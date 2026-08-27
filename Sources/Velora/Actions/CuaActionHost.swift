import AppKit
import ApplicationServices
import Foundation

/// Pure decision logic for when an Action routes to the background driver.
/// Kept free of AppKit so the selftest exercises the full matrix.
enum BackgroundActionGate {
    /// Background routing is for "do this over there while I keep working":
    /// the target must be a DIFFERENT app from the one the user is in, and it
    /// must be one whose background semantics we trust.
    ///
    /// Content mutations stay here only when Cua proves an exact complete
    /// non-web target. Browsers remain excluded because web content does not
    /// honor AX value writes reliably (the driver reports them "unverifiable").
    static func shouldRoute(enabled: Bool,
                            contentMayCommit _: Bool,
                            targetName: String,
                            targetBundleID: String,
                            frontmostName: String?,
                            frontmostBundleID: String?) -> Bool {
        guard enabled else { return false }
        if ActionRuntimePolicy.isBrowserBundle(targetBundleID) { return false }
        // Fail closed: if what the user is using cannot be read, nothing may
        // be driven "in the background" of it (review finding — a transient
        // nil frontmost must not disable the same-app guard).
        guard let frontmostBundleID, let frontmostName else { return false }
        // Exact bundle identity first; the fuzzy name check stays as depth
        // against a driver/AppKit display-name mismatch, but the bundle
        // comparison is the guard (review finding — bestMatch is asymmetric
        // and can miss "Visual Studio Code" vs "Code").
        if targetBundleID.lowercased() == frontmostBundleID.lowercased() {
            return false
        }
        if AppMatcher.bestMatch(for: targetName, in: [frontmostName]) != nil {
            return false
        }
        return true
    }
}

/// One AX element from a driver window snapshot.
struct CuaElement: Equatable {
    let index: Int
    let token: String?
    let role: String
    let label: String?
    let value: String?
    let parentIndex: Int?
    let depth: Int
    let frame: CGRect?
    let enabled: Bool
    let selected: Bool
    let inWebContent: Bool

    init(index: Int, token: String?, role: String, label: String?,
         value: String?, parentIndex: Int?, depth: Int = 0,
         frame: CGRect? = nil, enabled: Bool, selected: Bool = false,
         inWebContent: Bool = false) {
        self.index = index
        self.token = token
        self.role = role
        self.label = label
        self.value = value
        self.parentIndex = parentIndex
        self.depth = depth
        self.frame = frame
        self.enabled = enabled
        self.selected = selected
        self.inWebContent = inWebContent
    }

    static let editableTextRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    /// The driver folds an element's VALUE into `label` when it has no
    /// app-authored title (a text area's label arrives as its contents).
    /// Anything the plan itself typed would then satisfy `verify_context` or
    /// enter the URL token pool as "screen spelling" — the self-confirmation
    /// circularity the foreground host explicitly refuses. A label identical
    /// to the value is therefore no label at all.
    var authoredLabel: String? {
        guard let label, !label.isEmpty, label != value else { return nil }
        return label
    }

    var actionNames: [String] {
        guard enabled, let token, !token.isEmpty else { return [] }
        return [ActionUICapability.cuaClick]
    }
}

/// Parsed `get_window_state` reply. `degraded` mirrors the driver's own
/// refusal semantics: a degraded snapshot has no usable tree and background
/// input against it would be refused anyway.
struct CuaSnapshot: Equatable {
    let id: String?
    let degraded: Bool
    /// False when the AX walk was truncated. A truncated tree can
    /// MANUFACTURE uniqueness — two text areas where one was cut off looks
    /// like an unambiguous target (review finding) — so element selection
    /// refuses unless the whole tree is in hand.
    let complete: Bool
    let elements: [CuaElement]

    static func parse(_ payload: [String: Any]) -> CuaSnapshot {
        // A refusal ("window_id_not_found", owner mismatch, …) is not a
        // healthy empty window — treating it as one would read a vanished
        // window as alive.
        let refused = payload["refusal"] != nil
            || (payload["status"] as? String) == "refused"
        let degraded = refused || ((payload["degraded"] as? Bool) ?? false)
        let rawElements = (payload["elements"] as? [[String: Any]]) ?? []
        let elements = rawElements.compactMap { raw -> CuaElement? in
            guard let index = raw["element_index"] as? Int,
                  let role = raw["role"] as? String else { return nil }
            return CuaElement(
                index: index,
                token: raw["element_token"] as? String,
                role: role,
                label: raw["label"] as? String,
                value: raw["value"] as? String,
                parentIndex: raw["parent_index"] as? Int,
                depth: raw["depth"] as? Int ?? 0,
                frame: parseFrame(raw["frame"]),
                enabled: (raw["enabled"] as? Bool) ?? false,
                selected: (raw["selected"] as? Bool) ?? false,
                inWebContent: (raw["in_web_content"] as? Bool) ?? false)
        }
        let treeIsComplete = validTree(
            elements,
            rawCount: rawElements.count)
        let complete = !degraded && treeIsComplete
            && ((payload["elements_complete"] as? Bool) ?? false)
        return CuaSnapshot(id: payload["snapshot_id"] as? String,
                           degraded: degraded,
                           complete: complete,
                           elements: elements)
    }

    private static func validTree(
        _ elements: [CuaElement],
        rawCount: Int
    ) -> Bool {
        guard !elements.isEmpty, elements.count == rawCount else { return false }
        let indices = Set(elements.map(\.index))
        guard indices.count == elements.count else { return false }

        let byIndex = Dictionary(
            uniqueKeysWithValues: elements.map { ($0.index, $0) })
        for element in elements {
            guard element.index >= 0,
                  element.depth >= 0,
                  element.depth <= 64 else { return false }
            var seen = Set([element.index])
            var parent = element.parentIndex
            while let index = parent {
                guard seen.insert(index).inserted,
                      let ancestor = byIndex[index] else { return false }
                parent = ancestor.parentIndex
            }
        }
        return true
    }

