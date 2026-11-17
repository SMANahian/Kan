import AppKit
import ApplicationServices
import Foundation
import KanAudio
import KanCore
import os

/// Best-effort meeting info (platform, title, URL) for a call running in a browser.
public protocol MeetingProbing: AnyObject, Sendable {
    /// Blocks for at most a few seconds. Never call on the main thread.
    func probe(app: AppIdentity) -> MeetingInfo?
}

/// Finds the meeting tab of a browser call.
///
/// 1. Chrome-family browsers and Safari: AppleScript over every window's tabs — only when the browser
///    is already running and `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` says Kan
///    may automate it (never prompts, never launches a browser: the script itself is guarded by
///    `if application id … is running`).
/// 2. Any browser, including Zen and Firefox (no tab scripting): Accessibility window titles and the
///    web area's AXURL — only when `AXIsProcessTrusted()` is already true.
///
/// Meet tabs with a meeting code win, then other meeting platforms; query strings are dropped from
/// URLs (Zoom puts passcodes there). Thread-safe; AppleScripts run one at a time on a private queue.
public final class BrowserMeetingProbe: MeetingProbing, @unchecked Sendable {
    /// A browser tab or window as seen by AppleScript or Accessibility.
    public struct Tab: Sendable, Equatable {
        public var url: String?
        public var title: String
        public var isActive: Bool

        public init(url: String?, title: String, isActive: Bool = false) {
            self.url = url
            self.title = title
            self.isActive = isActive
        }
    }

    public let useAppleScript: Bool
    public let useAccessibility: Bool
    public let scriptTimeout: TimeInterval
    private let scriptQueue = DispatchQueue(label: "com.nahian.Kan.meeting-probe.applescript")

    public init(useAppleScript: Bool = true, useAccessibility: Bool = true, scriptTimeout: TimeInterval = 4) {
        self.useAppleScript = useAppleScript
        self.useAccessibility = useAccessibility
        self.scriptTimeout = scriptTimeout
    }

    public func probe(app: AppIdentity) -> MeetingInfo? {
        guard let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated else { return nil }
        let bundleID = running.bundleIdentifier ?? app.bundleID
        var tabs: [Tab] = []
        if useAppleScript, let family = ScriptableBrowsers.family(bundleID: bundleID),
           Permissions.automationStatus(pid: app.pid, askUserIfNeeded: false) == .granted {
            tabs += scriptTabs(bundleID: bundleID, family: family)
        }
        if let info = BrowserMeetingProbe.bestMeeting(in: tabs) { return info }
        if useAccessibility, AXIsProcessTrusted() {
            tabs = BrowserMeetingProbe.accessibilityWindows(pid: app.pid)
            return BrowserMeetingProbe.bestMeeting(in: tabs)
        }
        return nil
    }

    // MARK: AppleScript

