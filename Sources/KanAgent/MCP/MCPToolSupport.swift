import Foundation
import KanCore

/// A tool failure the model can act on (reported as a result with `isError: true`).
public struct ToolError: Error, LocalizedError, Equatable, Sendable {
    /// What went wrong, for the log: the message can quote call titles, folders and the agent's
    /// own arguments (a search, a title it looked for), and the log outlives the calls.
    public enum Kind: String, Sendable {
        case invalidArguments = "invalid arguments"
        case noCall = "no call given"
        case notFound = "no matching call"
        case ambiguous = "ambiguous call"
        case libraryUnreadable = "library unreadable"
        case callUnreadable = "call unreadable"
        case exportFailed = "export failed"
    }

    public let message: String
    public let kind: Kind
    /// Counts for the log ("2 candidates"); never call content.
    public let logDetail: String?

    public init(_ message: String, kind: Kind = .invalidArguments, logDetail: String? = nil) {
        self.message = message
        self.kind = kind
        self.logDetail = logDetail
    }

    public var errorDescription: String? { message }

    /// "ambiguous call (2 candidates)".
    public var logDescription: String { logDetail.map { "\(kind.rawValue) (\($0))" } ?? kind.rawValue }
}

/// What a tool returns: readable text for the model plus the same data as JSON.
struct ToolOutput {
    var text: String
    var structured: JSONValue
}

/// Shared state for tool implementations.
struct ToolContext {
    let library: AgentLibrary
    let now: @Sendable () -> Date
    let timeZone: TimeZone

    var store: LibraryStore { library.store }
    var dates: DateInput { DateInput(now: now(), timeZone: timeZone) }

    /// Fails with the load error when the library couldn't be read at all.
    func requireLibrary() throws {
        if let error = library.loadError {
            throw ToolError("Kan's library at \(library.root.path) couldn't be read: \(error)", kind: .libraryUnreadable)
        }
    }

    /// The call an agent means (full id, unique prefix, exact title or file path).
    func resolve(_ input: String) throws -> CallSummary {
        try requireLibrary()
        do {
            return try CallResolver.resolve(input, in: store.summaries(), root: library.root)
        } catch let error as CallResolutionError {
            switch error {
            case .notFound(let text):
                throw ToolError("No call matches “\(text)”. Use an id returned by list_calls or search_transcripts (never guess ids).",
                                kind: .notFound)
            case .empty:
                throw ToolError(error.localizedDescription, kind: .noCall)
            case .ambiguous(_, let candidates):
                throw ToolError(error.localizedDescription, kind: .ambiguous, logDetail: "\(candidates.count) candidates")
            }
        }
    }

    func record(_ summary: CallSummary) throws -> CallRecord {
        do {
            return try store.record(summary.id)
        } catch {
            throw ToolError("Couldn't read call \(summary.id): \(error.localizedDescription)", kind: .callUnreadable)
        }
    }
}

/// A tool's arguments, validated against its schema's property names.
///
/// Lenient where models commonly slip: `null` counts as absent, numbers may come as numeric
/// strings and booleans as "true"/"false". Unknown argument names are errors (they're usually typos).
struct ToolArguments {
    let values: [String: JSONValue]
    let tool: String

    init(_ values: [String: JSONValue], allowed: Set<String>, tool: String) throws {
        let unknown = values.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            let valid = allowed.sorted().joined(separator: ", ")
            throw ToolError("Unknown argument\(unknown.count == 1 ? "" : "s") for \(tool): \(unknown.joined(separator: ", ")). "
                            + (valid.isEmpty ? "This tool takes no arguments." : "Valid arguments: \(valid)."))
        }
        self.values = values.filter { !$0.value.isNull }
        self.tool = tool
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let s) = value else { throw ToolError("\(key) must be a string, not \(value.typeName).") }
        return s
    }

    /// A string with something in it.
    func requiredString(_ key: String, hint: String = "") throws -> String {
        guard let s = try string(key), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("\(key) is required." + (hint.isEmpty ? "" : " \(hint)"))
        }
        return s
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        switch value {
        case .bool(let b): return b
        case .string(let s) where ["true", "false"].contains(s.lowercased()): return s.lowercased() == "true"
        default: throw ToolError("\(key) must be true or false.")
        }
    }

    /// An integer ≥ `minimum`; values above `maximum` are lowered to it.
    func int(_ key: String, default fallback: Int, minimum: Int, maximum: Int) throws -> Int {
        guard let value = values[key] else { return fallback }
        let number: Int?
        switch value {
        case .string(let s): number = Int(s.trimmingCharacters(in: .whitespaces))
        default: number = value.intValue
        }
        guard let n = number else { throw ToolError("\(key) must be an integer.") }
        guard n >= minimum else { throw ToolError("\(key) must be at least \(minimum).") }
        return min(n, maximum)
    }

    /// Seconds from the call's start: a number, or "hh:mm:ss" / "mm:ss".
    func seconds(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        var result: Double?
        switch value {
        case .string(let s): result = Self.parseClock(s)
        default: result = value.doubleValue
        }
        guard let seconds = result, seconds.isFinite else {
            throw ToolError("\(key) must be a number of seconds from the call's start (or \"hh:mm:ss\").")
        }
        guard seconds >= 0 else { throw ToolError("\(key) can't be negative.") }
        return seconds
    }

    func choice(_ key: String, _ options: [String: String], default fallback: String) throws -> String {
        guard let raw = try string(key) else { return fallback }
        guard let chosen = options[raw.lowercased()] else {
            let valid = Set(options.values).sorted().joined(separator: ", ")
            throw ToolError("\(key) must be one of: \(valid).")
        }
        return chosen
    }

    func date(_ key: String, _ bound: DateBound, context: ToolContext) throws -> Date? {
        guard let text = try string(key), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            return try context.dates.parse(text, as: bound)
        } catch {
            throw ToolError("\(key): \(error.localizedDescription)")
        }
    }

    /// "1:02:03" / "02:03" / "75.5" → seconds.
    static func parseClock(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            if index < parts.count - 1 && (value.rounded() != value) { return nil }
            if index > 0 && value >= 60 { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// One MCP tool: definition plus implementation.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    /// JSON Schema properties, in display order.
    let properties: [(name: String, schema: JSONValue)]
    let required: [String]
    let run: (ToolArguments, ToolContext) throws -> ToolOutput

    var argumentNames: Set<String> { Set(properties.map(\.name)) }

    var definition: JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema) })),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": [
                "title": .string(title),
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ],
        ]
    }
}

/// JSON Schema fragments for tool inputs.
enum Schema {
    static func string(_ description: String, options: [String]? = nil, defaultValue: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let options { o["enum"] = .array(options.map { .string($0) }) }
        if let defaultValue { o["default"] = .string(defaultValue) }
        return .object(o)
    }

    static func integer(_ description: String, minimum: Int, maximum: Int? = nil, defaultValue: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer", "description": .string(description), "minimum": .int(minimum)]
        if let maximum { o["maximum"] = .int(maximum) }
        if let defaultValue { o["default"] = .int(defaultValue) }
        return .object(o)
    }

    static func number(_ description: String, minimum: Double) -> JSONValue {
        ["type": "number", "description": .string(description), "minimum": .double(minimum)]
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }
}
