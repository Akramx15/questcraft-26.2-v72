<#
.SYNOPSIS
Builds a Host-only, install-r-compatible rollback APK from the exact v66 APK.

.DESCRIPTION
The rollback keeps every v66 ZIP payload entry byte-for-byte identical except
for the three entries that carry application version metadata. It changes
versionCode 66 to 67 and the equal-length versionName suffix personal.7 to
personal.8, then signs with the existing one-signer v2-only lineage and checks
16 KiB page alignment.

The requested "personal.8-rollback" label is nine characters longer than the
binary v66 label. This conservative byte-preserving builder does not resize
compiled string pools, so the Android/Unity versionName remains the equal-length
personal.8. The output filename and emitted RollbackPayload field identify this
as the exact v66 rollback payload. This script never invokes ADB.
#>
[CmdletBinding()]
param(
    [string] $BaseApk,
    [string] $OutputApk,
    [string] $Keystore = (Join-Path $env:USERPROFILE ".android\debug.keystore"),
    [string] $KeyAlias = "androiddebugkey",
    [string] $PasswordEnvironmentVariable = "QCXR_DEBUG_KEYSTORE_PASS"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$expectedPackage = "com.qcxr.qcxr.dev262"
$expectedBaseVersionCode = 66
$expectedBaseVersionName = "6.0.1-26.2-vivecraft-personal.7"
$targetVersionCode = 67
$targetVersionName = "6.0.1-26.2-vivecraft-personal.8"
$expectedBaseSha256 = "708962B958B8373B46231F8DA6C7B2AC284593BB30B291B46C68931FD1A3A70D"
$expectedSignerSha256 = "B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A"
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "artifacts\v67-rollback"))

if ([string]::IsNullOrWhiteSpace($BaseApk)) {
    $BaseApk = Join-Path $repoRoot "backups\v67-rc1-preinstall-20260902-1300\installed-v66.apk"
}
if ([string]::IsNullOrWhiteSpace($OutputApk)) {
    $OutputApk = Join-Path $artifactRoot `
        "QuestCraft-Vivecraft-26.2-v66-payload-vc67-personal.8-rollback.apk"
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Parent,
        [Parameter(Mandatory)][string] $Description
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $prefix = $fullParent + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must remain inside $fullParent"
    }
    return $fullPath
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = & $Executable @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Executable $($Arguments -join ' ')`n$output"
    }
    return $output
}

function ConvertTo-HexString {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    return (($Bytes | ForEach-Object { $_.ToString("X2") }) -join "")
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][IO.Stream] $Stream)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ConvertTo-HexString ($sha256.ComputeHash($Stream))
    } finally {
        $sha256.Dispose()
    }
}

function Get-ZipInventory {
    param([Parameter(Mandatory)][string] $Path)

    $entries = [Collections.Generic.Dictionary[string, object]]::new(
        [StringComparer]::Ordinal)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entries.ContainsKey($entry.FullName)) {
                throw "Duplicate ZIP entry in ${Path}: $($entry.FullName)"
            }
            $stream = $entry.Open()
            try {
                $hash = Get-StreamSha256 $stream
            } finally {
                $stream.Dispose()
            }
            $entries.Add($entry.FullName, [pscustomobject]@{
                Length = [long] $entry.Length
                Sha256 = $hash
            })
        }
    } finally {
        $archive.Dispose()
    }
    return [pscustomobject]@{ Count = $entries.Count; Entries = $entries }
}

function Get-ZipEntryBytes {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $EntryName)

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $memory = $null
    try {
        $matches = @($archive.Entries | Where-Object FullName -CEQ $EntryName)
        if ($matches.Count -ne 1) {
            throw "Expected one ZIP entry '$EntryName' in ${Path}; found $($matches.Count)."
        }
        $memory = [IO.MemoryStream]::new()
        $stream = $matches[0].Open()
        try {
            $stream.CopyTo($memory)
        } finally {
            $stream.Dispose()
        }
        return (, $memory.ToArray())
    } finally {
        if ($null -ne $memory) { $memory.Dispose() }
        $archive.Dispose()
    }
}

