import AVFoundation
import CoreAudio
import Foundation
import KanAudio
import KanCore
import KanTestKit

private func testOptions(_ tweak: (inout RecordingOptions) -> Void = { _ in }) -> RecordingOptions {
    var o = RecordingOptions()
    o.pumpInterval = nil                 // the test drives the pump on the simulated clock
    o.rebuildDebounceSeconds = 0
    o.retryDelaysSeconds = [0, 0]
    o.microphoneRetrySeconds = 3_600
    o.headerUpdateInterval = 0
    tweak(&o)
    return o
}

private let zoomActivity = AppActivity(
    app: AppIdentity(bundleID: "us.zoom.xos", name: "zoom.us", path: "/Applications/zoom.us.app", pid: 500),
    category: .meeting, micActive: true, outputActive: true, processObjectIDs: [12, 11],
    processBundleIDs: ["us.zoom.xos", "us.zoom.caphost"], pids: [500, 501],
    inputDeviceUIDs: [], outputDeviceUIDs: [FakeDevices.builtInSpeakers.uid])

private func makeSession(_ env: FakeRecordingEnvironment, _ name: String, target: CaptureTarget = .app(zoomActivity),
                         captureMic: Bool = true, preferredInput: String? = nil,
                         options: RecordingOptions = testOptions()) throws -> (RecordingSession, URL) {
    let dir = scratchDirectory("session-\(name)").appendingPathComponent("01CALL", isDirectory: true)
    let request = RecordingRequest(callID: CallID.generate(date: env.clock.date), target: target, directory: dir, captureMic: captureMic,
                                   preferredInputDeviceUID: preferredInput)
    let handle = try CallRecorder(environment: env, options: options).start(request)
    guard let session = handle as? RecordingSession else { throw fail("CallRecorder did not return a RecordingSession") }
    settle(session)
    return (session, dir)
}

/// The tap currently feeding "them" (started, not stopped), if any.
private func liveTap(_ env: FakeRecordingEnvironment) -> FakeSource? {
    env.taps.last { $0.startCount > 0 && $0.stopCount == 0 }
}

/// Lets queued work (begin, rebuilds, retries, system events) run.
private func settle(_ session: RecordingSession) {
    for _ in 0..<8 { session.processPendingAudio() }
}

/// Emits audio on `sources` for [from, to) in `step` slices, advancing the clock and pumping after each.
private func run(_ session: RecordingSession, _ env: FakeRecordingEnvironment, from: Double, to: Double, step: Double = 0.1,
                 sources: [FakeSource], amplitude: Float = 0.3) {
    var t = from
    while t < to - 1e-9 {
        let dt = min(step, to - t)
        for s in sources { s.emit(from: t, duration: dt, clock: env.clock, amplitude: amplitude) }
        env.clock.set(t + dt)
        session.processPendingAudio()
        t += dt
    }
}

private func anchors(_ dir: URL) throws -> RecordingAnchors {
    let url = dir.appendingPathComponent("anchors.json")
    guard let data = try? Data(contentsOf: url) else {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["<no directory>"]
        throw fail("no anchors.json in \(dir.path); contains \(listing)")
    }
    return try JSONDecoder.kan.decode(RecordingAnchors.self, from: data)
}

private func frames(_ seconds: Double) -> Int { Int((seconds * 16_000).rounded()) }

