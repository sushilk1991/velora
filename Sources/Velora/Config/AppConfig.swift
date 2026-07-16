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
/// Corner presets exist so the pill can live permanently somewhere that never
/// collides with other dictation HUDs (Wispr Flow owns bottom-center).
enum HUDPosition: String, CaseIterable, Identifiable {
    case bottomCenter, bottomLeft, bottomRight, topCenter, topLeft, topRight, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topCenter: return "Top Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .custom: return "Custom (dragged)"
        }
    }

    /// Presets offered in menus (custom is drag-only).
    static let presets: [HUDPosition] = [
        .bottomLeft, .bottomCenter, .bottomRight, .topLeft, .topCenter, .topRight,
    ]
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

    struct ManualDictionarySnapshot: Codable, Equatable {
        var vocabulary: [String]
        var replacements: [String: String]
    }

    private let defaults = UserDefaults.standard
    private static let engineConfigLock = NSLock()

    /// `~/.velora` — shared home for socket, config, modes, history.
    static var veloraDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".velora", isDirectory: true)
    }

    static var socketPath: String {
        veloraDirectory.appendingPathComponent("engine.sock").path
    }

    /// App-owned CLI/MCP broker, distinct from the engine's single-owner socket.
    static var controlSocketPath: String {
        veloraDirectory.appendingPathComponent("control.sock").path
    }

    static var configFileURL: URL {
        veloraDirectory.appendingPathComponent("config.json")
    }

    static var historyDatabaseURL: URL {
        veloraDirectory.appendingPathComponent("history.sqlite3")
    }

    /// Independent meeting transcript index and disk-spooled audio root.
    static var meetingsDirectory: URL {
        veloraDirectory.appendingPathComponent("meetings", isDirectory: true)
    }

    static var meetingsDatabaseURL: URL {
        meetingsDirectory.appendingPathComponent("meetings.sqlite3")
    }

    /// `~/.velora/modes` — one JSON file per mode (engine + editor shared).
    static var modesDirectory: URL {
        veloraDirectory.appendingPathComponent("modes", isDirectory: true)
    }

    /// `~/.velora/audio` — archived dictation clips for History → Reprocess.
    static var audioDirectory: URL {
        veloraDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    /// Resolves only engine-owned archive basenames. History is a local file,
    /// but a corrupted or manually edited row must never turn playback,
    /// reprocessing, or deletion into a path traversal outside the archive.
    static func archivedAudioURL(name: String?) -> URL? {
        guard let name, !name.isEmpty,
              name == URL(fileURLWithPath: name).lastPathComponent,
              name.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "._-"))
                      .contains($0)
              }),
              name.hasSuffix(".flac") || name.hasSuffix(".wav")
        else { return nil }
        let root = audioDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(name)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
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
        static let hudCustomEdge = "velora.hudCustomEdge"
        static let hudAlwaysVisible = "velora.hudAlwaysVisible"
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
        static let typingWPM = "velora.typingWPM"
        static let localAgentAccess = "velora.localAgentAccess"
        static let meetingSuggestions = "velora.meetingSuggestions"
        static let meetingCalendar = "velora.meetingCalendar"
        static let meetingAudioRetentionDays = "velora.meetingAudioRetentionDays"
    }

    private init() {
        defaults.register(defaults: [
            Key.hotkeyMode: HotkeyMode.hold.rawValue,
            Key.soundsEnabled: true,
            Key.soundVolume: 40.0,
            // Bottom-right by default: bottom-center is where Wispr Flow (and
            // Superwhisper) park their pills, and the persistent idle pill must
            // never fight another dictation HUD for the same pixels.
            Key.hudPosition: HUDPosition.bottomRight.rawValue,
            Key.hudAlwaysVisible: true,
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
            Key.typingWPM: 40,
            Key.localAgentAccess: false,
            Key.meetingSuggestions: true,
            Key.meetingCalendar: false,
            Key.meetingAudioRetentionDays: 30,
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
        get { HUDPosition(rawValue: defaults.string(forKey: Key.hudPosition) ?? "") ?? .bottomRight }
        set { defaults.set(newValue.rawValue, forKey: Key.hudPosition) }
    }

    /// Keep the HUD on screen as a small idle pill when nothing is recording.
    /// Clicking the pill starts/stops dictation; right-click opens quick actions.
    var hudAlwaysVisible: Bool {
        get { defaults.bool(forKey: Key.hudAlwaysVisible) }
        set { defaults.set(newValue, forKey: Key.hudAlwaysVisible) }
    }

    /// Growth anchor for the dragged (custom) pill position — chosen from
    /// where the pill was dropped so the capsule always grows toward open
    /// screen space instead of cropping at a screen edge.
    var hudCustomEdge: HUDEdge {
        get { HUDEdge(rawValue: defaults.string(forKey: Key.hudCustomEdge) ?? "") ?? .center }
        set { defaults.set(newValue.rawValue, forKey: Key.hudCustomEdge) }
    }

    /// Persisted custom HUD spot: the standby pill's CENTER as a fraction
    /// (0…1) of the screen's visible frame, so it survives resolution and
    /// monitor changes and always restores on-screen. `nil` until first drag.
    /// See `HUDPanel.customFraction` / `customPillRect`.
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

    /// The user's typing speed in words per minute, used by the "time saved"
    /// metrics (Intelligence + History header). Default 40; clamped positive
    /// so a corrupted preference can't divide by zero.
    var typingWPM: Int {
        get { max(1, defaults.integer(forKey: Key.typingWPM)) }
        set { defaults.set(max(1, newValue), forKey: Key.typingWPM) }
    }

    /// Grants owner-local CLI/MCP clients access to allow-listed history and
    /// stats. Status remains available while off so the CLI can explain it.
    var localAgentAccess: Bool {
        get { defaults.bool(forKey: Key.localAgentAccess) }
        set { defaults.set(newValue, forKey: Key.localAgentAccess) }
    }

    /// Detection only suggests; capture always needs an explicit per-meeting
    /// confirmation regardless of this preference.
    var meetingSuggestions: Bool {
        get { defaults.bool(forKey: Key.meetingSuggestions) }
        set { defaults.set(newValue, forKey: Key.meetingSuggestions) }
    }

    var meetingCalendar: Bool {
        get { defaults.bool(forKey: Key.meetingCalendar) }
        set { defaults.set(newValue, forKey: Key.meetingCalendar) }
    }

    var meetingAudioRetentionDays: Int {
        get { max(1, defaults.integer(forKey: Key.meetingAudioRetentionDays)) }
        set { defaults.set(min(365, max(1, newValue)), forKey: Key.meetingAudioRetentionDays) }
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

    /// Reads only the user-owned manual dictionary keys. Invalid legacy values
    /// are ignored so they cannot become prompt-active during migration.
    static func manualDictionarySnapshot(at url: URL = configFileURL) -> ManualDictionarySnapshot {
        engineConfigLock.lock()
        defer { engineConfigLock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return ManualDictionarySnapshot(vocabulary: [], replacements: [:]) }
        let vocabulary = validatedTerms((payload["vocabulary"] as? [String]) ?? [])
        var replacements: [String: String] = [:]
        for (rawHeard, rawWritten) in (payload["replacements"] as? [String: String]) ?? [:] {
            guard let heard = try? DictionaryValue(rawHeard),
                  let written = try? DictionaryValue(rawWritten) else { continue }
            replacements[heard.normalized] = written.text
        }
        return ManualDictionarySnapshot(vocabulary: vocabulary, replacements: replacements)
    }

    /// Atomically replaces only manual vocabulary/replacements, preserving
    /// every engine/app setting and unknown future key in config.json.
    @discardableResult
    static func applyManualDictionary(
        _ snapshot: ManualDictionarySnapshot,
        at url: URL = configFileURL
    ) -> Bool {
        var vocabulary: [String] = []
        var seen: Set<String> = []
        for rawTerm in snapshot.vocabulary {
            guard let term = try? DictionaryValue(rawTerm) else { return false }
            if seen.insert(term.normalized).inserted { vocabulary.append(term.text) }
        }
        var replacements: [String: String] = [:]
        for (rawHeard, rawWritten) in snapshot.replacements {
            guard let heard = try? DictionaryValue(rawHeard),
                  let written = try? DictionaryValue(rawWritten) else { return false }
            replacements[heard.normalized] = written.text
        }
        return updateEngineConfig(at: url) { payload in
            payload["vocabulary"] = vocabulary
            payload["replacements"] = replacements
        }
    }

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
        _ = Self.updateEngineConfig(at: Self.configFileURL) { payload in
            payload["stt_model"] = self.sttModel
            payload["language"] = self.language
            payload["auto_punctuation"] = self.autoPunctuation
            payload["save_audio"] = self.saveAudio
            payload["romanize_output"] = self.romanizeOutput
            payload["vocab_mining"] = self.vocabMining
            payload["smart_terminal"] = self.smartTerminal
        }
    }

    /// Writes config.json only if it does not exist yet (first launch).
    func writeEngineConfigIfMissing() {
        guard !FileManager.default.fileExists(atPath: Self.configFileURL.path) else { return }
        writeEngineConfig()
    }

    private static func updateEngineConfig(
        at url: URL,
        _ mutation: (inout [String: Any]) -> Void
    ) -> Bool {
        engineConfigLock.lock()
        defer { engineConfigLock.unlock() }
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            payload = existing
        }
        mutation(&payload)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("Velora: failed to write config.json: \(error)")
            return false
        }
    }

    private static func validatedTerms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawTerm in terms {
            guard let term = try? DictionaryValue(rawTerm),
                  seen.insert(term.normalized).inserted else { continue }
            result.append(term.text)
        }
        return result
    }
}