function Get-OpenZipEntryBytes {
    param(
        [Parameter(Mandatory)][IO.Compression.ZipArchive] $Archive,
        [Parameter(Mandatory)][string] $EntryName
    )

    $matches = @($Archive.Entries | Where-Object FullName -CEQ $EntryName)
    if ($matches.Count -ne 1) {
        throw "Expected one open ZIP entry '$EntryName'; found $($matches.Count)."
    }
    $memory = [IO.MemoryStream]::new()
    $stream = $matches[0].Open()
    try {
        $stream.CopyTo($memory)
    } finally {
        $stream.Dispose()
    }
    try {
        return (, $memory.ToArray())
    } finally {
        $memory.Dispose()
    }
}

function Set-OpenZipEntryBytes {
    param(
        [Parameter(Mandatory)][IO.Compression.ZipArchive] $Archive,
        [Parameter(Mandatory)][string] $EntryName,
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][IO.Compression.CompressionLevel] $CompressionLevel
    )

    $matches = @($Archive.Entries | Where-Object FullName -CEQ $EntryName)
    if ($matches.Count -ne 1) {
        throw "Expected one open ZIP entry '$EntryName'; found $($matches.Count)."
    }
    $matches[0].Delete()
    $replacement = $Archive.CreateEntry($EntryName, $CompressionLevel)
    $stream = $replacement.Open()
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
    } finally {
        $stream.Dispose()
    }
}

function Assert-ZipPayloadParity {
    param(
        [Parameter(Mandatory)] $BaseInventory,
        [Parameter(Mandatory)] $CandidateInventory,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]] $MetadataEntries
    )

    if ($BaseInventory.Count -ne $CandidateInventory.Count) {
        throw "ZIP entry count changed ($($BaseInventory.Count) -> $($CandidateInventory.Count))."
    }
    foreach ($name in $BaseInventory.Entries.Keys) {
        if (-not $CandidateInventory.Entries.ContainsKey($name)) {
            throw "Rollback APK lost ZIP entry: $name"
        }
        $before = $BaseInventory.Entries[$name]
        $after = $CandidateInventory.Entries[$name]
        if ($before.Length -ne $after.Length) {
            throw "ZIP entry length changed: $name"
        }
        if ($MetadataEntries.Contains($name)) {
            if ($before.Sha256 -ceq $after.Sha256) {
                throw "Expected version metadata entry to change: $name"
            }
        } elseif ($before.Sha256 -cne $after.Sha256) {
            throw "v66 payload entry changed unexpectedly: $name"
        }
    }
}

function Assert-ApkSigningProfile {
    param(
        [Parameter(Mandatory)][string] $SigningText,
        [Parameter(Mandatory)][string] $ExpectedSigner
    )

    $expectedSchemes = @{
        "v1 scheme \(JAR signing\)" = "false"
        "v2 scheme \(APK Signature Scheme v2\)" = "true"
        "v3 scheme \(APK Signature Scheme v3\)" = "false"
        "v3\.1 scheme \(APK Signature Scheme v3\.1\)" = "false"
        "v4 scheme \(APK Signature Scheme v4\)" = "false"
    }
    foreach ($scheme in $expectedSchemes.Keys) {
        if ($SigningText -notmatch "Verified using $scheme`: $($expectedSchemes[$scheme])") {
            throw "Unexpected APK signing scheme profile: $scheme"
        }
    }
    if ($SigningText -notmatch "Number of signers:\s+1(?:\r?\n|$)") {
        throw "APK must have exactly one signer."
    }
    $matches = [regex]::Matches($SigningText,
        "Signer #\d+ certificate SHA-256 digest: (?<value>[0-9a-fA-F]+)")
    if ($matches.Count -ne 1) {
        throw "Expected one signer certificate digest; found $($matches.Count)."
    }
    $signer = $matches[0].Groups["value"].Value.ToUpperInvariant()
    if ($signer -cne $ExpectedSigner.ToUpperInvariant()) {
        throw "APK signer differs from the v66/v67 signing lineage."
    }
    return $signer
}

