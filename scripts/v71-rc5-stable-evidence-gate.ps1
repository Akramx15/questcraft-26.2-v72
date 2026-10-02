#requires -Version 7.0
<#
.SYNOPSIS
Read-only, fail-closed evidence validator for v71 RC5 Stable promotion.

.DESCRIPTION
This file contains no ADB, build, install, launch, mutation, or receipt writer.
It accepts only evidence for the exact RC5 Lab identity and rejects historical
RC4 receipts. Every producer and evidence file is bound by a canonical SHA-256.
#>

Set-StrictMode -Version Latest

$script:V71Rc5GatePath = $PSCommandPath
$script:V71Rc5RepoRoot = Split-Path -Parent $PSScriptRoot
$script:V71Rc5BuildLockPath = Join-Path $script:V71Rc5RepoRoot 'V71_LAB_RC5.lock.json'
$script:V71Rc4BuildLockPath = Join-Path $script:V71Rc5RepoRoot 'V71_LAB_RC4.lock.json'
$script:V71Rc5ProducerLockPath = Join-Path $script:V71Rc5RepoRoot `
    'V71_RC5_EVIDENCE_PRODUCERS.lock.json'
$script:V71Rc5BuildLock = Get-Content -Raw -LiteralPath `
    $script:V71Rc5BuildLockPath | ConvertFrom-Json
$script:V71Rc4BuildLock = Get-Content -Raw -LiteralPath `
    $script:V71Rc4BuildLockPath | ConvertFrom-Json
$script:V71Rc5ProducerLock = Get-Content -Raw -LiteralPath `
    $script:V71Rc5ProducerLockPath | ConvertFrom-Json
$script:V71Rc5LabPackage = [string]$script:V71Rc5BuildLock.target.package
$script:V71Rc5StablePackage = [string]$script:V71Rc5BuildLock.target.forbiddenStablePackage
$script:V71Rc5VersionCode = [int]$script:V71Rc5BuildLock.target.versionCode
$script:V71Rc5VersionName = [string]$script:V71Rc5BuildLock.target.versionName
$script:V71Rc5CoreSha256 = [string]$script:V71Rc5BuildLock.pair.core.sha256
$script:V71Rc5CoreSizeBytes = [int64]$script:V71Rc5BuildLock.pair.core.sizeBytes
$script:V71Rc5CoreVersion = [string]$script:V71Rc5BuildLock.pair.core.fabricVersion
$script:V71Rc5VeqSha256 = [string]$script:V71Rc5BuildLock.pair.veq.sha256
$script:V71Rc5VeqSizeBytes = [int64]$script:V71Rc5BuildLock.pair.veq.sizeBytes
$script:V71Rc5VeqVersion = [string]$script:V71Rc5BuildLock.pair.veq.fabricVersion
$script:V71Rc5PairSha256 = [string]$script:V71Rc5BuildLock.pair.sha256
$script:V71Rc5PojlibSha256 = [string]$script:V71Rc5BuildLock.pojlibAar.sha256
$script:V71Rc5PojlibSizeBytes = [int64]$script:V71Rc5BuildLock.pojlibAar.sizeBytes
$script:V71Rc5SignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:V71Rc5ZeroSha256 = '0' * 64
$script:V71Rc5ApkSha256 = [string]$script:V71Rc5BuildLock.target.apkSha256
$script:V71Rc5WorldSha256 = '9E9875E59D7C66C5E1C11E6557024D8033A33AC53A06F8D8B9065DFB76B31B90'
$script:V71Rc4CoreSha256 = [string]$script:V71Rc4BuildLock.pair.core.sha256
$script:V71Rc4VeqSha256 = [string]$script:V71Rc4BuildLock.pair.veq.sha256
$script:V71Rc5PerformanceProducerSha256 = `
    [string]$script:V71Rc5ProducerLock.producers.performanceHarnessScriptSha256
$script:V71Rc5PerformanceProducerHashScheme = 'sha256-utf8-normalized-lf'
$script:V71Rc5LabApkRelativePath = [string]$script:V71Rc5BuildLock.target.apkPath
$script:V71Rc5ExpectedGameLogRelativePath = `
    [string]$script:V71Rc5BuildLock.runtimeBinding.expectedGameLogRelativePath
$script:V71Rc5ExpectedGameLogMinecraftVersion = `
    [string]$script:V71Rc5BuildLock.runtimeBinding.expectedGameLogMinecraftVersion
$script:V71Rc5ExpectedGameLogCoreVersion = `
    [string]$script:V71Rc5BuildLock.runtimeBinding.expectedGameLogCoreVersion
$script:V71Rc5ExpectedGameLogVeqVersion = `
    [string]$script:V71Rc5BuildLock.runtimeBinding.expectedGameLogVeqVersion
$script:V71Rc5ManualConfirmationSource = 'explicit-user-message'
$script:V71Rc5ManualRecordedBy = 'human-recorded-from-explicit-user-confirmation'
$script:V71Rc5ManualCheckNames = @(
    'immersiveMcPickupBothHands'
    'wristThrowFullStackOutside'
    'wristThrowSingleItemOutside'
    'wristOtherHandCannotStealCarriedItem'
    'yUsesLeftHandItemOnLegacyServer'
    'bContainerAndInventoryBehavior'
    'nativeContainerMenuDoesNotFollowHeadTurn'
    'nativeContainerMenuPointerWorks'
    'nativeContainerMenuLocomotionWorks'
    'gripBothHands'
    'bow'
    'shield'
    'teleport'
    'secondaryActionRightHandSingleItem'
    'secondaryActionLeftHandSingleItem'
    'jumpAndTeleportUnaffectedOutsideWrist'
    'heldButtonFocusChangeDoesNotReplay'
    'reverseHandsSecondaryAction'
)
$script:V71Rc5ExpectedPerformanceDependencyHashes = [ordered]@{}
foreach ($dependency in $script:V71Rc5ProducerLock.performanceDependencies.PSObject.Properties) {
    $script:V71Rc5ExpectedPerformanceDependencyHashes[$dependency.Name] =
        [string]$dependency.Value
}

function Require-V71Rc5Evidence {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC5_STABLE_EVIDENCE] $Message" }
}

function Get-V71Rc5Property {
    param($Object, [string] $Name, [string] $Context)
    Require-V71Rc5Evidence ($null -ne $Object) "$Context is absent."
    $property = $Object.PSObject.Properties[$Name]
    Require-V71Rc5Evidence ($null -ne $property) "$Context.$Name is absent."
    return $property.Value
}

function Test-V71Rc5ExactTrue { param($Value); return $Value -is [bool] -and $Value }
function Test-V71Rc5ExactFalse { param($Value); return $Value -is [bool] -and -not $Value }

function ConvertTo-V71Rc5Sha256 {
    param($Value, [string] $Context, [switch] $AllowZero)
    Require-V71Rc5Evidence ($Value -is [string]) "$Context must be a string."
    $valueText = ([string]$Value).ToUpperInvariant()
    Require-V71Rc5Evidence ($valueText -cmatch '^[0-9A-F]{64}$') `
        "$Context is not a canonical SHA-256."
    if (-not $AllowZero) {
        Require-V71Rc5Evidence ($valueText -cne $script:V71Rc5ZeroSha256) `
            "$Context is still the zero/PENDING SHA-256."
    }
    return $valueText
}

function Get-V71Rc5FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-V71Rc5TextSha256 {
    param([Parameter(Mandatory)][string] $Path, [string] $Context = 'producer')
    Require-V71Rc5Evidence (Test-Path -LiteralPath $Path -PathType Leaf) `
        "$Context file is missing."
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $value = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } catch {
        throw "[V71_RC5_STABLE_EVIDENCE] $Context is not strict UTF-8 text: $($_.Exception.Message)"
    }
    Require-V71Rc5Evidence (-not $value.StartsWith([string][char]0xFEFF,
        [StringComparison]::Ordinal)) "$Context contains a UTF-8 BOM."
    $normalized = $value.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($normalized)))
}

function Enter-V71Rc5ReadLock {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Context)
    Require-V71Rc5Evidence (Test-Path -LiteralPath $Path -PathType Leaf) "$Context file is missing."
    $item = Get-Item -LiteralPath $Path -Force
    Require-V71Rc5Evidence (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
        "$Context must not be a reparse point."
    try {
        return [IO.File]::Open($item.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
    } catch {
        throw "[V71_RC5_STABLE_EVIDENCE] Failed to lock $Context for reading: $($_.Exception.Message)"
    }
}

function Resolve-V71Rc5EvidenceFile {
    param(
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)] $RelativePath,
        [Parameter(Mandatory)] $ExpectedSha256,
        [Parameter(Mandatory)][string] $Context,
        [string] $RequiredPrefix = ''
    )
    Require-V71Rc5Evidence ($RelativePath -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$RelativePath)) "$Context path is absent."
    $relative = ([string]$RelativePath).Replace('\','/')
    Require-V71Rc5Evidence (-not [IO.Path]::IsPathRooted($relative) -and
        $relative -notmatch '(^|/)\.\.(/|$)' -and $relative -notmatch '(^|/)\.(/|$)') `
        "$Context path is not a clean repository-relative path."
    if (-not [string]::IsNullOrWhiteSpace($RequiredPrefix)) {
        Require-V71Rc5Evidence ($relative.StartsWith($RequiredPrefix,
            [StringComparison]::Ordinal)) "$Context is outside $RequiredPrefix."
    }
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\','/')
    $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
    Require-V71Rc5Evidence ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) "$Context escapes the workspace."
    Require-V71Rc5Evidence (Test-Path -LiteralPath $full -PathType Leaf) "$Context is missing."
    $cursor = Get-Item -LiteralPath $full -Force
    $first = $true
    while ($null -ne $cursor -and $cursor.FullName.StartsWith($root,
        [StringComparison]::OrdinalIgnoreCase)) {
        Require-V71Rc5Evidence (($cursor.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -eq 0) "$Context traverses a reparse point."
        if ($cursor.FullName -ceq $root) { break }
        if ($first -and $cursor -is [IO.FileInfo]) {
            $cursor = $cursor.Directory
            $first = $false
        } else {
            $cursor = $cursor.Parent
        }
    }
    $lockedHash = ConvertTo-V71Rc5Sha256 $ExpectedSha256 "$Context locked SHA-256"
    $readLock = $null
    try {
        $readLock = Enter-V71Rc5ReadLock $full $Context
        Require-V71Rc5Evidence ($readLock.Length -le 64MB) "$Context exceeds the evidence size limit."
        $bytes = [byte[]]::new([int]$readLock.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $readLock.Read($bytes, $offset, $bytes.Length - $offset)
            Require-V71Rc5Evidence ($count -gt 0) "$Context ended while reading locked bytes."
            $offset += $count
        }
        $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        Require-V71Rc5Evidence ($actualHash -ceq $lockedHash) "$Context SHA-256 drifted."
        try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
        catch { throw "[V71_RC5_STABLE_EVIDENCE] $Context is not strict UTF-8: $($_.Exception.Message)" }
        Require-V71Rc5Evidence (-not $text.StartsWith([string][char]0xFEFF,
            [StringComparison]::Ordinal)) "$Context contains a UTF-8 BOM."
        return [pscustomobject]@{
            Path = $full; Sha256 = $actualHash; RelativePath = $relative
            Text = $text; ReadLock = $readLock
        }
    } catch {
        if ($null -ne $readLock) { $readLock.Dispose() }
        throw
    }
}

function Read-V71Rc5Json {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Context)
    try { return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 40 -DateKind String }
    catch { throw "[V71_RC5_STABLE_EVIDENCE] $Context is invalid JSON: $($_.Exception.Message)" }
}

function Read-V71Rc5JsonText {
    param([Parameter(Mandatory)][string] $Text, [Parameter(Mandatory)][string] $Context)
    try { return $Text | ConvertFrom-Json -Depth 40 -DateKind String }
    catch { throw "[V71_RC5_STABLE_EVIDENCE] $Context is invalid JSON: $($_.Exception.Message)" }
}

function ConvertTo-V71Rc5FiniteNumber {
    param($Value, [string] $Context, [switch] $AllowNegative)
    $numeric = $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
    Require-V71Rc5Evidence $numeric "$Context is not a JSON number."
    $number = [double]$Value
    Require-V71Rc5Evidence (-not [double]::IsNaN($number) -and
        -not [double]::IsInfinity($number)) "$Context is not finite."
    if (-not $AllowNegative) { Require-V71Rc5Evidence ($number -ge 0.0) "$Context is negative." }
    return $number
}

function ConvertTo-V71Rc5Timestamp {
    param($Value, [string] $Context)
    Require-V71Rc5Evidence ($Value -is [string] -and
        -not [string]::IsNullOrWhiteSpace([string]$Value)) "$Context is absent."
    $parsed = [DateTimeOffset]::MinValue
    $valid = [DateTimeOffset]::TryParse([string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
    Require-V71Rc5Evidence $valid "$Context is not an ISO-8601 timestamp."
    return $parsed
}

function Assert-V71Rc5ExactPropertyNames {
    param($Object, [string[]] $ExpectedNames, [string] $Context)
    Require-V71Rc5Evidence ($null -ne $Object) "$Context is absent."
    $actualNames = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
    Require-V71Rc5Evidence ($actualNames.Count -eq $ExpectedNames.Count) `
        "$Context has missing or unexpected properties."
    foreach ($name in $ExpectedNames) {
        Require-V71Rc5Evidence ($actualNames -ccontains $name) `
            "$Context.$name is absent."
    }
    foreach ($name in $actualNames) {
        Require-V71Rc5Evidence ($ExpectedNames -ccontains $name) `
            "$Context.$name is unexpected."
    }
}

