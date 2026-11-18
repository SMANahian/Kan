import Foundation
import KanAI
import KanCore
import KanTestKit

// MARK: - A fake OpenAI server (URLProtocol), so no test ever reaches the network

/// One scripted answer.
enum StubReply: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    /// The connection fails with this error.
    case failure(URLError.Code)
    /// No answer: the request ends only when it is cancelled.
    case hang

    static func ok(_ body: Data) -> StubReply {
        .http(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }
}

/// A request as the server saw it.
struct RecordedRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data
    var timeout: TimeInterval

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The JSON body.
    func json() throws -> [String: Any] {
        try expectNotNil((try? JSONSerialization.jsonObject(with: body)) as? [String: Any], "the request body is a JSON object")
    }
}

/// The fake server of one test: replays its replies in order and records every request. Servers are
/// found by host (a fresh one per server, except for "api.openai.com"), so a request left over from
/// another test never takes this test's replies. The registry keeps them alive for the whole run.
final class StubServer: @unchecked Sendable {
    let host: String
    private let lock = NSLock()
    private var replies: [StubReply]
    private var recorded: [RecordedRequest] = []

    init(host: String = "\(UUID().uuidString.lowercased()).openai.test", _ replies: [StubReply]) {
        self.host = host
        self.replies = replies
        StubURLProtocol.register(self)
    }

    var requests: [RecordedRequest] { lock.withLock { recorded } }

    func baseURL() throws -> URL {
        try expectNotNil(URL(string: "https://\(host)/v1"))
    }

    /// An assistant that talks to this server, with a clock fixed at `testNow` and waits that
    /// `sleeper` records instead of sleeping.
    func assistant(sleeper: SleepRecorder = SleepRecorder(),
                   retryDelays: [TimeInterval] = OpenAIAssistant.defaultRetryDelays) throws -> OpenAIAssistant {
        let session = URLSession(configuration: StubURLProtocol.configuration())
        let base = host == "api.openai.com" ? OpenAIAssistant.defaultBaseURL : try baseURL()
        return OpenAIAssistant(session: session, baseURL: base, retryDelays: retryDelays,
                               sleep: { try await sleeper.sleep($0) }, now: { testNow })
    }

    /// Waits until the server has seen `count` requests.
    func waitForRequests(_ count: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while requests.count < count {
            guard Date() < deadline else { throw fail("the server saw \(requests.count) requests, expected \(count)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    fileprivate func reply(to request: RecordedRequest) -> StubReply? {
        lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer) { lock.withLock { servers[server.host] = server } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    // Every request, whatever its host: nothing a test sends may leave the process.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let recorded = RecordedRequest(method: request.httpMethod ?? "GET", url: url,
                                       headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request),
                                       timeout: request.timeoutInterval)
        let server = Self.lock.withLock { Self.servers[url.host ?? ""] }
        switch server?.reply(to: recorded) {
        case .http(let status, let headers, let body)?:
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code)?:
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang?:
            return
        case nil:
            // No server for this host, or no reply left: a test bug, made loud.
            let body = Data(#"{"error":{"message":"no scripted reply","type":"stub","code":"no_reply"}}"#.utf8)
            if let response = HTTPURLResponse(url: url, statusCode: 418, httpVersion: "HTTP/1.1", headerFields: nil) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Records the waits the assistant asks for and returns at once.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { values } }

    func sleep(_ seconds: TimeInterval) async throws {
        lock.withLock { values.append(seconds) }
        try Task.checkCancellation()
    }
}

// MARK: - OpenAI's JSON

enum OpenAIJSON {
    /// Compact JSON text, as a model writes it.
    static func text(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A Responses body: a reasoning item, then a message whose `output_text` parts are `parts`.
    static func response(_ parts: [String], status: String = "completed", refusal: String? = nil,
                         incompleteReason: String? = nil, error: [String: Any]? = nil) -> Data {
        var content: [[String: Any]] = parts.map { ["type": "output_text", "text": $0, "annotations": [Any]()] }
        if let refusal { content.append(["type": "refusal", "refusal": refusal]) }
        let body: [String: Any] = [
            "id": "resp_0123", "object": "response", "created_at": 1_763_398_800, "status": status,
            "error": error ?? NSNull(),
            "incomplete_details": incompleteReason.map { ["reason": $0] as Any } ?? NSNull(),
            "model": "gpt-6.1-terra-2026-10-01",
            "output": [
                ["type": "reasoning", "id": "rs_0123", "summary": [Any]()] as [String: Any],
                ["type": "message", "id": "msg_0123", "status": "completed", "role": "assistant", "content": content],
            ],
            "usage": [
                "input_tokens": 1234, "input_tokens_details": ["cached_tokens": 0],
                "output_tokens": 321, "output_tokens_details": ["reasoning_tokens": 200], "total_tokens": 1555,
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func titles(_ titles: [String]) -> StubReply {
        .ok(response([text(["titles": titles])]))
    }

    static func summary(overview: String, keyPoints: [String] = [], ideas: [String] = [], decisions: [String] = [],
                        actionItems: [String] = [], openQuestions: [String] = []) -> StubReply {
        .ok(response([text(["overview": overview, "keyPoints": keyPoints, "ideas": ideas, "decisions": decisions,
                            "actionItems": actionItems, "openQuestions": openQuestions])]))
    }

    /// An HTTP error with OpenAI's error body.
    static func error(_ status: Int, type: String?, code: String?, param: String? = nil,
                      message: String = "Something went wrong.", headers: [String: String] = [:]) -> StubReply {
        let error: [String: Any] = ["message": message, "type": type ?? NSNull(), "param": param ?? NSNull(), "code": code ?? NSNull()]
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error])) ?? Data()
        return .http(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: body)
    }

    static func models(_ ids: [String]) -> StubReply {
        let data = ids.map { ["id": $0, "object": "model", "created": 1, "owned_by": "system"] as [String: Any] }
        return .ok((try? JSONSerialization.data(withJSONObject: ["object": "list", "data": data])) ?? Data())
    }
}
