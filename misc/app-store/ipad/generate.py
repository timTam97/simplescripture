#!/usr/bin/env python3
"""Compose 13-inch iPad App Store PNGs from native portrait app captures.

Requires Pillow and macOS San Francisco. Shares colour and font helpers with
the adjacent iPhone generator, while using an iPad-specific layout.
Run from any directory: python3 misc/app-store/ipad/generate.py
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent
SIZE = (2064, 2752)
DIRECTORY = "2064x2752"

# Keep typography, colour conversion and edge rendering identical to iPhone.
# Suppress bytecode so regeneration does not create working files beside it.
spec = importlib.util.spec_from_file_location(
    "iphone_artwork", ROOT.parent / "iphone" / "generate.py"
)
shared = importlib.util.module_from_spec(spec)
previous_bytecode_setting = sys.dont_write_bytecode
try:
    sys.dont_write_bytecode = True
    spec.loader.exec_module(shared)
finally:
    sys.dont_write_bytecode = previous_bytecode_setting


def render(item: dict, capture: Image.Image) -> tuple[Image.Image, dict]:
    width, height = SIZE
    top, bottom = 440, height - 64
    screen_height = bottom - top
    screen_width = round(screen_height * capture.width / capture.height)
    left = (width - screen_width) // 2
    rect = (left, top, left + screen_width, top + screen_height)
    if left < 100 or screen_width > capture.width or screen_height > capture.height:
        raise ValueError("Capture cannot fit the iPad layout without cropping or enlargement")

    canvas = Image.new("RGB", SIZE, shared.PALETTE["cover"])
    draw = ImageDraw.Draw(canvas)
    face = shared.font("headline", 144)
    text_bounds = []
    for index, line in enumerate(item["headline"]):
        position = (left, 88 + index * 162)
        bounds = draw.textbbox(position, line, font=face, anchor="lt")
        if bounds[2] > width - left or bounds[3] > top - 48:
            raise ValueError(f"Caption exceeds safe area: {line}")
        draw.text(position, line, font=face, fill=shared.PALETTE["paper"], anchor="lt")
        text_bounds.append({"text": line, "bounds": list(bounds)})

    # The iPad has a much smaller corner radius relative to its width.
    # Keep all app content at its original aspect ratio inside the screen.
    radius, edge = 38, 3
    shadow = Image.new("RGBA", SIZE)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left - 4, top + 16, rect[2] + 4, rect[3] + 16),
        radius=radius,
        fill=(0, 15, 8, 110),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(24))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB")
    outer_size = (screen_width + 2 * edge, screen_height + 2 * edge)
    canvas.paste(
        Image.new("RGB", outer_size, shared.PALETTE["edge"]),
        (left - edge, top - edge),
        shared.rounded_mask(outer_size, radius + edge),
    )
    screen = capture.resize((screen_width, screen_height), Image.Resampling.LANCZOS)
    canvas.paste(
        screen, (left, top),
        shared.rounded_mask((screen_width, screen_height), radius),
    )
    return canvas, {
        "screen_bounds": list(rect),
        "screen_scale": round(screen_width / capture.width, 6),
        "text_bounds": text_bounds,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=ROOT / "sources")
    parser.add_argument("--output", type=Path, default=ROOT)
    args = parser.parse_args()
    items = json.loads((ROOT / "copy.json").read_text())
    captures = {}
    for item in items:
        path = args.sources / item["source"]
        captures[item["source"]] = shared.read_srgb(path)
        if captures[item["source"]].size != SIZE:
            raise ValueError(f"Expected a native {SIZE[0]} × {SIZE[1]} iPad capture: {path}")

    report = {
        "format": "PNG", "mode": "RGB", "profile": "sRGB",
        "device_group": 'iPad 13" display', "orientation": "portrait",
        "exports": [],
    }
    images = []
    for item in items:
        capture = captures[item["source"]]
        image, layout = render(item, capture)
        target = args.output / DIRECTORY / f"{item['id']}.png"
        shared.save_png(image, target)
        with Image.open(target) as result:
            assert result.size == SIZE and result.mode == "RGB"
            assert "transparency" not in result.info
            assert result.info["icc_profile"] == shared.SRGB
            result.verify()
        report["exports"].append({
            "file": str(target.relative_to(args.output)),
            "pixels": list(SIZE),
            "bytes": target.stat().st_size,
            "sha256": shared.sha256(target),
            "source": item["source"],
            "source_sha256": shared.sha256(args.sources / item["source"]),
            "source_pixels": list(capture.size),
            **layout,
        })
        images.append(image)
    shared.save_png(shared.contact_sheet(images), args.output / f"preview-{DIRECTORY}.png")
    (args.output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Created and verified {len(report['exports'])} PNGs in {args.output}")


if __name__ == "__main__":
    main()
