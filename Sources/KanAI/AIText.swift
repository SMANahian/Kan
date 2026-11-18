import Foundation
import KanCore

// Text helpers for KanAI (KanCore keeps its own versions internal). Grapheme-safe: nothing here
// splits a Bangla conjunct or an emoji.

extension Unicode.Scalar {
    /// Whitespace or a control character; both become a single space in single-line text.
    /// Zero-width (non-)joiners are format characters, not whitespace, so Bangla keeps them.
    var isAISpaceOrControl: Bool {
        properties.isWhitespace || properties.generalCategory == .control
    }
}

extension String {
    /// NFC, with whitespace and control characters collapsed to single spaces, trimmed.
    var aiSingleLine: String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in unicodeScalars {
            if scalar.isAISpaceOrControl {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace {
                    out.append(" ")
                    pendingSpace = false
                }
                out.append(scalar)
            }
        }
        return String(out).nfc
    }

    /// True when there is anything besides whitespace and control characters.
    var aiHasVisibleText: Bool {
        unicodeScalars.contains { !$0.isAISpaceOrControl }
    }

    /// At most `maxCharacters` characters, the "…" included. Cuts at a space when one is within the
    /// last 20 characters, so a word isn't split.
    func aiTruncated(maxCharacters: Int) -> String {
        guard count > maxCharacters else { return self }
        guard maxCharacters > 1 else { return maxCharacters == 1 ? "…" : "" }
        var head = String(prefix(maxCharacters - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: space, to: head.endIndex) <= 20,
           head.distance(from: head.startIndex, to: space) > 0 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }
}
