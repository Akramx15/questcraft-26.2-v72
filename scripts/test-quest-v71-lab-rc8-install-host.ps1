#requires -Version 7.0
<# Host-only Fake-ADB regression tests for the fixed RC8 Lab install gate. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC8_LAB_INSTALL_HOST_TEST] $Message" }
}

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock] $Operation, [string] $Pattern = '')
    $script:LastExpectedFailureMessage = ''
    try {
        & $Operation
        return $false
    } catch {
        $script:LastExpectedFailureMessage = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($Pattern)) { return $true }
        return $_.Exception.Message -match $Pattern
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$gatePath = Join-Path $PSScriptRoot 'quest-v71-lab-rc8-install.ps1'
$apkPath = Join-Path $repoRoot 'QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-Lab-26.2-v71-rc.8-mining-local.apk'
Require (Test-Path -LiteralPath $gatePath -PathType Leaf) 'The RC8 Lab install gate is missing.'
Require (Test-Path -LiteralPath $apkPath -PathType Leaf) 'The exact RC8 Lab APK is missing.'

# The default invocation is the real Host audit. It must not even resolve ADB.
$auditValues = @(& $gatePath)
$audits = @($auditValues | Where-Object {
    $null -ne $_.PSObject.Properties['Result'] -and
    [string]$_.Result -ceq 'AUDIT_PASS'
})
Require ($audits.Count -eq 1) 'Default audit did not return one PASS result.'
$audit = $audits[0]
Require ([bool]$audit.DryRun -and [bool]$audit.HostOnly -and
    -not [bool]$audit.InstallRequested -and [int]$audit.DeviceInvocations -eq 0) `
    'Default mode was not a zero-device Host-only dry run.'
Require ([string]$audit.Package -ceq 'com.qcxr.qcxr.canary262' -and
    [string]$audit.ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
    -not [bool]$audit.StableTouched -and -not [bool]$audit.Launched) `
    'Default audit crossed its Lab/Stable/launch boundary.'
Require ([string]$audit.ApkSha256 -ceq 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416' -and
    [int]$audit.VersionCode -eq 71 -and
    [string]$audit.VersionName -ceq '6.0.1-26.2-vivecraft-personal.12-rc.8' -and
    [string]$audit.SignerSha256 -ceq 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A') `
    'Default audit identity drifted.'

$source = [IO.File]::ReadAllText($gatePath)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $gatePath, [ref]$tokens, [ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected the RC8 Lab install gate.'
$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
foreach ($required in @('Install','Serial','AdbPath','ApkSignerPath')) {
    Require ($parameterNames -ccontains $required) "Required gate parameter is missing: $required"
}
foreach ($forbidden in @('Package','ApkPath','VersionCode','VersionName','SignerSha256','Launch','Root')) {
    Require ($parameterNames -cnotcontains $forbidden) "A fixed boundary exposes an override: $forbidden"
}
Require ([regex]::Matches($source, "'install','-r'").Count -eq 1) `
    'The gate does not have exactly one install -r argv construction site.'
foreach ($forbiddenPattern in @(
    "'install','-d'",
    "'install','-r','-d'",
    "'uninstall'",
    "'pm','clear'",
    "'shell','rm'",
    "'shell','su'",
    "'shell','input'",
    "'shell','monkey'",
    "'shell','am','force-stop'",
    "'am','start'",
    'Invoke-WebRequest',
    'Start-BitsTransfer'
)) {
    Require (-not $source.Contains($forbiddenPattern)) `
        "Forbidden executable boundary is present: $forbiddenPattern"
}
Require ($source.Contains("`$script:LabPackage = 'com.qcxr.qcxr.canary262'") -and
    $source.Contains("`$script:ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'")) `
    'Lab or Stable package pin is missing.'
Require ($source.Contains("if (-not `$Install.IsPresent)")) `
    'Dry-run is not the default control path.'

# Dot-source only after the default Host audit so the internal fault boundaries
# can be exercised without spawning a real device process.
. $gatePath

