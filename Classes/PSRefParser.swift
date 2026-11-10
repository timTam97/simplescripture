//
//  PSRefParser.swift
//  PocketSword
//
//  Free-text reference parser for the one input the app does not generate
//  itself (inbound `sword://` URLs). Reads the `PSBookOSISResolver` table but is
//  kept separate from it: the resolver is on the reader's hot path and pinned by
//  tests; the parser is a consumer.
//
//  ## Grammar
//
//      <book> [ <chapter> [ ":" <verse> [ "-" <verse> ] ] ]
//
//  `<book>` is any of the seven spellings per book the resolver indexes
//  ("Genesis", "Gen", "1 Corinthians", "I Corinthians", "1Cor", "Jn", …),
//  case-insensitively, with an optional trailing "." after an abbreviation.
//  Verse and chapter default to 1 when absent. A range must be ascending and
//  inside the chapter.
//
//  A book on its own is a reference in every one of those spellings, the
//  unspaced numbered ones included: "1John" is 1 John 1:1, as "Jude" is
//  Jude 1:1. Only a string of nothing but digits, ":" and "-" ("3:16") is read
//  as having no book, and that needs a context book (below).
//
//  ## Deliberately out of scope
//
//  Bounded by what the app can actually receive; anything wider would be
//  untested production code:
//
//    - Lists ("Gen 1:1,3", "Gen 1:1; 2:4") and cross-book / cross-chapter
//      ranges. The `sword://` path truncates a list itself first
//      ("28-30" -> "28", "26,28;30" -> "26").
//    - Roman-numeral chapters ("Gen ii").
//    - A chapter run into the book name ("John3:16", "1John3:16"). The numbers
//      start at a space; the numbered books are why a digit cannot mark them.
//    - `ff` / trailing-letter suffixes ("Gen 1:1ff", "Gen 1:12a").
//    - `inscriptio` / `subscriptio`. No bundled module uses them.
//    - Localised book names. The app is English-only.
//    - Fuzzy or natural-language input.
//
//  `PSRefSemanticsTests`' exhaustive tier prints the abbreviation forms this
//  parser rejects but SWORD accepted, so that delta stays visible.
//
//  ## The parse context is always explicit
//
//  `parse(_:relativeTo:)` takes the book to resolve a bare chapter/verse
//  against; it never reads ambient state such as `getCurrentBibleRef()`.
//

import Foundation

/// A parsed single-book reference. `verse`/`endVerse` are always populated —
/// an absent verse spec means verse 1, matching `VerseKey`'s own default.
struct BibleReference: Equatable {
    let book: PSVersificationBook
    let chapter: Int
    let verse: Int
    /// The last verse of an inclusive range; equal to `verse` when there is no range.
    let endVerse: Int

    /// True when the source string carried a chapter number at all. False for a
    /// bare book name ("John"), where `chapter` is the default 1.
    ///
    /// The `sword://` path needs this so it never persists a chapter-less
    /// `lastRef` the reader cannot resolve. It cannot be inferred by looking for a
    /// digit — "1 John" has one and still has no chapter.
    let hadExplicitChapter: Bool

    /// True when the source string carried a ":" verse spec, so `verse` is
    /// something the caller asked for rather than the default. The `sword://` URL
    /// path keeps its own separately-derived verse position.
    let hadExplicitVerse: Bool

    var isRange: Bool { endVerse > verse }

    /// "Genesis 1" — the **munged `name`** form, which is what the app persists in
    /// `Defaults.lastRef` and keys history / bookmarks / headings on.
    var chapterRef: String { "\(book.name) \(chapter)" }

    /// "Genesis 1:1" / "Genesis 1:1-3".
    var displayRef: String {
        isRange ? "\(chapterRef):\(verse)-\(endVerse)" : "\(chapterRef):\(verse)"
    }

    static func == (lhs: BibleReference, rhs: BibleReference) -> Bool {
        lhs.book.osisName == rhs.book.osisName
            && lhs.chapter == rhs.chapter
            && lhs.verse == rhs.verse
            && lhs.endVerse == rhs.endVerse
            && lhs.hadExplicitChapter == rhs.hadExplicitChapter
            && lhs.hadExplicitVerse == rhs.hadExplicitVerse
    }
}

typealias PSParsedReference = BibleReference

struct PSRefParser {

    private let resolver: PSBookOSISResolver

    /// Fails only when the bundled versification table itself is unavailable —
    /// the same condition that makes the content reader decline.
    init?(resolver: PSBookOSISResolver? = PSBookOSISResolver.shared) {
        guard let resolver = resolver else { return nil }
        self.resolver = resolver
    }

