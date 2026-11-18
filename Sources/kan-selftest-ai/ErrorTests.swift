import Foundation
import KanAI
import KanCore
import KanTestKit

/// OpenAI's 401 message quotes part of the key; Kan must never keep it.
private let keyQuotingMessage = "Incorrect API key provided: sk-proj-KanS************************WXYZ. You can find your API key at https://platform.openai.com/account/api-keys."

func errorTests() -> TestSuite {
    let suite = TestSuite("Errors")

    suite.test("401 → .invalidKey, not retried") {
        let server = StubServer([OpenAIJSON.error(401, type: "invalid_request_error", code: "invalid_api_key", message: keyQuotingMessage)])
        let sleeper = SleepRecorder()
        let error = try await expectAIError(.invalidKey) {
            try await server.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        try expectEqual(server.requests.count, 1)
        try expectEqual(sleeper.delays, [])
        try expect(!error.isTransient)
    }

    suite.test("429 billing stops, by error code first: no credit or a spend limit, never retried") {
        // OpenAI: inspect `code` for billing errors; `type` can still be insufficient_quota.
        let cases: [(type: String?, code: String?, expected: AIError)] = [
            ("insufficient_quota", "insufficient_quota", .noCredit),
            ("insufficient_quota", nil, .noCredit),
            ("insufficient_quota", "credit_balance_exhausted", .noCredit),
            ("invalid_request_error", "credit_balance_exhausted", .noCredit),
            ("billing_not_active", nil, .noCredit),
            ("invalid_request_error", "billing_not_active", .noCredit),
            ("insufficient_quota", "organization_spend_limit_exceeded", .spendLimit),
            ("insufficient_quota", "project_spend_limit_exceeded", .spendLimit),
            ("insufficient_quota", "organization_usage_limit_exceeded", .spendLimit),
            ("invalid_request_error", "project_spend_limit_exceeded", .spendLimit),
            (nil, "organization_usage_limit_exceeded", .spendLimit),
        ]
        for (type, code, expected) in cases {
            let server = StubServer([OpenAIJSON.error(429, type: type, code: code,
                                                      message: "You exceeded your current quota, please check your plan and billing details.")])
            let sleeper = SleepRecorder()
            let error = try await expectAIError(expected) {
                try await server.assistant(sleeper: sleeper).summarize(Fixtures.researchCall(), options: Fixtures.options())
            }
            let name = "code \(code ?? "null"), type \(type ?? "null")"
            try expectEqual(server.requests.count, 1, name)
            try expectEqual(sleeper.delays, [], name)
            try expect(!error.isTransient, name)
        }
        try expect(AIError.spendLimit.message.contains("spend or usage limit") && AIError.spendLimit.message.contains("Limits"))
        try expectEqual(AIError.spendLimit.logDescription, "spend limit (429)")
    }

    suite.test("429 rate limit: retried twice, honoring Retry-After") {
        let limited = { (headers: [String: String]) in
            OpenAIJSON.error(429, type: "requests", code: "rate_limit_exceeded", message: "Rate limit reached for requests.",
                             headers: headers)
        }
        let server = StubServer([limited(["Retry-After": "7"]), limited([:]), OpenAIJSON.titles(["Third time lucky"])])
        let sleeper = SleepRecorder()
        let ideas = try await server.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(ideas.titles, ["Third time lucky"])
        try expectEqual(server.requests.count, 3)
        try expectEqual(sleeper.delays, [7, 6])

        // retry-after-ms and an HTTP date work too; a 429 without a code is a rate limit.
        let still = StubServer([limited(["retry-after-ms": "1500"]), limited(["Retry-After": "Tue, 17 Nov 2026 17:00:20 GMT"]),
                                OpenAIJSON.error(429, type: nil, code: nil)])
        let sleeper2 = SleepRecorder()
        let error = try await expectAIError(.rateLimited) {
            try await still.assistant(sleeper: sleeper2).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        try expectEqual(still.requests.count, 3)
        try expectEqual(sleeper2.delays, [1.5, 20])
        try expect(error.isTransient)
    }

    suite.test("Retry-After over 30 s: the error at once, never a retry sooner than the server asked") {
        let limited = { (headers: [String: String]) in
            OpenAIJSON.error(429, type: "tokens", code: "rate_limit_exceeded", message: "Rate limit reached for tokens.", headers: headers)
        }
        let replies: [(StubReply, AIError)] = [
            (limited(["Retry-After": "120"]), .rateLimited),
            (limited(["retry-after-ms": "56000"]), .rateLimited),
            (limited(["Retry-After": "Tue, 17 Nov 2026 17:05:00 GMT"]), .rateLimited),
            (OpenAIJSON.error(503, type: "server_error", code: "server_is_overloaded", headers: ["Retry-After": "31"]), .server(status: 503)),
        ]
        for (reply, expected) in replies {
            let server = StubServer([reply, OpenAIJSON.titles(["Too early"])])
            let sleeper = SleepRecorder()
            let error = try await expectAIError(expected) {
                try await server.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
            }
            try expectEqual(server.requests.count, 1, "\(expected)")
            try expectEqual(sleeper.delays, [], "\(expected)")
            try expect(error.isTransient)
        }
        // 30 s is still waited out.
        let thirty = StubServer([limited(["Retry-After": "30"]), OpenAIJSON.titles(["Waited"])])
        let sleeper = SleepRecorder()
        let ideas = try await thirty.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(ideas.titles, ["Waited"])
        try expectEqual(sleeper.delays, [30])
    }

    suite.test("500 then success: one retry after 2 s") {
        let server = StubServer([OpenAIJSON.error(500, type: "server_error", code: nil, message: "The server had an error."),
                                 OpenAIJSON.summary(overview: "Recovered.")])
        let sleeper = SleepRecorder()
        let summary = try await server.assistant(sleeper: sleeper).summarize(Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(summary.overview, "Recovered.")
        try expectEqual(server.requests.count, 2)
        try expectEqual(sleeper.delays, [2])
        // The retry sends the same request.
        try expectEqual(server.requests[0].body, server.requests[1].body)
    }

    suite.test("5xx that doesn't pass → .server(status), after two retries; other statuses aren't retried") {
        for status in [500, 502, 503, 504] {
            let failing = { OpenAIJSON.error(status, type: nil, code: nil, message: "Service unavailable.", headers: ["Retry-After": "1"]) }
            let server = StubServer([failing(), failing(), failing()])
            let sleeper = SleepRecorder()
            let error = try await expectAIError(.server(status: status)) {
                try await server.assistant(sleeper: sleeper).summarize(Fixtures.researchCall(), options: Fixtures.options())
            }
            try expectEqual(server.requests.count, 3, "HTTP \(status)")
            try expectEqual(sleeper.delays, [1, 1], "HTTP \(status)")
            try expect(error.isTransient, "HTTP \(status)")
        }

        for status in [501, 400, 409, 422] {
            let once = StubServer([OpenAIJSON.error(status, type: "invalid_request_error", code: nil)])
            _ = try await expectAIError(.server(status: status)) {
                try await once.assistant().summarize(Fixtures.researchCall(), options: Fixtures.options())
            }
            try expectEqual(once.requests.count, 1, "HTTP \(status)")
        }
    }

    suite.test("model_not_found → .modelUnavailable(model)") {
        let server = StubServer([
            OpenAIJSON.error(404, type: "invalid_request_error", code: "model_not_found", param: "model",
                             message: "The model `gpt-9` does not exist or you do not have access to it."),
            OpenAIJSON.error(400, type: "invalid_request_error", code: "model_not_found"),
            OpenAIJSON.error(403, type: "invalid_request_error", code: nil, param: "model"),
        ])
        let assistant = try server.assistant()
        for _ in 0..<3 {
            let error = try await expectAIError(.modelUnavailable("gpt-9")) {
                try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options(model: "gpt-9"))
            }
            try expect(error.message.contains("gpt-9"))
        }
        try expectEqual(server.requests.count, 3)
    }

    suite.test("context_length_exceeded → .tooLong; 403 → .notAllowed") {
        let server = StubServer([
            OpenAIJSON.error(400, type: "invalid_request_error", code: "context_length_exceeded", param: "input"),
            OpenAIJSON.error(403, type: "invalid_request_error", code: "unsupported_country_region_territory",
                             message: "Country, region, or territory not supported"),
            OpenAIJSON.error(403, type: "invalid_request_error", code: nil, message: "Project does not have access."),
        ])
        let assistant = try server.assistant()
        _ = try await expectAIError(.tooLong) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        _ = try await expectAIError(.notAllowed) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        _ = try await expectAIError(.notAllowed) { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        try expectEqual(server.requests.count, 3)
    }

    suite.test("401 missing_scope (a restricted key) → .notAllowed, on /responses and /models; other 401s → .invalidKey") {
        let missingScope = {
            OpenAIJSON.error(401, type: "invalid_request_error", code: "missing_scope",
                             message: "You have insufficient permissions for this operation. Missing scopes: api.responses.write.")
        }
        let server = StubServer([
            missingScope(), missingScope(),
            OpenAIJSON.error(401, type: "invalid_request_error", code: nil, message: keyQuotingMessage),
            OpenAIJSON.error(401, type: "invalid_request_error", code: "invalid_api_key", message: keyQuotingMessage),
        ])
        let sleeper = SleepRecorder()
        let assistant = try server.assistant(sleeper: sleeper)
        let error = try await expectAIError(.notAllowed) {
            try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
        }
        _ = try await expectAIError(.notAllowed) { try await assistant.availableModels(apiKey: testKey) }
        _ = try await expectAIError(.invalidKey) {
            try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        _ = try await expectAIError(.invalidKey) { try await assistant.availableModels(apiKey: testKey) }
        try expectEqual(server.requests.map(\.url.path), ["/v1/responses", "/v1/models", "/v1/responses", "/v1/models"])
        try expectEqual(sleeper.delays, [])
        try expect(!error.isTransient)
        try expectEqual(error.logDescription, "not allowed")
    }

    suite.test("400 invalid_prompt (OpenAI's safety checks) → .refused, not retried") {
        let server = StubServer([
            OpenAIJSON.error(400, type: "invalid_request_error", code: "invalid_prompt",
                             message: "Invalid prompt: your prompt was flagged as potentially violating our usage policy."),
            OpenAIJSON.summary(overview: "Never"),
        ])
        let sleeper = SleepRecorder()
        let error = try await expectAIError(.refused) {
            try await server.assistant(sleeper: sleeper).summarize(Fixtures.researchCall(), options: Fixtures.options())
        }
        try expectEqual(server.requests.count, 1)
        try expectEqual(sleeper.delays, [])
        try expect(!error.isTransient)
    }

    suite.test("400 about reasoning → one more try without the reasoning field") {
        let server = StubServer([
            OpenAIJSON.error(400, type: "invalid_request_error", code: "unsupported_parameter", param: "reasoning.effort",
                             message: "Unsupported parameter: 'reasoning.effort' is not supported with this model."),
            OpenAIJSON.titles(["Without reasoning"]),
        ])
        let sleeper = SleepRecorder()
        let ideas = try await server.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(ideas.titles, ["Without reasoning"])
        try expectEqual(server.requests.count, 2)
        try expect(try server.requests[0].json()["reasoning"] != nil)
        let retry = try server.requests[1].json()
        try expect(retry["reasoning"] == nil, "the retry still has reasoning")
        try expectEqual(retry["store"] as? Bool, false)
        try expectEqual(sleeper.delays, [])

        // Only once: a second refusal of the same kind is an error.
        let twice = StubServer([
            OpenAIJSON.error(400, type: "invalid_request_error", code: "unsupported_value", param: "reasoning"),
            OpenAIJSON.error(400, type: "invalid_request_error", code: "unsupported_value", param: "reasoning"),
        ])
        _ = try await expectAIError(.server(status: 400)) {
            try await twice.assistant().summarize(Fixtures.researchCall(), options: Fixtures.options())
        }
        try expectEqual(twice.requests.count, 2)
    }

    suite.test("400 about max_output_tokens → one more try without it, after the reasoning one too") {
        let tooMany = {
            OpenAIJSON.error(400, type: "invalid_request_error", code: "invalid_value", param: "max_output_tokens",
                             message: "max_output_tokens is too large: 64000. This model supports at most 16384 output tokens.")
        }
        let server = StubServer([
            OpenAIJSON.error(400, type: "invalid_request_error", code: "unsupported_parameter", param: "reasoning.effort"),
            tooMany(),
            OpenAIJSON.summary(overview: "An older model."),
        ])
        let sleeper = SleepRecorder()
        let summary = try await server.assistant(sleeper: sleeper).summarize(Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(summary.overview, "An older model.")
        let bodies = try server.requests.map { try $0.json() }
        try expectEqual(bodies.map { $0["reasoning"] != nil }, [true, false, false])
        try expectEqual(bodies.map { $0["max_output_tokens"] as? Int }, [64_000, 64_000, nil])
        try expectEqual(bodies.map { $0["input"] as? String }, Array(repeating: Fixtures.researchInput, count: 3))
        try expectEqual(sleeper.delays, [])

        // Only once.
        let twice = StubServer([tooMany(), tooMany()])
        _ = try await expectAIError(.server(status: 400)) {
            try await twice.assistant().suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        try expectEqual(twice.requests.count, 2)
    }

    suite.test("a model id that can't be one (an API key in the model field…) → .modelUnavailable(\"?\"), nothing sent") {
        let server = StubServer([OpenAIJSON.titles(["A fine-tuned title"])])
        let assistant = try server.assistant()
        let legacyKey = "sk-" + String(repeating: "Ab3x", count: 12)
        let odd = [testKey, legacyKey, "SK-\(testKey.dropFirst(3))", "gpt 6", "gpt-6/terra", "gpt-6.1\u{200B}-terra",
                   "gpt-6.1-terra\u{FEFF}", "ডেটাসেট", "gpt-6;drop", "gpt-6\nterra", String(repeating: "g", count: 129)]
        for model in odd {
            let error = try await expectAIError(.modelUnavailable("?")) {
                try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options(model: model))
            }
            try expect(!error.message.contains(model) && !error.logDescription.contains(model), model)
            try expect(!error.message.contains("sk-") && !error.logDescription.contains("sk-"), model)
            _ = try await expectAIError(.modelUnavailable("?")) {
                try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options(model: model))
            }
            try expect(!OpenAIModels.isWellFormedID(model), model)
        }
        try expectEqual(server.requests.count, 0)
        try expectEqual(AIError.modelUnavailable("?").logDescription, "model unavailable (?)")

        for model in ["gpt-6.1-terra", "gpt-6.1-sol-2026-10-01", "o4-mini", "GPT-6-Luna", "ft:gpt-4o-mini:org::abc123",
                      " gpt-6-luna ", String(repeating: "g", count: 128)] {
            try expect(OpenAIModels.isWellFormedID(model), model)
        }
        let ideas = try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options(model: "ft:gpt-4o-mini:org::abc123"))
        try expectEqual(ideas.model, "ft:gpt-4o-mini:org::abc123")
        try expectEqual(try server.requests.first?.json()["model"] as? String, "ft:gpt-4o-mini:org::abc123")
    }

    suite.test("offline and timeouts aren't retried; dropped connections are") {
        for (code, expected) in [(URLError.Code.notConnectedToInternet, AIError.offline), (.dataNotAllowed, .offline),
                                 (.internationalRoamingOff, .offline), (.timedOut, .timedOut),
                                 (.secureConnectionFailed, .network(code: URLError.Code.secureConnectionFailed.rawValue))] {
            let server = StubServer([.failure(code)])
            let sleeper = SleepRecorder()
            _ = try await expectAIError(expected) {
                try await server.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
            }
            try expectEqual(server.requests.count, 1, "\(code)")
            try expectEqual(sleeper.delays, [], "\(code)")
        }

        let dropped = StubServer([.failure(.networkConnectionLost), .failure(.cannotConnectToHost), OpenAIJSON.titles(["Back online"])])
        let sleeper = SleepRecorder()
        let ideas = try await dropped.assistant(sleeper: sleeper).suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        try expectEqual(ideas.titles, ["Back online"])
        try expectEqual(sleeper.delays, [2, 6])

        let gone = StubServer([.failure(.cannotFindHost), .failure(.dnsLookupFailed), .failure(.cannotFindHost)])
        _ = try await expectAIError(.network(code: URLError.Code.cannotFindHost.rawValue)) {
            try await gone.assistant().suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        try expectEqual(gone.requests.count, 3)
    }

    suite.test("cancelled while OpenAI is answering → CancellationError, not an AIError") {
        let server = StubServer([.hang])
        let assistant = try server.assistant()
        let task = Task { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) }
        try await server.waitForRequests(1)
        task.cancel()
        let started = Date()
        switch await task.result {
        case .success: throw fail("a cancelled request returned a summary")
        case .failure(let error): try expect(error is CancellationError, "got \(error)")
        }
        try expect(Date().timeIntervalSince(started) < 5)
        try expectEqual(server.requests.count, 1)
    }

    suite.test("cancelled while waiting to retry → CancellationError, no more requests") {
        let server = StubServer([OpenAIJSON.error(429, type: "requests", code: "rate_limit_exceeded"), OpenAIJSON.titles(["Never"])])
        let session = URLSession(configuration: StubURLProtocol.configuration())
        let assistant = OpenAIAssistant(session: session, baseURL: try server.baseURL(), retryDelays: [60, 60], now: { testNow })
        let task = Task { try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options()) }
        try await server.waitForRequests(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        task.cancel()
        switch await task.result {
        case .success: throw fail("a cancelled request returned titles")
        case .failure(let error): try expect(error is CancellationError, "got \(error)")
        }
        // The wait itself ends: it doesn't run out its 30 s first.
        try expect(Date().timeIntervalSince(started) < 5)
        try expectEqual(server.requests.count, 1)
    }

    suite.test("cancelled before it starts: nothing is sent") {
        let server = StubServer([OpenAIJSON.titles(["Never"])])
        let assistant = try server.assistant()
        // The assistant is called from a task that is already cancelled.
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
        }
        task.cancel()
        switch await task.result {
        case .success: throw fail("a cancelled request returned titles")
        case .failure(let error): try expect(error is CancellationError, "got \(error)")
        }
        try expectEqual(server.requests.count, 0)
    }

    suite.test("model list: GET /v1/models with the key, ids sorted; the same error mapping") {
        let server = StubServer([
            OpenAIJSON.models(["gpt-6.1-terra", "dall-e-3", "gpt-6-luna", "gpt-6-luna"]),
            OpenAIJSON.error(401, type: "invalid_request_error", code: "invalid_api_key", message: keyQuotingMessage),
            .ok(Data(#"{"object": "list"}"#.utf8)),
            .ok(Data(#"{"object": "list", "data": [{"id": "o3"}, {"object": "model"}, {"id": 7}, "junk"]}"#.utf8)),
        ])
        let assistant = try server.assistant()
        try expectEqual(try await assistant.availableModels(apiKey: " \(testKey) "), ["dall-e-3", "gpt-6-luna", "gpt-6.1-terra"])
        let request = try expectNotNil(server.requests.first)
        try expectEqual(request.method, "GET")
        try expectEqual(request.url.path, "/v1/models")
        try expectEqual(request.header("Authorization"), "Bearer \(testKey)")
        try expect(request.body.isEmpty)
        _ = try await expectAIError(.invalidKey) { try await assistant.availableModels(apiKey: testKey) }
        _ = try await expectAIError(.badResponse) { try await assistant.availableModels(apiKey: testKey) }
        try expectEqual(try await assistant.availableModels(apiKey: testKey), ["o3"])
    }

    suite.test("the key and OpenAI's error text never reach an AIError's message or log description") {
        var errors: [AIError] = []
        let replies: [StubReply] = [
            OpenAIJSON.error(401, type: "invalid_request_error", code: "invalid_api_key", message: keyQuotingMessage),
            OpenAIJSON.error(429, type: "insufficient_quota", code: "insufficient_quota", message: keyQuotingMessage),
            OpenAIJSON.error(404, type: "invalid_request_error", code: "model_not_found", message: keyQuotingMessage),
            OpenAIJSON.error(403, type: "invalid_request_error", code: nil, message: keyQuotingMessage),
            OpenAIJSON.error(400, type: "invalid_request_error", code: "context_length_exceeded", message: keyQuotingMessage),
            OpenAIJSON.error(418, type: keyQuotingMessage, code: keyQuotingMessage, param: keyQuotingMessage, message: keyQuotingMessage),
            .ok(OpenAIJSON.response([], status: "failed", error: ["code": "server_error", "message": keyQuotingMessage])),
            .ok(OpenAIJSON.response([], refusal: keyQuotingMessage)),
            OpenAIJSON.error(429, type: "insufficient_quota", code: "project_spend_limit_exceeded", message: keyQuotingMessage),
            OpenAIJSON.error(401, type: "invalid_request_error", code: "missing_scope", message: keyQuotingMessage),
            OpenAIJSON.error(400, type: "invalid_request_error", code: "invalid_prompt", message: keyQuotingMessage),
            .ok(OpenAIJSON.response([], status: "failed", error: ["code": "bio_policy", "message": keyQuotingMessage])),
        ]
        let server = StubServer(replies)
        let assistant = try server.assistant()
        for _ in replies {
            errors.append(try await expectAIError { try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options()) })
        }
        errors.append(try await expectAIError { try await assistant.availableModels(apiKey: "sk-bad key") })
        // The key pasted into the model field.
        errors.append(try await expectAIError {
            try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options(model: testKey))
        })
        try expectEqual(errors, [.invalidKey, .noCredit, .modelUnavailable("gpt-6.1-terra"), .notAllowed, .tooLong,
                                 .server(status: 418), .server(status: 500), .refused, .spendLimit, .notAllowed, .refused,
                                 .refused, .invalidKey, .modelUnavailable("?")])
        try expectEqual(server.requests.count, replies.count)
        for error in errors {
            for text in [error.message, error.logDescription] {
                try expect(!text.contains(testKey) && !text.contains("sk-") && !text.contains("WXYZ")
                           && !text.contains("Incorrect API key"), "\(error): \(text)")
            }
        }
    }

    return suite
}
