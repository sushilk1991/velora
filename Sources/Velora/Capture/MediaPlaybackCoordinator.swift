import AppKit
import CoreAudio
import Foundation

/// Pauses the one process producing system audio while foreground dictation
/// owns the mic, then restores it after capture releases the mic.
///
/// macOS has no public API that exposes another app's Now Playing state. The
/// safe boundary is therefore observable behavior: Core Audio identifies one
/// unambiguous media process and a media-key event asks the system Now Playing
/// target to pause. Dedicated players are verified by their output stopping.
/// Browsers keep their Core Audio stream alive for about 15 seconds after a
/// Media Session pauses, so Velora observes a short misdirection window and
/// then pairs the delivered pause with one guarded restore.
final class MediaPlaybackCoordinator {
    struct Snapshot {
        var processes: Set<AudioObjectID>
        var playing: Set<AudioObjectID>
        var allPlaying: Set<AudioObjectID>
        var inputProcesses: Set<AudioObjectID>
        var isComplete: Bool
        var bundleIDs: [AudioObjectID: String]

        init(
            processes: Set<AudioObjectID>,
            playing: Set<AudioObjectID>,
            allPlaying: Set<AudioObjectID>? = nil,
            inputProcesses: Set<AudioObjectID> = [],
            isComplete: Bool = true,
            bundleIDs: [AudioObjectID: String] = [:]
        ) {
            self.processes = processes
            self.playing = playing
            self.allPlaying = allPlaying ?? playing
            self.inputProcesses = inputProcesses
            self.isComplete = isComplete
            self.bundleIDs = bundleIDs
        }

        func allAreBrowsers(_ processIDs: Set<AudioObjectID>) -> Bool {
            !processIDs.isEmpty && processIDs.allSatisfy { processID in
                bundleIDs[processID].map(MediaPlaybackSystem.isBrowserPlaybackCandidate) == true
            }
        }

        func hasMatchingInput(for outputProcessIDs: Set<AudioObjectID>) -> Bool {
            inputProcesses.contains { inputID in
                guard let inputBundleID = bundleIDs[inputID] else { return false }
                return outputProcessIDs.contains { outputID in
                    guard let outputBundleID = bundleIDs[outputID] else { return false }
                    return MediaPlaybackSystem.sameMediaFamily(inputBundleID, outputBundleID)
                }
            }
        }
    }

    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private enum State {
        case idle
        case pausePending(before: Set<AudioObjectID>, restoreRequested: Bool)
        case paused(Set<AudioObjectID>)
        case restorePending(Set<AudioObjectID>)
        case resumePending(Set<AudioObjectID>)
    }

    /// Browsers can keep their output stream alive for several seconds after
    /// their media session pauses. Poll to a bounded deadline rather than
    /// mistaking that drain lag for a failed command after one sample.
    private static let pauseVerificationDelay: TimeInterval = 0.4
    private static let pauseVerificationInterval: TimeInterval = 0.4
    private static let pauseVerificationAttempts = 15
    /// Three follow-up samples catch a media key that woke another player,
    /// while keeping short browser dictations responsive.
    private static let browserAssumptionAttemptsRemaining = 12
    /// Let Bluetooth leave headset mode after the input engine stops before
    /// playback returns to the headphones.
    private static let restoreDelay: TimeInterval = 0.8

    private let snapshot: () -> Snapshot
    private let postToggle: () -> Bool
    private let schedule: Schedule
    private var state: State = .idle

