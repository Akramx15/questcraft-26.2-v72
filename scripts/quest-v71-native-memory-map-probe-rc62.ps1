#requires -Version 7.0
<#
.SYNOPSIS
Arms and collects the aggregate-only RC6.2 native-memory map probe on Lab.

.DESCRIPTION
This tool is pinned to the immutable RC6.2 Lab identity. Its default SelfTest
is Host-only. Device actions require explicit read/write switches, reject the
Stable package, require the exact APK/Core/VEQ hashes, and never install,
launch, stop, clear, or uninstall an app.

Arm creates one fixed marker while Lab is stopped. Collect accepts only the
schema-2 aggregate JSON produced by LabNativeMemoryMapSampler; raw mapping
names, addresses, paths, account/world/server data, and unknown fields are
rejected before anything is persisted on Host. Disarm removes only the fixed
marker and preserves all samples.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Status', 'Arm', 'Collect', 'Disarm')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [string] $OutputDirectory = '',

    [switch] $AllowDeviceRead,
    [switch] $AllowDeviceWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC6_2.lock.json'
$script:BuildLock = Get-Content -Raw -LiteralPath $script:LockPath | ConvertFrom-Json
$script:Package = [string]$script:BuildLock.target.package
$script:ForbiddenStablePackage = [string]$script:BuildLock.target.forbiddenStablePackage
$script:Profile = [string]$script:BuildLock.target.profile
$script:ExpectedVersionCode = [int64]$script:BuildLock.target.versionCode
$script:ExpectedVersionName = [string]$script:BuildLock.target.versionName
$script:ExpectedApkSha256 = [string]$script:BuildLock.target.apkSha256
$script:ExpectedCoreSha256 = [string]$script:BuildLock.pair.core.sha256
$script:ExpectedVeqSha256 = [string]$script:BuildLock.pair.veq.sha256
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:DiagnosticRoot = "$($script:GameDirectory)/.questcraft-lab"
$script:MarkerPath = "$($script:DiagnosticRoot)/enable-memory-map-probe"
$script:RemoteOutputDirectory = "$($script:DiagnosticRoot)/native-memory-maps"
$script:RemoteOutputNames = @(
    'smaps-aggregates.jsonl.2',
    'smaps-aggregates.jsonl.1',
    'smaps-aggregates.jsonl'
)
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:ArtifactsRoot = [IO.Path]::GetFullPath(
    (Join-Path $script:RepoRoot 'artifacts\memory'))
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0
$script:Assertions = 0

$script:MetricFields = @(
    'mappings', 'sizeKiB', 'rssKiB', 'pssKiB', 'privateCleanKiB',
    'privateDirtyKiB', 'sharedCleanKiB', 'sharedDirtyKiB', 'anonymousKiB',
    'swapKiB', 'swapPssKiB'
)
$script:CategoryFields = @(
    'hotspotHeap', 'hotspotRuntime', 'androidRuntime', 'nativeHeap',
    'gpuOrDma', 'threadStack', 'jitOrCode', 'sharedMemory', 'appBinary',
    'gameContent', 'systemBinary', 'otherFile', 'anonymousPrivate',
    'anonymousShared'
)
$script:BucketFields = @(
    'under64KiB', '64KiBTo1MiB', '1MiBTo16MiB',
    '16MiBTo128MiB', 'atLeast128MiB'
)
$script:TopAnonymousFields = @(
    'sizeKiB', 'rssKiB', 'pssKiB', 'privateDirtyKiB', 'anonymousKiB',
    'swapKiB', 'permissions'
)

function Require([bool] $Condition, [string] $Message) {
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function Get-Sha256Text([Parameter(Mandatory)][string] $Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text)))
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-Sha256Text $text
}

