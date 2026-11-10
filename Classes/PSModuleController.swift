//
//  PSModuleController.swift
//  PocketSword
//
//  App-level singleton holding the user's primary Bible / commentary / dictionary
//  (by name) plus the ref-string and link-parsing helpers.
//
//  Copyright 2008-2012 CrossWire Bible Society – http://www.crosswire.org
//  GPL v2 (see the original header).
//

import Foundation
import UIKit

// SWORD option / category / attribute names. Wire strings — must match the
// values in globals.h byte-for-byte.
private enum SW {
    // global options (SW_OPTION_*)
    static let optionScriptRefs = "Cross-references"
    static let optionStrongs = "Strong's Numbers"
    static let optionMorphs = "Morphological Tags"
    static let optionHeadings = "Headings"
    static let optionFootnotes = "Footnotes"
    static let optionRedLetterWords = "Words of Christ in Red"
    static let optionGreekAccents = "Greek Accents"
    static let optionHebrewPoints = "Hebrew Vowel Points"
    static let optionHebrewCantillation = "Hebrew Cantillation"
    static let optionVariants = "Textual Variants"
    static let optionVariantsPrimary = "Primary Reading"
    static let optionGlosses = "Glosses"
    static let on = "On"
    static let off = "Off"

    // module categories (SWMOD_CATEGORY_*)
    static let categoryBibles = "Biblical Texts"
    static let categoryCommentaries = "Commentaries"
    static let categoryDictionaries = "Lexicons / Dictionaries"

    // passagestudy attribute keys (ATTRTYPE_*)
    static let attrType = "type"
    static let attrPassage = "passage"
    static let attrModule = "modulename"
    static let attrAction = "action"
    static let attrValue = "value"
}

@objc(PSModuleController)
final class PSModuleController: NSObject {

    // MARK: - The three primary modules, by NAME
    //
    // `nil` means "not resolved yet"; callers resolve via `reloadLast*`.

    /// The Bible being read, by name.
    @objc var primaryBibleName: String?

    /// The commentary being read, by name.
    @objc var primaryCommentaryName: String?

    /// The lexicon being browsed, by name.
    @objc var primaryDictionaryName: String?

    @objc var busyTimer: Timer?

    // MARK: - Singleton

    private static var instance: PSModuleController?

    /// Shared instance. Imported into Swift as `default()`; returns an IUO so both
    /// `.default().x` and `.default()!` call sites compile.
    @objc(defaultModuleController)
    class func `default`() -> PSModuleController! {
        if instance == nil {
            instance = PSModuleController()
        }
        return instance
    }

    @objc(releaseDefaultModuleController)
    class func releaseDefaultModuleController() {
        instance = nil
    }

    // MARK: - First / last available ref (static state, preserved exactly)

    private static var lastRefAvailable: String = "Revelation 22"
    private static var firstRefAvailable: String = "Genesis 1"

    @objc(setFirstRefAvailable:)
    class func setFirstRefAvailable(_ first: String!) {
        firstRefAvailable = first
    }

    @objc(setLastRefAvailable:)
    class func setLastRefAvailable(_ last: String!) {
        lastRefAvailable = last
    }

    @objc(getFirstRefAvailable)
    class func getFirstRefAvailable() -> String! {
        return firstRefAvailable
    }

    @objc(getLastRefAvailable)
    class func getLastRefAvailable() -> String! {
        return lastRefAvailable
    }

    // MARK: - Init

    @objc override init() {
        super.init()

        // The first/last available refs, derived from the baked versification table.
        // Values equal the static defaults above ("Genesis 1" / "Revelation 22");
        // "Revelation of John" munges to "Revelation" through createRefString.
        if let books = PSBookOSISResolver.shared?.books, let first = books.first, let last = books.last {
            PSModuleController.setFirstRefAvailable("\(first.name) 1")
            PSModuleController.setLastRefAvailable(
                PSModuleController.createRefString("\(last.longName) \(last.chapterCount)"))
        }

        // Per-module option prefs are read by the reader at render time
        // (PSContentReader.options(forModule:)).
        reloadLastBible()
        reloadLastCommentary()
    }

