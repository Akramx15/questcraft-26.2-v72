#requires -Version 7.0
<#
.SYNOPSIS
Collects a short, aggregate-only expanded memory diagnostic for exact RC6.2.

.DESCRIPTION
SelfTest is the default and is Host-only. Capture uses read-only queries and
samples numeric aggregate tables from `dumpsys meminfo -a --local` for 10 to
15 minutes. The --local fence keeps ActivityManager from calling into the
target process (and therefore avoids dump-triggered target GC); its heap
Size/Alloc/Free columns are consequently unavailable and reported as zero.
Raw command output is retained only in memory long enough to parse and validate
it. The persisted receipt contains no endpoint, application identifier, device
or Host path, or unfiltered text.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Capture')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [ValidateRange(10, 15)]
    [int] $DurationMinutes = 12,

    [ValidateRange(30, 300)]
    [int] $IntervalSeconds = 60,

    [string] $OutputDirectory = '',

    [switch] $AllowDeviceRead,
    [switch] $AllowHostOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuildLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC6_2.lock.json'
$script:ExpectedBuildLockSha256 = `
    '7DD25F7703A4E2B1F2857FD8EB552CB303CB3A1870779ADBD5708B3F5D1B7E45'
$script:LockedPackage = 'com.qcxr.qcxr.canary262'
$script:LockedStablePackage = 'com.qcxr.qcxr.dev262'
$script:LockedProfile = '26.2'
$script:LockedVersionCode = 71
$script:LockedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.6.2'
$script:LockedApkSha256 = `
    'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4'
$script:LockedCoreSha256 = `
    '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF'
$script:LockedVeqSha256 = `
    'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
$script:GameLogFreshnessSeconds = 60
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0
$script:HostWrites = 0
$script:Assertions = 0

$script:MainRowNames = @(
    'Native Heap', 'Dalvik Heap', 'Dalvik Other', 'Stack', 'Cursor',
    'Ashmem', 'Gfx dev', 'Gfx driver', 'Other dev', '.so mmap', '.jar mmap',
    '.apk mmap', '.ttf mmap', '.dex mmap', '.oat mmap', '.art mmap',
    'Other mmap', 'EGL mtrack', 'GL mtrack', 'Other mtrack', 'Unknown', 'TOTAL'
)
$script:DalvikDetailRowNames = @(
    '.Heap', '.LOS', '.Zygote', '.NonMoving', '.LinearAlloc', '.GC',
    '.JITCache', '.ZygoteJIT', '.AppJIT', '.CompilerMetadata', '.IndirectRef',
    '.Boot vdex', '.App dex', '.App vdex', '.App art', '.Boot art'
)

function Require([bool] $Condition, [string] $Message) {
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try {
        & $Operation
        return $false
    } catch {
        return $true
    }
}

function Get-Sha256Text([Parameter(Mandatory)][string] $Text) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return -join @($bytes | ForEach-Object { $_.ToString('X2') })
    } finally {
        $algorithm.Dispose()
    }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-Sha256Text $text
}

