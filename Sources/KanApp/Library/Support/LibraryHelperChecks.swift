#if DEBUG
import Foundation
import KanCore

/// Self-checks of the library window's pure helpers (KanApp has no test target: XCTest doesn't run
/// with the Command Line Tools). Debug builds run them once when the library window first opens and
/// log failures; a test runner can call `checks` and report each one.
enum LibraryHelperChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var checks: [(name: String, run: () throws -> Void)] {
        [
            ("text match: Bangla scalars, no diacritic folding", textMatchBangla),
            ("text match: case, merging, UTF-16 ranges", textMatchRanges),
            ("text match: query terms and phrases", textMatchTerms),
            ("day grouping", dayGrouping),
            ("folder tree", folderTree),
            ("folder path helpers", folderPaths),
            ("list filters", listFilters),
            ("tag parsing and people", tagsAndPeople),
            ("apps section", appsSection),
            ("turn merging", turnMerging),
            ("transcript plan: ranges", planRanges),
            ("transcript plan: time lookups and find", planLookups),
            ("speaker stats", speakerStats),
            ("status badges and banners", statusInfo),
            ("formatting", formatting),
        ]
    }

    /// Runs every check; returns one "name: failure" line per failed check.
    static func run() -> [String] {
        checks.compactMap { check in
            do {
                try check.run()
                return nil
            } catch {
                return "\(check.name): \(error)"
            }
        }
    }

    /// Debug builds: run once per process and log the outcome.
    @MainActor static func runOnceAndLog() {
        guard !hasRun else { return }
        hasRun = true
        let failures = run()
        if failures.isEmpty {
            KanLog.debug("Library helper self-checks passed (\(checks.count))", category: "library-ui")
        } else {
            for failure in failures { KanLog.error("Library helper self-check failed — \(failure)", category: "library-ui") }
        }
    }

    @MainActor private static var hasRun = false

    // MARK: Assertions

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) throws {
        if !condition { throw Failure(description: "line \(line): \(message())") }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                                                  line: Int = #line) throws {
        if actual != expected {
            throw Failure(description: "line \(line): expected \(expected), got \(actual) \(message)")
        }
    }

    private static func texts(_ ranges: [Range<String.Index>], in text: String) -> [String] {
        ranges.map { String(text[$0]) }
    }

    // MARK: Text matching

    private static func textMatchBangla() throws {
        let text = "বাংলা ভাষার গবেষণা"
        try expectEqual(texts(LibraryTextMatch.ranges(of: ["ভাষা"], in: text), in: text), ["ভাষা"])
        // A term ending inside a character still matches; the highlight covers the whole character.
        try expectEqual(texts(LibraryTextMatch.ranges(of: ["ভাষ"], in: text), in: text), ["ভাষা"])
        // Vowel signs and the virama are letters, not diacritics.
        try expect(LibraryTextMatch.ranges(of: ["জনি"], in: "এটা জন্য").isEmpty, "জনি must not match জন্য")
        try expectEqual(texts(LibraryTextMatch.ranges(of: ["জন্য"], in: "এটা জন্য"), in: "এটা জন্য"), ["জন্য"])
        // য় (U+09DF) is a composition exclusion: its NFC form is য + nukta, whichever way it was typed.
        let decomposed = "\u{09AF}\u{09BC}"
        try expectEqual(LibraryTextMatch.ranges(of: ["\u{09DF}"], in: "আ" + decomposed).count, 1)
    }

    private static func textMatchRanges() throws {
        let call = "Zoom call about ZOOM"
        try expectEqual(texts(LibraryTextMatch.ranges(of: ["zoom"], in: call), in: call), ["Zoom", "ZOOM"])
        try expectEqual(LibraryTextMatch.ranges(of: ["a"], in: "banana").count, 3)
        // Overlapping matches of different terms become one highlight.
        try expectEqual(texts(LibraryTextMatch.ranges(of: ["research", "search"], in: "my research"), in: "my research"),
                        ["research"])
        try expect(LibraryTextMatch.ranges(of: [], in: "text").isEmpty, "no terms, no ranges")
        try expect(LibraryTextMatch.ranges(of: ["  "], in: "text").isEmpty, "blank term")
        try expect(LibraryTextMatch.ranges(of: ["long term"], in: "long").isEmpty, "term longer than text")
        // UTF-16 ranges for AppKit: the emoji with skin tone is 4 UTF-16 units.
        let greeting = "👋🏽 hello বাংলা"
        try expectEqual(LibraryTextMatch.nsRanges(of: ["hello"], in: greeting), [NSRange(location: 5, length: 5)])
        let bangla = LibraryTextMatch.nsRanges(of: ["বাংলা"], in: greeting)
        try expectEqual(bangla.count, 1)
        try expectEqual((greeting as NSString).substring(with: bangla[0]), "বাংলা")
        try expect(LibraryTextMatch.containsAny(of: ["HELLO", "nothing"], in: greeting), "containsAny")
    }

    private static func textMatchTerms() throws {
        try expectEqual(LibraryTextMatch.terms(in: "  speech   model "), ["speech", "model"])
        try expectEqual(LibraryTextMatch.terms(in: "“speech model” ভাষা \"open  question\""),
                        ["speech model", "ভাষা", "open question"])
        try expectEqual(LibraryTextMatch.terms(in: "Zoom zoom ZOOM"), ["Zoom"])
        try expectEqual(LibraryTextMatch.terms(in: ""), [])
        try expectEqual(LibraryTextMatch.terms(in: "\"unclosed phrase"), ["unclosed phrase"])
    }

    // MARK: Days

    private static func dayGrouping() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let locale = Locale(identifier: "en_US")
        func date(_ iso: String) -> Date { KanDate.parse(iso) ?? Date(timeIntervalSince1970: 0) }
        struct Item: Identifiable { let id: Int; let date: Date }
        let now = date("2026-11-17T15:00:00Z")
        let items = [
            Item(id: 1, date: date("2026-11-17T10:00:00Z")),
            Item(id: 2, date: date("2026-11-16T20:00:00Z")),
            Item(id: 3, date: date("2026-11-17T09:00:00Z")),       // out of order: still "Today"
            Item(id: 4, date: date("2026-11-10T08:00:00Z")),
            Item(id: 5, date: date("2025-12-31T23:30:00Z")),
        ]
        let sections = LibraryDayGrouping.sections(items, date: \.date, now: now, calendar: calendar, locale: locale)
        try expectEqual(sections.map { $0.items.map(\.id) }, [[1, 3], [2], [4], [5]])
        try expectEqual(sections[0].title, "Today")
        try expectEqual(sections[1].title, "Yesterday")
        try expect(sections[2].title.contains("Tuesday") && sections[2].title.contains("10")
                   && !sections[2].title.contains("2026"), "weekday + date without the current year: \(sections[2].title)")
        try expect(sections[3].title.contains("2025"), "other years show the year: \(sections[3].title)")
        try expect(LibraryDayGrouping.sections([Item](), date: \.date, now: now, calendar: calendar, locale: locale).isEmpty,
                   "no items, no sections")
    }

    // MARK: Folders

    private static func folderTree() throws {
        let folders = [
            FolderInfo(name: "", count: 3),
            FolderInfo(name: "Research", count: 1),
            FolderInfo(name: "Research/Thesis", count: 2),
            FolderInfo(name: "Research/Week 10", count: 0),
            FolderInfo(name: "Research/Week 2", count: 1),
            FolderInfo(name: "Admin/Visa", count: 1),            // parent "Admin" missing
        ]
        let tree = LibraryFolderTree.build(folders)
        try expectEqual(tree.map(\.path), ["Admin", "Research"])
        try expectEqual(tree[0].count, 0)
        try expectEqual(tree[0].totalCount, 1)
        try expectEqual(tree[0].children?.map(\.name) ?? [], ["Visa"])
        try expectEqual(tree[1].children?.map(\.name) ?? [], ["Thesis", "Week 2", "Week 10"])
        try expectEqual(tree[1].totalCount, 4)
        try expect(tree[1].children?.first?.children == nil, "leaves have no children array")
        let flat = LibraryFolderTree.flatten(tree)
        try expectEqual(flat.map(\.path), ["Admin", "Admin/Visa", "Research", "Research/Thesis", "Research/Week 2",
                                           "Research/Week 10"])
        try expectEqual(flat.map(\.depth), [0, 1, 0, 1, 1, 1])
        try expect(LibraryFolderTree.build([FolderInfo(name: "", count: 5)]).isEmpty, "the Inbox isn't a tree node")
    }

    private static func folderPaths() throws {
        try expectEqual(LibraryFolderTree.parent(of: "A/B/C"), "A/B")
        try expectEqual(LibraryFolderTree.parent(of: "A"), nil)
        try expectEqual(LibraryFolderTree.name(of: "A/B/C"), "C")
        try expectEqual(LibraryFolderTree.name(of: "A"), "A")
        try expectEqual(LibraryFolderTree.join(nil, "New"), "New")
        try expectEqual(LibraryFolderTree.join("", "New"), "New")
        try expectEqual(LibraryFolderTree.join("A/B", "New"), "A/B/New")
        try expect(LibraryFolderTree.folder("Research/Thesis", isInside: "research"), "case-insensitive ancestor")
        try expect(LibraryFolderTree.folder("Research", isInside: "Research"), "a folder is inside itself")
        try expect(!LibraryFolderTree.folder("Researcher", isInside: "Research"), "prefix of a name isn't a parent")
        try expectEqual(LibraryFolderTree.renamed("Research/Thesis/Ch1", from: "Research", to: "PhD"), "PhD/Thesis/Ch1")
        try expectEqual(LibraryFolderTree.renamed("Other", from: "Research", to: "PhD"), "Other")
    }

    // MARK: Filters

    private static func summary(title: String = "Call", folder: String = "", tags: [String] = [], starred: Bool = false,
                                labeled: Bool = true, status: CallStatus = .ready, app: String = "Zoom",
                                platform: CallPlatform = .zoom, speakers: [String] = ["Nahian", "Prof. Rahman"],
                                start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CallSummary {
        let people = speakers.enumerated().map { i, name in
            Speaker(id: i == 0 ? Speaker.meID : "s\(i)", name: name, isMe: i == 0)
        }
        let record = CallRecord(title: title, folder: folder, tags: tags, starred: starred, labeled: labeled,
                                startedAt: start, endedAt: start.addingTimeInterval(600), timeZone: "UTC",
                                source: CallSource(appName: app, platform: platform), status: status, speakers: people)
        return CallSummary(record: record)
    }

    private static func listFilters() throws {
        let inbox = summary(labeled: false, status: .queued)
        let thesis = summary(folder: "Research/Thesis", tags: ["Thesis", "ideas"], starred: true)
        let research = summary(folder: "Research")
        let researcher = summary(folder: "Researcher")
        typealias F = LibraryFilter
        try expect(F.matches(inbox, .inbox) && !F.matches(thesis, .inbox), "inbox = unlabeled")
        try expect(F.matches(inbox, .processing) && !F.matches(thesis, .processing), "processing = active status")
        try expect(F.matches(thesis, .starred) && !F.matches(research, .starred), "starred")
        try expect(F.matches(thesis, .folder("research")) && F.matches(research, .folder("Research")),
                   "folders include subfolders, case-insensitively")
        try expect(!F.matches(researcher, .folder("Research")), "a name prefix isn't a subfolder")
        try expect(F.matches(inbox, .folder("")) && !F.matches(thesis, .folder("")), "\"\" = calls without a folder")
        try expect(F.matches(thesis, .tag("#thesis")) && F.matches(thesis, .tag("IDEAS")) && !F.matches(research, .tag("thesis")),
                   "tags ignore case and #")
        try expect(F.matches(thesis, .person("prof. rahman")) && !F.matches(thesis, .person("Rahman")),
                   "people match whole names")
        try expect(F.matches(thesis, .app("zoom")) && !F.matches(thesis, .app("Zen")), "apps")
        try expect(F.matches(thesis, .all), "all")

        let query = F.searchQuery(text: "ভাষা", item: .folder("Research"), limit: 50)
        try expectEqual(query.folder, "Research")
        try expectEqual(query.limit, 50)
        try expect(F.searchQuery(text: "x", item: .starred, limit: 0).starredOnly, "starred query")
        try expectEqual(F.searchQuery(text: "x", item: .tag("ideas"), limit: 0).tag, "ideas")
        try expect(F.needsPostFiltering(.inbox) && F.needsPostFiltering(.person("A")) && !F.needsPostFiltering(.tag("a")),
                   "post-filtering")
        try expect(F.isActive(.recording) && F.isActive(.queued) && F.isActive(.processing) && !F.isActive(.ready)
                   && !F.isActive(.failed), "active statuses")

        let counts = LibraryCounts([inbox, thesis, research])
        try expectEqual(counts, { var c = LibraryCounts(); c.all = 3; c.inbox = 1; c.starred = 1; c.processing = 1; return c }())
        try expectEqual(LibrarySidebarItem.folder("Research/Thesis").title, "Thesis")
        try expectEqual(LibrarySidebarItem.folder("").title, LibraryFilter.unfiledTitle)
        try expectEqual(LibrarySidebarItem.tag("ideas").title, "#ideas")

        let items: [LibrarySidebarItem] = [.inbox, .all, .starred, .processing, .folder(""), .folder("Research/Thesis"),
                                           .tag("ideas"), .person("Prof. Rahman"), .app("Google Meet"), .tag("a:b")]
        for item in items {
            try expectEqual(LibrarySidebarItem(storageKey: item.storageKey), item, "round trip of \(item.storageKey)")
        }
        try expect(LibrarySidebarItem(storageKey: "bogus") == nil && LibrarySidebarItem(storageKey: "tag:") == nil
                   && LibrarySidebarItem(storageKey: "") == nil, "invalid keys")
    }

    private static func tagsAndPeople() throws {
        try expectEqual(LibraryFilter.tagKey(" #Research  Ideas "), LibraryFilter.tagKey("research ideas"))
        try expectEqual(LibraryFilter.parseTags("#a, b ,A, ,c", existing: ["C"]), ["a", "b"])
        try expectEqual(LibraryFilter.parseTags("গবেষণা"), ["গবেষণা"])
        try expectEqual(LibraryFilter.parseTags("f, g, h", existing: ["a", "b", "c", "d", "e"]), ["f", "g"], "at most 7 tags")
        try expectEqual(LibraryFilter.parseTags("x", existing: ["a", "b", "c", "d", "e", "f", "g"]), [])
        let call = summary(speakers: ["Nahian", "Speaker 2", "Prof. Rahman", "prof. rahman", "Me", "Karim"])
        try expectEqual(LibraryFilter.otherPeople(in: call, userName: "nahian"), ["Prof. Rahman", "Karim"])
    }

    private static func appsSection() throws {
        let calls = [
            summary(app: "Zoom", platform: .zoom), summary(app: "Zoom", platform: .zoom),
            summary(app: "Zen", platform: .googleMeet), summary(app: "Zen", platform: .browser),
            summary(app: "Telegram", platform: .telegram), summary(app: "", platform: .manual),
        ]
        let entries = LibraryAppGrouping.entries(calls)
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        try expectEqual(byName["Zoom"]?.count, 2)
        try expectEqual(byName["Zoom"]?.isApp, true)
        try expectEqual(byName["Zen"]?.count, 2)
        try expectEqual(byName["Zen"]?.platform, nil)              // Meet and plain browser calls
        try expectEqual(byName["Google Meet"]?.count, 1)
        try expectEqual(byName["Google Meet"]?.isApp, false)
        try expectEqual(byName["Telegram"]?.count, 1)
        try expectEqual(byName["Manual recording"]?.count, 1)
        try expect(byName["Browser call"] == nil, "generic platforms aren't listed")
        try expectEqual(entries.first?.name, "Zen")                  // count 2, then by name: "Zen" < "Zoom"
        for entry in entries {
            let matching = calls.filter { LibraryAppGrouping.matches($0, app: entry.name) }.count
            try expectEqual(matching, entry.count, "the filter lists exactly what \(entry.name) counts")
        }
        try expect(LibraryAppGrouping.matches(calls[2], app: "googleMeet"), "platform ids match too")
    }

    // MARK: Transcript

    private static func segment(_ id: Int, _ start: Double, _ end: Double, _ speaker: String, _ text: String,
                                flags: [SegmentFlag] = []) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, speakerID: speaker,
                          channel: speaker == Speaker.meID ? .me : .them, text: text, language: "en", flags: flags)
    }

    private static var sampleSegments: [TranscriptSegment] {
        [
            segment(0, 0, 3, "me", "Hi"),
            segment(1, 3.5, 6, "me", "there"),
            segment(2, 6.2, 9, "s1", "আমি গবেষণা করছি"),
            segment(3, 12, 14, "s1", "on speech"),
            segment(4, 14, 15, "me", "on speech", flags: [.echoSuspect]),
            segment(5, 16, 17, "me", "   "),
            segment(6, 1, 2, "s1", "early"),            // appended out of order
        ]
    }

    private static func turnMerging() throws {
        let turns = LibraryTurnMerging.turns(sampleSegments, includeEchoSuspects: false)
        try expectEqual(turns.map { $0.segments.map(\.id) }, [[0], [6], [1], [2], [3]])
        let segments = sampleSegments.filter { $0.id != 6 }
        try expectEqual(LibraryTurnMerging.turns(segments, includeEchoSuspects: false).map { $0.segments.map(\.id) },
                        [[0, 1], [2], [3]])
        try expectEqual(LibraryTurnMerging.turns(segments, includeEchoSuspects: true).map { $0.segments.map(\.id) },
                        [[0, 1], [2], [3], [4]])
        try expectEqual(LibraryTurnMerging.echoSuspectCount(sampleSegments), 1)
        let long = [segment(0, 0, 50, "me", "a"), segment(1, 50.5, 100, "me", "b")]
        try expectEqual(LibraryTurnMerging.turns(long, includeEchoSuspects: false).count, 2, "turns stop at 90 s")
        let first = LibraryTurnMerging.turns(segments, includeEchoSuspects: false)[0]
        try expectEqual(first.start, 0)
        try expectEqual(first.end, 6)
        try expectEqual(first.id, 0)
    }

    private static func plan(_ segments: [TranscriptSegment], echo: Bool = false) -> LibraryTranscriptPlan {
        LibraryTranscriptPlan(segments: segments, includeEchoSuspects: echo) { id in
            id == "me" ? "Nahian" : "Prof. Rahman"
        }
    }

    private static func planRanges() throws {
        let segments = sampleSegments.filter { $0.id != 6 }
        let p = plan(segments)
        let text = p.string as NSString
        try expectEqual(p.turns.count, 3)
        try expectEqual(text.substring(with: p.turns[0].nameRange), "Nahian")
        try expectEqual(text.substring(with: p.turns[0].timeRange), "[00:00:00]")
        try expectEqual(text.substring(with: p.turns[0].bodyRange), "Hi there")
        try expectEqual(text.substring(with: p.turns[1].headerRange), "Prof. Rahman  [00:00:06]")
        try expectEqual(text.substring(with: p.turns[1].bodyRange), "আমি গবেষণা করছি")
        for s in p.segments { try expectEqual(text.substring(with: s.range), s.text) }
        try expectEqual(p.segments.map(\.turnIndex), [0, 0, 1, 2])
        try expect(p.string.hasPrefix("Nahian  [00:00:00]\nHi there\nProf. Rahman  [00:00:06]\n"), p.string)
        try expect(plan([]).isEmpty, "empty plan")
        let withEcho = plan(segments, echo: true)
        try expectEqual(withEcho.segments.last?.isEchoSuspect, true)
    }

    private static func planLookups() throws {
        let p = plan(sampleSegments.filter { $0.id != 6 })
        func id(_ index: Int?) -> Int? { index.map { p.segments[$0].segment.id } }
        try expectEqual(id(p.segmentIndex(playingAt: 4.0)), 1)
        try expectEqual(id(p.segmentIndex(playingAt: 10.0)), 2)       // 1 s after it ended: still current
        try expectEqual(id(p.segmentIndex(playingAt: 11.5)), nil)     // a longer pause
        try expectEqual(id(p.segmentIndex(nearest: 11.5)), 2)
        try expectEqual(id(p.segmentIndex(nearest: -3)), 0)
        try expectEqual(id(p.segmentIndex(playingAt: -1)), nil)
        try expectEqual(p.segmentIndex(forID: 3), 3)
        try expectEqual(p.segmentIndex(forID: 99), nil)
        for (i, s) in p.segments.enumerated() {
            try expectEqual(p.segmentIndex(containing: s.range.location), i)
            try expectEqual(p.segmentIndex(containing: s.range.upperBound - 1), i)
        }
        try expectEqual(p.segmentIndex(containing: 0), nil)          // inside the first header
        let matches = p.matchRanges(of: ["গবেষণা", "speech"])
        try expectEqual(matches.map { (p.string as NSString).substring(with: $0) }, ["গবেষণা", "speech"])
        try expect(p.matchRanges(of: ["Nahian"]).isEmpty, "speaker names and timestamps aren't searched")
    }

    private static func speakerStats() throws {
        let speakers = [
            Speaker(id: "me", name: "Nahian", isMe: true, talkTime: 30),
            Speaker(id: "s1", name: "Speaker 1", isMe: false, talkTime: 60),
            Speaker(id: "s2", name: "Speaker 2", isMe: false, talkTime: 10),
        ]
        let shares = LibrarySpeakerStats.talkShares(speakers: speakers, segments: [])
        try expectEqual(shares["s1"], 0.6)
        try expectEqual(shares["me"], 0.3)
        let untimed = speakers.map { Speaker(id: $0.id, name: $0.name, isMe: $0.isMe) }
        let fromSegments = LibrarySpeakerStats.talkShares(speakers: untimed, segments: sampleSegments)
        try expect(abs((fromSegments["me"] ?? 0) - 5.5 / 11.3) < 0.0001,
                   "segment durations, echo and empty segments excluded: \(fromSegments)")
        try expect(LibrarySpeakerStats.talkShares(speakers: untimed, segments: []).isEmpty, "nobody spoke")
        try expectEqual(LibrarySpeakerStats.sampleSegment(for: "s1", in: sampleSegments)?.id, 2)
        try expectEqual(LibrarySpeakerStats.sampleSegment(for: "me", in: sampleSegments)?.id, 0)   // ties: earliest
        try expectEqual(LibrarySpeakerStats.sampleSegment(for: "s9", in: sampleSegments)?.id, nil)
        let more = speakers + [Speaker(id: "s3", name: "Speaker 3", isMe: false)]
        try expectEqual(LibrarySpeakerStats.colorSlots(speakers: more, slotCount: 3), ["me": 0, "s1": 1, "s2": 2, "s3": 1])
        try expectEqual(LibrarySpeakerStats.displayOrder([speakers[1], speakers[0]]).map(\.id), ["me", "s1"])
        try expectEqual(LibrarySpeakerStats.speaker(named: "speaker 2", in: speakers, excluding: "s1")?.id, "s2")
        try expectEqual(LibrarySpeakerStats.speaker(named: "Speaker 2", in: speakers, excluding: "s2")?.id, nil)
    }

    private static func statusInfo() throws {
        let id = CallID.generate()
        let running = ProcessingStatus(callID: id, state: .running,
                                       progress: PipelineProgress(stage: .transcribingBangla, fraction: 0.42))
        try expectEqual(LibraryCallStatus.badge(status: .processing, processing: running), .transcribing(0.42))
        try expectEqual(LibraryCallBadge.transcribing(0.42).label, "42%")
        try expectEqual(LibraryCallStatus.badge(status: .ready, processing: ProcessingStatus(callID: id, state: .queued)), .queued)
        try expectEqual(LibraryCallStatus.badge(status: .failed, processing: nil), .failed)
        try expectEqual(LibraryCallStatus.badge(status: .ready, processing: ProcessingStatus(callID: id, state: .done)), nil)
        try expectEqual(LibraryCallStatus.badge(status: .recording, processing: nil), .recording)

        let banner = LibraryCallStatus.banner(status: .processing, processing: running, hasTranscript: true, error: nil)
        try expectEqual(banner?.kind, .transcribing)
        try expectEqual(banner?.progress, 0.42)
        try expect(banner?.canCancel == true && banner?.detail?.contains("Transcribing Bangla") == true
                   && banner?.detail?.contains("stays") == true, "running banner: \(String(describing: banner))")
        let cancelled = LibraryCallStatus.banner(status: .failed, processing: nil, hasTranscript: false,
                                                 error: LibraryCallStatus.cancelledMessage)
        try expectEqual(cancelled?.kind, .cancelled)
        try expectEqual(cancelled?.canRetry, true)
        let failed = LibraryCallStatus.banner(status: .failed, processing: nil, hasTranscript: true, error: "Model missing")
        try expectEqual(failed?.detail, "Model missing. This is the previous transcript.")
        try expect(LibraryCallStatus.banner(status: .ready, processing: nil, hasTranscript: true, error: nil) == nil,
                   "ready calls have no banner")
    }

    private static func formatting() throws {
        try expectEqual(LibraryFormat.appLabel(appName: "Zen", platform: .googleMeet), "Google Meet (Zen)")
        try expectEqual(LibraryFormat.appLabel(appName: "Zoom", platform: .zoom), "Zoom")
        try expectEqual(LibraryFormat.appLabel(appName: "", platform: .zoom), "Zoom")
        try expectEqual(LibraryFormat.appLabel(appName: "Zen", platform: .browser), "Zen")
        try expectEqual(LibraryFormat.appLabel(appName: "Microsoft Teams (work or school)", platform: .teams),
                        "Microsoft Teams (work or school)")
        try expectEqual(LibraryFormat.percent(0.523), "52%")
        try expectEqual(LibraryFormat.percent(1.7), "100%")
        try expectEqual(LibraryFormat.languages(["bn", "en"]), "বাংলা, English")
        try expectEqual(LibraryFormat.count(1, "call"), "1 call")
        try expectEqual(LibraryFormat.count(3, "match", "matches"), "3 matches")
        try expectEqual(LibraryFormat.nonEmpty("  \n"), nil)
        try expectEqual(LibraryFormat.nonEmpty(" a "), "a")
        try expectEqual(LibraryFormat.transcriptLine(time: 751, speaker: "Prof. Rahman", text: "Hi"), "[00:12:31] Prof. Rahman: Hi")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let range = LibraryFormat.timeRange(start, start.addingTimeInterval(2520), calendar: calendar,
                                            locale: Locale(identifier: "en_GB"))
        try expect(range.contains("–") && range.contains(":"), range)
        try expect(!LibraryFormat.longDate(start, calendar: calendar, locale: Locale(identifier: "en_US")).isEmpty, "long date")
    }
}
#endif
