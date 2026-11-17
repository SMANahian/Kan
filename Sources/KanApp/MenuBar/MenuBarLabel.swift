import AppKit
import SwiftUI
import KanCore

/// UserDefaults keys for the menu-bar icon.
enum MenuBarDefaults {
    /// Show the timer (recording, ending countdown) and the transcription progress next to the icon.
    static let showsText = "menuBar.showsText"
}

/// The menu-bar icon. It updates live from the model (the recording timer ticks once a second).
/// States with text are drawn into one image (symbol + timer), which renders the same however
/// MenuBarExtra treats multi-view labels. The label appears at launch, so it's also where the
/// window router captures `openWindow` / `openSettings`.
///
/// The timer and progress are off by default: right of a MacBook's notch there's room for only a
/// few icons, macOS hides those that don't fit, and a wider icon would vanish during calls (when
/// macOS adds its own microphone indicator), just when Stop & Save is needed. The menu shows them.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MenuBarDefaults.showsText) private var showsText = false

    var body: some View {
        label
            .onAppear { WindowRouter.shared.capture(openWindow: openWindow, openSettings: openSettings) }
    }

    @ViewBuilder
    private var label: some View {
        switch model.menuBarIndicator {
        case .recording(let elapsed):
            Image(nsImage: MenuBarIcon.image(symbol: "record.circle.fill", text: detail(KanFormat.timer(elapsed)), tint: .systemRed))
                .renderingMode(.original)
        case .paused(let elapsed):
            Image(nsImage: MenuBarIcon.image(symbol: "pause.circle", text: detail(KanFormat.timer(elapsed))))
        case .ending(let remaining):
            Image(nsImage: MenuBarIcon.image(symbol: "record.circle.fill", text: detail("\(Int(remaining.rounded(.up))) s"),
                                             tint: .systemRed))
                .renderingMode(.original)
        case .stale(let elapsed):
            Image(nsImage: MenuBarIcon.image(symbol: "questionmark.circle", text: detail(KanFormat.timer(elapsed))))
        case .problem:
            Image(systemName: "ear.trianglebadge.exclamationmark")
        case .transcribing(let fraction):
            Image(nsImage: MenuBarIcon.image(symbol: "ear.badge.waveform", text: detail(fraction.map(KanFormat.percent))))
        case .needsLabeling(let count):
            Image(nsImage: MenuBarIcon.image(symbol: "ear", text: "\(count)"))
        case .idle:
            Image(systemName: "ear")
        }
    }

    /// The timer or progress, when the icon shows them. The needs-labeling count always shows:
    /// a digit is narrow.
    private func detail(_ text: String?) -> String? { showsText ? text : nil }
}

/// Status-bar images: an SF Symbol followed by monospaced text.
@MainActor
private enum MenuBarIcon {
    /// `tint` nil: a template image (macOS colours it for the menu bar). With a tint the symbol
    /// keeps that colour and the text follows the menu bar's appearance when drawn.
    static func image(symbol: String, text: String?, tint: NSColor? = nil) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let glyph = tint.flatMap { base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [$0])) } ?? base
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let textSize = text.map { ($0 as NSString).size(withAttributes: [.font: font]) } ?? .zero
        let gap: CGFloat = text == nil ? 0 : 3
        let size = NSSize(width: ceil(glyph.size.width + gap + textSize.width),
                          height: ceil(max(glyph.size.height, textSize.height, 16)))
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: 0, y: (rect.height - glyph.size.height) / 2,
                                   width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)
            if let text {
                let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color: NSColor = tint == nil ? .black : (dark ? .white : .black)
                (text as NSString).draw(at: NSPoint(x: glyphRect.maxX + gap, y: (rect.height - textSize.height) / 2),
                                        withAttributes: [.font: font, .foregroundColor: color])
            }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }
}
