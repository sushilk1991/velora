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
/// hint; siblings require one title named by the immutable spoken command or
/// one uniquely frontmost window proven on the current Space and screen.
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
            raw -> (
                id: Int, title: String?, current: Bool?,
                onScreen: Bool?, zIndex: Int?
            )? in
            guard isEligible(raw, pid: pid),
                  let id = raw["window_id"] as? Int else { return nil }
            let title = (raw["title"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
            return (
                id, title, raw["on_current_space"] as? Bool,
                raw["is_on_screen"] as? Bool, raw["z_index"] as? Int)
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
        guard candidates.allSatisfy({ $0.current != nil }) else { return nil }
        let current = candidates.filter { $0.current == true }
        guard !current.isEmpty,
              current.allSatisfy({ $0.onScreen == true && $0.zIndex != nil }),
              let highest = current.compactMap(\.zIndex).max()
        else { return nil }
        let frontmost = current.filter { $0.zIndex == highest }
        guard frontmost.count == 1, let match = frontmost.first else { return nil }
        return (match.id, match.title)
    }

    static func eligible(_ windows: [[String: Any]], pid: Int)
        -> [[String: Any]] {
        windows.filter { isEligible($0, pid: pid) }
    }

    private static func isEligible(_ raw: [String: Any], pid: Int) -> Bool {
        let title = (raw["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isPlaceholder = title.isEmpty
            && (raw["is_on_screen"] as? Bool) == false
            && raw["on_current_space"] is NSNull
            && raw["current_space_id"] is NSNull
            && raw["space_ids"] is NSNull
        guard (raw["pid"] as? Int) == pid,
              !isPlaceholder,
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

/// Routes an action to an already-running exact background window. Cua
/// supplies read-only window and screenshot evidence. Public Accessibility,
/// exact retained elements, and app-native APIs own every automatic mutation.
final class BackgroundRoutingActionHost: ActionHost {
    /// The element cap matches the driver's own default walk bound. Normal
    /// routes stay tree-only; exact screenshots are a read-only fallback when
    /// macOS cannot resolve the pinned window's AX tree.
    private static let snapshotElements = 2000
    private static let callTimeout: TimeInterval = 3.0
    private static let maximumSnapshotIDs = 512
    private static let maximumSnapshotIDBytes = 128
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
    private static let visualTextRole = "VisualText"
    private static let visualMaxElements = 1
    private static let visualScales: Set<Double> = [1, 2]
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
    private let visualRecords: ([String: Any]) -> [CuaVisualTextRecord]?
    private let nativeSnapshot: (
        Int, Int, String, CGRect
    ) -> ScreenActionUISnapshot?
    private let nativePress: (
        Int, ScreenAXReadback?, ScreenActionUISnapshot
    ) -> Bool
    private let nativeWrite: (
        String, String, Int, ScreenActionUISnapshot
    ) -> Bool
    private let nativeValueEquals: (
        String, Int, ScreenActionUISnapshot
    ) -> Bool
    private let restoreForeground: (
        ActionWindowIdentity, () -> Bool
    ) -> Bool
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
    private var nativeAXReady = false
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

        init(_ element: ActionUIElement) {
            index = element.index
            role = element.role
            label = element.label
            parentIndex = element.parentIndex
            depth = element.depth
            frame = element.frame
            enabled = element.enabled
            inWebContent = element.inWebContent
        }
    }
    private var pinnedElement: ElementIdentity?
    /// The exact native AX element changed by the latest content write.
    /// A planner cannot prove completion against a sibling editable that
    /// happens to contain the same value.
    private var writtenElement: ElementIdentity?
    private var writtenNativeElement: AXUIElement?
    /// Text this action itself delivered to the pinned element — the
    /// background analog of the foreground draft: committing keys refuse
    /// without it, and it is dropped whenever the element or target changes.
    private var backgroundDraft = ""
    private var mutationOrdinal = 0
    private var pendingMutationLease: TargetMutationLease?
    private struct NavigationNode: Hashable {
        let role: String
        let label: String
    }

    private struct NavigationPath: Hashable {
        let nodes: [NavigationNode]
    }

    private struct NavigationReceipt {
        let process: CuaProcessIdentity
        let windowID: Int
        let bundleID: String
        let mutationOrdinal: Int
        let beforeSnapshotID: String
        let inputGeneration: UInt64
        let baseline: Set<NavigationPath>
        var observedSnapshotID: String?
    }
    private var navigationReceipt: NavigationReceipt?
    private struct RoutedUISnapshot {
        let observation: ActionUISnapshot
        let driver: CuaSnapshot
        let pid: Int
        let windowID: Int
        let bundleID: String
        let inputGeneration: UInt64
    }
    private var routedUISnapshot: RoutedUISnapshot?
    private struct RoutedNativeSnapshot {
        let snapshot: ScreenActionUISnapshot
        let pid: Int
        let windowID: Int
        let bundleID: String
        let inputGeneration: UInt64
    }
    private var routedNativeSnapshot: RoutedNativeSnapshot?
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
         visualRecords: @escaping ([String: Any])
            -> [CuaVisualTextRecord]? = { reply in
             guard let png = CuaVisualEvidence.pngData(from: reply) else {
                 return nil
             }
             return CuaVisualEvidence.readText(in: png)
         },
         nativeSnapshot: @escaping (
            Int, Int, String, CGRect
         ) -> ScreenActionUISnapshot? = { pid, windowID, title, bounds in
             ScreenContext.backgroundActionUISnapshot(
                pid: pid, windowID: windowID,
                windowTitle: title, windowBounds: bounds)
         },
         nativePress: @escaping (
            Int, ScreenAXReadback?, ScreenActionUISnapshot
         ) -> Bool = { index, expected, snapshot in
             ScreenContext.backgroundPress(
                index: index, expecting: expected, in: snapshot)
         },
         nativeWrite: @escaping (
            String, String, Int, ScreenActionUISnapshot
         ) -> Bool = { value, prior, index, snapshot in
             ScreenContext.backgroundWriteValue(
                value, replacing: prior, index: index, in: snapshot)
         },
         nativeValueEquals: @escaping (
            String, Int, ScreenActionUISnapshot
         ) -> Bool = { value, index, snapshot in
             ScreenContext.backgroundValueEquals(
                value, index: index, in: snapshot)
         },
         restoreForeground: @escaping (
            ActionWindowIdentity, () -> Bool
         ) -> Bool = { target, allowed in
             ScreenContext.restoreActionWindow(target, allowed: allowed)
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
        self.visualRecords = visualRecords
        self.nativeSnapshot = nativeSnapshot
        self.nativePress = nativePress
        self.nativeWrite = nativeWrite
        self.nativeValueEquals = nativeValueEquals
        self.restoreForeground = restoreForeground
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
            pid: pid, windowID: windowID,
            processIdentity: CuaProcessIdentity.capture(pid: pid_t(pid)))
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
        // Drain activation notifications already queued by the target before
        // dropping the mutation lease. The second check covers teardown work
        // itself without adding a timer or holding the user's desktop hostage.
        drainActivationEvents()
        _ = preserveUserFocus()
        system.endActionInputSession()
        drainActivationEvents()
        _ = preserveUserFocus()
        unroute()
        endDaemon()
        sessionCommand = ""
        contentMayCommit = false
    }

    private func drainActivationEvents() {
        guard !Thread.isMainThread else { return }
        DispatchQueue.main.sync {}
    }

    func prepareForActionPlan(sends: Bool) {
        contentMayCommit = sends
    }

    func prepareInteraction() -> ActionInteractionState {
        guard preserveUserFocus() else { return .refused }
        return routed ? waitForTargetIdle() : .ready
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
            // Even activates=false is a request, not a guarantee that a
            // regular app will not self-activate. Strict background mode acts
            // only on an already-running exact window.
            return .failed
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
        nativeAXReady = false
        everReady = false
        primeTried = false
        // A new target is a new window, a new element, and a new draft:
        // text delivered to the previous app must never authorize a commit
        // here (review finding — `unroute` cleared this, retargeting did
        // not). The materialization allowance travels with the target, but
        // the per-action ceiling still applies.
        pinnedElement = nil
        routedUISnapshot = nil
        routedNativeSnapshot = nil
        resetSnapshotLineage()
        backgroundDraft = ""
        writtenElement = nil
        writtenNativeElement = nil
        mutationOrdinal = 0
        navigationReceipt = nil
    }

    // MARK: - Target readiness (drives the executor's wait_frontmost poll)

    /// In routed mode the "frontmost app" IS the background target. A route
    /// that will hand off before interaction needs only an independently
    /// verified exact window; a background-input route also needs AX.
    func frontmostApp() -> (name: String, bundleID: String)? {
        guard terminalFailureReason == nil else { return nil }
        guard routed else { return exactForegroundApp() }
        guard preserveUserFocus() else { return nil }
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
        if nativeAXReady {
            guard targetWindowExists() else {
                return failRoute("The exact background target changed.")
            }
            return true
        }
        // A vanished target window must read as lost focus, never as "still
        // fine": the executor aborts instead of typing into nothing. A live
        // exact window without AX remains sufficient only for an app-ready
        // result; every mutation method independently requires its UI proof.
        guard let snapshot = snapshotTarget(maxElements: 1) else {
            guard snapshotLineage == .valid else { return false }
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
        guard snapshotLineage == .valid,
              resolveDeferredWindow(), let windowID = targetWindowID else {
            return false
        }
        if let target = exactRoutedProcess(), nativeMedia.supports(target) {
            return true
        }

        let generation = UserInputActivity.snapshot()
        guard targetActivitySafe(generation, windowID: windowID),
              let window = exactTargetWindow(),
              let snapshot = nativeSnapshot(
                targetPID, windowID, window.title ?? "", window.bounds),
              snapshot.observation.source == .native,
              snapshot.observation.complete,
              snapshot.observation.windowID == windowID,
              snapshot.observation.bundleID.caseInsensitiveCompare(
                targetBundleID) == .orderedSame,
              targetActivitySafe(generation, windowID: windowID),
              exactTargetWindow() == window
        else { return false }
        nativeAXReady = true
        return true
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
        // A degraded Cua observation can establish window liveness, but it
        // never authorizes focus priming or input. Mutation still requires a
        // fresh complete native AX snapshot.
        return true
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
            return failRoute(
                "Restart the target app before retrying this action.")
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

    /// Pins the exact target and current user window while the private
    /// no-raise primer performs its bounded observation.
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

    /// Builds read-only semantic evidence from Cua's exact requested-window
    /// PNG. These records can be re-read for completion but carry no click,
    /// key, token, or coordinate authority.
    private func visualObservation() -> ActionUISnapshot? {
        guard let windowID = targetWindowID,
              let process = targetProcessIdentity,
              processIdentity(targetPID) == process,
              let window = exactTargetWindow()
        else { return nil }
        let generation = UserInputActivity.snapshot()
        guard targetActivitySafe(generation, windowID: windowID),
              case .success(let reply) = transport.call(
                "get_window_state", arguments: [
                    "include_screenshot": true,
                    "pid": targetPID,
                    "window_id": windowID,
                    "max_elements": Self.visualMaxElements,
                ], timeout: Self.callTimeout),
              visualReplyIsExact(
                reply, windowID: windowID, window: window),
              targetActivitySafe(generation, windowID: windowID),
              processIdentity(targetPID) == process,
              exactTargetWindow() == window
        else { return nil }
        guard let records = visualRecords(reply) else { return nil }
        guard targetActivitySafe(generation, windowID: windowID),
              processIdentity(targetPID) == process,
              exactTargetWindow() == window
        else { return nil }
        let elements = records.enumerated().map { index, record in
            ActionUIElement(
                index: index, parentIndex: nil, depth: 0,
                role: Self.visualTextRole, label: record.text,
                frame: record.frame, actions: [])
        }
        return ActionUISnapshot(
            id: "cua-visual-\(UUID().uuidString)", source: .cuaVisual,
            appName: targetName, bundleID: targetBundleID,
            windowTitle: window.title ?? "", windowID: windowID,
            complete: false, elements: elements)
    }

    private func visualReplyIsExact(
        _ reply: [String: Any], windowID: Int, window: PrimeWindow
    ) -> Bool {
        let snapshot = CuaSnapshot.parse(reply)
        guard !snapshot.refused,
              !snapshot.degraded || snapshot.axWindowUnresolved,
              exactInt(reply["pid"]) == targetPID,
              exactInt(reply["window_id"]) == windowID,
              exactFlag(reply["screenshot_frame_valid"]) == true,
              let scale = exactNumber(reply["screenshot_scale"]),
              Self.visualScales.contains(scale),
              exactInt(reply["screenshot_width"])
                == Int(window.bounds.width * scale),
              exactInt(reply["screenshot_height"])
                == Int(window.bounds.height * scale),
              let bounds = reply["window_bounds"] as? [String: Any],
              exactNumber(bounds["x"]) == window.bounds.origin.x,
              exactNumber(bounds["y"]) == window.bounds.origin.y,
              exactNumber(bounds["width"]) == window.bounds.width,
              exactNumber(bounds["height"]) == window.bounds.height
        else { return false }
        return true
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
        nativeAXReady = false
        routedUISnapshot = nil
        routedNativeSnapshot = nil
        pinnedElement = nil
        backgroundDraft = ""
        writtenElement = nil
        writtenNativeElement = nil
        mutationOrdinal = 0
        navigationReceipt = nil
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
            writtenElement = nil
            writtenNativeElement = nil
            return nil
        }
        let identity = ElementIdentity(element)
        if let pinnedElement {
            guard pinnedElement == identity else {
                // The draft belonged to the element that just went away.
                backgroundDraft = ""
                writtenElement = nil
                writtenNativeElement = nil
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
        guard terminalFailureReason == nil else { return nil }
        guard routed else { return system.uiSnapshot() }
        guard preserveUserFocus() else { return nil }
        guard snapshotLineage == .valid, targetReady,
              let windowID = targetWindowID else {
            routedUISnapshot = nil
            routedNativeSnapshot = nil
            return nil
        }
        let inputGeneration = UserInputActivity.snapshot()
        guard targetActivitySafe(inputGeneration, windowID: windowID)
        else {
            routedUISnapshot = nil
            routedNativeSnapshot = nil
            return nil
        }

        // Public Accessibility is the first choice: it retains exact native
        // element references and never activates the target. Cua supplies only
        // the read-only WindowServer lease used to bind AX title and bounds.
        if let window = exactTargetWindow(),
           let native = nativeSnapshot(
                targetPID, windowID, window.title ?? "", window.bounds),
           native.observation.source == .native,
           native.observation.complete,
           native.observation.windowID == windowID,
           native.observation.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame,
           targetActivitySafe(inputGeneration, windowID: windowID),
           exactTargetWindow() == window {
            nativeAXReady = true
            if var receipt = navigationReceipt {
                guard receipt.observedSnapshotID == nil,
                      receipt.process == targetProcessIdentity,
                      receipt.windowID == windowID,
                      receipt.bundleID.caseInsensitiveCompare(targetBundleID)
                        == .orderedSame,
                      receipt.mutationOrdinal == mutationOrdinal,
                      receipt.beforeSnapshotID != native.observation.id,
                      targetActivitySafe(
                        receipt.inputGeneration, windowID: windowID),
                      !Set(navigationPaths(
                        in: native.observation).values)
                        .isSubset(of: receipt.baseline)
                else {
                    _ = failRoute(
                        "The UI action produced no verifiable state change. "
                            + "It was not retried.")
                    return nil
                }
                receipt.observedSnapshotID = native.observation.id
                navigationReceipt = receipt
            }
            routedUISnapshot = nil
            routedNativeSnapshot = RoutedNativeSnapshot(
                snapshot: native, pid: targetPID, windowID: windowID,
                bundleID: targetBundleID,
                inputGeneration: inputGeneration)
            return backgroundObservation(native.observation)
        }
        if navigationReceipt != nil {
            _ = failRoute(
                "The UI action produced no complete native observation. "
                    + "It was not retried.")
            return nil
        }
        routedNativeSnapshot = nil

        guard let driver = snapshotTarget(maxElements: Self.snapshotElements),
              targetActivitySafe(inputGeneration, windowID: windowID)
        else {
            routedUISnapshot = nil
            return nil
        }
        guard let observation = visualObservation(),
              targetActivitySafe(inputGeneration, windowID: windowID)
        else {
            routedUISnapshot = nil
            return nil
        }
        routedUISnapshot = RoutedUISnapshot(
            observation: observation, driver: driver, pid: targetPID,
            windowID: windowID, bundleID: targetBundleID,
            inputGeneration: inputGeneration)
        return observation
    }

    private func backgroundObservation(
        _ source: ActionUISnapshot
    ) -> ActionUISnapshot {
        let elements = source.elements.map { element in
            ActionUIElement(
                index: element.index, parentIndex: element.parentIndex,
                depth: element.depth, role: element.role,
                label: element.label, frame: element.frame,
                actions: element.actions.filter {
                    $0 != ActionUICapability.axFocus
                },
                enabled: element.enabled, selected: element.selected,
                focused: element.focused,
                inWebContent: element.inWebContent)
        }
        return ActionUISnapshot(
            id: source.id, source: source.source,
            appName: source.appName, bundleID: source.bundleID,
            windowTitle: source.windowTitle, windowID: source.windowID,
            complete: source.complete, elements: elements,
            capabilities: source.capabilities)
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
        nativeAXReady = false
        everReady = false
        primeTried = false
        pinnedElement = nil
        routedUISnapshot = nil
        routedNativeSnapshot = nil
        resetSnapshotLineage()
        backgroundDraft = ""
        writtenElement = nil
        writtenNativeElement = nil
        pendingMutationLease = nil
        navigationReceipt = nil
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
        // A label alone carries no native element identity or closed
        // postcondition. Background plans must use the structured UI path.
        return false
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
              let cached = routedNativeSnapshot,
              cached.snapshot.observation.id == snapshotID,
              cached.pid == targetPID, cached.windowID == targetWindowID,
              cached.bundleID == targetBundleID,
              targetActivitySafe(
                  cached.inputGeneration, windowID: cached.windowID),
              expectedMatchesTarget(bundleID), targetReady,
              let lease = captureMutationLease(),
              let record = cached.snapshot.observation.elements.first(where: {
                  $0.index == index
              }),
              record.role == role, record.enabled, !record.inWebContent,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(label),
              !ActionPlan.pressLabelIsCommitting(label),
              record.actions.contains(ActionUICapability.axPress),
              !record.selected,
              mutationLeaseIsLive(lease)
        else { return false }
        let expected = cached.snapshot.pressReadbacks[index]
        let receipt: NavigationReceipt?
        if expected == nil {
            guard let process = targetProcessIdentity,
                  process.pid == pid_t(targetPID)
            else { return false }
            receipt = NavigationReceipt(
                process: process, windowID: cached.windowID,
                bundleID: cached.bundleID,
                mutationOrdinal: mutationOrdinal + 1,
                beforeSnapshotID: cached.snapshot.observation.id,
                inputGeneration: lease.generation,
                baseline: Set(navigationPaths(
                    in: cached.snapshot.observation).values),
                observedSnapshotID: nil)
        } else {
            receipt = nil
        }
        navigationReceipt = nil
        routedNativeSnapshot = nil
        pendingMutationLease = lease
        let effectAccepted = nativePress(index, expected, cached.snapshot)
        let focusPreserved = finalizeMutation(lease)
        guard focusPreserved else { return false }
        guard effectAccepted else {
            return failMutation(
                expected == nil
                    ? "The UI action was not accepted. It was not retried."
                    : "The UI action could not be verified. It was not retried.")
        }
        backgroundDraft = ""
        writtenElement = nil
        writtenNativeElement = nil
        pinnedElement = nil
        mutationOrdinal += 1
        navigationReceipt = receipt
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
        if let cached = routedNativeSnapshot {
            guard routed, mutationOrdinal > 0,
                  snapshotLineage == .valid, targetReady,
                  expectedMatchesTarget(bundleID),
                  cached.snapshot.observation.id == check.snapshotID,
                  cached.pid == targetPID,
                  cached.windowID == targetWindowID,
                  cached.bundleID == targetBundleID,
                  targetActivitySafe(
                    cached.inputGeneration, windowID: cached.windowID),
                  let record = cached.snapshot.observation.elements.first(
                    where: { $0.index == check.index }),
                  let nativeElement = cached.snapshot.elementsByIndex[
                    check.index],
                  record.role == check.role, record.enabled,
                  !record.inWebContent,
                  AppMatcher.normalize(record.label ?? "")
                    == AppMatcher.normalize(check.label)
            else { return nil }
            switch check.assertion {
            case .writtenText:
                guard let expected = check.expectedValue,
                      !expected.isEmpty, expected == backgroundDraft,
                      writtenElement == ElementIdentity(record),
                      writtenNativeElement.map({
                        CFEqual($0, nativeElement)
                      }) == true,
                      nativeValueEquals(
                        expected, check.index, cached.snapshot)
                else { return nil }
            case .selected:
                guard !check.label.isEmpty, check.expectedValue == nil,
                      record.selected else {
                    return nil
                }
            }
            guard targetActivitySafe(
                cached.inputGeneration, windowID: cached.windowID)
            else { return nil }
            return stateReceipt(
                snapshotID: check.snapshotID, assertion: check.assertion)
        }
        guard routed, mutationOrdinal > 0,
              snapshotLineage == .valid, targetReady,
              expectedMatchesTarget(bundleID), !check.label.isEmpty,
              let windowID = targetWindowID,
              let cached = routedUISnapshot,
              cached.observation.source == .cua,
              cached.observation.id == check.snapshotID,
              cached.pid == targetPID, cached.windowID == windowID,
              cached.bundleID == targetBundleID,
              targetActivitySafe(
                  cached.inputGeneration, windowID: windowID),
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
        if let cached = routedNativeSnapshot {
            guard snapshotLineage == .valid,
                  expectedMatchesTarget(bundleID), targetReady,
                  cached.snapshot.observation.id == snapshotID,
                  cached.pid == targetPID,
                  cached.windowID == targetWindowID,
                  cached.bundleID == targetBundleID,
                  targetActivitySafe(
                    cached.inputGeneration, windowID: cached.windowID),
                  let record = cached.snapshot.observation.elements.first(
                    where: { $0.index == index }),
                  record.role == role, record.enabled,
                  !record.inWebContent,
                  ScreenContext.isEditableActionRole(role),
                  AppMatcher.normalize(record.label ?? "")
                    == AppMatcher.normalize(label),
                  AppMatcher.bestMatch(for: target, in: [label]) != nil,
                  nativeValueEquals(
                    backgroundDraft, index, cached.snapshot),
                  targetActivitySafe(
                    cached.inputGeneration, windowID: cached.windowID)
            else { return false }
            return true
        }
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
        if let cached = routedNativeSnapshot {
            let receiptPath: NavigationPath?
            if let receipt = navigationReceipt,
               receipt.process == targetProcessIdentity,
               receipt.windowID == cached.windowID,
               receipt.bundleID.caseInsensitiveCompare(cached.bundleID)
                    == .orderedSame,
               receipt.mutationOrdinal == mutationOrdinal,
               receipt.observedSnapshotID == snapshotID,
               targetActivitySafe(
                    receipt.inputGeneration, windowID: cached.windowID),
               let path = navigationPaths(
                    in: cached.snapshot.observation)[index],
               !receipt.baseline.contains(path) {
                receiptPath = path
            } else {
                receiptPath = nil
            }
            guard snapshotLineage == .valid,
                  expectedMatchesTarget(bundleID), targetReady,
                  cached.snapshot.observation.id == snapshotID,
                  cached.pid == targetPID,
                  cached.windowID == targetWindowID,
                  cached.bundleID == targetBundleID,
                  targetActivitySafe(
                    cached.inputGeneration, windowID: cached.windowID),
                  let record = cached.snapshot.observation.elements.first(
                    where: { $0.index == index }),
                  record.role == role, record.enabled,
                  !record.inWebContent,
                  AppMatcher.normalize(record.label ?? "")
                    == AppMatcher.normalize(label),
                  AppMatcher.bestMatch(for: target, in: [label]) != nil,
                  navigationReceipt == nil
                    ? record.selected || record.focused
                    : receiptPath != nil,
                  ActionUIEvidencePolicy.mayVerifyGoal(
                    index: index, source: .native,
                    in: cached.snapshot.observation.elements),
                  let window = exactTargetWindow(),
                  targetActivitySafe(
                    cached.inputGeneration, windowID: cached.windowID),
                  exactTargetWindow() == window
            else { return false }
            navigationReceipt = nil
            return true
        }
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

    private func navigationPaths(
        in snapshot: ActionUISnapshot
    ) -> [Int: NavigationPath] {
        let elements = Dictionary(
            uniqueKeysWithValues: snapshot.elements.map { ($0.index, $0) })
        var result: [Int: NavigationPath] = [:]

        for candidate in snapshot.elements {
            var current = candidate
            var visited = Set<Int>()
            var nodes: [NavigationNode] = []

            while true {
                guard visited.insert(current.index).inserted,
                      current.actions.isEmpty else {
                    nodes.removeAll()
                    break
                }
                nodes.append(NavigationNode(
                    role: current.role,
                    label: AppMatcher.normalize(current.label ?? "")))
                guard let parent = current.parentIndex else { break }
                guard let ancestor = elements[parent] else {
                    nodes.removeAll()
                    break
                }
                current = ancestor
            }
            if !nodes.isEmpty {
                result[candidate.index] = NavigationPath(
                    nodes: nodes.reversed())
            }
        }
        return result
    }

    func foregroundWindow() -> ActionWindowIdentity? {
        routed || terminalFailureReason != nil
            ? nil : system.foregroundWindow()
    }

    func actionWindow() -> ActionWindowIdentity? {
        guard terminalFailureReason == nil else { return nil }
        guard routed else { return system.actionWindow() }
        guard preserveUserFocus() else { return nil }
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
        guard preserveUserFocus() else { return nil }
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
        guard snapshotLineage == .valid, targetReady, everReady,
              let target = exactRoutedProcess() else { return [] }
        return nativeMedia.capabilities(for: target)
    }

    func mediaControl(
        _ control: ActionMediaControl
    ) -> ActionMediaControlResult {
        guard terminalFailureReason == nil else { return .unavailable }
        switch control.capability {
        case .cua:
            return .unavailable
        case .appNative:
            guard routed, snapshotLineage == .valid, targetReady,
                  let target = exactRoutedProcess(),
                  !userIsInTarget(), let lease = captureMutationLease(),
                  mutationLeaseIsLive(lease) else { return .unavailable }
            pendingMutationLease = lease
            let result = nativeMedia.perform(
                control, target: target,
                maySend: {
                    !self.userIsInTarget()
                        && self.mutationLeaseIsLive(lease)
                })
            guard finalizeMutation(lease) else { return .misdirected }
            return result
        }
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

    func presentUI(snapshotID: String, bundleID: String, windowID: Int,
                   scope: ActionPresentationScope = .window) -> Bool {
        // Automatic presentation is forbidden. The nonactivating completion
        // card owns the only foreground handoff, after a direct user click.
        return false
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
        writeExactText(
            text, operation: .type, target: target, expecting: bundleID)
    }

    func replaceText(
        _ text: String, target: ActionTextTarget,
        expecting bundleID: String?
    ) -> ActionStateReceipt? {
        writeExactText(
            text, operation: .replace, target: target, expecting: bundleID)
    }

    func searchText(
        _ text: String, target: ActionTextTarget,
        expecting bundleID: String?
    ) -> ActionStateReceipt? {
        writeExactText(
            text, operation: .search, target: target, expecting: bundleID)
    }

    private func writeExactText(
        _ text: String, operation: ActionTextOperation,
        target: ActionTextTarget, expecting bundleID: String?
    ) -> ActionStateReceipt? {
        guard routed, snapshotLineage == .valid,
              expectedMatchesTarget(bundleID), targetReady,
              let windowID = targetWindowID,
              let cached = routedNativeSnapshot,
              cached.snapshot.observation.id == target.snapshotID,
              cached.pid == targetPID, cached.windowID == windowID,
              cached.bundleID == targetBundleID,
              targetActivitySafe(
                  cached.inputGeneration, windowID: windowID),
              let record = cached.snapshot.observation.elements.first(where: {
                  $0.index == target.index
              }),
              let nativeElement = cached.snapshot.elementsByIndex[
                target.index],
              record.role == target.role, record.enabled,
              !record.inWebContent,
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(target.label),
              ScreenContext.isEditableActionRole(target.role),
              operation != .search || ActionPlan.isSearchTextTarget(
                role: target.role, label: target.label),
              let lease = captureMutationLease()
        else { return nil }
        navigationReceipt = nil
        let priorValue: String
        let expected: String
        switch operation {
        case .replace, .search:
            guard let baseline = cached.snapshot.writeBaselines[target.index]
            else { return nil }
            priorValue = baseline
            expected = text
        case .type, .paste:
            priorValue = backgroundDraft
            expected = priorValue + text
        }
        routedNativeSnapshot = nil
        guard mutationLeaseIsLive(lease) else { return nil }
        pendingMutationLease = lease
        let verified = nativeWrite(
            expected, priorValue, target.index, cached.snapshot)
        let focusPreserved = finalizeMutation(lease)
        guard focusPreserved, verified else {
            if focusPreserved {
                _ = failMutation(
                    "The text change could not be verified. It was not retried.")
            }
            backgroundDraft = ""
            writtenElement = nil
            writtenNativeElement = nil
            return nil
        }
        if operation == .search {
            backgroundDraft = ""
            writtenElement = nil
            writtenNativeElement = nil
        } else {
            backgroundDraft = expected
            writtenElement = ElementIdentity(record)
            writtenNativeElement = nativeElement
        }
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
        let foreground: ActionWindowIdentity
    }

    private func captureMutationLease() -> TargetMutationLease? {
        guard let windowID = targetWindowID,
              let process = targetProcessIdentity,
              let front = system.frontmostApp(),
              let foreground = system.foregroundWindow(),
              foreground.bundleID.caseInsensitiveCompare(front.bundleID)
                == .orderedSame,
              foreground.bundleID.caseInsensitiveCompare(targetBundleID)
                != .orderedSame else { return nil }
        let generation = UserInputActivity.snapshot()
        guard processIdentity(targetPID) == process,
              targetWindowExists(),
              targetActivitySafe(generation, windowID: windowID)
        else { return nil }
        return TargetMutationLease(
            generation: generation, process: process, windowID: windowID,
            foreground: foreground)
    }

    private func mutationLeaseIsLive(_ lease: TargetMutationLease) -> Bool {
        guard targetWindowID == lease.windowID,
              processIdentity(targetPID) == lease.process,
              targetWindowExists() else { return false }
        switch UserInputActivity.activity(
            after: lease.generation, targetPID: targetPID,
            targetWindowID: lease.windowID) {
        case .unchanged:
            return system.foregroundWindow() == lease.foreground
        case .unrelated:
            return currentFocusIsNonTarget()
        case .target, .unknown:
            return false
        }
    }

    private func finalizeMutation(_ lease: TargetMutationLease) -> Bool {
        if mutationLeaseIsLive(lease) { return true }
        guard targetWindowID == lease.windowID,
              processIdentity(targetPID) == lease.process,
              targetWindowExists() else { return mutationFocusFailed() }

        // One retry handles input arriving during restoration. The old window
        // is never reasserted after that input; only the ledger's exact latest
        // user-selected window may be restored.
        for _ in 0..<2 {
            let activity = UserInputActivity.activity(
                after: lease.generation, targetPID: targetPID,
                targetWindowID: lease.windowID)
            let generation: UInt64
            let prior: ActionWindowIdentity
            let userSelected: Bool
            switch activity {
            case .unchanged:
                generation = lease.generation
                prior = lease.foreground
                userSelected = false
            case .unrelated:
                guard let selection = UserInputActivity.selectedFocus(
                        after: lease.generation),
                      let selected = userFocusForWindow(selection.windowID),
                      selected.bundleID.caseInsensitiveCompare(targetBundleID)
                        != .orderedSame,
                      UserInputActivity.snapshot() == selection.generation
                else { continue }
                generation = selection.generation
                prior = selected
                userSelected = true
            case .target, .unknown:
                return mutationFocusFailed()
            }

            if system.foregroundWindow() == prior { return true }
            guard targetOwnsForeground() || userSelected else {
                return mutationFocusFailed()
            }
            if restoreForeground(prior, {
                    UserInputActivity.snapshot() == generation
                }),
               UserInputActivity.snapshot() == generation,
               system.foregroundWindow() == prior {
                return true
            }
        }
        return failRoute(
            "The target app took the screen and the previous window "
                + "could not be restored.")
    }

    private func mutationFocusFailed() -> Bool {
        failMutation(
            "The target changed after the action. The result was not retried.")
    }

    @discardableResult
    private func failMutation(_ reason: String) -> Bool {
        navigationReceipt = nil
        terminalFailureReason = reason
        veloraLog("Velora: \(reason)")
        return false
    }

    private func preserveUserFocus() -> Bool {
        guard let lease = pendingMutationLease else { return true }
        return finalizeMutation(lease)
    }

    private func targetOwnsForeground() -> Bool {
        guard let front = system.frontmostApp(),
              let window = system.foregroundWindow()
        else { return false }
        return front.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame
            && window.pid == targetPID
            && window.windowID == targetWindowID
            && window.bundleID.caseInsensitiveCompare(targetBundleID)
                == .orderedSame
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
        // Unstructured text has no retained native element reference. The
        // planner must re-observe and use typeText(target:) instead.
        return false
    }

    func pressKey(name: String, mods: [String], keyCode: CGKeyCode,
                  flags: CGEventFlags, expecting bundleID: String?) -> Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else {
            return system.pressKey(name: name, mods: mods, keyCode: keyCode,
                                   flags: flags, expecting: bundleID)
        }
        // Synthesized keys have no exact-window postcondition. Routed key
        // plans therefore fail closed instead of invoking Cua's focus lease.
        return false
    }

    // MARK: - Machine state

    /// Unscoped typing is a foreground concept. Background text must carry an
    /// exact native element or the one-shot visual capability.
    var hasFocusedTextTarget: Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else { return system.hasFocusedTextTarget }
        return false
    }

    var canPostInput: Bool {
        guard terminalFailureReason == nil else { return false }
        guard routed else { return system.canPostInput }
        guard snapshotLineage == .valid else { return false }
        // Each native delivery seam performs its own permission preflight.
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

}
