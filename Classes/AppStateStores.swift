import Foundation
import UIKit

enum RotationLock: Int, Equatable {
    case unlocked = 0
    case portrait = 1
    case landscape = 2

    init(interfaceOrientation: UIInterfaceOrientation) {
        self = interfaceOrientation.isLandscape ? .landscape : .portrait
    }
}

struct SettingsSnapshot: Equatable {
    let fontName: String
    let fontSize: Int
    let keepScreenAwake: Bool
    let rotationLock: RotationLock
    let librarySection: LibrarySection
}

final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() -> SettingsSnapshot {
        let savedFontSize = defaults.integer(forKey: Defaults.fontSizePreference)
        return SettingsSnapshot(
            // The font in effect, which is not always the one saved: a name the
            // system cannot supply draws as the default (`StudyFonts.resolved`),
            // and Settings must name the font the reader is drawing with. Nothing
            // writes this back; `SettingsModel` saves a font only when the user
            // picks one.
            fontName: StudyFonts.resolved(
                defaults.string(forKey: Defaults.fontNamePreference)
            ),
            fontSize: savedFontSize == 0
                ? AppConstants.defaultFontSize
                : savedFontSize,
            keepScreenAwake: defaults.bool(forKey: Defaults.insomniaPreference),
            rotationLock: RotationLock(
                rawValue: defaults.integer(forKey: Defaults.rotationLockPosition)
            ) ?? .unlocked,
            librarySection: defaults.string(
                forKey: Defaults.librarySectionPreference
            ).flatMap(LibrarySection.init(rawValue:)) ?? .bookmarks
        )
    }

    func ensureFontSizeDefault() {
        guard defaults.integer(forKey: Defaults.fontSizePreference) == 0 else {
            return
        }
        defaults.set(
            AppConstants.defaultFontSize,
            forKey: Defaults.fontSizePreference
        )
    }

    func saveFontName(_ value: String) {
        defaults.set(value, forKey: Defaults.fontNamePreference)
        defaults.synchronize()
    }

    func saveFontSize(_ value: Int) {
        defaults.set(value, forKey: Defaults.fontSizePreference)
        defaults.synchronize()
    }

    func saveKeepScreenAwake(_ value: Bool) {
        defaults.set(value, forKey: Defaults.insomniaPreference)
        defaults.synchronize()
    }

    func saveRotationLock(_ value: RotationLock) {
        defaults.setValue(
            NSNumber(value: Int32(value.rawValue)),
            forKey: Defaults.rotationLockPosition
        )
        defaults.synchronize()
    }

    func saveLibrarySection(_ value: LibrarySection) {
        defaults.set(value.rawValue, forKey: Defaults.librarySectionPreference)
        defaults.synchronize()
    }
}

struct ReadingSnapshot: Equatable {
    let reference: BibleReference?
    let bibleModule: String
    let commentaryModule: String
    let bibleVerse: Int
    let commentaryVerse: Int
}

final class ReadingStateStore {
    private let defaults: UserDefaults
    private let parser: PSRefParser?

    init(
        defaults: UserDefaults = .standard,
        parser: PSRefParser? = PSRefParser()
    ) {
        self.defaults = defaults
        self.parser = parser
    }

    func snapshot() -> ReadingSnapshot {
        let persistedReference = defaults.string(forKey: Defaults.lastRef)
            ?? "Genesis 1"
        return ReadingSnapshot(
            reference: parser?.parse(persistedReference),
            bibleModule: defaults.string(forKey: Defaults.lastBible)
                ?? BundledModules.bible,
            commentaryModule: defaults.string(forKey: Defaults.lastCommentary)
                ?? BundledModules.commentary,
            bibleVerse: intValue(forKey: Defaults.bibleVersePosition),
            commentaryVerse: intValue(forKey: Defaults.commentaryVersePosition)
        )
    }

    func persist(_ route: URLRoute) {
        defaults.set(route.persistedChapterRef, forKey: Defaults.lastRef)
        defaults.set(route.versePosition, forKey: Defaults.bibleVersePosition)
        if case .commentary = route.destination {
            defaults.set(
                route.versePosition,
                forKey: Defaults.commentaryVersePosition
            )
        }
        defaults.synchronize()
    }

