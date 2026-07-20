import Darwin
import Foundation

/// How the hotkey drives recording.
enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
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
enum HUDPosition: String, Codable, CaseIterable, Identifiable {
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
            id: "handy-computer/whisper-large-v3-turbo-gguf",
            displayName: "Whisper Turbo Q8 (Experimental)",
            size: "~0.85 GB", speed: "Faster", languages: "Multilingual — transcribe.cpp"
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
/// Backing store is the versioned `~/.velora/settings.json`. Existing
/// `UserDefaults` values are migrated when that file is first created. The
/// subset the engine needs (model choice, language, cleanup options) is mirrored
/// to `~/.velora/config.json`, followed by a `reload_config` push from callers.
final class AppConfig {
    static let shared = AppConfig(
        defaults: .standard,
        settingsFileURL: settingsFileURL,
        engineConfigURL: configFileURL)

    struct ManualDictionarySnapshot: Codable, Equatable {
        var vocabulary: [String]
        var replacements: [String: String]
    }

    private let defaults: UserDefaults
    private let settingsStorageURL: URL
    private let engineConfigStorageURL: URL
    /// Serializes multi-file imports with ordinary preference mutations.
    private let settingsMutationLock = NSLock()
    private let settingsLock = NSLock()
    private var settingsDocument = SettingsDocument.defaults
    private var localSettings = SettingsDocument.MachineLocalSettings.defaults
    private var settingsWriteBlockError: SettingsDocumentError?
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

    /// Typed portable preferences. This file is safe to copy between Macs as-is.
    static var settingsFileURL: URL {
        veloraDirectory.appendingPathComponent("settings.json")
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
        static let settingsSidebarCollapsed = "velora.settingsSidebarCollapsed"
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
        static let meetingDiarization = "velora.meetingDiarization"
        static let inputDeviceUID = "velora.inputDeviceUID"
        static let editHotkey = "velora.editHotkey.v1"
        static let voiceEdit = "velora.voiceEdit"
        static let updateChecks = "velora.updateChecks"
        static let autoInstallUpdates = "velora.autoInstallUpdates"
        static let lastUpdateCheckAt = "velora.lastUpdateCheckAt"
        static let launchAtLogin = "velora.launchAtLogin"
    }

