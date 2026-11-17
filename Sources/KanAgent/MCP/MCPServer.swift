import Foundation
import KanCore

/// A JSON-RPC error (a protocol-level failure; tool failures are results with `isError`).
public struct RPCError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603

    static func invalidRequest(_ detail: String) -> RPCError { RPCError(code: invalidRequestCode, message: "Invalid request: \(detail)") }
    static func methodNotFound(_ method: String) -> RPCError { RPCError(code: methodNotFoundCode, message: "Method not found: \(method)") }
    static func invalidParams(_ detail: String) -> RPCError { RPCError(code: invalidParamsCode, message: "Invalid params: \(detail)") }
}

/// Kan's MCP server: JSON-RPC 2.0, one message per line, read-only tools over the library.
///
/// Implements `initialize` (version negotiation), `notifications/initialized`, `ping`,
/// `tools/list` and `tools/call`; other methods get -32601, notifications never get a reply.
/// Tool failures (unknown call, bad argument values) are results with `isError: true` so the model
/// can correct itself; malformed requests get JSON-RPC errors. Before each tool call the library is
/// reloaded if its files changed (checked at most every `reloadInterval` seconds).
///
/// Thread-safety: not thread-safe — use one server from one thread (the stdio loop is serial).
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var latestProtocolVersion: String { supportedProtocolVersions[0] }
    /// `structuredContent` exists since this protocol version.
    static let structuredContentVersion = "2025-06-18"

    public let library: AgentLibrary
    public var reloadInterval: TimeInterval

    /// The version agreed in `initialize` (nil before it).
    public private(set) var negotiatedVersion: String?
    public private(set) var clientName: String?
    public private(set) var clientInitialized = false

    private let context: ToolContext
    private let tools: [MCPTool]

    /// - Parameters:
    ///   - reloadInterval: minimum seconds between checks for library changes (0 = every call).
    ///   - now / timeZone: how relative dates ("7d", "today") in tool arguments are read.
    public init(library: AgentLibrary, reloadInterval: TimeInterval = 3, now: @escaping @Sendable () -> Date = { Date() },
                timeZone: TimeZone = .current) {
        self.library = library
        self.reloadInterval = reloadInterval
        self.context = ToolContext(library: library, now: now, timeZone: timeZone)
        self.tools = MCPTools.all
    }

    /// Tool definitions as `tools/list` returns them.
    public var toolDefinitions: [JSONValue] { tools.map(\.definition) }

    // MARK: - Serving

    /// Reads messages until `readLine` returns nil (EOF) or `write` fails (the client went away).
    /// `write` gets one complete JSON message without the trailing newline. Returns the exit code.
    public func serve(readLine: () -> String?, write: (String) -> Bool) -> Int32 {
        KanLog.info("MCP server started for \(library.root.path) (\(library.store.summaries().count) calls)", category: "mcp")
        while let line = readLine() {
            guard let response = handle(line: line) else { continue }
            if !write(response) {
                KanLog.info("MCP client closed the connection", category: "mcp")
                return 0
            }
        }
        KanLog.info("MCP server stopped (end of input)", category: "mcp")
        return 0
    }

    /// Handles one line of input. Returns the response line, or nil when none is due (an empty
    /// line, a notification, a batch of notifications).
    public func handle(line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") { trimmed.removeFirst() }      // a byte-order mark some clients send first
        guard !trimmed.isEmpty else { return nil }
        let message: JSONValue
        do {
            message = try JSONValue.parse(trimmed)
        } catch {
            // Its size, not its text: it may hold a search or a call's notes.
            KanLog.warning("MCP: unparseable message (\(trimmed.utf8.count) bytes)", category: "mcp")
            return encode(Self.errorResponse(id: .null, RPCError(code: RPCError.parseErrorCode, message: "Parse error: the message is not valid JSON.")), id: .null)
        }
        guard let response = handle(message) else { return nil }
        return encode(response, id: message["id"] ?? .null)
    }

    /// Handles one parsed message (or batch). Returns the response, nil when none is due.
    public func handle(_ message: JSONValue) -> JSONValue? {
        if case .array(let items) = message {
            guard !items.isEmpty else { return Self.errorResponse(id: .null, .invalidRequest("empty batch")) }
            let responses = items.compactMap(handleSingle)
            return responses.isEmpty ? nil : .array(responses)
        }
        return handleSingle(message)
    }

    // MARK: - Dispatch

    private func handleSingle(_ message: JSONValue) -> JSONValue? {
        guard case .object(let fields) = message else {
            return Self.errorResponse(id: .null, .invalidRequest("a message must be a JSON object"))
        }
        let rawID = fields["id"]
        var id: JSONValue = .null
        if let rawID {
            switch rawID {
            case .string, .int: id = rawID
            case .double(let d) where d.rounded() == d: id = rawID
            default: return Self.errorResponse(id: .null, .invalidRequest("id must be a string or an integer"))
            }
        }
        guard fields["jsonrpc"] == .string("2.0") else {
            return Self.errorResponse(id: id, .invalidRequest("\"jsonrpc\" must be \"2.0\""))
        }
        guard let methodValue = fields["method"] else {
            if rawID != nil && (fields["result"] != nil || fields["error"] != nil) {
                // A response, but this server never sends requests.
                KanLog.debug("MCP: ignoring a response from the client", category: "mcp")
                return nil
            }
            return Self.errorResponse(id: id, .invalidRequest("\"method\" is missing"))
        }
        guard case .string(let method) = methodValue else {
            return Self.errorResponse(id: id, .invalidRequest("\"method\" must be a string"))
        }
        let params = fields["params"]
        if let params, params.objectValue == nil, params.arrayValue == nil, !params.isNull {
            return Self.errorResponse(id: id, .invalidRequest("\"params\" must be an object or an array"))
        }
        guard rawID != nil else {
            handleNotification(method)
            return nil
        }
        do {
            let result = try dispatch(method, params: params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            if error.code != RPCError.methodNotFoundCode {
                KanLog.warning("MCP \(method): \(error.message)", category: "mcp")
            }
            return Self.errorResponse(id: id, error)
        } catch {
            KanLog.error("MCP \(method) failed: \(KanLog.describe(error))", category: "mcp")
            return Self.errorResponse(id: id, RPCError(code: RPCError.internalErrorCode, message: "Internal error: \(error.localizedDescription)"))
        }
    }

    private func handleNotification(_ method: String) {
        switch method {
        case "notifications/initialized":
            clientInitialized = true
        case "notifications/cancelled":
            // Requests are answered one at a time, so there is never one in flight to cancel.
            break
        default:
            KanLog.debug("MCP: ignoring notification \(method)", category: "mcp")
        }
    }

    private func dispatch(_ method: String, params: JSONValue?) throws -> JSONValue {
        switch method {
        case "initialize": return try initialize(params)
        case "ping": return .object([:])
        case "tools/list":
            _ = try Self.object(params)
            return ["tools": .array(toolDefinitions)]
        case "tools/call": return try callTool(params)
        default: throw RPCError.methodNotFound(method)
        }
    }

    private func initialize(_ params: JSONValue?) throws -> JSONValue {
        let fields = try Self.object(params)
        guard let requested = fields["protocolVersion"]?.stringValue else {
            throw RPCError.invalidParams("protocolVersion (a string) is required")
        }
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion
        negotiatedVersion = version
        clientName = fields["clientInfo"]?["name"]?.stringValue
        KanLog.info("MCP initialize from \(clientName ?? "unknown client") (asked \(requested), using \(version))", category: "mcp")
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "kan", "title": "Kan", "version": .string(KanVersion.current)],
            "instructions": .string(MCPInstructions.text(library: library)),
        ]
    }

    private func callTool(_ params: JSONValue?) throws -> JSONValue {
        let fields = try Self.object(params)
        guard let name = fields["name"]?.stringValue else { throw RPCError.invalidParams("name (a string) is required") }
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw RPCError(code: RPCError.invalidParamsCode, message: "Unknown tool: \(name)")
        }
        let arguments: [String: JSONValue]
        switch fields["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let values)?: arguments = values
        case let other?: throw RPCError.invalidParams("arguments must be an object, not \(other.typeName)")
        }
        library.reloadIfChanged(minimumInterval: reloadInterval)
        let started = Date()
        do {
            let output = try tool.run(ToolArguments(arguments, allowed: tool.argumentNames, tool: name), context)
            KanLog.debug("MCP \(name) answered in \(Int(Date().timeIntervalSince(started) * 1000)) ms", category: "mcp")
            var result: [String: JSONValue] = ["content": [["type": "text", "text": .string(output.text)]]]
            if includesStructuredContent { result["structuredContent"] = output.structured }
            return .object(result)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            // The message goes to the agent only: it can quote titles, folders and the agent's own
            // query, so the log gets what kind of failure it was.
            let kind = (error as? ToolError)?.logDescription ?? "\(type(of: error))"
            KanLog.info("MCP \(name) → error: \(kind)", category: "mcp")
            return ["content": [["type": "text", "text": .string(message)]], "isError": true]
        }
    }

    /// Older protocol versions have no `structuredContent`.
    private var includesStructuredContent: Bool {
        (negotiatedVersion ?? Self.latestProtocolVersion) >= Self.structuredContentVersion
    }

    // MARK: - Helpers

    private static func object(_ params: JSONValue?) throws -> [String: JSONValue] {
        switch params {
        case nil, .null?: return [:]
        case .object(let fields)?: return fields
        case let other?: throw RPCError.invalidParams("params must be an object, not \(other.typeName)")
        }
    }

    /// JSONEncoder leaves U+0085, U+2028 and U+2029 raw inside strings; some line readers (Python's
    /// splitlines, JavaScript line terminators) break lines there. They only occur inside strings,
    /// so escaping them textually keeps each message on one line for every client.
    static func escapingLineSeparators(_ json: String) -> String {
        guard json.unicodeScalars.contains(where: { $0 == "\u{85}" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else { return json }
        var out = String.UnicodeScalarView()
        for scalar in json.unicodeScalars {
            switch scalar {
            case "\u{85}": out.append(contentsOf: "\\u0085".unicodeScalars)
            case "\u{2028}": out.append(contentsOf: "\\u2028".unicodeScalars)
            case "\u{2029}": out.append(contentsOf: "\\u2029".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    static func errorResponse(id: JSONValue, _ error: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }

    /// The response as one line. Encoding can't really fail (non-finite numbers become null), but
    /// a request must never go unanswered: fall back to an internal error for its id.
    private func encode(_ value: JSONValue, id: JSONValue) -> String? {
        do {
            return Self.escapingLineSeparators(try value.compactString())
        } catch {
            KanLog.error("MCP: couldn't encode a response: \(error)", category: "mcp")
            let safeID: JSONValue
            switch id {
            case .string, .int: safeID = id
            default: safeID = .null
            }
            let fallback = Self.errorResponse(id: safeID, RPCError(code: RPCError.internalErrorCode, message: "Internal error: the response couldn't be encoded."))
            return try? fallback.compactString()
        }
    }
}
