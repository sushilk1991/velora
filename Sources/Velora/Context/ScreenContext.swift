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

/// A closed same-control postcondition for one background AXPress.
enum ScreenAXReadback: Equatable {
    case selected(Bool)
    case expanded(Bool)
    case stringValue(String)
    case numberValue(Double)
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
    struct AXIdentityGuard {
        private var buckets: [CFHashCode: [AXUIElement]] = [:]

        mutating func insert(_ element: AXUIElement) -> Bool {
            let hash = CFHash(element)
            if buckets[hash]?.contains(where: {
                CFEqual($0, element)
            }) == true {
                return false
            }

            // CFHash narrows candidates; CFEqual handles hash collisions.
            buckets[hash, default: []].append(element)
            return true
        }
    }

    /// Merges the three native window sources without treating the same AX
    /// identity as multiple matches. The caller owns the exact-match policy.
    private static func uniqueAXWindow(
        windows: [AXUIElement],
        focused: AXUIElement?,
        main: AXUIElement?,
        matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var candidates = windows
        if let focused {
            candidates.append(focused)
        }
        if let main {
            candidates.append(main)
        }

        var identities = AXIdentityGuard()
        var match: AXUIElement?
        for candidate in candidates {
            guard identities.insert(candidate), matches(candidate) else {
                continue
            }
            guard match == nil else {
                return nil
            }
            match = candidate
        }
        return match
    }

    private enum BackgroundElementUse {
        case press
        case readback
    }

    private enum BackgroundTitleMatch {
        case exact
        case observation
    }

    /// Max entities returned; keeps the prompt/vocabulary bounded.
    private static let maxEntities = 4
    /// Electron applications commonly nest the useful editable surface under
    /// several layers of web containers. Slack's visible composer is depth 23;
    /// this remains bounded by the independent node and wall-clock ceilings.
    static let actionTreeDepthBudget = 30
    static let actionSnapshotDeadline: TimeInterval = 2
    private static let backgroundFrameTolerance: CGFloat = 1
    private static let backgroundAncestorLimit = 64
    private static let backgroundReadAttempts = 5
    private static let backgroundReadInterval: TimeInterval = 0.05
    private static let editableActionRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    static func isEditableActionRole(_ role: String) -> Bool {
        editableActionRoles.contains(role)
    }

    /// The model may invoke only capabilities the executor implements. Many
    /// Electron nodes advertise AXShowMenu/AXScrollToVisible even when they are
    /// passive prose; forwarding them bloats the semantic tree and invents no
    /// usable action.
    static func modelActionNames(from actions: [String]) -> [String] {
        let available = Set(actions)
        return ["AXFocus", kAXPressAction as String].filter {
            available.contains($0)
        }
    }

    /// One generic, bounded projection of the focused window's AX tree for
    /// Action Mode. It deliberately preserves hierarchy, geometry, roles and
    /// supported actions instead of flattening the screen into a bag of names.
    /// Values are excluded: editable values may contain text the action just
    /// typed, and feeding them back would let the model self-confirm a target.
    static func actionUISnapshot(
        of app: NSRunningApplication?,
        nodeBudget: Int = 500,
        depthBudget: Int = actionTreeDepthBudget,
        deadline: TimeInterval = actionSnapshotDeadline
    ) -> ScreenActionUISnapshot? {
        guard nodeBudget > 0, let app, app.processIdentifier > 0,
              Permissions.accessibilityGranted else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let window = focusedOrFirstWindow(
            appElement, pid: app.processIdentifier) else { return nil }
        // One identity read is enough to annotate the whole tree. Reading
        // AXFocused separately on every node would add avoidable IPC latency.
        let focusedElement = axElement(appElement, kAXFocusedUIElementAttribute)

        return makeActionSnapshot(
            app: app, appElement: appElement, window: window,
            windowID: nil, windowTitle: axString(
                window, kAXTitleAttribute) ?? "",
            focusedElement: focusedElement, nodeBudget: nodeBudget,
            depthBudget: depthBudget, deadline: deadline)
    }

