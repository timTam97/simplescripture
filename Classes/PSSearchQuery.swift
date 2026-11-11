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
//    * ae / æ: a term with either is searched in both spellings, so a typed
//      Caesar finds the KJV's Cæsar
//
//  Also home to the two index-side text rules, `foldForIndex` and
//  `cleanDisplayText`, shared by the index build (PSSearchEngine.swift) and the
//  query/display path. Both must stay compatible with the `text_norm` column of
//  every index already built on a user's device; any drift silently breaks
//  search matching. Pinned by PSSearchIndexParityTests.
//
//  And to what a search highlights. The text arms are read once (`textTerms`),
//  into terms that `fts5Expression` renders and `highlightTerms(fromUserInput:…)`
//  hands to the highlighters, and `highlightRanges(of:in:)` says where a term is
//  in a text: on whole index tokens, as FTS5 matched it. The result row and the
//  reader both ask it.
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
    /// history stores it. The highlight terms come out of the same reading of
    /// the input (`textTerms`), so the highlight and the query agree on what a
    /// phrase is.
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

    // MARK: - Spellings

    /// `term`, followed by its other spelling when it has an "ae" or an æ in
    /// it: the one with every `ae` joined into the ligature, and the one with
    /// every ligature split into `ae`. A term with neither comes back alone.
    ///
    /// The KJV prints Cæsar, Judæa, Zacchæus and eleven other words with the
    /// ligature — 96 times, in 86 verses — and a few of them, now and then,
    /// without it. Nobody types æ, and nothing on the index side turns it into
    /// `ae`: it has no decomposition, so `foldForIndex` keeps it and the
    /// tokenizer's `remove_diacritics` does too. `text_norm` holds `cæsar`. A
    /// typed `Caesar` found 2 of the 24 verses, and not "Render therefore unto
    /// Cæsar"; `Judaea` found 12 of 43; `Zacchaeus` found none.
    ///
    /// So the query asks for both spellings (`textTerms`, ORed by
    /// `fts5Expression`). It has to be the query:
    /// the index rules are pinned by every index already built on a device.
    /// Any term with an "ae" gets the second spelling, Israel and Michael
    /// included. `isræl` is in no verse, and the rows such a search returns are
    /// the ones it returned without it (measured: 2,301 and 15).
    ///
    /// All or nothing: a phrase is tried with every `ae` joined and with every
    /// æ split, not in each mixture of the two. Luke 3:1 is the one verse with
    /// both spellings in it (`Cæsar … Judæa … Ituraea`).
    ///
    /// Each spelling is also a highlight term (`highlightTerms(fromUserInput:…)`):
    /// the highlighters do not take `ae` for `æ` any more than the index does,
    /// and need the second spelling to mark what the query found.
    ///
    /// Case-insensitive, though every caller now passes folded text.
    /// `.literal`, as in `quote`: scalar by scalar, whatever mark follows.
    class func ligatureSpellings(_ term: String) -> [String] {
        let options: String.CompareOptions = [.literal, .caseInsensitive]
        var out = [term]
        let joined = term.replacingOccurrences(of: "ae", with: "\u{00E6}", options: options)
        if joined != term { out.append(joined) }
        let split = term.replacingOccurrences(of: "\u{00E6}", with: "ae", options: options)
        if split != term, !out.contains(split) { out.append(split) }
        return out
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

        // Every other arm: the terms of the text query, each rendered as one
        // operand — its spellings, ORed inside parentheses when it has more
        // than one (an ae / æ word). The parentheses keep the group a single
        // operand of the AND / OR join around it. A term with one spelling
        // comes out as that spelling and nothing else.
        //
        // An Exact search is one term, so the join adds nothing to it.
        guard let terms = textTerms(trimmed, matchType: matchType, fuzzy: fuzzy) else {
            return nil
        }
        let atoms = terms.map { spellings -> String in
            let parts = spellings.map(\.expression)
            if parts.count == 1 { return parts[0] }
            return "(" + parts.joined(separator: " OR ") + ")"
        }
        let joiner = (matchType == .OrSearch) ? " OR " : " AND "
        return atoms.joined(separator: joiner)
    }

    /// One spelling of one term of a text query, as FTS5 is asked for it: the
    /// phrase `text_norm:"text"`, or the prefix `text_norm:text*`.
    private struct Spelling {
        /// Folded. For a prefix, the bareword (`barewordForPrefix`).
        let text: String
        let isPrefix: Bool

        var expression: String {
            isPrefix ? "text_norm:\(text)*" : "text_norm:\(PSSearchQuery.quote(text))"
        }
    }

    /// The terms of a text query — every arm of `fts5Expression` but Strong's:
    /// one entry per word or phrase, in the order typed, each with its
    /// spellings (`ligatureSpellings`). Nil for input that makes no query.
    ///
    /// **The one reading of the input.** `fts5Expression` renders these into
    /// the MATCH expression and `highlightTerms(fromUserInput:…)` hands the
    /// same list to the highlighters, so what is marked cannot drift from what
    /// was asked. The highlight terms used to be worked out a second time in
    /// `SearchModel`, by a copy of these rules kept in step by hand, and each
    /// rule the copy lacked was a search that found its verses and marked
    /// nothing: the Exact arm's trim, the quotes it strips, typographic
    /// quotes, the ae / æ spellings.
    ///
    /// `trimmed` is the user's input with the whitespace at its ends removed,
    /// and not empty.
    private static func textTerms(_ trimmed: String,
                                  matchType: PSSearchType,
                                  fuzzy: Bool) -> [[Spelling]]? {
        // Typographic quotes are phrase quotes from here on (see
        // `straighteningQuotes`). Not applied to the Strong's arm, which takes
        // no phrases and is left exactly as it was.
        let text = straighteningQuotes(trimmed)

        // Exact mode: treat the whole raw input as a single phrase (strip any
        // surrounding quotes the user typed so we don't double-wrap). Never a
        // prefix: this arm ignores Fuzzy.
        if matchType == .ExactSearch {
            var body = text
            if body.hasPrefix("\"") && body.hasSuffix("\"") && body.count >= 2 {
                body = String(body.dropFirst().dropLast())
            }
            if body.isEmpty { return nil }
            let folded = foldForIndex(body)
            return [ligatureSpellings(folded).map { Spelling(text: $0, isPrefix: false) }]
        }

        // All / Any modes: tokenise, fold each token, apply fuzzy if set.
        // Every arm takes a term's other ae / æ spelling when it has one.
        let tokens = tokenise(text)
        if tokens.isEmpty { return nil }

        var terms: [[Spelling]] = []
        for tk in tokens {
            let folded = foldForIndex(tk.text)
            if folded.isEmpty { continue }
            let spellings = ligatureSpellings(folded)
            if !tk.isPhrase && fuzzy {
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
                terms.append(spellings.map { spelling in
                    if let bare = barewordForPrefix(spelling) {
                        return Spelling(text: bare, isPrefix: true)
                    }
                    return Spelling(text: spelling, isPrefix: false)
                })
            } else {
                // A quoted phrase always matches as a phrase, regardless of
                // fuzzy; so does every word with Fuzzy off.
                terms.append(spellings.map { Spelling(text: $0, isPrefix: false) })
            }
        }
        return terms.isEmpty ? nil : terms
    }

    /// What a query highlights: its terms, each with the way FTS5 matched it.
    ///
    /// They are `textTerms` — the list `fts5Expression` renders — spelling by
    /// spelling, so a term is here exactly as the query asked for it: the
    /// phrase an Exact search ran, a quoted phrase whole, a word Fuzzy ran as a
    /// prefix marked as one, both spellings of an ae word. A term with no
    /// letter or digit in it (`--`) matches nothing and is left out.
    ///
    /// Empty for a Strong's search: the match is a lemma, not text in the
    /// verse. A result row marks the verse's tagged words instead
    /// (`PSSearchResult.strongsHighlightWords`).
    class func highlightTerms(fromUserInput raw: String,
                              matchType: PSSearchType,
                              fuzzy: Bool,
                              strongs: Bool) -> [SearchHighlightTerm] {
        if strongs { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let terms = textTerms(trimmed, matchType: matchType, fuzzy: fuzzy) else {
            return []
        }
        return terms.joined()
            .map { SearchHighlightTerm($0.text, matchesPrefix: $0.isPrefix) }
            .filter { !$0.tokens.isEmpty }
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
    // the fuzzy branch of `textTerms`).
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

    // MARK: - Highlighting

    /// The combining marks `foldForIndex` deletes, by code point: its six
    /// ranges, which are all in the BMP.
    ///
    /// A second copy, for the highlighter's tokenizer (`highlightTokens`),
    /// which has to step over exactly the marks the index never saw.
    /// `foldForIndex` keeps its own so that a function every built index
    /// depends on is not edited for this; the ranges cannot change for the same
    /// reason. The two are held together by
    /// `testTheHighlighterCutsWordsWhereTheIndexDoes`.
    private static func foldDrops(_ c: UInt32) -> Bool {
        (c >= 0x0300 && c <= 0x036F) ||
        (c >= 0x0591 && c <= 0x05C7) ||
        (c >= 0x1AB0 && c <= 0x1AFF) ||
        (c >= 0x1DC0 && c <= 0x1DFF) ||
        (c >= 0x20D0 && c <= 0x20FF) ||
        (c >= 0xFE20 && c <= 0xFE2F)
    }

    /// One word of a text as the index's tokenizer cuts it: where it is, and
    /// the token the index holds for it.
    fileprivate struct HighlightToken {
        let range: Range<String.Index>
        let folded: String
    }

    /// A letter or a digit: what `unicode61` makes tokens of (general
    /// categories L*, N* and Co). Everything else separates two tokens — a
    /// space, punctuation, the apostrophe in `LORD’s`, the dash in
    /// `Beer–sheba`, an underscore.
    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let c = scalar.value
            return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A)
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .privateUse:
            return true
        default:
            return false
        }
    }

    /// `text` cut into the tokens the index holds for it, in order.
    ///
    /// The index tokenizes `foldForIndex(text)`; this reads the text as
    /// displayed, so that each token keeps its place in it. A mark the fold
    /// deletes (`foldDrops`) is stepped over: the tokenizer never saw it, so it
    /// neither starts nor ends a word, and one inside or straight after a word
    /// stays in that word's range. Each token is folded on its own.
    ///
    /// MEASURED against FTS5 itself, on the simulator's SQLite (2026-11-11,
    /// iOS 27.2): this gives the tokenizer's own tokens for every row of both
    /// modules' index text — the KJV's 31,102 rows (792,376 tokens) and MHCC's
    /// 27,715 (5,491,560). Character by character it agrees with FTS5 on every
    /// assigned code point of the scripts the modules are in
    /// (`testTheHighlighterCutsWordsWhereTheIndexDoes`).
    ///
    /// Not modelled, and in neither module's text (which has no combining
    /// mark, and no letter outside ASCII but æ and Æ):
    ///  * FTS5's tables are Unicode 6.1's, and it takes a code point that was
    ///    unassigned then for part of a word: the Turkish lira sign (U+20BA),
    ///    an emoji assigned since (U+1F914).
    ///  * what the tokenizer's own case folding adds to `foldForIndex` for
    ///    eleven letters (ſ to s, a final sigma). Term and text come through
    ///    here alike, so such a word is still marked when typed as printed.
    ///  * a letter whose decomposition leaves a mark the fold keeps (the
    ///    Devanagari nukta letters), which FTS5 splits and this does not.
    ///  * the other way round: a letter followed by a mark the fold keeps and
    ///    NFC joins to it (a kana voiced mark, an Arabic madda), which is one
    ///    word to the index and two here, where the text is read as displayed.
    fileprivate static func highlightTokens(in text: String) -> [HighlightToken] {
        var tokens: [HighlightToken] = []
        let scalars = text.unicodeScalars
        var start: String.Index?
        var end = scalars.startIndex
        // The token so far, lowercased, for as long as it is ASCII: the fold
        // of an ASCII word is its lowercase, and nearly every word is one (all
        // but 96 of the KJV's, every one of MHCC's). `foldForIndex` normalizes
        // twice and is kept off this path, which runs for every result row and
        // every verse row drawn while a highlight is on.
        var ascii: [UInt8] = []
        var isASCII = true

        func close(from: String.Index) {
            let range = from..<end
            let folded = isASCII
                ? String(decoding: ascii, as: UTF8.self)
                : foldForIndex(String(text[range]))
            tokens.append(HighlightToken(range: range, folded: folded))
        }

        var index = scalars.startIndex
        while index != scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if isTokenScalar(scalar) {
                if start == nil {
                    start = index
                    ascii.removeAll(keepingCapacity: true)
                    isASCII = true
                }
                if scalar.isASCII {
                    let c = UInt8(scalar.value)
                    ascii.append(c >= 0x41 && c <= 0x5A ? c + 0x20 : c)
                } else {
                    isASCII = false
                }
                end = next
            } else if foldDrops(scalar.value) {
                if start != nil {
                    isASCII = false
                    end = next
                }
            } else if let from = start {
                close(from: from)
                start = nil
            }
            index = next
        }
        if let from = start {
            close(from: from)
        }
        return tokens
    }

    /// Where `terms` are in `text`: the ranges a search highlight marks.
    ///
    /// **A term is marked where the query matched it, and the query matches
    /// whole words.** FTS5 holds a verse as tokens — its runs of letters and
    /// digits, folded — and a typed word is one token, a phrase a run of them.
    /// So `the` is the word "the", not the first three letters of "there" or
    /// the middle of "father"; a phrase is its words in a row, whatever
    /// punctuation the verse has between them (`light and there` marks
    /// "light: and there"); and a possessive or a hyphenated name is found
    /// whichever apostrophe or dash it was typed with.
    ///
    /// Both highlighters — the result row and the reader — used to look for the
    /// term's characters anywhere in the text. MEASURED on the KJV index, for
    /// the result row: in the verses a search for `the` found, FTS5 matched
    /// 63,944 words and the row had 93,567 marks, 29,623 of them inside
    /// "there", "gathered", "thereof"; for `he`, 10,419 words and 39,198
    /// marks. And a term the query found across punctuation was marked
    /// nowhere: `LORD's` typed with a straight apostrophe in none of its 131
    /// verses, `Beer-sheba` in none of 33, an Exact `verily verily I say unto
    /// you` in none of 20.
    ///
    /// A term's range runs from the start of its first word to the end of its
    /// last, so the punctuation between a phrase's words is marked and the
    /// punctuation around it is not. A prefix term (`matchesPrefix`: a word
    /// Fuzzy ran as `word*`) is marked in every word that BEGINS with it, over
    /// the whole word.
    ///
    /// The ranges come back in reading order and apart from one another:
    /// matches that overlap are one range (`holy holy` in "Holy, holy, holy"
    /// fits twice and marks all three words, as FTS5's own `highlight()` does).
    /// Their bounds are scalar-aligned indices of `text`, and of no other
    /// string: hand over the string the marks will be put on.
    ///
    /// The rule was MEASURED against FTS5's own `highlight()` on the KJV index
    /// before it was written here (a reference implementation, in Python): the
    /// same spans on every returned row for every word of the text typed alone
    /// (12,460 queries), for 64,234 phrases, and for a battery of 445 queries
    /// in every mode (9.3 million rows) — all but 7 of them, written to break
    /// it: an accent on an `ae` pair, which the terms now handle by taking
    /// their spellings from the folded word, and the characters
    /// `highlightTokens` lists as not modelled. This implementation is held to
    /// FTS5 by `testASearchTermIsMarkedWhereTheQueryMatchedIt`.
    class func highlightRanges(
        of terms: [SearchHighlightTerm],
        in text: String
    ) -> [Range<String.Index>] {
        let terms = terms.filter { !$0.tokens.isEmpty }
        guard !terms.isEmpty else { return [] }

        // Once, for every term.
        let words = highlightTokens(in: text)
        var found: [Range<String.Index>] = []
        for term in terms {
            let count = term.tokens.count
            guard words.count >= count else { continue }
            let last = term.tokens[count - 1]
            // Every place the term fits, one word on from the last: a phrase
            // that repeats a word overlaps itself.
            for first in 0...(words.count - count) {
                var fits = true
                for offset in 0..<(count - 1)
                where words[first + offset].folded != term.tokens[offset] {
                    fits = false
                    break
                }
                guard fits else { continue }
                // FTS5 puts a prefix on the last token of what it is given, and
                // compares it byte for byte.
                let final = words[first + count - 1].folded
                guard term.matchesPrefix
                        ? final.utf8.starts(with: last.utf8)
                        : final == last else { continue }
                found.append(
                    words[first].range.lowerBound
                        ..< words[first + count - 1].range.upperBound
                )
            }
        }

        found.sort { $0.lowerBound < $1.lowerBound }
        var ranges: [Range<String.Index>] = []
        for range in found {
            if let previous = ranges.last, range.lowerBound <= previous.upperBound {
                if range.upperBound > previous.upperBound {
                    ranges[ranges.count - 1] = previous.lowerBound..<range.upperBound
                }
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}

/// One thing a search highlights: a word or a phrase, as the index's tokens,
/// and how the query matched it.
///
/// Made by `PSSearchQuery.highlightTerms(fromUserInput:…)` when the query runs
/// and carried unchanged to the result rows and into the reader, so that both
/// mark a verse the way the query found it. `PSSearchQuery.highlightRanges`
/// reads them.
///
/// Two terms are equal when they match the same thing: "Jesus wept", "jesus
/// wept " and "JESUS, WEPT" are one term.
struct SearchHighlightTerm: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The term as the index would hold it: its words, folded, in order
    /// (`LORD’s` is `lord`, `s`). Case, diacritics and whatever punctuation was
    /// typed in or around the term are gone. Empty for a term with no letter or
    /// digit in it, which matches nothing.
    let tokens: [String]

    /// The query ran this word as a prefix (`word*`, the Fuzzy option), so it
    /// is marked in every word that BEGINS with it, over the whole word. False
    /// for a phrase, for an Exact search and for a word with punctuation inside
    /// it, all of which Fuzzy matches as typed.
    ///
    /// With more than one token the prefix is on the last, as in FTS5. The
    /// query builder makes a prefix of one word only.
    let matchesPrefix: Bool

    init(_ text: String, matchesPrefix: Bool = false) {
        self.tokens = PSSearchQuery.highlightTokens(in: text).map(\.folded)
        self.matchesPrefix = matchesPrefix
    }

    /// A term written as a literal is a whole word or phrase.
    init(stringLiteral value: String) {
        self.init(value)
    }

    /// `lord s`, or `lov*` for a prefix: for a failed assertion to read.
    var description: String {
        tokens.joined(separator: " ") + (matchesPrefix ? "*" : "")
    }
}
