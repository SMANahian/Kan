import Foundation
import KanAgent
import KanCore
import KanTestKit

func argumentTests() -> TestSuite {
    let suite = TestSuite("Arguments")

    func run(_ args: [String]) throws -> ParsedCommand {
        guard case .run(let parsed) = try ArgumentParser.parse(args) else { throw TestFailure("expected a command for \(args)") }
        return parsed
    }

    func failure(_ args: [String]) throws -> ArgumentError {
        do {
            _ = try ArgumentParser.parse(args)
        } catch let error as ArgumentError {
            return error
        }
        throw TestFailure("expected a usage error for \(args)")
    }

    suite.test("command, words and value options") {
        let parsed = try run(["search", "data", "augmentation", "--tag", "research", "--limit", "5"])
        try expectEqual(parsed.name, "search")
        try expectEqual(parsed.positionals, ["data", "augmentation"])
        try expectEqual(parsed.value("tag"), "research")
        try expectEqual(parsed.value("limit"), "5")
    }

    suite.test("--name=value, flags, and options between words") {
        let parsed = try run(["search", "ভাষা", "--folder=Research/Thesis", "মডেল", "--starred", "--json"])
        try expectEqual(parsed.positionals, ["ভাষা", "মডেল"])
        try expectEqual(parsed.value("folder"), "Research/Thesis")
        try expect(parsed.flag("starred") && parsed.flag("json"))
        try expectEqual(try run(["list", "--folder="]).value("folder"), "", "an empty inline value is a value")
    }

    suite.test("global options before the command") {
        let parsed = try run(["--library", "/tmp/lib", "--json", "list", "--since", "7d"])
        try expectEqual(parsed.name, "list")
        try expectEqual(parsed.value("library"), "/tmp/lib")
        try expect(parsed.flag("json"))
        try expectEqual(parsed.value("since"), "7d")
    }

    suite.test("short options") {
        let parsed = try run(["export", "01KAX3A", "-f", "srt", "-o", "out.srt"])
        try expectEqual(parsed.value("format"), "srt")
        try expectEqual(parsed.value("out"), "out.srt")
        try expectEqual(try run(["list", "-n", "3"]).value("limit"), "3")
    }

    suite.test("-- ends the options; negative numbers are words") {
        let parsed = try run(["search", "--", "--not-an-option", "-x"])
        try expectEqual(parsed.positionals, ["--not-an-option", "-x"])
        try expectEqual(try run(["search", "-5"]).positionals, ["-5"])
        // A value may look like a negative number (validated later by the command).
        try expectEqual(try run(["list", "--limit", "-1"]).value("limit"), "-1")
    }

    suite.test("aliases") {
        try expectEqual(try run(["ls"]).name, "list")
        try expectEqual(try run(["find", "x"]).name, "search")
        try expectEqual(try run(["cat", "x"]).name, "show")
    }

    suite.test("unknown options and commands") {
        let option = try failure(["list", "--bogus"])
        try expectEqual(option.kind, .unknownOption("--bogus"))
        try expectEqual(option.command, "list")
        try expectEqual(try failure(["list", "-q"]).kind, .unknownOption("-q"))
        try expectEqual(try failure(["--bogus", "list"]).kind, .unknownOption("--bogus"))
        try expectEqual(try failure(["serch", "x"]).kind, .unknownCommand("serch", suggestion: "search"))
        try expectEqual(try failure(["xyzzy"]).kind, .unknownCommand("xyzzy", suggestion: nil))
        try expectEqual(try failure(["foldrs"]).kind, .unknownCommand("foldrs", suggestion: "folders"))
    }

    suite.test("missing, unexpected and repeated values") {
        try expectEqual(try failure(["list", "--limit"]).kind, .missingValue("--limit"))
        try expectEqual(try failure(["list", "--folder", "--json"]).kind, .missingValue("--folder"), "a value can't be an option")
        try expectEqual(try failure(["list", "--starred=yes"]).kind, .unexpectedValue("--starred"))
        let repeated = try failure(["list", "--tag", "a", "--tag", "b"])
        try expectEqual(repeated.kind, .repeated("--tag"))
        try expectEqual(repeated.command, "list")
    }

    suite.test("positional rules") {
        try expectEqual(try failure(["folders", "extra"]).kind, .unexpectedArgument("extra"))
        try expectEqual(try failure(["show"]).kind, .missingArgument("a call"))
        try expectEqual(try failure(["search"]).kind, .missingArgument("search words"))
        try expectEqual(try failure(["path", "a", "b"]).kind, .unexpectedArgument("b"))
        try expectEqual(try run(["path"]).positionals, [])
        try expectEqual(try run(["show", "Weekly", "sync"]).positionals, ["Weekly", "sync"])
    }

    suite.test("help, version and transcribe") {
        try expectEqual(try ArgumentParser.parse([]), .help(topic: nil))
        try expectEqual(try ArgumentParser.parse(["help"]), .help(topic: nil))
        try expectEqual(try ArgumentParser.parse(["-h"]), .help(topic: nil))
        try expectEqual(try ArgumentParser.parse(["help", "search"]), .help(topic: "search"))
        try expectEqual(try ArgumentParser.parse(["search", "--help"]), .help(topic: "search"))
        try expectEqual(try ArgumentParser.parse(["--help", "export"]), .help(topic: "export"))
        try expectEqual(try ArgumentParser.parse(["show", "-h"]), .help(topic: "show"), "help wins over a missing argument")
        try expectEqual(try ArgumentParser.parse(["--version"]), .version)
        try expectEqual(try ArgumentParser.parse(["version"]), .version)
        try expectEqual(try ArgumentParser.parse(["transcribe", "a.wav", "--model", "x", "--help"]),
                        .transcribe(["a.wav", "--model", "x", "--help"]), "transcribe gets its arguments untouched")
        try expectEqual(try ArgumentParser.parse(["--library", "/x", "transcribe", "a.wav"]), .transcribe(["--library", "/x", "a.wav"]),
                        "options before the word go to the transcriber too")
        try expectEqual(try ArgumentParser.parse(["--help", "transcribe"]), .transcribe(["--help"]), "the transcriber explains itself")
    }

    suite.test("query words keep shell-quoted phrases") {
        // `kan search "data augmentation" ভাষা` arrives as two words, the first with a space.
        try expectEqual(CLIQuery.text(["data augmentation", "ভাষা"]), "\"data augmentation\" ভাষা")
        try expectEqual(CLIQuery.text(["\"already quoted\""]), "\"already quoted\"")
        try expect(!CLIQuery.hasTerms("\"\"  “”"))
        try expect(CLIQuery.hasTerms("ভাষা"))
    }
    return suite
}

