import Foundation
import KanCore

/// Kan's MCP tools. All are read-only.
enum MCPTools {
    static let all: [MCPTool] = [
        listCalls, searchTranscripts, getCall, getTranscript, listFolders, listTags, listPeople, getLibraryInfo, exportCall,
    ]

    static let defaultTranscriptPage = 400
    static let maxTranscriptPage = 1000

    // MARK: Shared arguments

    private static let callID: (name: String, schema: JSONValue) = (
        "call_id", Schema.string("The call's id from list_calls or search_transcripts (a unique prefix of at least 4 characters or the exact title also works). Never guess ids."))

    private static let filterProperties: [(name: String, schema: JSONValue)] = [
        ("folder", Schema.string("Only calls in this folder or its subfolders, e.g. \"Research/Thesis\". \"Inbox\" (or \"\") = calls not filed yet.")),
        ("tag", Schema.string("Only calls with this tag (case-insensitive, \"#\" optional).")),
        ("person", Schema.string("Only calls where a speaker or attendee name contains this text, e.g. \"Rahman\".")),
        ("app", Schema.string("Only calls from this app or platform: \"Zoom\", \"Zen\", \"Google Meet\", \"googleMeet\", \"Telegram\"…")),
        ("since", Schema.string("Only calls that started at or after this: YYYY-MM-DD, ISO-8601, \"today\", \"yesterday\" or an age like \"7d\", \"12h\", \"2w\". Dates without an offset are the user's local time.")),
        ("until", Schema.string("Only calls that started at or before this (same forms as since; a date covers its whole day).")),
        ("starred", Schema.boolean("true = only calls the user starred.")),
    ]

    private static func filter(_ args: ToolArguments, _ context: ToolContext) throws -> CallFilter {
        var filter = CallFilter()
        filter.folder = try args.string("folder")
        filter.tag = try args.string("tag")?.nonEmptyPath
        filter.person = try args.string("person")?.nonEmptyPath
        filter.app = try args.string("app")?.nonEmptyPath
        filter.since = try args.date("since", .start, context: context)
        filter.until = try args.date("until", .end, context: context)
        filter.starredOnly = try args.bool("starred") ?? false
        if let since = filter.since, let until = filter.until, since > until {
            throw ToolError("since is after until.")
        }
        return filter
    }

    // MARK: list_calls

    static let listCalls = MCPTool(
        name: "list_calls", title: "List calls",
        description: """
            List the user's recorded calls, newest first, with optional filters. Returns for each call: id, title, \
            folder, tags, started_at / ended_at (ISO-8601 with the call's UTC offset), time_zone, duration_seconds, \
            app, people (named speakers; the user is usually first), languages ("bn" Bangla, "en" English), status, \
            has_summary (an AI summary exists; get_call returns it) and a preview (the user's notes, else the \
            summary, else the first words). Page with offset; next_offset is null on the last page. Use \
            search_transcripts to find what was said, get_transcript to read a call.
            """,
        properties: [("query", Schema.string("Only calls containing all these words (title, tags, notes, bookmarks, summary or transcript; Bangla or English). Quote a phrase to match it exactly."))]
            + filterProperties + [
                ("status", Schema.string("Only calls with this status.", options: ["ready", "processing", "queued", "recording", "failed"])),
                ("limit", Schema.integer("Calls per page.", minimum: 1, maximum: 200, defaultValue: 20)),
                ("offset", Schema.integer("Calls to skip (from next_offset).", minimum: 0, defaultValue: 0)),
            ],
        required: [],
        run: { args, context in
            try context.requireLibrary()
            var filter = try filter(args, context)
            if let status = try args.string("status")?.nonEmptyPath {
                guard let value = CallStatus(rawValue: status.lowercased()) else {
                    throw ToolError("status must be one of: ready, processing, queued, recording, failed.")
                }
                filter.status = value
            }
            let limit = try args.int("limit", default: 20, minimum: 1, maximum: 200)
            let offset = try args.int("offset", default: 0, minimum: 0, maximum: Int.max)
            let page = LibraryQueries.list(context.store, filter: filter, text: try args.string("query"), offset: offset, limit: limit)
            let root = context.library.root
            let structured: JSONValue = [
                "calls": .array(page.calls.map { AgentJSON.summary($0, root: root) }),
                "total": .int(page.total),
                "offset": .int(page.offset),
                "limit": .int(limit),
                "next_offset": AgentJSON.optionalInt(page.nextOffset),
                "library_root": .string(root.path),
            ]
            return ToolOutput(text: MCPText.callList(page, libraryEmpty: context.store.summaries().isEmpty), structured: structured)
        })

