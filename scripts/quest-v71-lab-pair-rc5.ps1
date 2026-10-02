<#
.SYNOPSIS
Arms or restores a paired Vivecraft Core + VEQ v71 RC5 Lab transaction.

.DESCRIPTION
This coordinator has no package or profile overrides. Both child harnesses are
hard-locked to com.qcxr.qcxr.canary262 / 26.2 and reject Stable. Each target is
promoted atomically by its runtime gate. If the second arm fails, this script
restores both exact embedded baselines, Core first. Runtime verification uses
the same compensating order. SelfTest never resolves or invokes ADB.
#>
[CmdletBinding()]
param(
    [ValidateSet('Status', 'Deploy', 'Rollback', 'SelfTest')]
    [string] $Action = 'SelfTest',

    [string] $CoreJarPath,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $CoreExpectedSha256,

    [string] $VeqJarPath,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string] $VeqExpectedSha256,

    [ValidateRange(1, 30)]
    [int] $ExpiryMinutes = 15,

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceWrite,

    [switch] $AllowRootFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreHarness = Join-Path $PSScriptRoot 'quest-vivecraft-core-canary-rc5.ps1'
$veqHarness = Join-Path $PSScriptRoot 'quest-veq-lab-rc5.ps1'
$script:LabPackage = 'com.qcxr.qcxr.canary262'
$script:ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Get-ChildCommonArguments {
    return @{
        ExpiryMinutes = $ExpiryMinutes
        Serial = $Serial
        AdbPath = $AdbPath
        AllowRootFallback = $AllowRootFallback
    }
}

function Invoke-PairedRollback {
    param([switch] $BestEffort)

    if (-not $AllowDeviceWrite) {
        throw 'Rollback is disabled until -AllowDeviceWrite is explicit.'
    }
    $common = Get-ChildCommonArguments
    $errors = [Collections.Generic.List[string]]::new()
    $coreResult = $null
    $veqResult = $null
    try {
        $coreResult = & $coreHarness -Action Rollback -AllowDeviceWrite @common
    } catch {
        $errors.Add("Core rollback failed: $($_.Exception.Message)")
    }
    try {
        $veqResult = & $veqHarness -Action Rollback -AllowDeviceWrite @common
    } catch {
        $errors.Add("VEQ rollback failed: $($_.Exception.Message)")
    }
    if ($errors.Count -gt 0 -and -not $BestEffort) {
        throw ($errors -join ' ')
    }
    return [pscustomobject]@{
        Result = if ($errors.Count -eq 0) { 'PAIRED_ROLLBACK_COMPLETE' } else { 'PAIRED_ROLLBACK_PARTIAL' }
        Package = $script:LabPackage
        Profile = $script:Profile
        Core = $coreResult
        Veq = $veqResult
        Errors = @($errors)
        RollbackOrder = @('Core', 'VEQ')
    }
}

function Invoke-PairedDeploy {
    if (-not $AllowDeviceWrite) {
        throw 'Deploy is disabled until -AllowDeviceWrite is explicit.'
    }
    foreach ($value in @($CoreJarPath, $CoreExpectedSha256, $VeqJarPath, $VeqExpectedSha256)) {
        Require (-not [string]::IsNullOrWhiteSpace([string]$value)) `
                'Paired Deploy requires both JAR paths and both explicit SHA-256 values.'
    }

    # Fully validate VEQ, including its exact v70 Fabric version, before Core
    # can be armed. This is Host-only and must report zero ADB invocations.
    $veqPreflight = & $veqHarness -Action SelfTest -JarPath $VeqJarPath `
            -ExpectedSha256 $VeqExpectedSha256
    Require ($veqPreflight.Result -ceq 'PASS' -and
            [int]$veqPreflight.AdbInvocations -eq 0) `
            'VEQ Host preflight did not complete without ADB.'
    $common = Get-ChildCommonArguments
    $core = $null
    try {
        $core = & $coreHarness -Action Deploy -JarPath $CoreJarPath `
                -ExpectedSha256 $CoreExpectedSha256 -OpenXrCopyBatchMode OFF `
                -AllowDeviceWrite @common
        $veq = & $veqHarness -Action Deploy -JarPath $VeqJarPath `
                -ExpectedSha256 $VeqExpectedSha256 -AllowDeviceWrite @common
        return [pscustomobject]@{
            Result = 'PAIRED_ARMED'
            Package = $script:LabPackage
            Profile = $script:Profile
            Core = $core
            Veq = $veq
            MarkerOrder = @('Core', 'VEQ')
            RuntimePromotionOrder = @('Core', 'VEQ')
            CompensatingRollback = $true
        }
    } catch {
        $failure = $_
        if ($null -eq $core) {
            throw $failure
        }
        # A second-stage failure must never leave a Core marker/candidate armed.
        # Attempt both restorations in runtime's fixed Core -> VEQ order.
        $rollback = Invoke-PairedRollback -BestEffort
        $rollbackErrors = @($rollback.Errors)
        if ($rollbackErrors.Count -gt 0) {
            throw "Paired deploy failed: $($failure.Exception.Message) Compensation was partial: $($rollbackErrors -join ' ')"
        }
        throw "Paired deploy failed and both baselines were restored: $($failure.Exception.Message)"
    }
}

