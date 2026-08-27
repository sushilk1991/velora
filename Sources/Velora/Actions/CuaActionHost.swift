import AppKit
import ApplicationServices
import CoreAudio
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
    private static let axWindowCode = "ax_window_unresolved"

    let id: String?
    let degraded: Bool
    let degradedReason: String?
    let refused: Bool
    /// False when the AX walk was truncated. A truncated tree can
    /// MANUFACTURE uniqueness — two text areas where one was cut off looks
    /// like an unambiguous target (review finding) — so element selection
    /// refuses unless the whole tree is in hand.
    let complete: Bool
    let elements: [CuaElement]

    /// Cua may append diagnostics after the stable refusal code. Parse the
    /// code token so added detail cannot disable the exact-window recovery.
    fileprivate var axWindowUnresolved: Bool {
        guard let code = degradedReason?.split(
            separator: ":", maxSplits: 1
        ).first else { return false }
        return code == Self.axWindowCode
    }

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
                           degradedReason: payload["degraded_reason"] as? String,
                           refused: refused,
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

/// Picks one exact document-sized window for a pid. One candidate needs no
/// hint; siblings require one title named by the immutable spoken command.
/// Z-order never decides which same-process document receives an Action.
enum CuaWindowPick {
    /// Smallest thing that can be a document window. Observed live: an app
    /// owns full-width 30-pixel strips (menu-bar surfaces) and 64-pixel save-
    /// panel accessory views that pass any area-only filter — typing into
    /// one of those would be the background version of typing into a random
    /// chrome element.
    static let minimumWidth: Double = 200
    static let minimumHeight: Double = 120
    private static let locatorWords: Set<String> = [
        "called", "document", "file", "in", "inside", "into", "note",
        "titled", "window",
    ]
    private static let directLocatorVerbs: Set<String> = [
        "edit", "open", "show",
    ]

