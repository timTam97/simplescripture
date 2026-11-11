//
//  PSChapterDocument.swift
//  PocketSword
//
//  The typed chapter document the native SwiftUI reader renders.
//  `PSChapterDocumentBuilder` (below) turns the store's token stream into these
//  values, and a `LazyVStack` renders them.
//
//  ── Why this is not "parse the HTML" ───────────────────────────────────────
//
//  Measured across all 2,378 chapter rows (61,190 non-empty expanded records plus
//  all 1,322 stored headings), the chapter vocabulary is a CLOSED SET of six inline
//  tags (`a` with class strongs/morph/n, `i.transChangeAdded`, `font size="-1"`,
//  the `<p><b>…</b></p>` title pair, `span.WordOfChrist`) with numeric-only
//  entities — no `blockquote`, `div`, `table`, `ruby`, `br` or `<!P>`. The token
//  stream is already a structured document, so the grammar gets a SECOND emitter
//  rather than an HTML parser.
//
//  ── The two emitters, and what holds them together ────────────────────────
//
//      tokens ──PSChapterExpander────────▶ HTML             (fixture-pinned oracle)
//      tokens ──PSChapterDocumentBuilder─▶ ChapterDocument  (the render path)
//
//  Both consume the same `PSChapterExpander.Options`, so a disabled toggle SKIPS
//  its token here exactly as it does there — including red-letter's exception,
//  where the option being off drops the span but KEEPS its recursively-expanded
//  payload. `PSChapterDocumentParityTests` asserts the two agree, chapter by
//  chapter, on plain text / verse anchors / entryCount / link targets. The HTML
//  side is byte-locked to fixtures captured from the SWORD engine, so it is a
//  real oracle and not a co-drifting sibling.
//
//  **Do not "simplify" either emitter into calling the other.** Their independence
//  is what makes the parity test mean anything.
//
//  ── The counter is not a verse number ─────────────────────────────────────
//
//  `ChapterVerse.number` is `PSChapterAssembler`'s loop counter `i`, not a verse
//  ordinal: it advances for slots the loop skips as empty or duplicate. It drives
//  the verse label, the verse-menu target and the bookmark-highlight lookup, and
//  it is what `chapter-loop-counters.tsv` pins. Deriving it from an array index
//  would silently renumber every chapter that has an empty slot.
//

import Foundation

// MARK: - Inline runs

/// What a span of verse text links to when tapped: the four `a` classes the
/// corpus contains, as a typed value the reader's link router switches on.
enum InlineLink: Equatable, Hashable {
    /// `class="strongs"` — a Strong's number. `type` is "Hebrew", "Greek", or ""
    /// (the corpus contains only the first two); `value` is the raw number as the
    /// lexicon keys it.
    case strongs(type: String, value: String)
    /// `class="morph"` — a morphological tag.
    case morph(type: String, value: String)
    /// `class="n"` (or `"x"`) — a footnote / cross-reference marker. `passage`
    /// arrives URL-encoded exactly as the anchor carried it;
    /// `PSContentReader.noteBody` decodes it.
    case note(kind: String, value: String, module: String, passage: String)
    /// A `<reference>` tag's `action=showRef` anchor. Unreachable for the shipped
    /// content (zero occurrences across 122,380 record expansions); carried so a
    /// future module cannot silently lose its links.
    case scriptRef(value: String)
    /// The verse NUMBER itself. Not produced by the token grammar — the renderer
    /// attaches it to the superscript label.
    case verseMenu(verse: Int)

    /// A compact URL for this link.
    ///
    /// SwiftUI only makes a span of `Text` tappable through
    /// `AttributedString.link`, so the typed value has to reach the view as a URL.
    /// `pslink://` is this app's own scheme: one component per field,
    /// percent-encoded once.
    var url: URL? {
        var components = URLComponents()
        components.scheme = "pslink"
        switch self {
        case .strongs(let type, let value):
            components.host = "strongs"
            components.path = "/\(type)/\(value)"
        case .morph(let type, let value):
            components.host = "morph"
            components.path = "/\(type)/\(value)"
        case .note(let kind, let value, let module, let passage):
            components.host = "note"
            components.path = "/\(kind)/\(value)/\(module)"
            // `passage` arrives URL-encoded off the anchor and
            // `PSContentReader.noteBody` decodes it itself, so it is carried as a
            // query item rather than a path component — a path component would be
            // double-encoded and then double-decoded.
            components.queryItems = [URLQueryItem(name: "passage", value: passage)]
        case .scriptRef(let value):
            components.host = "scriptref"
            components.queryItems = [URLQueryItem(name: "value", value: value)]
        case .verseMenu(let verse):
            components.host = "versemenu"
            components.path = "/\(verse)"
        }
        return components.url
    }

