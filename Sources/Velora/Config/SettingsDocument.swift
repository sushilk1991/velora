import Foundation

/// Stable, human-readable settings document stored at `~/.velora/settings.json`.
///
/// Every value in this file is safe and useful to move to another Mac.
/// Machine state and security-sensitive grants remain in the macOS preferences
/// domain and are never decoded from this document.
struct SettingsDocument: Codable, Equatable {
    static let formatIdentifier = "velora-settings"
    static let currentVersion = 1

    var format: String = formatIdentifier
    var version: Int = currentVersion
    var settings: PortableSettings

    static var defaults: SettingsDocument {
        SettingsDocument(settings: .defaults)
    }
}

extension SettingsDocument {
    struct PortableSettings: Codable, Equatable {
        var general: General
        var hud: HUD
        var dictation: Dictation
        var models: Models
        var engine: Engine
        var meetings: Meetings
        var shortcuts: Shortcuts
        var updates: Updates

        static let defaults = PortableSettings(
            general: .defaults,
            hud: .defaults,
            dictation: .defaults,
            models: .defaults,
            engine: .defaults,
            meetings: .defaults,
            shortcuts: .defaults,
            updates: .defaults)
    }

    struct General: Codable, Equatable {
        var appearance: String
        var soundsEnabled: Bool
        var soundVolume: Double

        static let defaults = General(
            appearance: "system", soundsEnabled: true, soundVolume: 40)
    }

    struct HUD: Codable, Equatable {
        var position: HUDPosition
        var customOrigin: NormalizedPoint?
        var customEdge: HUDEdge
        var alwaysVisible: Bool

        static let defaults = HUD(
            position: .bottomRight, customOrigin: nil,
            customEdge: .center, alwaysVisible: true)
    }

    struct Dictation: Codable, Equatable {
        var language: String
        var autoPunctuation: Bool
        var saveAudio: Bool
        var romanizeOutput: Bool
        var learnFromEdits: Bool
        var vocabularyMining: Bool
        var smartTerminal: Bool
        var voiceCommands: Bool
        var typingFallbackApps: [String]
        var typingWordsPerMinute: Int

        static let defaults = Dictation(
            language: "auto",
            autoPunctuation: true,
            saveAudio: true,
            romanizeOutput: false,
            learnFromEdits: true,
            vocabularyMining: true,
            smartTerminal: true,
            voiceCommands: true,
            typingFallbackApps: AppConfig.defaultTypingFallbackApps,
            typingWordsPerMinute: 40)
    }

    struct Models: Codable, Equatable {
        var speech: String

        static let defaults = Models(speech: STTModel.all[0].id)
    }

    /// User-tunable engine values that already lived in config.json even when
    /// no Settings control exposed them. Keeping them typed here makes the
    /// portable document complete without treating dictionary data as settings.
    struct Engine: Codable, Equatable {
        var cleanupEnabled: Bool
        var defaultMode: String
        var streamingCleanup: Bool
        var maximumRecordingSeconds: Double
        var audioRetentionDays: Double
        var audioMaximumMegabytes: Double

        static let defaults = Engine(
            cleanupEnabled: true,
            defaultMode: "Default",
            streamingCleanup: true,
            maximumRecordingSeconds: 300,
            audioRetentionDays: 180,
            audioMaximumMegabytes: 4096)
    }

    struct Meetings: Codable, Equatable {
        var suggestions: Bool
        var audioRetentionDays: Int
        var diarization: Bool

        static let defaults = Meetings(
            suggestions: true, audioRetentionDays: 30, diarization: true)
    }

    struct Shortcuts: Codable, Equatable {
        var dictation: Hotkey
        var editSelection: Hotkey
        var voiceEdit: Bool
        var behavior: HotkeyMode

        static let defaults = Shortcuts(
            dictation: .rightOption,
            editSelection: .optionShiftE,
            voiceEdit: true,
            behavior: .hold)
    }

    struct Updates: Codable, Equatable {
        var checkAutomatically: Bool
        var installAutomatically: Bool

        static let defaults = Updates(
            checkAutomatically: true, installAutomatically: false)
    }

    /// Machine-only preferences kept in UserDefaults, never SettingsDocument.
    struct MachineLocalSettings: Equatable {
        var onboardingComplete: Bool
        var settingsSidebarCollapsed: Bool
        var inputDeviceUid: String?
        var localAgentAccess: Bool
        var meetingCalendar: Bool
        var launchAtLogin: Bool
        var lastUpdateCheck: Double

        static let defaults = MachineLocalSettings(
            onboardingComplete: false,
            settingsSidebarCollapsed: false,
            inputDeviceUid: nil,
            localAgentAccess: false,
            meetingCalendar: false,
            launchAtLogin: false,
            lastUpdateCheck: 0)
    }

