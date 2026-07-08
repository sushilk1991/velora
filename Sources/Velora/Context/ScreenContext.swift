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
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
            let windowRef else { return nil }
        // Force-cast is safe: a successful copy of the focused-window attribute
        // always yields an AXUIElement.
        let window = windowRef as! AXUIElement  // swiftlint:disable:this force_cast
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
        guard let lead = segments.first, lead.count <= 80 else { return [] }
        // Drop a trailing app-name segment ("… - Slack") from consideration.
        let head = appName.map { name in
            lead.caseInsensitiveCompare(name) == .orderedSame ? "" : lead
        } ?? lead
        guard !head.isEmpty else { return [] }

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
            entities = [ContextEntity(type: "page", value: head)]
        case .notes, .none:
            entities = [ContextEntity(type: "title", value: head)]
        }
        return Array(entities.prefix(maxEntities))
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
