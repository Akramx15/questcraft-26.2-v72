<#
.SYNOPSIS
Arms one hash-bound VEQ v71 candidate for one isolated Lab launch.

.DESCRIPTION
The package, profile, target, persistent RC5 pair, Fabric metadata, and rejected candidate
are fixed by VEQ_LAB_CANARY.lock.json. Candidate hashes are never implicit:
Deploy requires both -ExpectedSha256 and -AllowDeviceWrite. There are no
package/profile override parameters.
Rollback also requires -AllowDeviceWrite. SelfTest is Host-only and never
resolves or invokes ADB.

The helper reuses the audited one-shot transaction transport used by the
Vivecraft core canary. The candidate remains outside mods until the Lab
prelaunch gate atomically promotes it. A failed/terminal transaction restores
the exact embedded VEQ baseline; the next prelaunch restores that baseline
after a successful one-process run. Legacy v1/v2 state is isolated by the v3
namespace and can never restore a pre-v71 payload.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy', 'Rollback', 'SelfTest')]
    [string] $Action = 'SelfTest',

    [string] $JarPath,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $ExpectedSha256,

    [ValidateRange(1, 30)]
    [int] $ExpiryMinutes = 15,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceWrite,

    [switch] $AllowRootFallback,

    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requestedAction = $Action
$script:HarnessScriptPath = $PSCommandPath
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$sharedScript = Join-Path $PSScriptRoot 'quest-vivecraft-core-canary-rc5.ps1'
if (-not (Test-Path -LiteralPath $sharedScript -PathType Leaf)) {
    throw "The audited one-shot transaction helper is missing: $sharedScript"
}

# Dot-source only the shared helper's offline branch. It leaves its pure
# validators and shell generators in this script scope without resolving ADB.
$sharedArguments = @{
    Action = 'SelfTest'
    JarPath = $JarPath
    ExpiryMinutes = $ExpiryMinutes
    Serial = $Serial
    AdbPath = $AdbPath
    AllowDeviceWrite = $AllowDeviceWrite
    AllowRootFallback = $AllowRootFallback
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    $sharedArguments.ExpectedSha256 = $ExpectedSha256
}
. $sharedScript @sharedArguments | Out-Null

$script:SharedGetDevicePaths = (Get-Command Get-DevicePaths -CommandType Function).ScriptBlock
$script:SharedInvokeStatus = (Get-Command Invoke-Status -CommandType Function).ScriptBlock
$script:SharedInvokeDeploy = (Get-Command Invoke-Deploy -CommandType Function).ScriptBlock
$script:SharedInvokeRollback = (Get-Command Invoke-Rollback -CommandType Function).ScriptBlock

$script:HarnessId = 'questcraft-veq-v71-canary-v3'
$script:Package = 'com.qcxr.qcxr.canary262'
$script:ForbiddenPackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:TargetRelative = 'mods/Vivecraft-Essentials-Quest.jar'
$script:StateRelative = ".questcraft/$script:HarnessId"
$script:FabricId = 'vivecraft_essentials_quest'
$script:ExpectedFabricVersion = '0.7.0-v70-canary.1'
$script:MinecraftDependency = '26.2'
$script:JavaDependency = '>=25'
$script:MaxCandidateBytes = 2MB
$script:MaxArchiveBytes = 32MB
$script:MaxArchiveEntries = 4096
$script:VeqLockPath = Join-Path $script:RepoRoot 'VEQ_LAB_CANARY.lock.json'
$script:PairLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC5.lock.json'
$script:BaselinePath = $null
$script:BaselineSha256 = $null
$script:BaselineSize = 0L
$script:VeqLock = $null

