import Foundation

/// What to do when an app starts a call.
public enum AppPolicy: String, Codable, Sendable, CaseIterable {
    case auto       // record automatically (with an undo toast)
    case ask        // start capturing tentatively and ask
    case never      // ignore this app

    public var displayName: String {
        switch self {
        case .auto: return "Record automatically"
        case .ask: return "Ask"
        case .never: return "Never"
        }
    }
}

/// Which audio to record as "them".
public enum CaptureScope: String, Codable, Sendable, CaseIterable {
    case callApp            // only the call app's processes (recommended)
    case allSystemAudio     // everything the Mac plays, except Kan itself
}

/// A reusable instruction for "Copy for AI". Placeholders: {{title}}, {{date}}, {{me}},
/// {{participants}}, {{transcript}}, {{notes}}, {{duration}}.
public struct PromptTemplate: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var body: String

    public init(id: String, name: String, body: String) {
        self.id = id
        self.name = name
        self.body = body
    }

    public static let defaults: [PromptTemplate] = [
        PromptTemplate(id: "research-ideas", name: "Extract research ideas", body: """
            Below is a transcript of a call I ({{me}}) had: "{{title}}" on {{date}} ({{duration}}). \
            Participants: {{participants}}. The conversation may mix Bangla (বাংলা) and English; English \
            technical terms sometimes appear in Bengali script.

            List every research idea, hypothesis, method, dataset or paper that was discussed. For each one give: \
            who proposed it, a short explanation, open questions, and the timestamp(s) where it was discussed. \
            Then list concrete next steps with owners.

            {{notes}}
            {{transcript}}
            """),
        PromptTemplate(id: "summary", name: "Summarize", body: """
            Summarize this call for me ({{me}}). The transcript may mix Bangla and English. Give: a 5-bullet \
            summary, decisions made, action items (with owners), and anything I should follow up on. Cite \
            timestamps.

            Call: "{{title}}" — {{date}} — {{duration}} — {{participants}}
            {{notes}}
            {{transcript}}
            """),
        PromptTemplate(id: "explain", name: "Help me understand", body: """
            I ({{me}}) was on this call and want to understand it deeply. The transcript may mix Bangla and \
            English. Explain the main topics in plain language, define any jargon, point out anything that \
            seemed unclear or contradictory, and suggest questions I could ask next time. Cite timestamps.

            Call: "{{title}}" — {{date}} — {{participants}}
            {{notes}}
            {{transcript}}
            """),
        PromptTemplate(id: "raw", name: "Transcript only", body: "{{transcript}}"),
    ]
}

/// All user preferences. Persisted as JSON at `KanPaths.settingsFile` (shared with the `kan` CLI).
/// Every field has a default so older/newer files decode safely.
public struct KanSettings: Codable, Sendable, Equatable {
    public var version: Int = 1

    // General
    /// The user's own name, used for the microphone track ("Me" until set).
    public var userName: String = ""
    /// Library root; empty = `KanPaths.defaultLibrary`.
    public var libraryPath: String = ""
    public var showLabelPrompt: Bool = true
    public var onboardingCompleted: Bool = false

    // Detection
    public var autoDetect: Bool = true
    /// Per-bundle-ID overrides of the catalog defaults.
    public var appPolicies: [String: AppPolicy] = [:]
    /// Policy for browsers (Zen, Chrome, Safari, Firefox, Arc, …) using the mic.
    public var browserPolicy: AppPolicy = .auto
    /// Policy for apps that aren't in the catalog.
    public var unknownAppPolicy: AppPolicy = .ask
    /// Recordings shorter than this are discarded silently (auto-detected calls only).
    public var minCallSeconds: Double = 20
    /// The call app must hold the mic this long before a call is considered started.
    public var startConfirmSeconds: Double = 3
    /// Countdown after the mic is released before the call is considered over.
    public var endGraceNativeSeconds: Double = 15
    public var endGraceBrowserSeconds: Double = 30
    /// Ask "still in a call?" after this long without any audio on either track.
    public var staleSilenceMinutes: Double = 15
    public var captureScope: CaptureScope = .callApp
    /// Don't run transcription (GPU-heavy) while a call is being recorded.
    public var pauseTranscriptionDuringCalls: Bool = true

    // Transcription
    public var languageMode: LanguageMode = .auto
    /// Model ids ("auto" = best installed). See `ModelManaging.availableModels()`.
    public var generalModelID: String = "auto"
    public var englishModelID: String = "auto"
    public var banglaModelID: String = "auto"
    /// Names, jargon and terms that help the recognizer (comma or newline separated).
    public var vocabulary: String = ""
    public var diarize: Bool = true
    public var maxRemoteSpeakers: Int? = nil
    public var echoSuppression: Bool = true
    /// Remember speakers' voices to name them automatically in later calls (asked once).
    public var rememberVoices: Bool = false
    public var askedAboutVoices: Bool = false

