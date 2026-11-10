import Foundation
import Observation
import UIKit

enum Workspace: String, CaseIterable, Equatable {
    case read
    case search
    case library
    case settings
}

enum ReadingMode: String, CaseIterable, Equatable {
    case bible
    case commentary
}

/// The session's mirror of the reading position: the reference, the two module
/// names and the two verse positions.
///
/// **Nothing in the app reads it.** The reader takes its position from
/// `UserDefaults` — `PSModuleController.getCurrentBibleRef()` and the
/// `Defaults{Bible,Commentary}VersePosition` keys, through `ReaderPaneModel` —
/// and the pane switch is `ReadingWorkspaceModel.mode`, which mirrors INTO this
/// object rather than out of it. What this type is for is being the assertable
/// statement of what a launch restore and an accepted `sword://` route did:
/// `URLRouterTests.testAppSessionMirrorsAcceptedRoute` and
/// `AppStateStoresTests.testSessionStartRestoresReadingStateAndWiresSettingsEffects`
/// and
/// `AppStateStoresTests.testAppStateResetReloadsTheModelsThatCachedRemovedPreferences`
/// are its only readers.
///
/// `AppSession.handleAppStateReset()` also re-applies the store snapshot into it
/// after a preferences reset — a WRITE, not a read. That write can interleave
/// with the rest of `LaunchCoordinator.prepare()` at launch, and it is harmless
/// only because nothing in the app reads this object. Giving it a production
/// reader would turn that interleave into a real race.
///
/// So keep it a faithful mirror of `ReadingStateStore` — including the arm
/// asymmetry in `apply(_ route:)` below, which looks like a bug and is not — and
/// do not give it a production reader without first deciding which of it and
/// `UserDefaults` is authoritative.
@MainActor
@Observable
final class ReadingModel {
    var mode: ReadingMode
    var reference: BibleReference?
    var bibleModule: String
    var commentaryModule: String
    var bibleVerse: Int
    var commentaryVerse: Int

    init(
        mode: ReadingMode = .bible,
        reference: BibleReference? = nil,
        bibleModule: String = BundledModules.bible,
        commentaryModule: String = BundledModules.commentary,
        bibleVerse: Int = 1,
        commentaryVerse: Int = 1
    ) {
        self.mode = mode
        self.reference = reference
        self.bibleModule = bibleModule
        self.commentaryModule = commentaryModule
        self.bibleVerse = bibleVerse
        self.commentaryVerse = commentaryVerse
    }

    func apply(_ route: URLRoute) {
        reference = route.reference
        let verse = Int(route.versePosition) ?? 1

        switch route.destination {
        case .bible(let module):
            mode = .bible
            // Only the Bible verse. The asymmetry with the `.commentary` arm below
            // is deliberate and mirrors `ReadingStateStore.persist(_:)`, which
            // writes `bibleVersePosition` for every route but
            // `commentaryVersePosition` only for a commentary destination: a
            // bible route leaves the commentary's own verse position alone, in
            // the defaults and therefore here.
            bibleVerse = verse
            if let module {
                bibleModule = module
            }
        case .commentary(let module):
            mode = .commentary
            bibleVerse = verse
            commentaryVerse = verse
            if let module {
                commentaryModule = module
            }
        }
    }

    func apply(_ snapshot: ReadingSnapshot) {
        reference = snapshot.reference
        bibleModule = snapshot.bibleModule
        commentaryModule = snapshot.commentaryModule
        bibleVerse = snapshot.bibleVerse
        commentaryVerse = snapshot.commentaryVerse
    }
}

@MainActor
@Observable
final class SettingsModel {
    var fontName: String {
        didSet {
            guard !isReloading, fontName != oldValue else { return }
            store.saveFontName(fontName)
            onReadingAppearanceChanged?()
        }
    }
    var fontSize: Int {
        didSet {
            guard !isReloading, fontSize != oldValue else { return }
            store.saveFontSize(fontSize)
            onReadingAppearanceChanged?()
        }
    }
    var keepScreenAwake: Bool {
        didSet {
            guard !isReloading, keepScreenAwake != oldValue else { return }
            store.saveKeepScreenAwake(keepScreenAwake)
            onKeepScreenAwakeChanged?(keepScreenAwake)
        }
    }
    var rotationLock: RotationLock {
        didSet {
            guard !isReloading, rotationLock != oldValue else { return }
            store.saveRotationLock(rotationLock)
        }
    }
    var librarySection: LibrarySection {
        didSet {
            guard !isReloading, librarySection != oldValue else { return }
            store.saveLibrarySection(librarySection)
        }
    }
    var fontSizeValue: Double {
        get { Double(fontSize) }
        set { fontSize = Int(newValue) }
    }

