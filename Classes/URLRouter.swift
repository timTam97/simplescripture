import Foundation

struct URLRoute: Equatable {
    enum Destination: Equatable {
        case bible(module: String?)
        case commentary(module: String?)
    }

    let sourceURL: URL
    let destination: Destination
    let reference: BibleReference
    let persistedChapterRef: String
    let versePosition: String
}

struct URLRouter {
    typealias ModuleTypeProvider = (String) -> String?

    private let parser: PSRefParser
    private let resolver: PSBookOSISResolver
    private let moduleTypeProvider: ModuleTypeProvider
    private let externalScheme: String

    private static var registeredScriptureScheme: String {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
            as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "sword"
    }

    init?(
        parser: PSRefParser? = PSRefParser(),
        resolver: PSBookOSISResolver? = PSBookOSISResolver.shared,
        externalScheme: String = URLRouter.registeredScriptureScheme,
        moduleTypeProvider: @escaping ModuleTypeProvider = {
            PSContentStore.shared?.moduleMeta($0, key: "type")
        }
    ) {
        guard let parser, let resolver else {
            return nil
        }
        self.parser = parser
        self.resolver = resolver
        self.externalScheme = externalScheme
        self.moduleTypeProvider = moduleTypeProvider
    }

    func route(for url: URL?) -> URLRoute? {
        // Bundled study texts keep using sword:// internally, while the
        // development app registers sword-dev:// for links opened by iOS.
        guard let url, url.scheme == "sword" || url.scheme == externalScheme else {
            return nil
        }

        let module = url.host
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        let rawReference = decodedPath
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "+", with: " ")

        let parts = rawReference.components(separatedBy: ":")
        let hadVerseSpec = parts.count > 1
        let chapter = parts[0]
        let verseRaw = hadVerseSpec ? parts[1] : "1"

        guard let reference = parser.parse(chapter) else {
            alog("sword:// URL carries an unresolvable reference, ignoring: \(rawReference)")
            return nil
        }

        // The link's own spelling is kept when the reader can resolve it ("Jn 3"
        // stays "Jn 3"); anything else is stored as the parser's canonical ref.
        //
        // The munge comes BEFORE that test, because the munged string is the one
        // stored and the munge can break a ref that resolved without it: the
        // book lookup ignores case, `createRefString` does not, and it turns
        // "MALACHI 3" into "MALACH1 3". Tested as given, that was persisted, and
        // the reader came up blank (a trap in Debug) at every launch until some
        // other navigation replaced it. `chapterRef` is the `name` form, which
        // the munge leaves alone.
        let mungedChapter = PSRefHelper.createRefString(chapter)
        let chapterResolvesAsGiven = reference.hadExplicitChapter
            && resolver.resolve(ref: mungedChapter) != nil
        let persistedChapterRef = chapterResolvesAsGiven
            ? mungedChapter
            : reference.chapterRef
        // The parser only saw the chapter, so this is the one place the verse is
        // made into something the reader can scroll to: a number, and at least
        // 1. A "0" written to the verse-position key is a restore the reader
        // ignores, leaving the new chapter wherever the last one was scrolled to
        // under a title reading "John 3:0". A verse past the end of the chapter
        // is left alone: the reader falls back to the nearest row before it.
        let versePosition = firstVerseNumber(in: verseRaw)
            .map { String(max(1, $0)) } ?? "1"
        let type = queryValue(named: "type", in: url)

        // The host names the module to open the reference in — if it is one a
        // chapter can be read in. A lexicon is a bundled module too, but it has
        // no chapters: taken for a commentary, as every module that was not a
        // Bible used to be, `sword://StrongsRealGreek/John+3:16` made the lexicon
        // the primary commentary and persisted it. Every chapter then read as
        // empty, across relaunches, and there is no module picker to put MHCC
        // back with. So a host of any other kind is ignored, exactly like one
        // that is not installed, and the reference still opens.
        let destination: URLRoute.Destination
        if let requestedModule = module, !requestedModule.isEmpty,
           let moduleType = moduleTypeProvider(requestedModule),
           moduleType == PSRefLinkRouter.typeBible
            || moduleType == PSRefLinkRouter.typeCommentary {
            destination = moduleType == PSRefLinkRouter.typeBible
                ? .bible(module: requestedModule)
                : .commentary(module: requestedModule)
        } else {
            destination = type == nil || type == "bible"
                ? .bible(module: nil)
                : .commentary(module: nil)
        }

        return URLRoute(
            sourceURL: url,
            destination: destination,
            reference: reference,
            persistedChapterRef: persistedChapterRef,
            versePosition: versePosition
        )
    }

    private func queryValue(named name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .last(where: { $0.name == name })?
            .value
    }

    /// The leading ASCII digits of the verse part ("28-30" -> 28, "1." -> 1,
    /// " 16" -> 16), or nil when it does not start with one ("-5", "abc", "").
    ///
    /// The first character is tested like the rest: taken on trust, it let a
    /// sign through, and "-5" came out as verse -5. `Int32` because that is the
    /// width the reader formats a verse position through (`persistPosition`), and
    /// the conversion there traps on anything wider — so a number that does not
    /// fit is no verse here.
    private func firstVerseNumber(in value: String) -> Int32? {
        Int32(value.trimmingCharacters(in: .whitespaces)
            .prefix { $0.isASCII && $0.isNumber })
    }
}
