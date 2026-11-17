import Foundation

// Case-insensitive substring matching on NFC text, WITHOUT diacritic folding.
//
// Bangla vowel signs and the virama are letters, not diacritics: "জনি" (জ ন ি) must not match
// "জন্য" (জ ন ্ য). Matching therefore compares Unicode scalars (not grapheme clusters — "ভাষ" must
// still find "ভাষা", whose last cluster is ষ + া) after a simple lowercase fold.
//
// The fold maps a scalar to its lowercase form only when that is a single scalar of the same UTF-8
// width. Folded text therefore has exactly the byte layout of the original, a match found at byte
// offset k of the folded text is at offset k of the original, and the text never needs a folded
// copy in memory: it is folded on the fly while matching.

enum TextFolding {
    @inline(__always)
    static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let v = scalar.value
        if v < 0x80 {
            return (v >= 0x41 && v <= 0x5A) ? Unicode.Scalar(UInt8(v + 0x20)) : scalar
        }
        if isCaseless(v) { return scalar }
        let properties = scalar.properties
        guard properties.changesWhenLowercased else { return scalar }
        let lower = properties.lowercaseMapping.unicodeScalars
        guard let first = lower.first, lower.count == 1,
              UTF8.width(first) == UTF8.width(scalar) else { return scalar }
        return first
    }

    /// Scripts and blocks without case, skipped without a Unicode property lookup.
    @inline(__always)
    static func isCaseless(_ v: UInt32) -> Bool {
        (v >= 0x0600 && v <= 0x06FF)            // Arabic
            || (v >= 0x0900 && v <= 0x0DFF)     // Devanagari … Sinhala, incl. Bengali
            || (v >= 0x2000 && v <= 0x206F)     // General punctuation
            || (v >= 0x3000 && v <= 0x9FFF)     // CJK, kana
            || (v >= 0xAC00 && v <= 0xD7AF)     // Hangul
            || (v >= 0x1F000 && v <= 0x1FAFF)   // Emoji
    }

    static func fold(_ string: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in string.unicodeScalars { out.append(fold(scalar)) }
        return String(out)
    }
}

/// A search term prepared for matching: NFC, single-spaced, folded.
struct FoldedPattern: Hashable {
    /// The term as the user typed it (NFC, single-spaced) — what the UI highlights.
    let display: String
    let bytes: [UInt8]
    /// Lead bytes a match can start with (the first scalar or any scalar folding to it), as a
    /// 256-bit set: one bit per byte value.
    private let leadMask: [UInt64]
    /// No scalar of the pattern has case variants (Bangla, digits, punctuation…): the text must
    /// contain exactly these bytes, so a plain byte search (memmem) finds the matches.
    private let isExact: Bool

    init?(_ term: String) {
        let display = term.nfc.singleLine
        guard !display.isEmpty else { return nil }
        let folded = TextFolding.fold(display)
        guard let first = folded.unicodeScalars.first else { return nil }
        self.display = display
        self.bytes = Array(folded.utf8)
        var mask = [UInt64](repeating: 0, count: 4)
        for candidate in FoldedPattern.unfoldedForms(of: first) {
            if let lead = String(candidate).utf8.first { mask[Int(lead >> 6)] |= UInt64(1) << UInt64(lead & 63) }
        }
        self.leadMask = mask
        self.isExact = folded.unicodeScalars.allSatisfy { !$0.properties.changesWhenCaseMapped }
    }

    @inline(__always)
    private func canStart(with byte: UInt8) -> Bool {
        leadMask[Int(byte >> 6)] & (UInt64(1) << UInt64(byte & 63)) != 0
    }

    /// Scalars whose fold is `scalar`: itself and its single-scalar upper/title case forms.
    private static func unfoldedForms(of scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        var forms = [scalar]
        for mapping in [scalar.properties.uppercaseMapping, scalar.properties.titlecaseMapping] {
            let scalars = mapping.unicodeScalars
            if let s = scalars.first, scalars.count == 1, s != scalar, TextFolding.fold(s) == scalar {
                forms.append(s)
            }
        }
        return forms
    }

