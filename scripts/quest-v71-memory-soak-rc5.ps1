<#
.SYNOPSIS
Records a read-only long-duration memory profile for the fixed v71 Lab app.

.DESCRIPTION
The sampler is pinned to com.qcxr.qcxr.canary262. It never launches, stops,
installs, clears, or writes to either QuestCraft package. Every five minutes it
records process PSS/RSS/swap plus Android MemAvailable/SwapFree. Output contains
no account, world, or server identifiers. The exact 26.2 latest.log is checked
at bounded identity fences and for freshness at every sample; its text is never
persisted.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Sample')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [ValidateRange(30, 180)]
    [int] $DurationMinutes = 90,

    [ValidateRange(60, 900)]
    [int] $IntervalSeconds = 300,

    [string] $OutputDirectory = '',

    [switch] $AllowDeviceRead,
    [switch] $AllowRootRead
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Rc5LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC5.lock.json'
$script:Rc5Lock = Get-Content -Raw -LiteralPath $script:Rc5LockPath | ConvertFrom-Json
$script:EvidenceContractPath = Join-Path $script:RepoRoot `
    'V71_RC5_EVIDENCE_PRODUCERS.lock.json'
$script:EvidenceContract = Get-Content -Raw -LiteralPath `
    $script:EvidenceContractPath | ConvertFrom-Json
$script:ExpectedVersionCode = [int]$script:Rc5Lock.target.versionCode
$script:ExpectedVersionName = [string]$script:Rc5Lock.target.versionName
$script:ExpectedBaseApkSha256 = [string]$script:Rc5Lock.target.apkSha256
$script:ExpectedCoreSha256 = [string]$script:Rc5Lock.pair.core.sha256
$script:ExpectedVeqSha256 = [string]$script:Rc5Lock.pair.veq.sha256
$script:ExpectedGameLogRelativePath = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogRelativePath
$script:ExpectedMinecraftVersion = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogMinecraftVersion
$script:ExpectedCoreVersion = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogCoreVersion
$script:ExpectedVeqVersion = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogVeqVersion
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/26.2"
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:GameLogPath = "/sdcard/Android/data/$($script:Package)/files/" +
    $script:ExpectedGameLogRelativePath
# RC5 writes an OpenXR progress line every 600 submitted frames. Sixty seconds
# tolerates brief stalls while still rejecting a live JVM using another profile.
$script:GameLogFreshnessSeconds = 60
$script:RequiredMetricNames = @(
    'totalPssKib',
    'totalRssKib',
    'javaHeapKib',
    'nativeHeapKib',
    'graphicsKib',
    'vmRssKib',
    'vmSwapKib',
    'memAvailableKib',
    'swapFreeKib'
)
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0
$script:Assertions = 0
$script:ProducerSha256 = $null
$script:ProducerReadLock = [IO.File]::Open($PSCommandPath, [IO.FileMode]::Open,
    [IO.FileAccess]::Read, [IO.FileShare]::Read)

function Require([bool] $Condition, [string] $Message) {
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}

function Assert-ExpectedGameLogContract {
    $binding = $script:Rc5Lock.runtimeBinding
    Require ($null -ne $binding -and
        [string]$binding.expectedGameLogRelativePath -ceq
            'instances/26.2/logs/latest.log' -and
        [string]$binding.expectedGameLogMinecraftVersion -ceq '26.2' -and
        [string]$binding.expectedGameLogCoreVersion -ceq $script:ExpectedCoreVersion -and
        [string]$binding.expectedGameLogVeqVersion -ceq $script:ExpectedVeqVersion) `
        'The RC5 expectedGameLog binding is incomplete or targets another profile/version.'
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($text)))
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    return $quote + $Value.Replace($quote, $quote + '"' + $quote + '"' + $quote) + $quote
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
    throw 'ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocations++
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB read failed with exit code $code; device output was suppressed."
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $rows }
}

function Resolve-Device {
    Require $AllowDeviceRead.IsPresent 'Sample requires explicit -AllowDeviceRead.'
    $script:Adb = Resolve-Adb
    $devicesResult = Invoke-Adb @('devices')
    $devices = @($devicesResult.Lines | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { [string]$Matches.serial }
    })
    if ($Serial -ceq 'auto') {
        Require ($devices.Count -eq 1) `
            'Auto selection requires exactly one authorized ADB endpoint; pass -Serial otherwise.'
        $script:Device = [string]$devices[0]
    } else {
        Require ($devices -ccontains $Serial) 'The requested ADB endpoint is not connected.'
        $script:Device = $Serial
    }
}

function Invoke-Shell([string] $Command, [switch] $AllowFailure) {
    Invoke-Adb @('-s', $script:Device, 'shell', $Command) -AllowFailure:$AllowFailure
}

function Invoke-ReadShell([string] $Command, [switch] $Optional) {
    $normal = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $normal = Invoke-Shell $Command -AllowFailure
        if ($normal.ExitCode -eq 0) { return $normal }
        if ($attempt -lt 3) { Start-Sleep -Milliseconds (250 * $attempt) }
    }
    if ($AllowRootRead) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $root = Invoke-Shell ('su -c ' + (ConvertTo-ShLiteral $Command)) -AllowFailure
            if ($root.ExitCode -eq 0) { return $root }
            if ($attempt -lt 2) { Start-Sleep -Milliseconds 250 }
        }
    }
    if ($Optional) { return $normal }
    throw 'A required read-only device probe failed; output was suppressed.'
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try {
        & $Operation
        return $false
    } catch {
        return $true
    }
}

function Read-PackageIdentity([Parameter(Mandatory)][string[]] $Lines) {
    $versionCodes = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionCode=(?<value>\d+)(?:\s|$)')
        if ($match.Success) { [int64]$match.Groups['value'].Value }
    })
    $versionNames = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionName=(?<value>\S+)\s*$')
        if ($match.Success) { [string]$match.Groups['value'].Value }
    })
    Require ($versionCodes.Count -eq 1) `
        'Installed Lab identity did not contain exactly one versionCode.'
    Require ($versionNames.Count -eq 1) `
        'Installed Lab identity did not contain exactly one versionName.'
    [pscustomobject]@{
        VersionCode = [int64]$versionCodes[0]
        VersionName = [string]$versionNames[0]
    }
}

