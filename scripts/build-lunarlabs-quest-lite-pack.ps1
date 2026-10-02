#requires -Version 7.0
<#
.SYNOPSIS
Builds or verifies deterministic Quest-Lite variants of the pinned LunarLabs pack.

.DESCRIPTION
This is a Host-only tool. Production mode accepts only the pinned LunarLabs
archive and writes beneath the repository exports directory. It preserves all
member names and every JSON/mcmeta payload byte-for-byte. Selected blocks-atlas
PNGs are resized with nearest-neighbour sampling. Animated strips are split and
resized frame-by-frame before being stacked again.

TestFixture mode exists solely for the companion Host self-test. It requires an
explicit expected input hash and confines every path to the operating-system
temporary directory.
#>
[CmdletBinding()]
param(
    [ValidateSet('Build', 'Verify')]
    [string] $Action = 'Build',

    [ValidateSet('probe512', 'half-ge256', 'cap128')]
    [string] $Tier = 'probe512',

    [string] $InputPath = (Join-Path $env:USERPROFILE `
        'Downloads\LunarLabs-26.2-Quest-Vulkan-v2.zip'),

    [string] $OutputPath = '',

    [string] $ReportPath = '',

    [string] $PythonPath = 'python',

    [switch] $TestFixture,

    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string] $TestExpectedInputSha256 = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LockedInputSha256 =
    '227FF427604E4503BAF06A9766977EB7F926841A4325428069A40DC21FCB67D8'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ExportsRoot = Join-Path $script:RepoRoot 'exports'
$script:DefaultOutputRoot = Join-Path $script:ExportsRoot 'lunarlabs-quest-lite'
$script:PathComparison = if ([OperatingSystem]::IsWindows()) {
    [StringComparison]::OrdinalIgnoreCase
}
else {
    [StringComparison]::Ordinal
}

function Get-FullPath([Parameter(Mandatory)][string] $Path) {
    return [IO.Path]::GetFullPath($Path)
}

function Test-PathInside(
    [Parameter(Mandatory)][string] $Candidate,
    [Parameter(Mandatory)][string] $Root
) {
    $candidateFull = (Get-FullPath $Candidate).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $rootFull = (Get-FullPath $Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($candidateFull, $rootFull, $script:PathComparison)) {
        return $true
    }
    return $candidateFull.StartsWith(
        $rootFull + [IO.Path]::DirectorySeparatorChar,
        $script:PathComparison)
}

function Test-PathAlias(
    [Parameter(Mandatory)][string] $Left,
    [Parameter(Mandatory)][string] $Right
) {
    $leftFull = Get-FullPath $Left
    $rightFull = Get-FullPath $Right
    if ([string]::Equals($leftFull, $rightFull, $script:PathComparison)) {
        return $true
    }

    # Resolve existing paths to catch alternate lexical spellings such as an
    # 8.3 Windows path. Reparse points are rejected separately below rather
    # than being accepted merely because they resolve to the same target.
    if (([IO.File]::Exists($leftFull) -or [IO.Directory]::Exists($leftFull)) -and
        ([IO.File]::Exists($rightFull) -or [IO.Directory]::Exists($rightFull))) {
        $leftResolved = (Resolve-Path -LiteralPath $leftFull -ErrorAction Stop).ProviderPath
        $rightResolved = (Resolve-Path -LiteralPath $rightFull -ErrorAction Stop).ProviderPath
        if ([string]::Equals(
                (Get-FullPath $leftResolved),
                (Get-FullPath $rightResolved),
                $script:PathComparison)) {
            return $true
        }
    }
    return $false
}

function Assert-NoReparsePath(
    [Parameter(Mandatory)][string] $Path,
    [Parameter(Mandatory)][string] $Label
) {
    $full = Get-FullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "$Label has no filesystem root: $full"
    }

    $current = $root
    $relative = $full.Substring($root.Length)
    $segments = $relative.Split(
        @([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        }
        catch [Management.Automation.ItemNotFoundException] {
            # Once an ancestor does not exist, no deeper component can already
            # be a link. The Python writer repeats this check after mkdir.
            break
        }
        $linkType = $item.PSObject.Properties['LinkType']
        $isLink = $null -ne $linkType -and
            -not [string]::IsNullOrWhiteSpace([string]$linkType.Value)
        $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($isLink -or $isReparse) {
            throw "$Label traverses a reparse point: $current"
        }
    }
}

$inputFull = Get-FullPath $InputPath
if (-not [IO.File]::Exists($inputFull)) {
    throw "Pinned input does not exist: $inputFull"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $script:DefaultOutputRoot `
        "LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-$Tier.zip"
}
$outputFull = Get-FullPath $OutputPath
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = "$outputFull.report.json"
}
$reportFull = Get-FullPath $ReportPath