    /// Byte offset of the first match in `text[from..<to]`, or nil.
    func firstMatch(in text: UnsafeBufferPointer<UInt8>, from start: Int = 0, to end: Int? = nil) -> Int? {
        let limit = min(end ?? text.count, text.count)
        let m = bytes.count
        guard m > 0, start >= 0, start + m <= limit, let base = text.baseAddress else { return nil }
        if isExact {
            // A valid UTF-8 pattern can only match at a scalar boundary of valid UTF-8 text.
            return bytes.withUnsafeBytes { pattern -> Int? in
                guard let found = memmem(base + start, limit - start, pattern.baseAddress, m) else { return nil }
                return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found))
            }
        }
        var i = start
        while i + m <= limit {
            if canStart(with: text[i]) && matches(text, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Compares the pattern with `text` at byte offset `i`, scalar by scalar (requires i + m ≤ count).
    private func matches(_ text: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
        let m = bytes.count
        var k = 0
        while k < m {
            let pb = bytes[k]
            let tb = text[i + k]
            let width = FoldedPattern.width(ofLead: pb)
            if width == 1 {
                let folded = (tb >= 0x41 && tb <= 0x5A) ? tb + 0x20 : tb
                guard folded == pb else { return false }
                k += 1
                continue
            }
            guard width > 1, FoldedPattern.width(ofLead: tb) == width else { return false }
            var identical = true
            for j in 1..<width where text[i + k + j] != bytes[k + j] {
                identical = false
                break
            }
            if !(identical && tb == pb) {
                // Slow path: the text scalar may be an upper-case form of the pattern scalar.
                guard let scalar = FoldedPattern.decode(text, at: i + k, width: width) else { return false }
                let folded = TextFolding.fold(scalar)
                guard folded != scalar, equalsEncoded(folded, at: k) else { return false }
            }
            k += width
        }
        return true
    }

    private func equalsEncoded(_ scalar: Unicode.Scalar, at k: Int) -> Bool {
        var index = k
        var equal = true
        UTF8.encode(scalar) { unit in
            if index >= bytes.count || bytes[index] != unit { equal = false }
            index += 1
        }
        return equal
    }

    /// UTF-8 sequence length for a lead byte; 0 for continuation or invalid bytes.
    @inline(__always)
    static func width(ofLead b: UInt8) -> Int {
        if b < 0x80 { return 1 }
        if b < 0xC2 { return 0 }
        if b < 0xE0 { return 2 }
        if b < 0xF0 { return 3 }
        if b < 0xF5 { return 4 }
        return 0
    }

    static func decode(_ t: UnsafeBufferPointer<UInt8>, at i: Int, width: Int) -> Unicode.Scalar? {
        var v: UInt32
        switch width {
        case 2: v = UInt32(t[i] & 0x1F)
        case 3: v = UInt32(t[i] & 0x0F)
        case 4: v = UInt32(t[i] & 0x07)
        default: return nil
        }
        for j in 1..<width {
            let b = t[i + j]
            guard b & 0xC0 == 0x80 else { return nil }
            v = (v << 6) | UInt32(b & 0x3F)
        }
        return Unicode.Scalar(v)
    }
}

/// A parsed free-text query: whitespace-separated terms (ANDed) and "quoted phrases".
struct ParsedQuery {
    let patterns: [FoldedPattern]

    /// More terms than this are ignored (the term set is tracked in a 64-bit mask).
    static let maxTerms = 32

    init(_ text: String) {
        var terms: [String] = []
        var current = ""
        var inQuote = false
        func flush() {
            if let t = current.nonEmptyTrimmed { terms.append(t) }
            current = ""
        }
        for character in text.nfc {
            if ParsedQuery.quotes.contains(character) {
                flush()
                inQuote.toggle()
            } else if character.isWhitespace && !inQuote {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()

        var seen = Set<[UInt8]>()
        var patterns: [FoldedPattern] = []
        for term in terms {
            guard let pattern = FoldedPattern(term), seen.insert(pattern.bytes).inserted else { continue }
            patterns.append(pattern)
            if patterns.count == ParsedQuery.maxTerms { break }
        }
        self.patterns = patterns
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// Straight and typographic double quotes (macOS text fields substitute “smart quotes”).
    private static let quotes: Set<Character> = ["\"", "“", "”", "„", "‟", "«", "»"]
}

enum Snippet {
    /// About `maxCharacters` characters of `text` around the match at UTF-8 offset `offset`, cut
    /// only at grapheme-cluster boundaries (and preferably between words), with "…" where cut.
    static func around(_ text: String, utf8Offset offset: Int, maxCharacters: Int = 200,
                       leadingContext: Int = 60) -> String {
        guard !text.isEmpty else { return "" }
        let utf8 = text.utf8
        let target = utf8.index(utf8.startIndex, offsetBy: max(0, offset), limitedBy: utf8.endIndex) ?? utf8.endIndex

        // The character containing the match start.
        var matchStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if next > target { break }
            index = next
            matchStart = next
        }
        if matchStart == text.endIndex, matchStart > text.startIndex {
            matchStart = text.index(before: matchStart)
        }

        var start = matchStart
        var taken = 0
        while start > text.startIndex && taken < leadingContext {
            start = text.index(before: start)
            taken += 1
        }
        var end = matchStart
        var total = taken
        while end < text.endIndex && total < maxCharacters {
            end = text.index(after: end)
            total += 1
        }
        while start > text.startIndex && total < maxCharacters {
            start = text.index(before: start)
            total += 1
        }

        // Prefer whole words at both cuts, without cutting into the match.
        if start > text.startIndex, let space = text[start..<matchStart].prefix(20).firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[matchStart..<end].suffix(20).lastIndex(where: \.isWhitespace),
           space > matchStart {
            end = space
        }

        let core = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + core + (end < text.endIndex ? "…" : "")
    }
}
