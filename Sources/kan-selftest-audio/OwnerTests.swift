import Foundation
import KanCore
import KanDetect
import KanTestKit

/// A synthetic machine: executable paths, responsible PIDs, app bundles and running apps.
private struct World {
    var ownPID: Int32 = 1
    var paths: [Int32: String] = [:]
    var responsible: [Int32: Int32] = [:]
    var responsibilityAPI = true
    var bundles: [String: OwnerResolver.BundleInfo] = [:]
    var running: [Int32: OwnerResolver.RunningApp] = [:]

    func resolver() -> OwnerResolver {
        let w = self
        return OwnerResolver(environment: OwnerResolver.Environment(
            ownPID: w.ownPID,
            responsiblePID: { pid in w.responsibilityAPI ? (w.responsible[pid] ?? pid) : nil },
            executablePath: { pid in w.paths[pid] },
            bundleInfo: { path in w.bundles[path] },
            runningApp: { pid in w.running[pid] },
            runningApps: { id in w.running.values.filter { $0.bundleID == id }.sorted { $0.pid < $1.pid } },
            category: { id, path in AppCatalog.category(bundleID: id, appURL: path.map { URL(fileURLWithPath: $0) }) }))
    }
}

private let chromeApp = "/Applications/Google Chrome.app"
private let chromeMain = chromeApp + "/Contents/MacOS/Google Chrome"
private let chromeHelper = chromeApp + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
private let zenApp = "/Applications/Zen.app"
private let safariApp = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
private let webkitGPU = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"

private func world() -> World {
    var w = World()
    w.paths = [
        780: chromeMain, 4512: chromeHelper,
        900: zenApp + "/Contents/MacOS/zen", 901: zenApp + "/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container",
        1200: safariApp + "/Contents/MacOS/Safari", 1201: webkitGPU,
        700: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", 701: "/opt/homebrew/bin/sox",
        791: "/usr/libexec/avconferenced", 792: "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd",
        1407: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd",
        1: "/Applications/Kan.app/Contents/MacOS/KanApp",
    ]
    w.responsible = [4512: 780, 901: 900, 1201: 1200, 701: 700]
    w.bundles = [
        chromeApp: .init(bundleID: "com.google.Chrome", name: "Google Chrome"),
        zenApp: .init(bundleID: "app.zen-browser.zen", name: "Zen"),
        safariApp: .init(bundleID: "com.apple.Safari", name: "Safari"),
        "/System/Applications/Utilities/Terminal.app": .init(bundleID: "com.apple.Terminal", name: "Terminal"),
        "/Applications/Kan.app": .init(bundleID: KanPaths.bundleIdentifier, name: "Kan"),
    ]
    w.running = [
        780: .init(pid: 780, bundleID: "com.google.Chrome", name: "Google Chrome", bundlePath: chromeApp),
        900: .init(pid: 900, bundleID: "app.zen-browser.zen", name: "Zen", bundlePath: zenApp),
    ]
    return w
}

private func client(_ object: UInt32, _ pid: Int32, _ bundleID: String, path: String? = nil, mic: Bool = false,
                    out: Bool = false, inputs: [String] = [], outputs: [String] = []) -> AudioClient {
    AudioClient(processObjectID: object, pid: pid, bundleID: bundleID, path: path, isRunning: mic || out,
                isRunningInput: mic, isRunningOutput: out, inputDeviceUIDs: inputs, outputDeviceUIDs: outputs)
}

