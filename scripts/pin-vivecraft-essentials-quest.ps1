[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $JarPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._+-]*$')]
    [string] $Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$resolvedJar = (Resolve-Path -LiteralPath $JarPath).Path
$assetRelative = 'Pojlib/src/main/assets/mods/vivecraft-essentials-quest.bin'
$assetPath = Join-Path $root $assetRelative
$manifestRelativePaths = @(
    'Pojlib/mods.json',
    'Pojlib/devmods.json',
    'Pojlib/src/main/assets/mods.json',
    'Pojlib/src/main/assets/devmods.json'
)

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($resolvedJar)
try {
    $metadataEntry = $archive.GetEntry('fabric.mod.json')
    if ($null -eq $metadataEntry) {
        throw 'The supplied artifact is not a Fabric mod JAR (fabric.mod.json is missing).'
    }
    $metadataReader = [IO.StreamReader]::new($metadataEntry.Open(), [Text.Encoding]::UTF8, $true)
    try {
        $metadata = $metadataReader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $metadataReader.Dispose()
    }
} finally {
    $archive.Dispose()
}

if ([string] $metadata.id -cne 'vivecraft_essentials_quest') {
    throw "Unexpected Fabric mod id '$($metadata.id)'; expected 'vivecraft_essentials_quest'."
}
if ([string] $metadata.version -cne $Version) {
    throw "Artifact version '$($metadata.version)' does not match requested version '$Version'."
}
if ([string] $metadata.environment -cne 'client') {
    throw "Unexpected Fabric environment '$($metadata.environment)'; expected 'client'."
}
if ([string] $metadata.depends.minecraft -cne '26.2') {
    throw "Artifact targets Minecraft '$($metadata.depends.minecraft)'; expected '26.2'."
}

$sha256 = (Get-FileHash -LiteralPath $resolvedJar -Algorithm SHA256).Hash.ToUpperInvariant()
$entry = [ordered]@{
    slug = 'Vivecraft-Essentials-Quest'
    version = $Version
    download_link = 'asset://mods/vivecraft-essentials-quest.bin'
    sha256 = $sha256
}

$parsedManifests = @()
foreach ($relativePath in $manifestRelativePaths) {
    $fullPath = Join-Path $root $relativePath
    $manifest = Get-Content -Raw -LiteralPath $fullPath | ConvertFrom-Json
    $version26 = @($manifest.versions | Where-Object name -eq '26.2')
    if ($version26.Count -ne 1) {
        throw "$relativePath must contain exactly one 26.2 block."
    }
    $defaults = @($version26[0].defaultMods | Where-Object slug -ne $entry.slug)
    $version26[0].defaultMods = @($defaults) + [pscustomobject]$entry
    $parsedManifests += [pscustomobject]@{ Path = $fullPath; Json = $manifest }
}

$blocks = @($parsedManifests | ForEach-Object {
    (($_.Json.versions | Where-Object name -eq '26.2') | ConvertTo-Json -Depth 20 -Compress)
})
if (@($blocks | Sort-Object -Unique).Count -ne 1) {
    throw 'Refusing to pin an add-on because the four resulting 26.2 blocks differ.'
}

$utf8 = [Text.UTF8Encoding]::new($false)
$candidateFiles = [System.Collections.Generic.List[object]]::new()
$candidateFiles.Add([pscustomobject]@{
    Path = $assetPath
    Bytes = [IO.File]::ReadAllBytes($resolvedJar)
})
foreach ($manifest in $parsedManifests) {
    $candidateFiles.Add([pscustomobject]@{
        Path = $manifest.Path
        Bytes = $utf8.GetBytes(($manifest.Json | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
    })
}

$checksumPath = Join-Path $root 'CHECKSUMS.sha256'
$checksumLines = @(Get-Content -LiteralPath $checksumPath |
    Where-Object { $_ -notmatch '(?i)  Pojlib/src/main/assets/mods/vivecraft-essentials-quest\.bin$' })
$checksumLines += "$sha256  $assetRelative"
$candidateFiles.Add([pscustomobject]@{
    Path = $checksumPath
    Bytes = $utf8.GetBytes(($checksumLines -join [Environment]::NewLine) + [Environment]::NewLine)
})

$lockPath = Join-Path $root 'STACK.lock.json'
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
$lock.addOnSlot.state = 'pinned-host-artifact'
$lock.addOnSlot.manifestIncluded = $true
$lock.addOnSlot.version = $Version
$lock.addOnSlot.sha256 = $sha256
$candidateFiles.Add([pscustomobject]@{
    Path = $lockPath
    Bytes = $utf8.GetBytes(($lock | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
})

# Validate the complete candidate set before touching any tracked file, then
# replace each destination through a same-directory temporary file. If a later
# destination fails, restore every earlier destination from its in-memory
# snapshot so the repository can never contain a half-pinned release.
$snapshots = [System.Collections.Generic.List[object]]::new()
foreach ($candidate in $candidateFiles) {
    $parent = Split-Path -Parent $candidate.Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $exists = [IO.File]::Exists($candidate.Path)
    $snapshots.Add([pscustomobject]@{
        Path = $candidate.Path
        Existed = $exists
        Bytes = if ($exists) { [IO.File]::ReadAllBytes($candidate.Path) } else { $null }
    })
}

function Set-AtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )

    $temporary = "$Path.pin-$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.pin-$([Guid]::NewGuid().ToString('N')).bak"
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) {
            [IO.File]::Replace($temporary, $Path, $backup, $true)
            [IO.File]::Delete($backup)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
}

$applied = 0
try {
    foreach ($candidate in $candidateFiles) {
        Set-AtomicBytes -Path $candidate.Path -Bytes $candidate.Bytes
        $applied++
    }
} catch {
    for ($index = $applied - 1; $index -ge 0; $index--) {
        $snapshot = $snapshots[$index]
        if ($snapshot.Existed) {
            Set-AtomicBytes -Path $snapshot.Path -Bytes $snapshot.Bytes
        } elseif ([IO.File]::Exists($snapshot.Path)) {
            [IO.File]::Delete($snapshot.Path)
        }
    }
    throw
}

[pscustomobject]@{
    Artifact = $resolvedJar
    Asset = $assetPath
    Version = $Version
    Sha256 = $sha256
    ManifestsUpdated = $manifestRelativePaths.Count
    RuntimeAccepted = $false
}
