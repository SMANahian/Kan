import Foundation
import KanCore

/// Model catalog, downloads, deletion and "auto" resolution (`ModelManaging`).
///
/// Whisper and VAD files live directly in `directory` (`KanPaths.models`); FluidAudio's CoreML
/// models in `directory/FluidAudio`. A file counts as installed when it has the catalog's exact
/// size (downloads are verified by SHA-256 before they are renamed into place).
///
/// Thread-safety: all methods may be called from any thread; concurrent downloads of the same model
/// are rejected.
public final class ModelStore: ModelManaging, @unchecked Sendable {
    public let directory: URL
    public let catalog: [ModelSpec]
    private let sessionConfiguration: URLSessionConfiguration
    private let activeDownloads = LockedValue<Set<String>>([])

    public init(directory: URL = KanPaths.models, catalog: [ModelSpec] = ModelCatalog.all,
                sessionConfiguration: URLSessionConfiguration = .default) {
        self.directory = directory
        self.catalog = catalog
        self.sessionConfiguration = sessionConfiguration
    }

    public var fluidAudioDirectory: URL { directory.appendingPathComponent("FluidAudio", isDirectory: true) }

    public func spec(_ id: String) -> ModelSpec? { catalog.first { $0.id == id } }

    public func location(of spec: ModelSpec) -> URL {
        spec.kind == .fluidAudio ? fluidAudioDirectory : directory.appendingPathComponent(spec.fileName)
    }

    public func isInstalled(_ spec: ModelSpec) -> Bool {
        switch spec.kind {
        case .fluidAudio:
            return FluidAudioModelAccess.installed(at: fluidAudioDirectory)
        case .whisper, .vad:
            guard let size = ResumableDownloader.fileSize(location(of: spec)) else { return false }
            return spec.sizeBytes > 0 ? size == spec.sizeBytes : size > 0
        }
    }

    public func isInstalled(_ id: String) -> Bool { spec(id).map(isInstalled) ?? false }

    // MARK: - ModelManaging

    public func availableModels() -> [ModelInfo] {
        catalog.map { spec in
            ModelInfo(id: spec.id, displayName: spec.displayName, detail: spec.detail, role: spec.role,
                      sizeBytes: spec.sizeBytes, installed: isInstalled(spec),
                      recommended: ModelCatalog.autoPreference[spec.role]?.first == spec.id,
                      downloadable: spec.url != nil || spec.kind == .fluidAudio)
        }
    }

    public func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let spec = spec(id) else { throw ModelStoreError.unknownModel(id) }
        if isInstalled(spec) {
            progress(1)
            return
        }
        let claimed = activeDownloads.withValue { $0.insert(id).inserted }
        guard claimed else { throw ModelStoreError.alreadyDownloading(id) }
        defer { activeDownloads.withValue { _ = $0.remove(id) } }

