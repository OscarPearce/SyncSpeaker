import Foundation

/// Builds calibration plans and turns a listener's recording into per-device
/// corrections. See "Calibration" in DESIGN.md.
enum Calibrator {
    static let leadIn: Int64 = 1_500_000_000        // first chirp 1.5 s after the plan is sent
    static let slotSpacing: Int64 = 600_000_000     // 0.6 s between chirps (lets reverb die down)
    static let rounds = 3
    static let minConfidence: Float = 8

    /// Every device chirps once per round, in turn.
    static func plan(deviceIDs: [String], startingAtLeader now: Int64) -> [CalibrationSlot] {
        var slots: [CalibrationSlot] = []
        var t = now + leadIn
        for _ in 0..<rounds {
            for id in deviceIDs {
                slots.append(CalibrationSlot(peerID: id, leaderTime: t))
                t += slotSpacing
            }
        }
        return slots
    }

    static func endTime(of slots: [CalibrationSlot]) -> Int64 {
        (slots.map(\.leaderTime).max() ?? 0) + slotSpacing
    }

    struct Result {
        /// ms to add to each device's residual delay (positive = it was late).
        var corrections: [String: Double]
        /// Raw lateness per device, one value per detected round (ms). For the debug screen.
        var latenessByDevice: [String: [Double]]
        var missedSlots: Int
    }

    /// - Parameters:
    ///   - recording: the listener's mic recording.
    ///   - template: the chirp, at the recording's sample rate.
    ///   - toLeader: converts listener-local ns to leader ns.
    static func analyze(recording: MicRecorder.Recording,
                        template: [Float],
                        slots: [CalibrationSlot],
                        toLeader: (Int64) -> Int64,
                        toLocal: (Int64) -> Int64) -> Result {
        var lateness: [String: [Double]] = [:]
        var missed = 0
        let before: Int64 = 100_000_000          // search 100 ms before the slot…
        let after = slotSpacing - before         // …up to the next slot

        for slot in slots {
            let lo = recording.sampleIndex(atLocal: toLocal(slot.leaderTime - before))
            let hi = recording.sampleIndex(atLocal: toLocal(slot.leaderTime + after))
            guard lo >= 0, hi <= recording.samples.count, hi - lo > template.count else {
                missed += 1
                continue
            }
            let window = Array(recording.samples[lo..<hi])
            guard let hit = DSP.detect(template: template, in: window),
                  hit.confidence >= minConfidence else {
                missed += 1
                continue
            }
            let arrivalLocal = recording.localNanos(atSample: Double(lo) + hit.sampleIndex)
            let late = (toLeader(arrivalLocal) - slot.leaderTime).nanosToMillis
            lateness[slot.peerID, default: []].append(late)
        }

        // Median per device resists one bad round.
        var medians: [String: Double] = [:]
        for (id, values) in lateness {
            let s = values.sorted()
            medians[id] = s[s.count / 2]
        }

        // Only relative timing matters: anything common to every device
        // (the listener's input latency, distance to the room centre) cancels.
        let mean = medians.values.reduce(0, +) / Double(max(medians.count, 1))
        let corrections = medians.mapValues { $0 - mean }
        return Result(corrections: corrections, latenessByDevice: lateness, missedSlots: missed)
    }
}
