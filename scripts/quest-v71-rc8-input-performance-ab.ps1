#requires -Version 7.0
<#
.SYNOPSIS
Captures and analyzes aggregate-only, exact-RC8 OpenXR-input A/B evidence.

.DESCRIPTION
SelfTest is the default and performs no ADB call. Status and Analyze are
Host-only. Capture is read-only on Quest: it proves the exact RC8 Lab APK and
VEQ, either the exact integrated RC8 core (A) or exact reviewed allocation
candidate (B), renderScaleFactor 1.0, copy batching OFF, Stable stopped, a
focused process identity, and aggregate-only VrApi evidence under QGO Dynamic.
It never installs, launches, stops, roots, or changes an Android file. Analyze
consumes six fresh-process aggregate receipts in the fixed A1-B1 / B2-A2 /
A3-B3 order and compares only overlapping observed refresh-rate strata.
Insufficient refresh overlap, duplicate process identity, or thermal mismatch
fails closed. A passing result is only a Lab performance candidate and never
authorizes Stable promotion.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Status', 'Capture', 'Finalize', 'Analyze')]
    [string] $Action = 'SelfTest',

    [ValidatePattern('^[A-Za-z0-9._-]*$')]
    [string] $Serial = '',

    [string] $AdbPath = 'adb',

    [ValidateRange(10, 300)]
    [int] $Seconds = 180,

    [ValidateRange(1, 6)]
    [int] $SequenceIndex = 1,

    [ValidateSet('', 'A', 'B')]
    [string] $Condition = '',

    [ValidateSet('', '1.0')]
    [string] $DeclaredRenderScale = '',

    [ValidateRange(0, 15)]
    [int] $ExpectedCpuLevel = 8,

    [ValidateRange(0, 15)]
    [int] $ExpectedGpuLevel = 7,

    [string] $OutputDirectory = '',
    [string] $InputDirectory = '',
    [string] $OutputJson = '',

    [ValidateRange(10.0, 100.0)]
    [double] $MinimumOverlapPercentPerArm = 50.0,

    [ValidateRange(6, 300)]
    [int] $MinimumOverlapSamplesPerPair = 24,

    [ValidateRange(1, 30)]
    [int] $MinimumSamplesPerStratum = 3,

    [ValidateRange(0.1, 2.0)]
    [double] $MaximumStartTemperatureDeltaC = 1.0,

    [ValidateRange(0.1, 3.0)]
    [double] $MaximumMatchedTemperatureDeltaC = 1.5,

    [switch] $AllowDeviceRead,
    [switch] $ConfirmExactRc8Lab,
    [switch] $ConfirmQgoDynamic,
    [switch] $AllowRootFallback,
    [switch] $AllowHostOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:BuildLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC8.lock.json'
$script:BenchmarkPath = Join-Path $PSScriptRoot 'quest-vrapi-pid-benchmark.ps1'
$script:WorldResetPath = Join-Path $PSScriptRoot 'quest-v71-rc8-benchmark-world-reset.ps1'
$script:InputCanaryPath = Join-Path $PSScriptRoot 'quest-v71-rc8-input-canary.ps1'
$script:InputLockPath = Join-Path $script:RepoRoot 'RC8_INPUT_AB.lock.json'
$script:ArtifactRoot = Join-Path $script:RepoRoot 'artifacts\v71-rc8-input-performance-ab'
$script:BuildLockSha256 = 'BB5147F0B5B0A3AB5C61D7012A821F0C2583BDE76F96F963C19EDDD967177EF7'
$script:InputLockSha256 = 'BE67D44004FC23B569DA5BD80B6AAC1FD633CED7EAEB78F330B3466A6E7C7F6F'
$script:BenchmarkSha256 = '419672CB4C7D6939A84DB933FE83A5D988249074B1DC2E3EBE891CDFD5684CD5'
$script:WorldResetSha256 = '15B5B5D73D7B6195EA4F69962A510D10E26DDA9A7BC342CA0D6181BFA9B19723'
$script:InputCanarySha256 = '560388F0B659B585AFC7A7318C8505B4A36AF4A29E8390E7670051AE351DA3A5'
$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:VersionCode = 71L
$script:VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.8'
$script:ApkSha256 = 'A8E364630A8BA22853FD8135818DB4E9430FE856305754B1FD6C420E429B2416'
$script:SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:BaselineCoreSha256 = 'ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB'
$script:CandidateCoreSha256 = '9B9C1999E999C4810CA6CECE98BB0D9557939D0326AFEBBCCB58CD4816F216DD'
$script:BaselineCoreVersion = '26.2-1.3.15+qc.v71.rc8-mining'
$script:CandidateCoreVersion = '26.2-1.3.15+qc.v71.rc8-input.1'
$script:VeqSha256 = 'FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9'
$script:WorldMasterSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:WorldLevelDatSha256 = '42446BBE1195E2AFB2BE44FC90600C7ED32750BF0F02D45C0CE505F83AAD9065'
$script:GameDirectory = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:CanonicalGameDirectory =
    "/storage/emulated/0/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:CorePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:ConfigPath = "$($script:GameDirectory)/config/vivecraft-client-config.json"
$script:CanaryMarkerPath = "$($script:GameDirectory)/.questcraft/questcraft-vivecraft-core-canary-v9/request.json"
$script:Order = @('A', 'B', 'B', 'A', 'A', 'B')
$script:RequiredDurationSeconds = 180
$script:RequiredWarmupSeconds = 300
$script:MaximumPreparationAgeSeconds = 900
$script:FixedMinimumOverlapPercentPerArm = 50.0
$script:FixedMinimumOverlapSamplesPerPair = 24
$script:FixedMinimumSamplesPerStratum = 3
$script:FixedMaximumStartTemperatureDeltaC = 1.0
$script:FixedMaximumMatchedTemperatureDeltaC = 1.5
$script:CoreShaByCondition = @{
    A = $script:BaselineCoreSha256
    B = $script:CandidateCoreSha256
}
$script:CoreVersionByCondition = @{
    A = $script:BaselineCoreVersion
    B = $script:CandidateCoreVersion
}
$script:UsbTransportProofMethod = $null
$script:QuestUsbParentPrefix = 'USB\VID_2833&PID_5013\'
$script:Adb = $null
$script:Device = $null
$script:DeviceInvocations = 0
$script:HostWrites = 0
$script:Assertions = 0
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Require([bool] $ConditionValue, [string] $Message) {
    $script:Assertions++
    if (-not $ConditionValue) { throw "[RC8_INPUT_PERF_AB] $Message" }
}

function Test-Throws([Parameter(Mandatory)][scriptblock] $Operation) {
    try { & $Operation; return $false } catch { return $true }
}

function Get-TextSha256([Parameter(Mandatory)][string] $Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))
    } finally { $sha.Dispose() }
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Path) {
    $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n")
    Get-TextSha256 $text
}

function Get-FileSha256([Parameter(Mandatory)][string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function ConvertTo-ShLiteral([Parameter(Mandatory)][string] $Value) {
    $quote = [string][char]39
    $escaped = $quote + '"' + $quote + '"' + $quote
    $quote + $Value.Replace($quote, $escaped) + $quote
}

function Get-StrictBoolean($Value, [string] $Context) {
    Require ($Value -is [bool]) "$Context must be a JSON boolean."
    [bool]$Value
}

function Get-StrictInteger($Value, [string] $Context, [int64] $Minimum = 0,
        [int64] $Maximum = [int64]::MaxValue) {
    Require ($Value -is [ValueType]) "$Context must be a JSON integer."
    [double]$number = 0
    Require ([double]::TryParse([string]$Value,
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$number) -and [double]::IsFinite($number) -and
            $number -ge $Minimum -and $number -le $Maximum) `
        "$Context must be an in-range JSON integer."
    [int64]$number
}

function Get-ExactTimestamp($Value, [string] $Context) {
    if ($Value -is [DateTime]) {
        # PowerShell versions before ConvertFrom-Json -DateKind String eagerly
        # materialize ISO JSON strings. The JSON token was still a string.
        return [DateTimeOffset]([DateTime]$Value)
    }
    Require ($Value -is [string]) "$Context must be an ISO-8601 string."
    [DateTimeOffset]$timestamp = [DateTimeOffset]::MinValue
    Require ([DateTimeOffset]::TryParseExact([string]$Value, 'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$timestamp)) "$Context was not exact round-trip ISO-8601."
    $timestamp
}

function Assert-FixedAnalysisContract {
    Require ($MinimumOverlapPercentPerArm -eq
                $script:FixedMinimumOverlapPercentPerArm -and
            $MinimumOverlapSamplesPerPair -eq
                $script:FixedMinimumOverlapSamplesPerPair -and
            $MinimumSamplesPerStratum -eq
                $script:FixedMinimumSamplesPerStratum -and
            $MaximumStartTemperatureDeltaC -eq
                $script:FixedMaximumStartTemperatureDeltaC -and
            $MaximumMatchedTemperatureDeltaC -eq
                $script:FixedMaximumMatchedTemperatureDeltaC) `
        'The fixed acceptance thresholds cannot be overridden.'
}

function Assert-HostContract {
    Require ($script:Package -ceq 'com.qcxr.qcxr.canary262' -and
            $script:StablePackage -ceq 'com.qcxr.qcxr.dev262' -and
            $script:Package -cne $script:StablePackage) `
        'The fixed Lab/Stable boundary drifted.'
    Require (Test-Path -LiteralPath $script:BuildLockPath -PathType Leaf) `
        'The exact RC8 build lock is missing.'
    Require ((Get-NormalizedTextSha256 $script:BuildLockPath) -ceq
            $script:BuildLockSha256) 'The exact RC8 build lock bytes drifted.'
    $lock = Get-Content -Raw -LiteralPath $script:BuildLockPath | ConvertFrom-Json
    Require ([string]$lock.target.package -ceq $script:Package -and
            [string]$lock.target.forbiddenStablePackage -ceq $script:StablePackage -and
            [string]$lock.target.profile -ceq $script:Profile -and
            [int64]$lock.target.versionCode -eq $script:VersionCode -and
            [string]$lock.target.versionName -ceq $script:VersionName -and
            [string]$lock.target.apkSha256 -ceq $script:ApkSha256 -and
            [string]$lock.target.signerSha256 -ceq $script:SignerSha256 -and
            [string]$lock.pair.core.sha256 -ceq $script:BaselineCoreSha256 -and
            [string]$lock.pair.core.fabricVersion -ceq $script:BaselineCoreVersion -and
            [string]$lock.pair.veq.sha256 -ceq $script:VeqSha256) `
        'The exact RC8 identity lock drifted.'
    Require (Test-Path -LiteralPath $script:InputLockPath -PathType Leaf) `
        'The exact RC8 input A/B lock is missing.'
    Require ((Get-NormalizedTextSha256 $script:InputLockPath) -ceq
            $script:InputLockSha256) 'The exact RC8 input A/B lock bytes drifted.'
    $inputLock = Get-Content -Raw -LiteralPath $script:InputLockPath | ConvertFrom-Json
    Require ([string]$inputLock.target.package -ceq $script:Package -and
            [string]$inputLock.target.forbiddenStablePackage -ceq $script:StablePackage -and
            [string]$inputLock.target.profile -ceq $script:Profile -and
            [int64]$inputLock.target.versionCode -eq $script:VersionCode -and
            [string]$inputLock.target.versionName -ceq $script:VersionName -and
            [string]$inputLock.target.apkSha256 -ceq $script:ApkSha256 -and
            [string]$inputLock.baseline.sha256 -ceq $script:BaselineCoreSha256 -and
            [string]$inputLock.baseline.fabricVersion -ceq $script:BaselineCoreVersion -and
            [string]$inputLock.candidate.sha256 -ceq $script:CandidateCoreSha256 -and
            [string]$inputLock.candidate.fabricVersion -ceq $script:CandidateCoreVersion -and
            [string]$inputLock.companion.sha256 -ceq $script:VeqSha256 -and
            [string]$inputLock.transaction.harnessId -ceq
                'questcraft-vivecraft-core-canary-v9' -and
            [string]$inputLock.transaction.openXrCopyBatchMode -ceq 'OFF') `
        'The exact RC8 input A/B identity contract drifted.'
    Require (Test-Path -LiteralPath $script:BenchmarkPath -PathType Leaf) `
        'The aggregate VrApi benchmark is missing.'
    Require ((Get-NormalizedTextSha256 $script:BenchmarkPath) -ceq
            $script:BenchmarkSha256) 'The aggregate VrApi benchmark bytes drifted.'
    Require (Test-Path -LiteralPath $script:WorldResetPath -PathType Leaf) `
        'The exact RC8 world-reset producer is missing.'
    Require ((Get-NormalizedTextSha256 $script:WorldResetPath) -ceq
            $script:WorldResetSha256) 'The exact RC8 world-reset producer bytes drifted.'
    Require (Test-Path -LiteralPath $script:InputCanaryPath -PathType Leaf) `
        'The exact RC8 input transaction producer is missing.'
    Require ((Get-NormalizedTextSha256 $script:InputCanaryPath) -ceq
            $script:InputCanarySha256) 'The exact RC8 input transaction producer bytes drifted.'
    $canaryArtifact = @($inputLock.hostArtifacts | Where-Object {
        [string]$_.path -ceq 'scripts/quest-v71-rc8-input-canary.ps1'
    })
    Require ($canaryArtifact.Count -eq 1 -and
            [string]$canaryArtifact[0].sha256 -ceq $script:InputCanarySha256) `
        'The input lock did not bind the exact transaction producer.'
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    if ($AdbPath -cne 'adb') { throw '[RC8_INPUT_PERF_AB] Explicit ADB path was not found.' }
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sdk -PathType Leaf) { return $sdk }
    throw '[RC8_INPUT_PERF_AB] ADB was not found.'
}

function Invoke-Adb([string[]] $Arguments, [switch] $AllowFailure) {
    $script:DeviceInvocations++
    $lines = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "[RC8_INPUT_PERF_AB] A read-only ADB probe failed ($exitCode); output suppressed."
    }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Test-ExplicitNonNetworkAdbSerial(
    [AllowNull()][AllowEmptyString()][string] $Candidate
) {
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate -ceq 'auto') {
        return $false
    }
    if ($Candidate -cnotmatch '^[A-Za-z0-9._-]+$' -or $Candidate.Contains(':') -or
            $Candidate.Contains('/') -or $Candidate.Contains('\')) {
        return $false
    }
    if ($Candidate -match '(?i)(?:^adb-|\.local$|_adb(?:-tls)?-connect\._tcp$|_adb\._tcp$)') {
        return $false
    }
    return $true
}

function Read-AdbDeviceRows([Parameter(Mandatory)][string[]] $Lines) {
    @($Lines | ForEach-Object {
        $line = ([string]$_).Trim()
        if ($line -match '^(?<serial>\S+)\s+(?<state>\S+)(?:\s+(?<details>.*))?$' -and
                [string]$Matches.serial -cne 'List') {
            [pscustomobject][ordered]@{
                Serial = [string]$Matches.serial
                State = [string]$Matches.state
                Details = [string]$Matches.details
            }
        }
    })
}

function Get-RecordProperty(
    [Parameter(Mandatory)][object] $Record,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Context
) {
    $property = $Record.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context omitted $Name."
    return $property.Value
}

function Assert-WindowsUsbPnpSnapshot(
    [Parameter(Mandatory)][string] $ExpectedSerial,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Children,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Parents
) {
    Require (Test-ExplicitNonNetworkAdbSerial $ExpectedSerial) `
        'The Windows USB proof received a network-shaped ADB serial.'
    $expectedParent = $script:QuestUsbParentPrefix + $ExpectedSerial
    $validParents = @($Parents | Where-Object {
        $instanceId = [string](Get-RecordProperty $_ 'InstanceId' 'PnP parent')
        $status = [string](Get-RecordProperty $_ 'Status' 'PnP parent')
        $present = Get-RecordProperty $_ 'Present' 'PnP parent'
        $present -is [bool] -and [bool]$present -and $status -ceq 'OK' -and
            $instanceId.Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase)
    })
    Require ($validParents.Count -eq 1) `
        'Windows did not expose one exact present and healthy Quest USB parent.'
    $validChildren = @($Children | Where-Object {
        $instanceId = [string](Get-RecordProperty $_ 'InstanceId' 'PnP child')
        $friendlyName = [string](Get-RecordProperty $_ 'FriendlyName' 'PnP child')
        $status = [string](Get-RecordProperty $_ 'Status' 'PnP child')
        $present = Get-RecordProperty $_ 'Present' 'PnP child'
        $parentInstanceId = [string](Get-RecordProperty $_ 'ParentInstanceId' 'PnP child')
        $present -is [bool] -and [bool]$present -and $status -ceq 'OK' -and
            $instanceId -cmatch '^USB\\' -and
            $friendlyName -match '(?i)(?:^|\s)ADB Interface$' -and
            $parentInstanceId.Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase)
    })
    Require ($validChildren.Count -eq 1) `
        'Windows did not expose one exact present and healthy ADB child of the Quest USB parent.'
    return $true
}

function Get-WindowsUsbPnpSnapshot([Parameter(Mandatory)][string] $ExpectedSerial) {
    Require ($IsWindows) 'Windows PnP USB proof is unavailable on this Host.'
    Require ($null -ne (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) -and
            $null -ne (Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)) `
        'Windows PnP inspection commands are unavailable.'
    $expectedParent = $script:QuestUsbParentPrefix + $ExpectedSerial
    try {
        $pnpDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
        $adbChildren = @($pnpDevices | Where-Object {
            $name = $_.PSObject.Properties['FriendlyName']
            $instance = $_.PSObject.Properties['InstanceId']
            $null -ne $name -and $null -ne $instance -and
                [string]$name.Value -match '(?i)(?:^|\s)ADB Interface$' -and
                [string]$instance.Value -cmatch '^USB\\'
        } | ForEach-Object {
            $child = $_
            $parentProperties = @(Get-PnpDeviceProperty `
                -InstanceId ([string]$child.InstanceId) `
                -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop)
            Require ($parentProperties.Count -eq 1 -and
                    $null -ne $parentProperties[0].PSObject.Properties['Data']) `
                'An ADB child did not expose one PnP parent property.'
            $present = $child.PSObject.Properties['Present']
            [pscustomobject][ordered]@{
                InstanceId = [string]$child.InstanceId
                FriendlyName = [string]$child.FriendlyName
                Status = [string]$child.Status
                Present = if ($null -ne $present) { [bool]$present.Value } else { $true }
                ParentInstanceId = [string]$parentProperties[0].Data
            }
        })
        $parents = @(Get-PnpDevice -PresentOnly -InstanceId $expectedParent `
            -ErrorAction Stop | ForEach-Object {
            $present = $_.PSObject.Properties['Present']
            [pscustomobject][ordered]@{
                InstanceId = [string]$_.InstanceId
                Status = [string]$_.Status
                Present = if ($null -ne $present) { [bool]$present.Value } else { $true }
            }
        })
    } catch {
        throw '[RC8_INPUT_PERF_AB] Windows PnP could not prove the requested USB transport.'
    }
    [pscustomobject][ordered]@{ Children = $adbChildren; Parents = $parents }
}

function Resolve-Device {
    Require (Test-ExplicitNonNetworkAdbSerial $Serial) `
        'Capture requires an explicit USB ADB serial; auto/network selection is forbidden.'
    $script:Adb = Resolve-Adb
    $result = Invoke-Adb @('devices', '-l')
    $matchingRows = @(Read-AdbDeviceRows ([string[]]@($result.Lines)) |
        Where-Object { $_.Serial -ceq $Serial })
    Require ($matchingRows.Count -eq 1 -and $matchingRows[0].State -ceq 'device') `
        'The explicitly requested ADB endpoint is not connected and authorized.'
    $script:Device = $Serial
    $transport = Invoke-Adb @('-s', $script:Device, 'get-devpath')
    $transportRows = @(Get-NonBlankRows ([string[]]$transport.Lines))
    if ($transportRows.Count -eq 1 -and
            $transportRows[0] -cmatch '^usb:[A-Za-z0-9._:/-]+$') {
        $script:UsbTransportProofMethod = 'adb-devpath'
        return
    }
    Require ($IsWindows -and $transportRows.Count -eq 1 -and
            $transportRows[0] -ceq 'unknown') `
        'The explicitly requested endpoint is not a proven USB transport.'
    $serialProbe = Invoke-Adb @('-s', $script:Device, 'shell', 'getprop', 'ro.serialno')
    $serialRows = @(Get-NonBlankRows ([string[]]$serialProbe.Lines))
    Require ($serialRows.Count -eq 1 -and $serialRows[0] -ceq $Serial) `
        'Android did not confirm the exact requested hardware serial.'
    $snapshot = Get-WindowsUsbPnpSnapshot $Serial
    Assert-WindowsUsbPnpSnapshot -ExpectedSerial $Serial `
        -Children ([object[]]@($snapshot.Children)) `
        -Parents ([object[]]@($snapshot.Parents)) | Out-Null
    $script:UsbTransportProofMethod = 'windows-pnp-parent'
}

function Invoke-Shell([string[]] $Arguments, [switch] $AllowFailure) {
    Invoke-Adb (@('-s', $script:Device, 'shell') + $Arguments) `
        -AllowFailure:$AllowFailure
}

