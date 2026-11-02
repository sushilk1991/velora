import Foundation

/// Current state of a native two/three-state control (AXCheckBox, including
/// subrole AXSwitch) whose AXValue is numeric 0/1/2 and which exposes AXPress.
/// The engine's claim that a done needs no step: the one switch an explicit
/// on/off command names already shows that state in the snapshot it planned
/// from. The app trusts none of it until `ActionHost.observedToggle` re-reads
/// that exact element live.
struct ActionObservedToggle: Equatable {
    let snapshotID: String
    let index: Int
    let label: String
    let state: ActionToggleState

    init(snapshotID: String, index: Int, label: String,
         state: ActionToggleState) {
        self.snapshotID = snapshotID
        self.index = index
        self.label = label
        self.state = state
    }

    init?(payload: Any?) {
        guard let object = payload as? [String: Any],
              let snapshotID = object["snapshot"] as? String,
              !snapshotID.isEmpty,
              let index = object["index"] as? Int,
              let label = object["label"] as? String, !label.isEmpty,
              let raw = object["state"] as? String,
              let state = ActionToggleState(rawValue: raw),
              state != .mixed
        else { return nil }
        self.init(snapshotID: snapshotID, index: index, label: label,
                  state: state)
    }

    /// The app's own check that this is exactly what the command asks: the
    /// state it explicitly requests, for a switch whose whole label is its
    /// target. A done for anything else is not this proof.
    func answers(_ transcript: String) -> Bool {
        let target = ActionToggleCommand.target(transcript)
        return !target.isEmpty
            && ActionToggleCommand.requestedState(transcript) == state
            && AppMatcher.normalize(label) == target
    }
}

/// The app's copy of the engine's explicit on/off command reading
/// (`command_requests_toggle` and `_toggle_target` in actions.py).
enum ActionToggleCommand {
    static let verbWords: Set<String> = ["turn", "switch", "toggle", "set", "put"]
    static let intentWords: [ActionToggleState: Set<String>] = [
        .on: ["enable", "activate"],
        .off: ["disable", "deactivate", "uncheck"],
    ]

    private static func words(_ command: String) -> [String] {
        AppMatcher.words(
            command.folding(options: .diacriticInsensitive, locale: nil))
    }

    /// The one state the command asks for: "turn on X", "switch X off",
    /// "enable X". Both or neither is not explicit.
    static func requestedState(_ command: String) -> ActionToggleState? {
        let said = Set(words(command))
        let asked = [ActionToggleState.on, .off].filter { state in
            !said.isDisjoint(with: intentWords[state] ?? [])
                || (!said.isDisjoint(with: verbWords)
                    && said.contains(state.rawValue))
        }
        return asked.count == 1 ? asked[0] : nil
    }

    /// What it toggles, normalized: only the toggle phrase is removed, every
    /// other word kept ("turn on Find My" → "findmy"); "" otherwise.
    static func target(_ command: String) -> String {
        var said = words(command)
        while said.first == "please" { said.removeFirst() }
        while said.last == "please" { said.removeLast() }
        guard said.count >= 2 else { return "" }
        let intent = intentWords.values.reduce(Set<String>()) { $0.union($1) }
        let states: Set<String> = ["on", "off"]
        var rest: ArraySlice<String>
        if intent.contains(said[0]) {
            rest = said[1...]
        } else if verbWords.contains(said[0]), states.contains(said[1]) {
            rest = said[2...]
        } else if verbWords.contains(said[0]), let last = said.last,
                  states.contains(last) {
            rest = said[1..<(said.count - 1)]
        } else {
            return ""
        }
        if rest.first == "the" { rest = rest.dropFirst() }
        return rest.joined()
    }
}

enum ActionToggleState: String, Equatable {
    case on
    case off
    case mixed

    init?(axValue: Double) {
        switch axValue {
        case 0: self = .off
        case 1: self = .on
        case 2: self = .mixed
        default: return nil
        }
    }
}

/// A declarative target state `set_ui` may put one exact element into. The
/// element's `set` list names only states reachable NOW (never its current
/// one); the engine trusts nothing outside this closed enum.
enum ActionUISetState: String, Equatable, CaseIterable {
    case on
    case off
    case selected
    case expanded
    case collapsed

    /// on/off name a setting, not a commit, so they use the press denylist
    /// minus the toggle-exempt words. Navigation states keep the full list.
    var isToggle: Bool { self == .on || self == .off }

    /// Canonical wire order, so payloads are stable across walks.
    static func ordered(_ states: Set<ActionUISetState>) -> [ActionUISetState] {
        allCases.filter { states.contains($0) }
    }
}

