[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ApkPath,

    [string] $ExpectedPackage = "com.qcxr.qcxr.dev262",
    [string] $ExpectedVersionCode = "68",
    [string] $ExpectedVersionName = "6.0.1-26.2-vivecraft-personal.9",
    [string] $ExpectedLabel = "QuestCraft Vivecraft Personal 26.2",
    [string] $ExpectedVivecraftSha256 = "3638F258C7DAAB8391975DB8C39AE254F67A1FD96AA540650D07E5318A0D842F",
    [string] $ExpectedVivecraftVersion = "",
    [string] $ExpectedAddOnSha256 = "",
    [string] $ExpectedAddOnVersion = "",
    [string] $ExpectedLwjglSha256 = "DD19A303D574FCFA68F82300186693BCCC2EF9C6AACDC3ECC3D422EC6DDA4DC9",
    [string] $ExpectedSignerSha256 = "B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A"
)

$ErrorActionPreference = "Stop"

function Get-StreamBytes {
    param([Parameter(Mandatory = $true)][System.IO.Stream] $Stream)

    $memory = [System.IO.MemoryStream]::new()
    try {
        $Stream.CopyTo($memory)
        return ,$memory.ToArray()
    } finally {
        $memory.Dispose()
    }
}

function Test-ByteSequence {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][string] $Text
    )

    $needle = [System.Text.Encoding]::UTF8.GetBytes($Text)
    for ($offset = 0; $offset -le $Bytes.Length - $needle.Length; $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $needle.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $needle[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) { return $true }
    }
    return $false
}

