//
//  PSContentReader.swift
//  PocketSword
//
//  The coordinating layer over the content reader: the single thing the UI
//  talks to. Composes PSContentStore (rows) + PSBookOSISResolver (name -> OSIS)
//  + PSChapterExpander (tokens -> HTML) + PSChapterAssembler (the accumulator
//  loop), and adds module selection, the per-module option prefs and the
//  bookmark-highlight lookup.
//
//  === FAILURE POLICY ===
//
//  FATAL — the store itself is unusable, so the app cannot do its job. These
//  call `PSContentStore.fatal`, which traps: a crash report naming the broken
//  invariant beats a permanently blank app. All are build-integrity failures
//  (bundled resources, validated by PSContentStoreTests):
//
//    1. Resources/PSContent.sqlite absent from the bundle, or unopenable.
//    2. content_meta schemaVersion != 2 or tokenGrammar != "v2".
//    3. content_meta missing the chunkRows.* sizes.
//    4. Resources/Versification-KJV.json absent, unparseable, or not 66 books.
//
//  LOUD-AND-NIL — one datum is bad; the rest of the store is fine. These report
//  through `PSContentStore.fail` (assertionFailure in debug, alog in release)
//  and return nil. One malformed chapter must not brick the app:
//
//    5. A chunk that fails to inflate or is not UTF-8, or whose row_count /
//       raw_size disagrees with its blob.
//    6. A chapter blob whose record count disagrees with entry_count.
//    7. An MHCC body id that does not resolve in `bodies`.
//    8. A malformed token stream (unterminated token, wrong field count, unknown
//       Strong's flag).
//    9. An unresolvable book name, or a chapter outside the book.
//   10. A dict_keys / notes_index row pointing at a slot its chunk does not have.
//
//  NOT failures: a chapter absent from `chapters` (wholly-empty chapters are
//  omitted; the reader shows the "empty chapter" message), and a dictionary or
//  note lookup that misses (nil is the right answer).
//
//  For a chapter, the reader cannot yet tell 5-7 from that absent case:
//  `PSContentStore.chapterRecords` reports the failure and then returns the same
//  nil for both, so in a release build a corrupt chapter is logged and shown as
//  the "empty chapter" message rather than returned as nil. Neither occurs over
//  the bundled store: both modules hold all 1,189 chapters, and every one
//  inflates, decodes and counts consistently.
//

import Foundation

@objc(PSContentReader)
final class PSContentReader: NSObject {

    @objc(sharedReader)
    static let shared = PSContentReader()

    /// nil when the store failed to open or validate. Held rather than re-fetched
    /// so the failure is reported once, at first use, not on every page turn.
    private let store: PSContentStore?
    private let resolver: PSBookOSISResolver?

    override init() {
        store = PSContentStore.shared
        resolver = PSBookOSISResolver.shared
        super.init()
    }

    /// Whether the reader is usable at all. Always true in production (both
    /// dependencies are fatal if absent); exists so tests over broken stores can
    /// assert `false` instead of trapping.
    @objc var isAvailable: Bool { store != nil && resolver != nil }

    // MARK: - Lexicon lookups

    /// A lexicon entry for `key`, or nil if the lexicon does not have it.
    @objc(entryForModule:key:)
    static func entry(module: String, key: String?) -> String? {
        guard let key else { return nil }
        return shared.dictionaryEntry(module: module, key: key)
    }

    /// Every key of a lexicon, in the module's own order and true casing.
    @objc(allKeysForModule:)
    static func allKeys(module: String) -> [String] {
        shared.dictionaryKeys(module: module)
    }

    /// How many entries a lexicon has.
    @objc(entryCountForModule:)
    static func entryCount(module: String) -> Int {
        shared.dictionaryEntryCount(module: module)
    }

    /// The footnote (`n`) branch of the passagestudy attribute lookup — the only
    /// branch that renders content. The `x` and `scriptRef` branches are provably
    /// unreachable for the shipped content (see PSRefSemanticsTests).
    @objc(footnoteBodyForModule:data:)
    static func footnoteBody(module: String?, data: [AnyHashable: Any]) -> String? {
        guard let module,
              let passage = data[ATTRTYPE_PASSAGE] as? String,
              let marker = data[ATTRTYPE_VALUE] as? String else {
            return nil
        }
        return shared.noteBody(module: module, osisRef: passage, marker: marker)
    }