/// Pure capture-time rules for the per-element `toggle` / `expanded` / `set`
/// fields. ScreenContext reads the AX attributes; these decide what they mean.
enum ActionUISetPolicy {
    /// `on`/`off`: the opposite of the current state; `mixed` offers both.
    static func toggleTargets(
        _ toggle: ActionToggleState?, hasPress: Bool
    ) -> Set<ActionUISetState> {
        guard let toggle, hasPress else { return [] }
        switch toggle {
        case .on: return [.off]
        case .off: return [.on]
        case .mixed: return [.on, .off]
        }
    }

    /// `selected` (AXRow only): not already selected, and either its own
    /// AXSelected or its nearest list container's AXSelectedRows is settable.
    static func selectionTargets(
        role: String, selected: Bool,
        ownSelectable: Bool, containerSelectable: Bool
    ) -> Set<ActionUISetState> {
        guard role == "AXRow", !selected,
              ownSelectable || containerSelectable else { return [] }
        return [.selected]
    }

    /// `expanded`/`collapsed`: the opposite of the current disclosure.
    static func disclosureTargets(
        expanded: Bool?, changeable: Bool
    ) -> Set<ActionUISetState> {
        guard let expanded, changeable else { return [] }
        return expanded ? [.collapsed] : [.expanded]
    }

    /// Roles whose list container may grant row selection.
    static let selectionContainerRoles: Set<String> = [
        "AXTable", "AXOutline", "AXList",
    ]
    /// How far above a row its selection container may sit.
    static let containerAncestorLevels = 3
    /// Readback after a set: ≤5 reads, 50 ms apart.
    static let readbackAttempts = 5
    static let readbackInterval: TimeInterval = 0.05
}

/// Pure rules for labels derived when an element carries no authored name.
enum ActionDerivedLabelPolicy {
    /// AXRow names live in a descendant; bounded BFS.
    static let rowLevels = 4
    static let rowNodes = 16
    /// Roles that may borrow their AXTitleUIElement's name.
    static let titleElementRoles: Set<String> = [
        "AXCheckBox", "AXSlider", "AXPopUpButton",
    ]

    /// Siblings read before a control when nothing else names it.
    static let rowTextSiblings = 4

    /// The name a control shows beside it when nothing names it: the one
    /// short static text in the run directly before it (a SwiftUI form row
    /// is title, optional prose subtitle, control). Any other sibling ends
    /// the run, so a control never borrows a neighbouring row's text. Two
    /// short texts name nothing: a section heading above a row title looks
    /// the same as a title above a short subtitle, and a wrong name flips
    /// the wrong switch, while no name only leaves it unreachable.
    /// `preceding` is nearest first. System Settings' Wi-Fi switch
    /// (`wifi-power`) has no title, description, or title element (live
    /// probe 2026-11-02); its row is "Wi‑Fi", a prose subtitle, the switch.
    static func rowTextLabel(
        preceding: [(role: String, value: String?)]
    ) -> String? {
        var names: [String] = []
        for sibling in preceding.prefix(rowTextSiblings) {
            guard sibling.role == "AXStaticText" else { break }
            if let value = sibling.value, isShortName(value) {
                names.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return names.count == 1 ? names[0] : nil
    }

    /// The existing passive-label rule: a name, tab, or status, not prose.
    static func isShortName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
            && trimmed.split(whereSeparator: \.isWhitespace).count <= 8
    }
}

/// Snapshot-level marker for a find-scoped tree. It grants navigation only.
struct ActionUIScope: Equatable {
    static let findKind = "find"
    let kind: String
    let query: String
    let matches: Int

    init(query: String, matches: Int) {
        kind = Self.findKind
        self.query = query
        self.matches = matches
    }

    var isFind: Bool { kind == Self.findKind }

    var payload: [String: Any] {
        ["kind": kind, "query": query, "matches": matches]
    }
}

/// Pure rules for the bounded `find_ui` walk.
enum ActionFindPolicy {
    static let minQueryCharacters = 3
    static let maxQueryCharacters = 60
    /// The walk's bound; the output is the snapshot's own 500 records.
    static let deadline: TimeInterval = 2
    /// Cycle/pathology guard only; the deadline is the real bound.
    static let maxDepth = 128

    /// The planner's query after the same sanitize and whitespace collapse
    /// the engine applies; nil when outside 3–60 characters.
    static func cleanedQuery(_ raw: String) -> String? {
        let cleaned = ActionPlan.sanitize(raw)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard cleaned.count >= minQueryCharacters,
              cleaned.count <= maxQueryCharacters else { return nil }
        return cleaned
    }

