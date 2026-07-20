import AppKit
import CoreAudio
import Foundation

/// Pauses a supported music player while foreground dictation owns the mic,
/// then restores it after capture releases the mic.
///
/// macOS has no public API that exposes another app's Now Playing state. The
/// safe boundary here is deliberately narrower: Core Audio tells us whether a
/// dedicated player is producing output, and a media-key event asks that
/// player to pause. Velora only earns the right to resume after Core Audio
/// confirms that the exact process stopped producing output.
final class MediaPlaybackCoordinator {
    struct Snapshot {
        var processes: Set<AudioObjectID>
        var playing: Set<AudioObjectID>
        var allPlaying: Set<AudioObjectID>

        init(
            processes: Set<AudioObjectID>,
            playing: Set<AudioObjectID>,
            allPlaying: Set<AudioObjectID>? = nil
        ) {
            self.processes = processes
            self.playing = playing
            self.allPlaying = allPlaying ?? playing
        }
    }

    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private enum State {
        case idle
        case pausePending(before: Set<AudioObjectID>, restoreRequested: Bool)
        case paused(Set<AudioObjectID>)
        case restorePending(Set<AudioObjectID>)
    }

    /// Core Audio closes an idle player's output stream asynchronously.
    private static let pauseVerificationDelay: TimeInterval = 1.0
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
        case .pausePending, .paused:
            return
        case .idle:
            break
        }

        let current = snapshot()
        // A media key is global. If another supported player is open but
        // paused, macOS may target that app instead of the one producing
        // audio, turning the wrong player on. Only an unambiguous single
        // player earns a toggle.
        guard current.processes.count == 1,
              current.playing == current.processes,
              current.allPlaying == current.playing,
              postToggle()
        else { return }
        let before = current.playing
        NSLog("Velora: requested media pause for dictation")
        state = .pausePending(before: before, restoreRequested: false)
        schedule(Self.pauseVerificationDelay) { [weak self] in
            self?.verifyPause(before: before)
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
        case .idle, .restorePending:
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
            paused = before
                .subtracting(current.playing)
                .intersection(current.processes)
        case .paused(let value), .restorePending(let value):
            paused = value
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

    private func verifyPause(before: Set<AudioObjectID>) {
        guard case .pausePending(let pendingBefore, let restoreRequested) = state,
              pendingBefore == before
        else { return }

        let after = snapshot()
        // A vanished process quit; Velora must not relaunch or replace it.
        let pausedByVelora = before
            .subtracting(after.playing)
            .intersection(after.processes)
        guard !pausedByVelora.isEmpty else {
            NSLog("Velora: media pause was not observed; no resume will be sent")
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
        defer { state = .idle }

        let current = snapshot()
        // Never interrupt something the user resumed or another supported
        // player they started while dictating. Also refuse to revive a player
        // process that exited while the mic was open.
        guard current.allPlaying.isEmpty,
              !paused.intersection(current.processes).isEmpty
        else { return }
        if postToggle() { NSLog("Velora: restored media after dictation") }
    }
}

enum MediaPlaybackSystem {
    private static let supportedBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
    ]

    static func isSupportedPlayer(bundleID: String) -> Bool {
        supportedBundleIDs.contains(bundleID)
    }

    static func snapshot() -> MediaPlaybackCoordinator.Snapshot {
        var processes = Set<AudioObjectID>()
        var playing = Set<AudioObjectID>()
        var allPlaying = Set<AudioObjectID>()
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.sushil.velora"
        for process in processObjects() {
            let bundleID = stringProperty(process, kAudioProcessPropertyBundleID)
            let isPlaying = uint32Property(
                process, kAudioProcessPropertyIsRunningOutput) != 0
            if isPlaying, bundleID != ownBundleID { allPlaying.insert(process) }
            guard let bundleID, isSupportedPlayer(bundleID: bundleID) else { continue }
            processes.insert(process)
            if isPlaying { playing.insert(process) }
        }
        return .init(
            processes: processes, playing: playing, allPlaying: allPlaying)
    }

    /// Posts the hardware Play/Pause key rather than scripting a media app.
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
        guard let down = event(isDown: true), let up = event(isDown: false) else { return false }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
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
    ) -> UInt32 {
        var property = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
                  object, &property, 0, nil, &size, &value) == noErr
        else { return 0 }
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
