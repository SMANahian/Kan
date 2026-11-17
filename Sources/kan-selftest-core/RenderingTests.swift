import Foundation
import KanCore
import KanTestKit

private func advisorRecord() -> CallRecord {
    Fixture.record(id: CallID(rawValue: "01JD3Q8Z6M7K2V9R4T5N8P1XQA"), title: "Advisor meeting – augmentation idea",
                   folder: "Research/Thesis", tags: ["research", "thesis"], starred: true,
                   segments: [Fixture.segment(0, 5, 9, "me", "So I was thinking…"),
                              Fixture.segment(1, 21, 25, "s1", "That's interesting…")],
                   languages: ["en", "bn"])
}

private let nastyTitles = [
    #"He said "hi": yes # no"#, #"Back\slash \ path"#, "- leading dash", "[bracket] {brace}", "'single quoted'",
    "বাংলা: আলোচনা #১", "Emoji 🎉🔬 test", "true", "123", "2026-11-14", "null", "key: value", "Tab\tand\nnewline",
    "@mention", "%percent", "*star", "&anchor", "!tag", "|pipe", ">fold", "?question", "~", "`backtick`",
    "trailing colon:", "  padded  ", "#hash", "ends with #", "a\u{07}bell", "line\u{2028}sep", "জ\u{200D}য় joiner",
    "---", "...", "yes", "0x1F", "1e3", ".5",
]
private let nastyTags = ["c++", "a,b", "#hash", "x: y", "বাংলা", "2026", "yes", "[x]", "multi word", "-dash", "ok", "{}", "a#b"]

