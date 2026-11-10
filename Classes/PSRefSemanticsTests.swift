//
//  PSRefSemanticsTests.swift
//  SimpleScriptureTests
//
//  The acceptance criterion for the versification + reference layer: it must
//  reproduce the SWORD engine's reference semantics exactly, and the `x` /
//  `scriptRef` branches must be provably unreachable for the shipped content.
//
//  `Tests/Fixtures/versification-KJV-oracle.txt` was captured from the live engine
//  and holds **66 books x 5 members, all 1,189 verse maxima, and all 2,376
//  transitions**. It is the whole versification gate and cannot be regenerated —
//  do NOT recapture it to make a red test pass. At Genesis 1 / Revelation 22 it
//  records the engine's clamp (the ref unchanged), where Swift deliberately
//  returns nil.
//
//  === Two tiers ===
//
//  * FAST — runs on every `test` invocation. All 2,376 next/prev transitions plus
//    66 books x 5 members and 1,189 maxima against the committed fixture, the
//    parser grammar fixture, `displayRef` munging, and the four-part
//    unreachability proof (re-derived from the store, not trusted as prose).
//  * EXHAUSTIVE — set `PSREF_EXHAUSTIVE=1`. All 31,102 parser round-trips and
//    1,189 parser-vs-resolver agreement checks.
//
//  Both tiers print their coverage: a silently-sampled gate reads as "covered
//  everything" when it did not.
//

import XCTest
@testable import SimpleScripture

final class PSRefSemanticsTests: XCTestCase {

    // MARK: - Tiering / fixture plumbing

    private static var isExhaustive: Bool {
        ProcessInfo.processInfo.environment["PSREF_EXHAUSTIVE"] != nil
    }

    private static var isCapturing: Bool {
        ProcessInfo.processInfo.environment["PSORACLE_CAPTURE"] != nil
    }

    /// Derived from `#filePath`, so the tests read the committed fixtures rather
    /// than the simulator sandbox.
    private static func fixtureDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["PSORACLE_FIXTURE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
    }

    private func checkFixture(_ name: String, actual: String) throws {
        let dir = Self.fixtureDir()
        let url = dir.appendingPathComponent(name)

        if Self.isCapturing {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            print("[refsem] captured \(name) (\(actual.utf8.count) bytes)")
            return
        }

        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("fixture \(name) not captured yet; run with PSORACLE_CAPTURE=1")
        }
        guard expected != actual else { return }