    private func intValue(forKey key: String) -> Int {
        guard let value = defaults.string(forKey: key), let int = Int(value) else {
            return 1
        }
        return int
    }
}

struct BookmarkColor: Equatable, Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hexString: String?) {
        guard var value = hexString, !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return nil
        }
        red = UInt8((rgb >> 16) & 0xff)
        green = UInt8((rgb >> 8) & 0xff)
        blue = UInt8(rgb & 0xff)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }
}

struct BookmarkNode: Identifiable, Equatable {
    enum Kind: Equatable {
        case bookmark(reference: String?)
        case folder(color: BookmarkColor?, children: [BookmarkNode])
    }

    let id: UUID
    let name: String?
    let dateAdded: Date?
    let dateLastAccessed: Date?
    let kind: Kind
}

enum BookmarkMutationError: Error, Equatable, Identifiable {
    case duplicateFolder
    case invalidFolderName
    case missingNode

    var id: Int {
        switch self {
        case .duplicateFolder: 0
        case .invalidFolderName: 1
        case .missingNode: 2
        }
    }
}

final class BookmarkStore {
    private let rootProvider: () -> PSBookmarkFolder
    private let save: () -> Bool
    private let notificationCenter: NotificationCenter

    init(
        rootProvider: @escaping () -> PSBookmarkFolder = {
            PSBookmarks.default()
        },
        save: @escaping () -> Bool = {
            PSBookmarks.saveBookmarksToFile()
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.rootProvider = rootProvider
        self.save = save
        self.notificationCenter = notificationCenter
    }

    func snapshot() -> [BookmarkNode] {
        nodes(in: rootProvider())
    }

    func children(in parentID: UUID?) -> [BookmarkNode] {
        guard let parentID else {
            return snapshot()
        }
        guard let folder = object(id: parentID) as? PSBookmarkFolder else {
            return []
        }
        return nodes(in: folder)
    }

    func node(id: UUID) -> BookmarkNode? {
        object(id: id).map(node(from:))
    }

    func addFolder(
        name: String,
        color: BookmarkColor?,
        to parentID: UUID?
    ) throws {
        guard Self.isValidFolderName(name) else {
            throw BookmarkMutationError.invalidFolderName
        }
        guard let parent = folder(id: parentID) else {
            throw BookmarkMutationError.missingNode
        }
        guard !containsFolder(named: name, excluding: nil, in: parent) else {
            throw BookmarkMutationError.duplicateFolder
        }

        parent.addChild(
            PSBookmarkFolder(
                name: name,
                dateAdded: Date(),
                dateLastAccessed: Date(),
                rgbHexString: color?.hexString,
                children: nil
            )
        )
        commit()
    }

    func rename(id: UUID, to name: String) throws {
        try renameObject(id: id, to: name)
        commit()
    }

    /// Renames a folder and sets its colour, or throws having changed NOTHING.
    ///
    /// The type check runs BEFORE `renameObject`, deliberately: `renameObject`
    /// mutates the live `PSBookmarks.default()` tree and only `commit()` writes it
    /// out, so validating afterwards would leave a phantom rename in memory for the
    /// next unrelated `commit()` to persist.
    func updateFolder(
        id: UUID,
        name: String,
        color: BookmarkColor?
    ) throws {
        guard let folder = object(id: id) as? PSBookmarkFolder else {
            throw BookmarkMutationError.missingNode
        }
        try renameObject(id: id, to: name)
        folder.rgbHexString = color?.hexString
        commit()
    }

    private func renameObject(id: UUID, to name: String) throws {
        guard let object = object(id: id),
              let parent = parentFolder(containing: id, in: rootProvider()) else {
            throw BookmarkMutationError.missingNode
        }
        if object is PSBookmarkFolder {
            guard Self.isValidFolderName(name) else {
                throw BookmarkMutationError.invalidFolderName
            }
            guard !containsFolder(named: name, excluding: id, in: parent) else {
                throw BookmarkMutationError.duplicateFolder
            }
        }
        if let bookmark = object as? PSBookmark, name.isEmpty {
            bookmark.name = bookmark.ref
        } else {
            object.name = name
        }
        object.dateLastAccessed = Date()
    }

    /// What a folder may be called: something the reader can see, without the
    /// separator its path is joined with.
    ///
    /// A blank name (empty, or nothing but whitespace) is a folder icon with no
    /// label and, when a second one is tried beside it, a "duplicate folder" alert
    /// that names nothing. At the top level its path is "", which
    /// `PSBookmarks.getBookmarkFolder` reads as the root, so the bookmark editor
    /// could never file into it.
    ///
    /// The name is only TESTED trimmed. It is stored as typed, so nothing changes
    /// for a name that was accepted before.
    ///
    /// The rule lives here, not in a `.disabled` on the two Save buttons: a
    /// `TextField`'s binding lags the last keystroke until the field commits (the
    /// XCUITests' `createFolder` measured it), so a button bound to the text would
    /// refuse a one-character name tapped quickly. Both call sites already present
    /// the thrown error, and both checks run before anything is mutated, which is
    /// what `updateFolder` promises.
    ///
    /// One consequence: a blank-named folder already on disk cannot be recoloured
    /// until it is given a name, because `updateFolder` validates the name it is
    /// handed. Renaming it works.
    private static func isValidFolderName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.contains(AppConstants.folderSeparatorString)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let parent = parentFolder(containing: id, in: rootProvider()) else {
            return false
        }
        var children = parent.children ?? []
        guard let index = children.firstIndex(where: {
            ($0 as? PSBookmarkObject)?.id == id
        }) else {
            return false
        }
        children.remove(at: index)
        parent.children = children
        commit()
        return true
    }