function Get-FileSha256([Parameter(Mandatory)][string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sideQuest = Join-Path $env:LOCALAPPDATA `
        'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw 'ADB was not found. Pass -AdbPath with the full adb executable path.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocations++
    $rawRows = @(& $script:Adb @Arguments 2>&1)
    $code = $LASTEXITCODE
    $rows = @($rawRows | ForEach-Object { [string]$_ })
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB operation failed with exit code $code; device output was suppressed."
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $rows }
}

function Resolve-Device {
    Require $AllowDeviceRead.IsPresent `
        "$Action requires explicit -AllowDeviceRead."
    $script:Adb = Resolve-Adb
    $result = Invoke-Adb @('devices')
    $devices = @($result.Lines | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
            [string]$Matches.serial
        }
    })
    if ($Serial -ceq 'auto') {
        Require ($devices.Count -eq 1) `
            'Auto selection requires exactly one authorized ADB endpoint.'
        $script:Device = [string]$devices[0]
    } else {
        Require ($devices -ccontains $Serial) `
            'The requested ADB endpoint is not connected and authorized.'
        $script:Device = $Serial
    }
}

function Invoke-Shell([string[]] $Arguments, [switch] $AllowFailure) {
    $adbArguments = @('-s', $script:Device, 'shell') + $Arguments
    Invoke-Adb $adbArguments -AllowFailure:$AllowFailure
}

