#requires -Version 7.0
<#
.SYNOPSIS
Host-only fake-ADB tests for quest-v71-rc8-benchmark-world-reset.ps1.

.DESCRIPTION
Creates an isolated fake ADB script under the Host temporary directory. No
real adb executable is resolved or invoked. The tests cover explicit USB
selection with simultaneous USB/Wi-Fi endpoints, exact RC8 identity failures,
Stable/Lab process guards, snapshot validation, write authorization, and the
successful backup-before-swap sequence. Successful resets must emit bounded,
non-overwritable receipts; failed resets must not emit one.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gate = Join-Path $PSScriptRoot 'quest-v71-rc8-benchmark-world-reset.ps1'
$pwsh = (Get-Process -Id $PID).Path
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$temp = Join-Path $tempParent ('qc-rc8-world-reset-host-' + [Guid]::NewGuid().ToString('N'))
$tempFull = [IO.Path]::GetFullPath($temp)
if (-not $tempFull.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The Host test directory escaped the system temporary directory.'
}
[IO.Directory]::CreateDirectory($tempFull) | Out-Null
$fakeAdbScript = Join-Path $tempFull 'fake-adb.ps1'
$fakeAdb = Join-Path $tempFull 'fake-adb.exe'
$fakeForwarderPath = Join-Path $tempFull 'fake-adb-forwarder.cs'
$log = Join-Path $tempFull 'adb-invocations.jsonl'
$state = Join-Path $tempFull 'fake-device-state.txt'
$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactRoot = Join-Path $repoRoot 'artifacts\v71-rc8-input-performance-ab'
$receiptTestRoot = Join-Path $artifactRoot `
    ('world-reset-host-test-' + [Guid]::NewGuid().ToString('N'))
$assertions = 0
$failureScenarios = 0
$receiptSequence = 0
$testCompleted = $false

function Require([bool] $Condition, [string] $Message) {
    $script:assertions++
    if (-not $Condition) { throw "[RC8_WORLD_RESET_HOST_TEST] $Message" }
}

function Reset-Fixture([string] $Scenario) {
    $env:QC_FAKE_ADB_SCENARIO = $Scenario
    $env:QC_FAKE_ADB_LOG = $log
    $env:QC_FAKE_ADB_STATE = $state
    if (Test-Path -LiteralPath $log) { [IO.File]::Delete($log) }
    if (Test-Path -LiteralPath $state) { [IO.File]::Delete($state) }
}

function Invoke-Gate([string[]] $Arguments) {
    $rows = @(& $pwsh -NoProfile -File $gate @Arguments 2>&1 |
        ForEach-Object { [string]$_ })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $rows }
}

function New-ReceiptPath {
    $script:receiptSequence++
    Require ($script:receiptSequence -le 99) 'The Host receipt fixture exhausted its names.'
    Join-Path $receiptTestRoot ('reset-{0:D2}.json' -f $script:receiptSequence)
}

function Invoke-ResetGate([string[]] $Arguments, [string] $OutputPath = '') {
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = New-ReceiptPath }
    $result = Invoke-Gate (@($Arguments) + @(
        '-OutputJson', $OutputPath, '-AllowHostOutput'))
    $result | Add-Member -NotePropertyName ReceiptPath -NotePropertyValue $OutputPath
    $result
}

function Get-LogText {
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return '' }
    [IO.File]::ReadAllText($log)
}

function Get-LogRecords {
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return @() }
    @([IO.File]::ReadAllLines($log) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-TextSha256([Parameter(Mandatory)][string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
    } finally { $sha.Dispose() }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-TextSha256 $text
}

function Read-Receipt([Parameter(Mandatory)][string] $Path) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) `
        "The expected reset receipt was not created: $Path"
    [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Assert-ResetReceipt(
    [Parameter(Mandatory)] $Result,
    [Parameter(Mandatory)][DateTimeOffset] $StartedAtUtc,
    [Parameter(Mandatory)][DateTimeOffset] $EndedAtUtc,
    [Parameter(Mandatory)][ValidateSet('Normal', 'Root')][string] $ExpectedAccessMode,
    [Parameter(Mandatory)][ValidateSet('CREATED', 'VERIFIED')][string] $ExpectedMasterCache
) {
    Require ($Result.ExitCode -eq 0) `
        ('The reset expected to produce a receipt failed: ' + ($Result.Lines -join ' | '))
    $path = [string]$Result.ReceiptPath
    $raw = [IO.File]::ReadAllText($path)
    $receipt = Read-Receipt $path
    $propertyNames = @($receipt.PSObject.Properties.Name)
    Require ([int64]$receipt.schemaVersion -eq 1 -and
            [string]$receipt.receiptType -ceq 'V71_RC8_INPUT_PERFORMANCE_WORLD_RESET' -and
            [string]$receipt.result -ceq 'RESET') `
        'The reset receipt schema/type/result was not exact.'
    $runId = [string]$receipt.resetRunId
    Require ($runId -cmatch '^[0-9a-f]{32}$') 'The reset receipt run ID was invalid.'
    $timestampMatch = [regex]::Match($raw,
        '"completedAtUtc"\s*:\s*"(?<timestamp>[^"]+)"',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    Require $timestampMatch.Success 'The reset receipt completion timestamp field was absent.'
    $completedText = [string]$timestampMatch.Groups['timestamp'].Value
    $completedAt = [DateTimeOffset]::MinValue
    $timestampParsed = [DateTimeOffset]::TryParseExact($completedText, 'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$completedAt)
    Require ($timestampParsed -and $completedAt.Offset -eq [TimeSpan]::Zero) `
        'The reset receipt completion timestamp was not exact UTC.'
    Require ($completedAt -ge $StartedAtUtc.AddSeconds(-1) -and
            $completedAt -le $EndedAtUtc.AddSeconds(1)) `
        ("The reset receipt timestamp was outside this run: completed=$completedAt; " +
            "started=$StartedAtUtc; ended=$EndedAtUtc.")
    $expectedProducer = Get-NormalizedTextSha256 $gate
    Require ([string]$receipt.resetProducerSha256 -ceq $expectedProducer) `
        'The reset receipt producer hash did not bind the executed reset tool.'
    $expectedBinding = Get-TextSha256 (
        "rc8-world-reset-v1`nserial=USB123`nrunId=$runId`nmaster=9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90")
    Require ([string]$receipt.deviceBindingSha256 -ceq $expectedBinding) `
        'The reset receipt device-binding hash was invalid.'
    Require ([string]$receipt.package -ceq 'com.qcxr.qcxr.canary262' -and
            [string]$receipt.profile -ceq '26.2' -and
            [string]$receipt.world -ceq 'FPS-Stress-Test' -and
            [bool]$receipt.exactRc8Identity) `
        'The reset receipt did not bind the exact RC8 Lab/world identity.'
    Require ([string]$receipt.apkSha256 -ceq
                'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416' -and
            [string]$receipt.coreSha256 -ceq
                'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB' -and
            [string]$receipt.veqSha256 -ceq
                'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9' -and
            [string]$receipt.masterSha256 -ceq
                '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90') `
        'The reset receipt exact APK/Core/VEQ/master hashes drifted.'
    Require ([string]$receipt.worldLevelDatSha256 -ceq
                '42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065' -and
            [string]$receipt.worldResetActivationReceipt -ceq
                'QC_RC8_WORLD_RESET:PASS:42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065:100:26') `
        'The reset receipt did not bind the verified world activation result.'
    Require ([string]$receipt.originalSnapshotState -ceq 'SNAPSHOT' -and
            [string]$receipt.originalSnapshotSha256 -ceq ('A' * 64) -and
            [string]$receipt.masterCache -ceq $ExpectedMasterCache) `
        'The reset receipt snapshot/cache evidence was invalid.'
    Require ([bool]$receipt.stableStoppedAtAllFences -and
            [bool]$receipt.labStoppedAtAllFences -and
            [bool]$receipt.backupVerifiedBeforeSwap -and
            [bool]$receipt.canaryMarkerAbsent -and
            [bool]$receipt.usbTransportConfirmed) `
        'The reset receipt omitted a required stopped/backup/marker/USB fence.'
    Require ([string]$receipt.accessMode -ceq $ExpectedAccessMode -and
            [bool]$receipt.rootUsed -eq ($ExpectedAccessMode -ceq 'Root') -and
            -not [bool]$receipt.serialPersisted) `
        'The reset receipt access/root/no-serial contract was invalid.'
    Require (-not ($propertyNames -ccontains 'serial') -and
            -not $raw.Contains('USB123', [StringComparison]::Ordinal)) `
        'The reset receipt persisted the raw device serial.'
    $receiptSha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
    $output = $Result.Lines -join "`n"
    Require ($output -match "(?m)^ResetRunId\s*:\s*$runId\s*$" -and
            $output -match "(?m)^CompletedAtUtc\s*:\s*$([regex]::Escape($completedText))\s*$" -and
            $output -match "(?m)^ResetProducerSha256\s*:\s*$expectedProducer\s*$" -and
            $output -match "(?m)^ReceiptSha256\s*:\s*$receiptSha\s*$" -and
            $output -match "(?m)^ReceiptFileName\s*:\s*$([regex]::Escape([IO.Path]::GetFileName($path)))\s*$" -and
            $output -match "(?m)^AccessMode\s*:\s*$ExpectedAccessMode\s*$" -and
            $output -match "(?m)^RootUsed\s*:\s*$(if ($ExpectedAccessMode -ceq 'Root') { 'True' } else { 'False' })\s*$" -and
            $output -match '(?m)^HostWrites\s*:\s*1\s*$') `
        'The successful reset output did not bind its durable receipt metadata.'
    $receipt
}

function Assert-NoMutation([string] $Context) {
    $text = Get-LogText
    $mutating = $text -match
        'QC_RC8_SNAPSHOT_CREATE|QC_RC8_WORLD_STAGE_AND_SWAP|"push"|"mkdir"|"mv"'
    Require (-not $mutating) "$Context reached a device mutation command."
}

function Assert-Failed([Parameter(Mandatory)] $Result, [string] $Context) {
    $script:failureScenarios++
    Require ($Result.ExitCode -ne 0) "$Context unexpectedly succeeded."
    if ($Result.PSObject.Properties.Name -ccontains 'ReceiptPath') {
        Require (-not (Test-Path -LiteralPath ([string]$Result.ReceiptPath))) `
            "$Context wrote a reset receipt despite failing."
    }
}

$fakeSource = @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]] $FakeArgs)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$encodedArgs = [string]$env:QC_FAKE_ARGS_B64
if (-not [string]::IsNullOrEmpty($encodedArgs)) {
    $decodedArgs = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($encodedArgs))
    $FakeArgs = @($decodedArgs.Split([char]0))
}
$scenario = [string]$env:QC_FAKE_ADB_SCENARIO
$log = [string]$env:QC_FAKE_ADB_LOG
$state = [string]$env:QC_FAKE_ADB_STATE
$apk = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$core = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$veq = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$master = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$level = '42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065'
$snapshot = ('A' * 64)
$package = 'com.qcxr.qcxr.canary262'
$stable = 'com.qcxr.qcxr.dev262'
$files = "/storage/emulated/0/Android/data/$package/files"
$game = "$files/instances/26.2"
$stdin = [Console]::In.ReadToEnd().Replace("`r`n", "`n").Replace("`r", "`n")
$invocation = [pscustomobject][ordered]@{
    Args = @($FakeArgs)
    StandardInput = $stdin
}
[IO.File]::AppendAllText($log, (($invocation | ConvertTo-Json -Compress) + "`n"))
$out = [Collections.Generic.List[string]]::new()
$code = 0
$joined = $FakeArgs -join ' '

