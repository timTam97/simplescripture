import XCTest
@testable import SimpleScripture

final class URLRouterTests: XCTestCase {
    private func router() throws -> URLRouter {
        try XCTUnwrap(URLRouter())
    }

    func testInstalledModulesDetermineTheReadingMode() throws {
        let router = try router()

        let bible = try XCTUnwrap(router.route(
            for: URL(string: "sword://KJV/John+3:16")
        ))
        XCTAssertEqual(bible.destination, .bible(module: "KJV"))
        XCTAssertEqual(bible.persistedChapterRef, "John 3")
        XCTAssertEqual(bible.versePosition, "16")

        let commentary = try XCTUnwrap(router.route(
            for: URL(string: "sword://MHCC/John+3:16")
        ))
        XCTAssertEqual(commentary.destination, .commentary(module: "MHCC"))
        XCTAssertEqual(commentary.persistedChapterRef, "John 3")
        XCTAssertEqual(commentary.versePosition, "16")
    }

    func testForeignModuleFallsBackToQueryTypeAndCanonicalReference() throws {
        let router = try router()
        let route = try XCTUnwrap(router.route(
            for: URL(string: "sword://ESV/Gen.+1:28-30?type=commentary")
        ))

        XCTAssertEqual(route.destination, .commentary(module: nil))
        XCTAssertEqual(route.persistedChapterRef, "Genesis 1")
        XCTAssertEqual(route.versePosition, "28")
        XCTAssertEqual(route.reference.chapterRef, "Genesis 1")
    }

    func testChapterlessReferenceDefaultsToChapterAndVerseOne() throws {
        let router = try router()
        let route = try XCTUnwrap(router.route(for: URL(string: "sword:///John")))

        XCTAssertEqual(route.destination, .bible(module: nil))
        XCTAssertEqual(route.persistedChapterRef, "John 1")
        XCTAssertEqual(route.versePosition, "1")
    }

    func testOutOfRangeVerseStillRoutesToAValidChapter() throws {
        let router = try router()
        let route = try XCTUnwrap(router.route(
            for: URL(string: "sword://KJV/John+3:99")
        ))

        XCTAssertEqual(route.persistedChapterRef, "John 3")
        XCTAssertEqual(route.versePosition, "99")
    }

    func testInvalidURLsAreRejected() throws {
        let router = try router()

        XCTAssertNil(router.route(for: nil))
        XCTAssertNil(router.route(for: URL(string: "https://example.com/John+3:16")))
        XCTAssertNil(router.route(for: URL(string: "sword://KJV/Nonsense+9:9")))
    }

    func testDevelopmentLinksPreserveRoutingAndBundledLinks() throws {
        let development = try XCTUnwrap(URLRouter(externalScheme: "sword-dev"))
        let developmentURL = try XCTUnwrap(URL(string: "sword-dev://KJV/John+3:16"))
        let external = try XCTUnwrap(development.route(for: developmentURL))
        let bundled = try XCTUnwrap(development.route(
            for: URL(string: "sword://KJV/John+3:16")
        ))

        XCTAssertEqual(external.sourceURL, developmentURL)
        XCTAssertEqual(external.destination, bundled.destination)
        XCTAssertEqual(external.reference, bundled.reference)
        XCTAssertEqual(external.persistedChapterRef, bundled.persistedChapterRef)
        XCTAssertEqual(external.versePosition, bundled.versePosition)

        let production = try XCTUnwrap(URLRouter(externalScheme: "sword"))
        XCTAssertNil(production.route(for: developmentURL))
        XCTAssertNil(development.route(for: URL(string: "https://KJV/John+3:16")))
    }

    @MainActor
    func testAppSessionMirrorsAcceptedRoute() throws {
        let route = try XCTUnwrap(try router().route(
            for: URL(string: "sword://MHCC/Psalms+23:4")
        ))
        let session = AppSession(selectedWorkspace: .settings)

        session.apply(route)

        XCTAssertEqual(session.selectedWorkspace, .read)
        XCTAssertEqual(session.lastOpenedURL, route.sourceURL)
        XCTAssertEqual(session.reading.mode, .commentary)
        XCTAssertEqual(session.reading.reference?.chapterRef, "Psalms 23")
        XCTAssertEqual(session.reading.bibleVerse, 4)
        XCTAssertEqual(session.reading.commentaryVerse, 4)
        XCTAssertEqual(session.reading.commentaryModule, "MHCC")
    }