function Get-V71Rc5PssSlope {
    param([object[]] $Samples, [string] $Context)
    Require-V71Rc5Evidence ($Samples.Count -ge 2) "$Context has too few samples for a slope."
    $meanX = ($Samples | Measure-Object elapsedMinutes -Average).Average
    $meanY = ($Samples | ForEach-Object { $_.totalPssKib / 1024.0 } |
        Measure-Object -Average).Average
    $numerator = 0.0; $denominator = 0.0
    foreach ($sample in $Samples) {
        $dx = [double]$sample.elapsedMinutes - $meanX
        $dy = ([double]$sample.totalPssKib / 1024.0) - $meanY
        $numerator += $dx * $dy; $denominator += $dx * $dx
    }
    Require-V71Rc5Evidence ($denominator -gt 0.0) "$Context sample times cannot produce a slope."
    return [math]::Round($numerator / $denominator, 3)
}

function Assert-V71Rc5RoundedEqual {
    param($Reported, [double] $Recomputed, [string] $Context)
    $number = ConvertTo-V71Rc5FiniteNumber $Reported $Context -AllowNegative
    Require-V71Rc5Evidence ([math]::Abs($number - $Recomputed) -le 0.0011) `
        "$Context does not match the locked raw samples."
}

function Assert-V71Rc5BuildLockContract {
    param([switch] $RequireBuiltApk)
    $target = Get-V71Rc5Property $script:V71Rc5BuildLock 'target' 'RC5 build lock'
    $binding = Get-V71Rc5Property $script:V71Rc5BuildLock 'runtimeBinding' 'RC5 build lock'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $target 'package' 'RC5 build target') -ceq
            'com.qcxr.qcxr.canary262' -and
        [string](Get-V71Rc5Property $target 'forbiddenStablePackage' 'RC5 build target') -ceq
            'com.qcxr.qcxr.dev262' -and
        [string](Get-V71Rc5Property $target 'profile' 'RC5 build target') -ceq '26.2' -and
        [int](Get-V71Rc5Property $target 'versionCode' 'RC5 build target') -eq 71 -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $target 'stableTouched' 'RC5 build target'))) `
        'RC5 build lock package/profile/version or Stable guard drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $binding `
            'expectedGameLogRelativePath' 'RC5 runtime binding') -ceq
            'instances/26.2/logs/latest.log' -and
        [string](Get-V71Rc5Property $binding 'expectedGameLogMinecraftVersion' `
            'RC5 runtime binding') -ceq '26.2' -and
        [string](Get-V71Rc5Property $binding 'expectedGameLogCoreVersion' `
            'RC5 runtime binding') -ceq $script:V71Rc5CoreVersion -and
        [string](Get-V71Rc5Property $binding 'expectedGameLogVeqVersion' `
            'RC5 runtime binding') -ceq $script:V71Rc5VeqVersion) `
        'RC5 expectedGameLog binding drifted from profile/Core/VEQ.'
    if ($RequireBuiltApk) {
        Require-V71Rc5Evidence ([bool](Get-V71Rc5Property $target 'artifactAuditPassed' `
                'RC5 build target') -and
            [int64](Get-V71Rc5Property $target 'apkSizeBytes' 'RC5 build target') -gt 0 -and
            [string](Get-V71Rc5Property $target 'apkSha256' 'RC5 build target') -cmatch
                '^[0-9A-F]{64}$') `
            'RC5 Lab APK is PENDING_NOT_BUILT; Stable evidence cannot be accepted.'
    }
}

function Assert-V71Rc5LabIdentity {
    param($Identity, [switch] $RequireBuiltApk)
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'package' 'Lab identity') -ceq
        $script:V71Rc5LabPackage) 'Lab package drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'forbiddenStablePackage' 'Lab identity') -ceq
        $script:V71Rc5StablePackage) 'Forbidden Stable package marker drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'profile' 'Lab identity') -ceq
        '26.2') 'Lab profile drifted.'
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Identity 'versionCode' 'Lab identity') -eq
        $script:V71Rc5VersionCode) 'Lab versionCode drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'versionName' 'Lab identity') -ceq
        $script:V71Rc5VersionName) 'Lab versionName drifted.'
    $apkValue = Get-V71Rc5Property $Identity 'apkSha256' 'Lab identity'
    if ($RequireBuiltApk -and $apkValue -is [string] -and
        ([string]$apkValue).ToUpperInvariant() -ceq $script:V71Rc5ZeroSha256) {
        throw '[V71_RC5_STABLE_EVIDENCE] RC5 Lab APK is PENDING_NOT_BUILT; Stable evidence cannot be accepted.'
    }
    $apk = ConvertTo-V71Rc5Sha256 $apkValue 'Lab APK SHA-256' `
        -AllowZero:(-not $RequireBuiltApk)
    $apkSize = [int64](Get-V71Rc5Property $Identity 'apkSizeBytes' 'Lab identity')
    if ($RequireBuiltApk) {
        Require-V71Rc5Evidence ($apk -cne $script:V71Rc5ZeroSha256 -and $apkSize -gt 0) `
            'RC5 Lab APK is PENDING_NOT_BUILT; Stable evidence cannot be accepted.'
        Require-V71Rc5Evidence ($apk -ceq $script:V71Rc5ApkSha256 -and
            $apkSize -eq [int64]$script:V71Rc5BuildLock.target.apkSizeBytes) `
            'Acceptance identity does not match the exact audited RC5 build lock.'
        Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'artifactAudit' 'Lab identity') -ceq
            'PASS') 'RC5 Lab artifact audit is not PASS.'
    }
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'coreSha256' 'Lab identity') -ceq
        $script:V71Rc5CoreSha256 -and
        [int64](Get-V71Rc5Property $Identity 'coreSizeBytes' 'Lab identity') -eq
        $script:V71Rc5CoreSizeBytes -and
        [string](Get-V71Rc5Property $Identity 'coreVersion' 'Lab identity') -ceq
        $script:V71Rc5CoreVersion) 'Clean reproducible RC5 Core identity drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'veqSha256' 'Lab identity') -ceq
        $script:V71Rc5VeqSha256 -and
        [int64](Get-V71Rc5Property $Identity 'veqSizeBytes' 'Lab identity') -eq
        $script:V71Rc5VeqSizeBytes -and
        [string](Get-V71Rc5Property $Identity 'veqVersion' 'Lab identity') -ceq
        $script:V71Rc5VeqVersion) 'Frozen VEQ identity drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'coreVeqPairSha256' 'Lab identity') -ceq
        $script:V71Rc5PairSha256) 'RC5 Core/VEQ pair digest drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'pojlibAarSha256' 'Lab identity') -ceq
        $script:V71Rc5PojlibSha256 -and
        [int64](Get-V71Rc5Property $Identity 'pojlibAarSizeBytes' 'Lab identity') -eq
        $script:V71Rc5PojlibSizeBytes) 'Pojlib AAR identity drifted.'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'signerSha256' 'Lab identity') -ceq
        $script:V71Rc5SignerSha256) 'Lab signer drifted.'
    return [pscustomobject]@{ ApkSha256 = $apk; ApkSizeBytes = $apkSize }
}

function Assert-V71Rc5StableAcceptanceManifestContract {
    param($Manifest, [switch] $RequireAccepted)
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Manifest 'schemaVersion' `
        'acceptance manifest') -eq 1) 'Acceptance schema drifted.'
    $status = [string](Get-V71Rc5Property $Manifest 'status' 'acceptance manifest')
    if ($RequireAccepted) {
        Require-V71Rc5Evidence ($status -ceq 'ACCEPTED_FOR_STABLE_BUILD') `
            'RC5 evidence status is not ACCEPTED_FOR_STABLE_BUILD.'
    } else {
        Require-V71Rc5Evidence ($status -cin @('PENDING_EVIDENCE',
            'ACCEPTED_FOR_STABLE_BUILD')) 'RC5 acceptance status is invalid.'
    }
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Manifest `
            'candidateBuildLockPath' 'acceptance manifest') -ceq 'V71_LAB_RC5.lock.json') `
        'Acceptance manifest is not dynamically bound to V71_LAB_RC5.lock.json.'
    $relockRequired = Get-V71Rc5Property $Manifest `
        'identityRelockRequiredAfterFinalBuild' 'acceptance manifest'
    if ($RequireAccepted) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactFalse $relockRequired) `
            'Accepted RC5 evidence still requires identity relock.'
    } else {
        Require-V71Rc5Evidence ($relockRequired -is [bool]) `
            'Pending RC5 identity-relock state is not a JSON boolean.'
    }
    Assert-V71Rc5BuildLockContract -RequireBuiltApk:$RequireAccepted
    if ($RequireAccepted) {
        $identity = Get-V71Rc5Property $Manifest 'labIdentity' 'acceptance manifest'
        $null = Assert-V71Rc5LabIdentity $identity -RequireBuiltApk
    }
    $validator = Get-V71Rc5Property $Manifest 'validatorScript' 'acceptance manifest'
    $lockedValidatorSha = ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $script:V71Rc5ProducerLock.producers `
            'stableEvidenceGateScriptSha256' 'RC5 producer lock') `
        'RC5 Stable evidence-gate SHA-256'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $validator 'path' `
            'Stable validator') -ceq 'scripts/v71-rc5-stable-evidence-gate.ps1' -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $validator 'sha256' `
            'Stable validator') 'Stable validator SHA-256') -ceq $lockedValidatorSha -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $validator 'readOnly' `
            'Stable validator')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $validator 'deviceCapable' `
            'Stable validator')) -and
        (Get-V71Rc5TextSha256 $script:V71Rc5GatePath 'Stable evidence gate') -ceq
            $lockedValidatorSha) `
        'Stable evidence validator path, hash, or Host-only contract drifted.'
    $stable = Get-V71Rc5Property $Manifest 'stableTarget' 'acceptance manifest'
    $stableProtected = Test-V71Rc5ExactTrue (Get-V71Rc5Property $stable `
        'mustRemainUntouchedUntilPromotion' 'Stable target')
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $stable 'package' `
            'Stable target') -ceq $script:V71Rc5StablePackage -and
        [int](Get-V71Rc5Property $stable 'versionCode' 'Stable target') -eq 71 -and
        [string](Get-V71Rc5Property $stable 'versionName' 'Stable target') -ceq
            '6.0.1-26.2-vivecraft-personal.12' -and
        [string](Get-V71Rc5Property $stable 'signerSha256' 'Stable target') -ceq
            $script:V71Rc5SignerSha256 -and
        $stableProtected) `
        'Stable target identity or protection contract drifted.'
    $boundary = Get-V71Rc5Property $Manifest 'evidenceBoundary' 'acceptance manifest'
    $rc4DiagnosticOnly = Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
        'rc4ReceiptsAreDiagnosticOnly' 'evidence boundary')
    $rc4CannotAcceptRc5 = Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary `
        'rc4ReceiptsMaySatisfyRc5Acceptance' 'evidence boundary')
    $stableUntouched = Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary `
        'stableTouched' 'evidence boundary')
    Require-V71Rc5Evidence ($rc4DiagnosticOnly -and $rc4CannotAcceptRc5 -and
        $stableUntouched) 'RC4/RC5 evidence boundary drifted.'
    return $true
}

function Assert-V71Rc5EmbeddedReceiptIdentity {
    param($Identity, [string] $ApkSha256, [int64] $ApkSizeBytes, [string] $Context)
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Identity 'package' $Context) -ceq
        $script:V71Rc5LabPackage -and
        [string](Get-V71Rc5Property $Identity 'forbiddenStablePackage' $Context) -ceq
        $script:V71Rc5StablePackage -and
        [int](Get-V71Rc5Property $Identity 'versionCode' $Context) -eq 71 -and
        [string](Get-V71Rc5Property $Identity 'versionName' $Context) -ceq
        $script:V71Rc5VersionName -and
        [string](Get-V71Rc5Property $Identity 'apkSha256' $Context) -ceq $ApkSha256 -and
        [int64](Get-V71Rc5Property $Identity 'apkSizeBytes' $Context) -eq $ApkSizeBytes -and
        [string](Get-V71Rc5Property $Identity 'coreSha256' $Context) -ceq
        $script:V71Rc5CoreSha256 -and
        [string](Get-V71Rc5Property $Identity 'veqSha256' $Context) -ceq
        $script:V71Rc5VeqSha256 -and
        [string](Get-V71Rc5Property $Identity 'signerSha256' $Context) -ceq
        $script:V71Rc5SignerSha256) "$Context does not bind the exact RC5 Lab identity."
}

