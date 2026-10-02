<#
.SYNOPSIS
Records a read-only long-duration memory profile for the fixed v71 Lab app.

.DESCRIPTION
The sampler is pinned to com.qcxr.qcxr.canary262. It never launches, stops,
installs, clears, or writes to either QuestCraft package. Every five minutes it
records process PSS/RSS/swap plus Android MemAvailable/SwapFree. Output contains
no account, world, or server identifiers.
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
$script:ExpectedVersionCode = 71
$script:ExpectedVersionName = '6.0.1-26.2-vivecraft-personal.12-rc.3'
$script:ExpectedBaseApkSha256 = `
    'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
$script:ExpectedCoreSha256 = `
    '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26'
$script:ExpectedVeqSha256 = `
    '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/26.2"
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
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
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
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
        'Installed Lab versionCode did not match the fixed RC3 build.'
    Require ([string]$Identity.VersionName -ceq $script:ExpectedVersionName) `
        'Installed Lab versionName did not match the fixed RC3 build.'
    Require ($BaseApkSha256 -ceq $script:ExpectedBaseApkSha256) `
        'Installed Lab base APK hash did not match the fixed RC3 build.'
    Require ($CoreSha256 -ceq $script:ExpectedCoreSha256) `
        'Persistent Vivecraft Core hash did not match RC3.'
    Require ($VeqSha256 -ceq $script:ExpectedVeqSha256) `
        'Persistent VEQ hash did not match RC3.'
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

function Get-Sample([int] $ExpectedPid, [datetime] $StartedUtc) {
    $processId = Get-Pid $script:Package -AllowMissing
    if ($null -eq $processId) {
        return [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $StartedUtc).TotalMinutes, 3)
            pid = $null
            pidStable = $false
            focus = 'not-running'
            gameJvmAlive = $false
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
    $status = (Invoke-ReadShell "cat /proc/$processId/status").Lines
    $system = (Invoke-ReadShell 'cat /proc/meminfo').Lines
    $meminfo = (Invoke-ReadShell "dumpsys meminfo $processId").Lines
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        elapsedMinutes = [math]::Round(([DateTime]::UtcNow - $StartedUtc).TotalMinutes, 3)
        pid = $processId
        pidStable = ($processId -eq $ExpectedPid)
        focus = Get-FocusState
        gameJvmAlive = Get-GameJvmState $processId
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

function Get-MinimumExpectedSampleCount([int] $Minutes, [int] $Seconds) {
    # Initial sample + every interval + a real sample at/after the deadline.
    [math]::Max(2, [int][math]::Ceiling(($Minutes * 60.0) / $Seconds) + 1)
}

if ($Action -ceq 'SelfTest') {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262') 'Lab package drifted.'
    Require ($script:StablePackage -ceq 'com.qcxr.qcxr.dev262') 'Stable guard drifted.'
    $forbiddenMutation = 'am force' + '-stop'
    Require (-not ((Get-Content -Raw -LiteralPath $PSCommandPath).Contains($forbiddenMutation))) `
        'The read-only sampler contains a forbidden process-stop action.'
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
        '  versionName=6.0.1-26.2-vivecraft-personal.12-rc.3'
    )
    Require ($identityFixture.VersionCode -eq 71 -and
            $identityFixture.VersionName -ceq $script:ExpectedVersionName) `
        'The installed package identity parser self-test failed.'
    Require (Test-Throws {
        Read-PackageIdentity @(
            'versionCode=71 minSdk=29',
            'versionCode=70 minSdk=29',
            'versionName=6.0.1-26.2-vivecraft-personal.12-rc.3'
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
    $hashFixture = 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
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
    $receiptFixture = New-ProvenanceReceipt $identityFixture $script:ExpectedBaseApkSha256 `
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
    Require ($script:DeviceInvocations -eq 0) `
        'Host-only SelfTest unexpectedly invoked ADB.'
    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        Package = $script:Package
        StablePackageForbidden = $script:StablePackage
        DefaultDurationMinutes = 90
        DefaultIntervalSeconds = 300
    }
    return
}

Resolve-Device
Require ($null -eq (Get-Pid $script:StablePackage -AllowMissing)) `
    'Stable is running; stop it manually before a Lab memory comparison.'
$provenanceReceipt = Invoke-LabProvenancePreflight
$initialPid = Get-Pid $script:Package
$startedUtc = [DateTime]::UtcNow
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = $startedUtc.ToString('yyyyMMdd-HHmmss')
    $OutputDirectory = Join-Path $script:RepoRoot "artifacts\memory\v71-rc3-$stamp"
}
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$samplesPath = Join-Path $OutputDirectory 'samples.jsonl'
$summaryPath = Join-Path $OutputDirectory 'summary.json'
$deadline = $startedUtc.AddMinutes($DurationMinutes)
$samples = [Collections.Generic.List[object]]::new()

while ($true) {
    $sample = [pscustomobject](Get-Sample $initialPid $startedUtc)
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

$summary = [ordered]@{
    schemaVersion = 1
    package = $script:Package
    provenance = $provenanceReceipt
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
