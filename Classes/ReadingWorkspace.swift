//
//  ReadingWorkspace.swift
//  PocketSword
//
//  The reading workspace.
//
//  `ReadingWorkspaceModel` is the coordinator. It owns the two `ReaderPaneModel`s
//  (Bible and commentary), the chapter-load fan-out (`displayChapter`), study-popup
//  routing, and the verse-menu / bookmark-highlight state.
//  `ReadingModeSwitcher` in `SimpleScriptureApp.swift` renders whichever pane is active.
//
//  `ReaderPaneModel` is one reading surface: the chapter document, its
//  `ReaderChromeModel`, and the per-pane scroll/verse bookkeeping. Two exist for
//  the app's lifetime and both stay loaded, because `displayChapter` defers a
//  `refToShow` / `pendingRestore` into the pane it did not render.
//
//  Things that look odd and are deliberate:
//
//  * **The `refToShow` / `pendingRestore` deferral.** `displayChapter` renders the
//    polled pane immediately and hands the *other* pane a pending ref + restore
//    that it applies when it next becomes active. That is what lets a verse's
//    "commentary" action land on the right verse without rendering MHCC on every
//    Bible chapter change. `applyPendingWork()`'s branch order is load-bearing.
//  * **Chapter paging restores no position in either direction** — do not
//    "restore" a verse position on `previousChapter`. It also starts the new
//    chapter on a NEW scroll view (`ReaderPaneModel.scrollSurface`) rather than
//    scrolling the old one to the top, which did not land reliably. The swap is
//    also what the page-turn slide animates (`ReaderPaneModel.pageTurn`), so the
//    scroll view being left stays on screen for the length of the slide — which
//    is why every scroll callback names the surface it came from.
//  * **`bibleScrollPosition` / `commentaryScrollPosition`** are raw `UserDefaults`
//    string keys with no `Defaults` constant, written as `"%d"` of a `CGFloat`.
//    They are persisted; `displayChapter`'s `.scroll` arm reads them back into an
//    `.offset(_:)` restore.
//  * Cross-object coordination is method calls. The few `NotificationCenter`
//    observers left exist only because something outside this file posts them.
//

import Foundation
import Observation
import SwiftUI

/// How much of the previous position a chapter load restores. Raw values are
/// not persisted.
enum RestorePositionType: Int {
    case scroll = 1
    case verse = 2
    case none = 3
}

/// Which pane a chapter load renders immediately; the other gets the deferral.
enum PollingType: Int {
    case bible = 1
    case commentary = 2
    case none = 3
}

/// `passagestudy` attribute names; must match the literals in `globals.h`.
private enum SWRender {
    static let attrType = "type"
    static let attrAction = "action"
    static let attrValue = "value"
    static let attrModule = "modulename"

    static let featureGreekDef = "GreekDef"
    static let featureHebrewDef = "HebrewDef"
}

// MARK: - Study popup

/// A study popup the reader wants shown: a Strong's entry, a morph tag, a
/// footnote, or a lexicon entry. Carried by a `sheet(item:)` binding.
struct StudyPopup: Identifiable, Equatable {
    let id = UUID()
    let content: PSInfoPopupContent

    static func == (lhs: StudyPopup, rhs: StudyPopup) -> Bool {
        lhs.id == rhs.id
    }
}

/// The verse-menu action sheet's subject.
struct VerseMenuTarget: Identifiable, Equatable {
    var id: Int { verse }
    let verse: Int
    /// The book-and-chapter reference the verse belongs to, already munged
    /// through `+createRefString:` — what the bookmark editor persists.
    let chapterRef: String
}

/// A bookmark the user is adding from the verse menu.
struct BookmarkDraft: Identifiable, Equatable {
    let id = UUID()
    let chapterRef: String
    let verse: String

    var reference: String {
        "\(chapterRef):\(verse)"
    }

    static func == (lhs: BookmarkDraft, rhs: BookmarkDraft) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - One reading pane

/// One geometry sample from the reading scroll view.
///
/// `offset` is `contentOffset.y + contentInsets.top` — the persisted value. The
/// two heights let the model tell three cases apart, which the launch restore
/// depends on:
///
///  * a scroll view that has **not been laid out yet** publishes all-zero
///    geometry. Its `offset` of 0 is the absence of an answer, not a position;
///    persisting it would overwrite `bibleScrollPosition` with 0 before the
///    restore runs, and every later launch would restore that 0.
///  * an offset restore that has **landed** reports the value that was asked for.
///  * an offset restore that **cannot** land — the chapter is shorter than the
///    saved offset, e.g. because the font grew — reports the largest offset the
///    geometry allows, `contentSize.height - containerSize.height` exactly.
struct ReaderScrollSample: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerHeight: CGFloat

    /// The largest `offset` this geometry can reach.
    var maxOffset: CGFloat { max(0, contentHeight - containerHeight) }

    /// Whether this sample is an answer at all.
    var isLaidOut: Bool { contentHeight > 0 && containerHeight > 0 }
}

/// One reading surface: the chapter document, its chrome, and its scroll/verse
/// state. Two exist for the app's lifetime (Bible and commentary).
@MainActor
@Observable
final class ReaderPaneModel {
    let mode: ReadingMode
    @ObservationIgnored let chrome: ReaderChromeModel

    /// The rendered chapter. Only ever replaced WHOLESALE, which is what makes the
    /// paragraph cache below safe.
    var document = ChapterDocument() {
        didSet { paragraphs = document.paragraphs }
    }

    /// `document.verses` regrouped into flowing paragraphs — the prose layout's row
    /// set — derived once per document instead of once per body evaluation.
    ///
    /// `ChapterDocument.paragraphs` walks and reallocates every verse, so it must
    /// not be called from a view body (Psalm 119 is 176 verses). Cached here rather
    /// than on `ChapterDocument` so the value type keeps the synthesized
    /// conformances the parity tests use, and so it cannot go stale: the only way
    /// to change the rows is to assign `document`.
    private(set) var paragraphs: [ChapterParagraph] = []

    /// Where the scroll view is. `ScrollPosition` addresses a verse by IDENTITY,
    /// which is what lets the `versepos` pixel table and its rotation re-measure go.
    var scrollPosition = ScrollPosition(idType: Int.self)

    /// Verse-per-line, read per-module. Drives the row unit in `ChapterTextView`;
    /// the document itself is layout-agnostic.
    var versePerLine = false

    /// Resolved font/size/line-height for this render.
    var textStyle = ChapterTextRenderer.Style.current()

