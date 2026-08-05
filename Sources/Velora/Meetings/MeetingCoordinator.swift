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
        /// A detected call is waiting for explicit per-meeting consent. This is
        /// presented by the existing HUD, never a focus-stealing NSAlert.
        case suggesting(title: String, sourceApp: String?)
        case preparing(title: String)
        case recording(
            id: String, title: String, startedAt: Date,
            systemAudio: Bool, endDetected: Bool)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isActive: Bool {
            switch self {
            case .preparing, .recording: return true
            case .idle, .suggesting: return false
            }
        }
    }

    private let config = AppConfig.shared
    private let capture = MeetingAudioCapture()
    private let detector: MeetingDetector
    private let store: MeetingStore
    private let processor: MeetingProcessor
    private let sounds: SoundPlayer
    private let foregroundBusy: () -> Bool
    private var pendingCandidate: MeetingCandidate?
    private var pendingMetadata: (source: String?, calendarID: String?)?
    private var pendingMeetingID: String?
    private var finishingMeetingID: String?
    private var discardingMeetingID: String?
    private var finishCallbacks: [() -> Void] = []
    /// The one alert capable of starting a new capture. Other informational
    /// alerts may close naturally, but this token is revoked during teardown.
    private var consentToken: UUID?
    private var endWatch = MeetingEndWatch()
    private var discardConfirmToken: UUID?
    /// True once this recording's scoped call was confirmed by microphone
    /// activity. A native app mic can authorize automatic stop; a browser mic
    /// only changes the presence signal from stale titles to bundle activity,
    /// and its eventual absence still asks.
    private var recordingMicEvidence = false
    /// Binds the watch to the call it was armed for. Presence from an
    /// unrelated source (another app's call, a website on the mic) must not
    /// sustain the watch or arm auto-stop.
    private var watchScope: MeetingWatchScope = .unknown
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
        detector.onActivity = { [weak self] presences in self?.handleActivity(presences) }
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
                calendarID: nil,
                channel: .unknown)
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
        if let token = discardConfirmToken {
            discardConfirmToken = nil
            VisibleAlert.dismiss(token)
        }
        if let token = consentToken {
            // Clear state before dismiss: VisibleAlert completes synchronously,
            // and its callback must observe that approval has been revoked.
            consentToken = nil
            state = .idle
            VisibleAlert.dismiss(token)
            completion()
            return
        }
        if case .suggesting = state {
            pendingCandidate = nil
            state = .idle
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
        guard case .recording(let id, let title, _, _, _) = state else {
            completion?()
            return
        }
        settleEndWatch()
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
        guard case .recording(let meetingID, _, _, _, _) = state,
              discardConfirmToken == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this meeting recording?"
        alert.informativeText = "The temporary microphone and system-audio files will be deleted. No meeting will be saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Recording")
        // Owned token: if the recording stops through another path first,
        // settleEndWatch withdraws this destructive question instead of
        // leaving it stranded over an already-saved meeting.
        discardConfirmToken = VisibleAlert.present(alert) { [weak self] response in
            guard let self else { return }
            self.discardConfirmToken = nil
            guard response == .alertFirstButtonReturn,
                  case .recording(let currentID, _, _, _, _) = self.state,
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
        guard !terminating, config.meetingSuggestions else { return }
        guard state == .idle, !foregroundBusy() else {
            // The detector marks a candidate delivered before invoking us. If
            // the shared foreground/HUD is busy, release that debounce so the
            // same still-live call retries on the next five-second poll.
            detector.resetSuggestionDebounce()
            return
        }
        pendingCandidate = candidate
        state = .suggesting(title: candidate.title, sourceApp: candidate.sourceApp)
        veloraLog(
            "Velora: meeting suggestion shown in HUD "
            + "source=\(candidate.sourceApp ?? "unknown") "
            + "confidence=\(candidate.confidence) mic=\(candidate.micBacked ? "yes" : "no") "
            + "calendar=\(candidate.calendarEventID == nil ? "no" : "yes")")
        // Watch while the question is up so a huddle that ends unanswered
        // withdraws its own stale prompt. Seeded as confirmed: the candidate
        // poll was the evidence.
        if candidate.callConfirmed {
            watchScope = .forChannel(candidate.channel)
            // An unanswered prompt should withdraw promptly. The longer
            // browser streak is reserved for an actual recording, where a
            // long mute must not look like a definitive end.
            endWatch = MeetingEndWatch(
                threshold: min(4, watchScope.endThreshold), confirmed: true)
            detector.setEndWatch(true)
        }
    }

    func acceptSuggestion() {
        guard !terminating, case .suggesting = state,
              let candidate = pendingCandidate else { return }
        detector.setEndWatch(false)
        state = .preparing(title: "Checking call…")
        detector.revalidate(candidate) { [weak self] current in
            guard let self, !self.terminating,
                  self.pendingCandidate?.key == candidate.key,
                  self.state == .preparing(title: "Checking call…") else { return }
            guard let current else {
                self.pendingCandidate = nil
                self.detector.resetSuggestionDebounce()
                self.state = .preparing(title: "Call no longer detected")
                veloraLog("Velora: meeting suggestion was stale at consent — recording not started")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self,
                          self.state == .preparing(title: "Call no longer detected") else {
                        return
                    }
                    self.state = .idle
                }
                return
            }
            self.pendingCandidate = nil
            veloraLog("Velora: meeting suggestion accepted in HUD after live re-check")
            self.beginCapture(
                title: current.title, source: current.sourceApp,
                calendarID: current.calendarEventID,
                channel: current.channel,
                callConfirmed: current.callConfirmed,
                micBacked: current.micBacked,
                foregroundAlreadyOwned: true)
        }
    }

    func declineSuggestion() {
        dismissSuggestion(reason: "dismissed in HUD")
    }

    /// A suggestion owns no microphone and must never block an explicit
    /// dictation. AppDelegate calls this at the start boundary so the shared
    /// HUD cannot remain logically stuck after dictation replaces it.
    func yieldSuggestionToForegroundOperation() {
        dismissSuggestion(reason: "yielded to foreground recording", rearm: true)
    }

    private func dismissSuggestion(reason: String, rearm: Bool = false) {
        guard case .suggesting = state else { return }
        pendingCandidate = nil
        detector.setEndWatch(false)
        endWatch = MeetingEndWatch()
        watchScope = .unknown
        // Yield happens before dictation preflight. If that preflight fails,
        // the still-live call must be eligible for another prompt; an explicit
        // user dismissal intentionally keeps the detector's episode debounce.
        if rearm { detector.resetSuggestionDebounce() }
        state = .idle
        veloraLog("Velora: meeting suggestion \(reason)")
    }

    private func handleActivity(_ presences: [MeetingPresence]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !terminating else { return }
        // Presence only counts when it belongs to the call this watch was
        // armed for; an unrelated call or a website on the mic is neither
        // "the meeting continues" nor "the meeting ended".
        let relevant = presences.filter(watchScope.matches)
        // Once the microphone has confirmed this recording, only attributable
        // microphone presence may sustain it. A stale Meet/Zoom title can stay
        // open on a post-call screen and must not pin recording forever.
        let present = recordingMicEvidence
            ? relevant.contains(where: \.micBacked)
            : !relevant.isEmpty
        if state.isRecording,
           relevant.contains(where: watchScope.mayLatchMicEvidence) {
            recordingMicEvidence = true
        }
        // The destructive confirmation freezes observation entirely: an end
        // event consumed now could neither prompt nor ever re-fire (the call
        // is gone and cannot re-confirm the watch).
        guard discardConfirmToken == nil else { return }
        switch state {
        case .suggesting:
            if case .ended = endWatch.observe(present: present) {
                // The call ended before the user answered the record prompt.
                veloraLog("Velora: meeting ended before consent — dismissing suggestion")
                pendingCandidate = nil
                detector.setEndWatch(false)
                endWatch = MeetingEndWatch()
                watchScope = .unknown
                state = .idle
            }
        case .recording(
            let id, let title, let startedAt, let systemAudio, let endDetected
        ):
            if endDetected {
                guard present else { return }
                // The call is back (rejoined, or a flaky poll) — withdraw the
                // HUD question rather than let it stop a live meeting.
                _ = endWatch.observe(present: true)
                state = .recording(
                    id: id, title: title, startedAt: startedAt,
                    systemAudio: systemAudio, endDetected: false)
                return
            }
            if case .ended = endWatch.observe(present: present) {
                meetingLikelyEnded()
            }
        case .idle, .preparing:
            break
        }
    }

    private func meetingLikelyEnded() {
        guard case .recording(
            let id, let title, let startedAt, let systemAudio, false
        ) = state,
              discardConfirmToken == nil else { return }
        // No preference for this: attribution decides. A native client's own
        // mic closing is a definitive end. Browser mic ownership is only
        // bundle-wide, and title/manual inferences can be stale, so both ask.
        if recordingMicEvidence, watchScope.mayAutoStop {
            veloraLog("Velora: native call released its microphone — stopping and creating notes")
            stopRecording()
            return
        }
        veloraLog("Velora: meeting end is not attributable enough to auto-stop — asking in HUD")
        state = .recording(
            id: id, title: title, startedAt: startedAt,
            systemAudio: systemAudio, endDetected: true)
    }

    func confirmMeetingEnded() {
        guard case .recording(_, _, _, _, true) = state else { return }
        stopRecording()
    }

    func keepMeetingRecording() {
        guard case .recording(
            let id, let title, let startedAt, let systemAudio, true
        ) = state else { return }
        state = .recording(
            id: id, title: title, startedAt: startedAt,
            systemAudio: systemAudio, endDetected: false)
        veloraLog("Velora: meeting end suggestion dismissed — keeping recording")
    }

    /// Arms end-of-meeting watching for a capture that just started. The
    /// scope binds the watch to this call's transport and decides the absence
    /// streak; manual recordings can never latch mic evidence.
    private func armEndWatch(
        channel: MeetingChannel, callConfirmed: Bool, micBacked: Bool
    ) {
        watchScope = .forChannel(channel)
        recordingMicEvidence = micBacked && watchScope != .unknown
        endWatch = MeetingEndWatch(
            threshold: watchScope.endThreshold,
            confirmed: callConfirmed)
        detector.setEndWatch(true)
    }

    /// Disarms watching and withdraws any open destructive confirmation.
    private func settleEndWatch() {
        detector.setEndWatch(false)
        endWatch = MeetingEndWatch()
        recordingMicEvidence = false
        watchScope = .unknown
        if let token = discardConfirmToken {
            discardConfirmToken = nil
            VisibleAlert.dismiss(token)
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

    private func beginCapture(
        title: String, source: String?, calendarID: String?,
        channel: MeetingChannel,
        callConfirmed: Bool = false, micBacked: Bool = false,
        foregroundAlreadyOwned: Bool = false
    ) {
        let mayStart = state == .idle
            || (foregroundAlreadyOwned && state == .preparing(title: "Checking call…"))
        guard !terminating, mayStart else { return }
        guard foregroundAlreadyOwned || !foregroundBusy() else {
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
                    startedAt: start.startedAt, systemAudio: start.systemAudio,
                    endDetected: false)
                self.armEndWatch(
                    channel: channel, callConfirmed: callConfirmed, micBacked: micBacked)
                self.sounds.play(.start)
                if let warning = start.warning {
                    veloraLog("Velora: meeting capture degraded: \(warning)")
                }
            }
        }
    }

    private func discardActiveCapture() {
        guard case .recording(let id, let title, _, _, _) = state else { return }
        settleEndWatch()
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
        guard case .recording(
            let id, let title, let startedAt, true, let endDetected
        ) = state else { return }
        state = .recording(
            id: id, title: title, startedAt: startedAt,
            systemAudio: false, endDetected: endDetected)
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
