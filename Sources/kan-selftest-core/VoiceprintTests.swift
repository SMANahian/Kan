import Foundation
import KanCore
import KanTestKit

func voiceprintTests() -> TestSuite {
    let suite = TestSuite("Voiceprints")

    func store(_ name: String) -> (VoiceprintStore, URL) {
        let url = temporaryDirectory(name).appendingPathComponent("voiceprints.json")
        return (VoiceprintStore(fileURL: url), url)
    }

    suite.test("cosine handles identical, opposite, mismatched, zero and empty vectors") {
        try expectClose(Double(VoiceprintStore.cosine([1, 0, 0], [2, 0, 0])), 1, tolerance: 1e-6)
        try expectClose(Double(VoiceprintStore.cosine([1, 0], [0, 3])), 0, tolerance: 1e-6)
        try expectClose(Double(VoiceprintStore.cosine([1, 1], [-1, -1])), -1, tolerance: 1e-6)
        try expectClose(Double(VoiceprintStore.cosine([3, 4], [4, 3])), 24.0 / 25.0, tolerance: 1e-6)
        try expectEqual(VoiceprintStore.cosine([1, 2, 3], [1, 2]), 0)
        try expectEqual(VoiceprintStore.cosine([0, 0, 0], [1, 2, 3]), 0)
        try expectEqual(VoiceprintStore.cosine([], []), 0)
        try expectEqual(VoiceprintStore.cosine([.nan, 1], [1, 1]), 0)
        try expectEqual(VoiceprintStore.cosine([.infinity, 1], [1, 1]), 0)
        try expectEqual(VoiceprintStore.normalized([0, 0]), nil)
        let unit = try expectNotNil(VoiceprintStore.normalized([3, 4]))
        try expectClose(Double(unit[0]), 0.6, tolerance: 1e-6)
        try expectClose(Double(unit[1]), 0.8, tolerance: 1e-6)
    }

    suite.test("enroll L2-normalizes, matches names case-insensitively and keeps the newest 20 samples") {
        let (voices, _) = store("vp-enroll")
        let id = try voices.enroll(name: "Rahim", embedding: Fixture.vector(0).map { $0 * 7 })
        try expectEqual(try voices.enroll(name: " rahim ", embedding: Fixture.vector(1)), id)
        for i in 2..<30 { try voices.enroll(name: "RAHIM", embedding: Fixture.vector(i)) }
        let people = voices.people()
        try expectEqual(people.count, 1)
        let rahim = try expectNotNil(people.first)
        try expectEqual(rahim.name, "Rahim")
        try expectEqual(rahim.embeddings.count, VoiceprintStore.maxSamplesPerPerson)
        for sample in rahim.embeddings {
            let norm = sample.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            try expectClose(Double(norm), 1, tolerance: 1e-5)
        }
        try expectEqual(rahim.embeddings.last, Fixture.vector(29))                 // newest kept…
        try expectEqual(rahim.embeddings.first, Fixture.vector(10))                // …oldest dropped
        try voices.enroll(name: "Rahim", embedding: Fixture.vector(29))            // a duplicate sample doesn't pile up
        try expectEqual(voices.person(id: id)?.embeddings.count, VoiceprintStore.maxSamplesPerPerson)
        try expectThrows { try voices.enroll(name: "  ", embedding: Fixture.vector(0)) }
        try expectThrows { try voices.enroll(name: "Zero", embedding: [0, 0, 0]) }
        try expectThrows { try voices.enroll(name: "Empty", embedding: []) }
    }

    suite.test("match: best person by max cosine, margin to the runner-up, thresholds") {
        let (voices, _) = store("vp-match")
        let rahim = try voices.enroll(name: "Rahim", embedding: Fixture.vector(0))
        try voices.enroll(name: "Rahim", embedding: Fixture.vector(5))
        let karim = try voices.enroll(name: "Karim", embedding: Fixture.vector(1))

        // Close to one of Rahim's samples: confident.
        let strong = try expectNotNil(voices.match(Fixture.vector(5, cosine: 0.95, toward: 200)))
        try expectEqual(strong.personID, rahim)
        try expectEqual(strong.name, "Rahim")
        try expectClose(Double(strong.score), 0.95, tolerance: 1e-4)
        try expectClose(Double(strong.margin), 0.95, tolerance: 1e-4)              // Karim scores 0
        try expect(strong.isConfident)

        // Exactly between two similar voices: a high score but no margin → only a suggestion.
        let twinA = try voices.enroll(name: "Twin A", embedding: Fixture.vector(10))
        let twinB = try voices.enroll(name: "Twin B", embedding: Fixture.vector(10, cosine: 0.9, toward: 11))
        let between = zip(Fixture.vector(10), Fixture.vector(10, cosine: 0.9, toward: 11)).map { $0 + $1 }
        let ambiguous = try expectNotNil(voices.match(between))
        try expect([twinA, twinB].contains(ambiguous.personID))
        try expect(ambiguous.score > VoiceprintStore.autoAssignThreshold, "\(ambiguous.score)")
        try expect(ambiguous.margin < VoiceprintStore.minimumMargin, "\(ambiguous.margin)")
        try expect(!ambiguous.isConfident)

        // Similar, but below the auto-assign threshold → a suggestion.
        let weak = try expectNotNil(voices.match(Fixture.vector(1, cosine: 0.75, toward: 100)))
        try expectEqual(weak.personID, karim)
        try expect(!weak.isConfident)

        // Below the suggestion threshold, or nonsense input → nil.
        try expectEqual(voices.match(Fixture.vector(1, cosine: 0.6, toward: 100)), nil)
        try expectEqual(voices.match([0, 0, 0]), nil)
        try expectEqual(voices.match([]), nil)
        try expectEqual(voices.match([1, 2, 3]), nil)                              // other dimension
    }

    suite.test("rename (merging duplicates), forget and forgetAll") {
        let (voices, url) = store("vp-forget")
        let a = try voices.enroll(name: "Rahim", embedding: Fixture.vector(0))
        let b = try voices.enroll(name: "Rahim U.", embedding: Fixture.vector(1))
        try voices.rename(personID: b, to: "Rahim Uddin")
        try expectEqual(voices.people().map(\.name), ["Rahim", "Rahim Uddin"])
        try voices.rename(personID: b, to: "rahim")                               // same person after all
        let merged = voices.people()
        try expectEqual(merged.count, 1)
        try expectEqual(merged.first?.id, b)
        try expectEqual(merged.first?.name, "rahim")
        try expectEqual(merged.first?.embeddings.count, 2)
        try expectThrows { try voices.rename(personID: a, to: "Ghost") }          // `a` was merged away
        try expectThrows { try voices.rename(personID: b, to: "") }
        let karim = try voices.enroll(name: "Karim", embedding: Fixture.vector(2))
        try voices.forget(personID: karim)
        try voices.forget(personID: "unknown")                                     // no-op
        try expectEqual(voices.people().map(\.name), ["rahim"])
        try expectEqual(voices.match(Fixture.vector(2)), nil)
        try voices.forgetAll()
        try expectEqual(voices.people().count, 0)
        try expect(!FileManager.default.fileExists(atPath: url.path))
    }

    suite.test("persistence: atomic owner-only file, reloaded by a new instance, corrupt file moved aside") {
        let (voices, url) = store("vp-persist")
        let id = try voices.enroll(name: "রহিম", embedding: Fixture.vector(3))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try expectEqual(permissions, 0o600)
        let reopened = VoiceprintStore(fileURL: url)
        try expectEqual(reopened.people().map(\.id), [id])
        try expectEqual(reopened.match(Fixture.vector(3))?.name, "রহিম")
        try Data("{ broken".utf8).write(to: url)
        let damaged = VoiceprintStore(fileURL: url)
        try expectEqual(damaged.people().count, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        try expect(names.contains { $0.hasPrefix("voiceprints.corrupt-") }, "\(names)")
        try damaged.enroll(name: "Fresh", embedding: Fixture.vector(4))
        try expectEqual(VoiceprintStore(fileURL: url).people().map(\.name), ["Fresh"])
    }

    suite.test("concurrent enrolls and matches are safe") {
        let (voices, url) = store("vp-concurrent")
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            _ = try? voices.enroll(name: "Person \(i % 4)", embedding: Fixture.vector(i))
            _ = voices.match(Fixture.vector(i))
        }
        let people = VoiceprintStore(fileURL: url).people()
        try expectEqual(people.count, 4)
        try expectEqual(people.map(\.embeddings.count).reduce(0, +), 40)
    }

    return suite
}
