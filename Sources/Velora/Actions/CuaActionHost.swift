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
    /// Content-committing actions may resolve and observe here, but their first
    /// interaction is deferred to an exact foreground handoff. Browsers remain
    /// excluded because web content does not honor AX value writes reliably
    /// (the driver itself reports them "unverifiable").
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
        let complete = (payload["elements_complete"] as? Bool) ?? false
        return CuaSnapshot(id: payload["snapshot_id"] as? String,
                           degraded: degraded,
                           complete: complete,
                           elements: elements)
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
        guard complete else { return nil }
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
        let candidates = windows.compactMap { raw -> (id: Int, title: String?, z: Int)? in
            guard (raw["pid"] as? Int) == pid,
                  (raw["layer"] as? Int) == 0,
                  let id = raw["window_id"] as? Int else { return nil }
            let bounds = raw["bounds"] as? [String: Any]
            let width = (bounds?["width"] as? Double) ?? 0
            let height = (bounds?["height"] as? Double) ?? 0
            guard width >= minimumWidth, height >= minimumHeight else { return nil }
            let title = (raw["title"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            return (id, title, (raw["z_index"] as? Int) ?? 0)
        }
        // A titled window is a document; untitled ones are panels and
        // overlays. Within each class the topmost wins — z-order is what the
        // app itself would bring forward, which is what "the window" means.
        let titled = candidates.filter { $0.title != nil }
        let pool = titled.isEmpty ? candidates : titled
        return pool.max { $0.z < $1.z }.map { ($0.id, $0.title) }
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
/// activation stayed suppressed. Explicit Foreground cases—current app,
/// browsers, or a disabled setting—delegate to `SystemActionHost`. Sending
/// targets stay routed for observation and defer their foreground transition
/// until interaction. Driver failures fail closed.
///
/// Validation is unchanged on purpose: the same `ActionPlan` decode, the same
/// `ActionRuntimePolicy`, the same executor invariants run against this host.
/// The driver only changes WHERE verified steps are delivered.
final class BackgroundRoutingActionHost: ActionHost {
    /// Tree-only snapshots; screenshots are for humans and cost ~250 KB each.
    /// The element cap matches the driver's own default walk bound. Routed
    /// trees stay partial; an exact action is bound to one observed element
    /// and a fresh driver reread instead of treating the cap as completeness.
    private static let snapshotElements = 2000
    private static let callTimeout: TimeInterval = 3.0
    private static let maximumSnapshotIDs = 512
    private static let maximumSnapshotIDBytes = 128
    private static let presentationTool = "bring_to_front"
    private static let presentationCode =
        "bring_to_front_exact_window_verified"
    private static let processPresentationCode =
        "bring_to_front_process_verified"
    private static let handoffQuietSeconds: TimeInterval = 0.5
    private static let handoffWaitMs = 5_000
    private static let handoffPollMs = 50
    private let system: ActionHost
    private let transport: CuaTransport
    private let backgroundEnabled: () -> Bool
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
    private var targetPID: Int = 0
    private var targetWindowID: Int?
    private var targetName = ""
    private var targetBundleID = ""
    private var targetReady = false
    /// This route may be observed in place, but its first mutation must cross
    /// the exact-window foreground boundary and continue through native AX.
    private var foregroundAtInteraction = false
    /// Space membership alone is not a refusal. If Cua cannot resolve this
    /// exact off-Space AX tree, defer it to the foreground boundary instead.
    private var handoffIfDegraded = false
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
    private var pinnedElement: (index: Int, role: String)?
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
            guard let index = AppMatcher.bestMatch(
                for: name, in: running.map { $0.localizedName ?? "" }),
                  let bundleID = running[index].bundleIdentifier else { return nil }
            return (running[index].localizedName ?? name, bundleID)
        }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    func beginActionInputSession() {
        unroute()
        contentMayCommit = false
        system.beginActionInputSession()
    }

    func endActionInputSession() {
        unroute()
        contentMayCommit = false
        system.endActionInputSession()
        endDaemon()
    }

    func prepareForActionPlan(sends: Bool) {
        contentMayCommit = sends
        if sends && routed { foregroundAtInteraction = true }
    }

    func prepareInteraction() -> ActionInteractionState {
        guard routed, foregroundAtInteraction else { return .ready }
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
        guard case .success(let reply) = result,
              presentationMatches(reply, pid: targetPID, windowID: windowID)
        else {
            _ = restoreHandoffFocus(
                prior, pid: targetPID, windowID: windowID,
                bundleID: targetBundleID)
            unroute()
            endDaemon()
            return .refused
        }

        finishHandoff(windowID: windowID)
        return .ready
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
            return system.openApp(named: name)
        }
        // Resolve the target BEFORE deciding, so the gate judges the actual
        // app (bundle id included), not the spoken words.
        guard ensureDaemon(transport),
              let resolved = resolveApp(named: name) else { return nil }
        guard BackgroundActionGate.shouldRoute(
            enabled: true, contentMayCommit: contentMayCommit,
            targetName: resolved.name,
            targetBundleID: resolved.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) else {
            return system.openApp(named: name)
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
    /// foreground-only target ends routing and delegates; routing failures do
    /// not silently activate a different app on the user's screen.
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
            return system.openApp(named: name)
        }
        guard let resolved = resolveApp(named: name) else {
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
            return system.openApp(named: name)
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

    private func resolveApp(named name: String) -> ResolvedApp? {
        guard case .success(let reply) = transport.call(
            "list_apps", arguments: [:], timeout: Self.callTimeout),
              let apps = reply["apps"] as? [[String: Any]] else { return nil }
        let names = apps.map { ($0["name"] as? String) ?? "" }
        guard let index = AppMatcher.bestMatch(for: name, in: names),
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
                foregroundAtInteraction: contentMayCommit,
                handoffIfDegraded: false)
            return .routed
        case .offSpace(let pid, let windowID):
            beginRoute(
                resolved, pid: pid, windowID: windowID,
                foregroundAtInteraction: contentMayCommit,
                handoffIfDegraded: true)
            return .routed
        case .missing:
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
        // Cua owns background launch. Velora accepts only the driver's exact
        // suppression attestation plus a read-only foreground check; it never
        // tries to repair focus with another activation.
        let launchResult = transport.call(
            "launch_app", arguments: ["bundle_id": resolved.bundleID],
            timeout: 10)
        guard case .success(let launched) = launchResult,
              exactFlag(launched["self_activation_suppressed"]) == true,
              let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(resolved.bundleID)
                != .orderedSame else { return false }
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
            foregroundAtInteraction: contentMayCommit,
            handoffIfDegraded: false)
        return true
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
        foregroundAtInteraction: Bool, handoffIfDegraded: Bool
    ) {
        routed = true
        targetPID = pid
        targetName = resolved.name
        targetBundleID = resolved.bundleID.lowercased()
        targetWindowID = windowID
        targetReady = false
        self.foregroundAtInteraction = foregroundAtInteraction
        self.handoffIfDegraded = handoffIfDegraded
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

    private func restoreHandoffFocus(
        _ prior: FocusTarget, pid: Int, windowID: Int, bundleID: String
    ) -> Bool {
        guard let front = system.frontmostApp(),
              let window = system.foregroundWindow()
        else { return true }
        guard front.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
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
        return restoreHandoffFocus(
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
        // fine": the executor aborts instead of typing into nothing.
        guard let snapshot = snapshotTarget(maxElements: 1),
              !snapshot.degraded else {
            targetReady = false
            return false
        }
        return true
    }

    private func advanceReadiness() -> Bool {
        guard snapshotLineage == .valid else { return false }
        // Re-picking is allowed ONLY while the target has never been ready:
        // a cold-launched app's real document window can appear after the
        // first look. Once ready, the window is pinned for the rest of the
        // action — re-picking then would silently retarget at a different
        // window of the same app (review finding), the background analog of
        // typing into whatever took focus.
        if targetWindowID == nil || !everReady {
            guard let window = pickTargetWindow() else { return false }
            targetWindowID = window.id
        }
        guard let snapshot = snapshotTarget(maxElements: 10) else { return false }
        if snapshot.degraded {
            guard handoffIfDegraded else { return false }
            foregroundAtInteraction = true
            guard resolveDeferredWindow() else { return false }
        }
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

    private func snapshotTarget(maxElements: Int) -> CuaSnapshot? {
        guard snapshotLineage == .valid,
              let windowID = targetWindowID else { return nil }
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
        // An unresolved Cua observation is non-actionable and carries no
        // lineage while Electron enables AX. Retry that exact shape; degraded
        // replies that do carry IDs still participate in replay detection.
        if snapshot.degraded, snapshot.id?.isEmpty != false { return snapshot }
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
    /// call pins; every later call must find the SAME element (index and
    /// role) or it refuses — a window whose editable surfaces changed under
    /// the action is not a target the plan ever verified.
    private func freshPrimaryTextElement()
        -> (snapshot: CuaSnapshot, element: CuaElement)? {
        guard let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              let element = snapshot.primaryTextElement else {
            backgroundDraft = ""
            return nil
        }
        if let pinnedElement {
            guard pinnedElement.index == element.index,
                  pinnedElement.role == element.role else {
                // The draft belonged to the element that just went away.
                backgroundDraft = ""
                return nil
            }
        } else {
            pinnedElement = (element.index, element.role)
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
              let snapshot = snapshotTarget(maxElements: Self.snapshotElements)
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
        // a background target exposes Cua's exact structured capabilities but
        // never promotes its actionable projection to a complete UI tree.
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
        let elements = visibleElements.map { element in
            ActionUIElement(
                index: element.index, parentIndex: element.parentIndex,
                depth: element.depth, role: element.role,
                label: element.authoredLabel, frame: element.frame,
                actions: element.actionNames,
                enabled: element.enabled,
                selected: element.selected, focused: false,
                inWebContent: element.inWebContent)
        }
        let observation = ActionUISnapshot(
            id: snapshotID, source: .cua,
            appName: targetName, bundleID: targetBundleID,
            windowTitle: frontmostWindowTitle() ?? "", windowID: windowID,
            complete: false, elements: elements)
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
        // A URL hands off to the default browser IN THE FOREGROUND, so the
        // action leaves the background world entirely: clearing routing here
        // stops every later observation from describing a window the plan no
        // longer means (review finding).
        unroute()
        return system.openURL(url)
    }

    /// Returns to classic foreground behavior for the rest of this action.
    /// The draft is dropped with the target: text delivered to the old
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
        handoffIfDegraded = false
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
              cached.observation.id == snapshotID,
              cached.pid == targetPID, cached.windowID == targetWindowID,
              cached.bundleID == targetBundleID,
              let prior = cached.driver.elements.first(where: {
                  $0.index == index
              }),
              prior.role == role,
              AppMatcher.normalize(prior.authoredLabel ?? "")
                == AppMatcher.normalize(label),
              ScreenContext.isEditableActionRole(role),
              AppMatcher.bestMatch(for: target, in: [label]) != nil,
              let current = snapshotTarget(maxElements: Self.snapshotElements),
              !current.degraded,
              let element = current.elements.first(where: { $0.index == index }),
              sameElementIdentity(
                element, prior: prior, role: role, label: label)
        else {
            routedUISnapshot = nil
            return false
        }
        routedUISnapshot = nil
        guard prepareInteraction() == .ready,
              let native = system.uiSnapshot(), native.source == .native,
              native.bundleID.caseInsensitiveCompare(cached.bundleID)
                == .orderedSame,
              native.windowID == cached.windowID else { return false }
        let matches = native.elements.filter {
            $0.role == role
                && AppMatcher.normalize($0.label ?? "")
                    == AppMatcher.normalize(label)
        }
        guard matches.count == 1, let match = matches.first else { return false }
        return system.verifyElement(
            index: match.index, snapshotID: native.id, label: label,
            role: role, target: target, expecting: bundleID,
            purpose: purpose)
    }

    func foregroundWindow() -> ActionWindowIdentity? {
        routed ? nil : system.foregroundWindow()
    }

    private func presentationTargetIsLive(windowID: Int) -> Bool {
        guard routed, snapshotLineage == .valid, targetReady,
              resolveDeferredWindow(), targetWindowID == windowID,
              let liveBundleID = bundleForPID(targetPID),
              liveBundleID.caseInsensitiveCompare(targetBundleID) == .orderedSame
        else { return false }
        return true
    }

    func presentUI(snapshotID: String, bundleID: String, windowID: Int) -> Bool {
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
        guard case .success(let reply) = result,
              presentationMatches(reply, pid: targetPID, windowID: windowID)
        else {
            _ = restoreHandoffFocus(
                prior, pid: targetPID, windowID: windowID,
                bundleID: targetBundleID)
            unroute()
            return false
        }
        unroute()
        return true
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

    private func presentationMatches(
        _ reply: [String: Any], pid: Int, windowID: Int
    ) -> Bool {
        guard reply["status"] as? String == "activated",
              reply["code"] as? String == Self.presentationCode,
              exactFlag(reply["activated"]) == true,
              exactFlag(reply["request_accepted"]) == true,
              exactFlag(reply["process_activated"]) == true,
              exactInt(reply["pid"]) == pid,
              exactInt(reply["window_id"]) == windowID,
              let effect = reply["exact_window_effect"] as? [String: Any],
              exactFlag(effect["verified"]) == true,
              exactFlag(effect["focused"]) == true,
              exactFlag(effect["frontmost_ordinary"]) == true,
              exactFlag(effect["target_visible_ordinary"]) == true,
              let observed = reply["observed"] as? [String: Any],
              exactInt(observed["frontmost_pid"]) == pid,
              exactInt(observed["focused_window_id"]) == windowID,
              exactInt(observed["frontmost_ordinary_window_id"]) == windowID,
              derivedFrontmostPID(observed, targetPID: pid) == pid
        else { return false }
        return true
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
              let token = before.element.token else { return false }
        let priorValue = before.element.value ?? ""
        guard case .success(let reply) = transport.call("type_text", arguments: [
            "pid": targetPID, "window_id": windowID, "text": text,
            "element_token": token,
        ], timeout: 10) else { return false }
        guard !isRefused(reply) else { return false }
        if (reply["effect"] as? String) == "confirmed" {
            backgroundDraft += text
            return true
        }
        // The driver could not prove delivery, so Velora proves it: the SAME
        // element's value must have CHANGED and must now carry the
        // insertion. A plain "the text appears somewhere" check certifies a
        // false positive when the document already contained it (review
        // finding) — and matching the driver's own web-content rule, an
        // element under an AXWebArea is never a background target at all.
        guard let after = freshPrimaryTextElement(),
              after.element.index == before.element.index,
              after.element.role == before.element.role else { return false }
        let newValue = after.element.value ?? ""
        guard newValue != priorValue, newValue.contains(text) else { return false }
        backgroundDraft += text
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
              let driverKey = CuaKeyMap.driverKey(forPlanKey: name)
        else { return false }
        // Defense in depth behind the executor's target-attestation gate: a
        // key that commits text may only be pressed when THIS action
        // delivered the pending text, exactly as the foreground host
        // requires (review finding — `backgroundDraft` existed but nothing
        // read it).
        let committing = ActionPlan.Limits.committingKeys.contains(name.lowercased())
        if committing, backgroundDraft.isEmpty { return false }
        var arguments: [String: Any] = [
            "pid": targetPID, "window_id": windowID, "key": driverKey,
        ]
        let modifiers = CuaKeyMap.driverModifiers(mods)
        if !modifiers.isEmpty { arguments["modifiers"] = modifiers }
        guard case .success(let reply) = transport.call(
            "press_key", arguments: arguments, timeout: Self.callTimeout)
        else { return false }
        guard !isRefused(reply) else { return false }
        if committing { backgroundDraft = "" }
        return true
    }

    // MARK: - Machine state

    /// The dictation typing target is a foreground concept; in routed mode
    /// the equivalent proof is an editable text element in the TARGET window.
    /// Focus inside the background window cannot be read yet, so this is the
    /// weaker "the window has somewhere for text to go" — acceptable because
    /// routing excludes every app with send authority.
    var hasFocusedTextTarget: Bool {
        guard routed else { return system.hasFocusedTextTarget }
        guard snapshotLineage == .valid, targetReady else { return false }
        return freshPrimaryTextElement() != nil
    }

    var canPostInput: Bool {
        guard routed else { return system.canPostInput }
        guard snapshotLineage == .valid else { return false }
        // The driver's AX write path does not synthesize global events, so
        // the CGEvent preflight is not required. A committing route leaves
        // Cua before mutation; locked screens and secure input still refuse.
        return Permissions.accessibilityGranted
            && !SecureInput.isActive
            && !system.screenIsLocked
    }

    var screenIsLocked: Bool { system.screenIsLocked }

    func sleep(ms: Int) { system.sleep(ms: ms) }

    func now() -> TimeInterval { system.now() }

    // MARK: - Helpers

    private func expectedMatchesTarget(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return bundleID.lowercased() == targetBundleID
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