    /// Leaving the Search workspace dismisses the keyboard — only leaving it, and
    /// BEFORE the selection moves.
    ///
    /// The order is the point (see `AppSession.selectedWorkspace`): dismissed
    /// after the change, the workspace being shown is still laid out against the
    /// keyboard. So the closure records the selection it ran under.
    @MainActor
    func testLeavingSearchDismissesTheKeyboardBeforeTheSelectionMoves() throws {
        var dismissedUnder: [Workspace] = []
        var session: AppSession!
        session = AppSession(
            selectedWorkspace: .read,
            dismissKeyboard: { dismissedUnder.append(session.selectedWorkspace) }
        )

        // Not between other workspaces, and not on the way INTO Search.
        session.selectedWorkspace = .library
        session.selectedWorkspace = .settings
        session.selectedWorkspace = .search
        XCTAssertEqual(dismissedUnder, [])

        // Reselecting Search focuses the field; it must not put it away again.
        let focusRequests = session.searchFocusRequest
        session.selectedWorkspace = .search
        XCTAssertEqual(session.searchFocusRequest, focusRequests + 1)
        XCTAssertEqual(dismissedUnder, [])

        // Leaving by the tab bar: once, while Search is still the selection.
        session.selectedWorkspace = .library
        XCTAssertEqual(dismissedUnder, [.search])
        XCTAssertEqual(session.selectedWorkspace, .library)

        // Leaving by a route — how a search result opens — takes the same path.
        session.selectedWorkspace = .search
        let route = try XCTUnwrap(try router().route(
            for: URL(string: "sword://Bible/Genesis+5:29")
        ))
        session.apply(route)
        XCTAssertEqual(dismissedUnder, [.search, .search])
        XCTAssertEqual(session.selectedWorkspace, .read)
    }

    /// What a `sword://` URL persists to `lastRef` has to be a ref the reader can
    /// resolve, however the link spelled and cased the book.
    ///
    /// The book lookup ignores case; `createRefString` does not. It turns "I "
    /// into "1 " wherever it finds one, so a link written in capitals passed the
    /// resolvability check as "MALACHI 3" and was then stored as "MALACH1 3",
    /// which nothing resolves: a blank reader (a trap in Debug) at that launch and
    /// every later one, until some other navigation overwrote the ref. Seven
    /// spellings end that way — MALACHI, HAGGAI, PHI and the USFM codes 1KI, 2KI,
    /// 1TI, 2TI.
    func testEverySpellingInEveryCasingPersistsARefTheReaderResolves() throws {
        let router = try router()
        let resolver = try XCTUnwrap(PSBookOSISResolver.shared)

        // Built the way `openLibraryReference` builds one.
        func routing(_ reference: String) -> URLRoute? {
            var components = URLComponents()
            components.scheme = "sword"
            components.host = "Bible"
            components.path = "/" + reference
            return router.route(for: components.url)
        }

        let onceCorrupted: [(reference: String, persisted: String)] = [
            ("MALACHI 3:10", "Malachi 3"),
            ("HAGGAI 2:4", "Haggai 2"),
            ("1KI 3", "1 Kings 3"),
            ("2KI 3", "2 Kings 3"),
            ("1TI 1", "1 Timothy 1"),
            ("2TI 1", "2 Timothy 1"),
            ("PHI 2", "Philippians 2"),
        ]
        for (reference, persisted) in onceCorrupted {
            XCTAssertEqual(routing(reference)?.persistedChapterRef, persisted,
                           "sword://Bible/\(reference)")
        }

        var checked = 0
        func check(_ reference: String) {
            guard let route = routing(reference) else {
                XCTFail("'\(reference)' did not route")
                return
            }
            let persisted = route.persistedChapterRef
            // Against the route's own book, not the loop's: "Jud" and "Phi" are
            // intentional collisions (Judges, Philippians).
            let resolved = resolver.resolve(ref: persisted)
            XCTAssertEqual(resolved?.book.osisName, route.reference.book.osisName,
                           "'\(reference)' persists '\(persisted)'")
            XCTAssertEqual(resolved?.chapter, route.reference.chapter,
                           "'\(reference)' persists '\(persisted)'")
            // `ReaderPaneModel.render` puts `lastRef` through `createRefString`
            // again on every render, so what is stored must already be what that
            // produces.
            XCTAssertEqual(PSRefHelper.createRefString(persisted), persisted,
                           "'\(reference)' persists a ref the next render rewrites")
            checked += 1
        }
        for book in resolver.books {
            let spellings = [book.name, book.longName, book.localisedName, book.osisName,
                             book.shortName, book.preferredAbbreviation, book.abbreviation]
            for spelling in spellings where !spelling.isEmpty {
                for cased in [spelling, spelling.uppercased(), spelling.lowercased()] {
                    check("\(cased) \(book.chapterCount):1")
                }
            }
            // A bare book has no chapter to keep, so it takes the canonical ref —
            // which is stored as it is, without the munge.
            check(book.name)
        }
        XCTAssertGreaterThan(checked, 1000)

        // Otherwise the link's own spelling is kept, deliberately: only a ref the
        // reader cannot resolve is replaced by the canonical one.
        XCTAssertEqual(routing("Jn 3:16")?.persistedChapterRef, "Jn 3")
        XCTAssertEqual(routing("I Samuel 3")?.persistedChapterRef, "1 Samuel 3")
    }
}