    // MARK: search_transcripts

    static let searchTranscripts = MCPTool(
        name: "search_transcripts", title: "Search transcripts",
        description: """
            Find passages in the user's calls: transcripts, titles, tags, notes, bookmarks and AI summaries. Every \
            word must occur somewhere in the call; quote a phrase ("data augmentation") to match it exactly. \
            Case-insensitive; Bangla matches as written (vowel signs count, "ভাষা" also finds "ভাষার"); English terms \
            are often spoken in Bengali script ("মডেল", "ডেটাসেট"), so try both spellings. Returns passages, best \
            call first: call_id, title, started_at, time_zone, field (title, tags, notes, bookmark, summary or \
            transcript), time_seconds + timestamp ("hh:mm:ss" from the call's start; transcript and bookmark \
            passages), at (absolute time), speaker and a ~200-character snippet. Read around a passage with \
            get_transcript (from_seconds a little before time_seconds).
            """,
        properties: [("query", Schema.string("Words or \"quoted phrases\" to find (Bangla or English)."))]
            + filterProperties + [
                ("limit", Schema.integer("Maximum passages in total.", minimum: 1, maximum: 100, defaultValue: 20)),
                ("max_per_call", Schema.integer("Maximum passages per call (its best ones).", minimum: 1, maximum: 50, defaultValue: 5)),
            ],
        required: ["query"],
        run: { args, context in
            try context.requireLibrary()
            let query = try args.requiredString("query", hint: "To browse calls without a query, use list_calls.")
            let filter = try filter(args, context)
            let limit = try args.int("limit", default: 20, minimum: 1, maximum: 100)
            let perCall = try args.int("max_per_call", default: 5, minimum: 1, maximum: 50)
            let results = LibraryQueries.search(context.store, text: query, filter: filter, limit: limit, perCall: perCall)
            let structured: JSONValue = [
                "query": .string(query),
                "passages": .array(results.passages.map(AgentJSON.passage)),
                "matched_calls": .int(results.matchedCalls),
                "total_hits": .int(results.totalHits),
                "truncated": .bool(results.truncated),
            ]
            return ToolOutput(text: MCPText.passages(results, query: query), structured: structured)
        })

    // MARK: get_call

    static let getCall = MCPTool(
        name: "get_call", title: "Get call details",
        description: """
            Everything about one call except its transcript: title, folder, tags, the user's notes, bookmarks \
            (moments the user marked, with timestamps), speakers (id "me" / is_me = the user; "Speaker N" = not \
            named yet), times, app, meeting link, languages, status and file paths. When Kan's optional OpenAI \
            features wrote them, also ai_summary (overview, key_points, ideas, decisions, action_items, \
            open_questions, model, generated_at; transcript_changed = written from an earlier version of the \
            transcript) and title_ideas. Summaries are AI-written and can contain mistakes: check facts in the \
            transcript. Use get_transcript for the words.
            """,
        properties: [callID],
        required: ["call_id"],
        run: { args, context in
            let summary = try context.resolve(try args.requiredString("call_id"))
            let record = try context.record(summary)
            let files = context.store.files(for: summary.id)
            return ToolOutput(text: MCPText.call(record, files: files),
                              structured: AgentJSON.call(record, files: files))
        })

    // MARK: get_transcript

