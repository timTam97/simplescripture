//
//  SwiftUIStudyViews.swift
//  PocketSword
//
//  The study surfaces the reader raises: the Strong's / morph / footnote /
//  lexicon popup and the bookmark editor.
//
//  `PSInfoPopupContent`'s Greek/Hebrew lemma and transliteration parsing (nested
//  beta-code brackets, the ~114 Hebrew entries with a spurious `<sup>` vowel,
//  numeric-entity decoding) is content, not presentation, and is kept separate.
//

import SwiftUI
import UIKit

// MARK: - Study popup

/// The Strong's / morph / footnote / lexicon sheet: an accent rail, the lemma as
/// the hero in its own script font, the reference demoted to a subtitle, and the
/// definition below over frosted material.
struct StudyPopupSheet: View {
    /// The entries the reader opened, one per Strong's number of the word
    /// tapped (`StudyPopup`). Usually one.
    let entries: [PSInfoPopupContent]
    let findAllOccurrences: (String) -> Void

    /// Which of `entries` is chosen. Choosing another starts its own trail.
    @State private var selected: Int

    init(entries: [PSInfoPopupContent],
         initial: Int = 0,
         findAllOccurrences: @escaping (String) -> Void) {
        self.entries = entries
        self.findAllOccurrences = findAllOccurrences
        _selected = State(initialValue: entries.indices.contains(initial) ? initial : 0)
    }

    /// The chosen entry the reader opened, before any cross-link.
    private var content: PSInfoPopupContent {
        entries[selected]
    }

    /// Cross-links followed from the entry the reader opened, innermost last.
    ///
    /// 14,989 lexicon cross-links ("From 3898") are baked into the content. They
    /// resolve **in place** rather than by stacking sheets: a `.medium` detent sheet
    /// presenting another sheet trips the floating-tab-bar layout assertion, and a
    /// `NavigationStack` in a half-height sheet spends a fifth of the visible area
    /// on a bar. So the sheet swaps its content and offers Back while the trail is
    /// non-empty.
    @State private var trail: [PSInfoPopupContent] = []

