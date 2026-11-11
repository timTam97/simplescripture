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
                query: "H430", matchType: .AndSearch, strongs: true
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
        func jacketed(_ terms: [String], line: UInt = #line) -> [String] {
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
        XCTAssertEqual(jacketed(["created."]), ["created", "."])
        // Case-insensitively, as before, and starting inside a run.
        XCTAssertEqual(jacketed(["GOD CREATED"]), ["God", " created"])
        // A marker's own text is not searched.
        XCTAssertEqual(jacketed(["0430"]), [])
        XCTAssertEqual(jacketed(["880"]), [])
        // Every term still gets its turn.
        XCTAssertEqual(jacketed(["beginning God", "the"]), ["the", "beginning", " God"])
        // Control: a term inside one run is jacketed as it always was.
        XCTAssertEqual(jacketed(["God"]), ["God"])
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
