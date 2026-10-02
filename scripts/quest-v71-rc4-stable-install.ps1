#requires -Version 7.0
<#
.SYNOPSIS
Fail-closed v71 Stable install, verification, runtime, and rollback harness.

.DESCRIPTION
The target is permanently fixed to com.qcxr.qcxr.dev262. SelfTest and Plan
never resolve ADB. Device phases require independent read/write/install/launch
switches as applicable, accepted V71_STABLE_RC4_ACCEPTANCE evidence, a reviewed
V71_STABLE.lock.json, and a complete protected v69 backup.

The only package replacement command this file can construct is exactly
`adb -s <serial> install -r <apk>`. It never uninstalls, clears application
data, reads account files, adds a downgrade flag, or synthesizes UI input.
#>
[CmdletBinding()]
param(
    [ValidateSet(
        'SelfTest',
        'Plan',
        'Install',
        'VerifyInstalled',
        'ThreeNormalStarts',
        'Final30MinuteGate',
        'RollbackToV69'
    )]
    [string] $Action = 'SelfTest',

    [string] $StableLockPath = '',
    [string] $BackupManifestPath = '',
    [string] $BackupManifestSha256 = '',
    [string] $ReceiptDirectory = '',

    [ValidatePattern('^(auto|[A-Za-z0-9._:-]+)$')]
    [string] $Serial = 'auto',
    [string] $AdbPath = 'adb',

    [switch] $AllowDeviceRead,
    [switch] $AllowDeviceWrite,
    [switch] $AllowInstallReplace,
    [switch] $AllowLaunch,
    [switch] $AllowForceStop,
    [switch] $AllowRollbackOnFailure,
    [switch] $AllowRollbackDowngrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:EvidenceRoot = Split-Path -Parent (Split-Path -Parent $script:RepoRoot)
$script:Package = 'com.qcxr.qcxr.dev262'
$script:Profile = '26.2'
$script:Component = 'com.qcxr.qcxr.dev262/pojlib.UnityPlayerActivity'
$script:AcceptanceManifestPath = Join-Path $script:RepoRoot 'V71_STABLE_RC4_ACCEPTANCE.lock.json'
$script:Rc4LockPath = Join-Path $script:RepoRoot 'V71_LAB_RC4.lock.json'
$script:EvidenceGatePath = Join-Path $PSScriptRoot 'v71-rc4-stable-evidence-gate.ps1'
$script:MemorySamplerPath = Join-Path $PSScriptRoot 'quest-v71-memory-soak-rc4.ps1'
$script:MemoryRuntimeContractPath = Join-Path $PSScriptRoot 'quest-v71-memory-runtime-contract-rc4.ps1'
$script:PerformanceHarnessPath = Join-Path $PSScriptRoot 'quest-v71-rc3-rc4-ab.ps1'
$script:LifecycleHarnessPath = Join-Path $PSScriptRoot 'quest-v71-lab-lifecycle-recovery-rc4.ps1'
$script:ApkVerifierPath = Join-Path $PSScriptRoot 'verify-dev-apk.ps1'
$script:DefaultStableLockPath = Join-Path $script:RepoRoot 'V71_STABLE.lock.json'
$script:BackupRoot = Join-Path $script:RepoRoot 'artifacts\device-config-backups'
$script:ReceiptRoot = Join-Path $script:RepoRoot 'artifacts\stable-v71-install'
$script:GameDirectory = '/sdcard/Android/data/com.qcxr.qcxr.dev262/files/instances/26.2'
$script:CoreDevicePath = "$($script:GameDirectory)/mods/Vivecraft.jar"
$script:VeqDevicePath = "$($script:GameDirectory)/mods/Vivecraft-Essentials-Quest.jar"
$script:MinecraftLogPath = "$($script:GameDirectory)/logs/latest.log"

$script:ExpectedSignerSha256 = 'B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A'
$script:ExpectedCoreSha256 = '289C27057489B1D9B81583776F458179A1D5D5842451B35E598ADCBEB3213189'
$script:ExpectedCoreSizeBytes = 10068021L
$script:ExpectedCoreVersion = '26.2-1.3.15+qc.v71.rc4'
$script:ExpectedVeqSha256 = '314D3CBD6D7A06D9AD2A5A6AC437A1B3A3C2AE2F1D9927414DB4A9B3E7AE0D8B'
$script:ExpectedVeqSizeBytes = 441660L
$script:ExpectedVeqVersion = '0.7.0-v70-canary.1'
$script:ExpectedLwjglSha256 = 'DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9'

$script:V69 = [ordered]@{
    Package = $script:Package
    VersionCode = 69
    VersionName = '6.0.1-26.2-vivecraft-personal.10'
    Label = 'QuestCraft Vivecraft Personal 26.2'
    ApkSha256 = '05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034'
    ApkSizeBytes = 126700777L
    SignerSha256 = $script:ExpectedSignerSha256
    CoreSha256 = '3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F'
    CoreVersion = '1.3.15-qc-openxr-vulkan6-vc014d47e-personal-v67-rc1'
    VeqSha256 = '6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9'
    VeqVersion = '0.7.0'
}

$script:ResolvedAdb = $null
$script:ResolvedSerial = $null
$script:DeviceInvocationCount = 0
$script:DeviceResolved = $false
$script:MutationAttempted = $false
$script:CandidateInstallAttempted = $false
$script:StableContract = $null
$script:ReceiptDirectoryFull = $null

function Require {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "[V71_RC4_STABLE_INSTALL] $Message" }
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

function ConvertTo-CanonicalSha256 {
    param($Value, [string] $Context)
    Require ($Value -is [string]) "$Context must be a string."
    $normalized = ([string]$Value).ToUpperInvariant()
    Require ($normalized -cmatch '^[0-9A-F]{64}$' -and $normalized -cne ('0' * 64)) "$Context is not a nonzero canonical SHA-256."
    return $normalized
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-NormalizedUtf8TextSha256 {
    param([Parameter(Mandatory)][string] $Text)
    $normalized = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes($normalized)))
}

function Enter-StrictUtf8TextReadLock {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Context
    )
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    Assert-NoReparsePoint -Path $Path -Root $script:RepoRoot
    $full = Assert-PathContained -Path $Path -Root $script:RepoRoot
    $stream = $null
    try {
        # FileShare.Read denies writes, replacement, and deletion while still
        # allowing PowerShell to read the authenticated script for dot-source.
        $stream = [IO.File]::Open(
            $full,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        Assert-NoReparsePoint -Path $full -Root $script:RepoRoot
        Require ($stream.Length -gt 0 -and $stream.Length -le 32MB) `
            "$Context has an unsafe byte length."
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            Require ($read -gt 0) "$Context ended during its locked read."
            $offset += $read
        }
        $textOffset = 0
        if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $textOffset = 3
        }
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        try {
            $text = $utf8.GetString($bytes, $textOffset, $bytes.Length - $textOffset)
        } catch {
            throw "[V71_RC4_STABLE_INSTALL] $Context is not strict UTF-8: $($_.Exception.Message)"
        }
        return [pscustomobject]@{
            Path = $full
            Stream = $stream
            Text = $text
            NormalizedSha256 = Get-NormalizedUtf8TextSha256 $text
        }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function ConvertFrom-StrictJsonText {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Context
    )
    try {
        return $Text | ConvertFrom-Json -Depth 40
    } catch {
        throw "[V71_RC4_STABLE_INSTALL] $Context is not strict parseable JSON: $($_.Exception.Message)"
    }
}

function Assert-Rc4EvidenceGateLockContract {
    param([Parameter(Mandatory)] $Lock)
    $schemaVersion = Get-RequiredProperty $Lock 'schemaVersion' 'RC4 Lab lock'
    Require (($schemaVersion -is [int] -or $schemaVersion -is [long]) -and
        [int64]$schemaVersion -eq 1) 'RC4 Lab lock schemaVersion must be the integer 1.'
    $source = Get-RequiredProperty $Lock 'source' 'RC4 Lab lock'
    $hashScheme = Get-RequiredProperty $source 'scriptHashScheme' 'RC4 Lab lock source'
    Require ($hashScheme -is [string] -and [string]$hashScheme -ceq
        'sha256-utf8-normalized-lf') 'RC4 Lab lock scriptHashScheme drifted.'
    $expectedGateSha256 = ConvertTo-CanonicalSha256 `
        (Get-RequiredProperty $source 'stableEvidenceGateScriptSha256' 'RC4 Lab lock source') `
        'RC4 Lab lock Stable evidence gate SHA-256'
    return [pscustomobject]@{
        SchemaVersion = 1
        HashScheme = 'sha256-utf8-normalized-lf'
        EvidenceGateSha256 = $expectedGateSha256
    }
}

function Invoke-AuthenticatedRc4EvidenceGate {
    param(
        [Parameter(Mandatory)] $Contract,
        [Parameter(Mandatory)][hashtable] $GateArguments,
        [string] $Rc4LockPath = $script:Rc4LockPath,
        [string] $EvidenceGatePath = $script:EvidenceGatePath
    )
    $rc4LockRead = $null
    $evidenceGateRead = $null
    try {
        # INSTALLER_AUTH_LOCK_AND_HASH_CHECK_BEFORE_DOT_SOURCE
        $rc4LockRead = Enter-StrictUtf8TextReadLock -Path $Rc4LockPath `
            -Context 'RC4 Lab lock'
        $rc4Lock = ConvertFrom-StrictJsonText -Text $rc4LockRead.Text `
            -Context 'RC4 Lab lock'
        $gateLock = Assert-Rc4EvidenceGateLockContract $rc4Lock
        $evidenceGateRead = Enter-StrictUtf8TextReadLock -Path $EvidenceGatePath `
            -Context 'RC4 Stable evidence gate'
        Require ([string]$evidenceGateRead.NormalizedSha256 -ceq
            [string]$gateLock.EvidenceGateSha256) `
            'The RC4 Stable evidence gate drifted from V71_LAB_RC4.lock.json.'

        # INSTALLER_AUTH_DOT_SOURCE_ONLY_AFTER_LOCKED_HASH_CHECK
        $dotSourceOutput = . $EvidenceGatePath
        Require (@($dotSourceOutput).Count -eq 0) `
            'The authenticated RC4 Stable evidence gate emitted output while loading.'
        $gateCommand = Get-Command 'Assert-V71Rc4StableAcceptanceEvidence' `
            -CommandType Function -ErrorAction SilentlyContinue
        Require ($null -ne $gateCommand -and @($gateCommand).Count -eq 1) `
            'The authenticated RC4 Stable evidence gate did not define exactly one entry function.'
        $definedBy = [string]$gateCommand.ScriptBlock.File
        Require (-not [string]::IsNullOrWhiteSpace($definedBy) -and
            (Get-CanonicalPath $definedBy) -ceq (Get-CanonicalPath $EvidenceGatePath)) `
            'The RC4 Stable evidence entry function did not come from the authenticated gate file.'

        # Invoke the resolved FunctionInfo explicitly; do not permit alias,
        # cmdlet, or ambient function resolution to choose the entry point.
        $result = & $gateCommand @GateArguments
        Require ([string]$result.Result -ceq 'PASS') `
            'V71 Stable acceptance evidence did not pass.'
        Require ([string]$result.ManifestSha256 -ceq
            [string]$Contract.AcceptanceManifestSha256) `
            'The reviewed lock does not bind the accepted evidence manifest bytes.'
        Require ([string]$result.ExactCoreSha256 -ceq $script:ExpectedCoreSha256 -and
            [string]$result.ExactVeqSha256 -ceq $script:ExpectedVeqSha256) `
            'Accepted evidence does not bind the exact RC4 pair.'
        return $result
    } finally {
        if ($null -ne $evidenceGateRead) { $evidenceGateRead.Stream.Dispose() }
        if ($null -ne $rc4LockRead) { $rc4LockRead.Stream.Dispose() }
    }
}

function ConvertTo-ValidatedRoundtripTimestamp {
    param($Value, [string] $Context)
    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToString('o')
    }
    if ($Value -is [DateTime]) {
        $dateTime = [DateTime]$Value
        Require ($dateTime.Kind -ne [DateTimeKind]::Unspecified) "$Context has no time-zone designator."
        return ([DateTimeOffset]$dateTime).ToString('o')
    }
    Require ($Value -is [string]) "$Context is not a timestamp string."
    $parsed = [DateTimeOffset]::MinValue
    Require ([DateTimeOffset]::TryParseExact(
        [string]$Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed)) "$Context must be an ISO-8601 round-trip timestamp."
    return $parsed.ToString('o')
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
    Require ($inside -or ($AllowRoot.IsPresent -and $full -eq $fullRoot)) "A Host path escaped its fixed root: $full"
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
        Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) "A protected Host path is a reparse point: $current"
    }
    if ($full -eq $fullRoot) { return }
    $relative = [IO.Path]::GetRelativePath($fullRoot, $full)
    foreach ($part in $relative.Split([IO.Path]::DirectorySeparatorChar)) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Require (-not ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) "A protected Host path component is a reparse point: $current"
        }
    }
}

function Read-StrictJsonFile {
    param([Parameter(Mandatory)][string] $Path, [string] $Context = 'JSON file')
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    Assert-NoReparsePoint -Path $Path -Root $script:RepoRoot
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        return $text | ConvertFrom-Json -Depth 40
    } catch {
        throw "[V71_RC4_STABLE_INSTALL] $Context is not strict parseable JSON: $($_.Exception.Message)"
    }
}

function Assert-ExactValue {
    param($Actual, $Expected, [string] $Context)
    if ($Expected -is [string]) {
        Require ($Actual -is [string] -and [string]$Actual -ceq [string]$Expected) "$Context drifted."
    } else {
        Require ($Actual -eq $Expected) "$Context drifted."
    }
}

