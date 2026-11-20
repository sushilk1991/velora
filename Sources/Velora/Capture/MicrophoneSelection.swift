import Foundation

/// Where a resolved microphone came from. Recorded once per take so "which
/// microphone did that take use, and why" is answerable from velora-app.log
/// instead of guessed at from a silent transcript.
enum MicSelectionStep: String, Equatable, CaseIterable {
    /// The device the user picked in Settings.
    case chosen
    /// macOS's current input device: follow the OS when nothing is chosen.
    case systemDefault
    /// The device that last delivered audio for a take.
    case lastUsed
    /// A microphone the user picked before, most recent first.
    case recentChoice
    /// The first connected input, when nothing above qualified.
    case firstConnected
    /// Every connected device was excluded, so the ordinary order won anyway.
    case exclusionOverridden

    var label: String {
        switch self {
        case .chosen: return "chosen"
        case .systemDefault: return "system default"
        case .lastUsed: return "last used"
        case .recentChoice: return "recent choice"
        case .firstConnected: return "first connected"
        case .exclusionOverridden: return "exclusion overridden"
        }
    }
}

struct MicrophoneResolution: Equatable {
    let uid: String
    let step: MicSelectionStep
}

/// What a capture session is actually recording from. Capture, the dead-input
/// rescue and the caller that logs a take's device all pass this around instead
/// of re-reading settings that may have moved on.
struct MicrophoneDevice: Equatable {
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

/// The one microphone-selection policy, as a pure function of what is saved
/// and what is plugged in.
///
/// The order is deliberate:
///
///     chosen (connected, not excluded)
///       → system default
///       → last used
///       → a microphone the user chose before, most recent first
///       → first connected
///
/// A chosen microphone that is unplugged must not clear the choice: it wins
/// again when it reappears, which is why "chosen" is skipped rather than
/// dropped when it is absent.
enum MicrophoneSelection {
    /// How many explicit choices are remembered for the recent-choice step.
    static let recentLimit = 5

    struct Ladder: Equatable {
        var chosenUID: String?
        var systemDefaultUID: String?
        var lastUsedUID: String?
        var recentUIDs: [String] = []
        var excludedUIDs: [String] = []
        var connectedUIDs: [String] = []

        init(
            chosenUID: String? = nil,
            systemDefaultUID: String? = nil,
            lastUsedUID: String? = nil,
            recentUIDs: [String] = [],
            excludedUIDs: [String] = [],
            connectedUIDs: [String] = []
        ) {
            // An empty UID is not a device identity: the picker's nil and a
            // persisted "" both mean "no choice", and Core Audio can report an
            // empty UID for a device that has none yet.
            self.chosenUID = chosenUID.flatMap(Self.identity)
            self.systemDefaultUID = systemDefaultUID.flatMap(Self.identity)
            self.lastUsedUID = lastUsedUID.flatMap(Self.identity)
            self.recentUIDs = recentUIDs.compactMap(Self.identity)
            self.excludedUIDs = excludedUIDs.compactMap(Self.identity)
            self.connectedUIDs = connectedUIDs.compactMap(Self.identity)
        }

        static func identity(_ uid: String) -> String? {
            let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var excluded: Set<String> { Set(excludedUIDs) }

        /// The connected, non-excluded device, or nil when this step cannot
        /// supply one.
        func usable(_ uid: String?) -> String? {
            guard let uid, connectedUIDs.contains(uid), !excluded.contains(uid) else {
                return nil
            }
            return uid
        }
    }

    /// The microphone to open, or nil when nothing is connected.
    ///
    /// Exclusion is a convenience for keeping a loopback or a dead webcam out
    /// of auto-selection, not a promise to record silence: when every
    /// connected device is excluded, the ordinary preference order wins and the
    /// caller can see why from the step.
    static func resolve(_ ladder: Ladder) -> MicrophoneResolution? {
        let connected = ladder.connectedUIDs
        guard !connected.isEmpty else { return nil }

        if let uid = ladder.usable(ladder.chosenUID) {
            return MicrophoneResolution(uid: uid, step: .chosen)
        }
        if let uid = ladder.usable(ladder.systemDefaultUID) {
            return MicrophoneResolution(uid: uid, step: .systemDefault)
        }
        if let uid = ladder.usable(ladder.lastUsedUID) {
            return MicrophoneResolution(uid: uid, step: .lastUsed)
        }
        if let uid = ladder.recentUIDs.lazy.compactMap({ ladder.usable($0) }).first {
            return MicrophoneResolution(uid: uid, step: .recentChoice)
        }
        if let uid = connected.first(where: { !ladder.excluded.contains($0) }) {
            return MicrophoneResolution(uid: uid, step: .firstConnected)
        }
        // Every connected microphone is excluded. Use the ordinary order and
        // let the log name the override rather than failing with "No
        // microphone available" and no explanation.
        for candidate in [ladder.chosenUID, ladder.systemDefaultUID, ladder.lastUsedUID]
            .compactMap({ $0 }) where connected.contains(candidate) {
            return MicrophoneResolution(uid: candidate, step: .exclusionOverridden)
        }
        return MicrophoneResolution(uid: connected[0], step: .exclusionOverridden)
    }

