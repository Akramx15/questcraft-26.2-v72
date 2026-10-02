#requires -Version 7.0
<# Host-only safety, parser, and Fake-ADB regression test for RC8 memory aggregates. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) {
        throw "[V71_RC8_MEMORY_AGGREGATE_HOST_TEST] $Message"
    }
}

function Test-RejectedBeforeAdb(
    [Parameter(Mandatory)][scriptblock] $Operation,
    [Parameter(Mandatory)][string] $ExpectedMessage
) {
    $script:LastRejectedMessage = ''
    try {
        & $Operation
        return $false
    } catch {
        $script:LastRejectedMessage = $_.Exception.Message
        return $_.Exception.Message.Contains(
            $ExpectedMessage, [StringComparison]::Ordinal)
    }
}

$collector = Join-Path $PSScriptRoot 'quest-v71-memory-aggregate-rc8.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildLockPath = Join-Path $repoRoot 'V71_LAB_RC8.lock.json'
$sentinelAdb = Join-Path $PSScriptRoot `
    '__quest-v71-memory-aggregate-rc8-host-test-no-adb__.exe'
$sentinelOutput = Join-Path $repoRoot `
    'artifacts\memory\__quest-v71-memory-aggregate-rc8-host-test-no-output__'

Require (Test-Path -LiteralPath $collector -PathType Leaf) `
    'The expanded-memory collector is missing.'
Require (Test-Path -LiteralPath $buildLockPath -PathType Leaf) `
    'The exact RC8 build lock is missing.'
Require (-not (Test-Path -LiteralPath $sentinelAdb)) `
    'The deliberately absent ADB sentinel unexpectedly exists.'
Require (-not (Test-Path -LiteralPath $sentinelOutput)) `
    'The deliberately absent output sentinel unexpectedly exists.'

$collectorTokens = $null
$collectorParseErrors = $null
$collectorAst = [Management.Automation.Language.Parser]::ParseFile(
    $collector, [ref]$collectorTokens, [ref]$collectorParseErrors)
Require ($collectorParseErrors.Count -eq 0) `
    'The PowerShell parser rejected the expanded-memory collector.'

$selfTokens = $null
$selfParseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $PSCommandPath, [ref]$selfTokens, [ref]$selfParseErrors)
Require ($selfParseErrors.Count -eq 0) `
    'The PowerShell parser rejected this Host test.'

$selfTestValues = @(& $collector -Serial 'offline-proof' -AdbPath $sentinelAdb)
$selfTests = @($selfTestValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($selfTests.Count -eq 1 -and
        [string]$selfTests[0].Result -ceq 'PASS') `
    'Default invocation did not return one PASS SelfTest record.'
$selfTest = $selfTests[0]
Require ([bool]$selfTest.HostOnly -and
        [int]$selfTest.DeviceInvocations -eq 0 -and
        [int]$selfTest.HostWrites -eq 0 -and
        [string]$selfTest.DefaultAction -ceq 'SelfTest') `
    'Default SelfTest touched a device, wrote output, or changed mode.'
Require ([int]$selfTest.DefaultDurationMinutes -eq 12 -and
        [string]$selfTest.AllowedDurationMinutes -ceq '10-15' -and
        [int]$selfTest.DefaultIntervalSeconds -eq 60) `
    'The bounded 10-to-15-minute capture contract drifted.'
Require ([bool]$selfTest.AggregateParserPassed -and
        [bool]$selfTest.DalvikDetailParserPassed -and
        [bool]$selfTest.TotalCrossCheckPassed -and
        [bool]$selfTest.LocalOnlyMeminfoCovered -and
        [bool]$selfTest.TargetGcAvoidanceCovered -and
        [bool]$selfTest.NoRuntimeLogReadCovered -and
        [bool]$selfTest.SystemMeminfoParserPassed -and
        [bool]$selfTest.SmapsRollupParserPassed -and
        [bool]$selfTest.SmapsRollupOptionalWithoutRoot -and
        [bool]$selfTest.PidFenceCovered -and
        [bool]$selfTest.ProcessStartFenceCovered -and
        [bool]$selfTest.ExactRc8LockCovered -and
        [bool]$selfTest.SanitizedReceiptCovered -and
        [bool]$selfTest.RawRowsDiscarded) `
    'SelfTest did not cover every parser, fence, and sanitization boundary.'
Require (-not (Test-Path -LiteralPath $sentinelAdb) -and
        -not (Test-Path -LiteralPath $sentinelOutput)) `
    'Default SelfTest resolved ADB or created Host output.'
$statusValues = @(& $collector -Action Status -Serial 'offline-proof' `
    -AdbPath $sentinelAdb)
