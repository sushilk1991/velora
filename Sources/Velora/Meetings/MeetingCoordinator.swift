import AppKit
import Combine
import EventKit
import Foundation

final class MeetingCoordinator: ObservableObject {
    enum RecordingEndOutcome: Equatable {
        case saved
        case discarded
        case failed
    }

    enum SystemAudioFailurePresentation: Equatable {
        case hud
    }

    static let consentDescription =
        "Records your microphone and computer audio locally. Make sure everyone knows."
    static let systemAudioFailurePresentation: SystemAudioFailurePresentation = .hud

    enum State: Equatable {
        case idle
        case preparing(title: String)
        case recording(id: String, title: String, startedAt: Date, systemAudio: Bool)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isActive: Bool { self != .idle }
    }

    private let config = AppConfig.shared
    private let capture = MeetingAudioCapture()
    private let detector: MeetingDetector
    private let store: MeetingStore
    private let processor: MeetingProcessor
    private let sounds: SoundPlayer
    private let foregroundBusy: () -> Bool
    private var pendingMetadata: (source: String?, calendarID: String?)?
    private var pendingMeetingID: String?
    private var finishingMeetingID: String?
    private var discardingMeetingID: String?
    private var finishCallbacks: [() -> Void] = []
    /// The one alert capable of starting a new capture. Other informational
    /// alerts may close naturally, but this token is revoked during teardown.
    private var consentToken: UUID?
    private var terminating = false

    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    var onRecordingEnded: ((RecordingEndOutcome) -> Void)?

    init(
        store: MeetingStore,
        processor: MeetingProcessor,
        sounds: SoundPlayer,
        foregroundBusy: @escaping () -> Bool
    ) {
        self.store = store
        self.processor = processor
        self.sounds = sounds
        self.foregroundBusy = foregroundBusy
        detector = MeetingDetector(
            calendarEnabled: { AppConfig.shared.meetingCalendar },
            suggestionsEnabled: { AppConfig.shared.meetingSuggestions })
        detector.onCandidate = { [weak self] candidate in self?.suggest(candidate) }
        capture.onSystemAudioFailure = { [weak self] message in
            self?.systemAudioDidFail(message)
        }
        capture.onMicrophoneFailure = { [weak self] message in
            self?.microphoneDidFail(message)
        }
    }

    func start() {
        guard !terminating else { return }
        store.pruneAudio(olderThanDays: config.meetingAudioRetentionDays)
        // First launch must stay focused on permissions/onboarding, and a
        // suggestion is useless until capture can actually use the mic.
        guard config.onboardingComplete, Permissions.microphoneGranted else { return }
        detector.start()
    }

    func stop() {
        detector.stop()
    }

    func startManual() {
        guard !terminating, state == .idle else { return }
        let field = NSTextField(string: "Meeting")
        field.placeholderString = "Meeting title"
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        let alert = consentAlert(title: "Record a meeting?")
        alert.accessoryView = field
        state = .preparing(title: "Waiting for confirmation…")
        consentToken = VisibleAlert.present(alert) { [weak self, field] response in
            guard let self, self.consentToken != nil else { return }
            self.consentToken = nil
            guard !self.terminating, case .preparing = self.state else { return }
            self.state = .idle
            guard response == .alertFirstButtonReturn else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.beginCapture(
                title: title.isEmpty ? "Meeting" : title,
                source: nil,
                calendarID: nil)
        }
    }

    func stopRecording() {
        finishActiveRecording(enqueue: true, completion: nil)
    }

    /// Finalizes an active recording before app teardown. Graceful quit must
    /// never take the same path as an explicit discard. A capture still in its
    /// permission/preparation phase has no user audio and is removed cleanly.
    /// True while termination is genuinely waiting on meeting work — the
    /// AppDelegate watchdog extends its deadline instead of cutting a
    /// mid-flight recording finalize (pending CAF writes must be flushed).
    var terminationWorkInFlight: Bool {
        finishingMeetingID != nil || discardingMeetingID != nil
            || state.isRecording || capture.isCapturing
    }

    /// Includes device negotiation/teardown after the visible state has
    /// already reported a startup failure. This is the foreground exclusion
    /// truth used by dictation.
    var foregroundCaptureActive: Bool {
        state.isActive || capture.isCapturing
    }

