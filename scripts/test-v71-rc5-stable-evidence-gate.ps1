#requires -Version 7.0
<# Host-only structural and adversarial tests for the RC5 Stable evidence gate. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC5_EVIDENCE_HOST_TEST] $Message" }
}

function Expect-Failure([scriptblock] $Operation, [string] $Needle = '') {
    try { & $Operation | Out-Null; return $false } catch {
        if ([string]::IsNullOrWhiteSpace($Needle)) { return $true }
        return [string]$_.Exception.Message -like "*$Needle*"
    }
}

function Copy-Value($Value) {
    return $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$gatePath = Join-Path $PSScriptRoot 'v71-rc5-stable-evidence-gate.ps1'
$buildLockPath = Join-Path $repoRoot 'V71_LAB_RC5.lock.json'
$producerLockPath = Join-Path $repoRoot 'V71_RC5_EVIDENCE_PRODUCERS.lock.json'
$acceptancePath = Join-Path $repoRoot 'V71_STABLE_RC5_ACCEPTANCE.lock.json'
$manualTemplatePath = Join-Path $repoRoot 'V71_MANUAL_RC5_ACCEPTANCE.template.json'

foreach ($path in @($gatePath, $buildLockPath, $producerLockPath,
        $acceptancePath, $manualTemplatePath)) {
    Require-Test (Test-Path -LiteralPath $path -PathType Leaf) "Missing Host contract: $path"
}

$tokens = $null
$parseErrors = $null
$gateAst = [Management.Automation.Language.Parser]::ParseFile(
    $gatePath, [ref]$tokens, [ref]$parseErrors)
Require-Test ($parseErrors.Count -eq 0) 'PowerShell parser rejected the Stable gate.'
$commandNames = @($gateAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst]
}, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
foreach ($forbidden in @('adb', 'adb.exe', 'am', 'pm', 'Start-Process',
        'Set-Content', 'Add-Content', 'Remove-Item', 'Move-Item', 'Copy-Item')) {
    Require-Test ($commandNames -cnotcontains $forbidden) `
        "Read-only Stable gate contains forbidden command: $forbidden"
}

. $gatePath
$buildLock = Get-Content -Raw -LiteralPath $buildLockPath | ConvertFrom-Json -Depth 30
$producerLock = Get-Content -Raw -LiteralPath $producerLockPath | ConvertFrom-Json -Depth 30
$acceptance = Get-Content -Raw -LiteralPath $acceptancePath | ConvertFrom-Json -Depth 30
$manualTemplate = Get-Content -Raw -LiteralPath $manualTemplatePath | ConvertFrom-Json -Depth 30

$gateText = [IO.File]::ReadAllText($gatePath).Replace("`r`n", "`n").Replace("`r", "`n")
$gateSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.UTF8Encoding]::new($false).GetBytes($gateText)))
Require-Test ($gateSha256 -ceq [string]$producerLock.producers.stableEvidenceGateScriptSha256 -and
    [string]$acceptance.validatorScript.path -ceq 'scripts/v71-rc5-stable-evidence-gate.ps1' -and
    [string]$acceptance.validatorScript.sha256 -ceq $gateSha256 -and
    [bool]$acceptance.validatorScript.readOnly -and
    -not [bool]$acceptance.validatorScript.deviceCapable) `
    'Stable validator script is not hash-locked as a read-only Host producer.'

Require-Test ([string]$script:V71Rc5LabPackage -ceq [string]$buildLock.target.package -and
    [string]$script:V71Rc5StablePackage -ceq [string]$buildLock.target.forbiddenStablePackage -and
    [string]$script:V71Rc5VersionName -ceq [string]$buildLock.target.versionName -and
    [string]$script:V71Rc5PojlibSha256 -ceq [string]$buildLock.pojlibAar.sha256) `
    'Stable gate did not consume candidate identity dynamically from V71_LAB_RC5.lock.json.'

Assert-V71Rc5BuildLockContract
$candidateBuilt = [bool]$buildLock.target.artifactAuditPassed -and
    [string]$buildLock.target.apkSha256 -cmatch '^[0-9A-F]{64}$' -and
    [int64]$buildLock.target.apkSizeBytes -gt 0
