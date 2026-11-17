import Foundation
import KanAgent
import KanCore
import KanTestKit

/// Timings on a library larger than the fixture. Bounds are generous (debug builds, busy
/// machines): they catch accidental quadratic work, not small slowdowns.
func performanceTests() -> TestSuite {
    let suite = TestSuite("Performance")

    suite.test("300 calls × 200 segments: load, list, search, page, change check") {
        let base = temporaryDirectory("agent-perf")
        let root = base.appendingPathComponent("Library", isDirectory: true)
        let calls = 300, segmentsPerCall = 200
        let english = ["we should try data augmentation on the corpus", "the attention model overfits quickly",
                       "let's compare the baseline with the new tokenizer", "I will send the paper draft tomorrow"]
        let bangla = ["আমি ভাবছিলাম ডেটাসেট আরও বড় করা দরকার", "মডেলটা এখনো ঠিকমতো converge করছে না",
                      "পরের সপ্তাহে আবার আলোচনা করি", "ভাষার মডেল আলাদা করে train করা যায়"]
        let start = KanDate.parse("2026-01-05T10:00:00-05:00") ?? testNow
        for c in 0..<calls {
            let folder = ["Research", "Research/Thesis", "Lab", ""][c % 4]
            let directory = root.appendingPathComponent(folder.isEmpty ? "Inbox" : folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let started = start.addingTimeInterval(Double(c) * 86_400 / 3)
            var segments: [TranscriptSegment] = []
            for s in 0..<segmentsPerCall {
                let isBangla = s % 3 == 0
                let text = (isBangla ? bangla[(s + c) % 4] : english[(s + c) % 4]) + " (\(c)-\(s))"
                segments.append(AgentFixture.segment(s, Double(s) * 6, Double(s) * 6 + 5, s % 2 == 0 ? "me" : "s1", text,
                                                     isBangla ? "bn" : "en"))
            }
            let record = CallRecord(
                id: CallID.generate(date: started), title: "Call \(c) about topic \(c % 17)", folder: folder,
                tags: ["t\(c % 5)"], startedAt: started, endedAt: started.addingTimeInterval(1200),
                timeZone: "America/New_York", source: CallSource(appName: "Zoom", platform: .zoom), status: .ready,
                languages: ["en", "bn"], speakers: [AgentFixture.me(), AgentFixture.remote("s1", "Person \(c % 11)")],
                segments: segments)
            try TranscriptRenderer.json(record).write(to: directory.appendingPathComponent("call-\(c).json"))
        }

        func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
            let t0 = Date()
            let value = try body()
            return (value, Date().timeIntervalSince(t0) * 1000)
        }
        let (library, loadMS) = time {
            AgentLibrary.open(libraryArgument: root.path, environment: [:], currentDirectory: base,
                              settingsFile: base.appendingPathComponent("settings.json"))
        }
        try expectEqual(library.store.summaries().count, calls)
        let h = MCPHarness(library, reloadInterval: 0)
        _ = try h.initialize()

        let (list, listMS) = try time { try h.structured("list_calls", ["limit": 20]) }
        try expectEqual(try list.int("total"), calls)
        let (english1, searchMS) = try time { try h.structured("search_transcripts", ["query": "augmentation corpus"]) }
        try expectEqual(try english1.int("matched_calls"), calls)
        let (bangla1, banglaMS) = try time { try h.structured("search_transcripts", ["query": "ডেটাসেট", "folder": "Research"]) }
        try expect(try bangla1.int("matched_calls") > 0)
        let id = try list.array("calls")[0].string("id")
        let (page, pageMS) = try time { try h.structured("get_transcript", ["call_id": .string(id)]) }
        try expectEqual(page["returned"], 200)
        let (_, checkMS) = time { library.reloadIfChanged(minimumInterval: 0) }
        print(String(format: "    (load %.0f ms · list %.0f ms · search %.0f ms · Bangla search %.0f ms · transcript page %.0f ms · change check %.1f ms)",
                     loadMS, listMS, searchMS, banglaMS, pageMS, checkMS))
        try expect(loadMS < 15_000, "load took \(loadMS) ms")
        for (name, ms) in [("list", listMS), ("search", searchMS), ("Bangla search", banglaMS), ("page", pageMS)] {
            try expect(ms < 3_000, "\(name) took \(ms) ms")
        }
        try expect(checkMS < 1_000, "the change check took \(checkMS) ms")
    }
    return suite
}
