# Rebranding work

Branch: `release/rebrand`, created from `main` at `49f4748b` on 5 October 2026.

The app will receive a new name and original visual assets before publication.
The user requested help choosing the name and style, then proposed
**SimpleScripture**. On 5 October 2026, the user chose SimpleScripture and
Gilded Folio for the redesigned About page. Its icon is now included in the
application bundle. The display name and visible application messages now use
SimpleScripture. Gilded Folio is also installed as the app icon, and all build
configurations use the fork's new application identity.

## Selected About direction: SimpleScripture

The name directly communicates the purpose of the app and fits a focused Bible
reader with commentary, search and lexicons. “Simple” describes the interface;
it does not require removing the study tools. “Simple Scripture” is an optional
spaced form for visible titles; the user's proposed spelling is SimpleScripture.

The first visual proposal was an open book with one brass bookmark, on deep pine.
Palette: pine `#254E47`, paper `#F9F8F2`, brass `#D4B875`, sage `#93ABA1`.
Use a clear sans serif for the brand; leave the reading font under user control.
The editable master is `simplescripture.svg`; `simplescripture-concept.png`
shows the concept at large and small sizes. These are provisional, original
vector shapes, not final application assets.

### Gilded Folio artwork

On 5 October 2026, the user requested a maximalist, skeuomorphic direction
inspired by the tactile character of the original PocketSword icon.
`simplescripture-heritage.af` is the editable Affinity master. The revised
pine-leather Bible is upright and inset within the square icon, with a solid gold cross
(`#E3BC67`), a plain embossed oval, gilt page edges, index tabs, and an oxblood
satin bookmark. The cross has a fine bronze outline and a soft shadow; its face
remains one colour. Botanical ornaments, the oval's inward rays and lower
diamond-and-dot ornament, and the cross's gradients, bevels, and hairlines have
been removed at the user's request.

- `simplescripture-heritage.png`: exported from Affinity and verified as
  1024 × 1024, RGB, sRGB IEC61966-2.1, without an alpha channel.
- `simplescripture-heritage-preview.png`: a 640 px preview for review.
- `simplescripture-heritage.svg`: matching Affinity vector export with embedded,
  procedurally generated material textures. No inherited icon pixels or font
  files are included.

The detailed source was prepared programmatically after Affinity's custom
controls rejected computer-use input, then imported, visually inspected, saved
as a native document, and exported through Affinity. The revision used an SVG
export of the user's straightened Affinity document as its base. The binding
was widened to fill the square while preserving the cross and oval proportions.
Book and background are separate groups; the book contains editable component
groups. The updated PNG was checked at 60, 120, and 256 px, and the cross's
interior was verified to contain one RGB colour. The PNG was installed as
the `SimpleScriptureAbout` image set and the universal 1024 px iOS `AppIcon`
source. Xcode generates the required device icon sizes from the approved PNG.

The rounded-corner adaptation on 5 October 2026 was edited directly in Affinity.
The book group is scaled uniformly to 87.5%, with its bounds at X 64, Y 61 and
width 896 on the 1024 px canvas. The pine background still covers the full square.
This gives the corner fittings, page edges and bookmark room inside the rounded
mask. The native master, SVG, PNG, 640 px preview and both application asset
copies are updated. Rounded previews using the silhouette from the user's
About screenshot were visually checked at 60, 120 and 320 px. That export
is 1024 × 1024, opaque RGB with its sRGB profile, and both application copies
matched it byte for byte at that checkpoint. The application had not been
rebuilt or checked on a device after that artwork-only change.

The current Home Screen icon source and export are in
[`misc/icon`](../../misc/icon/README.md). The editable Affinity master uses an
832-unit-wide book inside the 1024-unit artboard, giving it more room within
Apple's icon shape. Its opaque 1024 px PNG matches the `AppIcon` asset byte for
byte. The About image and launch splash retain the earlier artwork described
above. Unused Icon Composer examples and stock Illustrator/Photoshop templates
have been removed; the retained source files and export instructions are listed
in the icon README.

