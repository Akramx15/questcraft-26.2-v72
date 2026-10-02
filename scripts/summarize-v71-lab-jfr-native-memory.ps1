<#
.SYNOPSIS
Creates privacy-preserving aggregate summaries for the bounded v71 Lab JFR.

.DESCRIPTION
This Host-only tool accepts only the fixed recording name produced by
LabJvmNativeMemoryDiagnostics and rejects recordings larger than 16 MiB. It
requires the Java 25 `jfr` command and asks that command for exactly five
aggregate memory event types. The resulting JSON and Markdown contain no raw
events, timestamps, paths, JVM arguments, system properties, stack traces, or
arbitrary Native Memory Tracking labels.

The output is deterministic for a given recording: it contains only the input
size/hash, fixed tool/schema identifiers, event counts, and numeric aggregate
statistics. Existing summaries are replaced through same-directory temporary
files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $JfrPath,

    [Parameter(Mandatory = $true)]
    [string] $OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string] $JfrToolPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$expectedRecordingName = 'quest-native-memory.jfr'
$maximumRecordingBytes = 16MB
$maximumFilteredJsonBytes = 32MB
$maximumFilteredEvents = 25000
$jsonOutputName = 'v71-lab-native-memory-summary.json'
$markdownOutputName = 'v71-lab-native-memory-summary.md'
$allowedEvents = @(
    'jdk.ResidentSetSize',
    'jdk.NativeMemoryUsage',
    'jdk.NativeMemoryUsageTotal',
    'jdk.GCHeapMemoryUsage',
    'jdk.DirectBufferStatistics'
)
$allowedEventCsv = $allowedEvents -join ','

function Get-SafeLeafFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $FailureMessage
    )

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
                (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw [InvalidOperationException]::new($FailureMessage)
        }
        return $item
    } catch {
        throw [InvalidOperationException]::new($FailureMessage)
    }
}

function Get-SafeDirectory {
    param([Parameter(Mandatory = $true)][string] $Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
                (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw [InvalidOperationException]::new('OutputDirectory is not a safe directory.')
        }
        return $item
    } catch {
        throw [InvalidOperationException]::new('OutputDirectory is not a safe directory.')
    }
}

