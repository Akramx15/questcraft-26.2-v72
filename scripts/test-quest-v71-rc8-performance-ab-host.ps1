#requires -Version 7.0
<# Host-only regression suite. All transport tests use an explicit fake ADB. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[RC8_PERF_AB_HOST_TEST] $Message" }
}

function Invoke-ExpectedFailure([scriptblock] $Operation, [string] $Pattern) {
    try { & $Operation; return $false } catch {
        return $_.Exception.Message -match $Pattern
    }
}

$sourceGate = Join-Path $PSScriptRoot 'quest-v71-rc8-performance-ab.ps1'
$sourceBenchmark = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$sourceLock = Join-Path (Split-Path -Parent $PSScriptRoot) 'V71_LAB_RC8.lock.json'
foreach ($path in @($sourceGate, $sourceBenchmark, $sourceLock)) {
    Require (Test-Path -LiteralPath $path -PathType Leaf) "Missing Host source: $path"
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourceGate, [ref]$tokens, [ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected the performance gate.'
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($required in @(
    'Action','Serial','AdbPath','Seconds','SequenceIndex','Condition',
    'DeclaredRenderScale','ExpectedCpuLevel','ExpectedGpuLevel',
    'OutputDirectory','InputDirectory','OutputJson',
    'AllowDeviceRead','ConfirmExactRc8Lab','AllowHostOutput')) {
    Require ($parameters -ccontains $required) "Missing parameter: $required"
}
foreach ($forbidden in @(
    'Package','StablePackage','Profile','CorePath','VeqPath','ConfigPath',
    'ApkSha256','SignerSha256','Install','Launch','Stop','Root')) {
    Require ($parameters -cnotcontains $forbidden) `
        "A fixed boundary is externally overrideable: $forbidden"
}

$source = [IO.File]::ReadAllText($sourceGate)
Require ($source.Contains("[string] `$Action = 'SelfTest'") -and
        $source.Contains("[ValidateSet('SelfTest', 'Status', 'Capture', 'Analyze')]")) `
    'SelfTest is not the fixed default.'
Require ($source.Contains("`$script:Package = 'com.qcxr.qcxr.canary262'") -and
        $source.Contains("`$script:StablePackage = 'com.qcxr.qcxr.dev262'")) `
    'The Lab allow pin or Stable deny pin is missing.'
Require ($source.Contains('-Package $script:Package') -and
        $source.Contains('-DynamicRefresh')) `
    'The child benchmark is not explicitly Lab/Dynamic.'
Require ($source.Contains("`$script:Order = @('A', 'B', 'B', 'A', 'A', 'B')")) `
    'The counterbalanced order drifted.'
Require ($source.Contains('RefreshMetricStrata') -and
        $source.Contains('MinimumOverlapSamplesPerPair') -and
        $source.Contains('MaximumStartTemperatureDeltaC')) `
    'Matched refresh or thermal gates are absent.'

$stringConstants = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst]
}, $true) | ForEach-Object { [string]$_.Value })
foreach ($forbiddenCommand in @(
    'install','install-multiple','uninstall','clear','force-stop','start',
    'start-activity','push','pull','mv','rm','su','root','reboot','remount')) {
    Require ($stringConstants -cnotcontains $forbiddenCommand) `
        "A forbidden device command literal exists: $forbiddenCommand"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('qc-rc8-perf-ab-host-' + [Guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$scripts = Join-Path $repo 'scripts'
[IO.Directory]::CreateDirectory($scripts) | Out-Null
[IO.File]::Copy($sourceGate, (Join-Path $scripts ([IO.Path]::GetFileName($sourceGate))))
[IO.File]::Copy($sourceBenchmark, (Join-Path $scripts ([IO.Path]::GetFileName($sourceBenchmark))))
[IO.File]::Copy($sourceLock, (Join-Path $repo 'V71_LAB_RC8.lock.json'))
$gate = Join-Path $scripts 'quest-v71-rc8-performance-ab.ps1'
$benchmark = Join-Path $scripts 'quest-vrapi-pid-benchmark.ps1'
$fakePs1 = Join-Path $testRoot 'fake-adb.ps1'
$fakeCmd = Join-Path $testRoot 'fake-adb.cmd'
$callDir = Join-Path $testRoot 'calls'
$stable = 'com.qcxr.qcxr.dev262'
[IO.Directory]::CreateDirectory($callDir) | Out-Null

$fakeSource = @'
$ErrorActionPreference = 'Stop'
$FakeArgs = [string[]]@($env:QC_PA_ARGS -split ' ' | Where-Object { $_.Length -gt 0 })
$call = Join-Path $env:QC_PA_CALL_DIR (([Guid]::NewGuid().ToString('N')) + '.json')
[IO.File]::WriteAllText($call,
    (([ordered]@{ argv=@($FakeArgs) }) | ConvertTo-Json -Compress),
    [Text.UTF8Encoding]::new($false))
$scenario = [string]$env:QC_PA_SCENARIO
$lab = 'com.qcxr.qcxr.canary262'
$stable = 'com.qcxr.qcxr.dev262'
$base = '/data/app/~~TEST/' + $lab + '-TEST/base.apk'
$game = '/sdcard/Android/data/' + $lab + '/files/instances/26.2'
$core = $game + '/mods/Vivecraft.jar'
$veq = $game + '/mods/Vivecraft-Essentials-Quest.jar'
$config = $game + '/config/vivecraft-client-config.json'
$apkSha = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$coreSha = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$veqSha = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'

if ($FakeArgs.Count -eq 1 -and $FakeArgs[0] -ceq 'devices') {
    'List of devices attached'; "QUEST_PERF`tdevice product:fake"; exit 0
}
if ($FakeArgs.Count -eq 3 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_PERF' -and $FakeArgs[2] -ceq 'get-state') {
    'device'; exit 0
}
if ($FakeArgs.Count -lt 4 -or $FakeArgs[0] -cne '-s' -or
    $FakeArgs[1] -cne 'QUEST_PERF' -or $FakeArgs[2] -cne 'shell') {
    Write-Error ('Unexpected prefix: ' + ($FakeArgs -join '|')); exit 90
}
$a = @($FakeArgs[3..($FakeArgs.Count-1)])
if ($a[0] -ceq 'pidof' -and $a[1] -ceq $stable) {
    if ($scenario -ceq 'stable-running') { '999'; exit 0 }
    exit 1
}
if ($a[0] -ceq 'pidof' -and $a[1] -ceq $lab) { '1234'; exit 0 }
if ($a[0] -ceq 'dumpsys' -and $a[1] -ceq 'package') {
    if ($scenario -ceq 'wrong-version') {
        '  versionCode=72 minSdk=29 targetSdk=34'
    } else { '  versionCode=71 minSdk=29 targetSdk=34' }
    '  versionName=6.0.1-26.2-vivecraft-personal.12-rc.8'; exit 0
}
if ($a[0] -ceq 'pm' -and $a[1] -ceq 'path') { 'package:' + $base; exit 0 }
if ($a[0] -ceq 'sha256sum') {
    $path = [string]$a[1]
    $sha = if ($path -ceq $base) {
        if ($scenario -ceq 'wrong-apk') { '0' * 64 } else { $apkSha }
    } elseif ($path -ceq $core) {
        if ($scenario -ceq 'wrong-core') { '0' * 64 } else { $coreSha }
    } elseif ($path -ceq $veq) {
        if ($scenario -ceq 'wrong-veq') { '0' * 64 } else { $veqSha }
    } else {
        Write-Error ('Unexpected sha path: ' + $path); exit 91
    }
    $sha.ToLowerInvariant() + '  ' + $path; exit 0
}
if ($a[0] -ceq 'cat' -and $a[1] -ceq $config) {
    $scale = if ($scenario -ceq 'scale-08') { '0.8' } else { '1.0' }
    '{"renderScaleFactor":"' + $scale + '","untouched":true}'; exit 0
}
if ($a[0] -ceq 'dumpsys' -and $a[1] -ceq 'activity') {
    'topResumedActivity=ActivityRecord{1 u0 ' + $lab + '/.MainActivity t1}'; exit 0
}
if ($a[0] -ceq 'ps') {
    'PID PPID NAME CMD'; '1 0 init /system/bin/init'; exit 0
}
if ($a[0] -ceq 'timeout' -and $a[2] -ceq 'logcat') {
    for ($i=1; $i -le 10; $i++) {
        $hz = @(72,80,90)[$i % 3]
        $fps = $hz - 2
        $stale = $i % 2
        $temp = 42.0 + (($i % 3) * 0.1)
        $cpuLevel = if ($scenario -ceq 'levels-87') { 8 } else { 4 }
        $gpuLevel = if ($scenario -ceq 'levels-87') { 7 } else { 4 }
        ('09-07 12:00:{0:D2}.000 1234 100 I VrApi   : FPS={1}/{2},Prd=39ms,Tear=0,Early=0,Stale={3},Stale2/5/10/max=0/0/0/1,VSnc=1,Lat=-4,Free=3000MB,Temp={4:0.0}C/0.0C,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12),CPU4/GPU={5}/{6}' -f $i,$fps,$hz,$stale,$temp,$cpuLevel,$gpuLevel)
    }
    Start-Sleep -Milliseconds 2400
    exit 0
}
Write-Error ('Unexpected command: ' + ($a -join '|')); exit 92
'@
[IO.File]::WriteAllText($fakePs1, $fakeSource, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($fakeCmd,
    "@echo off`r`nset `"QC_PA_ARGS=%*`"`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-adb.ps1`"`r`nexit /b %ERRORLEVEL%`r`n",
    [Text.Encoding]::ASCII)

$previousCallDir = $env:QC_PA_CALL_DIR
$previousScenario = $env:QC_PA_SCENARIO
try {
    $env:QC_PA_CALL_DIR = $callDir
    $env:QC_PA_SCENARIO = 'exact'

    $before = @(Get-ChildItem -LiteralPath $callDir -File).Count
    $self = & $gate
    Require ($self.Result -ceq 'PASS' -and $self.DeviceInvocations -eq 0) `
        'Default SelfTest failed or reported a device call.'
    $status = & $gate -Action Status
    Require ($status.HostOnly -and $status.DeviceInvocations -eq 0) `
        'Host Status touched the device.'
    $after = @(Get-ChildItem -LiteralPath $callDir -File).Count
    Require ($before -eq $after) 'Default SelfTest/Status invoked fake ADB.'

    $benchSelf = & $benchmark -Action SelfTest
    Require ($benchSelf.Result -ceq 'PASS') 'Child aggregate benchmark SelfTest failed.'

    $analysisRelative = 'artifacts/v71-rc8-performance-ab/fake-analysis'
    $analysisDirectory = Join-Path $repo $analysisRelative
    [IO.Directory]::CreateDirectory($analysisDirectory) | Out-Null
    $order = @('A','B','B','A','A','B')
    for ($index = 1; $index -le 6; $index++) {
        $condition = $order[$index - 1]
        $isB = $condition -ceq 'B'
        $strata = @(72.0,80.0,90.0) | ForEach-Object {
            [pscustomobject]@{
                Hz=$_; Samples=20
                MeanAppFps=if ($isB) { $_ * 0.99 } else { $_ * 0.98 }
                P10AppFps=if ($isB) { $_ * 0.96 } else { $_ * 0.95 }
                MeanStalePerSecond=if ($isB) { 1.0 } else { 1.3 }
                P95CpuAndGpuMs=if ($isB) { 12.4 } else { 13.0 }
                MeanTempC=42.0 + (($index % 2) * 0.1)
            }
        }
        $receipt = [pscustomobject][ordered]@{
            schemaVersion=2
            receiptType='V71_RC8_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE'
            sequenceIndex=$index; condition=$condition
            renderScaleFactor=if ($isB) { '0.8' } else { '1.0' }
            refreshPolicy='Dynamic'; validForComparison=$true
            identityFence=[pscustomobject]@{
                exactBuildLock=$true; exactApk=$true
                signerBoundByExactApk=$true; exactCore=$true; exactVeq=$true
                stableStoppedAtBothFences=$true
            }
            benchmarkGate=[pscustomobject]@{
                expectedCpuLevel=4; expectedGpuLevel=4
                cpuExpectedLevelPercent=100.0; gpuExpectedLevelPercent=100.0
            }
            aggregate=[pscustomobject]@{
                VrApiSamples=60; FirstTempC=42.0
                RefreshMetricStrata=$strata
            }
        }
        $path = Join-Path $analysisDirectory ('{0:D2}-{1}.json' -f $index,$condition)
        [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12),
            [Text.UTF8Encoding]::new($false))
    }
    $analysis = & $gate -Action Analyze -InputDirectory $analysisRelative
    Require ($analysis.result -ceq 'PERFORMANCE_CANDIDATE' -and
            $analysis.allPairsComparable -and
            [string]$analysis.pairs[0].Order -ceq 'AB' -and
            [string]$analysis.pairs[1].Order -ceq 'BA' -and
            [string]$analysis.pairs[2].Order -ceq 'AB' -and
            -not $analysis.gates.stablePromotionAllowed) `
        'External Host analyzer did not enforce matched AB/BA/AB evidence.'

    $mixedPath = Join-Path $analysisDirectory '06-B.json'
    $mixedReceipt = Get-Content -Raw -LiteralPath $mixedPath | ConvertFrom-Json -Depth 20
    $mixedReceipt.benchmarkGate.expectedGpuLevel = 7
    [IO.File]::WriteAllText($mixedPath, ($mixedReceipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    Require (Invoke-ExpectedFailure {
        & $gate -Action Analyze -InputDirectory $analysisRelative | Out-Null
    } 'same declared CPU/GPU performance levels') `
        'Analyzer accepted receipts captured at mixed performance levels.'
    $mixedReceipt.benchmarkGate.expectedGpuLevel = 4
    [IO.File]::WriteAllText($mixedPath, ($mixedReceipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))

    $captureDir = 'artifacts/v71-rc8-performance-ab/fake-capture'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -OutputDirectory $captureDir `
            -Serial QUEST_PERF -AdbPath $fakeCmd | Out-Null
    } 'requires -AllowDeviceRead') 'Capture was allowed without consent.'

    $capture = & $gate -Action Capture -SequenceIndex 1 -Condition A `
        -DeclaredRenderScale 1.0 -OutputDirectory $captureDir `
        -Seconds 10 -Serial QUEST_PERF -AdbPath $fakeCmd `
        -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput
    Require ($capture.Result -ceq 'PASS' -and $capture.DeviceWrites -eq 0 -and
            $capture.RefreshPolicy -ceq 'Dynamic') 'Fake-ADB Capture failed.'
    $capturePath = Join-Path $repo "$captureDir/01-A.json"
    Require (Test-Path -LiteralPath $capturePath -PathType Leaf) `
        'Capture receipt was not published.'
    $captured = Get-Content -Raw -LiteralPath $capturePath | ConvertFrom-Json -Depth 20
    Require (@($captured.aggregate.RefreshMetricStrata).Count -eq 3 -and
            $captured.identityFence.stableStoppedAtBothFences -and
            [int]$captured.benchmarkGate.expectedCpuLevel -eq 4 -and
            [int]$captured.benchmarkGate.expectedGpuLevel -eq 4) `
        'Capture omitted observed-refresh strata or identity fences.'
    Require (@(Get-ChildItem -LiteralPath (Split-Path -Parent $capturePath) -File |
        Where-Object { $_.Name -like '.vrapi-*' }).Count -eq 0) `
        'The temporary child aggregate was retained.'

    $capture87Dir = 'artifacts/v71-rc8-performance-ab/fake-capture-87'
    $env:QC_PA_SCENARIO = 'levels-87'
    $capture87 = & $gate -Action Capture -SequenceIndex 1 -Condition A `
        -DeclaredRenderScale 1.0 -ExpectedCpuLevel 8 -ExpectedGpuLevel 7 `
        -OutputDirectory $capture87Dir -Seconds 10 -Serial QUEST_PERF `
        -AdbPath $fakeCmd -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput
    Require ($capture87.Result -ceq 'PASS') `
        'Capture rejected an explicitly declared and fully covered 8/7 run.'
    $capture87Path = Join-Path $repo "$capture87Dir/01-A.json"
    $captured87 = Get-Content -Raw -LiteralPath $capture87Path | ConvertFrom-Json -Depth 20
    Require ([int]$captured87.benchmarkGate.expectedCpuLevel -eq 8 -and
            [int]$captured87.benchmarkGate.expectedGpuLevel -eq 7 -and
            [double]$captured87.benchmarkGate.cpuExpectedLevelPercent -eq 100.0 -and
            [double]$captured87.benchmarkGate.gpuExpectedLevelPercent -eq 100.0) `
        'The explicit 8/7 performance-level evidence was not preserved.'

    $wrongLevelDir = 'artifacts/v71-rc8-performance-ab/fake-capture-wrong-level'
    $env:QC_PA_SCENARIO = 'exact'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -ExpectedCpuLevel 8 -ExpectedGpuLevel 7 `
            -OutputDirectory $wrongLevelDir -Seconds 10 -Serial QUEST_PERF `
            -AdbPath $fakeCmd -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'declared CPU/GPU levels 8/7') `
        'Capture accepted performance telemetry that did not match the declared levels.'

    $env:QC_PA_SCENARIO = 'stable-running'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 2 -Condition B `
            -DeclaredRenderScale 0.8 -OutputDirectory $captureDir `
            -Seconds 10 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'Stable must be conclusively stopped') `
        'A running Stable package passed preflight.'

    $env:QC_PA_SCENARIO = 'wrong-core'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 2 -Condition B `
            -DeclaredRenderScale 0.8 -OutputDirectory $captureDir `
            -Seconds 10 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'Persistent Core is not exact RC8') `
        'A wrong Core digest passed preflight.'

    foreach ($negative in @(
        [pscustomobject]@{ Scenario='wrong-version'; Pattern='not exact RC8 Lab' },
        [pscustomobject]@{ Scenario='wrong-apk'; Pattern='Installed APK is not exact RC8' },
        [pscustomobject]@{ Scenario='wrong-veq'; Pattern='Persistent VEQ is not exact RC8' },
        [pscustomobject]@{ Scenario='exact'; Pattern='live render scale does not match' }
    )) {
        $env:QC_PA_SCENARIO = $negative.Scenario
        Require (Invoke-ExpectedFailure {
            & $gate -Action Capture -SequenceIndex 2 -Condition B `
                -DeclaredRenderScale 0.8 -OutputDirectory $captureDir `
                -Seconds 10 -Serial QUEST_PERF -AdbPath $fakeCmd `
                -AllowDeviceRead -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
        } $negative.Pattern) "Identity/config scenario passed: $($negative.Scenario)"
    }

    $calls = @(Get-ChildItem -LiteralPath $callDir -File | ForEach-Object {
        Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
    })
    Require ($calls.Count -gt 0) 'Fake ADB was not exercised.'
    $forbidden = @('install','install-multiple','uninstall','clear','force-stop',
        'start','start-activity','push','pull','mv','rm','su','root','reboot','remount')
    foreach ($call in $calls) {
        foreach ($arg in @($call.argv)) {
            Require ([string]$arg -cnotin $forbidden) `
                "Fake ADB observed a forbidden command: $arg"
        }
        if (@($call.argv) -ccontains $stable) {
            Require (@($call.argv) -ccontains 'pidof') `
                'Stable was queried for anything other than stopped-state proof.'
        }
    }

    [pscustomobject][ordered]@{
        Result='PASS'; HostOnly=$true; FakeAdbInvocations=$calls.Count
        RealAdbInvocations=0; CaptureAggregateOnly=$true
        MatchedActualRefreshStrata=$true; CounterbalancedAnalyzer=$true
        StableMutation=$false; DeviceWrites=0; RawLogsPersisted=$false
    }
} finally {
    $env:QC_PA_CALL_DIR = $previousCallDir
    $env:QC_PA_SCENARIO = $previousScenario
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
