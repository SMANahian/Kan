import Foundation
import KanCore

/// `kan`'s exit codes.
public enum ExitCode {
    public static let success: Int32 = 0
    /// The library couldn't be read, a file couldn't be written, …
    public static let failure: Int32 = 1
    /// Unknown command or option, bad value.
    public static let usage: Int32 = 2
    /// No call matches the id/prefix/title.
    public static let notFound: Int32 = 3
    /// Several calls match; candidates are on stderr.
    public static let ambiguous: Int32 = 4
}

/// Everything a CLI run touches, injectable for tests. A run is sequential: the context is used
/// from one thread.
public struct CLIContext {
    public var environment: [String: String]
    public var currentDirectory: URL
    public var stdout: TextSink
    public var stderr: TextSink
    /// "Now" for relative dates ("7d", "today").
    public var now: @Sendable () -> Date
    /// Zone for dates without an offset ("2026-11-14", "today").
    public var timeZone: TimeZone
    /// Absolute path of the running kan (printed by `mcp-config`).
    public var executablePath: String
    public var settingsFile: URL
    /// Opens a file with its default app (`kan open`).
    public var openFile: (URL) throws -> Void
    /// `kan transcribe …` (wired by the executable).
    public var transcribe: ([String]) async -> Int32
    /// `kan mcp` input/output: one message per line.
    public var mcpReadLine: () -> String?
    public var mcpWriteLine: (String) -> Bool
    public var mcpReloadInterval: TimeInterval

    public init(environment: [String: String], currentDirectory: URL, stdout: TextSink, stderr: TextSink,
                now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
                executablePath: String, settingsFile: URL = KanPaths.settingsFile,
                openFile: @escaping (URL) throws -> Void = CLIContext.openWithDefaultApp,
                transcribe: @escaping ([String]) async -> Int32,
                mcpReadLine: @escaping () -> String? = StdioLines.readLine,
                mcpWriteLine: @escaping (String) -> Bool = StdioLines.writeLine,
                mcpReloadInterval: TimeInterval = 3) {
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdout = stdout
        self.stderr = stderr
        self.now = now
        self.timeZone = timeZone
        self.executablePath = executablePath
        self.settingsFile = settingsFile
        self.openFile = openFile
        self.transcribe = transcribe
        self.mcpReadLine = mcpReadLine
        self.mcpWriteLine = mcpWriteLine
        self.mcpReloadInterval = mcpReloadInterval
    }

    /// The real process: its environment, working directory, stdin/stdout/stderr.
    public static func standard(transcribe: @escaping ([String]) async -> Int32) -> CLIContext {
        CLIContext(environment: ProcessInfo.processInfo.environment,
                   currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                   stdout: .standardOutput, stderr: .standardError,
                   executablePath: currentExecutablePath(), transcribe: transcribe)
    }

    /// `/usr/bin/open <file>`.
    public static func openWithDefaultApp(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).singleLineText
            throw CLIFailure("Couldn't open \(url.path)" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    /// The running executable with symlinks resolved (e.g. ~/.local/bin/kan → …/Kan.app/Contents/MacOS/kan).
    public static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return Bundle.main.executablePath ?? CommandLine.arguments.first ?? "kan"
        }
        let raw = String(cString: buffer)
        guard let resolved = realpath(raw, nil) else { return raw }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// A failure with a message for the user (exit code 1).
public struct CLIFailure: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The `kan` command line. All logic lives here; the executable only wires the context.
public enum KanCLI {
    /// Runs one command line (without the program name) and returns the exit code.
    public static func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let invocation: Invocation
        do {
            invocation = try ArgumentParser.parse(arguments)
        } catch let error as ArgumentError {
            return reportUsage(error, context)
        } catch {
            context.stderr.write("kan: \(error.localizedDescription)\n")
            return ExitCode.usage
        }
        switch invocation {
        case .help(let topic):
            guard let topic else {
                context.stdout.write(HelpText.overview(version: KanVersion.current))
                return ExitCode.success
            }
            guard let spec = CommandSpec.find(topic) else {
                return reportUsage(ArgumentError(.unknownCommand(topic, suggestion: CommandSpec.suggestion(for: topic, in: CommandSpec.all))), context)
            }
            context.stdout.write(HelpText.command(spec))
            return ExitCode.success
        case .version:
            context.stdout.write("kan \(KanVersion.current)\n")
            return ExitCode.success
        case .transcribe(let rest):
            return await context.transcribe(rest)
        case .run(let command):
            return CommandRunner(command: command, context: context).run()
        }
    }

