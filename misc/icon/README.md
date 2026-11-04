# SimpleScripture app icon

- [SimpleScripture App Icon.af](<SimpleScripture App Icon.af>) — editable
  Gilded Folio artwork migrated into the supplied Apple Illustrator template.
- [SimpleScripture App Icon.png](<SimpleScripture App Icon.png>) — clean,
  square 1024 × 1024 RGB export with an embedded sRGB profile and no alpha.
- [Preview](<SimpleScripture App Icon-preview.png>) — 320 px square preview.

The Affinity document retains Apple's grid and rounded icon shape as named
guide/preview layers. The sample circles were replaced by the original editable
`03_Gilded_Folio` and `01_Background` layers, including the book's component
groups and embedded textures.

The book is uniformly reduced from 896 to 832 units wide, centered at approximately
X 96, Y 93.3 on the 1024-unit artboard, so its corners clear Apple's icon shape.
The background covers the entire square. The original design remains in
[`docs/rebranding/simplescripture-heritage.af`](../../docs/rebranding/simplescripture-heritage.af)
and supplies the About and launch artwork.

For a clean export, hide both `GUIDE — Apple grid (hide for export)` and
`PREVIEW — Apple icon shape (hide for export)`. Export the named artboard as PNG
at 1024 × 1024 with sRGB and an opaque background. The Illustrator import uses
points and 300 dpi, so explicitly set the output pixel dimensions. The included
PNG was rendered in Affinity at 4267 px and downsampled with Lanczos to 1024 px;
its size, RGB format and profile were checked, along with 60, 120 and 256 px
previews.

The PNG is installed in
`PocketSword/Images.xcassets/AppIcon.appiconset/SimpleScripture.png`. All three
app build configurations use the `AppIcon` asset. After exporting an updated
1024 px PNG, copy it to that asset path as well.

The unused Icon Composer demo, stock Illustrator and Photoshop templates, and
their sample exports have been removed. The editable Affinity document retains
the guide layers described above, with the accompanying
[Apple Design Resources License](<Apple Design Resources License.rtf>).
The app uses the PNG asset; there is no `.icon` package.
