[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BaseApk,

    [string] $OutputApk,
    [int] $ExpectedBaseVersionCode = 66,
    [string] $ExpectedBaseVersionName = "6.0.1-26.2-vivecraft-personal.7",
    [int] $VersionCode = 67,
    [string] $VersionName = "6.0.1-26.2-vivecraft-personal.8",
    [string] $Keystore = (Join-Path $env:USERPROFILE ".android\debug.keystore"),
    [string] $KeyAlias = "androiddebugkey",
    [string] $PasswordEnvironmentVariable = "QCXR_DEBUG_KEYSTORE_PASS"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -Raw -LiteralPath (Join-Path $root "STACK.lock.json") | ConvertFrom-Json
if (-not $OutputApk) {
    $OutputApk = Join-Path $root ([string] $lock.identity.output)
}

$resolvedBase = (Resolve-Path -LiteralPath $BaseApk).Path
$resolvedKeystore = (Resolve-Path -LiteralPath $Keystore).Path
$outputFullPath = [IO.Path]::GetFullPath($OutputApk)
if ($resolvedBase -eq $outputFullPath) {
    throw "The verified base APK must never be modified in place."
}
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($PasswordEnvironmentVariable))) {
    throw "Keystore password environment variable is not set: $PasswordEnvironmentVariable"
}

$sdkRoot = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME,
    (Join-Path $env:LOCALAPPDATA "Android\Sdk")) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
    Select-Object -First 1
if (-not $sdkRoot) {
    throw "Android SDK was not found."
}
$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot "build-tools") -Directory |
    Sort-Object { [version] $_.Name } -Descending | Select-Object -First 1
$aapt2 = Join-Path $buildTools.FullName "aapt2.exe"
$zipalign = Join-Path $buildTools.FullName "zipalign.exe"
$apksigner = Join-Path $buildTools.FullName "apksigner.bat"
$dexdump = Join-Path $buildTools.FullName "dexdump.exe"
foreach ($tool in @($aapt2, $zipalign, $apksigner)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required Android build tool is missing: $tool"
    }
}
$keytoolCommand = Get-Command keytool -ErrorAction Stop
$sevenZipCommand = Get-Command 7z -ErrorAction Stop

