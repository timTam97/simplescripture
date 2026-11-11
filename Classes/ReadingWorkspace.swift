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
//    A deferral only ever waits on a HIDDEN pane: `mode`'s `didSet` drains a pane
//    as it appears, `displayChapter` drains the pane on screen at once when that
//    is not the one it polled, and a pane that renders drops its own.
//  * **Chapter paging restores no position in either direction** — do not
//    "restore" a verse position on `previousChapter`. It also starts the new
//    chapter on a NEW scroll view (`ReaderPaneModel.scrollSurface`) rather than
//    scrolling the old one to the top, which did not land reliably. The swap is
//    also what the page-turn slide animates (`ReaderPaneModel.pageTurn`), so the
//    scroll view being left stays on screen for the length of the slide — which
//    is why every scroll callback names the surface it came from. The pane a page
//    turn is DEFERRED into has its position keys reset when the turn is deferred,
//    not when it drains, and keeps the turn through any redisplay in between
//    (`ReaderPaneModel.deferRender`): until it has shown the new chapter its keys
//    describe the old one, and a relaunch or a redisplay restores from them.
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
    /// position to restore. Set by `displayChapter` for the pane it did NOT poll,
    /// through `deferRender(of:restore:)`; `selectReference` re-aims the restore
    /// of a chapter already owed the same way.
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
    /// Three things read it, and each is load-bearing: `scrollOffsetChanged` (do not
    /// persist a position from before the restore lands), `restoreAfterSizeChange`
    /// (do not re-anchor on a verse while an offset restore is still in flight) and
    /// `topmostVerseChanged` (the row at the top before it lands has not measured
    /// where it lands — see `shownVerseIsMeasured`).
    @ObservationIgnored private var outstandingOffsetRestore: CGFloat?
    /// The verse the position keys pair with an offset restore, used for what
    /// `scrollOffsetChanged` persists until the view reports the topmost verse
    /// itself.
    ///
    /// An offset names no verse, and `currentShownVerse` is whatever the pane
    /// last knew — 1 on a pane that has shown nothing, which is every launch. The
    /// first scroll persisted after the restore landed (the rows settling a few
    /// points is enough) wrote that 1 over the saved verse and retitled to `…:1`
    /// with the reader correctly mid-chapter, until a DIFFERENT row reached the
    /// top. A display toggle or a font change in that window jumped to verse 1.
    ///
    /// **Kept apart from `currentShownVerse`, not written into it.** The row at
    /// the top BEFORE the scroll lands reports verse 1, and `topmostVerseChanged`
    /// drops it only because that is what the pane already believes. Seeded with
    /// the saved verse, it would take that report for a move and persist verse 1.
    ///
    /// Ended by any persist, by any newer restore, and by the view's first report
    /// that counts as a measurement (`topmostVerseChanged`) — whether that report
    /// changes the verse or confirms it.
    @ObservationIgnored private var offsetRestoreVerse: Int?
    /// Whether `currentShownVerse` says where the scroll view IS: the view
    /// reported it as the row at the top, or a restore that names a verse (or the
    /// top of the chapter) sent the scroll view there.
    ///
    /// False after an offset restore that MOVES the scroll view, which names no
    /// verse: `currentShownVerse` is then whatever the pane believed before it —
    /// 1 on a pane that has shown nothing, which is every launch — until the
    /// view reports. An offset the scroll view is already at keeps it (a
    /// bookmark change — see `apply`).
    /// `restoreAfterSizeChange` reads it. A width change re-anchors on a measured
    /// verse; on a leftover one it would drag a reader restored mid-chapter back
    /// to verse 1.
    ///
    /// **A different question from `offsetRestoreVerse`.** That is the verse the
    /// KEYS hold, carried so that a scroll does not save a leftover over it. It
    /// says what to persist, not where the scroll view is — nothing has checked
    /// it against the rows — so the scroll that writes it into
    /// `currentShownVerse` (`scrollOffsetChanged`) leaves this false.
    @ObservationIgnored private var shownVerseIsMeasured = true

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
        // It belongs to the offset restore that set it. Any newer instruction
        // ends it, another offset included, which sets its own below.
        offsetRestoreVerse = nil
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
            shownVerseIsMeasured = true
            verseToShow = 0
            let target = rowID(containing: verse)
            // The chapter's first row is the one landing nothing may report. It
            // rests at offset 0, which `lastScrollOffset` was just reset to, so
            // `scrollOffsetChanged` sees no move — and when the verse asked for is
            // the one at its top, `topmostVerseChanged` sees no change either. The
            // keys then kept the position the reader had just LEFT, and a display
            // toggle, a bookmark or a relaunch went back there. So it is persisted
            // here, as `.chapterStart` persists its own. (`document.verses.first`
            // is the first row in either layout: that row with a row per verse,
            // the first paragraph's id in prose. With Headings on it is the title
            // row, which is where verse 1 lands — see `rowID(containing:)`. With a
            // row per verse that row reports itself as verse 0, which is verse 1
            // to this pane; alone in a paragraph it reports nothing.)
            //
            // Only the first row. Any row below it lands past the threshold and is
            // persisted when it does; writing offset 0 for one of those would be
            // wrong until then, and for good if the re-render never moves the view.
            if target == document.verses.first?.number {
                persistPosition(verse: verse, scrollOffset: 0)
            }
            Task { @MainActor [weak self] in
                self?.scrollPosition.scrollTo(id: target, anchor: .top)
            }
        case .offset(let offset):
            guard offset > 0 else {
                outstandingOffsetRestore = nil
                return
            }
            // A redisplay IN PLACE: the offset the scroll view is already at, under
            // a verse the view measured there. A bookmark change is the producer.
            // It redraws the chapter at the pane's own saved offset, and that key
            // is `"%d"` of `lastScrollOffset`, so the two agree to within a point.
            //
            // Nothing moves, so there is nothing to land and no verse to forget:
            // the row at the top stays the row at the top, and a row reports only
            // when it BECOMES the topmost one. Taken for a restore, the pane gave
            // up a verse nothing would measure again until the reader scrolled a
            // row past it, and armed a landing a scroll view that does not move
            // never publishes. A rotation in between replayed the old width's
            // offset: add a bookmark at Genesis 1:20, turn the phone, and the
            // reader was pinned past the end of the chapter.
            //
            // Asked of what the pane itself knows, and nothing else. Wherever it
            // cannot vouch for both — a launch, a verse scroll whose landing has
            // not been reported, a rotation's — the offset is the restore it
            // always was.
            let redisplaysInPlace = shownVerseIsMeasured
                && abs(lastScrollOffset - offset) <= Self.scrollThreshold
            lastScrollOffset = offset
            if !redisplaysInPlace {
                // An offset names no verse — see `shownVerseIsMeasured`.
                shownVerseIsMeasured = false
                // Recorded BEFORE the hop: the scroll view publishes geometry (and
                // `scrollOffsetChanged` would persist it) before the hop runs.
                outstandingOffsetRestore = offset
                // The verse this offset was saved with — see `offsetRestoreVerse`.
                // The clamp is `persistPosition`'s.
                offsetRestoreVerse = UserDefaults.standard
                    .string(forKey: versePositionKey)
                    .map { max(1, ($0 as NSString).integerValue) }
            }
            // Issued either way. In place it asks for where the view already is.
            Task { @MainActor [weak self] in
                self?.scrollPosition.scrollTo(y: offset)
            }
        case .none:
            // A chapter change lands at the top, which is what
            // `RestoreNoPosition` meant.
            outstandingOffsetRestore = nil
            lastScrollOffset = 0
            currentShownVerse = 1
            shownVerseIsMeasured = true
            Task { @MainActor [weak self] in
                self?.scrollPosition.scrollTo(edge: .top)
            }
        case .chapterStart:
            // A new scroll view (see `scrollSurface`), and a new position to go with
            // it: the old one names a row of the chapter being left, and the chapter
            // arriving has a row with the same id.
            outstandingOffsetRestore = nil
            lastScrollOffset = 0
            // A verse scroll armed before the page turn is spent by it. A `.verse`
            // load arms one on both panes, and a deferred pane that keeps its page
            // turn through that load (`deferRender`) drains here rather than through
            // `.verse`, which is what would have cleared it. Left armed, it scrolls
            // the pane to that verse the next time it appears with nothing owed.
            verseToShow = 0
            scrollPosition = ScrollPosition(idType: Int.self)
            scrollSurface += 1
            // Persisted HERE because nothing else will. A scroll view that starts at
            // the top publishes no offset change and no new topmost verse, so the keys
            // would keep the position in the chapter being left — and `setToPreviousChapter`
            // has just written the destination's LAST verse into the verse key. A
            // relaunch (`.scroll`) or a display toggle (`.verse`) would land there.
            // (A DEFERRED page turn has had the same two keys written already, by
            // `deferRender`; this also retitles.)
            persistPosition(verse: 1, scrollOffset: 0)
            shownVerseIsMeasured = true
        }
    }

    /// Hands this pane `ref` to render the next time it appears, restoring
    /// `restore` — unless what the pane already owes says more about where it
    /// should open than `restore` does.
    ///
    /// **`restore` is built from this pane's position keys, and those describe
    /// the chapter the pane last SHOWED.** A pane that owes a render is about to
    /// show a different one, so:
    ///
    ///  * **A page turn settles the keys here, at defer time.** The pane itself
    ///    writes verse 1 / offset 0 only when it drains (`apply(.chapterStart)`).
    ///    Until then a relaunch restores the old chapter's offset in the new one,
    ///    and every other load rebuilds this deferral from the old chapter's verse
    ///    — paging BACK guarantees a wrong one, because `setToPreviousChapter`
    ///    writes the destination's last verse into the commentary's key.
    ///  * **An owed page turn outlasts a redisplay.** With the keys settled, a
    ///    display toggle or a font change arrives as `.verse(1)` and a bookmark
    ///    change as `.offset(0)`. Neither is a chapter start: `.offset(0)` does not
    ///    scroll at all, so the pane would show the new chapter wherever its
    ///    scroll view was left in the old one.
    ///  * **A verse past the first wins**, over an owed page turn too. That is
    ///    somebody naming a verse: the reference picker, or a `sword://` route —
    ///    which writes the BIBLE's verse key for a commentary destination as
    ///    well. Draining `.chapterStart` instead would persist verse 1 over it.
    ///  * **An offset, or no saved position at all, never replaces an owed verse
    ///    or chapter start.** A bookmark added after picking John 3:16 would
    ///    otherwise open the commentary's John 3 at the offset it was left at in
    ///    whatever chapter it last showed.
    func deferRender(of ref: String?, restore: PaneRestore) {
        // Only a restore owed WITH a render counts. One on its own is
        // `showInCommentary`'s, and is consumed by the switch that follows it.
        let owed = refToShow == nil ? nil : pendingRestore
        refToShow = ref
        switch restore {
        case .chapterStart:
            pendingRestore = .chapterStart
            // The bytes `persistPosition(verse: 1, scrollOffset: 0)` writes, without
            // the rest of it: `currentShownVerse` still belongs to the scroll view
            // this pane is holding, and `displayChapter` titles both panes itself.
            let defaults = UserDefaults.standard
            defaults.set("0", forKey: scrollPositionKey)
            defaults.set("1", forKey: versePositionKey)
        case .verse(let verse) where verse > 1:
            pendingRestore = restore
        case .verse:
            pendingRestore = owed == .chapterStart ? .chapterStart : restore
        case .offset, .none:
            if case .offset? = owed {
                pendingRestore = restore
            } else {
                pendingRestore = owed ?? restore
            }
        }
    }

    /// Applies deferred work: when the pane becomes active, and straight away if
    /// it is handed some while it already is (see `displayChapter`).
    ///
    /// The order is load-bearing: a pending ref wins over a pending restore, which
    /// wins over a pending verse scroll. Collapsing these into "do whatever is set"
    /// would re-render a chapter that was only meant to scroll.
    ///
    /// **The first two branches disarm the third.** A `.verse` load arms
    /// `verseToShow` on both panes, and anything this pane is owed was handed to
    /// it by that load or by a later one, so draining it supersedes the armed
    /// verse. `.verse` and `.chapterStart` spend it themselves; an offset does
    /// not, and one drained over it left it armed for the pane's NEXT appearance
    /// with nothing owed — a Bible ⇄ commentary round trip, nothing navigated —
    /// which scrolled to a verse from an earlier chapter and persisted it over
    /// the reader's place.
    func applyPendingWork() {
        if let ref = refToShow {
            verseToShow = 0
            render(ref: ref, restore: pendingRestore ?? .none)
            refToShow = nil
            pendingRestore = nil
        } else if let restore = pendingRestore {
            verseToShow = 0
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
    ///
    /// **Verse 1 starts at the chapter's title when the title is the row above
    /// it.** With Headings on a KJV chapter opens with a row that is only its
    /// title (`CHAPTER 1.`, row 0 — see `ChapterVerse.hasVisibleText`), and verse
    /// 1's own row is the next one. Sent there, the reader rested with the title
    /// above the reading area, behind the navigation bar. MEASURED (iOS 27.2,
    /// 20 pt, a row per verse): "CHAPTER 1." at y 87–110 under a bar whose bottom
    /// edge is at 116 — after the reference picker, after turning Headings on at
    /// the top of the chapter, and at launch, where the size hook re-issues the
    /// row of the verse the pane believes. Only a page turn showed it. Flowing,
    /// the title heads verse 1's paragraph and that row was already the answer,
    /// except in the 117 psalms whose own title starts a paragraph at verse 1 and
    /// leaves `PSALM n.` a row by itself.
    ///
    /// Only a row with no text of its own, which is a title and nothing else. A
    /// commentary's row 0 is the chapter summary, a record in its own right, and
    /// verse 1 keeps the record under it: "Show in Commentary" on verse 1 opens
    /// on that one. And only verse 1 — the title is not part of any other verse.
    private func rowID(containing verse: Int) -> Int {
        if verse == 1, let first = document.verses.first,
           first.isIntro, !first.hasVisibleText {
            // The first row in either layout: its own row with a row per verse,
            // and the first paragraph's id in prose.
            return first.number
        }
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
        // After an offset restore the pane does not know its verse until the view
        // says — see `offsetRestoreVerse` — and the saved one is the better answer.
        persistPosition(
            verse: offsetRestoreVerse ?? currentShownVerse,
            scrollOffset: normalized
        )
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
        guard !isRestoringAfterTransition else { return }
        // The view has said which row is at the top, so `currentShownVerse` is a
        // measurement from here on, whether or not this report changes it.
        //
        // One report is not: the one the row at the top makes BEFORE an offset
        // restore lands, which says where the view was. It is told apart the way
        // `offsetRestoreVerse` already relies on — it is the verse the pane
        // believes anyway (1, on a new pane) — so while a restore is in flight a
        // report counts only if it changes that. The row the restore lands on may
        // report before the landing itself is published, and it does change it.
        if outstandingOffsetRestore == nil || clamped != currentShownVerse {
            shownVerseIsMeasured = true
            // A measurement also ends the verse carried from the keys — see
            // `offsetRestoreVerse`. A report that changes the verse ends it through
            // the persist below. One that CONFIRMS what the pane believes persists
            // nothing, and left the saved verse armed for the next scroll to write
            // over the one the view had just reported.
            offsetRestoreVerse = nil
        }
        guard clamped != currentShownVerse else { return }
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
        // Any persist settles it: the pane now holds a verse of its own, whether
        // the view reported it or the saved one was just written back.
        offsetRestoreVerse = nil
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

    /// Rotation, or an iPad split-view resize — or the reader's height alone
    /// changing, as the bars settle at launch and when a keyboard goes.
    ///
    /// Scroll identity is width-independent, so nothing needs re-measuring. All
    /// that is needed here is suppressing the transient scroll callbacks the
    /// transition produces, which would otherwise overwrite the persisted
    /// position. A scroll OFFSET is not width-independent, and what is restored
    /// afterwards turns on that — see `restoreAfterSizeChange(widthChanged:)`.
    func prepareForSizeChange() {
        sizeChangeGeneration += 1
        isRestoringAfterTransition = true
    }

    /// **The suppression has to outlive this call.** `ReaderScreen` calls
    /// `prepareForSizeChange()` and `restoreAfterSizeChange(widthChanged:)` back
    /// to back in one `onGeometryChange` action, so clearing the flag synchronously
    /// would let every transient rotation callback overwrite the saved position.
    ///
    /// **A height change replays the scroll offset; a width change re-anchors on
    /// the verse.** The hook fires for both. Height alone re-wraps nothing, so the
    /// offset still names the same text and is preserved exactly. A width change
    /// re-wraps every row, and the old width's offset names different text:
    /// Genesis 1 with a row per verse is 4198 pt tall in portrait and about half
    /// that in landscape, so the offset of verse 20 is past the end of the
    /// landscape chapter. Replayed, it pinned the reader there, that was persisted
    /// as the position, and rotating back replayed IT into the portrait layout.
    ///
    /// The flowing layout keeps the offset on a width change too. A prose
    /// paragraph is one flowing `Text`, not one scroll target per verse, so
    /// re-anchoring to `rowID(containing:)` would jump to the paragraph's first
    /// verse; the per-verse layout tracker updates the title independently.
    func restoreAfterSizeChange(widthChanged: Bool) {
        let generation = sizeChangeGeneration
        // Re-anchor on the verse only where it is a better answer than the pixels:
        //
        //  * the rows are per verse (per record, on a commentary) and not
        //    paragraphs — see above;
        //  * the verse is one the view measured or a restore named. After an
        //    offset restore it is a leftover — see `shownVerseIsMeasured`;
        //  * no offset restore is in flight (below);
        //  * the pane owes no render. One that does is holding a chapter the
        //    reader has left, under position keys that already describe the one it
        //    will open on (`deferRender`). Re-anchoring moves its scroll view, and
        //    the landing would be persisted over them. The offset replayed instead
        //    lands on `lastScrollOffset`, which `scrollOffsetChanged` does not
        //    take for a move — unless the new width cannot reach it.
        let reanchorsOnVerse = widthChanged && versePerLine && shownVerseIsMeasured
            && outstandingOffsetRestore == nil && refToShow == nil
        if reanchorsOnVerse {
            // As in `apply(.verse)`: the old width's offset is not evidence for
            // this position, and neither is a verse saved with it. Zeroed rather
            // than skipped over, because a rotation's size arrives in steps, as
            // the launch's does — the bars settle after the width has changed —
            // and with everything published in between suppressed, the
            // height-only step that follows would replay it.
            lastScrollOffset = 0
            offsetRestoreVerse = nil
        }
        // An OFFSET restore still in flight wins over `currentShownVerse`.
        //
        // The reader's size settles in steps at launch ((402, 0) → (402, 623) →
        // (402, 675) as the nav bar and tab bar come in), so this hook fires during
        // launch, after an `.offset` restore is requested but before it lands.
        // Re-anchoring on `currentShownVerse` (still 1 — an offset restore names no
        // verse, and the one its keys pair with it is held apart, in
        // `offsetRestoreVerse`) would drag the reader back to the top. `.verse`
        // restores are unaffected because they set `currentShownVerse` first.
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
    /// and the `sword://` router), `bookmarksChanged`,
    /// `newPrimary{Bible,Commentary}` (module load, including `render`'s nil-primary
    /// recovery), and `appStateDidReset` (the Settings-app reset).
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
        // A reset leaves the chapter by the one path that is not a navigation. It
        // removes `lastRef`, and the `redisplayPrimaryBible` it posts next renders
        // Genesis 1 through `redisplay` — which is otherwise the SAME chapter
        // drawn again, and so carries the search highlight across.
        observe(.appStateDidReset) { [weak self] in
            self?.clearSearchHighlight()
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
    ///  1. **Only the polled pane renders, unless the other one is on screen.** A
    ///     hidden pane is handed `refToShow` + `pendingRestore` and renders when it
    ///     next becomes active, which stops every Bible chapter change from also
    ///     rendering MHCC. An inbound `sword://` route must DISCARD that deferral
    ///     rather than drain it — see `showRoutedMode(_:)`.
    ///  2. **Each pane's restore is built from its own verse-position pref**; they
    ///     track position independently. The deferred pane's may be overruled by
    ///     what it already owes — `ReaderPaneModel.deferRender(of:restore:)`.
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
            // chapter on a new scroll surface, the deferred one when it is drained
            // (its position keys are reset now, not then — see `deferRender`).
            bibleRestore = .chapterStart
            commentaryRestore = .chapterStart
        }

        // The pane that renders drops whatever it had deferred. This render is the
        // newer instruction, and a deferral left behind it is replayed over it the
        // next time the pane appears: the reader pages on, switches away and back,
        // and is returned — `lastRef` included — to the chapter they had left.
        let polledPane: ReaderPaneModel?
        switch polling {
        case .bible:
            polledPane = bible
            bible.refToShow = nil
            bible.pendingRestore = nil
            bible.render(ref: ref, restore: bibleRestore)
            commentary.deferRender(of: ref, restore: commentaryRestore)
        case .commentary:
            polledPane = commentary
            commentary.refToShow = nil
            commentary.pendingRestore = nil
            commentary.render(ref: ref, restore: commentaryRestore)
            bible.deferRender(of: ref, restore: bibleRestore)
        case .none:
            polledPane = nil
            bible.deferRender(of: ref, restore: bibleRestore)
            commentary.deferRender(of: ref, restore: commentaryRestore)
        }

        // `mode`'s `didSet` drains a pane when it APPEARS; this drains one that is
        // already showing. Nothing else would: a deferral handed to the pane on
        // screen waits for the reader to switch away and back, with the old chapter
        // on screen under the new one's title until they do. Most callers poll the
        // pane on screen and never get here. A bookmark change and a reset poll the
        // Bible whichever pane is showing.
        if activePane !== polledPane {
            activePane.applyPendingWork()
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
    ///
    /// **An inbound route also ends the search highlight**, in both panes. This
    /// is the one place a bookmark, a history row and every `sword://` link pass
    /// through on their way out of the chapter a search result was opened in. It
    /// ends even when the route is to the chapter already showing: `lastRef` has
    /// been rewritten by the time this runs, so there is nothing left to compare
    /// against. A search result arrives by this route too, which is why its own
    /// terms go on AFTER the open — see `openSearchResult`.
    func showRoutedMode(_ newMode: ReadingMode) {
        clearSearchHighlight()
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
    /// Polls the ACTIVE pane so that it is the only one rendered. Polling the
    /// other would still reach this one — `displayChapter` drains a deferral
    /// handed to the pane on screen — but would render the hidden pane as well,
    /// for a change the reader cannot see there yet.
    private func redisplayWithDefaults() {
        redisplay(pane: mode, restore: .verse)
    }

    /// A bookmark change re-renders the Bible pane at its current SCROLL offset,
    /// not its verse — the user has not navigated, only recoloured. The highlight
    /// is a property of the document, so re-rendering both adds and removes it.
    /// This is the ONLY `bookmarksChanged` re-render.
    ///
    /// It polls the Bible even when the commentary is showing (a bookmark edited
    /// in the Library). `displayChapter` then re-renders the commentary as well,
    /// at its own offset, rather than leaving it a deferral it would not drain.
    ///
    /// **Unless the Bible owes a render.** It is hidden then, and it reads the
    /// bookmarks when it drains. Polling it here would spend the chapter start or
    /// the verse it owes on its offset key, which is where it was last LEFT —
    /// after a page turn that is 0, which does not scroll, so the Bible would
    /// show the new chapter wherever its scroll view sat in the old one. The pane
    /// on screen is polled instead, and `deferRender` keeps what the Bible owes.
    ///
    /// Not `private` so that a test can call it: posting `bookmarksChanged` on the
    /// shared centre would reach the host app's own workspace as well.
    func redisplayAfterBookmarksChange() {
        redisplay(pane: bible.refToShow == nil ? .bible : mode, restore: .scroll)
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
        // otherwise it follows the reader through every later chapter. In both
        // panes: the one that is not showing follows to the new chapter through
        // its deferral, and drew it with its own terms when it was next shown.
        clearSearchHighlight()
        // No position is restored on EITHER pane, so a verse scroll armed before
        // the page turn is spent on both. The pane that is not on screen spends
        // its own when it drains the chapter start it is handed below — but a
        // load that polls it first renders it where it stands, and at an offset
        // the armed verse survived to fire when the pane was next shown.
        bible.setVerseToShow(0)
        commentary.setVerseToShow(0)
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
    ///
    /// **Only a pane that has rendered the chapter is scrolled.** One that still
    /// owes it (`refToShow` — the commentary after any Bible navigation, and
    /// always straight after launch) is holding the chapter it last showed, or
    /// nothing. Scrolling that moved a document about to be replaced, and a
    /// pending ref outranks everything when the pane drains, so it then opened
    /// this chapter wherever its old deferral said, under a title naming the
    /// verse picked. Its deferral is re-aimed at the verse instead, through
    /// `deferRender`, so a page turn it still owes is kept for verse 1.
    ///
    /// Both paths write both verse keys. On the fast path nothing else would
    /// until a scroll moved the view, and every later `.verse` load reads them.
    func selectReference(bookName: String, chapter: Int, verse: Int) {
        let ref = "\(bookName) \(chapter)"
        let verseString = "\(verse)"
        let controller = PSModuleController.default()
        let defaults = UserDefaults.standard
        defaults.set(verseString, forKey: Defaults.bibleVersePosition)
        defaults.set(verseString, forKey: Defaults.commentaryVersePosition)

        if PSModuleController.getCurrentBibleRef() == ref {
            for pane in [bible, commentary] {
                if let owed = pane.refToShow {
                    pane.deferRender(of: owed, restore: .verse(verse))
                } else {
                    pane.scrollToVerse(verse)
                }
            }
            if controller?.primaryBibleName != nil {
                bible.setTitle("\(ref):\(verseString)")
            }
            if controller?.primaryCommentaryName != nil {
                commentary.setTitle("\(ref):\(verseString)")
            }
            return
        }

        // Another chapter, so a search result's highlight ends here. The path
        // above is a scroll within the result's own chapter, and keeps it.
        clearSearchHighlight()
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
    ///
    /// **Not the way to open a result** — that is `openSearchResult`, which owns
    /// the order. A routed open ends the highlight in both panes, so terms set
    /// before one are wiped by it.
    func highlightSearchTerms(_ terms: [String], mode: ReadingMode) {
        let pane = mode == .bible ? bible : commentary
        pane.searchHighlightTerms = terms.filter { !$0.isEmpty }
    }

    /// Ends the search highlight in both panes.
    ///
    /// A result's highlight belongs to the chapter it was opened in, and every way
    /// of leaving that chapter ends it: a page turn, the reference picker, an
    /// inbound route (a bookmark, a history row, a `sword://` link, the next
    /// search result) and a reset. Drawing the SAME chapter again — a font change,
    /// a display toggle, a bookmark edit, the Bible/commentary picker — keeps it:
    /// `render` carries the terms across.
    ///
    /// BOTH panes, because the pane that is not showing follows to the new chapter
    /// through its deferral, and would draw it with its own terms when next shown.
    func clearSearchHighlight() {
        bible.searchHighlightTerms = []
        commentary.searchHighlightTerms = []
    }

    // MARK: Search hand-off

    /// Opens a search result and highlights its terms in the pane that produced
    /// it.
    ///
    /// **The terms go on AFTER the open, and that order is the whole method.** The
    /// open is a route like any other, so it ends whatever highlight was showing
    /// (`showRoutedMode`); assigning the terms then re-highlights the chapter it
    /// rendered. The other way round, the open wipes the terms it was handed and
    /// the result opens unhighlighted — with nothing failing, which is how the
    /// highlighter went without a caller for as long as it did. Pinned by
    /// `testASearchResultsTermsGoOnAfterTheOpenThatEndsThePreviousHighlight`.
    ///
    /// A reference the router rejects opens nothing, and its terms still land on
    /// the chapter showing, as they always have.
    func openSearchResult(
        _ reference: String,
        module: String,
        terms: [String],
        mode: ReadingMode
    ) {
        openLibraryReference(reference, module: module)
        highlightSearchTerms(terms, mode: mode)
    }

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

    func restoreAfterSizeChange(widthChanged: Bool) {
        bible.restoreAfterSizeChange(widthChanged: widthChanged)
        commentary.restoreAfterSizeChange(widthChanged: widthChanged)
    }
}
