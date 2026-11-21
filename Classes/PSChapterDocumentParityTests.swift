//
//  PSChapterDocumentParityTests.swift
//  SimpleScriptureTests
//
//  The native reader's DATA gate: `PSChapterDocumentBuilder` must agree with the
//  byte-locked HTML emitter about what a chapter says.
//
//  Two emitters over one grammar are only safe if something holds them together,
//  and this is it. The HTML side is a genuine oracle: it is pinned byte-for-byte
//  by `PSContentStoreTests`' chapter-body fixtures (captured from the SWORD engine,
//  which cannot be re-run) plus `chapter-loop-counters.tsv`. When these two agree,
//  the native reader agrees with the engine transitively.
//
//  COMPARED (per chapter):
//    * the plain text of every verse, after stripping tags from the HTML side;
//    * `entryCount` — the loop counter, which is not a verse number;
//    * the set of verse numbers, i.e. which slots produced a row at all;
//    * every link target, in document order (Strong's type+value, morph
//      type+value, note kind/value/module/passage).
//
//  NOT COMPARED: CSS, font sizes, the `<p>`/`<br />` structure — presentation the
//  native reader owns differently by design.
//
//  Tiering: the default tier covers a fixed sample chosen to hit every structural
//  feature (see `sampleRefs`) at BOTH option endpoints. `PSDOC_EXHAUSTIVE=1` walks
//  all 1,189 chapters × 2 modules × 2 endpoints (4,756 builds, ~30 s).
//  `testTheReadersWordsAreTheWordsTheSearchMatched` is tiered the same way (the
//  sample by default, every KJV chapter under the switch, ~8 s in all), and so
//  is `testTheReaderMarksTheWordsAStrongsNumberTags` (~21 s under the switch).
//

import XCTest
@testable import SimpleScripture

final class PSChapterDocumentParityTests: XCTestCase {

    private static var isExhaustive: Bool {
        ProcessInfo.processInfo.environment["PSDOC_EXHAUSTIVE"] != nil
    }

    // MARK: - Plumbing

    private func store() throws -> PSContentStore {
        guard let store = PSContentStore.shared else {
            throw XCTSkip("PSContentStore did not open")
        }
        return store
    }

    private func resolver() throws -> PSBookOSISResolver {
        guard let resolver = PSBookOSISResolver.shared else {
            throw XCTSkip("PSBookOSISResolver did not load")
        }
        return resolver
    }

    /// One chapter, rendered BOTH ways from the same records.
    ///
    /// The records are read once and handed to both emitters, so a store-level
    /// difference cannot masquerade as an emitter difference.
    private func renderBoth(
        module: String,
        ref: String,
        options: PSChapterExpander.Options,
        kind: PSChapterAssembler.ModuleKind
    ) throws -> (html: PSChapterAssembler.Result, document: ChapterDocument)? {
        let store = try store()
        let resolver = try resolver()
        guard let (book, chapter) = resolver.resolve(ref: ref) else {
            XCTFail("\(ref) did not resolve")
            return nil
        }
        guard let records = store.chapterRecords(module: module,
                                                 bookOsis: book.osisName,
                                                 chapter: chapter) else {
            // A wholly-empty chapter is omitted by the converter; both sides show
            // the same message, and there is nothing to compare.
            return nil
        }
        let headings = store.headings(module: module,
                                     bookName: book.longName,
                                     chapter: chapter)

        // ── HTML side ──
        var expanded: [String] = []
        expanded.reserveCapacity(records.records.count)
        for record in records.records {
            if record.isEmpty {
                expanded.append("")
                continue
            }
            guard let html = PSChapterExpander.expand(record, options: options) else {
                XCTFail("\(module) \(ref): a record failed to expand")
                return nil
            }
            expanded.append(html)
        }
        var config = PSChapterAssembler.Config()
        config.kind = kind
        config.versePerLine = false
        config.headingsOn = options.headings
        guard let htmlResult = PSChapterAssembler.assemble(
            records: expanded,
            headings: headings,
            config: config,
            headingHTML: { PSChapterExpander.expand($0.html, options: options.forHeading) },
            highlightColour: { _ in nil },
            emptyChapterMessage: "") else {
            XCTFail("\(module) \(ref): HTML assembly failed")
            return nil
        }

        // ── Native side ──
        var docConfig = PSChapterDocumentBuilder.Config()
        docConfig.kind = kind
        docConfig.headingsOn = options.headings
        guard let document = PSChapterDocumentBuilder.build(
            records: records.records,
            headings: headings,
            config: docConfig,
            options: options,
            highlightColour: { _ in nil },
            emptyChapterMessage: "") else {
            XCTFail("\(module) \(ref): document build failed")
            return nil
        }
        return (htmlResult, document)
    }

    // MARK: - Text normalisation

    /// Reduce the HTML body to the text a reader sees.
    ///
    /// Tags are dropped, entities decoded (through the builder's own decoder, so
    /// the two sides cannot disagree about `&#182;`), and whitespace collapsed. The
    /// verse-number anchors are removed first: the HTML carries the number as
    /// content (`<a …>12</a>`) whereas the native document carries it as
    /// `ChapterVerse.number`.
    ///
    /// **Block boundaries become whitespace, on both sides.** Stripping tags
    /// uniformly would glue `<p><b>CHAPTER 1.</b></p>In the beginning` into
    /// `CHAPTER 1.In the beginning`, while the document holds the heading and verse
    /// separately. Spacing across a block boundary is implied by structure in both
    /// representations, so both normalise it to one space. A dropped or duplicated
    /// word, or any difference inside a block, still fails.
    private func plainText(fromHTML html: String) -> String {
        var text = html
        // Verse-number anchors, both flavours the assembler emits.
        text = text.replacingOccurrences(
            of: "<a href=\"pocketsword:versemenu:[0-9]+\" id=\"vv[0-9]+\" class=\"verse\">[0-9]+</a>",
            with: "",
            options: .regularExpression)
        text = text.replacingOccurrences(
            of: "<a href=\"#verse[0-9]+\" id=\"vv[0-9]+\" class=\"verse\">[0-9]+</a>",
            with: "",
            options: .regularExpression)
        // Block-level tags carry an implied break; everything else is inline.
        text = text.replacingOccurrences(
            of: "</?(p|br|blockquote|div)\\s*/?>", with: " ",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "",
                                         options: .regularExpression)
        text = PSChapterDocumentBuilder.decodeEntities(text)
        return collapseWhitespace(text)
    }

    private func plainText(from document: ChapterDocument) -> String {
        var pieces: [String] = []
        for verse in document.verses {
            for heading in verse.headings {
                pieces.append(heading.runs.map(\.text).joined())
            }
            pieces.append(verse.runs.map(\.text).joined())
        }
        return collapseWhitespace(pieces.joined(separator: " "))
    }

    private func collapseWhitespace(_ input: String) -> String {
        let collapsed = input.replacingOccurrences(of: "\\s+", with: " ",
                                                   options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Link extraction

    /// Link targets from the HTML, in document order, as comparable strings.
    private func links(fromHTML html: String) -> [String] {
        var out: [String] = []
        let pattern = "<a href=\"passagestudy\\.jsp\\?([^\"]*)\" class=\"([a-z]+)\">"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = html as NSString
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let query = ns.substring(with: match.range(at: 1))
            let cls = ns.substring(with: match.range(at: 2))
            var fields: [String: String] = [:]
            for pair in query.replacingOccurrences(of: "&amp;", with: "&")
                .components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                fields[kv[0]] = kv[1]
            }
            switch cls {
            case "strongs":
                out.append("strongs:\(fields["type"] ?? ""):\(fields["value"] ?? "")")
            case "morph":
                out.append("morph:\(fields["type"] ?? ""):\(fields["value"] ?? "")")
            case "n", "x":
                out.append("note:\(cls):\(fields["value"] ?? ""):"
                           + "\(fields["module"] ?? ""):\(fields["passage"] ?? "")")
            default:
                break
            }
        }
        return out
    }

    private func links(from document: ChapterDocument) -> [String] {
        var out: [String] = []
        for verse in document.verses {
            for heading in verse.headings {
                out.append(contentsOf: heading.runs.compactMap { describe($0.link) })
            }
            out.append(contentsOf: verse.runs.compactMap { describe($0.link) })
        }
        return out
    }

    private func describe(_ link: InlineLink?) -> String? {
        switch link {
        case .strongs(let type, let value):
            return "strongs:\(type):\(value)"
        case .morph(let type, let value):
            return "morph:\(type):\(value)"
        case .note(let kind, let value, let module, let passage):
            return "note:\(kind):\(value):\(module):\(passage)"
        case .scriptRef:
            // Unreachable for the shipped corpus, and the HTML emitter writes only
            // an opening anchor with no class, so there is nothing to pair it with.
            return nil
        case .verseMenu:
            // Not produced by the token grammar: the renderer attaches it to the
            // superscript verse label. The HTML side's verse anchors are stripped and
            // verse identity is checked separately, so it is not counted here.
            return nil
        case .strongsWord:
            // Not produced by the token grammar either: the renderer attaches it to
            // a word in Underlined Words mode, from the word maps.
            return nil
        case nil:
            return nil
        }
    }

    // MARK: - The comparison

    /// Compare one chapter both ways, failing with the first divergence.
    private func assertParity(module: String,
                              ref: String,
                              options: PSChapterExpander.Options,
                              kind: PSChapterAssembler.ModuleKind,
                              label: String) throws -> Bool {
        guard let (html, document) = try renderBoth(module: module, ref: ref,
                                                    options: options, kind: kind) else {
            return true
        }

        // 1. The loop counter. This is the one `chapter-loop-counters.tsv` pins, so
        //    a mismatch here means the native builder renumbered a chapter.
        guard document.entryCount == html.entryCount else {
            XCTFail("\(label): entryCount \(document.entryCount) != HTML \(html.entryCount)")
            return false
        }

        // 2. Verse identity. Every `vv{i}` anchor the HTML emitted must be a row.
        let htmlVerses = verseNumbers(fromHTML: html.body)
        let docVerses = document.verses.filter { !$0.isIntro }.map(\.number)
        guard htmlVerses == docVerses else {
            XCTFail("""
                \(label): verse numbers differ.
                  HTML:     \(htmlVerses.prefix(20))… (\(htmlVerses.count))
                  document: \(docVerses.prefix(20))… (\(docVerses.count))
                """)
            return false
        }

        // 3. The text. This is the assertion that catches a dropped tag, a
        //    mis-decoded entity, or a gating axis wired to the wrong option.
        let htmlText = plainText(fromHTML: html.body)
        let docText = plainText(from: document)
        guard htmlText == docText else {
            let a = Array(docText), e = Array(htmlText)
            var i = 0
            while i < min(a.count, e.count), a[i] == e[i] { i += 1 }
            let lo = max(0, i - 60)
            XCTFail("""
                \(label): text differs at character \(i) \
                (HTML \(e.count) chars, document \(a.count)).
                  HTML:     …\(String(e[lo..<min(e.count, i + 60)]))…
                  document: …\(String(a[lo..<min(a.count, i + 60)]))…
                """)
            return false
        }

        // 4. Link targets, in order. A Strong's number routed to the wrong lexicon
        //    is invisible in the text but wrong on tap.
        let htmlLinks = links(fromHTML: html.body)
        let docLinks = links(from: document)
        guard htmlLinks == docLinks else {
            var i = 0
            while i < min(htmlLinks.count, docLinks.count),
                  htmlLinks[i] == docLinks[i] { i += 1 }
            XCTFail("""
                \(label): links differ at index \(i) \
                (HTML \(htmlLinks.count), document \(docLinks.count)).
                  HTML:     \(i < htmlLinks.count ? htmlLinks[i] : "<end>")
                  document: \(i < docLinks.count ? docLinks[i] : "<end>")
                """)
            return false
        }
        return true
    }