function Assert-V71Rc5ManualReceiptIdentity {
    param($Identity, [string] $ApkSha256, [int64] $ApkSizeBytes)
    $context = 'manual receipt identity'
    $expectedNames = @(
        'package', 'forbiddenStablePackage', 'profile', 'versionCode', 'versionName', 'apkPath',
        'apkSha256', 'apkSizeBytes', 'coreVersion', 'coreSha256', 'coreSizeBytes',
        'veqVersion', 'veqSha256', 'veqSizeBytes', 'coreVeqPairSha256',
        'pojlibAarSha256', 'pojlibAarSizeBytes', 'signerSha256'
    )
    Assert-V71Rc5ExactPropertyNames $Identity $expectedNames $context
    Assert-V71Rc5EmbeddedReceiptIdentity $Identity $ApkSha256 $ApkSizeBytes $context
    Require-V71Rc5Evidence (
        [string](Get-V71Rc5Property $Identity 'profile' $context) -ceq '26.2' -and
        (Get-V71Rc5Property $Identity 'versionCode' $context) -is [int64] -and
        (Get-V71Rc5Property $Identity 'apkSizeBytes' $context) -is [int64] -and
        (Get-V71Rc5Property $Identity 'coreSizeBytes' $context) -is [int64] -and
        (Get-V71Rc5Property $Identity 'veqSizeBytes' $context) -is [int64] -and
        (Get-V71Rc5Property $Identity 'pojlibAarSizeBytes' $context) -is [int64] -and
        [string](Get-V71Rc5Property $Identity 'apkPath' $context) -ceq
            $script:V71Rc5LabApkRelativePath -and
        [string](Get-V71Rc5Property $Identity 'coreVersion' $context) -ceq
            $script:V71Rc5CoreVersion -and
        [int64](Get-V71Rc5Property $Identity 'coreSizeBytes' $context) -eq
            $script:V71Rc5CoreSizeBytes -and
        [string](Get-V71Rc5Property $Identity 'veqVersion' $context) -ceq
            $script:V71Rc5VeqVersion -and
        [int64](Get-V71Rc5Property $Identity 'veqSizeBytes' $context) -eq
            $script:V71Rc5VeqSizeBytes -and
        [string](Get-V71Rc5Property $Identity 'coreVeqPairSha256' $context) -ceq
            $script:V71Rc5PairSha256 -and
        [string](Get-V71Rc5Property $Identity 'pojlibAarSha256' $context) -ceq
            $script:V71Rc5PojlibSha256 -and
        [int64](Get-V71Rc5Property $Identity 'pojlibAarSizeBytes' $context) -eq
            $script:V71Rc5PojlibSizeBytes) `
        'Manual receipt does not bind the complete exact RC5 Lab identity.'
}

function Assert-V71Rc5ManualAcceptanceReceipt {
    param($Manual, [string] $ApkSha256, [int64] $ApkSizeBytes)
    $schema = Get-V71Rc5Property $Manual 'schemaVersion' 'manual receipt'
    Require-V71Rc5Evidence ($schema -is [int64] -and [int64]$schema -eq 1) `
        'RC5 manual receipt schemaVersion must be the JSON integer 1.'
    Require-V71Rc5Evidence (
        [string](Get-V71Rc5Property $Manual 'receiptType' 'manual receipt') -ceq
            'V71_RC5_MANUAL_VR_INTERACTION' -and
        [string](Get-V71Rc5Property $Manual 'status' 'manual receipt') -ceq
            'PASS_CONFIRMED_BY_USER') `
        'RC5 manual receipt type or explicit-user status is invalid.'

    $confirmation = Get-V71Rc5Property $Manual 'confirmation' 'manual receipt'
    Assert-V71Rc5ExactPropertyNames $confirmation `
        @('source', 'recordedBy', 'confirmedUtc', 'statement', 'userQuote') `
        'manual receipt confirmation'
    Require-V71Rc5Evidence (
        [string](Get-V71Rc5Property $confirmation 'source' 'manual receipt confirmation') -ceq
            $script:V71Rc5ManualConfirmationSource -and
        [string](Get-V71Rc5Property $confirmation 'recordedBy' 'manual receipt confirmation') -ceq
            $script:V71Rc5ManualRecordedBy) `
        'RC5 manual receipt is not sourced and recorded from an explicit user message.'
    foreach ($field in @('statement', 'userQuote')) {
        $value = Get-V71Rc5Property $confirmation $field 'manual receipt confirmation'
        Require-V71Rc5Evidence ($value -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$value)) `
            "RC5 manual receipt confirmation.$field is empty."
    }
    $confirmedText = Get-V71Rc5Property $confirmation 'confirmedUtc' 'manual receipt confirmation'
    Require-V71Rc5Evidence ($confirmedText -is [string] -and
        [string]$confirmedText -cmatch
            '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') `
        'RC5 manual receipt confirmedUtc must be a canonical UTC ISO-8601 timestamp.'
    $confirmed = ConvertTo-V71Rc5Timestamp $confirmedText 'manual receipt confirmation.confirmedUtc'
    Require-V71Rc5Evidence ($confirmed.Offset -eq [TimeSpan]::Zero) `
        'RC5 manual receipt confirmedUtc is not UTC.'

    $checks = Get-V71Rc5Property $Manual 'checks' 'manual receipt'
    Assert-V71Rc5ExactPropertyNames $checks $script:V71Rc5ManualCheckNames `
        'manual receipt checks'
    foreach ($name in $script:V71Rc5ManualCheckNames) {
        $value = Get-V71Rc5Property $checks $name 'manual receipt checks'
        Require-V71Rc5Evidence ($value -is [string] -and [string]$value -ceq 'PASS') `
            "RC5 manual receipt check is not PASS: $name."
    }
    Require-V71Rc5Evidence (
        [string](Get-V71Rc5Property $Manual 'exactCandidateRuntime' 'manual receipt') -ceq 'PASS' -and
        [string](Get-V71Rc5Property $Manual 'exactCandidateManualGate' 'manual receipt') -ceq 'PASS' -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $Manual 'stableTouched' 'manual receipt'))) `
        'RC5 manual receipt does not confirm the exact candidate or says Stable was touched.'
    Assert-V71Rc5ManualReceiptIdentity `
        (Get-V71Rc5Property $Manual 'labIdentity' 'manual receipt') $ApkSha256 $ApkSizeBytes
}

function Assert-V71Rc5Producer {
    param($ProducerLock, [string] $Name, [string] $ExpectedRelativePath,
        [string] $SuppliedPath, [string] $RepoRoot,
        [Collections.Generic.List[System.IDisposable]] $ReadLocks,
        [string] $ReviewedSha256 = '')
    $pathField = $Name + 'Path'
    $hashField = $Name + 'Sha256'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $ProducerLock $pathField 'producerScripts') -ceq
        $ExpectedRelativePath) "$Name producer path drifted."
    $expectedHash = ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $ProducerLock $hashField 'producerScripts') `
        "$Name producer SHA-256"
    $root = [IO.Path]::GetFullPath($RepoRoot)
    $expectedFull = [IO.Path]::GetFullPath((Join-Path $root $ExpectedRelativePath))
    $suppliedFull = [IO.Path]::GetFullPath($SuppliedPath)
    Require-V71Rc5Evidence ($suppliedFull -ceq $expectedFull) "$Name producer override is not the fixed RC5 path."
    $producerLock = Enter-V71Rc5ReadLock $suppliedFull "$Name producer"
    $ReadLocks.Add($producerLock)
    $actualHash = Get-V71Rc5TextSha256 $suppliedFull "$Name producer"
    Require-V71Rc5Evidence ($actualHash -ceq $expectedHash) "$Name producer drifted."
    if (-not [string]::IsNullOrWhiteSpace($ReviewedSha256)) {
        $reviewed = ConvertTo-V71Rc5Sha256 $ReviewedSha256 "$Name reviewed producer SHA-256"
        Require-V71Rc5Evidence ($actualHash -ceq $reviewed) `
            "$Name producer is not the reviewed fixed RC5 producer."
    }
    return $actualHash
}

function Assert-V71Rc5Provenance {
    param($Provenance, [string] $Context)
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Provenance 'schemaVersion' $Context) -eq 1) `
        "$Context schema drifted."
    $null = ConvertTo-V71Rc5Timestamp `
        (Get-V71Rc5Property $Provenance 'verifiedUtc' $Context) "$Context verifiedUtc"
    foreach ($field in @('installedIdentityMatched', 'baseApkMatched',
            'persistentCoreMatched', 'persistentVeqMatched', 'allMatched')) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactTrue `
            (Get-V71Rc5Property $Provenance $field $Context)) "$Context failed $field."
    }
}

