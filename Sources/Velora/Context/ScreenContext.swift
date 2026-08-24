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

enum ScreenTextSelectionIdentity {
    case characterRange(location: Int, length: Int)
    case textMarkerRange(CFTypeRef)
    case sublimeToken(SublimeTextSelectionToken)
    case unavailable
}

/// Exact selection snapshot used by Safe Voice Edit. Text alone is not an
/// identity: the same word can appear twice in one editor or webpage.
struct ScreenTextSelection {
    let text: String
    let element: AXUIElement
    let identity: ScreenTextSelectionIdentity
    let isEditable: Bool

    /// True only when the current selection is the exact editable range that
    /// was captured. An unavailable identity is always clipboard-only.
    func canReplace(with current: ScreenTextSelection) -> Bool {
        guard isEditable, current.isEditable,
              text == current.text,
              CFEqual(element, current.element)
        else { return false }
        switch (identity, current.identity) {
        case let (
            .characterRange(oldLocation, oldLength),
            .characterRange(newLocation, newLength)
        ):
            return oldLocation == newLocation && oldLength == newLength
        case let (.textMarkerRange(oldRange), .textMarkerRange(newRange)):
            return CFEqual(oldRange, newRange)
        case (.sublimeToken, _), (_, .sublimeToken):
            // Sublime tokens are validated and replaced inside Sublime; AX
            // cannot produce a comparable current range.
            return false
        case (.unavailable, _), (_, .unavailable),
             (.characterRange, .textMarkerRange), (.textMarkerRange, .characterRange):
            return false
        }
    }

    var sublimeToken: SublimeTextSelectionToken? {
        guard case .sublimeToken(let token) = identity else { return nil }
        return token
    }

    func discardMutableIdentity() {
        sublimeToken?.discard()
    }
}

/// Exact, bounded insertion point owned by one Stream Typing session.
/// Character offsets are UTF-16 because that is the unit used by macOS AX.
struct ScreenStreamTarget {
    let bundleID: String
    let element: AXUIElement
    let location: Int
    let originalText: String
    let boundary: TextSelectionBoundary?
}

/// A focused text control that accepts physical keys but does not expose a
/// settable Accessibility selection range. This intentionally permits only a
/// proven empty selection: without an exact range Velora could restore text,
/// but not the user's original selection, after cancellation.
struct ScreenKeystrokeStreamTarget {
    let bundleID: String
    let element: AXUIElement
    let location: Int
    let boundary: TextSelectionBoundary?
}

/// Exact opaque field captured for Stream's non-mutating HUD preview. The
/// element identity is retained so the final cannot land in another pane of
/// the same terminal app.
struct ScreenStreamPreviewTarget {
    let bundleID: String
    let element: AXUIElement
}

enum KeystrokeStreamTargetPolicy {
    static func mayCapture(
        role: String,
        editabilityProven: Bool,
        selectedRangeLength: Int?,
        selectedText: String?
    ) -> Bool {
        let isTextInput = role == kAXTextFieldRole
            || role == kAXTextAreaRole
            || role == kAXComboBoxRole
        guard isTextInput, editabilityProven else { return false }
        guard selectedRangeLength == 0 else { return false }
        return selectedText?.isEmpty ?? true
    }
}

enum StreamPreviewTargetPolicy {
    static func mayCapture(
        bundleID: String,
        role: String,
        editabilityProven: Bool,
        selectedRangeLength: Int?,
        allowedBundleIDs: [String]
    ) -> Bool {
        let isAllowed = allowedBundleIDs.contains {
            $0.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        let isTextInput = role == kAXTextFieldRole
            || role == kAXTextAreaRole
            || role == kAXComboBoxRole
        return isAllowed
            && isTextInput
            && editabilityProven
            && selectedRangeLength == 0
    }
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

    /// AXPress is a generic control action. Action Mode exposes it only for
    /// roles whose semantics are navigation, never mutation or submission.
    /// Groups are intentionally excluded: an unlabeled group can wrap a row,
    /// but it can just as easily wrap a destructive button cluster.
    static let actionNavigationRoles: Set<String> = [
        "AXRow", "AXCell",
    ]

    /// Browser variant: links are the web's navigation primitive (a search
    /// result, an article), so AXLink joins rows/cells there. Web buttons,
    /// checkboxes, and menu items stay refused — a link whose label names a
    /// committing verb is still rejected by the press denylist.
    static let browserNavigationRoles: Set<String> = [
        "AXRow", "AXCell", "AXLink",
    ]

    static func isActionNavigationRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return actionNavigationRoles.contains(role)
    }

    /// Best-effort entities for the given app. Never throws; returns [] when
    /// AX is unavailable or the title yields nothing useful.
    ///
    /// For browsers, the page URL host is the authoritative web-app signal
    /// (Notion and Linear tabs carry no product name in their titles) — the
    /// window's `AXDocument` is one cheap AX read. `deepURL` additionally
    /// walks from the focused element to a web area exposing `AXURL`; that
    /// costs more IPC, so only off-hot-path callers ask for it.
    static func entities(
        for app: NSRunningApplication?,
        category: ModeCategory?,
        deepURL: Bool = false
    ) -> [ContextEntity] {
        guard let app, app.processIdentifier > 0 else { return [] }
        // URL first: for Apple-Events browsers this also warms the tab-title
        // cache the fallback below reads.
        var slugFromURL: String?
        if category == .browser {
            slugFromURL = siteSlug(forHost: pageURL(of: app, deep: deepURL)?.host)
        }
        var title = focusedWindowTitle(pid: app.processIdentifier)
        if title == nil, category == .browser {
            // Chrome exposes no AX window at all; its tab title arrives with
            // the same Apple Event that fetched the URL.
            title = BrowserPage.cachedInfo(bundleID: app.bundleIdentifier)?.title
        }
        var result = title.map {
            parse(title: $0, category: category, appName: app.localizedName)
        } ?? []
        if let slug = slugFromURL {
            // The URL outranks the title guess: a title can mention a product
            // ("Gmail help"), the host cannot lie about where the user is.
            result.removeAll { $0.type == "site" }
            result.insert(ContextEntity(type: "site", value: slug), at: 0)
        }
        return Array(result.prefix(maxEntities))
    }

