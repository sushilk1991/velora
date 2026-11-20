import Foundation
import IOKit

/// Whether the MacBook lid is shut.
///
/// A closed lid hardware-disconnects the built-in microphone, which then
/// delivers a steady stream of exact zeros: it looks like a running device that
/// is recording a silent room, and the take ends with no text and no
/// explanation. IOKit is the only public source for this state. It answers on
/// desktops too, where the lid is always open.
enum LidState {
    /// nil when IOKit does not answer. Callers must not act on a guess: an
    /// unknown lid is "do not switch the microphone".
    static func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let value = property.takeRetainedValue()
        guard let number = value as? NSNumber else { return nil }
        return number.boolValue
    }
}

/// Decides whether a dictation take is being recorded from a lid-closed
/// built-in microphone, and if so, which device to switch to for the rest of
/// that same take.
///
/// The sample-level test cannot separate the two cases that produce exact
/// zeros: a lid-closed built-in mic and a muted input are identical on the
/// wire. So the decision uses context the samples cannot carry, and it stays
/// conservative: an unknown lid, a non-built-in device, or a take with nothing
/// else to switch to all keep the input as it is.
enum DeadInputRescue {
    /// How much exact digital silence is long enough to conclude the input is
    /// dead rather than a pause before speech.
    static let silenceThreshold: TimeInterval = 1.0

    struct Evidence: Equatable {
        /// The resolved input is the Mac's own microphone array.
        var deviceIsBuiltIn: Bool
        /// IOKit says the lid is shut. Unknown (nil) is passed as false.
        var lidClosed: Bool
        /// Consecutive exact-zero seconds measured on the converted stream.
        var silentSeconds: TimeInterval
        /// A different connected microphone that is not excluded.
        var alternateUID: String?
        /// This take already switched once. Never switch twice: a second
        /// switch would drop audio the user can see being recorded.
        var alreadyAttempted: Bool
    }

    enum Decision: Equatable {
        case switchTo(uid: String)
        /// Keep the current input. The reason is logged once, so a take that
        /// recorded nothing says why no rescue happened.
        case keep(String)
    }

    static func decide(
        _ evidence: Evidence,
        threshold: TimeInterval = silenceThreshold
    ) -> Decision {
        if evidence.alreadyAttempted {
            return .keep("already switched once this take")
        }
        guard evidence.deviceIsBuiltIn else {
            return .keep("input is not the built-in microphone")
        }
        guard evidence.lidClosed else {
            return .keep("lid is open or unknown")
        }
        guard evidence.silentSeconds >= threshold else {
            return .keep("silence has not lasted long enough yet")
        }
        guard let uid = evidence.alternateUID, !uid.isEmpty else {
            return .keep("no other microphone is connected")
        }
        return .switchTo(uid: uid)
    }
}