    private func verseNumbers(fromHTML html: String) -> [Int] {
        var out: [Int] = []
        let pattern = "id=\"vv([0-9]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = html as NSString
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let n = Int(ns.substring(with: match.range(at: 1))) else { return }
            out.append(n)
        }
        return out
    }

    // MARK: - Sample tier

    /// Chapters chosen to hit every structural feature the corpus has, rather than
    /// for coverage breadth. Each earns its place:
    ///
    ///  * `Genesis 1` — the ordinary case, dense Strong's + morph.
    ///  * `Genesis 4` — an entry with a footnote anchor.
    ///  * `Psalms 23` — canonical Psalm title (a heading emitted even with
    ///    headings OFF) and the highlighted-body fixture's chapter.
    ///  * `Psalms 119` — the acrostic, 22 interverse titles; the heaviest heading
    ///    chapter in the corpus.
    ///  * `Psalms 3` — a canonical title plus Selah pilcrows (`&#182;`).
    ///  * `Matthew 1` — a genealogy, and MHCC's own first chapter.
    ///  * `John 3` — red-letter (`WordOfChrist`) spans nesting Strong's, which is
    ///    the case where option-off must keep the payload.
    ///  * `Revelation 22` — the last chapter, and the `alloff` fixture's.
    private static let sampleRefs = [
        "Genesis 1", "Genesis 4", "Psalms 3", "Psalms 23",
        "Psalms 119", "Matthew 1", "John 3", "Revelation 22",
    ]

    func testNativeDocumentMatchesHTMLForSampleChaptersAllOptionsOn() throws {
        for ref in Self.sampleRefs {
            guard try assertParity(module: "KJV", ref: ref, options: .allOn,
                                   kind: .bible, label: "KJV \(ref) all-on") else { return }
        }
    }

    func testNativeDocumentMatchesHTMLForSampleChaptersAllOptionsOff() throws {
        for ref in Self.sampleRefs {
            guard try assertParity(module: "KJV", ref: ref, options: .allOff,
                                   kind: .bible, label: "KJV \(ref) all-off") else { return }
        }
    }

    /// The commentary path, which differs structurally: MHCC's verse anchor is
    /// `href="#verse%ld"` rather than a verse-menu link, and its records arrive
    /// through the `bodyref` indirection.
    func testNativeDocumentMatchesHTMLForCommentary() throws {
        for ref in ["Genesis 1", "Psalms 23", "Matthew 1"] {
            guard try assertParity(module: "MHCC", ref: ref, options: .allOn,
                                   kind: .commentary,
                                   label: "MHCC \(ref) all-on") else { return }
            guard try assertParity(module: "MHCC", ref: ref, options: .allOff,
                                   kind: .commentary,
                                   label: "MHCC \(ref) all-off") else { return }
        }
    }

    /// Each option axis alone, so a mis-wired gate cannot hide behind the two
    /// endpoints agreeing. `John 3` carries red-letter; `Psalms 119` headings;
    /// `Genesis 4` footnotes; `Genesis 1` Strong's and morph.
    func testEachOptionAxisAgreesIndependently() throws {
        var axes: [(String, PSChapterExpander.Options)] = []
        for (name, mutate) in [
            ("strongs off", { (o: inout PSChapterExpander.Options) in o.strongs = false }),
            ("morphs off", { (o: inout PSChapterExpander.Options) in o.morphs = false }),
            ("footnotes off", { (o: inout PSChapterExpander.Options) in o.footnotes = false }),
            ("redLetter off", { (o: inout PSChapterExpander.Options) in o.redLetter = false }),
            ("headings off", { (o: inout PSChapterExpander.Options) in o.headings = false }),
        ] as [(String, (inout PSChapterExpander.Options) -> Void)] {
            var options = PSChapterExpander.Options.allOn
            mutate(&options)
            axes.append((name, options))
        }

        for (name, options) in axes {
            for ref in ["Genesis 1", "Genesis 4", "Psalms 119", "John 3"] {
                guard try assertParity(module: "KJV", ref: ref, options: options,
                                       kind: .bible,
                                       label: "KJV \(ref) [\(name)]") else { return }
            }
        }
    }

    // MARK: - Exhaustive tier (PSDOC_EXHAUSTIVE=1)

    /// All 1,189 chapters × both modules × both endpoints — 4,756 builds. Catches a
    /// chapter whose shape nothing in the sample represents. Opt-in
    /// (`PSDOC_EXHAUSTIVE=1`).
    func testNativeDocumentMatchesHTMLForEveryChapter() throws {
        try XCTSkipUnless(Self.isExhaustive,
                          "set PSDOC_EXHAUSTIVE=1 to run the exhaustive tier")
        let resolver = try resolver()
        var checked = 0
        for book in resolver.books {
            for chapter in 1...book.chapterCount {
                let ref = "\(book.name) \(chapter)"
                for (module, kind) in [("KJV", PSChapterAssembler.ModuleKind.bible),
                                       ("MHCC", .commentary)] {
                    for options in [PSChapterExpander.Options.allOn, .allOff] {
                        let endpoint = options.strongs ? "all-on" : "all-off"
                        guard try assertParity(module: module, ref: ref,
                                               options: options, kind: kind,
                                               label: "\(module) \(ref) \(endpoint)") else {
                            return
                        }
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 4_000,
                             "expected ~4,756 chapter comparisons, ran \(checked)")
    }

    // MARK: - The grammar tables cannot drift apart

    /// Both emitters carry their own copy of the v2 token table, deliberately (see
    /// `PSChapterDocument.swift`'s header). This asserts the copies agree, by
    /// round-tripping a synthetic entry that uses every token through both sides.
    ///
    /// Without this, a typo'd sentinel in one table would only surface as a corpus
    /// chapter that happened to use that token — and `scripRef`, which the corpus
    /// never uses, would never surface at all.
    func testBothEmittersRecogniseTheSameTokenSentinels() throws {
        let cases: [(String, String)] = [
            ("strongs", "word\u{0001}H0430\u{0002}"),
            ("morph", "word\u{0003}|TH8804\u{0004}"),
            ("note", "word\u{0005}1|KJV|Genesis+4%3A1\u{0006}"),
            ("xref", "word\u{0007}1|KJV|Genesis+4%3A1\u{0008}"),
            ("title", "\u{000B}A Psalm of David\u{000C}"),
            ("redLetter", "\u{0011}I am\u{0001}G1510\u{0002}\u{0012}"),
            ("scripRef", "see\u{000E}Gen 1:1\u{000F}"),
        ]
        for (name, input) in cases {
            let html = PSChapterExpander.expand(input, options: .allOn)
            XCTAssertNotNil(html, "\(name): the HTML emitter rejected its own token")
            let runs = PSChapterDocumentBuilder.runs(from: input, options: .allOn)
            XCTAssertNotNil(runs, "\(name): the document builder rejected the token")

            // Neither side may leave a raw sentinel in its output — that is what a
            // table typo looks like.
            if let html {
                XCTAssertFalse(html.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" },
                               "\(name): the HTML emitter passed a control character through")
            }
            if let runs {
                let text = runs.map(\.text).joined()
                XCTAssertFalse(text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" },
                               "\(name): the document builder passed a control character through")
            }
        }
    }

    /// The corpus vocabulary claim this design rests on: chapter records contain
    /// only `i.transChangeAdded` and `font size="-1"` as raw markup.
    ///
    /// If a future store carried a `blockquote`, `div` or `br`, the native reader
    /// would silently drop it — so the claim is re-derived from the store on every
    /// run. Sampled for speed; the exhaustive tier covers the rest by comparing
    /// text.
    func testChapterRecordsCarryOnlyTheModelledRawTags() throws {
        let store = try store()
        let resolver = try resolver()
        let modelled: Set<String> = ["i", "/i", "font", "/font"]
        var seen: Set<String> = []

        for book in resolver.books.prefix(12) {
            for chapter in 1...min(book.chapterCount, 4) {
                for module in ["KJV", "MHCC"] {
                    guard let records = store.chapterRecords(
                        module: module,
                        bookOsis: book.osisName,
                        chapter: chapter) else { continue }
                    for record in records.records where !record.isEmpty {
                        for tag in Self.rawTags(in: record) {
                            seen.insert(tag)
                        }
                    }
                }
            }
        }

        let unexpected = seen.subtracting(modelled)
        XCTAssertTrue(unexpected.isEmpty,
                      "chapter records carry raw tags the native reader does not model: "
                      + "\(unexpected.sorted()). Model them in "
                      + "PSChapterDocumentBuilder.inlineRuns(fromMarkup:) or the "
                      + "reader will drop them silently.")
    }

    // MARK: - Lexicon entries

    /// A lexicon entry renders its definition, its cross-links, and NOT its own key.
    ///
    /// Pins three things about the preamble every entry opens with —
    /// `<a name="04399"><b>4399</b></a><br />`:
    ///
    ///  * the key number must not render (the popup header already shows it);
    ///  * clearing the pending text is not enough, because `<b>` flushes and the
    ///    number is already a run by the time `</a>` arrives;
    ///  * `.bold` must be reset, or it leaks into the Hebrew lemma that follows.
    ///
    /// It also pins the cross-link, which is why a lexicon entry is rendered
    /// natively rather than as static text.
    func testLexiconEntryDropsItsKeyAnchorAndKeepsCrossLinks() throws {
        let store = try store()
        // H4399 — the entry that exposed the `<b>`-inside-anchor case on device.
        let html = try XCTUnwrap(
            store.dictEntry(module: BundledModules.strongsHebrew, key: "04399"),
            "StrongsRealHebrew 04399 is missing from the store"
        )
        XCTAssertTrue(html.hasPrefix("<a name=\"04399\"><b>4399</b></a>"),
                      "the fixture's shape changed; this test targets the key anchor")

        let document = PSEntryDocumentBuilder.build(html: html)
        let text = document.blocks
            .map { $0.runs.map(\.text).joined() }
            .joined(separator: "\n")

        // The key number is gone from the BODY.
        XCTAssertFalse(text.hasPrefix("4399"),
                       "the entry's own key anchor still renders: \(text.prefix(40))")
        // The definition survived.
        XCTAssertTrue(text.contains("deputyship"),
                      "the definition is missing: \(text.prefix(80))")
        // The Hebrew lemma survived, and is not bold — `.bold` from the key anchor's
        // `<b>` must not leak past it.
        let lemmaRuns = document.blocks
            .flatMap(\.runs)
            .filter { $0.text.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF } }
        XCTAssertFalse(lemmaRuns.isEmpty, "the Hebrew lemma did not render")
        for run in lemmaRuns {
            XCTAssertFalse(run.style.contains(.bold),
                           "bold leaked out of the key anchor into the lemma")
        }

        // The cross-link to 4397 is a real link, and round-trips.
        let links = document.blocks.flatMap(\.runs).compactMap(\.entryLink)
        XCTAssertTrue(
            links.contains(.lexicon(module: BundledModules.strongsHebrew, key: "04397")),
            "the sword:// cross-link did not resolve; found \(links)"
        )
        for link in links {
            let url = try XCTUnwrap(link.url)
            XCTAssertEqual(EntryLink(url: url), link, "entry link round trip failed")
        }
    }

    /// A cross-link jackets ONLY its own anchor text, not the prose leading up to it.
    ///
    /// Regression: on H3899 ("lechem"), tapping the "3898" of "From 3898" once
    /// showed the ENTIRE definition as one link, because the `</a>` handler walked
    /// `runs` backwards with no lower bound.
    ///
    /// All 14,989 baked cross-link anchors wrap a bare number (0 non-digit inner
    /// texts), which makes this assertable corpus-wide — see
    /// `testEveryLexiconCrossLinkIsBoundToItsOwnAnchorText`.
    func testCrossLinkDoesNotSwallowTheProseBeforeIt() throws {
        let store = try store()
        let html = try XCTUnwrap(
            store.dictEntry(module: BundledModules.strongsHebrew, key: "03899"),
            "StrongsRealHebrew 03899 is missing from the store"
        )

        let document = PSEntryDocumentBuilder.build(html: html)
        let linked = document.blocks.flatMap(\.runs).filter { $0.entryLink != nil }
        XCTAssertFalse(linked.isEmpty, "the cross-links did not resolve at all")

        // Every linked run is a bare Strong's number. Before the fix the run holding
        // "; food (for man or {beast}) especially " carried a link too.
        for run in linked {
            let text = run.text.trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(
                text.isEmpty,
                "an empty run was linked"
            )
            XCTAssertTrue(
                text.allSatisfy(\.isNumber),
                "a cross-link swallowed prose: '\(run.text)'"
            )
        }

        // The definition text itself is present and NOT linked.
        let unlinkedText = document.blocks
            .flatMap(\.runs)
            .filter { $0.entryLink == nil }
            .map(\.text)
            .joined()
        XCTAssertTrue(unlinkedText.contains("victuals"),
                      "the definition body is missing or was absorbed into a link")
    }

    /// The Greek lexicon's lemma line survives the key-anchor preamble.
    ///
    /// All 8,674 StrongsRealHebrew entries put the `<br />` immediately after the
    /// key anchor; all 5,624 StrongsRealGreek entries carry a whole lemma line first
    /// — `<a name="03588">3588</a> <b>ὁ</b> [O(] {ho} \<i>ho</i>\<br/>`. An
    /// unconditional `skipNextBreak` would consume the Greek lemma's own break.
    func testGreekLexiconKeepsItsLemmaLineBreak() throws {
        let store = try store()
        let html = try XCTUnwrap(
            store.dictEntry(module: BundledModules.strongsGreek, key: "03588"),
            "StrongsRealGreek 03588 is missing from the store"
        )
        XCTAssertTrue(html.hasPrefix("<a name=\"03588\">3588</a> <b>"),
                      "the fixture's shape changed; this test targets the Greek preamble")

        let document = PSEntryDocumentBuilder.build(html: html)
        let texts = document.blocks.map { $0.runs.map(\.text).joined() }

        // The key number is still dropped — that fix must not regress.
        let joined = texts.joined(separator: "\n")
        XCTAssertFalse(joined.trimmingCharacters(in: .whitespaces).hasPrefix("3588"),
                       "the Greek key anchor still renders: \(joined.prefix(40))")

        // The lemma line is its OWN block, not run into the next one.
        let lemmaBlock = try XCTUnwrap(
            texts.first { $0.contains("{ho}") },
            "the Greek lemma line is missing: \(texts.prefix(3))"
        )
        XCTAssertFalse(
            lemmaBlock.contains("including the feminine"),
            "the lemma's own <br/> was swallowed: '\(lemmaBlock)'"
        )
        XCTAssertTrue(
            texts.contains { $0.contains("including the feminine") },
            "the second line is missing entirely: \(texts.prefix(3))"
        )
    }

    /// Corpus-wide: no cross-link anywhere jackets anything but its own number, and
    /// every one of them resolves to a real target. Walks all 15,824 entries; fast
    /// enough to keep in the default suite, and the failure it guards is silent.
    func testEveryLexiconCrossLinkIsBoundToItsOwnAnchorText() throws {
        let store = try store()
        var anchors = 0
        var checkedEntries = 0

        for module in BundledModules.lexicons {
            for key in store.dictKeys(module: module) {
                guard let html = store.dictEntry(module: module, key: key),
                      html.contains("href=") else { continue }
                checkedEntries += 1
                let document = PSEntryDocumentBuilder.build(html: html)
                for run in document.blocks.flatMap(\.runs) {
                    guard let link = run.entryLink else { continue }
                    anchors += 1
                    let text = run.text.trimmingCharacters(in: .whitespaces)
                    XCTAssertTrue(
                        !text.isEmpty && text.allSatisfy(\.isNumber),
                        "\(module) \(key): a link jackets non-anchor text '\(run.text)'"
                    )
                    // The target exists. A cross-link to a missing entry would open a blank
                    // sheet; it should never arise for the shipped corpus.
                    guard case .lexicon(let targetModule, let targetKey) = link else {
                        return XCTFail("\(module) \(key): unexpected link kind")
                    }
                    XCTAssertNotNil(
                        store.dictEntry(module: targetModule, key: targetKey),
                        "\(module) \(key): cross-link to missing \(targetModule)/\(targetKey)"
                    )
                }
            }
        }

        // The measured corpus: 14,989 cross-links over 11,442 entries that carry one.
        XCTAssertEqual(anchors, 14_989,
                       "the cross-link count changed; the store or the parser moved")
        XCTAssertEqual(checkedEntries, 11_442,
                       "the number of entries carrying a cross-link changed")
    }

    /// A cross-link followed from inside a popup resolves, and takes its `G`/`H`
    /// prefix from the TARGET module rather than the source.
    ///
    /// 317 of the baked links point from the Greek lexicon into the Hebrew one, so
    /// deriving the prefix from the entry being read would label those `G` and pick
    /// the Greek script font for a Hebrew lemma.
    func testFollowedCrossLinkTakesItsPrefixFromTheTargetModule() throws {
        let hebrew = try XCTUnwrap(
            PSInfoPopupContent.lexiconEntry(
                module: BundledModules.strongsHebrew,
                key: "03898",
                allowsSearch: true
            ),
            "the Hebrew cross-link target did not resolve"
        )
        XCTAssertEqual(hebrew.reference, "H3898")
        XCTAssertTrue(hebrew.isHebrew)
        XCTAssertEqual(hebrew.searchTerm, "H3898",
                       "find-all should stay available on a followed entry")

        let greek = try XCTUnwrap(
            PSInfoPopupContent.lexiconEntry(
                module: BundledModules.strongsGreek,
                key: "03588",
                allowsSearch: false
            ),
            "the Greek cross-link target did not resolve"
        )
        XCTAssertEqual(greek.reference, "G3588")
        XCTAssertFalse(greek.isHebrew)
        XCTAssertNil(greek.searchTerm,
                     "find-all must stay suppressed when the source suppressed it")

        // A miss returns nil rather than an empty sheet.
        XCTAssertNil(
            PSInfoPopupContent.lexiconEntry(
                module: BundledModules.strongsHebrew,
                key: "99999",
                allowsSearch: false
            ),
            "a missing cross-link target should not produce a popup"
        )
    }

    /// A footnote renders as text. The narrowest vocabulary of the three (`i` and
    /// `font` only, over 13,918 fields), and the one with no header to fall back on
    /// if it comes out empty.
    func testFootnoteBodyRendersAsText() throws {
        let reader = PSContentReader.shared
        // Genesis 4:1 carries KJV's first footnote; the passage arrives URL-encoded
        // off the anchor, which `noteBody` decodes itself.
        //
        // Unwrapped, not skipped: the note is baked (`notes_index` has
        // `KJV|Genesis 4:1|1`), so a nil here is the lookup or the passage decoding
        // breaking, and a skip would report that as a green run.
        let body = try XCTUnwrap(
            reader.noteBody(module: "KJV", osisRef: "Genesis+4%3A1", marker: "1"),
            "KJV Genesis 4:1 note 1 is in the store; a nil body is a lookup regression"
        )
        let document = PSEntryDocumentBuilder.build(html: body)
        let text = document.blocks.map { $0.runs.map(\.text).joined() }.joined()
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "the footnote rendered empty")
        XCTAssertFalse(text.contains("<"), "a tag survived into the rendered text")
    }

    /// A cross-link that spans a `<br />` keeps its link on BOTH halves, and puts it
    /// on neither the prose before the anchor nor the prose after it.
    ///
    /// `flushBlock()` starts a fresh `runs` array, so the `</a>` can no longer reach
    /// the runs emitted before the break; the pending link must be applied on the
    /// way out of the block, or the pre-break half silently goes dead.
    ///
    /// Synthetic on purpose: zero shipped `href` anchors span a `<br />`, so no
    /// store entry can pin this.
    func testCrossLinkSpanningALineBreakKeepsBothHalves() throws {
        let html = "From <a href=\"sword://StrongsRealHebrew/03898\">3898"
            + "<br />(bis)</a>; food"
        let target = EntryLink.lexicon(module: BundledModules.strongsHebrew,
                                       key: "03898")

        let document = PSEntryDocumentBuilder.build(html: html)

        // The break still splits the anchor across two blocks — the fix must not
        // "solve" this by keeping the anchor's content in one block.
        XCTAssertEqual(document.blocks.count, 2,
                       "the <br /> inside the anchor did not split the entry: "
                           + "\(document.blocks.map { $0.runs.map(\.text).joined() })")

        // Both halves of the anchor text are linked, in order.
        let linkedText = document.blocks
            .flatMap(\.runs)
            .filter { $0.entryLink == target }
            .map(\.text)
            .joined()
        XCTAssertEqual(linkedText, "3898(bis)",
                       "a cross-link spanning a line break lost a half")

        // And nothing outside the anchor is linked, in either block.
        for run in document.blocks.flatMap(\.runs) where run.entryLink != nil {
            XCTAssertFalse(run.text.contains("From"),
                           "the prose before the anchor was jacketed: '\(run.text)'")
            XCTAssertFalse(run.text.contains("food"),
                           "the prose after the anchor was jacketed: '\(run.text)'")
        }
    }

    // MARK: - Search highlighting

    /// Every term in the list gets highlighted, not just the first, and a marker
    /// run is left alone. The XCUITest cannot cover this because the highlight is
    /// an attribute rather than an accessibility value.
    @MainActor
    func testEveryHighlightTermIsAppliedAndMarkersAreSkipped() throws {
        var style = ChapterTextRenderer.Style.current()
        style.highlightTerms = ["God", "light"]

        let verse = ChapterVerse(
            number: 3,
            runs: [
                InlineRun(text: "And God said, Let there be light: "),
                InlineRun(text: "<H0430>", isMarker: true),
                InlineRun(text: "and there was light."),
            ]
        )

        let text = ChapterTextRenderer.text(for: verse, style: style)
        let string = String(text.characters)

        // Both terms, and every occurrence of each: "God" once, "light" twice.
        var highlighted: [String] = []
        for run in text.runs where run.backgroundColor != nil {
            highlighted.append(String(text[run.range].characters))
        }
        XCTAssertTrue(
            highlighted.contains("God"),
            "the first term was not highlighted — got \(highlighted)"
        )
        XCTAssertEqual(
            highlighted.filter { $0 == "light" }.count, 2,
            "the second term was not highlighted at every occurrence — "
                + "got \(highlighted)"
        )
        XCTAssertFalse(
            string.isEmpty,
            "the verse rendered empty"
        )

        // The marker is left alone: its text is a link's label, not a word of the
        // verse, so a term that occurs only there highlights nothing.
        style.highlightTerms = ["H0430"]
        let markerOnly = ChapterTextRenderer.text(for: verse, style: style)
        XCTAssertEqual(String(markerOnly.characters), string)
        for run in markerOnly.runs {
            XCTAssertNil(
                run.backgroundColor,
                "a term was highlighted inside a marker: "
                    + "'\(String(markerOnly[run.range].characters))'"
            )
        }
    }

    /// An empty term list highlights nothing — the state a Strong's search leaves
    /// (the match is a lemma, not text in the verse), and the state chapter paging
    /// restores.
    @MainActor
    func testNoHighlightTermsLeavesTheVerseUnmarked() throws {
        var style = ChapterTextRenderer.Style.current()
        style.highlightTerms = []

        let verse = ChapterVerse(
            number: 1,
            runs: [InlineRun(text: "In the beginning God created the heaven.")]
        )

        let text = ChapterTextRenderer.text(for: verse, style: style)
        for run in text.runs {
            XCTAssertNil(
                run.backgroundColor,
                "an empty term list still highlighted "
                    + "\(String(text[run.range].characters))"
            )
        }

        XCTAssertEqual(
            SearchModel.highlightTerms(
                query: "H430", matchType: .AndSearch, fuzzy: false, strongs: true
            ),
            [],
            "a Strong's query must contribute no highlight terms"
        )
    }

    /// A bookmarked verse keeps the search jacket on its matching words.
    ///
    /// The bookmark colour is painted UNDER the jacket. Painting it over the
    /// finished string erases every match, which shows only when a verse is both
    /// bookmarked and searched.
    ///
    /// Compares colours against each other rather than naming `Color.yellow`, so
    /// this file needs no `import SwiftUI`.
    @MainActor
    func testBookmarkHighlightDoesNotEraseTheSearchJacket() throws {
        var style = ChapterTextRenderer.Style.current()
        style.highlightTerms = ["light"]

        let verse = ChapterVerse(
            number: 3,
            runs: [InlineRun(text: "And God said, Let there be light: and it was so.")],
            highlightColour: "rgba(255,204,0,0.8)"
        )

        let text = ChapterTextRenderer.text(for: verse, style: style)
        let allRuns = Array(text.runs)

        // The bookmark colour, taken from a run the search term does not cover.
        //
        // If the bookmark colour is painted OVER the finished string instead of under
        // it, every run ends up with one uniform background and the whole verse
        // coalesces into a single run that contains the term — so this guard is the
        // first thing that trips, not the jacket assertion below.
        guard let bookmarked = allRuns.first(where: {
            !String(text[$0.range].characters).contains("light")
        })?.backgroundColor else {
            return XCTFail(
                "no run outside the search term carries its own background, in "
                    + "\(allRuns.count) run(s): either the bookmark colour was never "
                    + "applied, or it was painted over the jacket and erased it"
            )
        }

        var jacketed: [String] = []
        for run in allRuns {
            let piece = String(text[run.range].characters)
            XCTAssertNotNil(
                run.backgroundColor,
                "the bookmark background missed '\(piece)'"
            )
            if run.backgroundColor != bookmarked {
                jacketed.append(piece)
            }
        }

        XCTAssertEqual(
            jacketed, ["light"],
            "the bookmark background overwrote the search jacket"
        )
    }

    /// Tag NAMES (lowercased, attributes dropped) appearing literally in a record.
    private static func rawTags(in record: String) -> [String] {
        var out: [String] = []
        var i = record.startIndex
        while let open = record[i...].firstIndex(of: "<") {
            guard let close = record[open...].firstIndex(of: ">") else { break }
            let body = record[record.index(after: open)..<close]
            let name = body.prefix { !$0.isWhitespace }
            out.append(String(name).lowercased())
            i = record.index(after: close)
            if i >= record.endIndex { break }
        }
        return out
    }

    // MARK: - Bookmark highlights

    /// One chapter rendered both ways with a lookup that calls EVERY verse
    /// bookmarked, recording which verses each emitter asked it about.
    ///
    /// `renderBoth` hands both emitters `{ _ in nil }`, which is why the parity
    /// comparison says nothing about highlights.
    private func renderBothAskingForHighlights(
        module: String,
        ref: String,
        kind: PSChapterAssembler.ModuleKind,
        colour: String
    ) throws -> (html: PSChapterAssembler.Result, document: ChapterDocument,
                 askedByAssembler: [Int], askedByBuilder: [Int]) {
        let store = try store()
        let resolver = try resolver()
        let options = PSChapterExpander.Options.allOn
        let (book, chapter) = try XCTUnwrap(resolver.resolve(ref: ref),
                                            "\(module) \(ref) did not resolve")
        let chapterRecords = try XCTUnwrap(
            store.chapterRecords(module: module, bookOsis: book.osisName,
                                 chapter: chapter),
            "\(module) \(ref) has no records")
        let records = chapterRecords.records
        let headings = store.headings(module: module, bookName: book.longName,
                                      chapter: chapter)

        // ── HTML side ──
        var expanded: [String] = []
        for record in records {
            if record.isEmpty {
                expanded.append("")
                continue
            }
            let expandedRecord = try XCTUnwrap(
                PSChapterExpander.expand(record, options: options),
                "\(module) \(ref): a record failed to expand")
            expanded.append(expandedRecord)
        }
        var config = PSChapterAssembler.Config()
        config.kind = kind
        config.versePerLine = false
        config.headingsOn = options.headings
        var askedByAssembler: [Int] = []
        let assembled = PSChapterAssembler.assemble(
            records: expanded,
            headings: headings,
            config: config,
            headingHTML: { PSChapterExpander.expand($0.html, options: options.forHeading) },
            highlightColour: { verse in
                askedByAssembler.append(verse)
                return colour
            },
            emptyChapterMessage: "")
        let html = try XCTUnwrap(assembled, "\(module) \(ref): HTML assembly failed")

        // ── Native side ──
        var docConfig = PSChapterDocumentBuilder.Config()
        docConfig.kind = kind
        docConfig.headingsOn = options.headings
        var askedByBuilder: [Int] = []
        let built = PSChapterDocumentBuilder.build(
            records: records,
            headings: headings,
            config: docConfig,
            options: options,
            highlightColour: { verse in
                askedByBuilder.append(verse)
                return colour
            },
            emptyChapterMessage: "")
        let document = try XCTUnwrap(built, "\(module) \(ref): document build failed")

        return (html, document, askedByAssembler, askedByBuilder)
    }

    /// The bookmark highlight is looked up for a Bible only — by BOTH emitters.
    ///
    /// The assembler's lookup sits inside its `case .bible`. The builder asked for
    /// every row, and a commentary row's number is the loop counter of the first
    /// slot of a verse RANGE (MHCC Genesis 1 has rows 0, 1, 3, 6, 14, 20, 26, 29,
    /// 31). So a Bible bookmark on Genesis 1:3 painted the whole "3-5" section of
    /// the commentary in its folder's colour, and one on 1:4 painted nothing.
    ///
    /// The KJV case is the control — it must keep asking, and keep painting.
    func testBookmarkHighlightIsLookedUpForABibleOnlyInBothEmitters() throws {
        let colour = "rgba(255,204,0,0.8)"
        let cases: [(String, String, PSChapterAssembler.ModuleKind)] = [
            ("MHCC", "Genesis 1", .commentary),
            ("MHCC", "John 3", .commentary),
            ("KJV", "Genesis 1", .bible),
        ]

        for (module, ref, kind) in cases {
            let label = "\(module) \(ref)"
            let rendered = try renderBothAskingForHighlights(
                module: module, ref: ref, kind: kind, colour: colour)
            let rows = rendered.document.verses.map(\.number)
            let painted = rendered.document.verses
                .filter { $0.highlightColour != nil }
                .map(\.number)

            XCTAssertEqual(
                rendered.askedByBuilder, rendered.askedByAssembler,
                "\(label): the builder looked up bookmarks for verses the assembler did not")

            switch kind {
            case .commentary:
                XCTAssertEqual(
                    painted, [],
                    "\(label): commentary rows carry a Bible bookmark's colour")
                XCTAssertFalse(
                    rendered.html.body.contains("highlightedVerse"),
                    "\(label): the oracle highlighted a commentary; this test's premise moved")
            case .bible:
                XCTAssertFalse(rows.isEmpty, "\(label): the chapter built no rows")
                XCTAssertEqual(
                    painted, rows,
                    "\(label): a bookmarked Bible verse lost its colour")
                XCTAssertTrue(
                    rendered.html.body.contains("highlightedVerse"),
                    "\(label): the oracle did not highlight a Bible; this test's premise moved")
            }
        }
    }

    // MARK: - The intro slot and its title

    /// The joined text of each heading.
    private func headingTexts(_ headings: [ChapterHeading]) -> [String] {
        headings.map { $0.runs.map(\.text).joined() }
    }

    /// The text of every run, in a verse or a heading, that still carries the
    /// builder's internal title marker.
    private func runsCarryingTheTitleMarker(in document: ChapterDocument) -> [String] {
        document.verses
            .flatMap { $0.runs + $0.headings.flatMap(\.runs) }
            .filter { $0.style.contains(.titleMarker) }
            .map(\.text)
    }

    /// A title token that leads a record becomes a HEADING, not bold text in the
    /// verse.
    ///
    /// Every title in the KJV sits in slot 0 as `" " + <title>` — 1,184 chapters.
    /// The leading-whitespace strip blanks that space but leaves its run in the
    /// array, and the hoist looked only at the first run, so it never fired. With
    /// Headings on and Verse Per Line off the chapter opened `CHAPTER 1.`,
    /// superscript 1, `In the beginning` as one line of prose, and the builder's
    /// internal `.titleMarker` reached the view.
    ///
    /// The parity comparison cannot see any of it: it joins headings and runs with
    /// a space, so it does not know which of the two a title is in.
    func testLeadingTitleTokenBecomesAHeading() throws {
        var config = PSChapterDocumentBuilder.Config()
        config.kind = .bible
        config.headingsOn = true
        var options = PSChapterExpander.Options.allOff
        options.headings = true

        // ── The corpus shape, synthetic ──
        let built = PSChapterDocumentBuilder.build(
            records: [" \u{000B}CHAPTER 1.\u{000C}", "In the beginning", "And the earth"],
            headings: [:],
            config: config,
            options: options,
            highlightColour: { _ in nil },
            emptyChapterMessage: "")
        let document = try XCTUnwrap(built)
        XCTAssertEqual(document.verses.map(\.number), [0, 1, 2])
        XCTAssertEqual(document.entryCount, 3)

        let intro = try XCTUnwrap(document.verses.first)
        XCTAssertEqual(headingTexts(intro.headings), ["CHAPTER 1."],
                       "the title was not hoisted out of the intro's runs")
        XCTAssertFalse(intro.hasVisibleText,
                       "the intro still has text to draw: \(intro.runs.map(\.text))")
        XCTAssertEqual(runsCarryingTheTitleMarker(in: document), [],
                       "the builder's internal title marker reached the document")

        // Prose: the title heads the first paragraph and verse 1 flows under it.
        let first = try XCTUnwrap(document.paragraphs.first)
        XCTAssertEqual(headingTexts(first.headings), ["CHAPTER 1."])
        XCTAssertEqual(first.verses.map(\.number), [0, 1, 2])
        XCTAssertFalse(
            first.verses.flatMap(\.runs).map(\.text).joined().contains("CHAPTER"),
            "the title is still inside the flowed paragraph text")

        // ── A title that does NOT lead stays inline: bold, and unmarked ──
        let inlineBuilt = PSChapterDocumentBuilder.build(
            records: ["", "Text \u{000B}MID\u{000C} more"],
            headings: [:],
            config: config,
            options: options,
            highlightColour: { _ in nil },
            emptyChapterMessage: "")
        let inline = try XCTUnwrap(inlineBuilt)
        XCTAssertEqual(inline.verses.map(\.number), [1])
        let verse = try XCTUnwrap(inline.verses.first)
        XCTAssertEqual(verse.headings, [])
        XCTAssertEqual(verse.runs.map(\.text).joined(), "Text MID more")
        XCTAssertEqual(verse.runs.first { $0.text == "MID" }?.style, InlineStyle.bold)
        XCTAssertEqual(runsCarryingTheTitleMarker(in: inline), [],
                       "an inline title kept the builder's internal marker")

        // ── The store's own records ──
        let genesisBoth = try XCTUnwrap(
            renderBoth(module: "KJV", ref: "Genesis 1", options: options, kind: .bible))
        let genesis = genesisBoth.document
        XCTAssertEqual(headingTexts(genesis.verses.first?.headings ?? []), ["CHAPTER 1."])
        XCTAssertEqual(genesis.verses.first?.hasVisibleText, false)
        XCTAssertEqual(headingTexts(genesis.paragraphs.first?.headings ?? []),
                       ["CHAPTER 1."])
        XCTAssertEqual(genesis.paragraphs.first?.verses.map(\.number), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(runsCarryingTheTitleMarker(in: genesis), [])

        let psalmBoth = try XCTUnwrap(
            renderBoth(module: "KJV", ref: "Psalms 3", options: options, kind: .bible))
        let psalm = psalmBoth.document
        XCTAssertEqual(
            psalm.verses.prefix(2).map { headingTexts($0.headings) },
            [["PSALM 3."], ["A Psalm of David, when he fled from Absalom his son."]])
        // The psalm's own title breaks the paragraph at verse 1, so the intro is a
        // paragraph by itself with nothing but its heading — the row the views must
        // not lay an empty `Text` under. 117 psalms have this shape.
        let opening = Array(psalm.paragraphs.prefix(2))
        XCTAssertEqual(opening.map(\.id), [0, 1])
        XCTAssertEqual(opening.first?.verses.map(\.number), [0])
        XCTAssertEqual(opening.first?.verses.contains(where: \.hasVisibleText), false)
        XCTAssertEqual(runsCarryingTheTitleMarker(in: psalm), [])
    }

    /// A bible intro that is only whitespace is not a row.
    ///
    /// With Headings off — a fresh install — the intro record `" " + <title>`
    /// expands to one space. The engine's HTML showed that as a space the browser
    /// collapsed to nothing. The builder made it verse 0, which the verse-per-line
    /// layout drew as a blank line above verse 1 (29.7 pt at the default size) in
    /// 1,184 of the KJV's 1,189 chapters, and the prose layout as a leading space.
    ///
    /// The slot still COUNTS: `entryCount` is the loop counter that
    /// `chapter-loop-counters.tsv` pins.
    func testWhitespaceOnlyBibleIntroIsNotARow() throws {
        var config = PSChapterDocumentBuilder.Config()
        config.kind = .bible
        config.headingsOn = false

        // ── The corpus shape, synthetic ──
        let built = PSChapterDocumentBuilder.build(
            records: [" \u{000B}CHAPTER 1.\u{000C}", "In the beginning", "And the earth"],
            headings: [:],
            config: config,
            options: .allOff,
            highlightColour: { _ in nil },
            emptyChapterMessage: "")
        let document = try XCTUnwrap(built)
        XCTAssertEqual(document.verses.map(\.number), [1, 2],
                       "the whitespace-only intro was given a row")
        XCTAssertEqual(document.entryCount, 3, "the intro slot must still count")
        XCTAssertEqual(document.paragraphs.first?.id, 1)
        XCTAssertNil(document.emptyMessage)

        // Only the INTRO. A numbered slot that is all whitespace keeps its row: the
        // assembler gives it a `vv` anchor, and verse identity is part of parity.
        let numberedBuilt = PSChapterDocumentBuilder.build(
            records: ["", "In the beginning", " "],
            headings: [:],
            config: config,
            options: .allOff,
            highlightColour: { _ in nil },
            emptyChapterMessage: "")
        let numbered = try XCTUnwrap(numberedBuilt)
        XCTAssertEqual(numbered.verses.map(\.number), [1, 2])

        // And only a BIBLE's. The rule is the assembler's, which is bible-only;
        // MHCC's intro is the chapter summary, real text in every chapter.
        config.kind = .commentary
        let commentaryBuilt = PSChapterDocumentBuilder.build(
            records: ["* Summary.", "Verse one."],
            headings: [:],
            config: config,
            options: .allOff,
            highlightColour: { _ in nil },
            emptyChapterMessage: "")
        let commentary = try XCTUnwrap(commentaryBuilt)
        XCTAssertEqual(commentary.verses.map(\.number), [0, 1])

        // ── The store's own records ──
        let genesisBoth = try XCTUnwrap(
            renderBoth(module: "KJV", ref: "Genesis 1", options: .allOff, kind: .bible))
        let genesis = genesisBoth.document
        XCTAssertEqual(genesis.verses.first?.number, 1)
        XCTAssertEqual(genesis.verses.count, 31)
        XCTAssertEqual(genesis.entryCount, 32)
        XCTAssertEqual(genesis.paragraphs.first?.id, 1)

        for ref in Self.sampleRefs {
            let both = try XCTUnwrap(
                renderBoth(module: "KJV", ref: ref, options: .allOff, kind: .bible))
            XCTAssertEqual(both.document.verses.first?.number, 1,
                           "KJV \(ref): the chapter opens with a row above verse 1")
        }
    }

    // MARK: - Red-letter spacing

    /// The red-letter construct's spaces fold into whitespace that is already
    /// there.
    ///
    /// The HTML carried a space just inside each end of the span
    /// (`<span class="WordOfChrist"> ` … `</span> `), and a browser folded each
    /// into any whitespace on the other side of the tag. The builder emitted both
    /// as text whatever was beside them, and `Text` folds nothing: with Red Letter
    /// on, `said unto him,  Verily` had two spaces at 611 openings and 153
    /// closings across the Gospels and Acts.
    ///
    /// The construct's space is still the ONLY separator at 14 of the 2,038
    /// openings (mid-record, straight after a morph marker), and 1,865 of the
    /// 2,038 closes end their record with it, so it cannot simply go. The parity
    /// tests are the guard in that direction — John 3 is in their sample.
    func testRedLetterSpacesFoldIntoAdjacentWhitespace() throws {
        func text(_ record: String,
                  _ options: PSChapterExpander.Options = .allOn) throws -> String {
            let runs = try XCTUnwrap(
                PSChapterDocumentBuilder.runs(from: record, options: options))
            return runs.map(\.text).joined()
        }

        // The record's own whitespace is beside the token: one space, not two.
        XCTAssertEqual(try text("him, \u{0011}Suffer it\u{0012} Then he"),
                       "him, Suffer it Then he")
        XCTAssertEqual(try text("him,\n\u{0011}Suffer it\u{0012}\nThen he"),
                       "him,\nSuffer it\nThen he")
        // Two spans back to back share one.
        XCTAssertEqual(try text("\u{0011}Verily\u{0012}\u{0011}I say\u{0012}"),
                       " Verily I say ")

        // The construct's spaces are the only separators: kept.
        XCTAssertEqual(try text("him,\u{0011}Suffer it\u{0012}Then he"),
                       "him, Suffer it Then he")
        // Verse-leading and verse-final: as they were. The leading one is the
        // leading-whitespace strip's to remove.
        XCTAssertEqual(try text("\u{0011}Verily\u{0012}"), " Verily ")
        // A token sentinel after the span is whitespace to Swift (U+000B opens a
        // title) but puts no space in the text, so the construct's space stays.
        XCTAssertEqual(try text("\u{0011}Verily\u{0012}\u{000B}Title\u{000C}"),
                       " Verily Title")

        // Red Letter off emits neither space; the record's own are the separators.
        var off = PSChapterExpander.Options.allOn
        off.redLetter = false
        XCTAssertEqual(try text("him, \u{0011}Suffer it\u{0012} Then he", off),
                       "him, Suffer it Then he")

        // The payload is still red, and so is a space the construct supplies.
        let folded = try XCTUnwrap(PSChapterDocumentBuilder.runs(
            from: "him, \u{0011}Suffer\u{0012} Then", options: .allOn))
        XCTAssertEqual(folded.map(\.text), ["him, ", "Suffer", " Then"])
        XCTAssertEqual(folded.map { $0.style.contains(.wordOfChrist) },
                       [false, true, false])
        let kept = try XCTUnwrap(PSChapterDocumentBuilder.runs(
            from: "him,\u{0011}Suffer\u{0012}Then", options: .allOn))
        XCTAssertEqual(kept.map(\.text), ["him,", " ", "Suffer", " ", "Then"])
        XCTAssertEqual(kept.map { $0.style.contains(.wordOfChrist) },
                       [false, true, true, true, false])

        // ── The store's own records ──
        // John 3:3, 3:5 and 3:10 each open a span after `, `.
        let johnBoth = try XCTUnwrap(
            renderBoth(module: "KJV", ref: "John 3", options: .allOn, kind: .bible))
        var doubled: [Int] = []
        for verse in johnBoth.document.verses where !verse.isIntro {
            let joined = verse.runs.map(\.text).joined()
            if joined.range(of: "\\S\\s{2,}\\S", options: .regularExpression) != nil {
                doubled.append(verse.number)
            }
        }
        XCTAssertEqual(doubled, [],
                       "KJV John 3: verses with a doubled space inside their text")
    }

    // MARK: - Heading fonts

    /// A heading is bold run by run, and each run keeps the rest of its own font.
    ///
    /// `text(for heading:)` put one bold font over the whole string, which replaced
    /// every run's. A Strong's or morph marker in a Psalm title kept its grey and
    /// its raise but was drawn at the title's size — `A Psalm<04210> of
    /// David<01732>` in full-size numbers — and the translators' supplied words
    /// lost their italic. The HTML had the same anchors inside its `<b>`, as 70%
    /// superscripts. Of the KJV's 138 canonical headings, 116 carry a Strong's
    /// token and 39 an `<i>`.
    ///
    /// Compares fonts against each other, as the bookmark test compares colours, so
    /// this file needs no `import SwiftUI`.
    @MainActor
    func testHeadingKeepsEachRunsOwnFont() throws {
        let style = ChapterTextRenderer.Style(
            fontName: "Georgia", fontSize: 20, lineSpacingMultiple: 1.4
        )
        // The shape of Psalms 3's title with Strong's on. Every run is already
        // bold: the whole heading sits inside a title token.
        let runs = [
            InlineRun(text: "A Psalm", style: .bold),
            InlineRun(text: "<04210>", style: [.smaller, .bold],
                      link: .strongs(type: "Hebrew", value: "04210"), isMarker: true),
            InlineRun(text: " which", style: [.bold, .transChangeAdded]),
        ]
        let heading = ChapterTextRenderer.text(
            for: ChapterHeading(runs: runs, isCanonical: true), style: style
        )
        let fonts = heading.runs.map { $0.font }
        guard fonts.count == 3 else {
            return XCTFail(
                "expected one attributed run per heading run, got \(fonts.count)"
            )
        }
        XCTAssertNotEqual(fonts[0], fonts[1],
                          "the marker is drawn in the title's own font")
        XCTAssertNotEqual(fonts[0], fonts[2],
                          "the supplied words lost their italic")
        XCTAssertEqual(
            fonts,
            ChapterTextRenderer.attributed(runs: runs, style: style).runs.map { $0.font },
            "a heading's runs are not in the fonts the renderer gives those runs"
        )

        // Bold does not lean on the title token: a run that arrives without it is
        // bold in a heading all the same.
        let plain = ChapterTextRenderer.text(
            for: ChapterHeading(runs: [InlineRun(text: "ALEPH.")], isCanonical: true),
            style: style
        )
        XCTAssertEqual(
            plain.runs.first?.font,
            ChapterTextRenderer.attributed(
                runs: [InlineRun(text: "ALEPH.", style: .bold)], style: style
            ).runs.first?.font,
            "a heading run without its own bold was not drawn bold"
        )
        XCTAssertNotEqual(
            plain.runs.first?.font,
            ChapterTextRenderer.attributed(
                runs: [InlineRun(text: "ALEPH.")], style: style
            ).runs.first?.font,
            "bold and regular compare equal, so the assertion above proves nothing"
        )
    }

    // MARK: - Heading links

    /// The markers in a Psalm's title are links the reader's tap handler reads.
    ///
    /// A title has Strong's and morph markers of its own — 116 of the KJV's 138
    /// canonical headings carry a Strong's token — and they are drawn as the
    /// raised grey markers the verse text has. The heading row sat outside the
    /// verse text's link routing, so a tap on one went to the system, which has
    /// nothing registered for `pslink://`, and did nothing.
    ///
    /// This pins the two ends a unit test can reach: the title's rendered text
    /// carries every marker's link as a URL, and each URL decodes back to the
    /// typed link the pane routes. What joins them is a view's environment —
    /// `routesChapterLinks(to:)` on the heading row's `Text` — and that the tap
    /// reaches the pane can only be seen by tapping one.
    @MainActor
    func testAPsalmTitlesMarkersAreLinksTheReaderRoutes() throws {
        let style = ChapterTextRenderer.Style(
            fontName: "Georgia", fontSize: 20, lineSpacingMultiple: 1.4
        )
        let psalmBoth = try XCTUnwrap(
            renderBoth(module: "KJV", ref: "Psalms 3", options: .allOn, kind: .bible))
        let title = try XCTUnwrap(
            psalmBoth.document.verses.flatMap(\.headings).first { $0.isCanonical },
            "Psalms 3 has no canonical title"
        )
        let typed = title.runs.filter { !$0.text.isEmpty }.compactMap(\.link)
        // `A Psalm<04210>` — in Psalms 3 that number is in the title alone.
        XCTAssertTrue(
            typed.contains(.strongs(type: "Hebrew", value: "04210")),
            "the title carries no Strong's link for 'A Psalm': \(typed)"
        )
        XCTAssertTrue(
            typed.contains { link in
                if case .morph = link { return true }
                return false
            },
            "the title carries no morph link: \(typed)"
        )

        let text = ChapterTextRenderer.text(for: title, style: style)
        var routed: [InlineLink] = []
        for run in text.runs {
            guard let url = run.link else { continue }
            routed.append(try XCTUnwrap(
                InlineLink(url: url),
                "the title's link \(url) is not one the reader's handler reads"
            ))
        }
        XCTAssertEqual(routed, typed,
                       "the title's text does not carry its markers' links")
    }

    // MARK: - Search highlighting across markers

    /// The search terms are matched against the verse's words; the markers between
    /// them are neither searched nor jacketed.
    ///
    /// The highlighter searched the rendered string, markers included. With
    /// Strong's on nearly every word is followed by one, so an exact phrase —
    /// `beginning God` over `beginning<07225> God` — was never found and the
    /// chapter opened from a phrase search with nothing highlighted, though the
    /// result row that was tapped showed the match. And a term could be jacketed
    /// inside a marker's own text: `prep` in `(PREP)`.
    ///
    /// The words are what the search matched and what the row shows. A match is
    /// mapped back onto the rendered text stretch by stretch, so a marker inside a
    /// matched phrase stays as it was.
    @MainActor
    func testSearchHighlightReadsTheWordsAndLeavesMarkersAlone() throws {
        let verse = ChapterVerse(
            number: 1,
            runs: [
                InlineRun(text: "In the beginning"),
                InlineRun(text: "<07225>", isMarker: true),
                InlineRun(text: " God"),
                InlineRun(text: "<0430>", isMarker: true),
                InlineRun(text: " created"),
                InlineRun(text: "(8804)", isMarker: true),
                InlineRun(text: "."),
            ]
        )
        let rendered = "In the beginning<07225> God<0430> created(8804)."
        let base = ChapterTextRenderer.Style.current()

        /// The jacketed stretches for `terms`, in order. The text itself must come
        /// through untouched whatever is highlighted.
        func jacketed(_ terms: [SearchHighlightTerm], line: UInt = #line) -> [String] {
            var style = base
            style.highlightTerms = terms
            let text = ChapterTextRenderer.text(for: verse, style: style)
            XCTAssertEqual(String(text.characters), rendered,
                           "highlighting \(terms) changed the text", line: line)
            var out: [String] = []
            for run in text.runs where run.backgroundColor != nil {
                out.append(String(text[run.range].characters))
            }
            return out
        }

        // A phrase whose words have a marker between them: both words, and not
        // the marker.
        XCTAssertEqual(jacketed(["beginning God"]), ["beginning", " God"])
        // A term is its words. The full stop typed after one is no part of what
        // the query matched, and is not jacketed (it was, when a term was
        // matched character for character).
        XCTAssertEqual(jacketed(["created."]), ["created"])
        // Case-insensitively, as before, and starting inside a run.
        XCTAssertEqual(jacketed(["GOD CREATED"]), ["God", " created"])
        // A marker's own text is not searched.
        XCTAssertEqual(jacketed(["0430"]), [])
        XCTAssertEqual(jacketed(["8804"]), [])
        // Every term still gets its turn.
        XCTAssertEqual(jacketed(["beginning God", "the"]), ["the", "beginning", " God"])
        // Control: a term inside one run is jacketed as it always was.
        XCTAssertEqual(jacketed(["God"]), ["God"])
    }

    /// The reader marks a search term as a whole word, as the row that opened
    /// the chapter did, and a fuzzy term over every word that begins with it.
    ///
    /// The reader looked for the term's letters anywhere in the verse's words,
    /// so the chapter a search for `the` opened had it marked inside "father",
    /// "there" and "thee". And it was never told about Fuzzy: a result found by
    /// `lov*` opened with "lov" marked inside "loved", where its row had marked
    /// the word.
    ///
    /// Both now ask `PSSearchQuery.highlightRanges`, with the terms the query
    /// ran. This pins the reader's half: the marks land on the right words of
    /// the rendered text with a marker after nearly every one of them, which is
    /// the reader's own work (`applyHighlights` maps a match in the words back
    /// onto the text).
    @MainActor
    func testTheReaderMarksASearchTermAsAWholeWord() throws {
        // Genesis 46:3 as the reader holds it with Strong's numbers on: one
        // "the", and "father", "there" and "thee" with those letters in them.
        let verse = ChapterVerse(
            number: 3,
            runs: [
                InlineRun(text: "And he said"),
                InlineRun(text: "<0559>", isMarker: true),
                InlineRun(text: ", I am God"),
                InlineRun(text: "<0410>", isMarker: true),
                InlineRun(text: ", the God"),
                InlineRun(text: "<0430>", isMarker: true),
                InlineRun(text: " of thy father"),
                InlineRun(text: "<01>", isMarker: true),
                InlineRun(text: ": fear"),
                InlineRun(text: "<03372>", isMarker: true),
                InlineRun(text: " not to go down"),
                InlineRun(text: "<03381>", isMarker: true),
                InlineRun(text: " into Egypt"),
                InlineRun(text: "<04714>", isMarker: true),
                InlineRun(text: "; for I will there make"),
                InlineRun(text: "<07760>", isMarker: true),
                InlineRun(text: " of thee a great"),
                InlineRun(text: "<01419>", isMarker: true),
                InlineRun(text: " nation"),
                InlineRun(text: "<01471>", isMarker: true),
                InlineRun(text: ":"),
            ]
        )
        let rendered = verse.runs.map(\.text).joined()
        let base = ChapterTextRenderer.Style.current()

        func jacketed(_ terms: [SearchHighlightTerm], line: UInt = #line) -> [String] {
            var style = base
            style.highlightTerms = terms
            let text = ChapterTextRenderer.text(for: verse, style: style)
            XCTAssertEqual(String(text.characters), rendered,
                           "highlighting \(terms) changed the text", line: line)
            var out: [String] = []
            for run in text.runs where run.backgroundColor != nil {
                out.append(String(text[run.range].characters))
            }
            return out
        }

        XCTAssertEqual(jacketed(["the"]), ["the"])
        XCTAssertEqual(jacketed(["he"]), ["he"])
        XCTAssertEqual(jacketed(["fat"]), [])
        // A marker's digits are no word of the verse, whole or not.
        XCTAssertEqual(jacketed(["0430"]), [])
        // Fuzzy: the words that begin with the term, whole. Not "father".
        XCTAssertEqual(
            jacketed([SearchHighlightTerm("the", matchesPrefix: true)]),
            ["the", "there", "thee"]
        )
        XCTAssertEqual(
            jacketed([SearchHighlightTerm("fat", matchesPrefix: true)]),
            ["father"]
        )
        // A phrase across the verse's own punctuation and across markers: its
        // words and what is printed between them, and no marker.
        XCTAssertEqual(jacketed(["am God the God of"]),
                       ["am God", ", the God", " of"])

        // "LORD" is two runs in the reader, a capital and three small ones
        // (MEASURED: a word spans a run boundary in 5,825 KJV verses — LORD,
        // GOD, JEHOVAH, JAH). The words are matched joined, so it is one word:
        // found whole, and no "ORD" to be found on its own.
        let genesis2v4 = ChapterVerse(
            number: 4,
            runs: [
                InlineRun(text: "in the day that the L"),
                InlineRun(text: "ORD", style: .smaller),
                InlineRun(text: "<03068>", isMarker: true),
                InlineRun(text: " God"),
                InlineRun(text: "<0430>", isMarker: true),
                InlineRun(text: " made the earth"),
            ]
        )
        func jacketedInGenesis2v4(_ terms: [SearchHighlightTerm]) -> [String] {
            var style = base
            style.highlightTerms = terms
            let text = ChapterTextRenderer.text(for: genesis2v4, style: style)
            var out: [String] = []
            for run in text.runs where run.backgroundColor != nil {
                out.append(String(text[run.range].characters))
            }
            return out
        }
        XCTAssertEqual(jacketedInGenesis2v4(["lord"]), ["L", "ORD"])
        XCTAssertEqual(jacketedInGenesis2v4(["the LORD God"]), ["the L", "ORD", " God"])
        XCTAssertEqual(
            jacketedInGenesis2v4([SearchHighlightTerm("lor", matchesPrefix: true)]),
            ["L", "ORD"]
        )
        XCTAssertEqual(jacketedInGenesis2v4(["ord"]), [])
    }

    /// The reader's words are the words the search matched, verse for verse.
    ///
    /// A search matches the words of the store's plain text for a verse: what
    /// the index holds, and what the result row shows. The reader marks a
    /// different derivation of the same verse — its runs with the markers left
    /// out (`ChapterTextRenderer.applyHighlights`). Marking whole words
    /// depends on the two breaking into the same words. A word glued to the
    /// next where a marker was taken out, or held apart from itself, would be a
    /// verse the search found and the chapter opened without a mark; while a
    /// term was looked for anywhere in the text, no such difference could show.
    ///
    /// MEASURED 2026-11-11 (iOS 27.2): all 31,102 verses break into the same
    /// words at all 32 combinations of the five display options, and no marker
    /// sits inside a word. A word does span a RUN boundary in 5,825 verses
    /// ("L" + "ORD"), which is why the words are matched joined.
    ///
    /// The reader's side is the highlighter's own join
    /// (`ChapterTextRenderer.searchableWords`), and both sides are cut by its
    /// own tokenizer. So this fails if the join changes — a space put between
    /// runs, a marker let in — if the document builder moves a word across a
    /// run, or if the baked text does. The default tier walks the sample
    /// chapters at both option endpoints; `PSDOC_EXHAUSTIVE=1` walks every
    /// chapter (about 8 s in all).
    ///
    /// The Bible only. MHCC has no markers to take out, and six of its
    /// passages cannot pass: the store's plain text for them has words the
    /// chapter body lacks, 145 in all, each stretch from an `&c` to the next
    /// semicolon or the passage's end (Genesis 3:1 and 43:1, Numbers 35:9,
    /// Deuteronomy 18:9, II Samuel 5:17, Matthew 1:1). That is the baked data.
    /// A search can find a passage on those words; the reader has nothing to
    /// mark there, and never had.
    func testTheReadersWordsAreTheWordsTheSearchMatched() throws {
        let store = try store()
        let resolver = try resolver()

        // The chapters to walk, as the cursor names them. Nil is all of them.
        var wanted: Set<String>?
        if !Self.isExhaustive {
            wanted = Set(try Self.sampleRefs.map { ref in
                let (book, chapter) = try XCTUnwrap(resolver.resolve(ref: ref), ref)
                return "\(book.osisName)|\(chapter)"
            })
        }

        // The search's side: each verse's index text, cut into words.
        var index: [String: [Int: [String]]] = [:]
        let cursor = store.verseCursor(module: "KJV")
        while let row = cursor.next() {
            let ref = row.osisRef
            guard let colon = ref.lastIndex(of: ":"),
                  let space = ref[..<colon].lastIndex(of: " "),
                  let chapter = Int(ref[ref.index(after: space)..<colon]),
                  let verse = Int(ref[ref.index(after: colon)...]) else {
                return XCTFail("cannot read the reference of an index row: \(ref)")
            }
            let key = "\(row.bookOsis)|\(chapter)"
            if let wanted, !wanted.contains(key) { continue }
            let plain = PSSearchQuery.cleanDisplayText(row.textPlain)
            if plain.isEmpty { continue }
            index[key, default: [:]][verse] = SearchHighlightTerm(plain).tokens
        }
        XCTAssertFalse(cursor.failed, "the store's verse cursor stopped early")

        var compared = 0
        for book in resolver.books {
            for chapter in 1...book.chapterCount {
                guard let verses = index["\(book.osisName)|\(chapter)"] else {
                    XCTAssertNotNil(wanted, "the index has no verse of \(book.name) \(chapter)")
                    continue
                }
                for options in [PSChapterExpander.Options.allOn, .allOff] {
                    let label = "\(book.name) \(chapter), \(options.strongs ? "all-on" : "all-off")"
                    let document = try XCTUnwrap(
                        PSContentReader.shared.chapterDocument(
                            module: "KJV", ref: "\(book.name) \(chapter)", kind: .bible,
                            options: options, applyBookmarkHighlights: false),
                        label)
                    var found = 0
                    for verse in document.verses {
                        // A heading-only intro row is no verse of the index.
                        guard let matched = verses[verse.number] else { continue }
                        found += 1
                        // The words as the highlighter itself joins them.
                        let words = ChapterTextRenderer.searchableWords(of: verse.runs).words
                        let shown = SearchHighlightTerm(words).tokens
                        guard shown == matched else {
                            return XCTFail("""
                                \(label), verse \(verse.number): the reader's words are not \
                                the words the search matched.
                                  search: \(matched)
                                  reader: \(shown)
                                """)
                        }
                        compared += 1
                    }
                    XCTAssertEqual(found, verses.count,
                                   "\(label): the index holds verses the reader does not show")
                }
            }
        }
        // 329 verses in the sample chapters, 31,102 in the Bible; twice each.
        XCTAssertEqual(compared, Self.isExhaustive ? 62_204 : 658)
    }

    // MARK: - A Strong's result's words

    /// Every word of the Bible a word map tags is found at its own place: where
    /// the chapter's own Strong's marker for one of its numbers follows it.
    ///
    /// A Strong's search result marks, in the chapter it opens, the words the
    /// number tags (`PSSearchQuery.strongsHighlightRanges`). The word map has
    /// each verse's tagged words in order, and found in order alone a line
    /// takes the first place its words fit: Psalm 10:4's supplied "*after
    /// God*" for H0430, where the God the number tags comes after it. So a line
    /// is found only where a marker for its number follows. This holds the
    /// walk to the markers over the whole chapter at once — every number in it
    /// searched for, so every line with a number is marked:
    ///
    ///  * every such line is found, and found once, in order;
    ///  * its mark is its own words, and a marker for one of its numbers
    ///    follows the mark's last word, past punctuation and no space;
    ///  * the chapter as drawn with the numbers OFF — the reader's usual case,
    ///    found by the same markers in the chapter built with them on — marks
    ///    the same words, in the same order;
    ///  * a Psalm's title, which its first verse's word map opens with, is
    ///    marked in the title.
    ///
    /// Which words a search for ONE number marks is the same walk, filtered
    /// (`isTagged`), so this covers each number's marks. MEASURED 2026-11-16:
    /// 349,513 lines over the Bible, every one with a number; the 349,514th is
    /// I Corinthians 15:35's "dead", which carries only its Greek word.
    ///
    /// The default tier walks the sample chapters; `PSDOC_EXHAUSTIVE=1` walks
    /// every chapter.
    func testTheReaderMarksTheWordsAStrongsNumberTags() throws {
        let resolver = try resolver()
        let refs: [String] = Self.isExhaustive
            ? resolver.books.flatMap { book in
                (1...book.chapterCount).map { "\(book.name) \($0)" }
            }
            : Self.sampleRefs
        var lines = 0
        var titleLines = 0
        for ref in refs {
            let reader = PSContentReader.shared
            let on = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOn, applyBookmarkHighlights: false), ref)
            let off = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOff, applyBookmarkHighlights: false), ref)
            let maps = reader.wordMaps(module: "KJV", ref: ref)
            XCTAssertEqual(Set(maps.keys),
                           Set(on.verses.map(\.number).filter { $0 > 0 }),
                           "\(ref): a verse with no word map, or a word map with no verse")

            // Every number the chapter's markers carry, so every line is marked.
            var numbers = Set<String>()
            func texts(of verse: ChapterVerse) -> [[InlineRun]] {
                verse.headings.filter(\.isCanonical).map(\.runs) + [verse.runs]
            }
            for verse in on.verses {
                for runs in texts(of: verse) {
                    for marked in ChapterTextRenderer.strongsTaggedWords(of: runs)
                        .markers.values {
                        // Each group's numbers, in marker order.
                        numbers.formUnion(marked)
                    }
                }
            }
            let offVerses = Dictionary(uniqueKeysWithValues:
                off.verses.map { ($0.number, $0) })

            for verse in on.verses where !verse.isIntro {
                let label = "\(ref):\(verse.number)"
                let map = try XCTUnwrap(maps[verse.number], label)
                let tagged = texts(of: verse).map {
                    ChapterTextRenderer.strongsTaggedWords(of: $0)
                }
                let found = PSSearchQuery.strongsHighlightRanges(
                    taggedWithAnyOf: numbers, wordMap: map,
                    taggedIn: tagged, in: tagged.map(\.words))
                // Each mark in reading order, with the text it is in.
                let marks = found.enumerated().flatMap { text, ranges in
                    ranges.map { (text: text, range: $0) }
                }
                let expected = PSWordMapLine.lines(in: map).filter {
                    $0.isTagged(withAnyOf: numbers)
                }
                guard marks.count == expected.count else {
                    return XCTFail("""
                        \(label): \(expected.count) tagged lines, \(marks.count) marks.
                          lines: \(expected.map(\.surface))
                          marks: \(marks.map { tagged[$0.text].words[$0.range] })
                        """)
                }
                for (mark, line) in zip(marks, expected) {
                    let words = tagged[mark.text].words
                    let marked = String(words[mark.range])
                    XCTAssertEqual(SearchHighlightTerm(marked).tokens,
                                   SearchHighlightTerm(line.surface).tokens,
                                   "\(label): a mark is not its line's words")
                    // The marker after the mark's last word, past punctuation.
                    var at = words.unicodeScalars.distance(
                        from: words.startIndex, to: mark.range.upperBound)
                    var index = mark.range.upperBound
                    var after: Set<String> = []
                    while true {
                        if let numbers = tagged[mark.text].markers[at] {
                            after = Set(numbers)
                            break
                        }
                        guard index != words.endIndex,
                              !words.unicodeScalars[index].properties.isWhitespace,
                              !words.unicodeScalars[index].properties.isAlphabetic
                        else { break }
                        index = words.unicodeScalars.index(after: index)
                        at += 1
                    }
                    XCTAssertFalse(after.isDisjoint(with: line.lemmas),
                                   "\(label): \"\(marked)\" is not where \(line.lemmas) tags it")
                    if mark.text < found.count - 1 { titleLines += 1 }
                }
                lines += marks.count

                // Drawn with the numbers off, found by the same markers.
                let offVerse = try XCTUnwrap(offVerses[verse.number], label)
                let drawn = texts(of: offVerse).map {
                    ChapterTextRenderer.searchableWords(of: $0).words
                }
                let foundOff = PSSearchQuery.strongsHighlightRanges(
                    taggedWithAnyOf: numbers, wordMap: map,
                    taggedIn: tagged, in: drawn)
                XCTAssertEqual(
                    foundOff.enumerated().flatMap { text, ranges in
                        ranges.map { SearchHighlightTerm(String(drawn[text][$0])).tokens }
                    },
                    marks.map {
                        SearchHighlightTerm(String(tagged[$0.text].words[$0.range])).tokens
                    },
                    "\(label): with the numbers off, other words are marked")
            }
        }
        // Every line with a number: 2,823 in the sample chapters.
        XCTAssertEqual(lines, Self.isExhaustive ? 349_513 : 2_823)
        if !Self.isExhaustive {
            XCTAssertEqual(titleLines, 6 + 2,
                           "Psalms 3's title is six lines of its map, Psalms 23's two")
        }
    }

    /// A Strong's result's chapter marks the words the number tags, each where
    /// it stands, with the numbers hidden as they are by default — not every
    /// word spelled like one of them.
    ///
    /// Through the reader's own steps (`ChapterTextRenderer.annotatingStrongs` over
    /// the chapter built with the numbers on, then the jacket the row views
    /// draw), so this is what the reader shows. Most of the cases are verses
    /// where marking the tagged words wherever they stand would mark one too
    /// many, as the result row did before issue #34
    /// (`testAStrongsRowMarksEachTaggedWordWhereItsChapterDoes` holds the row
    /// to the same cases).
    @MainActor
    func testAStrongsResultsChapterMarksEachTaggedWordWhereItStands() throws {
        let reader = PSContentReader.shared
        let style = ChapterTextRenderer.Style.current()

        /// One verse as the reader draws it for a result of `numbers`, its
        /// headings first and each ending in " | ", with what is jacketed in
        /// brackets.
        func drawn(_ ref: String, _ verse: Int, _ numbers: Set<String>,
                   showingNumbers: Bool = false,
                   line: UInt = #line) throws -> String {
            var options = PSChapterExpander.Options.allOff
            options.strongs = showingNumbers
            let shown = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: options, applyBookmarkHighlights: false), ref)
            let tagged = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOn, applyBookmarkHighlights: false), ref)
            let marked = ChapterTextRenderer.annotatingStrongs(
                highlighting: numbers, linkingWords: false,
                wordMaps: reader.wordMaps(module: "KJV", ref: ref),
                taggedIn: tagged, in: shown)
            let found = try XCTUnwrap(marked.verses.first { $0.number == verse },
                                      "\(ref):\(verse)", line: line)
            var texts = found.headings.map {
                ChapterTextRenderer.text(for: $0, style: style)
            }
            texts.append(ChapterTextRenderer.text(for: found, style: style))
            return texts.map { text in
                text.runs.map { run in
                    let piece = String(text[run.range].characters)
                    return run.backgroundColor == .yellow ? "[\(piece)]" : piece
                }.joined()
            }.joined(separator: " | ")
        }

        // The first God is the translators' (italic); H0430 tags the second.
        XCTAssertTrue(try drawn("Psalms 10", 4, ["H0430", "H430"])
            .hasSuffix("will not seek after God: [God] is not in all his thoughts."))
        // John 3:16 has "that" twice: G5620 "so loved the world, that", G2443
        // "that whosoever". Each search marks its own.
        XCTAssertTrue(try drawn("John 3", 16, ["G5620"])
            .contains("the world, [that] he gave his only begotten Son, that whosoever"))
        XCTAssertTrue(try drawn("John 3", 16, ["G2443"])
            .contains("the world, that he gave his only begotten Son, [that] whosoever"))
        // "breaking in of waters: in the desolation": H08478 is the second in.
        XCTAssertTrue(try drawn("Job 30", 14, ["H08478", "H8478"])
            .contains("breaking in of waters: [in] the desolation"))
        // "find them, even them that contended": H0582 is the second them.
        XCTAssertTrue(try drawn("Isaiah 41", 12, ["H0582", "H582"])
            .contains("not find them, even [them] that contended"))

        // A word's whole surface, the divine name as printed ("L" + small
        // "ORD"): H3068 in Genesis 2:4 is `that the <divineName>Lord</divineName>`.
        XCTAssertTrue(try drawn("Genesis 2", 4, ["H03068", "H3068"])
            .contains("in the day [that the L][ORD] God made"))
        XCTAssertTrue(try drawn("Genesis 1", 2, ["H0430", "H430"])
            .contains("And the Spirit [of God] moved"))
        // A possessive's apostrophe is not a word's.
        XCTAssertTrue(try drawn("Genesis 6", 18, ["H01121", "H1121"])
            .contains("[and thy sons]’ wives"))

        // A Psalm's title: H4210 is its "A Psalm", in the heading above verse 1.
        XCTAssertTrue(try drawn("Psalms 3", 1, ["H04210", "H4210"])
            .hasPrefix("[A Psalm] of David, when he fled from Absalom his son. | "))

        // The numbers shown move no mark, and no marker is jacketed with a word.
        XCTAssertTrue(try drawn("Psalms 10", 4, ["H0430", "H430"], showingNumbers: true)
            .contains(": [God]<0430> is"))
        XCTAssertTrue(try drawn("Genesis 2", 4, ["H03068", "H3068"], showingNumbers: true)
            .contains("[that the L][ORD]<03068> God<0430>"))

        // No numbers, no marks; nor for a number the chapter does not have.
        XCTAssertFalse(try drawn("Genesis 1", 1, []).contains("["))
        XCTAssertFalse(try drawn("Genesis 1", 1, ["G2316"]).contains("["))
        XCTAssertEqual(try drawn("Genesis 1", 1, ["H0430", "H430"]),
                       "In the beginning [God] created the heaven and the earth.")
    }

    /// A Strong's search's row marks what the chapter it opens marks: the same
    /// words, at the same places, in the verse and in its title (issue #34).
    ///
    /// The row is marked from the index (`PSSearchEngine.markStrongsWords`):
    /// the verse's text as the index holds it, with no markers, and its word
    /// map, walked through a copy of the listed verses built with the numbers
    /// on. The reader is marked from the chapter as drawn, numbers off, walked
    /// through the whole chapter built with them on
    /// (`ChapterTextRenderer.annotatingStrongs`). This holds the two to each
    /// other over every verse of the chapter at once — every number in it
    /// searched for, so every line with a number is marked — compared by the
    /// places among each text's words that the marks cover. Not by string: the
    /// reader parts "L" + small "ORD" into two marks, and the row has one.
    ///
    /// Before, the row marked each tagged spelling wherever it stood, and a
    /// word of a Psalm's title nowhere. MEASURED 2026-11-21, a search for each
    /// number of each verse: of the KJV's 318,036 (verse, number) pairs, the
    /// row marked words the number does not tag in 10,228 (3.2%) — always as
    /// well as the ones it does — and in 422 the number tags a word of the
    /// verse's title, which was not marked.
    ///
    /// The default tier walks the sample chapters; `PSDOC_EXHAUSTIVE=1` walks
    /// every chapter.
    func testAStrongsRowMarksWhatItsChapterMarks() throws {
        let store = try store()
        let resolver = try resolver()
        let refs: [String] = Self.isExhaustive
            ? resolver.books.flatMap { book in
                (1...book.chapterCount).map { "\(book.name) \($0)" }
            }
            : Self.sampleRefs

        // The index's rows, as the build makes them, by chapter.
        var wanted = Set<String>()
        for ref in refs {
            let (book, chapter) = try XCTUnwrap(resolver.resolve(ref: ref), ref)
            wanted.insert("\(book.osisName) \(chapter)")
        }
        var rows: [String: [(ref: String, verse: Int, text: String, map: String)]] = [:]
        let cursor = store.verseCursor(module: "KJV")
        while let row = cursor.next() {
            let ref = row.osisRef
            guard let colon = ref.lastIndex(of: ":"),
                  let space = ref[..<colon].lastIndex(of: " "),
                  let chapter = Int(ref[ref.index(after: space)..<colon]),
                  let verse = Int(ref[ref.index(after: colon)...]) else {
                return XCTFail("cannot read the reference of an index row: \(ref)")
            }
            let key = "\(row.bookOsis) \(chapter)"
            guard wanted.contains(key) else { continue }
            let plain = PSSearchQuery.cleanDisplayText(row.textPlain)
            if plain.isEmpty { continue }
            rows[key, default: []].append((ref, verse, plain, row.wordMap))
        }
        XCTAssertFalse(cursor.failed, "the store's verse cursor stopped early")

        /// The places among `text`'s words that `ranges` cover, in order. A
        /// range that ends where the next begins is one: the reader's marks
        /// part at a run.
        func places(_ ranges: [Range<String.Index>], in text: String) -> [Int] {
            var merged: [Range<String.Index>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, last.upperBound == range.lowerBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    merged.append(range)
                }
            }
            var out = Set<Int>()
            for range in merged {
                let first = SearchHighlightTerm(String(text[..<range.lowerBound])).tokens.count
                let count = SearchHighlightTerm(String(text[range])).tokens.count
                out.formUnion(first..<(first + count))
            }
            return out.sorted()
        }
        /// A row's marks, UTF-16 offsets, as ranges of its text.
        func rowRanges(_ marks: [Range<Int>], in text: String) -> [Range<String.Index>] {
            marks.compactMap {
                Range(NSRange(location: $0.lowerBound, length: $0.count), in: text)
            }
        }
        /// The reader's marks, unicode-scalar offsets of the runs as drawn, as
        /// ranges of that text.
        func readerRanges(_ marks: [Range<Int>], in text: String) -> [Range<String.Index>] {
            let scalars = text.unicodeScalars
            return marks.map {
                let start = scalars.index(scalars.startIndex, offsetBy: $0.lowerBound)
                return start..<scalars.index(start, offsetBy: $0.count)
            }
        }

        let reader = PSContentReader.shared
        var marks = 0
        var titleMarks = 0
        for ref in refs {
            let (book, chapter) = try XCTUnwrap(resolver.resolve(ref: ref), ref)
            let chapterRows = try XCTUnwrap(rows["\(book.osisName) \(chapter)"], ref)
            let on = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOn, applyBookmarkHighlights: false), ref)
            let off = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOff, applyBookmarkHighlights: false), ref)

            // Every number the chapter's markers carry, so every line is marked.
            var numbers = Set<String>()
            for verse in on.verses {
                for runs in verse.headings.filter(\.isCanonical).map(\.runs) + [verse.runs] {
                    for marked in ChapterTextRenderer.strongsTaggedWords(of: runs)
                        .markers.values {
                        numbers.formUnion(marked)
                    }
                }
            }

            // The row's side, as `runQuery` marks the rows it lists.
            let results = chapterRows.map {
                PSSearchResult(reference: $0.ref, fullText: $0.text)
            }
            PSSearchEngine.markStrongsWords(
                in: results, wordMaps: chapterRows.map(\.map),
                numbers: numbers, module: "KJV")

            // The reader's side, as a Strong's result's chapter is drawn.
            let drawn = ChapterTextRenderer.annotatingStrongs(
                highlighting: numbers, linkingWords: false,
                wordMaps: reader.wordMaps(module: "KJV", ref: ref),
                taggedIn: on, in: off)
            let verses = Dictionary(drawn.verses.map { ($0.number, $0) },
                                    uniquingKeysWith: { first, _ in first })

            for (row, result) in zip(chapterRows, results) {
                let label = row.ref
                let verse = try XCTUnwrap(verses[row.verse], label)
                XCTAssertFalse(verse.runs.contains(where: \.isMarker),
                               "\(label): the chapter drawn with every option off has a marker")
                let shown = verse.runs.map(\.text).joined()
                let rowPlaces = places(rowRanges(result.strongsMarks, in: row.text),
                                       in: row.text)
                let readerPlaces = places(readerRanges(verse.strongsMarks, in: shown),
                                          in: shown)
                guard rowPlaces == readerPlaces else {
                    return XCTFail("""
                        \(label): the row marks other words than its chapter.
                          row:    \(rowPlaces) of "\(row.text)"
                          reader: \(readerPlaces)
                        """)
                }
                marks += result.strongsMarks.count

                // The title, where the number tags a word of it.
                let titles = verse.headings.filter { $0.isCanonical && !$0.strongsMarks.isEmpty }
                guard result.strongsHeadings.count == titles.count else {
                    return XCTFail("""
                        \(label): the row has \(result.strongsHeadings.count) marked titles, \
                        its chapter \(titles.count).
                        """)
                }
                for (heading, title) in zip(result.strongsHeadings, titles) {
                    let text = title.runs.map(\.text).joined()
                    XCTAssertEqual(SearchHighlightTerm(heading.text).tokens,
                                   SearchHighlightTerm(text).tokens,
                                   "\(label): the row's title is not its chapter's")
                    XCTAssertEqual(
                        places(rowRanges(heading.marks, in: heading.text), in: heading.text),
                        places(readerRanges(title.strongsMarks, in: text), in: text),
                        "\(label): the row marks other words of its title than its chapter")
                    marks += heading.marks.count
                    titleMarks += heading.marks.count
                }
            }
        }
        // Every line with a number, as `testTheReaderMarksTheWordsAStrongsNumberTags`
        // counts them: 2,823 in the sample chapters, 8 of them in titles.
        XCTAssertEqual(marks, Self.isExhaustive ? 349_513 : 2_823)
        if !Self.isExhaustive {
            XCTAssertEqual(titleMarks, 6 + 2,
                           "Psalms 3's title is six lines of its map, Psalms 23's two")
        }
    }

    // MARK: - Underlined Words' links

    /// Every word of the Bible a word map tags is linked, in Underlined Words
    /// mode, at its own place and to its own numbers.
    ///
    /// The mode draws a chapter with no markers and links each tagged word
    /// (`ChapterVerse.strongsWords`), found by the same walk a Strong's result's
    /// marks are (`PSSearchQuery.strongsWords`), through the chapter built with
    /// the numbers on. Over every chapter drawn with all the options off:
    ///
    ///  * one link per line that carries a number, in order, and its words are
    ///    the line's;
    ///  * its numbers are some of the line's, as the markers write them, never
    ///    none, and its URL comes back as the same link;
    ///  * a Psalm's title is linked in the title.
    ///
    /// It also counts what the popup and the docs need: words with more than one
    /// number, the most on one word, which of a word's numbers is a particle
    /// (H0853, G3588), and the marker numbers no word is linked to.
    ///
    /// The default tier walks the sample chapters; `PSDOC_EXHAUSTIVE=1` walks
    /// every chapter.
    func testEveryTaggedWordLinksToTheNumbersItsMarkerCarries() throws {
        let resolver = try resolver()
        let refs: [String] = Self.isExhaustive
            ? resolver.books.flatMap { book in
                (1...book.chapterCount).map { "\(book.name) \($0)" }
            }
            : Self.sampleRefs
        var links = 0
        var titleLinks = 0
        var multiple = 0
        var most = 0
        var particleFirst = 0
        var particleLast = 0
        var markerNumbers = 0
        var linkedNumbers = 0
        let particles: Set<String> = ["H0853", "G3588"]
        for ref in refs {
            let reader = PSContentReader.shared
            let on = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOn, applyBookmarkHighlights: false), ref)
            let off = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOff, applyBookmarkHighlights: false), ref)
            let maps = reader.wordMaps(module: "KJV", ref: ref)
            let linked = ChapterTextRenderer.annotatingStrongs(
                highlighting: [], linkingWords: true,
                wordMaps: maps, taggedIn: on, in: off)

            func texts(of verse: ChapterVerse) -> [[InlineRun]] {
                verse.headings.filter(\.isCanonical).map(\.runs) + [verse.runs]
            }
            var numbers = Set<String>()
            for verse in on.verses {
                for runs in texts(of: verse) {
                    for group in ChapterTextRenderer.strongsTaggedWords(of: runs)
                        .markers.values {
                        numbers.formUnion(group)
                        markerNumbers += group.count
                    }
                }
            }

            for verse in linked.verses where !verse.isIntro {
                let label = "\(ref):\(verse.number)"
                XCTAssertTrue(verse.strongsMarks.isEmpty, label)
                let canonical = verse.headings.filter(\.isCanonical)
                // Each link in reading order, with the words it covers.
                var found: [(words: String, numbers: [String], inTitle: Bool)] = []
                for (index, runs) in texts(of: verse).enumerated() {
                    let words = index < canonical.count
                        ? canonical[index].strongsWords
                        : verse.strongsWords
                    let text = String(ChapterTextRenderer.attributed(
                        runs: runs, style: .init(fontName: "Georgia", fontSize: 20,
                                                 lineSpacingMultiple: 1.4)
                    ).characters)
                    let scalars = Array(text.unicodeScalars)
                    for word in words {
                        XCTAssertLessThanOrEqual(word.range.upperBound, scalars.count, label)
                        var piece = String.UnicodeScalarView()
                        piece.append(contentsOf: scalars[word.range])
                        found.append((String(piece), word.numbers,
                                      index < canonical.count))
                    }
                }
                let expected = PSWordMapLine.lines(in: maps[verse.number] ?? "")
                    .filter { $0.isTagged(withAnyOf: numbers) }
                guard found.count == expected.count else {
                    return XCTFail("""
                        \(label): \(expected.count) tagged lines, \(found.count) links.
                          lines: \(expected.map(\.surface))
                          links: \(found.map(\.words))
                        """)
                }
                for (link, line) in zip(found, expected) {
                    XCTAssertEqual(SearchHighlightTerm(link.words).tokens,
                                   SearchHighlightTerm(line.surface).tokens,
                                   "\(label): a link is not its line's words")
                    XCTAssertFalse(link.numbers.isEmpty, "\(label): \(link.words)")
                    XCTAssertTrue(Set(link.numbers).isSubset(of: Set(line.lemmas)),
                                  "\(label): \(link.numbers) are not \(line.lemmas)")
                    let url = try XCTUnwrap(
                        InlineLink.strongsWord(numbers: link.numbers).url, label)
                    XCTAssertEqual(InlineLink(url: url),
                                   .strongsWord(numbers: link.numbers), label)
                    if link.inTitle { titleLinks += 1 }
                    if link.numbers.count > 1 {
                        multiple += 1
                        if particles.contains(link.numbers[0]) { particleFirst += 1 }
                        if let last = link.numbers.last, particles.contains(last) {
                            particleLast += 1
                        }
                    }
                    most = max(most, link.numbers.count)
                    linkedNumbers += link.numbers.count
                }
                links += found.count
            }
        }
        // Every line with a number, as `testTheReaderMarksTheWordsAStrongsNumberTags`.
        XCTAssertEqual(links, Self.isExhaustive ? 349_513 : 2_823)
        // MEASURED 2026-11-18. The words with more than one number, which the
        // popup offers side by side: never more than four, so the segments fit.
        XCTAssertEqual(multiple, Self.isExhaustive ? 17_874 : 247)
        XCTAssertEqual(most, Self.isExhaustive ? 4 : 3)
        // Where one is a particle (the object marker H0853, the article G3588)
        // it comes first and never last, which is why the popup opens on the
        // last (`StudyPopup`).
        XCTAssertEqual(particleFirst, Self.isExhaustive ? 15_749 : 237)
        XCTAssertEqual(particleLast, 0)
        // The marker numbers no word is linked to: those with no English word
        // (John 3:16's leading articles), unreachable in this mode by the
        // owner's choice. Numbers mode shows them.
        XCTAssertEqual(markerNumbers - linkedNumbers, Self.isExhaustive ? 5_452 : 48,
                       "of \(markerNumbers) marker numbers")
        if !Self.isExhaustive {
            XCTAssertEqual(titleLinks, 6 + 2,
                           "Psalms 3's title is six lines of its map, Psalms 23's two")
        }
    }

    /// Underlined Words links each word to its own numbers, where it stands,
    /// and keeps the text's own colours, under the bookmark colour and the
    /// search jacket.
    ///
    /// Through the reader's own steps (`ChapterTextRenderer.annotatingStrongs`
    /// over the chapter built with the numbers on, then `text(for:)`, which
    /// links the words before anything paints over them).
    @MainActor
    func testUnderlinedWordsLinkEachWordToItsOwnNumbers() throws {
        let reader = PSContentReader.shared
        let style = ChapterTextRenderer.Style.current()

        /// One verse of `ref` in Underlined Words mode, red letter and headings
        /// on, the markers off.
        func verse(_ ref: String, _ number: Int,
                   line: UInt = #line) throws -> ChapterVerse {
            var options = PSChapterExpander.Options.allOff
            options.redLetter = true
            options.headings = true
            let shown = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: options, applyBookmarkHighlights: false), ref, line: line)
            let tagged = try XCTUnwrap(reader.chapterDocument(
                module: "KJV", ref: ref, kind: .bible,
                options: .allOn, applyBookmarkHighlights: false), ref, line: line)
            let linked = ChapterTextRenderer.annotatingStrongs(
                highlighting: [], linkingWords: true,
                wordMaps: reader.wordMaps(module: "KJV", ref: ref),
                taggedIn: tagged, in: shown)
            return try XCTUnwrap(linked.verses.first { $0.number == number },
                                 "\(ref):\(number)", line: line)
        }
        /// The verse as drawn, headings first and each ending in " | ", each
        /// link in brackets with its numbers.
        func drawn(_ ref: String, _ number: Int, line: UInt = #line) throws -> String {
            let found = try verse(ref, number, line: line)
            var texts = found.headings.map { ChapterTextRenderer.text(for: $0, style: style) }
            texts.append(ChapterTextRenderer.text(for: found, style: style))
            return texts.map { text in
                text.runs[\.link].map { link, range -> String in
                    let piece = String(text[range].characters)
                    guard let link,
                          case .strongsWord(let numbers)? = InlineLink(url: link) else {
                        return piece
                    }
                    return "[\(piece)|\(numbers.joined(separator: ","))]"
                }.joined()
            }.joined(separator: " | ")
        }

        // Each word its own numbers, a word with two offering both in the
        // markers' order.
        XCTAssertEqual(try drawn("Genesis 1", 1), """
            [In the beginning|H07225] [God|H0430] [created|H0853,H01254] \
            [the heaven|H08064] [and|H0853] [the earth|H0776].
            """)
        // John 3:16's two "that"s are two numbers' words. Its leading articles
        // (`<3588>(T-NSM)<3588>(T-ASM)For`) have no English word and no link.
        let john = try drawn("John 3", 16)
        XCTAssertTrue(john.hasPrefix("¶[For|G1063] [God|G3588,G2316] [so|G3779]"), john)
        XCTAssertTrue(john.contains(
            "[the world|G3588,G2889], [that|G5620] [he gave|G1325]"), john)
        XCTAssertTrue(john.contains("[Son|G3588,G5207], [that|G2443] [whosoever|G3956]"),
                      john)
        // The translators' supplied "after God" is no number's.
        XCTAssertTrue(try drawn("Psalms 10", 4)
            .contains("[will not seek|H01875] after God: [God|H0430] is"))
        // A Psalm's title is linked in the title.
        XCTAssertTrue(try drawn("Psalms 3", 1)
            .hasPrefix("[A Psalm|H04210] [of David|H01732], [when he fled|H01272]"))
        // One link over the divine name's two runs ("L" + small "ORD").
        XCTAssertTrue(try drawn("Genesis 2", 4).contains("[that the LORD|H03068] [God|H0430]"))

        // The text keeps its own colours under the link: Christ's words red,
        // the supplied words grey, a plain word the body colour (not the
        // tint). Every link is underlined; nothing else is.
        let red = ChapterTextRenderer.text(for: try verse("John 3", 16), style: style)
        for run in red.runs where run.link != nil {
            XCTAssertEqual(run.foregroundColor, .wordOfChrist,
                           String(red[run.range].characters))
            XCTAssertNotNil(run.underlineStyle, String(red[run.range].characters))
        }
        let plain = ChapterTextRenderer.text(for: try verse("Psalms 10", 4), style: style)
        var sawSupplied = false
        for run in plain.runs {
            let piece = String(plain[run.range].characters)
            if run.link != nil {
                XCTAssertEqual(run.foregroundColor, .primary, piece)
                XCTAssertNotNil(run.underlineStyle, piece)
            } else {
                XCTAssertNil(run.underlineStyle, piece)
                if piece.contains("after God") {
                    sawSupplied = true
                    XCTAssertEqual(run.foregroundColor, .secondary, piece)
                }
            }
        }
        XCTAssertTrue(sawSupplied, "Psalms 10:4's supplied words were not drawn as a run")

        // The bookmark colour and a search jacket paint over the links and
        // leave them links.
        var bookmarked = try verse("Genesis 1", 1)
        bookmarked.highlightColour = "rgba(255,0,0,0.5)"
        var searched = style
        searched.highlightTerms = ["God"]
        let painted = ChapterTextRenderer.text(for: bookmarked, style: searched)
        let god = try XCTUnwrap(painted.range(of: "God"))
        XCTAssertEqual(painted[god].backgroundColor, .yellow)
        XCTAssertEqual(
            painted[god].link,
            InlineLink.strongsWord(numbers: ["H0430"]).url
        )
        let created = try XCTUnwrap(painted.range(of: "created"))
        XCTAssertNotNil(painted[created].backgroundColor)
        XCTAssertEqual(
            painted[created].link,
            InlineLink.strongsWord(numbers: ["H0853", "H01254"]).url
        )
    }

    // MARK: - The flowed paragraph's join

    /// Flowing verses have a space between them, and a verse number cannot be
    /// parted from its verse.
    ///
    /// The prose layout ran each verse straight into the next number — `the
    /// earth.²And the earth` — where the engine ended every entry with a newline,
    /// which the browser showed as a space. And the one place a line could break
    /// near a verse boundary was after the hair space that followed the number, so
    /// a verse that began a new line left its number at the end of the line above:
    /// 133 of 1,655 numbers over real KJV paragraphs, measured in CoreText.
    ///
    /// This pins the join as text: a space after every verse but the last, none
    /// doubled after a verse that already ends in one (red-letter), none for an
    /// intro that is only its heading, the space outside the verse's bookmark
    /// colour — the one added here and a verse's own alike — and a no-break gap
    /// after each number. Where the lines then break can only be seen on a device.
    ///
    /// A verse's own trailing space was painted. A verse that ends in Christ's
    /// words ends in the red-letter span's space, which is then the gap before the
    /// next number, so a bookmark's colour ran up to that number where every other
    /// verse's stopped at its last word.
    @MainActor
    func testFlowedVersesAreSpacedAndNumbersStayWithTheirVerse() throws {
        let style = ChapterTextRenderer.Style(
            fontName: "Georgia", fontSize: 20, lineSpacingMultiple: 1.4
        )
        XCTAssertEqual(
            String(ChapterTextRenderer.verseLabel(2, style: style).characters),
            "2\u{202F}",
            "the gap after a verse number must be a no-break space"
        )

        // A chapter's first paragraph with Headings on: the intro's title is the
        // paragraph's heading and the intro itself has nothing left to draw.
        let paragraph = ChapterParagraph(
            verses: [
                ChapterVerse(number: 0),
                ChapterVerse(number: 1, runs: [InlineRun(text: "In the beginning.")]),
                ChapterVerse(number: 2, runs: [InlineRun(text: "And the earth.")]),
                ChapterVerse(number: 3,
                             runs: [InlineRun(text: "Verily. ", style: .wordOfChrist)]),
                ChapterVerse(number: 4, runs: [InlineRun(text: "And God saw.")]),
            ],
            headings: [
                ChapterHeading(runs: [InlineRun(text: "CHAPTER 1.", style: .bold)],
                               isCanonical: false),
            ]
        )
        let pieces = ChapterTextRenderer.flowedPieces(
            for: paragraph, style: style, tappable: true
        )
        XCTAssertEqual(pieces.map { $0.verse }, [0, 1, 2, 3, 4])
        XCTAssertEqual(
            pieces.map { String($0.text.characters) },
            [
                "",
                "1\u{202F}In the beginning. ",
                "2\u{202F}And the earth. ",
                "3\u{202F}Verily. ",
                "4\u{202F}And God saw.",
            ]
        )

        // An intro with text of its own is an entry like any other.
        let withIntro = ChapterTextRenderer.flowedPieces(
            for: ChapterParagraph(verses: [
                ChapterVerse(number: 0, runs: [InlineRun(text: "A Song.")]),
                ChapterVerse(number: 1, runs: [InlineRun(text: "Blessed.")]),
            ]),
            style: style, tappable: true
        )
        XCTAssertEqual(withIntro.map { String($0.text.characters) },
                       ["A Song. ", "1\u{202F}Blessed."])

        // The space is no part of the verse's highlight: the bookmark colour stops
        // at the verse's last word, whether the space is the one added here
        // (verse 1) or the verse's own (verses 2 and 3).
        func painted(_ text: AttributedString) -> String {
            var out = ""
            for run in text.runs where run.backgroundColor != nil {
                out += String(text[run.range].characters)
            }
            return out
        }
        let colour = "rgba(255,204,0,0.8)"
        // A verse that ends in Christ's words, as the builder emits it: the
        // red-letter span's own space is its last run. 1,865 of the KJV's 2,038
        // spans close at the end of their record.
        let christsWords = try XCTUnwrap(PSChapterDocumentBuilder.runs(
            from: "He said, \u{0011}Verily.\u{0012}", options: .allOn))
        XCTAssertEqual(christsWords.map(\.text), ["He said, ", "Verily.", " "])
        let marked = ChapterTextRenderer.flowedPieces(
            for: ChapterParagraph(verses: [
                ChapterVerse(number: 1, runs: [InlineRun(text: "In the beginning.")],
                             highlightColour: colour),
                ChapterVerse(number: 2, runs: christsWords, highlightColour: colour),
                // The last verse of a chapter: its record ends in a space, in all
                // 1,189 chapters.
                ChapterVerse(number: 3, runs: [InlineRun(text: "And the earth. ")],
                             highlightColour: colour),
            ]),
            style: style, tappable: true
        )
        XCTAssertEqual(
            marked.map { String($0.text.characters) },
            [
                "1\u{202F}In the beginning. ",
                "2\u{202F}He said, Verily. ",
                "3\u{202F}And the earth. ",
            ]
        )
        XCTAssertEqual(
            marked.map { painted($0.text) },
            ["In the beginning.", "He said, Verily.", "And the earth."],
            "the bookmark colour runs past a verse's last word"
        )

        // The same verse on its own row, in the Verse Per Line layout.
        let alone = ChapterTextRenderer.text(
            for: ChapterVerse(number: 2, runs: christsWords, highlightColour: colour),
            style: style
        )
        XCTAssertEqual(String(alone.characters), "He said, Verily. ")
        XCTAssertEqual(painted(alone), "He said, Verily.")

        // ── The store's own records ──
        // John 3:3 ends in Christ's words.
        let johnBoth = try XCTUnwrap(
            renderBoth(module: "KJV", ref: "John 3", options: .allOn, kind: .bible))
        var verse = try XCTUnwrap(johnBoth.document.verses.first { $0.number == 3 })
        verse.highlightColour = colour
        let real = ChapterTextRenderer.text(for: verse, style: style)
        let whole = String(real.characters)
        XCTAssertEqual(whole.last, " ", "John 3:3 no longer ends in the span's space")
        XCTAssertEqual(painted(real), whole.trimmingCharacters(in: .whitespaces),
                       "John 3:3's bookmark colour runs past its last word")
    }

    /// The transliteration in a Hebrew Strong's popup header keeps its vocal shewa
    /// inside the word.
    ///
    /// StrongsRealHebrew writes the shewa as `<sup><font size="-1"><i>e</i></font></sup>`
    /// inside the bracketed transliteration: 1,414 of its 8,674 entries, H3068
    /// (LORD), H1285 (covenant) and H3063 (Judah) among them. A tag strip that
    /// leaves a space for every tag turned `[y<sup>…e…</sup>hôvâh]` into
    /// "y e hôvâh" in the header, above a body that renders the word whole.
    func testHebrewTransliterationKeepsItsSuperscriptVowelInsideTheWord() throws {
        let store = try store()
        let html = try XCTUnwrap(
            store.dictEntry(module: BundledModules.strongsHebrew, key: "03068"),
            "StrongsRealHebrew 03068 is missing from the store"
        )
        XCTAssertTrue(
            html.contains("[y<sup><font size=\"-1\"><i>e</i></font></sup>h&#244;v&#226;h]"),
            "the entry's shape changed; this test targets the superscript shewa"
        )

        let lexeme = PSInfoPopupContent.parseStrongsLexeme(fromRenderedEntry: html)
        XCTAssertEqual(lexeme.transliteration, "yeh\u{00F4}v\u{00E2}h")
        XCTAssertEqual(lexeme.lemma, "\u{05D9}\u{05D4}\u{05D5}\u{05D4}")

        // Through the entry point the popup itself uses.
        let covenant = try XCTUnwrap(
            PSInfoPopupContent.lexiconEntry(
                module: BundledModules.strongsHebrew,
                key: "01285",
                allowsSearch: false
            ),
            "StrongsRealHebrew 01285 did not resolve"
        )
        XCTAssertEqual(covenant.transliteration, "ber\u{00EE}yth")

        // The other superscript, which must not move: 114 lemmas end in a
        // superscript `o`, and the lemma is script only.
        let trailing = try XCTUnwrap(
            store.dictEntry(module: BundledModules.strongsHebrew, key: "00726"),
            "StrongsRealHebrew 00726 is missing from the store"
        )
        XCTAssertTrue(
            trailing.contains("&#1497;<sup><font size=\"-1\"><i>o</i></font></sup><br />"),
            "the entry's shape changed; this test targets the lemma's trailing superscript"
        )
        let edomite = PSInfoPopupContent.parseStrongsLexeme(fromRenderedEntry: trailing)
        XCTAssertEqual(edomite.lemma, "\u{05D0}\u{05E8}\u{05D5}\u{05DE}\u{05D9}")
        XCTAssertEqual(edomite.transliteration, "'\u{0103}r\u{00F4}m\u{00EE}y")

        // Corpus-wide: every transliteration that carries a superscript comes out
        // with no letter standing alone. Collected rather than asserted per entry,
        // so a regression reports once instead of 1,414 times.
        var superscripted = 0
        var broken: [String] = []
        for key in store.dictKeys(module: BundledModules.strongsHebrew) {
            guard let entry = store.dictEntry(module: BundledModules.strongsHebrew, key: key),
                  let open = entry.firstIndex(of: "["),
                  let close = entry[open...].firstIndex(of: "]"),
                  entry[open...close].contains("<sup>") else { continue }
            superscripted += 1
            let parsed = PSInfoPopupContent.parseStrongsLexeme(fromRenderedEntry: entry)
            guard let transliteration = parsed.transliteration else {
                broken.append("\(key): none")
                continue
            }
            if transliteration.range(of: "(^| )[a-z]( |$)",
                                     options: .regularExpression) != nil {
                broken.append("\(key): \(transliteration)")
            }
        }
        XCTAssertEqual(superscripted, 1_414,
                       "the number of transliterations carrying a superscript changed")
        XCTAssertTrue(
            broken.isEmpty,
            "\(broken.count) transliterations were split around their superscript: "
                + "\(broken.prefix(5))"
        )
    }
}
