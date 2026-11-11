//
//  PSInfoPopupContent.swift
//  PocketSword
//
//  The parsed content of a study popup — the entry HTML plus the Greek/Hebrew
//  lemma and transliteration pulled out of a rendered lexicon entry.
//
//  The lexeme parsing below reflects what the bundled strongsrealgreek /
//  strongsrealhebrew modules actually render: nested beta-code brackets, the
//  Hebrew entries' superscript letters (a shewa inside 1,414 transliterations,
//  which belongs to the word; a trailing `o` on 114 lemmas, which does not),
//  and numeric character references that must be decoded before the script can
//  be recognised.
//

import UIKit

final class PSInfoPopupContent: NSObject {
    /// The entry's own HTML — the lexicon/footnote body as the store yields it,
    /// **not** a full page.
    let entryHTML: String
    let contextTitle: String?
    let reference: String?
    let searchTerm: String?
    /// The actual Greek/Hebrew lemma (e.g. "ὁ"), parsed from the rendered
    /// lexicon entry. nil when the module isn't a standard Strong's lexicon.
    let lemma: String?
    /// The transliteration (e.g. "ho"), parsed from the first `{…}` token.
    let transliteration: String?

    /// The parsed entry, built ONCE per content object (memoized here rather than
    /// in view state, so a body evaluation never re-scans the entry). Main-actor
    /// use only, like the rest of this type.
    private var parsedDocument: EntryDocument?

    var entryDocument: EntryDocument {
        if let parsedDocument { return parsedDocument }
        let document = PSEntryDocumentBuilder.build(html: entryHTML)
        parsedDocument = document
        return document
    }

    var isStrongsEntry: Bool {
        reference != nil
    }

    var isHebrew: Bool {
        reference?.hasPrefix("H") ?? false
    }

    init(html: String) {
        self.entryHTML = html
        self.contextTitle = nil
        self.reference = nil
        self.searchTerm = nil
        self.lemma = nil
        self.transliteration = nil
    }

    init(strongsHTML html: String, rawEntry: String?, reference rawReference: String, allowsSearch: Bool) {
        let normalizedReference = Self.normalizedStrongsReference(rawReference)
        let isHebrew = normalizedReference.hasPrefix("H")
        let lexeme = Self.parseStrongsLexeme(fromRenderedEntry: rawEntry)

        self.entryHTML = html
        self.contextTitle = NSLocalizedString(
            isHebrew ? "PreferencesHebrewStrongsLexiconTitle" : "PreferencesGreekStrongsLexiconTitle",
            comment: ""
        )
        self.reference = normalizedReference
        self.searchTerm = allowsSearch ? normalizedReference : nil
        self.lemma = lexeme.lemma
        self.transliteration = lexeme.transliteration
    }

    /// The content for a lexicon entry reached by tapping a cross-link inside
    /// another one ("From 3898", "See also 1036").
    ///
    /// Returns nil when the target is missing from the store, so the caller can leave
    /// the current entry on screen rather than pushing a blank one.
    ///
    /// The `G`/`H` prefix comes from the **target** module, not the one being read:
    /// 317 of the 14,989 baked cross-links point from the Greek lexicon into the
    /// Hebrew one (`StrongsRealGreek` → `StrongsRealHebrew`), so deriving the prefix
    /// from the source would label those entries `G` and pick the wrong script font
    /// for the lemma.
    static func lexiconEntry(
        module: String,
        key: String,
        allowsSearch: Bool
    ) -> PSInfoPopupContent? {
        guard let entry = PSContentReader.entry(module: module, key: key) else {
            return nil
        }
        let prefix: String
        switch module {
        case BundledModules.strongsHebrew: prefix = "H"
        case BundledModules.strongsGreek: prefix = "G"
        default:
            // Robinson, or anything unrecognised. No baked cross-link targets it
            // (measured: all 14,989 hrefs address one of the two Strong's lexicons),
            // and a morph code is not a Strong's reference — so render the body with
            // no lemma header rather than inventing a prefix for it.
            return PSInfoPopupContent(html: entry)
        }
        return PSInfoPopupContent(
            strongsHTML: entry,
            rawEntry: entry,
            reference: prefix + key,
            allowsSearch: allowsSearch
        )
    }

    private static func normalizedStrongsReference(_ reference: String) -> String {
        let uppercased = reference
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let prefix = uppercased.first, prefix == "G" || prefix == "H" else {
            return uppercased
        }

        let digits = uppercased.dropFirst()
        let withoutLeadingZeroes = digits.drop(while: { $0 == "0" })
        return String(prefix) + (withoutLeadingZeroes.isEmpty ? "0" : String(withoutLeadingZeroes))
    }