    static func reportUsage(_ error: ArgumentError, _ context: CLIContext) -> Int32 {
        context.stderr.write("kan: \(error.localizedDescription)\n")
        context.stderr.write("Run `kan help\(error.command.map { " \($0)" } ?? "")` for usage.\n")
        return ExitCode.usage
    }
}

/// Runs one parsed command.
struct CommandRunner {
    let command: ParsedCommand
    let context: CLIContext

    private var json: Bool { command.flag("json") }

    func run() -> Int32 {
        do {
            switch command.name {
            case "list": return try list()
            case "search": return try search()
            case "show": return try show()
            case "export": return try export()
            case "folders": return try folders()
            case "tags": return try namedCounts(key: "tags", empty: "No tags yet.") { $0.tags() }
            case "people": return try namedCounts(key: "people", empty: "No named people yet.") { $0.people() }
            case "path": return try path()
            case "open": return try open()
            case "info": return info()
            case "mcp": return mcp()
            case "mcp-config": return mcpConfig()
            default: throw ArgumentError(.unknownCommand(command.name, suggestion: nil))
            }
        } catch var error as ArgumentError {
            if error.command == nil { error.command = command.name }
            return KanCLI.reportUsage(error, context)
        } catch let error as CallResolutionError {
            context.stderr.write("kan: \(error.localizedDescription)\n")
            switch error {
            case .empty: return ExitCode.usage
            case .notFound: return ExitCode.notFound
            case .ambiguous: return ExitCode.ambiguous
            }
        } catch {
            context.stderr.write("kan: \(error.localizedDescription)\n")
            return ExitCode.failure
        }
    }

    // MARK: Commands

    private func list() throws -> Int32 {
        let filter = try parseFilter()
        let limit = try count("limit", default: 50)
        let offset = try count("offset", default: 0)
        let library = try openLibrary()
        let page = LibraryQueries.list(library.store, filter: filter, offset: offset, limit: limit)
        if json {
            writeJSON([
                "calls": .array(page.calls.map { AgentJSON.summary($0, root: library.root) }),
                "total": .int(page.total), "offset": .int(page.offset), "limit": .int(limit),
                "next_offset": AgentJSON.optionalInt(page.nextOffset), "library_root": .string(library.root.path),
            ])
        } else {
            let all = library.store.summaries()
            context.stdout.write(CLIText.callTable(page, prefixLength: CallResolver.uniquePrefixLength(for: all.map(\.id)),
                                                   libraryEmpty: all.isEmpty, root: library.root))
            hintUnknownFolder(filter, library: library, found: page.total)
        }
        return ExitCode.success
    }

    private func search() throws -> Int32 {
        let text = CLIQuery.text(command.positionals)
        guard CLIQuery.hasTerms(text) else {
            throw ArgumentError(.missingArgument("search words (use `kan list` to browse)"), command: "search")
        }
        let filter = try parseFilter()
        let limit = try count("limit", default: 30)
        let perCall = try count("per-call", default: 5)
        let library = try openLibrary()
        let results = LibraryQueries.search(library.store, text: text, filter: filter, limit: limit,
                                            perCall: perCall == 0 ? Int(Int32.max) : perCall)
        if json {
            writeJSON([
                "query": .string(text),
                "passages": .array(results.passages.map(AgentJSON.passage)),
                "matched_calls": .int(results.matchedCalls), "total_hits": .int(results.totalHits),
                "truncated": .bool(results.truncated),
            ])
        } else {
            let prefix = CallResolver.uniquePrefixLength(for: library.store.summaries().map(\.id))
            context.stdout.write(CLIText.searchResults(results, query: text, prefixLength: prefix))
            hintUnknownFolder(filter, library: library, found: results.matchedCalls)
        }
        return ExitCode.success
    }

