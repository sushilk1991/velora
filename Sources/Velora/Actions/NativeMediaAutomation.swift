import AppKit
import ApplicationServices
import Foundation

protocol NativeMediaProvider: AnyObject {
    var bundleID: String { get }
    var states: [ActionMediaState] { get }
    func permission(
        _ state: ActionMediaState,
        target: ActionProcessIdentity,
        askUserIfNeeded: Bool
    ) -> OSStatus
    func send(
        _ state: ActionMediaState,
        target: ActionProcessIdentity,
        maySend: () -> Bool
    ) -> Bool
}

extension NativeMediaProvider {
    var states: [ActionMediaState] { [.play, .pause] }
}

enum NativeMediaPermission: Equatable {
    case allowed
    case needsConsent
    case denied
    case unavailable
}

/// Registry for exact app-native media adapters. Planner-visible tokens reveal
/// no provider mechanics and are consumed against their original PID binding.
final class NativeMediaAutomation {
    static let shared = NativeMediaAutomation(
        providers: [MusicAppleEventMediaProvider()])

    private static let pollMs = 200
    private static let pollAttempts = 15
    private static let maximumBindings = 64

    private struct Binding {
        let target: ActionProcessIdentity
        let process: CuaProcessIdentity
        let state: ActionMediaState
        let provider: any NativeMediaProvider
    }

    private let providers: [any NativeMediaProvider]
    private let bundleForPID: (Int) -> String?
    private let processIdentity: (Int) -> CuaProcessIdentity?
    private let read: () -> MediaPlaybackCoordinator.Snapshot
    private let sleep: (Int) -> Void
    private let musicPermission: (Bool) -> [OSStatus]
    private let lock = NSLock()
    private var bindings: [String: Binding] = [:]

    init(
        providers: [any NativeMediaProvider],
        bundleForPID: @escaping (Int) -> String? = { pid in
            NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
        },
        processIdentity: @escaping (Int) -> CuaProcessIdentity? = {
            CuaProcessIdentity.capture(pid: pid_t($0))
        },
        read: @escaping () -> MediaPlaybackCoordinator.Snapshot
            = MediaPlaybackSystem.snapshot,
        sleep: @escaping (Int) -> Void = { milliseconds in
            Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
        },
        musicPermission: @escaping (Bool) -> [OSStatus]
            = MusicAppleEvents.permissionStatuses
    ) {
        self.providers = providers
        self.bundleForPID = bundleForPID
        self.processIdentity = processIdentity
        self.read = read
        self.sleep = sleep
        self.musicPermission = musicPermission
    }

    func readMusicPermission(
        completion: @escaping (NativeMediaPermission) -> Void
    ) {
        determineMusicPermission(false, completion: completion)
    }

    /// This is the sole interactive Automation request. Settings calls it
    /// only after the user presses Allow; Action execution always probes with
    /// `askUserIfNeeded: false` and fails closed.
    func requestMusicPermission(
        completion: @escaping (NativeMediaPermission) -> Void
    ) {
        determineMusicPermission(true, completion: completion)
    }

    private func determineMusicPermission(
        _ askUserIfNeeded: Bool,
        completion: @escaping (NativeMediaPermission) -> Void
    ) {
        let permission = musicPermission
        DispatchQueue.global(qos: .userInitiated).async {
            let state = Self.permissionState(permission(askUserIfNeeded))
            DispatchQueue.main.async {
                completion(state)
            }
        }
    }

    func supports(_ target: ActionProcessIdentity) -> Bool {
        guard let process = processIdentity(target.pid),
              let provider = provider(for: target) else { return false }
        let supported = provider.states.contains {
            provider.permission(
                $0, target: target, askUserIfNeeded: false) == noErr
        }
        return supported && exactTarget(target, process: process)
    }

    func capabilities(
        for target: ActionProcessIdentity
    ) -> [ActionNativeCapability] {
        guard let process = processIdentity(target.pid),
              let provider = provider(for: target) else { return [] }
        let states = provider.states.filter {
            provider.permission(
                $0, target: target, askUserIfNeeded: false) == noErr
        }
        guard !states.isEmpty,
              exactTarget(target, process: process) else { return [] }

        lock.lock()
        defer { lock.unlock() }
        if bindings.count >= Self.maximumBindings {
            bindings.removeAll(keepingCapacity: true)
        }
        return states.map { state in
            let id = UUID().uuidString
            bindings[id] = Binding(
                target: target, process: process,
                state: state, provider: provider)
            return ActionNativeCapability(
                id: id, verb: .mediaControl, state: state)
        }
    }

    func perform(
        _ control: ActionMediaControl,
        target: ActionProcessIdentity,
        maySend: () -> Bool
    ) -> ActionMediaControlResult {
        guard case .appNative(_, let id) = control.capability else {
            return .unavailable
        }
        lock.lock()
        let binding = bindings.removeValue(forKey: id)
        lock.unlock()
        guard let binding,
              binding.target == target,
              binding.state == control.state,
              exactTarget(target, process: binding.process),
              binding.provider.permission(
                control.state, target: target,
                askUserIfNeeded: false) == noErr,
              exactTarget(target, process: binding.process)
        else { return .unavailable }

        let before = read()
        guard exactTarget(target, process: binding.process) else {
            return .unavailable
        }
        let prior = mediaMatches(
            control.state, target: target, snapshot: before)
        if prior == true { return .verified }
        if control.state == .pause, prior == nil { return .unavailable }
        guard maySend(), exactTarget(target, process: binding.process),
              binding.provider.send(
                control.state, target: target, maySend: {
                    maySend()
                        && self.exactTarget(
                            target, process: binding.process)
                }),
              exactTarget(target, process: binding.process)
        else { return .unavailable }

        for _ in 0..<Self.pollAttempts {
            sleep(Self.pollMs)
            guard exactTarget(target, process: binding.process) else {
                return .misdirected
            }
            let after = read()
            guard exactTarget(target, process: binding.process) else {
                return .misdirected
            }
            if mediaMatches(
                control.state, target: target, snapshot: after) == true {
                return .verified
            }
        }
        return .misdirected
    }

