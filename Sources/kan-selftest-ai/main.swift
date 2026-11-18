import Foundation
import KanCore
import KanTestKit

// Self-tests for KanAI (OpenAI title ideas and summaries). No test reaches the network: every
// request goes to a URLProtocol stub (Stub.swift) that answers with scripted OpenAI responses. The
// login keychain is used only with KAN_TEST_KEYCHAIN=1, under a throwaway service name. KAN_HOME is
// redirected before anything touches KanPaths, so kan.log and the library stay in a temporary
// directory.
let testHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("kan-selftest-ai-\(getpid())", isDirectory: true)
try? FileManager.default.removeItem(at: testHome)
try? FileManager.default.createDirectory(at: testHome, withIntermediateDirectories: true)
setenv("KAN_HOME", testHome.path, 1)
// Debug lines reach the log file in release builds too: the privacy test reads them.
setenv("KAN_DEBUG", "1", 1)
KanLog.configure(fileName: "kan-selftest-ai.log")

let code = await TestMain.run([
    requestTests(),
    responseTests(),
    errorTests(),
    modelTests(),
    keyStoreTests(),
    privacyTests(),
])

// KAN_KEEP_TEST_FILES=1 keeps the test home (and its log) for inspection.
if ProcessInfo.processInfo.environment["KAN_KEEP_TEST_FILES"] == nil {
    try? FileManager.default.removeItem(at: testHome)
}
exit(code)