    func finishForTermination(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        terminating = true
        detector.stop()
        if let token = consentToken {
            // Clear state before dismiss: VisibleAlert completes synchronously,
            // and its callback must observe that approval has been revoked.
            consentToken = nil
            state = .idle
            VisibleAlert.dismiss(token)
            completion()
            return
        }
        if finishingMeetingID != nil {
            veloraLog("Velora: termination waiting on meeting finish")
            finishCallbacks.append(completion)
            return
        }
        if discardingMeetingID != nil {
            veloraLog("Velora: termination waiting on meeting discard")
            finishCallbacks.append(completion)
            return
        }
        if state.isRecording {
            veloraLog("Velora: termination finalizing active meeting recording")
            finishActiveRecording(enqueue: false, completion: completion)
            return
        }
        guard capture.isCapturing else { completion(); return }
        veloraLog("Velora: termination stopping pending meeting capture")
        let pendingID = pendingMeetingID
        capture.stop(cancelled: true) { [weak self] _ in
            guard let self else { completion(); return }
            if let pendingID { self.store.delete(meetingID: pendingID) }
            self.pendingMeetingID = nil
            self.pendingMetadata = nil
            self.state = .idle
            completion()
        }
    }

    private func finishActiveRecording(
        enqueue: Bool,
        completion: (() -> Void)?
    ) {
        guard case .recording(let id, let title, _, _) = state else {
            completion?()
            return
        }
        if let completion { finishCallbacks.append(completion) }
        finishingMeetingID = id
        sounds.play(.stop)
        state = .preparing(title: "Saving \(title)…")
        capture.stop(cancelled: false) { [weak self] files in
            guard let self else { return }
            let metadata = self.pendingMetadata
            self.pendingMetadata = nil
            self.pendingMeetingID = nil
            self.finishingMeetingID = nil
            defer {
                let callbacks = self.finishCallbacks
                self.finishCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
            guard let files else {
                self.store.markFailed(
                    meetingID: id, error: "Recording could not be finalized")
                NotificationCenter.default.post(name: .veloraMeetingsChanged, object: nil)
                self.onRecordingEnded?(.failed)
                self.state = .idle
                return
            }
            let record = MeetingRecord(
                id: id, title: title,
                startedAt: files.startedAt, endedAt: files.endedAt,
                sourceApp: metadata?.source,
                calendarEventID: metadata?.calendarID,
                status: .processing,
                micPath: files.micRelativePath,
                systemPath: files.systemRelativePath)
            self.store.insertProcessing(record)
            NotificationCenter.default.post(name: .veloraMeetingsChanged, object: nil)
            // A manual stop can already be finalizing when Quit arrives. Keep
            // the durable processing row, but let next launch resume it rather
            // than starting fresh engine work during teardown.
            if enqueue && !self.terminating { self.processor.enqueue(meetingID: id) }
            self.onRecordingEnded?(.saved)
            self.state = .idle
        }
    }

    func cancelRecording() {
        guard case .recording(let meetingID, _, _, _) = state else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this meeting recording?"
        alert.informativeText = "The temporary microphone and system-audio files will be deleted. No meeting will be saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        VisibleAlert.present(alert) { [weak self] response in
            guard let self,
                  response == .alertFirstButtonReturn,
                  case .recording(let currentID, _, _, _) = self.state,
                  currentID == meetingID
            else { return }
            self.discardActiveCapture()
        }
    }

    func requestCalendarAccess(_ completion: @escaping (Bool) -> Void) {
        detector.requestCalendarAccess(completion)
    }

    func pruneAudio() {
        store.pruneAudio(olderThanDays: config.meetingAudioRetentionDays)
    }

    var calendarAuthorization: EKAuthorizationStatus {
        MeetingDetector.calendarAuthorization
    }