function Get-FileSha256([Parameter(Mandatory)][string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-ImmutableRc62Lock {
    Require (Test-Path -LiteralPath $script:BuildLockPath -PathType Leaf) `
        'The immutable RC6.2 build lock is missing.'
    Require ((Get-FileSha256 $script:BuildLockPath) -ceq
            $script:ExpectedBuildLockSha256) `
        'The immutable RC6.2 build lock bytes drifted.'
    $lock = Get-Content -Raw -LiteralPath $script:BuildLockPath | ConvertFrom-Json
    Require ([bool]$lock.immutable -and
            [string]$lock.target.package -ceq $script:LockedPackage -and
            [string]$lock.target.forbiddenStablePackage -ceq
                $script:LockedStablePackage -and
            [string]$lock.target.profile -ceq $script:LockedProfile -and
            [int64]$lock.target.versionCode -eq $script:LockedVersionCode -and
            [string]$lock.target.versionName -ceq $script:LockedVersionName -and
            [string]$lock.target.apkSha256 -ceq $script:LockedApkSha256 -and
            [string]$lock.pair.core.sha256 -ceq $script:LockedCoreSha256 -and
            [string]$lock.pair.veq.sha256 -ceq $script:LockedVeqSha256 -and
            [string]$lock.runtimeBinding.expectedGameLogRelativePath -ceq
                'instances/26.2/logs/latest.log' -and
            [string]$lock.runtimeBinding.expectedGameLogMinecraftVersion -ceq
                $script:LockedProfile -and
            [string]$lock.runtimeBinding.expectedGameLogCoreVersion -ceq
                '26.2-1.3.15+qc.v71.rc6.2' -and
            [string]$lock.runtimeBinding.expectedGameLogVeqVersion -ceq
                '0.7.0-v71.rc6') `
        'The immutable RC6.2 identity contract drifted.'
    return $lock
}

$script:BuildLock = Assert-ImmutableRc62Lock
$script:Package = [string]$script:BuildLock.target.package
$script:StablePackage = [string]$script:BuildLock.target.forbiddenStablePackage
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:LockedProfile)"
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:GameLogPath = "/sdcard/Android/data/$($script:Package)/files/" +
    [string]$script:BuildLock.runtimeBinding.expectedGameLogRelativePath

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    if ($AdbPath -cne 'adb') {
        throw 'The explicitly requested ADB executable was not found.'
    }
    $sideQuest = Join-Path $env:LOCALAPPDATA `
        'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw 'ADB was not found. Pass -AdbPath with the full adb executable path.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocations++
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "A read-only ADB probe failed with exit code $exitCode; output was suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $rows }
}

function Resolve-Device {
    $script:Adb = Resolve-Adb
    $result = Invoke-Adb @('devices')
    $devices = @($result.Lines | ForEach-Object {
        if ([string]$_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
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
    $result = $null
    $devices = $null
}

function Invoke-Shell([string[]] $Arguments, [switch] $AllowFailure) {
    Invoke-Adb (@('-s', $script:Device, 'shell') + $Arguments) `
        -AllowFailure:$AllowFailure
}

function Read-OneUnsignedInteger(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $Context
) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch '^[0-9]+$') `
        "$Context returned a malformed value."
    return [uint64]$rows[0]
}

function Get-Pid([string] $ExpectedPackage, [switch] $AllowMissing) {
    $result = Invoke-Shell @('pidof', $ExpectedPackage) -AllowFailure
    $rows = @($result.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($result.ExitCode -eq 1 -and $rows.Count -eq 0 -and $AllowMissing) {
        return $null
    }
    Require ($result.ExitCode -eq 0 -and $rows.Count -eq 1 -and
            $rows[0] -cmatch '^[0-9]+$') 'The PID probe was absent or ambiguous.'
    return [int]$rows[0]
}

function Read-ProcessStartTicks([Parameter(Mandatory)][string[]] $Lines) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'The process stat probe returned an ambiguous result.'
    $row = [string]$rows[0]
    $commEnd = $row.LastIndexOf(') ', [StringComparison]::Ordinal)
    Require ($commEnd -gt 0) 'The process stat probe was malformed.'
    $suffix = @($row.Substring($commEnd + 2) -split '\s+')
    Require ($suffix.Count -ge 20 -and $suffix[19] -cmatch '^[0-9]+$') `
        'The process stat probe omitted a valid start time.'
    return [uint64]$suffix[19]
}

function Get-ProcessStartTicks([int] $ProcessId) {
    $result = Invoke-Shell @('cat', "/proc/$ProcessId/stat")
    Read-ProcessStartTicks ([string[]]@($result.Lines))
}

function Get-ProcessAnchor([int] $ProcessId) {
    $clockTicksResult = Invoke-Shell @('getconf', 'CLK_TCK')
    $clockTicks = Read-OneUnsignedInteger ([string[]]@($clockTicksResult.Lines)) `
        'The clock-tick probe'
    $uptimeResult = Invoke-Shell @('cat', '/proc/uptime')
    $uptimeRows = @($uptimeResult.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($uptimeRows.Count -eq 1 -and
            $uptimeRows[0] -cmatch '^(?<up>[0-9]+(?:\.[0-9]+)?)\s+[0-9]+(?:\.[0-9]+)?$') `
        'The device uptime probe was malformed.'
    [double]$uptimeSeconds = 0
    $parsedUptime = [double]::TryParse(
        [string]$Matches.up,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$uptimeSeconds)
    Require ($parsedUptime -and $uptimeSeconds -gt 0) `
        'The device uptime value was invalid.'
    $epochResult = Invoke-Shell @('date', '+%s')
    $epochSeconds = Read-OneUnsignedInteger ([string[]]@($epochResult.Lines)) `
        'The device clock probe'
    $startTicks = Get-ProcessStartTicks $ProcessId
    $startEpochSeconds = [double]$epochSeconds - $uptimeSeconds +
        ([double]$startTicks / [double]$clockTicks)
    Require ($startEpochSeconds -gt 0 -and
            $startEpochSeconds -le ([double]$epochSeconds + 3.0)) `
        'The computed process start time was impossible.'
    [pscustomobject]@{
        ProcessStartTicks = [uint64]$startTicks
        ProcessStartEpochSeconds = $startEpochSeconds
        DeviceEpochSeconds = [uint64]$epochSeconds
    }
}

function Test-GameJvm([int] $ProcessId) {
    $program = 'for f in /proc/' + $ProcessId +
        '/task/*/comm; do [ -r "$f" ] && cat "$f" 2>/dev/null || true; done'
    $result = Invoke-Shell @('sh', '-c', $program)
    $matches = @($result.Lines | Where-Object {
        ([string]$_).Trim() -ceq 'QuestCraft-JVM'
    })
    return $matches.Count -eq 1
}

function Assert-ProcessFence(
    [int] $ExpectedPid,
    [uint64] $ExpectedStartTicks,
    [string] $Context
) {
    Require ((Get-Pid $script:Package) -eq $ExpectedPid) "$Context PID changed."
    Require ((Get-ProcessStartTicks $ExpectedPid) -eq $ExpectedStartTicks) `
        "$Context process incarnation changed."
    Require (Test-GameJvm $ExpectedPid) "$Context game JVM was not observed."
    Require ($null -eq (Get-Pid $script:StablePackage -AllowMissing)) `
        "$Context rejected a concurrently running Stable process."
}

function Read-PackageIdentity([Parameter(Mandatory)][string[]] $Lines) {
    $versionCodes = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_,
            '^\s*versionCode=(?<value>[0-9]+)(?:\s|$)')
        if ($match.Success) { [int64]$match.Groups['value'].Value }
    })
    $versionNames = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_,
            '^\s*versionName=(?<value>\S+)\s*$')
        if ($match.Success) { [string]$match.Groups['value'].Value }
    })
    Require ($versionCodes.Count -eq 1 -and $versionNames.Count -eq 1) `
        'The installed application identity was incomplete or ambiguous.'
    [pscustomobject]@{
        VersionCode = [int64]$versionCodes[0]
        VersionName = [string]$versionNames[0]
    }
}

function Read-ExactBaseApkPath([Parameter(Mandatory)][string[]] $Lines) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and
            $rows[0] -cmatch
                '^package:(?<path>/data/app/(?:[A-Za-z0-9._~+=-]+/)+base\.apk)$') `
        'The installed application did not expose one safe base APK.'
    $path = [string]$Matches.path
    Require (-not $path.Contains('/../', [StringComparison]::Ordinal) -and
            -not $path.Contains('/./', [StringComparison]::Ordinal) -and
            $path -cmatch
            ('/' + [regex]::Escape($script:Package) + '(?:-|/)')) `
        'The installed base APK path was not bound to the isolated Lab application.'
    return $path
}

function Read-Sha256Sum(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $ExpectedPath
) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'An artifact digest probe was ambiguous.'
    $match = [regex]::Match($rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($match.Success -and
            [string]$match.Groups['path'].Value -ceq $ExpectedPath) `
        'An artifact digest probe named unexpected data.'
    return ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RemoteSha256([Parameter(Mandatory)][string] $Path) {
    $result = Invoke-Shell @('sha256sum', $Path)
    Read-Sha256Sum ([string[]]@($result.Lines)) $Path
}

function Assert-ExactDeviceIdentity {
    Require ($script:Package -ceq $script:LockedPackage -and
            $script:StablePackage -ceq $script:LockedStablePackage) `
        'The device identity target drifted from the fixed Lab application.'
    $packageResult = Invoke-Shell @('dumpsys', 'package', $script:Package)
    $identity = Read-PackageIdentity ([string[]]@($packageResult.Lines))
    Require ($identity.VersionCode -eq $script:LockedVersionCode -and
            $identity.VersionName -ceq $script:LockedVersionName) `
        'The installed application is not exact RC6.2.'
    $baseResult = Invoke-Shell @('pm', 'path', $script:Package)
    $basePath = Read-ExactBaseApkPath ([string[]]@($baseResult.Lines))
    Require ((Read-RemoteSha256 $basePath) -ceq $script:LockedApkSha256) `
        'The installed APK digest is not exact RC6.2.'
    Require ((Read-RemoteSha256 $script:CorePath) -ceq $script:LockedCoreSha256) `
        'The persistent Core digest is not exact RC6.2.'
    Require ((Read-RemoteSha256 $script:VeqPath) -ceq $script:LockedVeqSha256) `
        'The persistent companion digest is not exact RC6.2.'
    $packageResult = $null
    $baseResult = $null
    $basePath = $null
    [pscustomobject]@{
        InstalledVersionMatched = $true
        ApkMatched = $true
        CoreMatched = $true
        CompanionMatched = $true
        AllMatched = $true
    }
}

function Read-GameLogMetadata([Parameter(Mandatory)][string[]] $Lines) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1 -and
            $rows[0] -cmatch '^(?<size>[0-9]+)_(?<mtime>[0-9]+)_(?<ctime>[0-9]+)_(?<inode>[0-9]+)$') `
        'The runtime-log metadata probe was malformed.'
    [pscustomobject]@{
        SizeBytes = [int64]$Matches.size
        ModifiedEpochSeconds = [int64]$Matches.mtime
        ChangedEpochSeconds = [int64]$Matches.ctime
        Inode = [uint64]$Matches.inode
    }
}

function Get-GameLogMetadata {
    $stat = Invoke-Shell @('stat', '-c', '%s_%Y_%Z_%i', $script:GameLogPath)
    Read-GameLogMetadata ([string[]]@($stat.Lines))
}

function Assert-GameLogBoundToProcess(
    [Parameter(Mandatory)][object] $Metadata,
    [Parameter(Mandatory)][object] $ProcessAnchor,
    [uint64] $ExpectedInode = 0
) {
    Require ([int64]$Metadata.SizeBytes -gt 0 -and [uint64]$Metadata.Inode -gt 0) `
        'The expected runtime log was absent or empty.'
    Require ([int64]$Metadata.ModifiedEpochSeconds -ge
            [math]::Floor([double]$ProcessAnchor.ProcessStartEpochSeconds - 3.0) -and
            [int64]$Metadata.ChangedEpochSeconds -ge
            [math]::Floor([double]$ProcessAnchor.ProcessStartEpochSeconds - 3.0)) `
        'The expected runtime log belonged to another process launch.'
    if ($ExpectedInode -gt 0) {
        Require ([uint64]$Metadata.Inode -eq $ExpectedInode) `
            'The expected runtime log was replaced during the capture.'
    }
}

function Assert-InitiallyFreshGameLog(
    [Parameter(Mandatory)][object] $Metadata,
    [Parameter(Mandatory)][object] $ProcessAnchor,
    [uint64] $DeviceEpochSeconds
) {
    Assert-GameLogBoundToProcess $Metadata $ProcessAnchor
    Require ([int64]$Metadata.ModifiedEpochSeconds -le
                ([int64]$DeviceEpochSeconds + 2) -and
            [int64]$Metadata.ModifiedEpochSeconds -ge
                ([int64]$DeviceEpochSeconds - $script:GameLogFreshnessSeconds)) `
        'The expected runtime log was not fresh at the initial identity fence.'
}

function Read-ExactGameLogIdentity(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines
) {
    $minecraft = [Collections.Generic.List[string]]::new()
    $core = [Collections.Generic.List[string]]::new()
    $companion = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $text = [string]$line
        $match = [regex]::Match($text,
            '^(?:.*:\s)?Loading Minecraft (?<v>\S+) with Fabric Loader(?:\s+\S+)?\s*$')
        if ($match.Success) { $minecraft.Add([string]$match.Groups['v'].Value) }
        $match = [regex]::Match($text, '^(?:.*:\s)?\s*-\s+vivecraft\s+(?<v>\S+)\s*$')
        if ($match.Success) { $core.Add([string]$match.Groups['v'].Value) }
        $match = [regex]::Match($text,
            '^(?:.*:\s)?\s*-\s+vivecraft_essentials_quest\s+(?<v>\S+)\s*$')
        if ($match.Success) { $companion.Add([string]$match.Groups['v'].Value) }
    }
    Require ($minecraft.Count -eq 1 -and
            $minecraft[0] -ceq $script:LockedProfile -and
            $core.Count -eq 1 -and
            $core[0] -ceq '26.2-1.3.15+qc.v71.rc6.2' -and
            $companion.Count -eq 1 -and
            $companion[0] -ceq '0.7.0-v71.rc6') `
        'The live runtime text did not identify exact RC6.2.'
    [pscustomobject]@{
        MinecraftMatched = $true
        CoreMatched = $true
        CompanionMatched = $true
        AllMatched = $true
    }
}

function Assert-ExactRuntimeLog(
    [int] $ProcessId,
    [uint64] $ExpectedStartTicks,
    [Parameter(Mandatory)][object] $ProcessAnchor,
    [uint64] $ExpectedInode = 0
) {
    $before = Get-GameLogMetadata
    if ($ExpectedInode -eq 0) {
        $now = Invoke-Shell @('date', '+%s')
        $deviceEpoch = Read-OneUnsignedInteger ([string[]]@($now.Lines)) `
            'The runtime-log clock probe'
        Assert-InitiallyFreshGameLog $before $ProcessAnchor $deviceEpoch
    } else {
        Assert-GameLogBoundToProcess $before $ProcessAnchor $ExpectedInode
    }
    $content = Invoke-Adb @('-s', $script:Device, 'exec-out', 'cat', $script:GameLogPath)
    Require ($content.ExitCode -eq 0) 'The exact runtime identity probe failed.'
    $identity = Read-ExactGameLogIdentity ([string[]]@($content.Lines))
    $after = Get-GameLogMetadata
    Require ([uint64]$after.Inode -eq [uint64]$before.Inode -and
            [int64]$after.SizeBytes -ge [int64]$before.SizeBytes -and
            [int64]$after.ModifiedEpochSeconds -ge [int64]$before.ModifiedEpochSeconds) `
        'The runtime identity text changed incompatibly while it was read.'
    Assert-GameLogBoundToProcess $after $ProcessAnchor ([uint64]$before.Inode)
    Require ((Get-ProcessStartTicks $ProcessId) -eq $ExpectedStartTicks) `
        'The process incarnation changed during the runtime identity probe.'
    $content = $null
    return [pscustomobject]@{
        Metadata = $after
        IdentityMatched = [bool]$identity.AllMatched
    }
}