    // Storage
    public var keepAudio: Bool = true
    /// nil = keep forever. Starred calls are always kept.
    public var audioRetentionDays: Int? = nil

    // AI agents
    public var promptTemplates: [PromptTemplate] = PromptTemplate.defaults

    // Shortcuts
    public var globalHotkeysEnabled: Bool = true

    // Calendar
    public var useCalendar: Bool = false

    public init() {}

    /// Display name for the microphone track.
    public var effectiveUserName: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Me" : trimmed
    }

    public var libraryURL: URL {
        let trimmed = libraryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return KanPaths.defaultLibrary }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Decodes field by field, and collections entry by entry: a value this build doesn't
    /// understand (from a newer Kan, or a typo) loses only itself. An app policy it can't read
    /// becomes `.ask` — never a more permissive default for an app the user configured. What was
    /// dropped is reported through `SettingsDecodingReport` (`SettingsStore` keeps a backup).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KanSettings()
        let report = SettingsDecodingReport.current(in: decoder)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            guard c.contains(key) else { return fallback }
            do {
                return try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                report?.note("“\(key.stringValue)” couldn't be read; using the default")
                return fallback
            }
        }
        func optional<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? {
            guard c.contains(key) else { return nil }
            do {
                return try c.decodeIfPresent(T.self, forKey: key)
            } catch {
                report?.note("“\(key.stringValue)” couldn't be read; using the default")
                return nil
            }
        }
        version = v(.version, d.version)
        userName = v(.userName, d.userName)
        libraryPath = v(.libraryPath, d.libraryPath)
        showLabelPrompt = v(.showLabelPrompt, d.showLabelPrompt)
        onboardingCompleted = v(.onboardingCompleted, d.onboardingCompleted)
        autoDetect = v(.autoDetect, d.autoDetect)
        appPolicies = Self.decodeAppPolicies(c, report: report)
        browserPolicy = v(.browserPolicy, d.browserPolicy)
        unknownAppPolicy = v(.unknownAppPolicy, d.unknownAppPolicy)
        minCallSeconds = v(.minCallSeconds, d.minCallSeconds)
        startConfirmSeconds = v(.startConfirmSeconds, d.startConfirmSeconds)
        endGraceNativeSeconds = v(.endGraceNativeSeconds, d.endGraceNativeSeconds)
        endGraceBrowserSeconds = v(.endGraceBrowserSeconds, d.endGraceBrowserSeconds)
        staleSilenceMinutes = v(.staleSilenceMinutes, d.staleSilenceMinutes)
        captureScope = v(.captureScope, d.captureScope)
        pauseTranscriptionDuringCalls = v(.pauseTranscriptionDuringCalls, d.pauseTranscriptionDuringCalls)
        languageMode = v(.languageMode, d.languageMode)
        generalModelID = v(.generalModelID, d.generalModelID)
        englishModelID = v(.englishModelID, d.englishModelID)
        banglaModelID = v(.banglaModelID, d.banglaModelID)
        vocabulary = v(.vocabulary, d.vocabulary)
        diarize = v(.diarize, d.diarize)
        maxRemoteSpeakers = optional(.maxRemoteSpeakers, Int.self)
        echoSuppression = v(.echoSuppression, d.echoSuppression)
        rememberVoices = v(.rememberVoices, d.rememberVoices)
        askedAboutVoices = v(.askedAboutVoices, d.askedAboutVoices)
        keepAudio = v(.keepAudio, d.keepAudio)
        audioRetentionDays = optional(.audioRetentionDays, Int.self)
        promptTemplates = Self.decodePromptTemplates(c, fallback: d.promptTemplates, report: report)
        globalHotkeysEnabled = v(.globalHotkeysEnabled, d.globalHotkeysEnabled)
        useCalendar = v(.useCalendar, d.useCalendar)
    }

    private enum CodingKeys: String, CodingKey {
        case version, userName, libraryPath, showLabelPrompt, onboardingCompleted
        case autoDetect, appPolicies, browserPolicy, unknownAppPolicy, minCallSeconds, startConfirmSeconds
        case endGraceNativeSeconds, endGraceBrowserSeconds, staleSilenceMinutes, captureScope
        case pauseTranscriptionDuringCalls
        case languageMode, generalModelID, englishModelID, banglaModelID, vocabulary, diarize
        case maxRemoteSpeakers, echoSuppression, rememberVoices, askedAboutVoices
        case keepAudio, audioRetentionDays, promptTemplates, globalHotkeysEnabled, useCalendar
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Consumes one element of any shape (to step over an unreadable array element).
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private static func decodeAppPolicies(_ c: KeyedDecodingContainer<CodingKeys>,
                                          report: SettingsDecodingReport?) -> [String: AppPolicy] {
        guard c.contains(.appPolicies), (try? c.decodeNil(forKey: .appPolicies)) == false else { return [:] }
        guard let entries = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .appPolicies) else {
            report?.note("“appPolicies” couldn't be read; no app has its own policy")
            return [:]
        }
        var policies: [String: AppPolicy] = [:]
        for key in entries.allKeys {
            if let raw = try? entries.decode(String.self, forKey: key), let policy = AppPolicy(rawValue: raw) {
                policies[key.stringValue] = policy
            } else {
                let raw = (try? entries.decode(String.self, forKey: key)).map { "“\($0)”" } ?? "an invalid value"
                report?.note("the policy for \(key.stringValue) is \(raw); using Ask")
                policies[key.stringValue] = .ask
            }
        }
        return policies
    }

    private static func decodePromptTemplates(_ c: KeyedDecodingContainer<CodingKeys>, fallback: [PromptTemplate],
                                              report: SettingsDecodingReport?) -> [PromptTemplate] {
        guard c.contains(.promptTemplates), (try? c.decodeNil(forKey: .promptTemplates)) == false else { return fallback }
        guard var elements = try? c.nestedUnkeyedContainer(forKey: .promptTemplates) else {
            report?.note("“promptTemplates” couldn't be read; using the default templates")
            return fallback
        }
        var templates: [PromptTemplate] = []
        var dropped = 0
        while !elements.isAtEnd {
            if let template = try? elements.decode(PromptTemplate.self) {
                templates.append(template)
            } else {
                dropped += 1
                guard (try? elements.decode(Skipped.self)) != nil else { break }
            }
        }
        if dropped > 0 {
            report?.note("\(dropped) prompt template(s) couldn't be read and were left out")
            if templates.isEmpty { return fallback }
        }
        return templates
    }
}

