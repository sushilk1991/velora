import AVFoundation
import Foundation

/// Microphone capture: a directly selected AVCaptureDevice converted to 16 kHz mono
/// Float32, delivered as ~100 ms chunks (1600 samples / 6400 bytes) for the
/// engine, plus normalized RMS levels for the HUD waveform.
///
/// Chunk callbacks fire on a private serial queue (callers forward to their
/// own queue); level callbacks are delivered on the main queue.
final class AudioCapture {
    /// Output format required by the engine (docs/ARCHITECTURE.md).
    static let sampleRate: Double = 16_000
    /// ~100 ms at 16 kHz.
    private static let chunkFrames = 1600

    private let source = MicrophoneStreamCapture()
    private(set) var isRunning = false
    private var isStarting = false
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Called (main queue) when the directly selected capture device stops or
    /// disappears mid-recording.
    var onDeviceLost: ((String) -> Void)?

    /// All pending-buffer state below is confined to `bufferQueue`: the tap
    /// callback (audio thread) hops onto it to accumulate/emit, and `stop()`
    /// drains it synchronously — no concurrent Array mutation.
    private let bufferQueue = DispatchQueue(label: "com.velora.capture.buffer")
    private var pending: [Float] = []
    private var chunkHandler: ((Data) -> Void)?
    private var levelHandler: (([Float]) -> Void)?

    /// FFT window fed the spectrum analyzer; a ~1024-sample rolling buffer with
    /// a short hop so the HUD updates ~30x/s (lively) instead of ~10x/s.
    private let spectrum = SpectrumAnalyzer(fftSize: 1024, bandCount: WaveformLevelStore.halfCount, sampleRate: AudioCapture.sampleRate)
    private static let spectrumWindow = 1024
    private static let spectrumHop = 512  // ~32 ms at 16 kHz
    private var spectrumBuffer: [Float] = []
    private var sinceLastSpectrum = 0

    /// Starts capture. `onChunk` receives raw Float32 LE PCM (~100 ms each);
    /// `onLevel` receives a frequency spectrum (0…1 per band, main queue) for
    /// the HUD waveform, roughly every 32 ms.
    func start(
        onChunk: @escaping (Data) -> Void,
        onLevel: @escaping ([Float]) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isRunning, !isStarting else {
            DispatchQueue.main.async { completion(.success(())) }
            return
        }
        isStarting = true

        bufferQueue.sync {
            pending.removeAll(keepingCapacity: true)
            spectrumBuffer.removeAll(keepingCapacity: true)
            sinceLastSpectrum = 0
            chunkHandler = onChunk
            levelHandler = onLevel
        }
        source.start(
            persistedUID: AppConfig.shared.inputDeviceUID,
            onBuffer: { [weak self] buffer in self?.convertAndAccumulate(buffer) },
            onFailure: { [weak self] message in self?.onDeviceLost?(message) }
        ) { [weak self] result in
            guard let self, self.isStarting else { return }
            self.isStarting = false
            switch result {
            case .success:
                self.isRunning = true
            case .failure:
                self.clearBuffers()
            }
            completion(result)
        }
    }

    /// Stops capture and tears down the tap. Safe to call when not running.
    ///
    /// Synchronously drains the buffer queue: already-queued tap callbacks
    /// run first, then the partial tail chunk (< 100 ms) is flushed to the
    /// chunk handler as-is — so the last syllable reaches the engine before
    /// the caller sends `stop`.
    func stop(completion: @escaping () -> Void = {}) {
        guard isRunning || isStarting else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        isRunning = false
        isStarting = false
        source.stop { [weak self] in
            guard let self else { completion(); return }
            self.converter = nil
            self.converterInputFormat = nil
            self.bufferQueue.sync {
                if !self.pending.isEmpty, let handler = self.chunkHandler {
                    let data = self.pending.withUnsafeBufferPointer { Data(buffer: $0) }
                    handler(data)
                }
                self.pending.removeAll()
                self.spectrumBuffer.removeAll()
                self.chunkHandler = nil
                self.levelHandler = nil
            }
            completion()
        }
    }

    private func clearBuffers() {
        bufferQueue.sync {
            pending.removeAll()
            spectrumBuffer.removeAll()
            chunkHandler = nil
            levelHandler = nil
        }
    }

    /// Converts on AVCapture's serial sample queue, then copies Float32 data
    /// before handing it to Velora's existing accumulation queue.
    private func convertAndAccumulate(_ buffer: AVAudioPCMBuffer) {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { return }
        let inFormat = buffer.format
        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converterInputFormat = inFormat
        }
        guard let converter else {
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceLost?("Microphone audio could not be converted")
            }
            return
        }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        bufferQueue.async { [weak self] in self?.accumulate(samples) }
    }

    // MARK: - Buffer accumulation (bufferQueue only)

    /// Appends converted samples, emits fixed ~100 ms chunks to the engine, and
    /// emits a frequency spectrum for the HUD on a short (~32 ms) hop.
    private func accumulate(_ samples: [Float]) {
        guard chunkHandler != nil else { return }  // stopped; drop stragglers
        pending.append(contentsOf: samples)
        while pending.count >= Self.chunkFrames {
            let chunk = Array(pending.prefix(Self.chunkFrames))
            pending.removeFirst(Self.chunkFrames)
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            chunkHandler?(data)
        }

        // Rolling FFT window for the HUD waveform: keep the last ~1024 samples,
        // recompute the spectrum every ~512 samples so the bars react to pitch
        // and loudness ~30x/s.
        spectrumBuffer.append(contentsOf: samples)
        if spectrumBuffer.count > Self.spectrumWindow {
            spectrumBuffer.removeFirst(spectrumBuffer.count - Self.spectrumWindow)
        }
        sinceLastSpectrum += samples.count
        if sinceLastSpectrum >= Self.spectrumHop, spectrumBuffer.count >= Self.spectrumWindow / 2 {
            sinceLastSpectrum = 0
            let bands = spectrum.process(spectrumBuffer)
            if let onLevel = levelHandler {
                DispatchQueue.main.async { onLevel(bands) }
            }
        }
    }
}
