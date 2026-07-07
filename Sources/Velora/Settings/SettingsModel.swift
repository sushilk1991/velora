import AppKit
import Foundation
import ServiceManagement

/// Notifications for settings changes that other components react to live.
extension Notification.Name {
    /// Hotkey choice changed — the hotkey monitor re-reads its config.
    static let veloraHotkeyChanged = Notification.Name("VeloraHotkeyChanged")
    /// Accessibility flipped from denied to granted (onboarding live-poll) —
    /// the hotkey monitor reinstalls so a pre-grant dead event tap comes back
    /// without an app relaunch.
    static let veloraAccessibilityGranted = Notification.Name("VeloraAccessibilityGranted")
}

/// A model the running engine advertises via the `status` reply. Drives the
/// dynamic STT picker (new engine models appear without an app update) and the
/// History reprocess menu.
struct EngineModel: Identifiable, Equatable {
    let id: String
    /// "stt" | "cleanup"
    let kind: String
    let backend: String
    let size: String
    let description: String

    /// Short human label — the description if present, else the repo basename.
    var displayName: String {
        if !description.isEmpty { return description }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Decodes the array under `status.models`; tolerates missing/typed fields.
    static func parse(_ raw: Any?) -> [EngineModel] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            let size: String
            if let s = dict["size"] as? String { size = s }
            else if let n = dict["size"] as? NSNumber { size = "\(n) GB" }
            else { size = "" }
            return EngineModel(
                id: id,
                kind: dict["kind"] as? String ?? "stt",
                backend: dict["backend"] as? String ?? "",
                size: size,
                description: dict["description"] as? String ?? "")
        }
    }
}

/// Observable bridge between the SwiftUI settings/onboarding UI and
/// `AppConfig` + the engine. Writing a property persists it and, where
/// relevant, pushes `reload_config` / `set_model` to the engine.
final class SettingsModel: ObservableObject {
    private let config = AppConfig.shared
    private weak var supervisor: EngineSupervisor?
    private var statusObserver: NSObjectProtocol?

    /// Models advertised by the running engine (from the `status` reply). Empty
    /// until the first reply arrives; the UI falls back to the static catalog.
    @Published var engineModels: [EngineModel] = []
    /// Retention window for archived clips, reported by the engine (days).
    @Published var audioRetentionDays: Double = 180

    /// STT models the engine offers, in advertised order.
    var sttEngineModels: [EngineModel] { engineModels.filter { $0.kind == "stt" } }

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
        romanizeOutput = config.romanizeOutput
        sttModel = config.sttModel
        saveAudio = config.saveAudio

        statusObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineStatus, object: nil, queue: .main
        ) { [weak self] note in
            self?.applyStatus(note.userInfo?["payload"] as? [String: Any])
        }
        requestStatus()
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    /// Asks the engine for its current status (models, retention, …). Cheap;
    /// safe to call whenever a settings surface appears.
    func requestStatus() {
        supervisor?.send(["cmd": "status"])
    }

    private func applyStatus(_ payload: [String: Any]?) {
        guard let payload else { return }
        let models = EngineModel.parse(payload["models"])
        if !models.isEmpty { engineModels = models }
        if let days = payload["audio_retention_days"] as? NSNumber {
            audioRetentionDays = days.doubleValue
        }
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

    @Published var romanizeOutput: Bool {
        didSet {
            guard romanizeOutput != oldValue else { return }
            config.romanizeOutput = romanizeOutput
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

    @Published var saveAudio: Bool {
        didSet {
            guard saveAudio != oldValue else { return }
            config.saveAudio = saveAudio
            supervisor?.send(["cmd": "reload_config"])
        }
    }

    // MARK: - Shortcuts

    @Published var hotkey: Hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            config.hotkey = hotkey
            NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        }
    }
}