    /// The inverse of `url`. Returns nil for anything that is not a `pslink://`.
    init?(url: URL) {
        guard url.scheme == "pslink", let host = url.host else { return nil }
        // `pathComponents` leads with "/" for a rooted path; drop it.
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        func queryValue(_ name: String) -> String {
            query.first { $0.name == name }?.value ?? ""
        }

        switch host {
        case "strongs":
            // An empty `type` is legitimate (the `-` flag), so a two-component path
            // is the encoded form of type="" — hence the padding rather than a
            // count check that would reject it.
            guard parts.count >= 1 else { return nil }
            let type = parts.count >= 2 ? parts[0] : ""
            let value = parts.count >= 2 ? parts[1] : parts[0]
            self = .strongs(type: type, value: value)
        case "morph":
            guard parts.count >= 1 else { return nil }
            let type = parts.count >= 2 ? parts[0] : ""
            let value = parts.count >= 2 ? parts[1] : parts[0]
            self = .morph(type: type, value: value)
        case "note":
            guard parts.count >= 2 else { return nil }
            self = .note(kind: parts[0],
                         value: parts[1],
                         module: parts.count >= 3 ? parts[2] : "",
                         passage: queryValue("passage"))
        case "scriptref":
            self = .scriptRef(value: queryValue("value"))
        case "versemenu":
            guard let first = parts.first, let verse = Int(first) else { return nil }
            self = .verseMenu(verse: verse)
        default:
            return nil
        }
    }
}

/// The typographic axes a run can carry.
///
/// `transChangeAdded` (21,609 occurrences) is the italic grey "words supplied by
/// the translator"; `wordOfChrist` (2,038) is red-letter; `smallCaps` is
/// `font size="-1"`, applied by the view as a relative size.
struct InlineStyle: OptionSet, Hashable {
    let rawValue: Int

    static let transChangeAdded = InlineStyle(rawValue: 1 << 0)
    static let wordOfChrist     = InlineStyle(rawValue: 1 << 1)
    static let smaller          = InlineStyle(rawValue: 1 << 2)
    /// The `<b>` inside a title. Titles are their own block, but a heading's
    /// stored html can carry nested emphasis.
    static let bold             = InlineStyle(rawValue: 1 << 3)
    static let italic           = InlineStyle(rawValue: 1 << 4)
}

/// One contiguous span of text with uniform styling and at most one link.
struct InlineRun: Equatable, Hashable {
    var text: String
    var style: InlineStyle = []
    var link: InlineLink?

    /// A lexicon cross-link, when this run came from an ENTRY rather than a chapter
    /// (see `PSEntryDocument.swift`).
    ///
    /// A separate field rather than a case on `InlineLink`, because the two
    /// vocabularies are genuinely disjoint: a chapter record never contains a
    /// lexicon cross-link, and a lexicon entry never contains a verse-menu target.
    /// Merging them would put permanently-unreachable cases in both routers.
    var entryLink: EntryLink?

    /// A Strong's/morph anchor's own text is decorative — `<H0430>` / `(8804)` —
    /// and the view renders it superscript-small. Marking it lets the reader
    /// offer "hide markers" and lets the search highlighter skip it, neither of
    /// which is possible once it is flattened into the verse text.
    var isMarker: Bool = false

    init(text: String, style: InlineStyle = [], link: InlineLink? = nil,
         entryLink: EntryLink? = nil, isMarker: Bool = false) {
        self.text = text
        self.style = style
        self.link = link
        self.entryLink = entryLink
        self.isMarker = isMarker
    }
}

// MARK: - Blocks

/// A heading (`<p><b>…</b></p>` in the HTML).
///
/// Both sources land here: the loop's own PREVERSE injection (gated on
/// `headingsOn || canonical`) and a title token inside a record, which is always
/// non-canonical Interverse — see `PSChapterExpander`'s header for why those gate
/// differently.
struct ChapterHeading: Equatable, Hashable {
    var runs: [InlineRun]
    /// Canonical headings (Psalm titles) render as scripture rather than as
    /// editorial furniture, and are emitted even with headings off.
    var isCanonical: Bool
}