    subscript(rotationLockedFor currentOrientation: RotationLock) -> Bool {
        get { rotationLock != .unlocked }
        set {
            rotationLock = newValue ? currentOrientation : .unlocked
        }
    }

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var isReloading = false
    @ObservationIgnored var onReadingAppearanceChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onKeepScreenAwakeChanged: (@MainActor (Bool) -> Void)?

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let snapshot = store.snapshot()
        self.fontName = snapshot.fontName
        self.fontSize = snapshot.fontSize
        self.keepScreenAwake = snapshot.keepScreenAwake
        self.rotationLock = snapshot.rotationLock
        self.librarySection = snapshot.librarySection
    }

    func ensureFontSizeDefault() {
        store.ensureFontSizeDefault()
    }

    func reload() {
        let snapshot = store.snapshot()
        isReloading = true
        fontName = snapshot.fontName
        fontSize = snapshot.fontSize
        keepScreenAwake = snapshot.keepScreenAwake
        rotationLock = snapshot.rotationLock
        librarySection = snapshot.librarySection
        isReloading = false
    }
}

@MainActor
@Observable
final class LibraryModel {
    var bookmarks: [BookmarkNode]
    var history: [HistoryEntry]
    private(set) var dictionaryModule: String?
    private(set) var dictionaryKeys: [String] = []
    private(set) var visibleDictionaryKeys: [String] = []
    var dictionaryQuery = "" {
        didSet {
            guard dictionaryQuery != oldValue else { return }
            filterDictionaryKeys()
        }
    }

    @ObservationIgnored private let bookmarkStore: BookmarkStore
    @ObservationIgnored private let historyStore: HistoryStore
    @ObservationIgnored private let dictionaryStore: DictionaryStore
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(
        bookmarkStore: BookmarkStore = BookmarkStore(),
        historyStore: HistoryStore = HistoryStore(),
        dictionaryStore: DictionaryStore = DictionaryStore(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.bookmarkStore = bookmarkStore
        self.historyStore = historyStore
        self.dictionaryStore = dictionaryStore
        self.notificationCenter = notificationCenter
        self.bookmarks = bookmarkStore.snapshot()
        self.history = historyStore.snapshot()
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    /// Starts refreshing on the two notifications that change this model's data
    /// from outside it: `bookmarksChanged` (the bookmark editor, and the store's
    /// own mutations) and `historyChanged` (a new entry, a clear, or an iCloud
    /// merge).
    func startObservingChanges() {
        guard observers.isEmpty else { return }
        for (name, handler) in [
            (Notification.Name.bookmarksChanged, { [weak self] in
                self?.reloadBookmarks()
            }),
            (Notification.Name.historyChanged, { [weak self] in
                self?.reloadHistory()
            }),
        ] as [(Notification.Name, @MainActor () -> Void)] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { handler() }
            }
            observers.append(observer)
        }
    }

    func reloadBookmarks() {
        bookmarks = bookmarkStore.snapshot()
    }

    func reloadHistory() {
        history = historyStore.snapshot()
    }

    /// Records the reference currently being read. The store posts
    /// `historyChanged`, which refreshes `history` through the observer above.
    func recordHistory(mode: ReadingMode) {
        historyStore.addEntry(mode: mode)
    }

    func bookmarkNode(id: UUID) -> BookmarkNode? {
        findBookmark(id: id, in: bookmarks)
    }

    func bookmarkChildren(in parentID: UUID?) -> [BookmarkNode] {
        guard let parentID,
              let parent = findBookmark(id: parentID, in: bookmarks),
              case .folder(_, let children) = parent.kind else {
            return parentID == nil ? bookmarks : []
        }
        return children
    }

    func addBookmarkFolder(
        name: String,
        color: BookmarkColor?,
        parentID: UUID?
    ) throws {
        try bookmarkStore.addFolder(name: name, color: color, to: parentID)
        reloadBookmarks()
    }

    func renameBookmark(id: UUID, to name: String) throws {
        try bookmarkStore.rename(id: id, to: name)
        reloadBookmarks()
    }

    func updateBookmarkFolder(
        id: UUID,
        name: String,
        color: BookmarkColor?
    ) throws {
        try bookmarkStore.updateFolder(id: id, name: name, color: color)
        reloadBookmarks()
    }

    func removeBookmark(id: UUID) {
        guard bookmarkStore.remove(id: id) else { return }
        reloadBookmarks()
    }

    func reorderBookmarks(
        parentID: UUID?,
        sources: [UUID],
        before destinationID: UUID?
    ) {
        guard bookmarkStore.reorder(
            parentID: parentID,
            sources: sources,
            before: destinationID
        ) else {
            return
        }
        reloadBookmarks()
    }

    func openBookmark(id: UUID) -> String? {
        guard let reference = bookmarkStore.markAccessed(id: id) else {
            return nil
        }
        reloadBookmarks()
        return reference
    }

    func removeHistory(id: HistoryEntry.ID) {
        guard historyStore.remove(id: id) else { return }
        reloadHistory()
    }

    func clearHistory() {
        historyStore.clear()
        reloadHistory()
    }

    func reloadDictionary() {
        apply(dictionaryStore.snapshot())
    }

    func selectDictionary(module: String) {
        dictionaryQuery = ""
        apply(dictionaryStore.select(module: module))
    }