$status = @($statusValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($status.Count -eq 1 -and
        [string]$status[0].Result -ceq 'PASS' -and
        [bool]$status[0].HostOnly -and
        [string]$status[0].Candidate -ceq 'RC8' -and
        [int]$status[0].DeviceInvocations -eq 0 -and
        [int]$status[0].HostWrites -eq 0 -and
        -not [bool]$status[0].StableAccessAllowed -and
        -not [bool]$status[0].RootRequired -and
        -not [bool]$status[0].JfrArmingSupported) `
    'Host Status resolved ADB, wrote output, or weakened the safety boundary.'
Require (-not (Test-Path -LiteralPath $sentinelAdb) -and
        -not (Test-Path -LiteralPath $sentinelOutput)) `
    'Host Status touched ADB or created Host output.'
$mixedCaseValues = @(& $collector -Action 'sElFtEsT' -Serial 'offline-proof' `
    -AdbPath $sentinelAdb)
$mixedCaseSelfTest = @($mixedCaseValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($mixedCaseSelfTest.Count -eq 1 -and
        [string]$mixedCaseSelfTest[0].Result -ceq 'PASS' -and
        [bool]$mixedCaseSelfTest[0].HostOnly -and
        [int]$mixedCaseSelfTest[0].DeviceInvocations -eq 0 -and
        [int]$mixedCaseSelfTest[0].HostWrites -eq 0) `
    'A case-insensitive SelfTest selection fell through to Capture.'

$missingDeviceReadRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput | Out-Null
} 'Capture requires explicit -AllowDeviceRead.'
Require $missingDeviceReadRejected `
    'Capture did not require explicit read-only device authorization.'

$missingHostOutputRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput -AllowDeviceRead | Out-Null
} 'Capture requires explicit -ConfirmExactRc8Lab.'
Require $missingHostOutputRejected `
    'Capture did not require the exact RC8 confirmation switch.'

$missingHostOutputRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput -AllowDeviceRead `
        -ConfirmExactRc8Lab | Out-Null
} 'Capture requires explicit -AllowHostOutput.'
Require $missingHostOutputRejected `
    'Capture did not require explicit Host-output authorization.'

$unsafeOutputRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $repoRoot -AllowDeviceRead -ConfirmExactRc8Lab `
        -AllowHostOutput | Out-Null
} 'Output must be a new child directory under artifacts/memory.'
Require $unsafeOutputRejected `
    'Capture did not reject an output directory outside its narrow boundary.'
$missingExplicitAdbRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput -AllowDeviceRead -ConfirmExactRc8Lab `
        -AllowHostOutput | Out-Null
} 'The explicitly requested ADB executable was not found.'
Require $missingExplicitAdbRejected `
    'An absent explicit ADB path fell back to another executable.'
Require (-not (Test-Path -LiteralPath $sentinelAdb) -and
        -not (Test-Path -LiteralPath $sentinelOutput)) `
    'A pre-ADB rejection fixture touched ADB or created Host output.'

$source = [IO.File]::ReadAllText($collector)
Require ($source.Contains("[string] `$Action = 'SelfTest'",
            [StringComparison]::Ordinal) -and
        $source.Contains('[ValidateRange(10, 15)]',
            [StringComparison]::Ordinal) -and
        $source.Contains("'dumpsys', 'meminfo', '-a', '--local', [string]`$ExpectedPid",
            [StringComparison]::Ordinal)) `
    'The default mode, duration fence, or expanded meminfo command drifted.'
Require ($source.Contains('Assert-ProcessFence $ExpectedPid $ExpectedStartTicks',
            [StringComparison]::Ordinal) -and
        $source.Contains('Assert-ExactDeviceIdentity',
            [StringComparison]::Ordinal) -and
        $source.Contains('Assert-SanitizedReceipt $receipt $json',
            [StringComparison]::Ordinal)) `
    'The process, exact-build, or receipt fence is missing.'
