import AppKit
import Foundation
import KanAudio
import KanCore
import KanDetect
import KanTestKit

typealias Tab = BrowserMeetingProbe.Tab

func probeSuite() -> TestSuite {
    let suite = TestSuite("Browser meeting probe (parsing)")

    suite.test("AppleScript output → tabs") {
        let output = "https://meet.google.com/abc-defg-hij?authuser=0\u{1F}Meet - abc-defg-hij\u{1F}true\u{1E}"
            + "https://mail.google.com/mail/u/0/\u{1F}Inbox (3) - me@example.com\u{1F}false\u{1E}"
            + "\u{1F}Untitled\u{1F}false\u{1E}"
        let tabs = BrowserMeetingProbe.parseScriptOutput(output)
        try expectEqual(tabs, [
            Tab(url: "https://meet.google.com/abc-defg-hij?authuser=0", title: "Meet - abc-defg-hij", isActive: true),
            Tab(url: "https://mail.google.com/mail/u/0/", title: "Inbox (3) - me@example.com", isActive: false),
            Tab(url: nil, title: "Untitled", isActive: false),
        ])
        try expect(BrowserMeetingProbe.parseScriptOutput("").isEmpty)
    }

    suite.test("a Meet tab with a meeting code wins; URLs are canonical and free of query strings") {
        let tabs = [
            Tab(url: "https://web.whatsapp.com/", title: "WhatsApp", isActive: true),
            Tab(url: "https://meet.google.com/landing", title: "Google Meet"),
            Tab(url: "https://meet.google.com/abc-defg-hij?authuser=1&pli=1", title: "Meet - Weekly research sync - Google Chrome"),
            Tab(url: "https://www.google.com/search?q=google+meet", title: "google meet - Google Search"),
        ]
        let info = try expectNotNil(BrowserMeetingProbe.bestMeeting(in: tabs))
        try expectEqual(info, MeetingInfo(platform: .googleMeet, title: "Weekly research sync", url: "https://meet.google.com/abc-defg-hij"))
        let zoom = BrowserMeetingProbe.bestMeeting(in: [Tab(url: "https://us05web.zoom.us/wc/81234567890/join?pwd=SECRET#success", title: "Zoom Meeting")])
        try expectEqual(zoom, MeetingInfo(platform: .zoom, title: nil, url: "https://us05web.zoom.us/wc/81234567890/join"))
        try expect(zoom?.url?.contains("SECRET") == false, "no passcodes in stored URLs")
        let teams = BrowserMeetingProbe.bestMeeting(in: [
            Tab(url: "https://teams.microsoft.com/v2/", title: "(2) Meeting with Alice | Microsoft Teams"),
            Tab(url: "https://github.com/", title: "GitHub", isActive: true),
        ])
        try expectEqual(teams?.platform, .teams)
        try expectEqual(teams?.title, "Meeting with Alice")
        try expect(BrowserMeetingProbe.bestMeeting(in: [Tab(url: "https://github.com", title: "Google Meet tips")]) == nil,
                   "a known URL decides; the title isn't used")
        try expect(BrowserMeetingProbe.bestMeeting(in: []) == nil)
        let active = BrowserMeetingProbe.bestMeeting(in: [
            Tab(url: "https://web.whatsapp.com/", title: "WhatsApp"),
            Tab(url: "https://web.telegram.org/a/", title: "Telegram Web", isActive: true),
        ])
        try expectEqual(active?.platform, .whatsapp, "priority beats the active-tab bonus across platforms")
    }

    suite.test("window titles (Accessibility, any browser incl. Zen/Firefox) map to meetings") {
        let zen = BrowserMeetingProbe.bestMeeting(in: [Tab(url: nil, title: "Meet - abc-defg-hij — Zen Browser")])
        try expectEqual(zen, MeetingInfo(platform: .googleMeet, title: nil, url: "https://meet.google.com/abc-defg-hij"))
        let named = BrowserMeetingProbe.bestMeeting(in: [Tab(url: nil, title: "Meet - Thesis check-in — Mozilla Firefox")])
        try expectEqual(named?.title, "Thesis check-in")
        try expectEqual(named?.url, nil)
        let withURL = BrowserMeetingProbe.bestMeeting(in: [Tab(url: "https://meet.google.com/xyz-abcd-efg", title: "Meet - xyz-abcd-efg — Zen Browser")])
        try expectEqual(withURL?.url, "https://meet.google.com/xyz-abcd-efg", "the AXURL beats the title")
        try expect(BrowserMeetingProbe.bestMeeting(in: [Tab(url: nil, title: "arXiv.org — Zen Browser")]) == nil)
    }

    suite.test("browser decorations are stripped from titles") {
        let cases: [(String, String)] = [
            ("Meet - abc-defg-hij - Camera and microphone recording - Google Chrome - Nahian (Work)", "Meet - abc-defg-hij"),
            ("Meet - abc-defg-hij — Mozilla Firefox", "Meet - abc-defg-hij"),
            ("Meet - abc-defg-hij — Zen Browser", "Meet - abc-defg-hij"),
            ("(3) Chat | Microsoft Teams", "Chat | Microsoft Teams"),
            ("Zoom Meeting - Microsoft\u{200B} Edge", "Zoom Meeting"),
            ("🔊 Lecture - YouTube - Brave", "Lecture - YouTube"),
            ("Plain title", "Plain title"),
            ("A - B - C", "A - B - C"),
        ]
        for (input, expected) in cases {
            try expectEqual(BrowserMeetingProbe.stripBrowserDecorations(input), expected, input)
        }
    }

    suite.test("clean meeting titles per platform") {
        let cases: [(String, CallPlatform, String?)] = [
            ("Meet - abc-defg-hij", .googleMeet, nil),
            ("Meet – Weekly sync", .googleMeet, "Weekly sync"),
            ("Advisor meeting - Google Meet - Google Chrome", .googleMeet, "Advisor meeting"),
            ("Google Meet", .googleMeet, nil),
            ("(2) Meeting with Alice | Microsoft Teams", .teams, "Meeting with Alice"),
            ("Calendar | Microsoft Teams", .teams, nil),
            ("Microsoft Teams", .teams, nil),
            ("Zoom Meeting", .zoom, nil),
            ("Zoom Workplace", .zoom, nil),
            ("research-room | Jitsi Meet", .jitsi, "research-room"),
            ("Huddle: #ml-reading - Slack", .slack, "Huddle: #ml-reading"),
            ("WhatsApp", .whatsapp, nil),
            ("Lab sync", .other, "Lab sync"),
        ]
        for (title, platform, expected) in cases {
            try expectEqual(BrowserMeetingProbe.cleanTitle(title, platform: platform), expected, "\(title) [\(platform)]")
        }
    }

    suite.test("Meet codes, URL sanitizing and the AppleScript sources") {
        try expectEqual(BrowserMeetingProbe.googleMeetCode(inURL: "https://meet.google.com/abc-defg-hij?authuser=0"), "abc-defg-hij")
        try expectEqual(BrowserMeetingProbe.googleMeetCode(inURL: "https://meet.google.com/new"), nil)
        try expectEqual(BrowserMeetingProbe.googleMeetCode(inURL: "https://example.com/abc-defg-hij"), nil)
        try expectEqual(BrowserMeetingProbe.googleMeetCode(inTitle: "Meet - abc-defg-hij — Zen Browser"), "abc-defg-hij")
        try expectEqual(BrowserMeetingProbe.googleMeetCode(inTitle: "Meet - xabc-defg-hij"), nil)
        try expectEqual(BrowserMeetingProbe.sanitizedURL("https://user:pw@zoom.us/j/123?pwd=x#y"), "https://zoom.us/j/123")
        let chrome = BrowserMeetingProbe.appleScript(bundleID: "com.google.Chrome", family: .chromium)
        try expect(chrome.contains("if application id \"com.google.Chrome\" is running then"), "never launches the browser")
        try expect(chrome.contains("title of every tab of w") && chrome.contains("active tab index of w"))
        let safari = BrowserMeetingProbe.appleScript(bundleID: "com.apple.Safari", family: .safari)
        try expect(safari.contains("name of every tab of w") && safari.contains("current tab of w"))
        try expect(safari.contains("with timeout of 3 seconds"))
    }

    return suite
}