    func dictionaryEntry(key: String) -> DictionaryEntryDocument? {
        guard let dictionaryModule else { return nil }
        return dictionaryStore.entry(module: dictionaryModule, key: key)
    }

    func dictionaryEntry(
        module: String,
        key: String
    ) -> DictionaryEntryDocument {
        dictionaryStore.entry(module: module, key: key)
    }

    private func apply(_ snapshot: DictionarySnapshot) {
        dictionaryModule = snapshot.module
        dictionaryKeys = snapshot.keys
        filterDictionaryKeys()
    }

    private func filterDictionaryKeys() {
        guard !dictionaryQuery.isEmpty else {
            visibleDictionaryKeys = dictionaryKeys
            return
        }
        visibleDictionaryKeys = dictionaryKeys.filter {
            $0.range(of: dictionaryQuery, options: .caseInsensitive) != nil
        }
    }

    /// The `[BookmarkNode]` twin of `BookmarkStore.findObject(id:in:)`.
    ///
    /// Deliberately NOT shared. This walks the immutable `BookmarkNode` PROJECTION
    /// this model already published, so a view resolves an id against exactly the tree
    /// it is rendering; the store's walks the live `PSBookmarkFolder` object graph it
    /// is about to mutate. Routing this through the store would re-read
    /// `PSBookmarks.default()` mid-render and could answer from a tree the view has not
    /// seen yet. The two representations cannot share code without one of them
    /// changing — and the store's is the byte-locked persisted chain.
    private func findBookmark(
        id: UUID,
        in nodes: [BookmarkNode]
    ) -> BookmarkNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if case .folder(_, let children) = node.kind,
               let match = findBookmark(id: id, in: children) {
                return match
            }
        }
        return nil
    }
}

struct SearchResultRow: Identifiable, Equatable {
    var id: String { reference }

    let reference: String
    let text: String?
    let strongsHighlightWords: [String]
}

struct SearchModuleChoice: Identifiable, Equatable {
    let id: String
    let kind: ReadingMode
}

enum SearchIndexState: Equatable {
    case unavailable
    case ready
    case building(progress: Float)
    case cancelling
    case cancelled
    case failed
}

private final class SearchIndexCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@MainActor
@Observable
final class SearchIndexCoordinator {
    typealias FreshnessProvider = (String) -> Bool
    typealias BuildOperation = (String, PSSearchProgressBlock?) throws -> Void

    private(set) var state: SearchIndexState = .unavailable {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    @ObservationIgnored private let freshnessProvider: FreshnessProvider
    @ObservationIgnored private let buildOperation: BuildOperation
    @ObservationIgnored private let buildGate: SearchIndexBuildGate
    @ObservationIgnored private var cancellation: SearchIndexCancellation?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored var onStateChange: (@MainActor (SearchIndexState) -> Void)?
    @ObservationIgnored var onCompletion: (@MainActor (Bool, Bool) -> Void)?

    init(
        freshnessProvider: @escaping FreshnessProvider = {
            PSSearchEngine.engine(forModuleName: $0).indexIsFresh()
        },
        buildGate: SearchIndexBuildGate = .shared,
        buildOperation: @escaping BuildOperation = { module, progress in
            try PSSearchEngine.engine(forModuleName: module).build(progress: progress)
        }
    ) {
        self.freshnessProvider = freshnessProvider
        self.buildGate = buildGate
        self.buildOperation = buildOperation
    }

    var isOperationActive: Bool {
        switch state {
        case .building, .cancelling:
            true
        case .unavailable, .ready, .cancelled, .failed:
            false
        }
    }

    func refresh(module: String?) {
        guard !isOperationActive else { return }
        guard let module else {
            state = .unavailable
            return
        }
        state = freshnessProvider(module) ? .ready : .unavailable
    }

    @discardableResult
    func build(module: String) -> Bool {
        guard operationID == nil else { return false }
        let id = UUID()
        let cancellation = SearchIndexCancellation()
        let operation = buildOperation
        let buildGate = buildGate
        operationID = id
        self.cancellation = cancellation
        state = .building(progress: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buildError: Error?
            do {
                try buildGate.perform {
                    try operation(module) { fraction, cancel in
                        cancel = cancellation.isCancelled
                        DispatchQueue.main.async { [weak self] in
                            self?.updateProgress(fraction, operationID: id)
                        }
                    }
                }
            } catch {
                buildError = error
            }

            let wasCancelled = cancellation.isCancelled
            DispatchQueue.main.async { [weak self] in
                self?.finish(
                    operationID: id,
                    error: buildError,
                    cancelled: wasCancelled
                )
            }
        }
        return true
    }

    func cancel() {
        guard cancellation != nil else { return }
        cancellation?.cancel()
        state = .cancelling
    }

    private func updateProgress(_ progress: Float, operationID: UUID) {
        guard self.operationID == operationID, state != .cancelling else {
            return
        }
        state = .building(progress: progress)
    }

    private func finish(
        operationID: UUID,
        error: Error?,
        cancelled: Bool
    ) {
        guard self.operationID == operationID else { return }
        self.operationID = nil
        cancellation = nil

        if cancelled {
            state = .cancelled
            onCompletion?(false, true)
        } else if let error {
            alog("SearchIndexCoordinator: build failed: \(error)")
            state = .failed
            onCompletion?(false, false)
        } else {
            state = .ready
            onCompletion?(true, false)
        }
    }
}

@MainActor
@Observable
final class SearchModel {
    typealias QueryOperation = (
        _ module: String,
        _ expression: String,
        _ range: PSSearchRange,
        _ bookName: String?,
        _ strongsTokens: [String]?
    ) -> [PSSearchResult]