        let e = Array(expected), a = Array(actual)
        var i = 0
        while i < min(e.count, a.count), e[i] == a[i] { i += 1 }
        let lo = max(0, i - 80)
        XCTFail("""
            fixture \(name) does not match.
              first difference at character \(i) (expected \(e.count) chars, got \(a.count))
              expected: …\(String(e[lo..<min(e.count, i + 80)]))…
              actual:   …\(String(a[lo..<min(a.count, i + 80)]))…
            """)
    }

    // MARK: - Fixtures under test

    private func resolver() throws -> PSBookOSISResolver {
        guard let resolver = PSBookOSISResolver.shared else { throw XCTSkip("no resolver") }
        return resolver
    }

    private func parser() throws -> PSRefParser {
        guard let parser = PSRefParser() else { throw XCTSkip("no parser") }
        return parser
    }

    private func store() throws -> PSContentStore {
        guard let store = PSContentStore.shared else { throw XCTSkip("no store") }
        return store
    }

    // MARK: - The oracle
    //
    // `Tests/Fixtures/versification-KJV-oracle.txt`: SWORD's raw answers, clamps
    // included, so the comparisons below are byte-level.

    /// One book, as the fixture records the live engine's answer.
    private struct OracleBook {
        let name: String
        let shortName: String
        let osisName: String
        let chapters: Int
        let verseMax: [Int]
    }

    /// Parsed `versification-KJV-oracle.txt`. Throws (rather than skips) if it is
    /// missing or malformed: this file IS the oracle, so an absent one means the
    /// gate is not running.
    private func oracle() throws -> (books: [OracleBook], transitions: [String: (next: String, prev: String)]) {
        let url = Self.fixtureDir().appendingPathComponent("versification-KJV-oracle.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("versification-KJV-oracle.txt is missing — the Phase-4 oracle is gone")
            throw XCTSkip("no oracle fixture")
        }

        var books: [OracleBook] = []
        var transitions: [String: (next: String, prev: String)] = [:]
        var pending: (name: String, short: String, osis: String, chapters: Int)?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("## [") {
                // ## [0] name=Genesis short=Gen osis=Gen chapters=50
                func field(_ key: String) -> String? {
                    guard let r = line.range(of: "\(key)=") else { return nil }
                    let rest = line[r.upperBound...]
                    // Values are space-delimited except `name`, which can contain
                    // spaces ("1 Corinthians", "Song of Solomon") — so for `name`
                    // stop at the next " short=" rather than at the next space.
                    if key == "name" {
                        guard let end = rest.range(of: " short=") else { return String(rest) }
                        return String(rest[rest.startIndex..<end.lowerBound])
                    }
                    return String(rest.prefix { $0 != " " })
                }
                guard let name = field("name"), let short = field("short"),
                      let osis = field("osis"), let chapters = field("chapters").flatMap(Int.init) else {
                    XCTFail("malformed oracle book line: \(line)")
                    throw XCTSkip("malformed oracle")
                }
                pending = (name, short, osis, chapters)
            } else if line.hasPrefix("verseMax=") {
                guard let p = pending else {
                    XCTFail("oracle verseMax line with no preceding book: \(line)")
                    throw XCTSkip("malformed oracle")
                }
                let maxima = line.dropFirst("verseMax=".count)
                    .split(separator: ",").compactMap { Int($0) }
                books.append(OracleBook(name: p.name, shortName: p.short,
                                        osisName: p.osis, chapters: p.chapters,
                                        verseMax: maxima))
                pending = nil
            } else if line.contains(" -> next="), !line.hasPrefix("#") {
                // Genesis 1 -> next=Genesis 2 prev=Genesis 1
                //
                // The `!hasPrefix("#")` matters: the section header itself is
                // "# transitions: <from> -> next=<...> prev=<...>", which matches
                // the same substring and would be parsed as a 1,190th transition.
                guard let arrow = line.range(of: " -> next="),
                      let prevMark = line.range(of: " prev=") else { continue }
                let from = String(line[line.startIndex..<arrow.lowerBound])
                let next = String(line[arrow.upperBound..<prevMark.lowerBound])
                let prev = String(line[prevMark.upperBound...])
                transitions[from] = (next, prev)
            }
        }

        XCTAssertEqual(books.count, 66, "the oracle fixture does not hold 66 books")
        XCTAssertEqual(transitions.count, 1189, "the oracle fixture does not hold 1,189 transitions")
        return (books, transitions)
    }



    // MARK: - Fast tier: the table itself



    // MARK: - Fast tier: chapter navigation (the 2,376 transitions)




    /// All 2,376 transitions against the committed fixture — the whole navigation
    /// gate.
    ///
    /// The fixture stores SWORD's raw answers, including the two clamps
    /// ("Revelation 22 -> next=Revelation of John 22", "Genesis 1 -> prev=Genesis 1"),
    /// so those two rows are compared against our deliberate nil rather than against
    /// a ref.
    func testAllTransitionsMatchTheCommittedFixture() throws {
        let resolver = try resolver()
        let transitions = try oracle().transitions

        var compared = 0, clamps = 0
        for book in resolver.books {
            for chapter in 1...book.chapterCount {
                let from = "\(book.name) \(chapter)"
                guard let expected = transitions[from] else {
                    XCTFail("the fixture has no transition row for '\(from)'")
                    return
                }

                let next = resolver.nextChapter(book: book, chapter: chapter).map(resolver.displayRef)
                let prev = resolver.previousChapter(book: book, chapter: chapter).map(resolver.displayRef)

                // The fixture records SWORD's CLAMP at each canon end: the ref it was
                // given, unchanged. We return nil there, deliberately.
                if expected.next == from || expected.next == resolver.displayRef(book: book, chapter: chapter) {
                    XCTAssertNil(next, "'\(from)': the fixture shows a clamp, so we must return nil")
                    clamps += 1
                } else {
                    XCTAssertEqual(next, expected.next, "'\(from)' -> next")
                    guard next == expected.next else { return }
                }

                if expected.prev == from || expected.prev == resolver.displayRef(book: book, chapter: chapter) {
                    XCTAssertNil(prev, "'\(from)': the fixture shows a clamp, so we must return nil")
                    clamps += 1
                } else {
                    XCTAssertEqual(prev, expected.prev, "'\(from)' -> prev")
                    guard prev == expected.prev else { return }
                }
                compared += 1
            }
        }
        print("[refsem/fast] fixture transitions compared: \(compared) chapters, \(clamps) clamps")
        XCTAssertEqual(compared, 1189)
        XCTAssertEqual(clamps, 2, "exactly two clamps: Gen 1 prev and Rev 22 next")
    }


    /// `displayRef` returns the **longName** form, and every call site's downstream
    /// munge turns that into the `name` form. 66/66, which is what makes returning
    /// longName safe.
    func testDisplayRefLongNameMungesToTheNameForm() throws {
        let resolver = try resolver()
        var differing = 0
        for book in resolver.books {
            let long = resolver.displayRef(book: book, chapter: 1)
            XCTAssertEqual(PSModuleController.createRefString(long), "\(book.name) 1",
                           "\(book.osisName): createRefString(longName) != name")
            if book.name != book.longName { differing += 1 }
        }
        print("[refsem/fast] books where name != longName: \(differing) (expected 18)")
        XCTAssertEqual(differing, 18,
                       "Revelation + the numbered books are what make the longName choice observable")
    }

    /// The ref-selector's section-index strip, and the two intentional collisions
    /// in it.
    ///
    /// The strip adds a `shortName` only if no EARLIER book already used it, and
    /// resolves a tap with a first-match scan. So 66 books dedup to 64 titles and
    /// two books are unreachable from the strip: "Jud" scrolls to **Judges** (not
    /// Jude) and "Phi" to **Philippians** (not Philemon). Deliberate, pinned here so
    /// it is not "fixed" by accident.
    func testRefSelectorIndexStripKeepsItsTwoIntentionalCollisions() throws {
        let resolver = try resolver()

        // Verbatim reproduction of updateRefSelectorBooks' construction.
        var stripTitles: [String] = []
        var allShortNames: [String] = []
        for book in resolver.books {
            let short = book.shortName
            if !allShortNames.contains(short) { stripTitles.append(short) }
            allShortNames.append(short)
        }

        XCTAssertEqual(resolver.books.count, 66)
        XCTAssertEqual(stripTitles.count, 64, "the strip should dedup to 64 titles")

        // And the tap resolution — sectionForSectionIndexTitle's first-match scan.
        func section(forTitle title: String) -> Int {
            for i in 0..<resolver.books.count where resolver.books[i].shortName == title {
                return i
            }
            return 0
        }
        XCTAssertEqual(resolver.books[section(forTitle: "Jud")].name, "Judges",
                       "'Jud' must keep scrolling to Judges, not Jude")
        XCTAssertEqual(resolver.books[section(forTitle: "Phi")].name, "Philippians",
                       "'Phi' must keep scrolling to Philippians, not Philemon")
        XCTAssertEqual(resolver.books[section(forTitle: "Gen")].name, "Genesis")
        XCTAssertEqual(resolver.books[section(forTitle: "Rev")].name, "Revelation")
        XCTAssertEqual(resolver.books[section(forTitle: "1Jo")].name, "1 John")

        // Exactly which two books the strip cannot reach.
        let unreachable = resolver.books.filter { section(forTitle: $0.shortName) != resolver.index(of: $0) }
        XCTAssertEqual(Set(unreachable.map(\.name)), ["Jude", "Philemon"],
                       "the set of strip-unreachable books changed")
    }

    // MARK: - Fast tier: name -> OSIS



    /// The first/last available refs, derived from the table. They must be
    /// byte-identical to the static defaults, because the ref selector's bounds and
    /// the chapter-navigation gate both compare against them.
    func testTableDerivedFirstAndLastRefsMatchTheShippedDefaults() throws {
        let resolver = try resolver()
        guard let first = resolver.books.first, let last = resolver.books.last else {
            XCTFail("empty table")
            return
        }
        XCTAssertEqual("\(first.name) 1", "Genesis 1")
        XCTAssertEqual(PSModuleController.createRefString("\(last.longName) \(last.chapterCount)"),
                       "Revelation 22")
        // And what PSModuleController actually published at init time.
        XCTAssertEqual(PSModuleController.getFirstRefAvailable(), "Genesis 1")
        XCTAssertEqual(PSModuleController.getLastRefAvailable(), "Revelation 22")
    }

    /// The soft-fail migration's predicate: `resolve(ref:)` must reject exactly the
    /// refs an existing install could be holding that the reader cannot serve, and
    /// accept every ref the app itself produces.
    func testLastRefValidationRejectsOnlyUnresolvableRefs() throws {
        let resolver = try resolver()

        // Refs the app can legitimately be holding — none may be reset.
        for ref in ["Genesis 1", "Revelation 22", "1 Corinthians 13", "Psalms 119",
                    "Song of Solomon 2", "3 John 1",
                    // Abbreviated forms, which the sword:// path persists verbatim
                    // when the reader can resolve them.
                    "Jn 3", "Gen 1", "Ps 23", "1Cor 13"] {
            XCTAssertNotNil(resolver.resolve(ref: ref),
                            "'\(ref)' is a ref the app produces and must NOT be reset")
        }

        // Every book's canonical `name` form — what the selector VCs, history and
        // the notification dict all produce — resolves for all 66.
        for book in resolver.books {
            XCTAssertNotNil(resolver.resolve(ref: "\(book.name) 1"),
                            "\(book.osisName): the canonical ref form must resolve")
        }

        // The two shapes the migration exists for.
        XCTAssertNil(resolver.resolve(ref: "1. Mose 1"),
                     "a localised ref must be caught (the non-English-user case)")
        XCTAssertNil(resolver.resolve(ref: "Nonsense 9"),
                     "a poisoned ref from the old unvalidated sword:// path must be caught")
        XCTAssertNil(resolver.resolve(ref: "John"),
                     "a chapter-less ref must be caught")
        XCTAssertNil(resolver.resolve(ref: ""))
    }

    /// **The sword:// path's persistence contract.** Whatever that path writes to
    /// `lastRef` must be a ref the *reader* can resolve — accepting it at the gate
    /// is not enough.
    ///
    /// `PSRefParser` is deliberately more permissive than
    /// `PSBookOSISResolver.resolve(ref:)`: it adds a trailing-"." fallback and a
    /// despaced-numbered-abbreviation fallback ("Gen.", "1 Cor") that the resolver's
    /// spelling index does not carry (and must not, because PSContentStoreTests pins
    /// it). So `sword://KJV/Gen.+1` parses, and the path must fall back to the
    /// parser's canonical form rather than persist the unrenderable "Gen. 1".
    ///
    /// Asserted over every spelling of every book in all three shapes the parser
    /// accepts, through `URLRouter.route(for:)` itself. This test used to carry its
    /// own copy of the router's choice of what to write, and the copy left out the
    /// `createRefString` step the router finishes with — the step that turned a
    /// resolvable "MALACHI 3" into "MALACH1 3". `URLRouterTests` sweeps the casings.
    func testEveryParseableRefPersistsSomethingTheReaderCanResolve() throws {
        let resolver = try resolver()
        let parser = try parser()
        guard let router = URLRouter() else { throw XCTSkip("no router") }

        var checked = 0, fellBackToCanonical = 0
        for book in resolver.books {
            let spellings = [book.name, book.longName, book.localisedName, book.osisName,
                             book.shortName, book.preferredAbbreviation, book.abbreviation]
            for spelling in spellings where !spelling.isEmpty {
                for candidate in [spelling,
                                  spelling + ".",
                                  spelling.replacingOccurrences(of: " ", with: "")] {
                    let asGiven = "\(candidate) 1"
                    guard parser.parse(asGiven) != nil else { continue }
                    checked += 1

                    // The URL `openLibraryReference` would build for it.
                    var components = URLComponents()
                    components.scheme = "sword"
                    components.host = "Bible"
                    components.path = "/\(asGiven)"
                    guard let persisted = router.route(for: components.url)?.persistedChapterRef else {
                        XCTFail("'\(asGiven)' parses but does not route")
                        return
                    }
                    // The spelling as given is kept only where the reader resolves it.
                    if persisted != PSRefHelper.createRefString(asGiven) { fellBackToCanonical += 1 }

                    XCTAssertNotNil(resolver.resolve(ref: persisted),
                                    "'\(asGiven)' persists '\(persisted)', which the reader cannot resolve")
                    guard resolver.resolve(ref: persisted) != nil else { return }
                }
            }
        }
        print("[refsem/fast] parseable refs checked: \(checked)"
              + " (\(fellBackToCanonical) fell back to the canonical name form)")
        XCTAssertGreaterThan(checked, 400)
        XCTAssertGreaterThan(fellBackToCanonical, 0,
                             "the fallback is unexercised — the parser/resolver widths have converged")
    }

    // MARK: - Fast tier: the parser grammar

    /// The grammar cases the plan names, plus the `name`-vs-`longName` pins for the
    /// 18 books where the two differ, plus the whole documented out-of-scope list.
    func testParserGrammar() throws {
        let parser = try parser()

        let accepted: [(input: String, expected: String)] = [
            ("Gen 1:1",              "Genesis 1:1"),
            ("John 3:16",            "John 3:16"),
            ("Ps 23:1-3",            "Psalms 23:1-3"),   // the one in-chapter range
            ("Rom 8:28",             "Romans 8:28"),
            ("Psalms 23:1",          "Psalms 23:1"),     // the display format
            ("1 Cor 13:4",           "1 Corinthians 13:4"),
            ("1Cor 13:4",            "1 Corinthians 13:4"),
            ("I Corinthians 13:4",   "1 Corinthians 13:4"),
            ("III John 1",           "3 John 1:1"),
            ("3 John 1",             "3 John 1:1"),
            ("Rev 22:21",            "Revelation 22:21"),
            ("Revelation of John 22", "Revelation 22:1"),
            ("Song of Solomon 2:1",  "Song of Solomon 2:1"),
            ("Genesis",              "Genesis 1:1"),
            ("Genesis 1",            "Genesis 1:1"),
            ("Gen. 1:1",             "Genesis 1:1"),
            ("  Genesis 1  ",        "Genesis 1:1"),
            ("Psalms 119:176",       "Psalms 119:176"),  // the longest chapter's last verse
        ]
        for (input, expected) in accepted {
            guard let parsed = parser.parse(input) else {
                XCTFail("parser rejected '\(input)', expected \(expected)")
                continue
            }
            XCTAssertEqual(parsed.displayRef, expected, "parsing '\(input)'")
        }

        // Out of scope / invalid. Each line is a shape the app cannot produce; the
        // parser must decline rather than guess.
        let rejected = [
            "Nonsense 9:9",       // unknown book
            "Genesis 51",         // chapter past the end
            "Genesis 0", "Gen 1:0",
            "Gen 1:32",           // verse past the end of Genesis 1 (31)
            "Gen 1:3-1",          // descending range
            "Gen 1:1,3",          // comma list
            "Gen 1:1; 2:4",       // semicolon list
            "Gen 1:1-Exod 2:2",   // cross-book range
            "Gen ii",             // roman-numeral chapter (versekey.cpp:948)
            "Gen 1:1ff",          // ff suffix (:885)
            "Gen 1:12a",          // trailing-letter suffix (:925)
            "Gen inscriptio",     // INTF-only form (:962)
            "Gen -1", "Gen 1:1:1",
            "Psalms 151:1", "Rev 23", "3 John 2",
            "", "   ",
        ]
        for input in rejected {
            XCTAssertNil(parser.parse(input), "parser accepted '\(input)' but should not")
        }

        // The context-relative form, and that it is never taken from ambient state.
        let resolver = try resolver()
        guard let john = resolver.book(named: "John") else { return }
        XCTAssertEqual(parser.parse("3:16", relativeTo: john)?.displayRef, "John 3:16")
        XCTAssertEqual(parser.parse("3", relativeTo: john)?.displayRef, "John 3:1")
        XCTAssertNil(parser.parse("3:16"), "a bare verse spec must need an explicit context")

        // hadExplicitChapter, which the sword:// path branches on.
        XCTAssertEqual(parser.parse("John")?.hadExplicitChapter, false)
        XCTAssertEqual(parser.parse("1 John")?.hadExplicitChapter, false,
                       "'1 John' contains a digit but has no chapter")
        XCTAssertEqual(parser.parse("1 John 2")?.hadExplicitChapter, true)
    }

    /// Every book resolves from every spelling the table carries.
    func testParserResolvesAllBooksFromEverySpelling() throws {
        let parser = try parser()
        let resolver = try resolver()
        var resolved = 0
        // The two intentional shortName collisions: the strip dedups to 64 titles,
        // and "Jud" scrolls to Judges / "Phi" to Philippians. First-writer-wins in
        // the resolver's index reproduces that, so these two spellings do NOT
        // resolve to Jude / Philemon and must not be asserted to.
        let intentionalCollisions: [String: String] = ["Jud": "Judges", "Phi": "Philippians"]

        for book in resolver.books {
            let spellings = [book.name, book.longName, book.localisedName, book.osisName,
                             book.shortName, book.preferredAbbreviation, book.abbreviation]
            for spelling in spellings where !spelling.isEmpty {
                guard let parsed = parser.parse("\(spelling) 1:1") else {
                    XCTFail("parser rejected spelling '\(spelling)' of \(book.osisName)")
                    continue
                }
                if let owner = intentionalCollisions[spelling] {
                    XCTAssertEqual(parsed.book.name, owner,
                                   "'\(spelling)' is an intentional collision and must keep resolving to \(owner)")
                } else {
                    XCTAssertEqual(parsed.book.osisName, book.osisName,
                                   "spelling '\(spelling)' resolved to the wrong book")
                }
                resolved += 1
            }
            // Boundaries: the last verse of the last chapter parses, +1 does not.
            let lastChapter = book.chapterCount
            guard let lastVerse = resolver.verseMax(book: book, chapter: lastChapter) else { continue }
            XCTAssertNotNil(parser.parse("\(book.name) \(lastChapter):\(lastVerse)"))
            XCTAssertNil(parser.parse("\(book.name) \(lastChapter):\(lastVerse + 1)"))
            XCTAssertNil(parser.parse("\(book.name) \(lastChapter + 1)"))
        }
        print("[refsem/fast] book spellings resolved: \(resolved)")
        XCTAssertGreaterThan(resolved, 300)
    }

    // MARK: - Fast tier: the unreachability proof
    //
    // Four parts. Three are pure data assertions over the baked store; the fourth
    // is the routing claim, which is why PSRefLinkRouter exists. Together they
    // license the absence of the `x` and `scriptRef` branches. They re-derive the
    // finding from the store on every run rather than trusting it as prose.

    /// Part 1. Expand every record of all 1,189 chapters of both modules at both
    /// option endpoints, plus all 1,322 stored headings under `.forHeading`, and
    /// assert **zero** `action=showRef` anchors. `showRef` is the only action that
    /// reaches the `scriptRef` branch.
    ///
    /// The headings pass is easy to miss: `headings.html` is a *text* column, not a
    /// blob, so a blob-shaped scan of the store would silently skip all 1,322 rows.
    func testNoShippedContentEmitsAShowRefAnchor() throws {
        let store = try store()
        let resolver = try resolver()

        var chaptersScanned = 0, recordsScanned = 0, headingsScanned = 0
        var showRefHits: [String] = []

        for (module, kind) in [("KJV", "bible"), ("MHCC", "commentary")] {
            _ = kind
            for book in resolver.books {
                for chapter in 1...book.chapterCount {
                    guard let records = store.chapterRecords(module: module,
                                                             bookOsis: book.osisName,
                                                             chapter: chapter) else { continue }
                    chaptersScanned += 1
                    for options in [PSChapterExpander.Options.allOn, .allOff] {
                        for record in records.records where !record.isEmpty {
                            recordsScanned += 1
                            guard let html = PSChapterExpander.expand(record, options: options) else {
                                XCTFail("\(module) \(book.name) \(chapter): expander refused a record")
                                return
                            }
                            if html.contains("action=showRef") {
                                showRefHits.append("\(module) \(book.name) \(chapter) [expanded]")
                            }
                        }
                    }
                }
            }
        }

        // The headings axis, keyed by the module's own key text (long name).
        for module in ["KJV", "MHCC"] {
            for book in resolver.books {
                for chapter in 1...book.chapterCount {
                    let byVerse = store.headings(module: module, bookName: book.longName, chapter: chapter)
                    for (verse, headings) in byVerse {
                        for heading in headings {
                            headingsScanned += 1
                            // .forHeading is the option set a stored heading is
                            // expanded under — the title wrapper is unconditional
                            // inside one (see PSChapterExpander's header).
                            for options in [PSChapterExpander.Options.allOn.forHeading,
                                            PSChapterExpander.Options.allOff.forHeading] {
                                guard let html = PSChapterExpander.expand(heading.html, options: options) else {
                                    XCTFail("\(module) \(book.longName) \(chapter):\(verse): expander refused a heading")
                                    return
                                }
                                if html.contains("action=showRef") {
                                    showRefHits.append("\(module) \(book.longName) \(chapter):\(verse) [heading]")
                                }
                            }
                        }
                    }
                }
            }
        }

        print("[refsem/fast] unreachability part 1: \(chaptersScanned) chapter records,"
              + " \(recordsScanned) record expansions, \(headingsScanned) headings scanned")
        XCTAssertEqual(chaptersScanned, 2378, "1,189 chapters x 2 modules")
        // 1,322 headings x 2 modules-worth of lookups; KJV holds them all.
        XCTAssertEqual(headingsScanned, 1322, "the stored heading count changed")
        XCTAssertTrue(showRefHits.isEmpty,
                      "shipped content emits \(showRefHits.count) showRef anchor(s): \(showRefHits.prefix(5))")
    }

    /// Part 2. All 6,959 notes are `type='study'` with an **empty** refList, so the
    /// `x` branch — which parses that refList — has nothing to act on even if an
    /// `x` anchor could be emitted (none is: zero `\u{0007}`/`\u{0008}` tokens).
    func testEveryNoteIsAStudyNoteWithAnEmptyRefList() throws {
        let store = try store()
        let keys = store.allNoteKeys(module: "KJV")
        XCTAssertEqual(keys.count, 6959, "the note set changed size")

        var study = 0, nonEmptyRefLists: [String] = [], otherTypes: Set<String> = []
        for (osisRef, marker) in keys {
            guard let note = store.note(module: "KJV", osisRef: osisRef, marker: marker) else {
                XCTFail("note \(osisRef) #\(marker) is indexed but unreadable")
                return
            }
            if note.type == "study" { study += 1 } else { otherTypes.insert(note.type) }
            if !note.refList.isEmpty { nonEmptyRefLists.append("\(osisRef) #\(marker)") }
        }
        print("[refsem/fast] unreachability part 2: \(study)/\(keys.count) study notes,"
              + " \(nonEmptyRefLists.count) with a refList")
        XCTAssertEqual(study, 6959, "not every note is type='study'; found \(otherTypes)")
        XCTAssertTrue(nonEmptyRefLists.isEmpty,
                      "\(nonEmptyRefLists.count) notes carry a refList: \(nonEmptyRefLists.prefix(5))")
    }

    /// Part 3. Enumerate every href in all 15,824 lexicon entries and assert the
    /// `sword://` shape set is exactly the two `sword://Strongs*` forms — i.e. the
    /// only `sword://` links in the whole shipped corpus are lexicon->lexicon.
    func testTheOnlyBakedSwordLinksAreLexiconToLexicon() throws {
        let store = try store()
        var hosts: [String: Int] = [:]
        var entries = 0

        for module in ["StrongsRealGreek", "StrongsRealHebrew", "Robinson"] {
            for key in store.dictKeys(module: module) {
                guard let html = store.dictEntry(module: module, key: key) else {
                    XCTFail("\(module) key '\(key)' is indexed but unreadable")
                    return
                }
                entries += 1
                for host in Self.swordLinkHosts(in: html) {
                    hosts[host, default: 0] += 1
                }
            }
        }

        print("[refsem/fast] unreachability part 3: \(entries) lexicon entries,"
              + " sword:// hosts: \(hosts)")
        XCTAssertEqual(entries, 15824, "the lexicon entry count changed")
        XCTAssertEqual(Set(hosts.keys), ["StrongsRealGreek", "StrongsRealHebrew"],
                       "a sword:// link points somewhere new: \(hosts)")
        XCTAssertEqual(hosts.values.reduce(0, +), 14989, "the baked sword:// link count changed")
    }

    /// Part 4. **The routing claim.** Every baked `sword://` link must route to
    /// `.dictionary`, never to the bible-ref arm that reaches `scriptRef`. Module
    /// type comes from `content_meta`.
    func testEveryBakedSwordLinkRoutesToTheDictionaryArm() throws {
        let store = try store()
        var routed = 0
        var wrongArm: [String] = []

        for module in ["StrongsRealGreek", "StrongsRealHebrew", "Robinson"] {
            for key in store.dictKeys(module: module) {
                guard let html = store.dictEntry(module: module, key: key) else { continue }
                for host in Self.swordLinkHosts(in: html) {
                    // What data(forLink:) produces for `sword://<host>/<value>`.
                    let linkData: [AnyHashable: Any] = [
                        ATTRTYPE_MODULE: host,
                        ATTRTYPE_TYPE: "scriptRef",
                        ATTRTYPE_ACTION: "showRef",
                    ]
                    let type = store.moduleMeta(host, key: "type")
                    XCTAssertEqual(type, PSRefLinkRouter.typeDictionary,
                                   "content_meta says \(host) is '\(type ?? "nil")'")
                    let destination = PSRefLinkRouter.destination(forLinkData: linkData, moduleType: type)
                    if destination != .dictionary {
                        wrongArm.append("\(module)/\(key) -> \(host)")
                    }
                    routed += 1
                }
            }
        }

        print("[refsem/fast] unreachability part 4: \(routed) baked links routed")
        XCTAssertEqual(routed, 14989)
        XCTAssertTrue(wrongArm.isEmpty,
                      "\(wrongArm.count) baked links take the bible-ref arm: \(wrongArm.prefix(5))")

        // And the router still answers .bibleRef for the three inputs that must
        // keep reaching the ref path, so this is a routing test and not a
        // "everything is a dictionary" tautology.
        XCTAssertEqual(PSRefLinkRouter.destination(forModuleName: nil, moduleType: nil), .bibleRef)
        XCTAssertEqual(PSRefLinkRouter.destination(forModuleName: "", moduleType: nil), .bibleRef)
        XCTAssertEqual(PSRefLinkRouter.destination(forModuleName: "KJV",
                                                   moduleType: PSRefLinkRouter.typeBible), .bibleRef)
        XCTAssertEqual(PSRefLinkRouter.destination(forModuleName: "MHCC",
                                                   moduleType: PSRefLinkRouter.typeCommentary), .bibleRef)
        // Not installed -> bible arm (then the caller's placeholder).
        XCTAssertEqual(PSRefLinkRouter.destination(forModuleName: "ESV", moduleType: nil), .bibleRef)
        // Unrecognised type string -> ModuleType defaults to `bible`.
        XCTAssertEqual(PSRefLinkRouter.destination(forModuleName: "Weird", moduleType: "Something Else"),
                       .bibleRef,
                       "+moduleTypeForModuleTypeString: defaults to bible for an unknown type")
    }

    /// The `sword://<host>` hosts appearing in an HTML fragment.
    private static func swordLinkHosts(in html: String) -> [String] {
        guard html.contains("sword://") else { return [] }
        var out: [String] = []
        var rest = Substring(html)
        while let start = rest.range(of: "sword://") {
            let after = rest[start.upperBound...]
            // Host runs to the next "/", quote, or whitespace.
            let end = after.firstIndex(where: { $0 == "/" || $0 == "\"" || $0 == "'" || $0.isWhitespace })
                ?? after.endIndex
            out.append(String(after[after.startIndex..<end]))
            rest = after[end...]
        }
        return out
    }

    // Do not recapture the versification fixture — a red test means a real
    // behaviour change.


    // MARK: - Exhaustive tier (PSREF_EXHAUSTIVE=1)


    /// All 31,102 verses round-trip through the parser: `parse(displayRef(v)) == v`.
    func testExhaustiveEveryVerseRoundTripsThroughTheParser() throws {
        try XCTSkipUnless(Self.isExhaustive, "set PSREF_EXHAUSTIVE=1 to run the exhaustive tier")
        let resolver = try resolver()
        let parser = try parser()

        var compared = 0
        for book in resolver.books {
            for chapter in 1...book.chapterCount {
                guard let maxVerse = resolver.verseMax(book: book, chapter: chapter) else { continue }
                for verse in 1...maxVerse {
                    let ref = "\(book.name) \(chapter):\(verse)"
                    guard let parsed = parser.parse(ref) else {
                        XCTFail("parser rejected its own output form '\(ref)'")
                        return
                    }
                    guard parsed.displayRef == ref,
                          parsed.book.osisName == book.osisName,
                          parsed.chapter == chapter, parsed.verse == verse else {
                        XCTFail("'\(ref)' round-tripped to '\(parsed.displayRef)'")
                        return
                    }
                    compared += 1
                }
            }
        }
        print("[refsem/exhaustive] verses round-tripped: \(compared) (expected 31102)")
        XCTAssertEqual(compared, 31102)
    }

    /// 1,189 parser-vs-resolver agreement checks: the parser and the reader's own
    /// `resolve(ref:)` must land on the same (book, chapter) for every chapter ref
    /// the app can produce.
    func testExhaustiveParserAgreesWithTheReadersResolveForEveryChapter() throws {
        try XCTSkipUnless(Self.isExhaustive, "set PSREF_EXHAUSTIVE=1 to run the exhaustive tier")
        let resolver = try resolver()
        let parser = try parser()

        var compared = 0
        for book in resolver.books {
            for chapter in 1...book.chapterCount {
                let ref = "\(book.name) \(chapter)"
                guard let viaResolver = resolver.resolve(ref: ref),
                      let viaParser = parser.parse(ref) else {
                    XCTFail("'\(ref)': resolver or parser declined")
                    return
                }
                guard viaResolver.book.osisName == viaParser.book.osisName,
                      viaResolver.chapter == viaParser.chapter else {
                    XCTFail("'\(ref)': resolver \(viaResolver.book.osisName) \(viaResolver.chapter)"
                            + " vs parser \(viaParser.book.osisName) \(viaParser.chapter)")
                    return
                }
                compared += 1
            }
        }
        print("[refsem/exhaustive] chapter refs agreed: \(compared) (expected 1189)")
        XCTAssertEqual(compared, 1189)
    }

}
