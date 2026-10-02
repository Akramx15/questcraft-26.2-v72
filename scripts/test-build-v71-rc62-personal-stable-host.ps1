#requires -Version 7.0
<# Host-only regression tests for the exact RC6.2 Personal Stable admission gate. #>
[CmdletBinding()]
param(
    [string] $UnityEditor = (Join-Path $env:USERPROFILE `
        'Unity\Hub\Editor\2022.3.62f3\Editor\Unity.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$prefix = '[TEST_V71_RC62_STABLE_BUILD]'
$repo = Split-Path -Parent $PSScriptRoot
$gate = Join-Path $PSScriptRoot 'build-v71-rc62-personal-stable.ps1'
$stableOutput = Join-Path $repo `
    'QCXR-XR-Wrapper\Builds\QuestCraft-Vivecraft-26.2-personal.12-local.apk'

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { throw "$prefix $Message" }
}

function Snapshot-File([Parameter(Mandatory)][string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Length = 0L; Sha256 = $null }
    }
    return [pscustomobject]@{
        Present = $true
        Length = (Get-Item -LiteralPath $Path).Length
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Require-SameSnapshot([object] $Before, [object] $After, [string] $Label) {
    Require ([bool]$Before.Present -eq [bool]$After.Present) "$Label presence changed."
    if ([bool]$Before.Present) {
        Require ([int64]$Before.Length -eq [int64]$After.Length -and
                [string]$Before.Sha256 -ceq [string]$After.Sha256) "$Label bytes changed."
    }
}

Require (Test-Path -LiteralPath $gate -PathType Leaf) 'Stable admission gate is missing.'

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $gate, [ref]$tokens, [ref]$parseErrors)
Require ($parseErrors.Count -eq 0) 'Stable admission gate has PowerShell parse errors.'
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
Require (@(Compare-Object @('Action', 'UnityEditor') $parameters).Count -eq 0) `
    'Stable gate exposed an unexpected force/skip/override parameter.'
$commands = @($ast.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
Require (@($commands | Where-Object {
    $_ -match '^(?i:adb|fastboot)$'
}).Count -eq 0) 'Stable gate contains a device command path.'

$watched = @(
    'Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin',
    'Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin',
    'QCXR-XR-Wrapper/Assets/Plugins/Android/Pojlib-release.aar',
    'V71_LAB_RC6_2.lock.json',
    'V71_RC6_2_RUNTIME_RESULT.lock.json',
    'artifacts/manual/v71-rc6.2-user-acceptance-20260907.json'
)
$beforeFiles = @{}
foreach ($relative in $watched) {
    $beforeFiles[$relative] = Snapshot-File (Join-Path $repo $relative)
}
$beforeOutput = Snapshot-File $stableOutput
$beforeStatus = @(& git -C $repo status --porcelain=v1 --untracked-files=all)
Require ($LASTEXITCODE -eq 0) 'Could not snapshot Git status.'

$selfTest = @(& $gate -Action SelfTest -UnityEditor $UnityEditor)
Require ($selfTest.Count -eq 1) 'SelfTest returned an unexpected object count.'
$result = $selfTest[0]
Require ([string]$result.Result -ceq 'PASS_SOURCE_AND_ARTIFACTS_PROMOTION_BLOCKED') `
    'SelfTest did not pass the source/artifact chain.'
Require ([bool]$result.HostOnly -and [int]$result.DeviceInvocations -eq 0 -and
        [int]$result.UnityInvocations -eq 0) 'SelfTest was not Host-only.'
Require ([int]$result.SourceTreesVerified -eq 4 -and
        [int]$result.ManifestsVerified -eq 4) 'SelfTest omitted source or manifest checks.'
Require ([string]$result.FormalMemoryAcceptance -ceq 'FAIL' -and
        -not [bool]$result.StablePromotionAllowed -and
        -not [bool]$result.BuildActionAvailable) `
    'SelfTest did not preserve the immutable promotion denial.'
Require ([string]$result.ManualAcceptance -ceq 'PASS_REQUIRED_STANDARD_HAND_CHECKS') `
    'SelfTest did not authenticate the additive manual receipt.'
Require ([string]$result.StablePackage -ceq 'com.qcxr.qcxr.dev262' -and
        [string]$result.StableVersionCode -ceq '71' -and
        [string]$result.StableVersionName -ceq
            '6.0.1-26.2-vivecraft-personal.12') 'Stable target identity drifted.'

$buildRejected = $false
$buildError = $null
try {
    & $gate -Action Build -UnityEditor $UnityEditor | Out-Null
} catch {
    $buildError = $_.Exception.Message
    $buildRejected = $buildError.Contains(
        'formalMemoryAcceptance=FAIL; stablePromotionAllowed=false. No override is supported.')
}
Require $buildRejected "Build did not fail closed on the current receipt: $buildError"

foreach ($relative in $watched) {
    $after = Snapshot-File (Join-Path $repo $relative)
    Require-SameSnapshot $beforeFiles[$relative] $after $relative
}
$afterOutput = Snapshot-File $stableOutput
Require-SameSnapshot $beforeOutput $afterOutput 'Stable output APK'
$afterStatus = @(& git -C $repo status --porcelain=v1 --untracked-files=all)
Require ($LASTEXITCODE -eq 0) 'Could not verify final Git status.'
Require (($beforeStatus -join "`n") -ceq ($afterStatus -join "`n")) `
    'Stable gate changed the worktree.'

[pscustomobject]@{
    Result = 'PASS'
    HostOnly = $true
    SourceArtifactChecksPassed = $true
    BuildRejectedForFormalMemory = $true
    StablePromotionFalsePreserved = $true
    OverrideParameterAbsent = $true
    DeviceCommandPathAbsent = $true
    DeviceInvocations = 0
    UnityInvocations = 0
    WatchedFilesUnchanged = $watched.Count
    StableOutputUnchanged = $true
}
