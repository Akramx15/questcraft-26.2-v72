<#
.SYNOPSIS
Arms one fixed, Lab-only managed-mod A/B experiment.

.DESCRIPTION
The package and profile cannot be overridden.  Arm/Rollback require an exact
local baseline, an independent expected SHA-256, and -AllowDeviceWrite.
Sodium replacement additionally requires the one allowlisted official 0.9.1
artifact and its independent SHA-256.  Disable experiments atomically hold
the selected baseline outside mods; they never delete it.

SelfTest is offline and neither resolves nor invokes ADB.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Status', 'Arm', 'Rollback')]
    [string] $Action = 'SelfTest',

    [ValidateSet('sodium-0.9.1', 'without-lithium', 'without-ferrite-core',
            'without-bad-optimizations')]
    [string] $Experiment = 'sodium-0.9.1',

    [string] $BaselineJar,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedBaselineSha256,

    [string] $CandidateJar,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedCandidateSha256,

    [ValidateRange(1, 30)]
    [int] $ExpiryMinutes = 15,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceWrite,

    [switch] $AllowRootFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requestedAction = $Action
$requestedAllowDeviceWrite = [bool]$AllowDeviceWrite
$requestedAllowRootFallback = [bool]$AllowRootFallback
$script:HarnessScriptPath = $PSCommandPath
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$sharedScript = Join-Path $PSScriptRoot 'quest-vivecraft-core-canary.ps1'
if (-not (Test-Path -LiteralPath $sharedScript -PathType Leaf)) {
    throw "The audited transaction transport is missing: $sharedScript"
}

# Import only the shared helper's offline path.  This provides the already
# audited ADB resolver, path canonicalizer, archive limits, and shell runner.
. $sharedScript -Action SelfTest -Serial $Serial -AdbPath $AdbPath `
        -AllowDeviceWrite:$AllowDeviceWrite -AllowRootFallback:$AllowRootFallback | Out-Null
$script:SharedGetDevicePaths = (Get-Command Get-DevicePaths -CommandType Function).ScriptBlock

$Action = $requestedAction
$AllowDeviceWrite = $requestedAllowDeviceWrite
$AllowRootFallback = $requestedAllowRootFallback
$script:HarnessId = 'questcraft-mods-ab-canary-v1'
$script:Package = 'com.qcxr.qcxr.canary262'
$script:ForbiddenPackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:StateRelative = ".questcraft/$script:HarnessId"
$script:LockPath = Join-Path $script:RepoRoot 'MODS_AB_LAB.lock.json'
$script:EmptySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$script:AbsentValue = '<absent>'
$script:MarkerSchemaVersion = 2
$script:OpenXrCopyBatchMode = 'OFF'
$script:ExperimentLock = $null
$script:BaselinePath = $null
$script:BaselineSha256 = $null
$script:BaselineSize = 0L
$script:TargetRelative = $null
$script:FabricId = $null
$script:MinecraftDependency = $null
$script:JavaDependency = $null
$script:MaxCandidateBytes = 16MB
$script:MaxArchiveBytes = 64MB
$script:MaxArchiveEntries = 4096

function Assert-ExactString {
    param([AllowNull()][object] $Actual, [string] $Expected, [string] $Label)
    Assert-Condition ($Actual -is [string] -and [string]$Actual -ceq $Expected) `
            "$Label changed from its fixed Lab contract."
}

function Test-IntegerValue {
    param([AllowNull()][object] $Value)
    return $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or
            $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64]
}

function Get-DependencyOrAbsent {
    param([AllowNull()][object] $Value, [string] $Name)
    if ($null -eq $Value) { return $script:AbsentValue }
    if ($Value -is [string]) { return [string]$Value }
    $values = @($Value)
    if ($values.Count -ne 1 -or $values[0] -isnot [string]) {
        throw "Fabric dependency '$Name' must be absent or one exact string."
    }
    return [string]$values[0]
}

