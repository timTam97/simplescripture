//
//  PSSearchIndexParityTests.swift
//  SimpleScriptureTests
//
//  Proves the FTS index built from the baked content store is the same index the
//  SWORD engine produced. `Tests/Fixtures/search-index-KJV.digest` holds all 31,102
//  rows of the *engine-built* index, in rowid order, as `reference|book_osis|
//  testament|` plus a hash of each of the four text columns. This builds the index
//  with the real `PSSearchEngine.build(progress:)` and compares every row.
//
//  The failure mode this guards is silent — search results just quietly go
//  missing — so it stays in the default suite despite taking tens of seconds.
//
//  Do NOT recapture the digest to make a red test pass — see the fixture header.
//

import XCTest
import CryptoKit
import SQLite3
@testable import SimpleScripture

final class PSSearchIndexParityTests: XCTestCase {

    /// The engine's row count, which the digest's own header records.
    private static let expectedRowCount = 31102

    // MARK: - Fixture

    private static func fixtureURL(_ name: String) -> URL {
        if let override = ProcessInfo.processInfo.environment["PSORACLE_FIXTURE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent(name)
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Must match the capture's own digest exactly — SHA-256 truncated to its
    /// leading 64 bits (a change detector, not a commitment; 2.7 MB rather than
    /// 8.7 MB).
    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Building

    /// Build the KJV index through the store and return one digest line per row, in
    /// the same format and the same order the fixture holds.
    private func buildAndDigest() throws -> [String] {
        let engine = PSSearchEngine.engine(forModuleName: "KJV")
        do {
            try engine.build(progress: nil)
        } catch {
            XCTFail("index build failed: \(error.localizedDescription)")
            throw XCTSkip("build failed")
        }

        var db: OpaquePointer?
        let dbPath = engine.dbPath
        // A failure BEFORE each skip below, as for the build above. The build has
        // just returned, so an index that will not open or will not read is a
        // regression — and a bare skip reports it as a skipped test in a green run.
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            XCTFail("cannot open the built index at \(dbPath)")
            throw XCTSkip("cannot open the built index at \(dbPath)")
        }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        // ORDER BY rowid — the order results actually come back in (equivalent to
        // ordinal, which is strictly increasing and unique).
        let sql = "SELECT reference, book_osis, testament, text_plain, text_norm, lemmas, word_map"
            + " FROM verses ORDER BY rowid;"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            XCTFail("cannot read the built index: \(String(cString: sqlite3_errmsg(db)))"
                + " - the seven FTS columns are fixed")
            throw XCTSkip("cannot read the built index")
        }
        defer { sqlite3_finalize(st) }
        func text(_ c: Int32) -> String {
            guard let p = sqlite3_column_text(st, c) else { return "" }
            return String(cString: p)
        }
        var lines: [String] = []
        while sqlite3_step(st) == SQLITE_ROW {
            lines.append([text(0), text(1), String(sqlite3_column_int(st, 2)),
                          Self.sha256Hex(text(3)), Self.sha256Hex(text(4)),
                          Self.sha256Hex(text(5)), Self.sha256Hex(text(6))]
                .joined(separator: "|"))
        }
        return lines
    }

    // MARK: - The acceptance criterion

    /// The store-built index must equal the engine-built one the pre-work recorded,
    /// row for row, in order.
    func testStoreBuiltIndexMatchesTheEngineDigest() throws {
        let url = Self.fixtureURL("search-index-KJV.digest")
        guard let fixture = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("search-index-KJV.digest not captured")
        }
        // Drop the four `#` header lines and the trailing newline's empty element.
        let expected = fixture.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .map(String.init)
        XCTAssertEqual(expected.count, Self.expectedRowCount,
                       "the fixture itself is the wrong size — do not recapture to fix this")

        let actual = try buildAndDigest()
        XCTAssertEqual(actual.count, Self.expectedRowCount,
                       "the store build no longer produces \(Self.expectedRowCount) rows")

