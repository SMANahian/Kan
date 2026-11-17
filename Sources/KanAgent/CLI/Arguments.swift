import Foundation

/// One `--option` a command understands.
public struct OptionSpec: Sendable, Equatable {
    public let name: String
    public let short: Character?
    /// Name of the value ("PATH"), nil for a flag.
    public let valueName: String?
    public let help: String

    public init(_ name: String, short: Character? = nil, value: String? = nil, help: String) {
        self.name = name
        self.short = short
        self.valueName = value
        self.help = help
    }

    public var takesValue: Bool { valueName != nil }

    /// "-n, --limit N"
    var label: String {
        let long = "--\(name)" + (valueName.map { " \($0)" } ?? "")
        return short.map { "-\($0), \(long)" } ?? long
    }
}

/// How many positional arguments a command takes.
public enum PositionalRule: Sendable, Equatable {
    case none
    case optional(String)
    /// One or more words, joined by the command ("Weekly sync" may arrive as two words).
    case words(String)
}

/// A parsed command line: the command, its words and its options (global ones included).
public struct ParsedCommand: Sendable, Equatable {
    public var name: String
    public var positionals: [String] = []
    public var values: [String: String] = [:]
    public var flags: Set<String> = []

    public func value(_ name: String) -> String? { values[name] }
    public func flag(_ name: String) -> Bool { flags.contains(name) }
}

/// A mistake on the command line (exit code 2).
public struct ArgumentError: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unknownCommand(String, suggestion: String?)
        case unknownOption(String)
        case missingValue(String)
        case unexpectedValue(String)
        case repeated(String)
        case unexpectedArgument(String)
        case missingArgument(String)
        case invalidValue(option: String, message: String)
    }

    public var kind: Kind
    /// The command whose help explains the mistake (nil: the overview).
    public var command: String?

    public init(_ kind: Kind, command: String? = nil) {
        self.kind = kind
        self.command = command
    }

    public var errorDescription: String? {
        switch kind {
        case .unknownCommand(let name, let suggestion):
            return "Unknown command “\(name)”." + (suggestion.map { " Did you mean “\($0)”?" } ?? "")
        case .unknownOption(let option):
            return "Unknown option \(option)" + (command.map { " for “\($0)”" } ?? "") + "."
        case .missingValue(let option):
            return "\(option) needs a value."
        case .unexpectedValue(let option):
            return "\(option) doesn't take a value."
        case .repeated(let option):
            return "\(option) was given more than once."
        case .unexpectedArgument(let argument):
            return "Unexpected argument “\(argument)”" + (command.map { " for “\($0)”" } ?? "") + "."
        case .missingArgument(let name):
            return (command.map { "“\($0)” needs " } ?? "Missing ") + name + "."
        case .invalidValue(let option, let message):
            return "\(option): \(message)"
        }
    }
}

/// What the command line asks for.
public enum Invocation: Equatable, Sendable {
    case help(topic: String?)
    case version
    /// `kan transcribe …`: every argument except the word itself, untouched and in order.
    case transcribe([String])
    case run(ParsedCommand)
}

