import SwiftUI
import Observation

struct DictionaryView: View {
    let library: LibraryModel
    /// Handed on to the entry screen, which is the only thing here that reads it.
    /// Holding the reference subscribes nothing.
    let settings: SettingsModel
    /// The Library workspace's section switch, hosted in this view's own toolbar.
    /// Each section owns its `NavigationStack`, so the picker has to be declared
    /// inside each of them — see `LibraryWorkspace`.
    @Binding var section: LibrarySection

    var body: some View {
        @Bindable var library = library

        NavigationStack {
            DictionaryKeyList(library: library)
                // Value-based navigation: the entry is loaded HERE, on push,
                // not when a row is realized — see `DictionaryKeyList`.
                // `String` is unambiguous in this stack: it declares no other
                // typed destination, and `DictionaryEntryView` resolves its
                // cross-links in place rather than pushing another screen.
                .navigationDestination(for: String.self) { key in
                    if let entry = library.dictionaryEntry(key: key) {
                        DictionaryEntryView(
                            initialEntry: entry,
                            library: library,
                            settings: settings
                        )
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $library.dictionaryQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("DictionarySearchPlaceholderText")
                )
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        LibrarySectionPicker(section: $section)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        DictionaryModuleMenu(library: library)
                    }
                }
                .task {
                    library.reloadDictionary()
                }
        }
    }
}

private struct DictionaryKeyList: View {
    let library: LibraryModel

