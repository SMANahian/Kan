import Foundation
import KanCore
import KanTestKit

private struct Corpus {
    let lib: TestLibrary
    let advisor: CallRecord
    let lab: CallRecord
    let coffee: CallRecord
    let old: CallRecord

    var store: LibraryStore { lib.store }

    func search(_ text: String, _ configure: (inout SearchQuery) -> Void = { _ in }) -> [SearchHit] {
        var query = SearchQuery(text: text)
        configure(&query)
        return store.search(query)
    }

    func calls(_ text: String, _ configure: (inout SearchQuery) -> Void = { _ in }) -> Set<CallID> {
        Set(search(text, configure).map(\.callID))
    }
}

private func makeCorpus(_ name: String) throws -> Corpus {
    let lib = TestLibrary(name)
    let advisor = Fixture.record(
        title: "Advisor meeting – augmentation idea", folder: "Research/Thesis", start: "2026-11-14T10:00:12-05:00",
        tags: ["research", "thesis"], notes: "Discuss data augmentation for low-resource Bangla ASR",
        segments: [
            Fixture.segment(0, 5, 9, "me", "So I was thinking about data augmentation."),
            Fixture.segment(1, 21, 30, "s1", "আমরা বাংলা ভাষার জন্য একটি স্পিচ রিকগনিশন মডেল তৈরি করব।", language: "bn"),
            Fixture.segment(2, 31, 33, "me", "জনি কোথায়?", language: "bn"),
            Fixture.segment(3, 40, 44, "me", "echo of the dataset", flags: [.echoSuspect]),
        ],
        bookmarks: [Bookmark(time: 21, note: "pseudo-labeling idea")], languages: ["en", "bn"])
    let lab = Fixture.record(
        title: "Lab sync", folder: "Research", start: "2026-11-10T09:00:00-05:00", app: "Telegram", platform: .telegram,
        starred: true,
        segments: [Fixture.segment(0, 1, 4, "s1", "এটা আমাদের জন্য ভালো", language: "bn"),
                   Fixture.segment(1, 5, 8, "me", "Let's try the augmentation pipeline next week")])
    let coffee = Fixture.record(
        title: "Coffee chat", start: "2026-11-12T16:00:00-05:00", app: "Zen", platform: .googleMeet, tags: ["social"],
        speakers: Fixture.speakers(others: ["Rahim Uddin"]),
        segments: [Fixture.segment(0, 2, 6, "s1", "We talked about the new dataset and ÉCOLE normale"),
                   Fixture.segment(1, 7, 9, "me", "Строка на русском")])
    let old = Fixture.record(title: "Augmentation kickoff", folder: "Archive", start: "2025-03-01T10:00:00-05:00")
    for r in [advisor, lab, coffee, old] { try lib.store.save(r) }
    return Corpus(lib: lib, advisor: advisor, lab: lab, coffee: coffee, old: old)
}

private func isContiguous<T: Equatable>(_ needle: [T], in haystack: [T]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return needle.isEmpty }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
        return true
    }
    return false
}