function Assert-KeystoreSigner {
    param(
        [Parameter(Mandatory)][string] $Keytool,
        [Parameter(Mandatory)][string] $KeystorePath,
        [Parameter(Mandatory)][string] $Alias,
        [Parameter(Mandatory)][string] $PasswordVariable,
        [Parameter(Mandatory)][string] $ExpectedSigner
    )

    $details = Invoke-Checked $Keytool @(
        "-list", "-v", "-keystore", $KeystorePath,
        "-storepass:env", $PasswordVariable, "-alias", $Alias)
    $match = [regex]::Match($details,
        "SHA256:\s*(?<value>(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})")
    if (-not $match.Success) {
        throw "keytool returned no SHA-256 certificate fingerprint."
    }
    $signer = $match.Groups["value"].Value.Replace(":", "").ToUpperInvariant()
    if ($signer -cne $ExpectedSigner.ToUpperInvariant()) {
        throw "The selected keystore does not contain the v66/v67 signing certificate."
    }
}

function Get-BadgingValue {
    param([Parameter(Mandatory)][string] $Badging, [Parameter(Mandatory)][string] $Name)

    $package = [regex]::Match($Badging,
        "package: name='(?<package>[^']+)' versionCode='(?<code>[^']+)' versionName='(?<name>[^']+)'")
    if (-not $package.Success) {
        throw "aapt2 returned no parseable package line."
    }
    switch ($Name) {
        "package" { return $package.Groups["package"].Value }
        "code" { return $package.Groups["code"].Value }
        "name" { return $package.Groups["name"].Value }
        default { throw "Unknown badging field: $Name" }
    }
}

function Find-ByteSequence {
    param([Parameter(Mandatory)][byte[]] $Bytes, [Parameter(Mandatory)][byte[]] $Needle)

    $matches = [Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le $Bytes.Length - $Needle.Length; $i++) {
        $same = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Needle[$j]) {
                $same = $false
                break
            }
        }
        if ($same) { $matches.Add($i) }
    }
    return $matches.ToArray()
}

function Patch-UniqueEqualLengthBytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][byte[]] $OldValue,
        [Parameter(Mandatory)][byte[]] $NewValue,
        [Parameter(Mandatory)][string] $Description
    )

    if ($OldValue.Length -ne $NewValue.Length) {
        throw "$Description replacement must have the same byte length."
    }
    $matches = @(Find-ByteSequence $Bytes $OldValue)
    if ($matches.Count -ne 1) {
        throw "Expected one $Description value, found $($matches.Count)."
    }
    $NewValue.CopyTo($Bytes, $matches[0])
}

if (-not ("Qcxr.Rollback.DexChecksums" -as [type])) {
    Add-Type -TypeDefinition @"
namespace Qcxr.Rollback {
    public static class DexChecksums {
        public static uint Adler32(byte[] bytes, int offset, int count) {
            const uint Modulus = 65521;
            uint a = 1;
            uint b = 0;
            int end = offset + count;
            while (offset < end) {
                int blockEnd = System.Math.Min(offset + 5552, end);
                while (offset < blockEnd) {
                    a += bytes[offset++];
                    b += a;
                }
                a %= Modulus;
                b %= Modulus;
            }
            return (b << 16) | a;
        }
    }
}
"@
}

function Update-DexHeader {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    if ($Bytes.Length -lt 112 -or [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -cne "dex`n" -or
        $Bytes[7] -ne 0) {
        throw "classes.dex has an invalid DEX header."
    }
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $signature = $sha1.ComputeHash($Bytes, 32, $Bytes.Length - 32)
    } finally {
        $sha1.Dispose()
    }
    $signature.CopyTo($Bytes, 12)
    $checksum = [Qcxr.Rollback.DexChecksums]::Adler32($Bytes, 12, $Bytes.Length - 12)
    [BitConverter]::GetBytes([uint32] $checksum).CopyTo($Bytes, 8)
}

function Assert-DexHeader {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $storedChecksum = [BitConverter]::ToUInt32($Bytes, 8)
    $expectedChecksum = [Qcxr.Rollback.DexChecksums]::Adler32($Bytes, 12, $Bytes.Length - 12)
    if ($storedChecksum -ne $expectedChecksum) {
        throw "classes.dex Adler-32 checksum is invalid."
    }
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $expectedSignature = $sha1.ComputeHash($Bytes, 32, $Bytes.Length - 32)
    } finally {
        $sha1.Dispose()
    }
    for ($i = 0; $i -lt $expectedSignature.Length; $i++) {
        if ($Bytes[12 + $i] -ne $expectedSignature[$i]) {
            throw "classes.dex SHA-1 signature is invalid."
        }
    }
}