/// One verse row: the unit the `LazyVStack` renders and scrolls to.
///
/// `id` is `number`, so `ScrollPosition(id:)` addresses a verse by identity
/// rather than by measured offset — which is also why rotation needs no
/// re-measuring.
struct ChapterVerse: Identifiable, Equatable, Hashable {
    /// `PSChapterAssembler`'s loop counter — NOT a verse ordinal. See the header.
    var number: Int
    var id: Int { number }
    /// Headings that precede this verse.
    var headings: [ChapterHeading] = []
    var runs: [InlineRun] = []
    /// A bookmark highlight colour, as the `rgb(r,g,b)` string
    /// `PSBookmarks.getHighlightRGBColourString` returns. Kept as the persisted
    /// string form rather than a `Color` so the model stays free of SwiftUI.
    /// Always nil on a commentary: the builder looks it up for a Bible only.
    var highlightColour: String?
    /// The intro slot (`i == 0`) has no verse number and renders without a label.
    var isIntro: Bool { number == 0 }

    /// Whether any run has something to draw.
    ///
    /// False for an intro whose title was hoisted into `headings`, which has no
    /// runs left, and for one that is only whitespace. The row views ask this
    /// before laying out the text — an empty `Text` still takes a line — and the
    /// builder asks it before giving a bible intro a row at all.
    ///
    /// Computed, so the synthesized `Equatable` and memberwise `init` the parity
    /// tests build on are untouched.
    var hasVisibleText: Bool {
        runs.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Whether this verse OPENS a paragraph.
    ///
    /// The KJV marks paragraph starts with a pilcrow (`&#182;`), and it does so
    /// cleanly: measured over the whole module, all **2,970** pilcrows sit at the
    /// start of a verse's visible text and **none** appears mid-verse. So the
    /// marker is trustworthy as a paragraph boundary, which is what lets the
    /// flowing-prose layout break where the translators intended rather than at an
    /// arbitrary verse count.
    ///
    /// Verse 1 of every chapter also opens a paragraph, whether or not it carries a
    /// pilcrow.
    var startsParagraph: Bool = false
}

/// A run of verses that render as one flowing paragraph.
///
/// With verse-per-line OFF (the default) verses run together as continuous
/// prose with superscript numbers inline; only with it ON does each verse get
/// its own line. One row per verse unconditionally would make every chapter
/// verse-per-line and leave the toggle inert. So the document groups verses
/// into paragraphs, and the view picks its unit.
struct ChapterParagraph: Identifiable, Equatable {
    /// The first verse's number — stable, and what `ScrollPosition(id:)` targets in
    /// prose mode.
    var id: Int { verses.first?.number ?? 0 }
    var verses: [ChapterVerse]
    /// Headings that precede the paragraph, hoisted off its first verse so they
    /// render above it rather than inside the flowed text.
    var headings: [ChapterHeading] = []
}

/// A whole rendered chapter.
struct ChapterDocument: Equatable {
    var verses: [ChapterVerse] = []
    /// `PSChapterAssembler.Result.entryCount`, reproduced exactly — the loop
    /// counter after the final iteration, which is one past the last slot.
    var entryCount: Int = 0
    /// Set when the chapter has no content at all, carrying the same message the
    /// engine's own fallback showed.
    var emptyMessage: String?

    /// `verses` regrouped into flowing paragraphs, for the prose layout.
    ///
    /// Breaks where a verse carries the KJV's own pilcrow (and always before the
    /// first verse). A heading forces a break too: a heading belongs above a
    /// paragraph, never inside one.
    ///
    /// **This DERIVES on every call — it walks and reallocates every verse — so it
    /// must not be called from a SwiftUI view body.** It stays computed so this type
    /// keeps its synthesized `Equatable` and all-defaulted memberwise `init` (the
    /// parity tests build on both); the reader caches the result in
    /// `ReaderPaneModel.paragraphs`.
    var paragraphs: [ChapterParagraph] {
        var out: [ChapterParagraph] = []
        for verse in verses {
            let breaksHere = out.isEmpty
                || verse.startsParagraph
                || !verse.headings.isEmpty
            if breaksHere {
                var opening = verse
                let headings = opening.headings
                opening.headings = []
                out.append(ChapterParagraph(verses: [opening], headings: headings))
            } else {
                out[out.count - 1].verses.append(verse)
            }
        }
        return out
    }
}

// MARK: - Builder

/// Expands the store's token stream directly into a `ChapterDocument`.
///
/// A sibling of `PSChapterExpander` + `PSChapterAssembler`, sharing their option
/// gating and their loop shape. Where they append strings, this appends runs.
enum PSChapterDocumentBuilder {

