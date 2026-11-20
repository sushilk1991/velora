import AVFoundation
import CoreMedia
import Foundation

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
    private var generation: UInt64 = 0

    /// The device a running session was opened on. Readers that must reason
    /// about *which* microphone is recording (the dead-input rescue) use it
    /// instead of guessing from the settings.
    private var resolvedDevice: MicrophoneDevice?
    /// Uptime of the last device-list change. A change seconds ago means the
    /// route may still be moving: a Bluetooth headset that just appeared, or
    /// one that is about to disappear.
    private var lastDeviceListChange: TimeInterval?

    /// The running session's device, safe to read from any queue.
    var currentDevice: MicrophoneDevice? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return resolvedDevice
    }

    static func describe(_ device: AVCaptureDevice) -> MicrophoneDevice {
        MicrophoneDevice(
            uid: device.uniqueID,
            name: device.localizedName,
            isBuiltIn: AudioTransport.isBuiltIn(device.transportType),
            isBluetooth: AudioTransport.isBluetooth(device.transportType))
    }

    /// The resolve ladder over the devices AVFoundation can see right now.
    /// `chosenUID` comes from the caller so the start path and the tests agree
    /// on which choice is being resolved.
    static func resolveCandidate(
        chosenUID: String?, config: AppConfig = .shared
    ) -> (device: AVCaptureDevice, resolution: MicrophoneResolution)? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let ladder = MicrophoneSelection.Ladder(
            chosenUID: chosenUID,
            systemDefaultUID: AVCaptureDevice.default(for: .audio)?.uniqueID,
            lastUsedUID: config.inputDeviceLastUID,
            recentUIDs: config.recentInputDeviceUIDs,
            excludedUIDs: config.excludedInputDeviceUIDs,
            connectedUIDs: devices.map(\.uniqueID))
        guard let resolution = MicrophoneSelection.resolve(ladder),
              let device = devices.first(where: { $0.uniqueID == resolution.uid })
        else { return nil }
        return (device, resolution)
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
        stateLock.unlock()

        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.teardownSession()
            guard self.generationMatches(requestedGeneration) else { return }

            do {
                // Resolve through the ladder, then let a moving route settle
                // before binding: a Bluetooth headset needs a few hundred
                // milliseconds to reach its two-way route, and binding during
                // the switch records the wrong device or digital silence.
                let resolveCandidate = { Self.resolveCandidate(chosenUID: persistedUID) }
                guard let initial = resolveCandidate() else { throw CaptureError.noDevice }
                let plan = MicrophoneRouteSettle.plan(
                    isBluetooth: Self.describe(initial.device).isBluetooth,
                    deviceListChangedAt: self.deviceListChangeUptime(),
                    now: ProcessInfo.processInfo.systemUptime)
                guard let chosen = self.settleRoute(
                    plan: plan, initial: initial,
                    generation: requestedGeneration, resolve: resolveCandidate)
                else { return }
                let device = chosen.device
                let uid = device.uniqueID
                veloraLog(
                    "Velora: mic resolved by \(chosen.resolution.step.label) → "
                        + "\(device.localizedName)")

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
                let resolved = Self.describe(device)
                self.stateLock.lock()
                if self.generation == requestedGeneration {
                    self.resolvedDevice = resolved
                }
                self.stateLock.unlock()
                // Only a start that actually delivered a session teaches the
                // ladder which device works. A failed start must not become
                // "last used".
                AppConfig.shared.inputDeviceLastUID = resolved.uid
                veloraLog("Velora: capturing from \(resolved.name) [\(resolved.uid)]")
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
                self.resolvedDevice = nil
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
    }

    /// Uptime of the last device-list change, or nil when none has arrived.
    private func deviceListChangeUptime() -> TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastDeviceListChange
    }

    /// lifecycleQueue only. Holds the start until the resolved device stops
    /// moving, so a Bluetooth route switch cannot be bound mid-flight. A plan
    /// that does not wait returns `initial` without sleeping, so a stable wired
    /// microphone pays no latency. Returns nil when a newer start or a stop
    /// superseded this one.
    private func settleRoute(
        plan: MicrophoneRouteSettle.Plan,
        initial: (device: AVCaptureDevice, resolution: MicrophoneResolution),
        generation: UInt64,
        resolve: () -> (device: AVCaptureDevice, resolution: MicrophoneResolution)?
    ) -> (device: AVCaptureDevice, resolution: MicrophoneResolution)? {
        guard plan.waits else { return initial }
        var state = MicrophoneRouteSettleState(
            plan: plan, firstUID: initial.device.uniqueID,
            at: ProcessInfo.processInfo.systemUptime)
        var current = initial
        while true {
            guard generationMatches(generation) else { return nil }
            if case .bind(let uid) = state.observe(
                current.device.uniqueID, at: ProcessInfo.processInfo.systemUptime) {
                // Bind the device the state machine settled on, not the one seen
                // before its verdict.
                if uid != current.device.uniqueID, let next = resolve() {
                    current = next
                }
                return current
            }
            Thread.sleep(forTimeInterval: plan.pollInterval)
            if let next = resolve() { current = next }
        }
    }

    /// Replaces the running input without ending the take.
    ///
    /// Buffers keep flowing to the same `onBuffer` callback, so the caller's
    /// chunk stream and take identity are untouched: this is one take recorded
    /// from two devices, used when a lid-closed built-in microphone is
    /// delivering digital silence. The old session is detached first; two live
    /// taps would splice two devices into the same 100 ms chunk grid.
    func switchInput(
        to uid: String,
        completion: @escaping (Result<MicrophoneDevice, Error>) -> Void
    ) {
        stateLock.lock()
        let swapGeneration = generation
        let isLive = session != nil && !stopping
        stateLock.unlock()
        guard isLive else {
            DispatchQueue.main.async { completion(.failure(CaptureError.noDevice)) }
            return
        }

        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.session?.stopRunning()
            self.sampleQueue.sync {}
            self.removeObservers()
            do {
                let devices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.microphone], mediaType: .audio,
                    position: .unspecified).devices
                guard let device = devices.first(where: { $0.uniqueID == uid }) else {
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
                guard self.generation == swapGeneration, !self.stopping else {
                    self.stateLock.unlock()
                    output.setSampleBufferDelegate(nil, queue: nil)
                    DispatchQueue.main.async {
                        completion(.failure(CaptureError.sessionDidNotStart))
                    }
                    return
                }
                self.session = session
                self.output = output
                self.selectedUID = uid
                self.failureReported = false
                let resolved = Self.describe(device)
                self.resolvedDevice = resolved
                self.stateLock.unlock()
                self.installObservers(for: session)
                session.startRunning()
                guard session.isRunning else { throw CaptureError.sessionDidNotStart }
                DispatchQueue.main.async { completion(.success(resolved)) }
            } catch {
                // The old input is already detached, so say so: the take ends
                // visibly through the failure path instead of recording silence.
                self.reportFailure("Could not switch microphone: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
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
            // Stamp the change: a start in the next couple of seconds is a
            // route that may still be moving.
            self.lastDeviceListChange = ProcessInfo.processInfo.systemUptime
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
