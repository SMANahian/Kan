import Darwin
import Foundation
import KanCore

/// `kan transcribe`: transcribe audio files with the same pipeline the app uses.
///
///     kan transcribe <file>                         one file = the remote ("them") track, diarized
///     kan transcribe --me <mic> --them <call>       both sides of a recorded call
///       [--lang auto|bn|en] [--no-diarize] [--speakers N] [--json]
///       [--general ID] [--english ID] [--bangla ID] [--name NAME] [--vocab TERMS]
///       [--loudspeaker] [--no-echo] [--show-echo]
///
/// The transcript goes to stdout ("[hh:mm:ss] Name (lang): text", or JSON with segments, speakers
/// and stats); progress and warnings go to stderr. Ctrl-C cancels cleanly.
public enum TranscribeCommand {
    public static let usage = """
        usage: kan transcribe <file>
               kan transcribe --me <mic-file> --them <call-file>
        options:
          --lang auto|bn|en   language handling (default auto: Bangla/English per chunk)
          --no-diarize        don't separate remote speakers
          --speakers N        at most N remote speakers
          --json              print segments, speakers and stats as JSON
          --general ID        model for language ID (default auto; see `kan models`)
          --english ID        model for English chunks (default auto)
          --bangla ID         model for Bangla chunks (default auto)
          --name NAME         your name for the mic track (default Me)
          --vocab TERMS       names and jargon, comma separated
          --loudspeaker       the call played through speakers (stronger echo handling)
          --no-echo           disable echo handling
          --show-echo         also print mic segments flagged as echo
        A single file is treated as the remote track. Any format macOS can read works (WAV, m4a, …).
        """

    public struct Options: Equatable, Sendable {
        public var me: URL?
        public var them: URL?
        public var languageMode: LanguageMode = .auto
        public var diarize = true
        public var maxSpeakers: Int?
        public var json = false
        public var generalModelID = "auto"
        public var englishModelID = "auto"
        public var banglaModelID = "auto"
        public var userName = "Me"
        public var vocabulary = ""
        public var loudspeaker = false
        public var echoSuppression = true
        public var showEcho = false
        public var help = false

        public init() {}
    }

    public enum UsageError: Error, LocalizedError, Equatable {
        case message(String)
        public var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    /// Parses the words after `kan transcribe` (a leading "transcribe" is ignored).
    public static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var args = arguments[...]
        if args.first == "transcribe" { args = args.dropFirst() }
        var positional: [String] = []
        func value(for flag: String) throws -> String {
            guard let next = args.popFirst(), !next.hasPrefix("--") || next == "-" else {
                throw UsageError.message("\(flag) needs a value")
            }
            return next
        }
        while let argument = args.popFirst() {
            switch argument {
            case "-h", "--help": options.help = true
            case "--me": options.me = fileURL(try value(for: argument))
            case "--them": options.them = fileURL(try value(for: argument))
            case "--lang", "--language":
                switch try value(for: argument).lowercased() {
                case "auto": options.languageMode = .auto
                case "bn", "bangla", "bengali": options.languageMode = .bangla
                case "en", "english": options.languageMode = .english
                case let other: throw UsageError.message("unknown language “\(other)” (use auto, bn or en)")
                }
            case "--no-diarize": options.diarize = false
            case "--speakers":
                let text = try value(for: argument)
                guard let count = Int(text), count > 0 else { throw UsageError.message("--speakers needs a positive number") }
                options.maxSpeakers = count
            case "--json": options.json = true
            case "--general": options.generalModelID = try value(for: argument)
            case "--english": options.englishModelID = try value(for: argument)
            case "--bangla": options.banglaModelID = try value(for: argument)
            case "--name": options.userName = try value(for: argument)
            case "--vocab", "--vocabulary": options.vocabulary = try value(for: argument)
            case "--loudspeaker": options.loudspeaker = true
            case "--no-echo": options.echoSuppression = false
            case "--show-echo": options.showEcho = true
            default:
                if argument.hasPrefix("-") && argument != "-" { throw UsageError.message("unknown option \(argument)") }
                positional.append(argument)
            }
        }
        if options.help { return options }
        if let file = positional.first {
            guard positional.count == 1 else { throw UsageError.message("expected one audio file, got \(positional.count)") }
            guard options.me == nil && options.them == nil else {
                throw UsageError.message("give either one file or --me/--them, not both")
            }
            options.them = fileURL(file)
        }
        guard options.me != nil || options.them != nil else { throw UsageError.message("no audio file given") }
        return options
    }

    public static func run(_ arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            printError("kan transcribe: \(error.localizedDescription)\n\n\(usage)")
            return 2
        }
        if options.help {
            print(usage)
            return 0
        }
        for url in [options.me, options.them].compactMap({ $0 }) where !FileManager.default.fileExists(atPath: url.path) {
            printError("kan transcribe: no such file: \(url.path)")
            return 1
        }

