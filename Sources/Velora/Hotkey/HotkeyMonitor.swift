import AppKit
import CoreGraphics
import Foundation

/// Receives raw hotkey transitions. Interpretation (hold-to-talk vs
/// tap-to-lock) lives in `DictationController`; this type only reports
/// clean down/up edges for the configured hotkey plus Esc presses.
/// All callbacks are on the main queue.
/// A hotkey other than the dictation one. Each role is an independent slot with
/// its own latch state; the dictation hotkey always wins a collision.
enum SecondaryHotkeyRole: String, CaseIterable {
    /// Safe Voice Edit: select text, hold, speak an instruction.
    case edit
    /// Action Mode: hold, speak a command, Velora carries it out.
    case action

    var label: String { rawValue }
}

protocol HotkeyMonitorDelegate: AnyObject {
    func hotkeyDown()
    func hotkeyUp()
    func secondaryHotkeyDown(_ role: SecondaryHotkeyRole)
    func secondaryHotkeyUp(_ role: SecondaryHotkeyRole)
    func escapePressed()
    /// A real user keystroke or click happened between dictations. Callers use
    /// this to discard any AX-opaque insertion boundary they had to remember.
    func nonHotkeyInput()
}

/// Monotonic guard for observed real clicks and key presses. The event-tap
/// callback increments before controller work is queued, so a delivery check
/// can fail closed even while its main-queue notification is still pending.
/// Exact target/selection validation remains the authoritative safety check.
enum UserInputActivity {
    private static let lock = NSLock()
    private static var value: UInt64 = 0

    static func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func mark() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }
}

/// Global hotkey listener for arbitrary recorded hotkeys (`Hotkey`).
///
/// Matching rules:
/// - Modifier-only hotkeys (Right ⌥, Fn, …) match `flagsChanged` events on
///   their own key code; down/up comes from the modifier's flag bit.
/// - Key combos match `keyDown` with the exact required ⌘⌥⇧⌃ set
///   (superset-tolerant on the device-dependent Fn/numeric-pad bits, which
///   arrow keys and F-keys raise on their own). The up edge is the key's
///   `keyUp` regardless of modifier state, so releasing a modifier a beat
///   early never strands a recording.
///
/// Primary path: a filtering `CGEventTap` (session tap) when Accessibility is
/// granted, so matched combo hotkeys never type into or invoke commands in the
/// target app. Without Accessibility it uses a listen-only tap, and falls back
/// to `NSEvent` global monitors when no tap can be created. Unsuppressible combo
/// shortcuts fail closed instead of triggering Velora while also reaching the
/// target app. Modifier-only hotkeys and Esc are never consumed.
final class HotkeyMonitor {
    weak var delegate: HotkeyMonitorDelegate?