function Assert-StableLockContract {
    param($Lock)
    Assert-ExactValue (Get-RequiredProperty $Lock 'schemaVersion' 'Stable lock') 1 'Stable lock schemaVersion'
    Assert-ExactValue (Get-RequiredProperty $Lock 'status' 'Stable lock') 'REVIEWED_FOR_SUPERVISED_INSTALL' 'Stable lock status'

    $target = Get-RequiredProperty $Lock 'target' 'Stable lock'
    Assert-ExactValue (Get-RequiredProperty $target 'package' 'target') $script:Package 'target package'
    Assert-ExactValue (Get-RequiredProperty $target 'versionCode' 'target') 71 'target versionCode'
    Assert-ExactValue (Get-RequiredProperty $target 'versionName' 'target') '6.0.1-26.2-vivecraft-personal.12' 'target versionName'
    Assert-ExactValue (Get-RequiredProperty $target 'label' 'target') 'QuestCraft Vivecraft Personal 26.2' 'target label'
    Assert-ExactValue (Get-RequiredProperty $target 'apkPath' 'target') 'QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-26.2-personal.12-local.apk' 'target APK path'
    $targetSha256 = ConvertTo-CanonicalSha256 (Get-RequiredProperty $target 'apkSha256' 'target') 'target APK SHA-256'
    $targetSize = [int64](Get-RequiredProperty $target 'apkSizeBytes' 'target')
    Require ($targetSize -gt 100000000L) 'target APK size is not plausible.'
    Assert-ExactValue (Get-RequiredProperty $target 'signerSha256' 'target') $script:ExpectedSignerSha256 'target signer'
    Require ((Get-RequiredProperty $target 'signatureSchemeV2' 'target') -is [bool] -and [bool]$target.signatureSchemeV2) 'target signatureSchemeV2 must be exactly true.'
    Assert-ExactValue (Get-RequiredProperty $target 'coreSha256' 'target') $script:ExpectedCoreSha256 'target Core SHA-256'
    Assert-ExactValue (Get-RequiredProperty $target 'coreSizeBytes' 'target') $script:ExpectedCoreSizeBytes 'target Core size'
    Assert-ExactValue (Get-RequiredProperty $target 'coreVersion' 'target') $script:ExpectedCoreVersion 'target Core version'
    Assert-ExactValue (Get-RequiredProperty $target 'veqSha256' 'target') $script:ExpectedVeqSha256 'target VEQ SHA-256'
    Assert-ExactValue (Get-RequiredProperty $target 'veqSizeBytes' 'target') $script:ExpectedVeqSizeBytes 'target VEQ size'
    Assert-ExactValue (Get-RequiredProperty $target 'veqVersion' 'target') $script:ExpectedVeqVersion 'target VEQ version'
    Assert-ExactValue (Get-RequiredProperty $target 'lwjglSha256' 'target') $script:ExpectedLwjglSha256 'target LWJGL SHA-256'

    $baseline = Get-RequiredProperty $Lock 'baselineV69' 'Stable lock'
    foreach ($name in @('Package','VersionCode','VersionName','ApkSha256','ApkSizeBytes','SignerSha256','CoreSha256','CoreVersion','VeqSha256','VeqVersion')) {
        $jsonName = $name.Substring(0,1).ToLowerInvariant() + $name.Substring(1)
        Assert-ExactValue (Get-RequiredProperty $baseline $jsonName 'baselineV69') $script:V69[$name] "baselineV69.$jsonName"
    }

    $acceptance = Get-RequiredProperty $Lock 'acceptance' 'Stable lock'
    Assert-ExactValue (Get-RequiredProperty $acceptance 'manifestPath' 'acceptance') 'V71_STABLE_RC4_ACCEPTANCE.lock.json' 'acceptance manifest path'
    $acceptanceSha256 = ConvertTo-CanonicalSha256 (Get-RequiredProperty $acceptance 'manifestSha256' 'acceptance') 'acceptance manifest SHA-256'
    Assert-ExactValue (Get-RequiredProperty $acceptance 'requiredStatus' 'acceptance') 'ACCEPTED_FOR_STABLE_BUILD' 'acceptance required status'

    $review = Get-RequiredProperty $Lock 'review' 'Stable lock'
    Assert-ExactValue (Get-RequiredProperty $review 'status' 'review') 'APPROVED_FOR_SUPERVISED_INSTALL' 'review status'
    $reviewer = [string](Get-RequiredProperty $review 'reviewedBy' 'review')
    Require ($reviewer -cmatch '^[ -~]{2,120}$') 'reviewedBy is missing or unsafe.'
    $reviewedUtc = ConvertTo-ValidatedRoundtripTimestamp (Get-RequiredProperty $review 'reviewedUtc' 'review') 'reviewedUtc'

    $policy = Get-RequiredProperty $Lock 'installPolicy' 'Stable lock'
    foreach ($field in @('replaceOnly','noUninstall','noClearData','noAccountAccess','rollbackUsesReplaceOnly','rollbackDowngradeOverrideForbidden')) {
        Require ((Get-RequiredProperty $policy $field 'installPolicy') -is [bool] -and [bool]$policy.$field) "installPolicy.$field must be exactly true."
    }
    Assert-ExactValue (Get-RequiredProperty $policy 'finalRequiredState' 'installPolicy') 'STOPPED' 'installPolicy final state'
    Assert-ExactValue (Get-RequiredProperty $policy 'normalStartCount' 'installPolicy') 3 'installPolicy start count'
    Assert-ExactValue (Get-RequiredProperty $policy 'finalGateSeconds' 'installPolicy') 1800 'installPolicy final gate duration'

    return [pscustomobject]@{
        Target = [pscustomobject]@{
            Package = $script:Package
            VersionCode = 71
            VersionName = '6.0.1-26.2-vivecraft-personal.12'
            Label = 'QuestCraft Vivecraft Personal 26.2'
            ApkPath = [string]$target.apkPath
            ApkSha256 = $targetSha256
            ApkSizeBytes = $targetSize
            SignerSha256 = $script:ExpectedSignerSha256
            CoreSha256 = $script:ExpectedCoreSha256
            CoreSizeBytes = $script:ExpectedCoreSizeBytes
            CoreVersion = $script:ExpectedCoreVersion
            VeqSha256 = $script:ExpectedVeqSha256
            VeqSizeBytes = $script:ExpectedVeqSizeBytes
            VeqVersion = $script:ExpectedVeqVersion
            LwjglSha256 = $script:ExpectedLwjglSha256
        }
        AcceptanceManifestSha256 = $acceptanceSha256
        ReviewedBy = $reviewer
        ReviewedUtc = $reviewedUtc
    }
}

function Resolve-StableLock {
    $resolved = if ([string]::IsNullOrWhiteSpace($StableLockPath)) { $script:DefaultStableLockPath } else { $StableLockPath }
    $full = if ([IO.Path]::IsPathRooted($resolved)) { Get-CanonicalPath $resolved } else { Get-CanonicalPath (Join-Path $script:RepoRoot $resolved) }
    Assert-PathContained -Path $full -Root $script:RepoRoot | Out-Null
    Require ([IO.Path]::GetFileName($full) -ceq 'V71_STABLE.lock.json') 'The reviewed lock must be named V71_STABLE.lock.json.'
    $lock = Read-StrictJsonFile -Path $full -Context 'reviewed V71 Stable lock'
    $parsed = Assert-StableLockContract $lock
    $parsed | Add-Member -NotePropertyName LockPath -NotePropertyValue $full
    $parsed | Add-Member -NotePropertyName LockSha256 -NotePropertyValue (Get-Sha256 $full)
    return $parsed
}

