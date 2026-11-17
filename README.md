# Kan · কান

Kan (Bangla for "ear") is a macOS menu-bar app that notices when you're on a call, records both
sides on your Mac, and afterwards transcribes the call, in Bangla, English or both mixed together,
with who said what. Right after each call it asks you to label it, and it keeps every transcript as
plain Markdown + JSON that you, Kan's search and your AI agents can read.

Kan uploads nothing: its only network use is the one-time model downloads.

- **Automatic call detection**: Zoom, Google Meet in any browser (Zen, Firefox, Chrome, Safari,
  Arc, Brave, Edge…), Microsoft Teams, Slack huddles, Discord, Telegram, WhatsApp, Signal,
  FaceTime, Webex and more.
- **Both sides, separately**: your microphone is "you"; the call app's audio is everyone else.
- **Bangla + English**: the language is decided for every stretch of speech, so code-switched
  calls come out right. Bangla goes to a Bangla-tuned Whisper model, English to Whisper turbo.
- **Who said what**: other speakers are told apart automatically. Name them once; Kan can remember
  voices for later calls if you let it.
- **Organized as you go**: a small panel after each call asks for a title, folder, tags and notes.
- **Yours to use**: search everything, export (Markdown, text, JSON, SRT, VTT), copy a call into
  an AI prompt, or let agents read the library through the `kan` CLI or MCP.

## Requirements

- A Mac with Apple Silicon (M1 or later) running macOS 15 Sequoia or later.
- 8 GB of memory works; 16 GB or more is comfortable while transcribing.
- About 4 GB of disk for the recommended models, plus room for kept audio (a few tens of MB per
  hour of calls).
