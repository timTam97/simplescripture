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
}
