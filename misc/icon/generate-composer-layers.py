#!/usr/bin/env python3
"""Prepare transparent Icon Composer artwork from the Affinity SVG export.

Requires Pillow and Node.js with the sharp package available (or NODE_PATH set).
The .af document and the app's installed PNG are not modified.
"""

from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "SimpleScripture App Icon.svg"
OUTPUT = ROOT / "composer-layers"
SVG = "http://www.w3.org/2000/svg"
XLINK = "http://www.w3.org/1999/xlink"
ET.register_namespace("", SVG)
ET.register_namespace("xlink", XLINK)
ET.register_namespace("affinity", "https://www.affinity.studio/")


def export_layer(filename, cross_only=False, scale=1.0, section=None):
    root = ET.parse(SOURCE).getroot()
    root.set("width", "1024")
    root.set("height", "1024")
    root.set("viewBox", "0 0 1024 1024")
    artboard = root.find(f"{{{SVG}}}g")
    artboard.set(
        "transform", f"translate(512 512) scale({scale:.9f}) translate(-512 -512)"
    )
    folio = next(e for e in artboard if e.get("id") == "_03_Gilded_Folio")
    for element in list(artboard):
        if element is not folio:
            artboard.remove(element)
    for element in list(folio):
        is_cross = element.get("id") == "Solid_gold_cross"
        identifier = element.get("id")
        pages = identifier in {"Back_cover", "Ivory_page_block"}
        bookmark = identifier == "Oxblood_satin_bookmark"
        keep = is_cross == cross_only
        if section == "Pages":
            keep = pages
        elif section == "Bookmark":
            keep = bookmark
        elif section == "Cover":
            keep = not (pages or bookmark or is_cross)
        if not keep:
            folio.remove(element)
    if cross_only:
        cross = folio[0]
        # Icon Composer supplies the cross's lighting and shadow.
        for element in list(cross):
            if element.get("id") != "Solid_gold_face":
                cross.remove(element)

    # Retain only definitions actually referenced by this layer.
    defs = root.find(f"{{{SVG}}}defs")
    if defs is not None:
        definitions = {e.get("id"): e for e in defs}
        needed = set()
        pending = list(artboard.iter())
        while pending:
            element = pending.pop()
            for value in element.attrib.values():
                references = re.findall(r"url\(#([^)]*)\)", value)
                if value.startswith("#"):
                    references.append(value[1:])
                for reference in references:
                    if reference not in needed:
                        needed.add(reference)
                        if reference in definitions:
                            pending.extend(definitions[reference].iter())
        for definition in list(defs):
            if definition.get("id") not in needed:
                defs.remove(definition)
    ET.ElementTree(root).write(filename, encoding="utf-8", xml_declaration=True)


def render(source, destination):
    subprocess.run(
        [
            "node", "-e",
            "require('sharp')(process.argv[1]).resize(1024,1024)"
            ".png().toFile(process.argv[2]).catch(e=>{console.error(e);process.exit(1)})",
            str(source), str(destination),
        ],
        check=True,
    )


def main():
    OUTPUT.mkdir(exist_ok=True)
    export_layer(OUTPUT / "Book.svg")
    render(OUTPUT / "Book.svg", OUTPUT / "Book.png")
    original = Image.open(OUTPUT / "Book.png").convert("RGBA")
    left, top, right, bottom = original.getchannel("A").getbbox()
    scale = (1024 * 0.78) / (right - left)
    export_layer(OUTPUT / "Book.svg", scale=scale)
    export_layer(OUTPUT / "Cross.svg", cross_only=True, scale=scale)
    render(OUTPUT / "Book.svg", OUTPUT / "Book.png")
    render(OUTPUT / "Cross.svg", OUTPUT / "Cross.png")
    for section in ("Pages", "Bookmark", "Cover"):
        export_layer(OUTPUT / f"{section}.svg", scale=scale, section=section)
        render(OUTPUT / f"{section}.svg", OUTPUT / f"{section}.png")

    book = Image.open(OUTPUT / "Book.png").convert("RGBA")
    alpha = book.getchannel("A")
    bounds = alpha.getbbox()
    print(f"Book scale: {scale:.4f}; bounds: {bounds}; width: {bounds[2]-bounds[0]} px")


if __name__ == "__main__":
    main()