    /// Rich context = title entities PLUS short text near the text cursor read
    /// from the Accessibility tree (the "Message <Name>" header on LinkedIn, a
    /// field label, the recipient chip). This is what lets the cleanup LLM spell
    /// a name it never heard clearly. Heavier than `entities` (walks a bounded
    /// slice of the AX tree), so callers run it OFF the hot path (a background
    /// queue at session start, ready by the time recording stops).
    static func richEntities(for app: NSRunningApplication?, category: ModeCategory?) -> [ContextEntity] {
        var result = entities(for: app, category: category, deepURL: true)
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

    /// The raw title of an app's focused window, unparsed. Action Mode sends it
    /// to the planner as-is: "which window am I in" is the question, and the
    /// entity parser answers a different one.
    static func windowTitle(of app: NSRunningApplication?) -> String? {
        guard let app, app.processIdentifier > 0 else { return nil }
        if let title = focusedWindowTitle(pid: app.processIdentifier) {
            return title
        }
        // Chromium browsers: last tab title from the Apple-Events cache
        // (non-blocking here; deep readers fetch fresh).
        return BrowserPage.cachedInfo(bundleID: app.bundleIdentifier)?.title
    }

    /// Short, name-like labels visible in the app's front window — the sidebar
    /// rows in Slack, the chat list in WhatsApp.
    ///
    /// Speech recognition mishears names constantly ("Himesh" came back as
    /// "Hermes"), and a name the planner spells wrong is a name the quick
    /// switcher never finds. The correct spellings are usually right there on
    /// screen, so this hands the planner the actual candidates.
    ///
    /// A bounded breadth-first walk: Electron trees are enormous and every read
    /// is IPC, so this caps nodes, depth, and wall time rather than trusting the
    /// tree to be small. Runs off the hotkey path.
    static func visibleNames(
        of app: NSRunningApplication?,
        limit: Int = 40,
        nodeBudget: Int = 700,
        deadline: TimeInterval = 1.2
    ) -> [String] {
        guard let app, app.processIdentifier > 0, Permissions.accessibilityGranted else {
            return []
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let window = focusedOrFirstWindow(
            appElement, pid: app.processIdentifier) else { return [] }

        let stopAt = Date().addingTimeInterval(deadline)
        var names: [String] = []
        var seen = Set<String>()
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0

        while !queue.isEmpty, visited < nodeBudget, names.count < limit, Date() < stopAt {
            let (element, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.2)
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                        element, attribute as CFString, &ref) == .success,
                      let text = ref as? String else { continue }
                guard let candidate = nameCandidate(text) else { continue }
                let key = candidate.lowercased()
                if seen.insert(key).inserted { names.append(candidate) }
            }
            guard depth < 8 else { continue }
            for child in (axChildren(element) ?? []).prefix(40) {
                queue.append((child, depth + 1))
            }
        }
        return names
    }

