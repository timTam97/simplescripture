//
//  PSSearchQuery.swift
//  PocketSword
//
//  Translates user-typed search input into an FTS5 MATCH expression. Handles:
//    * quoted "phrases", in straight or typographic (“…”) quotes
//    * All (AND) / Any (OR) / Exact (whole-input phrase) match types
//    * Fuzzy toggle (suffix '*' on each non-phrase word; a term with
//      punctuation inside it, like Beer-sheba, is matched as typed)
//    * Strong's toggle (H0xxx / Hxxx equivalence under a lemmas: column filter)
//    * Diacritic folding so accented input matches unaccented storage
//
//  Also home to the two index-side text rules, `foldForIndex` and
//  `cleanDisplayText`, shared by the index build (PSSearchEngine.swift) and the
//  query/display path. Both must stay compatible with the `text_norm` column of
//  every index already built on a user's device; any drift silently breaks
//  search matching. Pinned by PSSearchIndexParityTests.
//

import Foundation

@objc(PSSearchQuery)
final class PSSearchQuery: NSObject {

    // MARK: - Folding

    /// Fold diacritics for storage/query normalisation: NFD -> drop combining-mark
    /// ranges -> NFC -> lowercase. The single copy used by both the stored
    /// `text_norm` column and the query parser. Pinned by
    /// `PSSearchIndexParityTests.testFoldForIndexHandlesEveryTargetedRange`.
    @objc(foldForIndex:)
    class func foldForIndex(_ s: String) -> String {
        if s.isEmpty { return "" }
        // NFD, then strip:
        //  * Hebrew points + cantillation (U+0591–U+05C7) — FTS5's
        //    remove_diacritics=2 doesn't touch these.
        //  * Generic Unicode combining marks (U+0300–U+036F, U+1AB0–U+1AFF,
        //    U+1DC0–U+1DFF, U+20D0–U+20FF, U+FE20–U+FE2F) — catches Greek
        //    polytonic accents and anything else that slipped past unicode61.
        let decomposed = Array(s.decomposedStringWithCanonicalMapping.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(decomposed.count)
        var i = 0
        let n = decomposed.count
        while i < n {
            let c = decomposed[i]
            let drop =
                (c >= 0x0300 && c <= 0x036F) ||
                (c >= 0x0591 && c <= 0x05C7) ||
                (c >= 0x1AB0 && c <= 0x1AFF) ||
                (c >= 0x1DC0 && c <= 0x1DFF) ||
                (c >= 0x20D0 && c <= 0x20FF) ||
                (c >= 0xFE20 && c <= 0xFE2F)
            if !drop {
                if UTF16.isLeadSurrogate(c) && i + 1 < n {
                    out.append(c)
                    out.append(decomposed[i + 1])
                    i += 2
                    continue
                }
                out.append(c)
            }
            i += 1
        }
        let assembled = String(utf16CodeUnits: out, count: out.count)
        return assembled.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Display cleaning

    // Compiled once. The patterns are constants and always compile; the guards
    // at each use only mean a broken pattern skips a step instead of trapping.
    private static let markerRe = try? NSRegularExpression(
        pattern: "<[A-Z][A-Z0-9]*\\d[A-Z0-9-]*>", options: [])
    private static let wsRe = try? NSRegularExpression(pattern: "\\s+", options: [])
    private static let wsBeforePunctRe = try? NSRegularExpression(
        pattern: "\\s+([,.;:!?\\)\\]])", options: [])

    /// Strip the inline Strong's / morph markers (e.g. `<H0430>`, `<TH8799>`) and
    /// the `" [] "` empty-tag marker from stored plain text, collapsing any
    /// whitespace the removal left behind — including a space stranded just before
    /// punctuation (e.g. `"field ,"`).
    ///
    /// **Load-bearing beyond display.** `PSSearchEngine`'s build loop applies it
    /// *before* the emptiness test, so it decides which rows exist in the index.
    /// The three regexes, their order and the trim must not change.
    ///
    /// Uses `NSMutableString` deliberately: `NSRegularExpression`'s replace-in-place
    /// API works in UTF-16 offsets, and redoing it over `String.Index` would be a
    /// different algorithm.
    class func cleanDisplayText(_ plain: String) -> String {
        if plain.isEmpty { return "" }
        let out = NSMutableString(string: plain)
        if let markerRe {
            markerRe.replaceMatches(in: out, options: [],
                                    range: NSRange(location: 0, length: out.length),
                                    withTemplate: " ")
        }
        out.replaceOccurrences(of: " [] ", with: " ", options: [],
                               range: NSRange(location: 0, length: out.length))
        if let wsRe {
            wsRe.replaceMatches(in: out, options: [],
                                range: NSRange(location: 0, length: out.length),
                                withTemplate: " ")
        }
        if let wsBeforePunctRe {
            wsBeforePunctRe.replaceMatches(in: out, options: [],
                                           range: NSRange(location: 0, length: out.length),
                                           withTemplate: "$1")
        }
        return (out as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tokenisation

    private struct PSToken {
        let text: String  // the phrase/word content, never contains quote chars
        let isPhrase: Bool // true if user wrapped it in "…"
    }

    // Tiny scanner: splits whitespace-separated tokens, keeping "quoted phrases"
    // as single atoms. Unterminated quotes are treated as running to end of input.
    // Only U+0022 is a quote here: the caller straightens typographic ones first
    // (`straighteningQuotes`).
    private static func tokenise(_ raw: String) -> [PSToken] {
        var tokens: [PSToken] = []
        let chars = Array(raw.utf16)
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == 0x20 || c == 0x09 || c == 0x0A { // space, tab, newline
                i += 1
                continue
            }

            if c == 0x22 { // '"'
                i += 1
                let start = i
                while i < n && chars[i] != 0x22 { i += 1 }
                let phrase = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
                if i < n { i += 1 } // skip closing quote
                if !phrase.isEmpty {
                    tokens.append(PSToken(text: phrase, isPhrase: true))
                }
            } else {
                let start = i
                while i < n {
                    let ch = chars[i]
                    if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x22 { break }
                    i += 1
                }
                let word = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
                if !word.isEmpty {
                    tokens.append(PSToken(text: word, isPhrase: false))
                }
            }
        }
        return tokens
    }

    /// `s` with the four typographic double quotes — U+201C “, U+201D ”,
    /// U+201E „ and U+201F ‟ — replaced by the straight U+0022, the only quote
    /// `tokenise` and the Exact arm recognise.
    ///
    /// Smart Punctuation turns a typed `"` into one of these wherever it is in
    /// effect, and pasted text carries them regardless. Taken for word
    /// characters, they made a quoted phrase in All or Any mode run as its
    /// separate words, with the quotes stuck to the first and last of them.
    ///
    /// Straightening cannot lose a match: the index's tokenizer (`unicode61`)
    /// treats all four as separators, so none is ever part of an indexed term.
    /// Per scalar, as `tokenise` scans per unit: a curly quote is a quote
    /// whatever follows it.
    ///
    /// Query-side only, and for a copy: never write the result back over what
    /// the user typed. The search field is bound to that text and the saved
    /// history stores it. `SearchModel.highlightTerms` applies the same mapping,
    /// so the highlight and the query agree on what a phrase is.
    class func straighteningQuotes(_ s: String) -> String {
        let straight: Unicode.Scalar = "\""
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x201C, 0x201D, 0x201E, 0x201F:
                out.append(straight)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Escaping

    // Escape a token for use inside an FTS5 phrase: double any embedded quotes
    // and wrap in "…". Phrase syntax accepts any characters literally, which
    // side-steps the need to strip operator keywords like AND/OR/NEAR.
    //
    // `.literal` is load-bearing. Without it the replace compares whole composed
    // characters, and a quote followed by a combining or variation-selector
    // scalar (`"` + U+FE0F, `"` + U+0301) is one character that is not `"`. It
    // went through undoubled and ended the FTS5 string early: the MATCH failed
    // with "unterminated string", which the user sees as "No Results". Both arms
    // that hand over unscanned text can carry one — Exact (its body is folded,
    // but the fold leaves U+FE0F and others) and Strong's (tokens are not folded
    // at all). All and Any cannot: `tokenise` removes every quote first.
    private static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"", options: .literal)
        return "\"\(escaped)\""
    }

    private static func isStrongsNumber(_ s: String) -> (isStrongs: Bool, prefix: Character) {
        let units = Array(s.utf16)
        if units.count < 2 { return (false, "\0") }
        let p = units[0]
        if p != UInt16(UnicodeScalar("H").value) && p != UInt16(UnicodeScalar("G").value)
            && p != UInt16(UnicodeScalar("h").value) && p != UInt16(UnicodeScalar("g").value) {
            return (false, "\0")
        }
        for idx in 1..<units.count {
            let c = units[idx]
            if c < UInt16(UnicodeScalar("0").value) || c > UInt16(UnicodeScalar("9").value) {
                return (false, "\0")
            }
        }
        let prefix: Character = (p == UInt16(UnicodeScalar("h").value) || p == UInt16(UnicodeScalar("H").value)) ? "H" : "G"
        return (true, prefix)
    }

    // For an H-prefixed Strong's number, return the OTHER form (H0430 ↔ H430).
    // Returns nil if the input is G-prefixed or already ambiguous.
    private static func alternateHebrewForm(_ s: String) -> String? {
        if s.count < 2 { return nil }
        let first = s[s.startIndex]
        if first != "H" && first != "h" { return nil }
        let digits = String(s[s.index(s.startIndex, offsetBy: 1)...])
        if digits.hasPrefix("0") {
            return "H" + String(digits.dropFirst())
        }
        return "H0" + digits
    }

    // MARK: - Expression builder

    /// Build an FTS5 MATCH expression for the given user input. Returns nil for
    /// trivial input (empty / pure whitespace / just quotes).
    @objc(fts5ExpressionFromUserInput:matchType:fuzzy:strongs:)
    class func fts5Expression(fromUserInput raw: String,
                              matchType: PSSearchType,
                              fuzzy: Bool,
                              strongs: Bool) -> String? {
        if raw.isEmpty { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Strong's mode: short-circuit — every whitespace-separated token is
        // treated as a Strong's number and mapped to the lemmas: column with
        // H0/H equivalence. Non-conforming tokens pass through as plain terms.
        if strongs {
            let parts = trimmed.components(separatedBy: .whitespaces)
            var ors: [String] = []
            for tok in parts {
                if tok.isEmpty { continue }
                let (isStrongs, prefix) = isStrongsNumber(tok)
                if isStrongs {
                    let upper = String(prefix) + String(tok.dropFirst())
                    if let alt = alternateHebrewForm(upper) {
                        ors.append("(\(quote(upper)) OR \(quote(alt)))")
                    } else {
                        ors.append(quote(upper))
                    }
                } else {
                    ors.append(quote(tok))
                }
            }
            if ors.isEmpty { return nil }
            // Join with OR so a multi-number Strong's query (rare but possible)
            // matches any of them. Constrain to the lemmas column.
            let joined = ors.joined(separator: " OR ")
            return "lemmas:(\(joined))"
        }

        // Typographic quotes are phrase quotes from here on (see
        // `straighteningQuotes`). Below the Strong's arm on purpose: that arm
        // takes no phrases and is left exactly as it was.
        let text = straighteningQuotes(trimmed)

        // Exact mode: treat the whole raw input as a single phrase (strip any
        // surrounding quotes the user typed so we don't double-wrap).
        if matchType == .ExactSearch {
            var body = text
            if body.hasPrefix("\"") && body.hasSuffix("\"") && body.count >= 2 {
                body = String(body.dropFirst().dropLast())
            }
            if body.isEmpty { return nil }
            let folded = foldForIndex(body)
            return "text_norm:\(quote(folded))"
        }

        // All / Any modes: tokenise, fold each non-phrase, apply fuzzy if set.
        let tokens = tokenise(text)
        if tokens.isEmpty { return nil }

        var atoms: [String] = []
        for tk in tokens {
            let folded = foldForIndex(tk.text)
            if folded.isEmpty { continue }
            if tk.isPhrase {
                // Quoted phrases always match as a phrase, regardless of fuzzy.
                atoms.append("text_norm:\(quote(folded))")
            } else if fuzzy {
                // Prefix match: word*, for a token that is one word — a single
                // run of letters and digits, whatever punctuation is around it
                // (`God,`, `(God)`, `sons'`).
                //
                // A token with punctuation INSIDE it (`Beer-sheba`, `God’s`) is
                // matched as typed instead, exactly as with Fuzzy off. The
                // index's tokenizer splits at that punctuation, so the text
                // holds `beer` + `sheba` and `god` + `s`. With the halves glued
                // into one prefix, `beersheba*` found nothing (33 verses with
                // Fuzzy off) and `gods*` listed the plural in place of the
                // possessive. Not FTS5's phrase-prefix form (`"lord’s" *`)
                // either: its prefix lands on the `s`, and that matched 921
                // verses where the phrase matches 131.
                //
                // The quoted phrase is also what a token with no letter or
                // digit in it (`--`) gets.
                if let bare = barewordForPrefix(folded) {
                    atoms.append("text_norm:\(bare)*")
                } else {
                    atoms.append("text_norm:\(quote(folded))")
                }
            } else {
                atoms.append("text_norm:\(quote(folded))")
            }
        }
        if atoms.isEmpty { return nil }

        let joiner = (matchType == .OrSearch) ? " OR " : " AND "
        return atoms.joined(separator: joiner)
    }

    /// Extract the canonicalised Strong's numbers from raw user input. Each valid
    /// H/G entry is upper-cased and included; H-numbers also include their alternate
    /// form (H0430 ↔ H430). Other input is ignored. The result matches what the
    /// Strong's-mode query injects, so it can filter the stored word_map.
    @objc(strongsTokensFromUserInput:)
    class func strongsTokens(fromUserInput raw: String) -> [String] {
        if raw.isEmpty { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let parts = trimmed.components(separatedBy: .whitespaces)
        var out: [String] = []
        var seen = Set<String>()
        for tok in parts {
            if tok.isEmpty { continue }
            let (isStrongs, prefix) = isStrongsNumber(tok)
            if !isStrongs { continue }
            let upper = String(prefix) + String(tok.dropFirst())
            if !seen.contains(upper) { seen.insert(upper); out.append(upper) }
            if let alt = alternateHebrewForm(upper), !seen.contains(alt) {
                seen.insert(alt); out.append(alt)
            }
        }
        return out
    }

    // The bareword for FTS5 prefix syntax (`word*`): the token's one run of
    // unicode letters and digits, without the punctuation around it. Nil when
    // there is no such run, or more than one — something that is not a letter
    // or digit INSIDE the word — and the caller quotes the token as typed (see
    // the fuzzy arm of `fts5Expression`).
    private static func barewordForPrefix(_ s: String) -> String? {
        // Deliberately per UTF-16 unit: surrogate halves of a non-BMP char are
        // individually rejected. CharacterSet.contains(_:UnicodeScalar) would differ
        // for non-BMP scalars. So a non-BMP char ends the run as punctuation does.
        let ok = NSCharacterSet.alphanumerics as NSCharacterSet
        var out: [UInt16] = []
        var runEnded = false
        for c in s.utf16 {
            if ok.characterIsMember(c) {
                if runEnded { return nil } // a second run
                out.append(c)
            } else if !out.isEmpty {
                runEnded = true
            }
        }
        return out.isEmpty ? nil : String(utf16CodeUnits: out, count: out.count)
    }
}
