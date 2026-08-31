import AppKit
import Foundation

enum MeetingProcessingHUDPolicy {
    static func shouldShow(
        dictationIsIdle: Bool,
        meetingIsIdle: Bool,
        hudAllowsMeetingProgress: Bool
    ) -> Bool {
        dictationIsIdle && meetingIsIdle && hudAllowsMeetingProgress
    }
}

struct MeetingFailureHUDQueue {
    private var states: [HUDState] = []

    var first: HUDState? { states.first }
    var isEmpty: Bool { states.isEmpty }

    mutating func retain(meetingID: String, message: String) {
        remove(meetingID: meetingID)
        states.append(.meetingFailure(meetingID: meetingID, message: message))
    }

    mutating func remove(meetingID: String) {
        states.removeAll {
            if case .meetingFailure(let id, _) = $0 { return id == meetingID }
            return false
        }
    }

    func state(meetingID: String) -> HUDState? {
        states.first {
            if case .meetingFailure(let id, _) = $0 { return id == meetingID }
            return false
        }
    }
}

enum MeetingFailureHUDReplayPolicy {
    static func shouldShow(
        dictationIsIdle: Bool,
        meetingIsIdle: Bool,
        processorAllowsFailure: Bool,
        hudIsAvailable: Bool,
        ownsVisibleHUD: Bool
    ) -> Bool {
        dictationIsIdle && meetingIsIdle && processorAllowsFailure
            && (hudIsAvailable || ownsVisibleHUD)
    }
}

enum UpdateRelaunchSafety {
    static func blockReason(
        dictationBusy: Bool,
        fileTranscriptionBusy: Bool,
        meetingCaptureBusy: Bool
    ) -> String? {
        if dictationBusy {
            return "Waiting for dictation or voice editing to finish"
        }
        if fileTranscriptionBusy {
            return "Waiting for audio-file transcription to finish"
        }
        if meetingCaptureBusy {
            return "Waiting for the meeting recording to finish"
        }
        return nil
    }
}

/// Owns the live revocation edge separately from the settings window. Keeping
/// this tiny observer injectable makes the security boundary deterministic to
/// test without constructing the full application graph.
final class LocalAgentAccessRevocationObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        center: NotificationCenter = .default,
        onRevoke: @escaping () -> Void
    ) {
        self.center = center
        token = center.addObserver(
            forName: .veloraLocalAgentAccessChanged, object: nil, queue: .main
        ) { notification in
            guard notification.object as? Bool == false else { return }
            onRevoke()
        }
    }

    func stop() {
        if let token { center.removeObserver(token) }
        token = nil
    }

    deinit { stop() }
}

