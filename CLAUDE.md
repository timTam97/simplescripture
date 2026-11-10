# CLAUDE.md

Guidance for AI coding agents working in this repository.

## Project

SimpleScripture is a GPL'd iOS Bible-study app, forked from PocketSword at `bitbucket.org/niccarter/pocketsword`. It ships CrossWire SWORD module *content* baked into a bundled SQLite store; there is no SWORD engine, C++ or Objective-C at runtime.

- **Pure Swift.** `Classes/` is Swift files plus one header, `globals.h` (enums + constants, imported by both bridging headers). No vendored code, no CocoaPods/SPM.
- **SwiftUI UI.** `@main SimpleScriptureApp` with a four-workspace `TabView` (Read / Search / Library / Settings). No XIBs; only `LaunchScreen.storyboard`. No WebKit: the reader is a native `ScrollView` + `LazyVStack` over `AttributedString`. UIKit survives only as leaf values plus a `@UIApplicationDelegateAdaptor` for `BGTaskScheduler` registration and the orientation hook.
- Old implementations (SWORD engine, Obj-C++ bridge, `tools/swordbake`, WebView reader) are in git history at `fa09511^`. Do not resurrect them.

## Build / run

- Open `SimpleScripture.xcodeproj` and build the shared `SimpleScripture` scheme. No workspace, no package step.
- CLI: `xcodebuild -project SimpleScripture.xcodeproj -scheme SimpleScripture -configuration Debug -sdk iphonesimulator build`, with `CODE_SIGNING_ALLOWED=NO` if there is no dev team. Prefer Xcode MCP; check `xcode-select -p` and installed destinations before using the CLI. Regular Xcode currently provides the iOS 27 SDK.
- A clean build should show **`CompileC` 0**. Any `CompileC` means non-Swift sources came back into the target — a regression.
- Configurations `Debug` / `Release` / `Distribution` all build `SimpleScripture.app` with bundle ID `org.timsam.SimpleScripture` and team `7SZUJ26BQ2`. Debug/Release use empty `SimpleScripture.entitlements` so Personal Team device signing works; history and bookmarks remain local. Distribution uses `SimpleScripture-Distribution.entitlements` for iCloud key-value storage and requires a team that supports iCloud before signing. The Swift module, project, app target and shared scheme use `SimpleScripture`; the scheme archives with `Distribution`. This is a separate app identity; old PocketSword containers are not migrated. Those three configurations share one local installation.
- A second shared scheme, `SimpleScriptureDev`, builds `Debug-Dev` / `Release-Dev`: the same app as **`org.timsam.SimpleScripture.dev`** ("SimpleScripture Dev"), so it installs beside the App Store build with its own container, and registers `sword-dev://` instead of `sword://` (`SIMPLESCRIPTURE_URL_SCHEME`, substituted into `misc/icon/Info.plist`; `URLRouter` accepts `sword` plus whatever the bundle registers). Check which scheme is active before resolving a container or driving a URL.
- `IPHONEOS_DEPLOYMENT_TARGET = 27.0` on all 3 targets × 5 configs; universal. `SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY = minimal`. No prefix header.
- zlib comes from the SDK's Clang module (`import zlib` in `PSContentStore`); no build setting needed.

## Tests

Two bundles:

