import CoreAudio
import Foundation

/// What one dictation does to whatever else is playing.
enum PlaybackDecision: String, Equatable {
    /// Leave other audio alone.
    case none
    /// Duck the output volume, and put it back afterwards.
    case lower
    /// Pause one unambiguous dedicated player, and resume it afterwards.
    case pause
}

/// A decision and the reason for it. The reason is logged once per take, so a
/// take that ducked when the user expected a pause (or the reverse) can be
/// explained from velora-app.log instead of guessed at.
struct PlaybackPlan: Equatable {
    let decision: PlaybackDecision
    let reason: String

    static func none(_ reason: String) -> PlaybackPlan {
        PlaybackPlan(decision: .none, reason: reason)
    }
}

/// The table that decides between pausing, ducking, and doing nothing.
///
/// Two rules are load-bearing and both come from real failures:
///
/// - **Never pause when the headset is also the microphone.** Opening a
///   Bluetooth headset's microphone moves it onto its low-bandwidth two-way
///   route; pausing its audio does not help that, and the pause is what the
///   user hears as their podcast dying. Lowering the volume leaves the music
///   where it is.
/// - **Never duck and pause on the same take.** They are independent
///   primitives and both restore themselves, so running both leaves the volume
///   down or the player paused depending on which restore wins.
///
/// Everything else is the conservative policy the pause coordinator already
/// enforced: one dedicated player and nothing else producing audio, never a
/// browser or a call, and never when the state could not be read.
enum PlaybackPolicy {
    /// A mode that wants its own say. `keepPlaying` is the only value that can
    /// outrank the headset rule; `lower` and `pause` are preferences that still
    /// lose to it.
    enum Override: String, Equatable, CaseIterable {
        case keepPlaying
        case lower
        case pause
    }

    struct Evidence: Equatable {
        var override: Override? = nil
        var outputMuted = false
        /// Master volume 0...1, or nil when the output has no settable volume.
        var outputVolume: Float? = 1
        /// The microphone dictation will open is the default output device.
        var micIsOutputDevice = false
        /// The microphone and the output are both Bluetooth, even when they are
        /// not the same device object (one headset can appear as two).
        var micAndOutputBothBluetooth = false
        /// Processes producing audio that the global media key could target.
        var dedicatedPlayerCount = 0
        /// Processes producing audio that are not dedicated players: browsers,
        /// call clients, anything unknown.
        var otherAudioCount = 0
        /// Every non-dedicated producer is a browser or a call client.
        var onlyBrowserAudio = false
        /// The user's "quiet other audio" preference.
        var quietOtherAudio = false
        /// False when Core Audio could not be read; a pause is never requested
        /// on an incomplete picture.
        var snapshotComplete = true
    }

    static func decide(_ evidence: Evidence) -> PlaybackPlan {
        // 1. A mode that explicitly wants its audio untouched.
        if evidence.override == .keepPlaying {
            return .none("the mode keeps other audio playing")
        }

        // 2. Nothing to do when the output makes no sound.
        if evidence.outputMuted {
            return .none("the output is muted")
        }
        if let volume = evidence.outputVolume, volume <= 0 {
            return .none("the output volume is zero")
        }

        // 3. The headset that is also the microphone: lower, never pause.
        if evidence.micIsOutputDevice || evidence.micAndOutputBothBluetooth {
            return lowerPlan(evidence, "the dictation microphone is the playback device")
        }

        // 4. A mode preference, still subject to the rules above.
        if evidence.override == .lower {
            return lowerPlan(evidence, "the mode lowers other audio")
        }
        if evidence.override == .pause {
            return pausePlan(evidence, "the mode pauses other audio")
        }

        // 5. One unambiguous dedicated player: pause it, verified.
        if !evidence.snapshotComplete {
            return .none("the audio state could not be read")
        }
        if evidence.dedicatedPlayerCount == 1 && evidence.otherAudioCount == 0 {
            return PlaybackPlan(decision: .pause, reason: "one dedicated player is playing")
        }

        // 6. Browser and call audio is never touched: Core Audio cannot tell a
        //    playing tab from a paused one, and a call must keep its audio.
        if evidence.onlyBrowserAudio {
            return .none("only browser or call audio is playing")
        }
        if evidence.dedicatedPlayerCount > 1 {
            return .none("more than one player is playing")
        }

        // 7. Fallback: the user's preference.
        if evidence.quietOtherAudio {
            return lowerPlan(evidence, "quiet other audio is on")
        }
        return .none("nothing else is playing")
    }

    /// Lowering needs a device that will accept it; without one the honest
    /// answer is to do nothing rather than fall back to a pause.
    private static func lowerPlan(_ evidence: Evidence, _ reason: String) -> PlaybackPlan {
        guard evidence.outputVolume != nil else {
            return .none("\(reason), but the output has no settable volume")
        }
        return PlaybackPlan(decision: .lower, reason: reason)
    }

    private static func pausePlan(_ evidence: Evidence, _ reason: String) -> PlaybackPlan {
        guard evidence.snapshotComplete else {
            return .none("\(reason), but the audio state could not be read")
        }
        guard evidence.dedicatedPlayerCount == 1, evidence.otherAudioCount == 0 else {
            return .none("\(reason), but no single dedicated player is playing")
        }
        return PlaybackPlan(decision: .pause, reason: reason)
    }
}

