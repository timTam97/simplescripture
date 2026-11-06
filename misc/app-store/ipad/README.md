# SimpleScripture iPad screenshots

Five English App Store marketing screenshots matching the current iPhone set,
with native iPad app captures and a layout composed for the wider display.

## Upload files

Upload the five numbered PNGs from [2064x2752](2064x2752/) to the
**iPad 13-inch display** slot in App Store Connect, in filename order.

| File | Caption | Feature |
| --- | --- | --- |
| `01-reading.png` | SimpleScripture / A simple Bible reader | KJV reading |
| `02-search.png` | Search the Bible, / English and Greek | Bible search |
| `03-commentary.png` | MHCC Commentary / Included | Matthew Henry's Concise Commentary |
| `04-word-study.png` | Strong's Concordance / Word by Word | Strong's word study |
| `05-library.png` | A library for / deeper study | Bookmarks, history and dictionary |

Each upload file is a **2064 × 2752 portrait, opaque, 8-bit RGB PNG** with an
embedded sRGB colour profile. This is an accepted size for the required iPad
13-inch group. App Store Connect can scale this set for smaller iPad groups
when the interface is consistent across sizes.

[Preview all five images](preview-2064x2752.png).
The preview, source captures and manifest are working files; upload only the
five numbered images in the size folder.

## Artwork and editing

The design uses the same book-cover green (`#173F35`), off-white headlines
(`#FAFCF8`), muted green screen edge (`#8DAB99`) and San Francisco semibold
type as [the iPhone set](../iphone/README.md). The captions retain its current
wording and order. The screen proportions, corner radius, headline size and
spacing are adapted to iPad.

Each composition preserves the full captured app screen at its original
aspect ratio, downscaled to 1686 × 2248 pixels. A subtle edge, shadow and
rounded presentation mask surround it. Headlines sit above the app. The
renderer does not redraw app text or controls.

- [copy.json](copy.json) contains editable captions and ordering.
- [generate.py](generate.py) contains the iPad layout and export validation.
  It imports shared colour, font and image helpers from the adjacent
  [iPhone generator](../iphone/generate.py).
- [sources](sources/) contains the original native iPad captures.
- [capture-metadata.json](sources/capture-metadata.json) records the device,
  app build, capture settings, source hashes and observations.
- [manifest.json](manifest.json) records each export's dimensions, hashes,
  source and layout bounds.

To regenerate on macOS with Pillow installed:

```sh
python3 misc/app-store/ipad/generate.py
```

Use `--output /path/to/directory` for an alternate output location.
The generator requires native 2064 × 2752 sources and verifies output
dimensions, RGB mode, embedded sRGB profile and absence of transparency.
The macOS San Francisco font is used locally; its font file is not
redistributed.

## Capture notes

The sources were captured on an iPad Pro 13-inch (M5) simulator running
iPadOS 27.2, in portrait and light appearance, with the status bar set to
09:41 and full Wi-Fi/battery. The reading view uses Georgia at 24 points;
commentary and word study use 32 points. Search and Library retain the
app's system typography.

The commentary image focuses on MHCC Genesis 1's opening passage. An earlier
capture at 24 points exposed a literal `#1Jo 5:20|` reference marker farther
down the commentary; increasing the app's font size kept that later text
outside the delivered view. This is an existing content-formatting observation,
not an app fix. No app source changes were made for these assets.

## Apple guidance

Checked 6 November 2026:

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications):
  2064 × 2752 is accepted for the required iPad 13-inch display group;
  images cannot contain alpha channels or transparency.
- [App Store asset best practices](https://developer.apple.com/app-store/asset-best-practices/):
  showcase real app use with concise captions and a consistent presentation.
- [Manage your App Store assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets):
  manage placement and ordering in App Store Connect and preview before publishing.