function Resolve-LockedCandidatePath {
    param($Contract)
    $relative = [string]$Contract.Target.ApkPath
    Require ($relative -cmatch '^[A-Za-z0-9._/-]+$' -and -not $relative.Contains('..') -and -not $relative.Contains('\')) 'The locked APK path has unsafe syntax.'
    $full = Assert-PathContained -Path (Join-Path $script:RepoRoot $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)) -Root $script:RepoRoot
    Require (Test-Path -LiteralPath $full -PathType Leaf) 'The locked v71 Stable APK is missing.'
    Assert-NoReparsePoint -Path $full -Root $script:RepoRoot
    Require ((Get-Item -LiteralPath $full).Length -eq [int64]$Contract.Target.ApkSizeBytes) 'The locked v71 Stable APK size mismatched.'
    Require ((Get-Sha256 $full) -ceq [string]$Contract.Target.ApkSha256) 'The locked v71 Stable APK hash mismatched.'
    return $full
}

function Assert-Rc4CandidateEvidenceReady {
    # This intentionally runs before any Stable lock, backup, ADB, or device
    # resolution. The checked-in RC4 lock is expected to fail here until the
    # exact Lab APK exists and its evidence is explicitly accepted.
    Require (Test-Path -LiteralPath $script:AcceptanceManifestPath -PathType Leaf) `
        'The fixed RC4 acceptance manifest is missing.'
    $manifest = Read-StrictJsonFile -Path $script:AcceptanceManifestPath `
        -Context 'RC4 Stable acceptance manifest'
    $identity = Get-RequiredProperty $manifest 'labIdentity' 'RC4 acceptance manifest'
    $apkHashValue = Get-RequiredProperty $identity 'apkSha256' 'RC4 Lab identity'
    $apkHash = if ($apkHashValue -is [string]) {
        ([string]$apkHashValue).ToUpperInvariant()
    } else { '' }
    $apkSize = [int64](Get-RequiredProperty $identity 'apkSizeBytes' 'RC4 Lab identity')
    Require ($apkHash -cmatch '^[0-9A-F]{64}$' -and $apkHash -cne ('0' * 64) -and
        $apkSize -gt 0 -and
        [string](Get-RequiredProperty $identity 'artifactAudit' 'RC4 Lab identity') -ceq 'PASS') `
        'RC4 Lab candidate is PENDING_NOT_BUILT or not independently audited; refusing before ADB.'
    Require ([string](Get-RequiredProperty $manifest 'status' 'RC4 acceptance manifest') -ceq
        'ACCEPTED_FOR_STABLE_BUILD') `
        'RC4 evidence is not ACCEPTED_FOR_STABLE_BUILD; refusing before ADB.'
    return [pscustomobject]@{ ApkSha256 = $apkHash; ApkSizeBytes = $apkSize }
}

function Assert-AcceptedEvidence {
    param($Contract)
    foreach ($path in @($script:AcceptanceManifestPath,$script:Rc4LockPath,$script:EvidenceGatePath,$script:MemorySamplerPath,$script:MemoryRuntimeContractPath,$script:PerformanceHarnessPath,$script:LifecycleHarnessPath)) {
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Required acceptance input is missing: $path"
        Assert-NoReparsePoint -Path $path -Root $script:RepoRoot
    }
    $arguments = @{
        ManifestPath = $script:AcceptanceManifestPath
        RepoRoot = $script:RepoRoot
        EvidenceRoot = $script:EvidenceRoot
        MemorySamplerPath = $script:MemorySamplerPath
        MemoryRuntimeContractPath = $script:MemoryRuntimeContractPath
        PerformanceHarnessPath = $script:PerformanceHarnessPath
        LifecycleHarnessPath = $script:LifecycleHarnessPath
    }
    return Invoke-AuthenticatedRc4EvidenceGate -Contract $Contract `
        -GateArguments $arguments
}

function Test-SafeBackupRelativePath {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Contains('\') -or $Value.StartsWith('/') -or $Value.Contains([char]0)) { return $false }
    $parts = $Value.Split('/')
    if ($parts.Count -lt 1 -or @('mods','config','options.txt','saves','Xaero','XaeroWaypoints','XaeroWorldMap') -cnotcontains $parts[0]) { return $false }
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part -ceq '.' -or $part -ceq '..' -or $part -match '(?i)(account|auth|credential|token)') { return $false }
    }
    return $true
}

function Assert-ProtectedBackup {
    Require (-not [string]::IsNullOrWhiteSpace($BackupManifestPath)) 'A completed BACKUP_MANIFEST.json path is required.'
    $expectedHash = ConvertTo-CanonicalSha256 $BackupManifestSha256 'backup manifest SHA-256'
    $full = if ([IO.Path]::IsPathRooted($BackupManifestPath)) { Get-CanonicalPath $BackupManifestPath } else { Get-CanonicalPath (Join-Path $script:RepoRoot $BackupManifestPath) }
    Assert-PathContained -Path $full -Root $script:BackupRoot | Out-Null
    Require ([IO.Path]::GetFileName($full) -ceq 'BACKUP_MANIFEST.json') 'The backup proof must name BACKUP_MANIFEST.json.'
    Assert-NoReparsePoint -Path $full -Root $script:RepoRoot
    Require ((Get-Sha256 $full) -ceq $expectedHash) 'The protected backup manifest hash mismatched.'
    $manifest = Read-StrictJsonFile -Path $full -Context 'protected backup manifest'
    Assert-ExactValue (Get-RequiredProperty $manifest 'schemaVersion' 'backup manifest') 1 'backup schemaVersion'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourcePackage' 'backup manifest') $script:Package 'backup package'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourceVersionCode' 'backup manifest') 69 'backup source versionCode'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourceVersionName' 'backup manifest') $script:V69.VersionName 'backup source versionName'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourceBaseApkSha256' 'backup manifest') $script:V69.ApkSha256 'backup source APK'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourceSignerSha256' 'backup manifest') $script:ExpectedSignerSha256 'backup source signer'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourceSignerProof' 'backup manifest') 'exact-apk-sha256-bound-to-host-audited-signer' 'backup signer proof'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sourceProfile' 'backup manifest') $script:Profile 'backup profile'
    Require ((Get-RequiredProperty $manifest 'deviceMutated' 'backup manifest') -is [bool] -and -not [bool]$manifest.deviceMutated) 'The backup reports device mutation.'
    Require ((Get-RequiredProperty $manifest 'accountOrAuthenticationFilesIncluded' 'backup manifest') -is [bool] -and -not [bool]$manifest.accountOrAuthenticationFilesIncluded) 'The backup reports account/authentication material.'
    Require (@('shell','su-read-fallback') -ccontains [string](Get-RequiredProperty $manifest 'readMode' 'backup manifest')) 'The backup read mode is not reviewed.'
    Assert-ExactValue (Get-RequiredProperty $manifest 'sensitiveNamePolicy' 'backup manifest') 'fail-before-stream-and-reject-on-host' 'backup sensitive-name policy'
    $null = ConvertTo-ValidatedRoundtripTimestamp (Get-RequiredProperty $manifest 'createdUtc' 'backup manifest') 'backup createdUtc'
    $allowedRoots = @(Get-RequiredProperty $manifest 'allowlistedRoots' 'backup manifest')
    $expectedAllowedRoots = @('mods','config','options.txt','saves','Xaero','XaeroWaypoints','XaeroWorldMap')
    Require ($allowedRoots.Count -eq $expectedAllowedRoots.Count) 'The backup allowlisted root set drifted.'
    for ($index = 0; $index -lt $expectedAllowedRoots.Count; $index++) {
        Assert-ExactValue ([string]$allowedRoots[$index]) $expectedAllowedRoots[$index] "backup allowlisted root $index"
    }

    $directory = Split-Path -Parent $full
    $files = @(Get-RequiredProperty $manifest 'files' 'backup manifest')
    $fileCount = [int](Get-RequiredProperty $manifest 'fileCount' 'backup manifest')
    Require ($fileCount -gt 0 -and $files.Count -eq $fileCount) 'The backup file list is empty or incomplete.'
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sumLines = [Collections.Generic.List[string]]::new()
    [int64]$total = 0
    foreach ($entry in $files) {
        $relative = [string](Get-RequiredProperty $entry 'path' 'backup file')
        Require (Test-SafeBackupRelativePath $relative) "Unsafe backup file path: $relative"
        Require $seen.Add($relative) "Duplicate or case-colliding backup file path: $relative"
        $size = [int64](Get-RequiredProperty $entry 'sizeBytes' "backup file $relative")
        $sha = ConvertTo-CanonicalSha256 (Get-RequiredProperty $entry 'sha256' "backup file $relative") "backup file $relative SHA-256"
        $nativeRelative = $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $path = Assert-PathContained -Path (Join-Path $directory $nativeRelative) -Root $directory
        Require (Test-Path -LiteralPath $path -PathType Leaf) "Backed-up file is missing: $relative"
        Assert-NoReparsePoint -Path $path -Root $directory
        Require ((Get-Item -LiteralPath $path).Length -eq $size) "Backed-up file size changed: $relative"
        Require ((Get-Sha256 $path) -ceq $sha) "Backed-up file hash changed: $relative"
        $sumLines.Add("$sha *$relative")
        $total += $size
    }
    Require ($total -eq [int64](Get-RequiredProperty $manifest 'totalSizeBytes' 'backup manifest')) 'The backup total size does not reaggregate.'
    $sumsPath = Join-Path $directory 'SHA256SUMS.sha256'
    Require (Test-Path -LiteralPath $sumsPath -PathType Leaf) 'The protected backup SHA256SUMS file is missing.'
    Assert-NoReparsePoint -Path $sumsPath -Root $directory
    $actualSums = @([IO.File]::ReadAllLines($sumsPath, [Text.UTF8Encoding]::new($false, $true)))
    Require ($actualSums.Count -eq $sumLines.Count) 'The protected backup SHA256SUMS row count mismatched.'
    for ($index = 0; $index -lt $sumLines.Count; $index++) {
        Require ([string]$actualSums[$index] -ceq [string]$sumLines[$index]) "The protected backup SHA256SUMS row $index mismatched."
    }
    $actualDirectories = @(Get-ChildItem -LiteralPath $directory -Directory -Recurse -Force)
    Require (@($actualDirectories | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -eq 0) 'The protected backup contains a reparse-point directory.'
    $actualPayloadFiles = @(
        Get-ChildItem -LiteralPath $directory -File -Recurse -Force | Where-Object {
            $_.FullName -cne $full -and $_.FullName -cne $sumsPath
        }
    )
    Require ($actualPayloadFiles.Count -eq $fileCount) 'The protected backup contains an unlisted or missing payload file.'
    foreach ($item in $actualPayloadFiles) {
        Require (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'The protected backup contains a reparse-point file.'
        $relative = [IO.Path]::GetRelativePath($directory,$item.FullName).Replace([IO.Path]::DirectorySeparatorChar,'/')
        Require ($seen.Contains($relative)) "The protected backup contains an unlisted payload: $relative"
    }
    return [pscustomobject]@{
        ManifestPath = $full
        ManifestSha256 = $expectedHash
        Directory = $directory
        FileCount = $fileCount
        TotalSizeBytes = $total
    }
}

function Resolve-HostContract {
    $lock = Resolve-StableLock
    $candidate = Resolve-LockedCandidatePath $lock
    $evidence = Assert-AcceptedEvidence $lock
    $backup = Assert-ProtectedBackup
    $script:StableContract = [pscustomobject]@{
        Lock = $lock
        CandidatePath = $candidate
        Evidence = $evidence
        Backup = $backup
    }
    return $script:StableContract
}

function Resolve-RollbackHostContract {
    # Recovery must not depend on the candidate APK still existing or on later
    # availability of promotion evidence. The reviewed lock and exact protected
    # v69 backup remain mandatory.
    $lock = Resolve-StableLock
    $backup = Assert-ProtectedBackup
    $script:StableContract = [pscustomobject]@{
        Lock = $lock
        CandidatePath = $null
        Evidence = [pscustomobject]@{ ManifestSha256 = $lock.AcceptanceManifestSha256 }
        Backup = $backup
    }
    return $script:StableContract
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory)][string] $FileName,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Require $process.Start() "Could not start process: $FileName"
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Resolve-Adb {
    if (Test-Path -LiteralPath $AdbPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }
    $command = Get-Command $AdbPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return [string]$command.Source }
    $sideQuest = Join-Path $env:LOCALAPPDATA 'Programs\SideQuest\resources\app.asar.unpacked\build\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $sideQuest -PathType Leaf) { return $sideQuest }
    throw '[V71_RC4_STABLE_INSTALL] ADB was not found. Pass -AdbPath with the full adb.exe path.'
}

function Invoke-AdbRaw {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $script:DeviceInvocationCount++
    return Invoke-ProcessCapture -FileName $script:ResolvedAdb -Arguments $Arguments
}

function Assert-AdbSucceeded {
    param($Result, [string] $Context, [switch] $AllowStdout)
    Require ([int]$Result.ExitCode -eq 0) "$Context failed; device output was suppressed."
    Require ([string]::IsNullOrWhiteSpace([string]$Result.Stderr)) "$Context emitted stderr and was rejected."
    if (-not $AllowStdout.IsPresent) {
        Require ([string]::IsNullOrWhiteSpace([string]$Result.Stdout)) "$Context emitted unexpected stdout."
    }
}

function Resolve-Device {
    Require $AllowDeviceRead.IsPresent 'This phase requires explicit -AllowDeviceRead.'
    $script:ResolvedAdb = Resolve-Adb
    $devices = Invoke-AdbRaw @('devices')
    Assert-AdbSucceeded $devices 'ADB endpoint enumeration' -AllowStdout
    $connected = @($devices.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\s*(?<serial>\S+)\s+device(?:\s|$)') { [string]$Matches.serial }
    })
    if ($Serial -ceq 'auto') {
        Require ($connected.Count -eq 1) 'Auto selection requires exactly one authorized ADB endpoint; pass -Serial otherwise.'
        $script:ResolvedSerial = [string]$connected[0]
    } else {
        Require ($connected -ccontains $Serial) 'The requested ADB endpoint is not connected.'
        $script:ResolvedSerial = $Serial
    }
    $state = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'get-state')
    Assert-AdbSucceeded $state 'ADB endpoint state check' -AllowStdout
    Require ($state.Stdout.Trim() -ceq 'device') 'The selected ADB endpoint is not ready.'
    $features = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'features')
    Assert-AdbSucceeded $features 'ADB feature check' -AllowStdout
    $featureSet = @($features.Stdout -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($featureSet -ccontains 'shell_v2') 'The endpoint does not advertise shell_v2; reliable remote status is required.'
    $script:DeviceResolved = $true
}

function ConvertTo-ShLiteral {
    param([Parameter(Mandatory)][string] $Value)
    $quote = [string][char]39
    return $quote + $Value.Replace($quote, $quote + '"' + $quote + '"' + $quote) + $quote
}

function New-ShellArguments {
    param([Parameter(Mandatory)][string] $Command)
    Require (-not [string]::IsNullOrWhiteSpace($Command) -and -not $Command.Contains([char]0)) 'A device shell command was empty or contained NUL.'
    return @('-s',$script:ResolvedSerial,'shell','-T','sh','-c',(ConvertTo-ShLiteral $Command))
}

function Invoke-DeviceShell {
    param([Parameter(Mandatory)][string] $Command, [switch] $AllowFailure)
    $result = Invoke-AdbRaw (New-ShellArguments $Command)
    if (-not $AllowFailure.IsPresent) {
        Assert-AdbSucceeded $result 'Device read command' -AllowStdout
    }
    return $result
}

function New-InstallArguments {
    param([Parameter(Mandatory)][string] $ApkPath)
    Require (-not [string]::IsNullOrWhiteSpace($script:ResolvedSerial)) 'The ADB endpoint is unresolved.'
    Require (Test-Path -LiteralPath $ApkPath -PathType Leaf) 'The APK selected for replacement is missing.'
    return @('-s',$script:ResolvedSerial,'install','-r',(Get-CanonicalPath $ApkPath))
}

function Assert-InstallResult {
    param($Result, [string] $Context)
    Require ([int]$Result.ExitCode -eq 0) "$Context was rejected by Android."
    Require ([string]::IsNullOrWhiteSpace([string]$Result.Stderr)) "$Context emitted stderr and was rejected."
    $rows = @($Result.Stdout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require (@($rows | Where-Object { $_ -ceq 'Success' }).Count -eq 1) "$Context did not return one exact Success row."
    Require (@($rows | Where-Object { $_ -match '(?i)failure|error|exception' }).Count -eq 0) "$Context returned a failure marker."
}

function Invoke-InstallReplace {
    param([Parameter(Mandatory)][string] $ApkPath, [string] $Context)
    Require $AllowDeviceWrite.IsPresent 'Package replacement requires explicit -AllowDeviceWrite.'
    Require $AllowInstallReplace.IsPresent 'Package replacement requires explicit -AllowInstallReplace.'
    $script:MutationAttempted = $true
    $result = Invoke-AdbRaw (New-InstallArguments $ApkPath)
    Assert-InstallResult $result $Context
    return [pscustomobject]@{ Result = 'PASS'; Command = 'adb install -r'; ExtraInstallFlags = $false }
}

function Invoke-PullBaseApk {
    param([Parameter(Mandatory)][string] $RemotePath, [Parameter(Mandatory)][string] $Destination)
    Require $AllowDeviceRead.IsPresent 'Pulling installed base.apk requires explicit -AllowDeviceRead.'
    Require (-not (Test-Path -LiteralPath $Destination)) 'The Host base.apk destination already exists.'
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'pull',$RemotePath,$Destination)
    # ADB versions disagree about which stream carries their transfer-progress
    # row. Treat the pulled bytes—not that untrusted progress text—as proof.
    Require ([int]$result.ExitCode -eq 0) 'The installed base.apk pull failed.'
    Require (Test-Path -LiteralPath $Destination -PathType Leaf) 'ADB reported success without a pulled base.apk.'
}

function Read-ExactBaseApkPath {
    param([string] $Text)
    $rows = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'pm path did not return exactly one monolithic base.apk.'
    $match = [regex]::Match([string]$rows[0],'^package:(?<path>/data/app/[^\r\n]+/base\.apk)$')
    Require $match.Success 'pm path returned malformed output.'
    $path = [string]$match.Groups['path'].Value
    Require (-not $path.Contains('..') -and -not $path.Contains('\') -and -not $path.Contains([char]0)) 'The installed base.apk path was unsafe.'
    Require ($path -cmatch ('/' + [regex]::Escape($script:Package) + '(?:-|/)')) 'The installed base.apk path is not owned by the fixed Stable package.'
    return $path
}

function Read-RemoteApkIdentity {
    $pathResult = Invoke-DeviceShell ('pm path ' + (ConvertTo-ShLiteral $script:Package))
    $basePath = Read-ExactBaseApkPath $pathResult.Stdout
    $qPath = ConvertTo-ShLiteral $basePath
    $identityResult = Invoke-DeviceShell ("set -eu; test -f $qPath; test ! -L $qPath; sha=`$(sha256sum $qPath | cut -d ' ' -f 1); size=`$(stat -c %s $qPath); printf 'APK\t%s\t%s\n' `"`$sha`" `"`$size`"")
    $rows = @($identityResult.Stdout -split "`r?`n" | Where-Object { $_ -cmatch '^APK\t[0-9a-f]{64}\t[0-9]+$' })
    Require ($rows.Count -eq 1) 'Installed APK hash/size response was ambiguous.'
    $null = $rows[0] -cmatch '^APK\t(?<sha>[0-9a-f]{64})\t(?<size>[0-9]+)$'
    $apkSha256 = ([string]$Matches.sha).ToUpperInvariant()
    $apkSizeBytes = [int64]$Matches.size
    $packageResult = Invoke-DeviceShell ('dumpsys package ' + (ConvertTo-ShLiteral $script:Package))
    $codes = @([regex]::Matches($packageResult.Stdout,'(?m)^\s*versionCode=(?<v>[0-9]+)\b') | ForEach-Object { [int]$_.Groups['v'].Value } | Sort-Object -Unique)
    $names = @([regex]::Matches($packageResult.Stdout,'(?m)^\s*versionName=(?<v>[^\r\n]+)$') | ForEach-Object { $_.Groups['v'].Value.Trim() } | Sort-Object -Unique)
    Require ($codes.Count -eq 1 -and $names.Count -eq 1) 'Installed package identity was ambiguous.'
    return [pscustomobject]@{
        Package = $script:Package
        VersionCode = [int]$codes[0]
        VersionName = [string]$names[0]
        BaseApkPath = $basePath
        ApkSha256 = $apkSha256
        ApkSizeBytes = $apkSizeBytes
    }
}

function Invoke-ApkVerifier {
    param([Parameter(Mandatory)][string] $ApkPath, [Parameter(Mandatory)] $Expected)
    $values = @(& $script:ApkVerifierPath -ApkPath $ApkPath -ExpectedPackage $script:Package -ExpectedVersionCode ([string]$Expected.VersionCode) -ExpectedVersionName ([string]$Expected.VersionName) -ExpectedLabel ([string]$Expected.Label) -ExpectedVivecraftSha256 ([string]$Expected.CoreSha256) -ExpectedVivecraftVersion ([string]$Expected.CoreVersion) -ExpectedAddOnSha256 ([string]$Expected.VeqSha256) -ExpectedAddOnVersion ([string]$Expected.VeqVersion) -ExpectedLwjglSha256 $script:ExpectedLwjglSha256 -ExpectedSignerSha256 $script:ExpectedSignerSha256)
    $objects = @($values | Where-Object { $null -ne $_.PSObject.Properties['Sha256'] -and $null -ne $_.PSObject.Properties['SignerSha256'] })
    Require ($objects.Count -eq 1) 'The APK verifier did not return one structured result.'
    $result = $objects[0]
    Require ([string]$result.Sha256 -ceq [string]$Expected.ApkSha256) 'The APK verifier returned an unexpected hash.'
    Require ([string]$result.SignerSha256 -ceq ([string]$Expected.SignerSha256).ToLowerInvariant()) 'The APK verifier returned an unexpected signer.'
    Require ([bool]$result.SignatureV2 -and [bool]$result.Zipalign16KiB) 'The APK verifier did not prove v2 signature and 16-KiB alignment.'
    return $result
}

function Assert-HostApkArtifact {
    param([string] $Path, $Expected, [string] $Context)
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "$Context is missing."
    Require ((Get-Item -LiteralPath $Path).Length -eq [int64]$Expected.ApkSizeBytes) "$Context size mismatched."
    Require ((Get-Sha256 $Path) -ceq [string]$Expected.ApkSha256) "$Context SHA-256 mismatched."
    $verified = Invoke-ApkVerifier -ApkPath $Path -Expected $Expected
    return [pscustomobject]@{
        Path = Get-CanonicalPath $Path
        Sha256 = [string]$verified.Sha256
        SizeBytes = [int64](Get-Item -LiteralPath $Path).Length
        VersionCode = [int]$verified.VersionCode
        VersionName = [string]$verified.VersionName
        SignerSha256 = ([string]$verified.SignerSha256).ToUpperInvariant()
        SignatureV2 = [bool]$verified.SignatureV2
    }
}

function Get-ExpectedTarget {
    $target = $script:StableContract.Lock.Target
    return [pscustomobject]@{
        Package = $script:Package
        VersionCode = [int]$target.VersionCode
        VersionName = [string]$target.VersionName
        Label = [string]$target.Label
        ApkSha256 = [string]$target.ApkSha256
        ApkSizeBytes = [int64]$target.ApkSizeBytes
        SignerSha256 = [string]$target.SignerSha256
        CoreSha256 = [string]$target.CoreSha256
        CoreVersion = [string]$target.CoreVersion
        VeqSha256 = [string]$target.VeqSha256
        VeqVersion = [string]$target.VeqVersion
    }
}

function Get-ExpectedV69 {
    return [pscustomobject]$script:V69
}

function Assert-InstalledArtifact {
    param([Parameter(Mandatory)] $Expected, [Parameter(Mandatory)][string] $PullPath)
    $remote = Read-RemoteApkIdentity
    Require ($remote.VersionCode -eq [int]$Expected.VersionCode) 'Installed versionCode mismatched.'
    Require ($remote.VersionName -ceq [string]$Expected.VersionName) 'Installed versionName mismatched.'
    Require ($remote.ApkSha256 -ceq [string]$Expected.ApkSha256) 'Installed base.apk remote hash mismatched.'
    Require ($remote.ApkSizeBytes -eq [int64]$Expected.ApkSizeBytes) 'Installed base.apk remote size mismatched.'
    Invoke-PullBaseApk -RemotePath $remote.BaseApkPath -Destination $PullPath
    try {
        $host = Assert-HostApkArtifact -Path $PullPath -Expected $Expected -Context 'pulled installed base.apk'
        Require ($host.Sha256 -ceq $remote.ApkSha256) 'Pulled and device-side base.apk hashes differ.'
        return [pscustomobject]@{
            Package = $script:Package
            VersionCode = $remote.VersionCode
            VersionName = $remote.VersionName
            ApkSha256 = $host.Sha256
            ApkSizeBytes = $host.SizeBytes
            SignerSha256 = $host.SignerSha256
            SignatureV2 = $host.SignatureV2
            Proof = 'remote-sha256-plus-pulled-base.apk-full-host-verification'
        }
    } catch {
        if ([IO.File]::Exists($PullPath)) { [IO.File]::Delete($PullPath) }
        throw
    }
}

function Resolve-ReceiptDirectory {
    param([switch] $Create)
    Require (-not [string]::IsNullOrWhiteSpace($ReceiptDirectory)) 'A receipt directory under artifacts/stable-v71-install is required.'
    $full = if ([IO.Path]::IsPathRooted($ReceiptDirectory)) { Get-CanonicalPath $ReceiptDirectory } else { Get-CanonicalPath (Join-Path $script:RepoRoot $ReceiptDirectory) }
    Assert-PathContained -Path $full -Root $script:ReceiptRoot | Out-Null
    Assert-NoReparsePoint -Path (Split-Path -Parent $full) -Root $script:RepoRoot
    if ($Create.IsPresent) {
        if (-not (Test-Path -LiteralPath $script:ReceiptRoot)) { [IO.Directory]::CreateDirectory($script:ReceiptRoot) | Out-Null }
        Require (-not (Test-Path -LiteralPath $full)) 'The requested receipt directory already exists.'
        [IO.Directory]::CreateDirectory($full) | Out-Null
    } else {
        Require (Test-Path -LiteralPath $full -PathType Container) 'The receipt directory does not exist.'
    }
    Assert-NoReparsePoint -Path $full -Root $script:RepoRoot
    $script:ReceiptDirectoryFull = $full
    return $full
}

function Get-RelativeRepoPath {
    param([Parameter(Mandatory)][string] $Path)
    $relative = [IO.Path]::GetRelativePath((Get-CanonicalPath $script:RepoRoot),(Get-CanonicalPath $Path))
    return $relative.Replace([IO.Path]::DirectorySeparatorChar,'/')
}

function Write-AtomicReceipt {
    param([Parameter(Mandatory)][string] $FileName, [Parameter(Mandatory)] $Body)
    Require ($FileName -cmatch '^[0-9]{2}-[a-z0-9-]+\.json$') 'Receipt file name is invalid.'
    $path = Assert-PathContained -Path (Join-Path $script:ReceiptDirectoryFull $FileName) -Root $script:ReceiptDirectoryFull
    Require (-not (Test-Path -LiteralPath $path)) "Receipt already exists: $FileName"
    $partial = "$path.partial-$([Guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($partial,($Body | ConvertTo-Json -Depth 20) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($partial,$path)
    } finally {
        if ([IO.File]::Exists($partial)) { [IO.File]::Delete($partial) }
    }
    return [pscustomobject]@{ Path = $path; Sha256 = Get-Sha256 $path }
}

function New-ReceiptBase {
    param([string] $Phase, [string] $PriorReceiptSha256 = '')
    return [ordered]@{
        schemaVersion = 1
        receiptType = 'V71_STABLE_INSTALL_PHASE'
        phase = $Phase
        status = 'PASS'
        completedUtc = [DateTime]::UtcNow.ToString('o')
        package = $script:Package
        profile = $script:Profile
        stableLockSha256 = $script:StableContract.Lock.LockSha256
        acceptanceManifestSha256 = $script:StableContract.Evidence.ManifestSha256
        backupManifestSha256 = $script:StableContract.Backup.ManifestSha256
        priorReceiptSha256 = $PriorReceiptSha256
        signerSha256 = $script:ExpectedSignerSha256
        deviceSerialPersisted = $false
        rawLogsPersisted = $false
        accountOrAuthenticationFilesRead = $false
        uninstallUsed = $false
        clearDataUsed = $false
        installCommandPolicy = 'adb install -r only; no downgrade override'
        finalAppState = 'STOPPED'
    }
}

function Assert-PriorReceipt {
    param(
        [string] $FileName,
        [string] $ExpectedPhase,
        [string] $ExpectedPriorReceiptSha256 = ''
    )
    $path = Assert-PathContained -Path (Join-Path $script:ReceiptDirectoryFull $FileName) -Root $script:ReceiptDirectoryFull
    $receipt = Read-StrictJsonFile -Path $path -Context "prior $ExpectedPhase receipt"
    Assert-ExactValue (Get-RequiredProperty $receipt 'schemaVersion' 'prior receipt') 1 'prior receipt schema'
    Assert-ExactValue (Get-RequiredProperty $receipt 'receiptType' 'prior receipt') 'V71_STABLE_INSTALL_PHASE' 'prior receipt type'
    Assert-ExactValue (Get-RequiredProperty $receipt 'phase' 'prior receipt') $ExpectedPhase 'prior receipt phase'
    Assert-ExactValue (Get-RequiredProperty $receipt 'status' 'prior receipt') 'PASS' 'prior receipt status'
    Assert-ExactValue (Get-RequiredProperty $receipt 'package' 'prior receipt') $script:Package 'prior receipt package'
    Assert-ExactValue (Get-RequiredProperty $receipt 'stableLockSha256' 'prior receipt') $script:StableContract.Lock.LockSha256 'prior receipt Stable lock'
    Assert-ExactValue (Get-RequiredProperty $receipt 'acceptanceManifestSha256' 'prior receipt') $script:StableContract.Evidence.ManifestSha256 'prior receipt acceptance evidence'
    Assert-ExactValue (Get-RequiredProperty $receipt 'backupManifestSha256' 'prior receipt') $script:StableContract.Backup.ManifestSha256 'prior receipt protected backup'
    Assert-ExactValue (Get-RequiredProperty $receipt 'signerSha256' 'prior receipt') $script:ExpectedSignerSha256 'prior receipt signer'
    Assert-ExactValue (Get-RequiredProperty $receipt 'finalAppState' 'prior receipt') 'STOPPED' 'prior receipt final state'
    Assert-ExactValue (Get-RequiredProperty $receipt 'priorReceiptSha256' 'prior receipt') $ExpectedPriorReceiptSha256 'prior receipt chain link'
    return [pscustomobject]@{ Path = $path; Sha256 = Get-Sha256 $path; Receipt = $receipt }
}

function Get-ExactProcessId {
    param([switch] $AllowMissing)
    $qPackage = ConvertTo-ShLiteral $script:Package
    $command = "out=`$(pidof $qPackage); rc=`$?; if [ `"`$rc`" -eq 0 ]; then printf 'PID\t%s\n' `"`$out`"; elif [ `"`$rc`" -eq 1 ]; then printf 'ABSENT\n'; else exit `"`$rc`"; fi"
    $result = Invoke-DeviceShell $command
    $rows = @($result.Stdout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Require ($rows.Count -eq 1) 'Stable PID response was ambiguous.'
    if ($rows[0] -ceq 'ABSENT') {
        if ($AllowMissing.IsPresent) { return $null }
        throw '[V71_RC4_STABLE_INSTALL] Stable has no running process.'
    }
    Require ($rows[0] -cmatch '^PID\t(?<values>[0-9]+(?:\s+[0-9]+)*)$') 'Stable PID response was malformed.'
    $values = @($Matches.values -split '\s+')
    Require ($values.Count -eq 1) 'Stable has more than one process.'
    return [int]$values[0]
}

function Assert-StableStopped {
    Require ($null -eq (Get-ExactProcessId -AllowMissing)) 'Stable must be stopped.'
}

function Stop-Stable {
    Require $AllowDeviceWrite.IsPresent 'Stopping Stable requires explicit -AllowDeviceWrite.'
    Require $AllowForceStop.IsPresent 'Stopping Stable requires explicit -AllowForceStop.'
    $script:MutationAttempted = $true
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','am','force-stop',$script:Package)
    Assert-AdbSucceeded $result 'Stable force-stop' -AllowStdout
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($null -eq (Get-ExactProcessId -AllowMissing)) { return }
        Start-Sleep -Milliseconds 250
    }
    throw '[V71_RC4_STABLE_INSTALL] Stable did not stop in the bounded window.'
}

function Start-StableNormal {
    Require $AllowDeviceWrite.IsPresent 'Starting Stable requires explicit -AllowDeviceWrite.'
    Require $AllowLaunch.IsPresent 'Starting Stable requires explicit -AllowLaunch.'
    Assert-StableStopped
    $script:MutationAttempted = $true
    $result = Invoke-AdbRaw @('-s',$script:ResolvedSerial,'shell','am','start','-n',$script:Component)
    Require ([int]$result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace([string]$result.Stderr)) 'The explicit Stable component start failed.'
    Require ($result.Stdout -notmatch '(?i)error|exception') 'The explicit Stable component start returned an error marker.'
}

function Test-StableFocused {
    $result = Invoke-DeviceShell 'dumpsys activity activities' -AllowFailure
    if ($result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$result.Stderr)) { return $false }
    $row = $result.Stdout -split "`r?`n" | Where-Object { $_ -match 'topResumedActivity' } | Select-Object -First 1
    if ($null -eq $row) {
        $row = $result.Stdout -split "`r?`n" | Where-Object { $_ -match '(?:mResumedActivity|ResumedActivity)' } | Select-Object -First 1
    }
    return $null -ne $row -and [string]$row -match ([regex]::Escape($script:Package) + '/')
}

function Get-ThreadNames {
    param([Parameter(Mandatory)][int] $ProcessId)
    $command = "for f in /proc/$ProcessId/task/*/comm; do test -r `"`$f`" && cat `"`$f`" 2>/dev/null || true; done"
    $result = Invoke-DeviceShell $command
    return @($result.Stdout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-PhysicalPair {
    $qCore = ConvertTo-ShLiteral $script:CoreDevicePath
    $qVeq = ConvertTo-ShLiteral $script:VeqDevicePath
    $qMods = ConvertTo-ShLiteral "$($script:GameDirectory)/mods"
    $command = @(
        'set -eu'
        "test -d $qMods && test ! -L $qMods"
        "test -f $qCore && test ! -L $qCore"
        "test -f $qVeq && test ! -L $qVeq"
        'seen_core=0; seen_veq=0; unexpected=0'
        "for file in $qMods/*; do test -f `"`$file`" || continue; leaf=`"`${file##*/}`"; lower=`$(printf '%s' `"`$leaf`" | tr '[:upper:]' '[:lower:]'); case `"`$lower`" in vivecraft.jar) seen_core=`$((seen_core+1));; vivecraft-essentials-quest.jar) seen_veq=`$((seen_veq+1));; *vivecraft*.jar) unexpected=`$((unexpected+1));; esac; done"
        'test "$seen_core" -eq 1 && test "$seen_veq" -eq 1 && test "$unexpected" -eq 0'
        "core_sha=`$(sha256sum $qCore | cut -d ' ' -f 1); core_size=`$(stat -c %s $qCore)"
        "veq_sha=`$(sha256sum $qVeq | cut -d ' ' -f 1); veq_size=`$(stat -c %s $qVeq)"
        'printf ''PAIR\t%s\t%s\t%s\t%s\n'' "$core_sha" "$core_size" "$veq_sha" "$veq_size"'
    ) -join "`n"
    $result = Invoke-DeviceShell $command
    $rows = @($result.Stdout -split "`r?`n" | Where-Object { $_ -cmatch '^PAIR\t[0-9a-f]{64}\t[0-9]+\t[0-9a-f]{64}\t[0-9]+$' })
    Require ($rows.Count -eq 1) 'The physical Core/VEQ proof was ambiguous.'
    $null = $rows[0] -cmatch '^PAIR\t(?<core>[0-9a-f]{64})\t(?<coreSize>[0-9]+)\t(?<veq>[0-9a-f]{64})\t(?<veqSize>[0-9]+)$'
    $coreSha = $Matches.core.ToUpperInvariant()
    $veqSha = $Matches.veq.ToUpperInvariant()
    Require ($coreSha -ceq $script:ExpectedCoreSha256 -and [int64]$Matches.coreSize -eq $script:ExpectedCoreSizeBytes) 'The physical Core is not exact RC4.'
    Require ($veqSha -ceq $script:ExpectedVeqSha256 -and [int64]$Matches.veqSize -eq $script:ExpectedVeqSizeBytes) 'The physical VEQ is not exact RC4.'
    return [pscustomobject]@{
        CoreSha256 = $coreSha
        CoreSizeBytes = [int64]$Matches.coreSize
        VeqSha256 = $veqSha
        VeqSizeBytes = [int64]$Matches.veqSize
        UnexpectedVivecraftJars = 0
    }
}

