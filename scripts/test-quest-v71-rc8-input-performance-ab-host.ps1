#requires -Version 7.0
<# Host-only regression suite. All transport tests use an explicit fake ADB. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[RC8_INPUT_PERF_AB_HOST_TEST] $Message" }
}

function Invoke-ExpectedFailure([scriptblock] $Operation, [string] $Pattern) {
    try { & $Operation; return $false } catch {
        return $_.Exception.Message -match $Pattern
    }
}

function Get-TextSha256([string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
    } finally { $sha.Dispose() }
}

$sourceGate = Join-Path $PSScriptRoot 'quest-v71-rc8-input-performance-ab.ps1'
$sourceBenchmark = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$sourceWorldReset = Join-Path $PSScriptRoot 'quest-v71-rc8-benchmark-world-reset.ps1'
$sourceCanary = Join-Path $PSScriptRoot 'quest-v71-rc8-input-canary.ps1'
$sourceLock = Join-Path (Split-Path -Parent $PSScriptRoot) 'V71_LAB_RC8.lock.json'
$sourceInputLock = Join-Path (Split-Path -Parent $PSScriptRoot) 'RC8_INPUT_AB.lock.json'
foreach ($path in @($sourceGate, $sourceBenchmark, $sourceWorldReset, $sourceCanary,
        $sourceLock, $sourceInputLock)) {
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
    'AllowDeviceRead','ConfirmExactRc8Lab','ConfirmQgoDynamic','AllowRootFallback',
    'AllowHostOutput')) {
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
        $source.Contains("[ValidateSet('SelfTest', 'Status', 'Capture', 'Finalize', 'Analyze')]")) `
    'SelfTest is not the fixed default.'
Require ($source.Contains("`$script:Package = 'com.qcxr.qcxr.canary262'") -and
        $source.Contains("`$script:StablePackage = 'com.qcxr.qcxr.dev262'")) `
    'The Lab allow pin or Stable deny pin is missing.'
Require ($source.Contains('-Package $script:Package') -and
        $source.Contains('-DynamicRefresh')) `
    'The child benchmark is not explicitly Lab/Dynamic.'
