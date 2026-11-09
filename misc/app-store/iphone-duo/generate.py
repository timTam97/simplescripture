#!/usr/bin/env python3
"""Compose iPhone Duo App Store PNGs from native display captures.

Requires Pillow and the macOS San Francisco system font.
Run from any directory: python3 misc/app-store/iphone-duo/generate.py
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent
DISPLAYS = {
    "outer": (1398, 2034),
    "inner": (2007, 2853),
}
SPECIFICATIONS_URL = (
    "https://developer.apple.com/help/app-store-connect/reference/"
    "app-information/screenshot-specifications"
)

# Reuse the existing artwork's palette, font and colour-profile conversion.
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


def render(
    item: dict, capture: Image.Image, display: str
) -> tuple[Image.Image, dict]:
    size = DISPLAYS[display]
    if capture.size != size:
        raise ValueError(f"Expected a native {size} {display} display capture")
    width, height = size
    scale = width / 2064

    def px(value: float) -> int:
        return round(value * scale)

    # Adapt the iPad artwork's spacing to each Duo display, preserving every
    # screen at its own aspect ratio. Never stretch an iPhone or iPad source.
    top, bottom = px(440), height - px(64)
    screen_height = bottom - top
    screen_width = round(screen_height * capture.width / capture.height)
    left = (width - screen_width) // 2
    rect = (left, top, left + screen_width, top + screen_height)
    if left < px(100) or screen_width > capture.width or screen_height > capture.height:
        raise ValueError("Capture cannot fit without cropping or enlargement")

    canvas = Image.new("RGB", size, shared.PALETTE["cover"])
    draw = ImageDraw.Draw(canvas)
    face = shared.font("headline", px(144))
    text_bounds = []
    for index, line in enumerate(item["headline"]):
        position = (left, px(88 + index * 162))
        bounds = draw.textbbox(position, line, font=face, anchor="lt")
        if bounds[0] < left or bounds[2] > width - left or bounds[3] > top - px(48):
            raise ValueError(f"Caption exceeds safe area: {line}")
        draw.text(position, line, font=face, fill=shared.PALETTE["paper"], anchor="lt")
        text_bounds.append({"text": line, "bounds": list(bounds)})

    # Rounded presentation masks follow the existing set; these are not
    # hardware mockups. The complete screen remains inside the composition.
    radius = px(72 if display == "outer" else 38)
    edge = max(2, px(3))
    shadow = Image.new("RGBA", size)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left - px(4), top + px(16), rect[2] + px(4), rect[3] + px(16)),
        radius=radius,
        fill=(0, 15, 8, 110),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(24)))
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
        "corner_radius": radius,
        "text_bounds": text_bounds,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=ROOT / "sources")
    parser.add_argument("--output", type=Path, default=ROOT)
    parser.add_argument(
        "--display", choices=("outer", "inner", "all"), default="outer",
        help="Display to export. Only outer sources are currently captured.",
    )
    args = parser.parse_args()
    displays = {
        name: size for name, size in DISPLAYS.items()
        if args.display == "all" or name == args.display
    }
    items = json.loads((ROOT / "copy.json").read_text())
    captures = {}
    for display, size in displays.items():
        for item in items:
            path = args.sources / display / item["source"]
            if not path.is_file():
                raise ValueError(f"Native {display} display capture is not available: {path}")
            capture = shared.read_srgb(path)
            if capture.size != size:
                raise ValueError(
                    f"Expected native {size[0]} × {size[1]} {display} capture: {path}"
                )
            captures[(display, item["source"])] = capture

    report = {
        "format": "PNG", "mode": "RGB", "profile": "sRGB",
        "device_group": "iPhone Duo", "orientation": "portrait",
        "displays": list(displays),
        "specifications_url": SPECIFICATIONS_URL,
        "specifications_checked": "2026-11-07",
        "exports": [],
    }
    for display, size in displays.items():
        directory = f"{size[0]}x{size[1]}"
        images = []
        for item in items:
            capture = captures[(display, item["source"])]
            image, layout = render(item, capture, display)
            target = args.output / directory / f"{item['id']}.png"
            shared.save_png(image, target)
            with Image.open(target) as result:
                if (
                    result.size != size
                    or result.mode != "RGB"
                    or "transparency" in result.info
                    or result.info.get("icc_profile") != shared.SRGB
                ):
                    raise ValueError(f"Invalid App Store export: {target}")
                result.verify()
            source = Path(display) / item["source"]
            report["exports"].append({
                "file": str(target.relative_to(args.output)),
                "display": display,
                "pixels": list(size),
                "bytes": target.stat().st_size,
                "sha256": shared.sha256(target),
                "source": str(source),
                "source_sha256": shared.sha256(args.sources / source),
                "source_pixels": list(capture.size),
                **layout,
            })
            images.append(image)
        shared.save_png(
            shared.contact_sheet(images),
            args.output / f"preview-{directory}.png",
        )
    (args.output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Created and verified {len(report['exports'])} PNGs in {args.output}")


if __name__ == "__main__":
    main()