        KanLog.info("Downloading \(spec.id)", category: "models")
        do {
            switch spec.kind {
            case .fluidAudio:
                try await FluidAudioModelAccess.prepareAll(directory: fluidAudioDirectory, progress: progress)
            case .whisper, .vad:
                guard let url = spec.url else { throw ModelStoreError.notDownloadable(id) }
                try await ResumableDownloader.download(from: url, to: location(of: spec),
                                                       expectedSize: spec.sizeBytes > 0 ? spec.sizeBytes : nil,
                                                       sha256: spec.sha256, configuration: sessionConfiguration,
                                                       progress: progress)
            }
            KanLog.info("Installed \(spec.id)", category: "models")
        } catch is CancellationError {
            KanLog.info("Download of \(spec.id) cancelled (partial file kept for resuming)", category: "models")
            throw CancellationError()
        } catch {
            KanLog.error("Download of \(spec.id) failed: \(error.localizedDescription)", category: "models")
            throw error
        }
    }

    public func delete(_ id: String) throws {
        guard let spec = spec(id) else { throw ModelStoreError.unknownModel(id) }
        let fileManager = FileManager.default
        var targets: [URL]
        switch spec.kind {
        case .fluidAudio:
            targets = ["speaker-diarization", "sortformer"].map { fluidAudioDirectory.appendingPathComponent($0) }
        case .whisper, .vad:
            let file = location(of: spec)
            targets = [file, file.appendingPathExtension("partial")]
        }
        targets = targets.filter { fileManager.fileExists(atPath: $0.path) }
        for target in targets {
            do {
                try fileManager.removeItem(at: target)
            } catch {
                throw ModelStoreError.fileSystem("Could not delete \(target.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !targets.isEmpty { KanLog.info("Deleted \(spec.id)", category: "models") }
    }

    public func readiness(for settings: KanSettings) -> ModelReadiness {
        let models = resolveModels(general: settings.generalModelID, english: settings.englishModelID,
                                   bangla: settings.banglaModelID)
        var missing: [String] = []
        var recommendations = models.notes
        let stock = models.general ?? models.english
        if models.vad == nil { missing.append("The voice activity model (Silero VAD, 0.9 MB) is not installed.") }
        switch settings.languageMode {
        case .english:
            if stock == nil { missing.append("No Whisper model for English is installed — download Whisper large-v3-turbo (1.6 GB).") }
        case .bangla:
            if models.bangla == nil { missing.append("No Whisper model for Bangla is installed — download the Bangla model (823 MB).") }
        case .auto:
            if stock == nil {
                missing.append("No Whisper model is installed — download Whisper large-v3 (q5_0, 1.1 GB) for Bangla + English.")
            }
        }
        if settings.languageMode != .english, models.bangla?.banglaTokenizer != true {
            recommendations.append("Download the Bangla model (823 MB) for much better Bangla.")
        }
        if settings.languageMode == .auto, let general = models.general, general.weakBanglaLanguageID {
            recommendations.append("Download Whisper large-v3 (q5_0, 1.1 GB): turbo often mistakes Bangla for Hindi.")
        }
        if settings.languageMode != .bangla, let english = models.english, !english.weakBanglaLanguageID {
            recommendations.append("Download Whisper large-v3-turbo (1.6 GB) for 2–3× faster English.")
        }
        if settings.diarize && !models.diarizationInstalled {
            recommendations.append("Download the speaker models (130 MB) to tell remote speakers apart.")
        }
        var resolved: [ModelRole: String] = [:]
        resolved[.general] = models.general?.id
        resolved[.english] = models.english?.id
        resolved[.bangla] = models.bangla?.id
        resolved[.vad] = models.vad?.id
        if models.diarizationInstalled { resolved[.diarization] = ModelCatalog.diarizationID }
        return ModelReadiness(canTranscribe: missing.isEmpty, missing: missing, recommendations: recommendations,
                              resolved: resolved)
    }

    // MARK: - Resolution

    public struct Resolution: Sendable, Equatable {
        public var spec: ModelSpec?
        /// Set when the requested model couldn't be used ("… is not installed — using …").
        public var note: String?
    }

    /// The installed model to use for `role` ("auto" or an explicit id; a missing explicit model
    /// falls back to "auto" with a note).
    ///
    /// auto: general = large-v3-q5_0 > large-v3 > turbo > turbo-q8_0; english = turbo > turbo-q8_0 >
    /// general; bangla = bengali-medium-q8_0 > bengali-medium-q5_0 > general.
    public func resolve(_ requested: String, role: ModelRole) -> Resolution {
        let id = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let automatic = autoResolve(role)
        guard !id.isEmpty, id.lowercased() != "auto" else { return Resolution(spec: automatic, note: nil) }
        let fallback = automatic.map { "using \($0.displayName)" } ?? "no replacement is installed"
        // A Bangla-tokenizer fine-tune can't identify languages or transcribe English.
        guard let spec = spec(id), Self.kinds(for: role).contains(spec.kind),
              role == .bangla || !spec.banglaTokenizer else {
            return Resolution(spec: automatic, note: "Unknown \(role.rawValue) model “\(id)” — \(fallback).")
        }
        guard isInstalled(spec) else {
            return Resolution(spec: automatic, note: "\(spec.displayName) is selected but not installed — \(fallback).")
        }
        return Resolution(spec: spec, note: nil)
    }

    public struct ResolvedModels: Sendable, Equatable {
        public var general: ModelSpec?
        public var english: ModelSpec?
        public var bangla: ModelSpec?
        public var vad: ModelSpec?
        public var diarizationInstalled: Bool
        public var notes: [String]
    }

    public func resolveModels(general: String = "auto", english: String = "auto", bangla: String = "auto") -> ResolvedModels {
        let g = resolve(general, role: .general)
        let e = resolve(english, role: .english)
        let b = resolve(bangla, role: .bangla)
        let vad = resolve("auto", role: .vad)
        return ResolvedModels(general: g.spec, english: e.spec, bangla: b.spec, vad: vad.spec,
                              diarizationInstalled: isInstalled(ModelCatalog.diarizationID),
                              notes: [g.note, e.note, b.note].compactMap { $0 })
    }

    private func autoResolve(_ role: ModelRole) -> ModelSpec? {
        let preferred = (ModelCatalog.autoPreference[role] ?? []).lazy.compactMap { self.spec($0) }.first(where: isInstalled)
        if let preferred { return preferred }
        switch role {
        case .english, .bangla: return autoResolve(.general)
        case .general, .vad, .diarization: return nil
        }
    }

    private static func kinds(for role: ModelRole) -> Set<ModelSpec.Kind> {
        switch role {
        case .general, .english, .bangla: return [.whisper]
        case .vad: return [.vad]
        case .diarization: return [.fluidAudio]
        }
    }
}
