import Foundation
import KanCore

// Reading OpenAI's answers: the Responses API body, its error body, and the JSON the model wrote.
// Decoding is lenient (unknown item types and fields are ignored) and never keeps OpenAI's error
// message: it can quote part of the API key, so it isn't even decoded.

/// The `error` object of a failed request (`{ "error": { "type", "code", "param", "message" } }`) or
/// of a response with `status: failed`. `message` is deliberately left out.
struct OpenAIErrorDetail: Decodable, Sendable, Equatable {
    var type: String?
    var code: String?
    var param: String?

    init(type: String? = nil, code: String? = nil, param: String? = nil) {
        self.type = type
        self.code = code
        self.param = param
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        // `code` is a string or null in OpenAI's API; take a number too.
        if let text = try? c.decodeIfPresent(String.self, forKey: .code) {
            code = text
        } else if let number = try? c.decodeIfPresent(Int.self, forKey: .code) {
            code = String(number)
        }
        param = try? c.decodeIfPresent(String.self, forKey: .param)
    }

    private enum CodingKeys: String, CodingKey { case type, code, param }

    /// The `error` object of an HTTP error body, or an empty detail when there is none.
    static func decode(_ body: Data) -> OpenAIErrorDetail {
        struct Envelope: Decodable { var error: OpenAIErrorDetail? }
        return ((try? JSONDecoder().decode(Envelope.self, from: body))?.error) ?? OpenAIErrorDetail()
    }

    /// True when `code` or `type` is `value` (OpenAI puts `insufficient_quota` in either).
    func means(_ value: String) -> Bool {
        code?.lowercased() == value || type?.lowercased() == value
    }

    /// A billing stop, by `code` first and then `type` (OpenAI's advice: a spend limit can still have
    /// the type `insufficient_quota`): `.spendLimit`, `.noCredit`, or nil. Never worth a retry.
    var billingError: AIError? {
        for value in [code, type].compactMap({ $0?.lowercased() }) {
            if Self.spendLimitCodes.contains(value) { return .spendLimit }
            if Self.noCreditCodes.contains(value) { return .noCredit }
        }
        return nil
    }

    private static let spendLimitCodes: Set<String> = [
        "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
    ]
    private static let noCreditCodes: Set<String> = ["insufficient_quota", "credit_balance_exhausted", "billing_not_active"]

    /// OpenAI's safety checks rejected the input (`invalid_prompt`) or stopped the answer under a
    /// usage policy (`bio_policy`, `misalignment_policy_violation`…): sending the call again won't help.
    var isPolicyRejection: Bool {
        [code, type].contains { value in
            guard let value = value?.lowercased() else { return false }
            return value == "invalid_prompt" || value.hasSuffix("_policy") || value.hasSuffix("_policy_violation")
        }
    }

    /// A 400 about the `reasoning` field: the model doesn't take a reasoning effort.
    var isAboutReasoning: Bool {
        guard let param = param?.lowercased() else { return false }
        return param == "reasoning" || param.hasPrefix("reasoning.")
    }

    /// A 400 about `max_output_tokens`: the model can't write that many tokens.
    var isAboutOutputLimit: Bool {
        param?.lowercased() == "max_output_tokens"
    }

    /// "code insufficient_quota, type insufficient_quota" for kan.log. Only identifier-like values
    /// are shown; anything else (free text) becomes "?".
    var logDescription: String {
        func safe(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            let allowed = value.count <= 64 && value.unicodeScalars.allSatisfy {
                ($0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil)) || "_.-[]".unicodeScalars.contains($0)
            }
            return allowed ? value : "?"
        }
        return [("code", safe(code)), ("type", safe(type)), ("param", safe(param))]
            .compactMap { name, value in value.map { "\(name) \($0)" } }
            .joined(separator: ", ")
    }
}

/// The parts of a Responses API body Kan reads (`output_text` is an SDK convenience, not in the
/// raw JSON).
struct OpenAIResponseBody: Decodable {
    var status: String?
    var error: OpenAIErrorDetail?
    var incompleteReason: String?
    var output: [OutputItem]
    var usage: Usage?

