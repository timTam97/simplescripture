//
//  SwiftUIReaderChrome.swift
//  PocketSword
//
//  The iOS 27 reading chrome. `ReaderScreen` wraps the reader in a
//  `NavigationStack` and owns its toolbar. Placements are deliberate:
//
//  - Reference and chapter navigation sit at `.principal` with
//    `visibilityPriority(.high)`, so a constrained width sheds the study actions
//    before it sheds the ability to move between chapters. This is the one
//    control the reader cannot do without.
//  - Per-module display toggles go in a `ToolbarOverflowMenu`.
//  - Navigation and workspace controls stay visible while reading.
//
//  The display toggles are PER-MODULE and gated on the BAKED feature set — see
//  `ReaderDisplayToggle.toggles(forModule:store:)`, a pure function so the
//  six-rows-for-KJV / zero-rows-for-MHCC contract is assertable without the
//  simulator. It writes `"<pref>_<ModuleName>"` keys (persisted).
//

import SwiftUI
import UIKit

// Feature names; must match the literals in `globals.h`.
private enum ReaderFeature {
    static let strongs = "Strongs"                  // SWMOD_FEATURE_STRONGS
    static let confStrongs = "StrongsNumbers"       // SWMOD_CONF_FEATURE_STRONGSNUMBERS
    static let morph = "Morph"                      // SWMOD_FEATURE_MORPH
    static let headings = "Headings"                // SWMOD_FEATURE_HEADINGS
    static let footnotes = "Footnotes"              // SWMOD_FEATURE_FOOTNOTES
    static let scriptRef = "Scripref"               // not Scriptref
    static let redLetterWords = "RedLetterWords"
    static let typeBibles = "Biblical Texts"        // SWMOD_CATEGORY_BIBLES
}

/// One row of the per-tab display menu: a boolean toggle over a per-module
/// preference key.
struct ReaderDisplayToggle: Identifiable, Equatable {
    /// Stable identity for `ForEach`, and the accessibility-identifier suffix
    /// ("strongs", "morph", "headings", "footnotes", "xref", "redLetter", "vpl")
    /// the XCUITests look for.
    let id: String
    /// The localization KEY, resolved by the view. Kept as a key rather than a
    /// resolved string so this stays a pure value type.
    let titleKey: String
    /// The unsuffixed preference name; the module name is appended by
    /// `UserDefaults.ps*(…forModule:)`.
    let preference: String