Require ($source.Contains('Invoke-Shell @(''cat'', "/proc/$ProcessId/task/*/comm")',
            [StringComparison]::Ordinal) -and
        -not $source.Contains("Invoke-Shell @('sh', '-c'",
            [StringComparison]::Ordinal) -and
        $source.Contains('App Summary for pid\s*:\s*(?<pid>[0-9]+)',
            [StringComparison]::Ordinal)) `
    'The real-adb argv-safe JVM probe or Android App Summary parser regressed.'

$literalValues = @($collectorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
$forbiddenDeviceVerbs = @(
    'am', 'cmd', 'monkey', 'start', 'stop', 'force-stop', 'install', 'uninstall',
    'clear', 'push', 'pull', 'sync', 'reboot', 'root', 'remount', 'disable-verity',
    'setprop', 'settings', 'rm', 'mv', 'cp', 'mkdir', 'touch', 'chmod', 'chown',
    'dd', 'tee'
)
foreach ($verb in $forbiddenDeviceVerbs) {
    Require ($literalValues -cnotcontains $verb) `
        "A prohibited device-operation token is callable: $verb."
}
Require ($literalValues -cnotcontains 'logcat') `
    'The collector must not collect an unfiltered device log stream.'
Require (-not $source.Contains("'exec-out'", [StringComparison]::Ordinal) -and
        $source.Contains('[IO.File]::WriteAllText($temporary, $Json + [Environment]::NewLine,',
            [StringComparison]::Ordinal)) `
    'The no-log-read boundary or sanitized-only writer drifted.'
