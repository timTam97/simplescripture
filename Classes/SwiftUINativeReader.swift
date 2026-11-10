//
//  SwiftUINativeReader.swift
//  PocketSword
//
//  The native reading surface. `ChapterTextView` renders a `ChapterDocument`
//  (see `PSChapterDocument.swift`) into a `ScrollView` + `LazyVStack` of `Text`
//  views built from `AttributedString`.
//
//  ── Edge-to-edge ──────────────────────────────────────────────────────────
//
//  The chapter must SCROLL UNDER the chrome, not stop at it, without any line
//  being hidden at rest:
//
//      .contentMargins(.all, insets, for: .scrollContent)        // content inset
//      .ignoresSafeArea(edges: .vertical)                        // full-height view
//
//  The scroll VIEW is full-height, so text flows beneath the translucent bars;
//  the scroll CONTENT carries the safe-area insets. Dropping either one either
//  hides text behind the floating tab bar or letterboxes the reader.
//  `contentMargins` also provides the scroll room past the bottom chrome.
//
//  The side gutter is a content margin too, NOT padding inside the content. The
//  scroll view re-anchors to a row whenever lazy row heights settle, and it
//  aligns the row's leading edge with the content's. With the gutter as padding
//  that edge sat a gutter's width in, so the chapter could come to rest shifted
//  left by the gutter, flush against the screen edge (measured after paging: 1
//  chevron page in 120). As a margin, the aligned position IS the resting one.
//
//  ── Prose vs verse-per-line ───────────────────────────────────────────────
//
//  With the per-module verse-per-line pref OFF (the default) verses flow
//  together as prose with superscript numbers inline, breaking at the KJV's
//  pilcrows. With it ON, each verse is its own row. See `ChapterParagraph`.
//
//  ── Scroll position: identity, not pixels ─────────────────────────────────
//
//  `ScrollPosition(id:)` addresses a verse by identity and
//  `onScrollGeometryChange` reports where the reader is. Rotation needs no
//  re-measure, and there is no polling; the visible verse is tracked directly.
//

import SwiftUI

// MARK: - Rendering the document

/// Turns `ChapterDocument` values into `AttributedString`s.
///
/// Kept separate from the views so the mapping from a run's style to its
/// presentation is one place, and so it can be exercised without a view host.
enum ChapterTextRenderer {

    /// Styling inputs the reader supplies: one global font and size, resolved once
    /// per render.
    struct Style {
        var fontName: String
        var fontSize: CGFloat
        /// `createHTMLString`'s `line-height`: 1.4 on iPhone, 1.6 on iPad.
        var lineSpacingMultiple: CGFloat

        /// The terms to highlight, case-insensitively. Empty for a Strong's search,
        /// where the match is a lemma rather than text present in the verse.
        var highlightTerms: [String] = []

        /// Resolve from the same defaults keys the HTML shell used, so a font
        /// chosen in Settings applies identically.
        static func current() -> Style {
            let defaults = UserDefaults.standard
            var name = (defaults.object(forKey: Defaults.fontNamePreference) as? String)
                ?? AppConstants.defaultFontName
            if name.isEmpty { name = AppConstants.defaultFontName }
            let size = defaults.integer(forKey: Defaults.fontSizePreference)
            return Style(
                fontName: name,
                // The absent-key fallback is ONE constant, shared with
                // `SettingsStore.snapshot()` / `ensureFontSizeDefault()` (the Settings
                // slider's value). `LaunchCoordinator.resetPreferences()` removes the key
                // and nothing re-materializes it, so separate fallbacks would disagree.
                fontSize: CGFloat(size == 0 ? AppConstants.defaultFontSize : size),
                lineSpacingMultiple: UIDevice.current.userInterfaceIdiom == .phone
                    ? 1.4
                    : 1.6
            )
        }
    }

