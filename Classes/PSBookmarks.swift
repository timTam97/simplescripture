//
//  PSBookmarks.swift
//  PocketSword
//
//  CRITICAL — the on-disk PSBookmarks.plist positional-array schema is locked
//  BYTE-FOR-BYTE by PersistedFormatTests:
//    WRITE  parseBookmarkObject:
//             folder   -> [name, dateAdded, dateLastAccessed, "YES", rgb-or-"", children] (6)
//             bookmark -> [name, dateAdded, dateLastAccessed, "NO", ref] (5)
//    READ   parseArray:
//             idx3 via boolValue selects folder/bookmark;
//             folder reads rgb@4 (""->nil) + children@5; bookmark reads ref@4.
//  The "YES"/"NO" are LITERAL STRINGS (not booleans). Do NOT tidy the asymmetry.
//

import Foundation

@objc(PSBookmarks)
class PSBookmarks: PSBookmarkFolder {

    // MARK: - Singleton

    private static var psDefaultBookmarks: PSBookmarks?

    /// The singleton instance (`PSBookmarks.default()`).
    @objc(defaultBookmarks)
    class func `default`() -> PSBookmarks {
        if psDefaultBookmarks == nil {
            psDefaultBookmarks = PSBookmarks(localBookmarks: ())
        }
        return psDefaultBookmarks!
    }

    // MARK: - Init

    @objc(initLocalBookmarks)
    init(localBookmarks: ()) {
        super.init(name: nil, dateAdded: nil, dateLastAccessed: nil, rgbHexString: nil, children: nil)
        self.name = NSLocalizedString("BookmarksTitle", comment: "")
        let bookmarksPath = (AppPaths.bookmarksPath as NSString).appendingPathComponent("PSBookmarks.plist")
        let dataArray = NSArray(contentsOfFile: bookmarksPath) as? [Any]
        loadBookmarks(fromArray: dataArray)
    }

    @objc(initCloudBookmarks)
    init(cloudBookmarks: ()) {
        super.init(name: nil, dateAdded: nil, dateLastAccessed: nil, rgbHexString: nil, children: nil)
        self.name = NSLocalizedString("BookmarksTitle", comment: "")
        let data = "plistStringToCreateADataThingo".data(using: .utf8)!
        // format should be NSPropertyListXMLFormat_v1_0
        let array = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        loadBookmarks(fromArray: array as? [Any])
    }

    // MARK: - Add / delete

    @objc(addBookmarkObject:withFolderString:)
    class func addBookmarkObject(_ bookmark: PSBookmarkObject, withFolderString folderString: String?) -> Bool {
        var ret = false
        let bookmarks = PSBookmarks.default()
        if folderString == nil || folderString == "" {
            bookmarks.addChild(bookmark)
            ret = true
        } else {
            let parentFolder = PSBookmarks.getBookmarkFolder(forFolderString: folderString)
            parentFolder.addChild(bookmark)
            ret = true
        }
        PSBookmarks.saveBookmarksToFile()
        return ret
    }

    @objc(addBookmarkWithRef:name:folderString:)
    class func addBookmark(withRef r: String?, name n: String?, folderString: String?) -> Bool {
        let date = Date()
        let bookmark = PSBookmark(name: n, dateAdded: date, dateLastAccessed: date, bibleReference: r)
        return PSBookmarks.addBookmarkObject(bookmark, withFolderString: folderString)
    }

    @objc(deleteBookmark:fromFolderString:)
    class func deleteBookmark(_ n: String, fromFolderString folderString: String?) {
        let parent = PSBookmarks.getBookmarkFolder(forFolderString: folderString)
        var array: [Any] = parent.children ?? []
        // need to identify which is the correct child
        for (idx, element) in array.enumerated() {
            if let obj = element as? PSBookmarkObject, obj.name == n {
                array.remove(at: idx)
                break
            }
        }
        parent.children = array
        PSBookmarks.saveBookmarksToFile()
    }

    // MARK: - Lookups

