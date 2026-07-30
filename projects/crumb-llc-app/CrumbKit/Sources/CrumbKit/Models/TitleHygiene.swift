import Foundation

/// A pure, deterministic, offline-safe policy for turning a raw catalog product title into a
/// legible **display** name — the single source of truth behind the card, cart line, and history
/// title text.
///
/// Live UCP titles routinely arrive as mixed-script marketing strings, e.g.
/// `"Imperial Choice Premium Green Tea 御茗 高級綠茶 100g"`. Rendered raw they read as noise to a
/// user who can't read the CJK run, and they blow past a single line. This helper surfaces the
/// **Latin-script portion** of such a title, trimmed of the stray separators the dropped run leaves
/// behind (so the example becomes `"Imperial Choice Premium Green Tea 100g"` — the useful `100g`
/// unit is kept, the CJK marketing run is dropped).
///
/// **It never invents or translates** — there is no network and no dictionary. It only ever
/// *removes* foreign-script letters from a title that also carries Latin ones, and it is
/// deliberately conservative: a single-script title (all-Latin **or** all-CJK) is returned as-is,
/// so we prefer the honest raw title over an over-aggressive clean. The **full raw title is always
/// kept for VoiceOver** by the views — only the visible display string is cleaned, nothing is
/// hidden from assistive tech.
public enum TitleHygiene {

    /// Separators a dropped foreign-script run tends to strand at the edges of the surviving Latin
    /// text (`"Green Tea · 綠茶"` → `"Green Tea · "` → trim the trailing `" · "`). Trimmed from both
    /// ends only — never from the interior, where they may be meaningful.
    private static let edgeSeparators = CharacterSet(charactersIn: "-–—·|/•:;,‧・~")
        .union(.whitespacesAndNewlines)

    /// The cleaned display name for a raw catalog title. Pure and total: every input yields a value
    /// (worst case, the trimmed raw title), never a crash and never an empty result for a non-empty
    /// title that carries any renderable text.
    ///
    /// - all-Latin / no foreign letters → the trimmed raw title, unchanged;
    /// - mixed Latin + foreign scripts → the Latin portion, foreign letters removed, whitespace
    ///   collapsed, edge separators trimmed;
    /// - all-foreign (no Latin letters, e.g. an all-CJK title) → falls back to the trimmed raw title
    ///   (we never blank a title we can't Latinize).
    public static func display(for rawTitle: String) -> String {
        let trimmedRaw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return trimmedRaw }

        var hasLatin = false
        var hasForeign = false
        for scalar in trimmedRaw.unicodeScalars {
            if isLatinLetter(scalar) {
                hasLatin = true
            } else if isForeignLetter(scalar) {
                hasForeign = true
            }
        }

        // Single-script (or letter-free) titles are already as clean as we can honestly make them.
        // With no foreign letters there is nothing to strip; with no Latin letters there is nothing
        // to surface, so we keep the raw title rather than blank it.
        guard hasForeign && hasLatin else { return trimmedRaw }

        // Mixed script: drop the foreign-letter scalars, keep Latin letters and every neutral
        // scalar (digits, units, punctuation, symbols, whitespace).
        var kept = String.UnicodeScalarView()
        for scalar in trimmedRaw.unicodeScalars where !isForeignLetter(scalar) {
            kept.append(scalar)
        }

        let cleaned = collapseWhitespace(String(kept))
            .trimmingCharacters(in: edgeSeparators)

