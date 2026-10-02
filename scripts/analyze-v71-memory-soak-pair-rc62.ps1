#requires -Version 7.0
<#
.SYNOPSIS
Performs a Host-only supplementary growth analysis of two completed RC6.2
memory soaks.

.DESCRIPTION
This postprocessor reads two summary.json/samples.jsonl pairs without changing
them. It authenticates the fixed RC6.2 locks and sampler, validates both
runtime bindings and sample streams, preserves each producer's original gate
result, and independently recomputes memory slopes and last-30-minute growth.

LEAK_STABILITY_PASS is supplementary evidence only. It neither overrides the
producer's absolute 2.4 GiB gate nor represents manual visual acceptance or
authority to promote or install any Stable build. This script has no device
command path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $FirstSummaryPath,

    [Parameter(Mandatory)]
    [string] $FirstSamplesPath,

    [Parameter(Mandatory)]
    [string] $SecondSummaryPath,

    [Parameter(Mandatory)]
    [string] $SecondSamplesPath,

    [string] $OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ErrorPrefix = '[V71_RC6_2_MEMORY_PAIR]'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:AbsoluteLimitMib = 2457.6 # 2.4 GiB, expressed in MiB.
$script:SupplementarySlopeLimit = 2.0
$script:SupplementaryLastThirtyLimitMib = 128.0
$script:SupplementaryMinMemAvailableMib = 1024.0
$script:SupplementaryMaxProcessSwapMib = 512.0
$script:MetricDefinitions = @(
    [pscustomobject]@{ Name = 'pss'; SourceField = 'totalPssKib' },
    [pscustomobject]@{ Name = 'vmRss'; SourceField = 'vmRssKib' },
    [pscustomobject]@{ Name = 'graphics'; SourceField = 'graphicsKib' },
    [pscustomobject]@{ Name = 'nativeHeap'; SourceField = 'nativeHeapKib' },
    [pscustomobject]@{ Name = 'javaHeap'; SourceField = 'javaHeapKib' },
    [pscustomobject]@{ Name = 'memAvailable'; SourceField = 'memAvailableKib' },
    [pscustomobject]@{ Name = 'processSwap'; SourceField = 'vmSwapKib' },
    [pscustomobject]@{ Name = 'systemSwapFree'; SourceField = 'swapFreeKib' }
)

function Fail([Parameter(Mandatory)][string] $Message) {
    throw "$($script:ErrorPrefix) $Message"
}

function Require([bool] $Condition, [Parameter(Mandatory)][string] $Message) {
    if (-not $Condition) { Fail $Message }
}

function Get-RequiredProperty(
    [Parameter(Mandatory)][object] $Object,
    [Parameter(Mandatory)][string] $Name,
    [Parameter(Mandatory)][string] $Context,
    [switch] $AllowNull
) {
    $property = $Object.PSObject.Properties[$Name]
    Require ($null -ne $property) "$Context is missing '$Name'."
    if (-not $AllowNull) {
        Require ($null -ne $property.Value) "$Context has null '$Name'."
    }
    return $property.Value
}

function Get-ExactBoolean(
    [AllowNull()][object] $Value,
    [Parameter(Mandatory)][string] $Context
) {
    Require ($Value -is [bool]) "$Context must be a JSON boolean."
    return [bool]$Value
}

function Test-ExactTrue([AllowNull()][object] $Value) {
    return $Value -is [bool] -and [bool]$Value
}

function Test-ExactFalse([AllowNull()][object] $Value) {
    return $Value -is [bool] -and -not [bool]$Value
}

function Test-NumericType([AllowNull()][object] $Value) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
        return $false
    }
    $typeCode = [Type]::GetTypeCode($Value.GetType())
    return $typeCode -in @(
        [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16,
        [TypeCode]::UInt16, [TypeCode]::Int32, [TypeCode]::UInt32,
        [TypeCode]::Int64, [TypeCode]::UInt64, [TypeCode]::Single,
        [TypeCode]::Double, [TypeCode]::Decimal)
}

function Get-FiniteNumber(
    [AllowNull()][object] $Value,
    [Parameter(Mandatory)][string] $Context
) {
    Require (Test-NumericType $Value) "$Context must be a JSON number."
    $number = [double]$Value
    Require (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) `
        "$Context must be finite."
    return $number
}

function Get-ExactInteger(
    [AllowNull()][object] $Value,
    [Parameter(Mandatory)][string] $Context,
    [int64] $Minimum = [int64]::MinValue,
    [int64] $Maximum = [int64]::MaxValue
) {
    $number = Get-FiniteNumber $Value $Context
    Require ([math]::Truncate($number) -eq $number) "$Context must be an integer."
    Require ($number -ge $Minimum -and $number -le $Maximum) `
        "$Context is outside its allowed range."
    return [int64]$number
}