    /// The verse number as a superscript label (70% size, body colour).
    ///
    /// `tappable` carries the verse-menu link. It is false on a commentary:
    /// tapping a commentary verse number has never done anything.
    static func verseLabel(_ number: Int, style: Style,
                           tappable: Bool = false) -> AttributedString {
        // A trailing hair space so the number never touches the first word.
        var label = AttributedString("\(number)\u{200A}")
        // 0.75 and SEMIBOLD (not 0.7 regular): at 12pt in flowing prose, colour
        // alone does not distinguish a verse number from a grey Strong's marker, and
        // the chapter reads as one run of superscripts. Weight separates them
        // structurally, which also works for users who cannot tell the greys apart.
        label.font = .custom(style.fontName, size: style.fontSize * 0.75)
            .weight(.semibold)
        label.baselineOffset = style.fontSize * 0.32
        label.foregroundColor = .primary
        if tappable, let url = InlineLink.verseMenu(verse: number).url {
            label.link = url
        }
        return label
    }

    /// One verse's text: its runs, its bookmark highlight, and any search jacket.
    ///
    /// **The order is load-bearing: bookmark colour FIRST, search jacket over the
    /// top**, so yellow paints over the bookmark colour on the matching words only.
    /// Painting the bookmark colour over the finished string would repaint the whole
    /// verse and erase every match. It lives here rather than in the two row views
    /// so there is one copy and one order.
    static func text(for verse: ChapterVerse, style: Style) -> AttributedString {
        var out = attributed(runs: verse.runs, style: style)
        if let colour = verse.highlightColour,
           let background = Color(bookmarkRGBAString: colour) {
            // One background over the whole range — the same visible result as the
            // HTML's span per block element.
            out.backgroundColor = background
            out.foregroundColor = .black
        }
        for term in style.highlightTerms where !term.isEmpty {
            applyHighlight(term, to: &out)
        }
        return out
    }

    /// Jacket every case-insensitive occurrence of `term` in yellow (black text).
    private static func applyHighlight(_ term: String, to text: inout AttributedString) {
        let jacket = AttributeContainer()
            .backgroundColor(.yellow)
            .foregroundColor(.black)
        var searchRange = text.startIndex..<text.endIndex
        while let found = text[searchRange].range(of: term,
                                                  options: .caseInsensitive) {
            text[found].mergeAttributes(jacket)
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
    }

    /// A heading's text — `<p><b>` in the HTML.
    static func text(for heading: ChapterHeading, style: Style) -> AttributedString {
        var out = attributed(runs: heading.runs, style: style)
        out.font = .custom(style.fontName, size: style.fontSize).bold()
        return out
    }

    /// Map runs to an `AttributedString`, carrying links as `AttributeContainer`
    /// values so a tap can be routed without re-parsing anything.
    static func attributed(runs: [InlineRun], style: Style) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            guard !run.text.isEmpty else { continue }
            var piece = AttributedString(run.text)

            // Size and weight.
            var size = style.fontSize
            if run.style.contains(.smaller) {
                // Strong's / morph / note markers are 70% size. `font size="-1"` (two points
                // smaller) is rare enough in chapters that it is not modelled separately.
                size = style.fontSize * 0.7
            }
            var font = Font.custom(style.fontName, size: size)
            if run.style.contains(.bold) { font = font.bold() }
            if run.style.contains(.italic) || run.style.contains(.transChangeAdded) {
                font = font.italic()
            }
            piece.font = font

            // Colour. Order matters: red-letter wins over the grey of a marker, so a
            // Strong's number inside a WordOfChrist span renders red.
            if run.style.contains(.transChangeAdded) {
                piece.foregroundColor = .secondary          // i.transChangeAdded { color: gray }
            }
            if run.isMarker {
                piece.foregroundColor = .secondary          // a.strongs/.morph/.n { color: gray }
                piece.baselineOffset = size * 0.34          // vertical-align: super
            }
            if run.style.contains(.wordOfChrist) {
                piece.foregroundColor = .wordOfChrist
            }

            // `AttributedString.link` is the ONLY way to make a span of `Text`
            // tappable in SwiftUI, so the typed link is carried as a `pslink://`
            // URL and turned back into an `InlineLink` by the tap handler. No
            // underline.
            if let link = run.link, let url = link.url {
                piece.link = url
                piece.underlineStyle = nil
            }
            out += piece
        }
        return out
    }
}

