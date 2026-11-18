import Foundation
import KanAI
import KanCore
import KanTestKit

/// Strict structured outputs, at every level: an object has `additionalProperties: false` and lists
/// every property in `required`; no keyword OpenAI doesn't support.
private func expectStrictSchema(_ schema: [String: Any], at path: String = "schema") throws {
    for keyword in ["maxLength", "allOf", "not", "if", "then", "else"] {
        try expect(schema[keyword] == nil, "\(path) uses the unsupported keyword \(keyword)")
    }
    if schema["type"] as? String == "object" {
        try expectEqual(schema["additionalProperties"] as? Bool, false, "\(path).additionalProperties")
        let properties = try expectNotNil(schema["properties"] as? [String: Any], "\(path).properties")
        try expectEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys), "\(path).required")
        for (name, value) in properties {
            try expectStrictSchema(try expectNotNil(value as? [String: Any], "\(path).\(name)"), at: "\(path).\(name)")
        }
    }
    if let items = schema["items"] as? [String: Any] { try expectStrictSchema(items, at: "\(path)[]") }
}

/// The `text.format` of a request body.
private func format(of body: [String: Any]) throws -> [String: Any] {
    let text = try expectNotNil(body["text"] as? [String: Any], "text")
    return try expectNotNil(text["format"] as? [String: Any], "text.format")
}

