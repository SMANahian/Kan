import Foundation
import KanCore
import KanDetect
import KanTestKit

/// Drives a CallStateMachine on a virtual timeline (seconds from t0).
struct Sim {
    var machine: CallStateMachine
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init(_ config: DetectionConfig = DetectionConfig()) {
        machine = CallStateMachine(config: config)
    }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    mutating func step(_ seconds: Double, _ activities: [AppActivity]) -> [DetectionEvent] {
        machine.update(activities: activities, now: at(seconds))
    }

    /// Updates every `dt` seconds over [from, to] with the same snapshot; returns (time, event) pairs.
    mutating func run(_ from: Double, _ to: Double, dt: Double = 1, _ activities: [AppActivity]) -> [(Double, DetectionEvent)] {
        var out: [(Double, DetectionEvent)] = []
        var t = from
        while t <= to + 1e-9 {
            out += step(t, activities).map { (t, $0) }
            t += dt
        }
        return out
    }
}

func kind(_ e: DetectionEvent) -> String {
    switch e {
    case .started: return "started"
    case .ask: return "ask"
    case .meetingInfo: return "meetingInfo"
    case .activityChanged: return "activityChanged"
    case .ending: return "ending"
    case .resumed: return "resumed"
    case .ended: return "ended"
    case .stale: return "stale"
    }
}

func kinds(_ events: [DetectionEvent]) -> [String] { events.map(kind) }
func kinds(_ events: [(Double, DetectionEvent)]) -> [String] { events.map { kind($0.1) } }

func call(of e: DetectionEvent) -> DetectedCall {
    switch e {
    case .started(let c), .ask(let c), .meetingInfo(let c), .resumed(let c), .stale(let c): return c
    case .activityChanged(let c, _), .ending(let c, _), .ended(let c, _): return c
    }
}

private let zoomOn = activity("us.zoom.xos", "zoom.us", .meeting, mic: true, out: true, objects: [10, 11], pid: 200)
private let zoomOff = activity("us.zoom.xos", "zoom.us", .meeting, mic: false, out: true, objects: [10, 11], pid: 200)
private let zenOn = activity("app.zen-browser.zen", "Zen", .browser, mic: true, out: true, objects: [20], pid: 300)
private let zenOff = activity("app.zen-browser.zen", "Zen", .browser, mic: false, out: true, objects: [20], pid: 300)
private let tgVoiceNote = activity("com.tdesktop.Telegram", "Telegram", .messaging, mic: true, out: false, objects: [30], pid: 400)
private let tgCall = activity("com.tdesktop.Telegram", "Telegram", .messaging, mic: true, out: true, objects: [30], pid: 400)
private let tgIdle = activity("com.tdesktop.Telegram", "Telegram", .messaging, mic: false, out: false, objects: [30], pid: 400)
private let waOn = activity("net.whatsapp.WhatsApp", "WhatsApp", .messaging, mic: true, out: false, objects: [40], pid: 500)
private let mysteryOn = activity("com.example.mystery", "Mystery", .unknown, mic: true, out: true, objects: [50], pid: 600)
private let mysteryOff = activity("com.example.mystery", "Mystery", .unknown, mic: false, out: true, objects: [50], pid: 600)
private let whisperOn = activity("com.superduper.superwhisper", "Superwhisper", .ignored, mic: true, out: false, objects: [60], pid: 700)

