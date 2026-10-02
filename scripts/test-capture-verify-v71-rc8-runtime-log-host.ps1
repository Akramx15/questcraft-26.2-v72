#requires -Version 7.0
<# Host-only Fake-ADB regression tests for RC8 runtime capture and purge. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Require([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw "[V71_RC8_CAPTURE_HOST_TEST] $Message"}
}
function Expect-Failure([scriptblock]$Operation,[string]$Pattern) {
    $script:LastFailure=''
    try {& $Operation; return $false} catch {$script:LastFailure=$_.Exception.Message;return $_.Exception.Message -match $Pattern}
}

$wrapper = Join-Path $PSScriptRoot 'capture-verify-v71-rc8-runtime-log.ps1'
Require (Test-Path -LiteralPath $wrapper -PathType Leaf) 'Capture wrapper is missing.'
$plan = @(& $wrapper | Where-Object {$_.Result -ceq 'PLAN_PASS'})
Require ($plan.Count -eq 1 -and [bool]$plan[0].HostOnly -and
    -not [bool]$plan[0].CaptureRequested -and [int]$plan[0].DeviceInvocations -eq 0 -and
    [string]$plan[0].Package -ceq 'com.qcxr.qcxr.canary262' -and
    [string]$plan[0].ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
    -not [bool]$plan[0].RawLogPersisted -and -not [bool]$plan[0].StableTouched) `
    'Default invocation crossed its Host/Lab/privacy boundary.'

$source=[IO.File]::ReadAllText($wrapper)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($wrapper,[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected capture wrapper.'
$parameters=@($ast.ParamBlock.Parameters|ForEach-Object{$_.Name.VariablePath.UserPath})
foreach($required in @('Capture','Serial','AdbPath')){Require ($parameters -ccontains $required) "Missing parameter: $required"}
foreach($bad in @('Package','RemoteLog','Profile','AccountPath','StablePackage','Root','Write','Launch')){
    Require ($parameters -cnotcontains $bad) "Unsafe override exposed: $bad"
}
foreach($bad in @("'install'","'uninstall'","'pm','clear'","'shell','rm'","'shell','su'",
        "'shell','input'","'am','start'","'am','force-stop'","'logcat'")){
    Require (-not $source.Contains($bad)) "Forbidden device operation exists: $bad"
}
Require ([regex]::Matches($source,'''pull'',\$script:RemoteLog').Count -eq 1) `
    'Capture wrapper must have one exact remote-log pull site.'

