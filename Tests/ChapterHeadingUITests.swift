import XCTest

/// What the top of a chapter shows with Headings off and on, in both verse
/// layouts.
final class ChapterHeadingUITests: SimpleScriptureUITestCase {
    /// With Headings off, a chapter starts at verse 1: no row above it, and
    /// nothing in front of its number.
    ///
    /// All but five of the KJV's chapters open with a title, and with Headings
    /// off — a fresh install — what is left of the title's slot is one space.
    /// Given a row, that space was a blank line above verse 1 with a row per
    /// verse, and a space in front of verse 1's number in flowing prose. The
    /// unit test proves the document has no such row; what the reader draws at
    /// the top of a chapter is only here.
    ///
    /// The two layouts do not fail alike. MEASURED (iOS 27.2) with the document
    /// keeping the row: flowing prose failed, verse 1's number at x 20.3 where
    /// its text starts at 16. A row per verse still passed, because the row
    /// view lays out no text for an intro with nothing to show; with that taken
    /// out as well it failed, the chapter opening with " ".
    ///
    /// The first text under the identifier both panes carry is the first thing
    /// the chapter draws: the pane that is not showing is hidden from
    /// accessibility and has none.
    @MainActor
    func testChapterOpensOnVerseOneWithHeadingsOff() throws {
        let arguments = app.launchArguments
        for versePerLine in [true, false] {
            let layout = versePerLine ? "a row per verse" : "flowing prose"
            openGenesis1ByPaging(
                arguments, versePerLine: versePerLine, headings: false
            )

            let readingAreaTop = app.navigationBars.firstMatch.frame.maxY
            let firstText = app.scrollViews
                .matching(identifier: "reading.chapter-content")
                .staticTexts.firstMatch
            XCTAssertTrue(firstText.waitForExistence(timeout: 5))
            let verse1 = firstText.links["pslink://versemenu/1"]
            XCTAssertTrue(
                verse1.exists,
                "With \(layout), Genesis 1 opens with \"\(firstText.label.prefix(30))\" "
                    + "(\(firstText.frame)), which is not verse 1."
            )
            XCTAssertEqual(
                verse1.frame.minY, readingAreaTop, accuracy: 1,
                "With \(layout), verse 1 is not at the top of the reading area."
            )
            XCTAssertEqual(
                verse1.frame.minX, firstText.frame.minX, accuracy: 1,
                "With \(layout), something is drawn in front of verse 1's number."
            )
        }
    }

    /// With Headings on, the chapter's title is a heading of its own above
    /// verse 1.
    ///
    /// Every KJV title is in the slot before verse 1. Left in that slot's text,
    /// it ran into verse 1 in flowing prose: "CHAPTER 1.", the number 1 and "In
    /// the beginning" on one line of one paragraph. It is lifted into a heading
    /// now, which leaves the slot with no text of its own, and an empty `Text`
    /// still takes a line, so neither layout lays one out under the heading. The
    /// unit test proves where the document puts the title. Whether a row is
    /// drawn for text that is not there is only here.
    ///
    /// Each layout pins one half. MEASURED (iOS 27.2) with the title left in the
    /// slot's text: flowing prose failed, with no title of its own. A row per
    /// verse still passed, because there the slot is a row by itself, and its
    /// text read "CHAPTER 1." alone. With the title lifted and the empty text
    /// laid out all the same, a row per verse failed: verse 1 started 25.7 pt
    /// below the title.
    @MainActor
    func testChapterTitleIsAHeadingOfItsOwnWithHeadingsOn() throws {
        let arguments = app.launchArguments
        for versePerLine in [true, false] {
            let layout = versePerLine ? "a row per verse" : "flowing prose"
            openGenesis1ByPaging(
                arguments, versePerLine: versePerLine, headings: true
            )

            let readingAreaTop = app.navigationBars.firstMatch.frame.maxY
            let title = app.staticTexts["CHAPTER 1."]
            XCTAssertTrue(
                title.waitForExistence(timeout: 5),
                "With \(layout), Genesis 1 has no title of its own."
            )
            XCTAssertGreaterThanOrEqual(
                title.frame.minY, readingAreaTop - 1,
                "With \(layout), the title is behind the navigation bar."
            )
            let verseText = app.staticTexts.containing(
                .link, identifier: "pslink://versemenu/1"
            ).firstMatch
            XCTAssertTrue(verseText.exists)
            XCTAssertFalse(
                verseText.label.contains("CHAPTER"),
                "With \(layout), the title is still part of verse 1's text."
            )
            // The heading's own padding and no more. A row for the slot's missing
            // text would be a blank line here.
            let gap = verseText.frame.minY - title.frame.maxY
            XCTAssertTrue(
                (0..<15).contains(gap),
                "With \(layout), verse 1 starts \(gap) pt below the title."
            )
        }
    }

