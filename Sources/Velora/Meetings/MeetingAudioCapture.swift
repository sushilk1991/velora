import AudioToolbox
import AVFoundation
import Foundation
import IOKit

struct MeetingCaptureStart {
    let startedAt: Date
    let systemAudio: Bool
    let micRelativePath: String
    let systemRelativePath: String?
    let warning: String?
    /// The microphone delivered only exact zeros during startup; capture
    /// continued so computer audio is still recorded.
    var microphoneSilent = false
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
/// Microphone frames count only when a sample is louder than digital
/// silence (`MeetingPCMLevel.isSilent`): a lid-closed built-in mic delivers
/// a steady stream of exact zeros.
final class MeetingCaptureReadiness {
    enum Track: Equatable {
        case microphone
        case systemAudio
    }

    private let lock = NSLock()
    private var microphoneReady = false
    private var microphoneFramesSeen = false
    private var microphoneHeardSound = false
    private var systemAudioReady = false
    private var requiresSystemAudio: Bool
    private var emittedReady = false
    private var failure: String?

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
    func recordMicrophone(frames: Int, peak: Float) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if frames > 0 { microphoneFramesSeen = true }
        if frames > 0 && !MeetingPCMLevel.isSilent(peak) {
            // A failed mic stays missing, so the startup timeout fails it.
            microphoneReady = failure == nil
            microphoneHeardSound = true
        }
        return consumeReadyLocked()
    }

    /// True once any microphone sample was nonzero, including after a
    /// degraded start accepted a silent microphone.
    var heardMicrophoneSound: Bool {
        lock.lock(); defer { lock.unlock() }
        return microphoneHeardSound
    }

    /// True when the microphone delivered frames but every sample was zero:
    /// the device is open yet records nothing. A mic that also failed is
    /// broken, not silent.
    var microphoneDeliveredOnlySilence: Bool {
        lock.lock(); defer { lock.unlock() }
        return microphoneFramesSeen && !microphoneReady && failure == nil
    }