    /// Normalized label or short static-text value CONTAINS the query.
    static func matches(_ candidate: String?, query normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty, let candidate else { return false }
        return AppMatcher.normalize(candidate).contains(normalizedQuery)
    }
}

/// The bounded projection of the target app's menu bar sent with a native
/// snapshot. Paths are exact captured titles; matching is component-wise
/// normalized, mirroring the engine's `normalized_term`.
struct ActionMenuBar: Equatable {
    let complete: Bool
    let top: [String]
    let items: [[String]]

    var payload: [String: Any] {
        [
            "complete": complete,
            "top": top,
            "items": items.map { ["path": $0] },
        ]
    }

    static func normalizedPath(_ path: [String]) -> [String] {
        path.map { AppMatcher.normalize($0) }
    }

    /// The single captured entry the planner's path names, if any.
    func entry(matching path: [String]) -> [String]? {
        let wanted = Self.normalizedPath(path)
        guard !wanted.contains(where: \.isEmpty) else { return nil }
        let found = items.filter { Self.normalizedPath($0) == wanted }
        return found.count == 1 ? found[0] : nil
    }

    /// For the repair note, mirroring the engine's `_menu_children_hint`:
    /// the deepest prefix of `path` that exists in `items` AND has a child
    /// below it, and that prefix's distinct next components (bounded).
    func deepestPrefix(
        of path: [String], childLimit: Int = 12
    ) -> (prefix: [String], children: [String]) {
        let wanted = Self.normalizedPath(path)
        var depth = 0
        for item in items {
            var shared = 0
            for (have, want) in zip(item, wanted) {
                guard AppMatcher.normalize(have) == want else { break }
                shared += 1
            }
            depth = max(depth, min(shared, item.count - 1))
        }
        let wantedPrefix = Array(wanted.prefix(depth))
        var prefix: [String] = []
        var seen = Set<String>()
        var children: [String] = []
        for item in items where item.count > depth
            && Self.normalizedPath(Array(item.prefix(depth))) == wantedPrefix {
            if prefix.isEmpty { prefix = Array(item.prefix(depth)) }
            let child = item[depth]
            if seen.insert(AppMatcher.normalize(child)).inserted {
                children.append(child)
            }
            if children.count >= childLimit { break }
        }
        return (prefix, children)
    }
}

/// Menu policy, applied at capture AND at execution. Pure functions only.
enum ActionMenuPolicy {
    /// Bounded by `walkDeadline`, not an item count: a 600-leaf cap left a
    /// big app's later menus unreachable. Only matching paths reach the
    /// planner prompt (engine MAX_PROMPT_MENU_ITEMS).
    static let maxPathComponents = 5
    static let maxComponentCharacters = 80
    static let walkDeadline: TimeInterval = 0.5
    /// AXMenuItemCmdModifiers bit: set = the shortcut has no ⌘.
    static let noCommandModifierBit = 8

    /// ⌘ with these characters quits, closes, saves, cuts, pastes, undoes,
    /// hides, deletes, commits, or cancels. Lowercased; control characters
    /// are AppKit's key equivalents for Delete/Forward Delete/Return/Enter/Esc.
    static let deniedCommandCharacters: Set<String> = [
        "q", "w", "s", "x", "v", "z", "h",
        "\u{8}", "\u{7f}", "\u{f728}", "\r", "\n", "\u{3}", "\u{1b}",
    ]
    /// Virtual key codes for the same keys (Q W S X V Z H, Delete, Forward
    /// Delete, Return, keypad Enter, Enter, Escape).
    static let deniedVirtualKeys: Set<Int> = [
        12, 13, 1, 7, 9, 6, 4, 51, 117, 36, 76, 52, 53,
    ]
    /// Menu glyphs: Enter, Forward Delete, Return, Return R2L, nonmarking
    /// Return, Delete, Escape.
    static let deniedGlyphs: Set<Int> = [
        0x04, 0x0A, 0x0B, 0x0C, 0x0D, 0x17, 0x1B,
    ]

    static func usesCommand(modifiers: Int?) -> Bool {
        (modifiers ?? 0) & noCommandModifierBit == 0
    }

    static func hasShortcut(
        cmdChar: String?, virtualKey: Int?, glyph: Int?
    ) -> Bool {
        !(cmdChar ?? "").isEmpty || virtualKey != nil || (glyph ?? 0) != 0
    }

    /// True when the item's ⌘ shortcut (any extra modifiers) is one of the
    /// denied keys. Any denied signal wins: the conservative direction.
    static func shortcutIsDenied(
        cmdChar: String?, virtualKey: Int?, glyph: Int?, modifiers: Int?
    ) -> Bool {
        guard hasShortcut(cmdChar: cmdChar, virtualKey: virtualKey, glyph: glyph),
              usesCommand(modifiers: modifiers) else { return false }
        if let cmdChar, deniedCommandCharacters.contains(cmdChar.lowercased()) {
            return true
        }
        if let virtualKey, deniedVirtualKeys.contains(virtualKey) { return true }
        if let glyph, deniedGlyphs.contains(glyph) { return true }
        return false
    }

