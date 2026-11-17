import Foundation
import KanCore
import KanTestKit

// Self-tests for KanAgent (the `kan` CLI and MCP server). KAN_HOME is redirected before anything
// touches KanPaths, so the real ~/Documents/Kan and Application Support are never used; every
// library is built in its own temporary directory.
let testHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("kan-selftest-agent-\(getpid())", isDirectory: true)
try? FileManager.default.removeItem(at: testHome)
try? FileManager.default.createDirectory(at: testHome, withIntermediateDirectories: true)
setenv("KAN_HOME", testHome.path, 1)
KanLog.configure(fileName: "kan-selftest-agent.log")
// Writing to a subprocess that already exited must fail the test, not kill the runner.
signal(SIGPIPE, SIG_IGN)

let code = await TestMain.run([
    argumentTests(),
    dateTests(),
    resolverTests(),
    locationTests(),
    queryTests(),
    cliTests(),
    mcpProtocolTests(),
    mcpToolTests(),
    performanceTests(),
    endToEndTests(),
])

// KAN_KEEP_TEST_FILES=1 keeps the generated libraries. Otherwise remove only this process's
// directories: other test executables may be using kan-tests/ at the same time.
if ProcessInfo.processInfo.environment["KAN_KEEP_TEST_FILES"] == nil {
    let fm = FileManager.default
    try? fm.removeItem(at: testHome)
    let shared = fm.temporaryDirectory.appendingPathComponent("kan-tests", isDirectory: true)
    for name in (try? fm.contentsOfDirectory(atPath: shared.path)) ?? [] where name.hasSuffix("-\(getpid())") {
        try? fm.removeItem(at: shared.appendingPathComponent(name))
    }
    if (try? fm.contentsOfDirectory(atPath: shared.path))?.isEmpty == true { try? fm.removeItem(at: shared) }
}
exit(code)
