import AppKit
import SwiftUI

/// A borderless, non-activating floating panel for SwiftUI content. Clicking it never activates
/// Kan, so the call app keeps focus; it floats over full-screen apps on every Space.
/// `allowsKey`: whether it can take keyboard focus (the label panel's text fields).
final class FloatingPanel: NSPanel {
    private let allowsKey: Bool

    init(content: NSView, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelStack.width, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .utilityWindow
        contentView = content
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view whose buttons work on the first click even though the panel isn't key.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A hosting view sized to its content's ideal height; afterwards the panel stack owns the
    /// frame (SwiftUI reports height changes through `reportsPanelHeight`).
    static func make(_ rootView: Content) -> PanelHostingView<Content> {
        let view = PanelHostingView(rootView: rootView)
        view.setFrameSize(view.fittingSize)
        view.sizingOptions = []
        return view
    }
}

/// Mouse enter/exit tracking that also works while another app is active (`onHover` may not).
struct PanelHoverTracker: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Lays out Kan's floating panels in a column at the top right of the screen with the menu bar,
/// newest at the bottom; the label panel (priority 0) stays on top. Main-thread only.
@MainActor
final class PanelStack {
    static let shared = PanelStack()
    static let width: CGFloat = 360
    private static let margin: CGFloat = 10
    private static let spacing: CGFloat = 8

    private struct Entry {
        var id: AnyHashable
        var panel: FloatingPanel
        var height: CGFloat
        var priority: Int
        var order: Int
    }

    private var entries: [Entry] = []
    private var nextOrder = 0

    /// Shows `panel` without activating Kan. `makeKey` gives it keyboard focus (label panel).
    func show(_ panel: FloatingPanel, id: AnyHashable, priority: Int, makeKey: Bool = false) {
        remove(id: id)
        let height = max(40, panel.contentView?.frame.height ?? 80)
        entries.append(Entry(id: id, panel: panel, height: height, priority: priority, order: nextOrder))
        nextOrder += 1
        layout(animated: false, appearing: id)
        panel.alphaValue = 0
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    /// The SwiftUI content reports its height when it changes.
    func setHeight(_ height: CGFloat, for id: AnyHashable) {
        guard let index = entries.firstIndex(where: { $0.id == id }), abs(entries[index].height - height) > 0.5 else { return }
        entries[index].height = height
        layout(animated: true, appearing: nil)
    }

    func remove(id: AnyHashable) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let panel = entries.remove(at: index).panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        layout(animated: true, appearing: nil)
    }

    func panel(for id: AnyHashable) -> FloatingPanel? {
        entries.first { $0.id == id }?.panel
    }

    private func layout(animated: Bool, appearing: AnyHashable?) {
        guard let screen = Self.menuBarScreen() else { return }
        let visible = screen.visibleFrame
        var top = visible.maxY - Self.margin
        let ordered = entries.sorted { a, b in a.priority != b.priority ? a.priority < b.priority : a.order < b.order }
        for entry in ordered {
            let frame = NSRect(x: visible.maxX - Self.width - Self.margin, y: top - entry.height,
                               width: Self.width, height: entry.height)
            if animated && entry.id != appearing && entry.panel.isVisible {
                entry.panel.animator().setFrame(frame, display: true)
            } else {
                entry.panel.setFrame(frame, display: true)
            }
            top = frame.minY - Self.spacing
        }
    }

    /// The screen showing Kan's status item, else the primary screen.
    private static func menuBarScreen() -> NSScreen? {
        let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") }
        return statusWindow?.screen ?? NSScreen.screens.first ?? NSScreen.main
    }
}

extension View {
    /// Reports the view's ideal height to the panel stack (panels resize to fit their content).
    func reportsPanelHeight(id: AnyHashable) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                PanelStack.shared.setHeight(height, for: id)
            }
    }
}
