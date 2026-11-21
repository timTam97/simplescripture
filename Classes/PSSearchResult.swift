//
//  PSSearchResult.swift
//  PocketSword
//
//  A single FTS5 search hit: the verse reference plus the verse's full text, as
//  the index stores it, which the UI marks itself. In-memory only; never
//  persisted.
//

import Foundation

@objc(PSSearchResult)
final class PSSearchResult: NSObject {

    @objc var reference: String

    /// Full plain-text of the verse, exactly as stored in FTS5's text_plain column.
    @objc var fullText: String?

    /// For a Strong's search, where `fullText` is marked: the words the verse's
    /// word map tags with the searched number, each at its own place, as UTF-16
    /// ranges (`NSRange`'s units). Empty for a text search.
    ///
    /// Places, not words: a word spelled like a tagged one is not marked
    /// unless the number tags it too (`PSSearchEngine.markStrongsWords`).
    var strongsMarks: [Range<Int>] = []

    /// For a Strong's search, the verse's canonical headings that hold a word
    /// the number tags — a Psalm's title, which `fullText` does not have —
    /// with their marks. Empty for a text search and for every verse whose
    /// title holds no such word.
    var strongsHeadings: [PSMarkedText] = []

    @objc(initWithReference:fullText:)
    init(reference: String, fullText: String?) {
        self.reference = reference
        self.fullText = fullText
        super.init()
    }

    @objc(resultWithReference:fullText:)
    class func result(withReference reference: String, fullText: String?) -> PSSearchResult {
        return PSSearchResult(reference: reference, fullText: fullText)
    }
}

/// A text and where a search marks it: a Psalm's title as a Strong's result
/// row shows it (`PSSearchResult.strongsHeadings`). The marks are UTF-16
/// ranges of `text`.
struct PSMarkedText: Equatable {
    let text: String
    let marks: [Range<Int>]
}
