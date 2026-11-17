import Foundation
import KanCore

public enum CallResolutionError: Error, LocalizedError, Equatable, Sendable {
    case empty
    case notFound(String)
    /// Several calls match; candidates newest first.
    case ambiguous(String, [CallSummary])

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "No call given. Pass a call id, a unique id prefix (at least \(CallResolver.minimumPrefixLength) characters) or the exact title."
        case .notFound(let input):
            return "No call matches “\(input)”. Use a call id, a unique id prefix (at least \(CallResolver.minimumPrefixLength) characters) or the exact title; `kan list` and `kan search` show ids."
        case .ambiguous(let input, let candidates):
            return "“\(input)” matches \(candidates.count) calls; use one of their ids:\n"
                + candidates.map { "  " + CallResolver.describe($0) }.joined(separator: "\n")
        }
    }
}

/// Finds the call a user or agent means: a full id (any case), a unique id prefix of at least four
/// characters, the exact title (case-insensitive), or the path of the call's .md/.json file
/// (absolute, or relative to the library root). Pure and thread-safe.
public enum CallResolver {
    public static let minimumPrefixLength = 4

    /// Crockford base32, the ULID alphabet.
    private static let idAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func resolve(_ input: String, in summaries: [CallSummary], root: URL) throws -> CallSummary {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CallResolutionError.empty }
        let upper = trimmed.uppercased()

        if let exact = summaries.first(where: { $0.id.rawValue.uppercased() == upper }) { return exact }

        let byPath = pathMatches(trimmed, in: summaries, root: root)
        if byPath.count == 1 { return byPath[0] }

        var byPrefix: [CallSummary] = []
        if trimmed.count >= minimumPrefixLength, upper.allSatisfy(idAlphabet.contains) {
            byPrefix = summaries.filter { $0.id.rawValue.uppercased().hasPrefix(upper) }
        }
        if byPrefix.count == 1 { return byPrefix[0] }
        if byPrefix.count > 1 { throw CallResolutionError.ambiguous(trimmed, newestFirst(byPrefix)) }

        let title = trimmed.nfc.singleLineText
        let byTitle = summaries.filter { $0.title.nfc.singleLineText.caseInsensitiveCompare(title) == .orderedSame }
        if byTitle.count == 1 { return byTitle[0] }
        if byTitle.count > 1 { throw CallResolutionError.ambiguous(trimmed, newestFirst(byTitle)) }

        throw CallResolutionError.notFound(trimmed)
    }

    /// "01JD3Q8Z6M7K2V9R4T5N8P1XQA  2026-11-14 10:00  Advisor meeting  (Research/Thesis)"
    public static func describe(_ summary: CallSummary) -> String {
        let folder = summary.folder.isEmpty ? "Inbox" : summary.folder
        return "\(summary.id.rawValue)  \(AgentFormat.shortDate(summary.startedAt, timeZone: summary.timeZone))  \(summary.title)  (\(folder))"
    }

    /// The shortest prefix length (at least `minimum`) that tells every id in `ids` apart, like
    /// git's abbreviated hashes.
    public static func uniquePrefixLength(for ids: [CallID], minimum: Int = 8) -> Int {
        let raw = Set(ids.map(\.rawValue))
        let longest = raw.map(\.count).max() ?? minimum
        var length = min(minimum, longest)
        while length < longest {
            let prefixes = Set(raw.map { $0.prefix(length) })
            if prefixes.count == raw.count { return length }
            length += 1
        }
        return length
    }

    private static func pathMatches(_ input: String, in summaries: [CallSummary], root: URL) -> [CallSummary] {
        let lower = input.lowercased()
        guard lower.hasSuffix(".md") || lower.hasSuffix(".json") else { return [] }
        let expanded = (input as NSString).expandingTildeInPath
        let relative: String
        if expanded.hasPrefix("/") {
            // Compare real paths so /var/… and /private/var/… (or a symlinked library) agree.
            let rootPath = canonicalPath(root.standardizedFileURL.path)
            let path = canonicalPath(URL(fileURLWithPath: expanded).standardizedFileURL.path)
            guard path.hasPrefix(rootPath + "/") else { return [] }
            relative = String(path.dropFirst(rootPath.count + 1))
        } else {
            relative = expanded.hasPrefix("./") ? String(expanded.dropFirst(2)) : expanded
        }
        let key = relative.nfc.lowercased()
        return summaries.filter { $0.markdownPath.nfc.lowercased() == key || $0.jsonPath.nfc.lowercased() == key }
    }

    /// realpath(3) when the path exists, else the path as given.
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func newestFirst(_ summaries: [CallSummary]) -> [CallSummary] {
        summaries.sorted { a, b in a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.id > b.id }
    }
}
