import Foundation
import KanCore

/// Title ideas and summaries from OpenAI's Responses API (`POST /v1/responses`) with strict
/// structured outputs, and the key check (`GET /v1/models`).
///
/// Sends only what `OpenAIPrompts` builds from the call (never audio), with `"store": false`, and the
/// key only to the base URL. Retries (at most `retryDelays.count` times) rate limits, 500/502/503/504
/// and dropped connections, waiting `retryDelays` or the server's Retry-After. Retry-After is the
/// least the server will wait, so when it asks for more than `maxRetryAfter` (30 s) the error is
/// thrown at once rather than retried early. Billing stops (no credit, a spend limit) and policy
/// rejections are never retried. A model that rejects the `reasoning` or `max_output_tokens` field
/// gets one more try without it. Errors are `AIError`s, or `CancellationError` when the task is
/// cancelled.
///
/// Logs ("ai") call ids, counts, the model id, HTTP status, OpenAI's error code / type, durations and
/// token counts — never the key, the call's text, what the model wrote or OpenAI's error message.
public final class OpenAIAssistant: CallAssisting {
    /// https://api.openai.com/v1 (the literal always parses).
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1") ?? URL(fileURLWithPath: "/")
    /// Waits before the first and second retry.
    public static let defaultRetryDelays: [TimeInterval] = [2, 6]
    /// The longest Kan waits before a retry. A server that asks for longer (Retry-After) gets no
    /// retry: Kan never retries sooner than asked.
    public static let maxRetryAfter: TimeInterval = 30

    static let titlesTimeout: TimeInterval = 120
    static let summaryTimeout: TimeInterval = 300
    static let modelsTimeout: TimeInterval = 30
    /// `max_output_tokens` (reasoning tokens count too): only a bound on a runaway answer, far above
    /// what a good one takes.
    static let titlesMaxOutputTokens = 16_000
    static let summaryMaxOutputTokens = 64_000

