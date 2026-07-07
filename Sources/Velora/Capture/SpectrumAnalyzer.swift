import Accelerate
import Foundation

/// Turns a window of PCM samples into a small set of normalized frequency-band
/// magnitudes for the HUD waveform, so the bars respond to BOTH loudness and
/// pitch (spectral content) instead of a single RMS scalar.
///
/// Pipeline: last `fftSize` samples → Hann window → real FFT (vDSP) →
/// magnitude spectrum → averaged into `bandCount` log-spaced bands over the
/// voice range → per-band dB normalization to 0…1. Log spacing matches how we
/// hear pitch; a rising voice shifts energy toward the higher bands.
final class SpectrumAnalyzer {
    private let fftSize: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    let bandCount: Int
    private var window: [Float]
    private let bandEdges: [Int]  // bin indices, bandCount+1 of them

    // Normalization: magnitudes below `floorDB` map to 0, at `ceilDB` to 1.
    // Tuned offline against real speech clips (see scripts/tune-spectrum).
    private static let floorDB: Float = -62
    private static let ceilDB: Float = -18

    init(fftSize: Int = 1024, bandCount: Int = 12, sampleRate: Double = 16_000) {
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.bandCount = bandCount
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Log-spaced band edges from 90 Hz to just under Nyquist — the band a
        // speaking voice actually occupies.
        let nyquist = sampleRate / 2
        let minF = 90.0
        let maxF = min(7600.0, nyquist - 1)
        var edges: [Int] = []
        for b in 0...bandCount {
            let f = minF * pow(maxF / minF, Double(b) / Double(bandCount))
            let bin = Int((f / nyquist) * Double(fftSize / 2))
            edges.append(min(max(bin, 1), fftSize / 2 - 1))
        }
        self.bandEdges = edges
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Returns `bandCount` magnitudes in 0…1, low frequency → high frequency.
    func process(_ input: [Float]) -> [Float] {
        var samples = [Float](repeating: 0, count: fftSize)
        let n = min(fftSize, input.count)
        if n > 0 {
            // Right-align the most recent samples (zero-padded at the front).
            for i in 0..<n { samples[fftSize - n + i] = input[input.count - n + i] }
        }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: halfSize)
        var imag = [Float](repeating: 0, count: halfSize)
        var mags = [Float](repeating: 0, count: halfSize)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBytes { raw in
                    let complex = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(halfSize))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Magnitude² per bin; scale for the vDSP_fft_zrip 2x convention.
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfSize))
            }
        }

        var bands = [Float](repeating: 0, count: bandCount)
        let scale = 1.0 / Float(fftSize * fftSize)
        for b in 0..<bandCount {
            let lo = bandEdges[b]
            let hi = max(bandEdges[b + 1], lo + 1)
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            let power = (sum / Float(hi - lo)) * scale
            let db = 10 * log10(power + 1e-12)
            let norm = (db - Self.floorDB) / (Self.ceilDB - Self.floorDB)
            bands[b] = max(0, min(1, norm))
        }
        return bands
    }
}