if ((Test-PathAlias $inputFull $outputFull) -or
    (Test-PathAlias $inputFull $reportFull) -or
    (Test-PathAlias $outputFull $reportFull)) {
    throw 'Input, output, and report paths must be distinct.'
}

Assert-NoReparsePath $inputFull 'Input path'
Assert-NoReparsePath $outputFull 'Output path'
Assert-NoReparsePath $reportFull 'Report path'

if ($TestFixture) {
    if ([string]::IsNullOrWhiteSpace($TestExpectedInputSha256)) {
        throw 'TestFixture requires TestExpectedInputSha256.'
    }
    $temporaryRoot = Get-FullPath ([IO.Path]::GetTempPath())
    foreach ($path in @($inputFull, $outputFull, $reportFull)) {
        if (-not (Test-PathInside $path $temporaryRoot)) {
            throw "TestFixture paths must remain under $temporaryRoot"
        }
    }
    $expectedInputSha256 = $TestExpectedInputSha256.ToUpperInvariant()
}
else {
    if (-not [string]::IsNullOrWhiteSpace($TestExpectedInputSha256)) {
        throw 'TestExpectedInputSha256 is forbidden outside TestFixture mode.'
    }
    foreach ($path in @($outputFull, $reportFull)) {
        if (-not (Test-PathInside $path $script:ExportsRoot)) {
            throw "Production outputs must remain beneath $($script:ExportsRoot)"
        }
    }
    $expectedInputSha256 = $script:LockedInputSha256
}

$worker = @'
import argparse
import binascii
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import sys
import tempfile
import zipfile
import zlib

try:
    from PIL import Image
except Exception as exc:
    raise SystemExit(f"Pillow is required: {exc}")

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
RESOURCE_NAMESPACE = re.compile(r"^[a-z0-9_.-]+$")
RESOURCE_PATH = re.compile(r"^[a-z0-9_./-]+$")
BLOCKS_ATLAS = "assets/minecraft/atlases/blocks.json"


class PackError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise PackError(message)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest().upper()


def strict_json(data, name):
    def reject(value):
        raise PackError(f"non-finite JSON value {value!r}: {name}")
    try:
        return json.loads(data.decode("utf-8"), parse_constant=reject)
    except PackError:
        raise
    except Exception as exc:
        raise PackError(f"invalid UTF-8 JSON {name}: {exc}") from exc


def safe_name(name):
    require(name and "\\" not in name and "\x00" not in name,
            f"unsafe ZIP member name: {name!r}")
    path = PurePosixPath(name)
    require(not path.is_absolute() and ".." not in path.parts,
             f"unsafe ZIP member path: {name!r}")


def absolute_path(path):
    return Path(os.path.abspath(os.fspath(path)))


def assert_no_reparse_ancestors(path, label):
    path = absolute_path(path)
    current = Path(path.anchor)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    for part in path.parts[1:]:
        current = current / part
        try:
            details = os.lstat(current)
        except FileNotFoundError:
            break
        except OSError as exc:
            raise PackError(f"could not inspect {label} component {current}: {exc}") \
                from exc
        attributes = getattr(details, "st_file_attributes", 0)
        require(not stat.S_ISLNK(details.st_mode) and
                not (attributes & reparse_flag),
                f"{label} traverses a reparse point: {current}")


