#requires -Version 7.0
<#
.SYNOPSIS
Creates a non-sensitive, write-once cross-evidence receipt for v71 memory runs.

.DESCRIPTION
SelfTest and Create are Host-only. Each reviewed RC5 sampler captures the
launcher marker and exact JVM memory line at soak start, then binds the final
sample to the same Linux process incarnation (PID plus process starttime), live
JVM, and final provenance. Create validates those two
immutable per-soak receipts without depending on a 90-minute-old logcat marker.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Create')]
    [string] $Action = 'SelfTest',

    [string] $WorkspaceRoot = '',
    [string] $Soak1SummaryPath = '',
    [string] $Soak1SamplesPath = '',
    [string] $Soak1ProducerSha256 = '',
    [string] $Soak2SummaryPath = '',
    [string] $Soak2SamplesPath = '',
    [string] $Soak2ProducerSha256 = '',
    [string] $LifecycleReceiptPath = '',
    [string] $OutputPath = '',
    [switch] $AllowReceiptWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HashScheme = 'sha256-utf8-normalized-lf'
$script:ExpectedPackage = 'com.qcxr.qcxr.canary262'
$script:ExpectedStablePackage = 'com.qcxr.qcxr.dev262'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Rc5LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC5.lock.json'
$script:Rc5Lock = Get-Content -Raw -LiteralPath $script:Rc5LockPath | ConvertFrom-Json
$script:EvidenceContractPath = Join-Path $script:RepoRoot `
    'V71_RC5_EVIDENCE_PRODUCERS.lock.json'
$script:EvidenceContract = Get-Content -Raw -LiteralPath `
    $script:EvidenceContractPath | ConvertFrom-Json
foreach ($contractSection in @('memoryPolicy', 'coldStartRuntimeEvidence',
        'launcherResourceReleaseEvidence')) {
    $sectionValue = $script:EvidenceContract.PSObject.Properties[$contractSection].Value
    $script:Rc5Lock | Add-Member -NotePropertyName $contractSection `
        -NotePropertyValue $sectionValue -Force
}
$script:ExpectedVersionCode = [int]$script:Rc5Lock.target.versionCode
$script:ExpectedVersionName = [string]$script:Rc5Lock.target.versionName
$script:ExpectedApkSha256 = [string]$script:Rc5Lock.target.apkSha256
$script:ExpectedApkSizeBytes = [int64]$script:Rc5Lock.target.apkSizeBytes
$script:ExpectedCoreSha256 = [string]$script:Rc5Lock.pair.core.sha256
$script:ExpectedVeqSha256 = [string]$script:Rc5Lock.pair.veq.sha256
$script:ExpectedSignerSha256 = `
    'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedPojlibSha256 = [string]$script:Rc5Lock.pojlibAar.sha256
$script:ExpectedCurrentMemoryProducerSha256 = `
    [string]$script:EvidenceContract.producers.memorySoakScriptSha256
$script:ExpectedContractProducerSha256 = `
    [string]$script:EvidenceContract.producers.memoryRuntimeContractScriptSha256
$script:ExpectedLifecycleProducerSha256 = `
    [string]$script:EvidenceContract.producers.lifecycleRecoveryScriptSha256
$script:ExpectedAutoplayProducerSha256 = `
    [string]$script:EvidenceContract.producers.autoplayHarnessScriptSha256
$script:ExpectedGameLogRelativePath = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogRelativePath
$script:ExpectedGameLogMinecraftVersion = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogMinecraftVersion
$script:ExpectedGameLogCoreVersion = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogCoreVersion
$script:ExpectedGameLogVeqVersion = `
    [string]$script:Rc5Lock.runtimeBinding.expectedGameLogVeqVersion
$script:DefaultReceiptRelativePath = `
    'artifacts/acceptance/v71-rc5-memory-runtime-contract-receipt.json'
$script:Assertions = 0

function Require([bool] $Condition, [string] $Message) {
    $script:Assertions++
    if (-not $Condition) { throw "[V71_MEMORY_CONTRACT] $Message" }
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try {
        & $Operation
        return $false
    } catch {
        return $true
    }
}

function Get-Property($Object, [string] $Name, [string] $Context) {
    Require ($null -ne $Object) "$Context is absent."
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context.$Name is absent."
    return $property.Value
}

function ConvertTo-Sha256($Value, [string] $Context) {
    Require ($Value -is [string]) "$Context is not a string."
    $sha = ([string]$Value).ToUpperInvariant()
    Require ($sha -cmatch '^[0-9A-F]{64}$') "$Context is not a canonical SHA-256."
    return $sha
}

function Get-FileSha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-TextSha256([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Require (-not $text.StartsWith([string][char]0xFEFF,
        [StringComparison]::Ordinal)) 'A producer contains a UTF-8 BOM.'
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($normalized)))
}