function Assert-ExactString {
    param(
        [AllowNull()][object] $Actual,
        [Parameter(Mandatory)][string] $Expected,
        [Parameter(Mandatory)][string] $Label
    )
    Assert-Condition ($Actual -is [string] -and [string]$Actual -ceq $Expected) `
            "$Label changed from its fixed Lab contract."
}

function Test-IntegralValue {
    param([AllowNull()][object] $Value)
    return $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or
            $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64]
}

function Get-ExactDependencyValue {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)][string] $Name
    )
    if ($Value -is [string]) { return [string]$Value }
    $values = @($Value)
    if ($values.Count -ne 1 -or $values[0] -isnot [string]) {
        throw "Fabric dependency '$Name' must contain one exact string."
    }
    return [string]$values[0]
}

function Get-VeqFabricMetadata {
    param([Parameter(Mandatory)][string] $Path)

    $metadata = Get-StrictFabricMetadata $Path
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $entry = $archive.GetEntry('fabric.mod.json')
        Assert-Condition ($null -ne $entry) 'The root fabric.mod.json is missing.'
        $reader = [IO.StreamReader]::new($entry.Open(), [Text.UTF8Encoding]::new($false, $true))
        try { $fabric = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }

    Assert-Condition ((Test-IntegralValue $fabric.schemaVersion) -and
            [int64]$fabric.schemaVersion -eq 1) `
            'VEQ fabric.mod.json must use schemaVersion 1.'
    Assert-ExactString $fabric.id $script:FabricId 'Fabric id'
    Assert-ExactString $fabric.environment 'client' 'Fabric environment'
    Assert-Condition ($null -ne $fabric.depends) 'Fabric depends is missing.'
    Assert-ExactString (Get-ExactDependencyValue $fabric.depends.fabricloader 'fabricloader') `
            '>=0.19.3' 'Fabric Loader dependency'
    Assert-ExactString (Get-ExactDependencyValue $fabric.depends.'fabric-api' 'fabric-api') `
            '>=0.158.0' 'Fabric API dependency'
    Assert-ExactString (Get-ExactDependencyValue $fabric.depends.minecraft 'minecraft') `
            $script:MinecraftDependency 'Minecraft dependency'
    Assert-ExactString (Get-ExactDependencyValue $fabric.depends.java 'java') `
            $script:JavaDependency 'Java dependency'
    Assert-ExactString (Get-ExactDependencyValue $fabric.depends.vivecraft 'vivecraft') `
            '*' 'Vivecraft dependency'
    Assert-Condition (@($fabric.entrypoints.client).Count -eq 1 -and
            [string]$fabric.entrypoints.client[0] -ceq
            'org.questcraft.veq.fabric.VeqFabricClient') `
            'VEQ client entrypoint changed.'
    Assert-Condition (@($fabric.mixins).Count -eq 1 -and
            [string]$fabric.mixins[0] -ceq 'vivecraft_essentials_quest.mixins.json') `
            'VEQ mixin contract changed.'

    return [pscustomobject]@{
        Id = $metadata.Id
        Version = $metadata.Version
        MinecraftDependency = $metadata.MinecraftDependency
        JavaDependency = $metadata.JavaDependency
        SizeBytes = $metadata.SizeBytes
        Sha256 = $metadata.Sha256
        Environment = [string]$fabric.environment
    }
}

function Resolve-VeqLock {
    if (-not (Test-Path -LiteralPath $script:VeqLockPath -PathType Leaf)) {
        throw "VEQ Lab lock is missing: $script:VeqLockPath"
    }
    $lock = Get-Content -Raw -LiteralPath $script:VeqLockPath | ConvertFrom-Json
    $pair = Get-Content -Raw -LiteralPath $script:PairLockPath | ConvertFrom-Json
    Assert-ExactString $pair.target.package $script:Package 'RC5 Lab package'
    Assert-ExactString $pair.target.forbiddenStablePackage $script:ForbiddenPackage `
            'RC5 forbidden Stable package'
    Assert-Condition (-not [bool]$pair.target.stableTouched) `
            'The RC5 Lab lock reports that Stable was touched.'
    Assert-Condition ([int64]$pair.target.versionCode -eq 71 -and
            [string]$pair.target.versionName -clike '6.0.1-26.2-vivecraft-personal.12-rc.5*' -and
            [bool]$pair.target.artifactAuditPassed) `
            'The paired RC5 Lab artifact is not built and audited.'
    Assert-Condition ((Test-IntegralValue $lock.schemaVersion) -and
            [int64]$lock.schemaVersion -eq 2) `
            'VEQ Lab lock schema changed.'
    Assert-ExactString $lock.harness.id $script:HarnessId 'Harness id'
    Assert-ExactString $lock.harness.package $script:Package 'Lab package'
    Assert-ExactString $lock.harness.forbiddenPackage $script:ForbiddenPackage 'Forbidden package'
    Assert-ExactString $lock.harness.profile $script:Profile 'Profile'
    Assert-ExactString $lock.harness.minecraftVersion $script:Profile 'Minecraft version'
    Assert-ExactString $lock.harness.target $script:TargetRelative 'Managed target'
    Assert-ExactString $lock.harness.pairedTarget 'mods/Vivecraft.jar' 'Paired managed target'
    Assert-ExactString $lock.harness.fabricId $script:FabricId 'Locked Fabric id'
    Assert-ExactString $lock.harness.fabricVersion $script:ExpectedFabricVersion `
            'Locked Fabric version'
    Assert-ExactString $lock.harness.minecraftDependency $script:MinecraftDependency `
            'Locked Minecraft dependency'
    Assert-ExactString $lock.harness.javaDependency $script:JavaDependency `
            'Locked Java dependency'
    Assert-Condition ([int]$lock.harness.maxLaunches -eq 1) 'VEQ Lab lock is not one-shot.'
    Assert-Condition ([int]$lock.harness.maxExpiryMinutes -eq 30) `
            'VEQ Lab maximum arm lifetime changed.'

    Assert-ExactString $lock.baseline.sha256 `
            '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B' `
            'Baseline SHA-256'
    Assert-ExactString $lock.baseline.version '0.7.0-v70-canary.1' 'Baseline VEQ version'
    Assert-ExactString $lock.baseline.assetPath `
            'Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin' `
            'Baseline asset path'
    Assert-ExactString $lock.candidatePolicy.hashBinding `
            'explicit-expected-sha256-per-deploy' 'Candidate hash-binding policy'
    Assert-Condition (@($lock.candidatePolicy.bakedCandidateHashes).Count -eq 0) `
            'The v71 Lab lock must not bake unknown candidate hashes.'
    Assert-Condition ([int]$lock.candidatePolicy.maximumPlannedSequentialCandidates -eq 3) `
            'The v71 Lab candidate count changed.'
    Assert-ExactString $lock.candidatePolicy.sharedFabricVersion `
            $script:ExpectedFabricVersion 'Shared v70 Fabric version'
    Assert-Condition ([bool]$lock.candidatePolicy.pairedCoreAndVeqPermitsAllowed) `
            'Paired Core and VEQ permits must remain enabled.'
    $fingerprintExclusions = @($lock.candidatePolicy.pairedOtherModsFingerprintExcludesExactly)
    Assert-Condition ($fingerprintExclusions.Count -eq 2 -and
            $fingerprintExclusions[0] -ceq 'mods/Vivecraft.jar' -and
            $fingerprintExclusions[1] -ceq 'mods/Vivecraft-Essentials-Quest.jar') `
            'The shared paired-mod fingerprint exclusions changed.'
    Assert-Condition (@($lock.rejectedCandidates).Count -eq 1) `
            'The VEQ Lab lock must retain exactly one rejected candidate.'
    $rejected = @($lock.rejectedCandidates)[0]
    Assert-ExactString $rejected.sourceCommit `
            '1047f873b5111017b86cd2f8f4f19ae51c8fb0d1' 'Rejected source commit'
    Assert-ExactString $rejected.sha256 `
            '35B71C9C432B42AF067D65BEEB1E966C2242181D085449C411B230F568800095' `
            'Rejected candidate SHA-256'
    Assert-Condition ([bool]$lock.policy.atomicPromotionPerTargetRequired -and
            [bool]$lock.policy.compensatingRollbackOnPairedFailure) `
            'The v70 paired transaction rollback policy changed.'

    $baselineRelative = [string]$lock.baseline.assetPath
    $baselinePath = Join-Path $script:RepoRoot $baselineRelative
    Assert-Condition (Test-Path -LiteralPath $baselinePath -PathType Leaf) `
            'The embedded VEQ baseline is missing.'
    $baselineItem = Get-Item -LiteralPath $baselinePath
    Assert-Condition (-not $baselineItem.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) `
            'The embedded VEQ baseline must not be a reparse point.'
    $baselineHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash.ToUpperInvariant()
    Assert-Condition ($baselineHash -ceq [string]$lock.baseline.sha256) `
            'The embedded VEQ baseline does not match the Lab lock.'
    Assert-Condition ([int64]$baselineItem.Length -eq [int64]$lock.baseline.sizeBytes) `
            'The embedded VEQ baseline size does not match the Lab lock.'
    Assert-ExactString $pair.pair.veq.sha256 ([string]$lock.baseline.sha256) `
            'Paired RC5 frozen VEQ SHA-256'
    Assert-ExactString $pair.pair.veq.fabricVersion ([string]$lock.baseline.version) `
            'Paired RC5 frozen VEQ version'
    Assert-Condition ([int64]$pair.pair.veq.sizeBytes -eq [int64]$lock.baseline.sizeBytes) `
            'Paired RC5 frozen VEQ size changed.'
    $baselineMetadata = Get-VeqFabricMetadata $baselinePath
    Assert-ExactString $baselineMetadata.Version ([string]$lock.baseline.version) `
            'Embedded VEQ version'

    $script:BaselinePath = $baselinePath
    $script:BaselineSha256 = (Assert-Sha256 ([string]$lock.baseline.sha256))
    $script:BaselineSize = [int64]$lock.baseline.sizeBytes
    $script:VeqLock = $lock
    return $lock
}

