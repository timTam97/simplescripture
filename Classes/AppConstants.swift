//
//  AppConstants.swift
//  PocketSword
//
//  Swift mirror of Classes/globals.h. Dual-maintained: every wire string here
//  must match globals.h BYTE-FOR-BYTE. The persisted key often differs from the
//  macro name (e.g. DefaultsLastRef -> "lastRef") — do NOT "fix" these; they are
//  persisted keys and changing them corrupts user data.
//

import Foundation

// MARK: - Defaults keys
//
// The right-hand value is the PERSISTED wire string, often not the same as the
// symbol name on the left.

enum Defaults {
    static let moduleCipherKeysKey         = "DefaultsModuleCipherKeysKey"
    static let lastRef                     = "lastRef"                 // macro DefaultsLastRef
    static let lastBible                   = "lastBible"               // macro DefaultsLastBible
    static let lastCommentary              = "lastCommentary"          // macro DefaultsLastCommentary
    static let lastDictionary              = "lastDictionary"          // macro DefaultsLastDictionary

    static let lastMultiListTab            = "DefaultsLastMultiListTab"
    static let lastSearchFuzzy             = "DefaultsLastSearchFuzzy"
    static let lastSearchType              = "DefaultsLastSearchType"
    static let lastSearchRange             = "DefaultsLastSearchRange"
    static let pendingSearchIndexModule    = "PendingSearchIndexModule"
    /// Consecutive FAILED background search-index build attempts for
    /// `pendingSearchIndexModule`, bounding the BGProcessingTask retry. Swift-only.
    static let pendingSearchIndexAttempts  = "PendingSearchIndexAttempts"
    static let luceneSwept                 = "DefaultsLuceneSwept"
    static let simplifiedCleanupDone       = "DefaultsSimplifiedCleanupDone"
    static let moduleChoiceRetired         = "DefaultsModuleChoiceRetired"
    static let globalFontOnly              = "DefaultsGlobalFontOnly"
    static let lastRefValidated            = "DefaultsLastRefValidated"
    static let dictKeyCaseFixed            = "DefaultsDictKeyCaseFixed"
    /// One-shot: delete the Documents/ trees the SWORD engine left behind
    /// (mods.d / modules / locales.d / unused) plus <Caches>/InstallMgr. Swift-only.
    static let swordRetired = "DefaultsSwordRetired"

    static let bibleVersePosition          = "bibleVersePosition"      // macro DefaultsBibleVersePosition
    static let commentaryVersePosition     = "commentaryVersePosition" // macro DefaultsCommentaryVersePosition

    // Default modules
    //
    // RETIRED: never written or read. A set flag would suppress a bundled module
    // forever, so `moduleChoiceRetired` clears any that are set. Kept declared so
    // the names are not reused.
    static let kjvRemoved                  = "DefaultsKJVRemoved"
    static let mhccRemoved                 = "DefaultsMHCCRemoved"
    static let strongsRealHebrewRemoved    = "DefaultsStrongsRealHebrewRemoved"
    static let robinsonRemoved             = "DefaultsRobinsonRemoved"
    static let strongsRealGreekRemoved     = "DefaultsStrongsRealGreekRemoved"

    /// All five retired `Defaults*Removed` flags, for the one-shot migration.
    static let bundledModuleRemovedFlags = [kjvRemoved, mhccRemoved,
                                           strongsRealHebrewRemoved,
                                           robinsonRemoved,
                                           strongsRealGreekRemoved]

    // Preferences - general
    //
    // RETIRED, NOT REUSABLE: the lexicon-role keys are never read or written — the
    // roles are hardcoded in `BundledModules`. A stale value can be the localized
    // string "None", so honouring one would break Strong's / morph lookups.
    static let strongsHebrewModule         = "DefaultsStrongsHebrewModule"
    static let strongsGreekModule          = "DefaultsStrongsGreekModule"
    static let morphHebrewModule           = "DefaultsMorphHebrewModule"
    static let morphGreekModule            = "DefaultsMorphGreekModule"

    /// The four retired lexicon-role keys, for the one-shot migration.
    static let retiredLexiconKeys = [strongsHebrewModule, strongsGreekModule,
                                     morphHebrewModule, morphGreekModule]
    static let insomniaPreference          = "insomniaPreference"            // macro DefaultsInsomniaPreference

    // RETIRED: never read. Kept declared so the key is not reused.
    static let swiftContentReaderPreference = "swiftContentReader"

    // from createHTMLString:
    static let fontNamePreference          = "fontNamePreference"
    static let fontSizePreference          = "fontSizePreference"
    static let fontDefaultsPreference      = "fontDefaultsPreference"

    // from attributeValueForEntryData: && getChapter:
    static let strongsPreference           = "strongsPreference"
    static let morphPreference             = "morphPreference"
    static let scriptRefsPreference        = "scriptRefsPreference"
    static let footnotesPreference         = "footnotesPreference"
    static let headingsPreference          = "headingsPreference"
    static let redLetterPreference         = "redLetterPreference"
    static let vplPreference               = "vplPreference"
    static let greekAccentsPreference      = "greekAccentsPreference"
    static let hvpPreference               = "hvpPreference"
    static let hebrewCantillationPreference = "hebrewCantillationPreference"
    static let glossesPreference           = "glossesPreference"

