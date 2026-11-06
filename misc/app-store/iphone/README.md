# SimpleScripture iPhone screenshots

Five English App Store marketing screenshots, based on the reading, search,
commentary, word-study and library examples in the repository README.

## Upload files

Upload the five numbered PNGs from each folder to its matching device-size slot,
in filename order:

| Folder | Portrait dimensions | App Store Connect device group |
| --- | --- | --- |
| [1206x2622](1206x2622/) | 1206 × 2622 | iPhone with Dynamic Island (medium display) |
| [1320x2868](1320x2868/) | 1320 × 2868 | iPhone with Dynamic Island (large display) |

Both sets are opaque, 8-bit RGB PNGs with an embedded sRGB colour profile.
The medium-display set covers Apple's currently required iPhone screenshot
group. The large-display set provides the corresponding larger presentation.
The five files in each folder are the same sequence, composed for that size.

1. **SimpleScripture — A simple Bible reader** — KJV reading.
2. **Search the Bible, English and Greek** — Bible search.
3. **MHCC Commentary Included** — Matthew Henry's Concise Commentary.
4. **Strong's Concordance — Word by word** — Strong's word study.
5. **A library for deeper study.** — bookmarks, history and dictionary.

[Preview the medium set](preview-1206x2622.png) or
[preview the large set](preview-1320x2868.png).
Preview contact sheets, source captures, and the manifest are working files;
upload only the numbered images in the size folders.

## Artwork and editing

The design keeps the green background from the app's book icon and uses
San Francisco semibold headlines for a modern Apple-style presentation.
Each image contains just its headline and a large app screen, without
additional branding, a decorative bookmark, or subtitles. The screen is about
12% larger in each dimension than the initial design. Headlines sit above
the screen so they do not cover controls, search results, or Bible text.

| Role | Colour |
| --- | --- |
| Book-cover background | `#173F35` |
| Headline | `#FAFCF8` |
| Screen edge | `#8DAB99` |

- [copy.json](copy.json) contains the editable captions and ordering.
- [generate.py](generate.py) contains the layout, typography and colours.
- [sources](sources/) contains the native app captures used in the artwork.
- [capture-metadata.json](sources/capture-metadata.json) records the device,
  app build, capture settings, source hashes and observations.
- [manifest.json](manifest.json) records export sizes, colour mode, file hashes,
  source hashes and layout bounds.

The original sources were captured on an iPhone 17 simulator running iOS 27.2
after a successful build of commit `e06cffe7` (app 0.1.1, build 20), using the
app's light appearance and Georgia at 18 points. The Library source was later
replaced with the user-provided `Screenshot iPhone 17 06-11-2026 at 14.20.12.png`,
copied unchanged into `sources/library.png`. It shows saved bookmarks and the
Bookmarks / History / Dictionary menu. All selected sources are native
1206 × 2622 images. The optional `sources/library-entry.png` offers a Hebrew
definition view.

The renderer converts the captures to sRGB, fits the complete screen at its
original aspect ratio, and adds a rounded presentation mask. It does not redraw
or alter the app's text, controls, or search results. Both export sizes render
directly from the native captures; no enlarged README thumbnails are used.

To regenerate on macOS with Pillow installed:

```sh
python3 misc/app-store/iphone/generate.py
```

The script uses the macOS-installed San Francisco system font; font
files are not redistributed. It verifies each output's dimensions, RGB mode,
ICC profile and absence of transparency. Use `--output /path/to/directory` for
an alternate output location.

Capture observation: the long first entry of MHCC John 3 appeared blank in two
captures; this was not checked across relaunches. The delivered commentary
image uses Genesis 1, matching the README and rendering correctly. No app
source changes were made.

## Apple guidance

Checked 6 November 2026:

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications):
  accepted dimensions above, PNG/JPEG formats, no alpha channel, and up to
  ten screenshots per device size.
- [App Store asset best practices](https://developer.apple.com/app-store/asset-best-practices/):
  show real app use, lead with core benefits, use short readable captions, and
  keep a consistent visual style.
- [Manage your App Store assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets):
  manage screenshot placement and order through Product Page Information or
  Media Manager; use App Store Connect's preview before publishing.
