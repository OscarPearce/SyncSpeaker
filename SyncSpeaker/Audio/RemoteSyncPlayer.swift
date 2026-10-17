import AVFoundation

/// Where a command-only player says it is. Like Spotify's player state: sent
/// only when its state changes, so extrapolate from `atLocalNanos`.
struct RemotePositionReport {
    let position: Double        // seconds
    let atLocalNanos: Int64
    let paused: Bool
}

/// A player we can only send commands to (resume / pause / seek), never
/// touch the audio of. The real Spotify app is one; `SimulatedSpotifyBackend`
/// is another that behaves like it, for testing without Spotify.
@MainActor
protocol RemoteBackend: AnyObject {
    /// Key for learned per-backend latencies, e.g. "spotify".
    var storageKey: String { get }
    var isConnected: Bool { get }
    var canMute: Bool { get }
    var lastReport: RemotePositionReport? { get }

    /// Load the track, seek to `position` and leave it paused, so the audio is
    /// already buffered when `resume()` is called.
    func load(_ track: TrackSource, position: Double) async throws
    func resume()
    func pause()
    func seek(to position: Double)
    func setMuted(_ muted: Bool)
}

/// Syncs a command-only player by timing its commands:
///
/// - **Start:** every phone loads, seeks and pauses ahead of time; then
///   `resume()` is sent early by this phone's measured resume delay. Resuming
///   already-buffered audio is far more consistent than a cold play or a seek.
/// - **Resume delay:** measured with the mic a few times (`measureResumeLatencyOnce`)
///   and averaged, per phone.
/// - **During playback:** only a coarse safety net here (seek if > 150 ms off).
///   Fine correction comes from the echo monitor (`EchoCorrector`), which
///   calls `realign` only when the offset passes its threshold.
@MainActor
final class RemoteSyncPlayer: SyncPlayer {
    let backend: RemoteBackend

    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var lastErrorMillis: Double?
    var currentRate: Double? { nil }      // no rate control, only seeks
    var canMute: Bool { backend.canMute }

    /// Coarse-check threshold and spacing. Seeks are audible and each adds its
    /// own random error, so keep them rare.
    var coarseThresholdSeconds = 0.150
    var minSeekSpacingNanos: Int64 = 20_000_000_000

    private var preparedPosition: Double = 0
    private var lastSeekNanos: Int64 = 0

    init(backend: RemoteBackend) {
        self.backend = backend
    }

    // MARK: Learned latencies (per phone, per backend)

    /// Time from `resume()` to sound leaving the phone, excluding route delay.
    var resumeLatencyMillis: Double {
        get { UserDefaults.standard.object(forKey: "resumeLatencyMillis.\(backend.storageKey)") as? Double ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "resumeLatencyMillis.\(backend.storageKey)") }
    }

    /// Standard deviation of the resume-delay measurements; nil until measured.
    var resumeJitterMillis: Double? {
        get { UserDefaults.standard.object(forKey: "resumeJitterMillis.\(backend.storageKey)") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "resumeJitterMillis.\(backend.storageKey)") }
    }

    /// Rough time from `seek()` until the new position is heard.
    var seekLatencyMillis = 150.0

    // MARK: SyncPlayer

    func prepare(_ track: TrackSource, position: Double) async throws {
        isReady = false
        isPlaying = false
        try await backend.load(track, position: position)
        preparedPosition = position
        isReady = true
    }

    func start(outputAtLocalNanos t: Int64, position: Double) {
        guard isReady else { return }
        if abs(position - preparedPosition) > 0.005 {
            // Rare (late join with a stale prepare). A seek now, while paused, still buffers in time.
            backend.seek(to: position)
            preparedPosition = position
        }
        let fireAt = t - AudioRoute.totalOutputDelayNanos - resumeLatencyMillis.millisToNanos
        fire(at: fireAt) { [weak self] in self?.backend.resume() }
        isPlaying = true
        lastSeekNanos = HostClock.nowNanos()   // no coarse seeks while it starts
    }

    func pause() {
        backend.pause()
        isPlaying = false
        lastErrorMillis = nil
    }

    func tick(expected: (Int64) -> Double) {
        guard isPlaying, let report = backend.lastReport, !report.paused else { return }
        // Reports are coarse (integer ms, only on state changes), so extrapolate
        // from the last one and act only on big errors.
        let now = HostClock.nowNanos()
        let reported = report.position + (now - report.atLocalNanos).nanosToSeconds
        let error = reported - expected(now + AudioRoute.totalOutputDelayNanos)
        lastErrorMillis = error * 1000

        guard abs(error) > coarseThresholdSeconds, now - lastSeekNanos > minSeekSpacingNanos else { return }
        realign(expected: expected)
    }

    func realign(expected: (Int64) -> Double) {
        let now = HostClock.nowNanos()
        lastSeekNanos = now
        // Aim for where the timeline will be once the seek has taken effect.
        let target = expected(now + seekLatencyMillis.millisToNanos + AudioRoute.totalOutputDelayNanos)
        backend.seek(to: max(0, target))
        if !isPlaying { preparedPosition = max(0, target) }
    }

    func setMuted(_ muted: Bool) {
        backend.setMuted(muted)
    }

    // MARK: Resume-delay probe

    /// Plays about a second from the prepared position while recording with
    /// this phone's mic, then pauses and seeks back. Returns the delay from
    /// `resume()` to sound, minus the route's output delay, in ms.
    ///
    /// Other phones must be silent meanwhile; the leader schedules one phone at a time.
    func measureResumeLatencyOnce(engine: AVAudioEngine) async -> Double? {
        guard isReady, !isPlaying else { return nil }
        let recorder = MicRecorder(engine: engine)
        do { try recorder.start() } catch { return nil }

        try? await Task.sleep(nanoseconds: 400_000_000)   // quiet lead-in for the noise floor
        let calledAt = HostClock.nowNanos()
        backend.resume()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        backend.pause()
        let recording = recorder.stop()
        backend.seek(to: preparedPosition)

        guard let recording,
              let onset = DSP.onsetIndex(in: recording.samples, sampleRate: recording.sampleRate, leadIn: 0.3)
        else { return nil }
        let soundAt = recording.localNanos(atSample: onset)
        return (soundAt - calledAt - AudioRoute.totalOutputDelayNanos).nanosToMillis
    }

    /// Stores the average of several probe results. Returns (mean, sd) used.
    @discardableResult
    func applyResumeMeasurements(_ values: [Double]) -> (mean: Double, sd: Double)? {
        guard let summary = Self.summarize(values) else { return nil }
        resumeLatencyMillis = summary.mean
        resumeJitterMillis = summary.sd
        return summary
    }

    /// Mean and standard deviation, ignoring values more than 50 ms from the
    /// median (e.g. an onset missed in a quiet intro).
    nonisolated static func summarize(_ values: [Double]) -> (mean: Double, sd: Double)? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let kept = values.filter { abs($0 - median) <= 50 }
        let mean = kept.reduce(0, +) / Double(kept.count)
        let variance = kept.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(kept.count)
        return (mean, variance.squareRoot())
    }

    // MARK: Helpers

    /// Runs `action` on the main queue at local time `t`: wakes ~3 ms early,
    /// then spins, because `asyncAfter` alone can be a few ms late.
    private func fire(at t: Int64, _ action: @escaping @MainActor () -> Void) {
        let wake = max(0, t - 3_000_000 - HostClock.nowNanos())
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(wake))) {
            MainActor.assumeIsolated {
                while HostClock.nowNanos() < t {}
                action()
            }
        }
    }
}
