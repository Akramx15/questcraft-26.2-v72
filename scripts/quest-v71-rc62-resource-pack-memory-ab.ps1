#requires -Version 7.0
<#
.SYNOPSIS
Fail-closed, read-only RC6.2 resource-pack memory A/B evidence wrapper.

.DESCRIPTION
This harness never selects a resource pack, edits options/profile data, starts
or stops an app, or invokes a package mutation. Begin and Finalize perform only
bounded device reads around an independently run, immutable RC6.2 memory
sampler. Finalize emits a supplementary receipt only after the same process,
exact APK/Core/VEQ, exact latest.log inode, ResourceManager condition, and (for
non-vanilla conditions) physical resource-pack SHA-256 remain bound across a
minimum thirty-minute sampler result. Each fence also requires exactly one
blocks-atlas creation line after the latest ResourceManager line and records
its supplied width, height, and miplevel without inferring them from pack name.

The immutable sampler's Sample action has a separately authorized thermal-stop
contract. This wrapper deliberately does not invoke that action, because this
harness has a stricter zero-device-mutation boundary. Run the sampler as a
separate, supervised step, then supply its finalized summary.json and
samples.jsonl to Finalize.

Compare is Host-only. It binds two distinct finalized condition receipts and
reports simple B-minus-A deltas. It does not claim causality, formal memory
acceptance, or Stable-promotion authorization.
#>
[CmdletBinding()]
param(
    [ValidateSet('SelfTest', 'Begin', 'Finalize', 'Compare')]
    [string] $Action = 'SelfTest',

    [ValidateSet('Vanilla', 'Original', 'Probe512', 'HalfGe256', 'Cap128')]
    [string] $Condition = 'Vanilla',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',

    [string] $AdbPath = 'adb',
    [switch] $AllowDeviceRead,
    [switch] $AllowRootRead,

    [string] $OutputDirectory = '',
    [string] $SamplerSummaryPath = '',
    [string] $SamplerSamplesPath = '',
    [string] $ReceiptAPath = '',
    [string] $ReceiptBPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Package = 'com.qcxr.qcxr.canary262'
$script:StablePackage = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:VersionCode = 71
$script:VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.6.2'
$script:ApkSha256 = 'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4'
$script:CoreVersion = '26.2-1.3.15+qc.v71.rc6.2'
$script:CoreSha256 = '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF'
$script:VeqVersion = '0.7.0-v71.rc6'
$script:VeqSha256 = 'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
$script:SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:SamplerRelativePath = 'scripts/quest-v71-memory-soak-rc62.ps1'
$script:SamplerSha256 = '75F5D720A3FC6396109D6D96820F2F75AE8A8327F317A41AE811CBBF781CD433'
$script:SamplerPath = Join-Path $script:RepoRoot $script:SamplerRelativePath
$script:BuildLockPath = Join-Path $script:RepoRoot 'V71_LAB_RC6_2.lock.json'
$script:ProducerLockPath = Join-Path $script:RepoRoot 'V71_RC6_2_EVIDENCE_PRODUCERS.lock.json'
$script:GameRoot = "/sdcard/Android/data/$($script:Package)/files/instances/$($script:Profile)"
$script:GameLogPath = "$($script:GameRoot)/logs/latest.log"
$script:CorePath = "$($script:GameRoot)/mods/Vivecraft.jar"
$script:VeqPath = "$($script:GameRoot)/mods/Vivecraft-Essentials-Quest.jar"
$script:PackDirectory = "$($script:GameRoot)/resourcepacks"
$script:LogFreshnessSeconds = 60
$script:MaximumResourceManagerLines = 256
$script:MaximumFilteredLogLines = 512
$script:MaximumGameLogBytes = 64MB
$script:EvidenceRootRelative = 'artifacts/memory'
$script:DeviceInvocations = 0
$script:Adb = $null
$script:Device = $null
$script:Assertions = 0

$script:PackContracts = [ordered]@{
    Vanilla = [pscustomobject][ordered]@{
        Name = 'Vanilla'
        FileName = $null
        FileToken = $null
        Sha256 = $null
    }
    Original = [pscustomobject][ordered]@{
        Name = 'Original'
        FileName = 'LunarLabs-26.2-Quest-Vulkan-v2.zip'
        FileToken = 'file/LunarLabs-26.2-Quest-Vulkan-v2.zip'
        Sha256 = '227FF427604E4503BAF06A9766977EB7F926841A4325428069A40DC21FCB67D8'
    }
    Probe512 = [pscustomobject][ordered]@{
        Name = 'Probe512'
        FileName = 'LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-probe512.zip'
        FileToken = 'file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-probe512.zip'
        Sha256 = '47DD0C418556E9DC5FEF6B92A2553F51D6BBAB1DFE8968E63AF046527E920D40'
    }
    HalfGe256 = [pscustomobject][ordered]@{
        Name = 'HalfGe256'
        FileName = 'LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-half-ge256.zip'
        FileToken = 'file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-half-ge256.zip'
        Sha256 = 'CAA755B12CA9D716E31C90ED6AECEE2163D0638FA67133D1EF841FE20C104C4A'
    }
    Cap128 = [pscustomobject][ordered]@{
        Name = 'Cap128'
        FileName = 'LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-cap128.zip'
        FileToken = 'file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-cap128.zip'
        Sha256 = '48B33A0061B320FBD5A587D371CAE872ECF937D0949E6D7632015351B48DE05D'
    }
}

function Require {
    param([bool] $ConditionValue, [string] $Message)
    $script:Assertions++
    if (-not $ConditionValue) {
        throw "[V71_RC6_2_PACK_MEMORY_AB] $Message"
    }
}

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock] $Operation)
    try {
        & $Operation
        return $false
    } catch {
        return $true
    }
}

function Get-RequiredProperty {
    param($Object, [string] $Name, [string] $Context)
    Require ($null -ne $Object) "$Context is absent."
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context.$Name is absent."
    return $property.Value
}

function Test-ExactTrue {
    param($Value)
    return $Value -is [bool] -and [bool]$Value
}

function Test-ExactFalse {
    param($Value)
    return $Value -is [bool] -and -not [bool]$Value
}

function ConvertTo-CanonicalSha256 {
    param($Value, [string] $Context)
    Require ($Value -is [string]) "$Context must be a string."
    $normalized = ([string]$Value).ToUpperInvariant()
    Require ($normalized -cmatch '^[0-9A-F]{64}$' -and
        $normalized -cne ('0' * 64)) "$Context is not a nonzero SHA-256."
    return $normalized
}

function Get-CanonicalPath {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-PathContained {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [switch] $AllowRoot
    )
    $full = Get-CanonicalPath $Path
    $fullRoot = Get-CanonicalPath $Root
    $inside = $full.StartsWith(
        $fullRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)
    Require ($inside -or ($AllowRoot.IsPresent -and $full -ceq $fullRoot)) `
        "A Host path escaped its fixed root: $full"
    return $full
}

function Assert-NoReparsePoint {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )
    $fullRoot = Get-CanonicalPath $Root
    $full = Assert-PathContained -Path $Path -Root $Root -AllowRoot
    $current = $fullRoot
    if (Test-Path -LiteralPath $current) {
        Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint)) `
            "A protected Host path is a reparse point: $current"
    }
    if ($full -ceq $fullRoot) { return }
    $relative = [IO.Path]::GetRelativePath($fullRoot, $full)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar) |
            Where-Object { -not [string]::IsNullOrEmpty($_) }) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint)) `
                "A protected Host path component is a reparse point: $current"
        }
    }
}

function ConvertTo-RepoRelativePath {
    param([Parameter(Mandatory)][string] $Path)
    $full = Assert-PathContained -Path $Path -Root $script:RepoRoot
    return [IO.Path]::GetRelativePath($script:RepoRoot, $full).Replace('\', '/')
}

function Enter-LockedUtf8File {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Context,
        [int64] $MaximumBytes = 16MB
    )
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    Assert-NoReparsePoint -Path $Path -Root $script:RepoRoot
    $full = Assert-PathContained -Path $Path -Root $script:RepoRoot
    $stream = $null
    try {
        $stream = [IO.File]::Open($full, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        Require ($stream.Length -gt 0 -and $stream.Length -le $MaximumBytes) `
            "$Context has an unsafe byte length."
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            Require ($read -gt 0) "$Context ended during its locked read."
            $offset += $read
        }
        Require (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
                $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) `
            "$Context must use UTF-8 without a byte-order mark."
        try {
            $text = [Text.UTF8Encoding]::new($false, $true).GetString(
                $bytes)
        } catch {
            throw "[V71_RC6_2_PACK_MEMORY_AB] $Context is not strict UTF-8."
        }
        return [pscustomobject]@{
            Path = $full
            Stream = $stream
            Text = $text
            Sha256 = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($bytes))
        }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Assert-NoDuplicateJsonProperties {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)][string] $Context
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            Require ($names.Add($property.Name)) `
                "$Context contains duplicate JSON property '$($property.Name)'."
            Assert-NoDuplicateJsonProperties $property.Value "$Context.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties $item "$Context[$index]"
            $index++
        }
    }
}

function ConvertFrom-StrictJsonText {
    param([string] $Text, [string] $Context)
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Text)
        Assert-NoDuplicateJsonProperties $document.RootElement $Context
        Require ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) `
            "$Context must contain one JSON object."
    } catch {
        if ($_.Exception.Message.StartsWith('[V71_RC6_2_PACK_MEMORY_AB]',
                [StringComparison]::Ordinal)) { throw }
        throw "[V71_RC6_2_PACK_MEMORY_AB] $Context is not strict JSON: $($_.Exception.Message)"
    } finally {
        if ($null -ne $document) { $document.Dispose() }
    }
    try {
        $value = $Text | ConvertFrom-Json -Depth 40
    } catch {
        throw "[V71_RC6_2_PACK_MEMORY_AB] $Context is not strict JSON: $($_.Exception.Message)"
    }
    Require ($value -is [pscustomobject]) "$Context must contain one JSON object."
    return $value
}

function Get-NormalizedTextSha256 {
    param([Parameter(Mandatory)][string] $Path)
    $locked = Enter-LockedUtf8File -Path $Path -Context 'normalized-text producer' `
        -MaximumBytes 4MB
    try {
        $normalized = $locked.Text.Replace("`r`n", "`n").Replace("`r", "`n")
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes($normalized)))
    } finally {
        $locked.Stream.Dispose()
    }
}

function Read-StrictJsonFile {
    param([string] $Path, [string] $Context)
    $locked = Enter-LockedUtf8File -Path $Path -Context $Context
    try {
        return ConvertFrom-StrictJsonText $locked.Text $Context
    } finally {
        $locked.Stream.Dispose()
    }
}

function Assert-HostContract {
    $build = Read-StrictJsonFile $script:BuildLockPath 'RC6.2 build lock'
    $producer = Read-StrictJsonFile $script:ProducerLockPath 'RC6.2 producer lock'
    Require (Test-ExactTrue (Get-RequiredProperty $build 'immutable' 'RC6.2 build lock')) `
        'The RC6.2 build lock is not immutable.'
    $target = Get-RequiredProperty $build 'target' 'RC6.2 build lock'
    $pair = Get-RequiredProperty $build 'pair' 'RC6.2 build lock'
    Require ([string](Get-RequiredProperty $target 'package' 'RC6.2 target') -ceq
            $script:Package -and
        [string](Get-RequiredProperty $target 'forbiddenStablePackage' 'RC6.2 target') -ceq
            $script:StablePackage -and
        [string](Get-RequiredProperty $target 'profile' 'RC6.2 target') -ceq
            $script:Profile -and
        [int](Get-RequiredProperty $target 'versionCode' 'RC6.2 target') -eq
            $script:VersionCode -and
        [string](Get-RequiredProperty $target 'versionName' 'RC6.2 target') -ceq
            $script:VersionName -and
        [string](Get-RequiredProperty $target 'apkSha256' 'RC6.2 target') -ceq
            $script:ApkSha256 -and
        [string](Get-RequiredProperty $target 'signerSha256' 'RC6.2 target') -ceq
            $script:SignerSha256) 'The exact RC6.2 target identity drifted.'
    $core = Get-RequiredProperty $pair 'core' 'RC6.2 pair'
    $veq = Get-RequiredProperty $pair 'veq' 'RC6.2 pair'
    Require ([string](Get-RequiredProperty $core 'fabricVersion' 'RC6.2 Core') -ceq
            $script:CoreVersion -and
        [string](Get-RequiredProperty $core 'sha256' 'RC6.2 Core') -ceq
            $script:CoreSha256 -and
        [string](Get-RequiredProperty $veq 'fabricVersion' 'RC6.2 VEQ') -ceq
            $script:VeqVersion -and
        [string](Get-RequiredProperty $veq 'sha256' 'RC6.2 VEQ') -ceq
            $script:VeqSha256) 'The exact RC6.2 Core/VEQ pair drifted.'
    Require ((Test-ExactTrue (Get-RequiredProperty $producer 'immutable' 'RC6.2 producer lock')) -and
        [string](Get-RequiredProperty $producer 'scriptHashScheme' 'RC6.2 producer lock') -ceq
            'sha256-utf8-normalized-lf') 'The RC6.2 producer-lock contract drifted.'
    $producers = Get-RequiredProperty $producer 'producers' 'RC6.2 producer lock'
    Require ([string](Get-RequiredProperty $producers 'memorySoakPath' 'RC6.2 producers') -ceq
            $script:SamplerRelativePath -and
        [string](Get-RequiredProperty $producers 'memorySoakScriptSha256' 'RC6.2 producers') -ceq
            $script:SamplerSha256) 'The immutable RC6.2 sampler pin drifted.'
    Require ((Get-NormalizedTextSha256 $script:SamplerPath) -ceq $script:SamplerSha256) `
        'The immutable RC6.2 sampler bytes drifted.'
    foreach ($name in @('Original', 'Probe512', 'HalfGe256', 'Cap128')) {
        $contract = $script:PackContracts[$name]
        $null = ConvertTo-CanonicalSha256 $contract.Sha256 "$name pack SHA-256"
    }
}

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][string] $Value)
    $quote = [string][char]39
    return $quote + $Value.Replace($quote,
        $quote + '"' + $quote + '"' + $quote) + $quote
}

