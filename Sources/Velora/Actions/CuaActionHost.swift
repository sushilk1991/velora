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
    /// Communication apps are deliberately excluded: their send authority is
    /// built on the foreground evidence chain (focused-field labels, selection
    /// readbacks) that a background window cannot provide yet. Browsers are
    /// excluded because web content does not honor AX value writes reliably
    /// (the driver itself reports them "unverifiable"). Both fall back to the
    /// classic foreground path — worse for the user's flow, but with every
    /// proven guarantee intact.
    static func shouldRoute(enabled: Bool,
                            targetName: String,
                            targetBundleID: String,
                            frontmostName: String?,
                            frontmostBundleID: String?) -> Bool {
        guard enabled else { return false }
        if ActionRuntimePolicy.isCommunicationBundle(targetBundleID) { return false }
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
    let enabled: Bool

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
                enabled: (raw["enabled"] as? Bool) ?? true)
        }
        // Completeness comes from the COUNTS, not from `elements_complete`:
        // driver 0.21.0 reports that flag false even on a walk that plainly
        // finished (verified live — 67 of 67 elements, flag false), so
        // trusting it would refuse every background target. The flag is
        // still honoured when it says true, in case a later driver fixes it.
        //
        // The comparison uses the elements actually PARSED, not a reported
        // count: the driver has three different count fields, and the only
        // number Velora can vouch for is how many nodes it holds.
        let total = payload["total_element_count"] as? Int
        let flagged = (payload["elements_complete"] as? Bool) ?? false
        var complete = flagged
        if let total, total > 0, elements.count >= total { complete = true }
        return CuaSnapshot(id: payload["snapshot_id"] as? String,
                           degraded: degraded,
                           complete: complete,
                           elements: elements)
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
        guard let chosen, !hasWebAreaAncestor(chosen) else { return nil }
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
/// denylist judged on the element's full text, allowed roles only, and an
/// ancestor walk for the Electron/table pattern where the text lives on a
/// child of the pressable row.
enum CuaPressPick {
    static func candidate(in elements: [CuaElement], label: String,
                          roles: Set<String>) -> CuaElement? {
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
            if roles.contains(element.role) { return element }
            var ancestorIndex = element.parentIndex
            for _ in 0..<3 {
                guard let index = ancestorIndex,
                      let ancestor = byIndex[index] else { break }
                let ancestorText = [ancestor.label, ancestor.value]
                    .compactMap { $0 }.joined(separator: " ")
                if !ancestorText.isEmpty,
                   ActionPlan.pressLabelIsCommitting(ancestorText) { break }
                if roles.contains(ancestor.role) { return ancestor }
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
            "socket": CuaDriver.socketPath,
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
/// is a different, native, non-communication app — with the feature enabled
/// and a healthy daemon — is launched WITHOUT activation and driven in the
/// background; the user's cursor, focus, and typing are never touched.
/// Everything else (acting on the current app, communication apps, browsers,
/// driver missing or sick) falls through to the wrapped `SystemActionHost`
/// unchanged.
///
/// Validation is unchanged on purpose: the same `ActionPlan` decode, the same
/// `ActionRuntimePolicy`, the same executor invariants run against this host.
/// The driver only changes WHERE verified steps are delivered.
final class BackgroundRoutingActionHost: ActionHost {
    /// Tree-only snapshots; screenshots are for humans and cost ~250 KB each.
    /// The element cap matches the driver's own default walk bound — element
    /// selection additionally requires `elements_complete`, so a window too
    /// big to walk refuses rather than acts on a partial view.
    private static let snapshotElements = 2000
    private static let callTimeout: TimeInterval = 3.0
    /// How long `frontmostApp` polling lets a fresh window stay AX-unresolved
    /// before the one permitted materialization flash.
    private static let flashAfterSeconds: TimeInterval = 1.2

    private let system: ActionHost
    private let transport: CuaTransport
    private let backgroundEnabled: () -> Bool
    /// Injectable so the selftest can gate health without spawning a daemon.
    private let ensureDaemon: (CuaTransport) -> Bool
    /// Resolves a spoken app name using Velora's own knowledge, so routing
    /// can be ruled out before a daemon is ever started. Returning nil just
    /// means "can't tell from here" — the driver decides.
    private let localResolve: (String) -> (name: String, bundleID: String)?
    /// Native activation/hide for the materialization flash — injectable so
    /// the selftest never touches real apps. No synthesized keystrokes: a
    /// keystroke-based hide could land in the user's app if activation
    /// silently failed (review finding).
    private let activateApp: (Int) -> Void
    private let hideApp: (Int) -> Bool

    // Routed-target state, reset every action.
    private var routed = false
    private var targetPID: Int = 0
    private var targetWindowID: Int?
    private var targetName = ""
    private var targetBundleID = ""
    private var targetReady = false
    /// True once readiness has succeeded at least once this action. The
    /// materialization flash is permitted ONLY before that — a mid-action
    /// degradation must fail the step, never steal focus between typing
    /// steps (review finding).
    private var everReady = false
    private var flashUsed = false
    /// Flashes across the whole action, however many targets it visits.
    private var flashCount = 0
    private static let maximumFlashes = 2
    private var readinessStarted: TimeInterval?
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

    init(system: ActionHost, transport: CuaTransport,
         backgroundEnabled: @escaping () -> Bool,
         ensureDaemon: @escaping (CuaTransport) -> Bool
            = CuaDriverDaemon.ensureRunning,
         activateApp: @escaping (Int) -> Void
            = BackgroundRoutingActionHost.activateOnMain,
         hideApp: @escaping (Int) -> Bool
            = BackgroundRoutingActionHost.hideOnMain,
         localResolve: @escaping (String) -> (name: String, bundleID: String)?
            = BackgroundRoutingActionHost.resolveRunningApp) {
        self.system = system
        self.transport = transport
        self.backgroundEnabled = backgroundEnabled
        self.ensureDaemon = ensureDaemon
        self.activateApp = activateApp
        self.hideApp = hideApp
        self.localResolve = localResolve
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
        flashUsed = false
        flashCount = 0
        system.beginActionInputSession()
    }

    // MARK: - Routing decision

    func openApp(named name: String) -> String? {
        guard !routed else { return openTargetApp(named: name) }
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
        // never going to route (the app the user is in, a chat app, a
        // browser) must not bring one up (review finding). The driver's
        // answer is still authoritative below; this only avoids the spawn.
        if let local = localResolve(name),
           !BackgroundActionGate.shouldRoute(
            enabled: true, targetName: local.name,
            targetBundleID: local.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) {
            return system.openApp(named: name)
        }
        // Resolve the target BEFORE deciding, so the gate judges the actual
        // app (bundle id included), not the spoken words.
        guard ensureDaemon(transport),
              let resolved = resolveApp(named: name) else {
            return system.openApp(named: name)
        }
        guard BackgroundActionGate.shouldRoute(
            enabled: true,
            targetName: resolved.name,
            targetBundleID: resolved.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID) else {
            return system.openApp(named: name)
        }
        guard activateTarget(resolved) else {
            return system.openApp(named: name)
        }
        veloraLog("Velora: action driving \(resolved.name) in the background")
        return resolved.name
    }

    /// A later `open_app` inside an already-routed action. A target the gate
    /// still accepts becomes the new background target; anything else ends
    /// background mode and runs classically for the rest of the action —
    /// refusing outright would fail plans that legitimately move on to a
    /// browser or a chat app (review finding).
    private func openTargetApp(named name: String) -> String? {
        let frontmost = system.frontmostApp()
        if let resolved = resolveApp(named: name),
           BackgroundActionGate.shouldRoute(
            enabled: true, targetName: resolved.name,
            targetBundleID: resolved.bundleID,
            frontmostName: frontmost?.name,
            frontmostBundleID: frontmost?.bundleID),
           activateTarget(resolved) {
            return resolved.name
        }
        unroute()
        return system.openApp(named: name)
    }

    private struct ResolvedApp {
        let name: String
        let bundleID: String
        let pid: Int
        let running: Bool
    }

    private func resolveApp(named name: String) -> ResolvedApp? {
        guard case .success(let reply) = transport.call(
            "list_apps", arguments: [:], timeout: Self.callTimeout),
              let apps = reply["apps"] as? [[String: Any]] else { return nil }
        let names = apps.map { ($0["name"] as? String) ?? "" }
        guard let index = AppMatcher.bestMatch(for: name, in: names),
              let bundleID = apps[index]["bundle_id"] as? String else { return nil }
        return ResolvedApp(
            name: names[index],
            bundleID: bundleID,
            pid: (apps[index]["pid"] as? Int) ?? 0,
            running: (apps[index]["running"] as? Bool) ?? false)
    }

    private func activateTarget(_ resolved: ResolvedApp) -> Bool {
        var pid = resolved.pid
        if !resolved.running || pid <= 0 {
            guard case .success(let launched) = transport.call(
                "launch_app", arguments: ["bundle_id": resolved.bundleID],
                timeout: 10),
                  let launchedPID = launched["pid"] as? Int, launchedPID > 0
            else { return false }
            pid = launchedPID
        }
        routed = true
        targetPID = pid
        targetName = resolved.name
        targetBundleID = resolved.bundleID.lowercased()
        targetWindowID = nil
        targetReady = false
        everReady = false
        readinessStarted = nil
        // A new target is a new window, a new element, and a new draft:
        // text delivered to the previous app must never authorize a commit
        // here (review finding — `unroute` cleared this, retargeting did
        // not). The materialization allowance travels with the target, but
        // the per-action ceiling still applies.
        pinnedElement = nil
        backgroundDraft = ""
        flashUsed = false
        return true
    }

    // MARK: - Target readiness (drives the executor's wait_frontmost poll)

    /// In routed mode the "frontmost app" IS the background target — but only
    /// once its window exists and its AX surface resolves. Until then this
    /// returns nil, which keeps the executor's `wait_frontmost` polling, and
    /// each poll advances readiness one bounded step.
    func frontmostApp() -> (name: String, bundleID: String)? {
        guard routed else { return system.frontmostApp() }
        if targetReady, verifyTargetAlive() { return (targetName, targetBundleID) }
        guard advanceReadiness() else { return nil }
        return (targetName, targetBundleID)
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
        if readinessStarted == nil { readinessStarted = now() }
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
            maybeFlash()
            return false
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
        guard let windowID = targetWindowID else { return nil }
        let arguments: [String: Any] = [
            "include_screenshot": false,
            "pid": targetPID,
            "window_id": windowID,
            "max_elements": maxElements,
        ]
        guard case .success(let reply) = transport.call(
            "get_window_state", arguments: arguments, timeout: Self.callTimeout)
        else { return nil }
        return CuaSnapshot.parse(reply)
    }

    /// An app that has never been activated since launch sits AX-unresolved:
    /// WindowServer knows its windows, the AX tree reports none (observed
    /// live on macOS 26 for both cold launches AND apps opened backgrounded
    /// earlier). The one fix is one brief activation: activate it, let AX
    /// materialize, hide it again — hiding hands focus back to the user's
    /// app. Native NSRunningApplication calls only, each step verified
    /// against the real frontmost app before the next (review findings: a
    /// synthesized ⌘H after a silently failed activation would hide the
    /// USER'S app). Permitted once per action and only before the target has
    /// ever been ready — never between input steps.
    private func maybeFlash() {
        guard !everReady, !flashUsed, flashCount < Self.maximumFlashes,
              let started = readinessStarted,
              now() - started > Self.flashAfterSeconds,
              !system.screenIsLocked else { return }
        flashUsed = true
        flashCount += 1
        activateApp(targetPID)
        system.sleep(ms: 700)
        // Only hide what actually came forward. If activation was refused,
        // the user's app is still frontmost and must not be touched.
        guard system.frontmostApp()?.bundleID.lowercased() == targetBundleID else {
            veloraLog("Velora: background target refused activation — "
                      + "leaving the screen alone")
            return
        }
        if !hideApp(targetPID) {
            veloraLog("Velora: could not hide the background target after "
                      + "materializing it")
        }
    }

    // MARK: - Observations

    /// Fresh from the window list every call: `verify_context` polls this
    /// while the screen settles, and a title captured once at readiness
    /// would let the check pass on stale evidence (review finding).
    func frontmostWindowTitle() -> String? {
        guard routed else { return system.frontmostWindowTitle() }
        guard let windowID = targetWindowID,
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
        guard targetReady, let element = freshPrimaryTextElement()?.element
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
        guard targetReady else { return nil }
        return freshPrimaryTextElement()?.element.role
    }

    /// The pinned element, re-read from a fresh tree. The first successful
    /// call pins; every later call must find the SAME element (index and
    /// role) or it refuses — a window whose editable surfaces changed under
    /// the action is not a target the plan ever verified.
    private func freshPrimaryTextElement()
        -> (snapshot: CuaSnapshot, element: CuaElement)? {
        guard let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              let element = snapshot.primaryTextElement else { return nil }
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

    func visibleNames() -> [String] {
        guard routed else { return system.visibleNames() }
        guard let snapshot = snapshotTarget(maxElements: Self.snapshotElements)
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
        targetPID = 0
        targetWindowID = nil
        targetName = ""
        targetBundleID = ""
        targetReady = false
        everReady = false
        readinessStarted = nil
        pinnedElement = nil
        backgroundDraft = ""
    }

    func pressElement(label: String, expecting bundleID: String?) -> Bool {
        guard routed else {
            return system.pressElement(label: label, expecting: bundleID)
        }
        // Same authority table as the foreground path. Background routing
        // excludes communication apps and browsers, and `pressRoles` grants
        // press only to those — so today this refuses everything, and it
        // starts working the moment policy grants a background-safe role set.
        guard let roles = ActionRuntimePolicy.pressRoles(forBundleID: targetBundleID),
              expectedMatchesTarget(bundleID), targetReady,
              let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              !snapshot.degraded, snapshot.complete
        else { return false }
        guard let element = CuaPressPick.candidate(
            in: snapshot.elements, label: label, roles: roles),
              let token = element.token else { return false }
        guard case .success(let reply) = transport.call("click", arguments: [
            "pid": targetPID, "element_token": token,
        ], timeout: Self.callTimeout) else { return false }
        return !isRefused(reply)
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
        guard expectedMatchesTarget(bundleID), targetReady,
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
        guard expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let driverKey = CuaKeyMap.driverKey(forPlanKey: name)
        else { return false }
        // Defense in depth behind the executor's communication-bundle gate:
        // a key that commits text may only be pressed when THIS action
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
        guard targetReady else { return false }
        return freshPrimaryTextElement() != nil
    }

    var canPostInput: Bool {
        guard routed else { return system.canPostInput }
        // The driver's AX write path does not synthesize global events, so
        // the CGEvent preflight is not required — but a locked screen or
        // secure input still means "the machine is not ours to drive".
        return Permissions.accessibilityGranted
            && !SecureInput.isActive
            && !system.screenIsLocked
    }

    var screenIsLocked: Bool { system.screenIsLocked }

    func sleep(ms: Int) { system.sleep(ms: ms) }

    func now() -> TimeInterval { system.now() }

    // MARK: - Helpers

    /// Cooperative activation on the main thread. A menubar app's plain
    /// `activate()` is frequently ignored on macOS 14+; yielding first is
    /// what makes the request likely to be granted — the same mechanism
    /// `SystemActionHost.activate` relies on. Safe to `sync` here: the
    /// executor runs on a background queue that main never waits on.
    private static func activateOnMain(pid: Int) {
        let work = {
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid))
            else { return }
            NSApp?.yieldActivation(to: app)
            app.activate(options: [])
        }
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private static func hideOnMain(pid: Int) -> Bool {
        let work: () -> Bool = {
            NSRunningApplication(processIdentifier: pid_t(pid))?.hide() ?? false
        }
        return Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private func expectedMatchesTarget(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return bundleID.lowercased() == targetBundleID
    }

    private func isRefused(_ reply: [String: Any]) -> Bool {
        if reply["refusal"] != nil { return true }
        if (reply["status"] as? String) == "refused" { return true }
        if (reply["effect"] as? String) == "refused" { return true }
        return false
    }
}