function Get-ExactString(
    [AllowNull()][object] $Value,
    [Parameter(Mandatory)][string] $Context,
    [switch] $AllowEmpty
) {
    Require ($Value -is [string]) "$Context must be a JSON string."
    if (-not $AllowEmpty) {
        Require (-not [string]::IsNullOrWhiteSpace([string]$Value)) `
            "$Context must not be empty."
    }
    return [string]$Value
}

function Get-ExactSha256(
    [AllowNull()][object] $Value,
    [Parameter(Mandatory)][string] $Context
) {
    $sha = Get-ExactString $Value $Context
    Require ($sha -cmatch '^[0-9A-F]{64}$') `
        "$Context must be an uppercase SHA-256 digest."
    return $sha
}

function Get-UtcTimestamp(
    [AllowNull()][object] $Value,
    [Parameter(Mandatory)][string] $Context
) {
    $text = Get-ExactString $Value $Context
    Require ($text.EndsWith('Z', [StringComparison]::Ordinal)) `
        "$Context must use an explicit UTC Z suffix."
    $parsed = [DateTimeOffset]::MinValue
    $ok = [DateTimeOffset]::TryParse(
        $text,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed)
    Require ($ok -and $parsed.Offset -eq [TimeSpan]::Zero) `
        "$Context is not a valid UTC timestamp."
    return $parsed
}

function Assert-RoundedEqual(
    [AllowNull()][object] $Reported,
    [double] $Recomputed,
    [Parameter(Mandatory)][string] $Context
) {
    $reportedNumber = Get-FiniteNumber $Reported $Context
    Require ([math]::Abs($reportedNumber - $Recomputed) -le 0.0005) `
        "$Context does not match the raw samples (reported=$reportedNumber, recomputed=$Recomputed)."
}

function Get-NormalizedTextSha256([Parameter(Mandatory)][string] $Text) {
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($normalized)))
}

function Open-ReadSnapshot(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Context,
    [int64] $MaximumBytes
) {
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        Fail "$Context does not resolve to a file."
    }
    $item = Get-Item -LiteralPath $resolved -Force
    Require (-not $item.PSIsContainer) "$Context is not a file."
    Require (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        "$Context must not be a reparse point."
    Require ($item.Length -gt 0 -and $item.Length -le $MaximumBytes) `
        "$Context has an invalid or excessive length."

    # FileShare.Read permits other auditors but excludes writers and deletion
    # for the full analysis. An in-progress producer therefore cannot be
    # mistaken for an immutable completed input.
    $stream = [IO.File]::Open(
        $resolved,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        Require ($stream.Length -eq $item.Length) "$Context changed before its read lock was acquired."
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
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        } catch {
            Fail "$Context is not strict UTF-8."
        }
        return [pscustomobject]@{
            ResolvedPath = $resolved
            Length = [int64]$bytes.Length
            Sha256 = [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($bytes))
            Text = $text
            ReadLock = $stream
        }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Read-JsonObject(
    [Parameter(Mandatory)][string] $Text,
    [Parameter(Mandatory)][string] $Context
) {
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Text)
        Assert-NoDuplicateJsonProperties $document.RootElement $Context
        Require ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) `
            "$Context must contain one JSON object."
    } catch {
        if ($_.Exception.Message.StartsWith($script:ErrorPrefix, [StringComparison]::Ordinal)) {
            throw
        }
        Fail "$Context is not strict JSON."
    } finally {
        if ($null -ne $document) { $document.Dispose() }
    }
    try {
        $value = $Text | ConvertFrom-Json -Depth 40 -DateKind String
    } catch {
        Fail "$Context is not valid JSON."
    }
    Require ($value -is [pscustomobject]) "$Context must contain one JSON object."
    return $value
}

function Assert-NoDuplicateJsonProperties(
    [Parameter(Mandatory)][Text.Json.JsonElement] $Element,
    [Parameter(Mandatory)][string] $Context
) {
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            Require ($names.Add($property.Name)) `
                "$Context contains duplicate JSON property '$($property.Name)'."
            Assert-NoDuplicateJsonProperties $property.Value `
                "$Context.$($property.Name)"
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties $item "$Context[$index]"
            $index++
        }
    }
}

function Assert-ExactCandidateLocks(
    [Parameter(Mandatory)][object] $BuildLock,
    [Parameter(Mandatory)][object] $EvidenceLock,
    [Parameter(Mandatory)][object] $SamplerSnapshot,
    [Parameter(Mandatory)][string] $BuildLockSha256,
    [Parameter(Mandatory)][string] $EvidenceLockSha256
) {
    Require ((Get-ExactInteger (Get-RequiredProperty $BuildLock 'schemaVersion' 'build lock') `
                'build lock schemaVersion') -eq 1) 'The build-lock schema drifted.'
    Require (Test-ExactTrue (Get-RequiredProperty $BuildLock 'immutable' 'build lock')) `
        'The RC6.2 build lock is not immutable.'
    Require ((Get-ExactInteger (Get-RequiredProperty $EvidenceLock 'schemaVersion' 'producer lock') `
                'producer lock schemaVersion') -eq 1) 'The producer-lock schema drifted.'
    Require (Test-ExactTrue (Get-RequiredProperty $EvidenceLock 'immutable' 'producer lock')) `
        'The RC6.2 producer lock is not immutable.'
    Require ((Get-ExactString (Get-RequiredProperty $EvidenceLock 'candidateBuildLockPath' `
                'producer lock') 'producer lock candidateBuildLockPath') -ceq
            'V71_LAB_RC6_2.lock.json') 'The producer lock names another candidate lock.'
    Require ((Get-ExactString (Get-RequiredProperty $EvidenceLock 'scriptHashScheme' `
                'producer lock') 'producer lock scriptHashScheme') -ceq
            'sha256-utf8-normalized-lf') 'The producer hash scheme drifted.'

    $target = Get-RequiredProperty $BuildLock 'target' 'build lock'
    $pair = Get-RequiredProperty $BuildLock 'pair' 'build lock'
    $core = Get-RequiredProperty $pair 'core' 'build lock pair'
    $veq = Get-RequiredProperty $pair 'veq' 'build lock pair'
    $pojlib = Get-RequiredProperty $BuildLock 'pojlibAar' 'build lock'
    $runtimeBinding = Get-RequiredProperty $BuildLock 'runtimeBinding' 'build lock'
    $runtimeIdentity = Get-RequiredProperty $EvidenceLock 'runtimeIdentity' 'producer lock'
    $producers = Get-RequiredProperty $EvidenceLock 'producers' 'producer lock'
    $memoryPolicy = Get-RequiredProperty $EvidenceLock 'memoryPolicy' 'producer lock'
    $thermalSafety = Get-RequiredProperty $EvidenceLock 'thermalSafety' 'producer lock'

    $expected = [ordered]@{
        Package = 'com.qcxr.qcxr.canary262'
        StablePackage = 'com.qcxr.qcxr.dev262'
        Profile = '26.2'
        VersionCode = 71
        VersionName = '6.0.1-26.2-vivecraft-personal.12-rc.6.2'
        ApkSha256 = 'ED810E5ABB7AD3A7B0D6303D08DEB813FCB5F4C9EE7BD6B85D298F67420FA3D4'
        ApkSizeBytes = 128459705
        CoreVersion = '26.2-1.3.15+qc.v71.rc6.2'
        CoreSha256 = '6449A62588FA944BA238F87178C43EE00BD10E3B223459606B4C002B7F2360AF'
        VeqVersion = '0.7.0-v71.rc6'
        VeqSha256 = 'BF7857E4212B18601D6E165A5453CAF325BC3AB8EB1D093A324D6AA8C20F70FD'
        PojlibSha256 = '6B9224C6697D00DCE363AD80EA5FA9946E90808C514517BA4EEDFEB31DB2BA89'
        SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
        MemorySoakProducerSha256 =
            '75F5D720A3FC6396109D6D96820F2F75AE8A8327F317A41AE811CBBF781CD433'
    }

    Require ((Get-ExactString (Get-RequiredProperty $target 'package' 'build target') `
                'build target package') -ceq $expected.Package -and
        (Get-ExactString (Get-RequiredProperty $target 'forbiddenStablePackage' 'build target') `
                'build target forbiddenStablePackage') -ceq $expected.StablePackage -and
        (Get-ExactString (Get-RequiredProperty $target 'profile' 'build target') `
                'build target profile') -ceq $expected.Profile -and
        (Get-ExactInteger (Get-RequiredProperty $target 'versionCode' 'build target') `
                'build target versionCode') -eq $expected.VersionCode -and
        (Get-ExactString (Get-RequiredProperty $target 'versionName' 'build target') `
                'build target versionName') -ceq $expected.VersionName -and
        (Get-ExactSha256 (Get-RequiredProperty $target 'apkSha256' 'build target') `
                'build target apkSha256') -ceq $expected.ApkSha256 -and
        (Get-ExactInteger (Get-RequiredProperty $target 'apkSizeBytes' 'build target') `
                'build target apkSizeBytes' 1) -eq $expected.ApkSizeBytes -and
        (Get-ExactSha256 (Get-RequiredProperty $target 'signerSha256' 'build target') `
                'build target signerSha256') -ceq $expected.SignerSha256) `
        'The fixed RC6.2 build identity drifted.'

    Require ((Get-ExactString (Get-RequiredProperty $core 'fabricVersion' 'build Core') `
                'build Core fabricVersion') -ceq $expected.CoreVersion -and
        (Get-ExactSha256 (Get-RequiredProperty $core 'sha256' 'build Core') `
                'build Core sha256') -ceq $expected.CoreSha256 -and
        (Get-ExactString (Get-RequiredProperty $veq 'fabricVersion' 'build VEQ') `
                'build VEQ fabricVersion') -ceq $expected.VeqVersion -and
        (Get-ExactSha256 (Get-RequiredProperty $veq 'sha256' 'build VEQ') `
                'build VEQ sha256') -ceq $expected.VeqSha256 -and
        (Get-ExactSha256 (Get-RequiredProperty $pojlib 'sha256' 'build Pojlib') `
                'build Pojlib sha256') -ceq $expected.PojlibSha256) `
        'The fixed RC6.2 payload identity drifted.'

    $pairText = "core=$($expected.CoreSha256)`nveq=$($expected.VeqSha256)`n"
    $pairSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($pairText)))
    Require ((Get-ExactSha256 (Get-RequiredProperty $pair 'sha256' 'build pair') `
                'build pair sha256') -ceq $pairSha256) 'The Core/VEQ pair digest is invalid.'

    $identityChecks = @(
        @('package', $expected.Package),
        @('forbiddenStablePackage', $expected.StablePackage),
        @('profile', $expected.Profile),
        @('versionName', $expected.VersionName),
        @('apkSha256', $expected.ApkSha256),
        @('coreVersion', $expected.CoreVersion),
        @('coreSha256', $expected.CoreSha256),
        @('veqVersion', $expected.VeqVersion),
        @('veqSha256', $expected.VeqSha256),
        @('pojlibAarSha256', $expected.PojlibSha256),
        @('signerSha256', $expected.SignerSha256)
    )
    foreach ($check in $identityChecks) {
        $actual = Get-ExactString (Get-RequiredProperty $runtimeIdentity $check[0] `
                'producer runtimeIdentity') "producer runtimeIdentity $($check[0])"
        Require ($actual -ceq [string]$check[1]) `
            "The producer runtime identity drifted at '$($check[0])'."
    }
    Require ((Get-ExactInteger (Get-RequiredProperty $runtimeIdentity 'versionCode' `
                'producer runtimeIdentity') 'producer runtimeIdentity versionCode') -eq
            $expected.VersionCode) 'The producer versionCode drifted.'

    Require ((Get-ExactString (Get-RequiredProperty $runtimeBinding `
                'expectedGameLogRelativePath' 'build runtimeBinding') `
                'build runtimeBinding expectedGameLogRelativePath') -ceq
            'instances/26.2/logs/latest.log' -and
        (Get-ExactString (Get-RequiredProperty $runtimeBinding `
                'expectedGameLogMinecraftVersion' 'build runtimeBinding') `
                'build runtimeBinding expectedGameLogMinecraftVersion') -ceq '26.2' -and
        (Get-ExactString (Get-RequiredProperty $runtimeBinding `
                'expectedGameLogCoreVersion' 'build runtimeBinding') `
                'build runtimeBinding expectedGameLogCoreVersion') -ceq $expected.CoreVersion -and
        (Get-ExactString (Get-RequiredProperty $runtimeBinding `
                'expectedGameLogVeqVersion' 'build runtimeBinding') `
                'build runtimeBinding expectedGameLogVeqVersion') -ceq $expected.VeqVersion) `
        'The expected game-log binding drifted.'

    Require ((Get-ExactInteger (Get-RequiredProperty $memoryPolicy 'requiredSoakCount' `
                'producer memoryPolicy') 'producer requiredSoakCount') -eq 2 -and
        (Get-ExactInteger (Get-RequiredProperty $memoryPolicy 'minutesPerSoak' `
                'producer memoryPolicy') 'producer minutesPerSoak') -eq 90 -and
        (Get-ExactInteger (Get-RequiredProperty $memoryPolicy 'sampleIntervalSeconds' `
                'producer memoryPolicy') 'producer sampleIntervalSeconds') -eq 300 -and
        (Get-FiniteNumber (Get-RequiredProperty $memoryPolicy 'maxPssMiB' `
                'producer memoryPolicy') 'producer maxPssMiB') -eq $script:AbsoluteLimitMib -and
        (Get-FiniteNumber (Get-RequiredProperty $memoryPolicy 'maxRssMiB' `
                'producer memoryPolicy') 'producer maxRssMiB') -eq $script:AbsoluteLimitMib -and
        (Get-FiniteNumber (Get-RequiredProperty $memoryPolicy 'maxProcessSwapMiB' `
                'producer memoryPolicy') 'producer maxProcessSwapMiB') -eq
            $script:SupplementaryMaxProcessSwapMib -and
        (Get-FiniteNumber (Get-RequiredProperty $memoryPolicy `
                'maxPostWarmGrowthMiBPerMinute' 'producer memoryPolicy') `
                'producer maxPostWarmGrowthMiBPerMinute') -eq
            $script:SupplementarySlopeLimit -and
        (Get-FiniteNumber (Get-RequiredProperty $memoryPolicy `
                'maxLastThirtyMinutesGrowthMiB' 'producer memoryPolicy') `
                'producer maxLastThirtyMinutesGrowthMiB') -eq
            $script:SupplementaryLastThirtyLimitMib) `
        'The fixed RC6.2 memory protocol drifted.'

    Require ((Get-FiniteNumber (Get-RequiredProperty $thermalSafety `
                'defaultMaxBatteryTemperatureC' 'producer thermalSafety') `
                'defaultMaxBatteryTemperatureC') -eq 47.0 -and
        (Get-ExactInteger (Get-RequiredProperty $thermalSafety 'defaultMaxThermalStatus' `
                'producer thermalSafety') 'defaultMaxThermalStatus') -eq 2 -and
        (Get-FiniteNumber (Get-RequiredProperty $thermalSafety `
                'maximumConfigurableBatteryTemperatureC' 'producer thermalSafety') `
                'maximumConfigurableBatteryTemperatureC') -eq 50.0 -and
        (Get-ExactInteger (Get-RequiredProperty $thermalSafety `
                'maximumConfigurableThermalStatus' 'producer thermalSafety') `
                'maximumConfigurableThermalStatus') -eq 3) `
        'The RC6.2 thermal contract drifted.'

    Require ((Get-ExactString (Get-RequiredProperty $producers 'memorySoakPath' `
                'producer paths') 'producer memorySoakPath') -ceq
            'scripts/quest-v71-memory-soak-rc62.ps1') `
        'The producer lock points at another sampler.'
    $producerSha256 = Get-ExactSha256 (Get-RequiredProperty $producers `
        'memorySoakScriptSha256' 'producer paths') 'producer memorySoakScriptSha256'
    Require ($producerSha256 -ceq $expected.MemorySoakProducerSha256 -and
        (Get-NormalizedTextSha256 $SamplerSnapshot.Text) -ceq
            $expected.MemorySoakProducerSha256) `
        'The checked-in RC6.2 sampler no longer matches its producer lock.'

    return [pscustomobject][ordered]@{
        package = $expected.Package
        forbiddenStablePackage = $expected.StablePackage
        profile = $expected.Profile
        versionCode = $expected.VersionCode
        versionName = $expected.VersionName
        apkSha256 = $expected.ApkSha256
        apkSizeBytes = $expected.ApkSizeBytes
        coreVersion = $expected.CoreVersion
        coreSha256 = $expected.CoreSha256
        veqVersion = $expected.VeqVersion
        veqSha256 = $expected.VeqSha256
        pojlibAarSha256 = $expected.PojlibSha256
        signerSha256 = $expected.SignerSha256
        memorySoakProducerSha256 = $producerSha256
        buildLockSha256 = $BuildLockSha256
        producerLockSha256 = $EvidenceLockSha256
        locksAndSamplerMatched = $true
    }
}

function Assert-ProvenanceReceipt(
    [Parameter(Mandatory)][object] $Receipt,
    [Parameter(Mandatory)][string] $Context
) {
    Require ((Get-ExactInteger (Get-RequiredProperty $Receipt 'schemaVersion' $Context) `
                "$Context schemaVersion") -eq 1) "$Context schemaVersion drifted."
    $null = Get-UtcTimestamp (Get-RequiredProperty $Receipt 'verifiedUtc' $Context) `
        "$Context verifiedUtc"
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        Require (Test-ExactTrue (Get-RequiredProperty $Receipt $field $Context)) `
            "$Context did not prove '$field'."
    }
}

function Assert-ExpectedGameLogReceipt(
    [Parameter(Mandatory)][object] $Receipt,
    [Parameter(Mandatory)][string] $Context,
    [double] $ProcessStartEpochSeconds
) {
    foreach ($field in @(
            'expectedGameLogPathMatched',
            'expectedGameLogRegularAndNonEmpty',
            'expectedGameLogSameFile',
            'expectedGameLogTemporallyBoundToProcess',
            'expectedGameLogFresh',
            'expectedMinecraftVersionObserved',
            'expectedVivecraftVersionObserved',
            'expectedVeqVersionObserved')) {
        Require (Test-ExactTrue (Get-RequiredProperty $Receipt $field $Context)) `
            "$Context did not prove '$field'."
    }
    $modified = Get-ExactInteger (Get-RequiredProperty $Receipt `
        'expectedGameLogModifiedEpochSeconds' $Context) `
        "$Context expectedGameLogModifiedEpochSeconds" 1
    $observed = Get-ExactInteger (Get-RequiredProperty $Receipt `
        'expectedGameLogObservedDeviceEpochSeconds' $Context) `
        "$Context expectedGameLogObservedDeviceEpochSeconds" 1
    Require ($modified -ge [math]::Floor($ProcessStartEpochSeconds - 2.0) -and
        $modified -ge ($observed - 60) -and $modified -le ($observed + 2)) `
        "$Context expected-game-log timestamps are detached or stale."
    return [pscustomobject]@{ ModifiedEpoch = $modified; ObservedEpoch = $observed }
}

function Assert-RuntimeBinding(
    [Parameter(Mandatory)][object] $Binding,
    [int] $ExpectedPid,
    [Parameter(Mandatory)][string] $ExpectedProducerSha256,
    [Parameter(Mandatory)][DateTimeOffset] $SummaryStartedUtc,
    [Parameter(Mandatory)][string] $Context
) {
    Require ((Get-ExactInteger (Get-RequiredProperty $Binding 'schemaVersion' $Context) `
                "$Context schemaVersion") -eq 1) "$Context schemaVersion drifted."
    Require ((Get-ExactString (Get-RequiredProperty $Binding 'receiptType' $Context) `
                "$Context receiptType") -ceq
            'V71_RC6_2_MEMORY_SOAK_RUNTIME_BINDING' -and
        (Get-ExactString (Get-RequiredProperty $Binding 'result' $Context) `
                "$Context result") -ceq 'PASS') `
        "$Context is not an RC6.2 PASS binding."

    $start = Get-RequiredProperty $Binding 'start' $Context
    $final = Get-RequiredProperty $Binding 'final' $Context
    $startContext = "$Context start"
    $finalContext = "$Context final"
    Require ((Get-ExactInteger (Get-RequiredProperty $start 'schemaVersion' $startContext) `
                "$startContext schemaVersion") -eq 1 -and
        (Get-ExactString (Get-RequiredProperty $start 'receiptType' $startContext) `
                "$startContext receiptType") -ceq
            'V71_RC6_2_MEMORY_SOAK_RUNTIME_START' -and
        (Get-ExactString (Get-RequiredProperty $start 'result' $startContext) `
                "$startContext result") -ceq 'PASS') `
        "$startContext is not the exact start receipt."
    Require ((Get-ExactInteger (Get-RequiredProperty $final 'schemaVersion' $finalContext) `
                "$finalContext schemaVersion") -eq 1 -and
        (Get-ExactString (Get-RequiredProperty $final 'receiptType' $finalContext) `
                "$finalContext receiptType") -ceq
            'V71_RC6_2_MEMORY_SOAK_RUNTIME_FINAL' -and
        (Get-ExactString (Get-RequiredProperty $final 'result' $finalContext) `
                "$finalContext result") -ceq 'PASS') `
        "$finalContext is not the exact final receipt."

    $startPid = Get-ExactInteger (Get-RequiredProperty $start 'pid' $startContext) `
        "$startContext pid" 1 ([int]::MaxValue)
    $finalPid = Get-ExactInteger (Get-RequiredProperty $final 'pid' $finalContext) `
        "$finalContext pid" 1 ([int]::MaxValue)
    $startTicks = Get-ExactInteger (Get-RequiredProperty $start 'processStartTicks' `
        $startContext) "$startContext processStartTicks" 1
    $finalTicks = Get-ExactInteger (Get-RequiredProperty $final 'processStartTicks' `
        $finalContext) "$finalContext processStartTicks" 1
    Require ($startPid -eq $ExpectedPid -and $finalPid -eq $ExpectedPid -and
        $startTicks -eq $finalTicks) `
        "$Context is not bound to the summary's one process incarnation."

    $startProducer = Get-ExactSha256 (Get-RequiredProperty $start 'producerSha256' `
        $startContext) "$startContext producerSha256"
    Require ($startProducer -ceq $ExpectedProducerSha256) `
        "$startContext producer hash drifted."
    $startObserved = Get-UtcTimestamp (Get-RequiredProperty $start 'observedUtc' `
        $startContext) "$startContext observedUtc"
    $finalObserved = Get-UtcTimestamp (Get-RequiredProperty $final 'observedUtc' `
        $finalContext) "$finalContext observedUtc"
    Require ($startObserved -ge $SummaryStartedUtc -and $finalObserved -gt $startObserved) `
        "$Context receipt timestamps are not ordered."

    $startEpoch = Get-FiniteNumber (Get-RequiredProperty $start `
        'processStartEpochSeconds' $startContext) "$startContext processStartEpochSeconds"
    $finalEpoch = Get-FiniteNumber (Get-RequiredProperty $final `
        'processStartEpochSeconds' $finalContext) "$finalContext processStartEpochSeconds"
    Require ($startEpoch -gt 0 -and [math]::Abs($finalEpoch - $startEpoch) -le 2.0) `
        "$Context process-start epochs identify another incarnation."

    foreach ($field in @('exactPidAlive', 'gameJvmAlive', 'provenanceMatched',
            'exactJvmMemoryLineObserved', 'launcherLogTemporallyBoundToProcess',
            'launcherResourceReleaseAppliedObserved',
            'launcherMarkerTemporallyBoundToProcess',
            'runtimeFenceBeforeStartProvenance', 'runtimeFenceAfterStartProvenance')) {
        Require (Test-ExactTrue (Get-RequiredProperty $start $field $startContext)) `
            "$startContext did not prove '$field'."
    }
    Require ((Get-ExactInteger (Get-RequiredProperty $start 'xmsMiB' $startContext) `
                "$startContext xmsMiB") -eq 512 -and
        (Get-ExactInteger (Get-RequiredProperty $start 'xmxMiB' $startContext) `
                "$startContext xmxMiB") -eq 1536 -and
        (Get-ExactString (Get-RequiredProperty $start 'xmxSource' $startContext) `
                "$startContext xmxSource") -ceq 'auto' -and
        (Get-ExactInteger (Get-RequiredProperty $start 'jvmMemoryLineCount' $startContext) `
                "$startContext jvmMemoryLineCount") -eq 1 -and
        (Get-ExactInteger (Get-RequiredProperty $start 'launcherLogSizeBytes' $startContext) `
                "$startContext launcherLogSizeBytes" 1) -gt 0) `
        "$startContext did not prove the bounded JVM policy."
    $launcherLogEpoch = Get-ExactInteger (Get-RequiredProperty $start `
        'launcherLogModifiedEpochSeconds' $startContext) `
        "$startContext launcherLogModifiedEpochSeconds" 1
    $appliedCount = Get-ExactInteger (Get-RequiredProperty $start `
        'launcherReleaseAppliedMarkerCount' $startContext) `
        "$startContext launcherReleaseAppliedMarkerCount" 1
    $degradedCount = Get-ExactInteger (Get-RequiredProperty $start `
        'launcherReleaseDegradedMarkerCount' $startContext) `
        "$startContext launcherReleaseDegradedMarkerCount" 0
    $markerEpoch = Get-FiniteNumber (Get-RequiredProperty $start `
        'launcherAppliedMarkerEpochSeconds' $startContext) `
        "$startContext launcherAppliedMarkerEpochSeconds"
    Require ($appliedCount -ge 1 -and $degradedCount -eq 0 -and
        $launcherLogEpoch -ge [math]::Floor($startEpoch - 3.0) -and
        $markerEpoch -ge ($startEpoch - 3.0)) `
        "$startContext launcher evidence is detached or degraded."
    $null = Assert-ExpectedGameLogReceipt $start $startContext $startEpoch

    foreach ($field in @('sameProcessIncarnation', 'exactPidAlive', 'gameJvmAlive',
            'provenanceMatched', 'startJvmMemoryObservationCarriedForward',
            'startLauncherMarkerCarriedForward', 'runtimeFenceBeforeFinalProvenance',
            'runtimeFenceAfterFinalProvenance')) {
        Require (Test-ExactTrue (Get-RequiredProperty $final $field $finalContext)) `
            "$finalContext did not prove '$field'."
    }
    Require (Test-ExactFalse (Get-RequiredProperty $final `
            'finalLogcatMarkerRequired' $finalContext)) `
        "$finalContext incorrectly requires a retained final marker."
    $null = Assert-ExpectedGameLogReceipt $final $finalContext $finalEpoch

    $boundary = Get-RequiredProperty $Binding 'evidenceBoundary' $Context
    foreach ($field in @(
            'logcatMarkerCapturedOnlyAtStart',
            'processStartTicksPersistedForPidReuseDefense',
            'processStartEpochPersistedForLogBinding',
            'producerHashCapturedAtLaunch',
            'producerFileReadLockedForRun',
            'launcherMarkerTemporallyBoundToProcess',
            'launcherLogTemporallyBoundToProcess',
            'expectedProfileGameLogPathFixed',
            'expectedGameLogIdentityCheckedAtStartAndFinal',
            'expectedGameLogFreshnessCheckedEverySample',
            'expectedGameLogEvidenceOnlyBooleansAndTimestamps',
            'gameJvmLivenessObservedAtBoundedFencesAndSamples')) {
        Require (Test-ExactTrue (Get-RequiredProperty $boundary $field `
                "$Context evidenceBoundary")) `
            "$Context evidenceBoundary did not prove '$field'."
    }
    foreach ($field in @('finalLogcatMarkerRequired',
            'continuousGameJvmLivenessClaimed', 'rawLogsPersisted',
            'logSnippetsPersisted', 'deviceSerialPersisted',
            'accountDataPersisted', 'hostAbsolutePathsPersisted')) {
        Require (Test-ExactFalse (Get-RequiredProperty $boundary $field `
                "$Context evidenceBoundary")) `
            "$Context evidenceBoundary did not keep '$field' false."
    }

    return [pscustomobject]@{
        Pid = [int]$startPid
        ProcessStartTicks = [int64]$startTicks
        ProcessStartEpochSeconds = $startEpoch
        StartObservedUtc = $startObserved
        FinalObservedUtc = $finalObserved
    }
}

function Get-RawSlopeMibPerMinute(
    [Parameter(Mandatory)][object[]] $Samples,
    [Parameter(Mandatory)][string] $Field,
    [Parameter(Mandatory)][string] $Context
) {
    Require ($Samples.Count -ge 2) "$Context needs at least two points."
    $meanX = ($Samples | Measure-Object elapsedMinutes -Average).Average
    $meanY = ($Samples | ForEach-Object { [double]$_.$Field / 1024.0 } |
        Measure-Object -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($sample in $Samples) {
        $dx = [double]$sample.elapsedMinutes - [double]$meanX
        $dy = ([double]$sample.$Field / 1024.0) - [double]$meanY
        $numerator += $dx * $dy
        $denominator += $dx * $dx
    }
    Require ($denominator -gt 0.0) "$Context has no elapsed-time span."
    return $numerator / $denominator
}

function Get-MetricAnalysis(
    [Parameter(Mandatory)][object[]] $Samples,
    [Parameter(Mandatory)][object[]] $PostWarm,
    [Parameter(Mandatory)][object[]] $LastThirty,
    [Parameter(Mandatory)][string] $Field,
    [Parameter(Mandatory)][string] $Context
) {
    $values = @($Samples | ForEach-Object { [double]$_.$Field / 1024.0 })
    $rawSlope = Get-RawSlopeMibPerMinute $PostWarm $Field "$Context post-warm slope"
    $rawGrowth = ([double]$LastThirty[-1].$Field -
        [double]$LastThirty[0].$Field) / 1024.0
    return [pscustomobject]@{
        Public = [pscustomobject][ordered]@{
            sourceField = $Field
            unit = 'MiB'
            firstMib = [math]::Round($values[0], 3)
            lastMib = [math]::Round($values[-1], 3)
            minimumMib = [math]::Round(($values | Measure-Object -Minimum).Minimum, 3)
            maximumMib = [math]::Round(($values | Measure-Object -Maximum).Maximum, 3)
            postWarmSlopeMibPerMinute = [math]::Round($rawSlope, 6)
            lastThirtyMinutesGrowthMib = [math]::Round($rawGrowth, 6)
        }
        RawSlope = $rawSlope
        RawLastThirtyGrowth = $rawGrowth
        RawMinimumMib = [double](($values | Measure-Object -Minimum).Minimum)
        RawMaximumMib = [double](($values | Measure-Object -Maximum).Maximum)
    }
}

function Read-SampleRows(
    [Parameter(Mandatory)][string] $Text,
    [int] $ExpectedCount,
    [int] $ExpectedPid,
    [Parameter(Mandatory)][DateTimeOffset] $StartedUtc,
    [double] $ConfiguredMaxBatteryTemperatureC,
    [int] $ConfiguredMaxThermalStatus,
    [Parameter(Mandatory)][string] $Context
) {
    $split = @([regex]::Split($Text, "`r`n|`n|`r"))
    if ($split.Count -gt 0 -and $split[-1].Length -eq 0) {
        $split = @($split | Select-Object -First ($split.Count - 1))
    }
    Require ($split.Count -eq $ExpectedCount) `
        "$Context contains $($split.Count) rows; expected exactly $ExpectedCount."
    Require (@($split | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) `
        "$Context contains a blank JSONL row."

    $memoryFields = @(
        'totalPssKib', 'totalRssKib', 'javaHeapKib', 'nativeHeapKib',
        'graphicsKib', 'vmRssKib', 'vmSwapKib', 'memAvailableKib',
        'swapFreeKib')
    $samples = [Collections.Generic.List[object]]::new()
    $previousElapsed = -1.0
    $previousTimestamp = [DateTimeOffset]::MinValue

    for ($index = 0; $index -lt $split.Count; $index++) {
        $rowContext = "$Context row $($index + 1)"
        $raw = Read-JsonObject ([string]$split[$index]) $rowContext
        $timestamp = Get-UtcTimestamp (Get-RequiredProperty $raw 'timestampUtc' $rowContext) `
            "$rowContext timestampUtc"
        $elapsed = Get-FiniteNumber (Get-RequiredProperty $raw 'elapsedMinutes' $rowContext) `
            "$rowContext elapsedMinutes"
        Require ($elapsed -ge 0.0) "$rowContext elapsedMinutes is negative."
        Require ([math]::Abs((($timestamp - $StartedUtc).TotalMinutes) - $elapsed) -le 0.05) `
            "$rowContext timestamp and elapsedMinutes identify different captures."
        Require ($elapsed -gt $previousElapsed -and $timestamp -gt $previousTimestamp) `
            "$Context is not strictly monotonic."
        $previousElapsed = $elapsed
        $previousTimestamp = $timestamp

        $samplePid = Get-ExactInteger (Get-RequiredProperty $raw 'pid' $rowContext) `
            "$rowContext pid" 1 ([int]::MaxValue)
        $pidStable = Get-ExactBoolean (Get-RequiredProperty $raw 'pidStable' $rowContext) `
            "$rowContext pidStable"
        Require ($samplePid -eq $ExpectedPid -and $pidStable) `
            "$rowContext does not belong to the bound process."
        $focus = Get-ExactString (Get-RequiredProperty $raw 'focus' $rowContext) `
            "$rowContext focus"
        Require ($focus -in @('focused', 'not-focused', 'unknown', 'not-running')) `
            "$rowContext has an unknown focus state."
        $gameJvmAlive = Get-ExactBoolean (Get-RequiredProperty $raw 'gameJvmAlive' `
            $rowContext) "$rowContext gameJvmAlive"

        $logFieldsPassed = $true
        foreach ($field in @(
                'expectedGameLogPathMatched',
                'expectedGameLogRegularAndNonEmpty',
                'expectedGameLogSameFile',
                'expectedGameLogTemporallyBoundToProcess',
                'expectedGameLogFresh')) {
            $value = Get-ExactBoolean (Get-RequiredProperty $raw $field $rowContext) `
                "$rowContext $field"
            $logFieldsPassed = $logFieldsPassed -and $value
        }
        $logModified = Get-ExactInteger (Get-RequiredProperty $raw `
            'expectedGameLogModifiedEpochSeconds' $rowContext) `
            "$rowContext expectedGameLogModifiedEpochSeconds" 1
        $logObserved = Get-ExactInteger (Get-RequiredProperty $raw `
            'expectedGameLogObservedDeviceEpochSeconds' $rowContext) `
            "$rowContext expectedGameLogObservedDeviceEpochSeconds" 1
        $logTimestampsPassed = $logModified -le ($logObserved + 2) -and
            $logModified -ge ($logObserved - 60)
        $logPassed = $logFieldsPassed -and $logTimestampsPassed
        # A complete metric row can be emitted only after the producer's live
        # log fence succeeds. A false fence alongside complete metrics is not a
        # faithful RC6.2 sample and is rejected rather than reinterpreted.
        Require $logPassed "$rowContext failed the expected-profile game-log fence."

        $normalized = [ordered]@{
            timestampUtc = $timestamp
            elapsedMinutes = $elapsed
            pid = [int]$samplePid
            pidStable = $pidStable
            focus = $focus
            gameJvmAlive = $gameJvmAlive
            expectedGameLogComplete = $logPassed
        }
        foreach ($field in $memoryFields) {
            $normalized[$field] = Get-ExactInteger `
                (Get-RequiredProperty $raw $field $rowContext) "$rowContext $field" 0
        }
        Require ($normalized.totalPssKib -gt 0 -and
            $normalized.totalRssKib -gt 0 -and
            $normalized.vmRssKib -gt 0 -and
            $normalized.memAvailableKib -gt 0) `
            "$rowContext contains impossible zero process/system memory."

        $batteryTemperatureC = Get-FiniteNumber (Get-RequiredProperty $raw `
            'batteryTemperatureC' $rowContext) "$rowContext batteryTemperatureC"
        $batteryStatusCode = Get-ExactInteger (Get-RequiredProperty $raw `
            'batteryStatusCode' $rowContext) "$rowContext batteryStatusCode" 0 5
        $thermalStatusCode = Get-ExactInteger (Get-RequiredProperty $raw `
            'thermalStatusCode' $rowContext) "$rowContext thermalStatusCode" 0 6
        $null = Get-ExactString (Get-RequiredProperty $raw 'thermalStatusName' $rowContext) `
            "$rowContext thermalStatusName"
        $rowMaxBattery = Get-FiniteNumber (Get-RequiredProperty $raw `
            'configuredMaxBatteryTemperatureC' $rowContext) `
            "$rowContext configuredMaxBatteryTemperatureC"
        $rowMaxThermal = Get-ExactInteger (Get-RequiredProperty $raw `
            'configuredMaxThermalStatus' $rowContext) `
            "$rowContext configuredMaxThermalStatus" 0 3
        Require ($rowMaxBattery -eq $ConfiguredMaxBatteryTemperatureC -and
            $rowMaxThermal -eq $ConfiguredMaxThermalStatus) `
            "$rowContext thermal limits differ from the run summary."
        $reportedLimitExceeded = Get-ExactBoolean (Get-RequiredProperty $raw `
            'thermalLimitExceeded' $rowContext) "$rowContext thermalLimitExceeded"
        $reportedSafetyStop = Get-ExactBoolean (Get-RequiredProperty $raw `
            'thermalSafetyStopPerformed' $rowContext) `
            "$rowContext thermalSafetyStopPerformed"
        $recomputedLimitExceeded = $batteryTemperatureC -gt $rowMaxBattery -or
            $thermalStatusCode -gt $rowMaxThermal
        Require ($reportedLimitExceeded -eq $recomputedLimitExceeded) `
            "$rowContext thermal-limit flag does not match its raw values."
        Require ($reportedSafetyStop -eq $reportedLimitExceeded) `
            "$rowContext thermal safety-stop flag is inconsistent."

        $normalized.batteryTemperatureC = $batteryTemperatureC
        $normalized.batteryStatusCode = [int]$batteryStatusCode
        $normalized.thermalStatusCode = [int]$thermalStatusCode
        $normalized.thermalLimitExceeded = $reportedLimitExceeded
        $normalized.thermalSafetyStopPerformed = $reportedSafetyStop
        $samples.Add([pscustomobject]$normalized)
    }

    return $samples.ToArray()
}

function Read-RunEvidence(
    [int] $Round,
    [Parameter(Mandatory)][object] $SummarySnapshot,
    [Parameter(Mandatory)][object] $SamplesSnapshot,
    [Parameter(Mandatory)][object] $Candidate
) {
    $context = "run $Round"
    $summary = Read-JsonObject $SummarySnapshot.Text "$context summary"
    Require ((Get-ExactInteger (Get-RequiredProperty $summary 'schemaVersion' `
                "$context summary") "$context summary schemaVersion") -eq 3) `
        "$context summary is not RC6.2 schema 3."
    Require ((Get-ExactString (Get-RequiredProperty $summary 'package' `
                "$context summary") "$context summary package") -ceq
            $Candidate.package) "$context summary names another package."
    $producerSha256 = Get-ExactSha256 (Get-RequiredProperty $summary `
        'producerSha256' "$context summary") "$context summary producerSha256"
    Require ($producerSha256 -ceq $Candidate.memorySoakProducerSha256) `
        "$context summary was emitted by another producer."
    $durationMinutes = Get-ExactInteger (Get-RequiredProperty $summary `
        'requestedDurationMinutes' "$context summary") `
        "$context requestedDurationMinutes" 1
    $intervalSeconds = Get-ExactInteger (Get-RequiredProperty $summary `
        'intervalSeconds' "$context summary") "$context intervalSeconds" 1
    $reportedSamples = Get-ExactInteger (Get-RequiredProperty $summary 'samples' `
        "$context summary") "$context summary samples" 1
    $minimumExpectedSamples = Get-ExactInteger (Get-RequiredProperty $summary `
        'minimumExpectedSamples' "$context summary") `
        "$context minimumExpectedSamples" 1
    $completeMetricSamples = Get-ExactInteger (Get-RequiredProperty $summary `
        'completeMetricSamples' "$context summary") `
        "$context completeMetricSamples" 0
    Require ($durationMinutes -eq 90 -and $intervalSeconds -eq 300 -and
        $reportedSamples -eq 19 -and $minimumExpectedSamples -eq 19 -and
        $completeMetricSamples -eq 19) `
        "$context did not use the complete fixed 90-minute/300-second protocol."

    $startedUtc = Get-UtcTimestamp (Get-RequiredProperty $summary 'startedUtc' `
        "$context summary") "$context summary startedUtc"
    $initialPid = Get-ExactInteger (Get-RequiredProperty $summary 'initialPid' `
        "$context summary") "$context initialPid" 1 ([int]::MaxValue)
    Assert-ProvenanceReceipt (Get-RequiredProperty $summary 'provenance' `
        "$context summary") "$context start provenance"
    Assert-ProvenanceReceipt (Get-RequiredProperty $summary 'finalProvenance' `
        "$context summary") "$context final provenance"
    $runtime = Assert-RuntimeBinding (Get-RequiredProperty $summary `
        'runtimeBinding' "$context summary") ([int]$initialPid) $producerSha256 `
        $startedUtc "$context runtimeBinding"

    $thermal = Get-RequiredProperty $summary 'thermalSafety' "$context summary"
    $configuredMaxBattery = Get-FiniteNumber (Get-RequiredProperty $thermal `
        'configuredMaxBatteryTemperatureC' "$context thermalSafety") `
        "$context configuredMaxBatteryTemperatureC"
    $configuredMaxThermal = Get-ExactInteger (Get-RequiredProperty $thermal `
        'configuredMaxThermalStatus' "$context thermalSafety") `
        "$context configuredMaxThermalStatus" 0 3
    Require ($configuredMaxBattery -ge 35.0 -and $configuredMaxBattery -le 50.0) `
        "$context configured battery-temperature limit is outside the producer contract."

    $samples = @(Read-SampleRows $SamplesSnapshot.Text ([int]$reportedSamples) `
        ([int]$initialPid) $startedUtc $configuredMaxBattery `
        ([int]$configuredMaxThermal) "$context samples")
    Require ($samples.Count -eq 19) "$context sample parser did not retain all rows."
    Require ($samples[0].elapsedMinutes -le 1.0 -and
        $samples[-1].elapsedMinutes -ge 90.0) `
        "$context samples do not span the requested 90 minutes."
    Require ($samples[0].timestampUtc -ge $runtime.StartObservedUtc -and
        $samples[-1].timestampUtc -le $runtime.FinalObservedUtc) `
        "$context samples fall outside the authenticated runtime binding."

    $postWarm = @($samples | Where-Object elapsedMinutes -ge 15.0)
    $lastThirty = @($samples | Where-Object elapsedMinutes -ge 60.0)
    Require ($postWarm.Count -ge 16 -and $lastThirty.Count -ge 7) `
        "$context analysis windows are incomplete."

    $metricPublic = [ordered]@{}
    $metricInternal = @{}
    foreach ($definition in $script:MetricDefinitions) {
        $analysis = Get-MetricAnalysis $samples $postWarm $lastThirty `
            $definition.SourceField "$context $($definition.Name)"
        $metricPublic[$definition.Name] = $analysis.Public
        $metricInternal[$definition.Name] = $analysis
    }

    $maxPssMib = [math]::Round($metricInternal.pss.RawMaximumMib, 3)
    $maxVmRssMib = [math]::Round($metricInternal.vmRss.RawMaximumMib, 3)
    $maxSwapMib = [math]::Round($metricInternal.processSwap.RawMaximumMib, 3)
    $minMemAvailableMib = [math]::Round($metricInternal.memAvailable.RawMinimumMib, 3)
    $minSwapFreeMib = [math]::Round($metricInternal.systemSwapFree.RawMinimumMib, 3)
    $producerPssSlope = [math]::Round($metricInternal.pss.RawSlope, 3)
    $producerPssLastThirty = [math]::Round(
        $metricInternal.pss.RawLastThirtyGrowth, 3)
    Assert-RoundedEqual (Get-RequiredProperty $summary 'maxPssMib' "$context summary") `
        $maxPssMib "$context summary maxPssMib"
    Assert-RoundedEqual (Get-RequiredProperty $summary 'maxRssMib' "$context summary") `
        $maxVmRssMib "$context summary maxRssMib (VmRSS)"
    Assert-RoundedEqual (Get-RequiredProperty $summary 'maxProcessSwapMib' `
        "$context summary") $maxSwapMib "$context summary maxProcessSwapMib"
    Assert-RoundedEqual (Get-RequiredProperty $summary 'minMemAvailableMib' `
        "$context summary") $minMemAvailableMib "$context summary minMemAvailableMib"
    Assert-RoundedEqual (Get-RequiredProperty $summary 'minSwapFreeMib' `
        "$context summary") $minSwapFreeMib "$context summary minSwapFreeMib"
    Assert-RoundedEqual (Get-RequiredProperty $summary `
        'postWarmPssSlopeMibPerMinute' "$context summary") $producerPssSlope `
        "$context summary postWarmPssSlopeMibPerMinute"
    Assert-RoundedEqual (Get-RequiredProperty $summary `
        'lastThirtyMinutesGrowthMib' "$context summary") $producerPssLastThirty `
        "$context summary lastThirtyMinutesGrowthMib"

    $pidStable = @($samples | Where-Object { -not $_.pidStable }).Count -eq 0
    $focusComplete = @($samples | Where-Object focus -cne 'focused').Count -eq 0
    $gameJvmComplete = @($samples | Where-Object { -not $_.gameJvmAlive }).Count -eq 0
    $gameLogComplete = @($samples | Where-Object {
            -not $_.expectedGameLogComplete
        }).Count -eq 0
    $thermalLimitExceeded = @($samples | Where-Object {
            $_.thermalLimitExceeded
        }).Count -gt 0
    $thermalStopPerformed = @($samples | Where-Object {
            $_.thermalSafetyStopPerformed
        }).Count -gt 0
    $maxBatteryObserved = [double](($samples |
            Measure-Object batteryTemperatureC -Maximum).Maximum)
    $maxThermalObserved = [int](($samples |
            Measure-Object thermalStatusCode -Maximum).Maximum)

    Require (-not $thermalStopPerformed) `
        "$context ended through a thermal safety stop and is not a completed input."
    Assert-RoundedEqual (Get-RequiredProperty $thermal `
        'maxBatteryTemperatureObservedC' "$context thermalSafety") `
        $maxBatteryObserved "$context maxBatteryTemperatureObservedC"
    Require ((Get-ExactInteger (Get-RequiredProperty $thermal `
                'maxThermalStatusObserved' "$context thermalSafety") `
                "$context maxThermalStatusObserved" 0 6) -eq $maxThermalObserved) `
        "$context summary maxThermalStatusObserved does not match its samples."
    Require ((Get-ExactBoolean (Get-RequiredProperty $thermal 'limitExceeded' `
                "$context thermalSafety") "$context thermalSafety limitExceeded") -eq
            $thermalLimitExceeded -and
        (Get-ExactBoolean (Get-RequiredProperty $thermal 'labSafetyStopPerformed' `
                "$context thermalSafety") "$context thermalSafety labSafetyStopPerformed") -eq
            $thermalStopPerformed) `
        "$context thermal summary flags do not match its samples."
    $safetyStopInvocations = Get-ExactInteger (Get-RequiredProperty $thermal `
        'safetyStopInvocations' "$context thermalSafety") `
        "$context safetyStopInvocations" 0
    Require ($safetyStopInvocations -eq 0 -and
        (Get-ExactString (Get-RequiredProperty $thermal 'safetyStopTarget' `
                "$context thermalSafety") "$context safetyStopTarget") -ceq
            $Candidate.package -and
        (Test-ExactFalse (Get-RequiredProperty $thermal 'stablePackageStopped' `
                "$context thermalSafety"))) `
        "$context thermal boundary is not Host-safe completed evidence."
    Require ((Get-ExactInteger (Get-RequiredProperty $summary `
                'thermalSafetyStopInvocations' "$context summary") `
                "$context summary thermalSafetyStopInvocations" 0) -eq 0) `
        "$context reports a thermal safety-stop invocation."

    $completedDuration = $samples[-1].elapsedMinutes -ge $durationMinutes
    $sampleCountComplete = $samples.Count -ge $minimumExpectedSamples
    $metricsComplete = $samples.Count -eq $completeMetricSamples
    $postWarmComplete = $postWarm.Count -ge 16
    $lastThirtyComplete = $lastThirty.Count -ge 7
    $absolutePssPass = $metricInternal.pss.RawMaximumMib -le $script:AbsoluteLimitMib
    $absoluteVmRssPass = $metricInternal.vmRss.RawMaximumMib -le $script:AbsoluteLimitMib
    $processSwapPass = $metricInternal.processSwap.RawMaximumMib -le
        $script:SupplementaryMaxProcessSwapMib
    # The producer gates its already rounded values. Supplementary decisions
    # below deliberately use the unrounded raw calculations.
    $producerSlopePass = $producerPssSlope -le $script:SupplementarySlopeLimit
    $producerLastThirtyPass = $producerPssLastThirty -le
        $script:SupplementaryLastThirtyLimitMib
    $thermalPass = -not $thermalLimitExceeded -and -not $thermalStopPerformed
    $producerPassed = $completedDuration -and $sampleCountComplete -and
        $metricsComplete -and $focusComplete -and $gameJvmComplete -and
        $gameLogComplete -and $thermalPass -and $postWarmComplete -and
        $lastThirtyComplete -and $pidStable -and $absolutePssPass -and
        $absoluteVmRssPass -and $processSwapPass -and $producerSlopePass -and
        $producerLastThirtyPass

    Require ($completedDuration -and $sampleCountComplete -and $metricsComplete -and
        $postWarmComplete -and $lastThirtyComplete) `
        "$context is not a complete analyzable soak."
    foreach ($topField in @(
            @('pidStable', $pidStable),
            @('focusStayedOnLab', $focusComplete),
            @('gameJvmStayedAlive', $gameJvmComplete),
            @('expectedGameLogStayedFresh', $gameLogComplete))) {
        $reported = Get-ExactBoolean (Get-RequiredProperty $summary $topField[0] `
            "$context summary") "$context summary $($topField[0])"
        Require ($reported -eq [bool]$topField[1]) `
            "$context summary '$($topField[0])' does not match its samples."
    }

    $acceptance = Get-RequiredProperty $summary 'acceptance' "$context summary"
    $derivedAcceptance = [ordered]@{
        completedDuration = $completedDuration
        sampleCountComplete = $sampleCountComplete
        allRequiredMetricsPresent = $metricsComplete
        focusStayedOnLab = $focusComplete
        gameJvmStayedAlive = $gameJvmComplete
        expectedGameLogStayedFresh = $gameLogComplete
        thermalLimitNeverExceeded = (-not $thermalLimitExceeded)
        thermalSafetyStopNotRequired = (-not $thermalStopPerformed)
        postWarmSamplesComplete = $postWarmComplete
        lastThirtySamplesComplete = $lastThirtyComplete
        maxPssAtMost2457Point6Mib = $absolutePssPass
        maxRssAtMost2457Point6Mib = $absoluteVmRssPass
        processSwapAtMost512Mib = $processSwapPass
        slopeAtMost2MibPerMinute = $producerSlopePass
        lastThirtyGrowthAtMost128Mib = $producerLastThirtyPass
        passed = $producerPassed
    }
    $originalAcceptanceSnapshot = [ordered]@{}
    foreach ($field in $derivedAcceptance.Keys) {
        $reported = Get-ExactBoolean (Get-RequiredProperty $acceptance $field `
            "$context acceptance") "$context acceptance $field"
        Require ($reported -eq [bool]$derivedAcceptance[$field]) `
            "$context original acceptance '$field' does not match the raw samples."
        $originalAcceptanceSnapshot[$field] = $reported
    }

    $absoluteFailures = [Collections.Generic.List[string]]::new()
    if (-not $absolutePssPass) { $absoluteFailures.Add('PSS_EXCEEDED_2_POINT_4_GIB') }
    if (-not $absoluteVmRssPass) { $absoluteFailures.Add('VMRSS_EXCEEDED_2_POINT_4_GIB') }
    $originalFailures = @($derivedAcceptance.Keys | Where-Object {
            $_ -cne 'passed' -and -not [bool]$derivedAcceptance[$_]
        })

    $supplementaryGates = [ordered]@{
        exactCandidateAndRuntimeBindingPassed = $true
        sampleCompletenessPassed = $true
        noLmkOrProcessLossObserved = ($pidStable -and $gameJvmComplete)
        focusStayedOnLab = $focusComplete
        expectedGameLogIdentityAndFreshnessPassed = $gameLogComplete
        thermalStayedWithinOriginalLimits = $thermalPass
        postWarmPssSlopeAtMost2MibPerMinute =
            ($metricInternal.pss.RawSlope -le $script:SupplementarySlopeLimit)
        postWarmVmRssSlopeAtMost2MibPerMinute =
            ($metricInternal.vmRss.RawSlope -le $script:SupplementarySlopeLimit)
        lastThirtyPssGrowthAtMost128Mib =
            ($metricInternal.pss.RawLastThirtyGrowth -le
                $script:SupplementaryLastThirtyLimitMib)
        lastThirtyVmRssGrowthAtMost128Mib =
            ($metricInternal.vmRss.RawLastThirtyGrowth -le
                $script:SupplementaryLastThirtyLimitMib)
        memAvailableNeverBelow1GiB =
            ($metricInternal.memAvailable.RawMinimumMib -ge
                $script:SupplementaryMinMemAvailableMib)
        processSwapNeverAbove512Mib =
            ($metricInternal.processSwap.RawMaximumMib -le
                $script:SupplementaryMaxProcessSwapMib)
    }
    $supplementaryPass = @($supplementaryGates.Values | Where-Object {
            $_ -isnot [bool] -or -not [bool]$_
        }).Count -eq 0

    return [pscustomobject]@{
        Public = [pscustomobject][ordered]@{
            run = $Round
            inputs = [pscustomobject][ordered]@{
                summarySha256 = $SummarySnapshot.Sha256
                summarySizeBytes = $SummarySnapshot.Length
                samplesSha256 = $SamplesSnapshot.Sha256
                samplesSizeBytes = $SamplesSnapshot.Length
                pathsPersisted = $false
            }
            protocol = [pscustomobject][ordered]@{
                requestedDurationMinutes = [int]$durationMinutes
                intervalSeconds = [int]$intervalSeconds
                sampleCount = $samples.Count
                postWarmSampleCount = $postWarm.Count
                lastThirtySampleCount = $lastThirty.Count
                firstElapsedMinutes = $samples[0].elapsedMinutes
                lastElapsedMinutes = $samples[-1].elapsedMinutes
                complete = $true
            }
            runtimeBinding = [pscustomobject][ordered]@{
                result = 'PASS'
                sameProcessIncarnation = $true
                pid = [int]$initialPid
                processStartTicks = [int64]$runtime.ProcessStartTicks
                startedUtc = $startedUtc.ToString('o')
                startReceiptUtc = $runtime.StartObservedUtc.ToString('o')
                finalReceiptUtc = $runtime.FinalObservedUtc.ToString('o')
                exactCandidateProducerMatched = $true
                expectedGameLogIdentityMatchedAtStartAndFinal = $true
                expectedGameLogFreshAtEverySample = $true
                lmkTelemetryPersisted = $false
                noLmkOrProcessLossBasis =
                    'same process incarnation and live JVM at every sample and the final attestation'
            }
            originalProducerResult = [pscustomobject][ordered]@{
                immutable = $true
                sourceSummarySha256 = $SummarySnapshot.Sha256
                result = if ($producerPassed) { 'PASS' } else { 'FAIL' }
                passed = $producerPassed
                acceptance = [pscustomobject]$originalAcceptanceSnapshot
                failedCriteria = @($originalFailures)
                supplementaryAnalysisOverridesResult = $false
            }
            absolute2Point4GiBGate = [pscustomobject][ordered]@{
                result = if ($absoluteFailures.Count -eq 0) { 'PASS' } else { 'FAIL' }
                failed = ($absoluteFailures.Count -gt 0)
                limitGiB = 2.4
                limitMib = $script:AbsoluteLimitMib
                pss = [pscustomobject][ordered]@{
                    maximumMib = $maxPssMib
                    passed = $absolutePssPass
                }
                vmRss = [pscustomobject][ordered]@{
                    maximumMib = $maxVmRssMib
                    passed = $absoluteVmRssPass
                    producerSummaryField = 'maxRssMib'
                }
                failureReasons = @($absoluteFailures)
                supplementaryAnalysisOverridesResult = $false
            }
            originalThermalLimits = [pscustomobject][ordered]@{
                maxBatteryTemperatureC = $configuredMaxBattery
                maxThermalStatus = [int]$configuredMaxThermal
                maxBatteryTemperatureObservedC = $maxBatteryObserved
                maxThermalStatusObserved = $maxThermalObserved
                passed = $thermalPass
            }
            recomputedMetrics = [pscustomobject]$metricPublic
            supplementaryGates = [pscustomobject]$supplementaryGates
            supplementaryClassification = if ($supplementaryPass) {
                'LEAK_STABILITY_PASS'
            } else {
                'LEAK_STABILITY_NOT_ESTABLISHED'
            }
        }
        StartedUtc = $startedUtc
        FirstSampleUtc = $samples[0].timestampUtc
        LastSampleUtc = $samples[-1].timestampUtc
        StartReceiptUtc = $runtime.StartObservedUtc
        FinalReceiptUtc = $runtime.FinalObservedUtc
        ProcessStartTicks = $runtime.ProcessStartTicks
        SupplementaryPass = $supplementaryPass
        OriginalPass = $producerPassed
        AbsolutePass = $absoluteFailures.Count -eq 0
    }
}

function Write-NewAtomicJson(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][object] $Value,
    [Parameter(Mandatory)][string[]] $ForbiddenPaths
) {
    if ([IO.Path]::IsPathRooted($Path)) {
        $fullPath = [IO.Path]::GetFullPath($Path)
    } else {
        $fullPath = [IO.Path]::GetFullPath((Join-Path ([Environment]::CurrentDirectory) $Path))
    }
    foreach ($forbidden in $ForbiddenPaths) {
        Require (-not $fullPath.Equals($forbidden, [StringComparison]::OrdinalIgnoreCase)) `
            'OutputPath must not overwrite an input or contract file.'
    }
    Require (-not (Test-Path -LiteralPath $fullPath)) `
        'OutputPath already exists; supplementary reports are create-once.'
    $parentText = Split-Path -Parent $fullPath
    Require (-not [string]::IsNullOrWhiteSpace($parentText)) `
        'OutputPath has no parent directory.'
    try {
        $parent = (Resolve-Path -LiteralPath $parentText -ErrorAction Stop).Path
    } catch {
        Fail 'OutputPath parent directory does not exist.'
    }
    $parentItem = Get-Item -LiteralPath $parent -Force
    Require ($parentItem.PSIsContainer -and
        ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        'OutputPath parent must be a normal directory.'
    $fullPath = Join-Path $parent ([IO.Path]::GetFileName($fullPath))
    Require (-not (Test-Path -LiteralPath $fullPath)) `
        'OutputPath appeared during validation.'

    $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    $temporary = Join-Path $parent `
        ('.' + [IO.Path]::GetFileName($fullPath) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally {
            $stream.Dispose()
        }
        [IO.File]::Move($temporary, $fullPath)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

$readLocks = [Collections.Generic.List[IDisposable]]::new()
try {
    $buildLockSnapshot = Open-ReadSnapshot `
        (Join-Path $script:RepoRoot 'V71_LAB_RC6_2.lock.json') `
        'RC6.2 build lock' (1024 * 1024)
    $readLocks.Add($buildLockSnapshot.ReadLock)
    $producerLockSnapshot = Open-ReadSnapshot `
        (Join-Path $script:RepoRoot 'V71_RC6_2_EVIDENCE_PRODUCERS.lock.json') `
        'RC6.2 producer lock' (1024 * 1024)
    $readLocks.Add($producerLockSnapshot.ReadLock)
    $samplerSnapshot = Open-ReadSnapshot `
        (Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc62.ps1') `
        'locked RC6.2 sampler' (4 * 1024 * 1024)
    $readLocks.Add($samplerSnapshot.ReadLock)
    $buildLock = Read-JsonObject $buildLockSnapshot.Text 'RC6.2 build lock'
    $producerLock = Read-JsonObject $producerLockSnapshot.Text 'RC6.2 producer lock'
    $candidate = Assert-ExactCandidateLocks $buildLock $producerLock `
        $samplerSnapshot $buildLockSnapshot.Sha256 $producerLockSnapshot.Sha256

    $firstSummary = Open-ReadSnapshot $FirstSummaryPath 'first summary' (1024 * 1024)
    $readLocks.Add($firstSummary.ReadLock)
    $firstSamples = Open-ReadSnapshot $FirstSamplesPath 'first samples' (16 * 1024 * 1024)
    $readLocks.Add($firstSamples.ReadLock)
    $secondSummary = Open-ReadSnapshot $SecondSummaryPath 'second summary' (1024 * 1024)
    $readLocks.Add($secondSummary.ReadLock)
    $secondSamples = Open-ReadSnapshot $SecondSamplesPath 'second samples' (16 * 1024 * 1024)
    $readLocks.Add($secondSamples.ReadLock)

    $canonicalInputs = @(
        $firstSummary.ResolvedPath, $firstSamples.ResolvedPath,
        $secondSummary.ResolvedPath, $secondSamples.ResolvedPath)
    $pathSet = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $canonicalInputs) {
        Require ($pathSet.Add($path)) 'All four evidence input paths must be distinct.'
    }
    Require ([IO.Path]::GetFileName($firstSummary.ResolvedPath) -ceq 'summary.json' -and
        [IO.Path]::GetFileName($secondSummary.ResolvedPath) -ceq 'summary.json' -and
        [IO.Path]::GetFileName($firstSamples.ResolvedPath) -ceq 'samples.jsonl' -and
        [IO.Path]::GetFileName($secondSamples.ResolvedPath) -ceq 'samples.jsonl') `
        'Each run must use its completed summary.json and samples.jsonl files.'
    Require ((Split-Path -Parent $firstSummary.ResolvedPath).Equals(
            (Split-Path -Parent $firstSamples.ResolvedPath),
            [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Parent $secondSummary.ResolvedPath).Equals(
            (Split-Path -Parent $secondSamples.ResolvedPath),
            [StringComparison]::OrdinalIgnoreCase)) `
        'Each summary must be paired with samples from the same directory.'
    Require ($firstSummary.Sha256 -cne $secondSummary.Sha256 -and
        $firstSamples.Sha256 -cne $secondSamples.Sha256) `
        'The same run content cannot satisfy both required soaks.'

    $run1 = Read-RunEvidence 1 $firstSummary $firstSamples $candidate
    $run2 = Read-RunEvidence 2 $secondSummary $secondSamples $candidate
    Require ($run1.StartedUtc -ne $run2.StartedUtc) `
        'The two inputs identify the same run start.'
    $nonOverlapping = $run1.FinalReceiptUtc -le $run2.StartReceiptUtc -or
        $run2.FinalReceiptUtc -le $run1.StartReceiptUtc
    Require $nonOverlapping `
        'The two runtime-bound soak intervals overlap; two distinct completed runs are required.'

    $pairSupplementaryPass = $run1.SupplementaryPass -and $run2.SupplementaryPass
    $pairOriginalPass = $run1.OriginalPass -and $run2.OriginalPass
    $pairAbsolutePass = $run1.AbsolutePass -and $run2.AbsolutePass
    $classification = if ($pairSupplementaryPass) {
        'LEAK_STABILITY_PASS'
    } else {
        'LEAK_STABILITY_NOT_ESTABLISHED'
    }
    $analyzerSha256 = Get-NormalizedTextSha256 `
        ([IO.File]::ReadAllText($PSCommandPath))
    $report = [pscustomobject][ordered]@{
        schemaVersion = 1
        receiptType = 'V71_RC6_2_MEMORY_SOAK_PAIR_SUPPLEMENTARY_ANALYSIS'
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        result = $classification
        scope = 'HOST_ONLY_SUPPLEMENTARY_POSTPROCESSOR'
        analyzer = [pscustomobject][ordered]@{
            path = 'scripts/analyze-v71-memory-soak-pair-rc62.ps1'
            normalizedLfSha256 = $analyzerSha256
        }
        candidate = $candidate
        supplementaryCriteria = [pscustomobject][ordered]@{
            postWarmSlopeLimitMibPerMinute = $script:SupplementarySlopeLimit
            lastThirtyGrowthLimitMib = $script:SupplementaryLastThirtyLimitMib
            minimumMemAvailableMib = $script:SupplementaryMinMemAvailableMib
            maximumProcessSwapMib = $script:SupplementaryMaxProcessSwapMib
            thermalLimitSource = 'each original producer summary and its samples'
            absolute2Point4GiBIncludedInSupplementaryClassification = $false
            comparisonsUseUnroundedRecomputedValues = $true
        }
        originalProducerGate = [pscustomobject][ordered]@{
            result = if ($pairOriginalPass) { 'PASS' } else { 'FAIL' }
            allRunsPassed = $pairOriginalPass
            runResults = @(
                $run1.Public.originalProducerResult.result,
                $run2.Public.originalProducerResult.result)
            immutableAndUnmodified = $true
            supplementaryAnalysisOverridesResult = $false
        }
        absolute2Point4GiBGate = [pscustomobject][ordered]@{
            result = if ($pairAbsolutePass) { 'PASS' } else { 'FAIL' }
            failed = (-not $pairAbsolutePass)
            limitGiB = 2.4
            limitMib = $script:AbsoluteLimitMib
            runResults = @(
                $run1.Public.absolute2Point4GiBGate.result,
                $run2.Public.absolute2Point4GiBGate.result)
            supplementaryAnalysisOverridesResult = $false
        }
        runs = @($run1.Public, $run2.Public)
        supplementaryClassification = [pscustomobject][ordered]@{
            result = $classification
            allRunsPassed = $pairSupplementaryPass
            meaning = 'Observed bounded-growth criteria passed only when every listed supplementary gate passed in both runs.'
            proofOfAbsenceOfAllLeaks = $false
            originalProducerGateOverridden = $false
            absolute2Point4GiBGateOverridden = $false
            manualVisualAcceptanceClaimed = $false
            stablePromotionAuthorized = $false
        }
        evidenceBoundary = [pscustomobject][ordered]@{
            hostOnly = $true
            deviceCommandsInvoked = 0
            deviceReadPerformed = $false
            deviceWritePerformed = $false
            inputFilesModified = $false
            hostAbsolutePathsPersisted = $false
            predecessorEvidenceInherited = $false
            manualVisualAcceptanceMayBeInferred = $false
            stablePromotionMayBeInferred = $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-NewAtomicJson $OutputPath $report @(
            $canonicalInputs + @(
                $buildLockSnapshot.ResolvedPath,
                $producerLockSnapshot.ResolvedPath,
                $samplerSnapshot.ResolvedPath,
                $PSCommandPath))
    }
    $report
} finally {
    for ($index = $readLocks.Count - 1; $index -ge 0; $index--) {
        $readLocks[$index].Dispose()
    }
}
