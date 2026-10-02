<#
.SYNOPSIS
Captures aggregate-only Quest VrApi metrics for one exact Android app PID.

.DESCRIPTION
This benchmark helper deliberately does not share the metric-owner model used by
quest-mod-ab.ps1. It starts a live logcat stream with --pid=<exact main app PID>,
keeps all raw rows in memory, and emits only aggregate values. It rejects a run
when the package PID changes, the app is not the resumed activity for at least
95 percent of known focus polls, the sample rate is too low, the observed
display refresh rate does not match the requested benchmark rate, or a bounded
before/after process guard detects a standalone `tr` contaminant. A steady
rgb_led.sh count is reported but allowed; a count change invalidates the run.

Meta's VrApi FPS field is interpreted as FPS=<application FPS>/<current headset
display refresh rate>. The second value is therefore reported as
DisplayRefreshHz, never TargetFps.

No app data is changed. The script never launches, force-stops, uninstalls, or
clears the package. Raw logcat/process rows and device identifiers are never
written to disk or returned. The exact app PID remains in the aggregate report
for schema compatibility and metric-owner verification. Performance metrics
are also aggregated by the observed display-refresh stratum so QGO Dynamic
runs can be compared without treating different refresh rates as equivalent.

.EXAMPLE
.\scripts\quest-vrapi-pid-benchmark.ps1 -Seconds 60 -ExpectedRefreshHz 72

.EXAMPLE
.\scripts\quest-vrapi-pid-benchmark.ps1 -Seconds 60 -ExpectedRefreshHz 72 `
  -OutputJson .\artifacts\benchmarks\dualpass\sample-1.json

.EXAMPLE
.\scripts\quest-vrapi-pid-benchmark.ps1 -Action SelfTest
#>
[CmdletBinding()]
param(
    [ValidateSet('Capture', 'SelfTest')]
    [string]$Action = 'Capture',

    [ValidatePattern('^[A-Za-z0-9._]+$')]
    [string]$Package = 'com.qcxr.qcxr.dev262',

    [ValidatePattern('^$|^[A-Za-z0-9._]+$')]
    [string]$ForbiddenPackage = '',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string]$Serial = 'auto',

    [ValidateRange(10, 1800)]
    [int]$Seconds = 60,

    [ValidateRange(1.0, 240.0)]
    [double]$ExpectedRefreshHz = 72.0,

    [ValidateRange(0.0, 10.0)]
    [double]$RefreshToleranceHz = 0.5,

    [ValidateRange(1.0, 100.0)]
    [double]$MinimumRefreshMatchPercent = 95.0,

    [switch]$DynamicRefresh,

    [ValidateRange(1.0, 100.0)]
    [double]$MinimumSampleCoveragePercent = 60.0,

    [ValidateRange(1, 10)]
    [int]$PollSeconds = 1,

    [ValidatePattern('^$|.*\.json$')]
    [string]$OutputJson,

    [string]$AdbPath = 'adb'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ResolvedAdb = $null
$script:ResolvedSerial = $null

function Get-ReservedLastExitCodeAssignments {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast] $Ast)
    return @($Ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.AssignmentStatementAst]) {
            return $false
        }
        $left = $node.Left
        return $left -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]$left.VariablePath.UserPath -ieq 'LASTEXITCODE'
    }, $true))
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }

    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $sdkCandidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdkCandidate -PathType Leaf) {
        return $sdkCandidate
    }

    throw 'ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& $script:ResolvedAdb @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (($exitCode -ne 0) -and -not $AllowFailure) {
        throw "ADB failed with exit code $exitCode. Output was suppressed to keep runtime logs out of reports."
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Lines = @($output | ForEach-Object { [string]$_ })
    }
}

function Resolve-DeviceSerial {
    if ($Serial -ne 'auto') {
        return $Serial
    }

    $result = Invoke-Adb -Arguments @('devices')
    $devices = @(
        $result.Lines | ForEach-Object {
            if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
                $Matches.serial
            }
        }
    )

    if ($devices.Count -eq 0) {
        throw 'No authorized ADB device is connected.'
    }
    if ($devices.Count -gt 1) {
        throw 'More than one authorized ADB device is connected. Pass -Serial explicitly.'
    }
    return [string]$devices[0]
}

function Assert-DeviceReady {
    # Wireless ADB can briefly return exit 1 while the already-authorized
    # transport is being reused by the parent orchestrator. Retry only this
    # read-only readiness probe; all ownership/PID/focus checks below remain
    # strict and will still reject a persistent disconnect.
    $lastStateExitCode = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $state = Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'get-state') `
                -AllowFailure
        $lastStateExitCode = $state.ExitCode
        if ($state.ExitCode -eq 0 -and
                (($state.Lines -join '').Trim()) -ceq 'device') {
            return
        }
        if ($attempt -lt 5) { Start-Sleep -Milliseconds 500 }
    }
    throw "ADB get-state did not prove one ready device after 5 attempts (last exit $lastStateExitCode)."
}

function Get-PackageMainPid {
    $result = Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'shell', 'pidof', $Package) -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "$Package is not running."
    }

    $text = ($result.Lines -join ' ').Trim()
    $pids = @(
        [regex]::Matches($text, '(?<!\d)\d+(?!\d)') |
            ForEach-Object { [int]$_.Value } |
            Sort-Object -Unique
    )
    if ($pids.Count -eq 0) {
        throw "$Package is not running."
    }
    if ($pids.Count -ne 1) {
        throw "Expected one exact main PID for $Package, observed $($pids.Count)."
    }
    return [int]$pids[0]
}

