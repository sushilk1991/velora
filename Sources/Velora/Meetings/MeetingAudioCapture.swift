import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

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

/// Disk-spooled, bounded-memory capture. Microphone and system audio are kept
/// separate so the transcript can honestly label Me/Them without pretending
/// to perform remote-speaker diarization.
final class MeetingAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Rebuilt per meeting so a device pinned for one meeting can never leak
    /// into the next after the mic setting changes back to system default.
    private var micEngine = AVAudioEngine()
    private var micConfigObserver: NSObjectProtocol?
    private var micFile: AVAudioFile?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerStarted = false
    private let systemQueue = DispatchQueue(label: "com.velora.meetings.system-audio")
    private var meetingID: String?
    private var startedAt: Date?
    private var micURL: URL?
    private var systemURL: URL?
    private let failureLock = NSLock()
    private var systemAudioFailed = false
    private var microphoneWriteFailed = false
    private var stopping = false
    private var systemSamplesEnabled = false

    /// Failure callbacks are delivered once on the main queue. Capture may
    /// fail after its initial permission/start handshake (device removal,
    /// ScreenCaptureKit revocation, disk full), and that must be visible.
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
        // CAF permits an Audio Data chunk with an unknown size extending to
        // EOF, so audio already flushed remains readable after a hard crash.
        // RIFF/WAV normally needs its final data length patched on close.
        let micURL = directory.appendingPathComponent("me.caf")
        let systemURL = directory.appendingPathComponent("them.m4a")
        do {
            micEngine = AVAudioEngine()
            let input = micEngine.inputNode
            // Same pin as AudioCapture.start(): bind the chosen mic before
            // the format is read; nil (system default) changes nothing.
            // Mid-meeting device loss is surfaced by the configuration-change
            // observer installed after start (no silent-track meetings).
            if AppConfig.shared.inputDeviceUID != nil,
               let chosen = AudioInputDevices.resolve(
                   persistedUID: AppConfig.shared.inputDeviceUID, in: AudioInputDevices.current()),
               let unit = input.audioUnit {
                var deviceID = chosen
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    NSLog("Velora: meeting mic pin failed (%d); using system default", status)
                }
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(
                    domain: "VeloraMeetingCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no input device is available"])
            }
            let file = try AVAudioFile(forWriting: micURL, settings: format.settings)
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
                do {
                    try file.write(from: buffer)
                } catch {
                    self?.reportMicrophoneFailure(error.localizedDescription)
                }
            }
            micEngine.prepare()
            self.micFile = file
            self.micURL = micURL
            self.systemURL = systemURL
            self.meetingID = meetingID
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: micURL.path)
        } catch {
            micEngine.inputNode.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(.microphone(error.localizedDescription)))
            return
        }

        startSystemAudio(meetingID: meetingID, url: systemURL) { [weak self] result in
            guard let self, self.meetingID == meetingID else { return }
            let systemAudio: Bool
            let warning: String?
            switch result {
            case .success:
                systemAudio = true
                warning = nil
            case .failure(let error):
                self.markSystemAudioFailed()
                self.stream = nil
                self.writer = nil
                self.writerInput = nil
                try? FileManager.default.removeItem(at: systemURL)
                systemAudio = false
                warning = Self.systemAudioWarning(for: error)
            }
            // Do not record the microphone while ScreenCaptureKit is still
            // preparing or showing its permission UI. Starting it only after
            // the system-audio handshake also gives the two tracks a common
            // practical origin; system samples are ignored until this point.
            do {
                try self.micEngine.start()
                self.installMicConfigObserver()
                let startedAt = Date()
                self.startedAt = startedAt
                self.enableSystemSamples()
                completion(.success(MeetingCaptureStart(
                    startedAt: startedAt,
                    systemAudio: systemAudio,
                    micRelativePath: "\(meetingID)/me.caf",
                    systemRelativePath: systemAudio ? "\(meetingID)/them.m4a" : nil,
                    warning: warning)))
            } catch {
                self.abortPreparedCapture(meetingID: meetingID) {
                    completion(.failure(.microphone(error.localizedDescription)))
                }
            }
        }
    }

    static func systemAudioWarning(for error: Error) -> String {
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain && failure.code == -3801 {
            return "macOS has not allowed computer-audio capture. In System Settings, open Privacy & Security → Screen & System Audio Recording, allow Velora, then relaunch it. This meeting is recording your microphone only."
        }
        return "Computer audio could not start (\(error.localizedDescription)). This meeting is recording your microphone only."
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
        removeMicConfigObserver()
        micEngine.stop()
        micEngine.inputNode.removeTap(onBus: 0)
        micFile = nil
        let activeStream = stream
        stream = nil
        markStopping()

        let finishSystem = { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            self.systemQueue.async {
                let finish = {
                    let hasSystem = !self.didSystemAudioFail
                        && self.writerStarted
                        && self.writer?.status == .completed
                        && FileManager.default.fileExists(atPath: system?.path ?? "")
                    DispatchQueue.main.async {
                        let endedAt = Date()
                        self.writer = nil
                        self.writerInput = nil
                        self.writerStarted = false
                        self.meetingID = nil
                        self.startedAt = nil
                        self.micURL = nil
                        self.systemURL = nil
                        let directory = AppConfig.meetingsDirectory
                            .appendingPathComponent(meetingID, isDirectory: true)
                        if cancelled {
                            try? FileManager.default.removeItem(at: directory)
                            completion(nil)
                            return
                        }
                        if !hasSystem, let system {
                            try? FileManager.default.removeItem(at: system)
                        }
                        if let mic { try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: mic.path) }
                        if hasSystem, let system { try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: system.path) }
                        completion(MeetingCaptureFiles(
                            startedAt: startedAt, endedAt: endedAt,
                            micRelativePath: FileManager.default.fileExists(atPath: mic?.path ?? "")
                                ? "\(meetingID)/me.caf" : nil,
                            systemRelativePath: hasSystem ? "\(meetingID)/them.m4a" : nil))
                    }
                }
                if self.writerStarted, self.writer?.status == .writing {
                    self.writerInput?.markAsFinished()
                    self.writer?.finishWriting(completionHandler: finish)
                } else {
                    if let system { try? FileManager.default.removeItem(at: system) }
                    finish()
                }
            }
        }

        if let activeStream {
            activeStream.stopCapture { _ in finishSystem() }
        } else {
            finishSystem()
        }
    }

    private func startSystemAudio(
        meetingID: String,
        url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        SCShareableContent.getExcludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) { [weak self] content, error in
            // Discovery can finish after quit/cancel has already cleared this
            // preparation. Serialize setup with the rest of the capture state
            // and require the exact meeting so a stale callback cannot start a
            // stream for a later session.
            DispatchQueue.main.async {
                guard let self, self.meetingID == meetingID else { return }
                if let error { completion(.failure(error)); return }
                guard let content, let display = content.displays.first else {
                    let error = NSError(
                        domain: "VeloraMeetingCapture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "no display is available"])
                    completion(.failure(error))
                    return
                }
                do {
                    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 128_000,
                    ])
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else {
                        throw NSError(
                            domain: "VeloraMeetingCapture", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "audio encoder is unavailable"])
                    }
                    writer.add(input)
                    self.writer = writer
                    self.writerInput = input

                    let current = content.applications.filter {
                        $0.processID == ProcessInfo.processInfo.processIdentifier
                    }
                    let filter = SCContentFilter(
                        display: display, excludingApplications: current, exceptingWindows: [])
                    let configuration = SCStreamConfiguration()
                    configuration.width = 2
                    configuration.height = 2
                    configuration.queueDepth = 3
                    configuration.capturesAudio = true
                    configuration.sampleRate = 48_000
                    configuration.channelCount = 2
                    configuration.excludesCurrentProcessAudio = true
                    let stream = SCStream(
                        filter: filter, configuration: configuration, delegate: self)
                    try stream.addStreamOutput(
                        self, type: .audio, sampleHandlerQueue: self.systemQueue)
                    self.stream = stream
                    stream.startCapture { error in
                        DispatchQueue.main.async {
                            guard self.meetingID == meetingID else { return }
                            if let error { completion(.failure(error)) }
                            else { completion(.success(())) }
                        }
                    }
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              systemSamplesAreEnabled, !didSystemAudioFail,
              let writer, let writerInput else { return }
        if !writerStarted {
            guard writer.startWriting() else {
                reportSystemAudioFailure(
                    writer.error?.localizedDescription ?? "the audio writer could not start")
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            writerStarted = true
        }
        if writer.status == .writing, writerInput.isReadyForMoreMediaData {
            if !writerInput.append(sampleBuffer) {
                reportSystemAudioFailure(
                    writer.error?.localizedDescription ?? "the audio writer stopped accepting data")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Velora: meeting system-audio stream stopped: %@", error.localizedDescription)
        reportSystemAudioFailure(error.localizedDescription)
    }

    private func resetFailureState() {
        failureLock.lock()
        systemAudioFailed = false
        microphoneWriteFailed = false
        stopping = false
        systemSamplesEnabled = false
        failureLock.unlock()
    }

    private func markStopping() {
        failureLock.lock()
        stopping = true
        failureLock.unlock()
    }

    private func enableSystemSamples() {
        failureLock.lock()
        systemSamplesEnabled = true
        failureLock.unlock()
    }

    private var systemSamplesAreEnabled: Bool {
        failureLock.lock(); defer { failureLock.unlock() }
        return systemSamplesEnabled
    }

    private func abortPreparedCapture(meetingID: String, completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        removeMicConfigObserver()
        micEngine.stop()
        micEngine.inputNode.removeTap(onBus: 0)
        micFile = nil
        let activeStream = stream
        stream = nil
        markStopping()
        let finish = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                self.writer?.cancelWriting()
                self.writer = nil
                self.writerInput = nil
                self.writerStarted = false
                self.meetingID = nil
                self.startedAt = nil
                self.micURL = nil
                self.systemURL = nil
                try? FileManager.default.removeItem(
                    at: AppConfig.meetingsDirectory
                        .appendingPathComponent(meetingID, isDirectory: true))
                completion()
            }
        }
        if let activeStream { activeStream.stopCapture { _ in finish() } }
        else { finish() }
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

    /// A mic device that disappears mid-meeting stops buffer delivery with
    /// NO error — the tap just goes quiet and the meeting would keep looking
    /// live while recording nothing (review catch). Surface it loudly: on an
    /// engine configuration change, restart if possible, and report a real
    /// failure when the chosen device is gone or the restart fails.
    private func installMicConfigObserver() {
        micConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: micEngine, queue: .main
        ) { [weak self] _ in
            guard let self, self.meetingID != nil else { return }
            if let uid = AppConfig.shared.inputDeviceUID, !uid.isEmpty,
               AudioInputDevices.resolve(
                   persistedUID: uid, in: AudioInputDevices.current()) == nil {
                self.reportMicrophoneFailure("The chosen microphone disconnected")
                return
            }
            guard !self.micEngine.isRunning else { return }
            do {
                try self.micEngine.start()
            } catch {
                self.reportMicrophoneFailure(error.localizedDescription)
            }
        }
    }

    private func removeMicConfigObserver() {
        if let micConfigObserver { NotificationCenter.default.removeObserver(micConfigObserver) }
        micConfigObserver = nil
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
