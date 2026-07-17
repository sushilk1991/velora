import CoreAudio
import Foundation

extension Notification.Name {
    /// The set of connected audio input devices changed (posted on the main
    /// queue) — the Settings picker refreshes its list and a running capture
    /// re-checks whether the chosen mic is still the right one.
    static let veloraAudioInputDevicesChanged = Notification.Name("VeloraAudioInputDevicesChanged")
}

/// Core Audio enumeration of input-capable devices plus the pure resolver
/// that turns the persisted mic choice into a concrete device.
///
/// The persisted choice is a device UID (stable across reboots and
/// reconnects), never an AudioDeviceID (transient). A missing device resolves
/// to the system default WITHOUT clearing the persisted UID — unplugging the
/// chosen mic must not forget the choice; it wins again when it reappears.
enum AudioInputDevices {
    struct Device: Identifiable, Equatable {
        let uid: String
        let name: String
        let id: AudioDeviceID
    }

    /// Snapshot of currently connected devices that can capture audio
    /// (at least one input stream channel).
    static func current() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName)
            else { return nil }
            return Device(uid: uid, name: name, id: id)
        }
    }

    /// `current()` in a stable order for menus and pickers.
    static func displayList() -> [Device] {
        current().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Pure resolver: the device capture should bind to, or nil to follow the
    /// system default. nil/empty persisted UID → default; a persisted UID not
    /// in `devices` (temporarily unplugged) also → default, and the caller
    /// must keep the persisted value untouched so it wins on reconnect.
    static func resolve(persistedUID: String?, in devices: [Device]) -> AudioDeviceID? {
        guard let persistedUID, !persistedUID.isEmpty else { return nil }
        return devices.first(where: { $0.uid == persistedUID })?.id
    }

    /// Installs the hardware device-list listener once (idempotent). Core
    /// Audio delivers on the queue given here — main — so observers of the
    /// notification never need to hop threads themselves.
    static func beginObserving() { _ = installListenerOnce }

    private static let installListenerOnce: Void = {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            NotificationCenter.default.post(name: .veloraAudioInputDevicesChanged, object: nil)
        }
        if status != noErr {
            veloraLog("Velora: audio device-list listener failed to install (\(status))")
        }
    }()

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ id: AudioDeviceID, selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
