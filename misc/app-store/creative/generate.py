#!/usr/bin/env python3
"""Create SimpleScripture header/search assets using Apple's crop-safe templates."""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageCms, ImageDraw


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[2]
ICON_DOCUMENT = REPOSITORY / "SimpleScripture App Icon.icon"
ICON_SOURCE = ROOT / "sources/app-icon-light.png"

# Import the existing artwork helpers without leaving bytecode in their folder.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "iphone_artwork", ROOT.parent / "iphone/generate.py"
)
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)

# Bounds of the "Art Safe Area" layers in Apple's Photoshop templates,
# downloaded from the asset best practices page on 6 November 2026.
# Coordinates below are left, top, right, bottom in source pixels.
PLACEMENTS = {
    "universal": {
        "size": (5244, 2950),
        "safe_area": (1921, 660, 3323, 1622),
        "template": "photoshop-universal-asset-template",
    },
    "header": {
        "size": (3840, 1646),
        "safe_area": (1097, 493, 2743, 1154),
        "template": "photoshop-product-page-header-template",
    },
    "search": {
        "size": (3840, 2560),
        "safe_area": (836, 765, 3004, 1795),
        "template": "photoshop-search-results-template",
    },
}


def refresh_icon() -> None:
    developer = Path(subprocess.check_output(
        ["xcode-select", "-p"], text=True
    ).strip())
    renderer = developer.parent / (
        "Applications/Icon Composer.app/Contents/Executables/ictool"
    )
    ICON_SOURCE.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        str(renderer), str(ICON_DOCUMENT),
        "--export-image", "--output-file", str(ICON_SOURCE),
        "--platform", "iOS", "--rendition", "Default",
        "--width", "1024", "--height", "1024", "--scale", "2",
        "--design-generation", "27",
    ], check=True, capture_output=True, text=True)


def read_icon() -> Image.Image:
    with Image.open(ICON_SOURCE) as original:
        icon = original.convert("RGBA")
        if original.info.get("icc_profile"):
            icon = ImageCms.profileToProfile(
                icon,
                ImageCms.ImageCmsProfile(io.BytesIO(original.info["icc_profile"])),
                ImageCms.ImageCmsProfile(io.BytesIO(shared.SRGB)),
                outputMode="RGBA",
            )
        return icon


def contains(outer: tuple, inner: tuple) -> bool:
    return (
        outer[0] <= inner[0] < inner[2] <= outer[2]
        and outer[1] <= inner[1] < inner[3] <= outer[3]
    )


def render(icon: Image.Image, placement: dict) -> tuple[Image.Image, dict]:
    canvas = Image.new("RGB", placement["size"], shared.PALETTE["cover"])
    draw = ImageDraw.Draw(canvas)
    left, top, right, bottom = placement["safe_area"]
    scale = (right - left) / 1402
    face = shared.font("headline", round(100 * scale))
    title = "SimpleScripture"
    text_box = draw.textbbox((0, 0), title, font=face, anchor="lt")
    text_width = text_box[2] - text_box[0]
    text_height = text_box[3] - text_box[1]
    icon_size = round(440 * scale)
    gap = round(82 * scale)
    group_width = text_width + gap + icon_size
    x = round((left + right - group_width) / 2)
    center_y = (top + bottom) / 2
    text_y = round(center_y - text_height / 2)
    text_position = (x - text_box[0], text_y - text_box[1])
    text_bounds = draw.textbbox(text_position, title, font=face, anchor="lt")
    icon_x = x + text_width + gap
    icon_y = round(center_y - icon_size / 2)
    icon_bounds = (icon_x, icon_y, icon_x + icon_size, icon_y + icon_size)
    assert contains(placement["safe_area"], text_bounds)
    assert contains(placement["safe_area"], icon_bounds)

    draw.text(
        text_position, title, font=face,
        fill=shared.PALETTE["paper"], anchor="lt",
    )
    resized_icon = icon.resize(
        (icon_size, icon_size), Image.Resampling.LANCZOS
    )
    canvas.paste(resized_icon, (icon_x, icon_y), resized_icon.getchannel("A"))
    return canvas, {
        "text": title,
        "font_pixels": face.size,
        "text_bounds": list(text_bounds),
        "icon_bounds": list(icon_bounds),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT)
    parser.add_argument("--refresh-icon", action="store_true")
    args = parser.parse_args()
    if args.refresh_icon or not ICON_SOURCE.exists():
        refresh_icon()
    icon = read_icon()
    report = {
        "format": "PNG", "mode": "RGB", "profile": "sRGB",
        "background": shared.PALETTE["cover"],
        "text_colour": shared.PALETTE["paper"],
        "font": "San Francisco, semibold 600, display optical size 96",
        "icon_source": str(ICON_SOURCE.relative_to(REPOSITORY)),
        "icon_source_sha256": shared.sha256(ICON_SOURCE),
        "icon_source_pixels": list(icon.size),
        "icon_rendition": "Default (light), iOS design generation 27",
        "guidance_checked": "2026-11-06",
        "exports": [],
    }
    for name, placement in PLACEMENTS.items():
        image, layout = render(icon, placement)
        width, height = placement["size"]
        filename = f"simplescripture-{name}-{width}x{height}.png"
        target = args.output / filename
        shared.save_png(image, target)
        with Image.open(target) as result:
            assert result.size == placement["size"]
            assert result.mode == "RGB"
            assert "transparency" not in result.info
            assert result.info["icc_profile"] == shared.SRGB
            result.verify()
        assert image.getpixel((0, 0)) == (23, 63, 53)
        report["exports"].append({
            "file": filename,
            "pixels": list(placement["size"]),
            "bytes": target.stat().st_size,
            "sha256": shared.sha256(target),
            "safe_area": list(placement["safe_area"]),
            "template": "https://developer.apple.com/go/?id=" + placement["template"],
            **layout,
        })

        preview = image.copy()
        preview.thumbnail((1311, 900), Image.Resampling.LANCZOS)
        shared.save_png(preview, args.output / "previews" / f"{name}.png")
        if name == "universal":
            # This detail preview is not an upload file or a device simulation.
            detail = image.crop(placement["safe_area"])
            detail.thumbnail((1000, 700), Image.Resampling.LANCZOS)
            shared.save_png(
                detail, args.output / "previews/universal-artwork-detail.png"
            )

    (args.output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Created and verified {len(report['exports'])} PNGs in {args.output}")


if __name__ == "__main__":
    main()
