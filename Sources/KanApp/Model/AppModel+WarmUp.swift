import Foundation
import KanCore

/// Which models a warm-up loaded, in which build (stored in UserDefaults).
struct WarmUpRecord: Equatable {
    var build: String
    var models: Set<String>

    private static let buildKey = "KanWarmedUpBuild"
    private static let modelsKey = "KanWarmedUpModels"

    /// nil before the first warm-up. Versions that didn't list the models count as having warmed none.
    static func load(from defaults: UserDefaults = .standard) -> WarmUpRecord? {
        guard let build = defaults.string(forKey: buildKey) else { return nil }
        return WarmUpRecord(build: build, models: Set(defaults.stringArray(forKey: modelsKey) ?? []))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(build, forKey: Self.buildKey)
        defaults.set(models.sorted(), forKey: Self.modelsKey)
    }

    /// A deleted model must be warmed up again once it's back.
    static func forget(_ id: String, in defaults: UserDefaults = .standard) {
        guard var record = load(from: defaults), record.models.remove(id) != nil else { return }
        record.save(to: defaults)
    }
}

extension AppModel {
    /// The models a warm-up loads for these settings: the Whisper models transcription resolves
    /// to and, when speakers are separated, the speaker models. Empty while none is installed.
    static func warmableModels(_ readiness: ModelReadiness, diarize: Bool) -> Set<String> {
        var ids = Set([ModelRole.general, .english, .bangla].compactMap { readiness.resolved[$0] })
        if diarize, let speakers = readiness.resolved[.diarization] { ids.insert(speakers) }
        return ids
    }

    /// Installed models that `build` hasn't warmed up yet.
    static func modelsNeedingWarmUp(_ installed: Set<String>, warmed: WarmUpRecord?, build: String) -> Set<String> {
        guard let warmed, warmed.build == build else { return installed }
        return installed.subtracting(warmed.models)
    }

    /// While idle, load each transcription model once per build so the first real transcription
    /// doesn't pay one-time compilation (~6 s Metal kernels, ~16 s speaker models). Only the
    /// models that were installed get recorded, so models installed later (a download, which
    /// calls this again, or the next launch) are warmed up too. Busy (a call, a transcription):
    /// looks again later.
    func scheduleModelWarmUp() {
        guard !services.isMock, !environment.isHeadless, warmUpTask == nil else { return }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? KanVersion.current
        warmUpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let pending = await self?.modelsToWarmUp(build: build), !pending.isEmpty else { break }
                try? await Task.sleep(for: .seconds(90))
                guard let self, !Task.isCancelled else { break }
                guard self.liveCall == nil, !self.isTranscribing else { continue }
                // Models may have come or gone while waiting.
                let models = await self.modelsToWarmUp(build: build)
                guard !models.isEmpty, !Task.isCancelled else { break }
                let transcriber = self.services.transcriber
                let settings = self.settings
                await Task.detached(priority: .background) { await transcriber.warmUp(settings: settings) }.value
                var record = WarmUpRecord.load().flatMap { $0.build == build ? $0 : nil } ?? WarmUpRecord(build: build, models: [])
                record.models.formUnion(models)
                record.save()
                KanLog.info("Warmed up \(models.sorted().joined(separator: ", ")) for build \(build)", category: "models")
                break
            }
            self?.warmUpTask = nil
        }
    }

    /// The models the next transcription uses that `build` hasn't warmed up yet.
    private func modelsToWarmUp(build: String) async -> Set<String> {
        let models = services.models
        let settings = self.settings
        let readiness = await Task.detached(priority: .utility) { models.readiness(for: settings) }.value
        return Self.modelsNeedingWarmUp(Self.warmableModels(readiness, diarize: settings.diarize),
                                        warmed: WarmUpRecord.load(), build: build)
    }
}
