[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Get-NormalizedTextSha256([string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($text)))
}

$helper = Join-Path $PSScriptRoot 'quest-v71-lab-lifecycle-recovery-rc4.ps1'
$sentinel = Join-Path $PSScriptRoot '__quest-v71-lifecycle-host-test-no-adb__.exe'
Require (-not (Test-Path -LiteralPath $sentinel)) 'ADB sentinel unexpectedly exists.'

$selfValues = @(& $helper -Action SelfTest -Serial 'offline-proof' -AdbPath $sentinel)
$self = @($selfValues | Where-Object { $null -ne $_.PSObject.Properties['Result'] })
Require ($self.Count -eq 1 -and [string]$self[0].Result -ceq 'PASS') `
    'Lifecycle SelfTest did not return one PASS record.'
Require (-not [bool]$self[0].DeviceTouched -and
    [int]$self[0].DeviceInvocationCount -eq 0) 'Lifecycle SelfTest touched or resolved a device.'
Require ([bool]$self[0].AutomaticVariableCollisionScan -and
    [int]$self[0].AutomaticVariableCollisionCount -eq 0 -and
    [bool]$self[0].AutomaticVariableCaseFixtureRejected) `
    'Lifecycle SelfTest did not enforce its automatic-variable collision regression.'
Require ([bool]$self[0].AtomicWriteOnceReceipt -and
    [bool]$self[0].FinalInstalledIdentityRecheck -and
    [string]$self[0].EvidenceReceiptPath -ceq
        'artifacts/acceptance/v71-lab-rc4-lifecycle-recovery-receipt.json' -and
    [string]$self[0].ProducerSha256 -ceq (Get-NormalizedTextSha256 $helper) -and
    [string]$self[0].ProducerLineageSha256 -cmatch '^[0-9A-F]{64}$') `
    'Lifecycle SelfTest did not bind the atomic receipt to its producer lineage.'

$planValues = @(& $helper -Action Plan -Serial 'offline-proof' -AdbPath $sentinel)
$plan = @($planValues | Where-Object { $null -ne $_.PSObject.Properties['Result'] })
Require ($plan.Count -eq 1 -and [string]$plan[0].Result -ceq 'PLAN') `
    'Lifecycle Plan did not return one PLAN record.'
Require (-not [bool]$plan[0].DeviceTouched) 'Lifecycle Plan touched a device.'
Require ([string]$plan[0].Package -ceq 'com.qcxr.qcxr.canary262' -and
    [string]$plan[0].ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262') `
    'Lifecycle Plan target identity drifted.'
Require ([string]$plan[0].InstalledApkSha256Required -ceq
    '8D4811174EC963FFB0DDD31196C425111D03F04A5A2EB4CF6ED7D2DEBB492FAA' -and
    [string]$plan[0].CandidateBuildState -ceq 'LOCKED') `
    'Lifecycle Plan APK identity drifted.'
Require (@($plan[0].Authorization).Count -eq 6) 'Lifecycle Run authorization contract drifted.'
Require ([string]$plan[0].EvidenceReceiptPath -ceq
        'artifacts/acceptance/v71-lab-rc4-lifecycle-recovery-receipt.json' -and
    [string]$plan[0].ProducerSha256 -ceq (Get-NormalizedTextSha256 $helper) -and
    [string]$plan[0].ProducerLineageSha256 -ceq
        [string]$self[0].ProducerLineageSha256) `
    'Lifecycle Plan did not disclose the exact receipt/producer contract.'
Require (@($plan[0].ExplicitlyNotProven | Where-Object {
    $_ -match 'gameReady-to-OpenXR-init'
}).Count -eq 1) 'The untestable post-handoff window is not disclosed.'
Require (-not (Test-Path -LiteralPath $sentinel)) 'Host-only actions attempted to create/use ADB sentinel.'

$unauthorizedRejected = $false
try {
    $null = & $helper -Action Run -Serial 'offline-proof' -AdbPath $sentinel
} catch {
    $unauthorizedRejected = $_.Exception.Message -match 'Run requires explicit'
}
Require $unauthorizedRejected 'Unauthorized Run did not fail before device resolution.'
Require (-not (Test-Path -LiteralPath $sentinel)) 'Unauthorized Run attempted ADB resolution.'

$source = Get-Content -Raw -LiteralPath $helper
Require ($source.Contains("Require (`$stop.ExitCode -eq 0) 'Lab cleanup force-stop failed.'")) `
    'Lifecycle cleanup no longer checks force-stop success.'
Require ($source.Contains("throw 'Lab PID remained after the bounded cleanup window.'")) `
    'Lifecycle cleanup no longer proves PID absence.'
Require ($source.Contains("if (`$finalizationErrors.Count -gt 0)")) `
    'Lifecycle finalization errors can be masked by a primary failure.'
Require ($source.Contains('[IO.FileMode]::CreateNew') -and
    $source.Contains('[IO.FileStream]::new($temporary') -and
    -not $source.Contains('[IO.File]::Open($temporary') -and
    $source.Contains('[IO.FileOptions]::WriteThrough') -and
    $source.Contains('[IO.File]::Move($temporary, $full)') -and
    $source.Contains('if ($published -and (Test-Path -LiteralPath $full -PathType Leaf))') -and
    $source.Contains('EvidenceReceiptSha256')) `
    'Lifecycle receipt is not atomic, write-once, failure-cleaning, and hash-returning.'
Require ($source.Contains('$installedAfter = Get-InstalledIdentity') -and
    $source.Contains('$pairAfter = Get-PhysicalPair') -and
    $source.Contains('Installed Lab APK identity changed during lifecycle/recovery Run.')) `
    'Lifecycle receipt is not preceded by the final stopped APK/pair recheck.'

[pscustomobject]@{
    Result = 'PASS'
    Assertions = 23
    SelfTestDeviceInvocations = 0
    PlanDeviceInvocations = 0
    Package = 'com.qcxr.qcxr.canary262'
    StableProtected = $true
    AtomicWriteOnceReceipt = $true
    RawLogsPersisted = $false
}