function Get-ProducerLineageDigest([object[]] $Files) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("scheme=$($script:HashScheme)")
    foreach ($file in $Files) {
        $lines.Add(('{0}|{1}|{2}' -f
                [string](Get-Property $file 'name' 'lifecycle producer file'),
                [string](Get-Property $file 'relativePath' 'lifecycle producer file'),
                (ConvertTo-Sha256 (Get-Property $file 'sha256' 'lifecycle producer file') `
                    'lifecycle producer file SHA-256')))
    }
    $payload = ($lines -join "`n") + "`n"
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($payload)))
}

function Assert-BooleanProperty(
    $Object,
    [string] $Name,
    [bool] $Expected,
    [string] $Context
) {
    $value = Get-Property $Object $Name $Context
    Require ($value -is [bool] -and [bool]$value -eq $Expected) `
        "$Context.$Name drifted."
}

function Assert-Rc5CandidateReady {
    Require ($script:ExpectedGameLogRelativePath -ceq 'instances/26.2/logs/latest.log' -and
        $script:ExpectedGameLogMinecraftVersion -ceq '26.2' -and
        $script:ExpectedGameLogCoreVersion -ceq
            [string]$script:Rc5Lock.pair.core.fabricVersion -and
        $script:ExpectedGameLogVeqVersion -ceq
            [string]$script:Rc5Lock.pair.veq.fabricVersion) `
        'V71_LAB_RC5.lock.json expectedGameLog binding drifted.'
    Require ($script:ExpectedApkSha256 -cmatch '^[0-9A-F]{64}$' -and
        $script:ExpectedApkSha256 -cnotmatch '^0{64}$' -and
        $script:ExpectedApkSizeBytes -gt 0 -and
        [bool]$script:Rc5Lock.target.artifactAuditPassed) `
        'The exact RC5 Lab APK is pending build and artifact audit.'
    Require ($script:ExpectedCurrentMemoryProducerSha256 -cmatch '^[0-9A-F]{64}$' -and
        $script:ExpectedContractProducerSha256 -cmatch '^[0-9A-F]{64}$' -and
        $script:ExpectedLifecycleProducerSha256 -cmatch '^[0-9A-F]{64}$') `
        'The RC5 evidence-producer hashes are not locked yet.'
    Require ((Get-TextSha256 $PSCommandPath) -ceq $script:ExpectedContractProducerSha256) `
        'This memory-contract producer drifted from the RC5 producer lock; relock it before Create.'
    Require ((Get-TextSha256 (Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc5.ps1')) -ceq
            $script:ExpectedCurrentMemoryProducerSha256 -and
        (Get-TextSha256 (Join-Path $PSScriptRoot `
                'quest-v71-lab-lifecycle-recovery-rc5.ps1')) -ceq
            $script:ExpectedLifecycleProducerSha256) `
        'An RC5 evidence producer drifted from the RC5 producer lock.'
}

function Read-Json([string] $Path, [string] $Context) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { throw "[V71_MEMORY_CONTRACT] $Context is invalid JSON: $($_.Exception.Message)" }
}

function Assert-ContainedFile(
    [string] $Path,
    [string] $Root,
    [string] $Context
) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) "$Context path is absent."
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    Require ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) `
        "$Context is outside the workspace."
    $item = Get-Item -LiteralPath $full -Force
    Require (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        "$Context must not be a reparse point."
    return $full
}

function Get-Rc5LockPath {
    return Assert-ContainedFile $script:Rc5LockPath $script:RepoRoot 'RC5 lock'
}

function Assert-ExactLabIdentity($Identity, [string] $Context) {
    Require ([string](Get-Property $Identity 'package' $Context) -ceq
        $script:ExpectedPackage) "$Context package drifted."
    $stableProperty = $Identity.PSObject.Properties['forbiddenStablePackage']
    if ($null -ne $stableProperty) {
        Require ([string]$stableProperty.Value -ceq $script:ExpectedStablePackage) `
            "$Context Stable guard drifted."
    }
    Require ([int](Get-Property $Identity 'versionCode' $Context) -eq
        $script:ExpectedVersionCode) "$Context versionCode drifted."
    Require ([string](Get-Property $Identity 'versionName' $Context) -ceq
        $script:ExpectedVersionName) "$Context versionName drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'apkSha256' $Context) `
            "$Context APK SHA-256") -ceq $script:ExpectedApkSha256) `
        "$Context APK drifted."
    Require ([int64](Get-Property $Identity 'apkSizeBytes' $Context) -eq
        $script:ExpectedApkSizeBytes) "$Context APK size drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'coreSha256' $Context) `
            "$Context Core SHA-256") -ceq $script:ExpectedCoreSha256) `
        "$Context Core drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'veqSha256' $Context) `
            "$Context VEQ SHA-256") -ceq $script:ExpectedVeqSha256) `
        "$Context VEQ drifted."
    Require ((ConvertTo-Sha256 (Get-Property $Identity 'signerSha256' $Context) `
            "$Context signer SHA-256") -ceq $script:ExpectedSignerSha256) `
        "$Context signer drifted."
}

function Assert-Rc5BuildLock {
    param([switch] $AllowPendingArtifact)
    $target = Get-Property $script:Rc5Lock 'target' 'RC5 build lock'
    $pair = Get-Property $script:Rc5Lock 'pair' 'RC5 build lock'
    Require ([string](Get-Property $target 'package' 'RC5 target') -ceq
            $script:ExpectedPackage -and
        [string](Get-Property $target 'forbiddenStablePackage' 'RC5 target') -ceq
            $script:ExpectedStablePackage -and
        -not [bool](Get-Property $target 'stableTouched' 'RC5 target') -and
        [int](Get-Property $target 'versionCode' 'RC5 target') -eq
            $script:ExpectedVersionCode -and
        [string](Get-Property $target 'versionName' 'RC5 target') -ceq
            $script:ExpectedVersionName) `
        'The RC5 build target identity or Stable guard drifted.'
    $artifactReady = [bool](Get-Property $target 'artifactAuditPassed' 'RC5 target')
    if ($artifactReady) {
        Require ((ConvertTo-Sha256 (Get-Property $target 'apkSha256' 'RC5 target') `
                'RC5 APK SHA-256') -ceq $script:ExpectedApkSha256 -and
            [int64](Get-Property $target 'apkSizeBytes' 'RC5 target') -eq
                $script:ExpectedApkSizeBytes -and $script:ExpectedApkSizeBytes -gt 0) `
            'The built RC5 APK identity drifted.'
    } else {
        Require ($AllowPendingArtifact.IsPresent -and
            [string](Get-Property $target 'apkSha256' 'RC5 target') -ceq 'PENDING_NOT_BUILT' -and
            [int64](Get-Property $target 'apkSizeBytes' 'RC5 target') -eq 0) `
            'The RC5 APK is neither an audited artifact nor the exact pending-build sentinel.'
    }
    Require ((ConvertTo-Sha256 (Get-Property (Get-Property $pair 'core' 'RC5 pair') `
                'sha256' 'RC5 Core') 'RC5 Core SHA-256') -ceq
            $script:ExpectedCoreSha256 -and
        (ConvertTo-Sha256 (Get-Property (Get-Property $pair 'veq' 'RC5 pair') `
                'sha256' 'RC5 VEQ') 'RC5 VEQ SHA-256') -ceq
            $script:ExpectedVeqSha256) 'The RC5 Core/VEQ identity drifted.'
    Require ($script:ExpectedPojlibSha256 -cmatch '^[0-9A-F]{64}$') `
        'The RC5 Pojlib AAR identity is absent.'
    Require ($script:ExpectedGameLogRelativePath -ceq 'instances/26.2/logs/latest.log' -and
        $script:ExpectedGameLogMinecraftVersion -ceq '26.2' -and
        $script:ExpectedGameLogCoreVersion -ceq '26.2-1.3.15+qc.v71.rc5' -and
        $script:ExpectedGameLogVeqVersion -ceq '0.7.0-v70-canary.1') `
        'The RC5 expectedGameLog build binding drifted.'
}

function Assert-Rc5Contract($Lock) {
    Require ([int](Get-Property $Lock 'schemaVersion' 'RC5 lock') -eq 1) `
        'RC5 lock schema drifted.'
    $target = Get-Property $Lock 'target' 'RC5 lock'
    $pair = Get-Property $Lock 'pair' 'RC5 lock'
    Require (-not [bool](Get-Property $target 'stableTouched' 'RC5 target')) `
        'RC5 lock no longer protects Stable.'
    Require ([bool](Get-Property $target 'artifactAuditPassed' 'RC5 target') -and
        [int64](Get-Property $target 'apkSizeBytes' 'RC5 target') -gt 0 -and
        [string](Get-Property $target 'apkSha256' 'RC5 target') -cnotmatch '^0{64}$') `
        'The exact RC5 APK build/audit gate is still pending.'
    $identity = [pscustomobject][ordered]@{
        package = Get-Property $target 'package' 'RC5 target'
        forbiddenStablePackage = Get-Property $target 'forbiddenStablePackage' 'RC5 target'
        versionCode = Get-Property $target 'versionCode' 'RC5 target'
        versionName = Get-Property $target 'versionName' 'RC5 target'
        apkSha256 = Get-Property $target 'apkSha256' 'RC5 target'
        apkSizeBytes = Get-Property $target 'apkSizeBytes' 'RC5 target'
        coreSha256 = Get-Property (Get-Property $pair 'core' 'RC5 pair') 'sha256' 'RC5 Core'
        veqSha256 = Get-Property (Get-Property $pair 'veq' 'RC5 pair') 'sha256' 'RC5 VEQ'
        signerSha256 = $script:ExpectedSignerSha256
    }
    Assert-ExactLabIdentity $identity 'RC5 lock identity'

    $policy = Get-Property $Lock 'memoryPolicy' 'RC5 lock'
    Require ([int](Get-Property $policy 'xmsMiB' 'memory policy') -eq 512 -and
        [int](Get-Property $policy 'automaticXmxTargetMiB' 'memory policy') -eq 1536 -and
        [int](Get-Property $policy 'automaticXmxMinMiB' 'memory policy') -eq 1536 -and
        [int](Get-Property $policy 'xmxMaxMiB' 'memory policy') -eq 2048 -and
        [int](Get-Property $policy 'manualXmxMaxMiB' 'memory policy') -eq 2048) `
        'The bounded RC5 JVM memory policy drifted.'

    $cold = Get-Property $Lock 'coldStartRuntimeEvidence' 'RC5 lock'
    Require ([string](Get-Property $cold 'result' 'cold-start evidence') -ceq 'PASS' -and
        [int](Get-Property $cold 'normalLauncherStartCount' 'cold-start evidence') -eq 3 -and
        (Get-Property $cold 'allThreeRetainedExactRc5' 'cold-start evidence') -is [bool] -and
        [bool](Get-Property $cold 'allThreeRetainedExactRc5' 'cold-start evidence')) `
        'The exact-build three-cold-start evidence is absent.'
    Require ([string](Get-Property $cold 'lifecycleReceiptPath' 'cold-start evidence') -ceq
        'artifacts/acceptance/v71-lab-rc5-lifecycle-recovery-receipt.json') `
        'The cold-start lifecycle receipt path drifted.'
    $null = ConvertTo-Sha256 (Get-Property $cold 'lifecycleReceiptSha256' `
        'cold-start evidence') 'cold-start lifecycle receipt SHA-256'
    Assert-BooleanProperty $cold 'stablePackageModified' $false 'cold-start evidence'

    $release = Get-Property $Lock 'launcherResourceReleaseEvidence' 'RC5 lock'
    Require ([string](Get-Property $release 'policy' 'launcher release evidence') -ceq
        'default-on-only-for-exact-v71-rc5-lab-and-stable-identities-lab-authenticated-ab-may-override') `
        'The exact-build launcher-resource-release policy drifted.'
    Assert-BooleanProperty $release 'designRationaleCarriedFromRc3' $true `
        'launcher release evidence'
    $runtimeValidated = Get-Property $release 'exactRc5RuntimeValidated' `
        'launcher release evidence'
    $releaseResult = [string](Get-Property $release 'result' 'launcher release evidence')
    Require ($runtimeValidated -is [bool] -and
        ((-not [bool]$runtimeValidated -and $releaseResult -ceq 'PENDING_NOT_RUN') -or
        ([bool]$runtimeValidated -and $releaseResult -ceq 'PASS'))) `
        'The locked launcher release validation flag/result pair is contradictory.'
    Assert-BooleanProperty $release 'stableTouched' $false 'launcher release evidence'
}

function Assert-ProvenanceMatched($Provenance, [string] $Context) {
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        $value = Get-Property $Provenance $field $Context
        Require ($value -is [bool] -and [bool]$value) "$Context failed $field."
    }
}

