import AppKit
import KanCore

/// Launch and quit: starts the model and the floating panels, turns SIGTERM into an orderly quit
/// and lets the model save a live recording before Kan exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting never waits longer than this for the recording to be finalized.
    static let terminationTimeout: TimeInterval = 20

    private var sigtermSource: DispatchSourceSignal?
    private var toastPresenter: ToastPresenter?
    private var labelPresenter: LabelPanelPresenter?
    private var terminationRequested = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        KanLog.configure(fileName: "kan.log")
        // Kan.app is LSUIElement; a development binary run outside the bundle behaves the same.
        if Bundle.main.bundleURL.pathExtension != "app" { NSApp.setActivationPolicy(.accessory) }
        let model = AppRuntime.model
        // A menu-bar app must never be terminated automatically for having no windows.
        ProcessInfo.processInfo.disableAutomaticTermination("Kan stays in the menu bar to detect calls")
        installSIGTERMHandler()
        model.ui = WindowRouter.shared
        toastPresenter = ToastPresenter(model: model)
        labelPresenter = LabelPanelPresenter(model: model)
        model.start()
        KanLog.info("Launched \(Bundle.main.bundleIdentifier ?? "(no bundle id)") from \(Bundle.main.bundlePath)")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Permissions are often changed in System Settings while Kan is in the background.
        AppRuntime.model.refreshPermissions()
        AppRuntime.model.refreshLoginItemStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening Kan again (Finder, Spotlight, `open -a Kan`) while it runs shows the library: a way
    /// in when the menu-bar icon is hidden — behind the notch when the menu bar is full, or by a
    /// menu-bar manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }        // a window is open: AppKit brings it to the front
        AppRuntime.model.openLibrary()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        terminationRequested = true
        let model = AppRuntime.model
        Task { @MainActor [weak self] in
            await model.prepareForTermination()
            self?.replyToTermination()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.terminationTimeout * 1_000_000_000))
            guard let self, !self.terminationReplied else { return }
            KanLog.error("Quitting before the recording was finalized (timed out after \(Int(Self.terminationTimeout)) s)")
            self.replyToTermination()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        KanLog.info("Kan quit")
    }

    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// `kill` / logout send SIGTERM: quit through NSApp so the recording is saved first.
    private func installSIGTERMHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                KanLog.info("SIGTERM received; quitting")
                NSApp.terminate(nil)
            }
        }
        source.resume()
        sigtermSource = source
    }
}
