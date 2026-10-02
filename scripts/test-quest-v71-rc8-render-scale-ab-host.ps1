#requires -Version 7.0
<# Host-only fake-ADB tests. This file never resolves or calls real ADB. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[RC8_RENDER_SCALE_AB_HOST_TEST] $Message" }
}

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock] $Operation, [string] $Pattern = '')
    try {
        & $Operation
        return $false
    } catch {
        if ([string]::IsNullOrWhiteSpace($Pattern)) { return $true }
        return $_.Exception.Message -match $Pattern
    }
}

function Get-ExpectedFailureMessage {
    param([Parameter(Mandatory)][scriptblock] $Operation)
    try {
        & $Operation
        throw '[RC8_RENDER_SCALE_AB_HOST_TEST] Expected operation unexpectedly succeeded.'
    } catch {
        if ($_.Exception.Message -ceq
                '[RC8_RENDER_SCALE_AB_HOST_TEST] Expected operation unexpectedly succeeded.') {
            throw
        }
        [string]$_.Exception.Message
    }
}

$sourceGate = Join-Path $PSScriptRoot 'quest-v71-rc8-render-scale-ab.ps1'
Require (Test-Path -LiteralPath $sourceGate -PathType Leaf) 'The render-scale gate is missing.'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourceGate, [ref]$tokens, [ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected the render-scale gate.'
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($required in @('Action','AllowDeviceWrite','Serial','AdbPath','ApkSignerPath')) {
    Require ($parameters -ccontains $required) "A required parameter is missing: $required"
}
foreach ($forbidden in @(
    'Package','StablePackage','Profile','ConfigPath','CorePath','VeqPath',
    'Scale','SourceScale','CandidateScale','Root','Install','Launch','ForceStop')) {
    Require ($parameters -cnotcontains $forbidden) "A fixed boundary is externally overrideable: $forbidden"
}

$source = [IO.File]::ReadAllText($sourceGate)
Require ($source.Contains("[string] `$Action = 'Status'") -and
    $source.Contains("[ValidateSet('Status', 'Arm', 'Restore')]")) `
    'Status is not the fixed default action.'
Require ($source.Contains("`$script:Package = 'com.qcxr.qcxr.canary262'") -and
    $source.Contains("`$script:StablePackage = 'com.qcxr.qcxr.dev262'")) `
    'Lab allow pin or Stable deny pin is missing.'
Require ($source.Contains('$script:ConfigPath = "$($script:GameDir)/config/vivecraft-client-config.json"')) `
    'The only mutable remote config path is not fixed.'
