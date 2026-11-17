import Foundation

/// `<call data directory>/embeddings.json`: speaker id → L2-normalized speaker embedding. Used to
/// remember a voice when the user names a speaker.
///
/// These are voice templates of other people (biometric data), so the queue writes the file only
/// while "Remember voices" is on (`KanSettings.rememberVoices`) and removes it otherwise. Delete
/// the files with `deleteAll(in:)` when the user forgets all voices or turns remembering off, and
/// with `delete(in:)` when the user deletes a call's audio (Delete Audio, audio retention). With
/// "Keep call audio" off the queue deletes the audio but keeps this file: the speakers can still be
/// named — and their voices remembered — after the audio is gone.
public enum SpeakerEmbeddingsFile {
    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(KanPaths.CallFile.embeddings)
    }

    /// Removes one call's embeddings (no-op when there are none).
    public static func delete(in directory: URL) throws {
        let target = url(in: directory)
        guard FileOps.exists(target) else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// Removes the embeddings of every call under `callsDirectory` (`KanPaths.calls`). Returns how
    /// many files were deleted; failures are logged.
    @discardableResult
    public static func deleteAll(in callsDirectory: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: callsDirectory.path) else { return 0 }
        var deleted = 0
        for name in names where !name.hasPrefix(".") {
            let directory = callsDirectory.appendingPathComponent(name, isDirectory: true)
            guard FileOps.exists(url(in: directory)) else { continue }
            do {
                try delete(in: directory)
                deleted += 1
            } catch {
                KanLog.error("Couldn't delete the voice samples in \(name): \(error.localizedDescription)", category: "voiceprints")
            }
        }
        if deleted > 0 { KanLog.info("Deleted the voice samples of \(deleted) call(s)", category: "voiceprints") }
        return deleted
    }

    /// How many calls under `callsDirectory` keep voice samples (one stat per call).
    public static func count(in callsDirectory: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: callsDirectory.path) else { return 0 }
        return names.filter { name in
            !name.hasPrefix(".") && FileOps.exists(url(in: callsDirectory.appendingPathComponent(name, isDirectory: true)))
        }.count
    }

    /// The embeddings, or [:] when the file is missing or unreadable.
    public static func read(in directory: URL) -> [String: [Float]] {
        guard let data = FileManager.default.contents(atPath: url(in: directory).path) else { return [:] }
        do {
            return try JSONDecoder.kan.decode([String: [Float]].self, from: data)
        } catch {
            KanLog.warning("Unreadable \(KanPaths.CallFile.embeddings) in \(directory.lastPathComponent): \(error)", category: "queue")
            return [:]
        }
    }

    public static func write(_ embeddings: [String: [Float]], in directory: URL) throws {
        try FileOps.ensureDirectory(directory)
        let data = try JSONEncoder.kanCompact.encode(embeddings)
        let target = url(in: directory)
        try FileOps.writeAtomically(data, to: target)
        FileOps.restrictToOwner(target)
    }
}

public enum ProcessingError: Error, LocalizedError, Sendable, Equatable {
    /// Re-transcription needs the call's kept audio.
    case audioNotAvailable(CallID)

    public var errorDescription: String? {
        switch self {
        case .audioNotAvailable:
            return "No audio was kept for this call, so it can't be transcribed again."
        }
    }
}

/// A queued transcription, as persisted in `queue.json`.
struct ProcessingJob: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case transcribe, retranscribe
        /// The transcript is saved; only archiving (or deleting) the audio is left, because Kan
        /// quit while doing it.
        case finishAudio
    }

    var request: TranscriptionRequest
    var kind: Kind
    var enqueuedAt: Date
}

/// `queue.json`: the running job (first) and the waiting ones, in order, plus the jobs that wait
/// for a model to be installed.
enum ProcessingQueueFile {
    struct Contents: Codable {
        var version: Int
        var jobs: [ProcessingJob]
        /// Failed because a model wasn't installed; retried when models change and at launch.
        var waitingForModels: [ProcessingJob]?
    }

    static func load(_ url: URL) -> Contents {
        let empty = Contents(version: 1, jobs: [], waitingForModels: nil)
        guard let data = FileManager.default.contents(atPath: url.path) else { return empty }
        do {
            return try JSONDecoder.kan.decode(Contents.self, from: data)
        } catch {
            let aside = FileOps.moveAside(url)
            KanLog.error("queue.json unreadable (\(error)); moved to \(aside?.lastPathComponent ?? "nowhere")", category: "queue")
            return empty
        }
    }

