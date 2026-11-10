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
}
