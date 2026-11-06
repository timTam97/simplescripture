import XCTest
import Observation
import UIKit
import os
@testable import SimpleScripture

/// Collects the FTS5 expressions a `SearchModel` actually queried with.
///
/// `SearchModel.runSearch` dispatches to a global queue, so a test cannot read a
/// plain captured array immediately after calling in — that races, and reads 1
/// where it wants 2. This holds them behind a lock and lets the test await a
/// count.
private final class ExpressionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var expressions: [String] = []

    func record(_ expression: String) {
        lock.lock()
        expressions.append(expression)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return expressions
    }

    func wait(forCount count: Int, in testCase: XCTestCase) async {
        let reached = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.snapshot().count ?? 0) >= count
            },
            object: nil
        )
        await testCase.fulfillment(of: [reached], timeout: 5)
    }
}

private final class HistoryCloudStoreStub: HistoryCloudStoring {
    private(set) var values: [String: Any] = [:]

    func array(forKey defaultName: String) -> [Any]? {
        values[defaultName] as? [Any]
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

final class AppStateStoresTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AppStateStoresTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    func testSettingsStoreUsesLegacyKeysAndDefaults() {
        let store = SettingsStore(defaults: defaults)

        let initial = store.snapshot()

        XCTAssertEqual(initial.fontName, AppConstants.defaultFontName)
        XCTAssertEqual(initial.fontSize, 20)
        XCTAssertFalse(initial.keepScreenAwake)
        XCTAssertEqual(initial.rotationLock, .unlocked)
        XCTAssertNil(defaults.object(forKey: Defaults.fontSizePreference))

        store.ensureFontSizeDefault()

        XCTAssertEqual(defaults.integer(forKey: Defaults.fontSizePreference), 20)
    }

    @MainActor
    func testSettingsModelPersistsMutationsAndRunsSideEffects() {
        let model = SettingsModel(store: SettingsStore(defaults: defaults))
        var appearanceChanges = 0
        var idleTimerValues: [Bool] = []
        model.onReadingAppearanceChanged = {
            appearanceChanges += 1
        }
        model.onKeepScreenAwakeChanged = {
            idleTimerValues.append($0)
        }

        model.fontName = "Gentium Plus"
        model.fontSize = 18
        model.keepScreenAwake = true
        model.rotationLock = .landscape

        XCTAssertEqual(
            defaults.string(forKey: Defaults.fontNamePreference),
            "Gentium Plus"
        )
        XCTAssertEqual(defaults.integer(forKey: Defaults.fontSizePreference), 18)
        XCTAssertTrue(defaults.bool(forKey: Defaults.insomniaPreference))
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.rotationLockPosition),
            RotationLock.landscape.rawValue
        )
        XCTAssertEqual(appearanceChanges, 2)
        XCTAssertEqual(idleTimerValues, [true])
    }

    @MainActor
    func testSettingsModelSwiftUIBindingsPreserveLegacyValues() {
        let model = SettingsModel(store: SettingsStore(defaults: defaults))

        model.fontSizeValue = 19
        model[rotationLockedFor: .landscape] = true

        XCTAssertEqual(model.fontSize, 19)
        XCTAssertEqual(model.rotationLock, .landscape)
        XCTAssertEqual(defaults.integer(forKey: Defaults.fontSizePreference), 19)
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.rotationLockPosition),
            RotationLock.landscape.rawValue
        )

        model[rotationLockedFor: .portrait] = false

        XCTAssertEqual(model.rotationLock, .unlocked)
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.rotationLockPosition),
            RotationLock.unlocked.rawValue
        )
    }

    func testRotationLockUsesInterfaceOrientationRatherThanWindowShape() {
        XCTAssertEqual(
            RotationLock(interfaceOrientation: .landscapeLeft),
            .landscape
        )
        XCTAssertEqual(
            RotationLock(interfaceOrientation: .landscapeRight),
            .landscape
        )
        XCTAssertEqual(
            RotationLock(interfaceOrientation: .portrait),
            .portrait
        )
        XCTAssertEqual(
            RotationLock(interfaceOrientation: .portraitUpsideDown),
            .portrait
        )
    }

    func testAboutFeedbackUsesTheForkIssueTracker() throws {
        let information = AboutInformation.current()
        let components = try XCTUnwrap(
            URLComponents(url: information.feedbackURL, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/timTam97/pocketsword/issues/new")
        XCTAssertTrue(
            components.queryItems?.contains {
                $0.name == "title"
                    && $0.value == "SimpleScripture feedback"
            } ?? false
        )
        XCTAssertTrue(
            components.queryItems?.contains {
                $0.name == "body"
                    && ($0.value?.contains("\(information.version) (\(information.build))") ?? false)
            } ?? false
        )
    }

    func testAboutNoticesAreBundledAndMatchTheShippedComponents() throws {
        let store = try XCTUnwrap(PSContentStore.shared)
        XCTAssertEqual(Set(AboutNotice.modules.map(\.id)), Set(BundledModules.all))
        for module in AboutNotice.modules {
            XCTAssertEqual(module.version, store.moduleVersion(module.id), module.id)
        }
        // Read the installed app bundle, so missing Copy Resources membership fails.
        for notice in AboutNotice.all {
            XCTAssertGreaterThan(try notice.text().count, 100, notice.id)
        }
        let robinson = try XCTUnwrap(AboutNotice.modules.first { $0.id == "Robinson" })
        let robinsonText = try robinson.text()
        XCTAssertTrue(robinsonText.contains("CrossWire Bible Society"))
        XCTAssertTrue(robinsonText.contains("2002"))
        XCTAssertTrue(robinsonText.contains("2009"))
        XCTAssertTrue(robinsonText.contains("https://creativecommons.org/licenses/by-sa/3.0/"))
        XCTAssertTrue(robinsonText.contains("converted"))
        let ezra = try XCTUnwrap(AboutNotice.fonts.first { $0.id == "ezra" })
        let ezraText = try ezra.text()
        XCTAssertTrue(ezraText.contains("Ralph Hancock and John Hudson"))
        XCTAssertTrue(ezraText.contains("MIT/X11 License"))
        XCTAssertTrue(ezraText.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(try AboutNotice.gpl.text().contains("NO WARRANTY"))
        XCTAssertTrue(try AboutNotice.creativeCommons.text().contains("8. Miscellaneous"))
    }

    @MainActor
    func testReferencePickerUsesStableBookIDsAndValidatedSelection() {
        let genesis = ReferencePickerBook(
            id: "Gen",
            name: "Genesis",
            shortName: "Gen",
            verseCounts: [31, 25]
        )
        let john = ReferencePickerBook(
            id: "John",
            name: "John",
            shortName: "Joh",
            verseCounts: [51, 25, 36]
        )
        let model = ReferencePickerModel(
            books: [genesis, john],
            currentReference: "John 3:16"
        )
        var selection: ReferencePickerSelection?
        model.onSelection = {
            selection = $0
        }

        XCTAssertEqual(model.currentBookID, "John")
        XCTAssertEqual(model.currentChapter, 3)
        XCTAssertEqual(
            model.indexEntries,
            [
                ReferencePickerIndexEntry(
                    shortName: "Gen",
                    bookID: "Gen"
                ),
                ReferencePickerIndexEntry(
                    shortName: "Joh",
                    bookID: "John"
                ),
            ]
        )

        model.openChapters(for: "John")
        model.openVerses(for: "John", chapter: 3)
        XCTAssertEqual(
            model.path,
            [
                .chapters(bookID: "John"),
                .verses(bookID: "John", chapter: 3),
            ]
        )

        model.select(bookID: "John", chapter: 3, verse: 16)
        XCTAssertEqual(
            selection,
            ReferencePickerSelection(
                bookName: "John",
                chapter: 3,
                verse: 16
            )
        )

        model.select(bookID: "John", chapter: 4, verse: 1)
        XCTAssertEqual(selection?.chapter, 3)
    }

    func testReadingStateStoreLoadsLegacyPositionAndModules() throws {
        defaults.set("John 3", forKey: Defaults.lastRef)
        defaults.set("KJV-Test", forKey: Defaults.lastBible)
        defaults.set("MHCC-Test", forKey: Defaults.lastCommentary)
        defaults.set("16", forKey: Defaults.bibleVersePosition)
        defaults.set("17", forKey: Defaults.commentaryVersePosition)
        let store = ReadingStateStore(defaults: defaults)

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.reference?.chapterRef, "John 3")
        XCTAssertEqual(snapshot.bibleModule, "KJV-Test")
        XCTAssertEqual(snapshot.commentaryModule, "MHCC-Test")
        XCTAssertEqual(snapshot.bibleVerse, 16)
        XCTAssertEqual(snapshot.commentaryVerse, 17)
    }

    func testReadingStateStorePersistsRouteWithoutChangingWireTypes() throws {
        let router = try XCTUnwrap(URLRouter())
        let store = ReadingStateStore(defaults: defaults)
        defaults.set("9", forKey: Defaults.commentaryVersePosition)

        let bibleRoute = try XCTUnwrap(router.route(
            for: URL(string: "sword://KJV/John+3:16")
        ))
        store.persist(bibleRoute)

        XCTAssertEqual(defaults.string(forKey: Defaults.lastRef), "John 3")
        XCTAssertEqual(
            defaults.string(forKey: Defaults.bibleVersePosition),
            "16"
        )
        XCTAssertEqual(
            defaults.string(forKey: Defaults.commentaryVersePosition),
            "9"
        )

        let commentaryRoute = try XCTUnwrap(router.route(
            for: URL(string: "sword://MHCC/Psalms+23:4")
        ))
        store.persist(commentaryRoute)

        XCTAssertEqual(defaults.string(forKey: Defaults.lastRef), "Psalms 23")
        XCTAssertEqual(
            defaults.string(forKey: Defaults.bibleVersePosition),
            "4"
        )
        XCTAssertEqual(
            defaults.string(forKey: Defaults.commentaryVersePosition),
            "4"
        )
    }

    func testBookmarkRuntimeIdentityIsExcludedFromPersistedSchema() throws {
        let bookmark = PSBookmark(
            name: "Hope",
            dateAdded: Date(timeIntervalSince1970: 10),
            dateLastAccessed: Date(timeIntervalSince1970: 20),
            bibleReference: "Romans 5:5"
        )

        let persisted = try XCTUnwrap(PSBookmarks.parseBookmarkObject(bookmark))
        let decoded = try XCTUnwrap(
            PSBookmarks.default().parseArray(persisted as? [Any]) as? PSBookmark
        )

        XCTAssertEqual(persisted.count, 5)
        XCTAssertNotEqual(decoded.id, bookmark.id)
        XCTAssertEqual(decoded.ref, bookmark.ref)
    }

    func testBookmarkStoreBuildsStableTypedTreeAndColor() throws {
        let bookmark = PSBookmark(
            name: "Hope",
            dateAdded: nil,
            dateLastAccessed: nil,
            bibleReference: "Romans 5:5"
        )
        let folder = PSBookmarkFolder(
            name: "Study",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: "#12ABEF",
            children: [bookmark]
        )
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [folder]
        )
        let store = BookmarkStore(rootProvider: { root })

        let first = try XCTUnwrap(store.snapshot().first)
        let second = try XCTUnwrap(store.snapshot().first)

        XCTAssertEqual(first.id, folder.id)
        XCTAssertEqual(second.id, first.id)
        guard case .folder(let color, let children) = first.kind else {
            return XCTFail("Expected a folder snapshot")
        }
        XCTAssertEqual(color?.hexString, "#12ABEF")
        XCTAssertEqual(children.first?.id, bookmark.id)
        XCTAssertEqual(
            children.first?.kind,
            .bookmark(reference: "Romans 5:5")
        )
    }

    /// `updateFolder` throws having changed NOTHING when the id is not a folder.
    ///
    /// Validating after `renameObject` would leave the live `PSBookmarks` tree
    /// carrying the new name with no `commit()` behind it, for the next unrelated
    /// `commit()` to persist. Mutation-checked: moving the guard below
    /// `renameObject` turns this red on the name assertion.
    func testUpdateFolderOnANonFolderChangesNothing() throws {
        let bookmark = PSBookmark(
            name: "First",
            dateAdded: Date(timeIntervalSince1970: 10),
            dateLastAccessed: Date(timeIntervalSince1970: 20),
            bibleReference: "John 1:1"
        )
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [bookmark]
        )
        var saveCount = 0
        let store = BookmarkStore(
            rootProvider: { root },
            save: {
                saveCount += 1
                return true
            },
            notificationCenter: NotificationCenter()
        )

        let accessedBefore = bookmark.dateLastAccessed

        // A bookmark id, not a folder id.
        XCTAssertThrowsError(
            try store.updateFolder(
                id: bookmark.id,
                name: "Renamed",
                color: BookmarkColor(hexString: "#12ABEF")
            )
        ) { error in
            XCTAssertEqual(error as? BookmarkMutationError, .missingNode)
        }

        XCTAssertEqual(
            bookmark.name, "First",
            "the rename must not have been applied to the live tree"
        )
        XCTAssertEqual(
            bookmark.dateLastAccessed, accessedBefore,
            "dateLastAccessed must not have been bumped either"
        )
        XCTAssertEqual(saveCount, 0, "nothing may be committed on the throwing path")
    }

    func testBookmarkStoreMutatesNestedTreeAndPreservesObjectIdentity() throws {
        let first = PSBookmark(
            name: "First",
            dateAdded: Date(timeIntervalSince1970: 10),
            dateLastAccessed: Date(timeIntervalSince1970: 20),
            bibleReference: "John 1:1"
        )
        let second = PSBookmark(
            name: "Second",
            dateAdded: Date(timeIntervalSince1970: 30),
            dateLastAccessed: Date(timeIntervalSince1970: 40),
            bibleReference: "John 1:2"
        )
        let folder = PSBookmarkFolder(
            name: "Study",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [first, second]
        )
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [folder]
        )
        let center = NotificationCenter()
        var saveCount = 0
        var changeCount = 0
        let observer = center.addObserver(
            forName: .bookmarksChanged,
            object: nil,
            queue: nil
        ) { _ in
            changeCount += 1
        }
        defer { center.removeObserver(observer) }
        let store = BookmarkStore(
            rootProvider: { root },
            save: {
                saveCount += 1
                return true
            },
            notificationCenter: center
        )

        try store.addFolder(
            name: "Notes",
            color: BookmarkColor(hexString: "#12ABEF"),
            to: folder.id
        )
        let notes = try XCTUnwrap(
            store.children(in: folder.id).first { $0.name == "Notes" }
        )
        try store.updateFolder(
            id: notes.id,
            name: "Notes 2",
            color: BookmarkColor(hexString: "#FF0000")
        )
        store.reorder(
            parentID: folder.id,
            sources: [second.id],
            before: first.id
        )
        try store.rename(id: first.id, to: "Opening")

        let children = store.children(in: folder.id)
        XCTAssertEqual(children.map(\.id), [second.id, first.id, notes.id])
        XCTAssertEqual(children[1].name, "Opening")
        XCTAssertEqual(store.node(id: notes.id)?.name, "Notes 2")
        XCTAssertEqual(
            (folder.children?[1] as? PSBookmarkObject)?.id,
            first.id
        )
        XCTAssertEqual(
            (folder.children?[2] as? PSBookmarkFolder)?.rgbHexString,
            "#FF0000"
        )
        XCTAssertEqual(store.markAccessed(id: first.id), "John 1:1")
        XCTAssertTrue(store.remove(id: second.id))
        XCTAssertEqual(store.children(in: folder.id).map(\.id), [first.id, notes.id])
        XCTAssertEqual(saveCount, 6)
        XCTAssertEqual(changeCount, 5)
    }

    func testBookmarkStoreRejectsDuplicateAndInvalidFolderNames() throws {
        let folder = PSBookmarkFolder(
            name: "Study",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: nil
        )
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [folder]
        )
        let store = BookmarkStore(
            rootProvider: { root },
            save: { true },
            notificationCenter: NotificationCenter()
        )

        XCTAssertThrowsError(
            try store.addFolder(name: "Study", color: nil, to: nil)
        ) {
            XCTAssertEqual($0 as? BookmarkMutationError, .duplicateFolder)
        }
        XCTAssertThrowsError(
            try store.addFolder(
                name: "Bad\(AppConstants.folderSeparatorString)Name",
                color: nil,
                to: nil
            )
        ) {
            XCTAssertEqual($0 as? BookmarkMutationError, .invalidFolderName)
        }
    }

    @MainActor
    func testLibraryBookmarkChildrenParticipateInObservation() throws {
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: nil
        )
        let library = LibraryModel(
            bookmarkStore: BookmarkStore(
                rootProvider: { root },
                save: { true },
                notificationCenter: NotificationCenter()
            ),
            historyStore: HistoryStore(
                defaults: defaults,
                cloudStore: HistoryCloudStoreStub(),
                notificationCenter: NotificationCenter()
            )
        )
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = library.bookmarkChildren(in: nil).count
        } onChange: {
            changed.withLock { $0 = true }
        }

        try library.addBookmarkFolder(
            name: "Study",
            color: nil,
            parentID: nil
        )

        XCTAssertTrue(changed.withLock { $0 })
        XCTAssertEqual(library.bookmarkChildren(in: nil).first?.name, "Study")
    }

    @MainActor
    func testLibraryModelRestoresFiltersAndSelectsDictionary() {
        defaults.set(
            BundledModules.strongsGreek,
            forKey: Defaults.lastDictionary
        )
        var selectedModule: String?
        let keys = [
            BundledModules.strongsGreek: ["G0001", "G0002", "Word"],
            BundledModules.strongsHebrew: ["H0001"],
        ]
        let dictionaryStore = DictionaryStore(
            defaults: defaults,
            moduleProvider: { selectedModule },
            moduleLoader: {
                selectedModule = $0
                if let module = $0 {
                    self.defaults.set(module, forKey: Defaults.lastDictionary)
                }
            },
            moduleTypeProvider: { _ in "Lexicons / Dictionaries" },
            keysProvider: { keys[$0] ?? [] },
            entryProvider: { module, key in "\(module):\(key)" },
            htmlBuilder: { body, _ in "<html>\(body)</html>" }
        )
        let library = LibraryModel(
            bookmarkStore: BookmarkStore(
                rootProvider: { PSBookmarkFolder() },
                save: { true },
                notificationCenter: NotificationCenter()
            ),
            historyStore: HistoryStore(
                defaults: defaults,
                cloudStore: HistoryCloudStoreStub(),
                notificationCenter: NotificationCenter()
            ),
            dictionaryStore: dictionaryStore
        )

        library.reloadDictionary()

        XCTAssertEqual(library.dictionaryModule, BundledModules.strongsGreek)
        XCTAssertEqual(library.visibleDictionaryKeys.count, 3)

        library.dictionaryQuery = "0002"
        XCTAssertEqual(library.visibleDictionaryKeys, ["G0002"])
        XCTAssertTrue(
            library.dictionaryEntry(key: "G0002")?.html.contains(
                "\(BundledModules.strongsGreek):G0002"
            ) ?? false
        )

        library.selectDictionary(module: BundledModules.strongsHebrew)
        XCTAssertEqual(library.dictionaryModule, BundledModules.strongsHebrew)
        XCTAssertEqual(library.dictionaryQuery, "")
        XCTAssertEqual(library.visibleDictionaryKeys, ["H0001"])
        XCTAssertEqual(
            defaults.string(forKey: Defaults.lastDictionary),
            BundledModules.strongsHebrew
        )
    }

    func testHistoryStoreUsesNaturalIDsAndPersistsRemoval() throws {
        let firstDate = Date(timeIntervalSince1970: 200)
        let secondDate = Date(timeIntervalSince1970: 100)
        defaults.set(
            [
                ["John 3:16", "0", "KJV", firstDate],
                ["Psalms 23:4", "0", "KJV", secondDate],
            ],
            forKey: AppConstants.historyName
        )
        let cloud = HistoryCloudStoreStub()
        let center = NotificationCenter()
        var changeCount = 0
        let token = center.addObserver(
            forName: .historyChanged,
            object: nil,
            queue: nil
        ) { _ in
            changeCount += 1
        }
        defer { center.removeObserver(token) }
        let store = HistoryStore(
            defaults: defaults,
            cloudStore: cloud,
            notificationCenter: center
        )

        let entries = store.snapshot()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id.reference, "John 3:16")
        XCTAssertEqual(entries[0].id.moduleName, "KJV")
        XCTAssertEqual(entries[0].id.dateAdded, firstDate)
        XCTAssertTrue(store.remove(id: entries[0].id))
        XCTAssertEqual(
            defaults.array(forKey: AppConstants.historyName)?.count,
            1
        )
        XCTAssertEqual(
            (cloud.values[AppConstants.historyName] as? [Any])?.count,
            1
        )
        XCTAssertEqual(changeCount, 1)
    }

    func testHistoryStoreOwnsExternalCloudNotificationAndInitialMerge() {
        let localDate = Date(timeIntervalSince1970: 100)
        let cloudDate = Date(timeIntervalSince1970: 200)
        defaults.set(
            [["Genesis 1:1", "0", "KJV", localDate]],
            forKey: AppConstants.historyName
        )
        let cloud = HistoryCloudStoreStub()
        cloud.set(
            [["John 3:16", "0", "KJV", cloudDate]],
            forKey: AppConstants.historyName
        )
        let center = NotificationCenter()
        let store = HistoryStore(
            defaults: defaults,
            cloudStore: cloud,
            notificationCenter: center
        )
        store.startCloudSync()
        defer { store.stopCloudSync() }

        center.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            userInfo: [
                NSUbiquitousKeyValueStoreChangeReasonKey:
                    NSNumber(
                        value: NSUbiquitousKeyValueStoreInitialSyncChange
                    ),
                NSUbiquitousKeyValueStoreChangedKeysKey:
                    [AppConstants.historyName],
            ]
        )

        let merged = defaults.array(forKey: AppConstants.historyName)
        XCTAssertEqual(merged?.count, 2)
        XCTAssertEqual((merged?.first as? [Any])?.first as? String, "John 3:16")
        XCTAssertEqual(
            (cloud.values[AppConstants.historyName] as? [Any])?.count,
            2
        )
    }

    func testLaunchCoordinatorRunsOneShotMigrationsOffUIKit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let documents = root.appendingPathComponent("Documents")
        let caches = root.appendingPathComponent("Caches")
        let installer = root.appendingPathComponent("InstallMgr")
        let temporary = root.appendingPathComponent("MMM")
        for directory in [documents, caches, installer, temporary] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        for name in ["mods.d", "modules", "locales.d", "unused"] {
            try FileManager.default.createDirectory(
                at: documents.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let cachePath = caches.appendingPathComponent(
            "cache-\(BundledModules.morphGreek)-1.0"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: cachePath.path,
                contents: Data()
            )
        )

        defaults.set(true, forKey: Defaults.kjvRemoved)
        defaults.set("None", forKey: Defaults.strongsGreekModule)
        defaults.set("orphan", forKey: "fontNamePreference_")
        defaults.psSet(
            "Legacy Font",
            forPref: Defaults.fontNamePreference,
            module: BundledModules.bible
        )
        defaults.set("Nonsense 9", forKey: Defaults.lastRef)
        defaults.set("42", forKey: Defaults.bibleVersePosition)
        defaults.set(true, forKey: Defaults.insomniaPreference)
        var resetCount = 0
        let coordinator = LaunchCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            paths: LaunchCoordinator.Paths(
                moduleRoot: documents.path,
                appSupportRoot: caches.path,
                installerRoot: installer.path,
                temporaryRoot: temporary.path
            ),
            moduleControllerAvailable: { true },
            resetModuleSelections: { resetCount += 1 },
            currentReference: { "Nonsense 9" },
            referenceResolves: { _ in false }
        )

        let result = coordinator.prepare()

        XCTAssertEqual(result, LaunchResult(shouldDisableIdleTimer: true))
        XCTAssertEqual(resetCount, 0)
        XCTAssertTrue(defaults.bool(forKey: Defaults.moduleChoiceRetired))
        XCTAssertTrue(defaults.bool(forKey: Defaults.globalFontOnly))
        XCTAssertTrue(defaults.bool(forKey: Defaults.lastRefValidated))
        XCTAssertTrue(defaults.bool(forKey: Defaults.dictKeyCaseFixed))
        XCTAssertTrue(defaults.bool(forKey: Defaults.swordRetired))
        XCTAssertNil(defaults.object(forKey: Defaults.kjvRemoved))
        XCTAssertNil(defaults.object(forKey: Defaults.strongsGreekModule))
        XCTAssertNil(defaults.object(forKey: "fontNamePreference_"))
        XCTAssertNil(
            defaults.psString(
                Defaults.fontNamePreference,
                forModule: BundledModules.bible
            )
        )
        XCTAssertEqual(defaults.string(forKey: Defaults.lastRef), "Genesis 1")
        XCTAssertEqual(
            defaults.string(forKey: Defaults.bibleVersePosition),
            "1"
        )
        XCTAssertEqual(
            defaults.string(forKey: Defaults.commentaryVersePosition),
            "1"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachePath.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: installer.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: temporary.path)
        )
        for name in ["mods.d", "modules", "locales.d", "unused"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: documents.appendingPathComponent(name).path
                )
            )
        }
    }

    func testLaunchCoordinatorResetPreservesLegacyKeysAndNotifications() {
        defaults.set(true, forKey: "reset_PocketSword")
        defaults.set("John 3", forKey: Defaults.lastRef)
        defaults.set(["history"], forKey: AppConstants.historyName)
        defaults.set("value", forKey: "loadedSWORDLocales-130708")
        defaults.psSet(
            true,
            forPref: Defaults.redLetterPreference,
            module: BundledModules.bible
        )
        let center = NotificationCenter()
        var resetNotifications = 0
        var redisplayNotifications = 0
        let resetObserver = center.addObserver(
            forName: .appStateDidReset,
            object: nil,
            queue: nil
        ) { _ in resetNotifications += 1 }
        let redisplayObserver = center.addObserver(
            forName: .redisplayPrimaryBible,
            object: nil,
            queue: nil
        ) { _ in redisplayNotifications += 1 }
        defer {
            center.removeObserver(resetObserver)
            center.removeObserver(redisplayObserver)
        }
        var resetSelections = 0
        let coordinator = LaunchCoordinator(
            defaults: defaults,
            notificationCenter: center,
            moduleControllerAvailable: { true },
            resetModuleSelections: { resetSelections += 1 }
        )

        XCTAssertTrue(coordinator.resetPreferences())

        XCTAssertNil(defaults.object(forKey: "reset_PocketSword"))
        XCTAssertNil(defaults.object(forKey: Defaults.lastRef))
        XCTAssertNil(defaults.object(forKey: AppConstants.historyName))
        XCTAssertNil(
            defaults.object(forKey: "loadedSWORDLocales-130708")
        )
        XCTAssertNil(
            defaults.object(
                forKey: defaults.psModuleKey(
                    Defaults.redLetterPreference,
                    BundledModules.bible
                )
            )
        )
        XCTAssertEqual(resetSelections, 1)
        XCTAssertEqual(resetNotifications, 1)
        XCTAssertEqual(redisplayNotifications, 1)
    }

    /// A reset has to TAKE in the live models, not just in the defaults plist.
    ///
    /// `resetPreferences()` removes `fontNamePreference` / `fontSizePreference` /
    /// `insomniaPreference` / `bibleHistory` from under models that have cached them
    /// — at launch, AFTER `AppSession.start()` has run, because `didFinishLaunching`
    /// precedes `RootView`'s `.task`.
    ///
    /// Also pins the half that is easy to get wrong: the reload must NOT write the
    /// cached values back. `SettingsModel`'s properties persist themselves from
    /// `didSet`, so assigning them individually would re-create the deleted keys.
    @MainActor
    func testAppStateResetReloadsTheModelsThatCachedRemovedPreferences() {
        defaults.set("John 3", forKey: Defaults.lastRef)
        defaults.set("Gentium Plus", forKey: Defaults.fontNamePreference)
        defaults.set(18, forKey: Defaults.fontSizePreference)
        defaults.set(true, forKey: Defaults.insomniaPreference)
        defaults.set(
            [[
                "John 3:16",
                "0",
                BundledModules.bible,
                Date(timeIntervalSince1970: 1),
            ]],
            forKey: AppConstants.historyName
        )

        let settings = SettingsModel(store: SettingsStore(defaults: defaults))
        let library = LibraryModel(
            bookmarkStore: BookmarkStore(
                rootProvider: { PSBookmarkFolder() },
                save: { true },
                notificationCenter: NotificationCenter()
            ),
            historyStore: HistoryStore(
                defaults: defaults,
                cloudStore: HistoryCloudStoreStub(),
                notificationCenter: NotificationCenter()
            ),
            dictionaryStore: DictionaryStore(
                defaults: defaults,
                moduleProvider: { nil },
                moduleLoader: { _ in },
                moduleTypeProvider: { _ in nil },
                keysProvider: { _ in [] },
                entryProvider: { _, _ in nil }
            ),
            notificationCenter: NotificationCenter()
        )
        let session = AppSession(
            settings: settings,
            library: library,
            readingStore: ReadingStateStore(defaults: defaults)
        )
        session.start()

        XCTAssertEqual(settings.fontName, "Gentium Plus")
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertTrue(settings.keepScreenAwake)
        XCTAssertEqual(library.history.count, 1)
        XCTAssertEqual(session.reading.reference?.chapterRef, "John 3")

        // The handler is delivered on `OperationQueue.main`, so the test has to wait
        // for it. This probe is registered on the same center AFTER `start()`:
        // NotificationCenter delivers to observers in registration order and both
        // blocks land on the same serial queue, so by the time it fulfils the
        // session's handler has finished. (Deliberately NOT an
        // `XCTNSPredicateExpectation` — XCTest does not promise to evaluate the
        // predicate on the main thread, and reading these `@MainActor` models from
        // it would need `MainActor.assumeIsolated`, which traps rather than fails.)
        let handled = expectation(description: "appStateDidReset handled")
        let probe = NotificationCenter.default.addObserver(
            forName: .appStateDidReset,
            object: nil,
            queue: .main
        ) { _ in handled.fulfill() }
        defer { NotificationCenter.default.removeObserver(probe) }

        // The real coordinator, on the real center — the observer is registered
        // there — with only `defaults` and the module-controller seams stubbed.
        let coordinator = LaunchCoordinator(
            defaults: defaults,
            moduleControllerAvailable: { true },
            resetModuleSelections: {}
        )
        XCTAssertTrue(coordinator.resetPreferences())
        wait(for: [handled], timeout: 5)

        XCTAssertEqual(settings.fontName, AppConstants.defaultFontName)
        XCTAssertEqual(settings.fontSize, 20)
        XCTAssertFalse(settings.keepScreenAwake)
        XCTAssertTrue(library.history.isEmpty)
        XCTAssertEqual(session.reading.reference?.chapterRef, "Genesis 1")
        // The reload read the defaults; it must not have written them back.
        XCTAssertNil(defaults.object(forKey: Defaults.fontNamePreference))
        XCTAssertNil(defaults.object(forKey: Defaults.insomniaPreference))
    }

    /// The reset must leave a USABLE module selection behind.
    ///
    /// `resetModuleSelections` clears all three primaries, and the singleton only
    /// resolves them in `init`, so without re-resolving the reading ones the reader
    /// is blank until the next launch.
    ///
    /// Uses a private center so the reset's posts cannot reach an `AppSession`
    /// another test started. `reloadLast*` resolves against
    /// `UserDefaults.standard` (the singleton has no injectable defaults), so the
    /// two keys are cleared there first — the same writes the app makes at every
    /// launch, which makes the bundled-default fallback deterministic.
    @MainActor
    func testResetRestoresThePrimaryReadingModules() {
        let controller: PSModuleController = PSModuleController.default()
        let previousDictionary = controller.primaryDictionaryName
        defer { controller.primaryDictionaryName = previousDictionary }
        UserDefaults.standard.removeObject(forKey: Defaults.lastBible)
        UserDefaults.standard.removeObject(forKey: Defaults.lastCommentary)
        let coordinator = LaunchCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )

        XCTAssertTrue(coordinator.resetPreferences())

        XCTAssertEqual(controller.primaryBibleName, BundledModules.bible)
        XCTAssertEqual(
            controller.primaryCommentaryName,
            BundledModules.commentary
        )
        // The lexicon is deliberately NOT restored: `lastDictionary` is gone, and
        // "none selected" is the fresh-install state.
        XCTAssertNil(controller.primaryDictionaryName)
    }

    func testSearchOptionsStorePreservesLegacyKeysAndEnumOrdinals() {
        let store = SearchOptionsStore(defaults: defaults)
        store.save(
            SearchOptionsSnapshot(
                fuzzy: true,
                matchType: .ExactSearch,
                range: .BookRange
            )
        )

        let snapshot = store.snapshot()

        XCTAssertTrue(snapshot.fuzzy)
        XCTAssertEqual(snapshot.matchType, .ExactSearch)
        XCTAssertEqual(snapshot.range, .BookRange)
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.lastSearchType),
            PSSearchType.ExactSearch.rawValue
        )
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.lastSearchRange),
            PSSearchRange.BookRange.rawValue
        )
    }

    @MainActor
    func testSearchWorkspaceReselectionRequestsKeyboardFocus() {
        let session = AppSession(selectedWorkspace: .search)

        XCTAssertEqual(session.searchFocusRequest, 0)

        session.selectedWorkspace = .search
        XCTAssertEqual(session.searchFocusRequest, 1)

        session.selectedWorkspace = .read
        session.selectedWorkspace = .search
        XCTAssertEqual(
            session.searchFocusRequest,
            1,
            "Entering Search from another workspace is not a reselection."
        )
    }

    @MainActor
    func testSearchResultClipboardCopiesReferenceAndNormalizedText() {
        XCTAssertEqual(
            SearchResultClipboardText.make(
                reference: "John 3:16",
                text: "For God so loved\n  the world"
            ),
            "John 3:16 For God so loved the world"
        )
        XCTAssertEqual(
            SearchResultClipboardText.make(
                reference: "John 3:16",
                text: nil
            ),
            "John 3:16"
        )

        let pasteboard = UIPasteboard.general
        defer { pasteboard.string = nil }

        SearchResultClipboard.copy(
            reference: "John 3:16",
            text: "For God so loved\n  the world",
            to: pasteboard
        )
        XCTAssertEqual(
            pasteboard.string,
            "John 3:16 For God so loved the world"
        )
    }

    @MainActor
    func testSearchModelUsesNaturalResultIdentity() {
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            )
        )
        let result = PSSearchResult(
            reference: "John 3:16",
            fullText: "For God so loved the world"
        )
        result.strongsHighlightWords = ["loved"]

        model.setResults([result])

        XCTAssertEqual(model.results.first?.id, "John 3:16")
        XCTAssertEqual(model.results.first?.text, "For God so loved the world")
        XCTAssertEqual(model.results.first?.strongsHighlightWords, ["loved"])
    }

    /// A SECOND "Find all occurrences" must run the new term, not re-show the
    /// previous one's results.
    ///
    /// `SearchView.configure(...)` runs once per launch behind a `@State` guard, so
    /// seeding it would only work for the first Strong's search (tapping H1254
    /// showed H430's results). `startStrongsQuery` drives the model directly.
    @MainActor
    func testRepeatedStrongsQueriesEachRunTheirOwnTerm() async {
        // The query runs on a global queue, so the expressions are collected
        // behind a lock and awaited rather than read straight after the call.
        let collector = ExpressionCollector()
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, expression, _, _, _ in
                collector.record(expression)
                return [
                    PSSearchResult(
                        reference: "Genesis 1:1",
                        fullText: "In the beginning"
                    ),
                ]
            }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.startStrongsQuery("H430", currentBookName: "Genesis")
        XCTAssertEqual(model.query, "H430")
        XCTAssertTrue(model.strongsSearch)
        await collector.wait(forCount: 1, in: self)

        // The second lookup is the one that matters.
        model.startStrongsQuery("H1254", currentBookName: "Genesis")
        XCTAssertEqual(
            model.query,
            "H1254",
            "A second Strong's lookup must replace the query, not keep the first."
        )
        await collector.wait(forCount: 2, in: self)

        let expressions = collector.snapshot()
        XCTAssertTrue(
            expressions[0].contains("430"),
            "First query should search H430; got \(expressions[0])"
        )
        XCTAssertTrue(
            expressions[1].contains("1254"),
            "Second query should search H1254; got \(expressions[1])"
        )

        // An empty or whitespace-only term is ignored rather than clearing the
        // query, so a malformed link cannot wipe a good search.
        model.startStrongsQuery("   ", currentBookName: "Genesis")
        XCTAssertEqual(model.query, "H1254")
        XCTAssertEqual(collector.snapshot().count, 2)
    }

    /// A Strong's lookup made BEFORE the Search workspace has ever appeared must
    /// still turn Strong's mode on.
    ///
    /// `strongsAvailable` is only resolved by `applyModule` during `configure(...)`,
    /// which has not run if the user went straight from the reader to a Strong's
    /// link on a fresh launch. Reading its `false` default would switch the mode
    /// off and search for the literal text "H430".
    ///
    /// So this test deliberately does NOT call `configure(...)` first. That absence
    /// is the whole point.
    @MainActor
    func testStrongsQueryEnablesStrongsModeBeforeTheWorkspaceIsConfigured() {
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            // Would be `true` for KJV, but it is never consulted here: nothing has
            // resolved a module yet, which is exactly the unconfigured state.
            featureProvider: { _, _ in true },
            queryOperation: { _, _, _, _, _ in [] }
        )

        XCTAssertFalse(
            model.strongsAvailable,
            "Precondition: an unconfigured model has not resolved its module."
        )

        model.startStrongsQuery("H430", currentBookName: nil)

        XCTAssertEqual(model.query, "H430")
        XCTAssertTrue(
            model.strongsSearch,
            "Strong's mode must be on — the term IS a Strong's number, and with the "
                + "mode off the query searches for the literal text \"H430\"."
        )

        // A genuine user edit still runs its side effects immediately, and must not
        // undo the seeded mode before a module has been resolved.
        model.fuzzySearch = true
        XCTAssertTrue(
            model.strongsSearch,
            "an option mutation must not clear the mode before a module is resolved."
        )
    }

    /// A model-originated seed must run exactly one search.
    ///
    /// Search input side effects run in the properties' `didSet` observers, while
    /// `startStrongsQuery` marks its writes as internal and schedules once
    /// explicitly.
    @MainActor
    func testSeededStrongsQueryRunsExactlyOnce() async {
        let collector = ExpressionCollector()
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, expression, _, _, _ in
                collector.record(expression)
                return []
            }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.startStrongsQuery("H430", currentBookName: "Genesis")
        await collector.wait(forCount: 1, in: self)
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(
            collector.snapshot().count, 1,
            "the seeded query must run once; the onChange echoes are not user edits"
        )
        XCTAssertTrue(model.strongsSearch)
        XCTAssertEqual(model.query, "H430")
    }

    /// A genuine user edit still schedules after a model-originated mutation.
    ///
    /// The user write is handled synchronously by the property's observer, so a later
    /// internal write cannot erase its provenance before an `.onChange` callback.
    @MainActor
    func testUserEditAfterAnInternalMutationStillRunsASearch() async {
        let collector = ExpressionCollector()
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, expression, _, _, _ in
                collector.record(expression)
                return []
            }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.startStrongsQuery("H430", currentBookName: "Genesis")
        await collector.wait(forCount: 1, in: self)

        // The user now types over it.
        model.query = "light"
        await collector.wait(forCount: 2, in: self)

        XCTAssertEqual(
            collector.snapshot().count, 2,
            "a real edit after a suppressed echo must still search"
        )
    }

    /// A module that genuinely has no Strong's index still clears the mode: once a
    /// module IS resolved and does not advertise Strong's, the mode goes off.
    @MainActor
    func testStrongsQueryRespectsAModuleWithoutStrongs() {
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in false },
            queryOperation: { _, _, _, _, _ in [] }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "MHCC", kind: .commentary)],
            preferredModule: "MHCC",
            currentBookName: nil,
            restoring: nil
        )
        XCTAssertFalse(model.strongsAvailable)

        model.startStrongsQuery("H430", currentBookName: nil)

        XCTAssertEqual(model.query, "H430")
        XCTAssertFalse(
            model.strongsSearch,
            "MHCC advertises no Strong's, so the mode must stay off."
        )
    }

    @MainActor
    func testUserOptionMutationPersistsAndScopesImmediately() {
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            )
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.range = .BookRange

        XCTAssertEqual(model.bookName, "Genesis")
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.lastSearchRange),
            PSSearchRange.BookRange.rawValue
        )
    }

    @MainActor
    func testModuleCannotChangeWhileItsIndexBuildIsRunning() async {
        let buildStarted = expectation(description: "Index build started")
        let buildFinished = expectation(description: "Index build finished")
        let releaseBuild = DispatchSemaphore(value: 0)
        let coordinator = SearchIndexCoordinator(
            freshnessProvider: { _ in false },
            buildGate: SearchIndexBuildGate(),
            buildOperation: { module, _ in
                XCTAssertEqual(module, "KJV")
                buildStarted.fulfill()
                releaseBuild.wait()
            }
        )
        var startedModules: [String] = []
        var finishedModules: [String] = []
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: coordinator,
            indexBuildStarted: {
                startedModules.append($0)
            },
            indexBuildFinished: {
                finishedModules.append($0)
                buildFinished.fulfill()
            }
        )
        let kjv = SearchModuleChoice(id: "KJV", kind: .bible)
        let mhcc = SearchModuleChoice(id: "MHCC", kind: .commentary)
        model.configure(
            modules: [kjv, mhcc],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.startIndexBuild()
        await fulfillment(of: [buildStarted], timeout: 2)
        model.selectModule(mhcc)
        coordinator.refresh(module: "MHCC")

        XCTAssertEqual(model.module, "KJV")
        XCTAssertEqual(coordinator.state, .building(progress: 0))
        XCTAssertEqual(startedModules, ["KJV"])

        releaseBuild.signal()
        await fulfillment(of: [buildFinished], timeout: 2)

        XCTAssertEqual(finishedModules, ["KJV"])
        XCTAssertEqual(coordinator.state, .ready)
    }

    @MainActor
    func testSearchIndexCoordinatorReportsProgressAndCompletion() async {
        let completed = expectation(description: "Index build completed")
        let coordinator = SearchIndexCoordinator(
            freshnessProvider: { $0 == "KJV" },
            buildOperation: { _, progress in
                var cancel = false
                progress?(0.5, &cancel)
            }
        )
        var states: [SearchIndexState] = []
        coordinator.onStateChange = {
            states.append($0)
        }
        coordinator.onCompletion = { success, cancelled in
            XCTAssertTrue(success)
            XCTAssertFalse(cancelled)
            completed.fulfill()
        }

        coordinator.refresh(module: "KJV")
        coordinator.build(module: "KJV")
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(states.contains(.building(progress: 0)))
        XCTAssertTrue(states.contains(.building(progress: 0.5)))
        XCTAssertEqual(states.last, .ready)
    }

    @MainActor
    func testSearchModelRejectsAStaleCompletion() async {
        let newestSearchCompleted = expectation(
            description: "Newest search completed"
        )
        let coordinator = SearchIndexCoordinator(
            freshnessProvider: { _ in true },
            buildOperation: { _, _ in }
        )
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: coordinator,
            debounceInterval: 0,
            featureProvider: { _, _ in false },
            queryOperation: { _, expression, _, _, _ in
                if expression.contains("first") {
                    Thread.sleep(forTimeInterval: 0.15)
                    return [
                        PSSearchResult(
                            reference: "Genesis 1:1",
                            fullText: "first"
                        ),
                    ]
                }
                Thread.sleep(forTimeInterval: 0.01)
                return [
                    PSSearchResult(
                        reference: "John 3:16",
                        fullText: "second"
                    ),
                ]
            }
        )
        model.onHistoryChange = { _ in
            if model.results.first?.reference == "John 3:16" {
                newestSearchCompleted.fulfill()
            }
        }
        model.configure(
            modules: [
                SearchModuleChoice(id: "KJV", kind: .bible),
            ],
            preferredModule: "KJV",
            currentBookName: "John",
            restoring: nil
        )

        model.query = "first"
        model.query = "second"

        await fulfillment(of: [newestSearchCompleted], timeout: 2)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(model.results.map(\.reference), ["John 3:16"])
        XCTAssertEqual(model.results.first?.text, "second")
    }

    @MainActor
    func testSearchModelRestoresHistoryAndStrongHighlights() throws {
        let coordinator = SearchIndexCoordinator(
            freshnessProvider: { _ in false },
            buildOperation: { _, _ in }
        )
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: coordinator,
            featureProvider: { module, feature in
                module == "KJV" && feature == "Strongs"
            }
        )
        let historyItem = try XCTUnwrap(
            PSSearchHistoryItem(
                searchTermToDisplay: "H430",
                strongs: true,
                fuzzy: false,
                type: .OrSearch,
                range: .BookRange,
                book: "Genesis"
            )
        )
        historyItem.results = [
            PSVerseTextEntry(
                key: "Genesis 1:1",
                text: "In the beginning God created"
            ),
        ]

        model.configure(
            modules: [
                SearchModuleChoice(id: "KJV", kind: .bible),
                SearchModuleChoice(id: "MHCC", kind: .commentary),
            ],
            preferredModule: "KJV",
            currentBookName: "John",
            restoring: historyItem
        )

        XCTAssertEqual(model.query, "H430")
        XCTAssertTrue(model.strongsSearch)
        XCTAssertEqual(model.range, .BookRange)
        XCTAssertEqual(model.bookName, "Genesis")
        XCTAssertEqual(model.results.first?.reference, "Genesis 1:1")
        XCTAssertEqual(
            SearchModel.highlightTerms(
                query: "love \"the world\" a",
                matchType: .AndSearch,
                strongs: false
            ),
            ["love", "the world"]
        )
    }

    func testSearchIndexBackgroundManagerPersistsRecoveryRequest() {
        var submittedIdentifiers: [String] = []
        var cancelledIdentifiers: [String] = []
        let scheduler = SearchIndexBackgroundManager.Scheduler(
            register: { _, _ in true },
            submit: { request, completion in
                submittedIdentifiers.append(request.identifier)
                completion(nil)
            },
            cancel: {
                cancelledIdentifiers.append($0)
            }
        )
        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: scheduler,
            buildOperation: { _, _ in }
        )

        manager.beginForegroundBuild(module: "KJV")

        XCTAssertEqual(
            defaults.string(forKey: Defaults.pendingSearchIndexModule),
            "KJV"
        )
        XCTAssertEqual(submittedIdentifiers, ["test.search-index"])

        manager.finishForegroundBuild(module: "KJV")

        XCTAssertNil(
            defaults.string(forKey: Defaults.pendingSearchIndexModule)
        )
        XCTAssertEqual(cancelledIdentifiers, ["test.search-index"])
    }

    func testSearchIndexBackgroundManagerPerformsPendingBuild() {
        let completed = expectation(description: "Pending index build completed")
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        var builtModules: [String] = []
        let scheduler = SearchIndexBackgroundManager.Scheduler(
            register: { _, _ in true },
            submit: { _, completion in completion(nil) },
            cancel: { _ in }
        )
        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: scheduler,
            buildOperation: { module, progress in
                builtModules.append(module)
                var cancel = false
                progress?(1, &cancel)
                XCTAssertFalse(cancel)
            }
        )

        manager.performPendingBuild(
            cancellationRequested: { false }
        ) { success, shouldRetry in
            XCTAssertTrue(success)
            XCTAssertFalse(shouldRetry)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(builtModules, ["KJV"])
        XCTAssertNil(
            defaults.string(forKey: Defaults.pendingSearchIndexModule)
        )
    }

    @MainActor
    func testForegroundAndBackgroundIndexBuildsAreSerialized() async {
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        let buildGate = SearchIndexBuildGate()
        let backgroundStarted = expectation(description: "Background build started")
        let backgroundFinished = expectation(description: "Background build finished")
        let foregroundStarted = expectation(description: "Foreground build started")
        let foregroundFinished = expectation(description: "Foreground build finished")
        let releaseBackground = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var activeBuilds = 0
        var maximumActiveBuilds = 0
        var didStartForeground = false

        func enterBuild() {
            stateLock.withLock {
                activeBuilds += 1
                maximumActiveBuilds = max(maximumActiveBuilds, activeBuilds)
            }
        }

        func leaveBuild() {
            stateLock.withLock {
                activeBuilds -= 1
            }
        }

        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: SearchIndexBackgroundManager.Scheduler(
                register: { _, _ in true },
                submit: { _, completion in completion(nil) },
                cancel: { _ in }
            ),
            buildGate: buildGate,
            buildOperation: { _, _ in
                enterBuild()
                backgroundStarted.fulfill()
                releaseBackground.wait()
                leaveBuild()
            }
        )
        let coordinator = SearchIndexCoordinator(
            freshnessProvider: { _ in false },
            buildGate: buildGate,
            buildOperation: { _, _ in
                enterBuild()
                stateLock.withLock {
                    didStartForeground = true
                }
                foregroundStarted.fulfill()
                leaveBuild()
            }
        )
        coordinator.onCompletion = { success, cancelled in
            XCTAssertTrue(success)
            XCTAssertFalse(cancelled)
            foregroundFinished.fulfill()
        }

        manager.performPendingBuild(cancellationRequested: { false }) {
            success, shouldRetry in
            XCTAssertTrue(success)
            XCTAssertFalse(shouldRetry)
            backgroundFinished.fulfill()
        }
        await fulfillment(of: [backgroundStarted], timeout: 2)

        coordinator.build(module: "KJV")
        try? await Task.sleep(for: .milliseconds(100))

        let (startedBeforeRelease, activeBeforeRelease) = stateLock.withLock {
            (didStartForeground, maximumActiveBuilds)
        }
        XCTAssertFalse(startedBeforeRelease)
        XCTAssertEqual(activeBeforeRelease, 1)

        releaseBackground.signal()
        await fulfillment(
            of: [backgroundFinished, foregroundStarted, foregroundFinished],
            timeout: 2
        )

        let finalMaximum = stateLock.withLock { maximumActiveBuilds }
        XCTAssertEqual(finalMaximum, 1)
    }

    /// A FAILED background build keeps its recovery record and asks for a retry, then
    /// gives up at `maxBuildAttempts`.
    ///
    /// Dropping the record on the first failure would leave the user with no index
    /// and no retry. The bound matters as much as the retry — unbounded, a
    /// deterministic failure would re-run a ~30 s build on every cold launch.
    func testFailedBackgroundIndexBuildRetriesThenGivesUp() {
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: SearchIndexBackgroundManager.Scheduler(
                register: { _, _ in true },
                submit: { _, completion in completion(nil) },
                cancel: { _ in }
            ),
            buildOperation: { _, _ in
                throw PSSearchEngineError.sqlite("disk I/O error")
            }
        )

        for attempt in 1..<SearchIndexBackgroundManager.maxBuildAttempts {
            let done = expectation(description: "attempt \(attempt)")
            manager.performPendingBuild(cancellationRequested: { false }) {
                success, shouldRetry in
                XCTAssertFalse(success)
                XCTAssertTrue(
                    shouldRetry,
                    "attempt \(attempt) must ask for another background slot"
                )
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(
                defaults.string(forKey: Defaults.pendingSearchIndexModule),
                "KJV",
                "the recovery record must survive a retryable failure"
            )
        }

        let exhausted = expectation(description: "retry budget exhausted")
        manager.performPendingBuild(cancellationRequested: { false }) {
            success, shouldRetry in
            XCTAssertFalse(success)
            XCTAssertFalse(shouldRetry)
            exhausted.fulfill()
        }
        wait(for: [exhausted], timeout: 5)

        XCTAssertNil(
            defaults.string(forKey: Defaults.pendingSearchIndexModule),
            "the record must be dropped once the budget is spent"
        )
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.pendingSearchIndexAttempts), 0,
            "the counter is meaningless without its module and must be cleared too"
        )
    }

    /// A background failure must not RESURRECT a record someone else has cleared.
    ///
    /// The interleaving: the user's own foreground build of the same module finishes
    /// (clearing the record) while a background build is still running, and the
    /// background build then fails. A resurrected retry would call
    /// `PSSearchEngine.build`, which opens with `dropIndex()`, DESTROYING the index
    /// the user just waited for. Mutation-checked: without the `stillPending` check
    /// this reports `shouldRetry: true` and writes the attempts counter.
    func testBackgroundFailureDoesNotResurrectAClearedRecoveryRecord() {
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        // Bound to a non-optional local: `defaults` is an implicitly-unwrapped
        // optional, and a capture list re-wraps it as `UserDefaults?`.
        let suite: UserDefaults = defaults
        let manager = SearchIndexBackgroundManager(
            defaults: suite,
            taskIdentifier: "test.search-index",
            scheduler: SearchIndexBackgroundManager.Scheduler(
                register: { _, _ in true },
                submit: { _, completion in completion(nil) },
                cancel: { _ in }
            ),
            buildOperation: { _, _ in
                // The foreground build lands mid-flight and clears the record.
                suite.removeObject(forKey: Defaults.pendingSearchIndexModule)
                throw PSSearchEngineError.sqlite("late failure")
            }
        )

        let done = expectation(description: "late failure")
        manager.performPendingBuild(cancellationRequested: { false }) {
            success, shouldRetry in
            XCTAssertFalse(success)
            XCTAssertFalse(
                shouldRetry,
                "a cleared record means someone else owns this module now"
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertNil(
            defaults.string(forKey: Defaults.pendingSearchIndexModule),
            "the record must NOT be resurrected"
        )
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.pendingSearchIndexAttempts), 0,
            "no budget may be spent on a module this manager no longer owns"
        )
    }

    /// An EXPIRED background build is not billed as a failure.
    ///
    /// `PSSearchEngine.build` throws `.cancelled` on expiry, so an expired run arrives
    /// with both an error and the cancellation flag set. Testing the error first would
    /// spend retry budget on work that was merely interrupted — which is why the expiry
    /// arm comes first and reports `shouldRetry: true` with the record intact.
    func testExpiredBackgroundIndexBuildKeepsItsRecordWithoutSpendingBudget() {
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: SearchIndexBackgroundManager.Scheduler(
                register: { _, _ in true },
                submit: { _, completion in completion(nil) },
                cancel: { _ in }
            ),
            buildOperation: { _, _ in throw PSSearchEngineError.cancelled }
        )

        let done = expectation(description: "expired build")
        manager.performPendingBuild(cancellationRequested: { true }) {
            success, shouldRetry in
            XCTAssertFalse(success)
            XCTAssertTrue(shouldRetry, "expired work must be resubmitted")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(
            defaults.string(forKey: Defaults.pendingSearchIndexModule), "KJV"
        )
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.pendingSearchIndexAttempts), 0,
            "an expiration must not spend retry budget"
        )
    }

    /// Every chapter link survives the round trip to the URL the text carries.
    ///
    /// `AttributedString.link` is the only way SwiftUI makes a span of `Text`
    /// tappable, so a typed `InlineLink` has to become a URL and come back. A lossy
    /// encoding would not fail to build; it would open the wrong lexicon entry.
    func testChapterLinksSurviveTheURLRoundTrip() throws {
        let cases: [InlineLink] = [
            .strongs(type: "Hebrew", value: "0430"),
            .strongs(type: "Greek", value: "2222"),
            // The `-` flag bakes an EMPTY type, which is the case an encoding that
            // assumes two path components would drop.
            .strongs(type: "", value: "1254"),
            .morph(type: "robinson%3AN-ASF", value: "N-ASF"),
            // The reconstructed `strongMorph%3A…` form, which carries a percent
            // escape of its own.
            .morph(type: "strongMorph%3ATH8804", value: "TH8804"),
            // `passage` arrives URL-encoded off the anchor and is decoded downstream
            // by `PSContentReader.noteBody`, so it must survive as-is rather than
            // being decoded in transit.
            .note(kind: "n", value: "1", module: "KJV", passage: "Genesis+4%3A1"),
            .scriptRef(value: "Gen 1:1"),
            .verseMenu(verse: 16),
        ]

        for link in cases {
            let url = try XCTUnwrap(link.url, "\(link) produced no URL")
            let decoded = try XCTUnwrap(
                InlineLink(url: url),
                "\(link) did not decode back from \(url)"
            )
            XCTAssertEqual(decoded, link, "round trip changed \(link) via \(url)")
        }

        // Anything that is not ours must decode to nil, so the view's `openURL`
        // handler falls through to `.systemAction` — which is what lets MHCC's own
        // `sword://` scripture links keep working.
        XCTAssertNil(InlineLink(url: try XCTUnwrap(URL(string: "sword://Bible/John%203:16"))))
        XCTAssertNil(InlineLink(url: try XCTUnwrap(URL(string: "https://crosswire.org"))))
        XCTAssertNil(InlineLink(url: try XCTUnwrap(URL(string: "pslink://nonsense/1"))))
    }

    /// The per-module display toggles a module's BAKED feature set earns it:
    /// **KJV yields exactly six rows, and Cross-references is not among them** (no
    /// `OSISScripref` filter, no `Feature=Scripref`), while **MHCC yields zero**,
    /// which hides the control instead of presenting an empty menu.
    func testDisplayTogglesMatchBakedFeatureSets() throws {
        let store = try XCTUnwrap(
            PSContentStore.shared,
            "PSContentStore.shared is required for the baked feature set."
        )

        let kjv = ReaderDisplayToggle.toggles(
            forModule: BundledModules.bible,
            store: store
        )
        XCTAssertEqual(
            kjv.map(\.id),
            ["strongs", "morph", "headings", "footnotes", "redLetter", "vpl"],
            "KJV earns six rows in this order, with no cross-references row."
        )
        XCTAssertFalse(kjv.contains { $0.id == "xref" })
        // Each row must carry the same unsuffixed pref name the UIKit menu wrote,
        // because the persisted key is "<pref>_<ModuleName>".
        XCTAssertEqual(
            kjv.map(\.preference),
            [
                Defaults.strongsPreference,
                Defaults.morphPreference,
                Defaults.headingsPreference,
                Defaults.footnotesPreference,
                Defaults.redLetterPreference,
                Defaults.vplPreference,
            ]
        )

        XCTAssertTrue(
            ReaderDisplayToggle.toggles(
                forModule: BundledModules.commentary,
                store: store
            ).isEmpty,
            "MHCC declares no Feature= and no GlobalOptionFilter, so it earns no rows."
        )

        // A nil module or a nil store yields nothing rather than crashing — the
        // old `guard let ... else { setSettingsMenu(nil) }` path.
        XCTAssertTrue(
            ReaderDisplayToggle.toggles(forModule: nil, store: store).isEmpty
        )
        XCTAssertTrue(
            ReaderDisplayToggle.toggles(
                forModule: BundledModules.bible,
                store: nil
            ).isEmpty
        )
    }

    /// The chrome model reads each toggle's CURRENT per-module value, so the
    /// checkmark reflects the pref rather than a stale snapshot.
    @MainActor
    func testChromeModelReflectsPerModuleToggleValues() throws {
        let store = try XCTUnwrap(PSContentStore.shared)
        defaults.psSet(
            true,
            forPref: Defaults.strongsPreference,
            module: BundledModules.bible
        )
        defaults.psSet(
            false,
            forPref: Defaults.vplPreference,
            module: BundledModules.bible
        )

        let chrome = ReaderChromeModel()
        chrome.reloadDisplayToggles(
            forModule: BundledModules.bible,
            store: store,
            defaults: defaults
        )

        XCTAssertEqual(chrome.displayToggles.count, 6)
        XCTAssertEqual(chrome.displayToggleValues["strongs"], true)
        XCTAssertEqual(chrome.displayToggleValues["vpl"], false)

        // Switching to a module with no features empties both, which is what hides
        // the control.
        chrome.reloadDisplayToggles(
            forModule: BundledModules.commentary,
            store: store,
            defaults: defaults
        )
        XCTAssertTrue(chrome.displayToggles.isEmpty)
        XCTAssertTrue(chrome.displayToggleValues.isEmpty)
    }

    /// The accessibility-identifier prefix keeps the UIKit menu's per-tab spelling
    /// ("bible." / "commentary."), so the identifiers do not change meaning.
    @MainActor
    func testChromeIdentifierPrefixFollowsTab() {
        let chrome = ReaderChromeModel()
        chrome.isBibleTab = true
        XCTAssertEqual(chrome.identifierPrefix, "bible")
        chrome.isBibleTab = false
        XCTAssertEqual(chrome.identifierPrefix, "commentary")
    }

    /// `AppSession.start()` restores the persisted reading position and wires the
    /// settings side effects: the restored snapshot must carry both verse positions
    /// independently, and a font change must reach the reader.
    @MainActor
    func testSessionStartRestoresReadingStateAndWiresSettingsEffects() {
        defaults.set("John 3", forKey: Defaults.lastRef)
        defaults.set("16", forKey: Defaults.bibleVersePosition)
        defaults.set("17", forKey: Defaults.commentaryVersePosition)
        let settings = SettingsModel(store: SettingsStore(defaults: defaults))
        let session = AppSession(
            settings: settings,
            readingStore: ReadingStateStore(defaults: defaults)
        )

        session.start()

        XCTAssertEqual(session.reading.reference?.chapterRef, "John 3")
        XCTAssertEqual(session.reading.bibleVerse, 16)
        XCTAssertEqual(session.reading.commentaryVerse, 17)

        // A font change must post the redisplay the reader observes; that post IS
        // the whole mechanism by which Preferences reaches the reading surface.
        let redisplayed = expectation(
            forNotification: .resetBibleAndCommentaryView,
            object: nil
        )
        settings.fontName = "Gentium Plus"
        wait(for: [redisplayed], timeout: 2)
        XCTAssertEqual(
            defaults.string(forKey: Defaults.fontNamePreference),
            "Gentium Plus"
        )
    }

    /// `LibraryModel` refreshes its snapshots off `bookmarksChanged` /
    /// `historyChanged`: a mutation behind the store's back, announced by
    /// notification, must reach the published arrays, because that is what makes the
    /// SwiftUI lists update.
    @MainActor
    func testLibraryModelReloadsSnapshotsOnChangeNotifications() {
        let firstBookmark = PSBookmark(
            name: "First",
            dateAdded: nil,
            dateLastAccessed: nil,
            bibleReference: "John 1:1"
        )
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [firstBookmark]
        )
        let center = NotificationCenter()
        let library = LibraryModel(
            bookmarkStore: BookmarkStore(rootProvider: { root }),
            historyStore: HistoryStore(
                defaults: defaults,
                cloudStore: HistoryCloudStoreStub(),
                notificationCenter: center
            ),
            notificationCenter: center
        )
        library.startObservingChanges()

        XCTAssertEqual(library.bookmarks.count, 1)

        root.children = [
            firstBookmark,
            PSBookmark(
                name: "Second",
                dateAdded: nil,
                dateLastAccessed: nil,
                bibleReference: "John 1:2"
            ),
        ]
        defaults.set(
            [["John 1:1", "0", "KJV", Date(timeIntervalSince1970: 1)]],
            forKey: AppConstants.historyName
        )
        center.post(name: .bookmarksChanged, object: nil)
        center.post(name: .historyChanged, object: nil)

        XCTAssertEqual(library.bookmarks.count, 2)
        XCTAssertEqual(library.history.count, 1)
    }

    /// `HistoryStore.addEntry` writes the byte-exact persisted row shape
    /// `[ref, "0", module, NSDate]` — positional, with `"0"` a literal string.
    /// `PersistedFormatTests` locks the reader side; this locks the writer.
    @MainActor
    func testHistoryStoreAddEntryWritesThePersistedRowShape() throws {
        defaults.set("Genesis 5", forKey: Defaults.lastRef)
        defaults.set("9", forKey: Defaults.bibleVersePosition)
        defaults.removeObject(forKey: AppConstants.historyName)

        let store = HistoryStore(
            defaults: defaults,
            cloudStore: HistoryCloudStoreStub(),
            notificationCenter: NotificationCenter(),
            moduleNameProvider: { _ in BundledModules.bible }
        )
        store.addEntry(mode: .bible)

        let history = try XCTUnwrap(
            defaults.array(forKey: AppConstants.historyName)
        )
        XCTAssertEqual(history.count, 1)
        let row = try XCTUnwrap(history[0] as? [Any])
        XCTAssertEqual(row.count, 4)
        XCTAssertEqual(row[0] as? String, "Genesis 5:9")
        XCTAssertEqual(
            row[1] as? String,
            "0",
            "The scroll slot is the literal string \"0\", not a number."
        )
        XCTAssertEqual(row[2] as? String, BundledModules.bible)
        XCTAssertNotNil(row[3] as? Date)

        // Re-recording the same reference in the same module REPLACES the row
        // rather than appending, which is what keeps the list from filling with
        // one entry per scroll.
        store.addEntry(mode: .bible)
        XCTAssertEqual(
            defaults.array(forKey: AppConstants.historyName)?.count,
            1
        )
    }

    func testVerseLayoutStoreTracksTheInlineVerseAtTheViewportTop() {
        let store = VerseLayoutStore()
        store.replace(
            with: [
                VerseLayoutFragment(
                    verse: 1,
                    rect: CGRect(x: 0, y: 0, width: 180, height: 20),
                    order: 0
                ),
                VerseLayoutFragment(
                    verse: 2,
                    rect: CGRect(x: 180, y: 0, width: 80, height: 20),
                    order: 1
                ),
                VerseLayoutFragment(
                    verse: 2,
                    rect: CGRect(x: 0, y: 20, width: 260, height: 20),
                    order: 2
                ),
                VerseLayoutFragment(
                    verse: 3,
                    rect: CGRect(x: 0, y: 40, width: 260, height: 20),
                    order: 3
                ),
            ]
        )

        XCTAssertEqual(store.verse(at: 10, fallback: 1), 1)
        XCTAssertEqual(store.verse(at: 25, fallback: 1), 2)
        XCTAssertEqual(store.verse(at: 45, fallback: 1), 3)
        XCTAssertEqual(store.verse(at: 100, fallback: 1), 3)
    }

    // MARK: Launch scroll restore

    /// Saves and restores the two `UserDefaults.standard` keys the reader pane
    /// persists. `ReaderPaneModel` reads `.standard` directly (it has no injectable
    /// defaults), so a test that writes them has to put them back.
    @MainActor
    private func withPreservedPanePositionKeys(_ body: (UserDefaults, String) -> Void) {
        let standard = UserDefaults.standard
        let scrollKey = "bibleScrollPosition"
        let verseKey = Defaults.bibleVersePosition
        let previousScroll = standard.string(forKey: scrollKey)
        let previousVerse = standard.string(forKey: verseKey)
        defer {
            if let previousScroll {
                standard.set(previousScroll, forKey: scrollKey)
            } else {
                standard.removeObject(forKey: scrollKey)
            }
            if let previousVerse {
                standard.set(previousVerse, forKey: verseKey)
            } else {
                standard.removeObject(forKey: verseKey)
            }
        }
        body(standard, scrollKey)
    }

    /// **An unlaid-out scroll view's zero is not a position, and persisting it
    /// destroys the saved scroll offset.**
    ///
    /// Replays the geometry sequence measured on device. `ChapterTextView`'s first
    /// `onScrollGeometryChange` publish is all zeros and arrives ~130 ms BEFORE the
    /// restore's deferred hop runs. Treating it as a scroll writes `"0"` over the
    /// key, so every later launch opens at the top of the chapter.
    ///
    /// Step 1 is red if the `isLaidOut` guard is removed; steps 2-4 pin the gate's
    /// three exits so it cannot suppress persistence for the rest of the session.
    @MainActor
    func testUnlaidOutGeometryDoesNotOverwriteThePersistedScrollOffset() {
        withPreservedPanePositionKeys { standard, scrollKey in
            standard.set("500", forKey: scrollKey)
            let pane = ReaderPaneModel(mode: .bible)
            pane.pendingRestore = .offset(500)
            pane.applyPendingWork()

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 0, contentHeight: 0, containerHeight: 0)
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "500",
                "A scroll view with no content has not reported a position; "
                    + "persisting its zero is what destroyed the saved offset."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 0, contentHeight: 2138, containerHeight: 675)
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "500",
                "Laid out, but the restore has not landed — every offset published "
                    + "between the request and the landing is where the view WAS."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 500, contentHeight: 2138, containerHeight: 675)
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "500",
                "Landed: the key already holds the target, so there is nothing to write."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 700, contentHeight: 2138, containerHeight: 675)
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "700",
                "The gate must OPEN once the restore has landed, or the reader stops "
                    + "saving the user's position for the rest of the session."
            )
        }
    }

    /// A restore the chapter can no longer honour must give up at the scroll view's
    /// maximum rather than suppressing persistence forever.
    ///
    /// The bigger-font / fewer-rows case: the offset was saved against a taller
    /// chapter. The reachable maximum in the persisted space is
    /// `contentSize.height - containerSize.height` exactly (measured: 1199 = 1874 -
    /// 675), so pinning there IS the position now.
    @MainActor
    func testUnreachableOffsetRestoreGivesUpAtTheScrollViewsMaximum() {
        withPreservedPanePositionKeys { standard, scrollKey in
            standard.set("100000", forKey: scrollKey)
            let pane = ReaderPaneModel(mode: .bible)
            pane.pendingRestore = .offset(100_000)
            pane.applyPendingWork()

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 1463, contentHeight: 2138, containerHeight: 675)
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "1463",
                "Pinned at contentHeight - containerHeight: the target is unreachable, "
                    + "so the truth is what should be persisted."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 1200, contentHeight: 2138, containerHeight: 675)
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "1200",
                "Having given up on the target, normal persistence must resume."
            )
        }
    }
}