    static let getTranscript = MCPTool(
        name: "get_transcript", title: "Read a transcript",
        description: """
            Read a call's transcript, paged by segments (default \(defaultTranscriptPage) per page; follow next_offset \
            until it is null). Optionally only the part between from_seconds and to_seconds (seconds from the \
            call's start, e.g. from search results' time_seconds). Formats: "markdown" (speaker turns with \
            [hh:mm:ss]; the first page of a whole call starts with its AI summary, if it has one), "text" \
            ("[hh:mm:ss] Name: words" lines) or "json" (segments with start/end, speaker id, language, text). The \
            speaker with is_me / id "me" is the user. Text mixes Bangla and English and is machine-transcribed: \
            names and jargon may be misheard.
            """,
        properties: [
            callID,
            ("format", Schema.string("Output format.", options: ["markdown", "text", "json"], defaultValue: "markdown")),
            ("from_seconds", Schema.number("Start of the part to read, in seconds from the call's start.", minimum: 0)),
            ("to_seconds", Schema.number("End of the part to read, in seconds from the call's start.", minimum: 0)),
            ("offset", Schema.integer("Segments to skip within the range (from next_offset).", minimum: 0, defaultValue: 0)),
            ("limit", Schema.integer("Segments per page.", minimum: 1, maximum: maxTranscriptPage, defaultValue: defaultTranscriptPage)),
        ],
        required: ["call_id"],
        run: { args, context in
            let summary = try context.resolve(try args.requiredString("call_id"))
            let format = try args.choice("format", ["markdown": "markdown", "md": "markdown", "text": "text", "txt": "text",
                                                    "plain": "text", "json": "json"], default: "markdown")
            let from = try args.seconds("from_seconds")
            let to = try args.seconds("to_seconds")
            if let from, let to, to <= from { throw ToolError("to_seconds must be after from_seconds.") }
            let offset = try args.int("offset", default: 0, minimum: 0, maximum: Int.max)
            let limit = try args.int("limit", default: defaultTranscriptPage, minimum: 1, maximum: maxTranscriptPage)
            let record = try context.record(summary)
            let page = LibraryQueries.transcript(record, from: from, to: to, offset: offset, limit: limit)

            var structured: [String: JSONValue] = [
                "call_id": .string(record.id.rawValue),
                "title": .string(record.title),
                "started_at": .string(AgentFormat.isoDate(record.startedAt, timeZone: record.timeZone)),
                "time_zone": .string(record.timeZone),
                "format": .string(format),
                "offset": .int(page.offset),
                "limit": .int(limit),
                "returned": .int(page.segments.count),
                "total_segments": .int(page.total),
                "call_segments": .int(page.callSegments),
                "next_offset": AgentJSON.optionalInt(page.nextOffset),
                "speakers": .array(record.speakers.map {
                    ["id": .string($0.id), "name": .string($0.name), "is_me": .bool($0.isMe)]
                }),
            ]
            if let from { structured["from_seconds"] = .double(AgentFormat.rounded(from)) }
            if let to { structured["to_seconds"] = .double(AgentFormat.rounded(to)) }
            if let note = LibraryQueries.statusNote(record) { structured["transcript_note"] = .string(note) }
            let text: String
            switch format {
            case "json":
                structured["segments"] = .array(page.segments.map { AgentJSON.segment($0, in: record) })
                text = try JSONValue.object(structured).compactString()
            default:
                let body = MCPText.transcriptBody(page, markdown: format == "markdown")
                structured["text"] = .string(body)
                text = MCPText.transcriptPage(page, body: body, markdown: format == "markdown")
            }
            return ToolOutput(text: text, structured: .object(structured))
        })

    // MARK: Folders, tags, people

    static let listFolders = MCPTool(
        name: "list_folders", title: "List folders",
        description: "The library's folders in tree order with call counts: count = calls directly in the folder, total = including subfolders. \"\" is the Inbox (calls not filed yet). Use a name as list_calls' folder filter.",
        properties: [], required: [],
        run: { _, context in
            try context.requireLibrary()
            let rows = LibraryQueries.folderRows(context.store)
            return ToolOutput(text: MCPText.folders(rows), structured: ["folders": .array(rows.map(AgentJSON.folder))])
        })

    static let listTags = MCPTool(
        name: "list_tags", title: "List tags",
        description: "Tags the user gave calls, most used first, with the number of calls each.",
        properties: [], required: [],
        run: { _, context in
            try context.requireLibrary()
            let tags = context.store.tags()
            return ToolOutput(text: MCPText.namedCounts(tags, empty: "No tags yet.", heading: "Tags (calls)"),
                              structured: ["tags": .array(tags.map(AgentJSON.namedCount))])
        })

