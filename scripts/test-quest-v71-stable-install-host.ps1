#requires -Version 7.0
<# Host-only regression and command-boundary tests for v71 Stable installation. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_STABLE_INSTALL_HOST_TEST] $Message" }
}

$scriptPath = Join-Path $PSScriptRoot 'quest-v71-stable-install.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$templatePath = Join-Path $repoRoot 'V71_STABLE.lock.template.json'

Require (Test-Path -LiteralPath $scriptPath -PathType Leaf) 'The install harness is missing.'
Require (Test-Path -LiteralPath $templatePath -PathType Leaf) 'The future Stable lock template is missing.'

$before = Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id
$selfTestValues = @(& $scriptPath -Action SelfTest)
$selfTest = @($selfTestValues | Where-Object { $null -ne $_.PSObject.Properties['HostOnly'] })
Require ($selfTest.Count -eq 1) 'SelfTest did not return one structured Host-only result.'
Require ([string]$selfTest[0].Result -ceq 'PASS' -and [bool]$selfTest[0].HostOnly -and -not [bool]$selfTest[0].DeviceTouched -and [int]$selfTest[0].DeviceInvocations -eq 0) 'SelfTest reported a device action or failure.'
Require ([bool]$selfTest[0].ExactInstallArgvBoundary -and [bool]$selfTest[0].ArgumentInjectionFixtureStayedLiteral -and [bool]$selfTest[0].ProtectedBackupHashFaultRejected) 'SelfTest did not exercise the critical Host fault boundaries.'

$planValues = @(& $scriptPath -Action Plan)
$plan = @($planValues | Where-Object { $null -ne $_.PSObject.Properties['Phases'] })
Require ($plan.Count -eq 1 -and [bool]$plan[0].HostOnly -and [int]$plan[0].DeviceInvocations -eq 0) 'Plan was not Host-only.'
Require (@($plan[0].Phases).Count -eq 4) 'Plan does not expose four separate receipt phases.'
Require ([string]$plan[0].InstallCommand -ceq 'adb install -r only') 'Plan install policy drifted.'

$source = [IO.File]::ReadAllText($scriptPath)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
Require ($errors.Count -eq 0) 'PowerShell parser rejected the install harness.'
$parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($required in @('AllowDeviceRead','AllowDeviceWrite','AllowInstallReplace','AllowLaunch','AllowForceStop','AllowRollbackOnFailure','AllowRollbackDowngrade')) {
    Require ($parameters -ccontains $required) "Explicit authorization switch is missing: $required"
}
foreach ($forbidden in @('Package','Profile','Component','CandidateApkPath','RollbackApkPath','AcceptanceManifestPath')) {
    Require ($parameters -cnotcontains $forbidden) "A fixed target exposes an override: $forbidden"
}

Require ([regex]::Matches($source,"'install','-r'").Count -eq 1) 'The source does not have one exact install argv construction boundary.'
foreach ($forbiddenPattern in @(
    "'install','-d'",
    "'install','-r','-d'",
    "'pm','clear'",
    "'pm','uninstall'",
    "'shell','rm'",
    "'shell','input'",
    "'shell','monkey'",
    "'shell','run-as'"
)) {
    Require (-not $source.Contains($forbiddenPattern)) "Forbidden ADB argv boundary is present: $forbiddenPattern"
}
Require ($source.Contains("`$script:Package = 'com.qcxr.qcxr.dev262'") -and $source.Contains("`$script:Profile = '26.2'")) 'The fixed Stable target pins drifted.'
Require ($source.Contains('Assert-AcceptedEvidence') -and $source.Contains('Assert-ProtectedBackup') -and $source.Contains('Assert-InstalledArtifact -Expected (Get-ExpectedV69)')) 'A pre-install evidence, backup, or exact-v69 gate is missing.'
Require ($source.Contains('Android rejected or failed the conservative v69 install -r rollback; stopped without deletion')) 'The Android rollback-rejection terminal boundary is missing.'

$template = [IO.File]::ReadAllText($templatePath) | ConvertFrom-Json -Depth 20
Require ([int]$template.schemaVersion -eq 1 -and [string]$template.status -ceq 'TEMPLATE_NOT_AUTHORIZED') 'The template is not inert by default.'
Require ([string]$template.target.package -ceq 'com.qcxr.qcxr.dev262' -and [int]$template.target.versionCode -eq 71 -and $null -eq $template.target.apkSha256 -and $null -eq $template.target.apkSizeBytes) 'The template target or future artifact placeholders drifted.'
Require ([string]$template.target.signerSha256 -ceq 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A' -and [bool]$template.target.signatureSchemeV2) 'The template signer contract drifted.'
Require ([int]$template.baselineV69.versionCode -eq 69 -and [string]$template.baselineV69.apkSha256 -ceq '05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034') 'The template exact v69 baseline drifted.'
Require ($null -eq $template.acceptance.manifestSha256 -and [string]$template.acceptance.requiredStatus -ceq 'ACCEPTED_FOR_STABLE_BUILD') 'The template acceptance binding drifted.'
Require ([bool]$template.installPolicy.replaceOnly -and [bool]$template.installPolicy.noUninstall -and [bool]$template.installPolicy.noClearData -and [bool]$template.installPolicy.noAccountAccess -and [bool]$template.installPolicy.rollbackDowngradeOverrideForbidden) 'The template fail-closed policy drifted.'
Require ([int]$template.installPolicy.normalStartCount -eq 3 -and [int]$template.installPolicy.finalGateSeconds -eq 1800 -and [string]$template.installPolicy.finalRequiredState -ceq 'STOPPED') 'The template runtime receipt policy drifted.'

[pscustomobject]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceTouched = $false
    DeviceInvocations = 0
    SelfTestPassed = $true
    PlanPassed = $true
    ExactInstallArgvConstructionSites = 1
    LockTemplateInert = $true
    ExplicitReceiptPhases = 4
    FaultBoundaries = @(
        'candidate/rollback argv remains one literal argument',
        'nonzero/noisy/ambiguous Android install results rejected',
        'split or ambiguous base.apk rejected',
        'backup manifest and backed-up file tampering rejected',
        'lock identity/hash/signer/baseline/acceptance/policy mutations rejected',
        'rollback rejection stops without a deletion fallback'
    )
}
