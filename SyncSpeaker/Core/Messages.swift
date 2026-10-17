import Foundation

/// Which playback source a track comes from.
enum TrackSource: Codable, Hashable {
    /// A file bundled with the app or imported by the user. Every phone must
    /// have a file with the same `id` (the file name is used as the id).
    case local(id: String, title: String)
    /// A Spotify track URI, e.g. "spotify:track:4uLU6hMCjMI75M1A2tKUQC".
    case spotify(uri: String, title: String)
    /// A local file played through `SimulatedSpotifyBackend`: Spotify's sync
    /// path (commands only, random delays) without needing Spotify.
    case simulatedSpotify(id: String, title: String)

    var title: String {
        switch self {
        case .local(_, let t), .spotify(_, let t), .simulatedSpotify(_, let t): return t
        }
    }

    /// True for sources we can only command (resume / pause / seek).
    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }
}

enum PeerRole: String, Codable {
    case leader, follower
}

struct CalibrationSlot: Codable, Hashable {
    let peerID: String          // MCPeerID.displayName of the device that plays this slot
    let leaderTime: Int64       // when the chirp should come out of the speaker, leader ns
}

/// A cepstral peak: an echo between two speakers at `lagMillis` apart.
struct EchoPeak: Codable, Hashable {
    var lagMillis: Double
    /// Height in standard deviations above the search range's mean.
    var strength: Float
}

/// One echo measurement by the listening phone. See `EchoCorrector`.
struct EchoReading: Codable, Hashable {
    /// Strongest echo anywhere in the search range.
    var strongest: EchoPeak?
    /// Strongest echo near each requested candidate lag (same order).
    var candidatePeaks: [EchoPeak?]
}

/// Everything sent between phones. Encoded as JSON (small, debuggable).
enum SyncMessage: Codable {
    // Discovery
    case hello(name: String, role: PeerRole)

    // Clock sync (sent unreliably)
    case ping(id: UInt32, t1: Int64)
    case pong(id: UInt32, t1: Int64, t2: Int64, t3: Int64)

    // Playback control (leader -> followers)
    case load(track: TrackSource, position: Double)
    case startAt(leaderTime: Int64, position: Double)
    case pause

    // Calibration
    case calibrationPlan(listenerID: String, slots: [CalibrationSlot])
    /// Correction to add to each device's residual delay, in ms (positive = that
    /// speaker was late and should start earlier).
    case calibrationResult(correctionsMillis: [String: Double])

    // Resume-delay probe: each device plays briefly in its slots while the
    // others stay paused, and times its own resume with its own mic.
    case resumeProbePlan(slots: [CalibrationSlot])

    // Echo monitor (leader <-> listener, leader -> one follower)
    /// Listener: record a few seconds and report the echo, scoring `candidatesMillis` too.
    case echoMeasure(id: UInt32, candidatesMillis: [Double])
    case echoResult(id: UInt32, reading: EchoReading?)
    /// Move this speaker ahead by `aheadByMillis` (negative = later), right away.
    /// (Always a jump: a gradual trim would still be under way at the next
    /// echo check and get corrected twice.)
    case shift(aheadByMillis: Double)
    /// Silence this speaker while the echo monitor checks another pair.
    case mute(Bool)

    // Status (followers -> leader, ~1 Hz)
    case status(PeerStatus)

    var isClockSync: Bool {
        switch self {
        case .ping, .pong: return true
        default: return false
        }
    }
}

struct PeerStatus: Codable, Hashable {
    var ready: Bool
    var playing: Bool
    var errorMillis: Double?        // actual - expected timeline position
    var rate: Double?               // current varispeed rate (local engine)
    var clockRMSMillis: Double?     // clock-sync residual
    var routeName: String
    var resumeLatencyMillis: Double? = nil   // learned resume delay (remote engines)
    var resumeJitterMillis: Double? = nil
    var trimMillis: Double? = nil            // echo-monitor correction so far
}

enum MessageCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ message: SyncMessage) throws -> Data {
        try encoder.encode(message)
    }

    static func decode(_ data: Data) throws -> SyncMessage {
        try decoder.decode(SyncMessage.self, from: data)
    }
}