func dateTests() -> TestSuite {
    let suite = TestSuite("Dates")
    let input = DateInput(now: testNow, timeZone: newYork)

    func iso(_ date: Date, _ zone: String = "America/New_York") -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: zone)
        return f.string(from: date)
    }

    suite.test("YYYY-MM-DD covers the whole local day") {
        try expectEqual(iso(try input.parse("2026-11-14", as: .start)), "2026-11-14T00:00:00.000-05:00")
        try expectEqual(iso(try input.parse("2026-11-14", as: .end)), "2026-11-14T23:59:59.999-05:00")
        // Daylight saving ended on 1 Nov 2026 in New York: that day has 25 hours.
        try expectEqual(iso(try input.parse("2026-11-01", as: .end)), "2026-11-01T23:59:59.999-05:00")
        try expectEqual(iso(try input.parse("2026-11-01", as: .start)), "2026-11-01T00:00:00.000-04:00")
    }

    suite.test("months and years") {
        try expectEqual(iso(try input.parse("2026-11", as: .start)), "2026-11-01T00:00:00.000-04:00")
        try expectEqual(iso(try input.parse("2026-11", as: .end)), "2026-11-30T23:59:59.999-05:00")
        try expectEqual(iso(try input.parse("2026", as: .end)), "2026-12-31T23:59:59.999-05:00")
    }

    suite.test("ISO-8601 with an offset or Z") {
        try expectEqual(iso(try input.parse("2026-11-14T10:00:12-05:00", as: .start)), "2026-11-14T10:00:12.000-05:00")
        try expectEqual(iso(try input.parse("2026-11-14T15:00:12Z", as: .end)), "2026-11-14T10:00:12.000-05:00")
        try expectEqual(iso(try input.parse("2026-11-14T10:00:12.250+06:00", as: .start), "Asia/Dhaka"), "2026-11-14T10:00:12.250+06:00")
        try expectEqual(iso(try input.parse("2026-11-14 10:00:12-05:00", as: .start)), "2026-11-14T10:00:12.000-05:00")
    }

    suite.test("local date-times without an offset") {
        try expectEqual(iso(try input.parse("2026-11-14T10:00", as: .start)), "2026-11-14T10:00:00.000-05:00")
        try expectEqual(iso(try input.parse("2026-11-14 10:00:30", as: .end)), "2026-11-14T10:00:30.000-05:00")
        let dhaka = DateInput(now: testNow, timeZone: TimeZone(identifier: "Asia/Dhaka") ?? .current)
        try expectEqual(iso(try dhaka.parse("2026-11-14T10:00", as: .start), "Asia/Dhaka"), "2026-11-14T10:00:00.000+06:00")
    }

    suite.test("today, yesterday, now (any case)") {
        try expectEqual(iso(try input.parse("today", as: .start)), "2026-11-17T00:00:00.000-05:00")
        try expectEqual(iso(try input.parse("Today", as: .end)), "2026-11-17T23:59:59.999-05:00")
        try expectEqual(iso(try input.parse("yesterday", as: .start)), "2026-11-16T00:00:00.000-05:00")
        try expectEqual(iso(try input.parse("YESTERDAY", as: .end)), "2026-11-16T23:59:59.999-05:00")
        try expectEqual(try input.parse("now", as: .end), testNow)
    }

    suite.test("ages: 7d, 12h, 2w, 3 days ago") {
        try expectEqual(try input.parse("7d", as: .start), testNow.addingTimeInterval(-7 * 86_400))
        try expectEqual(try input.parse("7D", as: .end), testNow.addingTimeInterval(-7 * 86_400))
        try expectEqual(try input.parse("12h", as: .start), testNow.addingTimeInterval(-12 * 3600))
        try expectEqual(try input.parse("2w", as: .start), testNow.addingTimeInterval(-14 * 86_400))
        try expectEqual(try input.parse("3 days ago", as: .start), testNow.addingTimeInterval(-3 * 86_400))
        try expectEqual(try input.parse("0d", as: .start), testNow)
    }

    suite.test("invalid dates are rejected with the accepted forms") {
        for bad in ["2026-02-30", "2026-13-01", "2026-1-5", "tomorrowish", "", "  ", "7x", "d7", "2026-11-14T25:00", "1234567d"] {
            do {
                _ = try input.parse(bad, as: .start)
                throw TestFailure("“\(bad)” should be rejected")
            } catch let error as DateInputError {
                try expectContains(error.localizedDescription, "YYYY-MM-DD")
            }
        }
    }

    suite.test("the time zone decides where a day starts") {
        let dhaka = DateInput(now: testNow, timeZone: TimeZone(identifier: "Asia/Dhaka") ?? .current)
        let a = try input.parse("2026-11-14", as: .start)
        let b = try dhaka.parse("2026-11-14", as: .start)
        try expectEqual(a.timeIntervalSince(b), 11 * 3600)
    }
    return suite
}