Require ($source.Contains("`$script:Order = @('A', 'B', 'B', 'A', 'A', 'B')")) `
    'The counterbalanced order drifted.'
Require ($source.Contains("`$script:CandidateCoreSha256 = '9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD'") -and
        $source.Contains("`$script:BaselineCoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'")) `
    'The exact baseline/candidate Core pair is not pinned.'
Require ($source.Contains("[string] `$Serial = ''") -and
        $source.Contains('explicit USB ADB serial')) `
    'Explicit USB selection is not fail-closed.'
Require ($source.Contains("openXrCopyBatchMode = 'OFF'") -and
        $source.Contains("renderScaleFactor = '1.0'")) `
    'The one-variable render-scale/copy-batch isolation is absent.'
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
    'start-activity','push','pull','mv','rm','reboot','remount')) {
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
[IO.File]::Copy($sourceWorldReset, (Join-Path $scripts ([IO.Path]::GetFileName($sourceWorldReset))))
[IO.File]::Copy($sourceCanary, (Join-Path $scripts ([IO.Path]::GetFileName($sourceCanary))))
[IO.File]::Copy($sourceLock, (Join-Path $repo 'V71_LAB_RC8.lock.json'))
[IO.File]::Copy($sourceInputLock, (Join-Path $repo 'RC8_INPUT_AB.lock.json'))
$gate = Join-Path $scripts 'quest-v71-rc8-input-performance-ab.ps1'
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
$marker = $game + '/.questcraft/questcraft-vivecraft-core-canary-v9/request.json'
$apkSha = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$baselineSha = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$candidateSha = '9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD'
$veqSha = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'

if ($FakeArgs.Count -eq 2 -and $FakeArgs[0] -ceq 'devices' -and
    $FakeArgs[1] -ceq '-l') {
    'List of devices attached'; "QUEST_PERF`tdevice usb:1-2 product:fake"; exit 0
}
if ($FakeArgs.Count -eq 3 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_PERF') {
    if ($FakeArgs[2] -ceq 'get-state') { 'device'; exit 0 }
    if ($FakeArgs[2] -ceq 'get-devpath') { 'usb:1-2'; exit 0 }
}
if ($FakeArgs.Count -lt 4 -or $FakeArgs[0] -cne '-s' -or
    $FakeArgs[1] -cne 'QUEST_PERF' -or $FakeArgs[2] -cne 'shell') {
    Write-Error ('Unexpected prefix: ' + ($FakeArgs -join '|')); exit 90
}
$a = @($FakeArgs[3..($FakeArgs.Count-1)])
if ($a[0] -ceq 'pidof' -and $a[1] -ceq $stable) {
    if ($scenario -ceq 'stable-mid') {
        $counterPath = Join-Path $env:QC_PA_CALL_DIR 'stable-counter.txt'
        $count = if (Test-Path -LiteralPath $counterPath) {
            [int](Get-Content -Raw -LiteralPath $counterPath)
        } else { 0 }
        $count++
        [IO.File]::WriteAllText($counterPath, [string]$count)
        if ($count -eq 3) { '999'; exit 0 }
    }
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
        if ($scenario -ceq 'wrong-core') {
            '0' * 64
        } elseif ($scenario -like 'candidate*') {
            $candidateSha
        } else {
            $baselineSha
        }
    } elseif ($path -ceq $veq) {
        if ($scenario -ceq 'wrong-veq') { '0' * 64 } else { $veqSha }
    } else {
        Write-Error ('Unexpected sha path: ' + $path); exit 91
    }
    $sha.ToLowerInvariant() + '  ' + $path; exit 0
}
if ($a[0] -ceq 'cat' -and $a[1] -ceq $config) {
    $scale = if ($scenario -ceq 'wrong-scale') { '0.8' } else { '1.0' }
    '{"renderScaleFactor":"' + $scale + '","untouched":true}'; exit 0
}
if ($a[0] -ceq 'test' -and $a.Count -eq 4 -and $a[1] -ceq '!' -and
    $a[2] -ceq '-e' -and $a[3] -ceq $marker) {
    if ($scenario -like 'candidate*') { exit 1 }
    exit 0
}
if ($a[0] -ceq 'test' -and $a.Count -eq 4 -and $a[1] -ceq '!' -and
    $a[2] -ceq '-L' -and $a[3] -ceq $marker) {
    if ($scenario -ceq 'marker-symlink') { exit 1 }
    exit 0
}
if ($a[0] -ceq 'stat' -and $a.Count -eq 4 -and $a[1] -ceq '-c' -and
    $a[2] -ceq '%s' -and $a[3] -ceq $marker) {
    if ($scenario -notlike 'candidate*') { exit 1 }
    '1024'; exit 0
}
if ($a[0] -ceq 'cat' -and $a[1] -ceq $marker) {
    if ($scenario -notlike 'candidate*') { exit 1 }
    $copyMode = if ($scenario -ceq 'candidate-copy-on') { 'ON' } else { 'OFF' }
    [ordered]@{
        schemaVersion=2; harnessId='questcraft-vivecraft-core-canary-v9'; state='consumed'
        packageName=$lab; profile='26.2'; target='mods/Vivecraft.jar'
        runId='0123456789abcdef0123456789abcdef'; baselineSha256=$baselineSha
        baselineSizeBytes=10078822; candidateSha256=$candidateSha
        candidateSizeBytes=10085812; fabricId='vivecraft'
        fabricVersion='26.2-1.3.15+qc.v71.rc8-input.1'
        minecraftDependency='26.2.x'; javaDependency='>=25'
        otherModsFingerprintSha256=('1' * 64); openXrCopyBatchMode=$copyMode
        expiresAtEpochMs=1999999999999; maxLaunches=1
    } | ConvertTo-Json -Compress
    exit 0
}
if ($a[0] -ceq 'cat' -and $a[1] -ceq '/proc/1234/stat') {
    $ticks = if ($scenario -like 'candidate*') { 223456 } else { 123456 }
    '1234 (com.qcxr.qcxr.canary262) R 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 ' + $ticks + ' 20 21'
    exit 0
}
if ($a[0] -ceq 'getconf' -and $a[1] -ceq 'CLK_TCK') { '100'; exit 0 }
if ($a[0] -ceq 'cat' -and $a[1] -ceq '/proc/uptime') {
    $uptime = if ($scenario -like 'candidate*') { '2594.56' } else { '1594.56' }
    $uptime + ' 1000.00'; exit 0
}
if (($a[0] -ceq 'sh' -or $a[0] -ceq 'su') -and $a[1] -ceq '-c') {
    "FINGERPRINT`t$('1' * 64)"; exit 0
}
if ($a[0] -ceq 'dumpsys' -and $a[1] -ceq 'activity') {
    'topResumedActivity=ActivityRecord{1 u0 ' + $lab + '/.MainActivity t1}'; exit 0
}
if ($a[0] -ceq 'ps') {
    'PID PPID NAME CMD'; '1 0 init /system/bin/init'; exit 0
}
if ($a[0] -ceq 'timeout' -and $a[2] -ceq 'logcat') {
    for ($i=1; $i -le 120; $i++) {
        $stamp = $i % 60
        $hz = @(72,80,90)[$i % 3]
        $fps = $hz - 2
        $stale = $i % 2
        $temp = 42.0 + (($i % 3) * 0.1)
        $cpuLevel = if ($scenario -ceq 'levels-44') { 4 } else { 8 }
        $gpuLevel = if ($scenario -ceq 'levels-44') { 4 } else { 7 }
        ('09-07 12:00:{0:D2}.000 1234 100 I VrApi   : FPS={1}/{2},Prd=39ms,Tear=0,Early=0,Stale={3},Stale2/5/10/max=0/0/0/1,VSnc=1,Lat=-4,Free=3000MB,Temp={4:0.0}C/0.0C,App=12.00ms,CPU&GPU=13.00ms,GPU%=0.78,CPU%=0.57(W12),CPU4/GPU={5}/{6}' -f $stamp,$fps,$hz,$stale,$temp,$cpuLevel,$gpuLevel)
    }
    Start-Sleep -Milliseconds 1200
    exit 0
}
Write-Error ('Unexpected command: ' + ($a -join '|')); exit 92
'@
[IO.File]::WriteAllText($fakePs1, $fakeSource, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($fakeCmd,
    "@echo off`r`nset `"QC_PA_ARGS=%*`"`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-adb.ps1`"`r`nexit /b %ERRORLEVEL%`r`n",
    [Text.Encoding]::ASCII)

function Get-NormalizedTextSha256([string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-TextSha256 $text
}

$resetProducerSha256 = Get-NormalizedTextSha256 `
    (Join-Path $scripts 'quest-v71-rc8-benchmark-world-reset.ps1')
$worldMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$worldLevelSha256 = '42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065'

function Write-FakeResetReceipt(
    [string] $RelativeDirectory,
    [int] $Index,
    [DateTimeOffset] $CompletedAt,
    [string] $RunId = ''
) {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [Guid]::NewGuid().ToString('N')
    }
    $directory = Join-Path $repo $RelativeDirectory
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $deviceBinding = Get-TextSha256 (
        "rc8-world-reset-v1`nserial=QUEST_PERF`nrunId=$RunId`nmaster=$worldMasterSha256")
    $receipt = [pscustomobject][ordered]@{
        schemaVersion=1
        receiptType='V71_RC8_INPUT_PERFORMANCE_WORLD_RESET'
        result='RESET'
        resetRunId=$RunId
        completedAtUtc=$CompletedAt.ToString('o')
        resetProducerSha256=$resetProducerSha256
        deviceBindingSha256=$deviceBinding
        package='com.qcxr.qcxr.canary262'
        profile='26.2'
        world='FPS-Stress-Test'
        exactRc8Identity=$true
        apkSha256='A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
        coreSha256='ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
        veqSha256='FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
        masterSha256=$worldMasterSha256
        worldLevelDatSha256=$worldLevelSha256
        worldResetActivationReceipt="QC_RC8_WORLD_RESET:PASS:${worldLevelSha256}:100:26"
        originalSnapshotState='SNAPSHOT'
        originalSnapshotSha256=('B' * 64)
        masterCache='VERIFIED'
        stableStoppedAtAllFences=$true
        labStoppedAtAllFences=$true
        backupVerifiedBeforeSwap=$true
        canaryMarkerAbsent=$true
        usbTransportConfirmed=$true
        accessMode='Normal'
        rootUsed=$false
        serialPersisted=$false
        deviceWrites=1
    }
    $path = Join-Path $directory ('reset-{0:D2}.json' -f $Index)
    [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Path=$path; Receipt=$receipt; RunId=$RunId }
}

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

    $analysisRelative = 'artifacts/v71-rc8-input-performance-ab/fake-analysis'
    $analysisDirectory = Join-Path $repo $analysisRelative
    [IO.Directory]::CreateDirectory($analysisDirectory) | Out-Null
    $order = @('A','B','B','A','A','B')
    $campaignId = 'a' * 32
    $campaignDeviceBinding = 'D' * 64
    $otherModsFingerprint = '1' * 64
    $analysisBase = [DateTimeOffset]'2026-09-08T00:00:00.0000000+00:00'
    $previousReceiptHash = $null
    for ($index = 1; $index -le 6; $index++) {
        $resetAt = $analysisBase.AddMinutes(($index - 1) * 10)
        $reset = Write-FakeResetReceipt -RelativeDirectory $analysisRelative `
            -Index $index -CompletedAt $resetAt -RunId ((100 + $index).ToString('x32'))
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
                TemperatureSampleCount=20
                TemperatureCoveragePercent=100.0
            }
        }
        $receipt = [pscustomobject][ordered]@{
            schemaVersion=4
            receiptType='V71_RC8_INPUT_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE'
            sequenceIndex=$index; condition=$condition
            campaignId=$campaignId
            captureId=$index.ToString('x32')
            capturedAtUtc=$resetAt.AddMinutes(6).ToString('o')
            previousReceiptSha256=$previousReceiptHash
            deviceBindingSha256=$campaignDeviceBinding
            worldResetReceiptSha256=(Get-FileHash -LiteralPath $reset.Path -Algorithm SHA256).Hash
            worldResetRunId=$reset.RunId
            worldResetCompletedAtUtc=$resetAt.ToString('o')
            warmupSecondsObserved=360.0
            renderScaleFactor='1.0'; openXrCopyBatchMode='OFF'
            refreshPolicy='Dynamic'; qgoDynamicConfirmed=$true
            durationSeconds=180; validForComparison=$true
            identityFence=[pscustomobject]@{
                exactBuildLock=$true; exactInputLock=$true; exactApk=$true
                signerBoundByExactApk=$true; exactCore=$true; exactVeq=$true
                stableStoppedAtBothFences=$true
                stableStoppedThroughout=$true
                renderScaleOneAtBothFences=$true; copyBatchOffAtBothFences=$true
                sameProcessAtBothFences=$true; explicitUsbTransport=$true
                coreSha256=if ($isB) {
                    '9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD'
                } else {
                    'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
                }
                coreVersion=if ($isB) {
                    '26.2-1.3.15+qc.v71.rc8-input.1'
                } else {
                    '26.2-1.3.15+qc.v71.rc8-mining'
                }
                markerState=if ($isB) { 'consumed' } else { 'absent' }
                markerRunId=if ($isB) { $index.ToString('x32') } else { $null }
                processTokenSha256=(Get-TextSha256 "fake-process-$index")
                otherModsFingerprintSha256=$otherModsFingerprint
                readAccessMode='Normal'
            }
            benchmarkGate=[pscustomobject]@{
                expectedCpuLevel=8; expectedGpuLevel=7
                cpuExpectedLevelPercent=100.0; gpuExpectedLevelPercent=100.0
                exactPid=$true; focusPercent=100.0
                polls=180; stableKnownPolls=180; stableStoppedPolls=180
                stablePollErrors=0; stableStoppedAtStart=$true
                stableStoppedAtEnd=$true
            }
            aggregate=[pscustomobject]@{
                VrApiSamples=60; FirstTempC=42.0
                TemperatureSampleCount=60; TemperatureCoveragePercent=100.0
                RefreshMetricStrata=$strata
            }
        }
        $path = Join-Path $analysisDirectory ('{0:D2}-{1}.json' -f $index,$condition)
        [IO.File]::WriteAllText($path, ($receipt | ConvertTo-Json -Depth 12),
            [Text.UTF8Encoding]::new($false))
        $previousReceiptHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $finalRollbackPath = Join-Path $analysisDirectory '07-final-rollback.json'
    $finalRollback = [pscustomobject][ordered]@{
        schemaVersion=1
        receiptType='V71_RC8_INPUT_PERFORMANCE_FINAL_ROLLBACK'
        finalizeId='f' * 32
        completedAtUtc=$analysisBase.AddMinutes(56.5).ToString('o')
        campaignId=$campaignId
        previousReceiptSha256=$previousReceiptHash
        deviceBindingSha256=$campaignDeviceBinding
        rolledBackCandidateRunId=(6).ToString('x32')
        otherModsFingerprintSha256=$otherModsFingerprint
        baselineCoreSha256='ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
        baselineCoreVersion='26.2-1.3.15+qc.v71.rc8-mining'
        apkSha256='A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
        veqSha256='FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
        markerState='absent'; readAccessMode='Normal'
        exactBaseline=$true; markerAbsent=$true
        stableStoppedAtBothFences=$true; labStoppedAtBothFences=$true
        renderScaleOne=$true; explicitUsbTransport=$true
    }
    [IO.File]::WriteAllText($finalRollbackPath,
        ($finalRollback | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $analysis = & $gate -Action Analyze -InputDirectory $analysisRelative
    Require ($analysis.result -ceq 'PERFORMANCE_CANDIDATE' -and
            $analysis.allPairsComparable -and
            [string]$analysis.pairs[0].Order -ceq 'AB' -and
            [string]$analysis.pairs[1].Order -ceq 'BA' -and
            [string]$analysis.pairs[2].Order -ceq 'AB' -and
            -not $analysis.gates.stablePromotionAllowed) `
        'External Host analyzer did not enforce matched AB/BA/AB evidence.'

    $mixedPath = Join-Path $analysisDirectory '06-B.json'
    $mixedReceipt = Get-Content -Raw -LiteralPath $mixedPath |
        ConvertFrom-Json -Depth 20 -DateKind String
    $mixedReceipt.benchmarkGate.expectedGpuLevel = 4
    [IO.File]::WriteAllText($mixedPath, ($mixedReceipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    $finalRollback.previousReceiptSha256 =
        (Get-FileHash -LiteralPath $mixedPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($finalRollbackPath,
        ($finalRollback | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Require (Invoke-ExpectedFailure {
        & $gate -Action Analyze -InputDirectory $analysisRelative | Out-Null
    } 'same declared CPU/GPU performance levels') `
        'Analyzer accepted receipts captured at mixed performance levels.'
    $mixedReceipt.benchmarkGate.expectedGpuLevel = 7
    [IO.File]::WriteAllText($mixedPath, ($mixedReceipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    $finalRollback.previousReceiptSha256 =
        (Get-FileHash -LiteralPath $mixedPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($finalRollbackPath,
        ($finalRollback | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    $strictReceipt = Get-Content -Raw -LiteralPath $mixedPath |
        ConvertFrom-Json -Depth 20 -DateKind String
    $strictReceipt.identityFence.exactCore = 'false'
    [IO.File]::WriteAllText($mixedPath, ($strictReceipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    $finalRollback.previousReceiptSha256 =
        (Get-FileHash -LiteralPath $mixedPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($finalRollbackPath,
        ($finalRollback | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Require (Invoke-ExpectedFailure {
        & $gate -Action Analyze -InputDirectory $analysisRelative | Out-Null
    } 'must be a JSON boolean') 'Analyzer accepted the JSON string "false" as true.'
    $strictReceipt.identityFence.exactCore = $true
    [IO.File]::WriteAllText($mixedPath, ($strictReceipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    $finalRollback.previousReceiptSha256 =
        (Get-FileHash -LiteralPath $mixedPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($finalRollbackPath,
        ($finalRollback | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    Require (Invoke-ExpectedFailure {
        & $gate -Action Analyze -InputDirectory $analysisRelative `
            -MinimumOverlapPercentPerArm 10 | Out-Null
    } 'cannot be overridden') 'Analyzer allowed a relaxed acceptance threshold.'

    $captureDir = 'artifacts/v71-rc8-input-performance-ab/fake-capture'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -OutputDirectory $captureDir `
            -Serial QUEST_PERF -AdbPath $fakeCmd | Out-Null
    } 'requires -AllowDeviceRead') 'Capture was allowed without consent.'

    $null = Write-FakeResetReceipt -RelativeDirectory $captureDir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    $capture = & $gate -Action Capture -SequenceIndex 1 -Condition A `
        -DeclaredRenderScale 1.0 -OutputDirectory $captureDir `
        -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
        -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic -AllowHostOutput
    Require ($capture.Result -ceq 'PASS' -and $capture.DeviceWrites -eq 0 -and
            $capture.RefreshPolicy -ceq 'Dynamic') 'Fake-ADB Capture failed.'
    $capturePath = Join-Path $repo "$captureDir/01-A.json"
    Require (Test-Path -LiteralPath $capturePath -PathType Leaf) `
        'Capture receipt was not published.'
    $captured = Get-Content -Raw -LiteralPath $capturePath |
        ConvertFrom-Json -Depth 20 -DateKind String
    Require (@($captured.aggregate.RefreshMetricStrata).Count -eq 3 -and
            $captured.identityFence.stableStoppedAtBothFences -and
            $captured.identityFence.explicitUsbTransport -and
            $captured.identityFence.copyBatchOffAtBothFences -and
            [string]$captured.identityFence.coreSha256 -ceq
                'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB' -and
            [string]$captured.identityFence.processTokenSha256 -cmatch '^[0-9A-F]{64}$' -and
            [int]$captured.benchmarkGate.expectedCpuLevel -eq 8 -and
            [int]$captured.benchmarkGate.expectedGpuLevel -eq 7 -and
            [int]$captured.benchmarkGate.stableStoppedPolls -eq
                [int]$captured.benchmarkGate.polls) `
        'Capture omitted observed-refresh strata or identity fences.'
    Require (@(Get-ChildItem -LiteralPath (Split-Path -Parent $capturePath) -File |
        Where-Object { $_.Name -like '.vrapi-*' }).Count -eq 0) `
        'The temporary child aggregate was retained.'

    # Compress the five-minute inter-arm wait only inside this Host fixture by
    # rebasing already-produced timestamps and re-hashing the exact chain.
    $simulatedNow = [DateTimeOffset]::UtcNow
    $resetOnePath = Join-Path $repo "$captureDir/reset-01.json"
    $resetOne = Get-Content -Raw -LiteralPath $resetOnePath |
        ConvertFrom-Json -Depth 20 -DateKind String
    $resetOne.completedAtUtc = $simulatedNow.AddMinutes(-18).ToString('o')
    [IO.File]::WriteAllText($resetOnePath, ($resetOne | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
    $captured.capturedAtUtc = $simulatedNow.AddMinutes(-12).ToString('o')
    $captured.worldResetCompletedAtUtc = [string]$resetOne.completedAtUtc
    $captured.worldResetReceiptSha256 =
        (Get-FileHash -LiteralPath $resetOnePath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($capturePath, ($captured | ConvertTo-Json -Depth 20),
        [Text.UTF8Encoding]::new($false))
    $null = Write-FakeResetReceipt -RelativeDirectory $captureDir -Index 2 `
        -CompletedAt $simulatedNow.AddMinutes(-6)

    $env:QC_PA_SCENARIO = 'candidate'
    $captureB = & $gate -Action Capture -SequenceIndex 2 -Condition B `
        -DeclaredRenderScale 1.0 -OutputDirectory $captureDir `
        -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
        -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic -AllowHostOutput
    Require ($captureB.Result -ceq 'PASS' -and
            [string]$captureB.CoreSha256 -ceq
                '9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD') `
        'Exact candidate B capture failed.'
    $capturedB = Get-Content -Raw -LiteralPath (Join-Path $repo "$captureDir/02-B.json") |
        ConvertFrom-Json -Depth 20 -DateKind String
    Require ([string]$capturedB.identityFence.markerState -ceq 'consumed' -and
            [string]$capturedB.identityFence.markerRunId -ceq
                '0123456789abcdef0123456789abcdef' -and
            [string]$capturedB.openXrCopyBatchMode -ceq 'OFF') `
        'Candidate B receipt did not preserve the exact consumed OFF-mode transaction.'

    $capture87Dir = 'artifacts/v71-rc8-input-performance-ab/fake-capture-87'
    $env:QC_PA_SCENARIO = 'exact'
    $null = Write-FakeResetReceipt -RelativeDirectory $capture87Dir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    $capture87 = & $gate -Action Capture -SequenceIndex 1 -Condition A `
        -DeclaredRenderScale 1.0 -ExpectedCpuLevel 8 -ExpectedGpuLevel 7 `
        -OutputDirectory $capture87Dir -Seconds 180 -Serial QUEST_PERF `
        -AdbPath $fakeCmd -AllowDeviceRead -ConfirmExactRc8Lab `
        -ConfirmQgoDynamic -AllowHostOutput
    Require ($capture87.Result -ceq 'PASS') `
        'Capture rejected an explicitly declared and fully covered 8/7 run.'
    $capture87Path = Join-Path $repo "$capture87Dir/01-A.json"
    $captured87 = Get-Content -Raw -LiteralPath $capture87Path |
        ConvertFrom-Json -Depth 20 -DateKind String
    Require ([int]$captured87.benchmarkGate.expectedCpuLevel -eq 8 -and
            [int]$captured87.benchmarkGate.expectedGpuLevel -eq 7 -and
            [double]$captured87.benchmarkGate.cpuExpectedLevelPercent -eq 100.0 -and
            [double]$captured87.benchmarkGate.gpuExpectedLevelPercent -eq 100.0) `
        'The explicit 8/7 performance-level evidence was not preserved.'

    $wrongLevelDir = 'artifacts/v71-rc8-input-performance-ab/fake-capture-wrong-level'
    $env:QC_PA_SCENARIO = 'levels-44'
    $null = Write-FakeResetReceipt -RelativeDirectory $wrongLevelDir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -ExpectedCpuLevel 8 -ExpectedGpuLevel 7 `
            -OutputDirectory $wrongLevelDir -Seconds 180 -Serial QUEST_PERF `
            -AdbPath $fakeCmd -AllowDeviceRead -ConfirmExactRc8Lab `
            -ConfirmQgoDynamic -AllowHostOutput | Out-Null
    } 'declared CPU/GPU levels 8/7') `
        'Capture accepted performance telemetry that did not match the declared levels.'

    $stableRunningDir = 'artifacts/v71-rc8-input-performance-ab/negative-stable-running'
    $null = Write-FakeResetReceipt -RelativeDirectory $stableRunningDir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    $env:QC_PA_SCENARIO = 'stable-running'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -OutputDirectory $stableRunningDir `
            -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
            -AllowHostOutput | Out-Null
    } 'Stable must be conclusively stopped') `
        'A running Stable package passed preflight.'

    $stableMidDir = 'artifacts/v71-rc8-input-performance-ab/negative-stable-mid'
    $null = Write-FakeResetReceipt -RelativeDirectory $stableMidDir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    $stableCounter = Join-Path $callDir 'stable-counter.txt'
    if (Test-Path -LiteralPath $stableCounter) { [IO.File]::Delete($stableCounter) }
    $env:QC_PA_SCENARIO = 'stable-mid'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -OutputDirectory $stableMidDir `
            -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
            -AllowHostOutput | Out-Null
    } 'Forbidden-package|Stable was not conclusively stopped throughout') `
        'A Stable process observed during the timed window passed capture.'

    $wrongCoreDir = 'artifacts/v71-rc8-input-performance-ab/negative-wrong-core'
    $null = Write-FakeResetReceipt -RelativeDirectory $wrongCoreDir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    $env:QC_PA_SCENARIO = 'wrong-core'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -OutputDirectory $wrongCoreDir `
            -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
            -AllowHostOutput | Out-Null
    } 'Persistent Core is not exact condition A') `
        'A wrong Core digest passed preflight.'

    foreach ($negative in @(
        [pscustomobject]@{ Scenario='wrong-version'; Pattern='not exact RC8 Lab' },
        [pscustomobject]@{ Scenario='wrong-apk'; Pattern='Installed APK is not exact RC8' },
        [pscustomobject]@{ Scenario='wrong-veq'; Pattern='Persistent VEQ is not exact RC8' },
        [pscustomobject]@{ Scenario='wrong-scale'; Pattern='renderScaleFactor' }
    )) {
        $env:QC_PA_SCENARIO = $negative.Scenario
        $negativeDir = 'artifacts/v71-rc8-input-performance-ab/negative-' +
            $negative.Scenario
        $null = Write-FakeResetReceipt -RelativeDirectory $negativeDir -Index 1 `
            -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
        Require (Invoke-ExpectedFailure {
            & $gate -Action Capture -SequenceIndex 1 -Condition A `
                -DeclaredRenderScale 1.0 -OutputDirectory $negativeDir `
                -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
                -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
                -AllowHostOutput | Out-Null
        } $negative.Pattern) "Identity/config scenario passed: $($negative.Scenario)"
    }

    $copyOnDir = 'artifacts/v71-rc8-input-performance-ab/negative-copy-on'
    $copyOnAbsolute = Join-Path $repo $copyOnDir
    $null = Write-FakeResetReceipt -RelativeDirectory $copyOnDir -Index 2 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    [IO.File]::Copy($resetOnePath, (Join-Path $copyOnAbsolute 'reset-01.json'))
    [IO.File]::Copy($capturePath, (Join-Path $copyOnAbsolute '01-A.json'))
    $env:QC_PA_SCENARIO = 'candidate-copy-on'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 2 -Condition B `
            -DeclaredRenderScale 1.0 -OutputDirectory $copyOnDir `
            -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
            -AllowHostOutput | Out-Null
    } 'OFF-mode transaction') `
        'Candidate B with copy batching ON passed the one-variable fence.'

    $markerSymlinkDir = 'artifacts/v71-rc8-input-performance-ab/negative-marker-symlink'
    $null = Write-FakeResetReceipt -RelativeDirectory $markerSymlinkDir -Index 1 `
        -CompletedAt ([DateTimeOffset]::UtcNow.AddMinutes(-6))
    $env:QC_PA_SCENARIO = 'marker-symlink'
    Require (Invoke-ExpectedFailure {
        & $gate -Action Capture -SequenceIndex 1 -Condition A `
            -DeclaredRenderScale 1.0 -OutputDirectory $markerSymlinkDir `
            -Seconds 180 -Serial QUEST_PERF -AdbPath $fakeCmd `
            -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
            -AllowHostOutput | Out-Null
    } 'must not be a symbolic link') `
        'A symbolic-link transaction marker path passed the identity fence.'

    foreach ($invalidSerial in @('auto', '192.0.2.33:5555', 'adb-QUEST._adb-tls-connect._tcp')) {
        $env:QC_PA_SCENARIO = 'exact'
        Require (Invoke-ExpectedFailure {
            & $gate -Action Capture -SequenceIndex 1 -Condition A `
                -DeclaredRenderScale 1.0 -OutputDirectory `
                    ('artifacts/v71-rc8-input-performance-ab/negative-serial-' +
                        ([Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($invalidSerial)))) `
                -Seconds 180 -Serial $invalidSerial -AdbPath $fakeCmd `
                -AllowDeviceRead -ConfirmExactRc8Lab -ConfirmQgoDynamic `
                -AllowHostOutput | Out-Null
        } 'explicit.*USB|Cannot validate argument') `
            "Non-USB serial was accepted: $invalidSerial"
    }

    $calls = @(Get-ChildItem -LiteralPath $callDir -File -Filter '*.json' | ForEach-Object {
        Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
    })
    Require ($calls.Count -gt 0) 'Fake ADB was not exercised.'
    $forbidden = @('install','install-multiple','uninstall','clear','force-stop',
        'start','start-activity','push','pull','mv','rm','reboot','remount')
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
        ExplicitUsbRequired=$true; CopyBatchMode='OFF'; RenderScaleFactor='1.0'
        StableMidCaptureRaceRejected=$true; StrictJsonBooleans=$true
        FixedAcceptanceThresholds=$true; WorldResetHashChain=$true
        StableMutation=$false; DeviceWrites=0; RawLogsPersisted=$false
    }
} finally {
    $env:QC_PA_CALL_DIR = $previousCallDir
    $env:QC_PA_SCENARIO = $previousScenario
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