function Convert-MemoryNumbers([Parameter(Mandatory)][string] $Text) {
    $parts = @($Text.Trim() -split '\s+')
    Require ($parts.Count -eq 8 -or $parts.Count -eq 11) `
        'An expanded memory row had an unexpected column count.'
    $values = [Collections.Generic.List[int64]]::new()
    foreach ($part in $parts) {
        Require ($part -cmatch '^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)$') `
            'An expanded memory row contained a non-numeric cell.'
        [uint64]$value = 0
        $parsed = [uint64]::TryParse(($part -replace ',', ''), [ref]$value)
        Require ($parsed -and $value -le [uint32]::MaxValue) `
            'An expanded memory value was outside the accepted range.'
        $values.Add([int64]$value)
    }
    return $values.ToArray()
}

function Convert-ExpandedMemoryRow(
    [Parameter(Mandatory)][string] $Line,
    [Parameter(Mandatory)][string[]] $AllowedNames,
    [Parameter(Mandatory)][string] $Section
) {
    foreach ($name in @($AllowedNames | Sort-Object Length -Descending)) {
        $match = [regex]::Match($Line,
            '^\s*' + [regex]::Escape($name) + '\s+(?<values>[0-9][0-9,]*(?:\s+[0-9][0-9,]*){7,10})\s*$')
        if (-not $match.Success) { continue }
        $values = Convert-MemoryNumbers $match.Groups['values'].Value
        Require (($values.Count -eq 11) -eq
                ($name -cin @('Native Heap', 'Dalvik Heap', 'TOTAL'))) `
            'An expanded memory row used an invalid heap-column shape.'
        return [pscustomobject][ordered]@{
            section = $Section
            name = $name
            pssTotalKib = $values[0]
            pssCleanKib = $values[1]
            sharedDirtyKib = $values[2]
            privateDirtyKib = $values[3]
            sharedCleanKib = $values[4]
            privateCleanKib = $values[5]
            swapMetricKib = $values[6]
            rssTotalKib = $values[7]
            heapSizeKib = if ($values.Count -eq 11) { $values[8] } else { $null }
            heapAllocKib = if ($values.Count -eq 11) { $values[9] } else { $null }
            heapFreeKib = if ($values.Count -eq 11) { $values[10] } else { $null }
        }
    }
    throw 'An expanded memory table contained an unrecognized aggregate row.'
}

