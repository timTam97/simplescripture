import SwiftUI
import UIKit

struct SearchView: View {
    let search: SearchModel
    let moduleChoices: [SearchModuleChoice]
    let preferredModule: String?
    let currentBookName: String?
    let focusRequest: UInt
    /// Pulled inside `.task`, NOT passed as a value, and that is load-bearing.
    ///
    /// `ReadingWorkspaceModel.searchHistoryItemToRestore()` **consumes** the
    /// reader's saved item on its query-only arm. `SearchWorkspace.body`
    /// re-evaluates on any observed change, while `configure(...)` runs once per
    /// launch behind `@State configured`, so evaluating it in `body` would consume
    /// the value on passes that never reach `configure`. As a closure the consume
    /// happens on the one path that uses the result.
    let restoredHistoryItem: () -> PSSearchHistoryItem?
    let openResult: (_ reference: String, _ module: String) -> Void

    @State private var configured = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var search = search

        NavigationStack {
            SearchWorkspaceContent(
                search: search,
                openResult: openResult
            )
            .navigationTitle("SearchTitle")
            // Inline, deliberately: the scope picker below is pinned with
            // `safeAreaInset(edge: .top)`, which sits *under* the navigation bar's
            // large-title region. With a large title, overscrolling revealed the
            // title and search drawer below the opaque bar (and left ~200pt of empty
            // space at rest). `DictionaryView` pins its title inline for the same
            // reason.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarMinimizationBehavior(.never, for: .navigationBar)
            .searchable(
                text: $search.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("SearchTitle")
            )
            .searchFocused($isSearchFocused)
            .safeAreaInset(edge: .top, spacing: 0) {
                SearchScopePicker(search: search)
            }
        }
        .onSubmit(of: .search) {
            search.searchNow()
        }
        .onChange(of: focusRequest) {
            isSearchFocused = true
        }
        .task {
            guard !configured else { return }
            configured = true
            search.configure(
                modules: moduleChoices,
                preferredModule: preferredModule,
                currentBookName: currentBookName,
                restoring: restoredHistoryItem()
            )
        }
    }
}

private struct SearchScopePicker: View {
    let search: SearchModel

    var body: some View {
        @Bindable var search = search

        HStack(spacing: 8) {
            SearchModuleMenu(search: search)
            Picker("SearchRangeSectionHeader", selection: $search.range) {
                Text("SearchScopeAll").tag(PSSearchRange.AllRange)
                Text("SearchRangeOTRowShort").tag(PSSearchRange.OTRange)
                Text("SearchRangeNTRowShort").tag(PSSearchRange.NTRange)
                Text("SearchScopeBook").tag(PSSearchRange.BookRange)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("search.scope")
            SearchOptionsMenu(search: search)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct SearchModuleMenu: View {
    let search: SearchModel

    var body: some View {
        Menu {
            ForEach(search.modules) { choice in
                Button {
                    search.selectModule(choice)
                } label: {
                    Label {
                        Text(choice.id)
                    } icon: {
                        Image(
                            systemName: search.module == choice.id
                                ? "checkmark"
                                : choice.kind.systemImage
                        )
                    }
                }
                .accessibilityIdentifier("search.module.\(choice.id)")
            }
        } label: {
            Image(systemName: "books.vertical")
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel(Text("SearchModuleButtonLabel"))
        .accessibilityIdentifier("search.module-menu")
        .disabled(search.indexCoordinator.isOperationActive)
    }
}

private struct SearchOptionsMenu: View {
    let search: SearchModel

    var body: some View {
        @Bindable var search = search

        Menu {
            Picker("SearchTypeSectionHeader", selection: $search.matchType) {
                Text("SearchTypeAllRow")
                    .tag(PSSearchType.AndSearch)
                Text("SearchTypeAnyRow")
                    .tag(PSSearchType.OrSearch)
                Text("SearchTypeExactRow")
                    .tag(PSSearchType.ExactSearch)
            }
            Toggle("SearchFuzzyRow", isOn: $search.fuzzySearch)
            if search.strongsAvailable {
                Toggle("SearchStrongsRow", isOn: $search.strongsSearch)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel(Text("SearchOptionsTitle"))
        .accessibilityIdentifier("search.options")
    }
}

private struct SearchWorkspaceContent: View {
    let search: SearchModel
    let openResult: (_ reference: String, _ module: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch search.indexCoordinator.state {
            case .unavailable:
                SearchIndexUnavailableView(
                    module: search.module,
                    build: search.startIndexBuild
                )
            case .building(let progress):
                SearchIndexProgressView(
                    module: search.module,
                    progress: progress,
                    isCancelling: false,
                    cancel: search.cancelIndexBuild
                )
            case .cancelling:
                SearchIndexProgressView(
                    module: search.module,
                    progress: nil,
                    isCancelling: true,
                    cancel: {}
                )
            case .cancelled:
                SearchIndexRetryView(
                    title: "SearchIndexCancelledTitle",
                    build: search.startIndexBuild
                )
            case .failed:
                SearchIndexRetryView(
                    title: "SearchIndexFailedTitle",
                    build: search.startIndexBuild
                )
            case .ready:
                SearchReadyContent(
                    query: search.query,
                    results: search.results,
                    highlightTerms: search.highlightTerms,
                    fuzzy: search.fuzzySearch,
                    strongs: search.strongsSearch,
                    isSearching: search.isSearching,
                    isSearchPending: search.isSearchPending,
                    module: search.module,
                    openResult: openResult
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SearchIndexUnavailableView: View {
    let module: String?
    let build: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                "NoSearchIndexInstalled",
                systemImage: "text.page.badge.magnifyingglass"
            )
        } description: {
            if let module {
                Text(module)
            }
        } actions: {
            Button("SearchBuildIndexButton", action: build)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.index-build")
        }
    }
}

private struct SearchIndexProgressView: View {
    let module: String?
    let progress: Float?
    let isCancelling: Bool
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.page.badge.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(
                isCancelling
                    ? "SearchBuildingCancellingLabel"
                    : "SearchBuildingIndexTitle"
            )
            .font(.headline)
            if let module {
                Text(module)
                    .foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: Double(progress))
                    .frame(maxWidth: 280)
            } else {
                ProgressView()
            }
            if !isCancelling {
                Button("CancelButtonTitle", action: cancel)
                    .accessibilityIdentifier("search.index-cancel")
            }
        }
        .padding()
    }
}

private struct SearchIndexRetryView: View {
    let title: LocalizedStringResource
    let build: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.magnifyingglass")
        } actions: {
            Button("SearchBuildIndexButton", action: build)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("search.index-retry")
        }
    }
}

private struct SearchReadyContent: View {
    let query: String
    let results: [SearchResultRow]
    let highlightTerms: [String]
    let fuzzy: Bool
    let strongs: Bool
    let isSearching: Bool
    /// The debounce is running. For the empty arm only — the result list is
    /// not given it, so typing over rows leaves them and their corner alone.
    let isSearchPending: Bool
    let module: String?
    let openResult: (_ reference: String, _ module: String) -> Void

    var body: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "SearchEmptyPromptTitle",
                systemImage: "magnifyingglass",
                description: Text("SearchEmptyPromptMessage")
            )
        } else if results.isEmpty, isSearching || isSearchPending {
            // Running, or owed and waiting out the debounce. "No Results" is a
            // statement about a search that has finished, and until the timer
            // fires the text in the field has not been searched.
            ProgressView()
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            SearchResultList(
                results: results,
                highlightTerms: highlightTerms,
                fuzzy: fuzzy,
                strongs: strongs,
                isSearching: isSearching,
                module: module,
                openResult: openResult
            )
        }
    }
}