$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('quest-v71-rc8-install-host-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$fakeAdbPs1 = Join-Path $testRoot 'fake-adb.ps1'
$fakeAdbCmd = Join-Path $testRoot 'fake-adb.cmd'
$fakeSignerPs1 = Join-Path $testRoot 'fake-apksigner.ps1'
$fakeSignerCmd = Join-Path $testRoot 'fake-apksigner.cmd'
$badApkPath = Join-Path $testRoot 'bad.apk'
$callLog = Join-Path $testRoot 'adb-calls.jsonl'
$pullCounter = Join-Path $testRoot 'pull-count.txt'
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllBytes($badApkPath, [Text.Encoding]::ASCII.GetBytes('not-the-reviewed-rc8-apk'))

$fakeAdbSource = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $FakeArgs)
$ErrorActionPreference = 'Stop'
$entry = [ordered]@{ Arguments = @($FakeArgs) } | ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:QC_RC8_FAKE_ADB_LOG, $entry + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$scenario = [string]$env:QC_RC8_FAKE_SCENARIO

if ($FakeArgs.Count -eq 1 -and $FakeArgs[0] -ceq 'devices') {
    Write-Output 'List of devices attached'
    if ($scenario -ceq 'no-device') { exit 0 }
    if ($scenario -ceq 'multiple-devices') {
        Write-Output "QUEST_A`tdevice"
        Write-Output "QUEST_B`tdevice"
        exit 0
    }
    if ($scenario -ceq 'offline-device') {
        Write-Output "QUEST_RC8`toffline"
        exit 0
    }
    Write-Output "QUEST_RC8`tdevice product:fake model:Quest_3"
    exit 0
}

if ($FakeArgs.Count -eq 3 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'get-state') {
    Write-Output 'device'
    exit 0
}

if ($FakeArgs.Count -eq 6 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and
    $FakeArgs[3] -ceq 'pm' -and $FakeArgs[4] -ceq 'path' -and
    $FakeArgs[5] -ceq 'com.qcxr.qcxr.canary262') {
    if ($scenario -ceq 'split-apk') {
        Write-Output 'package:/data/app/~~fake/com.qcxr.qcxr.canary262-test/base.apk'
        Write-Output 'package:/data/app/~~fake/com.qcxr.qcxr.canary262-test/split_config.arm64_v8a.apk'
        exit 0
    }
    Write-Output 'package:/data/app/~~fake/com.qcxr.qcxr.canary262-test/base.apk'
    exit 0
}

if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'shell' -and
    $FakeArgs[3] -ceq 'pidof' -and
    $FakeArgs[4] -ceq 'com.qcxr.qcxr.canary262') {
    if ($scenario -ceq 'running-app') {
        Write-Output '24680'
        exit 0
    }
    if ($scenario -ceq 'pidof-blank-success') { exit 0 }
    exit 1
}

if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'pull') {
    if ($scenario -ceq 'pull-failure') {
        Write-Error 'injected pull failure'
        exit 1
    }
    $count = 0
    if (Test-Path -LiteralPath $env:QC_RC8_FAKE_PULL_COUNT) {
        $count = [int][IO.File]::ReadAllText($env:QC_RC8_FAKE_PULL_COUNT)
    }
    $source = $env:QC_RC8_FAKE_GOOD_APK
    if ($scenario -ceq 'post-wrong-hash' -and $count -ge 1) {
        $source = $env:QC_RC8_FAKE_BAD_APK
    }
    [IO.File]::Copy($source, $FakeArgs[4], $false)
    [IO.File]::WriteAllText($env:QC_RC8_FAKE_PULL_COUNT, [string]($count + 1))
    Write-Output '1 file pulled'
    exit 0
}

if ($FakeArgs.Count -eq 5 -and $FakeArgs[0] -ceq '-s' -and
    $FakeArgs[1] -ceq 'QUEST_RC8' -and $FakeArgs[2] -ceq 'install' -and
    $FakeArgs[3] -ceq '-r') {
    if ($scenario -ceq 'install-failure') {
        Write-Output 'Failure [INSTALL_FAILED_TEST_ONLY]'
        exit 1
    }
    Write-Output 'Performing Streamed Install'
    Write-Output 'Success'
    exit 0
}

