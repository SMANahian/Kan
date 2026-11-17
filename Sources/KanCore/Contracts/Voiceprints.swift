import Foundation

// CONTRACT (implemented by the KanCore agent — keep these signatures; additions are fine).
//
// Voiceprints are biometric data about other people: stored only locally in
// KanPaths.voiceprintsFile (never in the library folder), opt-in (settings.rememberVoices),
// with "Forget voice". Embeddings are L2-normalized 256-d WeSpeaker vectors from FluidAudio.
// The per-call speaker samples they are enrolled from (`SpeakerEmbeddingsFile`) exist only while
// rememberVoices is on, and `forgetAll()` deletes them too.

public struct VoicePerson: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Several samples per person (one per call they were named in), capped at ~20, newest kept.
    public var embeddings: [[Float]]
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, embeddings: [[Float]], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embeddings = embeddings
        self.updatedAt = updatedAt
    }
}

public struct VoiceprintMatch: Sendable, Hashable {
    public var personID: String
    public var name: String
    /// Best cosine similarity against the person's samples.
    public var score: Float
    /// Gap to the runner-up person's best score.
    public var margin: Float
    /// score ≥ autoAssignThreshold and margin ≥ minimumMargin.
    public var isConfident: Bool

    public init(personID: String, name: String, score: Float, margin: Float, isConfident: Bool) {
        self.personID = personID
        self.name = name
        self.score = score
        self.margin = margin
        self.isConfident = isConfident
    }
}

public enum VoiceprintError: Error, LocalizedError, Sendable, Equatable {
    case invalidName
    case invalidEmbedding
    case notFound(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "A voice needs a name."
        case .invalidEmbedding: return "The voice sample is empty or invalid."
        case .notFound(let id): return "No remembered voice with id \(id)."
        case .io(let message): return message
        }
    }
}

/// Remembered voices: a JSON file of people with a few L2-normalized speaker embeddings each.
///
/// Thread-safe (one lock; the file is read lazily on first use and written atomically with
/// owner-only permissions). Matching compares a new embedding with every sample of every person:
/// a person's score is their best sample's cosine similarity.
public final class VoiceprintStore: @unchecked Sendable {
    /// Thresholds from the diarization spike (TTS voices: same ≥ 0.90, different ≤ 0.63).
    /// Re-tune on real calls.
    public static let autoAssignThreshold: Float = 0.80
    public static let suggestThreshold: Float = 0.70
    public static let minimumMargin: Float = 0.10
    /// Samples kept per person (the newest).
    public static let maxSamplesPerPerson = 20

    public let fileURL: URL
    /// Where calls keep the voice samples of their speakers (`SpeakerEmbeddingsFile`), which
    /// `forgetAll()` deletes too; nil leaves them alone.
    public let callsDirectory: URL?

    private let lock = NSLock()
    private var cache: [VoicePerson]?

    private struct Contents: Codable {
        var version: Int
        var people: [VoicePerson]
    }

    public init(fileURL: URL = KanPaths.voiceprintsFile, callsDirectory: URL? = KanPaths.calls) {
        self.fileURL = fileURL
        self.callsDirectory = callsDirectory
    }