function Invoke-Checked {
    param([string] $Executable, [string[]] $Arguments)
    $output = & $Executable @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Executable $($Arguments -join ' ')`n$output"
    }
    return $output
}

function ConvertTo-HexString {
    param([byte[]] $Bytes)
    return (($Bytes | ForEach-Object { $_.ToString("X2") }) -join "")
}

function Get-StreamSha256 {
    param([IO.Stream] $Stream)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (ConvertTo-HexString -Bytes ($sha256.ComputeHash($Stream)))
    } finally {
        $sha256.Dispose()
    }
}

function Get-ZipInventory {
    param([string] $Path)
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
    param([string] $Path, [string] $EntryName)
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    $memory = $null
    try {
        $matches = @($archive.Entries | Where-Object FullName -CEQ $EntryName)
        if ($matches.Count -ne 1) {
            throw "Expected one ZIP entry '$EntryName' in ${Path}; found $($matches.Count)."
        }
        $memory = [IO.MemoryStream]::new()
        $stream = $matches[0].Open()
        try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
        return (, $memory.ToArray())
    } finally {
        if ($memory) { $memory.Dispose() }
        $archive.Dispose()
    }
}

function Get-OpenZipEntryBytes {
    param([IO.Compression.ZipArchive] $Archive, [string] $EntryName)
    $matches = @($Archive.Entries | Where-Object FullName -CEQ $EntryName)
    if ($matches.Count -ne 1) {
        throw "Expected one open ZIP entry '$EntryName'; found $($matches.Count)."
    }
    $memory = [IO.MemoryStream]::new()
    $stream = $matches[0].Open()
    try { $stream.CopyTo($memory) } finally { $stream.Dispose() }
    try { return (, $memory.ToArray()) } finally { $memory.Dispose() }
}

function Set-OpenZipEntryBytes {
    param(
        [IO.Compression.ZipArchive] $Archive,
        [string] $EntryName,
        [byte[]] $Bytes,
        [IO.Compression.CompressionLevel] $CompressionLevel
    )
    $matches = @($Archive.Entries | Where-Object FullName -CEQ $EntryName)
    if ($matches.Count -ne 1) {
        throw "Expected one open ZIP entry '$EntryName'; found $($matches.Count)."
    }
    $matches[0].Delete()
    $newEntry = $Archive.CreateEntry($EntryName, $CompressionLevel)
    $stream = $newEntry.Open()
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}

function Assert-UnchangedZipEntries {
    param(
        [object] $BaseInventory,
        [object] $FinalInventory,
        [Collections.Generic.HashSet[string]] $ChangedEntries
    )
    if ($BaseInventory.Count -ne $FinalInventory.Count) {
        throw "ZIP entry count changed ($($BaseInventory.Count) -> $($FinalInventory.Count))."
    }
    foreach ($name in $BaseInventory.Entries.Keys) {
        if (-not $FinalInventory.Entries.ContainsKey($name)) {
            throw "Repacked APK lost ZIP entry: $name"
        }
        if ($ChangedEntries.Contains($name)) { continue }
        $before = $BaseInventory.Entries[$name]
        $after = $FinalInventory.Entries[$name]
        if ($before.Length -ne $after.Length -or $before.Sha256 -cne $after.Sha256) {
            throw "Unrelated APK entry changed during repack: $name"
        }
    }
}

function Assert-ApkSigningProfile {
    param([string] $SigningText, [string] $ExpectedSigner)
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
    $certificateMatches = [regex]::Matches($SigningText,
        "Signer #\d+ certificate SHA-256 digest: (?<value>[0-9a-fA-F]+)")
    if ($certificateMatches.Count -ne 1) {
        throw "Expected one signer certificate digest; found $($certificateMatches.Count)."
    }
    $signer = $certificateMatches[0].Groups["value"].Value.ToUpperInvariant()
    if ($signer -cne $ExpectedSigner.ToUpperInvariant()) {
        throw "APK signer does not match the locked signing lineage."
    }
    return $signer
}

function Assert-KeystoreSigner {
    param(
        [string] $Keytool,
        [string] $KeystorePath,
        [string] $Alias,
        [string] $PasswordVariable,
        [string] $ExpectedSigner
    )
    $details = Invoke-Checked $Keytool @(
        "-list", "-v", "-keystore", $KeystorePath,
        "-storepass:env", $PasswordVariable, "-alias", $Alias)
    $match = [regex]::Match($details, "SHA256:\s*(?<value>(?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})")
    if (-not $match.Success) { throw "keytool returned no SHA-256 certificate fingerprint." }
    $signer = $match.Groups["value"].Value.Replace(":", "").ToUpperInvariant()
    if ($signer -cne $ExpectedSigner.ToUpperInvariant()) {
        throw "The selected keystore does not contain the locked signing certificate."
    }
}

function Get-BadgingValue {
    param([string] $Badging, [string] $Name)
    $package = [regex]::Match($Badging,
        "package: name='(?<package>[^']+)' versionCode='(?<code>[^']+)' versionName='(?<name>[^']+)'")
    if (-not $package.Success) { throw "aapt2 returned no parseable package line." }
    switch ($Name) {
        "package" { return $package.Groups["package"].Value }
        "code" { return $package.Groups["code"].Value }
        "name" { return $package.Groups["name"].Value }
        default { throw "Unknown badging field: $Name" }
    }
}

function Find-ByteSequence {
    param([byte[]] $Bytes, [byte[]] $Needle)
    $matches = [Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le $Bytes.Length - $Needle.Length; $i++) {
        $same = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Needle[$j]) { $same = $false; break }
        }
        if ($same) { $matches.Add($i) }
    }
    return $matches.ToArray()
}

if (-not ("Qcxr.Repack.DexChecksums" -as [type])) {
    Add-Type -TypeDefinition @"
namespace Qcxr.Repack {
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

function Patch-UniqueEqualLengthBytes {
    param(
        [byte[]] $Bytes,
        [byte[]] $OldValue,
        [byte[]] $NewValue,
        [string] $Description
    )
    if ($OldValue.Length -ne $NewValue.Length) {
        throw "$Description replacement must have the same byte length."
    }
    $matches = @(Find-ByteSequence -Bytes $Bytes -Needle $OldValue)
    if ($matches.Count -ne 1) {
        throw "Expected one $Description value, found $($matches.Count)."
    }
    $NewValue.CopyTo($Bytes, $matches[0])
}

function Update-DexHeader {
    param([byte[]] $Bytes)
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
    $checksum = [Qcxr.Repack.DexChecksums]::Adler32($Bytes, 12, $Bytes.Length - 12)
    [BitConverter]::GetBytes([uint32] $checksum).CopyTo($Bytes, 8)
}

function Assert-DexHeader {
    param([byte[]] $Bytes)
    $storedChecksum = [BitConverter]::ToUInt32($Bytes, 8)
    $expectedChecksum = [Qcxr.Repack.DexChecksums]::Adler32($Bytes, 12, $Bytes.Length - 12)
    if ($storedChecksum -ne $expectedChecksum) { throw "classes.dex Adler-32 checksum is invalid." }
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
    param([byte[]] $Bytes, [string] $OldName, [string] $NewName)
    Patch-UniqueEqualLengthBytes -Bytes $Bytes `
        -OldValue ([Text.Encoding]::UTF8.GetBytes($OldName)) `
        -NewValue ([Text.Encoding]::UTF8.GetBytes($NewName)) `
        -Description "classes.dex versionName"
    Update-DexHeader $Bytes
    Assert-DexHeader $Bytes
    return (, $Bytes)
}