function Invoke-AndroidTool {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & $Executable @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Android tool failed ($LASTEXITCODE): $Executable $($Arguments -join ' ')`n$output"
    }
    return $output
}

$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$sdkCandidates = @(
    @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA "Android\Sdk")
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
)

if (-not $sdkCandidates) {
    throw "Android SDK was not found. Set ANDROID_SDK_ROOT or install it under LocalAppData."
}

$buildTools = @(
    foreach ($sdkRoot in $sdkCandidates) {
        $buildToolsRoot = Join-Path $sdkRoot "build-tools"
        if (Test-Path -LiteralPath $buildToolsRoot -PathType Container) {
            Get-ChildItem -LiteralPath $buildToolsRoot -Directory
        }
    }
) | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1

if (-not $buildTools) {
    throw "No Android SDK Build Tools installation was found in any configured Android SDK."
}

$apksigner = Join-Path $buildTools.FullName "apksigner.bat"
$zipalign = Join-Path $buildTools.FullName "zipalign.exe"
$aapt2 = Join-Path $buildTools.FullName "aapt2.exe"
foreach ($tool in @($apksigner, $zipalign, $aapt2)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required Android tool is missing: $tool"
    }
}

$alignmentOutput = Invoke-AndroidTool $zipalign @("-c", "-P", "16", "-v", "4", $resolvedApk)
$signingOutput = Invoke-AndroidTool $apksigner @("verify", "--verbose", "--print-certs", $resolvedApk)
$badgingOutput = Invoke-AndroidTool $aapt2 @("dump", "badging", $resolvedApk)

$packageMatch = [regex]::Match(
    $badgingOutput,
    "package: name='(?<package>[^']+)' versionCode='(?<code>[^']+)' versionName='(?<name>[^']+)'"
)
if (-not $packageMatch.Success) {
    throw "aapt2 did not return parseable package metadata."
}

$actualPackage = $packageMatch.Groups["package"].Value
$actualVersionCode = $packageMatch.Groups["code"].Value
$actualVersionName = $packageMatch.Groups["name"].Value
if ($actualPackage -ne $ExpectedPackage) {
    throw "Package mismatch: expected $ExpectedPackage, got $actualPackage."
}
if ($actualVersionCode -ne $ExpectedVersionCode) {
    throw "versionCode mismatch: expected $ExpectedVersionCode, got $actualVersionCode."
}
if ($actualVersionName -ne $ExpectedVersionName) {
    throw "versionName mismatch: expected $ExpectedVersionName, got $actualVersionName."
}

$label = [regex]::Match($badgingOutput, "application-label:'(?<label>[^']+)'").Groups["label"].Value
if ($label -ne $ExpectedLabel) {
    throw "Application label mismatch: expected $ExpectedLabel, got $label."
}

$minSdk = [regex]::Match($badgingOutput, "minSdkVersion:'(?<value>[^']+)'").Groups["value"].Value
$targetSdk = [regex]::Match($badgingOutput, "targetSdkVersion:'(?<value>[^']+)'").Groups["value"].Value
if ($minSdk -ne "29") {
    throw "minSdkVersion mismatch: expected 29, got $minSdk."
}
if ($targetSdk -ne "34") {
    throw "targetSdkVersion mismatch: expected 34, got $targetSdk."
}

$signerMatch = [regex]::Match(
    $signingOutput,
    "Signer #1 certificate SHA-256 digest: (?<digest>[0-9a-fA-F]+)"
)
if (-not $signerMatch.Success) {
    throw "apksigner did not return a signer SHA-256 digest."
}
$signerSha256 = $signerMatch.Groups["digest"].Value.ToLowerInvariant()
if ($ExpectedSignerSha256 -and $signerSha256 -ne $ExpectedSignerSha256.ToLowerInvariant()) {
    throw "Signer mismatch: expected $ExpectedSignerSha256, got $signerSha256."
}
if ($signingOutput -notmatch 'Verified using v2 scheme \(APK Signature Scheme v2\): true') {
    throw "APK Signature Scheme v2 verification did not succeed."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$repoRoot = Split-Path -Parent $PSScriptRoot
$stackLockPath = Join-Path $repoRoot "STACK.lock.json"
if (-not (Test-Path -LiteralPath $stackLockPath -PathType Leaf)) {
    throw "STACK.lock.json is missing."
}
$stackLock = Get-Content -Raw -LiteralPath $stackLockPath | ConvertFrom-Json
$addOnExpected = -not [string]::IsNullOrWhiteSpace($ExpectedAddOnSha256) -or
        [bool]$stackLock.addOnSlot.manifestIncluded
$addOnExpectedSha256 = if ([string]::IsNullOrWhiteSpace($ExpectedAddOnSha256)) {
    [string]$stackLock.addOnSlot.sha256
} else {
    $ExpectedAddOnSha256
}
$addOnExpectedVersion = if ([string]::IsNullOrWhiteSpace($ExpectedAddOnVersion)) {
    [string]$stackLock.addOnSlot.version
} else {
    $ExpectedAddOnVersion
}
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedApk)
$labDexGate = "not-applicable"
$personalDexGate = "not-applicable"
try {
    $entryNames = @($archive.Entries | ForEach-Object FullName)

    function Get-ArchiveEntrySha256 {
        param([string] $EntryName)

        $entry = $archive.GetEntry($EntryName)
        if (-not $entry) {
            throw "Cannot hash missing APK entry: $EntryName"
        }
        $stream = $entry.Open()
        try {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try {
                return (($sha256.ComputeHash($stream) | ForEach-Object ToString x2) -join '').ToUpperInvariant()
            } finally {
                $sha256.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    }

    $modsEntry = $archive.GetEntry("assets/mods.json")
    if (-not $modsEntry) {
        throw "Bundled mods.json is missing."
    }
    $reader = [System.IO.StreamReader]::new($modsEntry.Open())
    try {
        $modsManifest = $reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $reader.Dispose()
    }

    $devModsEntry = $archive.GetEntry("assets/devmods.json")
    if (-not $devModsEntry) {
        throw "Bundled devmods.json is missing."
    }
    $reader = [System.IO.StreamReader]::new($devModsEntry.Open())
    try {
        $devModsManifest = $reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $reader.Dispose()
    }

    $vivecraftSha256 = Get-ArchiveEntrySha256 "assets/mods/vivecraft-26.2-1.3.15-quest.bin"
    $lwjglSha256 = Get-ArchiveEntrySha256 "assets/lwjgl/lwjgl-glfw-classes.bin"
    $addOnSha256 = if ($addOnExpected) {
        Get-ArchiveEntrySha256 "assets/mods/vivecraft-essentials-quest.bin"
    } else {
        $null
    }

    if ($ExpectedPackage -ceq "com.qcxr.qcxr.canary262") {
        $dexEntries = @($archive.Entries | Where-Object {
            $_.FullName -match '^classes(?:[0-9]+)?\.dex$'
        })
        if ($dexEntries.Count -eq 0) {
            throw "The Lab APK has no classes*.dex payload to inspect."
        }

        $requiredDexStrings = @(
            "com.qcxr.qcxr.canary262.action.UNATTENDED_ARM",
            "com.qcxr.qcxr.canary262",
            "questcraft-mods-ab-canary-v1",
            "de406c7a0ca5e748dfbe44740278400882a44e3109e2584b243ec02d4003344b",
            "-Dvivecraft.openxrCopyBatch=",
            "openXrCopyBatchMode",
            "takeOpenXrCopyBatchMode"
        )
        if ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.12-rc.8') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v9',
                '26.2-1.3.15+qc.v71.rc8-mining',
                'addb01fa168033c42f97c615daf97cbb927b9e94400606eef27cfbe930015eab',
                'questcraft-veq-v71-canary-v5',
                '0.7.0-v71.rc6',
                'ff7f6fcfda21895764b69f3316ce7e9ebd8d890df675c1e8007835b3814573f9',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.12-rc.7') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v8',
                '26.2-1.3.15+qc.v71.rc7',
                'a1a522c2bb949dbdc2a3ae475b900407324441da50d94e012a7c734b32e498d3',
                'questcraft-veq-v71-canary-v4',
                '0.7.0-v71.rc6',
                'bf7857e4212b18601d6e165a5453caf325bc3ab8eb1d093a324d6aa8c20f70fd',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.12-rc.6.2') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v7',
                '26.2-1.3.15+qc.v71.rc6.2',
                '6449a62588fa944ba238f87178c43ee00bd10e3b223459606b4c002b7f2360af',
                'questcraft-veq-v71-canary-v4',
                '0.7.0-v71.rc6',
                'bf7857e4212b18601d6e165a5453caf325bc3ab8eb1d093a324d6aa8c20f70fd',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -in @(
                    '6.0.1-26.2-vivecraft-personal.12-rc.6',
                    '6.0.1-26.2-vivecraft-personal.12-rc.6.1')) {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v6',
                'questcraft-veq-v71-canary-v4',
                '0.7.0-v71.rc6',
                'bf7857e4212b18601d6e165a5453caf325bc3ab8eb1d093a324d6aa8c20f70fd',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -in @(
                    '6.0.1-26.2-vivecraft-personal.12-rc.5',
                    '6.0.1-26.2-vivecraft-personal.12-rc.5.1',
                    '6.0.1-26.2-vivecraft-personal.12-rc.5.2')) {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v5',
                'questcraft-veq-v71-canary-v3',
                '0.7.0-v70-canary.1',
                '314d3cbd6d7a06d9ad2a5a6ac437a1b3a3c2ae2f1d9927414db4a9b3e7ae0d8b',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.12-rc.4') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v4',
                'questcraft-veq-v71-canary-v3',
                '0.7.0-v70-canary.1',
                '314d3cbd6d7a06d9ad2a5a6ac437a1b3a3c2ae2f1d9927414db4a9b3e7ae0d8b',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.12-rc.3') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v3',
                'questcraft-veq-v71-canary-v3',
                '0.7.0-v70-canary.1',
                '314d3cbd6d7a06d9ad2a5a6ac437a1b3a3c2ae2f1d9927414db4a9b3e7ae0d8b',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '71' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.12-rc.2') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v2',
                'questcraft-veq-v71-canary-v2',
                '0.7.0-v70-canary.1',
                '8eb67999fa9334cf3b18f250b420668b912a2ee4f2b201db51ee1e265744427a',
                'Mojang version metadata endpoint'
            )
        } elseif ($ExpectedVersionCode -ceq '70' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.11-rc.1') {
            $requiredDexStrings += @(
                'questcraft-vivecraft-core-canary-v1',
                'questcraft-veq-v70-canary-v1',
                '0.7.0-v70-canary.1',
                '6575a2a436f1ff74898950a9d781b18641707621cafae064bb61a9709c1696b9'
            )
        } elseif ($ExpectedVersionCode -ceq '69' -and
                $ExpectedVersionName -ceq
                '6.0.1-26.2-vivecraft-personal.10-rc.1') {
            $requiredDexStrings += @(
                'questcraft-veq-frame-snapshot-canary-v1',
                '2ab6b70242cbb45b77fecec81b3d7cca9a45ad82c59ef28f12fdfb0070ff7c36'
            )
        } else {
            throw 'The Lab APK identity is not an allowlisted v69, v70, or v71 contract.'
        }
        $foundDexStrings = @{}
        foreach ($required in $requiredDexStrings) { $foundDexStrings[$required] = $false }
        $forbiddenDexString = "com.qcxr.qcxr.dev262.action.UNATTENDED_ARM"

        foreach ($dexEntry in $dexEntries) {
            $dexStream = $dexEntry.Open()
            try { $dexBytes = Get-StreamBytes $dexStream } finally { $dexStream.Dispose() }
            if (Test-ByteSequence $dexBytes $forbiddenDexString) {
                throw "The Lab APK DEX still contains the accepted Personal unattended action."
            }
            foreach ($required in $requiredDexStrings) {
                if (-not $foundDexStrings[$required] -and
                    (Test-ByteSequence $dexBytes $required)) {
                    $foundDexStrings[$required] = $true
                }
            }
        }
        $missingDexStrings = @($requiredDexStrings | Where-Object {
            -not $foundDexStrings[$_]
        })
        if ($missingDexStrings.Count -ne 0) {
            throw "The rebuilt Lab Pojlib gate did not reach classes*.dex: $($missingDexStrings -join ', ')."
        }
        $labDexGate = "verified"
    } elseif ($ExpectedPackage -ceq "com.qcxr.qcxr.dev262") {
        $dexEntries = @($archive.Entries | Where-Object {
            $_.FullName -match '^classes(?:[0-9]+)?\.dex$'
        })
        if ($dexEntries.Count -eq 0) {
            throw "The Personal APK has no classes*.dex payload to inspect."
        }

        $requiredDexStrings = @(
            "com.qcxr.qcxr.dev262",
            "LauncherCameraParkPolicy",
            "QC_LAUNCHER_CAMERA_PARK_RESULT",
            "NO_CAMERAS"
        )
        $forbiddenDexStrings = @(
            "com.qcxr.qcxr.dev262.action.UNATTENDED_ARM",
            "com.qcxr.qcxr.dev262.action.UNATTENDED_EXECUTE",
            "com.qcxr.qcxr.dev262.action.UNATTENDED_CANCEL",
            "LauncherIdleThrottlePolicy",
            "launcher_idle_throttle",
            "QC_LAUNCHER_IDLE_THROTTLE",
            "getLauncherIdleThrottleMode"
        )
        $foundDexStrings = @{}
        foreach ($required in $requiredDexStrings) { $foundDexStrings[$required] = $false }

        foreach ($dexEntry in $dexEntries) {
            $dexStream = $dexEntry.Open()
            try { $dexBytes = Get-StreamBytes $dexStream } finally { $dexStream.Dispose() }
            foreach ($forbidden in $forbiddenDexStrings) {
                if (Test-ByteSequence $dexBytes $forbidden) {
                    throw "The Personal APK DEX contains forbidden canary symbol: $forbidden"
                }
            }
            foreach ($required in $requiredDexStrings) {
                if (-not $foundDexStrings[$required] -and
                    (Test-ByteSequence $dexBytes $required)) {
                    $foundDexStrings[$required] = $true
                }
            }
        }
        $missingDexStrings = @($requiredDexStrings | Where-Object {
            -not $foundDexStrings[$_]
        })
        if ($missingDexStrings.Count -ne 0) {
            throw "Personal Camera Park did not reach classes*.dex: $($missingDexStrings -join ', ')."
        }
        $personalDexGate = "verified"
    }
} finally {
    $archive.Dispose()
}

$abis = @(
    $entryNames |
        Where-Object { $_ -match '^lib/([^/]+)/.+\.so$' } |
        ForEach-Object { [regex]::Match($_, '^lib/([^/]+)/').Groups[1].Value } |
        Sort-Object -Unique
)
if ($abis.Count -ne 1 -or $abis[0] -ne "arm64-v8a") {
    throw "ABI mismatch: expected only arm64-v8a, found: $($abis -join ', ')."
}

$requiredEntries = @(
    "lib/arm64-v8a/libUnityOpenXR.so",
    "lib/arm64-v8a/libopenxr_loader.so",
    "lib/arm64-v8a/libshaderc.so",
    "lib/arm64-v8a/libspirv-cross-c-shared.so",
    "lib/arm64-v8a/liblwjgl_vma.so",
    "lib/arm64-v8a/libmobileglues.so",
    "assets/mods.json",
    "assets/devmods.json",
    "assets/mods/vivecraft-26.2-1.3.15-quest.bin",
    "assets/lwjgl/lwjgl-glfw-classes.bin",
    "assets/vivecraft-client-config.json"
)
if ($addOnExpected) {
    $requiredEntries += "assets/mods/vivecraft-essentials-quest.bin"
}
$missingEntries = @($requiredEntries | Where-Object { $_ -notin $entryNames })
if ($missingEntries) {
    throw "Required QuestCraft payload is missing: $($missingEntries -join ', ')."
}

if ($vivecraftSha256 -ne $ExpectedVivecraftSha256.ToUpperInvariant()) {
    throw "Embedded Vivecraft hash mismatch: expected $ExpectedVivecraftSha256, got $vivecraftSha256."
}
if ($lwjglSha256 -ne $ExpectedLwjglSha256.ToUpperInvariant()) {
    throw "Embedded LWJGL hash mismatch: expected $ExpectedLwjglSha256, got $lwjglSha256."
}
if ($addOnExpected) {
    if ($addOnExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "STACK.lock.json has no valid SHA-256 for the pinned Vivecraft Essentials Quest add-on."
    }
    if ($addOnSha256 -ne $addOnExpectedSha256.ToUpperInvariant()) {
        throw "Embedded Vivecraft Essentials Quest hash mismatch: expected $addOnExpectedSha256, got $addOnSha256."
    }
}

$version26 = @($modsManifest.versions | Where-Object name -eq "26.2")
if ($version26.Count -ne 1) {
    throw "Bundled mods manifest must contain exactly one 26.2 block."
}
$devVersion26 = @($devModsManifest.versions | Where-Object name -eq "26.2")
if ($devVersion26.Count -ne 1) {
    throw "Bundled devmods manifest must contain exactly one 26.2 block."
}
if (($version26[0] | ConvertTo-Json -Depth 20 -Compress) -ne
    ($devVersion26[0] | ConvertTo-Json -Depth 20 -Compress)) {
    throw "Bundled mods.json and devmods.json have different 26.2 blocks."
}
$managedMods = @($version26[0].coreMods) + @($version26[0].defaultMods)
$managedSlugs = @($managedMods | ForEach-Object slug)
$manifestVivecraft = @($managedMods | Where-Object slug -eq "Vivecraft")
if ($manifestVivecraft.Count -ne 1 -or
    ([string]$manifestVivecraft[0].sha256).ToUpperInvariant() -ne $vivecraftSha256) {
    throw "Bundled mods.json does not pin the embedded Vivecraft SHA-256."
}
if ($addOnExpected) {
    $manifestAddOn = @($managedMods | Where-Object slug -eq "Vivecraft-Essentials-Quest")
    if ($manifestAddOn.Count -ne 1 -or
        ([string]$manifestAddOn[0].sha256).ToUpperInvariant() -ne $addOnSha256) {
        throw "Bundled mods.json does not pin the embedded Vivecraft Essentials Quest SHA-256."
    }
    if ([string]::IsNullOrWhiteSpace($addOnExpectedVersion) -or
        ([string]$manifestAddOn[0].version) -ne $addOnExpectedVersion) {
        throw "Unexpected bundled Vivecraft Essentials Quest version: $($manifestAddOn[0].version)."
    }
}
$requiredSlugs = @(
    "Vivecraft", "Fabric-API", "Sodium", "Lithium", "Ferrite-Core",
    "BadOptimizations", "Placeholder-API", "Mod-Menu", "ImmersiveMC", "Xaero-Minimap"
)
if ($addOnExpected) {
    $requiredSlugs += "Vivecraft-Essentials-Quest"
}
$missingSlugs = @($requiredSlugs | Where-Object { $_ -notin $managedSlugs })
if ($missingSlugs) {
    throw "Bundled 26.2 manifest is missing managed mods: $($missingSlugs -join ', ')."
}
if (($managedSlugs | Sort-Object -Unique).Count -ne $managedSlugs.Count) {
    throw "Bundled 26.2 manifest contains duplicate mod slugs."
}
if ($managedSlugs -match 'ViveMonke|ImmediatelyFast|EntityCulling|MoreCulling|Krypton|Distant') {
    throw "A prohibited v65 default mod was found in the 26.2 manifest."
}
if (-not $addOnExpected -and "Vivecraft-Essentials-Quest" -in $managedSlugs) {
    throw "The add-on is present in the APK manifest while STACK.lock.json still marks it absent."
}
$vivecraftVersion = ($managedMods | Where-Object slug -eq "Vivecraft").version
$expectedVivecraftVersion = if ([string]::IsNullOrWhiteSpace($ExpectedVivecraftVersion)) {
    [string]$stackLock.bundledArtifacts.vivecraft.version
} else {
    $ExpectedVivecraftVersion
}
if ([string]::IsNullOrWhiteSpace($expectedVivecraftVersion) -or
    $vivecraftVersion -ne $expectedVivecraftVersion) {
    throw "Unexpected bundled Vivecraft version: $vivecraftVersion."
}

foreach ($lockedMod in @($stackLock.managedMods)) {
    $manifestMod = @($managedMods | Where-Object slug -eq ([string]$lockedMod.slug))
    if ($manifestMod.Count -ne 1) {
        throw "Managed mod $($lockedMod.slug) is missing or duplicated in the bundled manifest."
    }
    if (([string]$manifestMod[0].version) -ne ([string]$lockedMod.version)) {
        throw "Managed mod version mismatch for $($lockedMod.slug): expected $($lockedMod.version), got $($manifestMod[0].version)."
    }
    if (([string]$manifestMod[0].sha256).ToUpperInvariant() -ne
        ([string]$lockedMod.sha256).ToUpperInvariant()) {
        throw "Managed mod SHA-256 mismatch for $($lockedMod.slug)."
    }
}

$apkHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedApk).Hash
[pscustomobject]@{
    ApkPath = $resolvedApk
    Sha256 = $apkHash
    Package = $actualPackage
    VersionCode = $actualVersionCode
    VersionName = $actualVersionName
    Label = $label
    MinSdk = $minSdk
    TargetSdk = $targetSdk
    Abis = $abis -join ","
    SignerSha256 = $signerSha256
    SignatureV2 = $true
    Zipalign16KiB = $alignmentOutput -match "Verification successful"
    VivecraftSha256 = $vivecraftSha256
    AddOnSha256 = $addOnSha256
    LwjglSha256 = $lwjglSha256
    ManagedMods26_2 = $managedSlugs.Count
    ManifestPair26_2 = "identical"
    RequiredPayload = "present"
    LabDexGate = $labDexGate
    PersonalDexGate = $personalDexGate
}
