// kan-probe — read-only diagnostics for Kan's audio and call detection.
//
// Starts no capture IO, creates no taps or aggregates and requests no permissions. `detect` only
// queries browsers (AppleScript / Accessibility) with --probe-meetings, and even then only when
// that is already permitted.

import AppKit
import CoreAudio
import Darwin
import Foundation
import KanAudio
import KanCore
import KanDetect

setvbuf(stdout, nil, _IOLBF, 0)
KanLog.configure(fileName: "kan-probe.log")

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"

func usage() {
    print("""
    kan-probe — read-only diagnostics (no capture, no taps, no permission prompts)

      kan-probe clients              Core Audio clients, their owning apps and categories
      kan-probe watch [seconds]      log per-app mic / output / device changes (default 300 s)
      kan-probe permissions          permission statuses (preflight only)
      kan-probe devices              audio devices, transport, loudspeaker classification
      kan-probe detect [seconds]     run the call detector and print its events (default 300 s)
                 [--probe-meetings]  also name browser meetings (only if already permitted)
                 [--defaults]        ignore settings.json policies

    Permission statuses belong to the process responsible for kan-probe (e.g. Terminal), not Kan.app.
    """)
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func seconds(at index: Int, default value: Double) -> Double {
    guard arguments.count > index, let v = Double(arguments[index]), v > 0 else { return value }
    return v
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

let deviceNames: [String: String] = Dictionary(AudioDeviceInfo.all().map { ($0.uid, $0.name) }, uniquingKeysWith: { a, _ in a })

func names(_ uids: [String]) -> String {
    uids.isEmpty ? "-" : uids.map { deviceNames[$0] ?? $0 }.joined(separator: ", ")
}

// MARK: clients

func printClients() {
    let monitor = AudioClientMonitor()
    guard let resolved = monitor.resolvedClients() else {
        print("Cannot read the Core Audio process list.")
        exit(1)
    }
    print("Core Audio clients: \(resolved.count)   (kan-probe pid \(getpid()))")
    print(pad("OBJ", 6) + pad("PID", 7) + pad("IN", 4) + pad("OUT", 5) + pad("CLIENT BUNDLE ID", 40) + pad("EXECUTABLE", 28) + "OWNER → CATEGORY")
    for r in resolved.sorted(by: { ($0.owner.name.lowercased(), $0.client.pid) < ($1.owner.name.lowercased(), $1.client.pid) }) {
        let c = r.client
        let owner = "\(r.owner.name) [\(r.owner.bundleID)] pid \(r.owner.pid)"
        let tail = r.exclusion.map { "excluded: \($0.rawValue)" } ?? r.category.rawValue
        print(pad("\(c.processObjectID)", 6) + pad("\(c.pid)", 7) + pad(c.isRunningInput ? "●" : "·", 4)
              + pad(c.isRunningOutput ? "●" : "·", 5) + pad(c.bundleID.isEmpty ? "-" : c.bundleID, 40)
              + pad(c.executableName ?? "?", 28) + "\(owner) → \(tail)")
        if !c.inputDeviceUIDs.isEmpty || !c.outputDeviceUIDs.isEmpty {
            print(String(repeating: " ", count: 22) + "in: \(names(c.inputDeviceUIDs))   out: \(names(c.outputDeviceUIDs))")
        }
    }
    let activities = AudioClientMonitor.group(resolved)
    print("\nApps (grouped by owning app, Kan and system noise excluded): \(activities.count)")
    for a in activities {
        print("  \(a.app.name) [\(a.app.bundleID)] \(a.category.rawValue)  mic=\(a.micActive ? "ON" : "off") out=\(a.outputActive ? "ON" : "off")")
        print("      process objects \(a.processObjectIDs)  pids \(a.pids)  bundles \(a.processBundleIDs)")
        print("      app path \(a.app.path ?? "-")")
        print("      input devices: \(names(a.inputDeviceUIDs))   output devices: \(names(a.outputDeviceUIDs))")
        print("      platform \(AppCatalog.platform(bundleID: a.app.bundleID).rawValue)  policy \(DetectionConfig().policy(for: a.app, category: a.category).rawValue)")
    }
}

// MARK: watch

func watch(for duration: Double) {
    let monitor = AudioClientMonitor()
    let queue = DispatchQueue(label: "com.nahian.Kan.probe.watch")
    var last: [String: String] = [:]
    func snapshot() {
        guard let activities = monitor.activities() else { return }
        var seen = Set<String>()
        for a in activities {
            seen.insert(a.app.bundleID)
            let state = "mic=\(a.micActive ? "ON " : "off") out=\(a.outputActive ? "ON " : "off") "
                + "in=[\(names(a.inputDeviceUIDs))] out=[\(names(a.outputDeviceUIDs))] procs=\(a.processObjectIDs.count)"
            if last[a.app.bundleID] != state {
                print("\(timestamp())  \(pad(a.app.name, 22)) \(pad(a.category.rawValue, 10)) \(state)")
                last[a.app.bundleID] = state
            }
        }
        for gone in last.keys.sorted() where !seen.contains(gone) {
            print("\(timestamp())  \(gone): no longer an audio client")
            last[gone] = nil
        }
    }
    print("Watching audio clients for \(Int(duration)) s (Ctrl-C to stop)…")
    monitor.startObserving(queue: queue) { snapshot() }
    queue.async { snapshot() }
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
    monitor.stopObserving()
}

// MARK: permissions

func printPermissions() {
    let permissions = Permissions()
    print("Permission statuses (preflight only; for the process responsible for kan-probe):")
    for kind in PermissionKind.allCases {
        let note = kind == .calendar ? "   (checked by the app with EventKit)" : ""
        print("  \(pad(kind.displayName, 26)) \(permissions.status(kind).rawValue)\(note)")
    }
    print("\nSystem Audio Recording via TCC SPI: \(Permissions.systemAudioPreflight() == .unknown ? "unavailable" : "available")")
    let browsers = runningScriptableBrowsers()
    if browsers.isEmpty {
        print("Automation: no scriptable browser (Chrome family / Safari) is running")
    } else {
        for (name, bundleID, pid) in browsers {
            let status = Permissions.automationStatus(pid: pid, askUserIfNeeded: false)
            print("Automation → \(name) [\(bundleID)] pid \(pid): \(status.rawValue)")
        }
    }
    for kind in PermissionKind.allCases {
        print("Settings link for \(kind.rawValue): \(Permissions.settingsURL(for: kind)?.absoluteString ?? "-")")
    }
}

// MARK: devices

func printDevices() {
    let devices = AudioDeviceInfo.all()
    let defaultInput = HAL.defaultInputDevice().flatMap(HAL.deviceUID)
    let defaultOutput = HAL.defaultOutputDevice().flatMap(HAL.deviceUID)
    print("Audio devices: \(devices.count)")
    for d in devices {
        var marks: [String] = []
        if d.uid == defaultInput { marks.append("default input") }
        if d.uid == defaultOutput { marks.append("default output") }
        print("  \(d.name)\(marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))")")
        print("      uid \(d.uid)  transport \(d.transport.rawValue)  in \(d.inputChannels) ch  out \(d.outputChannels) ch  \(Int(d.nominalSampleRate)) Hz  alive \(d.isAlive)")
        if d.hasInput {
            print("      input: \(d.isRealInput ? "physical microphone" : "virtual/aggregate (never chosen from the call app's list)")")
        }
        if d.hasOutput {
            let route = LoudspeakerClassifier.route(of: d)
            print("      output: data source \(d.outputDataSource ?? "-")  terminals \(d.outputTerminalTypes)  → \(route.rawValue)\(route.isLoudspeaker ? "  LOUDSPEAKER" : "")")
        }
    }
    let choice = MicrophoneSelector.choose(preferredUIDs: [], devices: devices, defaultInputUID: defaultInput)
    print("\nMicrophone Kan would record without a call-app preference: \(choice.map { "\(deviceNames[$0.uid] ?? $0.uid) (follows default: \($0.followsDefault))" } ?? "none")")
    let loud = LoudspeakerClassifier.isLoudspeakerSuspected(outputUIDs: [], devices: devices, defaultOutputUID: defaultOutput)
    print("Loudspeaker suspected for the default output: \(loud)")
}

// MARK: detect

/// The user's settings, read without SettingsStore (which moves a corrupt file aside — a write).
func readSettings() -> KanSettings {
    guard let data = try? Data(contentsOf: KanPaths.settingsFile),
          let settings = try? JSONDecoder.kan.decode(KanSettings.self, from: data) else { return KanSettings() }
    return settings
}

func detect(for duration: Double, probeMeetings: Bool, useSettings: Bool) {
    let config = useSettings ? DetectionConfig(settings: readSettings()) : DetectionConfig()
    let detector = CallDetector(config: config, meetingProbe: probeMeetings ? BrowserMeetingProbe() : nil)
    detector.onEvent = { event in
        print("\(timestamp())  \(CallDetector.describe(event))")
    }
    print("Detecting calls for \(Int(duration)) s (start \(config.startConfirmSeconds) s, grace \(config.endGraceNativeSeconds)/\(config.endGraceBrowserSeconds) s, meeting probe \(probeMeetings ? "on" : "off")); nothing is recorded.")
    detector.start()
    let activities = detector.currentActivities()
    print("Apps using audio now: \(activities.isEmpty ? "none" : activities.map { "\($0.app.name)\($0.micActive ? " (mic)" : "")" }.joined(separator: ", "))")
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
    detector.stop()
}

func runningScriptableBrowsers() -> [(name: String, bundleID: String, pid: pid_t)] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard let id = app.bundleIdentifier, ScriptableBrowsers.family(bundleID: id) != nil else { return nil }
        return (app.localizedName ?? id, id, app.processIdentifier)
    }
}

switch command {
case "clients": printClients()
case "watch": watch(for: seconds(at: 1, default: 300))
case "permissions": printPermissions()
case "devices": printDevices()
case "detect":
    detect(for: seconds(at: 1, default: 300), probeMeetings: arguments.contains("--probe-meetings"),
           useSettings: !arguments.contains("--defaults"))
case "help", "-h", "--help": usage()
default:
    usage()
    exit(2)
}