function Read-ExactBaseApkPath(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $ExpectedPackage
) {
    Require ($Lines.Count -eq 1) `
        'Installed Lab must expose exactly one base APK; split or contaminated installs are rejected.'
    $row = [string]$Lines[0]
    Require ($row -cmatch '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$') `
        'Installed Lab base APK response was malformed.'
    $path = [string]$Matches.path
    Require (-not $path.Contains('..') -and -not $path.Contains('\') -and
            -not $path.Contains("`0")) 'Installed Lab base APK path was unsafe.'
    Require ($path -cmatch ('/' + [regex]::Escape($ExpectedPackage) + '(?:-|/)')) `
        'Installed Lab base APK path did not belong to the fixed Lab package.'
    return $path
}

function Read-Sha256Sum(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $ExpectedPath
) {
    Require ($Lines.Count -eq 1) 'A device artifact hash returned an unexpected number of rows.'
    $row = [string]$Lines[0]
    $match = [regex]::Match($row, `
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require $match.Success 'A device artifact hash response was malformed.'
    Require ([string]$match.Groups['path'].Value -ceq $ExpectedPath) `
        'A device artifact hash response named an unexpected file.'
    return ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RemoteSha256([Parameter(Mandatory)][string] $Path) {
    $result = Invoke-ReadShell ('sha256sum ' + (ConvertTo-ShLiteral $Path))
    Read-Sha256Sum ([string[]]@($result.Lines)) $Path
}

function New-ProvenanceReceipt(
    [Parameter(Mandatory)][object] $Identity,
    [Parameter(Mandatory)][string] $BaseApkSha256,
    [Parameter(Mandatory)][string] $CoreSha256,
    [Parameter(Mandatory)][string] $VeqSha256,
    [Parameter(Mandatory)][datetime] $VerifiedUtc
) {
    Require ([int64]$Identity.VersionCode -eq $script:ExpectedVersionCode) `
        'Installed Lab versionCode did not match the fixed RC5 build.'
    Require ([string]$Identity.VersionName -ceq $script:ExpectedVersionName) `
        'Installed Lab versionName did not match the fixed RC5 build.'
    Require ($BaseApkSha256 -ceq $script:ExpectedBaseApkSha256) `
        'Installed Lab base APK hash did not match the fixed RC5 build.'
    Require ($CoreSha256 -ceq $script:ExpectedCoreSha256) `
        'Persistent Vivecraft Core hash did not match RC5.'
    Require ($VeqSha256 -ceq $script:ExpectedVeqSha256) `
        'Persistent VEQ hash did not match frozen RC5 VEQ.'
    [ordered]@{
        schemaVersion = 1
        verifiedUtc = $VerifiedUtc.ToString('o')
        installedIdentityMatched = $true
        baseApkMatched = $true
        persistentCoreMatched = $true
        persistentVeqMatched = $true
        allMatched = $true
    }
}

function Invoke-LabProvenancePreflight {
    $packageResult = Invoke-ReadShell `
        ('dumpsys package ' + (ConvertTo-ShLiteral $script:Package))
    $packageLines = [string[]]@($packageResult.Lines | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    $identity = Read-PackageIdentity $packageLines
    $baseResult = Invoke-ReadShell ('pm path ' + (ConvertTo-ShLiteral $script:Package))
    $basePath = Read-ExactBaseApkPath ([string[]]@($baseResult.Lines)) $script:Package
    $baseSha256 = Read-RemoteSha256 $basePath
    $coreSha256 = Read-RemoteSha256 $script:CorePath
    $veqSha256 = Read-RemoteSha256 $script:VeqPath
    New-ProvenanceReceipt $identity $baseSha256 $coreSha256 $veqSha256 ([DateTime]::UtcNow)
}

function Read-ExactPidProbe([string[]] $Lines, [switch] $AllowMissing) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'PID probe returned an ambiguous number of rows.'
    if ($rows[0] -ceq 'ABSENT') {
        if ($AllowMissing) { return $null }
        throw 'Expected exactly one process, but it was absent.'
    }
    Require ($rows[0] -cmatch '^PID\t(?<pids>[0-9]+(?:\s+[0-9]+)*)$') `
        'PID probe response was malformed.'
    $pids = @(([string]$Matches.pids) -split '\s+')
    Require ($pids.Count -eq 1) 'Expected exactly one process.'
    return [int]$pids[0]
}

function Get-Pid([string] $Package, [switch] $AllowMissing) {
    $qPackage = ConvertTo-ShLiteral $Package
    $command = "out=`$(pidof $qPackage); rc=`$?; " +
        'if [ "$rc" -eq 0 ]; then printf ''PID\t%s\n'' "$out"; ' +
        'elif [ "$rc" -eq 1 ]; then printf ''ABSENT\n''; else exit "$rc"; fi'
    $result = Invoke-ReadShell $command
    Read-ExactPidProbe ([string[]]@($result.Lines)) -AllowMissing:$AllowMissing
}

function Read-Kib([string[]] $Lines, [string] $Name) {
    $match = $Lines | Where-Object { $_ -match ('^\s*' + [regex]::Escape($Name) + ':\s+(?<v>\d+)\s+kB') } |
        Select-Object -First 1
    if ($null -eq $match) { return $null }
    [int64]([regex]::Match($match, '(?<v>\d+)\s+kB').Groups['v'].Value)
}

function Read-AppSummaryKib([string[]] $Lines, [string] $Name) {
    # Recent Quest builds print TOTAL PSS and TOTAL RSS on the same line. Match
    # the requested label itself instead of assuming that every value starts a
    # new line (or accidentally returning the first value on a combined line).
    $pattern = '(?:^|\s)' + [regex]::Escape($Name) + ':\s+(?<v>[\d,]+)'
    foreach ($line in $Lines) {
        $match = [regex]::Match([string]$line, $pattern)
        if ($match.Success) {
            return [int64]($match.Groups['v'].Value -replace ',', '')
        }
    }
    return $null
}

function Get-FocusState {
    $result = Invoke-ReadShell 'dumpsys activity activities'
    $line = $result.Lines | Where-Object { $_ -match '(?:topResumedActivity|mResumedActivity|ResumedActivity)' } |
        Select-Object -First 1
    if ($null -eq $line) { return 'unknown' }
    if ([string]$line -match [regex]::Escape($script:Package)) { return 'focused' }
    return 'not-focused'
}

function Test-ThreadListContainsGameJvm([string[]] $ThreadNames) {
    @($ThreadNames | Where-Object { ([string]$_).Trim() -ceq 'QuestCraft-JVM' }).Count -eq 1
}

function Get-GameJvmState([int] $ProcessId) {
    $command = 'for f in /proc/' + $ProcessId +
        '/task/*/comm; do [ -r "$f" ] && cat "$f" 2>/dev/null || true; done'
    $result = Invoke-ReadShell $command
    Test-ThreadListContainsGameJvm $result.Lines
}

function Read-ProcessStartTicks([Parameter(Mandatory)][string[]] $Lines) {
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'Process stat probe returned an ambiguous number of rows.'
    $row = [string]$rows[0]
    $commEnd = $row.LastIndexOf(') ', [StringComparison]::Ordinal)
    Require ($commEnd -gt 0) 'Process stat probe was malformed.'
    $suffix = @($row.Substring($commEnd + 2) -split '\s+')
    # The suffix starts at field 3 (state); Linux /proc/<pid>/stat starttime is field 22.
    Require ($suffix.Count -ge 20 -and $suffix[19] -cmatch '^[0-9]+$') `
        'Process stat probe did not contain a valid starttime.'
    return [uint64]$suffix[19]
}

function Get-ProcessStartTicks([int] $ProcessId) {
    $result = Invoke-ReadShell "cat /proc/$ProcessId/stat"
    Read-ProcessStartTicks ([string[]]@($result.Lines))
}

function Read-ProcessTemporalAnchor(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines
) {
    $rows = @($Lines | ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $clockRows = @($rows | Where-Object { $_ -cmatch '^CLOCK_TICKS\t(?<v>[0-9]+)$' })
    $uptimeRows = @($rows | Where-Object {
        $_ -cmatch '^UPTIME_SECONDS\t(?<v>[0-9]+(?:\.[0-9]+)?)$'
    })
    $epochRows = @($rows | Where-Object { $_ -cmatch '^EPOCH_SECONDS\t(?<v>[0-9]+)$' })
    $statRows = @($rows | Where-Object { $_ -cmatch '^STAT\t(?<v>.+)$' })
    Require ($clockRows.Count -eq 1 -and $uptimeRows.Count -eq 1 -and
            $epochRows.Count -eq 1 -and $statRows.Count -eq 1) `
        'The process temporal-anchor probe was malformed.'
    $clockTicks = [int64](([regex]::Match($clockRows[0], '\t(?<v>[0-9]+)$')).Groups['v'].Value)
    $epochSeconds = [int64](([regex]::Match($epochRows[0], '\t(?<v>[0-9]+)$')).Groups['v'].Value)
    [double]$uptimeSeconds = 0
    $uptimeText = ([regex]::Match($uptimeRows[0],
        '\t(?<v>[0-9]+(?:\.[0-9]+)?)$')).Groups['v'].Value
    $parsedUptime = [double]::TryParse($uptimeText,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$uptimeSeconds)
    Require ($parsedUptime -and $clockTicks -gt 0 -and $uptimeSeconds -gt 0 -and
            $epochSeconds -gt 0) 'The process temporal-anchor values were invalid.'
    $statLine = ([regex]::Match($statRows[0], '^STAT\t(?<v>.+)$')).Groups['v'].Value
    $startTicks = Read-ProcessStartTicks @($statLine)
    $startEpochSeconds = [double]$epochSeconds - $uptimeSeconds +
        ([double]$startTicks / [double]$clockTicks)
    Require ($startEpochSeconds -gt 0 -and $startEpochSeconds -le ($epochSeconds + 2.0)) `
        'The process temporal anchor computed an impossible start time.'
    return [pscustomobject][ordered]@{
        processStartTicks = [uint64]$startTicks
        clockTicksPerSecond = $clockTicks
        deviceEpochSeconds = $epochSeconds
        deviceUptimeSeconds = $uptimeSeconds
        processStartEpochSeconds = $startEpochSeconds
    }
}

function Get-ProcessTemporalAnchor([int] $ProcessId) {
    $command = 'hz=$(getconf CLK_TCK) || exit 41; ' +
        'up=$(cut -d '' '' -f 1 /proc/uptime) || exit 42; ' +
        'now=$(date +%s) || exit 43; ' +
        'printf ''CLOCK_TICKS\t%s\nUPTIME_SECONDS\t%s\nEPOCH_SECONDS\t%s\nSTAT\t'' ' +
        '"$hz" "$up" "$now"; cat /proc/' + $ProcessId + '/stat'
    $result = Invoke-ReadShell $command
    Read-ProcessTemporalAnchor ([string[]]@($result.Lines))
}

function Assert-ProcessRuntimeFence(
    [int] $ProcessId,
    [uint64] $ExpectedStartTicks,
    [string] $Context
) {
    Require ((Get-Pid $script:Package) -eq $ProcessId) "$Context PID changed."
    $before = Get-ProcessTemporalAnchor $ProcessId
    Require ([uint64]$before.processStartTicks -eq $ExpectedStartTicks) `
        "$Context process incarnation changed before the JVM probe."
    $gameJvmAlive = Get-GameJvmState $ProcessId
    $after = Get-ProcessTemporalAnchor $ProcessId
    Require ([uint64]$after.processStartTicks -eq $ExpectedStartTicks) `
        "$Context process incarnation changed after the JVM probe."
    Require ((Get-Pid $script:Package) -eq $ProcessId) "$Context PID changed after the JVM probe."
    Require $gameJvmAlive "$Context game JVM was not observed alive."
    return [pscustomobject][ordered]@{
        gameJvmAlive = $true
        temporalAnchor = $after
        observedUtc = [DateTime]::UtcNow
    }
}

function Read-ExpectedGameLogMetadata(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines
) {
    $rows = @($Lines | ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 2) 'The expected game-log metadata probe was malformed.'
    $epochMatch = [regex]::Match($rows[0], '^DEVICE_EPOCH\t(?<v>[0-9]+)$')
    $logMatch = [regex]::Match($rows[1],
        '^GAME_LOG\t(?<size>[0-9]+)_(?<mtime>[0-9]+)_(?<ctime>[0-9]+)_(?<inode>[0-9]+)$')
    Require ($epochMatch.Success -and $logMatch.Success) `
        'The expected game-log metadata probe was malformed.'
    $deviceEpochSeconds = [int64]$epochMatch.Groups['v'].Value
    $sizeBytes = [int64]$logMatch.Groups['size'].Value
    $modifiedEpochSeconds = [int64]$logMatch.Groups['mtime'].Value
    $changedEpochSeconds = [int64]$logMatch.Groups['ctime'].Value
    $fileInode = [uint64]$logMatch.Groups['inode'].Value
    Require ($deviceEpochSeconds -gt 0 -and $sizeBytes -gt 0 -and
            $modifiedEpochSeconds -gt 0 -and $changedEpochSeconds -gt 0 -and
            $fileInode -gt 0) 'The expected game-log metadata values were invalid.'
    return [pscustomobject][ordered]@{
        deviceEpochSeconds = $deviceEpochSeconds
        sizeBytes = $sizeBytes
        modifiedEpochSeconds = $modifiedEpochSeconds
        changedEpochSeconds = $changedEpochSeconds
        fileInode = $fileInode
    }
}

function Get-ExpectedGameLogMetadata {
    $qLog = ConvertTo-ShLiteral $script:GameLogPath
    $command = 'p=' + $qLog + '; ' +
        '[ -f "$p" ] && [ ! -L "$p" ] || exit 44; ' +
        'now=$(date +%s) || exit 45; ' +
        'printf ''DEVICE_EPOCH\t%s\nGAME_LOG\t'' "$now"; ' +
        'stat -c ''%s_%Y_%Z_%i'' "$p"'
    $result = Invoke-ReadShell $command
    Read-ExpectedGameLogMetadata ([string[]]@($result.Lines))
}

function Read-ExpectedGameLogIdentity(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines
) {
    $minecraftVersions = [Collections.Generic.List[string]]::new()
    $coreVersions = [Collections.Generic.List[string]]::new()
    $veqVersions = [Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $text = [string]$line
        $minecraft = [regex]::Match($text,
            '^(?:.*:\s)?Loading Minecraft (?<v>\S+) with Fabric Loader(?:\s+\S+)?\s*$')
        if ($minecraft.Success) {
            $minecraftVersions.Add([string]$minecraft.Groups['v'].Value)
        }
        $core = [regex]::Match($text,
            '^(?:.*:\s)?\s*-\s+vivecraft\s+(?<v>\S+)\s*$')
        if ($core.Success) { $coreVersions.Add([string]$core.Groups['v'].Value) }
        $veq = [regex]::Match($text,
            '^(?:.*:\s)?\s*-\s+vivecraft_essentials_quest\s+(?<v>\S+)\s*$')
        if ($veq.Success) { $veqVersions.Add([string]$veq.Groups['v'].Value) }
    }
    Require ($minecraftVersions.Count -eq 1 -and
            $minecraftVersions[0] -ceq $script:ExpectedMinecraftVersion) `
        'The expected game log did not identify exact Minecraft 26.2.'
    Require ($coreVersions.Count -eq 1 -and
            $coreVersions[0] -ceq $script:ExpectedCoreVersion) `
        'The expected game log did not identify exact Vivecraft RC5.'
    Require ($veqVersions.Count -eq 1 -and
            $veqVersions[0] -ceq $script:ExpectedVeqVersion) `
        'The expected game log did not identify exact frozen VEQ.'
    return [pscustomobject][ordered]@{
        expectedMinecraftVersionObserved = $true
        expectedVivecraftVersionObserved = $true
        expectedVeqVersionObserved = $true
    }
}

function Confirm-ExpectedGameLogFreshness(
    [Parameter(Mandatory)][string] $ObservedPath,
    [Parameter(Mandatory)][object] $Metadata,
    [Parameter(Mandatory)][object] $ProcessAnchor,
    [uint64] $ExpectedFileInode = 0
) {
    Require ($ObservedPath -ceq $script:GameLogPath) `
        'The live game log came from another profile.'
    $processStartEpochSeconds = [double]$ProcessAnchor.processStartEpochSeconds
    $deviceEpochSeconds = [int64]$Metadata.deviceEpochSeconds
    $modifiedEpochSeconds = [int64]$Metadata.modifiedEpochSeconds
    $changedEpochSeconds = [int64]$Metadata.changedEpochSeconds
    $fileInode = [uint64]$Metadata.fileInode
    Require ([int64]$Metadata.sizeBytes -gt 0 -and $fileInode -gt 0) `
        'The expected game log was absent or empty.'
    Require ($processStartEpochSeconds -gt 0 -and
            $modifiedEpochSeconds -ge [math]::Floor($processStartEpochSeconds - 2.0) -and
            $changedEpochSeconds -ge [math]::Floor($processStartEpochSeconds - 2.0) -and
            $modifiedEpochSeconds -le ($deviceEpochSeconds + 2) -and
            $changedEpochSeconds -le ($deviceEpochSeconds + 2)) `
        'The expected game log was not bound to the current process launch.'
    Require ($modifiedEpochSeconds -ge
            ($deviceEpochSeconds - $script:GameLogFreshnessSeconds)) `
        'The expected game log was stale; another profile may be running.'
    if ($ExpectedFileInode -gt 0) {
        Require ($fileInode -eq $ExpectedFileInode) `
            'The expected game log was replaced during the soak.'
    }
    return [pscustomobject][ordered]@{
        expectedGameLogPathMatched = $true
        expectedGameLogRegularAndNonEmpty = $true
        expectedGameLogSameFile = $true
        expectedGameLogTemporallyBoundToProcess = $true
        expectedGameLogFresh = $true
        expectedGameLogModifiedEpochSeconds = $modifiedEpochSeconds
        expectedGameLogObservedDeviceEpochSeconds = $deviceEpochSeconds
    }
}

