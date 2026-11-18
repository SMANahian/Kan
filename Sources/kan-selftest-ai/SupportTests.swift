import Foundation
import KanAI
import KanCore
import KanTestKit
import Security

func modelTests() -> TestSuite {
    let suite = TestSuite("Models")

    suite.test("the known models, recommended first") {
        try expectEqual(OpenAIModels.known.map(\.id), ["gpt-6.1-terra", "gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"])
        try expectEqual(OpenAIModels.known.map(\.name), ["GPT-6.1 Terra", "GPT-6 Luna", "GPT-6.1 Sol", "GPT-6 Astra"])
        try expectEqual(OpenAIModels.recommended, KanSettings.defaultAIModel)
        try expectEqual(OpenAIModels.known.first?.id, KanSettings.defaultAIModel)
        try expect(OpenAIModels.known.allSatisfy { !$0.detail.isEmpty })
        try expectEqual(OpenAIModels.option(for: " GPT-6-Luna ")?.name, "GPT-6 Luna")
        try expect(OpenAIModels.option(for: "gpt-5-mini") == nil)
    }

    suite.test("which /models ids can write titles and summaries") {
        let text = ["gpt-6.1-terra", "gpt-6-luna", "gpt-6.1-sol-2026-10-01", "gpt-6-astra", "gpt-5-mini", "gpt-4o",
                    "gpt-4.1-nano", "o3", "o4-mini", "o1-pro", "GPT-6.1-Terra"]
        let other = ["gpt-image-1", "gpt-4o-transcribe", "gpt-4o-mini-tts", "gpt-realtime", "gpt-audio-mini",
                     "gpt-4o-search-preview", "gpt-6-live", "gpt-5-codex", "codex-mini-latest", "o4-mini-deep-research",
                     "gpt-3.5-turbo-instruct", "text-embedding-3-small", "omni-moderation-latest", "dall-e-3", "whisper-1",
                     "tts-1", "babbage-002", "computer-use-preview", "chatgpt-4o-latest", "ft:gpt-4o-mini:org::abc", ""]
        for id in text { try expect(OpenAIModels.isLikelyTextModel(id), id) }
        for id in other { try expect(!OpenAIModels.isLikelyTextModel(id), id) }
    }

    suite.test("defaults: api.openai.com, retries after 2 s and 6 s, a session that keeps nothing") {
        try expectEqual(OpenAIAssistant.defaultBaseURL.absoluteString, "https://api.openai.com/v1")
        try expectEqual(OpenAIAssistant.defaultRetryDelays, [2, 6])
        try expectEqual(OpenAIAssistant.maxRetryAfter, 30)
        let configuration = OpenAIAssistant.makeSession().configuration
        try expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        try expect(configuration.urlCache == nil && configuration.urlCredentialStorage == nil)
        try expectEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        _ = OpenAIAssistant()
    }

    return suite
}

func keyStoreTests() -> TestSuite {
    let suite = TestSuite("Key stores")

    suite.test("in memory: save, load, replace, delete") {
        let store = InMemoryAPIKeyStore()
        try expect(store.loadKey() == nil)
        try store.saveKey("  \(testKey)\n")
        try expectEqual(store.loadKey(), testKey)
        try store.saveKey("sk-other")
        try expectEqual(store.loadKey(), "sk-other")
        try expectThrows { try store.saveKey(" \n") }
        try expectEqual(store.loadKey(), "sk-other")
        try store.deleteKey()
        try expect(store.loadKey() == nil)
        try store.deleteKey()
        try expectEqual(InMemoryAPIKeyStore(key: "sk-given").loadKey(), "sk-given")
    }

    suite.test("keychain item: Kan's service, account and label") {
        let store = KeychainAPIKeyStore()
        try expectEqual(store.service, "com.nahian.Kan.openai")
        try expectEqual(store.account, "default")
        try expectEqual(store.label, "Kan — OpenAI API key")
    }

    suite.test("keychain errors name the OSStatus and the system's reason") {
        let error = KeychainError(operation: .save, status: errSecDuplicateItem)
        let text = try expectNotNil(error.errorDescription)
        try expect(text.contains("OSStatus -25299") && text.contains("save"), text)
        try expect(!error.statusMessage.isEmpty && !text.contains("unknown error"), text)
        try expect(KeychainError(operation: .delete, status: errSecAuthFailed).errorDescription?.contains("remove") == true)
    }

    suite.test("login keychain round trip; a new store saves the key again after its first read (KAN_TEST_KEYCHAIN=1)") {
        guard ProcessInfo.processInfo.environment["KAN_TEST_KEYCHAIN"] == "1" else {
            throw TestSkip("uses the login keychain; run with KAN_TEST_KEYCHAIN=1")
        }
        // A throwaway service, so Kan's own item is never touched.
        let store = KeychainAPIKeyStore(service: "com.nahian.Kan.selftest.\(UUID().uuidString)", label: "Kan self-test (safe to delete)")
        print("    (throwaway keychain item: service \(store.service))")
        defer { try? store.deleteKey() }
        try expect(store.loadKey() == nil)
        try store.saveKey(testKey)
        try expectEqual(store.loadKey(), testKey)
        try store.saveKey("  sk-replaced \n")
        let saved = try expectNotNil(keychainItem(store)?.modified, "the saved item")

        // The keychain keeps whole seconds, so each check waits a little over one before it reads.
        // The store that saved the key reads it without writing it again…
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try expectEqual(store.loadKey(), "sk-replaced")
        try expectEqual(keychainItem(store)?.modified, saved, "the store that saved the key wrote it again")
        // …a new one, as at the next launch of a new build, writes it back once: the same key and label.
        let launch = KeychainAPIKeyStore(service: store.service)
        try expectEqual(launch.loadKey(), "sk-replaced", "another instance reads it")
        let resaved = try expectNotNil(keychainItem(store), "the re-saved item")
        try expect(resaved.modified > saved, "the first read didn't save the key again")
        try expectEqual(resaved.label, "Kan self-test (safe to delete)")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try expectEqual(launch.loadKey(), "sk-replaced")
        try expectEqual(keychainItem(store)?.modified, resaved.modified, "a second read saved the key again")
        try expectEqual(store.loadKey(), "sk-replaced")

        try expect(KeychainAPIKeyStore(service: store.service, account: "other").loadKey() == nil)
        try store.deleteKey()
        try expect(store.loadKey() == nil)
        try expect(KeychainAPIKeyStore(service: store.service).loadKey() == nil, "a re-save brought the item back")
        try expect(keychainItem(store) == nil)
        try store.deleteKey()   // nothing saved is fine
    }

    return suite
}

