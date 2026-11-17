import Foundation

/// A call-capable (or explicitly ignored) app Kan knows about.
public struct KnownApp: Sendable, Hashable, Identifiable {
    public var id: String { bundleIDs[0] }
    public var bundleIDs: [String]
    public var name: String
    public var category: AppCategory
    public var platform: CallPlatform
    /// Mic use alone may be a recorded message (voice note, clip), so the app counts as being in a
    /// call only while it also plays audio. Messaging apps by default.
    public var requiresOutput: Bool

    public init(_ name: String, _ category: AppCategory, _ platform: CallPlatform, _ bundleIDs: [String],
                requiresOutput: Bool? = nil) {
        self.name = name
        self.category = category
        self.platform = platform
        self.bundleIDs = bundleIDs
        self.requiresOutput = requiresOutput ?? (category == .messaging)
    }
}

/// Static knowledge about apps: which are call apps, browsers, or never calls.
/// Lookups match a bundle id exactly or as a helper prefix ("com.google.Chrome.helper" → Chrome).
public enum AppCatalog {
    public static let known: [KnownApp] = [
        // Native meeting apps
        KnownApp("Zoom", .meeting, .zoom, ["us.zoom.xos"]),
        KnownApp("Microsoft Teams", .meeting, .teams, ["com.microsoft.teams2", "com.microsoft.teams"],
                 requiresOutput: true),   // records clips and voice messages too
        KnownApp("Webex", .meeting, .webex, ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.webex.meetingmanager"]),
        KnownApp("Slack", .meeting, .slack, ["com.tinyspeck.slackmacgap"],
                 requiresOutput: true),   // records clips and voice messages too
        KnownApp("Discord", .meeting, .discord, ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]),
        KnownApp("FaceTime", .meeting, .facetime, ["com.apple.FaceTime"]),
        KnownApp("Skype", .meeting, .skype, ["com.skype.skype", "com.microsoft.SkypeForBusiness"]),
        KnownApp("Jitsi Meet", .meeting, .jitsi, ["org.jitsi.jitsi-meet"]),
        KnownApp("GoTo Meeting", .meeting, .other, ["com.logmein.GoToMeeting", "com.logmein.goto"]),
        KnownApp("Amazon Chime", .meeting, .other, ["com.amazon.Amazon-Chime"]),
        KnownApp("RingCentral", .meeting, .other, ["com.ringcentral.glip", "com.ringcentral.RingCentral"]),
        KnownApp("BlueJeans", .meeting, .other, ["com.bluejeansnet.Blue"]),
        KnownApp("Around", .meeting, .other, ["co.teamport.around"]),
        KnownApp("Tuple", .meeting, .other, ["app.tuple.app"]),
        KnownApp("Gather", .meeting, .other, ["com.gather.Gather"]),
        KnownApp("Element", .meeting, .other, ["im.riot.app", "io.element.elementx"],
                 requiresOutput: true),   // records clips and voice messages too

        // Messaging apps with calls (mic use alone may be a voice note)
        KnownApp("Telegram", .messaging, .telegram, ["com.tdesktop.Telegram", "ru.keepcoder.Telegram", "org.telegram.desktop"]),
        KnownApp("AyuGram", .messaging, .telegram, ["one.ayugram.AyuGramDesktop"]),
        KnownApp("WhatsApp", .messaging, .whatsapp, ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        KnownApp("Signal", .messaging, .signal, ["org.whispersystems.signal-desktop"]),
        KnownApp("Messenger", .messaging, .messenger, ["com.facebook.archon", "com.facebook.archon.developerID"]),
        KnownApp("Viber", .messaging, .other, ["com.viber.osx"]),
        KnownApp("LINE", .messaging, .other, ["jp.naver.line.mac"]),
        KnownApp("WeChat", .messaging, .other, ["com.tencent.xinWeChat"]),
        KnownApp("KakaoTalk", .messaging, .other, ["com.kakao.KakaoTalkMac"]),
        KnownApp("Wire", .messaging, .other, ["com.wearezeta.zclient.mac"]),

        // Browsers (any other app that opens web links and HTML documents is treated as a browser too)
        KnownApp("Zen", .browser, .browser, ["app.zen-browser.zen"]),
        KnownApp("Google Chrome", .browser, .browser, ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]),
        KnownApp("Safari", .browser, .browser, ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]),
        KnownApp("Firefox", .browser, .browser, ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]),
        KnownApp("Brave", .browser, .browser, ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"]),
        KnownApp("Arc", .browser, .browser, ["company.thebrowser.Browser"]),
        KnownApp("Dia", .browser, .browser, ["company.thebrowser.dia"]),
        KnownApp("Microsoft Edge", .browser, .browser, ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"]),
        KnownApp("Vivaldi", .browser, .browser, ["com.vivaldi.Vivaldi"]),
        KnownApp("Opera", .browser, .browser, ["com.operasoftware.Opera", "com.operasoftware.OperaGX"]),
        KnownApp("Chromium", .browser, .browser, ["org.chromium.Chromium"]),
        KnownApp("Orion", .browser, .browser, ["com.kagi.kagimacOS"]),
        KnownApp("Waterfox", .browser, .browser, ["net.waterfox.waterfox"]),
        KnownApp("Comet", .browser, .browser, ["ai.perplexity.comet"]),

        // Never calls: dictation, recorders, assistants, other meeting recorders
        KnownApp("Superwhisper", .ignored, .other, ["com.superduper.superwhisper"]),
        KnownApp("Wispr Flow", .ignored, .other, ["com.electron.wispr-flow"]),
        KnownApp("MacWhisper", .ignored, .other, ["com.goodsnooze.MacWhisper"]),
        KnownApp("VoiceInk", .ignored, .other, ["com.prakashjoshipax.VoiceInk"]),
        KnownApp("Aiko", .ignored, .other, ["com.sindresorhus.Aiko"]),
        KnownApp("Krisp", .ignored, .other, ["ai.krisp.krispMac"]),
        KnownApp("Granola", .ignored, .other, ["com.granola.app"]),
        KnownApp("Voice Memos", .ignored, .other, ["com.apple.VoiceMemos"]),
        KnownApp("QuickTime Player", .ignored, .other, ["com.apple.QuickTimePlayerX"]),
        KnownApp("Photo Booth", .ignored, .other, ["com.apple.PhotoBooth"]),
        KnownApp("OBS", .ignored, .other, ["com.obsproject.obs-studio"]),
        KnownApp("Audacity", .ignored, .other, ["org.audacityteam.audacity"]),
        KnownApp("GarageBand", .ignored, .other, ["com.apple.garageband10"]),
        KnownApp("Logic Pro", .ignored, .other, ["com.apple.logic10"]),
        KnownApp("Ableton Live", .ignored, .other, ["com.ableton.live"]),
        KnownApp("Loom", .ignored, .other, ["com.loom.desktop"]),
        // The current ChatGPT app and Codex share "com.openai.codex"; it claims http/https links.
        KnownApp("ChatGPT", .ignored, .other, ["com.openai.chat", "com.openai.codex"]),
        KnownApp("Claude", .ignored, .other, ["com.anthropic.claudefordesktop"]),
        KnownApp("Kan", .ignored, .other, [KanPaths.bundleIdentifier]),
    ]

    /// System processes that use audio but are never calls (Siri, dictation, accessibility…).
    public static let systemNoiseBundleIDs: Set<String> = [
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.Siri", "com.apple.SiriNCService",
        "com.apple.universalaccessd", "com.apple.accessibility.heard", "com.apple.controlcenter",
        "com.apple.loginwindow", "com.apple.PowerChime", "systemsoundserverd", "com.apple.audiomxd",
        "com.apple.mediaremoted", "com.apple.cmio.ContinuityCaptureAgent", "com.apple.cloudpaird",
        "com.apple.SpeechRecognitionCore", "com.apple.dictationim", "com.apple.notificationcenterui",
        "com.apple.NowPlayingTouchUI", "com.apple.WindowManager",
    ]

    private static let index: [String: KnownApp] = {
        var m: [String: KnownApp] = [:]
        for app in known { for id in app.bundleIDs { m[id.lowercased()] = app } }
        return m
    }()

    /// Exact match, then helper-prefix match (longest known prefix followed by ".").
    public static func lookup(bundleID: String) -> KnownApp? {
        let lower = bundleID.lowercased()
        if let hit = index[lower] { return hit }
        var best: (len: Int, app: KnownApp)?
        for (id, app) in index where lower.hasPrefix(id + ".") {
            if id.count > (best?.len ?? -1) { best = (id.count, app) }
        }
        return best?.app
    }

    public static func isSystemNoise(bundleID: String) -> Bool {
        systemNoiseBundleIDs.contains(bundleID) || bundleID.isEmpty
    }

    /// Category for an owning app. Unknown apps that look like web browsers (see
    /// `looksLikeWebBrowser`) count as browsers, and so get the browser policy (auto by default).
    public static func category(bundleID: String, appURL: URL?) -> AppCategory {
        if let known = lookup(bundleID: bundleID) { return known.category }
        if isSystemNoise(bundleID: bundleID) { return .ignored }
        if let url = appURL, looksLikeWebBrowser(appURL: url) { return .browser }
        return .unknown
    }

    /// The app counts only while it also plays audio (see `KnownApp.requiresOutput`); apps outside
    /// the catalog don't need to.
    public static func requiresOutput(bundleID: String) -> Bool {
        lookup(bundleID: bundleID)?.requiresOutput ?? false
    }

    public static func platform(bundleID: String) -> CallPlatform {
        lookup(bundleID: bundleID)?.platform ?? .other
    }

    /// True if the app's Info.plist declares http or https URL schemes.
    public static func handlesWebURLs(appURL: URL) -> Bool {
        guard let info = Bundle(url: appURL)?.infoDictionary else { return false }
        return handlesWebURLs(info: info)
    }

    /// True if the app opens web links (http/https URL schemes) *and* HTML documents, which is
    /// what a browser declares to be eligible as the default browser. Web links alone are no
    /// evidence: assistants and utilities claim them too (the ChatGPT app, TeX Live Utility), and a
    /// browser's mic use is recorded automatically.
    public static func looksLikeWebBrowser(appURL: URL) -> Bool {
        guard let info = Bundle(url: appURL)?.infoDictionary else { return false }
        return looksLikeWebBrowser(info: info)
    }

    /// `looksLikeWebBrowser(appURL:)` for an Info.plist dictionary.
    public static func looksLikeWebBrowser(info: [String: Any]) -> Bool {
        handlesWebURLs(info: info) && opensHTMLDocuments(info: info)
    }

    private static let htmlContentTypes: Set<String> = ["public.html", "public.xhtml"]
    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml", "xht"]

    private static func handlesWebURLs(info: [String: Any]) -> Bool {
        guard let types = info["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        for t in types {
            let schemes = (t["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() }
            if schemes.contains("http") || schemes.contains("https") { return true }
        }
        return false
    }

    /// A document type for HTML, by content type (Chrome, Brave) or file extension (Safari, Zen).
    private static func opensHTMLDocuments(info: [String: Any]) -> Bool {
        guard let types = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        for t in types {
            let contentTypes = (t["LSItemContentTypes"] as? [String] ?? []).map { $0.lowercased() }
            let extensions = (t["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() }
            if contentTypes.contains(where: htmlContentTypes.contains) || extensions.contains(where: htmlExtensions.contains) {
                return true
            }
        }
        return false
    }

    /// Meeting platform for a browser tab URL.
    public static func platform(forURL urlString: String) -> CallPlatform? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("meet.google.com") { return .googleMeet }
        if on("teams.microsoft.com") || on("teams.live.com") || on("teams.cloud.microsoft") { return .teams }
        if on("zoom.us") || on("zoom.com") || on("zoomgov.com") {
            return (path.contains("/wc") || path.contains("/j/") || host.hasPrefix("app.")) ? .zoom : nil
        }
        if on("discord.com") { return .discord }
        if on("webex.com") { return .webex }
        if on("meet.jit.si") || host.contains("jitsi") { return .jitsi }
        if on("whereby.com") { return .whereby }
        if on("app.slack.com") { return .slack }
        if on("web.whatsapp.com") { return .whatsapp }
        if on("web.telegram.org") { return .telegram }
        if on("messenger.com") { return .messenger }
        if on("gather.town") || on("around.co") || on("chime.aws") || on("meet.goto.com") { return .other }
        return nil
    }

    /// Meeting platform guessed from a browser window title ("Meet - abc-defg-hij — Zen").
    public static func platform(forWindowTitle title: String) -> CallPlatform? {
        let t = title.lowercased()
        if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("google meet") { return .googleMeet }
        if t.contains("microsoft teams") { return .teams }
        if t.contains("zoom meeting") || t.contains("zoom workplace") { return .zoom }
        if t.contains("jitsi meet") { return .jitsi }
        if t.contains("whereby") { return .whereby }
        if t.contains("webex") { return .webex }
        if t.contains("discord") { return .discord }
        return nil
    }
}