    static func choose(
        _ windows: [[String: Any]], pid: Int, command: String = ""
    ) -> (id: Int, title: String?)? {
        let candidates = windows.compactMap {
            raw -> (id: Int, title: String?, current: Bool?)? in
            guard isEligible(raw, pid: pid),
                  let id = raw["window_id"] as? Int else { return nil }
            let title = (raw["title"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            return (id, title, raw["on_current_space"] as? Bool)
        }
        guard let first = candidates.first else { return nil }
        if candidates.count == 1 { return (first.id, first.title) }
        let named = candidates.filter {
            guard let title = $0.title else { return false }
            return commandNames(title: title, command: command)
        }
        if named.count == 1, let match = named.first {
            return (match.id, match.title)
        }
        guard named.isEmpty else { return nil }
        let current = candidates.filter { $0.current == true }
        guard current.count == 1, let match = current.first else { return nil }
        return (match.id, match.title)
    }

    static func eligible(_ windows: [[String: Any]], pid: Int)
        -> [[String: Any]] {
        windows.filter { isEligible($0, pid: pid) }
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

    private static func commandNames(title: String, command: String) -> Bool {
        let titleWords = words(title)
        let commandWords = words(command)
        guard !titleWords.isEmpty,
              titleWords.count < commandWords.count else { return false }
        for start in 0...(commandWords.count - titleWords.count) {
            let end = start + titleWords.count
            guard Array(commandWords[start..<end]) == titleWords else { continue }
            if start > 0, locatorWords.contains(commandWords[start - 1]) {
                return true
            }
            if start == 1,
               directLocatorVerbs.contains(commandWords[0]) {
                return true
            }
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init)
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
        processIsCurrent: () -> Bool = { true },
        activateStrict: () -> Bool,
        observe: () -> Observation?,
        inputGeneration: () -> UInt64,
        sleep: (Int) -> Void
    ) -> Bool {
        guard pid > 0, windowID > 0, !bundleID.isEmpty else { return false }
        guard generation == inputGeneration(), processIsCurrent() else {
            return false
        }
        let strictAccepted = activateStrict()
        guard generation == inputGeneration(), processIsCurrent() else {
            return false
        }
        if let current = observe(),
           isExact(current, pid: pid, bundleID: bundleID, windowID: windowID) {
            return generation == inputGeneration() && processIsCurrent()
        }

        guard strictAccepted,
              generation == inputGeneration(), processIsCurrent()
        else { return false }
        for attempt in 0..<maximumPolls {
            guard generation == inputGeneration(), processIsCurrent() else {
                return false
            }
            if let current = observe() {
                guard current.pid != pid
                        || current.bundleID.caseInsensitiveCompare(bundleID)
                            != .orderedSame
                        || current.windowID == windowID
                else { return false }
                if isExact(current, pid: pid, bundleID: bundleID,
                           windowID: windowID) {
                    return generation == inputGeneration()
                        && processIsCurrent()
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
    private static let mediaPollMs = 200
    private static let mediaPollAttempts = 15
    private static let verifyTimeoutMs = 1_500
    private static let verifySamples = 2
    private static let primePollMs = 50
    private static let primePollAttempts = 6
    private let system: ActionHost
    private let transport: CuaTransport
    private let backgroundEnabled: () -> Bool
    private let accessibilityGranted: () -> Bool
    /// Injectable so the selftest can gate health without spawning a daemon.
    private let ensureDaemon: (CuaTransport) -> Bool
    private let endDaemon: () -> Void
    private let bundleForPID: (Int) -> String?
    private let interactionIsQuiet: () -> Bool
    private let mediaSnapshot: () -> MediaPlaybackCoordinator.Snapshot
    private let mediaSleep: (Int) -> Void
    private let nativeMedia: NativeMediaAutomation
    private let offSpacePrimer: OffSpaceAXPriming
    private let processIdentity: (Int) -> CuaProcessIdentity?
    private let cursorPosition: () -> CGPoint?
    private let userFocusForWindow: (Int) -> ActionWindowIdentity?
    /// Resolves a spoken app name using Velora's own knowledge, so routing
    /// can be ruled out before a daemon is ever started. Returning nil just
    /// means "can't tell from here" — the driver decides.
    private let localResolve: (String) -> (name: String, bundleID: String)?
    // Routed-target state, reset every action.
    private var routed = false
    private var contentMayCommit = false
    private var sessionCommand = ""
    private var terminalFailureReason: String?
    private var targetPID: Int = 0
    private var targetProcessIdentity: CuaProcessIdentity?
    private var targetWindowID: Int?
    private var targetName = ""
    private var targetBundleID = ""
    private var targetReady = false
    /// True once readiness has succeeded at least once this action.
    private var everReady = false
    private var primeTried = false
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
    private var mutationOrdinal = 0
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
         mediaSnapshot: @escaping () -> MediaPlaybackCoordinator.Snapshot
            = MediaPlaybackSystem.snapshot,
         mediaSleep: @escaping (Int) -> Void = { milliseconds in
             Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
         },
         nativeMedia: NativeMediaAutomation = .shared,
         offSpacePrimer: OffSpaceAXPriming = OffSpaceAXPrimer.shared,
         processIdentity: @escaping (Int) -> CuaProcessIdentity? = {
             CuaProcessIdentity.capture(pid: pid_t($0))
         },
         cursorPosition: @escaping () -> CGPoint? = {
             CGEvent(source: nil)?.location
         },
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
        self.mediaSnapshot = mediaSnapshot
        self.mediaSleep = mediaSleep
        self.nativeMedia = nativeMedia
        self.offSpacePrimer = offSpacePrimer
        self.processIdentity = processIdentity
        self.cursorPosition = cursorPosition
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

    func beginActionInputSession(command: String) {
        unroute()
        sessionCommand = command
        terminalFailureReason = nil
        contentMayCommit = false
        system.beginActionInputSession(command: command)
    }

    func endActionInputSession() {
        unroute()
        sessionCommand = ""
        terminalFailureReason = nil
        contentMayCommit = false
        system.endActionInputSession()
        endDaemon()
    }

    func prepareForActionPlan(sends: Bool) {
        contentMayCommit = sends
    }

    func prepareInteraction() -> ActionInteractionState {
        routed ? waitForTargetIdle() : .ready
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
              targetProcessIsCurrent(),
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame else { return false }
        return true
    }

    // MARK: - Routing decision

    func openApp(named name: String) -> String? {
        guard terminalFailureReason == nil else { return nil }
        guard !routed else { return openTargetApp(named: name) }
        guard backgroundEnabled() else {
            guard let local = localResolve(name),
                  isCurrentTarget(
                    local.bundleID, frontmost: system.frontmostApp())
            else { return nil }
            return local.name
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

    private enum WindowProbe {
        case found(pid: Int, windowID: Int)
        case offSpace(pid: Int, windowID: Int)
        case missing
        case invalid
    }

    private enum RouteResult {
        case routed
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
                resolved, pid: pid, windowID: windowID)
            return .routed
        case .offSpace(let pid, let windowID):
            beginRoute(
                resolved, pid: pid, windowID: windowID)
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
        let eligible = CuaWindowPick.eligible(windows, pid: resolved.pid)
        guard !eligible.isEmpty else { return .missing }
        guard let window = CuaWindowPick.choose(
            eligible, pid: resolved.pid, command: sessionCommand),
              let row = eligible.first(where: {
                  exactInt($0["window_id"]) == window.id
              }) else { return .invalid }
        if exactFlag(row["on_current_space"]) == true {
            return .found(pid: resolved.pid, windowID: window.id)
        }
        return .offSpace(pid: resolved.pid, windowID: window.id)
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
            resolved, pid: pid, windowID: nil)
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
        _ resolved: ResolvedApp, pid: Int, windowID: Int?
    ) {
        routed = true
        targetPID = pid
        targetProcessIdentity = processIdentity(pid)
        targetName = resolved.name
        targetBundleID = resolved.bundleID
        targetWindowID = windowID
        targetReady = false
        everReady = false
        primeTried = false
        // A new target is a new window, a new element, and a new draft:
        // text delivered to the previous app must never authorize a commit
        // here (review finding — `unroute` cleared this, retargeting did
        // not). The materialization allowance travels with the target, but
        // the per-action ceiling still applies.
        pinnedElement = nil
        routedUISnapshot = nil
        resetSnapshotLineage()
        backgroundDraft = ""
        mutationOrdinal = 0
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
        guard terminalFailureReason == nil else { return nil }
        guard routed else { return exactForegroundApp() }
        guard snapshotLineage == .valid else { return nil }
        if targetReady, verifyTargetAlive() { return (targetName, targetBundleID) }
        guard advanceReadiness() else { return nil }
        return (targetName, targetBundleID)
    }

    /// Re-reads WindowServer through Cua without activating the app. Space
    /// membership is nullable private metadata; exact PID/window identity is
    /// the handoff boundary.
    private func resolveDeferredWindow() -> Bool {
        guard routed,
              targetProcessIsCurrent(),
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              case .success(let reply) = transport.call(
                "list_windows", arguments: ["pid": targetPID],
                timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]],
              windows.allSatisfy({ validWindow($0, pid: targetPID) })
        else { return false }

        let eligible = CuaWindowPick.eligible(windows, pid: targetPID)
        if let windowID = targetWindowID {
            return eligible.filter {
                exactInt($0["window_id"]) == windowID
            }.count == 1
        }
        guard let window = CuaWindowPick.choose(
            eligible, pid: targetPID, command: sessionCommand) else {
            return false
        }
        targetWindowID = window.id
        return true
    }

    private func exactForegroundApp() -> (name: String, bundleID: String)? {
        system.frontmostApp()
    }

    private func verifyTargetAlive() -> Bool {
        guard targetProcessIsCurrent() else {
            return failRoute("The exact background target changed.")
        }
        // A vanished target window must read as lost focus, never as "still
        // fine": the executor aborts instead of typing into nothing. A live
        // exact window without AX remains sufficient only for an app-ready
        // result; every mutation method independently requires its UI proof.
        guard let snapshot = snapshotTarget(maxElements: 1) else {
            targetReady = nativeRouteReady()
            return targetReady
        }
        if snapshot.degraded { return recoverDegraded(snapshot) }
        return true
    }

    private func advanceReadiness() -> Bool {
        guard targetProcessIsCurrent() else {
            return failRoute("The exact background target changed.")
        }
        guard snapshotLineage == .valid else { return false }
        // Re-picking is allowed ONLY while the target has never been ready:
        // a cold-launched app's real document window can appear after the
        // first look. Once ready, the window is pinned for the rest of the
        // action — re-picking then would silently retarget at a different
        // window of the same app (review finding), the background analog of
        // typing into whatever took focus.
        if targetWindowID == nil || !everReady {
            if let window = pickTargetWindow() {
                targetWindowID = window.id
            } else {
                return false
            }
        }
        guard let snapshot = snapshotTarget(maxElements: 10) else {
            guard nativeRouteReady() else { return false }
            targetReady = true
            everReady = true
            return true
        }
        if snapshot.degraded {
            guard recoverDegraded(snapshot) else { return false }
        }
        targetReady = true
        everReady = true
        return true
    }

    private func nativeRouteReady() -> Bool {
        guard resolveDeferredWindow(), let target = exactRoutedProcess() else {
            return false
        }
        return nativeMedia.supports(target)
    }

    private struct PrimeWindow: Equatable {
        let title: String?
        let bounds: CGRect
    }

    private struct PrimeLease {
        let process: CuaProcessIdentity
        let window: PrimeWindow
        let foreground: ActionWindowIdentity
        let cursor: CGPoint
        let inputGeneration: UInt64
    }

    /// Some freshly launched AppKit apps publish no off-Space AX windows until
    /// their exact window receives one WindowServer focus record. Hold that
    /// private state only for the bounded semantic re-read, then defocus.
    private func recoverDegraded(_ snapshot: CuaSnapshot) -> Bool {
        if nativeRouteReady() { return true }
        guard !snapshot.refused, snapshot.axWindowUnresolved else {
            return failRoute("The target refused background accessibility.")
        }
        return primeOffSpaceAX()
    }

    private func primeOffSpaceAX() -> Bool {
        guard !primeTried else {
            return failRoute(
                "Restart the target app before retrying this action.")
        }
        primeTried = true
        guard let lease = capturePrimeLease() else {
            return failRoute("The exact background target changed.")
        }

        let result = offSpacePrimer.withPrime(
            pid: targetPID, windowID: targetWindowID ?? 0,
            foregroundPID: lease.foreground.pid,
            foregroundWindowID: lease.foreground.windowID,
            validate: { self.primeLeaseIsLive(lease) }
        ) {
            for attempt in 0..<Self.primePollAttempts {
                guard self.primeLeaseIsLive(lease) else { return false }
                if let snapshot = self.snapshotTarget(
                    maxElements: Self.snapshotElements),
                   !snapshot.degraded {
                    return true
                }
                if attempt + 1 < Self.primePollAttempts {
                    self.system.sleep(ms: Self.primePollMs)
                }
            }
            return false
        } cleanup: {
            self.primeCleanup(lease)
        }
        switch result {
        case .userEnteredTarget, .cancelled:
            return failRoute(
                "Action cancelled because the target window was selected.")
        case .focusFailed, .cleanupFailed:
            return failRoute(
                "Background accessibility is unavailable for this target.")
        case .observationFailed:
            guard processIdentity(targetPID) == lease.process else {
                return failRoute("The exact background target changed.")
            }
            return recoverInForeground()
        case .observed:
            break
        }
        guard primeLeaseRestored(lease),
              let after = snapshotTarget(maxElements: Self.snapshotElements),
              !after.degraded,
              primeLeaseRestored(lease) else {
            return failRoute("The exact background target changed.")
        }
        return true
    }

    /// If the no-raise record cannot materialize AX, briefly foreground only
    /// the exact attested window and immediately restore the exact window that
    /// was in front. AX polling happens after restoration; any physical input
    /// or identity drift closes the lease without granting a capability.
    private func recoverInForeground() -> Bool {
        guard waitForQuiet(),
              let lease = capturePrimeLease(),
              interactionIsQuiet(),
              UserInputActivity.snapshot() == lease.inputGeneration,
              primeLeaseIsLive(lease),
              let windowID = targetWindowID
        else { return failRoute("The exact background target changed.") }

        guard case .success(let reply) = transport.call(
            Self.presentationTool, arguments: [
                "pid": targetPID, "window_id": windowID,
            ], timeout: Self.callTimeout)
        else {
            _ = restoreFallback(lease, windowID: windowID)
            return failRoute(
                "Background accessibility is unavailable for this target.")
        }
        guard presentationMatches(
                reply, pid: targetPID, windowID: windowID),
              foregroundLeaseIsLive(lease)
        else {
            _ = restoreFallback(
                lease, windowID: windowID, reply: reply)
            return failRoute(
                "Background accessibility is unavailable for this target.")
        }

        let inputUnchanged = UserInputActivity.snapshot()
            == lease.inputGeneration
        let restored = restoreFallback(
            lease, windowID: windowID, reply: reply)
        guard inputUnchanged, restored,
              UserInputActivity.snapshot() == lease.inputGeneration,
              fallbackLeaseIsLive(lease)
        else { return failRoute("The exact background target changed.") }

        for attempt in 0..<Self.primePollAttempts {
            guard fallbackLeaseIsLive(lease) else {
                _ = restoreFallback(
                    lease, windowID: windowID, reply: reply)
                return failRoute("The exact background target changed.")
            }
            let snapshot = snapshotTarget(maxElements: Self.snapshotElements)
            guard fallbackLeaseIsLive(lease) else {
                _ = restoreFallback(
                    lease, windowID: windowID, reply: reply)
                return failRoute("The exact background target changed.")
            }
            if let snapshot, !snapshot.degraded { return true }
            if attempt + 1 < Self.primePollAttempts {
                system.sleep(ms: Self.primePollMs)
            }
        }
        return failRoute(
            "Background accessibility is unavailable for this target.")
    }

    private func foregroundLeaseIsLive(_ lease: PrimeLease) -> Bool {
        guard interactionIsQuiet(),
              UserInputActivity.snapshot() == lease.inputGeneration,
              processIdentity(targetPID) == lease.process,
              targetProcessIdentity == lease.process,
              accessibilityGranted(), !SecureInput.isActive,
              !system.screenIsLocked,
              cursorPosition() == lease.cursor,
              let windowID = targetWindowID,
              exactTargetWindow() == lease.window,
              exactTargetIsForeground(windowID: windowID)
        else { return false }
        return interactionIsQuiet()
            && UserInputActivity.snapshot() == lease.inputGeneration
            && processIdentity(targetPID) == lease.process
            && cursorPosition() == lease.cursor
    }

    private func restoreFallback(
        _ lease: PrimeLease, windowID: Int,
        reply: [String: Any]? = nil
    ) -> Bool {
        restoreTargetFocus(
            .window(lease.foreground), generation: lease.inputGeneration,
            pid: targetPID, windowID: windowID,
            bundleID: targetBundleID, reply: reply)
    }

    private func fallbackLeaseIsLive(_ lease: PrimeLease) -> Bool {
        guard interactionIsQuiet(),
              UserInputActivity.snapshot() == lease.inputGeneration,
              primeLeaseRestored(lease)
        else { return false }
        return interactionIsQuiet()
            && UserInputActivity.snapshot() == lease.inputGeneration
            && processIdentity(targetPID) == lease.process
            && cursorPosition() == lease.cursor
    }

    private func capturePrimeLease() -> PrimeLease? {
        let inputGeneration = UserInputActivity.snapshot()
        guard accessibilityGranted(), !SecureInput.isActive,
              !system.screenIsLocked,
              targetProcessIsCurrent(),
              let targetProcessIdentity,
              let process = processIdentity(targetPID),
              process == targetProcessIdentity,
              let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(targetBundleID)
                != .orderedSame,
              let foreground = system.foregroundWindow(),
              foreground.bundleID.caseInsensitiveCompare(front.bundleID)
                == .orderedSame,
              let window = exactOffSpaceWindow(),
              let cursor = cursorPosition()
        else { return nil }
        guard case .unchanged = UserInputActivity.activity(
                after: inputGeneration, targetPID: targetPID,
                targetWindowID: targetWindowID ?? 0),
              let frontAfter = system.frontmostApp(),
              frontAfter.bundleID.caseInsensitiveCompare(front.bundleID)
                == .orderedSame,
              system.foregroundWindow() == foreground,
              cursorPosition() == cursor,
              processIdentity(targetPID) == process,
              targetProcessIdentity == process,
              exactOffSpaceWindow() == window
        else { return nil }
        return PrimeLease(
            process: process, window: window, foreground: foreground,
            cursor: cursor, inputGeneration: inputGeneration)
    }

    private func primeLeaseIsLive(_ lease: PrimeLease) -> Bool {
        let activity = UserInputActivity.activity(
            after: lease.inputGeneration, targetPID: targetPID,
            targetWindowID: targetWindowID ?? 0)
        guard processIdentity(targetPID) == lease.process,
              targetProcessIdentity == lease.process,
              accessibilityGranted(), !SecureInput.isActive,
              !system.screenIsLocked,
              exactOffSpaceWindow() == lease.window
        else { return false }
        switch activity {
        case .unchanged:
            return cursorPosition() == lease.cursor
                && primeFocusIsLive(lease)
        case .unrelated:
            return currentFocusIsNonTarget()
        case .target, .unknown:
            return false
        }
    }

    private func primeFocusIsLive(_ lease: PrimeLease) -> Bool {
        system.foregroundWindow() == lease.foreground
    }

    private func primeLeaseRestored(_ lease: PrimeLease) -> Bool {
        let activity = UserInputActivity.activity(
            after: lease.inputGeneration, targetPID: targetPID,
            targetWindowID: targetWindowID ?? 0)
        guard processIdentity(targetPID) == lease.process,
              targetProcessIdentity == lease.process,
              accessibilityGranted(), !SecureInput.isActive,
              !system.screenIsLocked,
              exactOffSpaceWindow() == lease.window
        else { return false }
        switch activity {
        case .unchanged:
            return cursorPosition() == lease.cursor
                && system.foregroundWindow() == lease.foreground
        case .unrelated:
            return currentFocusIsNonTarget()
        case .target, .unknown:
            return false
        }
    }

    private func primeCleanup(_ lease: PrimeLease) -> OffSpaceAXCleanup {
        let activity = UserInputActivity.activity(
            after: lease.inputGeneration, targetPID: targetPID,
            targetWindowID: targetWindowID ?? 0)
        switch activity {
        case .unchanged:
            return .restoreForeground
        case .unrelated:
            return .defocus
        case .target:
            return userSelectedTarget(lease) ? .preserveUserFocus : .cancel
        case .unknown:
            return .cancel
        }
    }

    private func currentFocusIsNonTarget() -> Bool {
        guard let front = system.frontmostApp(),
              front.bundleID.caseInsensitiveCompare(targetBundleID)
                != .orderedSame,
              let window = system.foregroundWindow(),
              window.pid > 0, window.windowID > 0,
              window.bundleID.caseInsensitiveCompare(front.bundleID)
                == .orderedSame
        else { return false }
        return true
    }

    private func userSelectedTarget(_ lease: PrimeLease) -> Bool {
        guard let windowID = targetWindowID,
              UserInputActivity.selectedWindow(
                after: lease.inputGeneration) == windowID,
              let selected = userFocusForWindow(windowID),
              selected.pid == targetPID, selected.windowID == windowID,
              selected.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame
        else { return false }
        return true
    }

    private func exactOffSpaceWindow() -> PrimeWindow? {
        guard let windowID = targetWindowID,
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              case .success(let reply) = transport.call(
                "list_windows", arguments: ["pid": targetPID],
                timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]],
              windows.allSatisfy({ validWindow($0, pid: targetPID) })
        else { return nil }
        let eligible = CuaWindowPick.eligible(windows, pid: targetPID)
        let exact = eligible.filter {
            exactInt($0["window_id"]) == windowID
        }
        guard exact.count == 1, let row = exact.first,
              exactInt(row["window_id"]) == windowID,
              exactFlag(row["on_current_space"]) == false,
              let raw = row["bounds"] as? [String: Any],
              let x = exactNumber(raw["x"]),
              let y = exactNumber(raw["y"]),
              let width = exactNumber(raw["width"]),
              let height = exactNumber(raw["height"]),
              width >= CuaWindowPick.minimumWidth,
              height >= CuaWindowPick.minimumHeight
        else { return nil }
        return PrimeWindow(
            title: row["title"] as? String,
            bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    private func exactTargetWindow() -> PrimeWindow? {
        guard let windowID = targetWindowID,
              targetProcessIsCurrent(),
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              case .success(let reply) = transport.call(
                "list_windows", arguments: ["pid": targetPID],
                timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]],
              windows.allSatisfy({ validWindow($0, pid: targetPID) })
        else { return nil }
        let eligible = CuaWindowPick.eligible(windows, pid: targetPID)
        let exact = eligible.filter { exactInt($0["window_id"]) == windowID }
        guard exact.count == 1, let row = exact.first,
              let raw = row["bounds"] as? [String: Any],
              let x = exactNumber(raw["x"]),
              let y = exactNumber(raw["y"]),
              let width = exactNumber(raw["width"]),
              let height = exactNumber(raw["height"]),
              width >= CuaWindowPick.minimumWidth,
              height >= CuaWindowPick.minimumHeight
        else { return nil }
        return PrimeWindow(
            title: row["title"] as? String,
            bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    private func targetWindowExists() -> Bool {
        guard let windowID = targetWindowID,
              targetProcessIsCurrent(),
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              case .success(let reply) = transport.call(
                "list_windows", arguments: ["pid": targetPID],
                timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]],
              windows.allSatisfy({ validWindow($0, pid: targetPID) })
        else { return false }
        return CuaWindowPick.eligible(windows, pid: targetPID).filter {
            exactInt($0["window_id"]) == windowID
        }.count == 1
    }

    private func pickTargetWindow() -> (id: Int, title: String?)? {
        guard case .success(let reply) = transport.call(
            "list_windows", arguments: [:], timeout: Self.callTimeout),
              let windows = reply["windows"] as? [[String: Any]] else { return nil }
        return CuaWindowPick.choose(
            windows, pid: targetPID, command: sessionCommand)
    }

    private func snapshotTarget(maxElements: Int) -> CuaSnapshot? {
        guard snapshotLineage == .valid,
              let windowID = targetWindowID,
              targetProcessIsCurrent(),
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
        mutationOrdinal = 0
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
        guard snapshotLineage == .valid, targetProcessIsCurrent(),
              let windowID = targetWindowID,
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
        routed || terminalFailureReason != nil
            ? false : system.screenNamesAreUserVisible
    }

    /// While routed, `wait_frontmost` is polling this host's own readiness —
    /// re-opening the app would drop the pinned window (`openTargetApp` resets
    /// `targetWindowID`/`everReady`/`pinnedElement`) or `unroute()` into the
    /// foreground path and take the screen.
    var isDrivingInBackground: Bool {
        routed || terminalFailureReason != nil
    }

    var actionFailureReason: String? { terminalFailureReason }

    func visibleNames() -> [String] {
        guard terminalFailureReason == nil else { return [] }
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
        guard terminalFailureReason == nil else { return nil }
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
                label: element.authoredLabel,
                frame: element.frame,
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
        guard terminalFailureReason == nil else { return false }
        // Opening a URL can activate its handler. Action Mode has no exact
        // background browser capability, so it refuses on every route.
        return false
    }

    /// Drops the background route. The draft is dropped with the target: text
    /// delivered to the old
    /// window must never authorize a commit in the new one.
    private func unroute() {
        routed = false
        targetPID = 0
        targetProcessIdentity = nil
        targetWindowID = nil
        targetName = ""
        targetBundleID = ""
        targetReady = false
        everReady = false
        primeTried = false
        pinnedElement = nil
        routedUISnapshot = nil
        resetSnapshotLineage()
        backgroundDraft = ""
    }

    @discardableResult
    private func failRoute(_ reason: String) -> Bool {
        unroute()
        terminalFailureReason = reason
        endDaemon()
        veloraLog("Velora: \(reason)")
        return false
    }

    func pressElement(label: String, expecting bundleID: String?) -> Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else {
            return system.pressElement(label: label, expecting: bundleID)
        }
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let lease = captureMutationLease(),
              let snapshot = snapshotTarget(maxElements: Self.snapshotElements),
              !snapshot.degraded, snapshot.complete
        else { return false }
        guard let element = CuaPressPick.candidate(
            in: snapshot.elements, label: label),
              let token = element.token else { return false }
        guard mutationLeaseIsLive(lease),
              case .success(let reply) = transport.call("click", arguments: [
                "pid": targetPID, "window_id": lease.windowID,
                "element_token": token,
              ], timeout: Self.callTimeout),
              clickSucceeded(reply), mutationLeaseIsLive(lease)
        else { return false }
        // A click can move focus or replace the editor. Content delivered to
        // the old field must never authorize a later committing key.
        backgroundDraft = ""
        pinnedElement = nil
        mutationOrdinal += 1
        return true
    }

    func pressElement(index: Int, snapshotID: String, label: String,
                      role: String, expecting bundleID: String?) -> Bool {
        guard terminalFailureReason == nil else { return false }
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
              let lease = captureMutationLease(),
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
        guard mutationLeaseIsLive(lease),
              case .success(let reply) = transport.call("click", arguments: [
                "pid": targetPID, "window_id": cached.windowID,
                "element_token": token, "element_index": index,
                "snapshot_id": currentID,
              ], timeout: Self.callTimeout), clickSucceeded(reply),
              mutationLeaseIsLive(lease) else { return false }
        backgroundDraft = ""
        pinnedElement = nil
        mutationOrdinal += 1
        return true
    }

    func verifyElement(index: Int, snapshotID: String, label: String,
                       role: String, target: String,
                       expecting bundleID: String?,
                       purpose: ActionVerificationPurpose) -> Bool {
        guard terminalFailureReason == nil else { return false }
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

    func verifyState(
        _ check: ActionStateCheck, expecting bundleID: String?
    ) -> ActionStateReceipt? {
        guard routed, mutationOrdinal > 0,
              snapshotLineage == .valid, targetReady,
              expectedMatchesTarget(bundleID), !check.label.isEmpty,
              let windowID = targetWindowID,
              let cached = routedUISnapshot,
              cached.observation.source == .cua,
              cached.observation.id == check.snapshotID,
              cached.pid == targetPID, cached.windowID == windowID,
              cached.bundleID == targetBundleID,
              let record = cached.observation.elements.first(where: {
                  $0.index == check.index
              }),
              record.role == check.role, record.enabled,
              !record.inWebContent,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(check.label),
              let prior = cached.driver.elements.first(where: {
                  $0.index == check.index
              }),
              let process = targetProcessIdentity,
              let window = exactTargetWindow()
        else { return nil }
        switch check.assertion {
        case .writtenText:
            guard let expected = check.expectedValue,
                  !expected.isEmpty, expected == backgroundDraft,
                  ScreenContext.isEditableActionRole(check.role) else {
                return nil
            }
        case .selected:
            guard check.expectedValue == nil, prior.selected else { return nil }
        }
        let generation = UserInputActivity.snapshot()
        guard let current = snapshotTarget(maxElements: Self.snapshotElements),
              !current.degraded,
              let element = current.elements.first(where: {
                  $0.index == check.index
              }),
              sameElementIdentity(
                element, prior: prior, role: check.role,
                label: check.label),
              targetActivitySafe(generation, windowID: windowID)
        else { return nil }

        let elementPredicate: [String: Any]
        switch check.assertion {
        case .writtenText:
            guard let expected = check.expectedValue else { return nil }
            elementPredicate = [
                "selector": [
                    "role": check.role,
                    "label_contains": check.label,
                ],
                "value_equals": expected,
            ]
        case .selected:
            elementPredicate = [
                "selector": [
                    "role": check.role,
                    "label_contains": check.label,
                ],
                "selected": true,
            ]
        }
        let predicates: [[String: Any]] = [
            ["window": [
                "exists": true,
                "bounds": [
                    "x": window.bounds.origin.x,
                    "y": window.bounds.origin.y,
                    "width": window.bounds.width,
                    "height": window.bounds.height,
                    "tolerance_px": 0,
                ],
            ]],
            ["element": elementPredicate],
        ]
        guard case .success(let reply) = transport.call(
            "verify_state", arguments: [
                "pid": targetPID, "window_id": windowID,
                "expect": predicates,
                "timeout_ms": Self.verifyTimeoutMs,
                "stable_samples": Self.verifySamples,
                "include_screenshot": false,
            ], timeout: 3),
              verifyStateSucceeded(reply, predicateCount: predicates.count),
              targetActivitySafe(generation, windowID: windowID),
              processIdentity(targetPID) == process,
              exactTargetWindow() == window,
              let after = snapshotTarget(maxElements: Self.snapshotElements),
              !after.degraded,
              let afterElement = after.elements.first(where: {
                  $0.index == check.index
              }),
              sameElementIdentity(
                afterElement, prior: prior, role: check.role,
                label: check.label),
              targetActivitySafe(generation, windowID: windowID)
        else { return nil }
        return stateReceipt(
            snapshotID: check.snapshotID, assertion: check.assertion)
    }

    private func verifyStateSucceeded(
        _ reply: [String: Any], predicateCount: Int
    ) -> Bool {
        guard reply["status"] as? String == "satisfied",
              exactFlag(reply["stable"]) == true,
              exactInt(reply["samples"]).map({
                  $0 >= Self.verifySamples
              }) == true,
              let outcomes = reply["predicates"] as? [[String: Any]],
              outcomes.count == predicateCount else { return false }
        let indices = outcomes.compactMap { exactInt($0["index"]) }
        guard indices.count == predicateCount,
              Set(indices) == Set(0..<predicateCount) else { return false }
        return outcomes.allSatisfy {
            $0["status"] as? String == "satisfied"
                && $0["unknown_reason"] is NSNull
        }
    }

    private func verifyRoutedTarget(
        index: Int, snapshotID: String, label: String, role: String,
        target: String, expecting bundleID: String?,
        purpose: ActionVerificationPurpose
    ) -> Bool {
        switch purpose {
        case .target:
            return verifyRoutedTextTarget(
                index: index, snapshotID: snapshotID, label: label,
                role: role, target: target, expecting: bundleID)
        case .goal:
            return verifyRoutedGoal(
                index: index, snapshotID: snapshotID, label: label,
                role: role, target: target, expecting: bundleID)
        }
    }

    private func verifyRoutedTextTarget(
        index: Int, snapshotID: String, label: String, role: String,
        target: String, expecting bundleID: String?
    ) -> Bool {
        guard snapshotLineage == .valid,
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

    private func verifyRoutedGoal(
        index: Int, snapshotID: String, label: String, role: String,
        target: String, expecting bundleID: String?
    ) -> Bool {
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let process = targetProcessIdentity,
              process.pid == pid_t(targetPID),
              let cached = routedUISnapshot,
              cached.observation.source == .cua,
              cached.observation.complete, cached.driver.complete,
              cached.observation.id == snapshotID,
              cached.observation.windowID == windowID,
              cached.observation.bundleID.caseInsensitiveCompare(
                targetBundleID) == .orderedSame,
              cached.pid == targetPID, cached.windowID == windowID,
              cached.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
              let record = cached.observation.elements.first(where: {
                  $0.index == index
              }),
              let prior = cached.driver.elements.first(where: {
                  $0.index == index
              }),
              record.role == role, prior.role == role,
              record.parentIndex == prior.parentIndex,
              record.depth == prior.depth, record.frame == prior.frame,
              record.enabled == prior.enabled,
              record.selected == prior.selected,
              record.inWebContent == prior.inWebContent,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(label),
              AppMatcher.normalize(prior.authoredLabel ?? "")
                == AppMatcher.normalize(label),
              AppMatcher.bestMatch(for: target, in: [label]) != nil,
              ActionUIEvidencePolicy.mayVerifyGoal(
                index: index, source: .cua,
                in: cached.observation.elements)
        else { return false }

        // Goal proof is observation-only. Hold process, window, and user
        // activity stable across the fresh exhaustive tree read.
        let generation = UserInputActivity.snapshot()
        guard processIdentity(targetPID) == process,
              let window = exactTargetWindow(),
              targetActivitySafe(generation, windowID: windowID),
              let current = snapshotTarget(maxElements: Self.snapshotElements),
              !current.degraded, current.complete,
              let element = current.elements.first(where: {
                  $0.index == index
              }),
              sameElementIdentity(
                element, prior: prior, role: role, label: label),
              !record.focused || current.primaryTextElement?.index == index,
              ActionUIEvidencePolicy.mayVerifyGoal(
                index: index, source: .cua,
                in: goalElements(in: current)),
              targetActivitySafe(generation, windowID: windowID),
              processIdentity(targetPID) == process,
              targetProcessIdentity == process,
              exactTargetWindow() == window,
              targetActivitySafe(generation, windowID: windowID)
        else { return false }
        return true
    }

    private func goalElements(in snapshot: CuaSnapshot) -> [ActionUIElement] {
        let primary = snapshot.primaryTextElement
        return snapshot.elements.map { element in
            ActionUIElement(
                index: element.index, parentIndex: element.parentIndex,
                depth: element.depth, role: element.role,
                label: element.authoredLabel, frame: element.frame,
                actions: element.actionNames, enabled: element.enabled,
                selected: element.selected,
                focused: primary?.index == element.index,
                inWebContent: element.inWebContent)
        }
    }

    func foregroundWindow() -> ActionWindowIdentity? {
        routed || terminalFailureReason != nil
            ? nil : system.foregroundWindow()
    }

    func actionWindow() -> ActionWindowIdentity? {
        guard terminalFailureReason == nil else { return nil }
        guard routed else { return system.actionWindow() }
        guard targetProcessIsCurrent(),
              let windowID = targetWindowID else { return nil }
        return ActionWindowIdentity(
            name: targetName, bundleID: targetBundleID,
            pid: targetPID, windowID: windowID,
            processIdentity: targetProcessIdentity)
    }

    func actionProcess() -> ActionProcessIdentity? {
        guard terminalFailureReason == nil else { return nil }
        guard routed else { return system.actionProcess() }
        guard snapshotLineage == .valid else { return nil }
        if targetReady {
            guard verifyTargetAlive() else { return nil }
        } else {
            guard advanceReadiness() else { return nil }
        }
        guard targetReady, everReady else { return nil }
        return exactRoutedProcess()
    }

    private func exactRoutedProcess() -> ActionProcessIdentity? {
        guard routed, targetPID > 0,
              !targetName.isEmpty, !targetBundleID.isEmpty,
              targetProcessIsCurrent(),
              bundleForPID(targetPID)?.caseInsensitiveCompare(targetBundleID)
                == .orderedSame else { return nil }
        return ActionProcessIdentity(
            name: targetName, bundleID: targetBundleID, pid: targetPID,
            processIdentity: targetProcessIdentity)
    }

    func mediaCapabilities() -> [ActionNativeCapability] {
        guard terminalFailureReason == nil else { return [] }
        guard routed else {
            return system.mediaCapabilities()
        }
        guard targetReady, everReady,
              let target = exactRoutedProcess() else { return [] }
        return nativeMedia.capabilities(for: target)
    }

    func mediaControl(
        _ control: ActionMediaControl
    ) -> ActionMediaControlResult {
        guard terminalFailureReason == nil else { return .unavailable }
        switch control.capability {
        case .cua(let snapshotID, let index, let role, let label):
            return clickMediaControl(
                control, snapshotID: snapshotID, index: index,
                role: role, label: label)
        case .appNative:
            guard routed, targetReady, let target = exactRoutedProcess(),
                  !userIsInTarget(), let lease = captureMutationLease(),
                  mutationLeaseIsLive(lease) else { return .unavailable }
            let result = nativeMedia.perform(
                control, target: target,
                maySend: {
                    !self.userIsInTarget()
                        && self.mutationLeaseIsLive(lease)
                })
            guard mutationLeaseIsLive(lease) else { return .misdirected }
            return result
        }
    }

    private func clickMediaControl(
        _ control: ActionMediaControl,
        snapshotID: String,
        index: Int,
        role: String,
        label: String
    ) -> ActionMediaControlResult {
        guard routed, snapshotLineage == .valid, targetReady,
              let windowID = targetWindowID,
              let target = actionProcess(),
              let cached = routedUISnapshot,
              cached.observation.source == .cua,
              cached.observation.id == snapshotID,
              cached.pid == target.pid, cached.windowID == windowID,
              cached.bundleID.caseInsensitiveCompare(target.bundleID)
                == .orderedSame,
              let record = cached.observation.elements.first(where: {
                  $0.index == index
              }),
              record.enabled, record.role == role,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(label),
              record.actions.contains(ActionUICapability.cuaClick),
              let prior = cached.driver.elements.first(where: {
                  $0.index == index
              }),
              prior.token?.isEmpty == false,
              let lease = captureMutationLease(),
              let current = snapshotTarget(maxElements: Self.snapshotElements)
        else { return .unavailable }
        defer { routedUISnapshot = nil }
        guard !current.degraded,
              let currentID = current.id, !currentID.isEmpty,
              let element = current.elements.first(where: {
                  $0.index == index
              }),
              element.actionNames.contains(ActionUICapability.cuaClick),
              let token = element.token, !token.isEmpty,
              sameElementIdentity(
                element, prior: prior, role: role,
                label: label)
        else { return .unavailable }

        let before = mediaSnapshot()
        guard mutationLeaseIsLive(lease) else { return .unavailable }
        let priorState = mediaMatches(
            control.state, target: target, snapshot: before)
        if priorState == true { return .verified }
        if control.state == .pause, priorState == nil { return .unavailable }
        guard !userIsInTarget(), mutationLeaseIsLive(lease) else {
            return .unavailable
        }

        guard case .success(let reply) = transport.call("click", arguments: [
            "pid": target.pid, "window_id": windowID,
            "element_token": token, "element_index": index,
            "snapshot_id": currentID,
        ], timeout: Self.callTimeout), clickSucceeded(reply),
              mutationLeaseIsLive(lease) else {
            return .unavailable
        }
        backgroundDraft = ""
        pinnedElement = nil

        for _ in 0..<Self.mediaPollAttempts {
            mediaSleep(Self.mediaPollMs)
            guard mutationLeaseIsLive(lease) else { return .misdirected }
            let after = mediaSnapshot()
            guard mutationLeaseIsLive(lease) else { return .misdirected }
            if mediaMatches(
                control.state, target: target, snapshot: after) == true {
                return .verified
            }
        }
        return .misdirected
    }

    private func mediaMatches(
        _ requested: ActionMediaState,
        target: ActionProcessIdentity,
        snapshot: MediaPlaybackCoordinator.Snapshot
    ) -> Bool? {
        guard snapshot.isComplete,
              !ActionRuntimePolicy.isBrowserBundle(target.bundleID)
        else { return nil }
        let processes = snapshot.processes.filter {
            snapshot.pids[$0] == target.pid
                && snapshot.bundleIDs[$0]?.caseInsensitiveCompare(
                    target.bundleID) == .orderedSame
        }
        guard !processes.isEmpty else { return nil }
        let isPlaying = !processes.isDisjoint(with: snapshot.allPlaying)
        return requested == .play ? isPlaying : !isPlaying
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
        guard terminalFailureReason == nil else { return false }
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
        guard targetProcessIsCurrent(),
              let front = system.frontmostApp(),
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

    func typeText(
        _ text: String, target: ActionTextTarget,
        expecting bundleID: String?
    ) -> ActionStateReceipt? {
        guard routed, snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let cached = routedUISnapshot,
              cached.observation.id == target.snapshotID,
              cached.pid == targetPID, cached.windowID == windowID,
              cached.bundleID == targetBundleID,
              let record = cached.observation.elements.first(where: {
                  $0.index == target.index
              }),
              record.role == target.role, record.enabled,
              !record.inWebContent,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(target.label),
              ScreenContext.isEditableActionRole(target.role),
              let prior = cached.driver.elements.first(where: {
                  $0.index == target.index
              }),
              let priorValue = prior.value,
              priorValue == backgroundDraft,
              let lease = captureMutationLease()
        else { return nil }
        guard let current = snapshotTarget(maxElements: Self.snapshotElements),
              !current.degraded,
              let currentID = current.id, !currentID.isEmpty,
              let element = current.elements.first(where: {
                  $0.index == target.index
              }),
              sameElementIdentity(
                element, prior: prior, role: target.role,
                label: target.label),
              let token = element.token, !token.isEmpty,
              mutationLeaseIsLive(lease)
        else { return nil }
        guard case .success(let reply) = transport.call(
            "type_text", arguments: [
                "pid": targetPID, "window_id": windowID, "text": text,
                "element_token": token, "element_index": target.index,
                "snapshot_id": currentID,
            ], timeout: 10),
              reply["effect"] as? String == "confirmed",
              exactFlag(reply["verified"]) == true,
              exactInt(reply["characters"]) == text.unicodeScalars.count,
              exactInt(reply["delivered_chars"]) == text.unicodeScalars.count,
              mutationLeaseIsLive(lease),
              let after = snapshotTarget(maxElements: Self.snapshotElements),
              !after.degraded,
              let afterElement = after.elements.first(where: {
                  $0.index == target.index
              }),
              sameElementIdentity(
                afterElement, prior: prior, role: target.role,
                label: target.label)
        else { return nil }
        let expected = priorValue + text
        guard afterElement.value == expected,
              mutationLeaseIsLive(lease) else {
            backgroundDraft = ""
            return nil
        }
        backgroundDraft = expected
        pinnedElement = ElementIdentity(afterElement)
        mutationOrdinal += 1
        return stateReceipt(
            snapshotID: target.snapshotID, assertion: .writtenText)
    }

    private func targetActivitySafe(
        _ generation: UInt64, windowID: Int
    ) -> Bool {
        switch UserInputActivity.activity(
            after: generation, targetPID: targetPID,
            targetWindowID: windowID) {
        case .unchanged, .unrelated:
            return true
        case .target, .unknown:
            return false
        }
    }

    private struct TargetMutationLease {
        let generation: UInt64
        let process: CuaProcessIdentity
        let windowID: Int
    }

    private func captureMutationLease() -> TargetMutationLease? {
        guard let windowID = targetWindowID,
              let process = targetProcessIdentity else { return nil }
        let generation = UserInputActivity.snapshot()
        guard processIdentity(targetPID) == process,
              targetWindowExists(),
              targetActivitySafe(generation, windowID: windowID)
        else { return nil }
        return TargetMutationLease(
            generation: generation, process: process, windowID: windowID)
    }

    private func mutationLeaseIsLive(_ lease: TargetMutationLease) -> Bool {
        targetWindowID == lease.windowID
            && processIdentity(targetPID) == lease.process
            && targetWindowExists()
            && targetActivitySafe(
                lease.generation, windowID: lease.windowID)
    }

    private func stateReceipt(
        snapshotID: String, assertion: ActionStateAssertion
    ) -> ActionStateReceipt? {
        guard mutationOrdinal > 0, let windowID = targetWindowID else {
            return nil
        }
        return ActionStateReceipt(
            id: UUID().uuidString, appName: targetName,
            bundleID: targetBundleID, pid: targetPID, windowID: windowID,
            snapshotID: snapshotID, assertion: assertion,
            mutationOrdinal: mutationOrdinal,
            processIdentity: targetProcessIdentity)
    }

    func typeText(_ text: String, expecting bundleID: String?) -> Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else { return system.typeText(text, expecting: bundleID) }
        return deliverText(text, expecting: bundleID)
    }

    func pasteText(_ text: String, expecting bundleID: String?) -> Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else { return system.pasteText(text, expecting: bundleID) }
        // AX insertion is one atomic write; there is no separate paste road.
        return deliverText(text, expecting: bundleID)
    }

    private func deliverText(_ text: String, expecting bundleID: String?) -> Bool {
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let lease = captureMutationLease() else { return false }
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
        guard mutationLeaseIsLive(lease),
              case .success(let reply) = transport.call("type_text", arguments: [
            "pid": targetPID, "window_id": windowID, "text": text,
            "element_token": token,
        ], timeout: 10) else { return false }
        guard !isRefused(reply), mutationLeaseIsLive(lease) else { return false }
        // Driver confirmation is not draft ownership. Re-read the SAME field
        // and require its whole value to equal Velora's accumulated text.
        // This refuses pre-existing text, caret drift, and another writer.
        guard let after = freshPrimaryTextElement(),
              pinnedElement == ElementIdentity(after.element) else { return false }
        let expectedValue = priorValue + text
        guard after.element.value == expectedValue,
              mutationLeaseIsLive(lease) else {
            backgroundDraft = ""
            return false
        }
        backgroundDraft = expectedValue
        return true
    }

    func pressKey(name: String, mods: [String], keyCode: CGKeyCode,
                  flags: CGEventFlags, expecting bundleID: String?) -> Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else {
            return system.pressKey(name: name, mods: mods, keyCode: keyCode,
                                   flags: flags, expecting: bundleID)
        }
        guard snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let driverKey = CuaKeyMap.driverKey(forPlanKey: name),
              let lease = captureMutationLease(),
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
        guard mutationLeaseIsLive(lease),
              case .success(let reply) = transport.call(
            "press_key", arguments: arguments, timeout: Self.callTimeout)
        else { return false }
        guard !isRefused(reply), mutationLeaseIsLive(lease) else { return false }
        mutationOrdinal += 1
        return true
    }

    // MARK: - Machine state

    /// The dictation typing target is a foreground concept; routed mode uses
    /// the complete tree's one non-web primary element, pinned to the exact
    /// target window before mutation.
    var hasFocusedTextTarget: Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else { return system.hasFocusedTextTarget }
        guard snapshotLineage == .valid, targetReady else { return false }
        return freshPrimaryTextElement() != nil
    }

    var canPostInput: Bool {
        guard terminalFailureReason == nil else { return false }
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

    private func targetProcessIsCurrent() -> Bool {
        guard let targetProcessIdentity else { return false }
        return processIdentity(targetPID) == targetProcessIdentity
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
