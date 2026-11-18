import Foundation
import KanAI
import KanCore
import KanTestKit

func responseTests() -> TestSuite {
    let suite = TestSuite("Responses")

    suite.test("title ideas: the message after a reasoning item, its output_text parts joined") {
        let json = OpenAIJSON.text(["titles": ["SpecAugment baseline for low-resource Bangla ASR",
                                               "Choosing a Bangla speech dataset", "Paper draft due Friday"]])
        let middle = json.index(json.startIndex, offsetBy: json.count / 2)
        let server = StubServer([.ok(OpenAIJSON.response([String(json[..<middle]), String(json[middle...])]))])
        let record = Fixtures.researchCall()
        let ideas = try await server.assistant().suggestTitles(for: record, options: Fixtures.options(model: "gpt-6-luna"))
        try expectEqual(ideas.titles, ["SpecAugment baseline for low-resource Bangla ASR", "Choosing a Bangla speech dataset",
                                       "Paper draft due Friday"])
        try expectEqual(ideas.model, "gpt-6-luna")
        try expectEqual(ideas.generatedAt, testNow)
        try expectEqual(ideas.fingerprint, CallInsights.fingerprint(of: record))
    }

    suite.test("title ideas are cleaned: one line, no quotes, markers or final period, no duplicates, at most 5") {
        let long = String(repeating: "Contrastive pretraining ", count: 8) + "for protein structures"
        let raw = [
            "\"Data augmentation for Bangla ASR.\"",
            "  SpecAugment   baseline\nfor low-resource   ASR  ",
            "data augmentation for bangla asr",
            "",
            "   ",
            "1. Thesis chapter timeline",
            "**Advisor feedback on chapter 3**",
            "“ডেটাসেট বাছাই।”",
            long,
            "Seventh title",
            "Eighth title",
        ]
        let server = StubServer([OpenAIJSON.titles(raw)])
        let ideas = try await server.assistant().suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(Array(ideas.titles.prefix(4)), [
            "Data augmentation for Bangla ASR",
            "SpecAugment baseline for low-resource ASR",
            "Thesis chapter timeline",
            "Advisor feedback on chapter 3",
        ])
        try expectEqual(ideas.titles.count, 5)
        try expectEqual(ideas.titles[4], "ডেটাসেট বাছাই")
        let cut = try expectNotNil(OpenAIAssistant.cleanTitles([long]).first)
        try expect(cut.count <= 100 && cut.hasSuffix("…") && !cut.contains("  "), cut)
        try expectEqual(OpenAIAssistant.cleanTitles(["Results...", "'Quoted'", "`Code`", "Plain"]),
                        ["Results...", "Quoted", "Code", "Plain"])
        // Marks go only when they wrap the whole title: two quoted terms keep theirs, balanced.
        let balanced = ["“ডেটাসেট” বনাম “মডেল”", "`a` vs `b`", "`torch.compile` vs `jax.jit`", "\"LoRA\" vs \"QLoRA\"",
                        "*Nature* vs *Science*", "**LoRA** vs **full fine-tuning**", "'Mamba' or 'Transformers'",
                        "“Attention” and “Mamba”", "_init_ cleanup and data_loader_"]
        // (One title at a time: at most 5 are kept.)
        try expectEqual(balanced.flatMap { OpenAIAssistant.cleanTitles([$0]) }, balanced)
        let wrapped = ["\"LoRA\" vs \"QLoRA\".", "**`torch.compile` speedups**", "***Bold italic***", "\"\"Doubled\"\"",
                       "'Rahman's feedback on chapter 3'", "‘Rahman’s idea’", "\"‘SpecAugment’ ablations\""]
        try expectEqual(wrapped.flatMap { OpenAIAssistant.cleanTitles([$0]) },
                        ["\"LoRA\" vs \"QLoRA\"", "`torch.compile` speedups", "Bold italic", "Doubled",
                         "Rahman's feedback on chapter 3", "Rahman’s idea", "‘SpecAugment’ ablations"])
        // NFC (String == ignores the difference, so compare scalars).
        let nfc = try expectNotNil(OpenAIAssistant.cleanTitles(["Cafe\u{0301} chat"]).first)
        try expectEqual(Array(nfc.unicodeScalars), Array("Caf\u{00E9} chat".unicodeScalars))
    }

    suite.test("summary: decoded, cleaned, with the model, date, language and fingerprint") {
        let server = StubServer([OpenAIJSON.summary(
            overview: "Nahian and Prof. Rahman planned a data augmentation baseline\nfor Bangla ASR.  ",
            keyPoints: ["- OpenSLR's Bangla set has about 200 hours [00:00:41]", "  ", "• Noise is a problem"],
            ideas: ["Speed perturbation + SpecAugment as a baseline (Prof. Rahman) [00:12:31]"],
            decisions: [],
            actionItems: ["Nahian: send the paper draft by Friday [00:40:00]"],
            openQuestions: ["1. How much compute is available?"])])
        let record = Fixtures.researchCall()
        let summary = try await server.assistant().summarize(record, options: Fixtures.options(.bangla, model: "gpt-6.1-sol"))
        try expectEqual(summary.overview, "Nahian and Prof. Rahman planned a data augmentation baseline for Bangla ASR.")
        try expectEqual(summary.keyPoints, ["OpenSLR's Bangla set has about 200 hours [00:00:41]", "Noise is a problem"])
        try expectEqual(summary.ideas, ["Speed perturbation + SpecAugment as a baseline (Prof. Rahman) [00:12:31]"])
        try expectEqual(summary.decisions, [])
        try expectEqual(summary.actionItems, ["Nahian: send the paper draft by Friday [00:40:00]"])
        try expectEqual(summary.openQuestions, ["How much compute is available?"])
        try expectEqual(summary.language, .bangla)
        try expectEqual(summary.model, "gpt-6.1-sol")
        try expectEqual(summary.generatedAt, testNow)
        try expectEqual(summary.fingerprint, CallInsights.fingerprint(of: record))
        try expect(!summary.shortened)
    }

    suite.test("summary: a Bangla answer stays NFC and keeps its joiners") {
        let overview = "নাহিয়ান আর প্রফেসর রহমান augmentation নিয়ে কথা বলেছেন।"
        let decomposed = overview.decomposedStringWithCanonicalMapping
        let zwnj = "র\u{200C}্যাব"
        let server = StubServer([OpenAIJSON.summary(overview: decomposed, keyPoints: [zwnj])])
        let summary = try await server.assistant().summarize(Fixtures.researchCall(), options: Fixtures.options(.bangla))
        try expectEqual(Array(summary.overview.unicodeScalars), Array(overview.precomposedStringWithCanonicalMapping.unicodeScalars))
        try expectEqual(summary.keyPoints, [zwnj])
    }

    suite.test("a refusal → .refused") {
        let server = StubServer([.ok(OpenAIJSON.response([], refusal: "I can't help with that."))])
        let error = try await expectAIError(.refused) {
            try await server.assistant().suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        try expect(!error.isTransient)
    }

    suite.test("status incomplete → .incomplete, even with some text") {
        let server = StubServer([
            .ok(OpenAIJSON.response(["{\"overview\": \"They plan"], status: "incomplete", incompleteReason: "max_output_tokens")),
            .ok(OpenAIJSON.response([], status: "incomplete", incompleteReason: "content_filter")),
        ])
        let assistant = try server.assistant()
        _ = try await expectAIError(.incomplete) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        _ = try await expectAIError(.incomplete) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        try expectEqual(server.requests.count, 2)
    }

    suite.test("text that isn't the requested JSON → .badResponse") {
        let replies: [StubReply] = [
            .ok(OpenAIJSON.response(["Here are some titles: Bangla ASR, datasets"])),
            .ok(OpenAIJSON.response([OpenAIJSON.text(["names": ["A title"]])])),
            .ok(OpenAIJSON.response([OpenAIJSON.text(["titles": "A title"])])),
            .ok(OpenAIJSON.response([])),
            .ok(Data("<html>Bad gateway</html>".utf8)),
            .ok(Data(#"{"object": "response", "status": "completed"}"#.utf8)),
            .ok(OpenAIJSON.response(["{}"], status: "in_progress")),
        ]
        let server = StubServer(replies)
        let assistant = try server.assistant()
        for _ in replies {
            let error = try await expectAIError(.badResponse) {
                try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
            }
            try expect(error.isTransient)
        }
        try expectEqual(server.requests.count, replies.count, "an unreadable 200 isn't retried")
    }

    suite.test("no usable title ideas → .badResponse") {
        let server = StubServer([OpenAIJSON.titles([]), OpenAIJSON.titles(["", "  \n", "\"\"", "**", "."])])
        let assistant = try server.assistant()
        _ = try await expectAIError(.badResponse) { try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options()) }
        _ = try await expectAIError(.badResponse) { try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options()) }
    }

    suite.test("a summary without an overview or any item → .badResponse") {
        let server = StubServer([
            .ok(OpenAIJSON.response([OpenAIJSON.text(["keyPoints": ["A point"]])])),
            OpenAIJSON.summary(overview: "  ", keyPoints: ["", " "]),
            OpenAIJSON.summary(overview: "", keyPoints: ["Only a point"]),
        ])
        let assistant = try server.assistant()
        _ = try await expectAIError(.badResponse) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        _ = try await expectAIError(.badResponse) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        let pointsOnly = try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(pointsOnly.overview, "")
        try expectEqual(pointsOnly.keyPoints, ["Only a point"])
    }

    suite.test("status failed maps its error code, billing and policy codes as for an HTTP error") {
        let cases: [(code: String, expected: AIError)] = [
            ("server_error", .server(status: 500)), ("rate_limit_exceeded", .rateLimited), ("something_new", .badResponse),
            ("insufficient_quota", .noCredit), ("credit_balance_exhausted", .noCredit),
            ("project_spend_limit_exceeded", .spendLimit), ("organization_usage_limit_exceeded", .spendLimit),
            ("invalid_prompt", .refused), ("bio_policy", .refused), ("misalignment_policy_violation", .refused),
            ("context_length_exceeded", .tooLong), ("model_not_found", .modelUnavailable("gpt-6.1-terra")),
        ]
        let server = StubServer(cases.map { .ok(OpenAIJSON.response([], status: "failed", error: ["code": $0.code, "message": "?"])) })
        let sleeper = SleepRecorder()
        let assistant = try server.assistant(sleeper: sleeper)
        for (code, expected) in cases {
            let error = try await expectAIError(expected) {
                try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
            }
            try expectEqual(error.isTransient, [.server(status: 500), .rateLimited, .badResponse].contains(expected), code)
        }
        // A billing stop named only by its type counts too.
        let typed = StubServer([.ok(OpenAIJSON.response([], status: "failed", error: ["type": "insufficient_quota", "message": "?"]))])
        _ = try await expectAIError(.noCredit) { try await typed.assistant().summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        try expectEqual(server.requests.count, cases.count, "a failed answer isn't retried")
        try expectEqual(sleeper.delays, [])
    }

    suite.test("JSON in a Markdown code fence is read, unknown items and fields are ignored") {
        let fenced = "```json\n" + OpenAIJSON.text(["titles": ["Fenced title"]]) + "\n```"
        var body = try expectNotNil((try? JSONSerialization.jsonObject(with: OpenAIJSON.response([fenced]))) as? [String: Any])
        var output = try expectNotNil(body["output"] as? [Any])
        output.insert(["type": "web_search_call", "id": "ws_1", "status": "completed", "content": "not a list"] as [String: Any], at: 0)
        output.append(["type": "message", "role": "assistant", "content": [["type": "output_audio", "data": "…"]]] as [String: Any])
        body["output"] = output
        body["something_new"] = ["nested": true]
        let server = StubServer([.ok(try JSONSerialization.data(withJSONObject: body))])
        let ideas = try await server.assistant().suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(ideas.titles, ["Fenced title"])
    }

    return suite
}
