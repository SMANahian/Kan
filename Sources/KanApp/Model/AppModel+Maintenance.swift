import Foundation
import KanCore

/// Finds recordings that never reached the library: Kan crashed, was force-quit or the Mac lost
/// power while recording (or between stopping and saving). Read-only and thread-safe.
///
/// A call data directory is an orphan when it holds WAV audio, isn't in the library, and either
/// still has `live.json` (Kan's "not saved yet" marker) or has no `session.json` (the recorder was
/// never stopped). Directories of deleted calls (`.deleted` marker) and of calls in another
/// library (no `live.json`, but a `session.json`) are left alone.
enum OrphanScanner {
    enum Finding {
        /// Audio without a call: becomes a call.
        case orphan(manifest: RecordingManifest, result: RecordingResult)
        /// A library record still marked `.recording`.
        case stuck(CallID, duration: Double)
        /// `live.json` of a call that was saved (Kan quit right after saving).
        case staleManifest(URL)
        /// A recording that never captured audio.
        case empty(URL)
    }

    static func scan(callsDirectory: URL, library: LibraryStore, excluding: CallID?) -> [Finding] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: callsDirectory.path) else { return [] }
        var findings: [Finding] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let id = CallID(rawValue: name)
            guard id.ulidDate != nil, id != excluding else { continue }
            let directory = callsDirectory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !fm.fileExists(atPath: directory.appendingPathComponent(RecordingManifest.detachedMarkerName).path)
            else { continue }

            let manifest = RecordingManifest.read(in: directory)
            let me = audioFile(KanPaths.CallFile.meWAV, in: directory)
            let them = audioFile(KanPaths.CallFile.themWAV, in: directory)
            let wavDuration = max(me.flatMap(WAV.duration(of:)) ?? 0, them.flatMap(WAV.duration(of:)) ?? 0)

            if library.contains(id) {
                if let record = try? library.record(id), record.status == .recording {
                    findings.append(.stuck(id, duration: wavDuration))
                } else if manifest != nil {
                    findings.append(.staleManifest(directory))
                }
                continue
            }
            let session = sessionResult(in: directory)
            guard me != nil || them != nil else {
                let hasAnyAudio = [KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A]
                    .contains { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
                if manifest != nil && !hasAnyAudio { findings.append(.empty(directory)) }
                continue
            }
            guard manifest != nil || session == nil else { continue }

            let startedAt = session?.startedAt ?? manifest?.recordingStartedAt ?? id.ulidDate ?? Date()
            let result = session ?? RecordingResult(
                callID: id, directory: directory, meFile: me, themFile: them,
                anchorsFile: audioFile(KanPaths.CallFile.anchors, in: directory, minimumBytes: 1),
                startedAt: startedAt, endedAt: startedAt.addingTimeInterval(wavDuration),
                meSeconds: me.flatMap(WAV.duration(of:)) ?? 0, themSeconds: them.flatMap(WAV.duration(of:)) ?? 0,
                loudspeakerSuspected: false, issues: [])
            let recovered = manifest ?? RecordingManifest(
                callID: id, appName: "Recording", bundleID: "", category: .unknown, platform: .manual,
                detectedAt: startedAt, recordingStartedAt: startedAt, isManual: true, isTentative: false,
                attendees: [], bookmarks: [], timeZone: TimeZone.current.identifier)
            findings.append(.orphan(manifest: recovered, result: result))
        }
        return findings
    }

    /// The file when it exists with more than a header's worth of bytes.
    private static func audioFile(_ name: String, in directory: URL, minimumBytes: Int = 45) -> URL? {
        let url = directory.appendingPathComponent(name)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size >= minimumBytes else { return nil }
        return url
    }

    private static func sessionResult(in directory: URL) -> RecordingResult? {
        guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(KanPaths.CallFile.session).path)
        else { return nil }
        return try? JSONDecoder.kan.decode(RecordingResult.self, from: data)
    }
}

// MARK: - Recovery and audio retention