    /// Why microphone capture failed (a write error, a stream failure),
    /// or nil while it has not.
    var microphoneFailure: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    /// Records a real microphone capture failure. From then on startup can
    /// neither degrade to a silent mic nor become ready: it must fail.
    ///
    ///     frames of zeros ─► silent  ─► may start degraded
    ///     write/stream error ─► failed ─► startup fails
    func recordMicrophoneFailure(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = message }
    }

    /// Accepts a silent microphone so startup can finish degraded. A mic
    /// that delivered no frames at all, or failed, still cannot start a
    /// meeting.
    @discardableResult
    func continueWithSilentMicrophone() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard microphoneFramesSeen, failure == nil else { return false }
        microphoneReady = true
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
        guard !emittedReady, microphoneReady, failure == nil,
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
    /// This capture's microphone diagnostics. Each start makes a fresh one
    /// and hands it to the sample-queue callback, so a new capture never
    /// resets state a late buffer of the old one is still using; on main it
    /// only tags silence reports (see `notifySilenceChange`).
    private var microphoneLevel: MicrophoneLevelState?
    private var startupMicrophoneSilent = false
    private var startupCompletion:
        ((Result<MeetingCaptureStart, MeetingCaptureError>) -> Void)?
    private var startupTimeout: DispatchWorkItem?
    private var startupSystemAudio = false
    private var startupWarning: String?
    private let systemAudioTeardown = DispatchGroup()
    private let failureLock = NSLock()
    private var systemAudioFailed = false
    private var microphoneWriteFailed = false
    private var stopping = false

    /// Failure callbacks are delivered once on the main queue. A stream can
    /// fail after startup (device removal, permission revocation, disk full),
    /// and that must remain visible for the whole meeting.
    var onSystemAudioFailure: ((String) -> Void)?
    var onMicrophoneFailure: ((String) -> Void)?
    /// Reports the microphone recording only exact zeros for
    /// `MeetingMicrophoneLevelWatch.silentAlertSeconds`, and sound arriving
    /// after zeros. Delivered on the main queue.
    var onMicrophoneSilenceChange: ((MeetingMicrophoneSilence) -> Void)?

    static let silentMicrophoneWarning =
        "Your microphone is recording silence. Check the input device (a closed MacBook lid disconnects the built-in mic)."

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
        // The capture callbacks keep this object; `self.readiness` is main
        // queue state that startup and stop reset.
        let readiness = MeetingCaptureReadiness(requiresSystemAudio: wantsSystemAudio)
        self.readiness = readiness
        self.micURL = micURL
        self.systemURL = systemURL
        self.meetingID = meetingID
        self.startupCompletion = completion
        startupSystemAudio = false
        startupWarning = nil
        startupMicrophoneSilent = false
        // Read on main: the diagnostic log runs on a global queue and must
        // not touch AppConfig there.
        let persistedUID = AppConfig.shared.inputDeviceUID
        let microphoneLevel = MicrophoneLevelState(persistedUID: persistedUID)
        self.microphoneLevel = microphoneLevel

        if wantsSystemAudio {
            do {
                try startSystemAudio(to: systemURL, readiness: readiness)
                startupSystemAudio = true
            } catch {
                startupWarning = Self.systemAudioWarning(for: error)
                markSystemAudioFailed()
                try? FileManager.default.removeItem(at: systemURL)
                if readiness.continueWithoutSystemAudio() {
                    finishStartupIfReady()
                }
            }
        } else {
            startupWarning = "Computer-audio capture requires macOS 14.2 or later. This meeting is recording your microphone only."
            markSystemAudioFailed()
            _ = readiness.continueWithoutSystemAudio()
        }

        // Bound the entire Bluetooth/device negotiation plus first-frame
        // readiness window. Scheduling only after startRunning completed left
        // the meeting UI stuck forever if macOS wedged while opening a route.
        scheduleStartupTimeout()
        micCapture.start(
            persistedUID: persistedUID,
            onBuffer: { [weak self] buffer in
                self?.writeMicrophone(
                    buffer, readiness: readiness, level: microphoneLevel)
            },
            onFailure: { [weak self] message in
                readiness.recordMicrophoneFailure(message)
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
            return "macOS has not allowed Mac audio capture. In System Settings, open Privacy & Security → Screen & System Audio Recording, allow Velora, then relaunch it. Velora records Mac audio, not your screen. This meeting is recording your mic only."
        }
        return "Mac audio could not start (\(detail)). This meeting is recording your mic only."
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
            self.stopSystemAudio { _ in
                let hasSystem = Self.keepsSystemTrack(at: system)

                self.meetingID = nil
                self.startedAt = nil
                self.micURL = nil
                self.systemURL = nil
                self.readiness = nil
                self.microphoneLevel = nil
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
    }

    /// A computer-audio file is kept whenever Core Audio can read frames
    /// from it, even after the tap failed mid-meeting: the audio before the
    /// failure is real, and the engine decides whether it is usable.
    static func keepsSystemTrack(at url: URL?) -> Bool {
        guard let url, let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private func startSystemAudio(
        to url: URL, readiness: MeetingCaptureReadiness
    ) throws {
        guard #available(macOS 14.2, *) else {
            throw NSError(
                domain: "VeloraSystemAudioCapture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "macOS 14.2 is required"])
        }
        let capture = CoreAudioSystemAudioCapture()
        capture.onFrames = { [weak self] frames in
            guard readiness.recordSystemAudio(frames: frames) else { return }
            DispatchQueue.main.async { self?.finishStartupIfReady() }
        }
        capture.onFailure = { [weak self] message in
            self?.systemCaptureDidFail(message)
        }
        try capture.start(to: url)
        systemCapture = capture
    }

    private func stopSystemAudio(completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard #available(macOS 14.2, *),
              let capture = systemCapture as? CoreAudioSystemAudioCapture else {
            systemCapture = nil
            // A failure path may already have detached the capture and be
            // draining its writer. Wait off-main before callers delete or
            // inspect the CAF.
            DispatchQueue.global(qos: .userInitiated).async {
                self.systemAudioTeardown.wait()
                DispatchQueue.main.async { completion(false) }
            }
            return
        }
        systemCapture = nil
        // AudioDeviceStop and a durable file drain can block under the exact
        // disk pressure that caused the capture failure. Never make the HUD or
        // meeting controls wait on that teardown.
        systemAudioTeardown.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = capture.stop()
            self.systemAudioTeardown.leave()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func finishStartupIfReady() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let meetingID, startedAt == nil, let completion = startupCompletion else { return }
        startupTimeout?.cancel()
        startupTimeout = nil
        let date = Date()
        startedAt = date
        startupCompletion = nil
        // A silent-startup mic can find its sound while computer audio is
        // still being given up on. Its first-sound report reached the main
        // queue before the recording existed, so settle it here.
        let microphoneSilent = startupMicrophoneSilent
            && readiness?.heardMicrophoneSound != true
        readiness = nil
        let warning = [
            startupWarning, microphoneSilent ? Self.silentMicrophoneWarning : nil,
        ].compactMap { $0 }.joined(separator: " ")
        completion(.success(MeetingCaptureStart(
            startedAt: date,
            systemAudio: startupSystemAudio && !didSystemAudioFail,
            micRelativePath: "\(meetingID)/me.caf",
            systemRelativePath: startupSystemAudio && !didSystemAudioFail
                ? MeetingSystemAudioPolicy.relativePath(meetingID: meetingID) : nil,
            warning: warning.isEmpty ? nil : warning,
            microphoneSilent: microphoneSilent)))
    }

    /// Bounds device negotiation plus first-frame readiness.
    private static let startupTimeoutSeconds: TimeInterval = 5

    private func scheduleStartupTimeout() {
        startupTimeout?.cancel()
        let meetingID = self.meetingID
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.meetingID == meetingID, self.startedAt == nil,
                  let readiness = self.readiness else { return }
            let missing = readiness.missingTracks
            if missing.contains(.microphone) {
                // Frames of exact zeros still start the meeting, degraded and
                // flagged, so the computer-audio side is not lost with it. A
                // mic that failed to write or stream is not silent: it fails.
                guard readiness.microphoneDeliveredOnlySilence else {
                    let completion = self.startupCompletion
                    self.startupCompletion = nil
                    let message = readiness.microphoneFailure
                        ?? "no microphone audio arrived; check the selected input device"
                    self.abortPreparedCapture(meetingID: meetingID ?? "") {
                        completion?(.failure(.microphone(message)))
                    }
                    return
                }
                veloraLog(
                    "Velora: meeting microphone delivered only silence for the first "
                    + "\(Int(Self.startupTimeoutSeconds)) s; recording continues degraded")
                self.startupMicrophoneSilent = true
                if readiness.continueWithSilentMicrophone() { self.finishStartupIfReady() }
            }
            if missing.contains(.systemAudio) {
                self.markSystemAudioFailed()
                self.stopSystemAudio { _ in
                    if let systemURL = self.systemURL {
                        try? FileManager.default.removeItem(at: systemURL)
                    }
                    self.startupSystemAudio = false
                    self.startupWarning = [
                        self.startupWarning,
                        "Mac audio did not deliver any samples. This meeting is recording your mic only.",
                    ].compactMap { $0 }.joined(separator: " ")
                    if readiness.continueWithoutSystemAudio() { self.finishStartupIfReady() }
                }
            }
        }
        startupTimeout = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.startupTimeoutSeconds, execute: item)
    }

    private func systemCaptureDidFail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            if self.startedAt == nil, let readiness = self.readiness {
                self.markSystemAudioFailed()
                self.stopSystemAudio { _ in
                    if let systemURL = self.systemURL {
                        try? FileManager.default.removeItem(at: systemURL)
                    }
                    self.startupSystemAudio = false
                    self.startupWarning = Self.systemAudioWarning(for: NSError(
                        domain: "VeloraSystemAudioCapture", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: message]))
                    if readiness.continueWithoutSystemAudio() { self.finishStartupIfReady() }
                }
            } else {
                self.reportSystemAudioFailure(message)
                // A terminal writer/device failure cannot recover in-place.
                // Tear the tap down now instead of invoking a failing callback
                // for the rest of a long meeting and wasting CPU indefinitely.
                self.stopSystemAudio { _ in }
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
            self.stopSystemAudio { _ in
                self.meetingID = nil
                self.startedAt = nil
                self.micURL = nil
                self.systemURL = nil
                self.readiness = nil
                self.microphoneLevel = nil
                self.startupCompletion = nil
                self.startupSystemAudio = false
                self.startupWarning = nil
                try? FileManager.default.removeItem(
                    at: AppConfig.meetingsDirectory
                        .appendingPathComponent(meetingID, isDirectory: true))
            }
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
    private func writeMicrophone(
        _ buffer: AVAudioPCMBuffer, readiness: MeetingCaptureReadiness,
        level: MicrophoneLevelState
    ) {
        guard let micURL else { return }
        do {
            if micFile == nil {
                // The capture route may be non-interleaved. The settings-only
                // initializer lets AVAudioFile silently choose a different
                // client layout, then Core Audio traps inside ExtAudioFileWrite
                // when the live buffer arrives. Pin the processing layout to
                // the callback's real PCM format, as the system track does.
                micFile = try AVAudioFile(
                    forWriting: micURL,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: micURL.path)
            }
            try micFile?.write(from: buffer)
            let frames = Int(buffer.frameLength)
            let peak = MeetingPCMLevel.peak(buffer)
            if readiness.recordMicrophone(frames: frames, peak: peak) {
                DispatchQueue.main.async { [weak self] in self?.finishStartupIfReady() }
            }
            observeMicrophoneLevel(buffer, peak: peak, level: level)
        } catch {
            readiness.recordMicrophoneFailure(error.localizedDescription)
            reportMicrophoneFailure(error.localizedDescription)
        }
    }

    /// Diagnostics and the silent-microphone watch, on the sample queue.
    /// The first buffer logs which device and format this meeting records,
    /// so a silent track can be traced to its cause afterwards.
    private func observeMicrophoneLevel(
        _ buffer: AVAudioPCMBuffer, peak: Float, level: MicrophoneLevelState
    ) {
        let format = buffer.format
        if !level.loggedFormat {
            level.loggedFormat = true
            let persistedUID = level.persistedUID
            let formatDescription = Self.describe(format)
            // Device discovery and IOKit can block; the sample queue must
            // keep draining buffers in real time.
            DispatchQueue.global(qos: .utility).async {
                veloraLog(
                    "Velora: meeting microphone "
                    + "\(Self.microphoneDeviceDescription(persistedUID: persistedUID)) "
                    + "format=\(formatDescription) "
                    + "clamshell=\(Self.clamshellState())")
            }
        }
        let events = level.watch.observe(
            peak: peak, frames: Int(buffer.frameLength), sampleRate: format.sampleRate)
        for event in events {
            switch event {
            case .firstWindow(let windowPeak):
                veloraLog(String(
                    format: "Velora: meeting microphone first %.0f s peak=%.6f",
                    MeetingMicrophoneLevelWatch.firstWindowSeconds, windowPeak))
            case .firstSound:
                veloraLog("Velora: meeting microphone delivered its first sound after opening zeros")
                notifySilenceChange(.sound, level: level)
            case .silent(let afterSound):
                veloraLog(
                    "Velora: meeting microphone recorded only digital silence for "
                    + "\(Int(MeetingMicrophoneLevelWatch.silentAlertSeconds)) s"
                    + (afterSound ? " after delivering sound" : ", never any sound"))
                notifySilenceChange(afterSound ? .afterSound : .neverHeard, level: level)
            case .recovered:
                veloraLog("Velora: meeting microphone is delivering sound again")
                notifySilenceChange(.sound, level: level)
            }
        }
    }

    /// Delivers a silence change on main, only while `level` is still the
    /// current capture's: a report queued by a stopped capture must not
    /// flag the next meeting's microphone.
    private func notifySilenceChange(
        _ change: MeetingMicrophoneSilence, level: MicrophoneLevelState
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing, self.microphoneLevel === level else { return }
            self.onMicrophoneSilenceChange?(change)
        }
    }

    /// Mirrors MicrophoneStreamCapture's device choice (same policy, same
    /// inputs) for the diagnostic log only.
    private static func microphoneDeviceDescription(persistedUID: String?) -> String {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let uid = MicrophoneCaptureDevicePolicy.selectedUID(
            persistedUID: persistedUID,
            availableUIDs: devices.map(\.uniqueID),
            defaultUID: AVCaptureDevice.default(for: .audio)?.uniqueID)
        guard let device = devices.first(where: { $0.uniqueID == uid }) else {
            return "device=unknown"
        }
        return "device=\"\(device.localizedName)\" uid=\(device.uniqueID)"
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let description = format.streamDescription.pointee
        let kind = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int"
        return "\(kind)\(description.mBitsPerChannel)/\(Int(format.sampleRate))Hz/"
            + "\(format.channelCount)ch"
    }

    /// The built-in mic is hardware-disconnected while a MacBook lid is
    /// closed, which is one known source of an all-zero microphone track.
    /// "unknown" on desktops and when IOKit does not answer.
    private static func clamshellState() -> String {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return "unknown" }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        guard let closed = value as? Bool else { return "unknown" }
        return closed ? "closed" : "open"
    }

    private func reportMicrophoneFailure(_ message: String) {
        failureLock.lock()
        let shouldReport = !stopping && !microphoneWriteFailed
        microphoneWriteFailed = true
        failureLock.unlock()
        guard shouldReport else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            // Before the recording exists nobody handles this callback (the
            // coordinator is still preparing), and the report fires once, so
            // a startup failure fails the start here instead.
            if self.startedAt == nil, let completion = self.startupCompletion,
               let meetingID = self.meetingID {
                self.startupCompletion = nil
                self.abortPreparedCapture(meetingID: meetingID) {
                    completion(.failure(.microphone(message)))
                }
                return
            }
            self.onMicrophoneFailure?(message)
        }
    }
}