func resolverTests() -> TestSuite {
    let suite = TestSuite("Call ids")
    var cached: (AgentFixture, [CallSummary])?
    func fixture() throws -> (AgentFixture, [CallSummary]) {
        if let cached { return cached }
        let f = try AgentFixture("resolver")
        let value = (f, f.writer().summaries())
        cached = value
        return value
    }
    func resolve(_ input: String) throws -> CallSummary {
        let (f, summaries) = try fixture()
        return try CallResolver.resolve(input, in: summaries, root: f.root)
    }
    func failure(_ input: String) throws -> CallResolutionError {
        do {
            _ = try resolve(input)
        } catch let error as CallResolutionError {
            return error
        }
        throw TestFailure("“\(input)” should not resolve")
    }

    suite.test("full ids, any case") {
        try expectEqual(try resolve(IDs.advisor.rawValue).id, IDs.advisor)
        try expectEqual(try resolve(IDs.advisor.rawValue.lowercased()).id, IDs.advisor)
        try expectEqual(try resolve("  \(IDs.labSync.rawValue)\n").id, IDs.labSync)
    }

    suite.test("unique prefixes of at least 4 characters") {
        try expectEqual(try resolve("01KAX3A").id, IDs.advisor)
        try expectEqual(try resolve("01kax3c").id, IDs.ammu)
        try expectEqual(try resolve("01KAX3D1").id, IDs.weekly1)
    }

    suite.test("ambiguous prefixes list the candidates, newest first") {
        guard case .ambiguous(let input, let candidates) = try failure("01KAX3D") else { throw TestFailure("expected ambiguous") }
        try expectEqual(input, "01KAX3D")
        try expectEqual(candidates.map(\.id), [IDs.weekly2, IDs.weekly1])
        let message = try failure("01KA").localizedDescription
        try expectContains(message, "matches 8 calls")
        try expectContains(message, IDs.advisor.rawValue)
        try expectContains(message, "2026-11-14 10:00  Advisor meeting – augmentation idea  (Research/Thesis)")
    }

    suite.test("prefixes shorter than 4 characters or with non-id characters don't count") {
        try expectEqual(try failure("01K"), .notFound("01K"))
        try expectEqual(try failure("01KAX3-A"), .notFound("01KAX3-A"))
        try expectEqual(try failure(""), .empty)
        try expectEqual(try failure("   "), .empty)
    }

    suite.test("exact titles, case-insensitive, Bangla and NFD input") {
        try expectEqual(try resolve("lab SYNC").id, IDs.labSync)
        try expectEqual(try resolve("আম্মুর সাথে কথা").id, IDs.ammu)
        try expectEqual(try resolve("আম্মুর সাথে কথা".decomposedStringWithCanonicalMapping).id, IDs.ammu)
        try expectEqual(try resolve("Advisor meeting – augmentation idea").id, IDs.advisor)
        try expectEqual(try failure("Advisor meeting"), .notFound("Advisor meeting"), "titles must match exactly")
    }

    suite.test("duplicate titles are ambiguous") {
        guard case .ambiguous(_, let candidates) = try failure("weekly sync") else { throw TestFailure("expected ambiguous") }
        try expectEqual(Set(candidates.map(\.id)), [IDs.weekly1, IDs.weekly2])
    }

    suite.test("file paths: relative to the root, absolute, .md or .json") {
        let (f, _) = try fixture()
        let summary = try f.summary(IDs.advisor)
        try expectEqual(try resolve(summary.markdownPath).id, IDs.advisor)
        try expectEqual(try resolve(summary.jsonPath).id, IDs.advisor)
        try expectEqual(try resolve("./" + summary.markdownPath).id, IDs.advisor)
        let absolute = f.root.appendingPathComponent(summary.markdownPath).path
        try expectEqual(try resolve(absolute).id, IDs.advisor)
        // The temporary directory is /var/folders/…, a symlink to /private/var/folders/….
        let real = realPath(URL(fileURLWithPath: absolute))
        try expect(real != absolute, "the test needs a symlinked path (\(real))")
        try expectEqual(try resolve(real).id, IDs.advisor)
        try expectEqual(try failure("/elsewhere/" + summary.markdownPath), .notFound("/elsewhere/" + summary.markdownPath))
    }

    suite.test("shortest unique prefix length") {
        try expectEqual(CallResolver.uniquePrefixLength(for: [IDs.advisor, IDs.labSync]), 8)
        try expectEqual(CallResolver.uniquePrefixLength(for: [IDs.weekly1, IDs.weekly2]), 8)
        let close = [fixtureID("D1AAAAAA"), fixtureID("D1AAAAAB")]
        try expectEqual(CallResolver.uniquePrefixLength(for: close), 14)
        try expectEqual(CallResolver.uniquePrefixLength(for: []), 8)
    }
    return suite
}