func ownerSuite() -> TestSuite {
    let suite = TestSuite("Owner mapping")

    suite.test("Chrome helper → Google Chrome via the responsible PID") {
        let w = world()
        let r = w.resolver().resolve(client(99, 4512, "com.google.Chrome.helper", path: chromeHelper, mic: true))
        try expectEqual(r.owner.bundleID, "com.google.Chrome")
        try expectEqual(r.owner.name, "Google Chrome")
        try expectEqual(r.owner.pid, 780)
        try expectEqual(r.owner.path, chromeApp)
        try expectEqual(r.category, .browser)
        try expect(r.exclusion == nil)
    }

    suite.test("Chrome helper → Google Chrome from the outermost .app when the responsibility call is missing") {
        var w = world()
        w.responsibilityAPI = false
        let r = w.resolver().resolve(client(99, 4512, "com.google.Chrome.helper", path: chromeHelper))
        try expectEqual(r.owner.bundleID, "com.google.Chrome")
        try expectEqual(r.owner.pid, 4512, "no responsible PID: the helper itself")
        try expectEqual(r.owner.name, "Google Chrome", "the Info.plist name, not the helper's")
    }

    suite.test("cataloged apps go by Kan's name for them (zoom.us → Zoom); others by their own") {
        var w = world()
        let zoomApp = "/Applications/zoom.us.app"
        w.paths[1600] = zoomApp + "/Contents/MacOS/zoom.us"
        w.bundles[zoomApp] = .init(bundleID: "us.zoom.xos", name: "zoom.us")
        w.running[1600] = .init(pid: 1600, bundleID: "us.zoom.xos", name: "zoom.us", bundlePath: zoomApp)
        let zoom = w.resolver().resolve(client(120, 1600, "us.zoom.xos", path: w.paths[1600], mic: true))
        try expectEqual(zoom.owner.bundleID, "us.zoom.xos")
        try expectEqual(zoom.owner.name, "Zoom", "the toast says “Recording Zoom call”, not “zoom.us”")
        let meetApp = NSHomeDirectory() + "/Applications/Chrome Apps.localized/Google Meet.app"
        w.paths[1601] = meetApp + "/Contents/MacOS/app_mode_loader"
        w.bundles[meetApp] = .init(bundleID: "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", name: "Google Meet")
        let meet = w.resolver().resolve(client(121, 1601, "", path: w.paths[1601], mic: true))
        try expectEqual(meet.owner.name, "Google Meet", "a Chrome web app isn't Chrome by name")
        let terminal = w.resolver().resolve(client(122, 700, "com.apple.Terminal", path: w.paths[700], mic: true))
        try expectEqual(terminal.owner.name, "Terminal", "apps outside the catalog keep their own name")
    }

    suite.test("Zen's child processes → Zen.app (Firefox-based browsers)") {
        let w = world()
        let r = w.resolver().resolve(client(107, 901, "", path: w.paths[901], mic: true, out: true))
        try expectEqual(r.owner.bundleID, "app.zen-browser.zen")
        try expectEqual(r.owner.pid, 900)
        try expectEqual(r.category, .browser)
        var noAPI = w
        noAPI.responsibilityAPI = false
        let r2 = noAPI.resolver().resolve(client(107, 901, "", path: w.paths[901]))
        try expectEqual(r2.owner.bundleID, "app.zen-browser.zen", "nested plugin-container.app folds into Zen.app")
        try expect(r2.exclusion == nil, "an empty client bundle id is fine when the owner is an app")
    }

    suite.test("com.apple.WebKit.GPU → the app that hosts it (Safari)") {
        let w = world()
        let r = w.resolver().resolve(client(98, 1201, "com.apple.WebKit.GPU", path: webkitGPU, out: true))
        try expectEqual(r.owner.bundleID, "com.apple.Safari")
        try expectEqual(r.owner.pid, 1200)
        try expectEqual(r.category, .browser)
    }

    suite.test("WebKit.GPU without a resolvable host is excluded as a system daemon") {
        var w = world()
        w.responsible[1201] = nil
        let r = w.resolver().resolve(client(98, 1201, "com.apple.WebKit.GPU", path: webkitGPU))
        try expectEqual(r.exclusion, .systemDaemon)
    }

    suite.test("avconferenced / callservicesd → FaceTime, whether or not FaceTime is running") {
        var w = world()
        let notRunning = w.resolver().resolve(client(93, 791, "com.apple.avconferenced", path: w.paths[791], mic: true))
        try expectEqual(notRunning.owner.bundleID, "com.apple.FaceTime")
        try expectEqual(notRunning.owner.name, "FaceTime")
        try expectEqual(notRunning.owner.pid, 791)
        try expectEqual(notRunning.category, .meeting)
        w.running[1500] = .init(pid: 1500, bundleID: "com.apple.FaceTime", name: "FaceTime", bundlePath: "/System/Applications/FaceTime.app")
        let running = w.resolver().resolve(client(115, 792, "", path: w.paths[792], mic: true))
        try expectEqual(running.owner.bundleID, "com.apple.FaceTime", "matched by executable name")
        try expectEqual(running.owner.pid, 1500)
        try expectEqual(running.owner.path, "/System/Applications/FaceTime.app")
    }

    suite.test("Kan itself, its helpers and system noise are excluded") {
        let w = world()
        let resolver = w.resolver()
        try expectEqual(resolver.resolve(client(118, 1, "", path: w.paths[1], mic: true)).exclusion, .ownProcess)
        var helper = w
        helper.paths[1600] = "/Applications/Kan.app/Contents/Helpers/kan-helper"
        helper.responsible[1600] = 1
        try expectEqual(helper.resolver().resolve(client(119, 1600, "", path: helper.paths[1600])).exclusion, .ownProcess)
        try expectEqual(resolver.resolve(client(97, 1407, "com.apple.CoreSpeech", path: w.paths[1407], mic: true)).exclusion, .systemNoise)
        try expectEqual(resolver.resolve(client(120, 1408, "com.apple.SpeechRecognitionCore.speechrecognitiond")).exclusion,
                        .systemNoise, "noise ids match as prefixes")
        try expectEqual(resolver.resolve(client(121, 1409, "", path: "/usr/libexec/somethingd")).exclusion, .systemNoise,
                        "no bundle id and no app")
        try expectEqual(resolver.resolve(client(122, 1410, "com.apple.hidden.daemon", path: "/usr/libexec/hidden")).exclusion,
                        .systemDaemon)
    }

    suite.test("a command-line tool belongs to the app that launched it") {
        let w = world()
        let r = w.resolver().resolve(client(130, 701, "", path: w.paths[701], mic: true))
        try expectEqual(r.owner.bundleID, "com.apple.Terminal")
        try expectEqual(r.category, .unknown)
        try expect(r.exclusion == nil)
    }

    suite.test("an unknown app that opens web links counts as a browser") {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safari.path) else { throw TestSkip("no /Applications/Safari.app") }
        var w = world()
        w.paths[1700] = safari.path + "/Contents/MacOS/Safari"
        w.bundles[safari.path] = .init(bundleID: "com.example.NewBrowser", name: "New Browser")
        let r = w.resolver().resolve(client(140, 1700, "com.example.NewBrowser", path: w.paths[1700], mic: true))
        try expectEqual(r.owner.bundleID, "com.example.NewBrowser")
        try expectEqual(r.category, .browser)
    }

    suite.test("outermost .app on a path") {
        try expectEqual(OwnerResolver.outermostAppBundle(in: chromeHelper), chromeApp)
        try expectEqual(OwnerResolver.outermostAppBundle(in: "/Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/x"),
                        "/Applications/Zen.app")
        try expectEqual(OwnerResolver.outermostAppBundle(in: "/usr/libexec/avconferenced"), nil)
        try expectEqual(OwnerResolver.outermostAppBundle(in: "/Users/me/My Apps/Thing.APP/Contents/MacOS/Thing"),
                        "/Users/me/My Apps/Thing.APP")
        try expectEqual(OwnerResolver.outermostAppBundle(in: "/opt/.app/bin/tool"), nil, "a bare '.app' directory is not a bundle")
    }

    suite.test("grouping folds helpers into one activity per app") {
        let w = world()
        let clients = [
            client(102, 780, "com.google.Chrome", path: chromeMain),
            client(99, 4512, "com.google.Chrome.helper", path: chromeHelper, mic: true, inputs: ["mic-a"], outputs: ["spk"]),
            client(100, 4513, "com.google.Chrome.helper", path: chromeHelper, out: true, outputs: ["airpods", "spk"]),
            client(107, 901, "", path: w.paths[901], out: true, outputs: ["spk"]),
            client(97, 1407, "com.apple.CoreSpeech", path: w.paths[1407], mic: true),
            client(118, 1, "", path: w.paths[1], mic: true),
        ]
        var w2 = w
        w2.responsible[4513] = 780
        let groups = AudioClientMonitor.group(clients.map { w2.resolver().resolve($0) })
        try expectEqual(groups.count, 2, "\(groups.map(\.app.bundleID))")
        let chrome = groups[0]
        try expectEqual(chrome.app.bundleID, "com.google.Chrome", "mic users sort first")
        try expectEqual(chrome.app.pid, 780)
        try expect(chrome.micActive && chrome.outputActive)
        try expectEqual(chrome.processObjectIDs, [99, 100, 102])
        try expectEqual(chrome.pids, [780, 4512, 4513])
        try expectEqual(chrome.processBundleIDs, ["com.google.Chrome", "com.google.Chrome.helper"])
        try expectEqual(chrome.inputDeviceUIDs, ["mic-a"])
        try expectEqual(chrome.outputDeviceUIDs, ["airpods", "spk"], "devices of clients doing output IO first")
        let zen = groups[1]
        try expectEqual(zen.app.bundleID, "app.zen-browser.zen")
        try expect(!zen.micActive && zen.outputActive)
        try expectEqual(zen.category, .browser)
    }

    return suite
}