function Get-PropertyOrNull {
    param([AllowNull()][object] $Object, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ModArchiveMetadata {
    param([Parameter(Mandatory)][string] $Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolved
    Assert-Condition (-not $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
            'Artifact must not be a symlink/reparse point.'
    Assert-Condition ($item.Length -gt 0 -and $item.Length -le $script:MaxCandidateBytes) `
            'Artifact is outside the fixed 16 MiB limit.'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolved)
    try {
        Assert-Condition ($archive.Entries.Count -gt 0 -and
                $archive.Entries.Count -le $script:MaxArchiveEntries) `
                'Artifact ZIP entry count is outside the fixed limit.'
        $names = New-Object 'Collections.Generic.HashSet[string]' `
                ([StringComparer]::OrdinalIgnoreCase)
        [int64]$expanded = 0
        $fabricEntries = New-Object Collections.Generic.List[object]
        foreach ($entry in $archive.Entries) {
            Assert-Condition (Test-SafeZipName ([string]$entry.FullName)) `
                    'Artifact contains an unsafe ZIP entry.'
            Assert-Condition ($names.Add([string]$entry.FullName)) `
                    'Artifact contains duplicate or case-colliding ZIP entries.'
            $attributes = [uint64](([int64]$entry.ExternalAttributes) -band 0xffffffffL)
            $unixMode = ($attributes -shr 16) -band 0xffff
            Assert-Condition (($unixMode -band 0xf000) -ne 0xa000) `
                    'Artifact contains a symbolic-link ZIP entry.'
            $expanded += [int64]$entry.Length
            Assert-Condition ($expanded -le $script:MaxArchiveBytes) `
                    'Artifact ZIP expansion exceeds the fixed 64 MiB limit.'
            if ([string]$entry.FullName -ceq 'fabric.mod.json') { $fabricEntries.Add($entry) }
        }
        Assert-Condition ($fabricEntries.Count -eq 1) `
                'Artifact must contain exactly one root fabric.mod.json.'
        Assert-Condition ($fabricEntries[0].Length -gt 0 -and
                $fabricEntries[0].Length -le 131072) `
                'fabric.mod.json is empty or oversized.'
        $reader = [IO.StreamReader]::new($fabricEntries[0].Open(),
                [Text.UTF8Encoding]::new($false, $true))
        try { $fabric = ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$fabric.id)) `
                'Fabric id is missing.'
        Assert-Condition (-not [string]::IsNullOrWhiteSpace([string]$fabric.version)) `
                'Fabric version is missing.'
        Assert-Condition ($null -ne $fabric.depends) 'Fabric depends object is missing.'
        return [pscustomobject]@{
            Path = $resolved
            Sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToUpperInvariant()
            SizeBytes = [int64]$item.Length
            FabricId = [string]$fabric.id
            FabricVersion = [string]$fabric.version
            Environment = [string](Get-PropertyOrNull $fabric 'environment')
            FabricLoaderDependency = Get-DependencyOrAbsent `
                    (Get-PropertyOrNull $fabric.depends 'fabricloader') 'fabricloader'
            MinecraftDependency = Get-DependencyOrAbsent `
                    (Get-PropertyOrNull $fabric.depends 'minecraft') 'minecraft'
            JavaDependency = Get-DependencyOrAbsent `
                    (Get-PropertyOrNull $fabric.depends 'java') 'java'
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-ExpectedExperiments {
    return [ordered]@{
        'sodium-0.9.1' = [ordered]@{
            Operation='replace'; Slug='Sodium'; Target='mods/Sodium.jar';
            BaselineSha='A6D1CED177A1C57147E8C1C8043650D5F93E1F2824C9952F3FB67AE05633A0A7';
            CandidateSha='DE406C7A0CA5E748DFBE44740278400882A44E3109E2584B243EC02D4003344B'
        }
        'without-lithium' = [ordered]@{
            Operation='disable'; Slug='Lithium'; Target='mods/Lithium.jar';
            BaselineSha='FDDE92E238E8075F89AD7F701F2A3D5854AF88BA9A67657184A4407B104AC563';
            CandidateSha='E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        }
        'without-ferrite-core' = [ordered]@{
            Operation='disable'; Slug='Ferrite-Core'; Target='mods/Ferrite-Core.jar';
            BaselineSha='213966C72ED967ACC7392BEB28A866FBA301FF56B9976C2E7801C2DB7DE6BF22';
            CandidateSha='E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        }
        'without-bad-optimizations' = [ordered]@{
            Operation='disable'; Slug='BadOptimizations'; Target='mods/BadOptimizations.jar';
            BaselineSha='06CEE46D81D3A0AFB8E993DFBE4B990A3BE92F52ABDE3590CC396490CB6EB4D2';
            CandidateSha='E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        }
    }
}

function Resolve-ModsAbLock {
    Assert-Condition (Test-Path -LiteralPath $script:LockPath -PathType Leaf) `
            "Mods A/B lock is missing: $script:LockPath"
    $lock = Get-Content -Raw -LiteralPath $script:LockPath | ConvertFrom-Json
    Assert-Condition ((Test-IntegerValue $lock.schemaVersion) -and
            [int64]$lock.schemaVersion -eq 1) 'Mods A/B lock schema changed.'
    Assert-ExactString $lock.harness.id $script:HarnessId 'Harness id'
    Assert-ExactString $lock.harness.package $script:Package 'Lab package'
    Assert-ExactString $lock.harness.forbiddenPackage $script:ForbiddenPackage 'Forbidden package'
    Assert-ExactString $lock.harness.profile $script:Profile 'Profile'
    Assert-ExactString $lock.harness.minecraftVersion $script:Profile 'Minecraft version'
    Assert-ExactString $lock.harness.stateRelative $script:StateRelative 'State root'
    Assert-Condition ([int]$lock.harness.maxLaunches -eq 1) 'Harness is not one-shot.'
    Assert-Condition ([int]$lock.harness.maxExpiryMinutes -eq 30) `
            'Harness expiry limit changed.'

    $expected = Get-ExpectedExperiments
    Assert-Condition (@($lock.experiments).Count -eq $expected.Count) `
            'Experiment count changed.'
    foreach ($id in $expected.Keys) {
        $matches = @($lock.experiments | Where-Object { [string]$_.id -ceq $id })
        Assert-Condition ($matches.Count -eq 1) "Experiment '$id' is missing or duplicated."
        $actual = $matches[0]
        $fixed = $expected[$id]
        Assert-ExactString $actual.operation $fixed.Operation "$id operation"
        Assert-ExactString $actual.slug $fixed.Slug "$id slug"
        Assert-ExactString $actual.target $fixed.Target "$id target"
        Assert-ExactString $actual.baseline.sha256 $fixed.BaselineSha "$id baseline SHA-256"
        Assert-ExactString $actual.candidate.sha256 $fixed.CandidateSha "$id candidate SHA-256"
        Assert-Condition ((Test-IntegerValue $actual.baseline.sizeBytes) -and
                [int64]$actual.baseline.sizeBytes -gt 0) "$id baseline size is invalid."
        if ($fixed.Operation -ceq 'replace') {
            Assert-Condition ([int64]$actual.candidate.sizeBytes -gt 0) `
                    "$id candidate size is invalid."
            Assert-ExactString $actual.candidate.sourceUrl `
                    'https://modrinth.com/mod/sodium/version/mc26.2-0.9.1-fabric' `
                    "$id documented source"
            Assert-ExactString $actual.candidate.checksumEvidence `
                    'exports/QuestCraft-Visor-26.2-PC-client-mods-20260830/SHA256SUMS.txt' `
                    "$id checksum evidence"
        } else {
            Assert-Condition ([int64]$actual.candidate.sizeBytes -eq 0) `
                    "$id disable candidate must be absent."
        }
    }

    $expectedHashes = @(
        'A6D1CED177A1C57147E8C1C8043650D5F93E1F2824C9952F3FB67AE05633A0A7',
        'DE406C7A0CA5E748DFBE44740278400882A44E3109E2584B243EC02D4003344B',
        'FDDE92E238E8075F89AD7F701F2A3D5854AF88BA9A67657184A4407B104AC563',
        '213966C72ED967ACC7392BEB28A866FBA301FF56B9976C2E7801C2DB7DE6BF22',
        '06CEE46D81D3A0AFB8E993DFBE4B990A3BE92F52ABDE3590CC396490CB6EB4D2',
        'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855')
    $actualHashes = @($lock.allowedSha256 | ForEach-Object {
        (Assert-Sha256 ([string]$_)).ToUpperInvariant()
    })
    Assert-Condition ($actualHashes.Count -eq $expectedHashes.Count) `
            'SHA-256 allowlist cardinality changed.'
    foreach ($hash in $expectedHashes) {
        Assert-Condition (@($actualHashes | Where-Object { $_ -ceq $hash }).Count -eq 1) `
                "Allowlisted SHA-256 '$hash' is missing or duplicated."
    }
    return $lock
}

function Set-ExperimentContext {
    param([Parameter(Mandatory)] $Lock, [Parameter(Mandatory)][string] $Id)
    $matches = @($Lock.experiments | Where-Object { [string]$_.id -ceq $Id })
    Assert-Condition ($matches.Count -eq 1) 'Selected experiment did not resolve uniquely.'
    $script:ExperimentLock = $matches[0]
    $script:TargetRelative = [string]$script:ExperimentLock.target
    $script:BaselineSha256 = ([string]$script:ExperimentLock.baseline.sha256).ToLowerInvariant()
    $script:BaselineSize = [int64]$script:ExperimentLock.baseline.sizeBytes
    $script:FabricId = [string]$script:ExperimentLock.candidate.fabricId
    $script:MinecraftDependency = [string]$script:ExperimentLock.candidate.minecraftDependency
    $script:JavaDependency = [string]$script:ExperimentLock.candidate.javaDependency
}

function Assert-ExactArtifact {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $IndependentSha256,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Label
    )
    $metadata = Get-ModArchiveMetadata $Path
    $independent = (Assert-Sha256 $IndependentSha256).ToUpperInvariant()
    Assert-Condition ($metadata.Sha256 -ceq $independent) `
            "$Label does not match its independently supplied SHA-256."
    Assert-ExactString $metadata.Sha256 ([string]$Expected.sha256) "$Label locked SHA-256"
    Assert-Condition ($metadata.SizeBytes -eq [int64]$Expected.sizeBytes) `
            "$Label size changed from the fixed lock."
    Assert-ExactString $metadata.FabricId ([string]$Expected.fabricId) "$Label Fabric id"
    Assert-ExactString $metadata.FabricVersion ([string]$Expected.fabricVersion) `
            "$Label Fabric version"
    Assert-ExactString $metadata.Environment ([string]$Expected.environment) `
            "$Label environment"
    Assert-ExactString $metadata.FabricLoaderDependency `
            ([string]$Expected.fabricLoaderDependency) "$Label Fabric Loader dependency"
    Assert-ExactString $metadata.MinecraftDependency `
            ([string]$Expected.minecraftDependency) "$Label Minecraft dependency"
    Assert-ExactString $metadata.JavaDependency ([string]$Expected.javaDependency) `
            "$Label Java dependency"
    return $metadata
}

function Assert-LabPaths {
    param([Parameter(Mandatory)] $Paths)
    $allowedFiles = @(
        "/sdcard/Android/data/$script:Package/files",
        "/storage/emulated/0/Android/data/$script:Package/files")
    $files = [string]$Paths.Files
    Assert-Condition ($allowedFiles -ccontains $files) `
            'Device root is not a proven canonical Lab package root.'
    Assert-Condition ([string]$Paths.Game -ceq "$files/instances/$script:Profile") `
            'Game directory is not the fixed Lab profile.'
    Assert-Condition ([string]$Paths.Mods -ceq "$($Paths.Game)/mods") `
            'Mods directory escaped the Lab profile.'
    Assert-Condition ([string]$Paths.State -ceq "$($Paths.Game)/$script:StateRelative") `
            'State directory escaped the Lab profile.'
    Assert-Condition ([string]$Paths.Target -ceq "$($Paths.Game)/$script:TargetRelative") `
            'Target escaped the fixed experiment.'
    foreach ($value in @($Paths.PSObject.Properties.Value)) {
        Assert-Condition (([string]$value).IndexOf($script:ForbiddenPackage,
                [StringComparison]::Ordinal) -lt 0) 'Generated path targeted Stable.'
    }
    return $Paths
}

function Get-DevicePaths {
    return Assert-LabPaths (& $script:SharedGetDevicePaths)
}

function New-ModsAbMarker {
    param([string] $RunId, [string] $OtherModsFingerprintSha256, [int64] $ExpiresAtEpochMs)
    $candidate = $script:ExperimentLock.candidate
    [ordered]@{
        schemaVersion = $script:MarkerSchemaVersion
        harnessId = $script:HarnessId
        state = 'armed'
        packageName = $script:Package
        profile = $script:Profile
        target = $script:TargetRelative
        runId = Assert-RunId $RunId
        baselineSha256 = $script:BaselineSha256
        baselineSizeBytes = [int64]$script:BaselineSize
        candidateSha256 = ([string]$candidate.sha256).ToLowerInvariant()
        candidateSizeBytes = [int64]$candidate.sizeBytes
        fabricId = [string]$candidate.fabricId
        fabricVersion = [string]$candidate.fabricVersion
        minecraftDependency = [string]$candidate.minecraftDependency
        javaDependency = [string]$candidate.javaDependency
        otherModsFingerprintSha256 = Assert-Sha256 $OtherModsFingerprintSha256
        openXrCopyBatchMode = $script:OpenXrCopyBatchMode
        expiresAtEpochMs = [int64]$ExpiresAtEpochMs
        maxLaunches = 1
    }
}

function Assert-ModsAbMarker {
    param([Parameter(Mandatory)] $Marker)
    $expected = @('schemaVersion','harnessId','state','packageName','profile','target','runId',
        'baselineSha256','baselineSizeBytes','candidateSha256','candidateSizeBytes','fabricId',
        'fabricVersion','minecraftDependency','javaDependency','otherModsFingerprintSha256',
        'openXrCopyBatchMode',
        'expiresAtEpochMs','maxLaunches')
    $actual = @($Marker.PSObject.Properties.Name)
    Assert-Condition ($actual.Count -eq $expected.Count) 'Marker field count is not exact.'
    foreach ($name in $expected) {
        Assert-Condition (@($actual | Where-Object { $_ -ceq $name }).Count -eq 1) `
                "Marker field '$name' is missing or duplicated."
    }
    foreach ($name in @('harnessId','state','packageName','profile','target','runId',
            'baselineSha256','candidateSha256','fabricId','fabricVersion',
            'minecraftDependency','javaDependency','otherModsFingerprintSha256',
            'openXrCopyBatchMode')) {
        Assert-Condition ($Marker.$name -is [string]) `
                "Marker field '$name' must be a JSON string."
    }
    foreach ($name in @('schemaVersion','baselineSizeBytes','candidateSizeBytes',
            'expiresAtEpochMs','maxLaunches')) {
        Assert-Condition (Test-IntegerValue $Marker.$name) `
                "Marker field '$name' must be a JSON integer."
    }
    Assert-Condition ([int]$Marker.schemaVersion -eq $script:MarkerSchemaVersion) `
            'Marker schema changed.'
    Assert-Condition (@('armed','attempting','consumed','expired') -ccontains
            [string]$Marker.state) 'Marker state is unknown.'
    Assert-ExactString $Marker.harnessId $script:HarnessId 'Marker harness'
    Assert-ExactString $Marker.packageName $script:Package 'Marker package'
    Assert-ExactString $Marker.profile $script:Profile 'Marker profile'
    Assert-ExactString $Marker.target $script:TargetRelative 'Marker target'
    Assert-RunId ([string]$Marker.runId) | Out-Null
    Assert-ExactString $Marker.baselineSha256 $script:BaselineSha256 'Marker baseline hash'
    Assert-Condition ([int64]$Marker.baselineSizeBytes -eq $script:BaselineSize) `
            'Marker baseline size changed.'
    Assert-ExactString $Marker.candidateSha256 `
            ([string]$script:ExperimentLock.candidate.sha256).ToLowerInvariant() `
            'Marker candidate hash'
    Assert-Condition ([int64]$Marker.candidateSizeBytes -eq
            [int64]$script:ExperimentLock.candidate.sizeBytes) 'Marker candidate size changed.'
    Assert-ExactString $Marker.fabricId ([string]$script:ExperimentLock.candidate.fabricId) `
            'Marker Fabric id'
    Assert-ExactString $Marker.fabricVersion `
            ([string]$script:ExperimentLock.candidate.fabricVersion) 'Marker Fabric version'
    Assert-ExactString $Marker.minecraftDependency `
            ([string]$script:ExperimentLock.candidate.minecraftDependency) `
            'Marker Minecraft dependency'
    Assert-ExactString $Marker.javaDependency `
            ([string]$script:ExperimentLock.candidate.javaDependency) 'Marker Java dependency'
    Assert-Sha256 ([string]$Marker.otherModsFingerprintSha256) | Out-Null
    Assert-ExactString $Marker.openXrCopyBatchMode $script:OpenXrCopyBatchMode `
            'Marker OpenXR copy-batch mode'
    Assert-Condition ([int64]$Marker.expiresAtEpochMs -gt 0) 'Marker expiry is invalid.'
    Assert-Condition ([int]$Marker.maxLaunches -eq 1) 'Marker is not one-shot.'
}

function ConvertFrom-StrictModsAbMarkerJson {
    param([Parameter(Mandatory)][string] $Raw)
    $expected = @('schemaVersion','harnessId','state','packageName','profile','target','runId',
        'baselineSha256','baselineSizeBytes','candidateSha256','candidateSizeBytes','fabricId',
        'fabricVersion','minecraftDependency','javaDependency','otherModsFingerprintSha256',
        'openXrCopyBatchMode',
        'expiresAtEpochMs','maxLaunches')
    $matches = [regex]::Matches($Raw, '"(?<name>(?:\\.|[^"\\])*)"\s*:')
    $names = @($matches | ForEach-Object { $_.Groups['name'].Value })
    Assert-Condition ($names.Count -eq $expected.Count) `
            'Marker JSON member count is not exact.'
    foreach ($name in $expected) {
        Assert-Condition (@($names | Where-Object { $_ -ceq $name }).Count -eq 1) `
                "Marker JSON is missing or duplicates '$name'."
    }
    $marker = $Raw | ConvertFrom-Json
    Assert-ModsAbMarker $marker
    return $marker
}

function Get-RemoteBoundMarker {
    param(
        [Parameter(Mandatory)] $Paths,
        [ValidateSet('Normal','Root')][string] $Mode
    )
    $qMarker = ConvertTo-ShLiteral $Paths.Marker
    $command = @"
set -eu
test -f $qMarker && test ! -L $qMarker
test "`$(stat -c %s $qMarker)" -gt 0
test "`$(stat -c %s $qMarker)" -le 16384
printf 'MARKER_SHA256\t%s\n' "`$(sha256sum $qMarker | awk '{print tolower(`$1)}')"
cat $qMarker
"@
    $result = if ($Mode -ceq 'Root') {
        Invoke-WriteShell -Command $command -Mode Root -AllowFailure
    } else {
        Invoke-DeviceShell -Command $command -AllowFailure
    }
    $lines = @($result.Lines)
    if ($result.ExitCode -ne 0 -or $lines.Count -lt 2 -or
            $lines[0] -notmatch '^MARKER_SHA256\t[0-9a-f]{64}$') {
        throw 'Rollback requires one readable, bounded armed/terminal marker.'
    }
    $sha256 = Assert-Sha256 $lines[0].Split("`t")[1]
    $raw = ($lines | Select-Object -Skip 1) -join "`n"
    $marker = ConvertFrom-StrictModsAbMarkerJson $raw
    return [pscustomobject]@{ Marker=$marker; Sha256=$sha256 }
}

function New-ArmCommitShell {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $MarkerSha256,
        [Parameter(Mandatory)][string] $UploadMarker,
        [string] $UploadCandidate = '',
        [string] $FaultStage = '',
        [ValidateSet('Normal','Root')][string] $AccessMode = 'Normal'
    )
    $run = Assert-RunId $RunId
    $state = $Paths.State
    $baselineStage = "$state/baseline-$run.upload"
    $baselineFinal = "$state/baseline.jar"
    $markerStage = "$state/request-$run.upload"
    $candidateStage = "$state/candidate-$run.upload"
    $candidateFinal = "$state/candidate-$run.jar"
    $stateParent = "$($Paths.Game)/.questcraft"
    $isReplace = [string]$script:ExperimentLock.operation -ceq 'replace'
    if ($isReplace) {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($UploadCandidate)) `
                'Replacement arm requires a candidate upload path.'
    }
    $fault = if ([string]::IsNullOrEmpty($FaultStage)) {
        'qcmab_fault() { return 0; }'
    } else {
        'qcmab_fault() { [ "$1" = ' + (ConvertTo-ShLiteral $FaultStage) +
                ' ] && return 1 || return 0; }'
    }
    $rootCapture = if ($AccessMode -ceq 'Root') {
@"
qcmab_dir_uid=`$(stat -c %u $(ConvertTo-ShLiteral $Paths.Game))
qcmab_dir_gid=`$(stat -c %g $(ConvertTo-ShLiteral $Paths.Game))
qcmab_dir_mode=`$(stat -c %a $(ConvertTo-ShLiteral $Paths.Game))
qcmab_file_uid=`$(stat -c %u $(ConvertTo-ShLiteral $Paths.Target))
qcmab_file_gid=`$(stat -c %g $(ConvertTo-ShLiteral $Paths.Target))
qcmab_file_mode=`$(stat -c %a $(ConvertTo-ShLiteral $Paths.Target))
"@
    } else { '' }
    $rootDirectoryMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $stateParent)):`$(stat -c %g $(ConvertTo-ShLiteral $stateParent))" = "`$qcmab_dir_uid:`$qcmab_dir_gid" || chown "`$qcmab_dir_uid:`$qcmab_dir_gid" $(ConvertTo-ShLiteral $stateParent)
test "`$(stat -c %u $(ConvertTo-ShLiteral $state)):`$(stat -c %g $(ConvertTo-ShLiteral $state))" = "`$qcmab_dir_uid:`$qcmab_dir_gid" || chown "`$qcmab_dir_uid:`$qcmab_dir_gid" $(ConvertTo-ShLiteral $state)
test "`$(stat -c %a $(ConvertTo-ShLiteral $stateParent))" = "`$qcmab_dir_mode" || chmod "`$qcmab_dir_mode" $(ConvertTo-ShLiteral $stateParent)
test "`$(stat -c %a $(ConvertTo-ShLiteral $state))" = "`$qcmab_dir_mode" || chmod "`$qcmab_dir_mode" $(ConvertTo-ShLiteral $state)
test "`$(stat -c %u $(ConvertTo-ShLiteral $state))" = "`$qcmab_dir_uid"
test "`$(stat -c %g $(ConvertTo-ShLiteral $state))" = "`$qcmab_dir_gid"
test "`$(stat -c %a $(ConvertTo-ShLiteral $state))" = "`$qcmab_dir_mode"
"@
    } else { '' }
    $rootBaselineMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $baselineFinal)):`$(stat -c %g $(ConvertTo-ShLiteral $baselineFinal))" = "`$qcmab_file_uid:`$qcmab_file_gid" || chown "`$qcmab_file_uid:`$qcmab_file_gid" $(ConvertTo-ShLiteral $baselineFinal)
test "`$(stat -c %a $(ConvertTo-ShLiteral $baselineFinal))" = "`$qcmab_file_mode" || chmod "`$qcmab_file_mode" $(ConvertTo-ShLiteral $baselineFinal)
test "`$(stat -c %u $(ConvertTo-ShLiteral $baselineFinal))" = "`$qcmab_file_uid"
test "`$(stat -c %g $(ConvertTo-ShLiteral $baselineFinal))" = "`$qcmab_file_gid"
test "`$(stat -c %a $(ConvertTo-ShLiteral $baselineFinal))" = "`$qcmab_file_mode"
"@
    } else { '' }
    $rootCandidateMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $candidateFinal)):`$(stat -c %g $(ConvertTo-ShLiteral $candidateFinal))" = "`$qcmab_file_uid:`$qcmab_file_gid" || chown "`$qcmab_file_uid:`$qcmab_file_gid" $(ConvertTo-ShLiteral $candidateFinal)
test "`$(stat -c %a $(ConvertTo-ShLiteral $candidateFinal))" = "`$qcmab_file_mode" || chmod "`$qcmab_file_mode" $(ConvertTo-ShLiteral $candidateFinal)
test "`$(stat -c %u $(ConvertTo-ShLiteral $candidateFinal))" = "`$qcmab_file_uid"
test "`$(stat -c %g $(ConvertTo-ShLiteral $candidateFinal))" = "`$qcmab_file_gid"
test "`$(stat -c %a $(ConvertTo-ShLiteral $candidateFinal))" = "`$qcmab_file_mode"
"@
    } else { '' }
    $rootMarkerStageMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $markerStage)):`$(stat -c %g $(ConvertTo-ShLiteral $markerStage))" = "`$qcmab_file_uid:`$qcmab_file_gid" || chown "`$qcmab_file_uid:`$qcmab_file_gid" $(ConvertTo-ShLiteral $markerStage)
test "`$(stat -c %a $(ConvertTo-ShLiteral $markerStage))" = "`$qcmab_file_mode" || chmod "`$qcmab_file_mode" $(ConvertTo-ShLiteral $markerStage)
"@
    } else { '' }
    $rootMarkerFinalMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $Paths.Marker))" = "`$qcmab_file_uid"
test "`$(stat -c %g $(ConvertTo-ShLiteral $Paths.Marker))" = "`$qcmab_file_gid"
test "`$(stat -c %a $(ConvertTo-ShLiteral $Paths.Marker))" = "`$qcmab_file_mode"
"@
    } else { '' }
    $candidateChecks = if ($isReplace) {
@"
test -f $(ConvertTo-ShLiteral $UploadCandidate) && test ! -L $(ConvertTo-ShLiteral $UploadCandidate)
test ! -e $(ConvertTo-ShLiteral $candidateStage) && test ! -L $(ConvertTo-ShLiteral $candidateStage)
test ! -e $(ConvertTo-ShLiteral $candidateFinal) && test ! -L $(ConvertTo-ShLiteral $candidateFinal)
cp $(ConvertTo-ShLiteral $UploadCandidate) $(ConvertTo-ShLiteral $candidateStage)
test "`$(stat -c %s $(ConvertTo-ShLiteral $candidateStage))" = $(ConvertTo-ShLiteral ([string]$script:ExperimentLock.candidate.sizeBytes))
test "`$(sha256sum $(ConvertTo-ShLiteral $candidateStage) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral ([string]$script:ExperimentLock.candidate.sha256).ToLowerInvariant())
mv $(ConvertTo-ShLiteral $candidateStage) $(ConvertTo-ShLiteral $candidateFinal)
$rootCandidateMetadata
qcmab_fault after-candidate-rename
"@
    } else { '' }
    $candidateCleanup = if ($isReplace) {
        "rm -f $(ConvertTo-ShLiteral $UploadCandidate) $(ConvertTo-ShLiteral $candidateStage)"
    } else { '' }
    $candidateUncommitted = if ($isReplace) {
        "rm -f $(ConvertTo-ShLiteral $candidateFinal)"
    } else { '' }
    $guard = Get-PathGuardShell $Paths
    $appStopped = Get-AppStoppedShell
    return @"