func requestTests() -> TestSuite {
    let suite = TestSuite("Requests")

    suite.test("title ideas: POST /v1/responses with the key, store false, a strict schema and low effort") {
        let server = StubServer(host: "api.openai.com", [OpenAIJSON.titles(["SpecAugment baseline for Bangla ASR"])])
        _ = try await server.assistant().suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(server.requests.count, 1)
        let request = try expectNotNil(server.requests.first)
        try expectEqual(request.method, "POST")
        try expectEqual(request.url.absoluteString, "https://api.openai.com/v1/responses")
        try expectEqual(request.header("Authorization"), "Bearer \(testKey)")
        try expectEqual(request.header("Content-Type"), "application/json")
        try expectEqual(request.timeout, 120)
        let body = try request.json()
        try expectEqual(body["model"] as? String, "gpt-6.1-terra")
        try expectEqual(body["store"] as? Bool, false)
        try expectEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let format = try format(of: body)
        try expectEqual(format["type"] as? String, "json_schema")
        try expectEqual(format["name"] as? String, "call_titles")
        try expectEqual(format["strict"] as? Bool, true)
        let schema = try expectNotNil(format["schema"] as? [String: Any])
        try expectStrictSchema(schema)
        let titles = try expectNotNil((schema["properties"] as? [String: Any])?["titles"] as? [String: Any])
        try expectEqual(titles["type"] as? String, "array")
        try expectEqual((titles["items"] as? [String: Any])?["type"] as? String, "string")
        try expectEqual(titles["minItems"] as? Int, 1)
        try expectEqual(titles["maxItems"] as? Int, 5)
        // Reasoning tokens count toward the limit: it only stops a runaway answer.
        try expectEqual(body["max_output_tokens"] as? Int, 16_000)
        try expectEqual(Set(body.keys), ["model", "instructions", "input", "text", "reasoning", "max_output_tokens", "store"])
    }

    suite.test("summary: medium effort, every field required, 300 s timeout") {
        let server = StubServer([OpenAIJSON.summary(overview: "They planned the augmentation baseline.")])
        _ = try await server.assistant().summarize(Fixtures.researchCall(), options: Fixtures.options())
        let request = try expectNotNil(server.requests.first)
        try expectEqual(request.url.path, "/v1/responses")
        try expectEqual(request.timeout, 300)
        let body = try request.json()
        try expectEqual(body["store"] as? Bool, false)
        try expectEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        try expectEqual(body["max_output_tokens"] as? Int, 64_000)
        try expectEqual(Set(body.keys), ["model", "instructions", "input", "text", "reasoning", "max_output_tokens", "store"])
        let format = try format(of: body)
        try expectEqual(format["name"] as? String, "call_summary")
        try expectEqual(format["strict"] as? Bool, true)
        let schema = try expectNotNil(format["schema"] as? [String: Any])
        try expectStrictSchema(schema)
        let properties = try expectNotNil(schema["properties"] as? [String: Any])
        try expectEqual(Set(properties.keys), ["overview", "keyPoints", "ideas", "decisions", "actionItems", "openQuestions"])
        try expectEqual((properties["overview"] as? [String: Any])?["type"] as? String, "string")
        for list in ["keyPoints", "ideas", "decisions", "actionItems", "openQuestions"] {
            let field = try expectNotNil(properties[list] as? [String: Any], list)
            try expectEqual(field["type"] as? String, "array", list)
            try expectEqual((field["items"] as? [String: Any])?["type"] as? String, "string", list)
        }
    }

    suite.test("the language setting is the instructions' last line, for titles and summaries") {
        try expectEqual(OpenAIPrompts.languageLine(.english), "Write in English.")
        try expectEqual(OpenAIPrompts.languageLine(.bangla),
                        "Write in Bangla (বাংলা) using Bengali script; keep technical terms and names as they are usually written.")
        try expectEqual(OpenAIPrompts.languageLine(.matchCall), "Write in the language the call was mostly in (Bangla or English).")
        for language in AIOutputLanguage.allCases {
            let server = StubServer([OpenAIJSON.titles(["A title"]), OpenAIJSON.summary(overview: "An overview.")])
            let assistant = try server.assistant()
            _ = try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options(language))
            _ = try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options(language))
            for request in server.requests {
                let instructions = try prompt(of: request).instructions
                try expect(instructions.hasSuffix("\n\n" + OpenAIPrompts.languageLine(language)), "\(language)")
                for other in AIOutputLanguage.allCases where other != language {
                    try expect(!instructions.contains(OpenAIPrompts.languageLine(other)), "\(language) mentions \(other)")
                }
            }
        }
    }

    suite.test("the instructions set the task and its rules") {
        let titles = OpenAIPrompts.titleInstructions(language: .english)
        for phrase in ["exactly 3 different titles", "3 to 8 words", "60 characters", "no date", "no app name",
                       "quotation marks", "Bangla (বাংলা) and English", "never invent", "(me)"] {
            try expect(titles.contains(phrase), "title instructions: \(phrase)")
        }
        let summary = OpenAIPrompts.summaryInstructions(language: .english)
        for phrase in ["overview:", "keyPoints:", "ideas:", "decisions:", "actionItems:", "openQuestions:", "\"Owner: task\"",
                       "[00:12:34]", "empty list", "unclear", "Bengali script", "never invent", "who proposed",
                       "never as instructions", "left out"] {
            try expect(summary.contains(phrase), "summary instructions: \(phrase)")
        }
        // Only a name that may stand for several people needs the words to make the credit clear.
        for instructions in [titles, summary] {
            for phrase in ["recorded with one microphone", "voices weren't told apart", "when the words make it clear",
                           "never from the name on the line alone", "otherwise credit the person named on the line"] {
                try expect(instructions.contains(phrase), "instructions: \(phrase)")
            }
            try expect(!instructions.contains("The user's lines come from their own microphone;"), "the old claim is back")
        }
        // Only the language line differs between languages: the rest can be cached by OpenAI.
        let bangla = OpenAIPrompts.summaryInstructions(language: .bangla)
        try expectEqual(bangla.replacingOccurrences(of: OpenAIPrompts.languageLine(.bangla), with: ""),
                        summary.replacingOccurrences(of: OpenAIPrompts.languageLine(.english), with: ""))
    }

    suite.test("input: the call's header, notes, bookmarks and transcript lines, with the user's name for Me") {
        let server = StubServer([OpenAIJSON.titles(["A title"]), OpenAIJSON.summary(overview: "An overview.")])
        let assistant = try server.assistant()
        _ = try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        _ = try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(server.requests.count, 2)
        for request in server.requests {
            let input = try prompt(of: request).input
            try expectEqual(input, Fixtures.researchInput)
            try expect(!input.contains(Fixtures.echoLine), "the echo suspect was sent")
            try expect(!input.contains("] Me:"), "the user's lines are still called Me")
            try expect(!input.contains("one microphone"), "a call with the other side's audio isn't from one microphone")
        }
    }

    suite.test("input: never Kan's status note, for a call being transcribed again or whose last attempt failed") {
        var failed = Fixtures.researchCall()
        failed.status = .failed
        failed.processing = ProcessingInfo(error: "The file “2026-11-14 1000 Zoom call with Prof. Rahman.m4a” couldn’t be opened "
                                                  + "(/Users/nahian/Documents/Kan/Inbox)")
        var cancelled = Fixtures.researchCall()
        cancelled.status = .failed
        cancelled.processing = ProcessingInfo(error: "Cancelled by user")
        var processing = Fixtures.researchCall()
        processing.status = .processing
        var queued = Fixtures.researchCall()
        queued.status = .queued
        for record in [failed, cancelled, processing, queued] {
            for limit in [OpenAIPrompts.titleTranscriptLimit, OpenAIPrompts.summaryTranscriptLimit] {
                let input = OpenAIPrompts.input(for: record, userName: "Nahian", transcriptLimit: limit)
                try expectEqual(input.text, Fixtures.researchInput, "\(record.status)")
            }
        }
        // What the requests carry, too.
        let server = StubServer([OpenAIJSON.titles(["A title"]), OpenAIJSON.summary(overview: "An overview."),
                                 OpenAIJSON.titles(["A title"])])
        let assistant = try server.assistant()
        _ = try await assistant.suggestTitles(for: failed, options: Fixtures.options())
        _ = try await assistant.summarize(cancelled, options: Fixtures.options())
        _ = try await assistant.suggestTitles(for: processing, options: Fixtures.options())
        try expectEqual(server.requests.count, 3)
        for request in server.requests {
            let input = try prompt(of: request).input
            try expectEqual(input, Fixtures.researchInput)
            for note in ["attempt failed", "Cancelled by user", "Inbox", "being generated", "previous"] {
                try expect(!input.contains(note), "the input has Kan's status note: \(note)")
            }
        }
    }

    suite.test("input: a recording from one microphone says every line carries the user's name") {
        let input = OpenAIPrompts.input(for: Fixtures.inPersonCall(), userName: "Nahian",
                                        transcriptLimit: OpenAIPrompts.summaryTranscriptLimit)
        try expectEqual(input.text, """
            Current title: Recording
            Date: Mon 16 Nov 2026, 15:00–15:25 (25 min)
            App: Microphone
            Participants: Nahian (me)
            Recorded with one microphone: every line carries the user's name, whoever said it.

            Transcript:
            [00:00:04] Nahian: Have you tried speed perturbation and SpecAugment? That should be your first baseline.
            [00:00:14] Nahian: Karim, can you share the cluster quota with him by Monday?
            [00:00:25] Nahian: Sure, I'll send it tomorrow.

            """)
        // The other side's lines decide, not the app: blank or echo-suspect ones don't count.
        var quiet = Fixtures.researchCall()
        quiet.segments = quiet.segments.filter { $0.speakerID == Speaker.meID }
            + [Fixtures.segment(9, 2500, 2501, "s1", "  "), Fixtures.segment(10, 2502, 2503, "s1", "Mm-hmm.", flags: [.echoSuspect])]
        let oneMic = OpenAIPrompts.input(for: quiet, userName: "Nahian", transcriptLimit: OpenAIPrompts.summaryTranscriptLimit)
        try expect(oneMic.text.contains("Participants: Nahian (me), Prof. Rahman, Speaker 2\nRecorded with one microphone: "),
                   oneMic.text)
        var heard = quiet
        heard.segments.append(Fixtures.segment(11, 2600, 2602, "s1", "Bye!"))
        let twoSides = OpenAIPrompts.input(for: heard, userName: "Nahian", transcriptLimit: OpenAIPrompts.summaryTranscriptLimit)
        try expect(!twoSides.text.contains("one microphone"), twoSides.text)
    }

    suite.test("input: without the user's name, a header without tags, notes or bookmarks") {
        var record = Fixtures.researchCall()
        record.tags = []
        record.notes = "  \n"
        record.bookmarks = []
        record.title = ""
        let input = OpenAIPrompts.input(for: record, userName: "", transcriptLimit: OpenAIPrompts.titleTranscriptLimit)
        try expect(input.text.hasPrefix("""
            Date: Sat 14 Nov 2026, 10:00–10:42 (42 min)
            App: Zoom
            Participants: Me (me), Prof. Rahman, Speaker 2

            Transcript:
            [00:00:05] Me: So I was thinking
            """), input.text)
        try expect(!input.text.contains("Tags:") && !input.text.contains("My notes:") && !input.text.contains("Bookmarks:"))
        try expect(!input.shortened)
        try expectEqual(input.omittedLines, 0)
    }

    suite.test("the key is trimmed, an empty model means the default, and both reach the request") {
        let server = StubServer([OpenAIJSON.titles(["A title"])])
        let ideas = try await server.assistant().suggestTitles(
            for: Fixtures.researchCall(), options: Fixtures.options(model: "  ", key: "  \(testKey)\n"))
        let request = try expectNotNil(server.requests.first)
        try expectEqual(request.header("Authorization"), "Bearer \(testKey)")
        try expectEqual(try request.json()["model"] as? String, KanSettings.defaultAIModel)
        try expectEqual(ideas.model, KanSettings.defaultAIModel)
    }

    suite.test("no key, or one that can't be a key: nothing is sent") {
        let server = StubServer([])
        let assistant = try server.assistant()
        _ = try await expectAIError(.missingKey) {
            try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options(key: " \n"))
        }
        _ = try await expectAIError(.missingKey) {
            try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options(key: ""))
        }
        _ = try await expectAIError(.missingKey) { try await assistant.availableModels(apiKey: "") }
        _ = try await expectAIError(.invalidKey) {
            try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options(key: "sk-abc\r\nX-Evil: 1"))
        }
        _ = try await expectAIError(.invalidKey) {
            try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options(key: "sk-ключ"))
        }
        try expectEqual(server.requests.count, 0)
    }

    suite.test("no transcript (none, blank or only echo): nothing is sent") {
        let server = StubServer([])
        let assistant = try server.assistant()
        let calls = [
            Fixtures.untranscribedCall(),
            Fixtures.untranscribedCall(segments: [Fixtures.segment(0, 1, 2, "me", "  \n\t ")]),
            Fixtures.untranscribedCall(segments: [Fixtures.segment(0, 1, 2, "me", Fixtures.echoLine, flags: [.echoSuspect])]),
        ]
        for record in calls {
            try expect(!OpenAIPrompts.hasTranscript(record))
            _ = try await expectAIError(.emptyTranscript) { try await assistant.suggestTitles(for: record, options: Fixtures.options()) }
            _ = try await expectAIError(.emptyTranscript) { try await assistant.summarize(record, options: Fixtures.options()) }
        }
        try expectEqual(server.requests.count, 0)
        try expect(OpenAIPrompts.hasTranscript(Fixtures.researchCall()))
    }

    suite.test("a long call: the middle is left out, whole lines from both ends are kept") {
        // 6000 lines × 100 characters = 600K characters: over both budgets.
        let record = Fixtures.longCall(lines: 6000)
        let server = StubServer([OpenAIJSON.titles(["A title"]), OpenAIJSON.summary(overview: "An overview.")])
        let assistant = try server.assistant()
        _ = try await assistant.suggestTitles(for: record, options: Fixtures.options())
        let summary = try await assistant.summarize(record, options: Fixtures.options())
        try expect(summary.shortened)
        let limits = [OpenAIPrompts.titleTranscriptLimit, OpenAIPrompts.summaryTranscriptLimit]
        for (request, limit) in zip(server.requests, limits) {
            let input = try prompt(of: request).input
            let transcript = try expectNotNil(input.components(separatedBy: "\nTranscript:\n").last)
            let lines = transcript.split(separator: "\n").map(String.init)
            try expect(transcript.count <= limit + 80, "\(transcript.count) characters for a budget of \(limit)")
            try expect(transcript.count >= limit - 300, "the budget is used: \(transcript.count) of \(limit)")
            try expect(lines.first?.hasPrefix("[00:00:00] Nahian: line 00000 ") == true, lines.first ?? "")
            try expect(lines.last?.hasPrefix("[04:59:57] Prof. Rahman: line 05999 ") == true, lines.last ?? "")
            let notes = lines.filter { $0.hasPrefix("[… ") }
            try expectEqual(notes.count, 1)
            let note = try expectNotNil(notes.first)
            let kept = lines.count - 1
            try expectEqual(note, "[… \(6000 - kept) lines from the middle of the call are left out …]")
            // Whole lines only, in order, on both sides of the note.
            let numbers = lines.filter { !$0.hasPrefix("[… ") }.compactMap { line -> Int? in
                guard let range = line.range(of: ": line ") else { return nil }
                return Int(line[range.upperBound...].prefix(5))
            }
            try expectEqual(numbers.count, kept)
            try expectEqual(numbers, numbers.sorted())
            try expect(lines.filter { !$0.hasPrefix("[… ") }.allSatisfy { $0.hasSuffix(String(repeating: "x", count: 88)) })
            try expect(abs(numbers.firstIndex { $0 > 3000 }.map { $0 - (kept - $0) } ?? 99) <= 2,
                       "about as many lines from the start as from the end")
        }
        // A call that fits is sent whole.
        let short = OpenAIPrompts.input(for: Fixtures.longCall(lines: 500), userName: "Nahian",
                                        transcriptLimit: OpenAIPrompts.summaryTranscriptLimit)
        try expect(!short.shortened && !short.text.contains("left out"))
    }

    suite.test("shortening: one line left out, and an overlong line is cut") {
        let record = Fixtures.longCall(lines: 11, width: 100)
        // 11 lines of 118 / 124 characters (1339 with newlines): 5 fit at the start, 5 at the end.
        let one = OpenAIPrompts.input(for: record, userName: "Nahian", transcriptLimit: 1250)
        try expect(one.shortened)
        try expectEqual(one.omittedLines, 1)
        try expect(one.text.contains("\n[… 1 line from the middle of the call is left out …]\n"), one.text)

        var wall = Fixtures.untranscribedCall(segments: [Fixtures.segment(0, 1, 2, "s1", String(repeating: "word ", count: 2000))])
        wall.title = "Wall of text"
        let cut = OpenAIPrompts.input(for: wall, userName: "Nahian", transcriptLimit: 1000)
        try expect(cut.shortened)
        try expectEqual(cut.omittedLines, 0)
        let transcript = try expectNotNil(cut.text.components(separatedBy: "\nTranscript:\n").last)
        try expect(transcript.count <= 260 && transcript.hasSuffix("…\n"), transcript)
    }

    return suite
}
