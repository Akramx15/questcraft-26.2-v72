#requires -Version 7.0
<# Host-only safety and parser regression test for the RC6.2 expanded-memory collector. #>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require([bool] $Condition, [string] $Message) {
    if (-not $Condition) {
        throw "[V71_RC6_2_EXPANDED_MEMINFO_HOST_TEST] $Message"
    }
}

function Test-RejectedBeforeAdb(
    [Parameter(Mandatory)][scriptblock] $Operation,
    [Parameter(Mandatory)][string] $ExpectedMessage
) {
    try {
        & $Operation
        return $false
    } catch {
        return $_.Exception.Message.Contains(
            $ExpectedMessage, [StringComparison]::Ordinal)
    }
}

$collector = Join-Path $PSScriptRoot 'quest-v71-expanded-meminfo-rc62.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildLockPath = Join-Path $repoRoot 'V71_LAB_RC6_2.lock.json'
$sentinelAdb = Join-Path $PSScriptRoot `
    '__quest-v71-expanded-meminfo-rc62-host-test-no-adb__.exe'
$sentinelOutput = Join-Path $repoRoot `
    'artifacts\memory\__quest-v71-expanded-meminfo-rc62-host-test-no-output__'

Require (Test-Path -LiteralPath $collector -PathType Leaf) `
    'The expanded-memory collector is missing.'
Require (Test-Path -LiteralPath $buildLockPath -PathType Leaf) `
    'The immutable RC6.2 build lock is missing.'
Require (-not (Test-Path -LiteralPath $sentinelAdb)) `
    'The deliberately absent ADB sentinel unexpectedly exists.'
Require (-not (Test-Path -LiteralPath $sentinelOutput)) `
    'The deliberately absent output sentinel unexpectedly exists.'

$collectorTokens = $null
$collectorParseErrors = $null
$collectorAst = [Management.Automation.Language.Parser]::ParseFile(
    $collector, [ref]$collectorTokens, [ref]$collectorParseErrors)
Require ($collectorParseErrors.Count -eq 0) `
    'The PowerShell parser rejected the expanded-memory collector.'

$selfTokens = $null
$selfParseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
    $PSCommandPath, [ref]$selfTokens, [ref]$selfParseErrors)
Require ($selfParseErrors.Count -eq 0) `
    'The PowerShell parser rejected this Host test.'

$selfTestValues = @(& $collector -Serial 'offline-proof' -AdbPath $sentinelAdb)
$selfTests = @($selfTestValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($selfTests.Count -eq 1 -and
        [string]$selfTests[0].Result -ceq 'PASS') `
    'Default invocation did not return one PASS SelfTest record.'
$selfTest = $selfTests[0]
Require ([bool]$selfTest.HostOnly -and
        [int]$selfTest.DeviceInvocations -eq 0 -and
        [int]$selfTest.HostWrites -eq 0 -and
        [string]$selfTest.DefaultAction -ceq 'SelfTest') `
    'Default SelfTest touched a device, wrote output, or changed mode.'
Require ([int]$selfTest.DefaultDurationMinutes -eq 12 -and
        [string]$selfTest.AllowedDurationMinutes -ceq '10-15' -and
        [int]$selfTest.DefaultIntervalSeconds -eq 60) `
    'The bounded 10-to-15-minute capture contract drifted.'
Require ([bool]$selfTest.AggregateParserPassed -and
        [bool]$selfTest.DalvikDetailParserPassed -and
        [bool]$selfTest.TotalCrossCheckPassed -and
        [bool]$selfTest.LocalOnlyMeminfoCovered -and
        [bool]$selfTest.TargetGcAvoidanceCovered -and
        [bool]$selfTest.SilentRuntimeLogFixturePassed -and
        [bool]$selfTest.PidFenceCovered -and
        [bool]$selfTest.ProcessStartFenceCovered -and
        [bool]$selfTest.ExactRc62LockCovered -and
        [bool]$selfTest.SanitizedReceiptCovered -and
        [bool]$selfTest.RawRowsDiscarded) `
    'SelfTest did not cover every parser, fence, and sanitization boundary.'
Require (-not (Test-Path -LiteralPath $sentinelAdb) -and
        -not (Test-Path -LiteralPath $sentinelOutput)) `
    'Default SelfTest resolved ADB or created Host output.'
$mixedCaseValues = @(& $collector -Action 'sElFtEsT' -Serial 'offline-proof' `
    -AdbPath $sentinelAdb)
$mixedCaseSelfTest = @($mixedCaseValues | Where-Object {
        $null -ne $_.PSObject.Properties['Result']
    })
Require ($mixedCaseSelfTest.Count -eq 1 -and
        [string]$mixedCaseSelfTest[0].Result -ceq 'PASS' -and
        [bool]$mixedCaseSelfTest[0].HostOnly -and
        [int]$mixedCaseSelfTest[0].DeviceInvocations -eq 0 -and
        [int]$mixedCaseSelfTest[0].HostWrites -eq 0) `
    'A case-insensitive SelfTest selection fell through to Capture.'

$missingDeviceReadRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput | Out-Null
} 'Capture requires explicit -AllowDeviceRead.'
Require $missingDeviceReadRejected `
    'Capture did not require explicit read-only device authorization.'

$missingHostOutputRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput -AllowDeviceRead | Out-Null
} 'Capture requires explicit -AllowHostOutput.'
Require $missingHostOutputRejected `
    'Capture did not require explicit Host-output authorization.'

$unsafeOutputRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $repoRoot -AllowDeviceRead -AllowHostOutput | Out-Null
} 'Output must be a new child directory under artifacts/memory.'
Require $unsafeOutputRejected `
    'Capture did not reject an output directory outside its narrow boundary.'
$missingExplicitAdbRejected = Test-RejectedBeforeAdb {
    & $collector -Action Capture -Serial 'offline-proof' -AdbPath $sentinelAdb `
        -OutputDirectory $sentinelOutput -AllowDeviceRead -AllowHostOutput | Out-Null
} 'The explicitly requested ADB executable was not found.'
Require $missingExplicitAdbRejected `
    'An absent explicit ADB path fell back to another executable.'
Require (-not (Test-Path -LiteralPath $sentinelAdb) -and
        -not (Test-Path -LiteralPath $sentinelOutput)) `
    'A pre-ADB rejection fixture touched ADB or created Host output.'

$source = [IO.File]::ReadAllText($collector)
Require ($source.Contains("[string] `$Action = 'SelfTest'",
            [StringComparison]::Ordinal) -and
        $source.Contains('[ValidateRange(10, 15)]',
            [StringComparison]::Ordinal) -and
        $source.Contains("'dumpsys', 'meminfo', '-a', '--local', [string]`$ExpectedPid",
            [StringComparison]::Ordinal)) `
    'The default mode, duration fence, or expanded meminfo command drifted.'
Require ($source.Contains('Assert-ProcessFence $ExpectedPid $ExpectedStartTicks',
            [StringComparison]::Ordinal) -and
        $source.Contains('Assert-ExactDeviceIdentity',
            [StringComparison]::Ordinal) -and
        $source.Contains('Assert-ExactRuntimeLog',
            [StringComparison]::Ordinal) -and
        $source.Contains('Assert-SanitizedReceipt $receipt $json',
            [StringComparison]::Ordinal)) `
    'The process, exact-build, runtime, or receipt fence is missing.'

$literalValues = @($collectorAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
$forbiddenDeviceVerbs = @(
    'am', 'cmd', 'monkey', 'start', 'stop', 'force-stop', 'install', 'uninstall',
    'clear', 'push', 'pull', 'sync', 'reboot', 'root', 'remount', 'disable-verity',
    'setprop', 'settings', 'rm', 'mv', 'cp', 'mkdir', 'touch', 'chmod', 'chown',
    'dd', 'tee'
)
foreach ($verb in $forbiddenDeviceVerbs) {
    Require ($literalValues -cnotcontains $verb) `
        "A prohibited device-operation token is callable: $verb."
}
Require ($literalValues -cnotcontains 'logcat') `
    'The collector must not collect an unfiltered device log stream.'
Require ($source.Contains("Invoke-Adb @('-s', `$script:Device, 'exec-out', 'cat', `$script:GameLogPath)",
            [StringComparison]::Ordinal) -and
        $source.Contains('[IO.File]::WriteAllText($temporary, $Json + [Environment]::NewLine,',
            [StringComparison]::Ordinal)) `
    'The bounded in-memory runtime read or sanitized-only writer drifted.'

$selfTestJson = $selfTest | ConvertTo-Json -Depth 8 -Compress
$buildLock = Get-Content -Raw -LiteralPath $buildLockPath | ConvertFrom-Json
Require (-not $selfTestJson.Contains([string]$buildLock.target.package,
            [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains([string]$buildLock.target.forbiddenStablePackage,
            [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains($sentinelAdb, [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains('/sdcard/', [StringComparison]::Ordinal) -and
        -not $selfTestJson.Contains('/data/', [StringComparison]::Ordinal) -and
        $selfTestJson -notmatch '(?i)account|world|server') `
    'The public SelfTest record exposed a prohibited identifier or path.'

[pscustomobject][ordered]@{
    Result = 'PASS'
    HostOnly = $true
    DeviceInvocations = 0
    HostWrites = 0
    PowerShellParsePassed = $true
    DefaultSelfTestPassed = $true
    ExplicitAuthorizationFencesPassed = $true
    SafeOutputBoundaryPassed = $true
    ReadOnlyDeviceCommandAuditPassed = $true
    ExpandedAggregateParserPassed = $true
    PidAndProcessStartFencesPassed = $true
    ExactRc62FencePassed = $true
    SanitizedReceiptBoundaryPassed = $true
    LocalOnlyTargetGcAvoidancePassed = $true
    SilentRuntimeLogBindingPassed = $true
}
