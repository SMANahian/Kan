import Foundation
import KanCore
import KanTestKit
import KanTranscribe

// Self-tests for KanTranscribe. Pure-logic suites always run; integration suites use the installed
// models in KanPaths.models (read-only) and skip when a model is missing.
//
// Nothing here touches the real ~/Documents/Kan or ~/Library/Application Support/Kan: KAN_HOME
// points at a temporary directory (model files are only read from KanPaths.models).
let home = scratchDirectory("home")
setenv("KAN_HOME", home.path, 1)
KanLog.configure(fileName: "kan-selftest-transcribe.log")
print("KanTranscribe self-test — whisper.cpp \(KanTranscribeModule.whisperVersion), models in \(KanPaths.models.path)")

let suites = unitSuites() + [modelStoreSuite(), downloadSuite()] + integrationSuites()
let status = await TestMain.run(suites)
try? FileManager.default.removeItem(at: scratchRoot)
exit(status)