    /// The rows a module's advertised features earn it.
    ///
    /// Feature gating reads the BAKED feature set (`content_meta`'s
    /// `module.<name>.features`), which also matches `GlobalOptionFilter` entries,
    /// not just `Feature=` lines — which is why KJV earns Footnotes / Headings /
    /// RedLetter despite declaring only `Feature=StrongsNumbers`.
    ///
    /// **KJV yields six rows, not seven**: it has no `OSISScripref` filter and no
    /// `Feature=Scripref`, so there is no Cross-references row. MHCC yields
    /// **zero** rows and the caller hides the control rather than presenting an
    /// empty menu.
    static func toggles(
        forModule moduleName: String?,
        store: PSContentStore?
    ) -> [ReaderDisplayToggle] {
        guard let moduleName, let store else { return [] }

        func has(_ feature: String) -> Bool {
            store.moduleHasFeature(moduleName, feature)
        }

        var toggles: [ReaderDisplayToggle] = []
        if has(ReaderFeature.strongs) || has(ReaderFeature.confStrongs) {
            toggles.append(
                ReaderDisplayToggle(
                    id: "strongs",
                    titleKey: "PreferencesStrongsPreferencesTitle",
                    preference: Defaults.strongsPreference
                )
            )
        }
        if has(ReaderFeature.morph) {
            toggles.append(
                ReaderDisplayToggle(
                    id: "morph",
                    titleKey: "PreferencesMorphTagsTitle",
                    preference: Defaults.morphPreference
                )
            )
        }
        if has(ReaderFeature.headings) {
            toggles.append(
                ReaderDisplayToggle(
                    id: "headings",
                    titleKey: "PreferencesHeadingsTitle",
                    preference: Defaults.headingsPreference
                )
            )
        }
        if has(ReaderFeature.footnotes) {
            toggles.append(
                ReaderDisplayToggle(
                    id: "footnotes",
                    titleKey: "PreferencesFootnotesTitle",
                    preference: Defaults.footnotesPreference
                )
            )
        }
        if has(ReaderFeature.scriptRef) {
            toggles.append(
                ReaderDisplayToggle(
                    id: "xref",
                    titleKey: "PreferencesCrossReferencesTitle",
                    preference: Defaults.scriptRefsPreference
                )
            )
        }
        if has(ReaderFeature.redLetterWords) {
            toggles.append(
                ReaderDisplayToggle(
                    id: "redLetter",
                    titleKey: "PreferencesRedLetterTitle",
                    preference: Defaults.redLetterPreference
                )
            )
        }
        // Verse-per-line is a rendering-side option, gated on the module being a
        // Bible rather than on a feature.
        if store.moduleMeta(moduleName, key: "type") == ReaderFeature.typeBibles {
            toggles.append(
                ReaderDisplayToggle(
                    id: "vpl",
                    titleKey: "PreferencesVPLTitle",
                    preference: Defaults.vplPreference
                )
            )
        }
        return toggles
    }
}

/// Observable state behind the reading chrome, one per pane.
@MainActor
@Observable
final class ReaderChromeModel {
    /// The reference shown in the centre of the bar, already munged through
    /// `createTitleRefString` by the host.
    var title: String = ""
    /// The un-munged reference, used as the control's accessibility label.
    var accessibilityReference: String = ""
    var isNextEnabled: Bool = true
    var isPreviousEnabled: Bool = true
    /// Empty when the active module advertises nothing, which hides the control.
    var displayToggles: [ReaderDisplayToggle] = []
    /// Mirrors each toggle's current per-module value, keyed by
    /// `ReaderDisplayToggle.id`. Held in the model rather than read live inside
    /// the view body so a write goes through Observation and refreshes the menu.
    var displayToggleValues: [String: Bool] = [:]
    /// Drives the reference picker popover/sheet.
    var isPresentingReferencePicker: Bool = false
    /// Selects the accessibility-identifier prefix ("bible."/"commentary.").
    var isBibleTab: Bool = true

    @ObservationIgnored var onPreviousChapter: (@MainActor () -> Void)?
    @ObservationIgnored var onNextChapter: (@MainActor () -> Void)?
    /// Applies a display-toggle flip: write the per-module pref, then redisplay.
    @ObservationIgnored var onDisplayToggle: (@MainActor (ReaderDisplayToggle) -> Void)?

    var identifierPrefix: String {
        isBibleTab ? "bible" : "commentary"
    }

    /// Rebuilds the toggle rows and their current values for `moduleName`.
    func reloadDisplayToggles(
        forModule moduleName: String?,
        store: PSContentStore? = PSContentStore.shared,
        defaults: UserDefaults = .standard
    ) {
        displayToggles = ReaderDisplayToggle.toggles(
            forModule: moduleName,
            store: store
        )
        guard let moduleName else {
            displayToggleValues = [:]
            return
        }
        displayToggleValues = Dictionary(
            uniqueKeysWithValues: displayToggles.map {
                ($0.id, defaults.psBool($0.preference, forModule: moduleName))
            }
        )
    }
}

/// A finished drag on the reader, classified as a chapter swipe — or not one.
///
/// Swiping LEFT pages forward and RIGHT pages back, the direction a page turns.
/// It follows the text (English, left-to-right), not the interface's layout
/// direction.
///
/// A pure value so the swipe-versus-scroll decision is assertable without the
/// simulator. The reader is a vertical scroll view the user drags all day, so the
/// test is deliberately strict: an ordinary scroll that drifts sideways, or a
/// finger resting on the text, must not turn the page.
enum ChapterSwipe: Equatable {
    case next
    case previous