function Assert-V71Rc5RuntimeBinding {
    param($Binding, [int] $InitialPid, [int] $Round, [string] $ProducerSha256)
    $context = "memory soak $Round runtime binding"
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Binding 'schemaVersion' $context) -eq 1 -and
        [string](Get-V71Rc5Property $Binding 'receiptType' $context) -ceq
            'V71_RC5_MEMORY_SOAK_RUNTIME_BINDING' -and
        [string](Get-V71Rc5Property $Binding 'result' $context) -ceq 'PASS') `
        "$context identity drifted."
    $start = Get-V71Rc5Property $Binding 'start' $context
    $final = Get-V71Rc5Property $Binding 'final' $context
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $start 'schemaVersion' "$context start") -eq 1 -and
        [string](Get-V71Rc5Property $start 'receiptType' "$context start") -ceq
            'V71_RC5_MEMORY_SOAK_RUNTIME_START' -and
        [string](Get-V71Rc5Property $start 'result' "$context start") -ceq 'PASS') `
        "$context start receipt is not an exact PASS receipt."
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $final 'schemaVersion' "$context final") -eq 1 -and
        [string](Get-V71Rc5Property $final 'receiptType' "$context final") -ceq
            'V71_RC5_MEMORY_SOAK_RUNTIME_FINAL' -and
        [string](Get-V71Rc5Property $final 'result' "$context final") -ceq 'PASS') `
        "$context final receipt is not an exact PASS receipt."
    $startPid = [int](Get-V71Rc5Property $start 'pid' "$context start")
    $finalPid = [int](Get-V71Rc5Property $final 'pid' "$context final")
    $startTicks = [uint64](Get-V71Rc5Property $start 'processStartTicks' "$context start")
    $finalTicks = [uint64](Get-V71Rc5Property $final 'processStartTicks' "$context final")
    Require-V71Rc5Evidence ($startPid -eq $InitialPid -and $finalPid -eq $InitialPid -and
        $startTicks -gt 0 -and $finalTicks -eq $startTicks) `
        "$context start/final receipts are not the same process incarnation."
    $startProducer = ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $start 'producerSha256' "$context start") `
        "$context start producer SHA-256"
    Require-V71Rc5Evidence ($startProducer -ceq $ProducerSha256) `
        "$context start receipt is detached from the locked memory producer."
    foreach ($entry in @(
        ,@($start, 'exactPidAlive', "$context start")
        ,@($start, 'gameJvmAlive', "$context start")
        ,@($start, 'provenanceMatched', "$context start")
        ,@($start, 'exactJvmMemoryLineObserved', "$context start")
        ,@($start, 'launcherResourceReleaseAppliedObserved', "$context start")
        ,@($start, 'launcherLogTemporallyBoundToProcess', "$context start")
        ,@($start, 'launcherMarkerTemporallyBoundToProcess', "$context start")
        ,@($start, 'runtimeFenceBeforeStartProvenance', "$context start")
        ,@($start, 'runtimeFenceAfterStartProvenance', "$context start")
        ,@($start, 'expectedGameLogPathMatched', "$context start")
        ,@($start, 'expectedGameLogRegularAndNonEmpty', "$context start")
        ,@($start, 'expectedGameLogSameFile', "$context start")
        ,@($start, 'expectedGameLogTemporallyBoundToProcess', "$context start")
        ,@($start, 'expectedGameLogFresh', "$context start")
        ,@($final, 'sameProcessIncarnation', "$context final")
        ,@($final, 'exactPidAlive', "$context final")
        ,@($final, 'gameJvmAlive', "$context final")
        ,@($final, 'provenanceMatched', "$context final")
        ,@($final, 'startJvmMemoryObservationCarriedForward', "$context final")
        ,@($final, 'startLauncherMarkerCarriedForward', "$context final")
        ,@($final, 'runtimeFenceBeforeFinalProvenance', "$context final")
        ,@($final, 'runtimeFenceAfterFinalProvenance', "$context final")
        ,@($final, 'expectedGameLogPathMatched', "$context final")
        ,@($final, 'expectedGameLogRegularAndNonEmpty', "$context final")
        ,@($final, 'expectedGameLogSameFile', "$context final")
        ,@($final, 'expectedGameLogTemporallyBoundToProcess', "$context final")
        ,@($final, 'expectedGameLogFresh', "$context final")
    )) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactTrue `
            (Get-V71Rc5Property $entry[0] $entry[1] $entry[2])) `
            "$context failed $($entry[1])."
    }
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $start 'xmsMiB' "$context start") -eq 512 -and
        [int](Get-V71Rc5Property $start 'xmxMiB' "$context start") -eq 1536 -and
        [string](Get-V71Rc5Property $start 'xmxSource' "$context start") -ceq 'auto' -and
        [int](Get-V71Rc5Property $start 'jvmMemoryLineCount' "$context start") -eq 1 -and
        [int64](Get-V71Rc5Property $start 'launcherLogSizeBytes' "$context start") -gt 0 -and
        [int](Get-V71Rc5Property $start 'launcherReleaseAppliedMarkerCount' "$context start") -ge 1 -and
        [int](Get-V71Rc5Property $start 'launcherReleaseDegradedMarkerCount' "$context start") -eq 0) `
        "$context start Xmx or launcher marker observation drifted."
    foreach ($receiptAndLabel in @(
        ,@($start, "$context start")
        ,@($final, "$context final")
    )) {
        $gameLogReceipt = $receiptAndLabel[0]
        $gameLogContext = [string]$receiptAndLabel[1]
        Require-V71Rc5Evidence (
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $gameLogReceipt `
                'expectedMinecraftVersionObserved' $gameLogContext)) -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $gameLogReceipt `
                'expectedVivecraftVersionObserved' $gameLogContext)) -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $gameLogReceipt `
                'expectedVeqVersionObserved' $gameLogContext))) `
            "$gameLogContext did not observe every expectedGameLog identity field."
        $modifiedEpoch = ConvertTo-V71Rc5FiniteNumber `
            (Get-V71Rc5Property $gameLogReceipt 'expectedGameLogModifiedEpochSeconds' `
                $gameLogContext) "$gameLogContext expectedGameLogModifiedEpochSeconds"
        $observedEpoch = ConvertTo-V71Rc5FiniteNumber `
            (Get-V71Rc5Property $gameLogReceipt 'expectedGameLogObservedDeviceEpochSeconds' `
                $gameLogContext) "$gameLogContext expectedGameLogObservedDeviceEpochSeconds"
        $receiptProcessEpoch = ConvertTo-V71Rc5FiniteNumber `
            (Get-V71Rc5Property $gameLogReceipt 'processStartEpochSeconds' $gameLogContext) `
            "$gameLogContext processStartEpochSeconds"
        Require-V71Rc5Evidence ($modifiedEpoch -gt 0 -and $observedEpoch -gt 0 -and
            $modifiedEpoch -le ($observedEpoch + 2) -and
            $modifiedEpoch -ge ($receiptProcessEpoch - 3)) `
            "$gameLogContext expectedGameLog timestamps are detached from the process."
    }
    Require-V71Rc5Evidence (Test-V71Rc5ExactFalse `
        (Get-V71Rc5Property $final 'finalLogcatMarkerRequired' "$context final")) `
        "$context incorrectly requires a final logcat marker."
    $startObserved = Get-V71Rc5Property $start 'observedUtc' "$context start"
    $finalObserved = Get-V71Rc5Property $final 'observedUtc' "$context final"
    $startUtc = ConvertTo-V71Rc5Timestamp $startObserved "$context start observedUtc"
    $finalUtc = ConvertTo-V71Rc5Timestamp $finalObserved "$context final observedUtc"
    Require-V71Rc5Evidence ($finalUtc -gt $startUtc) "$context timestamps are not ordered."
    $startEpoch = ConvertTo-V71Rc5FiniteNumber `
        (Get-V71Rc5Property $start 'processStartEpochSeconds' "$context start") `
        "$context start processStartEpochSeconds"
    $finalEpoch = ConvertTo-V71Rc5FiniteNumber `
        (Get-V71Rc5Property $final 'processStartEpochSeconds' "$context final") `
        "$context final processStartEpochSeconds"
    $launcherLogEpoch = ConvertTo-V71Rc5FiniteNumber `
        (Get-V71Rc5Property $start 'launcherLogModifiedEpochSeconds' "$context start") `
        "$context start launcherLogModifiedEpochSeconds"
    $launcherMarkerEpoch = ConvertTo-V71Rc5FiniteNumber `
        (Get-V71Rc5Property $start 'launcherAppliedMarkerEpochSeconds' "$context start") `
        "$context start launcherAppliedMarkerEpochSeconds"
    Require-V71Rc5Evidence ($startEpoch -gt 0 -and [math]::Abs($finalEpoch - $startEpoch) -le 2.0 -and
        $launcherLogEpoch -ge [math]::Floor($startEpoch - 3.0) -and
        $launcherMarkerEpoch -ge ($startEpoch - 3.0)) `
        "$context process/log/marker temporal anchors are detached."
    $boundary = Get-V71Rc5Property $Binding 'evidenceBoundary' $context
    Require-V71Rc5Evidence ((Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'logcatMarkerCapturedOnlyAtStart' "$context evidence boundary")) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary 'finalLogcatMarkerRequired' `
            "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'processStartTicksPersistedForPidReuseDefense' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'processStartEpochPersistedForLogBinding' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'producerHashCapturedAtLaunch' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'producerFileReadLockedForRun' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'launcherMarkerTemporallyBoundToProcess' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'launcherLogTemporallyBoundToProcess' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'gameJvmLivenessObservedAtBoundedFencesAndSamples' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'expectedProfileGameLogPathFixed' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'expectedGameLogIdentityCheckedAtStartAndFinal' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'expectedGameLogFreshnessCheckedEverySample' "$context evidence boundary")) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary `
            'expectedGameLogEvidenceOnlyBooleansAndTimestamps' "$context evidence boundary")) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary `
            'continuousGameJvmLivenessClaimed' "$context evidence boundary"))) `
        "$context evidence boundary drifted."
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted', 'deviceSerialPersisted',
            'accountDataPersisted', 'hostAbsolutePathsPersisted')) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactFalse `
            (Get-V71Rc5Property $boundary $field "$context evidence boundary")) `
            "$context persisted forbidden evidence: $field."
    }
    return [pscustomobject]@{
        ProcessStartTicks = $startTicks; StartObservedUtc = $startUtc; FinalObservedUtc = $finalUtc
    }
}