    struct OutputItem: Decodable {
        var type: String?
        var content: [ContentPart]

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            type = try? c?.decodeIfPresent(String.self, forKey: .type)
            content = (try? c?.decodeIfPresent([ContentPart].self, forKey: .content)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case type, content }
    }

    struct ContentPart: Decodable {
        var type: String?
        var text: String?

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            type = try? c?.decodeIfPresent(String.self, forKey: .type)
            text = try? c?.decodeIfPresent(String.self, forKey: .text)
        }

        private enum CodingKeys: String, CodingKey { case type, text }
    }

    struct Usage: Decodable {
        var inputTokens: Int?
        var cachedTokens: Int?
        var outputTokens: Int?
        var reasoningTokens: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try? c.decodeIfPresent(Int.self, forKey: .inputTokens)
            outputTokens = try? c.decodeIfPresent(Int.self, forKey: .outputTokens)
            cachedTokens = (try? c.decodeIfPresent(Details.self, forKey: .inputDetails))?.cachedTokens
            reasoningTokens = (try? c.decodeIfPresent(Details.self, forKey: .outputDetails))?.reasoningTokens
        }

        private struct Details: Decodable {
            var cachedTokens: Int?
            var reasoningTokens: Int?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                cachedTokens = try? c.decodeIfPresent(Int.self, forKey: .cachedTokens)
                reasoningTokens = try? c.decodeIfPresent(Int.self, forKey: .reasoningTokens)
            }

            private enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
                case reasoningTokens = "reasoning_tokens"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case inputDetails = "input_tokens_details"
            case outputDetails = "output_tokens_details"
        }

        /// "1234 in (1024 cached), 321 out (200 reasoning)".
        var logDescription: String {
            func number(_ value: Int?) -> String { value.map(String.init) ?? "?" }
            return "\(number(inputTokens)) in (\(number(cachedTokens)) cached), "
                + "\(number(outputTokens)) out (\(number(reasoningTokens)) reasoning)"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        error = try? c.decodeIfPresent(OpenAIErrorDetail.self, forKey: .error)
        incompleteReason = (try? c.decodeIfPresent(IncompleteDetails.self, forKey: .incompleteDetails))?.reason
        output = (try? c.decodeIfPresent([OutputItem].self, forKey: .output)) ?? []
        usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
    }

    private struct IncompleteDetails: Decodable { var reason: String? }

    private enum CodingKeys: String, CodingKey {
        case status, error, output, usage
        case incompleteDetails = "incomplete_details"
    }

    /// The text of every `output_text` part of every `message` item, in order, and whether the
    /// model refused (a `refusal` part).
    var outputText: (text: String, refused: Bool) {
        var text = ""
        var refused = false
        for item in output where item.type == "message" {
            for part in item.content {
                switch part.type {
                case "output_text": text += part.text ?? ""
                case "refusal": refused = true
                default: continue
                }
            }
        }
        return (text, refused)
    }
}

enum OpenAIAnswer {
    /// The JSON text the model wrote, from a 2xx body. Throws `AIError`.
    static func text(from body: Data, model: String) throws -> (text: String, usage: OpenAIResponseBody.Usage?) {
        guard let response = try? JSONDecoder().decode(OpenAIResponseBody.self, from: body) else {
            throw AIError.badResponse
        }
        switch response.status {
        case "failed": throw failure(response.error ?? OpenAIErrorDetail(), model: model)
        case "incomplete": throw AIError.incomplete
        case "cancelled", "queued", "in_progress": throw AIError.badResponse
        default: break
        }
        let (text, refused) = response.outputText
        guard text.aiHasVisibleText else { throw refused ? AIError.refused : AIError.badResponse }
        // A refusal next to unreadable text is still a refusal; readable text wins.
        if refused, jsonObject(text) == nil { throw AIError.refused }
        return (text, response.usage)
    }

    /// The titles in `{"titles": […]}`, unclean.
    static func titles(from text: String) throws -> [String] {
        guard let object = jsonObject(text), let titles = object["titles"] as? [Any] else { throw AIError.badResponse }
        return titles.compactMap { $0 as? String }
    }