    // The v2 token grammar. Deliberately duplicated from `PSChapterExpander`
    // rather than shared: the emitters are independent by design (see this
    // file's header). A test asserts the two tables agree.
    private static let strongsOpen: Character    = "\u{0001}"
    private static let strongsClose: Character   = "\u{0002}"
    private static let morphOpen: Character      = "\u{0003}"
    private static let morphClose: Character     = "\u{0004}"
    private static let noteOpen: Character       = "\u{0005}"
    private static let noteClose: Character      = "\u{0006}"
    private static let xrefOpen: Character       = "\u{0007}"
    private static let xrefClose: Character      = "\u{0008}"
    private static let titleOpen: Character      = "\u{000B}"
    private static let titleClose: Character     = "\u{000C}"
    private static let scripRefOpen: Character   = "\u{000E}"
    private static let scripRefClose: Character  = "\u{000F}"
    private static let redLetterOpen: Character  = "\u{0011}"
    private static let redLetterClose: Character = "\u{0012}"

    /// The per-render inputs, mirroring `PSChapterAssembler.Config`.
    struct Config {
        var kind: PSChapterAssembler.ModuleKind = .bible
        var headingsOn = true
        // No `versePerLine`: it is a layout choice, so the toggle drives row layout
        // in the view instead of the document. See `VerseRow` / `ParagraphRow`.
    }

    /// Build a document from one chapter's expanded-in-place records.
    ///
    /// Returns nil on a malformed token stream, matching
    /// `PSChapterExpander.expand`'s contract — the caller reports and shows the
    /// chapter as failed rather than rendering a partial verse.
    static func build(records: [String],
                      headings: [Int: [PSHeading]],
                      config: Config,
                      options: PSChapterExpander.Options,
                      highlightColour: (Int) -> String?,
                      emptyChapterMessage: @autoclosure () -> String,
                      reportFailures: Bool = true) -> ChapterDocument? {
        var document = ChapterDocument()
        var lastEntry = ""
        var i = 0

        for (slot, raw) in records.enumerated() {
            // Normalisation order is load-bearing (the parity test caught this).
            //
            // `PSChapterAssembler` runs its `*x`/`*n` replacement and its
            // leading-whitespace strip over the entry AS EXPANDED TO HTML. This builder
            // consumes the *token stream*, and neither step is interchangeable:
            //
            //  * The v2 sentinels are U+0001…U+0012, and several — U+000B (title open)
            //    and U+000C (title close) among them — ARE whitespace to
            //    `CharacterSet.whitespacesAndNewlines`. Stripping leading whitespace off
            //    the raw record eats the title token's opening sentinel on the 1,184 KJV
            //    records shaped `" " + <title>CHAPTER n.</title>`, so "CHAPTER 1." would
            //    show even with headings OFF.
            //  * `*x`/`*n` exist only in EXPANDED output (zero occurrences in any raw
            //    record), so applying that replacement here could only corrupt a verse
            //    that legitimately contains an asterisk followed by an n.
            //
            // So: expand first, then normalise the runs, and run the duplicate/empty
            // test over the joined post-expansion text — the same string the assembler
            // compares, which keeps the loop counter aligned with
            // `chapter-loop-counters.tsv`.
            guard var runs = runs(from: raw,
                                  options: options,
                                  reportFailures: reportFailures) else { return nil }

            // The assembler's leading-whitespace strip, over the expanded text.
            // Deliberate quirk: an entry that is ENTIRELY whitespace is left alone, so
            // it then fails the isEmpty test and still counts as an entry. A numbered
            // slot made of it IS emitted; a bible intro made of it is not given a row
            // (see the drop rule below).
            stripLeadingWhitespace(&runs)

            let thisEntry = runs.map(\.text).joined()

            if thisEntry != lastEntry && !thisEntry.isEmpty {
                var verse = ChapterVerse(number: i)

                // Preverse headings, gated `headingsOn || canonical` — the loop's
                // own injection, a different mechanism from the markup filter's
                // interverse emission (which arrives as a title token below).
                for heading in headings[slot] ?? [] where heading.bucket == "Preverse" {
                    guard config.headingsOn || heading.canonical else { continue }
                    guard !heading.html.isEmpty else { continue }
                    // A stored heading expands under `forHeading`, where the title wrapper is
                    // unconditional (see PSChapterExpander's header). The `*x`/`*n`
                    // replacement is not applied, for the same reason as above.
                    // `Self.runs(...)`: the local `runs` array shadows the static method here.
                    guard var headingRuns = Self.runs(from: heading.html,
                                                      options: options.forHeading,
                                                      reportFailures: reportFailures) else { return nil }
                    // A stored heading's own title wrapper is the heading itself, so
                    // the marker is stripped rather than hoisted.
                    for index in headingRuns.indices {
                        headingRuns[index].style.remove(.titleMarker)
                    }
                    guard headingRuns.contains(where: { !$0.text.isEmpty }) else { continue }
                    verse.headings.append(
                        ChapterHeading(runs: headingRuns, isCanonical: heading.canonical)
                    )
                }

                // A title token at the head of a record became its own `<p><b>`
                // block in the HTML. Hoist those into `headings` so the view can
                // lay them out as headings rather than inline bold text.
                let hoisted = hoistLeadingTitles(&runs)
                verse.headings.append(contentsOf: hoisted)

                verse.runs = runs
                // Bibles only, as in the assembler, whose lookup sits inside its
                // `case .bible`. A commentary row's number is the loop counter of the
                // first slot of a verse RANGE (MHCC Genesis 1 has rows 0, 1, 3, 6, …), so
                // a Bible bookmark on 1:3 would paint the whole "3-5" section and one on
                // 1:4 nothing.
                verse.highlightColour = config.kind == .bible ? highlightColour(i) : nil
                // The KJV's own paragraph marker. All 2,970 sit at the start of a verse's
                // visible text, so a leading pilcrow is a reliable "new paragraph here".
                // The glyph itself stays in the text.
                //
                // A COMMENTARY always breaks per verse: MHCC has no pilcrows (zero across
                // 28,904 records), so flowing it as prose would run a chapter into one
                // block, and the assembler wraps every commentary verse in its own `<p>`.
                verse.startsParagraph = config.kind == .commentary
                    || Self.opensParagraph(runs)

                // A bible intro with nothing to show is not a row.
                //
                // The assembler drops one whose whole content was a `<br />` (none in
                // the corpus), and emits a whitespace-only one as a space the HTML
                // collapsed to nothing. That is 1,184 of the KJV's 1,189 chapters with
                // headings off: slot 0 is `" " + <title>`, and the title token is
                // skipped. Kept as a row, that space is a `Text(" ")` — a blank line
                // above verse 1 in the verse-per-line layout (29.7 pt at the default
                // size) and a leading space in prose.
                //
                // Only the row is withheld. `i` and `lastEntry` advance below as for
                // any slot, so the loop counter and the duplicate test are untouched.
                if !(i == 0 && config.kind == .bible
                     && !verse.hasVisibleText && verse.headings.isEmpty) {
                    document.verses.append(verse)
                }
            }

            lastEntry = thisEntry
            i += 1
        }

        document.entryCount = i
        if document.verses.isEmpty {
            document.emptyMessage = emptyChapterMessage()
        }
        return document
    }