def paths_alias(left, right):
    left = absolute_path(left)
    right = absolute_path(right)
    if os.path.normcase(os.fspath(left)) == os.path.normcase(os.fspath(right)):
        return True
    try:
        if os.path.lexists(left) and os.path.lexists(right):
            return os.path.samefile(left, right)
    except OSError as exc:
        raise PackError(f"could not compare path identity: {exc}") from exc
    return False


def validate_png(data, name):
    require(data.startswith(PNG_SIGNATURE), f"bad PNG signature: {name}")
    offset = len(PNG_SIGNATURE)
    saw_ihdr = False
    saw_iend = False
    width = height = None
    while offset < len(data):
        require(offset + 12 <= len(data), f"truncated PNG chunk: {name}")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(data), f"PNG chunk exceeds payload: {name}")
        payload = data[offset + 8:offset + 8 + length]
        observed = struct.unpack(">I", data[offset + 8 + length:end])[0]
        expected = binascii.crc32(kind + payload) & 0xFFFFFFFF
        require(observed == expected, f"PNG chunk CRC mismatch: {name}")
        if kind == b"IHDR":
            require(not saw_ihdr and length == 13, f"invalid IHDR: {name}")
            width, height = struct.unpack(">II", payload[:8])
            require(width > 0 and height > 0, f"invalid PNG dimensions: {name}")
            saw_ihdr = True
        elif kind == b"IEND":
            require(length == 0, f"invalid IEND: {name}")
            saw_iend = True
            require(end == len(data), f"trailing bytes after IEND: {name}")
        offset = end
    require(saw_ihdr and saw_iend, f"incomplete PNG structure: {name}")
    try:
        with Image.open(io.BytesIO(data)) as image:
            image.verify()
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            require(image.width == width and image.height == height,
                    f"Pillow/PNG dimension disagreement: {name}")
    except PackError:
        raise
    except Exception as exc:
        raise PackError(f"Pillow could not decode {name}: {exc}") from exc
    return width, height


def parse_location(value, context):
    require(isinstance(value, str) and value, f"bad resource location: {context}")
    namespace, separator, path = value.partition(":")
    if not separator:
        namespace, path = "minecraft", namespace
    require(RESOURCE_NAMESPACE.fullmatch(namespace) is not None,
            f"bad namespace: {context}")
    require(RESOURCE_PATH.fullmatch(path) is not None and
            ".." not in path.split("/"), f"bad resource path: {context}")
    return namespace, path


def read_members(blob, label):
    try:
        with zipfile.ZipFile(io.BytesIO(blob), "r") as archive:
            require(archive.testzip() is None, f"ZIP CRC failure: {label}")
            infos = archive.infolist()
            names = [entry.filename for entry in infos]
            require(len(names) == len(set(names)), f"duplicate ZIP names: {label}")
            for entry in infos:
                safe_name(entry.filename)
                require(not (entry.flag_bits & 0x1),
                        f"encrypted member is forbidden: {entry.filename}")
                mode = (entry.external_attr >> 16) & 0xF000
                require(mode not in {0xA000, 0x6000},
                        f"link/device member is forbidden: {entry.filename}")
            return {entry.filename: archive.read(entry) for entry in infos}, names
    except PackError:
        raise
    except Exception as exc:
        raise PackError(f"could not read ZIP {label}: {exc}") from exc


def overlay_range(entry, context):
    formats = entry.get("formats")
    if isinstance(formats, int) and not isinstance(formats, bool):
        minimum = maximum = formats
    elif isinstance(formats, list) and len(formats) == 2 and all(
            isinstance(item, int) and not isinstance(item, bool) for item in formats):
        minimum, maximum = formats
    else:
        minimum, maximum = entry.get("min_format"), entry.get("max_format")
        require(all(isinstance(item, int) and not isinstance(item, bool)
                    for item in (minimum, maximum)),
                f"unsupported overlay range: {context}")
    require(minimum <= maximum, f"reversed overlay range: {context}")
    return minimum, maximum