    private func suggest(_ candidate: MeetingCandidate) {
        guard !terminating, config.meetingSuggestions,
              state == .idle, !foregroundBusy() else { return }
        let alert = consentAlert(title: "Record \(candidate.title)?")
        alert.informativeText = "Velora detected \(candidate.sourceApp ?? "a scheduled call"). "
            + alert.informativeText
        state = .preparing(title: "Waiting for confirmation…")
        consentToken = VisibleAlert.present(alert) { [weak self] response in
            guard let self, self.consentToken != nil else { return }
            self.consentToken = nil
            guard !self.terminating, case .preparing = self.state else { return }
            self.state = .idle
            guard response == .alertFirstButtonReturn else { return }
            self.beginCapture(
                title: candidate.title, source: candidate.sourceApp,
                calendarID: candidate.calendarEventID)
        }
    }

    private func consentAlert(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = Self.consentDescription
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    private func beginCapture(title: String, source: String?, calendarID: String?) {
        guard !terminating, state == .idle else { return }
        guard !foregroundBusy() else {
            showError("Finish the current dictation or file transcription first")
            return
        }
        let id = UUID().uuidString
        pendingMetadata = (source, calendarID)
        pendingMeetingID = id
        let placeholderStart = Date()
        store.insertRecording(MeetingRecord(
            id: id, title: title,
            startedAt: placeholderStart, endedAt: placeholderStart,
            sourceApp: source, calendarEventID: calendarID,
            status: .recording,
            micPath: "\(id)/me.caf",
            systemPath: MeetingSystemAudioPolicy.relativePath(meetingID: id)))
        state = .preparing(title: title)
        capture.start(meetingID: id) { [weak self] result in
            guard let self else { return }
            guard !self.terminating else {
                if self.capture.isCapturing {
                    self.capture.stop(cancelled: true) { [weak self] _ in
                        self?.store.delete(meetingID: id)
                    }
                } else {
                    self.store.delete(meetingID: id)
                }
                self.pendingMetadata = nil
                self.pendingMeetingID = nil
                self.state = .idle
                return
            }
            switch result {
            case .failure(let error):
                self.pendingMetadata = nil
                self.pendingMeetingID = nil
                self.store.delete(meetingID: id)
                self.state = .idle
                self.sounds.play(.error)
                self.showError(error.localizedDescription)
            case .success(let start):
                let recording = MeetingRecord(
                    id: id, title: title,
                    startedAt: start.startedAt, endedAt: start.startedAt,
                    sourceApp: source, calendarEventID: calendarID,
                    status: .recording,
                    micPath: start.micRelativePath,
                    systemPath: start.systemRelativePath)
                self.store.insertRecording(recording)
                self.state = .recording(
                    id: id, title: title,
                    startedAt: start.startedAt, systemAudio: start.systemAudio)
                self.sounds.play(.start)
                if let warning = start.warning {
                    veloraLog("Velora: meeting capture degraded: \(warning)")
                }
            }
        }
    }

    private func discardActiveCapture() {
        guard case .recording(let id, let title, _, _) = state else { return }
        discardingMeetingID = id
        state = .preparing(title: "Discarding \(title)…")
        sounds.play(.stop)
        capture.stop(cancelled: true) { [weak self] _ in
            guard let self else { return }
            self.store.delete(meetingID: id)
            self.pendingMeetingID = nil
            self.pendingMetadata = nil
            self.discardingMeetingID = nil
            self.onRecordingEnded?(.discarded)
            self.state = .idle
            let callbacks = self.finishCallbacks
            self.finishCallbacks.removeAll()
            callbacks.forEach { $0() }
        }
    }

    private func systemAudioDidFail(_ message: String) {
        guard case .recording(let id, let title, let startedAt, true) = state else { return }
        state = .recording(id: id, title: title, startedAt: startedAt, systemAudio: false)
        sounds.play(.error)
        veloraLog("Velora: meeting computer audio stopped: \(message)")
    }

    private func microphoneDidFail(_ message: String) {
        guard state.isRecording else { return }
        // A meeting without a reliable local track should not keep appearing
        // healthy. Stop immediately, retain whatever was captured, and tell
        // the user exactly what happened.
        stopRecording()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Microphone recording stopped"
        alert.informativeText = "Velora stopped the meeting because it could no longer write microphone audio (\(message)). Audio captured before the failure will still be saved and processed."
        alert.addButton(withTitle: "OK")
        VisibleAlert.present(alert) { _ in }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Meeting capture unavailable"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        VisibleAlert.present(alert) { _ in }
    }

}