    // MARK: - Options

    /// Load the render options for a module from the **per-module** prefs
    /// (`"<pref>_<ModuleName>"`).
    ///
    /// Only some options have a token to gate:
    ///
    ///  * scriptRefs / strongs / morphs / headings / footnotes / redLetter — gated
    ///    here (scriptRefs shares `footnotes`' note tokens).
    ///  * variants — pinned to "Primary Reading"; nothing to vary.
    ///  * glosses, greekAccents, hebrewPoints, hebrewCantillation — act on source
    ///    text, not emitted markup, so they have no token. None of the shipped
    ///    modules declares them, and the store was baked with all four Off. A
    ///    module that did would need its own axis.
    func options(forModule module: String) -> PSChapterExpander.Options {
        let defaults = UserDefaults.standard
        var options = PSChapterExpander.Options()
        // Only Numbers draws the markers. Underlined Words draws the chapter
        // without them and links the words they tag instead, found through a
        // copy built with them on (`ReaderPaneModel.annotatingStrongs`).
        options.strongs = StrongsDisplay.current(forModule: module, defaults: defaults) == .numbers
        options.morphs = defaults.psBool(Defaults.morphPreference, forModule: module)
        options.headings = defaults.psBool(Defaults.headingsPreference, forModule: module)
        options.redLetter = defaults.psBool(Defaults.redLetterPreference, forModule: module)
        // Footnotes and cross-references are separate UI toggles but share the note
        // token family ('n' footnote, 'x' cross-reference). No `x` token exists in
        // the shipped content, so gate on footnotes, the one with any effect.
        options.footnotes = defaults.psBool(Defaults.footnotesPreference, forModule: module)
        return options
    }

    // MARK: - Chapter rendering

    /// The chapter body as HTML — the fixture-pinned oracle
    /// `PSChapterDocumentParityTests` compares the native document against. Not
    /// a render path.
    ///
    /// `ref` is the caller's ref string ("Genesis 1" / "Gen 1"), used both for
    /// resolution and — unchanged — for the bookmark-highlight lookup, which keys
    /// on `createRefString(ref)`.
    func chapterBody(module: String,
                     ref: String,
                     kind: PSChapterAssembler.ModuleKind,
                     applyBookmarkHighlights: Bool,
                     options: PSChapterExpander.Options? = nil,
                     reportFailures: Bool = true) -> (body: String, entryCount: Int)? {
        guard let store, let resolver else {
            PSContentStore.fail("reader is unavailable", report: reportFailures)
            return nil
        }
        guard let (book, chapter) = resolver.resolve(ref: ref) else {
            PSContentStore.fail("cannot resolve ref '\(ref)'", report: reportFailures)
            return nil
        }
        let opts = options ?? self.options(forModule: module)

        guard let records = store.chapterRecords(module: module,
                                                 bookOsis: book.osisName,
                                                 chapter: chapter) else {
            // Not a failure: the converter omits wholly-empty chapters, and the
            // engine renders the same message for them.
            return (emptyChapterBody(bookName: book.name, chapter: chapter), 0)
        }
        // Headings are keyed by the module's own key text, which uses the LONG
        // (roman-numeral) book name: "I Corinthians 1:1", not "1 Corinthians 1:1".
        let headings = store.headings(module: module, bookName: book.longName, chapter: chapter)

        var expanded: [String] = []
        expanded.reserveCapacity(records.records.count)
        for record in records.records {
            if record.isEmpty {
                expanded.append("")
                continue
            }
            guard let html = PSChapterExpander.expand(record, options: opts, reportFailures: reportFailures) else {
                // expand() has already reported the specific malformation.
                return nil
            }
            expanded.append(html)
        }

        var config = PSChapterAssembler.Config()
        config.kind = kind
        config.versePerLine = UserDefaults.standard.psBool(Defaults.vplPreference, forModule: module)
        config.headingsOn = opts.headings

        // The highlight lookup takes the CALLER's ref through createRefString
        // ("Psalms 23", not "Ps 23"). The abbreviation renders identical bytes but
        // silently matches no bookmark, so they are not interchangeable.
        let highlightRef = applyBookmarkHighlights ? PSRefHelper.createRefString(ref) : nil

        guard let result = PSChapterAssembler.assemble(
            records: expanded,
            headings: headings,
            config: config,
            headingHTML: { PSChapterExpander.expand($0.html, options: opts.forHeading) },
            highlightColour: { verse in
                guard let highlightRef else { return nil }
                return PSBookmarks.getHighlightRGBColourString(forBookAndChapterRef: highlightRef,
                                                               withVerse: verse)
            },
            emptyChapterMessage: self.emptyChapterBody(bookName: book.name, chapter: chapter))
        else {
            return nil
        }
        return (result.body, result.entryCount)
    }