    struct NormalizedPoint: Codable, Equatable {
        var x: Double
        var y: Double
    }
}

enum SettingsDocumentError: Error, LocalizedError, Equatable {
    case invalidFile
    case unsupportedVersion(Int)
    case invalidValue(String)
    case couldNotSave
    case engineProjectionFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "This isn't a valid Velora settings file."
        case .unsupportedVersion(let version):
            return "This settings file uses version \(version), which this version of Velora can't import."
        case .invalidValue(let field):
            return "The settings file contains an invalid value for \(field)."
        case .couldNotSave:
            return "Velora couldn't save the imported settings on this Mac."
        case .engineProjectionFailed:
            return "Velora couldn't update the engine configuration, so your previous settings were restored."
        case .rollbackFailed:
            return "Velora couldn't update the engine configuration or restore settings.json. A recovery copy remains beside it as settings.import-backup.json."
        }
    }
}

enum SettingsDocumentCodec {
    static func decode(_ data: Data) throws -> SettingsDocument {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["format"] as? String == SettingsDocument.formatIdentifier,
              let version = root["version"] as? Int
        else { throw SettingsDocumentError.invalidFile }

        guard version <= SettingsDocument.currentVersion else {
            throw SettingsDocumentError.unsupportedVersion(version)
        }
        // Before incrementing currentVersion, add and invoke an explicit wire
        // migration here. Silently decoding an older shape as current is unsafe.
        guard version == SettingsDocument.currentVersion else {
            throw SettingsDocumentError.invalidFile
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document: SettingsDocument
        do {
            document = try decoder.decode(SettingsDocument.self, from: data)
        } catch {
            throw SettingsDocumentError.invalidFile
        }
        try validate(document)
        return document
    }

    static func encode(_ document: SettingsDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    static func validate(_ document: SettingsDocument) throws {
        guard document.format == SettingsDocument.formatIdentifier,
              document.version == SettingsDocument.currentVersion
        else { throw SettingsDocumentError.invalidFile }

        let value = document.settings
        guard ["system", "light", "dark"].contains(value.general.appearance) else {
            throw SettingsDocumentError.invalidValue("appearance")
        }
        guard value.general.soundVolume.isFinite,
              (0...100).contains(value.general.soundVolume) else {
            throw SettingsDocumentError.invalidValue("sound volume")
        }

        if let origin = value.hud.customOrigin {
            guard origin.x.isFinite, origin.y.isFinite,
                  (0...1).contains(origin.x), (0...1).contains(origin.y) else {
                throw SettingsDocumentError.invalidValue("custom HUD position")
            }
        }

        guard isPrintableNonempty(value.dictation.language, maximumLength: 32) else {
            throw SettingsDocumentError.invalidValue("dictation language")
        }
        guard (1...1_000).contains(value.dictation.typingWordsPerMinute) else {
            throw SettingsDocumentError.invalidValue("typing speed")
        }
        guard value.dictation.typingFallbackApps.count <= 256,
              value.dictation.typingFallbackApps.allSatisfy({
                  isPrintableNonempty($0, maximumLength: 512)
              }) else {
            throw SettingsDocumentError.invalidValue("typing fallback apps")
        }

        guard isPrintableNonempty(value.models.speech, maximumLength: 512) else {
            throw SettingsDocumentError.invalidValue("speech model")
        }
        guard isPrintableNonempty(value.engine.defaultMode, maximumLength: 128) else {
            throw SettingsDocumentError.invalidValue("default mode")
        }
        guard value.engine.maximumRecordingSeconds.isFinite,
              value.engine.maximumRecordingSeconds > 0,
              value.engine.maximumRecordingSeconds <= 86_400 else {
            throw SettingsDocumentError.invalidValue("maximum recording time")
        }
        guard value.engine.audioRetentionDays.isFinite,
              value.engine.audioRetentionDays > 0,
              value.engine.audioRetentionDays <= 36_500 else {
            throw SettingsDocumentError.invalidValue("audio retention")
        }
        guard value.engine.audioMaximumMegabytes.isFinite,
              value.engine.audioMaximumMegabytes >= 0,
              value.engine.audioMaximumMegabytes <= 1_048_576 else {
            throw SettingsDocumentError.invalidValue("audio storage cap")
        }

        guard (1...365).contains(value.meetings.audioRetentionDays) else {
            throw SettingsDocumentError.invalidValue("meeting audio retention")
        }
        guard value.shortcuts.dictation.isValidSettingsHotkey,
              value.shortcuts.editSelection.isValidSettingsHotkey else {
            throw SettingsDocumentError.invalidValue("keyboard shortcuts")
        }
        guard value.shortcuts.dictation != value.shortcuts.editSelection else {
            throw SettingsDocumentError.invalidValue("keyboard shortcuts")
        }
    }

    private static func isPrintableNonempty(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