function Assert-V71Rc5MemorySamples {
    param($Summary, [string] $SamplesText, [int] $Round)
    $context = "memory soak $Round"
    $lines = @($SamplesText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require-V71Rc5Evidence ($lines.Count -eq 19 -and
        $lines.Count -eq [int](Get-V71Rc5Property $Summary 'samples' "$context summary")) `
        "$context raw sample count does not match its summary."
    $expectedPid = [int](Get-V71Rc5Property $Summary 'initialPid' "$context summary")
    $startedValue = Get-V71Rc5Property $Summary 'startedUtc' "$context summary"
    $started = ConvertTo-V71Rc5Timestamp $startedValue "$context startedUtc"
    $metrics = @('totalPssKib', 'totalRssKib', 'javaHeapKib', 'nativeHeapKib',
        'graphicsKib', 'vmRssKib', 'vmSwapKib', 'memAvailableKib', 'swapFreeKib')
    $samples = [Collections.Generic.List[object]]::new()
    $previousElapsed = -1.0; $previousTimestamp = [DateTimeOffset]::MinValue
    for ($index = 0; $index -lt $lines.Count; $index++) {
        try { $raw = $lines[$index] | ConvertFrom-Json -Depth 10 -DateKind String }
        catch { throw "[V71_RC5_STABLE_EVIDENCE] $context sample $index is invalid JSON." }
        $elapsed = ConvertTo-V71Rc5FiniteNumber `
            (Get-V71Rc5Property $raw 'elapsedMinutes' "$context sample $index") `
            "$context sample $index elapsedMinutes"
        $timestampValue = Get-V71Rc5Property $raw 'timestampUtc' "$context sample $index"
        $timestamp = ConvertTo-V71Rc5Timestamp $timestampValue "$context sample $index timestampUtc"
        Require-V71Rc5Evidence ([math]::Abs((($timestamp - $started).TotalMinutes) - $elapsed) -le 0.05) `
            "$context sample $index timestamp and elapsedMinutes identify different captures."
        Require-V71Rc5Evidence ($elapsed -gt $previousElapsed -and $timestamp -gt $previousTimestamp) `
            "$context sample order is not strictly monotonic."
        $previousElapsed = $elapsed; $previousTimestamp = $timestamp
        Require-V71Rc5Evidence ([int](Get-V71Rc5Property $raw 'pid' "$context sample $index") -eq
                $expectedPid -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $raw 'pidStable' "$context sample $index")) -and
            [string](Get-V71Rc5Property $raw 'focus' "$context sample $index") -ceq 'focused' -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $raw 'gameJvmAlive' "$context sample $index"))) `
            "$context sample $index lost PID, focus, or the game JVM."
        $normalized = [ordered]@{ elapsedMinutes = $elapsed; timestampUtc = $timestamp }
        foreach ($metric in $metrics) {
            $normalized[$metric] = ConvertTo-V71Rc5FiniteNumber `
                (Get-V71Rc5Property $raw $metric "$context sample $index") `
                "$context sample $index $metric"
        }
        Require-V71Rc5Evidence ($normalized.totalPssKib -gt 0 -and $normalized.totalRssKib -gt 0 -and
            $normalized.vmRssKib -gt 0 -and $normalized.memAvailableKib -gt 0) `
            "$context sample $index contains impossible zero process/system memory."
        $samples.Add([pscustomobject]$normalized)
    }
    Require-V71Rc5Evidence ($samples[0].elapsedMinutes -le 1.0 -and
        $samples[-1].elapsedMinutes -ge 90.0) "$context raw samples do not span 90 minutes."
    $postWarm = @($samples | Where-Object elapsedMinutes -ge 15.0)
    $lastThirty = @($samples | Where-Object elapsedMinutes -ge 60.0)
    Require-V71Rc5Evidence ($postWarm.Count -ge 16 -and $lastThirty.Count -ge 7) `
        "$context raw analysis windows are incomplete."
    $values = [ordered]@{
        maxPssMib = [math]::Round((($samples | Measure-Object totalPssKib -Maximum).Maximum / 1024.0), 3)
        maxRssMib = [math]::Round((($samples | Measure-Object vmRssKib -Maximum).Maximum / 1024.0), 3)
        maxProcessSwapMib = [math]::Round((($samples | Measure-Object vmSwapKib -Maximum).Maximum / 1024.0), 3)
        minMemAvailableMib = [math]::Round((($samples | Measure-Object memAvailableKib -Minimum).Minimum / 1024.0), 3)
        minSwapFreeMib = [math]::Round((($samples | Measure-Object swapFreeKib -Minimum).Minimum / 1024.0), 3)
        postWarmPssSlopeMibPerMinute = Get-V71Rc5PssSlope $postWarm "$context post-warm"
        lastThirtyMinutesGrowthMib = [math]::Round(
            ($lastThirty[-1].totalPssKib - $lastThirty[0].totalPssKib) / 1024.0, 3)
    }
    foreach ($name in $values.Keys) {
        Assert-V71Rc5RoundedEqual (Get-V71Rc5Property $Summary $name "$context summary") `
            ([double]$values[$name]) "$context $name"
    }
    Require-V71Rc5Evidence ($values.maxPssMib -le 2457.6 -and $values.maxRssMib -le 2457.6 -and
        $values.maxProcessSwapMib -le 512.0 -and $values.postWarmPssSlopeMibPerMinute -le 2.0 -and
        $values.lastThirtyMinutesGrowthMib -le 128.0) `
        "$context recomputed raw metrics fail a Stable guardrail."
    return [pscustomobject]@{ StartedUtc = $started; FirstUtc = $samples[0].timestampUtc; LastUtc = $samples[-1].timestampUtc }
}

function Assert-V71Rc5MemorySoak {
    param($Lock, [int] $Round, [string] $EvidenceRoot, [string] $ProducerSha256,
        [string] $ApkSha256, [int64] $ApkSizeBytes,
        [Collections.Generic.List[System.IDisposable]] $ReadLocks)
    $lockContext = "memorySoaks[$Round]"
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Lock 'round' $lockContext) -eq $Round -and
        [string](Get-V71Rc5Property $Lock 'status' $lockContext) -ceq 'PASS') `
        "Memory soak $Round is not explicitly PASS."
    Require-V71Rc5Evidence ((ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $Lock 'producerSha256' $lockContext) "Memory soak $Round producer") -ceq
        $ProducerSha256) "Memory soak $Round producer drifted."
    Require-V71Rc5Evidence ((Test-V71Rc5ExactTrue (Get-V71Rc5Property $Lock `
            'requiresStartRuntimeReceipt' $lockContext)) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $Lock 'requiresSamePidFinalReceipt' $lockContext))) `
        "Memory soak $Round runtime-attestation requirements drifted."
    $summaryFile = Resolve-V71Rc5EvidenceFile $EvidenceRoot `
        (Get-V71Rc5Property $Lock 'summaryPath' $lockContext) `
        (Get-V71Rc5Property $Lock 'summarySha256' $lockContext) `
        "memory soak $Round summary" 'artifacts/memory/'
    $ReadLocks.Add($summaryFile.ReadLock)
    $samplesFile = Resolve-V71Rc5EvidenceFile $EvidenceRoot `
        (Get-V71Rc5Property $Lock 'samplesPath' $lockContext) `
        (Get-V71Rc5Property $Lock 'samplesSha256' $lockContext) `
        "memory soak $Round samples" 'artifacts/memory/'
    $ReadLocks.Add($samplesFile.ReadLock)
    $summary = Read-V71Rc5JsonText $summaryFile.Text "memory soak $Round summary"
    $context = "memory soak $Round summary"
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $summary 'schemaVersion' $context) -eq 2 -and
        [string](Get-V71Rc5Property $summary 'package' $context) -ceq $script:V71Rc5LabPackage -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $summary 'producerSha256' $context) `
            "memory soak $Round summary producer") -ceq $ProducerSha256 -and
        [int](Get-V71Rc5Property $summary 'requestedDurationMinutes' $context) -eq 90 -and
        [int](Get-V71Rc5Property $summary 'intervalSeconds' $context) -eq 300 -and
        [int](Get-V71Rc5Property $summary 'samples' $context) -eq 19 -and
        [int](Get-V71Rc5Property $summary 'minimumExpectedSamples' $context) -eq 19 -and
        [int](Get-V71Rc5Property $summary 'completeMetricSamples' $context) -eq 19) `
        "Memory soak $Round summary schema or fixed protocol drifted."
    $initialPid = [int](Get-V71Rc5Property $summary 'initialPid' $context)
    Require-V71Rc5Evidence ($initialPid -gt 0) "Memory soak $Round has no initial PID."
    foreach ($field in @('pidStable', 'focusStayedOnLab', 'gameJvmStayedAlive')) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactTrue (Get-V71Rc5Property $summary $field $context)) `
            "Memory soak $Round failed $field."
    }
    Assert-V71Rc5Provenance (Get-V71Rc5Property $summary 'provenance' $context) `
        "memory soak $Round start provenance"
    Assert-V71Rc5Provenance (Get-V71Rc5Property $summary 'finalProvenance' $context) `
        "memory soak $Round final provenance"
    $binding = Assert-V71Rc5RuntimeBinding `
        (Get-V71Rc5Property $summary 'runtimeBinding' $context) $initialPid $Round $ProducerSha256
    $acceptance = Get-V71Rc5Property $summary 'acceptance' $context
    foreach ($field in @('completedDuration', 'sampleCountComplete', 'allRequiredMetricsPresent',
            'focusStayedOnLab', 'gameJvmStayedAlive', 'postWarmSamplesComplete',
            'lastThirtySamplesComplete', 'maxPssAtMost2457Point6Mib',
            'maxRssAtMost2457Point6Mib', 'processSwapAtMost512Mib',
            'slopeAtMost2MibPerMinute', 'lastThirtyGrowthAtMost128Mib', 'passed')) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactTrue `
            (Get-V71Rc5Property $acceptance $field "memory soak $Round acceptance")) `
            "Memory soak $Round acceptance failed $field."
    }
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $summary 'deviceInvocations' $context) -gt 0) `
        "Memory soak $Round contains no device-read evidence."
    $sampleWindow = Assert-V71Rc5MemorySamples $summary $samplesFile.Text $Round
    Require-V71Rc5Evidence ($binding.StartObservedUtc -ge $sampleWindow.StartedUtc -and
        $binding.StartObservedUtc -le $sampleWindow.FirstUtc -and
        $binding.FinalObservedUtc -ge $sampleWindow.LastUtc) `
        "Memory soak $Round runtime binding is not temporally attached to its samples."
    return [pscustomobject]@{
        Round = $Round; StartedUtc = $sampleWindow.StartedUtc; InitialPid = $initialPid
        ProcessStartTicks = $binding.ProcessStartTicks; SummarySha256 = $summaryFile.Sha256
        SamplesSha256 = $samplesFile.Sha256
    }
}

function Get-V71Rc5ProducerLineageDigest {
    param([object[]] $Files)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("scheme=$script:V71Rc5PerformanceProducerHashScheme")
    foreach ($file in $Files) {
        $name = [string](Get-V71Rc5Property $file 'Name' 'performance producer lineage file')
        $path = [string](Get-V71Rc5Property $file 'RelativePath' 'performance producer lineage file')
        $sha = ConvertTo-V71Rc5Sha256 `
            (Get-V71Rc5Property $file 'Sha256' 'performance producer lineage file') `
            "performance producer lineage file $name SHA-256"
        $lines.Add(('{0}|{1}|{2}' -f $name, $path, $sha))
    }
    $payload = ($lines -join "`n") + "`n"
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($payload)))
}

function Assert-V71Rc5LifecycleProducerLineage {
    param($Lineage, [string] $ExpectedLifecycleProducerSha256, [string] $Context)
    Assert-V71Rc5ExactPropertyNames $Lineage `
        @('schemaVersion', 'hashScheme', 'digestSha256', 'files') $Context
    $schema = Get-V71Rc5Property $Lineage 'schemaVersion' $Context
    Require-V71Rc5Evidence ($schema -is [int64] -and [int64]$schema -eq 1) `
        "$Context schemaVersion must be the JSON integer 1."
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Lineage 'hashScheme' $Context) -ceq
        $script:V71Rc5PerformanceProducerHashScheme) "$Context hash scheme drifted."

    $expected = @(
        [pscustomobject]@{
            Name = 'lifecycle-orchestrator'
            RelativePath = 'scripts/quest-v71-lab-lifecycle-recovery-rc5.ps1'
            Sha256 = $ExpectedLifecycleProducerSha256
        }
        [pscustomobject]@{
            Name = 'autoplay-harness'
            RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1'
            Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['autoplay-harness']
        }
    )
    $files = @(Get-V71Rc5Property $Lineage 'files' $Context)
    Require-V71Rc5Evidence ($files.Count -eq $expected.Count) `
        "$Context must contain exactly two reviewed producer files."
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $actual = $files[$index]
        $fileContext = "$Context file[$index]"
        Assert-V71Rc5ExactPropertyNames $actual @('name', 'relativePath', 'sha256') $fileContext
        $name = [string](Get-V71Rc5Property $actual 'name' $fileContext)
        $relative = [string](Get-V71Rc5Property $actual 'relativePath' $fileContext)
        $sha = ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $actual 'sha256' $fileContext) `
            "$fileContext SHA-256"
        Require-V71Rc5Evidence ($name -ceq $expected[$index].Name -and
            $relative -ceq $expected[$index].RelativePath -and
            $sha -ceq $expected[$index].Sha256) `
            "$fileContext drifted from the reviewed producer closure."
    }
    $digest = ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $Lineage 'digestSha256' $Context) "$Context digest"
    Require-V71Rc5Evidence ($digest -ceq (Get-V71Rc5ProducerLineageDigest $files)) `
        "$Context digest does not match its producer files."
    return $digest
}

function Assert-V71Rc5PerformanceLineage {
    param($Lineage, [string] $ExpectedProducerSha256, [string] $Context)
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Lineage 'SchemaVersion' $Context) -eq 1 -and
        [string](Get-V71Rc5Property $Lineage 'HashScheme' $Context) -ceq
            $script:V71Rc5PerformanceProducerHashScheme) "$Context schema/hash scheme drifted."
    $expected = @(
        [pscustomobject]@{ Name = 'orchestrator'; RelativePath = 'scripts/quest-v71-rc4-rc5-ab.ps1'; Sha256 = $ExpectedProducerSha256 }
        [pscustomobject]@{ Name = 'pair-harness'; RelativePath = 'scripts/quest-v71-lab-pair-rc5.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['pair-harness'] }
        [pscustomobject]@{ Name = 'core-canary-harness'; RelativePath = 'scripts/quest-vivecraft-core-canary-rc5.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['core-canary-harness'] }
        [pscustomobject]@{ Name = 'veq-lab-harness'; RelativePath = 'scripts/quest-veq-lab-rc5.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['veq-lab-harness'] }
        [pscustomobject]@{ Name = 'world-reset-harness'; RelativePath = 'scripts/reset-lab-benchmark-world.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['world-reset-harness'] }
        [pscustomobject]@{ Name = 'autoplay-harness'; RelativePath = 'scripts/run-vivecraft-local-autoplay.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['autoplay-harness'] }
        [pscustomobject]@{ Name = 'vrapi-benchmark-harness'; RelativePath = 'scripts/quest-vrapi-pid-benchmark.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['vrapi-benchmark-harness'] }
        [pscustomobject]@{ Name = 'apk-verifier'; RelativePath = 'scripts/verify-dev-apk.ps1'; Sha256 = $script:V71Rc5ExpectedPerformanceDependencyHashes['apk-verifier'] }
    )
    $files = @(Get-V71Rc5Property $Lineage 'Files' $Context)
    Require-V71Rc5Evidence ($files.Count -eq $expected.Count) `
        "$Context does not contain the complete reviewed producer closure."
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $actual = $files[$index]
        $name = [string](Get-V71Rc5Property $actual 'Name' "$Context file[$index]")
        $relative = [string](Get-V71Rc5Property $actual 'RelativePath' "$Context file[$index]")
        $sha = ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $actual 'Sha256' `
            "$Context file[$index]") "$Context file[$index] SHA-256"
        Require-V71Rc5Evidence ($name -ceq $expected[$index].Name -and
            $relative -ceq $expected[$index].RelativePath -and
            $sha -ceq $expected[$index].Sha256) `
            "$Context file[$index] drifted from the reviewed producer closure."
    }
    $digest = ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $Lineage 'DigestSha256' $Context) `
        "$Context digest"
    Require-V71Rc5Evidence ($digest -ceq (Get-V71Rc5ProducerLineageDigest $files)) `
        "$Context digest does not match its producer files."
    return $digest
}