    /// The typed chapter document the native reader renders — the render path.
    ///
    /// Same inputs, option prefs and bookmark-highlight lookup as `chapterBody`,
    /// but emits `ChapterDocument` values instead of HTML. See
    /// `PSChapterDocument.swift` for why the token stream has a second emitter.
    ///
    /// `PSChapterDocumentParityTests` asserts this agrees with `chapterBody` on
    /// text, verse identity, `entryCount` and every link target.
    ///
    /// `onlyVerses` builds those slots and no others — in a Bible a slot is its
    /// verse — for a caller that wants a few verses of many chapters rather than
    /// a chapter: a Strong's search marks its rows through a copy of every
    /// chapter they are in (`PSSearchEngine.markStrongsWords`), and built whole,
    /// those copies took up to three times as long: 92–313 ms against 54–103
    /// for a list of 1,001 (MEASURED 2026-11-21, `-O`).
    /// Every other slot is handed to the builder empty, which it skips as it
    /// skips any empty slot, so a verse keeps its number and its headings and
    /// `entryCount` is the chapter's. One thing differs: a verse that repeats
    /// the one before it is built, where the whole chapter skips it. The KJV
    /// has none — `testTheReadersWordsAreTheWordsTheSearchMatched` finds every
    /// verse of the index in the chapter at both option endpoints. Nil, the
    /// render path, builds the chapter.
    func chapterDocument(module: String,
                         ref: String,
                         kind: PSChapterAssembler.ModuleKind,
                         options: PSChapterExpander.Options? = nil,
                         applyBookmarkHighlights: Bool = true,
                         reportFailures: Bool = true,
                         onlyVerses: Set<Int>? = nil) -> ChapterDocument? {
        guard let store, let resolver else {
            PSContentStore.fail("reader is unavailable", report: reportFailures)
            return nil
        }
        guard let (book, chapter) = resolver.resolve(ref: ref) else {
            PSContentStore.fail("cannot resolve ref '\(ref)'", report: reportFailures)
            return nil
        }
        let opts = options ?? self.options(forModule: module)

        guard let records = store.chapterRecords(module: module,
                                                 bookOsis: book.osisName,
                                                 chapter: chapter) else {
            // Not a failure: wholly-empty chapters are omitted from the store.
            var document = ChapterDocument()
            document.emptyMessage = emptyChapterMessage(bookName: book.name,
                                                        chapter: chapter)
            return document
        }
        // Headings are keyed by the module's own key text, which uses the LONG
        // (roman-numeral) book name — see `chapterBody`.
        let headings = store.headings(module: module,
                                      bookName: book.longName,
                                      chapter: chapter)

        var config = PSChapterDocumentBuilder.Config()
        config.kind = kind
        config.headingsOn = opts.headings

        // The CALLER's ref through createRefString, as in `chapterBody`.
        let highlightRef = applyBookmarkHighlights
            ? PSRefHelper.createRefString(ref)
            : nil

        var slots = records.records
        if let onlyVerses {
            for slot in slots.indices where !onlyVerses.contains(slot) {
                slots[slot] = ""
            }
        }

        return PSChapterDocumentBuilder.build(
            records: slots,
            headings: headings,
            config: config,
            options: opts,
            highlightColour: { verse in
                guard let highlightRef else { return nil }
                return PSBookmarks.getHighlightRGBColourString(
                    forBookAndChapterRef: highlightRef,
                    withVerse: verse
                )
            },
            emptyChapterMessage: self.emptyChapterMessage(bookName: book.name,
                                                          chapter: chapter),
            reportFailures: reportFailures)
    }