set -eu
$appStopped
$guard
$fault
qcmab_committed=0
qcmab_cleanup() {
  qcmab_status=`$?
  rm -f $(ConvertTo-ShLiteral $UploadMarker) $(ConvertTo-ShLiteral $markerStage) $(ConvertTo-ShLiteral $baselineStage)
  $candidateCleanup
  if [ "`$qcmab_committed" -eq 0 ]; then
    rm -f $(ConvertTo-ShLiteral $baselineFinal)
    $candidateUncommitted
  fi
  exit "`$qcmab_status"
}
trap qcmab_cleanup EXIT HUP INT TERM
test -f $(ConvertTo-ShLiteral $Paths.Target) && test ! -L $(ConvertTo-ShLiteral $Paths.Target)
test "`$(stat -c %s $(ConvertTo-ShLiteral $Paths.Target))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Target) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
$rootCapture
test ! -e $(ConvertTo-ShLiteral $Paths.Marker) && test ! -L $(ConvertTo-ShLiteral $Paths.Marker)
test ! -e $(ConvertTo-ShLiteral $Paths.RejectedMarker) && test ! -L $(ConvertTo-ShLiteral $Paths.RejectedMarker)
mkdir -p $(ConvertTo-ShLiteral $state)
test -d $(ConvertTo-ShLiteral $state) && test ! -L $(ConvertTo-ShLiteral $state)
test "`$(cd $(ConvertTo-ShLiteral $state) && pwd -P)" = $(ConvertTo-ShLiteral $state)
$rootDirectoryMetadata
test ! -e $(ConvertTo-ShLiteral $baselineFinal) && test ! -L $(ConvertTo-ShLiteral $baselineFinal)
test -f $(ConvertTo-ShLiteral $UploadMarker) && test ! -L $(ConvertTo-ShLiteral $UploadMarker)
test ! -e $(ConvertTo-ShLiteral $baselineStage) && test ! -L $(ConvertTo-ShLiteral $baselineStage)
test ! -e $(ConvertTo-ShLiteral $markerStage) && test ! -L $(ConvertTo-ShLiteral $markerStage)
cp $(ConvertTo-ShLiteral $Paths.Target) $(ConvertTo-ShLiteral $baselineStage)
test "`$(stat -c %s $(ConvertTo-ShLiteral $baselineStage))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $baselineStage) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
mv $(ConvertTo-ShLiteral $baselineStage) $(ConvertTo-ShLiteral $baselineFinal)
$rootBaselineMetadata
qcmab_fault after-baseline-rename
$candidateChecks
cp $(ConvertTo-ShLiteral $UploadMarker) $(ConvertTo-ShLiteral $markerStage)
test "`$(sha256sum $(ConvertTo-ShLiteral $markerStage) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $MarkerSha256)
$rootMarkerStageMetadata
qcmab_fault before-marker-commit
$appStopped
mv $(ConvertTo-ShLiteral $markerStage) $(ConvertTo-ShLiteral $Paths.Marker)
qcmab_committed=1
qcmab_fault after-marker-commit
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Marker) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $MarkerSha256)
$rootMarkerFinalMetadata
trap - EXIT HUP INT TERM
rm -f $(ConvertTo-ShLiteral $UploadMarker)
$candidateCleanup
printf 'COMMITTED\n'
"@
}

