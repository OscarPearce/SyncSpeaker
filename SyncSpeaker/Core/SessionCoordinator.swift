import Foundation
import MultipeerConnectivity
import AVFoundation
import UIKit

/// The app's brain: owns the network session, the shared clock, the players,
/// and the leader/follower logic. Views observe it.
@MainActor
final class SessionCoordinator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case hosting
        case browsing
        case joined(leaderName: String)
    }

    enum CalibrationState: Equatable {
        case idle
        case running(String)
        case done(String)
        case failed(String)
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var connectedPeers: [String] = []
    @Published private(set) var foundLeaders: [MCPeerID] = []
    @Published private(set) var track: TrackSource?
    @Published private(set) var timeline: Timeline?
    @Published private(set) var peerStatuses: [String: PeerStatus] = [:]
    @Published private(set) var calibration: CalibrationState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var spotifyConnected = false

    // Live readouts (refreshed by the tick timer)
    @Published private(set) var clockRMSMillis: Double?
    @Published private(set) var clockMinRTTMillis: Double?
    @Published private(set) var playerErrorMillis: Double?
    @Published private(set) var playerRate: Double?
    @Published private(set) var routeName = AudioRoute.routeName
    @Published private(set) var residualMillis = AudioRoute.residualMillis
    @Published private(set) var reportedDelayMillis = AudioRoute.reportedOutputDelayNanos.nanosToMillis

    var isLeader: Bool { phase == .hosting }
    var myID: String { peer.localPeer.displayName }

    // MARK: Parts

    private let peer: PeerSession
    private var clock = ClockSync()
    let localPlayer: LocalEnginePlayer
    let spotifyPlayer: SpotifyPlayer
    private var activePlayer: SyncPlayer?

    private var pingTimer: Timer?
    private var tickTimer: Timer?
    private var pingID: UInt32 = 0
    private var lastStatusSent: Int64 = 0
    private var routeObserver: NSObjectProtocol?

    init() {
        // Created here rather than as property defaults: their initializers
        // are main-actor isolated (UIDevice, AVAudioEngine setup).
        peer = PeerSession(deviceName: UIDevice.current.name)
        localPlayer = LocalEnginePlayer()
        spotifyPlayer = SpotifyPlayer()

        do { try AudioRoute.configure() } catch { lastError = "Audio session: \(error.localizedDescription)" }
        Task { _ = await AudioRoute.requestMicrophone() }

        peer.onMessage = { [weak self] message, from, receivedAt in
            self?.handle(message, from: from, receivedAt: receivedAt)
        }
        peer.onPeersChanged = { [weak self] peers in self?.peersChanged(peers) }
        peer.onFoundLeadersChanged = { [weak self] leaders in self?.foundLeaders = leaders }

        localPlayer.onNeedsResync = { [weak self] in self?.resyncAfterInterruption() }
        spotifyPlayer.onConnectionChange = { [weak self] connected, error in
            self?.spotifyConnected = connected
            if let error { self?.lastError = "Spotify: \(error)" }
        }

        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRouteInfo() }
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Roles

    func host() {
        reset()
        peer.startAdvertising()
        phase = .hosting
    }

    func browse() {
        reset()
        peer.startBrowsing()
        phase = .browsing
    }

    func join(_ leader: MCPeerID) {
        peer.join(leader)
        phase = .joined(leaderName: leader.displayName)
        startPinging()
    }

    func leave() {
        reset()
        phase = .idle
    }

    private func reset() {
        activePlayer?.pause()
        activePlayer = nil
        peer.disconnect()
        clock.reset()
        pingTimer?.invalidate()
        pingTimer = nil
        track = nil
        timeline = nil
        peerStatuses = [:]
        calibration = .idle
    }

    // MARK: Clock

    /// Leader-clock ns for a local ns. The leader's own clock is the reference.
    func leaderTime(fromLocal t: Int64) -> Int64 {
        isLeader ? t : clock.leaderTime(fromLocal: t)
    }

    func localTime(fromLeader t: Int64) -> Int64 {
        isLeader ? t : clock.localTime(fromLeader: t)
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.peer.connectedPeers.isEmpty else { return }
                self.pingID &+= 1
                self.peer.send(.ping(id: self.pingID, t1: HostClock.nowNanos()))
            }
        }
    }

    // MARK: Leader actions

    /// Leader: everyone loads `track`, then everyone starts together.
    func play(_ newTrack: TrackSource, from position: Double = 0) {
        guard isLeader else { return }
        track = newTrack
        timeline = nil
        peer.send(.load(track: newTrack, position: position))
        Task {
            await prepareLocally(newTrack, position: position)
            // Spotify needs a few seconds to load + seek + pause on every phone.
            let wait: UInt64 = { if case .spotify = newTrack { return 3_000_000_000 } else { return 700_000_000 } }()
            try? await Task.sleep(nanoseconds: wait)
            let start = HostClock.nowNanos() + 1_500_000_000
            peer.send(.startAt(leaderTime: start, position: position))
            begin(Timeline(leaderStart: start, position: position))
        }
    }

    func pauseAll() {
        guard isLeader else { return }
        peer.send(.pause)
        stopLocally()
    }

    /// Leader: run a calibration with `listenerID` holding the measuring phone.
    func calibrate(listenerID: String) {
        guard isLeader else { return }
        if timeline != nil { pauseAll() }
        let devices = [myID] + connectedPeers
        let slots = Calibrator.plan(deviceIDs: devices, startingAtLeader: HostClock.nowNanos())
        peer.send(.calibrationPlan(listenerID: listenerID, slots: slots))
        runCalibration(listenerID: listenerID, slots: slots)
    }

    // MARK: Message handling

    private func handle(_ message: SyncMessage, from: MCPeerID, receivedAt: Int64) {
        switch message {
        case .hello:
            break

        case .ping:
            break   // answered inside PeerSession

        case let .pong(_, t1, t2, t3):
            clock.addExchange(t1: t1, t2: t2, t3: t3, t4: receivedAt)

        case let .load(newTrack, position):
            track = newTrack
            timeline = nil
            Task { await prepareLocally(newTrack, position: position) }

        case let .startAt(leaderStart, position):
            begin(Timeline(leaderStart: leaderStart, position: position))

        case .pause:
            stopLocally()

        case let .calibrationPlan(listenerID, slots):
            stopLocally()
            runCalibration(listenerID: listenerID, slots: slots)

        case let .calibrationResult(corrections):
            applyCalibration(corrections)

        case let .status(status):
            peerStatuses[from.displayName] = status
        }
    }

    private func peersChanged(_ peers: [MCPeerID]) {
        let names = peers.map(\.displayName)
        let newcomers = peers.filter { !connectedPeers.contains($0.displayName) }
        connectedPeers = names
        peerStatuses = peerStatuses.filter { names.contains($0.key) }

        // Leader: bring late joiners into whatever is already playing.
        guard isLeader, let track, let timeline, !newcomers.isEmpty else { return }
        // Pick the join point now so the newcomer prepares at the right
        // position (Spotify pre-seeks during prepare).
        let start = HostClock.nowNanos() + 4_500_000_000
        let position = timeline.expectedPosition(atLeader: start)
        peer.send(.load(track: track, position: position), to: newcomers)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            peer.send(.startAt(leaderTime: start, position: position), to: newcomers)
        }
    }

    // MARK: Playback

    private func player(for track: TrackSource) -> SyncPlayer {
        switch track {
        case .local: return localPlayer
        case .spotify: return spotifyPlayer
        }
    }

    private func prepareLocally(_ track: TrackSource, position: Double) async {
        activePlayer?.pause()
        let p = player(for: track)
        activePlayer = p
        do {
            try await p.prepare(track, position: position)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func begin(_ newTimeline: Timeline) {
        timeline = newTimeline
        guard let p = activePlayer, p.isReady else {
            lastError = lastError ?? "Not ready in time; will join on the next start."
            return
        }
        if !isLeader && !clock.isSynced {
            lastError = "Clock not synced yet; start may be off."
        }
        p.start(outputAtLocalNanos: localTime(fromLeader: newTimeline.leaderStart),
                position: newTimeline.position)
    }

    private func stopLocally() {
        activePlayer?.pause()
        timeline = nil
    }

    private func resyncAfterInterruption() {
        guard let timeline, let p = activePlayer else { return }
        let at = HostClock.nowNanos() + 400_000_000
        p.start(outputAtLocalNanos: at, position: timeline.expectedPosition(atLeader: leaderTime(fromLocal: at)))
    }

    private func tick() {
        if let timeline, let p = activePlayer, p.isPlaying {
            p.tick { [unowned self] local in
                timeline.expectedPosition(atLeader: self.leaderTime(fromLocal: local))
            }
        }
        clockRMSMillis = clock.isSynced ? clock.residualRMS / 1_000_000 : nil
        clockMinRTTMillis = clock.minRTTNanos?.nanosToMillis
        playerErrorMillis = activePlayer?.lastErrorMillis
        playerRate = activePlayer?.currentRate
        refreshRouteInfo()

        // Followers report to the leader about once a second.
        let now = HostClock.nowNanos()
        if !isLeader, case .joined = phase, now - lastStatusSent > 1_000_000_000 {
            lastStatusSent = now
            let status = PeerStatus(ready: activePlayer?.isReady ?? false,
                                    playing: activePlayer?.isPlaying ?? false,
                                    errorMillis: playerErrorMillis,
                                    rate: playerRate,
                                    clockRMSMillis: clockRMSMillis,
                                    routeName: routeName)
            peer.send(.status(status))
        }
    }

    private func refreshRouteInfo() {
        routeName = AudioRoute.routeName
        residualMillis = AudioRoute.residualMillis
        reportedDelayMillis = AudioRoute.reportedOutputDelayNanos.nanosToMillis
    }

    // MARK: Calibration

    private func runCalibration(listenerID: String, slots: [CalibrationSlot]) {
        calibration = .running("Listen for the chirps…")
        let chirp48k = DSP.chirp(sampleRate: localPlayer.chirpSampleRate)

        // Schedule this phone's own chirps.
        do { try localPlayer.ensureRunning() } catch {
            calibration = .failed("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        for slot in slots where slot.peerID == myID {
            localPlayer.playChirpWhenDue(chirp48k, outputAtLocalNanos: localTime(fromLeader: slot.leaderTime))
        }

        guard listenerID == myID else { return }

        // This phone is the listener: record everything, then analyse.
        let recorder = MicRecorder(engine: localPlayer.engine)
        do { try recorder.start() } catch {
            calibration = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        let end = localTime(fromLeader: Calibrator.endTime(of: slots))
        let waitNanos = UInt64(max(0, end - HostClock.nowNanos()))
        Task {
            try? await Task.sleep(nanoseconds: waitNanos)
            guard let recording = recorder.stop() else {
                calibration = .failed("Recording had a gap or no timestamps. Try again.")
                return
            }
            calibration = .running("Analysing…")
            let template = DSP.chirp(sampleRate: recording.sampleRate)
            let result = await Task.detached(priority: .userInitiated) { [clock = self.clock, isLeader = self.isLeader] in
                Calibrator.analyze(recording: recording,
                                   template: template,
                                   slots: slots,
                                   toLeader: { isLeader ? $0 : clock.leaderTime(fromLocal: $0) },
                                   toLocal: { isLeader ? $0 : clock.localTime(fromLeader: $0) })
            }.value

            let expectedDevices = Set(slots.map(\.peerID))
            let heard = Set(result.corrections.keys)
            guard heard.count >= 2 || (expectedDevices.count == 1 && heard.count == 1) else {
                calibration = .failed("Only heard \(heard.count) of \(expectedDevices.count) speakers. Turn them up or move closer.")
                return
            }
            peer.send(.calibrationResult(correctionsMillis: result.corrections))
            applyCalibration(result.corrections)
            let missing = expectedDevices.subtracting(heard)
            if !missing.isEmpty {
                lastError = "Didn't hear: \(missing.sorted().joined(separator: ", "))"
            }
        }
    }

    private func applyCalibration(_ corrections: [String: Double]) {
        if let mine = corrections[myID] {
            AudioRoute.residualMillis += mine
            refreshRouteInfo()
            calibration = .done(String(format: "Adjusted this speaker by %+.1f ms", mine))
        } else {
            calibration = .done("Calibration finished (this phone wasn't measured)")
        }
    }

    // MARK: Spotify

    func connectSpotify() { spotifyPlayer.authorize() }

    func handleOpenURL(_ url: URL) {
        _ = spotifyPlayer.handle(url: url)
    }

    func appBecameActive() {
        spotifyPlayer.reconnectIfNeeded()
    }
}
