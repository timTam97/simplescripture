//
//  SimpleScriptureApp.swift
//  SimpleScripture
//
//  The app's entry point and top-level navigation.
//
//  ── Four workspaces ───────────────────────────────────────────────────────
//
//  - **Read**: Bible and commentary as one workspace with a mode switch — two
//    views of the same reference. Both panes stay alive (see
//    `ReadingWorkspace.swift`); only which one is on screen changes.
//  - **Search**: a workspace with `TabRole.search`.
//  - **Library**: Dictionary, Bookmarks and History — lists you consult rather
//    than read.
//  - **Settings**: preferences and About.
//
//  ── Launch ─────────────────────────────────────────────────────────────────
//
//  `LaunchCoordinator.prepare()` runs in a `Task`; the view switches on
//  `LaunchPhase` from `LaunchView` to the tab bar when it finishes. The ORDER is
//  load-bearing: nothing may touch `PSModuleController`, the content store or the
//  reader until `prepare()` has returned, because its one-shot migrations
//  (`DefaultsLastRefValidated` in particular) can rewrite `lastRef` out from under
//  a render. `ReadingWorkspaceModel.start()` is therefore called from the `.ready`
//  transition, not from `init`.
//
//  ── Orientation ────────────────────────────────────────────────────────────
//
//  The rotation-lock preference is enforced by
//  `UIWindowSceneDelegate.supportedInterfaceOrientations(for:)`, implemented by
//  `SimpleScriptureSceneOrientationDelegate`.
//

import BackgroundTasks
import SwiftUI
import UIKit

/// Where launch has got to. `LaunchCoordinator.prepare()` returning nil means the
/// content store could not be opened at all, which is fatal in the reader (see
/// `PSContentReader`'s header) — so it is surfaced rather than silently retried.
enum LaunchPhase: Equatable {
    case preparing
    case ready
    case failed
}

@main
struct SimpleScriptureApp: App {
    /// The app delegate exists for two things UIKit still owns: the
    /// `BGTaskScheduler` registration (which must happen before
    /// `didFinishLaunching` returns) and the scene-orientation hook. It holds no
    /// app state — that is all in `AppSession`.
    @UIApplicationDelegateAdaptor(SimpleScriptureAppDelegate.self)
    private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(
                session: appDelegate.session,
                reading: appDelegate.readingWorkspace,
                launchCoordinator: appDelegate.launchCoordinator
            )
            .onOpenURL { url in
                appDelegate.session.open(url)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                // Everything that writes a pref already synchronizes; this is belt and
                // braces for a background kill.
                UserDefaults.standard.synchronize()
            case .active:
                // `reset_PocketSword` is set from the Settings bundle, so it can arrive
                // while the app is suspended.
                if UserDefaults.standard.bool(forKey: "reset_PocketSword") {
                    appDelegate.launchCoordinator.resetPreferences()
                }
            @unknown default:
                break
            }
        }
    }
}

/// Launch gate. Keeps the splash visible while `LaunchCoordinator` runs, then
/// opens the app as soon as preparation finishes.
private struct RootView: View {
    let session: AppSession
    let reading: ReadingWorkspaceModel
    let launchCoordinator: LaunchCoordinator

    @State private var phase: LaunchPhase = .preparing

    var body: some View {
        ZStack {
            switch phase {
            case .preparing:
                LaunchView()
            case .ready:
                WorkspaceTabs(session: session, reading: reading)
            case .failed:
                LaunchFailureView()
            }
        }
        .task {
            guard phase == .preparing else { return }
            phase = await prepare()
            if phase == .ready {
                // Only now: the migrations can rewrite `lastRef`, and the reader
                // renders from it.
                reading.start()
                session.replayPendingURL()
            }
        }
    }

    /// Runs the launch coordinator off the main actor: it touches the file system
    /// and the defaults plist and takes long enough to be worth not blocking on.
    private func prepare() async -> LaunchPhase {
        let coordinator = launchCoordinator
        let result = await Task.detached(priority: .userInitiated) {
            coordinator.prepare()
        }.value

        guard let result else {
            alog("Launch preparation failed; the content store is unavailable.")
            return .failed
        }
        if result.shouldDisableIdleTimer {
            // A UIKit side effect that must be on the main thread (the Main Thread
            // Checker terminates otherwise).
            UIApplication.shared.isIdleTimerDisabled = true
        }
        return .ready
    }
}

/// Shown when the baked content store cannot be opened. There is no fallback
/// render path, so this is a dead end by design — better than a blank reader.
private struct LaunchFailureView: View {
    var body: some View {
        ContentUnavailableView {
            Label("LaunchFailedTitle", systemImage: "exclamationmark.triangle")
        } description: {
            Text("LaunchFailedMessage")
        }
        .accessibilityIdentifier("launch.failed")
    }
}

// MARK: - The four workspaces

struct WorkspaceTabs: View {
    let session: AppSession
    let reading: ReadingWorkspaceModel