The obsolete icon sets, launch images, screenshots, `.acorn` artwork and unused
bitmap controls have been removed from the current checkout and Xcode resources
(170 files, 17,240,098 bytes). The SwiftUI UI uses SF Symbols plus the new About
image; the launch storyboard was reduced to a plain background before the splash
described below was added. Copyright/contributor
notices and Git history are preserved.

### Launch splash

Added on 6 October 2026. The system launch storyboard and SwiftUI loading view
show the approved Gilded Folio icon above the SimpleScripture name, centered on
the screen. System background and label colors adapt to light and dark mode.
The app adds an accessible progress indicator while preparation runs and opens
the reader immediately when it finishes; there is no minimum display time.

`LaunchIcon.imageset` contains rounded, transparent 128 pt artwork at 1×, 2×
and 3×. Both launch surfaces use those same images, since the system storyboard
cannot execute custom clipping code. Regenerate them after changing the approved
About artwork:

```sh
xcrun swift docs/rebranding/generate-launch-icon.swift
```

Keep the storyboard and `LaunchView` layout in sync: a 128 pt icon, a 24 pt gap,
and the name in 28 pt semibold system type within a 34 pt label. Xcode previews
in `SwiftUISupportingViews.swift` cover the loading view in both appearances and
the compiled system storyboard.

Verification on iPhone 18 Pro / iOS 27 simulator:

- Xcode build-for-testing passed. All four focused tests passed without skips:
  launch migrations, reset behavior, reading-session restoration and access to
  all four workspaces.
- Light and dark loading previews, landscape with the largest Dynamic Type
  setting, and the light system-storyboard preview were visually checked.
- Normal launch reached readable scripture, chapter navigation worked, and
  rotating to landscape and back preserved the reference.
- The brief system-to-app transition was not captured during a normal launch;
  appearance was checked using the rendered previews. Physical-device launch
  remains unverified.

On 7 October 2026, after the demo/template cleanup and `Info.plist` relocation,
Xcode build-for-testing and the same four tests passed again with zero skips.
Asset manifests, PNG dimensions, plist/storyboard syntax and local documentation
links also passed validation.

On 5 October 2026, the primary website at
`https://www.simplescripture.co.za/` was checked. It uses “Simple Scripture” for
Christian books and resources. A limited search of indexed Apple App Store
pages did not surface an exact app-title match. This does not establish App
Store Connect availability or trademark clearance. Existing use in the same
subject area is a reason to review differentiation before publication.

## Name and visual directions

| Working name | Character | Icon concept | Palette |
| --- | --- | --- | --- |
| Scripture Folio | A focused tool for reading and studying a text. More editorial than devotional. | A folded page with a marked passage. | Mulberry `#512D4C`, pale lavender `#D9C3DD`, paper `#FAF7FC`, annotation gold `#EDCA84`. |
| Daymark Bible | A warm, approachable name suggesting guidance and a place to return to. | An open book beneath a rising light. | Deep teal `#153E42`, amber `#FFBE55`, light teal `#7FAAA7`, paper `#FFF6E6`. |

For typography, Scripture Folio pairs a serif name with simple supporting text;
Daymark uses a friendly sans serif. Both marks use a simple silhouette that can
work at Home Screen sizes. The comparison uses Georgia and Avenir installed on
the development Mac; no font files are copied into the repository or app.

These were the initial alternatives before the user proposed SimpleScripture.
Scripture Folio emphasizes the reading, commentary and lexicon functions; its
longer Home Screen label should be reviewed on device. Daymark Bible is the
shorter-brand option, using Daymark as a possible Home Screen label.

Initial web searches on 5 October 2026 did not surface an exact Bible-app match
for these two full names. Daymark is already used by unrelated planning and
journaling apps; “scripture folio” is also a descriptive phrase for paper craft
products. Neither name has received an App Store Connect availability check or
trademark clearance. Do that before final adoption.

Other candidates were dropped when searches surfaced closely related uses:
Leaf and Lamp (Christian writing), Versefield (Scripture music), and Versefold
(an existing Bible app). Search results are preliminary screening, not an
ownership determination.

## Design intent

The SimpleScripture board shows its name, a large icon, palette and smaller icon
previews. Labels are left aligned; the icon silhouette does most of the work.
There are no inherited PocketSword images, stock marks, or copied competitor
graphics.