    /// Whether a verse's runs open with the KJV's paragraph pilcrow.
    ///
    /// Scans past leading whitespace and past marker runs: a paragraph-opening
    /// verse in a red-letter passage begins with the `WordOfChrist` space, and one
    /// with Strong's on may lead with `<3588>` (John 3:16 is exactly this shape).
    private static func opensParagraph(_ runs: [InlineRun]) -> Bool {
        for run in runs {
            if run.isMarker { continue }
            let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            return trimmed.hasPrefix("\u{00B6}")
        }
        return false
    }

    /// The assembler's leading-whitespace strip, applied across runs:
    ///
    ///  * it removes the whole leading whitespace RUN, not one character;
    ///  * an entry that is *entirely* whitespace is left untouched, so it then
    ///    fails the empty test and still counts as an entry. Reproduced
    ///    deliberately: a numbered slot made of it keeps its row, as it keeps its
    ///    `vv` anchor in the HTML. The bible INTRO made of it is the one that gets
    ///    no row — the engine showed it as a space that collapsed to nothing, in
    ///    all but five KJV chapters with headings off. See `build`'s drop rule.
    private static func stripLeadingWhitespace(_ runs: inout [InlineRun]) {
        // Nothing to cut back to → leave it exactly as it is.
        guard runs.contains(where: {
            $0.text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
        }) else { return }

        for index in runs.indices {
            if let firstNonWS = runs[index].text.rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.inverted) {
                if firstNonWS.lowerBound != runs[index].text.startIndex {
                    runs[index].text = String(runs[index].text[firstNonWS.lowerBound...])
                }
                return
            }
            // This run is all whitespace and something later is not: drop it whole
            // and keep going.
            runs[index].text = ""
        }
    }

