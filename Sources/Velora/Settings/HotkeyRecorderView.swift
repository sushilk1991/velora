import AppKit
import SwiftUI

/// Click-to-record shortcut field (Settings › Shortcuts + onboarding hotkey
/// step), drawn in the existing keycap design language.
///
/// Flow: click → "Press your shortcut…" → the next keyDown is captured with
/// its modifiers. Releasing a bare modifier without pressing a key records
/// the modifier itself (Right ⌥ / Fn / Globe stay recordable). Esc cancels.
/// While capturing, a local `NSEvent` monitor consumes the events and the
/// global `HotkeyMonitor` suspends matching (via
/// `.veloraHotkeyRecordingActive`) so the capture can't trigger dictation.
struct HotkeyRecorderView: View {
    @Binding var hotkey: Hotkey
    /// Show the curated quick-pick buttons under the recorder field.
    var showsQuickPicks = true

    @State private var isRecording = false
    @State private var monitor: Any?
    /// Set when a modifier goes down during capture; consumed when all
    /// modifiers are released without a keyDown (records the bare modifier).
    @State private var candidateModifierKeyCode: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
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
            Text(isRecording ? "Press your shortcut…" : hotkey.displayLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                .frame(minWidth: 150)
                .padding(.horizontal, VeloraSpacing.l)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isRecording ? "Recording shortcut; press keys now" : "Change shortcut")
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
                .foregroundStyle(Color(nsColor: .systemOrange))
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

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            let keyCode = Int64(event.keyCode)
            let modifiers = Hotkey.cgFlags(from: event.modifierFlags) & Hotkey.strictModifierMask
            // Esc (unmodified) cancels the capture — it stays the dictation
            // cancel key and can never be a hotkey itself.
            if keyCode == 53, modifiers == 0 {
                endRecording(reason: "Esc")
                return
            }
            apply(
                Hotkey(keyCode: keyCode, modifiers: modifiers, isModifierOnly: false),
                source: "captured combo")
            endRecording(reason: "captured")

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
