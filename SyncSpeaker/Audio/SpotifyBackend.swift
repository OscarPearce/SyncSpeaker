import Foundation

/// Controls this phone's Spotify app through the Spotify iOS SDK (App Remote).
///
/// We can't touch Spotify's audio, only send commands, so all the sync logic
/// lives in `RemoteSyncPlayer`; this just carries the commands. The same logic
/// is testable without Spotify through `SimulatedSpotifyBackend`.
///
/// Builds without the SDK: add the `SpotifyiOS` package (see README) to enable it.
#if canImport(SpotifyiOS)
import SpotifyiOS

@MainActor
final class SpotifyBackend: NSObject, RemoteBackend {
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

    let storageKey = "spotify"
    /// App Remote has no volume control, so the echo monitor can't mute other
    /// Spotify phones; with Spotify it needs exactly two speakers.
    let canMute = false
    private(set) var isConnected = false
    private(set) var lastReport: RemotePositionReport?

    var onConnectionChange: ((Bool, String?) -> Void)?

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

    // MARK: RemoteBackend

    func load(_ track: TrackSource, position: Double) async throws {
        guard case let .spotify(uri, _) = track else { throw PlayerError.wrongSource }
        guard isConnected, let api = appRemote.playerAPI else { throw PlayerError.spotifyNotConnected }
        try await call { api.play(uri, callback: $0) }
        try await Task.sleep(nanoseconds: 700_000_000)        // let Spotify load the track
        try await call { api.seek(toPosition: Int(position * 1000), callback: $0) }
        try await call { api.pause($0) }
        try await Task.sleep(nanoseconds: 500_000_000)        // let it settle and buffer
    }

    func resume() { appRemote.playerAPI?.resume(nil) }
    func pause() { appRemote.playerAPI?.pause(nil) }
    func seek(to position: Double) { appRemote.playerAPI?.seek(toPosition: Int(position * 1000), callback: nil) }
    func setMuted(_ muted: Bool) {}

    private func call(_ body: (@escaping SPTAppRemoteCallback) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            body { _, error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

// The SDK calls these on its own schedule; hop to the main actor explicitly.
extension SpotifyBackend: SPTAppRemoteDelegate {
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
            self.onConnectionChange?(false, message)
        }
    }
}

extension SpotifyBackend: SPTAppRemotePlayerStateDelegate {
    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        let receivedAt = HostClock.nowNanos()          // stamp before any hop
        let position = Double(playerState.playbackPosition) / 1000
        let paused = playerState.isPaused
        Task { @MainActor in
            self.lastReport = RemotePositionReport(position: position, atLocalNanos: receivedAt, paused: paused)
        }
    }
}

#else

/// Stand-in used when the Spotify SDK isn't linked, so the rest of the app builds.
@MainActor
final class SpotifyBackend: RemoteBackend {
    let storageKey = "spotify"
    let isConnected = false
    let canMute = false
    let lastReport: RemotePositionReport? = nil
    var onConnectionChange: ((Bool, String?) -> Void)?

    func authorize() { onConnectionChange?(false, PlayerError.spotifyUnavailable.errorDescription) }
    func handle(url: URL) -> Bool { false }
    func reconnectIfNeeded() {}
    func load(_ track: TrackSource, position: Double) async throws { throw PlayerError.spotifyUnavailable }
    func resume() {}
    func pause() {}
    func seek(to position: Double) {}
    func setMuted(_ muted: Bool) {}
}

#endif
