import Foundation
import KanCore
import KanTestKit

/// Builders for test records. Everything lives in temporary directories.
enum Fixture {
    static let newYork = "America/New_York"

    static func date(_ iso: String) -> Date {
        KanDate.parse(iso) ?? Date(timeIntervalSince1970: 0)
    }

    static func speakers(me: String = "Nahian", others: [String] = ["Prof. Rahman"]) -> [Speaker] {
        [Speaker(id: Speaker.meID, name: me, isMe: true)] + others.enumerated().map { i, name in
            Speaker(id: "s\(i + 1)", name: name, isMe: false,
                    nameSource: Speaker.isDefaultName(name) ? .automatic : .user)
        }
    }

    static func segment(_ id: Int, _ start: Double, _ end: Double, _ speaker: String, _ text: String,
                        language: String = "en", flags: [SegmentFlag] = []) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, speakerID: speaker,
                          channel: speaker == Speaker.meID ? .me : .them, text: text, language: language, flags: flags)
    }

    static func record(id: CallID = .generate(), title: String = "Advisor meeting", folder: String = "",
                       start: String = "2026-11-14T10:00:12-05:00", seconds: Double = 2533,
                       timeZone: String = newYork, app: String = "Zoom", platform: CallPlatform = .zoom,
                       tags: [String] = [], notes: String = "", starred: Bool = false, status: CallStatus = .ready,
                       speakers: [Speaker] = Fixture.speakers(), segments: [TranscriptSegment] = [],
                       bookmarks: [Bookmark] = [], languages: [String] = ["en"],
                       attendees: [String] = []) -> CallRecord {
        let started = date(start)
        return CallRecord(id: id, title: title, folder: folder, tags: tags, notes: notes, starred: starred,
                          startedAt: started, endedAt: started.addingTimeInterval(seconds), timeZone: timeZone,
                          source: CallSource(appName: app, platform: platform), status: status,
                          languages: languages, attendees: attendees, speakers: speakers, segments: segments,
                          bookmarks: bookmarks)
    }

    /// A summary as OpenAI writes it (in English, by GPT-6.1 Terra on Tue 17 Nov 2026).
    static func summary(overview: String, keyPoints: [String] = [], ideas: [String] = [], decisions: [String] = [],
                        actionItems: [String] = [], openQuestions: [String] = [], model: String = "gpt-6.1-terra",
                        generatedAt: Date = date("2026-11-17T09:30:00-05:00"), fingerprint: String = "",
                        shortened: Bool = false) -> AISummary {
        AISummary(overview: overview, keyPoints: keyPoints, ideas: ideas, decisions: decisions, actionItems: actionItems,
                  openQuestions: openQuestions, language: .english, model: model, generatedAt: generatedAt,
                  fingerprint: fingerprint, shortened: shortened)
    }

    /// A unit vector along `axis` (256-d like WeSpeaker), optionally tilted toward `toward`.
    static func vector(_ axis: Int, cosine: Float = 1, toward other: Int = 255, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[axis] = cosine
        v[other] = (1 - cosine * cosine).squareRoot()
        return v
    }
}

/// A library in a fresh temporary directory, with its own call-data directory.
struct TestLibrary {
    let base: URL
    let root: URL
    let calls: URL
    let store: LibraryStore

    init(_ name: String) {
        base = temporaryDirectory(name)
        root = base.appendingPathComponent("Library", isDirectory: true)
        calls = base.appendingPathComponent("Calls", isDirectory: true)
        let callsDirectory = calls
        store = LibraryStore(root: root, callDataDirectory: { callsDirectory.appendingPathComponent($0.rawValue, isDirectory: true) })
    }

