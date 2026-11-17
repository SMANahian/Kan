import Foundation
import KanAgent
import KanCore
import KanTestKit

func cliTests() -> TestSuite {
    let suite = TestSuite("CLI")
    var cached: AgentFixture?
    func fixture() throws -> AgentFixture {
        if let cached { return cached }
        let f = try AgentFixture("cli")
        cached = f
        return f
    }
    func run(_ args: [String], environment: [String: String] = [:]) async throws -> CLIResult {
        await runCLI(args, try fixture(), environment: environment)
    }

    suite.test("list --json: summaries with absolute times, zones and paths") {
        let result = try await run(["list", "--json"])
        try expectEqual(result.code, 0, result.stderr)
        try expectEqual(result.stderr, "")
        let json = try result.json()
        try expectEqual(try json.int("total"), 8)
        try expect(json["next_offset"]?.isNull == true)
        let calls = try json.array("calls")
        try expectEqual(calls.compactMap { $0["id"]?.stringValue }.first, IDs.weekly2.rawValue)
        let advisor = try expectNotNil(calls.first { $0["id"]?.stringValue == IDs.advisor.rawValue })
        try expectEqual(try advisor.string("title"), "Advisor meeting – augmentation idea")
        try expectEqual(try advisor.string("started_at"), "2026-11-14T10:00:12-05:00")
        try expectEqual(try advisor.string("ended_at"), "2026-11-14T10:42:25-05:00")
        try expectEqual(try advisor.string("time_zone"), "America/New_York")
        try expectEqual(try advisor.int("duration_seconds"), 2533)
        try expectEqual(advisor["people"], ["Nahian", "Prof. Rahman"])
        try expectEqual(advisor["languages"], ["en", "bn"])
        try expectEqual(advisor["tags"], ["research", "thesis"])
        try expectEqual(try advisor.string("folder"), "Research/Thesis")
        try expectEqual(try advisor.string("status"), "ready")
        try expectEqual(advisor["starred"], true)
        let md = try advisor.string("markdown_path")
        try expect(md.hasPrefix("/") && FileManager.default.fileExists(atPath: md), md)
        let ammu = try expectNotNil(calls.first { $0["id"]?.stringValue == IDs.ammu.rawValue })
        try expectEqual(try ammu.string("started_at"), "2026-11-12T21:00:00+06:00", "the call's own offset")
        try expectEqual(try ammu.string("time_zone"), "Asia/Dhaka")
    }

    suite.test("list: human table, filters and paging") {
        let all = try await run(["list"])
        try expectEqual(all.code, 0)
        let lines = all.stdout.split(separator: "\n").map(String.init)
        try expect(lines[0].hasPrefix("ID") && lines[0].contains("STARTED") && lines[0].contains("TITLE"), lines[0])
        try expectEqual(lines.count, 9)
        try expect(lines[1].hasPrefix("01KAX3D2") && lines[1].contains("2026-11-17 09:00") && lines[1].contains("Weekly sync"), lines[1])
        try expectContains(all.stdout, "আম্মুর সাথে কথা ★")
        try expectContains(all.stdout, "Zoom call [processing]")
        try expectContains(all.stdout, "#research #thesis")
        try expectContains(all.stdout, "2026-11-12 21:00", "Dhaka time for the Dhaka call")

        let huge = try await run(["list", "--json", "--limit", "9223372036854775807", "--offset", "9223372036854775807"])
        try expectEqual(huge.code, 0, "no overflow")
        try expectEqual(try huge.json().array("calls").count, 0)
        let page = try await run(["list", "--limit", "2", "--offset", "1"])
        try expectContains(page.stdout, "Showing 2–3 of 8 calls; --offset 3 shows the next page")
        let filtered = try await run(["list", "--json", "--folder", "Research", "--tag", "weekly", "--since", "2026-11-10"])
        try expectEqual(try filtered.json().array("calls").compactMap { $0["id"]?.stringValue }, [IDs.weekly2.rawValue])
        let zen = try await run(["list", "--json", "--app", "zen", "--person", "rahim"])
        try expectEqual(try zen.json().array("calls").compactMap { $0["id"]?.stringValue }, [IDs.labSync.rawValue])
        let starred = try await run(["list", "--json", "--starred", "--until", "2026-11-13"])
        try expectEqual(try starred.json().array("calls").compactMap { $0["id"]?.stringValue }, [IDs.ammu.rawValue])
        let failed = try await run(["list", "--json", "--status", "FAILED"])
        try expectEqual(try failed.json().array("calls").compactMap { $0["id"]?.stringValue }, [IDs.failed.rawValue])
        let none = try await run(["list", "--folder", "Nowhere"])
        try expectEqual(none.code, 0)
        try expectContains(none.stdout, "No calls match.")
        try expectContains(none.stderr, "there is no folder “Nowhere”")
    }

    suite.test("list: bad values are usage errors") {
        for (args, message) in [(["list", "--since", "soon"], "--since: Unrecognized date “soon”"),
                                (["list", "--since", "2026-11-15", "--until", "2026-11-14"], "--since: is after --until"),
                                (["list", "--limit", "-1"], "--limit: expected a whole number"),
                                (["list", "--limit", "ten"], "--limit: expected a whole number"),
                                (["list", "--status", "done"], "--status: use ready"),
                                (["list", "extra"], "Unexpected argument “extra” for “list”")] {
            let result = try await run(args)
            try expectEqual(result.code, ExitCode.usage, "\(args)")
            try expectContains(result.stderr, message)
            try expectContains(result.stderr, "kan help list")
            try expectEqual(result.stdout, "")
        }
    }

    suite.test("search --json: passages with call, time, speaker and snippet") {
        let result = try await run(["search", "augmentation", "--json"])
        try expectEqual(result.code, 0, result.stderr)
        let json = try result.json()
        try expectEqual(try json.int("matched_calls"), 2)
        try expectEqual(json["truncated"], false)
        let passages = try json.array("passages")
        let spoken = try expectNotNil(passages.first { $0["call_id"]?.stringValue == IDs.advisor.rawValue && $0["time_seconds"]?.doubleValue == 751 && $0["field"] == "transcript" })
        try expectEqual(try spoken.string("timestamp"), "00:12:31")
        try expectEqual(try spoken.string("at"), "2026-11-14T10:12:43-05:00")
        try expectEqual(try spoken.string("speaker"), "Prof. Rahman")
        try expectEqual(try spoken.string("started_at"), "2026-11-14T10:00:12-05:00")
        try expectEqual(try spoken.string("time_zone"), "America/New_York")
        try expectEqual(try spoken.string("title"), "Advisor meeting – augmentation idea")
        try expectEqual(try spoken.int("segment_id"), 4)
        try expectContains(try spoken.string("snippet"), "augmentation baseline")
        try expectEqual(spoken["terms"], ["augmentation"])

        let bangla = try await run(["search", "ভাষার", "মডেল", "--json"])
        let hits = try bangla.json().array("passages")
        try expectEqual(hits.count, 1)
        try expectEqual(try hits[0].string("timestamp"), "00:12:41")
        try expectEqual(hits[0]["field"], "transcript")
    }

    suite.test("search: human output, phrases, filters and empty results") {
        let result = try await run(["search", "augmentation", "--folder", "Research/Thesis"])
        try expectEqual(result.code, 0)
        try expectContains(result.stdout, "Advisor meeting – augmentation idea ★\n  2026-11-14 10:00 · Zoom · Research/Thesis · id 01KAX3A0")
        try expectContains(result.stdout, "  [00:12:31] Prof. Rahman: Speed perturbation and SpecAugment would be a good augmentation baseline.")
        try expectContains(result.stdout, "  [00:00:05] Nahian: So I was thinking about data augmentation")
        try expectContains(result.stdout, "  title: Advisor meeting – augmentation idea")
        try expectContains(result.stdout, "  bookmark [00:12:31]: augmentation idea")
        try expectNotContains(result.stdout, "Plan for the augmentation experiments", "filtered by folder")
        try expectContains(result.stdout, "4 passages in 1 call.")

        // A shell-quoted phrase stays a phrase: "speech does" occurs, "speech it" doesn't.
        let phrase = try await run(["search", "speech does", "--json"])
        try expectEqual(try phrase.json().array("passages").count, 1)
        let notPhrase = try await run(["search", "speech it", "--json"])
        try expectEqual(try notPhrase.json().array("passages").count, 0)
        let words = try await run(["search", "speech", "it", "--json"])
        try expectEqual(try words.json().array("passages").count, 1, "separate words are ANDed")

        let truncated = try await run(["search", "segment", "--limit", "3"])
        try expectContains(truncated.stdout, "3 passages in 1 call (of 900 matches; --limit 0 --per-call 0 shows all)")
        let none = try await run(["search", "zebra"])
        try expectEqual(none.code, 0)
        try expectEqual(none.stdout, "No matches for zebra.\n")
        let empty = try await run(["search", "\"\""])
        try expectEqual(empty.code, ExitCode.usage)
        try expectContains(empty.stderr, "needs search words")
    }

    suite.test("show: every format, by prefix and by title") {
        let md = try await run(["show", "01KAX3A0"])
        try expectEqual(md.code, 0, md.stderr)
        try expect(md.stdout.hasPrefix("---\nkan_id: \(IDs.advisor.rawValue)\n"), String(md.stdout.prefix(80)))
        try expectContains(md.stdout, "**Prof. Rahman** [00:00:21]")
        let txt = try await run(["show", "Lab sync", "--format", "txt"])
        try expectContains(txt.stdout, "[00:00:07] Rahim: হ্যাঁ, কালকে রাতে শেষ হয়েছে। Results ভালো।")
        let json = try await run(["show", IDs.ammu.rawValue.lowercased(), "--json"])
        let record = try json.json()
        try expectEqual(record["id"], .string(IDs.ammu.rawValue))
        try expectEqual(record["kind"], "kan.call")
        let srt = try await run(["show", "01KAX3C0", "-f", "srt"])
        try expect(srt.stdout.hasPrefix("1\n00:00:02,000 --> 00:00:04,000\nNahian: আম্মু, তুমি কেমন আছো?"), srt.stdout)
        let vtt = try await run(["show", "01KAX3C0", "--format", "vtt"])
        try expect(vtt.stdout.hasPrefix("WEBVTT\n"))
        let words = try await run(["show", "আম্মুর", "সাথে", "কথা", "--format", "md"])
        try expectContains(words.stdout, "# আম্মুর সাথে কথা", "title words are joined")
    }

    suite.test("show: not found, ambiguous and bad formats") {
        let missing = try await run(["show", "01ZZZZZZ"])
        try expectEqual(missing.code, ExitCode.notFound)
        try expectContains(missing.stderr, "No call matches “01ZZZZZZ”")
        try expectEqual(missing.stdout, "")
        let short = try await run(["show", "01K"])
        try expectEqual(short.code, ExitCode.notFound)
        let ambiguous = try await run(["show", "Weekly sync"])
        try expectEqual(ambiguous.code, ExitCode.ambiguous)
        try expectContains(ambiguous.stderr, "matches 2 calls")
        try expectContains(ambiguous.stderr, "\(IDs.weekly2.rawValue)  2026-11-17 09:00  Weekly sync  (Research)")
        try expectContains(ambiguous.stderr, IDs.weekly1.rawValue)
        let format = try await run(["show", "01KAX3A0", "--format", "pdf"])
        try expectEqual(format.code, ExitCode.usage)
        try expectContains(format.stderr, "--format: use md, txt, json, srt or vtt")
        let conflict = try await run(["show", "01KAX3A0", "--format", "md", "--json"])
        try expectEqual(conflict.code, ExitCode.usage)
    }

    suite.test("export: stdout, files, folders, --force, and never into the library") {
        let f = try fixture()
        let out = temporaryDirectory("agent-export")
        let stdout = try await run(["export", "01KAX3A0", "--format", "json"])
        try expectEqual(try stdout.json()["id"], .string(IDs.advisor.rawValue))

        let file = out.appendingPathComponent("advisor.srt").path
        let written = try await run(["export", "01KAX3A0", "--out", file])
        try expectEqual(written.code, 0, written.stderr)
        try expectEqual(written.stdout, file + "\n")
        try expectContains(try String(contentsOfFile: file, encoding: .utf8), "00:00:05,000 --> 00:00:09,500", "format from the extension")

        let again = try await run(["export", "01KAX3A0", "--out", file])
        try expectEqual(again.code, ExitCode.failure)
        try expectContains(again.stderr, "already exists; use --force")
        let forced = try await run(["export", "01KAX3A0", "--out", file, "--format", "txt", "--force", "--json"])
        try expectEqual(forced.code, 0, forced.stderr)
        let summary = try forced.json()
        try expectEqual(summary["format"], "text")
        try expectEqual(summary["path"], .string(file))
        try expectContains(try String(contentsOfFile: file, encoding: .utf8), "Advisor meeting – augmentation idea\n")

        var folder: CLIResult?
        let logged = try await loggedText { folder = try await run(["export", "01KAX3C0", "--out", out.path + "/"]) }
        try expectEqual(folder?.code, 0, folder?.stderr ?? "")
        try expectEqual(folder?.stdout, out.appendingPathComponent("2026-11-12 2100 আম্মুর সাথে কথা.md").path + "\n")
        try expectContains(logged, "Exported \(IDs.ammu.rawValue) as markdown")
        try expect(!logged.contains("আম্মুর") && !logged.contains(out.path), "the export's file name is its title:\n\(logged)")
        let missingFolder = try await run(["export", "01KAX3C0", "--out", out.path + "/nope/x.md"])
        try expectEqual(missingFolder.code, ExitCode.failure)
        try expectContains(missingFolder.stderr, "doesn't exist")

        let before = snapshot(f.root)
        let inside = try await run(["export", "01KAX3A0", "--format", "json", "--out", f.root.appendingPathComponent("Inbox").path])
        try expectEqual(inside.code, ExitCode.failure)
        try expectContains(inside.stderr, "doesn't write inside the library")
        let link = out.appendingPathComponent("library-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
        let viaLink = try await run(["export", "01KAX3A0", "--out", link.appendingPathComponent("Research/copy.json").path])
        try expectEqual(viaLink.code, ExitCode.failure, "a symlink into the library is still the library")
        let upperCase = f.root.path.replacingOccurrences(of: "/Library", with: "/LIBRARY") + "/copy.md"
        let caseVariant = try await run(["export", "01KAX3A0", "--out", upperCase])
        try expectEqual(caseVariant.code, ExitCode.failure, "case-insensitive volumes: same folder")
        try expect(snapshot(f.root) == before, "nothing was written into the library")
    }

    suite.test("folders, tags and people") {
        let folders = try await run(["folders", "--json"])
        let rows = try folders.json().array("folders")
        try expectEqual(rows.compactMap { $0["name"]?.stringValue }, ["", "Personal", "Research", "Research/Seminars", "Research/Thesis"])
        try expectEqual(rows[2]["total"], 4)
        try expectEqual(rows[0]["display_name"], "Inbox")
        let tree = try await run(["folders"])
        try expectEqual(tree.stdout, "Inbox       3\nPersonal    1\nResearch    2  (4 with subfolders)\n  Seminars  1\n  Thesis    1\n")

        let tags = try await run(["tags", "--json"])
        try expectEqual(try tags.json().array("tags").first?["name"], "weekly")
        try expectEqual(try tags.json().array("tags").first?["count"], 2)
        let tagText = try await run(["tags"])
        try expectContains(tagText.stdout, "2  weekly\n")
        let people = try await run(["people", "--json"])
        let names = try people.json().array("people").compactMap { $0["name"]?.stringValue }
        try expectEqual(names.first, "Prof. Rahman")
        try expect(names.contains("আম্মু") && names.contains("Rahim") && names.contains("Dr. Karim"), "\(names)")
        try expect(!names.contains("Nahian") && !names.contains("Speaker 1"), "not the user, no placeholders")
        let peopleText = try await run(["people"])
        try expectContains(peopleText.stdout, "3  Prof. Rahman\n")
    }

    suite.test("path and open") {
        let f = try fixture()
        let root = try await run(["path"])
        try expectEqual(root.stdout, f.root.standardizedFileURL.path + "\n")
        let rootJSON = try await run(["path", "--json"])
        try expectEqual(try rootJSON.json()["source"], "settings")
        let call = try await run(["path", "01KAX3A0"])
        try expectEqual(call.stdout, try f.markdownPath(IDs.advisor) + "\n")
        let callJSON = try await run(["path", "01KAX3A0", "--json"]).json()
        try expect((try callJSON.string("json_path")).hasSuffix("Advisor meeting – augmentation idea.json"))

        let opened = Recorder()
        let result = await runCLI(["open", "Lab sync"], f, opened: opened)
        try expectEqual(result.code, 0, result.stderr)
        try expectEqual(opened.all, [[try f.markdownPath(IDs.labSync)]])
        try expectEqual(result.stdout, "")
        let failing = await runCLI(["open", "Lab sync"], f, openError: CLIFailure("Couldn't open it: no app"))
        try expectEqual(failing.code, ExitCode.failure)
        try expectContains(failing.stderr, "Couldn't open it")
        let unknown = await runCLI(["open", "nothing like this"], f, opened: opened)
        try expectEqual(unknown.code, ExitCode.notFound)
        try expectEqual(opened.all.count, 1)
    }

    suite.test("info: location, counts and settings") {
        let result = try await run(["info", "--json"])
        try expectEqual(result.code, 0, result.stderr)
        let info = try result.json()
        try expectEqual(info["calls"], 8)
        try expectEqual(info["calls_by_status"]?["ready"], 6)
        try expectEqual(info["library_source"], "settings")
        try expectEqual(info["settings"]?["user_name"], "Nahian")
        try expectEqual(info["first_call_at"], "2026-11-01T13:00:00-05:00")
        try expectEqual(info["last_call_at"], "2026-11-17T09:00:00-05:00")
        let text = try await run(["info"])
        try expectContains(text.stdout, "Calls     8 (6 ready, 1 failed, 1 processing) · 2 starred")
        try expectContains(text.stdout, "you: Nahian")
        try expectContains(text.stdout, "kan mcp-config")
    }

    suite.test("library from --library and KAN_LIBRARY; a missing or broken library") {
        let f = try fixture()
        let other = try AgentFixture("cli-other", populate: false)
        try other.writer().save(CallRecord(id: fixtureID("Z9"), title: "Only call", startedAt: testNow,
                                           endedAt: testNow.addingTimeInterval(30), timeZone: "UTC",
                                           source: CallSource(appName: "FaceTime", platform: .facetime), status: .ready))
        let viaEnv = try await run(["list", "--json"], environment: ["KAN_LIBRARY": other.root.path])
        try expectEqual(try viaEnv.json().int("total"), 1)
        let viaArg = try await run(["--library", other.root.path, "list", "--json"], environment: ["KAN_LIBRARY": "/nonexistent"])
        try expectEqual(try viaArg.json().int("total"), 1, "--library beats KAN_LIBRARY")

        let missingRoot = f.base.appendingPathComponent("no-library-here").path
        let missing = try await run(["list", "--library", missingRoot])
        try expectEqual(missing.code, 0)
        try expectContains(missing.stderr, "doesn't exist yet")
        try expectContains(missing.stdout, "No calls yet")
        try expect(!FileManager.default.fileExists(atPath: missingRoot), "kan never creates the library")
        let show = try await run(["show", "x1234", "--library", missingRoot])
        try expectEqual(show.code, ExitCode.notFound)

        let file = f.base.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let broken = try await run(["list", "--library", file.path])
        try expectEqual(broken.code, ExitCode.failure)
        try expectContains(broken.stderr, "Can't read the library")
        let info = try await run(["info", "--library", file.path])
        try expectEqual(info.code, ExitCode.failure)
        try expectContains(info.stdout, "can't be read")
    }

    suite.test("a library this process may not read is an error, never an empty library") {
        // What an agent host without access to ~/Documents sees: stat fails with EPERM/EACCES.
        let f = try fixture()
        let documents = f.base.appendingPathComponent("Locked Documents", isDirectory: true)
        let root = documents.appendingPathComponent("Kan", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path) }

        let list = try await run(["list", "--library", root.path])
        try expectEqual(list.code, ExitCode.failure, list.stdout)
        try expectContains(list.stderr, "was denied")
        try expectContains(list.stderr, "Files & Folders")
        try expect(!list.stdout.contains("No calls yet") && !list.stderr.contains("doesn't exist yet"), list.stderr)
        let info = try await run(["info", "--library", root.path])
        try expectEqual(info.code, ExitCode.failure)
        try expectContains(info.stdout, "was denied")
        try expect(!info.stdout.contains("doesn't exist yet"), info.stdout)

        let library = AgentLibrary(location: LibraryLocation(url: root, source: .argument), settings: KanSettings())
        library.reload()
        let h = MCPHarness(library)
        _ = try h.initialize()
        try expectContains(try h.toolError("list_calls"), "was denied")
        try expect(try h.call("get_library_info").text.contains("doesn't exist yet") == false)
    }

    suite.test("mcp-config: Claude Code, Claude Desktop, Codex, Cursor") {
        let result = try await run(["mcp-config"])
        try expectEqual(result.code, 0)
        try expectContains(result.stdout, "claude mcp add kan -- /Applications/Kan.app/Contents/MacOS/kan mcp\n")
        try expectContains(result.stdout, "claude_desktop_config.json")
        try expectContains(result.stdout, "[mcp_servers.kan]\n    command = \"/Applications/Kan.app/Contents/MacOS/kan\"\n    args = [\"mcp\"]")
        try expectContains(result.stdout, "~/.cursor/mcp.json")
        try expectNotContains(result.stdout, "development build")

        let json = try await run(["mcp-config", "--json"]).json()
        try expectEqual(json["command"], "/Applications/Kan.app/Contents/MacOS/kan")
        try expectEqual(json["args"], ["mcp"])
        let desktop = try JSONValue.parse(try json.string("claude_desktop"))
        try expectEqual(desktop["mcpServers"]?["kan"]?["command"], "/Applications/Kan.app/Contents/MacOS/kan")
        try expectEqual(desktop["mcpServers"]?["kan"]?["args"], ["mcp"])
        try expectEqual(try JSONValue.parse(try json.string("cursor")), desktop)

        // An explicit library and an awkward path are quoted for each format.
        let awkward = await runCLI(["mcp-config", "--library", "/Users/me/My Notes/Kan"], try fixture(),
                                   executable: "/Users/me/dev/Kan's build/.build/debug/kan")
        try expectContains(awkward.stdout, "claude mcp add kan -- '/Users/me/dev/Kan'\\''s build/.build/debug/kan' mcp --library '/Users/me/My Notes/Kan'")
        try expectContains(awkward.stdout, "args = [\"mcp\", \"--library\", \"/Users/me/My Notes/Kan\"]")
        try expectContains(awkward.stdout, "development build")
        let awkwardJSON = await runCLI(["mcp-config", "--json", "--library", "/Users/me/My Notes/Kan"], try fixture())
        let entry = try JSONValue.parse(try awkwardJSON.json().string("claude_desktop"))
        try expectEqual(entry["mcpServers"]?["kan"]?["args"], ["mcp", "--library", "/Users/me/My Notes/Kan"])
    }

    suite.test("help, version, unknown commands, transcribe hook") {
        let help = try await run(["help"])
        try expectEqual(help.code, 0)
        for command in ["list", "search", "show", "export", "folders", "tags", "people", "path", "open", "info", "mcp", "mcp-config", "transcribe"] {
            try expectContains(help.stdout, "  \(command)")
        }
        try expectContains(help.stdout, "Exit codes: 0 ok, 1 error, 2 usage error, 3 call not found, 4 several calls match.")
        let commandHelp = try await run(["export", "--help"])
        try expectEqual(commandHelp.code, 0)
        try expect(commandHelp.stdout.hasPrefix("Usage: kan export <call> [--format F] [--out PATH] [--force]"), commandHelp.stdout)
        try expectContains(commandHelp.stdout, "-o, --out PATH")
        for line in commandHelp.stdout.split(separator: "\n") where !line.hasPrefix("  ") {
            try expect(line.count <= 100, "help lines are wrapped: \(line)")
        }
        let unknownTopic = try await run(["help", "nope"])
        try expectEqual(unknownTopic.code, ExitCode.usage)
        let version = try await run(["--version"])
        try expectEqual(version.stdout, "kan \(KanVersion.current)\n")
        let unknown = try await run(["lst"])
        try expectEqual(unknown.code, ExitCode.usage)
        try expectContains(unknown.stderr, "Did you mean “list”?")

        let transcribed = Recorder()
        let hook = await runCLI(["transcribe", "call.wav", "--language", "bn"], try fixture(), transcribed: transcribed)
        try expectEqual(hook.code, 7, "the hook's exit code is kan's")
        try expectEqual(transcribed.all, [["call.wav", "--language", "bn"]])
    }

    suite.test("kan mcp in-process: messages in, responses out") {
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_calls","arguments":{"limit":1}}}"#,
        ]
        let result = await runCLI(["mcp"], try fixture(), mcpInput: input)
        try expectEqual(result.code, 0)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        try expectEqual(lines.count, 2, "one response per request; none for the notification or the empty line")
        try expectEqual(try JSONValue.parse(lines[0])["result"]?["protocolVersion"], "2025-06-18")
        let list = try JSONValue.parse(lines[1])
        try expectEqual(list["result"]?["structuredContent"]?["calls"]?.arrayValue?.count, 1)
    }

    suite.test("no command writes to the library") {
        let f = try fixture()
        let before = snapshot(f.root)
        let out = temporaryDirectory("agent-readonly")
        for args in [["list"], ["list", "--json"], ["search", "augmentation"], ["show", "01KAX3A0"], ["folders"], ["tags"],
                     ["people"], ["info"], ["path", "01KAX3A0"], ["export", "01KAX3A0", "--out", out.path + "/"],
                     ["mcp-config"], ["search", "ভাষা", "--json"]] {
            _ = try await run(args)
        }
        _ = await runCLI(["open", "01KAX3A0"], f, opened: Recorder())
        try expect(snapshot(f.root) == before, "the library is unchanged")
    }
    return suite
}