    static let rotationLockPosition        = "rotationLockedPosition"        // macro ROTATION_LOCK_POSITION
    /// The `LibrarySection` raw value the Library opens to. Swift-only.
    static let librarySectionPreference    = "librarySectionPreference"
}

// MARK: - Bundled modules
//
// The app ships exactly these five modules and has no UI to add, remove, or
// pick another. The three lexicon ROLES are fixed and NOT interchangeable:
// StrongsRealGreek is `Feature=GreekDef`, StrongsRealHebrew is `HebrewDef`,
// Robinson is `GreekParse`.

enum BundledModules {
    static let bible = "KJV"
    static let commentary = "MHCC"
    static let strongsGreek = "StrongsRealGreek"
    static let strongsHebrew = "StrongsRealHebrew"
    static let morphGreek = "Robinson"

    /// The three fixed-role lexicons, in Dictionary-tab menu order.
    static let lexicons = [strongsGreek, strongsHebrew, morphGreek]

    /// All five bundled modules.
    static let all = [bible, commentary, strongsGreek, strongsHebrew, morphGreek]
}

// MARK: - Font names + misc string / int constants

enum AppConstants {
    static let strongsFontName        = "Times New Roman"   // macro StrongsFontName
    static let greekStrongsFontName   = "Gentium Plus"      // macro PSGreekStrongsFontName
    static let hebrewStrongsFontName  = "Ezra SIL"          // macro PSHebrewStrongsFontName
    static let defaultFontName        = "Georgia"           // macro PSDefaultFontName
    /// The reading font size used when `fontSizePreference` is absent — the single
    /// fallback for both Settings and the renderers, so they cannot disagree after
    /// `LaunchCoordinator.resetPreferences()` removes the key. Swift-only.
    static let defaultFontSize        = 20
    static let folderSeparatorString  = ":::"               // macro PSFolderSeparatorString
    static let historyMaxEntries      = 100                 // macro PSHistoryMaxEntries (Int)
    static let historyName            = "bibleHistory"      // macro PSHistoryName

    static let bookNameString         = "BookNameString"
    static let chapterString          = "ChapterString"
    static let verseString            = "VerseString"

    static let bibleTabTitleString    = "BibleTabTitleString"
    static let commentaryTabTitleString = "CommentaryTabTitleString"
}

// MARK: - Notification names
//
// rawValue MUST equal the literal in globals.h.

extension Notification.Name {
    static let bibleSwipeRight              = Notification.Name("NotificationBibleSwipeRight")
    static let bibleSwipeLeft               = Notification.Name("NotificationBibleSwipeLeft")
    static let commentarySwipeRight         = Notification.Name("NotificationCommentarySwipeRight")
    static let commentarySwipeLeft          = Notification.Name("NotificationCommentarySwipeLeft")

    static let refSelectorResetBooks        = Notification.Name("NotificationRefSelectorResetBooks")
    static let newPrimaryBible              = Notification.Name("NotificationNewPrimaryBible")
    static let newPrimaryCommentary         = Notification.Name("NotificationNewPrimaryCommentary")
    static let newPrimaryDictionary         = Notification.Name("NotificationNewPrimaryDictionary")
    static let reloadDictionaryData         = Notification.Name("NotificationReloadDictionaryData")
    static let resetBibleAndCommentaryView  = Notification.Name("NotificationResetBibleAndCommentaryView")

    static let redisplayPrimaryBible        = Notification.Name("NotificationRedisplayPrimaryBible")
    static let redisplayPrimaryCommentary   = Notification.Name("NotificationRedisplayPrimaryCommentary")
    static let bookmarksChanged             = Notification.Name("NotificationBookmarksChanged")
    static let historyChanged               = Notification.Name("NotificationHistoryChanged")

    static let toggleMultiList              = Notification.Name("NotificationToggleMultiList")
    static let toggleNavigation             = Notification.Name("NotificationToggleNavigation")

    static let hideInfoPane                 = Notification.Name("NotificationHideInfoPane")
    static let showInfoPane                 = Notification.Name("NotificationShowInfoPane")
    static let rotateInfoPane               = Notification.Name("NotificationRotateInfoPane")

    static let showCommentaryTab            = Notification.Name("NotificationShowCommentaryTab")
    static let showBibleTab                 = Notification.Name("NotificationShowBibleTab")

    static let addBookmarkInFolder          = Notification.Name("NotificationAddBookmarkInFolder")

    static let updateSelectedReference      = Notification.Name("NotificationUpdateSelectedReference")

    // Posted after the reset routine clears defaults so observable models can
    // reload without re-persisting old values.
    static let appStateDidReset             = Notification.Name("PocketSwordAppStateDidReset")
}

// MARK: - Per-module preference accessors
//
// The one implementation of the per-module key format: "<Pref>_<Mod>" (pref
// first, single underscore). Persisted — must stay byte-identical or
// per-module prefs silently break.