    // MARK: - Loaded check

    @objc(isLoaded:)
    func isLoaded(_ module: String) -> Bool {
        if let primaryBibleName, primaryBibleName == module {
            return true
        } else if let primaryCommentaryName, primaryCommentaryName == module {
            return true
        } else if let primaryDictionaryName, primaryDictionaryName == module {
            return true
        }
        return false
    }

    // MARK: - Current bible ref

    @objc(getCurrentBibleRef)
    class func getCurrentBibleRef() -> String! {
        let defaults = UserDefaults.standard
        if let lastRef = defaults.string(forKey: Defaults.lastRef) {
            return lastRef
        }
        defaults.set("Genesis 1", forKey: Defaults.lastRef)
        defaults.synchronize()
        return "Genesis 1"
    }

    // MARK: - Primary module loaders

    @objc(loadPrimaryBible:)
    func loadPrimaryBible(_ newText: String!) {
        primaryBibleName = newText
        UserDefaults.standard.set(newText, forKey: Defaults.lastBible)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: .newPrimaryBible, object: nil)
    }

    @objc(loadPrimaryCommentary:)
    func loadPrimaryCommentary(_ newText: String!) {
        primaryCommentaryName = newText
        UserDefaults.standard.set(newText, forKey: Defaults.lastCommentary)
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: .newPrimaryCommentary, object: nil)
    }

    /// Load a lexicon as the primary dictionary.
    @objc(loadPrimaryDictionary:)
    func loadPrimaryDictionary(_ newText: String!) {
        primaryDictionaryName = newText
        if let newText {
            UserDefaults.standard.set(newText, forKey: Defaults.lastDictionary)
        } else {
            UserDefaults.standard.removeObject(forKey: Defaults.lastDictionary)
        }
        UserDefaults.standard.synchronize()
        NotificationCenter.default.post(name: .newPrimaryDictionary, object: nil)
    }

    // Never called by the OS — callers invoke it manually.
    @objc(didReceiveMemoryWarning)
    func didReceiveMemoryWarning() {
        // Deliberately a no-op: the reader's lexicon keys are memoised from an
        // immutable read-only store, so there is nothing worth releasing. Kept as the
        // hook callers already use.
    }

    // MARK: - Chapter navigation
    //
    // Things a "simplification" would silently break:
    //
    //  1. Both modules share KJV versification, so the destination is computed
    //     once. The per-module pref writes keep their conditional shape, including
    //     the asymmetry that `next` leaves `commentaryVersePosition` alone when a
    //     bible is loaded while `prev` sets it from the bible's verse maximum.
    //  2. The verse maximum is the DESTINATION chapter's, not the one being left.
    //  3. nil at the canon boundaries. Callers also gate on string equality with
    //     get{First,Last}RefAvailable (three places, one drives button-enable
    //     state); the nil is a second, structural guard. Returning a clamped ref
    //     would turn a no-op into a full re-render.

    /// The table's answer for a move from the current ref, or nil at the canon
    /// boundary / for a ref the table cannot resolve.
    ///
    /// Returns the un-munged `longName` form ("Revelation of John 22"); every call
    /// site munges it through `createRefString`. 18 of the 66 books have
    /// `name != longName`, so returning `name` would be visibly wrong.
    private func navigate(from ref: String?, forward: Bool)
        -> (ref: String, book: PSVersificationBook, chapter: Int)? {
        guard let resolver = PSBookOSISResolver.shared,
              let ref = ref,
              let (book, chapter) = resolver.resolve(ref: ref) else { return nil }
        guard let destination = forward
                ? resolver.nextChapter(book: book, chapter: chapter)
                : resolver.previousChapter(book: book, chapter: chapter) else { return nil }
        return (resolver.displayRef(destination), destination.book, destination.chapter)
    }

    @objc(setToNextChapter)
    func setToNextChapter() -> String! {
        guard let destination = navigate(from: PSModuleController.getCurrentBibleRef(),
                                         forward: true) else { return nil }

        var ret: String? = nil
        if primaryBibleName != nil {
            ret = destination.ref
            UserDefaults.standard.set("1", forKey: Defaults.bibleVersePosition)
        }
        if primaryCommentaryName != nil, ret == nil {
            ret = destination.ref
            UserDefaults.standard.set("1", forKey: Defaults.commentaryVersePosition)
        }
        UserDefaults.standard.synchronize()
        return ret
    }

    @objc(setToPreviousChapter)
    func setToPreviousChapter() -> String! {
        guard let destination = navigate(from: PSModuleController.getCurrentBibleRef(),
                                         forward: false) else { return nil }
        // The DESTINATION chapter's maximum — see note 2 above.
        let destinationVerseMax = PSBookOSISResolver.shared?
            .verseMax(book: destination.book, chapter: destination.chapter) ?? 0

        var ret: String? = nil
        var verse = 0
        if primaryBibleName != nil {
            ret = destination.ref
            verse = destinationVerseMax
            UserDefaults.standard.set(String(format: "%ld", verse), forKey: Defaults.bibleVersePosition)
        }
        if primaryCommentaryName != nil {
            if ret == nil {
                ret = destination.ref
                verse = destinationVerseMax
                UserDefaults.standard.set(String(format: "%ld", verse), forKey: Defaults.commentaryVersePosition)
            } else if verse != 0 {
                UserDefaults.standard.set(String(format: "%ld", verse), forKey: Defaults.commentaryVersePosition)
            }
        }
        UserDefaults.standard.synchronize()
        return ret
    }

    // MARK: - Reload last bible / commentary

    /// Resolve the primary Bible from `lastBible`, falling back to the bundled one.
    /// A persisted name is honoured only if it names a Bible we ship — the kind is
    /// checked, not just that the module ships; see `reloadLastCommentary`.
    @objc(reloadLastBible)
    func reloadLastBible() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: Defaults.lastBible)
        if let last,
           PSContentStore.shared?.moduleMeta(last, key: "type") == PSRefLinkRouter.typeBible {
            primaryBibleName = last
        } else {
            primaryBibleName = BundledModules.bible
            defaults.set(BundledModules.bible, forKey: Defaults.lastBible)
            defaults.synchronize()
        }
    }

    /// Resolve the primary commentary from `lastCommentary`. Same shape as
    /// `reloadLastBible`, and the same rule: only a commentary we ship.
    ///
    /// The test used to be "has a type at all", which a lexicon passes — and the
    /// `sword://` router used to write one here (a URL with a lexicon as its host
    /// was loaded as the commentary). A lexicon has no chapters, so it came back
    /// at every launch as a commentary whose every chapter is empty, with no
    /// module picker to replace it. The wrong kind now takes the fallback, which
    /// rewrites the default too, so an install already holding one heals here.
    @objc(reloadLastCommentary)
    func reloadLastCommentary() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: Defaults.lastCommentary)
        if let last,
           PSContentStore.shared?.moduleMeta(last, key: "type") == PSRefLinkRouter.typeCommentary {
            primaryCommentaryName = last
        } else {
            primaryCommentaryName = BundledModules.commentary
            defaults.set(BundledModules.commentary, forKey: Defaults.lastCommentary)
            defaults.synchronize()
        }
    }

    // MARK: - Ref string helpers

    @objc(createRefString:)
    class func createRefString(_ ref: String!) -> String! {
        guard let ref = ref else { return nil }
        return ref
            .replacingOccurrences(of: "III ", with: "3 ")
            .replacingOccurrences(of: "II ", with: "2 ")
            .replacingOccurrences(of: "I ", with: "1 ")
            .replacingOccurrences(of: " of John ", with: " ")
    }

    @objc(createTitleRefString:)
    class func createTitleRefString(_ newTitle: String!) -> String! {
        let mutableTitle = NSMutableString(string: "")
        let titleToDisplay: String
        let verseRange = (newTitle as NSString).range(of: " ", options: .backwards)
        var titleMask = NSRangeFromString("0 3")
        if verseRange.location != NSNotFound { // only @"PocketSword" won't be here.
            let rest = (newTitle as NSString).substring(to: verseRange.location) // cuts off the @"3:16" part.
            let spaceRange = (rest as NSString).range(of: " ")
            if spaceRange.location != NSNotFound { // the book name contains a space.
                if spaceRange.location == 1 { // single char, so probably a number, as in "1 Cor", so keep this
                    mutableTitle.appendFormat("%c ", (newTitle as NSString).character(at: 0))
                    titleMask.location = 2
                } else if spaceRange.location == 2 { // double char, so probably a number followed by . as in "1. Cor", so keep this.
                    mutableTitle.appendFormat("%c%c ", (newTitle as NSString).character(at: 0), (newTitle as NSString).character(at: 1))
                    titleMask.location = 3
                }
            }
            mutableTitle.append((newTitle as NSString).substring(with: titleMask))
            mutableTitle.append((newTitle as NSString).substring(from: verseRange.location))
            titleToDisplay = mutableTitle as String
        } else {
            titleToDisplay = newTitle
        }
        return titleToDisplay
    }

    // MARK: - Link data parsing

    @objc(dataForLink:)
    class func data(forLink aURL: URL!) -> [AnyHashable: Any]! {
        // Two kinds of link: our generated sword:// links, and study data (file://).
        var ret: [AnyHashable: Any]? = nil

        // A nil link yields a nil dictionary.
        guard let aURL = aURL else { return nil }

        let scheme = aURL.scheme
        if scheme == "sword" || scheme == "bible" {
            // in this case host is the module and path the reference
            var dict = [AnyHashable: Any]()
            if let host = aURL.host {
                dict[SW.attrModule] = host
            } else {
                dict[SW.attrModule] = NSNull()
            }
            let value = (aURL.path.removingPercentEncoding ?? aURL.path)
                .replacingOccurrences(of: "/", with: "")
                .replacingOccurrences(of: "+", with: " ")
            dict[SW.attrValue] = value
            dict[SW.attrType] = "scriptRef"
            dict[SW.attrAction] = "showRef"
            ret = dict
        } else if scheme == "file" || scheme == "applewebdata" {
            let path = aURL.path
            let query = aURL.query
            if (path as NSString).lastPathComponent == "passagestudy.jsp" {
                let data = (query ?? "").components(separatedBy: "&")
                var type = "x"
                var module = ""
                var passage = ""
                var value = "1"
                var action = ""
                for entry in data {
                    if entry.hasPrefix("type=") {
                        type = entry.components(separatedBy: "=")[1]
                    } else if entry.hasPrefix("module=") {
                        module = entry.components(separatedBy: "=")[1]
                    } else if entry.hasPrefix("passage=") {
                        passage = entry.components(separatedBy: "=")[1]
                    } else if entry.hasPrefix("action=") {
                        action = entry.components(separatedBy: "=")[1]
                    } else if entry.hasPrefix("value=") {
                        value = entry.components(separatedBy: "=")[1]
                    } else {
                        alog("[ExtTextViewController -dataForLink:] unknown parameter: \(entry)\n")
                    }
                }
                var dict = [AnyHashable: Any]()
                dict[SW.attrModule] = module
                dict[SW.attrPassage] = passage
                dict[SW.attrValue] = value
                dict[SW.attrAction] = action
                dict[SW.attrType] = type
                ret = dict
            }
        }
        return ret
    }
}