func sessionSuite() -> TestSuite {
    let suite = TestSuite("RecordingSession (simulated)")

    suite.test("both tracks start at the session start, share one clock and are written as valid files") {
        let env = FakeRecordingEnvironment()
        let (session, dir) = try makeSession(env, "basic")
        let tap = try expectNotNil(env.taps.first)
        let mic = try expectNotNil(env.mics.first)
        try expectEqual(tap.tapTarget, TapTarget(scope: .processes, processObjectIDs: [11, 12], bundleIDs: ["us.zoom.xos", "us.zoom.caphost"]))
        try expectEqual(mic.kind, .mic(FakeDevices.builtInMic.uid), "no call-app input known: the default input")
        run(session, env, from: 0.1, to: 1.1, sources: [tap, mic])
        try expect(session.levels.me > 0.1 && session.levels.them > 0.1, "\(session.levels)")
        try expect(session.silenceSeconds < 0.2)
        try expect(!session.isPaused)
        let result = await session.stop(trimEndAt: nil)
        try expectEqual(result.meFile?.lastPathComponent, "me.wav")
        try expectEqual(result.themFile?.lastPathComponent, "them.wav")
        try expectClose(result.meSeconds, 1.1, tolerance: 0.001)
        try expectEqual(result.meSeconds, result.themSeconds)
        try expectClose(result.endedAt.timeIntervalSince(result.startedAt), 1.1, tolerance: 0.001)
        try expect(result.issues.isEmpty, "\(result.issues)")
        try expect(result.loudspeakerSuspected, "Zoom plays through the built-in speakers")
        for url in [result.meFile, result.themFile].compactMap({ $0 }) {
            let reader = try WAVReader(url: url)
            try expectEqual(reader.frameCount, Int64(frames(1.1)))
            try expect(!reader.headerIsStale)
            let s = try reader.readAllMono()
            try expect(maxAbs(s[0..<1_590]) == 0, "\(url.lastPathComponent): silence before the first audio")
            try expectClose(Double(rms(s[2_000..<16_000])), 0.3 / 2.0.squareRoot(), tolerance: 0.01)
        }
        let a = try anchors(dir)
        let me = try expectNotNil(a.me)
        try expectEqual(me.edits.first, RecordingAnchors.Edit(kind: .silence, frame: 0, frames: 1_600, reason: "start"))
        try expectEqual(me.anchors.first?.frame, 1_600)
        try expectClose(me.anchors.first?.seconds ?? -1, 0.1, tolerance: 1e-6)
        try expectEqual(me.sources.count, 1)
        try expectEqual(a.them?.sources.first?.sampleRate, 48_000)
        let saved = try JSONDecoder.kan.decode(RecordingResult.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        try expectEqual(saved.callID, result.callID)
        try expectEqual(saved.meSeconds, result.meSeconds)
        let again = await session.stop(trimEndAt: Date.distantPast)
        try expectEqual(again.endedAt, result.endedAt, "stop is idempotent")
        session.processPendingAudio()                                   // harmless after stop
    }

    suite.test("stop(trimEndAt:) truncates both tracks; tolerates instants before the start and after the end") {
        for (trim, expectedSeconds) in [(-0.5, 0.6), (-5.0, 0.0), (3.0, 1.1)] as [(Double, Double)] {
            let env = FakeRecordingEnvironment()
            let (session, _) = try makeSession(env, "trim")
            run(session, env, from: 0.1, to: 1.1, sources: env.taps + env.mics)
            let result = await session.stop(trimEndAt: env.clock.date.addingTimeInterval(trim))
            try expectClose(result.meSeconds, expectedSeconds, tolerance: 0.001, "trim \(trim)")
            try expectEqual(result.meSeconds, result.themSeconds)
            try expectClose(result.endedAt.timeIntervalSince(result.startedAt), expectedSeconds, tolerance: 0.001)
            for url in [result.meFile, result.themFile].compactMap({ $0 }) {
                try expectEqual(try WAVReader(url: url).frameCount, Int64(frames(expectedSeconds)), "\(url.lastPathComponent) trim \(trim)")
            }
        }
    }

    suite.test("a stop requested at sleep that only runs after the wake keeps the call (host time stops in sleep)") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "sleep-trim")
        run(session, env, from: 0.1, to: 30, sources: env.taps + env.mics)
        let trim = env.clock.date.addingTimeInterval(2)            // `.ended` at sleep (+ 2 s, as the app trims)
        env.clock.sleep(8 * 3_600)                                 // the stop runs after an overnight sleep
        env.clock.advance(0.2)
        let result = await session.stop(trimEndAt: trim)
        try expectClose(result.meSeconds, 30.2, tolerance: 0.01, "everything recorded is kept, not cut to nothing")
        try expectEqual(result.meSeconds, result.themSeconds)
        try expectClose(result.endedAt.timeIntervalSince(result.startedAt), 30.2, tolerance: 0.01, "not eight hours")
        let me = try readMono(try expectNotNil(result.meFile))
        try expect(rms(me[frames(1)..<frames(29.9)]) > 0.15)
    }

    suite.test("a source that goes quiet is padded with silence; its audio returns at the right time") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "gap")
        let tap = env.taps[0], mic = env.mics[0]
        run(session, env, from: 0.1, to: 1.1, sources: [tap, mic])
        run(session, env, from: 1.1, to: 2.1, sources: [tap])           // the mic delivers nothing for 1 s
        run(session, env, from: 2.1, to: 3.1, sources: [tap, mic])
        let result = await session.stop(trimEndAt: nil)
        let me = try readMono(try expectNotNil(result.meFile))
        try expectEqual(me.count, frames(3.1))
        try expect(maxAbs(me[frames(1.2)..<frames(2.08)]) == 0, "silence while the mic was quiet")
        try expect(rms(me[frames(2.11)..<frames(2.3)]) > 0.15, "audio placed back at 2.1 s")
        let them = try readMono(try expectNotNil(result.themFile))
        try expect(rms(them[frames(1.2)..<frames(2.0)]) > 0.15, "the tap kept recording")
        try expect(result.issues.isEmpty, "\(result.issues)")
    }

    suite.test("clock drift beyond 100 ms is corrected (slow clock: padding, fast clock: dropping)") {
        for (rate, kind) in [(1.005, RecordingAnchors.Edit.Kind.silence), (0.995, .drop)] {
            let env = FakeRecordingEnvironment()
            let (session, dir) = try makeSession(env, "drift", target: .micOnly)
            let mic = env.mics[0]
            var audio = 0.0
            while audio < 30 - 1e-9 {
                let hostStart = 0.1 + audio * rate
                mic.emit(from: hostStart, duration: 0.1, clock: env.clock, hostSecondsPerSecond: rate)
                env.clock.set(hostStart + 0.1 * rate)
                session.processPendingAudio()
                audio += 0.1
            }
            let result = await session.stop(trimEndAt: nil)
            try expectClose(result.meSeconds, 0.1 + 30 * rate, tolerance: 0.001)
            let track = try expectNotNil(try anchors(dir).me)
            let corrections = track.edits.filter { $0.kind == kind && $0.reason != "stop" && $0.reason != "start" }
            try expect(!corrections.isEmpty, "rate \(rate): \(track.edits)")
            for anchor in track.anchors {
                try expect(abs(Double(anchor.frame) - anchor.seconds * 16_000) <= 1_600 + 160, "anchor \(anchor) misaligned")
            }
            try expect(result.themFile == nil)
        }
    }

    suite.test("pause writes silence (tracks stay on the clock), resume continues; no stale silence while paused") {
        let env = FakeRecordingEnvironment()
        let (session, dir) = try makeSession(env, "pause", target: .micOnly)
        let mic = env.mics[0]
        run(session, env, from: 0.1, to: 1.1, sources: [mic])
        session.pause()
        try expect(session.isPaused)
        run(session, env, from: 1.1, to: 2.1, sources: [mic])
        try expectEqual(session.levels, .zero)
        try expectEqual(session.silenceSeconds, 0)
        session.resume()
        try expect(!session.isPaused)
        run(session, env, from: 2.1, to: 3.1, sources: [mic])
        let result = await session.stop(trimEndAt: nil)
        let me = try readMono(try expectNotNil(result.meFile))
        try expectEqual(me.count, frames(3.1))
        try expect(maxAbs(me[frames(1.15)..<frames(2.05)]) == 0, "paused audio was not kept")
        try expect(rms(me[frames(2.15)..<frames(3.0)]) > 0.15)
        try expect(try anchors(dir).me?.edits.contains { $0.kind == .silence && $0.reason == "pause" } == true)
    }

    suite.test("silenceSeconds counts time since either track was audible (-50 dBFS)") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "silence", target: .micOnly)
        let mic = env.mics[0]
        run(session, env, from: 0.1, to: 1.1, sources: [mic])
        try expect(session.silenceSeconds < 0.15)
        run(session, env, from: 1.1, to: 4.1, sources: [mic], amplitude: 0.001)   // -60 dBFS: room noise
        try expectClose(session.silenceSeconds, 3.0, tolerance: 0.15)
        run(session, env, from: 4.1, to: 4.5, sources: [mic])
        try expect(session.silenceSeconds < 0.15)
        _ = await session.stop(trimEndAt: nil)
    }

    suite.test("a tap fault rebuilds the tap (tapRebuilt) and recording continues on the new tap") {
        let env = FakeRecordingEnvironment()
        let (session, dir) = try makeSession(env, "rebuild")
        let issues = Box<RecordingIssue>()
        session.onIssue = { issues.append($0) }
        let tap1 = env.taps[0], mic = env.mics[0]
        run(session, env, from: 0.1, to: 0.5, sources: [tap1, mic])
        tap1.onFault?(.formatChanged)
        settle(session)
        try expectEqual(env.taps.count, 2)
        let tap2 = env.taps[1]
        try expectEqual(tap1.stopCount, 1)
        try expectEqual(tap2.startCount, 1)
        try expectEqual(tap2.tapTarget, tap1.tapTarget)
        try expectEqual(session.issues, [.tapRebuilt])
        run(session, env, from: 0.5, to: 1.5, sources: [tap2, mic])
        tap2.onFault?(.deviceDied)
        settle(session)
        try expectEqual(issues.all, [.tapRebuilt], "each issue is reported once")
        let result = await session.stop(trimEndAt: nil)
        let them = try readMono(try expectNotNil(result.themFile))
        try expect(rms(them[frames(0.6)..<frames(1.4)]) > 0.15, "audio from the rebuilt tap")
        try expectEqual(try anchors(dir).them?.sources.count, 3)
    }

    suite.test("an app tap that can't start: all system audio stands in (systemAudioFallback, not tapFailed) until the app's tap starts") {
        let env = FakeRecordingEnvironment()
        env.failingTapScopes = ["processes"]
        let (session, dir) = try makeSession(env, "fallback")
        try expectEqual(env.taps.map { $0.tapTarget?.scope }, [.processes, .processes, .processes, .systemAudio], "two retries, then system audio")
        let all = try expectNotNil(env.taps.last?.tapTarget)
        try expectEqual(all.processObjectIDs, [999], "excludes Kan's own process object")
        try expectEqual(all.bundleIDs, [KanPaths.bundleIdentifier])
        try expectEqual(session.issues, [.systemAudioFallback], "the other side is still recorded, so not tapFailed")
        let system = env.taps[3]
        run(session, env, from: 0.1, to: 9.9, sources: [system] + env.mics)
        try expectEqual(env.taps.count, 4, "the call app's tap is tried again after tapRecoverySeconds")
        run(session, env, from: 9.9, to: 10.5, sources: [system] + env.mics)
        try expectEqual(env.taps.map { $0.tapTarget?.scope }.last, .processes)
        try expectEqual(system.stopCount, 0, "a failed try leaves the system tap recording")
        try expect(liveTap(env) === system)
        env.failingTapScopes = []
        run(session, env, from: 10.5, to: 20.5, sources: [system] + env.mics)
        let app = try expectNotNil(liveTap(env))
        try expectEqual(app.tapTarget, TapTarget.app(zoomActivity), "back on the call app's tap")
        try expectEqual(system.stopCount, 1, "stopped once the app's tap runs")
        try expectEqual(env.taps.count, 6)
        run(session, env, from: 20.5, to: 22, sources: [app] + env.mics)
        let result = await session.stop(trimEndAt: nil)
        try expectEqual(result.issues, [.systemAudioFallback], "reported once; issues aren't retracted")
        let them = try readMono(try expectNotNil(result.themFile))
        try expect(rms(them[frames(1)..<frames(19.5)]) > 0.15, "all system audio meanwhile")
        try expect(rms(them[frames(20.6)..<frames(21.9)]) > 0.15, "the call app afterwards")
        try expectEqual(try anchors(dir).them?.sources.count, 2)
    }

    suite.test("when no tap works: tapFailed, the microphone goes on, and call audio comes back once a tap starts") {
        let env = FakeRecordingEnvironment()
        env.failingTapScopes = ["processes", "systemAudio"]
        let (session, dir) = try makeSession(env, "miconly-fallback")
        try expectEqual(env.taps.count, 6, "app ×3, then system audio ×3")
        try expectEqual(session.issues, [.tapFailed])
        run(session, env, from: 0.1, to: 1.1, sources: env.mics)
        let micOnly = await session.stop(trimEndAt: nil)
        try expect(micOnly.themFile == nil, "no call audio was ever captured")
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("them.wav").path))
        try expectClose(micOnly.meSeconds, 1.1, tolerance: 0.001)
        try expectEqual(micOnly.themSeconds, 0)

        let env2 = FakeRecordingEnvironment()
        env2.failingTapScopes = ["processes", "systemAudio"]
        let (session2, _) = try makeSession(env2, "tap-recovers")
        try expectEqual(session2.issues, [.tapFailed])
        env2.failingTapScopes = []
        run(session2, env2, from: 0.1, to: 9.9, sources: env2.mics)
        try expectEqual(env2.taps.count, 6, "nothing is tried before tapRecoverySeconds")
        run(session2, env2, from: 9.9, to: 13, sources: env2.mics)
        let tap = try expectNotNil(liveTap(env2), "the tap is tried again (budget permitting) and works")
        try expectEqual(tap.tapTarget?.scope, .processes, "the call app's tap first")
        run(session2, env2, from: 13, to: 15, sources: [tap] + env2.mics)
        let result = await session2.stop(trimEndAt: nil)
        let them = try readMono(try expectNotNil(result.themFile))
        try expect(maxAbs(them[0..<frames(11.9)]) == 0)
        try expect(rms(them[frames(13.2)..<frames(14.9)]) > 0.15, "call audio after the recovery")
        try expectEqual(result.issues, [.tapFailed])
    }

    suite.test("rebuilds are paced: a used-up budget delays the next one (no fallback, no tapFailed)") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "budget", options: testOptions { $0.maxRebuildsPerMinute = 2 })
        for _ in 0..<3 {
            liveTap(env)?.onFault?(.ioStoppedAbnormally)
            settle(session)
        }
        try expectEqual(env.taps.count, 3, "two rebuilds at once; the third waits (2 per minute: one every 30 s)")
        try expect(liveTap(env) == nil)
        env.clock.advance(29.9)
        settle(session)
        try expectEqual(env.taps.count, 3)
        env.clock.advance(0.2)
        settle(session)
        try expectEqual(env.taps.map { $0.tapTarget?.scope }, [.processes, .processes, .processes, .processes])
        try expect(liveTap(env) != nil)
        try expectEqual(session.issues, [.tapRebuilt])
        _ = await session.stop(trimEndAt: nil)
    }

    suite.test("a burst of tap faults (AirPods churn) never gives up the call app's tap or the remote track") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "fault-burst")          // default budget: 5 at once, then one per 12 s
        let mic = env.mics[0]
        run(session, env, from: 0.1, to: 1, sources: [try expectNotNil(liveTap(env)), mic])
        for second in 1...7 {                                         // a format change every second
            liveTap(env)?.onFault?(.formatChanged)
            settle(session)
            run(session, env, from: Double(second), to: Double(second + 1), sources: [liveTap(env), mic].compactMap { $0 })
        }
        try expectEqual(env.taps.count, 6, "five rebuilds at once, the sixth waits for the budget")
        try expect(liveTap(env) == nil)
        run(session, env, from: 8, to: 13.5, sources: [mic])
        let tap = try expectNotNil(liveTap(env), "rebuilt once the budget allows (about 7 s later)")
        try expectEqual(tap.tapTarget, TapTarget.app(zoomActivity), "still the call app, never all system audio")
        run(session, env, from: 13.5, to: 90, step: 0.5, sources: [tap, mic])
        try expect(liveTap(env) === tap)
        try expect(session.currentSources.them?.contains("processes") == true)
        try expectEqual(session.issues, [.tapRebuilt])
        let result = await session.stop(trimEndAt: nil)
        let them = try readMono(try expectNotNil(result.themFile))
        try expect(rms(them[frames(14)..<frames(89)]) > 0.15, "the remote track goes on after the burst")
    }

    suite.test("missing microphone permission: micPermissionDenied, 'them' still recorded; mic-only can't start") {
        let env = FakeRecordingEnvironment()
        env.micPermission = .denied
        let (session, _) = try makeSession(env, "mic-denied")
        try expect(env.mics.isEmpty)
        try expectEqual(session.issues, [.micPermissionDenied])
        run(session, env, from: 0.1, to: 1.1, sources: env.taps)
        let result = await session.stop(trimEndAt: nil)
        try expect(result.meFile == nil)
        try expectEqual(result.meSeconds, 0)
        try expect(result.themFile != nil)
        try expectThrows("mic-only without microphone access") { _ = try makeSession(env, "mic-denied-2", target: .micOnly) }
    }

    suite.test("no microphone: micUnavailable until a device appears") {
        let env = FakeRecordingEnvironment()
        env.deviceList = [FakeDevices.builtInSpeakers]
        env.defaultInput = nil
        let (session, _) = try makeSession(env, "no-mic", target: .micOnly)
        try expect(env.mics.isEmpty)
        try expectEqual(session.issues, [.micUnavailable])
        env.deviceList.append(FakeDevices.usbMic)
        env.defaultInput = FakeDevices.usbMic.uid
        env.fire(.devicesChanged)
        settle(session)
        try expectEqual(env.mics.map(\.kind), [.mic(FakeDevices.usbMic.uid)])
        run(session, env, from: 0.1, to: 1.0, sources: env.mics)
        let result = await session.stop(trimEndAt: nil)
        try expect(result.meFile != nil)
    }

    suite.test("following the default input across a device switch (deviceChanged); the call app's mic is kept") {
        let env = FakeRecordingEnvironment()
        env.deviceList.append(FakeDevices.airPods)
        let (session, _) = try makeSession(env, "default-switch", target: .micOnly)
        let first = env.mics[0]
        env.defaultInput = FakeDevices.airPods.uid
        env.fire(.defaultInputChanged)
        settle(session)
        try expectEqual(env.mics.map(\.kind), [.mic(FakeDevices.builtInMic.uid), .mic(FakeDevices.airPods.uid)])
        try expectEqual(first.stopCount, 1)
        try expect(session.issues.contains(.deviceChanged))
        _ = await session.stop(trimEndAt: nil)

        let env2 = FakeRecordingEnvironment()
        env2.deviceList.append(FakeDevices.usbMic)
        var zoomOnUSB = zoomActivity
        zoomOnUSB.inputDeviceUIDs = [FakeDevices.zoomVirtual.uid, FakeDevices.usbMic.uid]
        let (session2, _) = try makeSession(env2, "app-mic", target: .app(zoomOnUSB))
        try expectEqual(env2.mics.map(\.kind), [.mic(FakeDevices.usbMic.uid)], "the call app's physical microphone")
        env2.defaultInput = FakeDevices.usbMic.uid
        env2.fire(.defaultInputChanged)
        settle(session2)
        try expectEqual(env2.mics.count, 1, "not following the default")
        _ = await session2.stop(trimEndAt: nil)
    }

    suite.test("20 s of exact zeros from the tap → systemAudioSilent, unless System Audio Recording is known to reach Kan") {
        let cases: [(SystemAudioAccess, Bool)] = [(.notGranted, true), (.grantedPendingRelaunch, true), (.granted, false)]
        for (access, expectIssue) in cases {
            let env = FakeRecordingEnvironment()
            env.systemAudio = access
            let (session, _) = try makeSession(env, "zeros", captureMic: false)
            run(session, env, from: 0.1, to: 19.0, step: 0.5, sources: env.taps, amplitude: 0)
            try expect(session.issues.isEmpty)
            run(session, env, from: 19.0, to: 21.5, step: 0.5, sources: env.taps, amplitude: 0)
            try expectEqual(session.issues.contains(.systemAudioSilent), expectIssue, "\(access)")
            _ = await session.stop(trimEndAt: nil)
        }
    }

    suite.test("real silence is checked again after every 20 s of zeros; a pause breaks the run") {
        let env = FakeRecordingEnvironment()
        env.systemAudio = .granted
        let (session, _) = try makeSession(env, "zeros-recheck", captureMic: false)
        run(session, env, from: 0.1, to: 21.5, step: 0.5, sources: env.taps, amplitude: 0)
        try expect(session.issues.isEmpty, "real silence")
        env.systemAudio = .grantedPendingRelaunch           // revoked and granted again in System Settings
        run(session, env, from: 21.5, to: 40, step: 0.5, sources: env.taps, amplitude: 0)
        try expect(session.issues.isEmpty, "not before another 20 s of zeros")
        run(session, env, from: 40, to: 43, step: 0.5, sources: env.taps, amplitude: 0)
        try expectEqual(session.issues, [.systemAudioSilent])
        _ = await session.stop(trimEndAt: nil)

        let env2 = FakeRecordingEnvironment()
        let (paused, _) = try makeSession(env2, "zeros-pause", captureMic: false)
        run(paused, env2, from: 0.1, to: 15, step: 0.5, sources: env2.taps, amplitude: 0)
        paused.pause()
        run(paused, env2, from: 15, to: 30, step: 0.5, sources: env2.taps, amplitude: 0)
        paused.resume()
        run(paused, env2, from: 30, to: 45, step: 0.5, sources: env2.taps, amplitude: 0)
        try expect(paused.issues.isEmpty, "15 s before the pause and 15 s after it are two runs")
        run(paused, env2, from: 45, to: 51, step: 0.5, sources: env2.taps, amplitude: 0)
        try expectEqual(paused.issues, [.systemAudioSilent])
        _ = await paused.stop(trimEndAt: nil)
    }

    suite.test("'me' follows the call app's microphone mid-call (AirPods connected, a mic picked in the app)") {
        let env = FakeRecordingEnvironment()
        env.deviceList += [FakeDevices.airPods, FakeDevices.usbMic]
        var zoom = zoomActivity
        zoom.inputDeviceUIDs = [FakeDevices.builtInMic.uid]
        // As the app does it: the call app's microphone is also the request's preferred input.
        let (session, _) = try makeSession(env, "follow-app-mic", target: .app(zoom), preferredInput: FakeDevices.builtInMic.uid)
        try expectEqual(env.mics.map(\.kind), [.mic(FakeDevices.builtInMic.uid)])
        env.defaultInput = FakeDevices.airPods.uid                 // AirPods connect and become the default input
        env.fire(.defaultInputChanged)
        settle(session)
        try expectEqual(env.mics.count, 1, "a default change alone doesn't move a call-app microphone")
        zoom.inputDeviceUIDs = [FakeDevices.airPods.uid]           // Zoom follows; the detector reports it
        session.retarget(zoom)
        settle(session)
        try expectEqual(env.mics.map(\.kind), [.mic(FakeDevices.builtInMic.uid), .mic(FakeDevices.airPods.uid)])
        try expectEqual(env.mics[0].stopCount, 1, "the laptop microphone is released")
        try expect(session.issues.contains(.deviceChanged))
        try expectEqual(env.taps.count, 1, "same processes: the tap is untouched")
        try expectEqual(env.taps[0].retargets, [])
        zoom.inputDeviceUIDs = []                                  // muted with the mic released: unknown for now
        session.retarget(zoom)
        settle(session)
        try expectEqual(env.mics.count, 2, "keeps the AirPods")
        zoom.inputDeviceUIDs = [FakeDevices.zoomVirtual.uid, FakeDevices.usbMic.uid]   // a USB mic picked in Zoom
        session.retarget(zoom)
        settle(session)
        try expectEqual(env.mics.last?.kind, .mic(FakeDevices.usbMic.uid))
        try expectEqual(env.mics[1].stopCount, 1)
        env.defaultInput = FakeDevices.builtInMic.uid
        env.fire(.defaultInputChanged)
        settle(session)
        try expectEqual(env.mics.count, 3, "still the app's microphone")
        _ = await session.stop(trimEndAt: nil)
    }

    suite.test("retarget updates the live tap; a '!hog' refusal reports systemAudioSilent and rebuilds") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "retarget")
        let tap = env.taps[0]
        var moved = zoomActivity
        moved.processObjectIDs = [11, 13]
        session.retarget(moved)
        settle(session)
        try expectEqual(tap.retargets, [TapTarget.app(moved)])
        session.retarget(moved)
        settle(session)
        try expectEqual(tap.retargets.count, 1, "unchanged target: nothing to do")
        tap.retargetError = CoreAudioError(kAudioDevicePermissionsError, "set kAudioTapPropertyDescription")
        moved.processObjectIDs = [14]
        session.retarget(moved)
        settle(session)
        try expect(session.issues.contains(.systemAudioSilent))
        try expectEqual(env.taps.count, 2)
        try expectEqual(env.taps[1].tapTarget?.processObjectIDs, [14])
        _ = await session.stop(trimEndAt: nil)
    }

    suite.test("the watchdog restarts a source whose IOProc stopped firing") {
        let env = FakeRecordingEnvironment()
        let (session, _) = try makeSession(env, "watchdog", target: .micOnly)
        run(session, env, from: 0.1, to: 1.0, sources: env.mics)
        run(session, env, from: 1.0, to: 3.5, step: 0.25, sources: [])
        try expectEqual(env.mics.count, 2)
        try expectEqual(env.mics[0].stopCount, 1)
        _ = await session.stop(trimEndAt: nil)
    }

    suite.test("discard deletes everything the session created") {
        let env = FakeRecordingEnvironment()
        let (session, dir) = try makeSession(env, "discard")
        run(session, env, from: 0.1, to: 0.6, sources: env.taps + env.mics)
        try expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("me.wav").path))
        await session.discard()
        try expect(!FileManager.default.fileExists(atPath: dir.path))
        await session.discard()
        let after = await session.stop(trimEndAt: nil)
        try expect(after.meFile == nil && after.themFile == nil)
        try expect(env.taps.allSatisfy { $0.stopCount == 1 } && env.mics.allSatisfy { $0.stopCount == 1 })

        // A pre-existing directory is kept; only the session's files go.
        let env2 = FakeRecordingEnvironment()
        let keep = scratchDirectory("session-discard-existing")
        try Data("x".utf8).write(to: keep.appendingPathComponent("embeddings.json"))
        let s2 = try RecordingSession(request: RecordingRequest(callID: .generate(), target: .micOnly, directory: keep),
                                      environment: env2, options: testOptions())
        settle(s2)
        await s2.discard()
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: keep.path), ["embeddings.json"])
    }

    suite.test("loudspeaker suspicion: speakers yes, AirPods no, mic-only never") {
        let env = FakeRecordingEnvironment()
        env.deviceList.append(FakeDevices.airPods)
        var withAirPods = zoomActivity
        withAirPods.outputDeviceUIDs = [FakeDevices.airPods.uid]
        let (a, _) = try makeSession(env, "airpods", target: .app(withAirPods))
        let ra = await a.stop(trimEndAt: nil)
        try expect(!ra.loudspeakerSuspected)
        let (b, _) = try makeSession(env, "speakers")
        let rb = await b.stop(trimEndAt: nil)
        try expect(rb.loudspeakerSuspected)
        let (c, _) = try makeSession(env, "micOnly-loud", target: .micOnly)
        let rc = await c.stop(trimEndAt: nil)
        try expect(!rc.loudspeakerSuspected)
        env.defaultOutput = FakeDevices.airPods.uid
        let (d, _) = try makeSession(env, "system-airpods", target: .systemAudio)
        let rd = await d.stop(trimEndAt: nil)
        try expect(!rd.loudspeakerSuspected, "system audio: the default output decides")
    }

    suite.test("start refuses to record without disk space; WAV headers are current while recording") {
        let env = FakeRecordingEnvironment()
        env.freeBytes = 1_000_000
        try expectThrows { _ = try makeSession(env, "disk") }
        env.freeBytes = nil
        let (session, dir) = try makeSession(env, "live-header")
        run(session, env, from: 0.1, to: 1.1, sources: env.taps + env.mics)
        let live = try WAVReader(url: dir.appendingPathComponent("me.wav"))
        try expect(!live.headerIsStale && live.frameCount >= Int64(frames(1.0)), "\(live.headerFrameCount)/\(live.frameCount)")
        _ = await session.stop(trimEndAt: nil)
    }

    return suite
}