extension UserDefaults {
    /// Composite key "<pref>_<mod>" — exact reproduction of "%@_%@" (pref, mod).
    func psModuleKey(_ pref: String, _ mod: String) -> String { "\(pref)_\(mod)" }

    /// Per-module toggles that read as ON when the key is absent (fresh install,
    /// or after `resetPreferences()`). An explicit stored value always wins.
    static let psDefaultOnPrefs: Set<String> = [Defaults.vplPreference]

    func psBool(_ pref: String, forModule mod: String) -> Bool {
        let key = psModuleKey(pref, mod)
        guard object(forKey: key) != nil else {
            return Self.psDefaultOnPrefs.contains(pref)
        }
        return bool(forKey: key)
    }

    func psString(_ pref: String, forModule mod: String) -> String? {
        string(forKey: psModuleKey(pref, mod))
    }

    func psInteger(_ pref: String, forModule mod: String) -> Int {
        integer(forKey: psModuleKey(pref, mod))
    }

    func psSet(_ value: Bool, forPref pref: String, module mod: String) {
        set(value, forKey: psModuleKey(pref, mod))
    }

    func psSet(_ value: Any?, forPref pref: String, module mod: String) {
        set(value, forKey: psModuleKey(pref, mod))
    }

    func psSet(_ value: Int, forPref pref: String, module mod: String) {
        set(value, forKey: psModuleKey(pref, mod))
    }

    func psRemove(_ pref: String, forModule mod: String) {
        removeObject(forKey: psModuleKey(pref, mod))
    }
}

// MARK: - Application paths
//
// Computed on every access (never captured `let`s), matching the DEFAULT_*_PATH
// macros. Most paths concatenate a literal "/"; MMM uses path-component append
// with NO trailing slash. Bookmarks live in Documents; derived data in Caches.

enum AppPaths {
    private static func documentsDirectory() -> String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }

    private static func cachesDirectory() -> String {
        NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    }

    /// DEFAULT_MODULE_PATH — Documents + "/"
    static var modulePath: String { documentsDirectory() + "/" }

    /// DEFAULT_MODULE_PATH_OLD — Caches + "/"
    static var modulePathOld: String { cachesDirectory() + "/" }

    /// DEFAULT_BUILTIN_MODULE_PATH — Documents + "/Built-in/"
    static var builtinModulePath: String { documentsDirectory() + "/Built-in/" }

    /// DEFAULT_APPSUPPORT_PATH — Caches + "/"
    static var appSupportPath: String { cachesDirectory() + "/" }

    /// DEFAULT_BOOKMARKS_PATH — Documents + "/"
    static var bookmarksPath: String { documentsDirectory() + "/" }

    /// DEFAULT_INSTALLER_PATH — Caches + "/InstallMgr/"
    static var installerPath: String { cachesDirectory() + "/InstallMgr/" }

    /// DEFAULT_MMM_PATH — Temporary dir, path-component "MMM" (NO trailing slash)
    static var mmmPath: String { (NSTemporaryDirectory() as NSString).appendingPathComponent("MMM") }

    /// The FTS search index for a module: `<Caches>/search/<module>.db`.
    ///
    /// Derived data, so it lives in the OS-purgeable Caches. Keyed by module name
    /// so modules share one directory.
    static func searchIndexPath(for module: String) -> String {
        (searchIndexDirectory as NSString).appendingPathComponent("\(module).db")
    }

    /// The directory holding every module's search index.
    static var searchIndexDirectory: String {
        (cachesDirectory() as NSString).appendingPathComponent("search")
    }
}

// MARK: - Logging shims
//
// `dlog` fires only in DEBUG; `alog` always fires.

/// DEBUG-only logging.
func dlog(_ message: String, file: String = #file, line: Int = #line) {
    #if DEBUG
    NSLog("%@ [Line %d] %@", (file as NSString).lastPathComponent, line, message)
    #endif
}

/// Always-on logging.
func alog(_ message: String, file: String = #file, line: Int = #line) {
    NSLog("%@ [Line %d] %@", (file as NSString).lastPathComponent, line, message)
}

// MARK: - Reference-string helpers
//
// Pure string / UserDefaults helpers used by the bookmark store.

enum PSRefHelper {

    /// Mirror of +[PSModuleController createRefString:] — normalises the leading
    /// roman-numeral book prefixes to arabic and strips " of John ".
    static func createRefString(_ ref: String) -> String {
        return ref
            .replacingOccurrences(of: "III ", with: "3 ")
            .replacingOccurrences(of: "II ", with: "2 ")
            .replacingOccurrences(of: "I ", with: "1 ")
            .replacingOccurrences(of: " of John ", with: " ")
    }

    /// Mirror of +[PSModuleController getCurrentBibleRef] — reads DefaultsLastRef,
    /// seeding "Genesis 1" the first time.
    static func getCurrentBibleRef() -> String {
        let defaults = UserDefaults.standard
        if let lastRef = defaults.string(forKey: Defaults.lastRef) {
            return lastRef
        }
        defaults.set("Genesis 1", forKey: Defaults.lastRef)
        defaults.synchronize()
        return "Genesis 1"
    }
}
