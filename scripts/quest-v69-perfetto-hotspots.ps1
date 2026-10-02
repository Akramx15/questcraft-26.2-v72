<#
.SYNOPSIS
Captures and analyzes one app-state-read-only Perfetto trace from the fixed v69 Lab app.

.DESCRIPTION
This diagnostic is pinned to com.qcxr.qcxr.canary262 and the exact v68 core.
It never launches, stops, installs, uninstalls, clears, or edits either QuestCraft
application or profile. The Lab app must already be running, focused, and inside
the fixed benchmark route. Stable must be stopped.

Capture does perform bounded ephemeral device I/O: it pushes one randomized
config under /data/local/tmp, asks Perfetto to write one randomized trace there,
pulls it, and removes both files in a finally block. It never writes below either
application's data directory. Raw logcat, Android package lists, Binder payloads,
application file-system I/O, network packets, account data, and world/server
names are not captured. By default the host raw trace is deleted after aggregate
SQL analysis; use -KeepTrace only for a local Perfetto UI inspection.

The report identifies app threads, runnable-delay outliers, CPU competitors,
app trace slices, available GPU/KGSL counters, and optional PID-scoped native
callstack leaves whose contribution reaches the requested threshold. This is a
diagnostic trace, not an FPS acceptance sample: tracing overhead invalidates it
for A/B promotion decisions.

.EXAMPLE
.\scripts\quest-v69-perfetto-hotspots.ps1 -Action SelfTest

.EXAMPLE
.\scripts\quest-v69-perfetto-hotspots.ps1 -Action Plan

.EXAMPLE
$AdbPath = Join-Path $env:LOCALAPPDATA `
  'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
.\scripts\quest-v69-perfetto-hotspots.ps1 -Action Capture -AllowDeviceRead -AllowEphemeralDeviceIo `
  -AllowRootRead -IncludeCallstacks -Seconds 30 `
  -Serial QUEST_IP_ADDRESS:5555 `
  -AdbPath $AdbPath

.EXAMPLE
.\scripts\quest-v69-perfetto-hotspots.ps1 -Action Analyze `
  -TracePath C:\traces\lab.pftrace -CapturedPid 12345
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Plan', 'Capture', 'Analyze')]
    [string] $Action = 'Plan',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [ValidateRange(15, 60)]
    [int] $Seconds = 30,

    [ValidateRange(1.0, 20.0)]
    [double] $HotspotPercent = 3.0,

    [string] $OutputDirectory = '',

    [string] $TracePath = '',

    [ValidateRange(1, [int]::MaxValue)]
    [int] $CapturedPid = 1,

    [string] $TraceProcessorPath = '',

    [switch] $IncludeCallstacks,

    [switch] $AllowRootRead,

    [switch] $AllowDeviceRead,

    [switch] $AllowEphemeralDeviceIo,

    [switch] $KeepTrace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:ExpectedCoreSha256 = '3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F'
$script:CorePath = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/mods/Vivecraft.jar"
$script:MarkerPath = "/sdcard/Android/data/$script:Package/files/instances/$script:Profile/.questcraft/questcraft-vivecraft-core-canary-v1/request.json"
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:KnownTraceProcessor = Join-Path $script:WorkspaceRoot 'backups\20260831-vivecraft-v60-perfetto\tools\trace_processor'
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocationCount = 0

$script:CoreFtraceEvents = @(
    'sched/sched_switch',
    'sched/sched_waking',
    'sched/sched_wakeup',
    'sched/sched_wakeup_new',
    'sched/sched_blocked_reason',
    'sched/sched_process_exit',
    'task/task_newtask',
    'task/task_rename',
    'power/cpu_frequency',
    'power/cpu_idle',
    'irq/irq_handler_entry',
    'irq/irq_handler_exit',
    'irq/softirq_entry',
    'irq/softirq_exit'
)

$script:OptionalGpuFtraceEvents = @(
    'power/gpu_frequency',
    'gpu_mem/gpu_mem_total',
    'kgsl/kgsl_pwrlevel',
    'kgsl/kgsl_buslevel',
    'kgsl/kgsl_gpubusy',
    'kgsl/kgsl_clk',
    'kgsl/kgsl_switch_context',
    'kgsl/kgsl_cmdbatch_submitted',
    'kgsl/kgsl_cmdbatch_retired',
    'kgsl/adreno_cmdbatch_submitted',
    'kgsl/adreno_cmdbatch_retired'
)

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    $escaped = $quote + '"' + $quote + '"' + $quote
    return $quote + $Value.Replace($quote, $escaped) + $quote
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    throw 'ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    $script:DeviceInvocationCount++
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "ADB read failed with exit code $code; device output was suppressed."
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $rows }
}

function Resolve-Device {
    Require $AllowDeviceRead.IsPresent 'Capture requires explicit -AllowDeviceRead.'
    $script:Adb = Resolve-Adb
    $result = Invoke-Adb @('devices')
    $devices = @($result.Lines | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { [string]$Matches.serial }
    })
    Require ($devices.Count -eq 1) 'Exactly one authorized ADB device is required.'
    if ($Serial -ne 'auto') {
        Require ([string]$devices[0] -ceq $Serial) 'The requested serial is not the only attached device.'
    }
    $script:Device = [string]$devices[0]
}

function Invoke-DeviceShell {
    param([Parameter(Mandatory)][string] $Command, [switch] $AllowFailure)
    $normalized = $Command.Replace("`r`n", "`n").Replace("`r", "`n")
    return Invoke-Adb @('-s', $script:Device, 'shell', $normalized) -AllowFailure:$AllowFailure
}