    private func show() throws -> Int32 {
        let format = try exportFormat(out: nil)
        let library = try openLibrary()
        let summary = try resolveCall(library)
        let data = try render(try record(summary, library), format: format)
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text += "\n" }
        context.stdout.write(text)
        return ExitCode.success
    }

    private func export() throws -> Int32 {
        let out = command.value("out")
        let toStdout = out == nil || out == "-"
        let format = try exportFormat(out: toStdout ? nil : out)
        let library = try openLibrary()
        let summary = try resolveCall(library)
        let record = try record(summary, library)
        let data = try render(record, format: format)
        guard let out, !toStdout else {
            context.stdout.write(String(decoding: data, as: UTF8.self))
            return ExitCode.success
        }
        let target = try ExportTarget.resolve(out, record: record, format: format, currentDirectory: context.currentDirectory)
        try ExportTarget.refuseInsideLibrary(target, root: library.root)
        if FileManager.default.fileExists(atPath: target.path) && !command.flag("force") {
            throw CLIFailure("\(target.path) already exists; use --force to replace it.")
        }
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw CLIFailure("Couldn't write \(target.path): \(error.localizedDescription)")
        }
        KanLog.info("Exported \(record.id) as \(format.rawValue)", category: "cli")     // not the path: it names the title
        if json {
            writeJSON(["call_id": .string(record.id.rawValue), "format": .string(format.rawValue),
                       "path": .string(target.path), "bytes": .int(data.count)])
        } else {
            context.stdout.write(target.path + "\n")
        }
        return ExitCode.success
    }

    private func folders() throws -> Int32 {
        let library = try openLibrary()
        let rows = LibraryQueries.folderRows(library.store)
        if json {
            writeJSON(["folders": .array(rows.map(AgentJSON.folder))])
        } else {
            context.stdout.write(CLIText.folders(rows))
        }
        return ExitCode.success
    }

    private func namedCounts(key: String, empty: String, _ items: (LibraryStore) -> [NamedCount]) throws -> Int32 {
        let library = try openLibrary()
        let values = items(library.store)
        if json {
            writeJSON(.object([key: .array(values.map(AgentJSON.namedCount))]))
        } else {
            context.stdout.write(CLIText.namedCounts(values, empty: empty))
        }
        return ExitCode.success
    }

    private func path() throws -> Int32 {
        guard !command.positionals.isEmpty else {
            // Only the location: no need to scan the library.
            let loaded = AgentSettings.load(from: context.settingsFile)
            let location = LibraryLocation.resolve(argument: command.value("library"), environment: context.environment,
                                                   settings: loaded.settings, currentDirectory: context.currentDirectory)
            if json {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: location.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                writeJSON(["path": .string(location.url.path), "exists": .bool(exists), "source": .string(location.source.rawValue)])
            } else {
                context.stdout.write(location.url.path + "\n")
            }
            return ExitCode.success
        }
        let library = try openLibrary()
        let summary = try resolveCall(library)
        guard let files = library.store.files(for: summary.id) else { throw CallResolutionError.notFound(summary.id.rawValue) }
        if json {
            writeJSON(["call_id": .string(summary.id.rawValue), "markdown_path": .string(files.markdown.path),
                       "json_path": .string(files.json.path)])
        } else {
            context.stdout.write(files.markdown.path + "\n")
        }
        return ExitCode.success
    }

    private func open() throws -> Int32 {
        let library = try openLibrary()
        let summary = try resolveCall(library)
        guard let files = library.store.files(for: summary.id) else { throw CallResolutionError.notFound(summary.id.rawValue) }
        let fm = FileManager.default
        guard let target = [files.markdown, files.json].first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw CLIFailure("The files of “\(summary.title)” are gone; was it moved or deleted?")
        }
        try context.openFile(target)
        if json { writeJSON(["opened": .string(target.path), "call_id": .string(summary.id.rawValue)]) }
        return ExitCode.success
    }

    private func info() -> Int32 {
        let library = openLibraryUnchecked()
        let stats = LibraryQueries.stats(library.store)
        let settingsExists = FileManager.default.fileExists(atPath: library.settingsFile.path)
        if json {
            var o: [String: JSONValue] = [
                "kan_version": .string(KanVersion.current),
                "library": .string(library.root.path),
                "library_exists": .bool(library.rootExists),
                "library_source": .string(library.location.source.rawValue),
                "calls": .int(stats.calls),
                "calls_by_status": .object(Dictionary(uniqueKeysWithValues: stats.byStatus.map { ($0.key.rawValue, JSONValue.int($0.value)) })),
                "starred": .int(stats.starred), "unlabeled": .int(stats.unlabeled),
                "folders": .int(stats.folders), "tags": .int(stats.tags), "people": .int(stats.people),
                "total_duration_seconds": .int(AgentFormat.wholeSeconds(stats.totalSeconds)),
                "settings_file": .string(library.settingsFile.path),
                "settings_file_exists": .bool(settingsExists),
                "settings": CLIText.settingsJSON(library.settings),
                "executable": .string(context.executablePath),
            ]
            if let first = stats.first { o["first_call_at"] = .string(AgentFormat.isoDate(first.startedAt, timeZone: first.timeZone)) }
            if let last = stats.last { o["last_call_at"] = .string(AgentFormat.isoDate(last.startedAt, timeZone: last.timeZone)) }
            if let error = library.loadError { o["load_error"] = .string(error) }
            if let problem = library.settingsProblem { o["settings_problem"] = .string(problem) }
            writeJSON(.object(o))
        } else {
            context.stdout.write(CLIText.info(library, stats: stats, settingsExists: settingsExists,
                                              executable: context.executablePath))
        }
        return library.loadError == nil ? ExitCode.success : ExitCode.failure
    }

    private func mcp() -> Int32 {
        let library = openLibraryUnchecked()
        if let error = library.loadError {
            context.stderr.write("kan mcp: the library at \(library.root.path) couldn't be read (\(error)); tools will report it.\n")
        }
        if isatty(STDIN_FILENO) != 0 {
            context.stderr.write("kan mcp: waiting for MCP messages on stdin (one JSON-RPC message per line). "
                                 + "AI agents start this themselves; `kan mcp-config` shows how. Ctrl-D quits.\n")
        }
        // A client that goes away must end the loop with an error from write(2), not kill the process.
        signal(SIGPIPE, SIG_IGN)
        let server = MCPServer(library: library, reloadInterval: context.mcpReloadInterval, now: context.now,
                               timeZone: context.timeZone)
        return server.serve(readLine: context.mcpReadLine, write: context.mcpWriteLine)
    }

    private func mcpConfig() -> Int32 {
        let location = LibraryLocation.resolve(argument: command.value("library"), environment: context.environment,
                                               settings: KanSettings(), currentDirectory: context.currentDirectory)
        // Only an explicit choice is baked into the agent's config; otherwise the server follows Kan's setting.
        let libraryPath = location.source == .argument || location.source == .environment ? location.url.path : nil
        if json {
            writeJSON(MCPSetup.json(executable: context.executablePath, libraryPath: libraryPath))
        } else {
            context.stdout.write(MCPSetup.text(executable: context.executablePath, libraryPath: libraryPath))
        }
        return ExitCode.success
    }

    // MARK: Helpers

    /// Opens the library and fails when it can't be read at all.
    private func openLibrary() throws -> AgentLibrary {
        let library = openLibraryUnchecked()
        if let error = library.loadError {
            throw CLIFailure("Can't read the library at \(library.root.path): \(error)")
        }
        if !library.rootExists {
            context.stderr.write("kan: note: the library folder \(library.root.path) (\(library.location.source.displayName)) "
                                 + "doesn't exist yet; Kan creates it when it saves the first call.\n")
        }
        return library
    }

    private func openLibraryUnchecked() -> AgentLibrary {
        let library = AgentLibrary.open(libraryArgument: command.value("library"), environment: context.environment,
                                        currentDirectory: context.currentDirectory, settingsFile: context.settingsFile)
        if let problem = library.settingsProblem { context.stderr.write("kan: warning: \(problem)\n") }
        return library
    }

    private func resolveCall(_ library: AgentLibrary) throws -> CallSummary {
        try CallResolver.resolve(command.positionals.joined(separator: " "), in: library.store.summaries(), root: library.root)
    }

    private func record(_ summary: CallSummary, _ library: AgentLibrary) throws -> CallRecord {
        do {
            return try library.store.record(summary.id)
        } catch {
            throw CLIFailure(error.localizedDescription)
        }
    }

    private func render(_ record: CallRecord, format: ExportFormat) throws -> Data {
        do {
            return try TranscriptRenderer.render(record, format: format)
        } catch {
            throw CLIFailure("Couldn't render “\(record.title)” as \(format.displayName): \(error.localizedDescription)")
        }
    }

    /// --format (or --json, or the --out extension); Markdown by default.
    private func exportFormat(out: String?) throws -> ExportFormat {
        if let raw = command.value("format") {
            guard let format = ExportTarget.format(named: raw) else {
                throw ArgumentError(.invalidValue(option: "--format", message: "use md, txt, json, srt or vtt (not “\(raw)”)"))
            }
            if json && format != .json && out == nil {
                throw ArgumentError(.invalidValue(option: "--format", message: "--json asks for JSON, --format for \(format.rawValue)"))
            }
            return format
        }
        if let out, let format = ExportTarget.format(named: (out as NSString).pathExtension) { return format }
        return json && out == nil ? .json : .markdown
    }

    private func parseFilter() throws -> CallFilter {
        let dates = DateInput(now: context.now(), timeZone: context.timeZone)
        func date(_ name: String, _ bound: DateBound) throws -> Date? {
            guard let raw = command.value(name) else { return nil }
            do {
                return try dates.parse(raw, as: bound)
            } catch {
                throw ArgumentError(.invalidValue(option: "--\(name)", message: error.localizedDescription))
            }
        }
        var filter = CallFilter()
        filter.folder = command.value("folder")
        filter.tag = command.value("tag")?.nonEmptyPath
        filter.person = command.value("person")?.nonEmptyPath
        filter.app = command.value("app")?.nonEmptyPath
        filter.since = try date("since", .start)
        filter.until = try date("until", .end)
        if let since = filter.since, let until = filter.until, since > until {
            throw ArgumentError(.invalidValue(option: "--since", message: "is after --until"))
        }
        filter.starredOnly = command.flag("starred")
        if let raw = command.value("status") {
            guard let status = CallStatus(rawValue: raw.lowercased()) else {
                throw ArgumentError(.invalidValue(option: "--status", message: "use ready, processing, queued, recording or failed"))
            }
            filter.status = status
        }
        return filter
    }

    /// A whole number ≥ 0.
    private func count(_ name: String, default fallback: Int) throws -> Int {
        guard let raw = command.value(name) else { return fallback }
        guard let n = Int(raw.trimmingCharacters(in: .whitespaces)), n >= 0 else {
            throw ArgumentError(.invalidValue(option: "--\(name)", message: "expected a whole number ≥ 0, not “\(raw)”"))
        }
        return n
    }

    private func hintUnknownFolder(_ filter: CallFilter, library: AgentLibrary, found: Int) {
        guard found == 0, let folder = filter.folder, let sanitized = LibraryStore.sanitizeFolder(folder), !sanitized.isEmpty else { return }
        let known = library.store.folders().contains { $0.name.lowercased() == sanitized.lowercased() }
        if !known { context.stderr.write("kan: there is no folder “\(folder)”; `kan folders` lists them.\n") }
    }

    private func writeJSON(_ value: JSONValue) {
        do {
            context.stdout.write(try value.prettyString() + "\n")
        } catch {
            context.stderr.write("kan: couldn't encode JSON: \(error.localizedDescription)\n")
        }
    }
}