    /// Finds and presses the navigation row/cell whose visible label
    /// matches `label`. Label-addressed only; there is deliberately no
    /// press-by-coordinate anywhere in Action Mode, and non-navigation roles
    /// are refused even when their labels pass planning validation.
    ///
    /// Matching is `AppMatcher.contextMatches` (whole-word, ALL terms), the
    /// same rule `verify_context` lives by, so "Priya" cannot press
    /// "Priyanka". The element that carries the text is often not the one
    /// that accepts the press (Slack rows expose AXStaticText children), so
    /// after a label match the press walks up a few ancestors looking for one
    /// that lists AXPress. Bounded like `visibleNames`: Electron trees are
    /// enormous and every read is IPC.
    static func pressElement(
        labelled label: String,
        in app: NSRunningApplication?,
        roles: Set<String> = actionNavigationRoles,
        nodeBudget: Int = 900,
        deadline: TimeInterval = 1.5
    ) -> Bool {
        guard let app, app.processIdentifier > 0, Permissions.accessibilityGranted else {
            return false
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let window = focusedOrFirstWindow(
            appElement, pid: app.processIdentifier) else { return false }

        let stopAt = Date().addingTimeInterval(deadline)
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0

        while !queue.isEmpty, visited < nodeBudget, Date() < stopAt {
            let (element, depth) = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.2)
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                guard let text = axString(element, attribute),
                      AppMatcher.contextMatches([label], in: [text]) else { continue }
                // The denylist must judge the element's FULL text — BOTH
                // attributes joined, not just the one that matched (review
                // findings): "Priya Sharma" matches an element titled "Delete
                // chat with Priya Sharma", and an element titled "Priya
                // Sharma" can carry description "Delete conversation".
                let fullText = [
                    axString(element, kAXTitleAttribute),
                    axString(element, kAXDescriptionAttribute),
                ].compactMap { $0 }.joined(separator: " ")
                guard !ActionPlan.pressLabelIsCommitting(fullText) else { continue }
                if press(element, roles: roles) { return true }
                // The text lives on a child; the pressable thing is the row.
                // An ancestor that carries its OWN label gets the same
                // judgment — an unlabeled container (the typical Electron
                // row) is what this walk exists for.
                var ancestor = axElement(element, kAXParentAttribute)
                for _ in 0..<3 {
                    guard let candidate = ancestor else { break }
                    let ancestorText = [
                        axString(candidate, kAXTitleAttribute),
                        axString(candidate, kAXDescriptionAttribute),
                    ].compactMap { $0 }.joined(separator: " ")
                    if !ancestorText.isEmpty,
                       ActionPlan.pressLabelIsCommitting(ancestorText) { break }
                    if press(candidate, roles: roles) { return true }
                    ancestor = axElement(candidate, kAXParentAttribute)
                }
            }
            guard depth < 10 else { continue }
            for child in (axChildren(element) ?? []).prefix(40) {
                queue.append((child, depth + 1))
            }
        }
        return false
    }

    /// Performs AXPress only when both role and action prove this is an
    /// explicit navigation target. Buttons and generic containers are skipped.
    private static func press(_ element: AXUIElement, roles: Set<String>) -> Bool {
        guard let role = axString(element, kAXRoleAttribute),
              roles.contains(role) else {
            return false
        }
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String],
              actions.contains(kAXPressAction as String) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // MARK: - Page URL (browsers)

    /// Accepts only web-page URLs and strips credentials. `file:`, `chrome:`,
    /// `about:` and malformed strings are rejected — a non-web document path
    /// is private and useless for site detection. Pure logic; selftested.
    static func normalizedPageURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// PIDs whose Chromium accessibility switch this process has flipped.
    /// One set call per app instance is enough; the attribute is harmless on
    /// apps that don't implement it (the set simply fails).
    private static var accessibilityEnabledPIDs = Set<pid_t>()
    private static let accessibilityEnabledLock = NSLock()

    /// Chromium builds its AX tree on demand. The documented trigger for
    /// "platform API consumers" is a trusted client reading the APPLICATION
    /// element's AXRole (`accessibilityRole` override in Chromium's
    /// chrome_browser_application_mac.mm) — that enables native-API mode
    /// without flipping Chrome into full screen-reader mode the way
    /// `AXEnhancedUserInterface` would. `AXManualAccessibility` is set too:
    /// it is a no-op on Chrome proper (Electron-only attribute) but wakes
    /// Electron apps whose trees start dormant. The tree builds
    /// asynchronously, so the caller's CURRENT read may still miss; the next
    /// one succeeds.
    static func enableChromiumAccessibility(_ appElement: AXUIElement, pid: pid_t) {
        accessibilityEnabledLock.lock()
        let firstTime = accessibilityEnabledPIDs.insert(pid).inserted
        accessibilityEnabledLock.unlock()
        guard firstTime else { return }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(
            appElement, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The frontmost window, waking a dormant Chromium AX server if needed.
    private static func focusedOrFirstWindow(
        _ appElement: AXUIElement, pid: pid_t
    ) -> AXUIElement? {
        if let window = axElement(appElement, kAXFocusedWindowAttribute)
            ?? axElements(appElement, kAXWindowsAttribute).first {
            return window
        }
        enableChromiumAccessibility(appElement, pid: pid)
        return axElement(appElement, kAXFocusedWindowAttribute)
            ?? axElements(appElement, kAXWindowsAttribute).first
    }

    /// URL of the frontmost page in a browser, via Accessibility. The
    /// window's `AXDocument` is the cheap path where a browser exposes it;
    /// `deep` additionally searches the window for the web area's `AXURL`
    /// (Safari exposes the page URL there and not on the window — verified
    /// live) and checks the focused element's ancestors. Deep costs more AX
    /// IPC, so the hotkey path never asks for it. Best effort; nil is normal.
    static func pageURL(of app: NSRunningApplication?, deep: Bool = false) -> URL? {
        guard let app, app.processIdentifier > 0 else { return nil }
        if let url = axPageURL(of: app, deep: deep) {
            return url
        }
        if BrowserPage.usesAppleScript(app.bundleIdentifier) {
            // Chromium's accessibility engine sleeps until something enables
            // it (verified live: with it awake, the window's AXDocument holds
            // the URL; after a browser restart it sleeps again). The Apple
            // Events road survives restarts once the user consents. Deep
            // callers (background/rich context, Action Mode) wait briefly for
            // a fresh read; the hotkey path takes the cache and kicks a
            // refresh so the stop-time gate sees the real URL.
            if deep { return BrowserPage.info(app)?.url }
            let cached = BrowserPage.cachedInfo(bundleID: app.bundleIdentifier)?.url
            BrowserPage.refresh(app)
            return cached
        }
        return nil
    }

    /// The accessibility half of `pageURL`: window `AXDocument`, then (deep)
    /// the web area's `AXURL` and the focused element's ancestors.
    private static func axPageURL(of app: NSRunningApplication, deep: Bool) -> URL? {
        guard Permissions.accessibilityGranted else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        let window = focusedOrFirstWindow(appElement, pid: app.processIdentifier)
        if let window,
           let url = normalizedPageURL(axURLString(window, kAXDocumentAttribute)) {
            return url
        }
        guard deep else { return nil }
        // The web area carries AXURL; find it under the window. Bounded like
        // every other tree walk here — browser trees are enormous.
        if let window, let url = webAreaURL(under: window) {
            return url
        }
        var element = axElement(appElement, kAXFocusedUIElementAttribute)
        for _ in 0..<6 {
            guard let current = element else { break }
            if let url = normalizedPageURL(axURLString(current, kAXURLAttribute)) {
                return url
            }
            element = axElement(current, kAXParentAttribute)
        }
        return nil
    }

    /// Breadth-first search for an `AXWebArea` exposing `AXURL`. Web areas
    /// sit shallow (window → group/scroll/tab content → web area), so the
    /// budget stays small.
    private static func webAreaURL(under window: AXUIElement) -> URL? {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 80 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if axString(element, kAXRoleAttribute) == "AXWebArea",
               let url = normalizedPageURL(axURLString(element, kAXURLAttribute)) {
                return url
            }
            guard depth < 7 else { continue }
            for child in (axChildren(element) ?? []).prefix(12) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    /// AX role of the app's focused element ("AXTextField", "AXTextArea").
    static func focusedElementRole(of app: NSRunningApplication?) -> String? {
        guard let app, let focused = focusedElement(of: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.3)
        return axString(focused, kAXRoleAttribute)
    }

    /// Keeps strings that could plausibly be a person, channel, or app name and
    /// drops UI prose. A sentence is not a name, and neither is a single letter.
    /// Internal (not private) because the background action host applies the
    /// SAME policy to driver window snapshots — one rule, two readers.
    static func nameCandidate(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 40 else { return nil }
        let words = text.split(separator: " ")
        guard words.count <= 4 else { return nil }
        guard text.rangeOfCharacter(from: .letters) != nil else { return nil }
        // Punctuation-heavy strings are labels and glyphs, not names.
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters * 2 >= text.count else { return nil }
        return text
    }

    // MARK: - AX read

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        // Bound the AX IPC: the default messaging timeout is ~6 s per call, so a
        // beachballing target app (Xcode indexing, Electron GC) could otherwise
        // stall dictation start. Cap both calls hard.
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var window = axElement(appElement, kAXFocusedWindowAttribute)
        if window == nil {
            // A dormant Chromium AX server returns nothing at all until an
            // assistive client announces itself; wake it and retry once.
            enableChromiumAccessibility(appElement, pid: pid)
            window = axElement(appElement, kAXFocusedWindowAttribute)
        }
        guard let window else { return nil }
        // Timeouts do NOT propagate to returned elements (see axTimeout note):
        // without this, the title read below runs at the ~6s system default on
        // the hotkey hot path — a beachballing app would freeze dictation start.
        AXUIElementSetMessagingTimeout(window, 0.25)
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

    /// The frontmost app's current text selection, for Safe Voice Edit.
    /// Returns the exact string, element, and range identity so the caller can
    /// verify the selection has not moved before pasting the replacement.
    /// WebKit/Electron surfaces expose document selections as text-marker
    /// ranges rather than `AXSelectedText`, so both representations are read.
    /// Nil when there is no selection or the selection is empty/whitespace.
    static func selectedText(of app: NSRunningApplication?) -> ScreenTextSelection? {
        guard let focused = focusedElement(of: app) else { return nil }
        if let selection = resolvedSelectionText(
            direct: { axRawString(focused, kAXSelectedTextAttribute) },
            textMarker: { nil }
        ) {
            let range = axRange(focused, kAXSelectedTextRangeAttribute)
            let identity = range.map {
                ScreenTextSelectionIdentity.characterRange(
                    location: $0.location, length: $0.length)
            } ?? .unavailable
            return ScreenTextSelection(
                text: selection,
                element: focused,
                identity: identity,
                isEditable: range != nil
                    && axAttributeIsSettable(focused, kAXValueAttribute))
        }
        guard let marker = axSelectedTextMarkerSelection(focused),
              let selection = resolvedSelectionText(
                direct: { nil }, textMarker: { marker.text })
        else { return nil }
        return ScreenTextSelection(
            text: selection,
            element: focused,
            identity: .textMarkerRange(marker.range),
            // Static webpage selections are readable but not replaceable.
            // They still enter edit mode and return the result on clipboard.
            isEditable: axAttributeIsSettable(focused, kAXValueAttribute))
    }

    /// Resolves the native text-control representation first, then the web
    /// text-marker representation. The closures keep the fallback lazy: a
    /// normal NSTextView pays no extra AX IPC.
    static func resolvedSelectionText(
        direct: () -> String?,
        textMarker: () -> String?
    ) -> String? {
        if let selection = direct(),
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selection
        }
        if let selection = textMarker(),
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selection
        }
        return nil
    }

    /// Characters immediately around the focused selection/caret. Used only at
    /// insertion time to prevent two dictations (or a dictation and existing
    /// prose) from being concatenated without a separator.
    static func selectionBoundary(of app: NSRunningApplication?) -> TextSelectionBoundary? {
        guard let focused = focusedElement(of: app) else { return nil }
        return selectionBoundary(of: focused)
    }

    /// Boundary read for an already-snapshotted target. Keeping the AX element
    /// lets the inserter verify that focus did not move to another field in the
    /// same app while the range calls were in flight.
    static func selectionBoundary(of focused: AXUIElement) -> TextSelectionBoundary? {
        guard let range = axRange(focused, kAXSelectedTextRangeAttribute),
              let characterCount = axInt(focused, kAXNumberOfCharactersAttribute),
              range.location >= 0,
              range.length >= 0,
              range.location <= characterCount,
              range.length <= characterCount - range.location
        else { return nil }

        // Never read the element's full value here. A document or terminal can
        // contain megabytes of private text; only quote classification and the
        // adjacent characters are needed for insertion spacing.
        let limit = TextSelectionBoundary.contextLimit
        let beforeStart = max(0, range.location - limit)
        let beforeLength = range.location - beforeStart
        let afterStart = range.location + range.length
        let afterLength = min(limit, characterCount - afterStart)
        let before = beforeLength == 0
            ? ""
            : axStringForRange(focused, CFRange(location: beforeStart, length: beforeLength))
        let after = afterLength == 0
            ? ""
            : axStringForRange(focused, CFRange(location: afterStart, length: afterLength))
        guard let before, let after else { return nil }
        return TextSelectionBoundary(before: before, after: after)
    }

    // MARK: - Stream Typing target ownership

    /// Captures a caret/selection without reading the surrounding document.
    /// Stream Typing is enabled only for AX controls whose selection range can
    /// be set, because every provisional revision must replace exactly the
    /// draft Velora previously wrote. Unsupported apps still receive the final
    /// through the normal safe insertion path.
    static func streamTarget(of app: NSRunningApplication?) -> ScreenStreamTarget? {
        guard let app, let bundleID = app.bundleIdentifier,
              let focused = focusedElement(of: app),
              let range = axRange(focused, kAXSelectedTextRangeAttribute),
              range.location >= 0, range.length >= 0, range.length <= 8_000,
              axAttributeIsSettable(focused, kAXSelectedTextRangeAttribute)
        else { return nil }
        let selected = range.length == 0
            ? ""
            : axStringForRange(focused, range)
        guard let selected else { return nil }
        return ScreenStreamTarget(
            bundleID: bundleID,
            element: focused,
            location: range.location,
            originalText: selected,
            boundary: selectionBoundary(of: focused))
    }

    /// Captures the guarded fallback target used when an editable control
    /// accepts real keystrokes but cannot expose the exact mutable range that
    /// `ScreenStreamTarget` requires. A role alone is insufficient (read-only
    /// text has the same role), and an unknown selection is insufficient (the
    /// first partial could destroy selected user text), so both editability and
    /// an empty selection must be observable.
    static func keystrokeStreamTarget(
        of app: NSRunningApplication?
    ) -> ScreenKeystrokeStreamTarget? {
        guard let app, let bundleID = app.bundleIdentifier,
              let focused = focusedElement(of: app),
              let role = axString(focused, kAXRoleAttribute),
              axParameterizedAttributeIsAvailable(
                focused, kAXStringForRangeParameterizedAttribute)
        else { return nil }

        let selectedRange = axRange(focused, kAXSelectedTextRangeAttribute)
        let selectedText = axRawString(focused, kAXSelectedTextAttribute)
        guard let selectedRange, selectedRange.location >= 0 else { return nil }
        guard KeystrokeStreamTargetPolicy.mayCapture(
            role: role,
            editabilityProven:
                axAttributeIsSettable(focused, kAXValueAttribute)
                || axBool(focused, kAXIsEditableAttribute) == true
                || axElement(
                    focused, kAXEditableAncestorAttribute) != nil
                || axElement(
                    focused, kAXHighestEditableAncestorAttribute) != nil,
            selectedRangeLength: selectedRange.length,
            selectedText: selectedText)
        else { return nil }
        return ScreenKeystrokeStreamTarget(
            bundleID: bundleID,
            element: focused,
            location: selectedRange.location,
            boundary: selectionBoundary(of: focused))
    }

    /// Opaque terminal surfaces can accept a final insertion but cannot prove
    /// ownership of a provisional range. They receive a live Velora preview,
    /// never blind Backspaces, then the normal guarded final insertion.
    static func streamPreviewTarget(
        of app: NSRunningApplication?
    ) -> ScreenStreamPreviewTarget? {
        guard let app, let bundleID = app.bundleIdentifier,
              let focused = focusedElement(of: app),
              let role = axString(focused, kAXRoleAttribute),
              let range = axRange(focused, kAXSelectedTextRangeAttribute)
        else { return nil }
        guard StreamPreviewTargetPolicy.mayCapture(
            bundleID: bundleID,
            role: role,
            editabilityProven:
                axAttributeIsSettable(focused, kAXValueAttribute)
                || axBool(focused, kAXIsEditableAttribute) == true
                || axElement(focused, kAXEditableAncestorAttribute) != nil
                || axElement(focused, kAXHighestEditableAncestorAttribute) != nil,
            selectedRangeLength: range.length,
            allowedBundleIDs: AppConfig.shared.typingFallbackApps)
        else { return nil }
        return ScreenStreamPreviewTarget(
            bundleID: bundleID,
            element: focused)
    }

    static func streamPreviewTargetIsCurrent(
        _ target: ScreenStreamPreviewTarget,
        inputGeneration: UInt64
    ) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        let focused = focusedElement(of: app)
        return StreamPreviewOwnershipPolicy.isCurrent(
            capturedGeneration: inputGeneration,
            currentGeneration: UserInputActivity.snapshot(),
            capturedBundleID: target.bundleID,
            frontmostBundleID: app?.bundleIdentifier,
            focusedElementMatches: focused.map {
                CFEqual($0, target.element)
            } ?? false)
    }

    /// Proves the fallback caret is still immediately after the exact draft
    /// Velora wrote. The range need not be settable; reading it plus the
    /// bounded draft range is sufficient before Backspace-based revision.
    static func keystrokeStreamOwnsDraft(
        _ draft: String,
        target: ScreenKeystrokeStreamTarget
    ) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier == target.bundleID,
              let focused = focusedElement(of: app),
              CFEqual(focused, target.element),
              let range = axRange(
                focused, kAXSelectedTextRangeAttribute),
              range.location == target.location + draft.utf16.count,
              range.length == 0
        else { return false }
        if draft.isEmpty { return true }
        return axStringForRange(
            focused,
            CFRange(
                location: target.location,
                length: draft.utf16.count)) == draft
    }

    /// The user has not moved or edited the original selection.
    static func streamOriginalIsCurrent(_ target: ScreenStreamTarget) -> Bool {
        streamSelectionMatches(
            target, location: target.location,
            text: target.originalText)
    }

    /// The exact range is currently selected, immediately before a revision
    /// types over it.
    static func streamSelectionIsCurrent(
        _ text: String, target: ScreenStreamTarget
    ) -> Bool {
        streamSelectionMatches(target, location: target.location, text: text)
    }

    /// The caret and bounded text still prove that Velora owns `draft`.
    static func streamOwnsDraft(_ draft: String, target: ScreenStreamTarget) -> Bool {
        guard streamFocusedElementMatches(target),
              let range = axRange(target.element, kAXSelectedTextRangeAttribute),
              range.location == target.location + draft.utf16.count,
              range.length == 0
        else { return false }
        return axStringForRange(
            target.element,
            CFRange(location: target.location, length: draft.utf16.count)
        ) == draft
    }

    /// Which of `streamOwnsDraft`'s conditions is false, for logs and the
    /// `--stream-e2e` probe. Diagnostic only: nothing branches on this, so a
    /// stale read here can never widen what Velora is willing to type over.
    static func streamDraftOwnershipDiagnosis(
        _ draft: String, target: ScreenStreamTarget
    ) -> String {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier == target.bundleID else {
            return "frontmost is \(app?.bundleIdentifier ?? "nothing")"
        }
        guard let focused = focusedElement(of: app) else {
            return "no focused element"
        }
        guard CFEqual(focused, target.element) else {
            return "focused element identity changed"
        }
        guard let range = axRange(focused, kAXSelectedTextRangeAttribute) else {
            return "no selected range"
        }
        let expected = target.location + draft.utf16.count
        guard range.location == expected, range.length == 0 else {
            return "caret at (\(range.location),\(range.length)), expected (\(expected),0)"
        }
        let readBack = axStringForRange(
            target.element,
            CFRange(location: target.location, length: draft.utf16.count))
        guard let readBack else { return "draft range unreadable" }
        guard readBack == draft else {
            return "draft text differs (\(readBack.utf16.count) vs "
                + "\(draft.utf16.count) utf16 units)"
        }
        return "ownership intact"
    }

    /// Selects only the exact provisional draft after proving its contents and
    /// caret. A user keystroke/click invalidates the separate generation guard
    /// before this method is called.
    ///
    /// Asynchronous because the confirming read may have to wait — see
    /// `settle`.
    static func selectStreamDraft(
        _ draft: String,
        target: ScreenStreamTarget,
        completion: @escaping (Bool) -> Void
    ) {
        guard streamOwnsDraft(draft, target: target) else {
            completion(false)
            return
        }
        var range = CFRange(location: target.location, length: draft.utf16.count)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextRangeAttribute as CFString,
                value) == .success
        else {
            completion(false)
            return
        }
        settle(
            until: {
                streamSelectionMatches(
                    target, location: target.location, text: draft)
            },
            completion: completion)
    }

    /// How long an AX write may take to become visible to a reader before
    /// Velora treats it as not having happened.
    ///
    /// Chromium-family targets — Chrome and every Electron app — apply a
    /// selection change in the renderer process and acknowledge it
    /// asynchronously. The read immediately after a *successful* set still
    /// returns the OLD range. Reading once therefore turns "not yet" into "not
    /// true": Velora abandoned a draft it still owned, stopped typing after the
    /// first partial, and left the draft selected so the user's next keystroke
    /// wiped it. Reproduced live in Chrome and in Electron (see
    /// `--stream-e2e`).
    ///
    /// Polling cannot loosen the guarantee. Only the exact expected state ever
    /// returns true, and a timeout still fails closed — the wait just stops
    /// mistaking latency for a lost draft.
    static let streamSettleSeconds: TimeInterval = 0.4
    private static let streamPollSeconds: TimeInterval = 0.01

    /// Polls `condition` on the main queue until it holds or the budget runs
    /// out, calling back with the answer. Costs exactly one read against a
    /// synchronous target.
    ///
    /// It does NOT block the caller, and that is the whole point. Sleeping was
    /// the obvious implementation and the wrong one: Velora's hotkey CGEvent
    /// tap is a source on the **main** run loop (`HotkeyMonitor`), and that
    /// callback is what increments `UserInputActivity` — the guard that
    /// notices the user typing mid-draft. Sleeping the main thread would make
    /// that guard read "nothing happened" for exactly as long as the wait, and
    /// macOS additionally disables a tap that stalls
    /// (`.tapDisabledByTimeout`, already handled in HotkeyMonitor because it
    /// happens): the events lost during such a stall never arrive at all.
    /// A wait that blinds the safety guard is not a safe wait.
    ///
    /// The budget bounds the waiting, not the work: the final evaluation
    /// starts before the deadline and may finish after it.
    static func settle(
        until condition: @escaping () -> Bool,
        seconds: TimeInterval = streamSettleSeconds,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        func attempt() {
            if condition() {
                completion(true)
                return
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + streamPollSeconds, execute: attempt)
        }
        attempt()
    }

    /// Undoes Velora's own selection when a revision is abandoned after the
    /// draft was selected for replacement. Without this the draft stays
    /// highlighted and the user's next keystroke replaces it — the "it typed
    /// something and then it vanished" report.
    ///
    /// `generation` is the physical-input generation this draft was owned at.
    /// A selection that merely *looks* like the one Velora would have set is
    /// not proof Velora set it — the user could have selected the same range
    /// themselves (⌘A in a field holding only the draft produces an exact
    /// match). Only the generation separates "ours" from "identical", so a
    /// changed one means hands off.
    static func collapseStreamDraftSelection(
        _ draft: String,
        target: ScreenStreamTarget,
        ownedAtGeneration generation: UInt64,
        completion: (() -> Void)? = nil
    ) {
        guard StreamInputOwnership.isCurrent(generation) else {
            completion?()
            return
        }
        settle(until: {
            streamSelectionMatches(
                target, location: target.location, text: draft)
        }) { matched in
            guard matched, StreamInputOwnership.isCurrent(generation) else {
                completion?()
                return
            }
            var caret = CFRange(
                location: target.location + draft.utf16.count, length: 0)
            if let value = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(
                    target.element,
                    kAXSelectedTextRangeAttribute as CFString,
                    value)
            }
            completion?()
        }
    }

    private static func streamSelectionMatches(
        _ target: ScreenStreamTarget, location: Int, text: String
    ) -> Bool {
        guard streamFocusedElementMatches(target),
              let range = axRange(target.element, kAXSelectedTextRangeAttribute),
              range.location == location,
              range.length == text.utf16.count
        else { return false }
        if text.isEmpty { return true }
        return axStringForRange(target.element, range) == text
    }

    private static func streamFocusedElementMatches(_ target: ScreenStreamTarget) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier == target.bundleID,
              let focused = focusedElement(of: app)
        else { return false }
        return CFEqual(focused, target.element)
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

    static func axElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)  // checked
    }

    static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        guard let s = axRawString(element, attr) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// URL-valued attributes arrive as CFURL (`AXURL`) or as String
    /// (`AXDocument`, app-dependent); accept both.
    private static func axURLString(_ element: AXUIElement, _ attr: String) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref else { return nil }
        if let url = ref as? URL { return url.absoluteString }
        if let string = ref as? String { return string }
        return nil
    }

    private static func axRawString(_ element: AXUIElement, _ attr: String) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let s = ref as? String else { return nil }
        return s
    }

    private static func axRange(_ element: AXUIElement, _ attr: String) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        let value = ref as! AXValue  // type id checked above
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private static func axInt(_ element: AXUIElement, _ attr: String) -> Int? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let number = ref as? NSNumber
        else { return nil }
        return number.intValue
    }

    private static func axBool(
        _ element: AXUIElement, _ attr: String
    ) -> Bool? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attr as CFString, &ref) == .success,
              let number = ref as? NSNumber
        else { return nil }
        return number.boolValue
    }

    private static func axParameterizedAttributeIsAvailable(
        _ element: AXUIElement, _ attr: String
    ) -> Bool {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(
                element, &names) == .success,
              let names = names as? [String]
        else { return false }
        return names.contains(attr)
    }

    private static func axStringForRange(
        _ element: AXUIElement, _ range: CFRange
    ) -> String? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element,
                  kAXStringForRangeParameterizedAttribute as CFString,
                  parameter,
                  &ref) == .success,
              let string = ref as? String
        else { return nil }
        return string
    }

    /// Safari, Chromium, and Electron expose a document selection through an
    /// opaque AX text-marker range. Passing that range back to the same
    /// element's parameterized string attribute is the supported way to read
    /// it; no private marker decoding or full-document read is needed.
    private static func axSelectedTextMarkerSelection(
        _ element: AXUIElement
    ) -> (text: String, range: CFTypeRef)? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  element,
                  kAXSelectedTextMarkerRangeAttribute as CFString,
                  &markerRange) == .success,
              let markerRange
        else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                  element,
                  kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                  markerRange,
                  &ref) == .success,
              let string = ref as? String
        else { return nil }
        return (string, markerRange)
    }

    private static func axAttributeIsSettable(
        _ element: AXUIElement, _ attr: String
    ) -> Bool {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
                  element, attr as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    /// Elements held by an arbitrary array-valued attribute (windows, rows).
    static func axElements(
        _ element: AXUIElement, _ attribute: String
    ) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement] else { return [] }
        return array
    }

    static func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
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
        case .code, .terminal:
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
            if let site = site(in: segments, appName: appName) {
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
    /// category/mode. Slugs must exist in the engine's `_SITE_CATEGORY`
    /// (contract-tested from pytest against this source file).
    static let siteKeywords: [(needle: String, slug: String)] = [
        ("gmail", "gmail"), ("outlook", "outlook"), ("proton", "proton"),
        ("fastmail", "fastmail"), ("superhuman", "superhuman"),
        ("zoho mail", "zoho"), ("yahoo mail", "yahoo"),
        ("google docs", "gdocs"), ("notion", "notion"), ("obsidian", "obsidian"),
        ("linear", "linear"), ("google keep", "keep"), ("evernote", "evernote"),
        ("onenote", "onenote"), ("confluence", "confluence"),
        ("slack", "slack"), ("discord", "discord"), ("whatsapp", "whatsapp"),
        ("messenger", "messenger"), ("telegram", "telegram"),
        ("microsoft teams", "teams"), ("google chat", "gchat"),
        ("instagram", "instagram"),
    ]

    /// Known web apps keyed by URL host (exact host or any subdomain of it).
    /// The host cannot lie about where the user is, so this outranks the
    /// title keywords — and it covers web apps whose tab titles carry no
    /// product name at all (Notion, Linear, Craft, Coda, HEY).
    static let siteHosts: [(host: String, slug: String)] = [
        ("mail.google.com", "gmail"),
        ("outlook.live.com", "outlook"), ("outlook.office.com", "outlook"),
        ("outlook.office365.com", "outlook"),
        ("mail.proton.me", "proton"),
        ("app.fastmail.com", "fastmail"),
        ("mail.superhuman.com", "superhuman"),
        ("app.hey.com", "hey"),
        ("mail.zoho.com", "zoho"),
        ("mail.yahoo.com", "yahoo"),
        ("docs.google.com", "gdocs"),
        ("notion.so", "notion"), ("notion.site", "notion"),
        ("publish.obsidian.md", "obsidian"),
        ("linear.app", "linear"),
        ("keep.google.com", "keep"),
        ("evernote.com", "evernote"),
        ("onenote.com", "onenote"),
        ("coda.io", "coda"),
        ("craft.do", "craft"),
        ("app.slack.com", "slack"),
        ("discord.com", "discord"),
        ("web.whatsapp.com", "whatsapp"),
        ("messenger.com", "messenger"),
        ("web.telegram.org", "telegram"),
        ("teams.microsoft.com", "teams"), ("teams.live.com", "teams"),
        ("chat.google.com", "gchat"),
        ("instagram.com", "instagram"),
    ]

    /// Slug for a page host, or nil. Suffix-matched so `usw2.notion.so`
    /// still reads as Notion; a bare `www.` is ignored.
    static func siteSlug(forHost rawHost: String?) -> String? {
        guard var host = rawHost?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        for entry in siteHosts
        where host == entry.host || host.hasSuffix("." + entry.host) {
            return entry.slug
        }
        return nil
    }

    /// Browser product names that trail a window title. Chrome and Safari
    /// don't suffix their titles; Firefox and Edge do — and Edge inserts a
    /// zero-width space in "Microsoft Edge".
    private static let browserProductNames: [String] = [
        "google chrome", "chrome", "safari", "mozilla firefox", "firefox",
        "microsoft edge", "edge", "brave", "vivaldi", "opera", "orion",
        "arc", "dia", "zen",
    ]

    /// Detects a known site from the trailing title segment — that's where the
    /// web-app identifier lives ("Inbox - Gmail"). The browser's own trailing
    /// name is dropped first ("… — Mozilla Firefox"), and the candidate must
    /// be short and name-like: scanning long segments let page-content words
    /// hijack the mode ("How to use Gmail").
    static func site(in segments: [String], appName: String?) -> String? {
        func normalized(_ segment: String) -> String {
            segment.replacingOccurrences(of: "\u{200B}", with: "").lowercased()
        }
        func isBrowserish(_ segment: String) -> Bool {
            let value = normalized(segment)
            if let appName, value == appName.lowercased() { return true }
            return browserProductNames.contains { name in
                value == name
                    || value.hasSuffix(" " + name) || value.hasPrefix(name + " ")
            }
        }
        var trailing = segments
        // Cut at the LAST browser-name segment: Chrome with multiple profiles
        // appends "Google Chrome – <profile>", so the browser's name is not
        // necessarily the final segment (seen live: "… - Gmail - Google
        // Chrome – Sushil").
        if let cut = trailing.lastIndex(where: isBrowserish), cut > 0 {
            trailing = Array(trailing[..<cut])
        }
        guard let last = trailing.last.map(normalized),
              last.count <= 34, last.split(separator: " ").count <= 3
        else { return nil }
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

// MARK: - Diagnostics

extension ScreenContext {
    /// Dumps what the accessibility tree actually says around the focused
    /// element, for `velora ax-probe`.
    ///
    /// This exists because the verification step kept reading the wrong node in
    /// Slack's quick switcher, and guessing attribute names from documentation
    /// was costing whole build/install cycles per guess. Read the tree, then
    /// write the code.
    static func axDump(of app: NSRunningApplication?) -> [String: Any] {
        guard let app, app.processIdentifier > 0, Permissions.accessibilityGranted else {
            return ["error": "no app or no accessibility permission"]
        }
        var out: [String: Any] = [
            "app": app.localizedName ?? "?",
            "bundle": app.bundleIdentifier ?? "?",
        ]
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        out["pid"] = Int(app.processIdentifier)
        // Raw AXError codes: when an app yields no window, the code says WHY
        // (-25204 not responding, -25205 unsupported, -25211 API disabled…).
        var focusedRef: CFTypeRef?
        out["focused_window_error"] = Int(AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedRef).rawValue)
        var windowsRef: CFTypeRef?
        out["windows_error"] = Int(AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef).rawValue)
        out["windows_count"] = (windowsRef as? [AXUIElement])?.count ?? -1
        out["enable_error"] = Int(AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)
        out["enable_eui_error"] = Int(AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)
        var retryRef: CFTypeRef?
        out["focused_window_error_after_enable"] = Int(AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &retryRef).rawValue)
        if let window = axElement(appElement, kAXFocusedWindowAttribute) {
            out["window_title"] = axString(window, kAXTitleAttribute) ?? ""
            out["window_document"] = axURLString(window, kAXDocumentAttribute) ?? ""
        }
        if let bundleID = app.bundleIdentifier?.lowercased(),
           BrowserPage.usesAppleScript(bundleID) {
            out["automation_status"] = BrowserPage.permissionStatus(bundleID: bundleID)
            let read = BrowserPage.debugRead(bundleID: bundleID)
            out["ae_read_error"] = read.code
            out["ae_read_url"] = read.url
        }
        // Client-vs-pair isolation: a trivial event to Finder. -1743 here too
        // means this process cannot send ANY Apple Event; a script error like
        // -1728 or a name string means delivery works and the block is
        // target-specific.
        out["ae_finder_status"] = BrowserPage.permissionStatus(bundleID: "com.apple.finder")
        out["ae_finder_probe"] = BrowserPage.debugProbeFinder()
        // Which targets refuse: browsers vs ordinary apps.
        out["ae_pair_status"] = [
            "chrome": BrowserPage.permissionStatus(bundleID: "com.google.chrome"),
            "safari": BrowserPage.permissionStatus(bundleID: "com.apple.safari"),
            "zen": BrowserPage.permissionStatus(bundleID: "app.zen-browser.zen"),
            "notes": BrowserPage.permissionStatus(bundleID: "com.apple.notes"),
            "slack": BrowserPage.permissionStatus(bundleID: "com.tinyspeck.slackmacgap"),
        ]
        out["page_url"] = pageURL(of: app, deep: true)?.absoluteString ?? ""
        guard let focused = axElement(appElement, kAXFocusedUIElementAttribute) else {
            out["focused"] = "none"
            return out
        }
        AXUIElementSetMessagingTimeout(focused, 1.0)
        out["focused"] = describe(focused)

        // Every attribute the focused element actually exposes, so relation
        // names never have to be guessed again.
        var namesRef: CFArray?
        if AXUIElementCopyAttributeNames(focused, &namesRef) == .success,
           let names = namesRef as? [String] {
            out["focused_attributes"] = names
            var relations: [String: Any] = [:]
            for name in names where name.hasPrefix("AX") {
                let related = axElements(focused, name)
                guard !related.isEmpty else { continue }
                relations[name] = related.prefix(4).map { element -> [String: Any] in
                    var entry = describe(element)
                    entry["subtree_text"] = subtreeText(element, depth: 4)
                    return entry
                }
            }
            out["focused_relations"] = relations
        }
        return out
    }

    private static func describe(_ element: AXUIElement) -> [String: Any] {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var entry: [String: Any] = [:]
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                          kAXDescriptionAttribute, kAXValueAttribute,
                          kAXPlaceholderValueAttribute, kAXRoleDescriptionAttribute] {
            if let value = axString(element, attribute), !value.isEmpty {
                entry[attribute] = String(value.prefix(120))
            }
        }
        entry["children"] = (axChildren(element) ?? []).count
        return entry
    }

    /// Flattened app-authored text under an element, so a row's real label is
    /// visible even when it lives several nodes down.
    private static func subtreeText(_ element: AXUIElement, depth: Int) -> [String] {
        var found: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let value = axString(element, attribute),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(String(value.prefix(80)))
            }
        }
        guard depth > 0 else { return found }
        for child in (axChildren(element) ?? []).prefix(10) {
            found.append(contentsOf: subtreeText(child, depth: depth - 1))
            if found.count >= 25 { break }
        }
        return found
    }
}