function Invoke-ReadShell {
    param([Parameter(Mandatory)][string] $Command, [switch] $Optional)
    $normal = Invoke-DeviceShell -Command $Command -AllowFailure
    if ($normal.ExitCode -eq 0) { return $normal }
    if ($AllowRootRead) {
        $root = Invoke-DeviceShell -Command ('su -c ' + (ConvertTo-ShLiteral $Command)) -AllowFailure
        if ($root.ExitCode -eq 0) { return $root }
    }
    if ($Optional) { return $normal }
    throw 'A required read-only device probe failed; output was suppressed.'
}

function Get-OnlyPid([Parameter(Mandatory)][string] $Package, [switch] $AllowMissing) {
    $result = Invoke-DeviceShell -Command "pidof $(ConvertTo-ShLiteral $Package)" -AllowFailure
    $pids = @()
    if ($result.ExitCode -eq 0) {
        $pids = @([regex]::Matches(($result.Lines -join ' '), '(?<!\d)\d+(?!\d)') |
            ForEach-Object { [int]$_.Value } | Sort-Object -Unique)
    }
    if ($pids.Count -eq 0 -and $AllowMissing) { return $null }
    Require ($pids.Count -eq 1) "Expected exactly one PID for $Package."
    return [int]$pids[0]
}

function Test-LabFocused {
    $result = Invoke-DeviceShell -Command 'dumpsys activity activities' -AllowFailure
    if ($result.ExitCode -ne 0) { return $false }
    $line = $result.Lines | Where-Object { $_ -match 'topResumedActivity' } | Select-Object -First 1
    if ($null -eq $line) {
        $line = $result.Lines | Where-Object { $_ -match '(?:mResumedActivity|ResumedActivity)' } |
            Select-Object -First 1
    }
    return $null -ne $line -and [string]$line -match [regex]::Escape($script:Package)
}

function Get-ExactLabCoreHash {
    $command = "test -f $(ConvertTo-ShLiteral $script:CorePath) && sha256sum $(ConvertTo-ShLiteral $script:CorePath)"
    $result = Invoke-ReadShell -Command $command
    $matches = @($result.Lines | ForEach-Object {
        if ($_ -match '^\s*(?<sha>[0-9a-fA-F]{64})(?:\s|$)') { $Matches.sha.ToUpperInvariant() }
    })
    Require ($matches.Count -eq 1) 'The exact Lab core hash was ambiguous.'
    return [string]$matches[0]
}

function Assert-NoArmedCoreMarker {
    $command = "if [ -e $(ConvertTo-ShLiteral $script:MarkerPath) ] || [ -L $(ConvertTo-ShLiteral $script:MarkerPath) ]; then exit 75; fi"
    $result = Invoke-ReadShell -Command $command -Optional
    Require ($result.ExitCode -eq 0) 'A Lab core-canary request marker is still armed.'
}

function Get-SupportedFtraceEvents {
    $probe = 'cat /sys/kernel/tracing/available_events 2>/dev/null || cat /sys/kernel/debug/tracing/available_events 2>/dev/null'
    $result = Invoke-ReadShell -Command $probe -Optional
    $available = @{}
    if ($result.ExitCode -eq 0) {
        foreach ($token in (($result.Lines -join "`n") -split '\s+')) {
            if ($token -match '^(?<group>[A-Za-z0-9_.-]+):(?<event>[A-Za-z0-9_.-]+)$') {
                $available["$($Matches.group)/$($Matches.event)"] = $true
            }
        }
    }
    $core = @()
    foreach ($event in $script:CoreFtraceEvents) {
        if ($available.Count -eq 0 -or $available.ContainsKey($event)) { $core += $event }
    }
    $gpu = @()
    foreach ($event in $script:OptionalGpuFtraceEvents) {
        if ($available.ContainsKey($event)) { $gpu += $event }
    }
    Require ($core -contains 'sched/sched_switch') 'sched_switch is unavailable; a scheduling trace would be invalid.'
    return [pscustomobject]@{
        Core = @($core | Sort-Object -Unique)
        Gpu = @($gpu | Sort-Object -Unique)
        DiscoverySucceeded = $available.Count -gt 0
    }
}

function New-TraceConfig {
    param(
        [Parameter(Mandatory)][string[]] $FtraceEvents,
        [Parameter(Mandatory)][int] $DurationSeconds,
        [Parameter(Mandatory)][bool] $WithCallstacks
    )
    $eventRows = ($FtraceEvents | ForEach-Object { '      ftrace_events: "' + $_ + '"' }) -join "`n"
    $perfBuffer = ''
    $perfSource = ''
    if ($WithCallstacks) {
        $perfBuffer = @"
buffers {
  size_kb: 16384
  fill_policy: RING_BUFFER
}
"@
        $perfSource = @"
data_sources {
  config {
    name: "linux.perf"
    target_buffer: 1
    perf_event_config {
      timebase {
        counter: SW_CPU_CLOCK
        frequency: 100
        timestamp_clock: PERF_CLOCK_MONOTONIC
      }
      callstack_sampling {
        scope { target_cmdline: "$script:Package" }
        kernel_frames: false
      }
    }
  }
}
"@
    }
    return @"
buffers {
  size_kb: 65536
  fill_policy: RING_BUFFER
}
$perfBuffer
data_sources {
  config {
    name: "linux.ftrace"
    target_buffer: 0
    ftrace_config {
$eventRows
      atrace_apps: "$script:Package"
      drain_period_ms: 250
      symbolize_ksyms: false
    }
  }
}
data_sources {
  config {
    name: "linux.process_stats"
    target_buffer: 0
    process_stats_config {
      scan_all_processes_on_start: true
    }
  }
}
data_sources {
  config { name: "linux.system_info" target_buffer: 0 }
}
$perfSource
duration_ms: $($DurationSeconds * 1000)
flush_period_ms: 5000
compression_type: COMPRESSION_TYPE_DEFLATE
"@
}

