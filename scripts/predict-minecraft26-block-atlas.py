#!/usr/bin/env python3
r"""Deterministic, Host-only Minecraft 26.2 blocks-atlas predictor.

The production command accepts only the pinned Minecraft 26.2 client JAR and
the four pinned LunarLabs archives.  It reproduces the relevant
SpriteSourceList and Stitcher behaviour without launching Minecraft, touching
ADB, or reading a game profile.  Its output is a prediction until a Quest
runtime A/B confirms it.

Examples (PowerShell):

  python -I -B scripts/predict-minecraft26-block-atlas.py selftest
  python -I -B scripts/predict-minecraft26-block-atlas.py production `
    --client-jar "$env:USERPROFILE\.gradle\caches\fabric-loom\26.2\minecraft-client.jar" `
    --original-pack "$env:USERPROFILE\Downloads\Compressed\LunarLabs-26.2-Quest-Vulkan-v2.zip" `
    --lite-dir exports\lunarlabs-quest-lite
  python -I -B scripts/predict-minecraft26-block-atlas.py verify <same arguments>
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import tempfile
from typing import Any, Iterable
import warnings
import zipfile
import zlib


SCHEMA_VERSION = 1
MINECRAFT_VERSION = "26.2"
PACK_FORMAT = 88
REQUESTED_MIP_LEVEL = 4
MAX_TEXTURE_SIZE = 16384
MAX_ANISOTROPY_BIT = 0
BLOCKS_ATLAS = "assets/minecraft/atlases/blocks.json"
MISSING_SPRITE = "minecraft:missingno"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
REPORT_FILE_NAME = "MINECRAFT26_BLOCK_ATLAS_PREDICTIONS.json"
FILE_ATTRIBUTE_REPARSE_POINT = 0x400

MAX_ZIP_ENTRIES = 50_000
MAX_ZIP_MEMBER_BYTES = 256 * 1024 * 1024
MAX_ZIP_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_PNG_DECODED_BYTES = 512 * 1024 * 1024

CLIENT_CONTRACT = {
    "fileName": "minecraft-client.jar",
    "sha256": "40896EE9F1E2BEC3C934DAAC7E93D41E9E3D9C2F8AE0CA366D52FFBFD1AFA290",
    "sizeBytes": 39_193_383,
}

PACK_CONTRACTS = (
    {
        "id": "original",
        "fileName": "LunarLabs-26.2-Quest-Vulkan-v2.zip",
        "sha256": "227FF427604E4503BAF06A9766977EB7F926841A4325428069A40DC21FCB67D8",
        "sizeBytes": 6_106_374,
    },
    {
        "id": "probe512",
        "fileName": "LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-probe512.zip",
        "sha256": "47DD0C418556E9DC5FEF6B92A2553F51D6BBAB1DFE8968E63AF046527E920D40",
        "sizeBytes": 5_919_929,
    },
    {
        "id": "half-ge256",
        "fileName": "LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-half-ge256.zip",
        "sha256": "CAA755B12CA9D716E31C90ED6AECEE2163D0638FA67133D1EF841FE20C104C4A",
        "sizeBytes": 5_678_673,
    },
    {
        "id": "cap128",
        "fileName": "LunarLabs-26.2-Quest-Vulkan-v2.quest-lite-cap128.zip",
        "sha256": "48B33A0061B320FBD5A587D371CAE872ECF937D0949E6D7632015351B48DE05D",
        "sizeBytes": 5_608_066,
    },
)

OBSERVED_CONTRACTS = {
    "baseline": {"spriteEntries": 1279, "width": 2048, "height": 2048, "mipLevel": 4},
    "original": {"spriteEntries": 2006, "width": 8192, "height": 4096, "mipLevel": 4},
}

RESOURCE_NAMESPACE = re.compile(r"^[a-z0-9_.-]+$")
RESOURCE_PATH = re.compile(r"^[a-z0-9_./-]+$")
# Sprite-source filters are Java regular expressions.  Model only strings that
# have no regex metacharacters; anything richer must fail closed rather than be
# silently treated as an equality test.
LITERAL_FILTER = re.compile(r"^[a-z0-9_/-]+$")


class PredictionError(RuntimeError):
    """A fail-closed validation error."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PredictionError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def canonical_path(path: Path) -> str:
    return os.path.normcase(os.path.abspath(os.fspath(path)))


def assert_no_reparse_path(path: Path, label: str) -> None:
    """Reject symlinks/junctions in every existing path component."""

    absolute = Path(os.path.abspath(os.fspath(path)))
    parts = absolute.parts
    require(bool(parts), f"{label} has no filesystem root")
    current = Path(parts[0])
    for part in parts[1:]:
        current /= part
        if not os.path.lexists(current):
            break
        info = os.lstat(current)
        attributes = int(getattr(info, "st_file_attributes", 0))
        if stat.S_ISLNK(info.st_mode) or attributes & FILE_ATTRIBUTE_REPARSE_POINT:
            raise PredictionError(f"{label} traverses a reparse point: {current}")


def assert_input_file(path: Path, label: str) -> Path:
    path = Path(os.path.abspath(os.fspath(path)))
    assert_no_reparse_path(path, label)
    require(path.is_file(), f"{label} is not a regular file: {path}")
    return path


def paths_alias(left: Path, right: Path) -> bool:
    if canonical_path(left) == canonical_path(right):
        return True
    if os.path.exists(left) and os.path.exists(right):
        try:
            return os.path.samefile(left, right)
        except OSError as exc:
            raise PredictionError(f"cannot compare file identity: {exc}") from exc
    return False


def strict_json(data: bytes, label: str) -> Any:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        output: dict[str, Any] = {}
        for key, value in pairs:
            if key in output:
                raise PredictionError(f"duplicate JSON key {key!r}: {label}")
            output[key] = value
        return output

    def reject_constant(value: str) -> None:
        raise PredictionError(f"non-finite JSON number {value!r}: {label}")

    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=object_pairs,
            parse_constant=reject_constant,
        )
    except PredictionError:
        raise
    except Exception as exc:
        raise PredictionError(f"invalid UTF-8 JSON {label}: {exc}") from exc


def safe_zip_name(name: str) -> str:
    require("\\" not in name and "\x00" not in name, f"unsafe ZIP member name: {name!r}")
    path = PurePosixPath(name)
    require(not path.is_absolute(), f"absolute ZIP member name: {name!r}")
    require(all(part not in ("", ".", "..") for part in path.parts),
            f"traversal ZIP member name: {name!r}")
    require(not re.match(r"^[A-Za-z]:", name), f"drive-qualified ZIP member name: {name!r}")
    return name