function Get-SafeSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    } catch {
        throw [InvalidDataException]::new('The Lab recording could not be hashed safely.')
    }
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Convert-ToNonNegativeInt64 {
    param($Value)

    if ($null -eq $Value) {
        throw [InvalidDataException]::new('A required numeric event field is missing.')
    }

    $text = [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    [Int64]$parsed = 0
    if ([string]::IsNullOrEmpty($text) -or
            -not [Int64]::TryParse(
                $text,
                [Globalization.NumberStyles]::None,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed) -or
            $parsed -lt 0) {
        throw [InvalidDataException]::new('An event field is not a non-negative integer.')
    }
    return $parsed
}

function Convert-BytesToMiB {
    param([Int64] $Bytes)
    return [Math]::Round(
        ([double]$Bytes / 1MB), 4, [MidpointRounding]::AwayFromZero)
}

function New-ByteStatistics {
    param([object[]] $Values)

    $items = @($Values)
    if ($items.Count -eq 0) {
        return [ordered]@{
            available = $false
            sampleCount = 0
            firstMiB = $null
            lastMiB = $null
            minimumMiB = $null
            maximumMiB = $null
            deltaMiB = $null
        }
    }

    [Int64]$minimum = [Int64]::MaxValue
    [Int64]$maximum = 0
    foreach ($item in $items) {
        [Int64]$number = Convert-ToNonNegativeInt64 $item
        if ($number -lt $minimum) { $minimum = $number }
        if ($number -gt $maximum) { $maximum = $number }
    }
    [Int64]$first = Convert-ToNonNegativeInt64 $items[0]
    [Int64]$last = Convert-ToNonNegativeInt64 $items[$items.Count - 1]

    return [ordered]@{
        available = $true
        sampleCount = $items.Count
        firstMiB = Convert-BytesToMiB $first
        lastMiB = Convert-BytesToMiB $last
        minimumMiB = Convert-BytesToMiB $minimum
        maximumMiB = Convert-BytesToMiB $maximum
        deltaMiB = [Math]::Round(
            ([double]($last - $first) / 1MB), 4,
            [MidpointRounding]::AwayFromZero)
    }
}

function New-CountStatistics {
    param([object[]] $Values)

    $items = @($Values)
    if ($items.Count -eq 0) {
        return [ordered]@{
            available = $false
            sampleCount = 0
            first = $null
            last = $null
            minimum = $null
            maximum = $null
            delta = $null
        }
    }

    [Int64]$minimum = [Int64]::MaxValue
    [Int64]$maximum = 0
    foreach ($item in $items) {
        [Int64]$number = Convert-ToNonNegativeInt64 $item
        if ($number -lt $minimum) { $minimum = $number }
        if ($number -gt $maximum) { $maximum = $number }
    }
    [Int64]$first = Convert-ToNonNegativeInt64 $items[0]
    [Int64]$last = Convert-ToNonNegativeInt64 $items[$items.Count - 1]

    return [ordered]@{
        available = $true
        sampleCount = $items.Count
        first = $first
        last = $last
        minimum = $minimum
        maximum = $maximum
        delta = $last - $first
    }
}

function Get-SafeNmtCategory {
    param($TypeValue)

    $label = $null
    if ($TypeValue -is [string]) {
        $label = $TypeValue
    } elseif ($null -ne $TypeValue) {
        $label = Get-PropertyValue $TypeValue 'name'
    }

    switch -CaseSensitive ([string]$label) {
        'Java Heap' { return 'javaHeap' }
        'Class' { return 'class' }
        'Thread' { return 'thread' }
        'Thread Stack' { return 'threadStack' }
        'Code' { return 'code' }
        'GC' { return 'gc' }
        'GCCardSet' { return 'gcCardSet' }
        'Compiler' { return 'compiler' }
        'JVMCI' { return 'jvmci' }
        'Internal' { return 'internal' }
        'Other' { return 'other' }
        'Symbol' { return 'symbol' }
        'Native Memory Tracking' { return 'nativeMemoryTracking' }
        'Shared class space' { return 'sharedClassSpace' }
        'Arena Chunk' { return 'arenaChunk' }
        'Test' { return 'test' }
        'Tracing' { return 'tracing' }
        'Logging' { return 'logging' }
        'Statistics' { return 'statistics' }
        'Arguments' { return 'arguments' }
        'Module' { return 'module' }
        'Safepoint' { return 'safepoint' }
        'Synchronization' { return 'synchronization' }
        'Serviceability' { return 'serviceability' }
        'Metaspace' { return 'metaspace' }
        'String Deduplication' { return 'stringDeduplication' }
        'Object Monitors' { return 'objectMonitors' }
        'Unknown' { return 'unknown' }
        default { return 'unrecognized' }
    }
}

function Get-EventValues {
    param($Event)
    $values = Get-PropertyValue $Event 'values'
    if ($null -eq $values) {
        throw [InvalidDataException]::new('An allowed event has no values object.')
    }
    return $values
}

function Add-RequiredNumericValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]
        [Collections.ArrayList] $Target,
        $Values,
        [Parameter(Mandatory = $true)][string] $Name
    )
    [void]$Target.Add((Convert-ToNonNegativeInt64 (Get-PropertyValue $Values $Name)))
}

function New-EventAggregate {
    param(
        [Collections.ArrayList] $Events,
        [string[]] $ByteFields,
        [string[]] $CountFields
    )

    $result = [ordered]@{
        available = ($Events.Count -gt 0)
        eventCount = $Events.Count
    }
    foreach ($field in $ByteFields) {
        $values = New-Object Collections.ArrayList
        foreach ($event in $Events) {
            Add-RequiredNumericValue $values (Get-EventValues $event) $field
        }
        $result[$field] = New-ByteStatistics $values
    }
    foreach ($field in $CountFields) {
        $values = New-Object Collections.ArrayList
        foreach ($event in $Events) {
            Add-RequiredNumericValue $values (Get-EventValues $event) $field
        }
        $result[$field] = New-CountStatistics $values
    }
    return $result
}

function Format-ByteSummaryMarkdown {
    param(
        [Parameter(Mandatory = $true)][string] $Label,
        $Statistics
    )
    if (-not $Statistics.available) {
        return "| $Label | 0 | n/a | n/a | n/a |"
    }
    return "| $Label | $($Statistics.sampleCount) | $($Statistics.firstMiB) | " +
        "$($Statistics.lastMiB) | $($Statistics.deltaMiB) |"
}

$recording = Get-SafeLeafFile $JfrPath 'JfrPath is not a safe recording file.'
if (-not $recording.Name.Equals(
        $expectedRecordingName, [StringComparison]::OrdinalIgnoreCase)) {
    throw [InvalidDataException]::new('The input is not the fixed Lab diagnostic recording.')
}
if ($recording.Length -le 0 -or $recording.Length -gt $maximumRecordingBytes) {
    throw [InvalidDataException]::new('The Lab recording is empty or exceeds the 16 MiB limit.')
}
[Int64]$recordingLength = $recording.Length
$recordingHash = Get-SafeSha256 $recording.FullName
$output = Get-SafeDirectory $OutputDirectory
$tool = Get-SafeLeafFile $JfrToolPath 'JfrToolPath is not a safe Java 25 tool.'