    var query = "" {
        didSet {
            guard query != oldValue, !isApplyingInternalInputs else { return }
            scheduleSearch()
        }
    }
    var expression: String?
    private(set) var module: String?
    var strongsSearch = false {
        didSet {
            guard strongsSearch != oldValue, !isApplyingInternalInputs else {
                return
            }
            userOptionsDidChange()
        }
    }
    var fuzzySearch: Bool {
        didSet {
            guard fuzzySearch != oldValue, !isApplyingInternalInputs else {
                return
            }
            userOptionsDidChange()
        }
    }
    var matchType: PSSearchType {
        didSet {
            guard matchType != oldValue, !isApplyingInternalInputs else {
                return
            }
            userOptionsDidChange()
        }
    }
    var range: PSSearchRange {
        didSet {
            guard range != oldValue, !isApplyingInternalInputs else { return }
            userOptionsDidChange()
        }
    }
    var bookName: String?
    var results: [SearchResultRow] = []
    private(set) var modules: [SearchModuleChoice] = []
    private(set) var moduleKind: ReadingMode = .bible
    private(set) var strongsAvailable = false
    private(set) var isSearching = false
    private(set) var highlightTerms: [String] = []

    @ObservationIgnored private let optionsStore: SearchOptionsStore
    @ObservationIgnored let indexCoordinator: SearchIndexCoordinator
    @ObservationIgnored private let queryOperation: QueryOperation
    @ObservationIgnored private let featureProvider: (String, String) -> Bool
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored private let indexBuildStarted: (String) -> Void
    @ObservationIgnored private let indexBuildFinished: (String) -> Void
    @ObservationIgnored private var debounceTimer: Timer?
    @ObservationIgnored private var queryGeneration: UInt = 0
    @ObservationIgnored private var isApplyingInternalInputs = false
    @ObservationIgnored private var currentBookName: String?
    /// Announced when a search settles on a new result set, or clears it.
    ///
    /// **Deliberately unwired in production.** The Search workspace is persistent
    /// and keeps its own query and results, so refreshing the reader's copy could
    /// not change anything the user sees. Kept because
    /// `AppStateStoresTests.testSearchModelRejectsAStaleCompletion` uses it as its
    /// completion signal. Wire it only alongside a consumer that reads the result.
    @ObservationIgnored var onHistoryChange: (
        @MainActor (PSSearchHistoryItem?) -> Void
    )?

    init(
        optionsStore: SearchOptionsStore = SearchOptionsStore(),
        indexCoordinator: SearchIndexCoordinator? = nil,
        debounceInterval: TimeInterval = 0.25,
        featureProvider: @escaping (String, String) -> Bool = {
            PSContentStore.shared?.moduleHasFeature($0, $1) ?? false
        },
        queryOperation: @escaping QueryOperation = {
            module,
            expression,
            range,
            bookName,
            strongsTokens in
            PSSearchEngine.engine(forModuleName: module).runQuery(
                expression,
                scope: range,
                bookName: bookName,
                limit: 1000,
                strongsTokens: strongsTokens
            )
        },
        indexBuildStarted: @escaping (String) -> Void = { _ in },
        indexBuildFinished: @escaping (String) -> Void = { _ in }
    ) {
        self.optionsStore = optionsStore
        self.indexCoordinator = indexCoordinator ?? SearchIndexCoordinator()
        self.debounceInterval = debounceInterval
        self.featureProvider = featureProvider
        self.queryOperation = queryOperation
        self.indexBuildStarted = indexBuildStarted
        self.indexBuildFinished = indexBuildFinished
        let options = optionsStore.snapshot()
        self.fuzzySearch = options.fuzzy
        self.matchType = options.matchType
        self.range = options.range
    }

    func configure(
        modules: [SearchModuleChoice],
        preferredModule: String?,
        currentBookName: String?,
        restoring historyItem: PSSearchHistoryItem?
    ) {
        self.modules = modules
        self.currentBookName = currentBookName

        let selected = modules.first(where: { $0.id == module })
            ?? modules.first(where: { $0.id == preferredModule })
            ?? modules.first
        if let selected {
            applyModule(selected, clearExistingResults: module != selected.id)
        } else {
            module = nil
            indexCoordinator.refresh(module: nil)
        }

        if let historyItem {
            restore(historyItem, currentBookName: currentBookName)
        } else {
            updateBookName(currentBookName)
            if !query.isEmpty {
                scheduleSearch(immediate: true)
            }
        }
    }

