import Foundation

// Entry point. `KanApp --self-test` runs the headless self-test (mock services, a temporary
// KAN_HOME, no windows or status items) and exits 0/1; otherwise the menu-bar app starts.
if CommandLine.arguments.contains("--self-test") {
    SelfTest.launch()
}
MainActor.assumeIsolated {
    KanMenuBarApp.main()
}
