import Foundation

/// Controls this phone's Spotify app through the Spotify iOS SDK (App Remote).
///
/// We can't touch Spotify's audio, only send commands, so sync comes from
/// *when* commands are sent:
/// 1. prepare: play the URI, seek to the start position, pause. Audio is now buffered.
/// 2. start: call `resume()` early by (route delay + learned resume latency).
/// 3. tick: compare Spotify's reported position with the timeline and seek if
///    it's clearly off. Fine correction comes from the echo check (M4/M5).
///
/// Builds without the SDK: add the `SpotifyiOS` package (see README) to enable it.
#if canImport(SpotifyiOS)
import SpotifyiOS

@MainActor
final class SpotifyPlayer: NSObject, SyncPlayer {
    // Fill these in from https://developer.spotify.com/dashboard
    // The redirect URI must also be registered in the dashboard.
    static let clientID = "YOUR_SPOTIFY_CLIENT_ID"
    static let redirectURL = URL(string: "syncspeaker://spotify-callback")!

    private lazy var appRemote: SPTAppRemote = {
        let config = SPTConfiguration(clientID: Self.clientID, redirectURL: Self.redirectURL)
        let remote = SPTAppRemote(configuration: config, logLevel: .info)
        remote.delegate = self
        return remote
    }()

    private(set) var isConnected = false
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var lastErrorMillis: Double?
    var currentRate: Double? { nil }   // Spotify has no rate control

    var onConnectionChange: ((Bool, String?) -> Void)?

    /// Time from calling resume() until sound leaves the phone, learned over time.
    /// Starts at a guess; the echo check refines it (DESIGN.md, Spotify extra step).
    var resumeLatencyMillis: Double {
        get { UserDefaults.standard.object(forKey: "spotifyResumeLatencyMillis") as? Double ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "spotifyResumeLatencyMillis") }
    }

    private var lastState: (positionMs: Int, receivedAt: Int64, paused: Bool)?
    private var lastSeekNanos: Int64 = 0

    // MARK: Connection

    /// Opens Spotify to authorize; it comes back via `handle(url:)`.
    func authorize() {
        // "" = resume the user's last song; App Remote needs Spotify awake and playing.
        appRemote.authorizeAndPlayURI("") { [weak self] canAttempt in
            guard !canAttempt else { return }
            Task { @MainActor in
                self?.onConnectionChange?(false, "The Spotify app isn't installed on this phone.")
            }
        }
    }

    func handle(url: URL) -> Bool {
        guard url.scheme == Self.redirectURL.scheme else { return false }
        let params = appRemote.authorizationParameters(from: url)
        if let token = params?[SPTAppRemoteAccessTokenKey] {
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
        } else if let error = params?[SPTAppRemoteErrorDescriptionKey] {
            onConnectionChange?(false, error)
        }
        return true
    }

    func reconnectIfNeeded() {
        if !appRemote.isConnected, appRemote.connectionParameters.accessToken != nil {
            appRemote.connect()
        }
    }

    // MARK: SyncPlayer

    func prepare(_ track: TrackSource, position: Double) async throws {
        guard case let .spotify(uri, _) = track else { throw PlayerError.wrongSource }
        guard isConnected, let api = appRemote.playerAPI else { throw PlayerError.spotifyNotConnected }
        isReady = false
        try await call { api.play(uri, callback: $0) }
        try await Task.sleep(nanoseconds: 700_000_000)        // let Spotify load the track
        try await call { api.seek(toPosition: Int(position * 1000), callback: $0) }
        try await call { api.pause($0) }
        try await Task.sleep(nanoseconds: 500_000_000)        // let it settle and buffer
        isReady = true
    }

    func start(outputAtLocalNanos t: Int64, position: Double) {
        guard let api = appRemote.playerAPI else { return }
        let fireAt = t - AudioRoute.totalOutputDelayNanos - resumeLatencyMillis.millisToNanos
        // Wake up ~3 ms early on the main queue, then spin for the last bit:
        // asyncAfter alone can be a few ms late.
        let wake = max(fireAt - 3_000_000, HostClock.nowNanos())
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: UInt64(wake))) {
            while HostClock.nowNanos() < fireAt {}
            api.resume(nil)
        }
        isPlaying = true
    }

    func pause() {
        appRemote.playerAPI?.pause(nil)
        isPlaying = false
        lastErrorMillis = nil
    }

    func tick(expected: (Int64) -> Double) {
        guard isPlaying, let s = lastState, !s.paused else { return }
        // Position reports arrive only on state changes and are coarse, so
        // extrapolate from the last one and act only on big errors.
        let now = HostClock.nowNanos()
        let reported = Double(s.positionMs) / 1000 + (now - s.receivedAt).nanosToSeconds
        let error = reported - expected(now + AudioRoute.totalOutputDelayNanos)
        lastErrorMillis = error * 1000

        guard abs(error) > 0.150, now - lastSeekNanos > 20_000_000_000 else { return }
        lastSeekNanos = now
        let seekLead: Int64 = 150_000_000               // rough seek latency
        let target = expected(now + seekLead + AudioRoute.totalOutputDelayNanos)
        appRemote.playerAPI?.seek(toPosition: Int(target * 1000), callback: nil)
    }

    /// Fine correction from an external measurement such as the echo check.
    /// Positive = this speaker is ahead.
    func applyMeasuredOffset(millis: Double) {
        resumeLatencyMillis = max(0, resumeLatencyMillis - millis)
    }

    // MARK: Helpers

    private func call(_ body: (@escaping SPTAppRemoteCallback) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            body { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

// The SDK calls these on its own schedule; hop to the main actor explicitly.
extension SpotifyPlayer: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.isConnected = true
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: nil)
            self.onConnectionChange?(true, nil)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isConnected = false
            self.onConnectionChange?(false, message)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isConnected = false
            self.isReady = false
            self.onConnectionChange?(false, message)
        }
    }
}

extension SpotifyPlayer: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let receivedAt = HostClock.nowNanos()          // stamp before any hop
        let position = playerState.playbackPosition
        let paused = playerState.isPaused
        Task { @MainActor in
            self.lastState = (position, receivedAt, paused)
        }
    }
}

#else

/// Stand-in used when the Spotify SDK isn't linked, so the rest of the app builds.
@MainActor
final class SpotifyPlayer: SyncPlayer {
    let isConnected = false
    let isReady = false
    let isPlaying = false
    let lastErrorMillis: Double? = nil
    var currentRate: Double? { nil }
    var onConnectionChange: ((Bool, String?) -> Void)?

    func authorize() { onConnectionChange?(false, PlayerError.spotifyUnavailable.errorDescription) }
    func handle(url: URL) -> Bool { false }
    func reconnectIfNeeded() {}
    func prepare(_ track: TrackSource, position: Double) async throws { throw PlayerError.spotifyUnavailable }
    func start(outputAtLocalNanos: Int64, position: Double) {}
    func pause() {}
    func tick(expected: (Int64) -> Double) {}
    func applyMeasuredOffset(millis: Double) {}
}

#endif