    /// How far a finger moves before the drag is tracked at all. Well clear of a
    /// tap, so links and the verse menu are untouched.
    static let minimumDistance: CGFloat = 20
    /// Horizontal travel under the finger. Rules out a flick too short to be meant.
    static let minimumTravel: CGFloat = 50
    /// Horizontal travel once the release velocity is projected forward. A quick
    /// flick clears it on speed; a slow drag has to cover the distance itself.
    static let minimumProjectedTravel: CGFloat = 150
    /// Horizontal travel must be at least this many times the vertical — within
    /// about 27° of level. A scroll with sideways drift fails here.
    static let horizontalDominance: CGFloat = 2

    init?(translation: CGSize, predictedEndTranslation: CGSize) {
        let travel = translation.width
        let projected = predictedEndTranslation.width
        guard abs(travel) >= Self.minimumTravel,
              abs(travel) >= abs(translation.height) * Self.horizontalDominance,
              // Still heading the way it started: a drag reversed before release is
              // the user changing their mind.
              (travel < 0) == (projected < 0),
              abs(projected) >= Self.minimumProjectedTravel else {
            return nil
        }
        self = travel < 0 ? .next : .previous
    }
}

/// The slide between the scroll view a page turn leaves and the one it arrives
/// on (`ReaderPaneModel.scrollSurface`). The new chapter comes in from the side
/// it is on — the right going forward, the left going back, the way the swipe
/// itself reads (see `ChapterSwipe`) — and pushes the old one out the other,
/// like facing pages. With Reduce Motion they cross-fade in place instead.
///
/// It plays when the page turns, for a swipe and a chevron alike. It does NOT
/// follow the finger during a swipe, and at the swipe's gesture priority it
/// cannot: SwiftUI holds a `.gesture` drag back until the text's own gestures
/// have had the touch, and then delivers all of it at once. MEASURED on iOS
/// 27.2: every update of a 1.6-second drag arrived in the same millisecond as
/// its end. Tracking the finger would take `.simultaneousGesture`, the
/// attachment under which extending a text selection turned the page.
///
/// **The direction is read from the pane when the slide runs, not stored in the
/// transition.** SwiftUI removes a view with the transition value it was LAST
/// GIVEN, which for the scroll view being left is the one from the previous
/// turn. MEASURED with the direction stored (`.push(from:)`): paging forward
/// and then back sent the old chapter out to the left while the new one came in
/// from the left as well.
struct ChapterPageTransition: Transition {
    let pane: ReaderPaneModel
    let reduceMotion: Bool
    /// How much wider than the page the slide has to be to carry it off SCREEN
    /// rather than only out of its own frame: the reader's side safe-area insets.
    /// Zero in portrait. In landscape on an iPhone the reader sits inside them, and
    /// a page that travelled only its own width would stop with its edge still
    /// showing in the margin beside the sensor housing, then vanish.
    let overhang: CGFloat