    private func provider(
        for target: ActionProcessIdentity
    ) -> (any NativeMediaProvider)? {
        guard exactBundle(for: target) else { return nil }
        let matches = providers.filter {
            $0.bundleID.caseInsensitiveCompare(target.bundleID) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func exactBundle(for target: ActionProcessIdentity) -> Bool {
        guard target.pid > 0, !target.name.isEmpty, !target.bundleID.isEmpty,
              let live = bundleForPID(target.pid) else { return false }
        return live.caseInsensitiveCompare(target.bundleID) == .orderedSame
    }

    private func exactTarget(
        _ target: ActionProcessIdentity,
        process: CuaProcessIdentity
    ) -> Bool {
        exactBundle(for: target)
            && processIdentity(target.pid) == process
    }

    private func mediaMatches(
        _ requested: ActionMediaState,
        target: ActionProcessIdentity,
        snapshot: MediaPlaybackCoordinator.Snapshot
    ) -> Bool? {
        guard snapshot.isComplete else { return nil }
        let processes = snapshot.processes.filter {
            snapshot.pids[$0] == target.pid
                && snapshot.bundleIDs[$0]?.caseInsensitiveCompare(
                    target.bundleID) == .orderedSame
        }
        guard !processes.isEmpty else { return nil }
        let isPlaying = !processes.isDisjoint(with: snapshot.allPlaying)
        return requested == .play ? isPlaying : !isPlaying
    }

    private static func permissionState(
        _ statuses: [OSStatus]
    ) -> NativeMediaPermission {
        guard !statuses.isEmpty else { return .unavailable }
        if statuses.allSatisfy({ $0 == noErr }) { return .allowed }
        if statuses.contains(OSStatus(errAEEventWouldRequireUserConsent)) {
            return .needsConsent
        }
        if statuses.contains(OSStatus(errAEEventNotPermitted)) {
            return .denied
        }
        return .unavailable
    }
}

private enum MusicAppleEvents {
    static let bundleID = "com.apple.Music"
    static let suite: AEEventClass = 0x686F_6F6B // 'hook'
    static let play: AEEventID = 0x506C_6179 // 'Play'
    static let pause: AEEventID = 0x5061_7573 // 'Paus'

    static func eventID(_ state: ActionMediaState) -> AEEventID {
        state == .play ? play : pause
    }

    static func permissionStatuses(_ askUserIfNeeded: Bool) -> [OSStatus] {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return [ActionMediaState.play, .pause].map { state in
            AEDeterminePermissionToAutomateTarget(
                target.aeDesc, suite, eventID(state), askUserIfNeeded)
        }
    }
}

/// Music's official playback suite: `hook/Play` and `hook/Paus` from its SDEF.
/// The event targets the exact PID and forbids UI interaction or layer switches.
private final class MusicAppleEventMediaProvider: NativeMediaProvider {
    private static let timeout: TimeInterval = 2

    let bundleID = MusicAppleEvents.bundleID

    func permission(
        _ state: ActionMediaState,
        target: ActionProcessIdentity,
        askUserIfNeeded: Bool
    ) -> OSStatus {
        guard target.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
              let app = NSRunningApplication(
                processIdentifier: pid_t(target.pid)),
              app.bundleIdentifier?.caseInsensitiveCompare(bundleID)
                == .orderedSame else { return OSStatus(paramErr) }
        let descriptor = NSAppleEventDescriptor(
            processIdentifier: pid_t(target.pid))
        return AEDeterminePermissionToAutomateTarget(
            descriptor.aeDesc, MusicAppleEvents.suite,
            MusicAppleEvents.eventID(state), askUserIfNeeded)
    }

    func send(
        _ state: ActionMediaState,
        target: ActionProcessIdentity,
        maySend: () -> Bool
    ) -> Bool {
        guard target.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
              let app = NSRunningApplication(
                processIdentifier: pid_t(target.pid)),
              app.bundleIdentifier?.caseInsensitiveCompare(bundleID)
                == .orderedSame,
              maySend() else { return false }
        guard permission(
            state, target: target,
            askUserIfNeeded: false) == noErr, maySend() else { return false }
        let targetDescriptor = NSAppleEventDescriptor(
            processIdentifier: pid_t(target.pid))
        let event = NSAppleEventDescriptor(
            eventClass: MusicAppleEvents.suite,
            eventID: MusicAppleEvents.eventID(state),
            targetDescriptor: targetDescriptor,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        guard maySend() else { return false }
        do {
            _ = try event.sendEvent(
                options: [.waitForReply, .neverInteract, .dontRecord],
                timeout: Self.timeout)
            return true
        } catch {
            return false
        }
    }
}