function Assert-LifecycleReceipt($Receipt) {
    $context = 'lifecycle receipt'
    Require ([int](Get-Property $Receipt 'schemaVersion' $context) -eq 1 -and
        [string](Get-Property $Receipt 'receiptType' $context) -ceq
            'V71_LAB_RC5_LIFECYCLE_RECOVERY' -and
        [string](Get-Property $Receipt 'result' $context) -ceq 'PASS') `
        'The lifecycle receipt is not a PASS v71 RC5 lifecycle receipt.'
    Assert-ExactLabIdentity (Get-Property $Receipt 'labIdentity' $context) `
        'lifecycle receipt identity'

    $startedUtc = [DateTimeOffset]::Parse(
        [string](Get-Property $Receipt 'startedUtc' $context)).ToUniversalTime()
    $completedUtc = [DateTimeOffset]::Parse(
        [string](Get-Property $Receipt 'completedUtc' $context)).ToUniversalTime()
    Require ($completedUtc -gt $startedUtc) 'Lifecycle receipt timestamps are not ordered.'

    $lineage = Get-Property $Receipt 'producerLineage' $context
    Require ([int](Get-Property $lineage 'schemaVersion' 'lifecycle producer lineage') -eq 1 -and
        [string](Get-Property $lineage 'hashScheme' 'lifecycle producer lineage') -ceq
            $script:HashScheme) 'Lifecycle producer lineage schema drifted.'
    $lineageFiles = @(Get-Property $lineage 'files' 'lifecycle producer lineage')
    Require ($lineageFiles.Count -eq 2) 'Lifecycle producer lineage file count drifted.'
    $expectedLineage = @(
        @('lifecycle-orchestrator', 'scripts/quest-v71-lab-lifecycle-recovery-rc5.ps1',
            $script:ExpectedLifecycleProducerSha256),
        @('autoplay-harness', 'scripts/run-vivecraft-local-autoplay.ps1',
            $script:ExpectedAutoplayProducerSha256)
    )
    for ($index = 0; $index -lt $expectedLineage.Count; $index++) {
        $file = $lineageFiles[$index]
        $expected = $expectedLineage[$index]
        Require ([string](Get-Property $file 'name' "lifecycle producer $index") -ceq
                [string]$expected[0] -and
            [string](Get-Property $file 'relativePath' "lifecycle producer $index") -ceq
                [string]$expected[1] -and
            (ConvertTo-Sha256 (Get-Property $file 'sha256' "lifecycle producer $index") `
                "lifecycle producer $index SHA-256") -ceq [string]$expected[2]) `
            "Lifecycle producer lineage entry $index drifted."
    }
    Require ((ConvertTo-Sha256 (Get-Property $lineage 'digestSha256' `
                'lifecycle producer lineage') 'lifecycle producer lineage digest') -ceq
            (Get-ProducerLineageDigest $lineageFiles)) `
        'Lifecycle producer lineage digest is invalid.'

    $phases = @(Get-Property $Receipt 'phases' $context)
    $phaseContracts = @(
        @('preflight-exact-lab-and-rc5', @(
            'labInitiallyStopped', 'stableStopped', 'installedApkMatched', 'exactRc5PairBefore')),
        @('clean-cold-openxr', @(
            'startedFromStopped', 'exactRc5VersionRows', 'openXrFocused',
            'openXrFrame120Submitted', 'benchmarkWorldLoaded', 'gameJvmAlive')),
        @('post-openxr-process-stop-recovery', @(
            'liveOpenXrProcessStoppedBeforeRecovery', 'recoveryStartedFromStopped',
            'exactRc5VersionRows', 'openXrFocused', 'openXrFrame120Submitted',
            'benchmarkWorldLoaded', 'gameJvmAlive')),
        @('launcher-only-interruption', @(
            'startedFromStopped', 'launcherOnlyProven', 'unityMainPresent', 'gameJvmAbsent',
            'minecraftLogUntouched', 'interruptedByForceStop')),
        @('post-launcher-interruption-recovery', @(
            'launcherInterruptedBeforeRecovery', 'recoveryStartedFromStopped',
            'exactRc5VersionRows', 'openXrFocused', 'openXrFrame120Submitted',
            'benchmarkWorldLoaded', 'gameJvmAlive')),
        @('final-stopped-exact-rc5', @(
            'labStopped', 'stableStopped', 'exactRc5PairAfter',
            'installedLabApkUnchanged', 'hostArtifactsUnchanged'))
    )
    Require ($phases.Count -eq $phaseContracts.Count) 'Lifecycle phase count drifted.'
    for ($index = 0; $index -lt $phaseContracts.Count; $index++) {
        $phase = $phases[$index]
        $contract = $phaseContracts[$index]
        $phaseContext = "lifecycle phase $($contract[0])"
        Require ([string](Get-Property $phase 'name' $phaseContext) -ceq
                [string]$contract[0] -and
            [string](Get-Property $phase 'result' $phaseContext) -ceq 'PASS') `
            "$phaseContext identity drifted."
        foreach ($field in @($contract[1])) {
            Assert-BooleanProperty $phase $field $true $phaseContext
        }
    }
    Assert-BooleanProperty $phases[3] 'randomInputSent' $false `
        'lifecycle phase launcher-only-interruption'

    $finalState = Get-Property $Receipt 'finalState' $context
    Require ([string](Get-Property $finalState 'lab' 'lifecycle final state') -ceq 'stopped') `
        'Lifecycle final Lab state drifted.'
    foreach ($field in @('exactRc5Pair', 'installedLabApkUnchanged', 'stablePidAbsent')) {
        Assert-BooleanProperty $finalState $field $true 'lifecycle final state'
    }
    Assert-BooleanProperty $finalState 'stableTouched' $false 'lifecycle final state'

    $boundary = Get-Property $Receipt 'evidenceBoundary' $context
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted',
            'deviceSerialPersisted', 'processIdsPersisted', 'hostAbsolutePathsPersisted',
            'accountDataPersisted', 'saveDataPersistedByGate', 'randomInputSent',
            'manualInteractionClaim', 'performanceClaim', 'memorySoakClaim',
            'postInitAcknowledgementProven')) {
        Assert-BooleanProperty $boundary $field $false 'lifecycle evidence boundary'
    }
    Require ([string](Get-Property $boundary 'postInitAcknowledgementLimitation' `
            'lifecycle evidence boundary') -ceq
        'Frozen RC5 has no ACK; Unity launcher and JVM share one Android PID.') `
        'Lifecycle acknowledgement limitation drifted.'
}

function Assert-SoakRuntimeBinding(
    $Binding,
    [int] $InitialPid,
    [string] $ExpectedProducerSha256,
    [int] $Index
) {
    $context = "soak $Index runtime binding"
    Require ([int](Get-Property $Binding 'schemaVersion' $context) -eq 1 -and
        [string](Get-Property $Binding 'receiptType' $context) -ceq
            'V71_RC5_MEMORY_SOAK_RUNTIME_BINDING' -and
        [string](Get-Property $Binding 'result' $context) -ceq 'PASS') `
        "Soak $Index runtime binding identity drifted."
    $start = Get-Property $Binding 'start' $context
    $final = Get-Property $Binding 'final' $context
    Require ([int](Get-Property $start 'schemaVersion' "$context start") -eq 1 -and
        [string](Get-Property $start 'receiptType' "$context start") -ceq
            'V71_RC5_MEMORY_SOAK_RUNTIME_START' -and
        [string](Get-Property $start 'result' "$context start") -ceq 'PASS') `
        "Soak $Index start runtime receipt is not a PASS receipt."
    Require ([int](Get-Property $final 'schemaVersion' "$context final") -eq 1 -and
        [string](Get-Property $final 'receiptType' "$context final") -ceq
            'V71_RC5_MEMORY_SOAK_RUNTIME_FINAL' -and
        [string](Get-Property $final 'result' "$context final") -ceq 'PASS') `
        "Soak $Index final runtime receipt is not a PASS receipt."

    $startPid = [int](Get-Property $start 'pid' "$context start")
    $finalPid = [int](Get-Property $final 'pid' "$context final")
    $startTicks = [uint64](Get-Property $start 'processStartTicks' "$context start")
    $finalTicks = [uint64](Get-Property $final 'processStartTicks' "$context final")
    $expectedProducer = ConvertTo-Sha256 $ExpectedProducerSha256 `
        "soak $Index expected producer SHA-256"
    $startProducer = ConvertTo-Sha256 (Get-Property $start 'producerSha256' `
        "$context start") "soak $Index start producer SHA-256"
    Require ($startProducer -ceq $expectedProducer -and
        $startProducer -ceq $script:ExpectedCurrentMemoryProducerSha256) `
        "Soak $Index start receipt producer does not match the locked producer."
    Require ($startPid -eq $InitialPid -and $finalPid -eq $InitialPid -and
        $startTicks -gt 0 -and $finalTicks -eq $startTicks) `
        "Soak $Index start/final receipts are not the same process incarnation."
    foreach ($pair in @(
        ,@($start, 'exactPidAlive', "$context start")
        ,@($start, 'gameJvmAlive', "$context start")
        ,@($start, 'provenanceMatched', "$context start")
        ,@($start, 'exactJvmMemoryLineObserved', "$context start")
        ,@($start, 'launcherResourceReleaseAppliedObserved', "$context start")
        ,@($start, 'launcherMarkerTemporallyBoundToProcess', "$context start")
        ,@($start, 'launcherLogTemporallyBoundToProcess', "$context start")
        ,@($start, 'runtimeFenceBeforeStartProvenance', "$context start")
        ,@($start, 'runtimeFenceAfterStartProvenance', "$context start")
        ,@($final, 'sameProcessIncarnation', "$context final")
        ,@($final, 'exactPidAlive', "$context final")
        ,@($final, 'gameJvmAlive', "$context final")
        ,@($final, 'provenanceMatched', "$context final")
        ,@($final, 'startJvmMemoryObservationCarriedForward', "$context final")
        ,@($final, 'startLauncherMarkerCarriedForward', "$context final")
        ,@($final, 'runtimeFenceBeforeFinalProvenance', "$context final")
        ,@($final, 'runtimeFenceAfterFinalProvenance', "$context final")
    )) {
        $value = Get-Property $pair[0] $pair[1] $pair[2]
        Require ($value -is [bool] -and [bool]$value) `
            "Soak $Index runtime receipt failed $($pair[1])."
    }
    foreach ($endpoint in @(
        ,@($start, "$context start")
        ,@($final, "$context final")
    )) {
        foreach ($field in @('expectedGameLogPathMatched',
                'expectedGameLogRegularAndNonEmpty', 'expectedGameLogSameFile',
                'expectedGameLogTemporallyBoundToProcess', 'expectedGameLogFresh',
                'expectedMinecraftVersionObserved', 'expectedVivecraftVersionObserved',
                'expectedVeqVersionObserved')) {
            Assert-BooleanProperty $endpoint[0] $field $true $endpoint[1]
        }
    }
    Require ([int](Get-Property $start 'xmsMiB' "$context start") -eq 512 -and
        [int](Get-Property $start 'xmxMiB' "$context start") -eq 1536 -and
        [string](Get-Property $start 'xmxSource' "$context start") -ceq 'auto' -and
        [int](Get-Property $start 'jvmMemoryLineCount' "$context start") -eq 1 -and
        [int64](Get-Property $start 'launcherLogSizeBytes' "$context start") -gt 0) `
        "Soak $Index start JVM memory observation drifted."
    Require ([int](Get-Property $start 'launcherReleaseAppliedMarkerCount' `
            "$context start") -ge 1 -and
        [int](Get-Property $start 'launcherReleaseDegradedMarkerCount' `
            "$context start") -eq 0) `
        "Soak $Index start launcher marker observation drifted."
    $startEpoch = [double](Get-Property $start 'processStartEpochSeconds' "$context start")
    $finalEpoch = [double](Get-Property $final 'processStartEpochSeconds' "$context final")
    $launcherLogEpoch = [int64](Get-Property $start `
        'launcherLogModifiedEpochSeconds' "$context start")
    $launcherMarkerEpoch = [double](Get-Property $start `
        'launcherAppliedMarkerEpochSeconds' "$context start")
    $startGameLogEpoch = [int64](Get-Property $start `
        'expectedGameLogModifiedEpochSeconds' "$context start")
    $startGameLogObservedEpoch = [int64](Get-Property $start `
        'expectedGameLogObservedDeviceEpochSeconds' "$context start")
    $finalGameLogEpoch = [int64](Get-Property $final `
        'expectedGameLogModifiedEpochSeconds' "$context final")
    $finalGameLogObservedEpoch = [int64](Get-Property $final `
        'expectedGameLogObservedDeviceEpochSeconds' "$context final")
    Require ($startEpoch -gt 0.0 -and $finalEpoch -gt 0.0 -and
        [math]::Abs($finalEpoch - $startEpoch) -le 2.0 -and
        $launcherLogEpoch -ge [math]::Floor($startEpoch - 3.0) -and
        $launcherMarkerEpoch -ge ($startEpoch - 3.0) -and
        $startGameLogEpoch -ge [math]::Floor($startEpoch - 2.0) -and
        $startGameLogEpoch -le ($startGameLogObservedEpoch + 2) -and
        $finalGameLogEpoch -ge $startGameLogEpoch -and
        $finalGameLogEpoch -le ($finalGameLogObservedEpoch + 2)) `
        "Soak $Index temporal process/log binding drifted."
    $finalMarkerRequired = Get-Property $final 'finalLogcatMarkerRequired' "$context final"
    Require ($finalMarkerRequired -is [bool] -and -not [bool]$finalMarkerRequired) `
        "Soak $Index incorrectly requires a retained final logcat marker."

    $startUtc = [DateTimeOffset]::Parse(
        [string](Get-Property $start 'observedUtc' "$context start")).ToUniversalTime()
    $finalUtc = [DateTimeOffset]::Parse(
        [string](Get-Property $final 'observedUtc' "$context final")).ToUniversalTime()
    Require ($finalUtc -gt $startUtc) "Soak $Index runtime timestamps are not ordered."

    $boundary = Get-Property $Binding 'evidenceBoundary' $context
    $capturedAtStart = Get-Property $boundary 'logcatMarkerCapturedOnlyAtStart' `
        "$context evidence boundary"
    $noFinalMarker = Get-Property $boundary 'finalLogcatMarkerRequired' `
        "$context evidence boundary"
    $pidReuseDefense = Get-Property $boundary `
        'processStartTicksPersistedForPidReuseDefense' "$context evidence boundary"
    Require ($capturedAtStart -is [bool] -and [bool]$capturedAtStart -and
        $noFinalMarker -is [bool] -and -not [bool]$noFinalMarker -and
        $pidReuseDefense -is [bool] -and [bool]$pidReuseDefense) `
        "Soak $Index runtime evidence boundary drifted."
    foreach ($field in @('processStartEpochPersistedForLogBinding',
            'producerHashCapturedAtLaunch', 'producerFileReadLockedForRun',
            'launcherMarkerTemporallyBoundToProcess',
            'launcherLogTemporallyBoundToProcess',
            'expectedProfileGameLogPathFixed',
            'expectedGameLogIdentityCheckedAtStartAndFinal',
            'expectedGameLogFreshnessCheckedEverySample',
            'expectedGameLogEvidenceOnlyBooleansAndTimestamps',
            'gameJvmLivenessObservedAtBoundedFencesAndSamples')) {
        Assert-BooleanProperty $boundary $field $true "$context evidence boundary"
    }
    Assert-BooleanProperty $boundary 'continuousGameJvmLivenessClaimed' $false `
        "$context evidence boundary"
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted',
            'deviceSerialPersisted', 'accountDataPersisted',
            'hostAbsolutePathsPersisted')) {
        $value = Get-Property $boundary $field "$context evidence boundary"
        Require ($value -is [bool] -and -not [bool]$value) `
            "Soak $Index runtime receipt persisted forbidden evidence: $field."
    }
    return [pscustomobject][ordered]@{
        index = $Index
        available = $true
        evidenceBasis = 'integrated-start-final-same-process-incarnation'
        initialPid = $InitialPid
        processStartTicks = $startTicks
        processStartEpochSeconds = $startEpoch
        producerSha256 = $startProducer
        startObservedUtc = $startUtc.ToString('o')
        finalObservedUtc = $finalUtc.ToString('o')
        sameAndroidProcessIncarnation = $true
        gameJvmAliveAtStartAndFinal = $true
        provenanceMatchedAtStartAndFinal = $true
        xmsMiB = 512
        xmxMiB = 1536
        xmxSource = 'auto'
        launcherResourceReleaseAppliedAtStart = $true
        launcherMarkerTemporallyBoundToProcess = $true
        launcherLogTemporallyBoundToProcess = $true
        expectedProfileGameLogPathFixed = $true
        expectedGameLogIdentityCheckedAtStartAndFinal = $true
        expectedGameLogFreshnessCheckedEverySample = $true
        expectedGameLogEvidenceOnlyBooleansAndTimestamps = $true
        gameJvmLivenessObservedAtBoundedFencesAndSamples = $true
        continuousGameJvmLivenessClaimed = $false
        finalLogcatMarkerRequired = $false
    }
}

function Get-RecomputedSoakMetrics(
    [object[]] $Samples,
    [int] $DurationMinutes,
    [int] $IntervalSeconds,
    [int] $Index
) {
    $postWarm = @($Samples | Where-Object { [double]$_.elapsedMinutes -ge 15.0 })
    $lastThirtyStart = [math]::Max(0, $DurationMinutes - 30)
    $lastThirty = @($Samples | Where-Object {
        [double]$_.elapsedMinutes -ge [double]$lastThirtyStart
    })
    $minimumPostWarmSamples = [math]::Max(
        2,
        [int][math]::Floor((($DurationMinutes - 15) * 60.0) / $IntervalSeconds) + 1)
    $minimumLastThirtySamples = [math]::Max(
        2,
        [int][math]::Floor(([math]::Min(30, $DurationMinutes) * 60.0) /
            $IntervalSeconds) + 1)
    Require ($postWarm.Count -ge $minimumPostWarmSamples -and
        $lastThirty.Count -ge $minimumLastThirtySamples) `
        "Soak $Index raw samples do not cover the required analysis windows."

    $meanX = ($postWarm | Measure-Object elapsedMinutes -Average).Average
    $meanY = ($postWarm | ForEach-Object {
        [double]$_.totalPssKib / 1024.0
    } | Measure-Object -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($sample in $postWarm) {
        $dx = [double]$sample.elapsedMinutes - [double]$meanX
        $dy = ([double]$sample.totalPssKib / 1024.0) - [double]$meanY
        $numerator += $dx * $dy
        $denominator += $dx * $dx
    }
    $slope = if ($denominator -eq 0.0) {
        0.0
    } else {
        [math]::Round($numerator / $denominator, 3)
    }
    $lastThirtyGrowth = [math]::Round(
        ([double]$lastThirty[-1].totalPssKib -
            [double]$lastThirty[0].totalPssKib) / 1024.0,
        3)

    return [pscustomobject][ordered]@{
        maxPssMib = [math]::Round(
            [double](($Samples | Measure-Object totalPssKib -Maximum).Maximum) / 1024.0, 3)
        maxRssMib = [math]::Round(
            [double](($Samples | Measure-Object vmRssKib -Maximum).Maximum) / 1024.0, 3)
        maxProcessSwapMib = [math]::Round(
            [double](($Samples | Measure-Object vmSwapKib -Maximum).Maximum) / 1024.0, 3)
        minMemAvailableMib = [math]::Round(
            [double](($Samples | Measure-Object memAvailableKib -Minimum).Minimum) / 1024.0, 3)
        minSwapFreeMib = [math]::Round(
            [double](($Samples | Measure-Object swapFreeKib -Minimum).Minimum) / 1024.0, 3)
        postWarmPssSlopeMibPerMinute = $slope
        lastThirtyMinutesGrowthMib = $lastThirtyGrowth
    }
}

function Assert-RecomputedMetric(
    $Summary,
    [string] $Name,
    [double] $Expected,
    [string] $Context
) {
    $actual = Get-Property $Summary $Name $Context
    Require ($null -ne $actual -and [double]$actual -eq $Expected) `
        "$Context.$Name does not match the raw samples."
}

function Get-SoakEvidence(
    [string] $SummaryPath,
    [string] $SamplesPath,
    [string] $ProducerSha256,
    [int] $Index
) {
    $summary = Read-Json $SummaryPath "soak $Index summary"
    Require ([int](Get-Property $summary 'schemaVersion' "soak $Index summary") -eq 2 -and
        [string](Get-Property $summary 'package' "soak $Index summary") -ceq
            $script:ExpectedPackage) "Soak $Index summary identity drifted."
    $acceptance = Get-Property $summary 'acceptance' "soak $Index summary"
    foreach ($field in @('completedDuration', 'sampleCountComplete',
            'allRequiredMetricsPresent', 'focusStayedOnLab', 'gameJvmStayedAlive',
            'postWarmSamplesComplete', 'lastThirtySamplesComplete',
            'maxPssAtMost2457Point6Mib', 'maxRssAtMost2457Point6Mib',
            'processSwapAtMost512Mib', 'slopeAtMost2MibPerMinute',
            'lastThirtyGrowthAtMost128Mib', 'passed')) {
        Assert-BooleanProperty $acceptance $field $true "soak $Index acceptance"
    }
    Require ([int](Get-Property $summary 'requestedDurationMinutes' `
                "soak $Index summary") -eq 90 -and
        [int](Get-Property $summary 'intervalSeconds' "soak $Index summary") -eq 300 -and
        [int](Get-Property $summary 'samples' "soak $Index summary") -eq 19 -and
        [int](Get-Property $summary 'minimumExpectedSamples' "soak $Index summary") -eq 19 -and
        [int](Get-Property $summary 'completeMetricSamples' "soak $Index summary") -eq 19) `
        "Soak $Index capture dimensions drifted from the required 90-minute run."
    foreach ($field in @('pidStable', 'focusStayedOnLab', 'gameJvmStayedAlive')) {
        Assert-BooleanProperty $summary $field $true "soak $Index summary"
    }
    $provenance = Get-Property $summary 'provenance' "soak $Index summary"
    $finalProvenance = Get-Property $summary 'finalProvenance' "soak $Index summary"
    Assert-ProvenanceMatched $provenance "soak $Index start provenance"
    Assert-ProvenanceMatched $finalProvenance "soak $Index final provenance"
    $producer = ConvertTo-Sha256 $ProducerSha256 "soak $Index producer SHA-256"
    Require ($producer -ceq $script:ExpectedCurrentMemoryProducerSha256) `
        "Soak $Index did not use the exact reviewed RC5 producer."
    $summaryProducer = ConvertTo-Sha256 (Get-Property $summary 'producerSha256' `
        "soak $Index summary") "soak $Index summary producer SHA-256"
    Require ($summaryProducer -ceq $producer -and
        $summaryProducer -ceq $script:ExpectedCurrentMemoryProducerSha256) `
        "Soak $Index summary producer does not match the locked producer."
    $sampleRows = @(Get-Content -LiteralPath $SamplesPath | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    Require ($sampleRows.Count -eq 19) "Soak $Index raw sample count drifted."
    $samples = @($sampleRows | ForEach-Object { $_ | ConvertFrom-Json })
    $initialPid = [int](Get-Property $summary 'initialPid' "soak $Index summary")
    $previousTimestamp = $null
    $previousElapsedMinutes = $null
    foreach ($sample in $samples) {
        $sampleTimestamp = [DateTimeOffset]::Parse(
            [string](Get-Property $sample 'timestampUtc' "soak $Index sample")).ToUniversalTime()
        Require ($null -eq $previousTimestamp -or $sampleTimestamp -gt $previousTimestamp) `
            "Soak $Index sample timestamps are not strictly ordered."
        $previousTimestamp = $sampleTimestamp
        $elapsedMinutes = [double](Get-Property $sample 'elapsedMinutes' "soak $Index sample")
        Require ($elapsedMinutes -ge 0.0 -and
            ($null -eq $previousElapsedMinutes -or $elapsedMinutes -gt $previousElapsedMinutes)) `
            "Soak $Index sample elapsed times are not strictly ordered."
        $previousElapsedMinutes = $elapsedMinutes
        Require ([int](Get-Property $sample 'pid' "soak $Index sample") -eq $initialPid) `
            "Soak $Index contains a sample from another process."
        Assert-BooleanProperty $sample 'pidStable' $true "soak $Index sample"
        Assert-BooleanProperty $sample 'gameJvmAlive' $true "soak $Index sample"
        Require ([string](Get-Property $sample 'focus' "soak $Index sample") -ceq 'focused') `
            "Soak $Index contains a sample taken while Lab was not focused."
        foreach ($metric in @('totalPssKib', 'totalRssKib', 'javaHeapKib',
                'nativeHeapKib', 'graphicsKib', 'vmRssKib', 'vmSwapKib',
                'memAvailableKib', 'swapFreeKib')) {
            Require ([int64](Get-Property $sample $metric "soak $Index sample") -ge 0) `
                "Soak $Index sample metric $metric is invalid."
        }
    }
    $last = $samples[-1]
    $startedUtc = [DateTimeOffset]::Parse(
        [string](Get-Property $summary 'startedUtc' "soak $Index summary")).ToUniversalTime()
    Require ([DateTimeOffset]::Parse([string]$samples[0].timestampUtc).ToUniversalTime() -ge
            $startedUtc -and [double]$last.elapsedMinutes -ge 90.0) `
        "Soak $Index raw samples do not cover the declared 90-minute capture."
    $recomputed = Get-RecomputedSoakMetrics $samples 90 300 $Index
    foreach ($metric in @('maxPssMib', 'maxRssMib', 'maxProcessSwapMib',
            'minMemAvailableMib', 'minSwapFreeMib', 'postWarmPssSlopeMibPerMinute',
            'lastThirtyMinutesGrowthMib')) {
        Assert-RecomputedMetric $summary $metric ([double]$recomputed.$metric) `
            "soak $Index summary"
    }
    Require ([double]$recomputed.maxPssMib -le 2457.6 -and
        [double]$recomputed.maxRssMib -le 2457.6 -and
        [double]$recomputed.maxProcessSwapMib -le 512.0 -and
        [double]$recomputed.postWarmPssSlopeMibPerMinute -le 2.0 -and
        [double]$recomputed.lastThirtyMinutesGrowthMib -le 128.0) `
        "Soak $Index raw samples fail the memory acceptance thresholds."
    Require ([int](Get-Property $last 'pid' "soak $Index final sample") -eq
        $initialPid -and
        [bool](Get-Property $last 'pidStable' "soak $Index final sample") -and
        [bool](Get-Property $last 'gameJvmAlive' "soak $Index final sample")) `
        "Soak $Index final sample is not the original live JVM."
    $runtimeObservation = Assert-SoakRuntimeBinding `
        (Get-Property $summary 'runtimeBinding' "soak $Index summary") `
        $initialPid $producer $Index
    return [pscustomobject][ordered]@{
        index = $Index
        summarySha256 = Get-FileSha256 $SummaryPath
        samplesSha256 = Get-FileSha256 $SamplesPath
        producerSha256 = $producer
        startedUtc = $startedUtc.ToString('o')
        finalSampleUtc = [DateTimeOffset]::Parse(
            [string](Get-Property $last 'timestampUtc' "soak $Index final sample")).ToUniversalTime().ToString('o')
        initialPid = $initialPid
        runtimeObservation = $runtimeObservation
    }
}

function New-MemoryRuntimeContractReceipt(
    $Rc5Lock,
    [object[]] $Soaks,
    $LifecycleReceipt,
    [string] $LifecycleReceiptSha256,
    [string] $ProducerSha256,
    [DateTimeOffset] $CreatedUtc
) {
    Assert-Rc5Contract $Rc5Lock
    Require ($Soaks.Count -eq 2) 'Exactly two memory captures are required.'
    Assert-LifecycleReceipt $LifecycleReceipt
    $lifecycleSha = ConvertTo-Sha256 $LifecycleReceiptSha256 `
        'lifecycle receipt SHA-256'
    $coldStartEvidence = Get-Property $Rc5Lock 'coldStartRuntimeEvidence' 'RC5 lock'
    $lockedLifecycleSha = ConvertTo-Sha256 `
        (Get-Property $coldStartEvidence 'lifecycleReceiptSha256' 'cold-start evidence') `
        'locked lifecycle receipt SHA-256'
    Require ($lifecycleSha -ceq $lockedLifecycleSha) `
        'The lifecycle receipt does not match the receipt bound by the RC5 lock.'
    foreach ($soak in $Soaks) {
        $observation = Get-Property $soak 'runtimeObservation' `
            "soak $($soak.index) runtime observation"
        Require ([bool](Get-Property $observation 'available' `
                "soak $($soak.index) runtime observation")) `
            "Soak $($soak.index) lacks direct start/final runtime binding."
        Require ([int](Get-Property $observation 'initialPid' `
                "soak $($soak.index) runtime observation") -eq [int]$soak.initialPid) `
            "Soak $($soak.index) runtime observation PID drifted."
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC5_MEMORY_RUNTIME_CONTRACT'
        result = 'PASS'
        createdUtc = $CreatedUtc.ToUniversalTime().ToString('o')
        producer = [pscustomobject][ordered]@{
            hashScheme = $script:HashScheme
            sha256 = ConvertTo-Sha256 $ProducerSha256 'memory-contract producer SHA-256'
        }
        labIdentity = [pscustomobject][ordered]@{
            package = $script:ExpectedPackage
            forbiddenStablePackage = $script:ExpectedStablePackage
            versionCode = $script:ExpectedVersionCode
            versionName = $script:ExpectedVersionName
            apkSha256 = $script:ExpectedApkSha256
            apkSizeBytes = $script:ExpectedApkSizeBytes
            coreSha256 = $script:ExpectedCoreSha256
            veqSha256 = $script:ExpectedVeqSha256
            signerSha256 = $script:ExpectedSignerSha256
        }
        memoryPolicy = [pscustomobject][ordered]@{
            xmsMiB = 512
            automaticXmxMiB = 1536
            manualXmxHardCapMiB = 2048
            pojlibAarSha256 = $script:ExpectedPojlibSha256
            lifecycleColdStartsRetainingExactRc5 = 3
            directSoakStartJvmObservations = 2
            allDirectSoakStartsObservedAutomatic1536 = $true
            evidenceBasis = 'locked-memory-policy-plus-two-direct-soak-start-observations'
            perSoakJvmArgumentObservedDirectly = $true
        }
        launcherResourceRelease = [pscustomobject][ordered]@{
            exactBuildDefaultOn = $true
            lifecycleProducerRequestsOn = $true
            lifecycleReceiptSha256 = $lifecycleSha
            evidenceBasis = 'exact-apk-default-on-policy-plus-reviewed-on-lifecycle-producer'
            perSoakAppliedMarkerObservedDirectlyAtStart = $true
            finalLogcatMarkerRetentionRequired = $false
        }
        soaks = $Soaks
        directObservations = @($Soaks | ForEach-Object { $_.runtimeObservation })
        evidenceBoundary = [pscustomobject][ordered]@{
            crossEvidenceContractNotPerProcessAttestation = $false
            directPerSoakJvmArgumentClaim = $true
            directPerSoakResourceReleaseMarkerClaim = $true
            launcherMarkerCapturedOnlyAtSoakStart = $true
            finalLogcatMarkerRetentionRequired = $false
            sameProcessIncarnationUsesPidAndStartTicks = $true
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
}

function Write-AtomicWriteOnceJson($Value, [string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    Require (-not (Test-Path -LiteralPath $full)) `
        'The fixed memory-contract receipt already exists; archive and relock it first.'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    $temporary = $full + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $full)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject]@{
        Path = $full
        Sha256 = Get-FileSha256 $full
        SizeBytes = (Get-Item -LiteralPath $full).Length
    }
}

if ($Action -ceq 'SelfTest') {
    Require ($script:ExpectedPackage -ceq 'com.qcxr.qcxr.canary262') 'Lab package drifted.'
    Require ($script:ExpectedStablePackage -ceq 'com.qcxr.qcxr.dev262') 'Stable guard drifted.'
    Assert-Rc5BuildLock -AllowPendingArtifact
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    Require ($parseErrors.Count -eq 0) 'The Host-only producer has parser errors.'
    $commandNames = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    Require (@($commandNames | Where-Object { $_ -cin @('adb', 'adb.exe') }).Count -eq 0) `
        'The Host-only producer invokes a device command.'
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v71-memory-contract-' +
        [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    try {
        $path = Join-Path $tempRoot 'receipt.json'
        $fixture = [pscustomobject][ordered]@{ schemaVersion = 1; result = 'PASS' }
        $first = Write-AtomicWriteOnceJson $fixture $path
        Require ((Get-FileSha256 $path) -ceq [string]$first.Sha256) `
            'Atomic receipt hash self-test failed.'
        $rejected = $false
        try { $null = Write-AtomicWriteOnceJson $fixture $path } catch { $rejected = $true }
        Require $rejected 'Write-once receipt accepted an overwrite.'

        $outerEvidenceRoot = Join-Path $tempRoot 'outer-evidence'
        [IO.Directory]::CreateDirectory($outerEvidenceRoot) | Out-Null
        $outerEvidencePath = Join-Path $outerEvidenceRoot 'evidence.json'
        [IO.File]::WriteAllText($outerEvidencePath, '{}', [Text.UTF8Encoding]::new($false))
        $containedEvidence = Assert-ContainedFile $outerEvidencePath $outerEvidenceRoot `
            'distinct-root evidence fixture'
        $resolvedLock = Get-Rc5LockPath
        $outerFull = [IO.Path]::GetFullPath($outerEvidenceRoot).TrimEnd('\', '/') +
            [IO.Path]::DirectorySeparatorChar
        Require ($containedEvidence.StartsWith($outerFull,
                [StringComparison]::OrdinalIgnoreCase) -and
            $resolvedLock -ceq [IO.Path]::GetFullPath($script:Rc5LockPath) -and
            -not $resolvedLock.StartsWith($outerFull,
                [StringComparison]::OrdinalIgnoreCase)) `
            'Repo lock resolution was coupled to the outer evidence workspace.'
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
    $selfSha = Get-TextSha256 $PSCommandPath
    $fixtureMemoryProducerSha = Get-TextSha256 (Join-Path $PSScriptRoot `
        'quest-v71-memory-soak-rc5.ps1')
    $fixtureLifecycleProducerSha = Get-TextSha256 (Join-Path $PSScriptRoot `
        'quest-v71-lab-lifecycle-recovery-rc5.ps1')
    $fixtureApkSha = 'A' * 64
    $fixtureApkSize = 128000001L
    $savedApkSha = $script:ExpectedApkSha256
    $savedApkSize = $script:ExpectedApkSizeBytes
    $savedMemoryProducerSha = $script:ExpectedCurrentMemoryProducerSha256
    $savedLifecycleProducerSha = $script:ExpectedLifecycleProducerSha256
    $script:ExpectedApkSha256 = $fixtureApkSha
    $script:ExpectedApkSizeBytes = $fixtureApkSize
    $script:ExpectedCurrentMemoryProducerSha256 = $fixtureMemoryProducerSha
    $script:ExpectedLifecycleProducerSha256 = $fixtureLifecycleProducerSha
    $provenanceFixture = [pscustomobject][ordered]@{
        installedIdentityMatched = $true
        baseApkMatched = $true
        persistentCoreMatched = $true
        persistentVeqMatched = $true
        allMatched = $true
    }
    $runtimeBindingFixture = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC5_MEMORY_SOAK_RUNTIME_BINDING'
        result = 'PASS'
        start = [pscustomobject][ordered]@{
            schemaVersion = 1
            receiptType = 'V71_RC5_MEMORY_SOAK_RUNTIME_START'; result = 'PASS'
            observedUtc = '2026-09-06T06:16:24.0000000+00:00'
            pid = 111; processStartTicks = [uint64]1001
            producerSha256 = $fixtureMemoryProducerSha
            processStartEpochSeconds = 1700000000.0
            exactPidAlive = $true; gameJvmAlive = $true; provenanceMatched = $true
            exactJvmMemoryLineObserved = $true
            xmsMiB = 512; xmxMiB = 1536; xmxSource = 'auto'; jvmMemoryLineCount = 1
            launcherLogSizeBytes = 4096
            launcherLogModifiedEpochSeconds = 1700000001
            launcherLogTemporallyBoundToProcess = $true
            launcherResourceReleaseAppliedObserved = $true
            launcherReleaseAppliedMarkerCount = 1
            launcherReleaseDegradedMarkerCount = 0
            launcherAppliedMarkerEpochSeconds = 1700000001.0
            launcherMarkerTemporallyBoundToProcess = $true
            expectedGameLogPathMatched = $true
            expectedGameLogRegularAndNonEmpty = $true
            expectedGameLogSameFile = $true
            expectedGameLogTemporallyBoundToProcess = $true
            expectedGameLogFresh = $true
            expectedMinecraftVersionObserved = $true
            expectedVivecraftVersionObserved = $true
            expectedVeqVersionObserved = $true
            expectedGameLogModifiedEpochSeconds = 1700000001
            expectedGameLogObservedDeviceEpochSeconds = 1700000002
            runtimeFenceBeforeStartProvenance = $true
            runtimeFenceAfterStartProvenance = $true
        }
        final = [pscustomobject][ordered]@{
            schemaVersion = 1
            receiptType = 'V71_RC5_MEMORY_SOAK_RUNTIME_FINAL'; result = 'PASS'
            observedUtc = '2026-09-06T07:46:24.0000000+00:00'
            pid = 111; processStartTicks = [uint64]1001
            processStartEpochSeconds = 1700000000.0
            sameProcessIncarnation = $true; exactPidAlive = $true
            gameJvmAlive = $true; provenanceMatched = $true
            startJvmMemoryObservationCarriedForward = $true
            startLauncherMarkerCarriedForward = $true
            finalLogcatMarkerRequired = $false
            expectedGameLogPathMatched = $true
            expectedGameLogRegularAndNonEmpty = $true
            expectedGameLogSameFile = $true
            expectedGameLogTemporallyBoundToProcess = $true
            expectedGameLogFresh = $true
            expectedMinecraftVersionObserved = $true
            expectedVivecraftVersionObserved = $true
            expectedVeqVersionObserved = $true
            expectedGameLogModifiedEpochSeconds = 1700005401
            expectedGameLogObservedDeviceEpochSeconds = 1700005402
            runtimeFenceBeforeFinalProvenance = $true
            runtimeFenceAfterFinalProvenance = $true
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            logcatMarkerCapturedOnlyAtStart = $true
            finalLogcatMarkerRequired = $false
            processStartTicksPersistedForPidReuseDefense = $true
            processStartEpochPersistedForLogBinding = $true
            producerHashCapturedAtLaunch = $true
            producerFileReadLockedForRun = $true
            launcherMarkerTemporallyBoundToProcess = $true
            launcherLogTemporallyBoundToProcess = $true
            expectedProfileGameLogPathFixed = $true
            expectedGameLogIdentityCheckedAtStartAndFinal = $true
            expectedGameLogFreshnessCheckedEverySample = $true
            expectedGameLogEvidenceOnlyBooleansAndTimestamps = $true
            gameJvmLivenessObservedAtBoundedFencesAndSamples = $true
            continuousGameJvmLivenessClaimed = $false
            rawLogsPersisted = $false; logSnippetsPersisted = $false
            deviceSerialPersisted = $false; accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
    $normalizedRuntimeFixture = Assert-SoakRuntimeBinding $runtimeBindingFixture 111 `
        $fixtureMemoryProducerSha 1
    Require ([bool]$normalizedRuntimeFixture.available -and
        [uint64]$normalizedRuntimeFixture.processStartTicks -eq 1001 -and
        -not [bool]$normalizedRuntimeFixture.finalLogcatMarkerRequired) `
        'A valid integrated start/final runtime binding was rejected.'
    $runtimeBindingFixture.final.processStartTicks = [uint64]1002
    Require (Test-Throws {
        Assert-SoakRuntimeBinding $runtimeBindingFixture 111 $fixtureMemoryProducerSha 1 | Out-Null
    }) 'The runtime contract accepted PID reuse with different start ticks.'
    $runtimeBindingFixture.final.processStartTicks = [uint64]1001
    $runtimeBindingFixture.final.gameJvmAlive = $false
    Require (Test-Throws {
        Assert-SoakRuntimeBinding $runtimeBindingFixture 111 $fixtureMemoryProducerSha 1 | Out-Null
    }) 'The runtime contract accepted a dead final JVM.'
    $runtimeBindingFixture.final.gameJvmAlive = $true
    $runtimeBindingFixture.start.producerSha256 = 'B' * 64
    Require (Test-Throws {
        Assert-SoakRuntimeBinding $runtimeBindingFixture 111 $fixtureMemoryProducerSha 1 | Out-Null
    }) 'The runtime contract accepted a tampered start-receipt producer hash.'
    $runtimeBindingFixture.start.producerSha256 = $fixtureMemoryProducerSha
    foreach ($field in @('launcherMarkerTemporallyBoundToProcess',
            'launcherLogTemporallyBoundToProcess', 'expectedGameLogPathMatched',
            'expectedGameLogRegularAndNonEmpty', 'expectedGameLogSameFile',
            'expectedGameLogTemporallyBoundToProcess', 'expectedGameLogFresh',
            'expectedMinecraftVersionObserved', 'expectedVivecraftVersionObserved',
            'expectedVeqVersionObserved')) {
        $runtimeBindingFixture.start.$field = $false
        Require (Test-Throws {
            Assert-SoakRuntimeBinding $runtimeBindingFixture 111 `
                $fixtureMemoryProducerSha 1 | Out-Null
        }) "The runtime contract accepted false start.$field."
        $runtimeBindingFixture.start.$field = $true
    }
    foreach ($field in @('processStartEpochPersistedForLogBinding',
            'producerHashCapturedAtLaunch', 'producerFileReadLockedForRun',
            'launcherMarkerTemporallyBoundToProcess',
            'launcherLogTemporallyBoundToProcess',
            'expectedProfileGameLogPathFixed',
            'expectedGameLogIdentityCheckedAtStartAndFinal',
            'expectedGameLogFreshnessCheckedEverySample',
            'expectedGameLogEvidenceOnlyBooleansAndTimestamps',
            'gameJvmLivenessObservedAtBoundedFencesAndSamples')) {
        $runtimeBindingFixture.evidenceBoundary.$field = $false
        Require (Test-Throws {
            Assert-SoakRuntimeBinding $runtimeBindingFixture 111 `
                $fixtureMemoryProducerSha 1 | Out-Null
        }) "The runtime contract accepted false evidenceBoundary.$field."
        $runtimeBindingFixture.evidenceBoundary.$field = $true
    }
    $runtimeBindingFixture.evidenceBoundary.continuousGameJvmLivenessClaimed = $true
    Require (Test-Throws {
        Assert-SoakRuntimeBinding $runtimeBindingFixture 111 $fixtureMemoryProducerSha 1 | Out-Null
    }) 'The runtime contract accepted a continuous JVM-liveness claim.'
    $runtimeBindingFixture.evidenceBoundary.continuousGameJvmLivenessClaimed = $false

    $soakFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('v71-rc5-soak-contract-' +
        [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($soakFixtureRoot) | Out-Null
    try {
        $summaryFixturePath = Join-Path $soakFixtureRoot 'summary.json'
        $samplesFixturePath = Join-Path $soakFixtureRoot 'samples.jsonl'
        $summaryFixture = [pscustomobject][ordered]@{
            schemaVersion = 2
            package = $script:ExpectedPackage
            producerSha256 = $fixtureMemoryProducerSha
            provenance = $provenanceFixture
            finalProvenance = $provenanceFixture
            runtimeBinding = $runtimeBindingFixture
            startedUtc = '2026-09-06T06:16:23.0000000+00:00'
            requestedDurationMinutes = 90
            intervalSeconds = 300
            samples = 19
            minimumExpectedSamples = 19
            completeMetricSamples = 19
            initialPid = 111
            pidStable = $true
            focusStayedOnLab = $true
            gameJvmStayedAlive = $true
            maxPssMib = 0.977
            maxRssMib = 0.977
            maxProcessSwapMib = 0.0
            minMemAvailableMib = 0.977
            minSwapFreeMib = 0.977
            postWarmPssSlopeMibPerMinute = 0.0
            lastThirtyMinutesGrowthMib = 0.0
            acceptance = [pscustomobject][ordered]@{
                completedDuration = $true
                sampleCountComplete = $true
                allRequiredMetricsPresent = $true
                focusStayedOnLab = $true
                gameJvmStayedAlive = $true
                postWarmSamplesComplete = $true
                lastThirtySamplesComplete = $true
                maxPssAtMost2457Point6Mib = $true
                maxRssAtMost2457Point6Mib = $true
                processSwapAtMost512Mib = $true
                slopeAtMost2MibPerMinute = $true
                lastThirtyGrowthAtMost128Mib = $true
                passed = $true
            }
        }
        [IO.File]::WriteAllText($summaryFixturePath,
            ($summaryFixture | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        $sampleLines = for ($i = 0; $i -lt 19; $i++) {
            [pscustomobject][ordered]@{
                timestampUtc = ([DateTimeOffset]'2026-09-06T06:16:24Z').AddMinutes(5 * $i).ToString('o')
                elapsedMinutes = 5 * $i
                pid = 111; pidStable = $true; focus = 'focused'; gameJvmAlive = $true
                totalPssKib = 1000; totalRssKib = 1000; javaHeapKib = 100
                nativeHeapKib = 100; graphicsKib = 100; vmRssKib = 1000
                vmSwapKib = 0; memAvailableKib = 1000; swapFreeKib = 1000
            } | ConvertTo-Json -Compress
        }
        [IO.File]::WriteAllLines($samplesFixturePath, $sampleLines,
            [Text.UTF8Encoding]::new($false))
        $parsedSoakFixture = Get-SoakEvidence $summaryFixturePath $samplesFixturePath `
            $fixtureMemoryProducerSha 1
        Require ([int]$parsedSoakFixture.initialPid -eq 111 -and
            [bool]$parsedSoakFixture.runtimeObservation.available) `
            'The immutable soak evidence parser rejected a valid RC5 receipt.'
        $summaryFixture.producerSha256 = 'B' * 64
        [IO.File]::WriteAllText($summaryFixturePath,
            ($summaryFixture | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Require (Test-Throws {
            Get-SoakEvidence $summaryFixturePath $samplesFixturePath `
                $fixtureMemoryProducerSha 1 | Out-Null
        }) 'The RC5 memory contract accepted a tampered summary producer hash.'
        $summaryFixture.producerSha256 = $fixtureMemoryProducerSha
        $summaryFixture.maxPssMib = 0.978
        [IO.File]::WriteAllText($summaryFixturePath,
            ($summaryFixture | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Require (Test-Throws {
            Get-SoakEvidence $summaryFixturePath $samplesFixturePath `
                $fixtureMemoryProducerSha 1 | Out-Null
        }) 'The RC5 memory contract accepted a summary not bound to raw sample metrics.'
        $summaryFixture.maxPssMib = 0.977
        $summaryFixture.schemaVersion = 1
        [IO.File]::WriteAllText($summaryFixturePath,
            ($summaryFixture | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Require (Test-Throws {
            Get-SoakEvidence $summaryFixturePath $samplesFixturePath `
                $fixtureMemoryProducerSha 1 | Out-Null
        }) 'The RC5 memory contract accepted a legacy summary without runtime binding.'
    } finally {
        if (Test-Path -LiteralPath $soakFixtureRoot) {
            Remove-Item -LiteralPath $soakFixtureRoot -Recurse -Force
        }
    }
    $fixtureSoaks = @(
        [pscustomobject][ordered]@{
            index = 1; summarySha256 = '1' * 64; samplesSha256 = '2' * 64
            producerSha256 = $fixtureMemoryProducerSha
            startedUtc = '2026-09-06T06:16:23.0000000+00:00'
            finalSampleUtc = '2026-09-06T07:46:23.0000000+00:00'; initialPid = 111
            runtimeObservation = $normalizedRuntimeFixture
        },
        [pscustomobject][ordered]@{
            index = 2; summarySha256 = '3' * 64; samplesSha256 = '4' * 64
            producerSha256 = $fixtureMemoryProducerSha
            startedUtc = '2026-09-06T08:16:23.0000000+00:00'
            finalSampleUtc = '2026-09-06T09:46:23.0000000+00:00'; initialPid = 222
            runtimeObservation = [pscustomobject][ordered]@{
                index = 2; available = $true
                evidenceBasis = 'integrated-start-final-same-process-incarnation'
                initialPid = 222; processStartTicks = [uint64]2002
                startObservedUtc = '2026-09-06T08:16:24.0000000+00:00'
                finalObservedUtc = '2026-09-06T09:46:24.0000000+00:00'
                sameAndroidProcessIncarnation = $true
                gameJvmAliveAtStartAndFinal = $true
                provenanceMatchedAtStartAndFinal = $true
                xmsMiB = 512; xmxMiB = 1536; xmxSource = 'auto'
                launcherResourceReleaseAppliedAtStart = $true
                finalLogcatMarkerRequired = $false
            }
        }
    )
    $fixtureIdentity = [pscustomobject][ordered]@{
        package = $script:ExpectedPackage
        forbiddenStablePackage = $script:ExpectedStablePackage
        versionCode = $script:ExpectedVersionCode
        versionName = $script:ExpectedVersionName
        apkSha256 = $script:ExpectedApkSha256
        apkSizeBytes = $script:ExpectedApkSizeBytes
        coreSha256 = $script:ExpectedCoreSha256
        veqSha256 = $script:ExpectedVeqSha256
        signerSha256 = $script:ExpectedSignerSha256
    }
    $fixtureLineageFiles = @(
        [pscustomobject][ordered]@{
            name = 'lifecycle-orchestrator'
            relativePath = 'scripts/quest-v71-lab-lifecycle-recovery-rc5.ps1'
            sha256 = $fixtureLifecycleProducerSha
        }
        [pscustomobject][ordered]@{
            name = 'autoplay-harness'
            relativePath = 'scripts/run-vivecraft-local-autoplay.ps1'
            sha256 = $script:ExpectedAutoplayProducerSha256
        }
    )
    $fixtureLifecycle = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_LAB_RC5_LIFECYCLE_RECOVERY'
        result = 'PASS'
        startedUtc = '2026-09-06T05:00:00.0000000+00:00'
        completedUtc = '2026-09-06T05:05:00.0000000+00:00'
        labIdentity = $fixtureIdentity
        producerLineage = [pscustomobject][ordered]@{
            schemaVersion = 1
            hashScheme = $script:HashScheme
            digestSha256 = Get-ProducerLineageDigest $fixtureLineageFiles
            files = $fixtureLineageFiles
        }
        phases = @(
            [pscustomobject][ordered]@{
                name = 'preflight-exact-lab-and-rc5'; result = 'PASS'
                labInitiallyStopped = $true; stableStopped = $true
                installedApkMatched = $true; exactRc5PairBefore = $true
            }
            [pscustomobject][ordered]@{
                name = 'clean-cold-openxr'; result = 'PASS'; startedFromStopped = $true
                exactRc5VersionRows = $true; openXrFocused = $true
                openXrFrame120Submitted = $true; benchmarkWorldLoaded = $true
                gameJvmAlive = $true
            }
            [pscustomobject][ordered]@{
                name = 'post-openxr-process-stop-recovery'; result = 'PASS'
                liveOpenXrProcessStoppedBeforeRecovery = $true
                recoveryStartedFromStopped = $true; exactRc5VersionRows = $true
                openXrFocused = $true; openXrFrame120Submitted = $true
                benchmarkWorldLoaded = $true; gameJvmAlive = $true
            }
            [pscustomobject][ordered]@{
                name = 'launcher-only-interruption'; result = 'PASS'
                startedFromStopped = $true; launcherOnlyProven = $true
                unityMainPresent = $true; gameJvmAbsent = $true
                minecraftLogUntouched = $true; interruptedByForceStop = $true
                randomInputSent = $false
            }
            [pscustomobject][ordered]@{
                name = 'post-launcher-interruption-recovery'; result = 'PASS'
                launcherInterruptedBeforeRecovery = $true; recoveryStartedFromStopped = $true
                exactRc5VersionRows = $true; openXrFocused = $true
                openXrFrame120Submitted = $true; benchmarkWorldLoaded = $true
                gameJvmAlive = $true
            }
            [pscustomobject][ordered]@{
                name = 'final-stopped-exact-rc5'; result = 'PASS'; labStopped = $true
                stableStopped = $true; exactRc5PairAfter = $true
                installedLabApkUnchanged = $true; hostArtifactsUnchanged = $true
            }
        )
        finalState = [pscustomobject][ordered]@{
            lab = 'stopped'; exactRc5Pair = $true; installedLabApkUnchanged = $true
            stablePidAbsent = $true; stableTouched = $false
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            rawLogsPersisted = $false; logSnippetsPersisted = $false
            deviceSerialPersisted = $false; processIdsPersisted = $false
            hostAbsolutePathsPersisted = $false; accountDataPersisted = $false
            saveDataPersistedByGate = $false; randomInputSent = $false
            manualInteractionClaim = $false; performanceClaim = $false
            memorySoakClaim = $false; postInitAcknowledgementProven = $false
            postInitAcknowledgementLimitation =
                'Frozen RC5 has no ACK; Unity launcher and JVM share one Android PID.'
        }
    }
    $fixtureLifecycleSha = '5' * 64
    $fixtureLock = [pscustomobject][ordered]@{
        schemaVersion = 1
        target = [pscustomobject][ordered]@{
            package = $script:ExpectedPackage
            forbiddenStablePackage = $script:ExpectedStablePackage
            versionCode = $script:ExpectedVersionCode
            versionName = $script:ExpectedVersionName
            apkSha256 = $fixtureApkSha
            apkSizeBytes = $fixtureApkSize
            artifactAuditPassed = $true
            stableTouched = $false
        }
        pair = [pscustomobject][ordered]@{
            core = [pscustomobject][ordered]@{ sha256 = $script:ExpectedCoreSha256 }
            veq = [pscustomobject][ordered]@{ sha256 = $script:ExpectedVeqSha256 }
        }
        memoryPolicy = [pscustomobject][ordered]@{
            xmsMiB = 512; automaticXmxTargetMiB = 1536
            automaticXmxMinMiB = 1536; xmxMaxMiB = 2048; manualXmxMaxMiB = 2048
        }
        coldStartRuntimeEvidence = [pscustomobject][ordered]@{
            result = 'PASS'
            normalLauncherStartCount = 3; allThreeRetainedExactRc5 = $true
            lifecycleReceiptPath =
                'artifacts/acceptance/v71-lab-rc5-lifecycle-recovery-receipt.json'
            lifecycleReceiptSha256 = $fixtureLifecycleSha
            stablePackageModified = $false
        }
        launcherResourceReleaseEvidence = [pscustomobject][ordered]@{
            policy = 'default-on-only-for-exact-v71-rc5-lab-and-stable-identities-lab-authenticated-ab-may-override'
            designRationaleCarriedFromRc3 = $true
            exactRc5RuntimeValidated = $false
            result = 'PENDING_NOT_RUN'
            stableTouched = $false
        }
    }
    Assert-Rc5Contract $fixtureLock
    $fixtureLock.launcherResourceReleaseEvidence.exactRc5RuntimeValidated = $true
    $fixtureLock.launcherResourceReleaseEvidence.result = 'PASS'
    Assert-Rc5Contract $fixtureLock
    $fixtureLock.launcherResourceReleaseEvidence.exactRc5RuntimeValidated = $false
    Require (Test-Throws { Assert-Rc5Contract $fixtureLock }) `
        'The RC5 contract accepted result=PASS with runtime validation false.'
    $fixtureLock.launcherResourceReleaseEvidence.exactRc5RuntimeValidated = $true
    $fixtureLock.launcherResourceReleaseEvidence.result = 'PENDING_NOT_RUN'
    Require (Test-Throws { Assert-Rc5Contract $fixtureLock }) `
        'The RC5 contract accepted pending result with runtime validation true.'
    $fixtureLock.launcherResourceReleaseEvidence.exactRc5RuntimeValidated = $false
    $fixtureLock.launcherResourceReleaseEvidence.result = 'PENDING_NOT_RUN'
    $contractFixture = New-MemoryRuntimeContractReceipt `
        -Rc5Lock $fixtureLock `
        -Soaks $fixtureSoaks `
        -LifecycleReceipt $fixtureLifecycle `
        -LifecycleReceiptSha256 $fixtureLifecycleSha `
        -ProducerSha256 $selfSha `
        -CreatedUtc ([DateTimeOffset]::UtcNow)
    Require ([bool]$contractFixture.directObservations[0].available -and
        [bool]$contractFixture.directObservations[1].available -and
        [int]$contractFixture.directObservations[0].initialPid -eq 111 -and
        [int]$contractFixture.directObservations[1].initialPid -eq 222) `
        'Integrated direct per-soak runtime observations were not retained.'
    Require ([int]$contractFixture.memoryPolicy.lifecycleColdStartsRetainingExactRc5 -eq 3 -and
        [int]$contractFixture.memoryPolicy.directSoakStartJvmObservations -eq 2 -and
        [bool]$contractFixture.memoryPolicy.allDirectSoakStartsObservedAutomatic1536 -and
        [bool]$contractFixture.memoryPolicy.perSoakJvmArgumentObservedDirectly -and
        [bool]$contractFixture.launcherResourceRelease.perSoakAppliedMarkerObservedDirectlyAtStart -and
        -not [bool]$contractFixture.launcherResourceRelease.finalLogcatMarkerRetentionRequired) `
        'The runtime contract did not promote the integrated start/final evidence.'
    Require ($null -eq $contractFixture.memoryPolicy.PSObject.Properties[
            'exactColdStartObservations'] -and
        $null -eq $contractFixture.memoryPolicy.PSObject.Properties[
            'allColdStartsObservedAutomatic1536']) `
        'The runtime contract fabricated per-start Xmx observations for lifecycle starts.'
    Require (Test-Throws {
        New-MemoryRuntimeContractReceipt `
            -Rc5Lock $fixtureLock `
            -Soaks $fixtureSoaks `
            -LifecycleReceipt $fixtureLifecycle `
            -LifecycleReceiptSha256 ('6' * 64) `
            -ProducerSha256 $selfSha `
            -CreatedUtc ([DateTimeOffset]::UtcNow) | Out-Null
    }) 'The runtime contract accepted a lifecycle receipt not bound by the RC5 lock.'
    $script:ExpectedApkSha256 = $savedApkSha
    $script:ExpectedApkSizeBytes = $savedApkSize
    $script:ExpectedCurrentMemoryProducerSha256 = $savedMemoryProducerSha
    $script:ExpectedLifecycleProducerSha256 = $savedLifecycleProducerSha
    [pscustomobject]@{
        Result = 'PASS'
        SelfTestHostOnly = $true
        CreateHostOnly = $true
        DeviceInvocations = 0
        Assertions = $script:Assertions
        AtomicWriteOnce = $true
        IntegratedStartFinalBinding = $true
        PidReuseDefense = $true
        FinalLogcatRetentionRequired = $false
        PerSoakRuntimeReceiptsValidated = $true
        ProducerSha256 = $selfSha
        LockedProducerSha256 = $script:ExpectedContractProducerSha256
        CreateProducerLocked = ($selfSha -ceq $script:ExpectedContractProducerSha256)
    }
    return
}

Assert-Rc5CandidateReady
Require $AllowReceiptWrite.IsPresent 'Create requires explicit -AllowReceiptWrite.'
if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($WorkspaceRoot)
$rc5LockPath = Get-Rc5LockPath
$summary1 = Assert-ContainedFile $Soak1SummaryPath $root 'soak 1 summary'
$samples1 = Assert-ContainedFile $Soak1SamplesPath $root 'soak 1 samples'
$summary2 = Assert-ContainedFile $Soak2SummaryPath $root 'soak 2 summary'
$samples2 = Assert-ContainedFile $Soak2SamplesPath $root 'soak 2 samples'
$lifecyclePath = Assert-ContainedFile $LifecycleReceiptPath $root 'lifecycle receipt'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root $script:DefaultReceiptRelativePath
}
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$acceptanceRoot = [IO.Path]::GetFullPath(
    (Join-Path $root 'artifacts/acceptance')).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
Require ($outputFull.StartsWith($acceptanceRoot, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($outputFull) -ceq
        'v71-rc5-memory-runtime-contract-receipt.json') `
    'Receipt output must use the fixed non-sensitive acceptance path.'

$soaks = @(
    Get-SoakEvidence $summary1 $samples1 $Soak1ProducerSha256 1
    Get-SoakEvidence $summary2 $samples2 $Soak2ProducerSha256 2
)
Require ([DateTimeOffset]::Parse([string]$soaks[1].startedUtc) -
        [DateTimeOffset]::Parse([string]$soaks[0].startedUtc) -ge
        [TimeSpan]::FromMinutes(80)) 'The memory captures are not distinct rounds.'
$lifecycleReceipt = Read-Json $lifecyclePath 'lifecycle receipt'
$receipt = New-MemoryRuntimeContractReceipt `
    -Rc5Lock (Read-Json $rc5LockPath 'RC5 lock') `
    -Soaks $soaks `
    -LifecycleReceipt $lifecycleReceipt `
    -LifecycleReceiptSha256 (Get-FileSha256 $lifecyclePath) `
    -ProducerSha256 (Get-TextSha256 $PSCommandPath) `
    -CreatedUtc ([DateTimeOffset]::UtcNow)
$identity = Write-AtomicWriteOnceJson $receipt $outputFull
[pscustomobject]@{
    Result = 'PASS'
    ReceiptPath = $identity.Path
    ReceiptSha256 = $identity.Sha256
    ReceiptSizeBytes = $identity.SizeBytes
    DeviceInvocations = 0
    DirectPerSoakJvmArgumentClaim = $true
    DirectPerSoakResourceReleaseMarkerClaim = $true
    FinalLogcatMarkerRetentionRequired = $false
}