/// Whether applying one lever must first release another.
///
/// The pause coordinator and the volume ducker each own their own obligation,
/// so without this rule a take could duck *and* pause; whichever restore ran
/// second would then win, leaving the other half applied.
enum PlaybackLevers {
    /// The lever to release before acquiring `wanted`, or nil when nothing is
    /// held, nothing is wanted, or the same lever stays.
    static func releaseBefore(
        _ wanted: PlaybackDecision, active: PlaybackDecision
    ) -> PlaybackDecision? {
        guard wanted != .none, active != .none, wanted != active else { return nil }
        return active
    }
}

/// Reads the outside world for `PlaybackPolicy`. The only part of this file
/// that talks to Core Audio, so the table above stays pure and testable.
enum PlaybackProbe {
    static func evidence(
        micUID: String?,
        override: PlaybackPolicy.Override? = nil,
        quietOtherAudio: Bool,
        volume: OutputVolumeControlling = SystemOutputVolume(),
        snapshot: MediaPlaybackCoordinator.Snapshot = MediaPlaybackSystem.snapshot(),
        inputDevices: [AudioInputDevices.Device] = AudioInputDevices.current(),
        transport: (AudioDeviceID) -> UInt32 = AudioInputDevices.transport
    ) -> PlaybackPolicy.Evidence {
        let outputID = volume.defaultDevice()
        let micDevice = micUID.flatMap { uid in
            inputDevices.first(where: { $0.uid == uid })
        }
        let outputTransport = outputID.map { transport($0) }
        let micIsOutput = micDevice.map { device in
            outputID.map { $0 == device.id } ?? false
        } ?? false
        let bothBluetooth = (outputTransport.map { AudioTransport.isBluetooth($0) } ?? false)
            && (micDevice?.isBluetooth ?? false)

        let dedicated = snapshot.playing.count
        let others = snapshot.allPlaying.subtracting(snapshot.playing).count
        let onlyBrowsers = !snapshot.allPlaying.isEmpty
            && snapshot.allPlaying.subtracting(snapshot.playing).allSatisfy { process in
                snapshot.bundleIDs[process].map(MediaPlaybackSystem.isBrowserPlaybackCandidate) == true
            }

        return PlaybackPolicy.Evidence(
            override: override,
            outputMuted: outputID.flatMap { volume.isMuted(device: $0) } ?? false,
            outputVolume: outputID.flatMap { volume.readVolume(device: $0) },
            micIsOutputDevice: micIsOutput,
            micAndOutputBothBluetooth: bothBluetooth,
            dedicatedPlayerCount: dedicated,
            otherAudioCount: others,
            onlyBrowserAudio: others > 0 ? onlyBrowsers : false,
            quietOtherAudio: quietOtherAudio,
            snapshotComplete: snapshot.isComplete)
    }
}

/// Applies at most one playback decision per take, and undoes exactly what it
/// applied.
///
/// The two primitives are independent and each restore is a no-op when it owes
/// nothing, which is what makes the unconditional restore below safe. The
/// acquisition side is the one that must never double up, so it releases an
/// opposing lever from a previous take first.
final class DictationPlayback {
    private let media: MediaPlaybackCoordinator
    private let ducking: OutputDuckingController
    private(set) var applied: PlaybackDecision = .none
    private(set) var lastPlan: PlaybackPlan?

    init(media: MediaPlaybackCoordinator, ducking: OutputDuckingController) {
        self.media = media
        self.ducking = ducking
    }

    func apply(_ plan: PlaybackPlan) {
        lastPlan = plan
        if let release = PlaybackLevers.releaseBefore(plan.decision, active: applied) {
            // A previous take's lever is still held. Release it before taking
            // the other one so ducking and pausing never run together.
            releaseLever(release)
        }
        switch plan.decision {
        case .none:
            break
        case .lower:
            ducking.duckForDictation()
            // The duck is best-effort: a device with no settable volume, or a
            // device that refused the write, leaves nothing to restore.
            applied = ducking.isDucked ? .lower : .none
        case .pause:
            media.pauseForDictation()
            applied = .pause
        }
        veloraLog("Velora: playback \(plan.decision.rawValue) — \(plan.reason)")
    }

    /// Normal end of a take. Both primitives are idempotent and only undo what
    /// they started, so both are called: a setting changed mid-take cannot
    /// wedge the volume down or leave a player paused.
    func restore() {
        media.restoreAfterDictation()
        ducking.restoreAfterDictation()
        applied = .none
    }

    /// Action Mode is about to change playback deliberately.
    func restoreBeforeAction() {
        media.restoreBeforeAction()
        ducking.restoreAfterDictation()
        applied = .none
    }

    func restoreForTermination() {
        media.restoreImmediatelyForTermination()
        ducking.restoreImmediatelyForTermination()
        applied = .none
    }

    private func releaseLever(_ lever: PlaybackDecision) {
        switch lever {
        case .pause: media.restoreAfterDictation()
        case .lower: ducking.restoreAfterDictation()
        case .none: break
        }
        applied = .none
    }
}
