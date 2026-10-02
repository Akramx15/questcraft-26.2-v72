<#
.SYNOPSIS
Summarizes the bounded v71 Lab GC heap log without contacting a device.

.DESCRIPTION
Reads gc-heap.log plus numeric rotation siblings (gc-heap.log.0, .1, ...),
then emits aggregate-only JSON. It never invokes ADB and does not emit input
paths, absolute timestamps, PIDs, raw log lines, account data, world names, or
server data.

The GC log uses JVM uptime. A samples.jsonl file can be correlated when each
sample has jvmUptimeSeconds/processUptimeSeconds, or when
-SampleZeroJvmUptimeSeconds maps samples elapsedMinutes=0 to JVM uptime.

For G1, post-GC "used" approximates the retained Java live set and "total" is
the committed Java heap. Flat post-GC heap with rising PSS points outside the
Java heap; rising post-GC used/committed values point toward Java pressure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $GcHeapLogPath,

    [string] $SamplesJsonlPath,

    [Nullable[double]] $SampleZeroJvmUptimeSeconds,

    [ValidateRange(1, 900)]
    [int] $MaxCorrelationGapSeconds = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Convert-ToMiB {
    param(
        [Parameter(Mandatory = $true)][double] $Value,
        [Parameter(Mandatory = $true)][string] $Unit
    )
    switch ($Unit.ToUpperInvariant()) {
        'B' { return $Value / 1MB }
        'K' { return $Value / 1024.0 }
        'M' { return $Value }
        'G' { return $Value * 1024.0 }
        default { throw "Unsupported heap unit '$Unit'." }
    }
}

function Round-OrNull {
    param($Value, [int] $Digits = 4)
    if ($null -eq $Value) { return $null }
    return [Math]::Round([double]$Value, $Digits,
        [MidpointRounding]::AwayFromZero)
}

function Get-LinearSlopePerMinute {
    param(
        [object[]] $Points,
        [Parameter(Mandatory = $true)][string] $ValueProperty
    )
    $items = @($Points)
    if ($items.Count -lt 2) { return $null }

    $origin = [double]$items[0].TimeSeconds
    $sumX = 0.0
    $sumY = 0.0
    foreach ($point in $items) {
        $sumX += ([double]$point.TimeSeconds - $origin) / 60.0
        $sumY += [double]$point.$ValueProperty
    }
    $meanX = $sumX / $items.Count
    $meanY = $sumY / $items.Count
    $numerator = 0.0
    $denominator = 0.0
    foreach ($point in $items) {
        $x = (([double]$point.TimeSeconds - $origin) / 60.0) - $meanX
        $y = [double]$point.$ValueProperty - $meanY
        $numerator += $x * $y
        $denominator += $x * $x
    }
    if ($denominator -le 0.0) { return $null }
    return $numerator / $denominator
}