function Patch-UnityVersionName {
    param([byte[]] $Bytes, [string] $OldName, [string] $NewName)
    Patch-UniqueEqualLengthBytes -Bytes $Bytes `
        -OldValue ([Text.Encoding]::UTF8.GetBytes($OldName)) `
        -NewValue ([Text.Encoding]::UTF8.GetBytes($NewName)) `
        -Description "Unity Application.version"
    return (, $Bytes)
}

function Patch-BinaryManifest {
    param(
        [byte[]] $Bytes,
        [int] $OldCode,
        [int] $NewCode,
        [string] $OldName,
        [string] $NewName
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
            if ($attributeSize -lt 20) { throw "Malformed binary XML attribute size." }
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

    $oldUtf16 = [Text.Encoding]::Unicode.GetBytes($OldName)
    $newUtf16 = [Text.Encoding]::Unicode.GetBytes($NewName)
    $nameOffsets = @(Find-ByteSequence -Bytes $Bytes -Needle $oldUtf16)
    if ($nameOffsets.Count -ne 1) {
        throw "Expected one UTF-16 versionName string, found $($nameOffsets.Count)."
    }
    $newUtf16.CopyTo($Bytes, $nameOffsets[0])
    return $Bytes
}

function Assert-FabricJarMetadata {
    param(
        [string] $Path,
        [string] $ExpectedId,
        [string] $ExpectedVersion,
        [string] $ExpectedMinecraft
    )
    $null = Get-ZipInventory $Path
    $metadataBytes = Get-ZipEntryBytes -Path $Path -EntryName "fabric.mod.json"
    try {
        $metadata = [Text.Encoding]::UTF8.GetString($metadataBytes) | ConvertFrom-Json
    } catch {
        throw "Invalid fabric.mod.json in ${Path}: $($_.Exception.Message)"
    }
    if ([string] $metadata.id -cne $ExpectedId -or
        [string] $metadata.version -cne $ExpectedVersion -or
        [string] $metadata.depends.minecraft -cne $ExpectedMinecraft) {
        throw "Unexpected Fabric metadata in ${Path}: $($metadata.id) / $($metadata.version) / $($metadata.depends.minecraft)"
    }
}

function Assert-PayloadManifests {
    param([hashtable] $Payloads, [object] $Lock)
    $specs = @(
        [pscustomobject]@{
            Slug = "Vivecraft"
            EntryName = "assets/mods/vivecraft-26.2-1.3.15-quest.bin"
            Id = "vivecraft"
            JarVersion = "26.2-1.3.15"
            Minecraft = "26.2.x"
            CatalogVersion = [string] $Lock.bundledArtifacts.vivecraft.version
            ExpectedHash = [string] $Lock.bundledArtifacts.vivecraft.sha256
        },
        [pscustomobject]@{
            Slug = "Vivecraft-Essentials-Quest"
            EntryName = "assets/mods/vivecraft-essentials-quest.bin"
            Id = "vivecraft_essentials_quest"
            JarVersion = [string] $Lock.addOnSlot.version
            Minecraft = "26.2"
            CatalogVersion = [string] $Lock.addOnSlot.version
            ExpectedHash = [string] $Lock.addOnSlot.sha256
        }
    )

    foreach ($spec in $specs) {
        $path = [string] $Payloads[$spec.EntryName]
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($spec.ExpectedHash -notmatch '^[0-9A-Fa-f]{64}$' -or
            $actualHash -cne $spec.ExpectedHash.ToUpperInvariant()) {
            throw "Locked payload hash mismatch for $($spec.Slug)."
        }
        Assert-FabricJarMetadata -Path $path -ExpectedId $spec.Id `
            -ExpectedVersion $spec.JarVersion -ExpectedMinecraft $spec.Minecraft
    }

    foreach ($manifestEntry in @("assets/mods.json", "assets/devmods.json")) {
        $manifestPath = [string] $Payloads[$manifestEntry]
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        } catch {
            throw "Invalid ${manifestEntry}: $($_.Exception.Message)"
        }
        $versions = @($manifest.versions | Where-Object { [string] $_.name -ceq "26.2" })
        if ($versions.Count -ne 1) {
            throw "Expected one Minecraft 26.2 catalog in ${manifestEntry}; found $($versions.Count)."
        }
        $mods = @($versions[0].coreMods) + @($versions[0].defaultMods)
        foreach ($spec in $specs) {
            $matches = @($mods | Where-Object { [string] $_.slug -ceq $spec.Slug })
            if ($matches.Count -ne 1) {
                throw "Expected one $($spec.Slug) record in ${manifestEntry}; found $($matches.Count)."
            }
            $record = $matches[0]
            $expectedLink = "asset://" + $spec.EntryName.Substring("assets/".Length)
            if ([string] $record.version -cne $spec.CatalogVersion -or
                [string] $record.download_link -cne $expectedLink -or
                ([string] $record.sha256).ToUpperInvariant() -cne $spec.ExpectedHash.ToUpperInvariant()) {
                throw "Catalog record mismatch for $($spec.Slug) in ${manifestEntry}."
            }
        }
    }
}

