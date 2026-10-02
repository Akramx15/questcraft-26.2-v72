[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$parser = Join-Path $PSScriptRoot 'summarize-v71-lab-jvm-heap.ps1'
Require (Test-Path -LiteralPath $parser -PathType Leaf) 'Parser script is missing.'

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('qc-v71-heap-parser-' + [Guid]::NewGuid().ToString('N'))
$resolvedRoot = [IO.Path]::GetFullPath($testRoot)
Require ($resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) `
    'Refusing to create a test directory outside the system temp directory.'
[void][IO.Directory]::CreateDirectory($resolvedRoot)

try {
    $baseLog = Join-Path $resolvedRoot 'gc-heap.log'
    $rotatedZero = $baseLog + '.0'
    $rotatedOne = $baseLog + '.1'
    $samples = Join-Path $resolvedRoot 'samples.jsonl'

    [IO.File]::WriteAllText($rotatedOne, @'
[0.001s][debug][gc,heap] Minimum heap 536870912 Initial heap 536870912 Maximum heap 1610612736
[0.002s][info ][gc,heap] Heap region size: 2M
[60.000s][debug][gc,heap] GC(1) Heap after GC invocations=1 (full 0):
[60.000s][debug][gc,heap] GC(1)  garbage-first heap total reserved 1572864K, committed 524288K, used 262144K
[60.000s][debug][gc,heap] GC(1)   region size 2048K, 2 young (4096K), 1 survivors (2048K)
[60.000s][info ][gc,heap] GC(1) Old regions: 10->20
[60.000s][info ][gc,heap] GC(1) Humongous regions: 1->2
'@)
    [IO.File]::WriteAllText($rotatedZero, @'
[180.000s][debug][gc,heap] GC(2) Heap after GC invocations=2 (full 0):
[180.000s][debug][gc,heap] GC(2)  garbage-first heap total reserved 1572864K, committed 786432K, used 393216K
[180.000s][info ][gc,heap] GC(2) Old regions: 20->30
[180.000s][info ][gc,heap] GC(2) Humongous regions: 2->3
'@)
    [IO.File]::WriteAllText($baseLog, @'
[300.000s][debug][gc,heap] GC(3) Heap after GC invocations=3 (full 0):
[300.000s][debug][gc,heap] GC(3)  garbage-first heap total reserved 1572864K, committed 1048576K, used 524288K
[300.000s][info ][gc,heap] GC(3) Old regions: 30->40
[300.000s][info ][gc,heap] GC(3) Humongous regions: 3->4
'@)
    [IO.File]::WriteAllText($samples, @'
{"elapsedMinutes":0.0,"totalPssKib":1024000,"pid":100,"timestampUtc":"redacted-a"}
{"elapsedMinutes":2.0,"totalPssKib":1228800,"pid":100,"timestampUtc":"redacted-b"}
{"elapsedMinutes":4.0,"totalPssKib":1433600,"pid":100,"timestampUtc":"redacted-c"}
'@)

    $json = & $parser -GcHeapLogPath $baseLog -SamplesJsonlPath $samples `
        -SampleZeroJvmUptimeSeconds 60 -MaxCorrelationGapSeconds 1
    $result = $json | ConvertFrom-Json

    Require ($result.aggregateOnly -eq $true) 'Output is not marked aggregate-only.'
    Require ($result.rotatedLogFileCount -eq 3) 'Rotated logs were not combined.'
    Require ($result.configuredHeap.initialMiB -eq 512) 'Initial heap parse failed.'
    Require ($result.configuredHeap.maximumMiB -eq 1536) 'Maximum heap parse failed.'
    Require ($result.postGcHeap.eventCount -eq 3) 'Post-GC event count is wrong.'
    Require ($result.postGcHeap.firstUsedMiB -eq 256) 'First used heap is wrong.'
    Require ($result.postGcHeap.lastUsedMiB -eq 512) 'Last used heap is wrong.'
    Require ($result.postGcHeap.maxUsedMiB -eq 512) 'Maximum used heap is wrong.'
    Require ($result.postGcHeap.usedSlopeMiBPerMinute -eq 64) 'Used slope is wrong.'
    Require ($result.postGcHeap.firstCommittedMiB -eq 512) 'First committed heap is wrong.'
    Require ($result.postGcHeap.lastCommittedMiB -eq 1024) 'Last committed heap is wrong.'
    Require ($result.postGcHeap.committedSlopeMiBPerMinute -eq 128) `
        'Committed slope is wrong.'
    Require ($result.regionSizeMiB -eq 2) 'Region size parse failed.'
    Require ($result.oldRegions.firstRegions -eq 20) 'Old-region first value is wrong.'
    Require ($result.oldRegions.lastRegions -eq 40) 'Old-region last value is wrong.'
    Require ($result.oldRegions.slopeMiBPerMinute -eq 10) 'Old-region MiB slope is wrong.'
    Require ($result.humongousRegions.firstRegions -eq 2) `
        'Humongous-region first value is wrong.'
    Require ($result.humongousRegions.lastRegions -eq 4) `
        'Humongous-region last value is wrong.'
    Require ($result.pssCorrelation.status -eq 'aligned') 'PSS correlation did not align.'
    Require ($result.pssCorrelation.pairedSampleCount -eq 3) 'PSS pair count is wrong.'
    Require ($result.pssCorrelation.pssVsPostGcUsedPearson -eq 1) `
        'Used/PSS correlation is wrong.'
    Require ($result.pssCorrelation.pssVsPostGcCommittedPearson -eq 1) `
        'Committed/PSS correlation is wrong.'

    $serialized = $result | ConvertTo-Json -Depth 8
    Require (-not $serialized.Contains($resolvedRoot)) 'Output leaked an input path.'
    Require (-not $serialized.Contains('redacted-a')) 'Output leaked an absolute timestamp.'
    Require (-not $serialized.Contains('"pid"')) 'Output leaked a PID.'

    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        ParsedRotatedLogs = 3
        ParsedPostGcEvents = 3
        CorrelatedPssSamples = 3
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($resolvedRoot)
    if ($resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            $resolvedRoot -ne $tempBase -and (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
