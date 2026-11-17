import Foundation
import KanCore

/// `<call data directory>/live.json`: what Kan knows about a recording while it runs and until the
/// call is saved to the library. Its presence marks a recording that hasn't reached the library
/// yet, so the next launch can recover it after a crash or a forced quit.
struct RecordingManifest: Codable, Equatable, Sendable {
    static let fileName = "live.json"
    /// Written into a call data directory whose call was deleted while its audio was kept, so the
    /// directory is never mistaken for an orphaned recording.
    static let detachedMarkerName = ".deleted"

    var version = 1
    var callID: CallID
    var appName: String
    var bundleID: String
    var category: AppCategory
    var platform: CallPlatform
    var meetingTitle: String?
    var meetingURL: String?
    /// When the call app took the microphone.
    var detectedAt: Date
    /// When the recorder started (the audio files' time zero).
    var recordingStartedAt: Date
    var isManual: Bool
    /// "Ask" apps: true until the user answered "Record".
    var isTentative: Bool
    var calendarEventTitle: String?
    var attendees: [String]
    var bookmarks: [Bookmark]
    var timeZone: String

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func read(in directory: URL) -> RecordingManifest? {
        guard let data = FileManager.default.contents(atPath: url(in: directory).path) else { return nil }
        do {
            return try JSONDecoder.kan.decode(RecordingManifest.self, from: data)
        } catch {
            KanLog.warning("Unreadable \(fileName) in \(directory.lastPathComponent): \(error)", category: "recording")
            return nil
        }
    }

    func write(in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder.kanPretty.encode(self).write(to: Self.url(in: directory), options: .atomic)
        } catch {
            KanLog.error("Couldn't write \(Self.fileName) for \(callID): \(error.localizedDescription)", category: "recording")
        }
    }

    static func remove(in directory: URL) {
        let url = url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            KanLog.warning("Couldn't remove \(fileName) in \(directory.lastPathComponent): \(error.localizedDescription)",
                           category: "recording")
        }
    }

    /// The source block of the CallRecord this recording becomes.
    var source: CallSource {
        CallSource(appName: appName, bundleID: bundleID.isEmpty ? nil : bundleID, platform: platform,
                   meetingTitle: meetingTitle, meetingURL: meetingURL)
    }
}

/// A lock-protected copy of the settings for code that runs off the main actor (the processing
/// queue's settings provider).
final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: KanSettings

    init(_ value: KanSettings) { self.value = value }

    func get() -> KanSettings { lock.withLock { value } }
    func set(_ newValue: KanSettings) { lock.withLock { value = newValue } }
}
