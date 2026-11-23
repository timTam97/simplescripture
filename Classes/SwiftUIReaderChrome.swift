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
//    control the reader cannot do without. On an iPad, where the tab bar takes
//    the bar's centre, they move to the leading slot only where they fit there
//    (`ReaderReferenceFit`); otherwise they keep `.principal`, on a second row.
//  - Per-module display toggles go in a `ToolbarOverflowMenu`, declared only
//    when the active module has some: a module with none gets no ••• button.
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
/// preference key, or (Strong's) a choice among `StrongsDisplay`'s four.
struct ReaderDisplayToggle: Identifiable, Equatable {
    /// How the row is drawn and what it writes.
    enum Control: Equatable {
        /// A checkmark row that flips `preference`.
        case toggle
        /// A submenu of Off / Numbers / Underlined Words / Invisible, over
        /// `preference`, `Defaults.strongsUnderlinePreference` and
        /// `Defaults.strongsInvisiblePreference` (`StrongsDisplay`).
        case strongsDisplay
    }

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
    var control: Control = .toggle

    /// Every unsuffixed key the row writes: what a reset has to clear
    /// (`LaunchCoordinator.resetPreferences`).
    var preferences: [String] {
        switch control {
        case .toggle: [preference]
        case .strongsDisplay: [preference, Defaults.strongsUnderlinePreference,
                                 Defaults.strongsInvisiblePreference]
        }
    }

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
                    preference: Defaults.strongsPreference,
                    control: .strongsDisplay
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
    /// The Strong's row's choice, mirrored the same way. `.off` when the module
    /// has no Strong's row.
    var strongsDisplay: StrongsDisplay = .off
    /// Drives the reference picker popover/sheet.
    var isPresentingReferencePicker: Bool = false
    /// Selects the accessibility-identifier prefix ("bible."/"commentary.").
    var isBibleTab: Bool = true

    @ObservationIgnored var onPreviousChapter: (@MainActor () -> Void)?
    @ObservationIgnored var onNextChapter: (@MainActor () -> Void)?
    /// Applies a display-toggle flip: write the per-module pref, then redisplay.
    @ObservationIgnored var onDisplayToggle: (@MainActor (ReaderDisplayToggle) -> Void)?
    /// Applies a Strong's choice the same way.
    @ObservationIgnored var onStrongsDisplayChange: (@MainActor (StrongsDisplay) -> Void)?

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
            strongsDisplay = .off
            return
        }
        displayToggleValues = Dictionary(
            uniqueKeysWithValues: displayToggles.map {
                ($0.id, defaults.psBool($0.preference, forModule: moduleName))
            }
        )
        strongsDisplay = displayToggles.contains { $0.control == .strongsDisplay }
            ? StrongsDisplay.current(forModule: moduleName, defaults: defaults)
            : .off
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

/// Whether ‹ reference › fits on the tab bar's row, in the bar's leading slot
/// after the Bible/commentary switch. At a regular width the tab bar floats in
/// the navigation bar's centre; if the leading items do not fit beside it the
/// bar drops BOTH of them: no book button and no chapter navigation, and nothing
/// logged. So the reader decides from what it can measure, and sends the control
/// to the second row (`.principal`) wherever the leading slot would not hold it.
///
/// The constants are the bar's own geometry, MEASURED on iOS 27.2 (iPad Pro
/// 11-inch (M5), iPad mini (A20 Pro), iPad (A16); 2026-11-16), not ours to choose.
/// `testTheReferenceGoesLeadingOnlyWhereTheBarHasRoomForIt` pins each measured
/// case.
enum ReaderReferenceFit {
    /// Where the bar starts its leading items with nothing in the corner.
    static let leadingMargin: CGFloat = 14
    /// The bar's spacing: between two items, after the system's window controls,
    /// and before the first tab. Measured as the last: a pill that ended 16.75 pt
    /// short of the first tab stayed, one that ended 14.75 pt short was dropped.
    static let itemSpacing: CGFloat = 16
    /// The switch's glass circle, at every Dynamic Type size (its frame; it draws
    /// wider, see CLAUDE.md).
    static let modeSwitchWidth: CGFloat = 36
    /// How much wider the control is in the leading slot than at `.principal`:
    /// the bar gives each chevron button 6 pt more padding on both sides there
    /// (180 pt against 156 at the default text size, 187 against 163 at the
    /// largest).
    static let leadingSlotAllowance: CGFloat = 24
    /// The control's leading-slot width at the default text size. Measured with
    /// "Gen 1:11" and with "Psa 119:156", one of the longest titles: both sit
    /// inside the title's 95 pt floor.
    static let defaultLeadingWidth: CGFloat = 180