def active_overlays(members):
    require("pack.mcmeta" in members, "pack.mcmeta is missing")
    document = strict_json(members["pack.mcmeta"], "pack.mcmeta")
    require(isinstance(document, dict) and isinstance(document.get("pack"), dict),
            "pack.mcmeta lacks pack object")
    pack_format = document["pack"].get("pack_format")
    require(isinstance(pack_format, int) and not isinstance(pack_format, bool),
            "pack_format is not an integer")
    overlay_root = document.get("overlays", {})
    require(isinstance(overlay_root, dict), "overlays is not an object")
    entries = overlay_root.get("entries", [])
    require(isinstance(entries, list), "overlay entries is not a list")
    active = []
    for index, entry in enumerate(entries):
        require(isinstance(entry, dict), f"overlay {index} is not an object")
        directory = entry.get("directory")
        require(isinstance(directory, str) and directory and
                "/" not in directory and "\\" not in directory and
                directory not in {".", ".."}, f"unsafe overlay directory {index}")
        minimum, maximum = overlay_range(entry, f"overlay {index}")
        if minimum <= pack_format <= maximum:
            active.append(directory)
    return pack_format, active


def regex_match(pattern, value, context):
    require(isinstance(pattern, str), f"filter pattern is not text: {context}")
    try:
        return re.fullmatch(pattern, value) is not None
    except re.error as exc:
        raise PackError(f"invalid filter regex {context}: {exc}") from exc


def resolve_atlas(members):
    pack_format, overlays = active_overlays(members)
    for directory in overlays:
        prefix = directory + "/"
        conflicting = [name for name in members if name.startswith(prefix) and
                       (name == prefix + BLOCKS_ATLAS or
                        name.lower().endswith((".png", ".png.mcmeta")))]
        require(not conflicting,
                "active overlay PNG/atlas content is unsupported: " +
                ", ".join(sorted(conflicting)[:5]))
    require(BLOCKS_ATLAS in members, f"missing {BLOCKS_ATLAS}")
    atlas = strict_json(members[BLOCKS_ATLAS], BLOCKS_ATLAS)
    require(isinstance(atlas, dict) and set(atlas) == {"sources"} and
            isinstance(atlas["sources"], list), "unsupported blocks atlas schema")
    png_names = tuple(name for name in members if name.lower().endswith(".png"))
    bindings = []
    occurrences = 0
    for index, source in enumerate(atlas["sources"]):
        require(isinstance(source, dict), f"atlas source {index} is not an object")
        kind = source.get("type")
        if kind == "single":
            require(set(source).issubset({"type", "resource", "sprite"}),
                    f"unsupported single fields at {index}")
            namespace, path = parse_location(source.get("resource"), f"source {index}")
            sprite_ns, sprite_path = parse_location(
                source.get("sprite", source.get("resource")), f"sprite {index}")
            physical = f"assets/{namespace}/textures/{path}.png"
            if physical in members:
                bindings.append((physical, f"{sprite_ns}:{sprite_path}"))
                occurrences += 1
        elif kind == "directory":
            require(set(source) == {"type", "source", "prefix"},
                    f"unsupported directory fields at {index}")
            directory = source.get("source")
            sprite_prefix = source.get("prefix")
            require(isinstance(directory, str) and RESOURCE_PATH.fullmatch(directory) and
                    directory == directory.strip("/"), f"bad directory source {index}")
            require(isinstance(sprite_prefix, str) and
                    RESOURCE_PATH.fullmatch(sprite_prefix), f"bad directory prefix {index}")
            texture_prefix = directory + "/"
            for physical in png_names:
                parts = physical.split("/", 3)
                if len(parts) != 4 or parts[0] != "assets" or parts[2] != "textures":
                    continue
                texture_path = parts[3][:-4]
                if texture_path.startswith(texture_prefix):
                    relative = texture_path[len(texture_prefix):]
                    bindings.append((physical, f"{parts[1]}:{sprite_prefix}{relative}"))
                    occurrences += 1
        elif kind == "filter":
            require(set(source) == {"type", "pattern"} and
                    isinstance(source.get("pattern"), dict),
                    f"unsupported filter source {index}")
            pattern = source["pattern"]
            require(set(pattern).issubset({"namespace", "path"}),
                    f"unsupported filter fields {index}")
            retained = []
            for physical, sprite in bindings:
                namespace, path = sprite.split(":", 1)
                if not (regex_match(pattern.get("namespace", ".*"), namespace,
                                    f"filter {index}") and
                        regex_match(pattern.get("path", ".*"), path,
                                    f"filter {index}")):
                    retained.append((physical, sprite))
            bindings = retained
        else:
            raise PackError(f"unsupported atlas source type {kind!r} at {index}")
    by_sprite = {}
    duplicate_declarations = 0
    for physical, sprite in bindings:
        previous = by_sprite.get(sprite)
        if previous is not None:
            require(previous == physical,
                    f"sprite {sprite} resolves to conflicting physical resources")
            duplicate_declarations += 1
        else:
            by_sprite[sprite] = physical
    return pack_format, tuple(sorted(set(by_sprite.values()))), len(bindings), \
        len(by_sprite), duplicate_declarations