extension Color {
    /// `span.WordOfChrist { color: #D03030 }`, with the dark-mode override the
    /// shell carried (`@media (prefers-color-scheme: dark) { #FF7070 }`).
    static let wordOfChrist = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.00, green: 0.44, blue: 0.44, alpha: 1)
                : UIColor(red: 0.82, green: 0.19, blue: 0.19, alpha: 1)
        }
    )

    /// Parse the `rgba(r,g,b,a)` string the bookmark store produces
    /// (`PSBookmarkFolder.rgbString(fromHexString:)`).
    init?(bookmarkRGBAString string: String) {
        guard string.hasPrefix("rgba(") || string.hasPrefix("rgb(") else { return nil }
        let body = string
            .replacingOccurrences(of: "rgba(", with: "")
            .replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let parts = body.components(separatedBy: ",")
        guard parts.count >= 3,
              let r = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let g = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              let b = Double(parts[2].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let alpha = parts.count > 3
            ? (Double(parts[3].trimmingCharacters(in: .whitespaces)) ?? 0.8)
            : 0.8
        self = Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: alpha)
    }
}

// MARK: - The reading surface

/// The native chapter view. Owns only presentation: the document, the scroll
/// position and the tap routing come from `ReaderPaneModel`.
struct ChapterTextView: View {
    let pane: ReaderPaneModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var pane = pane
        // The scroll view this body describes. Captured so each callback below can
        // say which scroll view it is reporting for: a page turn leaves the old one
        // on screen, still live, until its slide ends — see `scrollSurface`.
        let surface = pane.scrollSurface

        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = pane.document.emptyMessage {
                        EmptyChapterNotice(message: message)
                    } else if pane.versePerLine {
                        ForEach(pane.document.verses) { verse in
                            VerseRow(verse: verse, pane: pane, style: pane.textStyle)
                                .id(verse.number)
                                .tracksTopmostVerse(verse.number, pane: pane,
                                                    surface: surface)
                        }
                    } else {
                        ForEach(pane.paragraphs) { paragraph in
                            ParagraphRow(paragraph: paragraph, pane: pane,
                                         surface: surface, style: pane.textStyle)
                                .id(paragraph.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
                // Paragraphs and individual verses reuse the same numeric IDs.
                // Replace the lazy row stack when switching layouts so cached
                // paragraphs cannot remain alongside the new verse rows.
                .id(pane.versePerLine)
            }
            .scrollPosition($pane.scrollPosition)
            // Edge-to-edge (see the file header): the scroll view fills the window
            // (`ignoresSafeArea`) and the CONTENT carries the safe-area insets
            // (`contentMargins`), so no line is obscured at rest.
            //
            // `for: .scrollContent` insets the content rather than the indicators —
            // the default would also pull the scroll indicator inward.
            //
            // The side gutter belongs here as well, not as padding on the stack: see
            // the file header for the left-shifted landing that padding produces.
            .contentMargins(
                .all,
                EdgeInsets(top: proxy.safeAreaInsets.top,
                           leading: horizontalPadding,
                           bottom: proxy.safeAreaInsets.bottom,
                           trailing: horizontalPadding),
                for: .scrollContent
            )
            .ignoresSafeArea(edges: .vertical)
            .onScrollGeometryChange(for: ReaderScrollSample.self) { geometry in
                // The offset is `contentOffset.y + contentInsets.top` on purpose: that is
                // the persisted value and the space `ScrollPosition.scrollTo(y:)`
                // consumes. MEASURED (it reads like a bug): with a 200pt content margin
                // and a zero safe area, `scrollTo(y: 300)` lands at `contentOffset.y ==
                // 100`, and the reachable maximum is `contentSize.height -
                // containerSize.height` exactly. A plain `contentOffset.y` would drift
                // upward by the inset on every launch.
                //
                // The two heights let the model tell an unlaid-out scroll view's zero from
                // a real position, and a landed restore from one the chapter is too short
                // to honour. Observing them also fires the action as content settles,
                // which drains a pending restore deterministically instead of on a timer.
                ReaderScrollSample(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
            } action: { _, sample in
                pane.scrollOffsetChanged(sample, from: surface)
            }
            .onScrollPhaseChange { _, newPhase in
                // A finger on the reader abandons any restore still in flight, which
                // is what lets the restore gate be a gate rather than a timeout.
                if newPhase == .tracking || newPhase == .interacting {
                    pane.userBeganScrolling()
                }
            }
            // A chapter the reader pages to gets a NEW scroll view, not the old one
            // scrolled to the top — see `ReaderPaneModel.scrollSurface`. After every
            // scroll modifier, so the identity covers the scroll view they configure.
            .id(surface)
            // The swap is the page turn, and this is its slide.
            .transition(ChapterPageTransition(
                pane: pane,
                reduceMotion: reduceMotion,
                overhang: proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            ))
        }
        // Animates the swap only when THIS pane turned a page while showing. A
        // deferred page drained on a Bible/commentary switch bumps the surface
        // without a `pageTurn`, and is swapped in place.
        .animation(ChapterPageTransition.animation(reduceMotion: reduceMotion),
                   value: pane.pageTurn.count)
        // The identifier the XCUITests match on.
        .accessibilityIdentifier("reading.chapter-content")
    }

    /// Horizontal gutter: text pinned to the physical edge is unreadable in a
    /// full-width view. Applied as a scroll-content margin.
    private var horizontalPadding: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 16 : 20
    }
}