/// One capture's microphone diagnostics, confined to the sample queue
/// (the object identity alone is compared on main).
private final class MicrophoneLevelState {
    /// The input-device choice read on main when the capture started.
    let persistedUID: String?
    var watch = MeetingMicrophoneLevelWatch()
    var loggedFormat = false

    init(persistedUID: String?) {
        self.persistedUID = persistedUID
    }
}

/// Watches the microphone track for digital silence. A device that
/// delivers frames of exact zeros (a lid-closed built-in mic, a muted
/// interface) passes every frame check yet records nothing, and no one
/// noticed until the meeting had no "Me" lines. Pure; fed per buffer.
///
///     buffer ─► observe(peak:frames:sampleRate:)
///                 ├─ .firstWindow(peak)     once, after the first 10 s
///                 ├─ .firstSound            first sound after opening zeros
///                 ├─ .silent(afterSound:)   after 30 s of digital silence
///                 └─ .recovered             first sound after .silent
struct MeetingMicrophoneLevelWatch {
    enum Event: Equatable {
        case firstWindow(peak: Float)
        /// A Bluetooth HFP route or Krisp can open with seconds of zeros;
        /// the startup check has flagged that mic silent by then.
        case firstSound
        /// `afterSound` is false while the device has never delivered sound.
        case silent(afterSound: Bool)
        case recovered
    }

