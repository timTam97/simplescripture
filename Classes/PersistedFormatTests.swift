//
//  PersistedFormatTests.swift
//  SimpleScriptureTests
//
//  LOCKS the load-bearing persisted formats, including every pre-existing
//  read/write asymmetry. They do NOT "correct" any quirk: a change to a positional
//  index, a hardcoded literal, or the per-module pref-key format must make one of
//  these tests go red, because it would corrupt user data.
//

import XCTest
@testable import SimpleScripture

final class PersistedFormatTests: XCTestCase {

    // MARK: - PSHistoryItem
    //
    // `array` writes EXACTLY [bibleReference, "0" (scroll hardcoded), moduleName,
    //  dateAdded]. The scroll slot is ALWAYS the literal string "0" — the live
    //  scrollAmount property is intentionally NOT written.

    func testHistoryItem_arrayWritesScrollAsHardcodedZero() {
        let date = Date(timeIntervalSince1970: 1234567890)
        let item = PSHistoryItem(reference: "John 3:16",
                                 scrollAmount: "999",   // deliberately non-zero
                                 moduleName: "KJV",
                                 dateAdded: date)
        let arr = (item?.array() ?? []) as NSArray

        XCTAssertEqual(arr.count, 4, "history array must be exactly 4 elements")
        XCTAssertEqual(arr[0] as? String, "John 3:16", "idx0 = bibleReference")
        XCTAssertEqual(arr[1] as? String, "0",
                       "idx1 = scroll is the HARDCODED string \"0\", never the live scrollAmount")
        XCTAssertEqual(arr[2] as? String, "KJV", "idx2 = moduleName")
        XCTAssertEqual(arr[3] as? Date, date, "idx3 = dateAdded (NSDate)")
    }

    // -initWithArray: full 4-element round trip.
    func testHistoryItem_initWithArray_fullFourElements() {
        let date = Date(timeIntervalSince1970: 42)
        let input: [Any] = ["Gen 1:1", "0", "ESV", date]
        let item = PSHistoryItem(array: input)

        XCTAssertEqual(item?.bibleReference, "Gen 1:1")
        XCTAssertEqual(item?.scrollAmount, "0")
        XCTAssertEqual(item?.moduleName, "ESV")
        XCTAssertEqual(item?.dateAdded, date)
    }

    // -initWithArray: tolerates a 3-element array (count < 4): date <- distantPast.
    func testHistoryItem_initWithArray_threeElementsFallsBackToDistantPast() {
        let input: [Any] = ["Gen 1:1", "0", "ESV"]
        let item = PSHistoryItem(array: input)

        XCTAssertEqual(item?.bibleReference, "Gen 1:1")
        XCTAssertEqual(item?.moduleName, "ESV")
        XCTAssertEqual(item?.dateAdded, Date.distantPast,
                       "count < 4 -> dateAdded falls back to NSDate.distantPast")
    }

