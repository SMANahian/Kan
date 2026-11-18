import Foundation
import KanCore

/// The readable (Markdown) text of tool results. Carries the same facts as `structuredContent`
/// (ids, absolute times with offsets and time zones), since many clients only show the text.
enum MCPText {
    static func callList(_ page: CallPage, libraryEmpty: Bool) -> String {
        guard !page.calls.isEmpty else {
            if libraryEmpty { return "The library has no calls yet." }
            return page.total > 0 ? "No calls at offset \(page.offset) (there are \(page.total))." : "No calls match these filters."
        }
        var out = "Calls \(page.offset + 1)–\(page.offset + page.calls.count) of \(page.total), newest first.\n"
        for (index, s) in page.calls.enumerated() {
            out += "\n\(page.offset + index + 1). **\(s.title)**" + (s.starred ? " ★" : "") + "\n"
            out += "   id: \(s.id.rawValue)\n"
            out += "   started: \(AgentFormat.isoDate(s.startedAt, timeZone: s.timeZone)) (\(s.timeZone)) · "
                + "\(KanTime.humanDuration(s.duration)) · \(s.appName) · status: \(s.status.rawValue)\n"
            var facts = ["folder: " + (s.folder.isEmpty ? "Inbox" : s.folder)]
            if !s.tags.isEmpty { facts.append("tags: " + s.tags.joined(separator: ", ")) }
            let people = LibraryQueries.people(s)
            if !people.isEmpty { facts.append("people: " + people.joined(separator: ", ")) }
            if !s.languages.isEmpty { facts.append("languages: " + s.languages.joined(separator: ", ")) }
            if s.hasSummary { facts.append("has an AI summary") }
            out += "   " + facts.joined(separator: " · ") + "\n"
            if !s.preview.isEmpty { out += "   preview: \(s.preview)\n" }
        }
        if let next = page.nextOffset { out += "\nMore calls: list_calls with offset \(next).\n" }
        return out
    }

    static func passages(_ results: PassageResults, query: String) -> String {
        guard !results.passages.isEmpty else {
            return "No passages match “\(query)”. Try fewer or different words, the other script (English terms are often written in Bengali script), or list_calls to browse."
        }
        var out = AgentFormat.count(results.passages.count, "passage") + " for “\(query)” from "
            + AgentFormat.count(results.matchedCalls, "call")
            + (results.truncated ? " (\(results.totalHits) hits in all; raise limit or max_per_call for more)" : "") + ".\n"
        var current: CallID?
        for passage in results.passages {
            let s = passage.summary, hit = passage.hit
            if current != s.id {
                current = s.id
                out += "\n## \(s.title)\n"
                out += "id: \(s.id.rawValue) · started \(AgentFormat.isoDate(s.startedAt, timeZone: s.timeZone)) (\(s.timeZone)) · \(s.appName)\n"
            }
            switch hit.field {
            case .transcript:
                out += "- [\(KanTime.hms(hit.time ?? 0))] \(hit.speakerName ?? "Unknown speaker"): \(hit.snippet)\n"
            case .bookmark:
                out += "- bookmark [\(KanTime.hms(hit.time ?? 0))]: \(hit.snippet)\n"
            case .title, .tags, .notes, .summary:
                out += "- \(hit.field.rawValue): \(hit.snippet)\n"
            }
        }
        return out
    }

