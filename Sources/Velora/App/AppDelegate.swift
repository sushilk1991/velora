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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. LSUIElement covers the bundled app; the programmatic
        // call is the reliable path for bare `swift build` binaries.
        NSApp.setActivationPolicy(.accessory)
        SettingsModel.applyAppearance(config.appearance)

        config.ensureVeloraDirectory()
        config.writeEngineConfigIfMissing()

        history = HistoryStore()
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

        statusController.install()
        contextTracker.start()
        hotkeyMonitor.start()
        supervisor.start()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .veloraHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeyMonitor.hotkey = self.config.hotkey
        }

        if !config.onboardingComplete {
            showOnboarding()
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

    private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(supervisor: supervisor)
        }
        settingsController?.show()
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
        case .recording, .awaitingSecondTap:
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

    func statusItemCheckPermissions() {
        let step: OnboardingModel.Step = !Permissions.microphoneGranted ? .microphone : .accessibility
        showOnboarding(startingAt: step)
    }
}