$version = $null
try {
    $versionLines = @(& $tool.FullName version 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw [InvalidOperationException]::new('version failed')
    }
    $version = ($versionLines -join ' ').Trim()
} catch {
    throw [InvalidOperationException]::new('The Java 25 jfr tool could not be verified.')
}
if ($version -notmatch '^25(?:\.|\s|$)') {
    throw [InvalidOperationException]::new('The summarizer requires the Java 25 jfr tool.')
}

$filteredJson = Join-Path $output.FullName ('.jfr-filtered-' + [Guid]::NewGuid().ToString('N'))
$filteredError = Join-Path $output.FullName ('.jfr-error-' + [Guid]::NewGuid().ToString('N'))
$jsonStage = Join-Path $output.FullName ('.summary-json-' + [Guid]::NewGuid().ToString('N'))
$markdownStage = Join-Path $output.FullName ('.summary-md-' + [Guid]::NewGuid().ToString('N'))
$jsonDestination = Join-Path $output.FullName $jsonOutputName
$markdownDestination = Join-Path $output.FullName $markdownOutputName
foreach ($destination in @($jsonDestination, $markdownDestination)) {
    if (Test-Path -LiteralPath $destination) {
        [void](Get-SafeLeafFile $destination 'An existing summary output is unsafe.')
    }
}