func archiverSuite() -> TestSuite {
    let suite = TestSuite("AudioArchiver")

    func copyTestAudio(_ name: String, to url: URL) throws {
        let src = testAudioDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: src.path) else { throw TestSkip("no test audio \(src.path)") }
        try FileManager.default.copyItem(at: src, to: url)
    }

    func duration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.fileFormat.sampleRate
    }

    suite.test("me.wav / them.wav → AAC m4a (16 kHz mono ~32 kbps), verified, WAVs deleted, json kept") {
        let dir = scratchDirectory("archive")
        try copyTestAudio("two_speakers_en.wav", to: dir.appendingPathComponent("me.wav"))
        try copyTestAudio("bangla.wav", to: dir.appendingPathComponent("them.wav"))
        for name in ["anchors.json", "session.json", "embeddings.json"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        let meSeconds = try WAVReader(url: dir.appendingPathComponent("me.wav")).duration
        let themSeconds = try WAVReader(url: dir.appendingPathComponent("them.wav")).duration
        let archiver = AudioArchiver()
        let assets = try await archiver.archive(directory: dir)
        try expectEqual(assets.meFile, "me.m4a")
        try expectEqual(assets.themFile, "them.m4a")
        try expectEqual(assets.format, "m4a")
        try expect(assets.isAvailable)
        let fm = FileManager.default
        try expect(!fm.fileExists(atPath: dir.appendingPathComponent("me.wav").path))
        try expect(!fm.fileExists(atPath: dir.appendingPathComponent("them.wav").path))
        let me = dir.appendingPathComponent("me.m4a"), them = dir.appendingPathComponent("them.m4a")
        try expectClose(try duration(me), meSeconds, tolerance: 0.1)
        try expectClose(try duration(them), themSeconds, tolerance: 0.1)
        let format = try AVAudioFile(forReading: me).fileFormat
        try expectEqual(format.sampleRate, 16_000)
        try expectEqual(format.channelCount, 1)
        let sizes = try [me, them].map { ((try fm.attributesOfItem(atPath: $0.path))[.size] as? NSNumber)?.int64Value ?? 0 }
        try expectEqual(assets.sizeBytes, sizes.reduce(0, +))
        let kbps = Double(sizes[0]) * 8 / meSeconds / 1_000
        try expect(kbps > 20 && kbps < 45, "\(kbps) kbps")
        let again = try await archiver.archive(directory: dir)
        try expectEqual(again.meFile, "me.m4a", "already archived")
        try archiver.deleteAudio(in: dir)
        try expectEqual(Set(try fm.contentsOfDirectory(atPath: dir.path)), ["anchors.json", "session.json", "embeddings.json"])
        do {
            _ = try await archiver.archive(directory: dir)
            throw fail("archiving a directory without audio must fail")
        } catch is AudioArchiverError {}
        try archiver.deleteAudio(in: dir)                                  // nothing left: no error
    }

    suite.test("an empty track is dropped; a crashed recording's stale header is archived in full") {
        let dir = scratchDirectory("archive-edge")
        try WAVWriter(url: dir.appendingPathComponent("me.wav")).close()
        let crashed = try WAVWriter(url: dir.appendingPathComponent("them.wav"), headerUpdateInterval: 3_600)
        try crashed.write((0..<48_000).map { 0.3 * Float(sin(Double($0) * 0.1)) })   // 3 s, header still says 0
        let assets = try await AudioArchiver().archive(directory: dir)
        try expect(assets.meFile == nil)
        try expectEqual(assets.themFile, "them.m4a")
        try expectClose(try duration(dir.appendingPathComponent("them.m4a")), 3.0, tolerance: 0.1)
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("me.wav").path))
        try crashed.close()
    }

    return suite
}
