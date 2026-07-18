import AppKit
import Foundation

/// Composition root: builds every module, wires delegates, and owns app
/// lifecycle (engine supervision, onboarding on first launch, teardown).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
    private var onboardingController: OnboardingWindowController?
    private var hotkeyObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var loadingObserver: NSObjectProtocol?
    private var hudPrefsObserver: NSObjectProtocol?
    private var terminationPending = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. LSUIElement covers the bundled app; the programmatic
        // call is the reliable path for bare `swift build` binaries.
        NSApp.setActivationPolicy(.accessory)
        // Ready before any window opens: the moment the app becomes regular
        // (AppActivation), the menu bar must show real menus.
        MainMenu.install(target: self)
        SettingsModel.applyAppearance(config.appearance)

        config.ensureVeloraDirectory()
        config.writeEngineConfigIfMissing()
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
        }
        meetingProcessor = MeetingProcessor(supervisor: supervisor, store: meetings)
        meetingCoordinator = MeetingCoordinator(
            store: meetings, processor: meetingProcessor, sounds: sounds,
            foregroundBusy: { [weak self] in
                guard let self else { return true }
                return self.dictation.phase != .idle || self.transcriber.isTranscribing
            })
        dictation.recordingBlockReason = { [weak self] in
            guard let self, self.meetingCoordinator.state.isRecording else { return nil }
            return "Meeting recording is active — stop it before dictating"
        }
        meetingCoordinator.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.statusController.meetingRecordingTitle = nil
                self.statusController.meetingPreparingTitle = nil
            case .preparing(let title):
                self.statusController.meetingRecordingTitle = nil
                self.statusController.meetingPreparingTitle = title
            case .recording(_, let title, _, _):
                self.statusController.meetingPreparingTitle = nil
                self.statusController.meetingRecordingTitle = title
            }
        }
        meetingProcessor.onStateChange = { [weak self] state in
            switch state {
            case .idle: self?.statusController.meetingProcessingLabel = nil
            case .processing(_, let label, let fraction):
                self?.statusController.meetingProcessingLabel =
                    "\(label) \(Int((fraction * 100).rounded()))%"
            case .failed:
                self?.statusController.meetingProcessingLabel =
                    "Meeting processing needs attention"
            }
        }

        let controlRouter = LocalControlRouter(
            history: history,
            accessEnabled: { AppConfig.shared.localAgentAccess },
            engineReady: { [weak supervisor] in supervisor?.isReady ?? false },
            typingWPM: { AppConfig.shared.typingWPM },
            transcribeFile: { [weak self] arguments, completion in
                let requestID = UUID()
                DispatchQueue.main.async {
                    guard let self else {
                        completion(.failure(ControlFailure(
                            code: "app_unavailable", message: "Velora is shutting down")))
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
            })
        let controlServer = LocalControlServer(router: controlRouter)
        if controlServer.start() { self.controlServer = controlServer }

        supervisor.delegate = self
        dictation.delegate = self
        hotkeyMonitor.delegate = dictation
        statusController.delegate = self

        // The HUD pill is a control surface: click toggles dictation,
        // right-click offers recent transcripts and placement.
        hud.onTap = { [weak self] in self?.dictation.toggleFromMenu() }
        hud.menuHooks = HUDPanel.MenuHooks(
            isRecording: { [weak self] in self?.dictation.isRecording ?? false },
            // Over-fetch: the menu drops rows with empty finals, and a run of
            // failed dictations must not shrink the list below five usable ones.
            recents: { [weak self] in self?.history.recent(limit: 10) ?? [] },
            toggleDictation: { [weak self] in self?.dictation.toggleFromMenu() },
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

        statusController.install()
        contextTracker.start()
        hotkeyMonitor.start()

        UpdateChecker.shared.onUpdate = { [weak self] update in
            guard let self else { return }
            self.statusController.updateAvailable = update
            // Opt-in autoupdate: fetch + verify + stage silently; the swap
            // happens on the next quit or via "Restart to Update". begin()
            // no-ops while busy or when this version is already staged.
            if self.config.autoInstallUpdates, UpdateInstaller.canInstallInPlace {
                UpdateInstaller.shared.begin(update)
            }
        }
        UpdateChecker.shared.startPeriodicChecks()
        UpdateInstaller.shared.resumeOrCleanOnLaunch()
        veloraLog("Velora: hotkey monitor started (usingEventTap=\(hotkeyMonitor.usingEventTap))")
        supervisor.start()
        dictionarySync.start()
        meetingCoordinator.start()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .veloraHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeyMonitor.hotkey = self.config.hotkey
            self.hotkeyMonitor.editHotkey = self.config.activeEditHotkey
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        veloraLog("Velora: termination requested")
        // Watchdog: if any teardown callback below is parked and never fires,
        // the pending reply would leave the app unquittable forever — and the
        // `terminationPending` latch makes every LATER quit a silent no-op
        // (field report: menubar Quit dead + update stuck on "Installing…").
        // A genuinely-finalizing meeting gets ONE extension to 60s (cutting a
        // mid-flight .m4a finalize loses the system track — review catch);
        // anything else wedged is forced at 8s.
        scheduleTerminationWatchdog(after: 8, allowMeetingExtension: true)
        // Stop accepting new long-running work, then wait for meeting audio to
        // finalize before allowing AppKit to tear down the engine and process.
        controlServer?.stop()
        dictation?.cancelForTermination()
        transcriber?.cancelForTermination()
        guard let meetingCoordinator else {
            DispatchQueue.main.async { self.replyTerminationOnce() }
            return .terminateLater
        }
        meetingCoordinator.finishForTermination { [weak self] in
            DispatchQueue.main.async { self?.replyTerminationOnce() }
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
                self.scheduleTerminationWatchdog(after: 52, allowMeetingExtension: false)
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

    @objc func menuOpenGitHub() {
        if let url = URL(string: "https://github.com/\(UpdateChecker.repoSlug)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func menuReportIssue() {
        if let url = URL(string: "https://github.com/\(UpdateChecker.repoSlug)/issues") {
            NSWorkspace.shared.open(url)
        }
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
        var reason: String?
        if case .degraded(let message) = supervisor.state {
            reason = message
        } else if Permissions.anyMissing {
            reason = "Permissions missing"
        }
        statusController.degradedReason = reason
    }
}

// MARK: - EngineSupervisorDelegate

extension AppDelegate: EngineSupervisorDelegate {
    func engineSupervisor(_ supervisor: EngineSupervisor, didChangeState state: EngineSupervisor.State) {
        dictation.handleEngineStateChange(state)
        transcriber.handleEngineStateChange(state)
        meetingProcessor.handleEngineStateChange(state)
        refreshDegradedState()
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
        case .recording:
            statusController.setIconState(.recording)
        case .transcribing:
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

    func statusItemCheckPermissions() {
        showOnboarding(startingAt: firstMissingPermissionStep)
    }
}