    @discardableResult
    func reorder(
        parentID: UUID?,
        sources: [UUID],
        before destinationID: UUID?
    ) -> Bool {
        guard let parent = folder(id: parentID) else {
            return false
        }
        let sourceIDs = Set(sources)
        guard !sourceIDs.isEmpty else {
            return false
        }

        var children = parent.children ?? []
        let moving = children.compactMap { child -> PSBookmarkObject? in
            guard let object = child as? PSBookmarkObject,
                  sourceIDs.contains(object.id) else {
                return nil
            }
            return object
        }
        guard moving.count == sourceIDs.count else {
            return false
        }

        children.removeAll {
            guard let object = $0 as? PSBookmarkObject else { return false }
            return sourceIDs.contains(object.id)
        }
        if let destinationID,
           let destinationIndex = children.firstIndex(where: {
               ($0 as? PSBookmarkObject)?.id == destinationID
           }) {
            children.insert(contentsOf: moving, at: destinationIndex)
        } else {
            children.append(contentsOf: moving)
        }
        parent.children = children
        commit()
        return true
    }

    func markAccessed(id: UUID) -> String? {
        guard let bookmark = object(id: id) as? PSBookmark else {
            return nil
        }
        bookmark.dateLastAccessed = Date()
        _ = save()
        return bookmark.ref
    }

    private func nodes(in folder: PSBookmarkFolder) -> [BookmarkNode] {
        (folder.children ?? []).compactMap { child in
            guard let child = child as? PSBookmarkObject else {
                return nil
            }
            return node(from: child)
        }
    }

    private func node(from object: PSBookmarkObject) -> BookmarkNode {
        let kind: BookmarkNode.Kind
        if let folder = object as? PSBookmarkFolder {
            let children = (folder.children ?? []).compactMap { child -> BookmarkNode? in
                guard let child = child as? PSBookmarkObject else {
                    return nil
                }
                return node(from: child)
            }
            kind = .folder(
                color: BookmarkColor(hexString: folder.rgbHexString),
                children: children
            )
        } else {
            kind = .bookmark(reference: (object as? PSBookmark)?.ref)
        }
        return BookmarkNode(
            id: object.id,
            name: object.name,
            dateAdded: object.dateAdded,
            dateLastAccessed: object.dateLastAccessed,
            kind: kind
        )
    }

    private func folder(id: UUID?) -> PSBookmarkFolder? {
        guard let id else {
            return rootProvider()
        }
        return object(id: id) as? PSBookmarkFolder
    }