# The shared transport calls this name from some of its diagnostics. Keep its
# resolution inside the fixed VEQ lock once this wrapper is active.
function Resolve-BaselineLock {
    Resolve-VeqLock | Out-Null
}

function Assert-VeqLabPaths {
    param(
        [Parameter(Mandatory)] $Paths,
        [Parameter(Mandatory)][string] $ExpectedFiles
    )

    Assert-Condition ([string]$Paths.Files -ceq $expectedFiles) `
            'The device root is not the fixed Lab package root.'
    Assert-Condition ([string]$Paths.Game -ceq "$expectedFiles/instances/$script:Profile") `
            'The game directory is not the fixed Lab 26.2 profile.'
    Assert-Condition ([string]$Paths.Mods -ceq "$($Paths.Game)/mods") `
            'The mods directory escaped the fixed Lab profile.'
    Assert-Condition ([string]$Paths.State -ceq "$($Paths.Game)/$script:StateRelative") `
            'The transaction state escaped the fixed Lab profile.'
    Assert-Condition ([string]$Paths.Target -ceq "$($Paths.Game)/$script:TargetRelative") `
            'The managed target escaped the fixed Lab profile.'
    foreach ($value in @($Paths.PSObject.Properties.Value)) {
        Assert-Condition (([string]$value).IndexOf($script:ForbiddenPackage,
                [StringComparison]::Ordinal) -lt 0) `
                'A generated path targeted the forbidden Stable package.'
    }
    return $Paths
}