function Get-ForbiddenPackageStoppedState {
    if ([string]::IsNullOrWhiteSpace($ForbiddenPackage)) {
        return [pscustomobject]@{ Known = $true; Stopped = $true }
    }
    $result = Invoke-Adb -Arguments @(
        '-s', $script:ResolvedSerial, 'shell', 'pidof', $ForbiddenPackage
    ) -AllowFailure
    $rows = @($result.Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($result.ExitCode -eq 1 -and $rows.Count -eq 0) {
        return [pscustomobject]@{ Known = $true; Stopped = $true }
    }
    if ($result.ExitCode -eq 0 -and $rows.Count -eq 1 -and
            $rows[0] -cmatch '^[1-9][0-9]*(?:\s+[1-9][0-9]*)*$') {
        return [pscustomobject]@{ Known = $true; Stopped = $false }
    }
    return [pscustomobject]@{ Known = $false; Stopped = $false }
}

function Get-FocusState {
    $result = Invoke-Adb -Arguments @('-s', $script:ResolvedSerial, 'shell', 'dumpsys', 'activity', 'activities') -AllowFailure
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Known = $false; Focused = $false }
    }

    # Quest dumpsys can retain multiple task-local topResumedActivity rows. The
    # first global/top row is the active foreground owner; accepting any later
    # historical row would incorrectly treat a backgrounded game as focused.
    $activeLine = $result.Lines |
        Where-Object { $_ -match 'topResumedActivity' } |
        Select-Object -First 1
    if ($null -eq $activeLine) {
        $activeLine = $result.Lines |
            Where-Object { $_ -match '(?:mResumedActivity|ResumedActivity)' } |
            Select-Object -First 1
    }
    if ($null -eq $activeLine) {
        return [pscustomobject]@{ Known = $false; Focused = $false }
    }

    $packageActivity = [regex]::Escape($Package) + '/'
    return [pscustomobject]@{
        Known = $true
        Focused = [bool]($activeLine -match $packageActivity)
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([Parameter(Mandatory)][string]$Value)

    if (($Value.Length -gt 0) -and ($Value -notmatch '[\s"]')) {
        return $Value
    }

    # CommandLineToArgvW-compatible quoting for ProcessStartInfo.Arguments.
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            $null = $builder.Append(('\' * (($backslashes * 2) + 1)))
            $null = $builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) {
        $null = $builder.Append(('\' * ($backslashes * 2)))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Start-AdbCaptureProcess {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:ResolvedAdb
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        $process.Dispose()
        throw 'Failed to start the PID-scoped ADB logcat process.'
    }

    return [pscustomobject]@{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
    }
}

function ConvertTo-InvariantDouble {
    param([Parameter(Mandatory)][string]$Value)

    return [double]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-VrApiLine {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][int]$ExpectedPid
    )

    if ($Line -notmatch '^\s*\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+(?<pid>\d+)\s+\d+\s+[VDIWEF]\s+VrApi\s*:\s*(?<message>.*)$') {
        return $null
    }

    $parsedPid = [int]$Matches.pid
    $message = [string]$Matches.message
    if ($message -notmatch '\bFPS=(?<fps>[0-9]+(?:\.[0-9]+)?)/(?<refresh>[0-9]+(?:\.[0-9]+)?)') {
        return [pscustomobject]@{
            IsVrApiFpsRow = $false
            IsForeignPid = ($parsedPid -ne $ExpectedPid)
            Sample = $null
        }
    }

    if ($parsedPid -ne $ExpectedPid) {
        return [pscustomobject]@{
            IsVrApiFpsRow = $true
            IsForeignPid = $true
            Sample = $null
        }
    }

    $sample = [ordered]@{
        Pid = $parsedPid
        AppFps = ConvertTo-InvariantDouble $Matches.fps
        DisplayRefreshHz = ConvertTo-InvariantDouble $Matches.refresh
        PredictionMs = $null
        Tear = $null
        Early = $null
        Stale = $null
        Stale2 = $null
        Stale5 = $null
        Stale10 = $null
        MaxConsecutiveStale = $null
        VSyncInterval = $null
        LatencyMode = $null
        AppMs = $null
        CpuAndGpuMs = $null
        GpuPercent = $null
        CpuPercent = $null
        TempC = $null
        FreeMB = $null
        CpuLevel = $null
        GpuLevel = $null
    }

    if ($message -match '\bPrd=(?<value>[0-9]+(?:\.[0-9]+)?)ms') {
        $sample.PredictionMs = ConvertTo-InvariantDouble $Matches.value
    }
    if ($message -match '\bTear=(?<value>[0-9]+)') {
        $sample.Tear = [int]$Matches.value
    }
    if ($message -match '\bEarly=(?<value>[0-9]+)') {
        $sample.Early = [int]$Matches.value
    }
    if ($message -match '\bStale=(?<value>[0-9]+)') {
        $sample.Stale = [int]$Matches.value
    }
    if ($message -match '\bStale2/5/10/max=(?<two>[0-9]+)/(?<five>[0-9]+)/(?<ten>[0-9]+)/(?<max>[0-9]+)') {
        $sample.Stale2 = [int]$Matches.two
        $sample.Stale5 = [int]$Matches.five
        $sample.Stale10 = [int]$Matches.ten
        $sample.MaxConsecutiveStale = [int]$Matches.max
    }
    if ($message -match '\bVSnc=(?<value>[0-9]+)') {
        $sample.VSyncInterval = [int]$Matches.value
    }
    if ($message -match '\bLat=(?<value>-?[0-9]+)') {
        $sample.LatencyMode = [int]$Matches.value
    }
    if ($message -match '\bApp=(?<value>[0-9]+(?:\.[0-9]+)?)ms') {
        $sample.AppMs = ConvertTo-InvariantDouble $Matches.value
    }
    if ($message -match '\bCPU&GPU=(?<value>[0-9]+(?:\.[0-9]+)?)ms') {
        $sample.CpuAndGpuMs = ConvertTo-InvariantDouble $Matches.value
    }
    if ($message -match '\bGPU%=(?<value>[0-9]+(?:\.[0-9]+)?)') {
        $rawGpu = ConvertTo-InvariantDouble $Matches.value
        $sample.GpuPercent = if ($rawGpu -le 1.5) { $rawGpu * 100.0 } else { $rawGpu }
    }
    if ($message -match '\bCPU%=(?<value>[0-9]+(?:\.[0-9]+)?)') {
        $rawCpu = ConvertTo-InvariantDouble $Matches.value
        $sample.CpuPercent = if ($rawCpu -le 1.5) { $rawCpu * 100.0 } else { $rawCpu }
    }
    if ($message -match '\bTemp=(?<value>-?[0-9]+(?:\.[0-9]+)?)C') {
        $sample.TempC = ConvertTo-InvariantDouble $Matches.value
    }
    if ($message -match '\bFree=(?<value>[0-9]+)MB') {
        $sample.FreeMB = [int]$Matches.value
    }
    if ($message -match '\bCPU(?:[0-9]+)?/GPU=(?<cpu>[0-9]+)/(?<gpu>[0-9]+)') {
        $sample.CpuLevel = [int]$Matches.cpu
        $sample.GpuLevel = [int]$Matches.gpu
    }

    return [pscustomobject]@{
        IsVrApiFpsRow = $true
        IsForeignPid = $false
        Sample = [pscustomobject]$sample
    }
}

function ConvertFrom-VrApiLines {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][int]$ExpectedPid
    )

    $samples = New-Object System.Collections.Generic.List[object]
    $fpsRows = 0
    $foreignRows = 0
    foreach ($line in $Lines) {
        $parsed = ConvertFrom-VrApiLine -Line $line -ExpectedPid $ExpectedPid
        if ($null -eq $parsed) {
            continue
        }
        if ($parsed.IsVrApiFpsRow) {
            $fpsRows++
        }
        if ($parsed.IsForeignPid) {
            $foreignRows++
        }
        if ($null -ne $parsed.Sample) {
            $samples.Add($parsed.Sample)
        }
    }

    return [pscustomobject]@{
        Samples = $samples.ToArray()
        VrApiFpsRows = $fpsRows
        ForeignPidRows = $foreignRows
    }
}

function Get-PresentDoubles {
    param([AllowEmptyCollection()][object[]]$Values)

    return [double[]]@($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
}

function Get-MeanOrNull {
    param([AllowEmptyCollection()][object[]]$Values)

    $present = @(Get-PresentDoubles $Values)
    if ($present.Count -eq 0) {
        return $null
    }
    return [double](($present | Measure-Object -Average).Average)
}

function Get-Percentile {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Values,
        [Parameter(Mandatory)][ValidateRange(0.0, 1.0)][double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [double]$sorted[0]
    }

    $position = ($sorted.Count - 1) * $Percentile
    $lower = [int][Math]::Floor($position)
    $upper = [int][Math]::Ceiling($position)
    if ($lower -eq $upper) {
        return [double]$sorted[$lower]
    }
    $weight = $position - $lower
    return ([double]$sorted[$lower] * (1.0 - $weight)) + ([double]$sorted[$upper] * $weight)
}

function ConvertTo-RoundedOrNull {
    param(
        $Value,
        [int]$Digits = 2
    )

    if ($null -eq $Value) {
        return $null
    }
    return [Math]::Round([double]$Value, $Digits)
}

function Get-ModeOrNull {
    param([AllowEmptyCollection()][object[]]$Values)

    $present = @($Values | Where-Object { $null -ne $_ })
    if ($present.Count -eq 0) {
        return $null
    }
    return $present | Group-Object |
        Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
        Select-Object -First 1
}

function ConvertFrom-AndroidProcessSnapshot {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
    )

    $parsedRows = 0
    $standaloneTrCount = 0
    $rgbLedScriptCount = 0

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or
            ($line -match '^\s*PID\s+PPID\s+NAME\s+CMD\s*$')) {
            continue
        }

        # Android toybox ps emits four columns for the requested projection.
        # CMD is deliberately consumed only long enough to classify the two
        # known contaminants; no row or identity leaves this function.
        if ($line -notmatch '^\s*\d+\s+\d+\s+(?<name>\S+)(?:\s+(?<cmd>.*))?$') {
            continue
        }

        $parsedRows++
        $name = [string]$Matches.name
        $command = if ($Matches.ContainsKey('cmd')) { [string]$Matches.cmd } else { '' }

        # Match an independently executing tr process, not a shell command
        # which merely contains the characters "tr" in an argument.
        if (($name -eq 'tr') -or
            ($command -match '^\s*(?:[^\s/]*/)*tr(?:\s|$)')) {
            $standaloneTrCount++
        }

        # rgb_led.sh normally appears as `sh /.../rgb_led.sh`. Match either
        # its process name or a command token ending in that exact basename.
        if (($name -eq 'rgb_led.sh') -or
            ($command -match '^\s*(?:(?:\S*/)?(?:sh|bash|dash)\s+)?["'']?(?:\S*/)?rgb_led\.sh["'']?(?:\s|$)')) {
            $rgbLedScriptCount++
        }
    }

    return [pscustomobject]@{
        ParsedRowCount = [int]$parsedRows
        StandaloneTrCount = [int]$standaloneTrCount
        RgbLedScriptCount = [int]$rgbLedScriptCount
    }
}

