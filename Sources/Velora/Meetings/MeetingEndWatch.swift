import Foundation

/// Which call a watch is bound to. Presence from an unrelated source must
/// neither sustain the watch nor arm automatic stopping — a website grabbing
/// the mic mid-way through a manual recording is not "the meeting".
enum MeetingWatchScope: Equatable {
    case native(String)
    case browser(String?)
    case unknown

    static func forChannel(_ channel: MeetingChannel) -> MeetingWatchScope {
        switch channel {
        case .native(let name): return .native(name)
        case .browser(let bundle): return .browser(bundle)
        case .unknown: return .unknown
        }
    }

    /// Presence that counts for this watch. A manual recording has no known
    /// call, so mic activity elsewhere cannot be attributed to it — titles
    /// only, and those lead to the ask flow, never auto-stop.
    func matches(_ presence: MeetingPresence) -> Bool {
        switch self {
        case .native(let name):
            return presence.channel == .native(name)
        case .browser(let expectedBundle):
            guard case .browser(let currentBundle) = presence.channel else { return false }
            return expectedBundle == nil || currentBundle == nil || expectedBundle == currentBundle
        case .unknown:
            return !presence.micBacked
        }
    }

    /// Only an attributable call may arm automatic stopping.
    func mayLatchMicEvidence(_ presence: MeetingPresence) -> Bool {
        guard presence.micBacked, matches(presence) else { return false }
        if case .unknown = self { return false }
        return true
    }

    /// Only native clients expose microphone ownership precisely enough to
    /// stop without asking. Browser ownership is process-wide, not tab-wide.
    var mayAutoStop: Bool {
        if case .native = self { return true }
        return false
    }

    /// Native apps keep their window titles and their input stream through
    /// mutes and device switches — fast streak. Browser calls hide titles
    /// behind tabs and some web apps release the mic on mute; manual
    /// recordings have nothing attributable — both need the long streak.
    var endThreshold: Int {
        if case .native = self { return 2 }
        if case .browser = self { return 12 }
        return 4
    }
}

/// Pure poll-fed state machine deciding when a recording's meeting has ended.
/// It must see the call at least once (`confirmed`) so a manual recording
/// with no detectable call never fires, and it requires consecutive absent
/// polls so one flaky Accessibility read (minimized window, mid-rename title)
/// cannot stop a live recording.
struct MeetingEndWatch: Equatable {
    enum Event: Equatable { case none, ended }

    private(set) var confirmed = false
    private var absentPolls = 0
    private let threshold: Int

    /// `confirmed: true` seeds the watch for captures born from a
    /// title-confirmed call, so a call that dies before the first watch poll
    /// still produces an end event instead of arming forever.
    init(threshold: Int = 2, confirmed: Bool = false) {
        self.threshold = max(1, threshold)
        self.confirmed = confirmed
    }

    mutating func observe(present: Bool) -> Event {
        if present {
            confirmed = true
            absentPolls = 0
            return .none
        }
        guard confirmed else { return .none }
        absentPolls += 1
        guard absentPolls >= threshold else { return .none }
        // Dropping back to unconfirmed makes "Keep Recording" sticky: another
        // end event needs the call to demonstrably resume first.
        confirmed = false
        absentPolls = 0
        return .ended
    }
}