    static let firstWindowSeconds: Double = 10
    static let silentAlertSeconds: Double = 30

    private var elapsedFrames = 0
    private var zeroRunFrames = 0
    private var firstWindowPeak: Float = 0
    private var reportedFirstWindow = false
    private var reportedSilence = false
    private var heardSound = false

    mutating func observe(peak: Float, frames: Int, sampleRate: Double) -> [Event] {
        guard frames > 0, sampleRate > 0 else { return [] }
        var events: [Event] = []

        // Frame counts, not summed seconds: 300 × 0.1 s must be exactly 30 s.
        elapsedFrames += frames
        if !reportedFirstWindow {
            firstWindowPeak = max(firstWindowPeak, peak)
            if Double(elapsedFrames) >= Self.firstWindowSeconds * sampleRate {
                reportedFirstWindow = true
                events.append(.firstWindow(peak: firstWindowPeak))
            }
        }

        guard MeetingPCMLevel.isSilent(peak) else {
            let openedWithZeros = !heardSound && zeroRunFrames > 0
            heardSound = true
            zeroRunFrames = 0
            if reportedSilence {
                reportedSilence = false
                events.append(.recovered)
            } else if openedWithZeros {
                events.append(.firstSound)
            }
            return events
        }
        zeroRunFrames += frames
        if !reportedSilence,
           Double(zeroRunFrames) >= Self.silentAlertSeconds * sampleRate {
            reportedSilence = true
            events.append(.silent(afterSound: heardSound))
        }
        return events
    }
}