    /// The page turn's curve. `.smooth`, not `.snappy`: the latter overshoots, and
    /// a page of text that runs a point past its margin and comes back reads as a
    /// wobble (measured: 1 pt, with `.snappy`).
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)
    }

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .modifier(PageSlide(widths: reduceMotion ? 0 : side(in: phase),
                                overhang: overhang))
            .opacity(reduceMotion && !phase.isIdentity ? 0 : 1)
            // The chapter being left stays in the hierarchy until the slide ends. It
            // must not take a touch (its links belong to a chapter that is no longer
            // the current one), or be read out and matched as though still showing.
            .allowsHitTesting(phase != .didDisappear)
            .accessibilityHidden(phase == .didDisappear)
    }

    /// Where a page sits, in page widths from rest: +1 is a full width to the
    /// right. Going forward the new chapter waits there and the old one leaves
    /// by the left; going back, the reverse.
    private func side(in phase: TransitionPhase) -> CGFloat {
        switch phase {
        case .identity: return 0
        case .willAppear: return pane.pageTurn.forward ? 1 : -1
        case .didDisappear: return pane.pageTurn.forward ? -1 : 1
        }
    }

    /// A sideways shift measured in the view's own width (plus the overhang), so
    /// it stays right through a rotation in mid-slide.
    private struct PageSlide: GeometryEffect {
        var widths: CGFloat
        var overhang: CGFloat

        var animatableData: CGFloat {
            get { widths }
            set { widths = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(
                CGAffineTransform(translationX: (size.width + overhang) * widths, y: 0)
            )
        }
    }
}

/// The Read workspace: the active pane, its chrome, the Bible/commentary
/// switch, and the study surfaces the reader raises (study popup, verse menu,
/// bookmark editor).
struct ReaderScreen: View {
    let reading: ReadingWorkspaceModel

    /// Bumped by a swipe that turned the page; the haptic's trigger.
    @State private var swipePageTurns = 0

    private var chrome: ReaderChromeModel { reading.activePane.chrome }

