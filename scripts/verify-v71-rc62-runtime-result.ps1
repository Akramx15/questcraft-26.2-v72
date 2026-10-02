#requires -Version 7.0
<#
.SYNOPSIS
Verifies the immutable Host-side RC6.2 runtime-result receipt.

.DESCRIPTION
Authenticates the exact Lab artifact chain, the immutable producer locks, the
30-minute screen, both completed memory soaks, and the supplementary pair
analysis. The verifier preserves the formal memory failure and does not infer
manual VR acceptance or Stable-promotion authority. It has no device command
path.
#>
[CmdletBinding()]
param(
    [string] $ReceiptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[V71_RC6_2_RUNTIME_RESULT]'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Expected = [ordered]@{
    Package = 'com.qcxr.qcxr.canary262'
    StablePackage = 'com.qcxr.qcxr.dev262'
    VersionCode = 71
    VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.6.2'
    ApkSha256 = 'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4'
    CoreSha256 = '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF'
    CoreVersion = '26.2-1.3.15+qc.v71.rc6.2'
    VeqSha256 = 'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
    VeqVersion = '0.7.0-v71.rc6'
    PairSha256 = 'EA2E063BF3B2B38B3B8EB28CA014C5D6144DC61BFC37BE4F3042CDE27FE8C30A'
    AarSha256 = '6B9224C6697D00DCE363AD80EA5FA9946E90808C514517BA4EEDFEB31DB2BA89'
    SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
    BuildLockSha256 = '7DD25F7703A4E2B1F2857FD8EB552CB303CB3A1870779ADBD5708B3F5D1B7E45'
    ProducerLockSha256 = 'AE863EE53217D11D594DF208E1C015F2AF59A06217894FE8509E6675CDC878C4'
    ManualTemplateSha256 = '7C6C9AAB85C65449040B39AF5E252E68B6EF610F9DE8800D8D37F6B24F5AC3D8'
    ScreenSha256 = 'BFA4632EDF153BE01E91E08EEA42339108A808FAF949BD9608597A22C7C1DE78'
    PairReceiptSha256 = '3C73CDB3DDD89C338BC001E6FC6C72F69B5158CD7F24C0D9481625D3587FD4C0'
    SamplerNormalizedSha256 = '75F5D720A3FC6396109D6D96820F2F75AE8A8327F317A41AE811CBBF781CD433'
    AnalyzerNormalizedSha256 = '073785C084DA6ECFC0CD69CA81667945AF88B43AE7500A904A62FB3355E7050B'
}

function Fail([Parameter(Mandatory)][string] $Message) {
    throw "$($script:Prefix) $Message"
}

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { Fail $Message }
}

function Get-RequiredProperty(
    [Parameter(Mandatory)][object] $Object,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Context
) {
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property -and $null -ne $property.Value) `
        "$Context is missing '$Name'."
    return $property.Value
}

function Get-Sha256([Parameter(Mandatory)][string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($text)))
}

function Resolve-RepoFile([Parameter(Mandatory)][string] $RelativePath) {
    Require (-not [IO.Path]::IsPathRooted($RelativePath)) `
        "Receipt path must be repository-relative: $RelativePath"
    $candidate = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot $RelativePath))
    $rootPrefix = [IO.Path]::GetFullPath($script:RepoRoot).TrimEnd('\', '/') +
        [IO.Path]::DirectorySeparatorChar
    Require ($candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) `
        "Receipt path escaped the repository: $RelativePath"
    return $candidate
}

function Assert-FileBinding(
    [Parameter(Mandatory)][string] $RelativePath,
    [Parameter(Mandatory)][string] $Sha256,
    [int64] $SizeBytes = -1
) {
    Require ($Sha256 -cmatch '^[0-9A-F]{64}$') "Invalid SHA-256 for $RelativePath."
    $path = Resolve-RepoFile $RelativePath
    Require (Test-Path -LiteralPath $path -PathType Leaf) "Missing evidence: $RelativePath"
    Require ((Get-Sha256 $path) -ceq $Sha256) "Evidence hash drifted: $RelativePath"
    if ($SizeBytes -ge 0) {
        Require ((Get-Item -LiteralPath $path).Length -eq $SizeBytes) `
            "Evidence size drifted: $RelativePath"
    }
}

