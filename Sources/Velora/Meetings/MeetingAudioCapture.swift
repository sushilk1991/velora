import AudioToolbox
import AVFoundation
import Foundation

struct MeetingCaptureStart {
    let startedAt: Date
    let systemAudio: Bool
    let micRelativePath: String
    let systemRelativePath: String?
    let warning: String?
}

struct MeetingCaptureFiles {
    let startedAt: Date
    let endedAt: Date
    let micRelativePath: String?
    let systemRelativePath: String?
}

enum MeetingCaptureError: LocalizedError {
    case alreadyRunning
    case microphonePermission
    case microphone(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A meeting recording is already active"
        case .microphonePermission: return "Microphone access is required for meeting capture"
        case .microphone(let message): return "Microphone capture failed: \(message)"
        }
    }
}

/// Thread-safe startup proof shared by the microphone and system-audio
/// callbacks. A successful API return only proves that a graph was created;
/// recording becomes visible only after every requested track delivers frames.
final class MeetingCaptureReadiness {
    enum Track: Equatable {
        case microphone
        case systemAudio
    }

    private let lock = NSLock()
    private var microphoneReady = false
    private var systemAudioReady = false
    private var requiresSystemAudio: Bool
    private var emittedReady = false

    init(requiresSystemAudio: Bool) {
        self.requiresSystemAudio = requiresSystemAudio
    }

    var missingTracks: [Track] {
        lock.lock(); defer { lock.unlock() }
        var result: [Track] = []
        if !microphoneReady { result.append(.microphone) }
        if requiresSystemAudio && !systemAudioReady { result.append(.systemAudio) }
        return result
    }

    @discardableResult
    func recordMicrophone(frames: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if frames > 0 { microphoneReady = true }
        return consumeReadyLocked()
    }

    @discardableResult
    func recordSystemAudio(frames: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if frames > 0 { systemAudioReady = true }
        return consumeReadyLocked()
    }

    @discardableResult
    func continueWithoutSystemAudio() -> Bool {
        lock.lock(); defer { lock.unlock() }
        requiresSystemAudio = false
        return consumeReadyLocked()
    }

    private func consumeReadyLocked() -> Bool {
        guard !emittedReady, microphoneReady,
              !requiresSystemAudio || systemAudioReady else { return false }
        emittedReady = true
        return true
    }
}

/// Disk-spooled, bounded-memory capture. Microphone and computer audio remain
/// separate so the transcript can label Me/Them honestly. Computer audio uses
/// an audio-only Core Audio process tap; this class never asks for screen or
/// display frames.
final class MeetingAudioCapture {
    private let micCapture = MicrophoneStreamCapture()
    private var micFile: AVAudioFile?
    private var systemCapture: AnyObject?
    private var meetingID: String?
    private var startedAt: Date?
    private var micURL: URL?
    private var systemURL: URL?
    private var readiness: MeetingCaptureReadiness?
    private var startupCompletion:
        ((Result<MeetingCaptureStart, MeetingCaptureError>) -> Void)?
    private var startupTimeout: DispatchWorkItem?
    private var startupSystemAudio = false
    private var startupWarning: String?
    private let failureLock = NSLock()
    private var systemAudioFailed = false
    private var microphoneWriteFailed = false
    private var stopping = false

    /// Failure callbacks are delivered once on the main queue. A stream can
    /// fail after startup (device removal, permission revocation, disk full),
    /// and that must remain visible for the whole meeting.
    var onSystemAudioFailure: ((String) -> Void)?
    var onMicrophoneFailure: ((String) -> Void)?

    var isCapturing: Bool { meetingID != nil }