private struct SearchResultList: View {
    let results: [SearchResultRow]
    let highlightTerms: [String]
    let fuzzy: Bool
    let strongs: Bool
    let isSearching: Bool
    let module: String?
    let openResult: (_ reference: String, _ module: String) -> Void

    var body: some View {
        List {
            Section {
                ForEach(results) { result in
                    Button {
                        guard let module else { return }
                        openResult(result.reference, module)
                    } label: {
                        SearchResultRowView(
                            reference: result.reference,
                            text: result.text ?? "",
                            highlightTerms: strongs
                                ? result.strongsHighlightWords
                                : highlightTerms,
                            fuzzy: strongs ? false : fuzzy
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "search.result.\(result.reference)"
                    )
                    .contextMenu {
                        Button {
                            SearchResultClipboard.copy(
                                reference: result.reference,
                                text: result.text
                            )
                        } label: {
                            Label(
                                "SearchCopyVerseButton",
                                systemImage: "doc.on.doc"
                            )
                        }
                    }
                }
            } header: {
                Text(
                    LocalizedStringResource(
                        "SearchResultCountFormat",
                        defaultValue: "\(results.count) Results",
                        comment: "Search result count; the variable is the count."
                    )
                )
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .overlay(alignment: .topTrailing) {
            if isSearching {
                ProgressView()
                    .padding()
            }
        }
    }
}

private struct SearchResultRowView: View {
    let reference: String
    let text: String
    let highlightTerms: [String]
    let fuzzy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(reference)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(
                SearchHighlightedText.make(
                    text.replacingOccurrences(of: "\n", with: " "),
                    terms: highlightTerms,
                    fuzzy: fuzzy
                )
            )
            .font(.body)
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
enum SearchResultClipboard {
    static func copy(
        reference: String,
        text: String?,
        to pasteboard: UIPasteboard = .general
    ) {
        pasteboard.string = SearchResultClipboardText.make(
            reference: reference,
            text: text
        )
    }
}

enum SearchResultClipboardText {
    static func make(reference: String, text: String?) -> String {
        let verse = (text ?? "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !verse.isEmpty else { return reference }
        return "\(reference) \(verse)"
    }
}

private enum SearchHighlightedText {
    static func make(
        _ text: String,
        terms: [String],
        fuzzy: Bool
    ) -> AttributedString {
        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let output = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont]
        )
        guard !text.isEmpty, !terms.isEmpty else {
            return AttributedString(output)
        }

        let highlightFont = UIFont.systemFont(
            ofSize: baseFont.pointSize,
            weight: .semibold
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .backgroundColor: UIColor.systemYellow,
            .foregroundColor: UIColor.black,
            .font: highlightFont,
        ]
        let source = text as NSString
        let comparison: NSString.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
        ]
        let wordCharacters = NSCharacterSet.alphanumerics as NSCharacterSet

        for term in terms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.location < source.length {
                let match = source.range(
                    of: term,
                    options: comparison,
                    range: searchRange
                )
                guard match.location != NSNotFound else { break }

                var highlightRange = match
                if fuzzy {
                    var end = NSMaxRange(match)
                    while end < source.length,
                          wordCharacters.characterIsMember(
                            source.character(at: end)
                          ) {
                        end += 1
                    }
                    highlightRange.length = end - highlightRange.location
                }
                output.addAttributes(attributes, range: highlightRange)
                searchRange.location = NSMaxRange(highlightRange)
                searchRange.length = source.length - searchRange.location
            }
        }
        return AttributedString(output)
    }
}

private extension ReadingMode {
    var systemImage: String {
        switch self {
        case .bible:
            "book.closed"
        case .commentary:
            "text.book.closed"
        }
    }
}