function Read-OtherModsFingerprint {
    $qMods = ConvertTo-ShLiteral "$($script:CanonicalGameDirectory)/mods"
    $qCore = ConvertTo-ShLiteral "$($script:CanonicalGameDirectory)/mods/Vivecraft.jar"
    $qVeq = ConvertTo-ShLiteral `
        "$($script:CanonicalGameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
    $command = @"
set -eu
qcpa_mods=$qMods
test -d "`$qcpa_mods" && test ! -L "`$qcpa_mods"
test "`$(cd "`$qcpa_mods" && pwd -P)" = "`$qcpa_mods"
(
  for qcpa_file in "`$qcpa_mods"/*.jar; do
    [ -e "`$qcpa_file" ] || continue
    [ "`$qcpa_file" = $qCore ] && continue
    [ "`$qcpa_file" = $qVeq ] && continue
    test -f "`$qcpa_file" && test ! -L "`$qcpa_file" || exit 69
    qcpa_name=`${qcpa_file##*/}
    printf '%s' "`$qcpa_name" | LC_ALL=C grep -q '[[:cntrl:]]' && exit 70 || true
    qcpa_hash=`$(sha256sum "`$qcpa_file" | awk '{print tolower(`$1)}')
    printf '%s\t%s\n' "`$qcpa_name" "`$qcpa_hash"
  done
) | LC_ALL=C sort | sha256sum | awk '{print "FINGERPRINT\t" toupper(`$1)}'
"@
    $probe = Invoke-Shell @('sh', '-c', $command) -AllowFailure
    $accessMode = 'Normal'
    if ($probe.ExitCode -ne 0 -and $AllowRootFallback.IsPresent) {
        $probe = Invoke-Shell @('su', '-c', $command) -AllowFailure
        $accessMode = 'Root'
    }
    Require ($probe.ExitCode -eq 0) `
        'The exact other-mod fingerprint could not be read in the selected access mode.'
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($rows.Count -eq 1 -and
            $rows[0] -cmatch '^FINGERPRINT\t(?<sha>[0-9A-F]{64})$') `
        'The exact other-mod fingerprint output was ambiguous.'
    [pscustomobject][ordered]@{
        Sha256 = [string]$Matches.sha
        AccessMode = $accessMode
    }
}

