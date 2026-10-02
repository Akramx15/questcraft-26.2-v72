#requires -Version 7.0
<#
Host-only regression suite for the exact-RC8 Perfetto guard.

Every device-facing test is routed through an explicit fake ADB. The fake
trace processor emits aggregate CSV only. No connected Android device is read
or changed by this suite.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[RC8_PERFETTO_HOST_TEST] $Message" }
}

function Test-ExpectedFailure(
    [Parameter(Mandatory)][scriptblock] $Operation,
    [Parameter(Mandatory)][string] $Pattern
) {
    $script:LastExpectedFailureMessage = ''
    try {
        & $Operation
        return $false
    } catch {
        $script:LastExpectedFailureMessage = $_.Exception.Message + ' | ' +
            $_.ScriptStackTrace
        return $_.Exception.Message -match $Pattern
    }
}

function Get-CallCount([Parameter(Mandatory)][string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    return @([IO.File]::ReadAllLines($Path) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

function Get-Calls([Parameter(Mandatory)][string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([IO.File]::ReadAllLines($Path) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json })
}

$sourceGuard = Join-Path $PSScriptRoot 'quest-v71-rc8-perfetto-guard.ps1'
$sourceLock = Join-Path (Split-Path -Parent $PSScriptRoot) 'V71_LAB_RC8.lock.json'
foreach ($path in @($sourceGuard, $sourceLock)) {
    Require (Test-Path -LiteralPath $path -PathType Leaf) "Missing source: $path"
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourceGuard, [ref]$tokens, [ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected the guard.'
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($required in @(
    'Action','Serial','AdbPath','TraceProcessorPath','Seconds',
    'AllowDeviceRead','AllowEphemeralDeviceIo','AllowRootRead')) {
    Require ($parameters -ccontains $required) "Missing parameter: $required"
}
foreach ($forbidden in @(
    'Package','StablePackage','Profile','ApkSha256','CoreSha256','VeqSha256',
    'KeepTrace','Install','Launch','Stop','OutputDirectory')) {
    Require ($parameters -cnotcontains $forbidden) `
        "A fixed privacy/identity boundary is externally overrideable: $forbidden"
}

$source = [IO.File]::ReadAllText($sourceGuard)
foreach ($requiredLiteral in @(
    "`$script:Package = [string]`$script:BuildLock.target.package",
    "`$script:StablePackage = [string]`$script:BuildLock.target.forbiddenStablePackage",
    "'com.qcxr.qcxr.canary262'",
    "'com.qcxr.qcxr.dev262'",
    "'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'",
    "'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'",
    "'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'",
    "'6.0.1-26.2-vivecraft-personal.12-rc.8'",
    "'pojlib.UnityPlayerActivity'",
    "'^\s*mCurrentFocus\s*='",
    "'^\s*mFocusedApp\s*='",
    'CAPTURED_ANALYZED_AND_PURGED')) {
    Require ($source.Contains($requiredLiteral, [StringComparison]::Ordinal)) `
        "Missing exact-RC8/privacy literal: $requiredLiteral"
}
foreach ($forbiddenSource in @(
    'linux.perf','android.log','android.packages_list','heapprofd',
    'atrace_categories','enable_raw_query','KeepTrace')) {
    if ($forbiddenSource -ceq 'linux.perf' -or $forbiddenSource -ceq 'android.log' -or
            $forbiddenSource -ceq 'android.packages_list' -or
            $forbiddenSource -ceq 'heapprofd') {
        # These are required deny-list literals; permit only those occurrences.
        continue
    }
    Require (-not $source.Contains($forbiddenSource,
            [StringComparison]::OrdinalIgnoreCase)) `
        "A forbidden capture feature exists: $forbiddenSource"
}
$hostPurgeIndex = $source.IndexOf('Require (Remove-PrivateHostTemp $hostTemp)',
    [StringComparison]::Ordinal)
$publishIndex = $source.IndexOf('$artifactDirectory = New-ArtifactDirectory',
    [StringComparison]::Ordinal)
Require ($hostPurgeIndex -ge 0 -and $publishIndex -gt $hostPurgeIndex) `
    'The aggregate can be published before Host raw-trace purge is proven.'
Require ($source.Contains("Invoke-Adb @('devices', '-l')",
        [StringComparison]::Ordinal) -and
        $source.Contains("'get-devpath'", [StringComparison]::Ordinal) -and
        $source.Contains("'getprop', 'ro.serialno'", [StringComparison]::Ordinal) -and
        $source.Contains("'DEVPKEY_Device_Parent'", [StringComparison]::Ordinal) -and
        $source.Contains("'USB\VID_2833&PID_5013\'", [StringComparison]::Ordinal)) `
    'The explicit USB transport proof is missing.'
Require (-not $source.Contains('Get-PnpDevice -PresentOnly -FriendlyName',
        [StringComparison]::Ordinal)) `
    'The fallback used unsupported PnpDevice FriendlyName wildcard matching.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('qc-rc8-perfetto-host-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$scripts = Join-Path $repo 'scripts'
$fakeState = Join-Path $testRoot 'fake-state'
$callLog = Join-Path $fakeState 'adb-calls.jsonl'
$tpLog = Join-Path $fakeState 'trace-processor-calls.txt'
$poisonLog = Join-Path $fakeState 'poison-real-adb.txt'
$stableSentinel = Join-Path $fakeState 'stable-sentinel.bin'
[IO.Directory]::CreateDirectory($scripts) | Out-Null
[IO.Directory]::CreateDirectory($fakeState) | Out-Null
[IO.File]::Copy($sourceGuard, (Join-Path $scripts ([IO.Path]::GetFileName($sourceGuard))))
[IO.File]::Copy($sourceLock, (Join-Path $repo 'V71_LAB_RC8.lock.json'))
$guard = Join-Path $scripts 'quest-v71-rc8-perfetto-guard.ps1'
[IO.File]::WriteAllBytes($stableSentinel, [byte[]](0..255))
$stableSentinelSha = (Get-FileHash -LiteralPath $stableSentinel -Algorithm SHA256).Hash

$fakeAdb = Join-Path $testRoot 'fake-adb.ps1'
$fakeTraceProcessor = Join-Path $testRoot 'fake-trace-processor.ps1'
$poisonDirectory = Join-Path $testRoot 'poison-path'
[IO.Directory]::CreateDirectory($poisonDirectory) | Out-Null
$poisonAdb = Join-Path $poisonDirectory 'adb.cmd'

$fakeAdbSource = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$argv = [string[]]@($args)
$state = [string]$env:QC_RC8_PERFETTO_FAKE_STATE
$scenario = [string]$env:QC_RC8_PERFETTO_SCENARIO
$log = Join-Path $state 'adb-calls.jsonl'
$record = ([ordered]@{ argv=@($argv) } | ConvertTo-Json -Compress)
[IO.File]::AppendAllText($log, $record + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))

function Finish([int] $Code) {
    $global:LASTEXITCODE = $Code
}
function Emit([string[]] $Lines, [int] $Code = 0) {
    foreach ($line in $Lines) { Write-Output $line }
    Finish $Code
}

$lab = 'com.qcxr.qcxr.canary262'
$stable = 'com.qcxr.qcxr.dev262'
$immersive = $lab + '/pojlib.UnityPlayerActivity'
$stableImmersive = $stable + '/pojlib.UnityPlayerActivity'
$serial = 'QUEST_RC8_FAKE'
$wifiSerial = '192.0.2.10:5555'
$base = '/data/app/~~fixture/' + $lab + '-fixture/base.apk'
$game = '/sdcard/Android/data/' + $lab + '/files/instances/26.2'
$core = $game + '/mods/Vivecraft.jar'
$veq = $game + '/mods/Vivecraft-Essentials-Quest.jar'
$apkSha = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$coreSha = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$veqSha = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$started = Join-Path $state 'perfetto-started'
$poll = Join-Path $state 'perfetto-polled'
$cleaned = Join-Path $state 'device-cleaned'
$configShaPath = Join-Path $state 'config-sha'
$capturedConfigPath = Join-Path $state 'captured-config.pbtxt'
$traceFixture = Join-Path $state 'trace-fixture.bin'
$traceSha = (Get-FileHash -LiteralPath $traceFixture -Algorithm SHA256).Hash

if ($argv.Count -eq 2 -and $argv[0] -ceq 'devices' -and $argv[1] -ceq '-l') {
    if ($scenario -ceq 'adb-unauthorized') {
        Emit @('List of devices attached', "$serial`tunauthorized product:fake")
        return
    }
    if ($scenario -ceq 'adb-duplicate') {
        Emit @('List of devices attached',
            "$serial`tdevice product:fake transport_id:1",
            "$serial`tdevice product:fake transport_id:3")
        return
    }
    $usbDetails = if ($scenario -like 'windows-pnp-*') {
        'product:fake transport_id:1'
    } else {
        'usb:1-2 product:fake transport_id:1'
    }
    Emit @('List of devices attached',
        "$serial`tdevice $usbDetails",
        "$wifiSerial`tdevice product:fake transport_id:2")
    return
}
if ($argv.Count -eq 3 -and $argv[0] -ceq '-s' -and
        $argv[2] -ceq 'get-devpath') {
    if ($argv[1] -ceq $serial) {
        if ($scenario -like 'windows-pnp-*') { Emit @('unknown'); return }
        if ($scenario -ceq 'local-serial-tcp-devpath') {
            Emit @('tcp:192.0.2.10:5555'); return
        }
        Emit @('usb:1-2'); return
    }
    if ($argv[1] -ceq $wifiSerial) { Emit @('tcp:192.0.2.10:5555'); return }
}
if ($argv.Count -lt 3 -or $argv[0] -cne '-s' -or $argv[1] -cne $serial) {
    Emit @('unexpected fake ADB prefix') 90
    return
}
if ($argv[2] -ceq 'push' -and $argv.Count -eq 5) {
    $device = [string]$argv[4]
    if ($device -cnotmatch '^/data/local/tmp/qc-rc8-perfetto-[0-9a-f]{32}\.pbtxt$') {
        Emit @('unsafe push destination') 91; return
    }
    if ($scenario -ceq 'push-fail') { Emit @('fixture push failure') 97; return }
    [IO.File]::WriteAllText($configShaPath,
        (Get-FileHash -LiteralPath ([string]$argv[3]) -Algorithm SHA256).Hash)
    [IO.File]::Copy([string]$argv[3], $capturedConfigPath, $true)
    Emit @('fixture push')
    return
}
if ($argv[2] -ceq 'pull' -and $argv.Count -eq 5) {
    $device = [string]$argv[3]
    if ($device -cnotmatch '^/data/local/tmp/qc-rc8-perfetto-[0-9a-f]{32}\.pftrace$') {
        Emit @('unsafe pull source') 92; return
    }
    if ($scenario -ceq 'pull-fail') { Emit @('fixture pull failure') 98; return }
    [IO.File]::Copy($traceFixture, [string]$argv[4], $true)
    Emit @('fixture pull')
    return
}
if ($argv[2] -cne 'shell' -or $argv.Count -lt 4) {
    Emit @('unexpected fake ADB command') 93
    return
}
$a = [string[]]@($argv[3..($argv.Count - 1)])

if ($a[0] -ceq 'getprop' -and $a.Count -eq 2 -and
        $a[1] -ceq 'ro.serialno') {
    if ($scenario -ceq 'windows-pnp-serial-mismatch') {
        Emit @('OTHER_FIXTURE_SERIAL'); return
    }
    Emit @($serial); return
}
if ($a[0] -ceq 'pidof' -and $a.Count -eq 2) {
    if ($a[1] -ceq $stable) {
        if ($scenario -ceq 'stable-running' -or
                ($scenario -ceq 'stable-after-capture' -and
                 (Test-Path -LiteralPath $started))) {
            Emit @('9999'); return
        }
        Emit @() 1; return
    }
    if ($a[1] -ceq $lab) { Emit @('4242'); return }
}
if ($a[0] -ceq 'dumpsys' -and $a[1] -ceq 'package') {
    $versionCode = if ($scenario -ceq 'wrong-version') { 72 } else { 71 }
    Emit @("  versionCode=$versionCode minSdk=29 targetSdk=34",
        '  versionName=6.0.1-26.2-vivecraft-personal.12-rc.8')
    return
}
if ($a[0] -ceq 'pm' -and $a[1] -ceq 'path') {
    Emit @('package:' + $base); return
}
if ($a[0] -ceq 'sha256sum' -and $a.Count -eq 2) {
    $path = [string]$a[1]
    $sha = if ($path -ceq $base) {
        if ($scenario -ceq 'wrong-apk') { '0' * 64 } else { $apkSha }
    } elseif ($path -ceq $core) {
        if ($scenario -ceq 'wrong-core') { '0' * 64 } else { $coreSha }
    } elseif ($path -ceq $veq) {
        if ($scenario -ceq 'wrong-veq') { '0' * 64 } else { $veqSha }
    } elseif ($path -cmatch '\.pbtxt$') {
        [IO.File]::ReadAllText($configShaPath).Trim()
    } elseif ($path -cmatch '\.pftrace$') {
        if ($scenario -ceq 'trace-hash-mismatch') { 'F' * 64 } else { $traceSha }
    } else {
        Emit @('unexpected sha path') 94; return
    }
    Emit @(($sha.ToUpperInvariant()) + '  ' + $path)
    return
}
if ($a[0] -ceq 'cat' -and $a[1] -ceq '/proc/4242/stat') {
    $startTicks = if ((Test-Path -LiteralPath $started) -and
            $scenario -ceq 'start-changed-after-capture') { '123457' } else { '123456' }
    $suffix = @('S') + @((1..18) | ForEach-Object { '0' }) + @($startTicks)
    Emit @(('4242 (' + $lab + ') ' + ($suffix -join ' ')))
    return
}
if ($a[0] -ceq 'cat' -and $a[1] -ceq '/proc/4242/task/*/comm') {
    Emit @('QuestCraft-JVM','Render thread','OpenXR-input'); return
}
if ($a[0] -ceq 'dumpsys' -and $a[1] -ceq 'activity') {
    $focusedComponent = $immersive
    if ($scenario -ceq 'focus-prefix-package') {
        $focusedComponent = $lab + '.evil/pojlib.UnityPlayerActivity'
    } elseif ((Test-Path -LiteralPath $started) -and
            $scenario -ceq 'focus-lost-after-capture') {
        $focusedComponent = 'com.example.other/.Main'
    } elseif ($scenario -ceq 'focus-wrong-global-package') {
        $focusedComponent = 'com.example.other/.Main'
    } elseif ($scenario -ceq 'focus-stable-global') {
        $focusedComponent = $stableImmersive
    }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Display #0 (activities from top to bottom):')
    $lines.Add('  topResumedActivity=ActivityRecord{10 u0 com.oculus.vrshell/.MainActivity t10}')
    $lines.Add('  ResumedActivity: ActivityRecord{10 u0 com.oculus.vrshell/.MainActivity t10}')
    $lines.Add('Display #2 (activities from top to bottom):')
    $lines.Add('  topResumedActivity=ActivityRecord{20 u0 ' + $immersive + ' t20}')
    $lines.Add('  ResumedActivity: ActivityRecord{20 u0 ' + $immersive + ' t20}')
    if ($scenario -ceq 'focus-duplicate-lab-display') {
        $lines.Add('  ResumedActivity: ActivityRecord{21 u0 ' + $immersive + ' t21}')
    }
    $lines.Add('Display #3 (activities from top to bottom):')
    $lines.Add('  topResumedActivity=ActivityRecord{30 u0 com.oculus.systemux/.ControlBarActivity t30}')
    $lines.Add('  ResumedActivity: ActivityRecord{30 u0 com.oculus.systemux/.ControlBarActivity t30}')
    $lines.Add('Display #4 (activities from top to bottom):')
    $lines.Add('  topResumedActivity=ActivityRecord{40 u0 com.oculus.toasts/.ToastActivity t40}')
    $lines.Add('  ResumedActivity: ActivityRecord{40 u0 com.oculus.toasts/.ToastActivity t40}')
    $lines.Add('Display #5 (activities from top to bottom):')
    $lines.Add('  topResumedActivity=ActivityRecord{50 u0 com.oculus.vrshell/.MainActivity t50}')
    $lines.Add('Display #7 (activities from top to bottom):')
    $lines.Add('  topResumedActivity=ActivityRecord{70 u0 com.oculus.systemux/.SystemUiActivity t70}')
    $lines.Add('Resumed: ActivityRecord{20 u0 ' + $immersive + ' t20}')
    $lines.Add('ActivityTaskSupervisor state:')
    if ($scenario -cne 'focus-missing-current') {
        foreach ($unused in 1..5) { $lines.Add('  mCurrentFocus=null') }
    }
    if ($scenario -cnotin @('focus-missing-current','focus-null-only')) {
        if ($scenario -ceq 'focus-malformed-nonnull') {
            $lines.Add('  mCurrentFocus=null Window{20 u0 ' + $immersive + '}')
        } else {
            $lines.Add('  mCurrentFocus=Window{20 u0 ' + $focusedComponent + '}')
        }
    }
    if ($scenario -ceq 'focus-ambiguous-global') {
        $lines.Add('  mCurrentFocus=Window{22 u0 ' + $immersive + '}')
    }
    foreach ($unused in 1..5) { $lines.Add('  mFocusedApp=null') }
    if ($scenario -cne 'focus-null-only') {
        $lines.Add('  mFocusedApp=ActivityRecord{20 u0 ' + $focusedComponent + ' t20}')
    }
    Emit ([string[]]$lines)
    return
}
if ($a[0] -ceq '/debug_ramdisk/su' -and $a[1] -ceq '-c' -and
        $a[2] -ceq "'id -u'") {
    Emit @('0'); return
}
if ($a[0] -ceq '/debug_ramdisk/su' -and $a[1] -ceq '-c' -and
        $a[2] -ceq "'cat /sys/kernel/tracing/available_events'") {
    $events = @(
        'sched:sched_switch','sched:sched_waking','sched:sched_wakeup',
        'power:cpu_frequency','power:cpu_idle','gpu_mem:gpu_mem_total',
        'kgsl:adreno_cmdbatch_submitted','kgsl:adreno_cmdbatch_retired',
        'kgsl:kgsl_buslevel','kgsl:kgsl_clk','kgsl:kgsl_gpubusy',
        'kgsl:kgsl_pwrlevel')
    if ($scenario -ceq 'missing-event') {
        $events = @($events | Where-Object { $_ -cne 'power:cpu_idle' })
    }
    Emit @($events -join "`n"); return
}
if ($a[0] -ceq 'test' -and $a[1] -ceq '!' -and
        $a[2] -cin @('-e','-L')) {
    if ($scenario -ceq 'cleanup-fail' -and
            (Test-Path -LiteralPath $cleaned) -and $a[3] -cmatch '\.pftrace$') {
        Emit @() 1; return
    }
    Emit @(); return
}
if ($a[0] -ceq 'perfetto' -and $a -ccontains '--background-wait') {
    if ($scenario -ceq 'perfetto-fail') { Emit @('fixture perfetto failure') 99; return }
    [IO.File]::WriteAllText($started, 'yes')
    Emit @('pid: 7777'); return
}
if ($a[0] -ceq 'test' -and $a[1] -ceq '-d' -and $a[2] -ceq '/proc/7777') {
    if ($scenario -ceq 'exact' -and -not (Test-Path -LiteralPath $poll)) {
        [IO.File]::WriteAllText($poll, 'once')
        Emit @(); return
    }
    Emit @() 1; return
}
if ($a[0] -ceq 'stat' -and $a[1] -ceq '-c' -and $a[2] -ceq '%s') {
    Emit @([string](Get-Item -LiteralPath $traceFixture).Length); return
}
if ($a[0] -ceq 'rm' -and $a[1] -ceq '-f' -and $a.Count -eq 4) {
    foreach ($path in $a[2..3]) {
        if ($path -cnotmatch '^/data/local/tmp/qc-rc8-perfetto-[0-9a-f]{32}\.(?:pbtxt|pftrace)$') {
            Emit @('unsafe cleanup path') 95; return
        }
    }
    [IO.File]::WriteAllText($cleaned, ($a[2..3] -join "`n"))
    Emit @(); return
}
Emit @(('unexpected fake ADB shell command: ' + ($a -join '|'))) 96
'@

$fakeTraceProcessorSource = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$argv = [string[]]@($args)
if ($argv.Count -ne 4 -or $argv[0] -cne 'query' -or $argv[1] -cne '-f') {
    throw 'Unexpected fake trace_processor invocation.'
}
$query = [IO.File]::ReadAllText([string]$argv[2])
$match = [regex]::Match($query, '^-- QC_QUERY: (?<name>[A-Z_]+)',
    [Text.RegularExpressions.RegexOptions]::Multiline)
if (-not $match.Success) { throw 'Missing query marker.' }
$name = [string]$match.Groups['name'].Value
[IO.File]::AppendAllText([string]$env:QC_RC8_PERFETTO_TP_LOG,
    $name + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
switch ($name) {
    'SUMMARY' {
        'trace_seconds,app_upid_count,sched_rows,app_cpu_ms,app_one_core_percent,runnable_wait_ms,runnable_wait_one_core_percent,app_thread_count,process_counter_samples'
        $duration = if ([string]$env:QC_RC8_PERFETTO_SCENARIO -ceq 'short-trace') {
            '27.999'
        } else {
            '30.000'
        }
        "$duration,1,9000,12345.5,41.152,45000.0,150.000,21,120"
    }
    'THREADS' {
        'thread_name,cpu_ms,app_cpu_percent,one_core_percent,runnable_wait_ms,runnable_p95_ms,runnable_max_ms,waits_ge_1ms,waits_ge_2ms,waits_ge_4ms'
        'Render thread,9000.0,72.9,30.0,40.0,0.7,3.2,10,4,0'
        'Server thread,900.0,7.3,3.0,4.0,0.2,1.0,1,0,0'
        'G1 Conc#0,800.0,6.5,2.7,3.0,0.2,0.9,0,0,0'
        'Sodium Async Cu,700.0,5.7,2.3,2.0,0.1,0.8,0,0,0'
        'UnityChoreograp,600.0,4.9,2.0,2.0,0.1,0.7,0,0,0'
        'UnityMain,500.0,4.1,1.7,2.0,0.1,0.6,0,0,0'
        'FMOD stream,400.0,3.2,1.3,1.0,0.1,0.5,0,0,0'
        'FMOD mixer,300.0,2.4,1.0,1.0,0.1,0.4,0,0,0'
        'alsoft-mixer,200.0,1.6,0.7,1.0,0.1,0.3,0,0,0'
        'Thread-13,150.0,1.2,0.5,1.0,0.1,0.3,0,0,0'
        'private-user@example.com,1000.0,8.1,3.3,20.0,0.4,1.8,3,0,0'
    }
    'CPU_FREQUENCY' {
        'cpu,freq_khz,samples,duration_ms'
        '6,2803200,40,20000.0'
        '7,2803200,40,21000.0'
    }
    'CPU_IDLE' {
        'cpu,idle_state,samples,duration_ms'
        '6,0,18,4000.0'
        '7,4294967295,20,5000.0'
    }
    'PROCESS_COUNTERS' {
        'metric,samples,mean_value,p95_value,max_value'
        'RssBytes,30,1100000000,1200000000,1250000000'
        'SwapBytes,30,1000000,2000000,3000000'
    }
    'GPU_MEMORY' {
        'samples,mean_mib,p95_mib,max_mib'
        '30,256.0,300.0,320.0'
    }
    'KGSL_EVENTS' {
        'metric,occurrences'
        'Submitted,1800'
        'Retired,1799'
    }
    'TRACE_HEALTH' {
        foreach ($required in @(
            'ftrace_cpu_dropped_events_delta',
            'ftrace_cpu_commit_overrun_delta',
            'ftrace_cpu_overrun_delta',
            'traced_buf_data_loss_overwrite')) {
            if (-not $query.Contains($required, [StringComparison]::Ordinal)) {
                throw "Trace-health query omitted $required"
            }
        }
        'ftrace_setup_errors,ftrace_dropped_events,ftrace_overruns,perf_samples_skipped,data_loss,buffer_overruns'
        if ([string]$env:QC_RC8_PERFETTO_SCENARIO -ceq 'trace-health-drops') {
            '0,3,2,0,0,1'
        } elseif ([string]$env:QC_RC8_PERFETTO_SCENARIO -ceq
                'trace-health-setup') {
            '4,0,0,0,0,0'
        } else {
            '0,0,0,0,0,0'
        }
    }
    default { throw "Unexpected query $name" }
}
'@

[IO.File]::WriteAllText($fakeAdb, $fakeAdbSource,
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($fakeTraceProcessor, $fakeTraceProcessorSource,
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($poisonAdb,
    "@echo off`r`necho real-adb-resolution-attempt>>`"$poisonLog`"`r`nexit /b 99`r`n",
    [Text.Encoding]::ASCII)
$traceBytes = [byte[]]::new(8192)
for ($index = 0; $index -lt $traceBytes.Length; $index++) {
    $traceBytes[$index] = [byte](($index * 17 + 31) % 256)
}
[IO.File]::WriteAllBytes((Join-Path $fakeState 'trace-fixture.bin'), $traceBytes)

# These functions deliberately shadow the Windows PnpDevice module for this
# Host-only process. They expose only generic fixture records; no live PnP or
# Android device is queried by the suite.
function Get-PnpDevice {
    [CmdletBinding()]
    param(
        [switch] $PresentOnly,
        [string] $InstanceId,
        [string] $FriendlyName
    )
    if (-not [string]::IsNullOrEmpty($FriendlyName)) {
        throw 'Fixture forbids FriendlyName lookup because the real cmdlet does not support wildcards.'
    }
    $scenario = [string]$env:QC_RC8_PERFETTO_SCENARIO
    $serial = 'QUEST_RC8_FAKE'
    $expectedParent = 'USB\VID_2833&PID_5013\' + $serial
    if (-not [string]::IsNullOrEmpty($InstanceId)) {
        if ($scenario -ceq 'windows-pnp-wrong-vidpid') {
            return [pscustomobject]@{
                InstanceId = 'USB\VID_0000&PID_0000\QUEST_RC8_FAKE'
                FriendlyName = 'Fixture USB Composite Device'
                Status = 'OK'; Present = $true
            }
        }
        return [pscustomobject]@{
            InstanceId = $expectedParent
            FriendlyName = 'Fixture USB Composite Device'
            Status = 'OK'
            Present = ($scenario -cne 'windows-pnp-parent-not-present')
        }
    }
    if ($scenario -ceq 'windows-pnp-missing-child') { return @() }
    return [pscustomobject]@{
        InstanceId = 'USB\VID_2833&PID_5013&MI_03\FIXTURE_CHILD'
        FriendlyName = if ($scenario -ceq 'windows-pnp-missing-adb-name') {
            'Fixture Composite Interface'
        } else {
            'Fixture Composite ADB Interface'
        }
        Status = if ($scenario -ceq 'windows-pnp-child-error') { 'Error' } else { 'OK' }
        Present = ($scenario -cne 'windows-pnp-child-not-present')
    }
}

function Get-PnpDeviceProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $InstanceId,
        [Parameter(Mandatory)][string] $KeyName
    )
    if ($KeyName -cne 'DEVPKEY_Device_Parent') {
        throw 'Fixture received a non-parent PnP key.'
    }
    $parent = if ([string]$env:QC_RC8_PERFETTO_SCENARIO -ceq
            'windows-pnp-wrong-parent') {
        'USB\VID_2833&PID_5013\OTHER_FIXTURE'
    } else {
        'USB\VID_2833&PID_5013\QUEST_RC8_FAKE'
    }
    [pscustomobject]@{ KeyName = $KeyName; Data = $parent }
}

$oldState = $env:QC_RC8_PERFETTO_FAKE_STATE
$oldScenario = $env:QC_RC8_PERFETTO_SCENARIO
$oldTpLog = $env:QC_RC8_PERFETTO_TP_LOG
$oldPath = $env:PATH
try {
    $env:QC_RC8_PERFETTO_FAKE_STATE = $fakeState
    $env:QC_RC8_PERFETTO_SCENARIO = 'exact'
    $env:QC_RC8_PERFETTO_TP_LOG = $tpLog
    $env:PATH = $poisonDirectory + [IO.Path]::PathSeparator + $oldPath

    $beforeCalls = Get-CallCount $callLog
    $self = & $guard -Action SelfTest
    $plan = & $guard -Action Plan
    Require ($self.Result -ceq 'PASS' -and $self.DeviceInvocations -eq 0 -and
            $self.WindowsUsbPnpCases -ceq 'PASS' -and
            $self.MultiDisplayFocusCases -ceq 'PASS') `
        'Default SelfTest was not Host-only.'
    Require ($plan.Result -ceq 'PLAN_ONLY' -and $plan.DeviceInvocations -eq 0) `
        'Plan was not Host-only.'
    Require ((Get-CallCount $callLog) -eq $beforeCalls -and
            -not (Test-Path -LiteralPath $poisonLog)) `
        'SelfTest/Plan resolved real or fake ADB.'

    foreach ($gateCase in @(
        [pscustomobject]@{ Name='read'; Run={
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor `
                -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
        }; Pattern='AllowDeviceRead' },
        [pscustomobject]@{ Name='ephemeral'; Run={
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor `
                -AllowDeviceRead -AllowRootRead | Out-Null
        }; Pattern='AllowEphemeralDeviceIo' },
        [pscustomobject]@{ Name='root'; Run={
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor `
                -AllowDeviceRead -AllowEphemeralDeviceIo | Out-Null
        }; Pattern='AllowRootRead' }
    )) {
        $before = Get-CallCount $callLog
        Require (Test-ExpectedFailure $gateCase.Run $gateCase.Pattern) `
            "Capability gate $($gateCase.Name) was bypassed."
        Require ((Get-CallCount $callLog) -eq $before) `
            "Capability gate $($gateCase.Name) invoked ADB before rejection."
    }

    $before = Get-CallCount $callLog
    Require (Test-ExpectedFailure {
        & $guard -Action Capture -AdbPath $fakeAdb `
            -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
            -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
    } 'explicit USB ADB serial') 'Capture accepted auto device selection.'
    Require ((Get-CallCount $callLog) -eq $before) `
        'Auto-selection rejection invoked ADB before failing closed.'

    $before = Get-CallCount $callLog
    Require (Test-ExpectedFailure {
        & $guard -Action Capture -Serial '192.0.2.10:5555' -AdbPath $fakeAdb `
            -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
            -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
    } 'explicit USB ADB serial') 'Capture accepted a TCP/Wi-Fi endpoint.'
    Require ((Get-CallCount $callLog) -eq $before) `
        'Wi-Fi rejection invoked ADB before failing closed.'

    foreach ($networkSerial in @(
        'adb-QUEST._adb-tls-connect._tcp', 'quest-fixture.local',
        'host.example:5555')) {
        $before = Get-CallCount $callLog
        Require (Test-ExpectedFailure {
            & $guard -Action Capture -Serial $networkSerial -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
                -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
        } 'explicit USB ADB serial') "Capture accepted network-shaped serial: $networkSerial"
        Require ((Get-CallCount $callLog) -eq $before) `
            'A network-shaped serial reached ADB before rejection.'
    }

    foreach ($adbRowFailure in @('adb-unauthorized','adb-duplicate')) {
        $env:QC_RC8_PERFETTO_SCENARIO = $adbRowFailure
        Require (Test-ExpectedFailure {
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
                -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
        } 'not connected and authorized') `
            "Capture accepted invalid exact ADB row: $adbRowFailure"
    }

    $env:QC_RC8_PERFETTO_SCENARIO = 'local-serial-tcp-devpath'
    Require (Test-ExpectedFailure {
        & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
            -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
            -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
    } 'not a proven USB transport') `
        'A network transport was accepted behind a local-shaped serial.'

    $env:QC_RC8_PERFETTO_SCENARIO = 'windows-pnp-valid'
    $windowsCapture = & $guard -Action Capture -Serial QUEST_RC8_FAKE `
        -AdbPath $fakeAdb -TraceProcessorPath $fakeTraceProcessor `
        -AllowDeviceRead -AllowEphemeralDeviceIo -AllowRootRead
    $windowsReportText =
        [IO.File]::ReadAllText([string]$windowsCapture.AggregateReport)
    $windowsReport = $windowsReportText | ConvertFrom-Json -Depth 20
    Require ($windowsCapture.Result -ceq 'CAPTURED_ANALYZED_AND_PURGED' -and
            $windowsReport.Identity.UsbTransportProven -and
            $windowsReport.Identity.UsbTransportProofMethod -ceq
                'windows-pnp-parent' -and
            -not $windowsReportText.Contains('QUEST_RC8_FAKE',
                [StringComparison]::Ordinal)) `
        'The exact Windows ADB-child/USB-parent fallback was not accepted or leaked identity.'
    Remove-Item -LiteralPath ([string]$windowsCapture.AggregateReport) -Force
    Require (-not (Test-Path -LiteralPath ([string]$windowsCapture.AggregateReport))) `
        'The Host test could not reset its synthetic aggregate between cases.'

    foreach ($pnpFailure in @(
        [pscustomobject]@{ Scenario='windows-pnp-wrong-parent'; Pattern='ADB child' },
        [pscustomobject]@{ Scenario='windows-pnp-child-not-present'; Pattern='ADB child' },
        [pscustomobject]@{ Scenario='windows-pnp-parent-not-present'; Pattern='USB parent' },
        [pscustomobject]@{ Scenario='windows-pnp-missing-child'; Pattern='ADB child' },
        [pscustomobject]@{ Scenario='windows-pnp-missing-adb-name'; Pattern='ADB child' },
        [pscustomobject]@{ Scenario='windows-pnp-wrong-vidpid'; Pattern='USB parent' },
        [pscustomobject]@{ Scenario='windows-pnp-serial-mismatch'; Pattern='hardware serial' }
    )) {
        $env:QC_RC8_PERFETTO_SCENARIO = $pnpFailure.Scenario
        Require (Test-ExpectedFailure {
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
                -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
        } $pnpFailure.Pattern) `
            "Windows PnP failure passed: $($pnpFailure.Scenario); observed: $script:LastExpectedFailureMessage"
    }
    $env:QC_RC8_PERFETTO_SCENARIO = 'exact'

    foreach ($negative in @(
        [pscustomobject]@{ Scenario='stable-running'; Pattern='Stable is running' },
        [pscustomobject]@{ Scenario='wrong-version'; Pattern='not exact RC8' },
        [pscustomobject]@{ Scenario='wrong-apk'; Pattern='not the exact locked RC8 APK' },
        [pscustomobject]@{ Scenario='wrong-core'; Pattern='Core is not exact RC8' },
        [pscustomobject]@{ Scenario='wrong-veq'; Pattern='companion is not exact RC8' },
        [pscustomobject]@{ Scenario='missing-event'; Pattern='Required tracepoint' },
        [pscustomobject]@{ Scenario='focus-prefix-package'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-wrong-global-package'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-stable-global'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-duplicate-lab-display'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-ambiguous-global'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-malformed-nonnull'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-null-only'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='focus-missing-current'; Pattern='not the focused' }
    )) {
        Get-ChildItem -LiteralPath $fakeState -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @(
                'perfetto-started','perfetto-polled','device-cleaned','config-sha',
                'captured-config.pbtxt') } |
            Remove-Item -Force
        $env:QC_RC8_PERFETTO_SCENARIO = $negative.Scenario
        Require (Test-ExpectedFailure {
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
                -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
        } $negative.Pattern) "Identity/event failure passed: $($negative.Scenario); observed: $script:LastExpectedFailureMessage"
    }

    foreach ($runtimeFailure in @(
        [pscustomobject]@{ Scenario='push-fail'; Pattern='config push failed' },
        [pscustomobject]@{ Scenario='perfetto-fail'; Pattern='ADB operation failed' },
        [pscustomobject]@{ Scenario='pull-fail'; Pattern='trace pull failed' },
        [pscustomobject]@{ Scenario='focus-lost-after-capture'; Pattern='not the focused' },
        [pscustomobject]@{ Scenario='start-changed-after-capture'; Pattern='incarnation changed' },
        [pscustomobject]@{ Scenario='stable-after-capture'; Pattern='Stable is running' },
        [pscustomobject]@{ Scenario='trace-hash-mismatch'; Pattern='byte identity' },
        [pscustomobject]@{ Scenario='cleanup-fail'; Pattern='cleanup failed' },
        [pscustomobject]@{ Scenario='short-trace'; Pattern='duration fell outside' }
    )) {
        Get-ChildItem -LiteralPath $fakeState -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @(
                'perfetto-started','perfetto-polled','device-cleaned','config-sha',
                'captured-config.pbtxt') } |
            Remove-Item -Force
        $env:QC_RC8_PERFETTO_SCENARIO = $runtimeFailure.Scenario
        Require (Test-ExpectedFailure {
            & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
                -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
                -AllowEphemeralDeviceIo -AllowRootRead | Out-Null
        } $runtimeFailure.Pattern) `
            "Runtime/cleanup failure passed: $($runtimeFailure.Scenario); observed: $script:LastExpectedFailureMessage"
        Require (Test-Path -LiteralPath (Join-Path $fakeState 'device-cleaned')) `
            "Failure path omitted its cleanup attempt: $($runtimeFailure.Scenario)"
        Require (@(Get-ChildItem -LiteralPath $repo -Recurse -File |
                Where-Object { $_.Name -ceq 'aggregate.json' -or
                    $_.Extension -cin @('.pftrace','.pbtxt','.sql') }).Count -eq 0) `
            "Failure path published aggregate/raw evidence: $($runtimeFailure.Scenario)"
    }

    Get-ChildItem -LiteralPath $fakeState -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @(
            'perfetto-started','perfetto-polled','device-cleaned','config-sha') } |
        Remove-Item -Force
    if (Test-Path -LiteralPath $tpLog) { Remove-Item -LiteralPath $tpLog -Force }
    $env:QC_RC8_PERFETTO_SCENARIO = 'exact'
    $capture = & $guard -Action Capture -Serial QUEST_RC8_FAKE -AdbPath $fakeAdb `
        -TraceProcessorPath $fakeTraceProcessor -AllowDeviceRead `
        -AllowEphemeralDeviceIo -AllowRootRead
    Require ($capture.Result -ceq 'CAPTURED_ANALYZED_AND_PURGED' -and
            $capture.ExactRc8 -and $capture.TraceHealthy -and
            -not $capture.RawTraceRetained -and -not $capture.StableTouched) `
        'The exact fake capture did not publish a healthy aggregate result.'
    Require (Test-Path -LiteralPath $capture.AggregateReport -PathType Leaf) `
        'The aggregate report was not published.'
    $reportText = [IO.File]::ReadAllText([string]$capture.AggregateReport)
    $report = $reportText | ConvertFrom-Json -Depth 20
    Require ($report.SchemaVersion -eq 3 -and
            $report.Identity.UsbTransportProven -and
            $report.Identity.UsbTransportProofMethod -ceq 'adb-devpath' -and
            $report.Privacy.HostRawTempPurgedBeforePublish -and
            $report.Identity.CapturedPid -eq 4242 -and
            $report.Identity.ProcessStartTicks -eq 123456 -and
            $report.Identity.StableStoppedBeforeDuringAndAfter -and
            $report.Identity.FocusedBeforeDuringAndAfter -and
            $report.Identity.CoreMatchedBeforeAndAfter -and
            $report.Identity.CompanionMatchedBeforeAndAfter) `
        'The aggregate omitted exact PID/start/focus/identity fences.'
    Require ($report.TraceHealth.UsableForSchedulerConclusions -and
            $report.TraceHealth.FtraceSetupErrors -eq 0 -and
            $report.TraceHealth.FtraceDroppedEvents -eq 0 -and
            $report.TraceHealth.DataLoss -eq 0 -and
            $report.TraceHealth.BufferOverruns -eq 0) `
        'Trace-health metrics were not preserved.'
    Require ($report.GpuMemory.Samples -eq 30 -and
            $report.GpuMemory.P95MiB -eq 300.0 -and
            $report.KgslEvents.UnmatchedDelta -eq 1 -and
            $report.KgslEvents.PSObject.Properties.Name -cnotcontains 'GpuBusy' -and
            $report.KgslEvents.PSObject.Properties.Name -cnotcontains 'BusLevel' -and
            $report.KgslEvents.PSObject.Properties.Name -cnotcontains 'Clock' -and
            $report.KgslEvents.PSObject.Properties.Name -cnotcontains 'PowerLevel') `
        'PID-scoped GPU/KGSL aggregates were not preserved.'
    foreach ($key in @(
        'sched_sched_switch','sched_sched_waking','sched_sched_wakeup',
        'power_cpu_frequency','power_cpu_idle','gpu_mem_gpu_mem_total',
        'kgsl_adreno_cmdbatch_submitted','kgsl_adreno_cmdbatch_retired')) {
        Require ($report.EventAvailability.$key -eq $true -and
                $report.EventCaptureSelection.$key -eq $true) `
            "A selected fixed tracepoint was not reported accurately: $key"
    }
    foreach ($key in @(
        'kgsl_kgsl_buslevel','kgsl_kgsl_clk','kgsl_kgsl_gpubusy',
        'kgsl_kgsl_pwrlevel')) {
        Require ($report.EventAvailability.$key -eq $true -and
                $report.EventCaptureSelection.$key -eq $false) `
            "An excluded vendor tracepoint was not distinguished from availability: $key"
    }
    Require ($report.EventSelectionPolicy.Profile -ceq
            'scheduler-core-with-proven-gpu-lifecycle' -and
            ([string]$report.EventSelectionPolicy.Reason).Contains(
                'correlation is not proof', [StringComparison]::Ordinal)) `
        'The aggregate overclaimed the inferred vendor-event failure.'
    $capturedConfig = [IO.File]::ReadAllText(
        (Join-Path $fakeState 'captured-config.pbtxt'))
    foreach ($requiredEvent in @(
        'sched/sched_switch','sched/sched_waking','sched/sched_wakeup',
        'power/cpu_frequency','power/cpu_idle','gpu_mem/gpu_mem_total',
        'kgsl/adreno_cmdbatch_submitted','kgsl/adreno_cmdbatch_retired')) {
        Require ($capturedConfig.Contains(
                'ftrace_events: "' + $requiredEvent + '"',
                [StringComparison]::Ordinal)) `
            "The live-shaped config omitted selected event $requiredEvent"
    }
    foreach ($excludedEvent in @(
        'kgsl/kgsl_buslevel','kgsl/kgsl_clk','kgsl/kgsl_gpubusy',
        'kgsl/kgsl_pwrlevel')) {
        Require (-not $capturedConfig.Contains(
                'ftrace_events: "' + $excludedEvent + '"',
                [StringComparison]::Ordinal)) `
            "The live-shaped config enabled excluded event $excludedEvent"
    }
    Require ($report.AppScheduling.RunnableWaitOneCorePercent -eq 150.0 -and
            $report.AppScheduling.PSObject.Properties.Name -cnotcontains
                'RunnableWaitWallPercent') `
        'Summed runnable delay was not labeled as a one-core-equivalent metric.'
    $categories = @($report.AppScheduling.Threads | ForEach-Object { $_.Category })
    foreach ($expectedCategory in @(
        'RenderThread','ServerThread','GarbageCollector','SodiumAsyncWorker',
        'UnityFramePacer','UnityRuntimeMain','FmodStreamAudio',
        'FmodMixerAudio','OpenAlMixerAudio','OtherAppThread'
    )) {
        Require ($categories -ccontains $expectedCategory) `
            "Thread-name normalization omitted fixed category $expectedCategory."
    }
    Require (@($report.AppScheduling.Threads |
            Where-Object { $_.Category -ceq 'OtherAppThread' }).Count -eq 2) `
        'Generic or private thread names were guessed instead of privacy-normalized.'
    Require ($categories -ccontains 'RenderThread' -and
            $categories -ccontains 'OtherAppThread') `
        'Thread-name normalization was not applied.'
    foreach ($secret in @(
        'private-user@example.com','Render thread','Server thread','G1 Conc#0',
        'Sodium Async Cu','UnityChoreograp','UnityMain','FMOD stream',
        'FMOD mixer','alsoft-mixer','Thread-13','QUEST_RC8_FAKE',
        'com.qcxr.qcxr.canary262',
        'com.qcxr.qcxr.dev262','/data/local/tmp','.pftrace','.pbtxt',
        'trace-fixture','identity-marker-should-not-persist',
        'world-marker-should-not-persist','network-marker-should-not-persist')) {
        Require (-not $reportText.Contains($secret,
                [StringComparison]::OrdinalIgnoreCase)) `
            "Aggregate report persisted forbidden raw identity/data: $secret"
    }
    $rawArtifacts = @(Get-ChildItem -LiteralPath $repo -Recurse -File |
        Where-Object { $_.Extension -cin @('.pftrace','.pbtxt','.sql') })
    Require ($rawArtifacts.Count -eq 0) 'A raw trace/config/query escaped Host temp.'
    Require (Test-Path -LiteralPath (Join-Path $fakeState 'device-cleaned')) `
        'The fake device cleanup transaction was not observed.'

    Get-ChildItem -LiteralPath $fakeState -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @(
            'perfetto-started','perfetto-polled','device-cleaned','config-sha') } |
        Remove-Item -Force
    $env:QC_RC8_PERFETTO_SCENARIO = 'trace-health-drops'
    $unhealthyCapture = & $guard -Action Capture -Serial QUEST_RC8_FAKE `
        -AdbPath $fakeAdb -TraceProcessorPath $fakeTraceProcessor `
        -AllowDeviceRead -AllowEphemeralDeviceIo -AllowRootRead
    $unhealthy = Get-Content -Raw -LiteralPath $unhealthyCapture.AggregateReport |
        ConvertFrom-Json -Depth 20
    Require (-not $unhealthyCapture.TraceHealthy -and
            -not $unhealthy.TraceHealth.UsableForSchedulerConclusions -and
            $unhealthy.TraceHealth.FtraceDroppedEvents -eq 3 -and
            $unhealthy.TraceHealth.FtraceOverruns -eq 2 -and
            $unhealthy.TraceHealth.BufferOverruns -eq 1) `
        'Nonzero v58.2 ftrace drop/overrun health counters escaped the fail-closed result.'
    $env:QC_RC8_PERFETTO_SCENARIO = 'exact'

    Get-ChildItem -LiteralPath $fakeState -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @(
            'perfetto-started','perfetto-polled','device-cleaned','config-sha',
            'captured-config.pbtxt') } |
        Remove-Item -Force
    $env:QC_RC8_PERFETTO_SCENARIO = 'trace-health-setup'
    $setupFailureCapture = & $guard -Action Capture -Serial QUEST_RC8_FAKE `
        -AdbPath $fakeAdb -TraceProcessorPath $fakeTraceProcessor `
        -AllowDeviceRead -AllowEphemeralDeviceIo -AllowRootRead
    $setupFailure = Get-Content -Raw `
        -LiteralPath $setupFailureCapture.AggregateReport |
        ConvertFrom-Json -Depth 20
    Require (-not $setupFailureCapture.TraceHealthy -and
            -not $setupFailure.TraceHealth.UsableForSchedulerConclusions -and
            $setupFailure.TraceHealth.FtraceSetupErrors -eq 4) `
        'Nonzero ftrace setup errors escaped the fail-closed result.'
    $env:QC_RC8_PERFETTO_SCENARIO = 'exact'

    $queries = @([IO.File]::ReadAllLines($tpLog) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $expectedQueries = @('SUMMARY','THREADS','CPU_FREQUENCY','CPU_IDLE',
        'PROCESS_COUNTERS','GPU_MEMORY','KGSL_EVENTS','TRACE_HEALTH')
    $badQueryCounts = @(foreach ($queryName in $expectedQueries) {
        if (@($queries | Where-Object { [string]$_ -ceq $queryName }).Count -ne 3) {
            $queryName
        }
    })
    Require ($queries.Count -eq (3 * $expectedQueries.Count) -and
            @($queries | Where-Object { $_ -cnotin $expectedQueries }).Count -eq 0 -and
            $badQueryCounts.Count -eq 0) `
        'The aggregate analyzer did not use exactly the fixed query set.'

    $calls = @(Get-Calls $callLog)
    Require ($calls.Count -gt 0) 'The explicit fake ADB was not exercised.'
    $forbiddenCommands = @(
        'install','install-multiple','uninstall','clear','force-stop',
        'start','start-activity','monkey','am','settings','setprop','reboot',
        'remount','mount','chmod','chown','kill','pkill','tee','echo','logcat')
    foreach ($call in $calls) {
        $argv = [string[]]@($call.argv)
        foreach ($arg in $argv) {
            Require ([string]$arg -cnotin $forbiddenCommands) `
                "Fake ADB observed forbidden mutation/capture command: $arg"
        }
        if ($argv -ccontains 'com.qcxr.qcxr.dev262') {
            Require ($argv.Count -eq 5 -and $argv[2] -ceq 'shell' -and
                    $argv[3] -ceq 'pidof' -and
                    $argv[4] -ceq 'com.qcxr.qcxr.dev262') `
                'Stable was addressed by anything except stopped-state pidof.'
        }
        if ($argv -ccontains '/debug_ramdisk/su') {
            $tail = $argv[-1]
            Require ($argv[-2] -ceq '-c' -and
                    $tail -cin @("'id -u'",
                        "'cat /sys/kernel/tracing/available_events'")) `
                'Root was used for anything except fixed read probes.'
        }
    }
    Require (-not (Test-Path -LiteralPath $poisonLog)) `
        'A PATH-resolved ADB was invoked; zero-real-ADB proof failed.'
    Require ((Get-FileHash -LiteralPath $stableSentinel -Algorithm SHA256).Hash `
            -ceq $stableSentinelSha) 'Stable sentinel changed.'

    [pscustomobject][ordered]@{
        Result = 'PASS'
        HostOnly = $true
        FakeAdbInvocations = $calls.Count
        FakeTraceProcessorQueries = $queries.Count
        RealAdbInvocations = 0
        StableWrites = 0
        AggregateOnly = $true
        ExactPidStartFocusFences = $true
        SeparateCapabilityGates = $true
        WindowsUsbPnpFallbackCases = 8
        MultiDisplayFocusCases = 9
        NetworkSerialRejections = 4
        NetworkTransportRejections = 1
        RawTraceRetained = $false
    }
} finally {
    $env:QC_RC8_PERFETTO_FAKE_STATE = $oldState
    $env:QC_RC8_PERFETTO_SCENARIO = $oldScenario
    $env:QC_RC8_PERFETTO_TP_LOG = $oldTpLog
    $env:PATH = $oldPath
    if (Test-Path -LiteralPath $testRoot) {
        $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolved = [IO.Path]::GetFullPath($testRoot)
        Require ($resolved.StartsWith($expectedPrefix,
                [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($resolved) -cmatch
                    '^qc-rc8-perfetto-host-[0-9a-f]{32}$') `
            'Refusing to clean an unexpected Host test directory.'
        [IO.Directory]::Delete($resolved, $true)
    }
}