The original idea of cream backgrounds and generic book illustrations was
narrowed to two clear marks: a single marked page and a book carrying light.
The first palette uses plum rather than the old app's blue; the second gets
its personality from teal and amber. These are identity proposals, not a
request to tint every reader surface or change the current navigation.

The earlier editable alternatives are `scripture-folio.svg` and
`daymark-bible.svg`. Preview images use a rounded mask; the masters themselves
remain square. They are provisional artwork, not final App Store exports.

## Application integration

Completed on 5 October 2026:

- Home Screen/display name, bundle name, launch progress and failure messages,
  the morphology help message, and system Settings labels use SimpleScripture.
- Voice reference entry has been removed, including its reader action, sheet,
  speech recognition and model downloads, parser, feature flag, preference key,
  strings and tests. The app has no microphone permission description.
- The approved Gilded Folio PNG supplies both the app icon and About image.
  Legacy icon plist keys, inherited launch-image assets, unused bitmap controls,
  artwork sources and old screenshots have been removed from the current tree.
- About uses the fork's project/support destination and preserves upstream
  attribution and the offline notices described below.
- `Debug`, `Release` and `Distribution` build `SimpleScripture.app`, with
  executable `SimpleScripture`, bundle ID `org.timsam.SimpleScripture`, automatic
  signing and the existing fork team `7SZUJ26BQ2`. Test bundle IDs are
  `org.timsam.SimpleScriptureTests` and `org.timsam.SimpleScriptureUITests`.
- Debug and Release use the empty `SimpleScripture.entitlements`, allowing
  Personal Team device signing without iCloud. Reading history and bookmarks
  continue to persist locally. Distribution uses
  `SimpleScripture-Distribution.entitlements`, with iCloud key-value-store
  identifier `$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`; signing that
  configuration requires an Apple developer team that supports iCloud.
  The old CrossWire keychain group and hardcoded `get-task-allow` entitlement
  are removed; signing supplies the app's default identity.
- Project/target/scheme names and the Swift module remained `PocketSword` at
  this stage. On 4 November 2026, they were renamed to `SimpleScripture`,
  `SimpleScriptureTests` and `SimpleScriptureUITests` as appropriate. Test
  imports, app/delegate symbols, UI test names and bridging headers now use
  the new names. The shared `SimpleScripture` scheme builds both test bundles
  and retains `Distribution` for archives. The UI test target's application
  selection was refreshed to `SimpleScripture` so Xcode can launch it.
- `sword://` remains registered. Its URL-type name and the search-index
  background-task identifier now derive from the new bundle ID.

This is a **new app identity**, not an update to any old PocketSword bundle ID.
Existing PocketSword local containers, preferences, bookmarks and cloud history
are not automatically migrated, shared or deleted. Debug, Release and
Distribution use the same new local installation; iCloud is enabled only in
Distribution. Persisted keys
(including `reset_PocketSword`), serialization formats and routing code are
unchanged.

Verification to date:

- Xcode MCP build-for-testing passed after the icon cleanup and again after
  the product/identifier changes.
- All 27 focused tests passed, with zero skips: the 18 persisted-format tests,
  seven state/notice/routing/background tests, and two UI tests covering the
  four workspaces and Settings → About → offline credits/licenses.
- Resolved build settings match across all three configurations. The built
  simulator app contains the new names, generated iPhone/iPad icon entries,
  `sword` scheme and `org.timsam.SimpleScripture.search-index` task identifier.
  The initial build expanded a simulated key-value-store entitlement to
  `7SZUJ26BQ2.org.timsam.SimpleScripture`. A subsequent device-signing attempt
  established that the configured team is a Personal Team without iCloud
  support, so the entitlement is now restricted to Distribution.
- A clean, unsigned Distribution archive succeeded at
  `/tmp/simplescripture-rebrand.xcarchive`. Its compiled asset catalog contains
  only `AppIcon`, `SimpleScriptureAbout` and `AboutAccent`; only Gentium Plus
  and Ezra SIL fonts are included. Both content files, all nine notices and
  GPLv2 match their source bytes. The Settings labels and reset key were checked
  in the archived bundle. No `CompileC` tasks ran.