    static func call(_ record: CallRecord, files: CallFiles?) -> String {
        let zone = record.timeZone
        var out = "# \(record.title)\n\(TranscriptRenderer.summaryLine(record))\n\n"
        out += "- id: \(record.id.rawValue)\n"
        out += "- started: \(AgentFormat.isoDate(record.startedAt, timeZone: zone)) · ended: "
            + "\(AgentFormat.isoDate(record.endedAt, timeZone: zone)) (\(zone)) · \(KanTime.humanDuration(record.duration))\n"
        var labels = ["folder: " + (record.folder.isEmpty ? "Inbox" : record.folder)]
        if !record.tags.isEmpty { labels.append("tags: " + record.tags.joined(separator: ", ")) }
        if record.starred { labels.append("starred") }
        if !record.labeled { labels.append("not labeled by the user yet") }
        out += "- " + labels.joined(separator: " · ") + "\n"
        var state = ["status: \(record.status.rawValue)", AgentFormat.count(LibraryQueries.visibleSegments(record).count, "segment")]
        if !record.languages.isEmpty { state.append("languages: " + record.languages.joined(separator: ", ")) }
        out += "- " + state.joined(separator: " · ") + "\n"
        out += "- app: \(record.source.appName) (\(record.source.platform.displayName))\n"
        if let title = record.source.meetingTitle { out += "- meeting: \(title)\n" }
        if let url = record.source.meetingURL { out += "- meeting link: \(url)\n" }
        if let event = record.calendarEventTitle { out += "- calendar event: \(event)\n" }
        if !record.attendees.isEmpty { out += "- attendees: \(record.attendees.joined(separator: ", "))\n" }
        if let note = LibraryQueries.statusNote(record) { out += "- note: \(note)\n" }
        if let files { out += "- transcript file: \(files.markdown.path)\n" }
        if let ideas = record.ai?.titleSuggestions, !ideas.titles.isEmpty {
            out += "- title ideas (by OpenAI" + (record.areTitleIdeasOutdated ? ", from an earlier transcript" : "") + "): "
                + ideas.titles.map { "“\($0.singleLineText)”" }.joined(separator: " · ") + "\n"
        }
        // The same section as in the .md, so the summary reads the same everywhere.
        if let summary = TranscriptRenderer.summaryMarkdown(record) { out += "\n" + summary }

        if !record.speakers.isEmpty {
            var counts: [String: Int] = [:]
            for segment in LibraryQueries.visibleSegments(record) { counts[segment.speakerID, default: 0] += 1 }
            out += "\n## Speakers\n"
            for speaker in record.speakers {
                var facts = ["id \(speaker.id)"]
                if speaker.isMe { facts.append("the user") }
                switch speaker.nameSource {
                case .user: facts.append("named by the user")
                case .voiceprint: facts.append("recognized by voice")
                case .automatic: if !speaker.isMe && speaker.hasDefaultName { facts.append("not named yet") }
                }
                if let suggestion = speaker.suggestedName { facts.append("sounds like \(suggestion)?") }
                facts.append("\(KanTime.humanDuration(speaker.talkTime)) of speech")
                facts.append(AgentFormat.count(counts[speaker.id] ?? 0, "segment"))
                out += "- **\(speaker.name)** — " + facts.joined(separator: " · ") + "\n"
            }
        }
        if !record.bookmarks.isEmpty {
            out += "\n## Bookmarks\n"
            for bookmark in record.bookmarks.sorted(by: { $0.time < $1.time }) {
                var when = "[\(KanTime.hms(bookmark.time))"
                if let end = bookmark.endTime, end > bookmark.time { when += "–\(KanTime.hms(end))" }
                when += "]"
                let at = AgentFormat.isoDate(record.startedAt.addingTimeInterval(bookmark.time), timeZone: zone)
                let note = bookmark.note.singleLineText
                out += "- \(when) \(note.isEmpty ? "(no note)" : note) (at \(at))\n"
            }
        }
        let notes = record.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { out += "\n## Notes\n\(notes)\n" }
        return out
    }

    static func transcriptBody(_ page: TranscriptPage, markdown: Bool) -> String {
        let record = page.record
        return LibraryQueries.turns(page.segments).map { turn in
            let name = record.speakerName(turn.speakerID).singleLineText
            return markdown
                ? "**\(name)** [\(KanTime.hms(turn.start))]\n\(turn.text)\n"
                : "[\(KanTime.hms(turn.start))] \(name): \(turn.text)"
        }.joined(separator: "\n")
    }

    static func transcriptPage(_ page: TranscriptPage, body: String, markdown: Bool) -> String {
        let record = page.record
        var header = markdown ? "# \(record.title) — transcript\n" : "\(record.title) — transcript\n"
        header += "id: \(record.id.rawValue) · started \(AgentFormat.isoDate(record.startedAt, timeZone: record.timeZone)) (\(record.timeZone))\n"
        if let first = page.segments.first, let last = page.segments.last {
            header += "segments \(page.offset + 1)–\(page.offset + page.segments.count) of \(page.total)"
            if page.total != page.callSegments { header += " in range (\(page.callSegments) in the call)" }
            header += " · \(KanTime.hms(first.start))–\(KanTime.hms(max(last.end, last.start)))\n"
        }
        if let note = LibraryQueries.statusNote(record) { header += markdown ? "_\(note)_\n" : "(\(note))\n" }
        var out = header + "\n"
        // Reading a whole call in Markdown starts with its summary, like the .md.
        if markdown, page.offset == 0, page.fromSeconds == nil, page.toSeconds == nil,
           let summary = TranscriptRenderer.summaryMarkdown(record) {
            out += summary + "\n## Transcript\n"
        }
        if page.segments.isEmpty {
            if page.total > 0 {
                out += "No segments at offset \(page.offset) (there are \(page.total)).\n"
            } else if page.callSegments > 0 {
                out += "No speech in this time range.\n"
            } else {
                out += "There is no transcript text.\n"
            }
        } else {
            out += body + (body.hasSuffix("\n") ? "" : "\n")
        }
        if let next = page.nextOffset {
            out += "\nMore: get_transcript with call_id \(record.id.rawValue) and offset \(next)"
                + (page.fromSeconds != nil || page.toSeconds != nil ? " (same from_seconds/to_seconds)" : "") + ".\n"
        }
        return out
    }