    /// The device that rescues a dead built-in input: the system default first,
    /// because that is the user's stated intent, then any other external
    /// microphone, then anything else that is connected and not excluded.
    static func alternate(
        to deadUID: String,
        devices: [AudioInputDevices.Device],
        systemDefaultUID: String?,
        excludedUIDs: [String]
    ) -> String? {
        let excluded = Set(excludedUIDs)
        let others = devices.filter {
            let uid = $0.uid.trimmingCharacters(in: .whitespacesAndNewlines)
            return !uid.isEmpty && uid != deadUID && !excluded.contains(uid)
        }
        if let systemDefaultUID,
           others.contains(where: { $0.uid == systemDefaultUID }) {
            return systemDefaultUID
        }
        if let external = others.first(where: { !$0.isBuiltIn }) {
            return external.uid
        }
        return others.first?.uid
    }
}

/// Transport codes, as the four-character values macOS actually reports.
///
/// `AVCaptureDevice.transportType` is an `Int32` four-character code from
/// IOAudioTypes.h, and Core Audio's `kAudioDevicePropertyTransportType` is the
/// `UInt32` form of the same code. Both are needed, so the codes live here once
/// instead of being compared through two different constant families.
enum AudioTransport {
    static let builtIn: UInt32 = fourCharacterCode("bltn")
    static let bluetooth: UInt32 = fourCharacterCode("blue")
    static let bluetoothLE: UInt32 = fourCharacterCode("blea")

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        value.unicodeScalars.reduce(0) { ($0 << 8) | UInt32($1.value) }
    }

    static func isBuiltIn(_ transport: Int32) -> Bool {
        UInt32(bitPattern: transport) == builtIn
    }

    static func isBluetooth(_ transport: Int32) -> Bool {
        let code = UInt32(bitPattern: transport)
        return code == bluetooth || code == bluetoothLE
    }

    static func isBuiltIn(_ transport: UInt32) -> Bool { transport == builtIn }

    static func isBluetooth(_ transport: UInt32) -> Bool {
        transport == bluetooth || transport == bluetoothLE
    }
}

/// Whether a queued input swap may touch the session it was requested for.
///
/// A swap is requested while a take is recording but runs later on the capture
/// lifecycle queue. By then the user may have stopped, or started a new take
/// whose session is the one on screen. Detaching before checking that would
/// kill the input of the take they are speaking into, so the check is a named
/// rule with its own test rather than an inline condition.
enum MicrophoneSwapPolicy {
    static func maySwap(
        requestedGeneration: UInt64,
        currentGeneration: UInt64,
        stopping: Bool
    ) -> Bool {
        requestedGeneration == currentGeneration && !stopping
    }
}

/// How long a route may still be moving before it is safe to bind.
///
/// Opening a Bluetooth headset microphone makes macOS move that headset from
/// its high-quality output route to a lower-bandwidth two-way route. That takes
/// hundreds of milliseconds, and a capture session created during the switch
/// binds to whatever the system reported a moment earlier: the built-in mic, or
/// a device that is about to disappear. The result is a take of the wrong room
/// or of digital silence.
///
/// The wait is conditional by design. A stable, wired, built-in or USB
/// microphone binds in the same call and pays nothing.
enum MicrophoneRouteSettle {
    /// How often the resolved device is re-read while a route settles.
    static let pollInterval: TimeInterval = 0.150
    /// The longest a start may be held for a settling route.
    static let deadline: TimeInterval = 1.200
    /// How long the resolved device must stay unchanged before binding.
    static let stableWindow: TimeInterval = 0.300
    /// A device-list change within this window counts as a route in motion.
    static let routeChangeWindow: TimeInterval = 2.000

    struct Plan: Equatable {
        var pollInterval: TimeInterval
        var deadline: TimeInterval
        var stableWindow: TimeInterval

        /// Bind now: the route is not moving, so waiting would add latency for
        /// nothing.
        static let immediate = Plan(
            pollInterval: 0, deadline: 0, stableWindow: 0)

        var waits: Bool { deadline > 0 }
    }

    /// Wait only when the transport is Bluetooth or the device list changed
    /// moments ago.
    static func plan(
        isBluetooth: Bool,
        deviceListChangedAt: TimeInterval?,
        now: TimeInterval,
        routeChangeWindow: TimeInterval = routeChangeWindow
    ) -> Plan {
        let movedRecently = deviceListChangedAt.map { changedAt in
            let age = now - changedAt
            return age >= 0 && age < routeChangeWindow
        } ?? false
        guard isBluetooth || movedRecently else { return .immediate }
        return Plan(
            pollInterval: pollInterval, deadline: deadline,
            stableWindow: stableWindow)
    }
}

/// Decides when a settling route has stopped moving. Pure and clock-injected so
/// the deadline and stability rules are testable without audio hardware.
struct MicrophoneRouteSettleState {
    enum Verdict: Equatable {
        case bind(String)
        case keepWaiting
    }

    private let plan: MicrophoneRouteSettle.Plan
    private let startedAt: TimeInterval
    private var candidate: String
    private var candidateSince: TimeInterval

    init(plan: MicrophoneRouteSettle.Plan, firstUID: String, at now: TimeInterval) {
        self.plan = plan
        self.startedAt = now
        self.candidate = firstUID
        self.candidateSince = now
    }

    /// Feed the currently resolved device. The first observation of a plan that
    /// waits always waits one poll, so a Bluetooth route gets at least one
    /// chance to change; a plan that does not wait binds immediately.
    mutating func observe(_ uid: String, at now: TimeInterval) -> Verdict {
        guard plan.waits else { return .bind(uid) }
        if uid != candidate {
            candidate = uid
            candidateSince = now
        }
        let stable = now - candidateSince >= plan.stableWindow
        let expired = now - startedAt >= plan.deadline
        return stable || expired ? .bind(candidate) : .keepWaiting
    }
}
