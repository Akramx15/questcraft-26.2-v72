#requires -Version 7.0
<#
.SYNOPSIS
Host-only self-test for the RC6.2 paired memory-soak postprocessor.

.DESCRIPTION
Builds synthetic completed-run fixtures beneath the operating-system temporary
directory. It does not read soak artifacts and does not invoke a device tool.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestPrefix = '[V71_RC6_2_MEMORY_PAIR_SELF_TEST]'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:AnalyzerPath = Join-Path $PSScriptRoot `
    'analyze-v71-memory-soak-pair-rc62.ps1'
$script:Package = 'com.qcxr.qcxr.canary262'
$script:AbsoluteLimitMib = 2457.6

function Assert-True(
    [bool] $Condition,
    [Parameter(Mandatory)][string] $Message
) {
    if (-not $Condition) { throw "$($script:TestPrefix) $Message" }
}

function Convert-ToUtcText([Parameter(Mandatory)][DateTimeOffset] $Value) {
    return $Value.UtcDateTime.ToString('o')
}

function Write-Utf8NoBom(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Text
) {
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-RawSlope(
    [Parameter(Mandatory)][object[]] $Rows,
    [Parameter(Mandatory)][string] $Field
) {
    $window = @($Rows | Where-Object elapsedMinutes -ge 15.0)
    $meanX = ($window | Measure-Object elapsedMinutes -Average).Average
    $meanY = ($window | ForEach-Object { [double]$_.$Field / 1024.0 } |
        Measure-Object -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($row in $window) {
        $dx = [double]$row.elapsedMinutes - [double]$meanX
        $dy = ([double]$row.$Field / 1024.0) - [double]$meanY
        $numerator += $dx * $dy
        $denominator += $dx * $dx
    }
    return $numerator / $denominator
}

function Get-RoundedMaximumMib(
    [Parameter(Mandatory)][object[]] $Rows,
    [Parameter(Mandatory)][string] $Field
) {
    $maximum = ($Rows | ForEach-Object { [double]$_.$Field } |
        Measure-Object -Maximum).Maximum
    return [math]::Round([double]$maximum / 1024.0, 3)
}

function Get-RoundedMinimumMib(
    [Parameter(Mandatory)][object[]] $Rows,
    [Parameter(Mandatory)][string] $Field
) {
    $minimum = ($Rows | ForEach-Object { [double]$_.$Field } |
        Measure-Object -Minimum).Minimum
    return [math]::Round([double]$minimum / 1024.0, 3)
}

function New-Provenance([Parameter(Mandatory)][DateTimeOffset] $VerifiedUtc) {
    return [ordered]@{
        schemaVersion = 1
        verifiedUtc = Convert-ToUtcText $VerifiedUtc
        installedIdentityMatched = $true
        baseApkMatched = $true
        persistentCoreMatched = $true
        persistentVeqMatched = $true
        allMatched = $true
    }
}

function Add-GameLogReceiptFields(
    [Parameter(Mandatory)][Collections.Specialized.OrderedDictionary] $Receipt,
    [int64] $ObservedEpoch
) {
    $Receipt.expectedGameLogPathMatched = $true
    $Receipt.expectedGameLogRegularAndNonEmpty = $true
    $Receipt.expectedGameLogSameFile = $true
    $Receipt.expectedGameLogTemporallyBoundToProcess = $true
    $Receipt.expectedGameLogFresh = $true
    $Receipt.expectedMinecraftVersionObserved = $true
    $Receipt.expectedVivecraftVersionObserved = $true
    $Receipt.expectedVeqVersionObserved = $true
    $Receipt.expectedGameLogModifiedEpochSeconds = $ObservedEpoch - 5
    $Receipt.expectedGameLogObservedDeviceEpochSeconds = $ObservedEpoch
}

function New-RuntimeBinding(
    [Parameter(Mandatory)][DateTimeOffset] $StartedUtc,
    [int] $ProcessId,
    [int64] $ProcessStartTicks,
    [Parameter(Mandatory)][string] $ProducerSha256
) {
    $processStartEpoch = $StartedUtc.ToUnixTimeSeconds() - 10
    $startObservedEpoch = $StartedUtc.ToUnixTimeSeconds()
    $finalObservedUtc = $StartedUtc.AddMinutes(90).AddSeconds(1)
    $finalObservedEpoch = $finalObservedUtc.ToUnixTimeSeconds()

    $start = [ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_MEMORY_SOAK_RUNTIME_START'
        result = 'PASS'
        observedUtc = Convert-ToUtcText $StartedUtc
        pid = $ProcessId
        processStartTicks = $ProcessStartTicks
        producerSha256 = $ProducerSha256
        processStartEpochSeconds = $processStartEpoch
        exactPidAlive = $true
        gameJvmAlive = $true
        provenanceMatched = $true
        exactJvmMemoryLineObserved = $true
        xmsMiB = 512
        xmxMiB = 1536
        xmxSource = 'auto'
        jvmMemoryLineCount = 1
        launcherLogSizeBytes = 4096
        launcherLogModifiedEpochSeconds = $processStartEpoch
        launcherLogTemporallyBoundToProcess = $true
        launcherResourceReleaseAppliedObserved = $true
        launcherReleaseAppliedMarkerCount = 1
        launcherReleaseDegradedMarkerCount = 0
        launcherAppliedMarkerEpochSeconds = $processStartEpoch
        launcherMarkerTemporallyBoundToProcess = $true
        runtimeFenceBeforeStartProvenance = $true
        runtimeFenceAfterStartProvenance = $true
    }
    Add-GameLogReceiptFields $start $startObservedEpoch

    $final = [ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_MEMORY_SOAK_RUNTIME_FINAL'
        result = 'PASS'
        observedUtc = Convert-ToUtcText $finalObservedUtc
        pid = $ProcessId
        processStartTicks = $ProcessStartTicks
        processStartEpochSeconds = $processStartEpoch
        sameProcessIncarnation = $true
        exactPidAlive = $true
        gameJvmAlive = $true
        provenanceMatched = $true
        startJvmMemoryObservationCarriedForward = $true
        startLauncherMarkerCarriedForward = $true
        finalLogcatMarkerRequired = $false
        runtimeFenceBeforeFinalProvenance = $true
        runtimeFenceAfterFinalProvenance = $true
    }
    Add-GameLogReceiptFields $final $finalObservedEpoch

    return [ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_MEMORY_SOAK_RUNTIME_BINDING'
        result = 'PASS'
        start = $start
        final = $final
        evidenceBoundary = [ordered]@{
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
            rawLogsPersisted = $false
            logSnippetsPersisted = $false
            deviceSerialPersisted = $false
            accountDataPersisted = $false
            hostAbsolutePathsPersisted = $false
        }
    }
}

function New-RunFixture(
    [Parameter(Mandatory)][string] $Root,
    [int] $Number,
    [Parameter(Mandatory)][DateTimeOffset] $StartedUtc,
    [int64] $PssBaseKib,
    [int64] $PssStepKib = 2048,
    [int64] $VmRssBaseKib = (1800 * 1024),
    [int64] $VmRssStepKib = 1536,
    [int64] $MemAvailableBaseKib = (1800 * 1024),
    [int64] $MemAvailableStepKib = -1024
) {
    $directory = Join-Path $Root ("run-$Number")
    $null = New-Item -ItemType Directory -Path $directory
    $processId = 4200 + $Number
    $ticks = [int64](700000000 + ($Number * 100000))
    $rows = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 19; $index++) {
        $elapsed = [double]($index * 5)
        $timestamp = $StartedUtc.AddMinutes($elapsed)
        $observedEpoch = $timestamp.ToUnixTimeSeconds()
        $row = [ordered]@{
            timestampUtc = Convert-ToUtcText $timestamp
            elapsedMinutes = $elapsed
            pid = $processId
            pidStable = $true
            focus = 'focused'
            gameJvmAlive = $true
            expectedGameLogPathMatched = $true
            expectedGameLogRegularAndNonEmpty = $true
            expectedGameLogSameFile = $true
            expectedGameLogTemporallyBoundToProcess = $true
            expectedGameLogFresh = $true
            expectedGameLogModifiedEpochSeconds = $observedEpoch - 5
            expectedGameLogObservedDeviceEpochSeconds = $observedEpoch
            totalPssKib = $PssBaseKib + ($index * $PssStepKib)
            totalRssKib = $VmRssBaseKib + (128 * 1024) + ($index * $VmRssStepKib)
            javaHeapKib = (400 * 1024) + ($index * 128)
            nativeHeapKib = (600 * 1024) + ($index * 512)
            graphicsKib = (900 * 1024) + ($index * 256)
            vmRssKib = $VmRssBaseKib + ($index * $VmRssStepKib)
            vmSwapKib = (64 * 1024) + ($index * 32)
            memAvailableKib = $MemAvailableBaseKib + ($index * $MemAvailableStepKib)
            swapFreeKib = (1024 * 1024) - ($index * 64)
            batteryTemperatureC = 40.0 + ($index / 10.0)
            batteryStatusCode = 2
            thermalStatusCode = 1
            thermalStatusName = 'light'
            configuredMaxBatteryTemperatureC = 47.0
            configuredMaxThermalStatus = 2
            thermalLimitExceeded = $false
            thermalSafetyStopPerformed = $false
        }
        $rows.Add([pscustomobject]$row)
    }
    $rowArray = $rows.ToArray()
    $postWarmSlope = [math]::Round((Get-RawSlope $rowArray 'totalPssKib'), 3)
    $lastThirty = @($rowArray | Where-Object elapsedMinutes -ge 60.0)
    $lastThirtyGrowth = [math]::Round(
        ([double]$lastThirty[-1].totalPssKib -
            [double]$lastThirty[0].totalPssKib) / 1024.0, 3)
    $maxPss = Get-RoundedMaximumMib $rowArray 'totalPssKib'
    $maxVmRss = Get-RoundedMaximumMib $rowArray 'vmRssKib'
    $maxSwap = Get-RoundedMaximumMib $rowArray 'vmSwapKib'
    $minAvailable = Get-RoundedMinimumMib $rowArray 'memAvailableKib'
    $minSwapFree = Get-RoundedMinimumMib $rowArray 'swapFreeKib'

    $absolutePssPass = $maxPss -le $script:AbsoluteLimitMib
    $absoluteVmRssPass = $maxVmRss -le $script:AbsoluteLimitMib
    $swapPass = $maxSwap -le 512.0
    $slopePass = $postWarmSlope -le 2.0
    $lastThirtyPass = $lastThirtyGrowth -le 128.0
    $passed = $absolutePssPass -and $absoluteVmRssPass -and $swapPass -and
        $slopePass -and $lastThirtyPass

    $producerLock = Get-Content -LiteralPath (Join-Path $script:RepoRoot `
        'V71_RC6_2_EVIDENCE_PRODUCERS.lock.json') -Raw | ConvertFrom-Json
    $producerSha = [string]$producerLock.producers.memorySoakScriptSha256
    $summary = [ordered]@{
        schemaVersion = 3
        package = $script:Package
        producerSha256 = $producerSha
        provenance = New-Provenance $StartedUtc
        finalProvenance = New-Provenance $StartedUtc.AddMinutes(90)
        runtimeBinding = New-RuntimeBinding $StartedUtc $processId $ticks $producerSha
        startedUtc = Convert-ToUtcText $StartedUtc
        requestedDurationMinutes = 90
        intervalSeconds = 300
        samples = 19
        minimumExpectedSamples = 19
        completeMetricSamples = 19
        initialPid = $processId
        pidStable = $true
        focusStayedOnLab = $true
        gameJvmStayedAlive = $true
        expectedGameLogStayedFresh = $true
        maxPssMib = $maxPss
        maxRssMib = $maxVmRss
        maxProcessSwapMib = $maxSwap
        minMemAvailableMib = $minAvailable
        minSwapFreeMib = $minSwapFree
        thermalSafety = [ordered]@{
            configuredMaxBatteryTemperatureC = 47.0
            configuredMaxThermalStatus = 2
            maxBatteryTemperatureObservedC = 41.8
            maxThermalStatusObserved = 1
            limitExceeded = $false
            labSafetyStopPerformed = $false
            safetyStopInvocations = 0
            safetyStopTarget = $script:Package
            stablePackageStopped = $false
        }
        postWarmPssSlopeMibPerMinute = $postWarmSlope
        lastThirtyMinutesGrowthMib = $lastThirtyGrowth
        acceptance = [ordered]@{
            completedDuration = $true
            sampleCountComplete = $true
            allRequiredMetricsPresent = $true
            focusStayedOnLab = $true
            gameJvmStayedAlive = $true
            expectedGameLogStayedFresh = $true
            thermalLimitNeverExceeded = $true
            thermalSafetyStopNotRequired = $true
            postWarmSamplesComplete = $true
            lastThirtySamplesComplete = $true
            maxPssAtMost2457Point6Mib = $absolutePssPass
            maxRssAtMost2457Point6Mib = $absoluteVmRssPass
            processSwapAtMost512Mib = $swapPass
            slopeAtMost2MibPerMinute = $slopePass
            lastThirtyGrowthAtMost128Mib = $lastThirtyPass
            passed = $passed
        }
        thermalSafetyStopInvocations = 0
    }
    $summaryPath = Join-Path $directory 'summary.json'
    $samplesPath = Join-Path $directory 'samples.jsonl'
    Write-Utf8NoBom $summaryPath (($summary | ConvertTo-Json -Depth 20) + "`n")
    $jsonLines = @($rowArray | ForEach-Object {
            $_ | ConvertTo-Json -Depth 10 -Compress
        })
    Write-Utf8NoBom $samplesPath (($jsonLines -join "`n") + "`n")
    return [pscustomobject]@{
        Directory = $directory
        SummaryPath = $summaryPath
        SamplesPath = $samplesPath
        Summary = $summary
        Rows = $rowArray
    }
}

