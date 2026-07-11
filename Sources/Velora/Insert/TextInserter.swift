import AppKit
import CoreGraphics
import Foundation

/// Inserts dictated text into the frontmost app.
///
/// Default strategy: snapshot the pasteboard (all items, all representations),
/// set the text, synthesize ⌘V, then restore the snapshot after 300 ms.
/// Fallback strategy: CGEvent unicode typing (chunked ≤ 20 UTF-16 units per
/// event) for apps that block programmatic paste — used automatically for
/// terminal-like apps (`AppConfig.typingFallbackApps`).
///
/// Posting CGEvents requires the Accessibility TCC grant; without it the post
/// is a silent no-op (see spikes/menubar/FINDINGS.md).
final class TextInserter {
    /// Delay before restoring the user's pasteboard (docs/SPEC.md). Long
    /// enough for the target app to service the synthetic ⌘V; restore is
    /// additionally guarded by a `changeCount` check so a late paste (or a
    /// user copy in the window) is never clobbered.
    /// How long the dictated text stays on the pasteboard before the user's
    /// original clipboard is restored. Heavy Electron apps can service the
    /// synthetic ⌘V after 300 ms — they'd paste the RESTORED clipboard instead
    /// of the transcript (review finding). 800 ms is still well under a human
    /// copy-paste cycle, and the changeCount guard protects user copies.
    private static let restoreDelay: TimeInterval = 0.8
    /// CGEvent unicode string limit per event.
    private static let typingChunk = 20

    /// Clipboard-manager conventions (http://nspasteboard.org): transient
    /// content should be ignored, concealed content never displayed/stored.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Inserts `text` into the app identified by `bundleID`, choosing the
    /// strategy from per-app configuration. Every attempt is logged so
    /// `log show --predicate 'process == "Velora"'` tells the whole story.
    func insert(_ text: String, targetBundleID: String?) {
        if let bundleID = targetBundleID,
           AppConfig.shared.typingFallbackApps.contains(bundleID) {
            NSLog(
                "Velora: insert method=type target=%@ trusted=%@ chars=%ld",
                bundleID, Permissions.accessibilityGranted ? "yes" : "no", text.count)
            insertViaTyping(text)
        } else {
            insertViaPasteboard(text, targetBundleID: targetBundleID)
        }
    }

    /// True when the process can post keyboard events (Accessibility granted).
    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    // MARK: - Own-window insertion (no TCC)

    /// Inserts `text` into the first responder of Velora's own key window via
    /// the responder chain — used when Velora itself is frontmost (the
    /// onboarding try-it TextEditor). This is our own process, so it needs
    /// ZERO Accessibility/TCC (exactly right for first-run, before the user
    /// has granted anything, and it dodges the "focus changed" clipboard
    /// diversion that fires because the context tracker ignores Velora's own
    /// activations). Returns false when there is no text responder to receive
    /// the insertion, so the caller can fall back.
    @discardableResult
    func insertIntoOwnWindow(_ text: String) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            NSLog("Velora: own-window insert — no key window / first responder")
            return false
        }
        // SwiftUI TextEditor / NSTextField field editors are backed by an
        // NSTextView; insertText(_:replacementRange:) respects the selection.
        if let textView = responder as? NSTextView {
            textView.insertText(text, replacementRange: textView.selectedRange())
            NSLog("Velora: own-window insert via NSTextView chars=%ld", text.count)
            return true
        }
        // Any other responder that accepts insertText: (e.g. NSText).
        if responder.responds(to: #selector(NSText.insertText(_:))) {
            _ = NSApp.sendAction(#selector(NSText.insertText(_:)), to: responder, from: text)
            NSLog("Velora: own-window insert via responder insertText chars=%ld", text.count)
            return true
        }
        NSLog("Velora: own-window insert — first responder is not a text target")
        return false
    }

    // MARK: - Pasteboard + ⌘V

    /// Makes a final result available for manual paste before any best-effort
    /// insertion is attempted. This write is intentionally persistent: the
    /// synthesized Command-V path snapshots this item and therefore restores
    /// the final dictation, not the user's older clipboard contents.
    func stageFinalOutput(_ text: String) {
        let changeCount = writeDictation(text, to: pasteboard)
        NSLog(
            "Velora: staged final output chars=%ld changeCount=%ld",
            text.count, changeCount)
    }

    /// Compatibility name used by history/file-transcription actions that put
    /// text on the clipboard without attempting insertion.
    func copyToClipboard(_ text: String) {
        stageFinalOutput(text)
    }

    /// Writes the dictated text as a transient + concealed string item so
    /// clipboard managers skip it. Returns the pasteboard `changeCount` after
    /// our write.
    @discardableResult
    private func writeDictation(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.transientType)
        pasteboard.setString("", forType: Self.concealedType)
        return pasteboard.changeCount
    }

    func insertViaPasteboard(_ text: String, targetBundleID: String? = nil) {
        let pasteboard = self.pasteboard
        let changeCountBefore = pasteboard.changeCount

        // Snapshot every item with every representation it carries.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        let ourChangeCount = writeDictation(text, to: pasteboard)
        NSLog(
            "Velora: insert method=paste target=%@ trusted=%@ changeCount %ld→%ld",
            targetBundleID ?? "unknown",
            Permissions.accessibilityGranted ? "yes" : "no",
            changeCountBefore, ourChangeCount)

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            // Only restore if the pasteboard still holds our write. If the
            // user (or anything else) wrote to it during the window, restoring
            // would clobber their copy — skip entirely.
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
        }
    }

    private func postCommandV() {
        pressKey(9, flags: .maskCommand, character: "v")  // kVK_ANSI_V
    }

    /// Posts one key press (down+up) with the given modifiers. Keycodes are
    /// POSITIONAL — on AZERTY keycode 6 types "w", so ⌘Z posted by position
    /// becomes ⌘W (closes the window!). `character` stamps the event's
    /// unicode payload so key-equivalent matching sees the intended letter on
    /// every layout (review finding).
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], character: Character? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        if let character {
            var units = Array(String(character).utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Unicode typing fallback

    /// Types `text` as synthesized unicode key events. Layout-independent,
    /// handles emoji; paced at 2 ms per chunk so target apps keep up.
    func insertViaTyping(_ text: String) {
        // Typing is slow for long strings; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .combinedSessionState)
            let utf16 = Array(text.utf16)
            var index = 0
            while index < utf16.count {
                let end = min(index + Self.typingChunk, utf16.count)
                var chunk = Array(utf16[index..<end])
                index = end

                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    down.post(tap: .cghidEventTap)
                }
                if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    up.post(tap: .cghidEventTap)
                }
                usleep(2000)
            }
        }
    }
}