function Get-BenchmarkProcessGuardSnapshot {
    $result = Invoke-Adb -Arguments @(
        '-s', $script:ResolvedSerial,
        'shell', 'ps', '-A', '-o', 'PID,PPID,NAME,CMD'
    ) -AllowFailure

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Succeeded = $false
            StandaloneTrCount = $null
            RgbLedScriptCount = $null
        }
    }

    $aggregate = ConvertFrom-AndroidProcessSnapshot -Lines ([string[]]$result.Lines)
    return [pscustomobject]@{
        Succeeded = ($aggregate.ParsedRowCount -gt 0)
        StandaloneTrCount = if ($aggregate.ParsedRowCount -gt 0) { $aggregate.StandaloneTrCount } else { $null }
        RgbLedScriptCount = if ($aggregate.ParsedRowCount -gt 0) { $aggregate.RgbLedScriptCount } else { $null }
    }
}

function Get-BenchmarkProcessGuardInvalidReasons {
    param(
        [Parameter(Mandatory)]$Initial,
        [Parameter(Mandatory)]$Final
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $Initial.Succeeded) {
        $reasons.Add('External process guard could not read the initial process snapshot.')
    }
    if (-not $Final.Succeeded) {
        $reasons.Add('External process guard could not read the final process snapshot.')
    }

    if ($Initial.Succeeded -and ($Initial.StandaloneTrCount -gt 0)) {
        $reasons.Add("Standalone tr contaminant count was $($Initial.StandaloneTrCount) before capture.")
    }
    if ($Final.Succeeded -and ($Final.StandaloneTrCount -gt 0)) {
        $reasons.Add("Standalone tr contaminant count was $($Final.StandaloneTrCount) after capture.")
    }
    if ($Initial.Succeeded -and $Final.Succeeded -and
        ($Initial.RgbLedScriptCount -ne $Final.RgbLedScriptCount)) {
        $reasons.Add("rgb_led.sh process count changed during capture ($($Initial.RgbLedScriptCount) to $($Final.RgbLedScriptCount)).")
    }

    return [string[]]$reasons.ToArray()
}

function New-BenchmarkProcessGuardReport {
    param(
        [Parameter(Mandatory)]$Initial,
        [Parameter(Mandatory)]$Final
    )

        # Persist counts only. In particular, do not add raw ps rows, command
        # strings, PIDs/PPIDs, or a device identifier to this guard report.
    return [ordered]@{
        StandaloneTrCountBefore = if ($Initial.Succeeded) { [int]$Initial.StandaloneTrCount } else { $null }
        StandaloneTrCountAfter = if ($Final.Succeeded) { [int]$Final.StandaloneTrCount } else { $null }
        RgbLedScriptCountBefore = if ($Initial.Succeeded) { [int]$Initial.RgbLedScriptCount } else { $null }
        RgbLedScriptCountAfter = if ($Final.Succeeded) { [int]$Final.RgbLedScriptCount } else { $null }
    }
}

function Get-PerformanceLevelAggregate {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Values,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$TotalVrApiSamples
    )

    $present = [int[]]@(
        $Values |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [int]$_ }
    )
    $level4Count = @($present | Where-Object { $_ -eq 4 }).Count

    # Percentages deliberately use every PID-owned VrApi FPS sample as the
    # denominator. A row with missing level telemetry must lower coverage and
    # cannot make a CPU/GPU level-4 quality gate pass by omission.
    $distribution = @(
        $present | Group-Object | Sort-Object { [int]$_.Name } | ForEach-Object {
            [pscustomobject][ordered]@{
                Level = [int]$_.Name
                Count = [int]$_.Count
                PercentOfVrApiSamples = [double](100.0 * $_.Count / $TotalVrApiSamples)
            }
        }
    )

    return [pscustomobject][ordered]@{
        SampleCount = [int]$present.Count
        CoveragePercent = [double](100.0 * $present.Count / $TotalVrApiSamples)
        Level4SampleCount = [int]$level4Count
        Level4Percent = [double](100.0 * $level4Count / $TotalVrApiSamples)
        Distribution = $distribution
    }
}

function Get-RefreshMetricStrata {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Samples
    )

    # VrApi reports the active display rate once per aggregate row. Keep the
    # rows grouped by that observed rate so a later A/B analyzer can compare
    # like-for-like samples when QGO Dynamic changes rate during a run. The
    # output remains aggregate-only; no timestamp, raw log row, or per-frame
    # series is persisted.
    return @(
        $Samples |
            Group-Object { ([double]$_.DisplayRefreshHz).ToString(
                    '0.0', [Globalization.CultureInfo]::InvariantCulture) } |
            Sort-Object { [double]$_.Name } |
            ForEach-Object {
                $rows = @($_.Group)
                $fps = [double[]]@($rows | ForEach-Object { [double]$_.AppFps })
                $stale = [double[]]@(Get-PresentDoubles @($rows.Stale))
                $appMs = [double[]]@(Get-PresentDoubles @($rows.AppMs))
                $cpuAndGpuMs = [double[]]@(Get-PresentDoubles @($rows.CpuAndGpuMs))
                $gpuPercent = [double[]]@(Get-PresentDoubles @($rows.GpuPercent))
                $cpuPercent = [double[]]@(Get-PresentDoubles @($rows.CpuPercent))
                $temp = [double[]]@(Get-PresentDoubles @($rows.TempC))
                $cpuLevels = Get-PerformanceLevelAggregate -Values @($rows.CpuLevel) `
                    -TotalVrApiSamples $rows.Count
                $gpuLevels = Get-PerformanceLevelAggregate -Values @($rows.GpuLevel) `
                    -TotalVrApiSamples $rows.Count

                [pscustomobject][ordered]@{
                    Hz = [double]$_.Name
                    Samples = [int]$rows.Count
                    PercentOfVrApiSamples = [Math]::Round(
                        100.0 * $rows.Count / $Samples.Count, 1)
                    MeanAppFps = ConvertTo-RoundedOrNull (Get-MeanOrNull $fps)
                    P10AppFps = ConvertTo-RoundedOrNull `
                        (Get-Percentile -Values $fps -Percentile 0.10)
                    MeanStalePerSecond = ConvertTo-RoundedOrNull `
                        (Get-MeanOrNull $stale)
                    P95AppMs = ConvertTo-RoundedOrNull `
                        (Get-Percentile -Values $appMs -Percentile 0.95)
                    P95CpuAndGpuMs = ConvertTo-RoundedOrNull `
                        (Get-Percentile -Values $cpuAndGpuMs -Percentile 0.95)
                    MeanGpuPercent = ConvertTo-RoundedOrNull `
                        (Get-MeanOrNull $gpuPercent) 1
                    P95GpuPercent = ConvertTo-RoundedOrNull `
                        (Get-Percentile -Values $gpuPercent -Percentile 0.95) 1
                    MeanCpuPercent = ConvertTo-RoundedOrNull `
                        (Get-MeanOrNull $cpuPercent) 1
                    P95CpuPercent = ConvertTo-RoundedOrNull `
                        (Get-Percentile -Values $cpuPercent -Percentile 0.95) 1
                    FirstTempC = if ($temp.Count -gt 0) {
                        ConvertTo-RoundedOrNull $temp[0] 1
                    } else { $null }
                    MeanTempC = ConvertTo-RoundedOrNull (Get-MeanOrNull $temp) 1
                    TemperatureSampleCount = [int]$temp.Count
                    TemperatureCoveragePercent = [double](100.0 * $temp.Count / $rows.Count)
                    LastTempC = if ($temp.Count -gt 0) {
                        ConvertTo-RoundedOrNull $temp[$temp.Count - 1] 1
                    } else { $null }
                    MaxTempC = if ($temp.Count -gt 0) {
                        ConvertTo-RoundedOrNull (($temp | Measure-Object -Maximum).Maximum) 1
                    } else { $null }
                    CpuLevel4Percent = ConvertTo-RoundedOrNull $cpuLevels.Level4Percent 1
                    GpuLevel4Percent = ConvertTo-RoundedOrNull $gpuLevels.Level4Percent 1
                }
            }
    )
}

