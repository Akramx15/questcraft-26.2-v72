#requires -Version 7.0
<#
.SYNOPSIS
Host-only self-test for the deterministic LunarLabs Quest-Lite pack builder.

.DESCRIPTION
Creates tiny synthetic packs below the operating-system temporary directory.
It exercises all tiers, deterministic rebuilds, exact JSON/mcmeta preservation,
animation semantics, and fail-closed hash/ZIP/report/geometry paths. It never
invokes ADB or reads a game profile.
#>
[CmdletBinding()]
param(
    [string] $PythonPath = 'python'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Prefix = '[LUNARLABS_QUEST_LITE_SELF_TEST]'
$script:Builder = Join-Path $PSScriptRoot 'build-lunarlabs-quest-lite-pack.ps1'
$script:Assertions = 0

function Assert-True(
    [bool] $Condition,
    [Parameter(Mandatory)][string] $Message
) {
    $script:Assertions++
    if (-not $Condition) { throw "$($script:Prefix) $Message" }
}

function Invoke-ExpectedFailure(
    [Parameter(Mandatory)][hashtable] $Arguments,
    [Parameter(Mandatory)][string] $Description
) {
    $failed = $false
    try {
        & $script:Builder @Arguments | Out-Null
    }
    catch {
        $failed = $true
    }
    Assert-True $failed "$Description did not fail closed."
}

function Get-Hash([Parameter(Mandatory)][string] $Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-FullPath([Parameter(Mandatory)][string] $Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Read-ZipEntryBytes(
    [Parameter(Mandatory)][string] $ArchivePath,
    [Parameter(Mandatory)][string] $EntryName
) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry($EntryName)
        Assert-True ($null -ne $entry) "Missing ZIP entry $EntryName."
        $stream = $entry.Open()
        try {
            $memory = [IO.MemoryStream]::new()
            try {
                $stream.CopyTo($memory)
                return $memory.ToArray()
            }
            finally { $memory.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Get-PngDimensions([Parameter(Mandatory)][byte[]] $Bytes) {
    Assert-True ($Bytes.Length -ge 24) 'PNG fixture output is truncated.'
    $width = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 16))
    $height = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 20))
    return @($width, $height)
}

Assert-True ([IO.File]::Exists($script:Builder)) 'Builder script is missing.'

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryBase `
    ('lunarlabs-quest-lite-self-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

$fixtureWorker = @'
import argparse
import io
import json
from pathlib import Path
import zipfile
from PIL import Image

FIXED = (1980, 1, 1, 0, 0, 0)


def png(width, height, seed):
    image = Image.new("RGBA", (width, height))
    pixels = image.load()
    for y in range(height):
        for x in range(width):
            pixels[x, y] = ((x + seed) & 255, (y * 3 + seed) & 255,
                            (x ^ y ^ seed) & 255, 255 if (x + y) % 5 else 192)
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=False, compress_level=9)
    return output.getvalue()


def write_zip(path, members):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for name in sorted(members):
            info = zipfile.ZipInfo(name, FIXED)
            info.create_system = 3
            info.external_attr = (0o100644 << 16)
            archive.writestr(info, members[name], compress_type=zipfile.ZIP_DEFLATED,
                             compresslevel=9)


parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=("valid", "explicit", "traversal"))
parser.add_argument("output")
args = parser.parse_args()

pack = {"pack": {"pack_format": 88, "description": "synthetic quest-lite test"}}
atlas = {"sources": [
    {"type": "single", "resource": "test:big512"},
    {"type": "single", "resource": "test:big512"},
    {"type": "single", "resource": "test:big256"},
    {"type": "single", "resource": "test:big200"},
    {"type": "single", "resource": "test:anim512"},
]}
animation = {
    "animation": {
        "frametime": 3,
        "interpolate": True,
        "frames": [{"index": 0, "time": 2}, 1, 0],
    }
}
if args.mode == "explicit":
    animation["animation"]["width"] = 512

members = {
    "pack.mcmeta": json.dumps(pack, separators=(",", ":")).encode(),
    "assets/minecraft/atlases/blocks.json":
        json.dumps(atlas, separators=(",", ":")).encode(),
    "assets/test/models/unchanged.json": b'{"parent":"item/generated"}',
    "assets/test/textures/big512.png": png(512, 512, 11),
    "assets/test/textures/big256.png": png(256, 256, 23),
    "assets/test/textures/big200.png": png(200, 200, 37),
    "assets/test/textures/anim512.png": png(512, 1024, 51),
    "assets/test/textures/anim512.png.mcmeta":
        json.dumps(animation, separators=(",", ":")).encode(),
    "assets/test/textures/unselected.png": png(32, 32, 71),
}
if args.mode == "traversal":
    members["../escape.txt"] = b"forbidden"
write_zip(Path(args.output), members)
'@

$fixtureWorkerPath = Join-Path $testRoot 'make-fixture.py'
try {
    [IO.File]::WriteAllText(
        $fixtureWorkerPath,
        $fixtureWorker,
        [Text.UTF8Encoding]::new($false))

    $validInput = Join-Path $testRoot 'fixture.zip'
    & $PythonPath -I -B $fixtureWorkerPath valid $validInput
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create valid fixture.'
    $validHash = Get-Hash $validInput

    $expected = @{
        probe512 = @{
            transformed = 2
            base = 1572864
            mip = 2095104
            physical = 2359296
        }
        'half-ge256' = @{
            transformed = 3
            base = 1769472
            mip = 2356992
            physical = 2555904
        }
        cap128 = @{
            transformed = 4
            base = 2257152
            mip = 3006548
            physical = 3240192
        }
    }

    foreach ($tier in @('probe512', 'half-ge256', 'cap128')) {
        $firstDirectory = Join-Path $testRoot "first-$tier"
        $secondDirectory = Join-Path $testRoot "second-$tier"
        [IO.Directory]::CreateDirectory($firstDirectory) | Out-Null
        [IO.Directory]::CreateDirectory($secondDirectory) | Out-Null
        $fileName = "fixture.quest-lite-$tier.zip"
        $firstOutput = Join-Path $firstDirectory $fileName
        $secondOutput = Join-Path $secondDirectory $fileName
        $firstReport = "$firstOutput.report.json"
        $secondReport = "$secondOutput.report.json"

        $common = @{
            Action = 'Build'
            Tier = $tier
            InputPath = $validInput
            PythonPath = $PythonPath
            TestFixture = $true
            TestExpectedInputSha256 = $validHash
        }
        & $script:Builder @common -OutputPath $firstOutput -ReportPath $firstReport |
            Out-Null
        & $script:Builder @common -OutputPath $secondOutput -ReportPath $secondReport |
            Out-Null

        Assert-True ((Get-Hash $firstOutput) -ceq (Get-Hash $secondOutput)) `
            "$tier output was not deterministic."
        Assert-True ((Get-Hash $firstReport) -ceq (Get-Hash $secondReport)) `
            "$tier report was not deterministic."

        $report = Get-Content -Raw -LiteralPath $firstReport | ConvertFrom-Json
        $tierExpected = $expected[$tier]
        Assert-True ([int]$report.transformation.transformedSprites -eq
            [int]$tierExpected.transformed) "$tier transformed count differs."
        Assert-True ([int64]$report.transformation.baseSlotBytesSaved -eq
            [int64]$tierExpected.base) "$tier base-slot saving differs."
        Assert-True ([int64]$report.transformation.mip0Through4SlotBytesSaved -eq
            [int64]$tierExpected.mip) "$tier mip saving differs."
        Assert-True ([int64]$report.transformation.physicalDecodedRgbaBytesSaved -eq
            [int64]$tierExpected.physical) "$tier physical saving differs."
        Assert-True ([int]$report.atlas.bindingOccurrences -eq 5) `
            "$tier lost the duplicate atlas occurrence."
        Assert-True ([int]$report.atlas.uniqueSpriteIds -eq 4) `
            "$tier unique sprite count differs."
        Assert-True ([int]$report.atlas.duplicateDeclarations -eq 1) `
            "$tier duplicate declaration count differs."
        Assert-True ([bool]$report.verification.jsonAndMcmetaByteExact) `
            "$tier did not verify metadata preservation."
        Assert-True ([bool]$report.verification.animationFrameCountTimingAndInterpolationPreserved) `
            "$tier did not verify animation semantics."

        if ($tier -ceq 'probe512') {
            $metadataName = 'assets/test/textures/anim512.png.mcmeta'
            $jsonName = 'assets/test/models/unchanged.json'
            Assert-True ([Linq.Enumerable]::SequenceEqual(
                    [byte[]](Read-ZipEntryBytes $validInput $metadataName),
                    [byte[]](Read-ZipEntryBytes $firstOutput $metadataName))) `
                'Independent check found changed animation metadata.'
            Assert-True ([Linq.Enumerable]::SequenceEqual(
                    [byte[]](Read-ZipEntryBytes $validInput $jsonName),
                    [byte[]](Read-ZipEntryBytes $firstOutput $jsonName))) `
                'Independent check found changed JSON.'
            $dimensions = Get-PngDimensions (
                Read-ZipEntryBytes $firstOutput 'assets/test/textures/anim512.png')
            Assert-True ($dimensions[0] -eq 256 -and $dimensions[1] -eq 512) `
                'Animated frames were not resized and restacked independently.'
            $archive = [IO.Compression.ZipFile]::OpenRead($firstOutput)
            try {
                $names = @($archive.Entries | ForEach-Object FullName)
                $sortedNames = @($names | Sort-Object -CaseSensitive)
                Assert-True ([Linq.Enumerable]::SequenceEqual(
                        [string[]]$names, [string[]]$sortedNames)) `
                    'Independent check found non-normalized ZIP order.'
                Assert-True (-not ($archive.Entries | Where-Object {
                            $_.LastWriteTime.Year -ne 1980 })) `
                    'Independent check found non-normalized ZIP timestamps.'
            }
            finally { $archive.Dispose() }
        }

        $verify = @{
            Action = 'Verify'
            Tier = $tier
            InputPath = $validInput
            OutputPath = $firstOutput
            ReportPath = $firstReport
            PythonPath = $PythonPath
            TestFixture = $true
            TestExpectedInputSha256 = $validHash
        }
        & $script:Builder @verify | Out-Null

        if ($tier -ceq 'probe512') {
            $tamperedOutput = [IO.File]::ReadAllBytes($firstOutput) + [byte[]]@(0x00)
            [IO.File]::WriteAllBytes($firstOutput, $tamperedOutput)
            Invoke-ExpectedFailure $verify 'Tampered output verification'
            & $script:Builder @common -OutputPath $firstOutput -ReportPath $firstReport |
                Out-Null

            [IO.File]::AppendAllText(
                $firstReport,
                " `n",
                [Text.UTF8Encoding]::new($false))
            Invoke-ExpectedFailure $verify 'Tampered report verification'
            & $script:Builder @common -OutputPath $firstOutput -ReportPath $firstReport |
                Out-Null
        }
    }

    $tamperedInput = Join-Path $testRoot 'fixture-tampered.zip'
    [IO.File]::WriteAllBytes(
        $tamperedInput,
        [IO.File]::ReadAllBytes($validInput) + [byte[]]@(0x00))
    Invoke-ExpectedFailure @{
        Action = 'Build'; Tier = 'probe512'; InputPath = $tamperedInput
        OutputPath = (Join-Path $testRoot 'tampered-output.zip')
        ReportPath = (Join-Path $testRoot 'tampered-report.json')
        PythonPath = $PythonPath; TestFixture = $true
        TestExpectedInputSha256 = $validHash
    } 'Tampered input hash'

    $explicitInput = Join-Path $testRoot 'fixture-explicit.zip'
    & $PythonPath -I -B $fixtureWorkerPath explicit $explicitInput
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create explicit-geometry fixture.'
    Invoke-ExpectedFailure @{
        Action = 'Build'; Tier = 'probe512'; InputPath = $explicitInput
        OutputPath = (Join-Path $testRoot 'explicit-output.zip')
        ReportPath = (Join-Path $testRoot 'explicit-report.json')
        PythonPath = $PythonPath; TestFixture = $true
        TestExpectedInputSha256 = (Get-Hash $explicitInput)
    } 'Explicit animation geometry'

    $traversalInput = Join-Path $testRoot 'fixture-traversal.zip'
    & $PythonPath -I -B $fixtureWorkerPath traversal $traversalInput
    Assert-True ($LASTEXITCODE -eq 0) 'Could not create traversal fixture.'
    Invoke-ExpectedFailure @{
        Action = 'Build'; Tier = 'probe512'; InputPath = $traversalInput
        OutputPath = (Join-Path $testRoot 'traversal-output.zip')
        ReportPath = (Join-Path $testRoot 'traversal-report.json')
        PythonPath = $PythonPath; TestFixture = $true
        TestExpectedInputSha256 = (Get-Hash $traversalInput)
    } 'Path traversal member'

    Invoke-ExpectedFailure @{
        Action = 'Build'; Tier = 'probe512'; InputPath = $validInput
        OutputPath = (Join-Path $testRoot 'override-output.zip')
        ReportPath = (Join-Path $testRoot 'override-report.json')
        PythonPath = $PythonPath; TestExpectedInputSha256 = $validHash
    } 'Production expected-hash override'

    if ([OperatingSystem]::IsWindows()) {
        $caseAliasOutput = Join-Path $testRoot 'case-alias.zip'
        $caseAliasReport = Join-Path $testRoot 'CASE-ALIAS.ZIP'
        $caseSentinel = [Text.UTF8Encoding]::new($false).GetBytes(
            'case-alias-must-not-be-overwritten')
        [IO.File]::WriteAllBytes($caseAliasOutput, $caseSentinel)
        $caseSentinelHash = Get-Hash $caseAliasOutput
        Invoke-ExpectedFailure @{
            Action = 'Build'; Tier = 'probe512'; InputPath = $validInput
            OutputPath = $caseAliasOutput; ReportPath = $caseAliasReport
            PythonPath = $PythonPath; TestFixture = $true
            TestExpectedInputSha256 = $validHash
        } 'Case-insensitive output/report alias'
        Assert-True ((Get-Hash $caseAliasOutput) -ceq $caseSentinelHash) `
            'Case-insensitive alias rejection modified the existing target.'

        $hardLinkOutput = Join-Path $testRoot 'fixture-hardlink.zip'
        New-Item -ItemType HardLink -Path $hardLinkOutput -Target $validInput |
            Out-Null
        $inputHashBeforeHardLinkTest = Get-Hash $validInput
        Invoke-ExpectedFailure @{
            Action = 'Build'; Tier = 'probe512'; InputPath = $validInput
            OutputPath = $hardLinkOutput
            ReportPath = (Join-Path $testRoot 'hardlink-report.json')
            PythonPath = $PythonPath; TestFixture = $true
            TestExpectedInputSha256 = $validHash
        } 'Input/output hard-link identity alias'
        Assert-True ((Get-Hash $validInput) -ceq $inputHashBeforeHardLinkTest) `
            'Hard-link alias rejection modified the pinned input.'
        Assert-True ((Get-Hash $hardLinkOutput) -ceq $inputHashBeforeHardLinkTest) `
            'Hard-link alias rejection modified the alias.'

        $junctionTarget = Join-Path $testRoot 'junction-target'
        $junctionPath = Join-Path $testRoot 'junction-output'
        [IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
        $junctionCreated = $false
        try {
            New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget |
                Out-Null
            $junctionCreated = $true
            $junctionOutput = Join-Path $junctionPath 'blocked-output.zip'
            $junctionReport = Join-Path $junctionPath 'blocked-report.json'
            Invoke-ExpectedFailure @{
                Action = 'Build'; Tier = 'probe512'; InputPath = $validInput
                OutputPath = $junctionOutput; ReportPath = $junctionReport
                PythonPath = $PythonPath; TestFixture = $true
                TestExpectedInputSha256 = $validHash
            } 'Junction ancestor output'
            Assert-True (-not [IO.File]::Exists(
                    (Join-Path $junctionTarget 'blocked-output.zip'))) `
                'Junction rejection wrote the output behind the reparse point.'
            Assert-True (-not [IO.File]::Exists(
                    (Join-Path $junctionTarget 'blocked-report.json'))) `
                'Junction rejection wrote the report behind the reparse point.'
        }
        finally {
            if ($junctionCreated -and [IO.Directory]::Exists($junctionPath)) {
                # Directory.Delete on a junction removes the junction entry and
                # never recursively traverses its target.
                [IO.Directory]::Delete($junctionPath, $false)
            }
        }
    }

    # Expected-failure workers intentionally return 2; do not leak that native
    # exit code to callers after every PowerShell assertion has passed.
    $global:LASTEXITCODE = 0
    Write-Output "$($script:Prefix) PASS ($($script:Assertions) assertions)"
}
finally {
    $resolvedRoot = Get-FullPath $testRoot
    if ($resolvedRoot.StartsWith(
            $temporaryBase.TrimEnd([IO.Path]::DirectorySeparatorChar) +
                [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Directory]::Exists($resolvedRoot)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
