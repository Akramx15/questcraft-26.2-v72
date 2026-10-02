[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$harness = Join-Path $PSScriptRoot 'quest-v70-lab-pair.ps1'
$selfTest = . $harness -Action SelfTest
if ($selfTest.Result -cne 'PASS' -or $selfTest.DeviceTouched -or
        [int]$selfTest.AdbInvocations -ne 0 -or -not $selfTest.CompensatingRollback) {
    throw 'Paired v70 Lab SelfTest failed its Host-only contract.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('quest-v70-pair-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$logPath = Join-Path $testRoot 'calls.log'
$coreMock = Join-Path $testRoot 'core-mock.ps1'
$veqMock = Join-Path $testRoot 'veq-mock.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)

$commonParams = @'
[CmdletBinding()]
param(
    [string] $Action,
    [string] $JarPath,
    [string] $ExpectedSha256,
    [string] $OpenXrCopyBatchMode,
    [int] $ExpiryMinutes,
    [string] $Serial,
    [string] $AdbPath,
    [switch] $AllowDeviceWrite,
    [switch] $AllowRootFallback
)
'@
$coreBody = @'
Add-Content -LiteralPath $env:QC_V70_PAIR_TEST_LOG -Value ("Core " + $Action)
if ($Action -eq 'Rollback' -and $env:QC_V70_PAIR_TEST_CORE_ROLLBACK_FAIL -eq '1') {
    throw 'injected Core rollback failure'
}
[pscustomobject]@{ Result = if ($Action -eq 'Deploy') { 'ARMED' } else { 'PASS' }; AdbInvocations = 0 }
'@
$veqBody = @'
Add-Content -LiteralPath $env:QC_V70_PAIR_TEST_LOG -Value ("VEQ " + $Action)
if ($Action -eq 'Deploy') { throw 'injected VEQ arm failure' }
[pscustomobject]@{ Result = 'PASS'; AdbInvocations = 0 }
'@
[IO.File]::WriteAllText($coreMock, $commonParams + $coreBody, $utf8)
[IO.File]::WriteAllText($veqMock, $commonParams + $veqBody, $utf8)

$savedCore = $script:coreHarness
$savedVeq = $script:veqHarness
$savedLog = $env:QC_V70_PAIR_TEST_LOG
$savedFailure = $env:QC_V70_PAIR_TEST_CORE_ROLLBACK_FAIL
$savedAllowDeviceWrite = $script:AllowDeviceWrite
$savedCoreJarPath = $script:CoreJarPath
$savedCoreExpectedSha256 = $script:CoreExpectedSha256
$savedVeqJarPath = $script:VeqJarPath
$savedVeqExpectedSha256 = $script:VeqExpectedSha256
try {
    $script:coreHarness = $coreMock
    $script:veqHarness = $veqMock
    $env:QC_V70_PAIR_TEST_LOG = $logPath
    $sha = '4C0FC01A3752A531A53F06C85A14C1E3F9510E1784A9160456699C8D8B9F7E72'
    $script:AllowDeviceWrite = $true
    $script:CoreJarPath = 'core.jar'
    $script:CoreExpectedSha256 = $sha
    $script:VeqJarPath = 'veq.jar'
    $script:VeqExpectedSha256 = $sha

    $env:QC_V70_PAIR_TEST_CORE_ROLLBACK_FAIL = '0'
    $restored = $false
    try {
        Invoke-PairedDeploy | Out-Null
    } catch {
        $restored = $_.Exception.Message -match 'both baselines were restored' -and
                $_.Exception.Message -match 'injected VEQ arm failure'
    }
    if (-not $restored) { throw 'Second-stage failure was not compensated.' }
    $calls = @(Get-Content -LiteralPath $logPath)
    $expected = @('VEQ SelfTest', 'Core Deploy', 'VEQ Deploy', 'Core Rollback', 'VEQ Rollback')
    if (($calls -join '|') -cne ($expected -join '|')) {
        throw "Unexpected paired compensation order: $($calls -join ', ')"
    }

    [IO.File]::WriteAllText($logPath, '', $utf8)
    $env:QC_V70_PAIR_TEST_CORE_ROLLBACK_FAIL = '1'
    $partialDetected = $false
    try {
        Invoke-PairedDeploy | Out-Null
    } catch {
        $partialDetected = $_.Exception.Message -match 'Compensation was partial' -and
                $_.Exception.Message -match 'Core rollback failed'
    }
    if (-not $partialDetected) { throw 'Partial paired rollback was not surfaced fail-closed.' }
    $partialCalls = @(Get-Content -LiteralPath $logPath)
    if (-not ($partialCalls -contains 'VEQ Rollback')) {
        throw 'VEQ rollback was skipped after an injected Core rollback failure.'
    }
} finally {
    $script:coreHarness = $savedCore
    $script:veqHarness = $savedVeq
    $env:QC_V70_PAIR_TEST_LOG = $savedLog
    $env:QC_V70_PAIR_TEST_CORE_ROLLBACK_FAIL = $savedFailure
    $script:AllowDeviceWrite = $savedAllowDeviceWrite
    $script:CoreJarPath = $savedCoreJarPath
    $script:VeqJarPath = $savedVeqJarPath
    if ([string]::IsNullOrWhiteSpace($savedCoreExpectedSha256)) {
        Remove-Variable -Name CoreExpectedSha256 -Scope Script -ErrorAction SilentlyContinue
    } else {
        $script:CoreExpectedSha256 = $savedCoreExpectedSha256
    }
    if ([string]::IsNullOrWhiteSpace($savedVeqExpectedSha256)) {
        Remove-Variable -Name VeqExpectedSha256 -Scope Script -ErrorAction SilentlyContinue
    } else {
        $script:VeqExpectedSha256 = $savedVeqExpectedSha256
    }
    [IO.Directory]::Delete($testRoot, $true)
}

[pscustomobject]@{
    Result = 'PASS'
    CasesPassed = 3
    HostOnly = $true
    DeviceTouched = $false
    AdbInvocations = 0
    SecondStageFailureRestoredBoth = $true
    PartialRollbackSurfaced = $true
    ContinuedAfterCoreRollbackFailure = $true
}
