//
//  PSSearchResult.swift
//  PocketSword
//
//  A single FTS5 search hit: the verse reference plus the raw snippet string
//  (with [[HL]]…[[/HL]] delimiters the UI renders). In-memory only; never
//  persisted.
//

import Foundation

@objc(PSSearchResult)
final class PSSearchResult: NSObject {

    @objc var reference: String

    /// Full plain-text of the verse, exactly as stored in FTS5's text_plain column.
    @objc var fullText: String?

    /// For Strong's searches, the English surface word(s) in this verse that mapped
    /// to the searched Strong's number(s). nil for text searches. Order-preserving
    /// and de-duped, as plain words: the markup the index stores around the
    /// divine name is taken off (`PSSearchEngine.surfaceWords`). The result row
    /// marks them as whole words.
    @objc var strongsHighlightWords: [String]?

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