    // -initWithArray: tolerates a 2-element array (count < 3): module <- DefaultsLastBible.
    func testHistoryItem_initWithArray_twoElementsFallsBackToLastBiblePref() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Defaults.lastBible)
        defaults.set("MyLastBible", forKey: Defaults.lastBible)
        defer {
            if let saved = saved { defaults.set(saved, forKey: Defaults.lastBible) }
            else { defaults.removeObject(forKey: Defaults.lastBible) }
        }

        let input: [Any] = ["Gen 1:1", "0"]
        let item = PSHistoryItem(array: input)

        XCTAssertEqual(item?.bibleReference, "Gen 1:1")
        XCTAssertEqual(item?.moduleName, "MyLastBible",
                       "count < 3 -> moduleName falls back to the DefaultsLastBible pref")
        XCTAssertEqual(item?.dateAdded, Date.distantPast,
                       "count < 4 also -> distantPast")
    }

    // MARK: - PSBookmark / PSBookmarkFolder positional plist schema
    //
    // WRITE (parseBookmarkObject):
    //   folder   => [name, dateAdded, dateLastAccessed, "YES" (literal STRING),
    //                rgbHex-or-"", childrenArray]              (6 elements)
    //   bookmark => [name, dateAdded, dateLastAccessed, "NO", ref] (5 elements)
    // READ (parseArray):
    //   idx3 via boolValue selects folder vs bookmark;
    //   folder reads rgb@4 ("" normalized to nil) + children@5;
    //   bookmark reads ref@4.

    func testBookmark_writeProducesFiveElementBookmarkSchema() throws {
        let da = Date(timeIntervalSince1970: 100)
        let dla = Date(timeIntervalSince1970: 200)
        let bm = PSBookmark(name: "Verse",
                            dateAdded: da,
                            dateLastAccessed: dla,
                            bibleReference: "Rom 8:28")
        let arr = try XCTUnwrap(PSBookmarks.parseBookmarkObject(bm))

        XCTAssertEqual(arr.count, 5, "bookmark schema = exactly 5 elements")
        XCTAssertEqual(arr[0] as? String, "Verse",   "idx0 = name")
        XCTAssertEqual(arr[1] as? Date, da,           "idx1 = dateAdded")
        XCTAssertEqual(arr[2] as? Date, dla,          "idx2 = dateLastAccessed")
        XCTAssertEqual(arr[3] as? String, "NO",
                       "idx3 = literal STRING \"NO\" (NOT a boolean) for a bookmark")
        XCTAssertEqual(arr[4] as? String, "Rom 8:28", "idx4 = ref for a bookmark")
    }

    func testBookmarkFolder_writeProducesSixElementFolderSchemaWithRGB() throws {
        let da = Date(timeIntervalSince1970: 300)
        let dla = Date(timeIntervalSince1970: 400)
        let folder = PSBookmarkFolder(name: "Fav",
                                      dateAdded: da,
                                      dateLastAccessed: dla,
                                      rgbHexString: "ff0000",
                                      children: [])
        let arr = try XCTUnwrap(PSBookmarks.parseBookmarkObject(folder))

        XCTAssertEqual(arr.count, 6, "folder schema = exactly 6 elements")
        XCTAssertEqual(arr[0] as? String, "Fav",  "idx0 = name")
        XCTAssertEqual(arr[1] as? Date, da,        "idx1 = dateAdded")
        XCTAssertEqual(arr[2] as? Date, dla,       "idx2 = dateLastAccessed")
        XCTAssertEqual(arr[3] as? String, "YES",
                       "idx3 = literal STRING \"YES\" (NOT a boolean) for a folder")
        XCTAssertEqual(arr[4] as? String, "ff0000", "idx4 = rgb hex string")
        XCTAssertTrue(arr[5] is NSArray,            "idx5 = children array")
        XCTAssertEqual((arr[5] as? NSArray)?.count, 0)
    }

    // A folder with no rgb writes "" at idx4 (never nil — nil would break the plist).
    func testBookmarkFolder_writeNilRGBProducesEmptyStringAtIndexFour() throws {
        let folder = PSBookmarkFolder(name: "NoColour",
                                      dateAdded: Date(timeIntervalSince1970: 1),
                                      dateLastAccessed: Date(timeIntervalSince1970: 2),
                                      rgbHexString: nil,
                                      children: [])
        let arr = try XCTUnwrap(PSBookmarks.parseBookmarkObject(folder))
        XCTAssertEqual(arr.count, 6)
        XCTAssertEqual(arr[4] as? String, "",
                       "nil rgb is written as the EMPTY STRING, not nil")
    }

    // READ round-trip: a written bookmark parses back to an equal bookmark.
    func testBookmark_writeReadRoundTrip() throws {
        let da = Date(timeIntervalSince1970: 500)
        let dla = Date(timeIntervalSince1970: 600)
        let bm = PSBookmark(name: "X",
                            dateAdded: da,
                            dateLastAccessed: dla,
                            bibleReference: "Ps 23:1")
        let arr = try XCTUnwrap(PSBookmarks.parseBookmarkObject(bm))

        let store = try XCTUnwrap(PSBookmarks.default())
        let parsedBM = try XCTUnwrap(store.parseArray(arr as? [Any]) as? PSBookmark)

        XCTAssertFalse(parsedBM.folder)
        XCTAssertEqual(parsedBM.name, "X")
        XCTAssertEqual(parsedBM.dateAdded, da)
        XCTAssertEqual(parsedBM.dateLastAccessed, dla)
        XCTAssertEqual(parsedBM.ref, "Ps 23:1")
    }

    // READ: empty-string rgb at idx4 is normalized to nil on read; children at idx5.
    func testBookmarkFolder_readEmptyRGBNormalizedToNil() throws {
        let da = Date(timeIntervalSince1970: 700)
        let dla = Date(timeIntervalSince1970: 800)
        // Hand-build the exact 6-element folder array with "" rgb and one child.
        let childArr = try XCTUnwrap(PSBookmarks.parseBookmarkObject(
            PSBookmark(name: "kid",
                       dateAdded: da,
                       dateLastAccessed: dla,
                       bibleReference: "Acts 2:1")))
        let folderArr: [Any] = ["Top", da, dla, "YES", "", [childArr]]

        let store = try XCTUnwrap(PSBookmarks.default())
        let parsedFolder = try XCTUnwrap(store.parseArray(folderArr) as? PSBookmarkFolder)

        XCTAssertTrue(parsedFolder.folder)
        XCTAssertEqual(parsedFolder.name, "Top")
        XCTAssertNil(parsedFolder.rgbHexString,
                     "empty-string rgb at idx4 must be normalized to nil on read")
        let children = try XCTUnwrap(parsedFolder.children)
        XCTAssertEqual(children.count, 1, "children read from idx5")
        XCTAssertEqual((children.first as? PSBookmark)?.ref, "Acts 2:1")
    }

    // MARK: - PSSearchHistoryItem
    //
    // `searchHistoryItemArray` WRITES 6 elements in order:
    //   [searchTermToDisplay, strongs("Y"/"N"), fuzzy("Y"/"N"),
    //    searchType(%d), searchRange(%d), bookName]
    // `init(array:)` has a READ SKEW, locked verbatim:
    //   strongs <- idx1, fuzzy <- idx1 (BOTH from index 1, NOT index 2),
    //   searchType <- idx2 (not idx3), searchRange <- idx3 (not idx4),
    //   bookName <- idx4 (not idx5).

    func testSearchHistoryItem_writeOrderingAndFlagLiterals() throws {
        let item = try XCTUnwrap(PSSearchHistoryItem(searchTermToDisplay: "grace",
                                                     strongs: true,
                                                     fuzzy: false,
                                                     type: .OrSearch,
                                                     range: .BookRange,
                                                     book: "Romans"))
        let arr = item.searchHistoryItemArray() as NSArray

        XCTAssertEqual(arr.count, 6, "search-history array = exactly 6 elements")
        XCTAssertEqual(arr[0] as? String, "grace", "idx0 = searchTermToDisplay")
        XCTAssertEqual(arr[1] as? String, "Y",     "idx1 = strongs as \"Y\"/\"N\"")
        XCTAssertEqual(arr[2] as? String, "N",     "idx2 = fuzzy as \"Y\"/\"N\"")
        XCTAssertEqual(arr[3] as? String, "\(PSSearchType.OrSearch.rawValue)",
                       "idx3 = searchType formatted with %d (OrSearch == 1)")
        XCTAssertEqual(arr[4] as? String, "\(PSSearchRange.BookRange.rawValue)",
                       "idx4 = searchRange formatted with %d (BookRange == 3)")
        XCTAssertEqual(arr[5] as? String, "Romans", "idx5 = bookName")
    }

    // Lock the asymmetric read: fuzzy is read from idx1 (same as strongs), so a
    // round-trip through write->read makes fuzzy MIRROR strongs, regardless of the
    // value originally written at idx2. Buggy but shipped; MUST be preserved.
    func testSearchHistoryItem_readSkew_fuzzyMirrorsStrongsFromIndexOne() throws {
        // Write with strongs=YES, fuzzy=NO -> array idx1="Y", idx2="N".
        let writer = try XCTUnwrap(PSSearchHistoryItem(searchTermToDisplay: "faith",
                                                       strongs: true,
                                                       fuzzy: false,
                                                       type: .AndSearch,
                                                       range: .AllRange,
                                                       book: "ignored"))
        let written = writer.searchHistoryItemArray()

        let read = PSSearchHistoryItem(array: written)

        XCTAssertEqual(read?.strongsSearch, true, "strongs read from idx1")
        XCTAssertEqual(read?.fuzzySearch, true,
                       "READ SKEW: fuzzy is also read from idx1, so it MIRRORS strongs "
                       + "rather than reading the \"N\" written at idx2")
    }

    // Lock the type/range index skew: type read from idx2, range from idx3.
    func testSearchHistoryItem_readSkew_typeAndRangeIndices() {
        // Hand-build an array whose idx2/idx3/idx4 differ so the skew is observable.
        // Written layout would be [term, strongsYN, fuzzyYN, typeD, rangeD, book];
        // here we craft idx values to prove the READ indices:
        //   strongs<-idx1, fuzzy<-idx1, type<-idx2, range<-idx3, book<-idx4
        let arr: [Any] = ["term", "N",
                          "\(PSSearchType.OrSearch.rawValue)",   // idx2 -> read as searchType
                          "\(PSSearchRange.BookRange.rawValue)", // idx3 -> read as searchRange
                          "BookFromIdx4",                        // idx4 -> read as bookName
                          "Unused5"]                             // idx5 NOT read
        let read = PSSearchHistoryItem(array: arr)

        XCTAssertEqual(read?.strongsSearch, false, "strongs <- idx1 (\"N\")")
        XCTAssertEqual(read?.fuzzySearch, false,   "fuzzy  <- idx1 (\"N\")")
        XCTAssertEqual(read?.searchType, .OrSearch,  "searchType <- idx2")
        XCTAssertEqual(read?.searchRange, .BookRange, "searchRange <- idx3")
        XCTAssertEqual(read?.bookName, "BookFromIdx4", "bookName <- idx4")
    }

    // MARK: - "%@_%@" per-module pref key
    //
    // UserDefaults.psModuleKey(pref, mod) == String(format: "%@_%@", pref, mod),
    // byte-for-byte.

    func testModuleKey_matchesObjCStringWithFormatByteForByte() {
        let pref = "fontSizePreference"
        let mod = "KJV"
        let swift = UserDefaults.standard.psModuleKey(pref, mod)
        let objc = NSString(format: "%@_%@", pref, mod) as String
        XCTAssertEqual(swift, objc)
        XCTAssertEqual(swift, "fontSizePreference_KJV", "literal expectation")
    }

    func testModuleKey_underscoresInOperandsArePreservedNotEscaped() {
        // Defensive: prove the single-underscore join even when operands themselves
        // contain underscores (no collapsing / escaping).
        let swift = UserDefaults.standard.psModuleKey("a_b", "c_d")
        let objc = NSString(format: "%@_%@", "a_b", "c_d") as String
        XCTAssertEqual(swift, objc)
        XCTAssertEqual(swift, "a_b_c_d")
    }

    // MARK: - HistoryStore iCloud merge / cap / dedup
    //
    // Locks the cloud<->local recursive merge, the 100-entry cap
    // (PSHistoryMaxEntries == 100, applied with a `while count >= 100` trim), and
    // the dedup-on-equal-ref+mod walk. PSHistoryName is the wire key
    // "bibleHistory" in BOTH UserDefaults and NSUbiquitousKeyValueStore.

    private func makeHistoryItem(_ ref: String, _ mod: String, secondsSinceEpoch: TimeInterval) -> PSHistoryItem {
        return PSHistoryItem(reference: ref,
                             scrollAmount: "0",
                             moduleName: mod,
                             dateAdded: Date(timeIntervalSince1970: secondsSinceEpoch))!
    }

    // The recursive merge interleaves two date-descending lists newest-first,
    // and RETURNS NIL the moment either list empties — so the trailing element
    // of the not-yet-empty list is DROPPED. Both the newest-first interleave AND
    // that lossy drop are locked here; do NOT "fix" them.
    func testHistoryMerge_recursiveInterleavesNewestFirstAndDropsTrailingElement() throws {
        // first (cloud) newest @300, then @100 ; second (local) @200, then @50.
        let cloud = NSMutableArray(array: [
            makeHistoryItem("Gen 1:1", "KJV", secondsSinceEpoch: 300),
            makeHistoryItem("Exo 2:2", "KJV", secondsSinceEpoch: 100),
        ])
        let local = NSMutableArray(array: [
            makeHistoryItem("Lev 3:3", "KJV", secondsSinceEpoch: 200),
            makeHistoryItem("Num 4:4", "KJV", secondsSinceEpoch: 50),
        ])

        let merged = try XCTUnwrap(
            HistoryStore.synchronizeHistoryArray(cloud, with: local)
        )
        let refs = merged.compactMap { ($0 as? PSHistoryItem)?.bibleReference }
        XCTAssertEqual(refs, ["Gen 1:1", "Lev 3:3", "Exo 2:2"],
                       "interleave is newest-first; the oldest tail (Num 4:4 @50) is DROPPED "
                       + "by the nil-on-empty recursion guard (preserved quirk)")
    }

    // Equal newest items short-circuit: the merge returns the SHORTER of the two
    // input lists unchanged (per the isEqualToHistoryItem: early return).
    func testHistoryMerge_equalNewestReturnsShorterListUnchanged() throws {
        let shared = makeHistoryItem("Ps 23:1", "KJV", secondsSinceEpoch: 900)
        let cloud = NSMutableArray(array: [shared])
        let local = NSMutableArray(array: [
            shared,
            makeHistoryItem("Ps 24:1", "KJV", secondsSinceEpoch: 800),
        ])
        let merged = try XCTUnwrap(
            HistoryStore.synchronizeHistoryArray(cloud, with: local)
        )
        let refs = merged.compactMap { ($0 as? PSHistoryItem)?.bibleReference }
        XCTAssertEqual(refs, ["Ps 23:1"],
                       "equal newest -> return the shorter list (cloud) unchanged")
    }

    // initialSynchronize writes the combined, deduped, capped history to
    // UserDefaults under "bibleHistory" as an array-of-[ref,scroll,mod,date]
    // arrays. Lock the schema + dedup-on-equal-ref+mod.
    func testHistoryInitialSynchronize_writesArraySchemaAndDedups() throws {
        let defaults = UserDefaults.standard
        let key = AppConstants.historyName
        XCTAssertEqual(key, "bibleHistory", "PSHistoryName wire string is load-bearing")
        let saved = defaults.array(forKey: key)
        defer {
            if let saved = saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        // cloud has John 3:16/KJV ; local has the SAME ref+mod (a dup) plus Acts 1:1/KJV.
        let dupDate = Date(timeIntervalSince1970: 500)
        let cloud: [Any] = [ makeHistoryItem("John 3:16", "KJV", secondsSinceEpoch: 500) ]
        let local: [Any] = [
            makeHistoryItem("Acts 1:1", "KJV", secondsSinceEpoch: 400),
            makeHistoryItem("John 3:16", "KJV", secondsSinceEpoch: 500),
        ]

        HistoryStore().initialSynchronize(
            withCloud: cloud,
            withLocalHistory: local
        )

        let written = try XCTUnwrap(defaults.array(forKey: key))
        // dedup removes the duplicate John 3:16/KJV -> 2 unique entries.
        XCTAssertEqual(written.count, 2, "equal ref+mod entries are deduped on merge")

        // each entry is the [ref, "0", mod, date] array (schema byte-lock).
        let first = try XCTUnwrap(written[0] as? [Any])
        XCTAssertEqual(first.count, 4, "history entry = exactly [ref, scroll, mod, date]")
        XCTAssertEqual(first[0] as? String, "John 3:16", "idx0 = ref (newest first)")
        XCTAssertEqual(first[1] as? String, "0",          "idx1 = scroll hardcoded \"0\"")
        XCTAssertEqual(first[2] as? String, "KJV",        "idx2 = mod")
        XCTAssertEqual(first[3] as? Date, dupDate,        "idx3 = NSDate")
        XCTAssertEqual((written[1] as? [Any])?[0] as? String, "Acts 1:1", "older entry follows")
    }

    // The 100-entry cap is applied as `while count >= PSHistoryMaxEntries { removeLast }`,
    // so a merge producing >= 100 unique entries is trimmed to 99.
    func testHistoryInitialSynchronize_capsAtNinetyNineWithGreaterOrEqualTrim() throws {
        let defaults = UserDefaults.standard
        let key = AppConstants.historyName
        let saved = defaults.array(forKey: key)
        defer {
            if let saved = saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        XCTAssertEqual(AppConstants.historyMaxEntries, 100, "PSHistoryMaxEntries is 100")

        // 120 unique entries (distinct refs), all in local, cloud empty.
        var local: [Any] = []
        for i in 0..<120 {
            local.append(makeHistoryItem("Ref \(i):1", "KJV", secondsSinceEpoch: TimeInterval(10_000 - i)))
        }
        HistoryStore().initialSynchronize(
            withCloud: [],
            withLocalHistory: local
        )

        let written = try XCTUnwrap(defaults.array(forKey: key))
        XCTAssertEqual(written.count, 99,
                       "`while count >= 100 { removeLast }` trims to 99, not 100")
    }
}
