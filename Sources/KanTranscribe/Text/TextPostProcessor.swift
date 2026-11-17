import Foundation
import KanCore

/// Cleans recognizer output for Bangla, English and code-switched text. Pure and thread-safe.
public enum TextPostProcessor {
    public enum DropReason: String, Sendable {
        /// Nothing but whitespace or punctuation.
        case empty
        /// Whisper's own no-speech rule: no_speech_prob > 0.6 and mean log-probability < −1.
        case noSpeech
        /// A known silence hallucination ("Thank you.", "Thanks for watching", …).
        case hallucination
    }

    public enum HallucinationMatch: Sendable, Equatable {
        case none
        /// The text contains a known multi-word hallucination phrase.
        case contains
        /// The whole text is a known hallucination phrase.
        case exact
    }

    /// no_speech_prob at or above this makes an exact hallucination match a drop.
    public static let highNoSpeechProbability = 0.3
    /// Mean token probability below this flags a segment `.lowConfidence`.
    public static let lowConfidenceProbability = 0.4

    /// Phrases Whisper produces on silence or noise (lowercase, punctuation removed). Single words
    /// only ever match exactly.
    public static let hallucinationPhrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks", "thank you bye",
        "thanks for watching", "thank you for watching", "thanks for watching and see you next time",
        "thank you for watching and see you next time", "see you next time", "see you in the next video",
        "please subscribe", "please like and subscribe", "like and subscribe", "subscribe to my channel",
        "dont forget to like and subscribe", "thanks for listening", "thank you for listening",
        "subtitles by the amaraorg community", "subtitles by the amara org community", "subtitles by",
        "transcribed by", "transcription by castingwords", "you", "bye", "bye bye", "the end",
    ]

    // MARK: - Cleaning

    /// NFC, no replacement characters, tidy whitespace, '.' → '।' after Bengali text.
    public static func clean(_ text: String) -> String {
        applyDari(normalizeWhitespace(text.replacingOccurrences(of: "\u{FFFD}", with: "").nfc))
    }

    /// Collapses whitespace runs to one space, removes spaces before punctuation, trims.
    public static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ([,.!?;:।])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// '.' that ends a Bengali sentence becomes the dari '।' (decimal points and ellipses stay).
    public static func applyDari(_ text: String) -> String {
        text.replacingOccurrences(of: "(?<=[\\u0980-\\u09FF])\\s*\\.(?=\\s|$)", with: "।",
                                  options: .regularExpression)
    }

    public static func isBengali(_ scalar: Unicode.Scalar) -> Bool { (0x0980...0x09FF).contains(scalar.value) }

    public static func containsBengali(_ text: String) -> Bool { text.unicodeScalars.contains(where: isBengali) }

    /// Share of letters that are Bengali script (0 when there are no letters).
    public static func bengaliLetterFraction(_ text: String) -> Double {
        var letters = 0, bengali = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if isBengali(scalar) { bengali += 1 }
        }
        return letters == 0 ? 0 : Double(bengali) / Double(letters)
    }

    // MARK: - Repetition

    /// Comparison key for a word: lowercase without surrounding punctuation.
    static func key(_ word: String) -> String {
        let trimmed = word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
        return trimmed.isEmpty ? word : trimmed
    }

    /// Indices of the words to keep after collapsing every run of ≥ `minRepeats` consecutive copies
    /// of the same 1…`maxN`-word phrase to a single copy. Runs of two survive: Bangla
    /// reduplication ("আস্তে আস্তে", "কী কী") is normal speech.
    public static func deloopIndices(_ words: [String], maxN: Int = 8, minRepeats: Int = 3) -> [Int] {
        var keys = words.map(key)
        var kept = Array(words.indices)
        var changed = true
        while changed {
            changed = false
            search: for n in 1...max(1, maxN) {
                var i = 0
                while i + n * minRepeats <= keys.count {
                    var repeats = 1
                    while i + (repeats + 1) * n <= keys.count,
                          keys[(i + repeats * n)..<(i + (repeats + 1) * n)] == keys[i..<(i + n)] {
                        repeats += 1
                    }
                    if repeats >= minRepeats {
                        keys.removeSubrange((i + n)..<(i + repeats * n))
                        kept.removeSubrange((i + n)..<(i + repeats * n))
                        changed = true
                        break search
                    }
                    i += 1
                }
            }
        }
        return kept
    }

    /// `deloopIndices` on whitespace-separated text.
    public static func deloop(_ text: String, maxN: Int = 8, minRepeats: Int = 3) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return deloopIndices(words, maxN: maxN, minRepeats: minRepeats).map { words[$0] }.joined(separator: " ")
    }

    /// True when some phrase of `minWords` words occurs twice — the symptom of a prompt-induced loop
    /// ("…model training প্রথম কাজ হবে দেটাশেট সম্রহ করা" repeated). Used to reject prompted output.
    public static func hasRepeatedPhrase(_ text: String, minWords: Int = 4) -> Bool {
        let keys = text.split(whereSeparator: \.isWhitespace).map { key(String($0)) }
        guard minWords > 0, keys.count >= 2 * minWords else { return false }
        var seen = Set<String>()
        for i in 0...(keys.count - minWords) {
            if !seen.insert(keys[i..<(i + minWords)].joined(separator: " ")).inserted { return true }
        }
        return false
    }

    // MARK: - Hallucinations

    static func hallucinationKey(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func hallucinationMatch(_ text: String) -> HallucinationMatch {
        let normalized = hallucinationKey(text)
        guard !normalized.isEmpty else { return .none }
        if hallucinationPhrases.contains(normalized) { return .exact }
        let padded = " \(normalized) "
        for phrase in hallucinationPhrases where phrase.contains(" ") && padded.contains(" \(phrase) ") {
            return .contains
        }
        return .none
    }

    /// Why a recognized segment should be dropped, or nil to keep it.
    ///
    /// Known hallucination phrases are dropped only when the audio is near-silent, or when the text is
    /// exactly such a phrase and no_speech_prob is high — "Thank you." is real speech in calls too.
    /// A Bangla chunk that came back as English boilerplate (no Bengali at all) is dropped as well.
    public static func dropReason(text: String, language: String, noSpeechProbability: Double,
                                  averageLogProbability: Double, nearSilent: Bool) -> DropReason? {
        let cleaned = clean(text)
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return .empty }
        if noSpeechProbability > 0.6 && averageLogProbability < -1.0 { return .noSpeech }
        let englishBoilerplateInBangla = language == "bn" && !containsBengali(cleaned)
        switch hallucinationMatch(cleaned) {
        case .exact:
            if nearSilent || noSpeechProbability >= highNoSpeechProbability || englishBoilerplateInBangla {
                return .hallucination
            }
        case .contains:
            if nearSilent || englishBoilerplateInBangla { return .hallucination }
        case .none:
            break
        }
        return nil
    }
}
