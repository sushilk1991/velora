import AppKit
import CoreGraphics
import Foundation

/// Receives raw hotkey transitions. Interpretation (hold-to-talk vs
/// tap-to-lock) lives in `DictationController`; this type only reports
/// clean down/up edges for the configured hotkey plus Esc presses.
/// All callbacks are on the main queue.
protocol HotkeyMonitorDelegate: AnyObject {
    func hotkeyDown()
    func hotkeyUp()
    func escapePressed()
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
/// Primary path: a listen-only `CGEventTap` (session tap) for
/// keyDown/keyUp/flagsChanged. Falls back to `NSEvent` global monitors when
/// the tap cannot be created (Input Monitoring / Accessibility not granted
/// to this process — see spikes/menubar/FINDINGS.md on TCC attribution).
/// Neither path consumes events; Esc also reaches the frontmost app.
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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var recorderObserver: NSObjectProtocol?
    private var modifierIsDown = false
    /// Tracks an active combo press so keyUp matches even after the user
    /// releases the modifiers first.
    private var comboIsDown = false
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
    private func resetLatchedState() {
        if hotkey.isModifierOnly, let mask = Hotkey.modifierMask(forKeyCode: hotkey.keyCode) {
            let live = CGEventSource.flagsState(.combinedSessionState)
            modifierIsDown = live.rawValue & mask.rawValue != 0
        } else {
            modifierIsDown = false
        }
        // Combos: the up edge is the key's own keyUp regardless of modifiers,
        // and a missed keyUp is recovered by the next keyDown (comboIsDown gate),
        // so clearing is safe.
        comboIsDown = false
    }

    // MARK: - CGEventTap path

    private func startEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // C callback: cannot capture context; self travels via refcon.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleTapEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("Velora: CGEvent tap unavailable (permission not granted); using NSEvent fallback")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        usingEventTap = true
        NSLog("Velora: hotkey CGEvent tap installed")
        return true
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        // The system disables taps that stall or that fire while another
        // process synthesizes input (our own ⌘V paste triggers
        // `.tapDisabledByUserInput`). Re-enable, and CRUCIALLY reset the
        // latched modifier/combo state: an up-edge we missed while disabled
        // would otherwise wedge `modifierIsDown == true` and kill the hotkey.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog(
                "Velora: hotkey tap disabled (%@) — re-enabling and resetting latched state",
                type == .tapDisabledByTimeout ? "timeout" : "userInput")
            resetLatchedState()
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue

        switch type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            handleKeyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        case .keyUp:
            handleKeyUp(keyCode: keyCode)
        default:
            break
        }
    }

    // MARK: - NSEvent fallback path

    private func startGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            guard let self else { return }
            let flags = Hotkey.cgFlags(from: event.modifierFlags)
            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(keyCode: Int64(event.keyCode), flags: flags)
            case .keyDown:
                self.handleKeyDown(
                    keyCode: Int64(event.keyCode), flags: flags, isRepeat: event.isARepeat)
            case .keyUp:
                self.handleKeyUp(keyCode: Int64(event.keyCode))
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
        guard hotkey.isModifierOnly,
              keyCode == hotkey.keyCode,
              let mask = Hotkey.modifierMask(forKeyCode: keyCode)
        else { return }
        let isDown = flags & mask.rawValue != 0
        guard isDown != modifierIsDown else { return }
        modifierIsDown = isDown
        emitHotkey(down: isDown)
    }

    private func handleKeyDown(keyCode: Int64, flags: UInt64, isRepeat: Bool) {
        if keyCode == Self.escKeyCode {
            if !suspended {
                emit { $0.escapePressed() }
            }
            return
        }
        guard !suspended,
              !hotkey.isModifierOnly,
              keyCode == hotkey.keyCode,
              !isRepeat, !comboIsDown
        else { return }
        // Exact match on the device-independent modifiers only.
        let required = hotkey.modifiers & Hotkey.strictModifierMask
        guard flags & Hotkey.strictModifierMask == required else { return }
        comboIsDown = true
        NSLog(
            "Velora: hotkey combo matched %@ (keyCode=%lld flags=0x%llx)",
            hotkey.displayLabel, keyCode, flags)
        emitHotkey(down: true)
    }

    private func handleKeyUp(keyCode: Int64) {
        // Deliberately no modifier check: the up edge is the key itself, so
        // dropping a modifier before the key still ends the hold cleanly.
        guard !hotkey.isModifierOnly, keyCode == hotkey.keyCode, comboIsDown else { return }
        comboIsDown = false
        emitHotkey(down: false)
    }

    private func emitHotkey(down: Bool) {
        NSLog(
            "Velora: hotkey %@ (source=%@)",
            down ? "down" : "up", usingEventTap ? "tap" : "nsevent")
        emit(down ? { $0.hotkeyDown() } : { $0.hotkeyUp() })
    }

    private func emit(_ action: @escaping (HotkeyMonitorDelegate) -> Void) {
        if Thread.isMainThread {
            if let delegate { action(delegate) }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let delegate = self?.delegate else { return }
                action(delegate)
            }
        }
    }
}