    private let session: URLSession
    private let baseURL: URL
    private let retryDelays: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - session: defaults to `makeSession()` (ephemeral: no cookies, cache or credentials kept).
    ///   - sleep: waits between retries; tests pass one that returns at once. The default is
    ///     `Task.sleep(for:)`: cancelling a `Task.sleep(nanoseconds:)` awaited through this closure
    ///     aborted debug builds in the concurrency runtime ("freed pointer was not the last allocation").
    ///   - now: the clock for `generatedAt` and HTTP-date Retry-After values.
    public init(session: URLSession = OpenAIAssistant.makeSession(), baseURL: URL = OpenAIAssistant.defaultBaseURL,
                retryDelays: [TimeInterval] = OpenAIAssistant.defaultRetryDelays,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(for: .seconds(min(max(0, seconds), 3600)))
                },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.baseURL = baseURL
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.now = now
    }

    /// An ephemeral session that keeps no cookies, cache or credentials.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        // Each request sets its own timeout (2–5 min); this only bounds a request that trickles.
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    // MARK: - CallAssisting

    public func suggestTitles(for record: CallRecord, options: AIOptions) async throws -> AITitleSuggestions {
        let key = try Self.usableKey(options.apiKey)
        let model = try Self.modelID(options.model)
        guard OpenAIPrompts.hasTranscript(record) else { throw AIError.emptyTranscript }
        let started = Date()
        let input = OpenAIPrompts.input(for: record, userName: options.userName, transcriptLimit: OpenAIPrompts.titleTranscriptLimit)
        let request = ResponsesRequest(
            model: model, instructions: OpenAIPrompts.titleInstructions(language: options.language), input: input.text,
            schemaName: OpenAIPrompts.titlesSchemaName, schema: OpenAIPrompts.titlesSchema, effort: "low",
            maxOutputTokens: Self.titlesMaxOutputTokens, timeout: Self.titlesTimeout)
        let answer = try await respond(request, key: key, task: "title ideas", callID: record.id)
        let titles = OpenAIAnswer.cleanTitles(try OpenAIAnswer.titles(from: answer.text))
        guard !titles.isEmpty else {
            KanLog.debug("OpenAI title ideas for call \(record.id): none usable in the answer", category: "ai")
            throw AIError.badResponse
        }
        KanLog.debug("OpenAI title ideas for call \(record.id) (\(model)): \(titles.count) idea(s) in \(Self.seconds(since: started))"
                     + (input.shortened ? ", \(input.omittedLines) transcript lines left out" : "")
                     + (answer.usage.map { "; tokens \($0.logDescription)" } ?? ""), category: "ai")
        return AITitleSuggestions(titles: titles, model: model, generatedAt: now(),
                                  fingerprint: CallInsights.fingerprint(of: record))
    }

    public func summarize(_ record: CallRecord, options: AIOptions) async throws -> AISummary {
        let key = try Self.usableKey(options.apiKey)
        let model = try Self.modelID(options.model)
        guard OpenAIPrompts.hasTranscript(record) else { throw AIError.emptyTranscript }
        let started = Date()
        let input = OpenAIPrompts.input(for: record, userName: options.userName, transcriptLimit: OpenAIPrompts.summaryTranscriptLimit)
        let request = ResponsesRequest(
            model: model, instructions: OpenAIPrompts.summaryInstructions(language: options.language), input: input.text,
            schemaName: OpenAIPrompts.summarySchemaName, schema: OpenAIPrompts.summarySchema, effort: "medium",
            maxOutputTokens: Self.summaryMaxOutputTokens, timeout: Self.summaryTimeout)
        let answer = try await respond(request, key: key, task: "summary", callID: record.id)
        let fields = try OpenAIAnswer.summary(from: answer.text)
        let summary = AISummary(
            overview: fields.overview, keyPoints: fields.lists["keyPoints"] ?? [], ideas: fields.lists["ideas"] ?? [],
            decisions: fields.lists["decisions"] ?? [], actionItems: fields.lists["actionItems"] ?? [],
            openQuestions: fields.lists["openQuestions"] ?? [], language: options.language, model: model,
            generatedAt: now(), fingerprint: CallInsights.fingerprint(of: record), shortened: input.shortened)
        let items = fields.lists.values.reduce(0) { $0 + $1.count }
        KanLog.debug("OpenAI summary for call \(record.id) (\(model)): \(items) list item(s) in \(Self.seconds(since: started))"
                     + (input.shortened ? ", \(input.omittedLines) transcript lines left out" : "")
                     + (answer.usage.map { "; tokens \($0.logDescription)" } ?? ""), category: "ai")
        return summary
    }

    public func availableModels(apiKey: String) async throws -> [String] {
        let key = try Self.usableKey(apiKey)
        let url = baseURL.appendingPathComponent("models")
        let body = try await perform(task: "model list", callID: nil, model: nil) { _ in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.modelsTimeout)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return request
        }
        struct ModelList: Decodable {
            struct Entry: Decodable {
                var id: String?
                init(from decoder: Decoder) throws {
                    id = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .id)
                }
                private enum CodingKeys: String, CodingKey { case id }
            }
            var data: [Entry]
        }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else { throw AIError.badResponse }
        let ids = Set(list.data.compactMap { $0.id?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        KanLog.debug("OpenAI model list: \(ids.count) model(s)", category: "ai")
        return ids.sorted()
    }

    /// The title ideas Kan would keep from `titles`: single line, no wrapping quotes, list markers or
    /// trailing period, at most 100 characters, no empties or duplicates (ignoring case), at most 5.
    public static func cleanTitles(_ titles: [String]) -> [String] {
        OpenAIAnswer.cleanTitles(titles)
    }

    // MARK: - Requests

    /// The fields of a Responses request that a model may reject (a 400 naming one as its `param`):
    /// each is left out after the first such answer.
    private struct OptionalFields {
        var reasoning = true
        var outputLimit = true
    }

    private struct ResponsesRequest {
        var model: String
        var instructions: String
        var input: String
        var schemaName: String
        var schema: [String: Any]
        /// "low" / "medium"; nil leaves `reasoning` out.
        var effort: String?
        var maxOutputTokens: Int
        var timeout: TimeInterval

        func body(_ fields: OptionalFields) throws -> Data {
            var body: [String: Any] = [
                "model": model,
                "instructions": instructions,
                "input": input,
                "text": ["format": ["type": "json_schema", "name": schemaName, "strict": true, "schema": schema] as [String: Any]],
                "store": false,
            ]
            if fields.reasoning, let effort { body["reasoning"] = ["effort": effort] }
            if fields.outputLimit { body["max_output_tokens"] = maxOutputTokens }
            return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    /// Sends a Responses request and returns the text the model wrote.
    private func respond(_ request: ResponsesRequest, key: String, task: String,
                         callID: CallID) async throws -> (text: String, usage: OpenAIResponseBody.Usage?) {
        let url = baseURL.appendingPathComponent("responses")
        let body = try await perform(task: task, callID: callID, model: request.model) { fields in
            var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                urlRequest.httpBody = try request.body(fields)
            } catch {
                throw AIError.badResponse   // unreachable: the body is plain strings, numbers and booleans
            }
            return urlRequest
        }
        do {
            return try OpenAIAnswer.text(from: body, model: request.model)
        } catch let error as AIError {
            KanLog.debug("OpenAI \(task) for call \(callID): \(error.logDescription)", category: "ai")
            throw error
        }
    }

    /// Sends `makeRequest(fields)` until it gets a 2xx answer and returns its body; retries what may
    /// pass, maps the rest to `AIError`.
    private func perform(task: String, callID: CallID?, model: String?,
                         _ makeRequest: (OptionalFields) throws -> URLRequest) async throws -> Data {
        let subject = callID.map { "OpenAI \(task) for call \($0)" } ?? "OpenAI \(task)"
        var fields = OptionalFields()
        var retries = 0
        while true {
            try Task.checkCancellation()
            let request = try makeRequest(fields)
            let started = Date()
            let data: Data
            let response: HTTPURLResponse
            do {
                let (body, urlResponse) = try await session.data(for: request)
                guard let http = urlResponse as? HTTPURLResponse else { throw AIError.badResponse }
                data = body
                response = http
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let error = error as? AIError { throw error }
                let mapped = Self.map(error)
                guard Self.isRetryable(error), retries < retryDelays.count else {
                    KanLog.debug("\(subject): \(mapped.logDescription) after \(Self.seconds(since: started))", category: "ai")
                    throw mapped
                }
                let delay = retryDelays[retries]
                retries += 1
                KanLog.info("\(subject): \(mapped.logDescription); retrying in \(Self.format(delay)) s "
                            + "(retry \(retries) of \(retryDelays.count))", category: "ai")
                try await sleep(delay)
                continue
            }

            let status = response.statusCode
            if (200..<300).contains(status) {
                KanLog.debug("\(subject)\(model.map { " (\($0))" } ?? ""): HTTP \(status) in \(Self.seconds(since: started))",
                             category: "ai")
                return data
            }
            let detail = OpenAIErrorDetail.decode(data)
            let codes = detail.logDescription
            KanLog.debug("\(subject)\(model.map { " (\($0))" } ?? ""): HTTP \(status)\(codes.isEmpty ? "" : " (\(codes))") "
                         + "in \(Self.seconds(since: started))", category: "ai")
            if status == 400, fields.reasoning, detail.isAboutReasoning {
                fields.reasoning = false
                KanLog.info("\(subject): the model doesn't take a reasoning effort; trying again without it", category: "ai")
                continue
            }
            if status == 400, fields.outputLimit, detail.isAboutOutputLimit {
                fields.outputLimit = false
                KanLog.info("\(subject): the model doesn't take this output limit; trying again without it", category: "ai")
                continue
            }
            let error = Self.map(status: status, detail: detail, model: model)
            guard Self.isRetryable(status: status, error: error), retries < retryDelays.count else { throw error }
            let asked = retryAfter(response)
            // The least the server will wait: a retry before then would only be refused again.
            if let asked, asked > Self.maxRetryAfter {
                KanLog.info("\(subject): \(error.logDescription); OpenAI asked to wait \(Self.format(asked)) s, "
                            + "longer than Kan waits, so no retry", category: "ai")
                throw error
            }
            let delay = asked ?? min(Self.maxRetryAfter, retryDelays[retries])
            retries += 1
            KanLog.info("\(subject): \(error.logDescription); retrying in \(Self.format(delay)) s "
                        + "(retry \(retries) of \(retryDelays.count))", category: "ai")
            try await sleep(delay)
        }
    }

    // MARK: - Errors

    /// HTTP error → `AIError`, by OpenAI's error code first, then the status. OpenAI's message is
    /// never read.
    static func map(status: Int, detail: OpenAIErrorDetail, model: String?) -> AIError {
        if let billing = detail.billingError { return billing }
        if let model, detail.means("model_not_found") || ([400, 403, 404].contains(status) && detail.param == "model") {
            return .modelUnavailable(model)
        }
        if detail.means("context_length_exceeded") { return .tooLong }
        if detail.isPolicyRejection { return .refused }
        if detail.means("invalid_api_key") { return .invalidKey }
        // A restricted key without the permission this call needs (a 401), or a region OpenAI doesn't serve.
        if detail.means("missing_scope") || detail.means("unsupported_country_region_territory") { return .notAllowed }
        switch status {
        case 401: return .invalidKey
        case 403: return .notAllowed
        case 429: return .rateLimited
        default: return .server(status: status)
        }
    }

    /// A transport error → `AIError`.
    static func map(_ error: Error) -> AIError {
        guard let urlError = error as? URLError else { return .network(code: (error as NSError).code) }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .timedOut: return .timedOut
        default: return .network(code: urlError.errorCode)
        }
    }

    /// Connection-level failures worth another try (not timeouts: those already waited minutes).
    static func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(urlError.code)
    }

    static func isRetryable(status: Int, error: AIError) -> Bool {
        if error == .rateLimited { return true }
        return [500, 502, 503, 504].contains(status) && error == .server(status: status)
    }

    /// The wait the server asked for: `retry-after-ms`, or `Retry-After` in seconds or as an HTTP date.
    private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "retry-after-ms"), let ms = Double(value.trimmingCharacters(in: .whitespaces)),
           ms.isFinite, ms >= 0 {
            return ms / 1000
        }
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now()))
    }

    // MARK: - Helpers

    /// The key as sent: trimmed; missing → `.missingKey`. A key with spaces, control or non-ASCII
    /// characters inside can't be a real key (and mustn't reach a header) → `.invalidKey`.
    static func usableKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.missingKey }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { throw AIError.invalidKey }
        return trimmed
    }

    /// The model id as sent; empty → `KanSettings.defaultAIModel`. Text that can't be a model id
    /// (`OpenAIModels.isWellFormedID`), such as an API key pasted into the model field, is never sent,
    /// shown or logged → `.modelUnavailable("?")`.
    static func modelID(_ model: String) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return KanSettings.defaultAIModel }
        guard OpenAIModels.isWellFormedID(trimmed) else { throw AIError.modelUnavailable("?") }
        return trimmed
    }

    private static func seconds(since start: Date) -> String {
        format(Date().timeIntervalSince(start)) + " s"
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", max(0, seconds))
    }
}
