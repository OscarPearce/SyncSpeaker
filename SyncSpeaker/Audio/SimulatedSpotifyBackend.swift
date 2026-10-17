import AVFoundation

/// Behaves like the Spotify app, but plays a local file, so the whole Spotify
/// sync path (pause-then-resume start, resume-delay probe, echo monitor,
/// threshold seeks) can be tested on real phones without Spotify.
///
/// Like Spotify, it only takes resume / pause / seek commands. Each command
/// takes effect after a random delay, seeks land slightly off target, and
/// position is reported coarsely (integer ms, only when its state changes).
/// Nothing in the sync code can reach past these limits.
@MainActor
final class SimulatedSpotifyBackend: RemoteBackend {
    /// Delays are in ms; `...Jitter` values are standard deviations.
    struct Behaviour {
        /// Fixed per phone, like a phone's own resume delay. Picked at random per launch.
        var resumeBase: Double
        var resumeJitter = 8.0
        var pauseDelay = 40.0
        var seekDelay = 150.0
        var seekJitter = 25.0
        /// Where a seek lands relative to its target.
        var seekLandingError = 10.0

        static func randomPhone() -> Behaviour {
            Behaviour(resumeBase: Double.random(in: 40...140))
        }
    }

    let storageKey = "simulated"
    let isConnected = true
    let canMute = true
    var behaviour = Behaviour.randomPhone()
    private(set) var lastReport: RemotePositionReport?

    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var segmentStart: Double = 0        // seconds
    private var paused = true

    init(engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(node)
    }

    func load(_ track: TrackSource, position: Double) async throws {
        guard case let .simulatedSpotify(id, _) = track else { throw PlayerError.wrongSource }
        guard let url = LocalLibrary.url(forID: id) else { throw PlayerError.missingFile(id) }
        node.stop()
        paused = true
        let f = try AVAudioFile(forReading: url)
        file = f
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        // A cold load takes a while, like Spotify fetching a track.
        try await Task.sleep(nanoseconds: UInt64(Double.random(in: 300...700) * 1_000_000))
        schedule(from: position)
        report()
    }

    func resume() {
        after(Self.gaussian(behaviour.resumeBase, behaviour.resumeJitter)) { backend in
            guard backend.paused else { return }
            backend.node.play()
            backend.paused = false
            backend.report()
        }
    }

    func pause() {
        after(Self.gaussian(behaviour.pauseDelay, 5)) { backend in
            backend.node.pause()
            backend.paused = true
            backend.report()
        }
    }

    func seek(to position: Double) {
        let landing = max(0, position + Self.gaussian(0, behaviour.seekLandingError) / 1000)
        after(Self.gaussian(behaviour.seekDelay, behaviour.seekJitter)) { backend in
            backend.node.stop()
            backend.schedule(from: landing)
            if !backend.paused { backend.node.play() }
            backend.report()
        }
    }

    func setMuted(_ muted: Bool) {
        node.volume = muted ? 0 : 1
    }

    // MARK: Internals

    private func schedule(from position: Double) {
        guard let file else { return }
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(position * sr)
        guard startFrame < file.length else { return }
        segmentStart = Double(startFrame) / sr
        node.scheduleSegment(file,
                             startingFrame: startFrame,
                             frameCount: AVAudioFrameCount(file.length - startFrame),
                             at: nil)
        node.prepare(withFrameCount: 8_192)
    }

    private var currentPosition: Double {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return segmentStart }
        return segmentStart + Double(max(0, playerTime.sampleTime)) / playerTime.sampleRate
    }

    /// Integer-ms position, stamped on arrival, like Spotify's player state.
    private func report() {
        let ms = (currentPosition * 1000).rounded(.down)
        lastReport = RemotePositionReport(position: ms / 1000, atLocalNanos: HostClock.nowNanos(), paused: paused)
    }

    private func after(_ millis: Double, _ action: @escaping @MainActor (SimulatedSpotifyBackend) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, millis) / 1000) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
    }

    private static func gaussian(_ mean: Double, _ sd: Double) -> Double {
        // Box–Muller
        let u1 = Double.random(in: Double.ulpOfOne..<1)
        let u2 = Double.random(in: 0..<1)
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