func searchTests() -> TestSuite {
    let suite = TestSuite("Search")

    suite.test("English terms are case-insensitive and ANDed across the call") {
        let c = try makeCorpus("search-english")
        try expectEqual(c.calls("AUGMENTATION"), [c.advisor.id, c.lab.id, c.old.id])
        let advisorFields = c.search("augmentation").filter { $0.callID == c.advisor.id }.map(\.field)
        try expectEqual(advisorFields, [.title, .notes, .transcript])
        try expectEqual(c.calls("augmentation bangla"), [c.advisor.id])           // "bangla" only in its notes
        try expectEqual(c.calls("augmentation dataset"), [])                      // never both in one call
        try expectEqual(c.calls("zzz"), [])
        try expectEqual(c.calls("echo"), [])                                      // echo suspects aren't searched
    }

    suite.test("Bangla: জনি doesn't match জন্য; ভাষা and ভাষ match inside ভাষার") {
        let c = try makeCorpus("search-bangla")
        let joni = c.search("জনি")
        try expectEqual(joni.map(\.callID), [c.advisor.id])
        try expectEqual(joni.map(\.segmentID), [2])
        let jonno = c.search("জন্য")
        try expectEqual(Set(jonno.map(\.callID)), [c.advisor.id, c.lab.id])
        try expectEqual(jonno.filter { $0.callID == c.advisor.id }.map(\.segmentID), [1])
        try expectEqual(c.search("ভাষা").map(\.segmentID), [1])
        try expectEqual(c.search("ভাষ").map(\.segmentID), [1])                   // prefix inside a cluster
        try expectEqual(c.calls("জন"), [c.advisor.id, c.lab.id])                  // a plain prefix matches both
        try expectEqual(c.search("জন").filter { $0.callID == c.advisor.id }.compactMap(\.segmentID), [1, 2])
        try expectEqual(c.calls("মডেল স্পিচ"), [c.advisor.id])
    }

    suite.test("NFC and NFD forms find each other") {
        let c = try makeCorpus("search-nfc")
        let nfd = "কোথায়".decomposedStringWithCanonicalMapping
        try expectEqual(c.search(nfd).map(\.segmentID), [2])
        let decomposed = Fixture.record(title: "NFD call", segments: [Fixture.segment(0, 0, 2, "s1", "বড় কোথায় যাবে".decomposedStringWithCanonicalMapping)])
        try c.store.save(decomposed)
        try expectEqual(c.calls("বড়".precomposedStringWithCanonicalMapping), [decomposed.id])
        try expectEqual(c.calls("যাবে"), [decomposed.id])
    }

    suite.test("quoted phrases match exactly, including typographic quotes") {
        let c = try makeCorpus("search-phrases")
        try expectEqual(c.calls("\"data augmentation\""), [c.advisor.id])
        try expectEqual(c.calls("\"augmentation data\""), [])
        try expectEqual(c.calls("“data augmentation”"), [c.advisor.id])
        try expectEqual(c.calls("\"augmentation pipeline\" week"), [c.lab.id])
        try expectEqual(c.search("\"data   augmentation\"").first?.terms, ["data augmentation"])
        try expectEqual(c.calls("\"unterminated phrase"), [])
    }

    suite.test("filters: folder (with subfolders), tag, person, app, dates, starred, limit") {
        let c = try makeCorpus("search-filters")
        try expectEqual(c.calls("") { $0.folder = "Research" }, [c.advisor.id, c.lab.id])
        try expectEqual(c.calls("") { $0.folder = "research/thesis" }, [c.advisor.id])
        try expectEqual(c.calls("") { $0.folder = "" }, [c.coffee.id])
        try expectEqual(c.calls("") { $0.folder = "Inbox" }, [c.coffee.id])
        try expectEqual(c.calls("") { $0.tag = "#Research" }, [c.advisor.id])
        try expectEqual(c.calls("") { $0.tag = "social" }, [c.coffee.id])
        try expectEqual(c.calls("") { $0.person = "rahim" }, [c.coffee.id])
        try expectEqual(c.calls("") { $0.person = "নাহি" }, [])
        try expectEqual(c.calls("") { $0.person = "nahian" }, [c.advisor.id, c.lab.id, c.coffee.id, c.old.id])
        try expectEqual(c.calls("") { $0.person = "Prof. Rahman" }, [c.advisor.id, c.lab.id, c.old.id])
        try expectEqual(c.calls("") { $0.appName = "telegram" }, [c.lab.id])
        try expectEqual(c.calls("") { $0.appName = "Google Meet" }, [c.coffee.id])
        try expectEqual(c.calls("") { $0.appName = "zen" }, [c.coffee.id])
        try expectEqual(c.calls("") { $0.from = Fixture.date("2026-11-11T00:00:00-05:00") }, [c.advisor.id, c.coffee.id])
        try expectEqual(c.calls("") { $0.to = Fixture.date("2026-11-11T00:00:00-05:00") }, [c.lab.id, c.old.id])
        try expectEqual(c.calls("") { $0.starredOnly = true }, [c.lab.id])
        try expectEqual(c.calls("augmentation") { $0.folder = "Research" }, [c.advisor.id, c.lab.id])
        try expectEqual(c.search("augmentation") { $0.limit = 2 }.count, 2)
        try expectEqual(c.search("augmentation") { $0.limit = 0 }.count, c.search("augmentation").count)
    }

    suite.test("empty text lists the calls passing the filters as title hits") {
        let c = try makeCorpus("search-list")
        let list = c.store.search(SearchQuery(folder: "Research"))
        try expectEqual(list.map(\.callID), [c.advisor.id, c.lab.id])
        try expect(list.allSatisfy { $0.field == .title && $0.terms.isEmpty })
        try expectEqual(list.first?.snippet, "Discuss data augmentation for low-resource Bangla ASR")
        try expectEqual(c.store.search(SearchQuery()).map(\.callID), [c.advisor.id, c.coffee.id, c.lab.id, c.old.id])
        try expectEqual(c.store.search(SearchQuery(text: "   ", limit: 1)).count, 1)
    }

    suite.test("hits carry the segment id, time, speaker and field") {
        let c = try makeCorpus("search-hits")
        let hit = try expectNotNil(c.search("স্পিচ").first)
        try expectEqual(hit.field, .transcript)
        try expectEqual(hit.segmentID, 1)
        try expectEqual(hit.time, 21)
        try expectEqual(hit.speakerName, "Prof. Rahman")
        try expectEqual(hit.terms, ["স্পিচ"])
        try expectEqual(hit.title, c.advisor.title)
        try expect(hit.snippet.contains("স্পিচ রিকগনিশন"))
        let bookmark = try expectNotNil(c.search("pseudo").first)
        try expectEqual(bookmark.field, .bookmark)
        try expectEqual(bookmark.time, 21)
        try expectEqual(bookmark.snippet, "pseudo-labeling idea")
        try expectEqual(c.search("thesis").map(\.field), [.tags])
        try expectEqual(c.search("thesis").first?.snippet, "research, thesis")
        let ids = c.search("augmentation").map(\.id)
        try expectEqual(Set(ids).count, ids.count)                                // hit ids are unique
        try c.store.update(c.advisor.id) { r in
            r.bookmarks = [Bookmark(time: 50, note: "second idea: labels"), Bookmark(time: 10, note: "first idea"),
                           Bookmark(time: 90, note: "unrelated")]
        }
        let bookmarkHits = c.search("idea").filter { $0.field == .bookmark }
        try expectEqual(bookmarkHits.count, 1)                                    // one bookmark hit per call
        try expectEqual(bookmarkHits.first?.time, 10)
        try expectEqual(c.search("idea labels").filter { $0.field == .bookmark }.first?.time, 50)
    }

    suite.test("snippets are ~200 characters around the match and never split a grapheme cluster") {
        let lib = TestLibrary("search-snippet")
        let filler = String(repeating: "ক্ষমতা স্পিচ রিকগনিশন ", count: 20)
        let middle = filler + "TARGETWORD " + filler
        let start = "TARGETWORD " + filler
        let short = "a short স্পিচ line"
        let record = Fixture.record(title: "Snippets", segments: [
            Fixture.segment(0, 0, 30, "s1", middle, language: "bn"),
            Fixture.segment(1, 31, 60, "s1", start, language: "bn"),
            Fixture.segment(2, 61, 62, "me", short),
        ])
        try lib.store.save(record)
        let hits = lib.store.search(SearchQuery(text: "targetword"))
        try expectEqual(hits.count, 2)
        for hit in hits {
            let original = Array((hit.segmentID == 0 ? middle : start).nfc.singleLineForTest)
            let snippet = hit.snippet
            try expect(snippet.count <= 202, "\(snippet.count) characters")
            try expect(snippet.count >= 150, "\(snippet.count) characters")
            try expect(snippet.contains("TARGETWORD"))
            var core = Substring(snippet)
            if core.hasPrefix("…") { core = core.dropFirst() }
            if core.hasSuffix("…") { core = core.dropLast() }
            try expect(isContiguous(Array(core), in: original), "snippet is not whole clusters of the text: \(snippet)")
            try expect(core.unicodeScalars.first.map { !$0.properties.isGraphemeExtend } ?? false)
        }
        try expect(hits.first { $0.segmentID == 0 }?.snippet.hasPrefix("…") ?? false)
        try expect(hits.first { $0.segmentID == 0 }?.snippet.hasSuffix("…") ?? false)
        try expect(hits.first { $0.segmentID == 1 }?.snippet.hasPrefix("TARGETWORD") ?? false)
        try expectEqual(lib.store.search(SearchQuery(text: "line")).first?.snippet, short)
    }

    suite.test("ranking: title > tags > notes > bookmark > transcript, more terms, then newer") {
        let lib = TestLibrary("search-rank")
        let transcript = Fixture.record(title: "Weekly", start: "2026-11-15T10:00:00-05:00",
                                        segments: [Fixture.segment(0, 1, 2, "s1", "we discussed quantum things")])
        let titleOld = Fixture.record(title: "Quantum review", start: "2026-01-01T10:00:00-05:00")
        let titleNew = Fixture.record(title: "Quantum again", start: "2026-02-01T10:00:00-05:00")
        let tags = Fixture.record(title: "T", start: "2026-11-10T10:00:00-05:00", tags: ["quantum"])
        let notes = Fixture.record(title: "N", start: "2026-11-11T10:00:00-05:00", notes: "quantum notes")
        let bookmark = Fixture.record(title: "B", start: "2026-11-12T10:00:00-05:00",
                                      bookmarks: [Bookmark(time: 3, note: "quantum moment")])
        let mixed = Fixture.record(title: "Quantum stuff", start: "2026-11-13T10:00:00-05:00", notes: "review later")
        for r in [transcript, titleOld, titleNew, tags, notes, bookmark, mixed] { try lib.store.save(r) }

        let hits = lib.store.search(SearchQuery(text: "quantum"))
        try expectEqual(hits.map(\.callID), [mixed.id, titleNew.id, titleOld.id, tags.id, notes.id, bookmark.id, transcript.id])
        try expectEqual(hits.map(\.field), [.title, .title, .title, .tags, .notes, .bookmark, .transcript])
        try expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })

        let two = lib.store.search(SearchQuery(text: "quantum review"))
        try expectEqual(two.map(\.callID), [titleOld.id, mixed.id, mixed.id])
        try expectEqual(two.map(\.field), [.title, .title, .notes])
        try expectEqual(two.first?.terms, ["quantum", "review"])
    }

    suite.test("searchCalls groups hits by call, best call first") {
        let c = try makeCorpus("search-grouped")
        let results = c.store.searchCalls(SearchQuery(text: "augmentation"), hitsPerCall: 2)
        try expectEqual(results.map(\.id), [c.advisor.id, c.old.id, c.lab.id])
        try expectEqual(results.first?.hits.count, 2)
        try expectEqual(results.first?.totalHits, 3)
        try expectEqual(results.first?.hits.first?.field, .title)
        try expectEqual(results.first?.summary.title, c.advisor.title)
        try expectEqual(c.store.searchCalls(SearchQuery(text: "augmentation", limit: 1)).count, 1)
        try expectEqual(c.store.searchCalls(SearchQuery(tag: "social")).map(\.id), [c.coffee.id])
    }

    suite.test("search reflects updates and deletes") {
        let c = try makeCorpus("search-updates")
        try expectEqual(c.calls("entanglement"), [])
        try c.store.update(c.coffee.id) { $0.notes = "Quantum entanglement, maybe" }
        try expectEqual(c.search("entanglement").map(\.field), [.notes])
        try c.store.delete(c.coffee.id, deleteAudio: false)
        try expectEqual(c.calls("entanglement"), [])
        try expectEqual(c.calls("dataset"), [])
    }

    suite.test("case folding covers accented Latin and Cyrillic") {
        let c = try makeCorpus("search-folding")
        try expectEqual(c.calls("école"), [c.coffee.id])
        try expectEqual(c.calls("строка"), [c.coffee.id])
        try expectEqual(c.calls("СТРОКА"), [c.coffee.id])
        try expectEqual(c.calls("ecole"), [])                                    // no diacritic folding
    }

    suite.test("search stays fast on a large library") {
        let lib = TestLibrary("search-perf")
        let inbox = lib.url("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let words = ["আমরা", "বাংলা", "ভাষার", "জন্য", "মডেল", "data", "augmentation", "pipeline", "speech", "model",
                     "ডেটাসেট", "পেপার", "experiment", "result", "জনি", "কোথায়", "training", "loss"]
        var rng = SystemRandomNumberGenerator()
        let calls = 200, segmentsPerCall = 150
        for i in 0..<calls {
            var segments: [TranscriptSegment] = []
            for j in 0..<segmentsPerCall {
                let text = (0..<12).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
                segments.append(Fixture.segment(j, Double(j * 5), Double(j * 5 + 4), j % 2 == 0 ? "me" : "s1", text))
            }
            let record = Fixture.record(title: "Call \(i)", start: "2026-0\(1 + i % 9)-1\(i % 10)T10:00:00-05:00",
                                        segments: segments)
            try JSONEncoder.kanPretty.encode(record).write(to: inbox.appendingPathComponent("call-\(i).json"))
        }
        let t0 = Date()
        let store = lib.reopened()
        try expectEqual(try store.reload().count, calls)
        let loadTime = Date().timeIntervalSince(t0)
        let queries = ["augmentation", "জন্য মডেল", "\"speech model\"", "zzz", "experiment result loss"]
        func measure(limit: Int) -> (seconds: Double, hits: Int) {
            let start = Date()
            var hits = 0
            for q in queries { hits += store.search(SearchQuery(text: q, limit: limit)).count }
            return (Date().timeIntervalSince(start) / Double(queries.count), hits)
        }
        let limited = measure(limit: 200)
        let unlimited = measure(limit: 0)
        let grouped = Date()
        _ = store.searchCalls(SearchQuery(text: "augmentation"))
        let groupedTime = Date().timeIntervalSince(grouped)
        print(String(format: "    %d calls × %d segments: load %.2f s; search %.0f ms/query (limit 200), %.0f ms/query (all %d hits), searchCalls %.0f ms",
                     calls, segmentsPerCall, loadTime, limited.seconds * 1000, unlimited.seconds * 1000, unlimited.hits,
                     groupedTime * 1000))
        try expect(limited.seconds < 1.0, "search took \(limited.seconds) s")
        try expect(unlimited.seconds < 3.0, "unlimited search took \(unlimited.seconds) s")
    }

    return suite
}
