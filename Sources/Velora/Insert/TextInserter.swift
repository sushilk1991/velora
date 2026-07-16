import AppKit
import ApplicationServices
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

    /// Puts a history record's text back on the clipboard and pastes it into
    /// the app it came from (best effort — needs Accessibility, degrades to a
    /// plain copy). Shared by the History tab and the HUD context menu.
    static func insertAgain(_ record: DictationRecord) {
        guard !record.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let inserter = TextInserter()
        inserter.copyToClipboard(record.final)
        guard let bundleID = record.bundleID,
              let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID).first
        else { return }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            inserter.insert(record.final, targetBundleID: bundleID, mode: record.mode)
        }
    }

    /// Inserts `text` into the app identified by `bundleID`, choosing the
    /// strategy from per-app configuration. Every attempt is logged so
    /// `log show --predicate 'process == "Velora"'` tells the whole story.
    func insert(
        _ text: String,
        targetBundleID: String?,
        mode: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard Self.deliveryAllowed(targetBundleID: targetBundleID) else {
            NSLog("Velora: insertion aborted before boundary read — target is not safe")
            completion?(false)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let targetStillFocused = targetBundleID == nil || frontmost?.bundleIdentifier == targetBundleID
        let targetElement = targetStillFocused ? ScreenContext.focusedElement(of: frontmost) : nil
        let boundary = targetElement.flatMap { ScreenContext.selectionBoundary(of: $0) }
        let deliveryText = TextInsertionBoundary.adjusted(
            text, boundary: boundary, mode: mode)

        // AX boundary reads are IPC and can take long enough for focus or
        // secure-input state to change. Revalidate after them, immediately
        // before choosing a delivery path.
        guard Self.deliveryAllowed(
            targetBundleID: targetBundleID, targetElement: targetElement
        ) else {
            NSLog("Velora: insertion aborted after boundary read — target no longer safe")
            completion?(false)
            return
        }
        if let bundleID = targetBundleID,
           AppConfig.shared.typingFallbackApps.contains(bundleID) {
            NSLog(
                "Velora: insert method=type target=%@ trusted=%@ chars=%ld",
                bundleID, Permissions.accessibilityGranted ? "yes" : "no", deliveryText.count)
            insertViaTyping(
                deliveryText,
                targetBundleID: targetBundleID,
                targetElement: targetElement,
                completion: completion)
        } else {
            let inserted = insertViaPasteboard(
                deliveryText,
                targetBundleID: targetBundleID,
                targetElement: targetElement)
            completion?(inserted)
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
    func insertIntoOwnWindow(_ text: String, mode: String? = nil) -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            NSLog("Velora: own-window insert — no key window / first responder")
            return false
        }
        // SwiftUI TextEditor / NSTextField field editors are backed by an
        // NSTextView; insertText(_:replacementRange:) respects the selection.
        if let textView = responder as? NSTextView {
            let selectedRange = textView.selectedRange()
            let boundary = TextSelectionBoundary(text: textView.string, utf16Range: selectedRange)
            let deliveryText = TextInsertionBoundary.adjusted(
                text, boundary: boundary, mode: mode)
            textView.insertText(deliveryText, replacementRange: selectedRange)
            NSLog("Velora: own-window insert via NSTextView chars=%ld", deliveryText.count)
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

    @discardableResult
    func insertViaPasteboard(
        _ text: String,
        targetBundleID: String? = nil,
        targetElement: AXUIElement? = nil
    ) -> Bool {
        guard Self.deliveryAllowed(
            targetBundleID: targetBundleID, targetElement: targetElement
        ) else {
            NSLog("Velora: paste aborted — target no longer safe")
            return false
        }
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

        // Recheck once more after the pasteboard write. If focus moved in this
        // tiny window, restore the staged/saved clipboard and post no event.
        guard Self.deliveryAllowed(
                  targetBundleID: targetBundleID, targetElement: targetElement),
              postCommandV()
        else {
            guard pasteboard.changeCount == ourChangeCount else { return false }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
            NSLog("Velora: paste aborted before Command-V — clipboard restored")
            return false
        }

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
        return true
    }

    private func postCommandV() -> Bool {
        pressKey(Hotkey.keyCode(for: "v") ?? 9, flags: .maskCommand)
    }

    /// Posts one key press (down+up) with the given modifiers. Keycodes are
    /// positional, so callers sending character shortcuts resolve them through
    /// `Hotkey.keyCode(for:)` first. Modified CGEvents deliberately carry no
    /// Unicode payload; macOS 26 can treat those as text input and silently
    /// discard the shortcut.
    @discardableResult
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Unicode typing fallback

    /// Types `text` as synthesized unicode key events. Layout-independent,
    /// handles emoji; paced at 2 ms per chunk so target apps keep up.
    func insertViaTyping(
        _ text: String,
        targetBundleID: String? = nil,
        targetElement: AXUIElement? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        // Typing is slow for long strings; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let source = CGEventSource(stateID: .combinedSessionState)
            let utf16 = Array(text.utf16)
            var index = 0
            while index < utf16.count {
                // A long terminal dictation spans many events. Stop before each
                // chunk if the user changes apps or enters a secure field so
                // the tail cannot spill into an unrelated/password target.
                guard Self.deliveryAllowed(
                    targetBundleID: targetBundleID, targetElement: targetElement
                ) else {
                    NSLog("Velora: typing aborted at utf16=%ld/%ld — target no longer safe",
                          index, utf16.count)
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                let end = min(index + Self.typingChunk, utf16.count)
                var chunk = Array(utf16[index..<end])
                index = end

                guard let down = CGEvent(
                          keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(
                          keyboardEventSource: source, virtualKey: 0, keyDown: false)
                else {
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(2000)
            }
            DispatchQueue.main.async { completion?(true) }
        }
    }

    private static func deliveryAllowed(
        targetBundleID: String?, targetElement: AXUIElement? = nil
    ) -> Bool {
        guard Permissions.accessibilityGranted, canPostEvents, !SecureInput.isActive else {
            return false
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let targetBundleID, frontmost?.bundleIdentifier != targetBundleID {
            return false
        }
        if let targetElement {
            guard let current = ScreenContext.focusedElement(of: frontmost),
                  CFEqual(current, targetElement)
            else { return false }
        }
        return true
    }
}