        // Guard: if the strip somehow left nothing legible, prefer the honest raw title.
        return cleaned.isEmpty ? trimmedRaw : cleaned
    }

    // MARK: - Merchandising clauses

    /// Separators that reliably introduce a *clause* rather than part of a name. Matched spaced (or
    /// pipe-adjacent) so hyphenated words survive: `"1-Cup Pour-Over"` must not lose its hyphens.
    private static let clauseSeparators = [" | ", " – ", " — ", " · ", " -- ", " - ", "| ", " |"]

    /// Symbols that add nothing to a written or spoken name.
    private static let noiseCharacters: Set<Character> = ["™", "®", "©", "℠"]

    /// The **name** to show a person, for surfaces that have room for one line and no more.
    ///
    /// `display(for:)` answers "which script do we render"; this answers "where does the name end and
    /// the merchandising begin". Live titles routinely arrive as
    /// `"Ceramic Heart Trinket Tray | I Love That You Are My Sister"` or
    /// `"1-Cup Pour-Over™ Coffee Brew Cone - Black"`. Rendered whole they read badly anywhere, and on
    /// Home they used to be interpolated into `"What should I do with \(name)?"` — which turned a
    /// merchant's marketing clause into a question about the reader's family.
    ///
    /// Deliberately **additive**: `display(for:)` is unchanged, so the card, cart line and history
    /// title keep their exact current output. Only callers that ask for a name get the shorter form.
    ///
    /// - Parameters:
    ///   - rawTitle: the merchant's title, verbatim.
    ///   - merchant: the shop's name, when known. A segment that *is* the shop name is skipped, so
    ///     `"Sisters & Co | Ceramic Heart Trinket Tray"` keeps the tray rather than the brand — the
    ///     one case where taking the first segment would be exactly wrong.
    public static func displayName(for rawTitle: String, merchant: String? = nil) -> String {
        // Script hygiene first: a clause separator can sit inside a run this step removes.
        let cleaned = display(for: rawTitle)
        guard !cleaned.isEmpty else { return cleaned }

        let denoised = collapseWhitespace(String(cleaned.filter { !noiseCharacters.contains($0) }))

        let segments = split(denoised)
            .map { collapseWhitespace($0).trimmingCharacters(in: edgeSeparators) }
            .filter { !$0.isEmpty }

        // The first segment that isn't just the shop's own name. Falling through to `denoised`
        // (rather than to nothing) means a title made entirely of the merchant name still renders.
        let named = segments.first { !isMerchantName($0, merchant: merchant) } ?? segments.first ?? denoised

        let result = stripTrailingBracketed(named).trimmingCharacters(in: edgeSeparators)

        // A separator can appear before the object is named at all ("Sale | Mug"). Two characters is
        // not a name, so keep the whole string rather than confidently showing a fragment.
        guard result.count > 2 else { return denoised }

        return isShouting(result) ? titleCased(result) : result
    }

    private static func split(_ value: String) -> [String] {
        clauseSeparators.reduce([value]) { parts, separator in
            parts.flatMap { $0.components(separatedBy: separator) }
        }
    }

    private static func isMerchantName(_ segment: String, merchant: String?) -> Bool {
        guard let merchant, merchant.count > 2 else { return false }
        return segment.compare(merchant, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Drops one *trailing* `(…)` or `[…]` group — "(100-Pack)", "[Sand]". Only trailing, and only
    /// one: a bracketed run mid-title is usually load-bearing.
    private static func stripTrailingBracketed(_ value: String) -> String {
        for (open, close) in [("(", ")"), ("[", "]")] {
            guard value.hasSuffix(close), let start = value.range(of: open, options: .backwards) else { continue }
            let head = String(value[value.startIndex..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
            if head.count > 2 { return head }
        }
        return value
    }

    /// True when the string carries no lowercase letter at all. Mixed case is left exactly as the
    /// merchant wrote it, because recasing it would eat brand names — "Hario V60" must never become
    /// "Hario v60".
    private static func isShouting(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        guard letters.count >= 3 else { return false }
        return !letters.contains { $0.isLowercase }
    }

    private static func titleCased(_ value: String) -> String {
        value.split(separator: " ").map { word in
            // Short all-caps runs inside a shouting title are usually initialisms or sizes
            // ("XL", "USB"), so they keep their case.
            if word.count <= 3, word.allSatisfy({ $0.isLetter || $0.isNumber }) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: - Script classification

    /// Whether a scalar is a Latin-script letter we keep: ASCII `A–Z`/`a–z`, the Latin-1 Supplement
    /// letters (accented `À–ÿ`, minus the `×`/`÷` math symbols), Latin Extended-A/B, Latin Extended
    /// Additional (Vietnamese etc.), and the combining diacritical marks that decorate them.
    private static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A:          // ASCII A–Z, a–z
            return true
        case 0xC0...0xFF:                        // Latin-1 Supplement letters
            return s.value != 0xD7 && s.value != 0xF7   // exclude × and ÷
        case 0x0100...0x024F:                    // Latin Extended-A and -B
            return true
        case 0x0300...0x036F:                    // combining diacritical marks
            return true
        case 0x1E00...0x1EFF:                    // Latin Extended Additional
            return true
        default:
            return false
        }
    }

    /// Whether a scalar is a *foreign-script* letter to drop from a mixed title: any alphabetic
    /// scalar that isn't Latin (CJK, Hangul, Hiragana/Katakana, Cyrillic, Greek, Arabic, Hebrew…).
    /// Non-letters — digits, punctuation, symbols, whitespace — are never foreign; they are neutral
    /// and always kept.
    private static func isForeignLetter(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic && !isLatinLetter(s)
    }

    // MARK: - Whitespace

    /// Collapses every run of whitespace to a single space (removing foreign letters strands double
    /// spaces where a CJK run used to sit) and trims the ends.
    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

public extension Product {
    /// The cleaned, legible display name for this product — a mixed-script catalog title reduced to
    /// its Latin portion, an already-clean title returned as-is. Purely presentational: the raw
    /// ``name`` remains the source of truth (and the VoiceOver label). See ``TitleHygiene``.
    var displayTitle: String {
        TitleHygiene.display(for: name)
    }
}