function Invoke-PairedStatus {
    $common = Get-ChildCommonArguments
    return [pscustomobject]@{
        Result = 'PAIRED_STATUS'
        Package = $script:LabPackage
        Profile = $script:Profile
        Core = & $coreHarness -Action Status @common
        Veq = & $veqHarness -Action Status @common
        ReadOnly = $true
    }
}

function Invoke-PairedSelfTest {
    $core = & $coreHarness -Action SelfTest
    $veq = & $veqHarness -Action SelfTest
    Require ($core.Result -ceq 'PASS' -and $veq.Result -ceq 'PASS') `
            'A child Lab harness SelfTest failed.'
    Require ([int]$core.AdbInvocations -eq 0 -and [int]$veq.AdbInvocations -eq 0) `
            'A paired SelfTest invoked ADB.'

    $source = Get-Content -Raw -LiteralPath $PSCommandPath
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
            $PSCommandPath, [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) 'PowerShell parser rejected the paired harness.'
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
        $_.Name.VariablePath.UserPath
    })
    Require ($parameterNames -cnotcontains 'Package' -and
            $parameterNames -cnotcontains 'Profile') `
            'The paired harness exposes a package or profile override.'
    Require ($source.Contains("`$script:LabPackage = '$script:LabPackage'")) `
            'The paired harness Lab package hard-lock drifted.'
    Require ($source.Contains("`$script:ForbiddenStablePackage = '$script:ForbiddenStablePackage'")) `
            'The paired harness Stable-package guard drifted.'
    Require ($source.Contains('Invoke-PairedRollback -BestEffort')) `
            'The paired deploy lacks compensating rollback.'
    Require ($source.IndexOf("`$coreResult = & `$coreHarness -Action Rollback",
            [StringComparison]::Ordinal) -lt
            $source.IndexOf("`$veqResult = & `$veqHarness -Action Rollback",
            [StringComparison]::Ordinal)) `
            'Paired rollback order is not Core then VEQ.'
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modsAbPath = Join-Path $repoRoot `
            'Pojlib\src\main\java\pojlib\ModsAbCanaryGate.java'
    $modsAbGate = Get-Content -Raw -LiteralPath $modsAbPath
    Require ($modsAbGate.Contains(
            'VivecraftCoreCanaryGate.hasProcessPermit() || VeqCanaryGate.hasProcessPermit()')) `
            'Managed Mods-A/B is no longer mutually exclusive with Core+VEQ permits.'

    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceTouched = $false
        AdbInvocations = 0
        Package = $script:LabPackage
        ForbiddenPackage = $script:ForbiddenStablePackage
        Profile = $script:Profile
        CoreAndVeqRequired = $true
        VeqValidatedBeforeCoreArm = $true
        PerTargetAtomicPromotion = $true
        CompensatingRollback = $true
        ModsAbMutuallyExclusive = $true
        RollbackOrder = @('Core', 'VEQ')
    }
}

switch ($Action) {
    'SelfTest' { Invoke-PairedSelfTest }
    'Status' { Invoke-PairedStatus }
    'Deploy' { Invoke-PairedDeploy }
    'Rollback' { Invoke-PairedRollback }
}
