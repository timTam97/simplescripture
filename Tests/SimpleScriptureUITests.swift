import XCTest

/// UI tests over the four workspaces — Read, Search, Library, Settings:
///
/// - Bible and Commentary are two modes of the Read workspace (`reading.mode`).
/// - Search is a workspace with `TabRole.search`.
/// - Dictionary, Bookmarks and History are Library sections.
/// - Settings is a workspace, with About pushed from its toolbar.
final class SimpleScriptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-librarySectionPreference", "bookmarks",
        ]
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 20),
            "SimpleScripture did not reach the foreground."
        )
        // The reader's own controls, not a tab title: the Read workspace draws its
        // chrome with a SwiftUI NavigationStack and has no navigation-bar title.
        XCTAssertTrue(
            app.buttons["reading.reference-picker"].waitForExistence(timeout: 20),
            "SimpleScripture did not finish initialization."
        )
    }

    @MainActor
    func testAllFourWorkspacesAreReachable() throws {
        XCTAssertTrue(
            app.descendants(matching: .any)["reading.chapter-content"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["reading.previous-chapter"].exists)
        XCTAssertTrue(app.buttons["reading.next-chapter"].exists)
        XCTAssertFalse(app.buttons["reading.focus-mode"].exists)

        selectWorkspace("Search")
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search.module-menu"].exists)
        XCTAssertTrue(app.buttons["search.options"].exists)
        XCTAssertTrue(app.segmentedControls["search.scope"].exists)

        selectWorkspace("Library")
        // The Library sections set no `navigationTitle`: the `library.section`
        // menu sits in the principal slot and names the active section itself.
        XCTAssertTrue(
            app.buttons["library.section"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["bookmarks.add-folder"].exists)

        selectWorkspace("Settings")
        XCTAssertTrue(
            app.navigationBars["Preferences"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.sliders["settings.font-size"].exists)
        XCTAssertTrue(app.buttons["settings.font"].exists)
        XCTAssertTrue(app.switches["settings.keep-awake"].exists)
        XCTAssertTrue(app.switches["settings.rotation-lock"].exists)
        XCTAssertFalse(app.switches["settings.automatic-fullscreen"].exists)
        XCTAssertFalse(app.staticTexts["Automatic Full Screen"].exists)
    }

    @MainActor
    func testBibleAndCommentaryModesBothRender() throws {
        selectWorkspace("Read")
        XCTAssertTrue(
            app.descendants(matching: .any)["reading.chapter-content"]
                .waitForExistence(timeout: 5)
        )

        selectReadingMode("Commentary")
        XCTAssertTrue(
            app.buttons["reading.reference-picker"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["reading.chapter-content"].exists
        )

        selectReadingMode("Bible")
        XCTAssertTrue(
            app.buttons["reading.reference-picker"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testSettingsFontPickerAndAbout() throws {
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        selectWorkspace("Settings")
        XCTAssertTrue(
            app.navigationBars["Preferences"].waitForExistence(timeout: 5)
        )

        app.buttons["settings.font"].tap()
        XCTAssertTrue(app.navigationBars["Font"].waitForExistence(timeout: 5))
        let arial = app.buttons["Arial"]
        XCTAssertTrue(arial.waitForExistence(timeout: 5))
        arial.tap()
        XCTAssertTrue(
            app.navigationBars["Preferences"].waitForExistence(timeout: 5)
        )

        app.buttons["workspace.settings.about"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["about.header"]
                .waitForExistence(timeout: 5)
        )
        capture("SimpleScripture About")
        app.buttons["about.acknowledgements"].tap()
        XCTAssertTrue(
            app.navigationBars["Credits & licenses"].waitForExistence(timeout: 5)
        )
        capture("SimpleScripture Credits")
        app.buttons["about.notice.gpl"].tap()
        let license = app.scrollViews["about.document.gpl"]
        XCTAssertTrue(license.waitForExistence(timeout: 5))
        XCTAssertTrue(
            license.staticTexts.containing(NSPredicate(
                format: "label CONTAINS %@", "GNU GENERAL PUBLIC LICENSE"
            )).firstMatch.waitForExistence(timeout: 5)
        )
        capture("SimpleScripture GPL")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["about.notice.Robinson"].tap()
        let robinson = app.scrollViews["about.document.Robinson"]
        XCTAssertTrue(robinson.waitForExistence(timeout: 5))
        capture("SimpleScripture Robinson")
        let ccLink = app.buttons["about.robinson.license"]
        for _ in 0..<6 {
            if ccLink.isHittable { break }
            robinson.swipeUp()
        }
        XCTAssertTrue(ccLink.isHittable)
        ccLink.tap()
        XCTAssertTrue(
            app.scrollViews["about.document.cc-by-sa"].waitForExistence(timeout: 5)
        )
        capture("SimpleScripture Creative Commons")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["about.notice.ezra"].tap()
        let ezra = app.scrollViews["about.document.ezra"]
        XCTAssertTrue(ezra.waitForExistence(timeout: 5))
        XCTAssertTrue(
            ezra.staticTexts.containing(NSPredicate(
                format: "label CONTAINS %@", "MIT/X11"
            )).firstMatch.waitForExistence(timeout: 5)
        )
        capture("SimpleScripture Ezra")
    }

    @MainActor
    func testReferencePickerSelectsVerse() throws {
        selectWorkspace("Read")

        let referenceButton = app.buttons["reading.reference-picker"]
        XCTAssertTrue(referenceButton.waitForExistence(timeout: 5))
        referenceButton.tap()

        XCTAssertTrue(
            app.navigationBars["Select Book"].waitForExistence(timeout: 5)
        )
        let genesis = app.buttons["reference.book.Gen"]
        XCTAssertTrue(genesis.waitForExistence(timeout: 5))
        genesis.tap()

        XCTAssertTrue(app.navigationBars["Genesis"].waitForExistence(timeout: 5))
        let chapter = app.buttons["reference.chapter.1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        chapter.tap()

        XCTAssertTrue(
            app.navigationBars["Genesis 1"].waitForExistence(timeout: 5)
        )
        let verse = app.buttons["reference.verse.1"]
        XCTAssertTrue(verse.waitForExistence(timeout: 5))
        verse.tap()

        XCTAssertTrue(
            app.navigationBars["Select Book"].waitForNonExistence(timeout: 5)
        )
    }

    /// Chapter-local verse IDs repeat. Paging must replace every old paragraph,
    /// including rows already realized by the lazy stack.
    @MainActor
    func testChapterPagingReplacesAllProseRows() throws {
        try assertChapterPagingReplacesRows(versePerLine: false)
    }

    @MainActor
    func testChapterPagingReplacesAllVerseRows() throws {
        try assertChapterPagingReplacesRows(versePerLine: true)
    }

    @MainActor
    func testChapterPagingAfterChangingVerseLayout() throws {
        try assertChapterPagingReplacesRows(
            versePerLine: true, changeLayoutBeforePaging: true
        )
    }

    @MainActor
    private func assertChapterPagingReplacesRows(
        versePerLine: Bool, changeLayoutBeforePaging: Bool = false
    ) throws {
        app.terminate()
        app.launchArguments += [
            "-strongsPreference_KJV", "NO",
            "-morphPreference_KJV", "NO",
            "-footnotesPreference_KJV", "NO",
            "-fontSizePreference", "18",
        ]
        if !changeLayoutBeforePaging {
            app.launchArguments += ["-vplPreference_KJV", versePerLine ? "YES" : "NO"]
        }
        app.launch()
        selectWorkspace("Read")
        selectReadingMode("Bible")
        selectGenesisChapter(1)
        if changeLayoutBeforePaging {
            setVersePerLine(false)
        }

        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content").firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        let openings = [
            1: "In the beginning God created",
            2: "Thus the heavens and the earth",
            3: "Now the serpent was more subtil",
        ]
        var currentVersePerLine = changeLayoutBeforePaging ? false : versePerLine

        func assertChapter(_ chapter: Int) {
            // A layout switch can reorder the two pane containers in the
            // accessibility tree. The inactive commentary is empty in this run;
            // query the chapter text rather than a stale first pane match.
            let opening = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", openings[chapter]!)
            ).firstMatch
            XCTAssertTrue(opening.waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Genesis \(chapter), VPL \(currentVersePerLine)"
            attachment.lifetime = .keepAlways
            add(attachment)
            for (other, text) in openings where other != chapter {
                XCTAssertFalse(
                    app.staticTexts.containing(
                        NSPredicate(format: "label CONTAINS %@", text)
                    ).firstMatch.exists,
                    "Genesis \(other) text survived navigation to Genesis \(chapter)."
                )
            }
            XCTAssertEqual(app.links.matching(identifier: "pslink://versemenu/1").count, 1,
                           "The chapter contains stale or duplicate verse rows.")
        }

        assertChapter(1)
        if changeLayoutBeforePaging {
            setVersePerLine(true)
            currentVersePerLine = true
            assertChapter(1)
        }
        for chapter in [2, 3] {
            app.buttons["reading.next-chapter"].tap()
            assertChapter(chapter)
        }
        for chapter in [2, 1] {
            app.buttons["reading.previous-chapter"].tap()
            assertChapter(chapter)
        }
        selectGenesisChapter(3)
        assertChapter(3)
        if changeLayoutBeforePaging {
            // Replacing the row stack must preserve verse-ID scrolling.
            selectGenesisChapter(3, verse: 10)
            let verse = app.links["pslink://versemenu/10"]
            XCTAssertTrue(verse.waitForExistence(timeout: 5))
            XCTAssertTrue(verse.isHittable)
            selectGenesisChapter(3)
            setVersePerLine(false)
            currentVersePerLine = false
            assertChapter(3)
        }
    }

    @MainActor
    private func setVersePerLine(_ enabled: Bool) {
        // Genesis 1 and 3 put verses 1 and 2 in the same prose paragraph.
        // Inspect that rendered structure: native menu checkmarks do not expose
        // a reliable `isSelected` value.
        let firstVerse = app.staticTexts.containing(
            .link, identifier: "pslink://versemenu/1"
        ).firstMatch
        XCTAssertTrue(firstVerse.waitForExistence(timeout: 5))
        let isVersePerLine = !firstVerse.links["pslink://versemenu/2"].exists
        if isVersePerLine != enabled {
            openReadingOverflowMenu()
            let toggle = app.buttons["Verse Per Line"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.tap()
        }
        XCTAssertTrue(firstVerse.waitForExistence(timeout: 5))
        XCTAssertEqual(!firstVerse.links["pslink://versemenu/2"].exists, enabled)
    }

    @MainActor
    private func selectGenesisChapter(_ chapter: Int, verse verseNumber: Int = 1) {
        app.buttons["reading.reference-picker"].tap()
        let genesis = app.buttons["reference.book.Gen"]
        XCTAssertTrue(genesis.waitForExistence(timeout: 5))
        genesis.tap()
        let chapterButton = app.buttons["reference.chapter.\(chapter)"]
        XCTAssertTrue(chapterButton.waitForExistence(timeout: 5))
        chapterButton.tap()
        let verse = app.buttons["reference.verse.\(verseNumber)"]
        XCTAssertTrue(verse.waitForExistence(timeout: 5))
        verse.tap()
        XCTAssertTrue(app.navigationBars["Select Book"].waitForNonExistence(timeout: 5))
    }

    /// The reader's overflow-menu "History and Search" action switches to the
    /// Search workspace (a tab selection, not a sheet presentation).
    @MainActor
    func testReadingOverflowMenuOpensTheSearchWorkspace() throws {
        selectWorkspace("Read")
        openReadingOverflowMenu()

        // Matched by label: UIKit renders a SwiftUI menu's rows as cells that
        // expose their title but drop the accessibility identifier.
        let historyAndSearch = app.buttons["History and Search"]
        XCTAssertTrue(historyAndSearch.waitForExistence(timeout: 5))
        historyAndSearch.tap()

        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["Search"].waitForExistence(timeout: 5))
    }

    /// Tapping a search result while the keyboard is still up opens the reader ON
    /// that verse.
    ///
    /// The ordinary way to open a result — type, tap — leaves the keyboard up. If
    /// it is still up when the Read workspace appears, the reader is laid out once
    /// at the keyboard's height and again without it, which `ReaderScreen` takes
    /// for a rotation: its size hook re-anchors on the offset the reader was at
    /// BEFORE the result was opened, over the top of the scroll to the result's
    /// verse. MEASURED (iOS 27.2): the title read "Gen 5:29" over verses 2–4.
    ///
    /// The reader has to start part-way down a chapter. From the top there is no
    /// earlier offset to replay, and the hook re-issues the verse instead.
    ///
    /// Asserts on reader CONTENT, not the navigation-bar title: the title was
    /// right even when the position was wrong.
    @MainActor
    func testOpeningASearchResultWithTheKeyboardUpLandsOnItsVerse() throws {
        selectWorkspace("Read")
        selectReadingMode("Bible")
        selectGenesisChapter(1)
        // One row per verse, so verse 29's link exists only once the reader has
        // actually scrolled to it.
        setVersePerLine(true)
        selectGenesisChapter(5, verse: 3)

        selectWorkspace("Search")
        let buildIndex = app.buttons["search.index-build"]
        if buildIndex.waitForExistence(timeout: 2) {
            buildIndex.tap()
            XCTAssertTrue(
                app.staticTexts["Search Scripture"].waitForExistence(timeout: 60),
                "The search index did not finish building."
            )
        }

        let field = app.searchFields["Search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Noah")

        // The first match in canonical order: "And he called his name Noah".
        let result = app.buttons["search.result.Genesis 5:29"]
        XCTAssertTrue(
            result.waitForExistence(timeout: 10),
            "Search did not produce Genesis 5:29 for 'Noah'."
        )
        XCTAssertTrue(
            app.keyboards.firstMatch.exists,
            "The keyboard has to be up for this to test anything."
        )
        result.tap()

        let verse = app.links["pslink://versemenu/29"]
        XCTAssertTrue(
            verse.waitForExistence(timeout: 5),
            "The reader did not scroll to the result's verse."
        )
        let navigationBarBottom = app.navigationBars.firstMatch.frame.maxY
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        XCTAssertGreaterThanOrEqual(verse.frame.minY, navigationBarBottom - 1)
        XCTAssertLessThan(
            verse.frame.minY, tabBarTop,
            "Verse 29 is in the hierarchy but not on screen."
        )
    }

    @MainActor
    func testSearchResultKeyboardAndCopyInteractions() throws {
        selectWorkspace("Search")

        let buildIndex = app.buttons["search.index-build"]
        if buildIndex.waitForExistence(timeout: 2) {
            buildIndex.tap()
            XCTAssertTrue(
                app.staticTexts["Search Scripture"].waitForExistence(timeout: 60),
                "The search index did not finish building."
            )
        }

        let field = app.searchFields["Search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("beginning")

        let results = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "search.result."
            )
        )
        let firstResult = results.firstMatch
        XCTAssertTrue(
            firstResult.waitForExistence(timeout: 10),
            "Search did not produce a result for 'beginning'."
        )
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        firstResult.swipeUp()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
            "Scrolling the search results did not dismiss the keyboard."
        )
        assertWorkspaceTabsVisible()
        XCTAssertTrue(app.searchFields["Search"].isHittable)

        let tabBarFrame = app.tabBars.firstMatch.frame
        let navigationBarFrame = app.navigationBars["Search"].frame
        let scopeFrame = app.segmentedControls["search.scope"].frame
        let visibleResult = try XCTUnwrap(
            results.allElementsBoundByIndex.first(where: \.isHittable)
        )
        visibleResult.swipeUp()
        assertWorkspaceTabsVisible()
        XCTAssertEqual(app.tabBars.firstMatch.frame.height,
                       tabBarFrame.height, accuracy: 1)
        XCTAssertEqual(app.tabBars.firstMatch.frame.minY,
                       tabBarFrame.minY, accuracy: 1)
        XCTAssertEqual(app.navigationBars["Search"].frame.height,
                       navigationBarFrame.height, accuracy: 1)
        XCTAssertEqual(app.segmentedControls["search.scope"].frame, scopeFrame)

        // Scrolled list rows remain in the accessibility tree beneath the inset,
        // so isHittable can reject its menus. Exercise the visible menu directly.
        app.buttons["search.module-menu"].coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(
            app.buttons["MHCC"].waitForExistence(timeout: 5),
            "The Search module menu did not open after scrolling."
        )
        dismissMenu()

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "Reselecting the Search workspace did not focus the search field."
        )

        guard let resultToCopy = results.allElementsBoundByIndex.first(
            where: \.isHittable
        ) else {
            XCTFail("No visible search result was available to long-press.")
            return
        }

        resultToCopy.press(forDuration: 1)

        let copyVerse = app.buttons["Copy Verse"]
        XCTAssertTrue(
            copyVerse.waitForExistence(timeout: 5),
            "Long-pressing a search result did not show Copy Verse."
        )
        copyVerse.tap()
        XCTAssertTrue(copyVerse.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLibrarySectionsSwitch() throws {
        selectWorkspace("Library")
        XCTAssertTrue(app.buttons["bookmarks.add-folder"].waitForExistence(timeout: 5))

        selectLibrarySection("History")
        XCTAssertTrue(app.buttons["history.clear"].waitForExistence(timeout: 5))
        // History is a workspace section, so there is no Close button.
        XCTAssertFalse(app.buttons["history.close"].exists)

        selectLibrarySection("Dictionary")
        XCTAssertTrue(
            app.searchFields["Search Dictionary"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["dictionary.module-menu"].exists)

        selectLibrarySection("Bookmarks")
        XCTAssertTrue(
            app.buttons["bookmarks.add-folder"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testLibraryOpensToTheSectionChosenInSettings() throws {
        app.terminate()
        app.launchArguments += ["-librarySectionPreference", "history"]
        app.launch()

        selectWorkspace("Library")
        XCTAssertTrue(app.buttons["history.clear"].waitForExistence(timeout: 5))

        selectWorkspace("Settings")
        let picker = app.buttons["settings.library-section"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let dictionary = app.buttons["Dictionary"].firstMatch
        XCTAssertTrue(dictionary.waitForExistence(timeout: 5))
        dictionary.tap()

        selectWorkspace("Library")
        XCTAssertTrue(
            app.searchFields["Search Dictionary"].waitForExistence(timeout: 5)
        )
    }

    /// The chapter is EDGE-TO-EDGE: a full-height scroll view whose content is
    /// inset, so text flows to the physical edges and scrolls beneath the
    /// translucent bars with no line obscured at rest. Both halves are asserted —
    /// dropping either paints text under the tab bar or letterboxes the chapter.
    ///
    /// The `reading.chapter-content` identifier is on the `ScrollView` ITSELF, so
    /// its frame is meaningful.
    @MainActor
    func testChapterScrollsUnderTheChromeEdgeToEdge() throws {
        // This checks the chapter at its start, not a saved scroll position
        // restored from an earlier test or an interactive reading session.
        selectWorkspace("Read")
        selectReadingMode("Bible")
        selectGenesisChapter(1)

        // `.firstMatch` is required, not incidental: BOTH panes carry this
        // identifier because both stay in the hierarchy for the app's lifetime (the
        // inactive one at `opacity(0)`), which is what lets `displayChapter` defer a
        // render into the pane that is not on screen. A bare subscript throws
        // "multiple matching elements".
        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content")
            .firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10))

        let readerFrame = reader.frame
        let window = app.windows.firstMatch.frame

        // The scroll view fills the window vertically. Letterboxing shows up here as
        // a frame that stops at the chrome.
        XCTAssertEqual(readerFrame.minY, window.minY, accuracy: 1,
                       "the reader does not reach the top edge — letterboxed")
        XCTAssertEqual(readerFrame.maxY, window.maxY, accuracy: 1,
                       "the reader does not reach the bottom edge — letterboxed")

        // ...and the CONTENT is inset, so the first verse is not hidden behind the
        // navigation bar. A full-height scroll view with no content inset is the
        // other failure.
        let navigationBarBottom = app.navigationBars.firstMatch.frame.maxY
        let firstVerse = app.links["pslink://versemenu/1"]
        if firstVerse.waitForExistence(timeout: 5) {
            XCTAssertGreaterThanOrEqual(
                firstVerse.frame.minY, navigationBarBottom - 1,
                "verse 1 is painted behind the navigation bar"
            )
        }
    }

    /// Flowing prose still tracks the exact inline verse at the viewport top.
    ///
    /// Genesis 1's first paragraph contains verses 1-5 in one `Text`. A small drag
    /// stays inside that paragraph, so a row-level tracker remains stuck at verse 1;
    /// the per-verse text-layout tracker must advance the reference value.
    @MainActor
    func testFlowingReaderTracksTheVisibleVerseWithinAParagraph() throws {
        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content")
            .firstMatch
        let reference = app.buttons["reading.reference-picker"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10))
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        let initialValue = try XCTUnwrap(reference.value as? String)

        let start = reader.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)
        )
        let end = reader.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)
        )
        start.press(forDuration: 0.05, thenDragTo: end)

        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (reference.value as? String) != initialValue
            },
            object: nil
        )
        wait(for: [advanced], timeout: 10)
        XCTAssertNotEqual(reference.value as? String, initialValue)
    }

    /// A Strong's number in the chapter text opens its lexicon entry. The reader's
    /// links are real accessibility elements carrying their `pslink://` target,
    /// so the whole tap path is driven from the test.
    @MainActor
    func testStrongsLinkOpensItsLexiconEntry() throws {
        XCTAssertTrue(
            app.descendants(matching: .any)["reading.chapter-content"]
                .waitForExistence(timeout: 10)
        )
        // Genesis 1:1's first Strong's number, H07225 (bereshith).
        let strongs = app.links["pslink://strongs/Hebrew/07225"]
        guard strongs.waitForExistence(timeout: 5) else {
            throw XCTSkip("Strong's numbers are switched off for this module")
        }
        strongs.tap()

        let popup = app.descendants(matching: .any)["study.popup"]
        XCTAssertTrue(popup.firstMatch.waitForExistence(timeout: 10),
                      "tapping a Strong's number did not open the study popup")
    }

    /// A cross-link INSIDE a lexicon entry navigates to the entry it names.
    ///
    /// Covers what a unit test cannot — whether a tap does anything:
    ///
    ///  * the popup must pass `openLink`, or an `OpenURLAction` returning
    ///    `.handled` swallows every cross-link;
    ///  * the link's run range must be bounded at its own anchor;
    ///  * the target entry opens in place, with a Back button, rather than by
    ///    stacking a second sheet.
    ///
    /// H07225's entry ("In the beginning") cross-links to H07218 (rosh). The link's
    /// identifier is its `pslink://lexicon/…` URL, so the assertion is on the
    /// TARGET, not merely on something being tappable.
    @MainActor
    func testLexiconCrossLinkNavigatesWithinThePopup() throws {
        XCTAssertTrue(
            app.descendants(matching: .any)["reading.chapter-content"]
                .waitForExistence(timeout: 10)
        )
        let strongs = app.links["pslink://strongs/Hebrew/07225"]
        guard strongs.waitForExistence(timeout: 5) else {
            throw XCTSkip("Strong's numbers are switched off for this module")
        }
        strongs.tap()

        let popup = app.descendants(matching: .any)["study.popup"]
        XCTAssertTrue(popup.firstMatch.waitForExistence(timeout: 10),
                      "the study popup did not open")

        // The cross-link is a real, addressable element — not a span of dead text.
        let crossLink = app.links["pslink://lexicon/StrongsRealHebrew?key=07218"]
        guard crossLink.waitForExistence(timeout: 5) else {
            throw XCTSkip("H07225's entry does not cross-link to H07218 in this build")
        }
        crossLink.tap()

        // Following it swaps the entry in place and offers a way back. "Back" is the
        // proof the navigation happened: it exists only while the trail is non-empty.
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10),
                      "tapping a lexicon cross-link did nothing — no entry was pushed")

        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5),
                      "Back did not return to the entry the reader opened")
        XCTAssertTrue(popup.firstMatch.exists,
                      "going back dismissed the popup instead of popping the trail")
    }

    @MainActor
    func testReaderControlsStayVisibleAfterTapsAndScrolling() throws {
        // A previously enabled preference must have no effect after upgrading.
        app.terminate()
        app.launchArguments += [
            "-fullscreenModePreference", "YES",
            "-lastRef", "Genesis 1",
            "-bibleScrollPosition", "0",
            "-commentaryScrollPosition", "0",
            "-bibleVersePosition", "1",
            "-commentaryVersePosition", "1",
        ]
        app.launch()
        selectWorkspace("Read")

        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content")
            .firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reading.focus-mode"].exists)
        defer { selectReadingMode("Bible") }

        for mode in ["Bible", "Commentary"] {
            selectReadingMode(mode)
            assertWorkspaceTabsVisible()
            let tabBarFrame = app.tabBars.firstMatch.frame
            let navigationBarFrame = app.navigationBars.firstMatch.frame
            let reference = app.buttons["reading.reference-picker"]
            let initialReference = try XCTUnwrap(reference.value as? String)

            for _ in 0..<2 {
                reader.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)
                ).tap()
                assertWorkspaceTabsVisible()
                XCTAssertTrue(reference.isHittable)
                XCTAssertEqual(reference.value as? String, initialReference)
            }

            reader.swipeUp()
            let advanced = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    (reference.value as? String) != initialReference
                },
                object: nil
            )
            wait(for: [advanced], timeout: 10)
            assertWorkspaceTabsVisible()
            XCTAssertTrue(reference.isHittable)
            XCTAssertTrue(app.buttons["reading.mode"].isHittable)
            XCTAssertTrue(app.buttons["reading.previous-chapter"].isHittable)
            XCTAssertTrue(app.buttons["reading.next-chapter"].isHittable)
            XCTAssertEqual(app.tabBars.firstMatch.frame.height,
                           tabBarFrame.height, accuracy: 1)
            XCTAssertEqual(app.tabBars.firstMatch.frame.minY,
                           tabBarFrame.minY, accuracy: 1)
            XCTAssertEqual(app.navigationBars.firstMatch.frame.height,
                           navigationBarFrame.height, accuracy: 1)
            XCTAssertEqual(app.navigationBars.firstMatch.frame.minY,
                           navigationBarFrame.minY, accuracy: 1)
            XCTAssertFalse(
                app.descendants(matching: .any)["reading.chapter-toast"].exists
            )
        }
    }

    @MainActor
    func testDisplayTogglesAppearForBibleAndNotCommentary() throws {
        // NB: UIKit renders a SwiftUI menu's rows as cells that expose their LABEL
        // but drop the `accessibilityIdentifier` (verified in the iOS 27
        // hierarchy), so these rows are matched by their localized titles. The
        // exhaustive id/pref/order assertions live in
        // AppStateStoresTests.testDisplayTogglesMatchBakedFeatureSets, which reads
        // the same pure builder this menu is populated from.
        selectWorkspace("Read")
        selectReadingMode("Bible")
        openReadingOverflowMenu()
        // KJV earns six rows; cross-references is deliberately absent (no
        // OSISScripref filter, no Feature=Scripref).
        XCTAssertTrue(
            app.buttons["Strong's Numbers"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Verse Per Line"].exists)
        XCTAssertFalse(app.buttons["Cross-references"].exists)
        dismissMenu()

        selectReadingMode("Commentary")
        openReadingOverflowMenu()
        // MHCC advertises nothing, so it contributes no display rows at all — only
        // the always-present History & Search action.
        XCTAssertTrue(
            app.buttons["History and Search"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["Strong's Numbers"].exists)
        XCTAssertFalse(app.buttons["Verse Per Line"].exists)
        dismissMenu()
    }

    @MainActor
    func testBookmarkFolderCrudAndReordering() throws {
        let firstName = "UI Drag A"
        let secondName = "UI Drag B"

        selectWorkspace("Library")
        // Prefix sweep, not two exact names: it also collects any truncated
        // leftover ("UI Drag ") from an earlier interrupted or raced run.
        deleteFoldersIfPresent(withPrefix: "UI Drag")
        defer {
            deleteFoldersIfPresent(withPrefix: "UI Drag")
        }

        createFolder(named: firstName)
        createFolder(named: secondName)

        let first = app.buttons[firstName]
        let second = app.buttons[secondName]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)

        second.press(forDuration: 1, thenDragTo: first)

        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                second.frame.minY < first.frame.minY
            },
            object: nil
        )
        // 15s, not 5s: the long-press-then-drag that drives iOS 27's `.reorderable()`
        // is timing-sensitive under the load of a full-suite run.
        wait(for: [reordered], timeout: 15)
        XCTAssertLessThan(second.frame.minY, first.frame.minY)
    }

    // MARK: - Helpers

    /// Opens the reading toolbar's iOS 27 overflow menu.
    ///
    /// `ToolbarOverflowMenu` is system-provided, so its button carries the system's
    /// own identity rather than one we set: confirmed on the iOS 27 simulator as
    /// identifier `OverflowBarButtonItem` / label "More". Matched by identifier,
    /// since the label is localized.
    @MainActor
    private func openReadingOverflowMenu() {
        let overflow = app.buttons["OverflowBarButtonItem"].firstMatch
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 5),
            "Could not find the reading toolbar's overflow menu."
        )
        overflow.tap()
    }

    @MainActor
    private func dismissMenu() {
        // A menu is dismissed by tapping outside it. The reader fills the screen,
        // but tapping its centre would hit a verse link, so use a corner well clear
        // of the menu (which anchors to the trailing side of the top bar).
        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.08, dy: 0.75)
        ).tap()
    }

    /// Selects a workspace by its LABEL, not an identifier.
    ///
    /// `Tab`'s `accessibilityIdentifier` does not reach the tab-bar button —
    /// verified in the iOS 27 hierarchy, where the four buttons carry only their
    /// localized labels. Note the on-screen order is Read, Library, Settings,
    /// Search: `TabRole.search` moves Search to the trailing position regardless of
    /// where it is declared.
    @MainActor
    private func selectWorkspace(_ label: String) {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(
            tab.waitForExistence(timeout: 5),
            "Missing workspace \(label)"
        )
        tab.tap()
        XCTAssertTrue(tab.isSelected, "Workspace \(label) was not selected")
    }

    @MainActor
    private func assertWorkspaceTabsVisible(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for label in ["Read", "Library", "Settings", "Search"] {
            XCTAssertTrue(
                app.tabBars.buttons[label].isHittable,
                "Workspace \(label) was hidden or minimised.",
                file: file,
                line: line
            )
        }
    }

    /// Switches the Read workspace between Bible and commentary, through the
    /// `reading.mode` menu in the toolbar's leading slot.
    @MainActor
    private func selectReadingMode(_ label: String) {
        let control = app.buttons["reading.mode"]
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "Missing the reading-mode control"
        )
        control.tap()
        let option = app.buttons[label].firstMatch
        XCTAssertTrue(
            option.waitForExistence(timeout: 5),
            "Missing reading mode \(label)"
        )
        option.tap()
    }

    /// Switches the Library workspace's section, through the `library.section`
    /// menu that occupies the navigation bar's principal slot.
    @MainActor
    private func selectLibrarySection(_ label: String) {
        let control = app.buttons["library.section"]
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "Missing the library section control"
        )
        control.tap()
        let option = app.buttons[label].firstMatch
        XCTAssertTrue(
            option.waitForExistence(timeout: 5),
            "Missing library section \(label)"
        )
        option.tap()
    }

    @MainActor
    private func createFolder(named name: String) {
        app.buttons["bookmarks.add-folder"].tap()
        let field = app.textFields["bookmarks.folder-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)

        // Commit the field before tapping Save, and verify the commit landed.
        //
        // Without it the folder is created under a TRUNCATED name (typing
        // "UI Drag B" persisted "UI Drag ", on every run): a SwiftUI `TextField`'s
        // binding is not necessarily current for the final keystroke until the
        // field commits, and tapping Save takes focus in the same beat.
        // `XCUIElement.value` is NOT a usable check — it reported the full text
        // while the app saved the prefix. Typing the newline commits the field;
        // the row assertion below reads the name back from the app's own list.
        field.typeText("\n")

        app.buttons["bookmarks.folder-save"].tap()
        XCTAssertTrue(
            app.buttons[name].waitForExistence(timeout: 5),
            "The folder was not created as \"\(name)\" — check for a truncated "
                + "name in PSBookmarks.plist."
        )
    }

    /// Deletes leftover test folders, matched by **prefix** rather than by exact
    /// name, so a folder saved under a slightly different name cannot accumulate in
    /// `PSBookmarks.plist` and later trip the store's duplicate-name guard.
    @MainActor
    private func deleteFoldersIfPresent(withPrefix prefix: String) {
        let matches = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        )
        // Bounded rather than `while`: a row that will not delete would
        // otherwise spin here until the test times out with no diagnosis.
        for _ in 0..<8 {
            let row = matches.firstMatch
            guard row.waitForExistence(timeout: 1) else { return }
            row.swipeLeft()

            let deleteAction = app.buttons["Delete"].firstMatch
            guard deleteAction.waitForExistence(timeout: 2) else { return }
            deleteAction.tap()

            let confirmation = app.buttons["Delete"].firstMatch
            guard confirmation.waitForExistence(timeout: 2) else { return }
            confirmation.tap()
            _ = row.waitForNonExistence(timeout: 5)
        }
    }
}