if ($FakeArgs.Count -eq 2 -and $FakeArgs[0] -ceq 'devices' -and $FakeArgs[1] -ceq '-l') {
    $out.Add('List of devices attached')
    $out.Add('USB123 device usb:1-1 product:eureka model:Quest_3 transport_id:1')
    $out.Add('192.0.2.10:5555 device product:eureka model:Quest_3 transport_id:2')
    $out.Add('adb-USB123._adb-tls-connect._tcp device product:eureka model:Quest_3 transport_id:4')
    if ($scenario -ceq 'duplicate-usb') {
        $out.Add('USB123 device product:eureka model:Quest_3 transport_id:3')
    }
} elseif ($FakeArgs.Count -ge 3 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[2] -ceq 'get-state') {
    if ($FakeArgs[1] -ceq 'USB123' -or $FakeArgs[1] -ceq '192.0.2.10:5555' -or
            $FakeArgs[1] -ceq 'adb-USB123._adb-tls-connect._tcp') {
        $out.Add('device')
    } else { $code = 1 }
} elseif ($FakeArgs.Count -ge 4 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[2] -ceq 'push') {
    if ($scenario -notmatch '^(?:success-cache-missing|root-required-cache-missing)') { $code = 91 }
    else {
        [IO.File]::AppendAllText($state, "cache-stage`n")
        $out.Add('58186240 bytes in 0.1s')
    }
} elseif ($FakeArgs.Count -ge 4 -and $FakeArgs[0] -ceq '-s' -and
        $FakeArgs[2] -ceq 'shell') {
    $shell = @($FakeArgs[3..($FakeArgs.Count - 1)])
    $command = $shell -join ' '
    $rootStdin = $shell.Count -eq 3 -and
        $shell[0] -ceq '/debug_ramdisk/su' -and
        $shell[1] -ceq '-c' -and $shell[2] -ceq 'sh'
    if ($rootStdin) {
        $command = $stdin
        $simpleRootCommand = $command.TrimEnd([char[]]@("`r", "`n"))
        if ($simpleRootCommand -cmatch "^'[^'\r\n]+'(?: '[^'\r\n]+')*$") {
            $shell = @($simpleRootCommand.Substring(
                1, $simpleRootCommand.Length - 2).Split("' '"))
        }
    }
    if ($shell.Count -eq 1 -and $command.StartsWith('sh -c ', [StringComparison]::Ordinal)) {
        $encoded = $command.Substring(6)
        if ($encoded.Length -ge 2 -and $encoded[0] -eq [char]39 -and
                $encoded[$encoded.Length - 1] -eq [char]39) {
            $quoteEscape = [string][char]39 + '"' + [string][char]39 + '"' + [string][char]39
            $command = $encoded.Substring(1, $encoded.Length - 2).Replace(
                $quoteEscape, [string][char]39)
        }
    }
    if ($shell.Count -eq 3 -and $shell[0] -ceq 'test' -and
            $shell[1] -ceq '-x' -and $shell[2] -ceq '/debug_ramdisk/su') {
        if ($scenario -ceq 'root-unavailable') { $code = 1 }
    } elseif ($shell.Count -eq 4 -and $shell[0] -ceq 'test' -and
            $shell[1] -ceq '!' -and $shell[2] -ceq '-e' -and
            $shell[3] -cmatch '^/data/local/tmp/qc-rc8-route-master-[0-9a-f]{32}\.tar$') {
        # Fresh bounded upload stage.
    } elseif ($shell.Count -eq 2 -and $shell[0] -ceq 'pidof') {
        if ($shell[1] -ceq $stable -and $scenario -ceq 'stable-running') {
            $out.Add('4100')
        } elseif ($shell[1] -ceq $package -and $scenario -ceq 'lab-running') {
            $out.Add('4200')
        } else { $code = 1 }
    } elseif ($shell.Count -eq 2 -and $shell[0] -ceq 'getprop' -and
            $shell[1] -ceq 'ro.serialno') {
        $out.Add('USB123')
    } elseif ($shell.Count -eq 3 -and $shell[0] -ceq 'dumpsys' -and
            $shell[1] -ceq 'package' -and $shell[2] -ceq $package) {
        $out.Add('  versionCode=' + $(if ($scenario -ceq 'wrong-version') { '70' } else { '71' }) + ' minSdk=29 targetSdk=34')
        $out.Add('  versionName=' + $(if ($scenario -ceq 'wrong-version') { 'wrong' } else { '6.0.1-26.2-vivecraft-personal.12-rc.8' }))
    } elseif ($shell.Count -eq 3 -and $shell[0] -ceq 'pm' -and
            $shell[1] -ceq 'path' -and $shell[2] -ceq $package) {
        if ($scenario -ceq 'wrong-base-path') {
            $out.Add('package:/data/app/~~token/com.qcxr.qcxr.dev262-token/base.apk')
        } else {
            $out.Add('package:/data/app/~~token/com.qcxr.qcxr.canary262-token/base.apk')
        }
    } elseif ($command.Contains('QC_RC8_HASH_PROBE')) {
        $pathMatch = [regex]::Match($command, "(?m)^path='(?<path>[^']+)'\r?$")
        if (-not $pathMatch.Success) { $code = 96 }
        else {
            $path = [string]$pathMatch.Groups['path'].Value
            if ($scenario -ceq 'core-symlink' -and
                    $path -match '/mods/Vivecraft\.jar$') {
                $out.Add('INVALID_SYMLINK')
            } elseif ($scenario -ceq 'master-cache-symlink' -and
                    $path -match 'route-master-[0-9A-F]{64}\.tar$') {
                $out.Add('INVALID_SYMLINK')
            } elseif ($path -match '/base\.apk$') {
                $hash = if ($scenario -ceq 'wrong-apk') { '0' * 64 } else { $apk }
                $out.Add("$hash  $path")
            } elseif ($path -match '/mods/Vivecraft\.jar$') {
                $hash = if ($scenario -ceq 'wrong-core') { '1' * 64 } else { $core }
                $out.Add("$hash  $path")
            } elseif ($path -match '/mods/Vivecraft-Essentials-Quest\.jar$') {
                $hash = if ($scenario -ceq 'wrong-veq') { '2' * 64 } else { $veq }
                $out.Add("$hash  $path")
            } elseif ($path -match '/\.questcraft/questcraft-vivecraft-core-canary-v9/request\.json$') {
                if ($scenario -ceq 'marker-present') { $out.Add((('4' * 64) + "  $path")) }
                else { $out.Add('MISSING') }
            } elseif ($path -match '(?:route-master-[0-9A-F]{64}\.tar\.part-|/data/local/tmp/qc-rc8-route-master-[0-9a-f]{32}\.tar$)') {
                $out.Add("$master  $path")
            } elseif ($path -match 'route-master-[0-9A-F]{64}\.tar$') {
                $cacheReady = (Test-Path -LiteralPath $state) -and
                    ([IO.File]::ReadAllText($state).Contains('cache-ready'))
                if ($scenario -match '^(?:success-cache-missing|root-required-cache-missing)' -and -not $cacheReady) {
                    $out.Add('MISSING')
                } else {
                    $hash = if ($scenario -ceq 'wrong-master-cache') { '3' * 64 } else { $master }
                    $out.Add("$hash  $path")
                }
            } else { $code = 92 }
        }
    } elseif ($shell.Count -eq 2 -and $shell[0] -ceq 'realpath') {
        if ($shell[1] -match '/files$') {
            if ($scenario -ceq 'wrong-files-path') {
                $out.Add("/data/local/tmp/Android/data/$package/files")
            } else { $out.Add($files) }
        }
        elseif ($shell[1] -match '/instances/26\.2/saves$') {
            if ($scenario -ceq 'saves-symlink') { $out.Add("$files/escaped-saves") }
            else { $out.Add("$game/saves") }
        }
        elseif ($shell[1] -match '/instances/26\.2$') {
            if ($scenario -ceq 'wrong-profile-path') { $out.Add("$files/instances/wrong") }
            else { $out.Add($game) }
        } else { $code = 93 }
    } elseif ($command.Contains('QC_RC8_WORLD_ACCESS_PROBE')) {
        if ($scenario -ceq 'root-unavailable') { $code = 11 }
        elseif ($scenario -like 'root-required*' -and -not $rootStdin) { $code = 11 }
        else { $out.Add('QC_RC8_WORLD_ACCESS_OK:PRESENT') }
    } elseif ($command.Contains('QC_RC8_MASTER_CACHE_PUBLISH')) {
        [IO.File]::AppendAllText($state, "cache-ready`n")
        $out.Add("QC_RC8_MASTER_CACHE_PUBLISHED:$master")
    } elseif ($command.Contains('rm -f -- "$stage"') -and
            $command.Contains('/data/local/tmp/qc-rc8-route-master-')) {
        # Bounded post-publication upload cleanup; stage is already absent.
    } elseif ($command.Contains('QC_RC8_WORLD_PROBE')) {
        if ($scenario -ceq 'world-invalid') { $out.Add('INVALID_LAYOUT') }
        else { $out.Add("PRESENT:$level") }
    } elseif ($command.Contains('QC_RC8_SNAPSHOT_PROBE')) {
        $created = (Test-Path -LiteralPath $state) -and
            ([IO.File]::ReadAllText($state).Contains('snapshot-created'))
        if ($scenario -ceq 'state-root-invalid') {
            $out.Add('INVALID_PARENT')
        } elseif ($scenario -ceq 'snapshot-mismatch') {
            $out.Add(('SNAPSHOT:' + ('A' * 64) + ':' + ('B' * 64)))
        } elseif ($scenario -cin @('unsafe-snapshot', 'safe-snapshot',
                'promote-failure-restored', 'rollback-restore-blocked')) {
            $out.Add("SNAPSHOT:${snapshot}:${snapshot}")
        } elseif ($created) {
            $out.Add("SNAPSHOT:${snapshot}:${snapshot}")
        } else { $out.Add('UNINITIALIZED') }
    } elseif ($shell.Count -eq 3 -and $shell[0] -ceq 'tar' -and
            $shell[1] -ceq '-tf') {
        if ($scenario -ceq 'unsafe-snapshot') {
            $out.Add('FPS-Stress-Test/')
            $out.Add('FPS-Stress-Test/../escape')
            $out.Add('FPS-Stress-Test/level.dat')
        } else {
            $out.Add('FPS-Stress-Test/')
            $out.Add('FPS-Stress-Test/level.dat')
        }
    } elseif ($shell.Count -eq 3 -and $shell[0] -ceq 'tar' -and
            $shell[1] -ceq '-tvf') {
        $out.Add('drwxrws--- 0 owner group 0 Jan 01 00:00 FPS-Stress-Test/')
        $out.Add('-rw-rw---- 0 owner group 1 Jan 01 00:00 FPS-Stress-Test/level.dat')
    } elseif ($command.Contains('QC_RC8_SNAPSHOT_CREATE')) {
        [IO.File]::AppendAllText($state, "snapshot-created`n")
        $out.Add("QC_RC8_SNAPSHOT_CREATED:SNAPSHOT:$snapshot")
    } elseif ($shell.Count -eq 3 -and $shell[0] -ceq 'test' -and
            $shell[1] -ceq '-d') {
        # Tool-owned state root established by the immutable snapshot contract.
    } elseif ($shell.Count -eq 3 -and $shell[0] -ceq 'mv' -and
            $shell[2] -match 'route-master-[0-9A-F]{64}\.tar$') {
        [IO.File]::AppendAllText($state, "cache-ready`n")
    } elseif ($command.Contains('QC_RC8_WORLD_STAGE_AND_SWAP')) {
        $hasRestoreFence = $command.Contains('restore_rollback_or_fail()') -and
            $command.Contains('test ! -e "$world" && test ! -L "$world" || fail rollback-destination-occupied') -and
            $command.Contains('rollback-destination-occupied') -and
            $command.Contains('rollback-source-hash') -and
            $command.Contains('rollback-restored-hash') -and
            $command.Contains('then restore_rollback_or_fail 64; fi') -and
            $command.Contains('cleanup-rollback-hash') -and
            -not $command.Contains('|| true') -and
            -not $command.Contains('failed_promoted')
        if (-not $hasRestoreFence) { $code = 97 }
        elseif ($scenario -ceq 'promote-failure-restored') {
            [IO.File]::AppendAllText($state, "rollback-restored-and-verified`n")
            $out.Add('QC_RC8_RESET_FAIL:promote-staged-world')
            $code = 60
        } elseif ($scenario -ceq 'rollback-restore-blocked') {
            [IO.File]::AppendAllText($state, "rollback-preserved-destination-untouched`n")
            $out.Add('QC_RC8_RESET_FAIL:rollback-destination-occupied')
            $code = 64
        } else {
            $out.Add("QC_RC8_WORLD_RESET:PASS:${level}:100:26")
        }
    } else { $code = 94 }
} else { $code = 95 }