def animation_view(png, metadata, name):
    document = strict_json(metadata, name + ".mcmeta")
    animation = document.get("animation") if isinstance(document, dict) else None
    require(isinstance(animation, dict), f"missing animation object: {name}")
    require("width" not in animation and "height" not in animation,
            f"explicit animation geometry is unsupported: {name}")
    with Image.open(io.BytesIO(png)) as source:
        source.load()
        rgba = source.convert("RGBA")
    frame_width = min(rgba.width, rgba.height)
    frame_height = frame_width
    require(rgba.width == frame_width and rgba.height % frame_height == 0,
            f"unsupported animation strip geometry: {name}")
    physical_count = rgba.height // frame_height
    default_time = animation.get("frametime", 1)
    require(isinstance(default_time, int) and not isinstance(default_time, bool) and
            default_time > 0, f"invalid animation frametime: {name}")
    interpolate = animation.get("interpolate", False)
    require(isinstance(interpolate, bool), f"invalid interpolation flag: {name}")
    raw_frames = animation.get("frames")
    entries = []
    if raw_frames is None:
        entries = [(index, default_time) for index in range(physical_count)]
    else:
        require(isinstance(raw_frames, list) and raw_frames,
                f"invalid animation frame list: {name}")
        for position, raw in enumerate(raw_frames):
            if isinstance(raw, int) and not isinstance(raw, bool):
                index, duration = raw, default_time
            else:
                require(isinstance(raw, dict) and set(raw).issubset({"index", "time"}),
                        f"invalid animation frame {position}: {name}")
                index, duration = raw.get("index"), raw.get("time", default_time)
            require(isinstance(index, int) and not isinstance(index, bool) and
                    0 <= index < physical_count, f"frame index out of range: {name}")
            require(isinstance(duration, int) and not isinstance(duration, bool) and
                    duration > 0, f"frame duration invalid: {name}")
            entries.append((index, duration))
    return rgba, frame_width, frame_height, physical_count, tuple(entries), interpolate


def target_dimensions(width, height, tier):
    maximum = max(width, height)
    if tier == "probe512":
        if maximum < 512:
            return width, height
        require(width % 2 == 0 and height % 2 == 0,
                "probe512 requires even dimensions")
        return width // 2, height // 2
    if tier == "half-ge256":
        if maximum < 256:
            return width, height
        require(width % 2 == 0 and height % 2 == 0,
                "half-ge256 requires even dimensions")
        return width // 2, height // 2
    if tier == "cap128":
        if maximum <= 128:
            return width, height
        scale = 128.0 / maximum
        return max(1, round(width * scale)), max(1, round(height * scale))
    raise PackError(f"unknown tier {tier}")