    convenience init() {
        self.init(
            snapshot: MediaPlaybackSystem.snapshot,
            postToggle: MediaPlaybackSystem.postPlayPause,
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            })
    }

    init(
        snapshot: @escaping () -> Snapshot,
        postToggle: @escaping () -> Bool,
        schedule: @escaping Schedule
    ) {
        self.snapshot = snapshot
        self.postToggle = postToggle
        self.schedule = schedule
    }

    /// Call after dictation's preflight gates pass, before opening the mic.
    func pauseForDictation() {
        switch state {
        case .pausePending(let before, true):
            // A new dictation began before the prior short session's pause was
            // verified. Keep the same pause and transfer its eventual restore
            // obligation to the new capture.
            state = .pausePending(before: before, restoreRequested: false)
            return
        case .restorePending(let paused):
            // Cancel the old delayed resume. The scheduled closure checks the
            // state and becomes a no-op; the new capture keeps media paused.
            state = .paused(paused)
            return
        case .resumePending(let paused):
            // A new dictation cancels the outstanding resume verification. If
            // the original output already returned, start a fresh pause cycle;
            // otherwise retain the existing verified pause obligation.
            let current = snapshot()
            if current.isComplete, !paused.isDisjoint(with: current.playing) {
                state = .idle
                pauseForDictation()
            } else {
                let unexpected = current.playing.subtracting(paused)
                if current.isComplete, !unexpected.isEmpty, postToggle() {
                    NSLog("Velora: reverted a misdirected media resume")
                }
                state = .paused(paused)
            }
            return
        case .pausePending, .paused:
            return
        case .idle:
            break
        }

        let current = snapshot()
        // A media key is global. Only one eligible output process, with no
        // simultaneous call/system output, earns a toggle. Paused applications
        // are not counted: public macOS APIs do not expose their Now Playing
        // ownership, so the verification below is the authoritative guard.
        guard current.isComplete,
              current.playing.count == 1,
              current.allPlaying == current.playing,
              !current.hasMatchingInput(for: current.playing),
              postToggle()
        else { return }
        let before = current.playing
        NSLog("Velora: requested media pause for dictation")
        state = .pausePending(before: before, restoreRequested: false)
        schedule(Self.pauseVerificationDelay) { [weak self] in
            self?.verifyPause(before: before, attemptsRemaining: Self.pauseVerificationAttempts)
        }
    }

    /// Call whenever foreground capture ends: normal stop, cancel, startup
    /// failure, engine failure, or app termination. Safe to call repeatedly.
    func restoreAfterDictation() {
        switch state {
        case .pausePending(let before, _):
            state = .pausePending(before: before, restoreRequested: true)
        case .paused(let paused):
            scheduleRestore(paused)
        case .idle, .restorePending, .resumePending:
            break
        }
    }

    /// AppKit may terminate before delayed main-queue work executes. Once the
    /// microphone has been released, restore a verified pause synchronously so
    /// quitting Velora cannot strand the player's playback state.
    func restoreImmediatelyForTermination() {
        let paused: Set<AudioObjectID>
        switch state {
        case .pausePending(let before, _):
            let current = snapshot()
            let confirmed = before
                .subtracting(current.playing)
                .intersection(current.processes)
            let guardedBrowserPair = current.isComplete
                && current.allPlaying.isSubset(of: before)
                && current.allAreBrowsers(before)
            paused = confirmed.isEmpty && guardedBrowserPair ? before : confirmed
        case .paused(let value), .restorePending(let value):
            paused = value
        case .resumePending(let value):
            let current = snapshot()
            if current.isComplete, value.isDisjoint(with: current.playing),
               !current.playing.isEmpty, postToggle() {
                NSLog("Velora: reverted a misdirected media resume during termination")
            }
            state = .idle
            return
        case .idle:
            return
        }
        guard !paused.isEmpty else {
            state = .idle
            return
        }
        state = .restorePending(paused)
        restore(paused: paused)
    }

    private func verifyPause(before: Set<AudioObjectID>, attemptsRemaining: Int) {
        guard case .pausePending(let pendingBefore, let restoreRequested) = state,
              pendingBefore == before
        else { return }

        let after = snapshot()
        guard after.isComplete else {
            NSLog("Velora: media state became unreadable; no resume will be sent")
            state = .idle
            return
        }
        // A vanished process quit; Velora must not relaunch or replace it.
        let pausedByVelora = before
            .subtracting(after.playing)
            .intersection(after.processes)
        guard !pausedByVelora.isEmpty else {
            // A global media key can occasionally target a previously paused
            // application instead of the process Core Audio showed as active.
            // If that mistake made a different eligible process start while
            // the original kept playing, immediately send the matching toggle
            // to put the accidental target back. Never claim a resume right.
            let unexpectedlyStarted = after.playing.subtracting(before)
            if !unexpectedlyStarted.isEmpty, !before.isDisjoint(with: after.playing) {
                if postToggle() {
                    NSLog("Velora: media pause targeted another player; reverted the toggle")
                }
                // The first command demonstrably targeted the wrong Now
                // Playing owner. A retry would be another untargeted media
                // command and could restart that player, so fail closed.
                state = .idle
                return
            }
            if attemptsRemaining <= Self.browserAssumptionAttemptsRemaining,
               after.allAreBrowsers(before),
               before.isSubset(of: after.processes) {
                NSLog("Velora: browser media pause accepted after target-safety window")
                state = .paused(before)
                if restoreRequested { scheduleRestore(before) }
                return
            }
            if attemptsRemaining > 0 {
                schedule(Self.pauseVerificationInterval) { [weak self] in
                    self?.verifyPause(
                        before: before, attemptsRemaining: attemptsRemaining - 1)
                }
                return
            }
            NSLog("Velora: media pause was not observed before the deadline; no resume will be sent")
            state = .idle
            return
        }

        NSLog("Velora: media pause confirmed")
        state = .paused(pausedByVelora)
        if restoreRequested { scheduleRestore(pausedByVelora) }
    }

    private func scheduleRestore(_ paused: Set<AudioObjectID>) {
        state = .restorePending(paused)
        schedule(Self.restoreDelay) { [weak self] in
            self?.restore(paused: paused)
        }
    }

    private func restore(paused: Set<AudioObjectID>) {
        guard case .restorePending(let pending) = state, pending == paused else { return }

        let current = snapshot()
        // Never interrupt something the user resumed or another supported
        // player they started while dictating. Also refuse to revive a player
        // process that exited while the mic was open.
        let outputIsSafe = current.allPlaying.isEmpty
            || (current.allPlaying.isSubset(of: paused) && current.allAreBrowsers(paused))
        guard current.isComplete,
              outputIsSafe,
              !current.hasMatchingInput(for: paused),
              !paused.intersection(current.processes).isEmpty
        else {
            state = .idle
            return
        }
        guard postToggle() else {
            state = .idle
            return
        }
        NSLog("Velora: requested media restore after dictation")
        state = .resumePending(paused)
        schedule(Self.pauseVerificationDelay) { [weak self] in
            self?.verifyRestore(paused: paused)
        }
    }

    private func verifyRestore(paused: Set<AudioObjectID>) {
        guard case .resumePending(let pending) = state, pending == paused else { return }
        defer { state = .idle }
        let after = snapshot()
        guard after.isComplete else { return }
        if !paused.isDisjoint(with: after.playing) {
            NSLog("Velora: media restore confirmed")
            return
        }
        if !after.playing.isEmpty, postToggle() {
            NSLog("Velora: media restore targeted another player; reverted the toggle")
        } else {
            NSLog("Velora: media restore was not observed")
        }
    }
}