    private func object(id: UUID) -> PSBookmarkObject? {
        findObject(id: id, in: rootProvider())
    }

    private func findObject(
        id: UUID,
        in folder: PSBookmarkFolder
    ) -> PSBookmarkObject? {
        for case let child as PSBookmarkObject in folder.children ?? [] {
            if child.id == id {
                return child
            }
            if let childFolder = child as? PSBookmarkFolder,
               let match = findObject(id: id, in: childFolder) {
                return match
            }
        }
        return nil
    }

    private func parentFolder(
        containing id: UUID,
        in folder: PSBookmarkFolder
    ) -> PSBookmarkFolder? {
        for case let child as PSBookmarkObject in folder.children ?? [] {
            if child.id == id {
                return folder
            }
            if let childFolder = child as? PSBookmarkFolder,
               let match = parentFolder(containing: id, in: childFolder) {
                return match
            }
        }
        return nil
    }

    private func containsFolder(
        named name: String,
        excluding id: UUID?,
        in parent: PSBookmarkFolder
    ) -> Bool {
        (parent.children ?? []).contains {
            guard let folder = $0 as? PSBookmarkFolder else { return false }
            return folder.id != id && folder.name == name
        }
    }

    private func commit() {
        _ = save()
        notificationCenter.post(name: .bookmarksChanged, object: nil)
    }
}

struct DictionarySnapshot: Equatable {
    let module: String?
    let keys: [String]
}

struct DictionaryEntryDocument: Identifiable, Equatable {
    struct ID: Hashable {
        let module: String
        let key: String
    }

    let module: String
    let key: String
    let html: String

    var id: ID {
        ID(module: module, key: key)
    }
}

final class DictionaryStore {
    typealias ModuleProvider = () -> String?
    typealias ModuleLoader = (String?) -> Void
    typealias ModuleTypeProvider = (String) -> String?
    typealias KeysProvider = (String) -> [String]
    typealias EntryProvider = (String, String) -> String?
    typealias HTMLBuilder = (String, String) -> String?

    private let defaults: UserDefaults
    private let moduleProvider: ModuleProvider
    private let moduleLoader: ModuleLoader
    private let moduleTypeProvider: ModuleTypeProvider
    private let keysProvider: KeysProvider
    private let entryProvider: EntryProvider
    private let htmlBuilder: HTMLBuilder

    init(
        defaults: UserDefaults = .standard,
        moduleProvider: @escaping ModuleProvider = {
            PSModuleController.default()?.primaryDictionaryName
        },
        moduleLoader: @escaping ModuleLoader = {
            PSModuleController.default()?.loadPrimaryDictionary($0)
        },
        moduleTypeProvider: @escaping ModuleTypeProvider = {
            PSContentStore.shared?.moduleMeta($0, key: "type")
        },
        keysProvider: @escaping KeysProvider = {
            PSContentReader.allKeys(module: $0)
        },
        entryProvider: @escaping EntryProvider = {
            PSContentReader.entry(module: $0, key: $1)
        },
        // The entry's own HTML (`EntryTextView` renders it natively), so this is
        // an identity pass. The seam exists because the tests inject through it.
        htmlBuilder: @escaping HTMLBuilder = { body, _ in body }
    ) {
        self.defaults = defaults
        self.moduleProvider = moduleProvider
        self.moduleLoader = moduleLoader
        self.moduleTypeProvider = moduleTypeProvider
        self.keysProvider = keysProvider
        self.entryProvider = entryProvider
        self.htmlBuilder = htmlBuilder
    }

    func snapshot() -> DictionarySnapshot {
        var module = moduleProvider()
        if let current = module, !BundledModules.lexicons.contains(current) {
            module = nil
        }
        if module == nil {
            let stored = defaults.string(forKey: Defaults.lastDictionary)
            if let stored, BundledModules.lexicons.contains(stored) {
                moduleLoader(stored)
                module = stored
            } else if stored != nil {
                defaults.removeObject(forKey: Defaults.lastDictionary)
            }
        }
        return DictionarySnapshot(
            module: module,
            keys: module.map(keysProvider) ?? []
        )
    }