function Get-ExpectedGameLogFreshnessObservation(
    [Parameter(Mandatory)][object] $ProcessAnchor,
    [Parameter(Mandatory)][uint64] $ExpectedFileInode
) {
    $metadata = Get-ExpectedGameLogMetadata
    Confirm-ExpectedGameLogFreshness $script:GameLogPath $metadata $ProcessAnchor `
        $ExpectedFileInode
}

function Get-ExpectedGameLogIdentityObservation(
    [int] $ProcessId,
    [Parameter(Mandatory)][object] $ProcessAnchor,
    [Parameter(Mandatory)][object] $BeforeMetadata,
    [uint64] $ExpectedFileInode = 0
) {
    $null = Confirm-ExpectedGameLogFreshness $script:GameLogPath `
        $BeforeMetadata $ProcessAnchor $ExpectedFileInode
    $content = Invoke-Adb @('-s', $script:Device, 'exec-out', 'cat', $script:GameLogPath)
    Require ($content.ExitCode -eq 0) 'The expected game log could not be read.'
    $identity = Read-ExpectedGameLogIdentity ([string[]]@($content.Lines))
    $afterMetadata = Get-ExpectedGameLogMetadata
    Require ([uint64]$afterMetadata.fileInode -eq [uint64]$BeforeMetadata.fileInode -and
            [int64]$afterMetadata.sizeBytes -ge [int64]$BeforeMetadata.sizeBytes -and
            [int64]$afterMetadata.modifiedEpochSeconds -ge
                [int64]$BeforeMetadata.modifiedEpochSeconds) `
        'The expected game log was replaced or truncated while its identity was read.'
    $afterFreshness = Confirm-ExpectedGameLogFreshness $script:GameLogPath `
        $afterMetadata $ProcessAnchor $ExpectedFileInode
    $afterAnchor = Get-ProcessTemporalAnchor $ProcessId
    Require ([uint64]$afterAnchor.processStartTicks -eq
            [uint64]$ProcessAnchor.processStartTicks) `
        'The process incarnation changed while the expected game log was read.'
    $content = $null
    return [pscustomobject][ordered]@{
        expectedGameLogPathMatched = [bool]$afterFreshness.expectedGameLogPathMatched
        expectedGameLogRegularAndNonEmpty = `
            [bool]$afterFreshness.expectedGameLogRegularAndNonEmpty
        expectedGameLogSameFile = [bool]$afterFreshness.expectedGameLogSameFile
        expectedGameLogTemporallyBoundToProcess = `
            [bool]$afterFreshness.expectedGameLogTemporallyBoundToProcess
        expectedGameLogFresh = [bool]$afterFreshness.expectedGameLogFresh
        expectedMinecraftVersionObserved = `
            [bool]$identity.expectedMinecraftVersionObserved
        expectedVivecraftVersionObserved = `
            [bool]$identity.expectedVivecraftVersionObserved
        expectedVeqVersionObserved = [bool]$identity.expectedVeqVersionObserved
        expectedGameLogModifiedEpochSeconds = `
            [int64]$afterFreshness.expectedGameLogModifiedEpochSeconds
        expectedGameLogObservedDeviceEpochSeconds = `
            [int64]$afterFreshness.expectedGameLogObservedDeviceEpochSeconds
    }
}

function Read-JvmMemoryObservation(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines,
    [int64] $FileSizeBytes,
    [int64] $FileModifiedEpochSeconds,
    [double] $ProcessStartEpochSeconds,
    [double] $ObservedDeviceEpochSeconds
) {
    $expected = 'Setting JVM memory: Xms=512MiB, Xmx=1536MiB (auto)'
    $count = @($Lines | Where-Object { [string]$_ -ceq $expected }).Count
    Require ($FileSizeBytes -gt 0) 'The launcher log was empty.'
    Require ($FileModifiedEpochSeconds -ge [math]::Floor($ProcessStartEpochSeconds - 2.0) -and
            $FileModifiedEpochSeconds -le [math]::Ceiling($ObservedDeviceEpochSeconds + 2.0)) `
        'The launcher log was not temporally bound to the current process incarnation.'
    Require ($count -eq 1) `
        'The current launcher log did not contain exactly one bounded JVM memory line.'
    return [pscustomobject][ordered]@{
        exactJvmMemoryLineObserved = $true
        xmsMiB = 512
        xmxMiB = 1536
        xmxSource = 'auto'
        jvmMemoryLineCount = $count
        launcherLogSizeBytes = $FileSizeBytes
        launcherLogModifiedEpochSeconds = $FileModifiedEpochSeconds
        launcherLogTemporallyBoundToProcess = $true
    }
}

function Get-JvmMemoryObservation([int] $ProcessId, [object] $ProcessAnchor) {
    $latestLogPath = "/sdcard/Android/data/$($script:Package)/files/latestlog.txt"
    $typeResult = Invoke-Adb @('-s', $script:Device, 'shell', 'stat', '-c', '%F',
        $latestLogPath)
    $typeRows = @($typeResult.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($typeResult.ExitCode -eq 0 -and $typeRows.Count -eq 1 -and
        $typeRows[0] -ceq 'regular file') `
        'The current launcher log was absent or was not a regular file.'
    # A literal tab is split by adb shell before stat receives it on Windows.
    # Use a shell-inert, non-whitespace delimiter so the format remains one argv element.
    $sizeResult = Invoke-Adb @('-s', $script:Device, 'shell', 'stat', '-c', '%s_%Y',
        $latestLogPath)
    $sizeRows = @($sizeResult.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($sizeResult.ExitCode -eq 0 -and $sizeRows.Count -eq 1 -and
        $sizeRows[0] -cmatch '^(?<size>[0-9]+)_(?<mtime>[0-9]+)$') `
        'The current launcher log size probe was malformed.'
    $sizeBytes = [int64]$Matches.size
    $modifiedEpochSeconds = [int64]$Matches.mtime
    # Avoid a nested sh -c pipeline. The fixed regular launcher log is read directly,
    # parsed in memory, and never persisted in an evidence artifact.
    $content = Invoke-Adb @('-s', $script:Device, 'exec-out', 'cat', $latestLogPath)
    Require ($content.ExitCode -eq 0) 'The current launcher log could not be read.'
    $afterStat = Invoke-Adb @('-s', $script:Device, 'shell', 'stat', '-c', '%s_%Y',
        $latestLogPath)
    $afterRows = @($afterStat.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($afterStat.ExitCode -eq 0 -and $afterRows.Count -eq 1 -and
            $afterRows[0] -ceq $sizeRows[0]) `
        'The launcher log changed while its bounded-memory line was read.'
    $afterAnchor = Get-ProcessTemporalAnchor $ProcessId
    Require ([uint64]$afterAnchor.processStartTicks -eq
            [uint64]$ProcessAnchor.processStartTicks) `
        'The process incarnation changed while the launcher log was read.'
    # Android launcher logs legitimately contain blank separator lines. The
    # parser accepts those raw rows and still requires one exact memory row.
    $observation = Read-JvmMemoryObservation ([string[]]@($content.Lines)) `
        $sizeBytes $modifiedEpochSeconds `
        ([double]$ProcessAnchor.processStartEpochSeconds) `
        ([double]$afterAnchor.deviceEpochSeconds)
    $content = $null
    return $observation
}

function Read-LauncherMarkerObservation(
    [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines,
    [double] $ProcessStartEpochSeconds,
    [double] $ObservedDeviceEpochSeconds
) {
    $appliedEpochs = [Collections.Generic.List[double]]::new()
    $degradedEpochs = [Collections.Generic.List[double]]::new()
    foreach ($line in $Lines) {
        $text = [string]$line
        $applied = $text.Contains('QC_LAUNCHER_RESOURCE_RELEASE_APPLIED',
            [StringComparison]::Ordinal)
        $degraded = $text.Contains('QC_LAUNCHER_RESOURCE_RELEASE_DEGRADED',
            [StringComparison]::Ordinal)
        if (-not $applied -and -not $degraded) { continue }
        $match = [regex]::Match($text, '^\s*(?<epoch>[0-9]+(?:\.[0-9]+)?)\s+')
        Require $match.Success 'A launcher-resource-release marker had no epoch timestamp.'
        [double]$markerEpoch = 0
        $parsedEpoch = [double]::TryParse($match.Groups['epoch'].Value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$markerEpoch)
        Require ($parsedEpoch -and $markerEpoch -le ($ObservedDeviceEpochSeconds + 2.0)) `
            'A launcher-resource-release marker had an invalid epoch timestamp.'
        if ($markerEpoch -lt ($ProcessStartEpochSeconds - 2.0)) { continue }
        if ($applied) { $appliedEpochs.Add($markerEpoch) }
        if ($degraded) { $degradedEpochs.Add($markerEpoch) }
    }
    $appliedCount = $appliedEpochs.Count
    $degradedCount = $degradedEpochs.Count
    Require ($appliedCount -ge 1) `
        'The starting PID had no launcher-resource-release applied marker.'
    Require ($degradedCount -eq 0) `
        'The starting PID contained a degraded launcher-resource-release marker.'
    return [pscustomobject][ordered]@{
        launcherResourceReleaseAppliedObserved = $true
        launcherReleaseAppliedMarkerCount = $appliedCount
        launcherReleaseDegradedMarkerCount = $degradedCount
        launcherAppliedMarkerEpochSeconds = [math]::Round($appliedEpochs[0], 3)
        launcherMarkerTemporallyBoundToProcess = $true
    }
}

function Get-LauncherMarkerObservation([int] $ProcessId, [object] $ProcessAnchor) {
    $result = Invoke-Adb @('-s', $script:Device, 'logcat', '-d', '-v', 'epoch',
        "--pid=$ProcessId")
    Require ($result.ExitCode -eq 0) 'The starting PID logcat probe failed.'
    $afterAnchor = Get-ProcessTemporalAnchor $ProcessId
    Require ([uint64]$afterAnchor.processStartTicks -eq
            [uint64]$ProcessAnchor.processStartTicks) `
        'The process incarnation changed while the launcher marker was captured.'
    Read-LauncherMarkerObservation ([string[]]@($result.Lines)) `
        ([double]$ProcessAnchor.processStartEpochSeconds) `
        ([double]$afterAnchor.deviceEpochSeconds)
}

function Test-ProvenanceReceipt([object] $Receipt) {
    if ($null -eq $Receipt) { return $false }
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        if ($Receipt -is [Collections.IDictionary]) {
            if (-not $Receipt.Contains($field)) { return $false }
            $value = $Receipt[$field]
        } else {
            $property = $Receipt.PSObject.Properties[$field]
            if ($null -eq $property) { return $false }
            $value = $property.Value
        }
        if ($value -isnot [bool] -or -not [bool]$value) { return $false }
    }
    return $true
}

function New-RuntimeStartReceipt(
    [int] $ProcessId,
    [uint64] $ProcessStartTicks,
    [object] $ProcessAnchor,
    [bool] $GameJvmAlive,
    [object] $Provenance,
    [object] $JvmMemory,
    [object] $LauncherMarker,
    [object] $ExpectedGameLog,
    [datetime] $ObservedUtc
) {
    Require ($ProcessId -gt 0 -and $ProcessStartTicks -gt 0) `
        'The start runtime binding did not identify one process incarnation.'
    Require ([uint64]$ProcessAnchor.processStartTicks -eq $ProcessStartTicks -and
            [double]$ProcessAnchor.processStartEpochSeconds -gt 0) `
        'The start runtime temporal anchor did not match the process incarnation.'
    Require ([string]$script:ProducerSha256 -cmatch '^[0-9A-F]{64}$') `
        'The memory-soak producer hash was not captured at launch.'
    Require $GameJvmAlive 'The game JVM was not alive at soak start.'
    Require (Test-ProvenanceReceipt $Provenance) `
        'The exact RC5 provenance was not valid at soak start.'
    Require ([bool]$JvmMemory.exactJvmMemoryLineObserved -and
        [int]$JvmMemory.xmsMiB -eq 512 -and [int]$JvmMemory.xmxMiB -eq 1536 -and
        [string]$JvmMemory.xmxSource -ceq 'auto' -and
        [int]$JvmMemory.jvmMemoryLineCount -eq 1 -and
        [bool]$JvmMemory.launcherLogTemporallyBoundToProcess -and
        [int64]$JvmMemory.launcherLogModifiedEpochSeconds -ge
            [math]::Floor([double]$ProcessAnchor.processStartEpochSeconds - 3.0) -and
        [int64]$JvmMemory.launcherLogModifiedEpochSeconds -le
            [math]::Ceiling([double]$ProcessAnchor.deviceEpochSeconds + 3.0)) `
        'The bounded JVM memory contract was not observed at soak start.'
    Require ([bool]$LauncherMarker.launcherResourceReleaseAppliedObserved -and
        [int]$LauncherMarker.launcherReleaseAppliedMarkerCount -ge 1 -and
        [int]$LauncherMarker.launcherReleaseDegradedMarkerCount -eq 0 -and
        [bool]$LauncherMarker.launcherMarkerTemporallyBoundToProcess -and
        [double]$LauncherMarker.launcherAppliedMarkerEpochSeconds -ge
            ([double]$ProcessAnchor.processStartEpochSeconds - 3.0) -and
        [double]$LauncherMarker.launcherAppliedMarkerEpochSeconds -le
            ([double]$ProcessAnchor.deviceEpochSeconds + 3.0)) `
        'The launcher-resource-release contract was not observed at soak start.'
    Require ([bool]$ExpectedGameLog.expectedGameLogPathMatched -and
        [bool]$ExpectedGameLog.expectedGameLogRegularAndNonEmpty -and
        [bool]$ExpectedGameLog.expectedGameLogSameFile -and
        [bool]$ExpectedGameLog.expectedGameLogTemporallyBoundToProcess -and
        [bool]$ExpectedGameLog.expectedGameLogFresh -and
        [bool]$ExpectedGameLog.expectedMinecraftVersionObserved -and
        [bool]$ExpectedGameLog.expectedVivecraftVersionObserved -and
        [bool]$ExpectedGameLog.expectedVeqVersionObserved -and
        [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds -ge
            [math]::Floor([double]$ProcessAnchor.processStartEpochSeconds - 2.0) -and
        [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds -ge
            ([int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds -
                $script:GameLogFreshnessSeconds) -and
        [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds -le
            ([int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds + 2) -and
        [int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds -le
            ([int64]$ProcessAnchor.deviceEpochSeconds + 3)) `
        'The exact expected-profile game log was not valid at soak start.'
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC5_MEMORY_SOAK_RUNTIME_START'
        result = 'PASS'
        observedUtc = $ObservedUtc.ToUniversalTime().ToString('o')
        pid = $ProcessId
        processStartTicks = $ProcessStartTicks
        producerSha256 = $script:ProducerSha256
        processStartEpochSeconds = [math]::Round(
            [double]$ProcessAnchor.processStartEpochSeconds, 3)
        exactPidAlive = $true
        gameJvmAlive = $true
        provenanceMatched = $true
        exactJvmMemoryLineObserved = $true
        xmsMiB = 512
        xmxMiB = 1536
        xmxSource = 'auto'
        jvmMemoryLineCount = 1
        launcherLogSizeBytes = [int64]$JvmMemory.launcherLogSizeBytes
        launcherLogModifiedEpochSeconds = [int64]$JvmMemory.launcherLogModifiedEpochSeconds
        launcherLogTemporallyBoundToProcess = $true
        launcherResourceReleaseAppliedObserved = $true
        launcherReleaseAppliedMarkerCount = [int]$LauncherMarker.launcherReleaseAppliedMarkerCount
        launcherReleaseDegradedMarkerCount = 0
        launcherAppliedMarkerEpochSeconds = [double]$LauncherMarker.launcherAppliedMarkerEpochSeconds
        launcherMarkerTemporallyBoundToProcess = $true
        expectedGameLogPathMatched = $true
        expectedGameLogRegularAndNonEmpty = $true
        expectedGameLogSameFile = $true
        expectedGameLogTemporallyBoundToProcess = $true
        expectedGameLogFresh = $true
        expectedMinecraftVersionObserved = $true
        expectedVivecraftVersionObserved = $true
        expectedVeqVersionObserved = $true
        expectedGameLogModifiedEpochSeconds = `
            [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds
        expectedGameLogObservedDeviceEpochSeconds = `
            [int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds
        runtimeFenceBeforeStartProvenance = $true
        runtimeFenceAfterStartProvenance = $true
    }
}

function New-RuntimeFinalReceipt(
    [Parameter(Mandatory)][object] $StartReceipt,
    [int] $ProcessId,
    [uint64] $ProcessStartTicks,
    [object] $ProcessAnchor,
    [bool] $GameJvmAlive,
    [object] $Provenance,
    [object] $ExpectedGameLog,
    [datetime] $ObservedUtc
) {
    Require ([string]$StartReceipt.receiptType -ceq
        'V71_RC5_MEMORY_SOAK_RUNTIME_START' -and [string]$StartReceipt.result -ceq 'PASS') `
        'The final runtime binding did not receive a valid start receipt.'
    Require ($ProcessId -eq [int]$StartReceipt.pid -and
        $ProcessStartTicks -eq [uint64]$StartReceipt.processStartTicks) `
        'The final runtime binding observed another process incarnation.'
    Require ([uint64]$ProcessAnchor.processStartTicks -eq $ProcessStartTicks -and
            [math]::Abs([double]$ProcessAnchor.processStartEpochSeconds -
                [double]$StartReceipt.processStartEpochSeconds) -le 2.0) `
        'The final runtime temporal anchor observed another process incarnation.'
    Require $GameJvmAlive 'The original game JVM was not alive at soak end.'
    Require (Test-ProvenanceReceipt $Provenance) `
        'The exact RC5 provenance was not valid at soak end.'
    Require ([bool]$ExpectedGameLog.expectedGameLogPathMatched -and
        [bool]$ExpectedGameLog.expectedGameLogRegularAndNonEmpty -and
        [bool]$ExpectedGameLog.expectedGameLogSameFile -and
        [bool]$ExpectedGameLog.expectedGameLogTemporallyBoundToProcess -and
        [bool]$ExpectedGameLog.expectedGameLogFresh -and
        [bool]$ExpectedGameLog.expectedMinecraftVersionObserved -and
        [bool]$ExpectedGameLog.expectedVivecraftVersionObserved -and
        [bool]$ExpectedGameLog.expectedVeqVersionObserved -and
        [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds -ge
            ([int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds -
                $script:GameLogFreshnessSeconds) -and
        [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds -le
            ([int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds + 2) -and
        [int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds -le
            ([int64]$ProcessAnchor.deviceEpochSeconds + 3)) `
        'The exact expected-profile game log was not valid at soak end.'
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC5_MEMORY_SOAK_RUNTIME_FINAL'
        result = 'PASS'
        observedUtc = $ObservedUtc.ToUniversalTime().ToString('o')
        pid = $ProcessId
        processStartTicks = $ProcessStartTicks
        processStartEpochSeconds = [math]::Round(
            [double]$ProcessAnchor.processStartEpochSeconds, 3)
        sameProcessIncarnation = $true
        exactPidAlive = $true
        gameJvmAlive = $true
        provenanceMatched = $true
        startJvmMemoryObservationCarriedForward = $true
        startLauncherMarkerCarriedForward = $true
        finalLogcatMarkerRequired = $false
        expectedGameLogPathMatched = $true
        expectedGameLogRegularAndNonEmpty = $true
        expectedGameLogSameFile = $true
        expectedGameLogTemporallyBoundToProcess = $true
        expectedGameLogFresh = $true
        expectedMinecraftVersionObserved = $true
        expectedVivecraftVersionObserved = $true
        expectedVeqVersionObserved = $true
        expectedGameLogModifiedEpochSeconds = `
            [int64]$ExpectedGameLog.expectedGameLogModifiedEpochSeconds
        expectedGameLogObservedDeviceEpochSeconds = `
            [int64]$ExpectedGameLog.expectedGameLogObservedDeviceEpochSeconds
        runtimeFenceBeforeFinalProvenance = $true
        runtimeFenceAfterFinalProvenance = $true
    }
}

function New-RuntimeBindingReceipt(
    [Parameter(Mandatory)][object] $StartReceipt,
    [Parameter(Mandatory)][object] $FinalReceipt
) {
    Require ([int]$FinalReceipt.pid -eq [int]$StartReceipt.pid -and
        [uint64]$FinalReceipt.processStartTicks -eq [uint64]$StartReceipt.processStartTicks -and
        [bool]$FinalReceipt.sameProcessIncarnation -and
        [bool]$StartReceipt.runtimeFenceBeforeStartProvenance -and
        [bool]$StartReceipt.runtimeFenceAfterStartProvenance -and
        [bool]$FinalReceipt.runtimeFenceBeforeFinalProvenance -and
        [bool]$FinalReceipt.runtimeFenceAfterFinalProvenance -and
        [string]$StartReceipt.producerSha256 -cmatch '^[0-9A-F]{64}$' -and
        [bool]$StartReceipt.launcherMarkerTemporallyBoundToProcess -and
        [bool]$StartReceipt.launcherLogTemporallyBoundToProcess -and
        [bool]$StartReceipt.expectedGameLogTemporallyBoundToProcess -and
        [bool]$StartReceipt.expectedGameLogFresh -and
        [bool]$FinalReceipt.expectedGameLogTemporallyBoundToProcess -and
        [bool]$FinalReceipt.expectedGameLogFresh -and
        [int64]$FinalReceipt.expectedGameLogModifiedEpochSeconds -ge
            [int64]$StartReceipt.expectedGameLogModifiedEpochSeconds) `
        'The start and final runtime receipts are not bound to one process incarnation.'
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC5_MEMORY_SOAK_RUNTIME_BINDING'
        result = 'PASS'
        start = $StartReceipt
        final = $FinalReceipt
        evidenceBoundary = [pscustomobject][ordered]@{
            logcatMarkerCapturedOnlyAtStart = $true
            finalLogcatMarkerRequired = $false
            processStartTicksPersistedForPidReuseDefense = $true
            processStartEpochPersistedForLogBinding = $true
            producerHashCapturedAtLaunch = $true
            producerFileReadLockedForRun = $true
            launcherMarkerTemporallyBoundToProcess = $true
            launcherLogTemporallyBoundToProcess = $true
            expectedProfileGameLogPathFixed = $true
            expectedGameLogIdentityCheckedAtStartAndFinal = $true
            expectedGameLogFreshnessCheckedEverySample = $true
            expectedGameLogEvidenceOnlyBooleansAndTimestamps = $true
            gameJvmLivenessObservedAtBoundedFencesAndSamples = $true
            continuousGameJvmLivenessClaimed = $false
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
}

function Get-Sample(
    [int] $ExpectedPid,
    [uint64] $ExpectedStartTicks,
    [uint64] $ExpectedGameLogFileInode,
    [datetime] $StartedUtc
) {
    $processId = Get-Pid $script:Package -AllowMissing
    if ($null -eq $processId -or $processId -ne $ExpectedPid) {
        return [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $StartedUtc).TotalMinutes, 3)
            pid = $processId
            pidStable = $false
            focus = if ($null -eq $processId) { 'not-running' } else { 'unknown' }
            gameJvmAlive = $false
            expectedGameLogPathMatched = $false
            expectedGameLogRegularAndNonEmpty = $false
            expectedGameLogSameFile = $false
            expectedGameLogTemporallyBoundToProcess = $false
            expectedGameLogFresh = $false
            expectedGameLogModifiedEpochSeconds = $null
            expectedGameLogObservedDeviceEpochSeconds = $null
            totalPssKib = $null
            totalRssKib = $null
            javaHeapKib = $null
            nativeHeapKib = $null
            graphicsKib = $null
            vmRssKib = $null
            vmSwapKib = $null
            memAvailableKib = $null
            swapFreeKib = $null
        }
    }
    $beforeAnchor = Get-ProcessTemporalAnchor $processId
    Require ([uint64]$beforeAnchor.processStartTicks -eq $ExpectedStartTicks) `
        'The process incarnation changed before a memory sample.'
    $gameLog = Get-ExpectedGameLogFreshnessObservation $beforeAnchor `
        $ExpectedGameLogFileInode
    $status = (Invoke-ReadShell "cat /proc/$processId/status").Lines
    $system = (Invoke-ReadShell 'cat /proc/meminfo').Lines
    $meminfo = (Invoke-ReadShell "dumpsys meminfo $processId").Lines
    $focus = Get-FocusState
    $gameJvmAlive = Get-GameJvmState $processId
    $afterAnchor = Get-ProcessTemporalAnchor $processId
    Require ([uint64]$afterAnchor.processStartTicks -eq $ExpectedStartTicks) `
        'The process incarnation changed during a memory sample.'
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $StartedUtc).TotalMinutes, 3)
        pid = $processId
        pidStable = ($processId -eq $ExpectedPid)
        focus = $focus
        gameJvmAlive = $gameJvmAlive
        expectedGameLogPathMatched = [bool]$gameLog.expectedGameLogPathMatched
        expectedGameLogRegularAndNonEmpty = `
            [bool]$gameLog.expectedGameLogRegularAndNonEmpty
        expectedGameLogSameFile = [bool]$gameLog.expectedGameLogSameFile
        expectedGameLogTemporallyBoundToProcess = `
            [bool]$gameLog.expectedGameLogTemporallyBoundToProcess
        expectedGameLogFresh = [bool]$gameLog.expectedGameLogFresh
        expectedGameLogModifiedEpochSeconds = `
            [int64]$gameLog.expectedGameLogModifiedEpochSeconds
        expectedGameLogObservedDeviceEpochSeconds = `
            [int64]$gameLog.expectedGameLogObservedDeviceEpochSeconds
        totalPssKib = Read-AppSummaryKib $meminfo 'TOTAL PSS'
        totalRssKib = Read-AppSummaryKib $meminfo 'TOTAL RSS'
        javaHeapKib = Read-AppSummaryKib $meminfo 'Java Heap'
        nativeHeapKib = Read-AppSummaryKib $meminfo 'Native Heap'
        graphicsKib = Read-AppSummaryKib $meminfo 'Graphics'
        vmRssKib = Read-Kib $status 'VmRSS'
        vmSwapKib = Read-Kib $status 'VmSwap'
        memAvailableKib = Read-Kib $system 'MemAvailable'
        swapFreeKib = Read-Kib $system 'SwapFree'
    }
}

function Get-SlopeMibPerMinute([object[]] $Samples) {
    $points = @($Samples | Where-Object { $null -ne $_.totalPssKib })
    if ($points.Count -lt 2) { return $null }
    $meanX = ($points | Measure-Object elapsedMinutes -Average).Average
    $meanY = ($points | ForEach-Object { $_.totalPssKib / 1024.0 } | Measure-Object -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($point in $points) {
        $dx = [double]$point.elapsedMinutes - $meanX
        $dy = ([double]$point.totalPssKib / 1024.0) - $meanY
        $numerator += $dx * $dy
        $denominator += $dx * $dx
    }
    if ($denominator -eq 0) { return 0.0 }
    [math]::Round($numerator / $denominator, 3)
}

function Test-CompleteMemorySample([object] $Sample) {
    foreach ($metricName in $script:RequiredMetricNames) {
        if ($null -eq $Sample.PSObject.Properties[$metricName] -or
                $null -eq $Sample.$metricName) {
            return $false
        }
    }
    return $true
}

function Test-ExpectedGameLogSample([object] $Sample) {
    foreach ($field in @('expectedGameLogPathMatched',
            'expectedGameLogRegularAndNonEmpty', 'expectedGameLogSameFile',
            'expectedGameLogTemporallyBoundToProcess', 'expectedGameLogFresh')) {
        $property = $Sample.PSObject.Properties[$field]
        if ($null -eq $property -or $property.Value -isnot [bool] -or
                -not [bool]$property.Value) {
            return $false
        }
    }
    $modified = $Sample.PSObject.Properties['expectedGameLogModifiedEpochSeconds']
    $observed = $Sample.PSObject.Properties['expectedGameLogObservedDeviceEpochSeconds']
    if ($null -eq $modified -or $null -eq $observed -or
            $null -eq $modified.Value -or $null -eq $observed.Value) {
        return $false
    }
    return [int64]$modified.Value -gt 0 -and
        [int64]$modified.Value -le ([int64]$observed.Value + 2) -and
        [int64]$modified.Value -ge
            ([int64]$observed.Value - $script:GameLogFreshnessSeconds)
}

function Get-MinimumExpectedSampleCount([int] $Minutes, [int] $Seconds) {
    # Initial sample + every interval + a real sample at/after the deadline.
    [math]::Max(2, [int][math]::Ceiling(($Minutes * 60.0) / $Seconds) + 1)
}

if ($Action -ceq 'SelfTest') {
    Assert-ExpectedGameLogContract
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262') 'Lab package drifted.'
    Require ($script:StablePackage -ceq 'com.qcxr.qcxr.dev262') 'Stable guard drifted.'
    Require ($script:GameLogPath -ceq
            '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/logs/latest.log') `
        'The expected game-log path drifted from the exact 26.2 Lab profile.'
    Require ($script:ExpectedMinecraftVersion -ceq '26.2' -and
            $script:ExpectedCoreVersion -ceq
                [string]$script:Rc5Lock.pair.core.fabricVersion -and
            $script:ExpectedVeqVersion -ceq
                [string]$script:Rc5Lock.pair.veq.fabricVersion -and
            $script:GameLogFreshnessSeconds -eq 60) `
        'The expected game-log identity or freshness contract drifted.'
    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $script:ProducerSha256 = Get-NormalizedTextSha256 $PSCommandPath
    $forbiddenMutation = 'am force' + '-stop'
    Require (-not $source.Contains($forbiddenMutation)) `
        'The read-only sampler contains a forbidden process-stop action.'
    $markerCaptureIndex = $source.LastIndexOf(
        '$initialLauncherMarker = Get-LauncherMarkerObservation $initialPid',
        [StringComparison]::Ordinal)
    $provenanceIndex = $source.LastIndexOf(
        '$provenanceReceipt = Invoke-LabProvenancePreflight',
        [StringComparison]::Ordinal)
    Require ($markerCaptureIndex -ge 0 -and $provenanceIndex -gt $markerCaptureIndex) `
        'The short-lived launcher marker is no longer captured before provenance verification.'
    Require ($source.Contains(
            '$postStartFence = Assert-ProcessRuntimeFence $initialPid') -and
        $source.Contains(
            '$finalPostProvenanceFence = Assert-ProcessRuntimeFence $finalPid')) `
        'A post-provenance process/JVM fence is absent.'
    Require ($source.Contains(
            '$sample = [pscustomobject](Get-Sample $initialPid $initialProcessStartTicks') -and
        $source.Contains(
            '$initialExpectedGameLog = Get-ExpectedGameLogIdentityObservation') -and
        $source.Contains(
            '$finalExpectedGameLog = Get-ExpectedGameLogIdentityObservation')) `
        'The expected-profile game log is not enforced at start, every sample, and final.'
    Require ((Read-Kib @('VmRSS: 1,234 kB', 'SwapFree: 5678 kB') 'SwapFree') -eq 5678) `
        'The /proc memory parser self-test failed.'
    Require ((Read-AppSummaryKib @(' Java Heap: 12,345', ' TOTAL PSS: 67,890') `
            'TOTAL PSS') -eq 67890) 'The dumpsys memory parser self-test failed.'
    $combinedTotals = @(' TOTAL PSS: 2,300,055   TOTAL RSS: 2,405,916   TOTAL SWAP PSS: 55,457')
    Require ((Read-AppSummaryKib $combinedTotals 'TOTAL PSS') -eq 2300055) `
        'The combined TOTAL PSS parser self-test failed.'
    Require ((Read-AppSummaryKib $combinedTotals 'TOTAL RSS') -eq 2405916) `
        'The combined TOTAL RSS parser self-test failed.'
    $slopeFixture = @(
        [pscustomobject]@{ elapsedMinutes = 15.0; totalPssKib = 102400 },
        [pscustomobject]@{ elapsedMinutes = 20.0; totalPssKib = 107520 }
    )
    Require ((Get-SlopeMibPerMinute $slopeFixture) -eq 1.0) `
        'The post-warm slope self-test failed.'
    $completeFixture = [pscustomobject]@{}
    foreach ($metricName in $script:RequiredMetricNames) {
        $completeFixture | Add-Member -NotePropertyName $metricName -NotePropertyValue 1
    }
    Require (Test-CompleteMemorySample $completeFixture) `
        'A complete memory sample was rejected.'
    $completeFixture.graphicsKib = $null
    Require (-not (Test-CompleteMemorySample $completeFixture)) `
        'A memory sample with a missing metric was accepted.'
    Require ((Get-MinimumExpectedSampleCount 90 300) -eq 19) `
        'The expected sample-count self-test failed.'
    Require (Test-ThreadListContainsGameJvm @('UnityMain', 'QuestCraft-JVM')) `
        'The live-game JVM marker was not recognized.'
    Require (-not (Test-ThreadListContainsGameJvm @('UnityMain', 'Launcher'))) `
        'A launcher-only thread list was accepted as a live game.'
    $identityFixture = Read-PackageIdentity @(
        'Packages:',
        '  versionCode=71 minSdk=29 targetSdk=34',
        "  versionName=$($script:ExpectedVersionName)"
    )
    Require ($identityFixture.VersionCode -eq 71 -and
            $identityFixture.VersionName -ceq $script:ExpectedVersionName) `
        'The installed package identity parser self-test failed.'
    Require (Test-Throws {
        Read-PackageIdentity @(
            'versionCode=71 minSdk=29',
            'versionCode=70 minSdk=29',
            "versionName=$($script:ExpectedVersionName)"
        ) | Out-Null
    }) 'The installed package identity parser accepted duplicate version codes.'
    $basePathFixture = '/data/app/~~abc/com.qcxr.qcxr.canary262-def/base.apk'
    Require ((Read-ExactBaseApkPath @("package:$basePathFixture") $script:Package) -ceq
            $basePathFixture) 'The exact base APK path parser self-test failed.'
    Require (Test-Throws {
        Read-ExactBaseApkPath @(
            "package:$basePathFixture",
            'package:/data/app/~~abc/split_config.arm64_v8a.apk'
        ) $script:Package | Out-Null
    }) 'The base APK path parser accepted a split install.'
    $hashFixture = 'A89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
    Require ((Read-Sha256Sum @($hashFixture.ToLowerInvariant() + '  ' + $basePathFixture) `
            $basePathFixture) -ceq $hashFixture) `
        'The device SHA-256 parser self-test failed.'
    Require (Test-Throws {
        Read-Sha256Sum @($hashFixture + '  /data/app/other/base.apk') $basePathFixture |
            Out-Null
    }) 'The device SHA-256 parser accepted an unexpected path.'
    Require ((Read-ExactPidProbe @("PID`t30181")) -eq 30181) `
        'The exact PID probe parser rejected one process.'
    Require ($null -eq (Read-ExactPidProbe @('ABSENT') -AllowMissing)) `
        'The exact PID probe parser rejected an allowed absent process.'
    Require (Test-Throws {
        Read-ExactPidProbe @("PID`t30181 30182") | Out-Null
    }) 'The exact PID probe parser accepted multiple processes.'
    $savedExpectedBaseApkSha256 = $script:ExpectedBaseApkSha256
    $script:ExpectedBaseApkSha256 = $hashFixture
    $receiptFixture = New-ProvenanceReceipt $identityFixture $hashFixture `
        $script:ExpectedCoreSha256 $script:ExpectedVeqSha256 `
        ([datetime]'2026-09-06T00:00:00Z')
    $receiptJson = $receiptFixture | ConvertTo-Json -Depth 4 -Compress
    Require ($receiptFixture.allMatched -eq $true) `
        'The aggregate provenance receipt self-test failed.'
    Require ($receiptJson -notmatch '(?i)deviceSerial|/data/|/sdcard/|account') `
        'The aggregate provenance receipt exposed device, path, or account data.'
    Require (Test-Throws {
        New-ProvenanceReceipt $identityFixture ('0' * 64) $script:ExpectedCoreSha256 `
            $script:ExpectedVeqSha256 ([datetime]'2026-09-06T00:00:00Z') | Out-Null
    }) 'The provenance gate accepted the wrong installed APK hash.'
    $processStatFixture = '30181 (QuestCraft JVM) S ' + ((1..19) -join ' ')
    Require ((Read-ProcessStartTicks @($processStatFixture)) -eq 19) `
        'The process-incarnation parser self-test failed.'
    Require (Test-Throws {
        Read-ProcessStartTicks @('30181 malformed') | Out-Null
    }) 'The process-incarnation parser accepted malformed stat data.'
    $temporalAnchorFixture = Read-ProcessTemporalAnchor @(
        '',
        "CLOCK_TICKS`t100",
        "UPTIME_SECONDS`t1000.50",
        "EPOCH_SECONDS`t1700001000",
        "STAT`t$processStatFixture"
    )
    Require ([uint64]$temporalAnchorFixture.processStartTicks -eq 19 -and
            [math]::Abs([double]$temporalAnchorFixture.processStartEpochSeconds -
                1699999999.69) -lt 0.001) `
        'The process temporal-anchor parser self-test failed.'
    Require (Test-Throws {
        Read-ProcessTemporalAnchor @(
            "CLOCK_TICKS`t0", "UPTIME_SECONDS`t1000.50",
            "EPOCH_SECONDS`t1700001000", "STAT`t$processStatFixture"
        ) | Out-Null
    }) 'The temporal-anchor parser accepted a zero clock rate.'
    $expectedGameLogLines = @(
        '[00:00:00] [main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.4',
        "`t- vivecraft $($script:ExpectedCoreVersion)",
        "`t- vivecraft_essentials_quest $($script:ExpectedVeqVersion)",
        '[00:00:01] [Render thread/INFO]: account@example.invalid serverAddress=private',
        '[00:00:02] [Render thread/INFO]: worldName=private-world'
    )
    $expectedGameLogIdentityFixture = Read-ExpectedGameLogIdentity $expectedGameLogLines
    Require ([bool]$expectedGameLogIdentityFixture.expectedMinecraftVersionObserved -and
            [bool]$expectedGameLogIdentityFixture.expectedVivecraftVersionObserved -and
            [bool]$expectedGameLogIdentityFixture.expectedVeqVersionObserved) `
        'The exact expected game-log identity fixture was rejected.'
    $expectedGameLogMetadataFixture = Read-ExpectedGameLogMetadata @(
        "DEVICE_EPOCH`t1700001000",
        "GAME_LOG`t8192_1700000995_1700000995_44123"
    )
    $expectedGameLogFreshnessFixture = Confirm-ExpectedGameLogFreshness `
        $script:GameLogPath $expectedGameLogMetadataFixture $temporalAnchorFixture 44123
    Require ([bool]$expectedGameLogFreshnessFixture.expectedGameLogFresh -and
            [bool]$expectedGameLogFreshnessFixture.expectedGameLogSameFile -and
            [bool]$expectedGameLogFreshnessFixture.expectedGameLogTemporallyBoundToProcess) `
        'The current expected game-log freshness fixture was rejected.'
    $expectedGameLogFixture = [pscustomobject][ordered]@{
        expectedGameLogPathMatched = $true
        expectedGameLogRegularAndNonEmpty = $true
        expectedGameLogSameFile = $true
        expectedGameLogTemporallyBoundToProcess = $true
        expectedGameLogFresh = $true
        expectedMinecraftVersionObserved = $true
        expectedVivecraftVersionObserved = $true
        expectedVeqVersionObserved = $true
        expectedGameLogModifiedEpochSeconds = 1700000995
        expectedGameLogObservedDeviceEpochSeconds = 1700001000
    }
    foreach ($property in $expectedGameLogFixture.PSObject.Properties) {
        if ($property.Name -in @('expectedGameLogModifiedEpochSeconds',
                'expectedGameLogObservedDeviceEpochSeconds')) {
            Require ($property.Value -is [int]) `
                'Expected game-log evidence exposed a non-timestamp value.'
        } else {
            Require ($property.Value -is [bool]) `
                'Expected game-log evidence exposed a value other than a boolean or timestamp.'
        }
    }
    $expectedGameLogJson = $expectedGameLogFixture | ConvertTo-Json -Compress
    Require ($expectedGameLogJson -notmatch
            '(?i)account@example|serverAddress|worldName|private-world|Loading Minecraft|vivecraft_essentials') `
        'Expected game-log evidence retained raw log or private runtime data.'
    Require (Test-Throws {
        Confirm-ExpectedGameLogFreshness `
            '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/25.1/logs/latest.log' `
            $expectedGameLogMetadataFixture $temporalAnchorFixture 44123 | Out-Null
    }) 'A live JVM using another profile path was accepted.'
    $staleGameLogMetadataFixture = Read-ExpectedGameLogMetadata @(
        "DEVICE_EPOCH`t1700001000",
        "GAME_LOG`t8192_1700000900_1700000995_44123"
    )
    Require (Test-Throws {
        Confirm-ExpectedGameLogFreshness $script:GameLogPath `
            $staleGameLogMetadataFixture $temporalAnchorFixture 44123 | Out-Null
    }) 'A stale expected-profile game log was accepted.'
    Require (Test-Throws {
        Read-ExpectedGameLogIdentity @(
            '[00:00:00] [main/INFO]: Loading Minecraft 26.1 with Fabric Loader 0.19.4',
            "`t- vivecraft $($script:ExpectedCoreVersion)",
            "`t- vivecraft_essentials_quest $($script:ExpectedVeqVersion)"
        ) | Out-Null
    }) 'A game log for the wrong Minecraft profile version was accepted.'
    Require (Test-Throws {
        Read-ExpectedGameLogIdentity @(
            '[00:00:00] [main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.4',
            "`t- vivecraft 26.2-1.3.15+qc.v71.rc4",
            "`t- vivecraft_essentials_quest $($script:ExpectedVeqVersion)"
        ) | Out-Null
    }) 'A game log with the wrong Vivecraft version was accepted.'
    Require (Test-Throws {
        Read-ExpectedGameLogIdentity @(
            '[00:00:00] [main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.4',
            "`t- vivecraft $($script:ExpectedCoreVersion)",
            "`t- vivecraft_essentials_quest 0.7.0-v70-canary.2"
        ) | Out-Null
    }) 'A game log with the wrong VEQ version was accepted.'
    $gameLogSampleFixture = [pscustomobject][ordered]@{
        expectedGameLogPathMatched = $true
        expectedGameLogRegularAndNonEmpty = $true
        expectedGameLogSameFile = $true
        expectedGameLogTemporallyBoundToProcess = $true
        expectedGameLogFresh = $true
        expectedGameLogModifiedEpochSeconds = 1700000995
        expectedGameLogObservedDeviceEpochSeconds = 1700001000
    }
    Require (Test-ExpectedGameLogSample $gameLogSampleFixture) `
        'A complete fresh expected game-log sample was rejected.'
    $gameLogSampleFixture.expectedGameLogFresh = $false
    Require (-not (Test-ExpectedGameLogSample $gameLogSampleFixture)) `
        'A memory sample without a fresh expected game log was accepted.'
    $gameLogSampleFixture.expectedGameLogFresh = $true
    $jvmFixture = Read-JvmMemoryObservation @(
        'unrelated launcher text',
        'Setting JVM memory: Xms=512MiB, Xmx=1536MiB (auto)'
    ) 4096 1700000000 1699999999.69 1700000002
    $jvmBlankLineContent = @(
        'unrelated launcher text',
        '',
        'Setting JVM memory: Xms=512MiB, Xmx=1536MiB (auto)'
    )
    $jvmBlankLineFixture = Read-JvmMemoryObservation `
        ([string[]]$jvmBlankLineContent) 4096 1700000000 1699999999.69 1700000002
    Require ([bool]$jvmBlankLineFixture.exactJvmMemoryLineObserved -and
        [int]$jvmBlankLineFixture.jvmMemoryLineCount -eq 1) `
        'The launcher-memory parser rejected raw content containing a blank line.'
    $markerFixture = Read-LauncherMarkerObservation @(
        '',
        '1700000000.0 30181 30181 I QC: QC_LAUNCHER_RESOURCE_RELEASE_APPLIED'
    ) 1699999999.69 1700000002
    Require ([bool]$markerFixture.launcherMarkerTemporallyBoundToProcess -and
            [double]$markerFixture.launcherAppliedMarkerEpochSeconds -eq 1700000000.0) `
        'The launcher marker was not temporally bound to the process fixture.'
    Require (Test-Throws {
        Read-LauncherMarkerObservation @(
            '1699999900.0 30181 30181 I QC: QC_LAUNCHER_RESOURCE_RELEASE_APPLIED'
        ) 1699999999.69 1700000002 | Out-Null
    }) 'A stale same-PID launcher marker was accepted.'
    Require (Test-Throws {
        Read-LauncherMarkerObservation @(
            'marker without epoch QC_LAUNCHER_RESOURCE_RELEASE_APPLIED'
        ) 1699999999.69 1700000002 | Out-Null
    }) 'An untimestamped launcher marker was accepted.'
    Require (Test-Throws {
        Read-LauncherMarkerObservation @(
            '1700000000.0 30181 30181 I QC: QC_LAUNCHER_RESOURCE_RELEASE_APPLIED',
            '1700000000.1 30181 30181 E QC: QC_LAUNCHER_RESOURCE_RELEASE_DEGRADED'
        ) 1699999999.69 1700000002 | Out-Null
    }) 'A current-incarnation degraded launcher marker was accepted.'
    Require (Test-Throws {
        Read-JvmMemoryObservation @(
            'Setting JVM memory: Xms=512MiB, Xmx=1536MiB (auto)'
        ) 4096 1699999900 1699999999.69 1700000002 | Out-Null
    }) 'A stale launcher log was accepted for the current process incarnation.'
    $startFixture = New-RuntimeStartReceipt `
        -ProcessId 30181 `
        -ProcessStartTicks 19 `
        -ProcessAnchor $temporalAnchorFixture `
        -GameJvmAlive $true `
        -Provenance $receiptFixture `
        -JvmMemory $jvmFixture `
        -LauncherMarker $markerFixture `
        -ExpectedGameLog $expectedGameLogFixture `
        -ObservedUtc ([datetime]'2026-09-06T00:00:01Z')
    $finalFixture = New-RuntimeFinalReceipt `
        -StartReceipt $startFixture `
        -ProcessId 30181 `
        -ProcessStartTicks 19 `
        -ProcessAnchor $temporalAnchorFixture `
        -GameJvmAlive $true `
        -Provenance $receiptFixture `
        -ExpectedGameLog $expectedGameLogFixture `
        -ObservedUtc ([datetime]'2026-09-06T01:30:01Z')
    $bindingFixture = New-RuntimeBindingReceipt $startFixture $finalFixture
    Require ([bool]$bindingFixture.evidenceBoundary.logcatMarkerCapturedOnlyAtStart -and
        -not [bool]$bindingFixture.evidenceBoundary.finalLogcatMarkerRequired -and
        [bool]$bindingFixture.evidenceBoundary.launcherMarkerTemporallyBoundToProcess -and
        [bool]$bindingFixture.evidenceBoundary.launcherLogTemporallyBoundToProcess -and
        [bool]$bindingFixture.evidenceBoundary.expectedProfileGameLogPathFixed -and
        [bool]$bindingFixture.evidenceBoundary.expectedGameLogIdentityCheckedAtStartAndFinal -and
        [bool]$bindingFixture.evidenceBoundary.expectedGameLogFreshnessCheckedEverySample -and
        [bool]$bindingFixture.evidenceBoundary.expectedGameLogEvidenceOnlyBooleansAndTimestamps -and
        -not [bool]$bindingFixture.evidenceBoundary.continuousGameJvmLivenessClaimed) `
        'The runtime binding still depends on a retained final logcat marker.'
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted',
            'deviceSerialPersisted', 'accountDataPersisted',
            'hostAbsolutePathsPersisted')) {
        Require (-not [bool]$bindingFixture.evidenceBoundary.$field) `
            "The runtime binding persisted forbidden evidence: $field."
    }
    $bindingJson = $bindingFixture | ConvertTo-Json -Depth 8 -Compress
    Require ($bindingJson -notmatch
            '(?i)/data/|/sdcard/|account@|serverAddress|worldName|Loading Minecraft|private-world') `
        'The runtime binding exposed a device path, account, world, or server.'
    Require (Test-Throws {
        New-RuntimeFinalReceipt -StartReceipt $startFixture -ProcessId 30181 `
            -ProcessStartTicks 20 -ProcessAnchor $temporalAnchorFixture `
            -GameJvmAlive $true -Provenance $receiptFixture `
            -ExpectedGameLog $expectedGameLogFixture `
            -ObservedUtc ([datetime]'2026-09-06T01:30:01Z') | Out-Null
    }) 'The final runtime binding accepted PID reuse with different start ticks.'
    $reusedTemporalAnchor = [pscustomobject][ordered]@{
        processStartTicks = [uint64]19
        processStartEpochSeconds = 1700000010.0
        deviceEpochSeconds = 1700001000
    }
    Require (Test-Throws {
        New-RuntimeFinalReceipt -StartReceipt $startFixture -ProcessId 30181 `
            -ProcessStartTicks 19 -ProcessAnchor $reusedTemporalAnchor `
            -GameJvmAlive $true -Provenance $receiptFixture `
            -ExpectedGameLog $expectedGameLogFixture `
            -ObservedUtc ([datetime]'2026-09-06T01:30:01Z') | Out-Null
    }) 'The final runtime binding accepted a mismatched process temporal anchor.'
    $script:ExpectedBaseApkSha256 = $savedExpectedBaseApkSha256
    Require ($script:DeviceInvocations -eq 0) `
        'Host-only SelfTest unexpectedly invoked ADB.'
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        Assertions = $script:Assertions
        Package = $script:Package
        Profile = [string]$script:Rc5Lock.target.profile
        StablePackageForbidden = $script:StablePackage
        DefaultDurationMinutes = 90
        DefaultIntervalSeconds = 300
        ExpectedGameLogPathBound = $true
        ExpectedGameLogRelativePath = $script:ExpectedGameLogRelativePath
        ExpectedGameLogMinecraftVersion = $script:ExpectedMinecraftVersion
        ExpectedGameLogCoreVersion = $script:ExpectedCoreVersion
        ExpectedGameLogVeqVersion = $script:ExpectedVeqVersion
        ExpectedGameLogIdentityAtStartAndFinal = $true
        ExpectedGameLogFreshnessEverySample = $true
        WrongProfileFixtureRejected = $true
        StaleGameLogFixtureRejected = $true
        WrongVersionFixturesRejected = $true
        RawGameLogDataPersisted = $false
    }
    return
}