. $wrapper
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('v71-rc8-capture-host-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot)|Out-Null
$fakePs1=Join-Path $testRoot 'fake-adb.ps1'
$fakeCmd=Join-Path $testRoot 'fake-adb.cmd'
$fixture=Join-Path $testRoot 'latest.log'
$calls=Join-Path $testRoot 'calls.jsonl'
$pidCounter=Join-Path $testRoot 'pid-count.txt'
$statCounter=Join-Path $testRoot 'stat-count.txt'
$fixtureText=@'
[main/INFO]: Loading Minecraft 26.2 with Fabric Loader 0.19.4
[main/INFO]: - vivecraft 26.2-1.3.15+qc.v71.rc8-mining
[main/INFO]: - vivecraft_essentials_quest 0.7.0-v71.rc6
[Render thread/INFO]: Using graphics backend Vulkan, test
[Render thread/INFO]: Vivecraft: OpenXR initialized & VR connected.
[Render thread/INFO]: Vivecraft: OpenXR submitted frame 42 projectionLayer=true
'@
[IO.File]::WriteAllText($fixture,$fixtureText,[Text.UTF8Encoding]::new($false))

$fakeSource=@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$FakeArgs)
$entry=[ordered]@{Arguments=@($FakeArgs)}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:QC_RC8_CAPTURE_CALLS,$entry+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
$scenario=[string]$env:QC_RC8_CAPTURE_SCENARIO
if($FakeArgs.Count -eq 1 -and $FakeArgs[0] -ceq 'devices'){
 'List of devices attached'
 if($scenario -ceq 'none'){exit 0}
 if($scenario -ceq 'multiple'){"QUEST_RC8`tdevice";"OTHER`tdevice";exit 0}
 if($scenario -ceq 'offline'){"QUEST_RC8`toffline";exit 0}
 "QUEST_RC8`tdevice product:fake model:Quest_3";exit 0
}
if($FakeArgs.Count -eq 3 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'get-state'){'device';exit 0}
if($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'pidof'){
 $n=if(Test-Path $env:QC_RC8_PID_COUNT){[int][IO.File]::ReadAllText($env:QC_RC8_PID_COUNT)}else{0}
 [IO.File]::WriteAllText($env:QC_RC8_PID_COUNT,[string]($n+1))
 if($scenario -ceq 'no-pid'){exit 1}
 if($scenario -ceq 'multi-pid'){'123 456';exit 0}
 if($scenario -ceq 'pid-changed' -and $n -ge 1){'456';exit 0}
 '123';exit 0
}
if($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'getconf'){'100';exit 0}
if($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'cat' -and $FakeArgs[4] -ceq '/proc/uptime'){'1000.00 500.00';exit 0}
if($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'date'){'2000';exit 0}
if($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'cat' -and $FakeArgs[4] -match '^/proc/[0-9]+/stat$'){
 $values=@('S')+(@('0')*18)+@($(if($scenario -ceq 'incarnation-changed' -and $FakeArgs[4] -match '/456/'){'60000'}else{'50000'}))
 '123 (fake process) '+($values -join ' ');exit 0
}
if($FakeArgs.Count -eq 7 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and $FakeArgs[3] -ceq 'stat'){
 $n=if(Test-Path $env:QC_RC8_STAT_COUNT){[int][IO.File]::ReadAllText($env:QC_RC8_STAT_COUNT)}else{0}
 [IO.File]::WriteAllText($env:QC_RC8_STAT_COUNT,[string]($n+1))
 $type=if($scenario -ceq 'symlink'){'symbolic link'}else{'regular file'}
 $size=(Get-Item -LiteralPath $env:QC_RC8_FIXTURE).Length
 if($scenario -ceq 'oversized'){$size=70000000}
 $mtime=if($scenario -ceq 'stale'){'1400'}else{'1501'}
 $inode=if($scenario -ceq 'replaced' -and $n -ge 1){'78'}else{'77'}
 "${type}_${size}_${mtime}_${mtime}_${inode}";exit 0
}
if($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'pull'){
 if($scenario -ceq 'pull-fail'){[Console]::Error.WriteLine('injected');exit 1}
 $src=if($scenario -ceq 'bad-log'){$env:QC_RC8_BAD_LOG}else{$env:QC_RC8_FIXTURE}
 [IO.File]::Copy($src,$FakeArgs[4],$false);'1 file pulled';exit 0
}
[Console]::Error.WriteLine('Unexpected argv: '+($FakeArgs -join '|'));exit 91
'@
[IO.File]::WriteAllText($fakePs1,$fakeSource,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($fakeCmd,"@echo off`r`npwsh -NoProfile -File `"$fakePs1`" %*`r`nexit /b %ERRORLEVEL%`r`n",[Text.ASCIIEncoding]::new())
$badLog=Join-Path $testRoot 'bad.log';[IO.File]::WriteAllText($badLog,'not rc8',[Text.UTF8Encoding]::new($false))
$env:QC_RC8_CAPTURE_CALLS=$calls;$env:QC_RC8_PID_COUNT=$pidCounter;$env:QC_RC8_STAT_COUNT=$statCounter
$env:QC_RC8_FIXTURE=$fixture;$env:QC_RC8_BAD_LOG=$badLog
$Capture=$true;$Serial='QUEST_RC8';$AdbPath=$fakeCmd

function Reset-Scenario([string]$Name){
 $env:QC_RC8_CAPTURE_SCENARIO=$Name
 Remove-Item -LiteralPath $calls,$pidCounter,$statCounter -Force -ErrorAction SilentlyContinue
}
function Get-RawTempNames{
 @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'quest-v71-rc8-runtime-*' -ErrorAction SilentlyContinue|ForEach-Object{$_.FullName})
}

try{
 foreach($case in @(
  @{Name='none';Pattern='exactly one endpoint';Serial='auto'},
  @{Name='multiple';Pattern='exactly one endpoint';Serial='auto'},
  @{Name='offline';Pattern='not authorized';Serial='auto'},
  @{Name='no-pid';Pattern='exactly one running PID'},
  @{Name='multi-pid';Pattern='exactly one running PID'},
  @{Name='stale';Pattern='not bound'},
  @{Name='symlink';Pattern='non-regular'},
  @{Name='oversized';Pattern='exceeds 64 MiB'},
  @{Name='pull-fail';Pattern='pull failed'},
  @{Name='bad-log';Pattern='truncated'},
  @{Name='pid-changed';Pattern='PID changed'},
  @{Name='replaced';Pattern='replaced, truncated'}
 )){
  Reset-Scenario $case.Name
  $Serial=if($case.ContainsKey('Serial')){$case.Serial}else{'QUEST_RC8'}
  $before=@(Get-RawTempNames)
  Require (Expect-Failure {Invoke-Rc8RuntimeCapture|Out-Null} $case.Pattern) `
    "Scenario did not fail closed: $($case.Name); observed=$script:LastFailure"
  $after=@(Get-RawTempNames)
  Require (($before -join '|') -ceq ($after -join '|')) "Scenario retained raw Temp data: $($case.Name)"
 }
 Reset-Scenario 'success';$Serial='QUEST_RC8'
 $before=@(Get-RawTempNames)
 $result=Invoke-Rc8RuntimeCapture
 $after=@(Get-RawTempNames)
 Require ([string]$result.Result -ceq 'CAPTURE_VERIFIED_AND_PURGED' -and
  [string]$result.Package -ceq 'com.qcxr.qcxr.canary262' -and
  -not [bool]$result.RawLogPersisted -and -not [bool]$result.StableTouched -and
  [string]$result.Vivecraft -ceq '26.2-1.3.15+qc.v71.rc8-mining') 'Success result drifted.'
 Require (($before -join '|') -ceq ($after -join '|')) 'Success retained raw Temp data.'
 $entries=@(Get-Content -LiteralPath $calls|ForEach-Object{$_|ConvertFrom-Json})
 $pulls=@($entries|Where-Object{$_.Arguments.Count -ge 3 -and $_.Arguments[2] -ceq 'pull'})
 Require ($pulls.Count -eq 1 -and [string]$pulls[0].Arguments[3] -ceq
  '/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/logs/latest.log') `
  'Success did not pull one exact Lab latest.log.'
 Require (-not ([IO.File]::ReadAllText($calls).Contains('com.qcxr.qcxr.dev262'))) 'Fake ADB observed Stable package.'
 [pscustomobject]@{Result='PASS';HostOnly=$true;FakeAdb=$true;NegativeScenarios=12;ExactLogPull=$true;RawLogPersisted=$false;StableTouched=$false}
}finally{
 Remove-Item Env:QC_RC8_CAPTURE_CALLS,Env:QC_RC8_PID_COUNT,Env:QC_RC8_STAT_COUNT,
  Env:QC_RC8_FIXTURE,Env:QC_RC8_BAD_LOG,Env:QC_RC8_CAPTURE_SCENARIO -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