function Read-Sha256Sum(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $ExpectedPath
) {
    Require ($Lines.Count -eq 1) 'A device hash returned an unexpected row count.'
    $match = [regex]::Match([string]$Lines[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require $match.Success 'A device hash response was malformed.'
    Require ([string]$match.Groups['path'].Value -ceq $ExpectedPath) `
        'A device hash response named an unexpected path.'
    ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RemoteSha256([Parameter(Mandatory)][string] $Path) {
    $result = Invoke-Shell @('sha256sum', $Path)
    Read-Sha256Sum ([string[]]@($result.Lines)) $Path
}

function Get-InstalledIdentity {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262') `
        'The immutable build lock no longer targets the fixed Lab package.'
    Require ($script:ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262') `
        'The immutable build lock no longer identifies the forbidden Stable package.'
    Require ($script:Package -cne $script:ForbiddenStablePackage) `
        'Lab and Stable package identities unexpectedly match.'

    $packageDump = Invoke-Shell @('dumpsys', 'package', $script:Package)
    $versionCodes = @($packageDump.Lines | ForEach-Object {
        if ($_ -match '^\s*versionCode=(?<value>\d+)(?:\s|$)') {
            [int64]$Matches.value
        }
    })
    $versionNames = @($packageDump.Lines | ForEach-Object {
        if ($_ -match '^\s*versionName=(?<value>\S+)\s*$') {
            [string]$Matches.value
        }
    })
    Require ($versionCodes.Count -eq 1 -and $versionNames.Count -eq 1) `
        'Installed Lab identity was missing or ambiguous.'
    Require ([int64]$versionCodes[0] -eq $script:ExpectedVersionCode -and
            [string]$versionNames[0] -ceq $script:ExpectedVersionName) `
        'Installed Lab version does not match immutable RC6.2.'

    $pathResult = Invoke-Shell @('pm', 'path', $script:Package)
    Require ($pathResult.Lines.Count -eq 1 -and
            [string]$pathResult.Lines[0] -cmatch
                '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$') `
        'Installed Lab must expose exactly one safe base APK.'
    $baseApkPath = [string]$Matches.path
    Require (-not $baseApkPath.Contains('..') -and
            $baseApkPath -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)')) `
        'Installed base APK path did not belong to fixed Lab.'

    $apkSha256 = Read-RemoteSha256 $baseApkPath
    $coreSha256 = Read-RemoteSha256 $script:CorePath
    $veqSha256 = Read-RemoteSha256 $script:VeqPath
    Require ($apkSha256 -ceq $script:ExpectedApkSha256) `
        'Installed Lab APK bytes do not match immutable RC6.2.'
    Require ($coreSha256 -ceq $script:ExpectedCoreSha256) `
        'Installed Lab Core bytes do not match immutable RC6.2.'
    Require ($veqSha256 -ceq $script:ExpectedVeqSha256) `
        'Installed Lab VEQ bytes do not match immutable RC6.2.'

    $pidResult = Invoke-Shell @('pidof', $script:Package) -AllowFailure
    $pids = @($pidResult.Lines | ForEach-Object {
        [regex]::Matches([string]$_, '(?<!\d)\d+(?!\d)') |
            ForEach-Object { [int64]$_.Value }
    })
    [pscustomobject][ordered]@{
        Package = $script:Package
        VersionCode = [int64]$versionCodes[0]
        VersionName = [string]$versionNames[0]
        ApkSha256 = $apkSha256
        CoreSha256 = $coreSha256
        VeqSha256 = $veqSha256
        Running = $pids.Count -gt 0
    }
}

function Test-RemoteFile([Parameter(Mandatory)][string] $Path) {
    (Invoke-Shell @('test', '-f', $Path) -AllowFailure).ExitCode -eq 0
}

function Assert-ExactRemotePaths {
    $expectedGameDirectory =
        '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2'
    Require ($script:GameDirectory -ceq $expectedGameDirectory) `
        'The fixed Lab game directory drifted.'
    Require ($script:MarkerPath -ceq
            "$expectedGameDirectory/.questcraft-lab/enable-memory-map-probe") `
        'The fixed marker path drifted.'
    Require ($script:RemoteOutputDirectory -ceq
            "$expectedGameDirectory/.questcraft-lab/native-memory-maps") `
        'The fixed aggregate-output path drifted.'
    Require (-not $script:MarkerPath.Contains('..') -and
            -not $script:RemoteOutputDirectory.Contains('..')) `
        'A fixed remote path contains traversal syntax.'
}

function Assert-Stopped([Parameter(Mandatory)][object] $Identity) {
    Require (-not [bool]$Identity.Running) `
        'Lab must be stopped first; this tool never force-stops or launches it.'
}

function Assert-ExactProperties(
    [Parameter(Mandatory)][object] $Object,
    [Parameter(Mandatory)][string[]] $Allowed,
    [Parameter(Mandatory)][string] $Context,
    [switch] $RequireAll
) {
    Require ($null -ne $Object) "$Context was null."
    $names = @($Object.PSObject.Properties.Name)
    foreach ($name in $names) {
        Require ($Allowed -ccontains [string]$name) `
            "$Context contained an unknown field."
    }
    if ($RequireAll) {
        foreach ($name in $Allowed) {
            Require ($names -ccontains $name) "$Context omitted a required field."
        }
    }
}

function Assert-NonNegativeInteger([object] $Value, [string] $Context) {
    $parsed = 0L
    Require ($null -ne $Value -and
            [int64]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 0) `
        "$Context was not a non-negative integer."
}

function Assert-Metrics([object] $Metrics, [string] $Context) {
    Assert-ExactProperties $Metrics $script:MetricFields $Context -RequireAll
    foreach ($field in $script:MetricFields) {
        Assert-NonNegativeInteger $Metrics.$field "$Context.$field"
    }
}

function Assert-NamedMetricMap(
    [object] $Map,
    [string[]] $AllowedNames,
    [string] $Context
) {
    Assert-ExactProperties $Map $AllowedNames $Context
    foreach ($property in $Map.PSObject.Properties) {
        Assert-Metrics $property.Value "$Context.$($property.Name)"
    }
}

function Assert-SafeSnapshotLine([Parameter(Mandatory)][string] $Line) {
    Require ($Line.Length -le 131072) 'One aggregate JSON sample exceeded 128 KiB.'
    Require (-not [string]::IsNullOrWhiteSpace($Line)) 'An aggregate JSON sample was empty.'
    try {
        $snapshot = $Line | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    } catch {
        throw 'An aggregate JSON sample was malformed.'
    }
    Assert-ExactProperties $snapshot @(
        'schema', 'elapsedRealtimeMs', 'total', 'categories', 'sizeBuckets',
        'categorySizeBuckets', 'topAnonymousPrivateMappings'
    ) 'snapshot' -RequireAll
    Require ([int]$snapshot.schema -eq 2) 'Only aggregate schema 2 is accepted.'
    Assert-NonNegativeInteger $snapshot.elapsedRealtimeMs 'snapshot.elapsedRealtimeMs'
    Assert-Metrics $snapshot.total 'snapshot.total'
    Assert-NamedMetricMap $snapshot.categories $script:CategoryFields `
        'snapshot.categories'
    Assert-NamedMetricMap $snapshot.sizeBuckets $script:BucketFields `
        'snapshot.sizeBuckets'
    Assert-ExactProperties $snapshot.categorySizeBuckets $script:CategoryFields `
        'snapshot.categorySizeBuckets'
    foreach ($category in $snapshot.categorySizeBuckets.PSObject.Properties) {
        Assert-NamedMetricMap $category.Value $script:BucketFields `
            "snapshot.categorySizeBuckets.$($category.Name)"
    }
    $top = @($snapshot.topAnonymousPrivateMappings)
    Require ($top.Count -le 8) 'The aggregate sample exposed more than eight summaries.'
    foreach ($entry in $top) {
        Assert-ExactProperties $entry $script:TopAnonymousFields `
            'snapshot.topAnonymousPrivateMappings[]' -RequireAll
        foreach ($field in $script:TopAnonymousFields |
                Where-Object { $_ -cne 'permissions' }) {
            Assert-NonNegativeInteger $entry.$field "topAnonymous.$field"
        }
        Require ([string]$entry.permissions -cmatch '^[rwxps-]{4}$') `
            'An anonymous summary contained unsafe permissions text.'
    }
    # Re-serialize only the strict allowlisted object; no raw line is returned.
    $snapshot | ConvertTo-Json -Depth 30 -Compress
}

function Resolve-SafeOutputDirectory {
    [IO.Directory]::CreateDirectory($script:ArtifactsRoot) | Out-Null
    $candidate = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        Join-Path $script:ArtifactsRoot `
            ('v71-rc6.2-native-memory-map-' + (Get-Date).ToUniversalTime().ToString(
                'yyyyMMdd-HHmmss'))
    } elseif ([IO.Path]::IsPathRooted($OutputDirectory)) {
        $OutputDirectory
    } else {
        Join-Path $script:RepoRoot $OutputDirectory
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $prefix = $script:ArtifactsRoot.TrimEnd('\') + '\'
    Require ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) `
        'Collection output must be a new directory under artifacts/memory.'
    Require (-not (Test-Path -LiteralPath $full)) `
        'Collection output directory already exists; refusing to overwrite it.'
    $full
}

function Read-RemoteAggregateFile([Parameter(Mandatory)][string] $RemotePath) {
    $sizeResult = Invoke-Shell @('stat', '-c', '%s', $RemotePath)
    Require ($sizeResult.Lines.Count -eq 1 -and
            [string]$sizeResult.Lines[0] -cmatch '^\s*(?<bytes>\d+)\s*$') `
        'Aggregate file size response was malformed.'
    $size = [int64]$Matches.bytes
    Require ($size -gt 0 -and $size -le 1048576) `
        'Aggregate file was empty or exceeded its 1 MiB device bound.'
    $result = Invoke-Adb @('-s', $script:Device, 'exec-out', 'cat', $RemotePath)
    $safe = [Collections.Generic.List[string]]::new()
    foreach ($line in $result.Lines) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            $safe.Add((Assert-SafeSnapshotLine ([string]$line)))
        }
    }
    Require ($safe.Count -gt 0) 'Aggregate file contained no valid samples.'
    [pscustomobject][ordered]@{
        Lines = [string[]]$safe.ToArray()
        SourceBytes = $size
    }
}

function Invoke-Status {
    Resolve-Device
    Assert-ExactRemotePaths
    $identity = Get-InstalledIdentity
    $files = @($script:RemoteOutputNames | ForEach-Object {
        $remote = "$($script:RemoteOutputDirectory)/$_"
        [pscustomobject][ordered]@{ Name = $_; Present = Test-RemoteFile $remote }
    })
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Action = 'Status'
        Identity = $identity
        Armed = Test-RemoteFile $script:MarkerPath
        AggregateFiles = $files
        DeviceInvocations = $script:DeviceInvocations
        DeviceMutations = 0
        StableTouched = $false
    }
}

function Invoke-Arm {
    Require $AllowDeviceWrite.IsPresent 'Arm requires explicit -AllowDeviceWrite.'
    Resolve-Device
    Assert-ExactRemotePaths
    $identity = Get-InstalledIdentity
    Assert-Stopped $identity
    Invoke-Shell @('mkdir', '-p', $script:DiagnosticRoot) | Out-Null
    Invoke-Shell @('touch', $script:MarkerPath) | Out-Null
    Invoke-Shell @('chmod', '600', $script:MarkerPath) | Out-Null
    Require (Test-RemoteFile $script:MarkerPath) `
        'The fixed aggregate-probe marker was not created.'
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Action = 'Arm'
        Package = $script:Package
        Marker = '.questcraft-lab/enable-memory-map-probe'
        LabWasStopped = $true
        AppLaunched = $false
        AppStopped = $false
        StableTouched = $false
        NextStep = 'Launch Lab manually; the aggregate sampler starts with the next JVM.'
    }
}

function Invoke-Disarm {
    Require $AllowDeviceWrite.IsPresent 'Disarm requires explicit -AllowDeviceWrite.'
    Resolve-Device
    Assert-ExactRemotePaths
    $identity = Get-InstalledIdentity
    Assert-Stopped $identity
    Invoke-Shell @('rm', '-f', $script:MarkerPath) | Out-Null
    Require (-not (Test-RemoteFile $script:MarkerPath)) `
        'The fixed aggregate-probe marker still exists.'
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Action = 'Disarm'
        Package = $script:Package
        MarkerRemoved = $true
        AggregateOutputsPreserved = $true
        AppLaunched = $false
        AppStopped = $false
        StableTouched = $false
    }
}

function Invoke-Collect {
    Resolve-Device
    Assert-ExactRemotePaths
    $identity = Get-InstalledIdentity
    Assert-Stopped $identity
    $finalDirectory = Resolve-SafeOutputDirectory
    $staging = $finalDirectory + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $artifacts = [Collections.Generic.List[object]]::new()
    $totalSamples = 0
    try {
        foreach ($name in $script:RemoteOutputNames) {
            $remote = "$($script:RemoteOutputDirectory)/$name"
            if (-not (Test-RemoteFile $remote)) { continue }
            $aggregate = Read-RemoteAggregateFile $remote
            $hostPath = Join-Path $staging $name
            $content = ([string]::Join("`n", $aggregate.Lines)) + "`n"
            [IO.File]::WriteAllText($hostPath, $content,
                [Text.UTF8Encoding]::new($false))
            $totalSamples += $aggregate.Lines.Count
            $artifacts.Add([pscustomobject][ordered]@{
                path = $name
                sha256 = Get-FileSha256 $hostPath
                sizeBytes = (Get-Item -LiteralPath $hostPath).Length
                sampleCount = $aggregate.Lines.Count
            })
        }
        Require ($artifacts.Count -gt 0) `
            'No aggregate schema-2 output exists on fixed Lab.'
        $receipt = [ordered]@{
            schemaVersion = 1
            status = 'COLLECTED_VALIDATED_AGGREGATE_ONLY'
            recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
            candidate = [ordered]@{
                package = $script:Package
                versionCode = $script:ExpectedVersionCode
                versionName = $script:ExpectedVersionName
                apkSha256 = $script:ExpectedApkSha256
                coreSha256 = $script:ExpectedCoreSha256
                veqSha256 = $script:ExpectedVeqSha256
            }
            validation = [ordered]@{
                schema = 2
                aggregateOnly = $true
                unknownFieldsRejected = $true
                rawMappingNamesPersisted = $false
                rawMappingAddressesPersisted = $false
                deviceIdentifierPersisted = $false
                accountWorldServerDataPersisted = $false
                labWasStopped = $true
                appLaunched = $false
                appStopped = $false
                deviceFilesDeleted = $false
                stableTouched = $false
            }
            sampleCount = $totalSamples
            artifacts = @($artifacts)
        }
        $receiptPath = Join-Path $staging 'COLLECTION_RECEIPT.json'
        [IO.File]::WriteAllText($receiptPath,
            (($receipt | ConvertTo-Json -Depth 12) + "`n"),
            [Text.UTF8Encoding]::new($false))
        [IO.Directory]::Move($staging, $finalDirectory)
        [pscustomobject][ordered]@{
            Result = 'PASS'
            Action = 'Collect'
            OutputDirectory = $finalDirectory
            SampleCount = $totalSamples
            ArtifactCount = $artifacts.Count
            ReceiptSha256 = Get-FileSha256 `
                (Join-Path $finalDirectory 'COLLECTION_RECEIPT.json')
            DeviceFilesDeleted = $false
            StableTouched = $false
        }
    } catch {
        if (Test-Path -LiteralPath $staging -PathType Container) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
        throw
    }
}

function Invoke-SelfTest {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262' -and
            $script:ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262') `
        'Lab/Stable package boundary drifted.'
    Assert-ExactRemotePaths
    Require ([bool]$script:BuildLock.immutable) 'RC6.2 build lock is not immutable.'

    $metrics = [ordered]@{}
    foreach ($field in $script:MetricFields) { $metrics[$field] = 0 }
    $metrics.mappings = 1
    $metrics.sizeKiB = 4096
    $metrics.rssKiB = 1024
    $metrics.pssKiB = 768
    $fixture = [ordered]@{
        schema = 2
        elapsedRealtimeMs = 123456
        total = $metrics
        categories = [ordered]@{ anonymousPrivate = $metrics }
        sizeBuckets = [ordered]@{ fromFixture = $null }
        categorySizeBuckets = [ordered]@{
            anonymousPrivate = [ordered]@{ '1MiBTo16MiB' = $metrics }
        }
        topAnonymousPrivateMappings = @([ordered]@{
            sizeKiB = 4096; rssKiB = 1024; pssKiB = 768
            privateDirtyKiB = 512; anonymousKiB = 1024; swapKiB = 0
            permissions = 'rw-p'
        })
    }
    # Use a valid bucket in the positive fixture.
    $fixture.sizeBuckets = [ordered]@{ '1MiBTo16MiB' = $metrics }
    $safe = Assert-SafeSnapshotLine ($fixture | ConvertTo-Json -Depth 20 -Compress)
    Require (($safe | ConvertFrom-Json).schema -eq 2) `
        'Valid schema-2 fixture was not accepted.'

    $badUnknown = $fixture | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
    $badUnknown | Add-Member -NotePropertyName rawMappingPath `
        -NotePropertyValue '/data/private/secret.so'
    $unknownRejected = $false
    try { Assert-SafeSnapshotLine ($badUnknown | ConvertTo-Json -Depth 20 -Compress) | Out-Null }
    catch { $unknownRejected = $true }
    Require $unknownRejected 'Unknown/raw mapping fields were not rejected.'

    $badSchema = $fixture | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
    $badSchema.schema = 1
    $schemaRejected = $false
    try { Assert-SafeSnapshotLine ($badSchema | ConvertTo-Json -Depth 20 -Compress) | Out-Null }
    catch { $schemaRejected = $true }
    Require $schemaRejected 'A legacy/raw schema was not rejected.'

    $source = [IO.File]::ReadAllText($PSCommandPath)
    $quote = [string][char]39
    $stablePackageText = 'com.qcxr.qcxr.' + 'dev262'
    foreach ($forbidden in @(
        $quote + ('in' + 'stall') + $quote,
        $quote + ('un' + 'in' + 'stall') + $quote,
        $quote + ('cl' + 'ear') + $quote,
        $quote + ('force' + '-stop') + $quote,
        $quote + 'am' + $quote + ', ' + $quote + ('sta' + 'rt') + $quote,
        $quote + ('mon' + 'key') + $quote,
        '/data/data/' + $stablePackageText,
        '/sdcard/Android/data/' + $stablePackageText
    )) {
        Require (-not $source.Contains($forbidden, [StringComparison]::Ordinal)) `
            'The probe tool contains a forbidden device operation or Stable path.'
    }
    [pscustomobject][ordered]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = $script:DeviceInvocations
        Assertions = $script:Assertions
        Package = $script:Package
        ForbiddenStablePackage = $script:ForbiddenStablePackage
        DefaultAction = 'SelfTest'
        AggregateSchema = 2
        ValidFixtureAccepted = $true
        UnknownFieldFixtureRejected = $true
        LegacySchemaFixtureRejected = $true
        RawMappingNamesPersisted = $false
        RawMappingAddressesPersisted = $false
        InstallsOrLaunchesApps = $false
        StopsOrClearsApps = $false
        StableTouched = $false
        SourceNormalizedSha256 = Get-NormalizedTextSha256 $PSCommandPath
    }
}

switch ($Action) {
    'SelfTest' { Invoke-SelfTest }
    'Status' { Invoke-Status }
    'Arm' { Invoke-Arm }
    'Collect' { Invoke-Collect }
    'Disarm' { Invoke-Disarm }
}