private extension View {
    /// Reports a single-row verse while it is the topmost visible one.
    ///
    /// Lives in the VIEW because only the view knows where a row sits. Without
    /// it `bibleVersePosition` would stay stale while the reader scrolls, taking
    /// the toolbar title and `.verse` relaunch restoration with it.
    func tracksTopmostVerse(_ verse: Int, pane: ReaderPaneModel,
                            surface: Int) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            // The row covers the top of the reading area (in the scroll view's own
            // space, where 0 is the top of the visible content).
            let frame = proxy.frame(in: .scrollView)
            return frame.minY <= 1 && frame.maxY > 1
        } action: { _, isTopmost in
            guard isTopmost else { return }
            pane.topmostVerseChanged(verse, from: surface)
        }
    }

    /// Reports the exact inline verse crossing the top of a flowing paragraph.
    func tracksTopmostVerse(
        fallbackVerse: Int,
        layoutStore: VerseLayoutStore,
        pane: ReaderPaneModel,
        surface: Int
    ) -> some View {
        onGeometryChange(for: CGFloat?.self) { proxy in
            let frame = proxy.frame(in: .scrollView)
            guard frame.minY <= 1, frame.maxY > 1 else { return nil }
            return 1 - frame.minY
        } action: { _, offset in
            guard let offset else { return }
            pane.topmostVerseChanged(
                layoutStore.verse(at: offset, fallback: fallbackVerse),
                from: surface
            )
        }
    }
}

struct VerseTextAttribute: TextAttribute {
    let verse: Int
}

struct VerseLayoutFragment: Equatable {
    let verse: Int
    let rect: CGRect
    let order: Int
}

final class VerseLayoutStore: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [VerseLayoutFragment] = []

    func replace(with fragments: [VerseLayoutFragment]) {
        lock.lock()
        self.fragments = fragments
        lock.unlock()
    }

    func verse(at verticalOffset: CGFloat, fallback: Int) -> Int {
        lock.lock()
        let snapshot = fragments
        lock.unlock()

        let intersecting = snapshot.filter {
            $0.rect.minY <= verticalOffset && $0.rect.maxY > verticalOffset
        }
        if let first = intersecting.min(by: { $0.order < $1.order }) {
            return max(1, first.verse)
        }

        let following = snapshot.filter { $0.rect.minY > verticalOffset }
        if let first = following.min(by: {
            if $0.rect.minY == $1.rect.minY {
                return $0.order < $1.order
            }
            return $0.rect.minY < $1.rect.minY
        }) {
            return max(1, first.verse)
        }

        return max(1, snapshot.max(by: { $0.order < $1.order })?.verse ?? fallback)
    }
}

private struct VerseTrackingTextRenderer: TextRenderer {
    let layoutStore: VerseLayoutStore?

