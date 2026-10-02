#requires -Version 7.0
<# Host-only fail-closed tests for the immutable RC6.2 result verifier. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[V71_RC6_2_RUNTIME_RESULT_SELF_TEST]'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Verifier = Join-Path $PSScriptRoot 'verify-v71-rc62-runtime-result.ps1'
$script:Receipt = Join-Path $script:RepoRoot 'V71_RC6_2_RUNTIME_RESULT.lock.json'
$script:ExpectedReceiptSha256 =
    'A0B37CCAAA67E0D0E4BA7C4E5CA80745707958F26B113638ABDEFB264788770C'

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { throw "$($script:Prefix) $Message" }
}

function Get-Sha256([Parameter(Mandatory)][string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Assert-Rejected(
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][scriptblock] $Mutate,
    [Parameter(Mandatory)][string] $Directory
) {
    $fixture = Get-Content -Raw -LiteralPath $script:Receipt | ConvertFrom-Json
    & $Mutate $fixture
    $path = Join-Path $Directory ($Name + '.json')
    [IO.File]::WriteAllText($path, ($fixture | ConvertTo-Json -Depth 30),
        [Text.UTF8Encoding]::new($false))
    $rejected = $false
    try {
        & $script:Verifier -ReceiptPath $path | Out-Null
    } catch {
        $rejected = $_.Exception.Message.Contains(
            '[V71_RC6_2_RUNTIME_RESULT]', [StringComparison]::Ordinal)
    }
    Require $rejected "Fail-closed fixture was accepted: $Name"
}

$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $script:Verifier, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'PowerShell rejected the verifier source.'
Require ((Get-Sha256 $script:Receipt) -ceq $script:ExpectedReceiptSha256) `
    'The immutable receipt hash drifted before the test.'

$resultValues = @(& $script:Verifier)
$result = @($resultValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($result.Count -eq 1 -and [string]$result[0].Result -ceq 'PASS' -and
        [bool]$result[0].HostOnly -and [int]$result[0].DeviceInvocations -eq 0) `
    'The canonical verifier did not return one Host-only PASS.'
Require ([string]$result[0].FormalMemoryResult -ceq 'FAIL' -and
        [string]$result[0].SupplementaryResult -ceq 'LEAK_STABILITY_PASS' -and
        [string]$result[0].ManualAcceptance -ceq 'PENDING_USER_OBSERVATION' -and
        -not [bool]$result[0].StablePromotionAllowed -and
        [int]$result[0].EvidenceFilesVerified -eq 13) `
    'The canonical verifier weakened an acceptance boundary.'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'v71-rc62-result-self-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    Assert-Rejected 'core-hash-drift' {
        param($fixture)
        $fixture.candidate.core.sha256 = '0' * 64
    } $tempRoot
    Assert-Rejected 'formal-result-upgrade' {
        param($fixture)
        $fixture.memory.formalResult = 'PASS'
    } $tempRoot
    Assert-Rejected 'supplementary-overrides-formal' {
        param($fixture)
        $fixture.memory.supplementary.overridesFormalResult = $true
    } $tempRoot
    Assert-Rejected 'manual-preaccepted' {
        param($fixture)
        $fixture.manualAcceptance.status = 'PASS'
    } $tempRoot
    Assert-Rejected 'stable-promotion-enabled' {
        param($fixture)
        $fixture.decision.stablePromotionAllowed = $true
    } $tempRoot
    Assert-Rejected 'path-traversal' {
        param($fixture)
        $fixture.runtimeScreen.path = '../outside.json'
    } $tempRoot
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Require ((Get-Sha256 $script:Receipt) -ceq $script:ExpectedReceiptSha256) `
    'The canonical receipt changed during negative testing.'
Require ((Get-Sha256 (Join-Path $script:RepoRoot 'V71_LAB_RC6_2.lock.json')) -ceq
        '7DD25F7703A4E2B1F2857FD8EB552CB303CB3A1870779ADBD5708B3F5D1B7E45') `
    'The immutable candidate lock changed during negative testing.'
$producerLockPath = Join-Path $script:RepoRoot 'V71_RC6_2_EVIDENCE_PRODUCERS.lock.json'
Require ((Get-Sha256 $producerLockPath) -ceq
        'AE863EE53217D11D594DF208E1C015F2AF59A06217894FE8509E6675CDC878C4') `
    'The immutable producer lock changed during negative testing.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    CanonicalReceiptVerified = $true
    NegativeFixturesRejected = 6
    FormalFailurePreserved = $true
    SupplementaryScopePreserved = $true
    ManualAcceptancePreserved = $true
    StablePromotionPreserved = $true
    ImmutableInputsUnchanged = $true
}