    /// The app menu contributes only the item whose shortcut is exactly ⌘,.
    static func isSettingsShortcut(cmdChar: String?, modifiers: Int?) -> Bool {
        cmdChar == "," && (modifiers ?? 0) == 0
    }

    /// Committing (press denylist) or containing a menu-deny word.
    static func componentIsDenied(_ component: String) -> Bool {
        if ActionPlan.pressLabelIsCommitting(component) { return true }
        return ActionPlan.labelWords(component).contains {
            ActionPlan.Limits.menuDenyWords.contains($0)
        }
    }

    /// Capture-time title cleanup: sanitized, trimmed, bounded, allowed.
    static func capturedComponent(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Same form as the engine's `_menu_component`: sanitized, whitespace
        // runs collapsed to one space.
        let title = ActionPlan.sanitize(raw)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty, !AppMatcher.normalize(title).isEmpty,
              title.count <= maxComponentCharacters,
              !componentIsDenied(title) else { return nil }
        return title
    }
}

/// Per-pid menu-bar cache. A walk is ≤0.5 s, so it is prewarmed off-main when
/// the Action hotkey goes down and reused for 120 s; a `menu_item` on a pid
/// invalidates it. Never walks on the main thread.
final class ActionMenuBarCache {
    static let shared = ActionMenuBarCache(walk: { pid, bundleID in
        ScreenContext.actionMenuBar(pid: pid, bundleID: bundleID)
    })
    static let ttl: TimeInterval = 120

    private struct Entry {
        let bundleID: String
        let bar: ActionMenuBar
        let at: TimeInterval
    }

    private let walk: (Int, String) -> ActionMenuBar?
    private let now: () -> TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var inFlight: [Int: DispatchGroup] = [:]
    private var generations: [Int: Int] = [:]

    init(
        walk: @escaping (Int, String) -> ActionMenuBar?,
        now: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        self.walk = walk
        self.now = now
        self.queue = queue
    }

    /// The fresh cached bar, else one bounded walk (or the in-flight one).
    /// On the main thread this only returns a fresh entry and prewarms.
    func menuBar(pid: Int, bundleID: String) -> ActionMenuBar? {
        guard pid > 0, !bundleID.isEmpty else { return nil }
        if let cached = fresh(pid: pid, bundleID: bundleID) { return cached }
        if Thread.isMainThread {
            prewarm(pid: pid, bundleID: bundleID)
            return nil
        }
        switch claim(pid: pid) {
        case .owner(let group, let generation):
            let bar = walk(pid, bundleID)
            finish(pid: pid, bundleID: bundleID, bar: bar,
                   generation: generation, group: group)
            return bar
        case .waiter(let group):
            _ = group.wait(timeout: .now()
                + ActionMenuPolicy.walkDeadline + 0.5)
            return fresh(pid: pid, bundleID: bundleID)
        }
    }

    /// Starts the walk in the background unless fresh or already running.
    func prewarm(pid: Int, bundleID: String) {
        guard pid > 0, !bundleID.isEmpty,
              fresh(pid: pid, bundleID: bundleID) == nil,
              case .owner(let group, let generation) = claim(pid: pid)
        else { return }
        queue.async { [self] in
            let bar = walk(pid, bundleID)
            finish(pid: pid, bundleID: bundleID, bar: bar,
                   generation: generation, group: group)
        }
    }

    /// A menu command may change the menus; the next read walks again.
    func invalidate(pid: Int) {
        lock.lock()
        entries.removeValue(forKey: pid)
        generations[pid, default: 0] += 1
        lock.unlock()
    }

    private enum Claim {
        case owner(DispatchGroup, Int)
        case waiter(DispatchGroup)
    }

    private func claim(pid: Int) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        if let group = inFlight[pid] { return .waiter(group) }
        let group = DispatchGroup()
        group.enter()
        inFlight[pid] = group
        return .owner(group, generations[pid, default: 0])
    }

    private func finish(
        pid: Int, bundleID: String, bar: ActionMenuBar?,
        generation: Int, group: DispatchGroup
    ) {
        lock.lock()
        if let bar, generations[pid, default: 0] == generation {
            entries[pid] = Entry(bundleID: bundleID, bar: bar, at: now())
        }
        inFlight.removeValue(forKey: pid)
        lock.unlock()
        group.leave()
    }

    private func fresh(pid: Int, bundleID: String) -> ActionMenuBar? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[pid],
              entry.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame,
              now() - entry.at < Self.ttl else { return nil }
        return entry.bar
    }
}