class SafeZip:
    def __init__(self, path: Path, label: str):
        self.path = assert_input_file(path, label)
        try:
            self.archive = zipfile.ZipFile(self.path, "r")
        except Exception as exc:
            raise PredictionError(f"invalid ZIP {label}: {exc}") from exc
        try:
            self.members: dict[str, zipfile.ZipInfo] = {}
            total = 0
            folded: set[str] = set()
            infos = self.archive.infolist()
            require(len(infos) <= MAX_ZIP_ENTRIES, f"too many ZIP entries in {label}")
            for info in infos:
                name = safe_zip_name(info.filename)
                require(name not in self.members, f"duplicate ZIP member: {name}")
                folded_name = name.casefold()
                require(folded_name not in folded, f"case-colliding ZIP member: {name}")
                folded.add(folded_name)
                require(not (info.flag_bits & 1), f"encrypted ZIP member: {name}")
                require(info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                        f"unsupported ZIP compression for {name}")
                unix_mode = (info.external_attr >> 16) & 0xFFFF
                require(not stat.S_ISLNK(unix_mode), f"symlink ZIP member: {name}")
                require(0 <= info.file_size <= MAX_ZIP_MEMBER_BYTES,
                        f"oversized ZIP member: {name}")
                total += info.file_size
                require(total <= MAX_ZIP_TOTAL_BYTES, "ZIP uncompressed-size limit exceeded")
                self.members[name] = info
            self._cache: dict[str, bytes] = {}
        except Exception:
            self.archive.close()
            raise

    def read(self, name: str) -> bytes:
        if name in self._cache:
            return self._cache[name]
        info = self.members.get(name)
        if info is None or info.is_dir():
            raise PredictionError(f"missing ZIP member {name}: {self.path.name}")
        try:
            data = self.archive.read(info)
        except Exception as exc:
            raise PredictionError(f"ZIP CRC/decode failure for {name}: {exc}") from exc
        require(len(data) == info.file_size, f"short ZIP member read: {name}")
        self._cache[name] = data
        return data

    def close(self) -> None:
        self.archive.close()

    def __enter__(self) -> "SafeZip":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


@dataclass(frozen=True)
class ResourceRef:
    archive: SafeZip
    member: str
    layer_id: str


@dataclass(frozen=True)
class ResourceLayer:
    archive: SafeZip
    prefix: str
    layer_id: str

    def logical_members(self) -> Iterable[tuple[str, ResourceRef]]:
        root = self.prefix + "assets/"
        for member in sorted(self.archive.members):
            info = self.archive.members[member]
            if not info.is_dir() and member.startswith(root):
                logical = member[len(self.prefix):]
                yield logical, ResourceRef(self.archive, member, self.layer_id)

    def get(self, logical_name: str) -> ResourceRef | None:
        member = self.prefix + logical_name
        info = self.archive.members.get(member)
        if info is None or info.is_dir():
            return None
        return ResourceRef(self.archive, member, self.layer_id)


def positive_int(value: Any, label: str) -> int:
    require(isinstance(value, int) and not isinstance(value, bool) and value > 0,
            f"{label} must be a positive integer")
    return value


def pack_layers(archive: SafeZip, layer_prefix: str) -> list[ResourceLayer]:
    layers = [ResourceLayer(archive, "", f"{layer_prefix}:base")]
    pack_info = archive.members.get("pack.mcmeta")
    if pack_info is None:
        return layers
    metadata = strict_json(archive.read("pack.mcmeta"), f"{archive.path.name}:pack.mcmeta")
    require(isinstance(metadata, dict), "pack.mcmeta root must be an object")
    require("filter" not in metadata,
            "resource-pack filters are unsupported by this predictor and must fail closed")
    overlays = metadata.get("overlays", {})
    require(isinstance(overlays, dict), "overlays must be an object")
    entries = overlays.get("entries", [])
    require(isinstance(entries, list), "overlays.entries must be an array")
    for index, entry in enumerate(entries):
        require(isinstance(entry, dict), f"overlay {index} must be an object")
        directory = entry.get("directory")
        require(isinstance(directory, str) and directory and "/" not in directory
                and "\\" not in directory and directory not in (".", ".."),
                f"invalid overlay directory at index {index}")
        minimum = entry.get("min_format")
        maximum = entry.get("max_format")
        formats = entry.get("formats")
        if minimum is None or maximum is None:
            require(isinstance(formats, list) and len(formats) == 2,
                    f"overlay {index} lacks an explicit format interval")
            minimum, maximum = formats
        minimum = positive_int(minimum, f"overlay {index} min_format")
        maximum = positive_int(maximum, f"overlay {index} max_format")
        require(minimum <= maximum, f"overlay {index} has an inverted format interval")
        if minimum <= PACK_FORMAT <= maximum:
            require(directory.rstrip("/") + "/" + BLOCKS_ATLAS not in archive.members,
                    "an active overlay replaces blocks.json within its composite pack; "
                    "this uncommon case is unsupported and must fail closed")
            layers.append(ResourceLayer(
                archive,
                directory.rstrip("/") + "/",
                f"{layer_prefix}:overlay:{index}:{directory}",
            ))
    return layers


def resource_id(value: Any, label: str) -> tuple[str, str]:
    require(isinstance(value, str) and value, f"{label} must be a resource identifier")
    if ":" in value:
        namespace, path = value.split(":", 1)
    else:
        namespace, path = "minecraft", value
    require(bool(RESOURCE_NAMESPACE.fullmatch(namespace)), f"invalid namespace in {label}: {value}")
    require(bool(RESOURCE_PATH.fullmatch(path)) and not path.startswith("/")
            and "//" not in path and all(piece not in (".", "..") for piece in path.split("/")),
            f"invalid resource path in {label}: {value}")
    return namespace, path


