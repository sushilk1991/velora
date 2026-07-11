import AppKit
import Carbon.HIToolbox
import CoreGraphics

extension Notification.Name {
    /// Posted by the shortcut recorder with `object == true` while it is
    /// capturing a shortcut and `object == false` when it stops. The global
    /// `HotkeyMonitor` suspends matching in between so pressing the current
    /// hotkey inside the recorder re-records it instead of starting dictation.
    static let veloraHotkeyRecordingActive = Notification.Name("VeloraHotkeyRecordingActive")
}

/// A user-recorded dictation hotkey: either a bare modifier (Right ⌥, Fn, …)
/// that fires on `flagsChanged`, or a regular key plus a required modifier
/// set that fires on keyDown/keyUp. Both shapes have a clean release edge,
/// so hold-to-talk semantics work for every recordable hotkey.
struct Hotkey: Equatable {
    /// Virtual key code (`kVK_*`). For modifier-only hotkeys this is the
    /// modifier key's own code (e.g. 61 = Right Option), which distinguishes
    /// left/right variants that share a `CGEventFlags` bit.
    var keyCode: Int64

    /// Raw `CGEventFlags` bits. For key combos only the four
    /// device-independent modifiers (⌘⌥⇧⌃) are stored and matched — the
    /// Fn/numeric-pad bits are hardware dependent (arrow keys and F-keys set
    /// them on their own), so matching is superset-tolerant on those. For
    /// modifier-only hotkeys this holds the modifier's own mask (display use).
    var modifiers: UInt64

    /// True when the hotkey is a bare modifier (matched on `flagsChanged`).
    var isModifierOnly: Bool
}

// MARK: - Well-known values

extension Hotkey {
    /// Modifier bits that participate in combo matching (see `modifiers`).
    static let strictModifierMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue

    /// All modifier bits the recorder tracks (strict set + Fn/Globe).
    static let allModifierMask: UInt64 =
        strictModifierMask | CGEventFlags.maskSecondaryFn.rawValue

    static let rightOption = Hotkey(
        keyCode: 61, modifiers: CGEventFlags.maskAlternate.rawValue, isModifierOnly: true)
    static let fnGlobe = Hotkey(
        keyCode: 63, modifiers: CGEventFlags.maskSecondaryFn.rawValue, isModifierOnly: true)
    static let f19 = Hotkey(keyCode: 80, modifiers: 0, isModifierOnly: false)

    /// Curated one-click choices shown next to the recorder.
    static let quickPicks: [(name: String, hotkey: Hotkey)] = [
        ("Right Option", .rightOption),
        ("Fn / Globe", .fnGlobe),
        ("F19", .f19),
    ]
}

// MARK: - Display

extension Hotkey {
    /// Keycap-style label: "⌘⇧Space", "⌥ right", "F19", "fn".
    var displayLabel: String {
        if isModifierOnly {
            return Self.modifierOnlyLabel(for: keyCode)
        }
        var label = ""
        if modifiers & CGEventFlags.maskControl.rawValue != 0 { label += "⌃" }
        if modifiers & CGEventFlags.maskAlternate.rawValue != 0 { label += "⌥" }
        if modifiers & CGEventFlags.maskShift.rawValue != 0 { label += "⇧" }
        if modifiers & CGEventFlags.maskCommand.rawValue != 0 { label += "⌘" }
        return label + Self.keyName(for: keyCode)
    }

    /// Prose name used in instructions ("Hold Right Option and speak").
    var displayName: String {
        guard isModifierOnly else { return displayLabel }
        switch keyCode {
        case 54: return "Right Command"
        case 55: return "Command"
        case 56: return "Shift"
        case 60: return "Right Shift"
        case 58: return "Option"
        case 61: return "Right Option"
        case 59: return "Control"
        case 62: return "Right Control"
        case 63: return "Fn / Globe"
        default: return displayLabel
        }
    }

    private static func modifierOnlyLabel(for keyCode: Int64) -> String {
        switch keyCode {
        case 54: return "⌘ right"
        case 55: return "⌘ left"
        case 56: return "⇧ left"
        case 60: return "⇧ right"
        case 58: return "⌥ left"
        case 61: return "⌥ right"
        case 59: return "⌃ left"
        case 62: return "⌃ right"
        case 63: return "fn"
        default: return "key \(keyCode)"
        }
    }