function Read-AppSummaryTotals(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][ValidateSet('SwapPss', 'Swap')][string] $ExpectedSwapKind
) {
    $totals = [Collections.Generic.List[object]]::new()
    $number = '(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)'
    foreach ($line in $Lines) {
        $match = [regex]::Match([string]$line,
            '(?:^|\s)TOTAL PSS:\s+(?<pss>' + $number + ')\s+' +
            'TOTAL RSS:\s+(?<rss>' + $number + ')\s+' +
            'TOTAL SWAP (?<swapKind>PSS|\(KB\)):\s+(?<swap>' + $number + ')\s*$')
        if ($match.Success) {
            $summarySwapKind = if ($match.Groups['swapKind'].Value -ceq 'PSS') {
                'SwapPss'
            } else {
                'Swap'
            }
            Require ($summarySwapKind -ceq $ExpectedSwapKind) `
                'The App Summary swap metric disagreed with the expanded table header.'
            $totals.Add([pscustomobject]@{
                Pss = [int64]($match.Groups['pss'].Value -replace ',', '')
                Rss = [int64]($match.Groups['rss'].Value -replace ',', '')
                Swap = [int64]($match.Groups['swap'].Value -replace ',', '')
            })
        }
    }
    Require ($totals.Count -eq 1) 'The App Summary totals were absent or ambiguous.'
    return $totals[0]
}

function Read-ExpandedMeminfoAggregates(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines,
    [int] $ExpectedPid,
    [Parameter(Mandatory)][string] $ExpectedProcessName
) {
    $headers = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_,
            '^\s*\*\* MEMINFO in pid (?<pid>[0-9]+) \[(?<name>[^\]\r\n]+)\] \*\*\s*$')
        if ($match.Success) { $match }
    })
    Require ($headers.Count -eq 1 -and
            [int]$headers[0].Groups['pid'].Value -eq $ExpectedPid -and
            [string]$headers[0].Groups['name'].Value -ceq $ExpectedProcessName) `
        'The expanded memory response was not bound to the expected process.'

    $appSummaryIndexes = @()
    $dalvikDetailIndexes = @()
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $trimmed = ([string]$Lines[$index]).Trim()
        if ($trimmed -ceq 'App Summary') { $appSummaryIndexes += $index }
        if ($trimmed -ceq 'Dalvik Details') { $dalvikDetailIndexes += $index }
    }
    Require ($appSummaryIndexes.Count -eq 1 -and $dalvikDetailIndexes.Count -eq 1 -and
            $dalvikDetailIndexes[0] -lt $appSummaryIndexes[0]) `
        'The expanded memory response omitted its unique aggregate sections.'

    $separatorIndexes = @()
    for ($index = 2; $index -lt $dalvikDetailIndexes[0]; $index++) {
        $cells = @(([string]$Lines[$index]).Trim() -split '\s+')
        if ($cells.Count -eq 11 -and
                @($cells | Where-Object { $_ -cne '------' }).Count -eq 0) {
            $separatorIndexes += $index
        }
    }
    Require ($separatorIndexes.Count -eq 1) `
        'The expanded memory response omitted its full-column table header.'
    $separator = [int]$separatorIndexes[0]
    Require ($separator -ge 2) `
        'The expanded memory columns were not recognized.'
    $headerTop = @(([string]$Lines[$separator - 2]).Trim() -split '\s+')
    $headerBottom = @(([string]$Lines[$separator - 1]).Trim() -split '\s+')
    Require ($headerTop.Count -eq 11 -and $headerBottom.Count -eq 11) `
        'The expanded memory header had an unexpected column count.'
    $expectedHeaderTop = @(
        'Pss', 'Pss', 'Shared', 'Private', 'Shared', 'Private',
        $headerTop[6], 'Rss', 'Heap', 'Heap', 'Heap'
    )
    $expectedHeaderBottom = @(
        'Total', 'Clean', 'Dirty', 'Dirty', 'Clean', 'Clean',
        'Dirty', 'Total', 'Size', 'Alloc', 'Free'
    )
    Require ((($headerTop -join [char]0) -ceq
                ($expectedHeaderTop -join [char]0)) -and
            (($headerBottom -join [char]0) -ceq
                ($expectedHeaderBottom -join [char]0)) -and
            $headerTop[6] -cin @('SwapPss', 'Swap')) `
        'The expanded memory columns were not recognized in exact order.'
    $swapKind = if ($headerTop[6] -ceq 'SwapPss') {
        'SwapPss'
    } elseif ($headerTop[6] -ceq 'Swap') {
        'Swap'
    } else {
        throw 'The expanded memory swap column was not identified.'
    }

    $mainRows = [Collections.Generic.List[object]]::new()
    $mainNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    for ($index = $separator + 1; $index -lt $dalvikDetailIndexes[0]; $index++) {
        $line = [string]$Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = Convert-ExpandedMemoryRow $line $script:MainRowNames 'aggregate'
        Require ($mainNames.Add([string]$row.name)) `
            'The expanded aggregate table repeated a row name.'
        $mainRows.Add($row)
    }
    Require ($mainRows.Count -ge 4 -and
            $mainNames.Contains('Native Heap') -and
            $mainNames.Contains('Dalvik Heap') -and
            $mainNames.Contains('Unknown') -and
            $mainNames.Contains('TOTAL') -and
            [string]$mainRows[$mainRows.Count - 1].name -ceq 'TOTAL') `
        'The expanded aggregate table was incomplete or reordered unsafely.'

    $detailRows = [Collections.Generic.List[object]]::new()
    $detailNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    for ($index = $dalvikDetailIndexes[0] + 1; $index -lt $appSummaryIndexes[0]; $index++) {
        $line = [string]$Lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = Convert-ExpandedMemoryRow $line $script:DalvikDetailRowNames 'dalvikDetail'
        Require ($detailNames.Add([string]$row.name)) `
            'The expanded Dalvik table repeated a row name.'
        $detailRows.Add($row)
    }
    Require ($detailRows.Count -ge 1) `
        'The requested expanded response contained no Dalvik detail row.'

    $summaryTotals = Read-AppSummaryTotals $Lines $swapKind
    $total = @($mainRows | Where-Object { $_.name -ceq 'TOTAL' })[0]
    Require ([int64]$total.pssTotalKib -eq [int64]$summaryTotals.Pss -and
            [int64]$total.rssTotalKib -eq [int64]$summaryTotals.Rss -and
            [int64]$total.swapMetricKib -eq [int64]$summaryTotals.Swap) `
        'The aggregate TOTAL row disagreed with App Summary.'

    [pscustomobject][ordered]@{
        swapMetricKind = $swapKind
        aggregateRows = $mainRows.ToArray()
        dalvikDetailRows = $detailRows.ToArray()
        totalsCrossChecked = $true
    }
}