def png_info(data: bytes, label: str) -> tuple[int, int]:
    require(data.startswith(PNG_SIGNATURE), f"invalid PNG signature: {label}")
    offset = len(PNG_SIGNATURE)
    chunks: list[tuple[bytes, bytes]] = []
    saw_iend = False
    while offset < len(data):
        require(offset + 12 <= len(data), f"truncated PNG chunk: {label}")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        require(length <= MAX_PNG_DECODED_BYTES, f"oversized PNG chunk: {label}")
        end = offset + 12 + length
        require(end <= len(data), f"truncated PNG payload: {label}")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length:end])[0]
        actual_crc = zlib.crc32(kind)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        require(actual_crc == expected_crc, f"PNG CRC mismatch in {label}: {kind!r}")
        chunks.append((kind, payload))
        offset = end
        if kind == b"IEND":
            saw_iend = True
            break
    require(saw_iend and offset == len(data), f"missing IEND or trailing PNG bytes: {label}")
    require(chunks and chunks[0][0] == b"IHDR" and len(chunks[0][1]) == 13,
            f"invalid PNG IHDR: {label}")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", chunks[0][1]
    )
    require(0 < width <= MAX_TEXTURE_SIZE and 0 < height <= MAX_PNG_DECODED_BYTES,
            f"invalid PNG dimensions {width}x{height}: {label}")
    valid_depths = {
        0: {1, 2, 4, 8, 16},
        2: {8, 16},
        3: {1, 2, 4, 8},
        4: {8, 16},
        6: {8, 16},
    }
    require(color_type in valid_depths and bit_depth in valid_depths[color_type],
            f"unsupported PNG color format: {label}")
    require(compression == 0 and filtering == 0 and interlace == 0,
            f"unsupported PNG compression/filter/interlace: {label}")
    require(sum(kind == b"IHDR" for kind, _ in chunks) == 1,
            f"duplicate PNG IHDR: {label}")
    require(chunks[-1] == (b"IEND", b""), f"invalid PNG IEND: {label}")
    if color_type == 3:
        require(any(kind == b"PLTE" for kind, _ in chunks), f"indexed PNG lacks PLTE: {label}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    scanline_bytes = (width * channels * bit_depth + 7) // 8
    expected_decoded = height * (scanline_bytes + 1)
    require(expected_decoded <= MAX_PNG_DECODED_BYTES,
            f"PNG decoded-size limit exceeded: {label}")
    compressed = b"".join(payload for kind, payload in chunks if kind == b"IDAT")
    require(bool(compressed), f"PNG lacks IDAT: {label}")
    try:
        decoder = zlib.decompressobj()
        decoded = decoder.decompress(compressed, expected_decoded + 1)
    except zlib.error as exc:
        raise PredictionError(f"PNG zlib decode failure in {label}: {exc}") from exc
    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail,
            f"incomplete or concatenated PNG zlib stream: {label}")
    require(len(decoded) == expected_decoded,
            f"PNG scanline size mismatch in {label}: {len(decoded)} != {expected_decoded}")
    require(all(decoded[row * (scanline_bytes + 1)] <= 4 for row in range(height)),
            f"invalid PNG scanline filter byte: {label}")
    return width, height


@dataclass(frozen=True)
class Sprite:
    name: str
    width: int
    height: int
    physical_width: int
    physical_height: int
    animated: bool
    unique_frames: int


def sprite_from_resource(name: str, ref: ResourceRef, logical_name: str,
                         resources: dict[str, ResourceRef]) -> Sprite:
    data = ref.archive.read(ref.member)
    image_width, image_height = png_info(data, f"{ref.archive.path.name}:{ref.member}")
    metadata = resources.get(logical_name + ".mcmeta")
    if metadata is None:
        return Sprite(name, image_width, image_height, image_width, image_height, False, 0)
    root = strict_json(metadata.archive.read(metadata.member),
                       f"{metadata.archive.path.name}:{metadata.member}")
    require(isinstance(root, dict), f"mcmeta root must be an object: {metadata.member}")
    animation = root.get("animation")
    if animation is None:
        return Sprite(name, image_width, image_height, image_width, image_height, False, 0)
    require(isinstance(animation, dict), f"animation must be an object: {metadata.member}")
    width_value = animation.get("width")
    height_value = animation.get("height")
    if width_value is None and height_value is None:
        frame_width = frame_height = min(image_width, image_height)
    elif width_value is None:
        frame_width = image_width
        frame_height = positive_int(height_value, f"{metadata.member} animation.height")
    elif height_value is None:
        frame_width = positive_int(width_value, f"{metadata.member} animation.width")
        frame_height = image_height
    else:
        frame_width = positive_int(width_value, f"{metadata.member} animation.width")
        frame_height = positive_int(height_value, f"{metadata.member} animation.height")
    require(image_width % frame_width == 0 and image_height % frame_height == 0,
            f"animation geometry does not tile image: {metadata.member}")
    columns = image_width // frame_width
    rows = image_height // frame_height
    physical_frames = columns * rows
    default_time = positive_int(animation.get("frametime", 1),
                                f"{metadata.member} animation.frametime")
    del default_time
    frames_value = animation.get("frames")
    frame_indices: list[int] = []
    if frames_value is None:
        frame_indices = list(range(physical_frames))
    else:
        require(isinstance(frames_value, list), f"animation.frames must be an array: {metadata.member}")
        for frame_number, frame in enumerate(frames_value):
            if isinstance(frame, int) and not isinstance(frame, bool):
                index = frame
            else:
                require(isinstance(frame, dict),
                        f"invalid animation frame {frame_number}: {metadata.member}")
                require(set(frame).issubset({"index", "time"}) and "index" in frame,
                        f"unsupported animation frame fields: {metadata.member}")
                index = frame["index"]
                require(isinstance(index, int) and not isinstance(index, bool),
                        f"invalid animation frame index: {metadata.member}")
                if "time" in frame:
                    positive_int(frame["time"], f"{metadata.member} frame time")
            require(0 <= index < physical_frames,
                    f"animation frame index out of bounds: {metadata.member}")
            frame_indices.append(index)
    # SpriteContents returns null AnimatedTexture when <=1 valid frame.
    animated = len(frame_indices) > 1
    unique_frames = len(dict.fromkeys(frame_indices)) if animated else 0
    return Sprite(name, frame_width, frame_height, image_width, image_height,
                  animated, unique_frames)


def logical_resource_map(layers: list[ResourceLayer]) -> dict[str, ResourceRef]:
    resources: dict[str, ResourceRef] = {}
    for layer in layers:
        for logical, ref in layer.logical_members():
            resources[logical] = ref
    return resources


def atlas_sources(layers: list[ResourceLayer]) -> tuple[list[dict[str, Any]], str]:
    sources: list[dict[str, Any]] = []
    canonical_fragments: list[bytes] = []
    for layer in layers:
        ref = layer.get(BLOCKS_ATLAS)
        if ref is None:
            continue
        root = strict_json(ref.archive.read(ref.member), f"{ref.archive.path.name}:{ref.member}")
        require(isinstance(root, dict) and set(root) == {"sources"},
                f"blocks atlas must contain only sources: {ref.member}")
        value = root["sources"]
        require(isinstance(value, list), f"atlas sources must be an array: {ref.member}")
        for item in value:
            require(isinstance(item, dict), f"atlas source must be an object: {ref.member}")
            sources.append(item)
        canonical_fragments.append(json.dumps(root, sort_keys=True, separators=(",", ":")).encode())
    require(bool(sources), "no blocks-atlas sources were found")
    return sources, sha256_bytes(b"\n".join(canonical_fragments))