$baseBadging = Invoke-Checked $aapt2 @("dump", "badging", $resolvedBase)
if ((Get-BadgingValue $baseBadging "package") -ne [string] $lock.identity.applicationId -or
    [int](Get-BadgingValue $baseBadging "code") -ne $ExpectedBaseVersionCode -or
    (Get-BadgingValue $baseBadging "name") -ne $ExpectedBaseVersionName) {
    throw "The base APK identity does not match the locked v66 input."
}
$baseSigning = Invoke-Checked $apksigner @("verify", "--verbose", "--print-certs", $resolvedBase)
$expectedSigner = ([string] $lock.identity.expectedSignerSha256).ToUpperInvariant()
$baseSigner = Assert-ApkSigningProfile -SigningText $baseSigning -ExpectedSigner $expectedSigner
$baseSha256 = (Get-FileHash -LiteralPath $resolvedBase -Algorithm SHA256).Hash
$expectedBaseSha256 = [string] $lock.buildProvenance.v67BaseApkSha256
if ($expectedBaseSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
    $baseSha256 -ne $expectedBaseSha256.ToUpperInvariant()) {
    throw "The base APK hash does not match the locked v66 input."
}
Assert-KeystoreSigner -Keytool $keytoolCommand.Source -KeystorePath $resolvedKeystore `
    -Alias $KeyAlias -PasswordVariable $PasswordEnvironmentVariable -ExpectedSigner $expectedSigner
Invoke-Checked $sevenZipCommand.Source @("t", "-bso0", "-bsp0", "-bse1", $resolvedBase) | Out-Null
$baseInventory = Get-ZipInventory $resolvedBase

if (Test-Path -LiteralPath $outputFullPath) {
    throw "Refusing to overwrite an existing output APK: $outputFullPath"
}

$payloads = @{
    "assets/mods.json" = Join-Path $root "Pojlib/src/main/assets/mods.json"
    "assets/devmods.json" = Join-Path $root "Pojlib/src/main/assets/devmods.json"
    "assets/mods/vivecraft-26.2-1.3.15-quest.bin" = Join-Path $root "Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin"
    "assets/mods/vivecraft-essentials-quest.bin" = Join-Path $root "Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin"
}
foreach ($path in $payloads.Values) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing APK payload: $path" }
}
Assert-PayloadManifests -Payloads $payloads -Lock $lock

$tempBasePath = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
$tempRoot = [IO.Path]::GetFullPath((Join-Path $tempBasePath (
    "qcxr-v67-repack-" + [guid]::NewGuid().ToString("N"))))
if (-not $tempRoot.StartsWith($tempBasePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary repack directory escaped the system temp directory."
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$patchedApk = Join-Path $tempRoot "patched-unaligned.apk"
$alignedApk = Join-Path $tempRoot "patched-aligned.apk"
$changedEntries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entryName in @(
    "AndroidManifest.xml",
    "classes.dex",
    "assets/bin/Data/globalgamemanagers"
) + @($payloads.Keys)) {
    [void] $changedEntries.Add($entryName)
}
$outputCreatedByThisRun = $false

try {
    Copy-Item -LiteralPath $resolvedBase -Destination $patchedApk
    $archive = [IO.Compression.ZipFile]::Open($patchedApk, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $manifestBytes = Get-OpenZipEntryBytes $archive "AndroidManifest.xml"
        $manifestBytes = Patch-BinaryManifest -Bytes $manifestBytes `
            -OldCode $ExpectedBaseVersionCode -NewCode $VersionCode `
            -OldName $ExpectedBaseVersionName -NewName $VersionName

        $dexBytes = Get-OpenZipEntryBytes $archive "classes.dex"
        $dexBytes = Patch-DexVersionName -Bytes $dexBytes `
            -OldName $ExpectedBaseVersionName -NewName $VersionName

        $globalManagersBytes = Get-OpenZipEntryBytes $archive "assets/bin/Data/globalgamemanagers"
        $globalManagersBytes = Patch-UnityVersionName -Bytes $globalManagersBytes `
            -OldName $ExpectedBaseVersionName -NewName $VersionName

        Set-OpenZipEntryBytes $archive "AndroidManifest.xml" $manifestBytes `
            ([IO.Compression.CompressionLevel]::Optimal)
        Set-OpenZipEntryBytes $archive "classes.dex" $dexBytes `
            ([IO.Compression.CompressionLevel]::NoCompression)
        Set-OpenZipEntryBytes $archive "assets/bin/Data/globalgamemanagers" $globalManagersBytes `
            ([IO.Compression.CompressionLevel]::Optimal)
        foreach ($entryName in $payloads.Keys) {
            Set-OpenZipEntryBytes $archive $entryName `
                ([IO.File]::ReadAllBytes([string] $payloads[$entryName])) `
                ([IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $archive.Dispose()
    }

    $patchedInventory = Get-ZipInventory $patchedApk
    Assert-UnchangedZipEntries -BaseInventory $baseInventory `
        -FinalInventory $patchedInventory -ChangedEntries $changedEntries
    Invoke-Checked $sevenZipCommand.Source @("t", "-bso0", "-bsp0", "-bse1", $patchedApk) | Out-Null

    $dexTestPath = Join-Path $tempRoot "classes.dex"
    [IO.File]::WriteAllBytes($dexTestPath, (Get-ZipEntryBytes $patchedApk "classes.dex"))
    if (Test-Path -LiteralPath $dexdump -PathType Leaf) {
        Invoke-Checked $dexdump @("-f", $dexTestPath) | Out-Null
    }

    $outputDirectory = Split-Path -Parent $outputFullPath
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    Invoke-Checked $zipalign @("-P", "16", "-f", "4", $patchedApk, $alignedApk) | Out-Null
    $outputCreatedByThisRun = $true
    Invoke-Checked $apksigner @(
        "sign", "--v1-signing-enabled", "false", "--v2-signing-enabled", "true",
        "--v3-signing-enabled", "false", "--v4-signing-enabled", "false",
        "--ks", $resolvedKeystore, "--ks-key-alias", $KeyAlias,
        "--ks-pass", "env:$PasswordEnvironmentVariable", "--key-pass", "env:$PasswordEnvironmentVariable",
        "--out", $outputFullPath, $alignedApk
    ) | Out-Null

    $finalBadging = Invoke-Checked $aapt2 @("dump", "badging", $outputFullPath)
    if ((Get-BadgingValue $finalBadging "package") -ne [string] $lock.identity.applicationId -or
        [int](Get-BadgingValue $finalBadging "code") -ne $VersionCode -or
        (Get-BadgingValue $finalBadging "name") -ne $VersionName) {
        throw "Repacked APK identity verification failed."
    }
    $manifestTree = Invoke-Checked $aapt2 @(
        "dump", "xmltree", $outputFullPath, "--file", "AndroidManifest.xml")
    if ($manifestTree -notmatch "versionCode\(0x0101021b\)=$VersionCode" -or
        $manifestTree -notmatch ('versionName\(0x0101021c\)="' + [regex]::Escape($VersionName) + '"')) {
        throw "Binary AndroidManifest.xml did not round-trip with the requested version."
    }

    $finalSigning = Invoke-Checked $apksigner @("verify", "--verbose", "--print-certs", $outputFullPath)
    $finalSigner = Assert-ApkSigningProfile -SigningText $finalSigning -ExpectedSigner $expectedSigner
    Invoke-Checked $zipalign @("-c", "-P", "16", "-v", "4", $outputFullPath) | Out-Null
    Invoke-Checked $sevenZipCommand.Source @("t", "-bso0", "-bsp0", "-bse1", $outputFullPath) | Out-Null

    $finalInventory = Get-ZipInventory $outputFullPath
    Assert-UnchangedZipEntries -BaseInventory $baseInventory `
        -FinalInventory $finalInventory -ChangedEntries $changedEntries
    foreach ($entryName in $payloads.Keys) {
        $expectedHash = (Get-FileHash -LiteralPath $payloads[$entryName] -Algorithm SHA256).Hash
        if ($finalInventory.Entries[$entryName].Sha256 -cne $expectedHash) {
            throw "Final APK payload hash mismatch: $entryName"
        }
    }

    $finalDex = Get-ZipEntryBytes $outputFullPath "classes.dex"
    Assert-DexHeader $finalDex
    $finalUnity = Get-ZipEntryBytes $outputFullPath "assets/bin/Data/globalgamemanagers"
    foreach ($versionProbe in @(
        [pscustomobject]@{ Bytes = $finalDex; Encoding = [Text.Encoding]::UTF8; Name = "classes.dex" },
        [pscustomobject]@{ Bytes = $finalUnity; Encoding = [Text.Encoding]::UTF8; Name = "globalgamemanagers" },
        [pscustomobject]@{ Bytes = Get-ZipEntryBytes $outputFullPath "AndroidManifest.xml"; Encoding = [Text.Encoding]::Unicode; Name = "AndroidManifest.xml" }
    )) {
        $oldMatches = @(Find-ByteSequence $versionProbe.Bytes $versionProbe.Encoding.GetBytes($ExpectedBaseVersionName))
        $newMatches = @(Find-ByteSequence $versionProbe.Bytes $versionProbe.Encoding.GetBytes($VersionName))
        if ($oldMatches.Count -ne 0 -or $newMatches.Count -ne 1) {
            throw "Embedded versionName consistency failed for $($versionProbe.Name)."
        }
    }

    [pscustomobject]@{
        Output = $outputFullPath
        Sha256 = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash
        VersionCode = $VersionCode
        VersionName = $VersionName
        SignerSha256 = $finalSigner
        BaseApkSha256 = $baseSha256
        EntryCount = $finalInventory.Count
        DexdumpVerified = (Test-Path -LiteralPath $dexdump -PathType Leaf)
    }
} catch {
    if ($outputCreatedByThisRun -and (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
        Remove-Item -LiteralPath $outputFullPath -Force
    }
    throw
} finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
