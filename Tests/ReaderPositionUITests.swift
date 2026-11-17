import XCTest

/// Where the reader rests: after a pick in the reference picker, a drag, a
/// rotation, and a relaunch.
final class ReaderPositionUITests: SimpleScriptureUITestCase {
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

    /// A position restored at launch keeps its side gutter when the app is left
    /// and come back to, launch after launch.
    ///
    /// The restore hands SwiftUI a scroll offset. Left in the scroll position
    /// after the scroll view had gone to it, the offset was applied again
    /// whenever the content size changed, and as a RAW content offset: the
    /// chapter one top inset further on and flush against the left screen edge.
    /// The reader saved that as its position, so the next launch started from it
    /// and moved on again. The lazy rows are re-measured when the app goes to
    /// the background, and on the first accessibility read of the reader — which
    /// any query here is. So nothing is asked of the app between a launch and
    /// leaving it, and the look that follows is the first. MEASURED (iOS 27.2,
    /// iPhone 18 Pro) without the fix: verse 16's number at x 0 after the first
    /// relaunch and verse 17's after the second, where the gutter puts a verse
    /// number at x 16.
    ///
    /// Judged by the gutter. The raw offset moves the text sideways and down
    /// together, so a verse number standing at the gutter is a reader that was
    /// not moved by it. WHICH verse the restore lands on is not asserted, beyond
    /// its being one deep in the chapter: under XCUITest about one launch in
    /// seven issues the restore before the scroll view's first layout and lands
    /// some two verses further on (MEASURED: 2 of 14 launches, one with the fix
    /// and one without). That is another defect, and it would fail this test
    /// for the wrong reason.
    @MainActor
    func testARestoredPositionKeepsItsGutterWhenTheAppIsLeft() throws {
        relaunchWithMarkersOff(
            app.launchArguments, versePerLine: true, headings: false
        )
        selectGenesisChapter(1, verse: 14)
        XCTAssertTrue(app.links["pslink://versemenu/14"].waitForExistence(timeout: 5))
        let picked = try XCTUnwrap(
            try verseAtTheTopOfTheReader(),
            "The reader shows no verse number after picking Genesis 1:14."
        )
        XCTAssertEqual(
            picked.verse, 14,
            "Picking Genesis 1:14 did not put it at the top of the reader, so "
                + "there is no position deep in the chapter to restore."
        )
        XCTAssertGreaterThan(
            picked.origin.x, 8,
            "Verse numbers stand at the screen edge before anything is "
                + "restored, so there is no gutter to lose."
        )

        // Twice: the moved position was saved, and the second launch began there.
        for launch in 1...2 {
            app.terminate()
            app.launch()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 20),
                "SimpleScripture did not reach the foreground."
            )
            // Time for the restore to land, with nothing asked of the app.
            Thread.sleep(forTimeInterval: 3)
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 3)
            app.activate()
            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 20),
                "SimpleScripture did not come back to the foreground."
            )

            let restored = try XCTUnwrap(
                try verseAtTheTopOfTheReader(),
                "The reader shows no verse number after relaunch \(launch)."
            )
            XCTAssertGreaterThan(
                restored.verse, 5,
                "Relaunch \(launch) opened at the top of the chapter, so no "
                    + "position was restored and nothing here was tested."
            )
            XCTAssertEqual(
                restored.origin.x, picked.origin.x, accuracy: 1,
                "After relaunch \(launch) and a trip to the Home Screen, verse "
                    + "\(restored.verse)'s number is at x \(restored.origin.x) "
                    + "where the gutter put verse 14's at \(picked.origin.x): "
                    + "the restored offset was applied again as a raw content "
                    + "offset."
            )
        }
    }

    // MARK: - Helpers

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
}
