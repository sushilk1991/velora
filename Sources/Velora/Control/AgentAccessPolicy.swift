import Foundation

extension Notification.Name {
    static let veloraAgentCapabilitiesChanged = Notification.Name("VeloraAgentCapabilitiesChanged")
}

/// Machine-local grants. Portable settings and imported recipes cannot grant access.
enum AgentCapability: String, CaseIterable, Identifiable {
    case history, meetings, vocabularyRead, vocabularyWrite, configuration
    case formatting, files, microphone, actions, delivery

    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: return "Read dictation history and statistics"
        case .meetings: return "Read and export meeting content"
        case .vocabularyRead: return "Read Personal Dictionary"
        case .vocabularyWrite: return "Change Personal Dictionary"
        case .configuration: return "Read and validate mode recipes"
        case .formatting: return "Reformat supplied text"
        case .files: return "Transcribe supplied files"
        case .microphone: return "Request microphone input"
        case .actions: return "Run actions and inspect app controls"
        case .delivery: return "Copy or paste the last dictation"
        }
    }

    var detail: String {
        switch self {
        case .history: return "Final transcripts and aggregate statistics; no recordings or screen context."
        case .meetings: return "Meeting titles, notes, transcript passages, and exports; no recording paths."
        case .vocabularyRead: return "Confirmed and learned names, phrases, and spelling rules."
        case .vocabularyWrite: return "Add or remove dictionary entries. Changes may sync through your iCloud Dictionary."
        case .configuration: return "Mode names and formatting strengths, plus validation and recipe scaffolds."
        case .formatting: return "Return formatted text to the requesting client without saving or pasting it."
        case .files: return "Only files explicitly supplied by the requester."
        case .microphone: return "Every recording still needs a visible Allow Once approval."
        case .actions: return "App control still uses Velora's target checks and explicit send intent."
        case .delivery: return "Pasting also requires an explicit current target app; blocked delivery copies instead."
        }
    }

    fileprivate var legacyDefault: Bool {
        switch self {
        case .history, .formatting, .files, .microphone: return true
        default: return false
        }
    }
}

final class AgentAccessPolicy {
    static let shared = AgentAccessPolicy()
    private let defaults: UserDefaults
    private let center: NotificationCenter

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    static func key(for capability: AgentCapability) -> String {
        "velora.agentCapability." + capability.rawValue
    }

    func allows(_ capability: AgentCapability) -> Bool {
        guard let value = defaults.object(forKey: Self.key(for: capability)) as? Bool else {
            return capability.legacyDefault
        }
        return value
    }

    func setAllowed(_ allowed: Bool, for capability: AgentCapability) {
        guard allows(capability) != allowed else { return }
        defaults.set(allowed, forKey: Self.key(for: capability))
        center.post(name: .veloraAgentCapabilitiesChanged,
                    object: allowed, userInfo: ["capability": capability.rawValue])
    }

    var enabledNames: [String] { AgentCapability.allCases.filter(allows).map(\.rawValue) }

    static func required(for command: String) -> [AgentCapability] {
        switch command {
        case "recent", "search", "stats": return [.history]
        case "transcribe": return [.files]
        case "listen": return [.microphone]
        case "action", "ax_probe": return [.actions]
        case "format_text": return [.formatting]
        case "modes_list", "modes_validate", "modes_init": return [.configuration]
        case "vocabulary_list": return [.vocabularyRead]
        case "vocabulary_add", "vocabulary_remove": return [.vocabularyWrite]
        case "meetings_list", "meetings_search", "meetings_show", "meetings_export": return [.meetings]
        case "paste_last": return [.history, .delivery]
        default: return []
        }
    }
}