def select_sprites(sources: list[dict[str, Any]],
                   resources: dict[str, ResourceRef]) -> tuple[dict[str, ResourceRef], dict[str, int]]:
    selected: dict[str, ResourceRef] = {}
    counts: Counter[str] = Counter()
    for source_number, source in enumerate(sources):
        source_type = source.get("type")
        require(isinstance(source_type, str), f"atlas source {source_number} has no type")
        require(source_type in ("directory", "single", "filter",
                                "minecraft:directory", "minecraft:single",
                                "minecraft:filter"),
                f"unregistered atlas source type must fail closed: {source_type}")
        short_type = source_type.split(":", 1)[-1]
        counts[short_type] += 1
        if short_type == "directory":
            require(set(source) == {"type", "source", "prefix"},
                    f"unsupported directory-source fields at {source_number}")
            source_path = source["source"]
            id_prefix = source["prefix"]
            require(isinstance(source_path, str) and isinstance(id_prefix, str),
                    f"invalid directory source at {source_number}")
            resource_id("minecraft:" + source_path, f"directory source {source_number}")
            resource_id("minecraft:" + (id_prefix or "placeholder"),
                        f"directory prefix {source_number}")
            base = "textures/" + source_path.strip("/") + "/"
            for logical_name in sorted(resources):
                match = re.fullmatch(r"assets/([^/]+)/" + re.escape(base) + r"(.+)\.png",
                                     logical_name)
                if match:
                    sprite = f"{match.group(1)}:{id_prefix}{match.group(2)}"
                    resource_id(sprite, f"directory sprite {source_number}")
                    selected[sprite] = resources[logical_name]
        elif short_type == "single":
            require(set(source).issubset({"type", "resource", "sprite"})
                    and set(source).issuperset({"type", "resource"}),
                    f"unsupported single-source fields at {source_number}")
            namespace, path = resource_id(source["resource"], f"single source {source_number}")
            logical_name = f"assets/{namespace}/textures/{path}.png"
            ref = resources.get(logical_name)
            if ref is not None:
                sprite_value = source.get("sprite", source["resource"])
                sprite_namespace, sprite_path = resource_id(
                    sprite_value, f"single sprite {source_number}"
                )
                selected[f"{sprite_namespace}:{sprite_path}"] = ref
        else:
            require(set(source) == {"type", "pattern"},
                    f"unsupported filter-source fields at {source_number}")
            pattern = source["pattern"]
            require(isinstance(pattern, dict) and set(pattern).issubset({"namespace", "path"}),
                    f"invalid filter pattern at {source_number}")
            namespace_pattern = pattern.get("namespace", None)
            path_pattern = pattern.get("path", None)
            for value, part in ((namespace_pattern, "namespace"), (path_pattern, "path")):
                if value is not None:
                    require(isinstance(value, str) and bool(LITERAL_FILTER.fullmatch(value)),
                            f"non-literal Java regex {part} is unsupported at source {source_number}")
            for sprite in list(selected):
                namespace, path = sprite.split(":", 1)
                if ((namespace_pattern is None or namespace == namespace_pattern)
                        and (path_pattern is None or path == path_pattern)):
                    del selected[sprite]
    return selected, dict(sorted(counts.items()))


class Region:
    __slots__ = ("width", "height", "children", "occupied")

    def __init__(self, width: int, height: int):
        self.width = width
        self.height = height
        self.children: list[Region] | None = None
        self.occupied = False

    def add(self, width: int, height: int) -> bool:
        if self.occupied or width > self.width or height > self.height:
            return False
        if width == self.width and height == self.height:
            self.occupied = True
            return True
        if self.children is None:
            self.children = [Region(width, height)]
            remaining_width = self.width - width
            remaining_height = self.height - height
            if remaining_height > 0 and remaining_width > 0:
                if max(self.height, remaining_width) >= max(self.width, remaining_height):
                    self.children.extend((Region(width, remaining_height),
                                          Region(remaining_width, self.height)))
                else:
                    self.children.extend((Region(remaining_width, height),
                                          Region(self.width, remaining_height)))
            elif remaining_width == 0:
                self.children.append(Region(width, remaining_height))
            elif remaining_height == 0:
                self.children.append(Region(remaining_width, height))
        return any(child.add(width, height) for child in self.children)


def power_of_two(value: int) -> int:
    return 1 if value <= 1 else 1 << (value - 1).bit_length()


def mip_bytes(width: int, height: int, mip_level: int) -> int:
    return sum(max(1, width >> level) * max(1, height >> level) * 4
               for level in range(mip_level + 1))


def sprite_loader_mip_level(sprites: list[Sprite]) -> int:
    require(bool(sprites), "cannot stitch an empty sprite set")
    minimum_dimension = min(min(sprite.width, sprite.height) for sprite in sprites)
    minimum_low_bit = min(min(sprite.width & -sprite.width,
                              sprite.height & -sprite.height) for sprite in sprites)
    return min(REQUESTED_MIP_LEVEL,
               int(math.log2(min(minimum_dimension, minimum_low_bit))))