/// The label and modification date of `store`'s keychain item (never its data), or nil.
private func keychainItem(_ store: KeychainAPIKeyStore) -> (label: String?, modified: Date)? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: store.service,
        kSecAttrAccount as String: store.account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let attributes = result as? [String: Any],
          let modified = attributes[kSecAttrModificationDate as String] as? Date else { return nil }
    return (attributes[kSecAttrLabel as String] as? String, modified)
}

func privacyTests() -> TestSuite {
    let suite = TestSuite("Privacy")

    suite.test("kan.log gets ids, codes and counts — never the key, the call's text or what OpenAI wrote") {
        let titles = ["SpecAugment baseline for Bangla ASR", "Choosing the OpenSLR dataset"]
        let overview = "Nahian and Prof. Rahman agreed on a speed perturbation baseline."
        let openAIWords = "Incorrect API key provided: sk-proj-KanS****WXYZ."
        let server = StubServer([
            OpenAIJSON.titles(titles),
            OpenAIJSON.summary(overview: overview, actionItems: ["Nahian: send the paper draft"]),
            OpenAIJSON.error(401, type: "invalid_request_error", code: "invalid_api_key", message: openAIWords),
            OpenAIJSON.error(429, type: "requests", code: "rate_limit_exceeded", message: openAIWords),
            OpenAIJSON.error(500, type: "server_error", code: nil, message: openAIWords),
            OpenAIJSON.summary(overview: overview),
            OpenAIJSON.error(400, type: "invalid_request_error", code: "unsupported_parameter", param: "reasoning.effort",
                             message: openAIWords),
            OpenAIJSON.titles(titles),
            .ok(OpenAIJSON.response([], refusal: openAIWords)),
            OpenAIJSON.models(["gpt-6.1-terra"]),
        ])
        let assistant = try server.assistant()
        let record = Fixtures.longCall(lines: 6000)
        let logFile = KanPaths.logs.appendingPathComponent("kan-selftest-ai.log")
        let log = try await capturedLog(logFile, log: { KanLog.info($0, category: "test") }) {
            _ = try await assistant.suggestTitles(for: Fixtures.researchCall(), options: Fixtures.options())
            _ = try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
            _ = try? await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
            _ = try await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
            _ = try await assistant.suggestTitles(for: record, options: Fixtures.options())
            _ = try? await assistant.summarize(Fixtures.researchCall(), options: Fixtures.options())
            _ = try await assistant.availableModels(apiKey: testKey)
        }
        // It says what happened…
        for expected in ["[ai]", "call \(Fixtures.callID)", "HTTP 401", "code invalid_api_key", "rate limited (429)", "retrying in",
                         "without it", "gpt-6.1-terra", "tokens 1234 in", "lines left out", "refused"] {
            try expect(log.contains(expected), "the log doesn't say “\(expected)”:\n\(log)")
        }
        // …and nothing private.
        var secrets = [testKey, "sk-proj", "WXYZ", openAIWords, "Incorrect API key", overview, "send the paper draft",
                       "Zoom call with", "Prof. Rahman", "Nahian", "augmentation", "OpenSLR", "ভাবছিলাম", "SpecAugment",
                       "Ask about compute", "line 00000"]
        secrets += titles
        for secret in secrets {
            try expect(!log.contains(secret), "the log contains “\(secret)”:\n\(log)")
        }
    }

    return suite
}