    /// The x of the bar's first leading item.
    ///
    /// The system's window controls take the window's top-leading corner, where
    /// `containerCornerInsets` reports them (MEASURED: 66 × 75 pt), and the bar
    /// starts its items 16 pt after them (x 82). They show in a window, and in
    /// full screen too after a switch from Windowed Apps to Full-Screen Apps with
    /// the app running, where the window still covers the screen. Counted only
    /// where the leading corner's inset exceeds the trailing one's: the display's
    /// own rounding is reported in all four corners alike (15 pt on an iPad mini)
    /// and moves nothing.
    static func leadingStart(cornerInsets: RectangleCornerInsets) -> CGFloat {
        let controls = cornerInsets.topLeading.width
        guard controls > cornerInsets.topTrailing.width else { return leadingMargin }
        return max(leadingMargin, controls + itemSpacing)
    }

    /// - Parameters:
    ///   - referenceWidth: the control's width in the leading slot.
    ///   - firstTabMinX: the first tab's leading edge, in the same space as the
    ///     bar (the window).
    static func fitsLeading(
        referenceWidth: CGFloat,
        firstTabMinX: CGFloat,
        cornerInsets: RectangleCornerInsets
    ) -> Bool {
        let leadingEnd = leadingStart(cornerInsets: cornerInsets)
            + modeSwitchWidth + itemSpacing + referenceWidth
        return leadingEnd + itemSpacing <= firstTabMinX
    }

    /// The control's leading-slot width, from a measurement taken in either slot.
    static func leadingSlotWidth(measured width: CGFloat, inLeadingSlot: Bool) -> CGFloat {
        inLeadingSlot ? width : width + leadingSlotAllowance
    }

    /// The leading edge of the first tab in the tab bar floating at the top of the
    /// app's window, in window coordinates; nil when there is none there (an
    /// iPhone, and an iPad at a compact width, put the tab bar at the bottom) or
    /// it cannot be found.
    ///
    /// `UITab` is a popover source item, so `frame(in:)` is public API; SwiftUI's
    /// `TabView` does not expose the tab bar's frame. The tab bar is centred and its
    /// width follows Dynamic Type (312.5 pt at the default size, 350 at the
    /// largest), so it has to be read, not assumed. nil sends the control to the
    /// second row, where it always shows.
    @MainActor
    static func floatingTabBarLeadingEdge() -> CGFloat? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first,
              let window = scene.keyWindow ?? scene.windows.first,
              let tabBarController = tabBarController(in: window.rootViewController)
        else { return nil }
        let frames = tabBarController.tabs
            .filter { !$0.isHidden }
            .compactMap { $0.frame(in: window) }
            .filter { !$0.isEmpty }
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.midY < window.bounds.midY })
        else { return nil }
        return frames.map(\.minX).min()
    }

    @MainActor
    private static func tabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabBarController = controller as? UITabBarController {
            return tabBarController
        }
        for child in controller.children {
            if let found = tabBarController(in: child) { return found }
        }
        return nil
    }
}

/// The Read workspace: the active pane, its chrome, the Bible/commentary
/// switch, and the study surfaces the reader raises (study popup, verse menu,
/// bookmark editor).
struct ReaderScreen: View {
    let reading: ReadingWorkspaceModel

    /// Bumped by a swipe that turned the page; the haptic's trigger.
    @State private var swipePageTurns = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var chrome: ReaderChromeModel { reading.activePane.chrome }

