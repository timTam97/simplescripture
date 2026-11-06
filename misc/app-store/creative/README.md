# SimpleScripture header and search artwork

“SimpleScripture” appears to the left of the current light-mode app icon on
the same solid green as the App Store screenshots.

## Upload files

| File | Dimensions | Placement |
| --- | --- | --- |
| [Universal](simplescripture-universal-5244x2950.png) | 5244 × 2950 | One image usable for both product page header and search results |
| [Header](simplescripture-header-3840x1646.png) | 3840 × 1646 | Product page header, with its own framing |
| [Search](simplescripture-search-3840x2560.png) | 3840 × 2560 | Search results, with its own framing |

Start with the universal PNG when reusing one asset in both placements.
The separate header and search files offer larger compositions within their
respective template safe areas.

All three files are opaque, 8-bit RGB PNGs with an embedded sRGB profile.
The artwork uses San Francisco semibold, off-white `#FAFCF8` lettering and
green `#173F35`, matching the iPhone and iPad screenshot sets.
The icon retains its native light background, shape and lighting.

The large green margins are intentional. Apple's universal template places
its shared art-safe area above the image centre; keeping the entire name
and icon in that area protects them when the image is cropped across
placements and devices. The separate exports follow their own templates.
Use App Store Connect's preview to inspect the final presentation.

The images in [previews](previews/) are working previews, not upload files.
`universal-artwork-detail.png` enlarges the safe area for reviewing the design;
it does not simulate a particular device or App Store placement.

## Edit and regenerate

[generate.py](generate.py) contains the layout and template coordinates.
It reuses the [iPhone screenshot generator](../iphone/generate.py)'s font,
palette and colour-profile helpers. The system font is used locally and
is not redistributed.

[sources/app-icon-light.png](sources/app-icon-light.png) is a native 2048 × 2048
Default/light render of the project's current
[`SimpleScripture App Icon.icon`](<../../../SimpleScripture App Icon.icon>),
exported through Xcode's Icon Composer with iOS design generation 27.

Run on macOS with Pillow installed:

```sh
python3 misc/app-store/creative/generate.py
```

Add `--refresh-icon` to render the current Icon Composer document again.
Use `--output /path/to/directory` to save the composed assets elsewhere.
The generator checks dimensions, RGB mode, absence of transparency, the
embedded sRGB profile, background colour and containment of all key artwork
inside Apple's template safe area.

[manifest.json](manifest.json) records source/output hashes, image sizes,
layout bounds and template links.

## Apple references

Checked 6 November 2026:

- [Asset best practices](https://developer.apple.com/app-store/asset-best-practices/)
- [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)
- [Universal Photoshop template](https://developer.apple.com/go/?id=photoshop-universal-asset-template)
- [Header Photoshop template](https://developer.apple.com/go/?id=photoshop-product-page-header-template)
- [Search Photoshop template](https://developer.apple.com/go/?id=photoshop-search-results-template)

Safe-area coordinates were read from the templates' “Art Safe Area” layers.
Apple's templates are reference files and are not included in this directory.