def stitch(sprites: list[Sprite], mip_level: int) -> dict[str, int]:
    require(bool(sprites), "cannot stitch an empty sprite set")
    require(0 <= mip_level <= REQUESTED_MIP_LEVEL, "invalid Stitcher mip level")
    padding_shift = max(0, min(4, MAX_ANISOTROPY_BIT - 1))
    padding = (1 << mip_level) << padding_shift
    quantum = 1 << mip_level

    def align(value: int) -> int:
        return ((value + quantum - 1) // quantum) * quantum

    holders = [(align(sprite.width + 2 * padding),
                align(sprite.height + 2 * padding), sprite.name) for sprite in sprites]
    holders.sort(key=lambda item: (-item[1], -item[0], item[2]))
    regions: list[Region] = []
    storage_width = 0
    storage_height = 0
    for width, height, name in holders:
        if any(region.add(width, height) for region in regions):
            continue
        previous_width = power_of_two(storage_width)
        previous_height = power_of_two(storage_height)
        next_width = power_of_two(storage_width + width)
        next_height = power_of_two(storage_height + height)
        can_grow_width = next_width <= MAX_TEXTURE_SIZE
        can_grow_height = next_height <= MAX_TEXTURE_SIZE
        require(can_grow_width or can_grow_height,
                f"sprite {name} does not fit within {MAX_TEXTURE_SIZE}x{MAX_TEXTURE_SIZE}")
        changes_width = can_grow_width and previous_width != next_width
        changes_height = can_grow_height and previous_height != next_height
        if changes_width != changes_height:
            grow_width = changes_width
        else:
            grow_width = can_grow_width and previous_width <= previous_height
        if grow_width:
            if storage_height == 0:
                storage_height = next_height
            region = Region(next_width - storage_width, storage_height)
            storage_width = next_width
        else:
            region = Region(storage_width, next_height - storage_height)
            storage_height = next_height
        require(region.add(width, height), f"internal stitcher expansion failure: {name}")
        regions.append(region)
    padded_area = sum(width * height for width, height, _ in holders)
    atlas_area = storage_width * storage_height
    return {
        "width": storage_width,
        "height": storage_height,
        "mipLevel": mip_level,
        "paddingPixelsPerSide": padding,
        "paddedSpriteAreaPixels": padded_area,
        "atlasAreaPixels": atlas_area,
        "atlasRgba8MipTexelBytes": mip_bytes(storage_width, storage_height, mip_level),
    }


def analyse_case(case_id: str, client_path: Path,
                 pack_path: Path | None, pack_sha: str | None) -> dict[str, Any]:
    with SafeZip(client_path, "Minecraft client JAR") as client:
        archives: list[SafeZip] = []
        try:
            layers = [ResourceLayer(client, "", "minecraft-client:base")]
            if pack_path is not None:
                pack = SafeZip(pack_path, f"{case_id} resource pack")
                archives.append(pack)
                layers.extend(pack_layers(pack, case_id))
            resources = logical_resource_map(layers)
            sources, source_digest = atlas_sources(layers)
            selected, source_counts = select_sprites(sources, resources)
            logical_by_ref = {ref: logical_name for logical_name, ref in resources.items()}
            sprites = [Sprite(MISSING_SPRITE, 16, 16, 16, 16, False, 0)]
            sprite_resources = {MISSING_SPRITE: "<generated>"}
            for name in sorted(selected):
                ref = selected[name]
                logical_name = logical_by_ref.get(ref)
                require(logical_name is not None,
                        f"selected resource is absent from logical map: {ref.member}")
                sprites.append(sprite_from_resource(name, ref, logical_name, resources))
                sprite_resources[name] = logical_name
            effective_mip = sprite_loader_mip_level(sprites)
            requested_mip_atlas = stitch(sprites, REQUESTED_MIP_LEVEL)
            adjusted_atlas = stitch(sprites, effective_mip)
            animated = [sprite for sprite in sprites if sprite.animated]
            requested_animation_bytes = sum(
                sprite.unique_frames * mip_bytes(sprite.width, sprite.height, REQUESTED_MIP_LEVEL)
                for sprite in animated
            )
            adjusted_animation_bytes = sum(
                sprite.unique_frames * mip_bytes(sprite.width, sprite.height, effective_mip)
                for sprite in animated
            )
            individual_mip_levels = {
                sprite.name: min(
                    REQUESTED_MIP_LEVEL,
                    int(math.log2(min(
                        sprite.width,
                        sprite.height,
                        sprite.width & -sprite.width,
                        sprite.height & -sprite.height,
                    ))),
                )
                for sprite in sprites
            }
            limiting_names = sorted(
                name for name, value in individual_mip_levels.items()
                if value == effective_mip
            ) if effective_mip != REQUESTED_MIP_LEVEL else []
            sprite_by_name = {sprite.name: sprite for sprite in sprites}
            minimum_frame_dimension = min(
                min(sprite.width, sprite.height) for sprite in sprites
            )
            minimum_lowest_one_bit = min(
                min(sprite.width & -sprite.width, sprite.height & -sprite.height)
                for sprite in sprites
            )
            mip_limiting_value = min(minimum_frame_dimension, minimum_lowest_one_bit)
            if minimum_frame_dimension == minimum_lowest_one_bit:
                mip_limiting_factor = "FRAME_DIMENSION_AND_LOWEST_ONE_BIT"
            elif minimum_frame_dimension < minimum_lowest_one_bit:
                mip_limiting_factor = "FRAME_DIMENSION"
            else:
                mip_limiting_factor = "LOWEST_ONE_BIT"
            limiter_details = [
                {
                    "sprite": name,
                    "logicalTexturePath": sprite_resources[name],
                    "frameWidth": sprite_by_name[name].width,
                    "frameHeight": sprite_by_name[name].height,
                    "minimumLowestOneBit": min(
                        sprite_by_name[name].width & -sprite_by_name[name].width,
                        sprite_by_name[name].height & -sprite_by_name[name].height,
                    ),
                    "individualMipLimit": individual_mip_levels[name],
                }
                for name in limiting_names[:20]
            ]
            sprite_table = "".join(
                f"{sprite.name}\t{sprite.width}\t{sprite.height}\t"
                f"{sprite.physical_width}\t{sprite.physical_height}\t"
                f"{int(sprite.animated)}\t{sprite.unique_frames}\n"
                for sprite in sorted(sprites, key=lambda item: item.name)
            ).encode("utf-8")
            limiter_digest_payload = (
                ("\n".join(limiting_names) + "\n").encode("utf-8")
                if limiting_names else b""
            )
            result: dict[str, Any] = {
                "id": case_id,
                "input": {
                    "pack": None if pack_path is None else {
                        "fileName": pack_path.name,
                        "sha256": pack_sha,
                        "sizeBytes": pack_path.stat().st_size,
                    },
                },
                "sources": {
                    "countsByType": source_counts,
                    "definitionSha256": source_digest,
                    "total": len(sources),
                },
                "sprites": {
                    "entriesIncludingMissing": len(sprites),
                    "entriesWithoutMissing": len(sprites) - 1,
                    "tableSha256": sha256_bytes(sprite_table),
                },
                "atlas": {
                    "requestedMipStitcher": requested_mip_atlas,
                    "spriteLoaderAdjustedStitcher": adjusted_atlas,
                    "effectiveMipWasReduced": effective_mip != REQUESTED_MIP_LEVEL,
                    "spriteLoaderMipDecision": {
                        "requestedMipLevel": REQUESTED_MIP_LEVEL,
                        "minimumFrameDimension": minimum_frame_dimension,
                        "minimumLowestOneBitAcrossFrameDimensions": minimum_lowest_one_bit,
                        "limitingFactor": mip_limiting_factor,
                        "limitingValue": mip_limiting_value,
                        "effectiveMipLevel": effective_mip,
                        "algorithm": (
                            "min(requested, floor(log2(min(minFrameDimension, "
                            "minLowestOneBit))))"
                        ),
                    },
                    "mipLimiters": {
                        "count": len(limiting_names),
                        "first20": limiter_details,
                        "allNamesSha256": sha256_bytes(limiter_digest_payload),
                    },
                },
                "animationFrameTextures": {
                    "animatedSprites": len(animated),
                    "uniqueFrameTextures": sum(sprite.unique_frames for sprite in animated),
                    "requestedMipRgba8TexelBytes": requested_animation_bytes,
                    "spriteLoaderAdjustedRgba8MipTexelBytes": adjusted_animation_bytes,
                    "boundKind": (
                        "exact-rgba8-texel-bytes-for-pinned-inputs; "
                        "lower-bound-for-driver-allocation"
                    ),
                    "separateFromAtlasAllocation": True,
                },
                "modeledRgba8TexelBytes": {
                    "requestedMipStitcher": (
                        requested_mip_atlas["atlasRgba8MipTexelBytes"]
                        + requested_animation_bytes
                    ),
                    "spriteLoaderAdjusted": (
                        adjusted_atlas["atlasRgba8MipTexelBytes"] + adjusted_animation_bytes
                    ),
                },
            }
            observed = OBSERVED_CONTRACTS.get(case_id)
            if observed is not None:
                actual = {
                    "spriteEntries": len(sprites),
                    "width": adjusted_atlas["width"],
                    "height": adjusted_atlas["height"],
                    "mipLevel": adjusted_atlas["mipLevel"],
                }
                require(actual == observed,
                        f"{case_id} simulation does not match observed runtime contract: "
                        f"{actual} != {observed}")
                result["observedRuntimeContract"] = {
                    **observed,
                    "matched": True,
                }
            else:
                result["status"] = "HOST_PREDICTION_REQUIRES_QUEST_RUNTIME_AB"
            if effective_mip != REQUESTED_MIP_LEVEL:
                first_limiter = limiter_details[0]
                prefix = "MIP_0_REJECT: " if effective_mip == 0 else "MIP_REDUCTION: "
                result["mipReductionWarning"] = (
                    f"{prefix}SpriteLoader would lower the atlas mip level from "
                    f"{REQUESTED_MIP_LEVEL} to {effective_mip}; limiting factor "
                    f"{mip_limiting_factor}={mip_limiting_value}, including "
                    f"{first_limiter['logicalTexturePath']} "
                    f"({first_limiter['frameWidth']}x{first_limiter['frameHeight']}). "
                    "This can change packing, texture quality, and modeled cost. "
                    "Do not accept this pack without confirming the actual Quest atlas "
                    "log and controlled runtime A/B."
                )
            return result
        finally:
            for archive in reversed(archives):
                archive.close()


def validate_contract_file(path: Path, contract: dict[str, Any], label: str) -> Path:
    path = assert_input_file(path, label)
    require(path.name == contract["fileName"],
            f"{label} filename mismatch: {path.name} != {contract['fileName']}")
    if "sizeBytes" in contract:
        require(path.stat().st_size == contract["sizeBytes"],
                f"{label} size mismatch")
    actual_hash = sha256_file(path)
    require(actual_hash == contract["sha256"],
            f"{label} SHA-256 mismatch: {actual_hash} != {contract['sha256']}")
    return path


def report_bytes(client_path: Path, original_pack: Path, lite_dir: Path) -> bytes:
    client_path = validate_contract_file(client_path, CLIENT_CONTRACT, "Minecraft client JAR")
    pack_paths: dict[str, Path] = {}
    for contract in PACK_CONTRACTS:
        base = original_pack if contract["id"] == "original" else lite_dir / contract["fileName"]
        pack_paths[contract["id"]] = validate_contract_file(
            base, contract, f"{contract['id']} resource pack"
        )
    cases = [analyse_case("baseline", client_path, None, None)]
    for contract in PACK_CONTRACTS:
        cases.append(analyse_case(
            contract["id"], client_path,
            pack_paths[contract["id"]], contract["sha256"],
        ))
    original = next(case for case in cases if case["id"] == "original")
    for case in cases:
        if case["id"] in ("baseline", "original"):
            continue
        comparisons: dict[str, Any] = {}
        for mode, atlas_key, animation_key, total_key in (
            ("requestedMipStitcher", "requestedMipStitcher",
             "requestedMipRgba8TexelBytes", "requestedMipStitcher"),
            ("spriteLoaderAdjusted", "spriteLoaderAdjustedStitcher",
             "spriteLoaderAdjustedRgba8MipTexelBytes", "spriteLoaderAdjusted"),
        ):
            comparisons[mode] = {
                "atlasRgba8MipTexelBytesSaved": (
                    original["atlas"][atlas_key]["atlasRgba8MipTexelBytes"]
                    - case["atlas"][atlas_key]["atlasRgba8MipTexelBytes"]
                ),
                "animationFrameRgba8MipTexelBytesSaved": (
                    original["animationFrameTextures"][animation_key]
                    - case["animationFrameTextures"][animation_key]
                ),
                "modeledRgba8TexelBytesSaved": (
                    original["modeledRgba8TexelBytes"][total_key]
                    - case["modeledRgba8TexelBytes"][total_key]
                ),
            }
        case["comparisonToOriginal"] = comparisons
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "scope": "HOST_ONLY_PREDICTION",
        "runtimeClaim": False,
        "minecraftClient": {
            "fileName": client_path.name,
            "minecraftVersion": MINECRAFT_VERSION,
            "sha256": CLIENT_CONTRACT["sha256"],
            "sizeBytes": client_path.stat().st_size,
        },
        "simulator": {
            "atlas": "minecraft:textures/atlas/blocks.png-atlas",
            "maxTextureSize": MAX_TEXTURE_SIZE,
            "requestedMipLevel": REQUESTED_MIP_LEVEL,
            "maxAnisotropyBit": MAX_ANISOTROPY_BIT,
            "resourceSemantics": "SpriteSourceList: directory/single/literal-filter; pack-format-88 overlays",
            "packingSemantics": "Minecraft 26.2 Stitcher comparator/expand/Region algorithm",
            "mipSelectionSemantics": (
                "Both direct requested-mip Stitcher and SpriteLoader lowestOneBit-adjusted "
                "Stitcher are reported"
            ),
            "pngValidation": "chunk CRC + zlib decode + scanline/filter validation",
            "animationSemantics": (
                "SpriteContents unique valid frames; one RGBA8 texture per unique frame with all atlas mips"
            ),
        },
        "observedRuntimeEvidence": {
            "baseline": OBSERVED_CONTRACTS["baseline"],
            "original": OBSERVED_CONTRACTS["original"],
            "bothMatchedExactly": True,
        },
        "cases": cases,
        "interpretation": {
            "atlasAndAnimationBytesAreRgba8TexelMathNotDriverGraphicsOrPss": True,
            "liteResultsNeedQuestRuntimeAB": True,
            "noFpsOrRuntimeMemorySavingsClaimed": True,
        },
    }
    return (json.dumps(report, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8")


def output_path() -> Path:
    repo_root = Path(__file__).resolve().parent.parent
    return repo_root / "exports" / "lunarlabs-quest-lite-stitcher" / REPORT_FILE_NAME


def atomic_write(path: Path, data: bytes, inputs: Iterable[Path]) -> None:
    path = Path(os.path.abspath(os.fspath(path)))
    assert_no_reparse_path(path, "report output")
    for input_path in inputs:
        require(not paths_alias(path, input_path), "report output aliases a pinned input")
    path.parent.mkdir(parents=True, exist_ok=True)
    assert_no_reparse_path(path.parent, "report output directory")
    if path.exists():
        assert_no_reparse_path(path, "existing report output")
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(prefix=".atlas-report-", suffix=".tmp",
                                                       dir=path.parent)
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        assert_no_reparse_path(temporary, "temporary report")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def verify_exact_report(path: Path, expected: bytes) -> None:
    path = assert_input_file(path, "prediction report")
    require(path.read_bytes() == expected,
            f"prediction report differs from deterministic reconstruction: {path}")


def run_production(args: argparse.Namespace, verify: bool) -> None:
    client = Path(args.client_jar)
    original = Path(args.original_pack)
    lite_dir = Path(args.lite_dir)
    assert_no_reparse_path(lite_dir, "Quest-Lite directory")
    require(lite_dir.is_dir(), f"Quest-Lite directory does not exist: {lite_dir}")
    expected = report_bytes(client, original, lite_dir)
    report = output_path()
    if verify:
        verify_exact_report(report, expected)
        action = "VERIFIED"
    else:
        inputs = [client, original] + [lite_dir / contract["fileName"]
                                      for contract in PACK_CONTRACTS if contract["id"] != "original"]
        atomic_write(report, expected, inputs)
        action = "WROTE"
    print(f"[MINECRAFT26_ATLAS_PREDICTOR] {action} {report}")
    print(f"[MINECRAFT26_ATLAS_PREDICTOR] SHA256 {sha256_bytes(expected)}")
    parsed = json.loads(expected)
    for case in parsed["cases"]:
        requested = case["atlas"]["requestedMipStitcher"]
        adjusted = case["atlas"]["spriteLoaderAdjustedStitcher"]
        print(f"[MINECRAFT26_ATLAS_PREDICTOR] {case['id']}: "
              f"{case['sprites']['entriesIncludingMissing']} entries => "
              f"requested {requested['width']}x{requested['height']}x{requested['mipLevel']}; "
              f"SpriteLoader-adjusted {adjusted['width']}x{adjusted['height']}x{adjusted['mipLevel']}")
    print("[MINECRAFT26_ATLAS_PREDICTOR] Lite results are Host predictions; Quest runtime A/B is still required.")


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    crc = zlib.crc32(kind)
    crc = zlib.crc32(payload, crc) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)


def fixture_png(width: int, height: int, seed: int = 1) -> bytes:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(((x + seed) & 255, (y + seed) & 255, (x ^ y ^ seed) & 255, 255))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return PNG_SIGNATURE + png_chunk(b"IHDR", ihdr) + png_chunk(
        b"IDAT", zlib.compress(bytes(rows), 9)
    ) + png_chunk(b"IEND", b"")


def fixture_zip(path: Path, members: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as archive:
        for name in sorted(members):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, members[name], compress_type=zipfile.ZIP_DEFLATED,
                             compresslevel=9)


def expect_failure(callable_: Any, description: str) -> None:
    try:
        callable_()
    except PredictionError:
        return
    raise AssertionError(f"negative self-test did not fail closed: {description}")


def run_selftest() -> None:
    assertions = 0
    with tempfile.TemporaryDirectory(prefix="minecraft26-atlas-selftest-") as temporary:
        root = Path(temporary)
        atlas = {"sources": [
            {"type": "directory", "source": "block", "prefix": "block/"},
            {"type": "single", "resource": "test:animated"},
        ]}
        animation = {"animation": {"frametime": 2, "frames": [0, 1, 0]}}
        client = root / "client.jar"
        fixture_zip(client, {
            BLOCKS_ATLAS: json.dumps(atlas, separators=(",", ":")).encode(),
            "assets/minecraft/textures/block/a.png": fixture_png(16, 16, 1),
            "assets/minecraft/textures/block/b.png": fixture_png(32, 32, 2),
            "assets/test/textures/animated.png": fixture_png(16, 32, 3),
            "assets/test/textures/animated.png.mcmeta":
                json.dumps(animation, separators=(",", ":")).encode(),
        })
        result = analyse_case("fixture", client, None, None)
        assert result["sprites"]["entriesIncludingMissing"] == 4
        assertions += 1
        adjusted = result["atlas"]["spriteLoaderAdjustedStitcher"]
        assert (adjusted["width"], adjusted["height"], adjusted["mipLevel"]) == (128, 128, 4)
        assertions += 1
        assert result["animationFrameTextures"]["uniqueFrameTextures"] == 2
        assertions += 1
        assert (result["animationFrameTextures"]["spriteLoaderAdjustedRgba8MipTexelBytes"]
                == 2 * mip_bytes(16, 16, 4))
        assertions += 1
        repeated_result = analyse_case("fixture", client, None, None)
        assert (json.dumps(result, sort_keys=True, separators=(",", ":"))
                == json.dumps(repeated_result, sort_keys=True, separators=(",", ":")))
        assertions += 1

        # Stitcher order must be independent of input list order.
        sprites = [
            Sprite("test:z", 16, 16, 16, 16, False, 0),
            Sprite("test:a", 32, 32, 32, 32, False, 0),
            Sprite(MISSING_SPRITE, 16, 16, 16, 16, False, 0),
        ]
        assert stitch(sprites, 4) == stitch(list(reversed(sprites)), 4)
        assertions += 1

        odd_sprite = Sprite("test:odd", 15, 15, 15, 15, False, 0)
        assert sprite_loader_mip_level([odd_sprite]) == 0
        assertions += 1
        assert stitch([odd_sprite], 4) != stitch([odd_sprite], 0)
        assertions += 1

        mip_zero = root / "mip-zero.jar"
        fixture_zip(mip_zero, {
            BLOCKS_ATLAS: json.dumps({"sources": [
                {"type": "single", "resource": "test:odd"}
            ]}).encode(),
            "assets/test/textures/odd.png": fixture_png(13, 128),
        })
        mip_zero_result = analyse_case("mip-zero", mip_zero, None, None)
        decision = mip_zero_result["atlas"]["spriteLoaderMipDecision"]
        assert decision["effectiveMipLevel"] == 0
        assertions += 1
        assert decision["limitingFactor"] == "LOWEST_ONE_BIT"
        assertions += 1
        assert (mip_zero_result["atlas"]["mipLimiters"]["first20"][0]
                ["logicalTexturePath"] == "assets/test/textures/odd.png")
        assertions += 1
        assert mip_zero_result["mipReductionWarning"].startswith("MIP_0_REJECT:")
        assertions += 1

        corrupt_crc = bytearray(fixture_png(16, 16, 4))
        corrupt_crc[25] ^= 1
        expect_failure(lambda: png_info(bytes(corrupt_crc), "bad-crc"), "PNG CRC")
        assertions += 1

        bad_zlib = (PNG_SIGNATURE +
                    png_chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0)) +
                    png_chunk(b"IDAT", b"not-a-zlib-stream") + png_chunk(b"IEND", b""))
        expect_failure(lambda: png_info(bad_zlib, "bad-zlib"), "PNG decode")
        assertions += 1

        traversal = root / "traversal.zip"
        fixture_zip(traversal, {"../escape": b"x"})
        expect_failure(lambda: SafeZip(traversal, "traversal"), "ZIP traversal")
        assertions += 1

        duplicate = root / "duplicate.zip"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(duplicate, "w") as archive:
                archive.writestr("same", b"one")
                archive.writestr("same", b"two")
        expect_failure(lambda: SafeZip(duplicate, "duplicate"), "duplicate ZIP member")
        assertions += 1

        corrupt_zip = root / "corrupt-entry.zip"
        fixture_zip(corrupt_zip, {"payload": b"zip-crc-must-fail"})
        with zipfile.ZipFile(corrupt_zip) as archive:
            info = archive.getinfo("payload")
            with corrupt_zip.open("r+b") as stream:
                stream.seek(info.header_offset + 26)
                name_length, extra_length = struct.unpack("<HH", stream.read(4))
                stream.seek(info.header_offset + 30 + name_length + extra_length
                            + info.compress_size // 2)
                byte = stream.read(1)
                stream.seek(-1, os.SEEK_CUR)
                stream.write(bytes((byte[0] ^ 1,)))
        def read_corrupt_zip() -> None:
            with SafeZip(corrupt_zip, "corrupt ZIP") as archive:
                archive.read("payload")
        expect_failure(read_corrupt_zip, "ZIP member CRC/decode")
        assertions += 1

        unsupported = root / "unsupported.jar"
        bad_atlas = {"sources": [{"type": "minecraft:unstitch", "resource": "test:x"}]}
        fixture_zip(unsupported, {
            BLOCKS_ATLAS: json.dumps(bad_atlas).encode(),
            "assets/test/textures/x.png": fixture_png(16, 16),
        })
        expect_failure(
            lambda: analyse_case("unsupported", unsupported, None, None),
            "unsupported atlas source",
        )
        assertions += 1

        expect_failure(
            lambda: select_sprites([{
                "type": "minecraft:filter",
                "pattern": {"path": "entity.anything"},
            }], {}),
            "regex filter treated as a literal",
        )
        assertions += 1
        expect_failure(
            lambda: select_sprites([{
                "type": "untrusted:directory", "source": "block", "prefix": "block/",
            }], {}),
            "unregistered source namespace",
        )
        assertions += 1

        overlay_atlas = root / "overlay-atlas.zip"
        fixture_zip(overlay_atlas, {
            "pack.mcmeta": json.dumps({
                "pack": {"pack_format": 88, "description": "fixture"},
                "overlays": {"entries": [{
                    "formats": [88, 88], "directory": "overlay"
                }]},
            }).encode(),
            "overlay/" + BLOCKS_ATLAS: json.dumps({"sources": []}).encode(),
        })
        def open_overlay_atlas() -> None:
            with SafeZip(overlay_atlas, "overlay atlas") as archive:
                pack_layers(archive, "fixture")
        expect_failure(open_overlay_atlas, "active overlay atlas replacement")
        assertions += 1

        invalid_animation = root / "invalid-animation.jar"
        fixture_zip(invalid_animation, {
            BLOCKS_ATLAS: json.dumps({"sources": [
                {"type": "single", "resource": "test:x"}
            ]}).encode(),
            "assets/test/textures/x.png": fixture_png(16, 32),
            "assets/test/textures/x.png.mcmeta": json.dumps({
                "animation": {"width": 15, "height": 16, "frames": [0, 1]}
            }).encode(),
        })
        expect_failure(
            lambda: analyse_case("invalid", invalid_animation, None, None),
            "invalid animation geometry",
        )
        assertions += 1

        expect_failure(
            lambda: validate_contract_file(client, CLIENT_CONTRACT, "wrong hash/name"),
            "input contract mismatch",
        )
        assertions += 1

        report = root / "report.json"
        data = (json.dumps(result, indent=2, sort_keys=True) + "\n").encode()
        atomic_write(report, data, [client])
        assert report.read_bytes() == data
        assertions += 1
        verify_exact_report(report, data)
        assertions += 1
        expect_failure(lambda: atomic_write(client, data, [client]), "output/input alias")
        assertions += 1
        hardlink = root / "hardlink-client.jar"
        os.link(client, hardlink)
        expect_failure(lambda: atomic_write(hardlink, data, [client]), "hard-link output alias")
        assertions += 1
        if os.name == "nt":
            assert paths_alias(report, Path(str(report).upper()))
            assertions += 1
        report.write_bytes(data + b" ")
        expect_failure(lambda: verify_exact_report(report, data), "tampered report")
        assertions += 1

        if os.name == "nt":
            junction_target = root / "junction-target"
            junction_path = root / "junction"
            junction_target.mkdir()
            # os.symlink may require Developer Mode; skip only when the OS
            # refuses creation, never when a created link evades detection.
            try:
                os.symlink(junction_target, junction_path, target_is_directory=True)
            except OSError:
                pass
            else:
                expect_failure(
                    lambda: atomic_write(junction_path / "blocked.json", b"{}\n", [client]),
                    "reparse-point output ancestor",
                )
                assertions += 1
                assert not (junction_target / "blocked.json").exists()
                assertions += 1

    print(f"[MINECRAFT26_ATLAS_PREDICTOR_SELFTEST] PASS ({assertions} assertions)")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="action", required=True)
    for name in ("production", "verify"):
        command = subparsers.add_parser(name)
        command.add_argument("--client-jar", required=True)
        command.add_argument("--original-pack", required=True)
        command.add_argument("--lite-dir", required=True)
    subparsers.add_parser("selftest")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.action == "selftest":
            run_selftest()
        else:
            run_production(args, args.action == "verify")
        return 0
    except (PredictionError, AssertionError) as exc:
        print(f"[MINECRAFT26_ATLAS_PREDICTOR] ERROR: {exc}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
