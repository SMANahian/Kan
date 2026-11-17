# Kan — architecture

Kan (কান, Bangla for "ear") is a macOS menu-bar app that notices when you're on a call, records
both sides locally, and afterwards transcribes the call — Bangla and English, code-switched — with
"who said what". Right after the call it asks you to label it (title, folder, tags, notes), and
everything is stored as plain Markdown + JSON that you and your AI agents can read, search and
export. Kan uploads nothing; its only network use is downloading models.

## Requirements (from the user)

1. Always running, in the menu bar, launches at login.
2. Detects calls automatically — Zoom and Google Meet first (Meet runs in **any** browser: Zen,
   Chrome, Safari, Firefox, Brave, Arc, Edge…), Telegram, and other call apps.
3. Local transcription for Bangla and English (often mixed in one call).
4. Speaker attribution ("who said what").
5. After a call ends, prompt to label it so the library stays organized.
6. Read and search transcripts later (mostly research ideas); export / hand them to AI agents.

Requirement 1 is met by launch at login only; nothing restarts Kan after a crash (see
[Known limitations](#known-limitations)).

## Module map

| Target | Kind | Owns |
|---|---|---|
| `CWhisper` | C module | whisper.cpp v1.9.5 headers; links `Vendor/whisper/lib/*.a` (Metal + Accelerate) |
| `KanCore` | library | Contracts (models, settings, paths, protocols, app catalog), `LibraryStore`, search, `TranscriptRenderer`, `ProcessingQueue`, `VoiceprintStore`, logging |
| `KanAudio` | library | Core Audio process taps, mic capture (HAL IOProc), 16 kHz WAV writing + anchors, `CallRecorder`, permissions, echo gate, `AudioArchiver` (m4a), WAV/m4a reading |
| `KanDetect` | library | Core Audio client monitor + owner mapping, `CallStateMachine`, `CallDetector`, browser meeting probe (AppleScript + Accessibility titles) |
| `KanTranscribe` | library | whisper.cpp engine, Silero VAD, chunk planner, {bn,en} language routing, decoding, post-processing, FluidAudio diarization, transcript assembly, `ModelStore`, `TranscriptionPipeline` |
| `KanAgent` | library | MCP server logic (JSON-RPC over stdio), CLI command implementations |
| `KanApp` | executable | SwiftUI menu-bar app (bundled as `Kan.app`, executable `KanApp`) |
| `kan` | executable | CLI + `kan mcp` for AI agents |
| `kan-probe` | executable | read-only diagnostics (audio clients, owners, permissions, `--watch`) |
| `kan-selftest-*` | executables | per-module tests on `KanTestKit` (XCTest doesn't run with CLT only) |

Dependencies point downward only: `KanApp → {KanAudio, KanDetect, KanTranscribe} → KanCore`.
UI code talks to services only through the protocols in `KanCore/Contracts`
(`CallDetecting`, `CallRecording`, `Transcribing`, `ModelManaging`, `PermissionsProviding`,
`AudioArchiving`), wired in `Sources/KanApp/Services/LiveServices.swift`.

## End-to-end flow

```
Core Audio process list ──► CallDetector (KanDetect)
   (which app holds the mic,     │  .started / .ask / .ending / .resumed / .ended / .stale
    helpers → parent app)        ▼
                          AppModel (KanApp) ──► CallRecorder (KanAudio)
                                 │                 me.wav  (mic, HAL IOProc)
                                 │                 them.wav (call app's process tap, mono mixdown)
                                 │                 anchors.json (host-time ↔ frame)
                                 ▼
             call ends ─► CallRecord saved to Inbox (status .queued) ─► Label panel
                                 │
                                 ▼
                     ProcessingQueue (KanCore) ─► TranscriptionPipeline (KanTranscribe)
                                                    VAD → diarize "them" → LID per chunk
                                                    → en chunks: Whisper turbo / large-v3
                                                    → bn chunks: Bengali Whisper-medium
                                                    → post-process → assemble speakers
                                 ▼
                     LibraryStore writes  <Library>/<Folder>/<date title>.{json,md}
                                 ▼
                 Library window · `kan` CLI · `kan mcp` · any agent reading the files
```

### Detection rules (KanDetect)

* Snapshot Core Audio clients (`kAudioHardwarePropertyProcessObjectList`), read PID, bundle id,
  `IsRunningInput/Output`, devices. Map each client to its **owning app**:
  `responsibility_get_pid_responsible_for_pid` → outermost `.app` in `proc_pidpath` → bundle id.
  Special cases: `com.apple.WebKit.GPU` → its responsible app (Safari…), `avconferenced` → FaceTime.
  Exclude Kan's own PID and `AppCatalog.systemNoiseBundleIDs`. A cataloged app (exact bundle id)
  goes by its catalog name — Zoom calls itself "zoom.us" — in the menu, notices and saved calls.
* Triggers: process-list / `pir?` / `pdv#` property listeners (C API — Swift block listeners can't
  be removed) plus a 1 s poll (per-process IsRunningInput listeners don't fire on macOS 26), and the
  NSWorkspace will-sleep, did-wake and did-terminate-application notifications.
* Category (`AppCatalog.category(bundleID:appURL:)`): the catalog (exact or helper-prefix match),
  then system noise → ignored, then `looksLikeWebBrowser` → browser, else unknown. A browser must
  declare http/https URL schemes **and** an HTML document type (what a default-browser candidate
  declares); URL schemes alone aren't enough, as assistants and utilities claim them too (TeX Live
  Utility; the ChatGPT/Codex app `com.openai.codex`, which the catalog lists as ignored).
* Start: an app holds the mic ≥ `startConfirmSeconds` (3 s); `DetectedCall.startedAt` is when it
  took the mic. With `messagingRequiresOutput` (on), apps whose mic use may be a recorded message
  must also be playing output: `KnownApp.requiresOutput` — messaging apps by default, plus Slack,
  Teams and Element (clips, voice messages). A call's playout stream runs all along; recording a
  message plays nothing. Policy per app (`DetectionConfig.policy`): the user's override, else
  meeting / messaging → auto, browser → `browserPolicy` (auto), ignored → never, unknown →
  `unknownAppPolicy` (ask).
* One call at a time; a call that is already ending gives way to an `.auto` app that now holds the
  mic (back-to-back calls).
* End: mic released (debounced 1 s, `releaseDebounceSeconds`) → `.ending(deadline)` (release +
  15 s native, 30 s browsers) → `.ended(endedAt: release time)`. Re-acquired before the deadline →
  `.resumed`. App gone from the client list (quit / crash) → end now; a running app that briefly
  has no clients (helper or coreaudiod restart) counts as a release. Manual sessions never end on
  their own. `staleSilenceMinutes` (15) without audio on both tracks → `.stale` ("Still in a call?").
* Ignored apps: `.notNow` / `.never` (the Ask prompt; "Don't record" and "Discard recording…" send
  `.notNow`), `.endNow` (Stop & Save, Save now, disk full), `endManualSession`, and holding the mic
  while detection is off or paused → the app is ignored for the rest of that call: until it has kept
  the mic released for its end grace (15 s / 30 s; no clients counts as released) or quit
  (`appTerminated`). Ignored apps accumulate no mic time, so a later call needs a fresh
  confirmation. A device switch mid-call (an input gap of 1–3 s) therefore can't re-record a call
  the user stopped or declined.
* Sleep: `systemWillSleep` ends detected calls (at the release time if already ending); nothing
  starts and no mic time is counted until `systemDidWake` (at most `sleepHoldSeconds`, 30 s, in case
  the Mac didn't sleep after all). An app still holding the mic after the wake starts a new call
  after a fresh 3 s confirmation; nothing is ignored.
* `.activityChanged` when the session app's process objects or its input / output device UIDs
  change (never for the detector's empty stand-in of a running app without clients) → the app calls
  `RecordingHandle.retarget`: the tap and the "me" microphone follow the app.
* Recordings shorter than `minCallSeconds` (20 s) are discarded silently (auto-detected only; a call
  the user stopped is kept).
* Browser meeting naming: AppleScript tab URL/title for Chrome-family + Safari (Automation
  permission, never launches a browser), Accessibility window titles for **any** browser
  (Zen/Firefox have no tab scripting). Best effort; never required for detection. `.meetingInfo`
  is logged as the platform and whether a title / URL was found, never their values.

### Recording (KanAudio)

* "them": `CATapDescription(monoMixdownOfProcesses:)` over all process objects of the call app,
  `muteBehavior = .unmuted`, private; on macOS 26 also `bundleIDs` + `isProcessRestoreEnabled`.
  Tap-only private aggregate device (no sub-devices). IOProc with nil queue = real-time thread:
  memcpy into a preallocated ring only; conversion/writing on a worker queue.
* "me": HAL IOProc on the input the call app uses now (its input devices from the latest activity,
  then the start-time request's device; virtual devices like ZoomAudioDevice skipped), else the
  default input. On `retarget`, a different physical input in the app moves "me" (debounced,
  rate-limited restart, `.deviceChanged`); while the app's input is unknown (released, or only a
  virtual device) the current mic stays. A default-input change moves "me" only when it was
  following the default. Never AVAudioEngine voice processing (ducks the call, breaks taps).
* Both tracks → 16 kHz mono PCM16 WAV (crash-safe header updates), aligned through host-time
  anchors; gaps are filled with silence so both files share one clock starting at call start.
* Recovery never gives up while recording (`RecordingSession`, *Tap*):
  * a fault (format change, device died, IO stopped, no IOProc callbacks for 2 s, coreaudiod
    restart) → full teardown now, a new tap after `rebuildDebounceSeconds` (0.25 s);
  * a start that fails → quick retries (0.5 s, 2 s), then the next fallback: the call app's tap →
    all system audio (minus Kan) → no call audio;
  * all system audio standing in for the call app raises `RecordingIssue.systemAudioFallback`
    (other apps' sounds may be included); the app's tap is tried again every `tapRecoverySeconds`
    (10 s) and whenever its processes change, and the system tap keeps recording until the app's
    tap runs;
  * no tap at all raises `.tapFailed` (only the mic for now) and starts a new round, app tap
    first, every 10 s;
  * every tap creation after the first draws from a token bucket (`RebuildLimiter`): a burst of 5,
    then one every 12 s (`maxRebuildsPerMinute` = 5). A used-up budget delays the next attempt; it
    never ends recovery. A restarted tap raises `.tapRebuilt`;
  * the mic restarts on its own budget of the same size; no usable mic → `.micUnavailable`,
    retried every 5 s;
  * each issue is raised once per recording and never retracted: a `.tapFailed` stays listed (and
    its notice shown) after the tap recovers.
* System Audio Recording fails silently: without an effective grant the tap delivers exact zeros.
  A grant made in System Settings while Kan runs takes effect only after a relaunch, although TCC
  already reports it granted. `Permissions.systemAudioAccess()` tells the states apart:
  `.grantedPendingRelaunch` when TCC says granted but this process saw it denied (macOS never
  prompts again after a denial, so the grant came from System Settings); a grant from Kan's own
  prompt applies at once. After `systemAudioSilentSeconds` (20 s) of exact zeros from the tap (a
  pause resets the run): an effective grant means real silence (logged, checked again after every
  further 20 s); otherwise `RecordingIssue.systemAudioSilent` (notice with Open Settings and
  Relaunch Kan). `PermissionsProviding.needsRelaunch(.systemAudio)` exposes the pending state to
  the UI ("Allowed — relaunch Kan to apply").
* Loudspeaker check (output device is built-in speakers / HDMI / AirPlay) → echo handling later.
* Stop: `stop(trimEndAt:)` drops the audio after the trim instant: the mic release + 2 s
  (`AppModel.endTrimSeconds`) for a detected end and for any stop during the end countdown. The
  trim instant is wall-clock time but the tracks run on host time, which stops during sleep, so the
  kept length is the later of "back from the stop" and "forward from the start": a stop requested
  at sleep that only runs after the wake can't cut the call to nothing.
* `start` refuses with less than 50 MB free; a full disk raises `.diskFull`, and the app stops and
  saves what it has.

### Transcription (KanTranscribe)

Learned in the spikes (TTS audio; re-check on real calls):

* Whisper decodes at most ~220 tokens per window; Bangla costs ~22 tokens/s with the stock
  tokenizer → stock models must get Bangla chunks ≤ 8 s or text is silently lost. The Bengali.AI
  Whisper-medium fine-tune has a Bangla tokenizer → chunks ≤ 15 s. English chunks ≤ 25 s.
* `whisper_full` detects language once per call → never decode a whole call with "auto".
  Do language ID per chunk, restricted to {bn, en} (large-v3 is reliable; turbo mislabels Bangla
  as Hindi, so with turbo compare bn+other Indic mass against en).
* Beam search 5 + best_of 5 (greedy is catastrophic for Bangla), suppress_nst, no_context,
  language always explicit (default is "en"!), entropy threshold tuned per model.
* Detect truncation (n_tokens ≥ n_text_ctx/2 − 4 or a segment ending past the chunk) → split
  at the lowest-VAD-probability frame and retry.
* Post-processing: NFC, '.'→'।' after Bengali text, collapse n-grams repeated ≥ 3×, drop
  near-silent "thank you for watching"-style hallucinations, drop high no-speech/low-logprob.
* Diarization only on "them" (mic = me). FluidAudio 0.18.3: Sortformer turns → WeSpeaker
  `embedSpans` on ≤ 4 s units → global cosine AHC (cut 0.55) → small clusters merged; VBx
  `OfflineDiarizerManager` (warmStartFa 0.3) as fallback / for very long calls.

Current rules:

* Language smoothing (`LanguageRouter.decide`, Auto mode): a unit shorter than 2 s, with
  |ln p(bn) − ln p(en)| < 1, or with bn + en mass < 0.1 inherits the language of the nearest
  confident unit of the **same diarized speaker** first. A speaker without a confident unit keeps a
  clear short measurement of their own, else takes anyone's nearest confident unit, else keeps its
  own guess. Language ID is skipped on a short unit only when its speaker is already settled
  (`settledSpeakers`). The mic track (one voice) and calls without diarization have no speakers
  to tell apart, so the nearest confident unit decides.
* Echo (Settings › "Remove echo when the call plays through speakers" = `echoSuppression`; off
  skips everything): the envelope gate (`EchoGate`) runs on every two-track call and changes the
  mic only when it measures a speaker → mic delay (≤ 400 ms); it then mutes echo runs ≥ 0.3 s and
  turns isolated echo frames down (× 0.1) before VAD. The transcript dedup (`EchoDedup`) runs only
  when the recorder suspected a loudspeaker or the gate measured a delay. It flags (never deletes)
  a mic segment of ≥ 8 character trigrams when ≥ 80 % of its time lies in remote speech delayed by
  that lag (unmeasured: 0–1 s), ±0.5 s, and ≥ 50 % of its trigrams were said by the remote side in
  that window (by word time). Replies that repeat the other side's words follow their turn rather
  than coincide with it, so they aren't flagged. `echoSuspect` segments stay in the JSON and are
  left out of the `.md`, search, talk time and the Library window's default view.
* Out of memory: `whisper_full_with_state` returns −7 after it has freed the decoder state (the KV
  cache couldn't be allocated). The engine drops its state at once (no double free), the job fails
  with "not enough memory to decode with … — close other apps or choose a smaller model", the audio
  is kept for a retry, and `EngineHost` loads that model again for the next job.
* Warm-up: `Transcribing.warmUp(settings:)` loads and frees the Whisper models the settings resolve
  to and, with `diarize`, the speaker models, so Metal / CoreML compilation (~6 s / ~16 s, paid again
  after every update) doesn't land on the first call. The app runs it while idle, once per build
  and model (`WarmUpRecord` in UserDefaults), and again after a model download.

Default models (in `~/Library/Application Support/Kan/Models`):

| id | file | role |
|---|---|---|
| `large-v3` / `large-v3-q5_0` | ggml-large-v3(.q5_0).bin | general: language ID, fallback Bangla |
| `large-v3-turbo` | ggml-large-v3-turbo.bin | English |
| `bengali-medium-q8_0` | ggml-bengali-whisper-medium-q8_0.bin (Bengali.AI tugstugi) | Bangla |
| `silero-v6.2.0` | ggml-silero-v6.2.0.bin | VAD |
| FluidAudio | Models/FluidAudio/… | diarization |

### Storage

```
~/Documents/Kan/                     (library, configurable; agents read this)
  AGENTS.md  index.md  index.jsonl
  Inbox/2026-11-16 1530 Zoom call.{md,json}
  Research/Thesis/2026-11-14 1000 Advisor meeting.{md,json}
~/Library/Application Support/Kan/
  settings.json  voiceprints.json  queue.json
  Models/                            whisper ggml + FluidAudio CoreML models
  Calls/<CallID>/                    live.json (until saved) me.wav them.wav anchors.json session.json
                                     → me.m4a them.m4a; embeddings.json (only with Remember voices)
  Signing/                           the local code-signing keychain and its password file
~/Library/Logs/Kan/kan.log  kan-cli.log
```

The `.json` (a `CallRecord`) is the source of truth; the `.md` is regenerated from it.
`KAN_HOME=/some/dir` redirects app support, library and logs (tests, experiments).

Library (`LibraryStore`):

* Call ids are ULIDs: 26 Crockford base32 characters, accepted in any case and stored uppercase.
  A JSON with any other id (`""`, `..`, `../victim`) fails to decode and is skipped as a corrupt
  call record; save, delete and the queue refuse malformed ids, and a delete removes `Calls/<id>`
  only when the resolved directory's last component is the id.
* Files moved or renamed in Finder: before reporting a call gone, the store rescans once, so an
  update (the queue's transcript) follows the move; a delete never removes a file that now holds
  another call.
* Two files with one id (Finder duplicate, sync conflict, a copy in another folder): the newer
  `updatedAt` wins, then the file named and placed as Kan saved it. Deleting the call removes
  every copy; a save removes older Kan-named copies next to it (an interrupted rename). The user's
  own copies elsewhere stay until the call is deleted.
* `reconcile()` (at launch instead of `reload()`, when the library window opens and after
  FSEvents) re-renders the `.md` of JSON edited outside Kan, also while Kan wasn't running: it
  remembers the JSON stamp each `.md` was rendered from, and for calls it hasn't rendered yet a
  `.md` older than its JSON is stale (Kan writes the JSON first).
* A root that exists but can't be looked at or listed (EPERM / EACCES: macOS's privacy protection
  of Documents, Desktop and Downloads, or file permissions) makes `reload()` throw instead of
  reporting an empty library (`isRootAccessDenied`); a missing root is an empty library. The app
  shows "Kan can't open its library folder" (Files & Folders) until a later check succeeds; the CLI
  and MCP server report the error.
* iCloud Drive: `KanPaths.isInICloudDrive` (the folder, or the nearest existing one above it, is
  ubiquitous) — Desktop & Documents in iCloud puts the default `~/Documents/Kan` there. The app's
  welcome guide and Settings › General then offer `~/Kan` (`KanPaths.userHome`); the default
  itself doesn't change.
* `recordedApps()` gives each recorded app's bundle id and newest name from the index (no record is
  read), for Settings › Detection.
* `index.md`, `index.jsonl` and `AGENTS.md` are (re)written only when missing or written by Kan
  (the `<!-- kan-index … -->` marker or the old `# Kan call library` heading; a Kan summary as the
  first JSONL line; the AGENTS.md version marker), so a vault's own `index.md` is never overwritten.

Settings (`SettingsStore`): decoded field by field and entry by entry. An unreadable or unknown app
policy becomes Ask (never a laxer default), unreadable prompt templates are dropped (the defaults
only when none is readable), and the next save first copies the original to
`settings.backup-<unix time>.json`. A file that can't be decoded at all is moved aside
(`settings.corrupt-<unix time>.json`) and the defaults are used.

Processing (`ProcessingQueue`, persisted in `queue.json`):

* The audio is located when a job runs (the WAV or, after archiving, the m4a); a recorded track
  that is gone fails the job rather than replace the transcript with one side of the call. A job
  restored after a quit whose transcript was already saved only finishes the audio step.
* Re-transcription keeps user-given speaker names by voice, not by id (ids are renumbered every
  run): a new speaker inherits a name when ≥ 50 % of its speech overlaps the old speaker's and the
  pair is ≥ 2× any rival on both sides; a looser match only suggests the name.
* `embeddings.json` (per-speaker voice samples, biometric data) is written only while
  `rememberVoices` is on and removed by a transcription without it; `VoiceprintStore.forgetAll()`
  deletes every call's file too, and so do Delete Audio and audio retention for that call. The
  queue's own audio deletion (Keep call audio off) keeps it, so the speakers can still be named
  after the audio is gone; Settings counts such calls and enables Forget All Voices for them.
* Starred calls keep their audio even with Keep call audio off (the audio step re-reads the record;
  when unsure it keeps the audio).
* A job that failed with `TranscriptionError.modelMissing` is kept in `waitingForModels` and runs
  again as soon as the installed models change (the app calls `retryWaitingForModels()` after a
  download) or at the next launch; Retry also works.

## Conventions

* Swift 5 language mode for our targets; macOS 15+; Apple Silicon only.
* No `fatalError`/force-unwraps on runtime paths (contract stubs excepted until implemented).
* Log through `KanLog` (never from real-time audio threads). Every user-visible failure is also logged.
  The log outlives deleted calls, so never interpolate call content (transcript text, titles,
  folder and file names — a call's file name is its title —, people's names, meeting URLs, search
  queries, an agent's arguments): log ids, counts and app names. Errors go through
  `KanLog.describe`, which logs library and Cocoa file errors by kind and code (their messages
  quote titles and paths); MCP tool errors are logged by `ToolError.Kind`. Unified-log messages are
  `.public`. Debug lines reach `kan.log` only in debug builds, with `KAN_DEBUG=1`, or with
  `defaults write com.nahian.Kan KanDebugLogging -bool true`.
* App Nap: Kan has no window open while it records or transcribes, so it holds a
  `.userInitiated` activity from the start of a recording until it is saved and while a
  transcription runs (`AppModel.updateActivities`); the recorder's 50 ms pump and the detector's
  deadlines would otherwise be coalesced. While detection is on (not paused, not off in
  Settings) it also holds a `.userInitiatedAllowingIdleSystemSleep` activity, so the detector's
  1 s tick, which confirms a call's start, isn't napped either; idle sleep stays allowed.
* All text stored NFC (`String.nfc`). Never diacritic-fold Bangla when searching.
* Thread-safety: library/services are `@unchecked Sendable` with internal locks or actors; UI state
  is `@MainActor`.
* Build one product at a time with your own scratch path to avoid lock contention:
  `swift build --product <name> --scratch-path /tmp/kan-build-<you>`. Never plain `swift build`.

## Build, install, test

```
make bootstrap   # build whisper.cpp static libs (only needed once / after a clean clone)
make signing     # once per Mac: the local self-signed identity (stable designated requirement)
make app         # build/Kan.app (release, hardened runtime, signed with the local identity)
make models      # the recommended models (3.5 GB); before the first install, as Kan listens at once
make install     # copy to /Applications and relaunch
make test        # run all kan-selftest-* executables
```

The hardened runtime is the default: `scripts/build-app.sh` signs with `--options runtime` and
`Resources/Kan.entitlements` (audio input, Apple Events, calendars), refuses entitlements that
grant `allow-dyld-environment-variables` or `disable-library-validation`, and checks the runtime
flag on the app and the CLI. `HARDENED=0` signs without it, for troubleshooting only; the
designated requirement is the same either way, so permissions carry over.

## Known limitations

* Launch at login is `SMAppService.mainApp`: nothing restarts Kan after a crash or kill, so calls
  go unrecorded until it is opened again. The next launch recovers the interrupted recording
  (`live.json`, or WAVs without `session.json`). A KeepAlive LaunchAgent (`SMAppService.agent`)
  would fix it, but changes how macOS launches Kan and needs testing in a real login session.
* The signing keychain's password is a file next to it (`Signing/keychain-password`, mode 600), so
  builds run unattended. The identity is only as safe as the user account.
* The waiting label panel polls `currentActivities()` every 2 s (the detector has no event for
  apps it doesn't record).
* Not yet checked on real calls: tap recovery under real faults, whether a prompt grant of System
  Audio Recording applies without a relaunch, and which call apps release the mic while muted
  (`kan-probe watch`).
