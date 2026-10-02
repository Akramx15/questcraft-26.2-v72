[CmdletBinding()]
param(
    [string] $SourceRoot = (Join-Path $PSScriptRoot '..\Vivecraft-26.2-Quest\examples\resourcepacks'),
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\v71-bow-resource-packs')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$resolvedSource = (Resolve-Path -LiteralPath $SourceRoot).Path
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
$fixedTimestamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

$packs = Get-ChildItem -LiteralPath $resolvedSource -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pack.mcmeta') } |
    Sort-Object Name

foreach ($pack in $packs) {
    $destination = Join-Path $resolvedOutput ($pack.Name + '-mc26.2.zip')
    $temporary = $destination + '.tmp'
    if (Test-Path -LiteralPath $temporary) {
        [IO.File]::Delete($temporary)
    }

    $archive = [IO.Compression.ZipFile]::Open($temporary, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = Get-ChildItem -LiteralPath $pack.FullName -Recurse -File | Sort-Object FullName
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($pack.FullName, $file.FullName).Replace('\', '/')
            if ($relative.StartsWith('/') -or $relative.Contains('../') -or $relative -eq '..') {
                throw "Unsafe resource-pack entry: $relative"
            }
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $input = $file.OpenRead()
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }

    $verification = [IO.Compression.ZipFile]::OpenRead($temporary)
    try {
        $names = @($verification.Entries | ForEach-Object FullName)
        if ($names.Count -ne (@($names | Sort-Object -Unique)).Count) {
            throw "Duplicate entries in $temporary"
        }
        if ('pack.mcmeta' -notin $names -or
            'assets/vivecraft/bow_guide_styles/energy.json' -notin $names) {
            throw "Incomplete resource pack: $temporary"
        }
    } finally {
        $verification.Dispose()
    }

    [IO.File]::Move($temporary, $destination, $true)
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
    $size = (Get-Item -LiteralPath $destination).Length
    [PSCustomObject]@{
        Name = $pack.Name
        Path = $destination
        Bytes = $size
        SHA256 = $hash
        DefaultEnabled = $false
    }
}
