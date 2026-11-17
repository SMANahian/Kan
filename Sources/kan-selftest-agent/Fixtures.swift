import Foundation
import KanAgent
import KanCore
import KanTestKit

/// Fixed clock for the tests: Tue 17 Nov 2026, 12:00 in New York.
let testNow = KanDate.parse("2026-11-17T12:00:00-05:00") ?? Date(timeIntervalSince1970: 0)
let newYork = TimeZone(identifier: "America/New_York") ?? .current

/// Deterministic call ids sharing the prefix "01KAX3" (so short prefixes are ambiguous).
func fixtureID(_ tail: String) -> CallID {
    let raw = "01KAX3" + tail
    return CallID(rawValue: raw + String(repeating: "0", count: max(0, 26 - raw.count)))
}

enum IDs {
    static let advisor = fixtureID("A0")
    static let labSync = fixtureID("B0")
    static let ammu = fixtureID("C0")
    static let weekly1 = fixtureID("D1")
    static let weekly2 = fixtureID("D2")
    static let processing = fixtureID("E0")
    static let seminar = fixtureID("F0")
    static let failed = fixtureID("G0")
}

/// A library of realistic calls (Bangla, English and code-switched) in a fresh temporary
/// directory, written through `LibraryStore` like the app does.
struct AgentFixture {
    let base: URL
    let root: URL
    let settingsFile: URL
    let calls: URL

    static let seminarSegments = 1000

    init(_ name: String, userName: String = "Nahian", populate: Bool = true) throws {
        base = temporaryDirectory("agent-\(name)")
        root = base.appendingPathComponent("Library", isDirectory: true)
        calls = base.appendingPathComponent("Calls", isDirectory: true)
        settingsFile = base.appendingPathComponent("AppSupport/settings.json")
        var settings = KanSettings()
        settings.userName = userName
        settings.libraryPath = root.path
        try SettingsStore(fileURL: settingsFile).save(settings)
        if populate {
            let store = writer()
            for record in AgentFixture.records() { try store.save(record) }
        }
    }

    /// A store that writes (the app's role); the agent code under test only reads.
    func writer() -> LibraryStore {
        let calls = self.calls
        return LibraryStore(root: root, callDataDirectory: { calls.appendingPathComponent($0.rawValue, isDirectory: true) })
    }

    func library() -> AgentLibrary {
        AgentLibrary.open(libraryArgument: root.path, environment: [:], currentDirectory: base, settingsFile: settingsFile)
    }

    func summary(_ id: CallID) throws -> CallSummary {
        try expectNotNil(writer().summary(id), "fixture call \(id)")
    }

    func markdownPath(_ id: CallID) throws -> String {
        root.appendingPathComponent(try summary(id).markdownPath).path
    }

    // MARK: Records

    static func date(_ iso: String) -> Date { KanDate.parse(iso) ?? Date(timeIntervalSince1970: 0) }