Write-Error ('Unexpected fake ADB argv: ' + ($FakeArgs -join ' | '))
exit 91
'@

$fakeSignerSource = @'
$FakeArgs = @($args)
if ($FakeArgs.Count -ne 4 -or $FakeArgs[0] -cne 'verify' -or
    $FakeArgs[1] -cne '--verbose' -or $FakeArgs[2] -cne '--print-certs') {
    Write-Error ('Unexpected fake apksigner argv: ' + ($FakeArgs -join ' | '))
    exit 92
}
$sha = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
if ($env:QC_RC8_FAKE_SCENARIO -ceq 'wrong-signer') {
    $sha = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
}
Write-Output 'Verifies'
Write-Output 'Verified using v2 scheme (APK Signature Scheme v2): true'
Write-Output ("Signer #1 certificate SHA-256 digest: " + $sha)
if ($env:QC_RC8_FAKE_SCENARIO -ceq 'multiple-signers') {
    Write-Output 'Signer #2 certificate SHA-256 digest: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
}
exit 0
'@

[IO.File]::WriteAllText($fakeAdbPs1, $fakeAdbSource, $utf8)
[IO.File]::WriteAllText($fakeSignerPs1, $fakeSignerSource, $utf8)
[IO.File]::WriteAllText(
    $fakeAdbCmd,
    "@echo off`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-adb.ps1`" %*`r`n",
    [Text.Encoding]::ASCII)