    /// Human-readable name for a virtual key code: fixed table for named
    /// keys, current keyboard layout (UCKeyTranslate) for character keys.
    static func keyName(for keyCode: Int64) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let character = characterKeyName(for: keyCode) { return character }
        return "Key \(keyCode)"
    }

    /// Virtual key code that produces `character` in the active keyboard
    /// layout. Synthesized shortcuts must use this semantic mapping instead of
    /// attaching a Unicode payload: macOS 26 can drop modified CGEvents that
    /// carry text while positional ANSI key codes are wrong on layouts such as
    /// AZERTY and QWERTZ.
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let layoutData = currentKeyboardLayoutData() else { return nil }
        let target = String(character).uppercased()
        for keyCode in 0...127 where
            characterKeyName(for: Int64(keyCode), layoutData: layoutData) == target
        {
            return CGKeyCode(keyCode)
        }
        return nil
    }

    private static let specialKeyNames: [Int64: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤",
        117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]

    /// Translates a character-producing key code via the current keyboard
    /// layout (so "Z" is right on QWERTZ). Returns nil for non-character keys.
    private static func characterKeyName(for keyCode: Int64) -> String? {
        guard let layoutData = currentKeyboardLayoutData() else { return nil }
        return characterKeyName(for: keyCode, layoutData: layoutData)
    }

    private static func currentKeyboardLayoutData() -> Data? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(
                  source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
    }

    private static func characterKeyName(for keyCode: Int64, layoutData: Data) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(-50) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                UInt16(truncatingIfNeeded: keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .controlCharacters)
        return name.isEmpty ? nil : name.uppercased()
    }
}

// MARK: - Matching helpers

extension Hotkey {
    /// The `CGEventFlags` bit a given modifier key code toggles; nil when the
    /// key code is not a modifier key.
    static func modifierMask(forKeyCode keyCode: Int64) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    /// Converts `NSEvent` modifier flags to the equivalent raw `CGEventFlags`
    /// bits (used by the NSEvent monitor paths so both event sources match
    /// with the same arithmetic).
    static func cgFlags(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var raw: UInt64 = 0
        if flags.contains(.command) { raw |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.option) { raw |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.shift) { raw |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.control) { raw |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.function) { raw |= CGEventFlags.maskSecondaryFn.rawValue }
        return raw
    }
}

// MARK: - Validation

extension Hotkey {
    /// Inline warning for shortcuts that collide with common system behavior
    /// or plain typing. Warnings never block — the user may have remapped
    /// the system side — they just surface the conflict.
    var conflictWarning: String? {
        guard !isModifierOnly else { return nil }
        let strict = modifiers & Self.strictModifierMask
        let commandOnly = strict == CGEventFlags.maskCommand.rawValue
        if commandOnly {
            switch keyCode {
            case 49: return "⌘Space opens Spotlight — pick another combo or remap Spotlight."
            case 48: return "⌘Tab is the app switcher and can't be overridden reliably."
            case 12: return "⌘Q quits the frontmost app — a risky choice for push-to-talk."
            default: break
            }
        }
        if strict == 0, Self.isTypingKey(keyCode) {
            let name = Self.keyName(for: keyCode)
            return "Bare \(name) fires every time you type it — consider adding a modifier."
        }
        return nil
    }

    /// True for keys that produce text during normal typing (single
    /// characters plus Space/Return/Tab/Delete).
    private static func isTypingKey(_ keyCode: Int64) -> Bool {
        if [49, 36, 48, 51].contains(keyCode) { return true }
        guard specialKeyNames[keyCode] == nil else { return false }
        return keyName(for: keyCode).count == 1
    }
}

// MARK: - Persistence

extension Hotkey {
    /// Plist-safe dictionary for `UserDefaults`.
    var defaultsRepresentation: [String: Any] {
        [
            "keyCode": NSNumber(value: keyCode),
            "modifiers": NSNumber(value: modifiers),
            "isModifierOnly": isModifierOnly,
        ]
    }

    init?(defaultsRepresentation dict: [String: Any]) {
        guard let keyCode = (dict["keyCode"] as? NSNumber)?.int64Value,
              let modifiers = (dict["modifiers"] as? NSNumber)?.uint64Value,
              let isModifierOnly = dict["isModifierOnly"] as? Bool
        else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, isModifierOnly: isModifierOnly)
    }

    /// Migrates a stored P0 `HotkeyChoice` raw value (curated picker era)
    /// into the recorder format. Returns nil for unknown values.
    init?(legacyChoice rawValue: String) {
        switch rawValue {
        case "rightOption": self = .rightOption
        case "fn": self = .fnGlobe
        case "f13": self.init(keyCode: 105, modifiers: 0, isModifierOnly: false)
        case "f14": self.init(keyCode: 107, modifiers: 0, isModifierOnly: false)
        case "f15": self.init(keyCode: 113, modifiers: 0, isModifierOnly: false)
        case "f16": self.init(keyCode: 106, modifiers: 0, isModifierOnly: false)
        case "f17": self.init(keyCode: 64, modifiers: 0, isModifierOnly: false)
        case "f18": self.init(keyCode: 79, modifiers: 0, isModifierOnly: false)
        case "f19": self = .f19
        default: return nil
        }
    }
}