/// Peak sample level of a capture buffer, 0...1 of full scale. Exactly 0
/// means every sample in every channel was digital zero.
enum MeetingPCMLevel {
    private static let int16FullScale: Float = 32_768
    private static let int32FullScale: Float = 2_147_483_648
    /// The loudest peak that is still digital silence: one 16-bit step.
    /// The engine skips a track by the same line (server.py
    /// `MEETING_SILENT_TRACK_MAX_PEAK`), so capture's silent-mic alert and
    /// the engine's silent track always agree. Example: Int16 samples of
    /// ±1 are silent; ±2 are sound.
    private static let silenceMaxPeak: Float = 1 / int16FullScale

    /// True when `peak` is digital silence: exact zeros, or ±1 LSB dither.
    static func isSilent(_ peak: Float) -> Bool {
        peak <= silenceMaxPeak
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        let format = buffer.format
        // Interleaved data is one buffer of frames × channels samples.
        let channels = Int(format.channelCount)
        let buffers = format.isInterleaved ? 1 : channels
        let samples = Int(buffer.frameLength) * (format.isInterleaved ? channels : 1)
        var peak: Float = 0
        // Only a standard layout's typed accessor is trusted: AVFoundation
        // also returns int32ChannelData for 24-bit samples padded to four
        // bytes, whose full scale is 2^23, not 2^31.
        let common = format.commonFormat
        if common == .pcmFormatFloat32, let data = buffer.floatChannelData {
            for channel in 0..<buffers {
                for index in 0..<samples {
                    peak = max(peak, abs(data[channel][index]))
                }
            }
            return peak
        }
        if common == .pcmFormatInt16, let data = buffer.int16ChannelData {
            for channel in 0..<buffers {
                for index in 0..<samples {
                    peak = max(peak, Float(abs(Int32(data[channel][index]))) / int16FullScale)
                }
            }
            return peak
        }
        if common == .pcmFormatInt32, let data = buffer.int32ChannelData {
            for channel in 0..<buffers {
                for index in 0..<samples {
                    peak = max(peak, Float(abs(Int64(data[channel][index]))) / int32FullScale)
                }
            }
            return peak
        }
        // Layouts without a typed accessor (Float64, big-endian samples,
        // and 24-bit integers packed in three bytes or padded to four) are
        // read from their bytes in their own byte order and normalized the
        // same way, so the silence line means the same for every format
        // MeetingTrackFormat accepts. Example: a 24-bit sample of 256 is
        // one 16-bit step, still silence.
        let description = format.streamDescription.pointee
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let sampleBytes = Int(description.mBytesPerFrame) / (format.isInterleaved ? channels : 1)
        // An integer header without a bit depth gives no scale.
        let readable = isFloat
            ? floatSampleBytes.contains(sampleBytes)
            : integerSampleBytes.contains(sampleBytes) && description.mBitsPerChannel > 0
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let bytes = audio.mData?.assumingMemoryBound(to: UInt8.self) else { continue }
            guard readable else {
                // Unknown scale: any nonzero byte is sound, the safe side.
                for index in 0..<Int(audio.mDataByteSize) where bytes[index] != 0 {
                    return 1
                }
                continue
            }
            for index in 0..<samples {
                let sample = bytes + index * sampleBytes
                peak = max(peak, isFloat
                    ? floatLevel(sample, width: sampleBytes, description)
                    : integerLevel(sample, width: sampleBytes, description))
            }
        }
        return peak
    }

    /// Integer sample widths `integerLevel` reads, in bytes.
    private static let integerSampleBytes = 2...4
    /// Float sample widths `floatLevel` reads: Float32 and Float64.
    private static let floatSampleBytes: Set<Int> = [4, 8]

    /// One sample's bytes as an unsigned value, most significant byte
    /// first whatever the format's byte order.
    private static func sampleBits(
        _ bytes: UnsafePointer<UInt8>, width: Int,
        _ description: AudioStreamBasicDescription
    ) -> UInt64 {
        let bigEndian = description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        var raw: UInt64 = 0
        for offset in 0..<width {
            raw = raw << 8 | UInt64(bytes[bigEndian ? offset : width - 1 - offset])
        }
        return raw
    }

    /// One Float32 or Float64 sample's magnitude.
    private static func floatLevel(
        _ bytes: UnsafePointer<UInt8>, width: Int,
        _ description: AudioStreamBasicDescription
    ) -> Float {
        let raw = sampleBits(bytes, width: width, description)
        if width == MemoryLayout<Double>.size {
            return Float(abs(Double(bitPattern: raw)))
        }
        return abs(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
    }

    /// One integer sample as a fraction of full scale. Its bytes are
    /// shifted so the sample's sign bit lands on bit 31, whatever its width
    /// or padding, then measured against 2^31.
    ///
    ///     packed 24-bit  00 01 00 (256)   -> 0x00010000 << 8 -> 1 / 32_768
    ///     24 in 32, low  00 01 00 00      -> 0x00000100 << 8 -> 1 / 32_768
    private static func integerLevel(
        _ bytes: UnsafePointer<UInt8>, width: Int,
        _ description: AudioStreamBasicDescription
    ) -> Float {
        let containerBits = UInt32(8 * width)
        var raw = UInt32(truncatingIfNeeded: sampleBits(bytes, width: width, description))
        raw <<= 32 - containerBits
        // A sample narrower than its container sits at the low end unless
        // the format says it is aligned high.
        let bits = description.mBitsPerChannel
        let alignedHigh = description.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        if bits < containerBits && !alignedHigh {
            raw <<= containerBits - bits
        }
        return Float(abs(Int64(Int32(bitPattern: raw)))) / int32FullScale
    }
}

/// A change in the recording microphone's silence, as capture reports it.
enum MeetingMicrophoneSilence: Equatable {
    /// Only exact zeros so far: the device never delivered sound.
    case neverHeard
    /// Exact zeros after the device delivered real sound.
    case afterSound
    /// Sound arrived after zeros.
    case sound
}
