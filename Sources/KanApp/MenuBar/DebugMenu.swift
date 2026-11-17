import SwiftUI
import KanCore

/// Debug ▸ (mock services, or KAN_DEBUG=1): simulates calls through the mock detector and shows
/// sample prompts, so every flow can be tried without a real call.
struct DebugMenu: View {
    @Environment(AppModel.self) private var model
    let close: (() -> Void) -> Void

    var body: some View {
        Menu {
            if let detector = model.mockDetector {
                Section("Simulate") {
                    Button("Zoom call starts") { close { detector.simulateZoomCall() } }
                    Button("Call ends (mic released)") { close { detector.simulateMicReleased() } }
                        .disabled(model.liveCall == nil)
                    Button("Mic back (call resumes)") {
                        close {
                            if let live = model.liveCall, let activity = Self.activity(for: live.detected) {
                                detector.simulateMicAcquired(activity)
                            }
                        }
                    }
                    .disabled(model.liveCall == nil)
                    Button("Google Meet in Zen") { close { detector.simulateMeetInZen() } }
                    Button("Telegram voice note") { close { detector.simulateTelegramVoiceNote() } }
                    Button("Unknown app (asks)") { close { detector.simulateUnknownApp() } }
                    Button("Stale silence (Still in a call?)") {
                        close {
                            (model.services.recorder as? MockRecorder)?.currentHandle?
                                .forceSilence(model.settings.staleSilenceMinutes * 60 + 1)
                            model.reportSilenceNow()
                        }
                    }
                    .disabled(model.liveCall == nil)
                    Menu("Recording issue") {
                        ForEach(Self.issues.indices, id: \.self) { i in
                            Button(Self.issues[i].title) {
                                close { (model.services.recorder as? MockRecorder)?.currentHandle?.raise(Self.issues[i].issue) }
                            }
                        }
                    }
                    .disabled(model.liveCall == nil)
                    Button("Call app quits") { close { detector.simulateAppQuit() } }
                        .disabled(model.liveCall == nil)
                    if let permissions = model.services.permissions as? MockPermissions {
                        Button(model.needsRelaunch(.systemAudio) ? "System Audio: applied" : "System Audio: allowed, relaunch pending") {
                            permissions.simulate(.systemAudio, .granted, pendingRelaunch: !model.needsRelaunch(.systemAudio))
                            model.refreshPermissions()
                        }
                    }
                }
                if let decision = detector.lastDecision {
                    Text("Last: \(decision)")
                }
            }
            Section("Panels") {
                Button("Info toast") { model.postInfo("This is a toast", message: "It hides after a few seconds.") }
                Button("Problem toast") {
                    model.postProblem("Something needs attention", message: "Problems stay until you close them.",
                                      buttons: [.init(title: "Settings…", command: .openSettings, role: .primary)])
                }
                Button("Label the newest call") {
                    close { if let newest = model.summaries.first { model.labelNow(newest.id) } }
                }
                .disabled(model.summaries.isEmpty)
            }
            Section("Files") {
                Button("Reveal logs") { model.environment.openURL(KanPaths.logs) }
                Button("Reveal call data") { model.environment.openURL(KanPaths.calls) }
            }
        } label: {
            Label("Debug", systemImage: "ladybug")
        }
        .menuStyle(.borderlessButton)
        .kanMenuRowLayout()
    }

    /// Issues the recorder can report, as the user sees them.
    private static let issues: [(title: String, issue: RecordingIssue)] = [
        ("“Can't hear the other side”", .systemAudioSilent),
        ("App tap failed (mic only)", .tapFailed),
        ("All system audio stands in", .systemAudioFallback),
        ("No microphone", .micUnavailable),
        ("Disk full", .diskFull),
    ]

    /// The simulated app behind a live call (to put it back on the mic).
    private static func activity(for call: DetectedCall) -> AppActivity? {
        [MockApps.zoom, MockApps.zen, MockApps.telegramCall, MockApps.unknown]
            .first { $0.app.bundleID == call.app.bundleID }
    }
}