function Assert-ReadOnlyShellCommand {
    param([Parameter(Mandatory)][string] $Command)
    Require (-not [string]::IsNullOrWhiteSpace($Command)) `
        'An empty device-read command was rejected.'
    $deny = '(?i)(?:^|[;|&\s])(?:am\s+(?:start|startservice|force-stop|kill)|' +
        'pm\s+(?:install|uninstall|clear|enable|disable)|cmd\s+package|' +
        'monkey|input|settings\s+put|setprop|rm|mv|cp|touch|mkdir|tee)(?:\s|$)|' +
        '(?:^|[;\s])>{1,2}(?:\s|$)|options\.txt'
    Require ($Command -notmatch $deny) `
        'A device command escaped the read-only allow boundary.'
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $sideQuest = Join-Path $env:LOCALAPPDATA `
        'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw '[V71_RC6_2_PACK_MEMORY_AB] ADB was not found; pass -AdbPath.'
}

function Invoke-AdbRead {
    param([string[]] $Arguments, [switch] $AllowFailure)
    $validDevices = $Arguments.Count -eq 1 -and $Arguments[0] -ceq 'devices'
    $validShell = $Arguments.Count -eq 4 -and $Arguments[0] -ceq '-s' -and
        $Arguments[1] -ceq $script:Device -and $Arguments[2] -ceq 'shell'
    Require ($validDevices -or $validShell) `
        'ADB arguments escaped the devices/read-only-shell boundary.'
    if ($validShell) { Assert-ReadOnlyShellCommand $Arguments[3] }
    $script:DeviceInvocations++
    $rows = @(& $script:Adb @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "[V71_RC6_2_PACK_MEMORY_AB] ADB read failed with exit code $exitCode; output suppressed."
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = $rows }
}

function Resolve-Device {
    Require $AllowDeviceRead.IsPresent `
        "$Action requires explicit -AllowDeviceRead."
    $script:Adb = Resolve-Adb
    $result = Invoke-AdbRead @('devices')
    $devices = @($result.Lines | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') {
            [string]$Matches.serial
        }
    })
    if ($Serial -ceq 'auto') {
        Require ($devices.Count -eq 1) `
            'Auto selection requires exactly one authorized ADB endpoint.'
        $script:Device = [string]$devices[0]
    } else {
        Require ($devices -ccontains $Serial) `
            'The requested ADB endpoint is not connected.'
        $script:Device = $Serial
    }
}

function Invoke-ReadShell {
    param([string] $Command, [switch] $Optional)
    Assert-ReadOnlyShellCommand $Command
    $normal = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $normal = Invoke-AdbRead @('-s', $script:Device, 'shell', $Command) -AllowFailure
        if ($normal.ExitCode -eq 0) { return $normal }
        if ($attempt -lt 3) { Start-Sleep -Milliseconds (250 * $attempt) }
    }
    if ($AllowRootRead) {
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $rootCommand = 'su -c ' + (ConvertTo-ShLiteral $Command)
            $root = Invoke-AdbRead @('-s', $script:Device, 'shell', $rootCommand) -AllowFailure
            if ($root.ExitCode -eq 0) { return $root }
            if ($attempt -lt 2) { Start-Sleep -Milliseconds 250 }
        }
    }
    if ($Optional) { return $normal }
    throw '[V71_RC6_2_PACK_MEMORY_AB] A required device read failed; output suppressed.'
}

function Read-ExactPidProbe {
    param([string[]] $Lines, [switch] $AllowMissing)
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'PID probe returned an ambiguous number of rows.'
    if ($rows[0] -ceq 'ABSENT') {
        if ($AllowMissing) { return $null }
        throw '[V71_RC6_2_PACK_MEMORY_AB] The required Lab process is absent.'
    }
    Require ($rows[0] -cmatch '^PID\t(?<pids>[0-9]+(?:\s+[0-9]+)*)$') `
        'PID probe response was malformed.'
    $pids = @(([string]$Matches.pids) -split '\s+')
    Require ($pids.Count -eq 1) 'PID probe found multiple processes.'
    return [int]$pids[0]
}

function Get-Pid {
    param([string] $PackageName, [switch] $AllowMissing)
    $qPackage = ConvertTo-ShLiteral $PackageName
    $command = "out=`$(pidof $qPackage); rc=`$?; " +
        'if [ "$rc" -eq 0 ]; then printf ''PID\t%s\n'' "$out"; ' +
        'elif [ "$rc" -eq 1 ]; then printf ''ABSENT\n''; else exit "$rc"; fi'
    $result = Invoke-ReadShell $command
    return Read-ExactPidProbe ([string[]]@($result.Lines)) -AllowMissing:$AllowMissing
}

function Read-PackageIdentity {
    param([string[]] $Lines)
    $codes = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionCode=(?<v>\d+)(?:\s|$)')
        if ($match.Success) { [int64]$match.Groups['v'].Value }
    })
    $names = @($Lines | ForEach-Object {
        $match = [regex]::Match([string]$_, '^\s*versionName=(?<v>\S+)\s*$')
        if ($match.Success) { [string]$match.Groups['v'].Value }
    })
    Require ($codes.Count -eq 1 -and $names.Count -eq 1) `
        'Installed Lab identity was missing or ambiguous.'
    Require ($codes[0] -eq $script:VersionCode -and
        $names[0] -ceq $script:VersionName) `
        'Installed Lab package version did not match exact RC6.2.'
    return [pscustomobject]@{ VersionCode = $codes[0]; VersionName = $names[0] }
}

