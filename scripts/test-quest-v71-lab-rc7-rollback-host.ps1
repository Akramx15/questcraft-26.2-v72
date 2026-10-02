#requires -Version 7.0
<# Host-only Fake-ADB tests for the exact RC7 Lab rollback gate. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC7_ROLLBACK_HOST_TEST] $Message" }
}

function Expect-Failure([scriptblock] $Operation, [string] $Pattern) {
    $script:LastFailure = ''
    try { & $Operation; return $false } catch {
        $script:LastFailure = $_.Exception.Message
        return $_.Exception.Message -match $Pattern
    }
}

$gate = Join-Path $PSScriptRoot 'quest-v71-lab-rc7-rollback.ps1'
Require (Test-Path -LiteralPath $gate -PathType Leaf) 'Rollback gate is missing.'

# Default invocation must be a genuine zero-device audit.
$audit = @(& $gate | Where-Object { $_.Result -ceq 'AUDIT_PASS' })
Require ($audit.Count -eq 1 -and [bool]$audit[0].HostOnly -and
    -not [bool]$audit[0].RollbackRequested -and [int]$audit[0].DeviceInvocations -eq 0 -and
    [string]$audit[0].Package -ceq 'com.qcxr.qcxr.canary262' -and
    [string]$audit[0].ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
    -not [bool]$audit[0].StableTouched -and -not [bool]$audit[0].Launched) `
    'Default rollback audit crossed its Host/Lab boundary.'
Require ([string]$audit[0].ApkSha256 -ceq
    '6AC3D0A1EECAE657367B427BF9A97983C68F6A0D01E166DD195694E3B0B0E7D7') `
    'Default rollback artifact identity drifted.'