function Get-NonBlankRows([string[]] $Lines) {
    @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-StableStopped {
    $probe = Invoke-Shell @('pidof', $script:StablePackage) -AllowFailure
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($probe.ExitCode -eq 1 -and $rows.Count -eq 0) `
        'Stable must be conclusively stopped; it is never stopped by this tool.'
}

function Assert-LabStopped {
    $probe = Invoke-Shell @('pidof', $script:Package) -AllowFailure
    $rows = @(Get-NonBlankRows ([string[]]$probe.Lines))
    Require ($probe.ExitCode -eq 1 -and $rows.Count -eq 0) `
        'Lab must be conclusively stopped before final rollback verification.'
}

function Read-PackageIdentity([string[]] $Lines) {
    $codes = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionCode=(?<v>[0-9]+)(?:\s|$)')
        if ($match.Success) { [int64]$match.Groups['v'].Value }
    })
    $names = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionName=(?<v>\S+)\s*$')
        if ($match.Success) { [string]$match.Groups['v'].Value }
    })
    Require ($codes.Count -eq 1 -and $names.Count -eq 1) `
        'Installed Lab identity was incomplete or ambiguous.'
    [pscustomobject]@{ VersionCode = $codes[0]; VersionName = $names[0] }
}

function Read-BaseApkPath([string[]] $Lines) {
    $rows = @(Get-NonBlankRows $Lines)
    Require ($rows.Count -eq 1 -and $rows[0] -cmatch
        '^package:(?<p>/data/app/(?:[A-Za-z0-9._~+=-]+/)+base\.apk)$') `
        'Installed Lab did not expose one safe base APK.'
    $path = [string]$Matches.p
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)') -and
            -not $path.Contains('/../', [StringComparison]::Ordinal)) `
        'The base APK path was not bound to Lab.'
    $path
}

function Read-RemoteSha256([string] $Path) {
    $result = Invoke-Shell @('sha256sum', $Path)
    $rows = @(Get-NonBlankRows ([string[]]$result.Lines))
    Require ($rows.Count -eq 1) 'A remote digest was ambiguous.'
    $match = [regex]::Match($rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($match.Success -and [string]$match.Groups['path'].Value -ceq $Path) `
        'A remote digest named unexpected data.'
    ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RenderScale {
    $result = Invoke-Shell @('cat', $script:ConfigPath)
    $text = @($result.Lines) -join "`n"
    try { $config = $text | ConvertFrom-Json -Depth 100 } catch {
        throw '[RC8_INPUT_PERF_AB] The Vivecraft configuration was not valid JSON.'
    }
    Require ([regex]::Matches($text,
            '"renderScaleFactor"\s*:',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1) `
        'renderScaleFactor did not occur exactly once in the configuration.'
    $properties = @($config.PSObject.Properties | Where-Object {
        $_.Name -ceq 'renderScaleFactor'
    })
    Require ($properties.Count -eq 1 -and $properties[0].Value -is [string] -and
            [string]$properties[0].Value -ceq '1.0') `
        'renderScaleFactor was missing, duplicated, or not exact 1.0.'
    [string]$properties[0].Value
}

function Read-CanaryMarkerFence([string] $ExpectedCondition) {
    $notLink = Invoke-Shell @('test', '!', '-L', $script:CanaryMarkerPath) -AllowFailure
    Require ($notLink.ExitCode -eq 0 -and
            @(Get-NonBlankRows ([string[]]$notLink.Lines)).Count -eq 0) `
        'The v9 canary marker path must not be a symbolic link.'
    if ($ExpectedCondition -ceq 'A') {
        $absent = Invoke-Shell @('test', '!', '-e', $script:CanaryMarkerPath) -AllowFailure
        Require ($absent.ExitCode -eq 0 -and
                @(Get-NonBlankRows ([string[]]$absent.Lines)).Count -eq 0) `
            'Baseline A requires an absent v9 canary marker.'
        return [pscustomobject][ordered]@{
            State = 'absent'
            RunId = $null
            OpenXrCopyBatchMode = 'OFF'
            OtherModsFingerprintSha256 = $null
        }
    }

    $sizeProbe = Invoke-Shell @('stat', '-c', '%s', $script:CanaryMarkerPath)
    $sizeRows = @(Get-NonBlankRows ([string[]]$sizeProbe.Lines))
    [int64]$size = 0
    Require ($sizeRows.Count -eq 1 -and
            [int64]::TryParse($sizeRows[0], [ref]$size) -and
            $size -gt 0 -and $size -le 16384) `
        'Candidate B marker was missing, ambiguous, or oversized.'
    $markerProbe = Invoke-Shell @('cat', $script:CanaryMarkerPath)
    $raw = @($markerProbe.Lines) -join "`n"
    $expectedFields = @(
        'schemaVersion','harnessId','state','packageName','profile','target','runId',
        'baselineSha256','baselineSizeBytes','candidateSha256','candidateSizeBytes',
        'fabricId','fabricVersion','minecraftDependency','javaDependency',
        'otherModsFingerprintSha256','openXrCopyBatchMode','expiresAtEpochMs','maxLaunches'
    )
    foreach ($field in $expectedFields) {
        Require ([regex]::Matches($raw,
                '"' + [regex]::Escape($field) + '"\s*:',
                [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1) `
            "Candidate B marker omitted or duplicated $field."
    }
    try { $marker = $raw | ConvertFrom-Json -Depth 5 } catch {
        throw '[RC8_INPUT_PERF_AB] Candidate B marker was not valid JSON.'
    }
    $actualFields = @($marker.PSObject.Properties.Name)
    Require ($actualFields.Count -eq $expectedFields.Count -and
            @($actualFields | Where-Object { $expectedFields -cnotcontains $_ }).Count -eq 0) `
        'Candidate B marker contained an unknown field.'
    $markerSchema = Get-StrictInteger $marker.schemaVersion `
        'Candidate B marker schemaVersion' 2 2
    $baselineSize = Get-StrictInteger $marker.baselineSizeBytes `
        'Candidate B marker baselineSizeBytes' 10078822 10078822
    $candidateSize = Get-StrictInteger $marker.candidateSizeBytes `
        'Candidate B marker candidateSizeBytes' 10085812 10085812
    $expiresAt = Get-StrictInteger $marker.expiresAtEpochMs `
        'Candidate B marker expiresAtEpochMs' 1 ([int64]::MaxValue)
    $maxLaunches = Get-StrictInteger $marker.maxLaunches `
        'Candidate B marker maxLaunches' 1 1
    Require ($markerSchema -eq 2 -and
            [string]$marker.harnessId -ceq 'questcraft-vivecraft-core-canary-v9' -and
            [string]$marker.state -ceq 'consumed' -and
            [string]$marker.packageName -ceq $script:Package -and
            [string]$marker.profile -ceq $script:Profile -and
            [string]$marker.target -ceq 'mods/Vivecraft.jar' -and
            [string]$marker.baselineSha256 -ceq $script:BaselineCoreSha256 -and
            $baselineSize -eq 10078822L -and
            [string]$marker.candidateSha256 -ceq $script:CandidateCoreSha256 -and
            $candidateSize -eq 10085812L -and
            [string]$marker.fabricId -ceq 'vivecraft' -and
            [string]$marker.fabricVersion -ceq $script:CandidateCoreVersion -and
            [string]$marker.minecraftDependency -ceq '26.2.x' -and
            [string]$marker.javaDependency -ceq '>=25' -and
            [string]$marker.openXrCopyBatchMode -ceq 'OFF' -and
            $expiresAt -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -and
            $maxLaunches -eq 1) `
        'Candidate B marker did not prove the exact consumed OFF-mode transaction.'
    Require ([string]$marker.runId -cmatch '^[0-9a-f]{32}$' -and
            [string]$marker.otherModsFingerprintSha256 -cmatch '^[0-9A-Fa-f]{64}$') `
        'Candidate B marker contained an invalid run/fingerprint identity.'
    [pscustomobject][ordered]@{
        State = 'consumed'
        RunId = [string]$marker.runId
        OpenXrCopyBatchMode = 'OFF'
        OtherModsFingerprintSha256 =
            ([string]$marker.otherModsFingerprintSha256).ToUpperInvariant()
    }
}

function Read-ProcessFence {
    $pidProbe = Invoke-Shell @('pidof', $script:Package)
    $pidRows = @(Get-NonBlankRows ([string[]]$pidProbe.Lines))
    Require ($pidRows.Count -eq 1 -and $pidRows[0] -cmatch '^[1-9][0-9]*$') `
        'Lab must expose exactly one live process.'
    [int]$appPid = [int]$pidRows[0]
    $statPath = "/proc/$appPid/stat"
    $statProbe = Invoke-Shell @('cat', $statPath)
    $statRows = @(Get-NonBlankRows ([string[]]$statProbe.Lines))
    Require ($statRows.Count -eq 1) 'Lab process start identity was ambiguous.'
    $close = $statRows[0].LastIndexOf(') ', [StringComparison]::Ordinal)
    Require ($close -gt 0) 'Lab process stat framing was malformed.'
    $tail = @($statRows[0].Substring($close + 2).Split(' ',
        [StringSplitOptions]::RemoveEmptyEntries))
    Require ($tail.Count -ge 20 -and $tail[19] -cmatch '^[1-9][0-9]*$') `
        'Lab process start ticks were missing.'
    $clockProbe = Invoke-Shell @('getconf', 'CLK_TCK')
    $clockRows = @(Get-NonBlankRows ([string[]]$clockProbe.Lines))
    [int]$clockTicksPerSecond = 0
    Require ($clockRows.Count -eq 1 -and
            [int]::TryParse($clockRows[0], [ref]$clockTicksPerSecond) -and
            $clockTicksPerSecond -ge 10 -and $clockTicksPerSecond -le 10000) `
        'Android did not expose a safe process clock-tick rate.'
    $uptimeProbe = Invoke-Shell @('cat', '/proc/uptime')
    $uptimeRows = @(Get-NonBlankRows ([string[]]$uptimeProbe.Lines))
    Require ($uptimeRows.Count -eq 1 -and
            $uptimeRows[0] -cmatch '^(?<seconds>[0-9]+(?:\.[0-9]+)?)\s+[0-9]+(?:\.[0-9]+)?$') `
        'Android uptime was missing or malformed.'
    [double]$uptimeSeconds = [double]::Parse([string]$Matches.seconds,
        [Globalization.CultureInfo]::InvariantCulture)
    [double]$processAgeSeconds = $uptimeSeconds -
        ([double]$tail[19] / [double]$clockTicksPerSecond)
    Require ([double]::IsFinite($processAgeSeconds) -and $processAgeSeconds -ge 0) `
        'The Lab process age was impossible.'
    $token = Get-TextSha256 ("pid=$appPid;startTicks=$($tail[19])")
    [pscustomobject][ordered]@{
        Pid = $appPid
        StartTicks = [int64]$tail[19]
        AgeSeconds = $processAgeSeconds
        TokenSha256 = $token
    }
}

function Assert-ExactDeviceIdentity([string] $ExpectedCondition,
        [switch] $StoppedLab) {
    Assert-StableStopped
    $package = Invoke-Shell @('dumpsys', 'package', $script:Package)
    $identity = Read-PackageIdentity ([string[]]$package.Lines)
    Require ($identity.VersionCode -eq $script:VersionCode -and
            $identity.VersionName -ceq $script:VersionName) `
        'Installed application is not exact RC8 Lab.'
    $path = Read-BaseApkPath ([string[]](Invoke-Shell @('pm', 'path', $script:Package)).Lines)
    Require ((Read-RemoteSha256 $path) -ceq $script:ApkSha256) `
        'Installed APK is not exact RC8.'
    $expectedCore = [string]$script:CoreShaByCondition[$ExpectedCondition]
    Require ((Read-RemoteSha256 $script:CorePath) -ceq $expectedCore) `
        "Persistent Core is not exact condition $ExpectedCondition."
    Require ((Read-RemoteSha256 $script:VeqPath) -ceq $script:VeqSha256) `
        'Persistent VEQ is not exact RC8.'
    Require ((Read-RenderScale) -ceq '1.0') `
        'The live render scale is not exact 1.0.'
    $marker = Read-CanaryMarkerFence $ExpectedCondition
    $fingerprint = Read-OtherModsFingerprint
    if ($ExpectedCondition -ceq 'B') {
        Require ([string]$marker.OtherModsFingerprintSha256 -ceq
                [string]$fingerprint.Sha256) `
            'The candidate transaction was not bound to the live other-mod set.'
    }
    $process = if ($StoppedLab) {
        Assert-LabStopped
        $null
    } else {
        Read-ProcessFence
    }
    if ($StoppedLab) {
        Assert-StableStopped
        Assert-LabStopped
    }
    [pscustomobject][ordered]@{
        AllMatched = $true
        StableStopped = $true
        ExpectedCondition = $ExpectedCondition
        CoreSha256 = $expectedCore
        CoreVersion = [string]$script:CoreVersionByCondition[$ExpectedCondition]
        Marker = $marker
        OtherModsFingerprintSha256 = [string]$fingerprint.Sha256
        AccessMode = [string]$fingerprint.AccessMode
        Process = $process
    }
}

function Get-CanonicalPath([string] $Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-NoReparsePath([string] $Path) {
    $root = Get-CanonicalPath $script:RepoRoot
    $full = Get-CanonicalPath $Path
    Require ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) 'A Host path escaped this worktree.'
    $cursor = $root
    $relative = [IO.Path]::GetRelativePath($root, $full)
    foreach ($part in $relative.Split([char[]]@(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            Require (-not ((Get-Item -LiteralPath $cursor -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) 'A Host path contains a reparse point.'
        }
    }
}

function Resolve-ArtifactChild([string] $Path, [switch] $MayBeMissing) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) 'An explicit artifact path is required.'
    $root = Get-CanonicalPath $script:ArtifactRoot
    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        Get-CanonicalPath $Path
    } else { Get-CanonicalPath (Join-Path $script:RepoRoot $Path) }
    Require ($candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) `
        'Artifacts must remain under artifacts/v71-rc8-input-performance-ab.'
    if (-not $MayBeMissing) {
        Require (Test-Path -LiteralPath $candidate) 'The requested artifact path is missing.'
    }
    Assert-NoReparsePath $candidate
    $candidate
}

function Write-JsonAtomic([string] $Path, $Value) {
    Require (-not (Test-Path -LiteralPath $Path)) 'Refusing to overwrite aggregate evidence.'
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    Assert-NoReparsePath $directory
    $temp = $Path + '.next-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp,
            ($Value | ConvertTo-Json -Depth 15), $script:Utf8NoBom)
        [IO.File]::Move($temp, $Path)
        $script:HostWrites++
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { [IO.File]::Delete($temp) }
    }
}

function Read-JsonObjectFile([Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Context) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    Assert-NoReparsePath $Path
    try {
        $json = Get-Content -Raw -LiteralPath $Path
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $json | ConvertFrom-Json -Depth 30 -DateKind String
        } else {
            $json | ConvertFrom-Json -Depth 30
        }
    } catch {
        throw "[RC8_INPUT_PERF_AB] $Context was not valid JSON."
    }
}

function Read-WorldResetReceipt([Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][int] $Index,
        [string] $ExpectedSerial = '',
        [switch] $RequireFresh) {
    $path = Join-Path $Directory ('reset-{0:D2}.json' -f $Index)
    $context = "World-reset receipt $Index"
    $receipt = Read-JsonObjectFile $path $context
    $expectedFields = @(
        'schemaVersion','receiptType','result','resetRunId','completedAtUtc',
        'resetProducerSha256','deviceBindingSha256','package','profile','world',
        'exactRc8Identity','apkSha256','coreSha256','veqSha256','masterSha256',
        'worldLevelDatSha256','worldResetActivationReceipt',
        'originalSnapshotState','originalSnapshotSha256','masterCache',
        'stableStoppedAtAllFences','labStoppedAtAllFences',
        'backupVerifiedBeforeSwap','canaryMarkerAbsent','usbTransportConfirmed',
        'accessMode','rootUsed','serialPersisted','deviceWrites'
    )
    $actualFields = @($receipt.PSObject.Properties.Name)
    Require ($actualFields.Count -eq $expectedFields.Count -and
            @($actualFields | Where-Object { $expectedFields -cnotcontains $_ }).Count -eq 0) `
        "$context contained unknown or missing fields."
    Require ((Get-StrictInteger (Get-RequiredProperty $receipt 'schemaVersion' $context) `
                "$context schemaVersion" 1 1) -eq 1 -and
            [string](Get-RequiredProperty $receipt 'receiptType' $context) -ceq
                'V71_RC8_INPUT_PERFORMANCE_WORLD_RESET' -and
            [string](Get-RequiredProperty $receipt 'result' $context) -ceq 'RESET' -and
            [string](Get-RequiredProperty $receipt 'resetProducerSha256' $context) -ceq
                $script:WorldResetSha256) `
        "$context schema drifted."
    $runId = [string](Get-RequiredProperty $receipt 'resetRunId' $context)
    Require ($runId -cmatch '^[0-9a-f]{32}$') "$context omitted its unique reset ID."
    $completed = Get-ExactTimestamp (Get-RequiredProperty $receipt 'completedAtUtc' $context) `
        "$context completedAtUtc"
    $actualBinding = [string](Get-RequiredProperty $receipt 'deviceBindingSha256' $context)
    Require ($actualBinding -cmatch '^[0-9A-F]{64}$') `
        "$context omitted its privacy-preserving device binding."
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSerial)) {
        $expectedBinding = Get-TextSha256 (
            "rc8-world-reset-v1`nserial=$ExpectedSerial`nrunId=$runId`nmaster=$($script:WorldMasterSha256)")
        Require ($actualBinding -ceq $expectedBinding) `
            "$context belongs to another device or reset."
    }
    $accessMode = [string](Get-RequiredProperty $receipt 'accessMode' $context)
    $rootUsed = Get-StrictBoolean (Get-RequiredProperty $receipt 'rootUsed' $context) `
        "$context rootUsed"
    $snapshotState = [string](Get-RequiredProperty $receipt 'originalSnapshotState' $context)
    $snapshotSha = Get-RequiredProperty $receipt 'originalSnapshotSha256' $context
    $snapshotValid = ($snapshotState -ceq 'SNAPSHOT' -and
            [string]$snapshotSha -cmatch '^[0-9A-F]{64}$') -or
        ($snapshotState -ceq 'ABSENT_MARKER' -and $null -eq $snapshotSha)
    Require ([string](Get-RequiredProperty $receipt 'package' $context) -ceq $script:Package -and
            [string](Get-RequiredProperty $receipt 'profile' $context) -ceq $script:Profile -and
            [string](Get-RequiredProperty $receipt 'world' $context) -ceq 'FPS-Stress-Test' -and
            [string](Get-RequiredProperty $receipt 'apkSha256' $context) -ceq $script:ApkSha256 -and
            [string](Get-RequiredProperty $receipt 'coreSha256' $context) -ceq $script:BaselineCoreSha256 -and
            [string](Get-RequiredProperty $receipt 'veqSha256' $context) -ceq $script:VeqSha256 -and
            [string](Get-RequiredProperty $receipt 'masterSha256' $context) -ceq $script:WorldMasterSha256 -and
            [string](Get-RequiredProperty $receipt 'worldLevelDatSha256' $context) -ceq
                $script:WorldLevelDatSha256 -and
            [string](Get-RequiredProperty $receipt 'worldResetActivationReceipt' $context) -ceq
                "QC_RC8_WORLD_RESET:PASS:$($script:WorldLevelDatSha256):100:26" -and
            [string](Get-RequiredProperty $receipt 'masterCache' $context) -cin
                @('VERIFIED','CREATED') -and
            $snapshotValid -and $accessMode -cin @('Normal','Root') -and
            $rootUsed -eq ($accessMode -ceq 'Root') -and
            (Get-StrictInteger (Get-RequiredProperty $receipt 'deviceWrites' $context) `
                "$context deviceWrites" 1 ([int64]::MaxValue)) -ge 1) `
        "$context did not prove the exact baseline world-reset identity."
    foreach ($field in @('exactRc8Identity','stableStoppedAtAllFences',
            'labStoppedAtAllFences','backupVerifiedBeforeSwap',
            'canaryMarkerAbsent','usbTransportConfirmed')) {
        Require (Get-StrictBoolean (Get-RequiredProperty $receipt $field $context) `
                "$context $field") "$context failed $field."
    }
    Require (-not (Get-StrictBoolean `
            (Get-RequiredProperty $receipt 'serialPersisted' $context) `
            "$context serialPersisted")) "$context persisted a device serial."
    [double]$ageSeconds = ([DateTimeOffset]::UtcNow - $completed).TotalSeconds
    if ($RequireFresh) {
        Require ($ageSeconds -ge $script:RequiredWarmupSeconds -and
                $ageSeconds -le $script:MaximumPreparationAgeSeconds) `
            "$context was not followed by the fixed five-minute warm-up."
    }
    [pscustomobject][ordered]@{
        Path = $path
        Sha256 = Get-FileSha256 $path
        ResetRunId = $runId
        CompletedAt = $completed
        CompletedAtUtc = $completed.ToString('o')
        AgeSeconds = $ageSeconds
        DeviceBindingSha256 = $actualBinding
        SnapshotState = $snapshotState
        SnapshotSha256 = if ($null -eq $snapshotSha) { $null } else { [string]$snapshotSha }
        AccessMode = $accessMode
    }
}

function Read-CampaignPrefix([Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][int] $NextIndex,
        [Parameter(Mandatory)][string] $ExpectedSerial) {
    $captureFiles = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object {
        $_.Name -cmatch '^[0-9]{2}-[AB]\.json$'
    })
    Require ($captureFiles.Count -eq ($NextIndex - 1)) `
        'Capture receipts must be produced in exact order without gaps or branches.'
    $resetFiles = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object {
        $_.Name -cmatch '^reset-[0-9]{2}\.json$'
    })
    Require ($resetFiles.Count -eq $NextIndex) `
        'Exactly one fresh world-reset receipt must precede the next arm.'
    Require (-not (Test-Path -LiteralPath (Join-Path $Directory '07-final-rollback.json'))) `
        'A finalized campaign cannot accept another capture.'

    $receipts = @()
    $hashes = @()
    $resets = @()
    for ($index = 1; $index -lt $NextIndex; $index++) {
        $condition = $script:Order[$index - 1]
        $path = Join-Path $Directory ('{0:D2}-{1}.json' -f $index, $condition)
        $receipts += Read-JsonObjectFile $path "Campaign receipt $index"
        $hashes += Get-FileSha256 $path
        $resets += Read-WorldResetReceipt -Directory $Directory -Index $index `
            -ExpectedSerial $ExpectedSerial
    }
    $currentReset = Read-WorldResetReceipt -Directory $Directory -Index $NextIndex `
        -ExpectedSerial $ExpectedSerial -RequireFresh
    $resetSnapshotTokens = @(@($resets) + @($currentReset) | ForEach-Object {
        [string]$_.SnapshotState + ':' + [string]$_.SnapshotSha256
    } | Select-Object -Unique)
    Require ($resetSnapshotTokens.Count -eq 1) `
        'The immutable original-world snapshot contract changed between resets.'

    if ($receipts.Count -eq 0) {
        return [pscustomobject][ordered]@{
            CampaignId = [Guid]::NewGuid().ToString('N')
            PreviousReceiptSha256 = $null
            PreviousCapturedAt = $null
            DeviceBindingSha256 = $null
            OtherModsFingerprintSha256 = $null
            CurrentReset = $currentReset
        }
    }

    [string]$campaignId = ''
    [string]$deviceBinding = ''
    [string]$fingerprint = ''
    [DateTimeOffset]$previousCaptured = [DateTimeOffset]::MinValue
    for ($offset = 0; $offset -lt $receipts.Count; $offset++) {
        $index = $offset + 1
        $receipt = $receipts[$offset]
        $context = "Campaign receipt $index"
        Require ((Get-StrictInteger (Get-RequiredProperty $receipt 'schemaVersion' $context) `
                    "$context schemaVersion" 4 4) -eq 4 -and
                (Get-StrictInteger (Get-RequiredProperty $receipt 'sequenceIndex' $context) `
                    "$context sequenceIndex" $index $index) -eq $index -and
                [string](Get-RequiredProperty $receipt 'condition' $context) -ceq
                    $script:Order[$index - 1]) "$context order drifted."
        $currentCampaign = [string](Get-RequiredProperty $receipt 'campaignId' $context)
        Require ($currentCampaign -cmatch '^[0-9a-f]{32}$') "$context campaign ID is invalid."
        $currentBinding = [string](Get-RequiredProperty $receipt 'deviceBindingSha256' $context)
        $currentFingerprint = [string](Get-RequiredProperty `
            (Get-RequiredProperty $receipt 'identityFence' $context) `
            'otherModsFingerprintSha256' "$context identity")
        if ($offset -eq 0) {
            $campaignId = $currentCampaign
            $deviceBinding = $currentBinding
            $fingerprint = $currentFingerprint
            Require ([string]::IsNullOrEmpty([string](Get-RequiredProperty `
                    $receipt 'previousReceiptSha256' $context))) `
                'The first capture must be the campaign genesis.'
        } else {
            Require ($currentCampaign -ceq $campaignId -and
                    $currentBinding -ceq $deviceBinding -and
                    $currentFingerprint -ceq $fingerprint -and
                    [string](Get-RequiredProperty $receipt 'previousReceiptSha256' $context) -ceq
                        [string]$hashes[$offset - 1]) `
                "$context broke the campaign hash/device/fingerprint chain."
        }
        $captured = Get-ExactTimestamp (Get-RequiredProperty $receipt 'capturedAtUtc' $context) `
            "$context capturedAtUtc"
        Require ($offset -eq 0 -or $captured -gt $previousCaptured) `
            "$context did not advance campaign time."
        Require ([string](Get-RequiredProperty $receipt 'worldResetReceiptSha256' $context) -ceq
                [string]$resets[$offset].Sha256) "$context lost its world-reset binding."
        Require ($resets[$offset].CompletedAt -lt $captured) `
            "$context preceded its world reset."
        if ($offset -gt 0) {
            Require ($resets[$offset].CompletedAt -gt $previousCaptured) `
                "$context reused a reset from before the prior arm completed."
        }
        $previousCaptured = $captured
    }
    Require ($currentReset.CompletedAt -gt $previousCaptured) `
        'The next arm did not receive a reset after the prior arm completed.'
    [pscustomobject][ordered]@{
        CampaignId = $campaignId
        PreviousReceiptSha256 = [string]$hashes[-1]
        PreviousCapturedAt = $previousCaptured
        DeviceBindingSha256 = $deviceBinding
        OtherModsFingerprintSha256 = $fingerprint
        CurrentReset = $currentReset
    }
}

function Read-CompleteCampaignArtifacts([Parameter(Mandatory)][string] $Directory,
        [string] $ExpectedSerial = '') {
    $captureFiles = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object {
        $_.Name -cmatch '^[0-9]{2}-[AB]\.json$'
    })
    $resetFiles = @(Get-ChildItem -LiteralPath $Directory -File | Where-Object {
        $_.Name -cmatch '^reset-[0-9]{2}\.json$'
    })
    Require ($captureFiles.Count -eq 6 -and $resetFiles.Count -eq 6) `
        'The exact campaign must contain six capture and six reset receipts.'
    $receipts = @()
    $hashes = @()
    $resets = @()
    for ($index = 1; $index -le 6; $index++) {
        $condition = $script:Order[$index - 1]
        $path = Join-Path $Directory ('{0:D2}-{1}.json' -f $index, $condition)
        $receipts += Read-JsonObjectFile $path "Campaign receipt $index"
        $hashes += Get-FileSha256 $path
        $resets += Read-WorldResetReceipt -Directory $Directory -Index $index `
            -ExpectedSerial $ExpectedSerial
    }
    [pscustomobject][ordered]@{
        Receipts = [object[]]$receipts
        Hashes = [string[]]$hashes
        Resets = [object[]]$resets
    }
}

function Get-RequiredProperty($Object, [string] $Name, [string] $Context) {
    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    Require ($properties.Count -eq 1) "$Context omitted or duplicated $Name."
    $properties[0].Value
}

function Get-ExactDouble($Value, [string] $Context) {
    Require ($Value -is [ValueType]) "$Context is not numeric."
    [double]$result = 0
    Require ([double]::TryParse([string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$result) -and [double]::IsFinite($result)) "$Context is invalid."
    $result
}

function Get-ReceiptStrata($Receipt, [string] $Context) {
    $aggregate = Get-RequiredProperty $Receipt 'aggregate' $Context
    $strata = @(Get-RequiredProperty $aggregate 'RefreshMetricStrata' "$Context aggregate")
    Require ($strata.Count -gt 0) "$Context lacks per-refresh aggregate strata."
    $map = [ordered]@{}
    [int64]$sampleSum = 0
    foreach ($stratum in $strata) {
        $hz = Get-ExactDouble (Get-RequiredProperty $stratum 'Hz' $Context) "$Context Hz"
        $key = $hz.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
        Require ($key -cin @('72.0','80.0','90.0','120.0')) `
            "$Context contained an unsupported Quest refresh stratum."
        Require (-not $map.Contains($key)) "$Context repeated a refresh stratum."
        [int]$samples = Get-StrictInteger (Get-RequiredProperty $stratum 'Samples' $Context) `
            "$Context Samples" 1 ([int]::MaxValue)
        Require ($samples -gt 0) "$Context has an empty refresh stratum."
        [int]$temperatureSamples = Get-StrictInteger `
            (Get-RequiredProperty $stratum 'TemperatureSampleCount' $Context) `
            "$Context TemperatureSampleCount" 0 $samples
        [double]$temperatureCoverage = Get-ExactDouble `
            (Get-RequiredProperty $stratum 'TemperatureCoveragePercent' $Context) `
            "$Context TemperatureCoveragePercent"
        $row = [pscustomobject]@{
            Hz = $hz
            Samples = $samples
            MeanAppFps = Get-ExactDouble (Get-RequiredProperty $stratum 'MeanAppFps' $Context) "$Context MeanAppFps"
            P10AppFps = Get-ExactDouble (Get-RequiredProperty $stratum 'P10AppFps' $Context) "$Context P10AppFps"
            MeanStalePerSecond = Get-ExactDouble (Get-RequiredProperty $stratum 'MeanStalePerSecond' $Context) "$Context stale"
            P95CpuAndGpuMs = Get-ExactDouble (Get-RequiredProperty $stratum 'P95CpuAndGpuMs' $Context) "$Context P95CpuAndGpuMs"
            MeanTempC = Get-ExactDouble (Get-RequiredProperty $stratum 'MeanTempC' $Context) "$Context MeanTempC"
            TemperatureSampleCount = $temperatureSamples
            TemperatureCoveragePercent = $temperatureCoverage
        }
        Require ($row.Hz -gt 0 -and $row.MeanAppFps -gt 0 -and
                $row.P10AppFps -gt 0 -and $row.P95CpuAndGpuMs -gt 0 -and
                $row.MeanStalePerSecond -ge 0 -and
                $row.MeanTempC -ge 0 -and $row.MeanTempC -le 100 -and
                $row.TemperatureSampleCount -eq $samples -and
                $row.TemperatureCoveragePercent -eq 100.0) `
            "$Context contains an impossible aggregate metric."
        $map[$key] = $row
        $sampleSum += $samples
    }
    [int64]$totalSamples = Get-StrictInteger `
        (Get-RequiredProperty $aggregate 'VrApiSamples' "$Context aggregate") `
        "$Context aggregate VrApiSamples" 1 ([int]::MaxValue)
    Require ($sampleSum -eq $totalSamples) `
        "$Context refresh strata did not partition all VrApi samples."
    [int64]$totalTemperatureSamples = Get-StrictInteger `
        (Get-RequiredProperty $aggregate 'TemperatureSampleCount' "$Context aggregate") `
        "$Context aggregate TemperatureSampleCount" 0 $totalSamples
    [double]$totalTemperatureCoverage = Get-ExactDouble `
        (Get-RequiredProperty $aggregate 'TemperatureCoveragePercent' "$Context aggregate") `
        "$Context aggregate TemperatureCoveragePercent"
    Require ($totalTemperatureSamples -eq $totalSamples -and
            $totalTemperatureCoverage -eq 100.0) `
        "$Context lacks complete thermal telemetry."
    $map
}

function Get-WeightedMean([object[]] $Rows, [string] $Property) {
    [double]$weighted = 0
    [double]$weight = 0
    foreach ($row in $Rows) {
        $w = [double]$row.Weight
        $weighted += $w * [double]$row.$Property
        $weight += $w
    }
    Require ($weight -gt 0) 'A weighted metric had no overlap.'
    $weighted / $weight
}

function Compare-MatchedRefreshPair($A, $B, [int] $PairIndex) {
    $aMap = Get-ReceiptStrata $A "Pair $PairIndex A"
    $bMap = Get-ReceiptStrata $B "Pair $PairIndex B"
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($key in @($aMap.Keys)) {
        if (-not $bMap.Contains($key)) { continue }
        $aStratum = $aMap[$key]; $bStratum = $bMap[$key]
        $overlap = [Math]::Min([int]$aStratum.Samples, [int]$bStratum.Samples)
        if ($overlap -lt $MinimumSamplesPerStratum) { continue }
        $rows.Add([pscustomobject][ordered]@{
            Hz = [double]$aStratum.Hz
            Weight = $overlap
            ACount = [int]$aStratum.Samples
            BCount = [int]$bStratum.Samples
            P95ImprovementPercent = 100.0 * ($aStratum.P95CpuAndGpuMs - $bStratum.P95CpuAndGpuMs) / $aStratum.P95CpuAndGpuMs
            MeanFpsChangePercent = 100.0 * ($bStratum.MeanAppFps - $aStratum.MeanAppFps) / $aStratum.MeanAppFps
            P10FpsChangePercent = 100.0 * ($bStratum.P10AppFps - $aStratum.P10AppFps) / $aStratum.P10AppFps
            StaleA = [double]$aStratum.MeanStalePerSecond
            StaleB = [double]$bStratum.MeanStalePerSecond
            StaleDeltaPerSecond = [double]$aStratum.MeanStalePerSecond - [double]$bStratum.MeanStalePerSecond
            StaleImprovementPercent = if ([double]$aStratum.MeanStalePerSecond -gt 0.0001) {
                100.0 * ([double]$aStratum.MeanStalePerSecond -
                    [double]$bStratum.MeanStalePerSecond) /
                    [double]$aStratum.MeanStalePerSecond
            } elseif ([double]$bStratum.MeanStalePerSecond -le 0.0001) {
                0.0
            } else {
                -100.0
            }
            TemperatureDeltaC = [Math]::Abs([double]$aStratum.MeanTempC - [double]$bStratum.MeanTempC)
        })
    }
    $overlapSamples = 0
    foreach ($row in $rows) { $overlapSamples += [int]$row.Weight }
    $aTotal = [int](Get-StrictInteger `
        (Get-RequiredProperty $A.aggregate 'VrApiSamples' 'A aggregate') `
        'A samples' 1 ([int]::MaxValue))
    $bTotal = [int](Get-StrictInteger `
        (Get-RequiredProperty $B.aggregate 'VrApiSamples' 'B aggregate') `
        'B samples' 1 ([int]::MaxValue))
    $overlapA = 100.0 * $overlapSamples / $aTotal
    $overlapB = 100.0 * $overlapSamples / $bTotal
    $aFirstTemp = Get-ExactDouble `
        (Get-RequiredProperty $A.aggregate 'FirstTempC' 'A aggregate') 'A first temp'
    $bFirstTemp = Get-ExactDouble `
        (Get-RequiredProperty $B.aggregate 'FirstTempC' 'B aggregate') 'B first temp'
    Require ($aFirstTemp -ge 0 -and $aFirstTemp -le 100 -and
            $bFirstTemp -ge 0 -and $bFirstTemp -le 100) `
        'A pair contained an impossible start temperature.'
    $startDelta = [Math]::Abs($aFirstTemp - $bFirstTemp)
    $matchedTempDelta = if ($rows.Count -gt 0) {
        Get-WeightedMean $rows.ToArray() 'TemperatureDeltaC'
    } else { [double]::PositiveInfinity }
    $comparable = $rows.Count -gt 0 -and
        $overlapSamples -ge $MinimumOverlapSamplesPerPair -and
        $overlapA -ge $MinimumOverlapPercentPerArm -and
        $overlapB -ge $MinimumOverlapPercentPerArm -and
        $startDelta -le $MaximumStartTemperatureDeltaC -and
        $matchedTempDelta -le $MaximumMatchedTemperatureDeltaC

    [pscustomobject][ordered]@{
        PairIndex = $PairIndex
        Order = if ([int]$A.sequenceIndex -lt [int]$B.sequenceIndex) { 'AB' } else { 'BA' }
        Comparable = $comparable
        MatchedRefreshStrata = @($rows | ForEach-Object { $_.Hz })
        MatchedStratumCount = $rows.Count
        OverlapSamples = $overlapSamples
        OverlapPercentA = [Math]::Round($overlapA, 1)
        OverlapPercentB = [Math]::Round($overlapB, 1)
        StartTemperatureDeltaC = [Math]::Round($startDelta, 2)
        MatchedTemperatureDeltaC = if ([double]::IsFinite($matchedTempDelta)) {
            $matchedTempDelta
        } else { $null }
        MatchedP95CpuAndGpuImprovementPercent = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'P95ImprovementPercent'
        } else { $null }
        MatchedMeanAppFpsChangePercent = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'MeanFpsChangePercent'
        } else { $null }
        MatchedP10AppFpsChangePercent = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'P10FpsChangePercent'
        } else { $null }
        MatchedStaleDeltaPerSecond = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'StaleDeltaPerSecond'
        } else { $null }
        MatchedStaleA = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'StaleA'
        } else { $null }
        MatchedStaleB = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'StaleB'
        } else { $null }
        MatchedStaleImprovementPercent = if ($rows.Count -gt 0) {
            Get-WeightedMean $rows.ToArray() 'StaleImprovementPercent'
        } else { $null }
        Strata = $rows.ToArray()
    }
}

function Assert-Receipt($Receipt, [int] $Index) {
    Require ((Get-StrictInteger (Get-RequiredProperty $Receipt 'schemaVersion' "Receipt $Index") `
                "Receipt $Index schemaVersion" 4 4) -eq 4 -and
            [string](Get-RequiredProperty $Receipt 'receiptType' "Receipt $Index") -ceq
                'V71_RC8_INPUT_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE') `
        "Receipt $Index schema drifted."
    $expectedCondition = $script:Order[$Index - 1]
    Require ((Get-StrictInteger (Get-RequiredProperty $Receipt 'sequenceIndex' "Receipt $Index") `
                "Receipt $Index sequenceIndex" $Index $Index) -eq $Index -and
            [string](Get-RequiredProperty $Receipt 'condition' "Receipt $Index") -ceq $expectedCondition -and
            [string](Get-RequiredProperty $Receipt 'renderScaleFactor' "Receipt $Index") -ceq
                '1.0' -and
            [string](Get-RequiredProperty $Receipt 'openXrCopyBatchMode' "Receipt $Index") -ceq
                'OFF') "Receipt $Index order/isolation drifted."
    Require ((Get-StrictInteger (Get-RequiredProperty $Receipt 'durationSeconds' "Receipt $Index") `
                "Receipt $Index durationSeconds" $script:RequiredDurationSeconds `
                $script:RequiredDurationSeconds) -eq $script:RequiredDurationSeconds -and
            (Get-StrictBoolean (Get-RequiredProperty $Receipt 'qgoDynamicConfirmed' "Receipt $Index") `
                "Receipt $Index qgoDynamicConfirmed")) `
        "Receipt $Index did not use the fixed duration/QGO Dynamic contract."
    Require ([string](Get-RequiredProperty $Receipt 'campaignId' "Receipt $Index") -cmatch
                '^[0-9a-f]{32}$' -and
            [string](Get-RequiredProperty $Receipt 'captureId' "Receipt $Index") -cmatch
                '^[0-9a-f]{32}$' -and
            [string](Get-RequiredProperty $Receipt 'deviceBindingSha256' "Receipt $Index") -cmatch
                '^[0-9A-F]{64}$' -and
            [string](Get-RequiredProperty $Receipt 'worldResetReceiptSha256' "Receipt $Index") -cmatch
                '^[0-9A-F]{64}$') `
        "Receipt $Index omitted its campaign/device/reset binding."
    $null = Get-ExactTimestamp (Get-RequiredProperty $Receipt 'capturedAtUtc' "Receipt $Index") `
        "Receipt $Index capturedAtUtc"
    $identity = Get-RequiredProperty $Receipt 'identityFence' "Receipt $Index"
    foreach ($field in @('exactBuildLock','exactInputLock','exactApk',
            'signerBoundByExactApk','exactCore','exactVeq','stableStoppedAtBothFences',
            'stableStoppedThroughout',
            'renderScaleOneAtBothFences','copyBatchOffAtBothFences',
            'sameProcessAtBothFences','explicitUsbTransport')) {
        Require (Get-StrictBoolean (Get-RequiredProperty $identity $field "Receipt $Index identity") `
                "Receipt $Index identity $field") `
            "Receipt $Index failed identity field $field."
    }
    Require ([string](Get-RequiredProperty $identity 'coreSha256' "Receipt $Index identity") -ceq
            [string]$script:CoreShaByCondition[$expectedCondition] -and
            [string](Get-RequiredProperty $identity 'coreVersion' "Receipt $Index identity") -ceq
            [string]$script:CoreVersionByCondition[$expectedCondition]) `
        "Receipt $Index carried the wrong A/B core identity."
    $expectedMarkerState = if ($expectedCondition -ceq 'A') { 'absent' } else { 'consumed' }
    Require ([string](Get-RequiredProperty $identity 'markerState' "Receipt $Index identity") -ceq
            $expectedMarkerState) "Receipt $Index carried the wrong v9 marker state."
    $markerRunId = [string](Get-RequiredProperty $identity 'markerRunId' "Receipt $Index identity")
    if ($expectedCondition -ceq 'A') {
        Require ([string]::IsNullOrEmpty($markerRunId)) `
            "Receipt $Index baseline A unexpectedly carried a canary run ID."
    } else {
        Require ($markerRunId -cmatch '^[0-9a-f]{32}$') `
            "Receipt $Index candidate B omitted its fresh canary run ID."
    }
    $processToken = [string](Get-RequiredProperty $identity 'processTokenSha256' "Receipt $Index identity")
    Require ($processToken -cmatch '^[0-9A-F]{64}$') `
        "Receipt $Index omitted its bounded process identity token."
    Require ([string](Get-RequiredProperty $identity 'otherModsFingerprintSha256' "Receipt $Index identity") -cmatch
                '^[0-9A-F]{64}$' -and
            [string](Get-RequiredProperty $identity 'readAccessMode' "Receipt $Index identity") -cin
                @('Normal','Root')) `
        "Receipt $Index omitted its exact other-mod/access-mode fence."
    Require (Get-StrictBoolean (Get-RequiredProperty $Receipt 'validForComparison' "Receipt $Index") `
            "Receipt $Index validForComparison") `
        "Receipt $Index was invalidated by the PID/focus/VrApi gate."
    Require ([string](Get-RequiredProperty $Receipt 'refreshPolicy' "Receipt $Index") -ceq 'Dynamic') `
        "Receipt $Index was not captured with Dynamic refresh."
    $benchmarkGate = Get-RequiredProperty $Receipt 'benchmarkGate' "Receipt $Index"
    $cpuLevel = [int](Get-StrictInteger `
        (Get-RequiredProperty $benchmarkGate 'expectedCpuLevel' "Receipt $Index benchmark gate") `
        "Receipt $Index expectedCpuLevel" 0 15)
    $gpuLevel = [int](Get-StrictInteger `
        (Get-RequiredProperty $benchmarkGate 'expectedGpuLevel' "Receipt $Index benchmark gate") `
        "Receipt $Index expectedGpuLevel" 0 15)
    Require ((Get-ExactDouble (Get-RequiredProperty $benchmarkGate 'cpuExpectedLevelPercent' `
                    "Receipt $Index benchmark gate") "Receipt $Index CPU level percent") -ge 95.0 -and
            (Get-ExactDouble (Get-RequiredProperty $benchmarkGate 'gpuExpectedLevelPercent' `
                    "Receipt $Index benchmark gate") "Receipt $Index GPU level percent") -ge 95.0) `
        "Receipt $Index did not remain at its declared performance levels."
    Require ((Get-StrictBoolean (Get-RequiredProperty $benchmarkGate 'exactPid' `
                    "Receipt $Index benchmark gate") "Receipt $Index exactPid") -and
            (Get-ExactDouble (Get-RequiredProperty $benchmarkGate 'focusPercent' `
                    "Receipt $Index benchmark gate") "Receipt $Index focusPercent") -ge 95.0) `
        "Receipt $Index did not keep the exact focused Lab process."
    $polls = Get-StrictInteger (Get-RequiredProperty $benchmarkGate 'polls' `
        "Receipt $Index benchmark gate") "Receipt $Index polls" 1 ([int]::MaxValue)
    $stableKnown = Get-StrictInteger (Get-RequiredProperty $benchmarkGate 'stableKnownPolls' `
        "Receipt $Index benchmark gate") "Receipt $Index stableKnownPolls" 0 $polls
    $stableStopped = Get-StrictInteger (Get-RequiredProperty $benchmarkGate 'stableStoppedPolls' `
        "Receipt $Index benchmark gate") "Receipt $Index stableStoppedPolls" 0 $polls
    $stableErrors = Get-StrictInteger (Get-RequiredProperty $benchmarkGate 'stablePollErrors' `
        "Receipt $Index benchmark gate") "Receipt $Index stablePollErrors" 0 ([int]::MaxValue)
    Require ($stableKnown -eq $polls -and $stableStopped -eq $polls -and
            $stableErrors -eq 0 -and
            (Get-StrictBoolean (Get-RequiredProperty $benchmarkGate 'stableStoppedAtStart' `
                    "Receipt $Index benchmark gate") "Receipt $Index stable start") -and
            (Get-StrictBoolean (Get-RequiredProperty $benchmarkGate 'stableStoppedAtEnd' `
                    "Receipt $Index benchmark gate") "Receipt $Index stable end")) `
        "Receipt $Index did not prove Stable stopped on every timed poll."
    $null = Get-ReceiptStrata $Receipt "Receipt $Index"
}

function Assert-CampaignEvidence([object[]] $Receipts, [string[]] $ReceiptHashes,
        [object[]] $ResetReceipts) {
    Require ($Receipts.Count -eq 6 -and $ReceiptHashes.Count -eq 6 -and
            $ResetReceipts.Count -eq 6) `
        'A complete campaign requires six captures and six reset receipts.'
    $campaignIds = @($Receipts | ForEach-Object { [string]$_.campaignId } |
        Select-Object -Unique)
    $captureIds = @($Receipts | ForEach-Object { [string]$_.captureId } |
        Select-Object -Unique)
    $deviceBindings = @($Receipts | ForEach-Object { [string]$_.deviceBindingSha256 } |
        Select-Object -Unique)
    $fingerprints = @($Receipts | ForEach-Object {
        [string]$_.identityFence.otherModsFingerprintSha256
    } | Select-Object -Unique)
    $resetIds = @($ResetReceipts | ForEach-Object { [string]$_.ResetRunId } |
        Select-Object -Unique)
    $resetSnapshotTokens = @($ResetReceipts | ForEach-Object {
        [string]$_.SnapshotState + ':' + [string]$_.SnapshotSha256
    } | Select-Object -Unique)
    Require ($campaignIds.Count -eq 1 -and $campaignIds[0] -cmatch '^[0-9a-f]{32}$' -and
            $captureIds.Count -eq 6 -and
            @($captureIds | Where-Object { $_ -cmatch '^[0-9a-f]{32}$' }).Count -eq 6 -and
            $deviceBindings.Count -eq 1 -and
            $deviceBindings[0] -cmatch '^[0-9A-F]{64}$' -and
            $fingerprints.Count -eq 1 -and
            $fingerprints[0] -cmatch '^[0-9A-F]{64}$' -and
            $resetIds.Count -eq 6 -and $resetSnapshotTokens.Count -eq 1) `
        'The campaign did not keep unique events and one device/mod identity.'

    [DateTimeOffset]$previousCapture = [DateTimeOffset]::MinValue
    for ($offset = 0; $offset -lt 6; $offset++) {
        $index = $offset + 1
        Assert-Receipt $Receipts[$offset] $index
        $context = "Receipt $index"
        $previousHash = [string](Get-RequiredProperty $Receipts[$offset] `
            'previousReceiptSha256' $context)
        if ($offset -eq 0) {
            Require ([string]::IsNullOrEmpty($previousHash)) `
                'Receipt 1 must be the campaign genesis.'
        } else {
            Require ($previousHash -ceq $ReceiptHashes[$offset - 1]) `
                "$context broke the receipt SHA-256 chain."
        }
        Require ([string](Get-RequiredProperty $Receipts[$offset] `
                'worldResetReceiptSha256' $context) -ceq $ResetReceipts[$offset].Sha256 -and
                [string](Get-RequiredProperty $Receipts[$offset] `
                'worldResetRunId' $context) -ceq $ResetReceipts[$offset].ResetRunId -and
                [string](Get-RequiredProperty $Receipts[$offset] `
                'worldResetCompletedAtUtc' $context) -ceq
                    $ResetReceipts[$offset].CompletedAtUtc) `
            "$context was not bound to its exact reset bytes and identity."
        [DateTimeOffset]$captured = Get-ExactTimestamp `
            (Get-RequiredProperty $Receipts[$offset] 'capturedAtUtc' $context) `
            "$context capturedAtUtc"
        Require ($ResetReceipts[$offset].CompletedAt -lt $captured -and
                ($offset -eq 0 -or
                    $ResetReceipts[$offset].CompletedAt -gt $previousCapture) -and
                ($offset -eq 0 -or $captured -gt $previousCapture)) `
            "$context/reset chronology was not exact."
        Require ((Get-ExactDouble (Get-RequiredProperty $Receipts[$offset] `
                    'warmupSecondsObserved' $context) "$context warmup") -ge
                $script:RequiredWarmupSeconds) `
            "$context did not prove the fixed warm-up."
        $previousCapture = $captured
    }
    [pscustomobject][ordered]@{
        CampaignId = $campaignIds[0]
        DeviceBindingSha256 = $deviceBindings[0]
        OtherModsFingerprintSha256 = $fingerprints[0]
        LastCaptureAt = $previousCapture
        LastReceiptSha256 = $ReceiptHashes[5]
        LastCandidateRunId = [string]$Receipts[5].identityFence.markerRunId
    }
}

function Assert-FinalRollbackReceipt($Receipt, $Campaign) {
    $context = 'Final rollback receipt'
    Require ((Get-StrictInteger (Get-RequiredProperty $Receipt 'schemaVersion' $context) `
                "$context schemaVersion" 1 1) -eq 1 -and
            [string](Get-RequiredProperty $Receipt 'receiptType' $context) -ceq
                'V71_RC8_INPUT_PERFORMANCE_FINAL_ROLLBACK') `
        'The final rollback receipt schema drifted.'
    Require ([string](Get-RequiredProperty $Receipt 'campaignId' $context) -ceq
                $Campaign.CampaignId -and
            [string](Get-RequiredProperty $Receipt 'previousReceiptSha256' $context) -ceq
                $Campaign.LastReceiptSha256 -and
            [string](Get-RequiredProperty $Receipt 'deviceBindingSha256' $context) -ceq
                $Campaign.DeviceBindingSha256 -and
            [string](Get-RequiredProperty $Receipt 'rolledBackCandidateRunId' $context) -ceq
                $Campaign.LastCandidateRunId -and
            [string](Get-RequiredProperty $Receipt 'otherModsFingerprintSha256' $context) -ceq
                $Campaign.OtherModsFingerprintSha256) `
        'The final rollback did not extend the exact campaign head.'
    $completed = Get-ExactTimestamp (Get-RequiredProperty $Receipt 'completedAtUtc' $context) `
        "$context completedAtUtc"
    Require ($completed -gt $Campaign.LastCaptureAt) `
        'The final rollback receipt predates B3.'
    Require ([string](Get-RequiredProperty $Receipt 'baselineCoreSha256' $context) -ceq
                $script:BaselineCoreSha256 -and
            [string](Get-RequiredProperty $Receipt 'baselineCoreVersion' $context) -ceq
                $script:BaselineCoreVersion -and
            [string](Get-RequiredProperty $Receipt 'apkSha256' $context) -ceq
                $script:ApkSha256 -and
            [string](Get-RequiredProperty $Receipt 'veqSha256' $context) -ceq
                $script:VeqSha256 -and
            [string](Get-RequiredProperty $Receipt 'markerState' $context) -ceq 'absent' -and
            [string](Get-RequiredProperty $Receipt 'readAccessMode' $context) -cin
                @('Normal','Root')) `
        'The final rollback did not restore exact A/no-marker state.'
    foreach ($field in @('exactBaseline','markerAbsent','stableStoppedAtBothFences',
            'labStoppedAtBothFences','renderScaleOne','explicitUsbTransport')) {
        Require (Get-StrictBoolean (Get-RequiredProperty $Receipt $field $context) `
                "$context $field") "The final rollback failed $field."
    }
    $true
}

function Analyze-Receipts([object[]] $Receipts, [string[]] $ReceiptHashes,
        [object[]] $ResetReceipts, $FinalRollbackReceipt) {
    Require ($Receipts.Count -eq 6) 'Exactly six receipts are required.'
    $campaign = Assert-CampaignEvidence $Receipts $ReceiptHashes $ResetReceipts
    $finalRollbackProved = Assert-FinalRollbackReceipt $FinalRollbackReceipt $campaign
    $campaignRootUsed = @($ResetReceipts | Where-Object {
        [string]$_.AccessMode -ceq 'Root'
    }).Count -gt 0 -or @($Receipts | Where-Object {
        [string]$_.identityFence.readAccessMode -ceq 'Root'
    }).Count -gt 0 -or [string]$FinalRollbackReceipt.readAccessMode -ceq 'Root'
    $expectedCpuLevels = @($Receipts | ForEach-Object { [int]$_.benchmarkGate.expectedCpuLevel } | Select-Object -Unique)
    $expectedGpuLevels = @($Receipts | ForEach-Object { [int]$_.benchmarkGate.expectedGpuLevel } | Select-Object -Unique)
    Require ($expectedCpuLevels.Count -eq 1 -and $expectedGpuLevels.Count -eq 1) `
        'All six receipts must use the same declared CPU/GPU performance levels.'
    $processTokens = @($Receipts | ForEach-Object { [string]$_.identityFence.processTokenSha256 })
    $freshProcessSet = @($processTokens | Select-Object -Unique).Count -eq 6
    $candidateRunIds = @($Receipts | Where-Object { $_.condition -ceq 'B' } |
        ForEach-Object { [string]$_.identityFence.markerRunId })
    $freshCandidateTransactions = @($candidateRunIds | Where-Object {
        $_ -cmatch '^[0-9a-f]{32}$'
    } | Select-Object -Unique).Count -eq 3
    $pairs = @(
        Compare-MatchedRefreshPair $Receipts[0] $Receipts[1] 1
        Compare-MatchedRefreshPair $Receipts[3] $Receipts[2] 2
        Compare-MatchedRefreshPair $Receipts[4] $Receipts[5] 3
    )
    $comparable = @($pairs | Where-Object { $_.Comparable }).Count -eq 3
    $weightedRows = @($pairs | ForEach-Object {
        if ($_.Comparable) {
            [pscustomobject]@{
                Weight = $_.OverlapSamples
                P95 = $_.MatchedP95CpuAndGpuImprovementPercent
                MeanFps = $_.MatchedMeanAppFpsChangePercent
                P10 = $_.MatchedP10AppFpsChangePercent
                StaleDelta = $_.MatchedStaleDeltaPerSecond
                StaleA = $_.MatchedStaleA
                StaleB = $_.MatchedStaleB
                StalePercent = $_.MatchedStaleImprovementPercent
            }
        }
    })
    $p95 = if ($comparable) { Get-WeightedMean $weightedRows 'P95' } else { $null }
    $meanFps = if ($comparable) { Get-WeightedMean $weightedRows 'MeanFps' } else { $null }
    $p10 = if ($comparable) { Get-WeightedMean $weightedRows 'P10' } else { $null }
    $staleDelta = if ($comparable) { Get-WeightedMean $weightedRows 'StaleDelta' } else { $null }
    $staleA = if ($comparable) { Get-WeightedMean $weightedRows 'StaleA' } else { $null }
    $staleB = if ($comparable) { Get-WeightedMean $weightedRows 'StaleB' } else { $null }
    $staleImprovement = if ($null -ne $staleA -and $staleA -gt 0.0001) {
        100.0 * ($staleA - $staleB) / $staleA
    } else { $null }
    $positivePairs = if ($comparable) {
        @($pairs | Where-Object { $_.MatchedP95CpuAndGpuImprovementPercent -gt 0 }).Count
    } else { 0 }
    $positiveStalePairs = if ($comparable) {
        @($pairs | Where-Object { $_.MatchedStaleImprovementPercent -gt 0 }).Count
    } else { 0 }
    $evidenceComplete = $comparable -and $freshProcessSet -and
        $freshCandidateTransactions -and $finalRollbackProved
    $p95Path = $positivePairs -ge 2 -and $p95 -ge 2.0
    $stalePath = $positiveStalePairs -ge 2 -and
        $null -ne $staleImprovement -and $staleImprovement -ge 2.0
    $guardrails = $null -ne $meanFps -and $null -ne $p10 -and
        $meanFps -ge -1.0 -and $p10 -ge -1.0
    $performanceGate = $evidenceComplete -and ($p95Path -or $stalePath) -and $guardrails
    [pscustomobject][ordered]@{
        schemaVersion = 3
        result = if (-not $evidenceComplete) { 'INCONCLUSIVE' } elseif ($performanceGate) {
            'PERFORMANCE_CANDIDATE'
        } else { 'REJECT' }
        comparison = 'exact RC8 Core (A) versus exact OpenXR-input allocation Core (B)'
        order = 'A1 B1 B2 A2 A3 B3'
        dynamicRefresh = $true
        matchedObservedRefreshOnly = $true
        allPairsComparable = $comparable
        allSixProcessIdentitiesFresh = $freshProcessSet
        allThreeCandidateTransactionsFresh = $freshCandidateTransactions
        finalRollbackProved = $finalRollbackProved
        pairs = $pairs
        combined = [pscustomobject][ordered]@{
            matchedP95CpuAndGpuImprovementPercent = if ($null -ne $p95) { [Math]::Round($p95, 2) } else { $null }
            matchedMeanAppFpsChangePercent = if ($null -ne $meanFps) { [Math]::Round($meanFps, 2) } else { $null }
            matchedP10AppFpsChangePercent = if ($null -ne $p10) { [Math]::Round($p10, 2) } else { $null }
            matchedStaleDeltaPerSecond = if ($null -ne $staleDelta) { [Math]::Round($staleDelta, 3) } else { $null }
            matchedStaleImprovementPercent = if ($null -ne $staleImprovement) { [Math]::Round($staleImprovement, 2) } else { $null }
            positiveP95Pairs = $positivePairs
            positiveStalePairs = $positiveStalePairs
            p95AcceptancePathPassed = $p95Path
            staleAcceptancePathPassed = $stalePath
            fpsAndP10GuardrailsPassed = $guardrails
        }
        gates = [pscustomobject][ordered]@{
            expectedCpuLevel = [int]$expectedCpuLevels[0]
            expectedGpuLevel = [int]$expectedGpuLevels[0]
            minimumOverlapPercentPerArm = $MinimumOverlapPercentPerArm
            minimumOverlapSamplesPerPair = $MinimumOverlapSamplesPerPair
            minimumSamplesPerStratum = $MinimumSamplesPerStratum
            maximumStartTemperatureDeltaC = $MaximumStartTemperatureDeltaC
            maximumMatchedTemperatureDeltaC = $MaximumMatchedTemperatureDeltaC
            performanceGatePassed = $performanceGate
            inputAndStereoStillRequireManualReview = $true
            stablePromotionAllowed = $false
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            aggregateOnly = $true
            rawLogsPersisted = $false
            deviceInvocations = 0
            deviceWrites = 0
            configOrProfileMutation = $false
            stableMutation = $false
            rootUsed = $campaignRootUsed
            analysisDeviceAccess = $false
        }
    }
}

function New-FixtureReceipt([int] $Index, [double[]] $Counts, [double] $P95Shift,
        [double] $TempShift = 0.0) {
    $condition = $script:Order[$Index - 1]
    $isB = $condition -ceq 'B'
    $strata = @()
    $hz = @(72.0, 80.0, 90.0)
    for ($i = 0; $i -lt 3; $i++) {
        $strata += [pscustomobject]@{
            Hz = $hz[$i]; Samples = [int]$Counts[$i]
            MeanAppFps = if ($isB) { $hz[$i] * 0.985 } else { $hz[$i] * 0.98 }
            P10AppFps = if ($isB) { $hz[$i] * 0.95 } else { $hz[$i] * 0.945 }
            MeanStalePerSecond = if ($isB) { 1.0 } else { 1.3 }
            P95CpuAndGpuMs = if ($isB) { 13.0 - $P95Shift } else { 13.0 }
            MeanTempC = 42.0 + $TempShift
            TemperatureSampleCount = [int]$Counts[$i]
            TemperatureCoveragePercent = 100.0
        }
    }
    [pscustomobject][ordered]@{
        schemaVersion = 4
        receiptType = 'V71_RC8_INPUT_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE'
        sequenceIndex = $Index
        condition = $condition
        campaignId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        captureId = $Index.ToString('x32')
        capturedAtUtc = ([DateTimeOffset]'2026-09-08T00:00:00Z').AddMinutes(
            (($Index - 1) * 10) + 6).ToString('o')
        previousReceiptSha256 = $null
        deviceBindingSha256 = ('D' * 64)
        worldResetReceiptSha256 = $null
        worldResetRunId = $null
        worldResetCompletedAtUtc = $null
        warmupSecondsObserved = 360.0
        renderScaleFactor = '1.0'
        openXrCopyBatchMode = 'OFF'
        refreshPolicy = 'Dynamic'
        qgoDynamicConfirmed = $true
        durationSeconds = $script:RequiredDurationSeconds
        validForComparison = $true
        identityFence = [pscustomobject]@{
            exactBuildLock=$true; exactInputLock=$true; exactApk=$true
            signerBoundByExactApk=$true; exactCore=$true; exactVeq=$true
            stableStoppedAtBothFences=$true; renderScaleOneAtBothFences=$true
            copyBatchOffAtBothFences=$true; sameProcessAtBothFences=$true
            explicitUsbTransport=$true
            coreSha256=[string]$script:CoreShaByCondition[$condition]
            coreVersion=[string]$script:CoreVersionByCondition[$condition]
            markerState=if ($isB) { 'consumed' } else { 'absent' }
            markerRunId=if ($isB) { $Index.ToString('x32') } else { $null }
            processTokenSha256=Get-TextSha256 "fixture-process-$Index"
            otherModsFingerprintSha256=('A' * 64)
            readAccessMode='Normal'
            stableStoppedThroughout=$true
        }
        benchmarkGate = [pscustomobject]@{
            expectedCpuLevel=4; expectedGpuLevel=4
            cpuExpectedLevelPercent=100.0; gpuExpectedLevelPercent=100.0
            exactPid=$true; focusPercent=100.0
            polls=180; stableKnownPolls=180; stableStoppedPolls=180
            stablePollErrors=0; stableStoppedAtStart=$true
            stableStoppedAtEnd=$true
        }
        aggregate = [pscustomobject]@{
            VrApiSamples = [int](($Counts | Measure-Object -Sum).Sum)
            FirstTempC = 42.0 + $TempShift
            TemperatureSampleCount = [int](($Counts | Measure-Object -Sum).Sum)
            TemperatureCoveragePercent = 100.0
            RefreshMetricStrata = $strata
        }
    }
}

function Complete-FixtureCampaign([object[]] $Receipts) {
    $hashes = @()
    $resets = @()
    $base = [DateTimeOffset]'2026-09-08T00:00:00Z'
    for ($offset = 0; $offset -lt $Receipts.Count; $offset++) {
        $index = $offset + 1
        $resetAt = $base.AddMinutes($offset * 10)
        $resetId = (100 + $index).ToString('x32')
        $resetSha = Get-TextSha256 "fixture-reset-$index"
        $Receipts[$offset].capturedAtUtc = $resetAt.AddMinutes(6).ToString('o')
        $Receipts[$offset].previousReceiptSha256 = if ($offset -eq 0) {
            $null
        } else {
            [string]$hashes[$offset - 1]
        }
        $Receipts[$offset].worldResetReceiptSha256 = $resetSha
        $Receipts[$offset].worldResetRunId = $resetId
        $Receipts[$offset].worldResetCompletedAtUtc = $resetAt.ToString('o')
        $resets += [pscustomobject][ordered]@{
            Sha256 = $resetSha
            ResetRunId = $resetId
            CompletedAt = $resetAt
            CompletedAtUtc = $resetAt.ToString('o')
            DeviceBindingSha256 = Get-TextSha256 "fixture-reset-device-$index"
            SnapshotState = 'SNAPSHOT'
            SnapshotSha256 = ('B' * 64)
            AccessMode = 'Normal'
        }
        $hashes += Get-TextSha256 ($Receipts[$offset] | ConvertTo-Json -Depth 20)
    }
    $final = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC8_INPUT_PERFORMANCE_FINAL_ROLLBACK'
        finalizeId = 'ffffffffffffffffffffffffffffffff'
        completedAtUtc = $base.AddMinutes(56.5).ToString('o')
        campaignId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        previousReceiptSha256 = [string]$hashes[5]
        deviceBindingSha256 = ('D' * 64)
        rolledBackCandidateRunId = [string]$Receipts[5].identityFence.markerRunId
        otherModsFingerprintSha256 = ('A' * 64)
        baselineCoreSha256 = $script:BaselineCoreSha256
        baselineCoreVersion = $script:BaselineCoreVersion
        apkSha256 = $script:ApkSha256
        veqSha256 = $script:VeqSha256
        markerState = 'absent'
        readAccessMode = 'Normal'
        exactBaseline = $true
        markerAbsent = $true
        stableStoppedAtBothFences = $true
        labStoppedAtBothFences = $true
        renderScaleOne = $true
        explicitUsbTransport = $true
    }
    [pscustomobject][ordered]@{
        Receipts = $Receipts
        Hashes = [string[]]$hashes
        Resets = [object[]]$resets
        Final = $final
    }
}

function Analyze-FixtureReceipts([object[]] $Receipts) {
    $campaign = Complete-FixtureCampaign $Receipts
    Analyze-Receipts $campaign.Receipts $campaign.Hashes $campaign.Resets $campaign.Final
}

function Invoke-SelfTest {
    $fixtures = @(
        New-FixtureReceipt 1 @(25,20,15) 0.5
        New-FixtureReceipt 2 @(20,25,15) 0.5 0.2
        New-FixtureReceipt 3 @(22,18,20) 0.5 0.3
        New-FixtureReceipt 4 @(18,22,20) 0.5 0.1
        New-FixtureReceipt 5 @(20,20,20) 0.5
        New-FixtureReceipt 6 @(24,18,18) 0.5 0.2
    )
    $accepted = Analyze-FixtureReceipts $fixtures
    Require ($accepted.result -ceq 'PERFORMANCE_CANDIDATE' -and
            $accepted.allPairsComparable -and
            $accepted.combined.positiveP95Pairs -eq 3) `
        'Matched-refresh fixture was not accepted.'

    $staleOnly = @($fixtures | ForEach-Object {
        $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    })
    foreach ($receipt in $staleOnly | Where-Object { $_.condition -ceq 'B' }) {
        foreach ($stratum in $receipt.aggregate.RefreshMetricStrata) {
            $stratum.P95CpuAndGpuMs = 13.1
        }
    }
    $staleAccepted = Analyze-FixtureReceipts $staleOnly
    Require ($staleAccepted.result -ceq 'PERFORMANCE_CANDIDATE' -and
            -not $staleAccepted.combined.p95AcceptancePathPassed -and
            $staleAccepted.combined.staleAcceptancePathPassed -and
            $staleAccepted.combined.positiveStalePairs -eq 3) `
        'A reproducible stale-only improvement was not accepted.'

    $p95Only = @($fixtures | ForEach-Object {
        $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    })
    foreach ($receipt in $p95Only | Where-Object { $_.condition -ceq 'B' }) {
        foreach ($stratum in $receipt.aggregate.RefreshMetricStrata) {
            $stratum.MeanStalePerSecond = 1.4
        }
    }
    $p95Accepted = Analyze-FixtureReceipts $p95Only
    Require ($p95Accepted.result -ceq 'PERFORMANCE_CANDIDATE' -and
            $p95Accepted.combined.p95AcceptancePathPassed -and
            -not $p95Accepted.combined.staleAcceptancePathPassed -and
            $p95Accepted.combined.positiveStalePairs -eq 0) `
        'A reproducible P95-only improvement was not accepted.'

    $badOrder = @($fixtures)
    $badOrder[1] = $fixtures[0]
    Require (Test-Throws { Analyze-FixtureReceipts $badOrder | Out-Null }) `
        'A non-counterbalanced sequence was accepted.'

    $noOverlap = @($fixtures | ForEach-Object { $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json })
    $noOverlap[1].aggregate.RefreshMetricStrata = @(
        [pscustomobject]@{
            Hz=120.0; Samples=60; MeanAppFps=118.0; P10AppFps=115.0
            MeanStalePerSecond=1.0; P95CpuAndGpuMs=12.5; MeanTempC=42.0
            TemperatureSampleCount=60; TemperatureCoveragePercent=100.0
        })
    $noOverlap[1].aggregate.VrApiSamples = 60
    $inconclusive = Analyze-FixtureReceipts $noOverlap
    Require ($inconclusive.result -ceq 'INCONCLUSIVE' -and
            -not $inconclusive.allPairsComparable) `
        'Insufficient observed-refresh overlap was accepted.'

    $hot = @($fixtures | ForEach-Object { $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json })
    $hot[1].aggregate.FirstTempC = 45.0
    $thermal = Analyze-FixtureReceipts $hot
    Require ($thermal.result -ceq 'INCONCLUSIVE') `
        'A start-temperature mismatch was accepted.'

    $duplicateProcess = @($fixtures | ForEach-Object {
        $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    })
    $duplicateProcess[1].identityFence.processTokenSha256 =
        $duplicateProcess[0].identityFence.processTokenSha256
    $notFresh = Analyze-FixtureReceipts $duplicateProcess
    Require ($notFresh.result -ceq 'INCONCLUSIVE' -and
            -not $notFresh.allSixProcessIdentitiesFresh) `
        'A reused Lab process identity was accepted.'

    $fpsRegression = @($fixtures | ForEach-Object {
        $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    })
    foreach ($receipt in $fpsRegression | Where-Object { $_.condition -ceq 'B' }) {
        foreach ($stratum in $receipt.aggregate.RefreshMetricStrata) {
            $stratum.MeanAppFps = [double]$stratum.MeanAppFps * 0.95
            $stratum.P10AppFps = [double]$stratum.P10AppFps * 0.95
        }
    }
    $guardrail = Analyze-FixtureReceipts $fpsRegression
    Require ($guardrail.result -ceq 'REJECT' -and
            -not $guardrail.combined.fpsAndP10GuardrailsPassed) `
        'An FPS/P10 regression greater than one percent was accepted.'

    $roundedP95Edge = @($fixtures | ForEach-Object {
        $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    })
    foreach ($receipt in $roundedP95Edge | Where-Object { $_.condition -ceq 'B' }) {
        foreach ($stratum in $receipt.aggregate.RefreshMetricStrata) {
            $stratum.P95CpuAndGpuMs = 13.0 * (1.0 - 0.01996)
            $stratum.MeanStalePerSecond = 1.3
        }
    }
    $p95Edge = Analyze-FixtureReceipts $roundedP95Edge
    Require ($p95Edge.result -ceq 'REJECT' -and
            $p95Edge.combined.matchedP95CpuAndGpuImprovementPercent -eq 2.0 -and
            -not $p95Edge.combined.p95AcceptancePathPassed) `
        'A sub-2% P95 result was accepted after display rounding.'

    $roundedFpsEdge = @($fixtures | ForEach-Object {
        $_ | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    })
    foreach ($receipt in $roundedFpsEdge | Where-Object { $_.condition -ceq 'B' }) {
        foreach ($stratum in $receipt.aggregate.RefreshMetricStrata) {
            $stratum.MeanAppFps = [double]$stratum.Hz * 0.98 * (1.0 - 0.01004)
        }
    }
    $fpsEdge = Analyze-FixtureReceipts $roundedFpsEdge
    Require ($fpsEdge.result -ceq 'REJECT' -and
            $fpsEdge.combined.matchedMeanAppFpsChangePercent -eq -1.0 -and
            -not $fpsEdge.combined.fpsAndP10GuardrailsPassed) `
        'A worse-than-1% mean-FPS result was accepted after display rounding.'

    Require (Test-ExplicitNonNetworkAdbSerial 'QUEST_USB_FIXTURE') `
        'A local USB-shaped fixture serial was rejected.'
    foreach ($badSerial in @('', 'auto', '192.0.2.2:5555',
            'adb-QUEST._adb-tls-connect._tcp', 'quest.local', 'a/b', 'a\b')) {
        Require (-not (Test-ExplicitNonNetworkAdbSerial $badSerial)) `
            "A network/ambiguous fixture serial was accepted: $badSerial"
    }
    $pnpParent = 'USB\VID_2833&PID_5013\QUEST_USB_FIXTURE'
    $pnpChildren = @([pscustomobject][ordered]@{
        InstanceId='USB\VID_2833&PID_5013&MI_01\ADB_FIXTURE'
        FriendlyName='Oculus Composite ADB Interface'
        Status='OK'; Present=$true; ParentInstanceId=$pnpParent
    })
    $pnpParents = @([pscustomobject][ordered]@{
        InstanceId=$pnpParent; Status='OK'; Present=$true
    })
    Require (Assert-WindowsUsbPnpSnapshot -ExpectedSerial 'QUEST_USB_FIXTURE' `
            -Children $pnpChildren -Parents $pnpParents) `
        'A valid exact Quest/ADB PnP fixture was rejected.'
    $badPnpChildren = @([pscustomobject][ordered]@{
        InstanceId='USB\VID_2833&PID_5013&MI_01\ADB_FIXTURE'
        FriendlyName='Oculus Composite ADB Interface'
        Status='Error'; Present=$true; ParentInstanceId=$pnpParent
    })
    Require (Test-Throws {
        Assert-WindowsUsbPnpSnapshot -ExpectedSerial 'QUEST_USB_FIXTURE' `
            -Children $badPnpChildren -Parents $pnpParents | Out-Null
    }) 'An unhealthy Windows ADB child passed the USB proof.'

    Require ($script:DeviceInvocations -eq 0 -and $script:HostWrites -eq 0) `
        'SelfTest touched ADB or wrote Host evidence.'
    [pscustomobject][ordered]@{
        Result = 'PASS'; HostOnly = $true; Assertions = $script:Assertions
        DeviceInvocations = 0; HostWrites = 0
        DynamicRefreshStratification = $true
        CounterbalancedOrder = 'A1 B1 B2 A2 A3 B3'; StableTouched = $false
        FreshProcessIdentityRequired = $true
        CopyBatchMode = 'OFF'
    }
}

Assert-HostContract
Assert-FixedAnalysisContract

if ($Action -ceq 'SelfTest') { Invoke-SelfTest; return }
if ($Action -ceq 'Status') {
    Require (-not $AllowDeviceRead -and -not $AllowHostOutput -and
            -not $ConfirmExactRc8Lab -and -not $ConfirmQgoDynamic -and
            -not $AllowRootFallback) `
        'Host-only Status rejects runtime authorization switches.'
    [pscustomobject][ordered]@{
        Result='PASS'; HostOnly=$true; ExactRc8Lock=$true
        PackageClass='LAB_ONLY'; DynamicRefresh=$true
        Comparison='exact-RC8-vs-OpenXR-input-allocation'
        RequiredOrder='A1 B1 B2 A2 A3 B3'
        RenderScaleFactor='1.0'; OpenXrCopyBatchMode='OFF'
        RequiredWarmupSeconds=$script:RequiredWarmupSeconds
        RequiredDurationSeconds=$script:RequiredDurationSeconds
        WorldResetReceiptRequired=$true; FinalRollbackReceiptRequired=$true
        ExplicitUsbSerialRequired=$true
        DeviceInvocations=0; HostWrites=0; StableTouched=$false
    }
    return
}

if ($Action -ceq 'Analyze') {
    Require (-not $AllowDeviceRead -and -not $ConfirmExactRc8Lab -and
            -not $ConfirmQgoDynamic -and -not $AllowRootFallback) `
        'Analyze is Host-only and rejects device authorization.'
    $directory = Resolve-ArtifactChild $InputDirectory
    Require (Test-Path -LiteralPath $directory -PathType Container) `
        'Analyze input must be a directory.'
    $artifacts = Read-CompleteCampaignArtifacts $directory
    $finalRollbackPath = Join-Path $directory '07-final-rollback.json'
    $finalRollback = Read-JsonObjectFile $finalRollbackPath 'Final rollback receipt'
    $analysis = Analyze-Receipts $artifacts.Receipts $artifacts.Hashes `
        $artifacts.Resets $finalRollback
    if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
        Require $AllowHostOutput.IsPresent 'Writing analysis requires -AllowHostOutput.'
        $output = Resolve-ArtifactChild $OutputJson -MayBeMissing
        Require ([IO.Path]::GetExtension($output) -ceq '.json') 'Analysis output must be JSON.'
        Write-JsonAtomic $output $analysis
    } else {
        Require (-not $AllowHostOutput) 'Unused -AllowHostOutput was rejected.'
    }
    $analysis
    return
}

if ($Action -ceq 'Finalize') {
    Require $AllowDeviceRead.IsPresent 'Finalize requires -AllowDeviceRead.'
    Require $ConfirmExactRc8Lab.IsPresent 'Finalize requires -ConfirmExactRc8Lab.'
    Require $AllowHostOutput.IsPresent 'Finalize requires -AllowHostOutput.'
    Require (-not $ConfirmQgoDynamic.IsPresent) `
        'Finalize rejects an unused QGO confirmation.'
    Require (Test-ExplicitNonNetworkAdbSerial $Serial) `
        'Finalize requires the same explicit USB hardware serial.'
    $directory = Resolve-ArtifactChild $OutputDirectory
    Require (Test-Path -LiteralPath $directory -PathType Container) `
        'Finalize output must be the completed campaign directory.'
    $finalPath = Join-Path $directory '07-final-rollback.json'
    Require (-not (Test-Path -LiteralPath $finalPath)) `
        'The final rollback receipt already exists.'
    $artifacts = Read-CompleteCampaignArtifacts $directory -ExpectedSerial $Serial
    $campaign = Assert-CampaignEvidence $artifacts.Receipts $artifacts.Hashes `
        $artifacts.Resets
    $expectedDeviceBinding = Get-TextSha256 (
        "rc8-input-perf-device-v1`ncampaign=$($campaign.CampaignId)`nserial=$Serial")
    Require ($campaign.DeviceBindingSha256 -ceq $expectedDeviceBinding) `
        'The completed campaign belongs to another device.'
    Resolve-Device
    $rolledBack = Assert-ExactDeviceIdentity 'A' -StoppedLab
    Require ([string]$rolledBack.OtherModsFingerprintSha256 -ceq
            [string]$campaign.OtherModsFingerprintSha256) `
        'Final rollback changed the other-mod set.'
    $finalReceipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC8_INPUT_PERFORMANCE_FINAL_ROLLBACK'
        finalizeId = [Guid]::NewGuid().ToString('N')
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        campaignId = [string]$campaign.CampaignId
        previousReceiptSha256 = [string]$campaign.LastReceiptSha256
        deviceBindingSha256 = $expectedDeviceBinding
        rolledBackCandidateRunId = [string]$campaign.LastCandidateRunId
        otherModsFingerprintSha256 = [string]$rolledBack.OtherModsFingerprintSha256
        baselineCoreSha256 = $script:BaselineCoreSha256
        baselineCoreVersion = $script:BaselineCoreVersion
        apkSha256 = $script:ApkSha256
        veqSha256 = $script:VeqSha256
        markerState = [string]$rolledBack.Marker.State
        readAccessMode = [string]$rolledBack.AccessMode
        exactBaseline = $true
        markerAbsent = ([string]$rolledBack.Marker.State -ceq 'absent')
        stableStoppedAtBothFences = $true
        labStoppedAtBothFences = $true
        renderScaleOne = $true
        explicitUsbTransport = $true
    }
    Write-JsonAtomic $finalPath $finalReceipt
    [pscustomobject][ordered]@{
        Result='FINAL_ROLLBACK_PROVED'; CampaignId=[string]$campaign.CampaignId
        ReceiptFileName=[IO.Path]::GetFileName($finalPath)
        BaselineCoreSha256=$script:BaselineCoreSha256
        MarkerState='absent'; StableTouched=$false; DeviceWrites=0
    }
    return
}

Require $AllowDeviceRead.IsPresent 'Capture requires -AllowDeviceRead.'
Require $ConfirmExactRc8Lab.IsPresent 'Capture requires -ConfirmExactRc8Lab.'
Require $ConfirmQgoDynamic.IsPresent 'Capture requires -ConfirmQgoDynamic.'
Require $AllowHostOutput.IsPresent 'Capture requires -AllowHostOutput.'
Require (Test-ExplicitNonNetworkAdbSerial $Serial) `
    'Capture requires one explicit non-network USB hardware serial.'
Require ($Seconds -eq $script:RequiredDurationSeconds) `
    'Every campaign arm requires the fixed 180-second aggregate.'
$expectedCondition = $script:Order[$SequenceIndex - 1]
Require ($Condition -ceq $expectedCondition) 'Condition does not match AB/BA/AB order.'
Require ($DeclaredRenderScale -ceq '1.0') `
    'Both input A/B conditions require declared render scale 1.0.'
$directory = Resolve-ArtifactChild $OutputDirectory
Require (Test-Path -LiteralPath $directory -PathType Container) `
    'Capture output must be a directory.'
$finalPath = Join-Path $directory ('{0:D2}-{1}.json' -f $SequenceIndex, $Condition)
Require (-not (Test-Path -LiteralPath $finalPath)) 'This sequence receipt already exists.'
$prefix = Read-CampaignPrefix -Directory $directory -NextIndex $SequenceIndex `
    -ExpectedSerial $Serial
$campaignId = [string]$prefix.CampaignId
$deviceBindingSha256 = Get-TextSha256 (
    "rc8-input-perf-device-v1`ncampaign=$campaignId`nserial=$Serial")
if ($SequenceIndex -gt 1) {
    Require ([string]$prefix.DeviceBindingSha256 -ceq $deviceBindingSha256) `
        'This arm belongs to another campaign device.'
}
Resolve-Device
$initial = Assert-ExactDeviceIdentity $expectedCondition
Require ([double]$initial.Process.AgeSeconds -ge $script:RequiredWarmupSeconds) `
    'The fresh Lab process did not complete the fixed five-minute warm-up.'
$resetMinusProcessAge = [double]$prefix.CurrentReset.AgeSeconds -
    [double]$initial.Process.AgeSeconds
Require ($resetMinusProcessAge -ge -5.0 -and $resetMinusProcessAge -le 120.0) `
    'The live process was not freshly launched after this arm world reset.'
if ($SequenceIndex -gt 1) {
    Require ([string]$initial.OtherModsFingerprintSha256 -ceq
            [string]$prefix.OtherModsFingerprintSha256) `
        'The other-mod set changed between campaign arms.'
}
$temporary = Join-Path $directory ('.vrapi-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    $benchmarkResult = & $script:BenchmarkPath -Action Capture `
        -Package $script:Package -ForbiddenPackage $script:StablePackage `
        -Serial $script:Device -AdbPath $script:Adb `
        -Seconds $Seconds -ExpectedRefreshHz 72 -DynamicRefresh `
        -MinimumSampleCoveragePercent 60 -PollSeconds 1 -OutputJson $temporary
    Require (Test-Path -LiteralPath $temporary -PathType Leaf) `
        'The aggregate benchmark did not publish its receipt.'
    $rawAggregate = Get-Content -Raw -LiteralPath $temporary | ConvertFrom-Json -Depth 20
    $benchmarkReasons = @($rawAggregate.InvalidReasons | ForEach-Object { [string]$_ })
    Require ([string]$rawAggregate.Package -ceq $script:Package -and
            [string]$rawAggregate.RefreshPolicy -ceq 'Dynamic' -and
            (Get-StrictBoolean $rawAggregate.ValidForComparison 'Benchmark ValidForComparison') -and
            -not (Get-StrictBoolean $rawAggregate.RawLogsPersisted 'Benchmark RawLogsPersisted') -and
            -not (Get-StrictBoolean $rawAggregate.RawProcessRowsPersisted 'Benchmark RawProcessRowsPersisted')) `
        ('The aggregate VrApi benchmark did not pass its read-only quality gates: ' +
            ($benchmarkReasons -join '; '))
    Require ([int]$rawAggregate.AppPid -eq [int]$initial.Process.Pid -and
            [double]$rawAggregate.ExactPidPollPercent -eq 100.0 -and
            [double]$rawAggregate.FocusedPollPercent -ge 95.0) `
        'The aggregate benchmark was not bound to the exact focused Lab process.'
    $runtimePolls = Get-StrictInteger $rawAggregate.Polls 'Benchmark Polls' 1 ([int]::MaxValue)
    $stableKnownPolls = Get-StrictInteger $rawAggregate.ForbiddenPackageKnownPolls `
        'Benchmark Stable known polls' 0 $runtimePolls
    $stableStoppedPolls = Get-StrictInteger $rawAggregate.ForbiddenPackageStoppedPolls `
        'Benchmark Stable stopped polls' 0 $runtimePolls
    Require ($stableKnownPolls -eq $runtimePolls -and
            [int]$rawAggregate.ForbiddenPackagePollErrors -eq 0 -and
            [double]$rawAggregate.ForbiddenPackageStoppedPollPercent -eq 100.0 -and
            (Get-StrictBoolean $rawAggregate.ForbiddenPackageStoppedAtStart `
                'Benchmark Stable stopped at start') -and
            (Get-StrictBoolean $rawAggregate.ForbiddenPackageStoppedAtEnd `
                'Benchmark Stable stopped at end')) `
        'Stable was not conclusively stopped throughout the capture window.'
    Require (@($rawAggregate.Aggregate.RefreshMetricStrata).Count -gt 0) `
        'The benchmark omitted matched-refresh metrics.'
    $strataProbe = [pscustomobject]@{ aggregate = $rawAggregate.Aggregate }
    $null = Get-ReceiptStrata $strataProbe 'Captured aggregate'
    $cpuExpectedRows = @($rawAggregate.Aggregate.CpuLevelDistribution | Where-Object {
        [int]$_.Level -eq $ExpectedCpuLevel
    })
    $gpuExpectedRows = @($rawAggregate.Aggregate.GpuLevelDistribution | Where-Object {
        [int]$_.Level -eq $ExpectedGpuLevel
    })
    Require ($cpuExpectedRows.Count -le 1 -and $gpuExpectedRows.Count -le 1) `
        'The CPU/GPU performance-level distribution was ambiguous.'
    $cpuExpectedPercent = if ($cpuExpectedRows.Count -eq 1) {
        [double]$cpuExpectedRows[0].PercentOfVrApiSamples
    } else { 0.0 }
    $gpuExpectedPercent = if ($gpuExpectedRows.Count -eq 1) {
        [double]$gpuExpectedRows[0].PercentOfVrApiSamples
    } else { 0.0 }
    Require ([double]$rawAggregate.Aggregate.CpuLevelCoveragePercent -ge 95.0 -and
            [double]$rawAggregate.Aggregate.GpuLevelCoveragePercent -ge 95.0 -and
            $cpuExpectedPercent -ge 95.0 -and $gpuExpectedPercent -ge 95.0) `
        "The capture did not remain at declared CPU/GPU levels $ExpectedCpuLevel/$ExpectedGpuLevel with sufficient telemetry coverage."
    $final = Assert-ExactDeviceIdentity $expectedCondition
    Require ([int]$initial.Process.Pid -eq [int]$final.Process.Pid -and
            [int64]$initial.Process.StartTicks -eq [int64]$final.Process.StartTicks -and
            [string]$initial.Process.TokenSha256 -ceq
                [string]$final.Process.TokenSha256) `
        'The Lab process identity changed during capture.'
    Require ([string]$initial.Marker.State -ceq [string]$final.Marker.State -and
            [string]$initial.Marker.OpenXrCopyBatchMode -ceq 'OFF' -and
            [string]$final.Marker.OpenXrCopyBatchMode -ceq 'OFF' -and
            [string]$initial.Marker.RunId -ceq [string]$final.Marker.RunId) `
        'The one-variable canary transaction changed during capture.'
    Require ([string]$initial.OtherModsFingerprintSha256 -ceq
                [string]$final.OtherModsFingerprintSha256 -and
            [string]$initial.AccessMode -ceq [string]$final.AccessMode) `
        'The other-mod fingerprint/access mode changed during capture.'
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 4
        receiptType = 'V71_RC8_INPUT_DYNAMIC_REFRESH_PERFORMANCE_AGGREGATE'
        sequenceIndex = $SequenceIndex
        condition = $Condition
        campaignId = $campaignId
        captureId = [Guid]::NewGuid().ToString('N')
        capturedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        previousReceiptSha256 = [string]$prefix.PreviousReceiptSha256
        deviceBindingSha256 = $deviceBindingSha256
        worldResetReceiptSha256 = [string]$prefix.CurrentReset.Sha256
        worldResetRunId = [string]$prefix.CurrentReset.ResetRunId
        worldResetCompletedAtUtc = [string]$prefix.CurrentReset.CompletedAtUtc
        warmupSecondsObserved = [Math]::Round([double]$initial.Process.AgeSeconds, 2)
        renderScaleFactor = '1.0'
        openXrCopyBatchMode = 'OFF'
        refreshPolicy = 'Dynamic'
        qgoDynamicConfirmed = $true
        durationSeconds = $Seconds
        validForComparison = $true
        identityFence = [pscustomobject][ordered]@{
            exactBuildLock = $true; exactInputLock = $true; exactApk = $true
            signerBoundByExactApk = $true; signerSha256 = $script:SignerSha256
            exactCore = $true
            coreSha256 = [string]$initial.CoreSha256
            coreVersion = [string]$initial.CoreVersion
            exactVeq = $true
            stableStoppedAtBothFences = [bool]($initial.StableStopped -and $final.StableStopped)
            stableStoppedThroughout = $true
            renderScaleOneAtBothFences = $true
            copyBatchOffAtBothFences = $true
            markerState = [string]$initial.Marker.State
            markerRunId = [string]$initial.Marker.RunId
            sameProcessAtBothFences = $true
            processTokenSha256 = [string]$initial.Process.TokenSha256
            otherModsFingerprintSha256 = [string]$initial.OtherModsFingerprintSha256
            readAccessMode = [string]$initial.AccessMode
            explicitUsbTransport = $true
            usbTransportProofMethod = [string]$script:UsbTransportProofMethod
        }
        benchmarkGate = [pscustomobject][ordered]@{
            exactPid = ([double]$rawAggregate.ExactPidPollPercent -eq 100.0)
            focusPercent = [double]$rawAggregate.FocusedPollPercent
            sampleCoveragePercent = [double]$rawAggregate.SampleCoveragePercent
            expectedCpuLevel = $ExpectedCpuLevel
            expectedGpuLevel = $ExpectedGpuLevel
            cpuExpectedLevelPercent = $cpuExpectedPercent
            gpuExpectedLevelPercent = $gpuExpectedPercent
            polls = [int]$runtimePolls
            stableKnownPolls = [int]$stableKnownPolls
            stableStoppedPolls = [int]$stableStoppedPolls
            stablePollErrors = [int]$rawAggregate.ForbiddenPackagePollErrors
            stableStoppedAtStart = [bool]$rawAggregate.ForbiddenPackageStoppedAtStart
            stableStoppedAtEnd = [bool]$rawAggregate.ForbiddenPackageStoppedAtEnd
            externalProcessGuard = $rawAggregate.ExternalProcessGuard
        }
        aggregate = $rawAggregate.Aggregate
        evidenceBoundary = [pscustomobject][ordered]@{
            aggregateOnly = $true; rawLogsPersisted = $false
            rawProcessRowsPersisted = $false; deviceReadsOnly = $true
            deviceWrites = 0; installLaunchStopMutation = $false
            rootReadUsed = ([string]$initial.AccessMode -ceq 'Root')
            configOrProfileMutation = $false; stableMutation = $false
        }
    }
    Write-JsonAtomic $finalPath $receipt
    [pscustomobject][ordered]@{
        Result='PASS'; SequenceIndex=$SequenceIndex; Condition=$Condition
        CampaignId=$campaignId
        CoreSha256=[string]$initial.CoreSha256
        RenderScaleFactor='1.0'; OpenXrCopyBatchMode='OFF'; RefreshPolicy='Dynamic'
        AggregateFileName=[IO.Path]::GetFileName($finalPath)
        ValidForComparison=$true; DeviceReadsOnly=$true
        DeviceWrites=0; StableTouched=$false; RawLogsPersisted=$false
    }
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        [IO.File]::Delete($temporary)
    }
}
