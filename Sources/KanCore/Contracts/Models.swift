import Foundation

// MARK: - Identifiers

/// Stable, time-sortable identifier for a call: a ULID (26 chars, Crockford base32).
/// It lives in the transcript's front matter and JSON, so files can be renamed or moved freely.
///
/// The id also names the call's data directory (`KanPaths.callDataDirectory`), so ids read from
/// files are validated: decoding accepts only a ULID (in any case, stored uppercase), never
/// "", "..", "../Models" or other strings that could point outside that directory.
public struct CallID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// The id in `string` (a ULID, any case; surrounding whitespace ignored), or nil.
    public init?(parsing string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // ASCII only, so uppercasing can't turn other letters into ULID ones ("ß" → "SS").
        guard trimmed.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let upper = trimmed.uppercased()
        guard ULID.isValid(upper) else { return nil }
        rawValue = upper
    }

    public static func generate(date: Date = Date()) -> CallID {
        CallID(rawValue: ULID.make(date: date))
    }

    /// True for a canonical ULID: 26 uppercase Crockford base32 characters, which is what Kan
    /// generates and what decoding produces. Only such ids are safe as a path component.
    public var isWellFormed: Bool { ULID.isValid(rawValue) }

    public var description: String { rawValue }
    public static func < (a: CallID, b: CallID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = CallID(parsing: string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid call id \(string.debugDescription): a call id is a 26-character ULID")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let characters = Set(alphabet.map { $0.asciiValue ?? 0 })
    static let length = 26

    /// 26 uppercase Crockford base32 characters.
    static func isValid(_ string: String) -> Bool {
        var count = 0
        for byte in string.utf8 {
            guard characters.contains(byte) else { return false }
            count += 1
        }
        return count == length
    }

    static func make(date: Date) -> String {
        var ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var time = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            time[i] = alphabet[Int(ms & 31)]
            ms >>= 5
        }
        var rng = SystemRandomNumberGenerator()
        let random = (0..<16).map { _ in alphabet[Int(rng.next() % 32)] }
        return String(time) + String(random)
    }
}

// MARK: - Call metadata

/// Where a call happened. Used for icons, default titles and filtering.
public enum CallPlatform: String, Codable, Sendable, CaseIterable {
    case zoom, googleMeet, teams, slack, discord, telegram, whatsapp, facetime, webex, signal
    case skype, messenger, jitsi, whereby, browser, manual, imported, other

    public var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .slack: return "Slack"
        case .discord: return "Discord"
        case .telegram: return "Telegram"
        case .whatsapp: return "WhatsApp"
        case .facetime: return "FaceTime"
        case .webex: return "Webex"
        case .signal: return "Signal"
        case .skype: return "Skype"
        case .messenger: return "Messenger"
        case .jitsi: return "Jitsi Meet"
        case .whereby: return "Whereby"
        case .browser: return "Browser call"
        case .manual: return "Manual recording"
        case .imported: return "Imported audio"
        case .other: return "Call"
        }
    }
}

/// The app (and, for browsers, the meeting) a call was captured from.
public struct CallSource: Codable, Sendable, Hashable {
    public var appName: String            // "Zoom", "Zen", "Telegram"
    public var bundleID: String?          // "us.zoom.xos"
    public var platform: CallPlatform
    public var meetingTitle: String?      // from the browser tab / window title or calendar
    public var meetingURL: String?        // e.g. "https://meet.google.com/abc-defg-hij"

    public init(appName: String, bundleID: String? = nil, platform: CallPlatform,
                meetingTitle: String? = nil, meetingURL: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.platform = platform
        self.meetingTitle = meetingTitle
        self.meetingURL = meetingURL
    }
}

public enum CallStatus: String, Codable, Sendable {
    case recording      // capture in progress
    case queued         // waiting for transcription
    case processing     // transcription running
    case ready          // transcript available
    case failed         // transcription failed (see ProcessingInfo.error); audio kept for retry
}

/// Language handling for a call. `.auto` decides Bangla vs English per speech chunk.
public enum LanguageMode: String, Codable, Sendable, CaseIterable {
    case auto, bangla, english

    public var displayName: String {
        switch self {
        case .auto: return "Auto (বাংলা + English)"
        case .bangla: return "বাংলা"
        case .english: return "English"
        }
    }
}