    /// With Headings on, a chapter picked at verse 1 opens on its title.
    ///
    /// The title is a row of its own above verse 1 with a row per verse, and
    /// the head of verse 1's paragraph in flowing prose. A scroll to verse 1 used
    /// to go to verse 1's own row, which with a row per verse left the title
    /// above the reading area, behind the navigation bar. MEASURED (iOS 27.2,
    /// 20 pt): after the reference picker, "CHAPTER 1." at y 87 to 110 with the
    /// bar's bottom edge at 116; after a page turn, at y 130. Turning Headings
    /// on at the top of a chapter changed nothing on screen. Verse 1 now lands
    /// on the title's row (`ReaderPaneModel.rowID(containing:)`). The unit test
    /// proves which row the model asks for; where the scroll view comes to rest
    /// is only here.
    ///
    /// Both of the picker's paths: from another chapter, which loads this one,
    /// and from further down the chapter already open, which only scrolls.
    ///
    /// Flowing prose showed Genesis 1's title before as well, so that layout is
    /// here to stay right, not to prove the change. Where flowing prose lost a
    /// title is a psalm with a title of its own on verse 1, which leaves
    /// `PSALM n.` a paragraph by itself; that is pinned in the unit test.
    @MainActor
    func testPickingVerseOneShowsTheChapterTitleWithHeadingsOn() throws {
        let arguments = app.launchArguments
        for versePerLine in [true, false] {
            let layout = versePerLine ? "a row per verse" : "flowing prose"
            relaunchWithMarkersOff(
                arguments, versePerLine: versePerLine, headings: true
            )
            let title = app.staticTexts["CHAPTER 1."]

            // The title is the first thing in the reading area: below the bar's
            // bottom edge, and by no more than the heading's own padding.
            func assertTheTitleOpensTheReadingArea(after arrival: String) {
                let readingAreaTop = app.navigationBars.firstMatch.frame.maxY
                let rested = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        title.exists
                            && title.frame.minY >= readingAreaTop - 1
                            && title.frame.minY <= readingAreaTop + 20
                    },
                    object: nil
                )
                let outcome = XCTWaiter().wait(for: [rested], timeout: 5)
                let rest = title.exists
                    ? "is at y \(title.frame.minY) to \(title.frame.maxY)"
                    : "is not in the hierarchy"
                XCTAssertEqual(
                    outcome, .completed,
                    "With \(layout), after \(arrival), the title \(rest); the "
                        + "reading area starts at y \(readingAreaTop)."
                )
            }

            selectGenesisChapter(2)
            XCTAssertTrue(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@",
                                "Thus the heavens and the earth")
                ).firstMatch.waitForExistence(timeout: 5),
                "The reference picker did not open Genesis 2."
            )
            selectGenesisChapter(1)
            assertTheTitleOpensTheReadingArea(
                after: "picking Genesis 1:1 from Genesis 2"
            )

            dragTheReaderUp(times: 2)
            let readingAreaTop = app.navigationBars.firstMatch.frame.maxY
            let scrolledAway = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    !title.exists || title.frame.maxY < readingAreaTop
                },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [scrolledAway], timeout: 5), .completed,
                "With \(layout), the drags did not take the title out of the "
                    + "reading area, so there is nothing for the pick to bring back."
            )
            selectGenesisChapter(1)
            assertTheTitleOpensTheReadingArea(
                after: "picking Genesis 1:1 from further down Genesis 1"
            )
        }
    }

    // MARK: - Helpers

    /// Relaunches with the KJV's markers off, in the given layout, and comes to
    /// Genesis 1 by paging back from Genesis 2.
    ///
    /// By a page turn because that arrival does not depend on where a scroll to
    /// a verse lands: the chapter opens on a new scroll view, at its very top.
    /// The arrival that is a scroll to verse 1 has a test of its own,
    /// `testPickingVerseOneShowsTheChapterTitleWithHeadingsOn`.
    @MainActor
    private func openGenesis1ByPaging(
        _ arguments: [String], versePerLine: Bool, headings: Bool
    ) {
        relaunchWithMarkersOff(
            arguments, versePerLine: versePerLine, headings: headings
        )
        selectGenesisChapter(2)
        let genesis2 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Thus the heavens and the earth")
        ).firstMatch
        XCTAssertTrue(genesis2.waitForExistence(timeout: 5))
        app.buttons["reading.previous-chapter"].tap()
        let genesis1 = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "In the beginning God created")
        ).firstMatch
        XCTAssertTrue(
            genesis1.waitForExistence(timeout: 5),
            "Paging back from Genesis 2 did not show Genesis 1."
        )
        // The chapter being left stays up until its slide has finished.
        XCTAssertTrue(
            genesis2.waitForNonExistence(timeout: 5),
            "Genesis 2 is still showing after paging back to Genesis 1."
        )
    }
}