[IO.File]::WriteAllText(
    $fakeSignerCmd,
    "@echo off`r`npwsh -NoLogo -NoProfile -NonInteractive -File `"%~dp0fake-apksigner.ps1`" %*`r`n",
    [Text.Encoding]::ASCII)

$savedEnvironment = [ordered]@{
    QC_RC8_FAKE_ADB_LOG = $env:QC_RC8_FAKE_ADB_LOG
    QC_RC8_FAKE_SCENARIO = $env:QC_RC8_FAKE_SCENARIO
    QC_RC8_FAKE_PULL_COUNT = $env:QC_RC8_FAKE_PULL_COUNT
    QC_RC8_FAKE_GOOD_APK = $env:QC_RC8_FAKE_GOOD_APK
    QC_RC8_FAKE_BAD_APK = $env:QC_RC8_FAKE_BAD_APK
}
$savedParameters = [ordered]@{
    Install = $script:Install
    Serial = $script:Serial
    AdbPath = $script:AdbPath
    ApkSignerPath = $script:ApkSignerPath
    LabPackage = $script:LabPackage
}

$candidateAudit = [pscustomobject]@{
    Path = [IO.Path]::GetFullPath($apkPath)
    Sha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
    SizeBytes = 128469341L
    Package = 'com.qcxr.qcxr.canary262'
    VersionCode = 71
    VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
    SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
}

function Reset-FakeScenario {
    param([Parameter(Mandatory)][string] $Name)
    $env:QC_RC8_FAKE_SCENARIO = $Name
    if (Test-Path -LiteralPath $callLog) { Remove-Item -LiteralPath $callLog -Force }
    if (Test-Path -LiteralPath $pullCounter) { Remove-Item -LiteralPath $pullCounter -Force }
    $script:DeviceInvocationCount = 0
    $script:ResolvedAdb = $null
    $script:ResolvedApkSigner = $null
    $script:ResolvedSerial = $null
}

function Read-FakeCalls {
    if (-not (Test-Path -LiteralPath $callLog)) { return @() }
    return @(Get-Content -LiteralPath $callLog | ForEach-Object {
        $parsed = ConvertFrom-Json $_
        [pscustomobject]@{ Arguments = @($parsed.Arguments) }
    })
}

function Assert-NoForbiddenFakeCalls {
    param([object[]] $Calls)
    foreach ($call in $Calls) {
        $argv = @($call.Arguments)
        $joined = ($argv -join ' ').ToLowerInvariant()
        foreach ($forbidden in @(
            'com.qcxr.qcxr.dev262',
            ' uninstall',
            ' pm clear',
            ' shell rm',
            ' shell su',
            ' shell input',
            ' shell monkey',
            ' force-stop',
            ' am start',
            ' install -d',
            ' install-multiple'
        )) {
            Require (-not $joined.Contains($forbidden)) `
                "Fake ADB log contains a forbidden command: $joined"
        }
        if ($argv -ccontains 'install') {
            Require ($argv.Count -eq 5 -and $argv[0] -ceq '-s' -and
                $argv[1] -ceq 'QUEST_RC8' -and $argv[2] -ceq 'install' -and
                $argv[3] -ceq '-r' -and
                [IO.Path]::GetFullPath([string]$argv[4]) -ceq [IO.Path]::GetFullPath($apkPath)) `
                'Fake ADB observed a non-exact install argv.'
        }
    }
}

try {
    $env:QC_RC8_FAKE_ADB_LOG = $callLog
    $env:QC_RC8_FAKE_PULL_COUNT = $pullCounter
    $env:QC_RC8_FAKE_GOOD_APK = $apkPath
    $env:QC_RC8_FAKE_BAD_APK = $badApkPath
    $script:Install = $true
    $script:Serial = 'auto'
    $script:AdbPath = $fakeAdbCmd
    $script:ApkSignerPath = $fakeSignerCmd

    # Stable refusal must occur before the first fake ADB call.
    Reset-FakeScenario 'success'
    $script:LabPackage = 'com.qcxr.qcxr.dev262'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'Only the fixed Lab package') `
        'Stable package mutation was not rejected.'
    Require (@(Read-FakeCalls).Count -eq 0) 'Stable refusal invoked fake ADB.'
    $script:LabPackage = 'com.qcxr.qcxr.canary262'

    Reset-FakeScenario 'no-device'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'exactly one ADB endpoint') `
        'No-device selection was not rejected.'
    $noDeviceCalls = Read-FakeCalls
    Require (@($noDeviceCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'No-device failure reached install.'

    Reset-FakeScenario 'multiple-devices'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'exactly one ADB endpoint') `
        'Multiple-device auto selection was not rejected.'
    $multipleDeviceCalls = Read-FakeCalls
    Require (@($multipleDeviceCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Multiple-device failure reached install.'

    Reset-FakeScenario 'success'
    $script:Serial = 'MISSING_SERIAL'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'requested ADB serial') `
        'A wrong explicit serial was not rejected.'
    $wrongSerialCalls = Read-FakeCalls
    Require (@($wrongSerialCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Wrong explicit serial reached install.'
    $script:Serial = 'auto'

    Reset-FakeScenario 'offline-device'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'not authorized and ready') `
        'An offline ADB endpoint was not rejected.'
    $offlineDeviceCalls = Read-FakeCalls
    Require (@($offlineDeviceCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Offline endpoint reached install.'

    Reset-FakeScenario 'running-app'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'Lab is running') `
        'A running Lab process was not rejected.'
    $runningAppCalls = Read-FakeCalls
    Require (@($runningAppCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Running-Lab failure reached install.'

    Reset-FakeScenario 'pidof-blank-success'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'process-state result was ambiguous') `
        'Blank successful pidof output was not rejected as ambiguous.'
    $blankPidofCalls = Read-FakeCalls
    Require (@($blankPidofCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Ambiguous pidof result reached install.'

    Reset-FakeScenario 'wrong-signer'
    $wrongSignerRejected = Test-ExpectedFailure {
        Invoke-DeviceInstall -CandidateAudit $candidateAudit
    } 'signer mismatched'
    Require $wrongSignerRejected `
        "Wrong installed signer was not rejected: $script:LastExpectedFailureMessage"
    $wrongSignerCalls = Read-FakeCalls
    Require (@($wrongSignerCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Wrong installed signer reached install.'

    Reset-FakeScenario 'multiple-signers'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'multiple or ambiguous signer') `
        'Multiple installed APK signers were not rejected.'
    $multipleSignerCalls = Read-FakeCalls
    Require (@($multipleSignerCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Multiple installed signers reached install.'

    Reset-FakeScenario 'split-apk'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'absent, split, or returned an ambiguous') `
        'A split/ambiguous installed package was not rejected.'
    $splitApkCalls = Read-FakeCalls
    Require (@($splitApkCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Split installed package reached install.'

    Reset-FakeScenario 'pull-failure'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'base.apk pull failed') `
        'An installed base.apk pull failure was not rejected.'
    $pullFailureCalls = Read-FakeCalls
    Require (@($pullFailureCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 0) `
        'Pre-install pull failure reached install.'

    Reset-FakeScenario 'install-failure'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'rejected the Lab install') `
        'Android install failure was not surfaced.'
    $installFailureCalls = Read-FakeCalls
    Require (@($installFailureCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 1) `
        'Install-failure scenario did not issue exactly one install.'

    Reset-FakeScenario 'post-wrong-hash'
    Require (Test-ExpectedFailure { Invoke-DeviceInstall -CandidateAudit $candidateAudit } 'size mismatched|SHA-256 mismatched') `
        'Wrong post-install APK hash/size was not rejected.'
    $wrongHashCalls = Read-FakeCalls
    Require (@($wrongHashCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 1) `
        'Wrong-hash scenario did not issue exactly one install.'

    Reset-FakeScenario 'success'
    $success = Invoke-DeviceInstall -CandidateAudit $candidateAudit
    Require ([string]$success.Result -ceq 'INSTALLED_AND_VERIFIED' -and
        -not [bool]$success.DryRun -and [bool]$success.InstallRequested -and
        [string]$success.Package -ceq 'com.qcxr.qcxr.canary262' -and
        [string]$success.Serial -ceq 'QUEST_RC8' -and
        [string]$success.ApkSha256 -ceq 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416' -and
        [string]$success.SignerSha256 -ceq 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A' -and
        -not [bool]$success.Launched -and -not [bool]$success.StableTouched) `
        'Successful fake deployment did not return the exact verified identity.'
    $successCalls = Read-FakeCalls
    Require (@($successCalls | Where-Object { @($_.Arguments) -ccontains 'install' }).Count -eq 1) `
        'Successful fake deployment did not issue exactly one install.'
    Require (@($successCalls | Where-Object { @($_.Arguments) -ccontains 'pull' }).Count -eq 2) `
        'Successful fake deployment did not verify both pre/post installed APKs.'

    $allCalls = @($noDeviceCalls) + @($multipleDeviceCalls) +
        @($wrongSerialCalls) + @($offlineDeviceCalls) +
        @($runningAppCalls) + @($blankPidofCalls) + @($wrongSignerCalls) +
        @($multipleSignerCalls) + @($splitApkCalls) + @($pullFailureCalls) +
        @($installFailureCalls) +
        @($wrongHashCalls) + @($successCalls)
    Assert-NoForbiddenFakeCalls -Calls $allCalls
} finally {
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
    }
    $script:Install = $savedParameters.Install
    $script:Serial = $savedParameters.Serial
    $script:AdbPath = $savedParameters.AdbPath
    $script:ApkSignerPath = $savedParameters.ApkSignerPath
    $script:LabPackage = $savedParameters.LabPackage

    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $fullTestRoot = [IO.Path]::GetFullPath($testRoot)
    Require ($fullTestRoot.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($fullTestRoot).StartsWith('quest-v71-rc8-install-host-',
            [StringComparison]::Ordinal)) 'Refused to clean an unexpected test directory.'
    Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
}

[pscustomobject]@{
    Result = 'PASS'
    HostOnly = $true
    RealAdbInvocations = 0
    DefaultDryRunPassed = $true
    WrongHashRejected = $true
    WrongSignerRejectedBeforeInstall = $true
    StableRejectedBeforeAdb = $true
    NoDeviceRejected = $true
    MultipleDevicesRejected = $true
    WrongExplicitSerialRejected = $true
    OfflineDeviceRejected = $true
    RunningLabRejected = $true
    AmbiguousPidofRejected = $true
    MultipleSignersRejected = $true
    SplitApkRejected = $true
    PullFailureRejected = $true
    InstallFailureRejected = $true
    PostInstallVerificationPassed = $true
    ExactInstallArgv = 'adb -s <serial> install -r <fixed-apk>'
    DestructiveCommandsAbsent = $true
    LaunchAbsent = $true
}