    /// Resolve one WindowServer lease to one AXWindow without activating or
    /// focusing its process. Title and bounds are both required because AX has
    /// no public attribute carrying the CGWindowID.
    static func backgroundActionUISnapshot(
        pid: Int,
        windowID: Int,
        windowTitle: String,
        windowBounds: CGRect,
        nodeBudget: Int = 500,
        depthBudget: Int = actionTreeDepthBudget,
        deadline: TimeInterval = actionSnapshotDeadline
    ) -> ScreenActionUISnapshot? {
        guard pid > 0, windowID > 0, nodeBudget > 0,
              depthBudget >= 0, deadline > 0,
              validWindowFrame(windowBounds),
              Permissions.accessibilityGranted,
              let app = NSRunningApplication(
                processIdentifier: pid_t(pid)),
              !app.isTerminated,
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              !bundleID.isEmpty
        else { return nil }
        let appElement = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard windowServerMatches(
                windowID: windowID, pid: pid,
                title: windowTitle, titleMatch: .exact,
                frame: windowBounds),
              let window = uniqueBackgroundWindow(
                appElement: appElement, pid: pid,
                title: windowTitle, titleMatch: .exact,
                frame: windowBounds)
        else { return nil }

        let focused = axElement(appElement, kAXFocusedUIElementAttribute)
            .flatMap { belongsToWindow($0, window: window) ? $0 : nil }
        return makeActionSnapshot(
            app: app, appElement: appElement, window: window,
            windowID: windowID, windowTitle: windowTitle,
            focusedElement: focused, nodeBudget: nodeBudget,
            depthBudget: depthBudget, deadline: deadline)
    }

    /// Perform AXPress against one exact retained native control. Prefer a
    /// same-control state transition. A control without one returns only that
    /// the exact noncommitting AX action was accepted; the routing host binds
    /// its effect to the next complete native tree before goal verification.
    static func backgroundPress(
        index: Int,
        expecting expected: ScreenAXReadback?,
        in snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard let (_, element) = backgroundElement(
                index: index, in: snapshot, use: .press)
        else { return false }
        if let expected {
            return backgroundStatePress(
                element, index: index, expected: expected, in: snapshot)
        }
        return AXUIElementPerformAction(
            element, kAXPressAction as CFString) == .success
    }

    private static func backgroundStatePress(
        _ element: AXUIElement,
        index: Int,
        expected: ScreenAXReadback,
        in snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard validReadback(expected),
              let before = readback(expected, from: element),
              before != expected,
              AXUIElementPerformAction(
                element, kAXPressAction as CFString) == .success
        else { return false }

        for attempt in 0..<backgroundReadAttempts {
            if let (_, current) = backgroundElement(
                    index: index, in: snapshot, use: .readback),
               readback(expected, from: current) == expected {
                return true
            }
            if attempt + 1 < backgroundReadAttempts {
                Thread.sleep(forTimeInterval: backgroundReadInterval)
            }
        }
        return false
    }

    /// Replace the exact AXValue and prove it with a fresh read from the same
    /// retained native control. Cursor-relative insertion is intentionally not
    /// offered because it would require focus or synthesized keyboard input.
    static func backgroundWriteValue(
        _ value: String,
        replacing expected: String,
        index: Int,
        in snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard let (record, element) = backgroundElement(
                index: index, in: snapshot, use: .readback),
              isEditableActionRole(record.role),
              axAttributeIsSettable(element, kAXValueAttribute),
              let before = axRawString(element, kAXValueAttribute),
              before == expected, before != value,
              AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString,
                value as CFString) == .success
        else { return false }

