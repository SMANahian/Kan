import AppKit
import SwiftUI
import KanCore

/// Kan is an accessory app (LSUIElement): no Dock icon, and its windows open *behind* the
/// frontmost app unless it activates. Proven in the packaging spike on macOS 26: only
/// `.regular` + `activate(ignoringOtherApps: true)` reliably gives a window key focus; Kan goes
/// back to `.accessory` when its last titled window closes.
@MainActor
enum AppActivation {
    static func activateForWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call when one of Kan's titled windows closes.
    static func windowClosed() {
        // One run-loop turn later, the closing window is no longer visible.
        DispatchQueue.main.async {
            let remaining = NSApp.windows.filter { $0.isVisible && isUserFacing($0) }
            if remaining.isEmpty, NSApp.activationPolicy() != .accessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Titled windows (library, settings, onboarding) — not the status item, the menu panel or
    /// Kan's floating panels.
    static func isUserFacing(_ window: NSWindow) -> Bool {
        let name = String(describing: type(of: window))
        if name.contains("StatusBar") || name.contains("MenuBarExtra") || window is NSPanel { return false }
        return window.styleMask.contains(.titled)
    }

    static func bringToFront(_ window: NSWindow) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { window.orderFrontRegardless() }
    }
}

/// Opens Kan's SwiftUI scenes from anywhere (the model, hot keys, panels). The actions are
/// captured from the menu-bar label, which appears at launch; requests made earlier wait.
@MainActor
final class WindowRouter: AppUIBridge {
    static let shared = WindowRouter()

    private var openWindowAction: OpenWindowAction?
    private var openSettingsAction: OpenSettingsAction?
    private var waiting: [@MainActor () -> Void] = []

    func capture(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        let first = openWindowAction == nil
        openWindowAction = openWindow
        openSettingsAction = openSettings
        if first {
            let queued = waiting
            waiting.removeAll()
            queued.forEach { $0() }
        }
    }

    func openLibrary() { open(SceneID.library) }

    func openOnboarding() { open(SceneID.onboarding) }

    func openSettings() {
        guard let action = openSettingsAction else {
            waiting.append { [weak self] in self?.openSettings() }
            return
        }
        AppActivation.activateForWindow()
        action()
    }

    private func open(_ id: String) {
        guard let action = openWindowAction else {
            waiting.append { [weak self] in self?.open(id) }
            return
        }
        AppActivation.activateForWindow()
        action(id: id)
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
private struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

extension View {
    /// Window behavior for Kan's titled windows: activates Kan and brings the window forward when
    /// it appears (also when opened by ⌘, or SettingsLink, which can't run code first), never
    /// restores it at launch, and returns to accessory mode when the last one closes.
    func managedWindow() -> some View {
        background(WindowReader { window in
            window.isRestorable = false
            AppActivation.activateForWindow()
            AppActivation.bringToFront(window)
        })
        .onDisappear { AppActivation.windowClosed() }
    }
}
