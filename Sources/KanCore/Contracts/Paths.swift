import Foundation

/// Every on-disk location Kan uses. Set the `KAN_HOME` environment variable to redirect all of
/// them into one directory (used by the self-tests and for experiments):
///   $KAN_HOME/AppSupport  instead of ~/Library/Application Support/Kan
///   $KAN_HOME/Library     instead of ~/Documents/Kan
///   $KAN_HOME/Logs        instead of ~/Library/Logs/Kan
public enum KanPaths {
    public static let bundleIdentifier = "com.nahian.Kan"

    private static var overrideHome: URL? {
        guard let v = ProcessInfo.processInfo.environment["KAN_HOME"], !v.isEmpty else { return nil }
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/Kan
    public static var appSupport: URL {
        if let o = overrideHome { return o.appendingPathComponent("AppSupport", isDirectory: true) }
        return home.appendingPathComponent("Library/Application Support/Kan", isDirectory: true)
    }

    /// Whisper ggml models, VAD model and FluidAudio's CoreML models (in `FluidAudio/`).
    public static var models: URL {
        // Models are large; share the real directory even under KAN_HOME unless KAN_MODELS is set.
        if let v = ProcessInfo.processInfo.environment["KAN_MODELS"], !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/Kan/Models", isDirectory: true)
    }

    public static var fluidAudioModels: URL { models.appendingPathComponent("FluidAudio", isDirectory: true) }

    /// Per-call working data: raw WAVs while recording/processing, kept audio, embeddings.
    public static var calls: URL { appSupport.appendingPathComponent("Calls", isDirectory: true) }

    public static func callDataDirectory(for id: CallID) -> URL {
        calls.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public static var voiceprintsFile: URL { appSupport.appendingPathComponent("voiceprints.json") }
    public static var processingQueueFile: URL { appSupport.appendingPathComponent("queue.json") }

    /// ~/Library/Logs/Kan
    public static var logs: URL {
        if let o = overrideHome { return o.appendingPathComponent("Logs", isDirectory: true) }
        return home.appendingPathComponent("Library/Logs/Kan", isDirectory: true)
    }

    /// ~/Documents/Kan — transcripts as Markdown + JSON, readable by people and AI agents.
    public static var defaultLibrary: URL {
        if let o = overrideHome { return o.appendingPathComponent("Library", isDirectory: true) }
        return home.appendingPathComponent("Documents/Kan", isDirectory: true)
    }

    /// The user's home folder ($KAN_HOME when set): where Kan offers a library folder that iCloud
    /// Drive doesn't sync (~/Kan) when the chosen one is synced.
    public static var userHome: URL { overrideHome ?? home }

    /// True when `url` — or, while it doesn't exist yet, the nearest folder above it that does — is
    /// synced by iCloud Drive: in iCloud Drive itself, or in Desktop or Documents with iCloud's
    /// "Desktop & Documents Folders" on (the default library ~/Documents/Kan then is). macOS
    /// uploads everything written there, transcripts included.
    public static func isInICloudDrive(_ url: URL) -> Bool {
        var candidate = url.standardizedFileURL
        while true {
            var info = stat()
            if stat(candidate.path, &info) == 0 {
                return (try? candidate.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return false }
            candidate = parent
        }
    }

    /// File names inside a call data directory.
    public enum CallFile {
        public static let meWAV = "me.wav"
        public static let themWAV = "them.wav"
        public static let anchors = "anchors.json"
        public static let session = "session.json"
        public static let meM4A = "me.m4a"
        public static let themM4A = "them.m4a"
        public static let embeddings = "embeddings.json"
    }

    public static func ensureDirectories() {
        for dir in [appSupport, models, calls, logs] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
