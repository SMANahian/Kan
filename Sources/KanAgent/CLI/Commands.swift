import Foundation

/// A `kan` command: its options and help.
public struct CommandSpec: Sendable, Equatable {
    public let name: String
    public let aliases: [String]
    /// "search <words…> [filters]"
    public let synopsis: String
    /// One line for the command list.
    public let summary: String
    /// Paragraphs shown by `kan help <command>`.
    public let details: String
    public let options: [OptionSpec]
    public let positionals: PositionalRule
    public let examples: [String]

    init(_ name: String, aliases: [String] = [], synopsis: String, summary: String, details: String = "",
         options: [OptionSpec] = [], positionals: PositionalRule = .none, examples: [String] = []) {
        self.name = name
        self.aliases = aliases
        self.synopsis = synopsis
        self.summary = summary
        self.details = details
        self.options = options
        self.positionals = positionals
        self.examples = examples
    }

    // MARK: Options

    public static let globalOptions: [OptionSpec] = [
        OptionSpec("library", value: "PATH", help: "Library folder (default: Kan's setting, else ~/Documents/Kan; or set KAN_LIBRARY)"),
        OptionSpec("json", help: "Machine-readable JSON on stdout"),
        OptionSpec("help", short: "h", help: "Show help"),
    ]

    static let filterOptions: [OptionSpec] = [
        OptionSpec("folder", value: "F", help: "Only this folder and its subfolders (\"Inbox\" = the Inbox)"),
        OptionSpec("tag", value: "T", help: "Only calls with this tag"),
        OptionSpec("person", value: "P", help: "Only calls with a speaker or attendee whose name contains P"),
        OptionSpec("app", value: "A", help: "Only calls from this app or platform (Zoom, Zen, \"Google Meet\", telegram…)"),
        OptionSpec("since", value: "DATE", help: "Calls that started at or after DATE"),
        OptionSpec("until", value: "DATE", help: "Calls that started at or before DATE (a day counts whole)"),
        OptionSpec("starred", help: "Only starred calls"),
        OptionSpec("status", value: "S", help: "Only calls with this status: ready, processing, queued, recording, failed"),
    ]

    static let dateHelp = "DATE is YYYY-MM-DD (or YYYY-MM, YYYY), an ISO-8601 time (2026-11-14T10:00:00-05:00, or "
        + "2026-11-14T10:00 in local time), today, yesterday, now, or an age: 7d, 12h, 2w."

    static let callHelp = "<call> is a call id, a unique id prefix of at least 4 characters (e.g. 01JD3Q8Z), the exact "
        + "title, or the path of the call's .md/.json file. Several calls with one title: use the id."

    // MARK: Commands

    public static let all: [CommandSpec] = [
        CommandSpec(
            "list", aliases: ["ls"], synopsis: "list [filters] [--limit N] [--offset N]",
            summary: "List calls, newest first",
            details: "Shows each call's id prefix, start (in the call's time zone), length, folder, title and tags.\n\n" + dateHelp,
            options: filterOptions + [
                OptionSpec("limit", short: "n", value: "N", help: "At most N calls (default 50; 0 = all)"),
                OptionSpec("offset", value: "N", help: "Skip the first N calls (paging)"),
            ],
            examples: ["kan list --since 7d", "kan list --folder Research --tag thesis", "kan list --app zen --json"]),
        CommandSpec(
            "search", aliases: ["find"], synopsis: "search <words…> [filters] [--limit N] [--per-call N]",
            summary: "Find passages in titles, tags, notes, bookmarks, summaries and transcripts",
            details: """
                Every word must occur somewhere in the call (in any field); a quoted phrase must occur as \
                typed. Matching ignores case but not Bangla vowel signs: search Bangla as you would write it \
                ("ভাষা" also finds "ভাষার"). Prints each matching call with its passages as \
                [hh:mm:ss] speaker: snippet.

                \(dateHelp)
                """,
            options: filterOptions + [
                OptionSpec("limit", short: "n", value: "N", help: "At most N passages (default 30; 0 = all)"),
                OptionSpec("per-call", value: "N", help: "At most N passages per call (default 5)"),
            ],
            positionals: .words("search words"),
            examples: ["kan search augmentation", "kan search \"data augmentation\" --since 2026-11-01",
                       "kan search ডেটাসেট --person Rahman --json"]),
        CommandSpec(
            "show", aliases: ["cat"], synopsis: "show <call> [--format md|txt|json|srt|vtt]",
            summary: "Print a call's transcript (Markdown by default)",
            details: callHelp + " The Markdown is the call's .md: front matter, the AI summary if there is one, notes, "
                + "bookmarks and transcript. --json is the same as --format json (the full call record).",
            options: [OptionSpec("format", short: "f", value: "FORMAT", help: "md (default), txt, json, srt or vtt")],
            positionals: .words("a call"),
            examples: ["kan show 01JD3Q8Z", "kan show \"Advisor meeting\" --format txt"]),
        CommandSpec(
            "export", synopsis: "export <call> [--format F] [--out PATH] [--force]",
            summary: "Export a call as Markdown, plain text, JSON, SRT or WebVTT",
            details: """
                \(callHelp)

                Without --out the export goes to stdout. --out may name a file or an existing folder (the \
                file is then named "<yyyy-MM-dd HHmm> <title>.<ext>"). Without --format the format comes \
                from the --out extension, else Markdown. Existing files are kept unless --force is given, \
                and kan never writes inside the library folder.
                """,
            options: [
                OptionSpec("format", short: "f", value: "FORMAT", help: "md (default), txt, json, srt or vtt"),
                OptionSpec("out", short: "o", value: "PATH", help: "Write to this file or folder (\"-\" = stdout)"),
                OptionSpec("force", help: "Overwrite an existing file"),
            ],
            positionals: .words("a call"),
            examples: ["kan export 01JD3Q8Z --format srt --out ~/Desktop/", "kan export 01JD3Q8Z --format json > call.json"]),
        CommandSpec("folders", synopsis: "folders", summary: "List folders with call counts",
                    details: "Counts are calls directly in the folder; the total includes subfolders."),
        CommandSpec("tags", synopsis: "tags", summary: "List tags, most used first"),
        CommandSpec("people", synopsis: "people", summary: "List the people in your calls, most frequent first",
                    details: "Named speakers across calls, without you and without placeholder names such as \"Speaker 2\"."),
        CommandSpec("path", synopsis: "path [<call>]", summary: "Print the library folder, or a call's .md file",
                    details: callHelp, positionals: .optional("a call"),
                    examples: ["kan path", "kan path 01JD3Q8Z", "cd \"$(kan path)\""]),
        CommandSpec("open", synopsis: "open <call>", summary: "Open a call's transcript (.md) in the default app",
                    details: callHelp, positionals: .words("a call")),
        CommandSpec("info", synopsis: "info", summary: "Show the library location, counts and settings"),
        CommandSpec(
            "mcp", synopsis: "mcp", summary: "Run the MCP server for AI agents (JSON-RPC over stdio)",
            details: """
                Speaks the Model Context Protocol on stdin/stdout (one JSON message per line); logs go to \
                stderr and ~/Library/Logs/Kan. Read-only: agents can list, search and read calls but never \
                change them. New calls appear without a restart. `kan mcp-config` prints the setup for \
                common agents.
                """),
        CommandSpec(
            "mcp-config", synopsis: "mcp-config",
            summary: "Print MCP setup for Claude Code, Claude Desktop, Codex and Cursor",
            details: "Uses the absolute path of this kan executable. With --library, the configured server reads that library."),
        CommandSpec("transcribe", synopsis: "transcribe <audio…> [options]",
                    summary: "Transcribe audio files (see kan transcribe --help)",
                    details: "All arguments except the word transcribe are passed to the transcriber, which has its own options.",
                    positionals: .words("audio files")),
        CommandSpec("help", synopsis: "help [<command>]", summary: "Show help for kan or a command",
                    positionals: .optional("a command")),
        CommandSpec("version", synopsis: "version", summary: "Print kan's version"),
    ]