function Get-DevicePaths {
    $paths = & $script:SharedGetDevicePaths
    $expectedFiles = Resolve-RemoteCanonicalPath `
            "/sdcard/Android/data/$script:Package/files"
    return Assert-VeqLabPaths $paths $expectedFiles
}

function Assert-NotBlacklistedCandidateHash {
    param([Parameter(Mandatory)][string] $Sha256)

    $normalized = (Assert-Sha256 $Sha256).ToUpperInvariant()
    foreach ($rejected in @($script:VeqLock.rejectedCandidates)) {
        if ($normalized -ceq ([string]$rejected.sha256).ToUpperInvariant()) {
            throw "Rejected VEQ candidate '$($rejected.sourceCommit)' is permanently blacklisted."
        }
    }
    return $normalized
}

function Assert-ApprovedCandidateFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $IndependentSha256
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $metadata = Get-VeqFabricMetadata $resolved
    $expected = (Assert-Sha256 $IndependentSha256).ToUpperInvariant()
    Assert-Condition ($metadata.Sha256.ToUpperInvariant() -ceq $expected) `
            'Candidate does not match -ExpectedSha256.'
    Assert-NotBlacklistedCandidateHash $expected | Out-Null
    Assert-ExactString $metadata.Version $script:ExpectedFabricVersion `
            'Candidate Fabric version'
    Assert-Condition ([int64]$metadata.SizeBytes -gt 0 -and
            [int64]$metadata.SizeBytes -le $script:MaxCandidateBytes) `
            'Candidate size is outside the fixed VEQ Lab limit.'
    return $metadata
}

function Invoke-VeqDeploy {
    if (-not $AllowDeviceWrite) {
        throw 'Deploy is disabled until -AllowDeviceWrite is explicit.'
    }
    if ([string]::IsNullOrWhiteSpace($JarPath)) {
        throw 'Deploy requires -JarPath.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        throw 'Deploy requires an explicit -ExpectedSha256.'
    }
    Assert-ApprovedCandidateFile -Path $JarPath -IndependentSha256 $ExpectedSha256 | Out-Null

    # Candidate validation and explicit host hash binding complete before ADB is even
    # resolved. The shared deploy repeats hash/archive validation immediately
    # before staging, closing a local file-change race.
    Resolve-Device
    & $script:SharedInvokeDeploy
}