    /// Moves title blocks that lead a record into headings, returning them.
    ///
    /// A title token expands to a block in both emitters; keeping it inline would
    /// render a chapter's title as bold text run into its first verse.
    ///
    /// **"Leads" means after the runs `stripLeadingWhitespace` blanked.** That
    /// strip empties a leading whitespace run and leaves it in the array, and every
    /// title in the corpus follows one: all 1,184 are slot 0 of a KJV chapter,
    /// shaped `" " + <title>`. Tested against `runs.first` alone, this hoisted
    /// nothing at all.
    ///
    /// Also where `.titleMarker` ends: a title that does not lead stays inline,
    /// bold, and loses the marker here, so none reaches the document.
    private static func hoistLeadingTitles(_ runs: inout [InlineRun]) -> [ChapterHeading] {
        var hoisted: [ChapterHeading] = []
        while true {
            // Step over the blanked runs, but only on the way to a title: a verse
            // with no title keeps exactly the runs it had. A zero-width run that
            // carries a link (`scripRef`) is content, and is not stepped over.
            let lead = runs.prefix { $0.text.isEmpty && $0.link == nil }.count
            guard lead < runs.count, runs[lead].style.contains(.titleMarker) else { break }
            runs.removeFirst(lead)
            // Collect the run span belonging to this title.
            var titleRuns: [InlineRun] = []
            while let run = runs.first, run.style.contains(.titleMarker) {
                var cleaned = run
                cleaned.style.remove(.titleMarker)
                titleRuns.append(cleaned)
                runs.removeFirst()
            }
            hoisted.append(ChapterHeading(runs: titleRuns, isCanonical: false))
        }
        for index in runs.indices {
            runs[index].style.remove(.titleMarker)
        }
        return hoisted
    }

    // MARK: Token expansion

    private static func closingToken(for open: Character) -> Character? {
        switch open {
        case strongsOpen:   return strongsClose
        case morphOpen:     return morphClose
        case noteOpen:      return noteClose
        case xrefOpen:      return xrefClose
        case titleOpen:     return titleClose
        case scripRefOpen:  return scripRefClose
        case redLetterOpen: return redLetterClose
        default:            return nil
        }
    }

    private static func gatingAxis(
        for open: Character
    ) -> ((PSChapterExpander.Options) -> Bool)? {
        switch open {
        case strongsOpen:        return { $0.strongs }
        case morphOpen:          return { $0.morphs }
        case noteOpen, xrefOpen: return { $0.footnotes }
        case titleOpen:          return { $0.headings }
        case redLetterOpen:      return { $0.redLetter }
        case scripRefOpen:       return nil
        default:                 return nil
        }
    }

