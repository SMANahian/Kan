import Foundation

/// Copy-paste setup for running `kan mcp` from common agents (`kan mcp-config`; also usable by
/// the app's Settings → Agents pane). Pure and thread-safe.
public enum MCPSetup {
    public struct Snippet: Sendable, Equatable {
        /// "Claude Code"
        public var client: String
        /// What to do with `text`.
        public var instructions: String
        public var text: String
    }

    /// The arguments the agent should launch kan with.
    public static func arguments(libraryPath: String?) -> [String] {
        ["mcp"] + (libraryPath.map { ["--library", $0] } ?? [])
    }

    public static func snippets(executable: String, libraryPath: String?) -> [Snippet] {
        let args = arguments(libraryPath: libraryPath)
        let shellCommand = ([executable] + args).map(shellQuoted).joined(separator: " ")
        let serverJSON = jsonServerEntry(executable: executable, arguments: args)
        let tomlArgs = "[" + args.map(tomlQuoted).joined(separator: ", ") + "]"
        return [
            Snippet(client: "Claude Code",
                    instructions: "Run once (add --scope user to make it available in every project):",
                    text: "claude mcp add kan -- \(shellCommand)"),
            Snippet(client: "Claude Desktop",
                    instructions: "Add to ~/Library/Application Support/Claude/claude_desktop_config.json, then restart Claude:",
                    text: serverJSON),
            Snippet(client: "Codex",
                    instructions: "Run `codex mcp add kan -- \(shellCommand)`, or add to ~/.codex/config.toml:",
                    text: "[mcp_servers.kan]\ncommand = \(tomlQuoted(executable))\nargs = \(tomlArgs)"),
            Snippet(client: "Cursor",
                    instructions: "Add to ~/.cursor/mcp.json (all projects) or .cursor/mcp.json (one project):",
                    text: serverJSON),
        ]
    }

    /// The whole `kan mcp-config` text.
    public static func text(executable: String, libraryPath: String?) -> String {
        var out = "Kan's MCP server is read-only: agents can list, search and read your calls, never change them.\n"
        out += "Server command: " + ([executable] + arguments(libraryPath: libraryPath)).map(shellQuoted).joined(separator: " ") + "\n"
        if let warning = locationWarning(executable) { out += "\n" + warning + "\n" }
        for snippet in snippets(executable: executable, libraryPath: libraryPath) {
            out += "\n\(snippet.client)\n  \(snippet.instructions)\n\n"
            out += snippet.text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        out += "\nOther MCP clients: transport stdio, command \(jsonString(executable)), arguments "
            + "[" + arguments(libraryPath: libraryPath).map(jsonString).joined(separator: ", ") + "].\n"
        return out
    }

    public static func json(executable: String, libraryPath: String?) -> JSONValue {
        var o: [String: JSONValue] = [
            "command": .string(executable),
            "args": .array(arguments(libraryPath: libraryPath).map { .string($0) }),
        ]
        for snippet in snippets(executable: executable, libraryPath: libraryPath) {
            let key = snippet.client.lowercased().replacingOccurrences(of: " ", with: "_")
            o[key] = .string(snippet.text)
        }
        if let warning = locationWarning(executable) { o["warning"] = .string(warning) }
        return .object(o)
    }

    /// A development build or a temporary copy makes a poor long-term server path.
    static func locationWarning(_ executable: String) -> String? {
        let path = executable
        let isDevelopment = path.contains("/.build/") || path.hasPrefix(NSTemporaryDirectory()) || path.hasPrefix("/private/var/folders/")
        guard isDevelopment else { return nil }
        return "Note: this kan is a development build (\(path)). For everyday use, point agents at the installed "
            + "app's copy: /Applications/Kan.app/Contents/MacOS/kan (run `kan mcp-config` from there)."
    }

    // MARK: Quoting

    /// POSIX shell word: bare when safe, else single-quoted.
    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@%+=,")
        if !word.isEmpty && word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func jsonString(_ text: String) -> String {
        (try? JSONValue.string(text).compactString()) ?? "\"\""
    }

    /// TOML basic string.
    static func tomlQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func jsonServerEntry(executable: String, arguments: [String]) -> String {
        let args = arguments.map(jsonString).joined(separator: ", ")
        return """
            {
              "mcpServers": {
                "kan": {
                  "command": \(jsonString(executable)),
                  "args": [\(args)]
                }
              }
            }
            """
    }
}
