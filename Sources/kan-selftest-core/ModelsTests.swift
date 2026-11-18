import Foundation
import KanCore
import KanTestKit

func modelsTests() -> TestSuite {
    let suite = TestSuite("Models")

    suite.test("iCloud Drive check: folders outside it, existing or not, aren't synced") {
        let base = temporaryDirectory("paths-icloud")
        try expect(!KanPaths.isInICloudDrive(base))
        try expect(!KanPaths.isInICloudDrive(base.appendingPathComponent("Not yet/Kan", isDirectory: true)),
                   "a folder that doesn't exist yet is judged by the nearest one that does")
        try expect(!KanPaths.isInICloudDrive(URL(fileURLWithPath: "/")))
        try expectEqual(KanPaths.userHome.path, ProcessInfo.processInfo.environment["KAN_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true).path } ?? "", "the home folder Kan suggests a library in follows KAN_HOME")
    }

    suite.test("KAN_HOME redirects every path into the test directory") {
        let home = testHome.resolvingSymlinksInPath().path
        for url in [KanPaths.appSupport, KanPaths.defaultLibrary, KanPaths.logs, KanPaths.calls,
                    KanPaths.settingsFile, KanPaths.voiceprintsFile, KanPaths.processingQueueFile] {
            try expect(url.resolvingSymlinksInPath().path.hasPrefix(home), "\(url.path) escapes KAN_HOME")
        }
    }

    suite.test("CallID: 26 Crockford base32 characters, unique") {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var seen = Set<CallID>()
        for _ in 0..<20_000 {
            let id = CallID.generate()
            try expectEqual(id.rawValue.count, 26)
            try expect(id.rawValue.allSatisfy(alphabet.contains), id.rawValue)
            seen.insert(id)
        }
        try expectEqual(seen.count, 20_000)
    }

    suite.test("CallID sorts by creation time") {
        let base = Fixture.date("2026-11-16T15:30:00-05:00")
        // Milliseconds apart at least (ULIDs carry millisecond time; within one ms the order is random).
        let offsets: [Double] = [0, 0.01, 0.02, 1, 59, 3600, 86_400, 31_536_000, 315_360_000].shuffled()
        let pairs = offsets.map { ($0, CallID.generate(date: base.addingTimeInterval($0))) }
        let byID = pairs.sorted { $0.1 < $1.1 }.map(\.0)
        try expectEqual(byID, offsets.sorted())
        try expect(CallID.generate(date: Fixture.date("2020-01-01T00:00:00Z")) < CallID.generate(date: base))
    }

    suite.test("CallID encodes as a bare JSON string") {
        let id = CallID(rawValue: "01JD3Q8Z6M7K2V9R4T5N8P1XQA")
        let data = try JSONEncoder.kanCompact.encode([id])
        try expectEqual(String(decoding: data, as: UTF8.self), "[\"01JD3Q8Z6M7K2V9R4T5N8P1XQA\"]")
        try expectEqual(try JSONDecoder.kan.decode([CallID].self, from: data), [id])
    }

    suite.test("Settings: missing keys take defaults") {
        try expectEqual(try JSONDecoder.kan.decode(KanSettings.self, from: Data("{}".utf8)), KanSettings())
        let partial = try JSONDecoder.kan.decode(KanSettings.self, from: Data(#"{"userName":"Nahian","keepAudio":false}"#.utf8))
        try expectEqual(partial.userName, "Nahian")
        try expectEqual(partial.keepAudio, false)
        try expectEqual(partial.languageMode, .auto)
        try expectEqual(partial.promptTemplates, PromptTemplate.defaults)
        try expectEqual(partial.effectiveUserName, "Nahian")
        try expectEqual(KanSettings().effectiveUserName, "Me")
    }

    suite.test("Settings: unknown keys and wrong types are ignored") {
        let json = #"{"userName": 5, "futureKey": {"x": [1, 2]}, "languageMode": "klingon", "minCallSeconds": 30, "maxRemoteSpeakers": 3, "audioRetentionDays": "soon"}"#
        let s = try JSONDecoder.kan.decode(KanSettings.self, from: Data(json.utf8))
        try expectEqual(s.userName, "")
        try expectEqual(s.languageMode, .auto)
        try expectEqual(s.minCallSeconds, 30)
        try expectEqual(s.maxRemoteSpeakers, 3)
        try expectEqual(s.audioRetentionDays, nil)
    }

    suite.test("SettingsStore round-trips and moves a corrupt file aside") {
        let dir = temporaryDirectory("settings")
        let url = dir.appendingPathComponent("settings.json")
        let store = SettingsStore(fileURL: url)
        try expectEqual(store.load(), KanSettings())          // missing file → defaults
        var settings = KanSettings()
        settings.userName = "নাহিয়ান"
        settings.rememberVoices = true
        settings.appPolicies = ["us.zoom.xos": .ask]
        try store.save(settings)
        try expectEqual(store.load(), settings)

        try Data("{ not json".utf8).write(to: url)
        try expectEqual(store.load(), KanSettings())
        try expect(!FileManager.default.fileExists(atPath: url.path), "corrupt file should be moved")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        try expect(names.contains { $0.hasPrefix("settings.corrupt-") && $0.hasSuffix(".json") }, "\(names)")
    }

    suite.test("Speaker default names") {
        for name in ["Speaker 1", "speaker 12", "Speaker", "", "  "] { try expect(Speaker.isDefaultName(name), name) }
        for name in ["Rahim", "Speakers Club", "Speaker A", "Me"] { try expect(!Speaker.isDefaultName(name), name) }
        try expectEqual(Speaker.defaultName(number: 3), "Speaker 3")
    }

    suite.test("CallSummary from a record") {
        let record = Fixture.record(notes: "", speakers: Fixture.speakers(others: ["Speaker 1"]), segments: [
            Fixture.segment(0, 1, 2, "me", "Hello there  world"),
            Fixture.segment(1, 3, 4, "s1", "আমরা বাংলা ভাষার জন্য", language: "bn"),
            Fixture.segment(2, 5, 6, "me", "echo echo", flags: [.echoSuspect]),
        ])
        let s = CallSummary(record: record, markdownPath: "Inbox/x.md", jsonPath: "Inbox/x.json")
        try expectEqual(s.wordCount, 7)                    // echo suspects don't count
        try expectEqual(s.segmentCount, 3)
        try expectEqual(s.speakerNames, ["Nahian", "Speaker 1"])
        try expectEqual(s.preview, "Hello there world আমরা বাংলা ভাষার জন্য")
        try expectEqual(s.hasAudio, false)
        var withNotes = record
        withNotes.notes = "Idea:\n  augmentation"
        withNotes.audio = AudioAssets(meFile: "me.m4a", themFile: nil, format: "m4a")
        let s2 = CallSummary(record: withNotes)
        try expectEqual(s2.preview, "Idea: augmentation")
        try expectEqual(s2.hasAudio, true)
        try expectEqual(withNotes.otherPeople, [])
    }

    suite.test("CallSummary: preview is the notes, else the summary's overview, else the transcript") {
        var record = Fixture.record(notes: "", segments: [Fixture.segment(0, 1, 2, "me", "Hello there")])
        try expectEqual(CallSummary(record: record).preview, "Hello there")
        try expectEqual(CallSummary(record: record).hasSummary, false)
        record.ai = CallInsights(summary: Fixture.summary(overview: "  We planned the\nBangla ASR paper.  "))
        try expectEqual(CallSummary(record: record).preview, "We planned the Bangla ASR paper.")
        try expectEqual(CallSummary(record: record).hasSummary, true)
        record.notes = "My own notes"
        try expectEqual(CallSummary(record: record).preview, "My own notes")
        record.ai?.summary = Fixture.summary(overview: " \n ", keyPoints: ["  "])
        try expectEqual(CallSummary(record: record).hasSummary, false, "a summary without text doesn't count")
        record.ai = CallInsights(titleSuggestions: AITitleSuggestions(titles: ["Idea"], model: "m", generatedAt: Date(), fingerprint: ""))
        try expectEqual(CallSummary(record: record).hasSummary, false, "title ideas aren't a summary")
        record.ai = CallInsights(summary: Fixture.summary(overview: "", actionItems: ["Rahim: share the data"]))
        try expectEqual(CallSummary(record: record).hasSummary, true, "a list item is enough")
    }

    suite.test("CallSummary: index.jsonl lines written before summaries existed still decode") {
        var record = Fixture.record(segments: [Fixture.segment(0, 1, 2, "me", "Hello")])
        record.ai = CallInsights(summary: Fixture.summary(overview: "We said hello."))
        let summary = CallSummary(record: record, markdownPath: "Inbox/x.md", jsonPath: "Inbox/x.json")
        let line = try JSONEncoder.kanCompact.encode(summary)
        try expectEqual(try JSONDecoder.kan.decode(CallSummary.self, from: line), summary)
        var object = try expectNotNil(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        try expectEqual(object["hasSummary"] as? Bool, true)
        object["hasSummary"] = nil
        let old = try JSONDecoder.kan.decode(CallSummary.self, from: try JSONSerialization.data(withJSONObject: object))
        try expectEqual(old.hasSummary, false)
        var expected = summary
        expected.hasSummary = false
        try expectEqual(old, expected, "everything else as written")
        object["title"] = nil
        try expectThrows("the other keys are still required") {
            _ = try JSONDecoder.kan.decode(CallSummary.self, from: try JSONSerialization.data(withJSONObject: object))
        }
    }

    suite.test("CallRecord: an ai part this build can't read never makes the call unreadable") {
        let record = Fixture.record(title: "Lenient", segments: [Fixture.segment(0, 1, 2, "me", "Hello")])
        let encoded = try JSONEncoder.kanPretty.encode(record)
        func decode(ai: Any?) throws -> CallRecord {
            var object = try expectNotNil(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["ai"] = ai
            return try JSONDecoder.kan.decode(CallRecord.self, from: try JSONSerialization.data(withJSONObject: object))
        }
        try expect(!String(decoding: encoded, as: UTF8.self).contains("\"ai\""), "no key without insights")
        try expect(try decode(ai: nil).ai == nil)
        try expect(try decode(ai: NSNull()).ai == nil)
        // Not an object: the call loads with empty insights (the next save drops them).
        for junk in ["a summary", 42, true, [1, 2], ["summary"]] as [Any] {
            let decoded = try decode(ai: junk)
            try expectEqual(decoded.id, record.id, "\(junk)")
            try expectEqual(decoded.segments, record.segments, "\(junk)")
            try expect(decoded.ai?.isEmpty ?? true, "\(junk)")
        }
        // Parts of the wrong type, or without their required field, are left out one by one.
        let wrongParts = try decode(ai: ["summary": "text", "titleSuggestions": 5, "appliedTitle": ["x"], "future": ["y": 1]] as [String: Any])
        try expect(wrongParts.ai?.isEmpty == true)
        let missing = try decode(ai: ["summary": ["keyPoints": ["x"]], "titleSuggestions": ["model": "m"], "appliedTitle": "Kept"] as [String: Any])
        try expect(missing.ai?.summary == nil && missing.ai?.titleSuggestions == nil)
        try expectEqual(missing.ai?.appliedTitle, "Kept")
        // Inside a readable part, an unreadable field takes its default.
        let lenient = try decode(ai: [
            "summary": ["overview": "Fine", "keyPoints": "not a list", "ideas": [1, 2], "decisions": ["Ship it"],
                        "language": "klingon", "generatedAt": "soon", "shortened": "yes", "model": 5, "fingerprint": NSNull()] as [String: Any],
            "titleSuggestions": ["titles": ["A good title"], "generatedAt": "never", "model": ["x"]] as [String: Any],
        ])
        let summary = try expectNotNil(lenient.ai?.summary)
        try expectEqual(summary.overview, "Fine")
        try expectEqual(summary.keyPoints, [])
        try expectEqual(summary.ideas, [])
        try expectEqual(summary.decisions, ["Ship it"])
        try expectEqual(summary.language, .english)
        try expectEqual(summary.generatedAt, .distantPast)
        try expectEqual(summary.shortened, false)
        try expectEqual(summary.model, "")
        try expectEqual(summary.fingerprint, "")
        try expectEqual(lenient.ai?.titleSuggestions?.titles, ["A good title"])
        try expectEqual(lenient.ai?.titleSuggestions?.model, "")
        try expectEqual(lenient.ai?.titleSuggestions?.generatedAt, .distantPast)
        try expectEqual(lenient.ai?.appliedTitle, nil)

        // Everything Kan writes comes back as it was.
        var full = record
        let written = Fixture.date("2026-11-17T09:30:00-05:00")
        full.ai = CallInsights(
            titleSuggestions: AITitleSuggestions(titles: ["One", "Two"], model: "gpt-6.1-terra", generatedAt: written, fingerprint: "00ff"),
            summary: AISummary(overview: "O", keyPoints: ["k"], ideas: ["i"], decisions: ["d"], actionItems: ["a"],
                               openQuestions: ["q"], language: .bangla, model: "gpt-6-luna", generatedAt: written,
                               fingerprint: "abcd", shortened: true),
            appliedTitle: "One")
        try expectEqual(try JSONDecoder.kan.decode(CallRecord.self, from: try JSONEncoder.kanPretty.encode(full)).ai, full.ai)
    }

    suite.test("fingerprint: only the transcript's lines and speaker names count") {
        let record = Fixture.record(title: "Fingerprint", speakers: Fixture.speakers(others: ["Speaker 1"]), segments: [
            Fixture.segment(0, 1, 2, "me", "Hello"),
            Fixture.segment(1, 3, 4, "s1", "আমরা বাংলা ভাষার জন্য", language: "bn"),
            Fixture.segment(2, 5, 6, "me", "Hello (echo)", flags: [.echoSuspect]),
        ])
        let original = CallInsights.fingerprint(of: record)
        try expectEqual(original.count, 16)
        try expect(original.allSatisfy(\.isHexDigit), original)

        // What Kan stores next to the transcript, and the call's state, leave it alone.
        var labeled = record
        labeled.ai = CallInsights(
            titleSuggestions: AITitleSuggestions(titles: ["Bangla ASR"], model: "m", generatedAt: Date(), fingerprint: original),
            summary: Fixture.summary(overview: "We said hello.", keyPoints: ["Hello"], fingerprint: original),
            appliedTitle: "Bangla ASR")
        labeled.title = "Bangla ASR"
        labeled.notes = "My notes"
        labeled.tags = ["asr"]
        labeled.bookmarks = [Bookmark(time: 1, note: "here")]
        labeled.folder = "Research"
        labeled.starred = true
        labeled.labeled = true
        try expectEqual(CallInsights.fingerprint(of: labeled), original)
        try expect(!labeled.isSummaryOutdated && !labeled.areTitleIdeasOutdated)
        // Being transcribed again, or a failed attempt, still shows the same lines.
        labeled.status = .processing
        try expectEqual(CallInsights.fingerprint(of: labeled), original)
        labeled.status = .failed
        labeled.processing = ProcessingInfo(error: "Model not installed: large-v3")
        try expectEqual(CallInsights.fingerprint(of: labeled), original)
        try expect(TranscriptRenderer.plainText(labeled).contains("We said hello."), "the summary is in the plain text")
        // Stored and read back (NFC, normalized) it is still the same.
        let lib = TestLibrary("fingerprint")
        try lib.store.save(labeled)
        try expectEqual(CallInsights.fingerprint(of: try lib.reopened().record(labeled.id)), original)

        // The words or the names change it.
        var renamed = record
        renamed.speakers[1].name = "Rahim"
        try expect(CallInsights.fingerprint(of: renamed) != original, "a speaker renamed")
        var edited = record
        edited.segments[1].text = "আমরা বাংলা ভাষার জন্যই"
        try expect(CallInsights.fingerprint(of: edited) != original, "a line edited")
        var added = record
        added.segments.append(Fixture.segment(3, 9, 10, "s1", "More"))
        try expect(CallInsights.fingerprint(of: added) != original, "a new transcript")
        var unflagged = record
        unflagged.segments[2].flags = []
        try expect(CallInsights.fingerprint(of: unflagged) != original, "an echo suspect shown again")
        labeled.speakers[1].name = "Rahim"
        try expect(labeled.isSummaryOutdated && labeled.areTitleIdeasOutdated)
    }

    suite.test("CallID: only ULIDs decode (any case, stored uppercase)") {
        let id = CallID.generate()
        try expect(id.isWellFormed)
        let lower = Data("[\"\(id.rawValue.lowercased())\"]".utf8)
        try expectEqual(try JSONDecoder.kan.decode([CallID].self, from: lower), [id])
        try expectEqual(CallID(parsing: " \(id.rawValue.lowercased())\n"), id)
        for bad in ["", ".", "..", "../Models", "../../..", "01JD3Q8Z6M7K2V9R4T5N8P1XQ", "01JD3Q8Z6M7K2V9R4T5N8P1XQAB",
                    "01JD3Q8Z6M7K2V9R4T5N8P1XQU", "01JD3Q8Z6M7K2V9R4T5N8P1XQ/", "01JD3Q8Z6M7K2V9R4T5N8P1Xß", "01JD3Q8Z6M7K2V9R4T5N8P\u{0}XQA"] {
            let json = try JSONEncoder().encode([bad])
            try expectThrows(bad.debugDescription) { _ = try JSONDecoder.kan.decode([CallID].self, from: json) }
            try expectEqual(CallID(parsing: bad), nil, bad.debugDescription)
            try expect(!CallID(rawValue: bad).isWellFormed, bad.debugDescription)
        }
        try expect(!CallID(rawValue: id.rawValue.lowercased()).isWellFormed, "only the canonical spelling is well formed")
    }

    suite.test("Settings: an entry this version can't read loses only itself, never to a laxer policy") {
        let json = #"""
            {"appPolicies": {"us.zoom.xos": "never", "com.tinyspeck.slackmacgap": "autoSilent", "com.hnc.Discord": 3},
             "promptTemplates": [{"name": "No id", "body": "x"}, {"id": "mine", "name": "Mine", "body": "{{transcript}}"}],
             "languageMode": "klingon", "userName": "Nahian"}
            """#
        let decoder = JSONDecoder.kan
        let report = SettingsDecodingReport()
        decoder.userInfo[try expectNotNil(SettingsDecodingReport.key)] = report
        let s = try decoder.decode(KanSettings.self, from: Data(json.utf8))
        try expectEqual(s.appPolicies, ["us.zoom.xos": .never, "com.tinyspeck.slackmacgap": .ask, "com.hnc.Discord": .ask])
        try expectEqual(s.promptTemplates.map(\.id), ["mine"])
        try expectEqual(s.userName, "Nahian")
        try expectEqual(s.languageMode, .auto)
        try expectEqual(report.issues.count, 4, "\(report.issues)")
        let clean = SettingsDecodingReport()
        let plain = JSONDecoder.kan
        plain.userInfo[try expectNotNil(SettingsDecodingReport.key)] = clean
        _ = try plain.decode(KanSettings.self, from: try JSONEncoder.kanPretty.encode(s))
        try expectEqual(clean.issues, [])

        let unreadable = try JSONDecoder.kan.decode(KanSettings.self, from: Data(#"{"promptTemplates": [{"name": 1}]}"#.utf8))
        try expectEqual(unreadable.promptTemplates, PromptTemplate.defaults)
        let none = try JSONDecoder.kan.decode(KanSettings.self, from: Data(#"{"promptTemplates": [], "appPolicies": null}"#.utf8))
        try expectEqual(none.promptTemplates, [])
        try expectEqual(none.appPolicies, [:])

        // The store keeps the original file before its first save, once.
        let dir = temporaryDirectory("settings-lossy")
        let url = dir.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        var loaded = store.load()
        try expectEqual(loaded.appPolicies["us.zoom.xos"], .never)
        loaded.userName = "Nahian H."
        try store.save(loaded)
        try store.save(loaded)
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("settings.backup-") }
        try expectEqual(backups.count, 1, "\(backups)")
        try expectEqual(try String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8), json)
        try expectEqual(store.load().appPolicies["us.zoom.xos"], .never)
    }

    suite.test("AppCatalog: assistants aren't browsers; a browser opens web links and HTML documents") {
        try expectEqual(AppCatalog.lookup(bundleID: "com.openai.codex")?.name, "ChatGPT")
        try expectEqual(AppCatalog.category(bundleID: "com.openai.codex", appURL: nil), .ignored)
        try expectEqual(DetectionConfig().policy(for: AppIdentity(bundleID: "com.openai.codex", name: "ChatGPT", pid: 1),
                                                 category: .ignored), .never)
        // Info.plists as these apps ship them (trimmed).
        let assistant: [String: Any] = [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["codex", "http", "https"]]],
            "CFBundleDocumentTypes": [["LSItemContentTypes": ["public.folder"]], ["CFBundleTypeExtensions": ["docx"]],
                                      ["LSItemContentTypes": ["public.data"]]]]
        let zen: [String: Any] = [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["http"]], ["CFBundleURLSchemes": ["https"]]],
            "CFBundleDocumentTypes": [["CFBundleTypeExtensions": ["html", "htm", "shtml"]]]]
        let chrome: [String: Any] = [
            "CFBundleURLTypes": [["CFBundleURLSchemes": ["http", "https"]]],
            "CFBundleDocumentTypes": [["LSItemContentTypes": ["com.compuserve.gif"]], ["LSItemContentTypes": ["public.html"]]]]
        let editor: [String: Any] = ["CFBundleDocumentTypes": [["LSItemContentTypes": ["public.html"]]]]
        try expect(!AppCatalog.looksLikeWebBrowser(info: assistant))
        try expect(AppCatalog.looksLikeWebBrowser(info: zen))
        try expect(AppCatalog.looksLikeWebBrowser(info: chrome))
        try expect(!AppCatalog.looksLikeWebBrowser(info: editor))
        // Unknown apps on disk.
        func app(_ name: String, _ info: [String: Any]) throws -> URL {
            let url = temporaryDirectory("catalog-\(name)").appendingPathComponent("\(name).app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist = info
            plist["CFBundleIdentifier"] = "com.example.\(name)"
            plist["CFBundlePackageType"] = "APPL"
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let assistantApp = try app("assistant", assistant)
        try expect(AppCatalog.handlesWebURLs(appURL: assistantApp))
        try expectEqual(AppCatalog.category(bundleID: "com.example.assistant", appURL: assistantApp), .unknown)
        try expectEqual(AppCatalog.category(bundleID: "com.example.browser", appURL: try app("browser", chrome)), .browser)
        try expectEqual(DetectionConfig().policy(for: AppIdentity(bundleID: "com.example.assistant", name: "Assistant", pid: 2),
                                                 category: .unknown), .ask)
    }

    return suite
}
