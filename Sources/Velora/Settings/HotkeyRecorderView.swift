import AppKit
import SwiftUI

/// Click-to-record shortcut field (Settings › Shortcuts + onboarding hotkey
/// step), drawn in the existing keycap design language.
///
/// Flow: click → "Press your shortcut…" → the next keyDown is captured with
/// its modifiers. Releasing a bare modifier without pressing a key records
/// the modifier itself (Right ⌥ / Fn / Globe stay recordable). A bare Esc,
/// Return or keypad Enter cancels.
/// While capturing, a local `NSEvent` monitor consumes the events and the
/// global `HotkeyMonitor` suspends matching (via
/// `.veloraHotkeyRecordingActive`) so the capture can't trigger dictation.
struct HotkeyRecorderView: View {
    @Binding var hotkey: Hotkey
    /// Show the curated quick-pick buttons under the recorder field.
    var showsQuickPicks = true
    /// The feature this shortcut runs ("Stream Typing"). Names the field
    /// for VoiceOver where several recorders share one list.
    var feature: String?

    @State private var isRecording = false
    @State private var monitor: Any?
    /// Set when a modifier goes down during capture; consumed when all
    /// modifiers are released without a keyDown (records the bare modifier).
    @State private var candidateModifierKeyCode: Int64?

    var body: some View {
        VStack(alignment: .trailing, spacing: VeloraSpacing.s) {
            recorderField
            if showsQuickPicks {
                quickPicks
            }
            warningLabel
        }
        .onDisappear { endRecording(reason: "view dismissed") }
    }

    // MARK: - Recorder field (keycap style)

    private var recorderField: some View {
        Button {
            isRecording ? endRecording(reason: "clicked away") : beginRecording()
        } label: {
            Group {
                if isRecording {
                    Text("Press your shortcut…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    KeycapsLabel(hotkey: hotkey)
                }
            }
            .frame(minWidth: 130)
            .padding(.horizontal, VeloraSpacing.m)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                    .fill(isRecording
                          ? Color.accentColor.opacity(0.08)
                          : Color.primary.opacity(0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                    .strokeBorder(
                        isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Click, then press the new shortcut. A single key like Right ⌥ works too.")
        .accessibilityLabel(
            isRecording ? "Recording shortcut; press keys now" : changeLabel)
    }

    /// "Change Stream Typing shortcut", so Settings' recorders don't all
    /// read "Change shortcut".
    private var changeLabel: String {
        guard let feature else { return "Change shortcut" }
        return "Change \(feature) shortcut"
    }

    // MARK: - Quick picks

    private var quickPicks: some View {
        HStack(spacing: VeloraSpacing.s) {
            ForEach(Hotkey.quickPicks, id: \.name) { pick in
                Button(pick.name) {
                    endRecording(reason: "quick pick")
                    apply(pick.hotkey, source: "quick pick")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(hotkey == pick.hotkey ? Color.accentColor : nil)
            }
        }
    }

    // MARK: - Inline conflict warning

    @ViewBuilder private var warningLabel: some View {
        if !isRecording, let warning = hotkey.conflictWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(VeloraStatus.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Capture

    private func beginRecording() {
        guard monitor == nil else { return }
        isRecording = true
        candidateModifierKeyCode = nil
        NSLog("Velora: shortcut recorder capturing")
        NotificationCenter.default.post(name: .veloraHotkeyRecordingActive, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil  // consume while recording
        }
    }

    private func endRecording(reason: String) {
        guard isRecording || monitor != nil else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        candidateModifierKeyCode = nil
        NSLog("Velora: shortcut recorder stopped (%@)", reason)
        NotificationCenter.default.post(name: .veloraHotkeyRecordingActive, object: false)
    }

    /// What a keyDown does while the recorder is armed.
    enum CaptureOutcome: Equatable {
        case cancel
        case record(Hotkey)
    }

    /// kVK_Escape, kVK_Return and kVK_ANSI_KeypadEnter.
    private static let escapeKeyCode: Int64 = 53
    private static let returnKeyCode: Int64 = 36
    private static let keypadEnterKeyCode: Int64 = 76

    // Test seam: internal so Selftest can reach it.
    /// A bare Esc, Return or keypad Enter cancels: Esc stays the dictation
    /// cancel key, and a bare ↩ or ⌤ as a global shortcut would fire on
    /// every line break. Anything else, ⌘↩ included, is recorded.
    static func captureOutcome(keyCode: Int64, modifiers: UInt64) -> CaptureOutcome {
        let bare = modifiers == 0
        let cancelKeys = [escapeKeyCode, returnKeyCode, keypadEnterKeyCode]
        if bare, cancelKeys.contains(keyCode) {
            return .cancel
        }
        return .record(Hotkey(keyCode: keyCode, modifiers: modifiers, isModifierOnly: false))
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let keyCode = Int64(event.keyCode)
            let modifiers = Hotkey.cgFlags(from: event.modifierFlags) & Hotkey.strictModifierMask
            // The local monitor consumes the event either way, so a
            // cancelling Return never reaches the window's default button.
            switch Self.captureOutcome(keyCode: keyCode, modifiers: modifiers) {
            case .cancel:
                endRecording(reason: "cancel key")
            case .record(let captured):
                apply(captured, source: "captured combo")
                endRecording(reason: "captured")
            }

        case .flagsChanged:
            let keyCode = Int64(event.keyCode)
            let flagsNow = Hotkey.cgFlags(from: event.modifierFlags) & Hotkey.allModifierMask
            guard let mask = Hotkey.modifierMask(forKeyCode: keyCode) else { return }
            if flagsNow & mask.rawValue != 0 {
                // Modifier pressed: it becomes the bare-modifier candidate.
                candidateModifierKeyCode = keyCode
            } else if flagsNow == 0, candidateModifierKeyCode == keyCode {
                // All modifiers released with no key pressed in between:
                // record the bare modifier itself.
                apply(
                    Hotkey(keyCode: keyCode, modifiers: mask.rawValue, isModifierOnly: true),
                    source: "captured bare modifier")
                endRecording(reason: "captured")
            }

        default:
            break
        }
    }

    private func apply(_ new: Hotkey, source: String) {
        NSLog(
            "Velora: shortcut recorded %@ via %@ (keyCode=%lld modifiers=0x%llx modifierOnly=%@)",
            new.displayLabel, source, new.keyCode, new.modifiers,
            new.isModifierOnly ? "yes" : "no")
        hotkey = new
    }
}