    func select(module: String) -> DictionarySnapshot {
        guard BundledModules.lexicons.contains(module) else {
            return snapshot()
        }
        moduleLoader(module)
        return DictionarySnapshot(
            module: module,
            keys: keysProvider(module)
        )
    }

    func entry(module: String, key: String) -> DictionaryEntryDocument {
        let rawDescription: String
        if moduleTypeProvider(module) == "Lexicons / Dictionaries" {
            rawDescription = entryProvider(module, key) ?? ""
        } else {
            let notInstalled = String(
                localized: "ModuleNotInstalled",
                comment: "A referenced module is not installed."
            )
            rawDescription = "<span style=\"color:grey;text-align:center;"
                + "font-style:italic;\">\(module) \(notInstalled)</span>"
        }
        // The entry as stored, with nothing around it. `PSEntryDocumentBuilder`
        // drops an entry's own key anchor only when the anchor is the FIRST thing
        // in its input, so the WebView page's shell (a bold key line in front,
        // three `&nbsp;` paragraphs behind) made every Strong's entry show its
        // number twice and end in three hard spaces. The key needs no line of its
        // own in the body: it is the navigation title directly above.
        let body = rawDescription
        return DictionaryEntryDocument(
            module: module,
            key: key,
            html: htmlBuilder(body, module) ?? body
        )
    }
}

struct HistoryEntry: Identifiable, Equatable {
    struct ID: Hashable {
        let reference: String?
        let moduleName: String?
        let dateAdded: Date?
    }

    let id: ID
    let reference: String?
    let scrollAmount: String?
    let moduleName: String?
    let dateAdded: Date?

    init(item: PSHistoryItem) {
        reference = item.bibleReference
        scrollAmount = item.scrollAmount
        moduleName = item.moduleName
        dateAdded = item.dateAdded
        id = ID(
            reference: item.bibleReference,
            moduleName: item.moduleName,
            dateAdded: item.dateAdded
        )
    }
}

protocol HistoryCloudStoring: AnyObject {
    func array(forKey defaultName: String) -> [Any]?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: HistoryCloudStoring {}

final class HistoryStore {
    /// Resolves the module name to record for a reading mode. Injectable for the
    /// same reason `defaults` is: `PSModuleController` is a singleton over
    /// `UserDefaults.standard`, so a test cannot otherwise control what
    /// `addEntry` writes into the module slot.
    typealias ModuleNameProvider = (ReadingMode) -> String?

    private let defaults: UserDefaults
    private let cloudStore: HistoryCloudStoring
    private let notificationCenter: NotificationCenter
    private let moduleNameProvider: ModuleNameProvider
    private var cloudObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        cloudStore: HistoryCloudStoring = NSUbiquitousKeyValueStore.default,
        notificationCenter: NotificationCenter = .default,
        moduleNameProvider: @escaping ModuleNameProvider = { mode in
            switch mode {
            case .bible:
                PSModuleController.default()?.primaryBibleName
            case .commentary:
                PSModuleController.default()?.primaryCommentaryName
            }
        }
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.notificationCenter = notificationCenter
        self.moduleNameProvider = moduleNameProvider
    }

    deinit {
        stopCloudSync()
    }

    func snapshot() -> [HistoryEntry] {
        (defaults.array(forKey: AppConstants.historyName) ?? []).compactMap {
            guard let array = $0 as? [Any],
                  let item = PSHistoryItem(array: array) else {
                return nil
            }
            return HistoryEntry(item: item)
        }
    }

