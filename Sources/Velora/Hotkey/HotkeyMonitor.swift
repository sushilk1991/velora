import AppKit
import CoreGraphics
import Foundation

/// Receives raw hotkey transitions. Interpretation (hold vs tap vs
/// double-tap-lock) lives in `DictationController`; this type only reports
/// clean down/up edges for the configured key plus Esc presses.
/// All callbacks are on the main queue.
protocol HotkeyMonitorDelegate: AnyObject {
    func hotkeyDown()
    func hotkeyUp()
    func escapePressed()
}

/// Global hotkey listener.
///
/// Primary path: a listen-only `CGEventTap` (session tap) for
/// keyDown/keyUp/flagsChanged. Falls back to `NSEvent` global monitors when
/// the tap cannot be created (Input Monitoring / Accessibility not granted
/// to this process — see spikes/menubar/FINDINGS.md on TCC attribution).
/// Neither path consumes events; Esc also reaches the frontmost app.
final class HotkeyMonitor {
    weak var delegate: HotkeyMonitorDelegate?

    /// The key being listened for; updated live from settings.
    var hotkey: HotkeyChoice = AppConfig.shared.hotkey

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var modifierIsDown = false
    private(set) var usingEventTap = false

    private static let escKeyCode: Int64 = 53

    // MARK: - Lifecycle

    /// Installs the event tap (or the NSEvent fallback). Safe to call once.
    func start() {
        guard eventTap == nil, globalMonitor == nil else { return }
        if !startEventTap() {
            startGlobalMonitor()
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
    }

    /// Tears down and reinstalls monitoring — call after a permission grant.
    func restart() {
        stop()
        start()
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
        // The system disables taps that stall; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, optionDown: flags.contains(.maskAlternate),
                               fnDown: flags.contains(.maskSecondaryFn))
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            handleKeyDown(keyCode: keyCode, isRepeat: isRepeat)
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
            switch event.type {
            case .flagsChanged:
                self.handleFlagsChanged(
                    keyCode: Int64(event.keyCode),
                    optionDown: event.modifierFlags.contains(.option),
                    fnDown: event.modifierFlags.contains(.function))
            case .keyDown:
                self.handleKeyDown(keyCode: Int64(event.keyCode), isRepeat: event.isARepeat)
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

    private func handleFlagsChanged(keyCode: Int64, optionDown: Bool, fnDown: Bool) {
        guard hotkey.isModifier, keyCode == hotkey.keyCode else { return }
        let isDown: Bool
        switch hotkey {
        case .rightOption: isDown = optionDown
        case .fn: isDown = fnDown
        default: return
        }
        guard isDown != modifierIsDown else { return }
        modifierIsDown = isDown
        emit(isDown ? { $0.hotkeyDown() } : { $0.hotkeyUp() })
    }

    private func handleKeyDown(keyCode: Int64, isRepeat: Bool) {
        if keyCode == Self.escKeyCode {
            emit { $0.escapePressed() }
            return
        }
        guard !hotkey.isModifier, keyCode == hotkey.keyCode, !isRepeat else { return }
        emit { $0.hotkeyDown() }
    }

    private func handleKeyUp(keyCode: Int64) {
        guard !hotkey.isModifier, keyCode == hotkey.keyCode else { return }
        emit { $0.hotkeyUp() }
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
