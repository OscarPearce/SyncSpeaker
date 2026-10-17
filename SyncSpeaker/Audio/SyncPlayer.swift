import Foundation

/// "Track position `position` comes out of the speakers at leader time `leaderStart`."
struct Timeline: Equatable {
    let leaderStart: Int64
    let position: Double

    func expectedPosition(atLeader t: Int64) -> Double {
        position + (t - leaderStart).nanosToSeconds
    }
}

/// A playback source that can be started at a precise moment and corrected.
@MainActor
protocol SyncPlayer: AnyObject {
    var isReady: Bool { get }
    var isPlaying: Bool { get }
    /// Last measured timeline error in ms (positive = this speaker is ahead).
    var lastErrorMillis: Double? { get }
    /// Current playback-rate trim (1.0 = none). Nil if the engine can't trim.
    var currentRate: Double? { get }

    func prepare(_ track: TrackSource, position: Double) async throws
    /// Start so that `position` comes out of the speaker at local time `outputAtLocalNanos`.
    func start(outputAtLocalNanos: Int64, position: Double)
    func pause()
    /// Called about twice a second while playing. `expected` maps a local time
    /// (when sound leaves the speaker) to the timeline position that should be heard then.
    func tick(expected: (Int64) -> Double)
}

/// Turns timeline error into a tiny playback-rate trim.
///
/// Gains are tuned in `sim/simulate.py` (`sim_drift`): with 60 ppm of clock
/// drift and 1 ms of measurement noise it holds the error under ~1 ms, and the
/// rate wobbles by about 0.02% (≈0.4 cents of pitch; inaudible).
struct DriftController {
    var kp = 0.2
    var ki = 0.02
    /// Largest rate change allowed: 0.2% ≈ 3.5 cents.
    var maxDeviation = 0.002
    /// Errors larger than this are fixed by re-seeking instead.
    var reseekThreshold = 0.080

    private var integral = 0.0

    mutating func reset() { integral = 0 }

    /// - Parameters:
    ///   - error: actual − expected position, seconds.
    ///   - dt: seconds since the last update.
    /// - Returns: new rate, or nil if the caller should re-seek.
    mutating func update(error: Double, dt: Double) -> Double? {
        if abs(error) > reseekThreshold {
            integral = 0
            return nil
        }
        integral = min(max(integral + error * dt, -0.2), 0.2)
        let u = kp * error + ki * integral
        return 1 - min(max(u, -maxDeviation), maxDeviation)
    }
}
