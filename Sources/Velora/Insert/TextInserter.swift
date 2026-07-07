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
    private static let restoreDelay: TimeInterval = 0.3
    /// CGEvent unicode string limit per event.
    private static let typingChunk = 20

    /// Clipboard-manager conventions (http://nspasteboard.org): transient
    /// content should be ignored, concealed content never displayed/stored.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Inserts `text` into the app identified by `bundleID`, choosing the
    /// strategy from per-app configuration.
    func insert(_ text: String, targetBundleID: String?) {
        if let bundleID = targetBundleID,
           AppConfig.shared.typingFallbackApps.contains(bundleID) {
            insertViaTyping(text)
        } else {
            insertViaPasteboard(text)
        }
    }

    /// True when the process can post keyboard events (Accessibility granted).
    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    // MARK: - Pasteboard + ⌘V

    /// Puts `text` on the general pasteboard (marked transient + concealed)
    /// without synthesizing any input and without a restore. Used when the
    /// insertion target was lost (focus change, secure field) — the user
    /// pastes manually.
    func copyToClipboard(_ text: String) {
        writeDictation(text, to: NSPasteboard.general)
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

    func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general

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
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // kVK_ANSI_V
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
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