    /// Resolves the `:::`-joined NAME path the bookmark editor's folder picker hands
    /// to `addBookmark` (`BookmarkFolderPath`), walking down from the root.
    ///
    /// Two rules. Each filed bookmarks in the root, silently, when it was looser:
    ///
    ///  - **Only nil / "" mean the root.** The root's own title ("Bookmarks") is not
    ///    compared: a top-level folder may be called that, and its path is then
    ///    exactly the title. No caller passes the title to mean the root (the picker
    ///    tags the root row nil), and with no such folder the walk falls back to the
    ///    root anyway.
    ///  - **A component matches a FOLDER of that name, never a bookmark.** Folders
    ///    are appended, so a bookmark described "Prayer" sits before a folder
    ///    "Prayer" created later; matched by name alone, the bookmark ended the walk
    ///    without descending, and the rest of the path was looked up in the wrong
    ///    parent.
    ///
    /// Pinned by `testBookmarkFolderPathResolvesToTheFolderItNames`.
    ///
    /// It is still a walk by name, so two paths resolve to the root that should not:
    /// a top-level folder with an EMPTY name has the path "", and a folder whose name
    /// ends in ":" splits in the wrong place once it has a subfolder ("Notes:" holding
    /// "Kid" is "Notes::::Kid"). Closing those means addressing the folder by identity.
    @objc(getBookmarkFolderForFolderString:)
    class func getBookmarkFolder(forFolderString folderString: String?) -> PSBookmarkFolder {
        let bookmarks = PSBookmarks.default()
        if folderString == nil || folderString == "" {
            return bookmarks
        }
        let folders = folderString!.components(separatedBy: AppConstants.folderSeparatorString)
        var parentFolder: PSBookmarkFolder = bookmarks
        for folderCount in 0..<folders.count {
            var foundFolder = false
            let kids = parentFolder.children ?? []
            for kidNumber in 0..<kids.count {
                if let folderKid = kids[kidNumber] as? PSBookmarkFolder, folderKid.name == folders[folderCount] {
                    parentFolder = folderKid
                    foundFolder = true
                    break
                }
            }
            if !foundFolder {
                // if we don't find the next folder, just place the bookmark here. This shouldn't be possible!
                alog("getBookmarkFolderForFolderString: couldn't find the folder - \(folders[folderCount])")
                break
            }
        }
        return parentFolder
    }

    @objc(getHighlightRGBColourStringForBookAndChapterRef:withVerse:)
    class func getHighlightRGBColourString(forBookAndChapterRef bookAndChapterRef: String, withVerse verse: Int) -> String? {
        // Changed to %ld and casting to "long" in order to compensate for 64bit "long" version of NSInteger.
        return PSBookmarks.default().getHighlightRGBColourString(forBookAndChapterRef: bookAndChapterRef,
                                                                 withVerse: String(format: "%ld", verse))
    }

    @objc(getBookmarksForCurrentRef)
    class func getBookmarksForCurrentRef() -> NSMutableArray {
        let currentRef = PSRefHelper.createRefString(PSRefHelper.getCurrentBibleRef())
        return PSBookmarks.getBookmarks(forBookAndChapterRef: currentRef)
    }

    @objc(getBookmarksForBookAndChapterRef:)
    class func getBookmarks(forBookAndChapterRef bookAndChapterRef: String) -> NSMutableArray {
        let bookmarks = PSBookmarks.default()
        return bookmarks.getBookmarks(forBookAndChapterRef: bookAndChapterRef)
    }

    // MARK: - Positional-array (de)serialization (schema-locked)

    @objc(parseArray:)
    func parseArray(_ array: [Any]?) -> PSBookmarkObject? {
        guard let array = array, array.count != 0 else {
            return nil
        }

        let n = array[0] as? String
        let da = array[1] as? Date
        let dla = array[2] as? Date
        let folderString = array[3] as? String
        if (folderString as NSString?)?.boolValue ?? false {
            // tis a folder
            var rgb = array[4] as? String
            if rgb == "" {
                rgb = nil
            }
            let kids = array[5] as? [Any] ?? []
            var kidsArray: [Any] = []
            for child in kids {
                if let kid = parseArray(child as? [Any]) {
                    kidsArray.append(kid)
                }
            }
            return PSBookmarkFolder(name: n, dateAdded: da, dateLastAccessed: dla, rgbHexString: rgb, children: kidsArray)
        } else {
            // tis a bookmark
            let r = array[4] as? String
            return PSBookmark(name: n, dateAdded: da, dateLastAccessed: dla, bibleReference: r)
        }
    }

    private func loadBookmarks(fromArray dataArray: [Any]?) {
        var kidsArray: [Any] = []
        if let dataArray = dataArray {
            for child in dataArray {
                if let kid = parseArray(child as? [Any]) {
                    kidsArray.append(kid)
                }
            }
            self.children = kidsArray
        } else {
            self.children = []
        }
    }

