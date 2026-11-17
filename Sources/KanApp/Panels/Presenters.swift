import AppKit
import CoreGraphics
import Observation
import SwiftUI
import KanCore

/// Shows `AppModel.notices` as floating toasts (one panel each). Main-thread only.
@MainActor
final class ToastPresenter {
    private let model: AppModel
    private var shown: Set<UUID> = []

    init(model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        let notices = withObservationTracking { model.notices } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observe() }
            }
        }
        sync(notices)
    }

    private func sync(_ notices: [AppNotice]) {
        let current = Set(notices.map(\.id))
        for id in shown.subtracting(current) { PanelStack.shared.remove(id: id) }
        shown.formIntersection(current)
        for notice in notices where !shown.contains(notice.id) {
            shown.insert(notice.id)
            let content = NoticeView(noticeID: notice.id).environment(model)
            let panel = FloatingPanel(content: PanelHostingView.make(content), allowsKey: false)
            PanelStack.shared.show(panel, id: notice.id, priority: 1)
        }
    }
}

/// Shows the post-call label panel for `AppModel.presentedLabel` (top of the panel stack).
/// It takes keyboard focus unless the user is typing in another app right now.
@MainActor
final class LabelPanelPresenter {
    private let model: AppModel
    private var shownID: CallID?
    private static let panelID = "kan.label-panel"
    /// Keyboard idle time before the panel may take focus.
    private static let typingGrace: TimeInterval = 2

    init(model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        let presented = withObservationTracking { model.presentedLabel } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.observe() }
            }
        }
        sync(presented)
    }

    private func sync(_ id: CallID?) {
        guard id != shownID else { return }
        if shownID != nil { PanelStack.shared.remove(id: Self.panelID) }
        shownID = id
        guard let id else { return }
        let content = LabelPanelView(callID: id, panelID: Self.panelID)
            .environment(model)
            .id(id)
        let panel = FloatingPanel(content: PanelHostingView.make(content), allowsKey: true)
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        PanelStack.shared.show(panel, id: Self.panelID, priority: 0, makeKey: idle > Self.typingGrace)
    }
}

/// One toast: title, detail, a live countdown for "call ended", and the notice's buttons.
private struct NoticeView: View {
    let noticeID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notices.first(where: { $0.id == noticeID }) {
            content(notice)
                .padding(12)
                .frame(width: PanelStack.width, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                .background(PanelHoverTracker { model.noticeHoverChanged(noticeID, hovering: $0) })
                .reportsPanelHeight(id: noticeID)
        }
    }

    private func content(_ notice: AppNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(notice.style))
                .font(.title2)
                .foregroundStyle(tint(notice.style))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if notice.isDismissible {
                        Button {
                            model.dismissNotice(notice.id)
                        } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Close")
                    }
                }
                if case .ending(_, let deadline) = notice.kind {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = Int(max(0, deadline.timeIntervalSince(context.date)).rounded(.up))
                        Text("Saving in \(remaining) s")
                            .font(.callout.monospacedDigit())
                    }
                }
                if let message = notice.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notice.buttons.isEmpty {
                    NoticeButtonRow(spacing: 6) {
                        ForEach(notice.buttons) { button in
                            NoticeButton(button: button) { model.perform(button.command, on: notice.id) }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func symbol(_ style: AppNotice.Style) -> String {
        switch style {
        case .recording: return "record.circle.fill"
        case .question: return "questionmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "ear"
        }
    }

    private func tint(_ style: AppNotice.Style) -> Color {
        switch style {
        case .recording: return .red
        case .question: return .accentColor
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

/// A toast's buttons, left to right, wrapping onto another line when they don't fit the toast's
/// width (three buttons with a long app name: "Don't record", "Pause", "Never record Voice Lounge").
/// A button wider than a whole line gets the line's width (its title truncates).
struct NoticeButtonRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = Self.sizes(of: subviews, width: width)
        let lines = Self.lines(widths: sizes.map(\.width), width: width, spacing: spacing)
        let heights = lines.map { line in line.map { sizes[$0].height }.max() ?? 0 }
        let widths = lines.map { line in line.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(line.count - 1) }
        return CGSize(width: widths.max() ?? 0, height: heights.reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = Self.sizes(of: subviews, width: bounds.width)
        var y = bounds.minY
        for line in Self.lines(widths: sizes.map(\.width), width: bounds.width, spacing: spacing) {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for index in line {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - sizes[index].height) / 2),
                                      proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += height + spacing
        }
    }

    /// Each button's ideal size, no wider than a line.
    private static func sizes(of subviews: Subviews, width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return CGSize(width: min(ideal.width, width), height: ideal.height)
        }
    }

    /// The buttons on each line, by index: as many as fit in `width`, and at least one.
    static func lines(widths: [CGFloat], width: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var line: [Int] = []
        var used: CGFloat = 0
        for (index, buttonWidth) in widths.enumerated() {
            if !line.isEmpty && used + spacing + buttonWidth > width {
                lines.append(line)
                line = []
                used = 0
            }
            used += (line.isEmpty ? 0 : spacing) + buttonWidth
            line.append(index)
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}

private struct NoticeButton: View {
    let button: AppNotice.Button
    let action: () -> Void

    var body: some View {
        switch button.role {
        case .primary:
            Button(button.title, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .normal:
            Button(button.title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .destructive:
            Button(button.title, role: .destructive, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}