Require ($script:ExpectedBaseApkSha256 -match '^[0-9A-F]{64}$' -and
        $script:ExpectedBaseApkSha256 -cnotmatch '^0{64}$' -and
        [int64]$script:Rc5Lock.target.apkSizeBytes -gt 0) `
    'The exact RC5 Lab APK hash is still pending; build and backfill the RC5 lock first.'
$script:ProducerSha256 = Get-NormalizedTextSha256 $PSCommandPath
Require ($script:ProducerSha256 -cmatch '^[0-9A-F]{64}$') `
    'The memory-soak producer hash could not be captured under its run-long read lock.'
Assert-ExpectedGameLogContract
Require ($script:ProducerSha256 -ceq
        [string]$script:EvidenceContract.producers.memorySoakScriptSha256) `
    'The running memory-soak producer does not match the RC5 lock.'
Resolve-Device
Require ($null -eq (Get-Pid $script:StablePackage -AllowMissing)) `
    'Stable is running; stop it manually before a Lab memory comparison.'
$initialPid = Get-Pid $script:Package
$startedUtc = [DateTime]::UtcNow
$initialTemporalAnchor = Get-ProcessTemporalAnchor $initialPid
$initialProcessStartTicks = [uint64]$initialTemporalAnchor.processStartTicks
$initialExpectedGameLogMetadata = Get-ExpectedGameLogMetadata
$initialExpectedGameLogFileInode = [uint64]$initialExpectedGameLogMetadata.fileInode
$initialExpectedGameLog = Get-ExpectedGameLogIdentityObservation `
    -ProcessId $initialPid `
    -ProcessAnchor $initialTemporalAnchor `
    -BeforeMetadata $initialExpectedGameLogMetadata `
    -ExpectedFileInode $initialExpectedGameLogFileInode