    static let listPeople = MCPTool(
        name: "list_people", title: "List people",
        description: "People the user talked to (named speakers across calls, without the user and without placeholders like \"Speaker 2\"), most frequent first, with the number of calls each. Use a name as the person filter.",
        properties: [], required: [],
        run: { _, context in
            try context.requireLibrary()
            let people = context.store.people()
            return ToolOutput(text: MCPText.namedCounts(people, empty: "No named people yet (speakers are named in Kan after a call).",
                                                         heading: "People (calls)"),
                              structured: ["people": .array(people.map(AgentJSON.namedCount))])
        })

    // MARK: get_library_info

    static let getLibraryInfo = MCPTool(
        name: "get_library_info", title: "Library info",
        description: "Where the library is, how many calls/folders/tags/people it has, the date range, the user's name, and the library's AGENTS.md (how the files are organized: front matter keys, JSON fields, conventions).",
        properties: [], required: [],
        run: { _, context in
            let library = context.library
            let stats = LibraryQueries.stats(context.store)
            let guide = MCPText.agentsGuide(root: library.root)
            var structured: [String: JSONValue] = [
                "root": .string(library.root.path),
                "root_exists": .bool(library.rootExists),
                "location_source": .string(library.location.source.rawValue),
                "kan_version": .string(KanVersion.current),
                "calls": .int(stats.calls),
                "calls_by_status": .object(Dictionary(uniqueKeysWithValues: stats.byStatus.map { ($0.key.rawValue, JSONValue.int($0.value)) })),
                "starred": .int(stats.starred),
                "unlabeled": .int(stats.unlabeled),
                "folders": .int(stats.folders),
                "tags": .int(stats.tags),
                "people": .int(stats.people),
                "total_duration_seconds": .int(AgentFormat.wholeSeconds(stats.totalSeconds)),
                "user_name": .string(library.settings.effectiveUserName),
                "index_markdown_path": .string(context.store.indexMarkdownURL.path),
                "index_jsonl_path": .string(context.store.indexJSONLURL.path),
                "agents_md_path": .string(context.store.agentsGuideURL.path),
                "agents_md": .string(guide.text),
                "agents_md_source": .string(guide.fromFile ? "file" : "built-in"),
                "local_time_zone": .string(context.timeZone.identifier),
            ]
            if let first = stats.first {
                structured["first_call_at"] = .string(AgentFormat.isoDate(first.startedAt, timeZone: first.timeZone))
            }
            if let last = stats.last {
                structured["last_call_at"] = .string(AgentFormat.isoDate(last.startedAt, timeZone: last.timeZone))
            }
            if let error = library.loadError { structured["load_error"] = .string(error) }
            return ToolOutput(text: MCPText.libraryInfo(library, stats: stats, guide: guide.text), structured: .object(structured))
        })

    // MARK: export_call

    static let exportCall = MCPTool(
        name: "export_call", title: "Export a call",
        description: """
            One whole call as a document: "markdown" (the library's .md: front matter, AI summary if any, notes, \
            bookmarks, transcript), "text", "json" (the full call record, the source of truth), "srt" or "vtt" \
            (subtitles). Long calls are large; to read a transcript in parts use get_transcript.
            """,
        properties: [
            callID,
            ("format", Schema.string("Export format.", options: ["markdown", "text", "json", "srt", "vtt"], defaultValue: "markdown")),
        ],
        required: ["call_id"],
        run: { args, context in
            let summary = try context.resolve(try args.requiredString("call_id"))
            let name = try args.choice("format", ["markdown": "markdown", "md": "markdown", "text": "text", "txt": "text",
                                                  "plain": "text", "json": "json", "srt": "srt", "vtt": "vtt",
                                                  "webvtt": "vtt"], default: "markdown")
            let format = ExportFormat(rawValue: name) ?? .markdown
            let record = try context.record(summary)
            let data: Data
            do {
                data = try TranscriptRenderer.render(record, format: format)
            } catch {
                throw ToolError("Couldn't export \(summary.id): \(error.localizedDescription)", kind: .exportFailed)
            }
            let content = String(decoding: data, as: UTF8.self)
            let structured: JSONValue = [
                "call_id": .string(record.id.rawValue),
                "title": .string(record.title),
                "format": .string(format.rawValue),
                "file_name": .string(TranscriptRenderer.suggestedFileName(for: record, format: format)),
                "bytes": .int(data.count),
                "content": .string(content),
            ]
            return ToolOutput(text: content, structured: structured)
        })
}
