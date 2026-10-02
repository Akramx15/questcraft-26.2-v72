[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifestPaths = @(
    'Pojlib/mods.json',
    'Pojlib/devmods.json',
    'Pojlib/src/main/assets/mods.json',
    'Pojlib/src/main/assets/devmods.json'
)
$expectedSlugs = @(
    'Vivecraft', 'Fabric-API', 'Sodium', 'Lithium', 'Ferrite-Core',
    'BadOptimizations', 'Placeholder-API', 'Mod-Menu', 'ImmersiveMC', 'Xaero-Minimap'
)
$prohibited = @('ImmediatelyFast', 'EntityCulling', 'MoreCulling', 'Krypton', 'DistantHorizons', 'ViveMonkeCraft')
$blocks = @()
$stableLock = Get-Content -Raw -LiteralPath (Join-Path $root 'STACK.lock.json') | ConvertFrom-Json
$lock = Get-Content -Raw -LiteralPath (Join-Path $root 'V71_LAB_RC6_2.lock.json') | ConvertFrom-Json
if ($stableLock.identity.versionCode -ne 69) { throw 'STACK.lock.json has the wrong Stable versionCode.' }
if ($lock.target.package -cne 'com.qcxr.qcxr.canary262' -or
        [int]$lock.target.versionCode -ne 71) {
    throw 'V71_LAB_RC6_2.lock.json is not the integrated Lab contract.'
}
$expectedVivecraftSha = ([string]$lock.pair.core.sha256).ToUpperInvariant()
$expectedAddOnSha = ([string]$lock.pair.veq.sha256).ToUpperInvariant()
$expectedSlugs += 'Vivecraft-Essentials-Quest'

foreach ($relativePath in $manifestPaths) {
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $root $relativePath) | ConvertFrom-Json
    $version26 = @($manifest.versions | Where-Object name -eq '26.2')
    if ($version26.Count -ne 1) { throw "$relativePath does not contain exactly one 26.2 block." }
    $blocks += ($version26[0] | ConvertTo-Json -Depth 20 -Compress)
    $mods = @($version26[0].coreMods) + @($version26[0].defaultMods)
    $slugs = @($mods | ForEach-Object slug)
    if (@(Compare-Object ($expectedSlugs | Sort-Object) ($slugs | Sort-Object)).Count -ne 0) {
        throw "$relativePath does not contain the exact current 26.2 managed set."
    }
    if (@($slugs | Where-Object { $_ -in $prohibited }).Count -ne 0) {
        throw "$relativePath contains a prohibited Personal default."
    }
    foreach ($mod in $mods) {
        if ([string]$mod.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "$relativePath has no valid SHA-256 for $($mod.slug)."
        }
    }
    $vivecraft = @($mods | Where-Object slug -eq 'Vivecraft')
    if ($vivecraft.Count -ne 1 -or ([string]$vivecraft[0].sha256).ToUpperInvariant() -ne $expectedVivecraftSha) {
        throw "$relativePath does not pin the locked Vivecraft SHA-256."
    }
    $addOn = @($mods | Where-Object slug -eq 'Vivecraft-Essentials-Quest')
    if ($addOn.Count -ne 1 -or
            ([string]$addOn[0].sha256).ToUpperInvariant() -ne $expectedAddOnSha -or
            [string]$addOn[0].version -cne [string]$lock.pair.veq.fabricVersion) {
        throw "$relativePath does not pin the locked Lab add-on."
    }
}
if (@($blocks | Sort-Object -Unique).Count -ne 1) {
    throw 'The four 26.2 managed manifest blocks are not identical.'
}

$instances = Get-Content -Raw -LiteralPath (Join-Path $root 'Pojlib/src/main/java/pojlib/util/json/MinecraftInstances.java')
if ($instances -notmatch 'public String\[\] disabledMods;') { throw 'disabledMods is not persisted per instance.' }
if ($instances -notmatch 'Keeping managed mod disabled') { throw 'Disabled managed projects are not purged before sync.' }
if ($instances -notmatch 'StandardCopyOption\.ATOMIC_MOVE') { throw 'Managed downloads are not installed atomically.' }
if ($instances -notmatch 'SHA-256 mismatch for managed project') { throw 'Managed artifact hash enforcement is absent.' }
if ($instances -notmatch 'requiresQuestVulkanBackend\(\)') { throw 'Quest 26.2 Vulkan launch fallback is absent.' }
if ($instances -notmatch 'new File\(gameDir\)\.getName\(\)') { throw 'Quest Vulkan launch fallback does not survive an instance-list refresh.' }

$actualVivecraftSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $lock.pair.core.embeddedAssetPath)).Hash
if ($actualVivecraftSha -ne $expectedVivecraftSha) {
    throw 'The staged Vivecraft asset does not match V71_LAB_RC6_2.lock.json.'
}
$actualAddOnSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $lock.pair.veq.embeddedAssetPath)).Hash
if ($actualAddOnSha -ne $expectedAddOnSha) {
    throw 'The staged add-on asset does not match V71_LAB_RC6_2.lock.json.'
}

[pscustomobject]@{
    Result = 'PASS'
    Manifests = $manifestPaths.Count
    ManagedMods = $expectedSlugs.Count
    DisabledModsPersistence = $true
    HashEnforcement = $true
    AddOnSlot = 'integrated-rc6.2-frozen-veq'
}