def encode_png(image):
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=False, compress_level=9)
    return output.getvalue()


def mip_bytes(width, height, levels=4):
    return sum(max(1, width >> level) * max(1, height >> level) * 4
               for level in range(levels + 1))


def transform_png(members, name, tier):
    original = members[name]
    width, height = validate_png(original, name)
    metadata_name = name + ".mcmeta"
    animated = metadata_name in members
    if animated:
        image, logical_width, logical_height, frame_count, entries, interpolate = \
            animation_view(original, members[metadata_name], name)
    else:
        with Image.open(io.BytesIO(original)) as source:
            source.load()
            image = source.convert("RGBA")
        logical_width, logical_height = width, height
        frame_count, entries, interpolate = 1, (), False
    new_width, new_height = target_dimensions(logical_width, logical_height, tier)
    if (new_width, new_height) == (logical_width, logical_height):
        return None, {
            "animated": animated,
            "logicalWidth": logical_width,
            "logicalHeight": logical_height,
            "physicalWidth": width,
            "physicalHeight": height,
            "physicalFrames": frame_count,
        }
    if animated:
        frames = []
        for index in range(frame_count):
            top = index * logical_height
            frame = image.crop((0, top, logical_width, top + logical_height))
            frames.append(frame.resize((new_width, new_height), Image.Resampling.NEAREST))
        resized = Image.new("RGBA", (new_width, new_height * frame_count))
        for index, frame in enumerate(frames):
            resized.paste(frame, (0, index * new_height))
    else:
        resized = image.resize((new_width, new_height), Image.Resampling.NEAREST)
    encoded = encode_png(resized)
    out_width, out_height = validate_png(encoded, name)
    require(out_width == new_width and
            out_height == new_height * frame_count,
            f"output dimensions mismatch: {name}")
    if animated:
        _out, check_width, check_height, check_count, check_entries, check_interp = \
            animation_view(encoded, members[metadata_name], name)
        require((check_width, check_height, check_count, check_entries, check_interp) ==
                (new_width, new_height, frame_count, entries, interpolate),
                f"animation semantics changed: {name}")
    record = {
        "path": name,
        "animated": animated,
        "physicalFrames": frame_count,
        "logicalBefore": [logical_width, logical_height],
        "logicalAfter": [new_width, new_height],
        "physicalBefore": [width, height],
        "physicalAfter": [out_width, out_height],
        "baseSlotBytesSaved": logical_width * logical_height * 4 -
                              new_width * new_height * 4,
        "mip0Through4SlotBytesSaved": mip_bytes(logical_width, logical_height) -
                                     mip_bytes(new_width, new_height),
        "physicalDecodedRgbaBytesSaved": width * height * 4 -
                                         out_width * out_height * 4,
    }
    return encoded, record


def normalized_zip(members):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9, strict_timestamps=True) as archive:
        for name in sorted(members):
            payload = members[name]
            info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = ((0o40755 if name.endswith("/") else 0o100644) << 16)
            info.flag_bits = 0x800
            archive.writestr(info, payload, compress_type=zipfile.ZIP_DEFLATED,
                             compresslevel=9)
    return output.getvalue()


