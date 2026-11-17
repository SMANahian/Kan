import Foundation

// A tiny test harness: XCTest and Swift Testing don't run with Command Line Tools only.
//
//     let suite = TestSuite("Library")
//     suite.test("saves and reloads") {
//         try expectEqual(1 + 1, 2)
//     }
//     exit(await TestMain.run([suite]))
//
// Command-line flags understood by TestMain.run: `--filter <substring>`, `--list`.

public struct TestFailure: Error, CustomStringConvertible {
    public let message: String
    public let file: String
    public let line: Int

    public init(_ message: String, file: String = #fileID, line: Int = #line) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String { "\(file):\(line): \(message)" }
}

/// Thrown by a test body to mark it as skipped (e.g. a model file is missing).
public struct TestSkip: Error, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

public final class TestSuite {
    public let name: String
    fileprivate var tests: [(name: String, body: () async throws -> Void)] = []

    public init(_ name: String) { self.name = name }

    public func test(_ name: String, _ body: @escaping () async throws -> Void) {
        tests.append((name, body))
    }
}

public enum TestMain {
    /// Runs the suites and returns the process exit code (0 = all passed).
    public static func run(_ suites: [TestSuite], arguments: [String] = CommandLine.arguments) async -> Int32 {
        var filter: String?
        if let i = arguments.firstIndex(of: "--filter"), i + 1 < arguments.count { filter = arguments[i + 1] }
        if arguments.contains("--list") {
            for s in suites { for t in s.tests { print("\(s.name) / \(t.name)") } }
            return 0
        }
        var passed = 0, failed = 0, skipped = 0
        var failures: [String] = []
        let start = Date()
        for suite in suites {
            for t in suite.tests {
                let full = "\(suite.name) / \(t.name)"
                if let f = filter, !full.localizedCaseInsensitiveContains(f) { continue }
                let t0 = Date()
                do {
                    try await t.body()
                    passed += 1
                    print("  ✓ \(full) (\(ms(since: t0)))")
                } catch let skip as TestSkip {
                    skipped += 1
                    print("  ⤼ \(full) — skipped: \(skip.reason)")
                } catch {
                    failed += 1
                    let msg = "  ✗ \(full) — \(error)"
                    failures.append(msg)
                    print(msg)
                }
            }
        }
        print("")
        print("\(passed) passed, \(failed) failed, \(skipped) skipped in \(ms(since: start))")
        if !failures.isEmpty {
            print("Failures:")
            failures.forEach { print($0) }
        }
        fflush(stdout)
        return failed == 0 ? 0 : 1
    }

    private static func ms(since date: Date) -> String {
        let v = Date().timeIntervalSince(date)
        return v < 1 ? "\(Int(v * 1000)) ms" : String(format: "%.2f s", v)
    }
}

public func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                   file: String = #fileID, line: Int = #line) throws {
    if try !condition() {
        throw TestFailure("expectation failed. \(message())", file: file, line: line)
    }
}

public func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                                      file: String = #fileID, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure("expected \(expected), got \(actual). \(message())", file: file, line: line)
    }
}

public func expectClose(_ actual: Double, _ expected: Double, tolerance: Double,
                        _ message: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line) throws {
    if abs(actual - expected) > tolerance {
        throw TestFailure("expected \(expected) ± \(tolerance), got \(actual). \(message())", file: file, line: line)
    }
}

@discardableResult
public func expectNotNil<T>(_ value: T?, _ message: @autoclosure () -> String = "",
                            file: String = #fileID, line: Int = #line) throws -> T {
    guard let v = value else { throw TestFailure("unexpected nil. \(message())", file: file, line: line) }
    return v
}

public func expectThrows(_ message: @autoclosure () -> String = "", file: String = #fileID, line: Int = #line,
                         _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        return
    }
    throw TestFailure("expected an error. \(message())", file: file, line: line)
}

public func fail(_ message: String, file: String = #fileID, line: Int = #line) -> TestFailure {
    TestFailure(message, file: file, line: line)
}

/// A fresh, empty temporary directory (deleted on next call with the same name). Each test process
/// gets its own root ($TMPDIR/kan-tests/<executable>-<pid>/), so concurrent runs never collide;
/// never delete the shared kan-tests parent.
public func temporaryDirectory(_ name: String) -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "test").lastPathComponent
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kan-tests/\(exe)-\(getpid())/\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Directory with the repo's shared test audio (16 kHz mono WAVs). Override with KAN_TEST_AUDIO.
public var testAudioDirectory: URL {
    if let v = ProcessInfo.processInfo.environment["KAN_TEST_AUDIO"], !v.isEmpty {
        return URL(fileURLWithPath: v, isDirectory: true)
    }
    // <repo>/Tests/Audio, found relative to this source file.
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Tests/Audio", isDirectory: true)
}

/// The text a log file gained while `body` ran. `log` writes one line through the logger under
/// test; that logger appends asynchronously but in order, so the capture is complete once a marker
/// logged after `body` shows up. Reads `<file>.1` too, in case the log rotated meanwhile.
public func capturedLog(_ file: URL, log: (String) -> Void, timeout: TimeInterval = 10,
                        _ body: () async throws -> Void) async throws -> String {
    let token = UUID().uuidString
    let start = "log capture \(token) starts", end = "log capture \(token) ends"
    log(start)
    try await body()
    log(end)
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let rotated = FileManager.default.contents(atPath: file.path + ".1") ?? Data()
        let current = FileManager.default.contents(atPath: file.path) ?? Data()
        let text = String(decoding: rotated + current, as: UTF8.self)
        if let from = text.range(of: start), let to = text.range(of: end, range: from.upperBound..<text.endIndex) {
            return String(text[from.upperBound..<to.lowerBound])
        }
        guard Date() < deadline else { throw TestFailure("the log capture's end marker never reached \(file.lastPathComponent)") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
