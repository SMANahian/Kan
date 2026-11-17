import Foundation
import KanTestKit

// Self-tests for KanAudio and KanDetect. No real audio is captured, no taps are created and no
// permission is requested: Core Audio sources, devices and the audio-client list are simulated.
//
//   swift build --product kan-selftest-audio && .build/debug/kan-selftest-audio [--filter <text>] [--list]

// Never touch the real ~/Documents/Kan or ~/Library/Application Support/Kan (logs go here too).
let kanHome = FileManager.default.temporaryDirectory.appendingPathComponent("kan-selftest-audio-\(getpid())", isDirectory: true)
setenv("KAN_HOME", kanHome.path, 1)

let suites = [
    stateMachineSuite(),
    ownerSuite(),
    wavSuite(),
    converterSuite(),
    ringSuite(),
    timelineSuite(),
    deviceSuite(),
    sessionSuite(),
    archiverSuite(),
    probeSuite(),
    detectorSuite(),
]
let code = await TestMain.run(suites)

// Everything this run wrote (logs, recordings, scratch directories) lives under KAN_HOME.
try? FileManager.default.removeItem(at: kanHome)
exit(code)
