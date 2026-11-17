import AVFoundation
import Foundation
import Observation
import KanCore

/// Keys of the library window's preferences in `UserDefaults`.
enum LibraryDefaults {
    static let sidebarWidth = "library.sidebarWidth"
    static let listWidth = "library.listWidth"
    static let showInspector = "library.showInspector"
    static let followPlayback = "library.followPlayback"
    static let transcriptFontSize = "library.transcriptFontSize"
    static let playbackRate = "library.playbackRate"
    static let collapsedFolders = "library.collapsedFolders"
    static let sidebarSelection = "library.sidebarSelection"
}

/// Plays a call's two tracks — "me" (the microphone) and "them" (the call app) — together.
///
/// Both files are inserted at time zero of one `AVMutableComposition` (the recorder pads both
/// tracks with silence, so they share the call's clock) and played by an `AVPlayer`. A missing or
/// unreadable track is skipped with a note; without any audio the player is `unavailable`.
///
/// Main-actor only. While playing, `currentTime` and the registered time listeners (the transcript
/// highlight) are updated ten times a second, and after every seek.
@MainActor
@Observable
final class LibraryPlayer {
    enum State: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }

    static let rates: [Float] = [1, 1.25, 1.5, 2]

    private(set) var state: State = .idle
    /// Shown next to the controls, e.g. "Only your microphone was recorded."
    private(set) var note: String?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float
    private(set) var callID: CallID?
    /// A speaker sample is playing (it pauses by itself at its end).
    private(set) var isPlayingSample = false

    var isReady: Bool { state == .ready }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var tracks: [AudioChannel: AVMutableCompositionTrack] = [:]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var sampleObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeek: (time: Double, play: Bool)?
    @ObservationIgnored private var listeners: [UUID: @MainActor (Double) -> Void] = [:]
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var loadGeneration = 0

    init() {
        let stored = UserDefaults.standard.float(forKey: LibraryDefaults.playbackRate)
        rate = Self.rates.contains(stored) ? stored : 1
    }

    // MARK: Loading

    /// Loads a call's audio, replacing whatever was loaded. Files that are nil or missing on disk are
    /// skipped; `unavailableReason` explains a call without any audio. `resumeAt` seeks once loaded.
    func load(callID: CallID, me: URL?, them: URL?, fallbackDuration: Double, unavailableReason: String?,
              resumeAt: Double? = nil, autoplay: Bool = false) {
        unload()
        self.callID = callID
        duration = max(0, fallbackDuration)
        var files: [(AudioChannel, URL)] = []
        if let me, FileManager.default.fileExists(atPath: me.path) { files.append((.me, me)) }
        if let them, FileManager.default.fileExists(atPath: them.path) { files.append((.them, them)) }
        guard !files.isEmpty else {
            state = .unavailable(unavailableReason ?? "No audio was kept for this call.")
            return
        }
        state = .loading
        if let resumeAt { pendingSeek = (resumeAt, autoplay) }
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.build(files, generation: generation)
        }
    }

    /// Stops playback and releases the audio.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        endSample()
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
        tracks = [:]
        isPlaying = false
        currentTime = 0
        duration = 0
        note = nil
        state = .idle
        callID = nil
        pendingSeek = nil
        reachedEnd = false
    }

    private func build(_ files: [(AudioChannel, URL)], generation: Int) async {
        let composition = AVMutableComposition()
        var built: [AudioChannel: AVMutableCompositionTrack] = [:]
        var failures: [String] = []
        for (channel, url) in files {
            let asset = AVURLAsset(url: url)
            do {
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                    failures.append("\(url.lastPathComponent) has no audio track")
                    continue
                }
                let length = try await asset.load(.duration)
                guard length.isNumeric, length.seconds > 0 else {
                    failures.append("\(url.lastPathComponent) is empty")
                    continue
                }
                guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    failures.append("couldn't add \(url.lastPathComponent)")
                    continue
                }
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
                built[channel] = track
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if !failures.isEmpty {
            KanLog.error("Playback: \(failures.joined(separator: "; "))", category: "library-ui")
        }
        guard !built.isEmpty else {
            state = .unavailable("Couldn't open the audio (\(failures.joined(separator: "; "))).")
            return
        }
        install(composition, tracks: built, failed: !failures.isEmpty)
    }

    private func install(_ composition: AVMutableComposition, tracks: [AudioChannel: AVMutableCompositionTrack],
                         failed: Bool) {
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .timeDomain      // clear speech at 1.25×–2×
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.defaultRate = rate
        self.player = player
        self.item = item
        self.tracks = tracks
        let seconds = composition.duration.seconds
        if seconds.isFinite, seconds > 0 { duration = seconds }

        switch (tracks[.me] != nil, tracks[.them] != nil) {
        case (true, false):
            note = failed ? "The other side's audio couldn't be opened." : "Only your microphone was recorded."
        case (false, true):
            note = failed ? "Your microphone's audio couldn't be opened." : "Only the call's audio was recorded."
        default:
            note = nil
        }

        let interval = CMTime(value: 1, timescale: 10)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayingState() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didPlayToEnd() }
        }
        state = .ready
        if let pending = pendingSeek {
            pendingSeek = nil
            seek(to: pending.time, play: pending.play)
        }
    }

    // MARK: Controls

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard state == .ready, let player else { return }
        endSample()
        if reachedEnd || currentTime >= duration - 0.05 {
            reachedEnd = false
            jump(to: 0)
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        endSample()
        player?.pause()
        isPlaying = false
    }

    /// Seeks to `time` (seconds from the call start). `play`: true starts playing, false pauses, nil
    /// keeps the current state. Before the audio is loaded, the seek is applied once it is.
    func seek(to time: Double, play: Bool? = nil) {
        guard state == .ready, let player else {
            if state == .loading { pendingSeek = (time, play ?? false) }
            return
        }
        endSample()
        reachedEnd = false
        jump(to: time)
        if play == true {
            player.playImmediately(atRate: rate)
            isPlaying = true
        } else if play == false {
            pause()
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ newRate: Float) {
        guard Self.rates.contains(newRate) else { return }
        rate = newRate
        UserDefaults.standard.set(newRate, forKey: LibraryDefaults.playbackRate)
        player?.defaultRate = newRate
        if isPlaying && !isPlayingSample { player?.rate = newRate }
    }

    /// Plays `start…end` at normal speed and pauses there. With both tracks loaded, only `channel`
    /// is heard (a remote speaker without the user's mic, or the reverse).
    func playSample(from start: Double, to end: Double, channel: AudioChannel?) {
        guard state == .ready, let player, let item else { return }
        endSample()
        if let channel, tracks.count > 1, let solo = tracks[channel] {
            item.audioMix = mix(soloing: solo)
        }
        isPlayingSample = true
        let stop = CMTime(seconds: max(end, start + 0.5), preferredTimescale: 600)
        sampleObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: stop)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pause() }
        }
        reachedEnd = false
        jump(to: start)
        player.playImmediately(atRate: 1)
        isPlaying = true
    }

    // MARK: Time listeners

    /// `listener` gets the playback time after every tick and seek. Remove it with `removeTimeListener`.
    func addTimeListener(_ listener: @escaping @MainActor (Double) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeTimeListener(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: Internals

    private func jump(to time: Double) {
        let clamped = min(max(0, time), max(0, duration - 0.05))
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        tick(clamped)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = max(0, seconds)
        for listener in listeners.values { listener(currentTime) }
    }

    private func syncPlayingState() {
        let playing = player.map { $0.timeControlStatus != .paused } ?? false
        if playing != isPlaying { isPlaying = playing }
    }

    private func didPlayToEnd() {
        endSample()
        reachedEnd = true
        isPlaying = false
    }

    private func endSample() {
        if let sampleObserver, let player { player.removeTimeObserver(sampleObserver) }
        sampleObserver = nil
        if isPlayingSample {
            item?.audioMix = nil
            isPlayingSample = false
        }
    }

    private func mix(soloing solo: AVMutableCompositionTrack) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.values.map { track -> AVAudioMixInputParameters in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(track === solo ? 1 : 0, at: .zero)
            return parameters
        }
        return mix
    }
}