/// Composition root: builds every module, wires delegates, and owns app
/// lifecycle (engine supervision, onboarding on first launch, teardown).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static let terminationWatchdogBase: TimeInterval = 8
    private static let meetingWatchdogExtension: TimeInterval = 52

    private let config = AppConfig.shared
    private let supervisor = EngineSupervisor()
    private let contextTracker = AppContextTracker()
    private let hotkeyMonitor = HotkeyMonitor()
    private let hud = HUDPanel()
    private let sounds = SoundPlayer()

    private var history: HistoryStore!
    private var meetings: MeetingStore!
    private var meetingProcessor: MeetingProcessor!
    private var meetingCoordinator: MeetingCoordinator!
    private var dictionary: DictionaryRepository!
    private var dictionarySync: ICloudDictionarySync!
    private var dictation: DictationController!
    private var transcriber: FileTranscriber!
    private var controlServer: LocalControlServer?
    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController?
    private var meetingNotesController: MeetingNotesWindowController?
    private var onboardingController: OnboardingWindowController?
    private var hotkeyObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var loadingObserver: NSObjectProtocol?
    private var hudPrefsObserver: NSObjectProtocol?
    private var localAgentAccessObserver: LocalAgentAccessRevocationObserver?
    private var meetingHUDActive = false
    /// Exact state last placed on the shared HUD by a meeting flow. Equality
    /// is the ownership token: teardown never hides a state
    /// another controller has since placed there.
    private var meetingOwnedHUDState: HUDState?
    private var meetingEndOutcome: MeetingCoordinator.RecordingEndOutcome?
    private var meetingProcessingHUDActive = false
    /// Retained until Retry/success so a dictation that temporarily owns the
    /// shared HUD cannot permanently swallow meeting recovery controls.
    private var meetingFailureHUDQueue = MeetingFailureHUDQueue()
    private var meetingHUDDismiss: DispatchWorkItem?
    private var terminationPending = false
    private var terminationReplied = false
    private var openFileTranscriptionQueue = FileTranscriptionQueue()
    private var openFileRetryPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. LSUIElement covers the bundled app; the programmatic
        // call is the reliable path for bare `swift build` binaries.
        NSApp.setActivationPolicy(.accessory)
        // Ready before any window opens: the moment the app becomes regular
        // (AppActivation), the menu bar must show real menus.
        MainMenu.install(target: self)
        SettingsModel.applyAppearance(config.appearance)

        config.ensureVeloraDirectory()
        // settings.json is the app source of truth. Re-project its engine-facing
        // subset on every launch so a directly-copied portable file takes effect.
        config.writeEngineConfig()
        // Drop a stale mic choice that points at the HAL's private aggregate
        // (selectable before it was filtered) so it is never misread as a
        // disconnected mic mid-meeting.
        AudioInputDevices.sanitizePersistedSelection()

        history = HistoryStore()
        meetings = MeetingStore()
        dictionary = DictionaryRepository(reload: { [weak self] in
            self?.supervisor.send(["cmd": "reload_config"])
        })
        dictionarySync = ICloudDictionarySync(repository: dictionary)
        // Transcript text is tiny and kept indefinitely; only the audio archive
        // expires (the engine prunes clips). Play just disables when a row's
        // clip has aged out. `pruneOlderThan` stays available for a future
        // user-configurable text-retention setting.
        dictation = DictationController(
            supervisor: supervisor,
            contextTracker: contextTracker,
            hud: hud,
            history: history,
            sounds: sounds,
            dictionary: dictionary)
        hud.onAvailable = { [weak self] in
            self?.dictation.hudDidBecomeAvailable()
            self?.showMeetingFailureIfPossible()
        }
        statusController = StatusItemController(history: history)
        transcriber = FileTranscriber(
            supervisor: supervisor, hud: hud,
            hudIsFree: { [weak self] in
                guard let self else { return false }
                return self.dictation.phase == .idle && self.hud.model.state.isAvailable
            })
        transcriber.onStateChange = { [weak self] in
            guard let self else { return }
            self.statusController.transcriptionProgress = self.transcriber.progressLabel
            self.drainOpenFileTranscriptions()
        }
        transcriber.onQueuedFileBusy = { [weak self] url in
            guard let self else { return }
            self.openFileTranscriptionQueue.retry(url)
            self.openFileRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.terminationPending else { return }
                self.openFileRetryPending = false
                self.drainOpenFileTranscriptions()
            }
        }
        meetingProcessor = MeetingProcessor(supervisor: supervisor, store: meetings)
        hud.model.onMeetingFailureOpen = { [weak self] meetingID in
            self?.clearMeetingFailure(meetingID: meetingID)
            self?.showMeetingNotes(meetingID: meetingID)
        }
        hud.model.onMeetingFailureRetry = { [weak self] meetingID in
            self?.clearMeetingFailure(meetingID: meetingID)
            self?.meetingProcessor.enqueue(meetingID: meetingID)
        }
        meetingCoordinator = MeetingCoordinator(
            store: meetings, processor: meetingProcessor, sounds: sounds,
            foregroundBusy: { [weak self] in
                guard let self else { return true }
                return self.dictation.phase != .idle
                    || self.transcriber.isTranscribing
                    || !self.hud.model.state.isAvailable
            })
        dictation.recordingBlockReason = { [weak self] in
            guard let self else { return nil }
            if case .suggesting = self.meetingCoordinator.state {
                self.meetingCoordinator.yieldSuggestionToForegroundOperation()
                return nil
            }
            guard self.meetingCoordinator.foregroundCaptureActive else { return nil }
            return self.meetingCoordinator.state.isRecording
                ? "Meeting recording is active — stop it before dictating"
                : "Meeting audio is starting or saving — wait a moment"
        }
        meetingCoordinator.onRecordingEnded = { [weak self] outcome in
            self?.meetingEndOutcome = outcome
        }
        meetingCoordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            self.meetingHUDDismiss?.cancel()
            self.meetingHUDDismiss = nil
            switch state {
            case .idle:
                let ownedHUD = self.meetingOwnedHUDState
                self.meetingOwnedHUDState = nil
                self.statusController.meetingRecordingTitle = nil
                self.statusController.meetingPreparingTitle = nil
                self.hud.model.recordingStart = nil
                if self.meetingHUDActive {
                    self.meetingHUDActive = false
                    let notice: (symbol: String, message: String, exit: HUDState.ExitStyle)
                    switch self.meetingEndOutcome {
                    case .saved:
                        notice = ("waveform.badge.checkmark", "Meeting saved · Creating notes", .success)
                    case .discarded:
                        notice = ("trash", "Meeting discarded", .cancel)
                    case .failed, .none:
                        notice = ("exclamationmark.triangle.fill", "Meeting could not be saved", .cancel)
                    }
                    self.meetingEndOutcome = nil
                    let toast = HUDState.notice(
                        symbol: notice.symbol, message: notice.message)
                    self.meetingOwnedHUDState = toast
                    self.hud.transition(to: toast)
                    let item = DispatchWorkItem { [weak self] in
                        // Hide only OUR toast. A dictation can start inside
                        // this 2s window; blindly hiding would blank a live
                        // recording capsule (review P1).
                        guard let self, self.hud.model.state == toast else { return }
                        self.hud.transition(to: .hidden(notice.exit))
                    }
                    self.meetingHUDDismiss = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
                } else if let ownedHUD, self.hud.model.state == ownedHUD {
                    self.hud.transition(to: .hidden(.cancel))
                }
            case .suggesting(let title, let sourceApp):
                self.meetingProcessingHUDActive = false
                self.statusController.meetingRecordingTitle = nil
                self.statusController.meetingPreparingTitle = "Meeting detected: \(title)"
                self.hud.model.recordingStart = nil
                let prompt = HUDState.meetingSuggestion(
                    title: title, source: sourceApp ?? "Call")
                self.meetingOwnedHUDState = prompt
                self.hud.transition(to: prompt)
            case .preparing(let title):
                self.meetingProcessingHUDActive = false
                self.statusController.meetingRecordingTitle = nil
                self.statusController.meetingPreparingTitle = title
                if title != "Waiting for confirmation…" {
                    let message: String
                    if title == "Call no longer detected" {
                        message = title
                    } else if title.hasSuffix("…") {
                        message = title
                    } else {
                        message = "Starting \(title)…"
                    }
                    let notice = HUDState.notice(
                        symbol: title == "Call no longer detected"
                            ? "video.slash.fill" : "hourglass",
                        message: message)
                    self.meetingOwnedHUDState = notice
                    self.hud.transition(to: notice)
                }
            case .recording(_, let title, let startedAt, let systemAudio, let endDetected):
                self.statusController.meetingPreparingTitle = nil
                self.statusController.meetingRecordingTitle = title
                self.meetingHUDActive = true
                self.hud.model.recordingStart = startedAt
                let meetingState: HUDState = endDetected
                    ? .meetingEnd(title: title)
                    : .meeting(title: title, systemAudio: systemAudio)
                self.meetingOwnedHUDState = meetingState
                self.hud.transition(to: meetingState)
            }
        }
        meetingProcessor.onStateChange = { [weak self] state in
            guard let self else { return }
            let ownsVisibleMeetingState = self.meetingOwnedHUDState == self.hud.model.state
            let canShow = MeetingProcessingHUDPolicy.shouldShow(
                dictationIsIdle: self.dictation.phase == .idle,
                meetingIsIdle: self.meetingCoordinator.state == .idle,
                hudAllowsMeetingProgress:
                    self.hud.model.state.isAvailable || ownsVisibleMeetingState)
            switch state {
            case .idle:
                self.statusController.meetingProcessingLabel = nil
                if self.meetingProcessingHUDActive {
                    self.meetingProcessingHUDActive = false
                    guard canShow else { return }
                    self.meetingHUDDismiss?.cancel()
                    let toast = HUDState.notice(
                        symbol: "checkmark.circle.fill", message: "Meeting notes ready")
                    self.meetingOwnedHUDState = toast
                    self.hud.transition(to: toast)
                    let item = DispatchWorkItem { [weak self] in
                        // Same guard as the meeting-saved toast: never hide a
                        // capsule that has since become a live session.
                        guard let self, self.hud.model.state == toast else { return }
                        self.hud.transition(to: .hidden(.success))
                    }
                    self.meetingHUDDismiss = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
                } else if !self.meetingFailureHUDQueue.isEmpty {
                    // A retained failure may have been denied while another
                    // meeting was processing. Processor idle is the final
                    // availability edge, so replay it without waiting for a
                    // new HUD availability callback that may never arrive.
                    self.showMeetingFailureIfPossible()
                }
            case .processing(let meetingID, let label, let fraction):
                // A Retry resolves only that meeting's retained failure. Work
                // for a different queued meeting must not swallow it.
                self.meetingFailureHUDQueue.remove(meetingID: meetingID)
                let progress = "\(label) \(Int((fraction * 100).rounded()))%"
                self.statusController.meetingProcessingLabel = progress
                guard canShow else { return }
                self.meetingProcessingHUDActive = true
                self.meetingHUDDismiss?.cancel()
                self.meetingHUDDismiss = nil
                let notice = HUDState.notice(
                    symbol: "waveform", message: progress)
                self.meetingOwnedHUDState = notice
                self.hud.transition(to: notice)
            case .failed(let meetingID, let message):
                self.statusController.meetingProcessingLabel =
                    "Meeting processing needs attention"
                self.meetingFailureHUDQueue.retain(
                    meetingID: meetingID,
                    message: MeetingFailurePresentation.hudMessage(message))
                self.showMeetingFailureIfPossible()
            }
        }
        meetingProcessor.onNotesReady = { [weak self] meetingID in
            self?.meetingFailureHUDQueue.remove(meetingID: meetingID)
            self?.showMeetingNotes(meetingID: meetingID)
        }

        let controlRouter = LocalControlRouter(
            history: history,
            accessEnabled: { AppConfig.shared.localAgentAccess },
            engineReady: { [weak supervisor] in supervisor?.isReady ?? false },
            typingWPM: { AppConfig.shared.typingWPM },
            restartBlockReason: { [weak self] in
                guard let self else { return "Velora is unavailable" }
                return self.restartBlockReason()
            },
            transcribeFile: { [weak self] arguments, completion in
                let requestID = UUID()
                DispatchQueue.main.async {
                    guard let self else {
                        completion(.failure(ControlFailure(
                            code: "app_unavailable", message: "Velora is shutting down")))
                        return
                    }
                    guard self.config.localAgentAccess else {
                        completion(.failure(.disabled))
                        return
                    }
                    guard let path = arguments["path"] as? String else {
                        completion(.failure(ControlFailure(
                            code: "invalid_file", message: "The audio path is invalid")))
                        return
                    }
                    self.transcriber.transcribeForAgent(
                        url: URL(fileURLWithPath: path),
                        mode: arguments["mode"] as? String,
                        requestID: requestID
                    ) { result in
                        switch result {
                        case .success(let value):
                            var payload: [String: Any] = [
                                "text": value.text,
                                "path": value.path,
                                "duration_ms": value.durationMs,
                                "stt_ms": value.sttMs,
                            ]
                            if let mode = value.mode { payload["mode"] = mode }
                            completion(.success(payload))
                        case .failure(let error):
                            let code: String
                            switch error {
                            case .busy: code = "busy"
                            case .engineUnavailable: code = "engine_unavailable"
                            case .invalidFile: code = "invalid_file"
                            case .cancelled: code = "cancelled"
                            case .failed: code = "transcription_failed"
                            }
                            completion(.failure(ControlFailure(
                                code: code, message: error.localizedDescription)))
                        }
                    }
                }
                return { [weak self] in
                    DispatchQueue.main.async {
                        self?.transcriber.cancelAgentRequest(requestID)
                    }
                }
            },
            listen: { [weak self] arguments, completion in
                let requestID = UUID()
                DispatchQueue.main.async {
                    guard let self else {
                        completion(.failure(ControlFailure(
                            code: "app_unavailable", message: "Velora is shutting down")))
                        return
                    }
                    guard self.config.localAgentAccess else {
                        completion(.failure(.disabled))
                        return
                    }
                    self.dictation.requestExternalDictation(
                        mode: arguments["mode"] as? String,
                        requestID: requestID
                    ) { result in
                        switch result {
                        case .success(let value):
                            var payload: [String: Any] = [
                                "text": value.text,
                                "duration_ms": value.durationMs,
                                "consent": "allow_once",
                            ]
                            if let mode = value.mode { payload["mode"] = mode }
                            completion(.success(payload))
                        case .failure(let error):
                            let code: String
                            switch error {
                            case .denied: code = "consent_denied"
                            case .busy: code = "busy"
                            case .unavailable: code = "recording_unavailable"
                            case .cancelled: code = "cancelled"
                            }
                            completion(.failure(ControlFailure(
                                code: code, message: error.localizedDescription)))
                        }
                    }
                }
                return { [weak self] in
                    DispatchQueue.main.async {
                        self?.dictation.cancelExternalRequest(requestID)
                    }
                }
            },
            action: { [weak self] arguments, completion in
                // Scoped like the sibling capabilities: without an identity, a
                // second client's disconnect would cancel the FIRST client's
                // (or the user's) running plan.
                let requestID = UUID()
                DispatchQueue.main.async {
                    guard let self else {
                        completion(.failure(ControlFailure(
                            code: "app_unavailable", message: "Velora is shutting down")))
                        return
                    }
                    guard self.config.localAgentAccess else {
                        completion(.failure(.disabled))
                        return
                    }
                    guard let text = arguments["text"] as? String else {
                        completion(.failure(ControlFailure(
                            code: "invalid_arguments", message: "action requires a command")))
                        return
                    }
                    self.dictation.performAction(
                        command: text,
                        execute: arguments["execute"] as? Bool ?? false,
                        allowSend: arguments["allow_send"] as? Bool ?? false,
                        requestID: requestID,
                        completion: completion)
                }
                return { [weak self] in
                    DispatchQueue.main.async {
                        self?.dictation.cancelAction(requestID: requestID)
                    }
                }
            },
            axProbe: { [weak self] _, completion in
                DispatchQueue.main.async {
                    guard let self, self.config.localAgentAccess else {
                        completion(.failure(.disabled))
                        return
                    }
                    let front = self.contextTracker.frontmost
                        ?? NSWorkspace.shared.frontmostApplication
                    var dump = ScreenContext.axDump(of: front)
                    dump["background"] = CuaDiagnostics.dump(
                        transport: CuaSocketTransport(), app: front)
                    completion(.success(dump))
                }
                return {}
            })
        let controlServer = LocalControlServer(router: controlRouter)
        if controlServer.start() { self.controlServer = controlServer }

        localAgentAccessObserver = LocalAgentAccessRevocationObserver { [weak self] in
            self?.dictation.revokeExternalAccess()
            self?.transcriber.revokeAgentAccess()
        }

        supervisor.delegate = self
        dictation.delegate = self
        hotkeyMonitor.delegate = dictation
        statusController.delegate = self

        // The HUD pill is a control surface: click toggles dictation,
        // right-click offers recent transcripts and placement.
        hud.onTap = { [weak self] in self?.dictation.toggleFromMenu() }
        hud.model.onMeetingStop = { [weak self] in self?.meetingCoordinator.stopRecording() }
        hud.model.onMeetingSuggestionAccept = { [weak self] in
            self?.meetingCoordinator.acceptSuggestion()
        }
        hud.model.onMeetingSuggestionDismiss = { [weak self] in
            self?.meetingCoordinator.declineSuggestion()
        }
        hud.model.onMeetingEndConfirm = { [weak self] in
            self?.meetingCoordinator.confirmMeetingEnded()
        }
        hud.model.onMeetingEndKeep = { [weak self] in
            self?.meetingCoordinator.keepMeetingRecording()
        }
        hud.model.onMeetingEndDiscard = { [weak self] in
            self?.meetingCoordinator.cancelRecording()
        }
        hud.menuHooks = HUDPanel.MenuHooks(
            isRecording: { [weak self] in self?.dictation.isRecording ?? false },
            isMeetingRecording: { [weak self] in
                self?.meetingCoordinator.state.isRecording ?? false
            },
            // Over-fetch: the menu drops rows with empty finals, and a run of
            // failed dictations must not shrink the list below five usable ones.
            recents: { [weak self] in self?.history.recent(limit: 10) ?? [] },
            toggleDictation: { [weak self] in self?.dictation.toggleFromMenu() },
            stopMeeting: { [weak self] in self?.meetingCoordinator.stopRecording() },
            openHistory: { [weak self] in self?.showSettings(selecting: .history) },
            openSettings: { [weak self] in self?.showSettings() })
        hudPrefsObserver = NotificationCenter.default.addObserver(
            forName: .veloraHUDPrefsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.hud.applyPreferences() }
        hud.applyPreferences()

        veloraLog(String(
            format: "Velora: launch — permissions mic=%@ inputMonitoring=%@ accessibility=%@; hotkey=%@ mode=%@",
            Permissions.microphoneGranted ? "yes" : "no",
            Permissions.inputMonitoringGranted ? "yes" : "no",
            Permissions.accessibilityGranted ? "yes" : "no",
            config.hotkey.displayLabel,
            config.hotkeyMode == .toggle ? "toggle" : "hold"))
        // The secondary bindings decide whether Voice Edit and Action Mode fire
        // at all; without them in the log, "my shortcut does nothing" is
        // unanswerable from a bug report.
        veloraLog("Velora: secondary hotkeys — "
            + SecondaryHotkeyRole.allCases.map { role in
                "\(role.label)=\(hotkeyMonitor.secondaryHotkeys[role]?.displayLabel ?? "off")"
            }.joined(separator: " "))

        // A validated cached release remains actionable across relaunches even
        // while the daily network check is still within its 20-hour gate.
        statusController.updateAvailable = UpdateChecker.shared.available
        statusController.install()
        refreshDegradedState()
        contextTracker.start()
        hotkeyMonitor.start()

        UpdateInstaller.shared.relaunchBlockReason = { [weak self] in
            self?.restartBlockReason() ?? "Velora is unavailable"
        }

        UpdateChecker.shared.onUpdate = { [weak self] update, origin in
            guard let self else { return }
            self.statusController.updateAvailable = update
            let automaticAllowed = UpdatePromptPolicy.allowsAutomaticAction(
                version: update.version,
                skippedVersion: self.config.skippedUpdateVersion,
                deferredVersion: self.config.deferredUpdateVersion,
                deferredUntil: self.config.deferredUpdateUntil)
            // Opt-in autoupdate: fetch + verify + stage silently; the swap
            // happens on the next quit or via "Restart to Update". begin()
            // no-ops while busy or when this version is already staged.
            if self.config.autoInstallUpdates, automaticAllowed,
               UpdateInstaller.canInstallInPlace {
                UpdateInstaller.shared.begin(update)
            }
            // A daily check surfaces the full release notes without taking
            // keyboard focus from the app the user is working in. Manual
            // checks always reopen the release window even when this exact
            // version's automatic path is skipped or deferred.
            if origin == .automatic {
                UpdateWindowController.shared.showAutomatically(update)
            }
        }
        UpdateChecker.shared.startPeriodicChecks()
        UpdateInstaller.shared.resumeOrCleanOnLaunch()
        veloraLog("Velora: hotkey monitor started (usingEventTap=\(hotkeyMonitor.usingEventTap))")
        // Repair unreadable interrupted rows even if engine startup later
        // degrades. Valid rows are queued now and begin once `.ready` arrives.
        meetingProcessor.resumeRecoverable()
        supervisor.start()
        dictionarySync.start()
        meetingCoordinator.start()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .veloraHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeyMonitor.hotkey = self.config.hotkey
            self.hotkeyMonitor.secondaryHotkeys = self.config.activeSecondaryHotkeys
        }

        // First-run setup progress (venv bootstrap, model downloads) →
        // menubar line + tooltip, so a fresh install is never a silent wait.
        loadingObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineLoading, object: nil, queue: .main
        ) { [weak self] note in
            self?.statusController.setupStatus = note.userInfo?["status"] as? String
        }

        // Accessibility just flipped to granted (onboarding live-poll): an
        // event tap created before the grant is dead — reinstall immediately
        // so the hotkey works without an app relaunch.
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: .veloraAccessibilityGranted, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeyMonitor.restart()
            self.refreshDegradedState()
        }

        // Onboarding must come back for a user who skipped it or whose
        // permissions broke (e.g. a TCC re-grant after re-signing), not just
        // on first launch.
        if !config.onboardingComplete {
            showOnboarding()
        } else if Permissions.anyMissing {
            veloraLog("Velora: permissions missing at launch — reopening setup assistant")
            showOnboarding(startingAt: firstMissingPermissionStep)
        }
    }

    private func restartBlockReason() -> String? {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { restartBlockReason() }
        }
        return UpdateRelaunchSafety.blockReason(
            dictationBusy: dictation.hasUserOperationInFlight,
            fileTranscriptionBusy: transcriber.isTranscribing,
            meetingCaptureBusy: meetingCoordinator.foregroundCaptureActive
                || meetingCoordinator.terminationWorkInFlight)
    }

    private func showMeetingFailureIfPossible() {
        guard let failure = meetingFailureHUDQueue.first,
              dictation != nil, meetingCoordinator != nil,
              meetingProcessor != nil else { return }
        let processorAllowsFailure: Bool
        switch meetingProcessor.state {
        case .idle, .failed: processorAllowsFailure = true
        case .processing: processorAllowsFailure = false
        }
        guard MeetingFailureHUDReplayPolicy.shouldShow(
            dictationIsIdle: dictation.phase == .idle,
            meetingIsIdle: meetingCoordinator.state == .idle,
            processorAllowsFailure: processorAllowsFailure,
            hudIsAvailable: hud.model.state.isAvailable,
            ownsVisibleHUD: meetingOwnedHUDState == hud.model.state)
        else { return }
        meetingProcessingHUDActive = false
        meetingHUDDismiss?.cancel()
        meetingHUDDismiss = nil
        meetingOwnedHUDState = failure
        if hud.model.state != failure { hud.transition(to: failure) }
    }

    private func clearMeetingFailure(meetingID: String) {
        let state = meetingFailureHUDQueue.state(meetingID: meetingID)
        meetingFailureHUDQueue.remove(meetingID: meetingID)
        guard let state, hud.model.state == state else { return }
        meetingOwnedHUDState = nil
        hud.transition(to: .hidden(.cancel))
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let accepted = openFileTranscriptionQueue.enqueue(
            filenames.map { URL(fileURLWithPath: $0) })
        if accepted > 0 {
            veloraLog("Velora: queued \(accepted) Finder media file(s) for transcription")
            drainOpenFileTranscriptions()
        }
        sender.reply(toOpenOrPrint: accepted > 0 ? .success : .failure)
    }

    private func drainOpenFileTranscriptions() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !terminationPending, !openFileRetryPending, let transcriber else { return }
        while let url = openFileTranscriptionQueue.dequeueIfReady(
            engineReady: supervisor.isReady,
            transcriberBusy: transcriber.isTranscribing
        ) {
            transcriber.transcribeQueuedFromFinder(url: url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        veloraLog("Velora: termination requested")
        // Watchdog: if any teardown callback below is parked and never fires,
        // the pending reply would leave the app unquittable forever — and the
        // `terminationPending` latch makes every LATER quit a silent no-op
        // (field report: menubar Quit dead + update stuck on "Installing…").
        // A finalizing meeting gets one extension. The base is eight seconds;
        // queued History writes scale it by SQLite's bounded busy wait so the
        // watchdog cannot outrun the drain it protects.
        let watchdogDelay = max(
            Self.terminationWatchdogBase,
            dictation?.terminationWatchdogDelay ?? 0)
        scheduleTerminationWatchdog(
            after: watchdogDelay, allowMeetingExtension: true)
        // A debounced Settings edit (notes prompt) must not die with the
        // process; windowWillClose is not guaranteed during terminate.
        settingsController?.flushPendingEdits()
        // Stop accepting new long-running work, then wait for meeting audio to
        // finalize and active dictation audio to seal before AppKit tears down
        // the engine and process.
        controlServer?.stop()
        transcriber?.cancelForTermination()
        let pending = DispatchGroup()
        if let dictation {
            pending.enter()
            dictation.preserveForTermination { pending.leave() }
        }
        if let meetingCoordinator {
            pending.enter()
            meetingCoordinator.finishForTermination { pending.leave() }
        }
        pending.notify(queue: .main) { [weak self] in
            self?.replyTerminationOnce()
        }
        return .terminateLater
    }

    private func scheduleTerminationWatchdog(
        after seconds: TimeInterval, allowMeetingExtension: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.terminationReplied else { return }
            if allowMeetingExtension,
               self.meetingCoordinator?.terminationWorkInFlight == true {
                veloraLog("Velora: termination waiting on a meeting finalize — extending watchdog to 60s")
                self.scheduleTerminationWatchdog(
                    after: Self.meetingWatchdogExtension,
                    allowMeetingExtension: false)
                return
            }
            veloraLog("Velora: termination watchdog fired — forcing quit")
            self.replyTerminationOnce()
        }
    }

    /// Answers the pending terminateLater exactly once — the normal completion
    /// and the watchdog can both race to deliver it.
    private func replyTerminationOnce() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !terminationReplied else { return }
        terminationReplied = true
        veloraLog("Velora: termination proceeding")
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        UpdateInstaller.shared.installOnQuitIfReady()
        // A driver daemon Velora started is a same-user automation surface;
        // it should not outlive the app that needed it.
        CuaDriverDaemon.stopIfVeloraStarted()
        dictation?.cancelForTermination()
        transcriber?.cancelForTermination()
        meetingCoordinator?.stop()
        controlServer?.stop()
        dictionarySync?.stop()
        hotkeyMonitor.stop()
        contextTracker.stop()
        supervisor.stop()
        if let hotkeyObserver {
            NotificationCenter.default.removeObserver(hotkeyObserver)
        }
        if let accessibilityObserver {
            NotificationCenter.default.removeObserver(accessibilityObserver)
        }
        if let loadingObserver {
            NotificationCenter.default.removeObserver(loadingObserver)
        }
        if let hudPrefsObserver {
            NotificationCenter.default.removeObserver(hudPrefsObserver)
        }
        localAgentAccessObserver?.stop()
    }

    // MARK: - Windows

    private func showOnboarding(startingAt step: OnboardingModel.Step? = nil) {
        if onboardingController == nil {
            let controller = OnboardingWindowController()
            controller.onComplete = { [weak self] in
                guard let self else { return }
                // Permissions may have just been granted; reinstall listeners
                // so the event tap picks up the new grant.
                self.hotkeyMonitor.restart()
                self.refreshDegradedState()
                self.meetingCoordinator.start()
            }
            onboardingController = controller
        }
        onboardingController?.show(startingAt: step)
    }

    private func showSettings(selecting tab: SettingsTab? = nil) {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                supervisor: supervisor,
                history: history,
                dictionary: dictionary,
                dictionarySync: dictionarySync,
                meetings: meetings,
                meetingCoordinator: meetingCoordinator,
                meetingProcessor: meetingProcessor)
        }
        settingsController?.show(selecting: tab)
    }

    private func showMeetingNotes(meetingID: String) {
        if meetingNotesController == nil {
            meetingNotesController = MeetingNotesWindowController(store: meetings)
        }
        meetingNotesController?.show(meetingID: meetingID)
        veloraLog("Velora: opened focused meeting notes id=\(meetingID)")
    }

    // MARK: - Main menu actions

    @objc func menuOpenSettings() {
        showSettings()
    }

    @objc func menuOpenAbout() {
        showSettings(selecting: .about)
    }

    @objc func menuToggleSidebar() {
        settingsController?.toggleSidebar()
    }

    @objc func menuOpenWebsite() {
        open(VeloraLinks.websiteURL)
    }

    @objc func menuOpenGitHub() {
        open(VeloraLinks.repositoryURL)
    }

    @objc func menuStarOnGitHub() {
        open(VeloraLinks.starURL)
    }

    @objc func menuReportIssue() {
        open(VeloraLinks.issuesURL)
    }

    @objc func menuEmailSupport() {
        open(VeloraLinks.supportEmailURL)
    }

    private func open(_ url: URL?) {
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Retitles Hide/Show Sidebar to the state it would produce and disables
    /// it while no Settings window is open (the only window with a sidebar).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(menuToggleSidebar) else { return true }
        menuItem.title = AppConfig.shared.settingsSidebarCollapsed
            ? "Show Sidebar" : "Hide Sidebar"
        return settingsController?.window?.isVisible ?? false
    }

    /// The onboarding step to reopen at: the first missing permission, or
    /// welcome when everything is granted.
    private var firstMissingPermissionStep: OnboardingModel.Step {
        if !Permissions.microphoneGranted { return .microphone }
        if !Permissions.inputMonitoringGranted { return .inputMonitoring }
        if !Permissions.accessibilityGranted { return .accessibility }
        return .welcome
    }

    // MARK: - Degraded state (menubar error icon + Check Permissions…)

    private func refreshDegradedState() {
        let permissionsMissing = Permissions.anyMissing
        statusController.permissionsMissing = permissionsMissing
        var reason: String?
        if case .degraded(let message) = supervisor.state {
            reason = message
        }
        statusController.degradedReason = reason
    }
}

