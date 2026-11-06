#!/usr/bin/env python3
"""Compose App Store PNGs from native, unmodified app captures.

Requires Pillow and the macOS San Francisco system font.
Run from any directory: python3 misc/app-store/iphone/generate.py
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
SIZES = {
    "1206x2622": (1206, 2622),
    "1320x2868": (1320, 2868),
}
PALETTE = {
    "cover": "#173F35",
    "paper": "#FAFCF8",
    "edge": "#8DAB99",
}
FONTS = {
    "headline": ("/System/Library/Fonts/SFNS.ttf", 0),
}
SRGB = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()


def font(role: str, size: int) -> ImageFont.FreeTypeFont:
    path, index = FONTS[role]
    face = ImageFont.truetype(path, size, index=index)
    # San Francisco's display optical size and semibold weight.
    values = {b"Width": 100, b"Optical Size": 96, b"GRAD": 400, b"Weight": 600}
    face.set_variation_by_axes([
        values.get(axis["name"], axis["default"])
        for axis in face.get_variation_axes()
    ])
    return face


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_srgb(path: Path) -> Image.Image:
    with Image.open(path) as original:
        image = original.convert("RGB")
        if original.info.get("icc_profile"):
            image = ImageCms.profileToProfile(
                image,
                ImageCms.ImageCmsProfile(io.BytesIO(original.info["icc_profile"])),
                ImageCms.ImageCmsProfile(io.BytesIO(SRGB)),
                outputMode="RGB",
            )
        return image


def save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(path, icc_profile=SRGB, optimize=True)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    """Antialias the presentation edge without softening the screenshot."""
    supersample = 4
    mask = Image.new("L", (size[0] * supersample, size[1] * supersample))
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, mask.width - 1, mask.height - 1),
        radius=radius * supersample, fill=255,
    )
    return mask.resize(size, Image.Resampling.LANCZOS)


def render(
    item: dict, capture: Image.Image, size: tuple[int, int]
) -> tuple[Image.Image, dict]:
    width, height = size
    scale = width / 1320

    def px(value: float) -> int:
        return round(value * scale)

    canvas = Image.new("RGB", size, PALETTE["cover"])
    draw = ImageDraw.Draw(canvas)
    text_bounds = []

    def text(value: str, x: int, y: int, role: str, size: int, color: str):
        face = font(role, px(size))
        position = (px(x), px(y))
        bounds = draw.textbbox(position, value, font=face, anchor="lt")
        if bounds[2] > width - px(90):
            raise ValueError(f"Caption exceeds safe area: {value}")
        draw.text(position, value, font=face, fill=color, anchor="lt")
        text_bounds.append({"text": value, "bounds": list(bounds)})

    for i, line in enumerate(item["headline"]):
        text(line, 104, 88 + i * 126, "headline", 112, PALETTE["paper"])

    # Fit the entire real screenshot, retaining its exact aspect ratio.
    top, bottom = px(380), height - px(70)
    available_height = bottom - top
    screen_width = min(px(1114), round(available_height * capture.width / capture.height))
    screen_height = round(screen_width * capture.height / capture.width)
    left = (width - screen_width) // 2
    rect = (left, top, left + screen_width, top + screen_height)
    radius = round(screen_width * 76 / 991)

    shadow = Image.new("RGBA", size)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (rect[0] - px(4), rect[1] + px(15), rect[2] + px(4), rect[3] + px(15)),
        radius=radius,
        fill=(0, 15, 8, 110),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(px(24)))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB")
    edge = px(3)
    outer_size = (screen_width + 2 * edge, screen_height + 2 * edge)
    canvas.paste(
        Image.new("RGB", outer_size, PALETTE["edge"]),
        (left - edge, top - edge),
        rounded_mask(outer_size, radius + edge),
    )
    mask = rounded_mask((screen_width, screen_height), radius)
    screen = capture.resize((screen_width, screen_height), Image.Resampling.LANCZOS)
    canvas.paste(screen, (left, top), mask)

    return canvas, {
        "screen_bounds": list(rect),
        "screen_scale": round(screen_width / capture.width, 6),
        "text_bounds": text_bounds,
    }


def contact_sheet(images: list[Image.Image]) -> Image.Image:
    tile_width, gutter = 330, 24
    tile_height = round(tile_width * images[0].height / images[0].width)
    sheet = Image.new(
        "RGB", (gutter + len(images) * (tile_width + gutter), tile_height + 2 * gutter),
        "#E8ECE8",
    )
    for i, image in enumerate(images):
        preview = image.resize((tile_width, tile_height), Image.Resampling.LANCZOS)
        sheet.paste(preview, (gutter + i * (tile_width + gutter), gutter))
    return sheet


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=ROOT / "sources")
    parser.add_argument("--output", type=Path, default=ROOT)
    parser.add_argument(
        "--draft", action="store_true",
        help="Permit low-resolution sources for a temporary design preview only.",
    )
    args = parser.parse_args()
    if args.draft and args.output.resolve() == ROOT:
        parser.error("--draft requires a separate --output directory")
    items = json.loads((ROOT / "copy.json").read_text())
    report = {
        "format": "PNG", "mode": "RGB", "profile": "sRGB",
        "draft": args.draft, "exports": [],
    }
    captures = {}
    for item in items:
        path = args.sources / item["source"]
        captures[item["source"]] = read_srgb(path)
        if not args.draft and captures[item["source"]].width < 1206:
            raise ValueError(f"Expected native-resolution capture, got {path}")

    for directory, size in SIZES.items():
        images = []
        for item in items:
            image, layout = render(item, captures[item["source"]], size)
            target = args.output / directory / f"{item['id']}.png"
            save_png(image, target)
            with Image.open(target) as result:
                assert result.size == size and result.mode == "RGB"
                assert "transparency" not in result.info
                assert result.info["icc_profile"] == SRGB
                result.verify()
            report["exports"].append({
                "file": str(target.relative_to(args.output)),
                "pixels": list(size),
                "bytes": target.stat().st_size,
                "sha256": sha256(target),
                "source": item["source"],
                "source_sha256": sha256(args.sources / item["source"]),
                "source_pixels": list(captures[item["source"]].size),
                **layout,
            })
            images.append(image)
        save_png(contact_sheet(images), args.output / f"preview-{directory}.png")
    (args.output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Created and verified {len(report['exports'])} PNGs in {args.output}")


if __name__ == "__main__":
    main()