def build_expected(input_blob, input_name, output_name, expected_hash, tier):
    observed_hash = sha256_bytes(input_blob)
    require(observed_hash == expected_hash.upper(),
            f"input SHA-256 mismatch: expected {expected_hash}, observed {observed_hash}")
    members, original_names = read_members(input_blob, input_name)
    for name, payload in members.items():
        lowered = name.lower()
        if lowered.endswith((".json", ".mcmeta")):
            strict_json(payload, name)
        if lowered.endswith(".png"):
            validate_png(payload, name)
    pack_format, selected, occurrences, unique_sprites, duplicate_declarations = \
        resolve_atlas(members)
    replacements = {}
    records = []
    selected_animated = 0
    selected_physical_rgba = 0
    selected_base_slots = 0
    selected_mip_slots = 0
    for name in selected:
        encoded, info = transform_png(members, name, tier)
        selected_animated += int(info["animated"])
        if encoded is None:
            physical_width, physical_height = info["physicalWidth"], info["physicalHeight"]
            logical_width, logical_height = info["logicalWidth"], info["logicalHeight"]
        else:
            physical_width, physical_height = info["physicalBefore"]
            logical_width, logical_height = info["logicalBefore"]
        selected_physical_rgba += physical_width * physical_height * 4
        selected_base_slots += logical_width * logical_height * 4
        selected_mip_slots += mip_bytes(logical_width, logical_height)
        if encoded is not None:
            replacements[name] = encoded
            records.append(info)
    require(records, f"tier {tier} selected no sprites")
    output_members = dict(members)
    output_members.update(replacements)
    output_blob = normalized_zip(output_members)
    verified_members, output_names = read_members(output_blob, output_name)
    require(output_names == sorted(original_names), "output ZIP order is not normalized")
    require(set(output_names) == set(original_names), "member names changed")
    for name in original_names:
        if name.lower().endswith((".json", ".mcmeta")):
            require(verified_members[name] == members[name],
                    f"JSON/mcmeta bytes changed: {name}")
        elif name not in replacements:
            require(verified_members[name] == members[name],
                    f"unselected member bytes changed: {name}")
    with zipfile.ZipFile(io.BytesIO(output_blob), "r") as archive:
        require(all(entry.date_time == FIXED_ZIP_TIME for entry in archive.infolist()),
                "ZIP timestamps were not normalized")
    totals = {
        "baseSlotBytesSaved": sum(item["baseSlotBytesSaved"] for item in records),
        "mip0Through4SlotBytesSaved":
            sum(item["mip0Through4SlotBytesSaved"] for item in records),
        "physicalDecodedRgbaBytesSaved":
            sum(item["physicalDecodedRgbaBytesSaved"] for item in records),
    }
    report = {
        "schema": "lunarlabs-quest-lite-canary-v1",
        "classification": "OPTIONAL_HOST_ONLY_VISUAL_QUALITY_CANARY",
        "tier": tier,
        "input": {
            "name": input_name,
            "sha256": observed_hash,
            "bytes": len(input_blob),
        },
        "output": {
            "name": output_name,
            "sha256": sha256_bytes(output_blob),
            "bytes": len(output_blob),
        },
        "atlas": {
            "packFormat": pack_format,
            "bindingOccurrences": occurrences,
            "uniqueSpriteIds": unique_sprites,
            "duplicateDeclarations": duplicate_declarations,
            "selectedUniquePhysicalPngs": len(selected),
            "selectedAnimatedPngs": selected_animated,
            "selectedPhysicalDecodedRgbaBytes": selected_physical_rgba,
            "selectedBaseSlotBytes": selected_base_slots,
            "selectedMip0Through4SlotLowerBoundBytes": selected_mip_slots,
        },
        "transformation": {
            "resampling": "nearest-neighbour-per-logical-frame",
            "transformedSprites": len(records),
            **totals,
            "sprites": records,
        },
        "verification": {
            "inputShaPinned": True,
            "inputAndOutputZipCrcPass": True,
            "allPngChunkCrcAndDecodePass": True,
            "memberNamesPreserved": True,
            "zipOrderLexicographicallyNormalized": True,
            "zipTimestampsNormalizedTo1980Utc": True,
            "jsonAndMcmetaByteExact": True,
            "animationFrameCountTimingAndInterpolationPreserved": True,
            "unselectedMemberPayloadsByteExact": True,
        },
        "runtime": {
            "python": sys.version.split()[0],
            "pillow": Image.__version__,
            "zlib": zlib.ZLIB_RUNTIME_VERSION,
        },
        "risks": [
            "Visual detail is intentionally reduced for transformed sprites.",
            "Nominal slot savings are not measured GPU savings; a stitched-atlas dimension boundary must be observed on Quest.",
            "Transformed PNGs are normalized RGBA and do not preserve ancillary PNG chunks.",
            "This artifact has no device, both-eye, gameplay, or performance acceptance.",
        ],
    }
    report_blob = (json.dumps(report, sort_keys=True, indent=2,
                              ensure_ascii=False) + "\n").encode("utf-8")
    return output_blob, report_blob, report


