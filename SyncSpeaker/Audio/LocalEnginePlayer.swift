import AVFoundation

/// Plays local audio files with sample-accurate start times and continuous,
/// inaudible drift correction. Also plays calibration chirps through the same
/// path, so calibration measures exactly the latency music will have.
///
///     musicNode → varispeed ─┐
///                            ├→ mainMixer → output
///     chirpNode ─────────────┘
@MainActor
final class LocalEnginePlayer: SyncPlayer {
    let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private let varispeed = AVAudioUnitVarispeed()
    private let chirpNode = AVAudioPlayerNode()
    private let chirpFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private var file: AVAudioFile?
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var drift = DriftController()
    private var lastTickNanos: Int64?
    private var lastReseekNanos: Int64 = 0
    private var configObserver: NSObjectProtocol?

    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var lastErrorMillis: Double?
    var currentRate: Double? { Double(varispeed.rate) }

    /// Called if the engine had to restart (route change) while playing.
    var onNeedsResync: (() -> Void)?

    init() {
        engine.attach(musicNode)
        engine.attach(varispeed)
        engine.attach(chirpNode)
        engine.connect(chirpNode, to: engine.mainMixerNode, format: chirpFormat)

        // Route changes (e.g. a Bluetooth speaker connecting) can stop the engine.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = false
                try? self.ensureRunning()
                if wasPlaying { self.onNeedsResync?() }
            }
        }
    }

    func ensureRunning() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    // MARK: SyncPlayer

    func prepare(_ track: TrackSource, position: Double) async throws {
        guard case let .local(id, _) = track else { throw PlayerError.wrongSource }
        guard let url = LocalLibrary.url(forID: id) else { throw PlayerError.missingFile(id) }
        pause()
        let f = try AVAudioFile(forReading: url)
        file = f
        engine.disconnectNodeOutput(musicNode)
        engine.disconnectNodeOutput(varispeed)
        engine.connect(musicNode, to: varispeed, format: f.processingFormat)
        engine.connect(varispeed, to: engine.mainMixerNode, format: f.processingFormat)
        try ensureRunning()
        isReady = true
    }

    func start(outputAtLocalNanos t: Int64, position: Double) {
        guard let file else { return }
        musicNode.stop()
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, position) * sr)
        guard startFrame < file.length else { return }

        segmentStartFrame = startFrame
        musicNode.scheduleSegment(file,
                                  startingFrame: startFrame,
                                  frameCount: AVAudioFrameCount(file.length - startFrame),
                                  at: nil)
        musicNode.prepare(withFrameCount: 8_192)
        varispeed.rate = 1
        drift.reset()
        lastTickNanos = nil

        try? ensureRunning()
        let renderAt = t - AudioRoute.totalOutputDelayNanos
        musicNode.play(at: AVAudioTime(hostTime: HostClock.hostTicks(fromNanos: renderAt)))
        isPlaying = true
    }

    func pause() {
        musicNode.stop()
        isPlaying = false
        lastErrorMillis = nil
    }

    func tick(expected: (Int64) -> Double) {
        guard isPlaying, let now = currentPosition() else { return }
        let error = now.position - expected(now.outputAtLocalNanos)
        lastErrorMillis = error * 1000

        let dt = lastTickNanos.map { (now.outputAtLocalNanos - $0).nanosToSeconds } ?? 0.5
        lastTickNanos = now.outputAtLocalNanos

        if let rate = drift.update(error: error, dt: max(dt, 0.01)) {
            varispeed.rate = Float(rate)
        } else {
            // Too far off to trim smoothly; jump back onto the timeline.
            // Rate-limited so a bad measurement can't cause a loop of skips.
            let wall = HostClock.nowNanos()
            guard wall - lastReseekNanos > 2_000_000_000 else { return }
            lastReseekNanos = wall
            realign(expected: expected)
        }
    }

    func realign(expected: (Int64) -> Double) {
        let at = HostClock.nowNanos() + 300_000_000
        start(outputAtLocalNanos: at, position: expected(at))
    }

    var canMute: Bool { true }

    func setMuted(_ muted: Bool) {
        musicNode.volume = muted ? 0 : 1
    }

    /// Track position currently being rendered, and the local time it leaves the speaker.
    func currentPosition() -> (position: Double, outputAtLocalNanos: Int64)? {
        guard let file,
              let nodeTime = musicNode.lastRenderTime, nodeTime.isHostTimeValid,
              let playerTime = musicNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleTime >= 0
        else { return nil }
        let position = Double(segmentStartFrame) / file.processingFormat.sampleRate
            + Double(playerTime.sampleTime) / playerTime.sampleRate
        let out = HostClock.nanos(fromHostTicks: nodeTime.hostTime) + AudioRoute.totalOutputDelayNanos
        return (position, out)
    }

    // MARK: Calibration chirps

    var chirpSampleRate: Double { chirpFormat.sampleRate }

    /// Calibration schedules several chirps per device, but the chirp node holds
    /// one start time at a time, so each is handed over shortly before it's due.
    func playChirpWhenDue(_ samples: [Float], outputAtLocalNanos t: Int64) {
        let handOver = t - AudioRoute.totalOutputDelayNanos - 250_000_000
        let delay = max(0, handOver - HostClock.nowNanos())
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            MainActor.assumeIsolated {
                do { try self?.playChirp(samples, outputAtLocalNanos: t) }
                catch { print("Chirp failed: \(error)") }
            }
        }
    }

    /// Plays `samples` (mono, at `chirpSampleRate`) so the first sample leaves
    /// the speaker at local time `t`, using the same delay compensation as music.
    func playChirp(_ samples: [Float], outputAtLocalNanos t: Int64) throws {
        try ensureRunning()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: chirpFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        chirpNode.stop()
        chirpNode.scheduleBuffer(buffer, at: nil)
        let renderAt = t - AudioRoute.totalOutputDelayNanos
        chirpNode.play(at: AVAudioTime(hostTime: HostClock.hostTicks(fromNanos: renderAt)))
    }
}

enum PlayerError: LocalizedError {
    case wrongSource
    case missingFile(String)
    case spotifyNotConnected
    case spotifyUnavailable

    var errorDescription: String? {
        switch self {
        case .wrongSource: return "This player can't play that kind of track."
        case .missingFile(let id): return "\"\(id)\" isn't on this phone. Every phone needs the same file."
        case .spotifyNotConnected: return "Not connected to Spotify yet."
        case .spotifyUnavailable: return "This build doesn't include the Spotify SDK."
        }
    }
}