    /// The `word_map` of every verse in `ref`'s chapter, keyed by verse: which
    /// of its words carry which Strong's numbers, in order. What the search
    /// index holds for the same verses (it is built from these rows).
    ///
    /// Empty for a ref that does not resolve, and for a module without Strong's
    /// numbers. The reader asks for it while a Strong's search result is
    /// highlighted, and on every render in Underlined Words mode
    /// (`ReaderPaneModel.annotatingStrongs`).
    func wordMaps(module: String, ref: String) -> [Int: String] {
        guard let store, let resolver,
              let (book, chapter) = resolver.resolve(ref: ref) else { return [:] }
        // Keyed by the module's own key text, the LONG book name, as `headings`.
        return store.wordMaps(module: module, bookOsis: book.osisName,
                              bookName: book.longName, chapter: chapter)
    }

    /// The empty-chapter fallback, byte-identical to the engine's. The
    /// parenthesised ref is the chapter part of the key text, e.g. "Genesis 1".
    private func emptyChapterBody(bookName: String, chapter: Int) -> String {
        let message = NSLocalizedString("EmptyChapterWarning", comment: "This chapter is empty for this module.")
        return "<p style=\"color:grey;text-align:center;font-style:italic;\">\(message) (\(bookName) \(chapter))</p>"
    }

    /// The same message as plain text, for the native reader. Shares the
    /// localisation key with `emptyChapterBody`, so the two cannot drift.
    private func emptyChapterMessage(bookName: String, chapter: Int) -> String {
        let message = NSLocalizedString("EmptyChapterWarning", comment: "This chapter is empty for this module.")
        return "\(message) (\(bookName) \(chapter))"
    }

    // MARK: - Lexicons

    /// A lexicon entry for the key the UI holds. See PSContentStore.dictEntry for
    /// the casing and zero-padding rules.
    @objc(dictionaryEntryForModule:key:)
    func dictionaryEntry(module: String, key: String) -> String? {
        store?.dictEntry(module: module, key: key)
    }

    /// Every key of a lexicon, in the module's own `.idx` order and in its **true
    /// casing**. Do not capitalise: the keys are case-significant (`V-PAI-3S`).
    @objc(dictionaryKeysForModule:)
    func dictionaryKeys(module: String) -> [String] {
        if let cached = Self.keyCache[module] { return cached }
        let keys = store?.dictKeys(module: module) ?? []
        // Memoise: `dictKeys` is a full table query and the store is immutable.
        if !keys.isEmpty { Self.keyCache[module] = keys }
        return keys
    }

    /// Memoised `dictionaryKeys` results, keyed by module; never invalidated
    /// because the bundled store is read-only.
    ///
    /// **MAIN-THREAD ONLY, deliberately unsynchronised.** A background caller must
    /// add synchronisation first — an unguarded dictionary write racing a read is
    /// a crash, not a stale answer.
    private static var keyCache: [String: [String]] = [:]

    @objc(dictionaryEntryCountForModule:)
    func dictionaryEntryCount(module: String) -> Int {
        store?.dictEntryCount(module: module) ?? 0
    }

    // MARK: - Notes

    /// A footnote body, expanded.
    @objc(noteBodyForModule:osisRef:marker:)
    func noteBody(module: String, osisRef: String, marker: String) -> String? {
        guard let store else { return nil }
        // The passage arrives URL-encoded straight off the anchor
        // (`passage=Genesis+4%3A1`, not decoded by `data(forLink:)`), but
        // notes_index holds "Genesis 4:1". Decode here, and accept an already-clean
        // ref too.
        let decoded = Self.decodePassage(osisRef)
        guard let note = store.note(module: module, osisRef: decoded, marker: marker) else {
            return nil
        }
        // The stored note body is not option-gated; the anchor that leads here is.
        guard let html = PSChapterExpander.expand(note.body, options: .allOn) else { return nil }
        return html
    }