function New-UniqueOutputDirectory {
    $parent = $OutputDirectory
    if ([string]::IsNullOrWhiteSpace($parent)) {
        $parent = Join-Path ([IO.Path]::GetTempPath()) 'questcraft-v69-perfetto'
    }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $leaf = 'capture-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $path = Join-Path $parent $leaf
    Require (-not (Test-Path -LiteralPath $path)) 'The unique output directory already exists.'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return (Resolve-Path -LiteralPath $path).Path
}

function Assert-SafeDeviceTracePath([Parameter(Mandatory)][string] $Path) {
    Require ($Path -match '^/data/local/tmp/qcv69-perfetto-[0-9a-f]{32}\.(?:pbtxt|pftrace)$') `
        'Unsafe device trace path.'
    return $Path
}

function Remove-EphemeralDeviceTraceFiles {
    param(
        [Parameter(Mandatory)][string] $DeviceConfig,
        [Parameter(Mandatory)][string] $DeviceTrace
    )
    $null = Assert-SafeDeviceTracePath $DeviceConfig
    $null = Assert-SafeDeviceTracePath $DeviceTrace
    $command = "rm -f $(ConvertTo-ShLiteral $DeviceConfig) $(ConvertTo-ShLiteral $DeviceTrace)"
    return Invoke-DeviceShell -Command $command -AllowFailure
}

function Start-PerfettoCapture {
    param(
        [Parameter(Mandatory)][string] $Config,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][int] $ExpectedPid
    )
    Require $AllowEphemeralDeviceIo.IsPresent `
        'Capture requires explicit -AllowEphemeralDeviceIo for /data/local/tmp config/trace files.'
    $runId = [guid]::NewGuid().ToString('N')
    $deviceConfig = Assert-SafeDeviceTracePath "/data/local/tmp/qcv69-perfetto-$runId.pbtxt"
    $deviceTrace = Assert-SafeDeviceTracePath "/data/local/tmp/qcv69-perfetto-$runId.pftrace"
    $hostConfig = Join-Path (Split-Path -Parent $Destination) "qcv69-perfetto-$runId.pbtxt"
    [IO.File]::WriteAllText($hostConfig, $Config, (New-Object Text.UTF8Encoding($false)))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:Adb
    $psi.Arguments = '-s "' + $script:Device + '" shell perfetto --txt -c ' +
        $deviceConfig + ' -o ' + $deviceTrace
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    $polls = New-Object Collections.Generic.List[object]
    $cleanupSucceeded = $false
    try {
        $exists = Invoke-DeviceShell -Command "test ! -e $(ConvertTo-ShLiteral $deviceConfig) -a ! -L $(ConvertTo-ShLiteral $deviceConfig) -a ! -e $(ConvertTo-ShLiteral $deviceTrace) -a ! -L $(ConvertTo-ShLiteral $deviceTrace)" -AllowFailure
        Require ($exists.ExitCode -eq 0) 'Randomized Perfetto device paths unexpectedly exist.'
        $push = Invoke-Adb @('-s', $script:Device, 'push', $hostConfig, $deviceConfig) -AllowFailure
        Require ($push.ExitCode -eq 0) 'Could not push the ephemeral Perfetto config.'
        $script:DeviceInvocationCount++
        Require $process.Start() 'Could not start the bounded ADB Perfetto capture.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(5000)) {
            $current = Get-OnlyPid -Package $script:Package -AllowMissing
            $focused = Test-LabFocused
            $polls.Add([pscustomobject]@{
                PidStable = $null -ne $current -and [int]$current -eq $ExpectedPid
                Focused = $focused
            })
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Require ($process.ExitCode -eq 0) "Perfetto exited with code $($process.ExitCode); diagnostics were suppressed."
        $pull = Invoke-Adb @('-s', $script:Device, 'pull', $deviceTrace, $Destination) -AllowFailure
        Require ($pull.ExitCode -eq 0) 'Could not pull the ephemeral Perfetto trace.'
        Require ((Get-Item -LiteralPath $Destination).Length -gt 4096) 'Perfetto produced an unexpectedly small trace.'
        return [pscustomobject]@{
            # PowerShell 7 can throw "Argument types do not match" when its
            # array-subexpression binder receives List[object] directly.
            # Materialize the generic list explicitly at this boundary.
            Polls = $polls.ToArray()
            PerfettoDiagnosticsPresent = -not [string]::IsNullOrWhiteSpace($stdout) -or
                -not [string]::IsNullOrWhiteSpace($stderr)
            DeviceConfig = $deviceConfig
            DeviceTrace = $deviceTrace
            EphemeralDeviceIoPerformed = $true
        }
    } finally {
        $process.Dispose()
        $cleanup = Remove-EphemeralDeviceTraceFiles -DeviceConfig $deviceConfig -DeviceTrace $deviceTrace
        $cleanupSucceeded = $cleanup.ExitCode -eq 0
        if (Test-Path -LiteralPath $hostConfig) {
            Remove-Item -LiteralPath $hostConfig -Force
        }
        Require $cleanupSucceeded `
            "Ephemeral device cleanup failed for $deviceConfig and $deviceTrace."
    }
}

function Resolve-TraceProcessor {
    $candidate = $TraceProcessorPath
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $script:KnownTraceProcessor }
    Require (Test-Path -LiteralPath $candidate -PathType Leaf) `
        'trace_processor was not found. Pass -TraceProcessorPath.'
    return (Resolve-Path -LiteralPath $candidate).Path
}

function ConvertTo-WindowsCommandLineArgument([Parameter(Mandatory)][AllowEmptyString()][string] $Value) {
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-TraceQuery {
    param(
        [Parameter(Mandatory)][string] $Processor,
        [Parameter(Mandatory)][string] $InputTrace,
        [Parameter(Mandatory)][string] $Sql
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('qcv69-tp-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $queryFile = Join-Path $tempRoot 'query.sql'
    [IO.File]::WriteAllText($queryFile, $Sql, (New-Object Text.UTF8Encoding($false)))
    try {
        $extension = [IO.Path]::GetExtension($Processor)
        $executable = $Processor
        $arguments = @('query', '-f', $queryFile, $InputTrace)
        if ($extension -ine '.exe') {
            $python = Get-Command python -ErrorAction Stop
            $executable = $python.Source
            $arguments = @($Processor) + $arguments
        }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $executable
        $psi.Arguments = (($arguments | ForEach-Object {
            ConvertTo-WindowsCommandLineArgument ([string]$_)
        }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $psi
        try {
            Require $process.Start() 'Could not start trace_processor.'
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $csv = $stdoutTask.GetAwaiter().GetResult()
            $null = $stderrTask.GetAwaiter().GetResult()
            Require ($process.ExitCode -eq 0) 'trace_processor rejected a diagnostic query; stderr was suppressed.'
        } finally {
            $process.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($csv)) { return @() }
        return @(ConvertFrom-Csv -InputObject $csv)
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Convert-NullableDouble($Value) {
    if ($null -eq $Value -or [string]$Value -eq '[NULL]' -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [double]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Convert-NullableInt64($Value) {
    if ($null -eq $Value -or [string]$Value -eq '[NULL]' -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [int64]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Convert-ThreadRow($Row) {
    return [pscustomobject]@{
        Tid = [int]$Row.tid
        Name = [string]$Row.thread_name
        CpuMs = Convert-NullableDouble $Row.cpu_ms
        AppCpuPercent = Convert-NullableDouble $Row.app_cpu_percent
        OneCorePercent = Convert-NullableDouble $Row.one_core_percent
        RunnableWaitMs = Convert-NullableDouble $Row.runnable_wait_ms
        RunnableWaitWallPercent = Convert-NullableDouble $Row.runnable_wait_wall_percent
        RunnableP95Ms = Convert-NullableDouble $Row.runnable_p95_ms
        RunnableMaxMs = Convert-NullableDouble $Row.runnable_max_ms
        RunnableAtLeast1Ms = Convert-NullableInt64 $Row.waits_ge_1ms
        RunnableAtLeast2Ms = Convert-NullableInt64 $Row.waits_ge_2ms
        RunnableAtLeast4Ms = Convert-NullableInt64 $Row.waits_ge_4ms
        UninterruptibleMs = Convert-NullableDouble $Row.uninterruptible_ms
    }
}

function Analyze-PerfettoTrace {
    param(
        [Parameter(Mandatory)][string] $InputTrace,
        [Parameter(Mandatory)][int] $AppProcessId,
        [bool] $PackageIdentityValidated = $false
    )
    Require (Test-Path -LiteralPath $InputTrace -PathType Leaf) 'The input trace does not exist.'
    $processor = Resolve-TraceProcessor

    $summarySql = @"
WITH b AS (SELECT end_ts - start_ts AS dur_ns FROM trace_bounds),
app_cpu AS (
  SELECT COALESCE(SUM(s.dur), 0) AS cpu_ns
  FROM sched s JOIN thread t USING(utid) JOIN process p USING(upid)
  WHERE p.pid = $AppProcessId AND s.dur > 0
),
app_wait AS (
  SELECT COALESCE(SUM(ts.dur), 0) AS wait_ns
  FROM thread_state ts JOIN thread t USING(utid) JOIN process p USING(upid)
  WHERE p.pid = $AppProcessId AND ts.state IN ('R', 'R+') AND ts.dur > 0
)
SELECT ROUND((SELECT dur_ns FROM b) / 1e9, 3) AS trace_seconds,
       ROUND((SELECT cpu_ns FROM app_cpu) / 1e6, 3) AS app_cpu_ms,
       ROUND(100.0 * (SELECT cpu_ns FROM app_cpu) / (SELECT dur_ns FROM b), 3) AS app_one_core_percent,
       ROUND((SELECT wait_ns FROM app_wait) / 1e6, 3) AS app_runnable_wait_ms,
       ROUND(100.0 * (SELECT wait_ns FROM app_wait) / (SELECT dur_ns FROM b), 3) AS app_runnable_wait_wall_percent,
       (SELECT COUNT(*) FROM perf_sample ps JOIN thread t USING(utid) JOIN process p USING(upid) WHERE p.pid = $AppProcessId) AS perf_samples,
       (SELECT COALESCE(SUM(value), 0) FROM stats WHERE severity = 'data_loss' AND value > 0) AS data_loss;
"@

    $threadsSql = @"
WITH b AS (SELECT end_ts - start_ts AS dur_ns FROM trace_bounds),
cpu AS (
  SELECT t.utid, t.tid, COALESCE(t.name, '[unnamed]') AS thread_name, SUM(s.dur) AS cpu_ns
  FROM sched s JOIN thread t USING(utid) JOIN process p USING(upid)
  WHERE p.pid = $AppProcessId AND s.dur > 0 GROUP BY t.utid, t.tid, t.name
),
total AS (SELECT SUM(cpu_ns) AS total_ns FROM cpu),
waits AS (
  SELECT t.utid,
    SUM(CASE WHEN ts.state IN ('R', 'R+') AND ts.dur > 0 THEN ts.dur ELSE 0 END) AS wait_ns,
    PERCENTILE(CASE WHEN ts.state IN ('R', 'R+') AND ts.dur > 0 THEN ts.dur / 1e6 END, 95) AS p95_ms,
    MAX(CASE WHEN ts.state IN ('R', 'R+') AND ts.dur > 0 THEN ts.dur ELSE 0 END) AS max_ns,
    SUM(CASE WHEN ts.state IN ('R', 'R+') AND ts.dur >= 1000000 THEN 1 ELSE 0 END) AS ge1,
    SUM(CASE WHEN ts.state IN ('R', 'R+') AND ts.dur >= 2000000 THEN 1 ELSE 0 END) AS ge2,
    SUM(CASE WHEN ts.state IN ('R', 'R+') AND ts.dur >= 4000000 THEN 1 ELSE 0 END) AS ge4,
    SUM(CASE WHEN ts.state = 'D' AND ts.dur > 0 THEN ts.dur ELSE 0 END) AS d_ns
  FROM thread_state ts JOIN thread t USING(utid) JOIN process p USING(upid)
  WHERE p.pid = $AppProcessId GROUP BY t.utid
)
SELECT cpu.tid, cpu.thread_name,
       ROUND(cpu.cpu_ns / 1e6, 3) AS cpu_ms,
       ROUND(100.0 * cpu.cpu_ns / total.total_ns, 3) AS app_cpu_percent,
       ROUND(100.0 * cpu.cpu_ns / b.dur_ns, 3) AS one_core_percent,
       ROUND(COALESCE(waits.wait_ns, 0) / 1e6, 3) AS runnable_wait_ms,
       ROUND(100.0 * COALESCE(waits.wait_ns, 0) / b.dur_ns, 3) AS runnable_wait_wall_percent,
       ROUND(waits.p95_ms, 3) AS runnable_p95_ms,
       ROUND(COALESCE(waits.max_ns, 0) / 1e6, 3) AS runnable_max_ms,
       COALESCE(waits.ge1, 0) AS waits_ge_1ms,
       COALESCE(waits.ge2, 0) AS waits_ge_2ms,
       COALESCE(waits.ge4, 0) AS waits_ge_4ms,
       ROUND(COALESCE(waits.d_ns, 0) / 1e6, 3) AS uninterruptible_ms
FROM cpu CROSS JOIN total CROSS JOIN b LEFT JOIN waits USING(utid)
ORDER BY cpu.cpu_ns DESC LIMIT 64;
"@

    $competitorsSql = @"
WITH b AS (SELECT end_ts - start_ts AS dur_ns FROM trace_bounds),
cpu AS (
  SELECT p.pid, COALESCE(p.name, '[kernel/unknown]') AS process_name, SUM(s.dur) AS cpu_ns
  FROM sched s JOIN thread t USING(utid) LEFT JOIN process p USING(upid)
  WHERE s.dur > 0 GROUP BY p.pid, p.name
)
SELECT pid, process_name, ROUND(cpu_ns / 1e6, 3) AS cpu_ms,
       ROUND(100.0 * cpu_ns / b.dur_ns, 3) AS one_core_percent
FROM cpu CROSS JOIN b
WHERE (pid IS NULL OR pid != $AppProcessId) AND 100.0 * cpu_ns / b.dur_ns >= $HotspotPercent
ORDER BY cpu_ns DESC LIMIT 32;
"@

    $slicesSql = @"
WITH b AS (SELECT end_ts - start_ts AS dur_ns FROM trace_bounds)
SELECT COALESCE(s.category, '') AS category, s.name AS slice_name, COUNT(*) AS occurrences,
       ROUND(SUM(CASE WHEN s.dur > 0 THEN s.dur ELSE 0 END) / 1e6, 3) AS total_ms,
       ROUND(100.0 * SUM(CASE WHEN s.dur > 0 THEN s.dur ELSE 0 END) / b.dur_ns, 3) AS wall_percent,
       ROUND(PERCENTILE(CASE WHEN s.dur > 0 THEN s.dur / 1e6 END, 95), 3) AS p95_ms,
       ROUND(MAX(CASE WHEN s.dur > 0 THEN s.dur ELSE 0 END) / 1e6, 3) AS max_ms
FROM slice s JOIN thread_track tt ON s.track_id = tt.id JOIN thread t USING(utid)
JOIN process p USING(upid) CROSS JOIN b
WHERE p.pid = $AppProcessId GROUP BY s.category, s.name, b.dur_ns
ORDER BY total_ms DESC LIMIT 64;
"@

    $gpuCountersSql = @"
SELECT ct.name AS counter_name, COALESCE(ct.unit, '') AS unit, COUNT(c.id) AS samples,
       ROUND(AVG(c.value), 3) AS mean_value,
       ROUND(PERCENTILE(c.value, 95), 3) AS p95_value,
       ROUND(MIN(c.value), 3) AS min_value, ROUND(MAX(c.value), 3) AS max_value
FROM counter_track ct JOIN counter c ON c.track_id = ct.id
WHERE LOWER(ct.name) LIKE '%gpu%' OR LOWER(ct.name) LIKE '%kgsl%'
GROUP BY ct.id, ct.name, ct.unit ORDER BY samples DESC LIMIT 64;
"@

    $gpuEventsSql = @"
SELECT name AS event_name, COUNT(*) AS occurrences
FROM raw WHERE LOWER(name) LIKE '%gpu%' OR LOWER(name) LIKE '%kgsl%'
GROUP BY name ORDER BY occurrences DESC LIMIT 64;
"@

    $framesSql = @"
WITH total AS (
  SELECT COUNT(*) AS n FROM perf_sample ps JOIN thread t USING(utid)
  JOIN process p USING(upid) WHERE p.pid = $AppProcessId
)
SELECT COALESCE(NULLIF(f.name, ''), '[unknown]') AS function_name,
       COALESCE(NULLIF(m.name, ''), '[unknown]') AS mapping_name,
       COUNT(*) AS samples, ROUND(100.0 * COUNT(*) / total.n, 3) AS sample_percent
FROM perf_sample ps JOIN thread t USING(utid) JOIN process p USING(upid)
LEFT JOIN stack_profile_callsite cs ON ps.callsite_id = cs.id
LEFT JOIN stack_profile_frame f ON cs.frame_id = f.id
LEFT JOIN stack_profile_mapping m ON f.mapping = m.id CROSS JOIN total
WHERE p.pid = $AppProcessId AND total.n > 0
GROUP BY f.name, m.name, total.n ORDER BY samples DESC LIMIT 64;
"@

    $frequencySql = @"
SELECT ct.cpu, COUNT(*) AS samples, ROUND(AVG(c.value) / 1000.0, 3) AS mean_mhz,
       ROUND(MIN(c.value) / 1000.0, 3) AS min_mhz,
       ROUND(MAX(c.value) / 1000.0, 3) AS max_mhz
FROM cpu_counter_track ct JOIN counter c ON c.track_id = ct.id
WHERE ct.name = 'cpufreq' GROUP BY ct.cpu ORDER BY ct.cpu;
"@

    $summaryRows = @(Invoke-TraceQuery $processor $InputTrace $summarySql)
    Require ($summaryRows.Count -eq 1) 'Trace summary was missing or ambiguous.'
    $threadRows = @((Invoke-TraceQuery $processor $InputTrace $threadsSql) |
        ForEach-Object { Convert-ThreadRow $_ })
    Require ($threadRows.Count -gt 0) 'The captured PID has no scheduling rows in the trace.'
    $competitors = @(Invoke-TraceQuery $processor $InputTrace $competitorsSql)
    $slices = @(Invoke-TraceQuery $processor $InputTrace $slicesSql)
    $gpuCounters = @(Invoke-TraceQuery $processor $InputTrace $gpuCountersSql)
    $gpuEvents = @(Invoke-TraceQuery $processor $InputTrace $gpuEventsSql)
    $frames = @(Invoke-TraceQuery $processor $InputTrace $framesSql)
    $frequencies = @(Invoke-TraceQuery $processor $InputTrace $frequencySql)

    $hotThreads = @($threadRows | Where-Object {
        $_.AppCpuPercent -ge $HotspotPercent -or
        $_.RunnableWaitWallPercent -ge $HotspotPercent -or
        $_.RunnableAtLeast4Ms -gt 0
    })
    $hotFrames = @($frames | Where-Object {
        (Convert-NullableDouble $_.sample_percent) -ge $HotspotPercent
    })
    $hotSlices = @($slices | Where-Object {
        (Convert-NullableDouble $_.wall_percent) -ge $HotspotPercent
    })

    $summary = $summaryRows[0]
    return [ordered]@{
        SchemaVersion = 1
        EvidenceClass = 'diagnostic-only-not-an-ab-performance-sample'
        PackageContract = $script:Package
        PackageIdentityValidated = $PackageIdentityValidated
        CapturedPid = $AppProcessId
        HotspotThresholdPercent = $HotspotPercent
        Trace = [ordered]@{
            DurationSeconds = Convert-NullableDouble $summary.trace_seconds
            AppCpuMs = Convert-NullableDouble $summary.app_cpu_ms
            AppOneCorePercent = Convert-NullableDouble $summary.app_one_core_percent
            AppRunnableWaitMs = Convert-NullableDouble $summary.app_runnable_wait_ms
            AppRunnableWaitWallPercent = Convert-NullableDouble $summary.app_runnable_wait_wall_percent
            PerfSamples = Convert-NullableInt64 $summary.perf_samples
            DataLossCount = Convert-NullableInt64 $summary.data_loss
        }
        HotspotCandidates = [ordered]@{
            Threads = $hotThreads
            NativeLeafFrames = $hotFrames
            AppSlices = $hotSlices
        }
        TopAppThreads = $threadRows
        ExternalCpuCompetitorsAtOrAboveThreshold = $competitors
        AppSlices = $slices
        NativeLeafFrames = $frames
        GpuCounters = $gpuCounters
        GpuOrKgslEventCounts = $gpuEvents
        CpuFrequencies = $frequencies
        Interpretation = @(
            'Thread CPU share >= threshold identifies where app CPU time is concentrated, not automatically removable work.',
            'Runnable wait >= threshold or repeated >=4 ms waits identify scheduler/frame-pacing candidates.',
            'Native leaf-frame share >= threshold is actionable only when symbols resolve; Java/JIT work may remain anonymous.',
            'GPU/KGSL absence means VrApi App/GPU timing remains the GPU source of truth.',
            'Only a fresh one-variable counterbalanced VrApi A/B can accept a code change.'
        )
        SensitiveData = [ordered]@{
            RawLogcatCaptured = $false
            AndroidPackageListCaptured = $false
            BinderPayloadCaptured = $false
            NetworkCaptured = $false
            AccountFilesRead = $false
            WorldOrServerNameCapturedByScript = $false
        }
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string] $Path)
    Require (-not (Test-Path -LiteralPath $Path)) 'Refusing to overwrite an existing report.'
    $temp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 9),
            (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Invoke-SelfTest {
    $events = @($script:CoreFtraceEvents + @('power/gpu_frequency', 'kgsl/kgsl_pwrlevel'))
    $config = New-TraceConfig -FtraceEvents $events -DurationSeconds 30 -WithCallstacks $true
    foreach ($required in @('sched/sched_switch', 'power/gpu_frequency', 'kgsl/kgsl_pwrlevel',
            'atrace_apps: "com.qcxr.qcxr.canary262"', 'name: "linux.perf"',
            'target_cmdline: "com.qcxr.qcxr.canary262"', 'frequency: 100')) {
        Require $config.Contains($required) "Trace config omitted $required."
    }
    foreach ($forbidden in @('android.log', 'android.packages_list', 'binder_driver',
            'raw_syscalls', 'vulkan.memory_tracker', 'heapprofd')) {
        Require (-not $config.Contains($forbidden)) "Trace config contains forbidden source $forbidden."
    }
    Require ($config.Contains('duration_ms: 30000')) 'Trace duration was generated incorrectly.'
    $safeConfig = Assert-SafeDeviceTracePath '/data/local/tmp/qcv69-perfetto-0123456789abcdef0123456789abcdef.pbtxt'
    $safeTrace = Assert-SafeDeviceTracePath '/data/local/tmp/qcv69-perfetto-0123456789abcdef0123456789abcdef.pftrace'
    Require ($safeConfig.EndsWith('.pbtxt')) 'Safe config-path validation failed.'
    Require ($safeTrace.EndsWith('.pftrace')) 'Safe trace-path validation failed.'
    $unsafeRejected = $false
    try { $null = Assert-SafeDeviceTracePath '/data/local/tmp/../bad.pftrace' } catch { $unsafeRejected = $true }
    Require $unsafeRejected 'Unsafe device trace path was accepted.'
    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $brokenStreamToken = 'exec-' + 'out perfetto'
    Require (-not $source.Contains($brokenStreamToken)) 'The broken stdin-stream capture path returned.'
    Require ($source.Contains('push')) 'Ephemeral config push is absent.'
    Require ($source.Contains('pull')) 'Ephemeral trace pull is absent.'
    $synthetic = [pscustomobject]@{
        AppCpuPercent = 3.0; RunnableWaitWallPercent = 0.0; RunnableAtLeast4Ms = 0
    }
    Require ($synthetic.AppCpuPercent -ge $HotspotPercent) 'The >= hotspot boundary is not inclusive.'
    Require ($script:DeviceInvocationCount -eq 0) 'SelfTest invoked ADB.'
    return [pscustomobject]@{
        Result = 'PASS'
        Package = $script:Package
        StablePackage = $script:StablePackage
        ExpectedCoreSha256 = $script:ExpectedCoreSha256
        DefaultSeconds = 30
        DefaultHotspotPercent = 3.0
        DeviceTouched = $false
        ExistingHistoricalTraceAvailable = Test-Path -LiteralPath (Join-Path $script:WorkspaceRoot 'backups\20260831-vivecraft-v60-perfetto\qc_v60_baseline.pftrace')
    }
}

function Get-Plan {
    return [pscustomobject]@{
        Result = 'PLAN_ONLY'
        DeviceTouched = $false
        Package = $script:Package
        StableMustBeStopped = $script:StablePackage
        RequiredCoreSha256 = $script:ExpectedCoreSha256
        DurationSeconds = $Seconds
        HotspotThresholdPercent = $HotspotPercent
        Capture = 'Scheduling + CPU frequency/idle + IRQ + discovered GPU/KGSL events + Lab-only atrace; optional 100 Hz native callstacks.'
        Excludes = 'Raw logcat, package list, Binder, syscalls, network, file I/O, account data, world/server names.'
        DeviceIoPolicy = 'Explicitly authorized randomized config+trace files under /data/local/tmp; both removed in finally. No app/profile writes.'
        RawTracePolicy = 'Pull into a new host directory; delete after aggregate analysis unless -KeepTrace is explicit.'
        RootPolicy = 'Optional read-only fallback only for SHA-256 and available_events discovery; no tuning.'
        AcceptancePolicy = 'Diagnostic only. Do not promote a code change without fresh counterbalanced VrApi A/B.'
        RecommendedCommand = '.\scripts\quest-v69-perfetto-hotspots.ps1 -Action Capture -AllowDeviceRead -AllowEphemeralDeviceIo -AllowRootRead -IncludeCallstacks -Seconds 30 -Serial QUEST_IP_ADDRESS:5555 -AdbPath <full-adb.exe-path>'
    }
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}

if ($Action -eq 'Plan') {
    Get-Plan
    exit 0
}

if ($Action -eq 'Analyze') {
    Require (-not [string]::IsNullOrWhiteSpace($TracePath)) 'Analyze requires -TracePath.'
    $resolvedTrace = (Resolve-Path -LiteralPath $TracePath).Path
    $directory = New-UniqueOutputDirectory
    $report = Analyze-PerfettoTrace -InputTrace $resolvedTrace -AppProcessId $CapturedPid `
        -PackageIdentityValidated $false
    $reportPath = Join-Path $directory 'hotspots.aggregate.json'
    Write-JsonAtomic $report $reportPath
    [pscustomobject]@{
        Result = 'ANALYZED'
        DeviceTouched = $false
        ReportPath = $reportPath
        TraceSha256 = (Get-FileHash -LiteralPath $resolvedTrace -Algorithm SHA256).Hash.ToUpperInvariant()
        Report = $report
    }
    exit 0
}

Resolve-Device
Require ($null -eq (Get-OnlyPid -Package $script:StablePackage -AllowMissing)) `
    'Stable is running; stop it outside this diagnostic script before tracing Lab.'
$initialPid = Get-OnlyPid -Package $script:Package
Require (Test-LabFocused) 'Lab is not the focused resumed activity.'
$coreHash = Get-ExactLabCoreHash
Require ($coreHash -ceq $script:ExpectedCoreSha256) 'Lab is not on the exact v68 baseline core.'
Assert-NoArmedCoreMarker
$support = Get-SupportedFtraceEvents
$events = @($support.Core + $support.Gpu | Sort-Object -Unique)
$config = New-TraceConfig -FtraceEvents $events -DurationSeconds $Seconds `
    -WithCallstacks $IncludeCallstacks.IsPresent
$captureDirectory = New-UniqueOutputDirectory
$rawTrace = Join-Path $captureDirectory 'lab-baseline.pftrace'
$captureResult = Start-PerfettoCapture -Config $config -Destination $rawTrace -ExpectedPid $initialPid
$finalPid = Get-OnlyPid -Package $script:Package
Require ($finalPid -eq $initialPid) 'Lab PID changed during the diagnostic trace.'
Require (Test-LabFocused) 'Lab lost focus by the end of the diagnostic trace.'
Require (@($captureResult.Polls | Where-Object { -not $_.PidStable -or -not $_.Focused }).Count -eq 0) `
    'Lab PID or focus changed during the diagnostic trace.'
$report = Analyze-PerfettoTrace -InputTrace $rawTrace -AppProcessId $initialPid `
    -PackageIdentityValidated $true
$traceSha = (Get-FileHash -LiteralPath $rawTrace -Algorithm SHA256).Hash.ToUpperInvariant()
$envelope = [ordered]@{
    Capture = [ordered]@{
        Package = $script:Package
        CoreSha256 = $coreHash
        DurationSecondsRequested = $Seconds
        IncludeCallstacks = $IncludeCallstacks.IsPresent
        FtraceEventDiscoverySucceeded = $support.DiscoverySucceeded
        FtraceEvents = $events
        GpuOrKgslEventsEnabled = $support.Gpu
        FocusAndPidPolls = $captureResult.Polls.Count
        FocusAndPidStable = $true
        PerfettoDiagnosticsPresent = $captureResult.PerfettoDiagnosticsPresent
        TraceSha256 = $traceSha
        RawTraceRetained = $KeepTrace.IsPresent
        RootReadFallbackAllowed = $AllowRootRead.IsPresent
        EphemeralDeviceIoPerformed = $true
        ApplicationOrProfileMutationPerformed = $false
    }
    Analysis = $report
}
$aggregatePath = Join-Path $captureDirectory 'hotspots.aggregate.json'
Write-JsonAtomic $envelope $aggregatePath
if (-not $KeepTrace) {
    Remove-Item -LiteralPath $rawTrace -Force
}
[pscustomobject]@{
    Result = 'CAPTURED_AND_ANALYZED'
    EphemeralDeviceIoPerformed = $true
    ApplicationOrProfileMutationPerformed = $false
    AggregateReport = $aggregatePath
    RawTrace = if ($KeepTrace) { $rawTrace } else { $null }
    TraceSha256 = $traceSha
    HotspotCandidates = $report.HotspotCandidates
}