function Assert-NoHostReparsePoint(
    [Parameter(Mandatory)][string] $CandidateDirectory
) {
    $relative = [IO.Path]::GetRelativePath($script:RepoRoot, $CandidateDirectory)
    Require (-not [IO.Path]::IsPathRooted($relative) -and
            $relative -cne '..' -and
            -not $relative.StartsWith(
                '..' + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::Ordinal)) `
        'The Host output ancestry escaped the repository.'
    $cursor = $script:RepoRoot
    $rootItem = Get-Item -LiteralPath $cursor -Force
    Require ($rootItem.PSIsContainer -and
            -not ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) `
        'The repository root was a reparse point.'
    foreach ($segment in @($relative.Split(
                [char[]]@(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar),
                [StringSplitOptions]::RemoveEmptyEntries))) {
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { continue }
        $item = Get-Item -LiteralPath $cursor -Force
        Require ($item.PSIsContainer -and
                -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) `
            'The Host output ancestry contained a reparse point.'
    }
}

function Resolve-SafeOutputDirectory {
    Require (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) `
        'Capture requires an explicit -OutputDirectory.'
    $base = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'artifacts\memory'))
    $candidate = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
        [IO.Path]::GetFullPath($OutputDirectory)
    } else {
        [IO.Path]::GetFullPath((Join-Path $script:RepoRoot $OutputDirectory))
    }
    $prefix = $base.TrimEnd([IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    Require ($candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) `
        'Output must be a new child directory under artifacts/memory.'
    Assert-NoHostReparsePoint $candidate
    Require (-not (Test-Path -LiteralPath $candidate)) `
        'The output directory already exists; refusing to overwrite evidence.'
    return $candidate
}

function New-SanitizedSample(
    [int] $Index,
    [datetime] $StartedUtc,
    [Parameter(Mandatory)][object] $Parsed
) {
    [pscustomobject][ordered]@{
        index = $Index
        observedUtc = [DateTime]::UtcNow.ToString('o')
        elapsedSeconds = [math]::Round(
            ([DateTime]::UtcNow - $StartedUtc).TotalSeconds, 3)
        pidFencePassed = $true
        processStartFencePassed = $true
        gameJvmFencePassed = $true
        stableAbsent = $true
        runtimeLogBoundToProcessLaunch = $true
        swapMetricKind = [string]$Parsed.swapMetricKind
        totalsCrossChecked = [bool]$Parsed.totalsCrossChecked
        aggregateRows = @($Parsed.aggregateRows)
        dalvikDetailRows = @($Parsed.dalvikDetailRows)
    }
}

function Get-SanitizedSample(
    [int] $Index,
    [datetime] $StartedUtc,
    [int] $ExpectedPid,
    [uint64] $ExpectedStartTicks,
    [uint64] $ExpectedGameLogInode
) {
    Assert-ProcessFence $ExpectedPid $ExpectedStartTicks 'The pre-sample fence'
    $anchor = Get-ProcessAnchor $ExpectedPid
    Require ([uint64]$anchor.ProcessStartTicks -eq $ExpectedStartTicks) `
        'The process incarnation changed before the memory probe.'
    $metadata = Get-GameLogMetadata
    Assert-GameLogBoundToProcess $metadata $anchor $ExpectedGameLogInode
    $result = Invoke-Shell @(
        'dumpsys', 'meminfo', '-a', '--local', [string]$ExpectedPid)
    $parsed = Read-ExpandedMeminfoAggregates ([string[]]@($result.Lines)) `
        $ExpectedPid $script:Package
    Assert-ProcessFence $ExpectedPid $ExpectedStartTicks 'The post-sample fence'
    $afterMetadata = Get-GameLogMetadata
    Assert-GameLogBoundToProcess $afterMetadata $anchor $ExpectedGameLogInode
    $sample = New-SanitizedSample $Index $StartedUtc $parsed
    $result = $null
    $parsed = $null
    return $sample
}

function New-RowTrends([Parameter(Mandatory)][object[]] $Samples) {
    $groups = @{}
    foreach ($sample in $Samples) {
        foreach ($row in @($sample.aggregateRows) + @($sample.dalvikDetailRows)) {
            $key = [string]$row.section + [char]0 + [string]$row.name
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = [Collections.Generic.List[object]]::new()
            }
            $groups[$key].Add($row)
        }
    }
    $trends = [Collections.Generic.List[object]]::new()
    foreach ($key in @($groups.Keys | Sort-Object)) {
        $rows = $groups[$key]
        $first = $rows[0]
        $last = $rows[$rows.Count - 1]
        $pssValues = @($rows | ForEach-Object { [int64]$_.pssTotalKib })
        $rssValues = @($rows | ForEach-Object { [int64]$_.rssTotalKib })
        $trends.Add([pscustomobject][ordered]@{
            section = [string]$first.section
            name = [string]$first.name
            observedSamples = $rows.Count
            firstPssKib = [int64]$first.pssTotalKib
            lastPssKib = [int64]$last.pssTotalKib
            deltaPssKib = [int64]$last.pssTotalKib - [int64]$first.pssTotalKib
            minPssKib = [int64]($pssValues | Measure-Object -Minimum).Minimum
            maxPssKib = [int64]($pssValues | Measure-Object -Maximum).Maximum
            firstRssKib = [int64]$first.rssTotalKib
            lastRssKib = [int64]$last.rssTotalKib
            deltaRssKib = [int64]$last.rssTotalKib - [int64]$first.rssTotalKib
            minRssKib = [int64]($rssValues | Measure-Object -Minimum).Minimum
            maxRssKib = [int64]($rssValues | Measure-Object -Maximum).Maximum
        })
    }
    return $trends.ToArray()
}

