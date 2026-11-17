import AppKit
import SwiftUI
import KanCore

extension NSAttributedString.Key {
    /// Index of the transcript segment (in `LibraryTranscriptPlan.segments`) a character belongs to.
    static let librarySegmentIndex = NSAttributedString.Key("com.nahian.Kan.library.segmentIndex")
}

/// Speaker colors: the user is always the first color; other speakers follow the palette.
@MainActor
enum LibrarySpeakerColors {
    private static let palette: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemBrown,
        .systemIndigo, .systemRed, .systemCyan,
    ]

    static var count: Int { palette.count }

    static func nsColor(_ slot: Int?) -> NSColor {
        guard let slot else { return .secondaryLabelColor }
        return palette[((slot % palette.count) + palette.count) % palette.count]
    }

    static func color(_ slot: Int?) -> Color {
        Color(nsColor: nsColor(slot))
    }
}

/// A speaker offered by "Reassign to Speaker ▸" (and the 1–9 keys).
struct LibraryReaderSpeaker: Equatable {
    let id: String
    let label: String
}

/// The transcript as styled text: a `LibraryTranscriptPlan` with fonts, colors, timestamp links and
/// segment markers. Built on the main actor (AppKit fonts and colors).
struct LibraryTranscriptDocument {
    let callID: CallID
    let plan: LibraryTranscriptPlan
    let attributed: NSAttributedString
    let speakers: [LibraryReaderSpeaker]
    /// Changes whenever the text or its styling changes.
    let revision: Int

    @MainActor
    init(callID: CallID, plan: LibraryTranscriptPlan, record: CallRecord, colorSlots: [String: Int], fontSize: Double,
         revision: Int) {
        self.callID = callID
        self.plan = plan
        self.revision = revision
        speakers = LibrarySpeakerStats.displayOrder(record.speakers).map { speaker in
            LibraryReaderSpeaker(id: speaker.id, label: speaker.isMe ? "\(record.speakerName(speaker.id)) (me)"
                                                                      : record.speakerName(speaker.id))
        }

        let size = CGFloat(fontSize)
        let bodyStyle = NSMutableParagraphStyle()
        // Bangla's vowel signs reach well above and below the Latin x-height: give lines more air.
        bodyStyle.lineSpacing = (size * 0.32).rounded()
        bodyStyle.paragraphSpacing = 2
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.paragraphSpacingBefore = (size * 1.1).rounded()
        headerStyle.paragraphSpacing = 3
        let firstHeaderStyle = NSMutableParagraphStyle()
        firstHeaderStyle.paragraphSpacing = 3

        let text = NSMutableAttributedString(string: plan.string, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bodyStyle,
        ])
        let nameFont = NSFont.systemFont(ofSize: size - 1, weight: .semibold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: max(10, size - 2), weight: .regular)
        let length = text.length
        for (index, turn) in plan.turns.enumerated() {
            let headerParagraph = NSRange(location: turn.headerRange.location,
                                          length: min(turn.headerRange.length + 1, length - turn.headerRange.location))
            text.addAttribute(.paragraphStyle, value: index == 0 ? firstHeaderStyle : headerStyle, range: headerParagraph)
            text.addAttributes([
                .font: nameFont,
                .foregroundColor: LibrarySpeakerColors.nsColor(colorSlots[turn.turn.speakerID]),
            ], range: turn.nameRange)
            var timeAttributes: [NSAttributedString.Key: Any] = [.font: timeFont, .toolTip: "Play from here"]
            if let link = URL(string: "\(LibraryTranscriptView.seekScheme):\(turn.turn.start)") { timeAttributes[.link] = link }
            text.addAttributes(timeAttributes, range: turn.timeRange)
        }
        for (index, segment) in plan.segments.enumerated() {
            text.addAttribute(.librarySegmentIndex, value: index, range: segment.range)
            if segment.isEchoSuspect {
                text.addAttributes([
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .toolTip: "Possible echo: your microphone may have picked up the other side of the call.",
                ], range: segment.range)
            } else if segment.segment.flags.contains(.lowConfidence) || segment.segment.flags.contains(.hallucinationSuspect) {
                text.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor.tertiaryLabelColor,
                    .toolTip: "The recognizer wasn't sure about this part.",
                ], range: segment.range)
            }
        }
        attributed = text
    }
}

