import AppKit
import Foundation
import ServiceManagement

/// Notifications for settings changes that other components react to live.
extension Notification.Name {
    /// Hotkey choice changed — the hotkey monitor re-reads its config.
    static let veloraHotkeyChanged = Notification.Name("VeloraHotkeyChanged")
}

/// Observable bridge between the SwiftUI settings/onboarding UI and
/// `AppConfig` + the engine. Writing a property persists it and, where
/// relevant, pushes `reload_config` / `set_model` to the engine.
final class SettingsModel: ObservableObject {
    private let config = AppConfig.shared
    private weak var supervisor: EngineSupervisor?

    init(supervisor: EngineSupervisor?) {
        self.supervisor = supervisor
        launchAtLogin = Self.launchAtLoginEnabled
        hotkey = config.hotkey
        hotkeyMode = config.hotkeyMode
        soundsEnabled = config.soundsEnabled
        soundVolume = config.soundVolume
        hudPosition = config.hudPosition
        appearance = config.appearance
        language = config.language
        autoPunctuation = config.autoPunctuation
        sttModel = config.sttModel
    }

    // MARK: - General

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Velora: launch-at-login toggle failed: \(error)")
                // Revert silently (fails for non-bundled dev binaries).
                launchAtLogin = oldValue
            }
        }
    }

    private static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @Published var hudPosition: HUDPosition {
        didSet { config.hudPosition = hudPosition }
    }

    @Published var appearance: String {
        didSet {
            config.appearance = appearance
            Self.applyAppearance(appearance)
        }
    }

    static func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Dictation

    @Published var hotkeyMode: HotkeyMode {
        didSet { config.hotkeyMode = hotkeyMode }
    }

    @Published var language: String {
        didSet {
            config.language = language
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var autoPunctuation: Bool {
        didSet {
            config.autoPunctuation = autoPunctuation
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    @Published var soundsEnabled: Bool {
        didSet { config.soundsEnabled = soundsEnabled }
    }

    @Published var soundVolume: Double {
        didSet { config.soundVolume = soundVolume }
    }

    // MARK: - Model

    @Published var sttModel: String {
        didSet {
            guard sttModel != oldValue else { return }
            config.sttModel = sttModel
            supervisor?.send(["cmd": "set_model", "model": sttModel])
        }
    }

    // MARK: - Shortcuts

    @Published var hotkey: HotkeyChoice {
        didSet {
            guard hotkey != oldValue else { return }
            config.hotkey = hotkey
            NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        }
    }
}
