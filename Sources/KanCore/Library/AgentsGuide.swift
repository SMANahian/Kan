import Foundation

/// AGENTS.md: how the library is organized, for AI agents reading it.
///
/// The file carries a version marker. Kan writes it when it is missing and rewrites it only when
/// the marker is older than `version`; a file without a marker is the user's own and is left alone.
public enum AgentsGuide {
    /// Bump when the text changes in a way agents should see.
    /// 2: OpenAI summaries and title ideas (`ai`, `## Summary`, `hasSummary`).
    public static let version = 2

    static let markerPrefix = "<!-- kan-agents-guide-version: "

    /// The version embedded in an AGENTS.md text, or nil when there is no Kan marker.
    public static func embeddedVersion(in text: String) -> Int? {
        guard let range = text.range(of: markerPrefix) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    /// Writes AGENTS.md into `root` when missing or outdated. Returns true if it was written.
    @discardableResult
    static func writeIfNeeded(root: URL) throws -> Bool {
        let url = root.appendingPathComponent(LibraryNaming.agentsFileName)
        if let data = FileManager.default.contents(atPath: url.path) {
            let existing = String(decoding: data, as: UTF8.self)
            guard let installed = embeddedVersion(in: existing) else { return false }   // user-owned file
            guard installed < version else { return false }
        }
        try FileOps.writeAtomically(Data(text.utf8), to: url)
        return true
    }

    /// The guide.
    public static var text: String {
        """
        \(markerPrefix)\(version) -->
        <!-- Written by Kan \(KanVersion.current). Kan rewrites this file when a newer guide ships; \
        remove the version marker above to keep your own edits. -->

        # Kan call library — guide for AI agents

        This folder is the call library of **Kan** (কান, Bangla for "ear"), a macOS menu-bar app
        that records the user's calls (Zoom, Google Meet in any browser, Teams, Telegram, Slack,
        Discord, WhatsApp, FaceTime, …) and transcribes them **locally on the Mac** in **Bangla and
        English**, with who said what. The user is a researcher; most calls are research discussions.
        Audio never leaves the Mac. Only if the user set up Kan's optional OpenAI features was a
        call's transcript text (with its title, notes, tags and bookmarks) also sent to OpenAI, which
        suggested titles and wrote a summary (see "AI summaries and title ideas" below). Everything
        is plain files: read them directly, or use the `kan` command-line tool / MCP server
        described below.

        ## Layout

        ```
        AGENTS.md          this guide
        index.md           table of every call, newest first (regenerated automatically)
        index.jsonl        one JSON summary per call, newest first (regenerated automatically)
        Inbox/             calls not filed into a folder yet (folder "")
          2026-11-16 1530 Zoom call.md      the transcript (YAML front matter + Markdown)
          2026-11-16 1530 Zoom call.json    the full call record — the source of truth
        Research/Thesis/   user folders, nested with "/"
          2026-11-14 1000 Advisor meeting.md
          2026-11-14 1000 Advisor meeting.json
        ```

        * Every call is a pair of files with the same base name: `<yyyy-MM-dd HHmm> <title>` in the
          call's own local time. Same-minute, same-title calls get " (2)", " (3)", …
        * File names change when the user renames or moves a call. **Identify calls by `kan_id` /
          `id`** (a 26-character ULID that sorts by time), never by file name.
        * The `.md` is rendered from the `.json`; when they differ, the `.json` wins.
        * Audio is **not** in this folder (it stays in Kan's private storage).

        ## Quick recipes

        * Recent calls: read `index.jsonl` (or `index.md`) — it is ordered newest first.
        * One call: open its `.md` for reading, its `.json` for exact data (segment times, speakers).
          Its `## Summary`, when it has one, tells you quickly what the call was about.
        * Find something: `kan search "query"`, or search the `.md` files (`rg -i query .`). Text is
          Unicode NFC; search Bangla as typed (no diacritic folding: vowel signs are letters).
        * Quote the call title and date plus `[hh:mm:ss]` timestamps when you cite something.

        ## Transcript (.md)

        ```
        ---
        kan_id: 01JD3Q8Z6M7K2V9R4T5N8P1XQA
        title: "Advisor meeting – augmentation idea"
        date: 2026-11-14T10:00:12-05:00
        end: 2026-11-14T10:42:25-05:00
        duration: "00:42:13"
        app: Zoom
        platform: zoom
        folder: "Research/Thesis"
        tags: [research, thesis]
        people: ["Nahian", "Prof. Rahman"]
        languages: [en, bn]
        starred: true
        status: ready
        me: "Nahian"
        ---

        # Advisor meeting – augmentation idea
        Sat 14 Nov 2026, 10:00–10:42 · Zoom · 42 min · Nahian (me), Prof. Rahman

        ## Summary               (optional: written by OpenAI from the transcript, see below)
        ## Notes                 (the user's own notes, if any)
        ## Bookmarks             (moments the user marked: "- [00:12:31] note")
        ## Transcript
        **Nahian** [00:00:05]
        So I was thinking…

        **Prof. Rahman** [00:00:21]
        That's interesting…
        ```

        Front matter keys (stable):

        | key | meaning |
        |---|---|
        | `kan_id` | call id (ULID); same as `id` in the JSON |
        | `title` | call title (the user's label, or a suggestion such as "Zoom call with Rahim") |
        | `date`, `end` | start / end, ISO-8601 with the UTC offset of the call's time zone |
        | `duration` | "hh:mm:ss" |
        | `app` | app the call was captured from ("Zoom", "Zen", "Telegram"…) |
        | `platform` | `zoom`, `googleMeet`, `teams`, `slack`, `discord`, `telegram`, `whatsapp`, `facetime`, `webex`, `signal`, `skype`, `messenger`, `jitsi`, `whereby`, `browser`, `manual` (recorded by hand, e.g. in person), `imported`, `other` |
        | `folder` | library folder; `""` is the Inbox; nested folders use "/" |
        | `tags` | the user's tags |
        | `people` | named speakers: the user first, then the other people (placeholder names like "Speaker 2" are left out) |
        | `languages` | languages detected: `bn` (Bangla), `en` (English) |
        | `starred` | the user starred the call (often: it contains a research idea) |
        | `status` | `recording`, `queued`, `processing`, `ready`, `failed` |
        | `me` | (optional) the user's own speaker name |
        | `attendees` | (optional) calendar attendees |
        | `calendar_event` | (optional) matched calendar event title |
        | `meeting_url` | (optional) meeting link |

        In the body, each paragraph is one speaker turn: consecutive segments of the same speaker
        (less than 2 s apart, up to ~90 s) are merged under one `**Name** [hh:mm:ss]` heading, where
        the time is the turn's start, counted from the beginning of the call. Calls that are still
        being transcribed show a placeholder instead of the transcript; failed ones show the error.

        ## Call record (.json) — the source of truth

        Pretty-printed JSON with sorted keys. Dates are ISO-8601 strings with offsets. Times inside
        a call (`start`, `end`, `time`, `talkTime`) are **seconds from the start of the call** — add
        them to `startedAt` for wall-clock time.

        | field | type | meaning |
        |---|---|---|
        | `kind` | string | always `"kan.call"` (ignore JSON files without it) |
        | `schema` | int | record schema version (currently 1) |
        | `id` | string | call id (ULID) |
        | `title` | string | call title |
        | `folder` | string | `""` = Inbox; "Research/Thesis" for nested folders |
        | `tags` | [string] | tags |
        | `notes` | string | the user's notes (Markdown) |
        | `starred` | bool | starred by the user |
        | `labeled` | bool | the user has labeled the call (otherwise title/folder are defaults) |
        | `startedAt`, `endedAt` | date | call start / end |
        | `timeZone` | string | IANA time zone at recording time, e.g. "America/New_York" |
        | `source` | object | `appName`, `bundleID`, `platform` (see above), `meetingTitle`, `meetingURL` |
        | `status` | string | `recording`, `queued`, `processing`, `ready`, `failed` |
        | `languageMode` | string | what the user asked for: `auto` (Bangla + English), `bangla`, `english` |
        | `languages` | [string] | languages actually detected (`bn`, `en`) |
        | `calendarEventTitle` | string? | matched calendar event |
        | `attendees` | [string] | calendar attendees |
        | `speakers` | [object] | see below |
        | `segments` | [object] | the transcript, ordered by `start`; see below |
        | `bookmarks` | [object] | `id`, `time`, `endTime` (optional), `note`, `createdAt` |
        | `audio` | object? | kept audio: `meFile`, `themFile`, `format` (`m4a`/`wav`), `sizeBytes`, `deletedAt` (set once retention deleted it) — files live outside this folder |
        | `processing` | object? | `modelsUsed`, `languageMode`, `startedAt`, `finishedAt`, `processingSeconds`, `error` (why it failed), `warnings`, `kanVersion`, `attempts`, `stats` (counters) |
        | `ai` | object? | title ideas and a summary from OpenAI, only when the user asked Kan for them (see below) |
        | `createdAt`, `updatedAt` | date | record bookkeeping |

        Speakers (`speakers[]`):

        | field | meaning |
        |---|---|
        | `id` | `"me"` for the user's microphone; `"s1"`, `"s2"`, … for remote speakers |
        | `name` | display name; may be a placeholder like "Speaker 2" |
        | `isMe` | **true for the user** — the person this library belongs to |
        | `nameSource` | `automatic` (placeholder or the user's own name), `user` (typed by the user), `voiceprint` (recognized from a remembered voice — usually right, not certain) |
        | `talkTime` | seconds of speech |
        | `personID` | remembered-voice id, when linked |
        | `suggestedName` | a possible match that was not confident enough to apply ("sounds like …") |

        Segments (`segments[]`):

        | field | meaning |
        |---|---|
        | `id` | integer, unique within the call |
        | `start`, `end` | seconds from call start |
        | `speakerID` | a `speakers[].id` |
        | `channel` | `me` (the user's microphone) or `them` (the call app's audio) |
        | `text` | the words (Unicode NFC) |
        | `language` | `bn` or `en` |
        | `confidence` | mean token probability 0…1, when known |
        | `flags` | `echoSuspect` (the remote side leaking into the user's mic — usually a duplicate, ignore it), `lowConfidence`, `hallucinationSuspect`, `truncatedRetry`, `edited` (corrected by the user) |

        `index.jsonl` holds one summary per line: `id`, `title`, `folder`, `tags`, `starred`,
        `labeled`, `startedAt`, `endedAt`, `timeZone`, `appName`, `platform`, `status`,
        `speakerNames`, `languages`, `segmentCount`, `wordCount`, `hasAudio`, `hasSummary` (the call
        has an AI summary; missing in lines written by older versions), `preview` (first words of the
        notes, the summary or the transcript) and `markdownPath` / `jsonPath` (relative to this folder).

        ## AI summaries and title ideas (optional)

        Off by default. When the user saved an OpenAI API key in Kan and turned these features on
        (or asked for them on one call), Kan sent the call's transcript text, title, notes, tags and
        bookmarks (never audio) to OpenAI and stored the answers in the call's `.json` under `ai`:

        | field | meaning |
        |---|---|
        | `ai.summary` | `overview` (a few sentences), `keyPoints`, `ideas` (research ideas, methods, datasets, papers), `decisions`, `actionItems` ("Owner: task"), `openQuestions` — lists are empty when nothing fits — plus `language` (`english`, `bangla`, `matchCall`), `model`, `generatedAt`, `fingerprint`, `shortened` |
        | `ai.titleSuggestions` | `titles` (best first), `model`, `generatedAt`, `fingerprint` |
        | `ai.appliedTitle` | the idea Kan made the call's title; while `title` equals it, nobody changed the title since |

        * `fingerprint` identifies the transcript the text was written from: its lines with the
          speakers' names. Once the call is transcribed again, a speaker renamed or a line edited,
          it no longer matches: the summary is outdated until it is written again.
        * `shortened: true` — the call was too long to send whole; the middle of the transcript was
          left out.
        * The `.md` shows the summary as `## Summary` after the header line: the overview, then
          `### Key points`, `### Ideas`, `### Decisions`, `### Action items`, `### Open questions`
          (lists with items only), then a line like
          "_Summary written by OpenAI (gpt-6.1-terra) on 17 Nov 2026; it can contain mistakes._"
          and, when it is outdated, "_The transcript changed after this summary was written._".
          Timestamps like [00:12:34] point into the transcript.
        * The summary is written by an AI model from a machine transcript and **can contain
          mistakes**. Use it to find your way; for facts, quote the transcript with `[hh:mm:ss]`.

        ## Language

        * Calls mix **Bangla (বাংলা) and English**, often within one sentence (code-switching).
          Each segment is tagged `bn` or `en` by its dominant language.
        * English technical terms often appear **in Bengali script** ("মডেল" = model, "ডেটাসেট" =
          dataset, "পেপার" = paper). Treat them as the English words.
        * Bangla sentences end with "।". Text is Unicode NFC.
        * Transcripts are machine-generated: expect errors, especially in names, jargon and
          short or overlapping turns. Say so when a passage looks garbled instead of guessing.

        ## The `kan` command-line tool

        Kan ships a `kan` CLI that reads this library (it understands Bangla search, filters and
        exports):

        * `kan list` — recent calls
        * `kan search <words…>` — matching passages in titles, tags, notes, bookmarks, summaries
          and transcripts, with call id, `[hh:mm:ss]`, speaker and a snippet (every word must occur
          in the call; quote a phrase to match it exactly)
        * `kan show <call-id>` — one call's `.md` (summary, notes, bookmarks, transcript)
        * `kan export <call-id>` — Markdown, plain text, JSON, SRT or WebVTT
        * `kan mcp` — a Model Context Protocol server on stdio

        Run `kan help` for the exact commands and options of the installed version.

        ## MCP server

        `kan mcp` speaks MCP (JSON-RPC 2.0 over stdio) and is **read-only**: it lists, searches and
        reads calls but never changes the library; `get_call` includes a call's summary and title
        ideas when it has them. Example for Claude Code:
        `claude mcp add kan -- kan mcp`; generic MCP config:
        `{"mcpServers": {"kan": {"command": "kan", "args": ["mcp"]}}}`.

        ## Rules for agents

        * Treat this folder as **read-only** unless the user explicitly asks for a change. Kan owns
          these files: it regenerates `.md` files and the indexes from the `.json` records. When the
          user does ask (e.g. "rename Speaker 2 to Rahim"), edit only the call's `.json`, keep it
          valid and never change `id` or `kind`; Kan picks the change up and re-renders the `.md`.
        * Never invent call ids, dates, timestamps or quotes. Cite the call (title + date) and
          `[hh:mm:ss]` times so the user can jump to the moment in Kan.
        * A `## Summary` (`ai.summary`) is AI-written and can be wrong or outdated: check what it
          says against the transcript before you rely on it, and quote the transcript, not the
          summary. Leave `ai` as it is when you edit a `.json`.
        * The person with `isMe: true` / speaker id `me` is the user; everyone else is someone they
          talked to. Placeholder names ("Speaker 2") mean nobody has named that speaker yet.
        * Transcripts contain other people's words. Don't share them outside this conversation
          unless the user asks.
        """
    }
}