    /// Seeds a Strong's query from outside the search UI and runs it — the "Find
    /// all occurrences" path.
    ///
    /// Needed because `SearchView` runs `configure(...)` only once per launch, so a
    /// seeded history item would only apply to the first Strong's search.
    ///
    /// Deliberately does NOT read persisted match/fuzzy options: a Strong's lookup
    /// is an exact lemma query, and inheriting a stale "any word" or fuzzy setting
    /// makes it return the wrong thing. It sets the three options the query needs
    /// and leaves the rest alone.
    func startStrongsQuery(_ term: String, currentBookName: String?) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        withInternalInputMutation {
            query = trimmed

            // Strong's mode is ON by definition: the term IS a Strong's number; with
            // the mode off the query searches for the literal text "H430".
            //
            // Do NOT gate this on `strongsAvailable` alone: it is only resolved by
            // `applyModule` (from `configure(...)`), and this can run before the Search
            // workspace has ever appeared, when the flag is still `false`. If the
            // module is already resolved its capability is checked here; if not,
            // `applyModule` clears the mode during `configure(...)` before the search
            // runs.
            strongsSearch = module == nil || strongsAvailable
        }

        self.currentBookName = currentBookName
        updateBookName(currentBookName)
        // Re-check freshness: the index may have been built (or dropped) since the
        // last time this model looked, and `scheduleSearch` refuses to run unless
        // the coordinator says `.ready`.
        indexCoordinator.refresh(module: module)
        scheduleSearch(immediate: true)
    }

    func selectModule(_ choice: SearchModuleChoice) {
        guard module != choice.id, !indexCoordinator.isOperationActive else {
            return
        }
        applyModule(choice, clearExistingResults: true)
        if !query.isEmpty, indexCoordinator.state == .ready {
            scheduleSearch(immediate: true)
        }
    }

    private func userOptionsDidChange() {
        // `module != nil` is load-bearing: `strongsAvailable` is only resolved once
        // `applyModule` has run, so before then it is `false` and this must not clear
        // a mode the caller deliberately seeded.
        if strongsSearch, module != nil, !strongsAvailable {
            withInternalInputMutation {
                strongsSearch = false
            }
        }
        updateBookName(currentBookName)
        persistOptions()
        scheduleSearch()
    }

    func persistOptions() {
        optionsStore.save(
            SearchOptionsSnapshot(
                fuzzy: fuzzySearch,
                matchType: matchType,
                range: range
            )
        )
    }

    func setResults(_ rawResults: [PSSearchResult]) {
        results = rawResults.map {
            SearchResultRow(
                reference: $0.reference,
                text: $0.fullText,
                strongsHighlightWords: $0.strongsHighlightWords ?? []
            )
        }
    }