function Assert-SanitizedReceipt(
    [Parameter(Mandatory)][object] $Receipt,
    [Parameter(Mandatory)][string] $Json
) {
    $allowedTopLevel = @(
        'schemaVersion', 'receiptType', 'classification', 'candidate',
        'producerSha256', 'buildLockSha256', 'startedUtc', 'completedUtc',
        'requestedDurationMinutes', 'intervalSeconds', 'actualDurationSeconds',
        'minimumExpectedSamples', 'sampleCount', 'identityFence', 'processFence',
        'samples', 'rowTrends', 'evidenceBoundary'
    )
    $actual = @($Receipt.PSObject.Properties.Name)
    Require (@($actual | Where-Object { $_ -cnotin $allowedTopLevel }).Count -eq 0 -and
            @($allowedTopLevel | Where-Object { $_ -cnotin $actual }).Count -eq 0) `
        'The receipt top-level schema contained an unexpected field.'
    Require (-not $Json.Contains($script:Package, [StringComparison]::Ordinal) -and
            -not $Json.Contains($script:StablePackage, [StringComparison]::Ordinal) -and
            ([string]::IsNullOrWhiteSpace($script:Device) -or
                -not $Json.Contains($script:Device, [StringComparison]::Ordinal)) -and
            -not $Json.Contains('/sdcard/', [StringComparison]::Ordinal) -and
            -not $Json.Contains('/data/', [StringComparison]::Ordinal)) `
        'The receipt serialization contained a prohibited identifier or path.'
    Require ([bool]$Receipt.evidenceBoundary.aggregateNumbersOnly -and
            -not [bool]$Receipt.evidenceBoundary.rawDeviceTextPersisted -and
            -not [bool]$Receipt.evidenceBoundary.identifiersOrPathsPersisted -and
            -not [bool]$Receipt.evidenceBoundary.deviceWriteCommandsIssued -and
            -not [bool]$Receipt.evidenceBoundary.targetProcessCallbackRequested -and
            -not [bool]$Receipt.evidenceBoundary.targetGcRequested) `
        'The receipt evidence boundary was not fail-closed.'
}

function Write-ReceiptAtomically(
    [Parameter(Mandatory)][string] $Directory,
    [Parameter(Mandatory)][string] $Json
) {
    Require $AllowHostOutput.IsPresent `
        'Capture requires explicit -AllowHostOutput.'
    Assert-NoHostReparsePoint $Directory
    Require (-not (Test-Path -LiteralPath $Directory)) `
        'The output directory appeared during capture; refusing to overwrite it.'
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    Assert-NoHostReparsePoint $Directory
    $temporary = Join-Path $Directory `
        ('.expanded-meminfo-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $final = Join-Path $Directory 'expanded-meminfo-aggregates.json'
    try {
        [IO.File]::WriteAllText($temporary, $Json + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false))
        $script:HostWrites++
        [IO.File]::Move($temporary, $final)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return $final
}

function Get-ParserFixture([int] $ProcessId, [string] $ProcessName) {
    @(
        'Applications Memory Usage (in Kilobytes):',
        "** MEMINFO in pid $ProcessId [$ProcessName] **",
        '                     Pss      Pss   Shared  Private   Shared  Private  SwapPss      Rss     Heap     Heap     Heap',
        '                   Total    Clean    Dirty    Dirty    Clean    Clean    Dirty    Total     Size    Alloc     Free',
        '                  ------   ------   ------   ------   ------   ------   ------   ------   ------   ------   ------',
        '    Native Heap  1,200,000     1024        0  900000        0      128        4  950000        0        0        0',
        '    Dalvik Heap     24576      256       16    12000       32       64        0    30000        0        0        0',
        '   Dalvik Other      8192      128        0     7000        0       16        0     9000',
        '          Stack      4096        0        0     4096        0        0        0     4096',
        '       .so mmap     16000     8000       64     1000    12000     2000        0    40000',
        '      Gfx driver    700000        0        0   700000        0        0        0   700000',
        '        Unknown    100000      100       10    50000       20      100        1   150000',
        '          TOTAL  2,052,864     9508       90  1674096    12052     2308        5  1883096        0        0        0',
        ' ',
        ' Dalvik Details',
        '          .Heap     12000      100        0     9000        0        0        0    14000',
        '           .LOS      2000        0        0     1800        0        0        0     2100',
        '       .App dex      1000      500        0      100      700      100        0     3000',
        ' ',
        ' App Summary',
        '                       Pss(KB)                        Rss(KB)',
        '                        ------                         ------',
        '           Java Heap:    12000                          30000',
        '         Native Heap:   900000                         950000',
        ' ',
        '            TOTAL PSS: 2,052,864      TOTAL RSS: 1,883,096      TOTAL SWAP PSS:        5',
        ' ',
        ' Objects',
        '               Views:       99         ViewRootImpl:        1',
        ' DATABASES',
        '      pgsz     dbsz   Lookaside(b)          cache  Dbname',
        '         4       20             64       10/20/3  /data/user/0/private/account@example.test/worlds/private-world/server.example.db'
    )
}

function Invoke-SelfTest {
    Require ($Action -eq 'SelfTest') 'The Host self-test action was not selected.'
    Require ($DurationMinutes -eq 12 -and $IntervalSeconds -eq 60) `
        'The short-capture defaults drifted.'
    $fixturePid = 4242
    $fixture = Get-ParserFixture $fixturePid $script:Package
    $parsed = Read-ExpandedMeminfoAggregates $fixture $fixturePid $script:Package
    Require ([string]$parsed.swapMetricKind -ceq 'SwapPss' -and
            $parsed.aggregateRows.Count -eq 8 -and
            $parsed.dalvikDetailRows.Count -eq 3 -and
            [bool]$parsed.totalsCrossChecked) `
        'The expanded aggregate fixture did not parse completely.'
    $native = @($parsed.aggregateRows | Where-Object { $_.name -ceq 'Native Heap' })[0]
    $total = @($parsed.aggregateRows | Where-Object { $_.name -ceq 'TOTAL' })[0]
    Require ([int64]$native.pssTotalKib -eq 1200000 -and
            [int64]$native.heapSizeKib -eq 0 -and
            [int64]$native.heapAllocKib -eq 0 -and
            [int64]$native.heapFreeKib -eq 0 -and
            [int64]$total.pssTotalKib -eq 2052864 -and
            [int64]$total.rssTotalKib -eq 1883096 -and
            [int64]$total.heapSizeKib -eq 0 -and
            [int64]$total.heapAllocKib -eq 0 -and
            [int64]$total.heapFreeKib -eq 0) `
        'The expanded aggregate numeric mapping drifted.'
    $swapFixture = @($fixture)
    $swapFixture[2] = $swapFixture[2].Replace('SwapPss', 'Swap   ')
    $swapTotalIndex = [array]::FindIndex([string[]]$swapFixture,
        [Predicate[string]]{ param($line) $line -cmatch '^\s*TOTAL PSS:' })
    Require ($swapTotalIndex -ge 0) 'The swap-column fixture was malformed.'
    $swapFixture[$swapTotalIndex] = $swapFixture[$swapTotalIndex].Replace(
        'TOTAL SWAP PSS:', 'TOTAL SWAP (KB):')
    $swapParsed = Read-ExpandedMeminfoAggregates $swapFixture $fixturePid `
        $script:Package
    Require ([string]$swapParsed.swapMetricKind -ceq 'Swap') `
        'The non-proportional swap column was not recognized.'
    Require ((Read-ProcessStartTicks @(
                '4242 (name with ) parentheses) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 123456 20'
            )) -eq 123456) 'The process-incarnation parser self-test failed.'

    $logAnchor = [pscustomobject]@{ ProcessStartEpochSeconds = 1000000.0 }
    $quietLog = [pscustomobject]@{
        SizeBytes = 4096
        ModifiedEpochSeconds = 1000010
        ChangedEpochSeconds = 1000010
        Inode = [uint64]7001
    }
    Assert-GameLogBoundToProcess $quietLog $logAnchor 7001
    Require (Test-Throws {
            Assert-InitiallyFreshGameLog $quietLog $logAnchor 1000200
        }) 'The deliberately stale initial-log fixture was accepted.'
    $freshLog = [pscustomobject]@{
        SizeBytes = 4096
        ModifiedEpochSeconds = 1000190
        ChangedEpochSeconds = 1000190
        Inode = [uint64]7001
    }
    Assert-InitiallyFreshGameLog $freshLog $logAnchor 1000200
    Require (Test-Throws {
            Assert-GameLogBoundToProcess $quietLog $logAnchor 7002
        }) 'The replaced runtime-log fixture was accepted.'

    $wrongPid = @($fixture)
    $wrongPid[1] = "** MEMINFO in pid 4243 [$($script:Package)] **"
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $wrongPid $fixturePid $script:Package | Out-Null
        }) 'The wrong-PID fixture was accepted.'
    $wrongProcess = @($fixture)
    $wrongProcess[1] = "** MEMINFO in pid $fixturePid [$($script:StablePackage)] **"
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $wrongProcess $fixturePid $script:Package | Out-Null
        }) 'The wrong-process fixture was accepted.'
    $unknownRow = @($fixture)
    $unknownRow[7] = '   hidden/path     8192      128        0     7000        0       16        0     9000'
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $unknownRow $fixturePid $script:Package | Out-Null
        }) 'An unrecognized aggregate label was accepted.'
    $reorderedHeader = @($fixture)
    $reorderedHeader[3] = $reorderedHeader[3].Replace(
        'Total    Clean', 'Clean    Total')
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $reorderedHeader $fixturePid `
                $script:Package | Out-Null
        }) 'A reordered expanded-memory header was accepted.'
    $malformedGrouping = @($fixture)
    $malformedGrouping[5] = $malformedGrouping[5].Replace(
        '1,200,000', '1,,200000')
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $malformedGrouping $fixturePid `
                $script:Package | Out-Null
        }) 'A malformed numeric grouping was accepted.'
    $malformedSummaryGrouping = @($fixture)
    $malformedSummaryIndex = [array]::FindIndex([string[]]$malformedSummaryGrouping,
        [Predicate[string]]{ param($line) $line -cmatch '^\s*TOTAL PSS:' })
    Require ($malformedSummaryIndex -ge 0) `
        'The App Summary grouping fixture was malformed.'
    $malformedSummaryGrouping[$malformedSummaryIndex] =
        $malformedSummaryGrouping[$malformedSummaryIndex].Replace('2,052,864', '2,05,2864')
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $malformedSummaryGrouping $fixturePid `
                $script:Package | Out-Null
        }) 'A malformed App Summary numeric grouping was accepted.'
    $wrongSummarySwapKind = @($fixture)
    $wrongSummarySwapKind[$malformedSummaryIndex] =
        $wrongSummarySwapKind[$malformedSummaryIndex].Replace(
            'TOTAL SWAP PSS:', 'TOTAL SWAP (KB):')
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $wrongSummarySwapKind $fixturePid `
                $script:Package | Out-Null
        }) 'An App Summary swap metric that disagreed with the header was accepted.'
    $badTotal = @($fixture)
    $badTotalIndex = [array]::FindIndex([string[]]$badTotal,
        [Predicate[string]]{ param($line) $line -match '^\s*TOTAL PSS:' })
    Require ($badTotalIndex -ge 0) 'The App Summary fixture total was not found.'
    $badTotal[$badTotalIndex] = '            TOTAL PSS: 2,052,863      TOTAL RSS: 1,883,096      TOTAL SWAP PSS:        5'
    Require (Test-Throws {
            Read-ExpandedMeminfoAggregates $badTotal $fixturePid $script:Package | Out-Null
        }) 'A mismatched App Summary total was accepted.'

    $sample = New-SanitizedSample 0 ([DateTime]::UtcNow) $parsed
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_EXPANDED_MEMINFO_AGGREGATES'
        classification = 'SUPPLEMENTARY_DIAGNOSTIC_ONLY'
        candidate = 'RC6.2'
        producerSha256 = Get-NormalizedTextSha256 $PSCommandPath
        buildLockSha256 = $script:ExpectedBuildLockSha256
        startedUtc = [DateTime]::UtcNow.ToString('o')
        completedUtc = [DateTime]::UtcNow.ToString('o')
        requestedDurationMinutes = 12
        intervalSeconds = 60
        actualDurationSeconds = 720.0
        minimumExpectedSamples = 13
        sampleCount = 1
        identityFence = [pscustomobject]@{ startPassed = $true; finalPassed = $true }
        processFence = [pscustomobject]@{
            samePid = $true
            sameProcessStart = $true
            everySamplePassed = $true
        }
        samples = @($sample)
        rowTrends = @(New-RowTrends @($sample))
        evidenceBoundary = [pscustomobject]@{
            aggregateNumbersOnly = $true
            rawDeviceTextPersisted = $false
            identifiersOrPathsPersisted = $false
            deviceWriteCommandsIssued = $false
            targetProcessCallbackRequested = $false
            targetGcRequested = $false
            heapCapacityColumnsUnavailableInLocalMode = $true
        }
    }
    $json = $receipt | ConvertTo-Json -Depth 12
    $previousDevice = $script:Device
    $script:Device = 'fixture-device-serial-7001'
    try {
        Assert-SanitizedReceipt $receipt $json
    } finally {
        $script:Device = $previousDevice
    }
    Require (-not $json.Contains('fixture-device-serial-7001',
            [StringComparison]::Ordinal)) `
        'A device endpoint escaped into the sanitized receipt.'
    Require (-not $json.Contains(
                '/data/user/0/private/account@example.test/worlds/private-world/server.example.db',
                [StringComparison]::Ordinal) -and
            -not $json.Contains('account@example.test',
                [StringComparison]::Ordinal) -and
            -not $json.Contains('private-world',
                [StringComparison]::Ordinal) -and
            -not $json.Contains('server.example',
                [StringComparison]::Ordinal)) `
        'Unfiltered path, account, world, or server text escaped into the receipt.'
    Require ($script:DeviceInvocations -eq 0 -and $script:HostWrites -eq 0) `
        'The default SelfTest touched a device or wrote an artifact.'

    [pscustomobject][ordered]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = $script:DeviceInvocations
        HostWrites = $script:HostWrites
        Assertions = $script:Assertions
        DefaultAction = 'SelfTest'
        DefaultDurationMinutes = 12
        AllowedDurationMinutes = '10-15'
        DefaultIntervalSeconds = 60
        ExpandedCommand = 'dumpsys meminfo -a --local <pid>'
        LocalOnlyMeminfoCovered = $true
        TargetGcAvoidanceCovered = $true
        SilentRuntimeLogFixturePassed = $true
        AggregateParserPassed = $true
        DalvikDetailParserPassed = $true
        TotalCrossCheckPassed = $true
        PidFenceCovered = $true
        ProcessStartFenceCovered = $true
        ExactRc62LockCovered = $true
        SanitizedReceiptCovered = $true
        RawRowsDiscarded = $true
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    return
}

Require $AllowDeviceRead.IsPresent 'Capture requires explicit -AllowDeviceRead.'
Require $AllowHostOutput.IsPresent 'Capture requires explicit -AllowHostOutput.'
$safeOutputDirectory = Resolve-SafeOutputDirectory
Resolve-Device

$producerSha256 = Get-NormalizedTextSha256 $PSCommandPath
$producerReadLock = [IO.File]::Open($PSCommandPath, [IO.FileMode]::Open,
    [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    Require ($producerSha256 -cmatch '^[0-9A-F]{64}$') `
        'The producer digest could not be fixed for the capture.'
    Require ($null -eq (Get-Pid $script:StablePackage -AllowMissing)) `
        'Stable is running; end it manually before this isolated read-only capture.'
    $initialPid = Get-Pid $script:Package
    $initialAnchor = Get-ProcessAnchor $initialPid
    $initialStartTicks = [uint64]$initialAnchor.ProcessStartTicks
    Assert-ProcessFence $initialPid $initialStartTicks 'The initial pre-identity fence'
    $initialIdentity = Assert-ExactDeviceIdentity
    Assert-ProcessFence $initialPid $initialStartTicks 'The initial post-identity fence'
    $initialRuntime = Assert-ExactRuntimeLog $initialPid $initialStartTicks `
        $initialAnchor
    $gameLogInode = [uint64]$initialRuntime.Metadata.Inode
    Assert-ProcessFence $initialPid $initialStartTicks 'The initial runtime fence'

    $startedUtc = [DateTime]::UtcNow
    $deadline = $startedUtc.AddMinutes($DurationMinutes)
    $samples = [Collections.Generic.List[object]]::new()
    $sampleIndex = 0
    while ($true) {
        $samples.Add((Get-SanitizedSample $sampleIndex $startedUtc $initialPid `
            $initialStartTicks $gameLogInode))
        if ([DateTime]::UtcNow -ge $deadline) { break }
        $sampleIndex++
        $nextTarget = $startedUtc.AddSeconds($sampleIndex * $IntervalSeconds)
        if ($nextTarget -gt $deadline) { $nextTarget = $deadline }
        while ([DateTime]::UtcNow -lt $nextTarget) {
            $remaining = ($nextTarget - [DateTime]::UtcNow).TotalMilliseconds
            Start-Sleep -Milliseconds ([int][math]::Max(1, [math]::Min(5000, $remaining)))
        }
    }

    Assert-ProcessFence $initialPid $initialStartTicks 'The final pre-identity fence'
    $finalAnchor = Get-ProcessAnchor $initialPid
    Require ([uint64]$finalAnchor.ProcessStartTicks -eq $initialStartTicks) `
        'The process incarnation changed before the final identity fence.'
    $finalRuntime = Assert-ExactRuntimeLog $initialPid $initialStartTicks `
        $finalAnchor $gameLogInode
    $finalIdentity = Assert-ExactDeviceIdentity
    Assert-ProcessFence $initialPid $initialStartTicks 'The final post-identity fence'

    $completedUtc = [DateTime]::UtcNow
    $minimumExpectedSamples = [int][math]::Ceiling(
        ($DurationMinutes * 60.0) / $IntervalSeconds) + 1
    Require ($samples.Count -ge $minimumExpectedSamples -and
            ($completedUtc - $startedUtc).TotalMinutes -ge $DurationMinutes -and
            [bool]$initialIdentity.AllMatched -and [bool]$finalIdentity.AllMatched -and
            [bool]$initialRuntime.IdentityMatched -and
            [bool]$finalRuntime.IdentityMatched) `
        'The bounded capture did not complete every required fence and sample.'

    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_EXPANDED_MEMINFO_AGGREGATES'
        classification = 'SUPPLEMENTARY_DIAGNOSTIC_ONLY'
        candidate = 'RC6.2'
        producerSha256 = $producerSha256
        buildLockSha256 = $script:ExpectedBuildLockSha256
        startedUtc = $startedUtc.ToString('o')
        completedUtc = $completedUtc.ToString('o')
        requestedDurationMinutes = $DurationMinutes
        intervalSeconds = $IntervalSeconds
        actualDurationSeconds = [math]::Round(
            ($completedUtc - $startedUtc).TotalSeconds, 3)
        minimumExpectedSamples = $minimumExpectedSamples
        sampleCount = $samples.Count
        identityFence = [pscustomobject][ordered]@{
            immutableBuildLockMatched = $true
            installedVersionMatchedAtStartAndFinal = $true
            apkMatchedAtStartAndFinal = $true
            coreMatchedAtStartAndFinal = $true
            companionMatchedAtStartAndFinal = $true
            runtimeVersionsMatchedAtStartAndFinal = $true
            runtimeLogFreshAtInitialFence = $true
            runtimeLogStayedBoundToProcessLaunch = $true
        }
        processFence = [pscustomobject][ordered]@{
            samePid = $true
            sameProcessStart = $true
            gameJvmObservedAtEveryFence = $true
            stableAbsentAtEveryFence = $true
            everySamplePassed = $true
        }
        samples = $samples.ToArray()
        rowTrends = @(New-RowTrends $samples.ToArray())
        evidenceBoundary = [pscustomobject][ordered]@{
            aggregateNumbersOnly = $true
            rawDeviceTextPersisted = $false
            identifiersOrPathsPersisted = $false
            deviceWriteCommandsIssued = $false
            targetProcessCallbackRequested = $false
            targetGcRequested = $false
            heapCapacityColumnsUnavailableInLocalMode = $true
            formalMemoryResultChanged = $false
            promotionAuthorized = $false
        }
    }
    $json = $receipt | ConvertTo-Json -Depth 12
    Assert-SanitizedReceipt $receipt $json
    $writtenPath = Write-ReceiptAtomically $safeOutputDirectory $json
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Classification = 'SUPPLEMENTARY_DIAGNOSTIC_ONLY'
        Samples = $samples.Count
        DurationMinutes = [math]::Round(
            ($completedUtc - $startedUtc).TotalMinutes, 3)
        OutputFileName = [IO.Path]::GetFileName($writtenPath)
        DeviceQueriesOnly = $true
        DeviceWriteCommandsIssued = $false
        TargetProcessCallbackRequested = $false
        TargetGcRequested = $false
    }
} finally {
    $producerReadLock.Dispose()
}
