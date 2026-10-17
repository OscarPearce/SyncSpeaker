import Foundation
import Accelerate

/// Signal-processing building blocks for calibration and the echo check.
/// Each function has a numpy twin in `sim/simulate.py`, which is where the
/// algorithms are tested against synthetic rooms and noise.
enum DSP {

    // MARK: Chirp

    /// Linear sine sweep with short raised-cosine fades so it doesn't click.
    static func chirp(sampleRate: Double,
                      duration: Double = 0.15,
                      startHz: Double = 1_500,
                      endHz: Double = 8_000,
                      fade: Double = 0.005,
                      amplitude: Float = 0.6) -> [Float] {
        let n = Int(duration * sampleRate)
        let fadeN = max(1, Int(fade * sampleRate))
        let k = (endHz - startHz) / duration
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            let phase = 2 * Double.pi * (startHz * t + 0.5 * k * t * t)
            var env = 1.0
            if i < fadeN { env = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeN)) }
            if i >= n - fadeN { env = 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fadeN)) }
            return amplitude * Float(sin(phase) * env)
        }
    }

    // MARK: Matched filter

    struct Detection {
        /// Index into the searched signal where the template starts (fractional).
        let sampleIndex: Double
        /// Peak height divided by the median correlation magnitude.
        let confidence: Float
    }

    /// Finds where `template` occurs in `signal` using FFT cross-correlation.
    /// Returns nil if the signal is shorter than the template.
    static func detect(template: [Float], in signal: [Float]) -> Detection? {
        guard signal.count >= template.count, !template.isEmpty else { return nil }
        let corr = crossCorrelate(signal: signal, template: template)
        var mags = corr.map { abs($0) }
        guard let best = argmax(mags) else { return nil }
        let (peak, value) = best

        let refined = Double(peak) + parabolicOffset(mags, at: peak)
        mags.sort()
        let median = max(mags[mags.count / 2], 1e-12)
        return Detection(sampleIndex: refined, confidence: value / median)
    }

    /// r[k] = Σ signal[n + k] · template[n], for k in 0 ... signal.count − template.count.
    static func crossCorrelate(signal: [Float], template: [Float]) -> [Float] {
        let n = nextPowerOfTwo(signal.count + template.count)
        guard let fft = ComplexFFT(n: n) else { return [] }

        let (sr, si) = fft.forward(padded(signal, to: n))
        let (tr, ti) = fft.forward(padded(template, to: n))

        // X · conj(H)
        var pr = [Float](repeating: 0, count: n)
        var pi = [Float](repeating: 0, count: n)
        for i in 0..<n {
            pr[i] = sr[i] * tr[i] + si[i] * ti[i]
            pi[i] = si[i] * tr[i] - sr[i] * ti[i]
        }
        let (rr, _) = fft.inverse(real: pr, imag: pi)
        let valid = signal.count - template.count + 1
        let scale = 1 / Float(n)
        return (0..<valid).map { rr[$0] * scale }
    }

    // MARK: Echo check (cepstrum)

    struct EchoEstimate {
        let lagSeconds: Double
        /// Peak height in standard deviations above the search range's mean.
        let strength: Float
    }

    /// Estimates the delay between two copies of the same audio mixed together,
    /// e.g. two speakers playing one song slightly out of sync.
    ///
    /// Uses the power cepstrum, averaged over overlapping frames. Musical pitch
    /// also makes cepstral peaks, but pitch changes from frame to frame while
    /// the echo lag stays put, so averaging favours the echo.
    ///
    /// The cepstrum can't tell which copy is ahead; resolve that by nudging one
    /// player and re-measuring (see DESIGN.md).
    static func echoLag(in signal: [Float],
                        sampleRate: Double,
                        minLag: Double = 0.004,
                        maxLag: Double = 0.300,
                        frameLength: Int = 32_768) -> EchoEstimate? {
        let hop = frameLength / 2
        let maxLagN = Int(maxLag * sampleRate)
        let minLagN = max(1, Int(minLag * sampleRate))
        guard signal.count >= frameLength, maxLagN < frameLength / 2,
              let fft = ComplexFFT(n: frameLength) else { return nil }

        let window = hann(frameLength)
        var avg = [Float](repeating: 0, count: maxLagN + 1)
        var frames = 0
        var start = 0
        while start + frameLength <= signal.count {
            let frame = vDSP.multiply(Array(signal[start ..< start + frameLength]), window)
            let (re, im) = fft.forward(frame)
            // log power spectrum
            var logP = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength { logP[i] = log(re[i] * re[i] + im[i] * im[i] + 1e-10) }
            let (cep, _) = fft.inverse(real: logP, imag: [Float](repeating: 0, count: frameLength))
            for q in 0...maxLagN { avg[q] += cep[q] / Float(frameLength) }
            frames += 1
            start += hop
        }
        guard frames > 0 else { return nil }

        let range = Array(avg[minLagN...maxLagN])
        guard let best = argmax(range) else { return nil }
        let (i, peak) = best
        let mean = range.reduce(0, +) / Float(range.count)
        let variance = range.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(range.count)
        let sd = max(variance.squareRoot(), 1e-12)

        let lag = Double(minLagN + i) + parabolicOffset(range, at: i)
        return EchoEstimate(lagSeconds: lag / sampleRate, strength: (peak - mean) / sd)
    }

    // MARK: Helpers

    static func nextPowerOfTwo(_ x: Int) -> Int {
        var n = 1
        while n < x { n <<= 1 }
        return n
    }

    static func padded(_ x: [Float], to n: Int) -> [Float] {
        x.count >= n ? Array(x.prefix(n)) : x + [Float](repeating: 0, count: n - x.count)
    }

    static func hann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
    }

    static func argmax(_ x: [Float]) -> (Int, Float)? {
        guard !x.isEmpty else { return nil }
        var best = 0
        for i in 1..<x.count where x[i] > x[best] { best = i }
        return (best, x[best])
    }

    /// Sub-sample peak position from a parabola through the peak and its neighbours.
    static func parabolicOffset(_ y: [Float], at i: Int) -> Double {
        guard i > 0, i < y.count - 1 else { return 0 }
        let a = Double(y[i - 1]), b = Double(y[i]), c = Double(y[i + 1])
        let denom = a - 2 * b + c
        guard abs(denom) > 1e-12 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (a - c) / denom))
    }
}