$initialLauncherMarker = Get-LauncherMarkerObservation $initialPid $initialTemporalAnchor
$initialJvmMemory = Get-JvmMemoryObservation $initialPid $initialTemporalAnchor
$initialPreProvenanceFence = Assert-ProcessRuntimeFence $initialPid `
    $initialProcessStartTicks 'The pre-provenance start fence'
$provenanceReceipt = Invoke-LabProvenancePreflight
$postStartFence = Assert-ProcessRuntimeFence $initialPid `
    $initialProcessStartTicks 'The post-provenance start fence'
Require ([bool]$initialPreProvenanceFence.gameJvmAlive -and
        [bool]$postStartFence.gameJvmAlive) `
    'The game JVM was not observed alive at both bounded provenance fences.'
$runtimeStartReceipt = New-RuntimeStartReceipt `
    -ProcessId $initialPid `
    -ProcessStartTicks $initialProcessStartTicks `
    -ProcessAnchor $postStartFence.temporalAnchor `
    -GameJvmAlive ([bool]$postStartFence.gameJvmAlive) `
    -Provenance $provenanceReceipt `
    -JvmMemory $initialJvmMemory `
    -LauncherMarker $initialLauncherMarker `
    -ExpectedGameLog $initialExpectedGameLog `
    -ObservedUtc ([datetime]$postStartFence.observedUtc)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = $startedUtc.ToString('yyyyMMdd-HHmmss')
    $OutputDirectory = Join-Path $script:RepoRoot "artifacts\memory\v71-rc5-$stamp"
}
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$samplesPath = Join-Path $OutputDirectory 'samples.jsonl'
$summaryPath = Join-Path $OutputDirectory 'summary.json'
$deadline = $startedUtc.AddMinutes($DurationMinutes)
$samples = [Collections.Generic.List[object]]::new()