- To build: the Xcode Command Line Tools (`xcode-select --install`; Xcode itself isn't needed),
  `git`, and CMake (`brew install cmake`).

## Install from source

```sh
git clone <this repository> Kan && cd Kan
make bootstrap   # builds whisper.cpp (about 20 s)
make signing     # once per Mac: a local code-signing identity
make app         # builds and signs build/Kan.app
make models      # downloads the recommended models (3.5 GB, resumable)
make install     # copies it to /Applications and starts Kan
```

Get the models before the first `make install`: Kan starts listening for calls as soon as it runs.
(Kan's welcome guide and Settings › Transcription can download them too, and a call recorded
without them is transcribed later; see [Models](#models).)

`make signing` matters: macOS remembers Kan's permissions by its signature. With the local identity
the signature stays the same on every rebuild, so you grant Microphone and System Audio Recording
once. Without it, `make app` falls back to an ad-hoc signature (with a loud warning) and macOS asks
again after every build. The identity lives in `~/Library/Application Support/Kan/Signing`; back
that folder up.

- **Update:** `git pull && make app install`. Kan quits gracefully (finishing any recording), is
  replaced, and restarts. Your permissions carry over.
- **CLI:** `make install CLI=1` also links `~/.local/bin/kan`.
- **No admin rights?** If `/Applications` isn't writable, Kan goes to `~/Applications`.

## First run

Kan lives in the menu bar (the ear). It needs two permissions and can use three optional ones:

| Permission | Why | When it's asked |
|---|---|---|
| **Microphone** | Records your voice. | During setup or at the first recording. |
| **System Audio Recording** | Records the call app's sound, which is the other side of the call. In System Settings it's under Privacy & Security › Screen & System Audio Recording › *System Audio Recording Only*. | During setup or at the first recording. If you turn it on in System Settings instead, macOS applies it only after Kan restarts; until then Kan's Settings, welcome guide and menu show *Allowed — relaunch Kan to apply*, with a **Relaunch** button. |
| **Documents folder** | Kan saves transcripts in its library, `~/Documents/Kan` unless you choose another folder. | When Kan first starts, before the welcome guide. Click Allow. If you didn't, the menu says *Kan can't open its library folder* and calls can't be saved: allow Kan under Privacy & Security › Files & Folders, or choose a library folder outside Documents. |
| Accessibility *(optional)* | Reads browser window titles to name Meet, Teams or Zoom-web calls. This is the only way for Zen and Firefox, which have no tab scripting. | Only if you enable it in Kan. |
| Automation *(optional)* | Asks Chrome, Brave, Edge, Arc or Safari for the meeting tab's address and title. Kan never opens a browser that isn't running. | Once per browser. |
| Calendar *(optional, off by default)* | Suggests the meeting's title and attendees. | Only if you enable it in Kan. |

Detection itself needs no permission. Without Accessibility or Automation, browser calls are still
recorded; they're just named "Browser call" until you label them.

While Kan records, macOS shows its microphone indicator and the purple system-audio indicator.
That's expected.

**Launch at login**: turn it on in Kan's Settings. It registers the installed copy, so install
first. It starts Kan when you log in, not after a crash (see
[Known limitations](#known-limitations)).

## Models

Transcription runs locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) on the GPU.
Models are stored in `~/Library/Application Support/Kan/Models`.

| Model | Size | What it does |
|---|---:|---|
| Silero VAD (`silero-v6.2.0`) | 0.9 MB | Finds the speech, so silence isn't transcribed. |
| Whisper large-v3, 5-bit (`large-v3-q5_0`) | 1.1 GB | Tells Bangla from English for each piece of speech; also transcribes both. About 2 GB of memory. |
| Whisper large-v3-turbo (`large-v3-turbo`) | 1.6 GB | Fast, accurate English. |
| Bengali.AI Whisper-medium, 8-bit (`bengali-medium-q8_0`) | 0.8 GB | Bangla. Fine-tuned on Bangla with a Bangla tokenizer: much better spelling, and it doesn't drop text in long Bangla passages the way stock Whisper does. |
| Whisper large-v3 (`large-v3`, optional) | 3.1 GB | Full precision. Same quality as the 5-bit model with twice the memory. |
| Speaker models (FluidAudio) | ~130 MB | Who said what. Kan downloads these itself the first time it needs them. |

```sh
make models                              # recommended: the first four above, 3.5 GB
make models MODELS=--minimal             # VAD + large-v3 5-bit only (1.1 GB); Bangla is weaker
make models MODELS=--all                 # everything, 6.6 GB
make models MODELS="--only large-v3-turbo"
scripts/download-models.sh --list        # what's installed
```

Downloads resume where they stopped; just run the command again. Every file is checked against
its expected size and SHA-256. In Settings, "auto" picks the best installed model for each job.

Transcription starts after the call ends and runs in the background, paused while you're on
another call. Expect roughly half to one times the call's length for Bangla-heavy calls and much
less for English. English words inside a Bangla sentence may be written in Bangla script
(মডেল for "model"); search and AI agents handle that fine.

- **No models yet?** A call recorded before its models are installed is kept, marked failed with
  a note, and transcribed automatically as soon as the missing model is installed (a download in
  Kan), or at the next launch; **Retry** on the call works too.
- **Out of memory?** The call fails with a note to close other apps or choose a smaller model.
  Its audio is kept, so **Retry** works.

## How detection works

Kan watches which apps are using the microphone (macOS's list of audio clients):

- **Start**: a call app holds the microphone for about 3 seconds. Apps that also record messages
  (Telegram, WhatsApp and the other messaging apps, and Slack, Teams and Element) must also be
  playing sound, so recording a voice note or a clip doesn't count.
- **Browsers**: Meet, Teams, Zoom and other web calls are detected in any browser, Zen and Firefox
  included, by the browser's microphone use. Window titles or tab addresses only add the meeting's
  name. A browser Kan doesn't list counts too, if it opens web links and HTML files.
- **Your microphone**: Kan records the one the call app uses, and follows it when you switch
  (AirPods connecting, another microphone picked in the app).
- **End**: the app lets go of the microphone. Kan waits 15 seconds (30 for browsers) in case it
  comes back, then saves the call. Quitting the app ends it at once, and so does sleeping the Mac:
  if the call is still going after the Mac wakes, Kan records it as a new call. After 15 minutes
  of silence on both sides Kan asks "Still in a call?".
- **Stopped or declined**: after **Stop & Save**, **Don't record**, **Discard recording…** or
  **Not now**, Kan leaves that app alone until its call is over, that is until the app has let go
  of the microphone for 15 seconds (30 in a browser) or quit. Switching microphones mid-call
  doesn't start a new recording.
- **Too short**: automatically detected recordings under 20 seconds are discarded.

Every app has a policy, which you can change in Settings:

| Policy | Meaning | Default for |
|---|---|---|
| **Auto** | Record right away; a notice lets you undo. | Meeting and messaging apps, browsers |
| **Ask** | Start capturing quietly and ask whether to keep it. | Apps Kan doesn't know |
| **Never** | Ignore the app. | Dictation tools, recorders, AI assistants (ChatGPT, Codex, Claude), other meeting recorders |

From the menu you can also start a recording yourself (one app, all system audio, or microphone
only for in-person conversations), pause or stop it, add a bookmark, and pause detection for a while.
Three shortcuts work anywhere (Settings › General can turn them off): ⌃⌥⌘R starts recording all
system audio + mic or stops the current recording, ⌃⌥⌘B bookmarks the last 30 seconds, and ⌃⌥⌘L
opens the library.

## After the call: the label panel

When a call is saved, a small panel asks for:

- **Title**: suggested from your calendar, the meeting's name or the app.
- **Folder**: for example `Research/Thesis` (use `/` for nested folders). Leave it empty for the Inbox.
- **Tags**, **notes** and a **star** for calls worth keeping.
- **Language**: Auto (বাংলা + English), বাংলা or English. Changing it re-runs the transcription.

**Later** (Esc) files the call in the Inbox as unlabeled; **Discard** deletes the call and its audio
after you confirm with a click (it has no keyboard shortcut). The transcript keeps processing in the
meantime. Once it's ready the panel lists the speakers, so you can name them ("Speaker 1" → a name)
and, if you opted in, have Kan remember a voice for next time. A name Kan recognized from a
remembered voice stays a guess until you type a name or press **Confirm**; only then does saving add
the call's voice sample. Saving writes only what you changed in the panel, so edits you made to the
call in the library meanwhile are kept. In the library window you can also merge two speakers and
move a line to the right speaker.

The panel takes the keyboard when it opens, so it waits while you're still on a call, for example
after **Stop & Save** in the middle of a meeting. It appears once the call app lets go of the
microphone; pick the call under **Needs labeling** in the menu to open it right away.

## The library

Transcripts live in `~/Documents/Kan`. You can choose another folder in Settings, for example
inside an Obsidian vault; Kan switches to it at its next launch and doesn't move existing calls. It
never overwrites an `index.md`, `index.jsonl` or `AGENTS.md` it didn't write, so a vault's own home
note is safe. If iCloud Drive syncs the folder (iCloud's "Desktop & Documents Folders" includes
`~/Documents/Kan`), the welcome guide and Settings › General say so and offer `~/Kan` instead.

```
~/Documents/Kan/
  AGENTS.md                                     how the library is organized, for AI agents
  index.md                                      every call, newest first
  index.jsonl                                   one JSON summary per call
  Inbox/2026-11-16 1530 Zoom call.md            the transcript, readable
  Inbox/2026-11-16 1530 Zoom call.json          everything Kan knows about the call
  Research/Thesis/2026-11-14 1000 Advisor meeting.md
  Research/Thesis/2026-11-14 1000 Advisor meeting.json
```

- The **`.json`** is the source of truth: segments with start and end times, speaker, language and
  text, plus speakers, bookmarks, notes and tags.
- The **`.md`** is generated from it: YAML front matter (`kan_id`, `title`, `date`, `duration`,
  `app`, `folder`, `tags`, `people`, `languages`, …) and then the transcript as
  `**Name** [00:12:31]` paragraphs. Edit calls in Kan, not in the `.md`, because Kan rewrites it.
  When you or an agent edit a `.json`, Kan renders a new `.md` from it, also for edits made while
  Kan wasn't running (at its next launch).
- Every call has a stable id (`kan_id`). Kan renames and moves the files when you change a title or
  folder. Files you move or rename in Finder are found again. If a call ends up in two files (a
  Finder duplicate, a sync conflict), Kan uses the newer one, and deleting the call removes both.
- Audio is kept separately in `~/Library/Application Support/Kan/Calls/<id>/` (`me.m4a`,
  `them.m4a`) for playback and re-transcription, not in the library. Settings › Storage can delete
  it 7, 30 or 90 days after the call, or right after transcription; starred calls always keep
  theirs.

## Search

The library window searches titles, notes, tags, bookmarks and transcripts:

- Words are combined with AND; `"quoted phrases"` must match exactly.
- Matching ignores case but never folds Bangla vowel signs, so জনি doesn't match জন্য.
- Narrow results by folder, tag, person, app, date or starred.
- A transcript match opens the call at that moment.

## Export and "Copy for AI"

Export any call as **Markdown**, **plain text**, **JSON**, **SRT** or **WebVTT** subtitles.

**Copy for AI** puts the transcript (with timestamps and names) into a ready-made prompt on the
clipboard: *Extract research ideas*, *Summarize*, *Help me understand* or *Transcript only*. The
built-in prompts tell the model that the call may mix Bangla and English. You can edit them or add your own in
Settings.

## AI agents

The simplest way: point your agent at `~/Documents/Kan`. It's plain files, and `AGENTS.md` explains
the layout and the JSON schema.

For structured access, Kan ships a command-line tool and an MCP server inside the app at
`/Applications/Kan.app/Contents/MacOS/kan` (`make install CLI=1` puts `kan` on your PATH).
`kan help` lists the commands. The main ones:

```sh
kan list                      # recent calls
kan search "augmentation"     # matching passages with timestamps and speakers
kan show <id>                 # one call's transcript
kan export <id> --format srt  # markdown, text, json, srt or vtt
kan mcp                       # MCP server on stdin/stdout, for agents
```

The MCP server gives agents read access to your calls: listing them, searching transcripts (with
timestamps and speakers), reading a call, and exporting it.

**Claude Code**

```sh
claude mcp add kan -- /Applications/Kan.app/Contents/MacOS/kan mcp
# add --scope user to make it available in every project
```

**Claude Desktop**: add to `~/Library/Application Support/Claude/claude_desktop_config.json`, then
restart Claude:

```json
{
  "mcpServers": {
    "kan": {
      "command": "/Applications/Kan.app/Contents/MacOS/kan",
      "args": ["mcp"]
    }
  }
}
```

**Codex**: add to `~/.codex/config.toml`:

```toml
[mcp_servers.kan]
command = "/Applications/Kan.app/Contents/MacOS/kan"
args = ["mcp"]
```

**Cursor**: use the same `mcpServers` JSON as Claude Desktop in `~/.cursor/mcp.json`.

If Kan is in `~/Applications`, use that path instead. Kan never edits an agent's configuration on
its own.

Because the library is in `~/Documents`, macOS may ask whether the agent's app (Terminal, Claude,
Cursor…) may access your Documents folder. Allow it, or move the library elsewhere in Settings.

## Privacy

- Recording, transcription, speaker separation and search all run on your Mac. Kan has no account,
  no cloud and no analytics. Its only network traffic is downloading models from Hugging Face.
- Audio stays in `~/Library/Application Support/Kan/Calls` and is deleted according to your
  retention setting. Deleting a call deletes its audio.
- Remembered voices (biometric data about other people) are opt-in (Settings › Transcription ›
  Remember voices). They're stored only in `~/Library/Application Support/Kan/voiceprints.json`,
  never in the library. Kan saves each call's speaker samples (`Calls/<id>/embeddings.json`, so you
  can name a speaker afterwards) only while that setting is on. They stay when Keep call audio is
  off, so you can still name the speakers once the audio is gone; deleting the call or its audio,
  turning Remember voices off, or **Forget All Voices** deletes them (Settings › Transcription
  counts them).
- Kan's logs (`~/Library/Logs/Kan`) never contain what was said, call titles, folder or file
  names, people's names, meeting addresses or what an agent searched for: calls appear by id.
  Debug lines are written there only if you turn them on (see **Logs** under
  [Troubleshooting](#troubleshooting)).
- If "Desktop & Documents Folders" syncs to iCloud Drive, macOS uploads `~/Documents/Kan` like any
  other document. Kan's welcome guide and Settings › General warn about it and offer `~/Kan`, a
  folder iCloud doesn't sync. Decide before your first call: what iCloud has uploaded stays there.
- Recording laws differ by place. Telling people you're recording is the decent default.

## Troubleshooting

**macOS keeps asking for permissions after each rebuild, or a permission is "on" but doesn't work.**
Kan isn't signed with the local identity. Check it:

```sh
codesign -d -r- /Applications/Kan.app   # want: … and certificate root = H"…", not cdhash H"…"
```

Run `make signing && make app install`. If the identity was ever re-created, macOS sees a new app:
reset Kan's old grants, then relaunch Kan and allow again.

```sh
tccutil reset All com.nahian.Kan
```

**The other side is missing from the transcript (only your voice).**
That's the System Audio Recording permission: without it macOS hands Kan silence instead of the
call. After 20 seconds of that silence Kan warns "Kan can't hear the other side — grant System
Audio Recording": turn Kan on under System Settings › Privacy & Security › Screen & System Audio
Recording › System Audio Recording Only, then press **Relaunch Kan** in the warning (or quit and
reopen Kan). If you have already allowed Kan there but haven't relaunched it since (macOS applies
that change only after a restart), the warning reads "Relaunch Kan to hear the other side" and
offers just **Relaunch Kan**; Settings then shows *Allowed — relaunch Kan to apply*.

**The menu says Kan can't open its library folder.**
macOS refused Kan access to it, usually because you clicked Don't Allow when Kan asked for your
Documents folder. Calls can't be saved until it can: allow Kan under System Settings › Privacy &
Security › Files & Folders (**Open Settings** in the menu goes there), or choose a library folder
outside Documents in Settings › General. The warning goes away by itself once Kan can read the
folder; a recording that couldn't be saved meanwhile is kept and saved when Kan next starts. The
`kan` CLI and MCP server report the same thing instead of an empty library when the app running
them (Terminal, Claude…) isn't allowed into Documents.

**A warning says Kan is recording all system audio, or can't capture the call app's audio.**
Kan couldn't capture the call app's own sound. It keeps trying for the rest of the call and
switches back by itself; meanwhile it records all system audio, so other sounds (music,
notifications) may be included, or, if that fails too, only your microphone. The warning stays
until you close it, even after Kan has switched back.

**Your voice appears twice, or other people's words show up as yours.**
Laptop speakers leak into the microphone. Headphones fix it; otherwise keep "Remove echo when the
call plays through speakers" on (the default) in Settings › Transcription. Kan then turns the
other side's echo down in your microphone track, and hides a line of yours only when it matches
what they were saying at that same moment, so repeating their words afterwards to agree is kept.
Hidden lines aren't deleted: the library window can show them ("Show … possible echo lines").

**A call wasn't detected, or ended too early.**
Check the app's policy and that detection isn't paused (menu). Run `make probe` during the call to
see whether the app holds the microphone (and, for messaging apps, Slack, Teams and Element, whether
it plays sound). If you stopped or declined a recording earlier in the same call, Kan waits for that
call to end first. Some apps release the microphone while you're muted, and a long mute can then
look like the end of the call; `make probe PROBE_ARGS=watch` shows live what your call app does
when you mute, unmute and leave.

**The transcript is in the wrong language or poor.**
Open the call, set its language (Auto, বাংলা or English) and choose Re-transcribe. The old transcript
stays until the new one is ready, and the names you gave speakers carry over (matched by when each
person spoke). Make sure the Bangla model is installed (`make models`), and add names and jargon to
Vocabulary in Settings. Re-transcribing needs the call's audio, so it won't work once retention has
deleted it.

**Kan isn't in the menu bar.**
Check that it isn't switched off in System Settings › Menu Bar, and remember that a full menu bar
hides items behind the camera notch, and macOS adds its own microphone indicator during calls.
Kan's icon stays narrow (the timer and progress are in the menu; Settings › General › Menu bar puts
them next to the icon), but if it still disappears, ⌘-drag it to the right, next to the clock and
Control Center, or ⌘-drag a few other icons out of the menu bar. Opening Kan again (Finder,
Spotlight, `make run`) while it runs shows the library, ⌃⌥⌘L does too, and ⌃⌥⌘R stops a recording.
`pgrep -x KanApp` tells you whether it's running; `make run` starts it.
If it crashed, nothing restarted it (see [Known limitations](#known-limitations)); when it starts,
it recovers the recording that was cut off.

**Logs.**
`~/Library/Logs/Kan/kan.log` (app) and `kan-cli.log` (CLI), each rotated at 5 MB. Live:
`log stream --predicate 'subsystem == "com.nahian.Kan"' --level debug`. Debug lines go to the
files only when you turn them on: `defaults write com.nahian.Kan KanDebugLogging -bool true`, then
relaunch Kan (`defaults delete com.nahian.Kan KanDebugLogging` turns it off again), or run a single
command with `KAN_DEBUG=1`. Debug builds (`make app CONFIG=debug`) always write them.

**Uninstall.**
Turn off Launch at login in Kan's Settings, quit Kan, delete `/Applications/Kan.app`, and run
`tccutil reset All com.nahian.Kan`. Your transcripts stay in `~/Documents/Kan`. Models, settings,
audio and the signing identity are in `~/Library/Application Support/Kan`; logs are in
`~/Library/Logs/Kan`.

## Known limitations

- **Nothing restarts Kan after a crash.** Launch at login starts it only when you log in, so calls
  aren't recorded until you open Kan again. The next launch recovers the recording that was cut off.
- **Muting can look like hanging up** in apps that release the microphone while you're muted; see
  [Troubleshooting](#troubleshooting).
- **The signing keychain's password is stored in a file** next to it, readable only by you, so
  builds run unattended (see **Signing** under [Development](#development)).

## Development

| Target | Kind | What it contains |
|---|---|---|
| `KanCore` | library | Shared contracts (models, settings, paths, protocols, app catalog), library store, search, rendering, processing queue, voiceprints, logging |
| `KanAudio` | library | Core Audio process taps, microphone capture, WAV writing, recorder, permissions, echo gate, m4a archiving |
| `KanDetect` | library | Audio-client monitor, owner mapping, call state machine, browser meeting names |
| `KanTranscribe` | library | whisper.cpp engine, VAD, Bangla/English routing, FluidAudio diarization, model store, pipeline |
| `KanAgent` | library | MCP server and CLI commands |
| `CWhisper` | C module | whisper.cpp v1.9.5 headers; links `Vendor/whisper/lib/*.a` |
| `KanApp` | app | SwiftUI menu-bar app (bundled as `Kan.app`, executable `KanApp`) |
| `kan` | tool | CLI and `kan mcp` |
| `kan-probe` | tool | Read-only diagnostics: audio clients, owners, permissions, live watch |
| `kan-selftest-*` | tools | Per-module tests on `KanTestKit` |

`docs/ARCHITECTURE.md` describes the design.

```sh
make test                                        # build and run every kan-selftest-* suite
make test SUITES="core agent" TEST_ARGS="--filter Library"
make probe                                       # kan-probe clients
make probe PROBE_ARGS=watch                      # watch call apps live (mute, unmute, leave)
make app CONFIG=debug                            # debug build of Kan.app
make clean                                       # swift package clean + build/
```

- **Build one product at a time**: `swift build --product <name>`. A plain `swift build` also
  builds FluidAudio's own CLI, which doesn't compile with only the Diarizer trait enabled.
- **Tests** are plain executables on `Sources/KanTestKit` (XCTest doesn't run with the Command
  Line Tools alone). `scripts/test.sh` runs each suite with its own temporary `KAN_HOME`, and
  reports skips (for example a missing model) separately from failures.
- **Sandboxing your experiments**: `KAN_HOME=/tmp/kan-play` points the app support folder, library
  and logs at one directory; `KAN_MODELS` does the same for models.
- **Start the app through LaunchServices** (`make run`, `open build/Kan.app`), not by running the
  binary directly: the bare binary has no Info.plist, and macOS would attribute its permissions to
  your terminal.
- **Run the installed `kan`** (`~/.local/bin/kan` after `make install CLI=1`, or
  `/Applications/Kan.app/Contents/MacOS/kan`), not `build/Kan.app/Contents/MacOS/kan`: running a
  copy's CLI registers that copy with LaunchServices, and `open -b com.nahian.Kan`, Relaunch or the
  login item could then start it. `make install` unregisters every copy but the installed one.
  To see which copies LaunchServices knows:

  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
    | grep -E '^path:.*/Kan\.app'
  ```
- **kan-probe** is read-only and needs no permissions. During a real call,
  `make probe PROBE_ARGS=watch` shows which processes hold the microphone and speakers, which is how
  you check whether a call app keeps its microphone open while muted.
- **Signing**: `scripts/setup-signing.sh --status` shows the identity. It lives in its own keychain
  in `~/Library/Application Support/Kan/Signing` and never touches your login keychain or keychain
  list. Its password is stored next to it, readable only by you, so builds run unattended. Like any
  code-signing identity on your Mac, it's only as safe as your user account: a program running as
  you could use it to sign code that macOS treats as Kan. `SIGN_MODE=adhoc|none` are available too.
- **Hardened runtime** (the default): Kan.app is signed with `--options runtime` and
  `Resources/Kan.entitlements` (microphone, Apple Events, calendars), so other programs can't
  inject code into Kan (`DYLD_INSERT_LIBRARIES`) to use its Microphone, System Audio Recording,
  Accessibility and Automation permissions. Never add `allow-dyld-environment-variables` or
  `disable-library-validation` there; `scripts/build-app.sh` refuses them. `make app HARDENED=0`
  signs without it, for troubleshooting only. The designated requirement is the same either way,
  so switching keeps your permissions.
- **whisper.cpp** is pinned to v1.9.5 and built as static libraries with Metal (shaders compiled
  at runtime, so no Xcode), Accelerate and no OpenMP. `scripts/bootstrap-whisper.sh --check`
  tells you whether `Vendor/whisper/lib` is current; add `--force` to rebuild.
- **App icon**: `make icon` re-renders `Resources/AppIcon.icns` from `scripts/make-icon.swift`;
  commit the result.