    @objc(parseBookmarkObject:)
    class func parseBookmarkObject(_ bookmarkObject: PSBookmarkObject?) -> NSArray? {
        guard let bookmarkObject = bookmarkObject else {
            return nil
        }
        let capacity = bookmarkObject.folder ? 7 : 5
        let ret = NSMutableArray(capacity: capacity)
        ret.add(bookmarkObject.name as Any)
        ret.add(bookmarkObject.dateAdded as Any)
        ret.add(bookmarkObject.dateLastAccessed as Any)
        if bookmarkObject.folder {
            ret.add("YES")
            if let folder = bookmarkObject as? PSBookmarkFolder, let rgb = folder.rgbHexString {
                ret.add(rgb)
            } else {
                ret.add("")
            }
            let folder = bookmarkObject as? PSBookmarkFolder
            let folderChildren = folder?.children ?? []
            let kids = NSMutableArray(capacity: folderChildren.count)
            for case let child as PSBookmarkObject in folderChildren {
                if let kid = PSBookmarks.parseBookmarkObject(child) {
                    kids.add(kid)
                }
            }
            ret.add(kids)
        } else {
            ret.add("NO")
            if let bookmark = bookmarkObject as? PSBookmark {
                ret.add(bookmark.ref as Any)
            }
        }
        return ret
    }

    // MARK: - lastModified

    class func lastModified(_ bookmarkObject: PSBookmarkObject) -> Date? {
        // Deliberate quirk: compares the recursive childDate but assigns
        // child.dateLastAccessed (not childDate).
        var returnDate = bookmarkObject.dateLastAccessed
        if bookmarkObject.folder, let folder = bookmarkObject as? PSBookmarkFolder {
            for case let child as PSBookmarkObject in (folder.children ?? []) {
                let childDate = PSBookmarks.lastModified(child)
                if let childDate = childDate, let rd = returnDate,
                   childDate.compare(rd) == .orderedDescending {
                    returnDate = child.dateLastAccessed
                }
            }
        }
        return returnDate
    }

    @objc(lastModified)
    class func lastModified() -> Date? {
        let bookmarks = PSBookmarks.default()
        return PSBookmarks.lastModified(bookmarks)
    }

    // MARK: - Persistence

    @objc(saveBookmarksToFile)
    @discardableResult
    class func saveBookmarksToFile() -> Bool {
        let bookmarks = PSBookmarks.default()
        var ret = false
        let bookmarksPath = (AppPaths.bookmarksPath as NSString).appendingPathComponent("PSBookmarks.plist")
        if let children = bookmarks.children, children.count > 0 {
            let data = NSMutableArray(capacity: children.count)
            for case let child as PSBookmarkObject in children {
                if let kid = PSBookmarks.parseBookmarkObject(child) {
                    data.add(kid)
                }
            }
            ret = data.write(toFile: bookmarksPath, atomically: true)
        } else {
            // no bookmarks left! Write out the file to zeros...
            let data = NSMutableArray(capacity: 1)
            ret = data.write(toFile: bookmarksPath, atomically: false)
        }
        dlog("\n-- Bookmarks: finished saveBookmarksToFile")
        return ret
    }

    @objc(importBookmarksFromV2)
    class func importBookmarksFromV2() {
        let oldBookmarks = UserDefaults.standard.array(forKey: "bookmarks2")
        guard let oldBookmarks = oldBookmarks else {
            return
        }
        let bookmarks = PSBookmarks.default()
        var createImportedFolder = true
        for case let obj as PSBookmarkObject in (bookmarks.children ?? []) {
            if obj.name == NSLocalizedString("BookmarksImportedFolderName", comment: "") {
                // if there already exists an @"imported" folder, don't recreate it!
                createImportedFolder = false
                break
            }
        }
        if createImportedFolder {
            let importFolder = PSBookmarkFolder(name: NSLocalizedString("BookmarksImportedFolderName", comment: ""),
                                                dateAdded: Date(),
                                                dateLastAccessed: Date(),
                                                rgbHexString: nil,
                                                children: nil)
            _ = PSBookmarks.addBookmarkObject(importFolder, withFolderString: nil)
        }
        for case let ref as String in oldBookmarks {
            _ = PSBookmarks.addBookmark(withRef: PSRefHelper.createRefString(ref),
                                        name: ref,
                                        folderString: NSLocalizedString("BookmarksImportedFolderName", comment: ""))
        }
        UserDefaults.standard.removeObject(forKey: "bookmarks2")
        UserDefaults.standard.synchronize()
    }
}
