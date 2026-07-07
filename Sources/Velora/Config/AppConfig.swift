import Foundation

/// The dictation hotkey. A full key-recorder UI is P1; P0 offers a curated
/// list of keys that work well as push-to-talk triggers (bare modifiers and
/// F-keys, detected via CGEventTap / NSEvent global monitors).
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption
    case fn
    case f13, f14, f15, f16, f17, f18, f19

    var id: String { rawValue }

    /// Human-readable name shown in settings and onboarding.
    var displayName: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .fn: return "Fn / Globe"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        }
    }

    /// Short keycap label for the onboarding keycap view.
    var keycapLabel: String {
        switch self {
        case .rightOption: return "⌥ right"
        case .fn: return "fn"
        default: return displayName
        }
    }

    /// Virtual key code (kVK_*) for key-based hotkeys; modifier hotkeys are
    /// matched on `flagsChanged` instead.
    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61  // kVK_RightOption
        case .fn: return 63           // kVK_Function
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .f16: return 106
        case .f17: return 64
        case .f18: return 79
        case .f19: return 80
        }
    }

    /// Whether the hotkey arrives as a `flagsChanged` event (bare modifier)
    /// rather than keyDown/keyUp.
    var isModifier: Bool {
        switch self {
        case .rightOption, .fn: return true
        default: return false
        }
    }
}

/// How the hotkey drives recording.
enum HotkeyMode: String, CaseIterable, Identifiable {
    /// Hold to talk; release to transcribe. Double-tap locks recording on.
    case hold
    /// Each press toggles recording on/off.
    case toggle

    var id: String { rawValue }
    var displayName: String { self == .hold ? "Hold to talk" : "Press to toggle" }
}

/// Where the HUD capsule sits on screen.
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter, topCenter
    var id: String { rawValue }
    var displayName: String { self == .bottomCenter ? "Bottom center" : "Top center" }
}

/// A speech-to-text model the engine can run. The engine owns downloads;
/// the app only selects the active model.
struct STTModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let size: String
    let speed: String
    let languages: String

    static let all: [STTModel] = [
        STTModel(
            id: "mlx-community/parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B",
            size: "~0.6 GB", speed: "Fastest (streaming)", languages: "English"
        ),
        STTModel(
            id: "mlx-community/whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            size: "~1.6 GB", speed: "Fast", languages: "Multilingual"
        ),
    ]
}

/// Central app configuration.
///
/// Backing store is `UserDefaults` (app-side preferences); the subset the
/// engine needs (model choice, language, cleanup options) is mirrored to
/// `~/.velora/config.json` whenever it changes, followed by a
/// `reload_config` push from the caller.
final class AppConfig {
    static let shared = AppConfig()

    private let defaults = UserDefaults.standard

