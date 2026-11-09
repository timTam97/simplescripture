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

        let chapterResolvesAsGiven = reference.hadExplicitChapter
            && resolver.resolve(ref: chapter) != nil
        let chapterToShow = chapterResolvesAsGiven ? chapter : reference.chapterRef
        let persistedChapterRef = PSRefHelper.createRefString(chapterToShow)
        let versePosition = Int(firstNumericPrefix(in: verseRaw)).map(String.init) ?? "1"
        let type = queryValue(named: "type", in: url)

        let destination: URLRoute.Destination
        if let requestedModule = module, !requestedModule.isEmpty {
            if let moduleType = moduleTypeProvider(requestedModule) {
                destination = moduleType == PSRefLinkRouter.typeBible
                    ? .bible(module: requestedModule)
                    : .commentary(module: requestedModule)
            } else {
                destination = type == nil || type == "bible"
                    ? .bible(module: nil)
                    : .commentary(module: nil)
            }
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

    private func firstNumericPrefix(in value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else {
            return ""
        }

        var end = 1
        while end < scalars.count,
              CharacterSet.decimalDigits.contains(scalars[end]) {
            end += 1
        }
        return String(String.UnicodeScalarView(scalars[0..<end]))
    }
}
