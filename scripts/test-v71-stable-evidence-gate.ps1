#requires -Version 7.0
<# Host-only positive and fail-closed tests for v71 Stable evidence. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'v71-stable-evidence-gate.ps1')

function Assert-Test([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected([scriptblock] $Operation, [string] $Message) {
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected $Message
}

function Write-Json([object] $Value, [string] $Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}

function Write-JsonLines([object[]] $Values, [string] $Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $lines = @($Values | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function New-LabIdentity {
    return [ordered]@{
        package = 'com.qcxr.qcxr.canary262'
        forbiddenStablePackage = 'com.qcxr.qcxr.dev262'
        versionCode = 71
        versionName = '6.0.1-26.2-vivecraft-personal.12-rc.3'
        apkSha256 = 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
        apkSizeBytes = 128431385
        coreSha256 = '14B230B69AF24A53C459116AF2B2869F014690E6408D4881B5B1395C1EC38A26'
        veqSha256 = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
        signerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
    }
}

function New-MemoryCapture([string] $StartedUtc, [int] $ProcessId, [int] $BasePssKib) {
    $started = [DateTimeOffset]::Parse($StartedUtc)
    $samples = @()
    for ($index = 0; $index -le 18; $index++) {
        $elapsed = $index * 5.0
        $samples += [ordered]@{
            timestampUtc = $started.AddMinutes($elapsed).ToString('o')
            elapsedMinutes = $elapsed
            pid = $ProcessId
            pidStable = $true
            focus = 'focused'
            gameJvmAlive = $true
            totalPssKib = $BasePssKib + (512 * $index)
            totalRssKib = $BasePssKib + 2048 + (320 * $index)
            javaHeapKib = 524288 + (64 * $index)
            nativeHeapKib = 393216 + (32 * $index)
            graphicsKib = 262144
            vmRssKib = $BasePssKib + 1024 + (256 * $index)
            vmSwapKib = 65536
            memAvailableKib = 2097152 - (1024 * $index)
            swapFreeKib = 3145728 - (256 * $index)
        }
    }
    $normalized = @($samples | ForEach-Object { [pscustomobject]$_ })
    $postWarm = @($normalized | Where-Object elapsedMinutes -ge 15.0)
    $lastThirty = @($normalized | Where-Object elapsedMinutes -ge 60.0)
    $summary = [ordered]@{
        schemaVersion = 1
        package = 'com.qcxr.qcxr.canary262'
        provenance = [ordered]@{
            schemaVersion = 1
            verifiedUtc = $StartedUtc
            installedIdentityMatched = $true
            baseApkMatched = $true
            persistentCoreMatched = $true
            persistentVeqMatched = $true
            allMatched = $true
        }
        startedUtc = $StartedUtc
        requestedDurationMinutes = 90
        intervalSeconds = 300
        samples = 19
        minimumExpectedSamples = 19
        completeMetricSamples = 19
        initialPid = $ProcessId
        pidStable = $true
        focusStayedOnLab = $true
        gameJvmStayedAlive = $true
        maxPssMib = [math]::Round((($normalized | Measure-Object totalPssKib -Maximum).Maximum / 1024.0), 3)
        maxRssMib = [math]::Round((($normalized | Measure-Object vmRssKib -Maximum).Maximum / 1024.0), 3)
        maxProcessSwapMib = [math]::Round((($normalized | Measure-Object vmSwapKib -Maximum).Maximum / 1024.0), 3)
        minMemAvailableMib = [math]::Round((($normalized | Measure-Object memAvailableKib -Minimum).Minimum / 1024.0), 3)
        minSwapFreeMib = [math]::Round((($normalized | Measure-Object swapFreeKib -Minimum).Minimum / 1024.0), 3)
        postWarmPssSlopeMibPerMinute = Get-V71PssSlope $postWarm
        lastThirtyMinutesGrowthMib = [math]::Round(
            ($lastThirty[-1].totalPssKib - $lastThirty[0].totalPssKib) / 1024.0, 3)
        acceptance = [ordered]@{
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
        deviceInvocations = 100
    }
    return [pscustomobject]@{ Summary = $summary; Samples = $samples }
}

$tempRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP `
    ('v71-stable-evidence-test-' + [guid]::NewGuid().ToString('N'))))
$canonicalTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
Assert-Test ($tempRoot.StartsWith($canonicalTemp, [StringComparison]::OrdinalIgnoreCase)) `
    'Unsafe evidence-test root.'
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null

$memoryProducer = Join-Path $tempRoot 'memory-producer.ps1'
$memoryContractProducer = Join-Path $tempRoot 'quest-v71-memory-runtime-contract.ps1'
$performanceProducer = Join-Path $tempRoot 'performance-producer.ps1'
$lifecycleProducer = Join-Path $tempRoot 'lifecycle-producer.ps1'
$lifecycleDependency = Join-Path $tempRoot 'run-vivecraft-local-autoplay.ps1'
$soak1Path = Join-Path $tempRoot 'artifacts\memory\soak-1\summary.json'
$soak1SamplesPath = Join-Path $tempRoot 'artifacts\memory\soak-1\samples.jsonl'
$soak2Path = Join-Path $tempRoot 'work\agent-v70-integration\artifacts\memory\soak-2\summary.json'
$soak2SamplesPath = Join-Path $tempRoot 'work\agent-v70-integration\artifacts\memory\soak-2\samples.jsonl'
$campaignDirectory = Join-Path $tempRoot 'artifacts\benchmarks\campaign'
$runManifestPath = Join-Path $campaignDirectory 'run-manifest.json'
$comparisonPath = Join-Path $campaignDirectory 'comparison.json'
$reportNames = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
$manualPath = Join-Path $tempRoot 'artifacts\acceptance\v71-manual-vr-receipt.json'
$lifecyclePath = Join-Path $tempRoot `
    'artifacts\acceptance\v71-lab-lifecycle-recovery-receipt.json'
$memoryContractPath = Join-Path $tempRoot `
    'artifacts\acceptance\v71-memory-runtime-contract-receipt.json'
$acceptancePath = Join-Path $tempRoot 'V71_STABLE_ACCEPTANCE.lock.json'
[IO.File]::WriteAllText($memoryProducer, 'memory producer fixture')
[IO.File]::WriteAllText($memoryContractProducer, 'memory contract producer fixture')
[IO.File]::WriteAllText($lifecycleProducer, 'lifecycle producer fixture')
[IO.File]::Copy((Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1'),
    $lifecycleDependency, $false)
$performanceFixture = @'
#requires -Version 7.0
param(
    [ValidateSet('Aggregate')][string] $Action = 'Aggregate',
    [Parameter(Mandatory)][string] $OutputDirectory
)
$names = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
$reports = @{}
foreach ($name in $names) {
    $path = Join-Path $OutputDirectory ($name + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $name.json" }
    $reports[$name] = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}
$runManifestPath = Join-Path $OutputDirectory 'run-manifest.json'
if (-not (Test-Path -LiteralPath $runManifestPath -PathType Leaf)) {
    throw 'Missing run-manifest.json'
}
$lockedPaths = @($runManifestPath, (Join-Path $OutputDirectory 'comparison.json')) +
    @($names | ForEach-Object { Join-Path $OutputDirectory ($_ + '.json') })
foreach ($lockedPath in $lockedPaths) {
    $writeOpened = $false
    try {
        $writeProbe = [IO.File]::Open($lockedPath, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $writeOpened = $true
        $writeProbe.Dispose()
    } catch [IO.IOException] {}
    if ($writeOpened) { throw "Evidence was mutable during reaggregation: $lockedPath" }
}
$runManifest = Get-Content -Raw -LiteralPath $runManifestPath | ConvertFrom-Json
$producerLineageSha256 = [string]$runManifest.ProducerLineage.DigestSha256
$pairs = @()
for ($pair = 1; $pair -le 3; $pair++) {
    $a = $reports["A$pair"]
    $b = $reports["B$pair"]
    if ([string]$a.Protocol.Condition -cne 'A' -or [int]$a.Protocol.Pair -ne $pair -or
            [string]$b.Protocol.Condition -cne 'B' -or [int]$b.Protocol.Pair -ne $pair) {
        throw "Report identity mismatch for pair $pair."
    }
    $comparable = [bool]$a.Comparable -and [bool]$b.Comparable
    $guardrail = $comparable -and [bool]$a.GuardrailsPass -and [bool]$b.GuardrailsPass
    $pairs += [pscustomobject][ordered]@{
        Pair = $pair
        Comparable = $comparable
        GuardrailsPass = $guardrail
    }
}
$pairPasses = @($pairs | Where-Object GuardrailsPass).Count
$passed = @($pairs | Where-Object { -not $_.Comparable }).Count -eq 0 -and $pairPasses -ge 2
[pscustomobject][ordered]@{
    SchemaVersion = 1
    Result = if ($passed) { 'PASS_RC3_NO_PERSISTENT_REGRESSION' } else { 'FAIL_RC3_PERFORMANCE_GATE' }
    PerformanceGatePassed = $passed
    ConditionA = 'RC2 Core+VEQ under integrated RC3 Lab APK'
    ConditionB = 'integrated RC3 Core+VEQ under the same RC3 Lab APK'
    InstalledApkSha256 = 'B89181443E40E99FFA6DD094253631F59A4B0E01C21D10C5C3ADD0BBDF39AD8F'
    ProducerLineageSha256 = $producerLineageSha256
    Order = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
    Pairs = $pairs
    Aggregate = [pscustomobject][ordered]@{
        AggregateGuardrailsPass = $passed
        PairGuardrailPassCount = $pairPasses
        PersistentMetricRegression = $false
        MaximumRegressionPercent = 2.0
    }
    StableTouched = $false
    RawLogsPersisted = $false
}
'@
[IO.File]::WriteAllText($performanceProducer, $performanceFixture, [Text.UTF8Encoding]::new($false))

$performanceProducerSha256 = Get-V71TextProducerSha256 $performanceProducer `
    'fixture A/B producer'
$performanceLineageFiles = @(
    [pscustomobject][ordered]@{ Name = 'orchestrator'; RelativePath = 'scripts/quest-v71-rc2-rc3-ab.ps1'; Sha256 = $performanceProducerSha256 }
    [pscustomobject][ordered]@{ Name = 'pair-harness'; RelativePath = 'scripts/quest-v70-lab-pair.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['pair-harness'] }
    [pscustomobject][ordered]@{ Name = 'core-canary-harness'; RelativePath = 'scripts/quest-vivecraft-core-canary.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['core-canary-harness'] }
    [pscustomobject][ordered]@{ Name = 'veq-lab-harness'; RelativePath = 'scripts/quest-veq-lab.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['veq-lab-harness'] }
    [pscustomobject][ordered]@{ Name = 'world-reset-harness'; RelativePath = 'scripts/reset-lab-benchmark-world.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['world-reset-harness'] }
    [pscustomobject][ordered]@{ Name = 'autoplay-harness'; RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['autoplay-harness'] }
    [pscustomobject][ordered]@{ Name = 'vrapi-benchmark-harness'; RelativePath = 'scripts/quest-vrapi-pid-benchmark.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['vrapi-benchmark-harness'] }
    [pscustomobject][ordered]@{ Name = 'apk-verifier'; RelativePath = 'scripts/verify-dev-apk.ps1'; Sha256 = $script:V71ExpectedPerformanceDependencyHashes['apk-verifier'] }
)
$performanceLineage = [pscustomobject][ordered]@{
    SchemaVersion = 1
    HashScheme = $script:V71PerformanceProducerHashScheme
    DigestSha256 = Get-V71ProducerLineageDigest $performanceLineageFiles
    Files = $performanceLineageFiles
}
$lifecycleProducerSha256 = Get-V71TextProducerSha256 $lifecycleProducer `
    'fixture lifecycle/recovery producer'
$lifecycleLineageFiles = @(
    [pscustomobject][ordered]@{
        name = 'lifecycle-orchestrator'
        relativePath = 'scripts/quest-v71-lab-lifecycle-recovery.ps1'
        sha256 = $lifecycleProducerSha256
    }
    [pscustomobject][ordered]@{
        name = 'autoplay-harness'
        relativePath = 'scripts/run-vivecraft-local-autoplay.ps1'
        sha256 = $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness']
    }
)
$lifecycleLineage = [pscustomobject][ordered]@{
    schemaVersion = 1
    hashScheme = $script:V71PerformanceProducerHashScheme
    digestSha256 = Get-V71ProducerLineageDigest $lifecycleLineageFiles
    files = $lifecycleLineageFiles
}

$identity = New-LabIdentity
$soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
$soak2Capture = New-MemoryCapture '2026-09-06T08:16:23.0000000+00:00' 222 2001024
$soak1 = $soak1Capture.Summary
$soak1Samples = $soak1Capture.Samples
$soak2 = $soak2Capture.Summary
$soak2Samples = $soak2Capture.Samples
$runManifest = [ordered]@{
    SchemaVersion = 2
    Package = 'com.qcxr.qcxr.canary262'
    ForbiddenStablePackage = 'com.qcxr.qcxr.dev262'
    Profile = '26.2'
    World = 'FPS-Stress-Test'
    WorldMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
    InstalledApk = [ordered]@{
        Package = 'com.qcxr.qcxr.canary262'
        VersionCode = '71'
        VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.3'
        Sha256 = $identity.apkSha256
        SignerSha256 = $identity.signerSha256
    }
    ConditionA = [ordered]@{
        Name = 'RC2'
        CoreSha256 = 'AAC5852BD1495AA0121A078F87312A644608F209A9190AE539CDC4F7763CD8FC'
        VeqSha256 = '8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A'
    }
    ConditionB = [ordered]@{
        Name = 'RC3'
        CoreSha256 = $identity.coreSha256
        VeqSha256 = $identity.veqSha256
    }
    Order = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
    WarmupSeconds = 300
    PreflightSeconds = 10
    SampleSeconds = 60
    MaximumPairAttempts = 3
    InterRoundCooldownSeconds = 0
    Gates = [ordered]@{
        MinimumCoveragePercent = 95.0
        MinimumLevel4Percent = 95.0
        CpuLevel = 4
        GpuLevel = 4
        MaximumStartTemperatureDeltaC = 1.0
        MaximumThermalPathDeltaC = 1.0
        MaximumRefreshDistributionDistancePercent = 5.0
        MaximumRefreshMeanDeltaHz = 0.5
        MaximumRefreshModeDeltaHz = 0.5
        MaximumRefreshTransitionDelta = 1
        MaximumPersistentRegressionPercent = 2.0
    }
    PerformanceLevelLease = [ordered]@{
        Scope = 'Lab campaign only'
        TargetCpuLevel = 4
        TargetGpuLevel = 4
        OriginalCpuLevelSet = $true
        OriginalCpuLevel = 2
        OriginalGpuLevelSet = $true
        OriginalGpuLevel = 0
        ApplyAfterWorldReady = $true
        VerifyBeforeWarmup = $true
        RestoreEveryRoundAndOuterFinally = $true
        RefreshPropertiesModified = $false
        AdaptivePropertiesModified = $false
    }
    QgoContract = 'Dynamic refresh; CPU/GPU 4/4; application requests neither refresh nor performance hint'
    FinalState = 'Lab stopped on exact RC3 Core+VEQ pair; original CPU/GPU levels restored'
    StableTouched = $false
    RawLogsPersisted = $false
    ProducerLineage = $performanceLineage
}
$comparison = [ordered]@{
    SchemaVersion = 1
    Result = 'PASS_RC3_NO_PERSISTENT_REGRESSION'
    PerformanceGatePassed = $true
    ConditionA = 'RC2 Core+VEQ under integrated RC3 Lab APK'
    ConditionB = 'integrated RC3 Core+VEQ under the same RC3 Lab APK'
    InstalledApkSha256 = $identity.apkSha256
    ProducerLineageSha256 = $performanceLineage.DigestSha256
    Order = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
    Pairs = @(
        [ordered]@{ Pair = 1; Comparable = $true; GuardrailsPass = $true },
        [ordered]@{ Pair = 2; Comparable = $true; GuardrailsPass = $true },
        [ordered]@{ Pair = 3; Comparable = $true; GuardrailsPass = $true }
    )
    Aggregate = [ordered]@{
        AggregateGuardrailsPass = $true
        PairGuardrailPassCount = 3
        PersistentMetricRegression = $false
        MaximumRegressionPercent = 2.0
    }
    StableTouched = $false
    RawLogsPersisted = $false
}
$reportFixtures = @{}
foreach ($name in $reportNames) {
    $condition = $name.Substring(0, 1)
    $coreHash = if ($condition -ceq 'A') {
        'AAC5852BD1495AA0121A078F87312A644608F209A9190AE539CDC4F7763CD8FC'
    } else { $identity.coreSha256 }
    $veqHash = if ($condition -ceq 'A') {
        '8EB67999FA9334CF3B18F250B420668B912A2EE4F2B201DB51EE1E265744427A'
    } else { $identity.veqSha256 }
    $reportFixtures[$name] = [ordered]@{
        SchemaVersion = 1
        Package = 'com.qcxr.qcxr.canary262'
        ExactPidPollPercent = 100.0
        FocusedPollPercent = 100.0
        SampleCoveragePercent = 100.0
        ValidForComparison = $true
        RawLogsPersisted = $false
        Comparable = $true
        GuardrailsPass = $true
        Aggregate = [ordered]@{
            MeanAppFps = 72.0
            P10AppFps = 70.0
            P95CpuAndGpuMs = 14.0
            MeanStaleAtStableRefresh = 1.0
            MeanStalePerSecond = 1.0
            MeanDisplayRefreshHz = 72.0
            DisplayRefreshModeHz = 72.0
            RefreshTransitionCount = 0
            CpuLevelMode = 4
            GpuLevelMode = 4
            CpuLevel4Percent = 100.0
            GpuLevel4Percent = 100.0
            FirstTempC = 38.0
            MeanTempC = 38.2
            LastTempC = 38.4
            MaxTempC = 38.5
        }
        Protocol = [ordered]@{
            SchemaVersion = 2
            Condition = $condition
            Pair = [int]$name.Substring(1, 1)
            CoreSha256 = $coreHash
            VeqSha256 = $veqHash
            OtherModsFingerprintSha256 = 'C' * 64
            ProducerLineage = $performanceLineage
            PerformanceLevelLease = [ordered]@{
                AppliedAfterWorldReady = $true
                VerifiedBeforeWarmup = $true
                CpuLevel = 4
                GpuLevel = 4
                RefreshPropertiesModified = $false
                AdaptivePropertiesModified = $false
            }
        }
    }
}
$manual = [ordered]@{
    schemaVersion = 1
    receiptType = 'V71_MANUAL_VR_INTERACTION'
    status = 'PASS_CONFIRMED_BY_USER'
    labIdentity = $identity
    confirmation = [ordered]@{
        source = 'explicit-user-message'
        recordedBy = 'human-recorded-from-explicit-user-confirmation'
        confirmedUtc = '2026-09-06T10:00:00.0000000+00:00'
        statement = 'I manually tested the exact v71 RC3 Lab build in the headset and confirm every required interaction passed.'
        userQuote = 'I tested every listed interaction on this exact Lab build and all passed.'
    }
    checks = [ordered]@{
        immersiveMcPickupBothHands = 'PASS'
        wristThrowFullStackOutside = 'PASS'
        wristThrowSingleItemOutside = 'PASS'
        wristOtherHandCannotStealCarriedItem = 'PASS'
        yUsesLeftHandItemOnLegacyServer = 'PASS'
        bContainerAndInventoryBehavior = 'PASS'
        movingContainerMenus = 'PASS'
        gripBothHands = 'PASS'
        bow = 'PASS'
        shield = 'PASS'
        teleport = 'PASS'
    }
    stableTouched = $false
}
$lifecycle = [ordered]@{
    schemaVersion = 1
    receiptType = 'V71_LAB_LIFECYCLE_RECOVERY'
    result = 'PASS'
    startedUtc = '2026-09-06T10:00:00.0000000+00:00'
    completedUtc = '2026-09-06T10:20:00.0000000+00:00'
    producerLineage = $lifecycleLineage
    labIdentity = $identity
    phases = @(
        [ordered]@{
            name = 'preflight-exact-lab-and-rc3'; result = 'PASS'
            labInitiallyStopped = $true; stableStopped = $true
            installedApkMatched = $true; exactRc3PairBefore = $true
        },
        [ordered]@{
            name = 'clean-cold-openxr'; result = 'PASS'; startedFromStopped = $true
            exactRc3VersionRows = $true; openXrFocused = $true
            openXrFrame120Submitted = $true; benchmarkWorldLoaded = $true
            gameJvmAlive = $true
        },
        [ordered]@{
            name = 'post-openxr-process-stop-recovery'; result = 'PASS'
            liveOpenXrProcessStoppedBeforeRecovery = $true
            recoveryStartedFromStopped = $true; exactRc3VersionRows = $true
            openXrFocused = $true; openXrFrame120Submitted = $true
            benchmarkWorldLoaded = $true; gameJvmAlive = $true
        },
        [ordered]@{
            name = 'launcher-only-interruption'; result = 'PASS'
            startedFromStopped = $true; launcherOnlyProven = $true
            unityMainPresent = $true; gameJvmAbsent = $true
            minecraftLogUntouched = $true; interruptedByForceStop = $true
            randomInputSent = $false
        },
        [ordered]@{
            name = 'post-launcher-interruption-recovery'; result = 'PASS'
            launcherInterruptedBeforeRecovery = $true
            recoveryStartedFromStopped = $true; exactRc3VersionRows = $true
            openXrFocused = $true; openXrFrame120Submitted = $true
            benchmarkWorldLoaded = $true; gameJvmAlive = $true
        },
        [ordered]@{
            name = 'final-stopped-exact-rc3'; result = 'PASS'
            labStopped = $true; stableStopped = $true
            exactRc3PairAfter = $true; installedLabApkUnchanged = $true
            hostArtifactsUnchanged = $true
        }
    )
    finalState = [ordered]@{
        lab = 'stopped'; exactRc3Pair = $true; installedLabApkUnchanged = $true
        stablePidAbsent = $true; stableTouched = $false
    }
    evidenceBoundary = [ordered]@{
        rawLogsPersisted = $false; logSnippetsPersisted = $false
        deviceSerialPersisted = $false; processIdsPersisted = $false
        hostAbsolutePathsPersisted = $false; accountDataPersisted = $false
        saveDataPersistedByGate = $false; randomInputSent = $false
        manualInteractionClaim = $false; performanceClaim = $false
        memorySoakClaim = $false; postInitAcknowledgementProven = $false
        postInitAcknowledgementLimitation = 'Frozen RC3 has no ACK; Unity launcher and JVM share one Android PID.'
    }
}

function New-MemoryRuntimeContractFixture {
    return [ordered]@{
        schemaVersion = 1
        receiptType = 'V71_MEMORY_RUNTIME_CONTRACT'
        result = 'PASS'
        createdUtc = '2026-09-06T10:21:00.0000000+00:00'
        producer = [ordered]@{
            hashScheme = $script:V71PerformanceProducerHashScheme
            sha256 = Get-V71TextProducerSha256 $script:memoryContractProducer
        }
        labIdentity = $script:identity
        memoryPolicy = [ordered]@{
            xmsMiB = 512
            automaticXmxMiB = 1536
            manualXmxHardCapMiB = 2048
            pojlibAarSha256 = 'D7FF9C3EE2CCB332F88DE9A44E40E5BDA38F390142DC64905AEFD720FC3ADED6'
            exactColdStartObservations = 3
            allColdStartsObservedAutomatic1536 = $true
            evidenceBasis = 'exact-apk-contract-plus-three-observed-cold-starts'
            perSoakJvmArgumentObservedDirectly = $false
        }
        launcherResourceRelease = [ordered]@{
            exactBuildDefaultOn = $true
            lifecycleProducerRequestsOn = $true
            lifecycleReceiptSha256 = Get-V71FileSha256 $script:lifecyclePath
            evidenceBasis = 'exact-apk-default-on-policy-plus-reviewed-on-lifecycle-producer'
            perSoakAppliedMarkerObservedDirectly = $false
        }
        soaks = @(
            [ordered]@{
                index = 1
                summarySha256 = Get-V71FileSha256 $script:soak1Path
                samplesSha256 = Get-V71FileSha256 $script:soak1SamplesPath
                producerSha256 = Get-V71TextProducerSha256 $script:memoryProducer
                startedUtc = [DateTimeOffset]::Parse(
                    [string]$script:soak1.startedUtc).ToUniversalTime().ToString('o')
                finalSampleUtc = [DateTimeOffset]::Parse(
                    [string]$script:soak1Samples[-1].timestampUtc).ToUniversalTime().ToString('o')
                initialPid = [int]$script:soak1.initialPid
            },
            [ordered]@{
                index = 2
                summarySha256 = Get-V71FileSha256 $script:soak2Path
                samplesSha256 = Get-V71FileSha256 $script:soak2SamplesPath
                producerSha256 = Get-V71TextProducerSha256 $script:memoryProducer
                startedUtc = [DateTimeOffset]::Parse(
                    [string]$script:soak2.startedUtc).ToUniversalTime().ToString('o')
                finalSampleUtc = [DateTimeOffset]::Parse(
                    [string]$script:soak2Samples[-1].timestampUtc).ToUniversalTime().ToString('o')
                initialPid = [int]$script:soak2.initialPid
            }
        )
        directObservations = @(
            [ordered]@{
                index = 1
                available = $false
                reason = 'historical-process-ended-before-reviewed-direct-observer'
            },
            [ordered]@{
                index = 2
                available = $false
                reason = 'not-captured-before-process-exit-or-marker-unavailable'
            }
        )
        evidenceBoundary = [ordered]@{
            crossEvidenceContractNotPerProcessAttestation = $true
            directPerSoakJvmArgumentClaim = $false
            directPerSoakResourceReleaseMarkerClaim = $false
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
}

function Save-EvidenceFiles {
    Write-Json $script:soak1 $script:soak1Path
    Write-JsonLines $script:soak1Samples $script:soak1SamplesPath
    Write-Json $script:soak2 $script:soak2Path
    Write-JsonLines $script:soak2Samples $script:soak2SamplesPath
    Write-Json $script:runManifest $script:runManifestPath
    Write-Json $script:comparison $script:comparisonPath
    foreach ($name in $script:reportNames) {
        Write-Json $script:reportFixtures[$name] (Join-Path $script:campaignDirectory ($name + '.json'))
    }
    Write-Json $script:manual $script:manualPath
    Write-Json $script:lifecycle $script:lifecyclePath
    $script:memoryContract = New-MemoryRuntimeContractFixture
    Write-Json $script:memoryContract $script:memoryContractPath
}

function New-AcceptanceManifest([string] $Status = 'ACCEPTED_FOR_STABLE_BUILD') {
    $reports = @()
    foreach ($name in $script:reportNames) {
        $path = Join-Path $script:campaignDirectory ($name + '.json')
        $reports += [ordered]@{
            path = 'artifacts/benchmarks/campaign/' + $name + '.json'
            sha256 = Get-V71FileSha256 $path
        }
    }
    return [ordered]@{
        schemaVersion = 1
        status = $Status
        labIdentity = $script:identity
        producerScripts = [ordered]@{
            memorySoakSha256 = Get-V71TextProducerSha256 $script:memoryProducer
            memoryRuntimeContractSha256 = Get-V71TextProducerSha256 `
                $script:memoryContractProducer
            performanceHarnessSha256 = Get-V71TextProducerSha256 $script:performanceProducer
            lifecycleRecoverySha256 = Get-V71TextProducerSha256 `
                $script:lifecycleProducer
        }
        memorySoaks = @(
            [ordered]@{
                producerSha256 = Get-V71TextProducerSha256 $script:memoryProducer
                summaryPath = 'artifacts/memory/soak-1/summary.json'
                summarySha256 = Get-V71FileSha256 $script:soak1Path
                samplesPath = 'artifacts/memory/soak-1/samples.jsonl'
                samplesSha256 = Get-V71FileSha256 $script:soak1SamplesPath
            },
            [ordered]@{
                producerSha256 = Get-V71TextProducerSha256 $script:memoryProducer
                summaryPath = 'work/agent-v70-integration/artifacts/memory/soak-2/summary.json'
                summarySha256 = Get-V71FileSha256 $script:soak2Path
                samplesPath = 'work/agent-v70-integration/artifacts/memory/soak-2/samples.jsonl'
                samplesSha256 = Get-V71FileSha256 $script:soak2SamplesPath
            }
        )
        performance = [ordered]@{
            runManifestPath = 'artifacts/benchmarks/campaign/run-manifest.json'
            runManifestSha256 = Get-V71FileSha256 $script:runManifestPath
            comparisonPath = 'artifacts/benchmarks/campaign/comparison.json'
            comparisonSha256 = Get-V71FileSha256 $script:comparisonPath
            reports = $reports
        }
        manual = [ordered]@{
            receiptPath = 'artifacts/acceptance/v71-manual-vr-receipt.json'
            receiptSha256 = Get-V71FileSha256 $script:manualPath
        }
        lifecycleRecovery = [ordered]@{
            receiptPath = 'artifacts/acceptance/v71-lab-lifecycle-recovery-receipt.json'
            receiptSha256 = Get-V71FileSha256 $script:lifecyclePath
        }
        memoryRuntimeContract = [ordered]@{
            receiptPath = 'artifacts/acceptance/v71-memory-runtime-contract-receipt.json'
            receiptSha256 = Get-V71FileSha256 $script:memoryContractPath
        }
    }
}

function Invoke-FixtureGate([object] $Manifest) {
    Write-Json $Manifest $script:acceptancePath
    Assert-V71StableAcceptanceEvidenceCore `
        -ManifestPath $script:acceptancePath `
        -WorkspaceRoot $script:tempRoot `
        -MemorySamplerPath $script:memoryProducer `
        -PerformanceHarnessPath $script:performanceProducer `
        -LifecycleHarnessPath $script:lifecycleProducer `
        -ExpectedMemoryProducerSha256 (Get-V71TextProducerSha256 $script:memoryProducer) `
        -ExpectedMemoryContractProducerSha256 `
            (Get-V71TextProducerSha256 $script:memoryContractProducer) `
        -ExpectedPerformanceProducerSha256 (Get-V71TextProducerSha256 $script:performanceProducer) `
        -ExpectedLifecycleProducerSha256 `
            (Get-V71TextProducerSha256 $script:lifecycleProducer) `
        -LegacyRoundOneMemoryProducerSha256 ('F' * 64)
}

$tests = [Collections.Generic.List[string]]::new()
try {
    $buildSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'build-v71-integrated.ps1')
    Assert-Test ($buildSource.Contains('Assert-V71StableAcceptanceEvidence') -and
        $buildSource.Contains('-LifecycleHarnessPath $lifecycleRecoveryScript') -and
        -not $buildSource.Contains('$script:Rc3Lock.acceptance') -and
        -not $buildSource.Contains('manualVrInteractionPassed')) `
        'The build entry point still contains a legacy boolean-only promotion path.'
    $tests.Add('build-entry-evidence-only')
    $rc3Lock = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\V71_LAB_RC3.lock.json') |
        ConvertFrom-Json
    $actualPerformanceProducerSha = Get-V71TextProducerSha256 `
        (Join-Path $PSScriptRoot 'quest-v71-rc2-rc3-ab.ps1') 'actual A/B producer'
    $actualEvidenceGateSha = Get-V71TextProducerSha256 `
        (Join-Path $PSScriptRoot 'v71-stable-evidence-gate.ps1') 'actual Stable evidence gate'
    $actualMemoryContractProducerSha = Get-V71TextProducerSha256 `
        (Join-Path $PSScriptRoot 'quest-v71-memory-runtime-contract.ps1') `
        'actual memory runtime contract producer'
    $actualLifecycleProducerSha = Get-V71TextProducerSha256 `
        (Join-Path $PSScriptRoot 'quest-v71-lab-lifecycle-recovery.ps1') `
        'actual lifecycle/recovery producer'
    $actualAutoplayProducerSha = Get-V71TextProducerSha256 `
        (Join-Path $PSScriptRoot 'run-vivecraft-local-autoplay.ps1') `
        'actual lifecycle/recovery autoplay dependency'
    Assert-Test ([string]$rc3Lock.source.performanceHarnessScriptSha256 -ceq
            $actualPerformanceProducerSha -and
        $actualPerformanceProducerSha -ceq $script:V71ExpectedPerformanceProducerSha256 -and
        [string]$rc3Lock.source.stableEvidenceGateScriptSha256 -ceq
            $actualEvidenceGateSha -and
        [string]$rc3Lock.source.memoryRuntimeContractScriptSha256 -ceq
            $actualMemoryContractProducerSha -and
        $actualMemoryContractProducerSha -ceq
            $script:V71ExpectedMemoryContractProducerSha256 -and
        [string]$rc3Lock.source.lifecycleRecoveryScriptSha256 -ceq
            $actualLifecycleProducerSha -and
        $actualLifecycleProducerSha -ceq $script:V71ExpectedLifecycleProducerSha256 -and
        [string]$rc3Lock.source.autoplayHarnessScriptSha256 -ceq
            $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness'] -and
        $actualAutoplayProducerSha -ceq
            $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness'] -and
        [string]$rc3Lock.memoryEvidenceProducers.current.rawSha256 -ceq
            'C6FE7345ACE4978599A4C15FA5AAA846A3AE664A9AB5485215F72AFD4DF41202' -and
        [string]$rc3Lock.memoryEvidenceProducers.legacyRoundOneOnly.rawSha256 -ceq
            'FD443A5E4A1D63BDBBFA648B4BE57C694B5121BA3E98D6E25A58D8B0E8311ED9' -and
        [string]$rc3Lock.memoryEvidenceProducers.legacyRoundOneOnly.commit -ceq
            'ec112fc8944eda1a95134959f90ec9afacf590f2' -and
        [string]$rc3Lock.memoryEvidenceProducers.legacyRoundOneOnly.gitBlob -ceq
            '940590e490f3546e8d279122d82a302f7bd54d57' -and
        (Assert-V71Timestamp $rc3Lock.memoryEvidenceProducers.legacyRoundOneOnly.trustedLaunchLocal `
            'legacy trusted launch').ToUniversalTime() -eq
            [DateTimeOffset]::Parse('2026-09-06T09:16:23+03:00').ToUniversalTime()) `
        'The reviewed legacy/current memory-producer lineage drifted.'
    $tests.Add('memory-producer-lineage-locked')

    $producerReadLock = Enter-V71ProducerReadLock $performanceProducer `
        'fixture A/B producer lock'
    try {
        $writeRejected = $false
        try {
            $writeProbe = [IO.File]::Open($performanceProducer,
                [IO.FileMode]::Open, [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite)
            $writeProbe.Dispose()
        } catch [IO.IOException] { $writeRejected = $true }
        Assert-Test $writeRejected `
            'The Stable gate producer lock allowed concurrent mutation.'
    } finally { $producerReadLock.Dispose() }
    $tests.Add('reaggregation-producer-read-locked')

    $snapshotPath = Join-Path $tempRoot 'artifacts\acceptance\snapshot-probe.json'
    Write-Json ([ordered]@{ value = 'before' }) $snapshotPath
    $snapshotHash = Get-V71FileSha256 $snapshotPath
    $snapshot = Resolve-V71LockedEvidenceFile `
        -WorkspaceRoot $tempRoot `
        -RelativePath 'artifacts/acceptance/snapshot-probe.json' `
        -ExpectedSha256 $snapshotHash `
        -RequiredPrefix 'artifacts/acceptance/' `
        -RequiredLeaf 'snapshot-probe.json' `
        -Context 'snapshot probe'
    try {
        $snapshotWriteRejected = $false
        try {
            $snapshotWriteProbe = [IO.File]::Open($snapshotPath,
                [IO.FileMode]::Open, [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite)
            $snapshotWriteProbe.Dispose()
        } catch [IO.IOException] { $snapshotWriteRejected = $true }
        $snapshotValue = Read-V71EvidenceJsonText $snapshot.Text 'snapshot probe'
        Assert-Test ($snapshotWriteRejected -and
            [string]$snapshotValue.value -ceq 'before' -and
            [string]$snapshot.Sha256 -ceq $snapshotHash) `
            'Locked evidence was not parsed from the exact hashed bytes.'
    } finally { $snapshot.ReadLock.Dispose() }
    Write-Json ([ordered]@{ value = 'after' }) $snapshotPath
    Assert-Test ([string](Read-V71EvidenceJsonText $snapshot.Text `
        'retained snapshot probe').value -ceq 'before') `
        'A captured evidence snapshot changed after its path was replaced.'
    $tests.Add('evidence-exact-byte-snapshot')

    Save-EvidenceFiles
    $receipt = Invoke-FixtureGate (New-AcceptanceManifest)
    Assert-Test ($receipt.Result -ceq 'PASS') 'A complete exact evidence set was rejected.'
    Assert-Test ($receipt.PerformanceReportSha256.Count -eq 6) `
        'The positive receipt omitted retained A/B report hashes.'
    Assert-Test ([string]$receipt.LifecycleRecoveryReceiptSha256 -ceq
            (Get-V71FileSha256 $lifecyclePath) -and
        [string]$receipt.LifecycleRecoveryProducerSha256 -ceq
            $lifecycleProducerSha256 -and
        [string]$receipt.LifecycleRecoveryAutoplaySha256 -ceq
            $script:V71ExpectedLifecycleDependencyHashes['autoplay-harness'] -and
        [string]$receipt.LifecycleRecoveryLineageSha256 -ceq
            [string]$lifecycleLineage.digestSha256) `
        'The positive receipt omitted locked lifecycle/recovery lineage.'
    Assert-Test ([string]$receipt.ManifestSha256 -ceq
        (Get-V71FileSha256 $acceptancePath)) `
        'The receipt did not identify the exact acceptance-manifest bytes consumed.'
    Assert-Test ([string]$receipt.MemoryRuntimeContractReceiptSha256 -ceq
            (Get-V71FileSha256 $memoryContractPath) -and
        [string]$receipt.MemoryRuntimeContractProducerSha256 -ceq
            (Get-V71TextProducerSha256 $memoryContractProducer)) `
        'The positive receipt omitted the memory runtime contract lineage.'
    $tests.Add('exact-positive')

    $missingMemoryContractSlot = New-AcceptanceManifest
    $missingMemoryContractSlot.Remove('memoryRuntimeContract')
    Assert-Rejected { Invoke-FixtureGate $missingMemoryContractSlot } `
        'An acceptance manifest without the memory runtime contract was accepted.'
    $tests.Add('memory-contract-slot-required')

    $badMemoryContractProducer = New-AcceptanceManifest
    $badMemoryContractProducer.producerScripts.memoryRuntimeContractSha256 = '0' * 64
    Assert-Rejected { Invoke-FixtureGate $badMemoryContractProducer } `
        'An unreviewed memory runtime contract producer was accepted.'
    $tests.Add('memory-contract-producer-drift-rejected')

    $lockedMemoryContract = New-AcceptanceManifest
    [IO.File]::AppendAllText($memoryContractPath, " `n")
    Assert-Rejected { Invoke-FixtureGate $lockedMemoryContract } `
        'A memory runtime contract changed after SHA-256 locking was accepted.'
    $tests.Add('memory-contract-hash-tamper-rejected')
    Save-EvidenceFiles

    $memoryContract.memoryPolicy.automaticXmxMiB = 2048
    Write-Json $memoryContract $memoryContractPath
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A memory contract claiming the wrong effective automatic Xmx was accepted.'
    $tests.Add('memory-contract-xmx-drift-rejected')
    Save-EvidenceFiles

    $memoryContract.evidenceBoundary.directPerSoakJvmArgumentClaim = $true
    Write-Json $memoryContract $memoryContractPath
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A memory contract overclaiming per-soak JVM argument evidence was accepted.'
    $tests.Add('memory-contract-overclaim-rejected')
    Save-EvidenceFiles

    $memoryContract.directObservations[1] = [ordered]@{
        index = 2
        available = $true
        receiptSha256 = '3' * 64
        sameAndroidPid = $true
        initialPid = [int]$soak2.initialPid
        xmsMiB = 512
        xmxMiB = 1536
        xmxSource = 'auto'
        launcherResourceReleaseApplied = $true
    }
    Write-Json $memoryContract $memoryContractPath
    $directReceipt = Invoke-FixtureGate (New-AcceptanceManifest)
    Assert-Test ($directReceipt.Result -ceq 'PASS') `
        'A valid optional direct same-process soak-2 observation was rejected.'
    $tests.Add('memory-contract-direct-soak2-supported')
    $memoryContract.directObservations[1].initialPid = 999
    Write-Json $memoryContract $memoryContractPath
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A direct soak-2 observation bound to another PID was accepted.'
    $tests.Add('memory-contract-direct-soak2-pid-drift-rejected')
    Save-EvidenceFiles

    $memoryContract.launcherResourceRelease.lifecycleReceiptSha256 = '2' * 64
    Write-Json $memoryContract $memoryContractPath
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A memory contract detached from lifecycle resource-release evidence was accepted.'
    $tests.Add('memory-contract-lifecycle-detach-rejected')
    Save-EvidenceFiles

    $missingLifecycleSlot = New-AcceptanceManifest
    $missingLifecycleSlot.Remove('lifecycleRecovery')
    Assert-Rejected { Invoke-FixtureGate $missingLifecycleSlot } `
        'An acceptance manifest without the mandatory lifecycle slot was accepted.'
    $tests.Add('lifecycle-slot-required')

    $badLifecycleProducer = New-AcceptanceManifest
    $badLifecycleProducer.producerScripts.lifecycleRecoverySha256 = '0' * 64
    Assert-Rejected { Invoke-FixtureGate $badLifecycleProducer } `
        'An unreviewed lifecycle/recovery producer was accepted.'
    $tests.Add('lifecycle-producer-drift-rejected')

    $lifecycleDependencyBytes = [IO.File]::ReadAllBytes($lifecycleDependency)
    [IO.File]::AppendAllText($lifecycleDependency, " `n")
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A mutated lifecycle/recovery autoplay producer dependency was accepted.'
    $tests.Add('lifecycle-dependency-file-drift-rejected')
    [IO.File]::WriteAllBytes($lifecycleDependency, $lifecycleDependencyBytes)

    $originalLifecycleDependencySha = `
        [string]$lifecycle.producerLineage.files[1].sha256
    $lifecycle.producerLineage.files[1].sha256 = '1' * 64
    $lifecycle.producerLineage.digestSha256 = `
        Get-V71ProducerLineageDigest @($lifecycle.producerLineage.files)
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A self-consistent lifecycle receipt from a mutated helper closure was accepted.'
    $tests.Add('lifecycle-lineage-tamper-rejected')
    $lifecycle.producerLineage.files[1].sha256 = $originalLifecycleDependencySha
    $lifecycle.producerLineage.digestSha256 = `
        Get-V71ProducerLineageDigest @($lifecycle.producerLineage.files)
    Save-EvidenceFiles

    $lifecycle.phases[2].openXrFrame120Submitted = $false
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A lifecycle receipt with a failed recovery phase was accepted.'
    $tests.Add('lifecycle-phase-failure-rejected')
    $lifecycle.phases[2].openXrFrame120Submitted = $true
    Save-EvidenceFiles

    $lifecycle.finalState.stableTouched = $true
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A lifecycle receipt that touched Stable was accepted.'
    $tests.Add('lifecycle-stable-touch-rejected')
    $lifecycle.finalState.stableTouched = $false
    Save-EvidenceFiles

    $lifecycle.evidenceBoundary.deviceSerialPersisted = $true
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A lifecycle receipt persisting a device serial was accepted.'
    $tests.Add('lifecycle-sensitive-output-rejected')
    $lifecycle.evidenceBoundary.deviceSerialPersisted = $false
    Save-EvidenceFiles

    $lockedLifecycle = New-AcceptanceManifest
    [IO.File]::AppendAllText($lifecyclePath, " `n")
    Assert-Rejected { Invoke-FixtureGate $lockedLifecycle } `
        'A lifecycle receipt changed after SHA-256 locking was accepted.'
    $tests.Add('lifecycle-hash-tamper-rejected')
    Save-EvidenceFiles

    $runManifest.PerformanceLevelLease.OriginalCpuLevelSet = $false
    $runManifest.PerformanceLevelLease.OriginalCpuLevel = $null
    Save-EvidenceFiles
    $unsetReceipt = Invoke-FixtureGate (New-AcceptanceManifest)
    Assert-Test ($unsetReceipt.Result -ceq 'PASS') `
        'An exact originally-unset performance property was rejected.'
    $tests.Add('performance-lease-unset-original-supported')
    $runManifest.PerformanceLevelLease.OriginalCpuLevelSet = $true
    $runManifest.PerformanceLevelLease.OriginalCpuLevel = 2
    Save-EvidenceFiles

    $runManifest.PerformanceLevelLease.RefreshPropertiesModified = $true
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A campaign claiming refresh-property mutation was accepted.'
    $tests.Add('performance-lease-scope-tamper-rejected')
    $runManifest.PerformanceLevelLease.RefreshPropertiesModified = $false
    Save-EvidenceFiles

    $reportFixtures['A1'].Protocol.PerformanceLevelLease.VerifiedBeforeWarmup = $false
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A raw report without pre-warmup 4/4 verification was accepted.'
    $tests.Add('performance-lease-report-tamper-rejected')
    $reportFixtures['A1'].Protocol.PerformanceLevelLease.VerifiedBeforeWarmup = $true
    Save-EvidenceFiles

    $originalPairHarnessSha = [string]$runManifest.ProducerLineage.Files[1].Sha256
    $runManifest.ProducerLineage.Files[1].Sha256 = '0' * 64
    $runManifest.ProducerLineage.DigestSha256 = `
        Get-V71ProducerLineageDigest @($runManifest.ProducerLineage.Files)
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A self-consistent manifest lineage with a mutated helper was accepted.'
    $tests.Add('manifest-helper-lineage-tamper-rejected')
    $runManifest.ProducerLineage.Files[1].Sha256 = $originalPairHarnessSha
    $runManifest.ProducerLineage.DigestSha256 = `
        Get-V71ProducerLineageDigest @($runManifest.ProducerLineage.Files)
    Save-EvidenceFiles

    $originalReportLineage = $reportFixtures['A1'].Protocol.ProducerLineage
    $tamperedReportLineage = $originalReportLineage | ConvertTo-Json -Depth 8 |
        ConvertFrom-Json
    $tamperedReportLineage.Files[2].Sha256 = '1' * 64
    $tamperedReportLineage.DigestSha256 = `
        Get-V71ProducerLineageDigest @($tamperedReportLineage.Files)
    $reportFixtures['A1'].Protocol.ProducerLineage = $tamperedReportLineage
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A re-locked raw report from a different helper closure was accepted.'
    $tests.Add('raw-report-helper-lineage-tamper-rejected')
    $reportFixtures['A1'].Protocol.ProducerLineage = $originalReportLineage
    Save-EvidenceFiles

    $originalComparisonLineageSha = [string]$comparison.ProducerLineageSha256
    $comparison.ProducerLineageSha256 = '2' * 64
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A comparison detached from the run producer lineage was accepted.'
    $tests.Add('comparison-lineage-tamper-rejected')
    $comparison.ProducerLineageSha256 = $originalComparisonLineageSha
    Save-EvidenceFiles

    $legacyFirst = New-AcceptanceManifest
    $legacyFirst.memorySoaks[0].producerSha256 = 'F' * 64
    $memoryContract.soaks[0].producerSha256 = 'F' * 64
    Write-Json $memoryContract $memoryContractPath
    $legacyFirst.memoryRuntimeContract.receiptSha256 = `
        Get-V71FileSha256 $memoryContractPath
    $legacyReceipt = Invoke-FixtureGate $legacyFirst
    Assert-Test ($legacyReceipt.Result -ceq 'PASS' -and
        $legacyReceipt.MemorySoakProducerSha256[0] -ceq ('F' * 64)) `
        'The reviewed, timeline-bound legacy producer was rejected for soak 1.'
    $tests.Add('legacy-producer-round-one-only')
    Save-EvidenceFiles

    $legacySecond = New-AcceptanceManifest
    $legacySecond.memorySoaks[1].producerSha256 = 'F' * 64
    $memoryContract.soaks[1].producerSha256 = 'F' * 64
    Write-Json $memoryContract $memoryContractPath
    $legacySecond.memoryRuntimeContract.receiptSha256 = `
        Get-V71FileSha256 $memoryContractPath
    Assert-Rejected { Invoke-FixtureGate $legacySecond } `
        'The legacy producer was accepted for soak 2.'
    $tests.Add('legacy-producer-round-two-rejected')
    Save-EvidenceFiles

    $soak1Capture = New-MemoryCapture '2026-09-06T07:00:00.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    Save-EvidenceFiles
    $reusedLegacy = New-AcceptanceManifest
    $reusedLegacy.memorySoaks[0].producerSha256 = 'F' * 64
    $memoryContract.soaks[0].producerSha256 = 'F' * 64
    Write-Json $memoryContract $memoryContractPath
    $reusedLegacy.memoryRuntimeContract.receiptSha256 = `
        Get-V71FileSha256 $memoryContractPath
    Assert-Rejected { Invoke-FixtureGate $reusedLegacy } `
        'The legacy producer was reused outside its trusted already-running timeline.'
    $tests.Add('legacy-producer-timeline-reuse-rejected')
    $soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    Save-EvidenceFiles

    Write-Json (New-AcceptanceManifest) $acceptancePath
    Assert-Rejected {
        Assert-V71StableAcceptanceEvidence `
            -ManifestPath $acceptancePath `
            -WorkspaceRoot $tempRoot `
            -MemorySamplerPath $memoryProducer `
            -PerformanceHarnessPath $performanceProducer `
            -LifecycleHarnessPath $lifecycleProducer
    } 'The production gate accepted self-declared unreviewed producer hashes.'
    $tests.Add('production-producers-pinned')

    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest 'PENDING_EVIDENCE') } `
        'A pending manifest was accepted.'
    $tests.Add('pending-rejected')

    $locked = New-AcceptanceManifest
    [IO.File]::AppendAllText($soak1Path, " `n")
    Assert-Rejected { Invoke-FixtureGate $locked } 'A post-lock summary mutation was accepted.'
    $tests.Add('summary-hash-tamper-rejected')

    $soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    $soak1Samples[18].totalPssKib += 262144
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A re-locked raw capture inconsistent with its summary was accepted.'
    $tests.Add('raw-memory-recompute-rejected')

    $soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    $soak1.maxPssMib = $null
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A null memory metric was accepted as zero.'
    $tests.Add('null-memory-metric-rejected')

    $soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    $soak1Samples[4].javaHeapKib = '524288'
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A string-encoded memory metric was accepted as a JSON number.'
    $tests.Add('memory-metric-type-rejected')

    $soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    $soak1.acceptance.passed = $false
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A memory summary with passed=false was accepted.'
    $tests.Add('failed-soak-rejected')

    $soak1Capture = New-MemoryCapture '2026-09-06T06:16:23.0000000+00:00' 111 2000000
    $soak1 = $soak1Capture.Summary
    $soak1Samples = $soak1Capture.Samples
    $reportFixtures['A1'].GuardrailsPass = $false
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A re-locked raw A/B report inconsistent with comparison.json was accepted.'
    $tests.Add('raw-performance-reaggregation-rejected')

    $reportFixtures['A1'].GuardrailsPass = $true
    $comparison.PerformanceGatePassed = $false
    $comparison.Result = 'FAIL_RC3_PERFORMANCE_GATE'
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A failed A/B comparison was accepted.'
    $tests.Add('failed-performance-rejected')

    $comparison.PerformanceGatePassed = $true
    $comparison.Result = 'PASS_RC3_NO_PERSISTENT_REGRESSION'
    $manual.status = 'PENDING_USER_CONFIRMATION'
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A pending manual receipt was accepted.'
    $tests.Add('pending-manual-rejected')

    $manual.status = 'PASS_CONFIRMED_BY_USER'
    $manual.confirmation.userQuote = $null
    Save-EvidenceFiles
    Assert-Rejected { Invoke-FixtureGate (New-AcceptanceManifest) } `
        'A manual receipt without the explicit user quote was accepted.'
    $tests.Add('missing-manual-quote-rejected')

    $manual.confirmation.userQuote = 'I tested every listed interaction on this exact Lab build and all passed.'
    Save-EvidenceFiles
    $duplicate = New-AcceptanceManifest
    $duplicate.memorySoaks[1].summaryPath = $duplicate.memorySoaks[0].summaryPath
    $duplicate.memorySoaks[1].summarySha256 = $duplicate.memorySoaks[0].summarySha256
    $duplicate.memorySoaks[1].samplesPath = $duplicate.memorySoaks[0].samplesPath
    $duplicate.memorySoaks[1].samplesSha256 = $duplicate.memorySoaks[0].samplesSha256
    Assert-Rejected { Invoke-FixtureGate $duplicate } 'One soak reused twice was accepted.'
    $tests.Add('duplicate-soak-rejected')

    $badProducer = New-AcceptanceManifest
    $badProducer.producerScripts.memorySoakSha256 = '0' * 64
    Assert-Rejected { Invoke-FixtureGate $badProducer } 'Producer drift was accepted.'
    $tests.Add('producer-drift-rejected')

    $badPath = New-AcceptanceManifest
    $badPath.manual.receiptPath = 'artifacts/acceptance/../acceptance/v71-manual-vr-receipt.json'
    Assert-Rejected { Invoke-FixtureGate $badPath } 'Evidence path traversal was accepted.'
    $tests.Add('traversal-rejected')

    [pscustomobject]@{
        Result = 'PASS'
        TestsPassed = $tests.Count
        Tests = @($tests)
        HostOnly = $true
        DeviceInvocations = 0
        ManualReceiptGenerated = $false
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = [IO.Path]::GetFullPath($tempRoot)
        Assert-Test ($resolved.StartsWith($canonicalTemp, [StringComparison]::OrdinalIgnoreCase)) `
            'Unsafe evidence-test cleanup.'
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