try {
    try {
        & $tool.FullName print --json --events $allowedEventCsv `
            --stack-depth 0 $recording.FullName 2> $filteredError > $filteredJson
        if ($LASTEXITCODE -ne 0) {
            throw [InvalidOperationException]::new('print failed')
        }
    } catch {
        throw [InvalidOperationException]::new(
            'The Java 25 jfr tool could not read the bounded Lab recording.')
    }

    $filtered = Get-SafeLeafFile $filteredJson 'The filtered JFR output is unavailable.'
    if ($filtered.Length -le 0 -or $filtered.Length -gt $maximumFilteredJsonBytes) {
        throw [InvalidDataException]::new('The filtered JFR output is empty or too large.')
    }

    try {
        $document = [IO.File]::ReadAllText($filtered.FullName) | ConvertFrom-Json
    } catch {
        throw [InvalidDataException]::new('The filtered JFR output is not valid JSON.')
    }
    $recordingObject = Get-PropertyValue $document 'recording'
    $eventArray = @(Get-PropertyValue $recordingObject 'events')
    if ($null -eq $recordingObject -or $eventArray.Count -gt $maximumFilteredEvents) {
        throw [InvalidDataException]::new('The filtered JFR event set is invalid or too large.')
    }

    $eventsByType = [ordered]@{}
    foreach ($eventName in $allowedEvents) {
        $eventsByType[$eventName] = New-Object Collections.ArrayList
    }
    foreach ($event in $eventArray) {
        $type = [string](Get-PropertyValue $event 'type')
        if ($eventsByType.Contains($type)) {
            [void]$eventsByType[$type].Add($event)
        }
    }
    $allowedEventCount = 0
    foreach ($eventName in $allowedEvents) {
        $allowedEventCount += $eventsByType[$eventName].Count
    }
    if ($allowedEventCount -eq 0) {
        throw [InvalidDataException]::new('No Lab native-memory events were found.')
    }

    $recordingAfterRead = Get-SafeLeafFile `
        $recording.FullName 'The Lab recording changed while it was being summarized.'
    if ([Int64]$recordingAfterRead.Length -ne $recordingLength -or
            (Get-SafeSha256 $recordingAfterRead.FullName) -cne $recordingHash) {
        throw [InvalidDataException]::new(
            'The Lab recording changed while it was being summarized.')
    }

    $nmtBuckets = @{}
    $unrecognizedNmtTypeEvents = 0
    foreach ($event in $eventsByType['jdk.NativeMemoryUsage']) {
        $values = Get-EventValues $event
        $category = Get-SafeNmtCategory (Get-PropertyValue $values 'type')
        if ($category -eq 'unrecognized') { $unrecognizedNmtTypeEvents++ }
        if (-not $nmtBuckets.ContainsKey($category)) {
            $nmtBuckets[$category] = [ordered]@{
                reserved = New-Object Collections.ArrayList
                committed = New-Object Collections.ArrayList
            }
        }
        Add-RequiredNumericValue $nmtBuckets[$category].reserved $values 'reserved'
        Add-RequiredNumericValue $nmtBuckets[$category].committed $values 'committed'
    }
    $nmtCategories = New-Object Collections.ArrayList
    foreach ($category in @($nmtBuckets.Keys | Sort-Object)) {
        [void]$nmtCategories.Add([ordered]@{
            category = $category
            eventCount = $nmtBuckets[$category].reserved.Count
            reserved = New-ByteStatistics $nmtBuckets[$category].reserved
            committed = New-ByteStatistics $nmtBuckets[$category].committed
        })
    }

    $rss = New-EventAggregate $eventsByType['jdk.ResidentSetSize'] `
        @('size', 'peak') @()
    $nmtTotal = New-EventAggregate $eventsByType['jdk.NativeMemoryUsageTotal'] `
        @('reserved', 'committed') @()
    $heap = New-EventAggregate $eventsByType['jdk.GCHeapMemoryUsage'] `
        @('used', 'committed', 'max') @()
    $direct = New-EventAggregate $eventsByType['jdk.DirectBufferStatistics'] `
        @('maxCapacity', 'totalCapacity', 'memoryUsed') @('count')

    $summary = [ordered]@{
        schemaVersion = 1
        aggregateOnly = $true
        source = 'LabJvmNativeMemoryDiagnostics'
        recording = [ordered]@{
            sizeBytes = $recordingLength
            sha256 = $recordingHash
            maximumAllowedBytes = [Int64]$maximumRecordingBytes
        }
        tool = [ordered]@{
            name = 'jfr'
            javaMajor = 25
            format = 'json'
        }
        filteredEventCount = $allowedEventCount
        residentSetSize = $rss
        nativeMemoryUsage = [ordered]@{
            available = ($eventsByType['jdk.NativeMemoryUsage'].Count -gt 0)
            eventCount = $eventsByType['jdk.NativeMemoryUsage'].Count
            categoryCount = $nmtCategories.Count
            unrecognizedTypeEventCount = $unrecognizedNmtTypeEvents
            categories = @($nmtCategories)
        }
        nativeMemoryUsageTotal = $nmtTotal
        gcHeapMemoryUsage = $heap
        directBufferStatistics = $direct
    }

    $jsonText = ($summary | ConvertTo-Json -Depth 12) + "`n"
    $markdownLines = New-Object Collections.Generic.List[string]
    $markdownLines.Add('# Quest Lab native-memory JFR summary')
    $markdownLines.Add('')
    $markdownLines.Add('- Aggregate-only: yes')
    $markdownLines.Add('- Java/JFR tool major: 25')
    $markdownLines.Add("- Recording bytes: $($summary.recording.sizeBytes)")
    $markdownLines.Add("- Filtered events: $allowedEventCount")
    $markdownLines.Add('')
    $markdownLines.Add('## Process and JVM totals')
    $markdownLines.Add('')
    $markdownLines.Add('| Metric | Samples | First MiB | Last MiB | Delta MiB |')
    $markdownLines.Add('| --- | ---: | ---: | ---: | ---: |')
    $markdownLines.Add((Format-ByteSummaryMarkdown 'RSS' $rss.size))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'Peak RSS' $rss.peak))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'NMT committed' $nmtTotal.committed))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'NMT reserved' $nmtTotal.reserved))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'GC heap used' $heap.used))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'GC heap committed' $heap.committed))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'GC heap maximum' $heap.max))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'Direct-buffer used' $direct.memoryUsed))
    $markdownLines.Add((Format-ByteSummaryMarkdown 'Direct-buffer capacity' $direct.totalCapacity))
    $markdownLines.Add('')
    $markdownLines.Add('## Native Memory Tracking categories')
    $markdownLines.Add('')
    $markdownLines.Add('| Category | Samples | First committed MiB | Last committed MiB | Delta MiB |')
    $markdownLines.Add('| --- | ---: | ---: | ---: | ---: |')
    foreach ($category in $nmtCategories) {
        $stats = $category.committed
        $markdownLines.Add(
            "| $($category.category) | $($category.eventCount) | $($stats.firstMiB) | " +
            "$($stats.lastMiB) | $($stats.deltaMiB) |")
    }
    if ($nmtCategories.Count -eq 0) {
        $markdownLines.Add('| none | 0 | n/a | n/a | n/a |')
    }
    $markdownText = ($markdownLines -join "`n") + "`n"

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($jsonStage, $jsonText, $utf8NoBom)
    [IO.File]::WriteAllText($markdownStage, $markdownText, $utf8NoBom)

    Move-Item -LiteralPath $jsonStage -Destination $jsonDestination -Force
    Move-Item -LiteralPath $markdownStage -Destination $markdownDestination -Force

    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        AggregateOnly = $true
        FilteredEventCount = $allowedEventCount
        JsonFile = $jsonOutputName
        MarkdownFile = $markdownOutputName
    }
} finally {
    foreach ($temporary in @($filteredJson, $filteredError, $jsonStage, $markdownStage)) {
        if ($temporary -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}