function Get-VrApiAggregate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Samples,
        [Parameter(Mandatory)][double]$ExpectedHz,
        [Parameter(Mandatory)][double]$ToleranceHz,
        [switch]$Dynamic
    )

    if ($Samples.Count -eq 0) {
        throw 'No PID-owned VrApi FPS rows were captured.'
    }

    $fps = [double[]]@($Samples | ForEach-Object { [double]$_.AppFps })
    $refresh = [double[]]@($Samples | ForEach-Object { [double]$_.DisplayRefreshHz })
    $refreshMatches = @($refresh | Where-Object { [Math]::Abs($_ - $ExpectedHz) -le $ToleranceHz }).Count
    $refreshMode = Get-ModeOrNull $refresh
    $refreshDistribution = @(
        $refresh | Group-Object | Sort-Object { [double]$_.Name } | ForEach-Object {
            [pscustomobject]@{
                Hz = [double]$_.Name
                Count = [int]$_.Count
                Percent = [Math]::Round(100.0 * $_.Count / $refresh.Count, 1)
            }
        }
    )

    $stale = @($Samples | Where-Object { $null -ne $_.Stale } | ForEach-Object { [int]$_.Stale })
    $tear = @($Samples | Where-Object { $null -ne $_.Tear } | ForEach-Object { [int]$_.Tear })
    $early = @($Samples | Where-Object { $null -ne $_.Early } | ForEach-Object { [int]$_.Early })
    $stale2 = @($Samples | Where-Object { $null -ne $_.Stale2 } | ForEach-Object { [int]$_.Stale2 })
    $stale5 = @($Samples | Where-Object { $null -ne $_.Stale5 } | ForEach-Object { [int]$_.Stale5 })
    $stale10 = @($Samples | Where-Object { $null -ne $_.Stale10 } | ForEach-Object { [int]$_.Stale10 })
    $maxConsecutiveStale = @($Samples | Where-Object { $null -ne $_.MaxConsecutiveStale } | ForEach-Object { [int]$_.MaxConsecutiveStale })
    $temp = @(Get-PresentDoubles @($Samples.TempC))
    $firstTemp = $Samples | Where-Object { $null -ne $_.TempC } | Select-Object -First 1
    $lastTemp = $Samples | Where-Object { $null -ne $_.TempC } | Select-Object -Last 1
    $free = @($Samples | Where-Object { $null -ne $_.FreeMB } | ForEach-Object { [int]$_.FreeMB })
    $cpuLevelMode = Get-ModeOrNull @($Samples.CpuLevel)
    $gpuLevelMode = Get-ModeOrNull @($Samples.GpuLevel)
    $cpuLevels = Get-PerformanceLevelAggregate -Values @($Samples.CpuLevel) -TotalVrApiSamples $Samples.Count
    $gpuLevels = Get-PerformanceLevelAggregate -Values @($Samples.GpuLevel) -TotalVrApiSamples $Samples.Count
    $refreshMetricStrata = Get-RefreshMetricStrata -Samples $Samples
    $vsyncMode = Get-ModeOrNull @($Samples.VSyncInterval)
    $latencyMode = Get-ModeOrNull @($Samples.LatencyMode)

    $refreshTransitions = 0
    $transitionStale = New-Object System.Collections.Generic.List[int]
    $stableRefreshStale = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $Samples.Count; $index++) {
        if ($null -eq $Samples[$index].Stale) {
            continue
        }
        $changed = $index -gt 0 -and
            [Math]::Abs([double]$Samples[$index].DisplayRefreshHz - [double]$Samples[$index - 1].DisplayRefreshHz) -gt 0.01
        if ($changed) {
            $refreshTransitions++
            $transitionStale.Add([int]$Samples[$index].Stale)
        } else {
            $stableRefreshStale.Add([int]$Samples[$index].Stale)
        }
    }

    $staleByRefresh = @(
        $Samples | Group-Object DisplayRefreshHz | Sort-Object { [double]$_.Name } | ForEach-Object {
            $bucketStale = @($_.Group | Where-Object { $null -ne $_.Stale } | ForEach-Object { [int]$_.Stale })
            [pscustomobject]@{
                Hz = [double]$_.Name
                Samples = [int]$_.Count
                MeanStalePerSecond = ConvertTo-RoundedOrNull (Get-MeanOrNull $bucketStale)
                NonZeroStaleSamplePercent = if ($bucketStale.Count -gt 0) {
                    [Math]::Round(100.0 * @($bucketStale | Where-Object { $_ -gt 0 }).Count / $bucketStale.Count, 1)
                } else { $null }
            }
        }
    )

    return [ordered]@{
        VrApiSamples = $Samples.Count
        MeanAppFps = ConvertTo-RoundedOrNull (Get-MeanOrNull $fps)
        MedianAppFps = ConvertTo-RoundedOrNull (Get-Percentile -Values $fps -Percentile 0.50)
        P10AppFps = ConvertTo-RoundedOrNull (Get-Percentile -Values $fps -Percentile 0.10)
        MinAppFps = ConvertTo-RoundedOrNull (($fps | Measure-Object -Minimum).Minimum)
        MaxAppFps = ConvertTo-RoundedOrNull (($fps | Measure-Object -Maximum).Maximum)
        ExpectedDisplayRefreshHz = if ($Dynamic) { $null } else { $ExpectedHz }
        DisplayRefreshToleranceHz = if ($Dynamic) { $null } else { $ToleranceHz }
        DisplayRefreshModeHz = if ($null -ne $refreshMode) { [double]$refreshMode.Name } else { $null }
        MeanDisplayRefreshHz = ConvertTo-RoundedOrNull (Get-MeanOrNull $refresh)
        MinDisplayRefreshHz = ConvertTo-RoundedOrNull (($refresh | Measure-Object -Minimum).Minimum)
        MaxDisplayRefreshHz = ConvertTo-RoundedOrNull (($refresh | Measure-Object -Maximum).Maximum)
        DisplayRefreshMatchPercent = if ($Dynamic) {
            $null
        } else {
            [Math]::Round(100.0 * $refreshMatches / $refresh.Count, 1)
        }
        DisplayRefreshDistribution = $refreshDistribution
        RefreshMetricStrata = $refreshMetricStrata
        StaleTotal = if ($stale.Count -gt 0) { [int](($stale | Measure-Object -Sum).Sum) } else { $null }
        MeanStalePerSecond = ConvertTo-RoundedOrNull (Get-MeanOrNull $stale)
        MaxStalePerSecond = if ($stale.Count -gt 0) { [int](($stale | Measure-Object -Maximum).Maximum) } else { $null }
        StaleNonZeroSamplePercent = if ($stale.Count -gt 0) {
            [Math]::Round(100.0 * @($stale | Where-Object { $_ -gt 0 }).Count / $stale.Count, 1)
        } else { $null }
        Stale2Total = if ($stale2.Count -gt 0) { [int](($stale2 | Measure-Object -Sum).Sum) } else { $null }
        Stale5Total = if ($stale5.Count -gt 0) { [int](($stale5 | Measure-Object -Sum).Sum) } else { $null }
        Stale10Total = if ($stale10.Count -gt 0) { [int](($stale10 | Measure-Object -Sum).Sum) } else { $null }
        MaxConsecutiveStale = if ($maxConsecutiveStale.Count -gt 0) {
            [int](($maxConsecutiveStale | Measure-Object -Maximum).Maximum)
        } else { $null }
        RefreshTransitionCount = $refreshTransitions
        MeanStaleOnRefreshTransition = ConvertTo-RoundedOrNull (Get-MeanOrNull $transitionStale.ToArray())
        MeanStaleAtStableRefresh = ConvertTo-RoundedOrNull (Get-MeanOrNull $stableRefreshStale.ToArray())
        StaleByRefresh = $staleByRefresh
        TearTotal = if ($tear.Count -gt 0) { [int](($tear | Measure-Object -Sum).Sum) } else { $null }
        EarlyTotal = if ($early.Count -gt 0) { [int](($early | Measure-Object -Sum).Sum) } else { $null }
        VSyncIntervalMode = if ($null -ne $vsyncMode) { [int]$vsyncMode.Name } else { $null }
        LatencyMode = if ($null -ne $latencyMode) { [int]$latencyMode.Name } else { $null }
        MeanPredictionMs = ConvertTo-RoundedOrNull (Get-MeanOrNull @($Samples.PredictionMs))
        P95PredictionMs = ConvertTo-RoundedOrNull (Get-Percentile -Values (Get-PresentDoubles @($Samples.PredictionMs)) -Percentile 0.95)
        MeanAppMs = ConvertTo-RoundedOrNull (Get-MeanOrNull @($Samples.AppMs))
        P95AppMs = ConvertTo-RoundedOrNull (Get-Percentile -Values (Get-PresentDoubles @($Samples.AppMs)) -Percentile 0.95)
        MeanCpuAndGpuMs = ConvertTo-RoundedOrNull (Get-MeanOrNull @($Samples.CpuAndGpuMs))
        P95CpuAndGpuMs = ConvertTo-RoundedOrNull (Get-Percentile -Values (Get-PresentDoubles @($Samples.CpuAndGpuMs)) -Percentile 0.95)
        MeanGpuPercent = ConvertTo-RoundedOrNull (Get-MeanOrNull @($Samples.GpuPercent)) 1
        P95GpuPercent = ConvertTo-RoundedOrNull (Get-Percentile -Values (Get-PresentDoubles @($Samples.GpuPercent)) -Percentile 0.95) 1
        MeanCpuPercent = ConvertTo-RoundedOrNull (Get-MeanOrNull @($Samples.CpuPercent)) 1
        P95CpuPercent = ConvertTo-RoundedOrNull (Get-Percentile -Values (Get-PresentDoubles @($Samples.CpuPercent)) -Percentile 0.95) 1
        MeanTempC = ConvertTo-RoundedOrNull (Get-MeanOrNull $temp) 1
        TemperatureSampleCount = [int]$temp.Count
        TemperatureCoveragePercent = [double](100.0 * $temp.Count / $Samples.Count)
        FirstTempC = if ($null -ne $firstTemp) { ConvertTo-RoundedOrNull $firstTemp.TempC 1 } else { $null }
        LastTempC = if ($null -ne $lastTemp) { ConvertTo-RoundedOrNull $lastTemp.TempC 1 } else { $null }
        MaxTempC = if ($temp.Count -gt 0) { ConvertTo-RoundedOrNull (($temp | Measure-Object -Maximum).Maximum) 1 } else { $null }
        MeanFreeMB = ConvertTo-RoundedOrNull (Get-MeanOrNull $free) 0
        MinFreeMB = if ($free.Count -gt 0) { [int](($free | Measure-Object -Minimum).Minimum) } else { $null }
        CpuLevelMode = if ($null -ne $cpuLevelMode) { [int]$cpuLevelMode.Name } else { $null }
        GpuLevelMode = if ($null -ne $gpuLevelMode) { [int]$gpuLevelMode.Name } else { $null }
        CpuLevelSampleCount = $cpuLevels.SampleCount
        CpuLevelCoveragePercent = $cpuLevels.CoveragePercent
        CpuLevel4SampleCount = $cpuLevels.Level4SampleCount
        CpuLevel4Percent = $cpuLevels.Level4Percent
        CpuLevelDistribution = $cpuLevels.Distribution
        GpuLevelSampleCount = $gpuLevels.SampleCount
        GpuLevelCoveragePercent = $gpuLevels.CoveragePercent
        GpuLevel4SampleCount = $gpuLevels.Level4SampleCount
        GpuLevel4Percent = $gpuLevels.Level4Percent
        GpuLevelDistribution = $gpuLevels.Distribution
    }
}