- **`SimpleScriptureTests`** (app-hosted, `@testable import SimpleScripture`), sources in `Classes/*Tests.swift`. Expected result: **0 failures, 3 skipped** (152 tests at last count). The 3 skips are env-gated: two `PSREF_EXHAUSTIVE` tests and `PSDOC_EXHAUSTIVE`'s `testNativeDocumentMatchesHTMLForEveryChapter` (all 1,189 chapters × 2 modules × 2 option endpoints, ~30 s — run it when touching either chapter emitter).
- **`SimpleScriptureUITests`** (`Tests/SimpleScriptureUITests.swift`): 19 XCUITests over the four workspaces. Its Target Application is `SimpleScripture`. iPhone-only: `selectWorkspace` matches `app.tabBars`, which an iPad does not have, so every test fails there at "Missing workspace Read".
  - **Three are red on `main` as of 2026-11-10 (iOS 27.2 simulator), whatever the change under test.** `testReadingOverflowMenuOpensTheSearchWorkspace` and `testDisplayTogglesAppearForBibleAndNotCommentary` look for a "History and Search" overflow action that commit `1bdebdad` removed (the commentary's ••• now opens an empty menu); `testSearchResultKeyboardAndCopyInteractions` fails at "Scrolling the search results did not dismiss the keyboard". Expect 16 passed; attribute anything else.
  - **`testFlowingReaderTracksTheVisibleVerseWithinAParagraph` depends on the test before it.** It sets up no chapter of its own: it starts wherever the previous test left the reader, drags a little, and waits for the title's verse to change. In the full suite's order it passes. Run straight after `testChapterPagingReplacesAllVerseRows` (which ends in Genesis 3) — as an `-only-testing` subset does — it fails at that wait, on `b52c2a09` as much as on any later change. Don't attribute that failure to the change under test.
  - `testBookmarkFolderCrudAndReordering`'s long-press reorder is timing-sensitive: it failed once in a full run while a second `xcodebuild` was building alongside, and passed alone. Don't build in parallel with a UI test run.

Rules:

- **Fixtures in `Tests/Fixtures/` were captured from the live SWORD engine, which is gone.** They cannot be regenerated. A red fixture test is a real behaviour change — fix the code, never recapture or "fix" the test. Key fixtures: chapter bodies at both option endpoints, lexicon entries, `versification-KJV-oracle.txt` (the whole versification gate), `search-index-KJV.digest` (all 31,102 FTS rows, hashed), `chapter-loop-counters.tsv` (`entryCount` per chapter). `strongsPad-prefixed-key-bug.txt` is a historical record, not an oracle.
- **`PersistedFormatTests` locks byte-exact persisted formats** (history / bookmark / search-history serialization, the per-module pref-key format), quirks included. A red test there means you will corrupt user data.
- **`PSSearchIndexParityTests`** runs a real index build (tens of seconds) and compares every row against the digest. It stays in the default suite because the failure it guards is silent: search results just go missing.
- **Check the skip count, not just the pass count.** The two lexicon XCUITests (`testStrongsLinkOpensItsLexiconEntry`, `testLexiconCrossLinkNavigatesWithinThePopup`) `XCTSkip` when Strong's markers are off — the state of a freshly erased simulator — and report green having asserted nothing. Turn the pref on by editing the app container plist directly: `plutil -replace strongsPreference_KJV -bool YES <container>/Library/Preferences/org.timsam.SimpleScripture.plist` (`simctl spawn defaults write` does not take). On an already-launched container, also flush the simulator's `cfprefsd` or the app gets the cached value: `xcrun simctl spawn <device> launchctl kill SIGKILL system/com.apple.cfprefsd.xpc.daemon`. Cheap sanity check: seed `fontSizePreference` to 30 and confirm the text visibly changes.
- **Env vars in a test run** need a temporary `<EnvironmentVariables>` block in the shared scheme's `TestAction` **plus** `shouldUseLaunchSchemeArgsEnv = "NO"`. The scheme is checked in — back it up and restore it. `RunAllTests` / `RunSomeTests` have no env parameter.
- From the CLI, `-destination 'platform=iOS Simulator,id=<UUID>'` works where `name=...` may not. `xcodebuild` runs the tests on **clones** of that simulator ("Clone 1 of iPhone 18 Pro") unless you pass `-parallel-testing-enabled NO` — and a clone is a fresh install, so a container you seeded (the Strong's pref above) is not the one under test and the lexicon tests skip.
- **If every XCUITest fails in `setUp` with "Timed out while evaluating UI query", or Xcode says it `Could not attach to pid`, the harness is wedged, not your change.** A crashed Xcode leaves a `testmanagerd` inside the simulator runtime holding the debug slot. `kill -9` the one whose path contains `…SimulatorRuntime…/RuntimeRoot/usr/libexec/testmanagerd` (not the host's `/usr/libexec/testmanagerd`) and reboot the device. Confirm attribution by stashing your change and re-running.

## Driving the app on the simulator (Xcode MCP)

- Session: `DeviceInteractionStartWorkspaceSession` → `DeviceInteractionInstallAndRun` → `DeviceInteractionSynthesize` (repeat) → `DeviceInteractionEndSession`. Use the *Workspace* variant (the plain one cannot install). Always end the session.
- Xcode MCP calls take a `workspaceIdentifier` from `XcodeListWorkspaces` (the project is listed once per open window).
- `interactionCommand` syntax is in the `device-interaction` skill (`~/.claude/skills/device-interaction/`; re-export with `xcrun agent skills export <dir>`). Common: `t <x> <y>` tap, `d <x> <y>` double tap, `t <x1> <y1> f <x2> <y2>` swipe, `w <dur>` wait, `b h` home, `sender keyboard kbd <text>` (must be last; `\u{000A}` is Return). Omit the command to just capture state.
- **Use the hierarchy file for coordinates**, not the screenshot: each element has a `hitPoint`. Every verse is a `StaticText` and every Strong's / morph / footnote / verse-menu target is a `Link` whose identifier is its `pslink://` URL (e.g. `pslink://strongs/Hebrew/0430`).
- The reader `ScrollView` has identifier `reading.chapter-content`. **Both panes carry it** (the inactive one sits at `opacity(0)`), so XCUITests must use `.firstMatch`.
- SwiftUI identifiers must be checked against a real dump: `Tab`'s `accessibilityIdentifier` never reaches the tab-bar button (match tabs by label), and a menu row exposes its label, not its identifier.
- The app restores its last tab and scroll position; capture before assuming where it starts.
- Sheets animate in: `w 2.0` before capturing.
- **To check an animation, record it.** A capture is taken after the UI settles, so it cannot show one. Run `xcrun simctl io <device> recordVideo --codec h264 --force <file>.mov` in the background around the `Synthesize`, stop it with `SIGINT`, and pull the frames with `ffmpeg -i <file>.mov -fps_mode passthrough …`. The recording has a frame only when the screen changes, so read the frame timestamps (`showinfo`) instead of assuming a rate: a gap is the screen standing still.
- Per-run env vars for an **app** run: `InstallAndRun`'s `environmentVariables` / `commandLineArguments` (`$(inherited)` keeps the scheme's own).
- **A default passed as a launch argument (`-lastRef "Genesis 1"`) shadows every write the app makes to that key for the whole run.** Fine for a read-once seed; wrong for anything the run changes — page a chapter under `-lastRef` and the text moves on while the title, the chevron enablement and the next page all still read the argument. Seed the container plist instead (see the Strong's note above).
- `StartWorkspaceSession` / `InstallAndRun` drive the Xcode window's own scheme and run destination. If the owner is working in Xcode (active destination is a physical device), build from the CLI with a private `-derivedDataPath` and drive the simulator with `simctl` plus the plain `StartSession` instead.
- `xcrun simctl terminate` / `launch` / `openurl` work (`openurl` is how to drive `sword://`), but can fight the MCP session: after a `terminate` the next `Synthesize` may report `Crashed` when nothing crashed — check for an `.ips` report before believing it, then `InstallAndRun` to re-attach. Driving `simctl` while a session is attached can take Xcode down. A reinstall assigns a new container UUID; re-resolve with `xcrun simctl get_app_container <device> <bundle-id> data`.
- Harmless console noise: `UIAccessibilityLoaderWebShared` duplicate-class warning, `cannot add handler to 0 from 0`.

## The baked content store

`Resources/PSContent.sqlite` + `Resources/Versification-KJV.json` are the app's content and versification. **The converter that produced them is gone; they cannot be regenerated in this repo.** Both are bundled by path.

- Store is **schemaVersion 2 / tokenGrammar v2**; `PSContentStore` refuses anything else. A mismatch would address the wrong chunk slot and return *plausible but wrong* text.
- The FTS source text (`plain_texts`) is shipped, not derived on device — a second derivation would be an untested reimplementation whose bugs silently drop search results.
- **Exactly five modules, no UI to add/remove/pick:** KJV (Bible), MHCC (commentary), and three fixed-role lexicons — `StrongsRealGreek` (`GreekDef`), `StrongsRealHebrew` (`HebrewDef`), `Robinson` (`GreekParse`). The `BundledModules` enum in `AppConstants.swift` is the source of truth. Nothing is unpacked; `Documents/` is empty on a fresh install.

## Architecture

### Launch

1. `@main SimpleScriptureApp` declares a `WindowGroup` around `RootView` and holds the app delegate via `@UIApplicationDelegateAdaptor`.
2. `SimpleScriptureAppDelegate` does only what UIKit owns: `BGTaskScheduler` registration (**must** complete before `didFinishLaunching` returns), `HistoryStore.startCloudSync()`, `AppSession.start()`, and a scene delegate supplying `supportedInterfaceOrientations(for:)` for the rotation-lock pref.
3. `RootView`'s `.task` runs `LaunchCoordinator.prepare()` off the main actor and moves `LaunchPhase` `.preparing → .ready` (or `.failed`). On `.ready` it calls `ReadingWorkspaceModel.start()` and replays any held `sword://` URL.

**Order in step 3 is load-bearing.** Nothing may touch `PSModuleController`, the store or the reader until `prepare()` returns, because its one-shot migrations (`DefaultsLastRefValidated` in particular) can rewrite `lastRef`. That is why `AppSession` parks an incoming URL in `pendingURL`.

`LaunchCoordinator` runs `resetPreferences`, the insomnia pref, `MMM` temp cleanup, and five one-shot migrations: `DefaultsModuleChoiceRetired`, `DefaultsGlobalFontOnly`, `DefaultsLastRefValidated`, `DefaultsDictKeyCaseFixed`, `DefaultsSwordRetired`.

- `DefaultsSwordRetired` deletes the old engine's `Documents/{mods.d,modules,locales.d,unused}` and `<Caches>/InstallMgr` on upgrade. `PSBookmarks.plist` sits at `Documents/` root, outside those — **never widen the sweep to `Documents/` itself**.
- `resetPreferences()` re-resolves the reading primaries (`reloadLastBible()` / `reloadLastCommentary()`) after `resetModuleSelections()`; the lexicon is left nil deliberately. `AppSession.observeAppStateReset()` reloads the models on `.appStateDidReset`; it must go through `SettingsModel.reload()` (its `isReloading` flag suppresses `didSet` writes that would re-create the deleted keys) and be registered `queue: .main` (the reset runs off the main actor).
- Known, deliberate asymmetries: the reset removes local `bibleHistory` but not the iCloud copy, and the key list is the legacy one, so rotation lock, fullscreen mode, the three `lastSearch*`, scroll positions and verse positions survive a reset.

### Workspaces

`Read` / `Library` / `Settings` / `Search` in `WorkspaceTabs` — declared in that order, which is also the display order (`TabRole.search` shows Search in the trailing slot wherever it is declared).

**SwiftUI modifiers in the wrong place fail silently** — no warning, no crash, no unit-test failure. Drive the simulator and check the hierarchy. Known traps:

- `tabViewBottomAccessory` is one accessory for the whole `TabView`, not per tab.
- There is no usable `.bottomBar` on iOS 27; items land on top of the floating tab bar.
- **The search-role `Tab` must be declared LAST.** Declared anywhere else, the declared order and the display order disagree, and after every selection SwiftUI's re-push of the tab list (`-[UITabBarController setTabs:animated:]`) re-applies the selection through an index from the wrong order. Measured (iOS 27.2) with Search declared second: tapping Settings selected Library and then Settings, Library went via Search, Search via Settings — 18 of 27 tab changes. Each detour appears and disappears the wrong workspace (building it on first use: Search was configured by the first tap on Library) and cuts the bar's selection animation short, so the pill vanishes and re-enters. It is independent of what the tabs contain and of whether the selection lives in `@State` or the `@Observable` session. Nothing warns, and no test can see it from outside; log `UITabBar.setSelectedItem:` to check.
- **The tab bar's selection animation is evaluated in-process, on the main thread** (sampled: `-[UITabBar setSelectedItem:]` → `UIViewFloatAnimatableProperty` → the private `AnimationKit`, ticking from main-thread display-link callbacks). Main-thread work in the half-second after a tab change lands on its frames.
- **Leaving Search dismisses the keyboard first** (`AppSession.selectedWorkspace`'s setter). A keyboard still up when the next workspace appears is part of that workspace's safe area: the reader was laid out at the keyboard's height (390×442) and then at its own (390×660), which `ReaderScreen`'s size hook takes for a rotation and answers by re-anchoring on the reader's *previous* offset — so a search result opened with the keyboard up (type, tap) left the reader where it was, under the result's reference in the title. Pinned by `testOpeningASearchResultWithTheKeyboardUpLandsOnItsVerse` and `testLeavingSearchDismissesTheKeyboardBeforeTheSelectionMoves`. `ignoresSafeArea(.keyboard)` on the reader's `ZStack` or its `NavigationStack` does **not** stop the hook firing (measured). The hook itself is unchanged: `restoreAfterSizeChange` replays `lastScrollOffset` whenever one is recorded, and by then the re-rendered chapter has already republished the old offset into it — so a real size change in that window (a rotation mid-open) takes the same path. Only the keyboard trigger is removed here.
- **The reader asks for its bottom scroll edge effect by name** (`.scrollEdgeEffectStyle(.soft, for: .bottom)` in `ChapterTextView`). On the automatic style a `ScrollView` gets none under the floating tab bar (a `List` does), with or without the reader's `ignoresSafeArea` and with one pane or two — so the chapter showed through the bar's glass at full contrast and the selection lens refracted it.
- **Navigation stays visible.** Fullscreen/Focus mode and automatic fullscreen are removed. The tab bar and reader/Search navigation bars use `.never` minimisation; reader taps and scrolling do not hide controls. Chapter scrolling, verse tracking, study links and Search keyboard dismissal remain in place.
- A `safeAreaInset(edge: .top)` bar does not combine with a large navigation title — the large-title region expands behind it. `SearchView` and `DictionaryView` pin `.inline` for this reason.
- **Workspaces are persistent.** `SearchView.configure` runs once per launch, so anything seeding a workspace from outside must drive its model directly (`SearchModel.startStrongsQuery`), and must not assume anything `configure` computes (e.g. `strongsAvailable`) has been computed — both `startStrongsQuery` and `optionsDidChange` gate on `module != nil`.

### Reading coordinator (`ReadingWorkspace.swift`)

- `ReadingWorkspaceModel` owns the two `ReaderPaneModel`s (Bible and commentary), the `displayChapter` fan-out, and study-popup routing. Cross-object coordination is method calls; the few remaining `NotificationCenter` observers exist only because something outside the reader posts them.
- **Both panes stay in the hierarchy** (inactive at `opacity(0)`). `displayChapter` renders the polled pane and defers `refToShow` / `pendingRestore` into the other; that deferral is what avoids rendering MHCC on every Bible chapter change. **`mode`'s `didSet` is the only drain**, so a font change (`redisplayWithDefaults()`) polls the **active** pane.
- `ReaderPaneModel.render` writes `lastRef` (toolbar title and relaunch restore both read it).
- Links arrive as `pslink://` URLs through the reader's `OpenURLAction` and open a `StudyPopupSheet`.
- **Chapter paging restores no position, in both directions.** `previousChapter()` / `nextChapter()` go through `page(forward:)` with `.none`. The verse-position defaults hold the verse in the chapter being *left*, so restoring them on paging lands on a wrong verse. Don't reintroduce a restore. Two entry points: the chevron toolbar buttons, and a horizontal swipe on the reader (left = next, right = previous).
- **The chapter swipe** is a `DragGesture` on `ReaderScreen`'s pane `ZStack` (one recogniser for whichever pane shows), attached with **`.gesture`, not `.simultaneousGesture`**: the chapter text is selectable, and dragging a selection handle is a sideways drag — recognised simultaneously, extending a selection turned the page (measured, iOS 27.2). At ordinary priority the text's own gestures win, a swipe on plain text or a link still pages, and vertical scrolling is unaffected. `ChapterSwipe` (`SwiftUIReaderChrome.swift`) is the pure swipe-versus-scroll classifier — distance, projected distance, 2:1 horizontal dominance — pinned by `testChapterSwipeClassifiesAFinishedDrag`. `ReadingWorkspaceModel.page(_:)` gates it on the flags that disable the chevrons, because `page(forward:)` clears the search highlight before its boundary check.
- **Paging starts the new chapter on a new scroll view.** `displayChapter`'s `.none` (paging is its only caller) hands both panes `PaneRestore.chapterStart`, which bumps `ReaderPaneModel.scrollSurface` — the `ScrollView`'s `.id` in `ChapterTextView` — and resets `scrollPosition`. Scrolling the *old* scroll view to the top (what `.none` still does for its other producers) does not land reliably after a chapter swap: the chapters share row ids, and the old view keeps its anchored row and its momentum. Measured: 7 chevron pages in 120 and 8 swipes in 32 left verse 1 in the wrong place (too low, drifting, or shifted sideways); 0 in 152 with a new scroll view. Don't "simplify" it back to a `scrollTo(edge: .top)`.
  - `.chapterStart` also **persists verse 1 / offset 0 itself**. A scroll view that starts at the top reports no movement, so nothing else writes those keys, and they hold the position in the chapter being left (`setToPreviousChapter` writes the destination's *last* verse). Pinned by `testPagingStartsANewScrollSurfaceAtThePersistedTopOfTheChapter`. `showRoutedMode` deliberately stays on `.none`: persisting verse 1 there would clobber the verse an inbound `sword://` URL just wrote.
  - The landing was intermittent, so `testSwipingTheReaderPagesChapters` (which pages from the foot of a chapter and compares against the chevron's landing) is a necessary check, not a sufficient one.
- **A page turn slides.** The swap between scroll surfaces is animated by `ChapterPageTransition` (`SwiftUIReaderChrome.swift`): the new chapter comes in from the right going forward and the left going back, pushing the old one out the other side, for a chevron and a swipe alike. Under Reduce Motion the two cross-fade in place. It travels the page's width plus the side safe-area insets (`overhang`), so in landscape on an iPhone the page leaves the screen rather than stopping in the margin beside the sensor housing. Each of these is measured (iOS 27.2), not stylistic:
  - **The slide is keyed on `ReaderPaneModel.pageTurn`, not on `scrollSurface`.** `page(forward:)` bumps `pageTurn` on the active pane only. The other pane bumps its surface later, when a Bible ⇄ commentary switch drains its deferred `.chapterStart`, and that swap must happen in place — it is a pane appearing, not a page turning. Pinned by `testOnlyThePaneOnScreenTurnsAPage`.
  - **The transition reads the direction from the pane when it runs; it does not store it.** SwiftUI removes a view with the transition value it was *last given*, which for the scroll view being left is the previous turn's. With the direction stored (`.push(from:)`), paging forward and then back sent the old chapter out to the left while the new one came in from the left too.
  - **The scroll view being left stays live for the length of the slide**, still coasting on any flick, and keeps reporting: paging straight after a flick, it sent 26 offsets and topmost verses from the old chapter in the 420 ms after the new chapter's position was persisted. `scrollOffsetChanged` / `topmostVerseChanged` therefore take the reporting surface (`from:`) and drop a replaced one; `ChapterTextView` captures `pane.scrollSurface` once per body and threads it into every callback. Pinned by `testAScrollViewBeingLeftCannotOverwriteTheNewChaptersPosition`. Don't drop the parameter, and don't read `pane.scrollSurface` inside a callback — that is always the current one.
  - **The page does not follow the finger during a swipe, and at `.gesture` priority it cannot.** SwiftUI holds the drag back until the text's own gestures have had the touch and then delivers all of it at once: every update of a 1.6-second drag arrived in the same millisecond as its end. Tracking the finger would need `.simultaneousGesture`, which is the attachment that made a selection drag turn the page.
- **A swipe that turns the page fires one light impact** (`sensoryFeedback` on `ReaderScreen`, triggered off `page(_:)`'s return value). A swipe that goes nowhere — a scroll, or back from Genesis 1 — is silent, and so are the chevrons. Pinned by `testASwipeReportsWhetherItTurnedThePage`. The simulator has no haptics: the trigger can be checked there, the feel only on a device.

### Content reader (render path)

**The app reads only from the baked store; there is no fallback.** Failures are split into **fatal** (store missing, schema/grammar mismatch, missing chunk sizes, bad versification — a crash beats a blank app) and **loud-and-nil** (one bad chapter must not brick the app). `PSContentReader.swift`'s header lists which is which; keep it accurate.

- `PSContentStore` — read-only SQLite + chunk framing, serial queue, zlib `uncompress()` (not `Compression.framework`; blobs are zlib-with-header with exact `raw_size`). Reads chunk sizes from `content_meta`.
- `PSChapterExpander` — tokens → the exact HTML the SWORD markup filters emitted. A disabled toggle **skips** its token. `Options.forHeading`: a title token is headings-gated in a chapter record but unconditional inside a stored heading.
- `PSChapterAssembler` — the chapter accumulator loop, quirks included. Its `entryCount` is **not** a verse count (it advances for skipped entries) and is pinned by `chapter-loop-counters.tsv`. Verse highlighting inserts at UTF-16 offsets over `NSMutableString`; redoing it over `String.Index` is a different algorithm.
- `PSBookOSISResolver` — book name → OSIS abbreviation, and the whole versification layer (`book(at:)`, `verseMax`, `nextChapter` / `previousChapter`, `displayRef`). next/prev return **nil** at Genesis 1 / Revelation 22 (not clamped — a clamped ref would turn a no-op into a full re-render). `displayRef` returns the un-munged `longName` form that call sites munge downstream.
- `PSRefParser` — free-text refs, `<book> [<chapter>[:<verse>[-<verse>]]]`, single book, deliberately narrow (header documents each omission). Its one production caller is inbound `sword://`. It is **wider** than `PSBookOSISResolver.resolve(ref:)`, so anything persisting a parsed ref must check the resolver accepts it (see `AppSession.open(_:)`).
- `PSRefLinkRouter` — pure `showRef` routing predicate; an unrecognised module type defaults to bible.
- `PSContentReader` — module selection, per-module option prefs, bookmark-highlight lookup. `chapterDocument(module:ref:kind:)` is **the render path**. `chapterBody(...)` returns engine-exact HTML and is kept as a **test oracle** — `PSChapterDocumentParityTests` proves the native document matches it.

### Native reader (`PSChapterDocument.swift`, `SwiftUINativeReader.swift`, `PSEntryDocument.swift`)

- **Two emitters over the same tokens, deliberately.** `PSChapterExpander` → HTML; `PSChapterDocumentBuilder` → `ChapterDocument`. Their independence is what makes the parity test meaningful — **do not make one call the other.** The chapter corpus is a closed set of six inline tags, which is why there is no HTML parser dependency.
- **Lexicon entries and footnotes have their own renderer** (`PSEntryDocument.swift`) with a wider vocabulary (`br`, `a name=` / `a href=`, `sup`/`sub`, `q`, `bib`).
  - Hebrew and Greek Strong's entries shape their key-anchor preamble differently. The "swallow the `<br />` after the key anchor" rule means *immediately* after; `testGreekLexiconKeepsItsLemmaLineBreak` pins it.
  - A link's run range is bounded at the anchor's **open** (`runs.count`), and re-applied at a `<br />` block boundary. `testEveryLexiconCrossLinkIsBoundToItsOwnAnchorText` and the synthetic `testCrossLinkSpanningALineBreakKeepsBothHalves` pin it.
  - An `OpenURLAction` that returns `.handled` with no handler swallows the tap. Claim `.handled` only when there is a handler; otherwise `.systemAction`.
  - Cross-links resolve in place in `StudyPopupSheet` (a `trail` + Back), not by stacking sheets. The `G`/`H` prefix comes from the **target** module (317 links go Greek → Hebrew).
- **The reader's side gutter is a scroll-content margin** (`contentMargins(.all, …, for: .scrollContent)`), not padding inside the content. The scroll view re-anchors to a row as lazy heights settle and aligns the row's leading edge with the content's; as padding, that left the chapter resting shifted left by the gutter, flush against the screen edge (1 chevron page in 120). Don't move it back.
- **Scroll position is identity**, via `ScrollPosition(id:)`. In prose mode rows are paragraphs, so `scrollToVerse` lands at the top of the verse's paragraph (`rowID(containing:)`).
  - Applying a scroll in the same update as a document change does nothing; `apply(_:)` defers by one update. `restoreAfterSizeChange` inlines its own copy of `apply`'s `.verse` body so the rotation suppression clears in the same hop — don't de-duplicate them.
  - **`ScrollPosition.scrollTo(y:)` is inset-relative**, and the persisted offset (`contentOffset.y + contentInsets.top`) matches it on purpose. This is measured, not a bug. At rest the sum is 0.
  - Launch offset restore: the reader's size settles in steps during launch, so the rotation hook fires; `restoreAfterSizeChange` prefers an outstanding offset restore. The first geometry publish is an unlaid-out scroll view and must not be persisted. `ReaderScrollSample` + `outstandingOffsetRestore` give `scrollOffsetChanged` a three-way gate (drop unlaid-out samples; clear on landing within 2 pt; give up at `maxOffset` when unreachable), released by `userBeganScrolling()`. Pinned by `testUnlaidOutGeometryDoesNotOverwriteThePersistedScrollOffset` and `testUnreachableOffsetRestoreGivesUpAtTheScrollViewsMaximum`.
  - Known residual: ~1 launch in 4 the toolbar title keeps `…:1` after a correct restore; self-corrects on first scroll. Don't assert on the nav-bar title in XCUITests here — assert on reader content.
  - The prose row set is cached on `ReaderPaneModel.paragraphs` (invalidated by `document`'s `didSet`). Never call `ChapterDocument.paragraphs` from a view body. The cache is on the model, not the value type, to keep `ChapterDocument`'s synthesized `Equatable` and memberwise init that the parity tests use.
- **Verse layout honours verse-per-line.** VPL off: prose, breaking at the KJV's pilcrows (all at verse starts). VPL on (default — an absent `vplPreference_<module>` reads as on via `UserDefaults.psBool`): one row per verse. A commentary always breaks per verse (MHCC has no pilcrows).

### Dictionary

- `dict_keys.key` is `COLLATE NOCASE` as defence in depth; both producers return the module's true key casing, and `PSContentStoreTests` asserts both casings resolve for all 15,824 keys. `DefaultsDictKeyCaseFixed` sweeps `<Caches>/cache-*` key caches by prefix.
- Rows iterate `LibraryModel.visibleDictionaryKeys` and are `NavigationLink(value: key)` + `.navigationDestination(for: String.self)`. Keep the value form: the `NavigationLink { destination } label:` form evaluates the destination (a lookup + inflate + expand) for every realized row.

### Search (`PSSearchEngine.swift`, `PSSearchQuery.swift`)

Search results expose a long-press **Copy Verse** action (reference plus normalized
verse text). Scrolling results dismisses the keyboard, and so does leaving the
Search workspace (see Workspaces — the order there is load-bearing); reselecting
the Search tab focuses the existing search field. Preserve the query, results,
module and persisted options during these interactions.

Each of these fails **silently** if "simplified":

1. `SQLITE_TRANSIENT` on every `sqlite3_bind_text`; SQL passed to `prepare_v2` / `exec` via `withCString`. Otherwise every query matches nothing.
2. `SQLITE_OPEN_FULLMUTEX` + `sqlite3_busy_timeout(2000)` and **no** serial queue, so a ~30 s build doesn't block every keystroke's query.
3. The FTS5 schema, its seven columns and their order, and `ORDER BY rowid` are fixed.
4. `PSSearchQuery.cleanDisplayText` runs **before** the emptiness test in the build loop, so it decides which rows exist.
5. The index is `<Caches>/search/<module>.db` (`AppPaths.searchIndexPath(for:)`), shared directory — **`dropIndex` must not remove the directory.** A cached engine whose file is gone reopens on demand.

`cleanDisplayText` (strips inline `<H0430>` markers) and `foldForIndex` (diacritic fold for `text_norm`) are pinned to known vectors in `PSSearchIndexParityTests`; changing either stops queries matching indexes already built on devices. Bump `PSSearchEngine.schemaVersion` to force a rebuild. `engine(forModuleName:)` returns a shared instance. Cancellation belongs to `SearchIndexCoordinator`.

### Module controller

`PSModuleController` (singleton, `defaultModuleController`) holds the primary Bible / commentary / dictionary as **`String?` names** (`primaryBibleName` etc.) plus ref-string helpers. `nil` means not yet resolved.

### Display preferences

The split by scope is load-bearing:

- **Per-module content toggles** (Strong's, morph, headings, footnotes, cross-refs, red-letter, verse-per-line) live in the reader's `ToolbarOverflowMenu`, built by `ReaderDisplayToggle.toggles(forModule:store:)`. Keys are `"<pref>_<ModuleName>"`, gated on the baked feature set (`content_meta` `module.<name>.features`, via `PSContentStore.moduleHasFeature`).
  - **KJV shows exactly six rows**: Strong's, Morph, Headings, Footnotes, Red Letter, Verse Per Line. **No cross-references** — KJV has no scripref feature. Don't "fix" this.
  - **MHCC has no rows**; the section is omitted. Both asserted by `AppStateStoresTests.testDisplayTogglesMatchBakedFeatureSets`.
- **Global**: font name + size and device options, in `SettingsView` (`SwiftUISupportingViews.swift`). **One font for the whole app**: `ChapterTextRenderer.Style.current()` reads only unsuffixed `fontNamePreference` / `fontSizePreference`.
- `EntryTextView` honours the same keys, with a legibility floor `EntryTextView.minimumBodySize` (14). The Strong's arm uses the system face (`usesSystemFace`). `AppConstants.defaultFontSize` (20; default face Georgia) is the single absent-key fallback (Swift-only; `globals.h` has no counterpart).
- Code2000 is no longer bundled or offered. Existing saved font preferences are not migrated.

### Constants: `globals.h` ↔ `AppConstants.swift`

**Dual-maintained.** `globals.h` is the source of truth for `Defaults*` keys, notification names, `ShownTab`, `PSSearch*`, `ModuleType`, `ATTRTYPE_*`, `SW_OUTPUT_*_KEY`, `SWMOD_*`. `AppConstants.swift` mirrors every wire string **byte-for-byte**. The persisted key often differs from the macro name (`DefaultsLastRef` → `"lastRef"`). Change one, change the other, or persisted data breaks.

- Retired keys (`DefaultsKJVRemoved`, `DefaultsMHCCRemoved`, `DefaultsStrongsGreekModule`, `DefaultsStrongsHebrewModule`, `DefaultsMorphGreekModule`) stay declared so the names aren't reused; `DefaultsModuleChoiceRetired` clears them.
- `ShownTab` ordinals may be persisted — do not renumber or delete. New code uses `ReadingMode` / `Workspace`.
- There are no Objective-C consumers of a generated Swift interface header. `@objc` annotations on model types are inert; don't read one as evidence of an Obj-C caller. `NSObject` subclassing on persisted model types is relied on by the byte-locked formats.

### Persistence

- `UserDefaults` with keys from `globals.h` / `AppConstants.swift`; per-module prefs are `"<PrefName>_<ModuleName>"` via the `UserDefaults.ps*(…forModule:)` extension.
- Reading history (`bibleHistory`) syncs through `NSUbiquitousKeyValueStore`; `HistoryStore` owns observer, merge/dedup/cap, write-back and `addEntry(mode:)` (the byte-locked `[ref, "0", mod, NSDate]` row). `addEntry` reads `lastRef` from its own injected `defaults`.
- Bookmarks: `Documents/PSBookmarks.plist` at the **root** of `Documents/` (see `DefaultsSwordRetired`).
- Derived data lives in Caches: search indexes and lexicon key caches.
- `bibleScrollPosition` / `commentaryScrollPosition` are raw `UserDefaults` string keys, written as `"%d"` of a `CGFloat`.

### URL handling

`sword://` is registered in `misc/icon/Info.plist`. URLs arrive via `onOpenURL` → `AppSession.open(_:)`; before launch prep finishes they are held in `pendingURL`.

| URL | resolves to |
|---|---|
| `sword://Bible/John%203:16` | John 3:16 |
| `sword://KJV/Romans%208:28` | Romans 8:28 (module name as host) |
| `sword://Bible/Jude` | Jude 1:1 |
| `sword://Bible/Genesis%201:1.` | Genesis 1:1 (trailing period tolerated) |

An unresolvable ref is ignored (no navigation, no history, one `alog` line).

## Localization

English only. Strings go through `NSLocalizedString` against `en.lproj/Localizable.strings` (source of truth for keys) and `Settings.bundle/en.lproj/Root.strings`. `knownRegions` lists only `en`; don't add locales without a deliberate decision.