function Save-FixtureSummary([Parameter(Mandatory)][object] $Fixture) {
    Write-Utf8NoBom $Fixture.SummaryPath `
        (($Fixture.Summary | ConvertTo-Json -Depth 20) + "`n")
}

function Invoke-PairAnalyzer(
    [Parameter(Mandatory)][object] $First,
    [Parameter(Mandatory)][object] $Second,
    [string] $OutputPath = ''
) {
    $arguments = @{
        FirstSummaryPath = $First.SummaryPath
        FirstSamplesPath = $First.SamplesPath
        SecondSummaryPath = $Second.SummaryPath
        SecondSamplesPath = $Second.SamplesPath
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $arguments.OutputPath = $OutputPath
    }
    $output = @(& $script:AnalyzerPath @arguments)
    Assert-True ($output.Count -eq 1) `
        "Analyzer emitted $($output.Count) pipeline objects instead of one report."
    return $output[0]
}

function Assert-AnalyzerRejects(
    [Parameter(Mandatory)][object] $First,
    [Parameter(Mandatory)][object] $Second,
    [Parameter(Mandatory)][string] $Description
) {
    $threw = $false
    $message = ''
    try {
        $null = Invoke-PairAnalyzer $First $Second
    } catch {
        $threw = $true
        $message = $_.Exception.Message
    }
    Assert-True $threw "Analyzer accepted invalid fixture: $Description."
    Assert-True ($message.Contains('[V71_RC6_2_MEMORY_PAIR]')) `
        "Analyzer rejection lacked its contract prefix for: $Description."
}

$tempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('v71-rc62-memory-pair-self-test-' + [guid]::NewGuid().ToString('N'))))
$resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
Assert-True ($tempRoot.StartsWith($resolvedSystemTemp, `
        [StringComparison]::OrdinalIgnoreCase)) `
    'Synthetic fixture root escaped the operating-system temp directory.'
$null = New-Item -ItemType Directory -Path $tempRoot

try {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $script:AnalyzerPath, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'Analyzer has PowerShell parse errors.'
    $deviceCommandPattern = '(?i)(?<![a-z0-9_])(?:adb(?:\.exe)?|invoke-adb|resolve-adb)(?![a-z0-9_])'
    Assert-True (-not $ast.Extent.Text.Contains('System.Diagnostics.Process', `
            [StringComparison]::OrdinalIgnoreCase)) `
        'Analyzer contains a process-launch API.'
    Assert-True (-not [regex]::IsMatch($ast.Extent.Text, $deviceCommandPattern)) `
        'Analyzer contains a device-command token.'

    $run1 = New-RunFixture $tempRoot 1 `
        ([DateTimeOffset]::Parse('2026-01-01T00:00:00Z')) (2600 * 1024)
    $run2 = New-RunFixture $tempRoot 2 `
        ([DateTimeOffset]::Parse('2026-01-01T03:00:00Z')) (2700 * 1024) `
        -VmRssBaseKib (2500 * 1024)
    $inputHashesBefore = @(
        (Get-FileHash -LiteralPath $run1.SummaryPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $run1.SamplesPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $run2.SummaryPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $run2.SamplesPath -Algorithm SHA256).Hash)
    $outputPath = Join-Path $tempRoot 'supplementary-report.json'
    $report = Invoke-PairAnalyzer $run1 $run2 $outputPath
    $inputHashesAfter = @(
        (Get-FileHash -LiteralPath $run1.SummaryPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $run1.SamplesPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $run2.SummaryPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $run2.SamplesPath -Algorithm SHA256).Hash)
    Assert-True (($inputHashesBefore -join '|') -ceq ($inputHashesAfter -join '|')) `
        'Analyzer changed one or more input evidence files.'
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) `
        'Analyzer did not create the requested report.'
    $savedReportText = Get-Content -LiteralPath $outputPath -Raw
    $savedReport = $savedReportText | ConvertFrom-Json
    Assert-True (-not $savedReportText.Contains($tempRoot,
            [StringComparison]::OrdinalIgnoreCase)) `
        'Analyzer persisted a Host-absolute fixture path.'
    Assert-True ($report.result -ceq 'LEAK_STABILITY_PASS' -and
        $savedReport.result -ceq 'LEAK_STABILITY_PASS') `
        'Stable synthetic growth did not receive LEAK_STABILITY_PASS.'
    Assert-True ($report.originalProducerGate.result -ceq 'FAIL' -and
        $report.originalProducerGate.immutableAndUnmodified -and
        -not $report.originalProducerGate.supplementaryAnalysisOverridesResult) `
        'Original producer failure was not preserved as immutable.'
    Assert-True ($report.absolute2Point4GiBGate.result -ceq 'FAIL' -and
        $report.absolute2Point4GiBGate.failed -and
        -not $report.absolute2Point4GiBGate.supplementaryAnalysisOverridesResult) `
        'Absolute 2.4 GiB failure was hidden or overridden.'
    Assert-True ($report.runs[0].absolute2Point4GiBGate.pss.passed -eq $false -and
        $report.runs[1].absolute2Point4GiBGate.pss.passed -eq $false -and
        $report.runs[1].absolute2Point4GiBGate.vmRss.passed -eq $false) `
        'Per-run absolute PSS/VmRSS failures were not explicit.'
    Assert-True ($report.runs[0].recomputedMetrics.pss.postWarmSlopeMibPerMinute -eq 0.4 -and
        $report.runs[0].recomputedMetrics.pss.lastThirtyMinutesGrowthMib -eq 12.0 -and
        $report.runs[0].recomputedMetrics.vmRss.postWarmSlopeMibPerMinute -eq 0.3 -and
        $report.runs[0].recomputedMetrics.vmRss.lastThirtyMinutesGrowthMib -eq 9.0) `
        'Analyzer did not independently recompute the expected PSS/VmRSS trends.'
    $expectedMetricTrends = [ordered]@{
        graphics = @(0.05, 1.5)
        nativeHeap = @(0.1, 3.0)
        javaHeap = @(0.025, 0.75)
        memAvailable = @(-0.2, -6.0)
        processSwap = @(0.00625, 0.1875)
    }
    foreach ($metric in $expectedMetricTrends.Keys) {
        $metricResult = $report.runs[0].recomputedMetrics.$metric
        Assert-True ($null -ne $metricResult -and
            $metricResult.postWarmSlopeMibPerMinute -eq
                $expectedMetricTrends[$metric][0] -and
            $metricResult.lastThirtyMinutesGrowthMib -eq
                $expectedMetricTrends[$metric][1]) `
            "Analyzer did not recompute the expected '$metric' trends."
    }
    Assert-True (-not $report.supplementaryClassification.manualVisualAcceptanceClaimed -and
        -not $report.supplementaryClassification.stablePromotionAuthorized -and
        $report.evidenceBoundary.deviceCommandsInvoked -eq 0) `
        'Analyzer exceeded the Host-only supplementary evidence boundary.'

    $lowMemory = New-RunFixture $tempRoot 3 `
        ([DateTimeOffset]::Parse('2026-01-01T06:00:00Z')) (2650 * 1024) `
        -MemAvailableBaseKib (1000 * 1024) -MemAvailableStepKib -1024
    $lowMemoryReport = Invoke-PairAnalyzer $run1 $lowMemory
    Assert-True ($lowMemoryReport.result -ceq 'LEAK_STABILITY_NOT_ESTABLISHED' -and
        -not $lowMemoryReport.runs[1].supplementaryGates.memAvailableNeverBelow1GiB) `
        'Sub-1-GiB MemAvailable did not fail the supplementary classification.'

    # 10,242 KiB per five minutes is ~2.000391 MiB/min. The producer's
    # three-decimal value is 2.000 (pass), while the conservative raw comparison
    # must reject it.
    $rawBoundary = New-RunFixture $tempRoot 4 `
        ([DateTimeOffset]::Parse('2026-01-01T09:00:00Z')) (2200 * 1024) `
        -PssStepKib 10242
    $rawBoundaryReport = Invoke-PairAnalyzer $run1 $rawBoundary
    Assert-True ($rawBoundary.Summary.acceptance.slopeAtMost2MibPerMinute -and
        -not $rawBoundaryReport.runs[1].supplementaryGates.postWarmPssSlopeAtMost2MibPerMinute -and
        $rawBoundaryReport.result -ceq 'LEAK_STABILITY_NOT_ESTABLISHED') `
        'Supplementary slope comparison did not use the unrounded value.'

    $tamperedBinding = New-RunFixture $tempRoot 5 `
        ([DateTimeOffset]::Parse('2026-01-01T12:00:00Z')) (2620 * 1024)
    $tamperedBinding.Summary.runtimeBinding.final.processStartTicks++
    Save-FixtureSummary $tamperedBinding
    Assert-AnalyzerRejects $run1 $tamperedBinding 'runtime process-incarnation mismatch'

    $incomplete = New-RunFixture $tempRoot 6 `
        ([DateTimeOffset]::Parse('2026-01-01T15:00:00Z')) (2630 * 1024)
    $shortLines = @(Get-Content -LiteralPath $incomplete.SamplesPath |
        Select-Object -First 18)
    Write-Utf8NoBom $incomplete.SamplesPath (($shortLines -join "`n") + "`n")
    Assert-AnalyzerRejects $run1 $incomplete '18-row incomplete sample stream'

    Assert-AnalyzerRejects $run1 $run1 'same run reused for both required soaks'

    $tamperedAcceptance = New-RunFixture $tempRoot 7 `
        ([DateTimeOffset]::Parse('2026-01-01T18:00:00Z')) (2640 * 1024)
    $tamperedAcceptance.Summary.acceptance.passed = $true
    Save-FixtureSummary $tamperedAcceptance
    Assert-AnalyzerRejects $run1 $tamperedAcceptance `
        'producer acceptance result detached from samples'

    $tamperedIdentity = New-RunFixture $tempRoot 8 `
        ([DateTimeOffset]::Parse('2026-01-01T21:00:00Z')) (2660 * 1024)
    $tamperedIdentity.Summary.package = 'com.qcxr.qcxr.dev262'
    Save-FixtureSummary $tamperedIdentity
    Assert-AnalyzerRejects $run1 $tamperedIdentity 'forbidden Stable package identity'

    [pscustomobject][ordered]@{
        result = 'PASS'
        test = 'V71_RC6_2_MEMORY_SOAK_PAIR_HOST_SELF_TEST'
        syntheticFixturesOnly = $true
        soakArtifactPathsRead = 0
        deviceCommandsInvoked = 0
        positiveSupplementaryPassVerified = $true
        immutableOriginalFailureVerified = $true
        explicitAbsoluteGateFailureVerified = $true
        rawThresholdConservatismVerified = $true
        rejectionCasesVerified = 5
    }
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($tempRoot)
    if (Test-Path -LiteralPath $resolvedFixtureRoot) {
        Assert-True ($resolvedFixtureRoot.StartsWith($resolvedSystemTemp,
                [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedFixtureRoot).StartsWith(
                'v71-rc62-memory-pair-self-test-',
                [StringComparison]::Ordinal)) `
            'Refusing to remove an unexpected self-test path.'
        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
    }
}
