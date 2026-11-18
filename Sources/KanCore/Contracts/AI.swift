import Foundation

// CONTRACT for the OpenAI features: title ideas and summaries written from a call's transcript.
//
// Off by default. They run only after the user saves an OpenAI API key (kept in the Keychain, never
// in settings.json) and turns a feature on in Settings. Kan then sends the call's transcript text —
// never audio — to OpenAI and stores what comes back in the call's JSON under "ai" (`CallInsights`).
// Implemented by KanAI (`OpenAIAssistant`, `KeychainAPIKeyStore`); mocked in the app's self-test.

/// The language Kan asks OpenAI to write titles and summaries in.
public enum AIOutputLanguage: String, Codable, Sendable, CaseIterable {
    case english
    case bangla
    /// Whichever language the call was mostly in.
    case matchCall

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .bangla: return "বাংলা"
        case .matchCall: return "Same as the call"
        }
    }
}

/// Title ideas for a call (`CallInsights.titleSuggestions`), best first.
public struct AITitleSuggestions: Codable, Sendable, Hashable {
    public var titles: [String]
    /// The OpenAI model that wrote them.
    public var model: String
    public var generatedAt: Date
    /// `CallInsights.fingerprint(of:)` of the call they were written from.
    public var fingerprint: String

    public init(titles: [String], model: String, generatedAt: Date, fingerprint: String) {
        self.titles = titles
        self.model = model
        self.generatedAt = generatedAt
        self.fingerprint = fingerprint
    }

    /// Lenient: only `titles` is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titles = try c.decode([String].self, forKey: .titles)
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        generatedAt = (try? c.decodeIfPresent(Date.self, forKey: .generatedAt)) ?? .distantPast
        fingerprint = (try? c.decodeIfPresent(String.self, forKey: .fingerprint)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case titles, model, generatedAt, fingerprint
    }
}

/// A summary of a call (`CallInsights.summary`). A list is empty when nothing fits it.
public struct AISummary: Codable, Sendable, Hashable {
    /// Two to four sentences: what the call was about and where it ended up.
    public var overview: String
    public var keyPoints: [String]
    /// Research ideas, hypotheses, methods, datasets and papers that came up.
    public var ideas: [String]
    public var decisions: [String]
    /// "Owner: task" when the owner is clear.
    public var actionItems: [String]
    public var openQuestions: [String]
    public var language: AIOutputLanguage
    /// The OpenAI model that wrote it.
    public var model: String
    public var generatedAt: Date
    /// `CallInsights.fingerprint(of:)` of the call it was written from.
    public var fingerprint: String
    /// The transcript was too long to send whole, and its middle was left out.
    public var shortened: Bool

    public init(overview: String, keyPoints: [String] = [], ideas: [String] = [], decisions: [String] = [],
                actionItems: [String] = [], openQuestions: [String] = [], language: AIOutputLanguage,
                model: String, generatedAt: Date, fingerprint: String, shortened: Bool = false) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.ideas = ideas
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.language = language
        self.model = model
        self.generatedAt = generatedAt
        self.fingerprint = fingerprint
        self.shortened = shortened
    }

    /// Lenient: only `overview` is required; anything else unreadable takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) -> [String] { (try? c.decodeIfPresent([String].self, forKey: key)) ?? [] }
        overview = try c.decode(String.self, forKey: .overview)
        keyPoints = list(.keyPoints)
        ideas = list(.ideas)
        decisions = list(.decisions)
        actionItems = list(.actionItems)
        openQuestions = list(.openQuestions)
        language = (try? c.decodeIfPresent(AIOutputLanguage.self, forKey: .language)) ?? .english
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        generatedAt = (try? c.decodeIfPresent(Date.self, forKey: .generatedAt)) ?? .distantPast
        fingerprint = (try? c.decodeIfPresent(String.self, forKey: .fingerprint)) ?? ""
        shortened = (try? c.decodeIfPresent(Bool.self, forKey: .shortened)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case overview, keyPoints, ideas, decisions, actionItems, openQuestions
        case language, model, generatedAt, fingerprint, shortened
    }
}

