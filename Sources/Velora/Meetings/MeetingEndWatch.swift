import Foundation

/// Why a meeting recording ended, persisted on the meeting row (and in the
/// resume sidecar) so a recovered or finished meeting can say how it closed
/// instead of every ending looking identical.
enum MeetingEndReason: String, Codable, Equatable {
    /// The user pressed Stop / confirmed the ending. Always immediate:
    /// it never waits for an end-detection hold.
    case user
    /// The bound call released its microphone / presence (auto-detection).
    case mic
    /// The calendar event backing the meeting ended.
    case calendar
    /// A configured maximum recording duration was reached.
    case durationCap
    /// The app is quitting and finalized the recording on the way out.
    case appTermination
    /// Capture failed (microphone/system error) and could not continue.
    case error
}

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

    /// Stable identity of the bound call, for call-switch reconciliation:
    /// presence carrying a different key is a *different* call, not this
    /// call going quiet.
    var callKey: String? {
        switch self {
        case .native(let name): return "native:\(name)"
        case .browser(let bundle): return bundle.map { "browser:\($0)" }
        case .unknown: return nil
        }
    }

    static func callKey(for presence: MeetingPresence) -> String? {
        forChannel(presence.channel).callKey
    }
}

/// Pure poll-fed state machine deciding when a recording's meeting has ended.
/// It must see the call at least once (`confirmed`) so a manual recording
/// with no detectable call never fires, and it requires consecutive absent
/// polls so one flaky Accessibility read (minimized window, mid-rename title)
/// cannot stop a live recording.
struct MeetingEndWatch: Equatable {
    enum Event: Equatable { case none, ended }

    /// One poll's presence answer for the hold-aware API (`observe(presence:)`).
    /// `callID` is `MeetingWatchScope.callKey`; nil means "some call, identity
    /// unknown", which can sustain a watch but never proves a switch.
    enum PresenceObservation: Equatable {
        case present(callID: String?)
        case absent
        case differentCall(callID: String?)
    }

    /// What a hold-aware observation decided.
    enum HoldEvent: Equatable {
        case none
        /// Absence streak started/continued but has not confirmed an end.
        case holding(absentPolls: Int, needed: Int)
        case ended
        /// Presence returned while holding; the pending end is cancelled.
        case holdCancelled
        /// A different call is now present; the hold is cancelled and the
        /// watch rebinds to the new call instead of ending the meeting.
        case callSwitched
    }

    /// Consecutive absent polls required to confirm an end through the
    /// hold-aware API when a call drops.
    static let defaultHoldThreshold = 3

    private(set) var confirmed = false
    private var absentPolls = 0
    private let threshold: Int
    private let holdThreshold: Int
    /// The call this watch is bound to, once any identified presence is seen.
    private(set) var boundCallID: String?

    /// `confirmed: true` seeds the watch for captures born from a
    /// title-confirmed call, so a call that dies before the first watch poll
    /// still produces an end event instead of arming forever.
    init(threshold: Int = 2, confirmed: Bool = false) {
        self.threshold = max(1, threshold)
        self.holdThreshold = max(1, threshold)
        self.confirmed = confirmed
    }

    /// Hold-aware seeding: `holdThreshold` consecutive absent polls (default
    /// `defaultHoldThreshold`) confirm an end through `observe(presence:)`.
    /// The legacy `observe(present:)` keeps using it as its threshold too,
    /// so both APIs agree on one armed watch.
    init(holdThreshold: Int, confirmed: Bool = false, boundCallID: String? = nil) {
        self.threshold = max(1, holdThreshold)
        self.holdThreshold = max(1, holdThreshold)
        self.confirmed = confirmed
        self.boundCallID = boundCallID
    }

    /// True while an absence streak is being held short of confirmation.
    var isHoldingEnd: Bool { confirmed && absentPolls > 0 }
    var absentPollCount: Int { absentPolls }

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

    /// Hold-aware observation. Absence first *holds* (the meeting is not
    /// ended yet); only `holdThreshold` consecutive absent polls confirm.
    /// The bound call returning cancels the hold (`.holdCancelled`), and a
    /// different identified call cancels and rebinds it (`.callSwitched`)
    /// rather than killing a live meeting that merely moved calls.
    mutating func observe(presence: PresenceObservation) -> HoldEvent {
        switch presence {
        case .present(let callID):
            if let callID, let boundCallID, callID != boundCallID {
                return rebind(to: callID)
            }
            if boundCallID == nil { boundCallID = callID }
            let wasHolding = isHoldingEnd
            confirmed = true
            absentPolls = 0
            return wasHolding ? .holdCancelled : .none
        case .differentCall(let callID):
            if let callID, callID == boundCallID {
                // Same call after all: plain presence.
                let wasHolding = isHoldingEnd
                confirmed = true
                absentPolls = 0
                return wasHolding ? .holdCancelled : .none
            }
            return rebind(to: callID)
        case .absent:
            guard confirmed else { return .none }
            absentPolls += 1
            guard absentPolls >= holdThreshold else {
                return .holding(absentPolls: absentPolls, needed: holdThreshold)
            }
            confirmed = false
            absentPolls = 0
            return .ended
        }
    }

    /// Drops any pending absence streak without ending or re-binding.
    mutating func cancelHold() {
        absentPolls = 0
    }

    /// A user-initiated stop always wins immediately: it never waits for a
    /// hold to resolve, and it leaves the watch disarmed.
    mutating func confirmUserStop() -> MeetingEndReason {
        confirmed = false
        absentPolls = 0
        return .user
    }

    private mutating func rebind(to callID: String?) -> HoldEvent {
        boundCallID = callID
        // The new call demonstrably exists, so the re-armed watch may end
        // when *it* drops; any streak against the old call is discarded.
        confirmed = true
        absentPolls = 0
        return .callSwitched
    }
}
