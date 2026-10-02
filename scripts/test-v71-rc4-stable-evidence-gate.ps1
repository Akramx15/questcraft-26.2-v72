#requires -Version 7.0
<# Host-only positive and adversarial tests for the RC4 Stable evidence gate. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "[V71_RC4_EVIDENCE_HOST_TEST] $Message" }
}
function Write-Json($Value, [string] $Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 32) + "`n",
        [Text.UTF8Encoding]::new($false))
}
function Write-JsonLines([object[]] $Values, [string] $Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllLines($Path,
        @($Values | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }),
        [Text.UTF8Encoding]::new($false))
}
function Get-Hash([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
function Get-TextHash([string] $Path) {
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Path))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($normalized)))
}
function Expect-Failure([scriptblock] $Operation, [string] $Needle = '') {
    try { & $Operation | Out-Null; return $false } catch {
        if ([string]::IsNullOrWhiteSpace($Needle)) { return $true }
        return [string]$_.Exception.Message -like "*$Needle*"
    }
}
function Copy-Value($Value) {
    $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $repoRoot)
. (Join-Path $PSScriptRoot 'v71-rc4-stable-evidence-gate.ps1')

$buildSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'build-v71-integrated.ps1'))
$installSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'quest-v71-rc4-stable-install.ps1'))
Require-Test ($buildSource.Contains('-RepoRoot $repo') -and
    $buildSource.Contains('-EvidenceRoot $workspaceRoot')) 'Builder does not pass split roots.'
Require-Test ($installSource.Contains('$script:EvidenceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)') -and
    $installSource.Contains('RepoRoot = $script:RepoRoot') -and
    $installSource.Contains('EvidenceRoot = $script:EvidenceRoot') -and
    $installSource.Contains('Invoke-AuthenticatedRc4EvidenceGate -Contract $Contract') -and
    $installSource.Contains('-GateArguments $arguments')) `
    'Installer does not pass split roots.'
Require-Test ((Get-TextHash (Join-Path $PSScriptRoot 'quest-v71-rc3-rc4-ab.ps1')) -ceq
    $script:V71Rc4PerformanceProducerSha256) 'Reviewed A/B producer hash drifted.'

$pendingRejected = Expect-Failure {
    Assert-V71Rc4StableAcceptanceEvidence `
        -ManifestPath (Join-Path $repoRoot 'V71_STABLE_RC4_ACCEPTANCE.lock.json') `
        -RepoRoot $repoRoot -EvidenceRoot $workspaceRoot `
        -MemorySamplerPath (Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc4.ps1') `
        -MemoryRuntimeContractPath (Join-Path $PSScriptRoot 'quest-v71-memory-runtime-contract-rc4.ps1') `
        -PerformanceHarnessPath (Join-Path $PSScriptRoot 'quest-v71-rc3-rc4-ab.ps1') `
        -LifecycleHarnessPath (Join-Path $PSScriptRoot 'quest-v71-lab-lifecycle-recovery-rc4.ps1')
} 'not ACCEPTED_FOR_STABLE_BUILD'
Require-Test $pendingRejected 'Checked-in pending acceptance did not fail closed.'

$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('v71-rc4-evidence-' + [Guid]::NewGuid().ToString('N'))))
$fixtureRepoRoot = Join-Path $tempRoot 'repo'
$fixtureEvidenceRoot = Join-Path $tempRoot 'evidence'
$memoryRoot = Join-Path $fixtureEvidenceRoot 'artifacts/memory'
$campaignRoot = Join-Path $fixtureEvidenceRoot 'artifacts/benchmarks/rc4'
$acceptanceRoot = Join-Path $fixtureEvidenceRoot 'artifacts/acceptance'
$manifestPath = Join-Path $fixtureRepoRoot 'V71_STABLE_RC4_ACCEPTANCE.lock.json'
foreach ($path in @((Join-Path $fixtureRepoRoot 'scripts'), $memoryRoot, $campaignRoot, $acceptanceRoot)) {
    [IO.Directory]::CreateDirectory($path) | Out-Null
}
$producerMap = [ordered]@{
    memorySoak = 'scripts/quest-v71-memory-soak-rc4.ps1'
    memoryRuntimeContract = 'scripts/quest-v71-memory-runtime-contract-rc4.ps1'
    performanceHarness = 'scripts/quest-v71-rc3-rc4-ab.ps1'
    lifecycleRecovery = 'scripts/quest-v71-lab-lifecycle-recovery-rc4.ps1'
}

$performanceFixture = @'
#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Aggregate')][string] $Action = 'Aggregate',
    [Parameter(Mandatory)][string] $OutputDirectory)
$names = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
$paths = @((Join-Path $OutputDirectory 'run-manifest.json'),
    (Join-Path $OutputDirectory 'comparison.json')) +
    @($names | ForEach-Object { Join-Path $OutputDirectory ($_ + '.json') })