    /// The terms to highlight in the rendered text.
    ///
    /// Pushed into `textStyle` on assignment, so an existing render re-highlights
    /// without reloading the chapter. Clear it by assigning `[]`.
    ///
    /// A list because an "all words" / "any words" query matches on several, and
    /// the results list highlights each of them.
    var searchHighlightTerms: [String] = [] {
        didSet {
            guard searchHighlightTerms != oldValue else { return }
            textStyle.highlightTerms = searchHighlightTerms
        }
    }

    /// A chapter this pane should render the next time it appears, with the
    /// position to restore. Set by `displayChapter` for the pane it did NOT poll.
    @ObservationIgnored var refToShow: String?
    @ObservationIgnored var pendingRestore: PaneRestore?

    /// What a deferred (or immediate) render should restore: a verse, an offset, or
    /// nothing.
    enum PaneRestore: Equatable {
        case verse(Int)
        case offset(CGFloat)
        case none
        /// The top of a chapter the reader has PAGED to. Lands where `.none` does,
        /// but on a new scroll view rather than by scrolling the old one — see
        /// `scrollSurface` — and persists that position.
        case chapterStart
    }

    /// The identity of this pane's scroll view: `ChapterTextView` keys its
    /// `ScrollView` on it, so bumping it replaces the scroll view outright.
    ///
    /// **Paging bumps it, because scrolling the old scroll view to the top of a new
    /// chapter does not land reliably.** The two chapters share row ids (verse
    /// numbers), and the old scroll view keeps the row it was anchored to and any
    /// momentum it had, so the scroll to the top races all of them. Measured on the
    /// simulator, paging straight after a flick left verse 1 in the wrong place in
    /// 7 chevron pages in 120 (resting too low, still drifting on the old momentum,
    /// or shifted sideways), and in 8 swipes in 32 from the foot of a chapter. A new
    /// scroll view has nothing to carry over: 0 in 152.
    ///
    /// Only paging takes this path. Every other restore keeps its scroll view, so a
    /// display toggle or a font change does not flash or lose its place.
    ///
    /// The scroll view being replaced does not go at once: it slides out
    /// (`pageTurn`), and until it has it is still live. `scrollOffsetChanged` and
    /// `topmostVerseChanged` take the surface reporting for that reason.
    private(set) var scrollSurface = 0

    /// A page turn for `ChapterTextView` to animate: the slide from the scroll
    /// surface being left to the new one.
    struct PageTurn: Equatable {
        /// How many times this pane has paged WHILE IT WAS SHOWING. The view
        /// animates when this changes, and only then.
        var count = 0
        /// Which way the last one went. Forward brings the new chapter in from the
        /// right; back, from the left.
        var forward = true
    }

    /// Separate from `scrollSurface` on purpose. The surface is also bumped when a
    /// DEFERRED page is drained — the reader paged the Bible and then switched to
    /// the commentary — and that pane is appearing, not turning a page: sliding it
    /// in would animate a chapter change the user made some time ago.
    private(set) var pageTurn = PageTurn()

    /// Called by the workspace for the pane a page turn is rendered into, before
    /// it renders.
    func notePageTurn(forward: Bool) {
        pageTurn = PageTurn(count: pageTurn.count + 1, forward: forward)
    }

    @ObservationIgnored private var currentShownVerse = 1
    @ObservationIgnored private var verseToShow = 0
    /// Suppresses the transient scroll callbacks a size change produces, so a
    /// mid-transition offset is not mistaken for the user scrolling.
    @ObservationIgnored private var isRestoringAfterTransition = false
    /// Which size change the suppression above belongs to. `restoreAfterSizeChange`
    /// clears the flag from a deferred hop, and only if no newer transition has
    /// started — so two rotations in quick succession cannot have the first one's
    /// hop re-enable persisting while the second is still settling.
    @ObservationIgnored private var sizeChangeGeneration = 0
    /// The last scroll offset seen, clamped at 0 (see `scrollOffsetChanged`).
    @ObservationIgnored private var lastScrollOffset: CGFloat = 0
    /// An offset restore that has been requested but not yet observed to have landed.
    /// Two things read it, and both are load-bearing: `scrollOffsetChanged` (do not
    /// persist a position from before the restore lands) and `restoreAfterSizeChange`
    /// (do not re-anchor on a verse while an offset restore is still in flight).
    @ObservationIgnored private var outstandingOffsetRestore: CGFloat?

    @ObservationIgnored weak var workspace: ReadingWorkspaceModel?

    init(mode: ReadingMode) {
        self.mode = mode
        self.chrome = ReaderChromeModel()
        chrome.isBibleTab = (mode == .bible)
    }

    // MARK: Chapter text

    /// The pref keys this pane reads and writes. The Bible pane and the
    /// commentary pane keep entirely separate verse/scroll positions, which is
    /// what lets one land on John 3:20 while the other sits at John 3:1.
    private var versePositionKey: String {
        mode == .bible
            ? Defaults.bibleVersePosition
            : Defaults.commentaryVersePosition
    }

    /// The raw scroll-offset key. Deliberately a literal: `"bibleScrollPosition"`
    /// / `"commentaryScrollPosition"` never had a `Defaults` constant, and both
    /// are persisted, so the strings are load-bearing.
    private var scrollPositionKey: String {
        mode == .bible ? "bibleScrollPosition" : "commentaryScrollPosition"
    }

    /// Renders `ref` into this pane now and applies `restore`. Bookmark highlight
    /// colours, verse anchors and link targets are all in the document value.
    func render(ref: String?, restore: PaneRestore) {
        guard let ref else {
            document = ChapterDocument()
            return
        }
        // A nil primary is RESOLVED here via `reloadLast*` (which falls back to the
        // bundled module), then `newPrimary*` is posted so the display-toggle rows are
        // rebuilt. Only if it is still nil does the pane show "no content".
        //
        // Safe to post from here only because the sole `.newPrimary*` handler,
        // `refreshForModuleChange()`, never calls `render` / `displayChapter`. If a
        // future observer does, this becomes a render loop. Note `reloadLast*` may
        // write the last-module default on its fallback path.
        var resolved = moduleName
        if resolved == nil {
            let controller = PSModuleController.default()
            switch mode {
            case .bible: controller?.reloadLastBible()
            case .commentary: controller?.reloadLastCommentary()
            }
            resolved = moduleName
            if resolved != nil {
                NotificationCenter.default.post(
                    name: mode == .bible ? .newPrimaryBible : .newPrimaryCommentary,
                    object: nil
                )
            }
        }
        guard let module = resolved else {
            var empty = ChapterDocument()
            empty.emptyMessage = NSLocalizedString(
                "NoModulesInstalled",
                comment: "Shown in the reader when no module could be resolved."
            )
            document = empty
            return
        }
        // `lastRef` is persisted HERE: `getCurrentBibleRef()` and the chrome title
        // read it, and relaunch restores from it. Written before the document is built
        // because `PSBookmarks.getBookmarksForCurrentRef()` reads it for the highlight
        // lookup.
        UserDefaults.standard.set(
            PSModuleController.createRefString(ref),
            forKey: Defaults.lastRef
        )
        versePerLine = UserDefaults.standard.psBool(
            Defaults.vplPreference, forModule: module
        )
        // Re-resolve font/size, but carry the search highlight across — rebuilding
        // the style from defaults alone would silently drop it.
        var style = ChapterTextRenderer.Style.current()
        style.highlightTerms = searchHighlightTerms
        textStyle = style
        document = PSContentReader.shared.chapterDocument(
            module: module,
            ref: ref,
            kind: mode == .bible ? .bible : .commentary
        ) ?? ChapterDocument()
        apply(restore)
    }