Require ([regex]::Matches($source, '''push'',\$Local,\$Remote').Count -eq 1 -and
    [regex]::Matches($source, '''shell'',''chmod'',''0660'',\$RemoteStage').Count -eq 1 -and
    [regex]::Matches($source, '''shell'',''mv'',\$RemoteStage,\$script:ConfigPath').Count -eq 1) `
    'The gate must expose exactly one push, stage-mode correction and atomic move.'
foreach ($forbiddenPattern in @(
    "'uninstall'", "'install'", "'pm','clear'", "'am','force-stop'",
    "'am','start'", "'shell','su'", "'root'", "'remount'", "'reboot'",
    "'shell','rm'", 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer',
    '/resourcepacks/', '/saves/', '/worlds/', '/accounts/', '/authlib')
) {
    Require (-not $source.Contains($forbiddenPattern)) `
        "A forbidden mutation/network/data boundary is present: $forbiddenPattern"
}
Require ($source.Contains("Require `$AllowDeviceWrite.IsPresent 'Arm requires explicit -AllowDeviceWrite.'") -and
    $source.Contains("Require `$AllowDeviceWrite.IsPresent 'Restore requires explicit -AllowDeviceWrite.'")) `
    'Arm or Restore lacks the explicit device-write gate.'
Require ($source.Contains('Arm requires renderScaleFactor to be exactly 1.0.') -and
    $source.Contains('''${prefix}"0.8"''')) `
    'The fixed 1.0 -> 0.8 change is absent.'
Require ($source.Contains('function Read-RemoteMode') -and
    $source.Contains("'shell','chmod','0660',`$RemoteStage") -and
    $source.Contains('The live config lost its writable mode')) `
    'The scoped-storage writable-mode contract is absent.'
Require ($source.Contains('function Enter-TransactionMutex') -and
    $source.Contains('$mutex.WaitOne(0)') -and
    $source.Contains('[Threading.AbandonedMutexException]') -and
    $source.Contains('finally { Exit-TransactionMutex $lease }')) `
    'The cross-process transaction mutex is absent or not exception-safe.'
Require ($source.Contains("`$script:MutexNamespace = 'QuestCraft_RC8_RenderScale_AB_PRODUCTION'") -and
    -not $source.Contains('Get-CanonicalPath $script:RepoRoot).ToUpperInvariant()')) `
    'The production mutex is not fixed across worktree copies.'
Require ($source.Contains("`$script:ApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'")) `
    'The production APK digest pin drifted.'
Require (-not $source.Contains('Delete($script:') -and
    -not $source.Contains('Remove-Item -LiteralPath $script:')) `
    'The gate contains speculative stale-artifact deletion.'

$fakeBaseBytes = [Text.Encoding]::ASCII.GetBytes('fake-but-nonempty-apk')
$fakeBaseSha = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($fakeBaseBytes))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('qc-rc8-render-scale-host-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$repoRoot = Join-Path $testRoot 'isolated-repo'
$isolatedScripts = Join-Path $repoRoot 'scripts'
[IO.Directory]::CreateDirectory($isolatedScripts) | Out-Null
$gate = Join-Path $isolatedScripts 'quest-v71-rc8-render-scale-ab.ps1'
$testMutexNamespace = 'QuestCraft_RC8_RenderScale_AB_HOST_' +
    [Guid]::NewGuid().ToString('N').ToUpperInvariant()
$isolatedGateSource = [IO.File]::ReadAllText($sourceGate)
$productionNamespaceLiteral = "`$script:MutexNamespace = 'QuestCraft_RC8_RenderScale_AB_PRODUCTION'"
Require ([regex]::Matches($isolatedGateSource,
    [regex]::Escape($productionNamespaceLiteral)).Count -eq 1) `
    'The copied gate mutex namespace was ambiguous.'
$isolatedGateSource = $isolatedGateSource.Replace($productionNamespaceLiteral,
    "`$script:MutexNamespace = '$testMutexNamespace'")
$productionApkLiteral = "`$script:ApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'"
Require ([regex]::Matches($isolatedGateSource,
    [regex]::Escape($productionApkLiteral)).Count -eq 1) `
    'The copied gate APK digest pin was ambiguous.'
$isolatedGateSource = $isolatedGateSource.Replace($productionApkLiteral,
    "`$script:ApkSha256 = '$fakeBaseSha'")
[IO.File]::WriteAllText($gate, $isolatedGateSource, [Text.UTF8Encoding]::new($false))
$artifactRoot = Join-Path $repoRoot 'artifacts\v71-rc8-render-scale-ab'
$deviceRoot = Join-Path $testRoot 'device'
[IO.Directory]::CreateDirectory($deviceRoot) | Out-Null
$configFile = Join-Path $deviceRoot 'config.bin'
$stageFile = Join-Path $deviceRoot 'stage.bin'
$stageNameFile = Join-Path $deviceRoot 'stage-name.txt'
$baseFile = Join-Path $deviceRoot 'base.apk'
$callLog = Join-Path $testRoot 'adb-calls.jsonl'
$pidCount = Join-Path $testRoot 'pid-count.txt'
$mvCount = Join-Path $testRoot 'mv-count.txt'
$verifyLieCount = Join-Path $testRoot 'verify-lie-count.txt'
$stageModeFile = Join-Path $testRoot 'stage-mode.txt'
$liveModeFile = Join-Path $testRoot 'live-mode.txt'
$stageShaCount = Join-Path $testRoot 'stage-sha-count.txt'
$lockMarker = Join-Path $testRoot 'lock-holder-entered.txt'
$fakeAdbPs1 = Join-Path $testRoot 'fake-adb.ps1'
$fakeAdbCmd = Join-Path $testRoot 'fake-adb.cmd'
$fakeSignerPs1 = Join-Path $testRoot 'fake-apksigner.ps1'
$fakeSignerCmd = Join-Path $testRoot 'fake-apksigner.cmd'
$utf8 = [Text.UTF8Encoding]::new($false)
$baselineText = "{`r`n  `"label`": `"اختبار RC8`",`r`n  `"renderScaleFactor`" : `"1.0`",`r`n  `"unchanged`": [1, 2, 3]`r`n}`r`n"
$baselineBytes = $utf8.GetBytes($baselineText)
[IO.File]::WriteAllBytes($baseFile, $fakeBaseBytes)

$fakeAdbSource = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $FakeArgs)
$ErrorActionPreference = 'Stop'
$entry = [ordered]@{ Arguments = @($FakeArgs) } | ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:QC_RS_CALL_LOG, $entry + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false))
$scenario = [string]$env:QC_RS_SCENARIO
$config = [string]$env:QC_RS_CONFIG
$stage = [string]$env:QC_RS_STAGE
$stageNameFile = [string]$env:QC_RS_STAGE_NAME

function Emit-Sha([string] $sha, [string] $path) {
    Write-Output ($sha.ToLowerInvariant() + '  ' + $path)
}
function File-Sha([string] $path) {
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function Bump([string] $path) {
    $value = if (Test-Path -LiteralPath $path) {
        [int][IO.File]::ReadAllText($path)
    } else { 0 }
    $value++
    [IO.File]::WriteAllText($path, [string]$value)
    $value
}

if ($FakeArgs.Count -eq 1 -and $FakeArgs[0] -ceq 'devices') {
    Write-Output 'List of devices attached'
    if ($scenario -ceq 'slow-lock-holder') {
        [IO.File]::WriteAllText($env:QC_RS_LOCK_MARKER, 'entered')
        Start-Sleep -Seconds 8
    }
    if ($scenario -ceq 'multiple-devices') {
        Write-Output "QUEST_RS`tdevice"
        Write-Output "QUEST_OTHER`tdevice"
    } elseif ($scenario -cne 'no-device') {
        Write-Output "QUEST_RS`tdevice product:fake model:Quest_3"
    }
    exit 0
}
if ($FakeArgs.Count -eq 3 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_RS' -and $FakeArgs[2] -ceq 'get-state') {
    Write-Output 'device'; exit 0
}
if ($FakeArgs.Count -lt 4 -or $FakeArgs[0] -cne '-s' -or
    $FakeArgs[1] -cne 'QUEST_RS') {
    Write-Error ('Unexpected fake ADB prefix: ' + ($FakeArgs -join ' | ')); exit 91
}

if ($FakeArgs[2] -ceq 'pull' -and $FakeArgs.Count -eq 5) {
    $remote = $FakeArgs[3]
    $local = $FakeArgs[4]
    if ($scenario -ceq 'pull-missing-file') {
        [Console]::Error.WriteLine('1 file pulled, 0 skipped. 1.0 MB/s (1 bytes in 0.001s)')
        exit 0
    } elseif ($remote -like '/data/app/*/base.apk') {
        [IO.File]::Copy($env:QC_RS_BASE, $local, $false)
    } elseif ($remote -ceq $env:QC_RS_CONFIG_REMOTE) {
        [IO.File]::Copy($config, $local, $false)
    } else {
        Write-Error ('Unexpected pull source: ' + $remote); exit 92
    }
    if ($scenario -ceq 'pull-wrong-digest') {
        [IO.File]::AppendAllText($local, 'digest-drift')
    }
    $summary = $remote + ': 1 file pulled, 0 skipped. 4.2 MB/s (' +
        [IO.File]::ReadAllBytes($local).Length + ' bytes in 0.001s)'
    switch ($scenario) {
        'pull-progress-stdout' { Write-Output $summary; exit 0 }
        'pull-progress-stderr' { [Console]::Error.WriteLine($summary); exit 0 }
        'pull-progress-cr' {
            [Console]::Error.Write("[ 50%] $remote`r[100%] $remote`r$summary`r`n")
            exit 0
        }
        'pull-invalid-chatter' { [Console]::Error.WriteLine('adb: warning: unexpected text'); exit 0 }
        'pull-oversized-chatter' { [Console]::Error.WriteLine(('x' * 65537)); exit 0 }
        'pull-exit-failure' { [Console]::Error.WriteLine('adb: error: transport failure'); exit 1 }
        'pull-silent' { exit 0 }
        default { Write-Output '1 file pulled'; exit 0 }
    }
}
if ($FakeArgs[2] -ceq 'push' -and $FakeArgs.Count -eq 5) {
    $remote = $FakeArgs[4]
    if (-not $remote.StartsWith($env:QC_RS_CONFIG_REMOTE + '.next-',
            [StringComparison]::Ordinal)) {
        Write-Error ('Unsafe push target: ' + $remote); exit 93
    }
    [IO.File]::Copy($FakeArgs[3], $stage, $true)
    [IO.File]::WriteAllText($stageNameFile, $remote)
    [IO.File]::WriteAllText($env:QC_RS_STAGE_MODE, '644')
    if ($scenario -ceq 'corrupt-stage') {
        [IO.File]::AppendAllText($stage, 'corrupt')
    }
    $summary = $remote + ': 1 file pushed, 0 skipped. 4.2 MB/s (' +
        [IO.File]::ReadAllBytes($stage).Length + ' bytes in 0.001s)'
    switch ($scenario) {
        'push-progress-stdout' { Write-Output $summary; exit 0 }
        'push-progress-stderr' { [Console]::Error.WriteLine($summary); exit 0 }
        'push-progress-cr' {
            [Console]::Error.Write("[ 50%] $remote`r[100%] $remote`r$summary`r`n")
            exit 0
        }
        'push-invalid-chatter' { [Console]::Error.WriteLine('adb: warning: unexpected text'); exit 0 }
        'push-oversized-chatter' { [Console]::Error.WriteLine(('x' * 65537)); exit 0 }
        'push-exit-failure' { [Console]::Error.WriteLine('adb: error: transport failure'); exit 1 }
        'push-silent' { exit 0 }
        default { Write-Output '1 file pushed'; exit 0 }
    }
}
if ($FakeArgs[2] -cne 'shell') {
    Write-Error ('Unexpected fake ADB command: ' + ($FakeArgs -join ' | ')); exit 94
}
$shell = @($FakeArgs | Select-Object -Skip 3)
if ($shell.Count -eq 3 -and $shell[0] -ceq 'dumpsys' -and
    $shell[1] -ceq 'package' -and $shell[2] -ceq 'com.qcxr.qcxr.canary262') {
    $code = if ($scenario -ceq 'wrong-version') { '70' } else { '71' }
    Write-Output ('  versionCode=' + $code + ' minSdk=29 targetSdk=34')
    Write-Output '  versionName=6.0.1-26.2-vivecraft-personal.12-rc.8'
    exit 0
}
if ($shell.Count -eq 3 -and $shell[0] -ceq 'pm' -and
    $shell[1] -ceq 'path' -and $shell[2] -ceq 'com.qcxr.qcxr.canary262') {
    Write-Output 'package:/data/app/~~fake/com.qcxr.qcxr.canary262-test/base.apk'; exit 0
}
if ($shell.Count -eq 2 -and $shell[0] -ceq 'pidof' -and
    $shell[1] -ceq 'com.qcxr.qcxr.canary262') {
    $count = Bump $env:QC_RS_PID_COUNT
    if ($scenario -ceq 'running' -or
        ($scenario -ceq 'race-running' -and $count -ge 2) -or
        ($scenario -ceq 'late-running' -and $count -ge 3)) {
        Write-Output '24680'; exit 0
    }
    exit 1
}
if ($shell.Count -eq 4 -and $shell[0] -ceq 'stat' -and
    $shell[1] -ceq '-c' -and $shell[2] -ceq '%a') {
    $path = $shell[3]
    $knownStage = (Test-Path -LiteralPath $stageNameFile) -and
        [IO.File]::ReadAllText($stageNameFile) -ceq $path
    if ($path -cne $env:QC_RS_CONFIG_REMOTE -and -not $knownStage) {
        Write-Error ('Unsafe stat target: ' + $path); exit 95
    }
    if ($path -ceq $env:QC_RS_CONFIG_REMOTE) {
        Write-Output ([IO.File]::ReadAllText($env:QC_RS_LIVE_MODE))
    } else {
        Write-Output ([IO.File]::ReadAllText($env:QC_RS_STAGE_MODE))
    }
    exit 0
}
if ($shell.Count -eq 2 -and $shell[0] -ceq 'sha256sum') {
    $path = $shell[1]
    if ($path -like '/data/app/*/base.apk') {
        $sha = if ($scenario -ceq 'wrong-apk') {
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        } else { [string]$env:QC_RS_APK_SHA }
        Emit-Sha $sha $path; exit 0
    }
    if ($path -ceq $env:QC_RS_CORE_REMOTE) {
        $sha = if ($scenario -ceq 'wrong-core') {
            'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
        } else { 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB' }
        Emit-Sha $sha $path; exit 0
    }
    if ($path -ceq $env:QC_RS_VEQ_REMOTE) {
        $sha = if ($scenario -ceq 'wrong-veq') {
            'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'
        } else { 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9' }
        Emit-Sha $sha $path; exit 0
    }
    if ($path -ceq $env:QC_RS_CONFIG_REMOTE) {
        if ($scenario -ceq 'post-verify-lie-once' -and
            (Test-Path -LiteralPath $env:QC_RS_MV_COUNT) -and
            [int][IO.File]::ReadAllText($env:QC_RS_MV_COUNT) -ge 1 -and
            -not (Test-Path -LiteralPath $env:QC_RS_VERIFY_LIE_COUNT)) {
            [IO.File]::WriteAllText($env:QC_RS_VERIFY_LIE_COUNT, '1')
            Emit-Sha 'EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE' $path
            exit 0
        }
        Emit-Sha (File-Sha $config) $path; exit 0
    }
    if ((Test-Path -LiteralPath $stageNameFile) -and
        [IO.File]::ReadAllText($stageNameFile) -ceq $path -and
        (Test-Path -LiteralPath $stage)) {
        $stageProbe = Bump $env:QC_RS_STAGE_SHA_COUNT
        if ($scenario -ceq 'late-stage-corruption' -and $stageProbe -eq 2) {
            [IO.File]::AppendAllText($stage, 'late-corruption')
        }
        Emit-Sha (File-Sha $stage) $path; exit 0
    }
    Write-Error ('Unexpected sha256sum target: ' + $path); exit 95
}
if ($shell.Count -eq 3 -and $shell[0] -ceq 'chmod') {
    $expectedStage = if (Test-Path -LiteralPath $stageNameFile) {
        [IO.File]::ReadAllText($stageNameFile)
    } else { '' }
    if ($shell[1] -cne '0660' -or $shell[2] -cne $expectedStage) {
        Write-Error ('Unsafe chmod: ' + ($shell -join ' | ')); exit 96
    }
    if ($scenario -ceq 'chmod-failure') { exit 1 }
    if ($scenario -cne 'mode-stuck') {
        [IO.File]::WriteAllText($env:QC_RS_STAGE_MODE, '660')
    }
    exit 0
}
if ($shell.Count -eq 3 -and $shell[0] -ceq 'mv') {
    $expectedStage = if (Test-Path -LiteralPath $stageNameFile) {
        [IO.File]::ReadAllText($stageNameFile)
    } else { '' }
    if ($shell[1] -cne $expectedStage -or $shell[2] -cne $env:QC_RS_CONFIG_REMOTE) {
        Write-Error ('Unsafe mv: ' + ($shell -join ' | ')); exit 96
    }
    if ($scenario -ceq 'mv-failure') { exit 1 }
    $mvNumber = Bump $env:QC_RS_MV_COUNT
    [IO.File]::Move($stage, $config, $true)
    $publishedMode = [IO.File]::ReadAllText($env:QC_RS_STAGE_MODE)
    if ($scenario -ceq 'first-move-loses-mode' -and $mvNumber -eq 1) {
        $publishedMode = '644'
    }
    [IO.File]::WriteAllText($env:QC_RS_LIVE_MODE, $publishedMode)
    [IO.File]::Delete($stageNameFile)
    [IO.File]::Delete($env:QC_RS_STAGE_MODE)
    if ($scenario -ceq 'post-corrupt-once' -and $mvNumber -eq 1) {
        [IO.File]::AppendAllText($config, 'corrupt')
    }
    exit 0
}
Write-Error ('Unexpected fake shell argv: ' + ($shell -join ' | ')); exit 97
'@

$fakeSignerSource = @'
$FakeArgs = @($args)
if ($FakeArgs.Count -ne 4 -or $FakeArgs[0] -cne 'verify' -or
    $FakeArgs[1] -cne '--verbose' -or $FakeArgs[2] -cne '--print-certs') {
    Write-Error ('Unexpected fake signer argv: ' + ($FakeArgs -join ' | ')); exit 98
}
$sha = if ($env:QC_RS_SCENARIO -ceq 'wrong-signer') {
    'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD'
} else { 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A' }
Write-Output 'Verifies'
Write-Output 'Verified using v2 scheme (APK Signature Scheme v2): true'
Write-Output ('Signer #1 certificate SHA-256 digest: ' + $sha)
exit 0
'@

[IO.File]::WriteAllText($fakeAdbPs1, $fakeAdbSource, $utf8)
[IO.File]::WriteAllText($fakeSignerPs1, $fakeSignerSource, $utf8)
[IO.File]::WriteAllText($fakeAdbCmd,
    "@echo off`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-adb.ps1`" %*`r`n",
    [Text.Encoding]::ASCII)
[IO.File]::WriteAllText($fakeSignerCmd,
    "@echo off`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-apksigner.ps1`" %*`r`n",
    [Text.Encoding]::ASCII)

$envNames = @(
    'QC_RS_CALL_LOG','QC_RS_SCENARIO','QC_RS_CONFIG','QC_RS_STAGE',
    'QC_RS_STAGE_NAME','QC_RS_STAGE_MODE','QC_RS_LIVE_MODE','QC_RS_STAGE_SHA_COUNT',
    'QC_RS_BASE','QC_RS_PID_COUNT','QC_RS_MV_COUNT','QC_RS_VERIFY_LIE_COUNT',
    'QC_RS_LOCK_MARKER','QC_RS_CONFIG_REMOTE',
    'QC_RS_CORE_REMOTE','QC_RS_VEQ_REMOTE','QC_RS_APK_SHA')
$savedEnv = @{}
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name) }

$env:QC_RS_CALL_LOG = $callLog
$env:QC_RS_CONFIG = $configFile
$env:QC_RS_STAGE = $stageFile
$env:QC_RS_STAGE_NAME = $stageNameFile
$env:QC_RS_STAGE_MODE = $stageModeFile
$env:QC_RS_LIVE_MODE = $liveModeFile
$env:QC_RS_STAGE_SHA_COUNT = $stageShaCount
$env:QC_RS_BASE = $baseFile
$env:QC_RS_PID_COUNT = $pidCount
$env:QC_RS_MV_COUNT = $mvCount
$env:QC_RS_VERIFY_LIE_COUNT = $verifyLieCount
$env:QC_RS_LOCK_MARKER = $lockMarker
$env:QC_RS_APK_SHA = $fakeBaseSha
$env:QC_RS_CONFIG_REMOTE = '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/config/vivecraft-client-config.json'
$env:QC_RS_CORE_REMOTE = '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft.jar'
$env:QC_RS_VEQ_REMOTE = '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft-Essentials-Quest.jar'

function Clear-TransactionArtifacts {
    if (-not (Test-Path -LiteralPath $artifactRoot)) { return }
    $full = [IO.Path]::GetFullPath($artifactRoot)
    $expected = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts\v71-rc8-render-scale-ab'))
    Require ($full -ceq $expected -and $full.StartsWith(
        [IO.Path]::GetFullPath($repoRoot) + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'Refused to clear an unexpected artifact root.'
    foreach ($item in @(Get-ChildItem -LiteralPath $full -Force)) {
        Require (-not $item.PSIsContainer) 'Unexpected directory in the test transaction root.'
        [IO.File]::Delete($item.FullName)
    }
    [IO.Directory]::Delete($full)
    $parent = Split-Path -Parent $full
    if ((Test-Path -LiteralPath $parent) -and
        [IO.Directory]::GetFileSystemEntries($parent).Length -eq 0) {
        [IO.Directory]::Delete($parent)
    }
}

function Reset-Fixture {
    param([string] $Scenario = 'good', [byte[]] $ConfigBytes = $baselineBytes)
    $env:QC_RS_SCENARIO = $Scenario
    [IO.File]::WriteAllBytes($configFile, $ConfigBytes)
    foreach ($path in @($stageFile,$stageNameFile,$stageModeFile,$stageShaCount,
            $callLog,$pidCount,$mvCount,$verifyLieCount,$lockMarker)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { [IO.File]::Delete($path) }
    }
    [IO.File]::WriteAllText($liveModeFile, '660')
    Clear-TransactionArtifacts
}

function Invoke-Gate {
    param([string] $RequestedAction = 'Status', [switch] $Write)
    $arguments = @{
        Action = $RequestedAction
        Serial = 'QUEST_RS'
        AdbPath = $fakeAdbCmd
        ApkSignerPath = $fakeSignerCmd
    }
    if ($Write) { $arguments.AllowDeviceWrite = $true }
    $values = @(& $gate @arguments)
    $objects = @($values | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
    Require ($objects.Count -eq 1 -and $values.Count -eq 1) `
        'The gate returned transfer chatter or did not return one structured result.'
    $objects[0]
}

function Start-GateProcess {
    param([Parameter(Mandatory)][string] $RequestedAction, [switch] $Write)
    $pwsh = (Get-Command 'pwsh' -CommandType Application | Select-Object -First 1).Source
    Require (-not [string]::IsNullOrWhiteSpace($pwsh)) 'pwsh was unavailable for the concurrency test.'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pwsh
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @(
        '-NoLogo','-NoProfile','-NonInteractive','-File',$gate,
        '-Action',$RequestedAction,'-Serial','QUEST_RS',
        '-AdbPath',$fakeAdbCmd,'-ApkSignerPath',$fakeSignerCmd)) {
        $start.ArgumentList.Add($argument)
    }
    if ($Write) { $start.ArgumentList.Add('-AllowDeviceWrite') }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    Require $process.Start() 'Could not start the concurrent gate process.'
    [pscustomobject]@{
        Process = $process
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-GateProcess {
    param([Parameter(Mandatory)] $Handle, [int] $TimeoutMs = 45000)
    try {
        Require $Handle.Process.WaitForExit($TimeoutMs) 'A concurrent gate process timed out.'
        [pscustomobject]@{
            ExitCode = $Handle.Process.ExitCode
            Stdout = $Handle.Stdout.GetAwaiter().GetResult()
            Stderr = $Handle.Stderr.GetAwaiter().GetResult()
        }
    } finally {
        if (-not $Handle.Process.HasExited) { $Handle.Process.Kill($true) }
        $Handle.Process.Dispose()
    }
}

function Wait-ForMarker {
    param([Parameter(Mandatory)][string] $Path, [int] $TimeoutMs = 10000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        Start-Sleep -Milliseconds 25
    }
    $false
}

function Read-Calls {
    if (-not (Test-Path -LiteralPath $callLog)) { return @() }
    @([IO.File]::ReadAllLines($callLog) | ForEach-Object {
        $_ | ConvertFrom-Json
    })
}

function Assert-NoForbiddenCalls {
    $calls = @(Read-Calls)
    foreach ($call in $calls) {
        $argv = @($call.Arguments)
        $joined = @($argv) -join ' '
        Require (-not $joined.Contains('com.qcxr.qcxr.dev262', [StringComparison]::Ordinal)) `
            'Fake ADB observed Stable.'
        foreach ($word in @('uninstall','install','clear','force-stop','start','su','root','remount','reboot','rm','curl','wget')) {
            Require (@($argv) -cnotcontains $word) "Fake ADB observed a forbidden command: $joined"
        }
        if (@($argv) -ccontains 'push') {
            Require ($argv.Count -eq 5 -and $argv[2] -ceq 'push' -and
                [string]$argv[4] -clike ($env:QC_RS_CONFIG_REMOTE + '.next-*')) `
                "A push escaped the fixed config staging path: $joined"
        }
        if (@($argv) -ccontains 'mv') {
            Require ($argv.Count -eq 6 -and $argv[2] -ceq 'shell' -and
                $argv[3] -ceq 'mv' -and
                [string]$argv[4] -clike ($env:QC_RS_CONFIG_REMOTE + '.next-*') -and
                [string]$argv[5] -ceq $env:QC_RS_CONFIG_REMOTE) `
                "An atomic move escaped the fixed config target: $joined"
        }
        if (@($argv) -ccontains 'chmod') {
            Require ($argv.Count -eq 6 -and $argv[2] -ceq 'shell' -and
                $argv[3] -ceq 'chmod' -and $argv[4] -ceq '0660' -and
                [string]$argv[5] -clike ($env:QC_RS_CONFIG_REMOTE + '.next-*')) `
                "A mode correction escaped the fixed config stage: $joined"
        }
    }
}

try {
    # Default Status: exact identity, baseline scale, and zero device writes.
    Reset-Fixture
    $status = Invoke-Gate
    Require ([string]$status.Result -ceq 'STATUS_OK' -and
        [string]$status.Action -ceq 'Status' -and
        [string]$status.RenderScaleFactor -ceq '1.0' -and
        [string]$status.ConfigMode -ceq '660' -and
        [string]$status.Transaction -ceq 'NONE' -and
        -not [bool]$status.LabRunning -and [int]$status.DeviceWrites -eq 0 -and
        -not [bool]$status.StableTouched) 'Default Status was not read-only baseline status.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 0) `
        'Default Status issued a device mutation.'
    Assert-NoForbiddenCalls

    # Native adb may put the same bounded success summary/progress on stdout,
    # stderr, or carriage-return-updated stderr. It may also be silent. None of
    # those transport strings may escape the gate's structured output.
    foreach ($scenario in @(
        'pull-progress-stdout','pull-progress-stderr','pull-progress-cr','pull-silent')) {
        Reset-Fixture -Scenario $scenario
        $progressStatus = Invoke-Gate
        Require ([string]$progressStatus.Result -ceq 'STATUS_OK' -and
            [string]$progressStatus.RenderScaleFactor -ceq '1.0' -and
            [int]$progressStatus.DeviceWrites -eq 0) `
            "A bounded successful pull format was rejected: $scenario"
        Assert-NoForbiddenCalls
    }

    # Exit failure, missing/wrong bytes, unrecognized text, and oversized text
    # all fail closed. Error messages never reflect raw transfer output.
    foreach ($case in @(
        @{ Scenario='pull-exit-failure'; Pattern='read-only pull failed' },
        @{ Scenario='pull-missing-file'; Pattern='nonempty local file' },
        @{ Scenario='pull-wrong-digest'; Pattern='digest did not match' },
        @{ Scenario='pull-invalid-chatter'; Pattern='unrecognized transfer chatter' },
        @{ Scenario='pull-oversized-chatter'; Pattern='oversized transfer chatter' })) {
        Reset-Fixture -Scenario $case.Scenario
        $failureMessage = Get-ExpectedFailureMessage { Invoke-Gate }
        Require ($failureMessage -match $case.Pattern -and
            $failureMessage -notmatch 'transport failure|unexpected text|1 file pulled|x{32}') `
            "A failed pull leaked output or returned the wrong failure: $($case.Scenario)"
        Require (@(Read-Calls | Where-Object {
            $_.Arguments -ccontains 'push' -or $_.Arguments -ccontains 'chmod' -or
                $_.Arguments -ccontains 'mv'
        }).Count -eq 0) "A failed Status pull mutated the device: $($case.Scenario)"
        Assert-NoForbiddenCalls
    }

    # Explicit authorization is mandatory before any ADB resolution or write.
    Reset-Fixture
    Require (Test-ExpectedFailure { Invoke-Gate -RequestedAction Arm } 'explicit -AllowDeviceWrite') `
        'Arm ran without explicit device-write authorization.'
    Require (@(Read-Calls).Count -eq 0) 'Unauthorized Arm invoked ADB.'
    Require (Test-ExpectedFailure { Invoke-Gate -RequestedAction Restore } 'explicit -AllowDeviceWrite') `
        'Restore ran without explicit device-write authorization.'
    Require (@(Read-Calls).Count -eq 0) 'Unauthorized Restore invoked ADB.'

    # Running Lab blocks Arm before push/mv.
    Reset-Fixture -Scenario 'running'
    Require (Test-ExpectedFailure { Invoke-Gate -RequestedAction Arm -Write } 'Lab is running') `
        'A running Lab did not block Arm.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 0) `
        'Running-Lab refusal mutated the device.'

    # Every identity field, including signer, is a fail-closed precondition.
    foreach ($case in @(
        @{ Scenario='wrong-version'; Pattern='not exact RC8' },
        @{ Scenario='wrong-apk'; Pattern='APK digest' },
        @{ Scenario='wrong-core'; Pattern='Core' },
        @{ Scenario='wrong-veq'; Pattern='VEQ' },
        @{ Scenario='wrong-signer'; Pattern='signer' })) {
        Reset-Fixture -Scenario $case.Scenario
        Require (Test-ExpectedFailure {
            Invoke-Gate -RequestedAction Arm -Write
        } $case.Pattern) "Identity fault was not rejected: $($case.Scenario)"
        Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                    $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 0) `
            "Identity fault mutated the device: $($case.Scenario)"
    }

    # Arm changes exactly one equal-length scalar and preserves byte-exact backup.
    Reset-Fixture
    $arm = Invoke-Gate -RequestedAction Arm -Write
    Require ([string]$arm.Result -ceq 'ARMED' -and
        [string]$arm.RenderScaleFactor -ceq '0.8' -and
        [int]$arm.DeviceWrites -eq 3 -and -not [bool]$arm.StableTouched) `
        'Successful Arm did not report the exact transaction.'
    $armedBytes = [IO.File]::ReadAllBytes($configFile)
    $armedText = $utf8.GetString($armedBytes)
    Require ($armedBytes.Length -eq $baselineBytes.Length -and
        $armedText.Contains('"renderScaleFactor" : "0.8"') -and
        ($armedText.Replace('"renderScaleFactor" : "0.8"',
            '"renderScaleFactor" : "1.0"') -ceq $baselineText)) `
        'Arm changed bytes outside the fixed renderScaleFactor value.'
    $originalArtifact = Join-Path $artifactRoot 'vivecraft-client-config.original.bin'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($originalArtifact)) -ceq
        [Convert]::ToBase64String($baselineBytes)) 'The original backup was not byte exact.'
    $state = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'state.json') |
        ConvertFrom-Json
    Require ([string]$state.status -ceq 'ARMED' -and
        [string]$state.sourceSha256 -ceq
            (Get-FileHash $originalArtifact -Algorithm SHA256).Hash) `
        'The ARMED state did not bind the original digest.'
    $mutations = @(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
            $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' })
    Require ($mutations.Count -eq 3) `
        'Arm did not use exactly one push, mode correction and atomic move.'
    Assert-NoForbiddenCalls

    # Status while armed is read-only and identifies 0.8 without changing bytes.
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    $armedStatus = Invoke-Gate
    Require ([string]$armedStatus.RenderScaleFactor -ceq '0.8' -and
        [string]$armedStatus.Transaction -ceq 'ARMED' -and
        [int]$armedStatus.DeviceWrites -eq 0) 'Status did not recognize the armed state.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 0) `
        'Armed Status issued a mutation.'

    # Restore reproduces exact source bytes and digest with one atomic replacement.
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    if (Test-Path -LiteralPath $pidCount) { [IO.File]::Delete($pidCount) }
    $restore = Invoke-Gate -RequestedAction Restore -Write
    Require ([string]$restore.Result -ceq 'RESTORED' -and
        [bool]$restore.ByteExact -and [string]$restore.RenderScaleFactor -ceq '1.0' -and
        [int]$restore.DeviceWrites -eq 3) 'Restore did not report byte-exact success.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq
        [Convert]::ToBase64String($baselineBytes)) 'Restore did not recreate the exact original bytes.'
    Require ([string](Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'state.json') |
        ConvertFrom-Json).status -ceq 'RESTORED') 'Restore state was not persisted.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 3) `
        'Restore did not use exactly one push, mode correction and atomic move.'
    Assert-NoForbiddenCalls

    # A completed transaction may be re-armed for the final AB/BA/AB pair,
    # reusing the same byte-exact backups instead of deleting audit evidence.
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    if (Test-Path -LiteralPath $pidCount) { [IO.File]::Delete($pidCount) }
    $rearm = Invoke-Gate -RequestedAction Arm -Write
    Require ([string]$rearm.Result -ceq 'ARMED' -and
        [string]$rearm.RenderScaleFactor -ceq '0.8' -and
        [int]$rearm.DeviceWrites -eq 3) 'RESTORED transaction did not re-arm safely.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($originalArtifact)) -ceq
        [Convert]::ToBase64String($baselineBytes)) 'Re-arm changed the original backup.'
    Require ([string](Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'state.json') |
        ConvertFrom-Json).status -ceq 'ARMED') 'Re-arm did not persist ARMED state.'
    Require (@(Read-Calls | Where-Object {
        $_.Arguments -ccontains 'push' -or $_.Arguments -ccontains 'chmod' -or
            $_.Arguments -ccontains 'mv'
    }).Count -eq 3) 'Re-arm did not use one push, mode correction and atomic move.'
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    if (Test-Path -LiteralPath $pidCount) { [IO.File]::Delete($pidCount) }
    $null = Invoke-Gate -RequestedAction Restore -Write

    # Native adb may emit successful push progress on either stream, use CR
    # progress updates, or stay silent. All are accepted only before the
    # independently verified staged digest and atomic replacement.
    foreach ($scenario in @(
        'push-progress-stdout','push-progress-stderr','push-progress-cr','push-silent')) {
        Reset-Fixture -Scenario $scenario
        $pushArm = Invoke-Gate -RequestedAction Arm -Write
        Require ([string]$pushArm.Result -ceq 'ARMED' -and
            [string]$pushArm.RenderScaleFactor -ceq '0.8') `
            "A bounded successful push format was rejected: $scenario"
        Assert-NoForbiddenCalls
    }

    # Transport failure and unrecognized/oversized push output fail before mv.
    foreach ($case in @(
        @{ Scenario='push-exit-failure'; Pattern='config staging push failed' },
        @{ Scenario='push-invalid-chatter'; Pattern='unrecognized transfer chatter' },
        @{ Scenario='push-oversized-chatter'; Pattern='oversized transfer chatter' })) {
        Reset-Fixture -Scenario $case.Scenario
        $failureMessage = Get-ExpectedFailureMessage {
            Invoke-Gate -RequestedAction Arm -Write
        }
        Require ($failureMessage -match $case.Pattern -and
            $failureMessage -notmatch 'transport failure|unexpected text|1 file pushed|x{32}') `
            "A failed push leaked output or returned the wrong failure: $($case.Scenario)"
        Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq
            [Convert]::ToBase64String($baselineBytes)) `
            "A failed push changed the live config: $($case.Scenario)"
        Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'mv' }).Count -eq 0) `
            "A failed push reached atomic replacement: $($case.Scenario)"
        Assert-NoForbiddenCalls
    }

    # Source must be precisely string 1.0; numeric or another value is rejected pre-write.
    foreach ($badText in @(
        '{"renderScaleFactor":"0.9"}',
        '{"renderScaleFactor":1.0}',
        '{"renderScaleFactor":"1.0","nested":{"renderScaleFactor":"1.0"}}')) {
        Reset-Fixture -ConfigBytes $utf8.GetBytes($badText)
        Require (Test-ExpectedFailure {
            Invoke-Gate -RequestedAction Arm -Write
        } 'renderScaleFactor|ambiguous') 'A non-exact source scale was accepted.'
        Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                    $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 0) `
            'Invalid source config reached a device mutation.'
    }

    # Staged corruption and a running-state race both fail before atomic move.
    foreach ($case in @(
        @{ Scenario='corrupt-stage'; Pattern='staged config digest' },
        @{ Scenario='chmod-failure'; Pattern='mode correction' },
        @{ Scenario='mode-stuck'; Pattern='group-writable' },
        @{ Scenario='late-stage-corruption'; Pattern='changed before atomic replacement' },
        @{ Scenario='race-running'; Pattern='Lab is running' },
        @{ Scenario='late-running'; Pattern='Lab is running' })) {
        Reset-Fixture -Scenario $case.Scenario
        Require (Test-ExpectedFailure {
            Invoke-Gate -RequestedAction Arm -Write
        } $case.Pattern) "Pre-move fault was not rejected: $($case.Scenario)"
        Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq
            [Convert]::ToBase64String($baselineBytes)) `
            "Pre-move fault changed the live config: $($case.Scenario)"
        Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'mv' }).Count -eq 0) `
            "Pre-move fault reached atomic replacement: $($case.Scenario)"
    }

    # If the first mv publishes the right bytes with the wrong mode, the
    # post-move probe fails and emergency recovery restores exact source bytes
    # with the required writable mode.
    Reset-Fixture -Scenario 'first-move-loses-mode'
    Require (Test-ExpectedFailure {
        Invoke-Gate -RequestedAction Arm -Write
    } 'lost its writable mode') 'A post-move mode loss was not surfaced.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq
        [Convert]::ToBase64String($baselineBytes)) `
        'Post-move mode recovery did not restore exact original bytes.'
    Require ([IO.File]::ReadAllText($liveModeFile) -ceq '660') `
        'Post-move mode recovery did not restore writable mode.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'mv' }).Count -eq 2) `
        'Post-move mode recovery did not use one publish and one recovery move.'

    # Atomic move failure leaves the live original intact.
    Reset-Fixture -Scenario 'mv-failure'
    Require (Test-ExpectedFailure { Invoke-Gate -RequestedAction Arm -Write } 'atomic config replacement') `
        'An atomic-move failure was not surfaced.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq
        [Convert]::ToBase64String($baselineBytes)) 'Atomic-move failure changed the original.'
    $env:QC_RS_SCENARIO = 'good'
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    if (Test-Path -LiteralPath $pidCount) { [IO.File]::Delete($pidCount) }
    $reconciled = Invoke-Gate -RequestedAction Restore -Write
    Require ([string]$reconciled.Result -ceq 'RESTORED' -and
        [int]$reconciled.DeviceWrites -eq 0 -and [bool]$reconciled.ByteExact) `
        'Explicit Restore did not reconcile an already-original BACKUP_READY state.'
    Require (@(Read-Calls | Where-Object {
        $_.Arguments -ccontains 'push' -or $_.Arguments -ccontains 'chmod' -or
            $_.Arguments -ccontains 'mv'
    }).Count -eq 0) 'BACKUP_READY reconciliation unexpectedly wrote to the device.'

    # If post-move verification lies once while the live bytes remain our exact
    # candidate, emergency recovery restores the exact original and records it.
    Reset-Fixture -Scenario 'post-verify-lie-once'
    Require (Test-ExpectedFailure {
        Invoke-Gate -RequestedAction Arm -Write
    } 'digest mismatched after atomic replacement') 'Post-move verification fault was not surfaced.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -ceq
        [Convert]::ToBase64String($baselineBytes)) 'Emergency restore did not recreate exact original bytes.'
    $recovered = Get-Content -Raw -LiteralPath (Join-Path $artifactRoot 'state.json') |
        ConvertFrom-Json
    Require ([string]$recovered.status -ceq 'RECOVERED') 'Emergency restore was not recorded.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'mv' }).Count -eq 2) `
        'Emergency recovery did not use two bounded atomic moves.'
    Assert-NoForbiddenCalls

    # If the post-move bytes are neither exact source nor exact candidate,
    # preserve unknown drift and the local backup; do not overwrite it under
    # the label of emergency recovery.
    Reset-Fixture -Scenario 'post-corrupt-once'
    Require (Test-ExpectedFailure {
        Invoke-Gate -RequestedAction Arm -Write
    } 'unknown drift; automatic restore refused') `
        'Unknown post-move drift was not surfaced as a fail-closed condition.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile)) -cne
        [Convert]::ToBase64String($baselineBytes)) `
        'Unknown post-move drift was overwritten automatically.'
    Require ([Convert]::ToBase64String([IO.File]::ReadAllBytes(
            (Join-Path $artifactRoot 'vivecraft-client-config.original.bin'))) -ceq
        [Convert]::ToBase64String($baselineBytes)) `
        'Unknown-drift refusal did not retain the byte-exact original backup.'
    Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'mv' }).Count -eq 1) `
        'Unknown post-move drift triggered a speculative second atomic move.'

    # Tampered backups and active config drift block Restore before its push.
    Reset-Fixture
    $null = Invoke-Gate -RequestedAction Arm -Write
    [IO.File]::AppendAllText((Join-Path $artifactRoot 'vivecraft-client-config.original.bin'), 'tamper')
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    Require (Test-ExpectedFailure {
        Invoke-Gate -RequestedAction Restore -Write
    } 'original backup digest') 'A tampered backup was accepted.'
    Require (@(Read-Calls).Count -eq 0) 'Tampered backup reached ADB.'

    Reset-Fixture
    $null = Invoke-Gate -RequestedAction Arm -Write
    [IO.File]::AppendAllText($configFile, 'external-drift')
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    if (Test-Path -LiteralPath $pidCount) { [IO.File]::Delete($pidCount) }
    Require (Test-ExpectedFailure {
        Invoke-Gate -RequestedAction Restore -Write
    } 'active config drifted') 'An unknown live config was overwritten by Restore.'
        Require (@(Read-Calls | Where-Object { $_.Arguments -ccontains 'push' -or
                    $_.Arguments -ccontains 'chmod' -or $_.Arguments -ccontains 'mv' }).Count -eq 0) `
        'Drifted active config reached mutation.'
    Assert-NoForbiddenCalls

    # One live invocation excludes Status, Arm, and Restore in other
    # processes before they can resolve or call even fake ADB.
    Reset-Fixture -Scenario 'slow-lock-holder'
    $holder = Start-GateProcess -RequestedAction Arm -Write
    try {
        Require (Wait-ForMarker $lockMarker) 'The concurrent Arm did not enter its locked ADB probe.'
        $callsBeforeContenders = @(Read-Calls).Count
        foreach ($contender in @(
            @{ Action='Status'; Write=$false },
            @{ Action='Arm'; Write=$true },
            @{ Action='Restore'; Write=$true })) {
            Require (Test-ExpectedFailure {
                Invoke-Gate -RequestedAction $contender.Action -Write:([bool]$contender.Write)
            } 'Another render-scale gate invocation is active') `
                "A concurrent $($contender.Action) invocation was not excluded."
        }
        Require (@(Read-Calls).Count -eq $callsBeforeContenders) `
            'A lock-rejected contender reached ADB.'
        $holderResult = Complete-GateProcess $holder
        $holder = $null
        Require ([int]$holderResult.ExitCode -eq 0 -and
            [string]::IsNullOrWhiteSpace([string]$holderResult.Stderr)) `
            "The lock-holding Arm failed: $($holderResult.Stderr)"
        $completedConfig = $utf8.GetString([IO.File]::ReadAllBytes($configFile)) |
            ConvertFrom-Json
        Require ([string]$completedConfig.renderScaleFactor -ceq '0.8') `
            'The lock-holding Arm did not complete after contenders were rejected.'
    } finally {
        if ($null -ne $holder) {
            try {
                if (-not $holder.Process.HasExited) { $holder.Process.Kill($true) }
                $holder.Process.WaitForExit()
            } finally { $holder.Process.Dispose() }
        }
    }
    $env:QC_RS_SCENARIO = 'good'
    if (Test-Path -LiteralPath $callLog) { [IO.File]::Delete($callLog) }
    if (Test-Path -LiteralPath $pidCount) { [IO.File]::Delete($pidCount) }
    $afterConcurrentRestore = Invoke-Gate -RequestedAction Restore -Write
    Require ([string]$afterConcurrentRestore.Result -ceq 'RESTORED' -and
        [bool]$afterConcurrentRestore.ByteExact) `
        'The serialized transaction did not remain restorable.'

    # An owner killed while holding the named kernel mutex cannot leave a
    # stale file or permanent lock. Keep a non-owning handle alive so the next
    # gate deterministically observes AbandonedMutexException.
    Reset-Fixture
    $abandonHelper = Join-Path $testRoot 'abandon-mutex-holder.ps1'
    $abandonMarker = Join-Path $testRoot 'abandoned-mutex-name.txt'
    $helperSource = @'
param([string] $Gate, [string] $Marker)
. $Gate
$name = Get-TransactionMutexName
$mutex = [Threading.Mutex]::new($false, $name)
$null = $mutex.WaitOne()
[IO.File]::WriteAllText($Marker, $name)
Start-Sleep -Seconds 60
'@
    [IO.File]::WriteAllText($abandonHelper, $helperSource, $utf8)
    $pwshPath = (Get-Command 'pwsh' -CommandType Application | Select-Object -First 1).Source
    $helperStart = [Diagnostics.ProcessStartInfo]::new()
    $helperStart.FileName = $pwshPath
    $helperStart.UseShellExecute = $false
    $helperStart.CreateNoWindow = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',
            $abandonHelper,'-Gate',$gate,'-Marker',$abandonMarker)) {
        $helperStart.ArgumentList.Add($argument)
    }
    $helperProcess = [Diagnostics.Process]::new()
    $helperProcess.StartInfo = $helperStart
    $observer = $null
    $helperStarted = $false
    try {
        $helperStarted = $helperProcess.Start()
        Require $helperStarted 'Could not start the abandoned-owner helper.'
        Require (Wait-ForMarker $abandonMarker) 'The abandoned-owner helper never acquired the mutex.'
        $abandonedMutexName = [IO.File]::ReadAllText($abandonMarker)
        Require ($abandonedMutexName -ceq ($testMutexNamespace + '_' +
                $abandonedMutexName.Substring($abandonedMutexName.Length - 64)) -and
            $abandonedMutexName -cmatch '^QuestCraft_RC8_RenderScale_AB_HOST_[0-9A-F]{32}_[0-9A-F]{64}$') `
            'The abandoned-owner helper returned an invalid mutex identity.'
        $observer = [Threading.Mutex]::OpenExisting($abandonedMutexName)
        $helperProcess.Kill($true)
        $helperProcess.WaitForExit()
        $postAbandonStatus = Invoke-Gate
        Require ([string]$postAbandonStatus.Result -ceq 'STATUS_OK' -and
            [int]$postAbandonStatus.DeviceWrites -eq 0) `
            'The gate did not recover safely from an abandoned mutex owner.'
    } finally {
        if ($helperStarted -and -not $helperProcess.HasExited) {
            $helperProcess.Kill($true)
            $helperProcess.WaitForExit()
        }
        if ($null -ne $observer) { $observer.Dispose() }
        $helperProcess.Dispose()
    }

    [pscustomobject][ordered]@{
        Result = 'PASS'
        HostOnly = $true
        RealAdbInvocations = 0
        Cases = 46
        DefaultAction = 'Status'
        ArmPair = '1.0->0.8'
        AtomicDeviceReplacement = $true
        ByteExactRestore = $true
        CrossProcessExclusive = $true
        AbandonedOwnerRecovery = $true
        ProductionArtifactsIsolated = $true
        StableTouched = $false
    }
} finally {
    try { Clear-TransactionArtifacts } catch { }
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
    }
    if (Test-Path -LiteralPath $testRoot) {
        $full = [IO.Path]::GetFullPath($testRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)
        Require ($full.StartsWith($temp + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($full).StartsWith('qc-rc8-render-scale-host-',
                [StringComparison]::Ordinal)) 'Refused to clean an unexpected host-test directory.'
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
