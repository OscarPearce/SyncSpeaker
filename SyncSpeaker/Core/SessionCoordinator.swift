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

    // Spotify-style sync (Spotify and simulated Spotify)
    @Published private(set) var resumeProbe: CalibrationState = .idle
    @Published private(set) var resumeLatencyMillis: Double?
    @Published private(set) var resumeJitterMillis: Double?
    /// This speaker's echo-monitor correction so far, ms (positive = moved ahead).
    @Published private(set) var trimMillis = 0.0
    /// Leader: continuously check sync with the listening phone's mic while music plays.
    @Published var echoMonitorEnabled = false {
        didSet { if echoMonitorEnabled != oldValue { echoMonitorChanged() } }
    }
    /// Phone whose mic the echo monitor uses. Empty = the leader.
    @Published var monitorListenerID = ""
    /// Recent echo-monitor results, newest first.
    @Published private(set) var echoLog: [String] = []

    var isLeader: Bool { phase == .hosting }
    var myID: String { peer.localPeer.displayName }

    // MARK: Parts

    private let peer: PeerSession
    private var clock = ClockSync()
    let localPlayer: LocalEnginePlayer
    let spotifyBackend: SpotifyBackend
    let spotifyPlayer: RemoteSyncPlayer
    let simulatedPlayer: RemoteSyncPlayer
    private var activePlayer: SyncPlayer?

    private var pingTimer: Timer?
    private var tickTimer: Timer?
    private var pingID: UInt32 = 0
    private var lastStatusSent: Int64 = 0
    private var routeObserver: NSObjectProtocol?

    // Echo monitor (leader)
    private var monitorTask: Task<Void, Never>?
    private var corrector = EchoCorrector()
    private var echoRequestID: UInt32 = 0
    private var echoWaiters: [UInt32: CheckedContinuation<EchoReading?, Never>] = [:]
    /// Seconds between echo checks.
    private let echoInterval: UInt64 = 15

    init() {
        // Created here rather than as property defaults: their initializers
        // are main-actor isolated (UIDevice, AVAudioEngine setup).
        peer = PeerSession(deviceName: UIDevice.current.name)
        localPlayer = LocalEnginePlayer()
        spotifyBackend = SpotifyBackend()
        spotifyPlayer = RemoteSyncPlayer(backend: spotifyBackend)
        simulatedPlayer = RemoteSyncPlayer(backend: SimulatedSpotifyBackend(engine: localPlayer.engine))

        do { try AudioRoute.configure() } catch { lastError = "Audio session: \(error.localizedDescription)" }
        Task { _ = await AudioRoute.requestMicrophone() }

        peer.onMessage = { [weak self] message, from, receivedAt in
            self?.handle(message, from: from, receivedAt: receivedAt)
        }
        peer.onPeersChanged = { [weak self] peers in self?.peersChanged(peers) }
        peer.onFoundLeadersChanged = { [weak self] leaders in self?.foundLeaders = leaders }

        localPlayer.onNeedsResync = { [weak self] in self?.resyncAfterInterruption() }
        spotifyBackend.onConnectionChange = { [weak self] connected, error in
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
        echoMonitorEnabled = false
        activePlayer?.setMuted(false)
        activePlayer?.pause()
        activePlayer = nil
        trimMillis = 0
        corrector.forgetReflections()
        echoLog = []
        resumeProbe = .idle
        for (_, waiter) in echoWaiters { waiter.resume(returning: nil) }
        echoWaiters = [:]
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
            let wait: UInt64 = newTrack.isRemote ? 3_000_000_000 : 700_000_000
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

        case let .resumeProbePlan(slots):
            runResumeProbe(slots: slots)

        case let .echoMeasure(id, candidates):
            Task {
                let reading = await measureEcho(candidatesMillis: candidates)
                peer.send(.echoResult(id: id, reading: reading), to: [from])
            }

        case let .echoResult(id, reading):
            finishEchoRequest(id, reading)

        case let .shift(aheadBy):
            shiftTimeline(aheadByMillis: aheadBy)

        case let .mute(muted):
            activePlayer?.setMuted(muted)

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
        case .simulatedSpotify: return simulatedPlayer
        }
    }

    /// Maps a local time (when sound leaves this speaker) to the track position
    /// that should be heard then, including this speaker's echo-monitor trim.
    private func expectation(_ timeline: Timeline) -> (Int64) -> Double {
        let trim = trimMillis / 1000
        return { [unowned self] local in
            timeline.expectedPosition(atLeader: self.leaderTime(fromLocal: local)) + trim
        }
    }

    private func prepareLocally(_ track: TrackSource, position: Double) async {
        activePlayer?.setMuted(false)
        activePlayer?.pause()
        let p = player(for: track)
        activePlayer = p
        refreshResumeReadout()
        do {
            // Include the trim here so Spotify-style players are already at the
            // right spot and `start` is a pure resume, with no seek.
            try await p.prepare(track, position: position + trimMillis / 1000)
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
                position: newTimeline.position + trimMillis / 1000)
    }

    private func stopLocally() {
        activePlayer?.setMuted(false)
        activePlayer?.pause()
        timeline = nil
    }

    private func resyncAfterInterruption() {
        guard let timeline, let p = activePlayer else { return }
        let expected = expectation(timeline)
        let at = HostClock.nowNanos() + 400_000_000
        p.start(outputAtLocalNanos: at, position: expected(at))
    }

    /// Echo monitor asked this speaker to move. Positive = play ahead (earlier).
    private func shiftTimeline(aheadByMillis ms: Double) {
        trimMillis += ms
        guard let timeline, let p = activePlayer, p.isPlaying else { return }
        p.realign(expected: expectation(timeline))
    }

    private func tick() {
        if let timeline, let p = activePlayer, p.isPlaying {
            p.tick(expected: expectation(timeline))
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
                                    routeName: routeName,
                                    resumeLatencyMillis: resumeLatencyMillis,
                                    resumeJitterMillis: resumeJitterMillis,
                                    trimMillis: trimMillis)
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

    // MARK: Resume-delay probe (Spotify-style engines)

    var canMeasureResumeDelay: Bool {
        isLeader && (track?.isRemote ?? false) && timeline == nil && (activePlayer?.isReady ?? false)
    }

    /// Leader: each phone, one at a time, plays about a second from the loaded
    /// position and times its own `resume()` with its own mic. Three rounds,
    /// averaged per phone.
    func measureResumeDelays() {
        guard canMeasureResumeDelay else { return }
        let devices = [myID] + connectedPeers
        var slots: [CalibrationSlot] = []
        var t = HostClock.nowNanos() + 1_500_000_000
        for _ in 0..<3 {
            for id in devices {
                slots.append(CalibrationSlot(peerID: id, leaderTime: t))
                t += 2_500_000_000          // probe takes ~1.7 s, then the next phone
            }
        }
        peer.send(.resumeProbePlan(slots: slots))
        runResumeProbe(slots: slots)
    }

    private func runResumeProbe(slots: [CalibrationSlot]) {
        guard let remote = activePlayer as? RemoteSyncPlayer, remote.isReady, !remote.isPlaying else {
            resumeProbe = .failed("Load a Spotify or simulated-Spotify track first (and don't press play).")
            return
        }
        let mySlots = slots.filter { $0.peerID == myID }.map { localTime(fromLeader: $0.leaderTime) }
        resumeProbe = .running("Measuring resume delay… keep it quiet")
        Task {
            var values: [Double] = []
            for slotTime in mySlots {
                let wait = slotTime - HostClock.nowNanos()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait)) }
                if let v = await remote.measureResumeLatencyOnce(engine: localPlayer.engine) {
                    values.append(v)
                }
            }
            if let s = remote.applyResumeMeasurements(values) {
                resumeProbe = .done(String(format: "Resume delay %.0f ms ± %.0f ms (%d of %d heard)",
                                           s.mean, s.sd, values.count, mySlots.count))
            } else {
                resumeProbe = .failed("Couldn't hear this speaker start. Turn it up, or pick a part of the song that isn't silent.")
            }
            refreshResumeReadout()
        }
    }

    private func refreshResumeReadout() {
        if let remote = activePlayer as? RemoteSyncPlayer {
            resumeLatencyMillis = remote.resumeLatencyMillis
            resumeJitterMillis = remote.resumeJitterMillis
        } else {
            resumeLatencyMillis = nil
            resumeJitterMillis = nil
        }
    }

    // MARK: Echo monitor (leader)

    private func echoMonitorChanged() {
        monitorTask?.cancel()
        monitorTask = nil
        guard echoMonitorEnabled, isLeader else { return }
        logEcho("Echo monitor on: checking every \(echoInterval) s while music plays")
        monitorTask = Task { [weak self] in
            var turn = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.echoCheck(turn: turn)
                turn += 1
                try? await Task.sleep(nanoseconds: self.echoInterval * 1_000_000_000)
            }
        }
    }

    /// One check of one follower against this (the leader's) speaker.
    private func echoCheck(turn: Int) async {
        guard isLeader, timeline != nil, let p = activePlayer, p.isPlaying else { return }
        let followers = connectedPeers.filter { peerStatuses[$0]?.playing == true }
        guard !followers.isEmpty else {
            logEcho("Waiting for another speaker to play")
            return
        }
        let target = followers[turn % followers.count]
        let others = followers.filter { $0 != target }
        if !others.isEmpty && !p.canMute {
            logEcho("With Spotify the echo monitor needs exactly 2 phones (Spotify can't be muted)")
            return
        }
        guard let targetPeer = peerID(named: target) else { return }
        let listener = monitorListenerID.isEmpty ? myID : monitorListenerID

        // With 3+ phones, silence the rest so the mic hears one pair.
        let mutedPeers = others.compactMap { peerID(named: $0) }
        if !mutedPeers.isEmpty {
            peer.send(.mute(true), to: mutedPeers)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        defer { if !mutedPeers.isEmpty { peer.send(.mute(false), to: mutedPeers) } }

        let first = await requestEcho(from: listener, candidatesMillis: [])
        switch corrector.assess(first?.strongest) {
        case .noSignal:
            logEcho("\(target): no clear echo (within ~4 ms, or too quiet)")
        case .inSync(let lag):
            logEcho(String(format: "%@: %.0f ms apart, under %.0f ms, left alone", target, lag, corrector.thresholdMillis))
        case .reflection(let lag):
            logEcho(String(format: "%@: peak at %.0f ms is a room reflection, ignored", target, lag))
        case let .needsDirection(lag, nudge):
            // Which one is ahead? Nudge the follower ahead and see where the echo goes.
            peer.send(.shift(aheadByMillis: nudge), to: [targetPeer])
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let candidates = corrector.candidateLags(lagMillis: lag, nudgeMillis: nudge)
            let second = await requestEcho(from: listener, candidatesMillis: candidates)
            switch corrector.resolve(lagMillis: lag, nudgeMillis: nudge, peaks: second?.candidatePeaks ?? []) {
            case let .error(now, before):
                peer.send(.shift(aheadByMillis: -now), to: [targetPeer])
                logEcho(String(format: "%@ was %.0f ms %@: corrected", target, abs(before), before > 0 ? "ahead" : "behind"))
            case .inconclusive:
                peer.send(.shift(aheadByMillis: -nudge), to: [targetPeer])
                logEcho(String(format: "%@: %.0f ms echo didn't follow the nudge, undone", target, lag))
            }
        }
    }

    private func requestEcho(from listener: String, candidatesMillis: [Double]) async -> EchoReading? {
        if listener == myID { return await measureEcho(candidatesMillis: candidatesMillis) }
        guard let listenerPeer = peerID(named: listener) else { return nil }
        echoRequestID &+= 1
        let id = echoRequestID
        return await withCheckedContinuation { (cont: CheckedContinuation<EchoReading?, Never>) in
            echoWaiters[id] = cont
            peer.send(.echoMeasure(id: id, candidatesMillis: candidatesMillis), to: [listenerPeer])
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.finishEchoRequest(id, nil)
            }
        }
    }

    private func finishEchoRequest(_ id: UInt32, _ reading: EchoReading?) {
        echoWaiters.removeValue(forKey: id)?.resume(returning: reading)
    }

    /// Listener: record 4 s of whatever the speakers are playing and find the echo.
    private func measureEcho(candidatesMillis: [Double]) async -> EchoReading? {
        do { try localPlayer.ensureRunning() } catch { return nil }
        let recorder = MicRecorder(engine: localPlayer.engine)
        do { try recorder.start() } catch { return nil }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let recording = recorder.stop() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SessionCoordinator.analyzeEcho(recording, candidatesMillis: candidatesMillis)
        }.value
    }

    nonisolated static func analyzeEcho(_ recording: MicRecorder.Recording, candidatesMillis: [Double]) -> EchoReading? {
        let sr = recording.sampleRate
        guard let cepstrum = DSP.averagedCepstrum(of: recording.samples, sampleRate: sr) else { return nil }
        func peak(_ e: DSP.EchoEstimate?) -> EchoPeak? {
            e.map { EchoPeak(lagMillis: $0.lagSeconds * 1000, strength: $0.strength) }
        }
        let tolerance = EchoCorrector().candidateToleranceMillis / 1000
        return EchoReading(
            strongest: peak(DSP.strongestEcho(in: cepstrum, sampleRate: sr)),
            candidatePeaks: candidatesMillis.map {
                peak(DSP.echoPeak(in: cepstrum, sampleRate: sr, near: $0 / 1000, tolerance: tolerance))
            })
    }

    private func logEcho(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        echoLog.insert("\(time)  \(line)", at: 0)
        if echoLog.count > 8 { echoLog.removeLast() }
    }

    private func peerID(named name: String) -> MCPeerID? {
        peer.connectedPeers.first { $0.displayName == name }
    }

    // MARK: Spotify

    func connectSpotify() { spotifyBackend.authorize() }

    func handleOpenURL(_ url: URL) {
        _ = spotifyBackend.handle(url: url)
    }

    func appBecameActive() {
        spotifyBackend.reconnectIfNeeded()
    }
}
