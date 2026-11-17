import Foundation
import KanAgent
import KanCore
import KanTestKit

func queryTests() -> TestSuite {
    let suite = TestSuite("Queries")
    var cached: AgentFixture?
    func fixture() throws -> AgentFixture {
        if let cached { return cached }
        let f = try AgentFixture("queries")
        cached = f
        return f
    }
    func ids(_ filter: CallFilter, text: String? = nil) throws -> [CallID] {
        LibraryQueries.list(try fixture().library().store, filter: filter, text: text).calls.map(\.id)
    }

    suite.test("list: newest first, with every filter") {
        try expectEqual(try ids(CallFilter()), [IDs.weekly2, IDs.processing, IDs.failed, IDs.advisor, IDs.ammu, IDs.labSync,
                                                IDs.weekly1, IDs.seminar])
        try expectEqual(try ids(CallFilter(folder: "Research")), [IDs.weekly2, IDs.advisor, IDs.weekly1, IDs.seminar],
                        "subfolders included")
        try expectEqual(try ids(CallFilter(folder: "research/thesis")), [IDs.advisor], "case-insensitive")
        try expectEqual(try ids(CallFilter(folder: "Inbox")), [IDs.processing, IDs.failed, IDs.labSync])
        try expectEqual(try ids(CallFilter(folder: "")), [IDs.processing, IDs.failed, IDs.labSync])
        try expectEqual(try ids(CallFilter(tag: "#Weekly")), [IDs.weekly2, IDs.weekly1])
        try expectEqual(try ids(CallFilter(person: "rahman")), [IDs.weekly2, IDs.advisor, IDs.weekly1])
        try expectEqual(try ids(CallFilter(person: "আম্মু")), [IDs.ammu])
        try expectEqual(try ids(CallFilter(app: "zen")), [IDs.labSync])
        try expectEqual(try ids(CallFilter(app: "Google Meet")), [IDs.labSync])
        try expectEqual(try ids(CallFilter(app: "googleMeet")), [IDs.labSync])
        try expectEqual(try ids(CallFilter(starredOnly: true)), [IDs.advisor, IDs.ammu])
        try expectEqual(try ids(CallFilter(status: .processing)), [IDs.processing])
        let dates = DateInput(now: testNow, timeZone: newYork)
        try expectEqual(try ids(CallFilter(since: try dates.parse("2026-11-14", as: .start),
                                           until: try dates.parse("2026-11-15", as: .end))),
                        [IDs.failed, IDs.advisor])
        try expectEqual(try ids(CallFilter(since: try dates.parse("7d", as: .start))),
                        [IDs.weekly2, IDs.processing, IDs.failed, IDs.advisor, IDs.ammu, IDs.labSync],
                        "7 days before Tue 12:00 is Tue 10 Nov 12:00; the lab sync started at 14:00")
    }

    suite.test("list: text query and paging") {
        try expectEqual(try ids(CallFilter(), text: "augmentation"), [IDs.weekly2, IDs.advisor])
        try expectEqual(try ids(CallFilter(), text: "ডেটাসেট"), [IDs.advisor])
        try expectEqual(try ids(CallFilter(folder: "Personal"), text: "খেয়েছো"), [IDs.ammu])
        let store = try fixture().library().store
        let first = LibraryQueries.list(store, filter: CallFilter(), offset: 0, limit: 3)
        try expectEqual(first.calls.count, 3)
        try expectEqual(first.total, 8)
        try expectEqual(first.nextOffset, 3)
        let last = LibraryQueries.list(store, filter: CallFilter(), offset: 6, limit: 3)
        try expectEqual(last.calls.map(\.id), [IDs.weekly1, IDs.seminar])
        try expectEqual(last.nextOffset, nil)
        let beyond = LibraryQueries.list(store, filter: CallFilter(), offset: 50, limit: 3)
        try expect(beyond.calls.isEmpty && beyond.total == 8 && beyond.nextOffset == nil)
        let huge = LibraryQueries.list(store, filter: CallFilter(), offset: 2, limit: Int.max)
        try expectEqual(huge.calls.count, 6, "huge limits don't overflow")
        let hugeOffset = LibraryQueries.list(store, filter: CallFilter(), offset: Int.max, limit: Int.max)
        try expect(hugeOffset.calls.isEmpty)
        let seminar = try store.record(IDs.seminar)
        try expectEqual(LibraryQueries.transcript(seminar, from: nil, to: nil, offset: 999, limit: Int.max).segments.count, 1)
    }

    suite.test("search: passages per call, limits and reading order") {
        let store = try fixture().library().store
        let results = LibraryQueries.search(store, text: "augmentation", filter: CallFilter(), limit: 20, perCall: 5)
        try expectEqual(results.matchedCalls, 2)
        // The advisor call: title first, then bookmark, then transcript by time.
        let advisor = results.passages.filter { $0.hit.callID == IDs.advisor }.map(\.hit)
        try expectEqual(advisor.map(\.field), [.title, .bookmark, .transcript, .transcript])
        try expectEqual(advisor.compactMap(\.time), [751, 5, 751])
        try expect(!results.truncated)
        let capped = LibraryQueries.search(store, text: "augmentation", filter: CallFilter(), limit: 20, perCall: 1)
        try expectEqual(capped.passages.count, 2)
        try expect(capped.truncated)
        try expectEqual(capped.totalHits, results.totalHits)
        let limited = LibraryQueries.search(store, text: "segment", filter: CallFilter(), limit: 7, perCall: 50)
        try expectEqual(limited.passages.count, 7)
        try expectEqual(limited.passages.compactMap(\.hit.time), limited.passages.compactMap(\.hit.time).sorted())
        let echo = LibraryQueries.search(store, text: "\"good baseline\"", filter: CallFilter(), limit: 0, perCall: 50)
        try expect(echo.passages.isEmpty, "echo suspects are not searched")
    }

    suite.test("transcript pages: offset, limit, time range, echo suspects hidden") {
        let store = try fixture().library().store
        let seminar = try store.record(IDs.seminar)
        let page = LibraryQueries.transcript(seminar, from: nil, to: nil, offset: 0, limit: 400)
        try expectEqual(page.segments.count, 400)
        try expectEqual(page.total, 1000)
        try expectEqual(page.nextOffset, 400)
        let tail = LibraryQueries.transcript(seminar, from: nil, to: nil, offset: 800, limit: 400)
        try expectEqual(tail.segments.count, 200)
        try expectEqual(tail.nextOffset, nil)
        // [30, 60): segments start every 3 s and last 2 s; 27–29 ends before 30, 60–62 starts at the end.
        let range = LibraryQueries.transcript(seminar, from: 30, to: 60, offset: 0, limit: 0)
        try expectEqual(range.segments.map(\.id), Array(10..<20))
        try expectEqual(range.callSegments, 1000)
        let advisor = try store.record(IDs.advisor)
        let visible = LibraryQueries.visibleSegments(advisor)
        try expectEqual(visible.map(\.id), [0, 1, 2, 3, 4, 5, 7], "the echo suspect is hidden")
        let overlapping = LibraryQueries.transcript(advisor, from: 12, to: 22, offset: 0, limit: 0)
        try expectEqual(overlapping.segments.map(\.id), [1, 2], "segments overlapping the range")
    }

    suite.test("speaker turns merge like the .md files") {
        let s = [AgentFixture.segment(0, 0, 2, "me", "one"), AgentFixture.segment(1, 3, 5, "me", "two"),
                 AgentFixture.segment(2, 8, 9, "me", "three"), AgentFixture.segment(3, 9.5, 10, "s1", "four"),
                 AgentFixture.segment(4, 10.5, 99, "s1", "five"), AgentFixture.segment(5, 100, 101, "s1", "six")]
        let turns = LibraryQueries.turns(s)
        try expectEqual(turns.map(\.text), ["one two", "three", "four five", "six"])
        try expectEqual(turns.map(\.start), [0, 8, 9.5, 100], "a turn stops growing at 90 s")
    }

    suite.test("folders with nested totals, stats, people") {
        let store = try fixture().library().store
        let rows = LibraryQueries.folderRows(store)
        try expectEqual(rows.map(\.name), ["", "Personal", "Research", "Research/Seminars", "Research/Thesis"])
        try expectEqual(rows.map(\.count), [3, 1, 2, 1, 1])
        try expectEqual(rows.map(\.total), [3, 1, 4, 1, 1])
        try expectEqual(rows.map(\.depth), [0, 0, 0, 1, 1])
        let stats = LibraryQueries.stats(store)
        try expectEqual(stats.calls, 8)
        try expectEqual(stats.byStatus[.ready], 6)
        try expectEqual(stats.starred, 2)
        try expectEqual(stats.first?.id, IDs.seminar)
        try expectEqual(stats.last?.id, IDs.weekly2)
        try expectEqual(LibraryQueries.people(try fixture().summary(IDs.labSync)), ["Nahian", "Rahim"], "placeholders left out")
    }
    return suite
}
