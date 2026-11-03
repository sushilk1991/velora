import CoreAudio
import Foundation

/// Lowers the system output volume while foreground dictation records, then
/// restores it — for audio MediaPlaybackCoordinator can't pause (video, calls,
/// browsers). Opt-in, off by default; the pause-and-restore behavior for
/// Music/Spotify is independent and keeps applying.
///
/// The duck multiplies the current volume by 1/3 (quiet enough to hear
/// yourself speak, loud enough not to feel broken) and restores the exact
/// previous scalar on release. Muted or silent outputs are left alone: a
/// muted device has nothing to duck, and a user-set silence must not become
/// a restored blare. Only outputs the macOS volume slider controls (a
/// settable master volume) are ducked — HDMI/DP displays that route volume
/// to their own hardware fail the capability probe and are skipped. Ducking
/// is best-effort, never an error.
protocol OutputVolumeControlling {
    /// Current output volume scalar 0...1 of the default output device, or
    /// nil when it can't be read (no device, no hardware volume support).
    func readVolume() -> Float?
    /// Set the scalar; returns false when the device has no settable volume.
    @discardableResult
    func writeVolume(_ scalar: Float) -> Bool
    /// Whether the default output device is muted (or nil when unknown).
    func isMuted() -> Bool?
}

/// CoreAudio-backed volume control for the default output device's master
/// channel — the volume the macOS slider moves.
struct SystemOutputVolume: OutputVolumeControlling {
    private var defaultOutputDevice: AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return nil }
        return id
    }

    /// The device and element whose scalar is the system volume, when the
    /// output actually has one macOS can set.
    private var volumeAddress: (device: AudioObjectID, element: AudioObjectPropertyElement)? {
        guard let device = defaultOutputDevice else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return nil }
        return (device, address.mElement)
    }

    func readVolume() -> Float? {
        guard let device = defaultOutputDevice else { return nil }
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &scalar) == noErr
        else { return nil }
        return scalar
    }

    func writeVolume(_ scalar: Float) -> Bool {
        guard let device = defaultOutputDevice,
              volumeAddress != nil
        else { return false }
        var value = Float32(max(0, min(1, scalar)))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    func isMuted() -> Bool? {
        guard let device = defaultOutputDevice else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &muted) == noErr
        else { return nil }
        return muted != 0
    }
}

/// Ducked-volume lifecycle, mirrored on MediaPlaybackCoordinator's: duck at
/// capture start, restore at every release point (stop, cancel, failure,
/// termination). Idempotent in both directions, so overlapping session
/// lifecycles can never wedge the volume down or restore twice.
final class OutputDuckingController {
    /// Duck to this fraction of the current volume while recording.
    static let duckFraction: Float = 1.0 / 3.0

    private let volume: OutputVolumeControlling
    private var previousVolume: Float?

    /// True while a duck is active (exposed for tests and logging).
    var isDucked: Bool { previousVolume != nil }

    init(volume: OutputVolumeControlling = SystemOutputVolume()) {
        self.volume = volume
    }

    func duckForDictation() {
        guard previousVolume == nil else { return }  // already ducked
        // A muted or silent output has nothing to lower — and restoring
        // into "not muted" is a behavior change the user never asked for.
        if volume.isMuted() == true { return }
        guard let current = volume.readVolume(), current > 0 else { return }
        guard volume.writeVolume(current * Self.duckFraction) else { return }
        previousVolume = current
    }

    func restoreAfterDictation() {
        restore()
    }

    /// Termination path: restore synchronously and never leave a ducked
    /// volume behind; the remembered level is dropped either way.
    func restoreImmediatelyForTermination() {
        restore()
    }

    private func restore() {
        guard let previous = previousVolume else { return }
        previousVolume = nil
        volume.writeVolume(previous)
    }
}