private func nastyRecord(_ title: String) -> CallRecord {
    var record = Fixture.record(title: title, folder: "Research: \"quoted\"/বাংলা", app: "Zoom: Work", tags: nastyTags,
                                speakers: [Speaker(id: "me", name: #"Nahian "N""#, isMe: true),
                                           Speaker(id: "s1", name: "Prof. Rahman: PI", isMe: false, nameSource: .user),
                                           Speaker(id: "s2", name: "রহিম", isMe: false, nameSource: .user)],
                                attendees: ["a@b.c", "Karim #2"])
    record.calendarEventTitle = "Sync: \"ASR\" #3"
    record.source.meetingURL = "https://meet.google.com/abc-defg-hij?pli=1#x"
    return record
}

func renderingTests() -> TestSuite {
    let suite = TestSuite("Rendering")

    suite.test("Markdown has exactly the documented shape") {
        let expected = """
            ---
            kan_id: 01JD3Q8Z6M7K2V9R4T5N8P1XQA
            title: "Advisor meeting – augmentation idea"
            date: 2026-11-14T10:00:12-05:00
            end: 2026-11-14T10:42:25-05:00
            duration: "00:42:13"
            app: Zoom
            platform: zoom
            folder: "Research/Thesis"
            tags: [research, thesis]
            people: ["Nahian", "Prof. Rahman"]
            languages: [en, bn]
            starred: true
            status: ready
            me: "Nahian"
            ---

            # Advisor meeting – augmentation idea
            Sat 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman

            ## Transcript
            **Nahian** [00:00:05]
            So I was thinking…

            **Prof. Rahman** [00:00:21]
            That's interesting…

            """
        try expectEqual(TranscriptRenderer.markdown(advisorRecord()), expected)
    }

    suite.test("notes and bookmarks sections appear only when present") {
        var record = advisorRecord()
        record.notes = "Idea: use *pseudo-labels*\n\n- follow up"
        record.bookmarks = [Bookmark(time: 1200, endTime: 1290, note: ""), Bookmark(time: 751, note: "augmentation\ndetail")]
        let md = TranscriptRenderer.markdown(record)
        try expect(md.contains("""
            Nahian (me), Prof. Rahman

            ## Notes
            Idea: use *pseudo-labels*

            - follow up

            ## Bookmarks
            - [00:12:31] augmentation detail
            - [00:20:00–00:21:30]

            ## Transcript
            **Nahian** [00:00:05]
            """), md)
        let bare = TranscriptRenderer.markdown(record, options: RenderOptions(includeFrontMatter: false, includeNotes: false,
                                                                              includeBookmarks: false))
        try expect(bare.hasPrefix("# Advisor meeting – augmentation idea\n"), bare)
        try expect(!bare.contains("## Notes") && !bare.contains("## Bookmarks"))
    }

    suite.test("front matter is valid YAML for nasty titles, tags, names and apps") {
        for title in nastyTitles {
            let record = nastyRecord(title)
            let md = TranscriptRenderer.markdown(record)
            let fm: [String: MiniYAML.Value]
            do {
                fm = try MiniYAML.dictionary(md)
            } catch {
                throw fail("title \(title.debugDescription): \(error)\n\(md.prefix(600))")
            }
            try expectEqual(fm["title"], .quoted(title.singleLineForTest), title.debugDescription)
            try expectEqual(fm["tags"], .list(nastyTags), title.debugDescription)
            try expectEqual(fm["people"], .list([#"Nahian "N""#, "Prof. Rahman: PI", "রহিম"]))
            try expectEqual(fm["app"], .quoted("Zoom: Work"))
            try expectEqual(fm["folder"], .quoted("Research: \"quoted\"/বাংলা"))
            try expectEqual(fm["me"], .quoted(#"Nahian "N""#))
            try expectEqual(fm["attendees"], .list(["a@b.c", "Karim #2"]))
            try expectEqual(fm["calendar_event"], .quoted("Sync: \"ASR\" #3"))
            try expectEqual(fm["meeting_url"], .quoted("https://meet.google.com/abc-defg-hij?pli=1#x"))
            try expectEqual(fm.count, 17)
        }
    }

    suite.test("front matter parses with PyYAML to the same values (skipped without python3 + PyYAML)") {
        guard runProcess("/usr/bin/env", ["python3", "-I", "-c", "import yaml"]).status == 0 else {
            throw TestSkip("python3 with PyYAML not available")
        }
        let dir = temporaryDirectory("yaml-check")
        func frontMatterBody(_ md: String) -> String {
            guard md.hasPrefix("---\n"), let end = md.range(of: "\n---\n") else { return "" }
            return String(md[md.index(md.startIndex, offsetBy: 4)..<end.lowerBound])
        }
        let docs = (nastyTitles.map(nastyRecord) + [advisorRecord()]).map { frontMatterBody(TranscriptRenderer.markdown($0)) }
        let input = dir.appendingPathComponent("docs.json")
        try JSONEncoder().encode(docs).write(to: input)
        let script = """
            import json, sys, yaml
            out = []
            for doc in json.load(open(sys.argv[1], encoding="utf-8")):
                v = yaml.safe_load(doc)
                out.append({"title": v["title"], "tags": v["tags"], "people": v["people"], "app": v["app"],
                            "folder": v["folder"], "duration": v["duration"], "kan_id": v["kan_id"],
                            "starred": v["starred"], "date_type": type(v["date"]).__name__,
                            "languages": v["languages"], "status": v["status"]})
            print(json.dumps(out))
            """
        let result = runProcess("/usr/bin/env", ["python3", "-I", "-c", script, input.path])
        guard result.status == 0 else { throw fail("PyYAML failed: \(result.output)") }
        struct Parsed: Decodable {
            let title: String
            let tags: [String]
            let people: [String]
            let app: String
            let folder: String
            let duration: String
            let kan_id: String
            let starred: Bool
            let date_type: String
            let languages: [String]
            let status: String
        }
        let parsed = try JSONDecoder().decode([Parsed].self, from: Data(result.output.utf8))
        try expectEqual(parsed.count, nastyTitles.count + 1)
        for (title, p) in zip(nastyTitles, parsed) {
            try expectEqual(p.title, title.singleLineForTest)
            try expectEqual(p.tags, nastyTags)
            try expectEqual(p.people, [#"Nahian "N""#, "Prof. Rahman: PI", "রহিম"])
            try expectEqual(p.app, "Zoom: Work")
            try expectEqual(p.folder, "Research: \"quoted\"/বাংলা")
            try expectEqual(p.duration, "00:42:13")
            try expectEqual(p.date_type, "datetime")
        }
        let advisor = try expectNotNil(parsed.last)
        try expectEqual(advisor.kan_id, "01JD3Q8Z6M7K2V9R4T5N8P1XQA")
        try expectEqual(advisor.tags, ["research", "thesis"])
        try expectEqual(advisor.languages, ["en", "bn"])
        try expectEqual(advisor.starred, true)
        try expectEqual(advisor.status, "ready")
    }

    suite.test("consecutive segments of one speaker merge (gap < 2 s, ≤ 90 s per paragraph)") {
        var record = advisorRecord()
        record.segments = [
            Fixture.segment(0, 0, 3, "me", "A"), Fixture.segment(1, 3.5, 6, "me", "B"),
            Fixture.segment(2, 9, 10, "me", "C"), Fixture.segment(3, 10, 12, "s1", "D"),
            Fixture.segment(4, 12, 13, "me", "E"), Fixture.segment(5, 13.5, 14, "s1", "F"),
        ]
        let md = TranscriptRenderer.markdown(record)
        try expect(md.hasSuffix("""
            ## Transcript
            **Nahian** [00:00:00]
            A B

            **Nahian** [00:00:09]
            C

            **Prof. Rahman** [00:00:10]
            D

            **Nahian** [00:00:12]
            E

            **Prof. Rahman** [00:00:13]
            F

            """), md)
        let unmerged = TranscriptRenderer.markdown(record, options: RenderOptions(mergeConsecutive: false))
        try expectEqual(unmerged.components(separatedBy: "**Nahian** [").count - 1, 4)
        record.segments = (0..<30).map { Fixture.segment($0, Double($0 * 5), Double($0 * 5 + 4), "me", "part\($0)") }
        let long = TranscriptRenderer.markdown(record)
        try expectEqual(long.components(separatedBy: "**Nahian** [").count - 1, 2)
        try expect(long.contains("**Nahian** [00:01:30]\npart18 part19"), long)
        let plain = TranscriptRenderer.plainText(record, options: RenderOptions(includeFrontMatter: false, includeNotes: false,
                                                                                includeBookmarks: false))
        try expectEqual(plain.split(separator: "\n").count, 2)
    }

    suite.test("echo suspects are hidden unless asked for") {
        var record = advisorRecord()
        record.segments.append(Fixture.segment(2, 22, 24, "me", "That's interesting (echo)", flags: [.echoSuspect]))
        try expect(!TranscriptRenderer.markdown(record).contains("(echo)"))
        try expect(!TranscriptRenderer.plainText(record).contains("(echo)"))
        try expect(!TranscriptRenderer.srt(record).contains("(echo)"))
        try expect(TranscriptRenderer.markdown(record, options: RenderOptions(hideEchoSuspects: false)).contains("(echo)"))
    }

    suite.test("placeholders while recording, queued or processing; failed shows the error") {
        var record = advisorRecord()
        let segments = record.segments
        record.segments = []
        for status in [CallStatus.queued, .processing] {
            record.status = status
            try expect(TranscriptRenderer.markdown(record).hasSuffix("## Transcript\n_Transcript is being generated…_\n"))
            try expect(TranscriptRenderer.plainText(record).contains("(Transcript is being generated…)"))
        }
        record.status = .recording
        try expect(TranscriptRenderer.markdown(record).contains("_Recording in progress — the transcript will appear after the call._"))
        record.status = .failed
        record.processing = ProcessingInfo(error: "Model not installed: large-v3")
        let failed = TranscriptRenderer.markdown(record)
        try expect(failed.contains("_Transcription failed: Model not installed: large-v3. The audio was kept"), failed)
        record.status = .ready
        try expect(TranscriptRenderer.markdown(record).contains("_No speech was detected in this call._"))
        record.segments = segments
        record.status = .processing
        let again = TranscriptRenderer.markdown(record)
        try expect(again.contains("_A new transcript is being generated; this is the previous one._\n\n**Nahian** [00:00:05]"), again)
        record.status = .failed
        try expect(TranscriptRenderer.markdown(record).contains("this is the previous transcript._"))
    }

    suite.test("plain text has a header and [hh:mm:ss] Name: text lines") {
        var record = advisorRecord()
        record.notes = "My notes"
        record.bookmarks = [Bookmark(time: 751, note: "moment")]
        try expectEqual(TranscriptRenderer.plainText(record), """
            Advisor meeting – augmentation idea
            Sat 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman

            Notes:
            My notes

            Bookmarks:
            [00:12:31] moment

            Transcript:
            [00:00:05] Nahian: So I was thinking…
            [00:00:21] Prof. Rahman: That's interesting…

            """)
        try expectEqual(TranscriptRenderer.plainText(record, options: RenderOptions(includeFrontMatter: false, includeNotes: false,
                                                                                    includeBookmarks: false)),
                        "[00:00:05] Nahian: So I was thinking…\n[00:00:21] Prof. Rahman: That's interesting…\n")
    }

    suite.test("SRT and WebVTT: one cue per segment with correct timestamps") {
        var record = advisorRecord()
        record.segments.append(Fixture.segment(2, 3725.4, 3727.9, "s1", "Late <b>remark</b> & more"))
        record.segments.append(Fixture.segment(3, 3730, 3730, "me", "zero length"))
        record.segments.append(Fixture.segment(4, 3731, 3732, "me", "echo", flags: [.echoSuspect]))
        try expectEqual(TranscriptRenderer.srt(record), """
            1
            00:00:05,000 --> 00:00:09,000
            Nahian: So I was thinking…

            2
            00:00:21,000 --> 00:00:25,000
            Prof. Rahman: That's interesting…

            3
            01:02:05,400 --> 01:02:07,900
            Prof. Rahman: Late <b>remark</b> & more

            4
            01:02:10,000 --> 01:02:10,500
            Nahian: zero length

            """)
        try expectEqual(TranscriptRenderer.vtt(record), """
            WEBVTT

            00:00:05.000 --> 00:00:09.000
            Nahian: So I was thinking…

            00:00:21.000 --> 00:00:25.000
            Prof. Rahman: That's interesting…

            01:02:05.400 --> 01:02:07.900
            Prof. Rahman: Late &lt;b&gt;remark&lt;/b&gt; &amp; more

            01:02:10.000 --> 01:02:10.500
            Nahian: zero length

            """)
        record.segments = []
        try expectEqual(TranscriptRenderer.srt(record), "")
        try expectEqual(TranscriptRenderer.vtt(record), "WEBVTT\n")
    }

    suite.test("render(format:) covers every export format") {
        let record = advisorRecord()
        for format in ExportFormat.allCases {
            let data = try TranscriptRenderer.render(record, format: format)
            try expect(!data.isEmpty, format.rawValue)
        }
        try expectEqual(try TranscriptRenderer.render(record, format: .markdown), Data(TranscriptRenderer.markdown(record).utf8))
        try expectEqual(try TranscriptRenderer.render(record, format: .srt), Data(TranscriptRenderer.srt(record).utf8))
        let decoded = try JSONDecoder.kan.decode(CallRecord.self, from: try TranscriptRenderer.render(record, format: .json))
        try expectEqual(decoded.id, record.id)
        try expectEqual(decoded.segments, record.segments)
        let json = String(decoding: try TranscriptRenderer.json(record), as: UTF8.self)
        try expect(json.contains("\n  \"bookmarks\" : ["), "pretty-printed with sorted keys")
        try expectEqual(TranscriptRenderer.suggestedFileName(for: record, format: .srt),
                        "2026-11-14 1000 Advisor meeting – augmentation idea.srt")
    }

    suite.test("aiPrompt fills every placeholder") {
        var record = advisorRecord()
        record.notes = "Check the augmentation numbers"
        record.bookmarks = [Bookmark(time: 751, note: "key idea")]
        for template in PromptTemplate.defaults {
            let prompt = TranscriptRenderer.aiPrompt(record, template: template, userName: "Nahian")
            try expect(!prompt.contains("{{"), "\(template.id): \(prompt)")
            try expect(prompt.contains("[00:00:05] Nahian: So I was thinking…"), template.id)
            if template.body.contains("{{title}}") { try expect(prompt.contains("Advisor meeting – augmentation idea")) }
            if template.body.contains("{{participants}}") { try expect(prompt.contains("Nahian (me), Prof. Rahman")) }
            if template.body.contains("{{me}}") { try expect(prompt.contains("(Nahian)"), template.id) }
            if template.body.contains("{{duration}}") { try expect(prompt.contains("42 min")) }
            if template.body.contains("{{date}}") { try expect(prompt.contains("Sat 14 Nov 2026, 10:00–10:42")) }
            if template.body.contains("{{notes}}") { try expect(prompt.contains("My notes:\nCheck the augmentation numbers")) }
            try expect(!prompt.contains("\n\n\n"), template.id)
        }
        let custom = PromptTemplate(id: "x", name: "x", body: "{{ TITLE }} | {{tags}} | {{app}} | {{unknown}} | {{bookmarks}}")
        try expectEqual(TranscriptRenderer.aiPrompt(record, template: custom, userName: "Nahian"),
                        "Advisor meeting – augmentation idea | research, thesis | Zoom | {{unknown}} | Bookmarks:\n[00:12:31] key idea\n")
        record.notes = ""
        record.speakers[0].name = "Me"
        let raw = TranscriptRenderer.aiPrompt(record, template: PromptTemplate(id: "r", name: "r", body: "{{participants}}\n\n{{notes}}\n\n{{transcript}}"),
                                              userName: "নাহিয়ান")
        try expectEqual(raw, "নাহিয়ান (me), Prof. Rahman\n\n[00:00:05] নাহিয়ান: So I was thinking…\n[00:00:21] Prof. Rahman: That's interesting…\n")
    }

    suite.test("suggestedTitle: calendar > meeting title > app call with names > app call") {
        var record = advisorRecord()
        record.speakers = Fixture.speakers(others: ["Rahim", "Speaker 2", "Karim"])
        record.calendarEventTitle = "ASR sync"
        record.source.meetingTitle = "Meet – abc-defg-hij"
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "ASR sync")
        record.calendarEventTitle = "  "
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Meet – abc-defg-hij")
        record.source.meetingTitle = nil
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Zoom call with Rahim and Karim")
        record.speakers = Fixture.speakers(others: ["A", "B", "C"])
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Zoom call with A, B and C")
        record.speakers = Fixture.speakers(others: ["A", "B", "C", "D"])
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Zoom call with A, B, C and 1 other")
        record.speakers = Fixture.speakers(others: ["A", "B", "C", "D", "E"])
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Zoom call with A, B, C and 2 others")
        record.speakers = Fixture.speakers(others: ["Speaker 1"])
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Zoom call")
        record.source = CallSource(appName: "Zen", platform: .googleMeet)
        record.speakers = Fixture.speakers(others: ["Rahim"])
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Google Meet call with Rahim")
        record.source = CallSource(appName: "Zen", platform: .browser)
        record.speakers = []
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Zen call")
        record.source = CallSource(appName: "Microsoft Teams", platform: .teams)
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Microsoft Teams call")
        record.source = CallSource(appName: "Microphone", platform: .manual)
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Recording")
        record.source = CallSource(appName: "", platform: .imported)
        try expectEqual(TranscriptRenderer.suggestedTitle(for: record), "Imported audio")
    }

    suite.test("summary line: platform via another app, calls across midnight") {
        var record = advisorRecord()
        record.source = CallSource(appName: "Zen", platform: .googleMeet)
        record.startedAt = Fixture.date("2026-11-14T23:30:00-05:00")
        record.endedAt = Fixture.date("2026-11-15T00:15:00-05:00")
        try expectEqual(TranscriptRenderer.summaryLine(record),
                        "Sat 14 Nov 2026, 23:30–Sun 15 Nov 2026, 00:15 · Google Meet (Zen) · 45 min · Nahian (me), Prof. Rahman")
        record.speakers = []
        record.attendees = ["Rahim", "Karim"]
        try expect(TranscriptRenderer.summaryLine(record).hasSuffix("· 45 min · Rahim, Karim"))
    }

    suite.test("Markdown special characters in text and names are escaped") {
        var record = advisorRecord()
        record.speakers[1].name = "Dr. *Star* [PI]"
        record.segments = [Fixture.segment(0, 1, 2, "s1", "# not a heading"), Fixture.segment(1, 5, 6, "me", "1. not a list"),
                           Fixture.segment(2, 9, 10, "s1", "> not a quote")]
        let md = TranscriptRenderer.markdown(record)
        try expect(md.contains("**Dr. \\*Star\\* \\[PI\\]** [00:00:01]\n\\# not a heading"), md)
        try expect(md.contains("**Nahian** [00:00:05]\n1\\. not a list"), md)
        try expect(md.contains("\n\\> not a quote"), md)
    }

    return suite
}

extension String {
    /// What the front matter does to a title: whitespace and control characters collapse to one space.
    var singleLineForTest: String {
        var out = ""
        var pending = false
        for scalar in unicodeScalars {
            let isSpace = scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
            if isSpace {
                pending = !out.isEmpty
            } else {
                if pending { out += " " }
                pending = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}
