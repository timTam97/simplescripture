# SimpleScripture app icon

- [SimpleScripture App Icon.icon](<../../SimpleScripture App Icon.icon>) — project
  copy of the layered Icon Composer revision with a larger book and custom dark
  and tinted colours.
- [SimpleScripture App Icon.af](<SimpleScripture App Icon.af>) — editable
  Gilded Folio artwork migrated into the supplied Apple Illustrator template.

The Affinity document retains Apple's grid and rounded icon shape as named
guide/preview layers. The sample circles were replaced by the original editable
`03_Gilded_Folio` and `01_Background` layers, including the book's component
groups and embedded textures.

The book is uniformly reduced from 896 to 832 units wide, centered at approximately
X 96, Y 93.3 on the 1024-unit artboard, so its corners clear Apple's icon shape.
The background covers the entire square. The original design remains in
[`docs/rebranding/simplescripture-heritage.af`](../../docs/rebranding/simplescripture-heritage.af)
as the earlier artwork source.

For a clean export, hide both `GUIDE — Apple grid (hide for export)` and
`PREVIEW — Apple icon shape (hide for export)`. Export the named artboard as PNG
at 1024 × 1024 with sRGB and an opaque background. The Illustrator import uses
points and 300 dpi, so explicitly set the output pixel dimensions. The retained
asset-catalog PNG was rendered in Affinity at 4267 px and downsampled with
Lanczos to 1024 px; its size, RGB format and profile were checked, along with
60, 120 and 256 px previews.

The earlier PNG is retained in
`PocketSword/Images.xcassets/AppIcon.appiconset/SimpleScripture.png`.
The project copy of the Composer document is at the repository root.

The editable Affinity document retains the guide layers described above, with
the accompanying [Apple Design Resources License](<Apple Design Resources License.rtf>).

## Icon Composer revision

The Composer document uses a native background plus four transparent artwork
layers: leather cover, bookmark, pages/back cover, and a vector cross. Its book
is 798 pixels wide on a 1024-pixel canvas (about 78%), approximately 22% larger
than the existing PNG. The oval, borders, spine bands, page detail, and bookmark
are retained in the standard and dark appearances.

The standard background is System Light. Dark uses System Dark and a brighter
gold cross. Tinted uses explicit grayscale fills for the cover, bookmark,
pages, and cross; the operating system applies the user's chosen hue. The
cross has subtle glass lighting, while the book layers are opaque.

[SimpleScripture App Icon.svg](<SimpleScripture App Icon.svg>) is an export
of the existing Affinity document. `generate-composer-layers.py` extracts and
scales the artwork into the ignored `composer-layers/` directory; it requires
Pillow and Node.js with `sharp` available. The cross's baked shadows are omitted
so Composer can provide its lighting. The component SVG files retain editable
vector geometry and the original embedded textures.

The package embeds the generated Pages, Bookmark, and Cover PNGs plus Cross.svg.
After regenerating artwork, copy those four files from `composer-layers/` into
the project-root `SimpleScripture App Icon.icon/Assets/`. The package stores
layers from front to back. Its appearance settings live in `icon.json` and can
be edited in Composer. Use the project-root document for current app artwork.
Generated layers can be removed after copying them into that package.

Optional appearance exports can be saved locally in the ignored
`composer-previews/` directory. The user's tint remains a system choice.

The launch storyboard, SwiftUI loading screen, and About header use static
Default and Dark exports of the project-root document. Regenerate their
1×/2×/3× image assets after an icon edit:

```sh
xcrun swift docs/rebranding/generate-launch-icon.swift
```

This preserves Composer's native shape and lighting in the in-app artwork.
Home Screen tint and motion effects remain part of the system app icon.