    var body: some View {
        @Bindable var reading = reading

        NavigationStack {
            readerPanes
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ReaderReferenceControl(
                            chrome: chrome,
                            makeReferencePicker: {
                                makeReferencePicker(reading: reading)
                            }
                        )
                    }
                    .visibilityPriority(.high)

                    // The Bible/commentary switch, at the bar's LEADING edge.
                    //
                    // Not `.bottomBar`: on iOS 27 the floating tab bar occupies the bottom, so
                    // the picker lands on top of it and taps go to the tab bar. Not
                    // `.principal` either: that slot holds the reference control, which must
                    // be the last thing a constrained width sheds.
                    ToolbarItem(placement: .topBarLeading) {
                        ReadingModePicker(reading: reading)
                    }
                }
                .toolbarOverflowMenu {
                    if !chrome.displayToggles.isEmpty {
                        Section {
                            ForEach(chrome.displayToggles) { toggle in
                                ReaderDisplayToggleButton(
                                    chrome: chrome,
                                    toggle: toggle
                                )
                            }
                        }
                    }
                }
                .toolbarMinimizationBehavior(.never, for: .navigationBar)
                // The chapter already scrolls beneath the bar. Hiding the bar's
                // background lets iOS render these toolbar controls as native
                // floating Liquid Glass instead of placing an opaque strip behind
                // them.
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .sheet(item: $reading.studyPopup) { popup in
                    StudyPopupSheet(
                        content: popup.content,
                        findAllOccurrences: reading.startStrongsSearch
                    )
                }
                .sheet(item: $reading.bookmarkDraft) { draft in
                    NavigationStack {
                        BookmarkEditorView(draft: draft)
                    }
                }
                .confirmationDialog(
                    verseMenuTitle,
                    item: $reading.verseMenuTarget,
                    titleVisibility: .visible
                ) { target in
                    Button("VerseContextualMenuAddBookmark") {
                        reading.addBookmark(for: target)
                    }
                    Button("VerseContextualMenuCommentary") {
                        reading.showInCommentary(verse: target.verse)
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }

    /// BOTH panes stay in the hierarchy, with the inactive one hidden.
    ///
    /// Not stylistic: `displayChapter` renders the polled pane and defers a
    /// `refToShow` / `pendingRestore` into the other, which applies it when it next
    /// becomes active — so the inactive pane has to exist to receive it. Rendering
    /// only the active pane (a plain `if`) would tear down its document and scroll
    /// position and lose the pending work.
    ///
    /// The safe area is owned by `ChapterTextView` (edge-to-edge scroll view with
    /// inset content). Do not add an `ignoresSafeArea` here — a second one at this
    /// level would inset nothing and reintroduce the tab-bar overlap.
    private var readerPanes: some View {
        ZStack {
            ChapterTextView(pane: reading.bible)
                .opacity(reading.mode == .bible ? 1 : 0)
                .accessibilityHidden(reading.mode != .bible)
            ChapterTextView(pane: reading.commentary)
                .opacity(reading.mode == .commentary ? 1 : 0)
                .accessibilityHidden(reading.mode != .commentary)
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { old, new in
            // Rotation, or an iPad split-view resize: re-anchor each pane and SUPPRESS
            // the transient scroll callbacks the transition emits, which would
            // otherwise overwrite the persisted position.
            //
            // The two calls are deliberately back to back: `restoreAfterSizeChange`
            // keeps the suppression alive until its own deferred scroll has landed.
            // Do not split them across separate callbacks.
            guard old != .zero, old != new else { return }
            reading.prepareForSizeChange()
            reading.restoreAfterSizeChange()
        }
        // On the ZStack, not in `ChapterTextView`: one recogniser for whichever pane
        // is showing.
        //
        // `.gesture`, NOT `.simultaneousGesture`: the gestures inside the reader have
        // to win. The chapter text is selectable, and dragging a selection handle —
        // or pressing and dragging out a selection — is a sideways drag. MEASURED on
        // iOS 27.2: recognised simultaneously, extending a selection turned the page.
        // At ordinary priority the selection keeps the touch, a swipe that starts on
        // plain text or on a link still pages, and vertical scrolling is untouched
        // (the scroll view does not claim a sideways drag).
        .gesture(chapterSwipe)
        // One light tap as a swipe turns the page. A swipe has no button under the
        // finger, so this is its confirmation that the gesture took; a swipe that
        // goes nowhere (a scroll, or back from Genesis 1) stays silent. So do the
        // chevrons, like any other toolbar button.
        .sensoryFeedback(.impact(weight: .light), trigger: swipePageTurns)
    }

    /// A horizontal swipe pages by a chapter. Decided once, on release — see
    /// `ChapterSwipe` — so one swipe can never page twice.
    private var chapterSwipe: some Gesture {
        DragGesture(minimumDistance: ChapterSwipe.minimumDistance)
            .onEnded { drag in
                guard let swipe = ChapterSwipe(
                    translation: drag.translation,
                    predictedEndTranslation: drag.predictedEndTranslation
                ), reading.page(swipe) else { return }
                swipePageTurns += 1
            }
    }

    /// The verse menu's title — "Verse 12".
    private var verseMenuTitle: String {
        guard let verse = reading.verseMenuTarget?.verse else { return "" }
        return String.localizedStringWithFormat(
            String(localized: "RefSelectorVerseTitle"),
            verse
        )
    }

    /// Builds the reference picker: a selection closes the picker and applies
    /// book/chapter/verse directly.
    private func makeReferencePicker(
        reading: ReadingWorkspaceModel
    ) -> ReferencePickerView {
        let model = ReferencePickerModel(
            books: (PSBookOSISResolver.shared?.books ?? [])
                .map(ReferencePickerBook.init),
            currentReference: PSModuleController.getCurrentBibleRef(),
            // iPhone presents as a sheet, which needs an explicit Cancel; an iPad
            // popover is dismissed by tapping outside it.
            showsCancel: UIDevice.current.userInterfaceIdiom == .phone
        )
        let chrome = reading.activePane.chrome
        model.onCancel = {
            chrome.isPresentingReferencePicker = false
        }
        model.onSelection = { selection in
            chrome.isPresentingReferencePicker = false
            reading.selectReference(
                bookName: selection.bookName,
                chapter: selection.chapter,
                verse: selection.verse
            )
        }
        return ReferencePickerView(model: model)
    }
}

/// The Bible/commentary switch: two views of the same reference, so switching
/// is a display choice rather than navigation.
///
/// A `Menu` rather than a segmented `Picker`, like the Library's section
/// switch: it has to fit in a toolbar slot beside chapter navigation, where a
/// two-segment control is cramped and unlabelled. The menu names the active
/// mode.
private struct ReadingModePicker: View {
    let reading: ReadingWorkspaceModel

    var body: some View {
        @Bindable var reading = reading

        Menu {
            Picker("WorkspaceRead", selection: $reading.mode) {
                Label("TabBarTitleBible", systemImage: "book.closed")
                    .tag(ReadingMode.bible)
                Label("TabBarTitleCommentary", systemImage: "text.book.closed")
                    .tag(ReadingMode.commentary)
            }
            .pickerStyle(.inline)
        } label: {
            Image(
                systemName: reading.mode == .bible
                    ? "book.closed"
                    : "text.book.closed"
            )
        }
        .accessibilityLabel(
            Text(
                reading.mode == .bible
                    ? "TabBarTitleBible"
                    : "TabBarTitleCommentary"
            )
        )
        .accessibilityIdentifier("reading.mode")
    }
}

/// [‹ | Gen 23:23 | ›]: chapter back, the reference (opens the picker), chapter
/// forward. Each button carries its own accessibility label.
private struct ReaderReferenceControl: View {
    let chrome: ReaderChromeModel
    let makeReferencePicker: () -> ReferencePickerView

    var body: some View {
        @Bindable var chrome = chrome

        HStack(spacing: 4) {
            Button {
                chrome.onPreviousChapter?()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!chrome.isPreviousEnabled)
            .accessibilityLabel(Text("VoiceOverPreviousChapterButton"))
            .accessibilityIdentifier("reading.previous-chapter")

            Button {
                chrome.isPresentingReferencePicker = true
            } label: {
                Text(chrome.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    // A floor rather than a fixed width, so a long reference and larger
                    // Dynamic Type sizes can grow instead of truncating.
                    .frame(minWidth: 95)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(chrome.accessibilityReference))
            .accessibilityValue(Text(chrome.title))
            .accessibilityIdentifier("reading.reference-picker")
            // Anchored on the button itself, so the popover's arrow points at the
            // reference it is changing; on the NavigationStack it collapsed to a
            // 320x49 strip at the bottom of the screen.
            //
            // NO `presentationCompactAdaptation(.popover)`: iPhone adapts to a sheet
            // (the system default, and intended); iPad gets a popover.
            .popover(isPresented: $chrome.isPresentingReferencePicker) {
                makeReferencePicker()
                    .frame(
                        minWidth: 320,
                        minHeight: UIDevice.current.userInterfaceIdiom == .pad
                            ? 480 : nil
                    )
            }

            Button {
                chrome.onNextChapter?()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!chrome.isNextEnabled)
            .accessibilityLabel(Text("VoiceOverNextChapterButton"))
            .accessibilityIdentifier("reading.next-chapter")
        }
    }
}

/// One display toggle. A `Button` with a checkmark rather than a `Toggle`, so
/// the flip goes through the host's write-then-redisplay path rather than a
/// binding that would have to own the pref key.
private struct ReaderDisplayToggleButton: View {
    let chrome: ReaderChromeModel
    let toggle: ReaderDisplayToggle

    var body: some View {
        let isOn = chrome.displayToggleValues[toggle.id] ?? false
        Button {
            chrome.onDisplayToggle?(toggle)
        } label: {
            // A checkmark only when on. The icon is omitted when off rather than an
            // empty `Image(systemName: "")`, which is not a real symbol.
            if isOn {
                Label {
                    Text(LocalizedStringKey(toggle.titleKey))
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text(LocalizedStringKey(toggle.titleKey))
            }
        }
        .accessibilityIdentifier(
            "\(chrome.identifierPrefix).\(toggle.id)"
        )
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