/// A small, strict parser: `kan [global options] <command> [options] [arguments]`.
///
/// Options may come before or after arguments, as `--name value` or `--name=value`; `--` ends the
/// options. Values may not start with "--" (so a forgotten value isn't silently taken from the
/// next option). Unknown options and repeated value options are errors.
public enum ArgumentParser {
    public static func parse(_ arguments: [String], commands: [CommandSpec] = CommandSpec.all) throws -> Invocation {
        var index = 0
        var global = ParsedCommand(name: "")
        // Global options before the command word.
        while index < arguments.count, arguments[index].hasPrefix("-"), arguments[index] != "-" {
            let argument = arguments[index]
            if argument == "--" { index += 1; break }
            if argument == "--version" || argument == "-V" { return .version }
            index = try consumeOption(arguments, at: index, options: CommandSpec.globalOptions, into: &global, command: nil)
        }
        guard index < arguments.count else {
            return .help(topic: nil)
        }
        let word = arguments[index]
        let commandIndex = index
        index += 1
        guard let spec = CommandSpec.find(word, in: commands) else {
            throw ArgumentError(.unknownCommand(word, suggestion: CommandSpec.suggestion(for: word, in: commands)))
        }
        switch spec.name {
        case "transcribe":
            // The transcriber parses its own options, including any given before the word.
            return .transcribe(Array(arguments[..<commandIndex]) + Array(arguments[index...]))
        case "version":
            return .version
        default:
            break
        }
        if global.flag("help") { return .help(topic: spec.name == "help" ? nil : spec.name) }

        var parsed = global
        parsed.name = spec.name
        let options = spec.options + CommandSpec.globalOptions
        var onlyPositionals = false
        while index < arguments.count {
            let argument = arguments[index]
            if !onlyPositionals && argument == "--" {
                onlyPositionals = true
                index += 1
                continue
            }
            if !onlyPositionals && argument.hasPrefix("-") && argument != "-" && !isNegativeNumber(argument) {
                index = try consumeOption(arguments, at: index, options: options, into: &parsed, command: spec.name)
                continue
            }
            parsed.positionals.append(argument)
            index += 1
        }
        if parsed.flag("help") {
            return .help(topic: spec.name == "help" ? parsed.positionals.first : spec.name)
        }
        if spec.name == "help" {
            guard parsed.positionals.count <= 1 else {
                throw ArgumentError(.unexpectedArgument(parsed.positionals[1]), command: "help")
            }
            return .help(topic: parsed.positionals.first)
        }
        try check(parsed, against: spec)
        return .run(parsed)
    }

    private static func check(_ parsed: ParsedCommand, against spec: CommandSpec) throws {
        switch spec.positionals {
        case .none:
            if let extra = parsed.positionals.first {
                throw ArgumentError(.unexpectedArgument(extra), command: spec.name)
            }
        case .optional:
            if parsed.positionals.count > 1 {
                throw ArgumentError(.unexpectedArgument(parsed.positionals[1]), command: spec.name)
            }
        case .words(let name):
            if parsed.positionals.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw ArgumentError(.missingArgument(name), command: spec.name)
            }
        }
    }

    /// Parses the option at `index`; returns the index after it (and its value).
    private static func consumeOption(_ arguments: [String], at index: Int, options: [OptionSpec],
                                      into parsed: inout ParsedCommand, command: String?) throws -> Int {
        let argument = arguments[index]
        var name: String
        var inlineValue: String?
        let spec: OptionSpec
        if argument.hasPrefix("--") {
            name = String(argument.dropFirst(2))
            if let eq = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            guard let found = options.first(where: { $0.name == name }) else {
                throw ArgumentError(.unknownOption("--" + name), command: command)
            }
            spec = found
        } else {
            let letters = argument.dropFirst()
            guard letters.count == 1, let letter = letters.first,
                  let found = options.first(where: { $0.short == letter }) else {
                throw ArgumentError(.unknownOption(argument), command: command)
            }
            spec = found
        }
        let display = "--" + spec.name
        guard spec.takesValue else {
            if inlineValue != nil { throw ArgumentError(.unexpectedValue(display), command: command) }
            parsed.flags.insert(spec.name)
            return index + 1
        }
        if parsed.values[spec.name] != nil { throw ArgumentError(.repeated(display), command: command) }
        if let inlineValue {
            parsed.values[spec.name] = inlineValue
            return index + 1
        }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw ArgumentError(.missingValue(display), command: command)
        }
        parsed.values[spec.name] = arguments[index + 1]
        return index + 2
    }

    private static func isNegativeNumber(_ argument: String) -> Bool {
        argument.count > 1 && argument.dropFirst().allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
    }
}
