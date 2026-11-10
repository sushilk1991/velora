import Foundation

/// Machine-local meeting detection preferences. These never grant recording
/// consent, change Calendar authorization, or make weak call evidence stronger.
final class MeetingPolicy {
    enum EndBehavior: String, CaseIterable, Identifiable {
        case ask, confirmedNative, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: return "Ask before finishing"
            case .confirmedNative: return "Finish confirmed native calls"
            case .never: return "Keep recording until I stop"
            }
        }
    }

    static let leadKey = "velora.meeting.calendarLeadMinutes"
    static let endKey = "velora.meeting.endBehavior"
    static let shared = MeetingPolicy()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var calendarLeadMinutes: Int {
        get {
            guard defaults.object(forKey: Self.leadKey) != nil else { return 5 }
            return min(30, max(0, defaults.integer(forKey: Self.leadKey)))
        }
        set { defaults.set(min(30, max(0, newValue)), forKey: Self.leadKey) }
    }

    var endBehavior: EndBehavior {
        get { defaults.string(forKey: Self.endKey).flatMap(EndBehavior.init(rawValue:)) ?? .confirmedNative }
        set { defaults.set(newValue.rawValue, forKey: Self.endKey) }
    }

    static func automaticallyFinishes(
        behavior: EndBehavior, microphoneEvidence: Bool, scope: MeetingWatchScope
    ) -> Bool {
        behavior == .confirmedNative && microphoneEvidence && scope.mayAutoStop
    }
}