    /// The summary fields, cleaned. Throws `.badResponse` when there's no overview and no item.
    static func summary(from text: String) throws -> (overview: String, lists: [String: [String]]) {
        guard let object = jsonObject(text), let overview = object["overview"] as? String else { throw AIError.badResponse }
        var lists: [String: [String]] = [:]
        for field in OpenAIPrompts.summaryFields.dropFirst() {
            let items = (object[field] as? [Any])?.compactMap { $0 as? String } ?? []
            lists[field] = items.map(cleanItem).filter { !$0.isEmpty }
        }
        let cleanOverview = overview.aiSingleLine
        guard !cleanOverview.isEmpty || lists.values.contains(where: { !$0.isEmpty }) else { throw AIError.badResponse }
        return (cleanOverview, lists)
    }

    /// Title ideas as Kan stores them: single line, without wrapping quotes, list markers or a
    /// trailing period, at most `maxTitleLength` characters, no empties or duplicates (ignoring
    /// case), at most `maxTitles`.
    static func cleanTitles(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for title in raw {
            let clean = cleanTitle(title)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            titles.append(clean)
            if titles.count == maxTitles { break }
        }
        return titles
    }

    static let maxTitles = 5
    static let maxTitleLength = 100

    // MARK: - Internals

    /// Maps the `error` of a `status: failed` response (the billing and policy codes as for an HTTP error).
    private static func failure(_ detail: OpenAIErrorDetail, model: String) -> AIError {
        if let billing = detail.billingError { return billing }
        if detail.isPolicyRejection { return .refused }
        if detail.means("rate_limit_exceeded") { return .rateLimited }
        if detail.means("context_length_exceeded") { return .tooLong }
        if detail.means("model_not_found") { return .modelUnavailable(model) }
        if detail.means("server_error") { return .server(status: 500) }
        return .badResponse
    }

    /// The text as a JSON object. Tolerates a Markdown code fence around it (models without
    /// structured outputs add one).
    private static func jsonObject(_ text: String) -> [String: Any]? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = String(body.drop { $0 != "\n" })
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
        }
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("«", "»"), ("„", "“"), ("`", "`"), ("*", "*"), ("_", "_"),
    ]

    private static func cleanTitle(_ raw: String) -> String {
        var title = stripListMarker(raw.aiSingleLine)
        var changed = true
        while changed {
            changed = false
            for (open, close) in quotePairs {
                guard let inner = unwrapped(title, open: open, close: close) else { continue }
                title = inner
                changed = true
            }
            // A trailing period (or Bangla dari), but not an ellipsis.
            if let last = title.last, last == "." || last == "।", !title.hasSuffix("..") {
                title = String(title.dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return title.aiTruncated(maxCharacters: maxTitleLength)
    }

    /// `title` without the `open` … `close` marks around it, or nil when they don't wrap all of it:
    /// the marks may not occur inside, so "“A” vs “B”" and "`a` vs `b`" keep theirs. A run of the
    /// same mark counts as one ("**Bold**"); an apostrophe inside a word ("Rahman’s") isn't a mark.
    private static func unwrapped(_ title: String, open: Character, close: Character) -> String? {
        let run = min(title.prefix { $0 == open }.count, title.reversed().prefix { $0 == close }.count, title.count / 2)
        guard run > 0 else { return nil }
        let inner = Array(title.dropFirst(run).dropLast(run))
        for (i, character) in inner.enumerated() where character == open || character == close {
            let isApostrophe = (character == "'" || character == "’") && i > 0 && i + 1 < inner.count
                && inner[i - 1].isLetter && inner[i + 1].isLetter
            if !isApostrophe { return nil }
        }
        return String(inner).trimmingCharacters(in: .whitespaces)
    }

    /// One list item: single line, without a leading bullet.
    private static func cleanItem(_ raw: String) -> String {
        stripListMarker(raw.aiSingleLine)
    }

    /// "- ", "• ", "* ", "– " or "1. " / "1) " at the start.
    private static func stripListMarker(_ text: String) -> String {
        var rest = Substring(text)
        if let first = rest.first, "-•*–—".contains(first), rest.dropFirst().first == " " {
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let after = rest.dropFirst(digits.count)
            if (1...2).contains(digits.count), let marker = after.first, marker == "." || marker == ")",
               after.dropFirst().first == " " {
                rest = after.dropFirst(2)
            }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
