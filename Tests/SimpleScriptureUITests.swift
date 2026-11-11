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

    /// Each mode shows its own module's text for the chapter, and only its own.
    ///
    /// Judged by text only one pane can show. Both panes carry
    /// `reading.chapter-content` for the app's lifetime, so that identifier is
    /// there in either mode, rendered or not. A verse number is a link only in
    /// the Bible, and the sentence is how MHCC opens Genesis 1; the pane that is
    /// not showing is hidden from accessibility, so neither can be found in it.
    @MainActor
    func testBibleAndCommentaryModesBothRender() throws {
        // setUp leaves the app in the Read workspace, in the Bible.
        selectGenesisChapter(1)
        let bibleVerse = app.links["pslink://versemenu/1"]
        XCTAssertTrue(
            bibleVerse.waitForExistence(timeout: 5),
            "The Bible pane does not show Genesis 1."
        )

        selectReadingMode("Commentary")
        let commentary = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@",
                        "The first verse of the Bible gives us")
        ).firstMatch
        XCTAssertTrue(
            commentary.waitForExistence(timeout: 5),
            "The commentary pane does not show MHCC on Genesis 1."
        )
        XCTAssertFalse(
            bibleVerse.exists,
            "The Bible's text is still showing in the commentary."
        )

        selectReadingMode("Bible")
        XCTAssertTrue(
            bibleVerse.waitForExistence(timeout: 5),
            "The Bible pane did not come back with Genesis 1."
        )
        XCTAssertFalse(
            commentary.exists,
            "The commentary's text is still showing in the Bible."
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

        let font = app.buttons["settings.font"]
        let fontSheet = app.navigationBars["Font"]
        font.tap()
        XCTAssertTrue(fontSheet.waitForExistence(timeout: 5))
        let arial = app.buttons["Arial"]
        XCTAssertTrue(arial.waitForExistence(timeout: 5))
        arial.tap()
        // The sheet's own bar going is the return, and the row naming the font
        // is what shows the pick was taken. "Preferences" is no sign of either:
        // its bar is under the sheet the whole time the sheet is up.
        XCTAssertTrue(fontSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(font.label.hasSuffix("Arial"),
                      "Settings names \"\(font.label)\" after Arial was picked.")

        // The font is saved. Put the default back, or the app goes on reading in
        // Arial after this run. Georgia is some way down a lazy list, so its row
        // is not there until the list is scrolled to it. Slowly, so that one
        // swipe moves the list less than a screen and cannot carry the row past
        // (MEASURED, iOS 27.2: 528 pt of a list 742 pt tall), and only until the
        // row is clear of the sheet's bar and the foot of the screen.
        // `isHittable` is not that test: it was true of the row while it sat
        // under the bar.
        font.tap()
        XCTAssertTrue(fontSheet.waitForExistence(timeout: 5))
        let georgia = app.buttons["Georgia"]
        let screenBottom = app.windows.firstMatch.frame.maxY
        func georgiaIsInTheClear() -> Bool {
            georgia.exists
                && georgia.frame.minY >= fontSheet.frame.maxY
                && georgia.frame.maxY <= screenBottom
        }
        var inTheClear = georgiaIsInTheClear()
        for _ in 0..<4 where !inTheClear {
            app.swipeUp(velocity: .slow)
            inTheClear = georgiaIsInTheClear()
        }
        XCTAssertTrue(inTheClear,
                      "Scrolling the font list did not bring Georgia up.")
        georgia.tap()
        XCTAssertTrue(fontSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(font.label.hasSuffix("Georgia"),
                      "The font was left on \"\(font.label)\".")

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

    /// Choosing book, chapter and verse in the reference picker closes it and
    /// moves the reader to that verse.
    ///
    /// The reader starts in another chapter, so the choice has to move it, and
    /// the verse is one that does not open its chapter in either layout: flowing,
    /// the reader rests on the paragraph a chosen verse is in, and Genesis 1:10
    /// is in the third (verses 9-13).
    ///
    /// Judged by where that text is: the row, or the paragraph, holding verse 10
    /// starts at the top of the reading area. Not by the verse's number being
    /// there, which it is wherever the reader rests. MEASURED (iOS 27.2, flowing,
    /// 18 pt): at the top of Genesis 1 it is in the hierarchy and on screen, 769 pt
    /// down an 874 pt one.
    @MainActor
    func testReferencePickerSelectsVerse() throws {
        // setUp leaves the app in the Read workspace, in the Bible.
        selectGenesisChapter(3)

        let referenceButton = app.buttons["reading.reference-picker"]
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

        let versePage = app.navigationBars["Genesis 1"]
        XCTAssertTrue(versePage.waitForExistence(timeout: 5))
        let verse = app.buttons["reference.verse.10"]
        XCTAssertTrue(verse.waitForExistence(timeout: 5))
        verse.tap()

        // The verse page's own bar. "Select Book" went two pushes ago.
        XCTAssertTrue(
            versePage.waitForNonExistence(timeout: 5),
            "Choosing a verse did not close the reference picker."
        )
        // The label is the chapter the reader is in. The value is the title,
        // which carries the verse, and is not asserted on.
        let chosenText = app.staticTexts.containing(
            .link, identifier: "pslink://versemenu/10"
        ).firstMatch
        let readingAreaTop = app.navigationBars.firstMatch.frame.maxY
        let landed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                referenceButton.label == "Genesis 1"
                    && chosenText.exists
                    && abs(chosenText.frame.minY - readingAreaTop) <= 10
            },
            object: nil
        )
        let outcome = XCTWaiter().wait(for: [landed], timeout: 5)
        let rest = chosenText.exists
            ? "starts at y \(chosenText.frame.minY)" : "is not in the hierarchy"
        XCTAssertEqual(
            outcome, .completed,
            "After Genesis 1:10 was chosen the reader is in \(referenceButton.label) "
                + "and the text holding verse 10 \(rest); the reading area starts "
                + "at y \(readingAreaTop)."
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
            // The toggle is saved, and this is the only test that leaves it off.
            // End on the default, or the app stays in flowing prose after this
            // run and every later test starts there.
            setVersePerLine(true)
        }
    }

    /// A horizontal swipe on the reader pages by one chapter and lands at the top
    /// of it; a vertical scroll and a text-selection drag do not page at all.
    ///
    /// Only the simulator can answer this: the swipe is recognised alongside the
    /// scroll view's own pan, and a gesture attached the wrong way either never
    /// fires or stops the chapter scrolling. Both would pass every unit test.
    ///
    /// The landing is checked from the FOOT of a chapter, against where a chevron
    /// page from the top lands. That is the state paging mis-landed from when it
    /// scrolled the old scroll view to the top: verse 1 left some 110pt down the
    /// screen, but only in about one swipe in six, so a pass here is necessary and
    /// not sufficient. What rules it out is the new scroll surface per page, pinned
    /// by `testPagingStartsANewScrollSurfaceAtThePersistedTopOfTheChapter`.
    @MainActor
    func testSwipingTheReaderPagesChapters() throws {
        app.terminate()
        app.launchArguments += [
            "-strongsPreference_KJV", "NO",
            "-morphPreference_KJV", "NO",
            "-footnotesPreference_KJV", "NO",
            "-vplPreference_KJV", "NO",
            "-fontSizePreference", "18",
        ]
        app.launch()
        selectWorkspace("Read")
        selectReadingMode("Bible")
        selectGenesisChapter(1)

        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content").firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        let reference = app.buttons["reading.reference-picker"]
        let openings = [
            1: "In the beginning God created",
            2: "Thus the heavens and the earth",
            3: "Now the serpent was more subtil",
        ]

        func opening(_ chapter: Int) -> XCUIElement {
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", openings[chapter]!)
            ).firstMatch
        }

        func assertChapter(_ chapter: Int, after action: String) {
            XCTAssertTrue(opening(chapter).waitForExistence(timeout: 5),
                          "Genesis \(chapter) is not showing after \(action).")
            for other in openings.keys where other != chapter {
                XCTAssertFalse(opening(other).exists,
                               "Genesis \(other) is showing after \(action).")
            }
        }

        assertChapter(1, after: "selecting it")
        // Nothing precedes Genesis 1, so this is the disabled-chevron case.
        reader.swipeRight()
        assertChapter(1, after: "swiping back at the first chapter")

        // Where a page lands, taken from the chevron at the top of a chapter.
        app.buttons["reading.next-chapter"].tap()
        assertChapter(2, after: "the chevron")
        let verse1 = app.links["pslink://versemenu/1"]
        XCTAssertTrue(verse1.waitForExistence(timeout: 5))
        let landing = verse1.frame.origin

        func assertLandsAtTheTop(after action: String) {
            let landed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    guard verse1.exists else { return false }
                    let origin = verse1.frame.origin
                    return abs(origin.x - landing.x) <= 1 && abs(origin.y - landing.y) <= 1
                },
                object: nil
            )
            let outcome = XCTWaiter().wait(for: [landed], timeout: 5)
            let rest = verse1.exists ? "\(verse1.frame.origin)" : "off screen"
            XCTAssertEqual(outcome, .completed,
                           "Verse 1 came to rest at \(rest) after \(action); "
                               + "a page lands it at \(landing).")
        }

        func scrollToTheFoot() {
            for _ in 0..<5 { reader.swipeUp(velocity: .fast) }
        }

        scrollToTheFoot()
        reader.swipeLeft()
        assertChapter(3, after: "swiping forward")
        assertLandsAtTheTop(after: "swiping forward from the foot of Genesis 2")

        scrollToTheFoot()
        reader.swipeRight()
        assertChapter(2, after: "swiping back")
        assertLandsAtTheTop(after: "swiping back from the foot of Genesis 3")

        // The scroll still scrolls — the verse in the title moves — and stays in
        // the chapter it was in.
        let chapterReference = reference.label
        let verseBeforeScrolling = try XCTUnwrap(reference.value as? String)
        reader.swipeUp()
        let scrolled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (reference.value as? String) != verseBeforeScrolling
            },
            object: nil
        )
        wait(for: [scrolled], timeout: 10)
        XCTAssertEqual(reference.label, chapterReference,
                       "Scrolling the reader vertically changed the chapter.")
        XCTAssertFalse(opening(1).exists)
        XCTAssertFalse(opening(3).exists)

        // Dragging out a text selection is a sideways drag as well, and belongs to
        // the text: it must select, not page.
        let press = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45))
        let release = reader.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        press.press(forDuration: 1.0, thenDragTo: release)
        XCTAssertEqual(reference.label, chapterReference,
                       "Dragging out a text selection changed the chapter.")
        XCTAssertFalse(opening(1).exists)
        XCTAssertFalse(opening(3).exists)
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

    /// Relaunches at the top of Genesis 1 with the KJV's Strong's numbers showing.
    ///
    /// By launch argument, so the two lexicon tests need nothing from the
    /// container or from the test before them. Strong's numbers are off until
    /// someone turns them on, which is every fresh install and every simulator
    /// clone `xcodebuild` makes, and there both used to skip and report green.
    /// An argument shadows its key for the run and writes nothing; a tap on the
    /// menu's toggle would leave the numbers on for every later test and run.
    ///
    /// The place is seeded the same way, as
    /// `testReaderControlsStayVisibleAfterTapsAndScrolling` seeds it. That suits
    /// a test that opens a popup over the chapter and goes nowhere: a seeded
    /// `lastRef` hides every chapter change from the app for the whole run, so
    /// do not page or pick a reference after this. It is also why the reference
    /// picker is not used here. MEASURED (iOS 27.2): relaunched into Genesis 3
    /// flowing with the numbers on, every element query took 2.2 s where it
    /// takes 0.35 s, and the four taps to Genesis 1 took 31 s.
    @MainActor
    private func openGenesis1WithStrongsNumbers() {
        app.terminate()
        app.launchArguments += [
            "-strongsPreference_KJV", "YES",
            "-lastRef", "Genesis 1",
            "-bibleScrollPosition", "0",
            "-bibleVersePosition", "1",
        ]
        app.launch()
        // A launch always starts in the Read workspace, in the Bible.
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
        // The bar of the verse page itself. The picker is one navigation stack
        // whose bar takes the page's title, so by now "Select Book" is two pushes
        // gone and waiting for it to go waits for nothing.
        XCTAssertTrue(
            app.navigationBars["Genesis \(chapter)"].waitForNonExistence(timeout: 5),
            "Choosing a verse did not close the reference picker."
        )
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

    /// What Search does with the keyboard focus, with its bars while the results
    /// scroll, and with a long press.
    ///
    /// Judged by the keyboard FOCUS, not by the keyboard. Which control is typed
    /// into is the part the app decides — typing leaves it in the field, leaving
    /// Search takes it away, reselecting the Search tab puts it back — and it is
    /// there to read whether or not a software keyboard is drawn. The one thing
    /// that needs a keyboard on screen, a scroll putting it away, is
    /// `testScrollingSearchResultsDismissesTheKeyboard`.
    @MainActor
    func testSearchResultKeyboardAndCopyInteractions() throws {
        let field = search(for: "beginning")
        let results = searchResults
        let firstResult = results.firstMatch
        XCTAssertTrue(
            firstResult.waitForExistence(timeout: 10),
            "Search did not produce a result for 'beginning'."
        )
        XCTAssertTrue(
            waitForKeyboardFocus(field, true),
            "The search field is not holding the keyboard focus it was typed with."
        )

        firstResult.swipeUp()
        // Where a keyboard was drawn, the scroll puts it away, and the tab bar
        // is behind it until it has gone. Not asserted here.
        _ = waitForKeyboard(onScreen: false)
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
        XCTAssertTrue(
            app.buttons["MHCC"].waitForNonExistence(timeout: 5),
            "The Search module menu did not close."
        )

        // Leaving Search takes the keyboard focus out of the field and nothing
        // else: the query and its results are there to come back to. (It also
        // makes the reselection below mean something where no keyboard is drawn
        // and the scroll above has therefore left the field focused.)
        selectWorkspace("Read")
        selectWorkspace("Search")
        XCTAssertTrue(
            waitForKeyboardFocus(field, false),
            "The search field still held the keyboard focus after Search was left."
        )
        XCTAssertEqual(field.value as? String, "beginning",
                       "Leaving Search changed the query.")
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 5),
                      "Leaving Search dropped the results.")

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(
            waitForKeyboardFocus(field, true),
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

    /// Scrolling the search results puts the software keyboard away, and
    /// reselecting the Search tab brings it back.
    ///
    /// The one Search behaviour that needs a keyboard ON SCREEN. Without one
    /// this SKIPS — check the skip count — because there is nothing to judge it
    /// by instead: `scrollDismissesKeyboard` dismisses a keyboard that is
    /// showing, and with none showing a scroll leaves the field alone. MEASURED
    /// (iOS 27.2, keyboard parked below the screen): the field held the keyboard
    /// focus before a scroll of the results and still held it two seconds after.
    ///
    /// A simulator booted by `simctl` with no Simulator window does not draw the
    /// keyboard, and setting the per-device `ConnectHardwareKeyboard` preference
    /// to false and rebooting made no difference to that (MEASURED).
    @MainActor
    func testScrollingSearchResultsDismissesTheKeyboard() throws {
        let field = search(for: "beginning")
        let firstResult = searchResults.firstMatch
        XCTAssertTrue(
            firstResult.waitForExistence(timeout: 10),
            "Search did not produce a result for 'beginning'."
        )
        guard waitForKeyboard(onScreen: true) else {
            throw XCTSkip(
                "The software keyboard is not on screen, so there is nothing for "
                    + "a scroll to dismiss. The simulator is behaving as if a "
                    + "hardware keyboard is connected (in a Simulator window: "
                    + "I/O > Keyboard > Connect Hardware Keyboard)."
            )
        }

        firstResult.swipeUp()
        XCTAssertTrue(
            waitForKeyboard(onScreen: false),
            "Scrolling the search results did not dismiss the keyboard."
        )
        XCTAssertEqual(field.value as? String, "beginning",
                       "Dismissing the keyboard changed the query.")

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(
            waitForKeyboard(onScreen: true),
            "Reselecting the Search workspace did not bring the keyboard back."
        )
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

        // The choice is saved. Put the default back, or the app goes on opening
        // its Library on the dictionary after this run: the launch argument
        // decides what this run reads, not what it writes.
        selectWorkspace("Settings")
        picker.tap()
        let bookmarks = app.buttons["Bookmarks"].firstMatch
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 5))
        bookmarks.tap()
        XCTAssertTrue(picker.label.hasSuffix("Bookmarks"),
                      "The Library section was left on \"\(picker.label)\".")
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
        XCTAssertTrue(
            firstVerse.waitForExistence(timeout: 5),
            "Genesis 1 shows no verse 1 link"
        )
        XCTAssertGreaterThanOrEqual(
            firstVerse.frame.minY, navigationBarBottom - 1,
            "verse 1 is painted behind the navigation bar"
        )
    }

    /// Flowing prose still tracks the exact inline verse at the viewport top.
    ///
    /// Genesis 1's first paragraph contains verses 1-5 in one `Text`. A drag that
    /// stays inside that paragraph leaves a row-level tracker stuck at verse 1;
    /// the per-verse text-layout tracker must move the reference on, and to the
    /// verse whose text is on the line now at the top.
    ///
    /// The test brings its own chapter and its own layout. It used to start
    /// wherever the test before it had left the reader, and with Verse Per Line
    /// on — an absent key reads as on — every verse is a row of its own, so it
    /// passed without going near the text-layout tracker.
    ///
    /// The drag is held still before the finger lifts, so the reader moves the
    /// drag's own length and no further. MEASURED (iOS 27.2, iPhone 18 Pro, 18 pt):
    /// let go while moving, a drag of 149 pt coasted to 332 pt, past the foot of
    /// the paragraph (304 pt tall), and the reference read verse 6 — the first
    /// verse of the next ROW, which a row-level tracker reports just the same.
    @MainActor
    func testFlowingReaderTracksTheVisibleVerseWithinAParagraph() throws {
        app.terminate()
        app.launchArguments += [
            "-strongsPreference_KJV", "NO",
            "-morphPreference_KJV", "NO",
            "-footnotesPreference_KJV", "NO",
            "-vplPreference_KJV", "NO",
            "-fontSizePreference", "18",
        ]
        app.launch()
        // A launch always starts in the Read workspace, in the Bible.
        let reference = app.buttons["reading.reference-picker"]
        XCTAssertTrue(
            reference.waitForExistence(timeout: 20),
            "SimpleScripture did not finish initialization."
        )
        selectGenesisChapter(1)

        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content")
            .firstMatch
        let firstParagraph = app.staticTexts.containing(
            .link, identifier: "pslink://versemenu/1"
        ).firstMatch
        XCTAssertTrue(firstParagraph.waitForExistence(timeout: 5))
        XCTAssertTrue(
            firstParagraph.links["pslink://versemenu/2"].exists,
            "The reader is not in flowing prose."
        )
        let initialValue = try XCTUnwrap(reference.value as? String)

        let start = reader.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)
        )
        let end = start.withOffset(CGVector(dx: 0, dy: -200))
        start.press(
            forDuration: 0.05, thenDragTo: end,
            withVelocity: .slow, thenHoldForDuration: 0.5
        )

        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (reference.value as? String) != initialValue
            },
            object: nil
        )
        wait(for: [advanced], timeout: 10)
        XCTAssertNotEqual(reference.value as? String, initialValue)

        // The reading area starts under the navigation bar, and the tracker reads
        // the line 1 pt into it (MEASURED: a paragraph whose top was 0.4 pt below
        // the bar had already taken the reference).
        let topLine = app.navigationBars.firstMatch.frame.maxY + 1
        XCTAssertGreaterThan(
            firstParagraph.frame.maxY, topLine,
            "The drag left the first paragraph, so the row it landed in "
                + "accounts for the new reference without the inline tracker."
        )

        // The verse in the reference has text on that line: its number is on the
        // line or above it, and the next verse's number is on it or below. A
        // number in mid-line shares the line with the end of the verse before,
        // and either may be named; a verse wholly above or below may not. The
        // frames are the lines': a number's frame is as tall as the line it is
        // on. MEASURED with the fragments recorded at twice their depth, as they
        // once were: the reference read verse 2 with verse 4 on the line.
        func verseInTheReference() -> Int? {
            (reference.value as? String)?.split(separator: ":").last
                .flatMap { Int($0) }
        }
        func isOnTheTopLine(_ verse: Int) -> Bool {
            let number = app.links["pslink://versemenu/\(verse)"]
            let next = app.links["pslink://versemenu/\(verse + 1)"]
            guard number.exists, next.exists else { return false }
            return number.frame.minY <= topLine + 1.5
                && next.frame.maxY > topLine - 1.5
        }
        let named = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                verseInTheReference().map(isOnTheTopLine) ?? false
            },
            object: nil
        )
        let outcome = XCTWaiter().wait(for: [named], timeout: 5)
        let numbers = (1...6).map { verse -> String in
            let number = app.links["pslink://versemenu/\(verse)"]
            return "\(verse) at y \(number.exists ? "\(number.frame.minY)" : "?")"
        }
        XCTAssertEqual(
            outcome, .completed,
            "The reference reads \(reference.value as? String ?? "nothing") with "
                + "the top line at y \(topLine); the verse numbers are "
                + numbers.joined(separator: ", ") + "."
        )
    }

    /// Turning the phone leaves the reader on the verse it was on, there and back.
    ///
    /// Only a rotation on a device can answer this. A width change re-wraps every
    /// row, so the offset the reader held names different text afterwards, and
    /// the reader re-anchors on the verse at its top instead
    /// (`ReaderPaneModel.restoreAfterSizeChange`). The unit test for that proves
    /// what the model tells `ScrollPosition`; where the scroll view comes to rest
    /// once the system has resized it is measured here.
    ///
    /// The position is reached by finger, so the verse is one the view reported
    /// and the row at the top is scrolled part-way out. MEASURED (iOS 27.2,
    /// iPhone 18 Pro, 18 pt): three drags leave verse 15 with 68 pt of its row
    /// under the navigation bar and verse 16 the first whole verse. Turned, verse
    /// 15's number rests 0.1 pt above the bar's bottom edge, in landscape and
    /// back in portrait, and the same on each of three turns there and back.
    /// That snap to the top of the row being read is why the verse before the
    /// first whole one is accepted, and no other.
    ///
    /// With the offset replayed, as it used to be, landscape came to rest with
    /// verse 27 the first whole verse, eleven on: portrait's 1278 pt names verse
    /// 26 in a chapter whose rows are half as tall.
    ///
    /// Judged by the verse numbers, not by the reference in the navigation bar.
    @MainActor
    func testRotatingTheReaderKeepsTheVerseBeingRead() throws {
        // Registered before anything turns: a failure must not leave the device
        // on its side for every test after this one.
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments += [
            "-strongsPreference_KJV", "NO",
            "-morphPreference_KJV", "NO",
            "-footnotesPreference_KJV", "NO",
            "-vplPreference_KJV", "YES",
            "-fontSizePreference", "18",
            // Rotation Lock is a saved setting, and a locked app does not turn.
            "-rotationLockedPosition", "0",
        ]
        app.launch()
        selectWorkspace("Read")
        selectReadingMode("Bible")
        selectGenesisChapter(1)
        XCTAssertTrue(app.links["pslink://versemenu/1"].waitForExistence(timeout: 5))

        dragTheReaderUp(times: 3)
        let reading = try XCTUnwrap(
            try verseAtTheTopOfTheReader(),
            "The reader shows no verse number after scrolling."
        )
        XCTAssertGreaterThan(
            reading.verse, 5,
            "The drags did not take the reader into the chapter, so there is "
                + "no position for a rotation to lose."
        )

        turnTheDevice(to: .landscapeLeft)
        let onItsSide = try XCTUnwrap(
            try verseAtTheTopOfTheReader(),
            "The reader shows no verse number in landscape."
        )
        XCTAssertTrue(
            (reading.verse - 1...reading.verse).contains(onItsSide.verse),
            "Verse \(reading.verse) was the first whole verse in the reader; "
                + "turned to landscape, verse \(onItsSide.verse) is."
        )

        turnTheDevice(to: .portrait)
        let upright = try XCTUnwrap(
            try verseAtTheTopOfTheReader(),
            "The reader shows no verse number back in portrait."
        )
        XCTAssertTrue(
            (reading.verse - 1...reading.verse).contains(upright.verse),
            "Verse \(reading.verse) was the first whole verse in the reader; "
                + "turned to landscape and back, verse \(upright.verse) is."
        )
        XCTAssertEqual(
            upright.origin.x, reading.origin.x, accuracy: 1,
            "The chapter came back from landscape shifted sideways."
        )
    }

    /// A Strong's number in the chapter text opens its lexicon entry. The reader's
    /// links are real accessibility elements carrying their `pslink://` target,
    /// so the whole tap path is driven from the test.
    @MainActor
    func testStrongsLinkOpensItsLexiconEntry() throws {
        openGenesis1WithStrongsNumbers()
        // Genesis 1:1's first Strong's number, H07225 (bereshith).
        let strongs = app.links["pslink://strongs/Hebrew/07225"]
        XCTAssertTrue(
            strongs.waitForExistence(timeout: 10),
            "Genesis 1:1 shows no H07225 marker with Strong's numbers on"
        )
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
        openGenesis1WithStrongsNumbers()
        let strongs = app.links["pslink://strongs/Hebrew/07225"]
        XCTAssertTrue(
            strongs.waitForExistence(timeout: 10),
            "Genesis 1:1 shows no H07225 marker with Strong's numbers on"
        )
        strongs.tap()

        let popup = app.descendants(matching: .any)["study.popup"]
        XCTAssertTrue(popup.firstMatch.waitForExistence(timeout: 10),
                      "the study popup did not open")

        // The cross-link is a real, addressable element — not a span of dead text.
        // The content is fixed and the entry does name H07218, so a link that is
        // not there is the renderer losing it: a failure, not a skip.
        let crossLink = app.links["pslink://lexicon/StrongsRealHebrew?key=07218"]
        XCTAssertTrue(
            crossLink.waitForExistence(timeout: 5),
            "H07225's entry lost its cross-link to H07218"
        )
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

            // One swipe does not always move the reference on. A commentary record
            // covers a run of verses, and MHCC's first in Genesis 1 is several
            // screens long, so the commentary pane needs more than one.
            var advanced = false
            for _ in 0..<6 where !advanced {
                reader.swipeUp()
                let moved = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        (reference.value as? String) != initialReference
                    },
                    object: nil
                )
                advanced = XCTWaiter().wait(for: [moved], timeout: 3) == .completed
            }
            XCTAssertTrue(advanced,
                          "Scrolling the \(mode) pane never moved the reference on.")
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

    /// The reader's ••• menu is the active module's display toggles and nothing
    /// else, and a module with none has no ••• button at all.
    ///
    /// Only a UI run can see the button: it is the system's, drawn while a
    /// `ToolbarOverflowMenu` is declared. Declared with nothing in it, it was
    /// still drawn for the commentary, where this test used to find it, tap it
    /// and get an empty menu. MEASURED (iOS 27.2) with no menu declared: no
    /// button, and the rest of the bar stays where it was.
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
        let titles = ["Strong's Numbers", "Morphological Tags", "Headings",
                      "Footnotes", "Red Letter", "Verse Per Line"]
        XCTAssertTrue(app.buttons[titles[0]].waitForExistence(timeout: 5))
        for title in titles {
            XCTAssertTrue(app.buttons[title].exists,
                          "The Bible's display menu is missing \(title).")
        }
        XCTAssertFalse(app.buttons["Cross-references"].exists)
        // The toggles are the whole menu. Its "History and Search" action went
        // with Focus mode: Search is a tab, and the tab bar no longer hides.
        XCTAssertFalse(app.buttons["History and Search"].exists)
        // The open menu is the one collection view on screen (iOS 27.2
        // hierarchy), so its buttons are the rows, in order.
        XCTAssertEqual(
            app.collectionViews.buttons.allElementsBoundByIndex.map(\.label),
            titles,
            "The Bible's display menu is not exactly its six toggles."
        )
        dismissMenu()
        XCTAssertTrue(
            app.buttons[titles[0]].waitForNonExistence(timeout: 5),
            "The display menu did not close."
        )

        // Where the bar and the Bible pane rest, to compare below. The pane by
        // one of its verse numbers, which only the Bible has, and not through
        // `reading.chapter-content`: which of the two panes that query lists
        // first is not fixed. MEASURED (iOS 27.2): back in the Bible after a
        // visit to the commentary, the first match was the hidden commentary
        // pane, which exposes no text.
        let overflow = readingOverflowButton
        let reference = app.buttons["reading.reference-picker"]
        let referenceMidX = reference.frame.midX
        let topVerse = app.links.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "pslink://versemenu/")
        ).firstMatch
        XCTAssertTrue(topVerse.waitForExistence(timeout: 5))
        let topVerseIdentifier = topVerse.identifier
        let topVerseY = topVerse.frame.minY

        // MHCC advertises nothing, so the commentary has no display menu, and no
        // button offering one.
        selectReadingMode("Commentary")
        XCTAssertTrue(
            overflow.waitForNonExistence(timeout: 5),
            "The commentary has a ••• button with no menu behind it."
        )
        // Nothing else left with it, and the reference did not slide over into
        // the space.
        for identifier in ["reading.mode", "reading.previous-chapter",
                           "reading.reference-picker", "reading.next-chapter"] {
            XCTAssertTrue(app.buttons[identifier].exists,
                          "The commentary's bar lost \(identifier).")
        }
        XCTAssertEqual(reference.frame.midX, referenceMidX, accuracy: 1,
                       "The reference moved when the ••• button went.")

        // The button comes back with a module that has toggles, still opens its
        // menu, and the Bible pane is where it was left: the toolbar's content
        // changed, not the panes under it.
        selectReadingMode("Bible")
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 5),
            "The Bible's ••• button did not come back after the commentary."
        )
        let sameVerse = app.links[topVerseIdentifier].firstMatch
        XCTAssertTrue(
            sameVerse.waitForExistence(timeout: 5),
            "The Bible pane lost its place across a visit to the commentary."
        )
        XCTAssertEqual(sameVerse.frame.minY, topVerseY, accuracy: 1,
                       "The Bible pane moved across a visit to the commentary.")
        openReadingOverflowMenu()
        XCTAssertTrue(app.buttons[titles[0]].waitForExistence(timeout: 5))
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

    /// The reading toolbar's ••• button, where there is one.
    ///
    /// `ToolbarOverflowMenu` is system-provided, so its button carries the system's
    /// own identity rather than one we set: confirmed on the iOS 27 simulator as
    /// identifier `OverflowBarButtonItem` / label "More", and on iOS 27.2 as
    /// `TopOverflowBarButtonItem`. Matched by the identifier's suffix, which both
    /// share, since the label is localized.
    @MainActor
    private var readingOverflowButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH %@", "OverflowBarButtonItem")
        ).firstMatch
    }

    /// Scrolls the reader up by finger, each drag held still before the finger
    /// lifts so the reader moves the drag's own length and does not coast.
    @MainActor
    private func dragTheReaderUp(times: Int) {
        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content").firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 5))
        for _ in 0..<times {
            let start = reader.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)
            )
            let end = reader.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
            )
            start.press(
                forDuration: 0.05, thenDragTo: end,
                withVelocity: .slow, thenHoldForDuration: 0.5
            )
        }
    }

    /// Turns the device and waits for the reader to have turned with it.
    @MainActor
    private func turnTheDevice(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let reader = app.descendants(matching: .any)
            .matching(identifier: "reading.chapter-content").firstMatch
        let turned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard reader.exists else { return false }
                let frame = reader.frame
                return orientation.isLandscape
                    ? frame.width > frame.height
                    : frame.height > frame.width
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [turned], timeout: 10), .completed,
            "The reader did not turn with the device."
        )
    }

    /// The reader's verse numbers and where each is drawn, top to bottom.
    ///
    /// From ONE snapshot of the hierarchy, so the frames belong to the same
    /// instant. Asking each link for its frame is a query apiece, and a reader
    /// that is still settling moves between them.
    @MainActor
    private func verseNumbersInTheReader() throws -> [(verse: Int, frame: CGRect)] {
        let prefix = "pslink://versemenu/"
        var found: [(verse: Int, frame: CGRect)] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.elementType == .link, element.identifier.hasPrefix(prefix),
               let verse = Int(element.identifier.dropFirst(prefix.count)) {
                found.append((verse: verse, frame: element.frame))
            }
            element.children.forEach(collect)
        }
        collect(try app.snapshot())
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The first verse number inside the reading area, and where it is, once
    /// the reader has come to rest: two looks half a second apart that agree.
    ///
    /// The reading area starts under the navigation bar. The scroll view itself
    /// runs to the top of the screen, so a row scrolled part-way out still has
    /// its number in the hierarchy, above that line.
    @MainActor
    private func verseAtTheTopOfTheReader(
        timeout: TimeInterval = 10
    ) throws -> (verse: Int, origin: CGPoint)? {
        var last: (verse: Int, origin: CGPoint)?
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let top = app.navigationBars.firstMatch.frame.maxY
            let first = try verseNumbersInTheReader()
                .first { $0.frame.minY >= top - 1 }
                .map { (verse: $0.verse, origin: $0.frame.origin) }
            if let first, let last, first.verse == last.verse,
               abs(first.origin.x - last.origin.x) <= 0.5,
               abs(first.origin.y - last.origin.y) <= 0.5 {
                return first
            }
            last = first
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// Opens the reading toolbar's iOS 27 overflow menu.
    @MainActor
    private func openReadingOverflowMenu() {
        let overflow = readingOverflowButton
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 5),
            "Could not find the reading toolbar's overflow menu."
        )
        overflow.tap()
    }

    /// Opens Search and types `query` into its field, which is returned still
    /// holding the keyboard focus.
    ///
    /// Over the whole Bible: the scope is persisted, and a run that starts from
    /// a container left on "Book" would search whatever book the reader is in.
    @MainActor
    private func search(for query: String) -> XCUIElement {
        selectWorkspace("Search")

        let buildIndex = app.buttons["search.index-build"]
        if buildIndex.waitForExistence(timeout: 2) {
            buildIndex.tap()
            XCTAssertTrue(
                app.staticTexts["Search Scripture"].waitForExistence(timeout: 60),
                "The search index did not finish building."
            )
        }

        let wholeBible = app.segmentedControls["search.scope"].buttons["All"]
        XCTAssertTrue(wholeBible.waitForExistence(timeout: 5))
        wholeBible.tap()

        let field = app.searchFields["Search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(query)
        return field
    }

    /// The rows of the Search result list.
    @MainActor
    private var searchResults: XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")
        )
    }

    /// Waits for `element` to hold the keyboard focus, or to have let go of it.
    ///
    /// Focus is what the app decides — which control is typed into — and it is
    /// there to read whether or not a software keyboard is drawn. The attribute
    /// is the one the hierarchy dump prints as "Keyboard Focused"; XCTest has no
    /// public accessor for it, hence the key.
    @MainActor
    private func waitForKeyboardFocus(
        _ element: XCUIElement, _ focused: Bool, timeout: TimeInterval = 5
    ) -> Bool {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard element.exists else { return false }
                let hasFocus = element.value(forKey: "hasKeyboardFocus") as? Bool
                return hasFocus == focused
            },
            object: nil
        )
        return XCTWaiter().wait(for: [settled], timeout: timeout) == .completed
    }

    /// Waits for the software keyboard to be on screen, or to be off it.
    ///
    /// By FRAME, not `exists`. `exists` asks whether the element is in the
    /// hierarchy, and a keyboard that is not showing is still in it, parked
    /// below the screen. MEASURED on an iOS 27.2 simulator booted by `simctl`
    /// with no Simulator window: `Keyboard {{0, 918}, {402, 226}}` on an
    /// 874-point screen from the moment the field is tapped, not hittable, and
    /// unmoved by typing and by a scroll. Judged by `exists`, "the keyboard is
    /// up" cannot fail there and "the keyboard went away" cannot pass.
    @MainActor
    private func waitForKeyboard(
        onScreen: Bool, timeout: TimeInterval = 5
    ) -> Bool {
        let keyboard = app.keyboards.firstMatch
        let screenBottom = app.windows.firstMatch.frame.maxY
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let isOnScreen = keyboard.exists
                    && keyboard.frame.minY < screenBottom - 1
                return isOnScreen == onScreen
            },
            object: nil
        )
        return XCTWaiter().wait(for: [settled], timeout: timeout) == .completed
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