function Patch-DexVersionName {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $OldName,
        [Parameter(Mandatory)][string] $NewName
    )

    Patch-UniqueEqualLengthBytes $Bytes ([Text.Encoding]::UTF8.GetBytes($OldName)) `
        ([Text.Encoding]::UTF8.GetBytes($NewName)) "classes.dex versionName"
    Update-DexHeader $Bytes
    Assert-DexHeader $Bytes
    return (, $Bytes)
}

function Patch-UnityVersionName {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][string] $OldName,
        [Parameter(Mandatory)][string] $NewName
    )

    Patch-UniqueEqualLengthBytes $Bytes ([Text.Encoding]::UTF8.GetBytes($OldName)) `
        ([Text.Encoding]::UTF8.GetBytes($NewName)) "Unity Application.version"
    return (, $Bytes)
}

function Patch-BinaryManifest {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][int] $OldCode,
        [Parameter(Mandatory)][int] $NewCode,
        [Parameter(Mandatory)][string] $OldName,
        [Parameter(Mandatory)][string] $NewName
    )

    if ($OldName.Length -ne $NewName.Length) {
        throw "Binary manifest version names must have the same UTF-16 length."
    }
    if ([BitConverter]::ToUInt16($Bytes, 0) -ne 0x0003) {
        throw "AndroidManifest.xml is not Android binary XML."
    }

    $versionCodeNameIndex = $null
    $offset = 8
    while ($offset -lt $Bytes.Length) {
        $type = [BitConverter]::ToUInt16($Bytes, $offset)
        $headerSize = [BitConverter]::ToUInt16($Bytes, $offset + 2)
        $size = [BitConverter]::ToUInt32($Bytes, $offset + 4)
        if ($size -lt $headerSize -or $size -eq 0 -or $offset + $size -gt $Bytes.Length) {
            throw "Malformed Android binary XML chunk at offset $offset."
        }
        if ($type -eq 0x0180) {
            $resourceCount = [int](($size - $headerSize) / 4)
            for ($i = 0; $i -lt $resourceCount; $i++) {
                if ([BitConverter]::ToUInt32($Bytes, $offset + $headerSize + 4 * $i) -eq 0x0101021B) {
                    $versionCodeNameIndex = $i
                    break
                }
            }
        }
        $offset += $size
    }
    if ($null -eq $versionCodeNameIndex) {
        throw "android:versionCode resource id was not found."
    }

    $patchedCodes = 0
    $offset = 8
    while ($offset -lt $Bytes.Length) {
        $type = [BitConverter]::ToUInt16($Bytes, $offset)
        $nodeHeaderSize = [BitConverter]::ToUInt16($Bytes, $offset + 2)
        $size = [BitConverter]::ToUInt32($Bytes, $offset + 4)
        if ($type -eq 0x0102) {
            $extension = $offset + $nodeHeaderSize
            $attributeStart = [BitConverter]::ToUInt16($Bytes, $extension + 8)
            $attributeSize = [BitConverter]::ToUInt16($Bytes, $extension + 10)
            $attributeCount = [BitConverter]::ToUInt16($Bytes, $extension + 12)
            if ($attributeSize -lt 20) {
                throw "Malformed binary XML attribute size."
            }
            for ($i = 0; $i -lt $attributeCount; $i++) {
                $attribute = $extension + $attributeStart + $i * $attributeSize
                $nameIndex = [BitConverter]::ToUInt32($Bytes, $attribute + 4)
                if ($nameIndex -eq $versionCodeNameIndex) {
                    $dataType = $Bytes[$attribute + 15]
                    $oldValue = [BitConverter]::ToUInt32($Bytes, $attribute + 16)
                    if ($dataType -ne 0x10 -or $oldValue -ne $OldCode) {
                        throw "Unexpected android:versionCode encoding ($dataType/$oldValue)."
                    }
                    [BitConverter]::GetBytes([uint32] $NewCode).CopyTo($Bytes, $attribute + 16)
                    $patchedCodes++
                }
            }
        }
        $offset += $size
    }
    if ($patchedCodes -ne 1) {
        throw "Expected one android:versionCode attribute, patched $patchedCodes."
    }

    Patch-UniqueEqualLengthBytes $Bytes ([Text.Encoding]::Unicode.GetBytes($OldName)) `
        ([Text.Encoding]::Unicode.GetBytes($NewName)) "AndroidManifest.xml versionName"
    return (, $Bytes)
}

$resolvedBase = (Resolve-Path -LiteralPath $BaseApk).Path
$resolvedKeystore = (Resolve-Path -LiteralPath $Keystore).Path
$outputFullPath = Assert-PathInside $OutputApk $artifactRoot "Rollback output"
if ($resolvedBase -eq $outputFullPath) {
    throw "The exact v66 base APK must never be modified in place."
}
if ([IO.Path]::GetExtension($outputFullPath) -cne ".apk") {
    throw "Rollback output must have an .apk extension."
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Refusing to overwrite an existing rollback APK: $outputFullPath"
}
if ([string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable($PasswordEnvironmentVariable))) {
    throw "Keystore password environment variable is not set: $PasswordEnvironmentVariable"
}
if ($expectedBaseVersionName.Length -ne $targetVersionName.Length) {
    throw "The fallback rollback versionName is not equal-length."
}

$sdkRoot = @(
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    (Join-Path $env:LOCALAPPDATA "Android\Sdk")
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Select-Object -First 1
if (-not $sdkRoot) {
    throw "Android SDK was not found."
}
$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot "build-tools") -Directory |
    Sort-Object { [version] $_.Name } -Descending | Select-Object -First 1
if ($null -eq $buildTools) {
    throw "Android SDK build-tools were not found."
}
$aapt2 = Join-Path $buildTools.FullName "aapt2.exe"
$zipalign = Join-Path $buildTools.FullName "zipalign.exe"
$apksigner = Join-Path $buildTools.FullName "apksigner.bat"
$dexdump = Join-Path $buildTools.FullName "dexdump.exe"
foreach ($tool in @($aapt2, $zipalign, $apksigner, $dexdump)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required Android build tool is missing: $tool"
    }
}
$keytool = (Get-Command keytool -ErrorAction Stop).Source
$sevenZip = (Get-Command 7z -ErrorAction Stop).Source
$git = (Get-Command git -ErrorAction Stop).Source

$artifactRelative = $outputFullPath.Substring($repoRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
& $git -C $repoRoot check-ignore --quiet -- $artifactRelative
if ($LASTEXITCODE -ne 0) {
    throw "Rollback APK is not ignored by Git: $artifactRelative"
}
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
$artifactRootItem = Get-Item -LiteralPath $artifactRoot -Force
if (($artifactRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Rollback artifact directory must not be a reparse point: $artifactRoot"
}
$signedStage = Assert-PathInside `
    (Join-Path $artifactRoot (".rollback-signed-" + [guid]::NewGuid().ToString("N") + ".apk")) `
    $artifactRoot "Signed staging APK"
$publishedByThisRun = $false

$baseSha256 = (Get-FileHash -LiteralPath $resolvedBase -Algorithm SHA256).Hash
if ($baseSha256 -cne $expectedBaseSha256) {
    throw "Base APK is not the exact verified v66 artifact."
}
$baseBadging = Invoke-Checked $aapt2 @("dump", "badging", $resolvedBase)
if ((Get-BadgingValue $baseBadging "package") -cne $expectedPackage -or
    [int](Get-BadgingValue $baseBadging "code") -ne $expectedBaseVersionCode -or
    (Get-BadgingValue $baseBadging "name") -cne $expectedBaseVersionName) {
    throw "Base APK identity does not match exact v66."
}
$baseSigning = Invoke-Checked $apksigner @("verify", "--verbose", "--print-certs", $resolvedBase)
$null = Assert-ApkSigningProfile $baseSigning $expectedSignerSha256
Assert-KeystoreSigner $keytool $resolvedKeystore $KeyAlias `
    $PasswordEnvironmentVariable $expectedSignerSha256