    static func segment(_ id: Int, _ start: Double, _ end: Double, _ speaker: String, _ text: String,
                        _ language: String = "en", flags: [SegmentFlag] = []) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, speakerID: speaker, channel: speaker == Speaker.meID ? .me : .them,
                          text: text, language: language, confidence: 0.91, flags: flags)
    }

    static func me(_ name: String = "Nahian", talk: Double = 0) -> Speaker {
        Speaker(id: Speaker.meID, name: name, isMe: true, nameSource: .automatic, talkTime: talk)
    }

    static func remote(_ id: String, _ name: String, talk: Double = 0, suggested: String? = nil) -> Speaker {
        Speaker(id: id, name: name, isMe: false, nameSource: Speaker.isDefaultName(name) ? .automatic : .user,
                talkTime: talk, suggestedName: suggested)
    }

    static func records() -> [CallRecord] {
        let advisorStart = date("2026-11-14T10:00:12-05:00")
        let advisor = CallRecord(
            id: IDs.advisor, title: "Advisor meeting – augmentation idea", folder: "Research/Thesis",
            tags: ["research", "thesis"], notes: "Try SpecAugment + speed perturbation on the Bangla set.\nAsk about compute.",
            starred: true, labeled: true, startedAt: advisorStart, endedAt: advisorStart.addingTimeInterval(2533),
            timeZone: "America/New_York",
            source: CallSource(appName: "Zoom", bundleID: "us.zoom.xos", platform: .zoom),
            status: .ready, languages: ["en", "bn"],
            speakers: [me(talk: 900), remote("s1", "Prof. Rahman", talk: 1300)],
            segments: [
                segment(0, 5, 9.5, "me", "So I was thinking about data augmentation for low-resource Bangla ASR."),
                segment(1, 10, 16, "me", "আমি ভাবছিলাম OpenSLR-এর বাংলা ডেটাসেট দিয়ে শুরু করা যায়।", "bn"),
                segment(2, 21, 27.5, "s1", "That's interesting. How many hours of Bangla speech does it have?"),
                segment(3, 28, 33, "me", "প্রায় দুইশো ঘণ্টা, কিন্তু অনেক noise আছে।", "bn"),
                segment(4, 751, 760, "s1", "Speed perturbation and SpecAugment would be a good augmentation baseline."),
                segment(5, 761, 770, "s1", "আর ভাষার মডেল আলাদা করে train করো।", "bn"),
                segment(6, 771, 776, "me", "Speed perturbation and SpecAugment would be a good baseline.", flags: [.echoSuspect]),
                segment(7, 2400, 2410, "me", "I'll send you the paper draft by Friday."),
            ],
            bookmarks: [Bookmark(id: "b1", time: 751, endTime: 770, note: "augmentation idea",
                                 createdAt: advisorStart.addingTimeInterval(800))],
            audio: AudioAssets(meFile: "me.m4a", themFile: "them.m4a", format: "m4a"))

        let labStart = date("2026-11-10T14:00:00-05:00")
        let lab = CallRecord(
            id: IDs.labSync, title: "Lab sync", folder: "", tags: ["lab"], startedAt: labStart,
            endedAt: labStart.addingTimeInterval(1800), timeZone: "America/New_York",
            source: CallSource(appName: "Zen", bundleID: "app.zen-browser.zen", platform: .googleMeet,
                               meetingTitle: "Meet - abc-defg-hij", meetingURL: "https://meet.google.com/abc-defg-hij"),
            status: .ready, languages: ["en", "bn"],
            speakers: [me(talk: 60), remote("s1", "Speaker 1", talk: 30, suggested: "Karim"), remote("s2", "Rahim", talk: 45)],
            segments: [
                segment(0, 3, 6, "me", "Rahim, did the GPU cluster job finish?"),
                segment(1, 7, 12, "s2", "হ্যাঁ, কালকে রাতে শেষ হয়েছে। Results ভালো।", "bn"),
                segment(2, 13, 18, "s1", "Let's discuss the dataset split next week."),
            ])

        let ammuStart = date("2026-11-12T21:00:00+06:00")
        let ammu = CallRecord(
            id: IDs.ammu, title: "আম্মুর সাথে কথা", folder: "Personal", tags: ["family"], starred: true, labeled: true,
            startedAt: ammuStart, endedAt: ammuStart.addingTimeInterval(900), timeZone: "Asia/Dhaka",
            source: CallSource(appName: "Telegram", bundleID: "com.tdesktop.Telegram", platform: .telegram),
            status: .ready, languages: ["bn"],
            speakers: [me(talk: 300), remote("s1", "আম্মু", talk: 400)],
            segments: [
                segment(0, 2, 4, "me", "আম্মু, তুমি কেমন আছো?", "bn"),
                segment(1, 5, 9, "s1", "ভালো আছি বাবা, তুমি খেয়েছো?", "bn"),
                segment(2, 10, 12, "me", "হ্যাঁ, এই মাত্র খেলাম।", "bn"),
            ])

        func weekly(_ id: CallID, _ start: String, _ line: String) -> CallRecord {
            let started = date(start)
            return CallRecord(
                id: id, title: "Weekly sync", folder: "Research", tags: ["weekly"], labeled: true, startedAt: started,
                endedAt: started.addingTimeInterval(1500), timeZone: "America/New_York",
                source: CallSource(appName: "Microsoft Teams", bundleID: "com.microsoft.teams2", platform: .teams),
                status: .ready, languages: ["en"], speakers: [me(), remote("s1", "Prof. Rahman")],
                segments: [segment(0, 4, 9, "s1", line)])
        }

        let processingStart = date("2026-11-16T15:30:00-05:00")
        let processing = CallRecord(
            id: IDs.processing, title: "Zoom call", startedAt: processingStart,
            endedAt: processingStart.addingTimeInterval(1260), timeZone: "America/New_York",
            source: CallSource(appName: "Zoom", bundleID: "us.zoom.xos", platform: .zoom), status: .processing)

        let failedStart = date("2026-11-15T08:00:00-05:00")
        let failed = CallRecord(
            id: IDs.failed, title: "Failed call", startedAt: failedStart, endedAt: failedStart.addingTimeInterval(600),
            timeZone: "America/New_York", source: CallSource(appName: "Slack", platform: .slack), status: .failed,
            processing: ProcessingInfo(error: "Model not installed: large-v3", attempts: 1))

        let seminarStart = date("2026-11-01T13:00:00-05:00")   // daylight saving ended that morning
        var lecture: [TranscriptSegment] = []
        for i in 0..<seminarSegments {
            let speaker = i % 2 == 0 ? "me" : "s1"
            let text = i % 10 == 3 ? "সেগমেন্ট \(i): ট্রান্সফর্মার মডেলের attention নিয়ে কথা।"
                                   : "Segment \(i) is about transformer attention."
            // 3 s apart with 1 s gaps between speakers: every segment is its own turn.
            lecture.append(segment(i, Double(i) * 3, Double(i) * 3 + 2, speaker, text, i % 10 == 3 ? "bn" : "en"))
        }
        let seminar = CallRecord(
            id: IDs.seminar, title: "Long seminar", folder: "Research/Seminars", tags: ["seminar"], labeled: true,
            startedAt: seminarStart, endedAt: seminarStart.addingTimeInterval(3000), timeZone: "America/New_York",
            source: CallSource(appName: "Zoom", bundleID: "us.zoom.xos", platform: .zoom), status: .ready,
            languages: ["en", "bn"], speakers: [me(), remote("s1", "Dr. Karim")], segments: lecture)

        return [advisor, lab, ammu,
                weekly(IDs.weekly1, "2026-11-03T09:00:00-05:00", "Status update on the thesis chapters."),
                weekly(IDs.weekly2, "2026-11-17T09:00:00-05:00", "Plan for the augmentation experiments."),
                processing, failed, seminar]
    }
}

