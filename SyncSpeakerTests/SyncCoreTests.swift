import XCTest
@testable import SyncSpeaker

/// Unit tests for the pure sync logic. The same algorithms are stress-tested
/// with noisier models in sim/simulate.py.
final class ClockSyncTests: XCTestCase {

    func testRecoversOffsetAndSkewThroughAsymmetricJitter() {
        var cs = ClockSync()
        var rng = SystemRandomNumberGenerator()
        let offset: Int64 = 12_345_000_000          // follower is 12.345 s behind
        let skew = 35e-6
        func toLocal(_ t: Double) -> Int64 { Int64(t * (1 + skew)) - offset }

        var t = 0.0
        for _ in 0..<600 {                           // 60 s at 10 Hz
            // Queueing spikes 60% of the time, bigger on the way back.
            let up = Double.random(in: 0...1, using: &rng) < 0.6 ? Double.random(in: 0...20e6, using: &rng) : 0
            let down = 5e6 + (Double.random(in: 0...1, using: &rng) < 0.6 ? Double.random(in: 0...40e6, using: &rng) : 0)
            let t1 = toLocal(t)
            let t2 = Int64(t + 4e6 + up)
            let t3 = t2 + 200_000
            let t4 = toLocal(Double(t3) + down)
            cs.addExchange(t1: t1, t2: t2, t3: t3, t4: t4)
            t += 100e6
        }

        XCTAssertTrue(cs.isSynced)
        let probe = t + 50e6
        let error = Double(cs.leaderTime(fromLocal: toLocal(probe))) - probe
        XCTAssertLessThan(abs(error) / 1e6, 3.0, "clock error should be a few ms at most")

        // Round trip local -> leader -> local should be exact to within a microsecond.
        let local = toLocal(probe)
        XCTAssertLessThan(abs(cs.localTime(fromLeader: cs.leaderTime(fromLocal: local)) - local), 1_000)
    }

    func testIgnoresNegativeRTT() {
        var cs = ClockSync()
        cs.addExchange(t1: 100, t2: 50, t3: 1_000, t4: 200)   // rtt < 0
        XCTAssertEqual(cs.samples.count, 0)
    }
}

final class DriftControllerTests: XCTestCase {
    func testConvergesWithClockDrift() {
        var ctl = DriftController()
        var error = 0.015, rate = 1.0
        for _ in 0..<720 {                           // 6 minutes at 2 Hz
            error += ((1 + 60e-6) * rate - 1) * 0.5
            rate = ctl.update(error: error, dt: 0.5) ?? 1
        }
        XCTAssertLessThan(abs(error), 0.002)
        XCTAssertLessThanOrEqual(abs(rate - 1), 0.002)
    }

    func testAsksForReseekOnLargeError() {
        var ctl = DriftController()
        XCTAssertNil(ctl.update(error: 0.2, dt: 0.5))
    }
}

final class DSPTests: XCTestCase {

    func testDetectsChirpToSubMillisecond() throws {
        let sr = 48_000.0
        let chirp = DSP.chirp(sampleRate: sr)
        var signal = [Float](repeating: 0, count: Int(sr * 0.6))
        let trueStart = 13_337
        for i in 0..<chirp.count { signal[trueStart + i] += 0.1 * chirp[i] }
        for i in signal.indices { signal[i] += Float.random(in: -0.02...0.02) }

        let hit = try XCTUnwrap(DSP.detect(template: chirp, in: signal))
        XCTAssertEqual(hit.sampleIndex, Double(trueStart), accuracy: 2)   // 2 samples ≈ 0.04 ms
        XCTAssertGreaterThan(hit.confidence, Calibrator.minConfidence)
    }

    func testFindsEchoLag() throws {
        let sr = 48_000.0
        let n = Int(sr * 4)
        // Broadband "music": noise bursts with a changing spectrum.
        var music = [Float](repeating: 0, count: n)
        var prev: Float = 0
        for i in 0..<n {
            let x = Float.random(in: -1...1)
            prev = 0.7 * prev + 0.3 * x
            music[i] = (i / 6_000) % 2 == 0 ? x : prev
        }
        let lag = 2_400                               // 50 ms
        var mix = music
        for i in lag..<n { mix[i] += 0.8 * music[i - lag] }

        let est = try XCTUnwrap(DSP.echoLag(in: mix, sampleRate: sr))
        XCTAssertEqual(est.lagSeconds, 0.050, accuracy: 0.001)
    }
}

final class CalibratorTests: XCTestCase {

    func testCorrectionsAreRelativeAndRecoverLateness() throws {
        let sr = 48_000.0
        let chirp = DSP.chirp(sampleRate: sr)
        let slots = Calibrator.plan(deviceIDs: ["A", "B"], startingAtLeader: 0)
        let late: [String: Double] = ["A": 0.012, "B": 0.040]       // seconds

        let end = Calibrator.endTime(of: slots)
        var samples = [Float](repeating: 0, count: Int(end.nanosToSeconds * sr) + 10_000)
        for slot in slots {
            let start = Int((slot.leaderTime.nanosToSeconds + late[slot.peerID]!) * sr)
            for i in 0..<chirp.count { samples[start + i] += 0.2 * chirp[i] }
        }
        let rec = MicRecorder.Recording(samples: samples, sampleRate: sr, firstSampleLocalNanos: 0)

        let result = Calibrator.analyze(recording: rec, template: chirp, slots: slots,
                                        toLeader: { $0 }, toLocal: { $0 })
        XCTAssertEqual(result.missedSlots, 0)
        // Mean lateness is 26 ms, so A should move -14 ms and B +14 ms.
        XCTAssertEqual(try XCTUnwrap(result.corrections["A"]), -14, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(result.corrections["B"]), 14, accuracy: 0.1)
    }
}