    /// Move the scroll view, by identity or by offset.
    ///
    /// In prose mode a verse may sit inside a paragraph whose row id is an earlier
    /// verse, so the target is resolved to the enclosing row — otherwise
    /// `scrollTo(id:)` would silently do nothing for most verses.
    ///
    /// **The scroll is applied one update after the document assignment, and that
    /// is load-bearing.** In the same update the target resolves against the row
    /// set being replaced, so the request is dropped and the old content offset is
    /// kept against new row heights (e.g. flipping Verse Per Line at Gen 1:1 landed
    /// on verse 6). Affects font changes and every display toggle.
    private func apply(_ restore: PaneRestore) {
        switch restore {
        case .verse(let verse):
            guard verse > 0 else { return }
            // A newer instruction supersedes an offset restore that has not landed.
            outstandingOffsetRestore = nil
            // Until the target lands, the previous chapter/position's offset is not
            // evidence for this restore. A size change in that window must reissue the
            // verse target rather than replaying stale pixels.
            lastScrollOffset = 0
            currentShownVerse = verse
            verseToShow = 0
            let target = rowID(containing: verse)
            Task { @MainActor [weak self] in
                self?.scrollPosition.scrollTo(id: target, anchor: .top)
            }
        case .offset(let offset):
            guard offset > 0 else {
                outstandingOffsetRestore = nil
                return
            }
            lastScrollOffset = offset
            // Recorded BEFORE the hop: the scroll view publishes geometry (and
            // `scrollOffsetChanged` would persist it) before the hop runs.
            outstandingOffsetRestore = offset
            Task { @MainActor [weak self] in
                self?.scrollPosition.scrollTo(y: offset)
            }
        case .none:
            // A chapter change lands at the top, which is what
            // `RestoreNoPosition` meant.
            outstandingOffsetRestore = nil
            lastScrollOffset = 0
            currentShownVerse = 1
            Task { @MainActor [weak self] in
                self?.scrollPosition.scrollTo(edge: .top)
            }
        case .chapterStart:
            // A new scroll view (see `scrollSurface`), and a new position to go with
            // it: the old one names a row of the chapter being left, and the chapter
            // arriving has a row with the same id.
            outstandingOffsetRestore = nil
            lastScrollOffset = 0
            scrollPosition = ScrollPosition(idType: Int.self)
            scrollSurface += 1
            // Persisted HERE because nothing else will. A scroll view that starts at
            // the top publishes no offset change and no new topmost verse, so the keys
            // would keep the position in the chapter being left — and `setToPreviousChapter`
            // has just written the destination's LAST verse into the verse key. A
            // relaunch (`.scroll`) or a display toggle (`.verse`) would land there.
            persistPosition(verse: 1, scrollOffset: 0)
        }
    }

    /// Applies deferred work when the pane becomes active.
    ///
    /// The order is load-bearing: a pending ref wins over a pending restore, which
    /// wins over a pending verse scroll. Collapsing these into "do whatever is set"
    /// would re-render a chapter that was only meant to scroll.
    func applyPendingWork() {
        if let ref = refToShow {
            render(ref: ref, restore: pendingRestore ?? .none)
            refToShow = nil
            pendingRestore = nil
        } else if let restore = pendingRestore {
            apply(restore)
            pendingRestore = nil
        } else if verseToShow > 0 {
            scrollToVerse(verseToShow)
        }
    }

    // MARK: Verse position

    func setVerseToShow(_ verse: Int) {
        verseToShow = verse
    }

    func scrollToVerse(_ verse: Int) {
        apply(.verse(verse))
    }

    /// The id of the row that displays `verse`.
    ///
    /// In verse-per-line mode every verse is its own row, so this is the identity.
    /// In prose mode rows are paragraphs keyed by their FIRST verse, so a verse in
    /// the middle of a paragraph has to resolve to that paragraph's id. This is the
    /// one place the prose layout costs something: the scroll lands at the top of
    /// the verse's paragraph rather than exactly on the verse.
    private func rowID(containing verse: Int) -> Int {
        if versePerLine {
            // Every verse is its own row — but only among rows the document actually
            // HAS, which is not the same thing on a commentary. See below.
            if document.verses.contains(where: { $0.number == verse }) { return verse }
            return document.verses.map(\.number).filter { $0 <= verse }.max() ?? verse
        }
        var nearestPreceding: Int?
        for paragraph in paragraphs {
            guard let first = paragraph.verses.first?.number,
                  let last = paragraph.verses.last?.number else { continue }
            if verse >= first && verse <= last {
                return first
            }
            // Remember the closest row that STARTS at or before the target, for the
            // fall-through below.
            if first <= verse {
                nearestPreceding = max(nearestPreceding ?? first, first)
            }
        }
        // Fall back to the nearest PRECEDING row, not `verse` itself. A commentary
        // record covers a RANGE of verses and the document has a row only where one
        // begins (MHCC John 3 has rows 1 and 22), and `scrollTo(id:)` silently ignores
        // an unknown id. The covering record is the text discussing that verse.
        return nearestPreceding ?? verse
    }

