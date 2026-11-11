import XCTest
import Observation
import SwiftUI
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

    func synchronize() -> Bool {
        true
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
        XCTAssertEqual(initial.librarySection, .bookmarks)
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
        model.librarySection = .dictionary

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
        XCTAssertEqual(
            defaults.string(forKey: Defaults.librarySectionPreference),
            "dictionary"
        )
        XCTAssertEqual(appearanceChanges, 2)
        XCTAssertEqual(idleTimerValues, [true])
    }

    @MainActor
    func testSettingsModelRestoresLibrarySection() {
        defaults.set("history", forKey: Defaults.librarySectionPreference)
        XCTAssertEqual(
            SettingsModel(store: SettingsStore(defaults: defaults)).librarySection,
            .history
        )

        defaults.set("unknown", forKey: Defaults.librarySectionPreference)
        XCTAssertEqual(
            SettingsModel(store: SettingsStore(defaults: defaults)).librarySection,
            .bookmarks
        )
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

    /// Every font the picker offers is one the system can supply.
    ///
    /// The list was carried over from the old app. A name with no font behind it
    /// still takes the checkmark and is named in Settings, while `Font.custom`
    /// draws a substitute face that is neither that font nor the app default.
    ///
    /// The lookup is spelled out here rather than borrowed from `StudyFonts`, so
    /// the picker's list is checked against the system and not against itself.
    func testFontPickerOffersOnlyFontsTheSystemCanSupply() {
        func systemHas(_ name: String) -> Bool {
            UIFont(name: name, size: 17) != nil
                || !UIFont.fontNames(forFamilyName: name).isEmpty
        }

        XCTAssertEqual(
            StudyFonts.all.filter { !systemHas($0) }, [],
            "the picker offers fonts this system does not have"
        )

        // Against an over-eager filter. The two bundled faces resolve because the
        // app registers them (`UIAppFonts`); "HelveticaNeue-Light" is one face's
        // PostScript name, and Menlo, Optima and Bodoni 72 are families with no
        // face of that name.
        for name in [
            AppConstants.defaultFontName, "Gentium Plus", "Ezra SIL",
            "Times New Roman", "Arial", "Helvetica Neue", "HelveticaNeue-Light",
            "Menlo", "Optima", "Bodoni 72",
        ] {
            XCTAssertTrue(StudyFonts.all.contains(name), "\(name) is no longer offered")
        }

        // A missing font file is not the test. These four have none on iOS 27.2,
        // but the system answers for them with their successors (PingFang SC / TC,
        // Kohinoor Bangla / Telugu). Where it does, they still work and stay.
        for name in ["Heiti SC", "Heiti TC", "Bangla Sangam MN", "Telugu Sangam MN"]
        where systemHas(name) {
            XCTAssertTrue(StudyFonts.all.contains(name), "\(name) is no longer offered")
        }
    }

    /// A saved font the system cannot supply renders as an absent key renders: in
    /// the app default, not in whatever face `Font.custom` substitutes.
    ///
    /// The stored preference is left alone. Saved font preferences are not
    /// migrated, so the font comes back if the system ever supplies it again.
    func testASavedFontTheSystemLacksRendersAsTheDefault() {
        withPreservedFontKeys { standard in
            // Code2000 is no longer bundled, so no system has it.
            XCTAssertNil(UIFont(name: "Code2000", size: 17))
            standard.set("Code2000", forKey: Defaults.fontNamePreference)
            XCTAssertEqual(
                ChapterTextRenderer.Style.current().fontName,
                AppConstants.defaultFontName
            )
            XCTAssertEqual(
                standard.string(forKey: Defaults.fontNamePreference),
                "Code2000",
                "resolving the font rewrote the saved preference"
            )

            standard.set("Gentium Plus", forKey: Defaults.fontNamePreference)
            XCTAssertEqual(
                ChapterTextRenderer.Style.current().fontName,
                "Gentium Plus"
            )

            standard.removeObject(forKey: Defaults.fontNamePreference)
            XCTAssertEqual(
                ChapterTextRenderer.Style.current().fontName,
                AppConstants.defaultFontName
            )
        }
    }

    /// Settings names the font in effect, so its row, its preview line and the
    /// picker's checkmark agree with what the reader draws — and showing it does
    /// not write it back over the saved preference.
    @MainActor
    func testSettingsSnapshotShowsTheFontInEffect() {
        defaults.set("Code2000", forKey: Defaults.fontNamePreference)
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.snapshot().fontName, AppConstants.defaultFontName)

        let model = SettingsModel(store: store)
        model.reload()

        XCTAssertEqual(model.fontName, AppConstants.defaultFontName)
        XCTAssertEqual(
            defaults.string(forKey: Defaults.fontNamePreference),
            "Code2000",
            "showing the font in effect rewrote the saved preference"
        )
    }

    /// The two global font keys, which `ChapterTextRenderer.Style.current()` reads
    /// from the standard defaults only.
    private func withPreservedFontKeys(_ body: (UserDefaults) -> Void) {
        let standard = UserDefaults.standard
        let keys = [Defaults.fontNamePreference, Defaults.fontSizePreference]
        let saved = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value {
                    standard.set(value, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }
        body(standard)
    }

    /// What ties an open dictionary entry to the font settings.
    ///
    /// `Style.current()` reads `UserDefaults`, which SwiftUI does not track, so a
    /// view body that resolves its style that way does not depend on the font: an
    /// entry left open in the Library follows a Settings change only if something
    /// else rebuilds it. `current(observing:)` reads the two observable
    /// properties, and those reads are the subscription. Drop either and the
    /// entry no longer depends on that setting, with nothing else to say so.
    @MainActor
    func testEntryStyleReadSubscribesToTheFontSettings() {
        let settings = SettingsModel(store: SettingsStore(defaults: defaults))
        let changes: [(String, () -> Void)] = [
            ("size", { settings.fontSize = 31 }),
            ("name", { settings.fontName = "Gentium Plus" }),
        ]
        for (what, change) in changes {
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking {
                _ = ChapterTextRenderer.Style.current(observing: settings)
            } onChange: {
                changed.withLock { $0 = true }
            }

            change()

            XCTAssertTrue(
                changed.withLock { $0 },
                "a font \(what) change does not invalidate a body that read the style"
            )
        }

        // And the style a re-run body resolves is the new one: the model's setter
        // has saved the value before SwiftUI gets to re-evaluate anything.
        withPreservedFontKeys { _ in
            let live = SettingsModel(store: SettingsStore())
            live.fontSize = 31
            live.fontName = "Gentium Plus"

            let style = ChapterTextRenderer.Style.current(observing: live)
            XCTAssertEqual(style.fontSize, 31)
            XCTAssertEqual(style.fontName, "Gentium Plus")
        }
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

    /// A folder needs a name the reader can see.
    ///
    /// A blank one is a folder icon with no label; a second one beside it is refused
    /// as a "duplicate" of nothing visible; and at the top level its picker path is
    /// "", which the bookmark editor reads as the root, so nothing can be filed in
    /// it. Both Save buttons stay enabled — a `TextField` binding lags the last
    /// keystroke, so a `.disabled` bound to it would refuse a name typed quickly —
    /// which leaves the store as the place a blank name is turned away: with the
    /// error the separator already gets, and having changed NOTHING.
    ///
    /// The name is stored as typed (no trimming), and a BOOKMARK renamed to "" still
    /// falls back to its reference — that is a different rule, and it stays.
    func testBookmarkStoreRejectsBlankFolderNames() throws {
        let bookmark = PSBookmark(
            name: "Hope",
            dateAdded: nil,
            dateLastAccessed: nil,
            bibleReference: "Romans 5:5"
        )
        // The folder that is renamed sits one level below where the new one is
        // added, so neither call can be refused as a duplicate of a blank name the
        // other let through: each has to be refused for being blank.
        let notes = PSBookmarkFolder(
            name: "Notes",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: "#12ABEF",
            children: nil
        )
        let study = PSBookmarkFolder(
            name: "Study",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [notes]
        )
        let root = PSBookmarkFolder(
            name: "Bookmarks",
            dateAdded: nil,
            dateLastAccessed: nil,
            rgbHexString: nil,
            children: [study, bookmark]
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

        for blank in ["", " ", "\n\t "] {
            XCTAssertThrowsError(
                try store.addFolder(name: blank, color: nil, to: nil),
                "addFolder accepted \(blank.debugDescription)"
            ) {
                XCTAssertEqual($0 as? BookmarkMutationError, .invalidFolderName)
            }
            XCTAssertThrowsError(
                try store.rename(id: notes.id, to: blank),
                "rename accepted \(blank.debugDescription)"
            ) {
                XCTAssertEqual($0 as? BookmarkMutationError, .invalidFolderName)
            }
            XCTAssertThrowsError(
                try store.updateFolder(id: notes.id, name: blank, color: nil),
                "updateFolder accepted \(blank.debugDescription)"
            ) {
                XCTAssertEqual($0 as? BookmarkMutationError, .invalidFolderName)
            }
        }

        XCTAssertEqual(root.children?.count, 2)
        XCTAssertEqual(notes.name, "Notes")
        XCTAssertEqual(notes.rgbHexString, "#12ABEF")
        XCTAssertEqual(saveCount, 0, "nothing may be committed on the throwing path")

        // Only an all-blank name is refused; one with whitespace around it is kept
        // exactly as typed.
        try store.rename(id: notes.id, to: " Study notes ")
        XCTAssertEqual(notes.name, " Study notes ")

        try store.rename(id: bookmark.id, to: "")
        XCTAssertEqual(bookmark.name, "Romans 5:5")
    }

    /// The bookmark editor's folder picker hands `PSBookmarks.addBookmark` a NAME
    /// path, and that path has to resolve to the folder it names.
    ///
    /// The walk used to match ANY child by name. Folders are appended, so a bookmark
    /// described "Prayer" always sits before a folder "Prayer" created later: the
    /// bookmark matched, the walk stopped without descending, and every bookmark
    /// filed under "Prayer" — or under anything inside it — landed in the root, with
    /// no error and without the folder's highlight colour. A top-level folder called
    /// "Bookmarks" went the same way: its path is the root's own title, which was
    /// read as the root.
    ///
    /// `getBookmarkFolder` resolves against the singleton, so its children are
    /// swapped for the test and put back. Nothing here saves or posts.
    func testBookmarkFolderPathResolvesToTheFolderItNames() {
        func bookmark(_ name: String) -> PSBookmark {
            PSBookmark(
                name: name,
                dateAdded: nil,
                dateLastAccessed: nil,
                bibleReference: "Romans 5:5"
            )
        }
        func folder(_ name: String, _ children: [Any]? = nil) -> PSBookmarkFolder {
            PSBookmarkFolder(
                name: name,
                dateAdded: nil,
                dateLastAccessed: nil,
                rgbHexString: nil,
                children: children
            )
        }
        func resolve(_ path: String?) -> PSBookmarkFolder {
            PSBookmarks.getBookmarkFolder(forFolderString: path)
        }
        let bookmarks = PSBookmarks.default()
        let saved = bookmarks.children
        defer { bookmarks.children = saved }

        // A bookmark and a folder of the same name, in the order the app leaves them.
        let inner = folder("Inner")
        let prayer = folder("Prayer", [inner])
        bookmarks.children = [bookmark("Prayer"), prayer]
        let innerPath = "Prayer\(AppConstants.folderSeparatorString)Inner"

        XCTAssertEqual(
            BookmarkFolderPath.all(root: bookmarks).map(\.path),
            ["Prayer", innerPath],
            "the paths the picker offers"
        )
        XCTAssertIdentical(resolve("Prayer"), prayer)
        XCTAssertIdentical(resolve(innerPath), inner)

        // A top-level folder that shares the root's title.
        let title = NSLocalizedString("BookmarksTitle", comment: "")
        let titled = folder(title)
        bookmarks.children = [titled]

        XCTAssertIdentical(resolve(title), titled)

        // No path, and a path naming no folder, still mean the root.
        XCTAssertIdentical(resolve(nil), bookmarks)
        XCTAssertIdentical(resolve(""), bookmarks)
        XCTAssertIdentical(resolve("Nope"), bookmarks)
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

    /// A Library dictionary entry is the entry as stored, not a page built around
    /// it.
    ///
    /// `PSEntryDocumentBuilder` drops an entry's own key anchor only when the
    /// anchor is the first thing in its input. Wrapped the way the WebView page was
    /// (`<div><b>KEY</b><br /><p>…</p>` plus three `&nbsp;` paragraphs), every
    /// Strong's entry showed its number twice under a navigation title that is
    /// already the key, and ended in three hard spaces.
    func testDictionaryEntryIsTheStoredEntryNotAWebViewShell() throws {
        // The two stored shapes: Hebrew breaks straight after the key anchor, Greek
        // carries its lemma line first.
        let hebrew = "<a name=\"03899\"><b>3899</b></a><br /> &#1500;&#1495;&#1501;<br />"
            + " [lechem] \\<i>lekh'-em</i>\\<br /> From"
            + " <a href=\"sword://StrongsRealHebrew/03898\">3898</a>; <i>food</i>"
        let greek = "<a name=\"03588\">3588</a> <b>&#8001;</b> [O(] {ho} \\<i>ho</i>\\<br/>"
            + "including the feminine"
        let stored = [
            "\(BundledModules.strongsHebrew)/03899": hebrew,
            "\(BundledModules.strongsGreek)/03588": greek,
        ]
        let store = DictionaryStore(
            defaults: defaults,
            moduleProvider: { nil },
            moduleLoader: { _ in },
            moduleTypeProvider: { _ in "Lexicons / Dictionaries" },
            keysProvider: { _ in [] },
            entryProvider: { module, key in stored["\(module)/\(key)"] }
        )

        for (module, key, number, raw) in [
            (BundledModules.strongsHebrew, "03899", "3899", hebrew),
            (BundledModules.strongsGreek, "03588", "3588", greek),
        ] {
            let entry = store.entry(module: module, key: key)
            XCTAssertEqual(entry.html, raw,
                           "\(module) \(key) was not passed through as stored")

            let document = PSEntryDocumentBuilder.build(html: entry.html)
            XCTAssertEqual(document, PSEntryDocumentBuilder.build(html: raw),
                           "\(module) \(key) renders differently from its stored entry")

            let texts = document.blocks.map { $0.runs.map(\.text).joined() }
            XCTAssertFalse(texts.contains(key),
                           "\(module) \(key): the key is a line of the body: \(texts)")
            XCTAssertFalse(
                texts.contains {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix(number)
                },
                "\(module) \(key): the key anchor's number renders: \(texts)"
            )
            XCTAssertFalse(
                document.blocks.flatMap(\.runs).contains { $0.text == "\u{00A0}" },
                "\(module) \(key): the entry ends in the page's padding"
            )
        }

        // And through the production wiring, against the baked store: the Library
        // hands the renderer what the popup hands it.
        let key = "03899"
        let baked = try XCTUnwrap(
            PSContentReader.entry(module: BundledModules.strongsHebrew, key: key),
            "StrongsRealHebrew \(key) is missing from the store"
        )
        XCTAssertEqual(
            DictionaryStore(defaults: defaults)
                .entry(module: BundledModules.strongsHebrew, key: key).html,
            baked
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

    /// A cloud store that counts what `HistoryStore` asks of it, and lets a test
    /// stand in for the system's answer to `synchronize()`.
    private final class LaunchSyncCloudStore: HistoryCloudStoring {
        private(set) var values: [String: Any] = [:]
        private(set) var writeCount = 0
        private(set) var synchronizeCount = 0
        var onSynchronize: (() -> Void)?

        func array(forKey defaultName: String) -> [Any]? {
            values[defaultName] as? [Any]
        }

        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value
            writeCount += 1
        }

        func removeObject(forKey defaultName: String) {
            values.removeValue(forKey: defaultName)
        }

        func synchronize() -> Bool {
            synchronizeCount += 1
            onSynchronize?()
            return true
        }
    }

    /// iCloud reports what changed while the app was not running only when it is
    /// asked: `synchronize()`, called once the observer is registered, with the
    /// answer arriving as the change notification. Without the call a launch
    /// keeps its stale local list, and the next `addEntry` writes that list over
    /// the entries the other device made.
    func testStartingCloudSyncAsksForChangesMadeWhileTheAppWasNotRunning() {
        let sharedRow: [Any] = [
            "Genesis 1:1", "0", "KJV", Date(timeIntervalSince1970: 100),
        ]
        defaults.set([sharedRow], forKey: AppConstants.historyName)
        let cloud = LaunchSyncCloudStore()
        // The other device read John 3:16 while this one was not running. The
        // two lists share a tail, so the pinned merge loses nothing here.
        let otherDeviceRow: [Any] = [
            "John 3:16", "0", "KJV", Date(timeIntervalSince1970: 200),
        ]
        cloud.set(
            [otherDeviceRow, sharedRow],
            forKey: AppConstants.historyName
        )
        let center = NotificationCenter()
        let store = HistoryStore(
            defaults: defaults,
            cloudStore: cloud,
            notificationCenter: center
        )
        // The system answering `synchronize()` with the changes since the last
        // launch.
        cloud.onSynchronize = { [unowned cloud] in
            center.post(
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: cloud,
                userInfo: [
                    NSUbiquitousKeyValueStoreChangeReasonKey:
                        NSNumber(value: NSUbiquitousKeyValueStoreServerChange),
                    NSUbiquitousKeyValueStoreChangedKeysKey:
                        [AppConstants.historyName],
                ]
            )
        }
        let writesBeforeLaunch = cloud.writeCount

        store.startCloudSync()
        defer { store.stopCloudSync() }

        XCTAssertEqual(cloud.synchronizeCount, 1)
        let merged = defaults.array(forKey: AppConstants.historyName)
        XCTAssertEqual(
            merged?.count,
            2,
            "The answer arrives while synchronize() is running, so it is "
                + "heard only if the observer was registered first."
        )
        XCTAssertEqual((merged?.first as? [Any])?.first as? String, "John 3:16")
        XCTAssertEqual((merged?.last as? [Any])?.first as? String, "Genesis 1:1")
        XCTAssertEqual(
            cloud.writeCount,
            writesBeforeLaunch,
            "The merged list is the cloud's own, so nothing is written back."
        )
        XCTAssertEqual(
            (cloud.values[AppConstants.historyName] as? [Any])?.count,
            2
        )

        // The observer is already registered, so a second start asks nothing.
        store.startCloudSync()
        XCTAssertEqual(cloud.synchronizeCount, 1)
    }

    /// `addEntry` seeds the app's persistent domain before a first entry, and
    /// those two calls address the domain by NAME whichever `UserDefaults` they
    /// are made on. Through an injected store they replaced the host app's own
    /// `bibleHistory` with an empty array, so a run of these tests emptied the
    /// reading history of the install that hosted them.
    func testAddEntryThroughAnInjectedStoreLeavesTheAppsOwnHistoryAlone() {
        let standard = UserDefaults.standard
        let saved = standard.array(forKey: AppConstants.historyName)
        defer {
            if let saved {
                standard.set(saved, forKey: AppConstants.historyName)
            } else {
                standard.removeObject(forKey: AppConstants.historyName)
            }
        }
        standard.set(
            [["Psalms 23:1", "0", "KJV", Date(timeIntervalSince1970: 1)]],
            forKey: AppConstants.historyName
        )

        defaults.set("Genesis 5", forKey: Defaults.lastRef)
        defaults.set("9", forKey: Defaults.bibleVersePosition)
        defaults.removeObject(forKey: AppConstants.historyName)
        XCTAssertNil(
            defaults.array(forKey: AppConstants.historyName),
            "The seeding is the first-entry path: the injected store must "
                + "start with no history, and must not see the app's."
        )

        let store = HistoryStore(
            defaults: defaults,
            cloudStore: HistoryCloudStoreStub(),
            notificationCenter: NotificationCenter(),
            moduleNameProvider: { _ in BundledModules.bible }
        )
        store.addEntry(mode: .bible)

        let appHistory = standard.array(forKey: AppConstants.historyName)
        XCTAssertEqual(appHistory?.count, 1)
        XCTAssertEqual(
            (appHistory?.first as? [Any])?.first as? String,
            "Psalms 23:1"
        )
        let injectedHistory = defaults.array(forKey: AppConstants.historyName)
        XCTAssertEqual(injectedHistory?.count, 1)
        XCTAssertEqual(
            (injectedHistory?.first as? [Any])?.first as? String,
            "Genesis 5:9"
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

    /// The `lastRef` check runs at EVERY launch, not once.
    ///
    /// It was gated on `DefaultsLastRefValidated`, on the assumption that
    /// nothing after it could persist a ref the reader cannot resolve. The
    /// `sword://` router then did: a book in capitals was tested as "MALACHI 3"
    /// and stored as "MALACH1 3", on installs whose flag was long set. The
    /// router is fixed, but nothing repaired what it had stored — a blank reader
    /// at every launch, and in Debug the store's assertion before a held URL is
    /// replayed — until some other navigation overwrote the ref.
    ///
    /// The real resolver, because the rule is the reader's: the check resets
    /// exactly the refs the launch render would fail on. A ref it resolves is
    /// left byte for byte, with its positions — "Gen 3" included, the
    /// abbreviation the router stores as the link spelled it.
    func testLaunchCoordinatorRepairsAnUnresolvableReferenceAtEveryLaunch() throws {
        let resolver = try XCTUnwrap(PSBookOSISResolver.shared)
        let suite: UserDefaults = defaults
        // Nothing is created under it; the file sweeps find nothing to remove.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let coordinator = LaunchCoordinator(
            defaults: suite,
            notificationCenter: NotificationCenter(),
            paths: LaunchCoordinator.Paths(
                moduleRoot: root.appendingPathComponent("Documents").path,
                appSupportRoot: root.appendingPathComponent("Caches").path,
                installerRoot: root.appendingPathComponent("InstallMgr").path,
                temporaryRoot: root.appendingPathComponent("MMM").path
            ),
            moduleControllerAvailable: { true },
            resetModuleSelections: {},
            currentReference: { suite.string(forKey: Defaults.lastRef) ?? "" },
            referenceResolves: { resolver.resolve(ref: $0) != nil }
        )
        let positionKeys = [
            Defaults.bibleVersePosition,
            Defaults.commentaryVersePosition,
            "bibleScrollPosition",
            "commentaryScrollPosition",
        ]

        // An install that has launched before: the one-shot this used to be has
        // run, and the old router has since stored a ref nothing resolves.
        suite.set(true, forKey: Defaults.lastRefValidated)
        suite.set("MALACH1 3", forKey: Defaults.lastRef)
        suite.set("10", forKey: Defaults.bibleVersePosition)
        suite.set("10", forKey: Defaults.commentaryVersePosition)
        suite.set("2400", forKey: "bibleScrollPosition")
        suite.set("900", forKey: "commentaryScrollPosition")

        XCTAssertNotNil(coordinator.prepare())

        XCTAssertEqual(suite.string(forKey: Defaults.lastRef), "Genesis 1")
        // All four describe the chapter read before the bad ref, and the launch
        // restore is by offset.
        XCTAssertEqual(
            positionKeys.map { suite.string(forKey: $0) },
            ["1", "1", "0", "0"]
        )
        XCTAssertTrue(suite.bool(forKey: Defaults.lastRefValidated))

        // A ref the reader resolves is not touched, and neither is its position.
        for reference in ["John 3", "Gen 3", "1 Corinthians 13"] {
            suite.set(reference, forKey: Defaults.lastRef)
            suite.set("16", forKey: Defaults.bibleVersePosition)
            suite.set("4", forKey: Defaults.commentaryVersePosition)
            suite.set("640", forKey: "bibleScrollPosition")
            suite.set("320", forKey: "commentaryScrollPosition")

            XCTAssertNotNil(coordinator.prepare())

            XCTAssertEqual(suite.string(forKey: Defaults.lastRef), reference)
            XCTAssertEqual(
                positionKeys.map { suite.string(forKey: $0) },
                ["16", "4", "640", "320"],
                "'\(reference)' resolves, and its position was reset"
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

    /// A reset returns EVERY row of the reader's display menu to its default.
    ///
    /// Verse Per Line was left behind. The reset removed the unsuffixed
    /// `vplPreference`, a key nothing has read since the toggle became per-module,
    /// and its per-module sweep did not list it. So Strong's, Morph, Headings,
    /// Footnotes and Red Letter went back to their defaults while a reader who had
    /// switched Verse Per Line off stayed in prose — although an absent key reads
    /// as ON, and `psDefaultOnPrefs` says so with the reset in mind.
    ///
    /// The keys come from `ReaderDisplayToggle.toggles`, not from a list written
    /// here, so a seventh row cannot be left out of the reset unnoticed.
    func testResetClearsEveryDisplayToggleTheReaderOffers() throws {
        let store = try XCTUnwrap(
            PSContentStore.shared,
            "PSContentStore.shared is required for the baked feature set."
        )
        let toggles = ReaderDisplayToggle.toggles(
            forModule: BundledModules.bible,
            store: store
        )
        XCTAssertFalse(toggles.isEmpty)
        for toggle in toggles {
            defaults.psSet(
                false,
                forPref: toggle.preference,
                module: BundledModules.bible
            )
        }
        let coordinator = LaunchCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            moduleControllerAvailable: { true },
            resetModuleSelections: {}
        )

        XCTAssertTrue(coordinator.resetPreferences())

        for toggle in toggles {
            XCTAssertNil(
                defaults.object(
                    forKey: defaults.psModuleKey(
                        toggle.preference,
                        BundledModules.bible
                    )
                ),
                "\(toggle.id) survived the reset"
            )
        }
        // The wire key spelled out, and what the reader then renders with.
        XCTAssertNil(defaults.object(forKey: "vplPreference_KJV"))
        XCTAssertTrue(
            defaults.psBool(
                Defaults.vplPreference,
                forModule: BundledModules.bible
            )
        )
    }

    /// The primaries resolved at launch are a Bible and a commentary, not merely
    /// two modules that ship.
    ///
    /// `reloadLast*` used to honour any persisted name the store had a type for, so
    /// a `lastCommentary` naming a lexicon — which `sword://StrongsRealGreek/John+3:16`
    /// could write, before the router learned to ignore such a host — came back as
    /// the commentary at every launch. A lexicon has no chapters and there is no
    /// module picker, so the commentary pane stayed empty. A name of the wrong kind
    /// now falls back to the bundled module and is rewritten, exactly like a name
    /// that is not shipped at all.
    ///
    /// `reloadLast*` resolves against `UserDefaults.standard` (the singleton has no
    /// injectable defaults), so both keys and both primaries are put back.
    func testAPersistedLexiconIsNotRestoredAsAReadingModule() {
        let controller: PSModuleController = PSModuleController.default()
        let standard = UserDefaults.standard
        let previousBible = controller.primaryBibleName
        let previousCommentary = controller.primaryCommentaryName
        let previousLastBible = standard.string(forKey: Defaults.lastBible)
        let previousLastCommentary = standard.string(forKey: Defaults.lastCommentary)
        defer {
            controller.primaryBibleName = previousBible
            controller.primaryCommentaryName = previousCommentary
            standard.set(previousLastBible, forKey: Defaults.lastBible)
            standard.set(previousLastCommentary, forKey: Defaults.lastCommentary)
        }

        standard.set(BundledModules.strongsGreek, forKey: Defaults.lastCommentary)
        standard.set(BundledModules.commentary, forKey: Defaults.lastBible)
        controller.reloadLastCommentary()
        controller.reloadLastBible()

        XCTAssertEqual(controller.primaryCommentaryName, BundledModules.commentary)
        XCTAssertEqual(
            standard.string(forKey: Defaults.lastCommentary),
            BundledModules.commentary
        )
        XCTAssertEqual(controller.primaryBibleName, BundledModules.bible)
        XCTAssertEqual(
            standard.string(forKey: Defaults.lastBible),
            BundledModules.bible
        )
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

    /// The Book scope means the book the reader is in NOW, each time Search is
    /// entered.
    ///
    /// `SearchView` configures the model once per launch, so the book it took
    /// then went stale as soon as the reader moved: open Search at Genesis, read
    /// on to John, come back, and a Book-scoped "love" listed Genesis's 3 verses
    /// instead of John's 19 — for the rest of the launch. The reader can only
    /// move while another workspace is selected, so
    /// `AppSession.selectedWorkspace`'s setter hands the book over again on the
    /// way into Search.
    @MainActor
    func testEnteringSearchHandsOverTheReadersCurrentBook() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 1", forKey: Defaults.lastRef)
            defaults.set(
                PSSearchRange.BookRange.rawValue,
                forKey: Defaults.lastSearchRange
            )
            let model = SearchModel(
                optionsStore: SearchOptionsStore(defaults: defaults),
                indexCoordinator: SearchIndexCoordinator(
                    freshnessProvider: { _ in true },
                    buildOperation: { _, _ in }
                ),
                debounceInterval: 0,
                featureProvider: { _, _ in true },
                queryOperation: { _, _, _, _, _ in [] }
            )
            let session = AppSession(
                selectedWorkspace: .read,
                search: model,
                dismissKeyboard: {}
            )
            let workspace = ReadingWorkspaceModel(session: session)

            // The first visit, and what `SearchView`'s one-shot task does on it.
            session.selectedWorkspace = .search
            model.configure(
                modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
                preferredModule: "KJV",
                currentBookName: workspace.currentSearchBookName,
                restoring: nil
            )
            XCTAssertEqual(model.bookName, "Genesis")

            // The reader moves on, and the user comes back to Search.
            session.selectedWorkspace = .read
            standard.set("John 3", forKey: Defaults.lastRef)
            session.selectedWorkspace = .search

            // Read AFTER the selection moved, which also keeps the workspace
            // alive across it: the session's edge to it is weak.
            XCTAssertEqual(workspace.currentSearchBookName, "John")
            XCTAssertEqual(
                model.bookName,
                "John",
                "The Book scope kept the book open when Search first appeared."
            )
        }
    }

    /// The hand-over itself: it changes what the Book scope means and searches
    /// nothing.
    ///
    /// The results on screen stay until the next search — re-running one on the
    /// way in would rebuild the list inside the tab bar's selection animation,
    /// and replace results a tab change is meant to preserve. The next search,
    /// by a keystroke or an option, is scoped to the book handed over.
    @MainActor
    func testBookScopeUsesTheBookHandedOverOnEntry() async {
        let collector = ExpressionCollector()
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, _, _, bookName, _ in
                collector.record(bookName ?? "-")
                return []
            }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        // Handed over under another scope, it is what choosing Book then means.
        model.readerBookDidChange("John")
        model.range = .BookRange
        XCTAssertEqual(model.bookName, "John")

        model.query = "love"
        await collector.wait(forCount: 1, in: self)
        XCTAssertEqual(collector.snapshot(), ["John"])

        // Handed over with the scope already on Book, it moves the scope...
        model.readerBookDidChange("Romans")
        XCTAssertEqual(model.bookName, "Romans")
        // ...and runs nothing by itself.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            collector.snapshot(),
            ["John"],
            "Entering Search re-ran the query that was on screen."
        )

        model.query = "loved"
        await collector.wait(forCount: 2, in: self)
        XCTAssertEqual(collector.snapshot(), ["John", "Romans"])
    }

    /// A `SearchModel` over a ready index that records, for every query it runs,
    /// `module|expression|scope|book` — everything that decides which verses a
    /// "Find all occurrences" lists.
    @MainActor
    private func strongsLookupModel(
        recordingInto collector: ExpressionCollector,
        strongsModules: Set<String> = ["KJV"]
    ) -> SearchModel {
        SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { module, feature in
                strongsModules.contains(module)
                    && (feature == "Strongs" || feature == "StrongsNumbers")
            },
            queryOperation: { module, expression, range, bookName, _ in
                collector.record(
                    "\(module)|\(expression)|\(range.rawValue)|\(bookName ?? "-")"
                )
                return []
            }
        )
    }

    /// "Find all occurrences" is offered from the Bible, and only a module that
    /// carries Strong's numbers can answer it.
    ///
    /// Search's module is sticky for the launch: it is the commentary if Search
    /// first appeared while the reader was on the commentary, or if the user
    /// picked it in the menu. The lookup then switched Strong's mode off and
    /// searched MHCC for the literal text "H430" — no results for a number the
    /// KJV has in 2,249 verses — and picking KJV by hand afterwards did not
    /// help, because nothing switched the mode back on.
    @MainActor
    func testStrongsQueryMovesSearchToTheModuleThatCarriesStrongs() async {
        let collector = ExpressionCollector()
        let model = strongsLookupModel(recordingInto: collector)
        model.configure(
            modules: [
                SearchModuleChoice(id: "KJV", kind: .bible),
                SearchModuleChoice(id: "MHCC", kind: .commentary),
            ],
            preferredModule: "MHCC",
            currentBookName: "Genesis",
            restoring: nil
        )
        XCTAssertEqual(model.module, "MHCC")
        XCTAssertFalse(model.strongsAvailable)

        model.startStrongsQuery("H430", currentBookName: "Genesis")

        XCTAssertEqual(model.module, "KJV")
        // What a tapped result opens in.
        XCTAssertEqual(model.moduleKind, .bible)
        XCTAssertTrue(model.strongsSearch)
        await collector.wait(forCount: 1, in: self)
        XCTAssertEqual(
            collector.snapshot(),
            ["KJV|lemmas:((\"H430\" OR \"H0430\"))|0|-"]
        )
    }

    /// "Find ALL occurrences" searches the whole Bible, whatever scope the last
    /// text search left.
    ///
    /// The scope is saved across launches. Under a saved New Testament scope a
    /// Hebrew number listed nothing, and under Book the list was silently
    /// confined to the book being read (189 of H430's 2,249 verses in Genesis).
    ///
    /// The last assertion pins the other half of the decision: the lookup moves
    /// the scope on screen and does NOT rewrite the saved one. A text search on
    /// the next launch gets the scope the user chose, not one a lookup picked.
    @MainActor
    func testStrongsQuerySearchesTheWholeBibleWhateverScopeWasSaved() async {
        for saved in [PSSearchRange.NTRange, .BookRange] {
            defaults.set(saved.rawValue, forKey: Defaults.lastSearchRange)
            let collector = ExpressionCollector()
            let model = strongsLookupModel(recordingInto: collector)
            model.configure(
                modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
                preferredModule: "KJV",
                currentBookName: "Genesis",
                restoring: nil
            )
            XCTAssertEqual(model.range, saved)

            model.startStrongsQuery("H430", currentBookName: "Genesis")

            XCTAssertEqual(
                model.range,
                .AllRange,
                "The lookup kept saved scope \(saved.rawValue)."
            )
            XCTAssertNil(model.bookName)
            await collector.wait(forCount: 1, in: self)
            XCTAssertEqual(
                collector.snapshot(),
                ["KJV|lemmas:((\"H430\" OR \"H0430\"))|0|-"]
            )
            XCTAssertEqual(
                defaults.integer(forKey: Defaults.lastSearchRange),
                saved.rawValue,
                "The lookup rewrote the saved scope."
            )
        }
    }

    /// The same lookup made before the Search workspace has ever appeared: the
    /// scope it set has to survive the `configure(...)` that follows, which is
    /// what runs the search.
    @MainActor
    func testStrongsQuerySeededBeforeSearchAppearsSearchesTheWholeBible() async {
        defaults.set(
            PSSearchRange.NTRange.rawValue,
            forKey: Defaults.lastSearchRange
        )
        let collector = ExpressionCollector()
        let model = strongsLookupModel(recordingInto: collector)

        model.startStrongsQuery("H430", currentBookName: "Genesis")
        model.configure(
            modules: [
                SearchModuleChoice(id: "KJV", kind: .bible),
                SearchModuleChoice(id: "MHCC", kind: .commentary),
            ],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        await collector.wait(forCount: 1, in: self)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            collector.snapshot(),
            ["KJV|lemmas:((\"H430\" OR \"H0430\"))|0|-"]
        )
        XCTAssertTrue(model.strongsSearch)
        XCTAssertEqual(model.range, .AllRange)
    }

    /// Strong's mode survives a number being typed into it, one character at a
    /// time.
    ///
    /// The mode is sticky and clears itself when the text stops looking like a
    /// Strong's number. A lone "H" used to count as not looking like one, and it
    /// is where every typed number starts: on an iPhone the first digit is two
    /// taps away (123, then the digit), which ordinary typing does not fit
    /// inside the 0.25 s debounce, so the search for the bare letter ran,
    /// switched the mode off, and nothing switched it back on. "H430" was then
    /// searched as literal text: no results, with the toggle silently off.
    ///
    /// Asserts on `model.expression`, which `runSearch` sets synchronously here
    /// (`debounceInterval: 0`); the queries themselves run on a global queue.
    @MainActor
    func testStrongsModeSurvivesANumberTypedOneCharacterAtATime() {
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, _, _, _, _ in [] }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        // The options-menu toggle, on an empty field.
        model.strongsSearch = true

        model.query = "H"
        XCTAssertTrue(
            model.strongsSearch,
            "The prefix letter alone switched Strong's mode off."
        )
        XCTAssertEqual(model.expression, "lemmas:(\"H\")")

        model.query = "H4"
        model.query = "H430"
        XCTAssertTrue(model.strongsSearch)
        XCTAssertEqual(
            model.expression,
            "lemmas:((\"H430\" OR \"H0430\"))"
        )

        // The rule this must not weaken: a plain word still clears the mode, at
        // its second letter.
        model.query = "G"
        XCTAssertTrue(model.strongsSearch)
        model.query = "Go"
        XCTAssertFalse(
            model.strongsSearch,
            "A plain word kept Strong's mode, which searches the lemmas column."
        )
        XCTAssertEqual(model.expression, "text_norm:\"go\"")
    }

    /// A query that has been typed and not yet searched is pending, not empty.
    ///
    /// Typing is debounced (0.25 s in production), and `isSearching` is raised
    /// only when the query starts. Until the timer fired, nothing told the empty
    /// state a search was owed, so with no rows on screen it read "No Results
    /// for …" about text that had not been searched: on every keystroke of a
    /// search typed into an empty list, and for the debounce after the last one.
    ///
    /// The wait has its own flag, and `isSearching` stays down through it on
    /// purpose. The result list's corner spinner reads `isSearching`; raised at
    /// arming, it would spin over the previous query's rows on every keystroke.
    @MainActor
    func testATypedQueryIsPendingThroughTheDebounce() {
        // 60 s, so the timer cannot fire during the test: every state read below
        // is the debounce window's.
        func makeModel(indexIsBuilt: Bool) -> SearchModel {
            let model = SearchModel(
                optionsStore: SearchOptionsStore(defaults: defaults),
                indexCoordinator: SearchIndexCoordinator(
                    freshnessProvider: { _ in indexIsBuilt },
                    buildOperation: { _, _ in }
                ),
                debounceInterval: 60,
                featureProvider: { _, _ in true },
                queryOperation: { _, _, _, _, _ in [] }
            )
            model.configure(
                modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
                preferredModule: "KJV",
                currentBookName: "Genesis",
                restoring: nil
            )
            return model
        }

        let model = makeModel(indexIsBuilt: true)
        XCTAssertFalse(model.isSearchPending)

        model.query = "beginning"
        XCTAssertTrue(
            model.isSearchPending,
            "Nothing says a search is owed, so the empty state reads No Results."
        )
        XCTAssertFalse(
            model.isSearching,
            "The debounce raised the flag the result list's spinner reads."
        )
        XCTAssertTrue(model.results.isEmpty)

        // Every way out of the wait ends it. Nothing left to search:
        model.query = ""
        XCTAssertFalse(model.isSearchPending)

        // The results being cleared, which is also what a module change does:
        model.query = "x"
        XCTAssertTrue(model.isSearchPending)
        model.clearResults()
        XCTAssertFalse(model.isSearchPending)

        // And the search starting — here by the Search key, through the same
        // `runSearch` the timer calls. This also leaves no timer behind.
        model.query = "light"
        XCTAssertTrue(model.isSearchPending)
        model.searchNow()
        XCTAssertFalse(model.isSearchPending)
        XCTAssertTrue(model.isSearching)

        // An index that is not built owes no search.
        let unbuilt = makeModel(indexIsBuilt: false)
        unbuilt.query = "beginning"
        XCTAssertFalse(unbuilt.isSearchPending)
        XCTAssertFalse(unbuilt.isSearching)
    }

    /// An Exact search highlights the phrase the query ran, not the field text.
    ///
    /// `PSSearchQuery.fts5Expression` trims the input and strips one pair of
    /// surrounding quotes before it builds the phrase. The highlight term was
    /// the field text as typed, and both highlighters — the result row and the
    /// reader — match it literally. So "Jesus wept " (the trailing space the
    /// keyboard's predictive bar leaves) or a phrase typed in quotes found its
    /// verses and marked nothing, in the row and in the opened chapter alike.
    @MainActor
    func testExactSearchHighlightsThePhraseTheQueryRan() {
        func terms(_ query: String) -> [String] {
            SearchModel.highlightTerms(
                query: query,
                matchType: .ExactSearch,
                strongs: false
            )
        }
        func expression(_ query: String) -> String? {
            PSSearchQuery.fts5Expression(
                fromUserInput: query,
                matchType: .ExactSearch,
                fuzzy: false,
                strongs: false
            )
        }

        XCTAssertEqual(terms("Jesus wept"), ["Jesus wept"])
        XCTAssertEqual(terms("Jesus wept "), ["Jesus wept"])
        XCTAssertEqual(terms(" Jesus wept"), ["Jesus wept"])
        XCTAssertEqual(terms("\"Jesus wept\""), ["Jesus wept"])
        // A space left inside the quotes: the tokenizer ignores it, so the term
        // must too.
        XCTAssertEqual(terms(" \"in the beginning \" "), ["in the beginning"])
        // Nothing left to mark.
        XCTAssertEqual(terms("\"\""), [])
        XCTAssertEqual(terms(" a "), [])

        // The builder's side of the same rule, so the two cannot drift apart
        // unnoticed: each of these inputs runs as the one phrase.
        for query in ["Jesus wept", "Jesus wept ", " Jesus wept", "\"Jesus wept\""] {
            XCTAssertEqual(
                expression(query),
                "text_norm:\"jesus wept\"",
                "query \(query.debugDescription)"
            )
        }
    }

    /// A quoted phrase in All or Any mode highlights the phrase the query ran,
    /// without a space left inside its quotes.
    ///
    /// The Exact arm's rule (`testExactSearchHighlightsThePhraseTheQueryRan`),
    /// for the scanner's quoted-phrase branch. The builder trims the input and
    /// the tokenizer ignores a space at either end of a phrase, so `"Jesus wept `
    /// — the quote not closed yet, with the trailing space the keyboard's
    /// predictive bar leaves — finds John 11:35. Both highlighters match the
    /// term literally, and "Jesus wept " is not in "Jesus wept.": the verse was
    /// listed and marked nowhere, in the row or in the chapter it opened.
    @MainActor
    func testAQuotedPhraseHighlightsWithoutTheSpacesInsideItsQuotes() {
        func terms(
            _ query: String,
            _ matchType: PSSearchType = .AndSearch
        ) -> [String] {
            SearchModel.highlightTerms(
                query: query,
                matchType: matchType,
                strongs: false
            )
        }

        // Unclosed, with the predictive bar's trailing space.
        XCTAssertEqual(terms("\"Jesus wept "), ["Jesus wept"])
        XCTAssertEqual(terms("\u{201C}Jesus wept "), ["Jesus wept"])
        // Closed, with a space inside the quotes at either end.
        XCTAssertEqual(terms("\"Jesus wept \""), ["Jesus wept"])
        XCTAssertEqual(terms("\" Jesus wept\""), ["Jesus wept"])
        XCTAssertEqual(terms("\"Jesus wept \"", .OrSearch), ["Jesus wept"])
        // Among other words, which are untouched.
        XCTAssertEqual(
            terms("\" in the beginning \" God"),
            ["in the beginning", "God"]
        )
        // Nothing left to mark: under two units after the trim, dropped like
        // any other single character.
        XCTAssertEqual(terms("\" a \""), [])
        XCTAssertEqual(terms("\"  \""), [])
        // A phrase with no stray space is the term it always was.
        XCTAssertEqual(terms("love \"the world\" a"), ["love", "the world"])

        // The builder's side of the same rule: the unclosed phrase runs
        // without the trailing space.
        XCTAssertEqual(
            PSSearchQuery.fts5Expression(
                fromUserInput: "\"Jesus wept ",
                matchType: .AndSearch,
                fuzzy: false,
                strongs: false
            ),
            "text_norm:\"jesus wept\""
        )

        // What the rule is for: the reader marks the phrase in the verse the
        // query found.
        var style = ChapterTextRenderer.Style(
            fontName: "Georgia", fontSize: 20, lineSpacingMultiple: 1.4
        )
        style.highlightTerms = terms("\"Jesus wept ")
        let verse = ChapterTextRenderer.text(
            for: ChapterVerse(number: 35, runs: [InlineRun(text: "Jesus wept.")]),
            style: style
        )
        var jacketed = ""
        for run in verse.runs where run.backgroundColor != nil {
            jacketed += String(verse[run.range].characters)
        }
        XCTAssertEqual(jacketed, "Jesus wept")
    }

    /// A phrase in typographic quotes is highlighted as a phrase, and the quotes
    /// stay in the field.
    ///
    /// Smart Punctuation turns a typed " into “ or ” wherever it is in effect,
    /// and pasted text carries them regardless. The highlight scanner knew only
    /// the straight quote, so the curly ones became part of the first and last
    /// words — terms that occur nowhere in the text — and an Exact search's
    /// term kept them at both ends.
    ///
    /// The straightening is local to the query and the highlight: what the user
    /// typed is still what the field shows and what the history saves.
    @MainActor
    func testTypographicQuotesHighlightThePhrase() {
        func terms(_ query: String, _ matchType: PSSearchType) -> [String] {
            SearchModel.highlightTerms(
                query: query,
                matchType: matchType,
                strongs: false
            )
        }
        let curly = "\u{201C}in the beginning\u{201D}"

        XCTAssertEqual(terms(curly, .AndSearch), ["in the beginning"])
        XCTAssertEqual(terms(curly, .OrSearch), ["in the beginning"])
        XCTAssertEqual(terms(curly, .ExactSearch), ["in the beginning"])
        XCTAssertEqual(
            terms("God \u{201C}the world\u{201D} loved", .AndSearch),
            ["God", "the world", "loved"]
        )
        // The low and reversed forms other keyboards open a quotation with.
        XCTAssertEqual(
            terms("\u{201E}the world\u{201F}", .AndSearch),
            ["the world"]
        )

        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, _, _, _, _ in [] }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.query = curly

        XCTAssertEqual(model.expression, "text_norm:\"in the beginning\"")
        XCTAssertEqual(model.highlightTerms, ["in the beginning"])
        XCTAssertEqual(model.query, curly)
        XCTAssertEqual(model.historyItem()?.searchTermToDisplay, curly)
    }

    /// A term with "ae" in it also highlights the æ spelling, and the other way
    /// round.
    ///
    /// The KJV prints Cæsar, Judæa and a dozen other names with the ligature,
    /// and the query finds them from a typed "ae". Both highlighters — the
    /// result row and the reader — match a term literally, and "Caesar" does
    /// not occur in "Render therefore unto Cæsar". So the list carries both
    /// spellings, or the verses the search found would be marked nowhere.
    @MainActor
    func testAnAeTermAlsoHighlightsItsLigatureSpelling() {
        func terms(
            _ query: String,
            _ matchType: PSSearchType = .AndSearch
        ) -> [String] {
            SearchModel.highlightTerms(
                query: query,
                matchType: matchType,
                strongs: false
            )
        }

        XCTAssertEqual(terms("Caesar"), ["Caesar", "C\u{00E6}sar"])
        XCTAssertEqual(
            terms("render unto Caesar", .OrSearch),
            ["render", "unto", "Caesar", "C\u{00E6}sar"]
        )
        XCTAssertEqual(
            terms("\"unto Caesar\" tribute"),
            ["unto Caesar", "unto C\u{00E6}sar", "tribute"]
        )
        XCTAssertEqual(
            terms("unto Caesar ", .ExactSearch),
            ["unto Caesar", "unto C\u{00E6}sar"]
        )
        // Typed with the ligature, or pasted from a verse.
        XCTAssertEqual(terms("C\u{00E6}sar"), ["C\u{00E6}sar", "Caesar"])
        // The ligature on its own is one-character noise, dropped like any
        // other single character: it would mark the æ inside every such word.
        XCTAssertEqual(terms("ae"), ["ae"])
        // Terms without an "ae" are the list they always were.
        XCTAssertEqual(terms("God so loved"), ["God", "so", "loved"])
        XCTAssertEqual(terms("God so loved", .ExactSearch), ["God so loved"])

        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in true },
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, _, _, _, _ in [] }
        )
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        model.query = "Caesar"

        // The query and the highlight agree on the spellings.
        XCTAssertEqual(
            model.expression,
            "(text_norm:\"caesar\" OR text_norm:\"c\u{00E6}sar\")"
        )
        XCTAssertEqual(model.highlightTerms, ["Caesar", "C\u{00E6}sar"])
    }

    /// A search that matches more verses than the list holds is cut at the cap,
    /// and says it was cut.
    ///
    /// The list has always stopped at 1,000 rows, in canonical order, so the cut
    /// takes the end of the Bible. The header gave the cap as the count: "God"
    /// is in 3,892 verses, and the list read as 1,000 results ending at
    /// 1 Kings 15:3, with nothing to say the New Testament was missing or that a
    /// narrower scope would show it. The query now asks for one row past the
    /// cap; `setResults` drops that row and records that it was there.
    @MainActor
    func testResultsPastTheCapAreCutAndReportedAsTruncated() throws {
        func rows(_ count: Int) -> [PSSearchResult] {
            (0..<count).map {
                PSSearchResult(reference: "Ref \($0)", fullText: "t")
            }
        }
        // No index, so nothing here can start a search: every row arrives
        // through `setResults`, as it does from a finished query.
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in false },
                buildOperation: { _, _ in }
            ),
            featureProvider: { _, _ in false },
            queryOperation: { _, _, _, _, _ in [] }
        )
        let kjv = SearchModuleChoice(id: "KJV", kind: .bible)
        model.configure(
            modules: [kjv],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )

        XCTAssertEqual(SearchModel.resultLimit, 1000)

        // The row past the cap is the query's evidence of more. It is dropped,
        // and the list is marked.
        model.setResults(rows(1001))
        XCTAssertEqual(model.results.count, 1000)
        XCTAssertEqual(model.results.last?.reference, "Ref 999")
        XCTAssertTrue(model.resultsWereTruncated)

        // Exactly the cap is every match there is.
        model.setResults(rows(1000))
        XCTAssertEqual(model.results.count, 1000)
        XCTAssertEqual(model.results.last?.reference, "Ref 999")
        XCTAssertFalse(model.resultsWereTruncated)

        // The mark describes the rows on screen, so it goes when they do:
        // cleared results, ...
        model.setResults(rows(1001))
        model.clearResults()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.resultsWereTruncated)

        // ... an emptied field, ...
        model.query = "God"
        model.setResults(rows(1001))
        model.query = ""
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.resultsWereTruncated)

        // ... and a saved search put back, which holds its rows and no record
        // of whether they were cut.
        let saved = try XCTUnwrap(
            PSSearchHistoryItem(
                searchTermToDisplay: "God",
                strongs: false,
                fuzzy: false,
                type: .AndSearch,
                range: .AllRange,
                book: nil
            )
        )
        saved.results = [
            PSVerseTextEntry(key: "Genesis 1:1", text: "In the beginning God"),
        ]
        model.setResults(rows(1001))
        model.configure(
            modules: [kjv],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: saved
        )
        XCTAssertEqual(model.results.map(\.reference), ["Genesis 1:1"])
        XCTAssertFalse(model.resultsWereTruncated)
    }

    /// The Settings-bundle reset is handled on activation only once launch
    /// preparation has finished.
    ///
    /// `reset_PocketSword` is flipped in the Settings app, so it can be waiting
    /// at a cold launch as well as on a return from the background. At a cold
    /// launch `LaunchCoordinator.prepare()` handles it, off the main actor. The
    /// activation handler read the same flag with no readiness check, so an
    /// activation arriving during preparation would run the reset a second
    /// time, on the main thread, alongside the first — the one main-thread path
    /// that could first-touch `PSModuleController` before `prepare()` had
    /// returned. From the `.ready` transition (`replayPendingURL()`) on, the
    /// handler is the only reader of the flag, as it always was on a warm
    /// return.
    @MainActor
    func testActivationResetWaitsForLaunchPreparation() {
        defaults.set(true, forKey: "reset_PocketSword")
        let session = AppSession(
            settings: SettingsModel(store: SettingsStore(defaults: defaults)),
            library: LibraryModel(
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
            ),
            readingStore: ReadingStateStore(defaults: defaults)
        )
        var resets = 0

        // Launch preparation is still running: the flag is `prepare()`'s.
        session.resetOnActivationIfRequested(defaults: defaults) { resets += 1 }
        XCTAssertEqual(
            resets,
            0,
            "An activation during launch preparation ran the reset itself."
        )

        // The `.ready` transition. The stand-in reset leaves the flag set, as a
        // flag flipped while the app was suspended would be.
        session.replayPendingURL()
        session.resetOnActivationIfRequested(defaults: defaults) { resets += 1 }
        XCTAssertEqual(resets, 1)

        // The real reset clears the flag, and without it an activation resets
        // nothing.
        defaults.removeObject(forKey: "reset_PocketSword")
        session.resetOnActivationIfRequested(defaults: defaults) { resets += 1 }
        XCTAssertEqual(resets, 1)
    }

    /// Search re-checks its index when the app becomes active.
    ///
    /// A foreground build that dies with the app is finished later by a
    /// background task (`SearchIndexBackgroundManager`), which can run inside
    /// this process while it is suspended and reports to no one. A Search
    /// workspace left on "No Search Index Installed" kept saying so over the
    /// finished index — nothing looked again short of a module switch or a
    /// relaunch — and its Build button dropped that index and spent tens of
    /// seconds rebuilding it. `indexMayHaveChanged()` is the activation hook:
    /// it adopts the index and runs the query left waiting in the field.
    ///
    /// Two things it must NOT do are pinned with it. Before `configure(...)`
    /// there is no module and nothing is asked: the first activation can
    /// arrive during launch preparation, when the engine is off limits. And a
    /// build still running is not asked either: coming back to the app is when
    /// the system expires a background build, and the engine would be queried
    /// on the main thread about a connection that build is about to close.
    @MainActor
    func testSearchAdoptsAnIndexBuiltOutsideTheWorkspace() async {
        // What the engine would answer, and how often it was asked.
        var fresh = false
        var freshnessChecks = 0
        let buildGate = SearchIndexBuildGate()
        let collector = ExpressionCollector()
        let model = SearchModel(
            optionsStore: SearchOptionsStore(defaults: defaults),
            indexCoordinator: SearchIndexCoordinator(
                freshnessProvider: { _ in
                    freshnessChecks += 1
                    return fresh
                },
                buildGate: buildGate,
                buildOperation: { _, _ in }
            ),
            debounceInterval: 0,
            featureProvider: { _, _ in true },
            queryOperation: { _, expression, _, _, _ in
                collector.record(expression)
                return []
            }
        )

        // An activation before `configure(...)`: no module, nothing asked.
        model.indexMayHaveChanged()
        XCTAssertEqual(freshnessChecks, 0)
        XCTAssertEqual(model.indexCoordinator.state, .unavailable)

        // Search opens on the build prompt, and a query typed there waits.
        model.configure(
            modules: [SearchModuleChoice(id: "KJV", kind: .bible)],
            preferredModule: "KJV",
            currentBookName: "Genesis",
            restoring: nil
        )
        XCTAssertEqual(model.indexCoordinator.state, .unavailable)
        XCTAssertEqual(freshnessChecks, 1)
        model.query = "love"
        XCTAssertTrue(collector.snapshot().isEmpty)

        // The background recovery build, through the gate it shares with the
        // coordinator, held open mid-build.
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        let backgroundStarted = expectation(description: "Background build started")
        let backgroundFinished = expectation(description: "Background build finished")
        let releaseBackground = DispatchSemaphore(value: 0)
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
                backgroundStarted.fulfill()
                releaseBackground.wait()
            }
        )
        manager.performPendingBuild(cancellationRequested: { false }) { _, _ in
            backgroundFinished.fulfill()
        }
        await fulfillment(of: [backgroundStarted], timeout: 2)

        // An activation while it is still running leaves the engine alone.
        model.indexMayHaveChanged()
        XCTAssertEqual(
            freshnessChecks,
            1,
            "The engine was asked about an index a build was still writing."
        )
        XCTAssertEqual(model.indexCoordinator.state, .unavailable)

        // The build finishes after that activation: the index is fresh, nothing
        // has told Search, and the look that was skipped is not repeated. The
        // build prompt stays up over it — the gap `indexMayHaveChanged`
        // documents and leaves.
        releaseBackground.signal()
        await fulfillment(of: [backgroundFinished], timeout: 2)
        fresh = true
        XCTAssertEqual(model.indexCoordinator.state, .unavailable)
        XCTAssertTrue(collector.snapshot().isEmpty)

        // The next activation, whenever it comes, adopts it and runs the waiting
        // query.
        model.indexMayHaveChanged()
        XCTAssertEqual(
            model.indexCoordinator.state,
            .ready,
            "Search kept the build prompt over an index built in the background."
        )
        await collector.wait(forCount: 1, in: self)
        XCTAssertEqual(collector.snapshot().count, 1)
        XCTAssertTrue(collector.snapshot().first?.contains("love") ?? false)

        // A later activation finds nothing new and runs nothing.
        model.indexMayHaveChanged()
        XCTAssertEqual(model.indexCoordinator.state, .ready)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            collector.snapshot().count,
            1,
            "An activation with nothing changed re-ran the query on screen."
        )

        // An index that has gone missing becomes the build prompt again, rather
        // than a ready state that answers every query with nothing.
        fresh = false
        model.indexMayHaveChanged()
        XCTAssertEqual(model.indexCoordinator.state, .unavailable)
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
    /// with both an error and the cancellation flag set. Billing the error first would
    /// spend retry budget on work that was merely interrupted — which is why the expiry
    /// arm comes before the failure arm and reports `shouldRetry: true` with the record
    /// intact.
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

    /// A background build that RETURNED has built the index, even if its task
    /// expired on the way out.
    ///
    /// `PSSearchEngine.build` can only see a cancel at its 500-row progress
    /// poll. After the last one (row 31,000 of the KJV's 31,102) the remaining
    /// inserts, the COMMIT and the meta stamp cannot be stopped, so an expiry
    /// that lands there leaves a complete, stamped index and a build that
    /// returns normally with the flag set. Classified by the flag first, that
    /// was reported as an interrupted run: the recovery record stayed, the
    /// request was resubmitted, and the next background slot opened with
    /// `dropIndex()` on the finished index.
    ///
    /// So the order is success, then expiry, then failure. The flag is raised
    /// inside the operation, as it is on a device, rather than passed as
    /// `{ true }`: a build that was never allowed to start is not what this
    /// pins.
    func testBackgroundBuildThatFinishesAfterExpiryCountsAsBuilt() {
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        let flagLock = NSLock()
        var expired = false
        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: SearchIndexBackgroundManager.Scheduler(
                register: { _, _ in true },
                submit: { _, completion in completion(nil) },
                cancel: { _ in }
            ),
            buildGate: SearchIndexBuildGate(),
            buildOperation: { _, progress in
                // The engine's last poll finds nothing to stop for ...
                var cancel = false
                progress?(0.99, &cancel)
                XCTAssertFalse(cancel)
                // ... and the task expires after it, in the tail.
                flagLock.withLock { expired = true }
            }
        )

        let done = expectation(description: "late expiry")
        manager.performPendingBuild(
            cancellationRequested: { flagLock.withLock { expired } }
        ) { success, shouldRetry in
            XCTAssertTrue(
                success,
                "a build that returned has committed its index"
            )
            XCTAssertFalse(
                shouldRetry,
                "a retry would open with dropIndex() on the finished index"
            )
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertNil(
            defaults.string(forKey: Defaults.pendingSearchIndexModule),
            "nothing is left to recover"
        )
        XCTAssertEqual(
            defaults.integer(forKey: Defaults.pendingSearchIndexAttempts), 0
        )
    }

    /// A background build that finishes just as the user starts their own build
    /// of the same module leaves the recovery record alone.
    ///
    /// `beginForegroundBuild` writes the record for the build the user asked
    /// for and tells the background one to stop. Landing in the background
    /// build's tail, that stops nothing: the build returns, and counts as
    /// built. But the record is no longer its to clear. The foreground build is
    /// waiting at the gate, opens with `dropIndex()`, and needs the record if
    /// the app is killed before it finishes. Without the `foregroundModule`
    /// check the success arm clears it.
    func testALateBackgroundBuildLeavesTheRecordOfAForegroundBuild() {
        defaults.set("KJV", forKey: Defaults.pendingSearchIndexModule)
        let flagLock = NSLock()
        var cancelled = false
        // The operation needs the manager it belongs to; cleared at the end so
        // the two do not keep each other alive.
        var foreground: SearchIndexBackgroundManager?
        let manager = SearchIndexBackgroundManager(
            defaults: defaults,
            taskIdentifier: "test.search-index",
            scheduler: SearchIndexBackgroundManager.Scheduler(
                register: { _, _ in true },
                submit: { _, completion in completion(nil) },
                cancel: { _ in }
            ),
            buildGate: SearchIndexBuildGate(),
            buildOperation: { module, _ in
                // Build is tapped in the tail: the record is rewritten for the
                // foreground build and this one is told to stop, too late.
                foreground?.beginForegroundBuild(module: module)
                flagLock.withLock { cancelled = true }
            }
        )
        foreground = manager
        defer { foreground = nil }

        let done = expectation(description: "late background build")
        manager.performPendingBuild(
            cancellationRequested: { flagLock.withLock { cancelled } }
        ) { success, shouldRetry in
            XCTAssertTrue(success)
            XCTAssertFalse(shouldRetry)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(
            defaults.string(forKey: Defaults.pendingSearchIndexModule), "KJV",
            "the record belongs to the foreground build now"
        )

        // ... which clears it when it finishes.
        manager.finishForegroundBuild(module: "KJV")
        XCTAssertNil(
            defaults.string(forKey: Defaults.pendingSearchIndexModule)
        )
    }

    /// A foreground build that RETURNED is ready, even if Cancel was tapped on
    /// its way out.
    ///
    /// The Cancel button is up for the whole build and the engine stops only at
    /// a progress poll, so a tap in the tail cancels nothing: the index is
    /// committed and stamped. Classified by the flag first, the coordinator
    /// said `.cancelled` — no search ran, and the screen offered only "Build
    /// Index", which drops the finished index and spends another ~30 s
    /// rebuilding it. Nothing re-reads freshness until a relaunch or a module
    /// switch.
    @MainActor
    func testAnIndexBuildThatFinishesAfterALateCancelIsReady() async {
        let outcome = await outcomeOfAnIndexBuildCancelledMidFlight(
            endingWith: nil
        )

        XCTAssertEqual(outcome.state, .ready)
        XCTAssertEqual(outcome.success, true)
        XCTAssertEqual(outcome.cancelled, false)
    }

    /// The companion: a cancel the build DID see still ends cancelled.
    ///
    /// `PSSearchEngine.build` rolls back, drops the partial index and throws
    /// `.cancelled`, which arrives with the flag set. That throw, not the flag,
    /// is what makes a build cancelled.
    @MainActor
    func testAnIndexBuildThatStopsForACancelIsCancelled() async {
        let outcome = await outcomeOfAnIndexBuildCancelledMidFlight(
            endingWith: PSSearchEngineError.cancelled
        )

        XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertEqual(outcome.success, false)
        XCTAssertEqual(outcome.cancelled, true)
    }

    /// Starts a foreground build, cancels it while the operation is running,
    /// then lets the operation end: by returning, or by throwing `error`.
    @MainActor
    private func outcomeOfAnIndexBuildCancelledMidFlight(
        endingWith error: Error?
    ) async -> (state: SearchIndexState, success: Bool?, cancelled: Bool?) {
        let started = expectation(description: "Index build started")
        let completed = expectation(description: "Index build completed")
        let release = DispatchSemaphore(value: 0)
        let coordinator = SearchIndexCoordinator(
            freshnessProvider: { _ in false },
            buildGate: SearchIndexBuildGate(),
            buildOperation: { _, _ in
                started.fulfill()
                release.wait()
                if let error {
                    throw error
                }
            }
        )
        var success: Bool?
        var cancelled: Bool?
        coordinator.onCompletion = {
            success = $0
            cancelled = $1
            completed.fulfill()
        }

        coordinator.build(module: "KJV")
        await fulfillment(of: [started], timeout: 2)
        coordinator.cancel()
        XCTAssertEqual(coordinator.state, .cancelling)

        release.signal()
        await fulfillment(of: [completed], timeout: 2)

        return (coordinator.state, success, cancelled)
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

    /// Renders ten one-line verses through the reader's own text renderer and asks
    /// the store for the verse at the middle of each line.
    ///
    /// The test above hands the store text-view coordinates directly; this pins
    /// that the RENDERER records them in that space. With a line's origin added to
    /// bounds that already include it, every fragment sat at about twice its real y
    /// and this read `[1, 1, 2, 2, 3, 3, 4, 4, 5, 5]`: the toolbar title and
    /// `bibleVersePosition` moved through a flowing paragraph at half speed and
    /// never reached its second half.
    @MainActor
    func testVerseTrackingRendererRecordsFragmentsInTextViewCoordinates() throws {
        var text = Text("")
        for verse in 1...10 {
            let piece = Text(verbatim: verse == 10 ? "Verse \(verse)" : "Verse \(verse)\n")
                .customAttribute(VerseTextAttribute(verse: verse))
            text = Text("\(text)\(piece)")
        }
        let store = VerseLayoutStore()
        let renderer = ImageRenderer(
            content: text
                .font(.system(size: 20))
                .textRenderer(VerseTrackingTextRenderer(layoutStore: store))
                .frame(width: 300, alignment: .leading)
        )
        renderer.scale = 1
        let height = try XCTUnwrap(renderer.uiImage).size.height

        XCTAssertEqual(
            (0..<10).map {
                store.verse(at: height * (CGFloat($0) + 0.5) / 10, fallback: 0)
            },
            Array(1...10)
        )
    }

    /// Scrolls a flowing paragraph past the top half a point at a time and collects
    /// every change of verse the tracker reports: 1 to 12, each once, in order.
    ///
    /// The text is built the way `ParagraphRow` builds it — superscript label, body,
    /// verse attribute, the reader's line spacing — because the label is what made
    /// the tracker step backwards. A label's own bounds start about 2 pt above the
    /// body text's, so with each fragment at its run's height the gap above a line
    /// holding the tail of verse N-1 and the start of verse N read N, and the line
    /// itself read N-1 again: one backward step of the title, and two defaults
    /// writes, per verse. Correcting the fragments' position alone doubles those
    /// steps, which is why this is pinned beside the test above.
    @MainActor
    func testFlowingVerseTrackerNeverStepsBackwards() throws {
        let style = ChapterTextRenderer.Style(
            fontName: "Georgia", fontSize: 20, lineSpacingMultiple: 1.4
        )
        var text = Text("")
        for verse in 1...12 {
            var attributed = ChapterTextRenderer.verseLabel(verse, style: style)
            attributed += ChapterTextRenderer.attributed(
                runs: [
                    InlineRun(
                        text: "In the beginning God created the heaven and the earth "
                            + "and so on and so forth for a while. "
                    ),
                ],
                style: style
            )
            let piece = Text(attributed)
                .customAttribute(VerseTextAttribute(verse: verse))
            text = Text("\(text)\(piece)")
        }
        let store = VerseLayoutStore()
        let renderer = ImageRenderer(
            content: text
                .lineSpacing(style.fontSize * (style.lineSpacingMultiple - 1))
                .textRenderer(VerseTrackingTextRenderer(layoutStore: store))
                .frame(width: 360, alignment: .leading)
        )
        renderer.scale = 1
        let height = try XCTUnwrap(renderer.uiImage).size.height

        // Each element is one retitle on the way down the paragraph.
        var reported: [Int] = []
        for offset in stride(from: CGFloat(0), to: height, by: 0.5) {
            let verse = store.verse(at: offset, fallback: 0)
            if verse != reported.last { reported.append(verse) }
        }
        XCTAssertEqual(reported, Array(1...12))
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
                ReaderScrollSample(offset: 0, contentHeight: 0, containerHeight: 0),
                from: pane.scrollSurface
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "500",
                "A scroll view with no content has not reported a position; "
                    + "persisting its zero is what destroyed the saved offset."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 0, contentHeight: 2138, containerHeight: 675),
                from: pane.scrollSurface
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "500",
                "Laid out, but the restore has not landed — every offset published "
                    + "between the request and the landing is where the view WAS."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 500, contentHeight: 2138, containerHeight: 675),
                from: pane.scrollSurface
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "500",
                "Landed: the key already holds the target, so there is nothing to write."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 700, contentHeight: 2138, containerHeight: 675),
                from: pane.scrollSurface
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
                ReaderScrollSample(offset: 1463, contentHeight: 2138, containerHeight: 675),
                from: pane.scrollSurface
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "1463",
                "Pinned at contentHeight - containerHeight: the target is unreachable, "
                    + "so the truth is what should be persisted."
            )

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 1200, contentHeight: 2138, containerHeight: 675),
                from: pane.scrollSurface
            )
            XCTAssertEqual(
                standard.string(forKey: scrollKey), "1200",
                "Having given up on the target, normal persistence must resume."
            )
        }
    }

    /// Picking the top of the chapter already open persists it.
    ///
    /// A verse scroll resets what the pane believes — offset 0, that verse — and
    /// leaves the saving to the view's report of where it landed. The chapter's
    /// first row lands on exactly those values, so neither report reads as a
    /// change, and the keys kept the position the reader had just LEFT: a display
    /// toggle, a bookmark or a relaunch went back there.
    ///
    /// Jude, because verse 1 is its first row whatever the host's Headings
    /// setting. With Headings off (the default) that is true of every chapter: a
    /// Bible intro with nothing to show gets no row. With Headings on, 1,184 of
    /// the KJV's 1,189 chapters open with an intro row that is only its heading
    /// (`CHAPTER n.`) above verse 1, which puts verse 1 a line down, where its
    /// landing is seen; the five without one are the one-chapter books. With
    /// Verse Per Line off the first PARAGRAPH is the first row in every chapter.
    @MainActor
    func testPickingTheTopOfTheOpenChapterPersistsIt() {
        withPreservedReadingKeys { standard in
            standard.set("Jude 1", forKey: Defaults.lastRef)
            standard.set("1", forKey: Defaults.bibleVersePosition)
            let workspace = ReadingWorkspaceModel()
            workspace.displayChapter("Jude 1", polling: .bible, restore: .verse)
            let pane = workspace.bible
            XCTAssertEqual(pane.document.verses.first?.number, 1,
                           "Jude no longer opens on verse 1; this needs another chapter.")

            // Reading at verse 20...
            let surface = pane.scrollSurface
            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 1500, contentHeight: 3000, containerHeight: 675),
                from: surface
            )
            pane.topmostVerseChanged(20, from: surface)
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "20")
            XCTAssertEqual(standard.string(forKey: "bibleScrollPosition"), "1500")

            // ...the reader picks Jude 1:1, and the view reports the landing.
            workspace.selectReference(bookName: "Jude", chapter: 1, verse: 1)
            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 0, contentHeight: 3000, containerHeight: 675),
                from: surface
            )
            pane.topmostVerseChanged(1, from: surface)

            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "1",
                           "A display toggle would jump back to the verse being left.")
            XCTAssertEqual(standard.string(forKey: "bibleScrollPosition"), "0",
                           "A bookmark or a relaunch would restore the offset being left.")
        }
    }

    /// An offset restore names no verse, so a scroll persisted after it lands
    /// keeps the verse the keys already pair with that offset.
    ///
    /// A pane that has shown nothing believes it is at verse 1, and the launch
    /// restore is always an offset. The first offset saved once it had landed —
    /// the rows settling a few points is enough — wrote that 1 over the saved
    /// verse and retitled to `…:1`, with the reader correctly mid-chapter, until
    /// a different row reached the top. A display toggle or a font change in
    /// that window (a `.verse` restore) jumped to verse 1.
    ///
    /// The first assertion is why the saved verse is carried BESIDE what the
    /// pane believes and not written into it: the row at the top before the
    /// scroll lands reports verse 1, and is dropped only because the pane
    /// already believes that.
    @MainActor
    func testAnOffsetRestoreKeepsTheSavedVerseUntilTheViewReportsOne() {
        withPreservedPanePositionKeys { standard, scrollKey in
            let sample = { (y: CGFloat) in
                ReaderScrollSample(offset: y, contentHeight: 5000, containerHeight: 675)
            }
            standard.set("1500", forKey: scrollKey)
            standard.set("16", forKey: Defaults.bibleVersePosition)
            let pane = ReaderPaneModel(mode: .bible)
            pane.pendingRestore = .offset(1500)
            pane.applyPendingWork()
            let surface = pane.scrollSurface

            pane.topmostVerseChanged(1, from: surface)
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "16",
                           "The row at the top before the restore landed was "
                               + "persisted as the reader's verse.")

            // Landed, and then the rows settle four points.
            pane.scrollOffsetChanged(sample(1500), from: surface)
            pane.scrollOffsetChanged(sample(1504), from: surface)
            XCTAssertEqual(standard.string(forKey: scrollKey), "1504")
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "16",
                           "A scroll after the restore landed overwrote the saved "
                               + "verse with the one a new pane starts on.")

            // The view's own report takes over from there.
            pane.topmostVerseChanged(17, from: surface)
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "17")
            pane.scrollOffsetChanged(sample(1600), from: surface)
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "17",
                           "The saved verse came back after the view had reported one.")
        }
    }

    /// `ReaderScreen`'s size hook — the two calls, back to back — and then the
    /// hop the pane defers its scroll to.
    @MainActor
    private func sizeChange(_ pane: ReaderPaneModel, widthChanged: Bool) async {
        pane.prepareForSizeChange()
        pane.restoreAfterSizeChange(widthChanged: widthChanged)
        for _ in 0..<10 { await Task.yield() }
    }

    /// What `pane`'s scroll position was last told, as a row: the row's id after
    /// a `scrollTo(id:)`, nil after a `scrollTo(y:)`. `ScrollPosition` is a value,
    /// so this needs no scroll view.
    @MainActor
    private func targetRow(of pane: ReaderPaneModel) -> Int? {
        pane.scrollPosition.viewID(type: Int.self)
    }

    /// A rotation re-anchors on the verse being read. It does not replay the
    /// offset the old width was scrolled to.
    ///
    /// A width change re-wraps every row, so a pixel offset names different text.
    /// Genesis 1 with Verse Per Line on is 4198 pt tall in portrait and verse 20
    /// sits near 2700; in landscape the rows are about half as tall and 2700 is
    /// past the end of the chapter. The reader was pinned there, that was saved
    /// as the position, and rotating back replayed IT into the portrait layout.
    ///
    /// The offset is still what is replayed wherever it names the same text or
    /// there is no verse to go by. Each of those is pinned here too, because the
    /// change is wrong if it reaches any of them:
    ///
    ///  * a HEIGHT-only change — the bars settling at launch, the keyboard —
    ///    which re-wraps nothing, and where the verse would snap a row scrolled
    ///    part-way to its top;
    ///  * the flowing layout, whose row is a paragraph and not the verse;
    ///  * a verse nobody has measured: after an offset restore the pane goes on
    ///    believing what it did before — verse 1, at every launch — until the
    ///    view reports the row at the top;
    ///  * a pane that owes a render, which is holding a chapter the reader has
    ///    left, under position keys already settled for the next one.
    ///
    /// This is the model's half. Where a scroll view lands after a real rotation
    /// is a simulator check.
    @MainActor
    func testAWidthChangeReanchorsOnTheTopmostVerseInsteadOfReplayingPixels() async {
        let standard = UserDefaults.standard
        let scrollKey = "bibleScrollPosition"
        let verseKey = Defaults.bibleVersePosition
        // By hand: `withPreservedPanePositionKeys` takes a synchronous closure.
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
        let chapter = ChapterDocument(verses: (1...31).map { ChapterVerse(number: $0) })
        let portrait = { (y: CGFloat) in
            ReaderScrollSample(offset: y, contentHeight: 4198, containerHeight: 675)
        }
        let landscape = { (y: CGFloat) in
            ReaderScrollSample(offset: y, contentHeight: 2400, containerHeight: 340)
        }

        // Reading at verse 20 in portrait, having scrolled there.
        let pane = ReaderPaneModel(mode: .bible)
        pane.versePerLine = true
        pane.document = chapter
        let surface = pane.scrollSurface
        pane.scrollOffsetChanged(portrait(2700), from: surface)
        pane.topmostVerseChanged(20, from: surface)

        await sizeChange(pane, widthChanged: true)
        XCTAssertEqual(targetRow(of: pane), 20,
                       "Rotating replayed portrait's offset into the landscape "
                           + "layout, where it is past the end of the chapter.")

        // A rotation's size arrives in steps, as the launch's does: the bars
        // settle after the width has changed. Everything published in between is
        // suppressed, so the only offset the pane holds is still portrait's.
        await sizeChange(pane, widthChanged: false)
        XCTAssertEqual(targetRow(of: pane), 20,
                       "The bars settling after the rotation replayed portrait's "
                           + "offset.")

        // Where it lands is the position now, under the same verse.
        pane.scrollOffsetChanged(landscape(1310), from: surface)
        XCTAssertEqual(standard.string(forKey: scrollKey), "1310")
        XCTAssertEqual(standard.string(forKey: verseKey), "20")

        // Height alone, at this width: the offset still names the same text.
        await sizeChange(pane, widthChanged: false)
        XCTAssertNil(targetRow(of: pane),
                     "A height change re-wraps nothing, and re-anchoring on the "
                         + "verse snaps a row scrolled part-way to its top.")

        // And back to portrait.
        await sizeChange(pane, widthChanged: true)
        XCTAssertEqual(targetRow(of: pane), 20,
                       "Rotating back replayed landscape's offset into the "
                           + "portrait layout.")

        // The flowing layout. Its row is the paragraph — one, here, whose id is
        // verse 1 — so the verse is not something it can be scrolled to.
        let prose = ReaderPaneModel(mode: .bible)
        prose.versePerLine = false
        prose.document = chapter
        prose.scrollOffsetChanged(portrait(2700), from: prose.scrollSurface)
        prose.topmostVerseChanged(20, from: prose.scrollSurface)
        await sizeChange(prose, widthChanged: true)
        XCTAssertNil(targetRow(of: prose),
                     "The flowing layout jumped to the first verse of the "
                         + "paragraph being read.")

        // An offset restore names no verse. The row at the top BEFORE it lands
        // reports itself, and that is no measurement: it is where the view was.
        standard.set("600", forKey: scrollKey)
        standard.set("9", forKey: verseKey)
        let restored = ReaderPaneModel(mode: .bible)
        restored.versePerLine = true
        restored.document = chapter
        restored.pendingRestore = .offset(600)
        restored.applyPendingWork()
        restored.topmostVerseChanged(1, from: restored.scrollSurface)
        restored.scrollOffsetChanged(portrait(600), from: restored.scrollSurface)
        await sizeChange(restored, widthChanged: true)
        XCTAssertNil(targetRow(of: restored),
                     "A reader restored mid-chapter was dragged to verse 1, the "
                         + "verse a pane that has shown nothing believes it is on.")

        // Once the view has said which row is at the top, that is the verse.
        restored.topmostVerseChanged(10, from: restored.scrollSurface)
        await sizeChange(restored, widthChanged: true)
        XCTAssertEqual(targetRow(of: restored), 10)

        // The row the restore lands ON may report before the landing itself is
        // published. It is told from the row that was at the top by changing
        // what the pane believes. The restore still wins until it has landed —
        // launch's own size changes arrive in that window.
        standard.set("600", forKey: scrollKey)
        standard.set("9", forKey: verseKey)
        let early = ReaderPaneModel(mode: .bible)
        early.versePerLine = true
        early.document = chapter
        early.pendingRestore = .offset(600)
        early.applyPendingWork()
        early.topmostVerseChanged(1, from: early.scrollSurface)
        early.topmostVerseChanged(9, from: early.scrollSurface)
        await sizeChange(early, widthChanged: true)
        XCTAssertNil(targetRow(of: early),
                     "A width change re-anchored over an offset restore that had "
                         + "not landed.")
        early.scrollOffsetChanged(portrait(600), from: early.scrollSurface)
        await sizeChange(early, widthChanged: true)
        XCTAssertEqual(targetRow(of: early), 9,
                       "The verse the restore landed on was not taken for a "
                           + "measurement because it was reported before the landing.")

        // A pane that owes a render: it has been paged past while hidden.
        let owing = ReaderPaneModel(mode: .bible)
        owing.versePerLine = true
        owing.document = chapter
        owing.scrollOffsetChanged(portrait(2700), from: owing.scrollSurface)
        owing.topmostVerseChanged(20, from: owing.scrollSurface)
        owing.deferRender(of: "Genesis 2", restore: .chapterStart)
        await sizeChange(owing, widthChanged: true)
        XCTAssertNil(targetRow(of: owing))
        owing.scrollOffsetChanged(portrait(2700), from: owing.scrollSurface)
        XCTAssertEqual(standard.string(forKey: scrollKey), "0",
                       "Re-anchoring the chapter being left moved its scroll view, "
                           + "and the landing was saved over the top of the next one.")
        XCTAssertEqual(standard.string(forKey: verseKey), "1")
    }

    // MARK: Paging

    /// Paging replaces the scroll view and persists the top of the new chapter.
    ///
    /// The persist is the half that is easy to lose. A scroll view that starts at
    /// the top publishes no offset change and no new topmost verse, so nothing
    /// else writes these keys — and they hold the position in the chapter being
    /// LEFT (`setToPreviousChapter` even writes the destination's last verse). Left
    /// alone, a relaunch restores the old offset in the new chapter and a display
    /// toggle jumps to the old verse.
    @MainActor
    func testPagingStartsANewScrollSurfaceAtThePersistedTopOfTheChapter() {
        withPreservedPanePositionKeys { standard, scrollKey in
            standard.set("2289", forKey: scrollKey)
            standard.set("31", forKey: Defaults.bibleVersePosition)
            let pane = ReaderPaneModel(mode: .bible)
            let surface = pane.scrollSurface

            pane.pendingRestore = .chapterStart
            pane.applyPendingWork()

            XCTAssertEqual(pane.scrollSurface, surface + 1,
                           "Paging kept the scroll view of the chapter being left.")
            XCTAssertEqual(standard.string(forKey: scrollKey), "0")
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "1")

            // Every other restore keeps its scroll view: replacing it on a display
            // toggle or a font change would flash and drop the scroll in flight.
            for restore: ReaderPaneModel.PaneRestore in [.none, .verse(3), .offset(120)] {
                pane.pendingRestore = restore
                pane.applyPendingWork()
            }
            XCTAssertEqual(pane.scrollSurface, surface + 1)
        }
    }

    /// `displayChapter`'s `.none` is paging, and paging is what asks for the new
    /// scroll surface — on the pane it renders now and on the one it defers into.
    @MainActor
    func testPagingDefersAChapterStartIntoTheOtherPane() {
        withPreservedReadingKeys { standard in
            let workspace = ReadingWorkspaceModel()
            let surface = workspace.bible.scrollSurface

            workspace.displayChapter("Genesis 2", polling: .bible, restore: .none)

            XCTAssertEqual(workspace.bible.scrollSurface, surface + 1)
            XCTAssertEqual(workspace.commentary.pendingRestore, .chapterStart)
            XCTAssertEqual(standard.string(forKey: "bibleScrollPosition"), "0")
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "1")
        }
    }

    /// Everything a page turn through the workspace writes: the reference and
    /// both panes' positions.
    private func withPreservedReadingKeys(_ body: (UserDefaults) -> Void) {
        let standard = UserDefaults.standard
        let keys = [Defaults.lastRef, Defaults.bibleVersePosition,
                    Defaults.commentaryVersePosition,
                    "bibleScrollPosition", "commentaryScrollPosition"]
        let saved = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value {
                    standard.set(value, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }
        body(standard)
    }

    /// The chapter the commentary pane renders for `ref`, built the way the pane
    /// builds it: what a test compares the pane's document against to say WHICH
    /// chapter it is showing.
    @MainActor
    private func commentaryChapter(_ ref: String) throws -> ChapterDocument {
        let module = try XCTUnwrap(PSModuleController.default()?.primaryCommentaryName)
        let document = try XCTUnwrap(PSContentReader.shared.chapterDocument(
            module: module, ref: ref, kind: .commentary
        ))
        XCTAssertFalse(document.verses.isEmpty, "No commentary text for \(ref).")
        return document
    }

    /// A chapter load renders the pane it polls and defers into the other, and a
    /// deferral is drained when its pane APPEARS — which a pane already on screen
    /// never does.
    ///
    /// A bookmark edit in the Library is such a load: it re-renders the Bible
    /// whichever pane is showing. Made while the commentary was up, it left the
    /// commentary owing the chapter it was already on, and paging on did not
    /// clear that. The next Bible → commentary switch then rendered the OLD
    /// chapter and wrote it back to `lastRef`, under a Bible pane still showing
    /// the new one — where Add Bookmark saved the wrong chapter.
    @MainActor
    func testARedisplayOfTheHiddenPaneLeavesNoDeferralOnThePaneOnScreen() throws {
        let john4 = try commentaryChapter("John 4")
        withPreservedReadingKeys { standard in
            standard.set("John 3", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()
            workspace.displayChapter("John 3", polling: .bible, restore: .scroll)
            workspace.mode = .commentary
            XCTAssertNil(workspace.commentary.refToShow)

            // What `bookmarksChanged` runs, here with the commentary showing.
            workspace.displayChapter("John 3", polling: .bible, restore: .scroll)
            XCTAssertNil(workspace.commentary.refToShow,
                         "The pane on screen was left owing a render nothing will ask for.")
            XCTAssertNil(workspace.commentary.pendingRestore)

            workspace.nextChapter()
            workspace.mode = .bible
            workspace.mode = .commentary
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "John 4",
                           "Switching back to the commentary returned the reader to "
                               + "the chapter it had paged away from.")
            XCTAssertTrue(workspace.commentary.document == john4,
                          "The commentary is not showing the chapter it paged to.")
        }
    }

    /// The other half: a pane that renders drops whatever it had deferred. The
    /// render is the newer instruction, and a deferral left behind it is replayed
    /// over it at the next switch.
    @MainActor
    func testRenderingAPaneDropsWhateverItHadDeferred() {
        withPreservedReadingKeys { standard in
            standard.set("John 3", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()
            workspace.mode = .commentary
            workspace.commentary.refToShow = "John 3"
            workspace.commentary.pendingRestore = .offset(800)

            workspace.nextChapter()

            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "John 4")
            XCTAssertNil(workspace.commentary.refToShow,
                         "The commentary paged to John 4 and still owes John 3.")
            XCTAssertNil(workspace.commentary.pendingRestore)
        }
    }

    /// The same trap from a reset. `resetPreferences()` posts
    /// `.redisplayPrimaryBible` whichever pane is showing; on a warm resume into
    /// the commentary that rendered the hidden Bible and left the commentary on
    /// the old chapter, under a "Genesis 1" title.
    @MainActor
    func testAResetWhileTheCommentaryShowsRerendersTheCommentary() throws {
        let genesis1 = try commentaryChapter("Genesis 1")
        withPreservedReadingKeys { standard in
            standard.set("John 3", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()
            workspace.displayChapter("John 3", polling: .bible, restore: .scroll)
            workspace.mode = .commentary

            // The reset: `lastRef` falls back to Genesis 1, and this call is the
            // `.redisplayPrimaryBible` observer's body.
            standard.set("Genesis 1", forKey: Defaults.lastRef)
            workspace.redisplay(pane: .bible, restore: .verse)

            XCTAssertNil(workspace.commentary.refToShow)
            XCTAssertTrue(workspace.commentary.document == genesis1,
                          "The commentary on screen kept the chapter from before the reset.")
        }
    }

    /// A page turn owed to the pane that is not on screen is settled in that
    /// pane's keys when it is deferred, and is still a page turn when it drains.
    ///
    /// Only the rendered pane used to write verse 1 / offset 0. The other pane's
    /// keys went on describing the chapter it last showed, and every later load
    /// rebuilt its deferral from them: a display toggle or a font change turned
    /// the owed chapter start into the old chapter's verse, a bookmark add into
    /// the old chapter's offset, and a relaunch read that offset straight back.
    @MainActor
    func testADeferredPageTurnSurvivesARedisplay() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 1", forKey: Defaults.lastRef)
            standard.set("20", forKey: Defaults.commentaryVersePosition)
            standard.set("4000", forKey: "commentaryScrollPosition")
            let workspace = ReadingWorkspaceModel()

            workspace.nextChapter()
            XCTAssertEqual(standard.string(forKey: Defaults.commentaryVersePosition), "1",
                           "The commentary's verse is still the one in the chapter being left.")
            XCTAssertEqual(standard.string(forKey: "commentaryScrollPosition"), "0",
                           "A relaunch would open the new chapter at the old one's offset.")

            // Paging BACK needs no earlier visit to the commentary to go wrong:
            // `setToPreviousChapter` writes the destination's LAST verse into the
            // commentary's key itself.
            workspace.previousChapter()
            XCTAssertEqual(standard.string(forKey: Defaults.commentaryVersePosition), "1")

            // A display toggle or a font change...
            workspace.redisplay(pane: .bible, restore: .verse)
            XCTAssertEqual(workspace.commentary.pendingRestore, .chapterStart)
            // ...and a bookmark added from the verse menu.
            workspace.redisplayAfterBookmarksChange()
            XCTAssertEqual(workspace.commentary.pendingRestore, .chapterStart)

            let surface = workspace.commentary.scrollSurface
            workspace.mode = .commentary
            XCTAssertEqual(workspace.commentary.scrollSurface, surface + 1,
                           "The page turn drained as something other than a chapter start.")
            XCTAssertNil(workspace.commentary.pendingRestore)
        }
    }

    /// The mirror: paging in the commentary owes the BIBLE a chapter start.
    ///
    /// Its offset key is what a relaunch restores (the app always relaunches into
    /// the Bible), and a Library bookmark edit used to render the hidden Bible
    /// there and then at that old offset, throwing the owed page turn away. The
    /// edit now re-renders the pane on screen and leaves the Bible what it owes.
    @MainActor
    func testPagingFromTheCommentaryLeavesTheBibleAtTheChapterStart() {
        withPreservedReadingKeys { standard in
            standard.set("John 3", forKey: Defaults.lastRef)
            standard.set("20", forKey: Defaults.bibleVersePosition)
            standard.set("1500", forKey: "bibleScrollPosition")
            let workspace = ReadingWorkspaceModel()
            workspace.mode = .commentary

            workspace.nextChapter()
            XCTAssertEqual(standard.string(forKey: "bibleScrollPosition"), "0",
                           "A relaunch would open John 4 at John 3's offset.")

            // A render re-reads the font size, which is how this tells that one ran:
            // the document it builds is equal to the one it replaces, and an
            // `@Observable` property set to an equal value notifies nobody.
            let fontSize = standard.object(forKey: Defaults.fontSizePreference)
            defer {
                if let fontSize {
                    standard.set(fontSize, forKey: Defaults.fontSizePreference)
                } else {
                    standard.removeObject(forKey: Defaults.fontSizePreference)
                }
            }
            let probe = Int(workspace.commentary.textStyle.fontSize) + 3
            standard.set(probe, forKey: Defaults.fontSizePreference)

            workspace.redisplayAfterBookmarksChange()
            XCTAssertEqual(workspace.bible.pendingRestore, .chapterStart,
                           "A bookmark edit spent the Bible's page turn while it was hidden.")
            XCTAssertEqual(
                PSModuleController.createRefString(workspace.bible.refToShow), "John 4"
            )
            // The pane on screen is polled in the Bible's place, so the edit still
            // goes through `displayChapter` and something is rendered. It has
            // nothing new to draw there: a commentary row carries no bookmark
            // colour (the builder looks one up for a Bible only). So this pins
            // that the render ran, not that the commentary shows the edit.
            XCTAssertEqual(workspace.commentary.textStyle.fontSize, CGFloat(probe),
                           "The bookmark edit re-rendered neither pane.")

            // The keep rule is for a restore that names no verse. A commentary
            // route writes the Bible's verse too (`ReadingStateStore.persist`), and
            // that verse has to win over the owed chapter start: draining
            // `.chapterStart` would persist verse 1 over it.
            standard.set("16", forKey: Defaults.bibleVersePosition)
            workspace.redisplay(pane: .commentary, restore: .verse)
            XCTAssertEqual(workspace.bible.pendingRestore, .verse(16))
        }
    }

    /// A chapter start replaces a verse scroll that was armed before it.
    ///
    /// A `.verse` load arms `verseToShow` on both panes, and the deferred pane's
    /// copy is spent by the `.verse` restore it drains with. Draining a kept
    /// `.chapterStart` instead left it armed, and the next time the pane appeared
    /// with nothing owed it scrolled to that verse.
    @MainActor
    func testAChapterStartDisarmsAVerseScrollArmedBeforeIt() {
        withPreservedPanePositionKeys { standard, scrollKey in
            let pane = ReaderPaneModel(mode: .bible)
            pane.setVerseToShow(7)
            pane.pendingRestore = .chapterStart
            pane.applyPendingWork()

            // The reader scrolls on into the chapter...
            let resting = ReaderScrollSample(
                offset: 700, contentHeight: 2138, containerHeight: 675
            )
            pane.scrollOffsetChanged(resting, from: pane.scrollSurface)
            pane.topmostVerseChanged(9, from: pane.scrollSurface)
            // ...and the pane appears again with nothing owed.
            pane.applyPendingWork()

            // A scroll to verse 7 resets where the pane thinks it is, so the same
            // resting offset then reads as a move and is persisted against verse 7.
            pane.scrollOffsetChanged(resting, from: pane.scrollSurface)
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "9",
                           "A verse scroll armed before the page turn ran after it.")
            XCTAssertEqual(standard.string(forKey: scrollKey), "700")
        }
    }

    /// A bookmark add re-renders the Bible at its scroll OFFSET, and used to hand
    /// the other pane an offset as well — its own key, which describes whatever
    /// chapter that pane last showed — over the verse it had been sent to in
    /// this one.
    @MainActor
    func testABookmarkChangeKeepsTheVerseADeferredPaneWasSentTo() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 1", forKey: Defaults.lastRef)
            standard.set("4000", forKey: "commentaryScrollPosition")
            let workspace = ReadingWorkspaceModel()

            workspace.selectReference(bookName: "John", chapter: 3, verse: 16)
            XCTAssertEqual(workspace.commentary.pendingRestore, .verse(16))

            workspace.redisplayAfterBookmarksChange()
            XCTAssertEqual(workspace.commentary.pendingRestore, .verse(16),
                           "The commentary will open John 3 at Genesis 1's offset.")

            // A pane that has never been shown has no offset key at all, and "no
            // position" says no more about this chapter than another one's offset.
            standard.removeObject(forKey: "commentaryScrollPosition")
            workspace.redisplayAfterBookmarksChange()
            XCTAssertEqual(workspace.commentary.pendingRestore, .verse(16),
                           "The commentary will open John 3 at the top, not at the verse.")
        }
    }

    /// A verse a pane was sent to does not outlive the load that sent it there.
    ///
    /// A `.verse` load arms a scroll to that verse on BOTH panes, and the pane
    /// that is not on screen spent it only by draining as that verse. Pick
    /// Romans 8:16, page on, and the commentary opened Romans 9 at the top with
    /// verse 16 still armed: the next Bible → commentary switch, with nothing
    /// navigated in between, scrolled it there and saved verse 16 over the one
    /// the reader had read down to. The same the other way round.
    ///
    /// The stale scroll shows in the persisted verse. It resets where the pane
    /// believes it is, so the next scroll report is saved against that verse.
    @MainActor
    func testASupersededVerseRestoreDoesNotFireOnALaterPaneSwitch() {
        let sample = { (y: CGFloat) in
            ReaderScrollSample(offset: y, contentHeight: 4000, containerHeight: 675)
        }
        // Picked and paged in one pane, read in the other — both ways round.
        for reading in [ReadingMode.commentary, .bible] {
            let picking: ReadingMode = reading == .bible ? .commentary : .bible
            let verseKey = reading == .bible
                ? Defaults.bibleVersePosition
                : Defaults.commentaryVersePosition
            withPreservedReadingKeys { standard in
                standard.set("Romans 7", forKey: Defaults.lastRef)
                let workspace = ReadingWorkspaceModel()
                workspace.mode = picking
                workspace.selectReference(bookName: "Romans", chapter: 8, verse: 16)
                workspace.nextChapter()
                XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Romans 9")

                workspace.mode = reading
                let pane = workspace.activePane
                pane.topmostVerseChanged(25, from: pane.scrollSurface)
                pane.scrollOffsetChanged(sample(1900), from: pane.scrollSurface)
                XCTAssertEqual(standard.string(forKey: verseKey), "25")

                // A look at the other pane and straight back; then the rows settle.
                workspace.mode = picking
                workspace.mode = reading
                pane.scrollOffsetChanged(sample(1903), from: pane.scrollSurface)
                XCTAssertEqual(standard.string(forKey: verseKey), "25",
                               "Coming back to the \(reading) pane scrolled it to the "
                                   + "verse picked a chapter ago.")
            }
        }
    }

    /// Whatever a pane drains supersedes a verse scroll armed before it — an
    /// offset as much as a verse or a chapter start, and with a chapter owed or
    /// without.
    ///
    /// Only `.verse` and `.chapterStart` spend the armed verse themselves. An
    /// offset drained over it left it armed, and the next time the pane appeared
    /// with nothing owed it scrolled there. `deferRender` no longer hands a pane
    /// an offset over a verse it was sent to, so no load builds this pair today;
    /// the drain is where the rule belongs all the same, or the next producer
    /// of one brings the jump back.
    @MainActor
    func testADrainedOffsetDisarmsAVerseScrollArmedBeforeIt() {
        let sample = { (y: CGFloat) in
            ReaderScrollSample(offset: y, contentHeight: 4000, containerHeight: 675)
        }
        for owedChapter in [nil, "John 3"] as [String?] {
            withPreservedReadingKeys { standard in
                let pane = ReaderPaneModel(mode: .bible)
                pane.setVerseToShow(5)
                pane.refToShow = owedChapter
                pane.pendingRestore = .offset(400)
                pane.applyPendingWork()
                pane.scrollOffsetChanged(sample(400), from: pane.scrollSurface)

                // The reader scrolls on into the chapter...
                pane.topmostVerseChanged(30, from: pane.scrollSurface)
                pane.scrollOffsetChanged(sample(2600), from: pane.scrollSurface)
                // ...and the pane appears again with nothing owed.
                pane.applyPendingWork()

                pane.scrollOffsetChanged(sample(2603), from: pane.scrollSurface)
                XCTAssertEqual(
                    standard.string(forKey: Defaults.bibleVersePosition), "30",
                    "A verse scroll armed before the drain ran after it "
                        + "(chapter owed: \(owedChapter ?? "none"))."
                )
                XCTAssertEqual(standard.string(forKey: "bibleScrollPosition"), "2603")
            }
        }
    }

    /// Paging restores no position on EITHER pane, so it disarms a verse scroll
    /// on both — not only on the pane that is on screen.
    ///
    /// The other pane usually spends its own by draining the chapter start it is
    /// handed. It does not have to drain: a load that polls it renders it where
    /// it stands, at its offset, and an offset leaves an armed verse alone. Here
    /// the Bible was sent to Romans 8:16 while the commentary showed, the reader
    /// paged on, and the Bible was then rendered in place — after which showing
    /// it scrolled Romans 9 to verse 16. (A bookmark edit was that load. It now
    /// leaves a Bible that owes a render alone, so nothing polls one today.)
    @MainActor
    func testPagingDisarmsAPendingVerseOnBothPanes() {
        withPreservedReadingKeys { standard in
            standard.set("Romans 7", forKey: Defaults.lastRef)
            standard.set("0", forKey: "bibleScrollPosition")
            let workspace = ReadingWorkspaceModel()
            workspace.displayChapter("Romans 7", polling: .bible, restore: .scroll)
            workspace.mode = .commentary

            workspace.selectReference(bookName: "Romans", chapter: 8, verse: 16)
            workspace.nextChapter()
            workspace.displayChapter("Romans 9", polling: .bible, restore: .scroll)

            workspace.mode = .bible
            workspace.bible.scrollOffsetChanged(
                ReaderScrollSample(offset: 300, contentHeight: 4000, containerHeight: 675),
                from: workspace.bible.scrollSurface
            )
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "1",
                           "Showing the Bible scrolled the chapter paged to back to "
                               + "the verse picked in the one before it.")
        }
    }

    /// Picking a verse in the chapter already open reaches a pane that has not
    /// rendered that chapter yet.
    ///
    /// The picker's same-chapter path scrolled both panes. In the Bible the
    /// commentary almost always still OWES the chapter — every Bible load defers
    /// into it, launch included — so the scroll moved a document about to be
    /// replaced, and the commentary then opened wherever its old deferral said,
    /// under a title naming the picked verse. Neither verse key was written
    /// either, unlike a pick in any other chapter.
    @MainActor
    func testPickingAVerseInTheOpenChapterReachesThePaneThatHasNotRenderedIt() {
        withPreservedReadingKeys { standard in
            standard.set("John 3", forKey: Defaults.lastRef)
            standard.set("4", forKey: Defaults.bibleVersePosition)
            standard.set("9", forKey: Defaults.commentaryVersePosition)
            standard.set("700", forKey: "commentaryScrollPosition")
            let workspace = ReadingWorkspaceModel()
            // What launch does.
            workspace.displayChapter("John 3", polling: .bible, restore: .scroll)
            XCTAssertEqual(workspace.commentary.pendingRestore, .offset(700))

            workspace.selectReference(bookName: "John", chapter: 3, verse: 16)

            XCTAssertEqual(workspace.commentary.pendingRestore, .verse(16),
                           "The commentary will open John 3 where it was last left, "
                               + "not at the verse picked.")
            XCTAssertNotNil(workspace.commentary.refToShow)
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "16")
            XCTAssertEqual(standard.string(forKey: Defaults.commentaryVersePosition), "16")

            // A page turn the pane still owes IS the top of the chapter, and stays
            // one: picking verse 1 is no reason to open it on the old scroll view.
            workspace.nextChapter()
            workspace.selectReference(bookName: "John", chapter: 4, verse: 1)
            XCTAssertEqual(workspace.commentary.pendingRestore, .chapterStart)
        }
    }

    /// A highlight on each pane, as two search results opened one after the other
    /// in the two modules leave them.
    @MainActor
    private func highlightBothPanes(of workspace: ReadingWorkspaceModel) {
        workspace.highlightSearchTerms(["Noah"], mode: .bible)
        workspace.highlightSearchTerms(["grace"], mode: .commentary)
    }

    /// A search result's highlight belongs to the chapter the result was opened
    /// in, and ends on every way of leaving it — in BOTH panes.
    ///
    /// Paging was the only exit that ended it, and only on the pane showing. A
    /// jump from the reference picker, a bookmark, a history row or a `sword://`
    /// link carried the terms into the chapter it opened, where every occurrence
    /// was jacketed in yellow, and so did each jump after it, until a page turn in
    /// that same pane or a relaunch. The pane NOT showing kept its terms through
    /// a page turn too, and drew the new chapter with them when it was next shown.
    @MainActor
    func testLeavingASearchResultsChapterEndsItsHighlightInBothPanes() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 5", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()
            // What launch does: the Bible renders, the commentary owes the chapter.
            workspace.displayChapter("Genesis 5", polling: .bible, restore: .scroll)

            // A verse picked in the SAME chapter is a scroll, and keeps it.
            highlightBothPanes(of: workspace)
            workspace.selectReference(bookName: "Genesis", chapter: 5, verse: 29)
            XCTAssertEqual(workspace.bible.searchHighlightTerms, ["Noah"])
            XCTAssertEqual(workspace.commentary.searchHighlightTerms, ["grace"])

            // The reference picker, to another chapter.
            workspace.selectReference(bookName: "Genesis", chapter: 9, verse: 1)
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Genesis 9")
            XCTAssertEqual(workspace.bible.searchHighlightTerms, [],
                           "The highlight followed the reference picker into "
                               + "another chapter.")
            XCTAssertEqual(workspace.bible.textStyle.highlightTerms, [],
                           "The chapter the picker opened was drawn with the "
                               + "result's terms.")
            XCTAssertEqual(workspace.commentary.searchHighlightTerms, [],
                           "The pane not showing kept its highlight for the "
                               + "chapter the picker opened.")

            // A page turn in the Bible ends the commentary's as well...
            highlightBothPanes(of: workspace)
            workspace.nextChapter()
            XCTAssertEqual(workspace.bible.searchHighlightTerms, [])
            XCTAssertEqual(workspace.commentary.searchHighlightTerms, [],
                           "Paging the Bible left the commentary's highlight "
                               + "for the chapter it follows to.")

            // ...and one in the commentary ends the Bible's, which then draws the
            // chapter it was owed without it.
            workspace.mode = .commentary
            highlightBothPanes(of: workspace)
            workspace.nextChapter()
            XCTAssertEqual(workspace.bible.searchHighlightTerms, [],
                           "Paging the commentary left the Bible's highlight "
                               + "for the chapter it follows to.")
            workspace.mode = .bible
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Genesis 11")
            XCTAssertEqual(workspace.bible.textStyle.highlightTerms, [],
                           "The Bible drew the chapter paged to in the "
                               + "commentary with its old result's terms.")

            // An inbound route: a bookmark, a history row, a `sword://` link.
            highlightBothPanes(of: workspace)
            workspace.showRoutedMode(.bible)
            XCTAssertEqual(workspace.bible.searchHighlightTerms, [],
                           "The highlight followed a routed open.")
            XCTAssertEqual(workspace.commentary.searchHighlightTerms, [],
                           "The pane not showing kept its highlight through a "
                               + "routed open.")
        }
    }

    /// Opening a search result ends whatever highlight was showing and THEN puts
    /// the result's own terms on — in that order, which is why the hand-off is
    /// one model method and not two calls at the call site.
    ///
    /// A search result opens through the same route as a bookmark, and the route
    /// ends the highlight in both panes. Terms assigned before the open are wiped
    /// by it, and nothing else fails: the result just opens unhighlighted, as it
    /// did for every release in which the highlighter had no caller at all.
    @MainActor
    func testASearchResultsTermsGoOnAfterTheOpenThatEndsThePreviousHighlight() {
        withPreservedReadingKeys { standard in
            // The route loads the module it names, which writes this key.
            let lastBible = standard.object(forKey: Defaults.lastBible)
            defer {
                if let lastBible {
                    standard.set(lastBible, forKey: Defaults.lastBible)
                } else {
                    standard.removeObject(forKey: Defaults.lastBible)
                }
            }
            standard.set("John 3", forKey: Defaults.lastRef)
            let library = LibraryModel(
                bookmarkStore: BookmarkStore(
                    rootProvider: { PSBookmarkFolder() },
                    save: { true },
                    notificationCenter: NotificationCenter()
                ),
                // No module to record against, so the route writes no history.
                historyStore: HistoryStore(
                    defaults: defaults,
                    cloudStore: HistoryCloudStoreStub(),
                    notificationCenter: NotificationCenter(),
                    moduleNameProvider: { _ in nil }
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
            let session = AppSession(library: library, dismissKeyboard: {})
            let workspace = ReadingWorkspaceModel(session: session)
            // Marks the session ready. Until then `open` only parks the URL.
            session.replayPendingURL()

            // An older result, opened in the commentary.
            workspace.highlightSearchTerms(["grace"], mode: .commentary)
            workspace.openSearchResult(
                "Genesis 5:29",
                module: BundledModules.bible,
                terms: ["Noah"],
                mode: .bible
            )

            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Genesis 5")
            XCTAssertEqual(workspace.bible.searchHighlightTerms, ["Noah"],
                           "The open wiped the terms of the result it was opening.")
            XCTAssertEqual(workspace.bible.textStyle.highlightTerms, ["Noah"],
                           "The result's chapter is drawn without its terms.")
            XCTAssertEqual(workspace.commentary.searchHighlightTerms, [],
                           "An older result's terms outlived the open of a new one.")

            // The same route without terms — a bookmark — ends it again.
            workspace.openLibraryReference("Romans 8:28", module: nil)
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Romans 8")
            XCTAssertEqual(workspace.bible.searchHighlightTerms, [],
                           "The highlight followed a bookmark into another chapter.")
        }
        // A route posts `redisplayPrimaryBible` on the shared centre, so the host
        // app's own reader followed both of them. With the keys back, return it
        // to the chapter they name: left on Romans 8, it goes on saving its
        // scroll position from there, against a `lastRef` that says otherwise.
        NotificationCenter.default.post(name: .redisplayPrimaryBible, object: nil)
    }

    /// A reset leaves the result's chapter too, by the one path that is not a
    /// navigation: it removes `lastRef`, and the `redisplayPrimaryBible` it posts
    /// next renders Genesis 1. A redisplay is otherwise the SAME chapter drawn
    /// again, which is why it carries the highlight across. The reset flag is
    /// set in the Settings app, so it can arrive with a result open.
    @MainActor
    func testAResetEndsTheSearchHighlight() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 5", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()
            // A reset reaches the workspace as a notification, and `start()` is
            // where it starts listening.
            workspace.start()
            highlightBothPanes(of: workspace)

            // Delivered on `OperationQueue.main` in registration order, so by the
            // time this probe fulfils the workspace's own observer has run.
            let handled = expectation(description: "appStateDidReset handled")
            let probe = NotificationCenter.default.addObserver(
                forName: .appStateDidReset,
                object: nil,
                queue: .main
            ) { _ in handled.fulfill() }
            defer { NotificationCenter.default.removeObserver(probe) }
            NotificationCenter.default.post(name: .appStateDidReset, object: nil)
            wait(for: [handled], timeout: 5)

            XCTAssertEqual(workspace.bible.searchHighlightTerms, [],
                           "The highlight followed a reset to Genesis 1.")
            XCTAssertEqual(workspace.bible.textStyle.highlightTerms, [])
            XCTAssertEqual(workspace.commentary.searchHighlightTerms, [])
        }
    }

    // MARK: Page-turn slide

    /// The scroll view a page turn leaves stays on screen until its slide ends,
    /// still coasting on any flick it had, and keeps reporting where it is — in
    /// the chapter being LEFT. Measured on the simulator, paging straight after a
    /// flick: 26 such reports in the 420 ms after the new chapter's position was
    /// persisted. One of them getting through reopens the new chapter at the old
    /// one's offset, and titles it with the old one's verse.
    @MainActor
    func testAScrollViewBeingLeftCannotOverwriteTheNewChaptersPosition() {
        withPreservedPanePositionKeys { standard, scrollKey in
            let pane = ReaderPaneModel(mode: .bible)
            let leaving = pane.scrollSurface
            pane.pendingRestore = .chapterStart
            pane.applyPendingWork()

            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 1594, contentHeight: 2138, containerHeight: 675),
                from: leaving
            )
            pane.topmostVerseChanged(10, from: leaving)
            XCTAssertEqual(standard.string(forKey: scrollKey), "0",
                           "The scroll view being left persisted its offset.")
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "1",
                           "The scroll view being left persisted its verse.")

            // The scroll view that replaced it reports as usual.
            pane.scrollOffsetChanged(
                ReaderScrollSample(offset: 300, contentHeight: 2138, containerHeight: 675),
                from: pane.scrollSurface
            )
            pane.topmostVerseChanged(4, from: pane.scrollSurface)
            XCTAssertEqual(standard.string(forKey: scrollKey), "300")
            XCTAssertEqual(standard.string(forKey: Defaults.bibleVersePosition), "4")
        }
    }

    /// The slide is keyed on `pageTurn`, and only the pane on screen gets one.
    ///
    /// The other pane is handed the same chapter start and bumps its scroll
    /// surface when it is next shown. That is a pane appearing, not a page
    /// turning: were the slide keyed on the surface, switching Bible ⇄ commentary
    /// after paging would slide in a chapter change made some time ago.
    @MainActor
    func testOnlyThePaneOnScreenTurnsAPage() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 2", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()

            workspace.nextChapter()
            XCTAssertEqual(workspace.bible.pageTurn,
                           ReaderPaneModel.PageTurn(count: 1, forward: true))
            workspace.previousChapter()
            XCTAssertEqual(workspace.bible.pageTurn,
                           ReaderPaneModel.PageTurn(count: 2, forward: false))
            XCTAssertEqual(workspace.commentary.pageTurn.count, 0)

            // Draining the deferred page swaps the commentary's scroll view...
            let surface = workspace.commentary.scrollSurface
            workspace.mode = .commentary
            XCTAssertEqual(workspace.commentary.scrollSurface, surface + 1)
            // ...without a page turn to animate.
            XCTAssertEqual(workspace.commentary.pageTurn.count, 0)

            // Paging the commentary is its own page turn, and not the Bible's.
            workspace.nextChapter()
            XCTAssertEqual(workspace.commentary.pageTurn,
                           ReaderPaneModel.PageTurn(count: 1, forward: true))
            XCTAssertEqual(workspace.bible.pageTurn.count, 2)
        }
    }

    // MARK: Chapter swipe

    /// The swipe-versus-scroll decision. The reader is a vertical scroll view, so
    /// every vector here that returns nil is something a reader does all day; one
    /// of them paging would be a chapter change nobody asked for.
    func testChapterSwipeClassifiesAFinishedDrag() {
        func swipe(_ dx: CGFloat, _ dy: CGFloat,
                   projected px: CGFloat, _ py: CGFloat) -> ChapterSwipe? {
            ChapterSwipe(
                translation: CGSize(width: dx, height: dy),
                predictedEndTranslation: CGSize(width: px, height: py)
            )
        }

        // Left pages forward, right pages back.
        XCTAssertEqual(swipe(-120, 8, projected: -300, 20), .next)
        XCTAssertEqual(swipe(120, -8, projected: 300, -20), .previous)
        // A quick flick clears the projected distance on speed alone...
        XCTAssertEqual(swipe(-55, 0, projected: -400, 0), .next)
        // ...and a slow, deliberate drag clears it on distance.
        XCTAssertEqual(swipe(160, 10, projected: 160, 10), .previous)
        // The thresholds are inclusive.
        XCTAssertEqual(swipe(-50, 25, projected: -150, 75), .next)

        XCTAssertNil(swipe(5, -200, projected: 10, -600),
                     "An ordinary vertical scroll paged the chapter.")
        XCTAssertNil(swipe(-80, -60, projected: -250, -180),
                     "A scroll that drifted sideways paged the chapter.")
        XCTAssertNil(swipe(-30, 0, projected: -400, 0),
                     "A flick too short to be deliberate paged the chapter.")
        XCTAssertNil(swipe(-90, 0, projected: -90, 0),
                     "A short, slow drag paged the chapter.")
        XCTAssertNil(swipe(-60, 0, projected: 40, 0),
                     "A drag reversed before release paged the chapter.")
        XCTAssertNil(swipe(0, 0, projected: 0, 0))
    }

    /// A swipe is gated on the flags that disable the chevron buttons.
    ///
    /// `page(forward:)` clears the search highlight before it checks the boundary,
    /// which is harmless behind a disabled button and not behind a swipe: without
    /// the gate, swiping back at Genesis 1 would wipe the highlight and go nowhere.
    @MainActor
    func testChapterSwipeIsInertWhereTheChevronsAreDisabled() {
        let standard = UserDefaults.standard
        let lastRef = standard.string(forKey: Defaults.lastRef)
        let workspace = ReadingWorkspaceModel()
        workspace.bible.searchHighlightTerms = ["beginning"]
        workspace.bible.chrome.isNextEnabled = false
        workspace.bible.chrome.isPreviousEnabled = false

        workspace.page(.next)
        workspace.page(.previous)

        XCTAssertEqual(workspace.bible.searchHighlightTerms, ["beginning"])
        XCTAssertEqual(standard.string(forKey: Defaults.lastRef), lastRef,
                       "A gated swipe changed the persisted reference.")
    }

    /// A swipe's haptic fires on what `page(_:)` returns, so it has to be true
    /// exactly when the chapter changed. A tap for a swipe that went nowhere says
    /// the page turned when it did not.
    @MainActor
    func testASwipeReportsWhetherItTurnedThePage() {
        withPreservedReadingKeys { standard in
            standard.set("Genesis 1", forKey: Defaults.lastRef)
            let workspace = ReadingWorkspaceModel()

            // Nothing precedes Genesis 1. The chevron flags have not been computed
            // for this workspace, so this is the boundary check answering, not the gate.
            XCTAssertFalse(workspace.page(.previous))
            workspace.bible.chrome.isNextEnabled = false
            XCTAssertFalse(workspace.page(.next))
            XCTAssertEqual(workspace.bible.pageTurn.count, 0,
                           "A swipe that went nowhere turned a page.")
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Genesis 1")

            workspace.bible.chrome.isNextEnabled = true
            XCTAssertTrue(workspace.page(.next))
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Genesis 2")
            XCTAssertTrue(workspace.page(.previous))
            XCTAssertEqual(standard.string(forKey: Defaults.lastRef), "Genesis 1")
        }
    }
}