function Assert-V71Rc5PerformanceManifestAndComparison {
    param($Manifest, $Comparison, [string] $ExpectedProducerSha256, [string] $ApkSha256)
    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Manifest 'SchemaVersion' 'A/B manifest') -eq 2 -and
        [string](Get-V71Rc5Property $Manifest 'Package' 'A/B manifest') -ceq $script:V71Rc5LabPackage -and
        [string](Get-V71Rc5Property $Manifest 'ForbiddenStablePackage' 'A/B manifest') -ceq
            $script:V71Rc5StablePackage -and
        [string](Get-V71Rc5Property $Manifest 'Profile' 'A/B manifest') -ceq '26.2' -and
        [string](Get-V71Rc5Property $Manifest 'World' 'A/B manifest') -ceq 'FPS-Stress-Test') `
        'RC4-to-RC5 A/B manifest identity drifted.'
    Require-V71Rc5Evidence ((ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $Manifest 'WorldMasterSha256' 'A/B manifest') 'A/B world SHA-256') -ceq
        $script:V71Rc5WorldSha256) 'A/B benchmark world drifted.'
    $visualState = Get-V71Rc5Property $Manifest 'VisualState' 'A/B manifest'
    $optionsSha256 = ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $visualState 'OptionsSha256' 'A/B visual state') `
        'A/B options.txt SHA-256'
    $resourcePacksSha256 = ConvertTo-V71Rc5Sha256 `
        (Get-V71Rc5Property $visualState 'ResourcePacksFingerprintSha256' `
            'A/B visual state') 'A/B resource-pack fingerprint SHA-256'
    Require-V71Rc5Evidence (Test-V71Rc5ExactTrue `
        (Get-V71Rc5Property $visualState 'MustRemainIdenticalForAllSixRounds' `
            'A/B visual state')) `
        'A/B does not lock identical options/resource-pack state for all six rounds.'
    $installed = Get-V71Rc5Property $Manifest 'InstalledApk' 'A/B manifest'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $installed 'Package' 'A/B installed APK') -ceq
            $script:V71Rc5LabPackage -and
        [string](Get-V71Rc5Property $installed 'VersionCode' 'A/B installed APK') -ceq '71' -and
        [string](Get-V71Rc5Property $installed 'VersionName' 'A/B installed APK') -ceq
            $script:V71Rc5VersionName -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $installed 'Sha256' 'A/B installed APK') `
            'A/B installed APK SHA-256') -ceq $ApkSha256 -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $installed 'SignerSha256' 'A/B installed APK') `
            'A/B installed signer SHA-256') -ceq $script:V71Rc5SignerSha256) `
        'A/B installed APK identity drifted.'
    $a = Get-V71Rc5Property $Manifest 'ConditionA' 'A/B manifest'
    $b = Get-V71Rc5Property $Manifest 'ConditionB' 'A/B manifest'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $a 'Name' 'A/B condition A') -ceq 'RC4' -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $a 'CoreSha256' 'A/B condition A') `
            'A/B RC4 Core SHA-256') -ceq $script:V71Rc4CoreSha256 -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $a 'VeqSha256' 'A/B condition A') `
            'A/B RC4 VEQ SHA-256') -ceq $script:V71Rc4VeqSha256 -and
        [string](Get-V71Rc5Property $b 'Name' 'A/B condition B') -ceq 'RC5' -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $b 'CoreSha256' 'A/B condition B') `
            'A/B RC5 Core SHA-256') -ceq $script:V71Rc5CoreSha256 -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $b 'VeqSha256' 'A/B condition B') `
            'A/B RC5 VEQ SHA-256') -ceq $script:V71Rc5VeqSha256) `
        'A/B RC4/RC5 condition payloads drifted.'
    $lineageDigest = Assert-V71Rc5PerformanceLineage `
        (Get-V71Rc5Property $Manifest 'ProducerLineage' 'A/B manifest') `
        $ExpectedProducerSha256 'A/B manifest producer lineage'
    Require-V71Rc5Evidence ((@(Get-V71Rc5Property $Manifest 'Order' 'A/B manifest') -join '-') -ceq
            'A1-B1-B2-A2-A3-B3' -and
        [int](Get-V71Rc5Property $Manifest 'WarmupSeconds' 'A/B manifest') -ge 300 -and
        [int](Get-V71Rc5Property $Manifest 'WarmupSeconds' 'A/B manifest') -le 900 -and
        [int](Get-V71Rc5Property $Manifest 'PreflightSeconds' 'A/B manifest') -eq 10 -and
        [int](Get-V71Rc5Property $Manifest 'SampleSeconds' 'A/B manifest') -eq 60 -and
        [int](Get-V71Rc5Property $Manifest 'MaximumPairAttempts' 'A/B manifest') -ge 1 -and
        [int](Get-V71Rc5Property $Manifest 'MaximumPairAttempts' 'A/B manifest') -le 3) `
        'A/B order or timing contract drifted.'
    $gates = Get-V71Rc5Property $Manifest 'Gates' 'A/B manifest'
    foreach ($entry in @(
        ,@('MinimumCoveragePercent', 95.0)
        ,@('MinimumLevel4Percent', 95.0)
        ,@('CpuLevel', 4.0)
        ,@('GpuLevel', 4.0)
        ,@('MaximumStartTemperatureDeltaC', 1.0)
        ,@('MaximumThermalPathDeltaC', 1.0)
        ,@('MaximumRefreshDistributionDistancePercent', 5.0)
        ,@('MaximumRefreshMeanDeltaHz', 0.5)
        ,@('MaximumRefreshModeDeltaHz', 0.5)
        ,@('MaximumRefreshTransitionDelta', 1.0)
        ,@('MaximumPersistentRegressionPercent', 2.0)
    )) {
        Require-V71Rc5Evidence ((ConvertTo-V71Rc5FiniteNumber `
            (Get-V71Rc5Property $gates $entry[0] 'A/B gates') "A/B gate $($entry[0])") -eq
            [double]$entry[1]) "A/B gate $($entry[0]) drifted."
    }
    $lease = Get-V71Rc5Property $Manifest 'PerformanceLevelLease' 'A/B manifest'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $lease 'Scope' 'A/B lease') -ceq
            'Lab campaign only' -and
        [int](Get-V71Rc5Property $lease 'TargetCpuLevel' 'A/B lease') -eq 4 -and
        [int](Get-V71Rc5Property $lease 'TargetGpuLevel' 'A/B lease') -eq 4 -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $lease 'ApplyAfterWorldReady' 'A/B lease')) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $lease 'VerifyBeforeWarmup' 'A/B lease')) -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $lease 'RestoreEveryRoundAndOuterFinally' 'A/B lease')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $lease 'RefreshPropertiesModified' 'A/B lease')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $lease 'AdaptivePropertiesModified' 'A/B lease'))) `
        'A/B performance-level lease drifted.'
    foreach ($kind in @('Cpu', 'Gpu')) {
        $set = Get-V71Rc5Property $lease "Original${kind}LevelSet" 'A/B lease'
        $value = Get-V71Rc5Property $lease "Original${kind}Level" 'A/B lease'
        if (Test-V71Rc5ExactTrue $set) {
            $level = ConvertTo-V71Rc5FiniteNumber $value "A/B original $kind level"
            Require-V71Rc5Evidence ($level -le 99 -and [math]::Floor($level) -eq $level) `
                "A/B original $kind level is invalid."
        } else {
            Require-V71Rc5Evidence ((Test-V71Rc5ExactFalse $set) -and $null -eq $value) `
                "A/B unset original $kind level is invalid."
        }
    }
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $Manifest 'QgoContract' 'A/B manifest') -ceq
            'Dynamic refresh; CPU/GPU 4/4; application requests neither refresh nor performance hint' -and
        [string](Get-V71Rc5Property $Manifest 'FinalState' 'A/B manifest') -ceq
            'Lab stopped on exact RC5 Core+VEQ pair; original CPU/GPU levels restored' -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $Manifest 'StableTouched' 'A/B manifest')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $Manifest 'RawLogsPersisted' 'A/B manifest'))) `
        'A/B final-state or sensitive-evidence contract drifted.'

    Require-V71Rc5Evidence ([int](Get-V71Rc5Property $Comparison 'SchemaVersion' 'A/B comparison') -eq 1 -and
        [string](Get-V71Rc5Property $Comparison 'Result' 'A/B comparison') -ceq
            'PASS_RC5_NO_PERSISTENT_REGRESSION' -and
        (Test-V71Rc5ExactTrue (Get-V71Rc5Property $Comparison 'PerformanceGatePassed' 'A/B comparison')) -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $Comparison 'InstalledApkSha256' 'A/B comparison') `
            'A/B comparison APK SHA-256') -ceq $ApkSha256 -and
        (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $Comparison 'ProducerLineageSha256' 'A/B comparison') `
            'A/B comparison lineage SHA-256') -ceq $lineageDigest -and
        (@(Get-V71Rc5Property $Comparison 'Order' 'A/B comparison') -join '-') -ceq
            'A1-B1-B2-A2-A3-B3') 'A/B comparison is detached or did not pass the exact RC5 gate.'
    $pairs = @(Get-V71Rc5Property $Comparison 'Pairs' 'A/B comparison')
    Require-V71Rc5Evidence ($pairs.Count -eq 3) 'A/B comparison does not contain three pairs.'
    $numbers = @(); $passes = 0
    foreach ($pair in $pairs) {
        $numbers += [int](Get-V71Rc5Property $pair 'Pair' 'A/B pair')
        Require-V71Rc5Evidence (Test-V71Rc5ExactTrue `
            (Get-V71Rc5Property $pair 'Comparable' 'A/B pair')) 'An A/B pair is not comparable.'
        if (Test-V71Rc5ExactTrue (Get-V71Rc5Property $pair 'GuardrailsPass' 'A/B pair')) { $passes++ }
    }
    Require-V71Rc5Evidence ((@($numbers | Sort-Object -Unique) -join '-') -ceq '1-2-3') `
        'A/B comparison pair numbering is missing or duplicated.'
    $aggregate = Get-V71Rc5Property $Comparison 'Aggregate' 'A/B comparison'
    Require-V71Rc5Evidence ((Test-V71Rc5ExactTrue (Get-V71Rc5Property $aggregate `
            'AggregateGuardrailsPass' 'A/B aggregate')) -and
        [int](Get-V71Rc5Property $aggregate 'PairGuardrailPassCount' 'A/B aggregate') -eq $passes -and
        $passes -ge 2 -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $aggregate `
            'PersistentMetricRegression' 'A/B aggregate')) -and
        [double](Get-V71Rc5Property $aggregate 'MaximumRegressionPercent' 'A/B aggregate') -eq 2.0 -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $Comparison 'StableTouched' 'A/B comparison')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $Comparison 'RawLogsPersisted' 'A/B comparison'))) `
        'A/B comparison aggregate or evidence boundary failed.'
    return [pscustomobject]@{
        LineageSha256 = $lineageDigest
        OptionsSha256 = $optionsSha256
        ResourcePacksFingerprintSha256 = $resourcePacksSha256
    }
}

function Assert-V71Rc5RawPerformanceReports {
    param([object[]] $ResolvedReports, [string] $ExpectedProducerSha256,
        [string] $ExpectedLineageSha256, [string] $ApkSha256, [int] $WarmupSeconds,
        [string] $ExpectedOptionsSha256, [string] $ExpectedResourcePacksSha256)
    $names = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
    Require-V71Rc5Evidence ($ResolvedReports.Count -eq 6) 'The A/B report set is incomplete.'
    $otherMods = $null
    for ($index = 0; $index -lt 6; $index++) {
        $name = $names[$index]
        $report = Read-V71Rc5JsonText $ResolvedReports[$index].Text "A/B raw report $name"
        Require-V71Rc5Evidence ([int](Get-V71Rc5Property $report 'SchemaVersion' "A/B raw report $name") -eq 1 -and
            [string](Get-V71Rc5Property $report 'Package' "A/B raw report $name") -ceq
                $script:V71Rc5LabPackage -and
            [string](Get-V71Rc5Property $report 'RefreshPolicy' "A/B raw report $name") -ceq 'Dynamic' -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $report 'ValidForComparison' "A/B raw report $name")) -and
            @(Get-V71Rc5Property $report 'InvalidReasons' "A/B raw report $name").Count -eq 0 -and
            (Test-V71Rc5ExactFalse (Get-V71Rc5Property $report 'RawLogsPersisted' "A/B raw report $name"))) `
            "A/B raw report $name is not a retained exact-Lab report."
        foreach ($field in @('ExactPidPollPercent', 'FocusedPollPercent', 'SampleCoveragePercent')) {
            $coverage = ConvertTo-V71Rc5FiniteNumber `
                (Get-V71Rc5Property $report $field "A/B raw report $name") `
                "A/B raw report $name $field"
            $minimum = if ($field -ceq 'ExactPidPollPercent') { 100.0 } else { 95.0 }
            Require-V71Rc5Evidence ($coverage -ge $minimum -and $coverage -le 100.0) `
                "A/B raw report $name failed $field."
        }
        $protocol = Get-V71Rc5Property $report 'Protocol' "A/B raw report $name"
        $condition = $name.Substring(0, 1); $pair = [int]$name.Substring(1, 1)
        Require-V71Rc5Evidence ([int](Get-V71Rc5Property $protocol 'SchemaVersion' `
                "A/B raw report $name protocol") -eq 2 -and
            [string](Get-V71Rc5Property $protocol 'Condition' "A/B raw report $name protocol") -ceq
                $condition -and
            [int](Get-V71Rc5Property $protocol 'Pair' "A/B raw report $name protocol") -eq $pair -and
            [int](Get-V71Rc5Property $protocol 'Attempt' "A/B raw report $name protocol") -ge 1 -and
            [int](Get-V71Rc5Property $protocol 'Attempt' "A/B raw report $name protocol") -le 3) `
            "A/B raw report $name protocol identity drifted."
        $lineage = Assert-V71Rc5PerformanceLineage `
            (Get-V71Rc5Property $protocol 'ProducerLineage' "A/B raw report $name protocol") `
            $ExpectedProducerSha256 "A/B raw report $name producer lineage"
        Require-V71Rc5Evidence ($lineage -ceq $ExpectedLineageSha256) `
            "A/B raw report $name came from another producer closure."
        $expectedCore = if ($condition -ceq 'A') { $script:V71Rc4CoreSha256 } else { $script:V71Rc5CoreSha256 }
        $expectedVeq = if ($condition -ceq 'A') { $script:V71Rc4VeqSha256 } else { $script:V71Rc5VeqSha256 }
        Require-V71Rc5Evidence ((ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol `
                'CoreSha256' "A/B raw report $name protocol") "A/B raw report $name Core") -ceq
                $expectedCore -and
            (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol 'VeqSha256' `
                "A/B raw report $name protocol") "A/B raw report $name VEQ") -ceq $expectedVeq -and
            (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol 'InstalledApkSha256' `
                "A/B raw report $name protocol") "A/B raw report $name APK") -ceq $ApkSha256) `
            "A/B raw report $name payload/APK identity drifted."
        $fingerprint = ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol `
            'OtherModsFingerprintSha256' "A/B raw report $name protocol") `
            "A/B raw report $name other-mod fingerprint"
        if ($null -eq $otherMods) { $otherMods = $fingerprint }
        Require-V71Rc5Evidence ($fingerprint -ceq $otherMods) `
            'The A/B reports did not use one other-mod stack.'
        Require-V71Rc5Evidence (
            (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol 'OptionsSha256' `
                "A/B raw report $name protocol") "A/B raw report $name options") -ceq
                $ExpectedOptionsSha256 -and
            (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol `
                'ResourcePacksFingerprintSha256' "A/B raw report $name protocol") `
                "A/B raw report $name resource packs") -ceq $ExpectedResourcePacksSha256) `
            "A/B raw report $name did not preserve the exact options/resource-pack state."
        $expectedMarker = if ($condition -ceq 'A') { 'consumed' } else { 'absent' }
        Require-V71Rc5Evidence ([string](Get-V71Rc5Property $protocol 'MarkerState' `
                "A/B raw report $name protocol") -ceq $expectedMarker -and
            (ConvertTo-V71Rc5Sha256 (Get-V71Rc5Property $protocol 'WorldMasterSha256' `
                "A/B raw report $name protocol") "A/B raw report $name world") -ceq
                $script:V71Rc5WorldSha256 -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $protocol 'WorldResetBeforeLaunch' `
                "A/B raw report $name protocol")) -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $protocol 'ColdLaunch' `
                "A/B raw report $name protocol")) -and
            [int](Get-V71Rc5Property $protocol 'WarmupSeconds' "A/B raw report $name protocol") -eq
                $WarmupSeconds -and
            [int](Get-V71Rc5Property $protocol 'PreflightSeconds' "A/B raw report $name protocol") -eq 10 -and
            [int](Get-V71Rc5Property $protocol 'RoundPid' "A/B raw report $name protocol") -gt 0 -and
            [int](Get-V71Rc5Property $report 'AppPid' "A/B raw report $name") -eq
                [int](Get-V71Rc5Property $protocol 'RoundPid' "A/B raw report $name protocol")) `
            "A/B raw report $name is not bound to the fixed round/world/PID."
        $fresh = Get-V71Rc5Property $protocol 'FreshnessProof' "A/B raw report $name protocol"
        Require-V71Rc5Evidence ([string](Get-V71Rc5Property $fresh 'Source' `
                "A/B raw report $name freshness") -ceq 'device marker + fresh latest.log byte slice' -and
            [int](Get-V71Rc5Property $fresh 'AdvancementMarkers' "A/B raw report $name freshness") -ge 2 -and
            [int](Get-V71Rc5Property $fresh 'CoreVersionMarkers' "A/B raw report $name freshness") -ge 1 -and
            [int](Get-V71Rc5Property $fresh 'VeqVersionMarkers' "A/B raw report $name freshness") -ge 1 -and
            [int64](Get-V71Rc5Property $fresh 'LogMtime' "A/B raw report $name freshness") -gt
                [int64](Get-V71Rc5Property $fresh 'MarkerMtime' "A/B raw report $name freshness")) `
            "A/B raw report $name lacks freshness proof."
        $lease = Get-V71Rc5Property $protocol 'PerformanceLevelLease' "A/B raw report $name protocol"
        Require-V71Rc5Evidence ((Test-V71Rc5ExactTrue (Get-V71Rc5Property $lease `
                'AppliedAfterWorldReady' "A/B raw report $name lease")) -and
            (Test-V71Rc5ExactTrue (Get-V71Rc5Property $lease 'VerifiedBeforeWarmup' `
                "A/B raw report $name lease")) -and
            [int](Get-V71Rc5Property $lease 'CpuLevel' "A/B raw report $name lease") -eq 4 -and
            [int](Get-V71Rc5Property $lease 'GpuLevel' "A/B raw report $name lease") -eq 4 -and
            (Test-V71Rc5ExactFalse (Get-V71Rc5Property $lease 'RefreshPropertiesModified' `
                "A/B raw report $name lease")) -and
            (Test-V71Rc5ExactFalse (Get-V71Rc5Property $lease 'AdaptivePropertiesModified' `
                "A/B raw report $name lease"))) `
            "A/B raw report $name lacks the fixed per-round lease."
        $aggregate = Get-V71Rc5Property $report 'Aggregate' "A/B raw report $name"
        $numeric = @{}
        foreach ($field in @('MeanAppFps', 'P10AppFps', 'P95CpuAndGpuMs',
                'MeanStaleAtStableRefresh', 'MeanStalePerSecond', 'MeanDisplayRefreshHz',
                'DisplayRefreshModeHz', 'RefreshTransitionCount', 'CpuLevelMode', 'GpuLevelMode',
                'CpuLevel4Percent', 'GpuLevel4Percent', 'FirstTempC', 'MeanTempC', 'LastTempC', 'MaxTempC')) {
            $numeric[$field] = ConvertTo-V71Rc5FiniteNumber `
                (Get-V71Rc5Property $aggregate $field "A/B raw report $name aggregate") `
                "A/B raw report $name $field"
        }
        $buckets = @(Get-V71Rc5Property $aggregate 'DisplayRefreshDistribution' `
            "A/B raw report $name aggregate")
        Require-V71Rc5Evidence ($buckets.Count -gt 0) "A/B raw report $name has no refresh distribution."
        $percent = 0.0
        foreach ($bucket in $buckets) {
            $hz = ConvertTo-V71Rc5FiniteNumber (Get-V71Rc5Property $bucket 'Hz' `
                "A/B raw report $name refresh bucket") "A/B raw report $name refresh Hz"
            $count = ConvertTo-V71Rc5FiniteNumber (Get-V71Rc5Property $bucket 'Count' `
                "A/B raw report $name refresh bucket") "A/B raw report $name refresh Count"
            $p = ConvertTo-V71Rc5FiniteNumber (Get-V71Rc5Property $bucket 'Percent' `
                "A/B raw report $name refresh bucket") "A/B raw report $name refresh Percent"
            Require-V71Rc5Evidence ($hz -gt 0 -and $count -gt 0 -and $p -gt 0 -and $p -le 100) `
                "A/B raw report $name contains an invalid refresh bucket."
            $percent += $p
        }
        Require-V71Rc5Evidence ([math]::Abs($percent - 100.0) -le 0.1 -and
            $numeric.MeanAppFps -gt 0 -and $numeric.P10AppFps -gt 0 -and
            $numeric.P95CpuAndGpuMs -gt 0 -and $numeric.MeanDisplayRefreshHz -gt 0 -and
            $numeric.DisplayRefreshModeHz -gt 0 -and $numeric.CpuLevelMode -eq 4 -and
            $numeric.GpuLevelMode -eq 4 -and $numeric.CpuLevel4Percent -ge 95 -and
            $numeric.GpuLevel4Percent -ge 95 -and $numeric.FirstTempC -gt 0 -and
            $numeric.MeanTempC -gt 0 -and $numeric.LastTempC -gt 0 -and $numeric.MaxTempC -gt 0) `
            "A/B raw report $name contains impossible aggregate metrics."
    }
}

