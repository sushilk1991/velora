import CoreAudio
import AudioToolbox
import Foundation

/// Access is explicitly device-bound: a route change during recording must
/// never restore one device's volume onto another device.
protocol OutputVolumeControlling {
    func defaultDevice() -> AudioObjectID?
    func readVolume(device: AudioObjectID) -> Float?
    @discardableResult
    func writeVolume(_ scalar: Float, device: AudioObjectID) -> Bool
    func isMuted(device: AudioObjectID) -> Bool?
}

struct SystemOutputVolume: OutputVolumeControlling {
    func defaultDevice() -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    func readVolume(device: AudioObjectID) -> Float? {
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress()
        guard AudioHardwareServiceGetPropertyData(
            device, &address, 0, nil, &size, &scalar) == noErr,
              scalar.isFinite, (0...1).contains(scalar)
        else { return nil }
        return scalar
    }

    func writeVolume(_ scalar: Float, device: AudioObjectID) -> Bool {
        guard scalar.isFinite else { return false }
        var address = volumeAddress()
        var settable = DarwinBoolean(false)
        guard AudioHardwareServiceIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = Float32(max(0, min(1, scalar)))
        return AudioHardwareServiceSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    func isMuted(device: AudioObjectID) -> Bool? {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }
}

/// Opt-in, best-effort output ducking for foreground dictation only.
/// Muted/silent outputs and devices without a settable master volume are
/// left alone. Restore targets the original device and respects any volume
/// adjustment the user made while recording. Calls belong to the main queue.
final class OutputDuckingController {
    static let duckFraction: Float = 1.0 / 3.0

    private struct Lease {
        let device: AudioObjectID
        let original: Float
        let ducked: Float
    }

    private let volume: OutputVolumeControlling
    private var lease: Lease?
    var isDucked: Bool { lease != nil }

    init(volume: OutputVolumeControlling = SystemOutputVolume()) {
        self.volume = volume
    }

    func duckForDictation() {
        guard lease == nil, let device = volume.defaultDevice(),
              volume.isMuted(device: device) != true,
              let current = volume.readVolume(device: device),
              current.isFinite, current > 0, current <= 1 else { return }
        let ducked = current * Self.duckFraction
        guard volume.writeVolume(ducked, device: device) else { return }
        lease = Lease(device: device, original: current, ducked: ducked)
    }

    func restoreAfterDictation() { restore() }
    func restoreImmediatelyForTermination() { restore() }

    private func restore() {
        guard let previous = lease else { return }
        lease = nil
        // Do not undo a manual volume change, or act on a vanished device.
        guard let current = volume.readVolume(device: previous.device),
              abs(current - previous.ducked) < 0.005 else { return }
        volume.writeVolume(previous.original, device: previous.device)
    }
}