        let request = TranscriptionRequest(
            callID: .generate(), meFile: options.me, themFile: options.them, languageMode: options.languageMode,
            userName: options.userName, vocabulary: options.vocabulary, diarize: options.diarize,
            maxRemoteSpeakers: options.maxSpeakers, echoSuppression: options.echoSuppression,
            loudspeakerSuspected: options.loudspeaker, generalModelID: options.generalModelID,
            englishModelID: options.englishModelID, banglaModelID: options.banglaModelID)

        let pipeline = TranscriptionPipeline()
        let reporter = ProgressPrinter()
        let task = Task { try await pipeline.transcribe(request) { reporter.show($0) } }
        let interrupt = InterruptHandler { task.cancel() }
        defer { interrupt.remove() }

        do {
            let output = try await task.value
            reporter.finish()
            output.warnings.forEach { printError("warning: \($0)") }
            if options.json {
                try printJSON(output)
            } else {
                printTranscript(output, showEcho: options.showEcho)
            }
            return 0
        } catch TranscriptionError.cancelled {
            reporter.finish()
            printError("kan transcribe: cancelled")
            return 130
        } catch {
            reporter.finish()
            printError("kan transcribe: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: Output

    /// "[hh:mm:ss] Name (lang): text" per segment.
    public static func transcriptLines(_ output: TranscriptionOutput, showEcho: Bool = false) -> [String] {
        let names = Dictionary(output.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return output.segments.compactMap { segment in
            let echo = segment.flags.contains(.echoSuspect)
            if echo && !showEcho { return nil }
            let name = names[segment.speakerID] ?? segment.speakerID
            return "[\(KanTime.hms(segment.start))] \(name) (\(segment.language)): \(segment.text)\(echo ? "  [echo?]" : "")"
        }
    }

    private static func printTranscript(_ output: TranscriptionOutput, showEcho: Bool) {
        let lines = transcriptLines(output, showEcho: showEcho)
        if lines.isEmpty {
            printError("No speech found.")
        } else {
            print(lines.joined(separator: "\n"))
        }
        let hidden = output.segments.filter { $0.flags.contains(.echoSuspect) }.count
        if hidden > 0 && !showEcho { printError("\(hidden) mic segment(s) hidden as probable echo (use --show-echo).") }
        if let total = output.stats["seconds.total"], let audio = output.stats["seconds.audio"] {
            printError(String(format: "Transcribed %@ of audio in %.1f s (real-time factor %.2f) with %@.",
                              KanTime.compact(audio), total, total / max(audio, 1e-9),
                              output.modelsUsed.joined(separator: ", ")))
        }
    }

    private struct JSONOutput: Encodable {
        var segments: [TranscriptSegment]
        var speakers: [Speaker]
        var languages: [String]
        var modelsUsed: [String]
        var warnings: [String]
        var stats: [String: Double]
    }

    private static func printJSON(_ output: TranscriptionOutput) throws {
        let data = try JSONEncoder.kanPretty.encode(JSONOutput(
            segments: output.segments, speakers: output.speakers, languages: output.languages,
            modelsUsed: output.modelsUsed, warnings: output.warnings, stats: output.stats))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Turns Ctrl-C into task cancellation while a transcription runs, then restores the previous
/// SIGINT disposition.
private final class InterruptHandler {
    private let source: DispatchSourceSignal
    private let previous: sig_t?

    init(_ handler: @escaping @Sendable () -> Void) {
        previous = signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
    }

    func remove() {
        source.cancel()
        signal(SIGINT, previous ?? SIG_DFL)
    }
}

/// Progress on stderr: one rewritten line on a terminal, one line per stage otherwise.
private final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private let interactive = isatty(STDERR_FILENO) != 0
    private var lastStage: PipelineStage?
    private var lastPercent = -1
    private var drewLine = false

    func show(_ progress: PipelineProgress) {
        lock.withLock {
            let percent = Int((progress.fraction * 100).rounded(.down))
            if interactive {
                guard percent != lastPercent || progress.stage != lastStage else { return }
                let detail = progress.message.map { " (\($0))" } ?? ""
                let line = String(format: "\r[%3d%%] %@%@", percent, progress.stage.displayName, detail)
                FileHandle.standardError.write(Data((line.padding(toLength: max(line.count, 60), withPad: " ", startingAt: 0)).utf8))
                drewLine = true
            } else if progress.stage != lastStage {
                FileHandle.standardError.write(Data(String(format: "[%3d%%] %@\n", percent, progress.stage.displayName).utf8))
            }
            lastStage = progress.stage
            lastPercent = percent
        }
    }

    func finish() {
        lock.withLock {
            if drewLine { FileHandle.standardError.write(Data("\n".utf8)) }
            drewLine = false
        }
    }
}