    private func scriptTabs(bundleID: String, family: ScriptableBrowsers.Family) -> [Tab] {
        let source = BrowserMeetingProbe.appleScript(bundleID: bundleID, family: family)
        let result = OSAllocatedUnfairLock<String?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        scriptQueue.async {
            var error: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                KanLog.debug("meeting probe AppleScript for \(bundleID) failed: \(code)", category: "detect")
            }
            result.withLock { $0 = output }
            done.signal()
        }
        guard done.wait(timeout: .now() + scriptTimeout) == .success else {
            KanLog.debug("meeting probe AppleScript for \(bundleID) timed out", category: "detect")
            return []
        }
        return BrowserMeetingProbe.parseScriptOutput(result.withLock { $0 } ?? "")
    }

    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// One record per tab: URL ␟ title ␟ isActive ␞ (ASCII unit / record separators survive any title).
    public static func appleScript(bundleID: String, family: ScriptableBrowsers.Family) -> String {
        let id = bundleID.replacingOccurrences(of: "\"", with: "")
        let titleProperty = family == .safari ? "name" : "title"
        let activeIndex = family == .safari ? "index of current tab of w" : "active tab index of w"
        return """
        if application id "\(id)" is running then
            tell application id "\(id)"
                with timeout of 3 seconds
                    set fs to character id 31
                    set rs to character id 30
                    set out to ""
                    repeat with w in windows
                        try
                            set urls to URL of every tab of w
                            set titles to \(titleProperty) of every tab of w
                            set ai to 0
                            try
                                set ai to \(activeIndex)
                            end try
                            repeat with i from 1 to count of urls
                                set u to item i of urls
                                if u is missing value then set u to ""
                                set t to item i of titles
                                if t is missing value then set t to ""
                                set out to out & u & fs & t & fs & (i = ai) & rs
                            end repeat
                        end try
                    end repeat
                    return out
                end timeout
            end tell
        end if
        return ""
        """
    }

    public static func parseScriptOutput(_ output: String) -> [Tab] {
        output.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return nil }
            let url = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return Tab(url: url.isEmpty ? nil : url, title: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                       isActive: fields.count > 2 && fields[2].trimmingCharacters(in: .whitespacesAndNewlines) == "true")
        }
    }

    // MARK: Accessibility

    /// Window titles (the active tab of each window) and, when exposed, the web area's URL.
    /// Bounded: per-element messaging timeouts, a node budget per window and an overall deadline,
    /// so a hung browser can't hold the probe for long.
    static func accessibilityWindows(pid: pid_t, maxWindows: Int = 12, nodeBudget: Int = 400, timeLimit: TimeInterval = 3) -> [Tab] {
        let deadline = Date().addingTimeInterval(timeLimit)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows = elements(copy(app, kAXWindowsAttribute)) else { return [] }
        let focused = element(copy(app, kAXFocusedWindowAttribute))
        var tabs: [Tab] = []
        for window in windows.prefix(maxWindows) where Date() < deadline {
            AXUIElementSetMessagingTimeout(window, 0.5)
            let title = copy(window, kAXTitleAttribute) as? String ?? ""
            var budget = nodeBudget
            let url = webAreaURL(in: window, budget: &budget, deadline: deadline)
            let active = focused.map { CFEqual($0, window) } ?? false
            tabs.append(Tab(url: url, title: title, isActive: active))
        }
        return tabs
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// The value as an AXUIElement, if it is one (CF types can't be cast conditionally).
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func elements(_ value: CFTypeRef?) -> [AXUIElement]? {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return (unsafeBitCast(value, to: CFArray.self) as [AnyObject]).compactMap { element($0) }
    }

    /// Breadth-first search for an AXWebArea and its AXURL (a CFURL or a string, depending on the browser).
    private static func webAreaURL(in root: AXUIElement, budget: inout Int, deadline: Date) -> String? {
        var queue: [AXUIElement] = [root]
        var index = 0
        while index < queue.count, budget > 0, Date() < deadline {
            let element = queue[index]
            index += 1
            budget -= 1
            AXUIElementSetMessagingTimeout(element, 0.5)
            if copy(element, kAXRoleAttribute) as? String == "AXWebArea", let raw = copy(element, "AXURL") {
                if let url = raw as? URL { return url.absoluteString }
                if let s = raw as? String, !s.isEmpty { return s }
            }
            if let children = elements(copy(element, kAXChildrenAttribute)) {
                queue.append(contentsOf: children.prefix(64))
            }
        }
        return nil
    }

    // MARK: Pure mapping

    /// The most meeting-like tab. URLs decide when known; titles only when a tab has no URL.
    public static func bestMeeting(in tabs: [Tab]) -> MeetingInfo? {
        var best: (score: Int, info: MeetingInfo)?
        for tab in tabs {
            guard let candidate = meeting(for: tab) else { continue }
            let score = candidate.score + (tab.isActive ? 3 : 0)
            if let current = best, current.score >= score { continue }
            best = (score, candidate.info)
        }
        return best?.info
    }

    static func meeting(for tab: Tab) -> (score: Int, info: MeetingInfo)? {
        if let url = tab.url, !url.isEmpty {
            guard let platform = AppCatalog.platform(forURL: url) else { return nil }
            let code = googleMeetCode(inURL: url)
            let cleanURL = code.map { "https://meet.google.com/\($0)" } ?? sanitizedURL(url)
            let info = MeetingInfo(platform: platform, title: cleanTitle(tab.title, platform: platform), url: cleanURL)
            return (priority(platform, hasMeetCode: code != nil), info)
        }
        guard !tab.title.isEmpty, let platform = AppCatalog.platform(forWindowTitle: tab.title) else { return nil }
        let code = platform == .googleMeet ? googleMeetCode(inTitle: tab.title) : nil
        let info = MeetingInfo(platform: platform, title: cleanTitle(tab.title, platform: platform),
                               url: code.map { "https://meet.google.com/\($0)" })
        return (priority(platform, hasMeetCode: code != nil) - 1, info)
    }

    static func priority(_ platform: CallPlatform, hasMeetCode: Bool) -> Int {
        switch platform {
        case .googleMeet: return hasMeetCode ? 100 : 10
        case .zoom: return 90
        case .teams: return 85
        case .webex: return 80
        case .jitsi: return 75
        case .whereby: return 70
        case .slack: return 60
        case .discord: return 50
        case .whatsapp: return 40
        case .telegram: return 35
        case .messenger: return 30
        default: return 20
        }
    }

    private static let meetCodePattern = "[a-z]{3}-[a-z]{4}-[a-z]{3}"

    /// "https://meet.google.com/abc-defg-hij?authuser=0" → "abc-defg-hij".
    public static func googleMeetCode(inURL urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased(),
              host == "meet.google.com" || host.hasSuffix(".meet.google.com") else { return nil }
        let first = url.path.split(separator: "/").first.map(String.init) ?? ""
        return first.range(of: "^\(meetCodePattern)$", options: .regularExpression) != nil ? first : nil
    }

    /// "Meet - abc-defg-hij — Zen Browser" → "abc-defg-hij".
    public static func googleMeetCode(inTitle title: String) -> String? {
        guard let r = title.range(of: "(?<![a-z])\(meetCodePattern)(?![a-z])", options: .regularExpression) else { return nil }
        return String(title[r])
    }

    /// Scheme, host and path only — queries can carry passcodes.
    public static func sanitizedURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? urlString
    }

    private static let separators = [" - ", " — ", " – ", " | ", " · "]
    private static let browserNames: Set<String> = [
        "zen", "zen browser", "zen twilight", "mozilla firefox", "firefox", "firefox developer edition", "firefox nightly",
        "google chrome", "google chrome beta", "google chrome canary", "chrome", "chromium", "brave", "brave browser",
        "microsoft edge", "edge", "safari", "safari technology preview", "arc", "dia", "vivaldi", "opera", "opera gx",
        "orion", "waterfox", "comet",
    ]
    private static let statusPhrases: Set<String> = [
        "camera and microphone recording", "microphone recording", "camera recording", "microphone and camera recording",
        "audio playing", "audio muted", "playing audio", "screen sharing", "sharing your screen", "sharing this tab",
        "network error", "memory usage", "high memory usage",
    ]

    /// Strips what the browser adds around a page title: " — Zen Browser", " - Google Chrome - Profile",
    /// Chrome's " - Camera and microphone recording", leading "(3) " unread counters, "🔊".
    public static func stripBrowserDecorations(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "🔊", with: "").replacingOccurrences(of: "🔇", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = split(t)
        var changed = true
        while changed, segments.count > 1 {
            changed = false
            let last = normalized(segments[segments.count - 1].text)
            if browserNames.contains(last) || statusPhrases.contains(last) {
                segments.removeLast()
                changed = true
            } else if segments.count > 2, browserNames.contains(normalized(segments[segments.count - 2].text)),
                      segments[segments.count - 1].separator != " | " {
                segments.removeLast(2)                     // "… - Google Chrome - Work profile"
                changed = true
            }
        }
        t = segments.map { $0.separator + $0.text }.joined()
        if let r = t.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A clean meeting title, or nil when the title only names the platform (or is just a Meet code).
    public static func cleanTitle(_ title: String, platform: CallPlatform) -> String? {
        var t = stripBrowserDecorations(title)
        func dropPrefix(_ prefixes: [String]) {
            for p in prefixes where t.lowercased().hasPrefix(p.lowercased()) {
                t = String(t.dropFirst(p.count))
                return
            }
        }
        func dropSuffix(_ suffixes: [String]) {
            for s in suffixes where t.lowercased().hasSuffix(s.lowercased()) {
                t = String(t.dropLast(s.count))
                return
            }
        }
        switch platform {
        case .googleMeet:
            dropPrefix(["Meet - ", "Meet – ", "Meet — ", "Meet: ", "Google Meet - ", "Google Meet – "])
            dropSuffix([" - Google Meet", " – Google Meet", " — Google Meet", " | Google Meet"])
            if t.range(of: "^\(meetCodePattern)$", options: .regularExpression) != nil { return nil }
        case .teams:
            dropSuffix([" | Microsoft Teams", " - Microsoft Teams", " – Microsoft Teams", "| Microsoft Teams"])
            dropPrefix(["Microsoft Teams - ", "Microsoft Teams | "])
        case .zoom:
            dropSuffix([" - Zoom", " | Zoom", " - Zoom Workplace"])
        case .jitsi:
            dropSuffix([" | Jitsi Meet", " - Jitsi Meet", " – Jitsi Meet"])
        case .whereby:
            dropSuffix([" | Whereby", " - Whereby"])
        case .webex:
            dropSuffix([" - Webex", " | Webex", " - Cisco Webex"])
        case .discord:
            dropSuffix([" - Discord", " | Discord"])
        case .slack:
            dropSuffix([" - Slack", " | Slack"])
        case .whatsapp:
            dropSuffix([" - WhatsApp", " | WhatsApp"])
        case .telegram:
            dropSuffix([" - Telegram", " | Telegram"])
        default:
            break
        }
        t = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|·:")))
        let generic: Set<String> = [
            "", "meet", "google meet", "microsoft teams", "teams", "zoom", "zoom meeting", "zoom workplace", "webex",
            "cisco webex", "jitsi meet", "jitsi", "whereby", "discord", "slack", "whatsapp", "whatsapp web", "telegram",
            "telegram web", "messenger", "calendar", "chat", "activity", "meeting", "meetings", "new tab", "home",
        ]
        return generic.contains(t.lowercased()) ? nil : t
    }

    private struct Segment {
        var separator: String
        var text: String
    }

    private static func split(_ title: String) -> [Segment] {
        var segments: [Segment] = []
        var rest = Substring(title)
        var separator = ""
        while true {
            var earliest: (range: Range<Substring.Index>, sep: String)?
            for s in separators {
                guard let r = rest.range(of: s) else { continue }
                if let e = earliest, e.range.lowerBound <= r.lowerBound { continue }
                earliest = (r, s)
            }
            guard let found = earliest else {
                segments.append(Segment(separator: separator, text: String(rest)))
                return segments
            }
            segments.append(Segment(separator: separator, text: String(rest[..<found.range.lowerBound])))
            separator = found.sep
            rest = rest[found.range.upperBound...]
        }
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