def atomic_write(path, data):
    assert_no_reparse_ancestors(path, "write path")
    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_reparse_ancestors(path, "write path")
    handle, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp",
                                         dir=path.parent)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        assert_no_reparse_ancestors(path, "write path")
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=("Build", "Verify"), required=True)
    parser.add_argument("--tier", choices=("probe512", "half-ge256", "cap128"),
                        required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--expected", required=True)
    args = parser.parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output)
    report_path = Path(args.report)
    for label, path in (("input path", input_path),
                        ("output path", output_path),
                        ("report path", report_path)):
        assert_no_reparse_ancestors(path, label)
    require(not paths_alias(input_path, output_path) and
            not paths_alias(input_path, report_path) and
            not paths_alias(output_path, report_path),
            "input, output, and report paths alias the same filesystem object")
    input_blob = input_path.read_bytes()
    output_blob, report_blob, report = build_expected(
        input_blob, input_path.name, output_path.name, args.expected, args.tier)
    if args.action == "Build":
        atomic_write(output_path, output_blob)
        atomic_write(report_path, report_blob)
    else:
        require(output_path.is_file(), f"output is missing: {output_path}")
        require(report_path.is_file(), f"report is missing: {report_path}")
        require(output_path.read_bytes() == output_blob,
                "output differs from deterministic rebuild")
        require(report_path.read_bytes() == report_blob,
                "report differs from deterministic rebuild")
    require(output_path.read_bytes() == output_blob, "atomic output verification failed")
    require(report_path.read_bytes() == report_blob, "atomic report verification failed")
    print(json.dumps({
        "result": "PASS",
        "action": args.action,
        "tier": args.tier,
        "outputSha256": report["output"]["sha256"],
        "outputBytes": report["output"]["bytes"],
        "transformedSprites": report["transformation"]["transformedSprites"],
        "baseSlotBytesSaved": report["transformation"]["baseSlotBytesSaved"],
        "mip0Through4SlotBytesSaved":
            report["transformation"]["mip0Through4SlotBytesSaved"],
        "physicalDecodedRgbaBytesSaved":
            report["transformation"]["physicalDecodedRgbaBytesSaved"],
    }, sort_keys=True))


try:
    main()
except PackError as exc:
    print(f"QUEST_LITE_FAIL_CLOSED: {exc}", file=sys.stderr)
    raise SystemExit(2)
'@

$workerPath = Join-Path ([IO.Path]::GetTempPath()) `
    ("lunarlabs-quest-lite-worker-{0}.py" -f [Guid]::NewGuid().ToString('N'))
try {
    Assert-NoReparsePath $workerPath 'Temporary worker path'
    [IO.File]::WriteAllText($workerPath, $worker, [Text.UTF8Encoding]::new($false))
    $arguments = @(
        '-I', '-B', $workerPath,
        '--action', $Action,
        '--tier', $Tier,
        '--input', $inputFull,
        '--output', $outputFull,
        '--report', $reportFull,
        '--expected', $expectedInputSha256
    )
    $workerOutput = @(& $PythonPath @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Quest-Lite worker failed with exit code $exitCode`n$($workerOutput -join "`n")"
    }
    $workerOutput | ForEach-Object { Write-Output $_ }
}
finally {
    if ([IO.File]::Exists($workerPath)) {
        [IO.File]::Delete($workerPath)
    }
}