    public static func find(_ word: String, in commands: [CommandSpec] = all) -> CommandSpec? {
        commands.first { $0.name == word || $0.aliases.contains(word) }
    }

    /// The closest command name for a typo ("serch" → "search").
    static func suggestion(for word: String, in commands: [CommandSpec]) -> String? {
        let candidates = commands.flatMap { [$0.name] + $0.aliases }
        let scored = candidates.map { ($0, editDistance(word.lowercased(), $0)) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(1, word.count / 3) else { return nil }
        return find(best.0, in: commands)?.name
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// `kan help` and `kan help <command>`.
enum HelpText {
    /// Help paragraphs are wrapped to this many columns.
    static let wrapWidth = 96

    static func overview(version: String) -> String {
        let width = CommandSpec.all.map { shortSynopsis($0).displayWidth }.max() ?? 20
        var out = """
            kan \(version) — read and search your Kan call library (Bangla + English transcripts).

            Usage: kan <command> [options]

            Commands:

            """
        for spec in CommandSpec.all where spec.name != "version" {
            let head = shortSynopsis(spec)
            out += "  " + head.padded(toWidth: max(width, 16) + 2) + spec.summary + "\n"
        }
        out += "\n" + wrap(CommandSpec.callHelp) + "\n\nGlobal options:\n"
        out += optionLines(CommandSpec.globalOptions + [OptionSpec("version", help: "Print the version")])
        out += """

            Exit codes: 0 ok, 1 error, 2 usage error, 3 call not found, 4 several calls match.
            kan only reads the library; it never changes your calls. Run `kan help <command>` for details.

            """
        return out
    }

    static func command(_ spec: CommandSpec) -> String {
        var out = "Usage: kan \(spec.synopsis)\n\n\(spec.summary).\n"
        if !spec.details.isEmpty { out += "\n" + wrap(spec.details) + "\n" }
        if !spec.aliases.isEmpty { out += "\nAlias: " + spec.aliases.map { "kan \($0)" }.joined(separator: ", ") + "\n" }
        if !spec.options.isEmpty {
            out += "\nOptions:\n" + optionLines(spec.options)
        }
        out += "\nGlobal options:\n" + optionLines(CommandSpec.globalOptions)
        if !spec.examples.isEmpty {
            out += "\nExamples:\n" + spec.examples.map { "  \($0)\n" }.joined()
        }
        return out
    }

    /// Word-wraps each paragraph (lines are kept; blank lines separate paragraphs).
    static func wrap(_ text: String, width: Int = wrapWidth) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var lines: [String] = []
            var current = ""
            for word in line.split(separator: " ") {
                if !current.isEmpty && current.displayWidth + 1 + word.count > width {
                    lines.append(current)
                    current = String(word)
                } else {
                    current += (current.isEmpty ? "" : " ") + word
                }
            }
            lines.append(current)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func shortSynopsis(_ spec: CommandSpec) -> String {
        // "search <words…>" without the option list.
        spec.synopsis.split(separator: " ").prefix { !$0.hasPrefix("[") || $0 == "[<call>]" || $0 == "[<command>]" }
            .joined(separator: " ")
    }

    private static func optionLines(_ options: [OptionSpec]) -> String {
        let width = options.map { $0.label.count }.max() ?? 10
        return options.map { "  " + $0.label.padded(toWidth: width + 2) + $0.help + "\n" }.joined()
    }
}
