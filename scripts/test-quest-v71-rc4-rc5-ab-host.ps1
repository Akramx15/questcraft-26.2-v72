<#
.SYNOPSIS
Runs the Host-only contract tests for quest-v71-rc4-rc5-ab.ps1.

.DESCRIPTION
This test never resolves ADB. It checks the offline SelfTest and Plan contracts,
then proves that Run fails before device resolution without all three explicit
authorization switches.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$target = Join-Path $PSScriptRoot 'quest-v71-rc4-rc5-ab.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$rc4Lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'V71_LAB_RC4.lock.json') | ConvertFrom-Json
$rc5Lock = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'V71_LAB_RC5.lock.json') | ConvertFrom-Json
Require (Test-Path -LiteralPath $target -PathType Leaf) 'v71 A/B orchestrator is missing.'
$impossibleAdb = Join-Path $PSScriptRoot '__host-only-no-adb__.exe'
Require (-not (Test-Path -LiteralPath $impossibleAdb)) 'Host-only ADB sentinel unexpectedly exists.'

$selfTestRows = @(& $target -Action SelfTest -AdbPath $impossibleAdb -Serial 'offline-proof')
$selfTest = @($selfTestRows | Where-Object {
    $null -ne $_ -and $null -ne $_.PSObject.Properties['Result'] -and
    [string]$_.Result -ceq 'PASS'
})
Require ($selfTest.Count -eq 1) 'v71 A/B SelfTest did not return one PASS result.'
Require (-not [bool]$selfTest[0].DeviceTouched -and
        [int]$selfTest[0].DeviceInvocations -eq 0) 'v71 A/B SelfTest touched a device.'
Require ([string]$selfTest[0].Package -ceq 'com.qcxr.qcxr.canary262' -and
        [string]$selfTest[0].ForbiddenPackage -ceq 'com.qcxr.qcxr.dev262') `
        'v71 A/B package guard drifted.'
Require ([string]$selfTest[0].Order -ceq 'A1-B1-B2-A2-A3-B3') `
        'v71 A/B order drifted.'
Require ([bool]$selfTest[0].AlwaysRollbackRc5 -and
        @($selfTest[0].ExplicitDeviceSwitches).Count -eq 3) `
        'v71 A/B cleanup or explicit-authorization contract drifted.'
Require ([string]$selfTest[0].GlobalCampaignLock -ceq
        'artifacts/benchmarks/.quest-v71-rc4-rc5-ab.global.lock' -and
        [bool]$selfTest[0].PinnedPidPerRound -and
        [bool]$selfTest[0].DeviceMarkerFreshSlices -and
        [bool]$selfTest[0].RuntimeFabricVersionMarkers -and
        [bool]$selfTest[0].StrictSingleLinePmPath -and
        [bool]$selfTest[0].HelperSelfTestsAdbIsolated -and
        [bool]$selfTest[0].ReservedPidAssignmentGuard -and
        [bool]$selfTest[0].BenchmarkReservedLastExitCodeGuard -and
        [bool]$selfTest[0].PerformanceLevelLeasePureCommandTests -and
        -not [bool]$selfTest[0].RefreshOrAdaptivePropertiesModified -and
        [int]$selfTest[0].Assertions -eq 63) `
        'v71 A/B fail-closed runtime guards drifted.'
Require ([string]$selfTest[0].Rc4CoreSha256 -ceq
        [string]$rc4Lock.pair.core.sha256 -and
        [string]$selfTest[0].Rc4VeqSha256 -ceq
        '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B' -and
        [string]$selfTest[0].Rc5CoreSha256 -ceq
        [string]$rc5Lock.pair.core.sha256 -and
        [string]$selfTest[0].Rc5VeqSha256 -ceq
        [string]$rc5Lock.pair.veq.sha256) `
        'v71 A/B RC4/RC5 pair hashes drifted.'
Require ([string]$selfTest[0].ProducerLineageSha256 -cmatch '^[0-9A-F]{64}$' -and
        [int]$selfTest[0].ProducerFilesPinned -eq 8 -and
        [bool]$selfTest[0].ProducerFilesReadLockedDuringRun) `
        'v71 A/B producer-lineage or file-lock contract drifted.'

$planRows = @(& $target -Action Plan -WarmupSeconds 420 `
        -AdbPath $impossibleAdb -Serial 'offline-proof')
$plan = @($planRows | Where-Object {
    $null -ne $_ -and $null -ne $_.PSObject.Properties['Result'] -and
    [string]$_.Result -ceq 'PLAN'
})
Require ($plan.Count -eq 1) 'v71 A/B Plan did not return one PLAN result.'
Require (-not [bool]$plan[0].DeviceTouched -and
        [string]$plan[0].InstalledApkSha256 -ceq
        [string]$rc5Lock.target.apkSha256) `
        'v71 A/B Plan is not Host-only or pins the wrong APK.'
Require ([int]$plan[0].WarmupSeconds -eq 420) 'Plan ignored its manifest-bound warm-up value.'
Require ([string]$plan[0].PerformanceLevelLease -cmatch 'Lab only' -and
        -not [bool]$plan[0].RefreshOrAdaptivePropertiesModified) `
        'Plan omitted or broadened the reversible CPU/GPU 4/4 lease.'

$readRejected = $false
try {
    $null = & $target -Action Run -AllowDeviceWrite -AllowLaunch `
            -AdbPath $impossibleAdb -Serial 'offline-proof'
} catch {
    $readRejected = $_.Exception.Message -match 'AllowDeviceRead'
}
Require $readRejected 'Run did not require -AllowDeviceRead before device resolution.'

$writeRejected = $false
try {
    $null = & $target -Action Run -AllowDeviceRead -AllowLaunch `
            -AdbPath $impossibleAdb -Serial 'offline-proof'
} catch {
    $writeRejected = $_.Exception.Message -match 'AllowDeviceWrite'
}
Require $writeRejected 'Run did not require -AllowDeviceWrite before device resolution.'

$launchRejected = $false
try {
    $null = & $target -Action Run -AllowDeviceRead -AllowDeviceWrite `
            -AdbPath $impossibleAdb -Serial 'offline-proof'
} catch {
    $launchRejected = $_.Exception.Message -match 'AllowLaunch'
}
Require $launchRejected 'Run did not require -AllowLaunch before device resolution.'

[pscustomobject]@{
    Result = 'PASS'
    Assertions = 20
    Target = [IO.Path]::GetFileName($target)
    Package = 'com.qcxr.qcxr.canary262'
    ForbiddenPackage = 'com.qcxr.qcxr.dev262'
    InstalledApkSha256 = [string]$rc5Lock.target.apkSha256
    Order = 'A1-B1-B2-A2-A3-B3'
    DeviceTouched = $false
    DeviceInvocations = 0
}
