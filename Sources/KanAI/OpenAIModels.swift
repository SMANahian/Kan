import Foundation
import KanCore

/// A model Settings › OpenAI offers by name.
public struct OpenAIModelOption: Sendable, Hashable, Identifiable {
    /// The API model id, e.g. "gpt-6.1-terra".
    public let id: String
    /// "GPT-6.1 Terra".
    public let name: String
    /// One line on quality and price, relative to the recommended model.
    public let detail: String

    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

/// The OpenAI models Kan knows (Nov 2026). Older ones (gpt-5 mini…) are being retired, so the model
/// is a setting and any other id works too ("Other…" in Settings).
public enum OpenAIModels {
    /// `KanSettings.defaultAIModel`.
    public static let recommended = KanSettings.defaultAIModel

    /// Recommended first, then by price.
    public static let known: [OpenAIModelOption] = [
        OpenAIModelOption(id: "gpt-6.1-terra", name: "GPT-6.1 Terra",
                          detail: "Recommended: clear, natural writing; a few cents per call"),
        OpenAIModelOption(id: "gpt-6-luna", name: "GPT-6 Luna",
                          detail: "Most efficient: about a tenth of Terra's price"),
        OpenAIModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol",
                          detail: "Stronger reasoning: about twice Terra's price"),
        OpenAIModelOption(id: "gpt-6-astra", name: "GPT-6 Astra",
                          detail: "Most capable: about ten times Terra's price"),
    ]

    /// The known model with this id (ignoring case and surrounding spaces).
    public static func option(for id: String) -> OpenAIModelOption? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return known.first { $0.id == wanted }
    }

    /// True for text that can be an OpenAI model id: ASCII letters, digits and `. _ : -` (fine-tuned
    /// models look like "ft:gpt-4o-mini:org::abc"), at most 128 characters, and not an API key
    /// ("sk-…"). `OpenAIAssistant` never sends, shows or logs anything else as a model id.
    public static func isWellFormedID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.lowercased().hasPrefix("sk-") else { return false }
        return trimmed.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._:-".unicodeScalars.contains($0)
        }
    }

    /// True for ids from `GET /models` that can probably write titles and summaries: GPT ("gpt-…")
    /// and o-series ("o3", "o4-mini") models, except image, audio, realtime, transcription, speech,
    /// embedding, moderation, search, live, deep-research and Codex-only variants.
    public static func isLikelyTextModel(_ id: String) -> Bool {
        let lower = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isGPT = lower.hasPrefix("gpt-")
        let isOSeries = lower.hasPrefix("o") && lower.dropFirst().first?.isNumber == true
        guard isGPT || isOSeries else { return false }
        return !excludedVariants.contains { lower.contains($0) }
    }

    private static let excludedVariants = [
        "image", "audio", "realtime", "transcribe", "tts", "embedding", "moderation", "search", "live",
        "codex", "deep-research", "instruct", "computer-use",
    ]
}
