#requires -Version 7.0
<# Host-only regression test for the RC5 cross-evidence memory contract. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC5_MEMORY_CONTRACT_HOST_TEST] $Message" }
}

$producer = Join-Path $PSScriptRoot 'quest-v71-memory-runtime-contract-rc5.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildLock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'V71_LAB_RC5.lock.json') |
    ConvertFrom-Json
$evidenceLock = Get-Content -Raw -LiteralPath `
    (Join-Path $repoRoot 'V71_RC5_EVIDENCE_PRODUCERS.lock.json') | ConvertFrom-Json

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $producer, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'PowerShell parser rejected the producer.'

$resultRows = @(& $producer -Action SelfTest)
$result = @($resultRows | Where-Object {
    $null -ne $_ -and $null -ne $_.PSObject.Properties['Result']
})
Require ($result.Count -eq 1 -and [string]$result[0].Result -ceq 'PASS') `
    'SelfTest did not return exactly one PASS result.'
Require ([bool]$result[0].SelfTestHostOnly -and [bool]$result[0].CreateHostOnly -and
    [int]$result[0].DeviceInvocations -eq 0) 'The producer is not Host-only.'
Require ([bool]$result[0].IntegratedStartFinalBinding -and
    [bool]$result[0].PidReuseDefense -and
    [bool]$result[0].PerSoakRuntimeReceiptsValidated -and
    -not [bool]$result[0].FinalLogcatRetentionRequired) `
    'The start/final runtime evidence contract drifted.'
Require ([string]$result[0].ProducerSha256 -ceq
        [string]$evidenceLock.producers.memoryRuntimeContractScriptSha256 -and
    [bool]$result[0].CreateProducerLocked) 'Producer hash lock drifted.'

$source = [IO.File]::ReadAllText($producer)
foreach ($field in @(
    'expectedGameLogRelativePath',
    'expectedGameLogMinecraftVersion',
    'expectedGameLogCoreVersion',
    'expectedGameLogVeqVersion')) {
    Require ($null -ne $buildLock.runtimeBinding.PSObject.Properties[$field]) `
        "V71_LAB_RC5.lock.json is missing runtimeBinding.$field."
    Require ($source.Contains($field)) "The producer does not validate runtimeBinding.$field."
}
Require ($source.Contains('Assert-Rc5CandidateReady') -and
    $source.Contains('The exact RC5 Lab APK is pending build and artifact audit.')) `
    'Create no longer fails closed while the candidate artifact is pending.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    PowerShellParsePassed = $true
    CandidateIdentitySource = 'V71_LAB_RC5.lock.json'
    CandidateArtifactReady = [bool]$buildLock.target.artifactAuditPassed
    ExpectedGameLogFieldsValidated = 4
    StartFinalBinding = $true
    PidReuseDefense = $true
}
