import Foundation

/// File and folder naming rules of the library (see the header of Contracts/Library.swift).
enum LibraryNaming {
    static let inboxDirectory = "Inbox"
    static let untitled = "Untitled call"
    static let jsonExtension = "json"
    static let markdownExtension = "md"
    static let agentsFileName = "AGENTS.md"
    static let indexMarkdownName = "index.md"
    static let indexJSONLName = "index.jsonl"

    /// Title part of a file name: at most 90 characters and 180 UTF-8 bytes (Bangla is 3 bytes per
    /// scalar and APFS allows 255 bytes per name, which must also fit the date, " (n)" and ".json").
    static let maxTitleCharacters = 90
    static let maxTitleBytes = 180
    static let maxFolderComponentCharacters = 80
    static let maxFolderComponentBytes = 180
    static let maxFolderDepth = 12

    // MARK: Titles

    /// The title made safe for a file name: no "/", ":", "\" or control characters, no characters
    /// other systems reject (* ? " < > |), single spaces, trimmed, truncated; "Untitled call" if empty.
    static func fileTitle(_ title: String) -> String {
        let scalars = Array(title.nfc.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            switch scalar {
            case ":":
                // "Advisor meeting: idea" → "Advisor meeting - idea"; "10:30" → "10-30".
                let next = i + 1 < scalars.count ? scalars[i + 1] : " "
                out.append(contentsOf: next.isSpaceOrControl ? " -".unicodeScalars : "-".unicodeScalars)
            case "/", "\\", "|":
                out.append("-")
            case "\"":
                out.append("'")
            case "*", "?", "<", ">":
                continue
            default:
                out.append(scalar.isSpaceOrControl ? " " : scalar)
            }
        }
        var name = String(out).singleLine
        name = trimmingTrailingDotsAndSpaces(name)
        name = name.truncated(maxCharacters: maxTitleCharacters, maxUTF8Bytes: maxTitleBytes, ellipsis: "")
        name = trimmingTrailingDotsAndSpaces(name)
        return name.isEmpty ? untitled : name
    }

    private static func trimmingTrailingDotsAndSpaces(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last == "." || last == " " || last == "-" { t = t.dropLast() }
        return String(t)
    }

    /// "yyyy-MM-dd HHmm" in the call's own time zone (falls back to the current zone).
    static func datePrefix(_ date: Date, timeZone identifier: String) -> String {
        let c = components(of: date, timeZone: identifier)
        return String(format: "%04d-%02d-%02d %02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// "yyyy-MM-dd HH:mm" in the call's own time zone (index.md).
    static func displayDate(_ date: Date, timeZone identifier: String) -> String {
        let c = components(of: date, timeZone: identifier)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    static func timeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .current
    }

    private static func components(of date: Date, timeZone identifier: String) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(identifier)
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// "<yyyy-MM-dd HHmm> <file title>", without extension or collision suffix.
    static func baseName(for record: CallRecord) -> String {
        "\(datePrefix(record.startedAt, timeZone: record.timeZone)) \(fileTitle(record.title))"
    }

    /// The collision number of `name` relative to `base`: 1 for "base", n for "base (n)", nil otherwise.
    static func collisionNumber(of name: String, base: String) -> Int? {
        let name = name.nfc, base = base.nfc
        if name == base { return 1 }
        guard name.hasPrefix(base + " ("), name.hasSuffix(")") else { return nil }
        let digits = name.dropFirst(base.count + 2).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 2 else { return nil }
        return n
    }

    // MARK: Folders

    /// See `LibraryStore.sanitizeFolder`.
    static func sanitizeFolder(_ name: String) -> String? {
        var components: [String] = []
        for raw in name.nfc.split(separator: "/", omittingEmptySubsequences: false) {
            if String(raw).singleLine.isEmpty { continue }           // "a//b", leading or trailing "/"
            var out = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                switch scalar {
                case ":", "\\", "|": out.append("-")
                case "\"": out.append("'")
                case "*", "?", "<", ">": continue
                default: out.append(scalar.isSpaceOrControl ? " " : scalar)
                }
            }
            var component = String(out).singleLine
            guard !component.isEmpty else { return nil }             // nothing usable left ("???")
            if component.allSatisfy({ $0 == "." }) { return nil }    // ".", "..", "..."
            while component.hasPrefix(".") { component.removeFirst() }
            component = component.trimmingCharacters(in: .whitespaces)
            component = component.truncated(maxCharacters: maxFolderComponentCharacters,
                                            maxUTF8Bytes: maxFolderComponentBytes, ellipsis: "")
            component = component.trimmingCharacters(in: .whitespaces)
            guard !component.isEmpty else { return nil }
            components.append(component)
        }
        guard !components.isEmpty else { return "" }
        guard components.count <= maxFolderDepth else { return nil }
        if components[0].caseInsensitiveCompare(inboxDirectory) == .orderedSame {
            if components.count == 1 { return "" }
            components[0] = inboxDirectory
        }
        let reserved: Set<String> = [agentsFileName.lowercased(), indexMarkdownName, indexJSONLName]
        if reserved.contains(components[0].lowercased()) { return nil }
        return components.joined(separator: "/")
    }

    /// Directory components (relative to the root) of a sanitized folder: "" → ["Inbox"].
    static func directoryComponents(forFolder folder: String) -> [String] {
        folder.isEmpty ? [inboxDirectory] : folder.split(separator: "/").map(String.init)
    }

    /// The folder a directory represents: the root and "Inbox" are the Inbox ("").
    static func folder(forDirectoryComponents components: [String]) -> String {
        let normalized = components.map(\.nfc)
        if normalized.isEmpty { return "" }
        if normalized.count == 1 && normalized[0].caseInsensitiveCompare(inboxDirectory) == .orderedSame { return "" }
        return normalized.joined(separator: "/")
    }

    /// True if `folder` is `ancestor` or nested inside it ("" only contains itself).
    static func folder(_ folder: String, isInside ancestor: String) -> Bool {
        if ancestor.isEmpty { return folder.isEmpty }
        return folder == ancestor || folder.hasPrefix(ancestor + "/")
    }

    static func isReservedRootFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == agentsFileName.lowercased() || lower.hasPrefix("index.")
    }
}