function Save-AggregateJson {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($fullPath) -ne '.json') {
        throw '-OutputJson must end in .json.'
    }
    if (Test-Path -LiteralPath $fullPath) {
        throw "Refusing to overwrite existing aggregate: $fullPath"
    }

    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $temporaryPath = "$fullPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $json = $Summary | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::Move($temporaryPath, $fullPath)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            [IO.File]::Delete($temporaryPath)
        }
    }

    return $fullPath
}

function Invoke-SelfTest {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw 'SelfTest failed: benchmark script could not be parsed for reserved-variable checks.'
    }
    if (@(Get-ReservedLastExitCodeAssignments $ast).Count -ne 0) {
        throw 'SelfTest failed: benchmark script assigns to reserved automatic variable $LASTEXITCODE.'
    }
    $syntheticTokens = $null
    $syntheticErrors = $null
    $syntheticAst = [Management.Automation.Language.Parser]::ParseInput(
        '$LaStExItCoDe = 7', [ref]$syntheticTokens, [ref]$syntheticErrors)
    if (@($syntheticErrors).Count -ne 0 -or
        @(Get-ReservedLastExitCodeAssignments $syntheticAst).Count -ne 1) {
        throw 'SelfTest failed: reserved $LASTEXITCODE assignment guard is not case-insensitive.'
    }

    $lines = @(
        '08-28 21:00:01.000 19846 100 I VrApi   : FPS=70/72,Prd=39ms,Tear=0,Early=0,Stale=1,Stale2/5/10/max=0/0/0/1,VSnc=1,Lat=-4,Free=3900MB,Temp=42.0C/0.0C,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12),CPU4/GPU=4/4',
        '08-28 21:00:02.000 19846 100 I VrApi   : FPS=68/80,Prd=40ms,Tear=0,Early=1,Stale=0,Stale2/5/10/max=0/0/0/0,VSnc=1,Lat=-4,Free=3800MB,Temp=44.0C/0.0C,App=10.00ms,CPU&GPU=11.00ms,GPU%=0.80,CPU%=0.61(W10),CPU4/GPU=4/4',
        '08-28 21:00:03.000 20918 100 I VrApi   : FPS=90/90,Stale=9,Free=1MB,Temp=99.0C/0.0C,App=1.00ms,GPU%=1.00,CPU%=1.00(W1)'
    )
    $parsed = ConvertFrom-VrApiLines -Lines $lines -ExpectedPid 19846
    $summary = Get-VrApiAggregate -Samples $parsed.Samples -ExpectedHz 72 -ToleranceHz 0.5

    $assertions = @(
        @{ Name = 'Owned samples'; Actual = $parsed.Samples.Count; Expected = 2 },
        @{ Name = 'Foreign rows detected'; Actual = $parsed.ForeignPidRows; Expected = 1 },
        @{ Name = 'Mean application FPS'; Actual = $summary.MeanAppFps; Expected = 69.0 },
        @{ Name = 'P10 application FPS'; Actual = $summary.P10AppFps; Expected = 68.2 },
        @{ Name = 'Display refresh mode'; Actual = $summary.DisplayRefreshModeHz; Expected = 72.0 },
        @{ Name = 'Display refresh match'; Actual = $summary.DisplayRefreshMatchPercent; Expected = 50.0 },
        @{ Name = 'CPU level'; Actual = $summary.CpuLevelMode; Expected = 4 },
        @{ Name = 'GPU level'; Actual = $summary.GpuLevelMode; Expected = 4 },
        @{ Name = 'CPU level sample count'; Actual = $summary.CpuLevelSampleCount; Expected = 2 },
        @{ Name = 'GPU level sample count'; Actual = $summary.GpuLevelSampleCount; Expected = 2 },
        @{ Name = 'CPU level coverage'; Actual = $summary.CpuLevelCoveragePercent; Expected = 100.0 },
        @{ Name = 'GPU level coverage'; Actual = $summary.GpuLevelCoveragePercent; Expected = 100.0 },
        @{ Name = 'CPU level-4 sample count'; Actual = $summary.CpuLevel4SampleCount; Expected = 2 },
        @{ Name = 'GPU level-4 sample count'; Actual = $summary.GpuLevel4SampleCount; Expected = 2 },
        @{ Name = 'CPU level-4 percent'; Actual = $summary.CpuLevel4Percent; Expected = 100.0 },
        @{ Name = 'GPU level-4 percent'; Actual = $summary.GpuLevel4Percent; Expected = 100.0 },
        @{ Name = 'Stale total'; Actual = $summary.StaleTotal; Expected = 1 },
        @{ Name = 'Refresh transitions'; Actual = $summary.RefreshTransitionCount; Expected = 1 },
        @{ Name = 'Latency mode'; Actual = $summary.LatencyMode; Expected = -4 },
        @{ Name = 'VSync interval'; Actual = $summary.VSyncIntervalMode; Expected = 1 },
        @{ Name = 'Prediction mean'; Actual = $summary.MeanPredictionMs; Expected = 39.5 },
        @{ Name = 'CPU and GPU mean'; Actual = $summary.MeanCpuAndGpuMs; Expected = 12.0 },
        @{ Name = 'Minimum free memory'; Actual = $summary.MinFreeMB; Expected = 3800 },
        @{ Name = 'First temperature'; Actual = $summary.FirstTempC; Expected = 42.0 },
        @{ Name = 'Last temperature'; Actual = $summary.LastTempC; Expected = 44.0 }
    )
    foreach ($assertion in $assertions) {
        if ([double]$assertion.Actual -ne [double]$assertion.Expected) {
            throw "SelfTest failed: $($assertion.Name). Expected $($assertion.Expected), got $($assertion.Actual)."
        }
    }

    $cpuLevel4Bucket = @($summary.CpuLevelDistribution | Where-Object { $_.Level -eq 4 })
    $gpuLevel4Bucket = @($summary.GpuLevelDistribution | Where-Object { $_.Level -eq 4 })
    if (($cpuLevel4Bucket.Count -ne 1) -or ($cpuLevel4Bucket[0].Count -ne 2) -or
        ($cpuLevel4Bucket[0].PercentOfVrApiSamples -ne 100.0)) {
        throw 'SelfTest failed: CPU level distribution is not deterministic.'
    }
    if (($gpuLevel4Bucket.Count -ne 1) -or ($gpuLevel4Bucket[0].Count -ne 2) -or
        ($gpuLevel4Bucket[0].PercentOfVrApiSamples -ne 100.0)) {
        throw 'SelfTest failed: GPU level distribution is not deterministic.'
    }

    $refresh72 = @($summary.RefreshMetricStrata | Where-Object { $_.Hz -eq 72.0 })
    $refresh80 = @($summary.RefreshMetricStrata | Where-Object { $_.Hz -eq 80.0 })
    if (($summary.RefreshMetricStrata.Count -ne 2) -or
        ($refresh72.Count -ne 1) -or ($refresh80.Count -ne 1) -or
        ($refresh72[0].Samples -ne 1) -or ($refresh80[0].Samples -ne 1) -or
        ($refresh72[0].P95CpuAndGpuMs -ne 13.0) -or
        ($refresh80[0].P95CpuAndGpuMs -ne 11.0) -or
        ($refresh72[0].MeanStalePerSecond -ne 1.0) -or
        ($refresh80[0].MeanStalePerSecond -ne 0.0)) {
        throw 'SelfTest failed: aggregate refresh metric strata are incorrect.'
    }

    $mixedLevelLines = @(
        '08-28 21:01:01.000 19846 100 I VrApi   : FPS=72/72,Prd=39ms,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12),CPU4/GPU=4/4',
        '08-28 21:01:02.000 19846 100 I VrApi   : FPS=72/72,Prd=39ms,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12),CPU4/GPU=3/4',
        '08-28 21:01:03.000 19846 100 I VrApi   : FPS=72/72,Prd=39ms,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12),CPU4/GPU=4/2',
        '08-28 21:01:04.000 19846 100 I VrApi   : FPS=72/72,Prd=39ms,Stale=0,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12)'
    )
    $mixedLevelParsed = ConvertFrom-VrApiLines -Lines $mixedLevelLines -ExpectedPid 19846
    $mixedLevelSummary = Get-VrApiAggregate -Samples $mixedLevelParsed.Samples -ExpectedHz 72 -ToleranceHz 0.5
    $mixedLevelAssertions = @(
        @{ Name = 'Mixed CPU level sample count'; Actual = $mixedLevelSummary.CpuLevelSampleCount; Expected = 3 },
        @{ Name = 'Mixed GPU level sample count'; Actual = $mixedLevelSummary.GpuLevelSampleCount; Expected = 3 },
        @{ Name = 'Mixed CPU level coverage'; Actual = $mixedLevelSummary.CpuLevelCoveragePercent; Expected = 75.0 },
        @{ Name = 'Mixed GPU level coverage'; Actual = $mixedLevelSummary.GpuLevelCoveragePercent; Expected = 75.0 },
        @{ Name = 'Mixed CPU level-4 count'; Actual = $mixedLevelSummary.CpuLevel4SampleCount; Expected = 2 },
        @{ Name = 'Mixed GPU level-4 count'; Actual = $mixedLevelSummary.GpuLevel4SampleCount; Expected = 2 },
        @{ Name = 'Mixed CPU level-4 percent'; Actual = $mixedLevelSummary.CpuLevel4Percent; Expected = 50.0 },
        @{ Name = 'Mixed GPU level-4 percent'; Actual = $mixedLevelSummary.GpuLevel4Percent; Expected = 50.0 }
    )
    foreach ($assertion in $mixedLevelAssertions) {
        if ([double]$assertion.Actual -ne [double]$assertion.Expected) {
            throw "SelfTest failed: $($assertion.Name). Expected $($assertion.Expected), got $($assertion.Actual)."
        }
    }

    $cpuLevel3Bucket = @($mixedLevelSummary.CpuLevelDistribution | Where-Object { $_.Level -eq 3 })
    $mixedCpuLevel4Bucket = @($mixedLevelSummary.CpuLevelDistribution | Where-Object { $_.Level -eq 4 })
    $gpuLevel2Bucket = @($mixedLevelSummary.GpuLevelDistribution | Where-Object { $_.Level -eq 2 })
    $mixedGpuLevel4Bucket = @($mixedLevelSummary.GpuLevelDistribution | Where-Object { $_.Level -eq 4 })
    if (($cpuLevel3Bucket.Count -ne 1) -or ($cpuLevel3Bucket[0].Count -ne 1) -or
        ($cpuLevel3Bucket[0].PercentOfVrApiSamples -ne 25.0) -or
        ($mixedCpuLevel4Bucket.Count -ne 1) -or ($mixedCpuLevel4Bucket[0].Count -ne 2) -or
        ($mixedCpuLevel4Bucket[0].PercentOfVrApiSamples -ne 50.0)) {
        throw 'SelfTest failed: mixed CPU level distribution is incorrect.'
    }
    if (($gpuLevel2Bucket.Count -ne 1) -or ($gpuLevel2Bucket[0].Count -ne 1) -or
        ($gpuLevel2Bucket[0].PercentOfVrApiSamples -ne 25.0) -or
        ($mixedGpuLevel4Bucket.Count -ne 1) -or ($mixedGpuLevel4Bucket[0].Count -ne 2) -or
        ($mixedGpuLevel4Bucket[0].PercentOfVrApiSamples -ne 50.0)) {
        throw 'SelfTest failed: mixed GPU level distribution is incorrect.'
    }

    # The additions are intentionally aggregate-only and additive. Keep the
    # existing schema version and legacy fields readable by older consumers.
    $compatibilityJson = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Aggregate = $mixedLevelSummary
    } | ConvertTo-Json -Depth 8
    $compatibilityRoundTrip = $compatibilityJson | ConvertFrom-Json
    if (($compatibilityRoundTrip.SchemaVersion -ne 1) -or
        ($null -eq $compatibilityRoundTrip.Aggregate.MeanAppFps) -or
        ($null -eq $compatibilityRoundTrip.Aggregate.CpuLevelMode) -or
        ($null -eq $compatibilityRoundTrip.Aggregate.GpuLevelMode) -or
        ($null -eq $compatibilityRoundTrip.Aggregate.CpuLevel4Percent) -or
        ($null -eq $compatibilityRoundTrip.Aggregate.GpuLevel4Percent) -or
        (@($compatibilityRoundTrip.Aggregate.RefreshMetricStrata).Count -ne 1)) {
        throw 'SelfTest failed: aggregate JSON is not backward-compatible and additive.'
    }

    $wrongRefresh = Get-VrApiAggregate -Samples $parsed.Samples -ExpectedHz 90 -ToleranceHz 0.5
    if ($wrongRefresh.DisplayRefreshMatchPercent -ne 0.0) {
        throw 'SelfTest failed: a 72 Hz capture incorrectly matched a 90 Hz expectation.'
    }

    $dynamic = Get-VrApiAggregate -Samples $parsed.Samples -ExpectedHz 72 -ToleranceHz 0.5 -Dynamic
    if ($null -ne $dynamic.ExpectedDisplayRefreshHz -or $null -ne $dynamic.DisplayRefreshMatchPercent) {
        throw 'SelfTest failed: DynamicRefresh still reports a fixed-rate acceptance target.'
    }

    $processLines = @(
        '  PID  PPID NAME         CMD',
        '    1     0 init         /system/bin/init',
        '10373     1 sh           sh /data/user/0/com.lumi.singularity/files/rgb_led.sh',
        '28942 28940 tr           tr \000 \n',
        '30001     1 logger       logger tr-is-mentioned-but-is-not-a-process',
        '30002     1 logger       logger rgb_led.sh-is-mentioned-but-is-not-a-process',
        'this malformed row is ignored'
    )
    $processAggregate = ConvertFrom-AndroidProcessSnapshot -Lines $processLines
    if (($processAggregate.ParsedRowCount -ne 5) -or
        ($processAggregate.StandaloneTrCount -ne 1) -or
        ($processAggregate.RgbLedScriptCount -ne 1)) {
        throw 'SelfTest failed: Android process snapshot parsing is incorrect.'
    }

    $cleanStart = [pscustomobject]@{
        Succeeded = $true
        StandaloneTrCount = 0
        RgbLedScriptCount = 1
    }
    $cleanEnd = [pscustomobject]@{
        Succeeded = $true
        StandaloneTrCount = 0
        RgbLedScriptCount = 1
    }
    if (@(Get-BenchmarkProcessGuardInvalidReasons -Initial $cleanStart -Final $cleanEnd).Count -ne 0) {
        throw 'SelfTest failed: a steady rgb_led.sh count was not allowed.'
    }

    $trStart = [pscustomobject]@{
        Succeeded = $true
        StandaloneTrCount = 1
        RgbLedScriptCount = 1
    }
    $trEnd = [pscustomobject]@{
        Succeeded = $true
        StandaloneTrCount = 2
        RgbLedScriptCount = 1
    }
    $trReasons = @(Get-BenchmarkProcessGuardInvalidReasons -Initial $trStart -Final $trEnd)
    if (($trReasons.Count -ne 2) -or
        (-not ($trReasons -match 'before capture')) -or
        (-not ($trReasons -match 'after capture'))) {
        throw 'SelfTest failed: standalone tr did not invalidate both guarded boundaries.'
    }

    $rgbChanged = [pscustomobject]@{
        Succeeded = $true
        StandaloneTrCount = 0
        RgbLedScriptCount = 0
    }
    $rgbReasons = @(Get-BenchmarkProcessGuardInvalidReasons -Initial $cleanStart -Final $rgbChanged)
    if (($rgbReasons.Count -ne 1) -or (-not ($rgbReasons[0] -match 'rgb_led\.sh'))) {
        throw 'SelfTest failed: an rgb_led.sh count change did not invalidate the run.'
    }

    $failedSnapshot = [pscustomobject]@{
        Succeeded = $false
        StandaloneTrCount = $null
        RgbLedScriptCount = $null
    }
    $failedReasons = @(Get-BenchmarkProcessGuardInvalidReasons -Initial $failedSnapshot -Final $cleanEnd)
    if (($failedReasons.Count -ne 1) -or (-not ($failedReasons[0] -match 'initial process snapshot'))) {
        throw 'SelfTest failed: an unreadable process snapshot did not invalidate the run.'
    }

    $guardReport = New-BenchmarkProcessGuardReport -Initial $cleanStart -Final $cleanEnd
    $guardJson = $guardReport | ConvertTo-Json -Compress
    if (($guardReport.Keys.Count -ne 4) -or
        ($guardReport.StandaloneTrCountBefore -ne 0) -or
        ($guardReport.StandaloneTrCountAfter -ne 0) -or
        ($guardReport.RgbLedScriptCountBefore -ne 1) -or
        ($guardReport.RgbLedScriptCountAfter -ne 1) -or
        ($guardJson -match '(?i)pid|ppid|cmd|serial|device|/data/')) {
        throw 'SelfTest failed: process guard output is not aggregate-only and identifier-free.'
    }

    [pscustomobject]@{
        Result = 'PASS'
        Assertions = $assertions.Count + $mixedLevelAssertions.Count + 15
        MetricOwnerPolicy = 'Exact app PID only'
        RawLogsPersisted = $false
        RawProcessRowsPersisted = $false
        ReservedLastExitCodeAssignmentGuard = $true
    }
}