    /// Pull the leading lemma and transliteration out of a rendered Strong's
    /// entry. The bundled strongsrealgreek/strongsrealhebrew modules render as
    /// `ὁ [O(] {ho} \ho\ including the feminine ἡ …` — the lemma is the text
    /// before the first `[`, the transliteration is the first `{…}` token.
    /// Defensive: returns (nil, nil) for anything that doesn't look like a
    /// standard lexeme so callers fall back to showing the reference.
    static func parseStrongsLexeme(fromRenderedEntry rawEntry: String?) -> (lemma: String?, transliteration: String?) {
        guard let rawEntry = rawEntry else { return (nil, nil) }

        // The rendered entry looks like (HTML tags + numeric entities intact):
        //   <a name="4018">4018</a> &#960;&#949;&#961;… [PERIBO/LAION] {perib&#243;laion} \…\ neuter of…
        // Strip tags, decode entities to real Unicode, collapse whitespace,
        // then drop the leading key number the hidden anchor leaves behind.
        //
        // One shape is unwrapped first instead of stripped. strongsrealhebrew
        // writes a superscript letter as `<sup><font size="-1"><i>e</i></font></sup>`
        // (all 1,723 `<sup>` in the store have exactly this shape), and in 1,414
        // entries — H3068, H1285, H3063… — it is the vocal shewa in the middle of
        // the bracketed transliteration. The strip leaves a space where each tag
        // was, which is right between words and wrong inside one:
        // `[y<sup>…e…</sup>hôvâh]` reached the popup's header as "y e hôvâh".
        let unwrapped = rawEntry.replacingOccurrences(
            of: "<sup><font size=\"-1\"><i>([^<]*)</i></font></sup>",
            with: "$1",
            options: .regularExpression
        )
        let decoded = decodingHTMLEntities(
            unwrapped.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        )
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let body = decoded
            .replacingOccurrences(of: "^\\d+\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let openBracket = body.firstIndex(of: "[") else { return (nil, nil) }
        let candidate = String(body[body.startIndex..<openBracket])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 114 strongsrealhebrew entries (H726/H728/H971/H1208/H1269…) end the
        // lemma in a superscript `o`, which the unwrap above leaves attached to
        // it as a spurious trailing ASCII letter, e.g. "אֲרוֹןo". The lemma is
        // script only, so keep just the leading run up to the first ASCII letter.
        let lemma = String(candidate.prefix(while: { !($0.isASCII && $0.isLetter) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Reject anything that isn't a short run of actual script — the real
        // lemma is a handful of non-ASCII letters, not a sentence.
        let hasNonASCIILetter = lemma.unicodeScalars.contains { $0.value > 0x7F && CharacterSet.letters.contains($0) }
        guard !lemma.isEmpty, lemma.count <= 40, hasNonASCIILetter else {
            return (nil, nil)
        }

        // Transliteration. Greek renders `θεός [QEO/S] {theós} \…\` — the
        // transliteration is the `{…}` immediately after the bracket group.
        // Hebrew renders `חשך [chôshek] \…\ … {misery} …` — the transliteration
        // is *inside* the brackets, and any `{…}` later on is a gloss in the
        // definition, not a transliteration. So: prefer a `{…}` right after the
        // closing `]`; otherwise fall back to the bracket content when it reads
        // like a transliteration (has a lowercase letter, i.e. not Greek beta-code).
        var transliteration: String? = nil
        if let closeBracket = matchingCloseBracket(in: body, openBracket: openBracket) {
            let afterBracket = body[body.index(after: closeBracket)...]
                .drop(while: { $0 == " " })
            if afterBracket.first == "{", let brace = afterBracket.firstIndex(of: "}") {
                let inner = String(afterBracket[afterBracket.index(after: afterBracket.startIndex)..<brace])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty { transliteration = inner }
            } else {
                let bracketContent = String(body[body.index(after: openBracket)..<closeBracket])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A transliteration reads as lowercase Latin — possibly with
                // diacritics (Hebrew renders `[chôshek]`, `['â‛]`). Greek
                // beta-code is uppercase ASCII (`QEO/S`), so requiring a
                // lowercase letter distinguishes the two without an ASCII
                // restriction that would drop diacritic-only Hebrew translits.
                if bracketContent.contains(where: { $0.isLowercase }) {
                    transliteration = bracketContent
                }
            }
        }

        return (lemma, transliteration)
    }

    /// The `]` that closes the `[` at `openBracket`, honouring nesting. Greek
    /// beta-code occasionally nests brackets (`[…[1GE]…]`, e.g. G1490), so a
    /// naive `firstIndex(of: "]")` lands on the inner close and truncates the
    /// group before the trailing `{…}` transliteration. Returns nil if the
    /// bracket is never closed.
    private static func matchingCloseBracket(in body: String, openBracket: String.Index) -> String.Index? {
        var depth = 0
        var index = openBracket
        while index < body.endIndex {
            let character = body[index]
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = body.index(after: index)
        }
        return nil
    }

    /// Decode the HTML entities the SWORD markup filter emits (named basics +
    /// decimal/hex numeric character references) into real Unicode. The lexicon
    /// renders Greek/Hebrew as `&#960;`-style entities, so we must decode before
    /// we can recognise the script.
    private static func decodingHTMLEntities(_ input: String) -> String {
        var result = input
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<",
            "&gt;": ">", "&quot;": "\"", "&apos;": "'"
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        guard result.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else {
            return result
        }

        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return result }

        var output = ""
        var cursor = 0
        for match in matches {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                output.unicodeScalars.append(scalar)
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}
