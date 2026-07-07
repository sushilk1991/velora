import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// TCC permission checks and System Settings deep links.
/// Velora needs Microphone (capture) and Accessibility (hotkey event
/// delivery + posting ⌘V). Both are requested during onboarding, never at
/// launch (design brief §4.2).
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
        !microphoneGranted || !accessibilityGranted
    }
}
