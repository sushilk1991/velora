import Foundation

/// How the hotkey drives recording.
enum HotkeyMode: String, CaseIterable, Identifiable {
    /// Hold to talk; release to transcribe. A quick tap locks recording on;
    /// the next tap ends it.
    case hold
    /// Each press toggles recording on/off.
    case toggle

    var id: String { rawValue }
    var displayName: String { self == .hold ? "Hold to talk" : "Press to toggle" }
}

/// Where the HUD capsule sits on screen. `custom` is set when the user drags
/// the HUD; its origin is stored separately in `AppConfig.hudCustomOrigin`.
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter, topCenter, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bottomCenter: return "Bottom center"
        case .topCenter: return "Top center"
        case .custom: return "Custom (dragged)"
        }
    }
}

/// A speech-to-text model the engine can run. The engine owns downloads;
/// the app only selects the active model.
struct STTModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let size: String
    let speed: String
    let languages: String

    // Fallback catalog + source of the default model (`all[0]`). The live
    // picker is driven by the engine's registry (status.models); this list
    // must stay ordered to match it — turbo is the default. See
    // engine/src/velora_engine/models.py and docs/research/stt-multilingual-decision.md.
    static let all: [STTModel] = [
        STTModel(
            id: "mlx-community/whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo",
            size: "~1.6 GB", speed: "Fast", languages: "Multilingual — Hindi, Indian English, 99 langs"
        ),
        STTModel(
            id: "mlx-community/whisper-large-v3-mlx",
            displayName: "Whisper Large v3 (full)",
            size: "~3.1 GB", speed: "Slower", languages: "Multilingual — highest accuracy"
        ),
        STTModel(
            id: "knownsense/whisper-hindi-apex-mlx",
            displayName: "Whisper Hindi/Hinglish (Apex)",
            size: "~1.6 GB", speed: "Fast", languages: "Hindi & Hinglish (Romanized)"
        ),
        STTModel(
            id: "mlx-community/parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3",
            size: "~2.5 GB", speed: "Fastest (live streaming)", languages: "English + 24 European"
        ),
        STTModel(
            id: "mlx-community/parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2",
            size: "~2.3 GB", speed: "Fastest (live streaming)", languages: "English only"
        ),
        STTModel(
            id: "mlx-community/whisper-large-v3-turbo-q4",
            displayName: "Whisper Turbo (4-bit)",
            size: "~0.5 GB", speed: "Fast", languages: "Multilingual — smallest, roughest"
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

    /// `~/.velora/modes` — one JSON file per mode (engine + editor shared).
    static var modesDirectory: URL {
        veloraDirectory.appendingPathComponent("modes", isDirectory: true)
    }

    /// `~/.velora/audio` — archived dictation clips for History → Reprocess.
    static var audioDirectory: URL {
        veloraDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    private enum Key {
        static let onboardingComplete = "velora.onboardingComplete"
        /// Legacy P0 curated-picker value (`HotkeyChoice` raw string).
        static let legacyHotkey = "velora.hotkey"
        /// Recorder-era hotkey (`Hotkey.defaultsRepresentation` dictionary).
        static let hotkey = "velora.hotkey.v2"
        static let hotkeyMode = "velora.hotkeyMode"
        static let soundsEnabled = "velora.soundsEnabled"
        static let soundVolume = "velora.soundVolume"
        static let hudPosition = "velora.hudPosition"
        static let hudCustomOriginX = "velora.hudCustomOriginX"
        static let hudCustomOriginY = "velora.hudCustomOriginY"
        static let appearance = "velora.appearance"
        static let language = "velora.language"
        static let autoPunctuation = "velora.autoPunctuation"
        static let sttModel = "velora.sttModel"
        static let saveAudio = "velora.saveAudio"
        static let romanizeOutput = "velora.romanizeOutput"
        static let learnFromEdits = "velora.learnFromEdits"
        static let vocabMining = "velora.vocabMining"
        static let smartTerminal = "velora.smartTerminal"
        static let voiceCommands = "velora.voiceCommands"
        static let typingFallbackApps = "velora.typingFallbackApps"
    }

    private init() {
        defaults.register(defaults: [
            Key.hotkeyMode: HotkeyMode.hold.rawValue,
            Key.soundsEnabled: true,
            Key.soundVolume: 40.0,
            Key.hudPosition: HUDPosition.bottomCenter.rawValue,
            Key.appearance: "system",
            Key.language: "auto",
            Key.autoPunctuation: true,
            Key.sttModel: STTModel.all[0].id,
            Key.saveAudio: true,
            Key.romanizeOutput: false,
            Key.learnFromEdits: true,
            Key.vocabMining: true,
            Key.smartTerminal: true,
            Key.voiceCommands: true,
        ])
        migrateLegacyHotkeyIfNeeded()
    }

    /// One-time migration: users upgrading from the P0 curated hotkey picker
    /// keep their choice in the new recorder storage format.
    private func migrateLegacyHotkeyIfNeeded() {
        guard defaults.dictionary(forKey: Key.hotkey) == nil,
              let legacy = defaults.string(forKey: Key.legacyHotkey),
              let migrated = Hotkey(legacyChoice: legacy)
        else { return }
        defaults.set(migrated.defaultsRepresentation, forKey: Key.hotkey)
        NSLog("Velora: migrated legacy hotkey '%@' to recorder format (%@)",
              legacy, migrated.displayLabel)
    }

    // MARK: - App-side preferences

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Key.onboardingComplete) }
        set { defaults.set(newValue, forKey: Key.onboardingComplete) }
    }

    /// The dictation hotkey (recorder format; default Right Option).
    var hotkey: Hotkey {
        get {
            if let dict = defaults.dictionary(forKey: Key.hotkey),
               let stored = Hotkey(defaultsRepresentation: dict) {
                return stored
            }
            return .rightOption
        }
        set { defaults.set(newValue.defaultsRepresentation, forKey: Key.hotkey) }
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

    /// Persisted custom HUD origin as a fraction (0…1) of the screen's visible
    /// frame, so it survives resolution/monitor changes. `nil` until first drag.
    var hudCustomOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Key.hudCustomOriginX) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Key.hudCustomOriginX),
                           y: defaults.double(forKey: Key.hudCustomOriginY))
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: Key.hudCustomOriginX)
                defaults.set(p.y, forKey: Key.hudCustomOriginY)
            } else {
                defaults.removeObject(forKey: Key.hudCustomOriginX)
                defaults.removeObject(forKey: Key.hudCustomOriginY)
            }
        }
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

    /// Whether the engine archives each dictation's audio clip under
    /// `~/.velora/audio` (enables History → Reprocess). Default on.
    var saveAudio: Bool {
        get { defaults.bool(forKey: Key.saveAudio) }
        set { defaults.set(newValue, forKey: Key.saveAudio); writeEngineConfig() }
    }

    /// Romanize non-English output — write Hindi/other non-Latin speech in the
    /// Latin alphabet (natural Hinglish) instead of the native script.
    /// When on, Velora learns spelling corrections from edits you make to its
    /// output (local only). No engine config write — the learning store is a
    /// separate file the engine merges.
    var learnFromEdits: Bool {
        get { defaults.bool(forKey: Key.learnFromEdits) }
        set { defaults.set(newValue, forKey: Key.learnFromEdits) }
    }

    /// Voice commands: an utterance that IS a command ("scratch that",
    /// "new line") executes instead of being pasted as text. App-side only.
    var voiceCommands: Bool {
        get { defaults.bool(forKey: Key.voiceCommands) }
        set { defaults.set(newValue, forKey: Key.voiceCommands) }
    }

    var romanizeOutput: Bool {
        get { defaults.bool(forKey: Key.romanizeOutput) }
        set { defaults.set(newValue, forKey: Key.romanizeOutput); writeEngineConfig() }
    }

    /// Idle vocabulary mining: while nothing is happening, the engine's cleanup
    /// LLM extracts recurring names/jargon from recent dictations into an
    /// auto-learned vocabulary (all local). Mirrored as `vocab_mining`.
    var vocabMining: Bool {
        get { defaults.bool(forKey: Key.vocabMining) }
        set { defaults.set(newValue, forKey: Key.vocabMining); writeEngineConfig() }
    }

    /// Smart Terminal gate: long prose dictated into a terminal (AI chats like
    /// Claude Code) gets LLM cleanup; short command-like utterances stay
    /// verbatim. Mirrored as `smart_terminal`.
    var smartTerminal: Bool {
        get { defaults.bool(forKey: Key.smartTerminal) }
        set { defaults.set(newValue, forKey: Key.smartTerminal); writeEngineConfig() }
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
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.cmuxterm.app",
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
    /// keys (stt_model, language, auto_punctuation, save_audio,
    /// romanize_output, vocab_mining, smart_terminal) are updated; engine-owned
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
        payload["save_audio"] = saveAudio
        payload["romanize_output"] = romanizeOutput
        payload["vocab_mining"] = vocabMining
        payload["smart_terminal"] = smartTerminal
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