    var body: some View {
        @Bindable var session = session

        // NOTE: no `accessibilityIdentifier` on the `Tab`s. It does not reach the
        // tab-bar button — verified in the iOS 27 hierarchy, where the four
        // buttons expose only their localized labels ("Read", "Library",
        // "Settings", "Search"). The XCUITests therefore match tabs by label.
        //
        // NOTE ALSO the resulting ORDER: Read, Library, Settings, Search. `Search`
        // is declared second but `TabRole.search` moves it to the trailing
        // position, which is the system's convention for a search tab and is why
        // the role exists.
        TabView(selection: $session.selectedWorkspace) {
            Tab(
                "WorkspaceRead",
                systemImage: "book",
                value: Workspace.read
            ) {
                ReadWorkspace(session: session, reading: reading)
            }

            Tab(
                "WorkspaceSearch",
                systemImage: "magnifyingglass",
                value: Workspace.search,
                // The system's search-tab treatment: on iPhone it takes the
                // trailing position and can host the search field itself.
                role: .search
            ) {
                SearchWorkspace(session: session, reading: reading)
            }

            Tab(
                "WorkspaceLibrary",
                systemImage: "books.vertical",
                value: Workspace.library
            ) {
                LibraryWorkspace(session: session, reading: reading)
            }

            Tab(
                "WorkspaceSettings",
                systemImage: "gearshape",
                value: Workspace.settings
            ) {
                SettingsWorkspace(session: session)
            }
        }
        .tabBarMinimizeBehavior(.never)
    }
}

// MARK: - Read

private struct ReadWorkspace: View {
    let session: AppSession
    let reading: ReadingWorkspaceModel

    var body: some View {
        ReaderScreen(reading: reading)
    }
}

// MARK: - Search

private struct SearchWorkspace: View {
    let session: AppSession
    let reading: ReadingWorkspaceModel

    var body: some View {
        SearchView(
            search: session.search,
            moduleChoices: reading.searchModuleChoices,
            preferredModule: reading.preferredSearchModule,
            currentBookName: reading.currentSearchBookName,
            focusRequest: session.searchFocusRequest,
            // A closure, so the value is consumed by `configure(...)` and not by a
            // body pass: `searchHistoryItemToRestore()` nils the saved item on its
            // query-only arm, and this body re-evaluates on any observed change
            // (it reads `reading.mode`) long after `SearchView`'s one-shot `.task`
            // has run.
            restoredHistoryItem: { reading.searchHistoryItemToRestore() },
            openResult: { reference, module in
                reading.savedSearchHistoryItem = session.search.historyItem()
                reading.savedSearchResultsMode = session.search.moduleKind
                // Carry the results list's own highlight terms into the chapter,
                // so the verse you land on marks the words the row did. The same
                // `search.highlightTerms` the rows use, so the two cannot disagree.
                reading.highlightSearchTerms(
                    session.search.highlightTerms,
                    mode: session.search.moduleKind
                )
                reading.openLibraryReference(reference, module: module)
                session.selectedWorkspace = .read
            }
        )
    }
}

// MARK: - Library

/// Dictionary, Bookmarks and History, as one workspace.
///
/// The section switch sits at `.principal`, replacing the per-section title (the
/// shape Mail uses for its mailbox switcher). Each section keeps its own
/// `NavigationStack` — Bookmarks needs a `path`-driven stack for folder descent
/// and Dictionary one for entry push — so the picker is declared inside each.
///
/// Not a `tabViewBottomAccessory`: that declares ONE accessory for the whole
/// `TabView`, and a per-section control there renders nothing.
private struct LibraryWorkspace: View {
    let session: AppSession
    let reading: ReadingWorkspaceModel

    @State private var section: LibrarySection = .bookmarks

    var body: some View {
        switch section {
        case .bookmarks:
            BookmarksView(
                library: session.library,
                section: $section,
                openBookmark: { reference in
                    reading.openLibraryReference(reference, module: nil)
                    session.selectedWorkspace = .read
                }
            )
        case .history:
            HistoryView(
                library: session.library,
                section: $section,
                openHistoryEntry: { entry in
                    reading.openLibraryReference(
                        entry.reference ?? "",
                        module: entry.moduleName
                    )
                    session.selectedWorkspace = .read
                }
            )
        case .dictionary:
            DictionaryView(
                library: session.library,
                section: $section
            )
        }
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks
    case history
    case dictionary

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .bookmarks: "BookmarksTitle"
        case .history: "HistoryTitle"
        case .dictionary: "TabBarTitleDictionary"
        }
    }

    var systemImage: String {
        switch self {
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        }
    }

    var identifier: String {
        "workspace.library.\(rawValue)"
    }
}

/// The Library's section switch, for the `.principal` toolbar slot.
///
/// A `Menu` rather than a segmented `Picker`: icon-only segments are opaque, and
/// the menu names the active section, which also makes it discoverable by name
/// in the accessibility hierarchy.
struct LibrarySectionPicker: View {
    @Binding var section: LibrarySection

    var body: some View {
        Menu {
            Picker("WorkspaceLibrary", selection: $section) {
                ForEach(LibrarySection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(section.title)
                    .font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("library.section")
    }
}

// MARK: - Settings

/// Preferences and About. Both were rows under the tab bar's system "More" list,
/// reachable only by tapping through it.
private struct SettingsWorkspace: View {
    let session: AppSession

    var body: some View {
        NavigationStack {
            SettingsView(
                settings: session.settings,
                // The iPad's larger reading pane takes a larger maximum, as it
                // always has.
                maximumFontSize: UIDevice.current.userInterfaceIdiom == .phone
                    ? 20
                    : 36
            )
            .navigationTitle("PreferencesTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        AboutView(information: .current())
                            .navigationTitle("AboutTitle")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(Text("AboutTitle"))
                    .accessibilityIdentifier("workspace.settings.about")
                }
            }
        }
    }
}