    static func folders(_ rows: [FolderRow]) -> String {
        var out = "Folders (calls directly inside · including subfolders):\n"
        for row in rows {
            let indent = String(repeating: "  ", count: row.depth)
            let name = row.name.isEmpty ? "Inbox (\"\")" : row.leafName
            out += "\(indent)- \(name): \(row.count)" + (row.total != row.count ? " · \(row.total)" : "")
                + (row.name.contains("/") ? "  [\(row.name)]" : "") + "\n"
        }
        return out
    }

    static func namedCounts(_ items: [NamedCount], empty: String, heading: String) -> String {
        guard !items.isEmpty else { return empty }
        return heading + ":\n" + items.map { "- \($0.name): \($0.count)" }.joined(separator: "\n") + "\n"
    }

    static func libraryInfo(_ library: AgentLibrary, stats: LibraryStats, guide: String) -> String {
        var out = "# Kan library\n"
        out += "- root: \(library.root.path) (\(library.location.source.displayName))"
            + (library.rootExists || library.loadError != nil ? "" : " — the folder doesn't exist yet") + "\n"
        if let error = library.loadError { out += "- problem: \(error)\n" }
        let statuses = stats.byStatus.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key.rawValue)" }
        out += "- calls: \(stats.calls)" + (statuses.isEmpty ? "" : " (\(statuses.joined(separator: ", ")))")
            + " · \(stats.starred) starred · \(stats.unlabeled) not labeled yet · \(KanTime.humanDuration(stats.totalSeconds)) in all\n"
        if let first = stats.first, let last = stats.last {
            out += "- span: \(AgentFormat.isoDate(first.startedAt, timeZone: first.timeZone)) → "
                + "\(AgentFormat.isoDate(last.startedAt, timeZone: last.timeZone))\n"
        }
        out += "- folders: \(stats.folders) · tags: \(stats.tags) · people: \(stats.people)\n"
        out += "- the user: \(library.settings.effectiveUserName) (speaker id \"me\")\n"
        out += "- index: \(library.store.indexJSONLURL.path) (one JSON summary per call, newest first)\n"
        out += "- Kan \(KanVersion.current); this server is read-only\n"
        out += "\n## AGENTS.md\n\n" + guide
        return out
    }

    /// AGENTS.md beyond this size is cut (Kan's own guide is about 13 KB; a user may have replaced it).
    static let maxGuideBytes = 256 * 1024

    /// The library's AGENTS.md, or Kan's built-in guide when the file is missing or unreadable.
    static func agentsGuide(root: URL) -> (text: String, fromFile: Bool) {
        let url = root.appendingPathComponent("AGENTS.md")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (AgentsGuide.text, false) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxGuideBytes + 1) else { return (AgentsGuide.text, false) }
        let text = String(decoding: data.prefix(maxGuideBytes), as: UTF8.self)
        return (data.count > maxGuideBytes ? text + "\n\n[AGENTS.md is longer; the rest was left out]\n" : text, true)
    }
}

/// The `instructions` text of the `initialize` result.
enum MCPInstructions {
    static func text(library: AgentLibrary) -> String {
        let name = library.settings.effectiveUserName
        let user = name == "Me" ? "the user" : "the user, \(name)"
        return """
            Kan is \(user)'s local call library: calls (Zoom, Google Meet, Teams, Telegram, Slack, FaceTime…) recorded \
            and transcribed on their Mac, mostly research discussions. Transcripts mix Bangla (বাংলা) and English, \
            often within one sentence; English technical terms often appear in Bengali script ("মডেল" = model). \
            The speaker with id "me" (is_me: true) is \(user); other speakers are the people they talked to \
            ("Speaker 2" = not named yet).

            Workflow: search_transcripts (find passages) or list_calls (browse, filter by folder/tag/person/app/date) → \
            get_call (metadata, notes, bookmarks, speakers, and an AI summary when Kan's OpenAI features wrote one) → \
            get_transcript (paged; follow next_offset, or read around a passage with from_seconds/to_seconds). \
            list_folders / list_tags / list_people show what filters exist; get_library_info explains the file layout.

            Rules: use only call ids returned by these tools — never guess them. started_at / at are absolute ISO-8601 \
            times with the call's UTC offset (time_zone names the zone); time_seconds and [hh:mm:ss] count from the \
            call's start. Cite the call title, date and [hh:mm:ss] when quoting. Transcripts are machine-generated \
            and may mishear names and jargon. Summaries are written by OpenAI from the transcript and can contain \
            mistakes: check them against the transcript and quote the transcript, not the summary. This server is \
            read-only; it cannot change calls.
            """
    }
}