function Get-LogSnapshot {
    $qLog = ConvertTo-ShLiteral $script:MinecraftLogPath
    $command = @(
        'set -eu'
        "log=$qLog"
        'if [ ! -e "$log" ]; then printf ''LOG\tABSENT\t0\t0\tABSENT\t0\n''; exit 0; fi'
        'test -f "$log" && test ! -L "$log"'
        'inode=$(stat -c %i "$log"); size=$(stat -c %s "$log"); mtime=$(stat -c %Y "$log")'
        'n=$size; if [ "$n" -gt 4096 ]; then n=4096; fi'
        'if [ "$n" -eq 0 ]; then prefix=EMPTY; else prefix=$(head -c "$n" "$log" | sha256sum | cut -d " " -f 1); fi'
        'printf ''LOG\t%s\t%s\t%s\t%s\t%s\n'' "$inode" "$size" "$n" "$prefix" "$mtime"'
    ) -join "`n"
    $result = Invoke-DeviceShell $command
    $rows = @($result.Stdout -split "`r?`n" | Where-Object { $_ -cmatch '^LOG\t(?:ABSENT|[0-9]+)\t[0-9]+\t[0-9]+\t(?:ABSENT|EMPTY|[0-9a-f]{64})\t[0-9]+$' })
    Require ($rows.Count -eq 1) 'Minecraft log snapshot was ambiguous.'
    $null = $rows[0] -cmatch '^LOG\t(?<inode>ABSENT|[0-9]+)\t(?<size>[0-9]+)\t(?<bytes>[0-9]+)\t(?<prefix>ABSENT|EMPTY|[0-9a-f]{64})\t(?<mtime>[0-9]+)$'
    return [pscustomobject]@{
        Inode = [string]$Matches.inode
        SizeBytes = [int64]$Matches.size
        PrefixBytes = [int]$Matches.bytes
        PrefixSha256 = [string]$Matches.prefix
        Mtime = [int64]$Matches.mtime
    }
}