    /// Records the reference currently being read.
    ///
    /// The **serialized shape must not change** — `[ref, "0", mod, NSDate]`,
    /// positional, with `"0"` a literal string standing in for a scroll amount
    /// that has never been written. `PersistedFormatTests` locks it.
    ///
    /// Three quirks are preserved deliberately:
    ///
    ///  1. **The de-duplication scans for the first match and stops.** It compares
    ///     the reference, then treats a row with no module as matching any module,
    ///     which is how pre-1.4 rows (written without one) get replaced rather
    ///     than accumulating.
    ///  2. **The cap uses `>=`**, so the list settles at 99 entries rather than
    ///     `historyMaxEntries` = 100. Off by one, and persisted; changing it would
    ///     make one extra row appear for every user on upgrade.
    ///  3. **No entry is written at all when the relevant module is absent.**
    func addEntry(mode: ReadingMode) {
        var history = defaults.array(forKey: AppConstants.historyName)
            .map { NSMutableArray(array: $0) }

        let verse: String?
        let module: String?
        switch mode {
        case .bible:
            verse = defaults.string(forKey: Defaults.bibleVersePosition)
            module = moduleNameProvider(.bible)
        case .commentary:
            verse = defaults.string(forKey: Defaults.commentaryVersePosition)
            module = moduleNameProvider(.commentary)
        }
        guard let module else { return }

        // The chapter reference comes from THIS store's `defaults`, not from
        // `PSModuleController.getCurrentBibleRef()` (which always reads
        // `UserDefaults.standard`), so an injected test suite is honoured.
        let chapterRef = PSRefHelper.createRefString(
            defaults.string(forKey: Defaults.lastRef) ?? "Genesis 1"
        )
        let reference = "\(chapterRef):\(verse ?? "")"
        let entry: [Any] = [reference, "0" /* scroll */, module, Date()]

        if history == nil {
            history = NSMutableArray()
            // Seeding the persistent domain makes the key exist before the first
            // `set`. Kept: `setPersistentDomain` also flushes, and removing it
            // changes when the file first appears. ONLY for the app's own
            // store: these two calls address the domain by NAME whichever
            // instance they are made on, so through an injected store they
            // replaced the app's real `bibleHistory` with an empty array — a
            // run of the unit tests emptied the history of the install hosting
            // them. An injected store still gets its key from the `set` below.
            if defaults === UserDefaults.standard {
                let bundleId = Bundle.main.bundleIdentifier ?? ""
                var preferences = defaults.persistentDomain(forName: bundleId) ?? [:]
                preferences[AppConstants.historyName] = history
                defaults.setPersistentDomain(preferences, forName: bundleId)
            }
        } else if let history {
            for index in 0..<history.count {
                guard let existing = history[index] as? [Any],
                      !existing.isEmpty,
                      reference == existing[0] as? String else {
                    continue
                }
                let existingModule = existing.count > 2
                    ? existing[2] as? String
                    : nil
                if existingModule == nil || module == existingModule {
                    history.removeObject(at: index)
                    break
                }
            }
        }

        guard let history else { return }
        history.insert(entry, at: 0)
        if history.count >= AppConstants.historyMaxEntries {
            history.removeLastObject()
        }

        defaults.set(history, forKey: AppConstants.historyName)
        defaults.synchronize()
        cloudStore.set(history, forKey: AppConstants.historyName)
        notificationCenter.post(name: .historyChanged, object: nil)
    }

    @discardableResult
    func remove(at index: Int, notify: Bool = true) -> Bool {
        var history = defaults.array(forKey: AppConstants.historyName) ?? []
        guard history.indices.contains(index) else {
            return false
        }
        history.remove(at: index)
        persist(history, notify: notify)
        return true
    }

    @discardableResult
    func remove(id: HistoryEntry.ID, notify: Bool = true) -> Bool {
        guard let index = snapshot().firstIndex(where: { $0.id == id }) else {
            return false
        }
        return remove(at: index, notify: notify)
    }

    func clear() {
        defaults.removeObject(forKey: AppConstants.historyName)
        defaults.synchronize()
        cloudStore.removeObject(forKey: AppConstants.historyName)
        cloudStore.set([], forKey: AppConstants.historyName)
        notificationCenter.post(name: .historyChanged, object: nil)
    }

