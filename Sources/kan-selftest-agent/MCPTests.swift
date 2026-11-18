import Foundation
import KanAgent
import KanCore
import KanTestKit

func mcpProtocolTests() -> TestSuite {
    let suite = TestSuite("MCP protocol")
    var cached: AgentFixture?
    func fixture() throws -> AgentFixture {
        if let cached { return cached }
        let f = try AgentFixture("mcp-protocol")
        cached = f
        return f
    }
    func harness() throws -> MCPHarness { MCPHarness(try fixture().library()) }

    func expectError(_ response: JSONValue?, code: Int, id: JSONValue, _ message: String = "") throws {
        let response = try expectNotNil(response, "expected an error response. \(message)")
        try expectEqual(response["jsonrpc"], "2.0")
        try expectEqual(response["id"], id, message)
        try expectEqual(response["error"]?["code"], .int(code), "\(message) — got \(response)")
        try expect(response["error"]?["message"]?.stringValue?.isEmpty == false)
        try expect(response["result"] == nil)
    }

    suite.test("initialize echoes every supported protocol version") {
        for version in ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"] {
            let h = try harness()
            let result = try expectNotNil(try h.initialize(version)["result"])
            try expectEqual(result["protocolVersion"], .string(version))
            try expectEqual(h.server.negotiatedVersion, version)
        }
    }

    suite.test("initialize answers an unknown version with the latest") {
        for version in ["2099-01-01", "1.0", ""] {
            let result = try expectNotNil(try harness().initialize(version)["result"])
            try expectEqual(result["protocolVersion"], "2025-11-25", "asked \(version)")
        }
    }

    suite.test("initialize result: capabilities, server info, instructions") {
        let result = try expectNotNil(try harness().initialize()["result"])
        try expectEqual(result["capabilities"], ["tools": ["listChanged": false]])
        try expectEqual(result["serverInfo"]?["name"], "kan")
        try expectEqual(result["serverInfo"]?["version"], .string(KanVersion.current))
        let instructions = try result.string("instructions")
        for needle in ["Bangla", "English", "\"me\"", "Nahian", "read-only", "never guess", "search_transcripts", "get_transcript"] {
            try expectContains(instructions, needle)
        }
    }

    suite.test("initialize with bad params is -32602") {
        let h = try harness()
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#), code: -32602, id: 1)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":20250618}}"#), code: -32602, id: 2)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":["2025-06-18"]}"#), code: -32602, id: 3)
        try expect(h.server.negotiatedVersion == nil)
    }

    suite.test("notifications never get a reply") {
        let h = try harness()
        try expect(try h.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        try expect(h.server.clientInitialized)
        try expect(try h.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#) == nil)
        try expect(try h.send(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#) == nil)
        try expect(try h.send(#"{"jsonrpc":"2.0","method":"tools/list"}"#) == nil, "a request without id is a notification")
        try expect(try h.send("") == nil && (try h.send("   \t ")) == nil, "blank lines are skipped")
    }

    suite.test("ping, ids of every kind, requests before initialize") {
        let h = try harness()
        let pong = try h.request("ping")
        try expectEqual(pong["result"], .object([:]))
        let stringID = try expectNotNil(try h.send(#"{"jsonrpc":"2.0","id":"req-7","method":"ping"}"#))
        try expectEqual(stringID["id"], "req-7")
        let zero = try expectNotNil(try h.send(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#))
        try expectEqual(zero["id"], 0)
        let tools = try h.request("tools/list")
        try expectEqual(tools["result"]?["tools"]?.arrayValue?.count, 9, "served before initialize")
    }

    suite.test("unknown methods are -32601") {
        let h = try harness()
        _ = try h.initialize()
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#), code: -32601, id: 5)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":"x","method":"does/not/exist","params":{}}"#), code: -32601, id: "x")
    }

    suite.test("malformed JSON is -32700 with a null id") {
        let h = try harness()
        for line in ["{not json", #"{"jsonrpc":"2.0","id":1,"method":"ping""#, "[1,2", #"{"a":1} {"b":2}"#, "\u{FEFF}garbage"] {
            try expectError(try h.send(line), code: -32700, id: .null, line)
        }
        try expectEqual(try h.request("ping")["result"], .object([:]), "the server keeps going")
        let withBOM = try expectNotNil(try h.send("\u{FEFF}" + #"{"jsonrpc":"2.0","id":"bom","method":"ping"}"#))
        try expectEqual(withBOM["result"], .object([:]), "a leading byte-order mark is tolerated")
    }

    suite.test("invalid requests are -32600") {
        let h = try harness()
        try expectError(try h.send("42"), code: -32600, id: .null)
        try expectError(try h.send(#""ping""#), code: -32600, id: .null)
        try expectError(try h.send(#"{"id":1,"method":"ping"}"#), code: -32600, id: 1, "jsonrpc missing")
        try expectError(try h.send(#"{"jsonrpc":"1.0","id":2,"method":"ping"}"#), code: -32600, id: 2)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":3,"method":7}"#), code: -32600, id: 3)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":4}"#), code: -32600, id: 4, "method missing")
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#), code: -32600, id: .null)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#), code: -32600, id: .null)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#), code: -32600, id: .null)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":5,"method":"ping","params":"x"}"#), code: -32600, id: 5)
        // A response from the client is not a request: ignored.
        try expect(try h.send(#"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
    }

    suite.test("batches") {
        let h = try harness()
        let batch = try expectNotNil(try h.send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"nope"},17]"#))
        let items = try expectNotNil(batch.arrayValue)
        try expectEqual(items.count, 3)
        try expectEqual(items[0]["id"], 1)
        try expectEqual(items[0]["result"], .object([:]))
        try expectEqual(items[1]["error"]?["code"], -32601)
        try expectEqual(items[2]["error"]?["code"], -32600)
        try expectError(try h.send("[]"), code: -32600, id: .null)
        try expect(try h.send(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
    }

    suite.test("tools/list: nine read-only tools with valid input schemas") {
        let h = try harness()
        _ = try h.initialize()
        let tools = try expectNotNil(try h.request("tools/list")["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        try expectEqual(names, ["list_calls", "search_transcripts", "get_call", "get_transcript", "list_folders", "list_tags",
                                "list_people", "get_library_info", "export_call"])
        let jsonTypes: Set<String> = ["string", "integer", "number", "boolean", "object", "array"]
        for tool in tools {
            let name = try tool.string("name")
            try expect(try tool.string("description").count > 40, "\(name) has a real description")
            try expect(!(try tool.string("title")).isEmpty)
            let schema = try expectNotNil(tool["inputSchema"]?.objectValue, "\(name) inputSchema")
            try expectEqual(schema["type"], "object", name)
            try expectEqual(schema["additionalProperties"], false, name)
            let properties = try expectNotNil(schema["properties"]?.objectValue, "\(name) properties")
            for (property, definition) in properties {
                let type = try expectNotNil(definition["type"]?.stringValue, "\(name).\(property) type")
                try expect(jsonTypes.contains(type), "\(name).\(property): \(type)")
                try expect(definition["description"]?.stringValue?.isEmpty == false, "\(name).\(property) description")
                if let options = definition["enum"] {
                    try expect(options.arrayValue?.allSatisfy { $0.stringValue != nil } == true, "\(name).\(property) enum")
                }
                if let minimum = definition["minimum"] { try expect(minimum.doubleValue != nil) }
                if let fallback = definition["default"] {
                    let matches: Bool
                    switch type {
                    case "string": matches = fallback.stringValue != nil
                    case "integer": matches = fallback.intValue != nil
                    default: matches = true
                    }
                    try expect(matches, "\(name).\(property) default has the right type")
                }
            }
            if let required = schema["required"] {
                let list = try expectNotNil(required.arrayValue?.compactMap(\.stringValue))
                try expect(!list.isEmpty && list.allSatisfy { properties[$0] != nil }, "\(name): required ⊆ properties")
            }
            try expectEqual(tool["annotations"]?["readOnlyHint"], true, name)
            try expectEqual(tool["annotations"]?["destructiveHint"], false, name)
        }
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { t in t["name"]?.stringValue.map { ($0, t) } })
        try expectEqual(byName["search_transcripts"]?["inputSchema"]?["required"], ["query"])
        try expectEqual(byName["get_transcript"]?["inputSchema"]?["required"], ["call_id"])
        try expectEqual(byName["get_transcript"]?["inputSchema"]?["properties"]?["format"]?["enum"], ["markdown", "text", "json"])
        try expect(byName["list_folders"]?["inputSchema"]?["required"] == nil, "no empty required array")
    }

    suite.test("tools/call protocol errors are -32602") {
        let h = try harness()
        _ = try h.initialize()
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#), code: -32602, id: 1)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_everything"}}"#), code: -32602, id: 2)
        let unknown = try expectNotNil(try h.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#))
        try expectContains(try expectNotNil(unknown["error"]?["message"]?.stringValue), "Unknown tool: nope")
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_calls","arguments":[1]}}"#), code: -32602, id: 4)
        try expectError(try h.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":7}}"#), code: -32602, id: 5)
        // A null or missing "arguments" is fine.
        let ok = try expectNotNil(try h.send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_tags","arguments":null}}"#))
        try expect(ok["result"]?["isError"] == nil)
    }

    suite.test("structuredContent only for protocol versions that have it") {
        for (version, expected) in [("2025-11-25", true), ("2025-06-18", true), ("2025-03-26", false), ("2024-11-05", false)] {
            let h = try harness()
            _ = try h.initialize(version)
            let result = try h.call("list_tags")
            try expectEqual(result.structured != nil, expected, version)
            try expect(!result.text.isEmpty)
        }
    }

    suite.test("responses are always one line") {
        let h = try harness()
        _ = try h.initialize()
        let line = try expectNotNil(h.server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_call","arguments":{"call_id":"01KAX3A0"}}}"#))
        try expect(!line.contains("\n") && !line.contains("\r"))
        let text = try expectNotNil(try JSONValue.parse(line)["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        try expect(text.contains("\n"), "multi-line text is escaped inside the line")
    }

    suite.test("Unicode line separators are escaped on the wire") {
        let fixture = try AgentFixture("mcp-separators", populate: false)
        try fixture.writer().save(CallRecord(
            id: fixtureID("K0"), title: "Separators", notes: "one\u{2028}two\u{2029}three\u{85}four", startedAt: testNow,
            endedAt: testNow.addingTimeInterval(60), timeZone: "UTC", source: CallSource(appName: "Zoom", platform: .zoom),
            status: .ready))
        let h = MCPHarness(fixture.library())
        let line = try expectNotNil(h.server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_call","arguments":{"call_id":"Separators"}}}"#))
        try expect(!line.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" })
        try expectContains(line, #"one\u2028two\u2029three\u0085four"#)
        let parsed = try JSONValue.parse(line)
        try expectEqual(parsed["result"]?["structuredContent"]?["notes"], "one\u{2028}two\u{2029}three\u{85}four", "still the same text")
    }
    return suite
}

func mcpToolTests() -> TestSuite {
    let suite = TestSuite("MCP tools")
    var cached: AgentFixture?
    func fixture() throws -> AgentFixture {
        if let cached { return cached }
        let f = try AgentFixture("mcp-tools")
        cached = f
        return f
    }
    func harness() throws -> MCPHarness {
        let h = MCPHarness(try fixture().library())
        _ = try h.initialize()
        return h
    }

    suite.test("list_calls: summaries, filters, paging") {
        let h = try harness()
        let all = try h.structured("list_calls")
        try expectEqual(try all.int("total"), 8)
        let calls = try all.array("calls")
        try expectEqual(calls.count, 8)
        let first = calls[0]
        try expectEqual(try first.string("id"), IDs.weekly2.rawValue)
        for key in ["title", "folder", "started_at", "ended_at", "time_zone", "app", "platform", "status", "markdown_path"] {
            try expect(first[key]?.stringValue != nil, "summary has \(key)")
        }
        for key in ["tags", "people", "languages"] { try expect(first[key]?.arrayValue != nil, "summary has \(key)") }
        try expectEqual(first["duration_seconds"], 1500)
        try expect(all["next_offset"]?.isNull == true)

        let page = try h.structured("list_calls", ["limit": 3, "offset": 3])
        try expectEqual(try page.array("calls").compactMap { $0["id"]?.stringValue }, [IDs.advisor, IDs.ammu, IDs.labSync].map(\.rawValue))
        try expectEqual(page["next_offset"], 6)
        let text = try h.call("list_calls", ["limit": 3, "offset": 3]).text
        try expectContains(text, "Calls 4–6 of 8, newest first.")
        try expectContains(text, "id: \(IDs.advisor.rawValue)")
        try expectContains(text, "started: 2026-11-14T10:00:12-05:00 (America/New_York)")
        try expectContains(text, "More calls: list_calls with offset 6.")

        func ids(_ args: [String: JSONValue]) throws -> [String] {
            try h.structured("list_calls", args).array("calls").compactMap { $0["id"]?.stringValue }
        }
        try expectEqual(try ids(["folder": "Research/Thesis"]), [IDs.advisor.rawValue])
        try expectEqual(try ids(["folder": "Inbox", "status": "failed"]), [IDs.failed.rawValue])
        try expectEqual(try ids(["tag": "#family", "starred": true]), [IDs.ammu.rawValue])
        try expectEqual(try ids(["person": "Rahim", "app": "Google Meet"]), [IDs.labSync.rawValue])
        try expectEqual(try ids(["since": "2026-11-16", "until": "today"]), [IDs.weekly2.rawValue, IDs.processing.rawValue])
        try expectEqual(try ids(["query": "ভাষার মডেল"]), [IDs.advisor.rawValue])
        try expectEqual(try ids(["limit": "2"]).count, 2, "numeric strings are accepted")
        try expectEqual(try ids(["starred": "true"]).count, 2)
        try expectEqual(try ids(["limit": 5000]).count, 8, "limits above the maximum are lowered")
        try expectEqual(try ids(["folder": .null]).count, 8, "null = absent")
        try expectEqual(try h.call("list_calls", ["folder": "Nowhere"]).text, "No calls match these filters.")
    }

    suite.test("list_calls: bad arguments are tool errors") {
        let h = try harness()
        try expectContains(try h.toolError("list_calls", ["limit": 0]), "limit must be at least 1")
        try expectContains(try h.toolError("list_calls", ["limit": "lots"]), "limit must be an integer")
        try expectContains(try h.toolError("list_calls", ["limit": 2.5]), "limit must be an integer")
        try expectContains(try h.toolError("list_calls", ["offset": -1]), "offset must be at least 0")
        try expectContains(try h.toolError("list_calls", ["since": "next tuesday"]), "since: Unrecognized date")
        try expectContains(try h.toolError("list_calls", ["since": "2026-11-15", "until": "2026-11-01"]), "since is after until")
        try expectContains(try h.toolError("list_calls", ["status": "done"]), "status must be one of")
        try expectContains(try h.toolError("list_calls", ["starred": "maybe"]), "starred must be true or false")
        try expectContains(try h.toolError("list_calls", ["folder": 3]), "folder must be a string")
        let unknown = try h.toolError("list_calls", ["project": "Thesis"])
        try expectContains(unknown, "Unknown argument for list_calls: project")
        try expectContains(unknown, "Valid arguments: app, folder")
    }

    suite.test("search_transcripts: passages with absolute times") {
        let h = try harness()
        let result = try h.structured("search_transcripts", ["query": "augmentation"])
        try expectEqual(try result.int("matched_calls"), 2)
        let passages = try result.array("passages")
        try expectEqual(try passages[0].string("field"), "title", "the best call's title first")
        let spoken = try expectNotNil(passages.first { $0["segment_id"] == 4 })
        try expectEqual(try spoken.string("call_id"), IDs.advisor.rawValue)
        try expectEqual(spoken["time_seconds"]?.doubleValue, 751)
        try expectEqual(try spoken.string("timestamp"), "00:12:31")
        try expectEqual(try spoken.string("at"), "2026-11-14T10:12:43-05:00")
        try expectEqual(try spoken.string("speaker"), "Prof. Rahman")
        try expectEqual(try spoken.string("time_zone"), "America/New_York")
        try expectEqual(try spoken.string("title"), "Advisor meeting – augmentation idea")
        let text = try h.call("search_transcripts", ["query": "augmentation"]).text
        try expectContains(text, "## Advisor meeting – augmentation idea\nid: \(IDs.advisor.rawValue) · started 2026-11-14T10:00:12-05:00 (America/New_York) · Zoom")
        try expectContains(text, "- [00:12:31] Prof. Rahman: Speed perturbation and SpecAugment would be a good augmentation baseline.")

        let bangla = try h.structured("search_transcripts", ["query": "খেয়েছো"])
        let hit = try bangla.array("passages")[0]
        try expectEqual(try hit.string("speaker"), "আম্মু")
        try expectEqual(try hit.string("at"), "2026-11-12T21:00:05+06:00", "Dhaka offset")
        try expectEqual(try hit.string("time_zone"), "Asia/Dhaka")

        let capped = try h.structured("search_transcripts", ["query": "segment", "limit": 4, "max_per_call": 2])
        try expectEqual(try capped.array("passages").count, 2)
        try expectEqual(capped["truncated"], true)
        try expectEqual(try capped.int("total_hits"), 900)
        let filtered = try h.structured("search_transcripts", ["query": "augmentation", "folder": "Research", "since": "2026-11-15"])
        try expectEqual(try filtered.array("passages").compactMap { $0["call_id"]?.stringValue }, [IDs.weekly2.rawValue])
        let nothing = try h.call("search_transcripts", ["query": "zebra"])
        try expect(!nothing.isError)
        try expectContains(nothing.text, "No passages match “zebra”")
    }

    suite.test("search_transcripts: bad arguments") {
        let h = try harness()
        try expectContains(try h.toolError("search_transcripts"), "query is required")
        try expectContains(try h.toolError("search_transcripts", ["query": "   "]), "use list_calls")
        try expectContains(try h.toolError("search_transcripts", ["query": "x", "max_per_call": 0]), "max_per_call must be at least 1")
        try expectContains(try h.toolError("search_transcripts", ["query": ["a"]]), "query must be a string")
    }

    suite.test("get_call: metadata, notes, bookmarks, speakers — no transcript") {
        let h = try harness()
        let call = try h.structured("get_call", ["call_id": .string(IDs.advisor.rawValue)])
        try expectEqual(try call.string("title"), "Advisor meeting – augmentation idea")
        try expectEqual(try call.string("notes"), "Try SpecAugment + speed perturbation on the Bangla set.\nAsk about compute.")
        try expectEqual(try call.string("started_at"), "2026-11-14T10:00:12-05:00")
        try expectEqual(try call.string("duration"), "00:42:13")
        try expectEqual(try call.string("me"), "Nahian")
        try expectEqual(call["segment_count"], 7, "visible segments")
        try expect(call["segments"] == nil && call["transcript"] == nil, "no transcript in get_call")
        let speakers = try call.array("speakers")
        try expectEqual(speakers.map { $0["id"] }, ["me", "s1"])
        try expectEqual(speakers[0]["is_me"], true)
        try expectEqual(speakers[1]["name_source"], "user")
        try expectEqual(speakers[1]["segment_count"], 3)
        let bookmark = try call.array("bookmarks")[0]
        try expectEqual(bookmark["timestamp"], "00:12:31")
        try expectEqual(bookmark["end_timestamp"], "00:12:50")
        try expectEqual(bookmark["at"], "2026-11-14T10:12:43-05:00")
        try expectEqual(bookmark["note"], "augmentation idea")
        let text = try h.call("get_call", ["call_id": "01KAX3A0"]).text
        try expectContains(text, "# Advisor meeting – augmentation idea\nSat 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman")
        try expectContains(text, "- **Nahian** — id me · the user")
        try expectContains(text, "- [00:12:31–00:12:50] augmentation idea (at 2026-11-14T10:12:43-05:00)")
        try expectContains(text, "## Notes\nTry SpecAugment")

        let lab = try h.structured("get_call", ["call_id": "Lab sync"])
        try expectEqual(lab["meeting_url"], "https://meet.google.com/abc-defg-hij")
        let placeholder = try expectNotNil(try lab.array("speakers").first { $0["id"] == "s1" })
        try expectEqual(placeholder["has_placeholder_name"], true)
        try expectEqual(placeholder["suggested_name"], "Karim")
        let failed = try h.structured("get_call", ["call_id": .string(IDs.failed.rawValue)])
        try expectEqual(failed["processing"]?["error"], "Model not installed: large-v3")
        try expectContains(try failed.string("transcript_note"), "Transcription failed: Model not installed: large-v3")
    }

    suite.test("get_call: unknown, ambiguous and missing ids") {
        let h = try harness()
        let unknown = try h.toolError("get_call", ["call_id": "01KAX3ZZZZZZZZZZZZZZZZZZZZ"])
        try expectContains(unknown, "No call matches")
        try expectContains(unknown, "never guess ids")
        let ambiguous = try h.toolError("get_call", ["call_id": "Weekly sync"])
        try expectContains(ambiguous, "matches 2 calls")
        try expectContains(ambiguous, IDs.weekly1.rawValue)
        try expectContains(ambiguous, IDs.weekly2.rawValue)
        try expectContains(try h.toolError("get_call"), "call_id is required")
        try expectContains(try h.toolError("get_call", ["call_id": "01KAX3A0", "format": "md"]), "Unknown argument for get_call: format")
    }

    suite.test("the log says which tool failed and how, never titles, folders or the agent's words") {
        let h = try harness()
        let text = try await loggedText {
            try expectContains(try h.toolError("get_call", ["call_id": "Weekly sync"]), "Weekly sync  (Research)")
            try expectContains(try h.toolError("get_call", ["call_id": "Secret meeting"]), "No call matches “Secret meeting”")
            _ = try h.toolError("search_transcripts", ["query": "x", "since": "Secret date"])
            _ = try h.toolError("get_transcript", ["call_id": "01KAX3A0", "Secret argument": true])
            try expectEqual(try h.send(#"{"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "search_transcripts", "arguments": {"query": "Secret words""#)?["error"]?["code"],
                            .int(RPCError.parseErrorCode))
        }
        for line in ["MCP get_call → error: ambiguous call (2 candidates)", "MCP get_call → error: no matching call",
                     "MCP search_transcripts → error: invalid arguments", "MCP get_transcript → error: invalid arguments",
                     "MCP: unparseable message ("] {
            try expectContains(text, line)
        }
        for content in ["Weekly sync", "Research", "Secret"] {
            try expect(!text.contains(content), "“\(content)” in the log:\n\(text)")
        }
    }

    suite.test("get_transcript: markdown, text and json") {
        let h = try harness()
        let markdown = try h.call("get_transcript", ["call_id": .string(IDs.advisor.rawValue)])
        try expect(!markdown.isError, markdown.text)
        try expectContains(markdown.text, "# Advisor meeting – augmentation idea — transcript\nid: \(IDs.advisor.rawValue) · started 2026-11-14T10:00:12-05:00 (America/New_York)")
        try expectContains(markdown.text, "segments 1–7 of 7 · 00:00:05–00:40:10")
        try expectContains(markdown.text, "**Nahian** [00:00:05]\nSo I was thinking about data augmentation for low-resource Bangla ASR. আমি ভাবছিলাম OpenSLR-এর বাংলা ডেটাসেট দিয়ে শুরু করা যায়।\n")
        try expectContains(markdown.text, "**Prof. Rahman** [00:12:31]\nSpeed perturbation and SpecAugment would be a good augmentation baseline. আর ভাষার মডেল আলাদা করে train করো।")
        try expectNotContains(markdown.text, "would be a good baseline.", "echo suspects hidden")
        try expectNotContains(markdown.text, "More:")
        let structured = try expectNotNil(markdown.structured)
        try expectEqual(structured["returned"], 7)
        try expect(structured["next_offset"]?.isNull == true)
        try expectEqual(try structured.string("format"), "markdown")
        try expectEqual(structured["speakers"]?.arrayValue?.first?["is_me"], true)

        let text = try h.call("get_transcript", ["call_id": "Lab sync", "format": "text"]).text
        try expectContains(text, "Lab sync — transcript\n")
        try expectContains(text, "[00:00:03] Nahian: Rahim, did the GPU cluster job finish?\n[00:00:07] Rahim: হ্যাঁ")

        let json = try h.call("get_transcript", ["call_id": "01KAX3C0", "format": "json"])
        let parsed = try JSONValue.parse(json.text)
        let segments = try parsed.array("segments")
        try expectEqual(segments.count, 3)
        try expectEqual(segments[1]["speaker"], "আম্মু")
        try expectEqual(segments[1]["speaker_id"], "s1")
        try expectEqual(segments[1]["is_me"], false)
        try expectEqual(segments[1]["language"], "bn")
        try expectEqual(segments[1]["start_seconds"], 5)
        try expectEqual(segments[1]["timestamp"], "00:00:05")
        try expectEqual(json.structured?["segments"], parsed["segments"])
    }

    suite.test("get_transcript: paging and time ranges") {
        let h = try harness()
        let first = try h.structured("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "format": "json"])
        try expectEqual(first["returned"], 400, "default page")
        try expectEqual(first["total_segments"], 1000)
        try expectEqual(first["next_offset"], 400)
        let second = try h.call("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "offset": 400])
        try expectContains(second.text, "segments 401–800 of 1000")
        try expectContains(second.text, "More: get_transcript with call_id \(IDs.seminar.rawValue) and offset 800.")
        let last = try h.structured("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "offset": 800, "format": "json"])
        try expectEqual(last["returned"], 200)
        try expect(last["next_offset"]?.isNull == true)
        try expectEqual(try last.array("segments").first?["id"], 800)
        let beyond = try h.call("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "offset": 5000])
        try expectContains(beyond.text, "No segments at offset 1000 (there are 1000).")

        let window = try h.structured("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "from_seconds": 600,
                                                         "to_seconds": 630, "format": "json"])
        try expectEqual(try window.array("segments").compactMap { $0["id"]?.intValue }, Array(200..<210))
        try expectEqual(window["from_seconds"], 600)
        let clock = try h.structured("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "from_seconds": "00:10:00",
                                                        "to_seconds": "10:30", "limit": 3, "format": "json"])
        try expectEqual(try clock.array("segments").compactMap { $0["id"]?.intValue }, [200, 201, 202])
        try expectEqual(clock["total_segments"], 10)
        try expectEqual(clock["next_offset"], 3)
        let quiet = try h.call("get_transcript", ["call_id": .string(IDs.advisor.rawValue), "from_seconds": 1000, "to_seconds": 1100])
        try expectContains(quiet.text, "No speech in this time range.")
        let capped = try h.structured("get_transcript", ["call_id": .string(IDs.seminar.rawValue), "limit": 99_999])
        try expectEqual(capped["returned"], 1000, "limit lowered to the maximum page")
    }

    suite.test("get_transcript: bad arguments and calls without a transcript") {
        let h = try harness()
        try expectContains(try h.toolError("get_transcript", ["call_id": "01KAX3A0", "format": "pdf"]), "format must be one of: json, markdown, text")
        try expectContains(try h.toolError("get_transcript", ["call_id": "01KAX3A0", "from_seconds": 50, "to_seconds": 10]), "to_seconds must be after from_seconds")
        try expectContains(try h.toolError("get_transcript", ["call_id": "01KAX3A0", "from_seconds": -1]), "can't be negative")
        try expectContains(try h.toolError("get_transcript", ["call_id": "01KAX3A0", "from_seconds": "soon"]), "seconds from the call's start")
        try expectContains(try h.toolError("get_transcript", ["call_id": "01KAX3A0", "limit": 0]), "limit must be at least 1")
        try expectContains(try h.toolError("get_transcript", ["format": "text"]), "call_id is required")
        let processing = try h.call("get_transcript", ["call_id": .string(IDs.processing.rawValue)])
        try expect(!processing.isError)
        try expectContains(processing.text, "_The transcript is being generated; try again in a few minutes._")
        try expectContains(processing.text, "There is no transcript text.")
        try expectEqual(processing.structured?["transcript_note"], "The transcript is being generated; try again in a few minutes.")
    }

    suite.test("list_folders, list_tags, list_people") {
        let h = try harness()
        let folders = try h.structured("list_folders").array("folders")
        try expectEqual(folders.compactMap { $0["name"]?.stringValue }, ["", "Personal", "Research", "Research/Seminars", "Research/Thesis"])
        try expectEqual(folders.compactMap { $0["count"]?.intValue }, [3, 1, 2, 1, 1])
        try expectEqual(folders.compactMap { $0["total"]?.intValue }, [3, 1, 4, 1, 1])
        try expectContains(try h.call("list_folders").text, "- Research: 2 · 4\n  - Seminars: 1  [Research/Seminars]\n  - Thesis: 1  [Research/Thesis]\n")
        let tags = try h.structured("list_tags").array("tags")
        try expectEqual(tags.first, ["name": "weekly", "count": 2])
        try expectEqual(tags.count, 6)
        let people = try h.structured("list_people").array("people")
        try expectEqual(people.first, ["name": "Prof. Rahman", "count": 3])
        try expect(!people.contains { $0["name"] == "Nahian" || $0["name"] == "Speaker 1" })
        try expectContains(try h.call("list_people").text, "- আম্মু: 1")
        try expectContains(try h.toolError("list_tags", ["limit": 5]), "This tool takes no arguments.")
    }

    suite.test("get_library_info: root, counts and AGENTS.md") {
        let h = try harness()
        let info = try h.structured("get_library_info")
        try expectEqual(try info.string("root"), try fixture().root.standardizedFileURL.path)
        try expectEqual(info["calls"], 8)
        try expectEqual(info["folders"], 4)
        try expectEqual(info["people"], 4)
        try expectEqual(info["user_name"], "Nahian")
        try expectEqual(info["agents_md_source"], "file", "the library's own AGENTS.md")
        try expectContains(try info.string("agents_md"), "kan-agents-guide-version")
        try expectEqual(info["first_call_at"], "2026-11-01T13:00:00-05:00")
        let text = try h.call("get_library_info").text
        try expectContains(text, "- calls: 8 (6 ready")
        try expectContains(text, "## AGENTS.md\n\n<!-- kan-agents-guide-version")
    }

    suite.test("export_call: every format") {
        let h = try harness()
        let md = try h.call("export_call", ["call_id": "01KAX3A0"])
        try expect(md.text.hasPrefix("---\nkan_id: \(IDs.advisor.rawValue)\n"))
        try expectEqual(md.structured?["format"], "markdown")
        try expectEqual(md.structured?["file_name"], "2026-11-14 1000 Advisor meeting – augmentation idea.md")
        try expectEqual(md.structured?["content"], .string(md.text))
        let json = try h.call("export_call", ["call_id": "01KAX3A0", "format": "json"])
        let record = try JSONValue.parse(json.text)
        try expectEqual(record["id"], .string(IDs.advisor.rawValue))
        try expectEqual(record["segments"]?.arrayValue?.count, 8, "the full record, echo suspects included")
        let srt = try h.call("export_call", ["call_id": "01KAX3C0", "format": "srt"]).text
        try expect(srt.hasPrefix("1\n00:00:02,000 --> 00:00:04,000\n"))
        let vtt = try h.call("export_call", ["call_id": "01KAX3C0", "format": "vtt"]).text
        try expect(vtt.hasPrefix("WEBVTT\n"))
        let text = try h.call("export_call", ["call_id": "01KAX3C0", "format": "txt"])
        try expectEqual(text.structured?["format"], "text")
        try expectContains(text.text, "[00:00:05] আম্মু: ভালো আছি বাবা, তুমি খেয়েছো?")
        try expectContains(try h.toolError("export_call", ["call_id": "01KAX3C0", "format": "docx"]), "format must be one of")
    }

    suite.test("OpenAI summaries and title ideas: get_call, get_transcript, list_calls, search, export") {
        let fixture = try AgentFixture.withInsights("mcp-ai")
        let before = snapshot(fixture.root)
        let h = MCPHarness(fixture.library())
        let initialized = try h.initialize()
        try expectContains(try expectNotNil(initialized["result"]?["instructions"]?.stringValue), "Summaries are written by OpenAI")
        let id = JSONValue.string(IDs.summarized.rawValue)
        let overview = "Nahian and Rahim chose a tokenizer for the Bangla speech recognizer."

        let call = try h.structured("get_call", ["call_id": id])
        let summary = try expectNotNil(call["ai_summary"], "get_call has the summary")
        try expectEqual(summary["overview"], .string(overview))
        try expectEqual(summary["key_points"], ["Start from the Bengali.AI tokenizer [00:00:07]"])
        try expectEqual(summary["ideas"], [])
        try expectEqual(summary["decisions"], ["Benchmark before training"])
        try expectEqual(summary["action_items"], ["Nahian: run the benchmark by Friday [00:00:13]"])
        try expectEqual(summary["open_questions"], [])
        try expectEqual(summary["language"], "english")
        try expectEqual(summary["model"], "gpt-6.1-terra")
        try expectEqual(summary["generated_at"], "2026-11-16T11:30:00-05:00")
        try expectEqual(summary["shortened"], false)
        try expectEqual(summary["transcript_changed"], false)
        let ideas = try expectNotNil(call["title_ideas"])
        try expectEqual(ideas["titles"], ["Bangla tokenizer benchmark plan", "Choosing a tokenizer for Bangla ASR", "Bengali.AI tokenizer trial"])
        try expectEqual(ideas["model"], "gpt-6.1-terra")
        try expectEqual(ideas["transcript_changed"], false)
        let text = try h.call("get_call", ["call_id": id]).text
        try expectContains(text, "- title ideas (by OpenAI): “Bangla tokenizer benchmark plan” · “Choosing a tokenizer for Bangla ASR” · “Bengali.AI tokenizer trial”\n")
        try expectContains(text, "\n## Summary\n\(overview)\n\n### Key points\n- Start from the Bengali.AI tokenizer [00:00:07]\n\n"
                           + "### Decisions\n- Benchmark before training\n\n### Action items\n- Nahian: run the benchmark by Friday [00:00:13]\n\n"
                           + "_Summary written by OpenAI (gpt-6.1-terra) on 16 Nov 2026; it can contain mistakes._\n\n## Speakers\n")
        try expectNotContains(text, "The transcript changed")

        // Written before a speaker was named: it says so.
        let old = try h.structured("get_call", ["call_id": .string(IDs.outdated.rawValue)])
        try expectEqual(old["ai_summary"]?["transcript_changed"], true)
        try expectEqual(old["ai_summary"]?["shortened"], true)
        try expect(old["title_ideas"] == nil)
        try expectContains(try h.call("get_call", ["call_id": .string(IDs.outdated.rawValue)]).text,
                           "_The call was too long to send whole, so the middle of the transcript was left out._\n"
                           + "_The transcript changed after this summary was written._\n")
        // A call without OpenAI output has neither.
        let plain = try h.structured("get_call", ["call_id": .string(IDs.advisor.rawValue)])
        try expect(plain["ai_summary"] == nil && plain["title_ideas"] == nil)
        try expectNotContains(try h.call("get_call", ["call_id": .string(IDs.advisor.rawValue)]).text, "## Summary")

        // get_transcript: reading the whole call in Markdown starts with the summary; parts and other formats don't.
        let first = try h.call("get_transcript", ["call_id": id]).text
        try expectContains(first, "segments 1–3 of 3 · 00:00:02–00:00:18\n\n## Summary\n\(overview)\n")
        try expectContains(first, "it can contain mistakes._\n\n## Transcript\n**Nahian** [00:00:02]\nচলো tokenizer নিয়ে কথা বলি।\n")
        for args in [["format": "text"], ["format": "json"], ["from_seconds": 5], ["offset": 1]] as [[String: JSONValue]] {
            let result = try h.call("get_transcript", args.merging(["call_id": id]) { a, _ in a })
            try expect(!result.isError, result.text)
            try expectNotContains(result.text, "## Summary", "\(args)")
            try expectNotContains(result.text, overview, "\(args)")
        }
        try expectEqual(try h.structured("get_transcript", ["call_id": id])["text"]?.stringValue?.contains("Summary"), false,
                        "the structured text is the transcript")
        try expectNotContains(try h.call("get_transcript", ["call_id": .string(IDs.advisor.rawValue)]).text, "## Transcript")

        // list_calls flags calls with a summary; without notes, the summary is the preview.
        let rows = try h.structured("list_calls").array("calls")
        let row = try expectNotNil(rows.first { $0["id"] == id })
        try expectEqual(row["has_summary"], true)
        try expectEqual(row["preview"], .string(overview))
        try expectEqual(rows.first { $0["id"] == .string(IDs.advisor.rawValue) }?["has_summary"], false)
        try expectContains(try h.call("list_calls", ["query": "tokenizer"]).text, "· has an AI summary\n")
        try expectEqual(try h.structured("list_calls", ["query": "recognizer"]).array("calls").compactMap { $0["id"]?.stringValue },
                        [IDs.summarized.rawValue])

        // search_transcripts finds what only the summary says (English words for a Bangla call).
        let passage = try h.structured("search_transcripts", ["query": "recognizer"]).array("passages")[0]
        try expectEqual(passage["field"], "summary")
        try expectEqual(passage["call_id"], id)
        try expectEqual(passage["snippet"], .string(overview))
        try expect(passage["time_seconds"] == nil && passage["speaker"] == nil && passage["segment_id"] == nil)
        try expectContains(try h.call("search_transcripts", ["query": "recognizer"]).text, "- summary: \(overview)\n")

        // export_call: the .md has the section, the JSON the record's own `ai`.
        try expectContains(try h.call("export_call", ["call_id": id]).text, "\n## Summary\n\(overview)\n")
        let json = try JSONValue.parse(try h.call("export_call", ["call_id": id, "format": "json"]).text)
        try expectEqual(json["ai"]?["appliedTitle"], "Bangla tokenizer benchmark plan")
        try expectEqual(json["ai"]?["summary"]?["overview"], .string(overview))

        // The tool descriptions say what is there.
        let tools = try expectNotNil(try h.request("tools/list")["result"]?["tools"]?.arrayValue)
        func description(_ name: String) throws -> String {
            try expectNotNil(tools.first { $0["name"] == .string(name) }?["description"]?.stringValue, name)
        }
        for (tool, needle) in [("get_call", "ai_summary"), ("get_call", "title_ideas"), ("get_call", "can contain mistakes"),
                               ("list_calls", "has_summary"), ("search_transcripts", "AI summaries"),
                               ("get_transcript", "AI summary"), ("export_call", "AI summary")] {
            try expectContains(try description(tool), needle, tool)
        }
        try expect(snapshot(fixture.root) == before, "still read-only")
    }

    suite.test("new and removed calls appear without a restart") {
        let fixture = try AgentFixture("mcp-reload")
        let h = MCPHarness(fixture.library(), reloadInterval: 0)
        _ = try h.initialize()
        try expectEqual(try h.structured("list_calls").int("total"), 8)
        let fresh = CallRecord(id: fixtureID("H0"), title: "Brand new call", folder: "Research", startedAt: testNow,
                               endedAt: testNow.addingTimeInterval(120), timeZone: "America/New_York",
                               source: CallSource(appName: "Zoom", platform: .zoom), status: .ready,
                               speakers: [AgentFixture.me()],
                               segments: [AgentFixture.segment(0, 1, 3, "me", "Quantization ideas for the Bangla model.")])
        let writer = fixture.writer()
        try writer.save(fresh)
        try expectEqual(try h.structured("list_calls").int("total"), 9)
        try expectEqual(try h.structured("search_transcripts", ["query": "quantization"]).array("passages").count, 1)
        try writer.delete(IDs.labSync, deleteAudio: false)
        try expectEqual(try h.structured("list_calls").int("total"), 8)
        try expectContains(try h.toolError("get_call", ["call_id": "Lab sync"]), "No call matches")

        // Within the interval the old index is kept (the check is rate-limited).
        let slow = MCPHarness(fixture.library(), reloadInterval: 3600)
        _ = try slow.initialize()
        try writer.delete(fresh.id, deleteAudio: false)
        try expectEqual(try slow.structured("list_calls").int("total"), 8, "not rechecked yet")
    }

    suite.test("an unreadable library is explained by every tool") {
        let base = temporaryDirectory("agent-mcp-broken")
        let file = base.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        let library = AgentLibrary(location: LibraryLocation(url: file, source: .argument), settings: KanSettings())
        library.reload()
        let h = MCPHarness(library)
        _ = try h.initialize()
        try expectContains(try h.toolError("list_calls"), "couldn't be read")
        try expectContains(try h.toolError("search_transcripts", ["query": "x"]), "couldn't be read")
        try expectContains(try h.toolError("get_call", ["call_id": "01KAX3A0"]), "couldn't be read")
        let info = try h.structured("get_library_info")
        try expectContains(try info.string("load_error"), "not a folder")
        try expectEqual(info["agents_md_source"], "built-in")
    }

    suite.test("tools never write to the library") {
        let f = try fixture()
        let before = snapshot(f.root)
        let h = try harness()
        for (tool, args) in [("list_calls", [:]), ("search_transcripts", ["query": "augmentation"]), ("get_call", ["call_id": "01KAX3A0"]),
                             ("get_transcript", ["call_id": "01KAX3F0"]), ("list_folders", [:]), ("list_tags", [:]),
                             ("list_people", [:]), ("get_library_info", [:]), ("export_call", ["call_id": "01KAX3A0", "format": "json"])]
            as [(String, [String: JSONValue])] {
            _ = try h.structured(tool, args)
        }
        try expect(snapshot(f.root) == before)
    }
    return suite
}