Invoke-Checked $sevenZip @("t", "-bso0", "-bsp0", "-bse1", $resolvedBase) | Out-Null
$baseInventory = Get-ZipInventory $resolvedBase

$metadataEntries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in @(
    "AndroidManifest.xml",
    "classes.dex",
    "assets/bin/Data/globalgamemanagers"
)) {
    [void] $metadataEntries.Add($name)
    if (-not $baseInventory.Entries.ContainsKey($name)) {
        throw "Exact v66 APK is missing version metadata entry: $name"
    }
}

$tempParent = [IO.Path]::GetFullPath($env:TEMP)
$tempRoot = Assert-PathInside `
    (Join-Path $tempParent ("qcxr-v66-payload-rollback-" + [guid]::NewGuid().ToString("N"))) `
    $tempParent "Temporary directory"
$patchedApk = Join-Path $tempRoot "rollback-unaligned.apk"
$alignedApk = Join-Path $tempRoot "rollback-aligned.apk"
$dexTestPath = Join-Path $tempRoot "classes.dex"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Copy-Item -LiteralPath $resolvedBase -Destination $patchedApk

    $archive = [IO.Compression.ZipFile]::Open($patchedApk, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $manifestBytes = Patch-BinaryManifest `
            (Get-OpenZipEntryBytes $archive "AndroidManifest.xml") `
            $expectedBaseVersionCode $targetVersionCode $expectedBaseVersionName $targetVersionName
        $dexBytes = Patch-DexVersionName `
            (Get-OpenZipEntryBytes $archive "classes.dex") `
            $expectedBaseVersionName $targetVersionName
        $unityBytes = Patch-UnityVersionName `
            (Get-OpenZipEntryBytes $archive "assets/bin/Data/globalgamemanagers") `
            $expectedBaseVersionName $targetVersionName

        Set-OpenZipEntryBytes $archive "AndroidManifest.xml" $manifestBytes `
            ([IO.Compression.CompressionLevel]::Optimal)
        Set-OpenZipEntryBytes $archive "classes.dex" $dexBytes `
            ([IO.Compression.CompressionLevel]::NoCompression)
        Set-OpenZipEntryBytes $archive "assets/bin/Data/globalgamemanagers" $unityBytes `
            ([IO.Compression.CompressionLevel]::Optimal)
    } finally {
        $archive.Dispose()
    }

    $patchedInventory = Get-ZipInventory $patchedApk
    Assert-ZipPayloadParity $baseInventory $patchedInventory $metadataEntries
    Invoke-Checked $sevenZip @("t", "-bso0", "-bsp0", "-bse1", $patchedApk) | Out-Null
    [IO.File]::WriteAllBytes($dexTestPath, (Get-ZipEntryBytes $patchedApk "classes.dex"))
    Invoke-Checked $dexdump @("-f", $dexTestPath) | Out-Null

    Invoke-Checked $zipalign @("-P", "16", "-f", "4", $patchedApk, $alignedApk) | Out-Null
    Invoke-Checked $apksigner @(
        "sign", "--v1-signing-enabled", "false", "--v2-signing-enabled", "true",
        "--v3-signing-enabled", "false", "--v4-signing-enabled", "false",
        "--ks", $resolvedKeystore, "--ks-key-alias", $KeyAlias,
        "--ks-pass", "env:$PasswordEnvironmentVariable",
        "--key-pass", "env:$PasswordEnvironmentVariable",
        "--out", $signedStage, $alignedApk
    ) | Out-Null

    $finalBadging = Invoke-Checked $aapt2 @("dump", "badging", $signedStage)
    if ((Get-BadgingValue $finalBadging "package") -cne $expectedPackage -or
        [int](Get-BadgingValue $finalBadging "code") -ne $targetVersionCode -or
        (Get-BadgingValue $finalBadging "name") -cne $targetVersionName) {
        throw "Rollback APK identity verification failed."
    }
    $manifestTree = Invoke-Checked $aapt2 @(
        "dump", "xmltree", $signedStage, "--file", "AndroidManifest.xml")
    if ($manifestTree -notmatch "versionCode\(0x0101021b\)=$targetVersionCode" -or
        $manifestTree -notmatch ('versionName\(0x0101021c\)="' +
            [regex]::Escape($targetVersionName) + '"')) {
        throw "Binary AndroidManifest.xml did not round-trip with rollback metadata."
    }

    $finalSigning = Invoke-Checked $apksigner @(
        "verify", "--verbose", "--print-certs", $signedStage)
    $finalSigner = Assert-ApkSigningProfile $finalSigning $expectedSignerSha256
    Invoke-Checked $zipalign @("-c", "-P", "16", "-v", "4", $signedStage) | Out-Null
    Invoke-Checked $sevenZip @("t", "-bso0", "-bsp0", "-bse1", $signedStage) | Out-Null

    $finalInventory = Get-ZipInventory $signedStage
    Assert-ZipPayloadParity $baseInventory $finalInventory $metadataEntries
    foreach ($name in $metadataEntries) {
        if ($finalInventory.Entries[$name].Sha256 -cne $patchedInventory.Entries[$name].Sha256) {
            throw "Version metadata changed after alignment/signing: $name"
        }
    }

    $finalDex = Get-ZipEntryBytes $signedStage "classes.dex"
    Assert-DexHeader $finalDex
    $versionProbes = @(
        [pscustomobject]@{
            Bytes = $finalDex
            Encoding = [Text.Encoding]::UTF8
            Name = "classes.dex"
        },
        [pscustomobject]@{
            Bytes = Get-ZipEntryBytes $signedStage "assets/bin/Data/globalgamemanagers"
            Encoding = [Text.Encoding]::UTF8
            Name = "globalgamemanagers"
        },
        [pscustomobject]@{
            Bytes = Get-ZipEntryBytes $signedStage "AndroidManifest.xml"
            Encoding = [Text.Encoding]::Unicode
            Name = "AndroidManifest.xml"
        }
    )
    foreach ($probe in $versionProbes) {
        $oldMatches = @(Find-ByteSequence $probe.Bytes `
            $probe.Encoding.GetBytes($expectedBaseVersionName))
        $newMatches = @(Find-ByteSequence $probe.Bytes `
            $probe.Encoding.GetBytes($targetVersionName))
        if ($oldMatches.Count -ne 0 -or $newMatches.Count -ne 1) {
            throw "Embedded rollback versionName consistency failed for $($probe.Name)."
        }
    }

    if ((Get-FileHash -LiteralPath $resolvedBase -Algorithm SHA256).Hash -cne $baseSha256) {
        throw "Exact v66 base APK changed during rollback assembly."
    }

    $stagedSha256 = (Get-FileHash -LiteralPath $signedStage -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $outputFullPath) {
        throw "Rollback output appeared during assembly; refusing to overwrite it: $outputFullPath"
    }
    [IO.File]::Move($signedStage, $outputFullPath)
    $publishedByThisRun = $true
    if ((Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash -cne $stagedSha256) {
        throw "Atomic rollback publication changed the verified APK."
    }

    [pscustomobject]@{
        Result = "PASS"
        Output = $outputFullPath
        Sha256 = $stagedSha256
        Package = $expectedPackage
        VersionCode = $targetVersionCode
        VersionName = $targetVersionName
        RollbackPayload = "exact-v66-except-version-metadata-and-v2-signature"
        BaseApkSha256 = $baseSha256
        SignerSha256 = $finalSigner
        SignatureSchemeV2Only = $true
        ZipAligned16KiB = $true
        EntryCount = $finalInventory.Count
        VersionMetadataEntries = @($metadataEntries | Sort-Object)
        UnchangedPayloadEntryCount = $finalInventory.Count - $metadataEntries.Count
        GitIgnoredArtifact = $true
        DeviceTouched = $false
    }
} catch {
    if ($publishedByThisRun -and (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
        Remove-Item -LiteralPath $outputFullPath -Force
    }
    throw
} finally {
    if (Test-Path -LiteralPath $signedStage -PathType Leaf) {
        Remove-Item -LiteralPath $signedStage -Force
    }
    if ((Test-Path -LiteralPath $tempRoot -PathType Container) -and
        $tempRoot.StartsWith($tempParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
