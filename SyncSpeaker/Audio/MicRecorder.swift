import AVFoundation

/// Records the mic with a host-clock timestamp for the first sample, so any
/// sample can be mapped back to the moment it reached the microphone.
final class MicRecorder {
    struct Recording {
        let samples: [Float]
        let sampleRate: Double
        /// Local ns when samples[0] reached the microphone.
        let firstSampleLocalNanos: Int64

        func localNanos(atSample index: Double) -> Int64 {
            firstSampleLocalNanos + (index / sampleRate).secondsToNanos
        }

        func sampleIndex(atLocal t: Int64) -> Int {
            Int(((t - firstSampleLocalNanos).nanosToSeconds * sampleRate).rounded())
        }
    }

    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstHostNanos: Int64?
    private var nextSampleTime: AVAudioFramePosition?
    private var droppedFrames = false
    private var sampleRate: Double = 0

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        firstHostNanos = nil
        nextSampleTime = nil
        droppedFrames = false
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let inputLatency = AudioRoute.inputLatencyNanos

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, when in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.firstHostNanos == nil, when.isHostTimeValid {
                // The buffer's host time is when it was captured; the sound hit
                // the mic `inputLatency` earlier.
                self.firstHostNanos = HostClock.nanos(fromHostTicks: when.hostTime) - inputLatency
            }
            guard self.firstHostNanos != nil else { return }   // wait for a timestamped buffer
            if let expected = self.nextSampleTime, when.isSampleTimeValid, when.sampleTime != expected {
                self.droppedFrames = true
            }
            if when.isSampleTimeValid { self.nextSampleTime = when.sampleTime + AVAudioFramePosition(n) }
            self.samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Stops recording. Returns nil if no timestamp arrived or frames were dropped
    /// (a gap would break the sample-index-to-time mapping).
    func stop() -> Recording? {
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        defer { lock.unlock() }
        guard let first = firstHostNanos, !droppedFrames, !samples.isEmpty else { return nil }
        return Recording(samples: samples, sampleRate: sampleRate, firstSampleLocalNanos: first)
    }
}
