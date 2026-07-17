import AudioToolbox
import AVFoundation
import Foundation

/// Microphone capture: AVAudioEngine input tap converted to 16 kHz mono
/// Float32, delivered as ~100 ms chunks (1600 samples / 6400 bytes) for the
/// engine, plus normalized RMS levels for the HUD waveform.
///
/// Chunk callbacks fire on a private serial queue (callers forward to their
/// own queue); level callbacks are delivered on the main queue.
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case converterUnavailable
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: return "No microphone available"
            case .converterUnavailable: return "Audio converter unavailable"
            case .engineStartFailed(let e): return "Audio engine failed: \(e.localizedDescription)"
            }
        }
    }

    /// Output format required by the engine (docs/ARCHITECTURE.md).
    static let sampleRate: Double = 16_000
    /// ~100 ms at 16 kHz.
    private static let chunkFrames = 1600

    private var engine: AVAudioEngine?
    private(set) var isRunning = false
    private var configObserver: NSObjectProtocol?
    private var devicesObserver: NSObjectProtocol?
    /// The device successfully pinned on the current engine (nil = system
    /// default) — compared against a fresh resolve when the device list
    /// changes to decide whether a rebuild is needed.
    private var appliedInputDevice: AudioDeviceID?

    /// Called (main queue) when capture could not be re-established after an
    /// audio-device change mid-recording (e.g. the only mic unplugged).
    /// Successful recovery is silent — the recording just continues.
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
        onLevel: @escaping ([Float]) -> Void
    ) throws {
        guard !isRunning else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Pin the user's chosen mic (Settings → Dictation) on the input
        // node's HAL unit BEFORE reading the format: macOS re-routes the
        // default input when AirPods connect, and the chosen device must be
        // bound before the tap/converter formats are derived from it. nil
        // (system default) leaves the engine completely untouched; a chosen
        // device that is unplugged right now resolves to nil too (default),
        // without clearing the persisted choice.
        var pinned: AudioDeviceID?
        if AppConfig.shared.inputDeviceUID != nil,
           let chosen = AudioInputDevices.resolve(
               persistedUID: AppConfig.shared.inputDeviceUID, in: AudioInputDevices.current()),
           let unit = input.audioUnit {
            var deviceID = chosen
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                pinned = chosen
            } else {
                veloraLog("Velora: could not pin input device (\(status)); using system default")
            }
        }
        appliedInputDevice = pinned

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw CaptureError.converterUnavailable
        }

        bufferQueue.sync {
            pending.removeAll(keepingCapacity: true)
            spectrumBuffer.removeAll(keepingCapacity: true)
            sinceLastSpectrum = 0
            chunkHandler = onChunk
            levelHandler = onLevel
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                return
            }
            var fed = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if convError != nil { return }
            guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }

            // Copy out of the tap's buffer, then accumulate on bufferQueue.
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            self.bufferQueue.async { self.accumulate(samples) }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }
        self.engine = engine
        isRunning = true

        // The default input can change mid-recording (AirPods connect, mic
        // unplugged): AVAudioEngine stops and the tap/converter stay bound to
        // the dead format — without this the HUD keeps "listening" while no
        // audio flows. Rebuild the chain so the recording just continues.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.recoverFromConfigChange()
        }

        // The chosen mic vanishing (or coming back) mid-recording does not
        // reliably trip AVAudioEngineConfigurationChange for a pinned device.
        // Re-resolve on device-list changes and reuse the same rebuild path
        // when the answer differs: gone → falls back to the system default,
        // reappeared → the persisted choice wins again.
        AudioInputDevices.beginObserving()
        devicesObserver = NotificationCenter.default.addObserver(
            forName: .veloraAudioInputDevicesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let resolved = AudioInputDevices.resolve(
                persistedUID: AppConfig.shared.inputDeviceUID, in: AudioInputDevices.current())
            if resolved != self.appliedInputDevice { self.recoverFromConfigChange() }
        }
    }

    private func removeConfigObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let devicesObserver { NotificationCenter.default.removeObserver(devicesObserver) }
        devicesObserver = nil
    }

    /// Tears down the dead engine and restarts capture with the same handlers
    /// (new device, new format, new converter). At most ~100 ms of buffered
    /// audio is lost across the switch.
    private func recoverFromConfigChange() {
        guard isRunning, let engine else { return }
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRunning = false

        var onChunk: ((Data) -> Void)?
        var onLevel: (([Float]) -> Void)?
        bufferQueue.sync {
            onChunk = chunkHandler
            onLevel = levelHandler
        }
        guard let onChunk, let onLevel else { return }
        do {
            try start(onChunk: onChunk, onLevel: onLevel)
            veloraLog("Velora: capture re-established after audio device change")
        } catch {
            veloraLog("Velora: capture lost after device change: \(error.localizedDescription)")
            onDeviceLost?(error.localizedDescription)
        }
    }

    /// Stops capture and tears down the tap. Safe to call when not running.
    ///
    /// Synchronously drains the buffer queue: already-queued tap callbacks
    /// run first, then the partial tail chunk (< 100 ms) is flushed to the
    /// chunk handler as-is — so the last syllable reaches the engine before
    /// the caller sends `stop`.
    func stop() {
        removeConfigObserver()
        guard isRunning, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRunning = false

        bufferQueue.sync {
            if !pending.isEmpty, let handler = chunkHandler {
                let data = pending.withUnsafeBufferPointer { Data(buffer: $0) }
                handler(data)
            }
            pending.removeAll()
            spectrumBuffer.removeAll()
            chunkHandler = nil
            levelHandler = nil
        }
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
