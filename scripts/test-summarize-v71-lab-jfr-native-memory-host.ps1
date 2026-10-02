[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Expect-Failure {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Action,
        [Parameter(Mandatory = $true)][string] $Message
    )
    $failed = $false
    try {
        & $Action
    } catch {
        $failed = $true
    }
    Require $failed $Message
}

$summarizer = Join-Path $PSScriptRoot 'summarize-v71-lab-jfr-native-memory.ps1'
Require (Test-Path -LiteralPath $summarizer -PathType Leaf) 'Summarizer script is missing.'

$source = [IO.File]::ReadAllText($summarizer)
Require (-not [regex]::IsMatch($source, '(?i)(^|[^a-z])adb([^a-z]|$)')) `
    'Host-only summarizer must not contain a device command.'
Require ($source.Contains('--json --events')) 'Filtered JFR JSON is not requested.'
Require (-not $source.Contains('--json --exact')) `
    'Java 25 rejects the mutually exclusive --json and --exact format flags.'
Require ($source.Contains('$maximumRecordingBytes = 16MB')) 'The 16 MiB input cap is missing.'

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('qc-v71-jfr-summary-' + [Guid]::NewGuid().ToString('N'))
$resolvedRoot = [IO.Path]::GetFullPath($testRoot)
Require ($resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) `
    'Refusing to create a test directory outside the system temp directory.'
[void][IO.Directory]::CreateDirectory($resolvedRoot)

$oldFixture = $env:QC_FAKE_JFR_JSON
$oldVersion = $env:QC_FAKE_JFR_VERSION
$oldArgs = $env:QC_FAKE_JFR_ARGS
$oldMutation = $env:QC_FAKE_JFR_MUTATE
$oldRecording = $env:QC_FAKE_JFR_RECORDING

try {
    $recording = Join-Path $resolvedRoot 'quest-native-memory.jfr'
    $fixture = Join-Path $resolvedRoot 'filtered.json'
    $argsLog = Join-Path $resolvedRoot 'tool-args.txt'
    $tool = Join-Path $resolvedRoot 'jfr.cmd'
    $output = Join-Path $resolvedRoot 'output'
    [void][IO.Directory]::CreateDirectory($output)

    [IO.File]::WriteAllBytes($recording, [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
    [IO.File]::WriteAllText($fixture, @'
{
  "recording": {
    "events": [
      {"type":"jdk.ResidentSetSize","values":{"startTime":"secret-time-a","size":2147483648,"peak":2306867200}},
      {"type":"jdk.NativeMemoryUsage","values":{"startTime":"secret-time-a","type":{"name":"Java Heap"},"reserved":1610612736,"committed":536870912}},
      {"type":"jdk.NativeMemoryUsage","values":{"startTime":"secret-time-a","type":{"name":"Thread Stack"},"reserved":134217728,"committed":67108864}},
      {"type":"jdk.NativeMemoryUsage","values":{"startTime":"secret-time-a","type":{"name":"C:\\private\\account\\world"},"reserved":2097152,"committed":1048576}},
      {"type":"jdk.NativeMemoryUsageTotal","values":{"startTime":"secret-time-a","reserved":2147483648,"committed":734003200}},
      {"type":"jdk.GCHeapMemoryUsage","values":{"startTime":"secret-time-a","used":314572800,"committed":536870912,"max":1610612736}},
      {"type":"jdk.DirectBufferStatistics","values":{"startTime":"secret-time-a","maxCapacity":268435456,"count":3,"totalCapacity":33554432,"memoryUsed":34603008}},
      {"type":"jdk.JVMInformation","values":{"startTime":"secret-time-a","jvmArguments":"--token secret-account-token","jvmProperties":"user.home=C:\\private\\account","jvmFlags":"secret-flag"}},
      {"type":"jdk.ResidentSetSize","values":{"startTime":"secret-time-b","size":2415919104,"peak":2516582400}},
      {"type":"jdk.NativeMemoryUsage","values":{"startTime":"secret-time-b","type":{"name":"Java Heap"},"reserved":1610612736,"committed":671088640}},
      {"type":"jdk.NativeMemoryUsage","values":{"startTime":"secret-time-b","type":{"name":"Thread Stack"},"reserved":150994944,"committed":83886080}},
      {"type":"jdk.NativeMemoryUsageTotal","values":{"startTime":"secret-time-b","reserved":2281701376,"committed":891289600}},
      {"type":"jdk.GCHeapMemoryUsage","values":{"startTime":"secret-time-b","used":346030080,"committed":536870912,"max":1610612736}},
      {"type":"jdk.DirectBufferStatistics","values":{"startTime":"secret-time-b","maxCapacity":268435456,"count":5,"totalCapacity":50331648,"memoryUsed":52428800}}
    ]
  }
}
'@)
    [IO.File]::WriteAllText($tool, @'
@echo off
if "%~1"=="version" (
  echo %QC_FAKE_JFR_VERSION%
  exit /b 0
)
if "%~1"=="print" (
  echo %*>>"%QC_FAKE_JFR_ARGS%"
  type "%QC_FAKE_JFR_JSON%"
  if "%QC_FAKE_JFR_MUTATE%"=="1" echo changed>>"%QC_FAKE_JFR_RECORDING%"
  exit /b 0
)
exit /b 9
'@)

    $env:QC_FAKE_JFR_JSON = $fixture
    $env:QC_FAKE_JFR_VERSION = '25.0.1'
    $env:QC_FAKE_JFR_ARGS = $argsLog
    $env:QC_FAKE_JFR_MUTATE = '0'
    $env:QC_FAKE_JFR_RECORDING = $recording

    $result = & $summarizer -JfrPath $recording -OutputDirectory $output `
        -JfrToolPath $tool
    Require ($result.Result -eq 'PASS') 'Valid fixture did not pass.'
    Require ($result.HostOnly -eq $true) 'Result is not marked Host-only.'
    Require ($result.DeviceInvocations -eq 0) 'Unexpected device invocation count.'
    Require ($result.FilteredEventCount -eq 13) 'Filtered event count is incorrect.'

    $jsonPath = Join-Path $output 'v71-lab-native-memory-summary.json'
    $markdownPath = Join-Path $output 'v71-lab-native-memory-summary.md'
    Require (Test-Path -LiteralPath $jsonPath -PathType Leaf) 'JSON summary was not written.'
    Require (Test-Path -LiteralPath $markdownPath -PathType Leaf) `
        'Markdown summary was not written.'

    $jsonText = [IO.File]::ReadAllText($jsonPath)
    $markdownText = [IO.File]::ReadAllText($markdownPath)
    $summary = $jsonText | ConvertFrom-Json
    Require ($summary.schemaVersion -eq 1) 'Unexpected summary schema.'
    Require ($summary.aggregateOnly -eq $true) 'Output is not aggregate-only.'
    Require ($summary.source -eq 'LabJvmNativeMemoryDiagnostics') 'Unexpected source marker.'
    Require ($summary.recording.sizeBytes -eq 8) 'Recording size is wrong.'
    Require ($summary.recording.maximumAllowedBytes -eq 16777216) 'Recording cap is wrong.'
    Require ($summary.recording.sha256 -match '^[0-9A-F]{64}$') 'Recording hash is invalid.'
    Require ($summary.tool.javaMajor -eq 25) 'Java tool major is wrong.'
    Require ($summary.residentSetSize.size.firstMiB -eq 2048) 'RSS first value is wrong.'
    Require ($summary.residentSetSize.size.lastMiB -eq 2304) 'RSS last value is wrong.'
    Require ($summary.residentSetSize.size.deltaMiB -eq 256) 'RSS delta is wrong.'
    Require ($summary.gcHeapMemoryUsage.used.firstMiB -eq 300) 'Heap first value is wrong.'
    Require ($summary.gcHeapMemoryUsage.used.lastMiB -eq 330) 'Heap last value is wrong.'
    Require ($summary.directBufferStatistics.count.first -eq 3) `
        'Direct-buffer first count is wrong.'
    Require ($summary.directBufferStatistics.count.last -eq 5) `
        'Direct-buffer last count is wrong.'
    Require ($summary.nativeMemoryUsage.categoryCount -eq 3) `
        'NMT category count is wrong.'
    Require ($summary.nativeMemoryUsage.unrecognizedTypeEventCount -eq 1) `
        'Unknown NMT labels were not safely coalesced.'
    $categories = @($summary.nativeMemoryUsage.categories | ForEach-Object { $_.category })
    Require (($categories -join ',') -eq 'javaHeap,threadStack,unrecognized') `
        'NMT categories are not in deterministic safe order.'
    $javaHeap = @($summary.nativeMemoryUsage.categories | Where-Object {
            $_.category -eq 'javaHeap'
        })[0]
    Require ($javaHeap.committed.firstMiB -eq 512) 'Java-heap NMT first value is wrong.'
    Require ($javaHeap.committed.lastMiB -eq 640) 'Java-heap NMT last value is wrong.'

    foreach ($secret in @(
            'secret-time-a', 'secret-time-b', 'secret-account-token',
            'secret-flag', 'private', 'account', 'world', 'jvmArguments',
            'jvmProperties', 'jvmFlags')) {
        Require (-not $jsonText.Contains($secret)) "JSON leaked forbidden raw data: $secret"
        Require (-not $markdownText.Contains($secret)) `
            "Markdown leaked forbidden raw data: $secret"
    }
    Require (-not $jsonText.Contains($resolvedRoot)) 'JSON leaked a Host path.'
    Require (-not $markdownText.Contains($resolvedRoot)) 'Markdown leaked a Host path.'

    $toolArguments = [IO.File]::ReadAllText($argsLog)
    Require ($toolArguments.Contains('print --json --events')) `
        'The Java tool did not receive JSON event filtering.'
    Require ($toolArguments.Contains(
            'jdk.ResidentSetSize,jdk.NativeMemoryUsage,jdk.NativeMemoryUsageTotal,' +
            'jdk.GCHeapMemoryUsage,jdk.DirectBufferStatistics')) `
        'The event allowlist passed to Java is wrong.'
    Require ($toolArguments.Contains('--stack-depth 0')) 'Stack output was not disabled.'

    $firstJson = $jsonText
    $firstMarkdown = $markdownText
    [void](& $summarizer -JfrPath $recording -OutputDirectory $output `
        -JfrToolPath $tool)
    Require ([IO.File]::ReadAllText($jsonPath) -ceq $firstJson) `
        'JSON output is not deterministic.'
    Require ([IO.File]::ReadAllText($markdownPath) -ceq $firstMarkdown) `
        'Markdown output is not deterministic.'

    $wrongVersionOutput = Join-Path $resolvedRoot 'wrong-version-output'
    [void][IO.Directory]::CreateDirectory($wrongVersionOutput)
    $env:QC_FAKE_JFR_VERSION = '21.0.10'
    Expect-Failure {
        & $summarizer -JfrPath $recording -OutputDirectory $wrongVersionOutput `
            -JfrToolPath $tool
    } 'A non-Java-25 tool was accepted.'
    Require (@(Get-ChildItem -LiteralPath $wrongVersionOutput -Force).Count -eq 0) `
        'Wrong-version failure left output files.'
    $env:QC_FAKE_JFR_VERSION = '25.0.1'

    $oversizeRoot = Join-Path $resolvedRoot 'oversize'
    $oversizeOutput = Join-Path $resolvedRoot 'oversize-output'
    [void][IO.Directory]::CreateDirectory($oversizeRoot)
    [void][IO.Directory]::CreateDirectory($oversizeOutput)
    $oversize = Join-Path $oversizeRoot 'quest-native-memory.jfr'
    $stream = [IO.File]::Open($oversize, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $stream.SetLength(16MB + 1) } finally { $stream.Dispose() }
    $argsBeforeOversize = (Get-Item -LiteralPath $argsLog).Length
    Expect-Failure {
        & $summarizer -JfrPath $oversize -OutputDirectory $oversizeOutput `
            -JfrToolPath $tool
    } 'An oversized recording was accepted.'
    Require ((Get-Item -LiteralPath $argsLog).Length -eq $argsBeforeOversize) `
        'The Java tool ran before the input size gate.'
    Require (@(Get-ChildItem -LiteralPath $oversizeOutput -Force).Count -eq 0) `
        'Oversized-input failure left output files.'

    $wrongName = Join-Path $resolvedRoot 'unrelated.jfr'
    [IO.File]::WriteAllBytes($wrongName, [byte[]](1, 2, 3))
    $wrongNameOutput = Join-Path $resolvedRoot 'wrong-name-output'
    [void][IO.Directory]::CreateDirectory($wrongNameOutput)
    Expect-Failure {
        & $summarizer -JfrPath $wrongName -OutputDirectory $wrongNameOutput `
            -JfrToolPath $tool
    } 'A non-Lab recording name was accepted.'
    Require (@(Get-ChildItem -LiteralPath $wrongNameOutput -Force).Count -eq 0) `
        'Wrong-name failure left output files.'

    $invalidOutput = Join-Path $resolvedRoot 'invalid-output'
    [void][IO.Directory]::CreateDirectory($invalidOutput)
    [IO.File]::WriteAllText($fixture, '{not-json')
    Expect-Failure {
        & $summarizer -JfrPath $recording -OutputDirectory $invalidOutput `
            -JfrToolPath $tool
    } 'Malformed filtered JSON was accepted.'
    Require (@(Get-ChildItem -LiteralPath $invalidOutput -Force).Count -eq 0) `
        'Malformed-JSON failure left output files.'

    $emptyOutput = Join-Path $resolvedRoot 'empty-output'
    [void][IO.Directory]::CreateDirectory($emptyOutput)
    [IO.File]::WriteAllText($fixture,
        '{"recording":{"events":[{"type":"jdk.JVMInformation",' +
        '"values":{"jvmArguments":"secret"}}]}}')
    Expect-Failure {
        & $summarizer -JfrPath $recording -OutputDirectory $emptyOutput `
            -JfrToolPath $tool
    } 'A recording with no allowed events was accepted.'
    Require (@(Get-ChildItem -LiteralPath $emptyOutput -Force).Count -eq 0) `
        'No-allowed-event failure left output files.'

    $badNumberOutput = Join-Path $resolvedRoot 'bad-number-output'
    [void][IO.Directory]::CreateDirectory($badNumberOutput)
    [IO.File]::WriteAllText($fixture,
        '{"recording":{"events":[{"type":"jdk.ResidentSetSize",' +
        '"values":{"size":"secret-path","peak":1}}]}}')
    Expect-Failure {
        & $summarizer -JfrPath $recording -OutputDirectory $badNumberOutput `
            -JfrToolPath $tool
    } 'A non-numeric memory field was accepted.'
    Require (@(Get-ChildItem -LiteralPath $badNumberOutput -Force).Count -eq 0) `
        'Invalid-field failure left output files.'

    $mutationOutput = Join-Path $resolvedRoot 'mutation-output'
    [void][IO.Directory]::CreateDirectory($mutationOutput)
    [IO.File]::WriteAllText($fixture,
        '{"recording":{"events":[{"type":"jdk.ResidentSetSize",' +
        '"values":{"size":1,"peak":1}}]}}')
    $env:QC_FAKE_JFR_MUTATE = '1'
    Expect-Failure {
        & $summarizer -JfrPath $recording -OutputDirectory $mutationOutput `
            -JfrToolPath $tool
    } 'A recording mutated during parsing was accepted.'
    Require (@(Get-ChildItem -LiteralPath $mutationOutput -Force).Count -eq 0) `
        'Input-mutation failure left output files.'
    $env:QC_FAKE_JFR_MUTATE = '0'

    [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        DeterministicOutputs = 2
        AllowedEventTypes = 5
        PrivacySentinelsRejected = 10
        FailureGates = 6
    }
} finally {
    $env:QC_FAKE_JFR_JSON = $oldFixture
    $env:QC_FAKE_JFR_VERSION = $oldVersion
    $env:QC_FAKE_JFR_ARGS = $oldArgs
    $env:QC_FAKE_JFR_MUTATE = $oldMutation
    $env:QC_FAKE_JFR_RECORDING = $oldRecording

    $resolvedRoot = [IO.Path]::GetFullPath($resolvedRoot)
    if ($resolvedRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            $resolvedRoot -ne $tempBase -and (Test-Path -LiteralPath $resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
