import Foundation
import KanAgent
import KanCore
import KanTestKit

/// Finds the built `kan` executable: $KAN_CLI_PATH, else the one next to this test executable
/// (built with `swift build --product kan` when it's missing or older than this test).
enum KanBinary {
    static func locate() throws -> URL {
        let fm = FileManager.default
        if let explicit = ProcessInfo.processInfo.environment["KAN_CLI_PATH"], !explicit.isEmpty {
            guard fm.isExecutableFile(atPath: explicit) else { throw TestFailure("KAN_CLI_PATH=\(explicit) is not an executable") }
            return URL(fileURLWithPath: explicit)
        }
        let me = URL(fileURLWithPath: CLIContext.currentExecutablePath())
        let binDirectory = me.deletingLastPathComponent()
        let sibling = binDirectory.appendingPathComponent("kan")
        if fm.isExecutableFile(atPath: sibling.path), modified(sibling) >= modified(me) { return sibling }
        if ProcessInfo.processInfo.environment["KAN_SELFTEST_NO_BUILD"] == nil { try build(binDirectory) }
        guard fm.isExecutableFile(atPath: sibling.path) else {
            throw TestSkip("the kan executable isn't built (swift build --product kan, or set KAN_CLI_PATH)")
        }
        return sibling
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// `swift build --product kan` into the same build directory as this test.
    private static func build(_ binDirectory: URL) throws {
        // <package>/Sources/kan-selftest-agent/EndToEndTests.swift
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("Package.swift").path) else { return }
        let configuration = binDirectory.lastPathComponent        // "debug" / "release"
        let scratch = binDirectory.deletingLastPathComponent().deletingLastPathComponent()
        guard configuration == "debug" || configuration == "release", scratch.lastPathComponent.hasPrefix(".build")
                || FileManager.default.fileExists(atPath: scratch.appendingPathComponent("workspace-state.json").path) else { return }
        print("    (building kan for the end-to-end tests…)")
        let log = temporaryDirectory("agent-build").appendingPathComponent("build.log")
        let result = try runProcess(URL(fileURLWithPath: "/usr/bin/env"),
                                    ["swift", "build", "--package-path", package.path,
                                     "--scratch-path", spelledAsInvoked(scratch).path, "-c", configuration, "--product", "kan"],
                                    environment: ProcessInfo.processInfo.environment, timeout: 600, outputFile: log)
        if result.code != 0 {
            print("    swift build --product kan failed:\n" + result.stdout.suffix(2000))
        }
    }

    /// `scratch` written the way this test was started, e.g. /tmp/kan-build rather than the
    /// /private/tmp/kan-build its resolved path gives. Clang's module cache remembers the paths it
    /// was built through: one cache reached under two spellings ("module … is defined in both")
    /// breaks every later build there.
    private static func spelledAsInvoked(_ scratch: URL) -> URL {
        guard let argument = CommandLine.arguments.first, !argument.isEmpty else { return scratch }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let target = realPath(scratch)
        var candidate = URL(fileURLWithPath: argument, relativeTo: current).absoluteURL.standardizedFileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if realPath(candidate) == target { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return scratch
    }
}

/// realpath(3): symlinks resolved, "/private" kept (Foundation's resolvingSymlinksInPath drops it).
func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

struct ProcessResult {
    var code: Int32
    var stdout: String
    var stderr: String
}

/// Runs a process to completion; output goes through files (no pipe-buffer deadlocks).
func runProcess(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 60,
                outputFile: URL? = nil) throws -> ProcessResult {
    let directory = temporaryDirectory("agent-proc-\(UUID().uuidString.prefix(8))")
    let outURL = outputFile ?? directory.appendingPathComponent("stdout")
    let errURL = directory.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL)
    let err = try FileHandle(forWritingTo: errURL)
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = outputFile == nil ? err : out
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning {
        process.terminate()
        throw TestFailure("\(executable.lastPathComponent) \(arguments.joined(separator: " ")) timed out")
    }
    try out.close()
    try err.close()
    defer { try? FileManager.default.removeItem(at: directory) }
    return ProcessResult(code: process.terminationStatus,
                         stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                         stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
}

/// A long-running child with line-oriented stdin/stdout (the MCP transport).
final class LineSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var pending = Data()
    private var lines: [String] = []
    private var finished = false
    private var errorText = Data()
    /// Every stdout line ever received.
    private(set) var transcript: [String] = []

    init(_ executable: URL, _ arguments: [String], environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.received(data)
            if data.isEmpty { handle.readabilityHandler = nil }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if let self {
                self.condition.lock()
                self.errorText.append(data)
                self.condition.unlock()
            }
        }
        try process.run()
    }

    private func received(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        if data.isEmpty {
            finished = true
            if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
            pending = Data()
        } else {
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                lines.append(line)
                transcript.append(line)
                pending = Data(pending[(newline + 1)...])
            }
        }
        condition.broadcast()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func nextLine(timeout: TimeInterval = 20) throws -> String {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while lines.isEmpty && !finished {
            if !condition.wait(until: deadline) { break }
        }
        guard !lines.isEmpty else {
            throw TestFailure(finished ? "the server closed its output; stderr: \(stderr)" : "no response within \(timeout) s")
        }
        return lines.removeFirst()
    }

    /// The next message, parsed.
    func nextMessage(timeout: TimeInterval = 20) throws -> JSONValue {
        let line = try nextLine(timeout: timeout)
        do {
            return try JSONValue.parse(line)
        } catch {
            throw TestFailure("stdout carried a non-JSON line: \(line.prefix(200))")
        }
    }

    func closeInput() { try? input.fileHandleForWriting.close() }

    func waitForExit(timeout: TimeInterval = 15) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            throw TestFailure("the server didn't exit after its input closed")
        }
        return process.terminationStatus
    }

    var stderr: String {
        condition.lock()
        defer { condition.unlock() }
        return String(decoding: errorText, as: UTF8.self)
    }

    var pendingLineCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return lines.count
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}