enum MediaPlaybackSystem {
    /// Dedicated communication clients are system audio, but not media. Direct
    /// dictation must not send them a play/pause command, and meeting capture
    /// never invokes this coordinator at all.
    private static let dedicatedPlayerBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
    ]
    static func isAutomaticPlaybackCandidate(bundleID: String) -> Bool {
        mediaFamily(bundleID) != nil
    }

    static func isBrowserPlaybackCandidate(_ bundleID: String) -> Bool {
        mediaFamily(bundleID)?.hasPrefix("browser.") == true
    }

    static func sameMediaFamily(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = mediaFamily(lhs), let right = mediaFamily(rhs) else { return false }
        return left == right
    }

    static func snapshot() -> MediaPlaybackCoordinator.Snapshot {
        var processes = Set<AudioObjectID>()
        var playing = Set<AudioObjectID>()
        var allPlaying = Set<AudioObjectID>()
        var inputProcesses = Set<AudioObjectID>()
        var bundleIDs: [AudioObjectID: String] = [:]
        var isComplete = true
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.sushil.velora"
        for process in processObjects() {
            let bundleID = stringProperty(process, kAudioProcessPropertyBundleID)
            guard let bundleID, bundleID != ownBundleID else { continue }
            guard let isRunningOutput = uint32Property(
                      process, kAudioProcessPropertyIsRunningOutput),
                  let isRunningInput = uint32Property(
                      process, kAudioProcessPropertyIsRunningInput)
            else {
                isComplete = false
                continue
            }
            processes.insert(process)
            bundleIDs[process] = bundleID
            if isRunningInput != 0 { inputProcesses.insert(process) }
            guard isRunningOutput != 0 else { continue }
            allPlaying.insert(process)
            if isAutomaticPlaybackCandidate(bundleID: bundleID) {
                playing.insert(process)
            }
        }
        return .init(
            processes: processes, playing: playing, allPlaying: allPlaying,
            inputProcesses: inputProcesses, isComplete: isComplete,
            bundleIDs: bundleIDs)
    }

    private static func mediaFamily(_ bundleID: String) -> String? {
        if dedicatedPlayerBundleIDs.contains(bundleID) { return bundleID }
        if bundleID.hasPrefix("com.apple.Safari") || bundleID.hasPrefix("com.apple.WebKit") {
            return "browser.safari"
        }
        if bundleID.hasPrefix("com.google.Chrome") { return "browser.chrome" }
        if bundleID.hasPrefix("com.microsoft.edgemac") { return "browser.edge" }
        if bundleID.hasPrefix("company.thebrowser.Browser") { return "browser.arc" }
        if bundleID.hasPrefix("org.mozilla.firefox") { return "browser.firefox" }
        return nil
    }

    /// Posts a hardware-faithful Play/Pause key rather than scripting a media app.
    /// This uses Velora's existing Accessibility grant and avoids a separate
    /// Automation permission prompt for Music or Spotify.
    static func postPlayPause() -> Bool {
        guard TextInserter.canPostEvents else { return false }
        func event(isDown: Bool) -> CGEvent? {
            let keyFlags = isDown ? 0xA00 : 0xB00
            return NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: (Int(NX_KEYTYPE_PLAY) << 16) | keyFlags,
                data2: -1
            )?.cgEvent
        }
        guard let down = event(isDown: true) else { return false }
        down.post(tap: .cghidEventTap)
        // Chrome can discard an instantaneous down/up pair posted at the
        // session tap. A physical media key has a measurable hold interval.
        Thread.sleep(forTimeInterval: 0.02)
        guard let up = event(isDown: false) else { return false }
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func processObjects() -> [AudioObjectID] {
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(
                  system, &property, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var values = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
                  system, &property, 0, nil, &size, &values) == noErr
        else { return [] }
        return values
    }

    private static func uint32Property(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var property = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
                  object, &property, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var property = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