        for attempt in 0..<backgroundReadAttempts {
            if let (_, current) = backgroundElement(
                    index: index, in: snapshot, use: .readback),
               axRawString(current, kAXValueAttribute) == value {
                return true
            }
            if attempt + 1 < backgroundReadAttempts {
                Thread.sleep(forTimeInterval: backgroundReadInterval)
            }
        }
        return false
    }

    static func backgroundValueEquals(
        _ value: String,
        index: Int,
        in snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard let (record, element) = backgroundElement(
                index: index, in: snapshot, use: .readback),
              isEditableActionRole(record.role)
        else { return false }
        return axRawString(element, kAXValueAttribute) == value
    }

    static func restoreActionWindow(
        _ target: ActionWindowIdentity,
        allowed: () -> Bool
    ) -> Bool {
        guard target.pid > 0, target.windowID > 0,
              let expectedProcess = target.processIdentity,
              CuaProcessIdentity.capture(pid: pid_t(target.pid))
                == expectedProcess,
              Permissions.accessibilityGranted,
              let app = NSRunningApplication(
                processIdentifier: pid_t(target.pid)),
              !app.isTerminated, app.activationPolicy == .regular,
              app.bundleIdentifier?.caseInsensitiveCompare(target.bundleID)
                == .orderedSame,
              let lease = restoreWindowLease(target),
              let window = uniqueBackgroundWindow(
                appElement: lease.appElement, pid: target.pid,
                title: lease.title, titleMatch: .exact,
                frame: lease.frame),
              allowed()
        else { return false }

        // AXRaise selects the exact prior window within its process. AppKit
        // then restores that process to the foreground; neither step guesses
        // from the app name or accepts a sibling window.
        guard AXUIElementPerformAction(
                window, kAXRaiseAction as CFString) == .success,
              allowed() else { return false }
        let activated = runOnMain {
            guard allowed() else { return false }
            NSApp.yieldActivation(to: app)
            return app.activate(options: [])
        }
        guard activated else { return false }

        for attempt in 0..<backgroundReadAttempts {
            guard allowed(),
                  CuaProcessIdentity.capture(pid: pid_t(target.pid))
                    == expectedProcess else { return false }
            if actionWindowIsFront(target) {
                return true
            }
            if attempt + 1 < backgroundReadAttempts {
                Thread.sleep(forTimeInterval: backgroundReadInterval)
            }
        }
        return false
    }

    private struct RestoreWindowLease {
        let appElement: AXUIElement
        let title: String
        let frame: CGRect
    }

    private static func restoreWindowLease(
        _ target: ActionWindowIdentity
    ) -> RestoreWindowLease? {
        guard let rows = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], CGWindowID(target.windowID))
                as? [[String: Any]],
              let row = rows.first(where: {
                  ($0[kCGWindowNumber as String] as? Int) == target.windowID
                      && ($0[kCGWindowOwnerPID as String] as? Int) == target.pid
                      && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let rawBounds = row[kCGWindowBounds as String]
                as? [String: Any],
              let frame = CGRect(
                dictionaryRepresentation: rawBounds as CFDictionary),
              validWindowFrame(frame)
        else { return nil }
        let appElement = AXUIElementCreateApplication(pid_t(target.pid))
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        return RestoreWindowLease(
            appElement: appElement,
            title: row[kCGWindowName as String] as? String ?? "",
            frame: frame)
    }

    private static func actionWindowIsFront(
        _ target: ActionWindowIdentity
    ) -> Bool {
        let front = runOnMain { NSWorkspace.shared.frontmostApplication }
        guard front?.processIdentifier == pid_t(target.pid),
              front?.bundleIdentifier?.caseInsensitiveCompare(target.bundleID)
                == .orderedSame,
              let rows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                CGWindowID(kCGNullWindowID)) as? [[String: Any]],
              let first = rows.first(where: {
                  ($0[kCGWindowLayer as String] as? Int) == 0
              })
        else { return false }
        return (first[kCGWindowOwnerPID as String] as? Int) == target.pid
            && (first[kCGWindowNumber as String] as? Int) == target.windowID
    }

    private static func runOnMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private static func makeActionSnapshot(
        app: NSRunningApplication,
        appElement: AXUIElement,
        window: AXUIElement,
        windowID: Int?,
        windowTitle: String,
        focusedElement: AXUIElement?,
        nodeBudget: Int,
        depthBudget: Int,
        deadline: TimeInterval
    ) -> ScreenActionUISnapshot? {
        let stopAt = Date().addingTimeInterval(deadline)
        var queue: [(element: AXUIElement, parent: Int?, depth: Int)] = [
            (window, nil, 0),
        ]
        var records: [ActionUIElement] = []
        var references: [Int: AXUIElement] = [:]
        var nextIndex = 0
        var truncated = false
        var visited = AXIdentityGuard()

        while !queue.isEmpty {
            guard Date() < stopAt else {
                truncated = true
                break
            }
            let item = queue.removeFirst()
            guard visited.insert(item.element) else { continue }
            guard records.count < nodeBudget else {
                truncated = true
                break
            }
            let index = nextIndex
            nextIndex += 1
            AXUIElementSetMessagingTimeout(item.element, 0.2)
            let focused = focusedElement.map {
                CFEqual($0, item.element)
            } ?? false
            records.append(actionUIRecord(
                item.element,
                index: index,
                parentIndex: item.parent,
                depth: item.depth,
                focused: focused))
            references[index] = item.element

            let children = axChildren(item.element) ?? []
            if item.depth >= depthBudget {
                if !children.isEmpty { truncated = true }
                continue
            }
            for child in children.prefix(60) {
                queue.append((child, index, item.depth + 1))
            }
            if children.count > 60 { truncated = true }
        }

        if let focusedElement,
           !references.values.contains(where: { CFEqual($0, focusedElement) }) {
            AXUIElementSetMessagingTimeout(focusedElement, 0.2)
            let focusedRecord = actionUIRecord(
                focusedElement, index: nextIndex, parentIndex: nil,
                depth: 0, focused: true)
            if retainFocusedRecord(
                focusedRecord, reference: focusedElement,
                nodeBudget: nodeBudget, records: &records,
                references: &references) {
                truncated = true
            }
        }

        var pressReadbacks: [Int: ScreenAXReadback] = [:]
        var writeBaselines: [Int: String] = [:]
        if windowID != nil {
            records = records.map { record in
                guard let element = references[record.index] else {
                    return record
                }
                if isEditableActionRole(record.role), record.enabled,
                   !record.inWebContent,
                   axAttributeIsSettable(element, kAXValueAttribute),
                   let value = axRawString(element, kAXValueAttribute) {
                    writeBaselines[record.index] = value
                }
                let readback = pressReadback(for: element)
                if let readback { pressReadbacks[record.index] = readback }
                let actions = record.actions.filter {
                    $0 != ActionUICapability.axFocus
                }
                guard actions != record.actions else {
                    return record
                }
                return ActionUIElement(
                    index: record.index, parentIndex: record.parentIndex,
                    depth: record.depth, role: record.role,
                    label: record.label, frame: record.frame,
                    actions: actions,
                    enabled: record.enabled, selected: record.selected,
                    focused: record.focused,
                    inWebContent: record.inWebContent)
            }
        }

        let observation = ActionUISnapshot(
            id: UUID().uuidString,
            appName: app.localizedName ?? "",
            bundleID: app.bundleIdentifier ?? "",
            windowTitle: String(windowTitle.prefix(180)),
            windowID: windowID,
            complete: !truncated && queue.isEmpty,
            elements: records)
        return ScreenActionUISnapshot(
            observation: observation,
            applicationElement: appElement,
            focusedWindow: window,
            elementsByIndex: references,
            pressReadbacks: pressReadbacks,
            writeBaselines: writeBaselines)
    }

    private static func backgroundElement(
        index: Int,
        in snapshot: ScreenActionUISnapshot,
        use: BackgroundElementUse
    ) -> (ActionUIElement, AXUIElement)? {
        guard backgroundWindowIsCurrent(snapshot),
              let record = snapshot.observation.elements.first(where: {
                $0.index == index
              }),
              let element = snapshot.elementsByIndex[index],
              belongsToWindow(element, window: snapshot.focusedWindow),
              axString(element, kAXRoleAttribute) == record.role,
              axBool(element, kAXEnabledAttribute) != false
        else { return nil }
        var appPID = pid_t(0)
        var elementPID = pid_t(0)
        guard AXUIElementGetPid(
                snapshot.applicationElement, &appPID) == .success,
              AXUIElementGetPid(element, &elementPID) == .success,
              appPID > 0, appPID == elementPID
        else { return nil }
        let authored = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXPlaceholderValueAttribute),
        ].compactMap { $0 }
        let actions = modelActionNames(from: axActionNames(element))
        let label = actionUILabel(
            role: record.role, authored: authored, actions: actions)
        guard AppMatcher.normalize(label ?? "")
                == AppMatcher.normalize(record.label ?? "")
        else { return nil }
        if case .press = use {
            guard let label = record.label, !label.isEmpty,
                  actions.contains(kAXPressAction as String),
                  !ActionPlan.pressLabelIsCommitting(label)
            else { return nil }
        }
        return (record, element)
    }

    private static func backgroundWindowIsCurrent(
        _ snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard snapshot.observation.source == .native,
              let windowID = snapshot.observation.windowID,
              windowID > 0,
              !snapshot.observation.bundleID.isEmpty,
              let root = snapshot.observation.elements.first(where: {
                $0.parentIndex == nil && $0.depth == 0
              }),
              let rootElement = snapshot.elementsByIndex[root.index],
              CFEqual(rootElement, snapshot.focusedWindow),
              let frame = root.frame,
              validWindowFrame(frame)
        else { return false }
        var pid = pid_t(0)
        guard AXUIElementGetPid(
                snapshot.applicationElement, &pid) == .success,
              pid > 0,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated,
              app.bundleIdentifier?.caseInsensitiveCompare(
                snapshot.observation.bundleID) == .orderedSame,
              windowServerMatches(
                windowID: windowID, pid: Int(pid),
                title: snapshot.observation.windowTitle,
                titleMatch: .observation, frame: frame),
              let current = uniqueBackgroundWindow(
                appElement: snapshot.applicationElement, pid: Int(pid),
                title: snapshot.observation.windowTitle,
                titleMatch: .observation, frame: frame),
              CFEqual(current, snapshot.focusedWindow)
        else { return false }
        return true
    }

    private static func uniqueBackgroundWindow(
        appElement: AXUIElement,
        pid: Int,
        title: String,
        titleMatch: BackgroundTitleMatch,
        frame: CGRect
    ) -> AXUIElement? {
        let windows = axElements(appElement, kAXWindowsAttribute)
        let focused = axElement(appElement, kAXFocusedWindowAttribute)
        let main = axElement(appElement, kAXMainWindowAttribute)
        return uniqueAXWindow(
            windows: windows, focused: focused, main: main
        ) {
            var ownerPID = pid_t(0)
            return AXUIElementGetPid($0, &ownerPID) == .success
                && ownerPID == pid_t(pid)
                && axRawString($0, kAXTitleAttribute).map {
                    windowTitlesMatch($0, title, mode: titleMatch)
                } == true
                && axFrame($0).map { windowFramesMatch($0, frame) } == true
        }
    }

    private static func windowServerMatches(
        windowID: Int,
        pid: Int,
        title: String,
        titleMatch: BackgroundTitleMatch,
        frame: CGRect
    ) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], CGWindowID(windowID))
                as? [[String: Any]],
              let row = rows.first(where: {
                ($0[kCGWindowNumber as String] as? Int) == windowID
                    && ($0[kCGWindowOwnerPID as String] as? Int) == pid
                    && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let rawBounds = row[kCGWindowBounds as String]
                as? [String: Any],
              let bounds = CGRect(
                dictionaryRepresentation: rawBounds as CFDictionary),
              windowFramesMatch(bounds, frame)
        else { return false }
        if let currentTitle = row[kCGWindowName as String] as? String {
            return windowTitlesMatch(
                currentTitle, title, mode: titleMatch)
        }
        return true
    }

    private static func windowTitlesMatch(
        _ current: String,
        _ expected: String,
        mode: BackgroundTitleMatch
    ) -> Bool {
        if case .exact = mode { return current == expected }
        guard expected.count == 180 else { return current == expected }
        return current.hasPrefix(expected)
    }

    private static func belongsToWindow(
        _ element: AXUIElement,
        window: AXUIElement
    ) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<backgroundAncestorLimit {
            guard let candidate = current else { return false }
            if CFEqual(candidate, window) { return true }
            current = axElement(candidate, kAXParentAttribute)
        }
        return false
    }

    private static func validWindowFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private static func windowFramesMatch(
        _ first: CGRect,
        _ second: CGRect
    ) -> Bool {
        abs(first.minX - second.minX) <= backgroundFrameTolerance
            && abs(first.minY - second.minY) <= backgroundFrameTolerance
            && abs(first.width - second.width) <= backgroundFrameTolerance
            && abs(first.height - second.height) <= backgroundFrameTolerance
    }

    private static func validReadback(_ value: ScreenAXReadback) -> Bool {
        guard case .numberValue(let number) = value else { return true }
        return number.isFinite
    }

    private static func pressReadback(
        for element: AXUIElement
    ) -> ScreenAXReadback? {
        if let selected = axBool(element, kAXSelectedAttribute) {
            return .selected(!selected)
        }
        if let expanded = axBool(element, kAXExpandedAttribute) {
            return .expanded(!expanded)
        }
        return nil
    }

    private static func readback(
        _ expected: ScreenAXReadback,
        from element: AXUIElement
    ) -> ScreenAXReadback? {
        switch expected {
        case .selected:
            return axBool(element, kAXSelectedAttribute).map {
                .selected($0)
            }
        case .expanded:
            return axBool(element, kAXExpandedAttribute).map {
                .expanded($0)
            }
        case .stringValue:
            return axRawString(element, kAXValueAttribute).map {
                .stringValue($0)
            }
        case .numberValue:
            return axNumber(element, kAXValueAttribute).map {
                .numberValue($0)
            }
        }
    }

    private static func actionUIRecord(
        _ element: AXUIElement,
        index: Int,
        parentIndex: Int?,
        depth: Int,
        focused: Bool
    ) -> ActionUIElement {
        let role = axString(element, kAXRoleAttribute) ?? "AXUnknown"
        let authored = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXPlaceholderValueAttribute),
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var rawActions = axActionNames(element)
        if isEditableActionRole(role) {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                element, kAXFocusedAttribute as CFString,
                &settable) == .success, settable.boolValue {
                rawActions.append("AXFocus")
            }
        }
        let actions = modelActionNames(from: rawActions)
        let label = actionUILabel(
            role: role, authored: authored, actions: actions)
        let selected = label != nil
            && axBool(element, kAXSelectedAttribute) == true
        return ActionUIElement(
            index: index, parentIndex: parentIndex, depth: depth,
            role: role, label: label, frame: axFrame(element),
            actions: actions, selected: selected, focused: focused)
    }

    /// Keeps affirmative focus evidence inside the model cap. A late focused
    /// element replaces the last BFS record; callers mark that tree partial.
    static func retainFocusedRecord(
        _ record: ActionUIElement,
        reference: AXUIElement,
        nodeBudget: Int,
        records: inout [ActionUIElement],
        references: inout [Int: AXUIElement]
    ) -> Bool {
        if references.values.contains(where: { CFEqual($0, reference) }) {
            return false
        }
        guard nodeBudget > 0 else { return false }
        if records.count >= nodeBudget, let displaced = records.popLast() {
            references.removeValue(forKey: displaced.index)
        }
        records.append(record)
        references[record.index] = reference
        return true
    }

    /// Project authored AX labels into the model-facing interaction tree.
    /// Capabilities and editable/structural controls retain their labels;
    /// passive prose is kept only when it is short enough to plausibly be a
    /// name, tab, or status. This is app-agnostic and prevents long document or
    /// message bodies from dominating every planning turn. AXValue remains
    /// excluded entirely so an action cannot verify text it just typed.
    static func actionUILabel(
        role: String,
        authored: [String],
        actions: [String]
    ) -> String? {
        var seen = Set<String>()
        let label = authored
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter {
                seen.insert($0.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current)).inserted
            }
            .joined(separator: " ")
        guard !label.isEmpty else { return nil }

        let labelledControlRoles: Set<String> = [
            kAXWindowRole as String,
            kAXSheetRole as String,
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        let interactive = !actions.isEmpty || labelledControlRoles.contains(role)
        let wordCount = label.split(whereSeparator: \.isWhitespace).count
        guard interactive || (label.count <= 80 && wordCount <= 8) else {
            return nil
        }
        return String(label.prefix(180))
    }

    /// Perform the exact AX action selected from `actionUISnapshot`. The
    /// caller owns freshness and app/window identity; this method proves the
    /// referenced object still exposes AXPress and refuses committing labels.
    /// Editable controls are focused by exact AX identity; they are never sent
    /// coordinates and the caller must observe again before typing.
    static func pressActionElement(
        index: Int,
        in snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard focusedWindowIsCurrent(snapshot),
              let record = snapshot.observation.elements.first(where: {
            $0.index == index
        }),
              let element = snapshot.elementsByIndex[index],
              !ActionPlan.pressLabelIsCommitting(record.label ?? "")
        else { return false }
        let role = axString(element, kAXRoleAttribute) ?? "AXUnknown"
        guard role == record.role else { return false }
        let authored = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXPlaceholderValueAttribute),
        ].compactMap { $0 }
        var rawActions = axActionNames(element)
        if isEditableActionRole(role) {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                element, kAXFocusedAttribute as CFString,
                &settable) == .success, settable.boolValue {
                rawActions.append("AXFocus")
            }
        }
        let currentActions = modelActionNames(from: rawActions)
        let currentLabel = actionUILabel(
            role: role, authored: authored, actions: currentActions)
        guard AppMatcher.normalize(currentLabel ?? "")
                == AppMatcher.normalize(record.label ?? "") else { return false }
        guard isEditableActionRole(record.role) else {
            return currentActions.contains(kAXPressAction as String)
                && AXUIElementPerformAction(
                    element, kAXPressAction as CFString) == .success
        }
        guard currentActions.contains("AXFocus") else { return false }

        // AXFocused is the generic Accessibility capability for that exact
        // editable element. Do not also AXPress it: combo boxes may interpret
        // AXPress as expansion rather than focus.
        let focused = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        guard focused else { return false }
        for attempt in 0..<5 {
            if let current = axElement(
                snapshot.applicationElement, kAXFocusedUIElementAttribute),
               CFEqual(current, element) {
                return true
            }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return false
    }

    static func verifyActionElement(
        index: Int,
        label: String,
        role: String,
        target: String,
        in snapshot: ScreenActionUISnapshot,
        purpose: ActionVerificationPurpose
    ) -> Bool {
        guard focusedWindowIsCurrent(snapshot),
              snapshot.observation.elements.contains(where: {
            $0.index == index
        }),
              let element = snapshot.elementsByIndex[index],
              axString(element, kAXRoleAttribute) == role else { return false }
        switch purpose {
        case .target:
            guard snapshot.observation.source == .native,
                  !snapshot.observation.bundleID.isEmpty,
                  !snapshot.observation.windowTitle.isEmpty
                    || snapshot.observation.windowID != nil,
                  isEditableActionRole(role),
                  let focused = axElement(
                    snapshot.applicationElement, kAXFocusedUIElementAttribute),
                  CFEqual(focused, element) else { return false }
        case .goal:
            guard snapshot.observation.complete,
                  let currentElements = currentGoalElements(in: snapshot),
                  ActionUIEvidencePolicy.mayVerifyGoal(
                    index: index, source: .native, in: currentElements)
            else { return false }
        }
        let authored = [
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXPlaceholderValueAttribute),
        ].compactMap { $0 }
        let currentLabel = actionUILabel(
            role: role, authored: authored,
            actions: modelActionNames(from: axActionNames(element)))
        guard AppMatcher.normalize(currentLabel ?? "")
                == AppMatcher.normalize(label) else { return false }
        if purpose == .target {
            return AppMatcher.bestMatch(for: target, in: [label]) != nil
        }
        return true
    }

    private static func currentGoalElements(
        in snapshot: ScreenActionUISnapshot
    ) -> [ActionUIElement]? {
        let focused = axElement(
            snapshot.applicationElement, kAXFocusedUIElementAttribute)
        var elements: [ActionUIElement] = []
        elements.reserveCapacity(snapshot.observation.elements.count)

        for record in snapshot.observation.elements {
            guard let reference = snapshot.elementsByIndex[record.index] else {
                return nil
            }
            elements.append(actionUIRecord(
                reference, index: record.index,
                parentIndex: record.parentIndex, depth: record.depth,
                focused: focused.map { CFEqual($0, reference) } ?? false))
        }
        return elements
    }

    private static func focusedWindowIsCurrent(
        _ snapshot: ScreenActionUISnapshot
    ) -> Bool {
        guard let current = axElement(
            snapshot.applicationElement, kAXFocusedWindowAttribute) else {
            return false
        }
        return CFEqual(current, snapshot.focusedWindow)
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

    /// Legacy fallback for an app that cannot produce a structured snapshot.
    /// Finds the labelled control and performs only an AXPress action. New
    /// plans address an exact index from `actionUISnapshot` instead.
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
                if press(element) { return true }
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
                    if press(candidate) { return true }
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

    /// Accessibility itself is the capability boundary: the target must
    /// expose AXPress. App names and app-specific role tables are irrelevant.
    private static func press(_ element: AXUIElement) -> Bool {
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
              let focused = focusedElement(of: app) else { return nil }
        return keystrokeStreamTarget(
            bundleID: bundleID, element: focused)
    }

    /// Captures only the already-verified AX object, never a fresh generic
    /// focus lookup that could resolve to another field after verification.
    static func keystrokeStreamTarget(
        bundleID: String,
        element: AXUIElement
    ) -> ScreenKeystrokeStreamTarget? {
        let app = NSWorkspace.shared.frontmostApplication
        guard let focused = focusedElement(of: app),
              keystrokeTargetMatches(
                bundleID: bundleID, element: element,
                currentBundleID: app?.bundleIdentifier,
                currentElement: focused),
              let role = axString(element, kAXRoleAttribute),
              axParameterizedAttributeIsAvailable(
                element, kAXStringForRangeParameterizedAttribute)
        else { return nil }

        let selectedRange = axRange(element, kAXSelectedTextRangeAttribute)
        let selectedText = axRawString(element, kAXSelectedTextAttribute)
        guard let selectedRange, selectedRange.location >= 0 else { return nil }
        guard KeystrokeStreamTargetPolicy.mayCapture(
            role: role,
            editabilityProven:
                axAttributeIsSettable(element, kAXValueAttribute)
                || axBool(element, kAXIsEditableAttribute) == true
                || axElement(
                    element, kAXEditableAncestorAttribute) != nil
                || axElement(
                    element, kAXHighestEditableAncestorAttribute) != nil,
            selectedRangeLength: selectedRange.length,
            selectedText: selectedText)
        else { return nil }
        return ScreenKeystrokeStreamTarget(
            bundleID: bundleID,
            element: element,
            location: selectedRange.location,
            boundary: selectionBoundary(of: element))
    }

    /// Pure identity seam shared by runtime ownership and the selftest.
    static func keystrokeTargetMatches(
        bundleID: String,
        element: AXUIElement,
        currentBundleID: String?,
        currentElement: AXUIElement?
    ) -> Bool {
        guard currentBundleID == bundleID, let currentElement else { return false }
        return CFEqual(currentElement, element)
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
        let focused = focusedElement(of: app)
        guard keystrokeTargetMatches(
            bundleID: target.bundleID, element: target.element,
            currentBundleID: app?.bundleIdentifier,
            currentElement: focused),
              let range = axRange(
                target.element, kAXSelectedTextRangeAttribute),
              range.location == target.location + draft.utf16.count,
              range.length == 0
        else { return false }
        if draft.isEmpty { return true }
        return axStringForRange(
            target.element,
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

    private static func axActionNames(_ element: AXUIElement) -> [String] {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFArray?
        guard AXUIElementCopyActionNames(element, &ref) == .success,
              let actions = ref as? [String] else { return [] }
        return actions.sorted()
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite,
              size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: point, size: size)
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

    private static func axNumber(
        _ element: AXUIElement, _ attr: String
    ) -> Double? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attr as CFString, &ref) == .success,
              let number = ref as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
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
        let uiStarted = ProcessInfo.processInfo.systemUptime
        if let snapshot = actionUISnapshot(of: app) {
            out["action_ui_snapshot"] = [
                "id": snapshot.observation.id,
                "complete": snapshot.observation.complete,
                "elements": snapshot.observation.elements.count,
                "ms": Int((ProcessInfo.processInfo.systemUptime - uiStarted) * 1_000),
            ]
        }
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
