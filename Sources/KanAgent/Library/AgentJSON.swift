import Foundation
import KanCore

/// The JSON shapes the CLI (`--json`) and the MCP server (`structuredContent`) return.
///
/// Conventions: snake_case keys; every absolute time is ISO-8601 with the UTC offset of the call's
/// own time zone (`started_at`, `at`) next to that zone's identifier (`time_zone`); times inside a
/// call are seconds from its start (`time_seconds`) plus "hh:mm:ss" (`timestamp`); file paths are
/// absolute. Optional values that are unknown are left out.
public enum AgentJSON {
    public static func summary(_ s: CallSummary, root: URL) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(s.id.rawValue),
            "title": .string(s.title),
            "folder": .string(s.folder),
            "tags": strings(s.tags),
            "starred": .bool(s.starred),
            "labeled": .bool(s.labeled),
            "started_at": .string(AgentFormat.isoDate(s.startedAt, timeZone: s.timeZone)),
            "ended_at": .string(AgentFormat.isoDate(s.endedAt, timeZone: s.timeZone)),
            "time_zone": .string(s.timeZone),
            "duration_seconds": .int(AgentFormat.wholeSeconds(s.duration)),
            "app": .string(s.appName),
            "platform": .string(s.platform.rawValue),
            "people": strings(LibraryQueries.people(s)),
            "languages": strings(s.languages),
            "status": .string(s.status.rawValue),
            "segment_count": .int(s.segmentCount),
            "word_count": .int(s.wordCount),
            "has_audio": .bool(s.hasAudio),
            "has_summary": .bool(s.hasSummary),
            "markdown_path": .string(path(s.markdownPath, root: root)),
            "json_path": .string(path(s.jsonPath, root: root)),
        ]
        if !s.preview.isEmpty { o["preview"] = .string(s.preview) }
        return .object(o)
    }

    /// Everything about a call except its transcript. `ai_summary` and `title_ideas` are there
    /// only when OpenAI wrote them.
    public static func call(_ record: CallRecord, files: CallFiles?) -> JSONValue {
        let zone = record.timeZone
        func iso(_ date: Date) -> JSONValue { .string(AgentFormat.isoDate(date, timeZone: zone)) }
        let visible = LibraryQueries.visibleSegments(record)
        var segmentsBySpeaker: [String: Int] = [:]
        for segment in visible { segmentsBySpeaker[segment.speakerID, default: 0] += 1 }

        var o: [String: JSONValue] = [
            "id": .string(record.id.rawValue),
            "title": .string(record.title),
            "folder": .string(record.folder),
            "tags": strings(record.tags),
            "notes": .string(record.notes),
            "starred": .bool(record.starred),
            "labeled": .bool(record.labeled),
            "status": .string(record.status.rawValue),
            "started_at": iso(record.startedAt),
            "ended_at": iso(record.endedAt),
            "time_zone": .string(zone),
            "duration_seconds": .int(AgentFormat.wholeSeconds(record.duration)),
            "duration": .string(KanTime.hms(record.duration)),
            "summary_line": .string(TranscriptRenderer.summaryLine(record)),
            "app": .string(record.source.appName),
            "platform": .string(record.source.platform.rawValue),
            "platform_name": .string(record.source.platform.displayName),
            "language_mode": .string(record.languageMode.rawValue),
            "languages": strings(record.languages),
            "attendees": strings(record.attendees),
            "segment_count": .int(visible.count),
            "has_audio": .bool(record.audio?.isAvailable ?? false),
            "speakers": .array(record.speakers.map { speaker in
                var s: [String: JSONValue] = [
                    "id": .string(speaker.id),
                    "name": .string(speaker.name),
                    "is_me": .bool(speaker.isMe),
                    "name_source": .string(speaker.nameSource.rawValue),
                    "talk_time_seconds": .double(AgentFormat.rounded(speaker.talkTime)),
                    "segment_count": .int(segmentsBySpeaker[speaker.id] ?? 0),
                    "has_placeholder_name": .bool(speaker.hasDefaultName),
                ]
                if let suggestion = speaker.suggestedName { s["suggested_name"] = .string(suggestion) }
                return .object(s)
            }),
            "bookmarks": .array(record.bookmarks.sorted { $0.time < $1.time }.map { bookmark in
                var b: [String: JSONValue] = [
                    "id": .string(bookmark.id),
                    "time_seconds": .double(AgentFormat.rounded(bookmark.time)),
                    "timestamp": .string(KanTime.hms(bookmark.time)),
                    "at": iso(record.startedAt.addingTimeInterval(bookmark.time)),
                    "note": .string(bookmark.note),
                ]
                if let end = bookmark.endTime, end > bookmark.time {
                    b["end_seconds"] = .double(AgentFormat.rounded(end))
                    b["end_timestamp"] = .string(KanTime.hms(end))
                }
                return .object(b)
            }),
        ]
        if let me = record.me { o["me"] = .string(me.name) }
        if let title = record.source.meetingTitle { o["meeting_title"] = .string(title) }
        if let url = record.source.meetingURL { o["meeting_url"] = .string(url) }
        if let event = record.calendarEventTitle { o["calendar_event"] = .string(event) }
        if let note = LibraryQueries.statusNote(record) { o["transcript_note"] = .string(note) }
        if let processing = record.processing {
            var p: [String: JSONValue] = [
                "models_used": strings(processing.modelsUsed),
                "language_mode": .string(processing.languageMode.rawValue),
                "warnings": strings(processing.warnings),
                "kan_version": .string(processing.kanVersion),
                "attempts": .int(processing.attempts),
            ]
            if let error = processing.error { p["error"] = .string(error) }
            if let finished = processing.finishedAt { p["finished_at"] = iso(finished) }
            if let seconds = processing.processingSeconds { p["processing_seconds"] = .double(AgentFormat.rounded(seconds)) }
            o["processing"] = .object(p)
        }
        if let summary = record.ai?.summary, summary.hasText { o["ai_summary"] = aiSummary(summary, in: record) }
        if let ideas = record.ai?.titleSuggestions, !ideas.titles.isEmpty { o["title_ideas"] = titleIdeas(ideas, in: record) }
        if let files {
            o["markdown_path"] = .string(files.markdown.path)
            o["json_path"] = .string(files.json.path)
        }
        return .object(o)
    }

    /// The summary OpenAI wrote of a call: its text, which model wrote it when, and whether the
    /// transcript changed since (`transcript_changed`: re-transcribed, a speaker renamed or a line
    /// edited after it was written).
    public static func aiSummary(_ summary: AISummary, in record: CallRecord) -> JSONValue {
        var o: [String: JSONValue] = [
            "overview": .string(summary.overview),
            "key_points": strings(summary.keyPoints),
            "ideas": strings(summary.ideas),
            "decisions": strings(summary.decisions),
            "action_items": strings(summary.actionItems),
            "open_questions": strings(summary.openQuestions),
            "language": .string(summary.language.rawValue),
            "shortened": .bool(summary.shortened),
            "transcript_changed": .bool(record.isSummaryOutdated),
        ]
        if !summary.model.singleLineText.isEmpty { o["model"] = .string(summary.model.singleLineText) }
        if summary.generatedAt > .distantPast {
            o["generated_at"] = .string(AgentFormat.isoDate(summary.generatedAt, timeZone: record.timeZone))
        }
        return .object(o)
    }

    /// Title ideas OpenAI suggested for a call, best first.
    public static func titleIdeas(_ ideas: AITitleSuggestions, in record: CallRecord) -> JSONValue {
        var o: [String: JSONValue] = [
            "titles": strings(ideas.titles),
            "transcript_changed": .bool(record.areTitleIdeasOutdated),
        ]
        if !ideas.model.singleLineText.isEmpty { o["model"] = .string(ideas.model.singleLineText) }
        if ideas.generatedAt > .distantPast {
            o["generated_at"] = .string(AgentFormat.isoDate(ideas.generatedAt, timeZone: record.timeZone))
        }
        return .object(o)
    }

    /// One search hit with where it is (call, field, time) and what it says.
    public static func passage(_ passage: Passage) -> JSONValue {
        let s = passage.summary, hit = passage.hit
        var o: [String: JSONValue] = [
            "call_id": .string(hit.callID.rawValue),
            "title": .string(s.title),
            "started_at": .string(AgentFormat.isoDate(s.startedAt, timeZone: s.timeZone)),
            "time_zone": .string(s.timeZone),
            "folder": .string(s.folder),
            "field": .string(hit.field.rawValue),
            "snippet": .string(hit.snippet),
            "terms": strings(hit.terms),
        ]
        if let time = hit.time {
            o["time_seconds"] = .double(AgentFormat.rounded(time))
            o["timestamp"] = .string(KanTime.hms(time))
            o["at"] = .string(AgentFormat.isoDate(s.startedAt.addingTimeInterval(time), timeZone: s.timeZone))
        }
        if let segment = hit.segmentID { o["segment_id"] = .int(segment) }
        if let speaker = hit.speakerName { o["speaker"] = .string(speaker) }
        return .object(o)
    }

    public static func segment(_ segment: TranscriptSegment, in record: CallRecord) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .int(segment.id),
            "start_seconds": .double(AgentFormat.rounded(segment.start)),
            "end_seconds": .double(AgentFormat.rounded(segment.end)),
            "timestamp": .string(KanTime.hms(segment.start)),
            "speaker_id": .string(segment.speakerID),
            "speaker": .string(record.speakerName(segment.speakerID)),
            "is_me": .bool(record.speaker(segment.speakerID)?.isMe ?? (segment.speakerID == Speaker.meID)),
            "language": .string(segment.language),
            "text": .string(segment.text.nfc),
        ]
        if let confidence = segment.confidence { o["confidence"] = .double(AgentFormat.rounded(confidence)) }
        let flags = segment.flags.filter { $0 != .echoSuspect }
        if !flags.isEmpty { o["flags"] = strings(flags.map(\.rawValue)) }
        return .object(o)
    }

    public static func folder(_ row: FolderRow) -> JSONValue {
        ["name": .string(row.name), "display_name": .string(row.displayName), "count": .int(row.count),
         "total": .int(row.total)]
    }

    public static func namedCount(_ item: NamedCount) -> JSONValue {
        ["name": .string(item.name), "count": .int(item.count)]
    }

    // MARK: Helpers

    static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    static func path(_ relative: String, root: URL) -> String {
        relative.isEmpty ? "" : root.appendingPathComponent(relative).path
    }

    static func optionalInt(_ value: Int?) -> JSONValue { value.map { .int($0) } ?? .null }
}