function Get-V71Rc5CanonicalJson { param($Value); return ($Value | ConvertTo-Json -Depth 32 -Compress) }

function Assert-V71Rc5PerformanceReaggregation {
    param([string] $PerformanceHarnessPath, [string] $CampaignDirectory,
        $LockedComparison, [string] $ExpectedProducerSha256)
    Require-V71Rc5Evidence ((Get-V71Rc5TextSha256 $PerformanceHarnessPath `
        'A/B producer before reaggregation') -ceq $ExpectedProducerSha256) `
        'The reviewed A/B producer drifted before reaggregation.'
    $values = @(& $PerformanceHarnessPath -Action Aggregate -OutputDirectory $CampaignDirectory)
    $decisions = @($values | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties['PerformanceGatePassed']
    })
    Require-V71Rc5Evidence ($decisions.Count -eq 1) `
        'The reviewed A/B producer did not return one recomputed decision.'
    Require-V71Rc5Evidence ((Get-V71Rc5CanonicalJson $decisions[0]) -ceq
        (Get-V71Rc5CanonicalJson $LockedComparison)) `
        'The locked A/B comparison differs from fresh aggregation of its six reports.'
    Require-V71Rc5Evidence ((Get-V71Rc5TextSha256 $PerformanceHarnessPath `
        'A/B producer after reaggregation') -ceq $ExpectedProducerSha256) `
        'The reviewed A/B producer drifted during reaggregation.'
}

function Assert-V71Rc5StableAcceptanceEvidenceCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $RepoRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $MemorySamplerPath,
        [Parameter(Mandatory)][string] $MemoryRuntimeContractPath,
        [Parameter(Mandatory)][string] $PerformanceHarnessPath,
        [Parameter(Mandatory)][string] $LifecycleHarnessPath,
        [Parameter(Mandatory)][string] $ExpectedPerformanceProducerSha256
    )
    $manifestFull = [IO.Path]::GetFullPath($ManifestPath)
    $repoFull = [IO.Path]::GetFullPath($RepoRoot)
    $evidenceFull = [IO.Path]::GetFullPath($EvidenceRoot)
    $readLocks = [Collections.Generic.List[System.IDisposable]]::new()
    try {
    Require-V71Rc5Evidence (Test-Path -LiteralPath $manifestFull -PathType Leaf) `
        'V71_STABLE_RC5_ACCEPTANCE.lock.json is missing.'
    $manifestReadLock = Enter-V71Rc5ReadLock $manifestFull 'RC5 Stable acceptance manifest'
    $readLocks.Add($manifestReadLock)
    $manifestHash = Get-V71Rc5FileSha256 $manifestFull
    $manifest = Read-V71Rc5Json $manifestFull 'RC5 Stable acceptance manifest'
    $null = Assert-V71Rc5StableAcceptanceManifestContract $manifest -RequireAccepted
    Assert-V71Rc5BuildLockContract -RequireBuiltApk
    $identity = Get-V71Rc5Property $manifest 'labIdentity' 'acceptance manifest'
    $built = Assert-V71Rc5LabIdentity $identity -RequireBuiltApk
    $boundary = Get-V71Rc5Property $manifest 'evidenceBoundary' 'acceptance manifest'
    Require-V71Rc5Evidence ((Test-V71Rc5ExactTrue (Get-V71Rc5Property $boundary 'rc4ReceiptsAreDiagnosticOnly' 'evidence boundary')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary 'rc4ReceiptsMaySatisfyRc5Acceptance' 'evidence boundary')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary 'stableTouched' 'evidence boundary')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary 'rawLogsPersisted' 'evidence boundary')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary 'deviceSerialPersisted' 'evidence boundary')) -and
        (Test-V71Rc5ExactFalse (Get-V71Rc5Property $boundary 'accountDataPersisted' 'evidence boundary'))) `
        'RC5 evidence boundary is unsafe or attempts to reuse RC4 evidence.'

    $producerLocks = Get-V71Rc5Property $manifest 'producerScripts' 'acceptance manifest'
    $memoryProducer = Assert-V71Rc5Producer $producerLocks 'memorySoak' `
        'scripts/quest-v71-memory-soak-rc5.ps1' $MemorySamplerPath $repoFull $readLocks
    $memoryContractProducer = Assert-V71Rc5Producer $producerLocks 'memoryRuntimeContract' `
        'scripts/quest-v71-memory-runtime-contract-rc5.ps1' $MemoryRuntimeContractPath $repoFull $readLocks
    $performanceProducer = Assert-V71Rc5Producer $producerLocks 'performanceHarness' `
        'scripts/quest-v71-rc4-rc5-ab.ps1' $PerformanceHarnessPath $repoFull $readLocks `
        $ExpectedPerformanceProducerSha256
    $lifecycleProducer = Assert-V71Rc5Producer $producerLocks 'lifecycleRecovery' `
        'scripts/quest-v71-lab-lifecycle-recovery-rc5.ps1' $LifecycleHarnessPath $repoFull $readLocks

    $soakLocks = @(Get-V71Rc5Property $manifest 'memorySoaks' 'acceptance manifest')
    Require-V71Rc5Evidence ($soakLocks.Count -eq 2) 'Exactly two new RC5 memory soaks are required.'
    $soaks = @(
        Assert-V71Rc5MemorySoak $soakLocks[0] 1 $evidenceFull $memoryProducer `
            $built.ApkSha256 $built.ApkSizeBytes $readLocks
        Assert-V71Rc5MemorySoak $soakLocks[1] 2 $evidenceFull $memoryProducer `
            $built.ApkSha256 $built.ApkSizeBytes $readLocks
    )
    Require-V71Rc5Evidence (($soaks[1].StartedUtc - $soaks[0].StartedUtc) -ge [TimeSpan]::FromMinutes(80)) `
        'The two RC5 memory soaks are not distinct rounds.'

    $performanceLock = Get-V71Rc5Property $manifest 'performance' 'acceptance manifest'
    Require-V71Rc5Evidence ([string](Get-V71Rc5Property $performanceLock 'status' 'performance') -ceq 'PASS' -and
        [string](Get-V71Rc5Property $performanceLock 'requiredResult' 'performance') -ceq
        'PASS_RC5_NO_PERSISTENT_REGRESSION') 'RC4-to-RC5 performance acceptance is not PASS.'
    $runManifestFile = Resolve-V71Rc5EvidenceFile $evidenceFull $performanceLock.runManifestPath `
        $performanceLock.runManifestSha256 'RC5 A/B run manifest' 'artifacts/benchmarks/'
    $readLocks.Add($runManifestFile.ReadLock)
    $comparisonFile = Resolve-V71Rc5EvidenceFile $evidenceFull $performanceLock.comparisonPath `
        $performanceLock.comparisonSha256 'RC5 A/B comparison' 'artifacts/benchmarks/'
    $readLocks.Add($comparisonFile.ReadLock)
    $campaignDirectory = [IO.Path]::GetDirectoryName($runManifestFile.Path)
    Require-V71Rc5Evidence ($campaignDirectory -ceq [IO.Path]::GetDirectoryName($comparisonFile.Path)) `
        'The A/B manifest and comparison are from different campaigns.'
    Require-V71Rc5Evidence ([IO.Path]::GetFileName($runManifestFile.Path) -ceq 'run-manifest.json' -and
        [IO.Path]::GetFileName($comparisonFile.Path) -ceq 'comparison.json') `
        'The A/B manifest or comparison leaf name drifted.'
    $runManifest = Read-V71Rc5JsonText $runManifestFile.Text 'RC5 A/B run manifest'
    $comparison = Read-V71Rc5JsonText $comparisonFile.Text 'RC5 A/B comparison'
    $performanceContract = Assert-V71Rc5PerformanceManifestAndComparison $runManifest $comparison `
        $performanceProducer $built.ApkSha256
    $reports = @($performanceLock.reports)
    Require-V71Rc5Evidence ($reports.Count -eq 6) 'Exactly six retained RC4-to-RC5 A/B reports are required.'
    $reportHashes = @(); $resolvedReports = @()
    $expectedReportNames = @('A1', 'B1', 'B2', 'A2', 'A3', 'B3')
    foreach ($index in 0..5) {
        $reportFile = Resolve-V71Rc5EvidenceFile $evidenceFull $reports[$index].path `
            $reports[$index].sha256 "RC5 A/B report $($index + 1)" 'artifacts/benchmarks/'
        $readLocks.Add($reportFile.ReadLock)
        Require-V71Rc5Evidence ([IO.Path]::GetDirectoryName($reportFile.Path) -ceq $campaignDirectory -and
            [IO.Path]::GetFileNameWithoutExtension($reportFile.Path) -ceq $expectedReportNames[$index] -and
            [IO.Path]::GetExtension($reportFile.Path) -ceq '.json') `
            "RC5 A/B report $($index + 1) is outside the campaign or out of order."
        $reportHashes += $reportFile.Sha256
        $resolvedReports += $reportFile
    }
    Require-V71Rc5Evidence (@($reportHashes | Sort-Object -Unique).Count -eq 6) `
        'The six A/B reports are not distinct locked files.'
    Assert-V71Rc5RawPerformanceReports $resolvedReports $performanceProducer `
        $performanceContract.LineageSha256 $built.ApkSha256 `
        ([int](Get-V71Rc5Property $runManifest 'WarmupSeconds' 'A/B manifest')) `
        $performanceContract.OptionsSha256 `
        $performanceContract.ResourcePacksFingerprintSha256
    Assert-V71Rc5PerformanceReaggregation $PerformanceHarnessPath $campaignDirectory `
        $comparison $performanceProducer

    $lifecycleLock = Get-V71Rc5Property $manifest 'lifecycleRecovery' 'acceptance manifest'
    Require-V71Rc5Evidence ([string]$lifecycleLock.status -ceq 'PASS' -and
        [string]$lifecycleLock.requiredReceiptType -ceq 'V71_LAB_RC5_LIFECYCLE_RECOVERY') `
        'RC5 lifecycle/recovery evidence is not PASS.'
    $lifecycleFile = Resolve-V71Rc5EvidenceFile $evidenceFull $lifecycleLock.receiptPath `
        $lifecycleLock.receiptSha256 'RC5 lifecycle/recovery receipt' 'artifacts/acceptance/'
    $readLocks.Add($lifecycleFile.ReadLock)
    $lifecycle = Read-V71Rc5JsonText $lifecycleFile.Text 'RC5 lifecycle/recovery receipt'
    Require-V71Rc5Evidence ([string]$lifecycle.receiptType -ceq 'V71_LAB_RC5_LIFECYCLE_RECOVERY' -and
        [string]$lifecycle.result -ceq 'PASS' -and
        (Test-V71Rc5ExactFalse $lifecycle.finalState.stableTouched) -and
        (Test-V71Rc5ExactTrue $lifecycle.finalState.exactRc5Pair)) `
        'RC5 lifecycle/recovery receipt is incomplete.'
    Assert-V71Rc5EmbeddedReceiptIdentity $lifecycle.labIdentity $built.ApkSha256 $built.ApkSizeBytes `
        'lifecycle receipt identity'
    $lifecycleRuntimePhases = @($lifecycle.phases | Where-Object {
        [string]$_.name -cin @('clean-cold-openxr',
            'post-openxr-process-stop-recovery',
            'post-launcher-interruption-recovery')
    })
    Require-V71Rc5Evidence ($lifecycleRuntimePhases.Count -eq 3) `
        'RC5 lifecycle receipt does not contain all three expectedGameLog runtime phases.'
    foreach ($phase in $lifecycleRuntimePhases) {
        foreach ($field in @('expectedGameLogMinecraftVersionObserved',
                'expectedGameLogCoreVersionObserved',
                'expectedGameLogVeqVersionObserved')) {
            Require-V71Rc5Evidence (Test-V71Rc5ExactTrue `
                (Get-V71Rc5Property $phase $field `
                    "RC5 lifecycle phase $([string]$phase.name)")) `
                "RC5 lifecycle phase $([string]$phase.name) failed $field."
        }
    }
    $lifecycleLineageDigest = Assert-V71Rc5LifecycleProducerLineage `
        (Get-V71Rc5Property $lifecycle 'producerLineage' 'RC5 lifecycle/recovery receipt') `
        $lifecycleProducer 'RC5 lifecycle/recovery producer lineage'

    $runtimeLock = Get-V71Rc5Property $manifest 'memoryRuntimeContract' 'acceptance manifest'
    Require-V71Rc5Evidence ([string]$runtimeLock.status -ceq 'PASS' -and
        [string]$runtimeLock.requiredReceiptType -ceq 'V71_RC5_MEMORY_RUNTIME_CONTRACT') `
        'RC5 memory runtime contract is not PASS.'
    $runtimeFile = Resolve-V71Rc5EvidenceFile $evidenceFull $runtimeLock.receiptPath `
        $runtimeLock.receiptSha256 'RC5 memory runtime contract' 'artifacts/acceptance/'
    $readLocks.Add($runtimeFile.ReadLock)
    $runtime = Read-V71Rc5JsonText $runtimeFile.Text 'RC5 memory runtime contract'
    Require-V71Rc5Evidence ([int]$runtime.schemaVersion -eq 1 -and
        [string]$runtime.receiptType -ceq 'V71_RC5_MEMORY_RUNTIME_CONTRACT' -and
        [string]$runtime.result -ceq 'PASS' -and
        [string]$runtime.producer.hashScheme -ceq $script:V71Rc5PerformanceProducerHashScheme -and
        [string]$runtime.producer.sha256 -ceq $memoryContractProducer -and
        @($runtime.soaks).Count -eq 2) 'RC5 memory runtime contract is malformed or producer-detached.'
    Assert-V71Rc5EmbeddedReceiptIdentity $runtime.labIdentity $built.ApkSha256 $built.ApkSizeBytes `
        'memory runtime contract identity'
    Require-V71Rc5Evidence ([int]$runtime.memoryPolicy.xmsMiB -eq 512 -and
        [int]$runtime.memoryPolicy.automaticXmxMiB -eq 1536 -and
        [int]$runtime.memoryPolicy.manualXmxHardCapMiB -eq 2048 -and
        [string]$runtime.memoryPolicy.pojlibAarSha256 -ceq $script:V71Rc5PojlibSha256 -and
        (Test-V71Rc5ExactTrue $runtime.memoryPolicy.perSoakJvmArgumentObservedDirectly) -and
        (Test-V71Rc5ExactTrue $runtime.launcherResourceRelease.perSoakAppliedMarkerObservedDirectlyAtStart) -and
        [string]$runtime.launcherResourceRelease.lifecycleReceiptSha256 -ceq $lifecycleFile.Sha256) `
        'RC5 memory runtime contract policy or lifecycle binding drifted.'
    $runtimeSoaks = @($runtime.soaks); $direct = @($runtime.directObservations)
    Require-V71Rc5Evidence ($direct.Count -eq 2) 'RC5 memory contract lacks two direct observations.'
    for ($index = 0; $index -lt 2; $index++) {
        $receiptSoak = $runtimeSoaks[$index]; $acceptedSoak = $soaks[$index]
        Require-V71Rc5Evidence ([int]$receiptSoak.index -eq ($index + 1) -and
            [string]$receiptSoak.summarySha256 -ceq $acceptedSoak.SummarySha256 -and
            [string]$receiptSoak.samplesSha256 -ceq $acceptedSoak.SamplesSha256 -and
            [string]$receiptSoak.producerSha256 -ceq $memoryProducer -and
            [int]$receiptSoak.initialPid -eq $acceptedSoak.InitialPid -and
            [int]$direct[$index].index -eq ($index + 1) -and
            [int]$direct[$index].initialPid -eq $acceptedSoak.InitialPid -and
            [uint64]$direct[$index].processStartTicks -eq $acceptedSoak.ProcessStartTicks -and
            (Test-V71Rc5ExactTrue $direct[$index].sameAndroidProcessIncarnation) -and
            (Test-V71Rc5ExactTrue $direct[$index].gameJvmAliveAtStartAndFinal) -and
            (Test-V71Rc5ExactTrue $direct[$index].provenanceMatchedAtStartAndFinal) -and
            [int]$direct[$index].xmsMiB -eq 512 -and [int]$direct[$index].xmxMiB -eq 1536 -and
            [string]$direct[$index].xmxSource -ceq 'auto' -and
            (Test-V71Rc5ExactTrue $direct[$index].launcherResourceReleaseAppliedAtStart) -and
            (Test-V71Rc5ExactTrue $direct[$index].expectedProfileGameLogPathFixed) -and
            (Test-V71Rc5ExactTrue $direct[$index].expectedGameLogIdentityCheckedAtStartAndFinal) -and
            (Test-V71Rc5ExactTrue $direct[$index].expectedGameLogFreshnessCheckedEverySample) -and
            (Test-V71Rc5ExactTrue $direct[$index].expectedGameLogEvidenceOnlyBooleansAndTimestamps) -and
            (Test-V71Rc5ExactFalse $direct[$index].finalLogcatMarkerRequired)) `
            "RC5 memory contract soak $($index + 1) is detached from locked raw evidence."
    }
    $runtimeBoundary = $runtime.evidenceBoundary
    Require-V71Rc5Evidence ((Test-V71Rc5ExactFalse $runtimeBoundary.crossEvidenceContractNotPerProcessAttestation) -and
        (Test-V71Rc5ExactTrue $runtimeBoundary.directPerSoakJvmArgumentClaim) -and
        (Test-V71Rc5ExactTrue $runtimeBoundary.directPerSoakResourceReleaseMarkerClaim) -and
        (Test-V71Rc5ExactTrue $runtimeBoundary.launcherMarkerCapturedOnlyAtSoakStart) -and
        (Test-V71Rc5ExactFalse $runtimeBoundary.finalLogcatMarkerRetentionRequired) -and
        (Test-V71Rc5ExactTrue $runtimeBoundary.sameProcessIncarnationUsesPidAndStartTicks)) `
        'RC5 memory contract evidence boundary drifted.'
    foreach ($field in @('rawLogsPersisted', 'logSnippetsPersisted', 'deviceSerialPersisted',
            'accountDataPersisted', 'hostAbsolutePathsPersisted')) {
        Require-V71Rc5Evidence (Test-V71Rc5ExactFalse `
            (Get-V71Rc5Property $runtimeBoundary $field 'memory contract evidence boundary')) `
            "RC5 memory contract persisted forbidden evidence: $field."
    }

    $manualLock = Get-V71Rc5Property $manifest 'manual' 'acceptance manifest'
    Require-V71Rc5Evidence ([string]$manualLock.status -ceq 'ACCEPTED' -and
        [string]$manualLock.requiredReceiptType -ceq 'V71_RC5_MANUAL_VR_INTERACTION') `
        'RC5 manual acceptance is not ACCEPTED.'
    $manualFile = Resolve-V71Rc5EvidenceFile $evidenceFull $manualLock.receiptPath `
        $manualLock.receiptSha256 'RC5 manual VR receipt' 'artifacts/acceptance/'
    $readLocks.Add($manualFile.ReadLock)
    $manual = Read-V71Rc5JsonText $manualFile.Text 'RC5 manual VR receipt'
    Assert-V71Rc5ManualAcceptanceReceipt $manual $built.ApkSha256 $built.ApkSizeBytes

    return [pscustomobject][ordered]@{
        Result = 'PASS'
        ManifestSha256 = $manifestHash
        ExactLabApkSha256 = $built.ApkSha256
        ExactCoreSha256 = $script:V71Rc5CoreSha256
        ExactVeqSha256 = $script:V71Rc5VeqSha256
        MemorySoakSummarySha256 = @($soaks.SummarySha256)
        MemorySoakSamplesSha256 = @($soaks.SamplesSha256)
        PerformanceRunManifestSha256 = $runManifestFile.Sha256
        PerformanceComparisonSha256 = $comparisonFile.Sha256
        PerformanceReportSha256 = $reportHashes
        LifecycleRecoveryReceiptSha256 = $lifecycleFile.Sha256
        LifecycleProducerLineageSha256 = $lifecycleLineageDigest
        PerformanceOptionsSha256 = $performanceContract.OptionsSha256
        PerformanceResourcePacksFingerprintSha256 = `
            $performanceContract.ResourcePacksFingerprintSha256
        MemoryRuntimeContractReceiptSha256 = $runtimeFile.Sha256
        ManualReceiptSha256 = $manualFile.Sha256
        Rc4EvidenceAccepted = $false
        StableTouched = $false
    }
    } finally {
        for ($index = $readLocks.Count - 1; $index -ge 0; $index--) {
            $readLocks[$index].Dispose()
        }
    }
}

function Assert-V71Rc5StableAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $RepoRoot,
        [Parameter(Mandatory)][string] $EvidenceRoot,
        [Parameter(Mandatory)][string] $MemorySamplerPath,
        [Parameter(Mandatory)][string] $MemoryRuntimeContractPath,
        [Parameter(Mandatory)][string] $PerformanceHarnessPath,
        [Parameter(Mandatory)][string] $LifecycleHarnessPath
    )
    return Assert-V71Rc5StableAcceptanceEvidenceCore @PSBoundParameters `
        -ExpectedPerformanceProducerSha256 $script:V71Rc5PerformanceProducerSha256
}
