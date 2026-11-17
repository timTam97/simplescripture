import XCTest

/// The Library's sections, dictionary and bookmark folders, and Settings with
/// its About pages.
final class LibraryAndSettingsUITests: SimpleScriptureUITestCase {
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

    /// A dictionary entry left open in the Library follows a font size changed
    /// in Settings.
    ///
    /// The Library is a persistent workspace, so the entry is still up when the
    /// reader comes back from Settings. Whether it is redrawn in the new size is
    /// SwiftUI's invalidation, which no unit test can see.
    ///
    /// The entry follows because its body reads the font settings
    /// (`Style.current(observing:)`); coming back to the tab rebuilds nothing.
    /// MEASURED (iOS 27.2): with that read in place the line goes from 16 pt
    /// tall to 41. With the style read from `UserDefaults` instead, it was 16 pt
    /// at size 10 and still 16 pt at 36, and this failed.
    ///
    /// Judged by the height of a line of the entry that fits on one line at
    /// either size. From the bottom of the slider, where an entry is drawn at its
    /// 14 pt floor, to the top, 36 pt.
    ///
    /// No `-fontSizePreference` argument: it would shadow every size this run
    /// sets, and the entry could not change. The size is therefore saved, and
    /// put back in a teardown block, which runs when the test fails as well.
    /// Picking the lexicon is saved too (`lastDictionary`), and stays: it is
    /// where the Library's dictionary next opens, as the chapter is for the
    /// reader.
    @MainActor
    func testOpenDictionaryEntryFollowsAFontSizeChange() throws {
        selectWorkspace("Settings")
        let slider = app.sliders["settings.font-size"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let savedSize = try XCTUnwrap(
            (slider.value as? String).flatMap { Int($0) },
            "The font size slider does not say what size it is on."
        )
        addTeardownBlock { @MainActor [self] in
            self.selectWorkspace("Settings")
            self.setFontSize(savedSize)
        }
        setFontSize(10)

        selectWorkspace("Library")
        selectLibrarySection("Dictionary")
        let moduleMenu = app.buttons["dictionary.module-menu"]
        XCTAssertTrue(moduleMenu.waitForExistence(timeout: 5))
        moduleMenu.tap()
        let hebrew = app.buttons["Strong's Hebrew"].firstMatch
        XCTAssertTrue(hebrew.waitForExistence(timeout: 5))
        hebrew.tap()
        let key = app.buttons["dictionary.key.00001"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap()
        let entryBar = app.navigationBars["00001"]
        XCTAssertTrue(entryBar.waitForExistence(timeout: 5))
        // H1, "ab": "A primitive word; father…". The first clause is a line of
        // its own in the entry.
        let line = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "primitive word")
        ).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let smallHeight = line.frame.height

        selectWorkspace("Settings")
        setFontSize(36)
        selectWorkspace("Library")
        XCTAssertTrue(
            entryBar.waitForExistence(timeout: 5),
            "The entry did not stay open across a visit to Settings."
        )
        let grew = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                line.exists && line.frame.height > smallHeight * 1.5
            },
            object: nil
        )
        let outcome = XCTWaiter().wait(for: [grew], timeout: 5)
        let height = line.exists ? "\(line.frame.height)" : "nothing"
        XCTAssertEqual(
            outcome, .completed,
            "The open entry's line was \(smallHeight) pt tall with the font size "
                + "at 10 and is \(height) pt tall after it was set to 36."
        )
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

    /// Moves the font-size slider in Settings to `size`, and checks it got there.
    ///
    /// `adjust(toNormalizedSliderPosition:)` drags the thumb, and where a drag
    /// lands depends on where it starts. MEASURED (iOS 27.2, iPhone 18 Pro, on
    /// the slider's 10...36): from where the thumb rests, a drag of one step
    /// does not move it (from 19, aimed at 18 or 20: 19), and a drag of two or
    /// more overshoots by two or three (from 23, aimed at 20: 17). Corrected
    /// from wherever it landed, as this used to be, the slider circled a size
    /// without reaching it: six aims between 0.38 and 0.42 left it on 18, not
    /// 20, and the teardown of `testOpenDictionaryEntryFollowsAFontSizeChange`
    /// failed. From an end a drag lands the same way every time, a step or so
    /// past its aim (from 36, aimed at 20: 19, seven times in seven), and the
    /// ends themselves are reached at the first attempt.
    ///
    /// So every drag starts from the end further from `size`, which also keeps
    /// it long. A miss moves the aim by what it missed by, and once one aim
    /// has fallen short and another gone over, the next is halfway between
    /// them: from 36, 18 landed 17 and 19 landed 19, and 18.5 landed 18.
    /// MEASURED: 32 sizes in 32 across the range reached, in three drags at
    /// most.
    @MainActor
    private func setFontSize(_ size: Int) {
        let slider = app.sliders["settings.font-size"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        func reading() -> Int? {
            (slider.value as? String).flatMap { Int($0) }
        }
        let start: CGFloat = size - 10 < 36 - size ? 1 : 0
        var aim = Double(size)
        var short: Double?
        var over: Double?
        for _ in 0..<6 where reading() != size {
            slider.adjust(toNormalizedSliderPosition: start)
            if reading() == size { break }
            slider.adjust(toNormalizedSliderPosition: CGFloat((aim - 10) / 26))
            guard let landed = reading() else { break }
            if landed < size { short = max(short ?? aim, aim) }
            if landed > size { over = min(over ?? aim, aim) }
            if let short, let over {
                aim = (short + over) / 2
            } else if landed != size {
                aim = min(max(aim + Double(size - landed), 10), 36)
            }
        }
        XCTAssertEqual(reading(), size,
                       "The font size slider could not be put on \(size).")
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