function Invoke-VeqRollback {
    if (-not $AllowDeviceWrite) {
        throw 'Rollback is disabled until -AllowDeviceWrite is explicit.'
    }
    Resolve-Device
    & $script:SharedInvokeRollback
}

function Invoke-VeqStatus {
    Resolve-Device
    & $script:SharedInvokeStatus
}

function Invoke-VeqSelfTest {
    $adbBefore = $script:AdbInvocationCount
    $lock = Resolve-VeqLock
    $syntheticCandidateHash = '4C0FC01A3752A531A53F06C85A14C1E3F9510E1784A9160456699C8D8B9F7E72'
    $candidate = [pscustomobject]@{
        Id = $script:FabricId
        Version = $script:ExpectedFabricVersion
        MinecraftDependency = $script:MinecraftDependency
        JavaDependency = $script:JavaDependency
        SizeBytes = 425792L
        Sha256 = $syntheticCandidateHash.ToLowerInvariant()
    }
    $run = '0123456789abcdef0123456789abcdef'
    $paths = [pscustomobject]@{
        Files = "/sdcard/Android/data/$script:Package/files"
        Game = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile"
        Mods = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/mods"
        State = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/$script:StateRelative"
        Target = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/$script:TargetRelative"
        Marker = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/$script:StateRelative/request.json"
        RejectedMarker = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/$script:StateRelative/request.rejected.json"
    }
    Assert-VeqLabPaths $paths $paths.Files | Out-Null
    $marker = New-MarkerObject -RunId $run -Candidate $candidate `
            -OtherModsFingerprintSha256 ('a' * 64) -Mode 'OFF' `
            -ExpiresAtEpochMs 1800000000000
    Assert-StrictMarkerObject ([pscustomobject]$marker)
    $deployShell = New-DeployCommitShell -Paths $paths -RunId $run -Candidate $candidate `
            -MarkerSha256 ('b' * 64) `
            -UploadCandidate "/data/local/tmp/qcveq-$run-candidate.upload" `
            -UploadMarker "/data/local/tmp/qcveq-$run-marker.upload"
    $rollbackShell = New-RollbackShell -Paths $paths -RunId $run `
            -UploadBaseline "/data/local/tmp/qcveq-$run-baseline.upload"
    foreach ($generated in @($deployShell, $rollbackShell, ($marker | ConvertTo-Json -Depth 3))) {
        Assert-Condition ($generated.IndexOf($script:ForbiddenPackage,
                [StringComparison]::Ordinal) -lt 0) `
                'Generated transaction content can target the forbidden Stable package.'
        Assert-Condition ($generated.IndexOf($script:Package, [StringComparison]::Ordinal) -ge 0 -or
                $generated.IndexOf('/sdcard/Android/data/', [StringComparison]::Ordinal) -lt 0) `
                'Generated Android path is not owned by the Lab package.'
    }
    $stablePaths = [pscustomobject]@{
        Files = "/sdcard/Android/data/$script:ForbiddenPackage/files"
        Game = "/sdcard/Android/data/$script:ForbiddenPackage/files/instances/26.2"
        Mods = "/sdcard/Android/data/$script:ForbiddenPackage/files/instances/26.2/mods"
        State = "/sdcard/Android/data/$script:ForbiddenPackage/files/instances/26.2/$script:StateRelative"
        Target = "/sdcard/Android/data/$script:ForbiddenPackage/files/instances/26.2/$script:TargetRelative"
        Marker = "/sdcard/Android/data/$script:ForbiddenPackage/files/instances/26.2/$script:StateRelative/request.json"
        RejectedMarker = "/sdcard/Android/data/$script:ForbiddenPackage/files/instances/26.2/$script:StateRelative/request.rejected.json"
    }
    $stableRejected = $false
    try { Assert-VeqLabPaths $stablePaths $paths.Files | Out-Null } catch { $stableRejected = $true }
    Assert-Condition $stableRejected 'The Stable package path passed the Lab path guard.'

    $oldRejected = $false
    try {
        Assert-NotBlacklistedCandidateHash ([string]$lock.rejectedCandidates[0].sha256) | Out-Null
    } catch { $oldRejected = $true }
    Assert-Condition $oldRejected 'The superseded 1047f873 candidate was not blacklisted.'
    $resolvedSynthetic = Assert-NotBlacklistedCandidateHash $syntheticCandidateHash
    Assert-Condition ($resolvedSynthetic -ceq $syntheticCandidateHash) `
            'An explicitly supplied, non-blacklisted v70 candidate hash was not accepted.'

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:HarnessScriptPath, [ref]$tokens, [ref]$errors)
    Assert-Condition ($errors.Count -eq 0) 'PowerShell parser rejected the VEQ Lab harness.'
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
        $_.Name.VariablePath.UserPath
    })
    Assert-Condition ($parameterNames -cnotcontains 'Package' -and
            $parameterNames -cnotcontains 'Profile') `
            'The VEQ Lab harness exposes a package or profile override.'

    $gateSource = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot `
            'Pojlib/src/main/java/pojlib/VeqCanaryGate.java')
    Assert-Condition ($gateSource.Contains("EXPECTED_PACKAGE = `"$script:Package`"")) `
            'The runtime VEQ gate package drifted.'
    Assert-Condition (-not $gateSource.Contains("EXPECTED_PACKAGE = `"$script:ForbiddenPackage`"")) `
            'The runtime VEQ gate can target Stable.'
    Assert-Condition ($gateSource.Contains("HARNESS_ID = `"$script:HarnessId`"")) `
            'The runtime VEQ gate harness id drifted.'
    Assert-Condition ($gateSource.Contains(
            "EXPECTED_FABRIC_VERSION = `"$script:ExpectedFabricVersion`"")) `
            'The runtime VEQ gate Fabric version drifted.'
    Assert-Condition ($gateSource.Contains(
            '? Collections.singleton(requested.candidateSha256)')) `
            'The runtime VEQ gate no longer binds candidate SHA-256 from the marker.'
    Assert-Condition ($gateSource.Contains(
            ([string]$lock.rejectedCandidates[0].sha256).ToLowerInvariant())) `
            'The runtime VEQ gate no longer rejects the retired v69 candidate.'
    Assert-Condition (-not $gateSource.Contains(
            '2ab6b70242cbb45b77fecec81b3d7cca9a45ad82c59ef28f12fdfb0070ff7c36')) `
            'The runtime VEQ gate still bakes the retired v69 candidate hash.'

    if (-not [string]::IsNullOrWhiteSpace($JarPath)) {
        if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
            throw 'SelfTest with -JarPath also requires -ExpectedSha256.'
        }
        Assert-ApprovedCandidateFile -Path $JarPath -IndependentSha256 $ExpectedSha256 | Out-Null
    }
    Assert-Condition ($script:AdbInvocationCount -eq $adbBefore) `
            'VEQ Lab SelfTest invoked ADB or touched a device.'

    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceTouched = $false
        AdbInvocations = $script:AdbInvocationCount - $adbBefore
        HarnessId = $script:HarnessId
        Package = $script:Package
        ForbiddenPackage = $script:ForbiddenPackage
        Profile = $script:Profile
        Target = $script:TargetRelative
        BaselineSha256 = $script:BaselineSha256.ToUpperInvariant()
        CandidateHashPolicy = [string]$lock.candidatePolicy.hashBinding
        CandidateFabricVersion = $script:ExpectedFabricVersion
        SyntheticCandidateSha256 = $syntheticCandidateHash
        RejectedSourceCommit = [string]$lock.rejectedCandidates[0].sourceCommit
        StablePathRejected = $true
        ExpectedSha256Required = $true
        AllowDeviceWriteRequired = $true
        AtomicPromotionPerTarget = $true
        PairedCompensatingRollback = $true
        AutomaticRollback = $true
    }
}

$Action = $requestedAction
$result = if ($Action -eq 'SelfTest') {
    Invoke-VeqSelfTest
} else {
    Resolve-VeqLock | Out-Null
    switch ($Action) {
        'Status' { Invoke-VeqStatus }
        'Deploy' { Invoke-VeqDeploy }
        'Rollback' { Invoke-VeqRollback }
    }
}
if ($Json) {
    $result | ConvertTo-Json -Depth 6 -Compress
} else {
    $result
}