// MARK: - EngineSupervisorDelegate

extension AppDelegate: EngineSupervisorDelegate {
    func engineSupervisor(_ supervisor: EngineSupervisor, didChangeState state: EngineSupervisor.State) {
        if state == .ready {
            // Engine startup can migrate legacy app assignments. Refresh after
            // that work so the listening HUD and final engine mode stay equal.
            ModeApplicationIndex.shared.reload()
        }
        dictation.handleEngineStateChange(state)
        transcriber.handleEngineStateChange(state)
        meetingProcessor.handleEngineStateChange(state)
        refreshDegradedState()
        drainOpenFileTranscriptions()
    }

    func engineSupervisor(_ supervisor: EngineSupervisor, didReceive event: EngineEvent) {
        if case .vocabularyPromoted = event {
            dictionary.captureAutoVocabulary()
        }
        dictation.handleEngineEvent(event)
        transcriber.handle(event)
        meetingProcessor.handle(event)
    }
}

// MARK: - DictationControllerDelegate

extension AppDelegate: DictationControllerDelegate {
    func dictationController(_ controller: DictationController, didChangePhase phase: DictationController.Phase) {
        switch phase {
        case .idle:
            statusController.setIconState(.idle)
        case .starting, .recording:
            statusController.setIconState(.recording)
        case .transcribing, .editing:
            statusController.setIconState(.transcribing)
        }
    }
}