func stateMachineSuite() -> TestSuite {
    let suite = TestSuite("CallStateMachine")

    suite.test("Zoom starts after the confirm window; startedAt is the first mic time") {
        var sim = Sim()
        try expect(sim.step(0, [zoomOn]).isEmpty)
        try expect(sim.step(1, [zoomOn]).isEmpty)
        try expect(sim.step(2.9, [zoomOn]).isEmpty)
        let events = sim.step(3, [zoomOn])
        try expectEqual(kinds(events), ["started"])
        let c = call(of: events[0])
        try expectEqual(c.startedAt, sim.at(0))
        try expectEqual(c.platform, .zoom)
        try expectEqual(c.category, .meeting)
        try expect(!c.isManual)
        try expectEqual(sim.machine.session?.isTentative, false)
        try expect(sim.step(4, [zoomOn]).isEmpty, "no duplicate start")
    }

    suite.test("Zoom: mic release → ending with the native grace → ended at the release time") {
        var sim = Sim()
        _ = sim.run(0, 59, [zoomOn])
        try expect(sim.step(60, [zoomOff]).isEmpty, "release is debounced")
        let ending = sim.step(61, [zoomOff])
        try expectEqual(kinds(ending), ["ending"])
        if case .ending(_, let deadline) = ending[0] { try expectEqual(deadline, sim.at(75)) }
        try expect(sim.run(62, 74, [zoomOff]).isEmpty)
        let ended = sim.step(75, [zoomOff])
        try expectEqual(kinds(ended), ["ended"])
        if case .ended(_, let endedAt) = ended[0] { try expectEqual(endedAt, sim.at(60)) }
        try expect(sim.machine.session == nil)
        try expect(sim.run(76, 100, [zoomOff]).isEmpty)
    }

    suite.test("Zoom: mic back before the deadline → resumed, later ends normally") {
        var sim = Sim()
        _ = sim.run(0, 59, [zoomOn])
        let events = sim.run(60, 69, [zoomOff]) + sim.run(70, 99, [zoomOn])
        try expectEqual(kinds(events), ["ending", "resumed"])
        try expectEqual(events[1].0, 70)
        let later = sim.run(100, 120, [zoomOff])
        try expectEqual(kinds(later), ["ending", "ended"])
        if case .ended(_, let endedAt) = later[1].1 { try expectEqual(endedAt, sim.at(100)) }
        try expectEqual(later[1].0, 115)
    }

    suite.test("Zoom mute keeps the mic stream open → no end for 10 minutes") {
        var sim = Sim()
        let events = sim.run(0, 600, [zoomOn])
        try expectEqual(kinds(events), ["started"])
        try expect(sim.machine.session != nil)
    }

    suite.test("a mic glitch shorter than the debounce doesn't start the countdown") {
        var sim = Sim()
        _ = sim.run(0, 60, [zoomOn])
        try expect(sim.step(60.5, [zoomOff]).isEmpty)
        try expect(sim.step(61.2, [zoomOn]).isEmpty)
        try expect(sim.run(62, 100, [zoomOn]).isEmpty)
    }

    suite.test("the confirm window restarts when the mic drops before it elapses") {
        var sim = Sim()
        _ = sim.run(0, 2, [zoomOn])
        try expect(sim.step(2.5, [zoomOff]).isEmpty)
        let events = sim.run(3, 7, [zoomOn])
        try expectEqual(kinds(events), ["started"])
        try expectEqual(events[0].0, 6)
        try expectEqual(call(of: events[0].1).startedAt, sim.at(3))
    }

    suite.test("Meet in Zen starts automatically and uses the browser grace") {
        var sim = Sim()
        let start = sim.run(0, 5, [zenOn])
        try expectEqual(kinds(start), ["started"])
        let c = call(of: start[0].1)
        try expectEqual(c.category, .browser)
        try expectEqual(c.platform, .browser)
        let end = sim.run(100, 140, [zenOff])
        try expectEqual(kinds(end), ["ending", "ended"])
        if case .ending(_, let deadline) = end[0].1 { try expectEqual(deadline, sim.at(130)) }
        try expectEqual(end[1].0, 130)
        if case .ended(_, let endedAt) = end[1].1 { try expectEqual(endedAt, sim.at(100)) }
    }

    suite.test("Telegram voice note (mic without output) never starts; a Telegram call does") {
        var sim = Sim()
        try expect(sim.run(0, 20, [tgVoiceNote]).isEmpty, "voice note")
        try expect(sim.run(21, 29, [tgIdle]).isEmpty)
        let events = sim.run(30, 40, [tgCall])
        try expectEqual(kinds(events), ["started"])
        try expectEqual(events[0].0, 33)
        try expectEqual(call(of: events[0].1).platform, .telegram)
    }

    suite.test("WhatsApp needs output; messagingRequiresOutput = false relaxes that") {
        var sim = Sim()
        try expect(sim.run(0, 30, [waOn]).isEmpty)
        var relaxed = DetectionConfig()
        relaxed.messagingRequiresOutput = false
        var sim2 = Sim(relaxed)
        try expectEqual(kinds(sim2.run(0, 5, [waOn])), ["started"])
    }

    suite.test("unknown app → ask; record confirms the tentative session, which then ends normally") {
        var sim = Sim()
        let ask = sim.run(0, 5, [mysteryOn])
        try expectEqual(kinds(ask), ["ask"])
        let c = call(of: ask[0].1)
        try expectEqual(sim.machine.session?.isTentative, true)
        try expect(sim.machine.respond(.record, callID: c.id, now: sim.at(6)).isEmpty)
        try expectEqual(sim.machine.session?.isTentative, false)
        try expectEqual(kinds(sim.run(10, 40, [mysteryOff])), ["ending", "ended"])
    }

    suite.test("unknown app → notNow: ignored for the rest of that call, asked again on the next one") {
        var sim = Sim()
        let ask = sim.run(0, 5, [mysteryOn])
        let c = call(of: ask[0].1)
        try expect(sim.machine.respond(.notNow, callID: c.id, now: sim.at(6)).isEmpty)
        try expect(sim.machine.session == nil)
        try expect(sim.run(7, 60, [mysteryOn]).isEmpty, "still holding the mic: ignored")
        try expect(sim.run(61, 63, [mysteryOff]).isEmpty, "a 3 s gap (microphone switch)")
        try expect(sim.run(64, 120, [mysteryOn]).isEmpty, "the same call: still ignored")
        try expect(sim.run(121, 124, []).isEmpty, "no audio clients for a moment")
        try expect(sim.run(125, 150, [mysteryOn]).isEmpty)
        try expect(sim.machine.isSuppressed("com.example.mystery"))
        _ = sim.run(151, 166, [mysteryOff])                  // released for the end grace: that call is over
        try expect(!sim.machine.isSuppressed("com.example.mystery"))
        let again = sim.run(167, 175, [mysteryOn])
        try expectEqual(kinds(again), ["ask"])
        try expectEqual(again[0].0, 170)
        try expect(call(of: again[0].1).id != c.id)
    }

    suite.test("Don't record / Stop & save: a device switch mid-call doesn't record that call again; the next call is") {
        for response in [UserCallResponse.notNow, .endNow] {
            var sim = Sim()
            let c = call(of: sim.run(0, 5, [zoomOn])[0].1)
            try expectEqual(kinds(sim.machine.respond(response, callID: c.id, now: sim.at(10))), response == .endNow ? ["ended"] : [])
            try expect(sim.run(11, 1200, [zoomOn]).isEmpty, "\(response): twenty minutes of that call")
            try expect(sim.run(1201, 1202, [zoomOff]).isEmpty, "AirPods connect: Zoom's input restarts")
            try expect(sim.run(1203, 1800, [zoomOn]).isEmpty, "\(response): the rest of the call isn't recorded")
            _ = sim.run(1801, 1830, [zoomOff])                   // the call ends
            try expectEqual(kinds(sim.run(1831, 1840, [zoomOn])), ["started"], "\(response): the next call")
        }
        var browser = Sim()                                       // browsers: the browser grace (30 s)
        let meet = call(of: browser.run(0, 5, [zenOn])[0].1)
        _ = browser.machine.respond(.notNow, callID: meet.id, now: browser.at(6))
        try expect(browser.run(7, 26, [zenOff]).isEmpty)
        try expect(browser.run(27, 60, [zenOn]).isEmpty, "a 20 s gap is shorter than the browser grace")
        _ = browser.run(61, 91, [zenOff])
        try expectEqual(kinds(browser.run(92, 100, [zenOn])), ["started"])
    }

    suite.test("an ignored app that quits can start its next call right away") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [zoomOn])[0].1)
        _ = sim.machine.respond(.notNow, callID: c.id, now: sim.at(6))
        _ = sim.run(7, 30, [zoomOn])
        try expect(sim.run(31, 33, []).isEmpty, "Zoom quit")
        sim.machine.appTerminated(bundleID: "us.zoom.xos")
        try expect(!sim.machine.isSuppressed("us.zoom.xos"))
        let next = sim.run(40, 45, [zoomOn])                      // relaunched for the next call
        try expectEqual(kinds(next), ["started"])
        try expectEqual(next[0].0, 43)
        try expectEqual(call(of: next[0].1).startedAt, sim.at(40))
    }

    suite.test("unknown app → never (+ the caller's policy update): no further asks") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [mysteryOn])[0].1)
        _ = sim.machine.respond(.never, callID: c.id, now: sim.at(6))
        var config = sim.machine.config
        config.appPolicies["com.example.mystery"] = .never
        sim.machine.updateConfig(config)
        try expect(sim.run(7, 20, [mysteryOn]).isEmpty)
        _ = sim.run(21, 25, [mysteryOff])
        try expect(sim.run(26, 60, [mysteryOn]).isEmpty)
    }

    suite.test("ignored apps and per-app policies") {
        var sim = Sim()
        try expect(sim.run(0, 30, [whisperOn]).isEmpty, "dictation is never a call")
        var config = DetectionConfig()
        config.appPolicies["us.zoom.xos"] = .ask
        config.appPolicies["com.tdesktop.Telegram"] = .never
        var sim2 = Sim(config)
        try expectEqual(kinds(sim2.run(0, 5, [zoomOn])), ["ask"])
        var sim3 = Sim(config)
        try expect(sim3.run(0, 30, [tgCall]).isEmpty)
        var browserAsk = DetectionConfig()
        browserAsk.browserPolicy = .ask
        var sim4 = Sim(browserAsk)
        try expectEqual(kinds(sim4.run(0, 5, [zenOn])), ["ask"])
    }

    suite.test("paused detection starts nothing but never kills an ongoing call") {
        var config = DetectionConfig()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        config.pausedUntil = base.addingTimeInterval(3600)
        var paused = Sim(config)
        try expect(paused.run(0, 60, [zoomOn]).isEmpty)

        var sim = Sim()
        _ = sim.run(0, 10, [zoomOn])
        var pauseNow = sim.machine.config
        pauseNow.pausedUntil = sim.at(3600)
        sim.machine.updateConfig(pauseNow)
        try expect(sim.run(11, 120, [zoomOn]).isEmpty, "the call goes on")
        try expectEqual(kinds(sim.run(121, 140, [zoomOff])), ["ending", "ended"])
    }

    suite.test("an app holding the mic when a pause ends is ignored for the rest of that call") {
        var config = DetectionConfig()
        config.pausedUntil = Date(timeIntervalSinceReferenceDate: 800_000_000).addingTimeInterval(30)
        var sim = Sim(config)
        try expect(sim.run(0, 29, [zoomOn]).isEmpty)
        try expect(sim.run(30, 120, [zoomOn]).isEmpty, "no recording halfway through the call")
        try expect(sim.machine.isSuppressed("us.zoom.xos"))
        _ = sim.run(121, 122, [zoomOff])
        try expect(sim.run(123, 200, [zoomOn]).isEmpty, "a mic switch is no new call")
        _ = sim.run(201, 216, [zoomOff])
        try expectEqual(kinds(sim.run(217, 225, [zoomOn])), ["started"])
    }

    suite.test("disabled detection never starts; disabling mid-call keeps the call") {
        var off = DetectionConfig()
        off.enabled = false
        var sim = Sim(off)
        try expect(sim.run(0, 60, [zoomOn, tgCall, mysteryOn]).isEmpty)

        var live = Sim()
        _ = live.run(0, 5, [zoomOn])
        live.machine.updateConfig(off)
        try expect(live.run(6, 100, [zoomOn]).isEmpty)
        try expect(live.machine.session != nil)
    }

    suite.test("stale silence: reported once, again only after audio returned; not while ending") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [zoomOn])[0].1)
        try expect(sim.machine.reportSilence(seconds: 899, callID: c.id, now: sim.at(900)).isEmpty)
        try expectEqual(kinds(sim.machine.reportSilence(seconds: 900, callID: c.id, now: sim.at(901))), ["stale"])
        try expect(sim.machine.reportSilence(seconds: 950, callID: c.id, now: sim.at(950)).isEmpty, "once")
        try expect(sim.machine.reportSilence(seconds: 2, callID: c.id, now: sim.at(960)).isEmpty)
        try expectEqual(kinds(sim.machine.reportSilence(seconds: 901, callID: c.id, now: sim.at(1900))), ["stale"])
        try expect(sim.machine.reportSilence(seconds: 5000, callID: UUID(), now: sim.at(1901)).isEmpty, "other call")
        _ = sim.run(2000, 2002, [zoomOff])
        try expect(sim.machine.reportSilence(seconds: 1, callID: c.id, now: sim.at(2003)).isEmpty)
        try expect(sim.machine.reportSilence(seconds: 5000, callID: c.id, now: sim.at(2004)).isEmpty, "ending")
    }

    suite.test("manual session: mic release and quit don't end it; stale applies; endManualSession ends it") {
        var sim = Sim()
        _ = sim.step(0, [zoomOff])
        let manual = DetectedCall(app: zoomOn.app, category: .meeting, startedAt: sim.at(1), platform: .zoom, isManual: true)
        try expect(sim.machine.beginManualSession(manual, now: sim.at(1)).isEmpty)
        try expect(sim.run(2, 100, [zoomOn]).isEmpty, "no auto session on top")
        try expect(sim.run(101, 200, [zoomOff]).isEmpty, "mic release")
        try expect(sim.run(201, 300, []).isEmpty, "app gone")
        try expectEqual(kinds(sim.machine.reportSilence(seconds: 900, callID: manual.id, now: sim.at(301))), ["stale"])
        try expect(sim.machine.systemWillSleep(now: sim.at(302)).isEmpty, "sleep")
        let ended = sim.machine.endManualSession(manual.id, now: sim.at(303))
        try expectEqual(kinds(ended), ["ended"])
        if case .ended(let c, let at) = ended[0] {
            try expectEqual(at, sim.at(303))
            try expect(c.isManual)
        }
        try expect(sim.machine.session == nil)
    }

    suite.test("a stopped manual session doesn't hand over to auto-detection while the mic is held") {
        var sim = Sim()
        _ = sim.run(0, 2, [zoomOn])
        let manual = DetectedCall(app: zoomOn.app, category: .meeting, startedAt: sim.at(2), platform: .zoom)
        _ = sim.machine.beginManualSession(manual, now: sim.at(2))
        try expect(sim.machine.session?.call.isManual == true, "registered as manual")
        _ = sim.run(3, 30, [zoomOn])
        _ = sim.machine.endManualSession(manual.id, now: sim.at(31))
        try expect(sim.run(32, 90, [zoomOn]).isEmpty)
        _ = sim.run(91, 92, [zoomOff])
        try expect(sim.run(93, 150, [zoomOn]).isEmpty, "a short gap doesn't end the call the user stopped")
        _ = sim.run(151, 166, [zoomOff])
        try expectEqual(kinds(sim.run(167, 175, [zoomOn])), ["started"])
    }

    suite.test("two apps: the second is ignored while the first records, then starts once the first ends") {
        var sim = Sim()
        _ = sim.run(0, 5, [zoomOn])
        try expect(sim.run(6, 59, [zoomOn, tgCall]).isEmpty, "one call at a time")
        // Zoom releases the mic while Telegram (auto) holds it: as soon as Zoom's countdown starts,
        // Zoom ends at its release time and Telegram starts instead of waiting out the grace period.
        let events = sim.run(60, 80, [zoomOff, tgCall])
        try expectEqual(kinds(events), ["ending", "ended", "started"])
        try expectEqual(events.map(\.0), [61, 61, 61])
        if case .ended(let c, let at) = events[1].1 {
            try expectEqual(c.app.bundleID, "us.zoom.xos")
            try expectEqual(at, sim.at(60))
        }
        let telegram = call(of: events[2].1)
        try expectEqual(telegram.app.bundleID, "com.tdesktop.Telegram")
        try expectEqual(telegram.startedAt, sim.at(61), "not earlier than the previous call's end")
        try expect(sim.run(81, 120, [tgCall]).isEmpty, "Zoom quitting doesn't touch the Telegram call")
    }

    suite.test("an app holding the mic after an ask-policy call ends starts when that call is over") {
        var sim = Sim()
        _ = sim.run(0, 5, [mysteryOn])                     // tentative, unknown app
        try expect(sim.run(6, 59, [mysteryOn, zoomOn]).isEmpty)
        let events = sim.run(60, 70, [mysteryOff, zoomOn])
        try expectEqual(kinds(events), ["ending", "ended", "started"])
        try expectEqual(events[1].0, 61, "takeover by the auto app")
        try expectEqual(call(of: events[2].1).app.bundleID, "us.zoom.xos")
    }

    suite.test("an ending call gives way to an auto app that holds the mic; an ask app doesn't") {
        var sim = Sim()
        _ = sim.run(0, 5, [zoomOn])
        _ = sim.run(60, 61, [zoomOff])                       // ending, deadline 75
        let events = sim.run(62, 66, [zoomOff, zenOn])
        try expectEqual(kinds(events), ["ended", "started"])
        try expectEqual(events[0].0, 65)
        if case .ended(let c, let at) = events[0].1 {
            try expectEqual(c.app.bundleID, "us.zoom.xos")
            try expectEqual(at, sim.at(60))
        }
        try expectEqual(call(of: events[1].1).app.bundleID, "app.zen-browser.zen")

        var sim2 = Sim()
        _ = sim2.run(0, 5, [zoomOn])
        _ = sim2.run(60, 61, [zoomOff])
        let noTakeover = sim2.run(62, 74, [zoomOff, mysteryOn])
        try expect(noTakeover.isEmpty, "\(kinds(noTakeover))")
        try expectEqual(kinds(sim2.step(75, [zoomOff, mysteryOn])), ["ended", "ask"])
    }

    suite.test("app quits → ended immediately (at the release time if it was ending)") {
        var sim = Sim()
        _ = sim.run(0, 10, [zoomOn])
        let quit = sim.step(11, [])
        try expectEqual(kinds(quit), ["ended"])
        if case .ended(_, let at) = quit[0] { try expectEqual(at, sim.at(11)) }

        var sim2 = Sim()
        _ = sim2.run(0, 10, [zenOn])
        _ = sim2.run(20, 22, [zenOff])
        let quit2 = sim2.step(23, [])
        try expectEqual(kinds(quit2), ["ended"])
        if case .ended(_, let at) = quit2[0] { try expectEqual(at, sim2.at(20)) }
    }

    suite.test("activityChanged when the call app's process set changes") {
        var sim = Sim()
        _ = sim.run(0, 5, [zoomOn])
        var restarted = zoomOn
        restarted.processObjectIDs = [10, 12]
        let events = sim.step(6, [restarted])
        try expectEqual(kinds(events), ["activityChanged"])
        if case .activityChanged(_, let a) = events[0] { try expectEqual(a.processObjectIDs, [10, 12]) }
        try expect(sim.step(7, [restarted]).isEmpty)
        var reordered = restarted
        reordered.processObjectIDs = [12, 10]
        try expect(sim.step(8, [reordered]).isEmpty, "order doesn't matter")
        // AirPods connect: same processes, new microphone (and output) — the recorder must follow.
        var airPods = reordered
        airPods.inputDeviceUIDs = ["AirPods-UID"]
        airPods.outputDeviceUIDs = ["AirPods-UID"]
        let moved = sim.step(9, [airPods])
        try expectEqual(kinds(moved), ["activityChanged"])
        if case .activityChanged(_, let a) = moved[0] { try expectEqual(a.inputDeviceUIDs, ["AirPods-UID"]) }
        try expectEqual(sim.machine.session?.inputDeviceUIDs, ["AirPods-UID"])
        try expect(sim.step(10, [airPods]).isEmpty)
        var usbMic = airPods
        usbMic.inputDeviceUIDs = ["USB-Mic"]                     // a mic picked in the app, no default change
        try expectEqual(kinds(sim.step(11, [usbMic])), ["activityChanged"])
        // The detector's stand-in for an app without audio clients says nothing about devices.
        let standIn = AppActivity(app: zoomOn.app, category: .meeting, micActive: false, outputActive: false)
        try expect(sim.step(11.5, [standIn]).isEmpty)
    }

    suite.test("Slack / Teams / Element clips (mic without output) never start; their calls do") {
        for (bundleID, name) in [("com.tinyspeck.slackmacgap", "Slack"), ("com.microsoft.teams2", "Microsoft Teams"),
                                 ("com.microsoft.teams", "Microsoft Teams classic"), ("io.element.elementx", "Element X")] {
            let clip = activity(bundleID, name, .meeting, mic: true, out: false, objects: [70], pid: 800)
            let idle = activity(bundleID, name, .meeting, mic: false, out: false, objects: [70], pid: 800)
            let huddle = activity(bundleID, name, .meeting, mic: true, out: true, objects: [70], pid: 800)
            var sim = Sim()
            try expect(sim.run(0, 60, [clip]).isEmpty, "\(name): recording a one-minute clip")
            try expect(sim.run(61, 69, [idle]).isEmpty)
            let events = sim.run(70, 80, [huddle])
            try expectEqual(kinds(events), ["started"], name)
            try expectEqual(events[0].0, 73)
            try expectEqual(call(of: events[0].1).startedAt, sim.at(70))
        }
        var zoom = Sim()
        try expectEqual(kinds(zoom.run(0, 5, [activity("us.zoom.xos", "zoom.us", .meeting, mic: true, out: false)])), ["started"],
                        "other meeting apps don't need output")
        var relaxed = DetectionConfig()
        relaxed.messagingRequiresOutput = false
        var sim = Sim(relaxed)
        try expectEqual(kinds(sim.run(0, 5, [activity("com.tinyspeck.slackmacgap", "Slack", .meeting, mic: true, out: false)])),
                        ["started"])
    }

    suite.test("endNow ends now and doesn't restart while the mic is still held") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [zoomOn])[0].1)
        let ended = sim.machine.respond(.endNow, callID: c.id, now: sim.at(30))
        try expectEqual(kinds(ended), ["ended"])
        if case .ended(_, let at) = ended[0] { try expectEqual(at, sim.at(30)) }
        try expect(sim.run(31, 90, [zoomOn]).isEmpty)
        _ = sim.run(91, 106, [zoomOff])
        try expectEqual(kinds(sim.run(107, 115, [zoomOn])), ["started"])
    }

    suite.test("keepRecording cancels the countdown until the mic returns; then normal rules resume") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [zoomOn])[0].1)
        try expectEqual(kinds(sim.run(60, 61, [zoomOff])), ["ending"])
        try expect(sim.machine.respond(.keepRecording, callID: c.id, now: sim.at(62)).isEmpty)
        try expect(sim.run(63, 300, [zoomOff]).isEmpty, "no deadline while held")
        try expect(sim.run(301, 310, [zoomOn]).isEmpty, "mic back: silently active again")
        try expectEqual(kinds(sim.run(311, 330, [zoomOff])), ["ending", "ended"])
    }

    suite.test("sleep ends detected calls at once; a call that goes on after the wake is recorded again") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [zoomOn])[0].1)
        let events = sim.machine.systemWillSleep(now: sim.at(50))
        try expectEqual(kinds(events), ["ended"])
        try expectEqual(call(of: events[0]).id, c.id)
        if case .ended(_, let at) = events[0] { try expectEqual(at, sim.at(50)) }
        try expect(sim.run(50.5, 55, [zoomOn]).isEmpty, "nothing starts before the Mac is asleep")
        try expect(!sim.machine.isSuppressed("us.zoom.xos"), "sleep isn't the user declining the call")
        sim.machine.systemDidWake()                               // two hours later
        let after = sim.run(7_250, 7_260, [zoomOn])
        try expectEqual(kinds(after), ["started"])
        try expectEqual(after[0].0, 7_253, "a fresh confirm window from the wake")
        let resumed = call(of: after[0].1)
        try expect(resumed.id != c.id)
        try expectEqual(resumed.startedAt, sim.at(7_250))

        var cancelled = Sim()                                     // the Mac didn't sleep after all (no wake)
        _ = cancelled.run(0, 5, [zoomOn])
        _ = cancelled.machine.systemWillSleep(now: cancelled.at(50))
        let held = cancelled.run(51, 90, [zoomOn])
        try expectEqual(kinds(held), ["started"])
        try expectEqual(held[0].0, 83, "starts are held for sleepHoldSeconds, then the confirm window")
        var noWake = Sim()                                        // the wake was never reported: the hold expires
        _ = noWake.run(0, 5, [zoomOn])
        _ = noWake.machine.systemWillSleep(now: noWake.at(50))
        try expectEqual(kinds(noWake.run(3_650, 3_655, [zoomOn])), ["started"])
    }

    suite.test("meeting info updates the call's platform once") {
        var sim = Sim()
        let c = call(of: sim.run(0, 5, [zenOn])[0].1)
        let info = MeetingInfo(platform: .googleMeet, title: "Weekly sync", url: "https://meet.google.com/abc-defg-hij")
        let events = sim.machine.setMeetingInfo(info, callID: c.id)
        try expectEqual(kinds(events), ["meetingInfo"])
        let updated = call(of: events[0])
        try expectEqual(updated.id, c.id)
        try expectEqual(updated.platform, .googleMeet)
        try expectEqual(updated.meeting, info)
        try expect(sim.machine.setMeetingInfo(info, callID: c.id).isEmpty, "unchanged")
        try expect(sim.machine.setMeetingInfo(info, callID: UUID()).isEmpty, "other call")
        let end = sim.run(100, 140, [zenOff])
        let last = try expectNotNil(end.last)
        try expectEqual(call(of: last.1).platform, .googleMeet)
    }

    suite.test("answers for unknown call ids are ignored") {
        var sim = Sim()
        _ = sim.run(0, 5, [zoomOn])
        for response in [UserCallResponse.record, .notNow, .never, .keepRecording, .endNow] {
            try expect(sim.machine.respond(response, callID: UUID(), now: sim.at(6)).isEmpty)
        }
        try expect(sim.machine.session != nil)
        try expect(sim.machine.endManualSession(UUID(), now: sim.at(7)).isEmpty)
    }

    suite.test("DetectionConfig(settings:) maps the user's settings") {
        var settings = KanSettings()
        settings.startConfirmSeconds = 5
        settings.staleSilenceMinutes = 10
        settings.appPolicies = ["us.zoom.xos": .never]
        let config = DetectionConfig(settings: settings)
        var sim = Sim(config)
        try expectEqual(config.staleSilenceSeconds, 600)
        try expect(sim.run(0, 30, [zoomOn]).isEmpty)
        try expectEqual(kinds(sim.run(31, 40, [tgCall])).first, "started")
    }

    return suite
}