/// What OpenAI wrote for a call: `CallRecord.ai`, stored in the call's JSON under "ai".
public struct CallInsights: Codable, Sendable, Hashable {
    public var titleSuggestions: AITitleSuggestions?
    public var summary: AISummary?
    /// The suggestion Kan made the call's title. Kan replaces only the automatic title, or one it
    /// set itself that nobody changed since (`record.title == appliedTitle`): a title the user
    /// chose never changes.
    public var appliedTitle: String?

    public init(titleSuggestions: AITitleSuggestions? = nil, summary: AISummary? = nil, appliedTitle: String? = nil) {
        self.titleSuggestions = titleSuggestions
        self.summary = summary
        self.appliedTitle = appliedTitle
    }

    public var isEmpty: Bool { titleSuggestions == nil && summary == nil && appliedTitle == nil }

    /// Decodes part by part: a part this build can't read (hand-edited, or from a newer Kan) is
    /// left out, never the whole call record.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        titleSuggestions = try? c.decodeIfPresent(AITitleSuggestions.self, forKey: .titleSuggestions)
        summary = try? c.decodeIfPresent(AISummary.self, forKey: .summary)
        appliedTitle = try? c.decodeIfPresent(String.self, forKey: .appliedTitle)
    }

    private enum CodingKeys: String, CodingKey {
        case titleSuggestions, summary, appliedTitle
    }

    /// A short fingerprint (16 hex digits) of the transcript Kan sends for a call: its lines with
    /// the speakers' names. Title ideas or a summary with another fingerprint were written from an
    /// older transcript, or before a speaker was renamed or a line edited.
    public static func fingerprint(of record: CallRecord) -> String {
        let lines = TranscriptRenderer.plainText(
            record, options: RenderOptions(includeFrontMatter: false, includeNotes: false, includeBookmarks: false,
                                           includeSummary: false, includeStatusNote: false))
        // FNV-1a, 64 bit: stable across launches and builds (unlike `Hasher`).
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lines.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

/// What an OpenAI request needs besides the call.
public struct AIOptions: Sendable, Equatable {
    public var apiKey: String
    /// An OpenAI model id, e.g. "gpt-6.1-terra".
    public var model: String
    public var language: AIOutputLanguage
    /// The user's name, for their own speaker while it still has the automatic name "Me".
    public var userName: String

    public init(apiKey: String, model: String, language: AIOutputLanguage, userName: String) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.userName = userName
    }
}

/// Why an OpenAI request failed. `message` is for the UI. `logDescription` names only the kind and
/// HTTP status: OpenAI's own error text can quote part of the key, so Kan never keeps it.
public enum AIError: Error, Sendable, Equatable {
    case missingKey
    /// The call has no transcript lines to send.
    case emptyTranscript
    /// HTTP 401.
    case invalidKey
    /// HTTP 429 `insufficient_quota`, `credit_balance_exhausted` or `billing_not_active`: no API
    /// credit left.
    case noCredit
    /// HTTP 429 `organization_spend_limit_exceeded`, `project_spend_limit_exceeded` or
    /// `organization_usage_limit_exceeded`: a limit the account set (or OpenAI's usage limit) stops
    /// requests until it's raised or the month ends.
    case spendLimit
    /// HTTP 429 for another reason: OpenAI's rate limits.
    case rateLimited
    /// The key can't use this model (`model_not_found`), or the model id can't be one (then "?").
    case modelUnavailable(String)
    /// HTTP 403 for another reason (the project's permissions, an unsupported region), or a 401 for a
    /// key without the permission (`missing_scope`).
    case notAllowed
    /// `context_length_exceeded`.
    case tooLong
    /// The model declined to answer, or OpenAI's safety checks rejected the call (`invalid_prompt`).
    case refused
    /// The answer was cut off (`status: incomplete`).
    case incomplete
    /// The answer couldn't be read (not the requested JSON).
    case badResponse
    /// HTTP 5xx, or another status Kan doesn't handle specifically.
    case server(status: Int)
    case offline
    case timedOut
    /// Another `URLError`, by code.
    case network(code: Int)

