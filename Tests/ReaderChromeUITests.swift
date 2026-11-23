import XCTest

/// The Read workspace's chrome: the four workspaces, the Bible and commentary
/// modes, the reader edge to edge under the bars, controls that stay put, and
/// the display menu.
final class ReaderChromeUITests: SimpleScriptureUITestCase {
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
        // OSISScripref filter, no Feature=Scripref). The Strong's row is a
        // submenu whose label carries its choice, `Strong's Numbers, Off`
        // (MEASURED, iOS 27.2: the subtitle is folded into the label).
        let titles = ["Strong's Numbers", "Morphological Tags", "Headings",
                      "Footnotes", "Red Letter", "Verse Per Line"]
        let strongsRow = strongsDisplayRow
        XCTAssertTrue(strongsRow.waitForExistence(timeout: 5))
        for title in titles.dropFirst() {
            XCTAssertTrue(app.buttons[title].exists,
                          "The Bible's display menu is missing \(title).")
        }
        XCTAssertFalse(app.buttons["Cross-references"].exists)
        // The toggles are the whole menu. Its "History and Search" action went
        // with Focus mode: Search is a tab, and the tab bar no longer hides.
        XCTAssertFalse(app.buttons["History and Search"].exists)
        // The open menu is the one collection view on screen (iOS 27.2
        // hierarchy), so its buttons are the rows, in order.
        let rows = app.collectionViews.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(
            rows.map { $0.hasPrefix("\(titles[0]), ") ? titles[0] : $0 },
            titles,
            "The Bible's display menu is not exactly its six toggles: \(rows)"
        )
        dismissMenu()
        XCTAssertTrue(
            strongsRow.waitForNonExistence(timeout: 5),
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
        XCTAssertTrue(strongsRow.waitForExistence(timeout: 5))
        dismissMenu()
    }

    /// The Strong's row offers Off, Numbers and Underlined Words, says which
    /// is chosen, and the reader follows each choice: the markers with
    /// Numbers, the words as links with Underlined Words, neither with Off.
    ///
    /// Chosen through the menu, so the keys are not launch arguments (an
    /// argument would shadow the menu's writes), and the test ends on Off:
    /// a fresh clone's choice, and the one every other test expects unless it
    /// passes its own. MEASURED (iOS 27.2): before the words' text was keyed
    /// on whether it links them (`ChapterRunsText.linksWords`), Off to
    /// Underlined Words drew the underlines with no link in the hierarchy,
    /// and back to Off left all 73 of Genesis 1's.
    ///
    /// The place is a launch argument: the test pages nowhere.
    @MainActor
    func testStrongsChoiceSwitchesBetweenNumbersAndUnderlinedWords() throws {
        app.terminate()
        app.launchArguments += [
            "-lastRef", "Genesis 1",
            "-bibleScrollPosition", "0",
            "-bibleVersePosition", "1",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["reading.reference-picker"].waitForExistence(timeout: 20),
            "SimpleScripture did not finish initialization."
        )
        let word = strongsWordLink("pslink://strongsword/H07225")
        let marker = app.links["pslink://strongs/Hebrew/07225"]

        chooseStrongsDisplay("Underlined Words")
        XCTAssertTrue(word.waitForExistence(timeout: 10),
                      "Underlined Words did not make \"In the beginning\" a link")
        XCTAssertEqual(word.label, "In the beginning")
        XCTAssertFalse(marker.exists, "Underlined Words drew the numbers")

        chooseStrongsDisplay("Numbers", from: "Underlined Words")
        XCTAssertTrue(marker.waitForExistence(timeout: 10),
                      "Numbers did not draw the H07225 marker")
        XCTAssertFalse(word.exists, "Numbers left the words linked")

        chooseStrongsDisplay("Off", from: "Numbers")
        XCTAssertTrue(marker.waitForNonExistence(timeout: 10),
                      "Off left the markers")
        XCTAssertFalse(word.exists, "Off left the words linked")
        // Off straight from Underlined Words takes the links off too.
        chooseStrongsDisplay("Underlined Words", from: "Off")
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        chooseStrongsDisplay("Off", from: "Underlined Words")
        XCTAssertTrue(word.waitForNonExistence(timeout: 10),
                      "Off from Underlined Words left the words' links in the hierarchy")

        // The row reads the choice it was left on.
        openReadingOverflowMenu()
        XCTAssertTrue(strongsDisplayRow.waitForExistence(timeout: 5))
        XCTAssertEqual(strongsDisplayRow.label, "Strong's Numbers, Off")
        dismissMenu()
    }

    // MARK: - Helpers

    /// The ••• menu's Strong's row, whose label carries the choice.
    private var strongsDisplayRow: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Strong's Numbers")
        ).firstMatch
    }

    /// Chooses `label` in the ••• menu's Strong's submenu, checking first that
    /// the row reads `current` when given. The menu closes on the choice.
    @MainActor
    private func chooseStrongsDisplay(
        _ label: String, from current: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        openReadingOverflowMenu()
        let row = strongsDisplayRow
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The display menu has no Strong's row", file: file, line: line)
        if let current {
            XCTAssertEqual(row.label, "Strong's Numbers, \(current)",
                           "The Strong's row does not read its choice",
                           file: file, line: line)
        }
        row.tap()
        let choice = app.buttons[label].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5),
                      "The Strong's submenu offers no \(label)", file: file, line: line)
        choice.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                      "The menu stayed open after choosing \(label)",
                      file: file, line: line)
    }
}
