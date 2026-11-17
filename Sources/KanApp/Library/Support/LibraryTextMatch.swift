import Foundation

/// Text matching for highlights and find-in-transcript, with the rules of `LibraryStore.search`
/// (KanCore's TextMatching.swift), so the UI highlights exactly what the library search matched:
///
///  - case-insensitive on NFC text, WITHOUT diacritic folding: Bangla vowel signs and the virama are
///    letters, so "জনি" does not match "জন্য";
///  - compared scalar by scalar, so a term may end inside a character: "ভাষ" matches in "ভাষার".
///
/// Returned ranges are widened to whole characters (grapheme clusters), so a highlight never splits
/// a Bangla conjunct or separates a vowel sign from its consonant. Pure and thread-safe.
enum LibraryTextMatch {
    /// Straight and typographic double quotes (macOS text fields substitute "smart quotes").
    static let quoteCharacters: Set<Character> = ["\"", "“", "”", "„", "‟", "«", "»"]

    /// Lowercase fold of one scalar: ASCII A–Z, and any other scalar whose lowercase form is a single
    /// scalar of the same UTF-8 width (KanCore's `TextFolding.fold`). Caseless scripts are unchanged.
    static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let v = scalar.value
        if v < 0x80 {
            return (v >= 0x41 && v <= 0x5A) ? Unicode.Scalar(UInt8(v + 0x20)) : scalar
        }
        if (0x0900...0x0DFF).contains(v) { return scalar }   // Indic scripts, Bengali included
        let properties = scalar.properties
        guard properties.changesWhenLowercased else { return scalar }
        let lower = properties.lowercaseMapping.unicodeScalars
        guard let first = lower.first, lower.count == 1,
              UTF8.width(first) == UTF8.width(scalar) else { return scalar }
        return first
    }

    /// `text` folded scalar by scalar (NFC first). Used for case-insensitive comparisons of names.
    static func folded(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars { out.append(fold(scalar)) }
        return String(out)
    }

    /// Whitespace runs collapsed to single spaces, trimmed.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// The terms of a query the way the library search reads it: whitespace-separated, "quoted
    /// phrases" kept together, NFC, single-spaced, duplicates (ignoring case) dropped.
    static func terms(in query: String) -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        var current = ""
        var inQuote = false
        func flush() {
            let term = singleLine(current)
            current = ""
            guard !term.isEmpty, seen.insert(folded(term)).inserted else { return }
            terms.append(term)
        }
        for character in query.precomposedStringWithCanonicalMapping {
            if quoteCharacters.contains(character) {
                flush()
                inQuote.toggle()
            } else if character.isWhitespace && !inQuote {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return terms
    }

    /// Every occurrence of any of `terms` in `text` (NFC), widened to whole characters, sorted, with
    /// overlapping occurrences merged.
    static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        let patterns = foldedPatterns(terms)
        guard !patterns.isEmpty, !text.isEmpty else { return [] }

        let view = text.unicodeScalars
        var scalars: [Unicode.Scalar] = []
        var positions: [String.Index] = []
        scalars.reserveCapacity(view.count)
        positions.reserveCapacity(view.count + 1)
        for index in view.indices {
            positions.append(index)
            scalars.append(fold(view[index]))
        }
        positions.append(text.endIndex)

        var found: [(lower: Int, upper: Int)] = []
        for pattern in patterns where pattern.count <= scalars.count {
            let first = pattern[0]
            var i = 0
            let last = scalars.count - pattern.count
            while i <= last {
                if scalars[i] == first && matches(pattern, scalars, at: i) {
                    found.append((i, i + pattern.count))
                    i += pattern.count
                } else {
                    i += 1
                }
            }
        }
        guard !found.isEmpty else { return [] }

        // Scalar offsets where characters start (plus the end), to widen matches to whole characters.
        var boundaries: [Int] = []
        boundaries.reserveCapacity(text.count + 1)
        var offset = 0
        for character in text {
            boundaries.append(offset)
            offset += character.unicodeScalars.count
        }
        boundaries.append(offset)

        let widened = found.map { match -> (lower: Int, upper: Int) in
            (boundaries[lastIndex(in: boundaries, notAbove: match.lower)],
             boundaries[firstIndex(in: boundaries, notBelow: match.upper)])
        }.sorted { $0.lower != $1.lower ? $0.lower < $1.lower : $0.upper > $1.upper }

        var merged: [(lower: Int, upper: Int)] = []
        for match in widened {
            if let previous = merged.last, match.lower < previous.upper {
                merged[merged.count - 1].upper = max(previous.upper, match.upper)
            } else {
                merged.append(match)
            }
        }
        return merged.map { positions[$0.lower]..<positions[$0.upper] }
    }

    /// The same occurrences as UTF-16 `NSRange`s (for AppKit text).
    static func nsRanges(of terms: [String], in text: String) -> [NSRange] {
        ranges(of: terms, in: text).map { NSRange($0, in: text) }
    }

    /// True when `text` contains any of `terms`.
    static func containsAny(of terms: [String], in text: String) -> Bool {
        !ranges(of: terms, in: text).isEmpty
    }

    // MARK: - Internals

    private static func foldedPatterns(_ terms: [String]) -> [[Unicode.Scalar]] {
        var seen = Set<[UInt32]>()
        var patterns: [[Unicode.Scalar]] = []
        for term in terms {
            let normalized = singleLine(term.precomposedStringWithCanonicalMapping)
            let pattern = normalized.unicodeScalars.map(fold)
            guard !pattern.isEmpty, seen.insert(pattern.map(\.value)).inserted else { continue }
            patterns.append(pattern)
        }
        return patterns
    }

    @inline(__always)
    private static func matches(_ pattern: [Unicode.Scalar], _ text: [Unicode.Scalar], at start: Int) -> Bool {
        for k in 1..<pattern.count where text[start + k] != pattern[k] { return false }
        return true
    }

    /// Index of the largest element ≤ `value` in a sorted array that starts with 0.
    private static func lastIndex(in sorted: [Int], notAbove value: Int) -> Int {
        var low = 0, high = sorted.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if sorted[mid] <= value { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Index of the smallest element ≥ `value` in a sorted array whose last element is ≥ `value`.
    private static func firstIndex(in sorted: [Int], notBelow value: Int) -> Int {
        var low = 0, high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] >= value { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
