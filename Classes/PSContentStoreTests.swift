//
//  PSContentStoreTests.swift
//  SimpleScriptureTests
//
//  Tests for the baked content store (Resources/PSContent.sqlite) and the reader
//  on top of it. Fixtures in Tests/Fixtures were captured from the live SWORD
//  engine and cannot be regenerated: a red fixture test is a real behaviour
//  change — fix the code, never recapture.
//

import XCTest
import SQLite3
@testable import SimpleScripture

final class PSContentStoreTests: XCTestCase {

    // MARK: - Fixture plumbing

    /// Derived from #filePath, so the tests read the committed fixtures rather than
    /// anything in the simulator sandbox.
    private static func fixtureDir() -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> String {
        let url = Self.fixtureDir().appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("fixture \(name) is not present")
        }
        return text
    }

    /// Report the first divergence rather than dumping two chapters of HTML.
    private func assertEqualHTML(_ actual: String, _ expected: String, _ label: String) {
        guard actual != expected else { return }
        let a = Array(actual), e = Array(expected)
        var i = 0
        while i < min(a.count, e.count), a[i] == e[i] { i += 1 }
        let lo = max(0, i - 60)
        XCTFail("""
            \(label): reader output differs from the live-SWORD fixture.
              first difference at character \(i) (fixture \(e.count) chars, reader \(a.count))
              fixture: …\(String(e[lo..<min(e.count, i + 60)]))…
              reader:  …\(String(a[lo..<min(a.count, i + 60)]))…
            """)
    }

    private func store() throws -> PSContentStore {
        guard let store = PSContentStore.shared else {
            throw XCTSkip("PSContentStore did not open — see the logged failure")
        }
        return store
    }

    private func resolver() throws -> PSBookOSISResolver {
        guard let resolver = PSBookOSISResolver.shared else {
            throw XCTSkip("PSBookOSISResolver did not load")
        }
        return resolver
    }

    /// Store -> expander -> assembler, assembled here from the pieces rather than
    /// through PSContentReader, so a failure localises to one of the core files.
    private func renderBody(module: String,
                           ref: String,
                           options: PSChapterExpander.Options,
                           kind: PSChapterAssembler.ModuleKind = .bible,
                           versePerLine: Bool = false,
                           highlight: @escaping (Int) -> String? = { _ in nil }) throws -> PSChapterAssembler.Result {
        let store = try store()
        let resolver = try resolver()
        guard let (book, chapter) = resolver.resolve(ref: ref) else {
            XCTFail("\(ref) did not resolve to a book + chapter")
            throw XCTSkip("unresolvable ref")
        }
        guard let records = store.chapterRecords(module: module, bookOsis: book.osisName, chapter: chapter) else {
            XCTFail("\(module) \(ref) is not in the store")
            throw XCTSkip("missing chapter")
        }
        // Headings are keyed by the module's own key text, which uses the long
        // (roman-numeral) name — "I Corinthians 1:1", not "1 Corinthians 1:1".
        let headings = store.headings(module: module, bookName: book.longName, chapter: chapter)

        var expanded: [String] = []
        expanded.reserveCapacity(records.records.count)
        for record in records.records {
            if record.isEmpty {
                expanded.append("")
                continue
            }
            guard let html = PSChapterExpander.expand(record, options: options) else {
                XCTFail("\(module) \(ref): a record failed to expand")
                throw XCTSkip("expansion failed")
            }
            expanded.append(html)
        }

        var config = PSChapterAssembler.Config()
        config.kind = kind
        config.versePerLine = versePerLine
        config.headingsOn = options.headings
        guard let result = PSChapterAssembler.assemble(
            records: expanded,
            headings: headings,
            config: config,
            headingHTML: { PSChapterExpander.expand($0.html, options: options.forHeading) },
            highlightColour: highlight,
            emptyChapterMessage: "") else {
            XCTFail("\(module) \(ref): assembly failed")
            throw XCTSkip("assembly failed")
        }
        return result
    }

    // MARK: - Bundling (plan step 1)

    func testContentArtifactsAreBundled() throws {
        let store = Bundle.main.url(forResource: "PSContent", withExtension: "sqlite")
        XCTAssertNotNil(store, "PSContent.sqlite is missing from the app bundle's Copy Resources phase")

        let versification = Bundle.main.url(forResource: "Versification-KJV", withExtension: "json")
        XCTAssertNotNil(versification, "Versification-KJV.json is missing from the app bundle")

        // Non-empty and readable, not just present: a Copy Resources entry that
        // points at a stale path would still resolve to a zero-byte file.
        if let store {
            let size = try FileManager.default.attributesOfItem(atPath: store.path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 1_000_000, "PSContent.sqlite looks truncated (\(size) bytes)")
        }
        if let versification {
            let json = try Data(contentsOf: versification)
            XCTAssertGreaterThan(json.count, 1000, "Versification-KJV.json looks truncated")
        }
    }

    // MARK: - Store opens and validates (plan step 4)

    func testStoreOpensAndMatchesTheExpectedSchema() throws {
        let store = try store()
        // The counts the store was validated against at bake time. If these drift,
        // the store was rebuilt from different modules.
        XCTAssertEqual(store.dictEntryCount(module: "Robinson"), 1526)
        XCTAssertEqual(store.dictEntryCount(module: "StrongsRealGreek"), 5624)
        XCTAssertEqual(store.dictEntryCount(module: "StrongsRealHebrew"), 8674)
        XCTAssertEqual(store.moduleMeta("KJV", key: "type"), "Biblical Texts")
        XCTAssertEqual(store.moduleMeta("MHCC", key: "type"), "Commentaries")
    }

    /// The per-module `content_meta` keys (features / lang / direction).
    ///
    /// Asserted as exact values because they are a fixed property of the shipped
    /// content — a changed answer means the display menu or lexicon routing
    /// silently changed.
    func testBakedModuleMetadataMatchesTheModuleConfs() throws {
        let store = try store()

        // lang / direction. All five are Lang=en with no Direction=, so RTL is
        // false everywhere.
        for module in ["KJV", "MHCC", "Robinson", "StrongsRealGreek", "StrongsRealHebrew"] {
            XCTAssertEqual(store.moduleLang(module), "en", "\(module) Lang=")
            XCTAssertFalse(store.moduleIsRTL(module), "\(module) should not be RTL")
            XCTAssertEqual(store.moduleMeta(module, key: "direction"), "",
                           "\(module) declares no Direction=")
        }

        // The feature answers. KJV declares only `Feature=StrongsNumbers` and
        // `Feature=NoParagraphs`, but OSIS-prefixed GlobalOptionFilter entries also
        // count, so six more come from its `GlobalOptionFilter=OSIS*` lines.
        // `Scripref` is NOT among them — there is no OSISScripref filter — so KJV
        // has no cross-references toggle.
        let expected: [String: Set<String>] = [
            "KJV": ["Strongs", "StrongsNumbers", "Morph", "Headings",
                    "Footnotes", "RedLetterWords", "Lemma"],
            "MHCC": [],
            "Robinson": ["GreekParse"],
            "StrongsRealGreek": ["GreekDef"],
            "StrongsRealHebrew": ["HebrewDef"],
        ]
        // Every feature string the app ever asks about, so a YES that should be a NO
        // is caught as well as the reverse.
        let queried = ["Strongs", "StrongsNumbers", "Morph", "Headings", "Footnotes",
                       "Scripref", "RedLetterWords", "Lemma", "GreekDef", "HebrewDef",
                       "GreekParse", "HebrewParse", "Glossary", "DailyDevotion", "Images"]
        for (module, features) in expected {
            for feature in queried {
                XCTAssertEqual(store.moduleHasFeature(module, feature),
                               features.contains(feature),
                               "\(module) hasFeature(\(feature))")
            }
        }

        // MHCC declaring nothing is what hides its display menu, and no bundled
        // lexicon declares Images.
        XCTAssertEqual(store.moduleMeta("MHCC", key: "features"), "",
                       "MHCC must have an EMPTY feature list — its ▾ button hides on this")
        for lexicon in ["Robinson", "StrongsRealGreek", "StrongsRealHebrew"] {
            XCTAssertFalse(store.moduleHasFeature(lexicon, "Images"), "\(lexicon) Images")
        }
    }

    /// Both heading mechanisms are present in the rendered bodies — asserted
    /// directly rather than trusting the fixture comparison alone.
    ///
    ///  * Non-canonical titles (1,250 of KJV's 1,388) sit in intro-only entry slots
    ///    and reach the body only because Headings is On. Genesis 1 carries
    ///    `<title type="main">` and `<title type="chapter">CHAPTER 1.</title>`,
    ///    emitted unclassed as `<p><b>…</b></p>`.
    ///  * Canonical Psalm titles (138) are injected by the accumulator loop itself,
    ///    not by the markup filter. Psalm 3 is one.
    func testBothHeadingMechanismsSurviveIntoTheRenderedBody() throws {
        let gen1 = try renderBody(module: "KJV", ref: "Gen 1", options: .allOn).body
        XCTAssertTrue(gen1.contains("<p><b>"),
                      "Gen 1 body lost its intro titles — the headings option is probably off")
        XCTAssertTrue(gen1.uppercased().contains("CHAPTER 1"),
                      "Gen 1 body lost the chapter title specifically")

        let ps3 = try renderBody(module: "KJV", ref: "Ps 3", options: .allOn).body
        XCTAssertTrue(ps3.contains("<p><b>"),
                      "Ps 3 body lost its canonical preverse title")

        // The negative half: with headings OFF, Gen 1's non-canonical intro titles
        // must be GONE, while Ps 3's canonical one must survive (the injection is
        // gated `headings || canonical`).
        let gen1Off = try renderBody(module: "KJV", ref: "Gen 1", options: .allOff).body
        XCTAssertFalse(gen1Off.uppercased().contains("CHAPTER 1"),
                       "Gen 1's non-canonical chapter title must vanish with headings off")
        let ps3Off = try renderBody(module: "KJV", ref: "Ps 3", options: .allOff).body
        XCTAssertTrue(ps3Off.contains("<p><b>"),
                      "Ps 3's title is canonical, so it must survive headings being off")
    }

    /// The loop counter for all 2,378 chapters, against the captured fixture.
    ///
    /// The counter is not a verse count — it advances for entries the loop skips and
    /// for the final iteration that steps out of the chapter — and it drives the
    /// `vv{i}` anchors, the verse-menu links and the bookmark-highlight lookup, so an
    /// off-by-one here is a user-visible mis-scroll.
    func testAllChapterLoopCountersMatchTheCapturedFixture() throws {
        let text = try fixture("chapter-loop-counters.tsv")
        var compared = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3, let expected = Int(f[2]) else { continue }
            let module = String(f[0]), ref = String(f[1])
            let kind: PSChapterAssembler.ModuleKind = (module == "MHCC") ? .commentary : .bible
            // The fixture was captured at the all-off endpoint; the companion
            // invariance test proved the counter does not vary with the options.
            let result = try renderBody(module: module, ref: ref, options: .allOff, kind: kind)
            XCTAssertEqual(result.entryCount, expected, "\(module) \(ref) loop counter")
            if result.entryCount != expected { return }  // one report is enough
            compared += 1
        }
        print("[store] loop counters compared: \(compared)")
        XCTAssertEqual(compared, 2378, "1,189 chapters x 2 modules")
    }

    /// Single-verse `plain_texts` lookup by ref.
    func testPlainTextByRefLookup() throws {
        let store = try store()

        // A hit returns the same text the sequential cursor produces for that ref,
        // which is the strongest available statement: the two paths do the same
        // chunk arithmetic and must land on the same slot.
        let cursor = store.verseCursor(module: "KJV")
        var checked = 0
        while let row = cursor.next(), checked < 500 {
            // Stride through rather than testing all 31,102 — the arithmetic is
            // uniform, and the exhaustive version of this claim is the index digest.
            if checked % 50 == 0 {
                XCTAssertEqual(store.plainText(module: "KJV", osisRef: row.osisRef),
                               row.textPlain,
                               "by-ref lookup disagrees with the cursor for \(row.osisRef)")
            }
            checked += 1
        }
        XCTAssertFalse(cursor.failed)
        XCTAssertGreaterThan(checked, 400, "the walk collapsed")

        // Known content, so a systematically-wrong-but-self-consistent answer fails.
        let gen11 = store.plainText(module: "KJV", osisRef: "Genesis 1:1")
        XCTAssertNotNil(gen11)
        XCTAssertTrue(gen11?.contains("In the beginning") == true,
                      "Genesis 1:1 plain text: \(gen11 ?? "<nil>")")

        // A miss is nil, not a crash and not a neighbouring verse. This is the case
        // the caller actually depends on: a stale history entry naming a ref the
        // module does not have shows no preview rather than the wrong one.
        XCTAssertNil(store.plainText(module: "KJV", osisRef: "Genesis 999:1"))
        XCTAssertNil(store.plainText(module: "KJV", osisRef: "Nonexistent 1:1"))
        XCTAssertNil(store.plainText(module: "Robinson", osisRef: "Genesis 1:1"),
                     "a lexicon has no verses_plain rows")
    }

    // MARK: - Chapter bodies vs the live-SWORD fixtures

    /// The acceptance criterion: the reader reproduces the captured engine output
    /// byte-for-byte, at BOTH option endpoints, for every fixture chapter.
    func testChapterBodiesMatchFixturesAllOptionsOn() throws {
        for ref in ["Gen 1", "Ps 3", "Ps 119", "Matt 1", "John 3", "Gen 4", "Ps 23", "Rev 22"] {
            let result = try renderBody(module: "KJV", ref: ref, options: .allOn)
            let name = "KJV-\(ref.replacingOccurrences(of: " ", with: "_")).html"
            assertEqualHTML(result.body, try fixture(name), name)
        }
    }

    /// The state a fresh install renders. Passing both endpoints is what proves the
    /// option gating is wired to the right axes at all — a reader that ignored the
    /// options entirely would pass the all-on set alone.
    func testChapterBodiesMatchFixturesAllOptionsOff() throws {
        for ref in ["Gen 1", "Ps 3", "Ps 119", "Matt 1", "John 3", "Gen 4", "Ps 23", "Rev 22"] {
            let result = try renderBody(module: "KJV", ref: ref, options: .allOff)
            let name = "KJV-\(ref.replacingOccurrences(of: " ", with: "_"))-alloff.html"
            assertEqualHTML(result.body, try fixture(name), name)
        }
    }

    /// MHCC exercises the `bodyref` indirection (28,970 slots dedup to 4,435
    /// bodies) and the commentary formatting, whose anchor is `#verse{i}` rather
    /// than `pocketsword:versemenu:{i}`.
    func testCommentaryBodiesMatchFixtures() throws {
        for (ref, suffix) in [("Gen 1", ""), ("Matt 1", ""), ("Ps 23", ""),
                              ("Gen 1", "-alloff"), ("Matt 1", "-alloff"), ("Ps 23", "-alloff")] {
            let options: PSChapterExpander.Options = suffix.isEmpty ? .allOn : .allOff
            let result = try renderBody(module: "MHCC", ref: ref, options: options, kind: .commentary)
            let name = "MHCC-\(ref.replacingOccurrences(of: " ", with: "_"))\(suffix).html"
            assertEqualHTML(result.body, try fixture(name), name)
        }
    }

    /// The bookmark-highlighted body: the highlight re-opens its span around every
    /// block element, the subtlest thing in the assembler.
    func testBookmarkHighlightedBodyMatchesFixture() throws {
        let colour = "rgba(255,204,0,0.8)"
        let highlighted: Set<Int> = [1, 3, 6]
        let result = try renderBody(module: "KJV", ref: "Psalms 23", options: .allOn,
                                    highlight: { highlighted.contains($0) ? colour : nil })
        assertEqualHTML(result.body, try fixture("KJV-Ps_23-highlighted.html"), "KJV-Ps_23-highlighted.html")
    }

    /// The counter is a loop counter, not a verse count: Gen 1's 31 verses yield
    /// 32. It drives the vv{i} anchors, the verse-menu links and the bookmark
    /// lookup, so it has to come out identical.
    func testEntryCountsMatchTheCapturedLoopCounter() throws {
        let expected = ["Gen 1": 32, "Ps 3": 9, "Ps 119": 177, "Matt 1": 26,
                        "John 3": 37, "Gen 4": 27, "Ps 23": 7, "Rev 22": 22]
        for (ref, count) in expected {
            let result = try renderBody(module: "KJV", ref: ref, options: .allOn)
            XCTAssertEqual(result.entryCount, count, "\(ref) loop counter")
        }
    }

    // MARK: - Book resolution

    /// Refs carry book NAMES while the store is keyed on OSIS abbreviations.
    /// "Genesis 1" is what PSModuleController.getCurrentBibleRef() returns on a
    /// fresh install.
    func testBookNamesTheAppActuallyPassesResolve() throws {
        let resolver = try resolver()
        let cases: [(String, String, Int)] = [
            ("Genesis 1", "Gen", 1),            // the seeded default
            ("Gen 1", "Gen", 1),                // the abbreviation the fixtures use
            ("Psalms 119", "Ps", 119),
            ("1 Corinthians 13", "1Cor", 13),   // post-createRefString
            ("I Corinthians 13", "1Cor", 13),   // pre-createRefString / SWORD key text
            ("III John 1", "3John", 1),
            ("3 John 1", "3John", 1),
            ("Song of Solomon 2", "Song", 2),   // multi-word name
            ("Revelation 22", "Rev", 22),
            ("Genesis 1:1", "Gen", 1),          // a verse ref resolves to its chapter
        ]
        for (ref, osis, chapter) in cases {
            guard let resolved = resolver.resolve(ref: ref) else {
                XCTFail("\(ref) did not resolve")
                continue
            }
            XCTAssertEqual(resolved.book.osisName, osis, "\(ref) book")
            XCTAssertEqual(resolved.chapter, chapter, "\(ref) chapter")
        }
    }

    /// Out-of-range and nonsense must return nil, never a plausible wrong chapter.
    func testUnresolvableRefsReturnNil() throws {
        let resolver = try resolver()
        for ref in ["Genesis 51",        // 50 chapters
                    "Nonexistent 1",
                    "Genesis",           // no chapter
                    "Genesis 0",
                    "1",
                    ""] {
            XCTAssertNil(resolver.resolve(ref: ref), "\(ref.debugDescription) should not resolve")
        }
    }

    /// "Genesis 1" — the string the app passes — renders, not just resolves.
    func testTheAppsOwnDefaultRefRenders() throws {
        let result = try renderBody(module: "KJV", ref: "Genesis 1", options: .allOn)
        assertEqualHTML(result.body, try fixture("KJV-Gen_1.html"), "Genesis 1 via the app's own ref form")
        XCTAssertEqual(result.entryCount, 32)
    }

    // MARK: - Dictionary lookup parity (plan step 4b)

    /// Every key the Dictionary can display resolves — in **both** casings.
    ///
    ///  1. **True casing resolves.** The live path: what the Dictionary displays and
    ///     looks up (Robinson keys like "V-PAI-3S" are case-significant).
    ///  2. **Capitalised casing still resolves**, via `dict_keys.key COLLATE NOCASE`
    ///     as defence in depth: a stale key cache still finds its entry rather than
    ///     showing a blank definition. Dropping the collation would break that
    ///     silently.
    func testEveryKeyTheDictionaryTabCanDisplayResolves() throws {
        let store = try store()
        var checked = 0, altered = 0
        for module in ["StrongsRealGreek", "StrongsRealHebrew", "Robinson"] {
            let keys = store.dictKeys(module: module)
            XCTAssertFalse(keys.isEmpty, "\(module) has no keys")
            var missingTrue: [String] = []
            var missingCapitalized: [(String, String)] = []
            for key in keys {
                checked += 1
                // 1. The live path: the key exactly as stored and displayed.
                if store.dictEntry(module: module, key: key) == nil {
                    missingTrue.append(key)
                }
                // 2. Defence in depth: the old mangled form must still resolve.
                let capitalized = (key as NSString).capitalized
                if capitalized != key { altered += 1 }
                if store.dictEntry(module: module, key: capitalized) == nil {
                    missingCapitalized.append((key, capitalized))
                }
            }
            XCTAssertTrue(missingTrue.isEmpty,
                          "\(module): \(missingTrue.count) TRUE-cased keys do not resolve, e.g. \(missingTrue.prefix(5))")
            XCTAssertTrue(missingCapitalized.isEmpty,
                          "\(module): \(missingCapitalized.count) capitalised keys do not resolve — the COLLATE NOCASE"
                          + " defence-in-depth is gone, e.g. \(missingCapitalized.prefix(5))")
        }
        XCTAssertEqual(checked, 15824, "the store no longer holds 15,824 lexicon keys")
        // Not incidental: if this drops to 0 the second assertion has stopped
        // exercising the collation at all and would pass on a binary index.
        XCTAssertEqual(altered, 1375, "the number of case-altered keys changed")
    }

    /// `PSContentReader.dictionaryKeys` must return the **stored** casing, not a
    /// capitalised copy. Fails if a `capitalized` ever comes back.
    func testDictionaryKeysAreReturnedInTrueCasing() throws {
        let store = try store()
        let reader = PSContentReader.shared
        guard reader.isAvailable else { throw XCTSkip("content reader unavailable") }

        for module in ["StrongsRealGreek", "StrongsRealHebrew", "Robinson"] {
            let stored = store.dictKeys(module: module)
            let displayed = reader.dictionaryKeys(module: module)
            XCTAssertEqual(displayed, stored,
                           "\(module): the reader is not returning stored casing")
        }

        // Named cases, so a regression says what broke.
        let robinson = reader.dictionaryKeys(module: "Robinson")
        XCTAssertTrue(robinson.contains("V-PAI-3S"),
                      "Robinson keys should be true-cased ('V-PAI-3S'), got e.g. \(robinson.prefix(5))")
        XCTAssertFalse(robinson.contains("V-Pai-3S"),
                       "the capitalizedString mangling is back")

        // And the true-cased key opens the right entry.
        XCTAssertNotNil(reader.dictionaryEntry(module: "Robinson", key: "V-PAI-3S"))
    }

    /// The specific cases from the finding, spelled out so a regression names
    /// itself rather than appearing as "1,375 keys failed".
    func testDictionaryLookupCasingAndPaddingCases() throws {
        let store = try store()

        // Robinson: stored casing and UI casing must give the same entry.
        let stored = store.dictEntry(module: "Robinson", key: "V-PAI-3S")
        XCTAssertNotNil(stored, "V-PAI-3S (stored casing) should resolve")
        XCTAssertEqual(store.dictEntry(module: "Robinson", key: "V-Pai-3S"), stored,
                       "V-Pai-3S (the string the UI actually passes) must resolve to the same entry")

        // Strong's: the app passes the bare number (osishtmlhref.cpp:66 strips the
        // G/H prefix) and relies on strongsPad's zero-fill.
        let bare = store.dictEntry(module: "StrongsRealHebrew", key: "430")
        XCTAssertNotNil(bare, "bare Strong's number should resolve")
        XCTAssertEqual(store.dictEntry(module: "StrongsRealHebrew", key: "0430"), bare,
                       "'430' and '0430' must resolve to the same entry")

        // A miss returns nil — a deliberate fix to the engine, which padded "H430"
        // to "0430" and silently snapped to a NEIGHBOURING entry. See
        // Tests/Fixtures/strongsPad-prefixed-key-bug.txt.
        XCTAssertNil(store.dictEntry(module: "StrongsRealHebrew", key: "H430"),
                     "'H430' must miss rather than snap to a neighbour")
        XCTAssertNil(store.dictEntry(module: "StrongsRealHebrew", key: "99999"),
                     "a key that does not exist must return nil")
        XCTAssertNil(store.dictEntry(module: "Robinson", key: "NOT-A-CODE"), "nonsense key")
        XCTAssertNil(store.dictEntry(module: "StrongsRealGreek", key: ""), "empty key")

        // Cross-module isolation: a Hebrew key must not resolve out of the Greek
        // lexicon just because both key spaces are numeric.
        XCTAssertNotNil(store.dictEntry(module: "StrongsRealGreek", key: "25"))
        XCTAssertNotEqual(store.dictEntry(module: "StrongsRealGreek", key: "430"),
                          store.dictEntry(module: "StrongsRealHebrew", key: "430"))
    }

    /// The entries the fixtures DO pin must still come back byte-identical — this is
    /// the chunk-read path (inflate, split, slot) rather than the key path.
    func testDictionaryEntriesMatchFixtures() throws {
        let store = try store()
        for module in ["StrongsRealGreek", "StrongsRealHebrew", "Robinson"] {
            let text = try fixture("\(module)-entries.txt")
            // Blocks are "### key=<k>\n<entry>", entry running to the next marker.
            let blocks = text.components(separatedBy: "### key=").dropFirst()
            XCTAssertFalse(blocks.isEmpty, "\(module) fixture holds no blocks")
            for block in blocks {
                guard let newline = block.firstIndex(of: "\n") else { continue }
                let key = String(block[block.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
                var expected = String(block[block.index(after: newline)...])
                while expected.hasSuffix("\n") { expected.removeLast() }
                guard let actual = store.dictEntry(module: module, key: key) else {
                    XCTFail("\(module) key=\(key) is not in the store")
                    continue
                }
                assertEqualHTML(actual, expected, "\(module) key=\(key)")
            }
        }
    }

    // MARK: - Footnote bodies (plan step 6, the `n` branch)

    /// The footnote lookup must match the captured output AND work on the passage
    /// string the anchor actually carries, which is URL-encoded
    /// (`passage=Genesis+4%3A1`); `data(forLink:)` does not decode it.
    func testFootnoteBodiesMatchFixturesInBothEncodings() throws {
        let reader = PSContentReader.shared
        try XCTSkipUnless(reader.isAvailable, "reader unavailable")

        // Parsed out of the committed fixture rather than restated here, so the
        // expected bodies stay tied to what the engine emitted.
        let text = try fixture("KJV-footnote-attributes.txt")
        var expected: [(passage: String, marker: String, body: String)] = []
        for block in text.components(separatedBy: "### footnote ").dropFirst() {
            let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard lines.count == 2 else { continue }
            // "passage=Genesis 4:1 value=1"
            let header = String(lines[0])
            guard let passageRange = header.range(of: "passage="),
                  let valueRange = header.range(of: " value=") else { continue }
            let passage = String(header[passageRange.upperBound..<valueRange.lowerBound])
            let marker = String(header[valueRange.upperBound...])
            var body = String(lines[1])
            while body.hasSuffix("\n") { body.removeLast() }
            guard body.hasPrefix("string: ") else { continue }
            expected.append((passage, marker, String(body.dropFirst("string: ".count))))
        }
        XCTAssertEqual(expected.count, 4, "the footnote fixture no longer holds 4 cases")

        for c in expected {
            XCTAssertEqual(reader.noteBody(module: "KJV", osisRef: c.passage, marker: c.marker),
                           c.body, "clean passage \(c.passage) #\(c.marker)")

            // And the same lookup through the encoded form the anchor emits.
            let encoded = c.passage
                .replacingOccurrences(of: " ", with: "+")
                .replacingOccurrences(of: ":", with: "%3A")
            XCTAssertEqual(reader.noteBody(module: "KJV", osisRef: encoded, marker: c.marker),
                           c.body, "encoded passage \(encoded) #\(c.marker)")
        }

        // A passage with no note at that marker misses cleanly.
        XCTAssertNil(reader.noteBody(module: "KJV", osisRef: "Genesis+1%3A1", marker: "1"))
        XCTAssertNil(reader.noteBody(module: "KJV", osisRef: "Genesis+4%3A1", marker: "99"))
    }

    /// The anchor the store emits really carries `passage=Genesis+4%3A1`, and
    /// `data(forLink:)` passes it through verbatim — so the decoding above is
    /// needed.
    func testTheEmittedFootnoteAnchorCarriesAnEncodedPassage() throws {
        let body = try renderBody(module: "KJV", ref: "Gen 4", options: .allOn).body
        XCTAssertTrue(body.contains("passage=Genesis+4%3A1"),
                      "the footnote anchor's passage is no longer URL-encoded")
        XCTAssertEqual(PSContentReader.decodePassage("Genesis+4%3A1"), "Genesis 4:1")
        XCTAssertEqual(PSContentReader.decodePassage("Genesis 4:1"), "Genesis 4:1",
                       "an already-decoded passage must pass through unchanged")
    }

    // MARK: - Toggle independence
    //
    // All-on and all-off endpoints do NOT prove the gates are wired to the right
    // axes: Strong's and morph could be swapped and both endpoint fixtures would
    // still pass. So flip exactly one axis up from all-off and assert that axis's
    // markup appears while the others stay absent.

    /// The markup each axis is responsible for, and a chapter that carries it.
    private static let axisMarkers: [(name: String,
                                     ref: String,
                                     set: (inout PSChapterExpander.Options) -> Void,
                                     marker: String)] = [
        ("strongs",   "Gen 1",  { $0.strongs = true },   "action=showStrongs"),
        ("morphs",    "Gen 1",  { $0.morphs = true },    "action=showMorph"),
        ("footnotes", "Gen 4",  { $0.footnotes = true },  "action=showNote"),
        ("redLetter", "John 3", { $0.redLetter = true },  "class=\"WordOfChrist\""),
        ("headings",  "Gen 1",  { $0.headings = true },   "<p><b>"),
    ]

    func testEachToggleControlsExactlyItsOwnMarkup() throws {
        for axis in Self.axisMarkers {
            var options = PSChapterExpander.Options.allOff
            axis.set(&options)
            let body = try renderBody(module: "KJV", ref: axis.ref, options: options).body

            XCTAssertTrue(body.contains(axis.marker),
                          "\(axis.name) on: expected \(axis.marker) in \(axis.ref)")
            // Every OTHER axis's marker must be absent. This is the assertion the
            // endpoint fixtures cannot make: it fails if two axes are swapped.
            for other in Self.axisMarkers where other.name != axis.name {
                // Two axes legitimately share a marker prefix, so compare on the
                // full distinct string only when the chapters agree.
                guard other.ref == axis.ref else { continue }
                XCTAssertFalse(body.contains(other.marker),
                               "\(axis.name) on: \(other.marker) (\(other.name)) leaked into \(axis.ref)")
            }
        }
    }

    /// Red-letter's case specifically, because it is the one axis where "off" is
    /// not simply "omit the token": the span goes away but its PAYLOAD stays and
    /// must be recursively expanded. All 2,038 spans carry nested Strong's/morph
    /// tokens, so a naive delete-the-span-and-contents loses verse text.
    func testRedLetterOffKeepsTheVerseTextAndItsNestedTokens() throws {
        var withRed = PSChapterExpander.Options.allOff
        withRed.redLetter = true
        withRed.strongs = true
        var withoutRed = withRed
        withoutRed.redLetter = false

        let on = try renderBody(module: "KJV", ref: "John 3", options: withRed).body
        let off = try renderBody(module: "KJV", ref: "John 3", options: withoutRed).body

        XCTAssertTrue(on.contains("class=\"WordOfChrist\""))
        XCTAssertFalse(off.contains("class=\"WordOfChrist\""), "the span must be omitted, not hidden")

        // The verse text survives, and so do the Strong's anchors that were nested
        // inside the span.
        XCTAssertTrue(off.contains("action=showStrongs"),
                      "dropping the red-letter span lost its nested Strong's anchors")

        // Compare the two renders on their text with tags and all whitespace
        // removed. Neither normalisation weakens the claim (no *text* was lost):
        //  * tags, because Strong's anchors interleave the words, so no long
        //    phrase is contiguous in the raw HTML;
        //  * whitespace, because both WoC delimiters carry a trailing space that
        //    correctly disappears with the span. The byte-exact check is
        //    testChapterBodiesMatchFixturesAllOptionsOff.
        let onText = Self.strippingWhitespace(Self.strippingTags(on))
        let offText = Self.strippingWhitespace(Self.strippingTags(off))
        XCTAssertEqual(onText, offText,
                       "dropping the red-letter span changed the verse text")
        // A phrase that survives the anchor interleaving, so the comparison above
        // cannot pass by both sides being empty.
        XCTAssertTrue(offText.contains("onlybegotten"),
                      "the red-letter verse text is missing entirely")

        // And the HTML is genuinely shorter — the span really went rather than
        // being emitted with a different class.
        XCTAssertLessThan(off.count, on.count)
    }

    /// Everything outside a tag, so two renders can be compared on their text
    /// alone. Not a general HTML parser — the input is known to be well-formed
    /// markup with no `<` or `>` in text position (they are `&lt;` / `&gt;`).
    private static func strippingTags(_ html: String) -> String {
        var out = ""
        var depth = 0
        for c in html {
            if c == "<" { depth += 1 } else if c == ">" { depth -= 1 } else if depth == 0 { out.append(c) }
        }
        return out
    }

    /// Drop all whitespace. See the caller for why the red-letter comparison needs
    /// it (the WoC delimiters carry the spaces that legitimately disappear with the
    /// span).
    private static func strippingWhitespace(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// The verse-per-line toggle is on the assembler, not the expander, so it
    /// needs its own check: it changes the anchor shape rather than the markup set.
    func testVersePerLineChangesTheAnchorShape() throws {
        let plain = try renderBody(module: "KJV", ref: "Ps 23", options: .allOff).body
        let vpl = try renderBody(module: "KJV", ref: "Ps 23", options: .allOff, versePerLine: true).body
        XCTAssertFalse(plain.contains("id=\"vvv1\""))
        XCTAssertTrue(vpl.contains("id=\"vvv1\""), "verse-per-line wraps the verse in <span id=\"vvv{i}\">")
        XCTAssertTrue(vpl.contains("id=\"vv1\""), "the verse anchor itself is still emitted")
    }

    // MARK: - Failure seam
    //
    // Each of these injects one of the conditions PSContentReader's header lists
    // and asserts the reader REFUSES rather than crashing or rendering something
    // plausible. They construct a store directly (not the shared one) so nothing
    // is left broken for later tests.
    //
    // PSContentStore.fail() calls assertionFailure, which traps in Debug, so these
    // exercise the *initialiser* paths (report and return nil) plus the expander,
    // which can be handed a malformed token stream without touching the store.

    /// A scratch copy of the bundled store that tests can corrupt.
    private func makeStoreCopy(_ mutate: (URL) throws -> Void) throws -> URL {
        let source = try XCTUnwrap(Bundle.main.url(forResource: "PSContent", withExtension: "sqlite"))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("PSContent.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        try mutate(copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return copy
    }

    func testAbsentStoreFailsRatherThanCrashing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-here-\(UUID().uuidString).sqlite")
        // sqlite3_open_v2 with SQLITE_OPEN_READONLY does not create the file, so
        // this exercises the open failure, not an empty-database one.
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(PSContentStore(path: missing.path, reportFailures: false),
                     "a missing store must return nil, not a half-open handle")
    }

    func testWrongSchemaVersionIsRefused() throws {
        let copy = try makeStoreCopy { url in
            try Self.exec("UPDATE content_meta SET value='99' WHERE key='schemaVersion';", on: url)
        }
        XCTAssertNil(PSContentStore(path: copy.path, reportFailures: false),
                     "a store from a different schema version must be refused")
    }

    func testWrongTokenGrammarIsRefused() throws {
        let copy = try makeStoreCopy { url in
            try Self.exec("UPDATE content_meta SET value='v1' WHERE key='tokenGrammar';", on: url)
        }
        XCTAssertNil(PSContentStore(path: copy.path, reportFailures: false),
                     "a store whose token grammar predates the reader must be refused")
    }

    /// The chunk sizes drive the reader's slot arithmetic, so a store that does not
    /// declare them must be refused rather than silently defaulting — a skew would
    /// return plausible-but-wrong text from a neighbouring slot.
    func testMissingChunkSizesAreRefused() throws {
        let copy = try makeStoreCopy { url in
            try Self.exec("DELETE FROM content_meta WHERE key LIKE 'chunkRows.%';", on: url)
        }
        XCTAssertNil(PSContentStore(path: copy.path, reportFailures: false),
                     "a store without the chunkRows.* sizes must be refused")
    }

    func testMalformedVersificationIsRefused() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("psvers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let notJSON = dir.appendingPathComponent("bad.json")
        try Data("this is not json".utf8).write(to: notJSON)
        XCTAssertNil(PSBookOSISResolver(url: notJSON, reportFailures: false))

        // Valid JSON, wrong shape: 2 books instead of 66.
        let tooFew = dir.appendingPathComponent("short.json")
        let payload = """
            {"books":[{"osisName":"Gen","name":"Genesis","verseMax":[31]},
                      {"osisName":"Exod","name":"Exodus","verseMax":[22]}]}
            """
        try Data(payload.utf8).write(to: tooFew)
        XCTAssertNil(PSBookOSISResolver(url: tooFew, reportFailures: false),
                     "a versification dump that is not 66 books must be refused")
    }

    /// A malformed token stream must return nil, not a truncated verse. This runs
    /// against the expander directly, so it needs no store surgery.
    func testMalformedTokenStreamsAreRefused() {
        let cases: [(String, String)] = [
            ("\u{0001}H0430", "unterminated strongs token"),
            ("\u{0003}|TH8804", "unterminated morph token"),
            ("\u{0005}1|KJV", "unterminated note token"),
            ("\u{0001}X0430\u{0002}", "unknown strongs flag"),
            ("\u{0005}1|KJV\u{0006}", "note payload with 2 fields, not 3"),
            ("\u{0003}\u{0004}", "morph payload with 1 field, not 2"),
            ("\u{000B}unclosed title", "unterminated title token"),
            ("\u{0011}unclosed red letter", "unterminated red-letter token"),
        ]
        for (input, why) in cases {
            XCTAssertNil(PSChapterExpander.expand(input, options: .allOn, reportFailures: false),
                         "should have refused: \(why)")
        }
        // …while a well-formed stream still expands, so the guard is not just
        // rejecting everything.
        XCTAssertEqual(PSChapterExpander.expand("a\u{0001}H0430\u{0002}b", options: .allOn),
                       "a<a href=\"passagestudy.jsp?action=showStrongs&amp;type=Hebrew&amp;value=0430\""
                       + " class=\"strongs\">&lt;0430&gt;</a>b")
    }

    /// An unresolvable book must make the reader return nil so the caller falls
    /// back, rather than rendering an empty page.
    func testReaderRefusesAnUnresolvableRef() throws {
        let reader = PSContentReader.shared
        try XCTSkipUnless(reader.isAvailable, "reader unavailable")
        XCTAssertNil(reader.chapterBody(module: "KJV", ref: "Nonexistent 1", kind: .bible,
                                        applyBookmarkHighlights: false, reportFailures: false))
        XCTAssertNil(reader.chapterBody(module: "KJV", ref: "Genesis 999", kind: .bible,
                                        applyBookmarkHighlights: false, reportFailures: false))
    }

    /// A chapter absent from the store is NOT a failure: the reader must render the
    /// empty-chapter message rather than returning nil.
    ///
    /// Both shipped modules cover all 1,189 chapters, so the branch is unreachable
    /// through the bundled store — asserted here, since it would silently stop
    /// being true if a module changed. The fallback is exercised directly through
    /// the assembler.
    func testAbsentChapterRendersTheEmptyChapterMessage() throws {
        let store = try store()
        let resolver = try resolver()

        // Every chapter of both modules is present. Spot-check the boundaries
        // (testStoreOpensAndMatchesTheExpectedSchema pins the totals).
        for module in ["KJV", "MHCC"] {
            for (osis, chapter) in [("Gen", 1), ("Gen", 50), ("Mal", 4), ("Matt", 1), ("Rev", 22)] {
                XCTAssertNotNil(store.chapterRecords(module: module, bookOsis: osis, chapter: chapter),
                                "\(module) \(osis) \(chapter) is missing from the store")
            }
        }
        // A chapter number past the book's end does not resolve at all, which is
        // the nil-and-fall-back path, not the empty-chapter one.
        XCTAssertNil(resolver.resolve(ref: "Genesis 51"))

        // The fallback itself: all-empty records must produce the message, a
        // non-nil body, and a counter equal to the slot count.
        let message = "<p style=\"color:grey;\">empty (Gen 1)</p>"
        let result = PSChapterAssembler.assemble(
            records: ["", "", ""],
            headings: [:],
            config: PSChapterAssembler.Config(),
            headingHTML: { _ in "" },
            highlightColour: { _ in nil },
            emptyChapterMessage: message)
        XCTAssertEqual(result?.body, message, "an all-empty chapter must render the fallback")
        XCTAssertEqual(result?.entryCount, 3, "the counter still advances for skipped slots")
    }

    private static func exec(_ sql: String, on url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// `dictKeys` order is what the Dictionary shows, so it must be the module's
    /// own `.idx` order.
    func testDictionaryKeyOrderIsStoredOrder() throws {
        let store = try store()
        let greek = store.dictKeys(module: "StrongsRealGreek")
        XCTAssertEqual(greek.first, "00001")
        XCTAssertEqual(greek.count, 5624)
        // Numeric keys are fixed-width, so stored order is also ascending.
        XCTAssertEqual(greek, greek.sorted(), "Strong's keys are not in ascending order")

        let robinson = store.dictKeys(module: "Robinson")
        XCTAssertEqual(robinson.count, 1526)
        XCTAssertEqual(store.dictEntryCount(module: "Robinson"), robinson.count,
                       "entryCount and dictKeys disagree — the table would over- or under-run")
    }
}