func endToEndTests() -> TestSuite {
    let suite = TestSuite("End to end")

    func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return ["KAN_HOME": inherited["KAN_HOME"] ?? NSTemporaryDirectory(), "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
    }

    suite.test("`kan mcp` subprocess speaks MCP over stdio") {
        let binary = try KanBinary.locate()
        let fixture = try AgentFixture("e2e-mcp")
        let started = Date()
        let session = try LineSession(binary, ["mcp", "--library", fixture.root.path], environment: environment())

        try session.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"kan-selftest","version":"1.0"}}}"#)
        let initialize = try session.nextMessage()
        try expectEqual(initialize["id"], 1)
        try expectEqual(initialize["result"]?["protocolVersion"], "2025-11-25")
        try expectEqual(initialize["result"]?["serverInfo"]?["name"], "kan")
        print("    (initialize answered after \(Int(Date().timeIntervalSince(started) * 1000)) ms)")

        try session.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try session.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try session.nextMessage()
        try expectEqual(tools["id"], 2, "no reply to the notification came first")
        try expectEqual(tools["result"]?["tools"]?.arrayValue?.count, 9)

        try session.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_transcripts","arguments":{"query":"ভাষার মডেল"}}}"#)
        let search = try session.nextMessage()
        try expectEqual(search["id"], 3)
        let passage = try expectNotNil(search["result"]?["structuredContent"]?["passages"]?.arrayValue?.first)
        try expectEqual(passage["call_id"], .string(IDs.advisor.rawValue))
        try expectEqual(passage["timestamp"], "00:12:41")
        try expectContains(try expectNotNil(search["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue), "আর ভাষার মডেল")

        try session.send("{this is not json")
        let parseError = try session.nextMessage()
        try expectEqual(parseError["error"]?["code"], -32700)
        try expectEqual(parseError["id"], .null)

        try session.send(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        try expectEqual(try session.nextMessage()["result"], .object([:]))

        // A call saved by the app while the server runs shows up (the server re-checks every 3 s).
        try fixture.writer().save(CallRecord(
            id: fixtureID("J0"), title: "Saved while serving", startedAt: testNow, endedAt: testNow.addingTimeInterval(90),
            timeZone: "America/New_York", source: CallSource(appName: "Zoom", platform: .zoom), status: .ready))
        try await Task.sleep(nanoseconds: 3_300_000_000)
        try session.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_calls","arguments":{"limit":1}}}"#)
        let list = try session.nextMessage()
        try expectEqual(list["result"]?["structuredContent"]?["total"], 9)
        try expectEqual(list["result"]?["structuredContent"]?["calls"]?.arrayValue?.first?["title"], "Saved while serving")

        session.closeInput()
        try expectEqual(try session.waitForExit(), 0, "exits cleanly at end of input")
        try expectEqual(session.pendingLineCount, 0, "no unexpected output")
        for line in session.transcript {
            let message = try JSONValue.parse(line)
            try expectEqual(message["jsonrpc"], "2.0", "stdout carries only JSON-RPC: \(line.prefix(120))")
        }
        try expectNotContains(session.stderr, "jsonrpc", "protocol messages never go to stderr")
    }

    suite.test("`kan` subprocess: stdout, stderr and exit codes") {
        let binary = try KanBinary.locate()
        let fixture = try AgentFixture("e2e-cli")
        let env = environment()
        let list = try runProcess(binary, ["list", "--json", "--library", fixture.root.path], environment: env)
        try expectEqual(list.code, 0, list.stderr)
        try expectEqual(list.stderr, "")
        try expectEqual(try JSONValue.parse(list.stdout)["total"], 8)

        let search = try runProcess(binary, ["search", "--library", fixture.root.path, "augmentation"], environment: env)
        try expectEqual(search.code, 0)
        try expectContains(search.stdout, "[00:12:31] Prof. Rahman:")

        let missing = try runProcess(binary, ["show", "01ZZZZZZZZ", "--library", fixture.root.path], environment: env)
        try expectEqual(missing.code, ExitCode.notFound)
        try expectEqual(missing.stdout, "")
        try expectContains(missing.stderr, "No call matches")

        let ambiguous = try runProcess(binary, ["show", "Weekly sync", "--library", fixture.root.path], environment: env)
        try expectEqual(ambiguous.code, ExitCode.ambiguous)
        try expectContains(ambiguous.stderr, IDs.weekly1.rawValue)

        let usage = try runProcess(binary, ["list", "--nope"], environment: env)
        try expectEqual(usage.code, ExitCode.usage)

        // `kan transcribe` is wired to KanTranscribe: a missing file is a clean error on stderr.
        let transcribe = try runProcess(binary, ["transcribe", "/nonexistent/x.wav"], environment: env)
        try expectEqual(transcribe.code, 1)
        try expectEqual(transcribe.stdout, "")
        try expectContains(transcribe.stderr, "no such file")

        let config = try runProcess(binary, ["mcp-config"], environment: env)
        try expectContains(config.stdout, "claude mcp add kan -- \(realPath(binary)) mcp", "the executable's real path")

        let closedInput = try runProcess(binary, ["mcp", "--library", fixture.root.path], environment: env, timeout: 15)
        try expectEqual(closedInput.code, 0, "no input: exits at once")
        try expectEqual(closedInput.stdout, "")
    }
    return suite
}