    /// Expand a tokenised entry into runs.
    ///
    /// The literal text between tokens carries the only raw HTML the corpus has —
    /// `<i class="transChangeAdded">` and `<font size="-1">` — so it goes through
    /// `inlineRuns(fromMarkup:)` rather than being taken verbatim.
    static func runs(from input: String,
                     options: PSChapterExpander.Options,
                     reportFailures: Bool = true) -> [InlineRun]? {
        var out: [InlineRun] = []
        var literal = ""
        let chars = Array(input)
        var i = 0

        func flushLiteral(_ style: InlineStyle) {
            guard !literal.isEmpty else { return }
            out.append(contentsOf: inlineRuns(fromMarkup: literal, baseStyle: style))
            literal = ""
        }

        while i < chars.count {
            let c = chars[i]
            guard let closer = closingToken(for: c) else {
                literal.append(c)
                i += 1
                continue
            }
            guard let end = nextIndex(of: closer, in: chars, from: i + 1) else {
                PSContentStore.fail(
                    "unterminated token U+\(String(format: "%04X", c.unicodeScalars.first!.value))",
                    report: reportFailures)
                return nil
            }
            let payload = String(chars[(i + 1)..<end])
            flushLiteral([])

            if let axis = gatingAxis(for: c), !axis(options) {
                // Option off. Red-letter keeps its payload; the anchors have no
                // surviving text of their own. Identical to the HTML emitter.
                if c == redLetterOpen {
                    guard let inner = runs(from: payload, options: options,
                                           reportFailures: reportFailures) else { return nil }
                    out += inner
                }
                i = end + 1
                continue
            }

            switch c {
            case strongsOpen:
                guard let run = strongsRun(payload, reportFailures) else { return nil }
                out.append(run)
            case morphOpen:
                guard let run = morphRun(payload, reportFailures) else { return nil }
                out.append(run)
            case noteOpen, xrefOpen:
                let fields = payload.components(separatedBy: "|")
                guard fields.count == 3 else {
                    PSContentStore.fail("bad note payload: \(payload.debugDescription)",
                                        report: reportFailures)
                    return nil
                }
                let kind = c == xrefOpen ? "x" : "n"
                out.append(
                    InlineRun(text: kind,
                              style: .smaller,
                              link: .note(kind: kind, value: fields[0],
                                          module: fields[1], passage: fields[2]),
                              isMarker: true)
                )
            case titleOpen:
                guard let inner = runs(from: payload, options: options,
                                        reportFailures: reportFailures) else { return nil }
                // Marked so `hoistLeadingTitles` can lift it into a heading, and
                // bold because that is what `<p><b>` meant.
                out += inner.map {
                    var run = $0
                    run.style.insert(.bold)
                    run.style.insert(.titleMarker)
                    return run
                }
            case scripRefOpen:
                guard !payload.contains("|") else {
                    PSContentStore.fail("bad scripRef payload: \(payload.debugDescription)",
                                        report: reportFailures)
                    return nil
                }
                // The HTML emitter writes only the OPENING anchor here (the `</a>` comes
                // from the surrounding text), so the link's extent is unknowable from this
                // token. Unreachable for the shipped content; recorded as a zero-width run
                // so a future module's link is not silently dropped.
                out.append(
                    InlineRun(text: "", link: .scriptRef(value: payload))
                )
            case redLetterOpen:
                guard let inner = runs(from: payload, options: options,
                                        reportFailures: reportFailures) else { return nil }
                // The HTML carried a literal leading/trailing space inside the
                // span (`<span class="WordOfChrist"> ` / `</span> `); those are
                // part of the construct, so they are preserved as text.
                out.append(InlineRun(text: " ", style: .wordOfChrist))
                out += inner.map {
                    var run = $0
                    run.style.insert(.wordOfChrist)
                    return run
                }
                out.append(InlineRun(text: " ", style: .wordOfChrist))
            default:
                PSContentStore.fail("unhandled token", report: reportFailures)
                return nil
            }
            i = end + 1
        }
        flushLiteral([])
        return out
    }