    func clearResults() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        queryGeneration &+= 1
        isSearching = false
        expression = nil
        results = []
        highlightTerms = []
    }

    func searchNow() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        runSearch()
    }

    func startIndexBuild() {
        guard let module, !indexCoordinator.isOperationActive else { return }
        indexBuildStarted(module)
        indexCoordinator.onCompletion = { [weak self] success, _ in
            guard let self else { return }
            self.indexBuildFinished(module)
            guard self.module == module else {
                self.indexCoordinator.refresh(module: self.module)
                return
            }
            if success {
                self.scheduleSearch(immediate: true)
            }
        }
        if !indexCoordinator.build(module: module) {
            indexBuildFinished(module)
        }
    }

    func cancelIndexBuild() {
        indexCoordinator.cancel()
    }

    func historyItem() -> PSSearchHistoryItem? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        let item = PSSearchHistoryItem(
            searchTermToDisplay: query,
            strongs: strongsSearch,
            fuzzy: fuzzySearch,
            type: matchType,
            range: range,
            book: range == .BookRange ? bookName : nil
        )
        let entries = NSMutableArray(capacity: results.count)
        for result in results {
            entries.add(
                PSVerseTextEntry(
                    key: result.reference,
                    text: result.text
                )
            )
        }
        item?.results = entries
        return item
    }

    static func highlightTerms(
        query: String,
        matchType: PSSearchType,
        strongs: Bool
    ) -> [String] {
        guard !strongs, !query.isEmpty else { return [] }
        if matchType == .ExactSearch {
            return query.count >= 2 ? [query] : []
        }

        var terms: [String] = []
        let characters = Array(query.utf16)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == 0x20 || character == 0x09 || character == 0x0A {
                index += 1
                continue
            }
            if character == 0x22 {
                index += 1
                let start = index
                while index < characters.count, characters[index] != 0x22 {
                    index += 1
                }
                let phrase = String(
                    utf16CodeUnits: Array(characters[start..<index]),
                    count: index - start
                )
                if index < characters.count {
                    index += 1
                }
                if phrase.utf16.count >= 2 {
                    terms.append(phrase)
                }
            } else {
                let start = index
                while index < characters.count {
                    let value = characters[index]
                    if value == 0x20 || value == 0x09
                        || value == 0x0A || value == 0x22 {
                        break
                    }
                    index += 1
                }
                let word = String(
                    utf16CodeUnits: Array(characters[start..<index]),
                    count: index - start
                )
                if word.utf16.count >= 2 {
                    terms.append(word)
                }
            }
        }
        return terms
    }

    private func applyModule(
        _ choice: SearchModuleChoice,
        clearExistingResults: Bool
    ) {
        module = choice.id
        moduleKind = choice.kind
        strongsAvailable = featureProvider(choice.id, "Strongs")
            || featureProvider(choice.id, "StrongsNumbers")
        if !strongsAvailable {
            withInternalInputMutation {
                strongsSearch = false
            }
        }
        if clearExistingResults {
            clearResults()
        }
        indexCoordinator.refresh(module: choice.id)
    }

    private func restore(
        _ historyItem: PSSearchHistoryItem,
        currentBookName: String?
    ) {
        withInternalInputMutation {
            query = historyItem.cleanedDisplayTerm()
            fuzzySearch = historyItem.fuzzySearch
            matchType = historyItem.searchType
            range = historyItem.searchRange
            strongsSearch = historyItem.strongsSearch && strongsAvailable
        }
        bookName = range == .BookRange
            ? (historyItem.bookName ?? currentBookName)
            : nil

        let restoredRows: [SearchResultRow] = historyItem.results?.compactMap {
            element -> SearchResultRow? in
            guard let entry = element as? PSVerseTextEntry,
                  let reference = entry.key else {
                return nil
            }
            return SearchResultRow(
                reference: reference,
                text: entry.text,
                strongsHighlightWords: []
            )
        } ?? []
        results = restoredRows
        expression = PSSearchQuery.fts5Expression(
            fromUserInput: query,
            matchType: matchType,
            fuzzy: fuzzySearch,
            strongs: strongsSearch
        )
        highlightTerms = Self.highlightTerms(
            query: query,
            matchType: matchType,
            strongs: strongsSearch
        )
        persistOptions()

        if !query.isEmpty, indexCoordinator.state == .ready {
            scheduleSearch(immediate: true)
        }
    }

    private func updateBookName(_ currentBookName: String?) {
        bookName = range == .BookRange ? currentBookName : nil
    }

    // MARK: - Input provenance

    /// Model-originated writes are grouped explicitly so their property observers do
    /// not look like user edits. User binding writes run their side effects
    /// synchronously in `didSet`, so a later model sync cannot make a real change
    /// look like an `.onChange` echo.
    private func withInternalInputMutation(_ mutation: () -> Void) {
        let wasApplyingInternalInputs = isApplyingInternalInputs
        isApplyingInternalInputs = true
        mutation()
        isApplyingInternalInputs = wasApplyingInternalInputs
    }

    private func scheduleSearch(immediate: Bool = false) {
        debounceTimer?.invalidate()
        debounceTimer = nil
        queryGeneration &+= 1

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            expression = nil
            results = []
            highlightTerms = []
            onHistoryChange?(nil)
            return
        }
        guard indexCoordinator.state == .ready else {
            isSearching = false
            return
        }
        if immediate || debounceInterval == 0 {
            runSearch()
            return
        }

        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: debounceInterval,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.runSearch()
            }
        }
    }

    private func runSearch() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        guard let module, indexCoordinator.state == .ready else {
            isSearching = false
            return
        }

        // Sticky Strong's mode, cleared when the text stops looking like a lemma
        // (a plain word searched with the mode on hits the lemmas column and
        // returns zero rows). A model-originated write, marked as such.
        if strongsSearch && !Self.inputLooksLikeStrongs(query) {
            withInternalInputMutation {
                strongsSearch = false
            }
        }
        guard let expression = PSSearchQuery.fts5Expression(
            fromUserInput: query,
            matchType: matchType,
            fuzzy: fuzzySearch,
            strongs: strongsSearch
        ), !expression.isEmpty else {
            clearResults()
            return
        }

        self.expression = expression
        highlightTerms = Self.highlightTerms(
            query: query,
            matchType: matchType,
            strongs: strongsSearch
        )
        let capturedRange = range
        let capturedBookName = bookName
        let capturedStrongsTokens = strongsSearch
            ? PSSearchQuery.strongsTokens(fromUserInput: query)
            : nil
        let operation = queryOperation

        queryGeneration &+= 1
        let generation = queryGeneration
        isSearching = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rawResults = operation(
                module,
                expression,
                capturedRange,
                capturedBookName,
                capturedStrongsTokens
            )
            DispatchQueue.main.async {
                guard let self, self.queryGeneration == generation else {
                    return
                }
                self.isSearching = false
                self.setResults(rawResults)
                self.onHistoryChange?(self.historyItem())
            }
        }
    }

    private static func inputLooksLikeStrongs(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        for token in trimmed.components(separatedBy: .whitespaces) {
            let units = Array(token.utf16)
            guard units.count >= 2 else { continue }
            let prefix = units[0]
            guard prefix == 0x48 || prefix == 0x47
                    || prefix == 0x68 || prefix == 0x67 else {
                continue
            }
            if units.dropFirst().allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                return true
            }
        }
        return false
    }
}

