import Foundation
import KanCore

/// One decoded (non-special) token: its raw text bytes and timing.
public struct TokenPiece: Sendable, Hashable {
    /// Raw bytes of the token text. Byte-level BPE: a Bangla token is often a fragment of one
    /// UTF-8 character (আ = e0 a6 86 may arrive as "e0 a6" + "86").
    public var bytes: [UInt8]
    /// Seconds, relative to the decoded audio.
    public var start: Double
    public var end: Double
    public var probability: Double

    public init(bytes: [UInt8], start: Double, end: Double, probability: Double) {
        self.bytes = bytes
        self.start = start
        self.end = end
        self.probability = probability
    }

    public init(_ text: String, start: Double, end: Double, probability: Double = 1) {
        self.init(bytes: Array(text.utf8), start: start, end: end, probability: probability)
    }
}

/// A recognized word with timing.
public struct RecognizedWord: Sendable, Hashable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    /// Mean token probability, 0…1.
    public var probability: Double

    public init(text: String, start: Double, end: Double, probability: Double) {
        self.text = text
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// Merges byte-level BPE tokens into words before decoding UTF-8 (decoding per token would turn
/// every split Bangla character into "�"). A word starts at a token whose first byte is whitespace;
/// punctuation tokens without a leading space stay attached to the previous word. Pure.
public enum TokenAssembler {
    public static func words(from pieces: [TokenPiece]) -> [RecognizedWord] {
        var groups: [(bytes: [UInt8], start: Double, end: Double, probabilitySum: Double, count: Int)] = []
        for piece in pieces where !piece.bytes.isEmpty {
            if let first = piece.bytes.first, isWhitespace(first) || groups.isEmpty {
                groups.append((piece.bytes, piece.start, piece.end, piece.probability, 1))
            } else {
                groups[groups.count - 1].bytes += piece.bytes
                groups[groups.count - 1].end = max(groups[groups.count - 1].end, piece.end)
                groups[groups.count - 1].probabilitySum += piece.probability
                groups[groups.count - 1].count += 1
            }
        }
        return groups.compactMap { group in
            let text = decode(group.bytes).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedWord(text: text, start: group.start, end: max(group.start, group.end),
                                  probability: group.probabilitySum / Double(group.count))
        }
    }

    /// The full text of the pieces (bytes concatenated, then decoded).
    public static func text(from pieces: [TokenPiece]) -> String {
        decode(pieces.flatMap(\.bytes)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Moves UTF-8 continuation bytes that a segment boundary cut off back to the segment where the
    /// character started (a timestamp token can land between the bytes of one Bangla character).
    public static func repairBoundaries(_ segments: [[TokenPiece]]) -> [[TokenPiece]] {
        var repaired = segments
        for index in repaired.indices.dropLast() {
            let missing = missingContinuationBytes(repaired[index].flatMap(\.bytes))
            guard missing > 0, var next = repaired[index + 1].first else { continue }
            let available = next.bytes.prefix { $0 & 0xC0 == 0x80 }.count
            guard available >= missing, var last = repaired[index].last else { continue }
            last.bytes += next.bytes.prefix(missing)
            last.end = max(last.end, next.start)
            next.bytes.removeFirst(missing)
            repaired[index][repaired[index].count - 1] = last
            if next.bytes.isEmpty {
                repaired[index + 1].removeFirst()
            } else {
                repaired[index + 1][0] = next
            }
        }
        return repaired
    }

    /// How many continuation bytes the last (incomplete) UTF-8 sequence in `bytes` still needs.
    static func missingContinuationBytes(_ bytes: [UInt8]) -> Int {
        var continuation = 0
        for byte in bytes.reversed() {
            if byte & 0xC0 == 0x80 {
                continuation += 1
                if continuation > 3 { return 0 }
                continue
            }
            let length: Int
            switch byte {
            case 0xC0...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF7: length = 4
            default: return 0
            }
            return max(0, length - 1 - continuation)
        }
        return 0
    }

    /// UTF-8 decode that drops invalid or incomplete sequences instead of inserting "�".
    public static func decode(_ bytes: [UInt8]) -> String {
        if let valid = String(validating: bytes, as: UTF8.self) { return valid }
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }
}