/// Where `kan export --out` writes.
enum ExportTarget {
    static func format(named raw: String) -> ExportFormat? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "md", "markdown": return .markdown
        case "txt", "text", "plain": return .text
        case "json": return .json
        case "srt": return .srt
        case "vtt", "webvtt": return .vtt
        default: return nil
        }
    }

    /// A file path, or a folder (existing, or written with a trailing "/") that gets the suggested name.
    static func resolve(_ out: String, record: CallRecord, format: ExportFormat, currentDirectory: URL) throws -> URL {
        let expanded = (out as NSString).expandingTildeInPath
        let base = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : currentDirectory.appendingPathComponent(expanded)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory)
        if (exists && isDirectory.boolValue) || out.hasSuffix("/") {
            guard exists else { throw CLIFailure("The folder \(base.path) doesn't exist.") }
            return base.appendingPathComponent(TranscriptRenderer.suggestedFileName(for: record, format: format)).standardizedFileURL
        }
        let parent = base.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw CLIFailure("The folder \(parent.path) doesn't exist.")
        }
        return base.standardizedFileURL
    }

    /// kan never writes into the library: an exported .json there would be a second copy of the call.
    /// Compares file identities, so symlinks and case differences can't sneak past.
    static func refuseInsideLibrary(_ target: URL, root: URL) throws {
        guard let rootID = identity(root.path) else { return }
        var directory = target.deletingLastPathComponent().standardizedFileURL
        while true {
            if let id = identity(directory.path), id == rootID {
                throw CLIFailure("kan doesn't write inside the library (\(root.path)); export somewhere else.")
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return }
            directory = parent
        }
    }

    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
    }

    private static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
    }
}