    var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var fragments: [VerseLayoutFragment] = []
        var order = 0

        for line in layout {
            for run in line {
                if let verse = run[VerseTextAttribute.self]?.verse {
                    var rect = run.typographicBounds.rect
                    rect.origin.x += line.origin.x
                    rect.origin.y += line.origin.y
                    fragments.append(
                        VerseLayoutFragment(
                            verse: verse,
                            rect: rect,
                            order: order
                        )
                    )
                    order += 1
                }
            }
            context.draw(line)
        }
        layoutStore?.replace(with: fragments)
    }
}

/// One flowing paragraph: several verses concatenated, numbers inline.
private struct ParagraphRow: View {
    let paragraph: ChapterParagraph
    let pane: ReaderPaneModel
    /// The scroll surface this row belongs to — see `ChapterTextView.body`.
    let surface: Int
    let style: ChapterTextRenderer.Style

    @State private var verseLayoutStore = VerseLayoutStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(paragraph.headings.enumerated()), id: \.offset) { _, heading in
                HeadingRow(heading: heading, style: style)
            }
            ChapterRunsText(
                text: flowed,
                pane: pane,
                style: style,
                verseLayoutStore: verseLayoutStore
            )
                .tracksTopmostVerse(
                    fallbackVerse: paragraph.verses.first?.number ?? 1,
                    layoutStore: verseLayoutStore,
                    pane: pane,
                    surface: surface
                )
                .padding(.bottom, style.fontSize * 0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The verses of this paragraph, run together with their superscript numbers.
    private var flowed: Text {
        var out = Text("")
        for verse in paragraph.verses {
            var attributed = AttributedString()
            if !verse.isIntro {
                attributed += ChapterTextRenderer.verseLabel(
                    verse.number,
                    style: style,
                    tappable: pane.mode == .bible
                )
            }
            // The bookmark highlight is applied by the renderer, UNDER the search
            // jacket — see `ChapterTextRenderer.text(for:style:)`.
            attributed += ChapterTextRenderer.text(for: verse, style: style)
            let verseText = Text(attributed).customAttribute(
                VerseTextAttribute(verse: verse.number)
            )
            out = Text("\(out)\(verseText)")
        }
        return out
    }
}

/// One verse on its own row — the verse-per-line layout.
private struct VerseRow: View {
    let verse: ChapterVerse
    let pane: ReaderPaneModel
    let style: ChapterTextRenderer.Style

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(verse.headings.enumerated()), id: \.offset) { _, heading in
                HeadingRow(heading: heading, style: style)
            }
            ChapterRunsText(text: Text(labelled), pane: pane, style: style)
                .padding(.bottom, style.fontSize * 0.35)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelled: AttributedString {
        var out = AttributedString()
        if !verse.isIntro {
            out += ChapterTextRenderer.verseLabel(
                verse.number,
                style: style,
                tappable: pane.mode == .bible
            )
            out += AttributedString(" ")
        }
        out += ChapterTextRenderer.text(for: verse, style: style)
        return out
    }
}

private struct HeadingRow: View {
    let heading: ChapterHeading
    let style: ChapterTextRenderer.Style

