# SimpleScripture iPhone Duo screenshots

Five English App Store marketing screenshots for the iPhone Duo outer display,
matching the current [iPhone](../iphone/README.md) and
[iPad](../ipad/README.md) sets with native Duo app captures.

The inner-display set is incomplete. Capture stopped after attempts to switch
the simulator's displays caused a SpringBoard crash loop. The completed outer
captures were taken before those failures.

## Upload files

Use the numbered PNGs in App Store Connect's **iPhone Duo** screenshot group.
Upload the five images in filename order:

| Folder | Portrait dimensions | Display | Preview |
| --- | --- | --- | --- |
| [1398x2034](1398x2034/) | 1398 × 2034 | Outer display | [Five-image preview](preview-1398x2034.png) |

The files are opaque, 8-bit RGB PNGs with an embedded sRGB colour profile.
These are the outer-display dimensions listed in Apple's iPhone Duo screenshot
specifications, checked 7 November 2026.

| File | Caption | Feature |
| --- | --- | --- |
| `01-reading.png` | SimpleScripture / A simple Bible reader | KJV reading |
| `02-search.png` | Search the Bible, with / Greek and Hebrew too | Bible search |
| `03-commentary.png` | MHCC Commentary / Included | Matthew Henry's Concise Commentary |
| `04-word-study.png` | Strong's Concordance / Word by Word | Strong's word study |
| `05-library.png` | A library for your / deeper study | Bookmarks, history and dictionary |

Preview contact sheets, source captures and metadata are working files.
Upload only the numbered images in the size folder.

## Artwork and editing

The design retains the book-cover green (`#173F35`), off-white headlines
(`#FAFCF8`), muted green screen edge (`#8DAB99`) and San Francisco semibold
type from the existing artwork. Headline spacing and screen placement are
adapted from the iPad composition to the Duo outer display.

Each image uses a native Duo outer-display capture. The complete
screen is fitted at its original aspect ratio, with a subtle shadow, edge
and rounded presentation mask. Headlines sit above the app screen.

| Display | Presented screen size | Screen position |
| --- | --- | --- |
| Outer | 1164 × 1693 | Left 117, top 298 |

- [copy.json](copy.json) contains editable captions and ordering.
- [generate.py](generate.py) contains the Duo layout and export validation.
  It imports the existing iPhone generator's colour, font and image helpers.
- [sources/outer](sources/outer/) contains the native outer-display captures.
- [capture-metadata.json](sources/capture-metadata.json) records the simulator,
  app build, capture settings, source hashes and observations.
- [manifest.json](manifest.json) records output sizes, display assignments,
  source and output hashes, and layout bounds.

To regenerate on macOS with Pillow installed:

```sh
python3 misc/app-store/iphone-duo/generate.py
```

Use `--output /path/to/directory` for an alternate output location, or
`--sources /path/to/sources` for a source folder containing an `outer`
subfolder. The generator checks native source sizes, caption bounds,
output dimensions, RGB mode, embedded sRGB profile and absence of transparency.
The macOS San Francisco font is used locally; its font file is not redistributed.

The generator also defines a 2007 × 2853 inner-display layout for future use.
`--display inner` or `--display all` requires a complete set of native captures
in `sources/inner`; those captures are not included.

## Capture notes

Captured on 7 November 2026 with app 0.3.1 (build 20), on an iPhone Duo simulator
running iOS 27.2. The app uses its native vertical controls on the outer display,
light appearance and Georgia at 18 points for reading and study text. Search
and Library use the app's system typography. The status display shows 09:41,
full Wi-Fi and a charged battery.

The capture simulator was shut down after SpringBoard repeatedly failed in its
display-configuration code during the attempted transition to the inner display.
Xcode's original run destination was restored. See the capture metadata for
the exact device, crash context and cleanup record.

## Apple guidance

Checked 7 November 2026:

- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications):
  outer-display sizes are 1398 × 2034 or 2034 × 1398; inner-display sizes are
  2007 × 2853 or 2853 × 2007. PNG and JPEG are accepted; alpha channels and
  transparency are not.
- Apple states Duo screenshots become required in April 2027 for apps using
  the iOS 27.1 SDK or later. Submitting Duo screenshots adds the “Made for
  iPhone Duo” badge to the product page.
- [App Store asset best practices](https://developer.apple.com/app-store/asset-best-practices/):
  show real app use with concise captions and a consistent presentation.
- [Manage your App Store assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets):
  manage placement and ordering in App Store Connect and preview before publishing.
