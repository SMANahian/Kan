import Foundation

/// The small part of YAML the front matter needs: scalars and flow lists, always valid YAML 1.1
/// and 1.2 (Obsidian, PyYAML, js-yaml and Jekyll read the same values).
enum YAML {
    /// A double-quoted scalar with every character YAML can't hold literally escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x0D: out += "\\r"
            case 0x85: out += "\\N"
            case 0x2028: out += "\\L"
            case 0x2029: out += "\\P"
            case 0x00...0x1F, 0x7F...0x9F: out += String(format: "\\x%02X", v)
            case 0xFEFF, 0xFFFE, 0xFFFF: out += String(format: "\\u%04X", v)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A plain scalar when that can't be misread, otherwise a double-quoted one.
    static func scalar(_ text: String, inFlow: Bool = false) -> String {
        needsQuotes(text, inFlow: inFlow) ? quoted(text) : text
    }

    /// Conservative: anything that isn't plain printable ASCII text without YAML meaning is quoted
    /// (Bangla, emoji, ":", "#", quotes, indicators, numbers, dates, booleans, null…).
    static func needsQuotes(_ text: String, inFlow: Bool) -> Bool {
        guard let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else { return true }
        if first == " " || last == " " { return true }
        for scalar in text.unicodeScalars where scalar.value < 0x20 || scalar.value > 0x7E { return true }
        if "-?:,[]{}#&*!|>'\"%@`<=.+~\\".unicodeScalars.contains(first) { return true }
        if first.properties.numericType != nil { return true }           // numbers, dates, times
        for scalar in text.unicodeScalars {
            switch scalar {
            case ":", "#", "\"", "'", "\\": return true
            case ",", "[", "]", "{", "}": if inFlow { return true }
            default: break
            }
        }
        let reserved: Set<String> = ["null", "true", "false", "yes", "no", "on", "off", "y", "n"]
        return reserved.contains(text.lowercased())
    }

    /// `[a, "b c", …]`; items are quoted when needed, or always when `alwaysQuote`.
    static func flowList(_ items: [String], alwaysQuote: Bool = false) -> String {
        "[" + items.map { alwaysQuote ? quoted($0) : scalar($0, inFlow: true) }.joined(separator: ", ") + "]"
    }
}