/// Which recorded track a segment came from: the user's microphone or the call app's audio.
public enum AudioChannel: String, Codable, Sendable {
    case me, them
}

// MARK: - Transcript

public enum SpeakerNameSource: String, Codable, Sendable {
    case automatic      // "Speaker 1" or the user's own name
    case user           // typed by the user
    case voiceprint     // auto-assigned from a remembered voice
}

public struct Speaker: Codable, Sendable, Hashable, Identifiable {
    /// "me" for the microphone track; "s1", "s2", … for diarized remote speakers.
    public var id: String
    public var name: String
    public var isMe: Bool
    public var nameSource: SpeakerNameSource
    /// Seconds of speech attributed to this speaker.
    public var talkTime: Double
    /// Voiceprint person this speaker is linked to, if any.
    public var personID: String?
    /// A voiceprint match that was not confident enough to apply automatically ("Sounds like …").
    public var suggestedName: String?

    public static let meID = "me"

    public init(id: String, name: String, isMe: Bool, nameSource: SpeakerNameSource = .automatic,
                talkTime: Double = 0, personID: String? = nil, suggestedName: String? = nil) {
        self.id = id
        self.name = name
        self.isMe = isMe
        self.nameSource = nameSource
        self.talkTime = talkTime
        self.personID = personID
        self.suggestedName = suggestedName
    }
}

public enum SegmentFlag: String, Codable, Sendable {
    case echoSuspect            // mic segment that probably repeats the remote side (speaker bleed)
    case lowConfidence
    case hallucinationSuspect
    case truncatedRetry         // decoder hit its token budget and the chunk was re-split
    case edited                 // text edited by the user
}

public struct TranscriptSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Seconds from the start of the call (shared clock for both tracks).
    public var start: Double
    public var end: Double
    public var speakerID: String
    public var channel: AudioChannel
    /// NFC-normalized text.
    public var text: String
    /// ISO 639-1 code: "bn" or "en".
    public var language: String
    /// Mean token probability (0…1), when known.
    public var confidence: Double?
    public var flags: [SegmentFlag]

    public init(id: Int, start: Double, end: Double, speakerID: String, channel: AudioChannel,
                text: String, language: String, confidence: Double? = nil, flags: [SegmentFlag] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.channel = channel
        self.text = text
        self.language = language
        self.confidence = confidence
        self.flags = flags
    }
}

/// A moment the user marked during or after the call.
public struct Bookmark: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var time: Double         // seconds from call start
    public var endTime: Double?
    public var note: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, time: Double, endTime: Double? = nil, note: String = "",
                createdAt: Date = Date()) {
        self.id = id
        self.time = time
        self.endTime = endTime
        self.note = note
        self.createdAt = createdAt
    }
}

/// Audio kept for playback / re-transcription. Files live in `KanPaths.callDataDirectory(for:)`.
public struct AudioAssets: Codable, Sendable, Hashable {
    public var meFile: String?          // file name, e.g. "me.m4a"
    public var themFile: String?        // e.g. "them.m4a"
    public var format: String           // "m4a" or "wav"
    public var sizeBytes: Int64?
    public var deletedAt: Date?         // set when retention removed the audio

    public init(meFile: String?, themFile: String?, format: String, sizeBytes: Int64? = nil, deletedAt: Date? = nil) {
        self.meFile = meFile
        self.themFile = themFile
        self.format = format
        self.sizeBytes = sizeBytes
        self.deletedAt = deletedAt
    }

    public var isAvailable: Bool { deletedAt == nil && (meFile != nil || themFile != nil) }
}

public struct ProcessingInfo: Codable, Sendable, Hashable {
    public var modelsUsed: [String]
    public var languageMode: LanguageMode
    public var startedAt: Date?
    public var finishedAt: Date?
    public var processingSeconds: Double?
    public var error: String?
    public var warnings: [String]
    public var kanVersion: String
    public var attempts: Int
    /// The pipeline's timing and quality counters (`TranscriptionOutput.stats`), e.g. "seconds.total".
    public var stats: [String: Double]?

    public init(modelsUsed: [String] = [], languageMode: LanguageMode = .auto, startedAt: Date? = nil,
                finishedAt: Date? = nil, processingSeconds: Double? = nil, error: String? = nil,
                warnings: [String] = [], kanVersion: String = KanVersion.current, attempts: Int = 0,
                stats: [String: Double]? = nil) {
        self.modelsUsed = modelsUsed
        self.languageMode = languageMode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.processingSeconds = processingSeconds
        self.error = error
        self.warnings = warnings
        self.kanVersion = kanVersion
        self.attempts = attempts
        self.stats = stats
    }
}