    var body: some View {
        Text(ChapterTextRenderer.text(for: heading, style: style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, style.fontSize * 0.7)
            .padding(.bottom, style.fontSize * 0.3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A `Text` that routes taps on its links.
///
/// Links reach the string as `pslink://` URLs and are turned back into typed
/// `InlineLink`s here. An `openURL` environment override is used rather than
/// `onOpenURL`: the latter is for URLs from outside the app, and would send a
/// Strong's tap out through `AppSession`'s `sword://` router.
private struct ChapterRunsText: View {
    let text: Text
    let pane: ReaderPaneModel
    let style: ChapterTextRenderer.Style
    var verseLayoutStore: VerseLayoutStore?

    var body: some View {
        text
            .lineSpacing(style.fontSize * (style.lineSpacingMultiple - 1))
            .textRenderer(
                VerseTrackingTextRenderer(layoutStore: verseLayoutStore)
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard let link = InlineLink(url: url) else {
                    // Not one of ours — let the system have it. MHCC's own
                    // `sword://` scripture links arrive here.
                    return .systemAction
                }
                pane.handle(link: link)
                return .handled
            })
    }
}

// MARK: - Lexicon entries and footnotes

/// The native renderer for a lexicon entry or a footnote: a `ScrollView` of
/// `Text`, one per `EntryBlock`, inheriting the sheet's material.
struct EntryTextView: View {
    let document: EntryDocument
    /// Tapping a cross-link.
    ///
    /// When `nil` the link is left to the system rather than swallowed — see the
    /// `openURL` override below. Both call sites supply one; `nil` exists so a
    /// preview or a future read-only surface cannot silently eat a tap.
    var openLink: ((EntryLink) -> Void)?
    var topInset: CGFloat = 0
    /// Typography, resolved from the same two GLOBAL font preferences the chapter
    /// reader uses (`ChapterTextRenderer.Style.current()`), so footnotes and
    /// definitions follow the Settings size.
    var style: ChapterTextRenderer.Style = .current()
    /// Whether the body renders in the SYSTEM face instead of the user's font.
    /// Footnotes, morph entries and the Dictionary use the user's font; the
    /// Strong's definition deliberately uses the system face.
    var usesSystemFace = false
    /// The legibility floor for entry body text.
    ///
    /// A definition is dense reference prose, so at the bottom of the slider the
    /// raw preference would be too small. Above the floor the preference wins
    /// outright. The chapter text has no floor, so the bottom of the range
    /// deliberately moves one and not the other.
    static let minimumBodySize: CGFloat = 14

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(document.blocks) { block in
                    Text(attributed(block))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, blockSpacing(block))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, topInset)
            .padding(.bottom, 28)
        }
        .environment(\.openURL, OpenURLAction { url in
            // `.handled` is claimed ONLY when there is a handler: returning `.handled`
            // with no handler silently eats the tap on a link that looks live. Both
            // call sites pass `openLink`; this keeps a future surface that forgets to
            // degrade to the system's handling.
            guard let link = EntryLink(url: url), let openLink else {
                return .systemAction
            }
            openLink(link)
            return .handled
        })
        .textSelection(.enabled)
    }

    /// An empty block is the lexicons' paragraph spacing (a doubled `<br />`), so it
    /// contributes space rather than a blank line of text.
    private func blockSpacing(_ block: EntryBlock) -> CGFloat {
        block.runs.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            ? 8
            : 2
    }

    private func attributed(_ block: EntryBlock) -> AttributedString {
        var out = AttributedString()
        for run in block.runs where !run.text.isEmpty {
            var piece = AttributedString(run.text)
            // `.smaller` in an ENTRY is `<font size="-1">` (plus the Hebrew vowel
            // `<sup>`): two points smaller, NOT the chapter renderer's 0.7 (that is
            // the marker size, which does not occur in entries).
            //
            // The body size is the preference against a legibility FLOOR (see
            // `minimumBodySize`), so the bottom of the slider range is inert here
            // while the chapter text keeps shrinking.
            let base = max(style.fontSize, Self.minimumBodySize)
            var size = base
            if run.style.contains(.smaller) {
                size = max(base - 2, 9)
            }
            var font = usesSystemFace
                ? Font.system(size: size)
                : Font.custom(style.fontName, size: size)
            if run.style.contains(.bold) { font = font.bold() }
            if run.style.contains(.italic) || run.style.contains(.transChangeAdded) {
                font = font.italic()
            }
            piece.font = font
            // The raise is a RATIO of the resolved size (5/13 and -3/13), so it tracks
            // the font preference.
            if run.style.contains(.superscript) {
                piece.baselineOffset = size * 0.38
            }
            if run.style.contains(.subscript) {
                piece.baselineOffset = -size * 0.23
            }
            if let link = run.entryLink, let url = link.url {
                piece.link = url
                piece.foregroundColor = StudyPalette.accent
                piece.underlineStyle = .single
            }
            out += piece
        }
        return out
    }
}

private struct EmptyChapterNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.body.italic())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .accessibilityIdentifier("reading.empty-chapter")
    }
}
