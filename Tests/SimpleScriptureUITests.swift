import XCTest

/// What every UI test shares: the launch in `setUpWithError` and the helpers
/// that drive the four workspaces — Read, Search, Library, Settings:
///
/// - Bible and Commentary are two modes of the Read workspace (`reading.mode`).
/// - Search is a workspace with `TabRole.search`.
/// - Dictionary, Bookmarks and History are Library sections.
/// - Settings is a workspace, with About pushed from its toolbar.
///
/// The tests themselves are in one class per part of the app, each in a file
/// of its own, because parallel testing hands each simulator clone whole
/// classes, never single tests. As one class they all ran on one clone, one
/// after another. A clone is a fresh install and runs the classes it is given
/// one after another, so a test can still find what an earlier test on the
/// same clone left behind, and cannot know which tests those were: a test
/// that needs a place, a layout or a setting brings it.
///
/// Holds no tests of its own.
class SimpleScriptureUITestCase: XCTestCase {
    var app: XCUIApplication!

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

    // MARK: - Helpers shared by the test classes

    /// Relaunches into the Bible with the KJV's markers off, at 18 pt, in the
    /// given layout and with Headings on or off.
    ///
    /// The layout and the toggles are launch arguments: nothing that uses this
    /// changes them, and an argument writes nothing.
    @MainActor
    func relaunchWithMarkersOff(
        _ arguments: [String], versePerLine: Bool, headings: Bool
    ) {
        app.terminate()
        app.launchArguments = arguments + [
            "-strongsPreference_KJV", "NO",
            "-morphPreference_KJV", "NO",
            "-footnotesPreference_KJV", "NO",
            "-headingsPreference_KJV", headings ? "YES" : "NO",
            "-vplPreference_KJV", versePerLine ? "YES" : "NO",
            "-fontSizePreference", "18",
        ]
        app.launch()
        // A launch always starts in the Read workspace, in the Bible.
        XCTAssertTrue(
            app.buttons["reading.reference-picker"].waitForExistence(timeout: 20),
            "SimpleScripture did not finish initialization."
        )
    }

    @MainActor
    func setVersePerLine(_ enabled: Bool) {
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

    /// Picks a chapter and verse of Genesis in the reference picker, from
    /// whatever book the reader is in.
    ///
    /// The picker opens with the reader's own book in the middle of a lazy list
    /// of sixty-six, so Genesis is only there to tap when the reader is near the
    /// front of the Bible. Most tests leave it in Genesis;
    /// `testStrongsLinkInAPsalmTitleOpensItsLexiconEntry` and a reading session
    /// on the same simulator do not. MEASURED (iOS 27.2) with the app left in
    /// Psalms 3: no `reference.book.Gen` in the hierarchy, and this failed at
    /// its first assertion.
    ///
    /// So the list is swiped down until Genesis is clear of the picker's bar. A
    /// row under the bar exists and cannot be tapped. MEASURED: one swipe from
    /// Psalms 3 and four from Revelation 22, and the sheet stayed up. A swipe is
    /// only made while Genesis is out of reach, which is with the list away from
    /// its top; a drag that pulls the sheet down starts with the list at its
    /// top.
    @MainActor
    func selectGenesisChapter(_ chapter: Int, verse verseNumber: Int = 1) {
        selectChapter(chapter, verse: verseNumber, ofBook: "Gen", named: "Genesis")
    }

    /// Picks a chapter and verse of any book in the reference picker, from
    /// whatever book the reader is in. `bookID` is the book's OSIS name, which
    /// identifies its row, and `bookName` the name the picker's bar gives it.
    ///
    /// A book off screen in the lazy list is not in the hierarchy, so which way
    /// it lies cannot be asked. Genesis is brought up first, as
    /// `selectGenesisChapter` describes, which puts every other book below. The
    /// list is then dragged up until the book can be tapped, each drag held
    /// still before the finger lifts so the list moves the drag's own length
    /// and does not coast: under half of what the list shows at once, so the
    /// book cannot pass through the screen between two looks. MEASURED (iOS
    /// 27.2, iPhone 18 Pro): one drag brings Psalms, the nineteenth book, into
    /// reach, with the reader in Genesis 1 and, after the one swipe down, in
    /// Psalms 3.
    @MainActor
    func selectChapter(
        _ chapter: Int, verse verseNumber: Int = 1,
        ofBook bookID: String, named bookName: String
    ) {
        app.buttons["reading.reference-picker"].tap()
        let bookList = app.navigationBars["Select Book"]
        XCTAssertTrue(bookList.waitForExistence(timeout: 5))
        let genesis = app.buttons["reference.book.Gen"]
        func genesisIsInTheClear() -> Bool {
            genesis.exists && genesis.frame.minY >= bookList.frame.maxY
        }
        var inTheClear = genesisIsInTheClear()
        for _ in 0..<8 where !inTheClear {
            app.swipeDown(velocity: .fast)
            inTheClear = genesisIsInTheClear()
        }
        XCTAssertTrue(inTheClear,
                      "Scrolling the book list did not bring Genesis up.")

        let book = app.buttons["reference.book.\(bookID)"]
        func bookIsInReach() -> Bool {
            book.exists && book.frame.minY >= bookList.frame.maxY && book.isHittable
        }
        var inReach = bookID == "Gen" || bookIsInReach()
        for _ in 0..<12 where !inReach {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(
                forDuration: 0.05, thenDragTo: end,
                withVelocity: .slow, thenHoldForDuration: 0.5
            )
            inReach = bookIsInReach()
        }
        XCTAssertTrue(inReach,
                      "Scrolling the book list did not bring \(bookName) into reach.")
        book.tap()
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
            app.navigationBars["\(bookName) \(chapter)"].waitForNonExistence(timeout: 5),
            "Choosing a verse did not close the reference picker."
        )
    }

    /// The reading toolbar's ••• button, where there is one.
    ///
    /// `ToolbarOverflowMenu` is system-provided, so its button carries the system's
    /// own identity rather than one we set: confirmed on the iOS 27 simulator as
    /// identifier `OverflowBarButtonItem` / label "More", and on iOS 27.2 as
    /// `TopOverflowBarButtonItem`. Matched by the identifier's suffix, which both
    /// share, since the label is localized.
    @MainActor
    var readingOverflowButton: XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH %@", "OverflowBarButtonItem")
        ).firstMatch
    }

    /// Scrolls the reader up by finger, each drag held still before the finger
    /// lifts so the reader moves the drag's own length and does not coast.
    @MainActor
    func dragTheReaderUp(times: Int) {
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

    /// Opens the reading toolbar's iOS 27 overflow menu.
    @MainActor
    func openReadingOverflowMenu() {
        let overflow = readingOverflowButton
        XCTAssertTrue(
            overflow.waitForExistence(timeout: 5),
            "Could not find the reading toolbar's overflow menu."
        )
        overflow.tap()
    }

    @MainActor
    func dismissMenu() {
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
    func selectWorkspace(_ label: String) {
        let tab = app.tabBars.buttons[label]
        XCTAssertTrue(
            tab.waitForExistence(timeout: 5),
            "Missing workspace \(label)"
        )
        tab.tap()
        XCTAssertTrue(tab.isSelected, "Workspace \(label) was not selected")
    }

    @MainActor
    func assertWorkspaceTabsVisible(
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
    func selectReadingMode(_ label: String) {
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
    func selectLibrarySection(_ label: String) {
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
}