public enum KanVersion {
    public static let current = "0.1.0"
}

// MARK: - Call record

/// Everything Kan knows about one call. Persisted as `<Library>/<Folder>/<YYYY-MM-DD HHmm Title>.json`
/// next to a rendered `.md` with the same base name.
public struct CallRecord: Codable, Sendable, Identifiable {
    public static let currentSchema = 1

    public var kind: String = "kan.call"
    public var schema: Int = CallRecord.currentSchema
    public var id: CallID
    public var title: String
    /// Library folder, "" for the Inbox. Nested folders use "/", e.g. "Research/Thesis".
    public var folder: String
    public var tags: [String]
    public var notes: String
    public var starred: Bool
    /// True once the user saved the post-call label panel (or edited the call in the library).
    public var labeled: Bool
    public var startedAt: Date
    public var endedAt: Date
    /// TimeZone identifier at recording time, e.g. "America/New_York".
    public var timeZone: String
    public var source: CallSource
    public var status: CallStatus
    public var languageMode: LanguageMode
    /// Languages actually detected in the transcript ("bn", "en").
    public var languages: [String]
    /// Calendar event matched to this call, if any.
    public var calendarEventTitle: String?
    public var attendees: [String]
    public var speakers: [Speaker]
    public var segments: [TranscriptSegment]
    public var bookmarks: [Bookmark]
    public var audio: AudioAssets?
    public var processing: ProcessingInfo?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: CallID = .generate(), title: String, folder: String = "", tags: [String] = [],
                notes: String = "", starred: Bool = false, labeled: Bool = false, startedAt: Date,
                endedAt: Date, timeZone: String = TimeZone.current.identifier, source: CallSource,
                status: CallStatus = .queued, languageMode: LanguageMode = .auto, languages: [String] = [],
                calendarEventTitle: String? = nil, attendees: [String] = [], speakers: [Speaker] = [],
                segments: [TranscriptSegment] = [], bookmarks: [Bookmark] = [], audio: AudioAssets? = nil,
                processing: ProcessingInfo? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.folder = folder
        self.tags = tags
        self.notes = notes
        self.starred = starred
        self.labeled = labeled
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZone = timeZone
        self.source = source
        self.status = status
        self.languageMode = languageMode
        self.languages = languages
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.speakers = speakers
        self.segments = segments
        self.bookmarks = bookmarks
        self.audio = audio
        self.processing = processing
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }

    public var me: Speaker? { speakers.first { $0.isMe } }
}

/// Lightweight row used by lists, the index files, the CLI and MCP (no segments).
public struct CallSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: CallID
    public var title: String
    public var folder: String
    public var tags: [String]
    public var starred: Bool
    public var labeled: Bool
    public var startedAt: Date
    public var endedAt: Date
    public var timeZone: String
    public var appName: String
    public var platform: CallPlatform
    public var status: CallStatus
    public var speakerNames: [String]
    public var languages: [String]
    public var segmentCount: Int
    public var wordCount: Int
    public var hasAudio: Bool
    /// First words of the notes or transcript.
    public var preview: String
    /// Paths relative to the library root.
    public var markdownPath: String
    public var jsonPath: String

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    public init(id: CallID, title: String, folder: String, tags: [String], starred: Bool, labeled: Bool,
                startedAt: Date, endedAt: Date, timeZone: String, appName: String, platform: CallPlatform,
                status: CallStatus, speakerNames: [String], languages: [String], segmentCount: Int,
                wordCount: Int, hasAudio: Bool, preview: String, markdownPath: String, jsonPath: String) {
        self.id = id
        self.title = title
        self.folder = folder
        self.tags = tags
        self.starred = starred
        self.labeled = labeled
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZone = timeZone
        self.appName = appName
        self.platform = platform
        self.status = status
        self.speakerNames = speakerNames
        self.languages = languages
        self.segmentCount = segmentCount
        self.wordCount = wordCount
        self.hasAudio = hasAudio
        self.preview = preview
        self.markdownPath = markdownPath
        self.jsonPath = jsonPath
    }
}
