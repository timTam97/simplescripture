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
//  With the per-module verse-per-line pref OFF verses flow together as prose
//  with superscript numbers inline and a space between verses, breaking at the
//  KJV's pilcrows. With it ON (the default: an absent pref reads as on), each
//  verse is its own row. See `ChapterParagraph`.
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

        /// The search terms to highlight, each marked where the query matched it
        /// (`PSSearchQuery.highlightRanges(of:in:)`). Empty for a Strong's search,
        /// where the match is a lemma rather than text present in the verse.
        var highlightTerms: [SearchHighlightTerm] = []

        /// Resolve from the same defaults keys the HTML shell used, so a font
        /// chosen in Settings applies identically.
        static func current() -> Style {
            let defaults = UserDefaults.standard
            // A saved name the system cannot supply renders as an absent key
            // renders, in the default face; the stored value is left alone. See
            // `StudyFonts.resolved`.
            let name = StudyFonts.resolved(
                defaults.object(forKey: Defaults.fontNamePreference) as? String
            )
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

        /// `current()`, for a view body that has to follow a Settings change.
        ///
        /// `current()` reads `UserDefaults`, which SwiftUI does not track: a body
        /// that resolves its style that way does not depend on the font, and picks
        /// up a change only if something else happens to re-run it. The reader is
        /// told by notification and re-renders. A view that stays up behind
        /// Settings (an open Library dictionary entry) is told nothing.
        ///
        /// **The two reads are the subscription, and they are all this adds.** They
        /// look unused; drop one and the calling body no longer depends on that
        /// setting, silently. The values still come from `current()`, so there is
        /// one resolver, fallbacks included. That is safe because `SettingsModel`
        /// saves a new value inside its setter, before SwiftUI re-evaluates
        /// anything.
        @MainActor
        static func current(observing settings: SettingsModel) -> Style {
            _ = settings.fontName
            _ = settings.fontSize
            return current()
        }
    }

    /// The verse number as a superscript label (75% size, semibold, body colour).
    ///
    /// `tappable` carries the verse-menu link. It is false on a commentary:
    /// tapping a commentary verse number has never done anything.
    static func verseLabel(_ number: Int, style: Style,
                           tappable: Bool = false) -> AttributedString {
        // A trailing NARROW NO-BREAK SPACE (U+202F): the number never touches the
        // first word, and never parts from it either.
        //
        // It was a hair space (U+200A), which a line may break after. In flowing
        // prose that was the only place to break near a verse boundary, so a verse
        // that began a new line left its number at the end of the line above: 133
        // of 1,655 numbers over real KJV paragraphs (MEASURED, CoreText). With
        // U+202F, and the space `flowedPieces` puts between verses to break at
        // instead, none. A hair space plus a word joiner (U+2060) keeps the old
        // width exactly but still stranded 2. U+202F is the wider gap: 3.0 pt
        // against 1.25 pt at the default size, both from a fallback font (Georgia
        // has neither glyph).
        var label = AttributedString("\(number)\u{202F}")
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
           let background = Color(bookmarkRGBAString: colour),
           let last = out.characters.lastIndex(where: { !$0.isWhitespace }) {
            // One background from the verse's first character to its last visible
            // one, where the HTML had a span per block element.
            //
            // NOT over a trailing space. A verse that ends in Christ's words ends
            // in the red-letter span's own space (1,865 of the KJV's 2,038 spans
            // close at the end of their record), and the last verse of every
            // chapter ends in one of the record's. In flowing prose that space is
            // the gap before the next verse number — `flowedPieces` adds none
            // after it — so, painted, it carried the bookmark's colour up to the
            // number where every other verse's stops at its last word.
            let painted = out.startIndex..<out.characters.index(after: last)
            out[painted].backgroundColor = background
            out[painted].foregroundColor = .black
        }
        let terms = style.highlightTerms.filter { !$0.tokens.isEmpty }
        if !terms.isEmpty {
            applyHighlights(terms, over: verse.runs, to: &out)
        }
        return out
    }

    /// A flowing paragraph's verses, one piece per verse: its number, its text, and
    /// the space between it and the next.
    ///
    /// **The space is the engine's.** Its prose branch ended every entry with a
    /// newline (`<a class="verse">2</a>And the earth…\n`), which a browser showed as
    /// a space: `the earth. ²And the earth`. Joined with nothing between them, the
    /// verses read `the earth.²And`.
    ///
    /// The space is appended to the verse it follows, where the engine had it, and
    /// only after `text(for:style:)` has returned, so no bookmark colour and no
    /// search jacket covers it. A verse that already ends in a space keeps its own
    /// instead (the guard below), and `text(for:style:)` leaves a trailing space
    /// out of the bookmark colour for the same reason. The gap after the number
    /// does not break (see `verseLabel`), which leaves this space as the one place
    /// a line can break at a verse boundary: a number goes to the next line with
    /// its verse.
    ///
    /// Here rather than in `ParagraphRow` so the join can be read without a view
    /// host. Pinned by `testFlowedVersesAreSpacedAndNumbersStayWithTheirVerse`.
    static func flowedPieces(
        for paragraph: ChapterParagraph, style: Style, tappable: Bool
    ) -> [(verse: Int, text: AttributedString)] {
        var pieces: [(verse: Int, text: AttributedString)] = []
        for verse in paragraph.verses {
            var piece = AttributedString()
            if !verse.isIntro {
                piece += verseLabel(verse.number, style: style, tappable: tappable)
            }
            // The bookmark highlight is applied UNDER the search jacket — see
            // `text(for:style:)`.
            piece += text(for: verse, style: style)
            pieces.append((verse: verse.number, text: piece))
        }
        var gap = AttributedString(" ")
        gap.font = .custom(style.fontName, size: style.fontSize)
        for index in pieces.indices.dropLast() {
            // None after a piece with nothing in it (an intro that is only its
            // heading), and no second one after a piece that already ends in a space
            // (a verse that ends in Christ's words ends with the span's own).
            guard let last = pieces[index].text.characters.last,
                  !last.isWhitespace else { continue }
            pieces[index].text += gap
        }
        return pieces
    }

    /// A verse's words as the search highlight reads them: every run that is
    /// not a marker, joined with NOTHING between — and, for mapping a match
    /// back, each stretch's span in the words with where it starts in the
    /// rendered text (`attributed(runs:)`), all counted in unicode scalars.
    ///
    /// Nothing between, because a word can be two runs: "LORD" is a capital and
    /// three small ones. And no marker, because a marker's text is no word of
    /// the verse. The search matched the words of the store's plain text, and
    /// these cut into the same words for every verse of the Bible
    /// (`testTheReadersWordsAreTheWordsTheSearchMatched` reads `words` here).
    static func searchableWords(of runs: [InlineRun]) -> (
        words: String,
        stretches: [(inWords: Range<Int>, inText: Int)],
        renderedCount: Int
    ) {
        var words = ""
        var stretches: [(inWords: Range<Int>, inText: Int)] = []
        var wordsCount = 0
        var textCount = 0
        for run in runs where !run.text.isEmpty {
            let count = run.text.unicodeScalars.count
            if !run.isMarker {
                words += run.text
                stretches.append((inWords: wordsCount..<(wordsCount + count),
                                  inText: textCount))
                wordsCount += count
            }
            textCount += count
        }
        return (words, stretches, textCount)
    }

    /// Jacket each term in yellow (black text) wherever the query matched it.
    ///
    /// **Where that is, is not decided here.** `PSSearchQuery.highlightRanges`
    /// says, for the result row and for this alike: a term is the whole words
    /// the index holds for it, so `the` is not marked inside "there", and a
    /// word Fuzzy ran as a prefix is marked over every word that begins with it.
    /// A row and the chapter it opens mark the same words because they ask the
    /// same function.
    ///
    /// **The terms are matched against the verse's WORDS — its runs with the
    /// Strong's, morph and footnote markers left out — not against the rendered
    /// string.** The words are what the search matched and what its result row
    /// highlights. In the rendered string a marker follows nearly every word once
    /// Strong's is on (`beginning<07225> God`), so an exact phrase was never found
    /// there and the chapter opened with nothing highlighted; and a term could be
    /// found inside a marker's own text (`prep` in `(PREP)`).
    ///
    /// Each match is mapped back onto `text` one stretch of words at a time, so a
    /// marker inside a matched phrase is left as it was.
    ///
    /// `text` must be `attributed(runs:)` of the same runs, and the walk below
    /// MIRRORS it: one stretch of `run.text` per non-empty run, in order. Positions
    /// are counted in unicode scalars, because joining two runs can merge the
    /// Characters either side of the join but never the scalars. They become
    /// indices only at the point of use, so none is carried across a jacket: each
    /// jacket mutates the string, and an `AttributedString.Index` taken before a
    /// mutation is not promised to be valid after it.
    private static func applyHighlights(_ terms: [SearchHighlightTerm],
                                        over runs: [InlineRun],
                                        to text: inout AttributedString) {
        let (words, stretches, textCount) = searchableWords(of: runs)
        // Out of step with `attributed(runs:)`, a jacket would land on the wrong
        // letters or run off the end. No highlight is the better failure.
        guard textCount == text.unicodeScalars.count else {
            assertionFailure("applyHighlights is out of step with attributed(runs:)")
            return
        }

        let jacket = AttributeContainer()
            .backgroundColor(.yellow)
            .foregroundColor(.black)
        let scalars = words.unicodeScalars
        // The ranges come in reading order, so each one's place is counted on
        // from the one before and not from the start of the verse again.
        var counted = scalars.startIndex
        var lower = 0
        for found in PSSearchQuery.highlightRanges(of: terms, in: words) {
            lower += scalars.distance(from: counted, to: found.lowerBound)
            counted = found.lowerBound
            let upper = lower + scalars.distance(from: found.lowerBound,
                                                 to: found.upperBound)
            for stretch in stretches
            where stretch.inWords.lowerBound < upper
                && stretch.inWords.upperBound > lower {
                // The part of the match inside this stretch, moved from its
                // place in the words to its place in the text.
                let first = max(lower, stretch.inWords.lowerBound)
                let last = min(upper, stretch.inWords.upperBound)
                let start = text.index(
                    text.startIndex,
                    offsetByUnicodeScalars:
                        stretch.inText + first - stretch.inWords.lowerBound
                )
                let end = text.index(start, offsetByUnicodeScalars: last - first)
                text[start..<end].mergeAttributes(jacket)
            }
        }
    }

    /// A heading's text — `<p><b>` in the HTML.
    ///
    /// Bold PER RUN, not one bold font over the finished string. A font set on the
    /// whole string replaces each run's own: a Strong's or morph marker keeps its
    /// grey and its raise but is drawn at the title's size (`A Psalm<04210> of
    /// David<01732>` in full-size numbers), and the translators' supplied words
    /// lose their italic. The HTML had the same anchors inside its `<b>`, as 70%
    /// superscripts.
    ///
    /// All the heading text in the corpus already arrives bold from its title token;
    /// inserting it here is what stops a heading depending on that.
    static func text(for heading: ChapterHeading, style: Style) -> AttributedString {
        attributed(runs: heading.runs.map { run in
            var run = run
            run.style.insert(.bold)
            return run
        }, style: style)
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
            // A SOFT scroll edge effect under the floating tab bar, asked for by
            // name. Left on the automatic style this scroll view gets none at the
            // bottom (MEASURED, iOS 27.2 — a `List` under the same bar does), so
            // the chapter shows through the bar's glass at full contrast and the
            // selection lens refracts it on every tab change. The text still
            // scrolls under the bar; there it is blurred and faded.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
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

    /// Routes taps on the links in this view's text to the pane.
    ///
    /// Links reach the string as `pslink://` URLs and are turned back into typed
    /// `InlineLink`s here. An `openURL` environment override is used rather than
    /// `onOpenURL`: the latter is for URLs from outside the app, and would send a
    /// Strong's tap out through `AppSession`'s `sword://` router.
    ///
    /// **On EVERY `Text` that can carry a link, a heading's included.** A Psalm
    /// title has Strong's and morph markers of its own (116 of the KJV's 138
    /// canonical headings carry a Strong's token), and its row is a sibling of the
    /// verse text, not inside it — an override on the verse text does not reach
    /// it. Without this the title's markers are drawn like the ones in the verse
    /// below and a tap on one goes to the system, which has nothing registered
    /// for `pslink://`: nothing happens.
    ///
    /// `.handled` is claimed only for a link the pane takes. Anything else is left
    /// to the system; a `.handled` with no handler behind it swallows the tap.
    func routesChapterLinks(to pane: ReaderPaneModel) -> some View {
        environment(\.openURL, OpenURLAction { url in
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

/// Draws the text unchanged and records where each verse's runs were laid out, for
/// `VerseLayoutStore.verse(at:)` to answer with an offset from the top of the text.
///
/// Internal rather than private so the unit tests can render through it.
struct VerseTrackingTextRenderer: TextRenderer {
    let layoutStore: VerseLayoutStore?

    var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set {}
    }

    /// A fragment is its run's horizontal extent and its LINE's vertical extent,
    /// with nothing added to either. Both halves are measured (iOS 27.2), and they
    /// go together:
    ///
    /// - **Typographic bounds are already relative to the text view**, a run's and a
    ///   line's alike. With `line.origin` (the line's baseline) added on top, every
    ///   fragment sat at about twice its real y: the verse reported was the one half
    ///   as far into the paragraph, and none in its second half was ever reported.
    /// - **Every fragment on a line shares the line's extent**, so the store's
    ///   `order` tie-break returns the first verse on the topmost line. A verse
    ///   label is raised, and its own bounds start about 2 pt above the body text
    ///   beside it. At the runs' own heights, on a line holding the tail of verse
    ///   N-1 and the start of verse N, the gap above the line read N (the label's
    ///   bounds are the first below it) and the line itself read N-1 again: the
    ///   title stepped backwards once per verse boundary. Correcting the position
    ///   alone doubles those steps (11 against 5 over twelve verses), because the
    ///   whole table is then in reach.
    ///
    /// Pinned by `testVerseTrackingRendererRecordsFragmentsInTextViewCoordinates`
    /// and `testFlowingVerseTrackerNeverStepsBackwards`.
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var fragments: [VerseLayoutFragment] = []
        var order = 0

        for line in layout {
            let lineBounds = line.typographicBounds.rect
            for run in line {
                if let verse = run[VerseTextAttribute.self]?.verse {
                    let runBounds = run.typographicBounds.rect
                    fragments.append(
                        VerseLayoutFragment(
                            verse: verse,
                            rect: CGRect(
                                x: runBounds.minX,
                                y: lineBounds.minY,
                                width: runBounds.width,
                                height: lineBounds.height
                            ),
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
                HeadingRow(heading: heading, pane: pane, style: style)
            }
            // A paragraph can be the intro alone, with its title hoisted into the
            // heading above and no text left: 117 psalms open `PSALM n.` and then
            // break at verse 1's own title. That row is its heading. An empty `Text`
            // under it would still take a line, and the padding below it.
            if paragraph.verses.contains(where: { !$0.isIntro || $0.hasVisibleText }) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The verses of this paragraph, run together with their superscript numbers.
    ///
    /// What each verse contributes, and the space between two of them, is the
    /// renderer's: `ChapterTextRenderer.flowedPieces`. This tags each piece with
    /// its verse, for `VerseTrackingTextRenderer` to find it by.
    private var flowed: Text {
        var out = Text("")
        for piece in ChapterTextRenderer.flowedPieces(
            for: paragraph, style: style, tappable: pane.mode == .bible
        ) {
            let verseText = Text(piece.text).customAttribute(
                VerseTextAttribute(verse: piece.verse)
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
                HeadingRow(heading: heading, pane: pane, style: style)
            }
            // The intro has no label, and none of its own text once its title has
            // been hoisted into the heading above (`CHAPTER n.`, with Headings on).
            // That row is its heading. An empty `Text` under it would still take a
            // line, and the padding below it.
            if !verse.isIntro || verse.hasVisibleText {
                ChapterRunsText(text: Text(labelled), pane: pane, style: style)
                    .padding(.bottom, style.fontSize * 0.35)
            }
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

/// A heading above a verse or a paragraph: a chapter title, or a Psalm's own.
///
/// Takes the pane for its links alone (`routesChapterLinks(to:)`): a Psalm
/// title's Strong's and morph markers are as tappable as the verse's.
private struct HeadingRow: View {
    let heading: ChapterHeading
    let pane: ReaderPaneModel
    let style: ChapterTextRenderer.Style

    var body: some View {
        Text(ChapterTextRenderer.text(for: heading, style: style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, style.fontSize * 0.7)
            .padding(.bottom, style.fontSize * 0.3)
            .accessibilityAddTraits(.isHeader)
            .routesChapterLinks(to: pane)
    }
}

/// The verse text of a row, with its links routed to the pane
/// (`routesChapterLinks(to:)`).
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
            .routesChapterLinks(to: pane)
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
    ///
    /// The default is resolved when the PARENT's body builds this view, and a
    /// `UserDefaults` read subscribes that body to nothing. A parent that can
    /// stay on screen across a Settings change must pass
    /// `.current(observing:)` instead, as `DictionaryEntryView` does.
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
