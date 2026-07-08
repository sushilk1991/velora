import AppKit
import ApplicationServices
import Foundation

/// A named thing pulled from the current screen context — the file you're
/// editing, the person/channel you're messaging, the page you're on. Fed to
/// the engine so dictation can reference or tag it ("add this to the auth
/// file" → `auth.ts`, "tell Priya it's ready" → `@Priya`).
struct ContextEntity {
    /// "file", "person", "channel", "subject", "page", or "title".
    let type: String
    let value: String

    var payload: [String: String] { ["type": type, "value": value] }
}

/// Extracts lightweight entities from the frontmost app using the macOS
/// Accessibility API (already-granted permission — no Screen Recording, no
/// screenshot). Reads only the focused window's title, so it stays cheap
/// (<~5 ms) and privacy-preserving: no body text, no keystrokes.
///
/// This is the AX half of the "hybrid" context engine; a small on-device VLM
/// screen-read is layered on later for Electron apps whose AX trees are thin.
enum ScreenContext {
    /// Max entities returned; keeps the prompt/vocabulary bounded.
    private static let maxEntities = 4

    /// Best-effort entities for the given app. Never throws; returns [] when
    /// AX is unavailable or the title yields nothing useful.
    static func entities(for app: NSRunningApplication?, category: ModeCategory?) -> [ContextEntity] {
        guard let app, app.processIdentifier > 0 else { return [] }
        guard let title = focusedWindowTitle(pid: app.processIdentifier) else { return [] }
        return parse(title: title, category: category, appName: app.localizedName)
    }

    // MARK: - AX read

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        // Bound the AX IPC: the default messaging timeout is ~6 s per call, so a
        // beachballing target app (Xcode indexing, Electron GC) could otherwise
        // stall dictation start. Cap both calls hard.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let windowRef,
            // A buggy third-party AX server can return .success with a non-window
            // CFType; verify before the cast so a bad app can't crash Velora.
            CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement  // checked above
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Title parsing

    /// Window titles are `segment <sep> segment <sep> …` with the most specific
    /// part first (filename, person, subject). Split on the common separators
    /// and interpret the leading segment(s) by category.
    private static func parse(title: String, category: ModeCategory?, appName: String?) -> [ContextEntity] {
        let segments = title
            .components(separatedBy: CharacterSet(charactersIn: "—–|·"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Drop app-name segments ("Slack | #general" → keep "#general") and take
        // the first meaningful one as the head.
        let meaningful = segments.filter { seg in
            appName.map { seg.caseInsensitiveCompare($0) != .orderedSame } ?? true
        }
        guard let head = meaningful.first, head.count <= 80 else { return [] }

        let entities: [ContextEntity]
        switch category {
        case .code:
            // "auth.ts", "auth.ts (Working Tree)", "● main.py" → the filename.
            if let file = filename(in: head) {
                entities = [ContextEntity(type: "file", value: file)]
            } else {
                entities = [ContextEntity(type: "title", value: head)]
            }
        case .chat:
            let isChannel = head.hasPrefix("#")
            entities = [ContextEntity(type: isChannel ? "channel" : "person",
                                      value: head.replacingOccurrences(of: "#", with: ""))]
        case .email:
            entities = [ContextEntity(type: "subject", value: head)]
        case .browser:
            // The site (Gmail, Docs, Linear, GitHub…) usually appears as the
            // trailing title segment; surface it so the engine can pick a mode
            // (a browser is otherwise one undifferentiated bucket).
            var browserEntities = [ContextEntity(type: "page", value: head)]
            if let site = site(in: segments) {
                browserEntities.insert(ContextEntity(type: "site", value: site), at: 0)
            }
            entities = browserEntities
        case .notes, .none:
            entities = [ContextEntity(type: "title", value: head)]
        }
        return Array(entities.prefix(maxEntities))
    }

    /// Known web apps keyed by a case-insensitive substring of the window
    /// title's trailing segment. Value is a stable slug the engine maps to a
    /// category/mode.
    private static let siteKeywords: [(needle: String, slug: String)] = [
        ("gmail", "gmail"), ("outlook", "outlook"), ("proton", "proton"),
        ("google docs", "gdocs"), ("notion", "notion"), ("obsidian", "obsidian"),
        ("linear", "linear"),
        ("slack", "slack"), ("discord", "discord"), ("whatsapp", "whatsapp"),
        ("messenger", "messenger"),
    ]

    /// Detects a known site from the LAST title segment only — that's where the
    /// web-app identifier lives ("Inbox - Gmail"). Scanning every segment let
    /// page-content words hijack the mode ("GitHub … - YouTube").
    private static func site(in segments: [String]) -> String? {
        guard let last = segments.last?.lowercased() else { return nil }
        for entry in siteKeywords where last.contains(entry.needle) {
            return entry.slug
        }
        return nil
    }

    /// Pulls a filename token out of an editor title segment.
    private static func filename(in segment: String) -> String? {
        // Strip leading status glyphs some editors prepend (● • ✗ etc.).
        let cleaned = segment.trimmingCharacters(
            in: CharacterSet(charactersIn: "●•◦*✗✓ ").union(.whitespaces))
        // A filename token: contains a dot-extension or is a single path-like word.
        let token = cleaned.split(separator: " ").first.map(String.init) ?? cleaned
        if token.contains("."), !token.hasSuffix(".") {
            return token
        }
        return nil
    }
}