foreach ($path in @($paths + $PSCommandPath)) {
    $writeOpened = $false
    try {
        $probe = [IO.File]::Open($path, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $probe.Dispose(); $writeOpened = $true
    } catch [IO.IOException] {}
    if ($writeOpened) { throw "Gate failed to read-lock $path" }
}
$manifest = Get-Content -Raw -LiteralPath $paths[0] | ConvertFrom-Json
$reports = @{}
foreach ($name in $names) {
    $report = Get-Content -Raw -LiteralPath (Join-Path $OutputDirectory ($name + '.json')) |
        ConvertFrom-Json
    if ([string]$report.Protocol.Condition -cne $name.Substring(0, 1) -or
        [int]$report.Protocol.Pair -ne [int]$name.Substring(1, 1)) { throw "Report drifted: $name" }
    $reports[$name] = $report
}
$pairs = @()
foreach ($pair in 1..3) {
    $a = [double]$reports["A$pair"].Aggregate.MeanAppFps
    $b = [double]$reports["B$pair"].Aggregate.MeanAppFps
    $pairs += [pscustomobject][ordered]@{
        Pair = $pair; Comparable = $true; GuardrailsPass = ($b -ge ($a * 0.98))
        Rc3MeanFps = [math]::Round($a, 2); Rc4MeanFps = [math]::Round($b, 2)
    }
}
$aMean = [double](($reports.A1.Aggregate.MeanAppFps, $reports.A2.Aggregate.MeanAppFps,
    $reports.A3.Aggregate.MeanAppFps | Measure-Object -Average).Average)
$bMean = [double](($reports.B1.Aggregate.MeanAppFps, $reports.B2.Aggregate.MeanAppFps,
    $reports.B3.Aggregate.MeanAppFps | Measure-Object -Average).Average)
$passes = @($pairs | Where-Object GuardrailsPass).Count
$passed = $bMean -ge ($aMean * 0.98) -and $passes -ge 2
[pscustomobject][ordered]@{
    SchemaVersion = 1
    Result = if ($passed) { 'PASS_RC4_NO_PERSISTENT_REGRESSION' } else { 'FAIL_RC4_PERFORMANCE_GATE' }
    PerformanceGatePassed = $passed
    ConditionA = 'RC3 Core+VEQ under integrated RC4 Lab APK'
    ConditionB = 'integrated RC4 Core+VEQ under the same RC4 Lab APK'
    InstalledApkSha256 = [string]$manifest.InstalledApk.Sha256
    ProducerLineageSha256 = [string]$manifest.ProducerLineage.DigestSha256
    Order = @($manifest.Order); Pairs = $pairs
    Aggregate = [pscustomobject][ordered]@{
        Rc3MeanFps = [math]::Round($aMean, 2); Rc4MeanFps = [math]::Round($bMean, 2)
        AggregateGuardrailsPass = $passed; PairGuardrailPassCount = $passes
        PersistentMetricRegression = $false; MaximumRegressionPercent = 2.0
    }
    StableTouched = $false; RawLogsPersisted = $false
}
'@
foreach ($entry in $producerMap.GetEnumerator()) {
    $full = Join-Path $fixtureRepoRoot $entry.Value
    $text = if ($entry.Key -ceq 'performanceHarness') { $performanceFixture } else { "# fixture $($entry.Key)`n" }
    [IO.File]::WriteAllText($full, $text, [Text.UTF8Encoding]::new($false))
}
$producerHashes = @{}
foreach ($entry in $producerMap.GetEnumerator()) {
    $producerHashes[$entry.Key] = Get-TextHash (Join-Path $fixtureRepoRoot $entry.Value)
}
$lifecycleLineageFiles = @(
    [pscustomobject][ordered]@{
        name = 'lifecycle-orchestrator'
        relativePath = $producerMap.lifecycleRecovery
        sha256 = $producerHashes.lifecycleRecovery
    }
    [pscustomobject][ordered]@{
        name = 'autoplay-harness'
        relativePath = 'scripts/run-vivecraft-local-autoplay.ps1'
        sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['autoplay-harness']
    }
)
$lifecycleLineage = [pscustomobject][ordered]@{
    schemaVersion = 1
    hashScheme = $script:V71Rc4PerformanceProducerHashScheme
    digestSha256 = Get-V71Rc4ProducerLineageDigest $lifecycleLineageFiles
    files = $lifecycleLineageFiles
}
$lineageFiles = @(
    [pscustomobject][ordered]@{ Name = 'orchestrator'; RelativePath = $producerMap.performanceHarness; Sha256 = $producerHashes.performanceHarness }
    [pscustomobject][ordered]@{ Name = 'pair-harness'; RelativePath = 'scripts/quest-v70-lab-pair.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['pair-harness'] }
    [pscustomobject][ordered]@{ Name = 'core-canary-harness'; RelativePath = 'scripts/quest-vivecraft-core-canary.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['core-canary-harness'] }
    [pscustomobject][ordered]@{ Name = 'veq-lab-harness'; RelativePath = 'scripts/quest-veq-lab.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['veq-lab-harness'] }
    [pscustomobject][ordered]@{ Name = 'world-reset-harness'; RelativePath = 'scripts/reset-lab-benchmark-world.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['world-reset-harness'] }
    [pscustomobject][ordered]@{ Name = 'autoplay-harness'; RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['autoplay-harness'] }
    [pscustomobject][ordered]@{ Name = 'vrapi-benchmark-harness'; RelativePath = 'scripts/quest-vrapi-pid-benchmark.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['vrapi-benchmark-harness'] }
    [pscustomobject][ordered]@{ Name = 'apk-verifier'; RelativePath = 'scripts/verify-dev-apk.ps1'; Sha256 = $script:V71Rc4ExpectedPerformanceDependencyHashes['apk-verifier'] }
)
$performanceLineage = [pscustomobject][ordered]@{
    SchemaVersion = 1; HashScheme = $script:V71Rc4PerformanceProducerHashScheme
    DigestSha256 = Get-V71Rc4ProducerLineageDigest $lineageFiles; Files = $lineageFiles
}
$identity = [ordered]@{
    package = 'com.qcxr.qcxr.canary262'; forbiddenStablePackage = 'com.qcxr.qcxr.dev262'
    versionCode = 71; versionName = '6.0.1-26.2-vivecraft-personal.12-rc.4'
    apkSha256 = 'A' * 64; apkSizeBytes = 123456789; artifactAudit = 'PASS'
    coreSha256 = $script:V71Rc4CoreSha256; coreSizeBytes = 10068021
    coreVersion = '26.2-1.3.15+qc.v71.rc4'; veqSha256 = $script:V71Rc4VeqSha256
    veqSizeBytes = 441660; veqVersion = '0.7.0-v70-canary.1'
    coreVeqPairSha256 = '9D2C0830A34963FF3D5F336B465A6B8D11C153E82A738D0528E8D1821F25A8B1'
    pojlibAarSha256 = $script:V71Rc4PojlibSha256; pojlibAarSizeBytes = 88700612
    signerSha256 = $script:V71Rc4SignerSha256
}
$receiptIdentity = [ordered]@{
    package = $identity.package; forbiddenStablePackage = $identity.forbiddenStablePackage
    versionCode = 71; versionName = $identity.versionName; apkSha256 = $identity.apkSha256
    apkSizeBytes = $identity.apkSizeBytes; coreSha256 = $identity.coreSha256
    veqSha256 = $identity.veqSha256; signerSha256 = $identity.signerSha256
}
$manualReceiptIdentity = [ordered]@{
    package = $identity.package; forbiddenStablePackage = $identity.forbiddenStablePackage
    versionCode = 71; versionName = $identity.versionName
    apkPath = $script:V71Rc4LabApkRelativePath
    apkSha256 = $identity.apkSha256; apkSizeBytes = $identity.apkSizeBytes
    coreVersion = $identity.coreVersion; coreSha256 = $identity.coreSha256
    coreSizeBytes = $identity.coreSizeBytes; veqVersion = $identity.veqVersion
    veqSha256 = $identity.veqSha256; veqSizeBytes = $identity.veqSizeBytes
    coreVeqPairSha256 = $identity.coreVeqPairSha256
    pojlibAarSha256 = $identity.pojlibAarSha256
    pojlibAarSizeBytes = $identity.pojlibAarSizeBytes
    signerSha256 = $identity.signerSha256
}

function New-MemoryCapture([string] $StartedUtc, [int] $ProcessId,
        [uint64] $StartTicks, [int] $BasePssKib) {
    $started = [DateTimeOffset]::Parse($StartedUtc); $samples = @()
    foreach ($index in 0..18) {
        $elapsed = $index * 5.0
        $samples += [ordered]@{
            timestampUtc = $started.AddMinutes($elapsed).ToString('o')
            elapsedMinutes = $elapsed; pid = $ProcessId; pidStable = $true
            focus = 'focused'; gameJvmAlive = $true
            totalPssKib = $BasePssKib + (512 * $index)
            totalRssKib = $BasePssKib + 2048 + (320 * $index)
            javaHeapKib = 524288 + (64 * $index); nativeHeapKib = 393216 + (32 * $index)
            graphicsKib = 262144; vmRssKib = $BasePssKib + 1024 + (256 * $index)
            vmSwapKib = 65536; memAvailableKib = 2097152 - (1024 * $index)
            swapFreeKib = 3145728 - (256 * $index)
        }
    }
    $rows = @($samples | ForEach-Object { [pscustomobject]$_ })
    $postWarm = @($rows | Where-Object elapsedMinutes -ge 15.0)
    $lastThirty = @($rows | Where-Object elapsedMinutes -ge 60.0)
    $startEpoch = [double]$started.ToUnixTimeSeconds()
    $provenance = [ordered]@{ schemaVersion = 1; verifiedUtc = $started.ToString('o')
        installedIdentityMatched = $true; baseApkMatched = $true
        persistentCoreMatched = $true; persistentVeqMatched = $true; allMatched = $true }
    $start = [ordered]@{
        schemaVersion = 1; receiptType = 'V71_RC4_MEMORY_SOAK_RUNTIME_START'; result = 'PASS'
        observedUtc = $started.ToString('o'); pid = $ProcessId; processStartTicks = $StartTicks
        producerSha256 = $producerHashes.memorySoak; processStartEpochSeconds = $startEpoch
        exactPidAlive = $true; gameJvmAlive = $true; provenanceMatched = $true
        exactJvmMemoryLineObserved = $true; xmsMiB = 512; xmxMiB = 1536; xmxSource = 'auto'
        jvmMemoryLineCount = 1; launcherLogSizeBytes = 100
        launcherLogModifiedEpochSeconds = $startEpoch
        launcherLogTemporallyBoundToProcess = $true
        launcherResourceReleaseAppliedObserved = $true
        launcherReleaseAppliedMarkerCount = 1; launcherReleaseDegradedMarkerCount = 0
        launcherAppliedMarkerEpochSeconds = $startEpoch
        launcherMarkerTemporallyBoundToProcess = $true
        runtimeFenceBeforeStartProvenance = $true; runtimeFenceAfterStartProvenance = $true
    }
    $final = [ordered]@{
        schemaVersion = 1; receiptType = 'V71_RC4_MEMORY_SOAK_RUNTIME_FINAL'; result = 'PASS'
        observedUtc = $started.AddMinutes(90).ToString('o'); pid = $ProcessId
        processStartTicks = $StartTicks; processStartEpochSeconds = $startEpoch
        sameProcessIncarnation = $true
        exactPidAlive = $true; gameJvmAlive = $true; provenanceMatched = $true
        startJvmMemoryObservationCarriedForward = $true
        startLauncherMarkerCarriedForward = $true; finalLogcatMarkerRequired = $false
        runtimeFenceBeforeFinalProvenance = $true; runtimeFenceAfterFinalProvenance = $true
    }
    $summary = [ordered]@{
        schemaVersion = 2; package = $identity.package; provenance = $provenance
        finalProvenance = Copy-Value $provenance
        runtimeBinding = [ordered]@{
            schemaVersion = 1; receiptType = 'V71_RC4_MEMORY_SOAK_RUNTIME_BINDING'; result = 'PASS'
            start = $start; final = $final
            evidenceBoundary = [ordered]@{
                logcatMarkerCapturedOnlyAtStart = $true; finalLogcatMarkerRequired = $false
                processStartTicksPersistedForPidReuseDefense = $true
                processStartEpochPersistedForLogBinding = $true
                producerHashCapturedAtLaunch = $true; producerFileReadLockedForRun = $true
                launcherMarkerTemporallyBoundToProcess = $true
                launcherLogTemporallyBoundToProcess = $true
                gameJvmLivenessObservedAtBoundedFencesAndSamples = $true
                continuousGameJvmLivenessClaimed = $false
                rawLogsPersisted = $false; logSnippetsPersisted = $false
                deviceSerialPersisted = $false; accountDataPersisted = $false
                hostAbsolutePathsPersisted = $false
            }
        }
        producerSha256 = $producerHashes.memorySoak
        startedUtc = $StartedUtc; requestedDurationMinutes = 90; intervalSeconds = 300
        samples = 19; minimumExpectedSamples = 19; completeMetricSamples = 19
        initialPid = $ProcessId; pidStable = $true; focusStayedOnLab = $true
        gameJvmStayedAlive = $true
        maxPssMib = [math]::Round((($rows | Measure-Object totalPssKib -Maximum).Maximum / 1024.0), 3)
        maxRssMib = [math]::Round((($rows | Measure-Object vmRssKib -Maximum).Maximum / 1024.0), 3)
        maxProcessSwapMib = 64.0
        minMemAvailableMib = [math]::Round((($rows | Measure-Object memAvailableKib -Minimum).Minimum / 1024.0), 3)
        minSwapFreeMib = [math]::Round((($rows | Measure-Object swapFreeKib -Minimum).Minimum / 1024.0), 3)
        postWarmPssSlopeMibPerMinute = Get-V71Rc4PssSlope $postWarm 'fixture post-warm'
        lastThirtyMinutesGrowthMib = [math]::Round(
            ($lastThirty[-1].totalPssKib - $lastThirty[0].totalPssKib) / 1024.0, 3)
        acceptance = [ordered]@{
            completedDuration = $true; sampleCountComplete = $true
            allRequiredMetricsPresent = $true; focusStayedOnLab = $true
            gameJvmStayedAlive = $true; postWarmSamplesComplete = $true
            lastThirtySamplesComplete = $true; maxPssAtMost2457Point6Mib = $true
            maxRssAtMost2457Point6Mib = $true; processSwapAtMost512Mib = $true
            slopeAtMost2MibPerMinute = $true; lastThirtyGrowthAtMost128Mib = $true
            passed = $true
        }
        deviceInvocations = 100
    }
    [pscustomobject]@{ Summary = $summary; Samples = $samples }
}

function New-RunManifest {
    [ordered]@{
        SchemaVersion = 2; Package = $identity.package
        ForbiddenStablePackage = $identity.forbiddenStablePackage; Profile = '26.2'
        World = 'FPS-Stress-Test'; WorldMasterSha256 = $script:V71Rc4WorldSha256
        InstalledApk = [ordered]@{ Package = $identity.package; VersionCode = '71'
            VersionName = $identity.versionName; Sha256 = $identity.apkSha256
            SignerSha256 = $identity.signerSha256 }
        ConditionA = [ordered]@{ Name = 'RC3'; CoreSha256 = $script:V71Rc3CoreSha256; VeqSha256 = $script:V71Rc3VeqSha256 }
        ConditionB = [ordered]@{ Name = 'RC4'; CoreSha256 = $script:V71Rc4CoreSha256; VeqSha256 = $script:V71Rc4VeqSha256 }
        ProducerLineage = Copy-Value $performanceLineage
        Order = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
        WarmupSeconds = 300; PreflightSeconds = 10; SampleSeconds = 60
        MaximumPairAttempts = 3; InterRoundCooldownSeconds = 0
        Gates = [ordered]@{
            MinimumCoveragePercent = 95.0; MinimumLevel4Percent = 95.0
            CpuLevel = 4; GpuLevel = 4; MaximumStartTemperatureDeltaC = 1.0
            MaximumThermalPathDeltaC = 1.0; MaximumRefreshDistributionDistancePercent = 5.0
            MaximumRefreshMeanDeltaHz = 0.5; MaximumRefreshModeDeltaHz = 0.5
            MaximumRefreshTransitionDelta = 1; MaximumPersistentRegressionPercent = 2.0
        }
        PerformanceLevelLease = [ordered]@{
            Scope = 'Lab campaign only'; TargetCpuLevel = 4; TargetGpuLevel = 4
            OriginalCpuLevelSet = $true; OriginalCpuLevel = 2
            OriginalGpuLevelSet = $true; OriginalGpuLevel = 0
            ApplyAfterWorldReady = $true; VerifyBeforeWarmup = $true
            RestoreEveryRoundAndOuterFinally = $true
            RefreshPropertiesModified = $false; AdaptivePropertiesModified = $false
        }
        QgoContract = 'Dynamic refresh; CPU/GPU 4/4; application requests neither refresh nor performance hint'
        FinalState = 'Lab stopped on exact RC4 Core+VEQ pair; original CPU/GPU levels restored'
        StableTouched = $false; RawLogsPersisted = $false
    }
}
function New-Report([string] $Name) {
    $condition = $Name.Substring(0, 1); $pair = [int]$Name.Substring(1, 1)
    $core = if ($condition -ceq 'A') { $script:V71Rc3CoreSha256 } else { $script:V71Rc4CoreSha256 }
    $veq = if ($condition -ceq 'A') { $script:V71Rc3VeqSha256 } else { $script:V71Rc4VeqSha256 }
    [ordered]@{
        SchemaVersion = 1; Package = $identity.package; AppPid = 5000 + $pair
        RefreshPolicy = 'Dynamic'; ExactPidPollPercent = 100.0
        FocusedPollPercent = 100.0; SampleCoveragePercent = 100.0
        ValidForComparison = $true; InvalidReasons = @(); RawLogsPersisted = $false
        Aggregate = [ordered]@{
            MeanAppFps = 72.0; P10AppFps = 70.0; P95CpuAndGpuMs = 14.0
            MeanStaleAtStableRefresh = 1.0; MeanStalePerSecond = 1.0
            MeanDisplayRefreshHz = 72.0; DisplayRefreshModeHz = 72.0
            DisplayRefreshDistribution = @([ordered]@{ Hz = 72.0; Count = 60; Percent = 100.0 })
            RefreshTransitionCount = 0; CpuLevelMode = 4; GpuLevelMode = 4
            CpuLevel4Percent = 100.0; GpuLevel4Percent = 100.0
            FirstTempC = 38.0; MeanTempC = 38.2; LastTempC = 38.4; MaxTempC = 38.5
        }
        Protocol = [ordered]@{
            SchemaVersion = 2; Condition = $condition; Pair = $pair; Attempt = 1
            CoreSha256 = $core; VeqSha256 = $veq; InstalledApkSha256 = $identity.apkSha256
            ProducerLineage = Copy-Value $performanceLineage
            OtherModsFingerprintSha256 = 'C' * 64
            MarkerState = if ($condition -ceq 'A') { 'consumed' } else { 'absent' }
            WorldMasterSha256 = $script:V71Rc4WorldSha256
            WorldResetBeforeLaunch = $true; ColdLaunch = $true
            WarmupSeconds = 300; PreflightSeconds = 10; StartTemperatureC = 38.0
            RoundPid = 5000 + $pair
            FreshnessProof = [ordered]@{
                Source = 'device marker + fresh latest.log byte slice'; SliceMode = 'NEW_FILE'
                FreshByteStart = 1; AdvancementMarkers = 2; CoreVersionMarkers = 1
                VeqVersionMarkers = 1; MarkerMtime = 100; LogMtime = 101
            }
            PerformanceLevelLease = [ordered]@{
                AppliedAfterWorldReady = $true; VerifiedBeforeWarmup = $true
                CpuLevel = 4; GpuLevel = 4
                RefreshPropertiesModified = $false; AdaptivePropertiesModified = $false
            }
            CapturedAtUtc = '2026-09-06T10:00:00Z'
        }
    }
}
function New-Comparison($Reports, $RunManifest) {
    $pairs = @()
    foreach ($pair in 1..3) {
        $a = [double]$Reports["A$pair"].Aggregate.MeanAppFps
        $b = [double]$Reports["B$pair"].Aggregate.MeanAppFps
        $pairs += [ordered]@{ Pair = $pair; Comparable = $true
            GuardrailsPass = ($b -ge ($a * 0.98)); Rc3MeanFps = [math]::Round($a, 2)
            Rc4MeanFps = [math]::Round($b, 2) }
    }
    $aMean = [double](($Reports.A1.Aggregate.MeanAppFps, $Reports.A2.Aggregate.MeanAppFps,
        $Reports.A3.Aggregate.MeanAppFps | Measure-Object -Average).Average)
    $bMean = [double](($Reports.B1.Aggregate.MeanAppFps, $Reports.B2.Aggregate.MeanAppFps,
        $Reports.B3.Aggregate.MeanAppFps | Measure-Object -Average).Average)
    $passes = @($pairs | Where-Object GuardrailsPass).Count
    $passed = $bMean -ge ($aMean * 0.98) -and $passes -ge 2
    [ordered]@{
        SchemaVersion = 1
        Result = if ($passed) { 'PASS_RC4_NO_PERSISTENT_REGRESSION' } else { 'FAIL_RC4_PERFORMANCE_GATE' }
        PerformanceGatePassed = $passed
        ConditionA = 'RC3 Core+VEQ under integrated RC4 Lab APK'
        ConditionB = 'integrated RC4 Core+VEQ under the same RC4 Lab APK'
        InstalledApkSha256 = $identity.apkSha256
        ProducerLineageSha256 = $RunManifest.ProducerLineage.DigestSha256
        Order = @($RunManifest.Order); Pairs = $pairs
        Aggregate = [ordered]@{ Rc3MeanFps = [math]::Round($aMean, 2)
            Rc4MeanFps = [math]::Round($bMean, 2); AggregateGuardrailsPass = $passed
            PairGuardrailPassCount = $passes; PersistentMetricRegression = $false
            MaximumRegressionPercent = 2.0 }
        StableTouched = $false; RawLogsPersisted = $false
    }
}

$reportNames = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
$summaryPaths = @((Join-Path $memoryRoot 'rc4-soak-1/summary.json'),
    (Join-Path $memoryRoot 'rc4-soak-2/summary.json'))
$samplesPaths = @((Join-Path $memoryRoot 'rc4-soak-1/samples.jsonl'),
    (Join-Path $memoryRoot 'rc4-soak-2/samples.jsonl'))
$runPath = Join-Path $campaignRoot 'run-manifest.json'
$comparisonPath = Join-Path $campaignRoot 'comparison.json'
$lifecyclePath = Join-Path $acceptanceRoot 'v71-lab-rc4-lifecycle-recovery-receipt.json'
$runtimePath = Join-Path $acceptanceRoot 'v71-rc4-memory-runtime-contract-receipt.json'
$manualPath = Join-Path $acceptanceRoot 'v71-rc4-manual-vr-receipt.json'

function Reset-Fixture {
    $script:captures = @(New-MemoryCapture '2026-09-06T06:00:00Z' 4001 ([uint64]100001) 2000000
        New-MemoryCapture '2026-09-06T08:00:00Z' 4002 ([uint64]100002) 2001024)
    $script:runManifest = New-RunManifest; $script:reports = @{}
    foreach ($name in $reportNames) { $script:reports[$name] = New-Report $name }
    $script:comparison = New-Comparison $script:reports $script:runManifest
    $script:lifecycle = [ordered]@{
        schemaVersion = 1; receiptType = 'V71_LAB_RC4_LIFECYCLE_RECOVERY'; result = 'PASS'
        labIdentity = Copy-Value $receiptIdentity
        finalState = [ordered]@{ exactRc4Pair = $true; stableTouched = $false }
        producerLineage = Copy-Value $lifecycleLineage
    }
    $script:manual = [ordered]@{
        schemaVersion = 1; receiptType = 'V71_RC4_MANUAL_VR_INTERACTION'
        status = 'PASS_CONFIRMED_BY_USER'; labIdentity = Copy-Value $manualReceiptIdentity
        confirmation = [ordered]@{
            source = 'explicit-user-message'
            recordedBy = 'human-recorded-from-explicit-user-confirmation'
            confirmedUtc = '2026-09-06T10:00:00Z'
            statement = 'The user confirmed that every listed manual RC4 check passed.'
            userQuote = 'RC4 tested and accepted.'
        }
        checks = [ordered]@{}
        exactCandidateRuntime = 'PASS'; exactCandidateManualGate = 'PASS'
        stableTouched = $false
    }
    foreach ($name in $script:V71Rc4ManualCheckNames) { $script:manual.checks[$name] = 'PASS' }
}
function Save-Fixture {
    foreach ($index in 0..1) {
        Write-Json $script:captures[$index].Summary $summaryPaths[$index]
        Write-JsonLines $script:captures[$index].Samples $samplesPaths[$index]
    }
    Write-Json $script:runManifest $runPath
    foreach ($name in $reportNames) { Write-Json $script:reports[$name] (Join-Path $campaignRoot "$name.json") }
    Write-Json $script:comparison $comparisonPath
    Write-Json $script:lifecycle $lifecyclePath; Write-Json $script:manual $manualPath
    $runtimeSoaks = @(); $direct = @()
    foreach ($index in 0..1) {
        $summary = $script:captures[$index].Summary; $binding = $summary.runtimeBinding
        $observation = [ordered]@{
            index = $index + 1; available = $true
            evidenceBasis = 'integrated-start-final-same-process-incarnation'
            initialPid = $summary.initialPid; processStartTicks = $binding.start.processStartTicks
            startObservedUtc = $binding.start.observedUtc; finalObservedUtc = $binding.final.observedUtc
            sameAndroidProcessIncarnation = $true; gameJvmAliveAtStartAndFinal = $true
            provenanceMatchedAtStartAndFinal = $true; xmsMiB = 512; xmxMiB = 1536
            xmxSource = 'auto'; launcherResourceReleaseAppliedAtStart = $true
            finalLogcatMarkerRequired = $false
        }
        $runtimeSoaks += [ordered]@{
            index = $index + 1; summarySha256 = Get-Hash $summaryPaths[$index]
            samplesSha256 = Get-Hash $samplesPaths[$index]; producerSha256 = $producerHashes.memorySoak
            startedUtc = $summary.startedUtc; initialPid = $summary.initialPid
            runtimeObservation = $observation
        }
        $direct += Copy-Value $observation
    }
    $script:runtime = [ordered]@{
        schemaVersion = 1; receiptType = 'V71_RC4_MEMORY_RUNTIME_CONTRACT'; result = 'PASS'
        createdUtc = '2026-09-06T10:30:00Z'
        producer = [ordered]@{ hashScheme = 'sha256-utf8-normalized-lf'; sha256 = $producerHashes.memoryRuntimeContract }
        labIdentity = Copy-Value $receiptIdentity
        memoryPolicy = [ordered]@{ xmsMiB = 512; automaticXmxMiB = 1536
            manualXmxHardCapMiB = 2048; pojlibAarSha256 = $script:V71Rc4PojlibSha256
            perSoakJvmArgumentObservedDirectly = $true }
        launcherResourceRelease = [ordered]@{ lifecycleReceiptSha256 = Get-Hash $lifecyclePath
            perSoakAppliedMarkerObservedDirectlyAtStart = $true }
        soaks = $runtimeSoaks; directObservations = $direct
        evidenceBoundary = [ordered]@{
            crossEvidenceContractNotPerProcessAttestation = $false
            directPerSoakJvmArgumentClaim = $true; directPerSoakResourceReleaseMarkerClaim = $true
            launcherMarkerCapturedOnlyAtSoakStart = $true
            finalLogcatMarkerRetentionRequired = $false
            sameProcessIncarnationUsesPidAndStartTicks = $true
            rawLogsPersisted = $false; logSnippetsPersisted = $false
            deviceSerialPersisted = $false; accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
    Write-Json $script:runtime $runtimePath
    $reportLocks = @()
    foreach ($name in $reportNames) {
        $path = Join-Path $campaignRoot "$name.json"
        $reportLocks += [ordered]@{ path = "artifacts/benchmarks/rc4/$name.json"; sha256 = Get-Hash $path }
    }
    $script:manifest = [ordered]@{
        schemaVersion = 1; status = 'ACCEPTED_FOR_STABLE_BUILD'; labIdentity = Copy-Value $identity
        stableTarget = [ordered]@{ package = 'com.qcxr.qcxr.dev262'; versionCode = 71
            versionName = '6.0.1-26.2-vivecraft-personal.12'; signerSha256 = $identity.signerSha256
            mustRemainUntouchedUntilPromotion = $true }
        producerScripts = [ordered]@{
            memorySoakPath = $producerMap.memorySoak; memorySoakSha256 = $producerHashes.memorySoak
            memoryRuntimeContractPath = $producerMap.memoryRuntimeContract
            memoryRuntimeContractSha256 = $producerHashes.memoryRuntimeContract
            performanceHarnessPath = $producerMap.performanceHarness
            performanceHarnessSha256 = $producerHashes.performanceHarness
            lifecycleRecoveryPath = $producerMap.lifecycleRecovery
            lifecycleRecoverySha256 = $producerHashes.lifecycleRecovery
        }
        memorySoaks = @(
            [ordered]@{ round = 1; status = 'PASS'; producerSha256 = $producerHashes.memorySoak
                summaryPath = 'artifacts/memory/rc4-soak-1/summary.json'; summarySha256 = Get-Hash $summaryPaths[0]
                samplesPath = 'artifacts/memory/rc4-soak-1/samples.jsonl'; samplesSha256 = Get-Hash $samplesPaths[0]
                requiresStartRuntimeReceipt = $true; requiresSamePidFinalReceipt = $true },
            [ordered]@{ round = 2; status = 'PASS'; producerSha256 = $producerHashes.memorySoak
                summaryPath = 'artifacts/memory/rc4-soak-2/summary.json'; summarySha256 = Get-Hash $summaryPaths[1]
                samplesPath = 'artifacts/memory/rc4-soak-2/samples.jsonl'; samplesSha256 = Get-Hash $samplesPaths[1]
                requiresStartRuntimeReceipt = $true; requiresSamePidFinalReceipt = $true }
        )
        performance = [ordered]@{ status = 'PASS'; requiredResult = 'PASS_RC4_NO_PERSISTENT_REGRESSION'
            runManifestPath = 'artifacts/benchmarks/rc4/run-manifest.json'; runManifestSha256 = Get-Hash $runPath
            comparisonPath = 'artifacts/benchmarks/rc4/comparison.json'; comparisonSha256 = Get-Hash $comparisonPath
            reports = $reportLocks }
        lifecycleRecovery = [ordered]@{ status = 'PASS'
            receiptPath = 'artifacts/acceptance/v71-lab-rc4-lifecycle-recovery-receipt.json'
            receiptSha256 = Get-Hash $lifecyclePath; requiredReceiptType = 'V71_LAB_RC4_LIFECYCLE_RECOVERY' }
        memoryRuntimeContract = [ordered]@{ status = 'PASS'
            receiptPath = 'artifacts/acceptance/v71-rc4-memory-runtime-contract-receipt.json'
            receiptSha256 = Get-Hash $runtimePath; requiredReceiptType = 'V71_RC4_MEMORY_RUNTIME_CONTRACT' }
        manual = [ordered]@{ status = 'ACCEPTED'
            receiptPath = 'artifacts/acceptance/v71-rc4-manual-vr-receipt.json'
            receiptSha256 = Get-Hash $manualPath; requiredReceiptType = 'V71_RC4_MANUAL_VR_INTERACTION' }
        evidenceBoundary = [ordered]@{ rc3ReceiptsAreDiagnosticOnly = $true
            rc3ReceiptsMaySatisfyRc4Acceptance = $false; stableTouched = $false
            rawLogsPersisted = $false; deviceSerialPersisted = $false; accountDataPersisted = $false }
    }
    Write-Json $script:manifest $manifestPath
}
function Invoke-FixtureGate {
    Assert-V71Rc4StableAcceptanceEvidenceCore `
        -ManifestPath $manifestPath -RepoRoot $fixtureRepoRoot -EvidenceRoot $fixtureEvidenceRoot `
        -MemorySamplerPath (Join-Path $fixtureRepoRoot $producerMap.memorySoak) `
        -MemoryRuntimeContractPath (Join-Path $fixtureRepoRoot $producerMap.memoryRuntimeContract) `
        -PerformanceHarnessPath (Join-Path $fixtureRepoRoot $producerMap.performanceHarness) `
        -LifecycleHarnessPath (Join-Path $fixtureRepoRoot $producerMap.lifecycleRecovery) `
        -ExpectedPerformanceProducerSha256 $producerHashes.performanceHarness
}

$tests = [Collections.Generic.List[string]]::new()
try {
    $templatePath = Join-Path $repoRoot 'V71_MANUAL_ACCEPTANCE.template.json'
    $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json -Depth 20 -DateKind String
    Require-Test ([string]$template.status -ceq 'PENDING_USER_CONFIRMATION' -and
        [string]$template.confirmation.source -ceq 'explicit-user-message' -and
        [string]$template.confirmation.recordedBy -ceq
            'human-recorded-from-explicit-user-confirmation' -and
        [string]$template.labIdentity.apkSha256 -ceq $script:V71Rc4ApkSha256 -and
        [int64]$template.labIdentity.apkSizeBytes -eq 128434961 -and
        @($template.checks.PSObject.Properties).Count -eq 16) `
        'Checked-in manual template is not the exact pending RC4 contract.'
    Require-Test (Expect-Failure {
        Assert-V71Rc4ManualAcceptanceReceipt $template $script:V71Rc4ApkSha256 128434961
    } 'explicit-user status is invalid') 'Pending manual template was accepted as user confirmation.'
    $tests.Add('pending-manual-template-exact-and-fail-closed')

    Reset-Fixture; Save-Fixture
    $receipt = Invoke-FixtureGate
    Require-Test ($receipt.Result -ceq 'PASS' -and $receipt.PerformanceReportSha256.Count -eq 6 -and
        $receipt.LifecycleProducerLineageSha256 -ceq $lifecycleLineage.digestSha256 -and
        -not $receipt.Rc3EvidenceAccepted -and -not $receipt.StableTouched) 'Complete RC4 fixture rejected.'
    $tests.Add('schema2-runtime-binding-raw-recompute-read-lock-reaggregation')

    Reset-Fixture; $script:lifecycle.producerLineage.schemaVersion = '1'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'JSON integer 1') `
        'String lifecycle producer-lineage schema accepted.'
    $tests.Add('lifecycle-lineage-schema-type-tamper-rejected')

    Reset-Fixture; $script:lifecycle.producerLineage.hashScheme = 'sha256-raw-bytes'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'hash scheme drifted') `
        'Lifecycle producer-lineage hash-scheme drift accepted.'
    $tests.Add('lifecycle-lineage-hash-scheme-tamper-rejected')

    Reset-Fixture
    $lifecycleFiles = @($script:lifecycle.producerLineage.files)
    $script:lifecycle.producerLineage.files = @($lifecycleFiles[1], $lifecycleFiles[0])
    $script:lifecycle.producerLineage.digestSha256 =
        Get-V71Rc4ProducerLineageDigest @($script:lifecycle.producerLineage.files)
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'drifted from the reviewed producer closure') `
        'Reordered lifecycle producer closure accepted.'
    $tests.Add('lifecycle-lineage-order-tamper-rejected')

    Reset-Fixture
    $script:lifecycle.producerLineage.files[0].relativePath =
        'scripts/quest-v71-lab-lifecycle-recovery.ps1'
    $script:lifecycle.producerLineage.digestSha256 =
        Get-V71Rc4ProducerLineageDigest @($script:lifecycle.producerLineage.files)
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'drifted from the reviewed producer closure') `
        'Legacy lifecycle producer path accepted.'
    $tests.Add('lifecycle-lineage-rc4-path-tamper-rejected')

    Reset-Fixture; $script:lifecycle.producerLineage.files[0].sha256 = 'F' * 64
    $script:lifecycle.producerLineage.digestSha256 =
        Get-V71Rc4ProducerLineageDigest @($script:lifecycle.producerLineage.files)
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'drifted from the reviewed producer closure') `
        'Unpinned lifecycle producer hash accepted.'
    $tests.Add('lifecycle-lineage-producer-hash-tamper-rejected')

    Reset-Fixture
    $script:lifecycle.producerLineage.files[1].relativePath = 'scripts/autoplay-lookalike.ps1'
    $script:lifecycle.producerLineage.digestSha256 =
        Get-V71Rc4ProducerLineageDigest @($script:lifecycle.producerLineage.files)
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'drifted from the reviewed producer closure') `
        'Unreviewed autoplay producer path accepted.'
    $tests.Add('lifecycle-lineage-autoplay-path-tamper-rejected')

    Reset-Fixture; $script:lifecycle.producerLineage.files[1].sha256 = 'E' * 64
    $script:lifecycle.producerLineage.digestSha256 =
        Get-V71Rc4ProducerLineageDigest @($script:lifecycle.producerLineage.files)
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'drifted from the reviewed producer closure') `
        'Unpinned autoplay producer hash accepted.'
    $tests.Add('lifecycle-lineage-autoplay-hash-tamper-rejected')

    Reset-Fixture; $script:lifecycle.producerLineage.digestSha256 = 'D' * 64; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'digest does not match') `
        'Detached lifecycle producer-lineage digest accepted.'
    $tests.Add('lifecycle-lineage-digest-tamper-rejected')

    Reset-Fixture
    Add-Member -InputObject $script:lifecycle.producerLineage.files[0] `
        -NotePropertyName unreviewedField -NotePropertyValue 'PASS'
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'missing or unexpected properties') `
        'Unexpected lifecycle producer-lineage file property accepted.'
    $tests.Add('lifecycle-lineage-extra-property-rejected')

    Reset-Fixture; $script:manual.schemaVersion = '1'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'JSON integer 1') 'String manual schema accepted.'
    $tests.Add('manual-schema-type-tamper-rejected')

    Reset-Fixture; $script:manual.receiptType = 'V71_RC3_MANUAL_VR_INTERACTION'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'type or explicit-user status') `
        'Wrong manual receipt type accepted.'
    $tests.Add('manual-receipt-type-tamper-rejected')

    Reset-Fixture; $script:manual.status = 'ACCEPTED'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'type or explicit-user status') `
        'Legacy ACCEPTED manual status accepted.'
    $tests.Add('manual-legacy-status-rejected')

    Reset-Fixture; $script:manual.confirmation.source = 'explicit-user-confirmation'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'explicit user message') `
        'Legacy confirmation source accepted.'
    $tests.Add('manual-source-tamper-rejected')

    Reset-Fixture; $script:manual.confirmation.recordedBy = 'automation'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'explicit user message') `
        'Automated recorder accepted.'
    $tests.Add('manual-recorder-tamper-rejected')

    Reset-Fixture; $script:manual.confirmation.Remove('recordedBy'); Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'missing or unexpected properties') `
        'Missing manual recordedBy accepted.'
    $tests.Add('manual-recorder-missing-rejected')

    Reset-Fixture; $script:manual.confirmation['untrustedField'] = 'PASS'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'missing or unexpected properties') `
        'Unexpected manual confirmation field accepted.'
    $tests.Add('manual-extra-confirmation-field-rejected')

    Reset-Fixture; $script:manual.confirmation.confirmedUtc = '2026-09-06 10:00:00'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'canonical UTC ISO-8601') `
        'Non-canonical manual timestamp accepted.'
    $tests.Add('manual-noncanonical-time-rejected')

    Reset-Fixture; $script:manual.confirmation.confirmedUtc = '2026-02-30T10:00:00Z'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'not an ISO-8601 timestamp') `
        'Impossible manual timestamp accepted.'
    $tests.Add('manual-invalid-time-rejected')

    Reset-Fixture; $script:manual.confirmation.statement = '   '; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'confirmation.statement is empty') `
        'Blank manual statement accepted.'
    $tests.Add('manual-blank-statement-rejected')

    Reset-Fixture; $script:manual.confirmation.userQuote = ''; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'confirmation.userQuote is empty') `
        'Blank manual user quote accepted.'
    $tests.Add('manual-blank-user-quote-rejected')

    Reset-Fixture; $script:manual.checks.bow = 'FAIL'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'check is not PASS: bow') `
        'Failed manual check accepted.'
    $tests.Add('manual-failed-check-rejected')

    Reset-Fixture; $script:manual.checks.Remove('bow'); Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'missing or unexpected properties') `
        'Missing manual check accepted.'
    $tests.Add('manual-missing-check-rejected')

    Reset-Fixture; $script:manual.checks['bypass'] = 'PASS'
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'missing or unexpected properties') `
        'Unexpected manual check accepted.'
    $tests.Add('manual-extra-check-rejected')

    Reset-Fixture; $script:manual.exactCandidateRuntime = 'NOT_RUN'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'does not confirm the exact candidate') `
        'Unvalidated exact candidate runtime accepted.'
    $tests.Add('manual-exact-runtime-required')

    Reset-Fixture; $script:manual.exactCandidateManualGate = 'PENDING'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'does not confirm the exact candidate') `
        'Pending exact manual gate accepted.'
    $tests.Add('manual-exact-gate-required')

    Reset-Fixture; $script:manual.stableTouched = 'false'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'says Stable was touched') `
        'String false Stable mutation marker accepted.'
    $tests.Add('manual-stable-touched-must-be-boolean')

    Reset-Fixture; $script:manual.labIdentity.coreVeqPairSha256 = 'F' * 64; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'complete exact RC4 Lab identity') `
        'Wrong manual Core/VEQ pair accepted.'
    $tests.Add('manual-complete-identity-tamper-rejected')

    Reset-Fixture; $script:manual.labIdentity.versionCode = '71'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'complete exact RC4 Lab identity') `
        'String manual identity versionCode accepted.'
    $tests.Add('manual-identity-numeric-types-enforced')

    Reset-Fixture; $script:manual.labIdentity.apkPath = 'builds/lookalike.apk'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'complete exact RC4 Lab identity') `
        'Wrong manual APK path accepted.'
    $tests.Add('manual-exact-apk-path-enforced')

    Reset-Fixture; Add-Member -InputObject $script:manual.labIdentity `
        -NotePropertyName untrustedIdentityField -NotePropertyValue PASS
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'missing or unexpected properties') `
        'Unexpected manual identity field accepted.'
    $tests.Add('manual-extra-identity-field-rejected')

    Require-Test (Expect-Failure {
        Assert-V71Rc4StableAcceptanceEvidence `
            -ManifestPath $manifestPath -RepoRoot $fixtureRepoRoot -EvidenceRoot $fixtureEvidenceRoot `
            -MemorySamplerPath (Join-Path $fixtureRepoRoot $producerMap.memorySoak) `
            -MemoryRuntimeContractPath (Join-Path $fixtureRepoRoot $producerMap.memoryRuntimeContract) `
            -PerformanceHarnessPath (Join-Path $fixtureRepoRoot $producerMap.performanceHarness) `
            -LifecycleHarnessPath (Join-Path $fixtureRepoRoot $producerMap.lifecycleRecovery)
    } 'not the reviewed fixed RC4 producer') 'Production API trusted a self-declared producer.'
    $tests.Add('production-performance-producer-pinned')

    Reset-Fixture; $script:captures[0].Summary.schemaVersion = 1; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'summary schema or fixed protocol drifted') 'Legacy summary accepted.'
    $tests.Add('legacy-summary-rejected')

    Reset-Fixture; $script:captures[0].Summary.runtimeBinding.final.processStartTicks++; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'same process incarnation') 'Start-ticks mismatch accepted.'
    $tests.Add('pid-startticks-mismatch-rejected')

    Reset-Fixture; $script:captures[0].Summary.runtimeBinding.final.pid++; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'same process incarnation') 'PID mismatch accepted.'
    $tests.Add('pid-mismatch-rejected')

    Reset-Fixture; $script:captures[0].Summary.runtimeBinding.start.xmxMiB = 2048; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'Xmx or launcher marker') 'Changed Xmx accepted.'
    $tests.Add('xmx-mismatch-rejected')

    Reset-Fixture; $script:captures[0].Summary.runtimeBinding.start.launcherReleaseAppliedMarkerCount = 0; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'Xmx or launcher marker') 'Missing marker accepted.'
    $tests.Add('launcher-marker-mismatch-rejected')

    Reset-Fixture; $script:captures[0].Samples[18].totalPssKib += 262144; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'does not match the locked raw samples') 'Raw metric forgery accepted.'
    $tests.Add('raw-memory-recompute-rejected')

    Reset-Fixture; $script:captures[0].Samples[4].javaHeapKib = '524288'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'not a JSON number') 'String metric accepted.'
    $tests.Add('raw-memory-type-rejected')

    Reset-Fixture; $script:runManifest.ConditionA.Name = 'RC4'; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'condition payloads drifted') 'Manifest forgery accepted.'
    $tests.Add('ab-manifest-tamper-rejected')

    Reset-Fixture
    $script:reports.A1.Protocol.ProducerLineage.Files[1].Sha256 = 'D' * 64
    $script:reports.A1.Protocol.ProducerLineage.DigestSha256 =
        Get-V71Rc4ProducerLineageDigest @($script:reports.A1.Protocol.ProducerLineage.Files)
    Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'reviewed producer closure') 'Report lineage forgery accepted.'
    $tests.Add('report-lineage-tamper-rejected')

    Reset-Fixture; $script:reports.A1.Protocol.RoundPid++; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'fixed round/world/PID') 'Report PID detachment accepted.'
    $tests.Add('report-pid-detachment-rejected')

    Reset-Fixture; $script:reports.A1.Aggregate.MeanAppFps = 60.0; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'differs from fresh aggregation') 'Report/comparison mismatch accepted.'
    $tests.Add('report-reaggregation-rejected')

    Reset-Fixture; $script:comparison.Aggregate.Rc4MeanFps = 99.0; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'differs from fresh aggregation') 'Forged comparison accepted.'
    $tests.Add('forged-comparison-rejected')

    Reset-Fixture; $script:comparison.ProducerLineageSha256 = 'E' * 64; Save-Fixture
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'detached') 'Comparison lineage detachment accepted.'
    $tests.Add('comparison-lineage-detachment-rejected')

    Reset-Fixture; Save-Fixture; $lockedManifest = Copy-Value $script:manifest
    [IO.File]::AppendAllText($summaryPaths[0], " `n"); Write-Json $lockedManifest $manifestPath
    Require-Test (Expect-Failure { Invoke-FixtureGate } 'SHA-256 drifted') 'Post-lock mutation accepted.'
    $tests.Add('post-lock-evidence-mutation-rejected')

    [pscustomobject][ordered]@{
        Result = 'PASS'; HostOnly = $true; DeviceTouched = $false; AdbInvocations = 0
        Assertions = $tests.Count; Tests = $tests.ToArray()
        PendingCandidateRejectedBeforeProducerResolution = $pendingRejected
        SchemaVersion2AndRuntimeBindingValidated = $true; RawMemorySamplesRecomputed = $true
        PerformanceProducerPinnedAndReadLocked = $true
        PerformanceManifestReportsAndComparisonSemanticallyBound = $true
        PerformanceComparisonReaggregated = $true
        LifecycleProducerLineageValidated = $true
        ManualReceiptExactContractValidated = $true
        ManualCheckCount = $script:V71Rc4ManualCheckNames.Count
        ManualAdversarialTamperCasesRejected = $true
        SeparateRepoAndEvidenceRootsAccepted = $true; StableTouched = $false
    }
} finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        $canonicalTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($tempRoot.StartsWith($canonicalTemp, [StringComparison]::OrdinalIgnoreCase)) {
            [IO.Directory]::Delete($tempRoot, $true)
        }
    }
}