    /// A scroll came to rest at `offset`: work out which verse that is and persist
    /// it. `ScrollPosition` does not expose the topmost id, so the offset is kept
    /// and the verse only advanced when the reader actually moves.
    ///
    /// `surface` is the scroll view reporting — `scrollSurface` as `ChapterTextView`
    /// captured it — and a report from one that has been replaced is dropped. A
    /// page turn leaves the scroll view of the chapter being left on screen until
    /// its slide ends, still coasting on whatever flick it had, and it goes on
    /// reporting. MEASURED on iOS 27.2, paging straight after a flick: 26 offsets
    /// and topmost verses from the old chapter in the 420 ms AFTER the new one's
    /// position was persisted, any of which would have overwritten it.
    func scrollOffsetChanged(_ sample: ReaderScrollSample, from surface: Int) {
        guard surface == scrollSurface, !isRestoringAfterTransition else { return }
        // A scroll view with no content has not answered the question: its 0 is not
        // the top of the chapter, and persisting it would clobber the saved offset.
        guard sample.isLaidOut else { return }
        let normalized = max(0, sample.offset)
        if let target = outstandingOffsetRestore {
            if abs(normalized - target) <= Self.scrollThreshold {
                // Landed. `lastScrollOffset` and the persisted key both already hold
                // the target, so there is nothing to write.
                outstandingOffsetRestore = nil
                return
            }
            if target > sample.maxOffset,
               normalized >= sample.maxOffset - Self.scrollThreshold {
                // Unreachable: the chapter is shorter than the saved offset (bigger font,
                // fewer rows). That IS the position now, so persist it — suppressing forever
                // would stop saving the user's scrolls for the rest of the session.
                outstandingOffsetRestore = nil
            } else {
                // Still in flight. Every offset published between the request and the
                // landing is the scroll view saying where it WAS, and persisting one
                // of them overwrites the value being restored.
                return
            }
        }
        // The two-point threshold matters: without it a sub-pixel geometry republish
        // counts as a scroll and rewrites the persisted position on every layout pass.
        guard abs(lastScrollOffset - normalized) > Self.scrollThreshold else { return }
        lastScrollOffset = normalized
        persistPosition(verse: currentShownVerse, scrollOffset: normalized)
    }

    /// The two-point dead zone. The restore gate above uses it too, so a restore
    /// counts as landed to the same tolerance a scroll counts as moved.
    private static let scrollThreshold: CGFloat = 2

    /// A finger landed on the reader: abandon any restore still in flight.
    ///
    /// This is what makes `outstandingOffsetRestore` a gate rather than a timeout. If
    /// a restore ever neither lands nor pins, the user's first touch resumes normal
    /// persistence instead of suppressing it for the rest of the session.
    func userBeganScrolling() {
        outstandingOffsetRestore = nil
    }

    /// The topmost visible verse changed, as reported by the view.
    ///
    /// The verse and the offset are persisted from two different places because only
    /// the view knows which row is at the top — see `tracksTopmostVerse`. Both write
    /// through `persistPosition`, so the pair stays consistent whichever moves first.
    ///
    /// Dropped when `surface` has been replaced — see `scrollOffsetChanged`.
    func topmostVerseChanged(_ verse: Int, from surface: Int) {
        guard surface == scrollSurface else { return }
        // The clamp lives in `persistPosition`, so comparing the RAW value here
        // would let verse 0 through as "changed" forever (0 != 1) and rewrite the
        // position on every layout pass.
        let clamped = max(1, verse)
        guard !isRestoringAfterTransition, clamped != currentShownVerse else { return }
        persistPosition(verse: clamped, scrollOffset: lastScrollOffset)
    }

    /// Called by the view when a link in the chapter text is tapped.
    func handle(link: InlineLink) {
        route(link)
    }

    /// Writes the verse and scroll offset this pane is showing, and retitles the
    /// chrome. The persisted offset is `"%d"` of a `CGFloat` — a truncated integer
    /// in a string.
    private func persistPosition(verse: Int, scrollOffset: CGFloat) {
        // Clamped at the single write point, so no caller can persist verse 0. The
        // intro slot is loop counter 0, so a chapter opening with an intro (most MHCC
        // chapters) reports verse 0 as topmost; persisted, a later `.verse` restore of
        // 0 would silently do nothing.
        let verse = max(1, verse)
        currentShownVerse = verse
        let verseString = String(format: "%d", Int32(verse))
        let defaults = UserDefaults.standard
        defaults.set(
            String(format: "%d", Int32(scrollOffset)),
            forKey: scrollPositionKey
        )
        defaults.set(verseString, forKey: versePositionKey)

        let ref = "\(PSModuleController.getCurrentBibleRef() ?? ""):\(verseString)"
        setTitle(ref)
    }

    // MARK: Chrome

    /// Pushes a reference into the chrome, munged through `createTitleRefString`.
    /// The un-munged form becomes the accessibility label.
    func setTitle(_ title: String?) {
        // Assigned only on an actual change: this runs every ~2pt of scroll, and an
        // `@Observable` setter invalidates observers even for an identical value.
        let munged = PSModuleController.createTitleRefString(title) ?? ""
        if chrome.title != munged {
            chrome.title = munged
        }
        let reference = PSModuleController.getCurrentBibleRef() ?? ""
        if chrome.accessibilityReference != reference {
            chrome.accessibilityReference = reference
        }
    }

    /// The active module for this pane, by name — the primary Bible on the Bible
    /// pane, the primary commentary on the commentary pane. Drives both the
    /// display-toggle gating and the per-module pref keys those toggles write.
    var moduleName: String? {
        mode == .bible
            ? PSModuleController.default()?.primaryBibleName
            : PSModuleController.default()?.primaryCommentaryName
    }

    var redisplayNotification: Notification.Name {
        mode == .bible ? .redisplayPrimaryBible : .redisplayPrimaryCommentary
    }

    func rebuildDisplayToggles() {
        chrome.reloadDisplayToggles(forModule: moduleName)
    }

    /// The commentary pane's empty state: no commentary installed means there is
    /// nothing to page through, so the title becomes the app name and both
    /// chapter buttons go dead.
    func refreshForModuleChange() {
        rebuildDisplayToggles()
        guard mode == .commentary, moduleName == nil else { return }
        chrome.title = "PocketSword"
        chrome.accessibilityReference = "PocketSword"
        chrome.isNextEnabled = false
        chrome.isPreviousEnabled = false
    }

    // MARK: Size changes

    /// Rotation, or an iPad split-view resize.
    ///
    /// Scroll identity is width-independent, so nothing needs re-measuring. All
    /// that is needed is suppressing the transient scroll callbacks the transition
    /// produces, which would otherwise overwrite the persisted position.
    func prepareForSizeChange() {
        sizeChangeGeneration += 1
        isRestoringAfterTransition = true
    }