    var body: some View {
        List {
            if library.dictionaryModule == nil {
                ContentUnavailableView(
                    "DictionaryNoneLoaded",
                    systemImage: "books.vertical"
                )
                .listRowBackground(Color.clear)
            } else if library.visibleDictionaryKeys.isEmpty {
                ContentUnavailableView.search(text: library.dictionaryQuery)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(library.visibleDictionaryKeys, id: \.self) { key in
                    // `NavigationLink(value:)`, NOT the destination-closure form: a
                    // `@ViewBuilder` destination is built when the ROW is realized, which
                    // would run a `dictEntry` lookup (SQLite read + zlib inflate, on the
                    // main actor) for every row scrolled past — 8,674 in Strong's Hebrew.
                    // The row carries its own KEY, never an index into a list the search
                    // field is narrowing; `navigationDestination` resolves it on push.
                    NavigationLink(value: key) {
                        Text(key)
                    }
                    .accessibilityIdentifier("dictionary.key.\(key)")
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct DictionaryModuleMenu: View {
    let library: LibraryModel

    var body: some View {
        Menu {
            ForEach(DictionaryModuleChoice.all) { choice in
                Button {
                    library.selectDictionary(module: choice.id)
                } label: {
                    Label {
                        Text(choice.title)
                    } icon: {
                        if library.dictionaryModule == choice.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier("dictionary.module.\(choice.id)")
            }
        } label: {
            Image(systemName: "books.vertical")
        }
        .accessibilityLabel(Text("TabBarTitleDictionary"))
        .accessibilityIdentifier("dictionary.module-menu")
    }
}

private struct DictionaryModuleChoice: Identifiable {
    let id: String
    let title: String

    static let all = [
        DictionaryModuleChoice(
            id: BundledModules.strongsGreek,
            title: "Strong's Greek"
        ),
        DictionaryModuleChoice(
            id: BundledModules.strongsHebrew,
            title: "Strong's Hebrew"
        ),
        DictionaryModuleChoice(
            id: BundledModules.morphGreek,
            title: "Robinson"
        ),
    ]
}

private struct DictionaryEntryView: View {
    let library: LibraryModel
    let settings: SettingsModel

    /// Caches the parse of the entry currently on screen, keyed by its identity.
    ///
    /// A reference type held in `@State`, deliberately:
    ///
    /// - Not on `DictionaryEntryDocument`: it is a value type whose synthesized
    ///   `Equatable` must not grow a non-equatable memo.
    /// - Not in `body`: that re-runs the tag scanner on every update.
    /// - **Not `@State private var parsed = Parsed(entry)`**: `State(initialValue:)`
    ///   is an EAGER parameter, re-evaluated every time SwiftUI re-creates the view
    ///   struct, so it would only move the cost from `body` to `init`. A class costs
    ///   one throwaway empty allocation per init, and parses only for an entry it
    ///   has not seen.
    ///
    /// Mutating it from `body` is safe because it is NOT observable: filling the
    /// cache cannot invalidate the view reading it.
    private final class EntryDocumentCache {
        private var key: DictionaryEntryDocument.ID?
        private var document: EntryDocument?

        func document(for entry: DictionaryEntryDocument) -> EntryDocument {
            if key == entry.id, let document { return document }
            let built = PSEntryDocumentBuilder.build(html: entry.html)
            key = entry.id
            document = built
            return built
        }
    }

    @State private var shown: DictionaryEntryDocument
    @State private var cache = EntryDocumentCache()

    init(
        initialEntry: DictionaryEntryDocument,
        library: LibraryModel,
        settings: SettingsModel
    ) {
        self.library = library
        self.settings = settings
        _shown = State(initialValue: initialEntry)
    }

    var body: some View {
        EntryTextView(
            document: cache.document(for: shown),
            openLink: { link in
                guard case .lexicon(let module, let key) = link else { return }
                shown = library.dictionaryEntry(module: module, key: key)
            },
            topInset: 8,
            // Not `EntryTextView`'s default. That reads the font from `UserDefaults`
            // when this body runs, and nothing else this body reads changes with
            // the font. This workspace is persistent: the entry is still up when the
            // user comes back from Settings, and with no dependency on the model it
            // shows the new font only if something else rebuilds it (NOT measured
            // whether returning to the tab does). The study popup keeps the default
            // because it is a sheet, and Settings cannot be reached while one is
            // open.
            style: .current(observing: settings)
        )
        // Following a cross-link swaps the entry in place, so the scroll offset has
        // to reset with it — the same reason `StudyPopupSheet` puts an `.id` on its
        // `EntryTextView`. A font change leaves the id alone, so the scroll view is
        // not replaced under the reader.
        .id(shown.id)
        .navigationTitle(shown.key)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("dictionary.entry")
    }
}

struct BookmarksView: View {
    let library: LibraryModel
    @Binding var section: LibrarySection
    let openBookmark: (String) -> Void

    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            BookmarkFolderScreen(
                library: library,
                parentID: nil,
                title: String(localized: "BookmarksTitle"),
                // Only the ROOT folder screen hosts the section switch. A pushed
                // folder shows its own name and a back button, which is the
                // navigation the user is actually in at that point.
                section: $section,
                openBookmark: openBookmark
            )
            .navigationDestination(for: UUID.self) { folderID in
                if let folder = library.bookmarkNode(id: folderID),
                   case .folder = folder.kind {
                    BookmarkFolderScreen(
                        library: library,
                        parentID: folderID,
                        title: folder.name ?? "",
                        section: nil,
                        openBookmark: openBookmark
                    )
                }
            }
        }
    }
}

private struct BookmarkFolderScreen: View {
    let library: LibraryModel
    let parentID: UUID?
    let title: String
    /// Non-nil only on the root screen; a pushed folder shows its own title.
    let section: Binding<LibrarySection>?
    let openBookmark: (String) -> Void

    @State private var renameTarget: BookmarkNode? = nil
    @State private var renameText = ""
    @State private var deleteTarget: BookmarkNode? = nil
    @State private var folderDraft: BookmarkFolderDraft? = nil
    @State private var mutationError: BookmarkMutationError? = nil

    var body: some View {
        let nodes = library.bookmarkChildren(in: parentID)

        List {
            if nodes.isEmpty {
                ContentUnavailableView(
                    "BookmarksTitle",
                    systemImage: "bookmark"
                )
                .listRowBackground(Color.clear)
            }
            ForEach(nodes) { node in
                BookmarkItemAction(
                    node: node,
                    openBookmark: {
                        guard let reference = library.openBookmark(id: node.id) else {
                            return
                        }
                        openBookmark(reference)
                    }
                )
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        renameText = node.name ?? ""
                        renameTarget = node
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)

                    if case .folder(let color, _) = node.kind {
                        Button {
                            folderDraft = BookmarkFolderDraft(
                                parentID: parentID,
                                folderID: node.id,
                                name: node.name ?? "",
                                color: color
                            )
                        } label: {
                            Label(
                                "BookmarksAddFolderHighlightColour",
                                systemImage: "paintpalette"
                            )
                        }
                        .tint(.orange)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = node
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .reorderable()
        }
        .listStyle(.insetGrouped)
        .swipeActionsContainer()
        .reorderContainer(for: BookmarkNode.self) { difference in
            let destinationID: UUID?
            switch difference.destination.position {
            case .before(let id):
                destinationID = id
            case .end:
                destinationID = nil
            }
            library.reorderBookmarks(
                parentID: parentID,
                sources: difference.sources,
                before: destinationID
            )
        }
        .navigationTitle(section == nil ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let section {
                ToolbarItem(placement: .principal) {
                    LibrarySectionPicker(section: section)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    folderDraft = BookmarkFolderDraft(
                        parentID: parentID,
                        folderID: nil,
                        name: "",
                        color: nil
                    )
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel(Text("BookmarksAddFolderButton"))
                .accessibilityIdentifier("bookmarks.add-folder")
            }
        }
        .alert("Rename", item: $renameTarget) { node in
            TextField("BookmarksAddBookmarkDescriptionTitle", text: $renameText)
            Button("Save") {
                do {
                    try library.renameBookmark(id: node.id, to: renameText)
                } catch let error as BookmarkMutationError {
                    mutationError = error
                } catch {
                    mutationError = .missingNode
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete", item: $deleteTarget) { node in
            Button("Delete", role: .destructive) {
                library.removeBookmark(id: node.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text("Delete \(node.name ?? "")?")
        }
        .sheet(item: $folderDraft) { draft in
            NavigationStack {
                BookmarkFolderEditor(library: library, draft: draft)
            }
        }
        .alert(
            mutationError?.title ?? "LibraryUpdateFailedTitle",
            item: $mutationError
        ) { _ in
            Button("Ok", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }
}

private struct BookmarkItemAction: View {
    let node: BookmarkNode
    let openBookmark: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch node.kind {
            case .folder:
                NavigationLink(value: node.id) {
                    BookmarkRow(node: node)
                }
            case .bookmark:
                Button(action: openBookmark) {
                    BookmarkRow(node: node)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("bookmarks.item.\(node.id.uuidString)")
    }
}

private struct BookmarkRow: View {
    let node: BookmarkNode

    var body: some View {
        HStack(spacing: 12) {
            BookmarkRowIcon(kind: node.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name ?? "")
                    .foregroundStyle(.primary)
                if case .bookmark(let reference) = node.kind,
                   let reference {
                    Text(reference)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if case .bookmark = node.kind,
               let date = node.dateLastAccessed {
                Text(date, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct BookmarkRowIcon: View {
    let kind: BookmarkNode.Kind

    var body: some View {
        ZStack {
            switch kind {
            case .bookmark:
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.tint)
            case .folder(let color, _):
                Image(systemName: "folder.fill")
                    .foregroundStyle(color.map(Color.init) ?? .secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

@MainActor
@Observable
private final class BookmarkFolderDraft: Identifiable {
    let id = UUID()
    let parentID: UUID?
    let folderID: UUID?
    var name: String
    var color: BookmarkColor?

    init(
        parentID: UUID?,
        folderID: UUID?,
        name: String,
        color: BookmarkColor?
    ) {
        self.parentID = parentID
        self.folderID = folderID
        self.name = name
        self.color = color
    }
}

private struct BookmarkFolderEditor: View {
    let library: LibraryModel
    let draft: BookmarkFolderDraft

    @Environment(\.dismiss) private var dismiss
    @State private var mutationError: BookmarkMutationError? = nil

    var body: some View {
        @Bindable var draft = draft

        Form {
            Section("BookmarksAddFolderFolderName") {
                TextField("BookmarksAddFolderFolderName", text: $draft.name)
                    .accessibilityIdentifier("bookmarks.folder-name")
            }
            Section("BookmarksAddFolderHighlightColour") {
                BookmarkColorGrid(selection: $draft.color)
            }
        }
        .navigationTitle(
            draft.folderID == nil
                ? "BookmarksAddFolderButton"
                : "BookmarksEditFolderTitle"
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(Text("Cancel"))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel(Text("Save"))
                .accessibilityIdentifier("bookmarks.folder-save")
            }
        }
        .alert(
            mutationError?.title ?? "LibraryUpdateFailedTitle",
            item: $mutationError
        ) { _ in
            Button("Ok", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    private func save() {
        do {
            if let folderID = draft.folderID {
                try library.updateBookmarkFolder(
                    id: folderID,
                    name: draft.name,
                    color: draft.color
                )
            } else {
                try library.addBookmarkFolder(
                    name: draft.name,
                    color: draft.color,
                    parentID: draft.parentID
                )
            }
            dismiss()
        } catch let error as BookmarkMutationError {
            mutationError = error
        } catch {
            mutationError = .missingNode
        }
    }
}

private struct BookmarkColorGrid: View {
    @Binding var selection: BookmarkColor?

    private let columns = [
        GridItem(.adaptive(minimum: 44, maximum: 54), spacing: 12),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(BookmarkColorChoice.all) { choice in
                Button {
                    selection = choice.color
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(choice.swatch)
                            .frame(width: 44, height: 44)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        Color(uiColor: .separator),
                                        lineWidth: 1
                                    )
                            }
                        if selection == choice.color {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(choice.checkmarkColor)
                        } else if choice.color == nil {
                            Image(systemName: "slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(choice.accessibilityLabel))
                .accessibilityAddTraits(
                    selection == choice.color ? .isSelected : []
                )
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BookmarkColorChoice: Identifiable {
    let id: String
    let color: BookmarkColor?

    var swatch: Color {
        color.map(Color.init) ?? Color(uiColor: .systemBackground)
    }

    var checkmarkColor: Color {
        guard let color else { return .primary }
        let luminance = Double(color.red) * 0.299
            + Double(color.green) * 0.587
            + Double(color.blue) * 0.114
        return luminance > 160 ? .black : .white
    }

    var accessibilityLabel: String {
        color?.hexString ?? String(localized: "None")
    }

    static let all: [BookmarkColorChoice] = [
        BookmarkColorChoice(id: "none", color: nil),
        choice("#FF0000"),
        choice("#00FF00"),
        choice("#0000FF"),
        choice("#00FFFF"),
        choice("#FFFF00"),
        choice("#FF00FF"),
        choice("#FF8000"),
        choice("#800080"),
        choice("#996633"),
    ]

    private static func choice(_ hex: String) -> BookmarkColorChoice {
        BookmarkColorChoice(
            id: hex,
            color: BookmarkColor(hexString: hex)
        )
    }
}

struct HistoryView: View {
    let library: LibraryModel
    @Binding var section: LibrarySection
    let openHistoryEntry: (HistoryEntry) -> Void

    @State private var deleteTarget: HistoryEntry? = nil
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            List {
                if library.history.isEmpty {
                    ContentUnavailableView(
                        "HistoryTitle",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(library.history) { entry in
                    Button {
                        openHistoryEntry(entry)
                    } label: {
                        HistoryRow(entry: entry)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // A STABLE identifier: `hashValue` is reseeded every launch, so an
                    // out-of-process XCUITest could never compute it. Reference plus module
                    // is the row's own key and needs no change to the persisted row.
                    .accessibilityIdentifier(
                        "history.item.\(entry.reference ?? "")"
                            + "|\(entry.moduleName ?? "")"
                    )
                    .swipeActions(allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = entry
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .swipeActionsContainer()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // No Close button: as a workspace section there is nothing to close.
                ToolbarItem(placement: .principal) {
                    LibrarySectionPicker(section: $section)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        confirmingClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(library.history.isEmpty)
                    .accessibilityLabel(Text("HistoryClearButtonTitle"))
                    .accessibilityIdentifier("history.clear")
                }
            }
            .confirmationDialog(
                "HistoryClearConfirmationTitle",
                isPresented: $confirmingClear
            ) {
                Button("HistoryClearButtonTitle", role: .destructive) {
                    library.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("HistoryClearConfirmationMessage")
            }
            .confirmationDialog("Delete", item: $deleteTarget) { entry in
                Button("Delete", role: .destructive) {
                    library.removeHistory(id: entry.id)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.reference ?? "")
                    .font(.body)
                    .foregroundStyle(.primary)
                if let moduleName = entry.moduleName, !moduleName.isEmpty {
                    Text(moduleName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let date = entry.dateAdded {
                Text(
                    date,
                    format: .dateTime
                        .day()
                        .month()
                        .hour()
                        .minute()
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
        }
    }
}

// Not `private`: `BookmarkEditorView` in SwiftUIStudyViews.swift shows the same
// three failures with the same wording, and duplicating the mapping would let the
// two drift.
extension BookmarkMutationError {
    var title: LocalizedStringResource {
        switch self {
        case .duplicateFolder:
            "BookmarksDuplicateFolderTitle"
        case .invalidFolderName:
            "BookmarksInvalidFolderTitle"
        case .missingNode:
            "LibraryUpdateFailedTitle"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .duplicateFolder:
            "BookmarksDuplicateFolderMessage"
        case .invalidFolderName:
            "BookmarksInvalidFolderMessage"
        case .missingNode:
            "LibraryUpdateFailedMessage"
        }
    }
}

private extension Color {
    init(_ bookmarkColor: BookmarkColor) {
        self.init(
            red: Double(bookmarkColor.red) / 255,
            green: Double(bookmarkColor.green) / 255,
            blue: Double(bookmarkColor.blue) / 255
        )
    }
}