extension AppModel {
    /// Saves recordings that never reached the library as calls (status queued) and queues them.
    func recoverOrphanedRecordings() async {
        let calls = environment.callsDirectory
        let library = self.library
        let liveID = active?.callID
        let findings = await Task.detached(priority: .utility) {
            OrphanScanner.scan(callsDirectory: calls, library: library, excluding: liveID)
        }.value
        var recovered: [(id: CallID, startedAt: Date)] = []
        for finding in findings {
            switch finding {
            case .orphan(var manifest, var result):
                for url in [result.meFile, result.themFile].compactMap({ $0 }) where WAV.repairHeader(url) {
                    KanLog.info("Repaired the WAV header of \(url.path)", category: "recovery")
                }
                if let me = result.meFile, let d = WAV.duration(of: me) { result.meSeconds = d }
                if let them = result.themFile, let d = WAV.duration(of: them) { result.themSeconds = d }
                if result.endedAt <= result.startedAt {
                    result.endedAt = result.startedAt.addingTimeInterval(max(result.meSeconds, result.themSeconds))
                }
                if !manifest.isManual && result.duration < settings.minCallSeconds {
                    KanLog.info("Dropping a \(String(format: "%.1f", result.duration)) s orphaned recording \(manifest.callID)",
                                category: "recovery")
                    removeCallDirectory(result.directory)
                    continue
                }
                manifest.isTentative = false
                KanLog.warning("Recovering recording \(manifest.callID) from \(KanDate.iso8601(result.startedAt)) "
                               + "(\(String(format: "%.0f", result.duration)) s)", category: "recovery")
                if await saveRecording(manifest: manifest, result: result, showLabel: false, recovered: true) != nil {
                    recovered.append((manifest.callID, result.startedAt))
                }
            case .stuck(let id, let duration):
                KanLog.warning("Finishing call \(id), which was still marked as recording", category: "recovery")
                let saved = applyUpdate(id, markLabeled: false) { record in
                    record.status = .queued
                    if record.endedAt <= record.startedAt { record.endedAt = record.startedAt.addingTimeInterval(duration) }
                }
                RecordingManifest.remove(in: environment.callDataDirectory(for: id))
                if let saved {
                    transcribeFromKeptAudio(id)
                    recovered.append((id, saved.startedAt))
                }
            case .staleManifest(let directory):
                RecordingManifest.remove(in: directory)
            case .empty(let directory):
                KanLog.info("Removing \(directory.lastPathComponent): a recording that captured no audio", category: "recovery")
                removeCallDirectory(directory)
            }
        }
        guard let first = recovered.min(by: { $0.startedAt < $1.startedAt }) else { return }
        let title = recovered.count == 1
            ? "Recovered a recording from \(KanFormat.shortMoment(first.startedAt, now: environment.now()))"
            : "Recovered \(recovered.count) recordings"
        let buttons: [AppNotice.Button] = recovered.count == 1
            ? [.init(title: "Label", command: .label(first.id), role: .primary), .init(title: "Show", command: .showInLibrary(first.id))]
            : [.init(title: "Open Library", command: .openLibrary, role: .primary)]
        postInfo(title, message: "Kan quit before saving it. It's in the Inbox and being transcribed.", buttons: buttons,
                 seconds: 15)
    }

    /// Calls saved as queued/processing that the queue doesn't know (Kan quit between saving and
    /// queueing): transcribe them from their audio, or mark them failed when it's gone.
    func requeueStrandedCalls() {
        guard let queue else { return }
        for summary in summaries where summary.status == .queued || summary.status == .processing {
            guard queue.status(for: summary.id) == nil else { continue }
            KanLog.warning("Call \(summary.id) was \(summary.status.rawValue) without a transcription job; re-queueing",
                           category: "recovery")
            transcribeFromKeptAudio(summary.id)
        }
    }

    /// Queues a call for transcription from the audio in its call data directory.
    private func transcribeFromKeptAudio(_ id: CallID) {
        guard let queue else { return }
        do {
            try queue.retranscribe(id, languageMode: nil, settings: settings)
        } catch {
            KanLog.error("Can't transcribe \(id): \(Self.logDescription(error))", category: "recovery")
            let message = Self.describe(error)
            applyUpdate(id, markLabeled: false) { record in
                record.status = .failed
                var info = record.processing ?? ProcessingInfo(languageMode: record.languageMode)
                info.error = message
                record.processing = info
            }
        }
    }

    // MARK: Audio retention

    /// Deletes kept audio older than `settings.audioRetentionDays`, with the voice samples taken
    /// from it (starred calls, calls that still need their audio and calls without a transcript are
    /// exempt), now and then periodically.
    func startRetentionSweeps() {
        retentionTask?.cancel()
        retentionTask = nil
        guard let days = settings.audioRetentionDays, days > 0 else { return }
        let interval = environment.retentionSweepInterval
        retentionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sweepAudioRetention()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// One retention pass. Returns the calls whose audio was deleted.
    @discardableResult
    func sweepAudioRetention() async -> [CallID] {
        guard let days = settings.audioRetentionDays, days > 0, !retentionSweepRunning else { return [] }
        retentionSweepRunning = true
        defer { retentionSweepRunning = false }
        let cutoff = environment.now().addingTimeInterval(-Double(days) * 86_400)
        let expired = library.summaries()
            .filter { $0.hasAudio && !$0.starred && $0.status == .ready && $0.endedAt < cutoff }
            .map(\.id)
        guard !expired.isEmpty else { return [] }
        let library = self.library
        let archiver = services.archiver
        let deletedAt = environment.now()
        let deleted = await Task.detached(priority: .utility) { () -> [CallID] in
            var done: [CallID] = []
            for id in expired {
                // Re-check: the call may have been starred since the list was made.
                guard let current = try? library.record(id), !current.starred else { continue }
                let directory = library.callDataDirectory(for: id)
                do {
                    if let archiver {
                        try archiver.deleteAudio(in: directory)
                    } else {
                        for name in [KanPaths.CallFile.meWAV, KanPaths.CallFile.themWAV, KanPaths.CallFile.meM4A, KanPaths.CallFile.themM4A] {
                            let url = directory.appendingPathComponent(name)
                            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                        }
                    }
                    AppModel.deleteVoiceSamples(in: directory, of: id)
                    try library.update(id) { record in
                        record.audio = AudioAssets(meFile: nil, themFile: nil, format: record.audio?.format ?? "m4a",
                                                   sizeBytes: 0, deletedAt: deletedAt)
                    }
                    done.append(id)
                } catch {
                    KanLog.error("Retention: couldn't delete the audio of \(id): \(AppModel.logDescription(error))",
                                 category: "retention")
                }
            }
            return done
        }.value
        KanLog.info("Retention: deleted the audio of \(deleted.count) call(s) older than \(days) days", category: "retention")
        refreshSummaries()
        return deleted
    }

    /// Bytes used by every call's working data (audio, embeddings).
    nonisolated static func diskUsage(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