    func startCloudSync() {
        guard cloudObserver == nil else {
            return
        }
        cloudObserver = notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            self?.handleExternalCloudChange(notification)
        }
        // AFTER the observer is in place: this asks for the changes that arrived
        // while the app was not running, and the system reports them through
        // the notification above. Without it a launch keeps its stale local
        // list, and the next `addEntry` writes that list over the entries the
        // other device made. Returns false with no iCloud entitlement
        // (Debug/Release), where it does nothing.
        cloudStore.synchronize()
    }

    func stopCloudSync() {
        guard let cloudObserver else {
            return
        }
        notificationCenter.removeObserver(cloudObserver)
        self.cloudObserver = nil
    }

    func handleExternalCloudChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonNumber = userInfo[
                NSUbiquitousKeyValueStoreChangeReasonKey
              ] as? NSNumber else {
            return
        }

        let reason = reasonNumber.intValue
        guard reason == NSUbiquitousKeyValueStoreServerChange
                || reason == NSUbiquitousKeyValueStoreInitialSyncChange else {
            return
        }

        let changedKeys = userInfo[
            NSUbiquitousKeyValueStoreChangedKeysKey
        ] as? [String] ?? []
        guard changedKeys.contains(AppConstants.historyName) else {
            return
        }

        synchronizeFromCloud(
            initialSync: reason == NSUbiquitousKeyValueStoreInitialSyncChange
        )
    }

    func synchronizeFromCloud(initialSync: Bool) {
        let cloudHistory = PSHistoryItem.parseHistoryArrayArray(
            cloudStore.array(forKey: AppConstants.historyName)
        )
        let localHistory = NSMutableArray(
            array: PSHistoryItem.parseHistoryArrayArray(
                defaults.array(forKey: AppConstants.historyName)
            ) ?? []
        )
        let cloudHistoryCopy = NSMutableArray(array: cloudHistory ?? [])

        if PSHistoryItem.arraysAreEqual(
            cloudHistory,
            secondArray: localHistory as? [Any]
        ) {
            dlog("\ninitial arrays are equal, don't need to do anything! :)")
            return
        }

        let history: NSMutableArray
        if initialSync {
            initialSynchronize(
                withCloud: cloudHistoryCopy as? [Any],
                withLocalHistory: localHistory as? [Any]
            )
            return
        } else if cloudHistory == nil || cloudHistory?.isEmpty == true {
            dlog("\ndeleting local history due to iCloud deletion")
            defaults.removeObject(forKey: AppConstants.historyName)
            defaults.synchronize()
            notificationCenter.post(name: .historyChanged, object: nil)
            return
        } else if localHistory.count == 0 {
            dlog(
                "\nlocal history was blank, but we now need to update it "
                    + "from the changed iCloud version."
            )
            history = cloudHistoryCopy
        } else {
            history = NSMutableArray(
                array: Self.synchronizeHistoryArray(
                    cloudHistoryCopy,
                    with: localHistory
                ) ?? []
            )
        }

        sortDeduplicateAndCap(history)
        let combinedHistory = PSHistoryItem.arrayArray(
            fromHistoryItems: history as? [Any]
        )
        persistLocal(combinedHistory)

        if PSHistoryItem.arraysAreEqual(
            cloudHistory,
            secondArray: history as? [Any]
        ) {
            dlog(
                "\nOur new local history now equals the iCloud version, "
                    + "so don't re-update the cloud copy :P"
            )
            return
        }

        dlog(
            "\nAfter our sync, we have a new history item & so we need "
                + "to update the iCloud version as well..."
        )
        cloudStore.set(
            combinedHistory ?? [],
            forKey: AppConstants.historyName
        )
    }

    func initialSynchronize(
        withCloud cloudHistory: [Any]?,
        withLocalHistory localHistory: [Any]?
    ) {
        let history = NSMutableArray(array: localHistory ?? [])
        history.addObjects(from: cloudHistory ?? [])
        sortDeduplicateAndCap(history)

        let combinedHistory = PSHistoryItem.arrayArray(
            fromHistoryItems: history as? [Any]
        )
        persistLocal(combinedHistory)

        if PSHistoryItem.arraysAreEqual(
            cloudHistory,
            secondArray: history as? [Any]
        ) {
            return
        }
        cloudStore.set(
            combinedHistory ?? [],
            forKey: AppConstants.historyName
        )
    }

    static func synchronizeHistoryArray(
        _ firstArray: NSMutableArray?,
        with secondArray: NSMutableArray?
    ) -> [Any]? {
        guard let firstArray,
              let secondArray,
              firstArray.count != 0,
              secondArray.count != 0 else {
            return nil
        }

        let capacity = firstArray.count > secondArray.count
            ? secondArray.count
            : firstArray.count
        let returnArray = NSMutableArray(capacity: capacity)
        let firstNewest = firstArray[0] as? PSHistoryItem
        let secondNewest = secondArray[0] as? PSHistoryItem

        if firstNewest?.isEqual(to: secondNewest) ?? false {
            dlog("\nhistoryArrays are now (?) equal")
            return (firstArray.count > secondArray.count
                ? secondArray
                : firstArray) as? [Any]
        }

        switch firstNewest?.ageComparison(to: secondNewest) ?? .invalidAge {
        case .older:
            if let secondNewest {
                returnArray.add(secondNewest)
            }
            secondArray.removeObject(at: 0)
            if let rest = synchronizeHistoryArray(
                firstArray,
                with: secondArray
            ) {
                returnArray.addObjects(from: rest)
            }
        case .newer:
            if let firstNewest {
                returnArray.add(firstNewest)
            }
            firstArray.removeObject(at: 0)
            if let rest = synchronizeHistoryArray(
                firstArray,
                with: secondArray
            ) {
                returnArray.addObjects(from: rest)
            }
        default:
            dlog("tie-breaker!")
            if let firstNewest {
                returnArray.add(firstNewest)
            }
            if let secondNewest {
                returnArray.add(secondNewest)
            }
            firstArray.removeObject(at: 0)
            secondArray.removeObject(at: 0)
            if let rest = synchronizeHistoryArray(
                firstArray,
                with: secondArray
            ) {
                returnArray.addObjects(from: rest)
            }
        }

        return returnArray as? [Any]
    }

    private func persist(_ history: [Any], notify: Bool) {
        defaults.set(history, forKey: AppConstants.historyName)
        defaults.synchronize()
        cloudStore.set(history, forKey: AppConstants.historyName)
        if notify {
            notificationCenter.post(name: .historyChanged, object: nil)
        }
    }

    private func persistLocal(_ history: [Any]?) {
        defaults.set(history, forKey: AppConstants.historyName)
        defaults.synchronize()
        notificationCenter.post(name: .historyChanged, object: nil)
    }

    private func sortDeduplicateAndCap(_ history: NSMutableArray) {
        let sortDescriptor = NSSortDescriptor(
            key: "dateAdded",
            ascending: false
        )
        history.sort(using: [sortDescriptor])
        Self.deduplicate(history)
        while history.count >= AppConstants.historyMaxEntries {
            history.removeLastObject()
        }
    }

    private static func deduplicate(_ history: NSMutableArray) {
        var firstIndex = 0
        while firstIndex < history.count {
            let newItem = history[firstIndex] as? PSHistoryItem
            let reference = newItem?.bibleReference
            let module = newItem?.moduleName

            var secondIndex = firstIndex + 1
            while secondIndex < history.count {
                let existingItem = history[secondIndex] as? PSHistoryItem
                if reference == existingItem?.bibleReference,
                   module == existingItem?.moduleName {
                    history.removeObject(at: secondIndex)
                    secondIndex -= 1
                }
                secondIndex += 1
            }
            firstIndex += 1
        }
    }
}

struct SearchOptionsSnapshot: Equatable {
    let fuzzy: Bool
    let matchType: PSSearchType
    let range: PSSearchRange
}

final class SearchOptionsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() -> SearchOptionsSnapshot {
        SearchOptionsSnapshot(
            fuzzy: defaults.bool(forKey: Defaults.lastSearchFuzzy),
            matchType: PSSearchType(
                rawValue: defaults.integer(forKey: Defaults.lastSearchType)
            ) ?? .AndSearch,
            range: PSSearchRange(
                rawValue: defaults.integer(forKey: Defaults.lastSearchRange)
            ) ?? .AllRange
        )
    }

    func save(_ snapshot: SearchOptionsSnapshot) {
        defaults.set(snapshot.fuzzy, forKey: Defaults.lastSearchFuzzy)
        defaults.set(snapshot.matchType.rawValue, forKey: Defaults.lastSearchType)
        defaults.set(snapshot.range.rawValue, forKey: Defaults.lastSearchRange)
    }
}