while ($true) {
    $sample = [pscustomobject](Get-Sample $initialPid $initialProcessStartTicks `
        $initialExpectedGameLogFileInode $startedUtc)
    $samples.Add($sample)
    [IO.File]::AppendAllText(
        $samplesPath,
        ($sample | ConvertTo-Json -Compress) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    if (-not $sample.pidStable) { break }
    if ([DateTime]::UtcNow -ge $deadline) { break }
    $next = [DateTime]::UtcNow.AddSeconds($IntervalSeconds)
    if ($next -gt $deadline) { $next = $deadline }
    while ([DateTime]::UtcNow -lt $next) {
        Start-Sleep -Seconds 5
    }
}

$usable = @($samples | Where-Object { $null -ne $_.totalPssKib })
$completeSamples = @($samples | Where-Object { Test-CompleteMemorySample $_ })
$minimumExpectedSamples = Get-MinimumExpectedSampleCount $DurationMinutes $IntervalSeconds
$sampleCountComplete = $samples.Count -ge $minimumExpectedSamples
$metricsComplete = $completeSamples.Count -eq $samples.Count -and $sampleCountComplete
$focusComplete = @($samples | Where-Object { $_.focus -cne 'focused' }).Count -eq 0
$gameJvmComplete = @($samples | Where-Object { $_.gameJvmAlive -ne $true }).Count -eq 0
$expectedGameLogComplete = @($samples | Where-Object {
        -not (Test-ExpectedGameLogSample $_)
    }).Count -eq 0
$postWarm = @($usable | Where-Object elapsedMinutes -ge 15)
$lastThirtyStart = [math]::Max(0, $DurationMinutes - 30)
$lastThirty = @($usable | Where-Object elapsedMinutes -ge $lastThirtyStart)
$minimumPostWarmSamples = [math]::Max(
    2,
    [int][math]::Floor((($DurationMinutes - 15) * 60.0) / $IntervalSeconds) + 1)
$minimumLastThirtySamples = [math]::Max(
    2,
    [int][math]::Floor(([math]::Min(30, $DurationMinutes) * 60.0) / $IntervalSeconds) + 1)
$analysisWindowsComplete = $postWarm.Count -ge $minimumPostWarmSamples -and
    $lastThirty.Count -ge $minimumLastThirtySamples
$lastThirtyGrowthMib = $null
if ($lastThirty.Count -ge 2) {
    $lastThirtyGrowthMib = [math]::Round(
        ($lastThirty[-1].totalPssKib - $lastThirty[0].totalPssKib) / 1024.0, 3)
}
$maxPssKib = ($usable | Measure-Object totalPssKib -Maximum).Maximum
$maxRssKib = ($usable | Measure-Object vmRssKib -Maximum).Maximum
$maxSwapKib = ($usable | Measure-Object vmSwapKib -Maximum).Maximum
$minAvailableKib = ($usable | Measure-Object memAvailableKib -Minimum).Minimum
$minSwapFreeKib = ($usable | Measure-Object swapFreeKib -Minimum).Minimum
$slope = Get-SlopeMibPerMinute $postWarm
$completedDuration = $samples.Count -gt 1 -and
    $samples[-1].elapsedMinutes -ge $DurationMinutes
$passed = $completedDuration -and
    $metricsComplete -and
    $focusComplete -and
    $gameJvmComplete -and
    $expectedGameLogComplete -and
    $analysisWindowsComplete -and
    (@($samples | Where-Object { -not $_.pidStable }).Count -eq 0) -and
    $null -ne $maxPssKib -and
    $null -ne $maxRssKib -and
    $null -ne $maxSwapKib -and
    $null -ne $slope -and
    $null -ne $lastThirtyGrowthMib -and
    $maxPssKib -le (2.4 * 1024 * 1024) -and
    $maxRssKib -le (2.4 * 1024 * 1024) -and
    $maxSwapKib -le (512 * 1024) -and
    $slope -le 2.0 -and
    $lastThirtyGrowthMib -le 128.0

# The launcher marker is deliberately captured at start, while logcat still
# contains the exact PID's launch event. The launcher log need not survive for
# 90 minutes. In contrast, the fixed 26.2 game log must stay fresh at every
# sample and is re-read for exact runtime identity at the final fence.
$finalPid = Get-Pid $script:Package
$finalPreProvenanceFence = Assert-ProcessRuntimeFence $finalPid `
    $initialProcessStartTicks 'The pre-provenance final fence'
$finalExpectedGameLogMetadata = Get-ExpectedGameLogMetadata
$finalExpectedGameLog = Get-ExpectedGameLogIdentityObservation `
    -ProcessId $finalPid `
    -ProcessAnchor $finalPreProvenanceFence.temporalAnchor `
    -BeforeMetadata $finalExpectedGameLogMetadata `
    -ExpectedFileInode $initialExpectedGameLogFileInode
$finalProvenanceReceipt = Invoke-LabProvenancePreflight
$finalPostProvenanceFence = Assert-ProcessRuntimeFence $finalPid `
    $initialProcessStartTicks 'The post-provenance final fence'
$finalProcessStartTicks = [uint64]$finalPostProvenanceFence.temporalAnchor.processStartTicks
$runtimeFinalReceipt = New-RuntimeFinalReceipt `
    -StartReceipt $runtimeStartReceipt `
    -ProcessId $finalPid `
    -ProcessStartTicks $finalProcessStartTicks `
    -ProcessAnchor $finalPostProvenanceFence.temporalAnchor `
    -GameJvmAlive ([bool]$finalPostProvenanceFence.gameJvmAlive) `
    -Provenance $finalProvenanceReceipt `
    -ExpectedGameLog $finalExpectedGameLog `
    -ObservedUtc ([datetime]$finalPostProvenanceFence.observedUtc)
$runtimeBindingReceipt = New-RuntimeBindingReceipt $runtimeStartReceipt $runtimeFinalReceipt

$summary = [ordered]@{
    schemaVersion = 2
    package = $script:Package
    producerSha256 = $script:ProducerSha256
    provenance = $provenanceReceipt
    finalProvenance = $finalProvenanceReceipt
    runtimeBinding = $runtimeBindingReceipt
    startedUtc = $startedUtc.ToString('o')
    requestedDurationMinutes = $DurationMinutes
    intervalSeconds = $IntervalSeconds
    samples = $samples.Count
    minimumExpectedSamples = $minimumExpectedSamples
    completeMetricSamples = $completeSamples.Count
    initialPid = $initialPid
    pidStable = (@($samples | Where-Object { -not $_.pidStable }).Count -eq 0)
    focusStayedOnLab = $focusComplete
    gameJvmStayedAlive = $gameJvmComplete
    expectedGameLogStayedFresh = $expectedGameLogComplete
    maxPssMib = if ($null -eq $maxPssKib) { $null } else { [math]::Round($maxPssKib / 1024.0, 3) }
    maxRssMib = if ($null -eq $maxRssKib) { $null } else { [math]::Round($maxRssKib / 1024.0, 3) }
    maxProcessSwapMib = if ($null -eq $maxSwapKib) { $null } else { [math]::Round($maxSwapKib / 1024.0, 3) }
    minMemAvailableMib = if ($null -eq $minAvailableKib) { $null } else { [math]::Round($minAvailableKib / 1024.0, 3) }
    minSwapFreeMib = if ($null -eq $minSwapFreeKib) { $null } else { [math]::Round($minSwapFreeKib / 1024.0, 3) }
    postWarmPssSlopeMibPerMinute = $slope
    lastThirtyMinutesGrowthMib = $lastThirtyGrowthMib
    acceptance = [ordered]@{
        completedDuration = $completedDuration
        sampleCountComplete = $sampleCountComplete
        allRequiredMetricsPresent = $metricsComplete
        focusStayedOnLab = $focusComplete
        gameJvmStayedAlive = $gameJvmComplete
        expectedGameLogStayedFresh = $expectedGameLogComplete
        postWarmSamplesComplete = ($postWarm.Count -ge $minimumPostWarmSamples)
        lastThirtySamplesComplete = ($lastThirty.Count -ge $minimumLastThirtySamples)
        maxPssAtMost2457Point6Mib = ($maxPssKib -le (2.4 * 1024 * 1024))
        maxRssAtMost2457Point6Mib = ($maxRssKib -le (2.4 * 1024 * 1024))
        processSwapAtMost512Mib = ($maxSwapKib -le (512 * 1024))
        slopeAtMost2MibPerMinute = ($slope -le 2.0)
        lastThirtyGrowthAtMost128Mib = ($lastThirtyGrowthMib -le 128.0)
        passed = $passed
    }
    deviceInvocations = $script:DeviceInvocations
}
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Result = if ($passed) { 'PASS' } else { 'FAIL' }
    Summary = $summaryPath
    Samples = $samplesPath
    DeviceInvocations = $script:DeviceInvocations
}