function Get-PearsonCorrelation {
    param(
        [object[]] $Points,
        [Parameter(Mandatory = $true)][string] $XProperty,
        [Parameter(Mandatory = $true)][string] $YProperty
    )
    $items = @($Points)
    if ($items.Count -lt 3) { return $null }

    $sumX = 0.0
    $sumY = 0.0
    foreach ($point in $items) {
        $sumX += [double]$point.$XProperty
        $sumY += [double]$point.$YProperty
    }
    $meanX = $sumX / $items.Count
    $meanY = $sumY / $items.Count
    $covariance = 0.0
    $varianceX = 0.0
    $varianceY = 0.0
    foreach ($point in $items) {
        $dx = [double]$point.$XProperty - $meanX
        $dy = [double]$point.$YProperty - $meanY
        $covariance += $dx * $dy
        $varianceX += $dx * $dx
        $varianceY += $dy * $dy
    }
    if ($varianceX -le 0.0 -or $varianceY -le 0.0) { return $null }
    return $covariance / [Math]::Sqrt($varianceX * $varianceY)
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-HeapSummary {
    param([object[]] $Events)
    $items = @($Events | Sort-Object TimeSeconds, Sequence)
    if ($items.Count -eq 0) {
        return [ordered]@{
            available = $false
            eventCount = 0
            durationMinutes = $null
            firstUsedMiB = $null
            lastUsedMiB = $null
            maxUsedMiB = $null
            usedDeltaMiB = $null
            usedSlopeMiBPerMinute = $null
            firstCommittedMiB = $null
            lastCommittedMiB = $null
            maxCommittedMiB = $null
            committedDeltaMiB = $null
            committedSlopeMiBPerMinute = $null
        }
    }

    $first = $items[0]
    $last = $items[$items.Count - 1]
    $maxUsed = ($items | Measure-Object -Property UsedMiB -Maximum).Maximum
    $maxCommitted = ($items | Measure-Object -Property CommittedMiB -Maximum).Maximum
    return [ordered]@{
        available = $true
        eventCount = $items.Count
        durationMinutes = Round-OrNull (([double]$last.TimeSeconds -
                [double]$first.TimeSeconds) / 60.0)
        firstUsedMiB = Round-OrNull $first.UsedMiB
        lastUsedMiB = Round-OrNull $last.UsedMiB
        maxUsedMiB = Round-OrNull $maxUsed
        usedDeltaMiB = Round-OrNull ([double]$last.UsedMiB - [double]$first.UsedMiB)
        usedSlopeMiBPerMinute = Round-OrNull (Get-LinearSlopePerMinute $items 'UsedMiB')
        firstCommittedMiB = Round-OrNull $first.CommittedMiB
        lastCommittedMiB = Round-OrNull $last.CommittedMiB
        maxCommittedMiB = Round-OrNull $maxCommitted
        committedDeltaMiB = Round-OrNull (
            [double]$last.CommittedMiB - [double]$first.CommittedMiB)
        committedSlopeMiBPerMinute = Round-OrNull (
            Get-LinearSlopePerMinute $items 'CommittedMiB')
    }
}

function New-RegionTrend {
    param(
        [object[]] $Events,
        $RegionSizeMiB
    )
    $items = @($Events | Sort-Object TimeSeconds, Sequence)
    if ($items.Count -eq 0) {
        return [ordered]@{
            available = $false
            observationCount = 0
            firstRegions = $null
            lastRegions = $null
            maxRegions = $null
            deltaRegions = $null
            slopeRegionsPerMinute = $null
            firstMiB = $null
            lastMiB = $null
            maxMiB = $null
            slopeMiBPerMinute = $null
        }
    }

    $first = $items[0]
    $last = $items[$items.Count - 1]
    $maxRegions = [double](($items | Measure-Object -Property Regions -Maximum).Maximum)
    $slope = Get-LinearSlopePerMinute $items 'Regions'
    $hasRegionSize = $null -ne $RegionSizeMiB
    return [ordered]@{
        available = $true
        observationCount = $items.Count
        firstRegions = [int]$first.Regions
        lastRegions = [int]$last.Regions
        maxRegions = [int]$maxRegions
        deltaRegions = [int]$last.Regions - [int]$first.Regions
        slopeRegionsPerMinute = Round-OrNull $slope
        firstMiB = if ($hasRegionSize) {
            Round-OrNull ([double]$first.Regions * [double]$RegionSizeMiB)
        } else { $null }
        lastMiB = if ($hasRegionSize) {
            Round-OrNull ([double]$last.Regions * [double]$RegionSizeMiB)
        } else { $null }
        maxMiB = if ($hasRegionSize) {
            Round-OrNull ($maxRegions * [double]$RegionSizeMiB)
        } else { $null }
        slopeMiBPerMinute = if ($hasRegionSize -and $null -ne $slope) {
            Round-OrNull ([double]$slope * [double]$RegionSizeMiB)
        } else { $null }
    }
}

$baseLog = Get-Item -LiteralPath $GcHeapLogPath -ErrorAction Stop
if ($baseLog.PSIsContainer) { throw 'GcHeapLogPath must name a file.' }
$rotationPattern = '^' + [Regex]::Escape($baseLog.Name) + '(?:\.[0-9]+)?$'
$logFiles = @(Get-ChildItem -LiteralPath $baseLog.DirectoryName -File |
        Where-Object { $_.Name -match $rotationPattern })
if ($logFiles.Count -eq 0) { throw 'No GC heap log files were found.' }

$records = New-Object 'System.Collections.Generic.List[object]'
$sequence = 0
foreach ($logFile in $logFiles) {
    foreach ($line in (Get-Content -LiteralPath $logFile.FullName)) {
        $sequence++
        if ($line -match '^\[(?<uptime>[0-9]+(?:\.[0-9]+)?)s\]') {
            $records.Add([pscustomobject]@{
                TimeSeconds = [double]$Matches['uptime']
                Sequence = $sequence
                Line = $line
            })
        }
    }
}
$orderedRecords = @($records | Sort-Object TimeSeconds, Sequence)

$phaseByGc = @{}
$heapEvents = New-Object 'System.Collections.Generic.List[object]'
$heapEventKeys = New-Object 'System.Collections.Generic.HashSet[string]'
$oldByGc = @{}
$humongousByGc = @{}
$regionSizeMiB = $null
$minimumHeapMiB = $null
$initialHeapMiB = $null
$maximumHeapMiB = $null

foreach ($record in $orderedRecords) {
    $line = [string]$record.Line
    if ($line -match 'Minimum heap\s+(?<minimum>[0-9]+)\s+Initial heap\s+' +
            '(?<initial>[0-9]+)\s+Maximum heap\s+(?<maximum>[0-9]+)') {
        $minimumHeapMiB = [double]$Matches['minimum'] / 1MB
        $initialHeapMiB = [double]$Matches['initial'] / 1MB
        $maximumHeapMiB = [double]$Matches['maximum'] / 1MB
    }
    if ($line -match '(?:Heap\s+)?region size:?\s*' +
            '(?<value>[0-9]+(?:\.[0-9]+)?)(?<unit>[KMGB])') {
        $regionSizeMiB = Convert-ToMiB ([double]$Matches['value']) $Matches['unit']
    }
    if ($line -match 'GC\((?<gc>[0-9]+)\)\s+Heap before GC') {
        $phaseByGc[$Matches['gc']] = 'before'
        continue
    }
    if ($line -match 'GC\((?<gc>[0-9]+)\)\s+Heap after GC') {
        $phaseByGc[$Matches['gc']] = 'after'
        continue
    }
    if ($line -match 'GC\((?<gc>[0-9]+)\)\s+.*?\bheap\s+total\s+' +
            '(?:reserved\s+[0-9]+(?:\.[0-9]+)?[KMGB],\s+committed\s+)?' +
            '(?<total>[0-9]+(?:\.[0-9]+)?)(?<totalUnit>[KMGB]),\s+used\s+' +
            '(?<used>[0-9]+(?:\.[0-9]+)?)(?<usedUnit>[KMGB])') {
        $gc = $Matches['gc']
        if ($phaseByGc.ContainsKey($gc) -and $phaseByGc[$gc] -eq 'after') {
            $committedMiB = Convert-ToMiB ([double]$Matches['total']) $Matches['totalUnit']
            $usedMiB = Convert-ToMiB ([double]$Matches['used']) $Matches['usedUnit']
            $key = $gc + '|' + $record.TimeSeconds + '|' + $committedMiB + '|' + $usedMiB
            if ($heapEventKeys.Add($key)) {
                $heapEvents.Add([pscustomobject]@{
                    TimeSeconds = [double]$record.TimeSeconds
                    Sequence = [int]$record.Sequence
                    Gc = [int]$gc
                    UsedMiB = $usedMiB
                    CommittedMiB = $committedMiB
                })
            }
        }
        continue
    }
    if ($line -match 'GC\((?<gc>[0-9]+)\)\s+Old regions:\s*[0-9]+->(?<after>[0-9]+)') {
        $oldByGc[$Matches['gc']] = [pscustomobject]@{
            TimeSeconds = [double]$record.TimeSeconds
            Sequence = [int]$record.Sequence
            Regions = [int]$Matches['after']
        }
        continue
    }
    if ($line -match 'GC\((?<gc>[0-9]+)\)\s+Humongous regions:\s+' +
            '[0-9]+->(?<after>[0-9]+)') {
        $humongousByGc[$Matches['gc']] = [pscustomobject]@{
            TimeSeconds = [double]$record.TimeSeconds
            Sequence = [int]$record.Sequence
            Regions = [int]$Matches['after']
        }
    }
}

$heapItems = @($heapEvents | Sort-Object TimeSeconds, Sequence)
$sampleSummary = [ordered]@{
    requested = -not [string]::IsNullOrWhiteSpace($SamplesJsonlPath)
    sampleCount = 0
    alignedSampleCount = 0
    firstPssMiB = $null
    lastPssMiB = $null
    maxPssMiB = $null
    pssDeltaMiB = $null
    pssSlopeMiBPerMinute = $null
}
$correlation = [ordered]@{
    status = if ($sampleSummary.requested) { 'not-aligned' } else { 'not-requested' }
    pairedSampleCount = 0
    maximumPairGapSeconds = $null
    pssVsPostGcUsedPearson = $null
    pssVsPostGcCommittedPearson = $null
}

if ($sampleSummary.requested) {
    if (-not (Test-Path -LiteralPath $SamplesJsonlPath -PathType Leaf)) {
        throw 'SamplesJsonlPath does not name a file.'
    }
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $lineNumber = 0
    $hasOffset = $PSBoundParameters.ContainsKey('SampleZeroJvmUptimeSeconds')
    foreach ($line in (Get-Content -LiteralPath $SamplesJsonlPath)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $sample = $line | ConvertFrom-Json }
        catch { throw "Samples JSONL contains invalid JSON at line $lineNumber." }

        $pssKib = Get-PropertyValue $sample 'totalPssKib'
        $elapsedMinutes = Get-PropertyValue $sample 'elapsedMinutes'
        if ($null -eq $pssKib -or $null -eq $elapsedMinutes) { continue }

        $jvmUptime = Get-PropertyValue $sample 'jvmUptimeSeconds'
        if ($null -eq $jvmUptime) {
            $jvmUptime = Get-PropertyValue $sample 'processUptimeSeconds'
        }
        if ($null -eq $jvmUptime -and $hasOffset) {
            $jvmUptime = [double]$SampleZeroJvmUptimeSeconds +
                    ([double]$elapsedMinutes * 60.0)
        }
        $samples.Add([pscustomobject]@{
            TimeSeconds = if ($null -eq $jvmUptime) { $null } else { [double]$jvmUptime }
            ElapsedMinutes = [double]$elapsedMinutes
            PssMiB = [double]$pssKib / 1024.0
        })
    }

    $sampleItems = @($samples | Sort-Object ElapsedMinutes)
    $sampleSummary.sampleCount = $sampleItems.Count
    if ($sampleItems.Count -gt 0) {
        $sampleSummary.firstPssMiB = Round-OrNull $sampleItems[0].PssMiB
        $sampleSummary.lastPssMiB = Round-OrNull $sampleItems[$sampleItems.Count - 1].PssMiB
        $sampleSummary.maxPssMiB = Round-OrNull (
            ($sampleItems | Measure-Object -Property PssMiB -Maximum).Maximum)
        $sampleSummary.pssDeltaMiB = Round-OrNull (
            [double]$sampleItems[$sampleItems.Count - 1].PssMiB -
                    [double]$sampleItems[0].PssMiB)
        $pssPoints = @($sampleItems | ForEach-Object {
            [pscustomobject]@{
                TimeSeconds = [double]$_.ElapsedMinutes * 60.0
                PssMiB = [double]$_.PssMiB
            }
        })
        $sampleSummary.pssSlopeMiBPerMinute = Round-OrNull (
            Get-LinearSlopePerMinute $pssPoints 'PssMiB')
    }

    $alignedSamples = @($sampleItems | Where-Object { $null -ne $_.TimeSeconds })
    $sampleSummary.alignedSampleCount = $alignedSamples.Count
    if ($alignedSamples.Count -gt 0 -and $heapItems.Count -gt 0) {
        $pairs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($sample in $alignedSamples) {
            $nearest = $null
            $nearestGap = [double]::PositiveInfinity
            foreach ($heap in $heapItems) {
                $gap = [Math]::Abs([double]$heap.TimeSeconds - [double]$sample.TimeSeconds)
                if ($gap -lt $nearestGap) {
                    $nearest = $heap
                    $nearestGap = $gap
                }
            }
            if ($null -ne $nearest -and $nearestGap -le $MaxCorrelationGapSeconds) {
                $pairs.Add([pscustomobject]@{
                    PssMiB = [double]$sample.PssMiB
                    UsedMiB = [double]$nearest.UsedMiB
                    CommittedMiB = [double]$nearest.CommittedMiB
                    GapSeconds = $nearestGap
                })
            }
        }

        $pairItems = @($pairs | ForEach-Object { $_ })
        $correlation.pairedSampleCount = $pairItems.Count
        if ($pairItems.Count -gt 0) {
            $correlation.maximumPairGapSeconds = Round-OrNull (
                ($pairItems | Measure-Object -Property GapSeconds -Maximum).Maximum)
        }
        if ($pairItems.Count -ge 3) {
            $correlation.status = 'aligned'
            $correlation.pssVsPostGcUsedPearson = Round-OrNull (
                Get-PearsonCorrelation $pairItems 'PssMiB' 'UsedMiB') 6
            $correlation.pssVsPostGcCommittedPearson = Round-OrNull (
                Get-PearsonCorrelation $pairItems 'PssMiB' 'CommittedMiB') 6
        } else {
            $correlation.status = 'insufficient-pairs'
        }
    } elseif ($alignedSamples.Count -gt 0) {
        $correlation.status = 'no-post-gc-events'
    }
}

$result = [ordered]@{
    schemaVersion = 1
    aggregateOnly = $true
    rotatedLogFileCount = $logFiles.Count
    configuredHeap = [ordered]@{
        minimumMiB = Round-OrNull $minimumHeapMiB
        initialMiB = Round-OrNull $initialHeapMiB
        maximumMiB = Round-OrNull $maximumHeapMiB
    }
    postGcHeap = New-HeapSummary $heapItems
    regionSizeMiB = Round-OrNull $regionSizeMiB
    oldRegions = New-RegionTrend @($oldByGc.Values) $regionSizeMiB
    humongousRegions = New-RegionTrend @($humongousByGc.Values) $regionSizeMiB
    memorySamples = $sampleSummary
    pssCorrelation = $correlation
    interpretation = [ordered]@{
        postGcUsedRising = 'Java retention or allocation pressure is increasing.'
        postGcFlatWhilePssRises = 'Growth is outside Java heap: inspect native, graphics, or mapped memory.'
        committedNearMaximum = 'The JVM has committed most of its configured heap ceiling.'
    }
}

$result | ConvertTo-Json -Depth 8
