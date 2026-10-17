import Foundation

/// Decides, from microphone echo measurements taken while music plays, whether
/// a follower's speaker is out of sync with the reference speaker and by how much.
///
/// One check against one follower:
/// 1. Measure the echo lag `L0` between the two speakers (`DSP.strongestEcho`).
///    Under `thresholdMillis` → leave it alone: every correction has its own
///    random error, so correcting small offsets makes sync worse, not better.
/// 2. The lag doesn't say which speaker is ahead, so move the follower ahead by
///    a known `nudge` and measure again. If the follower was ahead (error +L0)
///    the echo moves to about `L0 + nudge`; if it was behind (−L0), to about
///    `|L0 − nudge|`. The listener reports the strongest peak near each, and
///    the stronger one gives the sign.
/// 3. Correct once, using the lag measured *after* the nudge, so any error in
///    the nudge itself (a Spotify seek lands ~10 ms off) is corrected too.
///
/// A cepstral peak that doesn't move when the follower is nudged isn't the
/// other speaker; it's a room reflection. Those lags are remembered and skipped.
///
/// Pure logic, mirrored by `EchoCorrector` in sim/simulate.py.
struct EchoCorrector {
    /// Only correct offsets larger than this.
    var thresholdMillis = 20.0
    /// Echo peaks weaker than this (standard deviations) are treated as "no reading".
    var minStrength: Float = 4
    /// After a nudge, the winning candidate must beat the other by this many sd.
    var decisionMargin: Float = 1.5
    /// Lags within this distance count as "the same peak" (reflection memory).
    var sameLagMillis = 2.0
    /// Echo search range (matches `DSP.echoLag` defaults).
    var minLagMillis = 4.0
    var maxLagMillis = 300.0
    /// Half-width of the search window around each candidate after a nudge.
    /// Must stay under half the gap between candidates (≥ 40 ms, see `nudgeSize`).
    var candidateToleranceMillis = 12.0

    private(set) var reflectionLagsMillis: [Double] = []

    enum Assessment: Equatable {
        /// No clear echo: speakers too quiet, or already within ~4 ms.
        case noSignal
        case inSync(lagMillis: Double)
        /// The peak is at a lag already identified as a room reflection.
        case reflection(lagMillis: Double)
        /// Out of sync by `lagMillis`; nudge the follower ahead by `nudgeMillis` to find the sign.
        case needsDirection(lagMillis: Double, nudgeMillis: Double)
    }

    enum Resolution: Equatable {
        /// The follower's error now, after the nudge, ms (positive = ahead).
        /// Shift it by `-now` to fix it. `beforeNudge` is for display.
        case error(now: Double, beforeNudge: Double)
        case inconclusive
    }

    func assess(_ strongest: EchoPeak?) -> Assessment {
        guard let peak = strongest, peak.strength >= minStrength else { return .noSignal }
        let lag = peak.lagMillis
        if lag < thresholdMillis { return .inSync(lagMillis: lag) }
        if reflectionLagsMillis.contains(where: { abs($0 - lag) <= sameLagMillis }) {
            return .reflection(lagMillis: lag)
        }
        return .needsDirection(lagMillis: lag, nudgeMillis: nudgeSize(forLag: lag))
    }

    /// Smallest nudge that keeps both candidate lags measurable. Since
    /// lag ≥ 20 and nudge ≥ 25, the candidates are ≥ 40 ms apart.
    func nudgeSize(forLag lag: Double) -> Double {
        for nudge in [25.0, 40.0, 60.0] {
            let plus = lag + nudge
            let minus = abs(lag - nudge)
            if minus >= minLagMillis + sameLagMillis * 2, plus <= maxLagMillis { return nudge }
        }
        return 25
    }

    /// Where the echo should be after the nudge: [if follower was ahead, if it was behind].
    func candidateLags(lagMillis: Double, nudgeMillis: Double) -> [Double] {
        [lagMillis + nudgeMillis, abs(lagMillis - nudgeMillis)]
    }

    /// - Parameter peaks: strongest echo near each of `candidateLags(...)`, measured after the nudge.
    mutating func resolve(lagMillis: Double, nudgeMillis: Double, peaks: [EchoPeak?]) -> Resolution {
        guard peaks.count == 2 else { return .inconclusive }
        let ahead = peaks[0], behind = peaks[1]
        let aheadStrength = ahead?.strength ?? 0
        let behindStrength = behind?.strength ?? 0

        if max(aheadStrength, behindStrength) < minStrength {
            // The peak didn't follow the nudge: it's a reflection, not the speaker.
            rememberReflection(lagMillis)
            return .inconclusive
        }
        if let ahead, aheadStrength >= behindStrength + decisionMargin {
            // Was ahead by L0; now ahead by about L0 + nudge.
            let now = ahead.lagMillis
            return .error(now: now, beforeNudge: now - nudgeMillis)
        }
        if let behind, behindStrength >= aheadStrength + decisionMargin {
            // Was behind by L0; now at nudge − L0, which is ahead if nudge > L0.
            let now = nudgeMillis >= lagMillis ? behind.lagMillis : -behind.lagMillis
            return .error(now: now, beforeNudge: now - nudgeMillis)
        }
        return .inconclusive
    }

    mutating func forgetReflections() { reflectionLagsMillis.removeAll() }

    private mutating func rememberReflection(_ lag: Double) {
        reflectionLagsMillis.append(lag)
        if reflectionLagsMillis.count > 6 { reflectionLagsMillis.removeFirst() }
    }
}
