import Foundation

/// What Velora does when the detected call disappears while a meeting
/// recording is still running.
enum MeetingEndAction: String, Codable, CaseIterable {
    case ask
    case stop
    case off
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
