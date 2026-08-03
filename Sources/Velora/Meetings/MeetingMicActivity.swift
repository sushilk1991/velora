import CoreAudio
import Foundation

/// Reads which bundle IDs are actively capturing microphone input right now,
/// straight from CoreAudio's process objects. Observing capture *state* needs
/// no TCC grant — no audio content is touched.
///
/// This is the load-bearing meeting signal: conferencing apps hold an input
/// stream for the entire call — mute included, windows and tabs hidden or
/// not — and release it the moment the call ends. Window titles only name
/// the meeting; the microphone decides whether one is happening.
enum MeetingMicActivity {
    /// nil means the probe itself failed (old macOS, HAL hiccup) — callers
    /// must treat that as "unknown", never as "nobody is on the mic". An
    /// absence verdict built on a failed probe could stop a live recording.
    static func bundleIDsCapturingMicrophone() -> Set<String>? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            system, &address, 0, nil, &size, &objects) == noErr else { return nil }

        // Velora itself holds the microphone while recording a meeting; its
        // own capture must never read as "a call is still running".
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var capturing: Set<String> = []
        for object in objects {
            guard uint32Property(object, kAudioProcessPropertyIsRunningInput) == 1,
                  pidProperty(object) != ownPID,
                  let bundle = stringProperty(object, kAudioProcessPropertyBundleID),
                  !bundle.isEmpty else { continue }
            capturing.insert(bundle)
        }
        return capturing
    }

    private static func uint32Property(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