@MainActor
@Observable
final class AppSession {
    private var workspaceSelection: Workspace
    var selectedWorkspace: Workspace {
        get { workspaceSelection }
        set {
            if workspaceSelection == .search, newValue == .search {
                searchFocusRequest &+= 1
            }
            // Leaving Search puts the keyboard away FIRST, before the selection
            // moves, so the workspace being shown is never laid out against it.
            //
            // Left up, the keyboard is still part of the safe area when the next
            // workspace appears: the reader is laid out at the keyboard's height
            // and then again at its own, which `ReaderScreen`'s size hook takes
            // for a rotation — and re-anchors on the offset the reader held
            // before. Opening a search result that way (type, tap) left the reader
            // where it had been, under the result's reference in the title.
            // MEASURED, iOS 27.2: 390x442 then 390x660, the hook firing twice.
            // Pinned by `testOpeningASearchResultWithTheKeyboardUpLandsOnItsVerse`.
            //
            // The query, its results and the options are untouched; reselecting
            // the Search tab focuses the field again (`searchFocusRequest`).
            if workspaceSelection == .search, newValue != .search {
                dismissKeyboard()
            }
            workspaceSelection = newValue
        }
    }
    private(set) var searchFocusRequest: UInt = 0
    /// The last `sword://` URL this session accepted.
    ///
    /// **Write-only in production, deliberately**: the assertable record of what a
    /// route did, read by `URLRouterTests.testAppSessionMirrorsAcceptedRoute`. It
    /// LATCHES the most recent URL for the rest of the session; do not give it a
    /// production reader without first deciding when it should be cleared.
    var lastOpenedURL: URL?
    @ObservationIgnored let reading: ReadingModel
    @ObservationIgnored let settings: SettingsModel
    @ObservationIgnored let library: LibraryModel
    @ObservationIgnored let search: SearchModel

    /// The reading workspace, wired in once it exists. Weak because the workspace
    /// holds the session; this is the back-edge.
    @ObservationIgnored weak var readingWorkspace: ReadingWorkspaceModel?

    @ObservationIgnored private let readingStore: ReadingStateStore
    /// A `sword://` URL that arrived before launch preparation finished, replayed
    /// from `replayPendingURL()`.
    ///
    /// `onOpenURL` can fire while `LaunchPhase` is still `.preparing`, and routing
    /// then would render a chapter the `DefaultsLastRefValidated` migration is
    /// about to rewrite.
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var isReady = false
    /// The `.appStateDidReset` observer. Held so it can be removed, and so a
    /// second `start()` cannot register a second handler.
    @ObservationIgnored private var resetObserver: NSObjectProtocol?
    /// Resigns whichever control has the keyboard. Injected so the rule in
    /// `selectedWorkspace`'s setter is assertable without a window.
    @ObservationIgnored private let dismissKeyboard: @MainActor () -> Void

    init(
        selectedWorkspace: Workspace = .read,
        lastOpenedURL: URL? = nil,
        reading: ReadingModel? = nil,
        settings: SettingsModel? = nil,
        library: LibraryModel? = nil,
        search: SearchModel? = nil,
        readingStore: ReadingStateStore = ReadingStateStore(),
        dismissKeyboard: (@MainActor () -> Void)? = nil
    ) {
        self.workspaceSelection = selectedWorkspace
        self.lastOpenedURL = lastOpenedURL
        self.reading = reading ?? ReadingModel()
        self.settings = settings ?? SettingsModel()
        self.library = library ?? LibraryModel()
        self.search = search ?? SearchModel()
        self.readingStore = readingStore
        self.dismissKeyboard = dismissKeyboard ?? {
            // To the first responder, whichever view that is: the search field is
            // SwiftUI's, and this model has no reference to it.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }

    deinit {
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
        }
    }

    /// Wires the settings side effects: a font/size change posts the redisplay
    /// the reader observes, and the keep-awake toggle sets the idle timer.
    func start() {
        settings.onReadingAppearanceChanged = {
            NotificationCenter.default.post(
                name: .resetBibleAndCommentaryView,
                object: nil
            )
        }
        settings.onKeepScreenAwakeChanged = { value in
            UIApplication.shared.isIdleTimerDisabled = value
        }
        // Materializes the font-size default (12) so the Settings slider has a
        // value to sit at rather than snapping from 0 on first drag.
        settings.ensureFontSizeDefault()
        library.startObservingChanges()
        reading.apply(readingStore.snapshot())
        observeAppStateReset()
    }

    /// Starts listening for `LaunchCoordinator.resetPreferences()`, which removes
    /// `fontNamePreference`, `fontSizePreference`, `insomniaPreference`,
    /// `bibleHistory` and more out from under models that have cached them.
    ///
    /// Two things about the wiring are load-bearing:
    ///
    ///  - **The `.appStateDidReset` post comes after every removal** in
    ///    `resetPreferences()` and after the module selections are re-resolved (only
    ///    the `.redisplayPrimaryBible` post follows it), so this handler reads
    ///    post-reset state and needs no ordering of its own. At launch the
    ///    *remaining* migrations in `prepare()` still run alongside it on the
    ///    detached task; none of them touches what this re-reads.
    ///  - **`queue: .main`.** The launch path runs `prepare()` — and therefore
    ///    `resetPreferences()` — off the main actor, while everything reloaded here
    ///    is `@MainActor`. `queue: nil` would run the block synchronously on that
    ///    background thread.
    ///
    /// `start()` runs from `didFinishLaunching`, which precedes `RootView`'s
    /// `.task`, so the observer is always in place before a reset can post.
    private func observeAppStateReset() {
        guard resetObserver == nil else { return }
        resetObserver = NotificationCenter.default.addObserver(
            forName: .appStateDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleAppStateReset()
            }
        }
    }

