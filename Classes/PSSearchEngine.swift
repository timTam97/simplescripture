//
//  PSSearchEngine.swift
//  PocketSword
//
//  SQLite FTS5-backed search engine for Bible/commentary modules. One engine
//  instance per module, keyed by module name; the underlying sqlite3 handle is
//  shared across threads (SQLITE_OPEN_FULLMUTEX).
//
//  Five things here are load-bearing, and a plausible-looking "simplification"
//  breaks each of them silently rather than loudly:
//
//   1. **`SQLITE_TRANSIENT` on every `sqlite3_bind_text`.** Bridging a Swift
//      `String` to `const char *` yields a buffer valid only for the duration of
//      the call, so the default `SQLITE_STATIC` leaves SQLite holding a dangling
//      pointer by the time `sqlite3_step` runs. The symptom is not a crash —
//      every query silently matches nothing. Same hazard for the SQL text handed
//      to `prepare_v2` / `exec`, which is why both go through `withCString`.
//   2. **`SQLITE_OPEN_FULLMUTEX` + `sqlite3_busy_timeout(2000)`, and NO serial
//      queue.** A ~30-second index build runs on one global queue while queries
//      run on another, and FULLMUTEX serialises per *call* rather than per
//      transaction — a serial queue would serialise the whole build against
//      every keystroke.
//   3. **The FTS5 schema, its seven columns and their order are fixed**, as is
//      `ORDER BY rowid` — see `runQuery`.
//   4. **`PSSearchQuery.cleanDisplayText` is applied BEFORE the emptiness test**
//      in the build loop, so it decides which rows exist at all.
//   5. **`dropIndex` must NOT remove the enclosing directory.** Every module's
//      index lives at `<Caches>/search/<module>.db`, so KJV and MHCC SHARE it —
//      removing it would delete the other's index, or leave an engine holding it
//      open writing to an unlinked file.
//
//  Errors are a plain Swift enum; callers catch generically, and cancellation
//  is reported by `SearchIndexCoordinator`. Queries return the full
//  `text_plain` and the UI highlights (see `runQuery`).
//

import Foundation
import SQLite3

/// Reported every few hundred rows during a build, on the **calling** thread.
/// Set `cancel = true` to abort cleanly; the partial DB is then dropped.
typealias PSSearchProgressBlock = (_ fraction: Float, _ cancel: inout Bool) -> Void

enum PSSearchEngineError: LocalizedError {
    case cannotOpenDatabase(String)
    case sqlite(String)
    case noContentStore
    case noRowsForModule(String)
    case contentStoreReadFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let detail): return "cannot open the search index: \(detail)"
        case .sqlite(let detail):             return detail
        case .noContentStore:                 return "no content store"
        case .noRowsForModule(let module):    return "content store has no rows for \(module)"
        case .contentStoreReadFailed:         return "content store read failed mid-build"
        case .cancelled:                      return "Index build cancelled"
        }
    }
}

final class PSSearchEngine {

    /// Bumped when the on-disk schema or index location changes incompatibly. An
    /// index with a different version is stale and rebuilt via the existing
    /// "build a search index?" prompt — there are no migrations.
    static let schemaVersion = 5

    private let moduleName: String
    private let dbDirectory: String
    private let dbFilePath: String
    private var db: OpaquePointer?

    /// SQLITE_TRANSIENT. See point 1 in the file header.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Instance cache

    /// Keyed by module NAME. Entries are never evicted.
    private static let cacheLock = NSLock()
    private static var cache: [String: PSSearchEngine] = [:]

    /// The cached (shared) engine for the named module — a factory, not an
    /// initialiser, because it does not create a new instance.
    static func engine(forModuleName name: String) -> PSSearchEngine {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let existing = cache[name] { return existing }
        let engine = PSSearchEngine(moduleName: name)
        cache[name] = engine
        return engine
    }

    // There is deliberately no `invalidate(forModuleName:)`: nothing needs it.
    // `dropIndex()` closes the handle before unlinking the file, and a cached
    // engine whose file is gone reopens on demand (`indexIsFresh` is false while
    // it is missing), so the cache never hands back a handle to a deleted index.
    //
    // If a future caller does need to evict: close the handle FIRST, then remove
    // the entry, or the handle leaks with the last reference.

    // MARK: - Init / paths