    /// Injected URLs keep migration and rollback tests out of the developer's
    /// real ~/.velora directory.
    init(
        defaults: UserDefaults,
        settingsFileURL: URL,
        engineConfigURL: URL,
        registerDefaults: Bool = true
    ) {
        self.defaults = defaults
        settingsStorageURL = settingsFileURL
        engineConfigStorageURL = engineConfigURL
        if registerDefaults {
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
                Key.meetingDiarization: true,
                Key.voiceEdit: true,
                Key.updateChecks: true,
                Key.launchAtLogin: false,
                // Off by default: downloading and swapping the app without being
                // asked should be something the user opted into.
                Key.autoInstallUpdates: false,
            ])
        }
        localSettings = Self.migratedLocalSettings(defaults: defaults)
        loadOrMigrateSettings()
    }

    private func loadOrMigrateSettings() {
        let fileExists = FileManager.default.fileExists(atPath: settingsStorageURL.path)
        if fileExists {
            do {
                let data = try Data(contentsOf: settingsStorageURL)
                let loaded = try SettingsDocumentCodec.decode(data)
                settingsDocument = loaded
                return
            } catch let error as SettingsDocumentError {
                if case .unsupportedVersion = error {
                    settingsWriteBlockError = error
                    settingsDocument = Self.migratedSettingsDocument(
                        defaults: defaults, engineConfigURL: engineConfigStorageURL)
                    NSLog("Velora: settings.json is from a newer app version; leaving it untouched")
                    return
                }
                guard preserveCorruptSettingsFile() else {
                    settingsWriteBlockError = .couldNotSave
                    settingsDocument = Self.migratedSettingsDocument(
                        defaults: defaults, engineConfigURL: engineConfigStorageURL)
                    return
                }
                NSLog("Velora: settings.json was invalid and was preserved: \(error)")
            } catch {
                guard preserveCorruptSettingsFile() else {
                    settingsWriteBlockError = .couldNotSave
                    settingsDocument = Self.migratedSettingsDocument(
                        defaults: defaults, engineConfigURL: engineConfigStorageURL)
                    return
                }
                NSLog("Velora: settings.json was invalid and was preserved: \(error)")
            }
        }

        // Once portable settings exist, UserDefaults are only historical
        // migration input. Recover a missing/corrupt canonical file from the
        // app-owned last-known-good copy instead of silently resurrecting
        // stale pre-migration preferences.
        if let recovered = recoverSettingsBackup() {
            settingsDocument = recovered
            do {
                try persistSettingsDocument(recovered)
                NSLog("Velora: recovered settings.json from its last-known-good copy")
            } catch {
                settingsWriteBlockError = .couldNotSave
                NSLog("Velora: recovered settings in memory but could not restore settings.json: \(error)")
            }
            return
        }

        settingsDocument = Self.migratedSettingsDocument(
            defaults: defaults, engineConfigURL: engineConfigStorageURL)
        do {
            try persistSettingsDocument(settingsDocument)
        } catch {
            settingsWriteBlockError = .couldNotSave
            NSLog("Velora: failed to create settings.json: \(error)")
        }
    }

    /// One-time bridge from the previous UserDefaults-backed implementation.
    /// Registered defaults make missing keys resolve to the same values a fresh
    /// install used before settings.json existed.
    static func migratedSettingsDocument(
        defaults: UserDefaults,
        engineConfigURL: URL
    ) -> SettingsDocument {
        let defaultDocument = SettingsDocument.defaults
        var document = defaultDocument

        let storedHotkey: Hotkey = {
            if let dict = defaults.dictionary(forKey: Key.hotkey),
               let value = Hotkey(defaultsRepresentation: dict), value.isValidSettingsHotkey {
                return value
            }
            if let legacy = defaults.string(forKey: Key.legacyHotkey),
               let value = Hotkey(legacyChoice: legacy) {
                return value
            }
            return defaultDocument.settings.shortcuts.dictation
        }()
        let storedEditHotkey: Hotkey = {
            guard let dict = defaults.dictionary(forKey: Key.editHotkey),
                  let value = Hotkey(defaultsRepresentation: dict),
                  value.isValidSettingsHotkey,
                  value != storedHotkey else {
                let preferred = defaultDocument.settings.shortcuts.editSelection
                return preferred != storedHotkey
                    ? preferred
                    : defaultDocument.settings.shortcuts.dictation
            }
            return value
        }()

        let appearance = defaults.string(forKey: Key.appearance) ?? "system"
        document.settings.general.appearance = ["system", "light", "dark"].contains(appearance)
            ? appearance : "system"
        let volume = defaults.double(forKey: Key.soundVolume)
        document.settings.general.soundsEnabled = defaults.bool(forKey: Key.soundsEnabled)
        document.settings.general.soundVolume = volume.isFinite ? min(100, max(0, volume)) : 40

        document.settings.hud.position = HUDPosition(
            rawValue: defaults.string(forKey: Key.hudPosition) ?? "") ?? .bottomRight
        if defaults.object(forKey: Key.hudCustomOriginX) != nil {
            let x = defaults.double(forKey: Key.hudCustomOriginX)
            let y = defaults.double(forKey: Key.hudCustomOriginY)
            if x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
                document.settings.hud.customOrigin = .init(x: x, y: y)
            }
        }
        document.settings.hud.customEdge = HUDEdge(
            rawValue: defaults.string(forKey: Key.hudCustomEdge) ?? "") ?? .center
        document.settings.hud.alwaysVisible = defaults.bool(forKey: Key.hudAlwaysVisible)

        let language = defaults.string(forKey: Key.language) ?? "auto"
        document.settings.dictation.language = !language.isEmpty
            && language.count <= 32
            && language.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
            ? language : "auto"
        document.settings.dictation.autoPunctuation = defaults.bool(forKey: Key.autoPunctuation)
        document.settings.dictation.saveAudio = defaults.bool(forKey: Key.saveAudio)
        document.settings.dictation.romanizeOutput = defaults.bool(forKey: Key.romanizeOutput)
        document.settings.dictation.learnFromEdits = defaults.bool(forKey: Key.learnFromEdits)
        document.settings.dictation.vocabularyMining = defaults.bool(forKey: Key.vocabMining)
        document.settings.dictation.smartTerminal = defaults.bool(forKey: Key.smartTerminal)
        document.settings.dictation.voiceCommands = defaults.bool(forKey: Key.voiceCommands)
        let fallbackApps = defaults.stringArray(forKey: Key.typingFallbackApps)
            ?? Self.defaultTypingFallbackApps
        document.settings.dictation.typingFallbackApps = Array(fallbackApps.prefix(256)).filter {
            !$0.isEmpty && $0.count <= 512
                && $0.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }
        document.settings.dictation.typingWordsPerMinute =
            max(1, defaults.integer(forKey: Key.typingWPM))

        let speechModel = defaults.string(forKey: Key.sttModel) ?? STTModel.all[0].id
        document.settings.models.speech = speechModel.isEmpty || speechModel.count > 512
            || speechModel.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) ? STTModel.all[0].id : speechModel
        if let data = try? Data(contentsOf: engineConfigURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let enabled = payload["cleanup_enabled"] as? Bool {
                document.settings.engine.cleanupEnabled = enabled
            }
            if let mode = payload["default_mode"] as? String,
               !mode.isEmpty, mode.count <= 128,
               mode.unicodeScalars.allSatisfy({
                   !CharacterSet.controlCharacters.contains($0)
               }) {
                document.settings.engine.defaultMode = mode
            }
            if let streaming = payload["streaming_cleanup"] as? Bool {
                document.settings.engine.streamingCleanup = streaming
            }
            if let seconds = (payload["max_recording_s"] as? NSNumber)?.doubleValue,
               seconds.isFinite, seconds > 0, seconds <= 86_400 {
                document.settings.engine.maximumRecordingSeconds = seconds
            }
            if let days = (payload["audio_retention_days"] as? NSNumber)?.doubleValue,
               days.isFinite, days > 0, days <= 36_500 {
                document.settings.engine.audioRetentionDays = days
            }
            if let megabytes = (payload["audio_max_mb"] as? NSNumber)?.doubleValue,
               megabytes.isFinite, megabytes >= 0, megabytes <= 1_048_576 {
                document.settings.engine.audioMaximumMegabytes = megabytes
            }
        }

        document.settings.meetings.suggestions = defaults.bool(forKey: Key.meetingSuggestions)
        document.settings.meetings.audioRetentionDays =
            min(365, max(1, defaults.integer(forKey: Key.meetingAudioRetentionDays)))
        document.settings.meetings.diarization = defaults.bool(forKey: Key.meetingDiarization)
        document.settings.shortcuts = .init(
            dictation: storedHotkey,
            editSelection: storedEditHotkey,
            voiceEdit: defaults.bool(forKey: Key.voiceEdit),
            behavior: HotkeyMode(
                rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .hold)
        document.settings.updates = .init(
            checkAutomatically: defaults.bool(forKey: Key.updateChecks),
            installAutomatically: defaults.bool(forKey: Key.autoInstallUpdates))

        return document
    }

    /// Machine identity, security gates, and OS-backed choices deliberately
    /// stay outside the portable JSON document.
    static func migratedLocalSettings(
        defaults: UserDefaults
    ) -> SettingsDocument.MachineLocalSettings {
        let inputDevice = defaults.string(forKey: Key.inputDeviceUID)
        let validInputDevice = inputDevice.flatMap { value in
            !value.isEmpty && value.count <= 1024
                && value.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                }) ? value : nil
        }
        let lastUpdateCheck = defaults.double(forKey: Key.lastUpdateCheckAt)
        return .init(
            onboardingComplete: defaults.bool(forKey: Key.onboardingComplete),
            settingsSidebarCollapsed: defaults.bool(forKey: Key.settingsSidebarCollapsed),
            inputDeviceUid: validInputDevice,
            localAgentAccess: defaults.bool(forKey: Key.localAgentAccess),
            meetingCalendar: defaults.bool(forKey: Key.meetingCalendar),
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin),
            lastUpdateCheck: lastUpdateCheck.isFinite ? max(0, lastUpdateCheck) : 0)
    }

    @discardableResult
    private func preserveCorruptSettingsFile() -> Bool {
        let backup = settingsStorageURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        do {
            try FileManager.default.moveItem(at: settingsStorageURL, to: backup)
            return true
        } catch {
            NSLog("Velora: failed to preserve corrupt settings.json: \(error)")
            return false
        }
    }

    private var settingsBackupURL: URL {
        settingsStorageURL.deletingPathExtension()
            .appendingPathExtension("backup.json")
    }

    private func recoverSettingsBackup() -> SettingsDocument? {
        guard let data = try? Data(contentsOf: settingsBackupURL),
              let recovered = try? SettingsDocumentCodec.decode(data) else { return nil }
        return recovered
    }

    private func writeSettingsBackup(_ data: Data) {
        do {
            try data.write(to: settingsBackupURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: settingsBackupURL.path)
        } catch {
            NSLog("Velora: could not refresh settings backup: \(error)")
        }
    }

    private func persistSettingsDocument(_ document: SettingsDocument) throws {
        try SettingsDocumentCodec.validate(document)
        let data = try SettingsDocumentCodec.encode(document)
        do {
            try FileManager.default.createDirectory(
                at: settingsStorageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: settingsStorageURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: settingsStorageURL.path)
            writeSettingsBackup(data)
        } catch {
            throw SettingsDocumentError.couldNotSave
        }
    }

    private func readSetting<Value>(
        _ keyPath: KeyPath<SettingsDocument.PortableSettings, Value>
    ) -> Value {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return settingsDocument.settings[keyPath: keyPath]
    }

    private func readLocalSetting<Value>(
        _ keyPath: KeyPath<SettingsDocument.MachineLocalSettings, Value>
    ) -> Value {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return localSettings[keyPath: keyPath]
    }

    private func updateSettings(
        _ mutation: (inout SettingsDocument.PortableSettings) -> Void
    ) {
        settingsMutationLock.lock()
        defer { settingsMutationLock.unlock() }
        settingsLock.lock()
        defer { settingsLock.unlock() }
        guard settingsWriteBlockError == nil else {
            NSLog("Velora: settings change ignored because settings.json is write-protected")
            return
        }
        var candidate = settingsDocument
        mutation(&candidate.settings)
        guard candidate != settingsDocument else { return }
        do {
            try persistSettingsDocument(candidate)
            settingsDocument = candidate
        } catch {
            NSLog("Velora: failed to persist settings change: \(error)")
        }
    }

    private func updateLocalSettings(
        _ mutation: (inout SettingsDocument.MachineLocalSettings) -> Void
    ) {
        settingsMutationLock.lock()
        defer { settingsMutationLock.unlock() }
        settingsLock.lock()
        defer { settingsLock.unlock() }
        var candidate = localSettings
        mutation(&candidate)
        guard candidate != localSettings else { return }
        localSettings = candidate
        persistLocalSettings(candidate)
    }

    private func persistLocalSettings(_ local: SettingsDocument.MachineLocalSettings) {
        defaults.set(local.onboardingComplete, forKey: Key.onboardingComplete)
        defaults.set(local.settingsSidebarCollapsed, forKey: Key.settingsSidebarCollapsed)
        if let uid = local.inputDeviceUid {
            defaults.set(uid, forKey: Key.inputDeviceUID)
        } else {
            defaults.removeObject(forKey: Key.inputDeviceUID)
        }
        defaults.set(local.localAgentAccess, forKey: Key.localAgentAccess)
        defaults.set(local.meetingCalendar, forKey: Key.meetingCalendar)
        defaults.set(local.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(local.lastUpdateCheck, forKey: Key.lastUpdateCheckAt)
    }

    // MARK: - App-side preferences

    var onboardingComplete: Bool {
        get { readLocalSetting(\.onboardingComplete) }
        set { updateLocalSettings { $0.onboardingComplete = newValue } }
    }

    /// The dictation hotkey (recorder format; default Right Option).
    var hotkey: Hotkey {
        get { readSetting(\.shortcuts.dictation) }
        set { updateSettings { $0.shortcuts.dictation = newValue } }
    }

    /// Safe Voice Edit: select text, press this, speak an instruction.
    var editHotkey: Hotkey {
        get { readSetting(\.shortcuts.editSelection) }
        set { updateSettings { $0.shortcuts.editSelection = newValue } }
    }

    var voiceEdit: Bool {
        get { readSetting(\.shortcuts.voiceEdit) }
        set { updateSettings { $0.shortcuts.voiceEdit = newValue } }
    }

    /// What the monitor should listen for — nil when the feature is off.
    var activeEditHotkey: Hotkey? { voiceEdit ? editHotkey : nil }

    var hotkeyMode: HotkeyMode {
        get { readSetting(\.shortcuts.behavior) }
        set { updateSettings { $0.shortcuts.behavior = newValue } }
    }

    var soundsEnabled: Bool {
        get { readSetting(\.general.soundsEnabled) }
        set { updateSettings { $0.general.soundsEnabled = newValue } }
    }

    /// 0–100 slider value; playback volume is this / 100.
    var soundVolume: Double {
        get { readSetting(\.general.soundVolume) }
        set { updateSettings { $0.general.soundVolume = min(100, max(0, newValue)) } }
    }

    var hudPosition: HUDPosition {
        get { readSetting(\.hud.position) }
        set { updateSettings { $0.hud.position = newValue } }
    }

    /// Keep the HUD on screen as a small idle pill when nothing is recording.
    /// Clicking the pill starts/stops dictation; right-click opens quick actions.
    var hudAlwaysVisible: Bool {
        get { readSetting(\.hud.alwaysVisible) }
        set { updateSettings { $0.hud.alwaysVisible = newValue } }
    }

    /// Settings sidebar collapsed to the icon-only rail (default: expanded).
    var settingsSidebarCollapsed: Bool {
        get { readLocalSetting(\.settingsSidebarCollapsed) }
        set { updateLocalSettings { $0.settingsSidebarCollapsed = newValue } }
    }

    /// Growth anchor for the dragged (custom) pill position — chosen from
    /// where the pill was dropped so the capsule always grows toward open
    /// screen space instead of cropping at a screen edge.
    var hudCustomEdge: HUDEdge {
        get { readSetting(\.hud.customEdge) }
        set { updateSettings { $0.hud.customEdge = newValue } }
    }

    /// Persisted custom HUD spot: the standby pill's CENTER as a fraction
    /// (0…1) of the screen's visible frame, so it survives resolution and
    /// monitor changes and always restores on-screen. `nil` until first drag.
    /// See `HUDPanel.customFraction` / `customPillRect`.
    var hudCustomOrigin: CGPoint? {
        get {
            guard let point = readSetting(\.hud.customOrigin) else { return nil }
            return CGPoint(x: point.x, y: point.y)
        }
        set {
            updateSettings { settings in
                settings.hud.customOrigin = newValue.map {
                    .init(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y)))
                }
            }
        }
    }

    /// UID of the microphone to record from; nil = follow the system default.
    /// Kept while the device is unplugged so the choice wins again on
    /// reconnect (see AudioInputDevices.resolve).
    var inputDeviceUID: String? {
        get { readLocalSetting(\.inputDeviceUid) }
        set { updateLocalSettings { $0.inputDeviceUid = newValue } }
    }

    /// "system" | "light" | "dark"
    var appearance: String {
        get { readSetting(\.general.appearance) }
        set { updateSettings { $0.general.appearance = newValue } }
    }

    /// Desired launch-at-login state. `SMAppService` remains the runtime
    /// authority; SettingsModel reconciles this value after each system call.
    var launchAtLogin: Bool {
        get { readLocalSetting(\.launchAtLogin) }
        set { updateLocalSettings { $0.launchAtLogin = newValue } }
    }

    // MARK: - Engine-relevant settings (mirrored to config.json)

    var language: String {
        get { readSetting(\.dictation.language) }
        set { updateSettings { $0.dictation.language = newValue }; writeEngineConfig() }
    }

    var autoPunctuation: Bool {
        get { readSetting(\.dictation.autoPunctuation) }
        set { updateSettings { $0.dictation.autoPunctuation = newValue }; writeEngineConfig() }
    }

    var sttModel: String {
        get { readSetting(\.models.speech) }
        set { updateSettings { $0.models.speech = newValue }; writeEngineConfig() }
    }

    /// The engine's selected cleanup model. Nil only before its first RAM-based
    /// recommendation; status/model-set events fill it in thereafter.
    var cleanupModel: String? {
        get {
            Self.engineConfigLock.lock()
            defer { Self.engineConfigLock.unlock() }
            guard let data = try? Data(contentsOf: engineConfigStorageURL),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let model = payload["cleanup_model"] as? String,
                  !model.isEmpty else { return nil }
            return model
        }
        set {
            guard newValue != cleanupModel else { return }
            _ = Self.updateEngineConfig(at: engineConfigStorageURL) { payload in
                if let newValue, !newValue.isEmpty {
                    payload["cleanup_model"] = newValue
                } else {
                    payload.removeValue(forKey: "cleanup_model")
                }
            }
        }
    }

    var portableEngineSettings: SettingsDocument.Engine {
        readSetting(\.engine)
    }

    /// Whether the engine archives each dictation's audio clip under
    /// `~/.velora/audio` (enables History → Reprocess). Default on.
    var saveAudio: Bool {
        get { readSetting(\.dictation.saveAudio) }
        set { updateSettings { $0.dictation.saveAudio = newValue }; writeEngineConfig() }
    }

    /// Romanize non-English output — write Hindi/other non-Latin speech in the
    /// Latin alphabet (natural Hinglish) instead of the native script.
    /// When on, Velora learns spelling corrections from edits you make to its
    /// output (local only). No engine config write — the learning store is a
    /// separate file the engine merges.
    var learnFromEdits: Bool {
        get { readSetting(\.dictation.learnFromEdits) }
        set { updateSettings { $0.dictation.learnFromEdits = newValue } }
    }

    /// The user's typing speed in words per minute, used by the "time saved"
    /// metrics (Intelligence + History header). Default 40; clamped positive
    /// so a corrupted preference can't divide by zero.
    var typingWPM: Int {
        get { readSetting(\.dictation.typingWordsPerMinute) }
        set { updateSettings { $0.dictation.typingWordsPerMinute = max(1, newValue) } }
    }

    /// Grants owner-local CLI/MCP clients access to allow-listed history and
    /// stats. Status remains available while off so the CLI can explain it.
    var localAgentAccess: Bool {
        get { readLocalSetting(\.localAgentAccess) }
        set { updateLocalSettings { $0.localAgentAccess = newValue } }
    }

    /// Detection only suggests; capture always needs an explicit per-meeting
    /// confirmation regardless of this preference.
    var meetingSuggestions: Bool {
        get { readSetting(\.meetings.suggestions) }
        set { updateSettings { $0.meetings.suggestions = newValue } }
    }

    var meetingCalendar: Bool {
        get { readLocalSetting(\.meetingCalendar) }
        set { updateLocalSettings { $0.meetingCalendar = newValue } }
    }

    var meetingAudioRetentionDays: Int {
        get { readSetting(\.meetings.audioRetentionDays) }
        set { updateSettings { $0.meetings.audioRetentionDays = min(365, max(1, newValue)) } }
    }

    /// Split the meeting system-audio track into per-speaker turns
    /// ("Speaker 1/2/…"). Mirrored as `meeting_diarization`; the engine
    /// downloads its ~46 MB of ONNX models on first use, all local.
    var meetingDiarization: Bool {
        get { readSetting(\.meetings.diarization) }
        set { updateSettings { $0.meetings.diarization = newValue }; writeEngineConfig() }
    }

    /// Daily anonymous GitHub releases check (UpdateChecker documents the
    /// privacy contract). Off = Velora never talks to the network at all.
    var updateChecks: Bool {
        get { readSetting(\.updates.checkAutomatically) }
        set { updateSettings { $0.updates.checkAutomatically = newValue } }
    }

    /// When a daily check finds a release, download + verify + stage it
    /// silently and install on the next quit or restart (UpdateInstaller).
    var autoInstallUpdates: Bool {
        get { readSetting(\.updates.installAutomatically) }
        set { updateSettings { $0.updates.installAutomatically = newValue } }
    }

    var lastUpdateCheck: Date {
        get { Date(timeIntervalSince1970: readLocalSetting(\.lastUpdateCheck)) }
        set { updateLocalSettings { $0.lastUpdateCheck = max(0, newValue.timeIntervalSince1970) } }
    }

    /// Voice commands: an utterance that IS a command ("scratch that",
    /// "new line") executes instead of being pasted as text. App-side only.
    var voiceCommands: Bool {
        get { readSetting(\.dictation.voiceCommands) }
        set { updateSettings { $0.dictation.voiceCommands = newValue } }
    }

    var romanizeOutput: Bool {
        get { readSetting(\.dictation.romanizeOutput) }
        set { updateSettings { $0.dictation.romanizeOutput = newValue }; writeEngineConfig() }
    }

    /// Idle vocabulary mining: while nothing is happening, the engine's cleanup
    /// LLM extracts recurring names/jargon from recent dictations into an
    /// auto-learned vocabulary (all local). Mirrored as `vocab_mining`.
    var vocabMining: Bool {
        get { readSetting(\.dictation.vocabularyMining) }
        set { updateSettings { $0.dictation.vocabularyMining = newValue }; writeEngineConfig() }
    }

    /// Smart Terminal gate: long prose dictated into a terminal (AI chats like
    /// Claude Code) gets LLM cleanup; short command-like utterances stay
    /// verbatim. Mirrored as `smart_terminal`.
    var smartTerminal: Bool {
        get { readSetting(\.dictation.smartTerminal) }
        set { updateSettings { $0.dictation.smartTerminal = newValue }; writeEngineConfig() }
    }

    /// Bundle ids that should use CGEvent unicode typing instead of ⌘V paste
    /// (terminals and other paste-hostile apps). User-extendable.
    var typingFallbackApps: [String] {
        get { readSetting(\.dictation.typingFallbackApps) }
        set { updateSettings { $0.dictation.typingFallbackApps = newValue } }
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

    // MARK: - Portable settings transfer

    /// JSON users can keep in source control or move to another Mac. Machine
    /// state and local security grants never enter this document.
    func exportSettingsData() throws -> Data {
        settingsLock.lock()
        let portable = settingsDocument
        settingsLock.unlock()
        return try SettingsDocumentCodec.encode(portable)
    }

    /// Parses and validates the entire file without changing current settings.
    /// The Settings UI uses this before showing its overwrite confirmation.
    static func portableSettings(from data: Data) throws -> SettingsDocument.PortableSettings {
        try SettingsDocumentCodec.decode(data).settings
    }

    /// Atomically replaces portable preferences; local state lives elsewhere.
    /// Callers apply runtime side effects (hotkeys, HUD, appearance, engine
    /// reload) only after this succeeds, so malformed or unwritable imports
    /// cannot leave the app half-configured.
    func applyPortableSettings(_ imported: SettingsDocument.PortableSettings) throws {
        settingsMutationLock.lock()
        defer { settingsMutationLock.unlock() }
        settingsLock.lock()
        if let blockError = settingsWriteBlockError {
            settingsLock.unlock()
            throw blockError
        }
        let previous = settingsDocument
        let previousWriteBlockError = settingsWriteBlockError
        let previousData = (try? Data(contentsOf: settingsStorageURL))
            ?? (try? SettingsDocumentCodec.encode(previous))
        let recoveryURL = settingsStorageURL.deletingPathExtension()
            .appendingPathExtension("import-backup.json")
        var candidate = settingsDocument
        candidate.settings = imported
        do {
            if let previousData {
                try previousData.write(to: recoveryURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
            }
            try persistSettingsDocument(candidate)
            settingsDocument = candidate
            settingsWriteBlockError = nil
            settingsLock.unlock()
        } catch {
            settingsLock.unlock()
            try? FileManager.default.removeItem(at: recoveryURL)
            throw error
        }
        guard writeEngineConfig() else {
            settingsLock.lock()
            var rollbackFailed = false
            do {
                if let previousData {
                    try previousData.write(to: settingsStorageURL, options: .atomic)
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: settingsStorageURL.path)
                    writeSettingsBackup(previousData)
                } else {
                    try persistSettingsDocument(previous)
                }
                settingsDocument = previous
                settingsWriteBlockError = previousWriteBlockError
                try? FileManager.default.removeItem(at: recoveryURL)
            } catch {
                settingsWriteBlockError = .couldNotSave
                rollbackFailed = true
                NSLog("Velora: failed to roll back settings after engine projection failed: \(error)")
            }
            settingsLock.unlock()
            if rollbackFailed { throw SettingsDocumentError.rollbackFailed }
            _ = writeEngineConfig()
            throw SettingsDocumentError.engineProjectionFailed
        }
        try? FileManager.default.removeItem(at: recoveryURL)
    }

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
    /// keys (cleanup model, vocabulary, replacements, …) are preserved.
    /// The engine reads this at startup and on `reload_config`.
    @discardableResult
    func writeEngineConfig() -> Bool {
        return Self.updateEngineConfig(at: engineConfigStorageURL) { payload in
            payload["stt_model"] = self.sttModel
            payload["language"] = self.language
            payload["auto_punctuation"] = self.autoPunctuation
            payload["save_audio"] = self.saveAudio
            payload["romanize_output"] = self.romanizeOutput
            payload["vocab_mining"] = self.vocabMining
            payload["smart_terminal"] = self.smartTerminal
            payload["meeting_diarization"] = self.meetingDiarization
            let engine = self.readSetting(\.engine)
            payload["cleanup_enabled"] = engine.cleanupEnabled
            payload["default_mode"] = engine.defaultMode
            payload["streaming_cleanup"] = engine.streamingCleanup
            payload["max_recording_s"] = engine.maximumRecordingSeconds
            payload["audio_retention_days"] = engine.audioRetentionDays
            payload["audio_max_mb"] = engine.audioMaximumMegabytes
        }
    }

    /// Writes config.json only if it does not exist yet (first launch).
    func writeEngineConfigIfMissing() {
        guard !FileManager.default.fileExists(atPath: engineConfigStorageURL.path) else { return }
        writeEngineConfig()
    }

    private static func updateEngineConfig(
        at url: URL,
        _ mutation: (inout [String: Any]) -> Void
    ) -> Bool {
        engineConfigLock.lock()
        defer { engineConfigLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("Velora: failed to create config directory: \(error)")
            return false
        }

        // The Python engine uses this same advisory lock. Holding it across the
        // full read/mutate/write prevents two otherwise-atomic renames from
        // losing whichever process wrote first.
        let lockURL = url.appendingPathExtension("lock")
        let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            NSLog("Velora: failed to open config.json.lock")
            return false
        }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            NSLog("Velora: failed to lock config.json.lock")
            return false
        }
        defer { _ = flock(lockFD, LOCK_UN) }

        var payload: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                NSLog("Velora: refusing to overwrite unreadable config.json")
                return false
            }
            payload = existing
        }
        mutation(&payload)
        do {
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