/// The transcript reader: an `NSTextView` (selectable across turns, clickable timestamps, per-segment
/// context menu) with playback, find and scroll highlights drawn as temporary attributes.
///
/// Keys while it has focus: Space plays/pauses, ←/→ seek 5 s, 1–9 reassign the segment under the
/// pointer (or the selection) to the n-th speaker, Esc clears the find; ⌥-click plays from a segment.
struct LibraryTranscriptView: NSViewRepresentable {
    static let seekScheme = "kan-seek"

    let document: LibraryTranscriptDocument
    let find: LibraryFindState
    let scrollRequest: LibraryTranscriptScroll?
    let focusToken: UUID?
    let followPlayback: Bool
    let player: LibraryPlayer
    let actions: LibraryTranscriptActions

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = LibraryTranscriptTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 24, height: 18)
        textView.linkTextAttributes = [.foregroundColor: NSColor.secondaryLabelColor, .cursor: NSCursor.pointingHand]
        textView.setAccessibilityLabel("Transcript")
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = actions
        coordinator.followPlayback = followPlayback
        coordinator.listen(to: player)
        coordinator.show(document)
        coordinator.show(find)
        coordinator.handle(scrollRequest)
        coordinator.focus(focusToken)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var actions = LibraryTranscriptActions()
        var followPlayback = true

        private weak var textView: LibraryTranscriptTextView?
        private weak var scrollView: NSScrollView?
        private weak var player: LibraryPlayer?
        private var listener: UUID?
        private var document: LibraryTranscriptDocument?
        private var find = LibraryFindState()
        private var playheadIndex: Int?
        private var appliedScroll: UUID?
        private var appliedFocus: UUID?
        private var lastUserScroll = Date.distantPast

        private enum Highlight {
            static let turn = NSColor.controlAccentColor.withAlphaComponent(0.07)
            static let segment = NSColor.controlAccentColor.withAlphaComponent(0.2)
            static let match = NSColor.systemYellow.withAlphaComponent(0.35)
            static let currentMatch = NSColor.systemOrange.withAlphaComponent(0.6)
        }

        func attach(textView: LibraryTranscriptTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            textView.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
            textView.menuProvider = { [weak self] index in self?.menu(forSegment: index) }
            textView.optionClickHandler = { [weak self] index in self?.playSegment(at: index) }
            NotificationCenter.default.addObserver(self, selector: #selector(userDidScroll(_:)),
                                                   name: NSScrollView.didLiveScrollNotification, object: scrollView)
        }

        func listen(to player: LibraryPlayer) {
            guard self.player !== player else { return }
            if let listener, let old = self.player { old.removeTimeListener(listener) }
            self.player = player
            listener = player.addTimeListener { [weak self] time in self?.playheadMoved(to: time) }
        }

        func detach() {
            if let listener, let player { player.removeTimeListener(listener) }
            listener = nil
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Content

        func show(_ document: LibraryTranscriptDocument) {
            guard document.revision != self.document?.revision || document.callID != self.document?.callID,
                  let textView, let storage = textView.textStorage else { return }
            let keepScroll = self.document?.callID == document.callID
            let origin = scrollView?.contentView.bounds.origin
            storage.setAttributedString(document.attributed)
            self.document = document
            playheadIndex = nil
            if let player, player.callID == document.callID {
                playheadIndex = document.plan.segmentIndex(playingAt: player.currentTime)
            }
            refreshHighlights()
            // A re-styled or edited transcript of the same call keeps its scroll position.
            if keepScroll, let origin, let scrollView, let layoutManager = textView.layoutManager,
               let container = textView.textContainer {
                layoutManager.ensureLayout(forBoundingRect: NSRect(origin: origin, size: scrollView.contentSize), in: container)
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        func show(_ find: LibraryFindState) {
            guard find != self.find else { return }
            let reveal = find.reveal && find.revision != self.find.revision
            self.find = find
            refreshHighlights()
            guard reveal, let current = find.current, current < find.ranges.count else { return }
            let range = find.ranges[current]
            whenLaidOut { [weak self] in
                self?.reveal(range, centered: false)
                self?.textView?.showFindIndicator(for: range)
            }
        }

        func handle(_ request: LibraryTranscriptScroll?) {
            guard let request, request.nonce != appliedScroll, let document, !document.plan.isEmpty else { return }
            appliedScroll = request.nonce
            let index = request.segmentID.flatMap { document.plan.segmentIndex(forID: $0) }
                ?? request.time.flatMap { document.plan.segmentIndex(nearest: $0) }
            guard let index else { return }
            let range = document.plan.segments[index].range
            whenLaidOut { [weak self] in
                self?.reveal(range, centered: true)
                self?.textView?.showFindIndicator(for: range)
            }
        }

        func focus(_ token: UUID?) {
            guard let token, token != appliedFocus else { return }
            appliedFocus = token
            whenLaidOut { [weak self] in
                guard let textView = self?.textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        // MARK: Playback

        private func playheadMoved(to time: Double) {
            guard let document, let player, player.callID == document.callID else { return }
            let index = document.plan.segmentIndex(playingAt: time)
            guard index != playheadIndex else { return }
            playheadIndex = index
            refreshHighlights()
            guard followPlayback, player.isPlaying, let index,
                  Date().timeIntervalSince(lastUserScroll) > 3 else { return }
            reveal(document.plan.segments[index].range, centered: false)
        }

        @objc private func userDidScroll(_ notification: Notification) {
            lastUserScroll = Date()
        }

        private func refreshHighlights() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let length = textView.textStorage?.length else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            guard let document, length > 0 else { return }
            func add(_ color: NSColor, _ range: NSRange) {
                guard range.location >= 0, range.upperBound <= length, range.length > 0 else { return }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            }
            if let index = playheadIndex, index < document.plan.segments.count {
                let segment = document.plan.segments[index]
                if segment.turnIndex < document.plan.turns.count {
                    add(Highlight.turn, document.plan.turns[segment.turnIndex].bodyRange)
                }
                add(Highlight.segment, segment.range)
            }
            for (index, range) in find.ranges.enumerated() {
                add(index == find.current ? Highlight.currentMatch : Highlight.match, range)
            }
        }

        // MARK: Scrolling

        /// Scrolls `range` into view: centered (well, at a third of the height), or only if it isn't
        /// comfortably visible already.
        private func reveal(_ range: NSRange, centered: Bool) {
            guard let textView, let scrollView, let rect = rect(for: range) else { return }
            let visible = scrollView.contentView.bounds
            if !centered && visible.insetBy(dx: 0, dy: min(60, visible.height * 0.15)).contains(rect) { return }
            let maxY = max(0, textView.frame.height - visible.height)
            let y = min(maxY, max(0, rect.minY - visible.height * 0.3))
            scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func rect(for range: NSRange) -> NSRect? {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let length = textView.textStorage?.length, range.upperBound <= length else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.ensureLayout(forGlyphRange: glyphs)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            return rect
        }

        /// Runs `work` on the next turn of the main actor, once the text view has a real width (right
        /// after it was created it may not have one yet).
        private func whenLaidOut(_ work: @escaping @MainActor () -> Void) {
            Task { @MainActor [weak self] in
                var attempts = 0
                while let textView = self?.textView, textView.frame.width <= 1, attempts < 20 {
                    attempts += 1
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard self?.textView != nil else { return }
                work()
            }
        }

        // MARK: Interaction

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let string = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            let prefix = LibraryTranscriptView.seekScheme + ":"
            guard string.hasPrefix(prefix), let time = Double(string.dropFirst(prefix.count)) else { return false }
            actions.seek(time, true)
            return true
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty else { return false }
            switch event.specialKey {
            case .leftArrow?:
                actions.skip(-5)
                return true
            case .rightArrow?:
                actions.skip(5)
                return true
            default:
                break
            }
            if event.keyCode == 49 {            // Space
                actions.togglePlay()
                return true
            }
            if event.keyCode == 53 {            // Escape
                return actions.escape()
            }
            if let characters = event.charactersIgnoringModifiers, let digit = Int(characters), (1...9).contains(digit),
               let document, digit <= document.speakers.count, let index = targetSegment() {
                actions.reassign(document.plan.segments[index].segment.id, document.speakers[digit - 1].id)
                return true
            }
            return false
        }

        /// The segment under the pointer, else the one where the selection starts.
        private func targetSegment() -> Int? {
            guard let textView, let document else { return nil }
            if let hovered = textView.hoveredSegment, hovered < document.plan.segments.count { return hovered }
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, selection.length > 0 else { return nil }
            return document.plan.segmentIndex(containing: selection.location)
        }

        private func playSegment(at index: Int) {
            guard let document, index < document.plan.segments.count else { return }
            actions.seek(document.plan.segments[index].segment.start, true)
        }

        private func menu(forSegment index: Int?) -> NSMenu? {
            guard let document, let textView else { return nil }
            let menu = NSMenu()
            let hasSelection = textView.selectedRange().length > 0
            if hasSelection {
                menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
            }
            if let index, index < document.plan.segments.count {
                let segment = document.plan.segments[index].segment
                if hasSelection { menu.addItem(.separator()) }
                menu.addItem(item("Play from Here", #selector(playFromHere(_:)), segment.id))
                if !hasSelection { menu.addItem(item("Copy", #selector(copySegment(_:)), segment.id)) }
                menu.addItem(item("Copy with Timestamp", #selector(copySegmentWithTimestamp(_:)), segment.id))
                menu.addItem(.separator())
                menu.addItem(item("Bookmark Here", #selector(bookmarkSegment(_:)), segment.id))
                if document.speakers.count > 1 {
                    let reassign = NSMenuItem(title: "Reassign to Speaker", action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for (n, speaker) in document.speakers.enumerated() {
                        let entry = item(speaker.label, #selector(reassignSegment(_:)), segment.id, speakerID: speaker.id)
                        if n < 9 {
                            entry.keyEquivalent = String(n + 1)
                            entry.keyEquivalentModifierMask = []
                        }
                        entry.state = speaker.id == segment.speakerID ? .on : .off
                        submenu.addItem(entry)
                    }
                    reassign.submenu = submenu
                    menu.addItem(reassign)
                }
            }
            return menu.items.isEmpty ? nil : menu
        }

        private func item(_ title: String, _ action: Selector, _ segmentID: Int, speakerID: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = LibrarySegmentTarget(segmentID: segmentID, speakerID: speakerID)
            return item
        }

        private func target(_ sender: NSMenuItem) -> LibrarySegmentTarget? {
            sender.representedObject as? LibrarySegmentTarget
        }

        @objc private func playFromHere(_ sender: NSMenuItem) {
            guard let target = target(sender), let document,
                  let index = document.plan.segmentIndex(forID: target.segmentID) else { return }
            playSegment(at: index)
        }

        @objc private func copySegment(_ sender: NSMenuItem) {
            guard let target = target(sender) else { return }
            actions.copy(target.segmentID, false)
        }

        @objc private func copySegmentWithTimestamp(_ sender: NSMenuItem) {
            guard let target = target(sender) else { return }
            actions.copy(target.segmentID, true)
        }

        @objc private func bookmarkSegment(_ sender: NSMenuItem) {
            guard let target = target(sender) else { return }
            actions.bookmark(target.segmentID)
        }

        @objc private func reassignSegment(_ sender: NSMenuItem) {
            guard let target = target(sender), let speakerID = target.speakerID else { return }
            actions.reassign(target.segmentID, speakerID)
        }
    }
}

/// What a context-menu item acts on.
final class LibrarySegmentTarget: NSObject {
    let segmentID: Int
    let speakerID: String?

    init(segmentID: Int, speakerID: String?) {
        self.segmentID = segmentID
        self.speakerID = speakerID
    }
}

/// The reader's text view: keeps a readable line length, reports the segment under the pointer and
/// routes keys, ⌥-clicks and context menus to the coordinator.
final class LibraryTranscriptTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    var menuProvider: ((Int?) -> NSMenu?)?
    var optionClickHandler: ((Int) -> Void)?
    /// The segment under the pointer (for the 1–9 reassign keys).
    private(set) var hoveredSegment: Int?

    private let readableWidth: CGFloat = 760
    private var hoverArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    /// Copy puts plain text on the pasteboard (not the reader's fonts and colors).
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = segmentIndex(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(index) ?? super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), event.clickCount == 1,
           let index = segmentIndex(at: convert(event.locationInWindow, from: nil)) {
            optionClickHandler?(index)
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredSegment = segmentIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredSegment = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(24, ((newSize.width - readableWidth) / 2).rounded(.down))
        if abs(textContainerInset.width - horizontal) >= 1 {
            textContainerInset = NSSize(width: horizontal, height: 18)
        }
    }

    /// The segment whose text is under `point` (view coordinates), if any.
    func segmentIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineRect.contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < storage.length else { return nil }
        return storage.attribute(.librarySegmentIndex, at: characterIndex, effectiveRange: nil) as? Int
    }
}