    /// A module NAME is all the engine needs: the path is
    /// `<Caches>/search/<name>.db` and the version comes from `content_meta`.
    private init(moduleName: String) {
        self.moduleName = moduleName
        self.dbDirectory = AppPaths.searchIndexDirectory
        self.dbFilePath = AppPaths.searchIndexPath(for: moduleName)
    }

    deinit {
        closeDB()
    }

    /// Absolute path to the FTS5 database file for this module
    /// (`<Caches>/search/<module>.db`).
    var dbPath: String { dbFilePath }

    // MARK: - Database open / close

    private func ensureDirectoryExists() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dbDirectory, isDirectory: &isDir), isDir.boolValue { return }
        try fm.createDirectory(atPath: dbDirectory, withIntermediateDirectories: true)
    }

    private func openDB(creatingIfNeeded create: Bool) throws {
        if db != nil { return }

        if create { try ensureDirectoryExists() }

        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if create { flags |= SQLITE_OPEN_CREATE }

        var handle: OpaquePointer?
        let rc = dbFilePath.withCString { sqlite3_open_v2($0, &handle, flags, nil) }
        guard rc == SQLITE_OK else {
            let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
                ?? "sqlite3_open_v2 failed (\(rc))"
            if let handle { sqlite3_close(handle) }
            throw PSSearchEngineError.cannotOpenDatabase(msg)
        }
        db = handle
        // Busy timeout so concurrent readers don't immediately SQLITE_BUSY.
        sqlite3_busy_timeout(handle, 2000)
    }

    private func closeDB() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func lastError() -> String {
        guard let db, let msg = sqlite3_errmsg(db) else { return "?" }
        return String(cString: msg)
    }

    private func execSQL(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sql.withCString { sqlite3_exec(db, $0, nil, nil, &errmsg) }
        guard rc == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? "sqlite3_exec failed (\(rc))"
            if let errmsg { sqlite3_free(errmsg) }
            throw PSSearchEngineError.sqlite(msg)
        }
    }

    /// Best-effort variant for the rollback / teardown paths, which must not mask
    /// the error that got them there.
    private func execSQLIgnoringErrors(_ sql: String) {
        try? execSQL(sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var st: OpaquePointer?
        let rc = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &st, nil) }
        guard rc == SQLITE_OK, let st else {
            throw PSSearchEngineError.sqlite(lastError())
        }
        return st
    }

    private func bind(_ st: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(st, index, value, -1, Self.transient)
    }

    private static func text(_ st: OpaquePointer, _ column: Int32) -> String? {
        guard let c = sqlite3_column_text(st, column) else { return nil }
        return String(cString: c)
    }

    private func createSchemaIfNeeded() throws {
        try execSQL("""
            CREATE TABLE IF NOT EXISTS meta (\
              module_name    TEXT PRIMARY KEY,\
              module_version TEXT,\
              built_at       INTEGER,\
              schema_version INTEGER\
            );
            """)

        // FTS5 virtual table. `reference`, `book_num`, `testament` are UNINDEXED
        // (they're scope/display metadata, not searched as text). `text_plain`
        // is indexed so snippet() can highlight against readable text;
        // `text_norm` holds diacritic-folded text for recall; `lemmas` holds
        // Strong's numbers in both H0xxx and Hxxx forms, space-separated.
        // `word_map` is UNINDEXED per-verse metadata: one line per scripture
        // word, surface form TAB lemma1 lemma2 ..., used at query time to
        // recover which English word(s) a Strong's match lit up.
        try execSQL("""
            CREATE VIRTUAL TABLE IF NOT EXISTS verses USING fts5(\
              reference UNINDEXED,\
              book_osis UNINDEXED,\
              testament UNINDEXED,\
              text_plain,\
              text_norm,\
              lemmas,\
              word_map UNINDEXED,\
              tokenize='unicode61 remove_diacritics 2'\
            );
            """)
    }

    // MARK: - Freshness

    /// True iff the DB file exists and its meta row matches the module's current
    /// `Version` (read from `content_meta`) and our schema version. A false return
    /// means either absent or stale — either way, the caller should offer to
    /// rebuild.
    func indexIsFresh() -> Bool {
        guard FileManager.default.fileExists(atPath: dbFilePath) else { return false }

        do {
            try openDB(creatingIfNeeded: false)
        } catch {
            dlog("PSSearchEngine: cannot open \(dbFilePath): \(error.localizedDescription)")
            return false
        }

        let st: OpaquePointer
        do {
            st = try prepare("SELECT module_version, schema_version FROM meta WHERE module_name = ? LIMIT 1;")
        } catch {
            dlog("PSSearchEngine: prepare meta failed: \(lastError())")
            return false
        }
        defer { sqlite3_finalize(st) }

        // The module's `Version=` conf value, from `content_meta`.
        let currentVersion = PSContentStore.shared?.moduleVersion(moduleName)
        bind(st, 1, moduleName)

        guard sqlite3_step(st) == SQLITE_ROW else { return false }
        let storedVersion = Self.text(st, 0)
        let storedSchema = Int(sqlite3_column_int(st, 1))
        return storedSchema == Self.schemaVersion && storedVersion == currentVersion
    }

    // MARK: - Build

    /// Builds the index from scratch. Blocks the calling thread; expected to run on
    /// a background queue. On cancel or error the partial DB is dropped.
    ///
    /// Returning normally MEANS every row is in and committed. Both drivers
    /// (`SearchIndexCoordinator`, `SearchIndexBackgroundManager`) take a return as
    /// success whatever their own cancel flag says by then, because a cancel is
    /// seen only at the 500-row progress poll: one raised after the last poll
    /// stops nothing. A cancel that IS seen must keep throwing `.cancelled`.
    ///
    /// It does NOT mean the index is stamped. The meta row is written after the
    /// COMMIT, outside the `catch` that drops a partial index, and `stampMeta`
    /// swallows its own failure: a statement that will not prepare returns
    /// early, and the step's result is not read. The build then returns over a
    /// committed index with no meta row, which `indexIsFresh()` rejects, and both
    /// drivers have counted it a success. The foreground one goes to `.ready`,
    /// where `runQuery` answers every query with nothing until the next
    /// activation turns that back into the build prompt
    /// (`SearchModel.indexMayHaveChanged`). The background one clears its
    /// recovery record, so nothing retries, and Search offers the build at its
    /// next look. Either way the rows are never used: the next build opens with
    /// `dropIndex()`. It takes a one-row write failing straight after the COMMIT
    /// of the whole index succeeded on the same connection — an I/O error, or
    /// the disk filling in that instant.
    func build(progress: PSSearchProgressBlock?) throws {
        // Start fresh: if there's any prior DB, drop it. A half-built index is worse
        // than none.
        dropIndex()

        try openDB(creatingIfNeeded: true)
        try createSchemaIfNeeded()

        // The baked store is the only source. Its output is pinned row-for-row by
        // `Tests/Fixtures/search-index-KJV.digest` via `PSSearchIndexParityTests`.
        // A cancellation simply propagates, like any other failure.
        do {
            try buildFromContentStore(progress: progress)
        } catch {
            // dropIndex so a partial index is never left behind to be treated as fresh.
            dropIndex()
            throw error
        }

        stampMeta()
        if let progress {
            var ignored = false
            progress(1.0, &ignored)
        }
    }

    /// Build the index from the baked content store.
    ///
    /// The emptiness test runs AFTER cleaning, because it decides which rows exist
    /// at all. The row cursor is used (rather than a direct join against
    /// `plain_texts`) because that table is chunk-compressed and framing is the
    /// store's business.
    ///
    /// `PSSearchQuery.cleanDisplayText` stays in the path even though the store's
    /// `text_plain` has no `<H…>` markers (a no-op on this input): it keeps the
    /// digest-pinned output independent of that fact, for one regex pass per row.
    private func buildFromContentStore(progress: PSSearchProgressBlock?) throws {
        guard let store = PSContentStore.shared else {
            throw PSSearchEngineError.noContentStore
        }

        let cursor = store.verseCursor(module: moduleName)
        // The real row count, known up front, so the progress fraction is exact.
        let total = cursor.count
        guard total > 0 else {
            throw PSSearchEngineError.noRowsForModule(moduleName)
        }

        try execSQL("BEGIN IMMEDIATE;")

        let insertSQL = "INSERT INTO verses (reference, book_osis, testament, text_plain,"
            + " text_norm, lemmas, word_map) VALUES (?, ?, ?, ?, ?, ?, ?);"
        let stmt: OpaquePointer
        do {
            stmt = try prepare(insertSQL)
        } catch {
            execSQLIgnoringErrors("ROLLBACK;")
            throw error
        }

        var cancelled = false
        var failure: Error?
        var count = 0
        // Rows arrive in `ordinal` order (strictly increasing and unique across all
        // 31,102 KJV rows), so `ORDER BY rowid` in `runQuery` gives biblical order.
        while let row = cursor.next() {
            let plain = PSSearchQuery.cleanDisplayText(row.textPlain)
            if !plain.isEmpty {
                let norm = PSSearchQuery.foldForIndex(plain)
                bind(stmt, 1, row.osisRef)
                bind(stmt, 2, row.bookOsis)
                sqlite3_bind_int(stmt, 3, Int32(row.testament))
                bind(stmt, 4, plain)
                bind(stmt, 5, norm)
                bind(stmt, 6, row.lemmas)
                bind(stmt, 7, row.wordMap)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    failure = PSSearchEngineError.sqlite(lastError())
                    sqlite3_reset(stmt)
                    break
                }
                sqlite3_reset(stmt)
            }

            count += 1
            if let progress, count % 500 == 0 {
                let fraction = min(Float(0.99), Float(count) / Float(total))
                var localCancel = false
                progress(fraction, &localCancel)
                if localCancel { cancelled = true; break }
            }
        }
        sqlite3_finalize(stmt)

        // A cursor that stopped because the STORE is broken must not be mistaken for
        // one that reached the end: that would commit a silently-truncated index.
        if failure == nil, !cancelled, cursor.failed {
            failure = PSSearchEngineError.contentStoreReadFailed
        }

        if cancelled || failure != nil {
            execSQLIgnoringErrors("ROLLBACK;")
            throw failure ?? PSSearchEngineError.cancelled
        }
        try execSQL("COMMIT;")
    }

    /// The meta row. `module_version` is nil-safe because the column is TEXT.
    ///
    /// Best effort: a failure here is neither thrown nor logged. `build`'s doc
    /// comment says what an unstamped index then costs.
    private func stampMeta() {
        let currentVersion = PSContentStore.shared?.moduleVersion(moduleName)
        guard let meta = try? prepare(
            "INSERT OR REPLACE INTO meta (module_name, module_version, built_at, schema_version)"
            + " VALUES (?, ?, ?, ?);") else { return }
        defer { sqlite3_finalize(meta) }
        bind(meta, 1, moduleName)
        if let currentVersion {
            bind(meta, 2, currentVersion)
        } else {
            sqlite3_bind_null(meta, 2)
        }
        sqlite3_bind_int64(meta, 3, sqlite3_int64(Date().timeIntervalSince1970))
        sqlite3_bind_int(meta, 4, Int32(Self.schemaVersion))
        sqlite3_step(meta)
    }

    // MARK: - Drop

    /// Removes the on-disk index. Does NOT remove the enclosing directory: every
    /// module's index shares `<Caches>/search`, so dropping KJV's must not delete
    /// MHCC's.
    func dropIndex() {
        closeDB()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbFilePath) else { return }
        do {
            try fm.removeItem(atPath: dbFilePath)
        } catch {
            alog("PSSearchEngine: failed to remove \(dbFilePath): \(error)")
        }
        // The enclosing directory is deliberately LEFT IN PLACE (see `dropIndex`'s
        // doc). An empty directory in Caches costs nothing; `ensureDirectoryExists`
        // recreates it on demand.
    }

    // MARK: - Query

    /// The words of a verse tagged with any of `tokens`, from its `word_map`:
    /// one line per tagged word or run of words, `surface TAB lemma lemma …`.
    /// Each distinct surface once, in the verse's order.
    ///
    /// **The surface is returned as words, with its markup taken off.** The
    /// column carries one tag, around the divine name: Genesis 2:4 has `that
    /// the <divineName>Lord</divineName>` for H3068, where the verse reads
    /// "that the LORD God made". Handed on as stored, the surface is in no
    /// verse, tags and all, and the result row had nothing to mark. MEASURED on
    /// the KJV index (6,878 of 349,514 lines carry the tag): a search for H3068
    /// listed 5,521 verses and marked a word in one of them; H3069 in none of
    /// 295. With the tag off, every tagged surface is in its verse except 424
    /// that are words of a Psalm's title, which the row's text does not hold.
    ///
    /// Read-side only. The column is as the store ships it and as the index
    /// digest pins it.
    static func surfaceWords(inWordMap map: String,
                             taggedWith tokens: Set<String>) -> [String] {
        var words: [String] = []
        var seen = Set<String>()
        for line in map.components(separatedBy: "\n") {
            guard let tab = line.range(of: "\t") else { continue }
            let lemmaStr = String(line[tab.upperBound...])
            let surface = String(line[line.startIndex..<tab.lowerBound])
                .replacingOccurrences(of: "<[^>]*>", with: "",
                                      options: .regularExpression)
            if surface.isEmpty || lemmaStr.isEmpty { continue }
            let hit = lemmaStr.components(separatedBy: " ")
                .contains { !$0.isEmpty && tokens.contains($0) }
            if !hit { continue }
            if seen.contains(surface) { continue }
            seen.insert(surface)
            words.append(surface)
        }
        return words
    }

    /// Runs a query against an already-built index. Returns an empty array if the
    /// index isn't fresh. The FTS5 expression should be produced by `PSSearchQuery`.
    /// If `strongsTokens` is non-empty, each returned result has its
    /// `strongsHighlightWords` populated with the English surface form(s) in that
    /// verse that map to any of the given Strong's tokens.
    ///
    /// No cancel flag: callers run this off the main thread under a generation
    /// counter and discard superseded results, so cancelling could only save CPU
    /// on a query the caller has already bounded. Search asks for one row past
    /// the 1,000 it lists (`SearchModel.resultLimit`), which is how it knows the
    /// list was cut.
    func runQuery(_ fts5Expression: String,
                  scope: PSSearchRange,
                  bookName: String?,
                  limit: Int32,
                  strongsTokens: [String]?) -> [PSSearchResult] {
        if fts5Expression.isEmpty { return [] }
        if !indexIsFresh() { return [] }

        do {
            try openDB(creatingIfNeeded: false)
        } catch {
            dlog("PSSearchEngine: runQuery openDB failed: \(error.localizedDescription)")
            return []
        }

        let wantWordMap = (strongsTokens?.isEmpty == false)
        let tokenSet: Set<String> = wantWordMap ? Set(strongsTokens ?? []) : []

        // We return the FULL stored verse text (`text_plain`) and let the UI do its
        // own highlighting. FTS5's `snippet()` truncates to ~64 tokens and drops
        // highlight markers for matches that hit non-visible columns (e.g. Strong's
        // lemmas), so `snippet()` is the wrong tool for this app. For Strong's
        // searches we also pull `word_map` so the caller can learn which English
        // surface word(s) to highlight.
        var sql = wantWordMap
            ? "SELECT reference, text_plain, word_map FROM verses WHERE verses MATCH ?"
            : "SELECT reference, text_plain FROM verses WHERE verses MATCH ?"

        var testamentValue: Int32?
        if scope == .OTRange { testamentValue = 1 }
        else if scope == .NTRange { testamentValue = 2 }
        if testamentValue != nil { sql += " AND testament = ?" }

        var bookOsis: String?
        if scope == .BookRange, let bookName, !bookName.isEmpty {
            // Name -> OSIS from the baked versification table. A nil resolver or an
            // unrecognised book name leaves the scope filter off, so the search covers
            // the whole Bible rather than nothing.
            if let osis = PSBookOSISResolver.shared?.book(named: bookName)?.osisName,
               !osis.isEmpty {
                bookOsis = osis
                sql += " AND book_osis = ?"
            }
        }

        // Rows are inserted in canonical order (Genesis 1:1 upward), so rowid gives
        // biblical order directly. Deliberately not `ORDER BY ordinal`: rowid order
        // IS ordinal order, and switching would need an extra FTS column, a
        // `schemaVersion` bump and a forced rebuild for every user, for nothing.
        sql += " ORDER BY rowid"
        if limit > 0 { sql += " LIMIT \(limit)" }

        let st: OpaquePointer
        do {
            st = try prepare(sql)
        } catch {
            dlog("PSSearchEngine: prepare query failed: \(lastError()) (sql=\(sql))")
            return []
        }
        defer { sqlite3_finalize(st) }

        var p: Int32 = 1
        bind(st, p, fts5Expression); p += 1
        if let testamentValue { sqlite3_bind_int(st, p, testamentValue); p += 1 }
        if let bookOsis { bind(st, p, bookOsis); p += 1 }

        var results: [PSSearchResult] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW {
                let ref = Self.text(st, 0) ?? ""
                let result = PSSearchResult(reference: ref, fullText: Self.text(st, 1))

                if wantWordMap, let map = Self.text(st, 2), !map.isEmpty {
                    let words = Self.surfaceWords(inWordMap: map, taggedWith: tokenSet)
                    if !words.isEmpty { result.strongsHighlightWords = words }
                }

                results.append(result)
            } else if rc == SQLITE_DONE {
                break
            } else {
                dlog("PSSearchEngine: step returned \(rc): \(lastError())")
                break
            }
        }
        return results
    }
}