    static func save(_ jobs: [ProcessingJob], waitingForModels: [ProcessingJob], to url: URL) throws {
        try FileOps.ensureDirectory(url.deletingLastPathComponent())
        let contents = Contents(version: 1, jobs: jobs, waitingForModels: waitingForModels.isEmpty ? nil : waitingForModels)
        try FileOps.writeAtomically(try JSONEncoder.kanPretty.encode(contents), to: url)
    }
}

/// Applies a transcription to the latest version of a record without touching what the user
/// edits (title, folder, tags, notes, starred, bookmarks, labels).
enum TranscriptMerge {
    /// Voiceprint matches for the remote speakers. One person is confidently assigned to at most one
    /// speaker per call (the best-scoring); other matches for them become suggestions.
    static func voiceprintMatches(output: TranscriptionOutput, store: VoiceprintStore) -> [String: VoiceprintMatch] {
        let remote = Set(output.speakers.filter { !$0.isMe && $0.id != Speaker.meID }.map(\.id))
        var matches: [String: VoiceprintMatch] = [:]
        for (speakerID, embedding) in output.speakerEmbeddings where remote.contains(speakerID) {
            if let match = store.match(embedding) { matches[speakerID] = match }
        }
        let confident = matches.filter { $0.value.isConfident }
        for (_, group) in Dictionary(grouping: confident, by: { $0.value.personID }) where group.count > 1 {
            guard let best = group.max(by: { $0.value.score < $1.value.score }) else { continue }
            for (speakerID, match) in group where speakerID != best.key {
                var weaker = match
                weaker.isConfident = false
                matches[speakerID] = weaker
            }
        }
        return matches
    }

    static func apply(_ output: TranscriptionOutput, to record: inout CallRecord, request: TranscriptionRequest,
                      matches: [String: VoiceprintMatch], attempts: Int, startedAt: Date, finishedAt: Date) {
        let previousSegments = record.segments
        record.segments = output.segments.map { segment in
            var s = segment
            s.text = s.text.nfc
            return s
        }
        record.speakers = mergedSpeakers(new: output.speakers, newSegments: output.segments, old: record.speakers,
                                         oldSegments: previousSegments, userName: request.userName, matches: matches)
        record.languages = output.languages
        record.languageMode = request.languageMode
        record.processing = ProcessingInfo(modelsUsed: output.modelsUsed, languageMode: request.languageMode,
                                           startedAt: startedAt, finishedAt: finishedAt,
                                           processingSeconds: max(0, finishedAt.timeIntervalSince(startedAt)),
                                           error: nil, warnings: output.warnings, kanVersion: KanVersion.current,
                                           attempts: attempts, stats: output.stats.isEmpty ? nil : output.stats)
    }

    /// The new speakers, keeping the names the user gave in the previous transcript: "me" keeps
    /// the user's name for the mic track (else it is called `userName`). Remote ids are numbered
    /// by first appearance on every run, so a remote speaker inherits a name (and remembered-voice
    /// link) only from the previous speaker who talked during the same stretches of the call
    /// (`SpeakerCorrespondence`); a looser correspondence only suggests the name. Voiceprint
    /// matches name (or suggest) the rest.
    static func mergedSpeakers(new: [Speaker], newSegments: [TranscriptSegment], old: [Speaker],
                               oldSegments: [TranscriptSegment], userName: String,
                               matches: [String: VoiceprintMatch]) -> [Speaker] {
        var previous: [String: Speaker] = [:]
        for speaker in old where previous[speaker.id] == nil { previous[speaker.id] = speaker }
        func isMe(_ speaker: Speaker) -> Bool { speaker.isMe || speaker.id == Speaker.meID }
        func userNamed(_ id: String?) -> Speaker? {
            guard let id, let speaker = previous[id], speaker.nameSource == .user, !isMe(speaker) else { return nil }
            return speaker
        }
        let correspondence = SpeakerCorrespondence(old: oldSegments, new: newSegments)
        func inherited(_ speaker: Speaker) -> Speaker? {
            if isMe(speaker) {
                guard let mine = previous[Speaker.meID], mine.nameSource == .user else { return nil }
                return mine
            }
            return userNamed(correspondence.confident[speaker.id])
        }
        let userNames = Set(new.compactMap { inherited($0)?.name.lowercased() })
        return new.map { incoming in
            var speaker = incoming
            if let p = inherited(speaker) {
                speaker.name = p.name
                speaker.nameSource = .user
                speaker.personID = p.personID
                speaker.suggestedName = nil
            } else if isMe(speaker) {
                if let name = userName.nonEmptyTrimmed { speaker.name = name.singleLine }
                speaker.nameSource = .automatic
            } else {
                let match = matches[speaker.id]
                if let match, match.isConfident, !userNames.contains(match.name.lowercased()) {
                    speaker.name = match.name
                    speaker.personID = match.personID
                    speaker.nameSource = .voiceprint
                    speaker.suggestedName = nil
                } else if let hint = userNamed(correspondence.likely[speaker.id]) {
                    speaker.suggestedName = hint.name
                } else if let match {
                    speaker.suggestedName = match.name
                }
            }
            return speaker
        }
    }
}