function Read-ExactBaseApkPath {
    param([string[]] $Lines)
    $rows = @($Lines | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    Require ($rows.Count -eq 1) `
        'Installed Lab must expose exactly one base APK.'
    $match = [regex]::Match([string]$rows[0],
        '^package:(?<path>/data/app/[^\r\n]+/base\.apk)$')
    Require $match.Success 'Installed Lab base APK response was malformed.'
    $path = [string]$match.Groups['path'].Value
    Require (-not $path.Contains('..') -and -not $path.Contains('\') -and
        $path.Contains('/' + $script:Package)) `
        'Installed Lab base APK path was unsafe or belonged to another package.'
    return $path
}

function Read-Sha256Sum {
    param([string[]] $Lines, [string] $ExpectedPath)
    $rows = @($Lines | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    Require ($rows.Count -eq 1) 'A device hash returned an ambiguous number of rows.'
    $match = [regex]::Match([string]$rows[0],
        '^(?<sha>[0-9A-Fa-f]{64})\s+\*?(?<path>[^\r\n]+?)\s*$')
    Require ($match.Success -and
        [string]$match.Groups['path'].Value -ceq $ExpectedPath) `
        'A device hash response was malformed or named another file.'
    return ([string]$match.Groups['sha'].Value).ToUpperInvariant()
}

function Read-RemoteSha256 {
    param([string] $Path, [switch] $RequireRegularNoSymlink)
    $qPath = ConvertTo-ShLiteral $Path
    $command = if ($RequireRegularNoSymlink) {
        'p=' + $qPath + '; [ -f "$p" ] && [ ! -L "$p" ] || exit 61; ' +
            'sha256sum "$p"'
    } else {
        'sha256sum ' + $qPath
    }
    $result = Invoke-ReadShell $command
    return Read-Sha256Sum ([string[]]@($result.Lines)) $Path
}

function Read-ProcessStartTicks {
    param([string[]] $Lines)
    $rows = @($Lines | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'Process stat probe returned an ambiguous response.'
    $match = [regex]::Match($rows[0], '^\d+\s+\(.*\)\s+(?<rest>.+)$')
    Require $match.Success 'Process stat response was malformed.'
    $fields = @(([string]$match.Groups['rest'].Value) -split '\s+')
    Require ($fields.Count -ge 20 -and $fields[19] -cmatch '^\d+$') `
        'Process stat did not contain exact start ticks.'
    return [uint64]$fields[19]
}

function Read-ProcessTemporalAnchor {
    param([string[]] $Lines)
    $rows = @($Lines | ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 4) 'Process temporal-anchor probe was malformed.'
    $clock = [regex]::Match($rows[0], '^CLOCK_TICKS\t(?<v>\d+)$')
    $uptime = [regex]::Match($rows[1], '^UPTIME_SECONDS\t(?<v>\d+(?:\.\d+)?)$')
    $epoch = [regex]::Match($rows[2], '^EPOCH_SECONDS\t(?<v>\d+)$')
    $stat = [regex]::Match($rows[3], '^STAT\t(?<v>.+)$')
    Require ($clock.Success -and $uptime.Success -and $epoch.Success -and
        $stat.Success) 'Process temporal-anchor framing was malformed.'
    $clockTicks = [uint64]$clock.Groups['v'].Value
    $uptimeSeconds = [double]::Parse($uptime.Groups['v'].Value,
        [Globalization.CultureInfo]::InvariantCulture)
    $epochSeconds = [int64]$epoch.Groups['v'].Value
    $startTicks = Read-ProcessStartTicks @([string]$stat.Groups['v'].Value)
    Require ($clockTicks -gt 0 -and $uptimeSeconds -gt 0 -and
        $epochSeconds -gt 0 -and $startTicks -gt 0) `
        'Process temporal-anchor values were invalid.'
    $processStartEpoch = [double]$epochSeconds - $uptimeSeconds +
        ([double]$startTicks / [double]$clockTicks)
    Require ($processStartEpoch -gt 0 -and
        $processStartEpoch -le ([double]$epochSeconds + 2.0)) `
        'Process temporal anchor resolved outside the device clock.'
    return [pscustomobject][ordered]@{
        processStartTicks = $startTicks
        processStartEpochSeconds = [math]::Round($processStartEpoch, 3)
        deviceEpochSeconds = $epochSeconds
    }
}

function Get-ProcessTemporalAnchor {
    param([int] $ProcessId)
    Require ($ProcessId -gt 0) 'Process ID was invalid.'
    $command = 'p=' + $ProcessId + '; ' +
        'hz=$(getconf CLK_TCK) || exit 51; ' +
        'up=$(cat /proc/uptime) || exit 52; up=${up%% *}; ' +
        'now=$(date +%s) || exit 53; st=$(cat /proc/$p/stat) || exit 54; ' +
        'printf ''CLOCK_TICKS\t%s\nUPTIME_SECONDS\t%s\nEPOCH_SECONDS\t%s\nSTAT\t%s\n'' ' +
        '"$hz" "$up" "$now" "$st"'
    $result = Invoke-ReadShell $command
    return Read-ProcessTemporalAnchor ([string[]]@($result.Lines))
}

function Get-ExactRuntimeObservation {
    Require ($null -eq (Get-Pid $script:StablePackage -AllowMissing)) `
        'Stable is running; this harness will not stop it.'
    $pid = Get-Pid $script:Package
    $before = Get-ProcessTemporalAnchor $pid
    $packageResult = Invoke-ReadShell `
        ('dumpsys package ' + (ConvertTo-ShLiteral $script:Package))
    $identity = Read-PackageIdentity ([string[]]@($packageResult.Lines))
    $baseResult = Invoke-ReadShell `
        ('pm path ' + (ConvertTo-ShLiteral $script:Package))
    $basePath = Read-ExactBaseApkPath ([string[]]@($baseResult.Lines))
    $baseHash = Read-RemoteSha256 $basePath
    $coreHash = Read-RemoteSha256 $script:CorePath -RequireRegularNoSymlink
    $veqHash = Read-RemoteSha256 $script:VeqPath -RequireRegularNoSymlink
    $afterPid = Get-Pid $script:Package
    $after = Get-ProcessTemporalAnchor $afterPid
    Require ($afterPid -eq $pid -and
        [uint64]$after.processStartTicks -eq [uint64]$before.processStartTicks) `
        'The Lab process changed while exact RC6.2 identity was read.'
    Require ($baseHash -ceq $script:ApkSha256 -and
        $coreHash -ceq $script:CoreSha256 -and
        $veqHash -ceq $script:VeqSha256) `
        'The installed APK/Core/VEQ did not match exact RC6.2.'
    return [pscustomobject][ordered]@{
        pid = $pid
        processStartTicks = [uint64]$after.processStartTicks
        processStartEpochSeconds = [double]$after.processStartEpochSeconds
        identityMatched = $true
        apkSha256 = $baseHash
        coreSha256 = $coreHash
        veqSha256 = $veqHash
        versionCode = [int64]$identity.VersionCode
        versionName = [string]$identity.VersionName
    }
}

function Read-GameLogMetadata {
    param([string[]] $Lines)
    $rows = @($Lines | ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 2) 'latest.log metadata response was malformed.'
    $epoch = [regex]::Match($rows[0], '^DEVICE_EPOCH\t(?<v>\d+)$')
    $metadata = [regex]::Match($rows[1],
        '^GAME_LOG\t(?<size>\d+)_(?<mtime>\d+)_(?<ctime>\d+)_(?<inode>\d+)$')
    Require ($epoch.Success -and $metadata.Success) `
        'latest.log metadata framing was malformed.'
    $result = [pscustomobject][ordered]@{
        deviceEpochSeconds = [int64]$epoch.Groups['v'].Value
        sizeBytes = [int64]$metadata.Groups['size'].Value
        modifiedEpochSeconds = [int64]$metadata.Groups['mtime'].Value
        changedEpochSeconds = [int64]$metadata.Groups['ctime'].Value
        fileInode = [uint64]$metadata.Groups['inode'].Value
    }
    Require ($result.deviceEpochSeconds -gt 0 -and $result.sizeBytes -gt 0 -and
        $result.sizeBytes -le $script:MaximumGameLogBytes -and
        $result.modifiedEpochSeconds -gt 0 -and
        $result.changedEpochSeconds -gt 0 -and $result.fileInode -gt 0) `
        'latest.log metadata values were invalid or unbounded.'
    return $result
}

function Get-GameLogMetadata {
    $qLog = ConvertTo-ShLiteral $script:GameLogPath
    $command = 'p=' + $qLog + '; [ -f "$p" ] && [ ! -L "$p" ] || exit 44; ' +
        'now=$(date +%s) || exit 45; ' +
        'printf ''DEVICE_EPOCH\t%s\nGAME_LOG\t'' "$now"; ' +
        'stat -c ''%s_%Y_%Z_%i'' "$p"'
    $result = Invoke-ReadShell $command
    return Read-GameLogMetadata ([string[]]@($result.Lines))
}

function Assert-FreshGameLogMetadata {
    param(
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] $Process,
        [uint64] $ExpectedInode = 0,
        [int64] $MinimumSizeBytes = 0
    )
    Require ([double]$Process.processStartEpochSeconds -gt 0 -and
        [int64]$Metadata.modifiedEpochSeconds -ge
            [math]::Floor([double]$Process.processStartEpochSeconds - 2.0) -and
        [int64]$Metadata.changedEpochSeconds -ge
            [math]::Floor([double]$Process.processStartEpochSeconds - 2.0) -and
        [int64]$Metadata.modifiedEpochSeconds -le
            ([int64]$Metadata.deviceEpochSeconds + 2) -and
        [int64]$Metadata.modifiedEpochSeconds -ge
            ([int64]$Metadata.deviceEpochSeconds - $script:LogFreshnessSeconds)) `
        'The exact latest.log was stale or belonged to another process launch.'
    if ($ExpectedInode -gt 0) {
        Require ([uint64]$Metadata.fileInode -eq $ExpectedInode) `
            'The exact latest.log inode changed during the condition run.'
    }
    if ($MinimumSizeBytes -gt 0) {
        Require ([int64]$Metadata.sizeBytes -ge $MinimumSizeBytes) `
            'The exact latest.log was truncated during the condition run.'
    }
}

function Get-ResourceManagerConditionFromLine {
    param([string] $Line)
    $markers = [regex]::Matches($Line, 'Reloading ResourceManager:')
    Require ($markers.Count -eq 1) `
        'A filtered latest.log line had an ambiguous ResourceManager marker.'
    $exact = [regex]::Match($Line,
        '^\[[^\]\r\n]+\] \[Render thread/INFO\]: Reloading ResourceManager: (?<payload>[^\r\n]+)$')
    Require $exact.Success `
        'A ResourceManager record was not an exact Render-thread latest.log line.'
    $payload = [string]$exact.Groups['payload'].Value
    Require (-not [string]::IsNullOrWhiteSpace($payload)) `
        'A ResourceManager line had an empty pack list.'
    $tokens = @($payload.Split(',') | ForEach-Object { $_.Trim() })
    Require ($tokens.Count -ge 2 -and $tokens.Count -le 3 -and
        $tokens[0] -ceq 'vanilla' -and $tokens[1] -ceq 'fabric') `
        'ResourceManager base packs were missing, reordered, or ambiguous.'
    Require (@($tokens | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) `
        'A ResourceManager pack token was empty.'
    if ($tokens.Count -eq 2) { return 'Vanilla' }
    $fileToken = [string]$tokens[2]
    Require ($fileToken -cmatch '^file/[A-Za-z0-9._-]+\.zip$') `
        'The active file resource pack used unsupported or ambiguous syntax.'
    foreach ($entry in $script:PackContracts.GetEnumerator()) {
        if ($null -ne $entry.Value.FileToken -and
                $fileToken -ceq [string]$entry.Value.FileToken) {
            return [string]$entry.Key
        }
    }
    throw '[V71_RC6_2_PACK_MEMORY_AB] An unrecognized file resource pack was active.'
}

function Assert-ResourceManagerLinesForCondition {
    param(
        [string[]] $Lines,
        [string] $ExpectedCondition,
        [int] $StartIndex = 0
    )
    Require ($Lines.Count -gt 0) 'No ResourceManager state was available.'
    Require ($StartIndex -ge 0 -and $StartIndex -le $Lines.Count) `
        'ResourceManager start index was outside the bounded history.'
    $last = Get-ResourceManagerConditionFromLine $Lines[-1]
    Require ($last -ceq $ExpectedCondition) `
        'The latest ResourceManager state did not match the requested condition.'
    for ($index = $StartIndex; $index -lt $Lines.Count; $index++) {
        $observed = Get-ResourceManagerConditionFromLine $Lines[$index]
        Require ($observed -ceq $ExpectedCondition) `
            'A ResourceManager reload changed condition during the sampler interval.'
    }
    return [pscustomobject][ordered]@{
        condition = $last
        lineCount = $Lines.Count
        lastLineSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($Lines[-1])))
    }
}

function Get-BlocksAtlasObservationFromLine {
    param([Parameter(Mandatory)][string] $Line)
    $needle = 'minecraft:textures/atlas/blocks.png-atlas'
    Require ($Line.IndexOf($needle, [StringComparison]::Ordinal) -ge 0) `
        'A supplied blocks-atlas line did not name the exact blocks atlas.'
    $matches = [regex]::Matches($Line,
        '^\[[^\]\r\n]+\] \[Render thread/INFO\]: Created: ' +
        '(?<width>[1-9][0-9]*)x(?<height>[1-9][0-9]*)x(?<miplevel>[0-9]+) ' +
        'minecraft:textures/atlas/blocks\.png-atlas$')
    Require ($matches.Count -eq 1) `
        'The supplied blocks-atlas dimensions were missing or ambiguous.'
    $match = $matches[0]
    $width = [int64]$match.Groups['width'].Value
    $height = [int64]$match.Groups['height'].Value
    $miplevel = [int]$match.Groups['miplevel'].Value
    Require ($width -gt 0 -and $height -gt 0 -and $miplevel -ge 0 -and
        $miplevel -le 32) 'The supplied blocks-atlas dimensions were unsafe.'
    return [pscustomobject][ordered]@{
        width = $width
        height = $height
        miplevel = $miplevel
        lineSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($Line)))
        rawLinePersisted = $false
    }
}

function Read-FilteredLatestLogEvidence {
    param([Parameter(Mandatory)][string[]] $Lines)
    $rows = @($Lines | ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -ge 1) 'Filtered latest.log probe returned no framing.'
    $countMatch = [regex]::Match($rows[0], '^LOG_EVIDENCE_COUNT\t(?<v>\d+)$')
    Require $countMatch.Success 'Filtered latest.log count framing was malformed.'
    $count = [int]$countMatch.Groups['v'].Value
    Require ($count -gt 0 -and $count -le $script:MaximumFilteredLogLines) `
        'Filtered latest.log evidence was missing or exceeded the bounded reader.'
    $evidenceLines = @($rows | Select-Object -Skip 1 | ForEach-Object {
        $match = [regex]::Match($_, '^LOG_EVIDENCE_LINE\t(?<v>.*)$')
        Require $match.Success 'Filtered latest.log line framing was malformed.'
        [string]$match.Groups['v'].Value
    })
    Require ($evidenceLines.Count -eq $count) `
        'Filtered latest.log count and lines disagreed.'

    $resourceLines = [Collections.Generic.List[string]]::new()
    $resourceIndexes = [Collections.Generic.List[int]]::new()
    $atlasIndexes = [Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $evidenceLines.Count; $index++) {
        $line = $evidenceLines[$index]
        $resourceMarkerCount = [regex]::Matches(
            $line, 'Reloading ResourceManager:').Count
        $atlasMarkerCount = [regex]::Matches(
            $line, 'minecraft:textures/atlas/blocks\.png-atlas').Count
        Require (($resourceMarkerCount -eq 1 -and $atlasMarkerCount -eq 0) -or
            ($resourceMarkerCount -eq 0 -and $atlasMarkerCount -eq 1)) `
            'A filtered latest.log line was unsupported or combined two evidence types.'
        if ($resourceMarkerCount -eq 1) {
            $resourceLines.Add($line)
            $resourceIndexes.Add($index)
        } else {
            $null = Get-BlocksAtlasObservationFromLine $line
            $atlasIndexes.Add($index)
        }
    }
    Require ($resourceLines.Count -gt 0 -and
        $resourceLines.Count -le $script:MaximumResourceManagerLines) `
        'Fresh exact latest.log had no bounded ResourceManager history.'
    $lastResourceIndex = $resourceIndexes[-1]
    $currentAtlasIndexes = @($atlasIndexes | Where-Object { $_ -gt $lastResourceIndex })
    Require ($currentAtlasIndexes.Count -eq 1) `
        'The latest ResourceManager state did not have exactly one subsequent blocks-atlas creation line.'
    $atlas = Get-BlocksAtlasObservationFromLine `
        $evidenceLines[[int]$currentAtlasIndexes[0]]
    return [pscustomobject][ordered]@{
        resourceManagerLines = $resourceLines.ToArray()
        resourceManagerLineCount = $resourceLines.Count
        blocksAtlas = $atlas
        filteredLineCount = $evidenceLines.Count
        rawLinesPersisted = $false
    }
}

function Get-FilteredLatestLogEvidence {
    $qLog = ConvertTo-ShLiteral $script:GameLogPath
    $pattern = 'Reloading ResourceManager:|minecraft:textures/atlas/blocks\.png-atlas'
    $qPattern = ConvertTo-ShLiteral $pattern
    $command = 'p=' + $qLog + '; n=' + $qPattern + '; ' +
        '[ -f "$p" ] && [ ! -L "$p" ] || exit 44; ' +
        'count=$(LC_ALL=C grep -E -c "$n" "$p"); rc=$?; ' +
        '[ "$rc" -le 1 ] || exit "$rc"; ' +
        'printf ''LOG_EVIDENCE_COUNT\t%s\n'' "$count"; ' +
        'LC_ALL=C grep -E "$n" "$p" | while IFS= read -r line; do ' +
        'printf ''LOG_EVIDENCE_LINE\t%s\n'' "$line"; done'
    $result = Invoke-ReadShell $command
    return Read-FilteredLatestLogEvidence ([string[]]@($result.Lines))
}

function Get-PhysicalPackObservation {
    param([string] $ExpectedCondition)
    $contract = $script:PackContracts[$ExpectedCondition]
    Require ($null -ne $contract) 'Unknown pack condition.'
    if ($ExpectedCondition -ceq 'Vanilla') {
        return [pscustomobject][ordered]@{
            required = $false
            expectedSha256 = $null
            observedSha256 = $null
            matched = $true
        }
    }
    $path = "$($script:PackDirectory)/$($contract.FileName)"
    $observed = Read-RemoteSha256 $path -RequireRegularNoSymlink
    Require ($observed -ceq [string]$contract.Sha256) `
        'The physical active resource pack did not match its exact SHA-256.'
    return [pscustomobject][ordered]@{
        required = $true
        expectedSha256 = [string]$contract.Sha256
        observedSha256 = $observed
        matched = $true
    }
}

function Get-ConditionFence {
    param(
        [string] $ExpectedCondition,
        [uint64] $ExpectedLogInode = 0,
        [int64] $MinimumLogSizeBytes = 0,
        [int] $ResourceManagerStartIndex = 0
    )
    $runtime = Get-ExactRuntimeObservation
    $beforeMetadata = Get-GameLogMetadata
    Assert-FreshGameLogMetadata $beforeMetadata $runtime $ExpectedLogInode `
        $MinimumLogSizeBytes
    $logEvidence = Get-FilteredLatestLogEvidence
    $afterMetadata = Get-GameLogMetadata
    Assert-FreshGameLogMetadata $afterMetadata $runtime $ExpectedLogInode `
        $MinimumLogSizeBytes
    Require ([uint64]$afterMetadata.fileInode -eq [uint64]$beforeMetadata.fileInode -and
        [int64]$afterMetadata.sizeBytes -ge [int64]$beforeMetadata.sizeBytes) `
        'latest.log was replaced or truncated while ResourceManager state was read.'
    $resource = Assert-ResourceManagerLinesForCondition `
        ([string[]]$logEvidence.resourceManagerLines) `
        $ExpectedCondition $ResourceManagerStartIndex
    $physical = Get-PhysicalPackObservation $ExpectedCondition
    $afterPid = Get-Pid $script:Package
    $afterAnchor = Get-ProcessTemporalAnchor $afterPid
    Require ($afterPid -eq [int]$runtime.pid -and
        [uint64]$afterAnchor.processStartTicks -eq
            [uint64]$runtime.processStartTicks) `
        'The Lab process changed while the condition fence was read.'
    return [pscustomobject][ordered]@{
        observedUtc = [DateTime]::UtcNow.ToString('o')
        runtime = $runtime
        latestLog = [pscustomobject][ordered]@{
            fileInode = [uint64]$afterMetadata.fileInode
            sizeBytes = [int64]$afterMetadata.sizeBytes
            modifiedEpochSeconds = [int64]$afterMetadata.modifiedEpochSeconds
            observedDeviceEpochSeconds = [int64]$afterMetadata.deviceEpochSeconds
            fresh = $true
            resourceManagerLineCount = [int]$resource.lineCount
            resourceManagerLastLineSha256 = [string]$resource.lastLineSha256
            filteredEvidenceLineCount = [int]$logEvidence.filteredLineCount
            blocksAtlas = $logEvidence.blocksAtlas
            rawLinesPersisted = $false
        }
        condition = [pscustomobject][ordered]@{
            name = $ExpectedCondition
            activeFileToken = $script:PackContracts[$ExpectedCondition].FileToken
            expectedPackSha256 = $script:PackContracts[$ExpectedCondition].Sha256
            physicalPackRequired = [bool]$physical.required
            physicalPackSha256 = $physical.observedSha256
            physicalPackMatched = [bool]$physical.matched
        }
    }
}

function Get-EvidenceRoot {
    return Get-CanonicalPath (Join-Path $script:RepoRoot $script:EvidenceRootRelative)
}

function Resolve-EvidencePath {
    param(
        [string] $Path,
        [string] $Context,
        [switch] $MustExist,
        [switch] $AllowDirectory
    )
    Require (-not [string]::IsNullOrWhiteSpace($Path)) "$Context path is required."
    $full = if ([IO.Path]::IsPathRooted($Path)) {
        Get-CanonicalPath $Path
    } else {
        Get-CanonicalPath (Join-Path $script:RepoRoot $Path)
    }
    $root = Get-EvidenceRoot
    $null = Assert-PathContained -Path $full -Root $root -AllowRoot:$AllowDirectory
    if ($MustExist) {
        $pathType = if ($AllowDirectory) { 'Container' } else { 'Leaf' }
        Require (Test-Path -LiteralPath $full -PathType $pathType) "$Context is missing."
        Assert-NoReparsePoint -Path $full -Root $script:RepoRoot
    }
    return $full
}

function Assert-RepoEvidenceReference {
    param($Value, [string] $ExpectedLeafName, [string] $Context)
    Require ($Value -is [string]) "$Context must be a string."
    $path = [string]$Value
    Require ($path.StartsWith('artifacts/memory/', [StringComparison]::Ordinal) -and
        -not [IO.Path]::IsPathRooted($path) -and $path.IndexOf('\') -lt 0 -and
        [IO.Path]::GetFileName($path) -ceq $ExpectedLeafName) `
        "$Context was not an artifacts/memory reference to $ExpectedLeafName."
    $segments = @($path.Split('/'))
    Require ($segments.Count -ge 4 -and
        @($segments | Where-Object {
                [string]::IsNullOrWhiteSpace($_) -or $_ -ceq '.' -or $_ -ceq '..'
            }).Count -eq 0) "$Context had an unsafe path segment."
    return $path
}

function Write-NewJsonFile {
    param([string] $Path, $Value, [string] $Context)
    Require (-not (Test-Path -LiteralPath $Path)) "$Context already exists; refusing overwrite."
    $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($bytes))
}

function New-CandidateReceiptObject {
    return [pscustomobject][ordered]@{
        package = $script:Package
        forbiddenStablePackage = $script:StablePackage
        profile = $script:Profile
        versionCode = $script:VersionCode
        versionName = $script:VersionName
        apkSha256 = $script:ApkSha256
        coreVersion = $script:CoreVersion
        coreSha256 = $script:CoreSha256
        veqVersion = $script:VeqVersion
        veqSha256 = $script:VeqSha256
        signerSha256 = $script:SignerSha256
    }
}

function Assert-CandidateReceiptObject {
    param($Candidate, [string] $Context)
    $expected = New-CandidateReceiptObject
    foreach ($property in $expected.PSObject.Properties) {
        $actual = Get-RequiredProperty $Candidate $property.Name $Context
        if ($property.Value -is [string]) {
            Require ($actual -is [string] -and
                [string]$actual -ceq [string]$property.Value) `
                "$Context.$($property.Name) drifted."
        } else {
            Require ([int64]$actual -eq [int64]$property.Value) `
                "$Context.$($property.Name) drifted."
        }
    }
}

function ConvertTo-RoundtripDateTimeOffset {
    param($Value, [string] $Context)
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) {
        $date = [DateTime]$Value
        Require ($date.Kind -ne [DateTimeKind]::Unspecified) `
            "$Context has no time-zone designator."
        return [DateTimeOffset]$date
    }
    Require ($Value -is [string]) "$Context is not a timestamp string."
    $parsed = [DateTimeOffset]::MinValue
    Require ([DateTimeOffset]::TryParseExact([string]$Value, 'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) `
        "$Context is not an ISO-8601 round-trip timestamp."
    return $parsed
}

function Assert-BlocksAtlasReceiptObject {
    param($Atlas, [string] $Context)
    $width = [int64](Get-RequiredProperty $Atlas 'width' $Context)
    $height = [int64](Get-RequiredProperty $Atlas 'height' $Context)
    $miplevel = [int](Get-RequiredProperty $Atlas 'miplevel' $Context)
    Require ($width -gt 0 -and $height -gt 0 -and $miplevel -ge 0 -and
        $miplevel -le 32) "$Context dimensions/miplevel were invalid."
    $null = ConvertTo-CanonicalSha256 `
        (Get-RequiredProperty $Atlas 'lineSha256' $Context) "$Context lineSha256"
    Require (Test-ExactFalse (Get-RequiredProperty $Atlas 'rawLinePersisted' $Context)) `
        "$Context persisted a raw latest.log line."
    return [pscustomobject][ordered]@{
        width = $width
        height = $height
        miplevel = $miplevel
    }
}

function Assert-StartReceipt {
    param($Receipt, [string] $ExpectedCondition)
    Require ([int](Get-RequiredProperty $Receipt 'schemaVersion' 'start receipt') -eq 1 -and
        [string](Get-RequiredProperty $Receipt 'receiptType' 'start receipt') -ceq
            'V71_RC6_2_RESOURCE_PACK_MEMORY_CONDITION_START' -and
        [string](Get-RequiredProperty $Receipt 'status' 'start receipt') -ceq
            'CONDITION_AUTHENTICATED') 'The condition start receipt type/status was invalid.'
    Assert-CandidateReceiptObject `
        (Get-RequiredProperty $Receipt 'candidate' 'start receipt') 'start receipt candidate'
    $sampler = Get-RequiredProperty $Receipt 'sampler' 'start receipt'
    Require ([string](Get-RequiredProperty $sampler 'path' 'start receipt sampler') -ceq
            $script:SamplerRelativePath -and
        [string](Get-RequiredProperty $sampler 'normalizedLfSha256' 'start receipt sampler') -ceq
            $script:SamplerSha256 -and
        [string](Get-RequiredProperty $sampler 'executionModel' 'start receipt sampler') -ceq
            'SEPARATE_SUPERVISED_IMMUTABLE_SAMPLER' -and
        [int](Get-RequiredProperty $sampler 'minimumConditionMinutes' 'start receipt sampler') -eq 30) `
        'The start receipt did not bind the immutable sampler.'
    $conditionObject = Get-RequiredProperty $Receipt 'condition' 'start receipt'
    $contract = $script:PackContracts[$ExpectedCondition]
    Require ([string](Get-RequiredProperty $conditionObject 'name' 'start receipt condition') -ceq
            $ExpectedCondition -and
        [string](Get-RequiredProperty $conditionObject 'activeFileToken' 'start receipt condition') -ceq
            [string]$contract.FileToken -and
        [string](Get-RequiredProperty $conditionObject 'expectedPackSha256' 'start receipt condition') -ceq
            [string]$contract.Sha256 -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'physicalPackMatched' 'start receipt condition'))) `
        'The start receipt condition binding drifted.'
    $physicalRequired = Get-RequiredProperty $conditionObject 'physicalPackRequired' `
        'start receipt condition'
    $physicalSha = Get-RequiredProperty $conditionObject 'physicalPackSha256' `
        'start receipt condition'
    if ($ExpectedCondition -ceq 'Vanilla') {
        Require ((Test-ExactFalse $physicalRequired) -and $null -eq $physicalSha) `
            'Vanilla start receipt claimed a physical active pack.'
    } else {
        Require ((Test-ExactTrue $physicalRequired) -and $physicalSha -is [string] -and
            [string]$physicalSha -ceq [string]$contract.Sha256) `
            'Non-vanilla start receipt did not bind the physical pack bytes.'
    }
    $process = Get-RequiredProperty $Receipt 'process' 'start receipt'
    Require ([int](Get-RequiredProperty $process 'pid' 'start receipt process') -gt 0 -and
        [uint64](Get-RequiredProperty $process 'processStartTicks' 'start receipt process') -gt 0 -and
        [double](Get-RequiredProperty $process 'processStartEpochSeconds' 'start receipt process') -gt 0) `
        'The start receipt process binding was invalid.'
    $log = Get-RequiredProperty $Receipt 'latestLog' 'start receipt'
    Require ([uint64](Get-RequiredProperty $log 'fileInode' 'start receipt latestLog') -gt 0 -and
        [int64](Get-RequiredProperty $log 'sizeBytes' 'start receipt latestLog') -gt 0 -and
        [int](Get-RequiredProperty $log 'resourceManagerLineCount' 'start receipt latestLog') -gt 0 -and
        (Test-ExactTrue (Get-RequiredProperty $log 'fresh' 'start receipt latestLog')) -and
        (Test-ExactFalse (Get-RequiredProperty $log 'rawLinesPersisted' 'start receipt latestLog'))) `
        'The start receipt latest.log binding was invalid.'
    Require ([int](Get-RequiredProperty $log 'filteredEvidenceLineCount' 'start receipt latestLog') -ge
            ([int]$log.resourceManagerLineCount + 1)) `
        'The start receipt omitted its filtered blocks-atlas evidence.'
    $null = ConvertTo-CanonicalSha256 `
        (Get-RequiredProperty $log 'resourceManagerLastLineSha256' 'start receipt latestLog') `
        'start receipt ResourceManager line hash'
    $null = Assert-BlocksAtlasReceiptObject `
        (Get-RequiredProperty $log 'blocksAtlas' 'start receipt latestLog') `
        'start receipt blocks atlas'
    $null = ConvertTo-RoundtripDateTimeOffset `
        (Get-RequiredProperty $Receipt 'observedUtc' 'start receipt') 'start receipt observedUtc'
    $boundary = Get-RequiredProperty $Receipt 'evidenceBoundary' 'start receipt'
    Require ((Test-ExactTrue (Get-RequiredProperty $boundary 'deviceReadOnly' 'start receipt boundary')) -and
        (Test-ExactFalse (Get-RequiredProperty $boundary 'samplerInvokedByWrapper' 'start receipt boundary'))) `
        'The start receipt escaped its read-only/separate-sampler boundary.'
    foreach ($field in @('profileOrOptionsEdited', 'appLaunchedOrStopped',
            'packageMutationUsed', 'rawLatestLogPersisted',
            'accountWorldOrServerDataPersisted', 'deviceSerialPersisted')) {
        Require (Test-ExactFalse (Get-RequiredProperty $boundary $field 'start receipt boundary')) `
            "The start receipt claimed forbidden behavior: $field."
    }
}

function Assert-ProvenanceFlags {
    param($Provenance, [string] $Context)
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        Require (Test-ExactTrue (Get-RequiredProperty $Provenance $field $Context)) `
            "$Context failed $field."
    }
}

function Assert-SamplerContent {
    param(
        [Parameter(Mandatory)] $Summary,
        [Parameter(Mandatory)][object[]] $Samples
    )
    Require ([int](Get-RequiredProperty $Summary 'schemaVersion' 'sampler summary') -eq 3 -and
        [string](Get-RequiredProperty $Summary 'package' 'sampler summary') -ceq
            $script:Package -and
        [string](Get-RequiredProperty $Summary 'producerSha256' 'sampler summary') -ceq
            $script:SamplerSha256) 'Sampler summary identity or producer drifted.'
    Assert-ProvenanceFlags `
        (Get-RequiredProperty $Summary 'provenance' 'sampler summary') 'sampler start provenance'
    Assert-ProvenanceFlags `
        (Get-RequiredProperty $Summary 'finalProvenance' 'sampler summary') 'sampler final provenance'
    $duration = [double](Get-RequiredProperty $Summary 'requestedDurationMinutes' 'sampler summary')
    $interval = [int](Get-RequiredProperty $Summary 'intervalSeconds' 'sampler summary')
    $declaredSamples = [int](Get-RequiredProperty $Summary 'samples' 'sampler summary')
    Require ($duration -ge 30.0 -and $duration -le 180.0) `
        'Each resource-pack condition requires at least thirty sampler minutes.'
    Require ($interval -ge 60 -and $interval -le 900) `
        'Sampler interval was outside the immutable producer range.'
    $minimum = [math]::Max(2,
        [int][math]::Ceiling(($duration * 60.0) / $interval) + 1)
    Require ($Samples.Count -eq $declaredSamples -and $Samples.Count -ge $minimum -and
        [int](Get-RequiredProperty $Summary 'minimumExpectedSamples' 'sampler summary') -eq
            $minimum -and
        [int](Get-RequiredProperty $Summary 'completeMetricSamples' 'sampler summary') -eq
            $Samples.Count) 'Sampler sample count/window was incomplete.'
    foreach ($field in @('pidStable', 'focusStayedOnLab', 'gameJvmStayedAlive',
            'expectedGameLogStayedFresh')) {
        Require (Test-ExactTrue (Get-RequiredProperty $Summary $field 'sampler summary')) `
            "Sampler summary failed $field."
    }
    $initialPid = [int](Get-RequiredProperty $Summary 'initialPid' 'sampler summary')
    $previousElapsed = -1.0
    $previousTimestamp = [DateTimeOffset]::MinValue
    $firstTimestamp = $null
    $requiredMetricNames = @('totalPssKib', 'totalRssKib', 'javaHeapKib',
        'nativeHeapKib', 'graphicsKib', 'vmRssKib', 'vmSwapKib',
        'memAvailableKib', 'swapFreeKib', 'batteryTemperatureC',
        'batteryStatusCode', 'thermalStatusCode')
    foreach ($sample in $Samples) {
        $elapsed = [double](Get-RequiredProperty $sample 'elapsedMinutes' 'sampler sample')
        $timestamp = ConvertTo-RoundtripDateTimeOffset `
            (Get-RequiredProperty $sample 'timestampUtc' 'sampler sample') `
            'sampler sample timestampUtc'
        Require ($elapsed -gt $previousElapsed -and $timestamp -gt $previousTimestamp) `
            'Sampler sample time was not strictly increasing.'
        if ($null -eq $firstTimestamp) { $firstTimestamp = $timestamp }
        $previousElapsed = $elapsed
        $previousTimestamp = $timestamp
        Require ([int](Get-RequiredProperty $sample 'pid' 'sampler sample') -eq $initialPid -and
            (Test-ExactTrue (Get-RequiredProperty $sample 'pidStable' 'sampler sample')) -and
            [string](Get-RequiredProperty $sample 'focus' 'sampler sample') -ceq 'focused' -and
            (Test-ExactTrue (Get-RequiredProperty $sample 'gameJvmAlive' 'sampler sample'))) `
            'A sampler row lost exact PID, focus, or the game JVM.'
        foreach ($field in @('expectedGameLogPathMatched',
                'expectedGameLogRegularAndNonEmpty', 'expectedGameLogSameFile',
                'expectedGameLogTemporallyBoundToProcess', 'expectedGameLogFresh')) {
            Require (Test-ExactTrue (Get-RequiredProperty $sample $field 'sampler sample')) `
                "A sampler row failed $field."
        }
        foreach ($metric in $requiredMetricNames) {
            $value = Get-RequiredProperty $sample $metric 'sampler sample'
            Require ($null -ne $value) "A sampler row omitted $metric."
        }
        Require ((Test-ExactFalse (Get-RequiredProperty $sample 'thermalLimitExceeded' 'sampler sample')) -and
            (Test-ExactFalse (Get-RequiredProperty $sample 'thermalSafetyStopPerformed' 'sampler sample'))) `
            'A sampler row crossed a thermal limit or stopped the Lab app.'
    }
    Require ($Samples[-1].elapsedMinutes -ge $duration) `
        'The final sampler row did not reach the requested duration.'
    $firstElapsed = [double]$Samples[0].elapsedMinutes
    $elapsedSpan = [double]$Samples[-1].elapsedMinutes - $firstElapsed
    $timestampSpan = ($previousTimestamp - $firstTimestamp).TotalMinutes
    Require ($firstElapsed -ge 0 -and $firstElapsed -le 1.0 -and
        $timestampSpan -ge ($duration - $firstElapsed - 0.25) -and
        [math]::Abs($timestampSpan - $elapsedSpan) -le 0.25) `
        'Sampler timestamps and monotonic elapsed time did not prove the requested window.'
    $thermal = Get-RequiredProperty $Summary 'thermalSafety' 'sampler summary'
    Require ((Test-ExactFalse (Get-RequiredProperty $thermal 'limitExceeded' 'sampler thermal')) -and
        (Test-ExactFalse (Get-RequiredProperty $thermal 'labSafetyStopPerformed' 'sampler thermal')) -and
        [int](Get-RequiredProperty $thermal 'safetyStopInvocations' 'sampler thermal') -eq 0 -and
        (Test-ExactFalse (Get-RequiredProperty $thermal 'stablePackageStopped' 'sampler thermal'))) `
        'Sampler thermal/safety-stop boundary was not mutation-free.'
    $acceptance = Get-RequiredProperty $Summary 'acceptance' 'sampler summary'
    foreach ($field in @('completedDuration', 'sampleCountComplete',
            'allRequiredMetricsPresent', 'focusStayedOnLab', 'gameJvmStayedAlive',
            'expectedGameLogStayedFresh', 'thermalLimitNeverExceeded',
            'thermalSafetyStopNotRequired', 'postWarmSamplesComplete',
            'lastThirtySamplesComplete')) {
        Require (Test-ExactTrue (Get-RequiredProperty $acceptance $field 'sampler acceptance')) `
            "Sampler acceptance failed $field."
    }
    $binding = Get-RequiredProperty $Summary 'runtimeBinding' 'sampler summary'
    Require ([string](Get-RequiredProperty $binding 'receiptType' 'sampler binding') -ceq
            'V71_RC6_2_MEMORY_SOAK_RUNTIME_BINDING' -and
        [string](Get-RequiredProperty $binding 'result' 'sampler binding') -ceq 'PASS') `
        'Sampler runtime binding was not exact RC6.2 PASS.'
    $start = Get-RequiredProperty $binding 'start' 'sampler binding'
    $final = Get-RequiredProperty $binding 'final' 'sampler binding'
    Require ([int](Get-RequiredProperty $start 'pid' 'sampler start binding') -eq $initialPid -and
        [int](Get-RequiredProperty $final 'pid' 'sampler final binding') -eq $initialPid -and
        [uint64](Get-RequiredProperty $start 'processStartTicks' 'sampler start binding') -gt 0 -and
        [uint64](Get-RequiredProperty $final 'processStartTicks' 'sampler final binding') -eq
            [uint64]$start.processStartTicks -and
        [string](Get-RequiredProperty $start 'producerSha256' 'sampler start binding') -ceq
            $script:SamplerSha256 -and
        (Test-ExactTrue (Get-RequiredProperty $final 'sameProcessIncarnation' 'sampler final binding'))) `
        'Sampler start/final process binding was inconsistent.'
    $boundary = Get-RequiredProperty $binding 'evidenceBoundary' 'sampler binding'
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted',
            'deviceSerialPersisted', 'accountDataPersisted', 'hostAbsolutePathsPersisted')) {
        Require (Test-ExactFalse (Get-RequiredProperty $boundary $field 'sampler boundary')) `
            "Sampler boundary persisted forbidden evidence: $field."
    }
    $maxPss = ($Samples | Measure-Object totalPssKib -Maximum).Maximum / 1024.0
    $maxRss = ($Samples | Measure-Object vmRssKib -Maximum).Maximum / 1024.0
    $maxGraphics = ($Samples | Measure-Object graphicsKib -Maximum).Maximum / 1024.0
    $firstPss = [double]$Samples[0].totalPssKib / 1024.0
    $finalPss = [double]$Samples[-1].totalPssKib / 1024.0
    Require ([math]::Abs([double]$Summary.maxPssMib - $maxPss) -le 0.001 -and
        [math]::Abs([double]$Summary.maxRssMib - $maxRss) -le 0.001) `
        'Sampler PSS/RSS aggregates did not match raw samples.'
    return [pscustomobject][ordered]@{
        requestedDurationMinutes = $duration
        observedDurationMinutes = [double]$Samples[-1].elapsedMinutes
        sampleCount = $Samples.Count
        intervalSeconds = $interval
        pid = $initialPid
        processStartTicks = [uint64]$start.processStartTicks
        processStartEpochSeconds = [double]$start.processStartEpochSeconds
        startedUtc = (ConvertTo-RoundtripDateTimeOffset $Summary.startedUtc `
            'sampler startedUtc').ToString('o')
        finalObservedUtc = (ConvertTo-RoundtripDateTimeOffset $final.observedUtc `
            'sampler final observedUtc').ToString('o')
        maxPssMib = [math]::Round($maxPss, 3)
        maxRssMib = [math]::Round($maxRss, 3)
        maxGraphicsMib = [math]::Round($maxGraphics, 3)
        firstPssMib = [math]::Round($firstPss, 3)
        finalPssMib = [math]::Round($finalPss, 3)
        pssChangeMib = [math]::Round($finalPss - $firstPss, 3)
        postWarmPssSlopeMibPerMinute = [double]$Summary.postWarmPssSlopeMibPerMinute
        lastThirtyMinutesGrowthMib = [double]$Summary.lastThirtyMinutesGrowthMib
        formalSamplerResult = if (Test-ExactTrue $acceptance.passed) { 'PASS' } else { 'FAIL' }
    }
}

function Read-SamplerOutputs {
    param([string] $SummaryPath, [string] $SamplesPath)
    $summaryFull = Resolve-EvidencePath $SummaryPath 'sampler summary' -MustExist
    $samplesFull = Resolve-EvidencePath $SamplesPath 'sampler samples' -MustExist
    Require ([IO.Path]::GetFileName($summaryFull) -ceq 'summary.json' -and
        [IO.Path]::GetFileName($samplesFull) -ceq 'samples.jsonl' -and
        [IO.Path]::GetDirectoryName($summaryFull) -ceq
            [IO.Path]::GetDirectoryName($samplesFull)) `
        'Sampler outputs must be the exact summary.json/samples.jsonl pair.'
    $summaryLock = $null
    $samplesLock = $null
    try {
        $summaryLock = Enter-LockedUtf8File $summaryFull 'sampler summary' 4MB
        $samplesLock = Enter-LockedUtf8File $samplesFull 'sampler samples' 16MB
        $summary = ConvertFrom-StrictJsonText $summaryLock.Text 'sampler summary'
        $sampleRows = @($samplesLock.Text -split '\r?\n' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
        $samples = @($sampleRows | ForEach-Object {
            ConvertFrom-StrictJsonText $_ 'sampler sample row'
        })
        $validated = Assert-SamplerContent $summary $samples
        return [pscustomobject][ordered]@{
            summaryPath = ConvertTo-RepoRelativePath $summaryFull
            summarySha256 = [string]$summaryLock.Sha256
            samplesPath = ConvertTo-RepoRelativePath $samplesFull
            samplesSha256 = [string]$samplesLock.Sha256
            validation = $validated
        }
    } finally {
        if ($null -ne $samplesLock) { $samplesLock.Stream.Dispose() }
        if ($null -ne $summaryLock) { $summaryLock.Stream.Dispose() }
    }
}

function Assert-ConditionRunBinding {
    param($StartReceipt, $Sampler, $EndFence, [string] $ExpectedCondition)
    Assert-StartReceipt $StartReceipt $ExpectedCondition
    $startProcess = $StartReceipt.process
    $samplerValidation = $Sampler.validation
    Require ([int]$startProcess.pid -eq [int]$samplerValidation.pid -and
        [uint64]$startProcess.processStartTicks -eq
            [uint64]$samplerValidation.processStartTicks -and
        [int]$EndFence.runtime.pid -eq [int]$samplerValidation.pid -and
        [uint64]$EndFence.runtime.processStartTicks -eq
            [uint64]$samplerValidation.processStartTicks) `
        'Begin, sampler, and Finalize did not bind the same process incarnation.'
    Require ([math]::Abs([double]$startProcess.processStartEpochSeconds -
            [double]$samplerValidation.processStartEpochSeconds) -le 2.0) `
        'Begin and sampler process epoch anchors disagreed.'
    Require ([uint64]$StartReceipt.latestLog.fileInode -eq
            [uint64]$EndFence.latestLog.fileInode -and
        [int64]$EndFence.latestLog.sizeBytes -ge
            [int64]$StartReceipt.latestLog.sizeBytes) `
        'Begin and Finalize did not bind the same append-only latest.log.'
    Require ([string]$StartReceipt.condition.name -ceq $ExpectedCondition -and
        [string]$EndFence.condition.name -ceq $ExpectedCondition -and
        [string]$StartReceipt.condition.physicalPackSha256 -ceq
            [string]$EndFence.condition.physicalPackSha256) `
        'The resource-pack condition or physical bytes changed across the run.'
    $startAtlas = Assert-BlocksAtlasReceiptObject `
        $StartReceipt.latestLog.blocksAtlas 'start receipt blocks atlas'
    $endAtlas = Assert-BlocksAtlasReceiptObject `
        $EndFence.latestLog.blocksAtlas 'final fence blocks atlas'
    Require ($startAtlas.width -eq $endAtlas.width -and
        $startAtlas.height -eq $endAtlas.height -and
        $startAtlas.miplevel -eq $endAtlas.miplevel) `
        'The parsed blocks-atlas dimensions or miplevel changed across the condition run.'
    $beginUtc = ConvertTo-RoundtripDateTimeOffset $StartReceipt.observedUtc `
        'start receipt observedUtc'
    $samplerStartUtc = ConvertTo-RoundtripDateTimeOffset `
        $samplerValidation.startedUtc 'sampler startedUtc'
    $samplerFinalUtc = ConvertTo-RoundtripDateTimeOffset `
        $samplerValidation.finalObservedUtc 'sampler final observedUtc'
    $endUtc = ConvertTo-RoundtripDateTimeOffset $EndFence.observedUtc `
        'Finalize fence observedUtc'
    Require ($beginUtc -le $samplerStartUtc -and
        $samplerStartUtc -lt $samplerFinalUtc -and $samplerFinalUtc -le $endUtc -and
        ($endUtc - $beginUtc).TotalMinutes -ge
            [double]$samplerValidation.requestedDurationMinutes) `
        'Begin/sampler/Finalize timestamps did not enclose the condition interval.'
}

function New-StartReceipt {
    param([string] $ExpectedCondition, $Fence)
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_RESOURCE_PACK_MEMORY_CONDITION_START'
        status = 'CONDITION_AUTHENTICATED'
        observedUtc = [string]$Fence.observedUtc
        candidate = New-CandidateReceiptObject
        sampler = [pscustomobject][ordered]@{
            path = $script:SamplerRelativePath
            normalizedLfSha256 = $script:SamplerSha256
            executionModel = 'SEPARATE_SUPERVISED_IMMUTABLE_SAMPLER'
            minimumConditionMinutes = 30
        }
        condition = $Fence.condition
        process = [pscustomobject][ordered]@{
            pid = [int]$Fence.runtime.pid
            processStartTicks = [uint64]$Fence.runtime.processStartTicks
            processStartEpochSeconds = [double]$Fence.runtime.processStartEpochSeconds
        }
        latestLog = $Fence.latestLog
        evidenceBoundary = [pscustomobject][ordered]@{
            deviceReadOnly = $true
            samplerInvokedByWrapper = $false
            profileOrOptionsEdited = $false
            appLaunchedOrStopped = $false
            packageMutationUsed = $false
            rawLatestLogPersisted = $false
            accountWorldOrServerDataPersisted = $false
            deviceSerialPersisted = $false
        }
    }
}

function New-ConditionReceiptObject {
    param(
        [string] $ExpectedCondition,
        $StartReceipt,
        [string] $StartReceiptPath,
        [string] $StartReceiptSha256,
        $Sampler,
        $EndFence,
        [string] $CreatedUtc = ''
    )
    if ([string]::IsNullOrEmpty($CreatedUtc)) {
        $CreatedUtc = [DateTime]::UtcNow.ToString('o')
    } else {
        $null = ConvertTo-RoundtripDateTimeOffset $CreatedUtc 'condition receipt createdUtc'
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_RESOURCE_PACK_MEMORY_CONDITION'
        result = 'PASS_CONDITION_BOUND'
        createdUtc = $CreatedUtc
        candidate = New-CandidateReceiptObject
        condition = [pscustomobject][ordered]@{
            name = $ExpectedCondition
            activeFileToken = $script:PackContracts[$ExpectedCondition].FileToken
            expectedPackSha256 = $script:PackContracts[$ExpectedCondition].Sha256
            physicalPackRequired = [bool]$EndFence.condition.physicalPackRequired
            physicalPackSha256 = $EndFence.condition.physicalPackSha256
            physicalPackMatchedAtBothFences = $true
            latestResourceManagerStateMatchedAtBothFences = $true
            allReloadsDuringIntervalMatched = $true
            blocksAtlasMatchedAtBothFences = $true
            exactLatestLogInodePreserved = $true
            exactLatestLogStayedFreshInSampler = $true
            blocksAtlas = [pscustomobject][ordered]@{
                width = [int64]$EndFence.latestLog.blocksAtlas.width
                height = [int64]$EndFence.latestLog.blocksAtlas.height
                miplevel = [int]$EndFence.latestLog.blocksAtlas.miplevel
                beginLineSha256 = [string]$StartReceipt.latestLog.blocksAtlas.lineSha256
                finalLineSha256 = [string]$EndFence.latestLog.blocksAtlas.lineSha256
                parsedFromFreshExactLatestLogAtBothFences = $true
                rawLinesPersisted = $false
            }
        }
        startFence = [pscustomobject][ordered]@{
            receiptPath = ConvertTo-RepoRelativePath $StartReceiptPath
            receiptSha256 = $StartReceiptSha256
            observedUtc = [string]$StartReceipt.observedUtc
            resourceManagerLineCount = [int]$StartReceipt.latestLog.resourceManagerLineCount
            resourceManagerLastLineSha256 = [string]$StartReceipt.latestLog.resourceManagerLastLineSha256
            blocksAtlas = $StartReceipt.latestLog.blocksAtlas
        }
        finalFence = [pscustomobject][ordered]@{
            observedUtc = [string]$EndFence.observedUtc
            resourceManagerLineCount = [int]$EndFence.latestLog.resourceManagerLineCount
            resourceManagerLastLineSha256 = [string]$EndFence.latestLog.resourceManagerLastLineSha256
            blocksAtlas = $EndFence.latestLog.blocksAtlas
        }
        process = [pscustomobject][ordered]@{
            pid = [int]$Sampler.validation.pid
            processStartTicks = [uint64]$Sampler.validation.processStartTicks
            sameIncarnationAcrossBeginSamplerFinalize = $true
        }
        sampler = [pscustomobject][ordered]@{
            producerPath = $script:SamplerRelativePath
            producerNormalizedLfSha256 = $script:SamplerSha256
            summaryPath = [string]$Sampler.summaryPath
            summarySha256 = [string]$Sampler.summarySha256
            samplesPath = [string]$Sampler.samplesPath
            samplesSha256 = [string]$Sampler.samplesSha256
            requestedDurationMinutes = [double]$Sampler.validation.requestedDurationMinutes
            observedDurationMinutes = [double]$Sampler.validation.observedDurationMinutes
            sampleCount = [int]$Sampler.validation.sampleCount
            intervalSeconds = [int]$Sampler.validation.intervalSeconds
            maxPssMib = [double]$Sampler.validation.maxPssMib
            maxRssMib = [double]$Sampler.validation.maxRssMib
            maxGraphicsMib = [double]$Sampler.validation.maxGraphicsMib
            firstPssMib = [double]$Sampler.validation.firstPssMib
            finalPssMib = [double]$Sampler.validation.finalPssMib
            pssChangeMib = [double]$Sampler.validation.pssChangeMib
            postWarmPssSlopeMibPerMinute = [double]$Sampler.validation.postWarmPssSlopeMibPerMinute
            lastThirtyMinutesGrowthMib = [double]$Sampler.validation.lastThirtyMinutesGrowthMib
            formalSamplerResult = [string]$Sampler.validation.formalSamplerResult
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            supplementaryConditionBindingOnly = $true
            wrapperInvokedSampler = $false
            deviceReadOnly = $true
            profileOrOptionsEdited = $false
            appLaunchedOrStopped = $false
            packageMutationUsed = $false
            rawLatestLogPersisted = $false
            accountWorldOrServerDataPersisted = $false
            deviceSerialPersisted = $false
            formalMemoryResultOverridden = $false
            causalMemoryClaimMade = $false
            stablePromotionAuthorized = $false
        }
    }
}

function Assert-ConditionReceipt {
    param($Receipt, [string] $Context)
    Require ([int](Get-RequiredProperty $Receipt 'schemaVersion' $Context) -eq 1 -and
        [string](Get-RequiredProperty $Receipt 'receiptType' $Context) -ceq
            'V71_RC6_2_RESOURCE_PACK_MEMORY_CONDITION' -and
        [string](Get-RequiredProperty $Receipt 'result' $Context) -ceq
            'PASS_CONDITION_BOUND') "$Context type/result was invalid."
    Assert-CandidateReceiptObject (Get-RequiredProperty $Receipt 'candidate' $Context) `
        "$Context candidate"
    $conditionObject = Get-RequiredProperty $Receipt 'condition' $Context
    $name = [string](Get-RequiredProperty $conditionObject 'name' "$Context condition")
    Require ($script:PackContracts.Contains($name)) "$Context named an unknown condition."
    $contract = $script:PackContracts[$name]
    Require ([string](Get-RequiredProperty $conditionObject 'activeFileToken' "$Context condition") -ceq
            [string]$contract.FileToken -and
        [string](Get-RequiredProperty $conditionObject 'expectedPackSha256' "$Context condition") -ceq
            [string]$contract.Sha256 -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'physicalPackMatchedAtBothFences' "$Context condition")) -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'latestResourceManagerStateMatchedAtBothFences' "$Context condition")) -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'allReloadsDuringIntervalMatched' "$Context condition")) -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'blocksAtlasMatchedAtBothFences' "$Context condition")) -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'exactLatestLogInodePreserved' "$Context condition")) -and
        (Test-ExactTrue (Get-RequiredProperty $conditionObject 'exactLatestLogStayedFreshInSampler' "$Context condition"))) `
        "$Context condition binding was incomplete."
    $physicalRequired = Get-RequiredProperty $conditionObject 'physicalPackRequired' `
        "$Context condition"
    $physicalSha = Get-RequiredProperty $conditionObject 'physicalPackSha256' `
        "$Context condition"
    if ($name -ceq 'Vanilla') {
        Require ((Test-ExactFalse $physicalRequired) -and $null -eq $physicalSha) `
            "$Context vanilla condition claimed a physical active pack."
    } else {
        Require ((Test-ExactTrue $physicalRequired) -and $physicalSha -is [string] -and
            [string]$physicalSha -ceq [string]$contract.Sha256) `
            "$Context non-vanilla condition lost its physical pack binding."
    }
    $atlas = Get-RequiredProperty $conditionObject 'blocksAtlas' "$Context condition"
    $width = [int64](Get-RequiredProperty $atlas 'width' "$Context blocks atlas")
    $height = [int64](Get-RequiredProperty $atlas 'height' "$Context blocks atlas")
    $miplevel = [int](Get-RequiredProperty $atlas 'miplevel' "$Context blocks atlas")
    Require ($width -gt 0 -and $height -gt 0 -and $miplevel -ge 0 -and
        $miplevel -le 32 -and
        (Test-ExactTrue (Get-RequiredProperty $atlas 'parsedFromFreshExactLatestLogAtBothFences' "$Context blocks atlas")) -and
        (Test-ExactFalse (Get-RequiredProperty $atlas 'rawLinesPersisted' "$Context blocks atlas"))) `
        "$Context blocks-atlas binding was invalid."
    foreach ($field in @('beginLineSha256', 'finalLineSha256')) {
        $null = ConvertTo-CanonicalSha256 `
            (Get-RequiredProperty $atlas $field "$Context blocks atlas") `
            "$Context blocks atlas $field"
    }
    $startFence = Get-RequiredProperty $Receipt 'startFence' $Context
    $finalFence = Get-RequiredProperty $Receipt 'finalFence' $Context
    $startAtlas = Assert-BlocksAtlasReceiptObject `
        (Get-RequiredProperty $startFence 'blocksAtlas' "$Context start fence") `
        "$Context start-fence blocks atlas"
    $finalAtlas = Assert-BlocksAtlasReceiptObject `
        (Get-RequiredProperty $finalFence 'blocksAtlas' "$Context final fence") `
        "$Context final-fence blocks atlas"
    Require ($startAtlas.width -eq $width -and $startAtlas.height -eq $height -and
        $startAtlas.miplevel -eq $miplevel -and $finalAtlas.width -eq $width -and
        $finalAtlas.height -eq $height -and $finalAtlas.miplevel -eq $miplevel -and
        [string]$startFence.blocksAtlas.lineSha256 -ceq [string]$atlas.beginLineSha256 -and
        [string]$finalFence.blocksAtlas.lineSha256 -ceq [string]$atlas.finalLineSha256) `
        "$Context blocks-atlas fence bindings disagreed."
    $startObserved = ConvertTo-RoundtripDateTimeOffset `
        (Get-RequiredProperty $startFence 'observedUtc' "$Context start fence") `
        "$Context start-fence observedUtc"
    $finalObserved = ConvertTo-RoundtripDateTimeOffset `
        (Get-RequiredProperty $finalFence 'observedUtc' "$Context final fence") `
        "$Context final-fence observedUtc"
    $created = ConvertTo-RoundtripDateTimeOffset `
        (Get-RequiredProperty $Receipt 'createdUtc' $Context) "$Context createdUtc"
    $startCount = [int](Get-RequiredProperty $startFence 'resourceManagerLineCount' `
        "$Context start fence")
    $finalCount = [int](Get-RequiredProperty $finalFence 'resourceManagerLineCount' `
        "$Context final fence")
    Require ($startObserved -lt $finalObserved -and $finalObserved -le $created -and
        $startCount -gt 0 -and $finalCount -ge $startCount) `
        "$Context fence timestamps/counts were inconsistent."
    foreach ($fence in @($startFence, $finalFence)) {
        $null = ConvertTo-CanonicalSha256 `
            (Get-RequiredProperty $fence 'resourceManagerLastLineSha256' "$Context fence") `
            "$Context ResourceManager line hash"
    }
    $startReceiptPath = Assert-RepoEvidenceReference `
        (Get-RequiredProperty $startFence 'receiptPath' "$Context start fence") `
        'condition-start.json' "$Context start receipt"
    $null = ConvertTo-CanonicalSha256 `
        (Get-RequiredProperty $startFence 'receiptSha256' "$Context start fence") `
        "$Context start receipt hash"
    $process = Get-RequiredProperty $Receipt 'process' $Context
    Require ([int](Get-RequiredProperty $process 'pid' "$Context process") -gt 0 -and
        [uint64](Get-RequiredProperty $process 'processStartTicks' "$Context process") -gt 0 -and
        (Test-ExactTrue (Get-RequiredProperty $process 'sameIncarnationAcrossBeginSamplerFinalize' "$Context process"))) `
        "$Context process-incarnation binding was invalid."
    $sampler = Get-RequiredProperty $Receipt 'sampler' $Context
    Require ([string](Get-RequiredProperty $sampler 'producerNormalizedLfSha256' "$Context sampler") -ceq
            $script:SamplerSha256 -and
        [double](Get-RequiredProperty $sampler 'requestedDurationMinutes' "$Context sampler") -ge 30 -and
        [double](Get-RequiredProperty $sampler 'observedDurationMinutes' "$Context sampler") -ge 30) `
        "$Context sampler duration/producer was invalid."
    foreach ($field in @('summarySha256', 'samplesSha256')) {
        $null = ConvertTo-CanonicalSha256 `
            (Get-RequiredProperty $sampler $field "$Context sampler") "$Context $field"
    }
    $summaryPath = Assert-RepoEvidenceReference `
        (Get-RequiredProperty $sampler 'summaryPath' "$Context sampler") `
        'summary.json' "$Context sampler summary"
    $samplesPath = Assert-RepoEvidenceReference `
        (Get-RequiredProperty $sampler 'samplesPath' "$Context sampler") `
        'samples.jsonl' "$Context sampler samples"
    Require (
        [IO.Path]::GetDirectoryName($summaryPath.Replace('/', [IO.Path]::DirectorySeparatorChar)) -ceq
            [IO.Path]::GetDirectoryName($samplesPath.Replace('/', [IO.Path]::DirectorySeparatorChar))) `
        "$Context sampler references were not one safe paired output directory."
    $requestedDuration = [double]$sampler.requestedDurationMinutes
    $observedDuration = [double]$sampler.observedDurationMinutes
    $sampleCount = [int](Get-RequiredProperty $sampler 'sampleCount' "$Context sampler")
    $intervalSeconds = [int](Get-RequiredProperty $sampler 'intervalSeconds' "$Context sampler")
    Require ($observedDuration -ge $requestedDuration -and $sampleCount -ge 2 -and
        $intervalSeconds -ge 60 -and $intervalSeconds -le 900 -and
        @('PASS', 'FAIL') -ccontains
            [string](Get-RequiredProperty $sampler 'formalSamplerResult' "$Context sampler")) `
        "$Context sampler completion/result fields were invalid."
    $boundary = Get-RequiredProperty $Receipt 'evidenceBoundary' $Context
    foreach ($field in @('supplementaryConditionBindingOnly', 'deviceReadOnly')) {
        Require (Test-ExactTrue (Get-RequiredProperty $boundary $field "$Context boundary")) `
            "$Context boundary failed $field."
    }
    foreach ($field in @('profileOrOptionsEdited', 'appLaunchedOrStopped',
            'packageMutationUsed', 'rawLatestLogPersisted',
            'accountWorldOrServerDataPersisted', 'deviceSerialPersisted',
            'formalMemoryResultOverridden', 'causalMemoryClaimMade',
            'stablePromotionAuthorized', 'wrapperInvokedSampler')) {
        Require (Test-ExactFalse (Get-RequiredProperty $boundary $field "$Context boundary")) `
            "$Context boundary claimed forbidden behavior: $field."
    }
    return $name
}

function Read-ConditionReceiptFile {
    param([string] $Path, [string] $Context)
    $full = Resolve-EvidencePath $Path $Context -MustExist
    $locked = Enter-LockedUtf8File $full $Context 4MB
    try {
        $receipt = ConvertFrom-StrictJsonText $locked.Text $Context
        $conditionName = Assert-ConditionReceipt $receipt $Context
        return [pscustomobject][ordered]@{
            path = ConvertTo-RepoRelativePath $full
            sha256 = [string]$locked.Sha256
            receipt = $receipt
            condition = $conditionName
        }
    } finally {
        $locked.Stream.Dispose()
    }
}

function Assert-DistinctComparisonPair {
    param($A, $B)
    Require ($script:PackContracts.Contains([string]$A.condition) -and
        $script:PackContracts.Contains([string]$B.condition) -and
        [string]$A.condition -cne [string]$B.condition) `
        'A/B comparison requires two distinct known resource-pack conditions.'
    Require ([string]$A.receipt.sampler.summarySha256 -cne
            [string]$B.receipt.sampler.summarySha256 -and
        [string]$A.receipt.sampler.samplesSha256 -cne
            [string]$B.receipt.sampler.samplesSha256) `
        'A/B comparison cannot reuse one sampler run for both conditions.'
    $aCreated = ConvertTo-RoundtripDateTimeOffset $A.receipt.createdUtc `
        'condition A createdUtc'
    $bCreated = ConvertTo-RoundtripDateTimeOffset $B.receipt.createdUtc `
        'condition B createdUtc'
    Require ($aCreated -cne $bCreated) 'A/B receipts had an ambiguous creation time.'
}

function New-ComparisonReceiptObject {
    param($A, $B, [string] $CreatedUtc = '')
    Assert-DistinctComparisonPair $A $B
    if ([string]::IsNullOrEmpty($CreatedUtc)) {
        $CreatedUtc = [DateTime]::UtcNow.ToString('o')
    } else {
        $null = ConvertTo-RoundtripDateTimeOffset $CreatedUtc 'comparison createdUtc'
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_RESOURCE_PACK_MEMORY_AB'
        result = 'PASS_DISTINCT_CONDITIONS_BOUND'
        createdUtc = $CreatedUtc
        candidate = New-CandidateReceiptObject
        a = [pscustomobject][ordered]@{
            condition = $A.condition; receiptPath = $A.path; receiptSha256 = $A.sha256
            summarySha256 = [string]$A.receipt.sampler.summarySha256
            samplesSha256 = [string]$A.receipt.sampler.samplesSha256
            durationMinutes = [double]$A.receipt.sampler.observedDurationMinutes
            atlasWidth = [int64]$A.receipt.condition.blocksAtlas.width
            atlasHeight = [int64]$A.receipt.condition.blocksAtlas.height
            atlasMiplevel = [int]$A.receipt.condition.blocksAtlas.miplevel
            maxPssMib = [double]$A.receipt.sampler.maxPssMib
            maxRssMib = [double]$A.receipt.sampler.maxRssMib
            maxGraphicsMib = [double]$A.receipt.sampler.maxGraphicsMib
            pssChangeMib = [double]$A.receipt.sampler.pssChangeMib
        }
        b = [pscustomobject][ordered]@{
            condition = $B.condition; receiptPath = $B.path; receiptSha256 = $B.sha256
            summarySha256 = [string]$B.receipt.sampler.summarySha256
            samplesSha256 = [string]$B.receipt.sampler.samplesSha256
            durationMinutes = [double]$B.receipt.sampler.observedDurationMinutes
            atlasWidth = [int64]$B.receipt.condition.blocksAtlas.width
            atlasHeight = [int64]$B.receipt.condition.blocksAtlas.height
            atlasMiplevel = [int]$B.receipt.condition.blocksAtlas.miplevel
            maxPssMib = [double]$B.receipt.sampler.maxPssMib
            maxRssMib = [double]$B.receipt.sampler.maxRssMib
            maxGraphicsMib = [double]$B.receipt.sampler.maxGraphicsMib
            pssChangeMib = [double]$B.receipt.sampler.pssChangeMib
        }
        bMinusA = [pscustomobject][ordered]@{
            maxPssMib = [math]::Round(
                [double]$B.receipt.sampler.maxPssMib - [double]$A.receipt.sampler.maxPssMib, 3)
            maxRssMib = [math]::Round(
                [double]$B.receipt.sampler.maxRssMib - [double]$A.receipt.sampler.maxRssMib, 3)
            maxGraphicsMib = [math]::Round(
                [double]$B.receipt.sampler.maxGraphicsMib - [double]$A.receipt.sampler.maxGraphicsMib, 3)
            pssChangeMib = [math]::Round(
                [double]$B.receipt.sampler.pssChangeMib - [double]$A.receipt.sampler.pssChangeMib, 3)
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            HostOnlyComparison = $true
            distinctConditionRuns = $true
            minimumThirtyMinutesPerCondition = $true
            rawLatestLogPersisted = $false
            accountWorldOrServerDataPersisted = $false
            formalMemoryResultOverridden = $false
            causalMemoryClaimMade = $false
            stablePromotionAuthorized = $false
        }
    }
}

function New-MockSamplerFixture {
    $samples = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -le 6; $index++) {
        $samples.Add([pscustomobject][ordered]@{
            timestampUtc = ([DateTimeOffset]'2026-09-07T00:00:00Z').AddMinutes(
                $index * 5).ToString('o')
            elapsedMinutes = [double]($index * 5)
            pid = 1234; pidStable = $true; focus = 'focused'; gameJvmAlive = $true
            expectedGameLogPathMatched = $true
            expectedGameLogRegularAndNonEmpty = $true
            expectedGameLogSameFile = $true
            expectedGameLogTemporallyBoundToProcess = $true
            expectedGameLogFresh = $true
            totalPssKib = [int64](1024000 + ($index * 1024))
            totalRssKib = [int64](921600 + ($index * 512))
            javaHeapKib = 100000; nativeHeapKib = 200000; graphicsKib = 300000
            vmRssKib = [int64](900000 + ($index * 512)); vmSwapKib = 0
            memAvailableKib = 2000000; swapFreeKib = 4000000
            batteryTemperatureC = 42.0; batteryStatusCode = 2; thermalStatusCode = 0
            thermalLimitExceeded = $false; thermalSafetyStopPerformed = $false
        })
    }
    $provenance = [pscustomobject][ordered]@{
        installedIdentityMatched = $true; baseApkMatched = $true
        persistentCoreMatched = $true; persistentVeqMatched = $true; allMatched = $true
    }
    $summary = [pscustomobject][ordered]@{
        schemaVersion = 3; package = $script:Package; producerSha256 = $script:SamplerSha256
        provenance = $provenance; finalProvenance = $provenance
        runtimeBinding = [pscustomobject][ordered]@{
            receiptType = 'V71_RC6_2_MEMORY_SOAK_RUNTIME_BINDING'; result = 'PASS'
            start = [pscustomobject][ordered]@{
                pid = 1234; processStartTicks = [uint64]99
                processStartEpochSeconds = 1788739000.0
                producerSha256 = $script:SamplerSha256
            }
            final = [pscustomobject][ordered]@{
                pid = 1234; processStartTicks = [uint64]99
                sameProcessIncarnation = $true
                observedUtc = '2026-09-07T00:30:01.0000000+00:00'
            }
            evidenceBoundary = [pscustomobject][ordered]@{
                rawLogsPersisted = $false; logSnippetsPersisted = $false
                deviceSerialPersisted = $false; accountDataPersisted = $false
                hostAbsolutePathsPersisted = $false
            }
        }
        startedUtc = '2026-09-07T00:00:00.0000000+00:00'
        requestedDurationMinutes = 30; intervalSeconds = 300; samples = 7
        minimumExpectedSamples = 7; completeMetricSamples = 7; initialPid = 1234
        pidStable = $true; focusStayedOnLab = $true; gameJvmStayedAlive = $true
        expectedGameLogStayedFresh = $true
        maxPssMib = 1006.0; maxRssMib = 881.906
        thermalSafety = [pscustomobject][ordered]@{
            limitExceeded = $false; labSafetyStopPerformed = $false
            safetyStopInvocations = 0; stablePackageStopped = $false
        }
        postWarmPssSlopeMibPerMinute = 0.2; lastThirtyMinutesGrowthMib = 6.0
        acceptance = [pscustomobject][ordered]@{
            completedDuration = $true; sampleCountComplete = $true
            allRequiredMetricsPresent = $true; focusStayedOnLab = $true
            gameJvmStayedAlive = $true; expectedGameLogStayedFresh = $true
            thermalLimitNeverExceeded = $true; thermalSafetyStopNotRequired = $true
            postWarmSamplesComplete = $true; lastThirtySamplesComplete = $true
            passed = $false
        }
    }
    return [pscustomobject]@{ Summary = $summary; Samples = $samples.ToArray() }
}

function Invoke-SelfTest {
    Assert-HostContract
    Require (Test-ExpectedFailure {
        ConvertFrom-StrictJsonText '{"condition":"Original","condition":"HalfGe256"}' `
            'duplicate-property fixture' | Out-Null
    }) 'A duplicate JSON property was accepted.'
    $vanillaResource = '[12:00:00] [Render thread/INFO]: Reloading ResourceManager: vanilla, fabric'
    $vanillaAtlas = '[12:00:01] [Render thread/INFO]: Created: 2048x2048x4 minecraft:textures/atlas/blocks.png-atlas'
    $originalAtlas = '[12:00:01] [Render thread/INFO]: Created: 8192x4096x4 minecraft:textures/atlas/blocks.png-atlas'
    $halfAtlas = '[12:00:01] [Render thread/INFO]: Created: 4096x4096x4 minecraft:textures/atlas/blocks.png-atlas'
    Require ((Get-ResourceManagerConditionFromLine $vanillaResource) -ceq
            'Vanilla') 'Vanilla ResourceManager fixture failed.'
    $fixtureLines = [ordered]@{
        Original = '[12:00:00] [Render thread/INFO]: Reloading ResourceManager: vanilla, fabric, file/LunarLabs-26.2-Quest-Vulkan-v2.zip'
        Probe512 = '[12:00:00] [Render thread/INFO]: Reloading ResourceManager: vanilla, fabric, file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-probe512.zip'
        HalfGe256 = '[12:00:00] [Render thread/INFO]: Reloading ResourceManager: vanilla, fabric, file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-half-ge256.zip'
        Cap128 = '[12:00:00] [Render thread/INFO]: Reloading ResourceManager: vanilla, fabric, file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-cap128.zip'
    }
    foreach ($entry in $fixtureLines.GetEnumerator()) {
        Require ((Get-ResourceManagerConditionFromLine $entry.Value) -ceq $entry.Key) `
            "$($entry.Key) ResourceManager fixture failed."
        $null = Assert-ResourceManagerLinesForCondition @($entry.Value) $entry.Key
    }
    $vanillaLogEvidence = Read-FilteredLatestLogEvidence @(
        "LOG_EVIDENCE_COUNT`t2",
        "LOG_EVIDENCE_LINE`t$vanillaResource",
        "LOG_EVIDENCE_LINE`t$vanillaAtlas")
    Require ($vanillaLogEvidence.resourceManagerLineCount -eq 1 -and
        $vanillaLogEvidence.blocksAtlas.width -eq 2048 -and
        $vanillaLogEvidence.blocksAtlas.height -eq 2048 -and
        $vanillaLogEvidence.blocksAtlas.miplevel -eq 4) `
        'Vanilla blocks-atlas fixture was not parsed from its supplied log.'
    $originalLogEvidence = Read-FilteredLatestLogEvidence @(
        "LOG_EVIDENCE_COUNT`t2",
        "LOG_EVIDENCE_LINE`t$($fixtureLines.Original)",
        "LOG_EVIDENCE_LINE`t$originalAtlas")
    Require ($originalLogEvidence.blocksAtlas.width -eq 8192 -and
        $originalLogEvidence.blocksAtlas.height -eq 4096 -and
        $originalLogEvidence.blocksAtlas.miplevel -eq 4) `
        'Original-pack blocks-atlas fixture was not parsed from its supplied log.'
    $halfLogEvidence = Read-FilteredLatestLogEvidence @(
        "LOG_EVIDENCE_COUNT`t2",
        "LOG_EVIDENCE_LINE`t$($fixtureLines.HalfGe256)",
        "LOG_EVIDENCE_LINE`t$halfAtlas")
    Require ($halfLogEvidence.blocksAtlas.width -eq 4096 -and
        $halfLogEvidence.blocksAtlas.height -eq 4096 -and
        $halfLogEvidence.blocksAtlas.miplevel -eq 4 -and
        (Get-ResourceManagerConditionFromLine $fixtureLines.HalfGe256) -ceq 'HalfGe256') `
        'HalfGe256 identity/blocks-atlas fixture was not parsed from its supplied log.'
    Require (Test-ExpectedFailure {
        Read-FilteredLatestLogEvidence @(
            "LOG_EVIDENCE_COUNT`t1",
            "LOG_EVIDENCE_LINE`t$vanillaResource") | Out-Null
    }) 'A supplied log missing its blocks-atlas line was accepted.'
    Require (Test-ExpectedFailure {
        Read-FilteredLatestLogEvidence @(
            "LOG_EVIDENCE_COUNT`t3",
            "LOG_EVIDENCE_LINE`t$vanillaResource",
            "LOG_EVIDENCE_LINE`t$vanillaAtlas",
            "LOG_EVIDENCE_LINE`t$originalAtlas") | Out-Null
    }) 'A supplied log with ambiguous blocks-atlas lines was accepted.'
    Require (Test-ExpectedFailure {
        Read-FilteredLatestLogEvidence @(
            "LOG_EVIDENCE_COUNT`t2",
            "LOG_EVIDENCE_LINE`t$vanillaAtlas",
            "LOG_EVIDENCE_LINE`t$vanillaResource") | Out-Null
    }) 'A blocks-atlas line preceding the latest ResourceManager state was accepted.'
    Require (Test-ExpectedFailure {
        Read-FilteredLatestLogEvidence @(
            "LOG_EVIDENCE_COUNT`t2",
            "LOG_EVIDENCE_LINE`t$vanillaResource",
            "LOG_EVIDENCE_LINE`t[12:00:01] [Render thread/INFO]: Created: 2048x2048 minecraft:textures/atlas/blocks.png-atlas") | Out-Null
    }) 'A malformed blocks-atlas dimension line was accepted.'
    Require (Test-ExpectedFailure {
        Get-ResourceManagerConditionFromLine `
            ($fixtureLines.Original + ', file/LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-cap128.zip') | Out-Null
    }) 'A multiple-pack ResourceManager state was accepted.'
    Require (Test-ExpectedFailure {
        Get-ResourceManagerConditionFromLine `
            '[12:00:00] [Render thread/INFO]: Reloading ResourceManager: vanilla, file/unknown.zip' | Out-Null
    }) 'An unknown file pack was accepted.'
    Require (Test-ExpectedFailure {
        Assert-ResourceManagerLinesForCondition @($fixtureLines.Original) 'Cap128' | Out-Null
    }) 'A mismatched requested condition was accepted.'
    Require (-not (Test-ExpectedFailure {
        Assert-ResourceManagerLinesForCondition @(
            $fixtureLines.Original, $fixtureLines.Cap128) 'Cap128' 1 | Out-Null
    })) 'A valid condition transition before the interval was rejected.'
    Require (Test-ExpectedFailure {
        Assert-ResourceManagerLinesForCondition @(
            $fixtureLines.Cap128, $fixtureLines.Original, $fixtureLines.Cap128) 'Cap128' 1 | Out-Null
    }) 'A mismatched reload during the interval was accepted.'
    $metadata = Read-GameLogMetadata @(
        "DEVICE_EPOCH`t1788740000",
        "GAME_LOG`t8192_1788739995_1788739000_44123")
    $process = [pscustomobject]@{
        processStartEpochSeconds = 1788738999.0
    }
    Assert-FreshGameLogMetadata $metadata $process
    $stale = Read-GameLogMetadata @(
        "DEVICE_EPOCH`t1788740000",
        "GAME_LOG`t8192_1788739900_1788739000_44123")
    Require (Test-ExpectedFailure { Assert-FreshGameLogMetadata $stale $process }) `
        'A stale latest.log fixture was accepted.'
    $identity = Read-PackageIdentity @(
        '  versionCode=71 minSdk=29 targetSdk=34',
        "  versionName=$($script:VersionName)")
    Require ($identity.VersionCode -eq 71) 'Exact RC6.2 identity fixture failed.'
    Require (Test-ExpectedFailure {
        Read-PackageIdentity @('versionCode=70', "versionName=$($script:VersionName)") |
            Out-Null
    }) 'A wrong package version fixture was accepted.'
    $mock = New-MockSamplerFixture
    $validated = Assert-SamplerContent $mock.Summary $mock.Samples
    Require ($validated.observedDurationMinutes -eq 30 -and
        $validated.sampleCount -eq 7 -and $validated.formalSamplerResult -ceq 'FAIL') `
        'Complete minimum-duration sampler fixture failed.'
    $savedDuration = $mock.Summary.requestedDurationMinutes
    $mock.Summary.requestedDurationMinutes = 29
    Require (Test-ExpectedFailure {
        Assert-SamplerContent $mock.Summary $mock.Samples | Out-Null
    }) 'A sub-thirty-minute sampler fixture was accepted.'
    $mock.Summary.requestedDurationMinutes = $savedDuration
    $savedProducer = $mock.Summary.producerSha256
    $mock.Summary.producerSha256 = 'A' * 64
    Require (Test-ExpectedFailure {
        Assert-SamplerContent $mock.Summary $mock.Samples | Out-Null
    }) 'A producer-detached sampler fixture was accepted.'
    $mock.Summary.producerSha256 = $savedProducer
    $mock.Samples[2].pidStable = $false
    Require (Test-ExpectedFailure {
        Assert-SamplerContent $mock.Summary $mock.Samples | Out-Null
    }) 'A PID-unstable sampler fixture was accepted.'
    $mock.Samples[2].pidStable = $true
    $mock.Samples[3].expectedGameLogFresh = $false
    Require (Test-ExpectedFailure {
        Assert-SamplerContent $mock.Summary $mock.Samples | Out-Null
    }) 'A stale exact-log sampler row was accepted.'
    $mock.Samples[3].expectedGameLogFresh = $true
    $mock.Samples[4].thermalSafetyStopPerformed = $true
    Require (Test-ExpectedFailure {
        Assert-SamplerContent $mock.Summary $mock.Samples | Out-Null
    }) 'A sampler fixture that stopped the app was accepted.'
    $mock.Samples[4].thermalSafetyStopPerformed = $false
    $mock.Summary.provenance.allMatched = $false
    Require (Test-ExpectedFailure {
        Assert-SamplerContent $mock.Summary $mock.Samples | Out-Null
    }) 'A provenance-mismatched sampler fixture was accepted.'
    $mock.Summary.provenance.allMatched = $true
    $originalResource = Assert-ResourceManagerLinesForCondition `
        ([string[]]$originalLogEvidence.resourceManagerLines) 'Original'
    $mockFence = [pscustomobject][ordered]@{
        observedUtc = '2026-09-06T23:59:59.0000000+00:00'
        runtime = [pscustomobject][ordered]@{
            pid = 1234; processStartTicks = [uint64]99
            processStartEpochSeconds = 1788739000.0
        }
        latestLog = [pscustomobject][ordered]@{
            fileInode = [uint64]44123; sizeBytes = [int64]8192
            modifiedEpochSeconds = 1788739995; observedDeviceEpochSeconds = 1788740000
            fresh = $true; resourceManagerLineCount = [int]$originalResource.lineCount
            resourceManagerLastLineSha256 = [string]$originalResource.lastLineSha256
            filteredEvidenceLineCount = [int]$originalLogEvidence.filteredLineCount
            blocksAtlas = $originalLogEvidence.blocksAtlas; rawLinesPersisted = $false
        }
        condition = [pscustomobject][ordered]@{
            name = 'Original'; activeFileToken = $script:PackContracts.Original.FileToken
            expectedPackSha256 = $script:PackContracts.Original.Sha256
            physicalPackRequired = $true
            physicalPackSha256 = $script:PackContracts.Original.Sha256
            physicalPackMatched = $true
        }
    }
    $mockStartReceipt = New-StartReceipt 'Original' $mockFence
    Assert-StartReceipt $mockStartReceipt 'Original'
    $savedPhysicalSha = $mockStartReceipt.condition.physicalPackSha256
    $mockStartReceipt.condition.physicalPackSha256 = 'A' * 64
    Require (Test-ExpectedFailure {
        Assert-StartReceipt $mockStartReceipt 'Original'
    }) 'A start receipt with mismatched physical pack bytes was accepted.'
    $mockStartReceipt.condition.physicalPackSha256 = $savedPhysicalSha
    $mockEndFence = [pscustomobject][ordered]@{
        observedUtc = '2026-09-07T00:30:02.0000000+00:00'
        runtime = $mockFence.runtime
        latestLog = [pscustomobject][ordered]@{
            fileInode = [uint64]44123; sizeBytes = [int64]16384
            resourceManagerLineCount = [int]$originalResource.lineCount
            resourceManagerLastLineSha256 = [string]$originalResource.lastLineSha256
            blocksAtlas = $originalLogEvidence.blocksAtlas
        }
        condition = $mockFence.condition
    }
    $mockSamplerEnvelope = [pscustomobject][ordered]@{
        summaryPath = 'artifacts/memory/mock-sampler/summary.json'
        summarySha256 = '8' * 64
        samplesPath = 'artifacts/memory/mock-sampler/samples.jsonl'
        samplesSha256 = '9' * 64
        validation = $validated
    }
    Assert-ConditionRunBinding $mockStartReceipt $mockSamplerEnvelope `
        $mockEndFence 'Original'
    $mockConditionReceipt = New-ConditionReceiptObject -ExpectedCondition Original `
        -StartReceipt $mockStartReceipt `
        -StartReceiptPath (Join-Path $script:RepoRoot `
            'artifacts/memory/mock-condition/condition-start.json') `
        -StartReceiptSha256 ('7' * 64) -Sampler $mockSamplerEnvelope `
        -EndFence $mockEndFence -CreatedUtc '2026-09-07T00:30:03.0000000+00:00'
    Require ((Assert-ConditionReceipt $mockConditionReceipt 'mock condition receipt') -ceq
        'Original') 'A complete condition-bound receipt fixture was rejected.'
    $mockConditionReceipt.condition.blocksAtlas.width = 4096
    Require (Test-ExpectedFailure {
        Assert-ConditionReceipt $mockConditionReceipt 'mock condition receipt' | Out-Null
    }) 'A receipt with atlas dimensions detached from its fences was accepted.'
    $mockConditionReceipt.condition.blocksAtlas.width = 8192
    $mockConditionReceipt.evidenceBoundary.appLaunchedOrStopped = $true
    Require (Test-ExpectedFailure {
        Assert-ConditionReceipt $mockConditionReceipt 'mock condition receipt' | Out-Null
    }) 'A receipt claiming an app launch/stop was accepted.'
    $mockConditionReceipt.evidenceBoundary.appLaunchedOrStopped = $false
    $mockConditionReceipt.sampler.observedDurationMinutes = 29
    Require (Test-ExpectedFailure {
        Assert-ConditionReceipt $mockConditionReceipt 'mock condition receipt' | Out-Null
    }) 'A condition receipt detached from its minimum sampler duration was accepted.'
    $mockConditionReceipt.sampler.observedDurationMinutes = 30
    $comparisonA = [pscustomobject][ordered]@{
        condition = 'Original'; path = 'artifacts/memory/mock-a/resource-pack-condition.json'
        sha256 = '1' * 64
        receipt = [pscustomobject][ordered]@{
            createdUtc = '2026-09-07T01:00:00.0000000+00:00'
            condition = [pscustomobject][ordered]@{
                blocksAtlas = [pscustomobject]@{ width = 8192; height = 4096; miplevel = 4 }
            }
            sampler = [pscustomobject][ordered]@{
                summarySha256 = '2' * 64; samplesSha256 = '3' * 64
                observedDurationMinutes = 30.0; maxPssMib = 3000.0
                maxRssMib = 2200.0; maxGraphicsMib = 1200.0; pssChangeMib = 50.0
            }
        }
    }
    $comparisonB = [pscustomobject][ordered]@{
        condition = 'HalfGe256'; path = 'artifacts/memory/mock-b/resource-pack-condition.json'
        sha256 = '4' * 64
        receipt = [pscustomobject][ordered]@{
            createdUtc = '2026-09-07T02:00:00.0000000+00:00'
            condition = [pscustomobject][ordered]@{
                blocksAtlas = [pscustomobject]@{ width = 4096; height = 4096; miplevel = 4 }
            }
            sampler = [pscustomobject][ordered]@{
                summarySha256 = '5' * 64; samplesSha256 = '6' * 64
                observedDurationMinutes = 30.0; maxPssMib = 2600.0
                maxRssMib = 1900.0; maxGraphicsMib = 800.0; pssChangeMib = 20.0
            }
        }
    }
    $comparison = New-ComparisonReceiptObject $comparisonA $comparisonB `
        '2026-09-07T03:00:00.0000000+00:00'
    Require ($comparison.a.condition -ceq 'Original' -and
        $comparison.b.condition -ceq 'HalfGe256' -and
        $comparison.a.atlasWidth -eq 8192 -and $comparison.b.atlasWidth -eq 4096 -and
        $comparison.b.atlasMiplevel -eq 4 -and
        $comparison.bMinusA.maxPssMib -eq -400.0) `
        'Original/HalfGe256 comparison did not preserve identity, observed atlas, or deltas.'
    $comparisonB.condition = 'Original'
    Require (Test-ExpectedFailure {
        Assert-DistinctComparisonPair $comparisonA $comparisonB
    }) 'A same-condition comparison pair was accepted.'
    $comparisonB.condition = 'HalfGe256'
    $comparisonB.receipt.sampler.summarySha256 = $comparisonA.receipt.sampler.summarySha256
    Require (Test-ExpectedFailure {
        Assert-DistinctComparisonPair $comparisonA $comparisonB
    }) 'A comparison pair reusing sampler output was accepted.'
    $comparisonB.receipt.sampler.summarySha256 = '5' * 64
    $comparisonB.receipt.createdUtc = $comparisonA.receipt.createdUtc
    Require (Test-ExpectedFailure {
        Assert-DistinctComparisonPair $comparisonA $comparisonB
    }) 'A comparison pair with ambiguous creation time was accepted.'
    $comparisonB.receipt.createdUtc = '2026-09-07T02:00:00.0000000+00:00'
    Require ($script:DeviceInvocations -eq 0) `
        'Host SelfTest unexpectedly resolved or invoked ADB.'
    return [pscustomobject][ordered]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceInvocations = 0
        Package = $script:Package
        VersionName = $script:VersionName
        ApkSha256 = $script:ApkSha256
        CoreSha256 = $script:CoreSha256
        VeqSha256 = $script:VeqSha256
        ImmutableSamplerSha256 = $script:SamplerSha256
        Conditions = @($script:PackContracts.Keys)
        MinimumConditionMinutes = 30
        MultipleAndUnknownPackStatesRejected = $true
        MismatchedAndMidRunReloadsRejected = $true
        PhysicalNonVanillaHashRequired = $true
        FreshExactLatestLogRequired = $true
        BlocksAtlasParsedAtBothFences = $true
        MissingAmbiguousOrMalformedAtlasRejected = $true
        AtlasDimensionsAreObservedNotInferred = $true
        SamplerTamperCasesRejected = $true
        HalfGe256IdentityAndCompareFixturesPassed = $true
        ReusedOrSameConditionCompareRejected = $true
        ReceiptTamperCasesRejected = $true
        WrapperInvokesSampler = $false
        DeviceMutationCapability = $false
        RawLatestLogPersisted = $false
        AccountWorldOrServerDataPersisted = $false
    }
}

