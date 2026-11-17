import XCTest

/// Turning the reader's page, by chevron and by swipe, in both verse layouts.
final class ChapterPagingUITests: SimpleScriptureUITestCase {
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

    // MARK: - Helpers

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
}