- On iPhone 18 Pro Max / iOS 27, the Home Screen shows Gilded Folio and the
  complete SimpleScripture label without truncation, alongside the separate
  old PocketSword installation. Settings → Apps shows the new name/icon and
  opens a SimpleScripture page with “Reset SimpleScripture?”; the toggle was
  left off. Screenshots and hierarchy captures are saved under
  `/Users/timsam/.codex/visualizations/2026/10/05/01a10b67-8f76-7ea1-92f4-81aeec954085/rebrand-runtime/`.
- After the Personal Team correction, Xcode completed a signed Debug
  `iphoneos` build using an app-specific managed development profile for
  `org.timsam.SimpleScripture`. The signed app contains the application/team
  identifiers and development debugging entitlement, with no iCloud
  entitlement. Device launch, Distribution signing, App Store registration
  and live iCloud sync remain unverified.
- After removing voice reference entry, Xcode MCP build-for-testing passed on
  iPhone 18 Pro / iOS 27. All ten focused tests passed with zero skips: seven
  unit tests covering the reference picker, reader controls, session startup
  and URL routing, plus three UI tests covering Bible/commentary switching,
  manual verse selection, and the display menu with chapter paging. The built
  simulator app has no voice symbols, voice localization keys, microphone or
  speech permission descriptions, or direct Speech/AVFoundation/AVFAudio
  framework dependencies.

The root README/public listing, name availability checks and broader visual
validation remain separate follow-up work. Release permission/source/data
requirements remain in the licensing assessment.

## Completed preparation

- Code2000 removed from source resources, Copy Resources, `UIAppFonts` and
  the font picker (8,377,000 bytes).
- Existing saved preferences are left unchanged. The user requested font
  removal without migrating existing selections.
- The initial Xcode MCP build-for-testing succeeded for iPhone 18 Pro, iOS 27.
- That built simulator app contains no Code2000 file and registers only
  Gentium Plus and Ezra SIL.
- The preference migration and its dedicated test were subsequently removed;
  settings code and tests now match the branch's base commit.
- Git history and the remaining licensing findings have not been changed.

## About page

The About page now uses the approved SimpleScripture name and Gilded Folio icon.
The icon supplies the pine-and-gold detail; a system-type header, adaptive
pine/sage links and native grouped rows keep the surrounding page quiet.
Text sizes follow Dynamic Type. The page describes the app as an independent
continuation of PocketSword and directs source/support links to the fork's
public GitHub repository.

Credits & licenses opens an offline index with PocketSword's original
contributors and copyright notices, GPLv2, all five bundled study modules,
Gentium Plus's OFL 1.1, Ezra SIL's OFL 1.1 and MIT/X11, and complete CC BY-SA 3.0.
Robinson's notice includes its CrossWire credit and format-conversion notice.
See [notice provenance and release boundaries](../licensing/about-notices.md).

Implementation: `Classes/SwiftUIAboutView.swift`, `Resources/Notices`, the
`SimpleScriptureAbout` and `AboutAccent` asset sets, and English localization.
The old About implementation was extracted from `SwiftUISupportingViews.swift`.

Validation: Xcode MCP build-for-testing and the three focused tests passed.
The final Xcode command-line run also passed all three tests, zero skips, after
the license reader's display wrapping was refined. Its UI test captures the
About page, credits index, GPL, Robinson, CC BY-SA and Ezra screens, and verifies
scrolling to Robinson's complete-license link, following it, and opening Ezra's
MIT/X11 notice.

Portrait screenshots on iPhone 18 Pro Max / iOS 27 were visually reviewed at the
default text size in light mode. Text is readable and rows/headings wrap without
clipping. Landscape, accessibility text sizes, dark mode and iPad remain
unverified. Xcode MCP's device sessions repeatedly disappeared after installation;
the visual evidence therefore comes from successful XCUITest screenshot
attachments. No source changes were needed for the session problem.

Final result bundle: `/tmp/simplescripture-about-final.xcresult`. The six screenshots
are in the chat's visualization directory under
`/Users/timsam/.codex/visualizations/2026/10/05/01a10b49-f1c6-7122-95c8-5742e15b0047/`.