function New-ModsAbRollbackShell {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $UploadBaseline,
        [Parameter(Mandatory)][string] $MarkerSha256,
        [ValidateSet('Normal','Root')][string] $AccessMode = 'Normal'
    )
    $run = Assert-RunId $RunId
    $markerHash = Assert-Sha256 $MarkerSha256
    $stage = "$($Paths.Mods)/.mods-ab-rollback-$run.tmp"
    $baselineSource = "$($Paths.State)/baseline.jar"
    $ownedPaths = @(
        $baselineSource,
        "$($Paths.State)/prelaunch.lock",
        "$($Paths.State)/candidate-$run.jar",
        "$($Paths.State)/candidate-$run.upload",
        "$($Paths.State)/disabled-$run.jar",
        "$($Paths.State)/request-$run.tmp",
        "$($Paths.State)/request-$run.upload",
        "$($Paths.State)/baseline-$run.upload",
        $Paths.Marker)
    $ownedLiterals = ($ownedPaths | ForEach-Object { ConvertTo-ShLiteral $_ }) -join ' '
    $guard = Get-PathGuardShell $Paths -StateMustExist
    $appStopped = Get-AppStoppedShell
    $rootCapture = if ($AccessMode -ceq 'Root') {
@"
qcmab_file_uid=`$(stat -c %u $(ConvertTo-ShLiteral $baselineSource))
qcmab_file_gid=`$(stat -c %g $(ConvertTo-ShLiteral $baselineSource))
qcmab_file_mode=`$(stat -c %a $(ConvertTo-ShLiteral $baselineSource))
"@
    } else { '' }
    $rootStageMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $stage)):`$(stat -c %g $(ConvertTo-ShLiteral $stage))" = "`$qcmab_file_uid:`$qcmab_file_gid" || chown "`$qcmab_file_uid:`$qcmab_file_gid" $(ConvertTo-ShLiteral $stage)
test "`$(stat -c %a $(ConvertTo-ShLiteral $stage))" = "`$qcmab_file_mode" || chmod "`$qcmab_file_mode" $(ConvertTo-ShLiteral $stage)
test "`$(stat -c %u $(ConvertTo-ShLiteral $stage))" = "`$qcmab_file_uid"
test "`$(stat -c %g $(ConvertTo-ShLiteral $stage))" = "`$qcmab_file_gid"
test "`$(stat -c %a $(ConvertTo-ShLiteral $stage))" = "`$qcmab_file_mode"
"@
    } else { '' }
    $rootTargetMetadata = if ($AccessMode -ceq 'Root') {
@"
test "`$(stat -c %u $(ConvertTo-ShLiteral $Paths.Target))" = "`$qcmab_file_uid"
test "`$(stat -c %g $(ConvertTo-ShLiteral $Paths.Target))" = "`$qcmab_file_gid"
test "`$(stat -c %a $(ConvertTo-ShLiteral $Paths.Target))" = "`$qcmab_file_mode"
"@
    } else { '' }
    return @"