    /// The hotkey being listened for; updated live from settings.
    var hotkey: Hotkey = AppConfig.shared.hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            modifierIsDown = false
            comboIsDown = false
            NSLog("Velora: hotkey monitor now listening for %@", hotkey.displayLabel)
        }
    }

    /// Optional extra hotkeys by role (Safe Voice Edit, Action Mode). A missing
    /// entry disables that role; a value equal to the dictation hotkey is
    /// ignored at match time so the main hotkey always wins.
    var secondaryHotkeys: [SecondaryHotkeyRole: Hotkey] = AppConfig.shared.activeSecondaryHotkeys {
        didSet {
            guard secondaryHotkeys != oldValue else { return }
            // Only clear the latches of roles that actually changed: rebinding
            // Action Mode must not strand an Edit hold that is in progress.
            for role in SecondaryHotkeyRole.allCases
            where secondaryHotkeys[role] != oldValue[role] {
                secondaryModifierIsDown[role] = false
                secondaryComboIsDown[role] = false
                NSLog("Velora: %@ hotkey now %@", role.label,
                      secondaryHotkeys[role].map(\.displayLabel) ?? "off")
            }
        }
    }

    /// Convenience for the Safe Voice Edit slot, which predates the role table.
    var editHotkey: Hotkey? {
        get { secondaryHotkeys[.edit] }
        set { secondaryHotkeys[.edit] = newValue }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var recorderObserver: NSObjectProtocol?
    private var modifierIsDown = false
    /// Tracks an active combo press so keyUp matches even after the user
    /// releases the modifiers first.
    private var comboIsDown = false
    private var secondaryModifierIsDown: [SecondaryHotkeyRole: Bool] = [:]
    private var secondaryComboIsDown: [SecondaryHotkeyRole: Bool] = [:]
    /// True only for a filtering tap whose callback may return nil to consume
    /// a matched combo key event.
    private var canSuppressComboEvents = false
    /// True while the settings/onboarding shortcut recorder is capturing;
    /// hotkey matching is suspended so the capture can't start dictation.
    private var suspended = false
    private(set) var usingEventTap = false

    private static let escKeyCode: Int64 = 53

    // MARK: - Lifecycle

    /// Installs the event tap (or the NSEvent fallback). Safe to call once.
    func start() {
        guard eventTap == nil, globalMonitor == nil else { return }
        if !startEventTap() {
            startGlobalMonitor()
        }
        if recorderObserver == nil {
            recorderObserver = NotificationCenter.default.addObserver(
                forName: .veloraHotkeyRecordingActive, object: nil, queue: .main
            ) { [weak self] note in
                guard let self else { return }
                self.suspended = (note.object as? Bool) ?? false
                NSLog(
                    "Velora: hotkey matching %@",
                    self.suspended ? "suspended (recorder capturing)" : "resumed")
            }
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let observer = recorderObserver {
            NotificationCenter.default.removeObserver(observer)
            recorderObserver = nil
        }
        canSuppressComboEvents = false
    }

    /// Tears down and reinstalls monitoring — call after a permission grant
    /// (an event tap created before the grant stays dead until reinstalled).
    func restart() {
        NSLog("Velora: hotkey monitor restarting")
        resetLatchedState()
        stop()
        start()
    }

    /// Resyncs cached modifier/combo latches to the ACTUAL live key state.
    /// Called when the tap is disabled then re-enabled (our own ⌘V paste
    /// triggers `.tapDisabledByUserInput`) and on restart.
    ///
    /// A blind reset to `false` wedges both ways: it fixes a stranded
    /// `modifierIsDown == true` (missed up-edge → hotkey dead), but if the
    /// modifier is *physically held* when the tap re-enables — e.g. the paste's
    /// tap-disable is delivered right after the user has begun holding the key
    /// for the NEXT dictation — forcing `false` desyncs the latch, so the
    /// eventual release sees "no change" and never emits `hotkeyUp`, stranding
    /// the recording (and the engine's `final` is then dropped downstream).
    /// Query the live modifier flags instead so the latch always matches reality.
    private func resetLatchedState(preservePhysicallyHeldCombos: Bool = false) {
        if hotkey.isModifierOnly, let mask = Hotkey.modifierMask(forKeyCode: hotkey.keyCode) {
            let live = CGEventSource.flagsState(.combinedSessionState)
            modifierIsDown = live.rawValue & mask.rawValue != 0
        } else {
            modifierIsDown = false
        }
        for role in SecondaryHotkeyRole.allCases {
            if let secondary = secondaryHotkeys[role], secondary.isModifierOnly,
               let mask = Hotkey.modifierMask(forKeyCode: secondary.keyCode) {
                let live = CGEventSource.flagsState(.combinedSessionState)
                secondaryModifierIsDown[role] = live.rawValue & mask.rawValue != 0
            } else {
                secondaryModifierIsDown[role] = false
            }
        }
        if preservePhysicallyHeldCombos {
            // A tap timeout can happen while a matched key is still held.
            // Preserve that latch until its real key-up so a modifier-release
            // autorepeat cannot leak a plain character into the selection.
            comboIsDown = Self.resyncedComboLatch(
                wasLatched: comboIsDown,
                keyCurrentlyDown: Self.keyState(hotkey.keyCode))
            for role in SecondaryHotkeyRole.allCases {
                secondaryComboIsDown[role] = Self.resyncedComboLatch(
                    wasLatched: secondaryComboIsDown[role] ?? false,
                    keyCurrentlyDown: secondaryHotkeys[role]
                        .map { Self.keyState($0.keyCode) } ?? false)
            }
        } else {
            comboIsDown = false
            for role in SecondaryHotkeyRole.allCases { secondaryComboIsDown[role] = false }
        }
    }

    static func resyncedComboLatch(
        wasLatched: Bool, keyCurrentlyDown: Bool
    ) -> Bool {
        wasLatched && keyCurrentlyDown
    }

    private static func keyState(_ keyCode: Int64) -> Bool {
        guard keyCode >= 0, keyCode <= Int64(CGKeyCode.max) else { return false }
        return CGEventSource.keyState(
            .combinedSessionState, key: CGKeyCode(keyCode))
    }

    // MARK: - CGEventTap path

    private func startEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        // C callback: cannot capture context; self travels via refcon.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let matchedCombo = monitor.handleTapEvent(type: type, event: event)
            if matchedCombo, monitor.canSuppressComboEvents {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        func makeTap(options: CGEventTapOptions) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        }

        var filtering = false
        var tap: CFMachPort?
        if Permissions.accessibilityGranted {
            tap = makeTap(options: .defaultTap)
            filtering = tap != nil
        }
        if tap == nil {
            tap = makeTap(options: .listenOnly)
        }
        guard let tap else {
            NSLog("Velora: CGEvent tap unavailable (permission not granted); using NSEvent fallback")
            return false
        }
        canSuppressComboEvents = filtering

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        usingEventTap = true
        // A listen-only keyboard tap is created successfully even WITHOUT
        // Input Monitoring — but then receives no events (silent-dead hotkey).
        // The NSEvent fallback needs the very same grant, so switching paths
        // wouldn't help; instead log the grant loudly so the cause is obvious.
        let granted = Permissions.inputMonitoringGranted
        veloraLog(
            "Velora: hotkey CGEvent tap installed (inputMonitoring="
            + (granted ? "granted" : "MISSING — hotkey stays dead until granted")
            + ", comboFiltering=" + (canSuppressComboEvents ? "enabled)" : "unavailable)"))
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        // The system disables taps that stall or that fire while another
        // process synthesizes input (our own ⌘V paste triggers
        // `.tapDisabledByUserInput`). Re-enable and resync to physical state.
        // An active combo latch is deliberately preserved while its key is
        // still down; clearing it would let the next autorepeat reach the app.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog(
                "Velora: hotkey tap disabled (%@) — re-enabling and resyncing latched state",
                type == .tapDisabledByTimeout ? "timeout" : "userInput")
            resetLatchedState(preservePhysicallyHeldCombos: true)
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let isVeloraEvent = sourcePID == Int64(ProcessInfo.processInfo.processIdentifier)

        switch type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
            return false
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return handleKeyDown(
                keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                invalidateContinuation: !isVeloraEvent,
                comboCanBeSuppressed: canSuppressComboEvents)
        case .keyUp:
            return handleKeyUp(keyCode: keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isVeloraEvent {
                UserInputActivity.mark()
                emit { $0.nonHotkeyInput() }
            }
            return false
        default:
            return false
        }
    }

    // MARK: - NSEvent fallback path

    private func startGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp,
                       .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            let flags = Hotkey.cgFlags(from: event.modifierFlags)
            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(keyCode: Int64(event.keyCode), flags: flags)
            case .keyDown:
                _ = self.handleKeyDown(
                    keyCode: Int64(event.keyCode), flags: flags,
                    isRepeat: event.isARepeat, comboCanBeSuppressed: false)
            case .keyUp:
                _ = self.handleKeyUp(keyCode: Int64(event.keyCode))
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                UserInputActivity.mark()
                self.emit { $0.nonHotkeyInput() }
            default:
                break
            }
        }
        usingEventTap = false
        NSLog("Velora: NSEvent global monitor installed (delivery requires Accessibility)")
    }

    // MARK: - Shared event interpretation

    private func handleFlagsChanged(keyCode: Int64, flags: UInt64) {
        guard !suspended else { return }
        if hotkey.isModifierOnly,
           keyCode == hotkey.keyCode,
           let mask = Hotkey.modifierMask(forKeyCode: keyCode) {
            let isDown = flags & mask.rawValue != 0
            guard isDown != modifierIsDown else { return }
            modifierIsDown = isDown
            emitHotkey(down: isDown)
            return
        }
        // Roles are checked in a fixed order, so two roles bound to the same
        // modifier resolve deterministically instead of both firing.
        for role in SecondaryHotkeyRole.allCases {
            guard let secondary = secondaryHotkeys[role], secondary != hotkey,
                  secondary.isModifierOnly, keyCode == secondary.keyCode,
                  let mask = Hotkey.modifierMask(forKeyCode: keyCode) else { continue }
            let isDown = flags & mask.rawValue != 0
            guard isDown != (secondaryModifierIsDown[role] ?? false) else { return }
            secondaryModifierIsDown[role] = isDown
            emitSecondaryHotkey(role, down: isDown)
            return
        }
    }

    @discardableResult
    func handleKeyDown(
        keyCode: Int64, flags: UInt64, isRepeat: Bool,
        invalidateContinuation: Bool = true,
        comboCanBeSuppressed: Bool = true
    ) -> Bool {
        if keyCode == Self.escKeyCode {
            if !suspended {
                emit { $0.escapePressed() }
            }
            return false
        }
        guard !suspended else { return false }
        let hotkeyComboMatches =
            !hotkey.isModifierOnly
            && keyCode == hotkey.keyCode
            && flags & Hotkey.strictModifierMask
                == hotkey.modifiers & Hotkey.strictModifierMask
        func comboMatches(_ role: SecondaryHotkeyRole) -> Bool {
            guard let secondary = secondaryHotkeys[role] else { return false }
            return secondary != hotkey
                && !secondary.isModifierOnly
                && keyCode == secondary.keyCode
                && flags & Hotkey.strictModifierMask
                    == secondary.modifiers & Hotkey.strictModifierMask
        }
        // First matching role wins, so one chord never triggers two features.
        let matchedRole = SecondaryHotkeyRole.allCases.first(where: comboMatches)
        if !comboCanBeSuppressed, hotkeyComboMatches || matchedRole != nil {
            if !isRepeat {
                NSLog(
                    "Velora: combo hotkey ignored — filtering event tap unavailable")
            }
            return false
        }
        // Once a combo is latched, keep every event for that physical key
        // suppressed until key-up even if the user releases a modifier first.
        // Otherwise autorepeat can leak plain characters into the selection.
        if !hotkey.isModifierOnly, keyCode == hotkey.keyCode, comboIsDown {
            return true
        }
        for role in SecondaryHotkeyRole.allCases {
            if let secondary = secondaryHotkeys[role], !secondary.isModifierOnly,
               keyCode == secondary.keyCode, secondaryComboIsDown[role] == true {
                return true
            }
        }
        if hotkeyComboMatches {
            if !isRepeat, !comboIsDown {
                comboIsDown = true
                NSLog(
                    "Velora: hotkey combo matched %@ (keyCode=%lld flags=0x%llx)",
                    hotkey.displayLabel, keyCode, flags)
                emitHotkey(down: true)
            }
            // Suppress the initial down plus any autorepeat while this combo
            // is latched, so the target app never sees part of the shortcut.
            return comboIsDown
        }
        if let matchedRole, let secondary = secondaryHotkeys[matchedRole] {
            if !isRepeat, secondaryComboIsDown[matchedRole] != true {
                secondaryComboIsDown[matchedRole] = true
                NSLog(
                    "Velora: %@ hotkey combo matched %@ (keyCode=%lld flags=0x%llx)",
                    matchedRole.label, secondary.displayLabel, keyCode, flags)
                emitSecondaryHotkey(matchedRole, down: true)
            }
            return secondaryComboIsDown[matchedRole] ?? false
        }
        if !isRepeat, invalidateContinuation {
            UserInputActivity.mark()
            emit { $0.nonHotkeyInput() }
        }
        return false
    }

    @discardableResult
    func handleKeyUp(keyCode: Int64) -> Bool {
        // Deliberately no modifier check: the up edge is the key itself, so
        // dropping a modifier before the key still ends the hold cleanly.
        if !hotkey.isModifierOnly, keyCode == hotkey.keyCode, comboIsDown {
            comboIsDown = false
            emitHotkey(down: false)
            return true
        }
        for role in SecondaryHotkeyRole.allCases {
            if let secondary = secondaryHotkeys[role], !secondary.isModifierOnly,
               keyCode == secondary.keyCode, secondaryComboIsDown[role] == true {
                secondaryComboIsDown[role] = false
                emitSecondaryHotkey(role, down: false)
                return true
            }
        }
        return false
    }

    private func emitHotkey(down: Bool) {
        veloraLog("Velora: hotkey \(down ? "down" : "up") (source=\(usingEventTap ? "tap" : "nsevent"))")
        emit(down ? { $0.hotkeyDown() } : { $0.hotkeyUp() })
    }

    private func emitSecondaryHotkey(_ role: SecondaryHotkeyRole, down: Bool) {
        veloraLog("Velora: \(role.label) hotkey \(down ? "down" : "up") "
                  + "(source=\(usingEventTap ? "tap" : "nsevent"))")
        emit(down ? { $0.secondaryHotkeyDown(role) } : { $0.secondaryHotkeyUp(role) })
    }

    private func emit(_ action: @escaping (HotkeyMonitorDelegate) -> Void) {
        // Never execute controller work inside the CGEvent tap callback. Voice
        // Edit begins with timeout-capped AX IPC; doing that synchronously can
        // exceed the event-tap budget and make macOS disable the filtering tap.
        guard let delegate else { return }
        DispatchQueue.main.async { [weak delegate] in
            guard let delegate else { return }
            action(delegate)
        }
    }
}