    /// **The suppression has to outlive this call.** `ReaderScreen` calls
    /// `prepareForSizeChange()` and `restoreAfterSizeChange()` back to back in one
    /// `onGeometryChange` action, so clearing the flag synchronously would let every
    /// transient rotation callback overwrite the saved position.
    ///
    /// A prose paragraph is one flowing `Text`, not one scroll target per verse, so
    /// re-anchoring to `rowID(containing:)` would jump to the paragraph's first
    /// verse. Preserve the actual scroll offset across the size change instead; the
    /// per-verse layout tracker updates the title independently.
    func restoreAfterSizeChange() {
        let generation = sizeChangeGeneration
        // An OFFSET restore still in flight wins over `currentShownVerse`.
        //
        // The reader's size settles in steps at launch ((402, 0) → (402, 623) →
        // (402, 675) as the nav bar and tab bar come in), so this hook fires during
        // launch, after an `.offset` restore is requested but before it lands.
        // Re-anchoring on `currentShownVerse` (still 1 — an offset restore names no
        // verse) would drag the reader back to the top. `.verse` restores are
        // unaffected because they set `currentShownVerse` first.
        //
        // A positive offset is preserved exactly. Zero is different: `scrollTo(y: 0)`
        // bypasses the top content margin and paints verse 1 under the navigation bar,
        // so an unknown/top position uses the verse target instead.
        let restoreOffset = outstandingOffsetRestore
            ?? (lastScrollOffset > 0 ? lastScrollOffset : nil)
        let verseTarget = restoreOffset == nil
            ? rowID(containing: max(1, currentShownVerse))
            : nil
        // Cleared unconditionally: a stale `verseToShow` would let a later
        // appearance scroll to a verse the user never asked for.
        verseToShow = 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let restoreOffset {
                self.scrollPosition.scrollTo(y: restoreOffset)
            } else if let verseTarget {
                self.scrollPosition.scrollTo(id: verseTarget, anchor: .top)
            }
            guard self.sizeChangeGeneration == generation else { return }
            self.isRestoringAfterTransition = false
        }
    }

}

// MARK: - Link routing

extension ReaderPaneModel {

    /// Routes a tapped chapter link to its study surface. MHCC's own `sword://`
    /// scripture links are not routed here: the view's `openURL` falls through to
    /// `.systemAction`, which reaches `AppSession`'s router.
    func route(_ link: InlineLink) {
        switch link {
        case .verseMenu(let verse):
            // Bible only: a commentary's verse number has never opened the verse menu.
            // The renderer does not attach the link on a commentary either.
            if mode == .bible {
                workspace?.presentVerseMenu(verse: verse)
            }
        case .strongs(let type, let value):
            let (entry, popup) = strongsPopup(type: type, value: value)
            present(entry: entry, popup: popup)
        case .morph(let type, let value):
            present(entry: morphEntry(type: type, value: value), popup: nil)
        case .note(let kind, let value, let module, let passage):
            // Only `n` renders a body; `x` is unreachable for the shipped content.
            guard kind == "n" else { return }
            present(
                entry: footnoteEntry(value: value, module: module, passage: passage),
                popup: nil
            )
        case .scriptRef(let value):
            // Unreachable for the shipped corpus. Logged rather than silently
            // dropped so that if a future module does emit one, it says so.
            alog("chapter carries a scriptRef link, which the shipped content never "
                 + "did — ignoring: \(value)")
        }
    }

    private func present(entry: String?, popup: PSInfoPopupContent?) {
        if let popup {
            workspace?.showStudyPopup(popup)
            return
        }
        if let entry {
            workspace?.showStudyPopup(PSInfoPopupContent(html: entry))
        }
    }

    /// A Strong's number tapped in the chapter text. The lexicon is chosen by the
    /// link's own `type=Hebrew|Greek`, not by a preference — the roles are fixed.
    private func strongsPopup(
        type: String,
        value: String
    ) -> (String?, PSInfoPopupContent?) {
        let hebrew = type == "Hebrew"
        let module = hebrew
            ? BundledModules.strongsHebrew
            : BundledModules.strongsGreek
        let rawNumber = value
        let reference = "\(hebrew ? "H" : "G")\(rawNumber)"

        var entry = PSContentReader.entry(module: module, key: rawNumber)
        let hasDefinition = entry != nil
        // The raw entry is what the popup's lemma parser reads and what it renders.
        let rawEntry = hasDefinition ? entry : nil
        if entry == nil {
            entry = NSLocalizedString(
                hebrew
                    ? "NoHebrewStrongsNumbersModuleInstalled"
                    : "NoGreekStrongsNumbersModuleInstalled",
                comment: ""
            )
        }
        guard let entry else { return (nil, nil) }
        return (
            entry,
            PSInfoPopupContent(
                strongsHTML: entry,
                rawEntry: rawEntry,
                reference: reference,
                // "Find all occurrences" is Bible-only: the commentary has no
                // Strong's index to search.
                allowsSearch: hasDefinition && mode == .bible
            )
        )
    }

    private func morphEntry(type: String, value: String) -> String? {
        let module = BundledModules.morphGreek
        var entry: String?
        if type.hasPrefix("strongMorph") {
            entry = NSLocalizedString("MorphHebrewNotSupported", comment: "")
        } else {
            entry = PSContentReader.entry(module: module, key: value)
            if entry == nil {
                entry = NSLocalizedString(
                    "NoMorphGreekModuleInstalled",
                    comment: ""
                )
            }
        }
        return entry
    }

    /// A footnote body.
    ///
    /// `passage` arrives URL-encoded (`Genesis+4%3A1`); `PSContentReader.noteBody`
    /// decodes it. The module on the LINK is preferred over the pane's.
    private func footnoteEntry(value: String, module: String, passage: String) -> String? {
        let lookupModule = module.isEmpty ? moduleName : module
        guard let lookupModule else { return nil }
        var entry = PSContentReader.shared.noteBody(
            module: lookupModule,
            osisRef: passage,
            marker: value
        )
        // The `*x` / `*n` unescaping the popup path has always applied; the leading
        // `*` is an artifact of the markup filters.
        entry = entry?.replacingOccurrences(of: "*x", with: "x")
        entry = entry?.replacingOccurrences(of: "*n", with: "n")
        return entry
    }

}

// MARK: - The workspace

/// The reading workspace: two panes, the chapter-load fan-out between them, and
/// the study surfaces they raise.
@MainActor
@Observable
final class ReadingWorkspaceModel {
    /// Which pane is showing.
    var mode: ReadingMode = .bible {
        didSet {
            guard mode != oldValue else { return }
            session?.reading.mode = mode
            activePane.applyPendingWork()
            activePane.rebuildDisplayToggles()
        }
    }

    /// The study popup (Strong's / morph / footnote / lexicon), presented as a
    /// sheet by the reader rather than posted through `NotificationShowInfoPane`.
    var studyPopup: StudyPopup?
    var verseMenuTarget: VerseMenuTarget?
    var bookmarkDraft: BookmarkDraft?

    let bible = ReaderPaneModel(mode: .bible)
    let commentary = ReaderPaneModel(mode: .commentary)

    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The search-history item carried between the reader and the search
    /// workspace, so reopening search restores the last query and its results.
    @ObservationIgnored var savedSearchHistoryItem: PSSearchHistoryItem?
    @ObservationIgnored var savedSearchResultsMode: ReadingMode = .bible