    func start(
        meetingID: String,
        completion: @escaping (Result<MeetingCaptureStart, MeetingCaptureError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isCapturing else { completion(.failure(.alreadyRunning)); return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            completion(.failure(.microphonePermission)); return
        }
        resetFailureState()

        let directory = AppConfig.meetingsDirectory
            .appendingPathComponent(meetingID, isDirectory: true)
        MeetingStore.ensurePrivateDirectory(directory)
        // CAF keeps already-flushed PCM readable after a hard crash; neither
        // track depends on a final container-length patch.
        let micURL = directory.appendingPathComponent("me.caf")
        let systemURL = directory.appendingPathComponent("them.caf")
        let wantsSystemAudio = MeetingSystemAudioPolicy.backend(
            for: ProcessInfo.processInfo.operatingSystemVersion) == .coreAudioTap
        readiness = MeetingCaptureReadiness(requiresSystemAudio: wantsSystemAudio)
        self.micURL = micURL
        self.systemURL = systemURL
        self.meetingID = meetingID
        self.startupCompletion = completion
        startupSystemAudio = false
        startupWarning = nil

        if wantsSystemAudio {
            do {
                try startSystemAudio(to: systemURL)
                startupSystemAudio = true
            } catch {
                startupWarning = Self.systemAudioWarning(for: error)
                markSystemAudioFailed()
                try? FileManager.default.removeItem(at: systemURL)
                if readiness?.continueWithoutSystemAudio() == true {
                    finishStartupIfReady()
                }
            }
        } else {
            startupWarning = "Computer-audio capture requires macOS 14.2 or later. This meeting is recording your microphone only."
            markSystemAudioFailed()
            _ = readiness?.continueWithoutSystemAudio()
        }

        // Bound the entire Bluetooth/device negotiation plus first-frame
        // readiness window. Scheduling only after startRunning completed left
        // the meeting UI stuck forever if macOS wedged while opening a route.
        scheduleStartupTimeout()
        micCapture.start(
            persistedUID: AppConfig.shared.inputDeviceUID,
            onBuffer: { [weak self] buffer in self?.writeMicrophone(buffer) },
            onFailure: { [weak self] message in
                self?.reportMicrophoneFailure(message)
            }
        ) { [weak self] result in
            guard let self, self.meetingID == meetingID else { return }
            switch result {
            case .success:
                break
            case .failure(let error):
                self.abortPreparedCapture(meetingID: meetingID) {
                    completion(.failure(.microphone(error.localizedDescription)))
                }
            }
        }
    }

    static func systemAudioWarning(for error: Error) -> String {
        let detail = error.localizedDescription
        let permissionFailure = detail.localizedCaseInsensitiveContains("permission")
            || detail.localizedCaseInsensitiveContains("denied")
            || detail.localizedCaseInsensitiveContains("not allowed")
        if permissionFailure {
            return "macOS has not allowed computer-audio capture. In System Settings, open Privacy & Security → Screen & System Audio Recording, allow Velora, then relaunch it. Velora records system audio only—not your screen. This meeting is recording your microphone only."
        }
        return "Computer audio could not start (\(detail)). This meeting is recording your microphone only."
    }

    func stop(
        cancelled: Bool,
        completion: @escaping (MeetingCaptureFiles?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let meetingID else { completion(nil); return }
        guard let startedAt else {
            abortPreparedCapture(meetingID: meetingID) { completion(nil) }
            return
        }
        let mic = micURL
        let system = systemURL
        startupTimeout?.cancel()
        startupTimeout = nil
        markStopping()
        micCapture.stop { [weak self] in
            guard let self else { completion(nil); return }
            self.micFile = nil
            let systemHadFrames = self.stopSystemAudio()
            let hasSystem = !self.didSystemAudioFail && systemHadFrames
                && FileManager.default.fileExists(atPath: system?.path ?? "")

            self.meetingID = nil
            self.startedAt = nil
            self.micURL = nil
            self.systemURL = nil
            self.readiness = nil
            self.startupCompletion = nil
            self.startupSystemAudio = false
            self.startupWarning = nil
            let directory = AppConfig.meetingsDirectory
                .appendingPathComponent(meetingID, isDirectory: true)
            if cancelled {
                try? FileManager.default.removeItem(at: directory)
                completion(nil)
                return
            }
            if !hasSystem, let system { try? FileManager.default.removeItem(at: system) }
            if let mic { try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: mic.path) }
            if hasSystem, let system { try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: system.path) }
            completion(MeetingCaptureFiles(
                startedAt: startedAt, endedAt: Date(),
                micRelativePath: FileManager.default.fileExists(atPath: mic?.path ?? "")
                    ? "\(meetingID)/me.caf" : nil,
                systemRelativePath: hasSystem
                    ? MeetingSystemAudioPolicy.relativePath(meetingID: meetingID) : nil))
        }
    }

    private func startSystemAudio(to url: URL) throws {
        guard #available(macOS 14.2, *) else {
            throw NSError(
                domain: "VeloraSystemAudioCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "macOS 14.2 is required"])
        }
        let capture = CoreAudioSystemAudioCapture()
        capture.onFrames = { [weak self] frames in
            guard let self else { return }
            if self.readiness?.recordSystemAudio(frames: frames) == true {
                DispatchQueue.main.async { [weak self] in self?.finishStartupIfReady() }
            }
        }
        capture.onFailure = { [weak self] message in
            self?.systemCaptureDidFail(message)
        }
        try capture.start(to: url)
        systemCapture = capture
    }

    @discardableResult
    private func stopSystemAudio() -> Bool {
        guard #available(macOS 14.2, *),
              let capture = systemCapture as? CoreAudioSystemAudioCapture else {
            systemCapture = nil
            return false
        }
        let result = capture.stop()
        systemCapture = nil
        return result
    }

