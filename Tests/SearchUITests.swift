import XCTest

/// The Search workspace: results, the keyboard, the header's count, and
/// opening a result in the reader.
///
/// One class, so the search index is built once, on the clone that runs them,
/// and not on several: a clone is a fresh install, with no index.
final class SearchUITests: SimpleScriptureUITestCase {
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

    /// The header over the results counts the verses found, or says the list was
    /// cut.
    ///
    /// A search lists at most 1,000 verses, and the header used to print that cap
    /// as the count. The model's unit test proves a list longer than the cap is
    /// cut and flagged. That the default query asks the engine for one row past
    /// the cap, which is the only way the model can know there were more, and
    /// what the header then says, are only here. Asked for exactly the cap, the
    /// model is never handed more than it lists and the header goes back to
    /// "1,000 Results" with every unit test passing. MEASURED (iOS 27.2) with
    /// the query asking for exactly the cap: the header for "the" read "1,000
    /// Results", and this failed.
    ///
    /// "Melchizedek" is in two verses of the KJV (the New Testament spells it
    /// "Melchisedec"), and "the" in far more than a thousand.
    @MainActor
    func testSearchHeaderSaysWhenTheListWasCut() throws {
        func header() -> String {
            app.staticTexts.matching(
                NSPredicate(format: "label ENDSWITH %@", "Results")
            ).allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        }

        let field = search(for: "Melchizedek")
        XCTAssertTrue(
            app.staticTexts["2 Results"].waitForExistence(timeout: 15),
            "The header over the results for 'Melchizedek' reads \"\(header())\"."
        )

        field.typeText(String(
            repeating: XCUIKeyboardKey.delete.rawValue, count: "Melchizedek".count
        ))
        field.typeText("the")
        XCTAssertTrue(
            app.staticTexts["First 1,000 Results"].waitForExistence(timeout: 15),
            "The header over the results for 'the' reads \"\(header())\"."
        )
    }

    // MARK: - Helpers

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
}
