#requires -Version 7.0
<# Host-only profile-binding regression test for the fixed RC4 memory sampler. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC4_MEMORY_SOAK_HOST_TEST] $Message" }
}

$sampler = Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc4.ps1'
$sentinel = Join-Path $PSScriptRoot '__quest-v71-memory-soak-host-test-no-adb__.exe'
Require (Test-Path -LiteralPath $sampler -PathType Leaf) 'The RC4 memory sampler is missing.'
Require (-not (Test-Path -LiteralPath $sentinel)) 'The ADB sentinel unexpectedly exists.'

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $sampler, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'The PowerShell parser rejected the RC4 memory sampler.'

$selfTestValues = @(& $sampler -Action SelfTest -Serial 'offline-proof' -AdbPath $sentinel)
$selfTest = @($selfTestValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($selfTest.Count -eq 1 -and [string]$selfTest[0].Result -ceq 'PASS') `
    'SelfTest did not return one PASS record.'
Require ([bool]$selfTest[0].HostOnly -and [int]$selfTest[0].DeviceInvocations -eq 0) `
    'SelfTest touched or resolved a device.'
Require ([bool]$selfTest[0].ExpectedGameLogPathBound -and
        [bool]$selfTest[0].ExpectedGameLogIdentityAtStartAndFinal -and
        [bool]$selfTest[0].ExpectedGameLogFreshnessEverySample) `
    'SelfTest did not prove the complete expected-profile game-log boundary.'
Require ([bool]$selfTest[0].WrongProfileFixtureRejected -and
        [bool]$selfTest[0].StaleGameLogFixtureRejected -and
        [bool]$selfTest[0].WrongVersionFixturesRejected) `
    'SelfTest did not exercise all fail-closed profile/version/freshness fixtures.'
Require (-not [bool]$selfTest[0].RawGameLogDataPersisted) `
    'SelfTest reported that raw game-log data is persisted.'
Require (-not (Test-Path -LiteralPath $sentinel)) `
    'The Host-only test attempted to create or use the ADB sentinel.'

$selfTestJson = $selfTest[0] | ConvertTo-Json -Depth 6 -Compress
Require ($selfTestJson -notmatch
        '(?i)account@example|serverAddress|worldName|private-world|/sdcard/|Loading Minecraft') `
    'The public SelfTest result exposed raw log, device-path, account, server, or world data.'

$source = [IO.File]::ReadAllText($sampler)
Require ($source.Contains(
        '$script:GameLogPath = "$($script:GameDirectory)/logs/latest.log"') -and
    $source.Contains('$script:ExpectedMinecraftVersion = ''26.2''') -and
    $source.Contains('$script:ExpectedCoreVersion = ''26.2-1.3.15+qc.v71.rc4''') -and
    $source.Contains('$script:ExpectedVeqVersion = ''0.7.0-v70-canary.1''')) `
    'The fixed expected-profile path or exact runtime versions drifted.'
Require ($source.Contains('Get-ExpectedGameLogIdentityObservation') -and
    $source.Contains('Get-ExpectedGameLogFreshnessObservation') -and
    $source.Contains('expectedGameLogEvidenceOnlyBooleansAndTimestamps')) `
    'The sampler no longer exposes the expected safe game-log boundary.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    PowerShellParsePassed = $true
    ExpectedProfilePathBound = $true
    ExactRuntimeVersionsBound = $true
    EverySampleFreshnessBound = $true
    FailClosedFixturesPassed = $true
    RawGameLogDataPersisted = $false
}