    /// Parse a single-book reference.
    ///
    /// - Parameter relativeTo: the book a bare "3:16" or "3" resolves against.
    ///   Pass nil to require a book name in the string. Never read from ambient
    ///   state inside here — see the file header.
    /// - Returns: nil for anything the grammar above does not cover, for an
    ///   unknown book, or for a chapter/verse outside the versification. Never a
    ///   clamped or guessed result: a wrong ref renders plausible-but-wrong text,
    ///   which is worse than declining.
    func parse(_ input: String, relativeTo contextBook: PSVersificationBook? = nil) -> PSParsedReference? {
        // Normalise nonbreaking spaces and en/em dashes in pasted or typed refs.
        let normalised = input
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalised.isEmpty else { return nil }

        // Split off the numeric tail: everything from the last run of
        // "<space><digit>" onward. The book name may itself both start with a
        // digit ("1 Corinthians") and contain spaces ("Song of Solomon"), so
        // neither "split on the first space" nor "split on the first digit"
        // works — hence scanning from the right.
        let (bookPart, numericPart) = splitBookFromNumbers(normalised)

        let book: PSVersificationBook
        if bookPart.isEmpty {
            // No book name: a bare "3:16" against the caller's context.
            guard let contextBook = contextBook else { return nil }
            book = contextBook
        } else {
            // A trailing "." after an abbreviation ("Gen.", "1 Cor.") is not in
            // the resolver's index; strip it and retry.
            guard let resolved = resolveBook(bookPart) else { return nil }
            book = resolved
        }

        // "Genesis" alone -> chapter 1 verse 1, matching parseVerseList's
        // "if chapter is left off, use the default key" behaviour.
        guard !numericPart.isEmpty else {
            return PSParsedReference(book: book, chapter: 1, verse: 1, endVerse: 1,
                                     hadExplicitChapter: false, hadExplicitVerse: false)
        }

        return parseNumbers(numericPart, in: book)
    }

    // MARK: - Book name

    /// Resolve a book name through the table, then through two narrow fallbacks.
    ///
    /// Both fallbacks live here rather than in `PSBookOSISResolver`'s index because
    /// that index is pinned by `PSContentStoreTests` and is on the reader's hot
    /// path — the parser is allowed to be more permissive than the reader.
    private func resolveBook(_ part: String) -> PSVersificationBook? {
        if let book = resolver.book(named: part) { return book }

        // 1. A single trailing period after an abbreviation ("Gen.", "1 Cor.").
        if part.hasSuffix(".") {
            let trimmed = String(part.dropLast()).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, let book = resolveBook(trimmed) { return book }
        }

        // 2. Spaced abbreviations of the numbered books: "1 Cor", "2 Kgs",
        //    "1 Thess". The table carries only the unspaced form ("1Cor").
        //    Despacing is verified collision-free across all 66 books x 7
        //    spellings.
        let despaced = part.replacingOccurrences(of: " ", with: "")
        if despaced != part, !despaced.isEmpty, let book = resolver.book(named: despaced) {
            return book
        }
        return nil
    }

    /// Split "1 Corinthians 13:4" into ("1 Corinthians", "13:4").
    ///
    /// Scans right-to-left for the last space that is followed by a digit, and
    /// treats everything after it as the numeric part — but only if the remaining
    /// left side is non-empty, so "1 Corinthians" does not lose its "1". A string
    /// that is entirely numeric ("3:16") yields an empty book part.
    ///
    /// Entirely: digits, ":" and "-" and nothing else. Starting with a digit is
    /// not enough — the unspaced numbered books do ("1John", "1Cor", "2Kgs"), and
    /// read as a number spec they had no book, so a bare one was declined while
    /// "Jude" and "1 John" were not.
    private func splitBookFromNumbers(_ input: String) -> (String, String) {
        let chars = Array(input)
        if let first = chars.first, first.isNumber,
           chars.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "-" }) {
            // "3:16" / "3" / "3:16-18" — no book name at all.
            return ("", input)
        }
        var i = chars.count - 1
        var candidate: Int? = nil
        while i > 0 {
            if chars[i] == " ", i + 1 < chars.count, chars[i + 1].isNumber {
                let left = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                // Reject a split that would leave only a number on the left
                // ("1 Corinthians" split at its own space): a lone leading digit
                // group is part of the book name, not a chapter.
                if !left.isEmpty && !left.allSatisfy({ $0.isNumber }) {
                    candidate = i
                    break
                }
            }
            i -= 1
        }
        guard let split = candidate else { return (input, "") }
        return (String(chars[0..<split]).trimmingCharacters(in: .whitespaces),
                String(chars[(split + 1)...]).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Numbers

    /// "13", "13:4", "13:4-6" — and nothing else. Rejects rather than truncates:
    /// a caller that wants "the first verse of a list" must do that itself, the
    /// way the `sword://` path already does.
    private func parseNumbers(_ part: String, in book: PSVersificationBook) -> PSParsedReference? {
        let pieces = part.components(separatedBy: ":")
        guard pieces.count <= 2 else { return nil }

        guard let chapter = strictInt(pieces[0]),
              chapter >= 1, chapter <= book.chapterCount,
              let maxVerse = resolver.verseMax(book: book, chapter: chapter) else {
            return nil
        }

        guard pieces.count == 2 else {
            return PSParsedReference(book: book, chapter: chapter, verse: 1, endVerse: 1,
                                     hadExplicitChapter: true, hadExplicitVerse: false)
        }

        let versePart = pieces[1].trimmingCharacters(in: .whitespaces)
        let verseBounds = versePart.components(separatedBy: "-")
        guard verseBounds.count <= 2,
              let verse = strictInt(verseBounds[0]), verse >= 1, verse <= maxVerse else {
            return nil
        }

        var endVerse = verse
        if verseBounds.count == 2 {
            // In-chapter ascending range only. A descending or cross-chapter one
            // ("1:3-1", "1:31-2:3") is a shape the app cannot produce.
            guard let end = strictInt(verseBounds[1]), end >= verse, end <= maxVerse else {
                return nil
            }
            endVerse = end
        }

        return PSParsedReference(book: book, chapter: chapter, verse: verse,
                                 endVerse: endVerse, hadExplicitChapter: true,
                                 hadExplicitVerse: true)
    }

    /// Digits only. `Int(_:)` rejects "12a" and "1ff" but accepts a leading
    /// "+"/"-" and Unicode digits, so the character check is explicit.
    private func strictInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(trimmed)
    }
}