    /// `Genesis+4%3A1` -> `Genesis 4:1`. `+` means space in a query string, so it
    /// is replaced before percent-decoding (decoding first would leave a literal
    /// `+` where a `%2B` had been, though no ref contains one).
    static func decodePassage(_ passage: String) -> String {
        let plussed = passage.replacingOccurrences(of: "+", with: " ")
        return plussed.removingPercentEncoding ?? plussed
    }
}

/// How a module's Strong's numbers are shown: the reader's four-way choice.
///
/// **Three per-module keys, not one.** `strongsPreference` (Bool) is whether
/// Strong's is shown at all, exactly as it always was, so every saved value and
/// every `-strongsPreference_KJV YES` launch argument keeps its meaning.
/// `strongsUnderlinePreference` (Bool, absent reads as off) picks underlined
/// words over the numbers, and means nothing while the first is off.
/// `strongsInvisiblePreference` (Bool, absent reads as off) makes those words
/// links with no underline, and wins over the underline key.
enum StrongsDisplay: String, CaseIterable, Identifiable {
    /// No markers and no links.
    case off
    /// A grey superscript marker after each tagged word, tapped for its entry.
    case numbers
    /// No markers: each tagged word or phrase is underlined and is itself the
    /// link (`ChapterVerse.strongsWords`). A number with no English word to
    /// stand on (John 3:16's leading articles) is not reachable this way;
    /// Numbers shows it.
    case words
    /// As `words`, in every respect but one: the words are links and carry no
    /// underline, so nothing on the page says they can be tapped.
    case invisible

    /// Whether the tagged words are drawn as links (`words`, `invisible`).
    var linksWords: Bool { self == .words || self == .invisible }

    var id: String { rawValue }

    /// The localization key of the choice's title in the reader's menu.
    var titleKey: String {
        switch self {
        case .off: "PreferencesStrongsDisplayOff"
        case .numbers: "PreferencesStrongsDisplayNumbers"
        case .words: "PreferencesStrongsDisplayWords"
        case .invisible: "PreferencesStrongsDisplayInvisible"
        }
    }

    /// What a module shows when the reader has never chosen (see
    /// `current(forModule:defaults:)`): the words are links, drawn plain.
    static let initial: StrongsDisplay = .invisible

    /// The module's choice. **With no `strongsPreference` stored, it is
    /// `initial`**: a first launch, or after a reset (which removes all three
    /// keys). Every choice the menu offers writes `strongsPreference`, Off
    /// included, so an explicit choice always wins, and the other two keys
    /// mean nothing until it is stored and on. A `-strongsPreference_KJV YES`
    /// seed with the other two absent still reads as the numbers, as it always
    /// has.
    static func current(forModule module: String,
                        defaults: UserDefaults = .standard) -> StrongsDisplay {
        guard defaults.object(
            forKey: defaults.psModuleKey(Defaults.strongsPreference, module)
        ) != nil else {
            return initial
        }
        guard defaults.psBool(Defaults.strongsPreference, forModule: module) else {
            return .off
        }
        if defaults.psBool(Defaults.strongsInvisiblePreference, forModule: module) {
            return .invisible
        }
        return defaults.psBool(Defaults.strongsUnderlinePreference, forModule: module)
            ? .words
            : .numbers
    }

    /// Writes the three keys `current(forModule:)` reads. Off clears the
    /// underline and invisible keys too: neither is read while Strong's is off,
    /// but left on either would make Underlined Words (or Invisible) of
    /// anything that later turns `strongsPreference` on by itself — a seeded
    /// container, a `-strongsPreference_KJV YES` argument — where that has
    /// always meant the numbers.
    static func write(_ display: StrongsDisplay,
                      forModule module: String,
                      defaults: UserDefaults = .standard) {
        defaults.psSet(display != .off, forPref: Defaults.strongsPreference, module: module)
        defaults.psSet(display == .words,
                       forPref: Defaults.strongsUnderlinePreference,
                       module: module)
        defaults.psSet(display == .invisible,
                       forPref: Defaults.strongsInvisiblePreference,
                       module: module)
    }
}