    /// What `ReaderReferenceFit` decides from.
    ///
    /// The control's leading-slot width, from its own last layout in whichever
    /// slot it was in. Until then, its width at the default text size, so that a
    /// launch lays it out in the right slot the first time: started on the second
    /// row, it showed there for a second of every launch before moving up (MEASURED,
    /// iOS 27.2, iPad Pro 11-inch). A wrong guess corrects itself, because the
    /// control reports its width from the leading slot even when the bar drops it
    /// there (MEASURED: a pill too wide to fit, every control gone, reported 190 pt).
    @State private var referenceWidth = ReaderReferenceFit.defaultLeadingWidth
    /// The first tab's leading edge, read from UIKit whenever the tab bar can have
    /// moved. nil keeps the control on the second row, where it always shows.
    @State private var firstTabMinX: CGFloat?
    /// The reader's corners: where the system's window controls show.
    @State private var cornerInsets = RectangleCornerInsets()

    /// Where ‹ reference › goes. At a regular width the tab bar floats at the
    /// TOP, in the navigation bar's centre, and pushes a `.principal` item down to
    /// a row of its own under it (MEASURED, iOS 27.2: the bar 112 pt tall). Where
    /// it fits, the control goes LEADING instead, beside the Bible/commentary
    /// switch, on the tab bar's row; where it does not, it stays on the second
    /// row, because the bar would drop both leading items rather than either
    /// (`ReaderReferenceFit`). Where the tab bar is at the bottom — a compact
    /// width, and an iPhone at any width — the centre of the top row is free.
    ///
    /// Fit, not full screen, because neither implies the other (MEASURED, iOS
    /// 27.2): full screen, an iPad mini (756 pt) and an iPad (A16) (820 pt) in
    /// portrait, and an iPad Pro 11-inch (834 pt) at the largest text size, or in
    /// portrait with the window controls still in the corner after a switch from
    /// Windowed Apps, all lost both items.
    private var referenceGoesLeading: Bool {
        guard horizontalSizeClass == .regular,
              // The arithmetic is left to right; the app is English only.
              layoutDirection == .leftToRight,
              let firstTabMinX
        else { return false }
        return ReaderReferenceFit.fitsLeading(
            referenceWidth: referenceWidth,
            firstTabMinX: firstTabMinX,
            cornerInsets: cornerInsets
        )
    }

    private var referencePlacement: ToolbarItemPlacement {
        referenceGoesLeading ? .topBarLeading : .principal
    }

    /// Reads the tab bar's edge now, and again on the next turn of the run loop.
    ///
    /// Now, because at launch it is already laid out when the reader's first
    /// geometry arrives, and the main thread can be busy for a while after
    /// (MEASURED: a deferred read alone landed 164 ms later, with the control on
    /// the second row meanwhile). Again, because a rotation reports the reader's
    /// new size before the tab bar has moved.
    private func refreshTabBarEdge() {
        readTabBarEdge()
        DispatchQueue.main.async {
            readTabBarEdge()
        }
    }

    private func readTabBarEdge() {
        let edge = ReaderReferenceFit.floatingTabBarLeadingEdge()
        if edge != firstTabMinX {
            firstTabMinX = edge
        }
    }

    /// A width the control reported from its own slot. A report from the slot it
    /// is leaving is dropped: converted as though from the other one, it could
    /// flip the placement back.
    private func referenceWidthChanged(_ width: CGFloat, inLeadingSlot: Bool) {
        guard inLeadingSlot == referenceGoesLeading else { return }
        let leadingWidth = ReaderReferenceFit.leadingSlotWidth(
            measured: width,
            inLeadingSlot: inLeadingSlot
        )
        if leadingWidth != referenceWidth {
            referenceWidth = leadingWidth
        }
    }