    private static func nextIndex(of target: Character,
                                 in chars: [Character],
                                 from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    /// `\x01 G|H|- value \x02`, or the explicit `*type|value|shown` form.
    private static func strongsRun(_ payload: String, _ report: Bool) -> InlineRun? {
        let type: String
        let value: String
        let shown: String
        if payload.hasPrefix("*") {
            let fields = String(payload.dropFirst()).components(separatedBy: "|")
            guard fields.count == 3 else {
                PSContentStore.fail("bad strongs payload: \(payload.debugDescription)",
                                    report: report)
                return nil
            }
            (type, value, shown) = (fields[0], fields[1], fields[2])
        } else {
            guard let flag = payload.first else {
                PSContentStore.fail("empty strongs payload", report: report)
                return nil
            }
            value = String(payload.dropFirst())
            shown = value
            switch flag {
            case "G": type = "Greek"
            case "H": type = "Hebrew"
            case "-": type = ""
            default:
                PSContentStore.fail("bad strongs flag '\(flag)'", report: report)
                return nil
            }
        }
        // `<H0430>` — the angle brackets were `&lt;`/`&gt;` in the HTML.
        return InlineRun(text: "<\(shown)>",
                         style: .smaller,
                         link: .strongs(type: type, value: value),
                         isMarker: true)
    }

    /// `\x03 type|value \x04`, or the explicit `*type|value|shown` form. Both
    /// derivations `PSChapterExpander` reconstructs are reconstructed here too.
    private static func morphRun(_ payload: String, _ report: Bool) -> InlineRun? {
        let type: String
        let value: String
        var shown: String
        if payload.hasPrefix("*") {
            let fields = String(payload.dropFirst()).components(separatedBy: "|")
            guard fields.count == 3 else {
                PSContentStore.fail("bad morph payload: \(payload.debugDescription)",
                                    report: report)
                return nil
            }
            (type, value, shown) = (fields[0], fields[1], fields[2])
        } else {
            let fields = payload.components(separatedBy: "|")
            guard fields.count == 2 else {
                PSContentStore.fail("bad morph payload: \(payload.debugDescription)",
                                    report: report)
                return nil
            }
            value = fields[1]
            type = fields[0].isEmpty ? "strongMorph%3A" + value : fields[0]
            shown = value
            let v = Array(value)
            if v.count >= 3, v[0] == "T", v[1] == "H" || v[1] == "G",
               v[2].isNumber, v[2].isASCII {
                shown = String(v[2...])
            }
        }
        return InlineRun(text: "(\(shown))",
                         style: .smaller,
                         link: .morph(type: type, value: value),
                         isMarker: true)
    }

    // MARK: Literal markup

    /// Split literal inter-token text on the only two raw tags the chapter corpus
    /// contains, decoding numeric entities.
    ///
    /// Measured over the whole corpus: `<i class="transChangeAdded">` (21,568) and
    /// `<font size="-1">` (6,886) inside chapter records, and nothing else. An
    /// unrecognised tag is DROPPED rather than shown as literal text — the HTML
    /// renderer would not have displayed it either — and reported in debug so a
    /// vocabulary change cannot pass silently.
    static func inlineRuns(fromMarkup markup: String,
                           baseStyle: InlineStyle) -> [InlineRun] {
        var out: [InlineRun] = []
        var style = baseStyle
        var text = ""
        var i = markup.startIndex

        func flush() {
            guard !text.isEmpty else { return }
            out.append(InlineRun(text: decodeEntities(text), style: style))
            text = ""
        }

        while i < markup.endIndex {
            let c = markup[i]
            guard c == "<" else {
                text.append(c)
                i = markup.index(after: i)
                continue
            }
            guard let close = markup[i...].firstIndex(of: ">") else {
                // An unterminated `<` is literal text.
                text.append(contentsOf: markup[i...])
                break
            }
            let tag = String(markup[markup.index(after: i)..<close])
            flush()
            let lower = tag.lowercased()
            if lower.hasPrefix("i ") || lower == "i" {
                style.insert(lower.contains("transchangeadded") ? .transChangeAdded : .italic)
            } else if lower == "/i" {
                style.remove(.transChangeAdded)
                style.remove(.italic)
            } else if lower.hasPrefix("font") {
                style.insert(.smaller)
            } else if lower == "/font" {
                style.remove(.smaller)
            } else if lower == "b" {
                style.insert(.bold)
            } else if lower == "/b" {
                style.remove(.bold)
            } else if lower == "br" || lower == "br/" || lower == "br /" {
                text.append("\n")
            } else {
                PSContentStore.fail(
                    "chapter markup carries an unmodelled tag <\(tag)> — the native"
                    + " reader is dropping it; the corpus scan found only i/font",
                    report: false)
            }
            i = markup.index(after: close)
        }
        flush()
        return out
    }

    /// Decode the entity forms the corpus uses.
    ///
    /// Numeric only (`&#182;` the pilcrow, `&#8217;` the right single quote,
    /// `&#8211;` en dash, `&#230;` æ, a run of Hebrew letters), plus the five named
    /// ones the expander's own anchor templates emit (`&amp;` `&lt;` `&gt;`
    /// `&quot;` `&apos;`) so a run that came through markup reads correctly.
    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex

        while i < input.endIndex {
            guard input[i] == "&",
                  let semi = input[i...].firstIndex(of: ";"),
                  input.distance(from: i, to: semi) <= 10 else {
                out.append(input[i])
                i = input.index(after: i)
                continue
            }
            let body = String(input[input.index(after: i)..<semi])
            if body.hasPrefix("#") {
                let digits = String(body.dropFirst())
                let scalarValue: UInt32?
                if digits.lowercased().hasPrefix("x") {
                    scalarValue = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(digits)
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    i = input.index(after: semi)
                    continue
                }
            } else {
                switch body {
                case "amp":  out.append("&");  i = input.index(after: semi); continue
                case "lt":   out.append("<");  i = input.index(after: semi); continue
                case "gt":   out.append(">");  i = input.index(after: semi); continue
                case "quot": out.append("\""); i = input.index(after: semi); continue
                case "apos": out.append("'");  i = input.index(after: semi); continue
                case "nbsp": out.append("\u{00A0}"); i = input.index(after: semi); continue
                default: break
                }
            }
            out.append(input[i])
            i = input.index(after: i)
        }
        return out
    }
}

// MARK: - Internal style marker

extension InlineStyle {
    /// Marks runs that came from a title token, so `hoistLeadingTitles` can lift
    /// them out. Stripped before the document is returned, so it never reaches a
    /// view — hence `fileprivate`-by-convention rather than a public axis.
    static let titleMarker = InlineStyle(rawValue: 1 << 30)
}