// MARK: - In-process CLI

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String]] = []

    func record(_ item: [String]) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

struct CLIResult {
    var code: Int32
    var stdout: String
    var stderr: String

    func json() throws -> JSONValue {
        do {
            return try JSONValue.parse(stdout)
        } catch {
            throw TestFailure("stdout is not JSON: \(error)\n\(stdout.prefix(400))")
        }
    }
}

/// Runs `kan <arguments>` in-process against the fixture (its settings file names the library).
func runCLI(_ arguments: [String], _ fixture: AgentFixture, environment: [String: String] = [:],
            opened: Recorder? = nil, openError: Error? = nil, transcribed: Recorder? = nil,
            executable: String = "/Applications/Kan.app/Contents/MacOS/kan",
            mcpInput: [String] = []) async -> CLIResult {
    let out = TextSink.buffer(), err = TextSink.buffer()
    var input = mcpInput
    let context = CLIContext(
        environment: environment, currentDirectory: fixture.base, stdout: out, stderr: err,
        now: { testNow }, timeZone: newYork, executablePath: executable, settingsFile: fixture.settingsFile,
        openFile: { url in
            if let openError { throw openError }
            opened?.record([url.path])
        },
        transcribe: { args in
            transcribed?.record(args)
            return 7
        },
        mcpReadLine: { input.isEmpty ? nil : input.removeFirst() },
        mcpWriteLine: { line in out.write(line + "\n") },
        mcpReloadInterval: 0)
    let code = await KanCLI.run(arguments, context: context)
    return CLIResult(code: code, stdout: out.text, stderr: err.text)
}

func expectContains(_ text: String, _ needle: String, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if !text.contains(needle) {
        throw TestFailure("expected to find “\(needle)” in:\n\(text.prefix(1500))\n\(message)", file: file, line: line)
    }
}

