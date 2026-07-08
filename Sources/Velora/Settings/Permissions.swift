import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import IOKit.hid

/// TCC permission checks and System Settings deep links.
///
/// Velora needs three grants:
/// - **Microphone** — audio capture.
/// - **Input Monitoring** (`kIOHIDRequestTypeListenEvent`) — a *listen-only*
///   keyboard `CGEventTap`/`NSEvent` global monitor receives key events only
///   with this grant. Accessibility does **not** substitute for it on modern
///   macOS: without Input Monitoring the tap is created successfully but is
///   silently starved of events, so the hotkey looks dead in every mode while
///   the menubar (needing no permission) still works.
/// - **Accessibility** — posting the synthesized ⌘V that inserts text.
///
/// All are requested during onboarding, never at launch (design brief §4.2).
enum Permissions {
    // MARK: - Microphone

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// Triggers the system microphone prompt (or no-ops if already resolved).
    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Input Monitoring (keyboard event delivery)

    /// True when the process may listen to global key events. This is the
    /// grant the hotkey actually depends on.
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the system Input Monitoring prompt (adds Velora to the list
    /// and, on first ask, shows the grant dialog). Returns the immediate
    /// status; the user may still be mid-dialog, so callers should re-poll.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    // MARK: - Accessibility

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show the Accessibility prompt for this process.
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - System Settings deep links

    static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// True when any required permission is missing (drives the degraded
    /// menubar state + "Check Permissions…" item).
    static var anyMissing: Bool {
        !microphoneGranted || !inputMonitoringGranted || !accessibilityGranted
    }
}
