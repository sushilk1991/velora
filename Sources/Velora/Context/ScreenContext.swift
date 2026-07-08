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

    /// Rich context = title entities PLUS short text near the text cursor read
    /// from the Accessibility tree (the "Message <Name>" header on LinkedIn, a
    /// field label, the recipient chip). This is what lets the cleanup LLM spell
    /// a name it never heard clearly. Heavier than `entities` (walks a bounded
    /// slice of the AX tree), so callers run it OFF the hot path (a background
    /// queue at session start, ready by the time recording stops).
    static func richEntities(for app: NSRunningApplication?, category: ModeCategory?) -> [ContextEntity] {
        var result = entities(for: app, category: category)
        guard let app, app.processIdentifier > 0 else { return result }
        let nearby = nearbyText(pid: app.processIdentifier)
        // Cap total nearby chars so the prompt stays lean and private.
        var budget = 600
        for text in nearby {
            guard budget > 0 else { break }
            let clipped = String(text.prefix(min(text.count, budget, 80)))
            result.append(ContextEntity(type: "nearby", value: clipped))
            budget -= clipped.count
        }
        return result
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

    // MARK: - Focused element (for the learning loop)

    /// The app's currently focused UI element (usually the text field being
    /// dictated into), or nil. Held by the learning loop to re-read its value
    /// after the user edits, so corrections can be diffed.
    static func focusedElement(of app: NSRunningApplication?) -> AXUIElement? {
        guard let app, app.processIdentifier > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        return axElement(appElement, kAXFocusedUIElementAttribute)
    }

    /// The text value of an element (best effort; nil for non-text elements).
    static func stringValue(of element: AXUIElement) -> String? {
        axString(element, kAXValueAttribute)
    }

    // MARK: - Nearby-text read (rich context)

    /// Short text strings near the focused element: the field's own
    /// placeholder/title/description, then a bounded sweep of static text under
    /// a few ancestor levels (headers, labels, the person you're replying to).
    private static func nearbyText(pid: pid_t) -> [String] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let focused = axElement(appElement, kAXFocusedUIElementAttribute) else { return [] }

        var out: [String] = []
        // The focused field's own hints often name the recipient
        // ("Message Priya Sharma", "Reply to …", "To:").
        for attr in [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = axString(focused, attr) { out.append(s) }
        }
        // Climb a few levels to a container, then sweep its static text.
        var container = focused
        for _ in 0..<3 {
            guard let parent = axElement(container, kAXParentAttribute) else { break }
            container = parent
        }
        var budget = 30  // max elements visited (hard bound on cost)
        collectStaticText(container, into: &out, budget: &budget, depth: 0)

        // Dedup, keep short human-readable strings, cap count.
        var seen = Set<String>()
        return out.compactMap { raw -> String? in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 2, s.count <= 80, !seen.contains(s) else { return nil }
            seen.insert(s)
            return s
        }.prefix(12).map { $0 }
    }

    /// Depth- and count-bounded sweep collecting `AXStaticText`/`AXHeading`
    /// values (and a few titles) from an element's subtree.
    private static func collectStaticText(
        _ element: AXUIElement, into out: inout [String], budget: inout Int, depth: Int
    ) {
        guard budget > 0, depth <= 5 else { return }
        budget -= 1
        let role = axString(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole || role == "AXHeading" {
            if let v = axString(element, kAXValueAttribute) ?? axString(element, kAXTitleAttribute) {
                out.append(v)
            }
        }
        guard let children = axChildren(element) else { return }
        for child in children.prefix(12) {
            if budget <= 0 { break }
            collectStaticText(child, into: &out, budget: &budget, depth: depth + 1)
        }
    }

    // MARK: - AX helpers

    /// Per-element messaging timeout. `AXUIElementSetMessagingTimeout` does NOT
    /// propagate to elements returned from a queried element, so it must be set
    /// on every element we touch — otherwise a beachballing target app blocks us
    /// for the ~6 s system default per call.
    private static let axTimeout: Float = 0.25

    private static func axElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)  // checked
    }

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let s = ref as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement] else { return nil }
        return array
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