function Wait-StableRuntimeReady {
    param($Baseline, [string] $Phase)
    $qLog = ConvertTo-ShLiteral $script:MinecraftLogPath
    $qCoreVersion = ConvertTo-ShLiteral $script:ExpectedCoreVersion
    $qVeqVersion = ConvertTo-ShLiteral $script:ExpectedVeqVersion
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    $firstProcessId = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $currentProcessId = Get-ExactProcessId -AllowMissing
        if ($null -eq $currentProcessId) {
            Require ($null -eq $firstProcessId) "$Phase process disappeared after launch."
            Start-Sleep -Seconds 1
            continue
        }
        if ($null -eq $firstProcessId) { $firstProcessId = [int]$currentProcessId }
        Require ([int]$currentProcessId -eq [int]$firstProcessId) "$Phase crossed Android process identities."
        $startOffset = [int64]$Baseline.SizeBytes + 1
        $baselineInode = [string]$Baseline.Inode
        $baselinePrefix = [string]$Baseline.PrefixSha256
        $baselineBytes = [int]$Baseline.PrefixBytes
        $command = @(
            'set -eu'
            "log=$qLog"
            'test -f "$log" && test ! -L "$log"'
            'inode=$(stat -c %i "$log"); size=$(stat -c %s "$log"); start=1; mode=NEW_FILE'
            "if [ '$baselineInode' != ABSENT ] && [ `"`$inode`" = '$baselineInode' ] && [ `"`$size`" -ge $($Baseline.SizeBytes) ]; then"
            "  if [ $baselineBytes -eq 0 ]; then prefix=EMPTY; else prefix=`$(head -c $baselineBytes `"`$log`" | sha256sum | cut -d `" `" -f 1); fi"
            "  if [ `"`$prefix`" = '$baselinePrefix' ]; then start=$startOffset; mode=APPEND; fi"
            'fi'
            'if [ "$start" -le "$size" ]; then'
            "  core=`$(tail -c +`"`$start`" `"`$log`" | grep -F -c $qCoreVersion || true)"
            "  veq=`$(tail -c +`"`$start`" `"`$log`" | grep -F -c $qVeqVersion || true)"
            '  focused=$(tail -c +"$start" "$log" | grep -F -c ''Vivecraft: OpenXR session state changed to FOCUSED'' || true)'
            '  frame=$(tail -c +"$start" "$log" | grep -F -c ''Vivecraft: OpenXR submitted frame 120 '' || true)'
            '  terminal=$(tail -c +"$start" "$log" | grep -c -E -e ''---- Minecraft Crash Report ----|ReportedException|Minecraft has crashed|Game crashed|MixinApplyError|LinkageError|FATAL EXCEPTION'' || true)'
            'else core=0; veq=0; focused=0; frame=0; terminal=0; fi'
            'fresh=$((size-start+1)); if [ "$fresh" -lt 0 ]; then fresh=0; fi'
            'printf ''READY\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n'' "$inode" "$start" "$mode" "$fresh" "$core" "$veq" "$focused" "$frame" "$terminal"'
        ) -join "`n"
        $result = Invoke-DeviceShell $command -AllowFailure
        if ($result.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace([string]$result.Stderr)) {
            $rows = @($result.Stdout -split "`r?`n" | Where-Object { $_ -cmatch '^READY\t[0-9]+\t[0-9]+\t(?:APPEND|NEW_FILE)\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+\t[0-9]+$' })
            if ($rows.Count -eq 1) {
                $null = $rows[0] -cmatch '^READY\t(?<inode>[0-9]+)\t(?<start>[0-9]+)\t(?<mode>APPEND|NEW_FILE)\t(?<fresh>[0-9]+)\t(?<core>[0-9]+)\t(?<veq>[0-9]+)\t(?<focused>[0-9]+)\t(?<frame>[0-9]+)\t(?<terminal>[0-9]+)$'
                if ([int]$Matches.terminal -gt 0) { throw "[V71_RC4_STABLE_INSTALL] $Phase observed a terminal runtime marker." }
                $threads = Get-ThreadNames ([int]$currentProcessId)
                $gameJvm = @($threads | Where-Object { $_ -ceq 'QuestCraft-JVM' }).Count -eq 1
                if ([int]$Matches.fresh -gt 0 -and [int]$Matches.core -ge 1 -and [int]$Matches.veq -ge 1 -and [int]$Matches.focused -ge 1 -and [int]$Matches.frame -ge 1 -and $gameJvm -and (Test-StableFocused)) {
                    return [pscustomobject]@{
                        Result = 'PASS'
                        Phase = $Phase
                        ProcessId = [int]$currentProcessId
                        ExactRc4VersionRows = $true
                        OpenXrFocused = $true
                        OpenXrFrame120Submitted = $true
                        GameJvmAlive = $true
                        FreshLogBytes = [int64]$Matches.fresh
                        LogInode = [string]$Matches.inode
                        LogStartOffset = [int64]$Matches.start
                        LogSliceMode = [string]$Matches.mode
                    }
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    throw "[V71_RC4_STABLE_INSTALL] $Phase did not reach exact RC4/OpenXR readiness in ten minutes. Use the normal launcher UI; the harness sends no account or UI input."
}

function Invoke-NormalStartCycle {
    param([string] $Phase)
    Stop-Stable
    $baseline = Get-LogSnapshot
    Start-Sleep -Milliseconds 1100
    Start-StableNormal
    $proof = Wait-StableRuntimeReady -Baseline $baseline -Phase $Phase
    $pair = Get-PhysicalPair
    Stop-Stable
    Assert-StableStopped
    return [pscustomobject]@{ Runtime = $proof; Pair = $pair; FinalState = 'STOPPED' }
}

function Get-RuntimeHealth {
    param([Parameter(Mandatory)] $ReadyProof)
    $currentProcessId = Get-ExactProcessId
    Require ([int]$currentProcessId -eq [int]$ReadyProof.ProcessId) 'The final gate crossed Android process identities.'
    $threads = Get-ThreadNames ([int]$currentProcessId)
    Require (@($threads | Where-Object { $_ -ceq 'QuestCraft-JVM' }).Count -eq 1) 'The final gate lost the QuestCraft-JVM thread.'
    Require (Test-StableFocused) 'The final gate lost Stable focus.'
    $qLog = ConvertTo-ShLiteral $script:MinecraftLogPath
    $inode = [string]$ReadyProof.LogInode
    $offset = [int64]$ReadyProof.LogStartOffset
    $command = @(
        'set -eu'
        "log=$qLog"
        'test -f "$log" && test ! -L "$log"'
        "test `"`$(stat -c %i `"`$log`")`" = '$inode'"
        "terminal=`$(tail -c +$offset `"`$log`" | grep -c -E -e '---- Minecraft Crash Report ----|ReportedException|Minecraft has crashed|Game crashed|MixinApplyError|LinkageError|FATAL EXCEPTION' || true)"
        'printf ''HEALTH\t%s\n'' "$terminal"'
    ) -join "`n"
    $result = Invoke-DeviceShell $command
    $rows = @($result.Stdout -split "`r?`n" | Where-Object { $_ -cmatch '^HEALTH\t[0-9]+$' })
    Require ($rows.Count -eq 1 -and $rows[0] -ceq "HEALTH`t0") 'The final gate observed a terminal runtime marker.'
    return [pscustomobject]@{ ProcessIdStable = $true; Focused = $true; GameJvmAlive = $true; TerminalMarkers = 0 }
}

function Assert-ReadWriteStopAuthorization {
    Require $AllowDeviceRead.IsPresent 'This phase requires explicit -AllowDeviceRead.'
    Require $AllowDeviceWrite.IsPresent 'This phase requires explicit -AllowDeviceWrite.'
    Require $AllowForceStop.IsPresent 'This phase requires explicit -AllowForceStop.'
    if ($AllowRollbackOnFailure.IsPresent) {
        Require $AllowInstallReplace.IsPresent 'Authorized failure rollback also requires -AllowInstallReplace.'
    }
}

function Assert-InstallAuthorization {
    Assert-ReadWriteStopAuthorization
    Require $AllowInstallReplace.IsPresent 'Install requires explicit -AllowInstallReplace.'
}

function Assert-LaunchAuthorization {
    Assert-ReadWriteStopAuthorization
    Require $AllowLaunch.IsPresent 'Runtime phases require explicit -AllowLaunch.'
}

function Assert-RollbackApkReady {
    param([string] $Path)
    Require (Test-Path -LiteralPath $Path -PathType Leaf) 'The exact pulled v69 rollback APK is absent.'
    Assert-NoReparsePoint -Path $Path -Root $script:ReceiptDirectoryFull
    return Assert-HostApkArtifact -Path $Path -Expected (Get-ExpectedV69) -Context 'exact v69 rollback APK'
}

function Invoke-ConservativeRollback {
    param([string] $RollbackApkPath)
    $result = [ordered]@{
        Attempted = $false
        Command = 'adb install -r'
        DowngradeOverrideUsed = $false
        AndroidAccepted = $false
        ExactV69Restored = $false
        DataDeletionAttempted = $false
        FinalStopProven = $false
    }
    if (-not $AllowRollbackOnFailure.IsPresent -and -not $AllowRollbackDowngrade.IsPresent) {
        return [pscustomobject]$result
    }
    Assert-InstallAuthorization
    $null = Assert-RollbackApkReady $RollbackApkPath
    $result.Attempted = $true
    try {
        Stop-Stable
        $null = Invoke-InstallReplace -ApkPath $RollbackApkPath -Context 'same-signer v69 conservative downgrade'
        $result.AndroidAccepted = $true
        $probePath = Join-Path $script:ReceiptDirectoryFull ('.rollback-verify-' + [Guid]::NewGuid().ToString('N') + '.apk')
        try {
            $null = Assert-InstalledArtifact -Expected (Get-ExpectedV69) -PullPath $probePath
            $result.ExactV69Restored = $true
        } finally {
            if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) }
        }
    } catch {
        # Android normally rejects a lower versionCode when only -r is used.
        # Do not add -d, uninstall, clear data, or attempt any recovery bypass.
        $result.AndroidAccepted = $false
        $result.ExactV69Restored = $false
    } finally {
        Stop-Stable
        Assert-StableStopped
        $result.FinalStopProven = $true
    }
    return [pscustomobject]$result
}

function Invoke-FailureRecovery {
    param(
        [string] $RollbackApkPath,
        [System.Management.Automation.ErrorRecord] $PrimaryError,
        [bool] $RollbackEligible
    )
    $stopError = $null
    if ($script:DeviceResolved -and $script:MutationAttempted) {
        try { Stop-Stable } catch { $stopError = $_.Exception.Message }
    }
    $rollback = [pscustomobject]@{
        Attempted = $false
        Command = 'adb install -r'
        DowngradeOverrideUsed = $false
        AndroidAccepted = $false
        ExactV69Restored = $false
        DataDeletionAttempted = $false
        FinalStopProven = ($null -eq $stopError)
    }
    if ($script:DeviceResolved -and $RollbackEligible -and $AllowRollbackOnFailure.IsPresent -and -not [string]::IsNullOrWhiteSpace($RollbackApkPath)) {
        try {
            $rollback = Invoke-ConservativeRollback -RollbackApkPath $RollbackApkPath
        } catch {
            $parts = [Collections.Generic.List[string]]::new()
            $parts.Add($PrimaryError.Exception.Message)
            $parts.Add("rollback/final-stop failure: $($_.Exception.Message)")
            throw ('[V71_RC4_STABLE_INSTALL] ' + ($parts -join '; '))
        }
    }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add($PrimaryError.Exception.Message)
    if ($null -ne $stopError) { $parts.Add("final stop failed: $stopError") }
    if ($rollback.Attempted) {
        if ($rollback.ExactV69Restored) {
            $parts.Add('explicit same-signer v69 install -r rollback restored exact v69')
        } else {
            $parts.Add('Android rejected or failed the conservative v69 install -r rollback; stopped without deletion')
        }
    } else {
        if (-not $RollbackEligible) {
            $parts.Add('package replacement had not begun, so no rollback was eligible; stopped without deletion')
        } else {
            $parts.Add('rollback was not explicitly authorized; stopped without deletion')
        }
    }
    throw ('[V71_RC4_STABLE_INSTALL] ' + ($parts -join '; '))
}

function Get-Plan {
    return [pscustomobject]@{
        Result = 'PLAN'
        HostOnly = $true
        DeviceInvocations = 0
        Package = $script:Package
        StableLockRequired = 'V71_STABLE.lock.json (copied and completed from V71_STABLE.lock.template.json)'
        AcceptanceRequired = 'V71_STABLE_RC4_ACCEPTANCE.lock.json status ACCEPTED_FOR_STABLE_BUILD and full evidence revalidation'
        ProtectedBackupRequired = 'exact v69 BACKUP_MANIFEST.json plus caller-supplied SHA-256 and all file hashes'
        Phases = @(
            'Install -> 01-install-and-immediate-verify.json',
            'VerifyInstalled -> 02-post-install-verify.json',
            'ThreeNormalStarts -> 03-three-normal-starts.json',
            'Final30MinuteGate -> 04-final-30m.json'
        )
        Authorization = [ordered]@{
            Install = '-AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowInstallReplace'
            VerifyInstalled = '-AllowDeviceRead -AllowDeviceWrite -AllowForceStop'
            ThreeNormalStarts = '-AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowLaunch'
            Final30MinuteGate = '-AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowLaunch'
            FailureRollback = 'add -AllowRollbackOnFailure and -AllowInstallReplace'
            ExplicitRollback = '-AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowInstallReplace -AllowRollbackDowngrade'
        }
        InstallCommand = 'adb install -r only'
        RollbackPolicy = 'same-signer exact v69 through adb install -r only; Android rejection is terminal; no -d or data deletion'
        NormalStartPolicy = 'explicit component start only; operator may use normal launcher UI; no autoplay or synthetic input'
        FinalState = 'Stable stopped after every phase and every handled failure'
        Never = @('uninstall','pm clear','downgrade override','account/authentication access','root','run-as','synthetic UI input')
    }
}

function Invoke-InstallPhase {
    Assert-InstallAuthorization
    $null = Assert-Rc4CandidateEvidenceReady
    $contract = Resolve-HostContract
    $directory = Resolve-ReceiptDirectory -Create
    $candidateArtifact = Assert-HostApkArtifact -Path $contract.CandidatePath -Expected (Get-ExpectedTarget) -Context 'locked v71 Stable APK'
    $rollbackPath = Join-Path $directory 'v69-rollback.apk'
    try {
        Resolve-Device
        Stop-Stable
        $baseline = Assert-InstalledArtifact -Expected (Get-ExpectedV69) -PullPath $rollbackPath
        Require ($baseline.SignerSha256 -ceq $candidateArtifact.SignerSha256) 'The installed v69 baseline and v71 candidate do not have the exact same signer.'
        $null = Assert-ProtectedBackup
        $null = Assert-AcceptedEvidence $contract.Lock
        $candidateReadLock = [IO.File]::Open($contract.CandidatePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            Require ((Get-Sha256 $contract.CandidatePath) -ceq $contract.Lock.Target.ApkSha256) 'The candidate APK changed before installation.'
            $script:CandidateInstallAttempted = $true
            $install = Invoke-InstallReplace -ApkPath $contract.CandidatePath -Context 'v71 Stable replace install'
        } finally {
            $candidateReadLock.Dispose()
        }
        $verifyPath = Join-Path $directory ('.installed-v71-' + [Guid]::NewGuid().ToString('N') + '.apk')
        try {
            $installed = Assert-InstalledArtifact -Expected (Get-ExpectedTarget) -PullPath $verifyPath
        } finally {
            if ([IO.File]::Exists($verifyPath)) { [IO.File]::Delete($verifyPath) }
        }
        Stop-Stable
        Assert-StableStopped
        Require ((Get-Sha256 $contract.CandidatePath) -ceq $contract.Lock.Target.ApkSha256) 'The candidate APK changed during installation.'
        Require ((Get-Sha256 $contract.Lock.LockPath) -ceq $contract.Lock.LockSha256) 'The reviewed Stable lock changed during installation.'
        $receipt = New-ReceiptBase -Phase 'INSTALL_AND_IMMEDIATE_VERIFY'
        $receipt.target = $installed
        $receipt.baseline = $baseline
        $receipt.rollbackApk = [ordered]@{
            relativePath = Get-RelativeRepoPath $rollbackPath
            sha256 = Get-Sha256 $rollbackPath
            sizeBytes = (Get-Item -LiteralPath $rollbackPath).Length
            exactV69 = $true
            sameSignerAsTarget = $true
            committedToGit = $false
        }
        $receipt.install = $install
        $receipt.immediatePostInstallBaseApkVerified = $true
        $written = Write-AtomicReceipt -FileName '01-install-and-immediate-verify.json' -Body $receipt
        return [pscustomobject]@{
            Result = 'PASS'
            Phase = $receipt.phase
            ReceiptPath = $written.Path
            ReceiptSha256 = $written.Sha256
            InstalledApkSha256 = $installed.ApkSha256
            SignerSha256 = $installed.SignerSha256
            FinalAppState = 'STOPPED'
        }
    } catch {
        Invoke-FailureRecovery -RollbackApkPath $rollbackPath -PrimaryError $_ -RollbackEligible $script:CandidateInstallAttempted
    }
}

function Invoke-VerifyInstalledPhase {
    Assert-ReadWriteStopAuthorization
    $null = Assert-Rc4CandidateEvidenceReady
    $null = Resolve-HostContract
    $directory = Resolve-ReceiptDirectory
    $prior = Assert-PriorReceipt -FileName '01-install-and-immediate-verify.json' -ExpectedPhase 'INSTALL_AND_IMMEDIATE_VERIFY'
    $rollbackPath = Join-Path $directory 'v69-rollback.apk'
    $targetVerified = $false
    if ($AllowRollbackOnFailure.IsPresent) { $null = Assert-RollbackApkReady $rollbackPath }
    try {
        Resolve-Device
        Stop-Stable
        $verifyPath = Join-Path $directory ('.post-install-v71-' + [Guid]::NewGuid().ToString('N') + '.apk')
        try {
            $installed = Assert-InstalledArtifact -Expected (Get-ExpectedTarget) -PullPath $verifyPath
            $targetVerified = $true
        } finally {
            if ([IO.File]::Exists($verifyPath)) { [IO.File]::Delete($verifyPath) }
        }
        Stop-Stable
        $receipt = New-ReceiptBase -Phase 'POST_INSTALL_VERIFY' -PriorReceiptSha256 $prior.Sha256
        $receipt.target = $installed
        $receipt.baseApkHashIdentityAndSignatureVerified = $true
        $receipt.profileRead = $false
        $written = Write-AtomicReceipt -FileName '02-post-install-verify.json' -Body $receipt
        return [pscustomobject]@{
            Result = 'PASS'
            Phase = $receipt.phase
            ReceiptPath = $written.Path
            ReceiptSha256 = $written.Sha256
            BaseApkHashIdentityAndSignatureVerified = $true
            FinalAppState = 'STOPPED'
        }
    } catch {
        Invoke-FailureRecovery -RollbackApkPath $rollbackPath -PrimaryError $_ -RollbackEligible $targetVerified
    }
}

function Invoke-ThreeNormalStartsPhase {
    Assert-LaunchAuthorization
    $null = Assert-Rc4CandidateEvidenceReady
    $null = Resolve-HostContract
    $directory = Resolve-ReceiptDirectory
    $installReceipt = Assert-PriorReceipt -FileName '01-install-and-immediate-verify.json' -ExpectedPhase 'INSTALL_AND_IMMEDIATE_VERIFY'
    $prior = Assert-PriorReceipt -FileName '02-post-install-verify.json' -ExpectedPhase 'POST_INSTALL_VERIFY' -ExpectedPriorReceiptSha256 $installReceipt.Sha256
    $rollbackPath = Join-Path $directory 'v69-rollback.apk'
    $targetVerified = $false
    if ($AllowRollbackOnFailure.IsPresent) { $null = Assert-RollbackApkReady $rollbackPath }
    try {
        Resolve-Device
        Stop-Stable
        $verifyPath = Join-Path $directory ('.pre-start-v71-' + [Guid]::NewGuid().ToString('N') + '.apk')
        try {
            $null = Assert-InstalledArtifact -Expected (Get-ExpectedTarget) -PullPath $verifyPath
            $targetVerified = $true
        } finally {
            if ([IO.File]::Exists($verifyPath)) { [IO.File]::Delete($verifyPath) }
        }
        $cycles = [Collections.Generic.List[object]]::new()
        for ($number = 1; $number -le 3; $number++) {
            $cycles.Add((Invoke-NormalStartCycle -Phase "normal-start-$number"))
        }
        $pairAfter = Get-PhysicalPair
        Stop-Stable
        $receipt = New-ReceiptBase -Phase 'THREE_NORMAL_STARTS' -PriorReceiptSha256 $prior.Sha256
        $receipt.startCount = 3
        $receipt.startMethod = 'explicit component start; normal launcher UI; no autoplay or synthetic input'
        $receipt.exactRc4PersistenceEveryStart = $true
        $receipt.noUnexpectedVivecraftJars = $true
        $receipt.cycles = $cycles.ToArray()
        $receipt.finalPair = $pairAfter
        $written = Write-AtomicReceipt -FileName '03-three-normal-starts.json' -Body $receipt
        return [pscustomobject]@{
            Result = 'PASS'
            Phase = $receipt.phase
            ReceiptPath = $written.Path
            ReceiptSha256 = $written.Sha256
            StartCount = 3
            ExactRc4PersistenceEveryStart = $true
            FinalAppState = 'STOPPED'
        }
    } catch {
        Invoke-FailureRecovery -RollbackApkPath $rollbackPath -PrimaryError $_ -RollbackEligible $targetVerified
    }
}

function Invoke-FinalThirtyMinutePhase {
    Assert-LaunchAuthorization
    $null = Assert-Rc4CandidateEvidenceReady
    $null = Resolve-HostContract
    $directory = Resolve-ReceiptDirectory
    $installReceipt = Assert-PriorReceipt -FileName '01-install-and-immediate-verify.json' -ExpectedPhase 'INSTALL_AND_IMMEDIATE_VERIFY'
    $postInstallReceipt = Assert-PriorReceipt -FileName '02-post-install-verify.json' -ExpectedPhase 'POST_INSTALL_VERIFY' -ExpectedPriorReceiptSha256 $installReceipt.Sha256
    $prior = Assert-PriorReceipt -FileName '03-three-normal-starts.json' -ExpectedPhase 'THREE_NORMAL_STARTS' -ExpectedPriorReceiptSha256 $postInstallReceipt.Sha256
    $rollbackPath = Join-Path $directory 'v69-rollback.apk'
    $targetVerified = $false
    if ($AllowRollbackOnFailure.IsPresent) { $null = Assert-RollbackApkReady $rollbackPath }
    try {
        Resolve-Device
        Stop-Stable
        $verifyPath = Join-Path $directory ('.pre-30m-v71-' + [Guid]::NewGuid().ToString('N') + '.apk')
        try {
            $null = Assert-InstalledArtifact -Expected (Get-ExpectedTarget) -PullPath $verifyPath
            $targetVerified = $true
        } finally {
            if ([IO.File]::Exists($verifyPath)) { [IO.File]::Delete($verifyPath) }
        }
        $baseline = Get-LogSnapshot
        Start-Sleep -Milliseconds 1100
        Start-StableNormal
        $ready = Wait-StableRuntimeReady -Baseline $baseline -Phase 'final-30m-start'
        $pairBefore = Get-PhysicalPair
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $sampleCount = 0
        $lastSampleStartedSeconds = $null
        [double]$maximumObservedSampleIntervalSeconds = 0
        [double]$targetSampleIntervalSeconds = 8
        [double]$maximumAllowedSampleIntervalSeconds = 10
        while ($watch.Elapsed.TotalSeconds -lt 1800) {
            [double]$sampleStartedSeconds = $watch.Elapsed.TotalSeconds
            if ($null -ne $lastSampleStartedSeconds) {
                [double]$observedIntervalSeconds = $sampleStartedSeconds - [double]$lastSampleStartedSeconds
                Require ($observedIntervalSeconds -le $maximumAllowedSampleIntervalSeconds) 'The final gate exceeded its ten-second health-sample boundary.'
                $maximumObservedSampleIntervalSeconds = [Math]::Max($maximumObservedSampleIntervalSeconds,$observedIntervalSeconds)
            }
            $null = Get-RuntimeHealth $ready
            $sampleCount++
            $lastSampleStartedSeconds = $sampleStartedSeconds
            $remaining = 1800 - $watch.Elapsed.TotalSeconds
            $untilNextSample = ($sampleStartedSeconds + $targetSampleIntervalSeconds) - $watch.Elapsed.TotalSeconds
            if ($remaining -gt 0 -and $untilNextSample -gt 0) {
                $sleepMilliseconds = [int][Math]::Ceiling([Math]::Min($remaining,$untilNextSample) * 1000)
                Start-Sleep -Milliseconds $sleepMilliseconds
            }
        }
        [double]$finalSampleStartedSeconds = $watch.Elapsed.TotalSeconds
        [double]$finalObservedIntervalSeconds = $finalSampleStartedSeconds - [double]$lastSampleStartedSeconds
        Require ($finalObservedIntervalSeconds -le $maximumAllowedSampleIntervalSeconds) 'The final gate exceeded its ten-second health-sample boundary before the endpoint sample.'
        $maximumObservedSampleIntervalSeconds = [Math]::Max($maximumObservedSampleIntervalSeconds,$finalObservedIntervalSeconds)
        $null = Get-RuntimeHealth $ready
        $sampleCount++
        $durationSeconds = [Math]::Floor($watch.Elapsed.TotalSeconds)
        $watch.Stop()
        Require ($durationSeconds -ge 1800 -and $sampleCount -ge 181) 'The final gate did not cover a complete 30 minutes with endpoint samples.'
        $pairAfter = Get-PhysicalPair
        $remote = Read-RemoteApkIdentity
        Require ($remote.ApkSha256 -ceq $script:StableContract.Lock.Target.ApkSha256 -and $remote.VersionCode -eq 71) 'The installed v71 identity changed during the final gate.'
        Stop-Stable
        $receipt = New-ReceiptBase -Phase 'FINAL_30_MINUTE_GATE' -PriorReceiptSha256 $prior.Sha256
        $receipt.durationSeconds = $durationSeconds
        $receipt.minimumDurationSeconds = 1800
        $receipt.healthSampleCount = $sampleCount
        $receipt.maximumSampleIntervalSeconds = 10
        $receipt.maximumObservedSampleIntervalSeconds = [Math]::Round($maximumObservedSampleIntervalSeconds,3)
        $receipt.targetSampleIntervalSeconds = 8
        $receipt.pidStable = $true
        $receipt.focusStayedOnStable = $true
        $receipt.gameJvmStayedAlive = $true
        $receipt.terminalRuntimeMarkers = 0
        $receipt.exactRc4PairBefore = $pairBefore
        $receipt.exactRc4PairAfter = $pairAfter
        $receipt.installedBaseApkStayedExact = $true
        $receipt.performanceAcceptanceClaim = $false
        $receipt.manualInteractionClaim = $false
        $written = Write-AtomicReceipt -FileName '04-final-30m.json' -Body $receipt
        return [pscustomobject]@{
            Result = 'PASS'
            Phase = $receipt.phase
            ReceiptPath = $written.Path
            ReceiptSha256 = $written.Sha256
            DurationSeconds = $durationSeconds
            HealthSampleCount = $sampleCount
            ExactRc4Persistence = $true
            FinalAppState = 'STOPPED'
        }
    } catch {
        Invoke-FailureRecovery -RollbackApkPath $rollbackPath -PrimaryError $_ -RollbackEligible $targetVerified
    }
}

function Invoke-ExplicitRollbackPhase {
    Assert-InstallAuthorization
    Require $AllowRollbackDowngrade.IsPresent 'Explicit rollback requires -AllowRollbackDowngrade.'
    $null = Resolve-RollbackHostContract
    $directory = Resolve-ReceiptDirectory
    $rollbackPath = Join-Path $directory 'v69-rollback.apk'
    $null = Assert-RollbackApkReady $rollbackPath
    Resolve-Device
    try {
        Stop-Stable
        $current = Read-RemoteApkIdentity
        $alreadyV69 = $current.VersionCode -eq 69 -and $current.VersionName -ceq $script:V69.VersionName -and $current.ApkSha256 -ceq $script:V69.ApkSha256
        if ($alreadyV69) {
            $probePath = Join-Path $directory ('.already-v69-' + [Guid]::NewGuid().ToString('N') + '.apk')
            try { $null = Assert-InstalledArtifact -Expected (Get-ExpectedV69) -PullPath $probePath } finally { if ([IO.File]::Exists($probePath)) { [IO.File]::Delete($probePath) } }
            $rollback = [pscustomobject]@{ Attempted = $false; AndroidAccepted = $true; ExactV69Restored = $true; AlreadyExactV69 = $true; Command = 'none'; DowngradeOverrideUsed = $false; DataDeletionAttempted = $false }
        } else {
            Require ($current.VersionCode -eq 71 -and $current.VersionName -ceq $script:StableContract.Lock.Target.VersionName -and $current.ApkSha256 -ceq $script:StableContract.Lock.Target.ApkSha256) 'Explicit rollback refuses an unknown installed package state.'
            $rollback = Invoke-ConservativeRollback -RollbackApkPath $rollbackPath
            Require $rollback.ExactV69Restored 'Android rejected the conservative v69 install -r downgrade; Stable was stopped and no data was deleted.'
        }
        Stop-Stable
        $receipt = New-ReceiptBase -Phase 'ROLLBACK_TO_V69'
        $receipt.rollback = $rollback
        $written = Write-AtomicReceipt -FileName '90-rollback-to-v69.json' -Body $receipt
        return [pscustomobject]@{ Result = 'PASS'; Phase = $receipt.phase; ReceiptPath = $written.Path; ReceiptSha256 = $written.Sha256; ExactV69Restored = $true; FinalAppState = 'STOPPED' }
    } catch {
        try { Stop-Stable } catch { }
        throw
    }
}

function New-SyntheticStableLock {
    return [pscustomobject]@{
        schemaVersion = 1
        status = 'REVIEWED_FOR_SUPERVISED_INSTALL'
        target = [pscustomobject]@{
            package = $script:Package
            versionCode = 71
            versionName = '6.0.1-26.2-vivecraft-personal.12'
            label = 'QuestCraft Vivecraft Personal 26.2'
            apkPath = 'QCXR-XR-Wrapper/Builds/QuestCraft-Vivecraft-26.2-personal.12-local.apk'
            apkSha256 = ('A' * 64)
            apkSizeBytes = 128000000L
            signerSha256 = $script:ExpectedSignerSha256
            signatureSchemeV2 = $true
            coreSha256 = $script:ExpectedCoreSha256
            coreSizeBytes = $script:ExpectedCoreSizeBytes
            coreVersion = $script:ExpectedCoreVersion
            veqSha256 = $script:ExpectedVeqSha256
            veqSizeBytes = $script:ExpectedVeqSizeBytes
            veqVersion = $script:ExpectedVeqVersion
            lwjglSha256 = $script:ExpectedLwjglSha256
        }
        baselineV69 = [pscustomobject]@{
            package = $script:Package
            versionCode = 69
            versionName = $script:V69.VersionName
            apkSha256 = $script:V69.ApkSha256
            apkSizeBytes = $script:V69.ApkSizeBytes
            signerSha256 = $script:ExpectedSignerSha256
            coreSha256 = $script:V69.CoreSha256
            coreVersion = $script:V69.CoreVersion
            veqSha256 = $script:V69.VeqSha256
            veqVersion = $script:V69.VeqVersion
        }
        acceptance = [pscustomobject]@{
            manifestPath = 'V71_STABLE_RC4_ACCEPTANCE.lock.json'
            manifestSha256 = ('B' * 64)
            requiredStatus = 'ACCEPTED_FOR_STABLE_BUILD'
        }
        review = [pscustomobject]@{
            status = 'APPROVED_FOR_SUPERVISED_INSTALL'
            reviewedBy = 'host-self-test'
            reviewedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        installPolicy = [pscustomobject]@{
            replaceOnly = $true
            noUninstall = $true
            noClearData = $true
            noAccountAccess = $true
            rollbackUsesReplaceOnly = $true
            rollbackDowngradeOverrideForbidden = $true
            finalRequiredState = 'STOPPED'
            normalStartCount = 3
            finalGateSeconds = 1800
        }
    }
}

function Invoke-HostBoundaryProbe {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('qcxr-v71-install-boundary-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        $apk = Join-Path $root 'candidate with spaces;literal.apk'
        [IO.File]::WriteAllBytes($apk,[byte[]](1,2,3))
        $probe = Join-Path $root 'argv-probe.ps1'
        [IO.File]::WriteAllText($probe,'[Console]::Out.Write((@($args) | ConvertTo-Json -Compress))',[Text.UTF8Encoding]::new($false))
        $oldSerial = $script:ResolvedSerial
        $script:ResolvedSerial = 'TEST_USB_SERIAL_01'
        try {
            $arguments = New-InstallArguments $apk
            Require ($arguments.Count -eq 5 -and $arguments[0] -ceq '-s' -and $arguments[1] -ceq 'TEST_USB_SERIAL_01' -and $arguments[2] -ceq 'install' -and $arguments[3] -ceq '-r' -and $arguments[4] -ceq (Get-CanonicalPath $apk)) 'The package replacement argv boundary drifted.'
            Require ($arguments -cnotcontains '-d' -and $arguments -cnotcontains '-t' -and $arguments -cnotcontains '--force-queryable') 'The package replacement argv gained an extra install flag.'
            $hostExecutable = [Environment]::ProcessPath
            Require (-not [string]::IsNullOrWhiteSpace($hostExecutable) -and [IO.File]::Exists($hostExecutable)) 'Could not resolve the Host PowerShell executable.'
            $capture = Invoke-ProcessCapture -FileName $hostExecutable -Arguments (@('-NoLogo','-NoProfile','-NonInteractive','-File',$probe) + $arguments)
            Require ($capture.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($capture.Stderr)) 'The Host argv boundary probe failed.'
            $roundTrip = @($capture.Stdout | ConvertFrom-Json)
            Require ($roundTrip.Count -eq $arguments.Count) 'The Host argv boundary changed argument count.'
            for ($index = 0; $index -lt $arguments.Count; $index++) {
                Require ([string]$roundTrip[$index] -ceq [string]$arguments[$index]) "The Host argv boundary changed argument $index."
            }

            $shellFixture = "value='literal'; printf '%s' `"`$value; `$(touch SHOULD_NOT_RUN)`""
            $shellArguments = New-ShellArguments $shellFixture
            Require ($shellArguments.Count -eq 7 -and $shellArguments[0] -ceq '-s' -and $shellArguments[1] -ceq 'TEST_USB_SERIAL_01' -and $shellArguments[2] -ceq 'shell' -and $shellArguments[3] -ceq '-T' -and $shellArguments[4] -ceq 'sh' -and $shellArguments[5] -ceq '-c') 'The shell_v2 argv prefix drifted.'
            Require ($shellArguments[6] -ceq (ConvertTo-ShLiteral $shellFixture)) 'The shell_v2 command was not protected as one -c argument.'
            $shellCapture = Invoke-ProcessCapture -FileName $hostExecutable -Arguments (@('-NoLogo','-NoProfile','-NonInteractive','-File',$probe) + $shellArguments)
            Require ($shellCapture.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($shellCapture.Stderr)) 'The shell_v2 Host argv probe failed.'
            $shellRoundTrip = @($shellCapture.Stdout | ConvertFrom-Json)
            Require ($shellRoundTrip.Count -eq 7 -and [string]$shellRoundTrip[6] -ceq [string]$shellArguments[6]) 'The shell_v2 Host argv boundary changed the protected command.'
        } finally {
            $script:ResolvedSerial = $oldSerial
        }
    } finally {
        if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) }
    }
}

function Invoke-BackupManifestSelfTest {
    $rootCreated = $false
    if (-not [IO.Directory]::Exists($script:BackupRoot)) {
        [IO.Directory]::CreateDirectory($script:BackupRoot) | Out-Null
        $rootCreated = $true
    }
    $directory = Join-Path $script:BackupRoot ('selftest-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory((Join-Path $directory 'mods')) | Out-Null
    try {
        $file = Join-Path $directory 'mods\example.jar'
        [IO.File]::WriteAllText($file,'protected-backup-fixture',[Text.UTF8Encoding]::new($false))
        $sha = Get-Sha256 $file
        $size = (Get-Item -LiteralPath $file).Length
        [IO.File]::WriteAllText((Join-Path $directory 'SHA256SUMS.sha256'),"$sha *mods/example.jar" + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        $manifest = [ordered]@{
            schemaVersion = 1
            createdUtc = [DateTime]::UtcNow.ToString('o')
            sourcePackage = $script:Package
            sourceVersionCode = 69
            sourceVersionName = $script:V69.VersionName
            sourceBaseApkSha256 = $script:V69.ApkSha256
            sourceSignerSha256 = $script:ExpectedSignerSha256
            sourceSignerProof = 'exact-apk-sha256-bound-to-host-audited-signer'
            sourceProfile = $script:Profile
            readMode = 'shell'
            deviceMutated = $false
            accountOrAuthenticationFilesIncluded = $false
            allowlistedRoots = @('mods','config','options.txt','saves','Xaero','XaeroWaypoints','XaeroWorldMap')
            sensitiveNamePolicy = 'fail-before-stream-and-reject-on-host'
            fileCount = 1
            totalSizeBytes = $size
            files = @([ordered]@{ path = 'mods/example.jar'; sizeBytes = $size; sha256 = $sha })
        }
        $manifestPath = Join-Path $directory 'BACKUP_MANIFEST.json'
        [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        $oldPath = $script:BackupManifestPath
        $oldHash = $script:BackupManifestSha256
        $script:BackupManifestPath = $manifestPath
        $script:BackupManifestSha256 = Get-Sha256 $manifestPath
        try {
            $proof = Assert-ProtectedBackup
            Require ($proof.FileCount -eq 1 -and $proof.TotalSizeBytes -eq $size) 'The protected backup fixture did not validate.'
            [IO.File]::AppendAllText($file,'tampered',[Text.UTF8Encoding]::new($false))
            Require (Test-ExpectedFailure { Assert-ProtectedBackup | Out-Null }) 'A mutated backed-up file passed validation.'
        } finally {
            $script:BackupManifestPath = $oldPath
            $script:BackupManifestSha256 = $oldHash
        }
    } finally {
        if ([IO.Directory]::Exists($directory)) { [IO.Directory]::Delete($directory,$true) }
        if ($rootCreated -and [IO.Directory]::Exists($script:BackupRoot) -and (Get-ChildItem -LiteralPath $script:BackupRoot -Force | Measure-Object).Count -eq 0) { [IO.Directory]::Delete($script:BackupRoot) }
    }
}

function Invoke-EvidenceGateAuthenticationSelfTest {
    $fixtureRoot = Join-Path $script:ReceiptRoot `
        ('auth-selftest-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $fixtureLockPath = Join-Path $fixtureRoot 'V71_LAB_RC4.lock.json'
    $fixtureGatePath = Join-Path $fixtureRoot 'v71-rc4-stable-evidence-gate.ps1'
    $beforeDeviceInvocations = $script:DeviceInvocationCount
    $script:InstallerAuthFixtureLockPath = $fixtureLockPath
    $script:InstallerAuthFixtureGatePath = $fixtureGatePath
    $script:InstallerAuthFixtureDotSourceCount = 0
    try {
        $gateText = @'
$script:InstallerAuthFixtureDotSourceCount++
function Assert-V71Rc4StableAcceptanceEvidence {
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
    $writeDenied = 0
    foreach ($path in @($script:InstallerAuthFixtureLockPath,
            $script:InstallerAuthFixtureGatePath)) {
        $writeStream = $null
        try {
            $writeStream = [IO.File]::Open($path, [IO.FileMode]::Open,
                [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        } catch [IO.IOException] {
            $writeDenied++
        } finally {
            if ($null -ne $writeStream) { $writeStream.Dispose() }
        }
    }
    if ($writeDenied -ne 2) {
        throw 'RC4 lock or evidence gate was writable during authenticated execution.'
    }
    [pscustomobject]@{
        Result = 'PASS'
        ManifestSha256 = ('B' * 64)
        ExactCoreSha256 = $script:ExpectedCoreSha256
        ExactVeqSha256 = $script:ExpectedVeqSha256
        ReadLocksHeld = $true
    }
}
'@
        [IO.File]::WriteAllText($fixtureGatePath, $gateText,
            [Text.UTF8Encoding]::new($false))
        $gateSha256 = Get-NormalizedUtf8TextSha256 $gateText
        $lockObject = [ordered]@{
            schemaVersion = 1
            source = [ordered]@{
                scriptHashScheme = 'sha256-utf8-normalized-lf'
                stableEvidenceGateScriptSha256 = $gateSha256
            }
        }
        $lockText = ($lockObject | ConvertTo-Json -Depth 4) + [Environment]::NewLine
        [IO.File]::WriteAllText($fixtureLockPath, $lockText,
            [Text.UTF8Encoding]::new($false))
        $contract = [pscustomobject]@{ AcceptanceManifestSha256 = ('B' * 64) }
        $arguments = @{
            ManifestPath = 'fixture-manifest'
            RepoRoot = $script:RepoRoot
            EvidenceRoot = $script:EvidenceRoot
            MemorySamplerPath = 'fixture-memory-sampler'
            MemoryRuntimeContractPath = 'fixture-memory-contract'
            PerformanceHarnessPath = 'fixture-performance-harness'
            LifecycleHarnessPath = 'fixture-lifecycle-harness'
        }

        $valid = Invoke-AuthenticatedRc4EvidenceGate -Contract $contract `
            -GateArguments $arguments -Rc4LockPath $fixtureLockPath `
            -EvidenceGatePath $fixtureGatePath
        Require ([bool]$valid.ReadLocksHeld -and
            $script:InstallerAuthFixtureDotSourceCount -eq 1) `
            'The authenticated gate fixture did not execute under both read locks.'

        # A single appended ASCII byte must invalidate the gate before its
        # top-level dot-source side effect can execute, and before any ADB path.
        [IO.File]::AppendAllText($fixtureGatePath, ' ',
            [Text.UTF8Encoding]::new($false))
        $dotSourceCountBeforeMutation = $script:InstallerAuthFixtureDotSourceCount
        Require (Test-ExpectedFailure {
                Invoke-AuthenticatedRc4EvidenceGate -Contract $contract `
                    -GateArguments $arguments -Rc4LockPath $fixtureLockPath `
                    -EvidenceGatePath $fixtureGatePath | Out-Null
            }) 'A one-byte mutation of the evidence gate passed authentication.'
        Require ($script:InstallerAuthFixtureDotSourceCount -eq
            $dotSourceCountBeforeMutation) `
            'The one-byte-mutated evidence gate was dot-sourced before rejection.'
        Require ($script:DeviceInvocationCount -eq $beforeDeviceInvocations) `
            'Evidence-gate mutation testing resolved or invoked ADB.'

        # Restore the gate, then mutate one byte of the declared scheme. This
        # independently proves schema/scheme validation precedes dot-source.
        [IO.File]::WriteAllText($fixtureGatePath, $gateText,
            [Text.UTF8Encoding]::new($false))
        $mutatedLockText = $lockText.Replace(
            'sha256-utf8-normalized-lf', 'sha256-utf8-normalized-lF')
        Require ($mutatedLockText.Length -eq $lockText.Length) `
            'The RC4 lock one-byte mutation fixture changed byte length.'
        [IO.File]::WriteAllText($fixtureLockPath, $mutatedLockText,
            [Text.UTF8Encoding]::new($false))
        Require (Test-ExpectedFailure {
                Invoke-AuthenticatedRc4EvidenceGate -Contract $contract `
                    -GateArguments $arguments -Rc4LockPath $fixtureLockPath `
                    -EvidenceGatePath $fixtureGatePath | Out-Null
            }) 'A one-byte mutation of the RC4 hash scheme passed authentication.'
        Require ($script:InstallerAuthFixtureDotSourceCount -eq
            $dotSourceCountBeforeMutation) `
            'The invalid RC4 hash scheme reached dot-source.'
        Require ($script:DeviceInvocationCount -eq $beforeDeviceInvocations) `
            'RC4 lock mutation testing resolved or invoked ADB.'

        return [pscustomobject]@{
            GateOneByteMutationRejected = $true
            LockOneByteMutationRejected = $true
            HashCheckedBeforeDotSource = $true
            ReadLocksHeldDuringExecution = $true
            FailedBeforeAdb = $true
        }
    } finally {
        Remove-Variable -Scope Script -Name InstallerAuthFixtureLockPath `
            -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name InstallerAuthFixtureGatePath `
            -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name InstallerAuthFixtureDotSourceCount `
            -ErrorAction SilentlyContinue
        if ([IO.Directory]::Exists($fixtureRoot)) {
            [IO.Directory]::Delete($fixtureRoot, $true)
        }
    }
}

function Invoke-SelfTest {
    $before = $script:DeviceInvocationCount
    $source = [IO.File]::ReadAllText($PSCommandPath)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors)
    Require ($parseErrors.Count -eq 0) 'PowerShell parser errors were found.'
    $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    foreach ($forbiddenOverride in @('Package','Profile','Component','CandidateApkPath','RollbackApkPath','AcceptanceManifestPath')) {
        Require ($parameterNames -cnotcontains $forbiddenOverride) "The fixed identity exposes a forbidden override: $forbiddenOverride"
    }
    Require ($source.Contains("`$script:Package = '$script:Package'") -and $source.Contains("`$script:Component = '$script:Component'")) 'The fixed Stable package/component pins are absent.'
    $authCheckIndex = $source.IndexOf(
        'INSTALLER_AUTH_LOCK_AND_HASH_CHECK_BEFORE_DOT_SOURCE',
        [StringComparison]::Ordinal)
    $authDotSourceIndex = $source.IndexOf(
        'INSTALLER_AUTH_DOT_SOURCE_ONLY_AFTER_LOCKED_HASH_CHECK',
        [StringComparison]::Ordinal)
    Require ($authCheckIndex -ge 0 -and $authDotSourceIndex -gt $authCheckIndex) `
        'The RC4 lock/hash check is not ordered before evidence-gate dot-source.'
    $installBoundaryPattern = "'install'," + "'-r'"
    Require ([regex]::Matches($source,[regex]::Escape($installBoundaryPattern)).Count -eq 1) 'Package replacement must have one exact argv construction site.'
    foreach ($pattern in @(
        ("'install'," + "'-d'"),
        ("'install'," + "'-r','-d'"),
        ("'pm'," + "'clear'"),
        ("'pm'," + "'uninstall'"),
        ("'shell'," + "'rm'"),
        ("'shell'," + "'input'"),
        ("'shell'," + "'monkey'"),
        ("'shell'," + "'run-as'")
    )) {
        Require (-not $source.Contains($pattern)) "A forbidden device argv construction is present: $pattern"
    }
    Require ($source.Contains('Android rejected or failed the conservative v69 install -r rollback; stopped without deletion')) 'Rollback rejection is not an explicit terminal state.'
    Require ($source.Contains("'01-install-and-immediate-verify.json'") -and $source.Contains("'02-post-install-verify.json'") -and $source.Contains("'03-three-normal-starts.json'") -and $source.Contains("'04-final-30m.json'")) 'The four explicit receipt phases are incomplete.'

    Require (Test-ExpectedFailure { $null = Assert-Rc4CandidateEvidenceReady }) `
        'The checked-in PENDING_NOT_BUILT RC4 candidate did not fail closed.'
    Require ($script:DeviceInvocationCount -eq $before) `
        'The PENDING_NOT_BUILT preflight resolved or invoked ADB.'

    $authenticationProof = Invoke-EvidenceGateAuthenticationSelfTest
    Require ([bool]$authenticationProof.GateOneByteMutationRejected -and
        [bool]$authenticationProof.LockOneByteMutationRejected -and
        [bool]$authenticationProof.HashCheckedBeforeDotSource -and
        [bool]$authenticationProof.ReadLocksHeldDuringExecution -and
        [bool]$authenticationProof.FailedBeforeAdb) `
        'The authenticated evidence-gate boundary did not pass all Host faults.'

    $validLock = New-SyntheticStableLock
    $parsed = Assert-StableLockContract $validLock
    Require ($parsed.Target.ApkSha256 -ceq ('A' * 64) -and $parsed.AcceptanceManifestSha256 -ceq ('B' * 64)) 'The reviewed Stable lock fixture did not validate.'
    foreach ($mutation in @(
        { $copy = New-SyntheticStableLock; $copy.status = 'TEMPLATE_NOT_AUTHORIZED'; Assert-StableLockContract $copy | Out-Null },
        { $copy = New-SyntheticStableLock; $copy.target.package = 'com.qcxr.qcxr.canary262'; Assert-StableLockContract $copy | Out-Null },
        { $copy = New-SyntheticStableLock; $copy.target.apkSha256 = $null; Assert-StableLockContract $copy | Out-Null },
        { $copy = New-SyntheticStableLock; $copy.target.signerSha256 = ('C' * 64); Assert-StableLockContract $copy | Out-Null },
        { $copy = New-SyntheticStableLock; $copy.baselineV69.versionCode = 68; Assert-StableLockContract $copy | Out-Null },
        { $copy = New-SyntheticStableLock; $copy.acceptance.manifestSha256 = ('0' * 64); Assert-StableLockContract $copy | Out-Null },
        { $copy = New-SyntheticStableLock; $copy.installPolicy.rollbackDowngradeOverrideForbidden = $false; Assert-StableLockContract $copy | Out-Null }
    )) {
        Require (Test-ExpectedFailure $mutation) 'A mutated Stable lock fixture passed fail-closed validation.'
    }

    $baseFixture = '/data/app/~~abc/com.qcxr.qcxr.dev262-def/base.apk'
    Require ((Read-ExactBaseApkPath "package:$baseFixture") -ceq $baseFixture) 'The exact base.apk parser rejected a valid fixture.'
    Require (Test-ExpectedFailure { Read-ExactBaseApkPath "package:$baseFixture`npackage:/data/app/split.apk" | Out-Null }) 'The exact base.apk parser accepted a split/ambiguous fixture.'
    foreach ($badPath in @('../mods/a.jar','config/auth.json','logs/latest.log','saves/world/token.dat')) {
        Require (-not (Test-SafeBackupRelativePath $badPath)) "An unsafe backup path passed: $badPath"
    }
    Invoke-BackupManifestSelfTest
    Invoke-HostBoundaryProbe

    Assert-InstallResult ([pscustomobject]@{ ExitCode = 0; Stdout = "Performing Streamed Install`nSuccess`n"; Stderr = '' }) 'self-test install'
    foreach ($badResult in @(
        [pscustomobject]@{ ExitCode = 1; Stdout = 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]'; Stderr = '' },
        [pscustomobject]@{ ExitCode = 0; Stdout = 'Success'; Stderr = 'warning' },
        [pscustomobject]@{ ExitCode = 0; Stdout = "Success`nSuccess"; Stderr = '' },
        [pscustomobject]@{ ExitCode = 0; Stdout = 'Failure'; Stderr = '' }
    )) {
        Require (Test-ExpectedFailure { Assert-InstallResult $badResult 'fault-injected install' }) 'A failed, noisy, or ambiguous install result passed.'
    }

    $plan = Get-Plan
    Require ($plan.HostOnly -and $plan.DeviceInvocations -eq 0 -and $plan.InstallCommand -ceq 'adb install -r only') 'The Host-only Plan contract drifted.'
    Require ($script:DeviceInvocationCount -eq $before) 'SelfTest unexpectedly invoked ADB.'
    return [pscustomobject]@{
        Result = 'PASS'
        HostOnly = $true
        DeviceTouched = $false
        DeviceInvocations = 0
        Package = $script:Package
        LockMutationFaultsRejected = 7
        InstallResultFaultsRejected = 4
        ExactInstallArgvBoundary = $true
        ArgumentInjectionFixtureStayedLiteral = $true
        ProtectedBackupHashFaultRejected = $true
        SplitBaseApkRejected = $true
        AcceptanceExecutionAttempted = $false
        PendingRc4RejectedBeforeAdb = $true
        Rc4LockSchemaAndHashSchemePinned = $true
        EvidenceGateOneByteMutationRejected = $true
        EvidenceGateAuthenticatedBeforeDotSource = $true
        EvidenceGateReadLocksHeldDuringExecution = $true
        InstallOrLaunchAttempted = $false
        FinalState = 'Host-only; no device selected'
    }
}

switch ($Action) {
    'SelfTest' { Invoke-SelfTest }
    'Plan' {
        $before = $script:DeviceInvocationCount
        $plan = Get-Plan
        Require ($script:DeviceInvocationCount -eq $before) 'Plan unexpectedly invoked ADB.'
        $plan
    }
    'Install' { Invoke-InstallPhase }
    'VerifyInstalled' { Invoke-VerifyInstalledPhase }
    'ThreeNormalStarts' { Invoke-ThreeNormalStartsPhase }
    'Final30MinuteGate' { Invoke-FinalThirtyMinutePhase }
    'RollbackToV69' { Invoke-ExplicitRollbackPhase }
}
