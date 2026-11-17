import Foundation

// Small text helpers shared by the library, search and rendering code.
// Everything here is grapheme-safe: truncation never splits a Bangla conjunct or an emoji.

extension Unicode.Scalar {
    /// Whitespace or a control character. Both become a single space in single-line text.
    var isSpaceOrControl: Bool {
        let v = value
        if v < 0x80 { return v <= 0x20 || v == 0x7F }
        if v >= 0x0980 && v <= 0x09FF { return false }      // Bengali block: no spaces or controls
        return properties.isWhitespace || properties.generalCategory == .control
    }
}

extension String {
    /// Whitespace and control characters collapsed to single spaces, trimmed. Zero-width joiners
    /// (used in Bangla) are kept.
    var singleLine: String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in unicodeScalars {
            if scalar.isSpaceOrControl {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace {
                    out.append(" ")
                    pendingSpace = false
                }
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// The string limited to `maxCharacters` grapheme clusters and `maxUTF8Bytes` bytes (the
    /// ellipsis included). Cuts at a word boundary when one is within the last 20 characters.
    func truncated(maxCharacters: Int, maxUTF8Bytes: Int = Int.max, ellipsis: String = "…") -> String {
        guard maxCharacters > 0, maxUTF8Bytes > 0 else { return "" }
        if utf8.count <= maxUTF8Bytes && count <= maxCharacters { return self }
        let characterBudget = maxCharacters - ellipsis.count
        let byteBudget = maxUTF8Bytes - ellipsis.utf8.count
        guard characterBudget > 0, byteBudget > 0 else { return "" }

        var end = startIndex
        var characters = 0
        var bytes = 0
        var lastSpace: (index: String.Index, characters: Int)?
        for index in indices {
            let character = self[index]
            let width = character.utf8.count
            if characters + 1 > characterBudget || bytes + width > byteBudget { break }
            if character.isWhitespace { lastSpace = (index, characters) }
            characters += 1
            bytes += width
            end = self.index(after: index)
        }
        var cut = end
        if let space = lastSpace, space.characters > 0, characters - space.characters <= 20 {
            cut = space.index
        }
        let head = String(self[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        return head + ellipsis
    }

    /// Trimmed NFC form, or nil when nothing is left.
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t.nfc
    }
}

extension Array where Element == String {
    /// Order-preserving de-duplication, ignoring case (the first spelling wins).
    func uniquedCaseInsensitive() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in self where seen.insert(item.lowercased()).inserted {
            out.append(item)
        }
        return out
    }
}