if ($Action -ceq 'SelfTest') {
    Invoke-SelfTest
    return
}

Assert-HostContract

if ($Action -ceq 'Begin') {
    Require $AllowDeviceRead.IsPresent 'Begin requires explicit -AllowDeviceRead.'
    $outputFull = Resolve-EvidencePath $OutputDirectory 'condition output directory' `
        -AllowDirectory
    Require (-not (Test-Path -LiteralPath $outputFull)) `
        'Begin requires a new output directory; refusing reuse.'
    $parent = Split-Path -Parent $outputFull
    Require (Test-Path -LiteralPath $parent -PathType Container) `
        'The condition output parent directory is missing.'
    Assert-NoReparsePoint -Path $parent -Root $script:RepoRoot
    Resolve-Device
    $fence = Get-ConditionFence $Condition
    [IO.Directory]::CreateDirectory($outputFull) | Out-Null
    $receiptPath = Join-Path $outputFull 'condition-start.json'
    $receipt = New-StartReceipt $Condition $fence
    $sha256 = Write-NewJsonFile $receiptPath $receipt 'condition start receipt'
    [pscustomobject][ordered]@{
        Result = 'PASS'
        Action = 'Begin'
        Condition = $Condition
        StartReceipt = ConvertTo-RepoRelativePath $receiptPath
        StartReceiptSha256 = $sha256
        DeviceInvocations = $script:DeviceInvocations
        DeviceMutations = 0
        NextStep = 'Run the immutable RC6.2 sampler separately for at least 30 minutes, then Finalize.'
    }
    return
}

if ($Action -ceq 'Finalize') {
    Require $AllowDeviceRead.IsPresent 'Finalize requires explicit -AllowDeviceRead.'
    $outputFull = Resolve-EvidencePath $OutputDirectory 'condition output directory' `
        -MustExist -AllowDirectory
    $startPath = Join-Path $outputFull 'condition-start.json'
    $startLock = Enter-LockedUtf8File $startPath 'condition start receipt' 2MB
    try {
        $startReceipt = ConvertFrom-StrictJsonText $startLock.Text 'condition start receipt'
        Assert-StartReceipt $startReceipt $Condition
        $sampler = Read-SamplerOutputs $SamplerSummaryPath $SamplerSamplesPath
        $resourceStartIndex = [int]$startReceipt.latestLog.resourceManagerLineCount
        Resolve-Device
        $endFence = Get-ConditionFence -ExpectedCondition $Condition `
            -ExpectedLogInode ([uint64]$startReceipt.latestLog.fileInode) `
            -MinimumLogSizeBytes ([int64]$startReceipt.latestLog.sizeBytes) `
            -ResourceManagerStartIndex $resourceStartIndex
        Assert-ConditionRunBinding $startReceipt $sampler $endFence $Condition
        $receipt = New-ConditionReceiptObject -ExpectedCondition $Condition `
            -StartReceipt $startReceipt -StartReceiptPath $startPath `
            -StartReceiptSha256 ([string]$startLock.Sha256) -Sampler $sampler `
            -EndFence $endFence
        $receiptPath = Join-Path $outputFull 'resource-pack-condition.json'
        $sha256 = Write-NewJsonFile $receiptPath $receipt 'condition-bound receipt'
        [pscustomobject][ordered]@{
            Result = 'PASS_CONDITION_BOUND'
            Action = 'Finalize'
            Condition = $Condition
            Receipt = ConvertTo-RepoRelativePath $receiptPath
            ReceiptSha256 = $sha256
            FormalSamplerResult = [string]$sampler.validation.formalSamplerResult
            DeviceInvocations = $script:DeviceInvocations
            DeviceMutations = 0
            StablePromotionAuthorized = $false
        }
    } finally {
        $startLock.Stream.Dispose()
    }
    return
}