$source = [IO.File]::ReadAllText($gate)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($gate,[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected rollback gate.'
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($required in @('Rollback','Serial','AdbPath','ApkSignerPath')) {
    Require ($parameters -ccontains $required) "Missing parameter: $required"
}
foreach ($forbidden in @('Package','ApkPath','VersionCode','VersionName','SignerSha256','Launch','Root')) {
    Require ($parameters -cnotcontains $forbidden) "Unsafe boundary override exposed: $forbidden"
}
Require ([regex]::Matches($source,"'install','-r'").Count -eq 1) `
    'Expected one exact install -r construction site.'
foreach ($bad in @("'install','-d'","'uninstall'","'pm','clear'","'shell','rm'",
        "'shell','su'","'shell','input'","'am','start'","'am','force-stop'",
        'Invoke-WebRequest','Start-BitsTransfer')) {
    Require (-not $source.Contains($bad)) "Forbidden operation exists: $bad"
}

. $gate
$temp = Join-Path ([IO.Path]::GetTempPath()) ('v71-rc7-rollback-host-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$fakePs1 = Join-Path $temp 'fake-adb.ps1'
$fakeCmd = Join-Path $temp 'fake-adb.cmd'
$signerPs1 = Join-Path $temp 'fake-signer.ps1'
$signerCmd = Join-Path $temp 'fake-signer.cmd'
$calls = Join-Path $temp 'calls.jsonl'
$counter = Join-Path $temp 'pull-count.txt'
$badApk = Join-Path $temp 'bad.apk'
[IO.File]::WriteAllBytes($badApk,[Text.Encoding]::ASCII.GetBytes('bad-apk'))

$fakeSource = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FakeArgs)
$entry = [ordered]@{Arguments=@($FakeArgs)} | ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:QC_RC7_CALLS,$entry+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
$scenario = [string]$env:QC_RC7_SCENARIO
if ($FakeArgs.Count -eq 1 -and $FakeArgs[0] -ceq 'devices') {
  'List of devices attached'
  if ($scenario -ceq 'none') { exit 0 }
  if ($scenario -ceq 'multiple') { "QUEST_RC7`tdevice"; "OTHER`tdevice"; exit 0 }
  if ($scenario -ceq 'offline') { "QUEST_RC7`toffline"; exit 0 }
  "QUEST_RC7`tdevice product:fake model:Quest_3"; exit 0
}
if ($FakeArgs.Count -eq 3 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC7' -and $FakeArgs[2] -ceq 'get-state') {
  'device'; exit 0
}
if ($FakeArgs.Count -eq 6 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC7' -and
    $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'pm' -and $FakeArgs[4] -ceq 'path' -and
    $FakeArgs[5] -ceq 'com.qcxr.qcxr.canary262') {
  'package:/data/app/~~fake/com.qcxr.qcxr.canary262-test/base.apk'
  if ($scenario -ceq 'split') { 'package:/data/app/~~fake/com.qcxr.qcxr.canary262-test/split_config.arm64.apk' }
  exit 0
}
if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC7' -and
    $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'pidof' -and
    $FakeArgs[4] -ceq 'com.qcxr.qcxr.canary262') {
  if ($scenario -ceq 'running') { '24680'; exit 0 }
  if ($scenario -ceq 'ambiguous-pid') { exit 0 }
  exit 1
}
if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC7' -and $FakeArgs[2] -ceq 'pull') {
  if ($scenario -ceq 'pull-fail') { [Console]::Error.WriteLine('injected'); exit 1 }
  $count = if (Test-Path $env:QC_RC7_COUNTER) {[int][IO.File]::ReadAllText($env:QC_RC7_COUNTER)} else {0}
  $source = if ($scenario -ceq 'post-corrupt' -and $count -ge 1) {$env:QC_RC7_BAD_APK} else {$env:QC_RC7_GOOD_APK}
  [IO.File]::Copy($source,$FakeArgs[4],$false)
  [IO.File]::WriteAllText($env:QC_RC7_COUNTER,[string]($count+1))
  '1 file pulled'; exit 0
}
if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC7' -and
    $FakeArgs[2] -ceq 'install' -and $FakeArgs[3] -ceq '-r') {
  if ($scenario -ceq 'install-fail') {'Failure [TEST]'; exit 1}
  'Performing Streamed Install'; 'Success'; exit 0
}
[Console]::Error.WriteLine('Unexpected argv: '+($FakeArgs -join '|')); exit 91
'@
$signerSource = @'
$sha='B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
if ($env:QC_RC7_SCENARIO -ceq 'wrong-signer') {$sha='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'}
'Verifies'
'Verified using v2 scheme (APK Signature Scheme v2): true'
'Signer #1 certificate SHA-256 digest: '+$sha
if ($env:QC_RC7_SCENARIO -ceq 'multi-signer') {'Signer #2 certificate SHA-256 digest: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'}
exit 0
'@
[IO.File]::WriteAllText($fakePs1,$fakeSource,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($signerPs1,$signerSource,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($fakeCmd,"@echo off`r`npwsh -NoProfile -File `"$fakePs1`" %*`r`nexit /b %ERRORLEVEL%`r`n",[Text.ASCIIEncoding]::new())
[IO.File]::WriteAllText($signerCmd,"@echo off`r`npwsh -NoProfile -File `"$signerPs1`" %*`r`nexit /b %ERRORLEVEL%`r`n",[Text.ASCIIEncoding]::new())

$env:QC_RC7_CALLS = $calls
$env:QC_RC7_COUNTER = $counter
$env:QC_RC7_GOOD_APK = $script:CandidatePath
$env:QC_RC7_BAD_APK = $badApk
$Rollback = $true; $Serial = 'QUEST_RC7'; $AdbPath = $fakeCmd; $ApkSignerPath = $signerCmd

function Reset-Scenario([string]$Name) {
    $env:QC_RC7_SCENARIO = $Name
    Remove-Item -LiteralPath $calls,$counter -Force -ErrorAction SilentlyContinue
}

try {
    foreach ($case in @(
        @{Name='none'; Pattern='exactly one endpoint'; Serial='auto'},
        @{Name='multiple'; Pattern='exactly one endpoint'; Serial='auto'},
        @{Name='offline'; Pattern='not authorized'; Serial='auto'},
        @{Name='running'; Pattern='user must exit'},
        @{Name='ambiguous-pid'; Pattern='ambiguous'},
        @{Name='split'; Pattern='split, or ambiguous'},
        @{Name='pull-fail'; Pattern='pull failed'},
        @{Name='wrong-signer'; Pattern='signer'},
        @{Name='multi-signer'; Pattern='signer'},
        @{Name='install-fail'; Pattern='rejected'},
        @{Name='post-corrupt'; Pattern='Post-rollback installed Lab APK'}
    )) {
        Reset-Scenario $case.Name
        $Serial = if ($case.ContainsKey('Serial')) { [string]$case.Serial } else { 'QUEST_RC7' }
        Require (Expect-Failure { Invoke-Rc7RollbackGate | Out-Null } $case.Pattern) `
            "Scenario did not fail closed: $($case.Name); observed=$script:LastFailure"
    }

    Reset-Scenario 'success'
    $Serial = 'QUEST_RC7'
    $result = Invoke-Rc7RollbackGate
    Require ([string]$result.Result -ceq 'ROLLED_BACK_AND_VERIFIED' -and
        [string]$result.Package -ceq 'com.qcxr.qcxr.canary262' -and
        [string]$result.ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
        -not [bool]$result.StableTouched -and -not [bool]$result.Launched) `
        'Success result crossed the Lab boundary.'
    $entries = @(Get-Content -LiteralPath $calls | ForEach-Object { $_ | ConvertFrom-Json })
    $installRows = @($entries | Where-Object { $_.Arguments.Count -ge 3 -and $_.Arguments[2] -ceq 'install' })
    Require ($installRows.Count -eq 1) 'Success path did not issue exactly one install.'
    $args = @($installRows[0].Arguments)
    Require ($args.Count -eq 5 -and $args[0] -ceq '-s' -and $args[1] -ceq 'QUEST_RC7' -and
        $args[2] -ceq 'install' -and $args[3] -ceq '-r' -and
        [IO.Path]::GetFullPath($args[4]) -ceq [IO.Path]::GetFullPath($script:CandidatePath)) `
        'Success path install argv drifted.'
    $allText = [IO.File]::ReadAllText($calls)
    Require (-not $allText.Contains('com.qcxr.qcxr.dev262')) 'Fake ADB observed Stable package.'
    [pscustomobject]@{
        Result='PASS'; HostOnly=$true; FakeAdb=$true; NegativeScenarios=11
        ExactInstallArgv=$true; RawDeviceActions=0; StableTouched=$false
    }
} finally {
    Remove-Item Env:QC_RC7_CALLS,Env:QC_RC7_COUNTER,Env:QC_RC7_GOOD_APK,
        Env:QC_RC7_BAD_APK,Env:QC_RC7_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