    public var message: String {
        switch self {
        case .missingKey: return "Add your OpenAI API key in Settings › OpenAI."
        case .emptyTranscript: return "This call has no transcript yet."
        case .invalidKey: return "OpenAI didn't accept the API key. Check it in Settings › OpenAI."
        case .noCredit: return "Your OpenAI account is out of API credit."
        case .spendLimit:
            return "Your OpenAI project or organization reached its spend or usage limit. "
                + "Raise it in OpenAI's Limits settings (platform.openai.com)."
        case .rateLimited: return "OpenAI is limiting requests right now. Try again in a minute."
        case .modelUnavailable(let model):
            return "This API key can't use the model “\(model)”. Choose another one in Settings › OpenAI."
        case .notAllowed: return "OpenAI refused requests from this key (its permissions or region)."
        case .tooLong: return "The transcript is too long for this model."
        case .refused: return "The model declined to answer."
        case .incomplete: return "OpenAI's answer was cut off. Try again."
        case .badResponse: return "Kan couldn't read OpenAI's answer. Try again."
        case .server(let status): return "OpenAI had a problem (HTTP \(status)). Try again later."
        case .offline: return "Can't reach OpenAI: this Mac is offline."
        case .timedOut: return "OpenAI took too long to answer. Try again."
        case .network(let code): return "Can't reach OpenAI (network error \(code))."
        }
    }

    /// Safe for kan.log: no text from OpenAI, the key or the call.
    public var logDescription: String {
        switch self {
        case .missingKey: return "missing key"
        case .emptyTranscript: return "empty transcript"
        case .invalidKey: return "invalid key (401)"
        case .noCredit: return "insufficient quota (429)"
        case .spendLimit: return "spend limit (429)"
        case .rateLimited: return "rate limited (429)"
        case .modelUnavailable(let model): return "model unavailable (\(model))"
        case .notAllowed: return "not allowed"
        case .tooLong: return "context length exceeded"
        case .refused: return "refused"
        case .incomplete: return "incomplete answer"
        case .badResponse: return "unreadable answer"
        case .server(let status): return "HTTP \(status)"
        case .offline: return "offline"
        case .timedOut: return "timed out"
        case .network(let code): return "URLError \(code)"
        }
    }

    /// Worth a Retry button: the same request may well work later.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .incomplete, .badResponse, .server, .offline, .timedOut, .network: return true
        default: return false
        }
    }
}

/// Writes title ideas and summaries with OpenAI (`OpenAIAssistant` in KanAI; a mock in the
/// self-test). Thread-safe. Errors are `AIError`s, or `CancellationError` when the task is cancelled.
public protocol CallAssisting: AnyObject, Sendable {
    func suggestTitles(for record: CallRecord, options: AIOptions) async throws -> AITitleSuggestions
    func summarize(_ record: CallRecord, options: AIOptions) async throws -> AISummary
    /// Checks a key: the ids of the models it can use.
    func availableModels(apiKey: String) async throws -> [String]
}

/// Where the OpenAI API key is kept: the login keychain in the app (`KeychainAPIKeyStore`), memory
/// in the self-test. Thread-safe. Reading the keychain can block: after each update of Kan, macOS
/// asks once whether Kan may use the item (the store then saves it again, so that build is never
/// asked again), so call these off the main thread.
public protocol APIKeyStoring: AnyObject, Sendable {
    /// nil when no key is saved, or it can't be read.
    func loadKey() -> String?
    func saveKey(_ key: String) throws
    func deleteKey() throws
}