        guard actual.count == expected.count else { return }
        for (i, (a, e)) in zip(actual, expected).enumerated() where a != e {
            XCTFail("""
                row \(i) differs from the recorded engine-built index:
                  engine (fixture): \(e)
                  store  (built):   \(a)
                """)
            return  // one report is enough; 31k would be unreadable
        }
        print("[search-parity] \(actual.count) rows identical to the recorded engine index")
    }

    /// The same queries come back with results, which is what a user experiences.
    /// "The rows are right" and "a query finds them" are different failures (a
    /// tokenizer or FTS-expression change breaks the second without touching the
    /// first).
    func testQueriesReturnNonVacuousResults() throws {
        let engine = PSSearchEngine.engine(forModuleName: "KJV")
        do {
            try engine.build(progress: nil)
        } catch {
            // Failed first, then skipped: run on its own, a bare skip here turned
            // an index that cannot be built into a skipped test.
            XCTFail("index build failed: \(error.localizedDescription)")
            throw XCTSkip("build failed: \(error.localizedDescription)")
        }

        // A spread of shapes: a common word, a phrase, a rare word, a
        // Strong's-bearing query, and one that should match nothing.
        var out: [String: [String]] = [:]
        for query in ["\"lovingkindness\"", "\"in the beginning\"", "\"Nicodemus\"",
                      "\"shepherd\"", "\"zzzzznotaword\""] {
            let hits = engine.runQuery(query, scope: .AllRange, bookName: nil,
                                       limit: 50, strongsTokens: nil)
            out[query] = hits.map { $0.reference }
        }

        XCTAssertFalse(out["\"in the beginning\""]?.isEmpty ?? true, "phrase query found nothing")
        XCTAssertFalse(out["\"Nicodemus\""]?.isEmpty ?? true, "rare-word query found nothing")
        XCTAssertFalse(out["\"shepherd\""]?.isEmpty ?? true, "common-word query found nothing")
        XCTAssertFalse(out["\"lovingkindness\""]?.isEmpty ?? true, "lovingkindness found nothing")
        XCTAssertEqual(out["\"zzzzznotaword\""], [], "the negative control matched something")
        // Genesis 1:1 is the first hit for the canonical phrase, which also pins that
        // results come back in index order rather than an arbitrary one.
        XCTAssertEqual(out["\"in the beginning\""]?.first, "Genesis 1:1",
                       "the phrase query's first hit moved")
        print("[search-parity] queries: \(out.mapValues { $0.count })")
    }

    // MARK: - Text normalisation (MOVED here from SwordOracleCaptureTests, step 12)

    /// `cleanDisplayText` strips the inline `<H0430>` / `<TH8799>` markers plus the
    /// `" [] "` empty-tag marker, collapsing whatever whitespace that leaves —
    /// including a space stranded before punctuation.
    ///
    /// Load-bearing beyond display: it is applied **before** the emptiness test in
    /// the index build, so it decides which rows exist at all. The expectations are
    /// the original engine implementation's outputs.
    func testCleanDisplayTextStripsInlineMarkers() {
        XCTAssertEqual(PSSearchQuery.cleanDisplayText("And God <H0430> divided <H0996> the light"),
                       "And God divided the light")
        XCTAssertEqual(PSSearchQuery.cleanDisplayText("word <TH8799> in <TG5707> place"),
                       "word in place")
        XCTAssertEqual(PSSearchQuery.cleanDisplayText("in the field <H7704> , and"),
                       "in the field, and")
        XCTAssertEqual(PSSearchQuery.cleanDisplayText("a [] b"), "a b")
        XCTAssertEqual(PSSearchQuery.cleanDisplayText(""), "")
    }

    /// The diacritic fold, pinned against **known vectors**: Greek polytonic accents
    /// (U+0300-U+036F after NFD), Hebrew points and cantillation (U+0591-U+05C7,
    /// which FTS5's `remove_diacritics=2` leaves alone), Latin diacritics in both
    /// precomposed and decomposed form, and the other combining-mark ranges. The
    /// expectations are the values the original implementation produced, so a
    /// change here breaks queries against indexes already built on devices.
    func testFoldForIndexHandlesEveryTargetedRange() {
        let cases: [(input: String, expected: String)] = [
            ("", ""),
            ("plain ascii text", "plain ascii text"),
            ("MiXeD CaSe", "mixed case"),
            // Greek polytonic: accents dropped, letters lower-cased.
            ("ἀγάπη", "αγαπη"),
            ("Θεός", "θεος"),
            ("λόγος", "λογος"),
            // Hebrew: points and cantillation dropped, consonants kept.
            ("אֱלֹהִים", "אלהים"),
            ("בְּרֵאשִׁית", "בראשית"),
            ("יְהוָ֣ה", "יהוה"),
            // Latin, precomposed and decomposed — must fold identically.
            ("café", "cafe"),
            ("cafe\u{0301}", "cafe"),
            // The other dropped combining ranges.
            ("a\u{20D0}b", "ab"),
            ("x\u{FE20}y", "xy"),
            ("q\u{1DC0}r", "qr"),
            ("m\u{1AB0}n", "mn"),
        ]
        for c in cases {
            XCTAssertEqual(PSSearchQuery.foldForIndex(c.input), c.expected,
                           "fold of \(c.input.debugDescription)")
        }

        // Non-BMP input must survive the surrogate-pair branch without corruption.
        XCTAssertEqual(PSSearchQuery.foldForIndex("𝔊𝔯𝔢𝔢𝔨 text").hasSuffix(" text"), true)
        XCTAssertFalse(PSSearchQuery.foldForIndex("😀 emoji").isEmpty)
    }

    // MARK: - Query building
    //
    // Plain tests of `PSSearchQuery`. Nothing from here down builds or opens the
    // index.

    /// Typographic quotes delimit a phrase, as straight ones do.
    ///
    /// Smart Punctuation turns a typed " into “ or ” wherever it is in effect,
    /// and pasted text carries them regardless. The parser knew only U+0022, so
    /// a phrase in curly quotes ran as its separate words in All and Any modes —
    /// `"“in" AND "the" AND "beginning”"`, every verse with all three words, or
    /// with any of them — and quoting is the only way to combine a phrase with
    /// other words.
    func testTypographicQuotesMakeAPhrase() {
        func expression(
            _ query: String,
            _ matchType: PSSearchType,
            fuzzy: Bool = false
        ) -> String? {
            PSSearchQuery.fts5Expression(fromUserInput: query, matchType: matchType,
                                         fuzzy: fuzzy, strongs: false)
        }
        let curly = "\u{201C}in the beginning\u{201D}"
        let phrase = "text_norm:\"in the beginning\""

        XCTAssertEqual(expression(curly, .AndSearch), phrase)
        XCTAssertEqual(expression(curly, .OrSearch), phrase)
        XCTAssertEqual(expression(curly, .ExactSearch), phrase)
        // A phrase stays a phrase under the fuzzy toggle.
        XCTAssertEqual(expression(curly, .AndSearch, fuzzy: true), phrase)
        XCTAssertEqual(
            expression("God \u{201C}the world\u{201D} loved", .AndSearch),
            "text_norm:\"god\" AND text_norm:\"the world\" AND text_norm:\"loved\"")
        // The low and reversed forms other keyboards open a quotation with.
        XCTAssertEqual(expression("\u{201E}the world\u{201F}", .OrSearch),
                       "text_norm:\"the world\"")

        // Straight quotes build what they always did: the same expressions.
        XCTAssertEqual(expression("\"in the beginning\"", .AndSearch), phrase)
        XCTAssertEqual(
            expression("God \"the world\" loved", .AndSearch),
            "text_norm:\"god\" AND text_norm:\"the world\" AND text_norm:\"loved\"")
    }

    /// What FTS5 makes of `expression`: how many rows of a one-row, in-memory
    /// table it matches — the index's tokenizer and its two searched columns —
    /// or nil, with SQLite's message, when the MATCH is rejected. A rejected
    /// MATCH is what the app shows as "No Results". Not the KJV index.
    ///
    /// `verse` is the row's text as the verse prints it. It is stored the way
    /// the build stores `text_norm`: through `foldForIndex`.
    private func matchAgainstOneRow(
        _ expression: String?,
        verse: String = "and they say hi to god"
    ) -> (rows: Int?, error: String) {
        guard let expression else { return (nil, "no expression was built") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                              nil) == SQLITE_OK, let db else {
            return (nil, "cannot open an in-memory database")
        }
        defer { sqlite3_close(db) }
        func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

        // The text goes into the SQL as a literal, so a `'` of its own is doubled.
        let textNorm = PSSearchQuery.foldForIndex(verse)
            .replacingOccurrences(of: "'", with: "''", options: .literal)
        let setUp = "CREATE VIRTUAL TABLE verses USING fts5(text_norm, lemmas,"
            + " tokenize='unicode61 remove_diacritics 2');"
            + " INSERT INTO verses VALUES('\(textNorm)', 'H430 H0430');"
        guard sqlite3_exec(db, setUp, nil, nil, nil) == SQLITE_OK else {
            return (nil, "set-up failed: \(lastError())")
        }
        var st: OpaquePointer?
        let sql = "SELECT count(*) FROM verses WHERE verses MATCH ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            return (nil, "prepare failed: \(lastError())")
        }
        defer { sqlite3_finalize(st) }
        // SQLITE_TRANSIENT, as in `PSSearchEngine`: the bridged C string is valid
        // only for the duration of the call.
        sqlite3_bind_text(st, 1, expression, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(st) == SQLITE_ROW else { return (nil, lastError()) }
        return (Int(sqlite3_column_int(st, 0)), "")
    }

    /// A quote inside a phrase is doubled whatever scalar follows it.
    ///
    /// `quote()` escaped with a search that compares whole composed characters,
    /// and a quote followed by a combining or variation-selector scalar is one
    /// character that is not `"`. It went through undoubled and ended the FTS5
    /// string early, so the MATCH was rejected and the user saw "No Results".
    /// Reaching it takes a paste, or a keyboard with standalone combining marks.
    ///
    /// Counted in scalars on purpose: `String` equality works over whole
    /// characters too, which is the comparison that hid the quote.
    func testAnEmbeddedQuoteBeforeACombiningScalarIsEscaped() {
        func quoteCount(_ expression: String?) -> Int? {
            expression?.unicodeScalars.filter { $0 == "\"" }.count
        }

        // Exact mode hands the whole body to `quote()`. U+FE0F survives the fold.
        let exact = PSSearchQuery.fts5Expression(
            fromUserInput: "say \"\u{FE0F}hi", matchType: .ExactSearch,
            fuzzy: false, strongs: false)
        XCTAssertEqual(quoteCount(exact), 4, "the wrapping pair plus one doubled quote")
        let exactMatch = matchAgainstOneRow(exact)
        XCTAssertEqual(exactMatch.rows, 1, "FTS5: \(exactMatch.error)")

        // Strong's mode does not fold its tokens, so a mark the fold would have
        // stripped (U+0301) gets here as well.
        let strongs = PSSearchQuery.fts5Expression(
            fromUserInput: "H430\"\u{0301}", matchType: .AndSearch,
            fuzzy: false, strongs: true)
        XCTAssertEqual(quoteCount(strongs), 4, "the wrapping pair plus one doubled quote")
        let strongsMatch = matchAgainstOneRow(strongs)
        XCTAssertEqual(strongsMatch.rows, 1, "FTS5: \(strongsMatch.error)")

        // A quote with nothing combining after it is escaped as it always was.
        XCTAssertEqual(
            PSSearchQuery.fts5Expression(fromUserInput: "God \"said", matchType: .ExactSearch,
                                         fuzzy: false, strongs: false),
            "text_norm:\"god \"\"said\"")
    }

    /// Fuzzy matches a word with punctuation inside it as typed, not as its
    /// halves glued into one prefix.
    ///
    /// The fuzzy arm made its prefix by deleting every character that is not a
    /// letter or digit, so `Beer-sheba` asked for words starting `beersheba` and
    /// `God’s` for words starting `gods`. The index's tokenizer splits at that
    /// same punctuation — the text holds `beer` + `sheba` and `god` + `s` — so
    /// the first found nothing (33 verses with Fuzzy off) and the second listed
    /// the 215 verses with the plural "gods" in place of the 25 with the
    /// possessive.
    func testFuzzyKeepsAPunctuatedWordAsTyped() {
        func expression(_ query: String, fuzzy: Bool = true) -> String? {
            PSSearchQuery.fts5Expression(fromUserInput: query, matchType: .AndSearch,
                                         fuzzy: fuzzy, strongs: false)
        }

        XCTAssertEqual(expression("Beer-sheba"), "text_norm:\"beer-sheba\"")
        XCTAssertEqual(expression("God\u{2019}s"), "text_norm:\"god\u{2019}s\"")
        XCTAssertEqual(expression("God's"), "text_norm:\"god's\"")
        // Only the punctuated word changes: its neighbour is still a prefix.
        XCTAssertEqual(expression("God\u{2019}s word"),
                       "text_norm:\"god\u{2019}s\" AND text_norm:word*")
        // It is the expression Fuzzy off builds, so turning Fuzzy on can never
        // find fewer verses than the same search without it.
        for query in ["Beer-sheba", "God\u{2019}s", "God's", "Abed-nego"] {
            XCTAssertEqual(expression(query), expression(query, fuzzy: false), query)
        }

        // Punctuation around a word is not inside it. Each of these is one word
        // and stays the prefix it always was.
        XCTAssertEqual(expression("rev"), "text_norm:rev*")
        XCTAssertEqual(expression("God,"), "text_norm:god*")
        XCTAssertEqual(expression("(God)"), "text_norm:god*")
        XCTAssertEqual(expression("sons'"), "text_norm:sons*")
        XCTAssertEqual(expression("Baal-"), "text_norm:baal*")
        XCTAssertEqual(expression("-sheba"), "text_norm:sheba*")
        // No letter or digit to make a prefix of: the quoted fallback, as before.
        XCTAssertEqual(expression("--"), "text_norm:\"--\"")

        // What FTS5 finds with them, in verses as the KJV prints them: the name
        // with an en dash, the possessive with a typographic apostrophe. The
        // typed ASCII hyphen and apostrophe split the word at the same place.
        let genesis26v23 = "And he went up from thence to Beer\u{2013}sheba."
        let firstCorinthians3v23 = "And ye are Christ\u{2019}s; and Christ is God\u{2019}s."
        let exodus20v3 = "Thou shalt have no other gods before me."

        let name = matchAgainstOneRow(expression("Beer-sheba"), verse: genesis26v23)
        XCTAssertEqual(name.rows, 1, "FTS5: \(name.error)")
        for query in ["God\u{2019}s", "God's"] {
            let possessive = matchAgainstOneRow(expression(query), verse: firstCorinthians3v23)
            XCTAssertEqual(possessive.rows, 1, "\(query), FTS5: \(possessive.error)")
            let plural = matchAgainstOneRow(expression(query), verse: exodus20v3)
            XCTAssertEqual(plural.rows, 0, "\(query), FTS5: \(plural.error)")
        }
        // A one-word prefix still widens: "God" finds the plural too.
        let prefix = matchAgainstOneRow(expression("God"), verse: exodus20v3)
        XCTAssertEqual(prefix.rows, 1, "FTS5: \(prefix.error)")
    }

    /// A typed "ae" also finds the æ ligature, and the other way round.
    ///
    /// The KJV prints Cæsar, Judæa, Zacchæus and eleven other words with the
    /// ligature, in 86 verses. It has no decomposition, so the index's fold and
    /// tokenizer both leave it alone, and a typed `Caesar` matched only the two
    /// verses that happen to be spelt without it — 2 of 24, and not "Render
    /// therefore unto Cæsar". `Zacchaeus` matched nothing at all.
    ///
    /// The index is pinned, so the two spellings are ORed in the query.
    func testAeSpellingsFindTheLigatureForms() {
        func expression(
            _ query: String,
            _ matchType: PSSearchType = .AndSearch,
            fuzzy: Bool = false
        ) -> String? {
            PSSearchQuery.fts5Expression(fromUserInput: query, matchType: matchType,
                                         fuzzy: fuzzy, strongs: false)
        }
        let caesar = "(text_norm:\"caesar\" OR text_norm:\"c\u{00E6}sar\")"

        XCTAssertEqual(expression("Caesar"), caesar)
        XCTAssertEqual(expression("Caesar", fuzzy: true),
                       "(text_norm:caesar* OR text_norm:c\u{00E6}sar*)")
        // One operand of the join around it, in parentheses.
        XCTAssertEqual(expression("render unto Caesar"),
                       "text_norm:\"render\" AND text_norm:\"unto\" AND \(caesar)")
        XCTAssertEqual(expression("Caesar tribute", .OrSearch),
                       "\(caesar) OR text_norm:\"tribute\"")
        // A phrase, quoted or as the whole of an Exact search.
        let phrase = "(text_norm:\"unto caesar\" OR text_norm:\"unto c\u{00E6}sar\")"
        XCTAssertEqual(expression("unto Caesar", .ExactSearch), phrase)
        XCTAssertEqual(expression("\"unto Caesar\" tribute"),
                       "\(phrase) AND text_norm:\"tribute\"")
        // Typed with the ligature (or pasted from a verse), it finds the two
        // verses spelt without it as well.
        XCTAssertEqual(expression("C\u{00E6}sar"),
                       "(text_norm:\"c\u{00E6}sar\" OR text_norm:\"caesar\")")
        // A possessive under Fuzzy is matched as typed, in each spelling.
        XCTAssertEqual(
            expression("Caesar\u{2019}s", fuzzy: true),
            "(text_norm:\"caesar\u{2019}s\" OR text_norm:\"c\u{00E6}sar\u{2019}s\")")
        // Every word with "ae" in it takes the second arm, the ones the KJV
        // never spells with a ligature included. That arm matches nothing.
        XCTAssertEqual(expression("Israel"),
                       "(text_norm:\"israel\" OR text_norm:\"isr\u{00E6}l\")")

        // Without an "ae" the expression is what it always was, byte for byte.
        XCTAssertEqual(expression("God"), "text_norm:\"god\"")
        XCTAssertEqual(expression("God", fuzzy: true), "text_norm:god*")
        XCTAssertEqual(expression("God so loved"),
                       "text_norm:\"god\" AND text_norm:\"so\" AND text_norm:\"loved\"")
        XCTAssertEqual(expression("God so loved", .OrSearch),
                       "text_norm:\"god\" OR text_norm:\"so\" OR text_norm:\"loved\"")
        XCTAssertEqual(expression("God so loved", .ExactSearch),
                       "text_norm:\"god so loved\"")
        XCTAssertEqual(expression("\"so loved\" God", fuzzy: true),
                       "text_norm:\"so loved\" AND text_norm:god*")
        // A letter apart is not an "ae".
        XCTAssertEqual(expression("a e"), "text_norm:\"a\" AND text_norm:\"e\"")
        // Strong's mode searches lemmas, not text, and takes no second spelling.
        XCTAssertEqual(
            PSSearchQuery.fts5Expression(fromUserInput: "Caesar", matchType: .AndSearch,
                                         fuzzy: false, strongs: true),
            "lemmas:(\"Caesar\")")

        // What FTS5 finds with them, in verses as the KJV prints them: one with
        // the ligature, one of the two without.
        let luke20v25 = "And he said unto them, Render therefore unto C\u{00E6}sar the things"
            + " which be C\u{00E6}sar\u{2019}s, and unto God the things which be God\u{2019}s."
        let matthew22v17 = "Tell us therefore, What thinkest thou? Is it lawful to give"
            + " tribute unto Caesar, or not?"
        let queries: [(query: String, matchType: PSSearchType, fuzzy: Bool)] = [
            ("Caesar", .AndSearch, false),
            ("Caesar", .AndSearch, true),
            ("C\u{00E6}sar", .AndSearch, false),
            ("unto Caesar", .ExactSearch, false),
            ("\"unto Caesar\" lawful render", .OrSearch, false),
        ]
        for (query, matchType, fuzzy) in queries {
            let built = expression(query, matchType, fuzzy: fuzzy)
            for verse in [luke20v25, matthew22v17] {
                let match = matchAgainstOneRow(built, verse: verse)
                XCTAssertEqual(match.rows, 1,
                               "\(query) in \(verse.prefix(24))…, FTS5: \(match.error)")
            }
        }
        let allWords = expression("render unto Caesar")
        let ligature = matchAgainstOneRow(allWords, verse: luke20v25)
        XCTAssertEqual(ligature.rows, 1, "FTS5: \(ligature.error)")
        // Still every word: the verse without "render" is not a match.
        let other = matchAgainstOneRow(allWords, verse: matthew22v17)
        XCTAssertEqual(other.rows, 0, "FTS5: \(other.error)")
    }

    // MARK: - Highlighting

    /// A search term is marked where the query matched it: on whole words.
    ///
    /// FTS5 holds a verse as tokens, its runs of letters and digits, and a typed
    /// word is one of them. Both highlighters — the result row and the reader —
    /// looked for the term's characters anywhere in the text instead. So `the`
    /// was marked inside "father", "there" and "thee", `is` inside "his", and
    /// with Fuzzy on the mark ran from wherever the letters were found to the
    /// end of that word ("ther" in "father"); while a phrase the query found
    /// across a comma or a colon, or a possessive typed with the other
    /// apostrophe, was marked nowhere.
    ///
    /// `PSSearchQuery.highlightRanges(of:in:)` now decides for both. This pins
    /// what it marks in verses as the KJV prints them, and then holds it to
    /// FTS5 itself: over every query and verse below, a verse has a mark exactly
    /// when the query's own expression matches it.
    @MainActor
    func testASearchTermIsMarkedWhereTheQueryMatchedIt() {
        /// The stretches of `verse` marked for `query`, in reading order,
        /// whatever order the terms were typed in.
        func marked(
            _ query: String,
            _ matchType: PSSearchType = .AndSearch,
            fuzzy: Bool = false,
            in verse: String
        ) -> [String] {
            let terms = SearchModel.highlightTerms(
                query: query, matchType: matchType, fuzzy: fuzzy, strongs: false)
            return PSSearchQuery.highlightRanges(of: terms, in: verse)
                .map { String(verse[$0]) }
        }

        let genesis46v3 = "And he said, I am God, the God of thy father: fear not to go"
            + " down into Egypt; for I will there make of thee a great nation:"
        let genesis1v3 = "And God said, Let there be light: and there was light."
        let isaiah6v3 = "And one cried unto another, and said, Holy, holy, holy, is the"
            + " LORD of hosts: the whole earth is full of his glory."
        let firstCorinthians3v23 = "And ye are Christ\u{2019}s; and Christ is God\u{2019}s."
        let genesis26v23 = "And he went up from thence to Beer\u{2013}sheba."
        let luke20v25 = "And he said unto them, Render therefore unto C\u{00E6}sar the things"
            + " which be C\u{00E6}sar\u{2019}s, and unto God the things which be God\u{2019}s."
        let firstJohn4v11 = "Beloved, if God so loved us, we ought also to love one another."

        // The reported case. One "the" in the verse, and three more words with
        // those letters in them.
        XCTAssertEqual(marked("the", in: genesis46v3), ["the"])
        XCTAssertEqual(marked("he", in: genesis46v3), ["he"])
        XCTAssertEqual(marked("is", in: isaiah6v3), ["is", "is"])
        XCTAssertEqual(marked("the", in: luke20v25), ["the", "the"])
        // Letters that are no word of the verse mark nothing.
        XCTAssertEqual(marked("fat", in: genesis46v3), [])
        XCTAssertEqual(marked("ther", in: genesis46v3), [])
        // Case, and punctuation typed against the word, change nothing.
        XCTAssertEqual(marked("GOD", in: genesis46v3), ["God", "God"])
        XCTAssertEqual(marked("light.", in: genesis1v3), ["light", "light"])
        XCTAssertEqual(marked("lord", in: isaiah6v3), ["LORD"])

        // Fuzzy runs a word as a prefix: every word that BEGINS with it, whole.
        // Not "father", which only contains it.
        XCTAssertEqual(marked("the", fuzzy: true, in: genesis46v3),
                       ["the", "there", "thee"])
        XCTAssertEqual(marked("fat", fuzzy: true, in: genesis46v3), ["father"])
        XCTAssertEqual(marked("ther", fuzzy: true, in: genesis46v3), ["there"])
        XCTAssertEqual(marked("lov", fuzzy: true, in: firstJohn4v11), ["loved", "love"])
        // An Exact search and a quoted phrase are not prefixes, whatever the
        // option says.
        XCTAssertEqual(marked("lov", .ExactSearch, fuzzy: true, in: firstJohn4v11), [])
        XCTAssertEqual(marked("\"lov\"", fuzzy: true, in: firstJohn4v11), [])

        // A phrase is its words in a row, across whatever the verse prints
        // between them; the mark takes that in, and stops at the last word.
        XCTAssertEqual(marked("light and there was light", .ExactSearch, in: genesis1v3),
                       ["light: and there was light"])
        XCTAssertEqual(marked("\"said let\"", in: genesis1v3), ["said, Let"])
        XCTAssertEqual(marked("\"God, the God\"", in: genesis46v3), ["God, the God"])
        // A phrase that repeats a word fits twice here, one word apart, and
        // the two are one mark: all three words, as FTS5's own highlight()
        // brackets them.
        XCTAssertEqual(marked("holy holy", .ExactSearch, in: isaiah6v3),
                       ["Holy, holy, holy"])
        // Several terms come back in reading order, whatever order they were
        // typed in.
        XCTAssertEqual(marked("father God the", .OrSearch, in: genesis46v3),
                       ["God", "the", "God", "father"])
        // One letter is a word like any other.
        XCTAssertEqual(marked("I", in: genesis46v3), ["I", "I"])
        XCTAssertEqual(marked("a", in: genesis46v3), ["a"])
        // The words out of order are not the phrase.
        XCTAssertEqual(marked("light said", .ExactSearch, in: genesis1v3), [])

        // A possessive and a hyphenated name are split where the index splits
        // them, so either apostrophe and either dash finds what is printed.
        for query in ["God's", "God\u{2019}s"] {
            XCTAssertEqual(marked(query, in: firstCorinthians3v23), ["God\u{2019}s"], query)
            // As typed under Fuzzy too: the builder does not make a prefix of it.
            XCTAssertEqual(marked(query, fuzzy: true, in: firstCorinthians3v23),
                           ["God\u{2019}s"], query)
        }
        XCTAssertEqual(marked("Christ", in: firstCorinthians3v23), ["Christ", "Christ"])
        XCTAssertEqual(marked("Beer-sheba", in: genesis26v23), ["Beer\u{2013}sheba"])
        XCTAssertEqual(marked("sheba", in: genesis26v23), ["sheba"])
        XCTAssertEqual(marked("he", in: genesis26v23), ["he"])
        // Both spellings of an ae word are terms, and each is a whole word.
        XCTAssertEqual(marked("Caesar", in: luke20v25), ["C\u{00E6}sar", "C\u{00E6}sar"])

        // Held to FTS5: a verse is marked exactly when the query matches it.
        // One term or one phrase to a query, so that "matches" means this term.
        let verses = [genesis46v3, genesis1v3, isaiah6v3, firstCorinthians3v23,
                      genesis26v23, luke20v25, firstJohn4v11]
        let queries = [
            "the", "he", "is", "an", "or", "art", "ye", "us", "so", "hat", "I", "a", "s",
            "God", "god's", "God\u{2019}s", "gods", "Christ", "lord", "holy", "whole",
            "light", "there", "fat", "ther", "lov", "love", "loved", "beloved", "be",
            "Beer-sheba", "beer", "sheba", "Caesar", "C\u{00E6}sar", "Caesar's", "thing",
            "light.", "(God)", "--",
            "\"said let\"", "\"holy holy\"", "\"the god\"", "\"god the\"",
            "\"unto caesar\"", "\"and christ is\"", "\"to beer sheba\"", "\"lov\"",
        ]
        var compared = 0
        var matched = 0
        for query in queries {
            for (matchType, fuzzy) in [(PSSearchType.AndSearch, false), (.AndSearch, true),
                                       (.ExactSearch, false), (.ExactSearch, true)] {
                let expression = PSSearchQuery.fts5Expression(
                    fromUserInput: query, matchType: matchType, fuzzy: fuzzy, strongs: false)
                for verse in verses {
                    let match = matchAgainstOneRow(expression, verse: verse)
                    guard let rows = match.rows else {
                        XCTFail("\(query): FTS5 rejected \(expression ?? "nil"): \(match.error)")
                        continue
                    }
                    let marks = marked(query, matchType, fuzzy: fuzzy, in: verse)
                    XCTAssertEqual(
                        !marks.isEmpty, rows == 1,
                        "\(query) (\(matchType == .ExactSearch ? "Exact" : "All"),"
                            + " fuzzy \(fuzzy)) in \(verse.prefix(28))…: FTS5 matched"
                            + " \(rows) row(s), marked \(marks)")
                    compared += 1
                    matched += rows
                }
            }
        }
        // Neither side of the comparison is vacuous.
        XCTAssertEqual(compared, queries.count * 4 * verses.count)
        XCTAssertGreaterThan(matched, 100, "FTS5 matched almost nothing: \(matched)")
        XCTAssertLessThan(matched, compared - 100, "FTS5 matched almost everything")
    }

    /// The highlighter cuts a text into words where the index's tokenizer does,
    /// character by character.
    ///
    /// Whole-word marking is only as good as its idea of a word. The index's is
    /// FTS5's `unicode61` over `foldForIndex(text)`; the highlighter's is its
    /// own (`PSSearchQuery.highlightTokens`: letters and digits, with the marks
    /// the fold deletes stepped over), because it has to keep each word's place
    /// in the text as displayed. This holds one to the other on the simulator's
    /// own SQLite: for every character `c` of the scripts the modules are in,
    /// `x`+`c`+`y` is two words, one word `xy`, or one longer word to both.
    ///
    /// The ranges are Latin, the combining marks, Greek and Cyrillic
    /// (U+0001–052F), Hebrew (U+0590–05FF), and Latin Extended Additional
    /// through General Punctuation (U+1E00–2064): the apostrophes, dashes and
    /// quotes a verse is printed with are in the last. Then the rest of what
    /// the highlighter's rule names and those scripts do not use: the other
    /// four ranges of marks the fold deletes (U+1AB0–1AFF, U+1DC0–1DFF,
    /// U+20D0–20FF, U+FE20–FE2F), digits that are not ASCII (U+0660–0669),
    /// letter numbers (U+2160–2188) and private use (U+E000–E0FF).
    ///
    /// Measured on macOS (SQLite 3.54.1) over the whole BMP, the two disagree
    /// on 1,731 of 63,488 code points, none of them here. FTS5's tables are
    /// Unicode 6.1's and it takes every code point that was unassigned then
    /// for part of a word: 1,331 still unassigned, and 379 symbols and marks
    /// assigned since (the Turkish lira sign U+20BA, the bidi isolates
    /// U+2066–2069). And 21 marks have become letters since: 19 New Tai Lue
    /// vowel signs and tone marks and 2 Vedic signs. An unassigned code point
    /// is skipped below for the first reason.
    func testTheHighlighterCutsWordsWhereTheIndexDoes() throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            return XCTFail("cannot open an in-memory database")
        }
        defer { sqlite3_close(db) }
        func lastError() -> String { String(cString: sqlite3_errmsg(db)) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        // One row per character: `x`+`c`+`y`, stored as the build stores
        // `text_norm`, under the index's tokenizer. The rowid is the code point.
        guard sqlite3_exec(db, "CREATE VIRTUAL TABLE verses USING fts5(text_norm,"
                           + " tokenize='unicode61 remove_diacritics 2'); BEGIN;",
                           nil, nil, nil) == SQLITE_OK else {
            return XCTFail("set-up failed: \(lastError())")
        }
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO verses(rowid, text_norm) VALUES (?, ?);",
                                 -1, &insert, nil) == SQLITE_OK else {
            return XCTFail("prepare failed: \(lastError())")
        }
        var characters: [Unicode.Scalar] = []
        let ranges: [ClosedRange<UInt32>] = [
            0x0001...0x052F, 0x0590...0x05FF, 0x1E00...0x2064,
            0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F,
            0x0660...0x0669, 0x2160...0x2188, 0xE000...0xE0FF,
        ]
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value),
                      scalar.properties.generalCategory != .unassigned else { continue }
                characters.append(scalar)
                sqlite3_bind_int64(insert, 1, sqlite3_int64(value))
                sqlite3_bind_text(insert, 2, PSSearchQuery.foldForIndex("x\(scalar)y"),
                                  -1, transient)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    sqlite3_finalize(insert)
                    return XCTFail("insert failed at U+\(String(value, radix: 16)):"
                                   + " \(lastError())")
                }
                sqlite3_reset(insert)
            }
        }
        sqlite3_finalize(insert)
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            return XCTFail("commit failed: \(lastError())")
        }

        /// The code points whose row FTS5 matches with `expression`.
        func rows(matching expression: String) -> Set<UInt32>? {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rowid FROM verses WHERE verses MATCH ?;",
                                     -1, &st, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_text(st, 1, expression, -1, transient)
            var out = Set<UInt32>()
            while true {
                let rc = sqlite3_step(st)
                if rc == SQLITE_ROW {
                    out.insert(UInt32(sqlite3_column_int64(st, 0)))
                } else if rc == SQLITE_DONE {
                    return out
                } else {
                    return nil
                }
            }
        }
        // Two words: the phrase "x y" is found. One word "xy": the character
        // was no part of it and split nothing.
        let between = try XCTUnwrap(rows(matching: "text_norm:\"x y\""),
                                    "FTS5: \(lastError())")
        let nothing = try XCTUnwrap(rows(matching: "text_norm:\"xy\""),
                                    "FTS5: \(lastError())")
        XCTAssertTrue(between.isDisjoint(with: nothing))

        enum Cut: String { case separatesWords, isNoPartOfAWord, isPartOfAWord }
        var disagreements: [String] = []
        var seen: [Cut: Int] = [:]
        for scalar in characters {
            let index: Cut = between.contains(scalar.value) ? .separatesWords
                : nothing.contains(scalar.value) ? .isNoPartOfAWord : .isPartOfAWord
            let text = "x\(scalar)y"
            let highlighter: Cut =
                !PSSearchQuery.highlightRanges(of: ["x y"], in: text).isEmpty ? .separatesWords
                : !PSSearchQuery.highlightRanges(of: ["xy"], in: text).isEmpty ? .isNoPartOfAWord
                : .isPartOfAWord
            seen[index, default: 0] += 1
            if index != highlighter {
                disagreements.append(
                    "U+\(String(scalar.value, radix: 16, uppercase: true)):"
                        + " the index says it \(index.rawValue),"
                        + " the highlighter that it \(highlighter.rawValue)")
            }
        }
        XCTAssertEqual(disagreements, [])

        // All three answers are in play, in about the numbers measured on
        // macOS with Unicode 17's tables (297 separators, 338 marks the fold
        // deletes, 1,839 letters and digits). How many code points of the
        // newer mark ranges are assigned depends on the system's own tables.
        XCTAssertGreaterThan(characters.count, 2_300)
        XCTAssertGreaterThan(seen[.separatesWords] ?? 0, 250)
        XCTAssertGreaterThan(seen[.isNoPartOfAWord] ?? 0, 280)
        XCTAssertGreaterThan(seen[.isPartOfAWord] ?? 0, 1_700)
        // Each of the fold's six ranges is walked, and each kind of word
        // character that is not a plain letter.
        for value: UInt32 in [0x0301, 0x05B0, 0x1AB0, 0x1DC0, 0x20D0, 0xFE20] {
            XCTAssertTrue(nothing.contains(value),
                          "U+\(String(value, radix: 16)) is not deleted by the fold")
        }
        for value: UInt32 in [0x0661, 0x2160, 0xE000] {
            XCTAssertFalse(between.contains(value) || nothing.contains(value),
                           "U+\(String(value, radix: 16)) is not part of a word to FTS5")
        }
        // The characters the KJV text is printed with, by name.
        for (scalar, cut): (Unicode.Scalar, Cut) in [
            ("\u{2019}", .separatesWords), ("\u{2013}", .separatesWords),
            ("\u{2014}", .separatesWords), ("'", .separatesWords), ("-", .separatesWords),
            ("\u{00E6}", .isPartOfAWord), ("\u{00C6}", .isPartOfAWord),
        ] {
            XCTAssertTrue(characters.contains(scalar), "U+\(scalar.value) is not covered")
            let index: Cut = between.contains(scalar.value) ? .separatesWords
                : nothing.contains(scalar.value) ? .isNoPartOfAWord : .isPartOfAWord
            XCTAssertEqual(index, cut, "U+\(String(scalar.value, radix: 16))")
        }
    }
}