if ($Action -ceq 'Compare') {
    $a = Read-ConditionReceiptFile $ReceiptAPath 'condition A receipt'
    $b = Read-ConditionReceiptFile $ReceiptBPath 'condition B receipt'
    Assert-DistinctComparisonPair $a $b
    $outputFull = Resolve-EvidencePath $OutputDirectory 'comparison output directory' `
        -AllowDirectory
    Require (-not (Test-Path -LiteralPath $outputFull)) `
        'Compare requires a new output directory; refusing reuse.'
    $parent = Split-Path -Parent $outputFull
    Require (Test-Path -LiteralPath $parent -PathType Container) `
        'Comparison output parent directory is missing.'
    Assert-NoReparsePoint -Path $parent -Root $script:RepoRoot
    [IO.Directory]::CreateDirectory($outputFull) | Out-Null
    $comparison = New-ComparisonReceiptObject $a $b
    $path = Join-Path $outputFull 'resource-pack-memory-ab.json'
    $sha256 = Write-NewJsonFile $path $comparison 'A/B comparison receipt'
    [pscustomobject][ordered]@{
        Result = 'PASS_DISTINCT_CONDITIONS_BOUND'
        Action = 'Compare'
        A = $a.condition
        B = $b.condition
        Receipt = ConvertTo-RepoRelativePath $path
        ReceiptSha256 = $sha256
        DeviceInvocations = 0
        DeviceMutations = 0
        CausalMemoryClaimMade = $false
        StablePromotionAuthorized = $false
    }
    return
}

throw '[V71_RC6_2_PACK_MEMORY_AB] Unsupported action.'
