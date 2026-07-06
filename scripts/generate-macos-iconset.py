#!/usr/bin/env python3

from __future__ import annotations

import argparse
import struct
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps


ICONSET_ENTRIES = [
    ("16x16", "1x", "icon_16x16.png", 16),
    ("16x16", "2x", "icon_16x16@2x.png", 32),
    ("32x32", "1x", "icon_32x32.png", 32),
    ("32x32", "2x", "icon_32x32@2x.png", 64),
    ("128x128", "1x", "icon_128x128.png", 128),
    ("128x128", "2x", "icon_128x128@2x.png", 256),
    ("256x256", "1x", "icon_256x256.png", 256),
    ("256x256", "2x", "icon_256x256@2x.png", 512),
    ("512x512", "1x", "icon_512x512.png", 512),
    ("512x512", "2x", "icon_512x512@2x.png", 1024),
]

ICNS_ENTRIES = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a macOS app iconset and optional icns file."
    )
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--iconset", required=True, type=Path)
    parser.add_argument("--icns", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def continuous_mask(size: int, scale: int = 4, exponent: float = 5.0) -> Image.Image:
    canvas_size = size * scale
    center = (canvas_size - 1) / 2.0
    radius = center
    points: list[tuple[float, float]] = []

    for index in range(720):
        angle = 2.0 * math.pi * index / 720
        cos_value = math.cos(angle)
        sin_value = math.sin(angle)
        x_value = math.copysign(abs(cos_value) ** (2.0 / exponent), cos_value)
        y_value = math.copysign(abs(sin_value) ** (2.0 / exponent), sin_value)
        points.append((center + radius * x_value, center + radius * y_value))

    mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def generate_iconset(source: Path, iconset: Path, dry_run: bool) -> None:
    if dry_run:
        print(f"Would generate {iconset} from {source}")
        return

    iconset.mkdir(parents=True, exist_ok=True)
    source_image = Image.open(source).convert("RGBA")
    base_image = ImageOps.fit(
        source_image,
        (1024, 1024),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    base_image.putalpha(continuous_mask(1024))

    for _logical_size, _scale, filename, pixel_size in ICONSET_ENTRIES:
        output = base_image.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
        output.save(iconset / filename)

    contents = {
        "images": [
            {
                "size": logical_size,
                "idiom": "mac",
                "filename": filename,
                "scale": scale,
            }
            for logical_size, scale, filename, _pixel_size in ICONSET_ENTRIES
        ],
        "info": {
            "version": 1,
            "author": "xcode",
        },
    }
    (iconset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n",
        encoding="utf-8",
    )


def generate_icns(iconset: Path, icns: Path | None, dry_run: bool) -> None:
    if icns is None:
        return

    if dry_run:
        print(f"Would generate {icns} from {iconset}")
        return

    chunks = []
    for icon_type, filename in ICNS_ENTRIES:
        data = (iconset / filename).read_bytes()
        chunks.append(icon_type.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

    payload = b"".join(chunks)
    icns.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)


def main() -> None:
    args = parse_args()
    generate_iconset(args.source, args.iconset, args.dry_run)
    generate_icns(args.iconset, args.icns, args.dry_run)


if __name__ == "__main__":
    main()
