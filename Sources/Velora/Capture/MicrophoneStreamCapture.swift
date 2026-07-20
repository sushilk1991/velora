import AVFoundation
import CoreMedia
import Foundation

/// Resolves Velora's persisted microphone choice against AVFoundation's
/// capture-device list. Unlike AVAudioEngine's input node, AVCaptureSession
/// opens this device directly and does not couple it to the current output
/// route (the failure seen when AirPods own output and the Mac mic is chosen).
enum MicrophoneCaptureDevicePolicy {
    static func selectedUID(
        persistedUID: String?,
        availableUIDs: [String],
        defaultUID: String?
    ) -> String? {
        if let persistedUID, !persistedUID.isEmpty,
           availableUIDs.contains(persistedUID) {
            return persistedUID
        }
        if let defaultUID, availableUIDs.contains(defaultUID) {
            return defaultUID
        }
        return availableUIDs.first
    }
}

/// A direct, audio-only microphone source. Sample callbacks are serialized on
/// a private queue and contain copied PCM whose lifetime extends through the
/// callback. Failure callbacks are delivered once on the main queue.
final class MicrophoneStreamCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum CaptureError: LocalizedError {
        case noDevice
        case cannotAddInput
        case cannotAddOutput
        case sessionDidNotStart

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No microphone available"
            case .cannotAddInput: return "The selected microphone could not be opened"
            case .cannotAddOutput: return "Microphone PCM output could not be configured"
            case .sessionDidNotStart: return "Microphone capture did not start"
            }
        }
    }

    private let sampleQueue = DispatchQueue(
        label: "com.velora.capture.microphone", qos: .userInitiated)
    /// AVCaptureSession start/stop are documented blocking operations. Keep
    /// their full lifecycle off AppKit's main thread so a Bluetooth route
    /// negotiation cannot freeze the hotkey or HUD.
    private let lifecycleQueue = DispatchQueue(
        label: "com.velora.capture.microphone.lifecycle", qos: .userInitiated)
    private let stateLock = NSLock()
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var selectedUID: String?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var failureReported = false
    private var stopping = false
    private var running = false
    private var generation: UInt64 = 0

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    func start(
        persistedUID: String?,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onFailure: @escaping (String) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        stateLock.lock()
        generation &+= 1
        let requestedGeneration = generation
        stopping = true
        running = false
        stateLock.unlock()

        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.teardownSession()
            guard self.generationMatches(requestedGeneration) else { return }

            do {
                let discovery = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                let devices = discovery.devices
                let defaultDevice = AVCaptureDevice.default(for: .audio)
                let uid = MicrophoneCaptureDevicePolicy.selectedUID(
                    persistedUID: persistedUID,
                    availableUIDs: devices.map(\.uniqueID),
                    defaultUID: defaultDevice?.uniqueID)
                guard let uid, let device = devices.first(where: { $0.uniqueID == uid }) else {
                    throw CaptureError.noDevice
                }

                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                let session = AVCaptureSession()
                session.beginConfiguration()
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    throw CaptureError.cannotAddInput
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw CaptureError.cannotAddOutput
                }
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                session.commitConfiguration()

                self.stateLock.lock()
                guard self.generation == requestedGeneration else {
                    self.stateLock.unlock()
                    output.setSampleBufferDelegate(nil, queue: nil)
                    return
                }
                self.onBuffer = onBuffer
                self.onFailure = onFailure
                self.selectedUID = uid
                self.failureReported = false
                self.stopping = false
                self.session = session
                self.output = output
                self.stateLock.unlock()
                self.installObservers(for: session)
                AudioInputDevices.beginObserving()

                guard self.generationIsCurrent(requestedGeneration) else {
                    self.teardownSession()
                    return
                }
                session.startRunning()
                guard self.generationIsCurrent(requestedGeneration) else {
                    self.teardownSession()
                    return
                }
                guard session.isRunning else { throw CaptureError.sessionDidNotStart }
                self.stateLock.lock()
                self.running = true
                self.stateLock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard self?.generationIsCurrent(requestedGeneration) == true else { return }
                    completion(.success(()))
                }
            } catch {
                self.teardownSession()
                self.finishStartFailure(
                    error, generation: requestedGeneration, completion: completion)
            }
        }
    }

    /// Stops new delivery, waits for already-delivered sample callbacks, then
    /// releases callbacks and hardware. Completion is always delivered on the
    /// main queue; safe to call repeatedly.
    func stop(completion: @escaping () -> Void = {}) {
        stateLock.lock()
        generation &+= 1
        let stoppedGeneration = generation
        stopping = true
        running = false
        stateLock.unlock()
        lifecycleQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            self.teardownSession()
            self.stateLock.lock()
            if self.generation == stoppedGeneration {
                self.selectedUID = nil
                self.onBuffer = nil
                self.onFailure = nil
            }
            self.stateLock.unlock()
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// lifecycleQueue only.
    private func teardownSession() {
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        sampleQueue.sync {}
        removeObservers()
        session = nil
        output = nil
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private func generationIsCurrent(_ value: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation == value && !stopping
    }

    private func generationMatches(_ value: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation == value
    }

    private func finishStartFailure(
        _ error: Error,
        generation failedGeneration: UInt64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        stateLock.lock()
        let shouldReport = generation == failedGeneration
        if shouldReport {
            stopping = true
            running = false
            selectedUID = nil
            onBuffer = nil
            onFailure = nil
        }
        stateLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async { completion(.failure(error)) }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            reportFailure("Microphone delivered an unreadable audio format")
            return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              frames <= Int(Int32.max),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        // AVAudioPCMBuffer exposes zero-length AudioBuffers until frameLength
        // is set. CoreMedia requires a pre-populated list whose byte sizes can
        // hold the requested copy.
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            reportFailure("Microphone PCM copy failed (\(status))")
            return
        }
        stateLock.lock()
        let callback = stopping ? nil : onBuffer
        stateLock.unlock()
        callback?(buffer)
    }

    private func installObservers(for session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] note in
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?
                .localizedDescription ?? "unknown runtime error"
            self?.reportFailure("Microphone capture stopped: \(detail)")
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main
        ) { [weak self] _ in
            self?.reportFailure("Microphone capture was interrupted")
        })
        observers.append(center.addObserver(
            forName: .veloraAudioInputDevicesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let selected = self.selectedUID
            let stopping = self.stopping
            self.stateLock.unlock()
            guard !stopping, let selected,
                  !AVCaptureDevice.DiscoverySession(
                      deviceTypes: [.microphone], mediaType: .audio,
                      position: .unspecified).devices.contains(where: { $0.uniqueID == selected })
            else { return }
            self.reportFailure("The selected microphone disconnected")
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func reportFailure(_ message: String) {
        stateLock.lock()
        let shouldReport = !stopping && !failureReported
        if shouldReport { failureReported = true }
        let reportedGeneration = generation
        stateLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let callback = self.generation == reportedGeneration && !self.stopping
                ? self.onFailure : nil
            self.stateLock.unlock()
            callback?(message)
        }
    }
}