    /// What is actually on screen: the deepest cross-link followed, or the entry the
    /// reader opened.
    private var current: PSInfoPopupContent {
        trail.last ?? content
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.count > 1 {
                numberPicker
            }
            if !trail.isEmpty {
                backBar
            }
            if current.isStrongsEntry {
                StudyPopupHeader(content: current)
            }
            EntryTextView(
                // Parsed ONCE, on the content object that owns the HTML; building it here
                // would re-run the scanner on every body evaluation.
                document: current.entryDocument,
                openLink: follow,
                // A non-Strong's entry has no header to sit under, so it gets top padding.
                topInset: current.isStrongsEntry ? 0 : 20,
                // The Strong's definition uses the system face; footnotes and morph
                // entries use the user's chosen font.
                usesSystemFace: current.isStrongsEntry
            )
            // `current` changes identity when a cross-link is followed or another
            // number is chosen, which resets the entry's scroll offset. Without this
            // the new definition opens scrolled to wherever the previous one sat.
            .id(current.reference ?? "root-\(selected)-\(trail.count)")
            if let searchTerm = current.searchTerm {
                Divider()
                Button {
                    findAllOccurrences(searchTerm)
                } label: {
                    Label("StrongsSearchFindAll", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StudyPalette.accent)
                .accessibilityIdentifier("study.find-all")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        // A container, so its identifier is its own and not every child's: on
        // the bare stack it replaced `study.numbers`, `study.back` and
        // `study.find-all` on the controls inside it (MEASURED, iOS 27.2: the
        // segmented control, Back and Find All all reported `study.popup`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("study.popup")
    }

    /// One segment per number of the word tapped (`H853 | H1254`). Choosing
    /// one drops the trail: Back belongs to the entry it was followed from.
    private var numberPicker: some View {
        Picker("StrongsWordNumbersPicker", selection: Binding(
            get: { selected },
            set: { index in
                guard index != selected else { return }
                trail = []
                selected = index
            }
        )) {
            ForEach(entries.indices, id: \.self) { index in
                Text(entries[index].reference ?? "\(index + 1)").tag(index)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        // Clear of the sheet's grabber, which 16 pt left 4 pt into the
        // segments' frame (MEASURED, iOS 27.2).
        .padding(.top, 24)
        .accessibilityIdentifier("study.numbers")
    }

    private var backBar: some View {
        HStack {
            Button {
                _ = trail.popLast()
            } label: {
                Label("RefSelectorBackButtonTitle", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyPalette.accent)
            .accessibilityIdentifier("study.back")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// Follow a cross-link, or do nothing if its target is not in the store.
    ///
    /// "Find all occurrences" stays available on a followed entry only if it was
    /// available on the one the reader opened — that flag is Bible-only (the
    /// commentary has no Strong's index to search) and is a property of where the
    /// popup was raised from, not of the entry now showing.
    private func follow(_ link: EntryLink) {
        guard case .lexicon(let module, let key) = link,
              let next = PSInfoPopupContent.lexiconEntry(
                  module: module,
                  key: key,
                  allowsSearch: content.searchTerm != nil
              ) else {
            return
        }
        trail.append(next)
    }
}

/// The lemma header. When the lexeme parses, the WORD is the hero and the
/// reference folds into the subtitle; when it does not, the reference becomes the
/// hero.
private struct StudyPopupHeader: View {
    let content: PSInfoPopupContent

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Capsule()
                .fill(StudyPalette.accent)
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(hero)
                    .font(heroFont)
                    .foregroundStyle(.primary)
                if let transliteration = content.transliteration {
                    Text(transliteration)
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.init(top: 24, leading: 20, bottom: 16, trailing: 20))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        guard content.lemma != nil, let reference = content.reference else {
            return content.contextTitle
        }
        return [content.contextTitle, reference]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var hero: String {
        content.lemma ?? content.reference ?? ""
    }

    /// The bundled script font at 40pt for a parsed lemma, scaled for Dynamic
    /// Type; a plain semibold 28pt for the reference fallback. `Font.custom(…,
    /// relativeTo:)` falls back to the system font if the custom family is not
    /// registered.
    private var heroFont: Font {
        guard content.lemma != nil else {
            return .system(size: 28, weight: .semibold)
        }
        let name = content.isHebrew
            ? AppConstants.hebrewStrongsFontName
            : AppConstants.greekStrongsFontName
        return .custom(name, size: 40, relativeTo: .largeTitle)
    }
}

/// The study accent, shared by the header rail and the entry's own links.
enum StudyPalette {
    static let accent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.40, green: 0.77, blue: 0.79, alpha: 1)
                : UIColor(red: 0.04, green: 0.40, blue: 0.44, alpha: 1)
        }
    )
}

// MARK: - Bookmark editor

/// Add a bookmark for a verse: the reference (fixed), a description, and a
/// destination folder. Editing an existing bookmark is the Library's
/// rename/colour flow.
///
/// The folder picker is flat, listing every folder by its full path.
struct BookmarkEditorView: View {
    let draft: BookmarkDraft

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folderPath: String?
    @State private var error: BookmarkMutationError?

    var body: some View {
        Form {
            Section("BookmarksAddBookmarkVerseTitle") {
                Text(draft.reference)
                    .accessibilityIdentifier("bookmark.reference")
            }
            Section("BookmarksAddBookmarkDescriptionTitle") {
                TextField(draft.reference, text: $name)
                    .accessibilityIdentifier("bookmark.description")
            }
            Section("BookmarksAddBookmarkFolderTitle") {
                Picker("BookmarksAddBookmarkFolderTitle", selection: $folderPath) {
                    Text("BookmarksTitle").tag(String?.none)
                    ForEach(BookmarkFolderPath.all(), id: \.path) { folder in
                        Text(folder.displayPath).tag(String?.some(folder.path))
                    }
                }
                .accessibilityIdentifier("bookmark.folder")
            }
        }
        .navigationTitle("VerseContextualMenuAddBookmark")
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
                .accessibilityIdentifier("bookmark.save")
            }
        }
        .alert(
            error?.title ?? "LibraryUpdateFailedTitle",
            item: $error
        ) { _ in
            Button("Ok", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
    }

    /// Persists the bookmark and announces the change. An empty description falls
    /// back to the reference itself.
    ///
    /// **The `bookmarksChanged` post is deliberately UNCONDITIONAL.** It has two
    /// consumers: the reader's highlight re-render and `LibraryModel`, which
    /// refreshes `bookmarks` only off this notification (the Bookmarks section has
    /// no reload of its own). Gating it on the bookmark being in the current chapter
    /// would leave the Library listing a stale tree. `PSBookmarks.addBookmark` posts
    /// nothing itself.
    private func save() {
        let description = name.isEmpty ? draft.reference : name
        _ = PSBookmarks.addBookmark(
            withRef: draft.reference,
            name: description,
            folderString: folderPath
        )
        NotificationCenter.default.post(name: .bookmarksChanged, object: nil)
        dismiss()
    }
}

/// A folder in the bookmark tree, by its persisted path.
///
/// The separator is `AppConstants.folderSeparatorString` (`":::"`), the persisted
/// format `PSBookmarks.getBookmarkFolder(forFolderString:)` parses — so the value
/// handed to `addBookmark` is exact. `displayPath` swaps it for `/` for reading.
struct BookmarkFolderPath: Equatable {
    let path: String

    var displayPath: String {
        path.replacingOccurrences(
            of: AppConstants.folderSeparatorString,
            with: " / "
        )
    }

    /// Every folder in the tree, depth-first, as separator-joined paths.
    static func all(root: PSBookmarkFolder = PSBookmarks.default()) -> [BookmarkFolderPath] {
        var result: [BookmarkFolderPath] = []
        func walk(_ folder: PSBookmarkFolder, prefix: String?) {
            for case let child as PSBookmarkFolder in folder.children ?? [] {
                guard let name = child.name else { continue }
                let path = prefix.map {
                    "\($0)\(AppConstants.folderSeparatorString)\(name)"
                } ?? name
                result.append(BookmarkFolderPath(path: path))
                walk(child, prefix: path)
            }
        }
        walk(root, prefix: nil)
        return result
    }
}