function Assert-ChecksumLine(
    [Parameter(Mandatory)][string[]] $Lines,
    [Parameter(Mandatory)][string] $Sha256,
    [Parameter(Mandatory)][string] $RelativePath
) {
    $expectedLine = "$Sha256  $RelativePath"
    Require (@($Lines | Where-Object { [string]$_ -ceq $expectedLine }).Count -eq 1) `
        "CHECKSUMS.sha256 does not contain one exact binding for $RelativePath."
}

if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path $script:RepoRoot 'V71_RC6_2_RUNTIME_RESULT.lock.json'
}
$resolvedReceipt = (Resolve-Path -LiteralPath $ReceiptPath).Path
$receipt = Get-Content -Raw -LiteralPath $resolvedReceipt | ConvertFrom-Json

Require ([int](Get-RequiredProperty $receipt 'schemaVersion' 'receipt') -eq 1) `
    'Receipt schema drifted.'
Require ([string](Get-RequiredProperty $receipt 'receiptType' 'receipt') -ceq
        'V71_RC6_2_RUNTIME_RESULT' -and [bool]$receipt.immutable) `
    'Receipt type or immutable flag drifted.'
Require ([string]$receipt.status -ceq
        'RECORDED_FORMAL_MEMORY_FAIL_SUPPLEMENTARY_LEAK_STABILITY_PASS_MANUAL_PENDING_STABLE_PROHIBITED') `
    'Receipt status no longer preserves every acceptance boundary.'

$candidate = Get-RequiredProperty $receipt 'candidate' 'receipt'
Require ([string]$candidate.package -ceq $script:Expected.Package -and
        [string]$candidate.forbiddenStablePackage -ceq $script:Expected.StablePackage -and
        [string]$candidate.profile -ceq '26.2' -and
        [int]$candidate.versionCode -eq $script:Expected.VersionCode -and
        [string]$candidate.versionName -ceq $script:Expected.VersionName) `
    'Candidate identity drifted.'
Require ([string]$candidate.apk.sha256 -ceq $script:Expected.ApkSha256 -and
        [string]$candidate.apk.signerSha256 -ceq $script:Expected.SignerSha256 -and
        [string]$candidate.core.sha256 -ceq $script:Expected.CoreSha256 -and
        [string]$candidate.core.version -ceq $script:Expected.CoreVersion -and
        [string]$candidate.veq.sha256 -ceq $script:Expected.VeqSha256 -and
        [string]$candidate.veq.version -ceq $script:Expected.VeqVersion -and
        [string]$candidate.coreVeqPairSha256 -ceq $script:Expected.PairSha256 -and
        [string]$candidate.pojlibAar.sha256 -ceq $script:Expected.AarSha256) `
    'Candidate artifact identity drifted.'

foreach ($binding in @($candidate.apk, $candidate.core, $candidate.veq, $candidate.pojlibAar)) {
    Assert-FileBinding -RelativePath ([string]$binding.path) `
        -Sha256 ([string]$binding.sha256) -SizeBytes ([int64]$binding.sizeBytes)
}
$pairText = "core=$($candidate.core.sha256)`nveq=$($candidate.veq.sha256)`n"
$computedPair = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($pairText)))
Require ($computedPair -ceq $script:Expected.PairSha256) 'Core/VEQ pair digest is invalid.'

$sourceLocks = Get-RequiredProperty $receipt 'sourceLocks' 'receipt'
foreach ($binding in @($sourceLocks.candidateBuild, $sourceLocks.evidenceProducers,
        $sourceLocks.manualTemplate)) {
    Assert-FileBinding -RelativePath ([string]$binding.path) -Sha256 ([string]$binding.sha256)
}
Require ([string]$sourceLocks.candidateBuild.sha256 -ceq $script:Expected.BuildLockSha256 -and
        [bool]$sourceLocks.candidateBuild.immutableAndUnmodified -and
        [string]$sourceLocks.evidenceProducers.sha256 -ceq $script:Expected.ProducerLockSha256 -and
        [bool]$sourceLocks.evidenceProducers.immutableAndUnmodified -and
        [string]$sourceLocks.manualTemplate.sha256 -ceq $script:Expected.ManualTemplateSha256) `
    'A source-lock binding drifted.'

$buildLock = Get-Content -Raw -LiteralPath (Resolve-RepoFile $sourceLocks.candidateBuild.path) |
    ConvertFrom-Json
$producerLock = Get-Content -Raw -LiteralPath (Resolve-RepoFile $sourceLocks.evidenceProducers.path) |
    ConvertFrom-Json
Require ([bool]$buildLock.immutable -and [bool]$producerLock.immutable -and
        [string]$buildLock.target.package -ceq $script:Expected.Package -and
        [string]$buildLock.target.apkSha256 -ceq $script:Expected.ApkSha256 -and
        [string]$producerLock.runtimeIdentity.apkSha256 -ceq $script:Expected.ApkSha256 -and
        [string]$producerLock.producers.memorySoakScriptSha256 -ceq
            $script:Expected.SamplerNormalizedSha256) `
    'Immutable build or producer-lock content drifted.'
$samplerPath = Resolve-RepoFile ([string]$producerLock.producers.memorySoakPath)
Require ((Get-NormalizedTextSha256 $samplerPath) -ceq $script:Expected.SamplerNormalizedSha256) `
    'The memory-soak producer no longer matches its immutable normalized hash.'

$screenBinding = Get-RequiredProperty $receipt 'runtimeScreen' 'receipt'
Assert-FileBinding -RelativePath ([string]$screenBinding.path) `
    -Sha256 ([string]$screenBinding.sha256) -SizeBytes ([int64]$screenBinding.sizeBytes)
Require ([string]$screenBinding.sha256 -ceq $script:Expected.ScreenSha256 -and
        [string]$screenBinding.classification -ceq 'PASS_SAFETY_STABILITY_ONLY' -and
        -not [bool]$screenBinding.pairedPerformanceComparison -and
        -not [bool]$screenBinding.qgoFourFourClaimed) `
    'Runtime-screen scope drifted into an unsupported performance claim.'
$screen = Get-Content -Raw -LiteralPath (Resolve-RepoFile $screenBinding.path) | ConvertFrom-Json
Require ([string]$screen.Package -ceq $script:Expected.Package -and
        [bool]$screen.ValidForComparison -and [double]$screen.DurationWallSeconds -eq 1800.79 -and
        [int]$screen.Aggregate.VrApiSamples -eq 1801 -and
        [double]$screen.Aggregate.MeanAppFps -eq 87.19 -and
        [double]$screen.Aggregate.P10AppFps -eq 85.0 -and
        [double]$screen.Aggregate.P95AppMs -eq 4.84 -and
        [double]$screen.Aggregate.P95CpuAndGpuMs -eq 11.06 -and
        [double]$screen.Aggregate.MeanStalePerSecond -eq 0.77 -and
        [double]$screen.Aggregate.MaxTempC -eq 44.0 -and
        -not [bool]$screen.RawLogsPersisted -and -not [bool]$screen.RawProcessRowsPersisted) `
    'Runtime-screen evidence content drifted.'

$expectedRuns = @(
    [ordered]@{
        Run = 1
        SummarySha256 = '140ABC18A9F10E9229D8B77A2A41B63883AE9E054B71E32CCDBC326FD4DAF9E9'
        SamplesSha256 = '4BD29B858AFBDBBCA28339035E265DCD761C4712BB5FAF301FEAA21584D9B30D'
        DurationMinutes = 90.09
        MaxPssMib = 3275.992
        MaxRssMib = 2322.660
        PairSlope = 0.133845
        PairLastThirty = 7.955078
    },
    [ordered]@{
        Run = 2
        SummarySha256 = '1E5C8EBA2E0B8CB86B9233E731CF88F25902DBA35FE79B72B0493C370CA18FE9'
        SamplesSha256 = 'C0F87D3B65BEACE3137BC2FCF0F503ED44114D55F8A0A170D5A14224FC487D09'
        DurationMinutes = 90.105
        MaxPssMib = 3172.923
        MaxRssMib = 2231.746
        PairSlope = 0.308162
        PairLastThirty = 7.828125
    }
)
$memory = Get-RequiredProperty $receipt 'memory' 'receipt'
Require ([bool]$memory.formalPolicy.immutable -and
        [double]$memory.formalPolicy.absolutePssLimitMib -eq 2457.6 -and
        [string]$memory.formalResult -ceq 'FAIL' -and
        [string]$memory.formalFailedCriterion -ceq 'absolutePssAtMost2457Point6Mib' -and
        @($memory.soaks).Count -eq 2) `
    'Formal memory policy or result drifted.'

for ($index = 0; $index -lt $expectedRuns.Count; $index++) {
    $expectedRun = $expectedRuns[$index]
    $binding = @($memory.soaks)[$index]
    Require ([int]$binding.run -eq $expectedRun.Run -and
            [string]$binding.summarySha256 -ceq $expectedRun.SummarySha256 -and
            [string]$binding.samplesSha256 -ceq $expectedRun.SamplesSha256 -and
            [double]$binding.durationMinutes -eq $expectedRun.DurationMinutes -and
            [int]$binding.sampleCount -eq 19 -and
            [double]$binding.maxPssMib -eq $expectedRun.MaxPssMib -and
            [double]$binding.maxRssMib -eq $expectedRun.MaxRssMib -and
            [double]$binding.postWarmPssSlopeMibPerMinute -eq $expectedRun.PairSlope -and
            [double]$binding.lastThirtyGrowthMib -eq $expectedRun.PairLastThirty -and
            [string]$binding.formalResult -ceq 'FAIL' -and
            [string]$binding.onlyFailedCriterion -ceq 'maxPssAtMost2457Point6Mib') `
        "Soak $($expectedRun.Run) receipt binding drifted."
    Assert-FileBinding -RelativePath ([string]$binding.summaryPath) `
        -Sha256 ([string]$binding.summarySha256) -SizeBytes ([int64]$binding.summarySizeBytes)
    Assert-FileBinding -RelativePath ([string]$binding.samplesPath) `
        -Sha256 ([string]$binding.samplesSha256) -SizeBytes ([int64]$binding.samplesSizeBytes)
    $summary = Get-Content -Raw -LiteralPath (Resolve-RepoFile $binding.summaryPath) | ConvertFrom-Json
    Require ([string]$summary.package -ceq $script:Expected.Package -and
            [string]$summary.producerSha256 -ceq $script:Expected.SamplerNormalizedSha256 -and
            [bool]$summary.provenance.allMatched -and [bool]$summary.finalProvenance.allMatched -and
            [string]$summary.runtimeBinding.result -ceq 'PASS' -and
            [int]$summary.samples -eq 19 -and [bool]$summary.pidStable -and
            [bool]$summary.focusStayedOnLab -and [bool]$summary.gameJvmStayedAlive -and
            [double]$summary.maxPssMib -eq $expectedRun.MaxPssMib -and
            [double]$summary.maxRssMib -eq $expectedRun.MaxRssMib -and
            -not [bool]$summary.acceptance.maxPssAtMost2457Point6Mib -and
            [bool]$summary.acceptance.maxRssAtMost2457Point6Mib -and
            [bool]$summary.acceptance.processSwapAtMost512Mib -and
            [bool]$summary.acceptance.slopeAtMost2MibPerMinute -and
            [bool]$summary.acceptance.lastThirtyGrowthAtMost128Mib -and
            -not [bool]$summary.acceptance.passed -and
            -not [bool]$summary.thermalSafety.limitExceeded -and
            -not [bool]$summary.thermalSafety.labSafetyStopPerformed -and
            -not [bool]$summary.thermalSafety.stablePackageStopped) `
        "Soak $($expectedRun.Run) producer result drifted."
}

$supplementary = $memory.supplementary
Assert-FileBinding -RelativePath ([string]$supplementary.path) `
    -Sha256 ([string]$supplementary.sha256) -SizeBytes ([int64]$supplementary.sizeBytes)
Require ([string]$supplementary.sha256 -ceq $script:Expected.PairReceiptSha256 -and
        [string]$supplementary.result -ceq 'LEAK_STABILITY_PASS' -and
        [string]$supplementary.analyzerNormalizedLfSha256 -ceq
            $script:Expected.AnalyzerNormalizedSha256 -and
        -not [bool]$supplementary.overridesFormalResult -and
        -not [bool]$supplementary.provesAbsenceOfAllLeaks -and
        -not [bool]$supplementary.authorizesStablePromotion) `
    'Supplementary receipt scope drifted.'
$analyzerPath = Resolve-RepoFile ([string]$supplementary.analyzerPath)
Require ((Get-NormalizedTextSha256 $analyzerPath) -ceq $script:Expected.AnalyzerNormalizedSha256) `
    'The supplementary analyzer no longer matches its normalized hash.'
$pairReceipt = Get-Content -Raw -LiteralPath (Resolve-RepoFile $supplementary.path) | ConvertFrom-Json
Require ([string]$pairReceipt.result -ceq 'LEAK_STABILITY_PASS' -and
        [string]$pairReceipt.originalProducerGate.result -ceq 'FAIL' -and
        [string]$pairReceipt.absolute2Point4GiBGate.result -ceq 'FAIL' -and
        -not [bool]$pairReceipt.originalProducerGate.supplementaryAnalysisOverridesResult -and
        -not [bool]$pairReceipt.supplementaryClassification.originalProducerGateOverridden -and
        -not [bool]$pairReceipt.supplementaryClassification.absolute2Point4GiBGateOverridden -and
        -not [bool]$pairReceipt.supplementaryClassification.stablePromotionAuthorized -and
        [int]$pairReceipt.evidenceBoundary.deviceCommandsInvoked -eq 0 -and
        -not [bool]$pairReceipt.evidenceBoundary.deviceReadPerformed -and
        -not [bool]$pairReceipt.evidenceBoundary.deviceWritePerformed) `
    'Supplementary analysis changed or exceeded its Host-only scope.'
for ($index = 0; $index -lt $expectedRuns.Count; $index++) {
    $expectedRun = $expectedRuns[$index]
    $pairRun = @($pairReceipt.runs)[$index]
    Require ([int]$pairRun.run -eq $expectedRun.Run -and
            [string]$pairRun.inputs.summarySha256 -ceq $expectedRun.SummarySha256 -and
            [string]$pairRun.inputs.samplesSha256 -ceq $expectedRun.SamplesSha256 -and
            [double]$pairRun.recomputedMetrics.pss.postWarmSlopeMibPerMinute -eq
                $expectedRun.PairSlope -and
            [double]$pairRun.recomputedMetrics.pss.lastThirtyMinutesGrowthMib -eq
                $expectedRun.PairLastThirty -and
            [string]$pairRun.originalProducerResult.result -ceq 'FAIL' -and
            [string]$pairRun.supplementaryClassification -ceq 'LEAK_STABILITY_PASS') `
        "Supplementary run $($expectedRun.Run) binding drifted."
}

Require ([string]$receipt.manualAcceptance.status -ceq 'PENDING_USER_OBSERVATION' -and
        -not [bool]$receipt.manualAcceptance.mayBeInferredFromLogsScreenshotsOrAutomation -and
        [bool]$receipt.decision.runtimeSafetyScreenPassed -and
        [string]$receipt.decision.formalMemoryAcceptance -ceq 'FAIL' -and
        [string]$receipt.decision.supplementaryLeakStability -ceq 'LEAK_STABILITY_PASS' -and
        [string]$receipt.decision.manualVrInteraction -ceq 'PENDING_USER_OBSERVATION' -and
        -not [bool]$receipt.decision.stablePromotionAllowed -and
        -not [bool]$receipt.decision.stablePackageTouched) `
    'Manual or Stable-promotion boundary drifted.'
Require ([bool]$receipt.evidenceBoundary.hostReceiptOnly -and
        [int]$receipt.evidenceBoundary.deviceCommandsInvokedWhileCreatingReceipt -eq 0 -and
        -not [bool]$receipt.evidenceBoundary.deviceReadPerformedWhileCreatingReceipt -and
        -not [bool]$receipt.evidenceBoundary.deviceWritePerformedWhileCreatingReceipt -and
        -not [bool]$receipt.evidenceBoundary.inputEvidenceModified -and
        -not [bool]$receipt.evidenceBoundary.rawLogsPersisted -and
        -not [bool]$receipt.evidenceBoundary.deviceSerialPersisted -and
        -not [bool]$receipt.evidenceBoundary.accountDataPersisted -and
        -not [bool]$receipt.evidenceBoundary.manualAcceptanceMayBeInferred -and
        -not [bool]$receipt.evidenceBoundary.stablePromotionMayBeInferred) `
    'Host-only evidence boundary drifted.'

$checksumLines = @(Get-Content -LiteralPath (Join-Path $script:RepoRoot 'CHECKSUMS.sha256'))
$checksumBindings = @(
    @([string]$candidate.core.sha256, [string]$candidate.core.path),
    @([string]$candidate.veq.sha256, [string]$candidate.veq.path),
    @([string]$candidate.pojlibAar.sha256, [string]$candidate.pojlibAar.path),
    @([string]$candidate.apk.sha256, [string]$candidate.apk.path),
    @([string]$sourceLocks.candidateBuild.sha256, [string]$sourceLocks.candidateBuild.path),
    @([string]$sourceLocks.evidenceProducers.sha256, [string]$sourceLocks.evidenceProducers.path),
    @([string]$sourceLocks.manualTemplate.sha256, [string]$sourceLocks.manualTemplate.path),
    @([string]$screenBinding.sha256, [string]$screenBinding.path),
    @([string]$memory.soaks[0].summarySha256, [string]$memory.soaks[0].summaryPath),
    @([string]$memory.soaks[0].samplesSha256, [string]$memory.soaks[0].samplesPath),
    @([string]$memory.soaks[1].summarySha256, [string]$memory.soaks[1].summaryPath),
    @([string]$memory.soaks[1].samplesSha256, [string]$memory.soaks[1].samplesPath),
    @([string]$supplementary.sha256, [string]$supplementary.path),
    @((Get-Sha256 $resolvedReceipt), 'V71_RC6_2_RUNTIME_RESULT.lock.json')
)
foreach ($binding in $checksumBindings) {
    Assert-ChecksumLine -Lines $checksumLines -Sha256 $binding[0] -RelativePath $binding[1]
}

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    ReceiptSha256 = Get-Sha256 $resolvedReceipt
    Candidate = $script:Expected.VersionName
    RuntimeScreen = 'PASS_SAFETY_STABILITY_ONLY'
    FormalMemoryResult = 'FAIL'
    SupplementaryResult = 'LEAK_STABILITY_PASS'
    ManualAcceptance = 'PENDING_USER_OBSERVATION'
    StablePromotionAllowed = $false
    EvidenceFilesVerified = 13
}