set -eu
$appStopped
$guard
qcmab_rollback_cleanup() {
  qcmab_status=`$?
  rm -f $(ConvertTo-ShLiteral $stage) $(ConvertTo-ShLiteral $UploadBaseline)
  exit "`$qcmab_status"
}
trap qcmab_rollback_cleanup EXIT HUP INT TERM
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Marker) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $markerHash)
test -f $(ConvertTo-ShLiteral $baselineSource) && test ! -L $(ConvertTo-ShLiteral $baselineSource)
test "`$(stat -c %s $(ConvertTo-ShLiteral $baselineSource))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $baselineSource) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
$rootCapture
test -f $(ConvertTo-ShLiteral $UploadBaseline) && test ! -L $(ConvertTo-ShLiteral $UploadBaseline)
test "`$(stat -c %s $(ConvertTo-ShLiteral $UploadBaseline))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $UploadBaseline) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
test ! -L $(ConvertTo-ShLiteral $stage)
rm -f $(ConvertTo-ShLiteral $stage)
cp $(ConvertTo-ShLiteral $UploadBaseline) $(ConvertTo-ShLiteral $stage)
test "`$(sha256sum $(ConvertTo-ShLiteral $stage) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
$rootStageMetadata
$appStopped
mv $(ConvertTo-ShLiteral $stage) $(ConvertTo-ShLiteral $Paths.Target)
test "`$(stat -c %s $(ConvertTo-ShLiteral $Paths.Target))" = $(ConvertTo-ShLiteral ([string]$script:BaselineSize))
test "`$(sha256sum $(ConvertTo-ShLiteral $Paths.Target) | awk '{print tolower(`$1)}')" = $(ConvertTo-ShLiteral $script:BaselineSha256)
$rootTargetMetadata
for qcmab_file in $ownedLiterals; do
  [ -e "`$qcmab_file" ] || [ -L "`$qcmab_file" ] || continue
  test ! -L "`$qcmab_file" || exit 67
  rm -f "`$qcmab_file"