    private func finishStartupIfReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let meetingID, startedAt == nil, let completion = startupCompletion else { return }
        startupTimeout?.cancel()
        startupTimeout = nil
        let date = Date()
        startedAt = date
        startupCompletion = nil
        readiness = nil
        completion(.success(MeetingCaptureStart(
            startedAt: date,
            systemAudio: startupSystemAudio && !didSystemAudioFail,
            micRelativePath: "\(meetingID)/me.caf",
            systemRelativePath: startupSystemAudio && !didSystemAudioFail
                ? MeetingSystemAudioPolicy.relativePath(meetingID: meetingID) : nil,
            warning: startupWarning)))
    }

    private func scheduleStartupTimeout() {
        startupTimeout?.cancel()
        let meetingID = self.meetingID
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.meetingID == meetingID, self.startedAt == nil,
                  let readiness = self.readiness else { return }
            let missing = readiness.missingTracks
            if missing.contains(.microphone) {
                let completion = self.startupCompletion
                self.startupCompletion = nil
                self.abortPreparedCapture(meetingID: meetingID ?? "") {
                    completion?(.failure(.microphone(
                        "no microphone audio arrived; check the selected input device")))
                }
                return
            }
            if missing.contains(.systemAudio) {
                self.markSystemAudioFailed()
                _ = self.stopSystemAudio()
                if let systemURL = self.systemURL {
                    try? FileManager.default.removeItem(at: systemURL)
                }
                self.startupSystemAudio = false
                self.startupWarning = "Computer audio did not deliver any samples. This meeting is recording your microphone only."
                if readiness.continueWithoutSystemAudio() { self.finishStartupIfReady() }
            }
        }
        startupTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func systemCaptureDidFail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            if self.startedAt == nil, let readiness = self.readiness {
                self.markSystemAudioFailed()
                _ = self.stopSystemAudio()
                if let systemURL = self.systemURL {
                    try? FileManager.default.removeItem(at: systemURL)
                }
                self.startupSystemAudio = false
                self.startupWarning = Self.systemAudioWarning(for: NSError(
                    domain: "VeloraSystemAudioCapture", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: message]))
                if readiness.continueWithoutSystemAudio() { self.finishStartupIfReady() }
            } else {
                self.reportSystemAudioFailure(message)
            }
        }
    }

    private func abortPreparedCapture(meetingID: String, completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        startupTimeout?.cancel()
        startupTimeout = nil
        markStopping()
        // Surface the startup failure immediately. Hardware teardown stays
        // serialized off-main and `isCapturing` remains true until it finishes,
        // so the coordinator can continue excluding a second foreground mic.
        completion()
        micCapture.stop { [weak self] in
            guard let self else { return }
            self.micFile = nil
            _ = self.stopSystemAudio()
            self.meetingID = nil
            self.startedAt = nil
            self.micURL = nil
            self.systemURL = nil
            self.readiness = nil
            self.startupCompletion = nil
            self.startupSystemAudio = false
            self.startupWarning = nil
            try? FileManager.default.removeItem(
                at: AppConfig.meetingsDirectory
                    .appendingPathComponent(meetingID, isDirectory: true))
        }
    }

    private func resetFailureState() {
        failureLock.lock()
        systemAudioFailed = false
        microphoneWriteFailed = false
        stopping = false
        failureLock.unlock()
    }

    private func markStopping() {
        failureLock.lock()
        stopping = true
        failureLock.unlock()
    }

    private func markSystemAudioFailed() {
        failureLock.lock()
        systemAudioFailed = true
        failureLock.unlock()
    }

    private var didSystemAudioFail: Bool {
        failureLock.lock(); defer { failureLock.unlock() }
        return systemAudioFailed
    }

    private func reportSystemAudioFailure(_ message: String) {
        failureLock.lock()
        let shouldReport = !stopping && !systemAudioFailed
        systemAudioFailed = true
        failureLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.onSystemAudioFailure?(message)
        }
    }

    /// Called on MicrophoneStreamCapture's serial sample queue. The file is
    /// opened lazily from the real stream format, then every callback is
    /// written before readiness can declare the meeting healthy.
    private func writeMicrophone(_ buffer: AVAudioPCMBuffer) {
        guard let micURL else { return }
        do {
            if micFile == nil {
                micFile = try AVAudioFile(forWriting: micURL, settings: buffer.format.settings)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: micURL.path)
            }
            try micFile?.write(from: buffer)
            let frames = Int(buffer.frameLength)
            if readiness?.recordMicrophone(frames: frames) == true {
                DispatchQueue.main.async { [weak self] in self?.finishStartupIfReady() }
            }
        } catch {
            reportMicrophoneFailure(error.localizedDescription)
        }
    }

    private func reportMicrophoneFailure(_ message: String) {
        failureLock.lock()
        let shouldReport = !stopping && !microphoneWriteFailed
        microphoneWriteFailed = true
        failureLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.onMicrophoneFailure?(message)
        }
    }
}
