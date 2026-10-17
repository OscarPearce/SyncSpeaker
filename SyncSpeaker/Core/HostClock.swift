import Foundation
import Darwin

/// The single local clock every part of the app uses.
///
/// It is `mach_absolute_time()`, the same clock Core Audio uses for
/// `AVAudioTime.hostTime`, so a timestamp from here can be handed straight to
/// `AVAudioPlayerNode.play(at:)` without converting between clocks.
///
/// All "time" values in the app are `Int64` nanoseconds on this clock unless a
/// name says otherwise.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Current local time in nanoseconds.
    static func nowNanos() -> Int64 {
        nanos(fromHostTicks: mach_absolute_time())
    }

    static func nanos(fromHostTicks ticks: UInt64) -> Int64 {
        // ticks * numer / denom, done in 128-bit-safe steps to avoid overflow.
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return Int64(ticks) }
        let whole = (ticks / denom) * numer
        let rem = (ticks % denom) * numer / denom
        return Int64(whole + rem)
    }

    static func hostTicks(fromNanos nanos: Int64) -> UInt64 {
        let n = UInt64(max(0, nanos))
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        if numer == denom { return n }
        let whole = (n / numer) * denom
        let rem = (n % numer) * denom / numer
        return whole + rem
    }
}

extension Int64 {
    var nanosToSeconds: Double { Double(self) / 1_000_000_000 }
    var nanosToMillis: Double { Double(self) / 1_000_000 }
}

extension Double {
    var secondsToNanos: Int64 { Int64((self * 1_000_000_000).rounded()) }
    var millisToNanos: Int64 { Int64((self * 1_000_000).rounded()) }
}