    private static func parseFrame(_ raw: Any?) -> CGRect? {
        guard let frame = raw as? [String: Any],
              let x = number(frame["x"]), let y = number(frame["y"]),
              let width = number(frame["w"]),
              let height = number(frame["h"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func number(_ raw: Any?) -> CGFloat? {
        guard let value = raw as? NSNumber else { return nil }
        return CGFloat(value.doubleValue)
    }

    var hasEditableTextElement: Bool { primaryTextElement != nil }

    /// The one element background typing may address. A window-targeted write
    /// must name its element: the driver's default target is the PID's
    /// focused element, which can live in a different window of the same app
    /// (live finding, 2026-08-23 — TextEdit with three open documents).
    /// Document body first (the lone AXTextArea), then the lone editable of
    /// any role; ambiguity — including the manufactured kind, from a
    /// truncated tree — refuses rather than guesses.
    var primaryTextElement: CuaElement? {
        guard complete,
              Set(elements.map(\.index)).count == elements.count else {
            return nil
        }
        let editable = elements.filter {
            CuaElement.editableTextRoles.contains($0.role) && $0.enabled
        }
        let bodies = editable.filter { $0.role == "AXTextArea" }
        let chosen: CuaElement?
        if bodies.count == 1 {
            chosen = bodies[0]
        } else if editable.count == 1 {
            chosen = editable[0]
        } else {
            chosen = nil
        }
        // Web content (Electron, embedded web views) echo-confirms AX value
        // writes without the DOM necessarily seeing them — the driver itself
        // refuses to trust readback there, and so does Velora: an element
        // under an AXWebArea is not a background-typeable target.
        guard let chosen, !chosen.inWebContent,
              !hasWebAreaAncestor(chosen) else { return nil }
        return chosen
    }

    /// Index lookup that TOLERATES a malformed reply. `uniqueKeysWithValues`
    /// traps on a repeated index, so a garbled driver response — or a
    /// same-user process squatting the socket — could crash the app instead
    /// of being refused (review finding).
    var elementsByIndex: [Int: CuaElement] {
        Dictionary(elements.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func hasWebAreaAncestor(_ element: CuaElement) -> Bool {
        let byIndex = elementsByIndex
        var cursor = element.parentIndex
        var hops = 0
        while let index = cursor, hops < 64 {
            guard let ancestor = byIndex[index] else { return false }
            if ancestor.role == "AXWebArea" { return true }
            cursor = ancestor.parentIndex
            hops += 1
        }
        return false
    }
}

/// Key-name translation from the plan vocabulary (`ActionKey`) to the
/// driver's (`press_key`). Nil means the driver cannot press it and the step
/// must fail rather than approximate.
enum CuaKeyMap {
    static func driverKey(forPlanKey name: String) -> String? {
        let key = name.lowercased()
        switch key {
        case "enter": return "return"
        case "page_up": return "pageup"
        case "page_down": return "pagedown"
        case "forward_delete": return nil
        case "return", "tab", "escape", "space", "delete", "home", "end",
             "up", "down", "left", "right":
            return key
        default:
            if key.count == 2, key.first == "f",
               ActionKey.namedKeyCodes[key] != nil { return key }
            if key.count == 3, key.hasPrefix("f1"),
               ActionKey.namedKeyCodes[key] != nil { return key }
            // Single letters and digits pass through; worded punctuation
            // ("comma") is not in the driver's vocabulary.
            if key.count == 1, let character = key.first,
               character.isLetter || character.isNumber { return key }
            return nil
        }
    }

    static func driverModifiers(_ mods: [String]) -> [String] {
        mods.compactMap { name in
            switch name.lowercased() {
            case "cmd": return "cmd"
            case "shift": return "shift"
            case "option": return "option"
            case "control": return "ctrl"
            case "fn": return "fn"
            default: return nil
            }
        }
    }
}

/// Picks the window an Action should drive for a pid: the app's topmost
/// document-sized window by z-order — the one the app itself would bring
/// forward, which is what a user means by "the TextEdit window". Tiny
/// layer-0 windows (palettes, accessory views) are never candidates: with
/// only those present the pick refuses rather than guesses (review finding).
enum CuaWindowPick {
    /// Smallest thing that can be a document window. Observed live: an app
    /// owns full-width 30-pixel strips (menu-bar surfaces) and 64-pixel save-
    /// panel accessory views that pass any area-only filter — typing into
    /// one of those would be the background version of typing into a random
    /// chrome element.
    static let minimumWidth: Double = 200
    static let minimumHeight: Double = 120

    static func choose(_ windows: [[String: Any]], pid: Int) -> (id: Int, title: String?)? {
        let candidates = windows.compactMap {
            raw -> (id: Int, title: String?, z: Int?)? in
            guard isEligible(raw, pid: pid),
                  let id = raw["window_id"] as? Int else { return nil }
            let title = (raw["title"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            return (id, title, raw["z_index"] as? Int)
        }
        // A titled window is a document; untitled ones are panels and
        // overlays. A lone semantic candidate needs no z-order. Multiple
        // candidates need complete, uniquely maximal ordering; null or a tie
        // would turn missing driver evidence into a guess.
        let titled = candidates.filter { $0.title != nil }
        let pool = titled.isEmpty ? candidates : titled
        guard let first = pool.first else { return nil }
        if pool.count == 1 { return (first.id, first.title) }
        guard !pool.contains(where: { $0.z == nil }),
              let maximumZ = pool.compactMap(\.z).max()
        else { return nil }
        let top = pool.filter { $0.z == maximumZ }
        guard top.count == 1, let chosen = top.first else { return nil }
        return (chosen.id, chosen.title)
    }

    private static func isEligible(_ raw: [String: Any], pid: Int) -> Bool {
        guard (raw["pid"] as? Int) == pid,
              (raw["layer"] as? Int) == 0,
              (raw["window_id"] as? Int).map({ $0 > 0 }) == true,
              let bounds = raw["bounds"] as? [String: Any],
              let width = bounds["width"] as? Double,
              let height = bounds["height"] as? Double else { return false }
        return width >= minimumWidth && height >= minimumHeight
    }
}

/// Exact, click-only handoff for an Action completion card. The UI supplies
/// the user's authority by calling this only from the card tap; background
/// execution never enters this path.
enum ActionResultHandoff {
    static let pollDelayMs = 50
    static let maximumPolls = 60

    struct Observation: Equatable {
        let pid: Int
        let bundleID: String
        let windowID: Int
    }

    static func open(
        pid: Int,
        bundleID: String,
        windowID: Int,
        generation: UInt64,
        activateStrict: () -> Bool,
        reopen: () -> Bool,
        observe: () -> Observation?,
        inputGeneration: () -> UInt64,
        sleep: (Int) -> Void
    ) -> Bool {
        guard pid > 0, windowID > 0, !bundleID.isEmpty else { return false }
        guard generation == inputGeneration() else { return false }
        _ = activateStrict()
        guard generation == inputGeneration() else { return false }
        if let current = observe(),
           isExact(current, pid: pid, bundleID: bundleID, windowID: windowID) {
            return generation == inputGeneration()
        }

        guard generation == inputGeneration(), reopen(),
              generation == inputGeneration() else { return false }
        for attempt in 0..<maximumPolls {
            guard generation == inputGeneration() else { return false }
            if let current = observe() {
                guard current.pid != pid
                        || current.bundleID.caseInsensitiveCompare(bundleID)
                            != .orderedSame
                        || current.windowID == windowID
                else { return false }
                if isExact(current, pid: pid, bundleID: bundleID,
                           windowID: windowID) {
                    return generation == inputGeneration()
                }
            }
            if attempt + 1 < maximumPolls { sleep(pollDelayMs) }
        }
        return false
    }

    private static func isExact(
        _ observed: Observation,
        pid: Int,
        bundleID: String,
        windowID: Int
    ) -> Bool {
        observed.pid == pid
            && observed.windowID == windowID
            && observed.bundleID.caseInsensitiveCompare(bundleID)
                == .orderedSame
    }
}

/// Completion and process-identity gate for AppKit's asynchronous reopen.
/// The caller runs off-main so AppKit can deliver its callback on main.
enum ActionReopenGate {
    static func hasUniquePID(_ pids: [Int], expected: Int) -> Bool {
        pids.count == 1 && pids[0] == expected
    }

    static func awaitResult(
        start: (@escaping (Bool) -> Void) -> Void
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Bool?
        var closed = false
        start { accepted in
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            result = accepted
            closed = true
            lock.unlock()
            semaphore.signal()
        }
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return result == true
    }
}

/// Press-candidate selection over a snapshot, mirroring
/// `ScreenContext.pressElement`: whole-word label match, the committing-verb
/// denylist judged on the element's full text, and an
/// ancestor walk for the Electron/table pattern where the text lives on a
/// child of the enabled control. This is the legacy fallback; structured
/// snapshots use exact indices instead.
enum CuaPressPick {
    /// Cua 0.21 snapshots do not carry AX action names. Refuse structural and
    /// editable roles here and let the driver prove whether the remaining
    /// exact token is clickable. This is one driver contract, not an app map.
    private static let nonInteractiveRoles: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXWebArea",
        "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox",
        "AXSearchField",
    ]

    static func supportsPress(role: String) -> Bool {
        !nonInteractiveRoles.contains(role)
    }

    static func candidate(in elements: [CuaElement], label: String) -> CuaElement? {
        // Duplicate indices must refuse, not trap (review finding).
        let byIndex = Dictionary(elements.map { ($0.index, $0) },
                                 uniquingKeysWith: { first, _ in first })
        for element in elements {
            // Match on the app-authored label only — a folded field VALUE
            // matching the spoken label must never make an element pressable.
            guard let text = element.authoredLabel,
                  AppMatcher.contextMatches([label], in: [text]) else { continue }
            let fullText = [element.label, element.value]
                .compactMap { $0 }.joined(separator: " ")
            guard !ActionPlan.pressLabelIsCommitting(fullText) else { continue }
            if element.enabled, element.token != nil,
               supportsPress(role: element.role) { return element }
            var ancestorIndex = element.parentIndex
            for _ in 0..<3 {
                guard let index = ancestorIndex,
                      let ancestor = byIndex[index] else { break }
                let ancestorText = [ancestor.label, ancestor.value]
                    .compactMap { $0 }.joined(separator: " ")
                if !ancestorText.isEmpty,
                   ActionPlan.pressLabelIsCommitting(ancestorText) { break }
                if ancestor.enabled, ancestor.token != nil,
                   supportsPress(role: ancestor.role) { return ancestor }
                ancestorIndex = ancestor.parentIndex
            }
        }
        return nil
    }
}

/// Background-routing state for `velora ax-probe`. Read-only: it never
/// starts a daemon, never activates anything, and never types. The project's
/// rule is to extend the probe before guessing at accessibility behaviour —
/// this answers "could an action drive this app in the background, and if
/// not, which gate said no?" in one command.
enum CuaDiagnostics {
    static func dump(transport: CuaTransport,
                     app: NSRunningApplication?) -> [String: Any] {
        var out: [String: Any] = [
            "installed": CuaDriver.isInstalled,
            "signature_trusted": CuaDriver.isInstalled
                ? CuaDriver.signatureIsTrusted : false,
            "socket": CuaDriverDaemon.activeSocketPath ?? "",
        ]
        let healthy = CuaDriverDaemon.isHealthy(transport: transport)
        out["daemon_healthy"] = healthy
        guard healthy, let app, app.processIdentifier > 0 else { return out }
        let pid = Int(app.processIdentifier)
        out["probe_pid"] = pid
        out["probe_app"] = app.localizedName ?? ""
        guard case .success(let listed) = transport.call(
            "list_windows", arguments: [:], timeout: 3),
              let windows = listed["windows"] as? [[String: Any]] else {
            out["windows_error"] = true
            return out
        }
        out["windows_for_pid"] = windows.filter { ($0["pid"] as? Int) == pid }.count
        guard let picked = CuaWindowPick.choose(windows, pid: pid) else {
            out["window_pick"] = "none (no document-sized layer-0 window)"
            return out
        }
        out["window_id"] = picked.id
        out["window_title"] = picked.title ?? ""
        guard case .success(let state) = transport.call(
            "get_window_state",
            arguments: ["pid": pid, "window_id": picked.id,
                        "include_screenshot": false, "max_elements": 2000],
            timeout: 3) else {
            out["snapshot_error"] = true
            return out
        }
        let snapshot = CuaSnapshot.parse(state)
        out["degraded"] = snapshot.degraded
        out["elements"] = snapshot.elements.count
        out["total_elements"] = state["total_element_count"] as? Int ?? -1
        out["elements_complete_flag"] = state["elements_complete"] as? Bool ?? false
        out["complete"] = snapshot.complete
        if let element = snapshot.primaryTextElement {
            out["text_target"] = "\(element.role)#\(element.index)"
        } else {
            out["text_target"] = "none (ambiguous, web-backed, or absent)"
        }
        return out
    }
}

/// `ActionHost` that runs an Action against a background window through the
/// Cua Driver daemon when that is possible, and behaves exactly like the
/// classic foreground host when it is not.
///
/// The routing decision is made once per action, at `openApp`: a target that
/// is a different native app, the feature is enabled, and the daemon is
/// healthy is resolved through an existing window.
/// A windowless target uses Cua's background launch only when the driver proves
/// activation stayed suppressed. The current app needs no activation;
/// unsupported targets refuse. Turning the setting off explicitly restores
/// `SystemActionHost`. Driver failures fail closed.
///
/// Validation is unchanged on purpose: the same `ActionPlan` decode, the same
/// `ActionRuntimePolicy`, the same executor invariants run against this host.
/// The driver only changes WHERE verified steps are delivered.
final class BackgroundRoutingActionHost: ActionHost {
    /// Tree-only snapshots; screenshots are for humans and cost ~250 KB each.
    /// The element cap matches the driver's own default walk bound. Routed
    /// an exact action is bound to one observed element and a fresh driver
    /// reread. Completeness comes only from the driver's positive flag.
    private static let snapshotElements = 2000
    private static let callTimeout: TimeInterval = 3.0
    private static let maximumSnapshotIDs = 512
    private static let maximumSnapshotIDBytes = 128
    private static let presentationTool = CuaWindowActivation.tool
    private static let partialPresentationCode =
        "bring_to_front_exact_window_unverified"
    private static let processPresentationCode =
        "bring_to_front_process_verified"
    private static let toolErrorMarker = "_velora_tool_error"
    private static let handoffQuietSeconds: TimeInterval = 0.5
    private static let handoffWaitMs = 5_000
    private static let handoffPollMs = 50
    private static let appActivationWaitMs = 3_000
    private static let appActivationStableMs = 100
    private let system: ActionHost
    private let transport: CuaTransport
    private let backgroundEnabled: () -> Bool
    private let accessibilityGranted: () -> Bool
    /// Injectable so the selftest can gate health without spawning a daemon.
    private let ensureDaemon: (CuaTransport) -> Bool
    private let endDaemon: () -> Void
    private let bundleForPID: (Int) -> String?
    private let interactionIsQuiet: () -> Bool
    private let userFocusForWindow: (Int) -> ActionWindowIdentity?
    /// Resolves a spoken app name using Velora's own knowledge, so routing
    /// can be ruled out before a daemon is ever started. Returning nil just
    /// means "can't tell from here" — the driver decides.
    private let localResolve: (String) -> (name: String, bundleID: String)?
    // Routed-target state, reset every action.
    private var routed = false
    private var contentMayCommit = false
    private var executionMode = ActionExecutionMode.interaction
    private var targetPID: Int = 0
    private var targetWindowID: Int?
    private var targetName = ""
    private var targetBundleID = ""
    private var targetReady = false
    /// Explicit callers may request a foreground transition. The automatic
    /// executor never arms this boundary.
    private var foregroundAtInteraction = false
    private struct ForegroundTarget {
        let name: String
        let bundleID: String
        let pid: Int
        let windowID: Int?
    }
    private var foregroundTarget: ForegroundTarget?
    /// True once readiness has succeeded at least once this action.
    private var everReady = false
    /// The exact element this action is writing into, pinned the first time
    /// one is chosen. Without it the "lone editable" rule is relative to
    /// whatever the tree looks like right now: a plan can verify against a
    /// sidebar search field and then type into the document body that
    /// materialized a step later, or the reverse (review finding). The
    /// foreground host pins one AX element for the whole action; so does
    /// this one.
    private struct ElementIdentity: Equatable {
        let index: Int
        let role: String
        let label: String?
        let parentIndex: Int?
        let depth: Int
        let frame: CGRect?
        let enabled: Bool
        let inWebContent: Bool

        init(_ element: CuaElement) {
            index = element.index
            role = element.role
            label = element.authoredLabel
            parentIndex = element.parentIndex
            depth = element.depth
            frame = element.frame
            enabled = element.enabled
            inWebContent = element.inWebContent
        }
    }
    private var pinnedElement: ElementIdentity?
    /// Text this action itself delivered to the pinned element — the
    /// background analog of the foreground draft: committing keys refuse
    /// without it, and it is dropped whenever the element or target changes.
    private var backgroundDraft = ""
    private struct RoutedUISnapshot {
        let observation: ActionUISnapshot
        let driver: CuaSnapshot
        let pid: Int
        let windowID: Int
        let bundleID: String
    }
    private var routedUISnapshot: RoutedUISnapshot?
    private enum SnapshotIDResult {
        case fresh
        case replay
        case exhausted
    }
    private enum SnapshotLineage {
        case valid
        case poisoned
    }
    /// Every nonempty driver snapshot ID read for this routed action. Each ID
    /// may occur once; alternating replay is stale even when it differs from
    /// the cached observation.
    private var observedSnapshotIDs = Set<String>()
    private var snapshotLineage = SnapshotLineage.valid

    init(system: ActionHost, transport: CuaTransport,
         backgroundEnabled: @escaping () -> Bool,
         accessibilityGranted: @escaping () -> Bool = {
             Permissions.accessibilityGranted
         },
         ensureDaemon: @escaping (CuaTransport) -> Bool
            = CuaDriverDaemon.ensureRunning,
         endDaemon: @escaping () -> Void
            = CuaDriverDaemon.stopIfVeloraStarted,
         bundleForPID: @escaping (Int) -> String? = { pid in
            NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
         },
         interactionIsQuiet: (() -> Bool)? = nil,
         userFocusForWindow: @escaping (Int) -> ActionWindowIdentity?
            = BackgroundRoutingActionHost.resolveUserWindow,
         localResolve: @escaping (String) -> (name: String, bundleID: String)?
            = BackgroundRoutingActionHost.resolveRunningApp) {
        self.system = system
        self.transport = transport
        self.backgroundEnabled = backgroundEnabled
        self.accessibilityGranted = accessibilityGranted
        self.ensureDaemon = ensureDaemon
        self.endDaemon = endDaemon
        self.bundleForPID = bundleForPID
        self.interactionIsQuiet = interactionIsQuiet ?? {
            UserInputActivity.isQuiet(for: Self.handoffQuietSeconds)
        }
        self.userFocusForWindow = userFocusForWindow
        self.localResolve = localResolve
    }

    private static func resolveUserWindow(
        _ windowID: Int
    ) -> ActionWindowIdentity? {
        guard windowID > 0,
              let rows = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], CGWindowID(windowID))
                as? [[String: Any]],
              let row = rows.first(where: {
                  ($0[kCGWindowNumber as String] as? Int) == windowID
                      && ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let pid = row[kCGWindowOwnerPID as String] as? Int, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier
        else { return nil }
        return ActionWindowIdentity(
            name: app.localizedName ?? "", bundleID: bundleID,
            pid: pid, windowID: windowID)
    }

    /// Best-effort local identity for a spoken app name: the running apps
    /// are what a background action almost always means, and they carry
    /// their bundle ids already.
    static func resolveRunningApp(named name: String)
        -> (name: String, bundleID: String)? {
        let work: () -> (name: String, bundleID: String)? = {
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.localizedName != nil
            }
            guard let index = uniqueIndex(
                for: name, in: running.map { $0.localizedName ?? "" }),
                  let bundleID = running[index].bundleIdentifier else { return nil }
            return (running[index].localizedName ?? name, bundleID)
        }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private static func uniqueIndex(
        for name: String,
        in candidates: [String]
    ) -> Int? {
        let matches = candidates.indices.filter {
            AppMatcher.namesSameApp(name, candidates[$0])
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func beginActionInputSession() {
        unroute()
        contentMayCommit = false
        executionMode = .interaction
        system.beginActionInputSession()
    }

    func endActionInputSession() {
        unroute()
        contentMayCommit = false
        executionMode = .interaction
        system.endActionInputSession()
        endDaemon()
    }

    func prepareForActionPlan(sends: Bool) {
        contentMayCommit = sends
        if sends && routed { foregroundAtInteraction = true }
    }

    func prepareForExecutionMode(_ mode: ActionExecutionMode) {
        executionMode = mode
    }

    func prepareInteraction() -> ActionInteractionState {
        guard routed else { return .ready }
        guard foregroundAtInteraction else { return waitForTargetIdle() }
        guard snapshotLineage == .valid, targetReady,
              resolveDeferredWindow(), let windowID = targetWindowID
        else { return .refused }

        guard waitForQuiet() else { return .deferred }
        let inputGeneration = UserInputActivity.snapshot()
        guard interactionIsQuiet(),
              inputGeneration == UserInputActivity.snapshot()
        else { return .deferred }
        guard presentationTargetIsLive(windowID: windowID) else { return .refused }
        if exactTargetIsForeground(windowID: windowID) {
            finishHandoff(windowID: windowID)
            return .ready
        }

        guard let front = system.frontmostApp(),
              let prior = captureFocus(front) else { return .refused }
        guard interactionIsQuiet(),
              inputGeneration == UserInputActivity.snapshot()
        else { return .deferred }
        guard presentationTargetIsLive(windowID: windowID) else { return .refused }
        let result = transport.call(Self.presentationTool, arguments: [
            "pid": targetPID, "window_id": windowID,
        ], timeout: Self.callTimeout)
        guard inputGeneration == UserInputActivity.snapshot() else {
            _ = restoreAfterUserInput(
                prior, generation: inputGeneration, pid: targetPID,
                windowID: windowID, bundleID: targetBundleID)
            return .deferred
        }
        let reply: [String: Any]?
        if case .success(let value) = result {
            reply = value
        } else {
            reply = nil
        }
        guard let reply,
              presentationMatches(reply, pid: targetPID, windowID: windowID)
        else {
            _ = restoreTargetFocus(
                prior, generation: inputGeneration, pid: targetPID,
                windowID: windowID, bundleID: targetBundleID, reply: reply)
            unroute()
            endDaemon()
            return .refused
        }

        finishHandoff(windowID: windowID)
        return .ready
    }

    private func waitForTargetIdle() -> ActionInteractionState {
        let deadline = system.now()
            + Double(Self.handoffWaitMs) / 1_000
        while userIsInTarget(), system.now() < deadline {
            system.sleep(ms: Self.handoffPollMs)
        }
        return userIsInTarget() ? .deferred : .ready
    }

    private func userIsInTarget() -> Bool {
        guard let front = system.frontmostApp() else { return false }
        return front.bundleID.caseInsensitiveCompare(targetBundleID)
            == .orderedSame
    }

    private func waitForQuiet() -> Bool {
        let deadline = system.now()
            + Double(Self.handoffWaitMs) / 1_000
        while !interactionIsQuiet(), system.now() < deadline {
            system.sleep(ms: Self.handoffPollMs)
        }
        return interactionIsQuiet()
    }

    private func exactTargetIsForeground(windowID: Int) -> Bool {
        guard let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(targetBundleID) == .orderedSame,
              let window = system.foregroundWindow(),
              window.pid == targetPID, window.windowID == windowID,
              window.bundleID.caseInsensitiveCompare(targetBundleID) == .orderedSame,
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame else { return false }
        return true
    }

    private func finishHandoff(windowID: Int) {
        let target = ForegroundTarget(
            name: targetName, bundleID: targetBundleID, pid: targetPID,
            windowID: windowID)
        unroute()
        foregroundTarget = target
        endDaemon()
    }

    // MARK: - Routing decision

    func openApp(named name: String) -> String? {
        guard !routed else { return openTargetApp(named: name) }
        if let target = foregroundTarget,
           AppMatcher.bestMatch(for: name, in: [target.name]) == 0 {
            if exactForegroundApp() != nil { return target.name }
            return openForeground(target)
        }
        foregroundTarget = nil
        // Driver installation is part of `backgroundEnabled` (wired in the
        // controller), keeping this host's behavior machine-independent for
        // the selftest.
        guard backgroundEnabled() else {
            return system.openApp(named: name)
        }
        let frontmost = system.frontmostApp()
        // Pre-gate with Velora's OWN app knowledge before touching the
        // driver. Starting the daemon is itself a cost — it is a same-user
        // automation surface with its own telemetry — so an action that was
        // never going to route (the app the user is in or a browser) must not
        // bring one up (review finding). The driver's
        // answer is still authoritative below; this only avoids the spawn.
        if let local = localResolve(name),
           !BackgroundActionGate.shouldRoute(
            enabled: true, contentMayCommit: contentMayCommit,
            targetName: local.name,
            targetBundleID: local.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) {
            guard isCurrentTarget(local.bundleID, frontmost: frontmost) else {
                return nil
            }
            return local.name
        }
        // Resolve the target BEFORE deciding, so the gate judges the actual
        // app (bundle id included), not the spoken words.
        guard ensureDaemon(transport),
              let resolved = resolveApp(
                named: name,
                expectedBundleID: localResolve(name)?.bundleID)
        else { return nil }
        guard BackgroundActionGate.shouldRoute(
            enabled: true, contentMayCommit: contentMayCommit,
            targetName: resolved.name,
            targetBundleID: resolved.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) else {
            guard isCurrentTarget(resolved.bundleID, frontmost: frontmost) else {
                return nil
            }
            return resolved.name
        }
        switch activateTarget(resolved) {
        case .routed:
            veloraLog("Velora: action driving \(resolved.name) in the background")
            return resolved.name
        case .foreground:
            return openForeground(resolved)
        case .failed:
            return nil
        }
    }

    /// A later `open_app` inside an already-routed action. A target the gate
    /// still accepts becomes the new background target. Only a deliberately
    /// unsupported target ends routing and refuses; routing failures do not
    /// silently activate a different app on the user's screen.
    private func openTargetApp(named name: String) -> String? {
        let frontmost = system.frontmostApp()
        if let local = localResolve(name),
           !BackgroundActionGate.shouldRoute(
            enabled: true, contentMayCommit: contentMayCommit,
            targetName: local.name,
            targetBundleID: local.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) {
            unroute()
            guard isCurrentTarget(local.bundleID, frontmost: frontmost) else {
                return nil
            }
            return local.name
        }
        guard let resolved = resolveApp(
            named: name,
            expectedBundleID: localResolve(name)?.bundleID)
        else {
            unroute()
            return nil
        }
        guard BackgroundActionGate.shouldRoute(
            enabled: true, contentMayCommit: contentMayCommit,
            targetName: resolved.name,
            targetBundleID: resolved.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) else {
            unroute()
            guard isCurrentTarget(resolved.bundleID, frontmost: frontmost) else {
                return nil
            }
            return resolved.name
        }
        switch activateTarget(resolved) {
        case .routed:
            return resolved.name
        case .foreground:
            unroute()
            return openForeground(resolved)
        case .failed:
            unroute()
            return nil
        }
    }

    private struct ResolvedApp {
        let name: String
        let bundleID: String
        let pid: Int
        let running: Bool
    }

    private func isCurrentTarget(
        _ bundleID: String,
        frontmost: (name: String, bundleID: String)?
    ) -> Bool {
        guard let frontmost else { return false }
        return frontmost.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
    }

    private func openForeground(_ resolved: ResolvedApp) -> String? {
        let target = ForegroundTarget(
            name: resolved.name, bundleID: resolved.bundleID, pid: resolved.pid,
            windowID: nil)
        return openForeground(target)
    }

    private func openForeground(_ target: ForegroundTarget) -> String? {
        endDaemon()
        guard let opened = system.openApp(
            named: target.name, bundleID: target.bundleID, pid: target.pid)
        else { return nil }
        let window = system.foregroundWindow()
        let windowID: Int? = window.flatMap {
            guard $0.pid == target.pid,
                  $0.bundleID.caseInsensitiveCompare(target.bundleID)
                    == .orderedSame else { return nil }
            return $0.windowID
        }
        foregroundTarget = ForegroundTarget(
            name: target.name, bundleID: target.bundleID, pid: target.pid,
            windowID: windowID)
        return opened
    }

    private enum WindowProbe {
        case found(pid: Int, windowID: Int)
        case offSpace(pid: Int, windowID: Int)
        case missing
        case invalid
    }

    private enum RouteResult {
        case routed
        case foreground
        case failed
    }

    private enum FocusTarget {
        case app(bundleID: String, pid: Int)
        case window(ActionWindowIdentity)
    }

    private func resolveApp(
        named name: String,
        expectedBundleID: String?
    ) -> ResolvedApp? {
        guard case .success(let reply) = transport.call(
            "list_apps", arguments: [:], timeout: Self.callTimeout),
              let apps = reply["apps"] as? [[String: Any]] else { return nil }
        let names = apps.map { ($0["name"] as? String) ?? "" }
        let matches = apps.indices.filter { index in
            guard AppMatcher.namesSameApp(name, names[index]) else { return false }
            guard let expectedBundleID else { return true }
            guard let bundleID = apps[index]["bundle_id"] as? String else {
                return false
            }
            return bundleID.caseInsensitiveCompare(expectedBundleID) == .orderedSame
        }
        guard matches.count == 1,
              let index = matches.first,
              let bundleID = apps[index]["bundle_id"] as? String,
              let pid = exactInt(apps[index]["pid"]), pid >= 0,
              let running = exactFlag(apps[index]["running"]),
              (running && pid > 0) || (!running && pid == 0)
        else { return nil }
        return ResolvedApp(
            name: names[index], bundleID: bundleID,
            pid: pid, running: running)
    }

    private func activateTarget(_ resolved: ResolvedApp) -> RouteResult {
        guard let frontBefore = system.frontmostApp(),
              frontBefore.bundleID.caseInsensitiveCompare(resolved.bundleID)
                != .orderedSame else { return .failed }

        switch existingWindow(resolved) {
        case .found(let pid, let windowID):
            beginRoute(
                resolved, pid: pid, windowID: windowID,
                foregroundAtInteraction: contentMayCommit)
            return .routed
        case .offSpace(let pid, let windowID):
            beginRoute(
                resolved, pid: pid, windowID: windowID,
                foregroundAtInteraction: contentMayCommit)
            return .routed
        case .missing:
            if resolved.running, executionMode == .processOnly {
                beginRoute(
                    resolved, pid: resolved.pid, windowID: nil,
                    foregroundAtInteraction: contentMayCommit)
                return .routed
            }
            return launchTarget(resolved)
                ? .routed : .failed
        case .invalid:
            return .failed
        }
    }

    private func existingWindow(_ resolved: ResolvedApp) -> WindowProbe {
        guard resolved.running, resolved.pid > 0 else { return .missing }
        guard let liveBundleID = bundleForPID(resolved.pid),
              liveBundleID.caseInsensitiveCompare(resolved.bundleID)
                == .orderedSame else { return .invalid }
        guard case .success(let reply) = transport.call(
            "list_windows", arguments: ["pid": resolved.pid],
            timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]]
        else { return .invalid }
        guard windows.allSatisfy({ validWindow($0, pid: resolved.pid) })
        else { return .invalid }
        let unknown = windows.filter {
            exactFlag($0["on_current_space"]) == nil
        }
        let known = windows.filter {
            exactFlag($0["on_current_space"]) != nil
        }
        let current = known.filter {
            exactFlag($0["on_current_space"]) == true
        }
        if let window = CuaWindowPick.choose(current, pid: resolved.pid) {
            return .found(pid: resolved.pid, windowID: window.id)
        }
        if let window = CuaWindowPick.choose(known, pid: resolved.pid) {
            return .offSpace(pid: resolved.pid, windowID: window.id)
        }
        if let window = CuaWindowPick.choose(unknown, pid: resolved.pid) {
            return .offSpace(pid: resolved.pid, windowID: window.id)
        }
        return .missing
    }

    private func validWindow(_ raw: [String: Any], pid: Int) -> Bool {
        guard exactInt(raw["pid"]) == pid,
              exactInt(raw["window_id"]).map({ $0 > 0 }) == true,
              exactInt(raw["layer"]) == 0,
              let bounds = raw["bounds"] as? [String: Any],
              exactNumber(bounds["width"]).map({ $0 >= 0 }) == true,
              exactNumber(bounds["height"]).map({ $0 >= 0 }) == true
        else { return false }
        return true
    }

    private func launchTarget(_ resolved: ResolvedApp) -> Bool {
        guard let front = system.frontmostApp(),
              let prior = captureFocus(front) else { return false }
        let inputGeneration = UserInputActivity.snapshot()
        let launchResult = transport.call(
            "launch_app", arguments: ["bundle_id": resolved.bundleID],
            timeout: 10)
        let inputUnchanged = inputGeneration == UserInputActivity.snapshot()
        let focusPreserved = focusMatches(prior)
        if inputUnchanged && !focusPreserved {
            _ = restoreFocus(prior)
        }
        // Unrelated input is harmless when the exact prior focus survived.
        // If launch changed focus, only an untouched input generation permits
        // restoration; otherwise the user's newly selected target wins.
        guard case .success(let launched) = launchResult,
              focusPreserved,
              exactFlag(launched["self_activation_suppressed"]) == true,
              system.frontmostApp()?.bundleID.caseInsensitiveCompare(
                resolved.bundleID) != .orderedSame else { return false }
        guard let pid = exactInt(launched["pid"]), pid > 0,
              !resolved.running || pid == resolved.pid,
              let launchedBundleID = launched["bundle_id"] as? String,
              launchedBundleID.caseInsensitiveCompare(resolved.bundleID)
                == .orderedSame,
              let launchState = launched["launch_state"] as? [String: Any],
              exactFlag(launchState["requested"]) == true,
              exactFlag(launchState["process_running"]) == true,
              let liveBundleID = bundleForPID(pid),
              liveBundleID.caseInsensitiveCompare(resolved.bundleID)
                == .orderedSame else { return false }
        beginRoute(
            resolved, pid: pid, windowID: nil,
            foregroundAtInteraction: contentMayCommit)
        return true
    }

    private func focusMatches(_ target: FocusTarget) -> Bool {
        switch target {
        case .window(let expected):
            guard let front = system.frontmostApp(),
                  let window = system.foregroundWindow()
            else { return false }
            return front.bundleID.caseInsensitiveCompare(expected.bundleID)
                    == .orderedSame
                && window == expected
        case .app(let bundleID, let pid):
            guard let front = system.frontmostApp(),
                  front.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
                  case .success(let reply) = transport.call(
                    "list_apps", arguments: [:], timeout: Self.callTimeout),
                  let apps = reply["apps"] as? [[String: Any]]
            else { return false }
            return apps.contains {
                exactInt($0["pid"]) == pid
                    && exactFlag($0["active"]) == true
                    && ($0["bundle_id"] as? String)?.caseInsensitiveCompare(
                        bundleID) == .orderedSame
            }
        }
    }

    private func captureFocus(
        _ front: (name: String, bundleID: String)
    ) -> FocusTarget? {
        if let window = captureWindow(front) { return window }
        guard case .success(let reply) = transport.call(
            "list_apps", arguments: [:], timeout: Self.callTimeout),
              let apps = reply["apps"] as? [[String: Any]] else { return nil }
        let matches = apps.filter {
            guard let bundleID = $0["bundle_id"] as? String else { return false }
            return bundleID.caseInsensitiveCompare(front.bundleID) == .orderedSame
                && exactFlag($0["running"]) == true
                && exactFlag($0["active"]) == true
        }
        guard matches.count == 1,
              let pid = exactInt(matches[0]["pid"]), pid > 0,
              let liveBundleID = bundleForPID(pid),
              liveBundleID.caseInsensitiveCompare(front.bundleID) == .orderedSame
        else { return nil }
        return .app(bundleID: front.bundleID, pid: pid)
    }

    private func captureWindow(
        _ front: (name: String, bundleID: String)
    ) -> FocusTarget? {
        guard let window = system.foregroundWindow(),
              window.pid > 0, window.windowID > 0,
              window.bundleID.caseInsensitiveCompare(front.bundleID) == .orderedSame
        else { return nil }
        return .window(window)
    }

    private func beginRoute(
        _ resolved: ResolvedApp, pid: Int, windowID: Int?,
        foregroundAtInteraction: Bool
    ) {
        routed = true
        targetPID = pid
        targetName = resolved.name
        targetBundleID = resolved.bundleID
        targetWindowID = windowID
        targetReady = false
        self.foregroundAtInteraction = foregroundAtInteraction
        everReady = false
        // A new target is a new window, a new element, and a new draft:
        // text delivered to the previous app must never authorize a commit
        // here (review finding — `unroute` cleared this, retargeting did
        // not). The materialization allowance travels with the target, but
        // the per-action ceiling still applies.
        pinnedElement = nil
        routedUISnapshot = nil
        resetSnapshotLineage()
        backgroundDraft = ""
    }

    private func restoreTargetFocus(
        _ prior: FocusTarget, generation: UInt64,
        pid: Int, windowID: Int, bundleID: String,
        reply: [String: Any]? = nil
    ) -> Bool {
        guard let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        else { return true }
        let targetOwnsFocus: Bool
        if let window = system.foregroundWindow() {
            targetOwnsFocus = window.pid == pid
                && window.bundleID.caseInsensitiveCompare(bundleID)
                    == .orderedSame
        } else {
            targetOwnsFocus = reply.map {
                replyProvesTargetFront($0, pid: pid)
            } == true
        }
        guard targetOwnsFocus else { return true }
        guard generation == UserInputActivity.snapshot() else {
            return restoreAfterUserInput(
                prior, generation: generation, pid: pid,
                windowID: windowID, bundleID: bundleID)
        }
        let restored = restoreFocus(prior)
        guard generation == UserInputActivity.snapshot() else {
            return restoreAfterUserInput(
                prior, generation: generation, pid: pid,
                windowID: windowID, bundleID: bundleID)
        }
        return restored
    }

    private func restoreExactFocus(
        _ prior: FocusTarget, pid: Int, windowID: Int, bundleID: String
    ) -> Bool {
        guard let front = system.frontmostApp(),
              let window = system.foregroundWindow(),
              front.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
              window.pid == pid, window.windowID == windowID,
              window.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        else { return true }
        return restoreFocus(prior)
    }

    private func restoreAfterUserInput(
        _ prior: FocusTarget, generation: UInt64,
        pid: Int, windowID: Int, bundleID: String
    ) -> Bool {
        if let selectedWindow = UserInputActivity.selectedWindow(after: generation),
           let selected = userFocusForWindow(selectedWindow) {
            return restoreWindow(selected)
        }
        return restoreExactFocus(
            prior, pid: pid, windowID: windowID, bundleID: bundleID)
    }

    // MARK: - Target readiness (drives the executor's wait_frontmost poll)

    /// In routed mode the "frontmost app" IS the background target. A route
    /// that will hand off before interaction needs only an independently
    /// verified exact window; a background-input route also needs AX.
    func frontmostApp() -> (name: String, bundleID: String)? {
        guard routed else { return exactForegroundApp() }
        guard snapshotLineage == .valid else { return nil }
        if foregroundAtInteraction {
            guard resolveDeferredWindow() else {
                targetReady = false
                return nil
            }
            targetReady = true
            everReady = true
            return (targetName, targetBundleID)
        }
        if targetReady, verifyTargetAlive() { return (targetName, targetBundleID) }
        guard advanceReadiness() else { return nil }
        return (targetName, targetBundleID)
    }

    /// Re-reads WindowServer through Cua without activating the app. Space
    /// membership is nullable private metadata; exact PID/window identity is
    /// the handoff boundary.
    private func resolveDeferredWindow() -> Bool {
        guard routed,
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              case .success(let reply) = transport.call(
                "list_windows", arguments: ["pid": targetPID],
                timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]],
              windows.allSatisfy({ validWindow($0, pid: targetPID) })
        else { return false }

        if let windowID = targetWindowID {
            let exact = windows.filter { exactInt($0["window_id"]) == windowID }
            return exact.count == 1
                && CuaWindowPick.choose(exact, pid: targetPID)?.id == windowID
        }
        guard let window = CuaWindowPick.choose(windows, pid: targetPID) else {
            return false
        }
        targetWindowID = window.id
        return true
    }

    private func exactForegroundApp() -> (name: String, bundleID: String)? {
        guard let target = foregroundTarget else {
            return system.frontmostApp()
        }
        guard let targetWindowID = target.windowID,
              let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(target.bundleID)
                == .orderedSame,
              let window = system.foregroundWindow(),
              window.pid == target.pid, window.windowID == targetWindowID,
              window.bundleID.caseInsensitiveCompare(target.bundleID)
                == .orderedSame,
              bundleForPID(target.pid)?.caseInsensitiveCompare(target.bundleID)
                == .orderedSame else { return nil }
        return front
    }

    private func verifyTargetAlive() -> Bool {
        // A vanished target window must read as lost focus, never as "still
        // fine": the executor aborts instead of typing into nothing. A live
        // exact window without AX remains sufficient only for an app-ready
        // result; every mutation method independently requires its UI proof.
        if executionMode == .processOnly {
            targetReady = processOnlyReady()
            return targetReady
        }
        guard let snapshot = snapshotTarget(maxElements: 1) else {
            targetReady = false
            return false
        }
        if snapshot.degraded {
            targetReady = resolveDeferredWindow()
            return targetReady
        }
        return true
    }

    private func advanceReadiness() -> Bool {
        guard snapshotLineage == .valid else { return false }
        if executionMode == .processOnly {
            targetReady = processOnlyReady()
            everReady = targetReady
            return targetReady
        }
        // Re-picking is allowed ONLY while the target has never been ready:
        // a cold-launched app's real document window can appear after the
        // first look. Once ready, the window is pinned for the rest of the
        // action — re-picking then would silently retarget at a different
        // window of the same app (review finding), the background analog of
        // typing into whatever took focus.
        if targetWindowID == nil || !everReady {
            if let window = pickTargetWindow() {
                targetWindowID = window.id
            } else if processOnlyReady() {
                targetReady = true
                everReady = true
                return true
            } else {
                return false
            }
        }
        guard let snapshot = snapshotTarget(maxElements: 10) else { return false }
        if snapshot.degraded, !resolveDeferredWindow() { return false }
        targetReady = true
        everReady = true
        return true
    }

    private func pickTargetWindow() -> (id: Int, title: String?)? {
        guard case .success(let reply) = transport.call(
            "list_windows", arguments: [:], timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]] else { return nil }
        return CuaWindowPick.choose(windows, pid: targetPID)
    }

    private func processOnlyReady() -> Bool {
        guard routed, executionMode == .processOnly, targetPID > 0,
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              case .success(let reply) = transport.call(
                "list_apps", arguments: [:],
                timeout: Self.callTimeout),
              let apps = reply["apps"] as? [[String: Any]]
        else { return false }
        let exact = apps.filter {
            exactInt($0["pid"]) == targetPID
                && exactFlag($0["running"]) == true
                && ($0["bundle_id"] as? String)?.caseInsensitiveCompare(
                    targetBundleID) == .orderedSame
        }
        return exact.count == 1
    }

    private func snapshotTarget(maxElements: Int) -> CuaSnapshot? {
        guard snapshotLineage == .valid,
              let windowID = targetWindowID,
              let liveBundleID = bundleForPID(targetPID),
              liveBundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame else { return nil }
        let arguments: [String: Any] = [
            "include_screenshot": false,
            "pid": targetPID,
            "window_id": windowID,
            "max_elements": maxElements,
        ]
        guard case .success(let reply) = transport.call(
            "get_window_state", arguments: arguments, timeout: Self.callTimeout)
        else { return nil }
        let snapshot = CuaSnapshot.parse(reply)
        // A degraded observation grants no element capability. Its optional
        // snapshot ID therefore carries no action lineage; exact app/window
        // readiness comes independently from the fresh WindowServer list.
        if snapshot.degraded { return snapshot }
        guard let snapshotID = snapshot.id, !snapshotID.isEmpty else {
            poisonSnapshotLineage()
            return nil
        }
        switch recordSnapshotID(snapshotID) {
        case .fresh:
            return snapshot
        case .replay, .exhausted:
            poisonSnapshotLineage()
            return nil
        }
    }

    private func recordSnapshotID(_ id: String) -> SnapshotIDResult {
        guard id.utf8.count <= Self.maximumSnapshotIDBytes else {
            return .exhausted
        }
        if observedSnapshotIDs.contains(id) { return .replay }
        guard observedSnapshotIDs.count < Self.maximumSnapshotIDs else {
            return .exhausted
        }
        observedSnapshotIDs.insert(id)
        return .fresh
    }

    private func poisonSnapshotLineage() {
        snapshotLineage = .poisoned
        targetReady = false
        routedUISnapshot = nil
        pinnedElement = nil
        backgroundDraft = ""
    }

    private func resetSnapshotLineage() {
        observedSnapshotIDs.removeAll(keepingCapacity: true)
        snapshotLineage = .valid
    }

    // MARK: - Observations

    /// Fresh from the window list every call: `verify_context` polls this
    /// while the screen settles, and a title captured once at readiness
    /// would let the check pass on stale evidence (review finding).
    func frontmostWindowTitle() -> String? {
        guard routed else { return system.frontmostWindowTitle() }
        guard snapshotLineage == .valid, let windowID = targetWindowID,
              case .success(let reply) = transport.call(
                "list_windows", arguments: [:], timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]],
              // Scoped by pid as well as id: WindowServer recycles window
              // ids, and a reissued id would feed ANOTHER app's title into
              // verify_context (review finding).
              let row = windows.first(where: {
                  ($0["window_id"] as? Int) == windowID
                      && ($0["pid"] as? Int) == targetPID
              }),
              let title = row["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The "focused element" a routed action reports is the target window's
    /// primary text element — the exact element `typeText` will address. It
    /// is not app focus (a background window has none the driver can read),
    /// but it is the truthful answer to what the planner is really asking:
    /// "is there somewhere for text to go?" Without it the planner waits
    /// forever for a focus that can never arrive (live finding, 2026-08-23).
    /// Always a fresh snapshot — cached trees let stale evidence satisfy
    /// `verify_context` (review finding).
    func focusedElementLabel() -> String? {
        guard routed else { return system.focusedElementLabel() }
        guard snapshotLineage == .valid, targetReady,
              let element = freshPrimaryTextElement()?.element
        else { return nil }
        let label = element.authoredLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty ?? true) ? nil : label
    }

    func focusedSelectionLabel() -> String? {
        routed ? nil : system.focusedSelectionLabel()
    }

    func focusedElementRole() -> String? {
        guard routed else { return system.focusedElementRole() }
        guard snapshotLineage == .valid, targetReady else { return nil }
        return freshPrimaryTextElement()?.element.role
    }

    /// The pinned element, re-read from a fresh tree. The first successful
    /// call pins; every later call must find the SAME immutable element
    /// identity or it refuses. Value and token are excluded because typing
    /// changes the former and fresh Cua snapshots rotate the latter.
    private func freshPrimaryTextElement()
        -> (snapshot: CuaSnapshot, element: CuaElement)? {
        guard let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              !snapshot.degraded,
              let element = snapshot.primaryTextElement else {
            backgroundDraft = ""
            return nil
        }
        let identity = ElementIdentity(element)
        if let pinnedElement {
            guard pinnedElement == identity else {
                // The draft belonged to the element that just went away.
                backgroundDraft = ""
                return nil
            }
        } else {
            pinnedElement = identity
        }
        return (snapshot, element)
    }

    /// False while routed: the window being driven is deliberately NOT in
    /// front of the user, so its labels cannot vouch for URL content.
    var screenNamesAreUserVisible: Bool {
        routed ? false : system.screenNamesAreUserVisible
    }

    /// While routed, `wait_frontmost` is polling this host's own readiness —
    /// re-opening the app would drop the pinned window (`openTargetApp` resets
    /// `targetWindowID`/`everReady`/`pinnedElement`) or `unroute()` into the
    /// foreground path and take the screen.
    var isDrivingInBackground: Bool { routed }

    func visibleNames() -> [String] {
        guard routed else { return system.visibleNames() }
        guard snapshotLineage == .valid,
              let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              !snapshot.degraded
        else { return [] }
        var names: [String] = []
        var seen = Set<String>()
        for element in snapshot.elements {
            guard let candidate = ScreenContext.nameCandidate(
                element.authoredLabel ?? "")
            else { continue }
            if seen.insert(candidate.lowercased()).inserted {
                names.append(candidate)
            }
            if names.count >= 40 { break }
        }
        return names
    }

    func uiSnapshot() -> ActionUISnapshot? {
        // Foreground Action Mode uses the host's native AX capability map;
        // a background target exposes Cua's exact structured capabilities.
        guard routed else { return system.uiSnapshot() }
        guard snapshotLineage == .valid, targetReady,
              let windowID = targetWindowID,
              let driver = snapshotTarget(maxElements: Self.snapshotElements)
        else {
            routedUISnapshot = nil
            return nil
        }
        let snapshotID: String
        if driver.degraded {
            // Cua still proves exact PID/window ownership when Electron cannot
            // expose this hidden window's AX tree. This identity has no
            // elements and therefore authorizes only the separately attested
            // final presentation; every content action remains impossible.
            snapshotID = "cua-window-\(targetPID)-\(windowID)"
        } else {
            guard let driverID = driver.id, !driverID.isEmpty else {
                routedUISnapshot = nil
                return nil
            }
            snapshotID = driverID
        }
        let visibleElements: [CuaElement] = driver.degraded ? [] : driver.elements
        let primary = driver.primaryTextElement
        let elements = visibleElements.map { element in
            ActionUIElement(
                index: element.index, parentIndex: element.parentIndex,
                depth: element.depth, role: element.role,
                label: element.authoredLabel, frame: element.frame,
                actions: element.actionNames,
                enabled: element.enabled,
                selected: element.selected,
                focused: primary?.index == element.index,
                inWebContent: element.inWebContent)
        }
        let observation = ActionUISnapshot(
            id: snapshotID, source: .cua,
            appName: targetName, bundleID: targetBundleID,
            windowTitle: frontmostWindowTitle() ?? "", windowID: windowID,
            complete: driver.complete, elements: elements)
        routedUISnapshot = RoutedUISnapshot(
            observation: observation, driver: driver, pid: targetPID,
            windowID: windowID, bundleID: targetBundleID)
        return observation
    }

    func frontmostPageURL() -> String? {
        routed ? nil : system.frontmostPageURL()
    }

    // MARK: - Input delivery

    func openURL(_ url: URL) -> Bool {
        // NSWorkspace may activate the default handler. Under the background
        // contract, an unsupported URL route refuses and leaves user focus
        // untouched. Turning background actions off explicitly restores the
        // classic foreground behavior.
        guard !backgroundEnabled() else { return false }
        return system.openURL(url)
    }

    /// Drops the background route. The draft is dropped with the target: text
    /// delivered to the old
    /// window must never authorize a commit in the new one.
    private func unroute() {
        routed = false
        foregroundTarget = nil
        targetPID = 0
        targetWindowID = nil
        targetName = ""
        targetBundleID = ""
        targetReady = false
        foregroundAtInteraction = false
        everReady = false
        pinnedElement = nil
        routedUISnapshot = nil
        resetSnapshotLineage()
        backgroundDraft = ""
    }

    func pressElement(label: String, expecting bundleID: String?) -> Bool {
        guard routed else {
            return system.pressElement(label: label, expecting: bundleID)
        }
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              !snapshot.degraded, snapshot.complete
        else { return false }
        guard let element = CuaPressPick.candidate(
            in: snapshot.elements, label: label),
              let token = element.token else { return false }
        guard case .success(let reply) = transport.call("click", arguments: [
            "pid": targetPID, "element_token": token,
        ], timeout: Self.callTimeout) else { return false }
        guard clickSucceeded(reply) else { return false }
        // A click can move focus or replace the editor. Content delivered to
        // the old field must never authorize a later committing key.
        backgroundDraft = ""
        pinnedElement = nil
        return true
    }

    func pressElement(index: Int, snapshotID: String, label: String,
                      role: String, expecting bundleID: String?) -> Bool {
        guard routed else {
            return system.pressElement(
                index: index, snapshotID: snapshotID, label: label,
                role: role, expecting: bundleID)
        }
        guard snapshotLineage == .valid,
              let cached = routedUISnapshot,
              cached.observation.id == snapshotID,
              cached.pid == targetPID,
              cached.windowID == targetWindowID,
              cached.bundleID == targetBundleID,
              expectedMatchesTarget(bundleID), targetReady,
              let record = cached.observation.elements.first(where: {
                  $0.index == index
              }),
              record.role == role,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(label),
              !ActionPlan.pressLabelIsCommitting(label),
              let prior = cached.driver.elements.first(where: {
                  $0.index == index
              }),
              record.actions.contains(ActionUICapability.cuaClick),
              prior.token?.isEmpty == false
        else { return false }
        guard let current = snapshotTarget(maxElements: Self.snapshotElements)
        else { return false }
        defer { routedUISnapshot = nil }
        guard !current.degraded,
              let currentID = current.id, !currentID.isEmpty,
              let element = current.elements.first(where: { $0.index == index }),
              let token = element.token, !token.isEmpty,
              sameElementIdentity(
                element, prior: prior, role: role, label: label)
        else { return false }
        guard case .success(let reply) = transport.call("click", arguments: [
            "pid": targetPID, "window_id": cached.windowID,
            "element_token": token, "element_index": index,
            "snapshot_id": currentID,
        ], timeout: Self.callTimeout), clickSucceeded(reply) else { return false }
        backgroundDraft = ""
        pinnedElement = nil
        return true
    }

    func verifyElement(index: Int, snapshotID: String, label: String,
                       role: String, target: String,
                       expecting bundleID: String?,
                       purpose: ActionVerificationPurpose) -> Bool {
        guard routed else {
            return system.verifyElement(
                index: index, snapshotID: snapshotID, label: label,
                role: role, target: target, expecting: bundleID,
                purpose: purpose)
        }
        return verifyRoutedTarget(
            index: index, snapshotID: snapshotID, label: label,
            role: role, target: target, expecting: bundleID,
            purpose: purpose)
    }

    private func verifyRoutedTarget(
        index: Int, snapshotID: String, label: String, role: String,
        target: String, expecting bundleID: String?,
        purpose: ActionVerificationPurpose
    ) -> Bool {
        guard purpose == .target, snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let cached = routedUISnapshot,
              cached.observation.complete, cached.driver.complete,
              cached.observation.id == snapshotID,
              cached.pid == targetPID, cached.windowID == targetWindowID,
              cached.bundleID == targetBundleID,
              let record = cached.observation.elements.first(where: {
                  $0.index == index
              }),
              record.focused, !record.inWebContent,
              let prior = cached.driver.elements.first(where: {
                  $0.index == index
              }),
              prior == cached.driver.primaryTextElement,
              prior.token?.isEmpty == false,
              prior.role == role,
              AppMatcher.normalize(prior.authoredLabel ?? "")
                == AppMatcher.normalize(label),
              ScreenContext.isEditableActionRole(role),
              AppMatcher.bestMatch(for: target, in: [label]) != nil,
              let current = snapshotTarget(maxElements: Self.snapshotElements),
              !current.degraded, current.complete,
              let element = current.primaryTextElement,
              element.index == index,
              sameElementIdentity(
                element, prior: prior, role: role, label: label)
        else { return false }
        let identity = ElementIdentity(element)
        if let pinnedElement, pinnedElement != identity {
            return false
        }
        pinnedElement = identity
        return true
    }

    func foregroundWindow() -> ActionWindowIdentity? {
        routed ? nil : system.foregroundWindow()
    }

    func actionWindow() -> ActionWindowIdentity? {
        guard routed else { return system.actionWindow() }
        guard let windowID = targetWindowID else { return nil }
        return ActionWindowIdentity(
            name: targetName, bundleID: targetBundleID,
            pid: targetPID, windowID: windowID)
    }

    func actionProcess() -> ActionProcessIdentity? {
        guard routed else { return system.actionProcess() }
        guard snapshotLineage == .valid else { return nil }
        if targetReady {
            guard verifyTargetAlive() else { return nil }
        } else {
            guard advanceReadiness() else { return nil }
        }
        guard targetReady, everReady,
              targetPID > 0, !targetName.isEmpty, !targetBundleID.isEmpty,
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame else { return nil }
        return ActionProcessIdentity(
            name: targetName, bundleID: targetBundleID, pid: targetPID)
    }

    func mediaControl(_ state: ActionMediaState) -> ActionMediaControlResult {
        guard routed else { return system.mediaControl(state) }
        guard let target = actionProcess() else { return .unavailable }
        return MediaPlaybackSystem.setPlayback(
            state, bundleID: target.bundleID, pid: target.pid)
    }

    private func presentationTargetIsLive(windowID: Int) -> Bool {
        guard routed, snapshotLineage == .valid, targetReady,
              resolveDeferredWindow(), targetWindowID == windowID,
              let liveBundleID = bundleForPID(targetPID),
              liveBundleID.caseInsensitiveCompare(targetBundleID) == .orderedSame
        else { return false }
        return true
    }

    func presentUI(snapshotID: String, bundleID: String, windowID: Int,
                   scope: ActionPresentationScope = .window) -> Bool {
        guard routed, snapshotLineage == .valid, targetReady,
              let cached = routedUISnapshot,
              cached.observation.source == .cua,
              cached.observation.id == snapshotID,
              cached.observation.bundleID.lowercased() == bundleID.lowercased(),
              cached.observation.windowID == windowID,
              cached.pid == targetPID, cached.windowID == windowID,
              cached.bundleID == targetBundleID,
              waitForQuiet()
        else { return false }

        let inputGeneration = UserInputActivity.snapshot()
        guard interactionIsQuiet(),
              inputGeneration == UserInputActivity.snapshot(),
              presentationTargetIsLive(windowID: windowID)
        else { return false }
        if exactTargetIsForeground(windowID: windowID) {
            unroute()
            return true
        }
        guard let front = system.frontmostApp(),
              let prior = captureFocus(front)
        else { return false }
        let priorWindow: ActionWindowIdentity?
        if case .window(let window) = prior {
            priorWindow = window
        } else {
            priorWindow = nil
        }
        guard scope != .app || priorWindow != nil else { return false }
        guard interactionIsQuiet(),
              inputGeneration == UserInputActivity.snapshot(),
              presentationTargetIsLive(windowID: windowID)
        else {
            return false
        }

        let result = transport.call(Self.presentationTool, arguments: [
            "pid": targetPID, "window_id": windowID,
        ], timeout: Self.callTimeout)
        guard inputGeneration == UserInputActivity.snapshot() else {
            _ = restoreAfterUserInput(
                prior, generation: inputGeneration, pid: targetPID,
                windowID: windowID, bundleID: targetBundleID)
            return false
        }
        let reply: [String: Any]?
        if case .success(let value) = result {
            reply = value
        } else {
            reply = nil
        }
        if let reply {
            if presentationMatches(
                    reply, pid: targetPID, windowID: windowID) {
                guard inputGeneration == UserInputActivity.snapshot() else {
                    _ = restoreAfterUserInput(
                        prior, generation: inputGeneration, pid: targetPID,
                        windowID: windowID, bundleID: targetBundleID)
                    return false
                }
                unroute()
                return true
            }
            if scope == .app, let priorWindow, interactionIsQuiet() {
                let matches = appPresentationMatches(
                    reply, pid: targetPID, windowID: windowID)
                let requestMatches = appRequestWindow(
                    reply, pid: targetPID, windowID: windowID) != nil
                guard inputGeneration == UserInputActivity.snapshot() else {
                    _ = restoreAfterUserInput(
                        prior, generation: inputGeneration, pid: targetPID,
                        windowID: windowID, bundleID: targetBundleID)
                    return false
                }
                if matches {
                    unroute()
                    return true
                }
                let priorRestored = requestMatches
                    && restoreWindow(priorWindow)
                guard inputGeneration == UserInputActivity.snapshot() else {
                    _ = restoreAfterUserInput(
                        prior, generation: inputGeneration, pid: targetPID,
                        windowID: windowID, bundleID: targetBundleID)
                    return false
                }
                if priorRestored
                    && activateTargetApp(generation: inputGeneration) {
                    guard inputGeneration == UserInputActivity.snapshot() else {
                        _ = restoreAfterUserInput(
                            prior, generation: inputGeneration,
                            pid: targetPID, windowID: windowID,
                            bundleID: targetBundleID)
                        return false
                    }
                    unroute()
                    return true
                }
                guard inputGeneration == UserInputActivity.snapshot() else {
                    _ = restoreAfterUserInput(
                        prior, generation: inputGeneration, pid: targetPID,
                        windowID: windowID, bundleID: targetBundleID)
                    return false
                }
                if requestMatches {
                    _ = restoreWindow(priorWindow)
                }
            }
        }
        guard inputGeneration == UserInputActivity.snapshot() else {
            _ = restoreAfterUserInput(
                prior, generation: inputGeneration, pid: targetPID,
                windowID: windowID, bundleID: targetBundleID)
            return false
        }
        _ = restoreTargetFocus(
            prior, generation: inputGeneration, pid: targetPID,
            windowID: windowID, bundleID: targetBundleID, reply: reply)
        unroute()
        return false
    }

    private func restoreFocus(_ target: FocusTarget) -> Bool {
        switch target {
        case .app(let bundleID, let pid):
            guard let liveBundleID = bundleForPID(pid),
                  liveBundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
                  case .success(let reply) = transport.call(
                    Self.presentationTool, arguments: ["pid": pid],
                    timeout: Self.callTimeout)
            else { return false }
            return processMatches(reply, pid: pid)
        case .window(let window):
            return restoreWindow(window)
        }
    }

    private func restoreWindow(_ prior: ActionWindowIdentity) -> Bool {
        guard case .success(let reply) = transport.call(
            Self.presentationTool, arguments: [
                "pid": prior.pid, "window_id": prior.windowID,
            ], timeout: Self.callTimeout)
        else { return false }
        return presentationMatches(
            reply, pid: prior.pid, windowID: prior.windowID)
    }

    private func processMatches(_ reply: [String: Any], pid: Int) -> Bool {
        guard reply["status"] as? String == "activated",
              reply["code"] as? String == Self.processPresentationCode,
              exactFlag(reply["activated"]) == true,
              exactFlag(reply["request_accepted"]) == true,
              exactFlag(reply["process_activated"]) == true,
              exactInt(reply["pid"]) == pid,
              reply["window_id"] is NSNull
        else { return false }
        return true
    }

    private func appPresentationMatches(
        _ reply: [String: Any], pid: Int, windowID: Int
    ) -> Bool {
        guard let siblingID = appRequestWindow(
                reply, pid: pid, windowID: windowID),
              siblingID != windowID,
              let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              let window = system.foregroundWindow(),
              window.pid == pid, window.windowID == siblingID,
              window.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame
        else { return false }
        return true
    }

    private func appRequestWindow(
        _ reply: [String: Any], pid: Int, windowID: Int
    ) -> Int? {
        guard reply["status"] as? String == "partial",
              reply["code"] as? String == Self.partialPresentationCode,
              exactFlag(reply[Self.toolErrorMarker]) == true,
              exactFlag(reply["activated"]) == false,
              exactFlag(reply["request_accepted"]) == true,
              exactFlag(reply["process_activated"]) == true,
              exactInt(reply["pid"]) == pid,
              exactInt(reply["window_id"]) == windowID,
              let effect = reply["exact_window_effect"] as? [String: Any],
              exactFlag(effect["verified"]) == false,
              exactFlag(effect["focused"]) == true,
              exactFlag(effect["frontmost_ordinary"]) == false,
              exactFlag(effect["target_visible_ordinary"]) != nil,
              let observed = reply["observed"] as? [String: Any],
              exactInt(observed["frontmost_pid"]) == pid,
              exactInt(observed["focused_window_id"]) == windowID,
              let frontWindowID = exactInt(
                observed["frontmost_ordinary_window_id"]),
              frontWindowID > 0,
              derivedFrontmostPID(observed, targetPID: pid) == pid,
              let liveBundleID = bundleForPID(pid),
              liveBundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame
        else { return nil }
        return frontWindowID
    }

    private func activateTargetApp(generation: UInt64) -> Bool {
        guard generation == UserInputActivity.snapshot(),
              system.openApp(
                named: targetName, bundleID: targetBundleID, pid: targetPID)
                != nil else { return false }
        let deadline = system.now()
            + Double(Self.appActivationWaitMs) / 1_000
        repeat {
            if targetAppIsFront() {
                guard generation == UserInputActivity.snapshot() else {
                    return false
                }
                system.sleep(ms: Self.appActivationStableMs)
                return generation == UserInputActivity.snapshot()
                    && targetAppIsFront()
            }
            guard system.now() < deadline else { return false }
            system.sleep(ms: Self.handoffPollMs)
        } while true
    }

    private func targetAppIsFront() -> Bool {
        guard let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              let window = system.foregroundWindow(),
              window.pid == targetPID,
              window.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame
        else { return false }
        return true
    }

    private func replyProvesTargetFront(
        _ reply: [String: Any], pid: Int
    ) -> Bool {
        guard exactFlag(reply["process_activated"]) == true,
              exactInt(reply["pid"]) == pid,
              let observed = reply["observed"] as? [String: Any],
              exactInt(observed["frontmost_pid"]) == pid,
              derivedFrontmostPID(observed, targetPID: pid) == pid
        else { return false }
        return true
    }

    private func presentationMatches(
        _ reply: [String: Any], pid: Int, windowID: Int
    ) -> Bool {
        CuaWindowActivation.matches(reply, pid: pid, windowID: windowID)
    }

    private func derivedFrontmostPID(
        _ observed: [String: Any], targetPID: Int
    ) -> Int? {
        guard let workspaceRaw = observed["workspace_frontmost_pid"],
              let privateRaw = observed["front_process_matches_target"]
        else { return nil }
        let workspace = nullablePID(workspaceRaw)
        let privateMatch = nullableFlag(privateRaw)
        guard workspace.valid, privateMatch.valid else { return nil }

        // Cua's private front-process result is authoritative when available.
        // AppKit's workspace PID may lag behind a successful private check.
        if let matches = privateMatch.value {
            return matches ? targetPID : nil
        }
        return workspace.value
    }

    private func nullablePID(_ raw: Any) -> (valid: Bool, value: Int?) {
        if raw is NSNull { return (true, nil) }
        guard let value = exactInt(raw) else { return (false, nil) }
        return (true, value)
    }

    private func nullableFlag(_ raw: Any) -> (valid: Bool, value: Bool?) {
        if raw is NSNull { return (true, nil) }
        guard let value = exactFlag(raw) else { return (false, nil) }
        return (true, value)
    }

    private func exactInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }

    private func exactFlag(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func exactNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func sameElementIdentity(
        _ current: CuaElement, prior: CuaElement,
        role: String, label: String
    ) -> Bool {
        current.index == prior.index
            && current.role == role
            && current.parentIndex == prior.parentIndex
            && current.depth == prior.depth
            && current.frame == prior.frame
            && current.enabled == prior.enabled
            && current.selected == prior.selected
            && current.inWebContent == prior.inWebContent
            && AppMatcher.normalize(current.authoredLabel ?? "")
                == AppMatcher.normalize(label)
    }

    func typeText(_ text: String, expecting bundleID: String?) -> Bool {
        guard routed else { return system.typeText(text, expecting: bundleID) }
        return deliverText(text, expecting: bundleID)
    }

    func pasteText(_ text: String, expecting bundleID: String?) -> Bool {
        guard routed else { return system.pasteText(text, expecting: bundleID) }
        // AX insertion is one atomic write; there is no separate paste road.
        return deliverText(text, expecting: bundleID)
    }

    private func deliverText(_ text: String, expecting bundleID: String?) -> Bool {
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID else { return false }
        // Address the write to the target window's own text element. The
        // driver's default target — the PID's focused element — can live in
        // a DIFFERENT window of the same app.
        guard let before = freshPrimaryTextElement(),
              pinnedElement == ElementIdentity(before.element),
              let token = before.element.token else { return false }
        guard let priorValue = before.element.value,
              priorValue == backgroundDraft else {
            backgroundDraft = ""
            return false
        }
        guard case .success(let reply) = transport.call("type_text", arguments: [
            "pid": targetPID, "window_id": windowID, "text": text,
            "element_token": token,
        ], timeout: 10) else { return false }
        guard !isRefused(reply) else { return false }
        // Driver confirmation is not draft ownership. Re-read the SAME field
        // and require its whole value to equal Velora's accumulated text.
        // This refuses pre-existing text, caret drift, and another writer.
        guard let after = freshPrimaryTextElement(),
              pinnedElement == ElementIdentity(after.element) else { return false }
        let expectedValue = priorValue + text
        guard after.element.value == expectedValue else {
            backgroundDraft = ""
            return false
        }
        backgroundDraft = expectedValue
        return true
    }

    func pressKey(name: String, mods: [String], keyCode: CGKeyCode,
                  flags: CGEventFlags, expecting bundleID: String?) -> Bool {
        guard routed else {
            return system.pressKey(name: name, mods: mods, keyCode: keyCode,
                                   flags: flags, expecting: bundleID)
        }
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let driverKey = CuaKeyMap.driverKey(forPlanKey: name),
              let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              !snapshot.degraded
        else { return false }
        var arguments: [String: Any] = [
            "pid": targetPID, "window_id": windowID, "key": driverKey,
        ]
        // A committing key is addressed to the freshly re-read field whose
        // whole value still equals this action's draft.
        let committing = ActionPlan.Limits.committingKeys.contains(name.lowercased())
        if committing {
            guard !backgroundDraft.isEmpty, snapshot.complete,
                  let element = snapshot.primaryTextElement,
                  let pinnedElement,
                  pinnedElement == ElementIdentity(element),
                  element.value == backgroundDraft,
                  let token = element.token, !token.isEmpty,
                  let snapshotID = snapshot.id, !snapshotID.isEmpty
            else {
                backgroundDraft = ""
                return false
            }
            arguments["element_token"] = token
            arguments["element_index"] = element.index
            arguments["snapshot_id"] = snapshotID
        }
        let modifiers = CuaKeyMap.driverModifiers(mods)
        if !modifiers.isEmpty { arguments["modifiers"] = modifiers }
        if committing { backgroundDraft = "" }
        guard case .success(let reply) = transport.call(
            "press_key", arguments: arguments, timeout: Self.callTimeout)
        else { return false }
        guard !isRefused(reply) else { return false }
        return true
    }

    // MARK: - Machine state

    /// The dictation typing target is a foreground concept; routed mode uses
    /// the complete tree's one non-web primary element, pinned to the exact
    /// target window before mutation.
    var hasFocusedTextTarget: Bool {
        guard routed else { return system.hasFocusedTextTarget }
        guard snapshotLineage == .valid, targetReady else { return false }
        return freshPrimaryTextElement() != nil
    }

    var canPostInput: Bool {
        guard routed else { return system.canPostInput }
        guard snapshotLineage == .valid else { return false }
        // The driver's AX write path does not synthesize global events, so
        // the CGEvent preflight is not required. Locked screens and secure
        // input still refuse.
        return accessibilityGranted()
            && !SecureInput.isActive
            && !system.screenIsLocked
    }

    var screenIsLocked: Bool { system.screenIsLocked }

    func sleep(ms: Int) { system.sleep(ms: ms) }

    func now() -> TimeInterval { system.now() }

    // MARK: - Helpers

    private func expectedMatchesTarget(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return bundleID.caseInsensitiveCompare(targetBundleID) == .orderedSame
    }

    /// A refusal normally arrives as a transport failure now — the driver
    /// marks it `isError` and the parser turns that into `.daemonError` with
    /// the refusal code. This stays as depth for any tool that reports a
    /// refusal inside an otherwise-successful reply.
    private func isRefused(_ reply: [String: Any]) -> Bool {
        if reply["refusal"] != nil { return true }
        if (reply["status"] as? String) == "refused" { return true }
        if (reply["effect"] as? String) == "refused" { return true }
        return false
    }

    private func clickSucceeded(_ reply: [String: Any]) -> Bool {
        guard !isRefused(reply), let effect = reply["effect"] as? String else {
            return false
        }
        return effect == "confirmed" || effect == "unverifiable"
    }
}
