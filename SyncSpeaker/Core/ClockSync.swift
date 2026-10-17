import Foundation

/// Estimates the leader's clock from NTP-style ping/pong exchanges.
///
/// Pure logic with no I/O, so it can be unit-tested and mirrored in `sim/simulate.py`.
///
/// For each exchange:
///   t1 = follower send (local)   t2 = leader receive (leader)
///   t3 = leader send (leader)    t4 = follower receive (local)
///   offset = ((t2 - t1) + (t3 - t4)) / 2   // leader - local
///   rtt    = (t4 - t1) - (t3 - t2)
///
/// Samples with RTT close to the window minimum are the ones where neither
/// direction got queued, so only those are trusted. A least-squares line through
/// them tracks crystal skew between the two phones.
struct ClockSync {
    struct Sample {
        let localMid: Int64   // (t1 + t4) / 2, local ns
        let offset: Int64     // leader - local, ns
        let rtt: Int64        // ns
    }

    /// Number of recent exchanges kept.
    var windowSize = 80
    /// A sample is "good" if its RTT is within this much of the window minimum.
    var rttMarginNanos: Int64 = 2_000_000          // 2 ms
    /// Skew is only fitted when good samples span at least this long.
    var minSkewSpanNanos: Int64 = 3_000_000_000    // 3 s
    /// Clamp on fitted skew. Real crystals are within ±50 ppm; anything bigger is noise.
    var maxSkewPPM = 200.0

    private(set) var samples: [Sample] = []

    // Fitted model: offset(t) = intercept + skew * (t - reference)
    private(set) var reference: Int64 = 0
    private(set) var intercept: Double = 0
    private(set) var skew: Double = 0
    private(set) var goodSampleCount = 0
    /// RMS residual of good samples around the fit, ns. A rough accuracy indicator.
    private(set) var residualRMS: Double = .infinity

    var isSynced: Bool { goodSampleCount >= 5 }

    var minRTTNanos: Int64? { samples.map(\.rtt).min() }

    mutating func addExchange(t1: Int64, t2: Int64, t3: Int64, t4: Int64) {
        let rtt = (t4 - t1) - (t3 - t2)
        guard rtt >= 0 else { return }               // clock went backwards or bad packet
        let offset = ((t2 - t1) + (t3 - t4)) / 2
        let mid = t1 + (t4 - t1) / 2
        samples.append(Sample(localMid: mid, offset: offset, rtt: rtt))
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        refit()
    }

    mutating func reset() {
        samples.removeAll()
        goodSampleCount = 0
        intercept = 0
        skew = 0
        residualRMS = .infinity
    }

    /// Leader-clock ns for a local-clock ns.
    func leaderTime(fromLocal local: Int64) -> Int64 {
        local + Int64(offset(atLocal: local).rounded())
    }

    /// Local-clock ns for a leader-clock ns.
    func localTime(fromLeader leader: Int64) -> Int64 {
        // offset varies only by ppm, so two fixed-point iterations are plenty.
        var local = leader - Int64(intercept.rounded())
        for _ in 0..<2 {
            local = leader - Int64(offset(atLocal: local).rounded())
        }
        return local
    }

    func offset(atLocal local: Int64) -> Double {
        intercept + skew * Double(local - reference)
    }

    private mutating func refit() {
        guard let minRTT = minRTTNanos else { return }
        let good = samples.filter { $0.rtt <= minRTT + rttMarginNanos }
        goodSampleCount = good.count
        guard !good.isEmpty else { return }

        reference = good.last!.localMid
        let xs = good.map { Double($0.localMid - reference) }
        let ys = good.map { Double($0.offset) }

        let span = (good.map(\.localMid).max()! - good.map(\.localMid).min()!)
        if good.count >= 3 && span >= minSkewSpanNanos {
            let n = Double(good.count)
            let mx = xs.reduce(0, +) / n
            let my = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for (x, y) in zip(xs, ys) {
                sxx += (x - mx) * (x - mx)
                sxy += (x - mx) * (y - my)
            }
            var b = sxx > 0 ? sxy / sxx : 0
            let limit = maxSkewPPM * 1e-6
            b = min(max(b, -limit), limit)
            skew = b
            intercept = my - b * mx
        } else {
            // Not enough time span to see skew: use the median offset.
            skew = 0
            intercept = ys.sorted()[ys.count / 2]
        }

        let sq = zip(xs, ys).map { x, y -> Double in
            let r = y - (intercept + skew * x)
            return r * r
        }
        residualRMS = (sq.reduce(0, +) / Double(sq.count)).squareRoot()
    }
}