    var activePane: ReaderPaneModel {
        mode == .bible ? bible : commentary
    }

    init(session: AppSession? = nil) {
        self.session = session
        bible.workspace = self
        commentary.workspace = self
        // The back-edge: `AppSession.open(_:)` sets `mode` when a sword:// URL names
        // a commentary, and it has no other way to reach this object.
        session?.readingWorkspace = self
        configureChrome(bible)
        configureChrome(commentary)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Start

    /// Renders the persisted chapter and starts observing the notifications that
    /// have posters outside this file: `resetBibleAndCommentaryView` (font/size,
    /// via `SettingsModel`), `redisplayPrimary{Bible,Commentary}` (display toggles
    /// and the `sword://` router), `bookmarksChanged`, and
    /// `newPrimary{Bible,Commentary}` (module load, including `render`'s nil-primary
    /// recovery).
    func start() {
        _ = PSModuleController.default()

        // Observers are registered BEFORE anything posts. The `.newPrimaryBible`
        // post below builds the display-toggle rows, and getting this order wrong
        // is silent: the overflow menu just has no display section. Both panes are
        // also primed explicitly at the end.
        observe(.resetBibleAndCommentaryView) { [weak self] in
            self?.redisplayWithDefaults()
        }
        observe(.redisplayPrimaryBible) { [weak self] in
            self?.redisplay(pane: .bible, restore: .verse)
        }
        observe(.redisplayPrimaryCommentary) { [weak self] in
            self?.redisplay(pane: .commentary, restore: .verse)
        }
        observe(.bookmarksChanged) { [weak self] in
            self?.redisplayAfterBookmarksChange()
        }
        observe(.newPrimaryBible) { [weak self] in
            self?.bible.refreshForModuleChange()
        }
        observe(.newPrimaryCommentary) { [weak self] in
            self?.commentary.refreshForModuleChange()
        }

        // The post covers a module *change*; priming directly covers the first
        // render, where nothing has changed yet.
        NotificationCenter.default.post(name: .newPrimaryBible, object: nil)
        bible.refreshForModuleChange()
        commentary.refreshForModuleChange()

        let lastRef = PSModuleController.getCurrentBibleRef()
        // Always the scroll offset. A `sword://` launch needs nothing else here:
        // `RootView` runs `start()` and THEN `replayPendingURL()`, whose `open(_:)`
        // persists the URL's ref and verse and posts `.redisplayPrimaryBible`, so a
        // `.verse` re-render lands immediately after this one. `lastOpenedURL` is
        // always nil at this point.
        displayChapter(lastRef, polling: .bible, restore: .scroll)
    }

    private func observe(
        _ name: Notification.Name,
        _ handler: @escaping @MainActor () -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append(observer)
    }

    private func configureChrome(_ pane: ReaderPaneModel) {
        let chrome = pane.chrome
        chrome.onPreviousChapter = { [weak self] in
            self?.previousChapter()
        }
        chrome.onNextChapter = { [weak self] in
            self?.nextChapter()
        }
        chrome.onDisplayToggle = { [weak self, weak pane] toggle in
            guard let self, let pane else { return }
            self.applyDisplayToggle(toggle, on: pane)
        }
    }

    /// Flips a per-module display pref and re-renders. The key is
    /// `"<pref>_<ModuleName>"`, unchanged — that format is persisted.
    private func applyDisplayToggle(
        _ toggle: ReaderDisplayToggle,
        on pane: ReaderPaneModel
    ) {
        guard let module = pane.moduleName else { return }
        let defaults = UserDefaults.standard
        let current = defaults.psBool(toggle.preference, forModule: module)
        defaults.psSet(!current, forPref: toggle.preference, module: module)
        NotificationCenter.default.post(
            name: pane.redisplayNotification,
            object: nil
        )
        pane.rebuildDisplayToggles()
    }

    // MARK: Chapter loading

    /// Loads `ref` into one pane and defers it into the other. Deliberate:
    ///
    ///  1. **Only the polled pane renders.** The other is handed `refToShow` +
    ///     `pendingRestore` and renders when it next becomes active, which stops
    ///     every Bible chapter change from also rendering MHCC. An inbound
    ///     `sword://` route must DISCARD that deferral rather than drain it — see
    ///     `showRoutedMode(_:)`.
    ///  2. **Each pane's restore is built from its own verse-position pref**; they
    ///     track position independently.
    ///  3. **Each pane's title verse comes from that pane's OWN verse-position
    ///     pref.** Sharing one value would title the Bible pane with a stale
    ///     commentary verse on a `.verse` restore (e.g. "John 3:4" while scrolled to
    ///     3:16). `.scroll` reads each key separately and `.none` forces both to
    ///     "1"; don't collapse those either.
    func displayChapter(
        _ ref: String?,
        polling: PollingType,
        restore position: RestorePositionType
    ) {
        let defaults = UserDefaults.standard
        var bibleRestore = ReaderPaneModel.PaneRestore.none
        var commentaryRestore = ReaderPaneModel.PaneRestore.none
        // The `.verse` arm below reassigns `versePosition` to the commentary's key,
        // so the Bible title's value has to be captured first — see (3) above.
        let bibleVersePosition = defaults.string(forKey: Defaults.bibleVersePosition)
        var versePosition = bibleVersePosition

        switch position {
        case .scroll:
            if let scroll = defaults.string(forKey: "bibleScrollPosition") {
                bibleRestore = .offset(CGFloat((scroll as NSString).doubleValue))
            }
            if let scroll = defaults.string(forKey: "commentaryScrollPosition") {
                commentaryRestore = .offset(CGFloat((scroll as NSString).doubleValue))
            }
        case .verse:
            if let verse = versePosition {
                bibleRestore = .verse((verse as NSString).integerValue)
                bible.setVerseToShow((verse as NSString).integerValue)
            }
            versePosition = defaults.string(forKey: Defaults.commentaryVersePosition)
            if let verse = versePosition {
                commentaryRestore = .verse((verse as NSString).integerValue)
                commentary.setVerseToShow((verse as NSString).integerValue)
            }
        case .none:
            // Paging — the only caller that passes `.none`. Each pane starts the new
            // chapter on a new scroll surface, the deferred one when it is drained.
            bibleRestore = .chapterStart
            commentaryRestore = .chapterStart
        }

        switch polling {
        case .bible:
            bible.render(ref: ref, restore: bibleRestore)
            commentary.refToShow = ref
            commentary.pendingRestore = commentaryRestore
        case .commentary:
            commentary.render(ref: ref, restore: commentaryRestore)
            bible.refToShow = ref
            bible.pendingRestore = bibleRestore
        case .none:
            bible.refToShow = ref
            bible.pendingRestore = bibleRestore
            commentary.refToShow = ref
            commentary.pendingRestore = commentaryRestore
        }

        var bibleVerse = bibleVersePosition ?? "1"
        var commentaryVerse = versePosition ?? "1"
        switch position {
        case .scroll:
            commentaryVerse = defaults.string(
                forKey: Defaults.commentaryVersePosition
            ) ?? "1"
        case .verse:
            break
        case .none:
            bibleVerse = "1"
            commentaryVerse = "1"
        }

        let refString = PSModuleController.createRefString(ref) ?? ""
        let controller = PSModuleController.default()
        if controller?.primaryBibleName != nil {
            bible.setTitle("\(refString):\(bibleVerse)")
        }
        if controller?.primaryCommentaryName != nil {
            commentary.setTitle("\(refString):\(commentaryVerse)")
        }

        updateChapterButtonState()
    }

    /// The three-way next/previous enablement. Both panes get the same state,
    /// because both navigate the same versification.
    private func updateChapterButtonState() {
        let current = PSModuleController.getCurrentBibleRef()
        let atLast = current == PSModuleController.getLastRefAvailable()
        let atFirst = current == PSModuleController.getFirstRefAvailable()
        for pane in [bible, commentary] {
            pane.chrome.isNextEnabled = !atLast
            pane.chrome.isPreviousEnabled = !atFirst
        }
    }

    func redisplay(pane mode: ReadingMode, restore position: RestorePositionType) {
        let pane = mode == .bible ? bible : commentary
        pane.refToShow = nil
        pane.pendingRestore = nil
        displayChapter(
            PSModuleController.getCurrentBibleRef(),
            polling: mode == .bible ? .bible : .commentary,
            restore: position
        )
    }

    /// Switches which pane is showing for an inbound `sword://` route, dropping
    /// whatever that pane had deferred first.
    ///
    /// **`mode`'s `didSet` drains the target pane's deferral, and for a routed
    /// switch that deferral is stale by construction** (it is the chapter the user
    /// was already on). Draining it would render the previous chapter and rewrite
    /// `lastRef` back to it, under both `HistoryStore.addEntry` and the
    /// `redisplayPrimary*` observer. The redisplay that follows re-renders the
    /// persisted ref anyway, so nothing is lost.
    ///
    /// `verseToShow` is cleared too: otherwise `applyPendingWork`'s third branch
    /// would scroll the outgoing document and persist a verse from the wrong
    /// chapter.
    ///
    /// The user's own Bible/commentary picker writes `mode` directly and wants the
    /// drain — which is why this clears at the CALL SITE and not in `didSet`.
    func showRoutedMode(_ newMode: ReadingMode) {
        let pane = newMode == .bible ? bible : commentary
        pane.refToShow = nil
        pane.pendingRestore = nil
        pane.setVerseToShow(0)
        mode = newMode
        // A pane that has never rendered (only ever the commentary pane, before its
        // first visit) would otherwise be shown EMPTY until the `.redisplayPrimary*`
        // observer runs a runloop turn later. Rendering the persisted ref here is
        // safe because `ReadingStateStore.persist` has already run: this is the
        // route's own chapter.
        if pane.document.verses.isEmpty {
            pane.render(
                ref: PSModuleController.getCurrentBibleRef(),
                restore: .none
            )
        }
    }

    /// A font or font-size change (`resetBibleAndCommentaryView`, posted by
    /// `SettingsModel.onReadingAppearanceChanged`): re-render the pane the user is
    /// on, and leave the other one's deferral alone.
    ///
    /// Must poll the ACTIVE pane: both panes stay in the hierarchy and `mode`'s
    /// `didSet` is the only drain, so polling neither would leave the change
    /// invisible until the user switched Bible ⇄ commentary.
    private func redisplayWithDefaults() {
        redisplay(pane: mode, restore: .verse)
    }

    /// A bookmark change re-renders the Bible pane at its current SCROLL offset,
    /// not its verse — the user has not navigated, only recoloured. The highlight
    /// is a property of the document, so re-rendering both adds and removes it.
    /// This is the ONLY `bookmarksChanged` re-render.
    private func redisplayAfterBookmarksChange() {
        bible.refToShow = nil
        bible.pendingRestore = nil
        displayChapter(
            PSModuleController.getCurrentBibleRef(),
            polling: .bible,
            restore: .scroll
        )
    }

    // MARK: Chapter paging

    /// Both directions restore NO position, i.e. land at the START of the chapter
    /// they move to. The verse-position defaults hold the verse in the chapter
    /// being LEFT, so restoring one here lands on a wrong verse.
    func nextChapter() {
        page(forward: true)
    }

    func previousChapter() {
        page(forward: false)
    }

    /// A chapter swipe on the reader: the same paging as the chevron buttons,
    /// under the same enablement.
    ///
    /// The chevrons are disabled at Genesis 1 / Revelation 22 and when the
    /// commentary pane has no module, so `page(forward:)` is never reached there.
    /// A swipe has no disabled state, so it is gated on the same flags — otherwise
    /// a swipe that goes nowhere would still clear the search highlight.
    ///
    /// Returns whether the chapter changed. A swipe's haptic is the only
    /// confirmation it gets, so it must not fire for a swipe that went nowhere.
    @discardableResult
    func page(_ swipe: ChapterSwipe) -> Bool {
        let chrome = activePane.chrome
        switch swipe {
        case .next:
            guard chrome.isNextEnabled else { return false }
            return page(forward: true)
        case .previous:
            guard chrome.isPreviousEnabled else { return false }
            return page(forward: false)
        }
    }

    @discardableResult
    private func page(forward: Bool) -> Bool {
        // Paging away from a search result's chapter ends that result's highlight;
        // otherwise it follows the reader through every later chapter.
        activePane.searchHighlightTerms = []
        activePane.setVerseToShow(0)
        let current = PSModuleController.getCurrentBibleRef()
        let boundary = forward
            ? PSModuleController.getLastRefAvailable()
            : PSModuleController.getFirstRefAvailable()
        guard current != boundary else { return false }

        guard let controller = PSModuleController.default(),
              let ref = forward
                ? controller.setToNextChapter()
                : controller.setToPreviousChapter() else {
            return false
        }

        // Only the pane on screen turns a page. The other one is handed the same
        // chapter start, but drains it when it next appears, without the slide.
        activePane.notePageTurn(forward: forward)
        displayChapter(
            ref,
            polling: mode == .bible ? .bible : .commentary,
            restore: .none
        )
        session?.library.recordHistory(mode: mode)
        return true
    }

    // MARK: Reference selection

    /// Applies a book/chapter/verse selection from the reference picker.
    ///
    /// The same-chapter fast path is preserved: selecting a verse in the chapter
    /// already on screen scrolls both panes rather than re-rendering, which is
    /// the difference between an instant jump and a visible reload.
    func selectReference(bookName: String, chapter: Int, verse: Int) {
        let ref = "\(bookName) \(chapter)"
        let verseString = "\(verse)"
        let controller = PSModuleController.default()

        if PSModuleController.getCurrentBibleRef() == ref {
            bible.scrollToVerse(verse)
            commentary.scrollToVerse(verse)
            if controller?.primaryBibleName != nil {
                bible.setTitle("\(ref):\(verseString)")
            }
            if controller?.primaryCommentaryName != nil {
                commentary.setTitle("\(ref):\(verseString)")
            }
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(verseString, forKey: Defaults.bibleVersePosition)
        defaults.set(verseString, forKey: Defaults.commentaryVersePosition)
        displayChapter(
            ref,
            polling: mode == .bible ? .bible : .commentary,
            restore: .verse
        )
        session?.library.recordHistory(mode: mode)
    }

    /// Opens a reference chosen in the Library or Search workspace. Routed
    /// through the same `sword://` path the URL router uses, so a bookmark, a
    /// history row and an external link all take one code path.
    func openLibraryReference(_ reference: String, module: String?) {
        var components = URLComponents()
        components.scheme = "sword"
        components.host = module
        components.path = "/\(reference)"
        guard let url = components.url else { return }
        session?.open(url)
    }

    // MARK: Study surfaces

    func showStudyPopup(_ content: PSInfoPopupContent) {
        studyPopup = StudyPopup(content: content)
    }

    func presentVerseMenu(verse: Int) {
        let chapterRef = PSModuleController.createRefString(
            PSModuleController.getCurrentBibleRef()
        ) ?? ""
        verseMenuTarget = VerseMenuTarget(verse: verse, chapterRef: chapterRef)
    }

    func addBookmark(for target: VerseMenuTarget) {
        bookmarkDraft = BookmarkDraft(
            chapterRef: target.chapterRef,
            verse: "\(target.verse)"
        )
    }

    /// The verse menu's "show in commentary" action: carry the verse across and
    /// switch panes.
    ///
    /// **The verse is carried in `pendingRestore`, not only in `verseToShow`.** The
    /// commentary pane's `refToShow` is always set here (every Bible-polled
    /// `displayChapter` defers into it), and a pending ref outranks a pending
    /// verse in `applyPendingWork`, so `verseToShow` alone would be silently
    /// dropped. Branch 1 re-renders the same chapter and applies `.verse(verse)`;
    /// branch 2 (nothing deferred) scrolls without re-rendering.
    ///
    /// `setVerseToShow` is NOT also called: the line below arms branch 2, which
    /// outranks branch 3, so it would be dead.
    func showInCommentary(verse: Int) {
        commentary.pendingRestore = .verse(verse)
        mode = .commentary
        session?.selectedWorkspace = .read
    }

    /// "Find all occurrences" from a Strong's popup: dismiss the popup, seed the
    /// Search workspace with a Strong's query, and switch to it. There is no
    /// second sheet presentation, which avoids the iOS 27 floating-tab-bar
    /// AnimationKit assertion a sheet-over-sheet transition triggers.
    func startStrongsSearch(_ term: String) {
        guard !term.isEmpty else { return }

        studyPopup = nil
        savedSearchResultsMode = mode
        // Drive the search model DIRECTLY. `SearchView.configure(...)` runs once
        // per launch (guarded by `@State configured`), so a seeded item would only
        // work for the first Strong's search and show stale results after.
        //
        // `savedSearchHistoryItem` is deliberately NOT set: it is the reader's
        // memory of the last search, written when the user leaves the search
        // workspace; pre-loading an unrun query would restore a resultless item.
        session?.search.startStrongsQuery(
            term,
            currentBookName: currentSearchBookName
        )
        session?.selectedWorkspace = .search
    }

    /// Highlights every occurrence of the search terms in the pane that produced
    /// the results. The terms are pane state applied while rendering, so they
    /// cannot drift from the content; clear by assigning an empty list.
    ///
    /// Takes the term LIST from `SearchModel.highlightTerms`, which splits an
    /// all/any-words query into words, honours quoted phrases, drops
    /// one-character noise, and returns **empty** for a Strong's search (the
    /// matched text is a lemma, not text present in the verse).
    func highlightSearchTerms(_ terms: [String], mode: ReadingMode) {
        let pane = mode == .bible ? bible : commentary
        pane.searchHighlightTerms = terms.filter { !$0.isEmpty }
    }

    // MARK: Search hand-off

    /// The module choices the search workspace offers — the two readable modules,
    /// in pane order.
    var searchModuleChoices: [SearchModuleChoice] {
        let controller = PSModuleController.default()
        var choices: [SearchModuleChoice] = []
        if let bibleName = controller?.primaryBibleName {
            choices.append(SearchModuleChoice(id: bibleName, kind: .bible))
        }
        if let commentaryName = controller?.primaryCommentaryName {
            choices.append(
                SearchModuleChoice(id: commentaryName, kind: .commentary)
            )
        }
        return choices
    }

    /// The module search should preselect: whichever pane the reader is on.
    var preferredSearchModule: String? {
        mode == .bible
            ? PSModuleController.default()?.primaryBibleName
            : PSModuleController.default()?.primaryCommentaryName
    }

    /// The book name for the "current book" search scope, taken off `lastRef` by
    /// dropping the trailing chapter number.
    var currentSearchBookName: String? {
        guard let reference = PSModuleController.getCurrentBibleRef(),
              let lastSpace = reference.range(of: " ", options: .backwards) else {
            return nil
        }
        return String(reference[..<lastSpace.lowerBound])
    }

    /// The search-history item to restore when the search workspace opens.
    ///
    /// An item whose results belong to the pane now on screen is restored WITH its
    /// results; an item from the other pane is restored as a query only (and
    /// consumed, so it does not come back a third time).
    func searchHistoryItemToRestore() -> PSSearchHistoryItem? {
        if savedSearchResultsMode == mode,
           let item = savedSearchHistoryItem,
           item.results != nil {
            return item
        }
        if let item = savedSearchHistoryItem,
           item.searchTerm != nil
            || (item.searchTermToDisplay?.count ?? 0) > 0 {
            savedSearchHistoryItem = nil
            return item
        }
        return nil
    }

    // MARK: Size changes

    func prepareForSizeChange() {
        bible.prepareForSizeChange()
        commentary.prepareForSizeChange()
    }

    func restoreAfterSizeChange() {
        bible.restoreAfterSizeChange()
        commentary.restoreAfterSizeChange()
    }
}