    /// Everyone remembered, by name.
    public func people() -> [VoicePerson] {
        locked { loadLocked() }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func person(id: String) -> VoicePerson? {
        locked { loadLocked().first { $0.id == id } }
    }

    /// Adds a sample to the person with this name (case-insensitive) or creates them. Returns person id.
    /// A sample identical to one already stored replaces it instead of filling the cap.
    @discardableResult
    public func enroll(name: String, embedding: [Float]) throws -> String {
        guard let name = name.nonEmptyTrimmed?.singleLine else { throw VoiceprintError.invalidName }
        guard let vector = Self.normalized(embedding) else { throw VoiceprintError.invalidEmbedding }
        return try locked {
            var people = loadLocked()
            let id: String
            if let i = people.firstIndex(where: { $0.name.nfc.caseInsensitiveCompare(name) == .orderedSame }) {
                people[i].embeddings.removeAll { Self.cosine($0, vector) > 0.9995 }
                people[i].embeddings.append(vector)
                if people[i].embeddings.count > Self.maxSamplesPerPerson {
                    people[i].embeddings.removeFirst(people[i].embeddings.count - Self.maxSamplesPerPerson)
                }
                people[i].updatedAt = Date()
                id = people[i].id
            } else {
                let person = VoicePerson(name: name, embeddings: [vector])
                people.append(person)
                id = person.id
            }
            try persistLocked(people)
            return id
        }
    }

    /// Best match above `suggestThreshold`, or nil.
    public func match(_ embedding: [Float]) -> VoiceprintMatch? {
        guard let query = Self.normalized(embedding) else { return nil }
        let people = locked { loadLocked() }
        var best: (person: VoicePerson, score: Float)?
        var runnerUp: Float?
        for person in people {
            guard let score = person.embeddings.map({ Self.cosine(query, $0) }).max() else { continue }
            if let current = best {
                if score > current.score {
                    runnerUp = current.score
                    best = (person, score)
                } else if score > (runnerUp ?? -.infinity) {
                    runnerUp = score
                }
            } else {
                best = (person, score)
            }
        }
        guard let best, best.score >= Self.suggestThreshold else { return nil }
        let margin = best.score - max(0, runnerUp ?? 0)
        return VoiceprintMatch(personID: best.person.id, name: best.person.name, score: best.score, margin: margin,
                               isConfident: best.score >= Self.autoAssignThreshold && margin >= Self.minimumMargin)
    }

    /// Renames a person. Renaming to the name of someone else merges the two (their samples move
    /// to this person, up to the cap).
    public func rename(personID: String, to name: String) throws {
        guard let name = name.nonEmptyTrimmed?.singleLine else { throw VoiceprintError.invalidName }
        try locked {
            var people = loadLocked()
            guard let i = people.firstIndex(where: { $0.id == personID }) else { throw VoiceprintError.notFound(personID) }
            var person = people[i]
            person.name = name
            person.updatedAt = Date()
            if let j = people.firstIndex(where: { $0.id != personID && $0.name.nfc.caseInsensitiveCompare(name) == .orderedSame }) {
                person.embeddings = Array((people[j].embeddings + person.embeddings).suffix(Self.maxSamplesPerPerson))
                people[i] = person
                people.remove(at: j)
            } else {
                people[i] = person
            }
            try persistLocked(people)
        }
    }

    /// Forgets one person's voice (no-op when unknown).
    public func forget(personID: String) throws {
        try locked {
            var people = loadLocked()
            guard people.contains(where: { $0.id == personID }) else { return }
            people.removeAll { $0.id == personID }
            try persistLocked(people)
        }
    }

    /// Forgets every voice: deletes the file and every call's speaker samples (embeddings.json
    /// in `callsDirectory`), from which a voice could be remembered again.
    public func forgetAll() throws {
        try locked {
            if FileOps.exists(fileURL) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    throw VoiceprintError.io("Couldn't delete remembered voices: \(error.localizedDescription)")
                }
            }
            cache = []
        }
        if let callsDirectory { SpeakerEmbeddingsFile.deleteAll(in: callsDirectory) }
    }

    /// Cosine similarity; 0 for empty, mismatched, zero or non-finite vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0, na.isFinite, nb.isFinite, dot.isFinite else { return 0 }
        let c = dot / (na.squareRoot() * nb.squareRoot())
        return Float(min(1, max(-1, c)))
    }

    /// The vector scaled to unit length, or nil for empty, zero or non-finite vectors.
    public static func normalized(_ v: [Float]) -> [Float]? {
        guard !v.isEmpty, v.allSatisfy(\.isFinite) else { return nil }
        let norm = v.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { Float(Double($0) / norm) }
    }

    // MARK: - Internals

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func loadLocked() -> [VoicePerson] {
        if let cache { return cache }
        var people: [VoicePerson] = []
        if let data = FileManager.default.contents(atPath: fileURL.path) {
            do {
                people = try JSONDecoder.kan.decode(Contents.self, from: data).people
            } catch {
                let aside = FileOps.moveAside(fileURL)
                KanLog.error("voiceprints.json unreadable (\(error)); moved to \(aside?.lastPathComponent ?? "nowhere")",
                             category: "voiceprints")
            }
        }
        cache = people
        return people
    }

    private func persistLocked(_ people: [VoicePerson]) throws {
        do {
            try FileOps.ensureDirectory(fileURL.deletingLastPathComponent())
            let data = try JSONEncoder.kanCompact.encode(Contents(version: 1, people: people))
            try FileOps.writeAtomically(data, to: fileURL)
            FileOps.restrictToOwner(fileURL)
        } catch {
            throw VoiceprintError.io("Couldn't save remembered voices: \(error.localizedDescription)")
        }
        cache = people
    }
}