done
rmdir $(ConvertTo-ShLiteral $Paths.State) 2>/dev/null || true
trap - EXIT HUP INT TERM
rm -f $(ConvertTo-ShLiteral $UploadBaseline)
printf 'ROLLED_BACK\n'
"@
}

function New-TestPaths {
    param(
        [ValidateSet('/sdcard','/storage/emulated/0')]
        [string] $StorageRoot = '/sdcard'
    )
    $files = "$StorageRoot/Android/data/$script:Package/files"
    $game = "$files/instances/$script:Profile"
    $state = "$game/$script:StateRelative"
    return [pscustomobject]@{
        Files=$files; Game=$game; Mods="$game/mods"; State=$state;
        Target="$game/$script:TargetRelative"; Marker="$state/request.json";
        RejectedMarker="$state/request.rejected.json"
    }
}

function Assert-LocalArmInputs {
    if (-not $AllowDeviceWrite) { throw 'Arm is disabled until -AllowDeviceWrite is explicit.' }
    if ([string]::IsNullOrWhiteSpace($BaselineJar)) { throw 'Arm requires -BaselineJar.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedBaselineSha256)) {
        throw 'Arm requires -ExpectedBaselineSha256.'
    }
    $script:BaselinePath = (Assert-ExactArtifact -Path $BaselineJar `
            -IndependentSha256 $ExpectedBaselineSha256 `
            -Expected $script:ExperimentLock.baseline -Label 'Baseline').Path
    if ([string]$script:ExperimentLock.operation -ceq 'replace') {
        if ([string]::IsNullOrWhiteSpace($CandidateJar)) { throw 'Sodium Arm requires -CandidateJar.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedCandidateSha256)) {
            throw 'Sodium Arm requires -ExpectedCandidateSha256.'
        }
        return Assert-ExactArtifact -Path $CandidateJar `
                -IndependentSha256 $ExpectedCandidateSha256 `
                -Expected $script:ExperimentLock.candidate -Label 'Candidate'
    }
    Assert-Condition ([string]::IsNullOrWhiteSpace($CandidateJar) -and
            [string]::IsNullOrWhiteSpace($ExpectedCandidateSha256)) `
            'Disable experiments do not accept a candidate JAR.'
    return $null
}

function Invoke-ModsAbArm {
    $candidate = Assert-LocalArmInputs
    Resolve-Device
    Assert-PackageInstalled
    $paths = Get-DevicePaths
    $mode = Resolve-WriteMode $paths
    $preflight = Get-RemotePreflight $paths $mode
    Assert-Condition ($preflight.TargetSha256 -eq $script:BaselineSha256 -and
            $preflight.TargetSize -eq $script:BaselineSize) `
            'Arm requires the exact locked baseline in the Lab profile.'
    $run = New-RunId
    $expires = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() +
            ($ExpiryMinutes * 60L * 1000L)
    $marker = New-ModsAbMarker -RunId $run `
            -OtherModsFingerprintSha256 $preflight.OtherModsFingerprintSha256 `
            -ExpiresAtEpochMs $expires
    $markerPath = Join-Path ([IO.Path]::GetTempPath()) "qcmab-marker-$run.json"
    [IO.File]::WriteAllText($markerPath, (($marker | ConvertTo-Json -Depth 4) + "`n"),
            [Text.UTF8Encoding]::new($false))
    $uploadMarker = "/data/local/tmp/qcmab-$run-marker.upload"
    $uploadCandidate = if ($null -ne $candidate) {
        "/data/local/tmp/qcmab-$run-candidate.upload"
    } else { '' }
    try {
        Assert-ModsAbMarker ([pscustomobject](Get-Content -LiteralPath $markerPath -Raw |
                ConvertFrom-Json))
        $markerSha = (Get-FileHash $markerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Push-LocalFile $markerPath $uploadMarker
        if ($null -ne $candidate) { Push-LocalFile $candidate.Path $uploadCandidate }
        $command = New-ArmCommitShell -Paths $paths -RunId $run `
                -MarkerSha256 $markerSha -UploadMarker $uploadMarker `
                -UploadCandidate $uploadCandidate -AccessMode $mode
        $result = Invoke-WriteShell -Command $command -Mode $mode -AllowFailure
        if ($result.ExitCode -ne 0) {
            $qMarker = ConvertTo-ShLiteral $paths.Marker
            $prove = 'test -f ' + $qMarker + ' && test ! -L ' + $qMarker +
                    ' && test "$(sha256sum ' + $qMarker +
                    ' | awk ''{print tolower($1)}'')" = ' +
                    (ConvertTo-ShLiteral $markerSha)
            if ((Invoke-WriteShell -Command $prove -Mode $mode -AllowFailure).ExitCode -ne 0) {
                throw 'Arm transaction did not complete exactly.'
            }
        }
    } catch {
        $cleanup = "rm -f $(ConvertTo-ShLiteral $uploadMarker)"
        if (-not [string]::IsNullOrWhiteSpace($uploadCandidate)) {
            $cleanup += " $(ConvertTo-ShLiteral $uploadCandidate)"
        }
        Invoke-WriteShell -Command $cleanup -Mode $mode -AllowFailure | Out-Null
        throw
    } finally {
        [IO.File]::Delete($markerPath)
    }
    [pscustomobject]@{
        Result='ARMED'; Experiment=$Experiment; Package=$script:Package;
        Profile=$script:Profile; RunId=$run; ExpiresAtEpochMs=$expires;
        BaselineSha256=$script:BaselineSha256.ToUpperInvariant();
        CandidateSha256=([string]$script:ExperimentLock.candidate.sha256).ToUpperInvariant();
        MarkerCommittedLast=$true; AtomicRuntimePromotion=$true; AccessMode=$mode
    }
}

function Invoke-ModsAbRollback {
    if (-not $AllowDeviceWrite) {
        throw 'Rollback is disabled until -AllowDeviceWrite is explicit.'
    }
    if ([string]::IsNullOrWhiteSpace($BaselineJar)) { throw 'Rollback requires -BaselineJar.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedBaselineSha256)) {
        throw 'Rollback requires -ExpectedBaselineSha256.'
    }
    $baseline = Assert-ExactArtifact -Path $BaselineJar `
            -IndependentSha256 $ExpectedBaselineSha256 `
            -Expected $script:ExperimentLock.baseline -Label 'Baseline'
    Resolve-Device
    Assert-PackageInstalled
    $paths = Get-DevicePaths
    $mode = Resolve-WriteMode $paths
    $bound = Get-RemoteBoundMarker -Paths $paths -Mode $mode
    $run = [string]$bound.Marker.runId
    $upload = "/data/local/tmp/qcmab-$run-baseline.upload"
    try {
        Push-LocalFile $baseline.Path $upload
        $result = Invoke-WriteShell -Command `
                (New-ModsAbRollbackShell -Paths $paths -RunId $run `
                -UploadBaseline $upload -MarkerSha256 $bound.Sha256 `
                -AccessMode $mode) -Mode $mode -AllowFailure
        if ($result.ExitCode -ne 0) { throw 'Rollback failed; exact baseline was not proven.' }
    } catch {
        Invoke-WriteShell -Command "rm -f $(ConvertTo-ShLiteral $upload)" `
                -Mode $mode -AllowFailure | Out-Null
        throw
    }
    [pscustomobject]@{
        Result='ROLLED_BACK'; Experiment=$Experiment; Package=$script:Package;
        Profile=$script:Profile; BaselineSha256=$script:BaselineSha256.ToUpperInvariant();
        RunId=$run; MarkerBound=$true; AccessMode=$mode
    }
}

function Invoke-ModsAbStatus {
    Resolve-Device
    Assert-PackageInstalled
    $paths = Get-DevicePaths
    $running = Invoke-DeviceShell -Command "pidof $(ConvertTo-ShLiteral $script:Package)" -AllowFailure
    $qTarget = ConvertTo-ShLiteral $paths.Target
    $qMarker = ConvertTo-ShLiteral $paths.Marker
    $command = @"
set -eu
if [ -f $qTarget ] && [ ! -L $qTarget ]; then
  printf 'TARGET\t%s\t%s\n' "`$(stat -c %s $qTarget)" "`$(sha256sum $qTarget | awk '{print tolower(`$1)}')"
elif [ ! -e $qTarget ] && [ ! -L $qTarget ]; then printf 'TARGET\tabsent\tabsent\n'
else exit 67; fi
if [ -f $qMarker ] && [ ! -L $qMarker ]; then printf 'MARKER\tpresent\n'; else printf 'MARKER\tabsent\n'; fi
"@
    $result = Invoke-DeviceShell -Command $command -AllowFailure
    if ($result.ExitCode -ne 0) { throw 'Could not read fixed Lab experiment status.' }
    $target = @($result.Lines | Where-Object { $_ -match '^TARGET\t' })
    $marker = @($result.Lines | Where-Object { $_ -match '^MARKER\t' })
    Assert-Condition ($target.Count -eq 1 -and $marker.Count -eq 1) 'Status output was ambiguous.'
    $parts = $target[0].Split("`t")
    [pscustomobject]@{
        Result='STATUS'; Experiment=$Experiment; Package=$script:Package; Profile=$script:Profile;
        Running=$running.ExitCode -eq 0; TargetState=$parts[1]; TargetSha256=$parts[2];
        Marker=$marker[0].Split("`t")[1]; ReadOnly=$true
    }
}

function Invoke-ModsAbSelfTest {
    $adbBefore = $script:AdbInvocationCount
    $lock = Resolve-ModsAbLock
    $generated = New-Object Collections.Generic.List[string]
    foreach ($entry in @($lock.experiments)) {
        Set-ExperimentContext $lock ([string]$entry.id)
        $paths = Assert-LabPaths (New-TestPaths)
        Assert-LabPaths (New-TestPaths -StorageRoot '/storage/emulated/0') | Out-Null
        $marker = New-ModsAbMarker -RunId '0123456789abcdef0123456789abcdef' `
                -OtherModsFingerprintSha256 ('a' * 64) -ExpiresAtEpochMs 1800000000000
        Assert-ModsAbMarker ([pscustomobject]$marker)
        $generated.Add(($marker | ConvertTo-Json -Depth 4))
        $uploadCandidate = if ([string]$entry.operation -ceq 'replace') {
            '/data/local/tmp/qcmab-candidate.upload'
        } else { '' }
        $generated.Add((New-ArmCommitShell -Paths $paths `
                -RunId '0123456789abcdef0123456789abcdef' `
                -MarkerSha256 ('b' * 64) -UploadMarker '/data/local/tmp/qcmab-marker.upload' `
                -UploadCandidate $uploadCandidate))
        $generated.Add((New-ArmCommitShell -Paths $paths `
                -RunId '0123456789abcdef0123456789abcdef' `
                -MarkerSha256 ('b' * 64) -UploadMarker '/data/local/tmp/qcmab-marker.upload' `
                -UploadCandidate $uploadCandidate -AccessMode Root))
        $generated.Add((New-ModsAbRollbackShell -Paths $paths `
                -RunId '0123456789abcdef0123456789abcdef' `
                -UploadBaseline '/data/local/tmp/qcmab-baseline.upload' `
                -MarkerSha256 ('b' * 64)))
        $generated.Add((New-ModsAbRollbackShell -Paths $paths `
                -RunId '0123456789abcdef0123456789abcdef' `
                -UploadBaseline '/data/local/tmp/qcmab-baseline.upload' `
                -MarkerSha256 ('b' * 64) -AccessMode Root))
    }
    foreach ($text in $generated) {
        Assert-Condition ($text.IndexOf($script:ForbiddenPackage,
                [StringComparison]::Ordinal) -lt 0) `
                'Generated transaction content can target Stable.'
    }
    $stableRoot = "/sdcard/Android/data/$script:ForbiddenPackage/files"
    $stableRejected = $false
    try {
        Assert-LabPaths ([pscustomobject]@{
            Files=$stableRoot; Game="$stableRoot/instances/26.2";
            Mods="$stableRoot/instances/26.2/mods";
            State="$stableRoot/instances/26.2/$script:StateRelative";
            Target="$stableRoot/instances/26.2/$script:TargetRelative";
            Marker="$stableRoot/instances/26.2/$script:StateRelative/request.json";
            RejectedMarker="$stableRoot/instances/26.2/$script:StateRelative/request.rejected.json"
        }) | Out-Null
    } catch { $stableRejected = $true }
    Assert-Condition $stableRejected 'Stable paths passed the Lab guard.'

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:HarnessScriptPath, [ref]$tokens, [ref]$errors)
    Assert-Condition ($errors.Count -eq 0) 'PowerShell parser rejected the Mods A/B harness.'
    $parameters = @($ast.ParamBlock.Parameters | ForEach-Object {
        $_.Name.VariablePath.UserPath
    })
    Assert-Condition ($parameters -cnotcontains 'Package' -and
            $parameters -cnotcontains 'Profile') `
            'Harness exposes a package or profile override.'

    $gate = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot `
            'Pojlib/src/main/java/pojlib/ModsAbCanaryGate.java')
    Assert-Condition ($gate.Contains("EXPECTED_PACKAGE = `"$script:Package`"")) `
            'Runtime gate package drifted.'
    Assert-Condition (-not $gate.Contains("EXPECTED_PACKAGE = `"$script:ForbiddenPackage`"")) `
            'Runtime gate can target Stable.'
    foreach ($hash in @($lock.allowedSha256 | Where-Object {
            [string]$_ -cne $script:EmptySha256.ToUpperInvariant() })) {
        Assert-Condition ($gate.Contains(([string]$hash).ToLowerInvariant())) `
                "Runtime gate lacks allowlisted hash $hash."
    }

    Set-ExperimentContext $lock $Experiment
    if (-not [string]::IsNullOrWhiteSpace($BaselineJar)) {
        if ([string]::IsNullOrWhiteSpace($ExpectedBaselineSha256)) {
            throw 'SelfTest with -BaselineJar requires -ExpectedBaselineSha256.'
        }
        Assert-ExactArtifact -Path $BaselineJar -IndependentSha256 $ExpectedBaselineSha256 `
                -Expected $script:ExperimentLock.baseline -Label 'Baseline' | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($CandidateJar)) {
        if ([string]$script:ExperimentLock.operation -cne 'replace') {
            throw 'SelfTest candidate validation is valid only for sodium-0.9.1.'
        }
        if ([string]::IsNullOrWhiteSpace($ExpectedCandidateSha256)) {
            throw 'SelfTest with -CandidateJar requires -ExpectedCandidateSha256.'
        }
        Assert-ExactArtifact -Path $CandidateJar `
                -IndependentSha256 $ExpectedCandidateSha256 `
                -Expected $script:ExperimentLock.candidate -Label 'Candidate' | Out-Null
    }
    Assert-Condition ($script:AdbInvocationCount -eq $adbBefore) `
            'Mods A/B SelfTest invoked ADB.'
    [pscustomobject]@{
        Result='PASS'; HostOnly=$true; DeviceTouched=$false;
        AdbInvocations=$script:AdbInvocationCount-$adbBefore;
        Package=$script:Package; ForbiddenPackage=$script:ForbiddenPackage;
        Profile=$script:Profile; ExperimentCount=4; StablePathRejected=$true;
        CanonicalStorageAliasAccepted=$true; MarkerBoundRollback=$true;
        RootOwnershipDerived=$true;
        ExpectedBaselineSha256Required=$true; ExpectedCandidateSha256Required=$true;
        AllowDeviceWriteRequired=$true; MarkerCommittedLast=$true;
        AtomicPromotion=$true; AutomaticRollback=$true
    }
}

$lock = Resolve-ModsAbLock
Set-ExperimentContext $lock $Experiment
switch ($Action) {
    'SelfTest' { Invoke-ModsAbSelfTest }
    'Status' { Invoke-ModsAbStatus }
    'Arm' { Invoke-ModsAbArm }
    'Rollback' { Invoke-ModsAbRollback }
}