function Measure-PidScopedVrApi {
    $initialPid = Get-PackageMainPid
    $initialForbidden = Get-ForbiddenPackageStoppedState
    if (-not $initialForbidden.Known -or -not $initialForbidden.Stopped) {
        throw 'The forbidden package was not conclusively stopped before capture.'
    }
    $initialFocus = Get-FocusState
    if (-not $initialFocus.Known) {
        throw 'Could not determine the resumed Android activity before capture.'
    }
    if (-not $initialFocus.Focused) {
        throw "$Package is running but is not the resumed Android activity. Return to the benchmark scene first."
    }

    $initialProcessGuard = Get-BenchmarkProcessGuardSnapshot

    $captureArguments = @(
        '-s', $script:ResolvedSerial,
        'shell', 'timeout', "$Seconds",
        # `-T 1` avoids adb-shell quoting problems while limiting pre-capture
        # history to one PID-owned row. Coverage and PID/focus gates still
        # define the accepted measurement window.
        'logcat', "--pid=$initialPid", '-v', 'threadtime', '-T', '1',
        'VrApi:I', '*:S'
    )
    $capture = Start-AdbCaptureProcess -Arguments $captureArguments
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $polls = 0
    $samePidPolls = 0
    $focusKnownPolls = 0
    $focusedPolls = 0
    $pollErrors = 0
    $forbiddenKnownPolls = 0
    $forbiddenStoppedPolls = 0
    $forbiddenPollErrors = 0

    try {
        while (-not $capture.Process.HasExited) {
            $remainingMs = [Math]::Max(0, ($Seconds + 10) * 1000 - $stopwatch.ElapsedMilliseconds)
            if ($remainingMs -le 0) {
                $capture.Process.Kill()
                throw 'The PID-scoped ADB logcat process did not stop after the bounded capture window.'
            }

            Start-Sleep -Milliseconds ([int][Math]::Min($PollSeconds * 1000, $remainingMs))
            if ($capture.Process.HasExited) {
                break
            }

            $polls++
            try {
                if ((Get-PackageMainPid) -eq $initialPid) {
                    $samePidPolls++
                }
                $focus = Get-FocusState
                if ($focus.Known) {
                    $focusKnownPolls++
                    if ($focus.Focused) {
                        $focusedPolls++
                    }
                }
            } catch {
                $pollErrors++
            }
            try {
                $forbiddenState = Get-ForbiddenPackageStoppedState
                if ($forbiddenState.Known) {
                    $forbiddenKnownPolls++
                    if ($forbiddenState.Stopped) { $forbiddenStoppedPolls++ }
                } else {
                    $forbiddenPollErrors++
                }
            } catch {
                $forbiddenPollErrors++
            }
        }

        $capture.Process.WaitForExit()
        $exitCode = $capture.Process.ExitCode
        $stdout = $capture.StdoutTask.GetAwaiter().GetResult()
        # Some Quest/platform-tools pairs forward the remote `logcat` stream
        # through adb's stderr channel. Merge both streams only in memory;
        # aggregate output below still persists no raw runtime text.
        $stderr = $capture.StderrTask.GetAwaiter().GetResult()
        $capturedText = @($stdout, $stderr) -join "`n"
    } finally {
        $stopwatch.Stop()
        if (-not $capture.Process.HasExited) {
            $capture.Process.Kill()
            $capture.Process.WaitForExit()
        }
        $capture.Process.Dispose()
    }

    $finalProcessGuard = Get-BenchmarkProcessGuardSnapshot

    # Android's toybox timeout is surfaced by adb as either 124 or 1,
    # depending on the platform-tools/device pairing. All other acceptance
    # gates below still require a full-duration, dense, PID-owned capture.
    if ($exitCode -notin @(0, 1, 124)) {
        throw "PID-scoped ADB capture failed with exit code $exitCode. No report was saved."
    }

    $finalPid = $null
    try {
        $finalPid = Get-PackageMainPid
    } catch {
        $finalPid = $null
    }
    $finalFocus = Get-FocusState
    $finalForbidden = Get-ForbiddenPackageStoppedState

    $lines = [string[]]@($capturedText -split "`r?`n" | Where-Object { $_.Length -gt 0 })
    $parsed = ConvertFrom-VrApiLines -Lines $lines -ExpectedPid $initialPid
    # Raw text is intentionally discarded before aggregate construction/output.
    $stdout = $null
    $stderr = $null
    $capturedText = $null
    $lines = $null

    $aggregate = Get-VrApiAggregate -Samples $parsed.Samples -ExpectedHz $ExpectedRefreshHz `
        -ToleranceHz $RefreshToleranceHz -Dynamic:$DynamicRefresh
    $sampleCoveragePercent = [Math]::Round(100.0 * $parsed.Samples.Count / $Seconds, 1)
    $samePidPercent = if ($polls -gt 0) { [Math]::Round(100.0 * $samePidPolls / $polls, 1) } else { 0.0 }
    # Unknown focus polls count against coverage. Dividing only by known polls
    # could turn one known-focused sample plus many unreadable polls into 100%.
    $focusedPercent = if ($polls -gt 0) {
        [Math]::Round(100.0 * $focusedPolls / $polls, 1)
    } else { 0.0 }
    $focusKnownPercent = if ($polls -gt 0) {
        [Math]::Round(100.0 * $focusKnownPolls / $polls, 1)
    } else { 0.0 }
    $forbiddenStoppedPercent = if ($forbiddenKnownPolls -gt 0) {
        [Math]::Round(100.0 * $forbiddenStoppedPolls / $forbiddenKnownPolls, 1)
    } elseif ([string]::IsNullOrWhiteSpace($ForbiddenPackage)) { 100.0 } else { 0.0 }

    $invalidReasons = New-Object System.Collections.Generic.List[string]
    if (($null -eq $finalPid) -or ($finalPid -ne $initialPid)) {
        $invalidReasons.Add('Package PID changed or disappeared during capture.')
    }
    if ($samePidPercent -lt 100.0) {
        $invalidReasons.Add("Exact app PID was present for only $samePidPercent percent of runtime polls.")
    }
    if (($focusKnownPolls -eq 0) -or ($focusedPercent -lt 95.0) -or (-not $finalFocus.Known) -or (-not $finalFocus.Focused)) {
        $invalidReasons.Add("App focus coverage was $focusedPercent percent; at least 95 percent and focused-at-end are required.")
    }
    if ($pollErrors -gt 0) {
        $invalidReasons.Add("$pollErrors runtime ownership/focus poll(s) failed.")
    }
    if (-not [string]::IsNullOrWhiteSpace($ForbiddenPackage) -and
            (($forbiddenKnownPolls -eq 0) -or
             ($forbiddenStoppedPercent -lt 100.0) -or
             ($forbiddenPollErrors -gt 0) -or
             (-not $finalForbidden.Known) -or
             (-not $finalForbidden.Stopped))) {
        $invalidReasons.Add(
            "Forbidden-package stopped coverage was $forbiddenStoppedPercent percent; 100 percent and stopped-at-end are required.")
    }
    if ($sampleCoveragePercent -lt $MinimumSampleCoveragePercent) {
        $invalidReasons.Add("VrApi sample coverage was $sampleCoveragePercent percent; minimum is $MinimumSampleCoveragePercent percent.")
    }
    if ($parsed.ForeignPidRows -gt 0) {
        $invalidReasons.Add("Logcat --pid isolation failed: $($parsed.ForeignPidRows) foreign VrApi row(s) were observed.")
    }
    if ((-not $DynamicRefresh) -and ($aggregate.DisplayRefreshMatchPercent -lt $MinimumRefreshMatchPercent)) {
        $invalidReasons.Add("Observed display refresh matched $ExpectedRefreshHz Hz for only $($aggregate.DisplayRefreshMatchPercent) percent of samples; minimum is $MinimumRefreshMatchPercent percent.")
    }
    foreach ($reason in @(Get-BenchmarkProcessGuardInvalidReasons -Initial $initialProcessGuard -Final $finalProcessGuard)) {
        $invalidReasons.Add($reason)
    }

    $processGuardReport = New-BenchmarkProcessGuardReport -Initial $initialProcessGuard -Final $finalProcessGuard

    $summary = [ordered]@{
        SchemaVersion = 1
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Package = $Package
        DeviceSelection = 'Resolved locally; serial intentionally not persisted'
        AppPid = $initialPid
        DurationRequestedSeconds = $Seconds
        DurationWallSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        RefreshPolicy = if ($DynamicRefresh) { 'Dynamic' } else { "Fixed-$ExpectedRefreshHz-Hz" }
        Polls = $polls
        ExactPidPollPercent = $samePidPercent
        FocusKnownPolls = $focusKnownPolls
        FocusKnownPollPercent = $focusKnownPercent
        FocusedPollPercent = $focusedPercent
        ForbiddenPackageStoppedAtStart = [bool]$initialForbidden.Stopped
        ForbiddenPackageKnownPolls = $forbiddenKnownPolls
        ForbiddenPackageStoppedPolls = $forbiddenStoppedPolls
        ForbiddenPackageStoppedPollPercent = $forbiddenStoppedPercent
        ForbiddenPackagePollErrors = $forbiddenPollErrors
        ForbiddenPackageStoppedAtEnd = [bool]($finalForbidden.Known -and $finalForbidden.Stopped)
        SampleCoveragePercent = $sampleCoveragePercent
        CaptureExitCode = $exitCode
        MetricOwnerPolicy = 'Exact Android package main PID only; com.oculus.vrshell is excluded'
        MetricSource = "live logcat --pid=$initialPid, VrApi tag only"
        MetricSemantics = [ordered]@{
            AppFps = 'First FPS=x/y value: application-rendered FPS'
            DisplayRefreshHz = 'Second FPS=x/y value: current headset display refresh rate, not a target setting'
            Stale = 'Frames redisplayed in the past second because a new frame missed its compositor deadline'
            RefreshTransitionCorrelation = 'A transition sample is the first VrApi row whose displayed refresh differs from the preceding row'
            PerformanceLevelPercent = 'CPU/GPU level percentages use all PID-owned VrApi FPS samples; missing level telemetry does not count as level 4'
        }
        Aggregate = $aggregate
        ExternalProcessGuard = $processGuardReport
        ValidForComparison = ($invalidReasons.Count -eq 0)
        InvalidReasons = $invalidReasons.ToArray()
        RawLogsPersisted = $false
        RawProcessRowsPersisted = $false
    }

    $result = [pscustomobject]$summary
    if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
        $savedPath = Save-AggregateJson -Summary $result -Path $OutputJson
        $result | Add-Member -NotePropertyName AggregateJsonPath -NotePropertyValue $savedPath
    }
    return $result
}

if ($Action -eq 'SelfTest') {
    Invoke-SelfTest
    exit 0
}

$script:ResolvedAdb = Resolve-Adb
$script:ResolvedSerial = Resolve-DeviceSerial
Assert-DeviceReady
Measure-PidScopedVrApi