$out | ForEach-Object { Write-Output $_ }
exit $code
'@

$fakeForwarderSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class QcRc8FakeAdbForwarder
{
    public static int Main(string[] args)
    {
        string pwsh = Environment.GetEnvironmentVariable("QC_FAKE_PWSH");
        string script = Environment.GetEnvironmentVariable("QC_FAKE_ADB_SCRIPT");
        if (String.IsNullOrEmpty(pwsh) || String.IsNullOrEmpty(script)) return 120;
        var psi = new ProcessStartInfo {
            FileName = pwsh,
            Arguments = "-NoProfile -File \"" + script.Replace("\"", "\\\"") + "\"",
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        string joined = String.Join("\0", args);
        psi.EnvironmentVariables["QC_FAKE_ARGS_B64"] = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(joined));
        using (Process process = Process.Start(psi)) {
            if (process == null) return 121;
            string input = Console.In.ReadToEnd();
            process.StandardInput.Write(input);
            process.StandardInput.Close();
            string output = process.StandardOutput.ReadToEnd();
            string error = process.StandardError.ReadToEnd();
            process.WaitForExit();
            Console.Out.Write(output);
            Console.Error.Write(error);
            return process.ExitCode;
        }
    }
}
'@

try {
    [IO.File]::WriteAllText($fakeAdbScript, $fakeSource, [Text.UTF8Encoding]::new($false))
    $env:QC_FAKE_PWSH = $pwsh
    $env:QC_FAKE_ADB_SCRIPT = $fakeAdbScript
    [IO.File]::WriteAllText($fakeForwarderPath, $fakeForwarderSource,
        [Text.UTF8Encoding]::new($false))
    $csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Require (Test-Path -LiteralPath $csc -PathType Leaf) `
        'The Host fake-ADB compiler is unavailable.'
    $compilerRows = @(& $csc /nologo /target:exe "/out:$fakeAdb" $fakeForwarderPath 2>&1 |
        ForEach-Object { [string]$_ })
    Require ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fakeAdb -PathType Leaf)) `
        ('The Host fake-ADB forwarder did not compile: ' + ($compilerRows -join ' | '))
    $parseTokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $fakeAdbScript, [ref]$parseTokens, [ref]$parseErrors)
    Require (@($parseErrors).Count -eq 0) `
        ('The fake ADB fixture did not parse: ' +
            (@($parseErrors | ForEach-Object {
                "line $($_.Extent.StartLineNumber): $($_.Message) [$($_.Extent.Text)]"
            }) -join '; '))

    Reset-Fixture 'default'
    $self = Invoke-Gate @('-Action', 'SelfTest')
    Require ($self.ExitCode -eq 0 -and ($self.Lines -join "`n") -match 'PASS') `
        'SelfTest failed.'
    Require (-not (Test-Path -LiteralPath $log)) 'SelfTest invoked fake ADB.'

    Reset-Fixture 'default'
    $status = Invoke-Gate @('-Action', 'Status', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-ConfirmExactRc8Lab')
    Require ($status.ExitCode -eq 0 -and ($status.Lines -join "`n") -match 'ExactRc8Identity\s*:\s*True') `
        ('Explicit USB Status failed while a Wi-Fi endpoint was also listed: ' +
            ($status.Lines -join ' | '))
    Assert-NoMutation 'Read-only Status'

    Reset-Fixture 'root-required-cache-missing'
    $rootDenied = Invoke-Gate @('-Action', 'Status', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-ConfirmExactRc8Lab')
    Assert-Failed $rootDenied 'Root-required Status without explicit authorization'
    Assert-NoMutation 'Root-required Status without explicit authorization'

    Reset-Fixture 'root-unavailable'
    $rootUnavailable = Invoke-Gate @('-Action', 'Status', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-ConfirmExactRc8Lab',
        '-AllowRootFallback')
    Assert-Failed $rootUnavailable 'Unavailable fixed root entrypoint'
    Assert-NoMutation 'Unavailable fixed root entrypoint'

    Reset-Fixture 'root-required'
    $rootStatus = Invoke-Gate @('-Action', 'Status', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-ConfirmExactRc8Lab',
        '-AllowRootFallback')
    Require ($rootStatus.ExitCode -eq 0 -and
            ($rootStatus.Lines -join "`n") -match 'AccessMode\s*:\s*Root' -and
            ($rootStatus.Lines -join "`n") -match 'RootUsed\s*:\s*True') `
        ('Authorized root read-only Status failed: ' + ($rootStatus.Lines -join ' | '))
    Assert-NoMutation 'Authorized root read-only Status'
    $rootStatusCalls = Get-LogText
    Require ($rootStatusCalls.Contains('/debug_ramdisk/su',
                [StringComparison]::Ordinal) -and
            -not $rootStatusCalls.Contains('su -c',
                [StringComparison]::Ordinal)) `
        'The root read path did not use the fixed stdin transport.'

    Reset-Fixture 'default'
    $auto = Invoke-Gate @('-Action', 'Status', '-Serial', 'auto', '-AdbPath', $fakeAdb,
        '-AllowDeviceRead', '-ConfirmExactRc8Lab')
    Assert-Failed $auto 'Ambiguous auto selection'
    Assert-NoMutation 'Ambiguous auto selection'

    Reset-Fixture 'default'
    $missing = Invoke-Gate @('-Action', 'Status', '-Serial', 'MISSING', '-AdbPath', $fakeAdb,
        '-AllowDeviceRead', '-ConfirmExactRc8Lab')
    Assert-Failed $missing 'Missing explicit serial'
    Assert-NoMutation 'Missing explicit serial'

    Reset-Fixture 'duplicate-usb'
    $duplicate = Invoke-Gate @('-Action', 'Status', '-Serial', 'USB123', '-AdbPath', $fakeAdb,
        '-AllowDeviceRead', '-ConfirmExactRc8Lab')
    Assert-Failed $duplicate 'Duplicate explicit serial'
    Assert-NoMutation 'Duplicate explicit serial'

    Reset-Fixture 'default'
    $missingOutput = Invoke-Gate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab', '-AllowHostOutput')
    Assert-Failed $missingOutput 'Reset without a receipt output path'
    Require (-not (Test-Path -LiteralPath $log)) `
        'Reset without a receipt output path contacted fake ADB.'

    Reset-Fixture 'default'
    $noHostOutputPath = New-ReceiptPath
    $noHostOutput = Invoke-Gate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab', '-OutputJson', $noHostOutputPath)
    $noHostOutput | Add-Member -NotePropertyName ReceiptPath `
        -NotePropertyValue $noHostOutputPath
    Assert-Failed $noHostOutput 'Reset without Host-output authorization'
    Require (-not (Test-Path -LiteralPath $log)) `
        'Reset without Host-output authorization contacted fake ADB.'

    Reset-Fixture 'default'
    $escapedReceipt = Join-Path $tempFull 'reset-01.json'
    $escapedOutput = Invoke-Gate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab', '-OutputJson', $escapedReceipt, '-AllowHostOutput')
    $escapedOutput | Add-Member -NotePropertyName ReceiptPath -NotePropertyValue $escapedReceipt
    Assert-Failed $escapedOutput 'Reset receipt path outside the artifact root'
    Require (-not (Test-Path -LiteralPath $log)) `
        'An escaped reset receipt path contacted fake ADB.'

    Reset-Fixture 'default'
    $badNameReceipt = Join-Path $receiptTestRoot 'wrong.json'
    $badNameOutput = Invoke-Gate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab', '-OutputJson', $badNameReceipt, '-AllowHostOutput')
    $badNameOutput | Add-Member -NotePropertyName ReceiptPath -NotePropertyValue $badNameReceipt
    Assert-Failed $badNameOutput 'Reset receipt with a non-campaign filename'
    Require (-not (Test-Path -LiteralPath $log)) `
        'A non-campaign reset receipt path contacted fake ADB.'

    Reset-Fixture 'default'
    $noWrite = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123', '-AdbPath', $fakeAdb,
        '-AllowDeviceRead', '-ConfirmExactRc8Lab')
    Assert-Failed $noWrite 'Reset without write authorization'
    Require (-not (Test-Path -LiteralPath $log)) `
        'Reset without write authorization contacted fake ADB.'

    Reset-Fixture 'default'
    $wifiWrite = Invoke-ResetGate @('-Action', 'Reset', '-Serial', '192.0.2.10:5555',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite', '-ConfirmExactRc8Lab')
    Assert-Failed $wifiWrite 'Reset through Wi-Fi serial'
    Require (-not (Test-Path -LiteralPath $log)) `
        'Rejected Wi-Fi reset contacted fake ADB.'

    Reset-Fixture 'default'
    $mdnsWrite = Invoke-ResetGate @('-Action', 'Reset',
        '-Serial', 'adb-USB123._adb-tls-connect._tcp', '-AdbPath', $fakeAdb,
        '-AllowDeviceRead', '-AllowDeviceWrite', '-ConfirmExactRc8Lab')
    Assert-Failed $mdnsWrite 'Reset through mDNS Wi-Fi serial'
    Assert-NoMutation 'Reset through mDNS Wi-Fi serial'

    foreach ($scenario in @('stable-running', 'wrong-version', 'wrong-base-path',
            'wrong-apk', 'wrong-core', 'wrong-veq', 'core-symlink',
            'wrong-files-path', 'wrong-profile-path', 'saves-symlink',
            'world-invalid', 'lab-running', 'snapshot-mismatch', 'unsafe-snapshot',
            'state-root-invalid', 'wrong-master-cache', 'master-cache-symlink',
            'marker-present')) {
        Reset-Fixture $scenario
        $result = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123',
            '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
            '-ConfirmExactRc8Lab')
        Assert-Failed $result "Failure scenario $scenario"
        Assert-NoMutation "Failure scenario $scenario"
    }

    Reset-Fixture 'promote-failure-restored'
    $promoteFailure = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab')
    Assert-Failed $promoteFailure 'Promote failure after verified rollback restoration'
    Require ((Get-Content -Raw -LiteralPath $state).Contains(
            'rollback-restored-and-verified', [StringComparison]::Ordinal)) `
        'The modeled promote failure did not restore and verify the rollback.'
    $promoteFailureCalls = Get-LogText
    Require ($promoteFailureCalls.Contains('restore_rollback_or_fail()',
                [StringComparison]::Ordinal) -and
            -not $promoteFailureCalls.Contains('|| true',
                [StringComparison]::Ordinal) -and
            -not $promoteFailureCalls.Contains('failed_promoted',
                [StringComparison]::Ordinal)) `
        'The rollback transaction still contains an unverified or quarantining path.'

    Reset-Fixture 'rollback-restore-blocked'
    $rollbackBlocked = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab')
    Assert-Failed $rollbackBlocked 'Rollback restore with an occupied destination'
    Require ((Get-Content -Raw -LiteralPath $state).Contains(
            'rollback-preserved-destination-untouched', [StringComparison]::Ordinal)) `
        'An occupied rollback destination was not modeled as fail-closed.'

    Reset-Fixture 'root-required-cache-missing'
    $rootStartedAtUtc = [DateTimeOffset]::UtcNow
    $rootReset = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab', '-AllowRootFallback')
    $rootEndedAtUtc = [DateTimeOffset]::UtcNow
    Require ($rootReset.ExitCode -eq 0 -and
            ($rootReset.Lines -join "`n") -match 'Result\s*:\s*RESET' -and
            ($rootReset.Lines -join "`n") -match 'AccessMode\s*:\s*Root' -and
            ($rootReset.Lines -join "`n") -match 'RootUsed\s*:\s*True') `
        ('The root stdin reset fixture failed: ' + ($rootReset.Lines -join ' | ') +
            ' CALLS=' + (Get-LogText))
    $rootResetCalls = Get-LogText
    Require ($rootResetCalls.Contains('QC_RC8_SNAPSHOT_CREATE',
                [StringComparison]::Ordinal) -and
            $rootResetCalls.Contains('QC_RC8_WORLD_STAGE_AND_SWAP',
                [StringComparison]::Ordinal) -and
            $rootResetCalls.Contains('/debug_ramdisk/su',
                [StringComparison]::Ordinal)) `
        'The root fixture did not carry the exact transaction through stdin.'
    $rootReceipt = Assert-ResetReceipt -Result $rootReset `
        -StartedAtUtc $rootStartedAtUtc -EndedAtUtc $rootEndedAtUtc `
        -ExpectedAccessMode Root -ExpectedMasterCache CREATED
    $rootStage = "/data/local/tmp/qc-rc8-route-master-$($rootReceipt.resetRunId).tar"
    $rootCache = "/storage/emulated/0/Android/data/com.qcxr.qcxr.canary262/files/.questcraft-benchmark-rc8/route-master-$($rootReceipt.masterSha256).tar"
    $rootRecords = @(Get-LogRecords)
    $snapshotIndex = -1
    $stageAbsentIndex = -1
    $pushIndex = -1
    $stageHashIndex = -1
    $publishIndex = -1
    $cleanupIndex = -1
    $cacheHashAfterIndex = -1
    for ($i = 0; $i -lt $rootRecords.Count; $i++) {
        $args = @($rootRecords[$i].Args)
        $input = [string]$rootRecords[$i].StandardInput
        if ($input.Contains('QC_RC8_SNAPSHOT_CREATE', [StringComparison]::Ordinal)) {
            $snapshotIndex = $i
        }
        if ($args.Count -eq 7 -and $args[0] -ceq '-s' -and
                $args[1] -ceq 'USB123' -and $args[2] -ceq 'shell' -and
                $args[3] -ceq 'test' -and $args[4] -ceq '!' -and
                $args[5] -ceq '-e' -and $args[6] -ceq $rootStage) {
            $stageAbsentIndex = $i
        }
        if ($args.Count -eq 5 -and $args[0] -ceq '-s' -and
                $args[1] -ceq 'USB123' -and $args[2] -ceq 'push') {
            Require ($pushIndex -eq -1) 'The root cache path used more than one ADB push.'
            $pushIndex = $i
            Require ([string]$args[4] -ceq $rootStage -and
                    -not ([string]$args[4]).Contains('/Android/data/',
                        [StringComparison]::Ordinal) -and
                    -not ([string]$args[4]).Contains('.questcraft-benchmark-rc8',
                        [StringComparison]::Ordinal)) `
                'The root cache upload did not target only its bounded /data/local/tmp stage.'
        }
        if ($input.Contains('QC_RC8_HASH_PROBE', [StringComparison]::Ordinal) -and
                $input.Contains("path='$rootStage'", [StringComparison]::Ordinal)) {
            $stageHashIndex = $i
        }
        if ($input.Contains('QC_RC8_MASTER_CACHE_PUBLISH', [StringComparison]::Ordinal)) {
            $publishIndex = $i
            Require ($input.Contains("stage='$rootStage'", [StringComparison]::Ordinal) -and
                    $input.Contains("cache='$rootCache'", [StringComparison]::Ordinal) -and
                    $input.Contains('test ! -e "$cache" && test ! -L "$cache"',
                        [StringComparison]::Ordinal) -and
                    $input.Contains('mv "$stage" "$cache"', [StringComparison]::Ordinal)) `
                'The root publication transaction did not bind the exact stage/cache targets.'
        }
        if ($input.Contains("stage='$rootStage'", [StringComparison]::Ordinal) -and
                $input.Contains('rm -f -- "$stage"', [StringComparison]::Ordinal)) {
            $cleanupIndex = $i
        }
        if ($i -gt $cleanupIndex -and $cleanupIndex -ge 0 -and
                $input.Contains('QC_RC8_HASH_PROBE', [StringComparison]::Ordinal) -and
                $input.Contains("path='$rootCache'", [StringComparison]::Ordinal)) {
            $cacheHashAfterIndex = $i
        }
    }
    Require ($snapshotIndex -ge 0 -and $stageAbsentIndex -gt $snapshotIndex -and
            $pushIndex -gt $stageAbsentIndex -and $stageHashIndex -gt $pushIndex -and
            $publishIndex -gt $stageHashIndex -and $cleanupIndex -gt $publishIndex -and
            $cacheHashAfterIndex -gt $cleanupIndex) `
        'The root upload did not follow snapshot -> absent probe -> bounded push -> hash -> publish -> cleanup -> verify order.'

    Reset-Fixture 'safe-snapshot'
    $reuseStartedAtUtc = [DateTimeOffset]::UtcNow
    $reuse = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab')
    $reuseEndedAtUtc = [DateTimeOffset]::UtcNow
    Require ($reuse.ExitCode -eq 0 -and ($reuse.Lines -join "`n") -match 'Result\s*:\s*RESET') `
        'A verified existing original snapshot could not be reused.'
    $reuseCalls = Get-LogText
    Require (-not $reuseCalls.Contains('QC_RC8_SNAPSHOT_CREATE',
            [StringComparison]::Ordinal) -and
            $reuseCalls.Contains('QC_RC8_WORLD_STAGE_AND_SWAP',
                [StringComparison]::Ordinal)) `
        'An existing immutable snapshot was unexpectedly replaced.'
    $null = Assert-ResetReceipt -Result $reuse -StartedAtUtc $reuseStartedAtUtc `
        -EndedAtUtc $reuseEndedAtUtc -ExpectedAccessMode Normal `
        -ExpectedMasterCache VERIFIED

    Reset-Fixture 'success-cache-missing'
    $resetStartedAtUtc = [DateTimeOffset]::UtcNow
    $reset = Invoke-ResetGate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab')
    $resetEndedAtUtc = [DateTimeOffset]::UtcNow
    Require ($reset.ExitCode -eq 0 -and ($reset.Lines -join "`n") -match 'Result\s*:\s*RESET') `
        ('The successful fake reset failed: ' + ($reset.Lines -join ' | ') +
            ' CALLS=' + (Get-LogText))
    $calls = Get-LogText
    $snapshotIndex = $calls.IndexOf('QC_RC8_SNAPSHOT_CREATE', [StringComparison]::Ordinal)
    $swapIndex = $calls.IndexOf('QC_RC8_WORLD_STAGE_AND_SWAP', [StringComparison]::Ordinal)
    Require ($snapshotIndex -ge 0 -and $swapIndex -gt $snapshotIndex) `
        'The world swap did not occur strictly after the original snapshot.'
    Require ($calls.Contains('"push"', [StringComparison]::Ordinal)) `
        'The missing-cache fixture did not exercise the verified upload path.'
    Require (-not $calls.Contains('/Android/data/com.qcxr.qcxr.dev262',
            [StringComparison]::Ordinal) -and
            -not $calls.Contains('resourcepacks', [StringComparison]::OrdinalIgnoreCase) -and
            -not $calls.Contains('/account', [StringComparison]::OrdinalIgnoreCase)) `
        'The successful reset command log escaped the Lab world/cache scope.'
    $null = Assert-ResetReceipt -Result $reset -StartedAtUtc $resetStartedAtUtc `
        -EndedAtUtc $resetEndedAtUtc -ExpectedAccessMode Normal `
        -ExpectedMasterCache CREATED

    $resetReceiptHashBefore = (Get-FileHash -LiteralPath $reset.ReceiptPath `
        -Algorithm SHA256).Hash
    Reset-Fixture 'default'
    $overwrite = Invoke-Gate @('-Action', 'Reset', '-Serial', 'USB123',
        '-AdbPath', $fakeAdb, '-AllowDeviceRead', '-AllowDeviceWrite',
        '-ConfirmExactRc8Lab', '-OutputJson', $reset.ReceiptPath, '-AllowHostOutput')
    Assert-Failed $overwrite 'Attempt to overwrite an existing reset receipt'
    Require (-not (Test-Path -LiteralPath $log) -and
            (Get-FileHash -LiteralPath $reset.ReceiptPath -Algorithm SHA256).Hash -ceq
                $resetReceiptHashBefore) `
        'The overwrite rejection contacted fake ADB or changed the existing receipt.'

    $testCompleted = $true
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Assertions = $assertions
        FakeAdbOnly = $true
        RealAdbInvocations = 0
        ExplicitUsbWithWifiEndpoint = 'PASS'
        FailureScenarios = $failureScenarios
        DurableResetReceipts = 3
        RootPushTargetAndOrder = 'PASS'
        RootStdinTransport = 'PASS'
        ExistingSnapshotReuse = 'PASS'
        BackupBeforeSwap = 'PASS'
        CanonicalSavesAncestor = 'PASS'
        VerifiedRollbackRestore = 'PASS'
        OccupiedRollbackDestination = 'PRESERVED'
        StableMutation = $false
        AccountMutation = $false
        ResourcePackMutation = $false
    }
} finally {
    Remove-Item Env:QC_FAKE_ADB_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:QC_FAKE_ADB_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:QC_FAKE_ADB_STATE -ErrorAction SilentlyContinue
    Remove-Item Env:QC_FAKE_PWSH -ErrorAction SilentlyContinue
    Remove-Item Env:QC_FAKE_ADB_SCRIPT -ErrorAction SilentlyContinue
    $resolvedArtifactRoot = [IO.Path]::GetFullPath($artifactRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $resolvedReceiptRoot = [IO.Path]::GetFullPath($receiptTestRoot)
    if ($testCompleted -and (Test-Path -LiteralPath $resolvedReceiptRoot) -and
            $resolvedReceiptRoot.StartsWith(
                $resolvedArtifactRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolvedReceiptRoot).StartsWith(
                'world-reset-host-test-', [StringComparison]::Ordinal)) {
        [IO.Directory]::Delete($resolvedReceiptRoot, $true)
    }
    $resolved = [IO.Path]::GetFullPath($tempFull)
    if ($testCompleted -and $resolved.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved).StartsWith('qc-rc8-world-reset-host-',
                [StringComparison]::Ordinal)) {
        [IO.Directory]::Delete($resolved, $true)
    }
}
