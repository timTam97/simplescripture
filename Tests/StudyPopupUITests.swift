import XCTest

/// Strong's links in the chapter, and the lexicon entries they open.
final class StudyPopupUITests: SimpleScriptureUITestCase {
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

    /// A Strong's number in a Psalm's TITLE opens its lexicon entry, as one in
    /// the verse under it does.
    ///
    /// A Psalm's title is a heading row, beside the verse text and not inside
    /// it, so the reader's link routing has to be on the heading in its own
    /// right (`routesChapterLinks(to:)`). Without it the title's markers are
    /// drawn like the verse's, and a tap on one goes to the system, which has
    /// nothing registered for `pslink://`. The unit test proves the title's text
    /// carries its links. That a tap on one reaches the pane is only here.
    /// MEASURED (iOS 27.2) with the routing taken off the heading row: the
    /// marker was found and tapped, and no popup opened.
    ///
    /// Psalms 3 is titled "A Psalm<04210> of David<01732>, when he fled…".
    /// The marker is looked for inside the title's own text, so it is the
    /// heading's link that is tapped. The header trait leaves it a link:
    /// MEASURED (iOS 27.2) it is a `Link` under the title's `StaticText`, and
    /// hittable.
    ///
    /// The chapter is picked, so the test starts from whatever book the app was
    /// left in, and it leaves the app in Psalms 3. Strong's numbers, Headings
    /// and the layout are launch arguments, which write nothing. Headings are
    /// on so the page is the fullest one: "PSALM 3." is a row above the title,
    /// and the pick of verse 1 lands on it with the title under it.
    @MainActor
    func testStrongsLinkInAPsalmTitleOpensItsLexiconEntry() throws {
        app.terminate()
        app.launchArguments += [
            "-strongsPreference_KJV", "YES",
            // Numbers, whatever a test before this one left the choice on.
            "-strongsUnderlinePreference_KJV", "NO",
            "-headingsPreference_KJV", "YES",
            "-vplPreference_KJV", "YES",
        ]
        app.launch()
        XCTAssertTrue(
            app.buttons["reading.reference-picker"].waitForExistence(timeout: 20),
            "SimpleScripture did not finish initialization."
        )
        selectChapter(3, ofBook: "Ps", named: "Psalms")

        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A Psalm")
        ).firstMatch
        XCTAssertTrue(
            title.waitForExistence(timeout: 10),
            "Psalms 3 shows no title of its own."
        )
        // H04210 (mizmor), the title's first Strong's number.
        let marker = title.links["pslink://strongs/Hebrew/04210"]
        XCTAssertTrue(
            marker.exists,
            "Psalms 3's title shows no H04210 marker with Strong's numbers on: "
                + "\"\(title.label)\""
        )
        XCTAssertTrue(
            marker.isHittable,
            "The title's H04210 marker is at \(marker.frame), where it cannot "
                + "be tapped."
        )
        marker.tap()

        let popup = app.descendants(matching: .any)["study.popup"]
        XCTAssertTrue(
            popup.firstMatch.waitForExistence(timeout: 10),
            "tapping a Strong's number in a Psalm title did not open the study popup"
        )
        // The entry the marker names: the popup's header gives its number.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "H4210")
            ).firstMatch.exists,
            "the study popup did not open on H4210"
        )
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

    /// In Underlined Words mode a tagged word is itself the link to its entry,
    /// and the numbers are not drawn.
    ///
    /// The link's identifier is its `pslink://strongsword/…` URL, with the
    /// numbers the chapter's markers carry for it: "In the beginning" is H07225.
    @MainActor
    func testUnderlinedWordOpensItsLexiconEntry() throws {
        openGenesis1WithStrongsNumbers(underlined: true)
        let word = app.links["pslink://strongsword/H07225"]
        XCTAssertTrue(
            word.waitForExistence(timeout: 10),
            "Genesis 1:1's \"In the beginning\" is not a link in Underlined Words"
        )
        XCTAssertEqual(word.label, "In the beginning")
        XCTAssertFalse(app.links["pslink://strongs/Hebrew/07225"].exists,
                       "Underlined Words drew the H07225 marker too")
        word.tap()

        let popup = app.descendants(matching: .any)["study.popup"]
        XCTAssertTrue(popup.firstMatch.waitForExistence(timeout: 10),
                      "tapping an underlined word did not open the study popup")
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "H7225")
            ).firstMatch.exists,
            "the study popup did not open on H7225"
        )
        XCTAssertFalse(app.descendants(matching: .any)["study.numbers"].exists,
                       "a word with one number offered a choice of numbers")
    }

    /// A word with several numbers offers each, opening on the last: Genesis
    /// 1:1's "created" is H853 (the object marker) and H1254, in the order its
    /// markers stand, and the particle's comes first.
    @MainActor
    func testAWordWithSeveralNumbersOffersEach() throws {
        openGenesis1WithStrongsNumbers(underlined: true)
        let word = app.links["pslink://strongsword/H0853/H01254"]
        XCTAssertTrue(
            word.waitForExistence(timeout: 10),
            "Genesis 1:1's \"created\" is not one link to H0853 and H01254"
        )
        word.tap()

        let popup = app.descendants(matching: .any)["study.popup"]
        XCTAssertTrue(popup.firstMatch.waitForExistence(timeout: 10),
                      "tapping an underlined word did not open the study popup")
        let first = app.buttons["H853"]
        let last = app.buttons["H1254"]
        XCTAssertTrue(last.waitForExistence(timeout: 5),
                      "the popup offers no H1254 segment")
        XCTAssertTrue(first.exists, "the popup offers no H853 segment")
        XCTAssertTrue(last.isSelected, "the popup did not open on the last number")
        XCTAssertFalse(first.isSelected)

        first.tap()
        XCTAssertTrue(
            first.wait(for: \.isSelected, toEqual: true, timeout: 5),
            "choosing H853 did not select it"
        )
        XCTAssertTrue(popup.firstMatch.exists, "choosing a number closed the popup")
    }

    // MARK: - Helpers

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
    ///
    /// `underlined` picks Underlined Words over the numbers, by argument too,
    /// and either way: a run that left the choice on Underlined Words must not
    /// take the markers away from the tests that tap them.
    @MainActor
    private func openGenesis1WithStrongsNumbers(underlined: Bool = false) {
        app.terminate()
        app.launchArguments += [
            "-strongsPreference_KJV", "YES",
            "-strongsUnderlinePreference_KJV", underlined ? "YES" : "NO",
            "-lastRef", "Genesis 1",
            "-bibleScrollPosition", "0",
            "-bibleVersePosition", "1",
        ]
        app.launch()
        // A launch always starts in the Read workspace, in the Bible.
    }
}