/// How the remote speakers of a new transcript correspond to those of the previous one, from the
/// time they spent talking during the same stretches of the call. The audio is the same; only the
/// speaker numbering (by first appearance) and the segmentation change between runs.
struct SpeakerCorrespondence {
    /// new id → old id, one-to-one: most of the new speaker's speech overlaps the old speaker's,
    /// and each is at least twice as much the other's counterpart as anyone else's.
    private(set) var confident: [String: String] = [:]
    /// new id → old id: most of the new speaker's speech overlaps the old speaker's, but the voices
    /// were split or merged differently (e.g. another speaker count) — only worth a suggestion.
    private(set) var likely: [String: String] = [:]

    init(old: [TranscriptSegment], new: [TranscriptSegment]) {
        let (overlap, newTalk) = Self.overlaps(old: old, new: new)
        for (newID, row) in overlap {
            // The best old counterpart (ties broken by id, so the result is deterministic).
            guard let best = row.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value > 0,
                  let talk = newTalk[newID], best.value >= 0.5 * talk else { continue }
            let otherOld = row.filter { $0.key != best.key }.values.max() ?? 0
            let otherNew = overlap.filter { $0.key != newID }.compactMap { $0.value[best.key] }.max() ?? 0
            if best.value >= 2 * otherOld && best.value >= 2 * otherNew {
                confident[newID] = best.key
            } else {
                likely[newID] = best.key
            }
        }
    }

    /// Seconds each (new, old) pair of remote speakers talked at the same time, and each new
    /// speaker's talk time (overlapping segments of one speaker counted once). A sweep over
    /// segment boundaries; "me" is not a remote speaker.
    static func overlaps(old: [TranscriptSegment], new: [TranscriptSegment])
        -> (overlap: [String: [String: Double]], newTalk: [String: Double]) {
        struct Event {
            let time: Double
            let delta: Int
            let isNew: Bool
            let speaker: String
        }
        var events: [Event] = []
        for (segments, isNew) in [(old, false), (new, true)] {
            for s in segments where s.speakerID != Speaker.meID && s.start.isFinite && s.end.isFinite && s.end > s.start {
                events.append(Event(time: s.start, delta: 1, isNew: isNew, speaker: s.speakerID))
                events.append(Event(time: s.end, delta: -1, isNew: isNew, speaker: s.speakerID))
            }
        }
        events.sort { $0.time < $1.time }
        var activeOld: [String: Int] = [:], activeNew: [String: Int] = [:]
        var overlap: [String: [String: Double]] = [:]
        var newTalk: [String: Double] = [:]
        var index = 0
        var last: Double?
        while index < events.count {
            let time = events[index].time
            if let last, time > last {
                let span = time - last
                let olds = activeOld.compactMap { $0.value > 0 ? $0.key : nil }
                for newID in activeNew.compactMap({ $0.value > 0 ? $0.key : nil }) {
                    newTalk[newID, default: 0] += span
                    for oldID in olds { overlap[newID, default: [:]][oldID, default: 0] += span }
                }
            }
            while index < events.count && events[index].time == time {
                let event = events[index]
                if event.isNew { activeNew[event.speaker, default: 0] += event.delta } else { activeOld[event.speaker, default: 0] += event.delta }
                index += 1
            }
            last = time
        }
        return (overlap, newTalk)
    }
}