func expectNotContains(_ text: String, _ needle: String, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if text.contains(needle) {
        throw TestFailure("did not expect “\(needle)” in:\n\(text.prefix(1500))\n\(message)", file: file, line: line)
    }
}

// MARK: - In-process MCP

/// Talks to an `MCPServer` through `handle(line:)`, exactly as the stdio loop does.
final class MCPHarness {
    let server: MCPServer
    private var nextID = 1

    init(_ library: AgentLibrary, reloadInterval: TimeInterval = 0) {
        server = MCPServer(library: library, reloadInterval: reloadInterval, now: { testNow }, timeZone: newYork)
    }

    /// Sends a raw line; returns the parsed response (nil when there was none).
    func send(_ line: String) throws -> JSONValue? {
        guard let response = server.handle(line: line) else { return nil }
        if response.contains("\n") { throw TestFailure("a response spans several lines") }
        return try JSONValue.parse(response)
    }

    func request(_ method: String, _ params: JSONValue? = nil) throws -> JSONValue {
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(id), "method": .string(method)]
        if let params { message["params"] = params }
        let response = try expectNotNil(try send(try JSONValue.object(message).compactString()), "response to \(method)")
        try expectEqual(response["id"], .int(id), "response id")
        try expectEqual(response["jsonrpc"], .string("2.0"))
        return response
    }

    func initialize(_ version: String = "2025-11-25") throws -> JSONValue {
        let response = try request("initialize", ["protocolVersion": .string(version), "capabilities": [:],
                                                  "clientInfo": ["name": "selftest", "version": "1"]])
        _ = try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return response
    }

    struct ToolResult {
        var raw: JSONValue
        var text: String
        var structured: JSONValue?
        var isError: Bool
    }

    func call(_ tool: String, _ arguments: [String: JSONValue] = [:]) throws -> ToolResult {
        let response = try request("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
        if let error = response["error"] { throw TestFailure("\(tool) → protocol error \(error)") }
        let result = try expectNotNil(response["result"], "result of \(tool)")
        let content = try expectNotNil(result["content"]?.arrayValue, "content of \(tool)")
        try expectEqual(content.count, 1)
        try expectEqual(content[0]["type"], .string("text"))
        let text = try expectNotNil(content[0]["text"]?.stringValue)
        return ToolResult(raw: result, text: text, structured: result["structuredContent"],
                          isError: result["isError"]?.boolValue ?? false)
    }

    /// A successful call's structured content.
    func structured(_ tool: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        let result = try call(tool, arguments)
        if result.isError { throw TestFailure("\(tool) failed: \(result.text)") }
        return try expectNotNil(result.structured, "structuredContent of \(tool)")
    }

    /// A call that must fail as a tool error; returns its message.
    func toolError(_ tool: String, _ arguments: [String: JSONValue] = [:]) throws -> String {
        let result = try call(tool, arguments)
        try expect(result.isError, "\(tool) should have failed, got: \(result.text.prefix(300))")
        try expect(result.structured == nil, "errors carry no structuredContent")
        return result.text
    }
}

extension JSONValue {
    /// The array at `key`, or a test failure.
    func array(_ key: String) throws -> [JSONValue] {
        try expectNotNil(self[key]?.arrayValue, "array \(key) in \((try? compactString().prefix(300)) ?? "")")
    }

    func string(_ key: String) throws -> String {
        try expectNotNil(self[key]?.stringValue, "string \(key) in \((try? compactString().prefix(300)) ?? "")")
    }

    func int(_ key: String) throws -> Int {
        try expectNotNil(self[key]?.intValue, "integer \(key) in \((try? compactString().prefix(300)) ?? "")")
    }
}

/// Every file under `root` with its contents, for "nothing was written" checks.
func snapshot(_ root: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        files[url.path] = FileManager.default.contents(atPath: url.path) ?? Data()
    }
    return files
}

/// What this process's log (kan-selftest-agent.log) gained while `body` ran.
func loggedText(_ body: () async throws -> Void) async throws -> String {
    try await capturedLog(KanPaths.logs.appendingPathComponent("kan-selftest-agent.log"),
                          log: { KanLog.info($0, category: "selftest") }, body)
}