    /// `~/.velora` — shared home for socket, config, modes, history.
    static var veloraDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".velora", isDirectory: true)
    }

    static var socketPath: String {
        veloraDirectory.appendingPathComponent("engine.sock").path
    }

    static var configFileURL: URL {
        veloraDirectory.appendingPathComponent("config.json")
    }

    static var historyDatabaseURL: URL {
        veloraDirectory.appendingPathComponent("history.sqlite3")
    }

    private enum Key {
        static let onboardingComplete = "velora.onboardingComplete"
        static let hotkey = "velora.hotkey"
        static let hotkeyMode = "velora.hotkeyMode"
        static let soundsEnabled = "velora.soundsEnabled"
        static let soundVolume = "velora.soundVolume"
        static let hudPosition = "velora.hudPosition"
        static let appearance = "velora.appearance"
        static let language = "velora.language"
        static let autoPunctuation = "velora.autoPunctuation"
        static let sttModel = "velora.sttModel"
        static let typingFallbackApps = "velora.typingFallbackApps"
    }

    private init() {
        defaults.register(defaults: [
            Key.hotkey: HotkeyChoice.rightOption.rawValue,
            Key.hotkeyMode: HotkeyMode.hold.rawValue,
            Key.soundsEnabled: true,
            Key.soundVolume: 40.0,
            Key.hudPosition: HUDPosition.bottomCenter.rawValue,
            Key.appearance: "system",
            Key.language: "auto",
            Key.autoPunctuation: true,
            Key.sttModel: STTModel.all[0].id,
        ])
    }

    // MARK: - App-side preferences

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Key.onboardingComplete) }
        set { defaults.set(newValue, forKey: Key.onboardingComplete) }
    }

    var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    var hotkeyMode: HotkeyMode {
        get { HotkeyMode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .hold }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundsEnabled) }
        set { defaults.set(newValue, forKey: Key.soundsEnabled) }
    }

    /// 0–100 slider value; playback volume is this / 100.
    var soundVolume: Double {
        get { defaults.double(forKey: Key.soundVolume) }
        set { defaults.set(newValue, forKey: Key.soundVolume) }
    }

    var hudPosition: HUDPosition {
        get { HUDPosition(rawValue: defaults.string(forKey: Key.hudPosition) ?? "") ?? .bottomCenter }
        set { defaults.set(newValue.rawValue, forKey: Key.hudPosition) }
    }

    /// "system" | "light" | "dark"
    var appearance: String {
        get { defaults.string(forKey: Key.appearance) ?? "system" }
        set { defaults.set(newValue, forKey: Key.appearance) }
    }

    // MARK: - Engine-relevant settings (mirrored to config.json)

    var language: String {
        get { defaults.string(forKey: Key.language) ?? "auto" }
        set { defaults.set(newValue, forKey: Key.language); writeEngineConfig() }
    }

    var autoPunctuation: Bool {
        get { defaults.bool(forKey: Key.autoPunctuation) }
        set { defaults.set(newValue, forKey: Key.autoPunctuation); writeEngineConfig() }
    }

    var sttModel: String {
        get { defaults.string(forKey: Key.sttModel) ?? STTModel.all[0].id }
        set { defaults.set(newValue, forKey: Key.sttModel); writeEngineConfig() }
    }

    /// Bundle ids that should use CGEvent unicode typing instead of ⌘V paste
    /// (terminals and other paste-hostile apps). User-extendable.
    var typingFallbackApps: [String] {
        get {
            defaults.stringArray(forKey: Key.typingFallbackApps) ?? Self.defaultTypingFallbackApps
        }
        set { defaults.set(newValue, forKey: Key.typingFallbackApps) }
    }

    static let defaultTypingFallbackApps = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
    ]

    // MARK: - config.json for the engine

    /// Ensures `~/.velora` exists (socket home, config, history) with owner-only
    /// permissions — it holds every transcript and the engine socket.
    @discardableResult
    func ensureVeloraDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: Self.veloraDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: Self.veloraDirectory.path)
            return true
        } catch {
            NSLog("Velora: failed to create ~/.velora: \(error)")
            return false
        }
    }

    /// Read-modify-writes the engine-facing config file: only the app-owned
    /// keys (stt_model, language, auto_punctuation) are updated; engine-owned
    /// keys (cleanup model/flags, vocabulary, replacements, …) are preserved.
    /// The engine reads this at startup and on `reload_config`.
    func writeEngineConfig() {
        ensureVeloraDirectory()
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.configFileURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            payload = existing  // tolerate missing/corrupt file: start fresh
        }
        payload["stt_model"] = sttModel
        payload["language"] = language
        payload["auto_punctuation"] = autoPunctuation
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.configFileURL, options: .atomic)
        } catch {
            NSLog("Velora: failed to write config.json: \(error)")
        }
    }

    /// Writes config.json only if it does not exist yet (first launch).
    func writeEngineConfigIfMissing() {
        guard !FileManager.default.fileExists(atPath: Self.configFileURL.path) else { return }
        writeEngineConfig()
    }
}
