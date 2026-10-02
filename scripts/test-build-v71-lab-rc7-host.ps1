#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot 'build-v71-lab-rc7-integrated.ps1'
$lockPath = Join-Path $repo 'V71_LAB_RC7.lock.json'
$builderPath = Join-Path $repo `
    'QCXR-XR-Wrapper\Assets\Editor\QuestCraftV71Rc7LabCliBuild.cs'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC7_HOST_TEST] $Message" }
}

$before = @(git -C $repo status --porcelain=v1 --untracked-files=all)
Require ($LASTEXITCODE -eq 0) 'Could not capture initial worktree status.'

$tokens = $null
$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $buildScript, [ref]$tokens, [ref]$errors)
Require ($errors.Count -eq 0) `
    ('Build script has parser errors: ' + (($errors | ForEach-Object Message) -join '; '))

$source = Get-Content -Raw -LiteralPath $buildScript
Require (-not $source.Contains('Invoke-Adb')) 'Host builder contains an ADB helper.'
Require (-not $source.Contains('adb.exe')) 'Host builder names adb.exe.'
Require (-not $source.Contains('install -r')) 'Host builder contains an install path.'
Require ($source.Contains("`$package = 'com.qcxr.qcxr.canary262'")) `
    'Lab package pin is missing.'
Require ($source.Contains("`$forbiddenStablePackage = 'com.qcxr.qcxr.dev262'")) `
    'Stable package deny pin is missing.'
Require ($source.Contains("Require `$AllowBuild 'Build requires explicit -AllowBuild.'")) `
    'Explicit build authorization is missing.'
Require ($source.Contains("`$builder = 'QuestCraftV71Rc7LabCliBuild.BuildAndroid'")) `
    'Exact Unity method pin is missing.'
Require ($source.Contains("& '.\gradlew.bat' --offline --no-daemon clean")) `
    'Pojlib build is not offline and clean.'
Require ($source.Contains('for ($buildNumber = 1; $buildNumber -le 2;')) `
    'Two-build AAR reproducibility gate is missing.'

$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
Require ([string]$lock.target.package -ceq 'com.qcxr.qcxr.canary262') `
    'Lock package is not Lab.'
Require ([string]$lock.target.forbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262' -and
        [bool]$lock.target.stableTouched -eq $false) 'Stable deny contract drifted.'
Require ([string]$lock.target.versionName -ceq
        '6.0.1-26.2-vivecraft-personal.12-rc.7') 'RC7 version drifted.'
Require ([string]$lock.pair.core.fabricVersion -ceq
        '26.2-1.3.15+qc.v71.rc7') 'RC7 Core version drifted.'
Require ([string]$lock.pair.veq.fabricVersion -ceq '0.7.0-v71.rc6') `
    'Frozen VEQ version drifted.'
Require ([bool]$lock.evidenceBoundary.deviceTouched -eq $false -and
        [bool]$lock.evidenceBoundary.adbUsed -eq $false -and
        [bool]$lock.acceptance.stablePromotionAllowed -eq $false) `
    'Host-only evidence boundary drifted.'

$builder = Get-Content -Raw -LiteralPath $builderPath
Require ($builder.Contains('ApplicationIdentifier = "com.qcxr.qcxr.canary262"')) `
    'Unity builder package drifted.'
Require (-not $builder.Contains('com.qcxr.qcxr.dev262')) `
    'Unity builder contains Stable package.'
Require ($builder.Contains('HasArgument("-release")')) `
    'Unity builder lacks Debug-only rejection.'

$selfTest = & $buildScript -Action SelfTest
Require ([string]$selfTest.Result -ceq 'PASS' -and [bool]$selfTest.HostOnly -and
        [int]$selfTest.AdbInvocations -eq 0) 'RC7 SelfTest did not pass Host-only.'
Require ([string]$selfTest.Package -ceq 'com.qcxr.qcxr.canary262' -and
        [string]$selfTest.ForbiddenStablePackage -ceq 'com.qcxr.qcxr.dev262') `
    'SelfTest identity drifted.'

$missingAuthorizationRejected = $false
try {
    & $buildScript -Action Build | Out-Null
} catch {
    $missingAuthorizationRejected = $_.Exception.Message.Contains(
        'Build requires explicit -AllowBuild.')
}
Require $missingAuthorizationRejected 'Build ran without explicit -AllowBuild.'

$after = @(git -C $repo status --porcelain=v1 --untracked-files=all)
Require ($LASTEXITCODE -eq 0) 'Could not capture final worktree status.'
Require (($before -join "`n") -ceq ($after -join "`n")) `
    'Host-only self-tests changed the worktree.'

[pscustomobject]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    Package = [string]$lock.target.package
    VersionName = [string]$lock.target.versionName
    CoreSha256 = [string]$lock.pair.core.sha256
    PojlibAarSha256 = [string]$lock.pojlibAar.sha256
    LockStatus = [string]$lock.status
    StableTouched = $false
}