func locationTests() -> TestSuite {
    let suite = TestSuite("Library location")
    let cwd = URL(fileURLWithPath: "/Users/someone/work", isDirectory: true)

    suite.test("--library beats KAN_LIBRARY beats settings beats the default") {
        var settings = KanSettings()
        settings.libraryPath = "/Volumes/Notes/Kan"
        let env = ["KAN_LIBRARY": "/env/lib"]
        try expectEqual(LibraryLocation.resolve(argument: "/arg/lib", environment: env, settings: settings, currentDirectory: cwd),
                        LibraryLocation(url: URL(fileURLWithPath: "/arg/lib", isDirectory: true), source: .argument))
        try expectEqual(LibraryLocation.resolve(argument: nil, environment: env, settings: settings, currentDirectory: cwd).source, .environment)
        let fromSettings = LibraryLocation.resolve(argument: "  ", environment: ["KAN_LIBRARY": ""], settings: settings, currentDirectory: cwd)
        try expectEqual(fromSettings.source, .settings)
        try expectEqual(fromSettings.url.path, "/Volumes/Notes/Kan")
        let fallback = LibraryLocation.resolve(argument: nil, environment: [:], settings: KanSettings(), currentDirectory: cwd)
        try expectEqual(fallback.source, .defaultLocation)
        try expectEqual(fallback.url.path, KanPaths.defaultLibrary.path, "KAN_HOME redirects the default in tests")
    }

    suite.test("~ and relative paths") {
        let relative = LibraryLocation.resolve(argument: "notes/../Kan", environment: [:], settings: KanSettings(), currentDirectory: cwd)
        try expectEqual(relative.url.path, "/Users/someone/work/Kan")
        let home = LibraryLocation.resolve(argument: "~/Documents/Kan", environment: [:], settings: KanSettings(), currentDirectory: cwd)
        try expectEqual(home.url.path, NSHomeDirectory() + "/Documents/Kan")
    }

    suite.test("settings are read without touching a damaged file") {
        let dir = temporaryDirectory("agent-settings")
        let file = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: file)
        let loaded = AgentSettings.load(from: file)
        try expect(loaded.problem != nil && loaded.fileExists)
        try expectEqual(loaded.settings, KanSettings())
        try expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["settings.json"], "not moved aside")
        try expectEqual(FileManager.default.contents(atPath: file.path), Data("{ not json".utf8))
        let missing = AgentSettings.load(from: dir.appendingPathComponent("none.json"))
        try expect(missing.problem == nil && !missing.fileExists)
    }

    suite.test("the library named in settings is used, with the user's name") {
        let fixture = try AgentFixture("location-settings")
        let library = AgentLibrary.open(libraryArgument: nil, environment: [:], currentDirectory: fixture.base,
                                        settingsFile: fixture.settingsFile)
        try expectEqual(library.location.source, .settings)
        try expectEqual(library.root.path, fixture.root.standardizedFileURL.path)
        try expectEqual(library.store.summaries().count, 8)
        try expectEqual(library.settings.effectiveUserName, "Nahian")
    }

    suite.test("a missing root is an empty library; a file is an error") {
        let dir = temporaryDirectory("agent-missing-root")
        let missing = AgentLibrary(location: LibraryLocation(url: dir.appendingPathComponent("nope"), source: .argument),
                                   settings: KanSettings())
        missing.reload()
        try expect(missing.loadError == nil && !missing.rootExists)
        try expect(missing.store.summaries().isEmpty)
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("nope").path), "never created")
        let file = dir.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let broken = AgentLibrary(location: LibraryLocation(url: file, source: .argument), settings: KanSettings())
        broken.reload()
        try expectContains(try expectNotNil(broken.loadError), "not a folder")
    }

    suite.test("changes on disk are noticed by the fingerprint check") {
        let fixture = try AgentFixture("location-reload")
        let library = fixture.library()
        try expect(!library.reloadIfChanged(minimumInterval: 0), "nothing changed")
        var record = CallRecord(title: "Fresh call", startedAt: testNow, endedAt: testNow.addingTimeInterval(60),
                                timeZone: "America/New_York", source: CallSource(appName: "Zoom", platform: .zoom))
        record.status = .ready
        try fixture.writer().save(record)
        try expect(!library.reloadIfChanged(minimumInterval: 3600), "within the interval nothing is checked")
        try expect(library.reloadIfChanged(minimumInterval: 0))
        try expect(library.store.contains(record.id))
        // An edit made in place (no rename) is noticed too.
        let json = try expectNotNil(fixture.writer().files(for: IDs.labSync)).json
        var text = try String(contentsOf: json, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"Lab sync\"", with: "\"Lab sync (edited)\"")
        let handle = try FileHandle(forWritingTo: json)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        try expect(library.reloadIfChanged(minimumInterval: 0))
        try expectEqual(library.store.summary(IDs.labSync)?.title, "Lab sync (edited)")
    }
    return suite
}