    /// Re-reads every cached preference the reset cleared.
    ///
    /// **`SettingsModel.reload()` rather than five assignments.** Each of those
    /// properties persists itself from `didSet`; `reload()` brackets the writes with
    /// `isReloading` so none of them writes back. Assigning them one by one would
    /// re-create exactly the keys the reset had just deleted.
    ///
    /// `onKeepScreenAwakeChanged` is suppressed along with the saves, so the idle
    /// timer is applied here explicitly.
    func handleAppStateReset() {
        // Re-materializes the font-size default exactly as `start()` does, so the
        // post-reset state equals the fresh-install state and the Settings slider
        // has a value to sit at.
        settings.ensureFontSizeDefault()
        settings.reload()
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake

        // `bibleHistory` was removed and nothing posts `historyChanged` for it;
        // `lastDictionary` was removed and the primary dictionary cleared; `lastRef`
        // / `lastBible` / `lastCommentary` were removed under `reading`.
        library.reloadHistory()
        library.reloadDictionary()
        reading.apply(readingStore.snapshot())

        // The per-module display toggles went too, and the chrome MIRRORS their
        // values (`ReaderChromeModel.displayToggleValues`) rather than reading them
        // live, so the overflow menu would keep showing checkmarks for prefs that no
        // longer exist. `redisplayPrimaryBible` — which `resetPreferences()` also
        // posts — re-renders the text but does not rebuild the rows.
        readingWorkspace?.bible.refreshForModuleChange()
        readingWorkspace?.commentary.refreshForModuleChange()
    }

    /// Routes an incoming `sword://` URL, or defers it if launch is still running.
    ///
    /// Two things look incidental and are not:
    ///
    ///  - **A URL the parser cannot resolve is ignored**, not guessed at: no
    ///    navigation, no history entry, one `alog` line from `URLRouter`.
    ///  - **The persist happens before the redisplay, and the pane switch drops the
    ///    target pane's stale deferral.** `readingStore.persist` writes `lastRef` and
    ///    the verse position; `redisplayPrimary*` renders from them and
    ///    `HistoryStore.addEntry` reads `lastRef` back. Reversing the order renders
    ///    the previous chapter — and so does a bare `mode` flip, because `mode`'s
    ///    `didSet` drains the target pane's `refToShow` and `ReaderPaneModel.render`
    ///    rewrites `lastRef` from it. That is what `showRoutedMode(_:)` prevents; do
    ///    not shorten it back to `mode = …`.
    @discardableResult
    func open(_ url: URL?) -> Bool {
        guard isReady else {
            pendingURL = url
            return false
        }
        guard let route = URLRouter()?.route(for: url) else {
            return false
        }

        lastOpenedURL = route.sourceURL
        selectedWorkspace = .read
        reading.apply(route)
        readingStore.persist(route)

        switch route.destination {
        case .bible(let module):
            if let module {
                PSModuleController.default()?.loadPrimaryBible(module)
            }
            readingWorkspace?.showRoutedMode(.bible)
            NotificationCenter.default.post(
                name: .redisplayPrimaryBible,
                object: nil
            )
            library.recordHistory(mode: .bible)
        case .commentary(let module):
            if let module {
                PSModuleController.default()?.loadPrimaryCommentary(module)
            }
            readingWorkspace?.showRoutedMode(.commentary)
            NotificationCenter.default.post(
                name: .redisplayPrimaryCommentary,
                object: nil
            )
            library.recordHistory(mode: .commentary)
        }

        return true
    }

    /// Opens the launch URL held back during preparation, if there was one. Called
    /// once, from the `.ready` transition.
    func replayPendingURL() {
        isReady = true
        guard let url = pendingURL else { return }
        pendingURL = nil
        open(url)
    }

    func apply(_ route: URLRoute) {
        selectedWorkspace = .read
        lastOpenedURL = route.sourceURL
        reading.apply(route)
    }
}
