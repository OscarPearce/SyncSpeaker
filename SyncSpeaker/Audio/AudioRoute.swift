import AVFoundation

/// Audio session setup and per-route latency bookkeeping.
enum AudioRoute {

    /// One configuration for the whole app, so the route (and its latency)
    /// doesn't change between calibrating and playing music.
    ///
    /// - `.playAndRecord` so the listener phone can record calibration chirps.
    /// - `.allowBluetoothA2DP` keeps Bluetooth speakers in high-quality stereo.
    ///   Do NOT add `.allowBluetooth`: that is the hands-free (HFP) profile, and
    ///   it would switch the speaker into low-quality call mode as soon as the
    ///   mic turns on.
    /// - `.measurement` turns off voice processing (AGC, echo cancellation),
    ///   which would otherwise shift and smear the timing of recorded chirps.
    /// - `.mixWithOthers` lets Spotify keep playing while this app is active.
    static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }

    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// What iOS believes the output delay is: output latency plus one IO buffer.
    static var reportedOutputDelayNanos: Int64 {
        let s = AVAudioSession.sharedInstance()
        return (s.outputLatency + s.ioBufferDuration).secondsToNanos
    }

    static var inputLatencyNanos: Int64 {
        AVAudioSession.sharedInstance().inputLatency.secondsToNanos
    }

    static var currentOutput: AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first
    }

    static var routeKey: String { currentOutput?.uid ?? "unknown" }
    static var routeName: String { currentOutput?.portName ?? "Unknown output" }
    static var isBluetooth: Bool { currentOutput?.portType == .bluetoothA2DP }

    // MARK: Calibrated residual delay, stored per output route

    private static let defaultsKey = "routeResidualMillis"

    /// Extra delay beyond `reportedOutputDelayNanos`, learned by calibration.
    static var residualMillis: Double {
        get { (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double])?[routeKey] ?? 0 }
        set {
            var all = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double]) ?? [:]
            all[routeKey] = newValue
            UserDefaults.standard.set(all, forKey: defaultsKey)
        }
    }

    /// Total time from "render this sample" to "sound leaves this speaker".
    static var totalOutputDelayNanos: Int64 {
        reportedOutputDelayNanos + residualMillis.millisToNanos
    }
}