if ($candidateBuilt) {
    Assert-V71Rc5BuildLockContract -RequireBuiltApk
} else {
    Require-Test (Expect-Failure { Assert-V71Rc5BuildLockContract -RequireBuiltApk } `
        'PENDING_NOT_BUILT') 'Pending RC5 build was accepted as an audited APK.'
}

foreach ($field in @('expectedGameLogRelativePath',
        'expectedGameLogMinecraftVersion', 'expectedGameLogCoreVersion',
        'expectedGameLogVeqVersion')) {
    Require-Test ($null -ne $buildLock.runtimeBinding.PSObject.Properties[$field]) `
        "Build lock is missing runtimeBinding.$field."
    Require-Test ([IO.File]::ReadAllText($gatePath).Contains($field)) `
        "Stable gate does not validate runtimeBinding.$field."
}

Require-Test ([string]$acceptance.status -ceq 'PENDING_EVIDENCE' -and
    [string]$acceptance.candidateBuildLockPath -ceq 'V71_LAB_RC5.lock.json' -and
    [bool]$acceptance.identityRelockRequiredAfterFinalBuild -and
    [string]$acceptance.labIdentity.apkSha256 -ceq 'DYNAMIC_FROM_V71_LAB_RC5_LOCK') `
    'Checked-in Stable acceptance skeleton is not dynamic and fail-closed.'
$null = Assert-V71Rc5StableAcceptanceManifestContract $acceptance

$pendingRejected = Expect-Failure {
    Assert-V71Rc5StableAcceptanceEvidence `
        -ManifestPath $acceptancePath -RepoRoot $repoRoot `
        -EvidenceRoot (Split-Path -Parent (Split-Path -Parent $repoRoot)) `
        -MemorySamplerPath (Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc5.ps1') `
        -MemoryRuntimeContractPath `
            (Join-Path $PSScriptRoot 'quest-v71-memory-runtime-contract-rc5.ps1') `
        -PerformanceHarnessPath (Join-Path $PSScriptRoot 'quest-v71-rc4-rc5-ab.ps1') `
        -LifecycleHarnessPath `
            (Join-Path $PSScriptRoot 'quest-v71-lab-lifecycle-recovery-rc5.ps1')
} 'not ACCEPTED_FOR_STABLE_BUILD'
Require-Test $pendingRejected 'Checked-in pending evidence did not fail closed.'

$expectedLineagePaths = @(
    'scripts/quest-v71-lab-pair-rc5.ps1',
    'scripts/quest-vivecraft-core-canary-rc5.ps1',
    'scripts/quest-veq-lab-rc5.ps1',
    'scripts/reset-lab-benchmark-world.ps1',
    'scripts/run-vivecraft-local-autoplay.ps1',
    'scripts/quest-vrapi-pid-benchmark.ps1',
    'scripts/verify-dev-apk.ps1'
)
$lineageSource = [IO.File]::ReadAllText($gatePath)
foreach ($path in $expectedLineagePaths) {
    Require-Test ($lineageSource.Contains($path)) "Stable gate omits A/B dependency: $path"
}
Require-Test (-not $lineageSource.Contains('scripts/quest-v70-lab-pair.ps1') -and
    -not $lineageSource.Contains('scripts/quest-vivecraft-core-canary.ps1') -and
    -not $lineageSource.Contains('scripts/quest-veq-lab.ps1')) `
    'Stable gate still trusts the historical RC4 rollback helpers.'
Require-Test ($lineageSource.Contains("'VisualState'") -and
    $lineageSource.Contains("'OptionsSha256'") -and
    $lineageSource.Contains("'ResourcePacksFingerprintSha256'")) `
    'Stable gate does not bind exact options/resource-pack state for A/B.'

Require-Test ([string]$manualTemplate.status -ceq 'PENDING_EXPLICIT_USER_CONFIRMATION' -and
    [string]$manualTemplate.labIdentity.apkSha256 -ceq 'RELOCK_FROM_V71_LAB_RC5' -and
    @($manualTemplate.checks.PSObject.Properties).Count -eq
        @($script:V71Rc5ManualCheckNames).Count) `
    'Manual template is not pending, dynamic, and complete.'
foreach ($name in @('nativeContainerMenuDoesNotFollowHeadTurn',
        'nativeContainerMenuPointerWorks', 'nativeContainerMenuLocomotionWorks')) {
    Require-Test ($script:V71Rc5ManualCheckNames -ccontains $name -and
        $null -ne $manualTemplate.checks.PSObject.Properties[$name]) `
        "Manual contract omits required container check: $name"
}

# Exercise the manual validator independently even while the next Lab build is pending.
$syntheticApkSha = 'A' * 64
$syntheticApkSize = [int64]123456789
$savedApkSha = $script:V71Rc5ApkSha256
$script:V71Rc5ApkSha256 = $syntheticApkSha
try {
    $checks = [ordered]@{}
    foreach ($name in $script:V71Rc5ManualCheckNames) { $checks[$name] = 'PASS' }
    $manual = [pscustomobject][ordered]@{
        schemaVersion = [int64]1
        receiptType = 'V71_RC5_MANUAL_VR_INTERACTION'
        status = 'PASS_CONFIRMED_BY_USER'
        confirmation = [pscustomobject][ordered]@{
            source = 'explicit-user-message'
            recordedBy = 'human-recorded-from-explicit-user-confirmation'
            confirmedUtc = '2026-09-06T10:00:00Z'
            statement = 'User confirmed the exact RC5 manual scope.'
            userQuote = 'Everything in this exact RC5 check passed.'
        }
        labIdentity = [pscustomobject][ordered]@{
            package = $script:V71Rc5LabPackage
            forbiddenStablePackage = $script:V71Rc5StablePackage
            profile = '26.2'
            versionCode = [int64]$script:V71Rc5VersionCode
            versionName = $script:V71Rc5VersionName
            apkPath = $script:V71Rc5LabApkRelativePath
            apkSha256 = $syntheticApkSha
            apkSizeBytes = $syntheticApkSize
            coreVersion = $script:V71Rc5CoreVersion
            coreSha256 = $script:V71Rc5CoreSha256
            coreSizeBytes = [int64]$script:V71Rc5CoreSizeBytes
            veqVersion = $script:V71Rc5VeqVersion
            veqSha256 = $script:V71Rc5VeqSha256
            veqSizeBytes = [int64]$script:V71Rc5VeqSizeBytes
            coreVeqPairSha256 = $script:V71Rc5PairSha256
            pojlibAarSha256 = $script:V71Rc5PojlibSha256
            pojlibAarSizeBytes = [int64]$script:V71Rc5PojlibSizeBytes
            signerSha256 = $script:V71Rc5SignerSha256
        }
        checks = [pscustomobject]$checks
        exactCandidateRuntime = 'PASS'
        exactCandidateManualGate = 'PASS'
        stableTouched = $false
    }
    Assert-V71Rc5ManualAcceptanceReceipt $manual $syntheticApkSha $syntheticApkSize
    foreach ($name in @('nativeContainerMenuDoesNotFollowHeadTurn',
            'nativeContainerMenuPointerWorks', 'nativeContainerMenuLocomotionWorks')) {
        $manual.checks.$name = 'FAIL'
        Require-Test (Expect-Failure {
            Assert-V71Rc5ManualAcceptanceReceipt $manual $syntheticApkSha $syntheticApkSize
        } "check is not PASS: $name") "Manual validator accepted failed $name."
        $manual.checks.$name = 'PASS'
    }
} finally {
    $script:V71Rc5ApkSha256 = $savedApkSha
}

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceTouched = $false
    AdbInvocations = 0
    CandidateIdentityDynamic = $true
    CandidateArtifactReady = $candidateBuilt
    ExpectedGameLogFieldsValidated = 4
    PerformanceLineageUsesRc5Helpers = $true
    ExactOptionsAndResourcePacksRequired = $true
    ManualChecksValidated = @($script:V71Rc5ManualCheckNames).Count
    NativeContainerHeadStationaryRequired = $true
    NativeContainerPointerRequired = $true
    NativeContainerLocomotionRequired = $true
    PendingAcceptanceRejected = $pendingRejected
}