/// Complex-to-complex DFT of a power-of-two length, wrapping vDSP_DFT_zop.
final class ComplexFFT {
    let n: Int
    private let forwardSetup: OpaquePointer
    private let inverseSetup: OpaquePointer

    init?(n: Int) {
        guard n > 0, n & (n - 1) == 0,
              let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), vDSP_DFT_Direction.FORWARD),
              let i = vDSP_DFT_zop_CreateSetup(f, vDSP_Length(n), vDSP_DFT_Direction.INVERSE)
        else { return nil }
        self.n = n
        forwardSetup = f
        inverseSetup = i
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func forward(_ real: [Float]) -> ([Float], [Float]) {
        execute(forwardSetup, real: real, imag: [Float](repeating: 0, count: n))
    }

    /// Unnormalised inverse: divide by `n` yourself.
    func inverse(real: [Float], imag: [Float]) -> ([Float], [Float]) {
        execute(inverseSetup, real: real, imag: imag)
    }

    private func execute(_ setup: OpaquePointer, real: [Float], imag: [Float]) -> ([Float], [Float]) {
        precondition(real.count == n && imag.count == n)
        var outR = [Float](repeating: 0, count: n)
        var outI = [Float](repeating: 0, count: n)
        real.withUnsafeBufferPointer { rp in
            imag.withUnsafeBufferPointer { ip in
                outR.withUnsafeMutableBufferPointer { orp in
                    outI.withUnsafeMutableBufferPointer { oip in
                        vDSP_DFT_Execute(setup, rp.baseAddress!, ip.baseAddress!,
                                         orp.baseAddress!, oip.baseAddress!)
                    }
                }
            }
        }
        return (outR, outI)
    }
}