    func callDirectory(_ id: CallID) -> URL {
        calls.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// A store reading the same root (a fresh process, e.g. the CLI).
    func reopened() -> LibraryStore {
        let callsDirectory = calls
        return LibraryStore(root: root, callDataDirectory: { callsDirectory.appendingPathComponent($0.rawValue, isDirectory: true) })
    }

    /// Every regular file under the root, as sorted relative paths (hidden files included).
    func files() -> [String] { listFiles(root) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func read(_ relative: String) -> String {
        (try? String(contentsOf: url(relative), encoding: .utf8)) ?? ""
    }
}

func listFiles(_ root: URL) -> [String] {
    let base = root.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    var out: [String] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        let path = url.resolvingSymlinksInPath().path
        out.append(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
    }
    return out.sorted()
}

/// Polls `condition` until it holds (the main queue keeps running meanwhile).
func eventually(_ what: String, timeout: Double = 10, file: String = #fileID, line: Int = #line,
                _ condition: () throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw TestFailure("timed out waiting for \(what)", file: file, line: line)
}

/// A value shared between threads in tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

/// Strict parser for the YAML subset in Kan's front matter. It rejects anything a YAML parser
/// would refuse or read as something else (plain scalars with indicators, ": " or " #", bad escapes).
enum MiniYAML {
    enum Value: Equatable, CustomStringConvertible {
        case quoted(String)
        case plain(String)
        case list([String])

        var string: String? {
            switch self {
            case .quoted(let s), .plain(let s): return s
            case .list: return nil
            }
        }

        var description: String {
            switch self {
            case .quoted(let s): return "\"\(s)\""
            case .plain(let s): return s
            case .list(let items): return "\(items)"
            }
        }
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    static func frontMatter(_ markdown: String) throws -> [(key: String, value: Value)] {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---" else { throw ParseError(description: "no opening ---") }
        var pairs: [(String, Value)] = []
        for line in lines.dropFirst() {
            if line == "---" { return pairs }
            guard let colon = line.range(of: ": ") else { throw ParseError(description: "no key in \(line)") }
            let key = String(line[..<colon.lowerBound])
            guard key.allSatisfy({ $0.isASCII && ($0.isLowercase || $0 == "_") }) else {
                throw ParseError(description: "bad key \(key)")
            }
            pairs.append((key, try value(String(line[colon.upperBound...]))))
        }
        throw ParseError(description: "no closing ---")
    }

    static func dictionary(_ markdown: String) throws -> [String: Value] {
        var out: [String: Value] = [:]
        for (key, value) in try frontMatter(markdown) {
            guard out[key] == nil else { throw ParseError(description: "duplicate key \(key)") }
            out[key] = value
        }
        return out
    }

    private static func value(_ text: String) throws -> Value {
        if text.hasPrefix("\"") {
            let (string, rest) = try quoted(Substring(text))
            guard rest.isEmpty else { throw ParseError(description: "junk after string: \(rest)") }
            return .quoted(string)
        }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw ParseError(description: "unterminated list \(text)") }
            var rest = Substring(text.dropFirst().dropLast())
            var items: [String] = []
            while !rest.isEmpty {
                if rest.hasPrefix("\"") {
                    let (item, after) = try quoted(rest)
                    items.append(item)
                    rest = after
                } else {
                    let end = rest.firstIndex(of: ",") ?? rest.endIndex
                    let item = String(rest[..<end])
                    try checkPlain(item, inFlow: true)
                    items.append(item)
                    rest = rest[end...]
                }
                if rest.hasPrefix(", ") {
                    rest = rest.dropFirst(2)
                } else if !rest.isEmpty {
                    throw ParseError(description: "bad list separator in \(text)")
                }
            }
            return .list(items)
        }
        try checkPlain(text, inFlow: false)
        return .plain(text)
    }

    private static func checkPlain(_ text: String, inFlow: Bool) throws {
        guard let first = text.first else { throw ParseError(description: "empty plain scalar") }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { throw ParseError(description: "plain scalar starts with indicator: \(text)") }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") {
            throw ParseError(description: "plain scalar with ': ' or ' #': \(text)")
        }
        if inFlow && text.contains(where: { ",[]{}".contains($0) }) {
            throw ParseError(description: "flow indicator in plain item: \(text)")
        }
        if text != text.trimmingCharacters(in: .whitespaces) { throw ParseError(description: "padded plain scalar") }
    }

    /// A double-quoted scalar at the start of `text`; returns it and the rest after the closing quote.
    private static func quoted(_ text: Substring) throws -> (String, Substring) {
        var scalars = Array(text.unicodeScalars.dropFirst())
        var out = String.UnicodeScalarView()
        var i = 0
        func hex(_ count: Int) throws -> Unicode.Scalar {
            guard i + count < scalars.count else { throw ParseError(description: "short escape") }
            let digits = String(String.UnicodeScalarView(scalars[(i + 1)...(i + count)]))
            guard let v = UInt32(digits, radix: 16), let s = Unicode.Scalar(v) else { throw ParseError(description: "bad hex \(digits)") }
            i += count
            return s
        }
        while i < scalars.count {
            let c = scalars[i]
            if c == "\"" {
                scalars.removeFirst(i + 1)
                return (String(out), Substring(String(String.UnicodeScalarView(scalars))))
            }
            if c.value < 0x20 && c != "\t" { throw ParseError(description: "raw control character in string") }
            if c == "\\" {
                guard i + 1 < scalars.count else { throw ParseError(description: "dangling backslash") }
                i += 1
                switch scalars[i] {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\u{0}")
                case " ": out.append(" ")
                case "N": out.append("\u{85}")
                case "L": out.append("\u{2028}")
                case "P": out.append("\u{2029}")
                case "x": out.append(try hex(2))
                case "u": out.append(try hex(4))
                case "U": out.append(try hex(8))
                default: throw ParseError(description: "unknown escape \\\(scalars[i])")
                }
            } else {
                out.append(c)
            }
            i += 1
        }
        throw ParseError(description: "unterminated string")
    }
}

/// What this process's log (kan-selftest-core.log) gained while `body` ran.
func loggedText(_ body: () async throws -> Void) async throws -> String {
    try await capturedLog(KanPaths.logs.appendingPathComponent("kan-selftest-core.log"),
                          log: { KanLog.info($0, category: "selftest") }, body)
}