// MARK: - StatusItemControllerDelegate

extension AppDelegate: StatusItemControllerDelegate {
    func statusItemToggleDictation() {
        dictation.toggleFromMenu()
    }

    func statusItemPasteLastRaw() {
        dictation.pasteLastRawOriginal()
    }

    func statusItemReformatLast(mode: String) {
        dictation.reformatLast(mode: mode)
    }

    func statusItemTranscribeFile() {
        transcriber.pickAndTranscribe()
    }

    func statusItemCancelTranscription() {
        transcriber.cancel()
    }

    func statusItemStartMeeting() { meetingCoordinator.startManual() }

    func statusItemStopMeeting() { meetingCoordinator.stopRecording() }

    func statusItemDiscardMeeting() { meetingCoordinator.cancelRecording() }

    func statusItemOpenSettings() {
        showSettings()
    }

    func statusItemOpenHistory() {
        showSettings(selecting: .history)
    }

    func statusItemOpenMeetings() { showSettings(selecting: .meetings) }

    func statusItemOpenSetupAssistant() {
        showOnboarding(startingAt: firstMissingPermissionStep)
    }

    func statusItemCheckForUpdates() {
        UpdateChecker.shared.check(origin: .manual) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .upToDate:
                self.statusController.updateAvailable = nil
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Velora is up to date"
                alert.informativeText =
                    "You’re using Velora \(VeloraAppInfo.shortVersion), the latest version."
                alert.addButton(withTitle: "OK")
                VisibleAlert.present(alert) { _ in }
            case .updateAvailable(let update):
                self.statusController.updateAvailable = update
            case .failed(let reason):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t Check for Updates"
                alert.informativeText = reason
                alert.addButton(withTitle: "OK")
                VisibleAlert.present(alert) { _ in }
            }
            if outcome.shouldOpenUpdateWindow,
               case .updateAvailable(let update) = outcome {
                UpdateWindowController.shared.show(update)
            }
        }
    }

    func statusItemCheckPermissions() {
        showOnboarding(startingAt: firstMissingPermissionStep)
    }
}
