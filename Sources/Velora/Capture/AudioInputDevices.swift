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

    /// Snapshot of currently connected devices that can capture audio (at least
    /// one input stream channel), minus the ones we hide from the picker.
    static func current() -> [Device] {
        inputDeviceIDs().compactMap { id in
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName),
                  !isHiddenDevice(id, name: name)
            else { return nil }
            return Device(uid: uid, name: name, id: id)
        }
    }

    /// Clears a persisted mic choice that points at a device we now hide (a
    /// private aggregate). Such a UID could have been selected before this
    /// filter existed; left in place it would be misread as a disconnected
    /// microphone on an engine configuration change and stop a meeting. A real
    /// but currently-unplugged mic is NOT in the connected set, so its choice
    /// is preserved and still wins on reconnect. Call once at startup.
    static func sanitizePersistedSelection() {
        guard let uid = AppConfig.shared.inputDeviceUID, !uid.isEmpty else { return }
        let pointsAtHidden = inputDeviceIDs().contains { id in
            guard stringProperty(id, selector: kAudioDevicePropertyDeviceUID) == uid else {
                return false
            }
            let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? ""
            return isHiddenDevice(id, name: name)
        }
        if pointsAtHidden {
            AppConfig.shared.inputDeviceUID = nil
            veloraLog("Velora: cleared a mic choice that pointed at a hidden private aggregate")
        }
    }

    /// Input-capable device IDs (at least one input stream channel), unfiltered.
    private static func inputDeviceIDs() -> [AudioDeviceID] {
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
        return ids.filter { inputChannelCount($0) > 0 }
    }

    /// Whether a device should be kept out of the picker: the HAL's private
    /// default-device aggregate (e.g. "CADefaultDeviceAggregate-43981-0"), an
    /// internal wrapper for the current system default that duplicates the
    /// "System Default" choice and shows a raw identifier instead of a real
    /// name. The private-aggregate flag is authoritative; the name check is a
    /// backstop for the exact generated form if the flag read ever fails.
    private static func isHiddenDevice(_ id: AudioDeviceID, name: String) -> Bool {
        isInternalDeviceName(name) || isPrivateAggregate(id)
    }

    /// True only for the HAL's generated private-aggregate name form
    /// (`CADefaultDeviceAggregate-<pid>-<n>`) or a blank name — narrow enough
    /// that no real device is caught. Pure and name-based so the selftest can
    /// pin it; the authoritative filter is `isPrivateAggregate`.
    static func isInternalDeviceName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.range(
            of: #"^CADefaultDeviceAggregate-\d+-\d+$"#, options: .regularExpression) != nil
    }

    /// True when the device is a PRIVATE aggregate — the kind Core Audio
    /// creates internally (default-device wrapper, process taps). User-created
    /// aggregates from Audio MIDI Setup are NOT private and stay visible.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: CFDictionary?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr,
              let composition = value as? [String: Any],
              let flag = composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber
        else { return false }
        return flag.boolValue
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
