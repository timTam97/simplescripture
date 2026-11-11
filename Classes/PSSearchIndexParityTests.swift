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
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw XCTSkip("cannot open the built index at \(dbPath)")
        }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        // ORDER BY rowid — the order results actually come back in (equivalent to
        // ordinal, which is strictly increasing and unique).
        let sql = "SELECT reference, book_osis, testament, text_plain, text_norm, lemmas, word_map"
            + " FROM verses ORDER BY rowid;"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
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
}