foreach ($identityValue in @(
        'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416',
        'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A',
        'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB',
        'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9')) {
    Require ($source.Contains($identityValue, [StringComparison]::Ordinal)) `
        'An exact RC8 artifact/signer identity pin is missing.'
}
Require ($source.Contains('"/proc/$ExpectedPid/smaps_rollup"',
            [StringComparison]::Ordinal) -and
        -not $source.Contains('$script:GameLogPath',
            [StringComparison]::Ordinal) -and
        -not $source.Contains("'logcat'", [StringComparison]::Ordinal) -and
        -not $source.Contains("'smaps'", [StringComparison]::Ordinal)) `
    'The aggregate-only smaps/log boundary drifted.'

$selfTestJson = $selfTest | ConvertTo-Json -Depth 8 -Compress
$buildLock = Get-Content -Raw -LiteralPath $buildLockPath | ConvertFrom-Json
Require (-not $selfTestJson.Contains([string]$buildLock.target.package,
            [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains([string]$buildLock.target.forbiddenStablePackage,
            [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains($sentinelAdb, [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains('/sdcard/', [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains('/data/', [StringComparison]::Ordinal) -and
        $selfTestJson -notmatch '(?i)account|world|server') `
    'The public SelfTest record exposed a prohibited identifier or path.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('quest-v71-rc8-memory-fake-adb-' + [guid]::NewGuid().ToString('N'))
$fakeAdb = Join-Path $fixtureRoot 'adb.cmd'
$fakeLog = Join-Path $fixtureRoot 'adb-invocations.txt'
$fakeOutputOne = Join-Path $repoRoot `
    ('artifacts\memory\__rc8-fake-adb-wrong-version-' +
        [guid]::NewGuid().ToString('N'))
$fakeOutputTwo = Join-Path $repoRoot `
    ('artifacts\memory\__rc8-fake-adb-wrong-apk-' +
        [guid]::NewGuid().ToString('N'))
$fakeOutputThree = Join-Path $repoRoot `
    ('artifacts\memory\__rc8-fake-adb-wrong-core-' +
        [guid]::NewGuid().ToString('N'))
$fakeOutputFour = Join-Path $repoRoot `
    ('artifacts\memory\__rc8-fake-adb-wrong-veq-' +
        [guid]::NewGuid().ToString('N'))
$oldFakeLog = $env:QC_RC8_MEMORY_FAKE_ADB_LOG
$oldFakeMode = $env:QC_RC8_MEMORY_FAKE_ADB_MODE
try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $batch = @'
@echo off
echo %~1 %~2 %~3 %~4 %~5>>"%QC_RC8_MEMORY_FAKE_ADB_LOG%"
if "%~1"=="devices" (
  echo List of devices attached
  echo fixture-quest device
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="pidof" if "%~5"=="com.qcxr.qcxr.canary262" (
  echo 4242
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="getconf" if "%~5"=="CLK_TCK" (
  echo 100
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="cat" if "%~5"=="/proc/uptime" (
  echo 1000.00 500.00
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="date" if "%~5"=="+%%s" (
  echo 2000000000
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="cat" if "%~5"=="/proc/4242/stat" (
  echo 4242 ^(fixture^) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 99900 20
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="cat" if "%~5"=="/proc/4242/task/*/comm" (
  echo QuestCraft-JVM
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="dumpsys" if "%~5"=="package" if "%~6"=="com.qcxr.qcxr.canary262" (
  echo Packages:
  echo   versionCode=71 minSdk=29 targetSdk=34
  if "%QC_RC8_MEMORY_FAKE_ADB_MODE%"=="wrong-version" (
    echo   versionName=6.0.1-26.2-vivecraft-personal.12-rc.7
  ) else (
    echo   versionName=6.0.1-26.2-vivecraft-personal.12-rc.8
  )
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="pm" if "%~5"=="path" if "%~6"=="com.qcxr.qcxr.canary262" (
  echo package:/data/app/~~fixture/com.qcxr.qcxr.canary262-fixture/base.apk
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="sha256sum" if "%~5"=="/data/app/~~fixture/com.qcxr.qcxr.canary262-fixture/base.apk" (
  if "%QC_RC8_MEMORY_FAKE_ADB_MODE%"=="wrong-apk" (
    echo 0000000000000000000000000000000000000000000000000000000000000000  /data/app/~~fixture/com.qcxr.qcxr.canary262-fixture/base.apk
  ) else (
    echo A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416  /data/app/~~fixture/com.qcxr.qcxr.canary262-fixture/base.apk
  )
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="sha256sum" if "%~5"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft.jar" (
  if "%QC_RC8_MEMORY_FAKE_ADB_MODE%"=="wrong-core" (
    echo 0000000000000000000000000000000000000000000000000000000000000000  /sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft.jar
  ) else (
    echo ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB  /sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft.jar
  )
  exit /b 0
)
if "%~1"=="-s" if "%~2"=="fixture-quest" if "%~3"=="shell" if "%~4"=="sha256sum" if "%~5"=="/sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft-Essentials-Quest.jar" (
  if "%QC_RC8_MEMORY_FAKE_ADB_MODE%"=="wrong-veq" (
    echo 0000000000000000000000000000000000000000000000000000000000000000  /sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft-Essentials-Quest.jar
  ) else (
    echo FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9  /sdcard/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2/mods/Vivecraft-Essentials-Quest.jar
  )
  exit /b 0
)
exit /b 87
'@
    [IO.File]::WriteAllText($fakeAdb, $batch, [Text.ASCIIEncoding]::new())
    $env:QC_RC8_MEMORY_FAKE_ADB_LOG = $fakeLog

    $env:QC_RC8_MEMORY_FAKE_ADB_MODE = 'wrong-version'
    $wrongVersionRejected = Test-RejectedBeforeAdb {
        & $collector -Action Capture -Serial fixture-quest -AdbPath $fakeAdb `
            -OutputDirectory $fakeOutputOne -AllowDeviceRead `
            -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'The installed application is not exact RC8.'
    $wrongVersionCalls = if (Test-Path -LiteralPath $fakeLog) {
        [string]::Join(' | ', [IO.File]::ReadAllLines($fakeLog))
    } else { '<no calls recorded>' }
    Require $wrongVersionRejected `
        "Fake ADB did not fail closed on a wrong installed RC8 version: $script:LastRejectedMessage; calls=$wrongVersionCalls"
    Require (-not (Test-Path -LiteralPath $fakeOutputOne)) `
        'Wrong-version Fake ADB created a Host evidence directory.'

    $env:QC_RC8_MEMORY_FAKE_ADB_MODE = 'wrong-apk'
    $wrongApkRejected = Test-RejectedBeforeAdb {
        & $collector -Action Capture -Serial fixture-quest -AdbPath $fakeAdb `
            -OutputDirectory $fakeOutputTwo -AllowDeviceRead `
            -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'The installed APK digest is not exact RC8.'
    Require $wrongApkRejected `
        "Fake ADB did not fail closed on a wrong installed APK digest: $script:LastRejectedMessage"
    Require (-not (Test-Path -LiteralPath $fakeOutputTwo)) `
        'Wrong-APK Fake ADB created a Host evidence directory.'

    $env:QC_RC8_MEMORY_FAKE_ADB_MODE = 'wrong-core'
    $wrongCoreRejected = Test-RejectedBeforeAdb {
        & $collector -Action Capture -Serial fixture-quest -AdbPath $fakeAdb `
            -OutputDirectory $fakeOutputThree -AllowDeviceRead `
            -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'The persistent Core digest is not exact RC8.'
    Require $wrongCoreRejected `
        "Fake ADB did not fail closed on a wrong Core digest: $script:LastRejectedMessage"
    Require (-not (Test-Path -LiteralPath $fakeOutputThree)) `
        'Wrong-Core Fake ADB created a Host evidence directory.'

    $env:QC_RC8_MEMORY_FAKE_ADB_MODE = 'wrong-veq'
    $wrongVeqRejected = Test-RejectedBeforeAdb {
        & $collector -Action Capture -Serial fixture-quest -AdbPath $fakeAdb `
            -OutputDirectory $fakeOutputFour -AllowDeviceRead `
            -ConfirmExactRc8Lab -AllowHostOutput | Out-Null
    } 'The persistent companion digest is not exact RC8.'
    Require $wrongVeqRejected `
        "Fake ADB did not fail closed on a wrong VEQ digest: $script:LastRejectedMessage"
    Require (-not (Test-Path -LiteralPath $fakeOutputFour)) `
        'Wrong-VEQ Fake ADB created a Host evidence directory.'

    $fakeCalls = [IO.File]::ReadAllLines($fakeLog)
    Require ($fakeCalls.Count -gt 0 -and
            @($fakeCalls | Where-Object {
                $_ -match '(?i)(?:^|\s)(install|uninstall|push|pull|start|stop|force-stop|clear|root|su|magisk|reboot|rm|mkdir|touch|chmod|chown|dd|tee)(?:\s|$)'
            }).Count -eq 0) `
        'Fake ADB observed a prohibited device command.'
    Require (@($fakeCalls | Where-Object {
                $_.Contains('com.qcxr.qcxr.dev262', [StringComparison]::Ordinal)
            }).Count -eq 0) `
        'Fake ADB observed an access to the forbidden Stable package.'
    Require (@($fakeCalls | Where-Object {
                $_ -match '(?i)latest\.log|logcat|jfr|smaps(?:$|\s|/)(?!_rollup)'
            }).Count -eq 0) `
        'Fake ADB observed a raw runtime-log, JFR, or mapping read.'
} finally {
    $env:QC_RC8_MEMORY_FAKE_ADB_LOG = $oldFakeLog
    $env:QC_RC8_MEMORY_FAKE_ADB_MODE = $oldFakeMode
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    Require ($resolvedFixture.StartsWith($resolvedTemp,
            [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedFixture).StartsWith(
                'quest-v71-rc8-memory-fake-adb-',
                [StringComparison]::Ordinal)) `
        'The Fake-ADB fixture cleanup target escaped its dedicated Temp directory.'
    if (Test-Path -LiteralPath $resolvedFixture) {
        [IO.Directory]::Delete($resolvedFixture, $true)
    }
}

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    HostWrites = 0
    PowerShellParsePassed = $true
    DefaultSelfTestPassed = $true
    ExplicitAuthorizationFencesPassed = $true
    SafeOutputBoundaryPassed = $true
    ReadOnlyDeviceCommandAuditPassed = $true
    ExpandedAggregateParserPassed = $true
    PidAndProcessStartFencesPassed = $true
    ExactRc8FencePassed = $true
    SanitizedReceiptBoundaryPassed = $true
    LocalOnlyTargetGcAvoidancePassed = $true
    NoRuntimeLogReadPassed = $true
    FakeAdbWrongVersionRejected = $true
    FakeAdbWrongApkRejected = $true
    FakeAdbWrongCoreRejected = $true
    FakeAdbWrongVeqRejected = $true
    FakeAdbStableBoundaryPassed = $true
    FakeAdbNoMutationCommandsPassed = $true
}