/// What `KanSettings` decoding had to leave out or replace (unknown values from a newer Kan,
/// typos in a hand-edited file). Set an instance in the decoder's `userInfo` under `key`.
public final class SettingsDecodingReport: @unchecked Sendable {
    public static let key = CodingUserInfoKey(rawValue: "kan.settingsDecodingReport")

    private let lock = NSLock()
    private var notes: [String] = []

    public init() {}

    /// Human-readable notes, in decoding order; empty when nothing was lost.
    public var issues: [String] { lock.withLock { notes } }

    func note(_ issue: String) { lock.withLock { notes.append(issue) } }

    static func current(in decoder: Decoder) -> SettingsDecodingReport? {
        guard let key else { return nil }
        return decoder.userInfo[key] as? SettingsDecodingReport
    }
}

/// Reads and writes `KanSettings` atomically. Safe to use from any thread.
///
/// When `load()` had to leave values out (see `KanSettings.init(from:)`), the next `save()` first
/// copies the original file to "settings.backup-<unix time>.json", so nothing the user set is
/// lost for good by rewriting the file.
public final class SettingsStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    /// Decoding the file as loaded dropped something: the next save backs it up first.
    private var backUpBeforeSaving = false

    public init(fileURL: URL = KanPaths.settingsFile) {
        self.fileURL = fileURL
    }

    /// Returns defaults when the file is missing or unreadable (a corrupt file is moved aside).
    public func load() -> KanSettings {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return KanSettings() }
        let decoder = JSONDecoder.kan
        let report = SettingsDecodingReport()
        if let key = SettingsDecodingReport.key { decoder.userInfo[key] = report }
        do {
            let settings = try decoder.decode(KanSettings.self, from: data)
            backUpBeforeSaving = !report.issues.isEmpty
            if backUpBeforeSaving {
                KanLog.warning("settings.json: \(report.issues.joined(separator: "; ")). The file is backed up before it is next saved.",
                               category: "settings")
            }
            return settings
        } catch {
            let aside = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            KanLog.error("settings.json unreadable (\(error)); moved to \(aside.lastPathComponent)", category: "settings")
            return KanSettings()
        }
    }

    public func save(_ settings: KanSettings) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backUpBeforeSaving, FileOps.exists(fileURL) {
            backUpBeforeSaving = false
            let backup = fileURL.deletingPathExtension().appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.copyItem(at: fileURL, to: backup)
                KanLog.info("Kept the previous settings as \(backup.lastPathComponent) (some of its values aren't understood by this version)",
                            category: "settings")
            } catch {
                KanLog.error("Couldn't back up settings.json before saving: \(error.localizedDescription)", category: "settings")
            }
        }
        let data = try JSONEncoder.kanPretty.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