/// A meeting probe that answers from a script (no AppleScript, no Accessibility).
final class ScriptedProbe: MeetingProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [MeetingInfo?]
    private var count = 0

    init(_ answers: [MeetingInfo?]) { self.answers = answers }

    var calls: Int { lock.withLock { count } }

    func probe(app: AppIdentity) -> MeetingInfo? {
        lock.withLock {
            count += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }
}

/// Collects detector events on the main thread.
@MainActor
final class EventLog {
    var events: [DetectionEvent] = []
    var offMain = 0
    var kinds: [String] { events.map(kind) }
}

@MainActor
private func waitFor(_ log: EventLog, timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw fail("timed out; events so far: \(log.kinds)") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Short timings; note the state machine's fixed 1 s release debounce comes before any grace period.
@MainActor
private func makeDetector(_ monitor: FakeMonitor, probe: MeetingProbing? = nil, grace: Double = 0.2) -> (CallDetector, EventLog) {
    var config = DetectionConfig()
    config.startConfirmSeconds = 0.1
    config.endGraceNativeSeconds = grace
    config.endGraceBrowserSeconds = 0.3
    let detector = CallDetector(config: config, monitor: monitor, meetingProbe: probe, tickInterval: 0.02, probeInterval: 0.1)
    let log = EventLog()
    detector.onEvent = { event in
        if !Thread.isMainThread { log.offMain += 1 }
        log.events.append(event)
    }
    return (detector, log)
}

private let zoomLive = activity("us.zoom.xos", "zoom.us", .meeting, mic: true, out: true, objects: [10], pid: 4_242)
private let zoomQuiet = activity("us.zoom.xos", "zoom.us", .meeting, mic: false, out: true, objects: [10], pid: 4_242)
private let zenLive = activity("app.zen-browser.zen", "Zen", .browser, mic: true, out: true, objects: [20], pid: 4_343)

func detectorSuite() -> TestSuite {
    let suite = TestSuite("CallDetector (fake monitor, real queues)")

    suite.test("events arrive on the main thread, in order: started → ending → ended") {
        let monitor = FakeMonitor()
        let (detector, log) = await makeDetector(monitor)
        monitor.set([zoomLive])
        detector.start()
        try await waitFor(log) { log.kinds == ["started"] }
        let activities = detector.currentActivities()
        try expectEqual(activities.map(\.app.bundleID), ["us.zoom.xos"])
        monitor.set([zoomQuiet])
        try await waitFor(log) { log.kinds.last == "ended" }
        let kinds = await log.kinds
        try expectEqual(kinds, ["started", "ending", "ended"])
        let offMain = await log.offMain
        try expectEqual(offMain, 0)
        detector.stop()
    }

    suite.test("a vanished call app ends now if its process is gone, counts as a mic release if it still runs") {
        let monitor = FakeMonitor()
        let (detector, log) = await makeDetector(monitor, grace: 3)
        monitor.set([zoomLive])
        detector.start()
        try await waitFor(log) { log.kinds == ["started"] }
        monitor.set([], alive: [4_242])                     // coreaudiod hiccup: Zoom still runs
        try await waitFor(log) { log.kinds.count >= 2 }
        let afterHiccup = await log.kinds
        try expectEqual(afterHiccup, ["started", "ending"])
        monitor.set([zoomLive])
        try await waitFor(log) { log.kinds.last == "resumed" }
        monitor.set([], alive: [])                          // Zoom quit
        try await waitFor(log) { log.kinds.last == "ended" }
        let kinds = await log.kinds
        try expectEqual(kinds, ["started", "ending", "resumed", "ended"])
        detector.stop()
    }

    suite.test("answers, silence reports and manual sessions go through the detector queue") {
        let monitor = FakeMonitor()
        let (detector, log) = await makeDetector(monitor)
        monitor.set([zoomLive])
        detector.start()
        try await waitFor(log) { log.kinds == ["started"] }
        let id = try expectNotNil(await log.events.first.map(call(of:))?.id)
        detector.reportSilence(seconds: 10_000, for: id)
        try await waitFor(log) { log.kinds.last == "stale" }
        detector.respond(.endNow, to: id)
        try await waitFor(log) { log.kinds.last == "ended" }
        try expect(detector.currentSession == nil)
        let manual = DetectedCall(app: zoomLive.app, category: .meeting, startedAt: Date(), platform: .zoom, isManual: true)
        detector.beginManualSession(manual)
        try await waitFor(log) { true }
        try expectEqual(detector.currentSession?.call.id, manual.id)
        detector.endManualSession(manual.id)
        try await waitFor(log) { log.kinds.last == "ended" && log.events.count == 4 }
        detector.stop()
    }

    suite.test("sleep / wake notifications: the call ends at sleep; a call still going after the wake starts again") {
        let monitor = FakeMonitor()
        let (detector, log) = await makeDetector(monitor)
        monitor.set([zoomLive])
        detector.start()
        try await waitFor(log) { log.kinds == ["started"] }
        // Posted in this process only (the detector observes NSWorkspace's notification center).
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try await waitFor(log) { log.kinds == ["started", "ended"] }
        try await Task.sleep(nanoseconds: 400_000_000)
        let held = await log.kinds
        try expectEqual(held, ["started", "ended"], "nothing starts until the wake")
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try await waitFor(log) { log.kinds == ["started", "ended", "started"] }
        let ids = await log.events.map { call(of: $0).id }
        try expect(ids[2] != ids[0], "a new call")
        detector.stop()
    }

    suite.test("browser calls are probed for meeting info until something is found") {
        let monitor = FakeMonitor()
        let meet = MeetingInfo(platform: .googleMeet, title: "Standup", url: "https://meet.google.com/abc-defg-hij")
        let probe = ScriptedProbe([nil, meet])
        let (detector, log) = await makeDetector(monitor, probe: probe)
        monitor.set([zenLive])
        detector.start()
        try await waitFor(log) { log.kinds == ["started", "meetingInfo"] }
        let updated = try expectNotNil(await log.events.last.map(call(of:)))
        try expectEqual(updated.platform, .googleMeet)
        try expectEqual(updated.meeting, meet)
        try expectEqual(probe.calls, 2, "retried after the first empty answer, then stopped")
        try await Task.sleep(nanoseconds: 300_000_000)
        try expectEqual(probe.calls, 2)
        detector.stop()
    }

    suite.test("a native app is never probed; stop() halts event delivery") {
        let monitor = FakeMonitor()
        let probe = ScriptedProbe([])
        let (detector, log) = await makeDetector(monitor, probe: probe)
        monitor.set([zoomLive])
        detector.start()
        try await waitFor(log) { log.kinds == ["started"] }
        try expectEqual(probe.calls, 0)
        detector.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.set([])
        try await Task.sleep(nanoseconds: 300_000_000)
        let kinds = await log.kinds
        try expectEqual(kinds, ["started"])
    }

    return suite
}