    var body: some View {
        @Bindable var reading = reading

        NavigationStack {
            readerPanes
                .toolbar {
                    // The Bible/commentary switch, at the bar's LEADING edge.
                    // Declared before the reference control: at a regular width both
                    // are leading, and the declaration order is the order in the bar.
                    //
                    // Not `.bottomBar`: on iOS 27 the floating tab bar occupies the bottom, so
                    // the picker lands on top of it and taps go to the tab bar. Not
                    // `.principal` either: that slot holds the reference control, which must
                    // be the last thing a constrained width sheds.
                    ToolbarItem(placement: .topBarLeading) {
                        ReadingModePicker(reading: reading)
                    }

                    ToolbarItem(placement: referencePlacement) {
                        ReaderReferenceControl(
                            chrome: chrome,
                            makeReferencePicker: {
                                makeReferencePicker(reading: reading)
                            },
                            inLeadingSlot: referenceGoesLeading,
                            widthChanged: referenceWidthChanged
                        )
                    }
                    .visibilityPriority(.high)
                    // The control draws its own glass pill. A leading item would also
                    // get the bar's shared glass, a second layer under it, and be
                    // grouped into one capsule with the switch beside it.
                    .sharedBackgroundVisibility(.hidden)

                    // The per-module display toggles, declared ONLY when the active
                    // module has some.
                    //
                    // Not the `toolbarOverflowMenu` modifier with its content gated
                    // instead: the modifier declares the menu whatever is in it, so
                    // the system still drew the ••• button, and for the commentary
                    // (MHCC advertises no features) it opened a menu with nothing in
                    // it. Not a conditional modifier on `readerPanes` either: that
                    // changes the panes' identity on every Bible/commentary switch and
                    // drops their scroll state and deferred work.
                    if !chrome.displayToggles.isEmpty {
                        ToolbarOverflowMenu {
                            Section {
                                ForEach(chrome.displayToggles) { toggle in
                                    switch toggle.control {
                                    case .toggle:
                                        ReaderDisplayToggleButton(
                                            chrome: chrome,
                                            toggle: toggle
                                        )
                                    case .strongsDisplay:
                                        StrongsDisplayPicker(
                                            chrome: chrome,
                                            toggle: toggle
                                        )
                                    }
                                }
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
                        entries: popup.entries,
                        initial: popup.initial,
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
        // The inputs `referenceGoesLeading` decides from, other than the control's
        // own width. The tab bar is re-read after anything that can move it: a
        // rotation or window resize, the window controls coming or going (a
        // multitasking mode switch can bring them with no change of size), a text
        // size change (the tab bar grows with it), and a return to the Read tab,
        // which may have missed any of those while it was away.
        .onGeometryChange(for: CGSize.self, of: \.size) { _ in
            refreshTabBarEdge()
        }
        .onGeometryChange(for: RectangleCornerInsets.self, of: \.containerCornerInsets) { insets in
            cornerInsets = insets
            refreshTabBarEdge()
        }
        .onChange(of: dynamicTypeSize) {
            refreshTabBarEdge()
        }
        .onAppear {
            refreshTabBarEdge()
        }
    }

    /// The pane on screen, then the other one — see `readerPanes`.
    private var paneOrder: [ReadingMode] {
        reading.mode == .bible ? [.bible, .commentary] : [.commentary, .bible]
    }

    /// BOTH panes stay in the hierarchy, with the inactive one hidden.
    ///
    /// Not stylistic: `displayChapter` renders the polled pane and defers a
    /// `refToShow` / `pendingRestore` into the other, which applies it when it next
    /// becomes active — so the inactive pane has to exist to receive it. Rendering
    /// only the active pane (a plain `if`) would tear down its document and scroll
    /// position and lose the pending work.
    ///
    /// **The pane on screen comes FIRST, so the order changes with the mode.**
    /// A tap on the selected Read tab is SwiftUI's to answer as well as the app's
    /// (`AppSession.tabBarSelection`): its tab coordinator pops a pushed stack or,
    /// with none, sends the tab's content scroll view to the top, and that is the
    /// FIRST scroll view in the tab, whichever is showing. Opacity, accessibility
    /// and `scrollDisabled` do not enter into it. MEASURED (iOS 27.2) with the
    /// Bible always first: with the commentary on screen the tap moved nothing
    /// there (issue #31) and took the hidden Bible from verse 14 to the top,
    /// and a pane's scroll reports do not ask whether it is showing: they save
    /// where it goes over the place the reader had left it.
    ///
    /// A `ForEach` keyed by the mode MOVES a pane; it does not rebuild it. Each
    /// keeps its identity, and with it its document, scroll view and deferred work
    /// — what a conditional modifier would throw away (see the toolbar). The pane
    /// not showing is drawn over the one that is, at opacity 0, as the commentary
    /// always was over the Bible: a touch goes through it.
    ///
    /// The safe area is owned by `ChapterTextView` (edge-to-edge scroll view with
    /// inset content). Do not add an `ignoresSafeArea` here — a second one at this
    /// level would inset nothing and reintroduce the tab-bar overlap.
    private var readerPanes: some View {
        ZStack {
            ForEach(paneOrder, id: \.self) { mode in
                ChapterTextView(pane: mode == .bible ? reading.bible : reading.commentary)
                    .opacity(reading.mode == mode ? 1 : 0)
                    .accessibilityHidden(reading.mode != mode)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { old, new in
            // Rotation, or an iPad split-view resize: re-anchor each pane and SUPPRESS
            // the transient scroll callbacks the transition emits, which would
            // otherwise overwrite the persisted position.
            //
            // The two calls are deliberately back to back: `restoreAfterSizeChange`
            // keeps the suppression alive until its own deferred scroll has landed.
            // Do not split them across separate callbacks.
            //
            // Whether the WIDTH changed goes with them, because it decides what a
            // pane re-anchors on. This also fires for height alone — the bars
            // settling at launch, a keyboard going — which re-wraps nothing, so the
            // scroll offset is still right. After a width change the offset names
            // different text, and the verse at the top is what to return to.
            guard old != .zero, old != new else { return }
            reading.prepareForSizeChange()
            reading.restoreAfterSizeChange(widthChanged: old.width != new.width)
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
            showsCancel: UIDevice.current.userInterfaceIdiom == .phone,
            // Tiles in the iPad popover; the iPhone sheet keeps its rows and index.
            layout: UIDevice.current.userInterfaceIdiom == .pad ? .grid : .list
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
    /// The slot this instance was placed in, carried with each width it reports:
    /// the bar pads the chevrons differently in the two (`ReaderReferenceFit`).
    let inLeadingSlot: Bool
    let widthChanged: (_ width: CGFloat, _ inLeadingSlot: Bool) -> Void

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
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // Three book columns and seven chapter columns. An ideal size,
                    // not a minimum: a minimum would hold the grid at this size in
                    // a popover the window makes smaller. Measured (iOS 27.2, iPad
                    // Pro 11-inch): 440 x 636 in portrait and in landscape.
                    makeReferencePicker()
                        .frame(idealWidth: 440, idealHeight: 640)
                } else {
                    makeReferencePicker()
                        .frame(minWidth: 320)
                }
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
        // A Liquid Glass pill around ‹ reference ›, sized to the bar's own glass
        // buttons (44 pt). Drawn here because the `.principal` slot gets no shared
        // background: `sharedBackgroundVisibility(.visible)` on its `ToolbarItem`
        // drew nothing (observed on device, iOS 27). Not `.interactive()`: the
        // pill holds three buttons, each with its own press state, and an
        // interactive glass would answer a tap on any of them as one.
        .padding(.horizontal, 10)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        // Its width as laid out, the pill included: what the leading slot has to
        // find room for. The title and the text size both change it.
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
            widthChanged(width, inLeadingSlot)
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

/// The Strong's row: a submenu of Off / Numbers / Underlined Words / Invisible, with the
/// current choice under its title. A binding whose setter goes through the
/// host's write-then-redisplay path, as `ReaderDisplayToggleButton` does,
/// rather than one that owns the pref keys.
///
/// A `Menu` around an inline `Picker`, not a `.menu`-style `Picker`: that drew
/// the row with its title alone, so the choice could be seen only by opening
/// it (MEASURED, iOS 27.2). A menu's second label `Text` is its subtitle.
private struct StrongsDisplayPicker: View {
    let chrome: ReaderChromeModel
    let toggle: ReaderDisplayToggle

    var body: some View {
        Menu {
            Picker(
                LocalizedStringKey(toggle.titleKey),
                selection: Binding(
                    get: { chrome.strongsDisplay },
                    set: { display in
                        guard display != chrome.strongsDisplay else { return }
                        chrome.onStrongsDisplayChange?(display)
                    }
                )
            ) {
                ForEach(StrongsDisplay.allCases) { display in
                    Text(LocalizedStringKey(display.titleKey)).tag(display)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(LocalizedStringKey(toggle.titleKey))
            Text(LocalizedStringKey(chrome.strongsDisplay.titleKey))
        }
        .accessibilityIdentifier(
            "\(chrome.identifierPrefix).\(toggle.id)"
        )
    }
}
