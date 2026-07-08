import AppKit
import Foundation

/// Composition root: builds every module, wires delegates, and owns app
/// lifecycle (engine supervision, onboarding on first launch, teardown).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = AppConfig.shared
    private let supervisor = EngineSupervisor()
    private let contextTracker = AppContextTracker()
    private let hotkeyMonitor = HotkeyMonitor()
    private let hud = HUDPanel()
    private let sounds = SoundPlayer()

    private var history: HistoryStore!
    private var dictation: DictationController!
    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController?
    private var onboardingController: OnboardingWindowController?
    private var hotkeyObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. LSUIElement covers the bundled app; the programmatic
        // call is the reliable path for bare `swift build` binaries.
        NSApp.setActivationPolicy(.accessory)
        SettingsModel.applyAppearance(config.appearance)

        config.ensureVeloraDirectory()
        config.writeEngineConfigIfMissing()

        history = HistoryStore()
        // Transcript text is tiny and kept indefinitely; only the audio archive
        // expires (the engine prunes clips). Play just disables when a row's
        // clip has aged out. `pruneOlderThan` stays available for a future
        // user-configurable text-retention setting.
        dictation = DictationController(
            supervisor: supervisor,
            contextTracker: contextTracker,
            hud: hud,
            history: history,
            sounds: sounds)
        statusController = StatusItemController(history: history)

        supervisor.delegate = self
        dictation.delegate = self
        hotkeyMonitor.delegate = dictation
        statusController.delegate = self

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
        veloraLog("Velora: hotkey monitor started (usingEventTap=\(hotkeyMonitor.usingEventTap))")
        supervisor.start()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .veloraHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeyMonitor.hotkey = self.config.hotkey
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

    func applicationWillTerminate(_ notification: Notification) {
        dictation?.cancel()
        hotkeyMonitor.stop()
        contextTracker.stop()
        supervisor.stop()
        if let hotkeyObserver {
            NotificationCenter.default.removeObserver(hotkeyObserver)
        }
        if let accessibilityObserver {
            NotificationCenter.default.removeObserver(accessibilityObserver)
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
            }
            onboardingController = controller
        }
        onboardingController?.show(startingAt: step)
    }

    private func showSettings(selecting tab: SettingsTab? = nil) {
        if settingsController == nil {
            settingsController = SettingsWindowController(supervisor: supervisor, history: history)
        }
        settingsController?.show(selecting: tab)
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
        refreshDegradedState()
    }

    func engineSupervisor(_ supervisor: EngineSupervisor, didReceive event: EngineEvent) {
        dictation.handleEngineEvent(event)
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

    func statusItemOpenSettings() {
        showSettings()
    }

    func statusItemOpenHistory() {
        showSettings(selecting: .history)
    }

    func statusItemOpenSetupAssistant() {
        showOnboarding(startingAt: firstMissingPermissionStep)
    }

    func statusItemCheckPermissions() {
        showOnboarding(startingAt: firstMissingPermissionStep)
    }
}
