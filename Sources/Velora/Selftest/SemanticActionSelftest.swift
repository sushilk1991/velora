import AppKit
import ApplicationServices
import Foundation

/// set_ui, menu_item, and find_ui: the pure policies, the plan contract the
/// engine mirrors, the executor outcomes, and both hosts' authority rules.
extension Selftest {
    static func testSemanticActions() {
        testSemanticCapturePolicy()
        testMenuPolicy()
        testMenuBarCache()
        testSemanticPayload()
        testSetUIDecoding()
        testMenuItemDecoding()
        testFindUIDecoding()
        testSemanticExecutor()
        testSemanticBackgroundHost()
    }

    // MARK: - Fixtures

    private static let semanticMenuBar = ActionMenuBar(
        complete: true,
        top: ["Finder", "File", "View", "Go"],
        items: [
            ["Finder", "Settings…"],
            ["File", "New Folder"],
            ["View", "Show Sidebar"],
            ["View", "Show Path Bar"],
            ["Go", "Downloads"],
        ])

    private static func semanticSnapshot(
        id: String = "sem-1", complete: Bool = true,
        scope: ActionUIScope? = nil, wifi: ActionToggleState = .off,
        notifications: ActionToggleState = .off,
        menuBar: ActionMenuBar? = semanticMenuBar
    ) -> ActionUISnapshot {
        let wifiTargets = ActionUISetState.ordered(
            ActionUISetPolicy.toggleTargets(wifi, hasPress: true))
        let notificationTargets = ActionUISetState.ordered(
            ActionUISetPolicy.toggleTargets(notifications, hasPress: true))
        return ActionUISnapshot(
            id: id, appName: "Finder", bundleID: "com.apple.finder",
            windowTitle: "Downloads", windowID: 9, complete: complete,
            elements: [
                ActionUIElement(
                    index: 0, parentIndex: nil, depth: 0, role: "AXWindow",
                    label: "Downloads", frame: nil, actions: []),
                ActionUIElement(
                    index: 1, parentIndex: 0, depth: 1, role: "AXCheckBox",
                    label: "Wi-Fi", frame: nil,
                    actions: [ActionUICapability.axPress],
                    toggle: wifi, settable: wifiTargets),
                ActionUIElement(
                    index: 2, parentIndex: 0, depth: 1, role: "AXRow",
                    label: "Downloads", frame: nil, actions: [],
                    expanded: false, settable: [.selected, .expanded]),
                ActionUIElement(
                    index: 3, parentIndex: 0, depth: 1, role: "AXCheckBox",
                    label: "Enable notifications", frame: nil,
                    actions: [ActionUICapability.axPress],
                    toggle: notifications, settable: notificationTargets),
                ActionUIElement(
                    index: 4, parentIndex: 0, depth: 1, role: "AXRow",
                    label: "Enable sync", frame: nil, actions: [],
                    settable: [.selected]),
                ActionUIElement(
                    index: 5, parentIndex: 0, depth: 1, role: "AXCheckBox",
                    label: "Send read receipts", frame: nil,
                    actions: [ActionUICapability.axPress],
                    toggle: .off, settable: [.on]),
            ],
            scope: scope, menuBar: menuBar)
    }

    private static func semanticState(
        _ snapshot: ActionUISnapshot = semanticSnapshot(),
        command: String = "turn on wi-fi in Finder"
    ) -> ActionPlan.BatchState {
        var state = ActionPlan.BatchState()
        state.structuredUIAvailable = true
        state.structuredUIComplete = snapshot.complete
        state.structuredUISnapshot = snapshot
        state.spokenCommand = command
        return state
    }

    private static func decodeSemantic(
        _ steps: String, _ snapshot: ActionUISnapshot = semanticSnapshot(),
        command: String = "turn on wi-fi in Finder"
    ) -> Result<ActionPlan, ActionPlanError> {
        var state = semanticState(snapshot, command: command)
        let json = "{\"sends\":false,\"steps\":[\(steps)]}"
        if let plan = decodeBatch(json, state: &state) { return .success(plan) }
        state = semanticState(snapshot, command: command)
        return .failure(decodeBatchError(json, state: &state)
            ?? .notAnObject)
    }

    private static let finderCheckpoint =
        "{\"do\":\"wait_frontmost\",\"app\":\"Finder\"}"

    // MARK: - Capture policy

    private static func testSemanticCapturePolicy() {
        expect(ActionToggleState(axValue: 0) == .off
               && ActionToggleState(axValue: 1) == .on
               && ActionToggleState(axValue: 2) == .mixed
               && ActionToggleState(axValue: 3) == nil
               && ActionToggleState(axValue: 0.5) == nil,
               "only numeric 0/1/2 are toggle states")
        expect(ActionUISetPolicy.toggleTargets(.on, hasPress: true) == [.off]
               && ActionUISetPolicy.toggleTargets(.off, hasPress: true) == [.on]
               && ActionUISetPolicy.toggleTargets(.mixed, hasPress: true)
                == [.on, .off]
               && ActionUISetPolicy.toggleTargets(.off, hasPress: false).isEmpty
               && ActionUISetPolicy.toggleTargets(nil, hasPress: true).isEmpty,
               "a switch offers the opposite state, and only with AXPress")
        expect(ActionUISetPolicy.selectionTargets(
                role: "AXRow", selected: false,
                ownSelectable: false, containerSelectable: true) == [.selected]
               && ActionUISetPolicy.selectionTargets(
                role: "AXRow", selected: true,
                ownSelectable: true, containerSelectable: true).isEmpty
               && ActionUISetPolicy.selectionTargets(
                role: "AXButton", selected: false,
                ownSelectable: true, containerSelectable: true).isEmpty
               && ActionUISetPolicy.selectionTargets(
                role: "AXRow", selected: false,
                ownSelectable: false, containerSelectable: false).isEmpty,
               "selected is offered only for an unselected, selectable AXRow")
        expect(ActionUISetPolicy.disclosureTargets(
                expanded: false, changeable: true) == [.expanded]
               && ActionUISetPolicy.disclosureTargets(
                expanded: true, changeable: true) == [.collapsed]
               && ActionUISetPolicy.disclosureTargets(
                expanded: true, changeable: false).isEmpty,
               "disclosure offers only the opposite, settable state")
        expect(ActionUISetState.ordered([.expanded, .selected, .on])
                == [.on, .selected, .expanded],
               "set lists use one stable wire order")
        expect(ActionDerivedLabelPolicy.isShortName("Downloads")
               && ActionDerivedLabelPolicy.isShortName(
                "one two three four five six seven eight")
               && !ActionDerivedLabelPolicy.isShortName(
                "one two three four five six seven eight nine")
               && !ActionDerivedLabelPolicy.isShortName(
                String(repeating: "x", count: 81))
               && !ActionDerivedLabelPolicy.isShortName("   "),
               "derived row labels use the passive short-name rule")
        expect(ActionFindPolicy.cleanedQuery("  Down   loads ") == "Down loads"
               && ActionFindPolicy.cleanedQuery("ab") == nil
               && ActionFindPolicy.cleanedQuery(
                String(repeating: "a", count: 61)) == nil,
               "find queries are cleaned to 3-60 characters")
        expect(ActionFindPolicy.matches(
                "My Downloads", query: AppMatcher.normalize("downloads"))
               && !ActionFindPolicy.matches("Desktop", query: "downloads")
               && !ActionFindPolicy.matches("anything", query: "")
               && !ActionFindPolicy.matches(nil, query: "downloads"),
               "find matching is normalized containment")
    }

    // MARK: - Menu policy

    private static func testMenuPolicy() {
        let noCommand = ActionMenuPolicy.noCommandModifierBit
        expect(ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "Q", virtualKey: nil, glyph: nil, modifiers: 0)
               && ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "w", virtualKey: nil, glyph: nil, modifiers: 0)
               && ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "S", virtualKey: nil, glyph: nil, modifiers: 1)
               && ActionMenuPolicy.shortcutIsDenied(
                cmdChar: nil, virtualKey: 51, glyph: nil, modifiers: 0)
               && ActionMenuPolicy.shortcutIsDenied(
                cmdChar: nil, virtualKey: nil, glyph: 0x17, modifiers: 0)
               && ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "\r", virtualKey: nil, glyph: nil, modifiers: 0)
               && ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "\u{1b}", virtualKey: nil, glyph: nil, modifiers: 0),
               "⌘Q/W/S (any extra modifiers), Delete, Return, Escape are denied")
        expect(!ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "N", virtualKey: 45, glyph: nil, modifiers: 1)
               && !ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "Q", virtualKey: 12, glyph: nil,
                modifiers: noCommand | 2)
               && !ActionMenuPolicy.shortcutIsDenied(
                cmdChar: nil, virtualKey: nil, glyph: nil, modifiers: 0)
               && !ActionMenuPolicy.shortcutIsDenied(
                cmdChar: "", virtualKey: nil, glyph: 0, modifiers: nil),
               "⌘⇧N, a shortcut without ⌘, and no shortcut stay allowed")
        expect(ActionMenuPolicy.isSettingsShortcut(cmdChar: ",", modifiers: 0)
               && ActionMenuPolicy.isSettingsShortcut(cmdChar: ",", modifiers: nil)
               && !ActionMenuPolicy.isSettingsShortcut(cmdChar: ",", modifiers: 1)
               && !ActionMenuPolicy.isSettingsShortcut(cmdChar: "q", modifiers: 0),
               "only exactly ⌘, counts as the app menu's Settings item")
        expect(ActionMenuPolicy.componentIsDenied("Paste")
               && ActionMenuPolicy.componentIsDenied("Paste and Match Style")
               && ActionMenuPolicy.componentIsDenied("Undo Typing")
               && ActionMenuPolicy.componentIsDenied("Cut")
               && ActionMenuPolicy.componentIsDenied("Redo")
               && ActionMenuPolicy.componentIsDenied("Move to Trash")
               && ActionMenuPolicy.componentIsDenied("Quit Finder")
               && ActionMenuPolicy.componentIsDenied("Send Message"),
               "menu-deny words and the press denylist both refuse a component")
        expect(!ActionMenuPolicy.componentIsDenied("Show Sidebar")
               && !ActionMenuPolicy.componentIsDenied("New Folder")
               && !ActionMenuPolicy.componentIsDenied("Downloads")
               && !ActionMenuPolicy.componentIsDenied("Settings…")
               && !ActionMenuPolicy.componentIsDenied("Picture"),
               "ordinary navigation commands pass (no substring false positive)")
        expect(ActionPlan.Limits.menuDenyWords == ["paste", "cut", "undo", "redo"]
               && ActionPlan.Limits.toggleExemptWords.count == 20
               && ActionPlan.Limits.toggleExemptWords.isSubset(of: [
                   "toggle", "turn", "enable", "disable", "play", "pause",
                   "stop", "start", "resume", "connect", "disconnect",
                   "record", "mute", "lock", "sleep", "save", "close",
                   "quit", "block", "subscribe",
               ]),
               "the two mirrored word lists hold the spec's words")
        expect(ActionMenuPolicy.capturedComponent("  New   Folder ")
                == "New Folder"
               && ActionMenuPolicy.capturedComponent("") == nil
               && ActionMenuPolicy.capturedComponent("—") == nil
               && ActionMenuPolicy.capturedComponent(
                String(repeating: "x", count: 81)) == nil
               && ActionMenuPolicy.capturedComponent("Paste") == nil
               && ActionMenuPolicy.capturedComponent(nil) == nil,
               "captured titles are cleaned, bounded, and policy-checked")

        let bar = semanticMenuBar
        expect(bar.entry(matching: ["view", "SHOW  sidebar"])
                == ["View", "Show Sidebar"]
               && bar.entry(matching: ["Finder", "Settings"])
                == ["Finder", "Settings…"]
               && bar.entry(matching: ["View"]) == nil
               && bar.entry(matching: ["View", "…"]) == nil,
               "menu paths match component-wise normalized, leaf only")
        let duplicated = ActionMenuBar(
            complete: true, top: ["View"],
            items: [["View", "Sidebar"], ["View", "sidebar"]])
        expect(duplicated.entry(matching: ["View", "Sidebar"]) == nil,
               "a path naming two entries resolves to none")
        let near = bar.deepestPrefix(of: ["View", "Hide Toolbar"])
        expect(near.prefix == ["View"]
               && near.children == ["Show Sidebar", "Show Path Bar"],
               "the repair note lists the deepest prefix's children")
        let overlong = bar.deepestPrefix(of: ["View", "Show Sidebar", "More"])
        expect(overlong.prefix == ["View"]
               && overlong.children == ["Show Sidebar", "Show Path Bar"],
               "a path past a leaf lists the leaf's siblings, like the engine")
        let top = bar.deepestPrefix(of: ["Window", "Zoom"])
        expect(top.prefix.isEmpty
               && top.children == ["Finder", "File", "View", "Go"],
               "a missing top-level menu lists the top components")
        expect(ActionPlan.menuPathComponents("View > Show  Sidebar")
                == ["View", "Show Sidebar"]
               && ActionPlan.menuPathComponents("Go › Downloads")
                == ["Go", "Downloads"]
               && ActionPlan.menuPathComponents("File→New Folder")
                == ["File", "New Folder"]
               && ActionPlan.menuPathComponents(["View", "Show Sidebar"])
                == ["View", "Show Sidebar"]
               && ActionPlan.menuPathComponents(["View", 3]) == nil
               && ActionPlan.menuPathComponents(7) == nil,
               "a path is a list or one string split on > › →")
    }

    // MARK: - Cache

    private static func testMenuBarCache() {
        final class Clock { var now: TimeInterval = 1_000 }
        let clock = Clock()
        let lock = NSLock()
        var walks: [(Int, String)] = []
        let queue = DispatchQueue(label: "velora.selftest.menu-cache")
        let bar = ActionMenuBar(
            complete: true, top: ["View"], items: [["View", "Show Sidebar"]])
        let cache = ActionMenuBarCache(
            walk: { pid, bundleID in
                lock.lock()
                walks.append((pid, bundleID))
                lock.unlock()
                return bar
            },
            now: { clock.now }, queue: queue)

        cache.prewarm(pid: 42, bundleID: "com.apple.finder")
        queue.sync {}
        expect(walks.count == 1, "prewarm walks once off-main")
        cache.prewarm(pid: 42, bundleID: "com.apple.finder")
        queue.sync {}
        expect(walks.count == 1, "a fresh entry is not walked again")
        expect(cache.menuBar(pid: 42, bundleID: "com.apple.finder") == bar
               && walks.count == 1,
               "the first observation reads the prewarmed bar")
        expect(cache.menuBar(pid: 42, bundleID: "com.other.app") == nil
               || walks.count == 2,
               "a different bundle at the same pid is never served the old bar")
        queue.sync {}

        var background: ActionMenuBar?
        let done = DispatchSemaphore(value: 0)
        clock.now += ActionMenuBarCache.ttl + 1
        let before = walks.count
        DispatchQueue.global().async {
            background = cache.menuBar(pid: 42, bundleID: "com.apple.finder")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        expect(background == bar && walks.count == before + 1,
               "an expired entry is walked again off the main thread")

        cache.invalidate(pid: 42)
        expect(cache.menuBar(pid: 42, bundleID: "com.apple.finder") == nil,
               "the main thread never walks; an invalidated pid misses")
        queue.sync {}
        expect(walks.count == before + 2
               && cache.menuBar(pid: 42, bundleID: "com.apple.finder") == bar,
               "a main-thread miss prewarms for the next turn")
        expect(cache.menuBar(pid: 0, bundleID: "com.apple.finder") == nil
               && cache.menuBar(pid: 42, bundleID: "") == nil,
               "invalid keys never walk")
    }

    // MARK: - Payload

    private static func testSemanticPayload() {
        let snapshot = semanticSnapshot(
            scope: ActionUIScope(query: "Downloads", matches: 2))
        let payload = snapshot.payload
        let elements = payload["elements"] as? [[String: Any]] ?? []
        expect(elements.count == 6
               && elements[1]["toggle"] as? String == "off"
               && elements[1]["set"] as? [String] == ["on"]
               && elements[2]["expanded"] as? Bool == false
               && elements[2]["set"] as? [String] == ["selected", "expanded"]
               && elements[0]["toggle"] == nil && elements[0]["set"] == nil
               && elements[0]["expanded"] == nil,
               "toggle/expanded/set are emitted only where present")
        let scope = payload["scope"] as? [String: Any]
        expect(scope?["kind"] as? String == "find"
               && scope?["query"] as? String == "Downloads"
               && scope?["matches"] as? Int == 2,
               "a find-scoped snapshot carries its scope")
        let menu = payload["menu_bar"] as? [String: Any]
        let items = menu?["items"] as? [[String: Any]]
        expect(menu?["complete"] as? Bool == true
               && menu?["top"] as? [String] == ["Finder", "File", "View", "Go"]
               && items?.first?["path"] as? [String] == ["Finder", "Settings…"],
               "the menu bar serializes as complete/top/items[path]")
        let plain = semanticSnapshot(menuBar: nil).payload
        expect(plain["scope"] == nil && plain["menu_bar"] == nil,
               "scope and menu_bar are absent unless observed")
        expect(JSONSerialization.isValidJSONObject(payload),
               "the semantic payload is valid JSON")
        let retained = ScreenActionUISnapshot(
            observation: semanticSnapshot(menuBar: nil),
            applicationElement: AXUIElementCreateSystemWide(),
            focusedWindow: AXUIElementCreateSystemWide(),
            elementsByIndex: [:], writeBaselines: [1: "x"])
        let attached = retained.replacingObservation(
            retained.observation.withMenuBar(semanticMenuBar))
        expect(attached.observation.menuBar == semanticMenuBar
               && attached.observation.id == "sem-1"
               && attached.writeBaselines == [1: "x"],
               "attaching the menu bar keeps the retained capabilities")
        let stripped = semanticSnapshot().elements[1].replacing(actions: [])
        expect(stripped.toggle == .off && stripped.settable == [.on]
               && stripped.actions.isEmpty,
               "stripping capabilities keeps semantic state")
    }

    // MARK: - set_ui

    private static func testSetUIDecoding() {
        let wifiOn = """
        \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":1,
         "role":"AXCheckBox","label":"Wi-Fi","state":"on"}
        """
        if case .success(let plan) = decodeSemantic(wifiOn) {
            expect(plan.steps.last == .setUI(
                    snapshotID: "sem-1", index: 1, role: "AXCheckBox",
                    label: "Wi-Fi", state: .on),
                   "set_ui on an offered target state decodes")
        } else {
            expect(false, "set_ui on an offered target state decodes")
        }
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":1,
             "role":"AXCheckBox","label":"Wi-Fi","state":"off"}
            """) == .failure(.invalidStructuredUICapability(step: 1)),
               "a state the element does not list is refused")
        expect(decodeSemantic("""
            {"do":"set_ui","snapshot":"sem-1","index":1,
             "role":"AXCheckBox","label":"Wi-Fi","state":"on"}
            """) == .failure(.inputBeforeFocus(step: 0)),
               "set_ui needs a focus checkpoint")
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":1,
             "role":"AXCheckBox","label":"Wi-Fi","state":"on"},
            \(finderCheckpoint)
            """) == .failure(.pressRequiresFreshObservation(step: 1)),
               "set_ui ends its batch")
        for bad in ["ON", "toggle", "mixed", ""] {
            expect(decodeSemantic("""
                \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1",
                 "index":1,"role":"AXCheckBox","label":"Wi-Fi",
                 "state":"\(bad)"}
                """) == .failure(.missingField(step: 1, field: "state")),
                   "state '\(bad)' is not a wire enum value")
        }
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":1,
             "role":"AXButton","label":"Wi-Fi","state":"on"}
            """) == .failure(.invalidStructuredUICapability(step: 1))
               && decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-0","index":1,
             "role":"AXCheckBox","label":"Wi-Fi","state":"on"}
            """) == .failure(.invalidStructuredUICapability(step: 1)),
               "role and snapshot identity are exact")

        // Toggle exemptions: a switch label names a setting.
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":3,
             "role":"AXCheckBox","label":"Enable notifications","state":"on"}
            """, command: "enable notifications").isSuccess,
               "on/off may name enable/disable settings")
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":4,
             "role":"AXRow","label":"Enable sync","state":"selected"}
            """).isSuccess,
               "selecting a row is navigation: no press denylist")
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":5,
             "role":"AXCheckBox","label":"Send read receipts","state":"on"}
            """) == .failure(.committingPressLabel("Send read receipts")),
               "a non-exempt committing word still refuses on/off")
        expect(!ActionPlan.setLabelIsCommitting("Enable notifications", state: .on)
               && !ActionPlan.setLabelIsCommitting("Turn off Bluetooth", state: .off)
               && ActionPlan.pressLabelIsCommitting("Enable notifications")
               && ActionPlan.setLabelIsCommitting("Delete account", state: .on),
               "the toggle exemption applies to on/off; other commits still refuse")
        expect(!ActionPlan.setLabelIsCommitting("Trash", state: .selected)
               && !ActionPlan.setLabelIsCommitting("Lock Screen", state: .selected)
               && !ActionPlan.setLabelIsCommitting("Wallet & Apple Pay",
                                                    state: .selected)
               && !ActionPlan.setLabelIsCommitting("Archive", state: .expanded),
               "selection and disclosure are navigation: no denylist")

        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":1,
             "role":"AXCheckBox","label":"Wi-Fi","state":"on"}
            """, semanticSnapshot(complete: false))
                == .failure(.incompleteStructuredUI(step: 1)),
               "a partial tree authorizes no set_ui")
        let scoped = semanticSnapshot(
            scope: ActionUIScope(query: "Downloads", matches: 1))
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"set_ui","snapshot":"sem-1","index":2,
             "role":"AXRow","label":"Downloads","state":"selected"}
            """, scoped, command: "open downloads").isSuccess,
               "a complete find-scoped tree authorizes navigation set_ui")

        // Carried state equals press_ui's.
        var seed = semanticState()
        seed.pendingText = true
        seed.pendingValue = "hello"
        seed.pendingIndex = 7
        seed.pendingRole = "AXTextArea"
        seed.pendingLabel = "body"
        let setPlan = ActionPlan(
            goal: "", sends: false,
            steps: [.setUI(snapshotID: "sem-1", index: 1, role: "AXCheckBox",
                           label: "Wi-Fi", state: .on)],
            unsupported: nil)
        let after = ActionPlan.state(after: setPlan, executedCount: 1, seed: seed)
        let pressPlan = ActionPlan(
            goal: "", sends: false,
            steps: [.pressUI(snapshotID: "sem-1", index: 1,
                             role: "AXCheckBox", label: "Wi-Fi")],
            unsupported: nil)
        let pressAfter = ActionPlan.state(
            after: pressPlan, executedCount: 1, seed: seed)
        expect(after.unverifiedText && after.pendingValue.isEmpty
               && after.pendingIndex == nil && after.pendingText
               && after == pressAfter,
               "set_ui carries exactly press_ui's state effect")
        let menuAfter = ActionPlan.state(
            after: ActionPlan(goal: "", sends: false,
                              steps: [.menuItem(snapshotID: "sem-1",
                                                path: ["View", "Show Sidebar"])],
                              unsupported: nil),
            executedCount: 1, seed: seed)
        expect(menuAfter == pressAfter,
               "menu_item carries exactly press_ui's state effect")
        let findAfter = ActionPlan.state(
            after: ActionPlan(goal: "", sends: false,
                              steps: [.findUI("Downloads")], unsupported: nil),
            executedCount: 1, seed: seed)
        expect(findAfter.pendingValue == "hello" && findAfter.pendingIndex == 7
               && !findAfter.unverifiedText,
               "find_ui changes no text or focus state")

        // verify_state on/off. ("Wi-Fi" splits into two short words the
        // shared command-mention rule ignores, so the switch here is
        // "Enable notifications".)
        let onSnapshot = semanticSnapshot(notifications: .on)
        let verifyOn = """
            {"do":"verify_state","snapshot":"sem-1","index":3,
             "role":"AXCheckBox","label":"Enable notifications","assert":"on"}
            """
        expect(decodeSemantic(verifyOn, onSnapshot,
                              command: "enable notifications").isSuccess,
               "verify_state on proves a switch the command names")
        expect(decodeSemantic("""
            {"do":"verify_state","snapshot":"sem-1","index":3,
             "role":"AXCheckBox","label":"Enable notifications","assert":"off"}
            """, onSnapshot, command: "enable notifications")
                == .failure(.invalidStructuredUICapability(step: 0))
               && decodeSemantic(verifyOn, onSnapshot, command: "open downloads")
                == .failure(.invalidStructuredUICapability(step: 0))
               && decodeSemantic(verifyOn, semanticSnapshot(),
                                 command: "enable notifications")
                == .failure(.invalidStructuredUICapability(step: 0)),
               "verify_state on/off needs the current state and a named label")
        expect(decodeSemantic(verifyOn, semanticSnapshot(
                scope: ActionUIScope(query: "notifications", matches: 1),
                notifications: .on), command: "enable notifications")
                .isSuccess,
               "verify_state stays allowed on a complete find-scoped tree")

        // A joined label: the whole of "Wi-Fi" equals "wifi" or "wi fi" in
        // the command, though its words are too short to share.
        let verifyWifi = """
            {"do":"verify_state","snapshot":"sem-1","index":1,
             "role":"AXCheckBox","label":"Wi-Fi","assert":"on"}
            """
        let wifiOnSnapshot = semanticSnapshot(wifi: .on)
        expect(["turn on wi-fi", "turn on wifi", "turn wi fi on"].allSatisfy {
                   decodeSemantic(verifyWifi, wifiOnSnapshot, command: $0)
                       .isSuccess
               },
               "verify_state on names Wi-Fi from wifi / wi-fi / wi fi")
        expect(decodeSemantic(verifyWifi, wifiOnSnapshot,
                              command: "turn on bluetooth")
                == .failure(.invalidStructuredUICapability(step: 0))
               && decodeSemantic(verifyWifi, wifiOnSnapshot,
                                 command: "turn on wifi calling")
                .isSuccess,
               "a joined label still needs the whole label in the command")

        // A plain press on a switch is refused even when it has AXPress:
        // "turn on" an already-on switch would turn it off.
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"press_ui","snapshot":"sem-1","index":1,
             "role":"AXCheckBox","label":"Wi-Fi"}
            """) == .failure(.invalidStructuredUICapability(step: 1)),
               "press_ui on a switch is refused; set_ui sets it")
    }

    // MARK: - menu_item

    private static func testMenuItemDecoding() {
        if case .success(let plan) = decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["View","Show Sidebar"]}
            """, command: "show the sidebar") {
            expect(plan.steps.last == .menuItem(
                    snapshotID: "sem-1", path: ["View", "Show Sidebar"]),
                   "menu_item binds the current snapshot's exact entry")
        } else {
            expect(false, "menu_item on a listed path decodes")
        }
        if case .success(let plan) = decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":"view > show sidebar"}
            """, command: "show the sidebar") {
            expect(plan.steps.last == .menuItem(
                    snapshotID: "sem-1", path: ["View", "Show Sidebar"]),
                   "a string path is split and normalized to the captured titles")
        } else {
            expect(false, "a string menu path decodes")
        }
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["Edit","Paste"]}
            """) == .failure(.committingMenuItem("Paste"))
               && decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["File","Move to Trash"]}
            """) == .failure(.committingMenuItem("Move to Trash")),
               "menu-deny and press-denylist components are refused first")
        let missing = decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["View","Hide Toolbar"]}
            """)
        if case .failure(let error) = missing,
           case .menuItemNotFound(let path, let prefix, let children) = error {
            expect(path == ["View", "Hide Toolbar"] && prefix == ["View"]
                   && children == ["Show Sidebar", "Show Path Bar"]
                   && error.message.contains("under \"View\" the menu has:")
                   && error.message.contains("\"Show Path Bar\"")
                   && error.message.count <= 400,
                   "a missing path names the deepest prefix and its children")
        } else {
            expect(false, "a missing menu path is a repairable PlanError")
        }
        if case .failure(let error) = decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["Window","Zoom"]}
            """), case .menuItemNotFound(_, let prefix, let children) = error {
            expect(prefix.isEmpty && children == ["Finder", "File", "View", "Go"]
                   && error.message.contains("the menu bar has:"),
                   "a missing top menu lists the menu bar")
        } else {
            expect(false, "a missing top menu is a repairable PlanError")
        }
        let tooLong = String(repeating: "x", count: 81)
        for bad in [
            "[]", "[\"A\",\"B\",\"C\",\"D\",\"E\",\"F\"]", "[\"View\",\"\"]",
            "[\"View\",\"\(tooLong)\"]", "[\"View\",3]", "5",
        ] {
            expect(decodeSemantic("""
                \(finderCheckpoint),{"do":"menu_item","path":\(bad)}
                """) == .failure(.invalidMenuPath(step: 1)),
                   "menu path \(bad.prefix(20)) is malformed")
        }
        expect(decodeSemantic("""
            {"do":"menu_item","path":["View","Show Sidebar"]}
            """) == .failure(.inputBeforeFocus(step: 0)),
               "menu_item needs a focus checkpoint")
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["View","Show Sidebar"]},
            \(finderCheckpoint)
            """) == .failure(.pressRequiresFreshObservation(step: 1)),
               "menu_item ends its batch")
        expect(decodeSemantic("""
            {"do":"wait_frontmost","app":"Safari"},
            {"do":"menu_item","path":["View","Show Sidebar"]}
            """) == .failure(.invalidStructuredUICapability(step: 1)),
               "a checkpoint on another app cannot use this app's menu bar")
        let cua = ActionUISnapshot(
            id: "cua-1", source: .cua, appName: "Finder",
            bundleID: "com.apple.finder", windowTitle: "Downloads",
            windowID: 9, complete: true, elements: [],
            menuBar: semanticMenuBar)
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["View","Show Sidebar"]}
            """, cua) == .failure(.invalidStructuredUICapability(step: 1)),
               "menu_item requires a native snapshot")
        if case .failure(let error) = decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["View","Show Sidebar"]}
            """, semanticSnapshot(menuBar: nil)),
           case .menuItemNotFound = error {
            expect(error.message.contains("lists no enabled items"),
                   "no observed menu bar refuses with a repair note")
        } else {
            expect(false, "menu_item without an observed menu bar is refused")
        }
        expect(decodeSemantic("""
            \(finderCheckpoint),{"do":"menu_item","path":["Go","Downloads"]}
            """, semanticSnapshot(complete: false)).isSuccess,
               "menu_item does not depend on window-tree completeness")
    }

    // MARK: - find_ui

    private static func testFindUIDecoding() {
        if case .success(let plan) = decodeSemantic("""
            {"do":"find_ui","text":"  Downloads "}
            """, semanticSnapshot(complete: false)) {
            expect(plan.steps == [.findUI("Downloads")],
                   "find_ui needs no checkpoint and works on a partial tree")
        } else {
            expect(false, "find_ui on a partial native tree decodes")
        }
        for bad in ["ab", "!!!!", String(repeating: "a", count: 61)] {
            expect(decodeSemantic("""
                {"do":"find_ui","text":"\(bad)"}
                """) == .failure(.invalidFindQuery(step: 0)),
                   "find text '\(bad.prefix(8))' is refused")
        }
        expect(decodeSemantic("""
            {"do":"find_ui","text":"Downloads"},\(finderCheckpoint)
            """) == .failure(.findRequiresFreshObservation(step: 0)),
               "find_ui ends its batch")
        let cua = ActionUISnapshot(
            id: "cua-1", source: .cua, appName: "Finder",
            bundleID: "com.apple.finder", windowTitle: "Downloads",
            windowID: 9, complete: false, elements: [])
        expect(decodeSemantic("""
            {"do":"find_ui","text":"Downloads"}
            """, cua) == .failure(.invalidStructuredUICapability(step: 0)),
               "find_ui requires a native snapshot")

        // Find-scoped trees grant navigation only.
        let scoped = ActionUISnapshot(
            id: "find-1", appName: "Notes", bundleID: "com.apple.Notes",
            windowTitle: "My Note", windowID: 9, complete: true,
            elements: [
                ActionUIElement(
                    index: 0, parentIndex: nil, depth: 0, role: "AXWindow",
                    label: "My Note", frame: nil, actions: []),
                ActionUIElement(
                    index: 1, parentIndex: 0, depth: 1, role: "AXTextArea",
                    label: "Body", frame: nil,
                    actions: [ActionUICapability.axFocus], focused: true),
                ActionUIElement(
                    index: 2, parentIndex: 0, depth: 1, role: "AXButton",
                    label: "Body Settings", frame: nil,
                    actions: [ActionUICapability.axPress]),
            ],
            scope: ActionUIScope(query: "Body", matches: 2))
        let unscoped = ActionUISnapshot(
            id: "find-1", appName: "Notes", bundleID: "com.apple.Notes",
            windowTitle: "My Note", windowID: 9, complete: true,
            elements: scoped.elements)
        let typeStep = """
            {"do":"wait_frontmost","app":"Notes"},
            {"do":"type_text","text":"hello","snapshot":"find-1",
             "index":1,"role":"AXTextArea","label":"Body"}
            """
        expect(decodeSemantic(typeStep, unscoped,
                              command: "write hello in Body").isSuccess,
               "the same indexed text step passes on an unscoped tree")
        expect(!decodeSemantic(typeStep, scoped,
                               command: "write hello in Body").isSuccess,
               "a find-scoped tree authorizes no indexed text")
        let pressStep = """
            {"do":"wait_frontmost","app":"Notes"},
            {"do":"press_ui","snapshot":"find-1","index":2,
             "role":"AXButton","label":"Body Settings"}
            """
        expect(decodeSemantic(pressStep, scoped,
                              command: "open body settings").isSuccess,
               "a complete find-scoped tree authorizes press_ui")
        var verifyState = semanticState(scoped, command: "write in Body")
        verifyState.requireUITargetVerification = true
        let verifyJSON = """
            {"sends":false,"steps":[{"do":"wait_frontmost","app":"Notes"},
              {"do":"verify_ui","snapshot":"find-1","index":1,
               "role":"AXTextArea","label":"Body","target":"Body",
               "purpose":"target","attestation":"engine"}]}
            """
        expect(decodeBatch(verifyJSON, state: &verifyState) == nil,
               "a find-scoped tree is never verify_ui evidence")
        var unscopedVerify = semanticState(unscoped, command: "write in Body")
        unscopedVerify.requireUITargetVerification = true
        expect(decodeBatch(verifyJSON, state: &unscopedVerify) != nil,
               "the same verify_ui passes on an unscoped tree")
        expect(ActionUIScope(query: "Body", matches: 2).isFind
               && scoped.isFindScoped && !unscoped.isFindScoped,
               "the find scope is recognized by kind")
    }

    // MARK: - Executor

    private static func testSemanticExecutor() {
        func host() -> FakeActionHost {
            let fake = FakeActionHost()
            fake.frontmost = ("Finder", "com.apple.finder")
            fake.uiSnapshotValue = semanticSnapshot()
            return fake
        }
        let checkpoint = ActionStep.waitFrontmost(app: "Finder", timeoutMs: 1000)
        let setStep = ActionStep.setUI(
            snapshotID: "sem-1", index: 1, role: "AXCheckBox",
            label: "Wi-Fi", state: .on)
        let setPlan = ActionPlan(
            goal: "wifi", sends: false, steps: [checkpoint, setStep],
            unsupported: nil)

        let verified = host()
        verified.setUIResult = .verified
        let verifiedRun = ActionExecutor(host: verified).run(setPlan)
        expect(verifiedRun.outcome == .completed
               && verified.setUICalls.count == 1
               && verified.setUICalls[0].index == 1
               && verified.setUICalls[0].state == .on
               && verifiedRun.evidence.contains(.unverifiedEffect(.setUI))
               && verified.sleepCalls == [ActionExecutor.indexedPressSettleMs]
               && verified.interactionCalls == 1,
               "a verified set_ui is an effect that settles like a press")

        let stale = host()
        stale.setUIResult = .stale
        if case .failed(_, _, let recoverable) =
            ActionExecutor(host: stale).run(setPlan).outcome {
            expect(recoverable, "a stale set_ui asks for a fresh turn")
        } else {
            expect(false, "a stale set_ui fails")
        }

        let unverified = host()
        unverified.setUIResult = .unverified
        if case .failed(_, let reason, let recoverable) =
            ActionExecutor(host: unverified).run(setPlan).outcome {
            expect(!recoverable && reason.contains("could not be verified")
                   && reason.contains("not retried"),
                   "an unverified set_ui ends the action without a retry")
        } else {
            expect(false, "an unverified set_ui fails")
        }

        let menuPlan = ActionPlan(
            goal: "sidebar", sends: false,
            steps: [checkpoint, .menuItem(snapshotID: "sem-1",
                                           path: ["View", "Show Sidebar"])],
            unsupported: nil)
        let menuHost = host()
        menuHost.menuItemResult = true
        let menuRun = ActionExecutor(host: menuHost).run(menuPlan)
        expect(menuRun.outcome == .completed
               && menuHost.menuItemCalls == [["View", "Show Sidebar"]]
               && menuRun.evidence.contains(.unverifiedEffect(.menuItem)),
               "a menu command runs once by exact path")
        let refusedMenu = host()
        if case .failed(_, _, let recoverable) =
            ActionExecutor(host: refusedMenu).run(menuPlan).outcome {
            expect(recoverable && refusedMenu.menuItemCalls.isEmpty,
                   "an unavailable menu command is a recoverable refusal")
        } else {
            expect(false, "an unavailable menu command fails")
        }
        let terminalMenu = host()
        terminalMenu.failureReason = "The menu command was not accepted."
        if case .failed(_, let reason, let recoverable) =
            ActionExecutor(host: terminalMenu).run(menuPlan).outcome {
            expect(!recoverable && reason == "The menu command was not accepted.",
                   "a host's terminal reason ends the action")
        } else {
            expect(false, "a terminal menu failure fails")
        }

        let findPlan = ActionPlan(
            goal: "", sends: false, steps: [.findUI("Downloads")],
            unsupported: nil)
        let finder = host()
        finder.findUIResult = true
        let findRun = ActionExecutor(host: finder).run(findPlan)
        expect(findRun.outcome == .completed
               && finder.findUICalls == ["Downloads"]
               && findRun.evidence.isEmpty
               && finder.interactionCalls == 0,
               "find_ui stores a query and is no effect")
        if case .failed(_, _, let recoverable) =
            ActionExecutor(host: host()).run(findPlan).outcome {
            expect(recoverable, "an unsearchable window is recoverable")
        } else {
            expect(false, "find_ui without a native target fails")
        }
    }

    // MARK: - Background host

    private static func testSemanticBackgroundHost() {
        let system = FakeActionHost()
        system.frontmost = ("Ghostty", "com.mitchellh.ghostty")
        system.foregroundWindowValue = ActionWindowIdentity(
            name: "Ghostty", bundleID: "com.mitchellh.ghostty",
            pid: 700, windowID: 70)
        let transport = FakeCuaTransport()
        scriptNotesWorld(transport)
        let dummy = AXUIElementCreateApplication(
            ProcessInfo.processInfo.processIdentifier)

        var complete = true
        var wifi = ActionToggleState.off
        var generation = 0
        var sets: [(index: Int, state: ActionUISetState)] = []
        var setResult = ActionUISetResult.verified
        var menuPresses: [[String]] = []
        var menuResult = ScreenContext.MenuPressResult.pressed
        var invalidated: [Int] = []
        var finds: [String] = []
        var presses: [Int] = []

        func elements(_ scoped: Bool) -> [ActionUIElement] {
            [
                ActionUIElement(
                    index: 0, parentIndex: nil, depth: 0, role: "AXWindow",
                    label: "My Note",
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                    actions: []),
                ActionUIElement(
                    index: 1, parentIndex: 0, depth: 1, role: "AXCheckBox",
                    label: "Wi-Fi", frame: nil,
                    actions: [ActionUICapability.axPress], toggle: wifi,
                    settable: ActionUISetState.ordered(
                        ActionUISetPolicy.toggleTargets(wifi, hasPress: true))),
                ActionUIElement(
                    index: 2, parentIndex: 0, depth: 1, role: "AXButton",
                    label: scoped ? "Downloads Folder" : "About", frame: nil,
                    actions: [ActionUICapability.axPress]),
                ActionUIElement(
                    index: 3, parentIndex: 0, depth: 1, role: "AXTextArea",
                    label: "Body", frame: nil,
                    actions: [ActionUICapability.axFocus]),
            ]
        }
        func native(scope: ActionUIScope? = nil) -> ScreenActionUISnapshot {
            generation += 1
            let observation = ActionUISnapshot(
                id: "bg-\(generation)", source: .native, appName: "Notes",
                bundleID: "com.apple.Notes", windowTitle: "My Note",
                windowID: 9, complete: scope != nil || complete,
                elements: elements(scope != nil), scope: scope)
            return ScreenActionUISnapshot(
                observation: observation, applicationElement: dummy,
                focusedWindow: dummy,
                elementsByIndex: [0: dummy, 1: dummy, 2: dummy, 3: dummy],
                writeBaselines: [3: ""])
        }

        let host = makeRoutedHost(
            system: system, transport: transport,
            nativeSnapshot: { pid, windowID, _, _ in
                guard pid == 500, windowID == 9 else { return nil }
                return native()
            },
            nativePress: { index, _, _ in
                presses.append(index)
                return true
            },
            nativeFind: { full, query in
                finds.append(query)
                guard full.observation.windowID == 9 else { return nil }
                return native(scope: ActionUIScope(query: query, matches: 1))
            },
            nativeSet: { index, state, _ in
                sets.append((index, state))
                if setResult == .verified { wifi = state == .on ? .on : .off }
                return setResult
            },
            nativeMenuPress: { path, _ in
                menuPresses.append(path)
                return menuResult
            },
            nativeToggle: { index, _ in index == 1 ? wifi : nil },
            menuBar: { pid, bundleID in
                pid == 500 && bundleID == "com.apple.Notes"
                    ? ActionMenuBar(
                        complete: true, top: ["View", "Format"],
                        items: [["View", "Show Folders"],
                                ["Format", "Checklist"]])
                    : nil
            },
            invalidateMenuBar: { invalidated.append($0) })

        host.beginActionInputSession(command: "turn on wi-fi in Notes")
        _ = host.openApp(named: "Notes")
        _ = host.frontmostApp()
        guard let first = host.uiSnapshot() else {
            expect(false, "the semantic native background tree is available")
            return
        }
        expect(first.menuBar?.items.count == 2
               && first.elements[1].toggle == .off
               && first.elements[1].settable == [.on]
               && first.elements[3].actions.isEmpty,
               "background observations keep semantic state and the menu bar")

        expect(host.setElement(
                index: 1, snapshotID: first.id, label: "Wi-Fi",
                role: "AXCheckBox", state: .off,
                expecting: "com.apple.Notes") == .stale
               && sets.isEmpty,
               "a state the element does not offer is refused before acting")
        expect(host.setElement(
                index: 1, snapshotID: first.id, label: "Wi-Fi",
                role: "AXCheckBox", state: .on,
                expecting: "com.apple.Notes") == .verified
               && sets.count == 1 && sets[0].index == 1 && sets[0].state == .on,
               "background set_ui acts on the exact routed element")
        expect(host.setElement(
                index: 1, snapshotID: first.id, label: "Wi-Fi",
                role: "AXCheckBox", state: .on,
                expecting: "com.apple.Notes") == .stale && sets.count == 1,
               "a set invalidates the snapshot it used")
        guard let toggled = host.uiSnapshot() else {
            expect(false, "the toggled tree is re-observed")
            return
        }
        // The app turns the switch back off while the planner thinks.
        wifi = .off
        expect(host.verifyState(
                ActionStateCheck(
                    snapshotID: toggled.id, index: 1, role: "AXCheckBox",
                    label: "Wi-Fi", assertion: .on, expectedValue: nil),
                expecting: "com.apple.Notes") == nil,
               "verify_state on re-reads the switch, not the observation")
        wifi = .on
        expect(host.verifyState(
                ActionStateCheck(
                    snapshotID: toggled.id, index: 1, role: "AXCheckBox",
                    label: "Wi-Fi", assertion: .on, expectedValue: nil),
                expecting: "com.apple.Notes")?.assertion == .on,
               "verify_state on proves the fresh switch state")
        expect(host.verifyState(
                ActionStateCheck(
                    snapshotID: toggled.id, index: 1, role: "AXCheckBox",
                    label: "Wi-Fi", assertion: .off, expectedValue: nil),
                expecting: "com.apple.Notes") == nil,
               "verify_state off refuses a switch that is on")

        expect(!host.pressMenuItem(
                path: ["View", "Hide Folders"], snapshotID: toggled.id,
                expecting: "com.apple.Notes") && menuPresses.isEmpty,
               "an unlisted menu path never reaches the target")
        expect(host.pressMenuItem(
                path: ["view", "show folders"], snapshotID: toggled.id,
                expecting: "com.apple.Notes")
               && menuPresses == [["View", "Show Folders"]]
               && invalidated == [500],
               "a background menu command uses the captured path and "
                   + "invalidates the cache")
        guard let afterMenu = host.uiSnapshot() else {
            expect(false, "the tree is re-observed after a menu command")
            return
        }
        menuResult = .refused
        expect(!host.pressMenuItem(
                path: ["Format", "Checklist"], snapshotID: afterMenu.id,
                expecting: "com.apple.Notes")
               && host.actionFailureReason == nil,
               "a live refusal is recoverable")

        // Busy window: partial native tree, then sticky find scope.
        complete = false
        guard let partial = host.uiSnapshot() else {
            expect(false, "a partial native tree is observed, not dropped")
            return
        }
        expect(partial.source == .native && !partial.complete
               && partial.scope == nil && partial.menuBar != nil,
               "a busy window is returned partial with its menu bar")
        expect(!host.pressElement(
                index: 2, snapshotID: partial.id, label: "About",
                role: "AXButton", expecting: "com.apple.Notes")
               && presses.isEmpty,
               "a partial tree authorizes no background press")
        expect(host.setElement(
                index: 1, snapshotID: partial.id, label: "Wi-Fi",
                role: "AXCheckBox", state: .off,
                expecting: "com.apple.Notes") == .stale,
               "a partial tree authorizes no background set_ui")
        expect(!host.findUI(text: "x", expecting: "com.apple.Notes"),
               "a too-short query stores nothing")
        expect(host.findUI(text: "Downloads", expecting: "com.apple.Notes"),
               "find_ui stores a query for the routed native window")
        guard let scoped = host.uiSnapshot() else {
            expect(false, "the find-scoped tree is observed")
            return
        }
        expect(scoped.isFindScoped && scoped.complete
               && scoped.scope?.query == "Downloads"
               && finds == ["Downloads"] && scoped.menuBar != nil,
               "a partial walk is replaced by the find-scoped walk")
        expect(!host.pressElement(
                index: 2, snapshotID: scoped.id, label: "Downloads Folder",
                role: "AXButton", expecting: "com.apple.Notes")
               && presses.isEmpty,
               "a find-scoped press without a state readback is refused "
                   + "before acting")
        expect(host.typeText(
                "hello",
                target: ActionTextTarget(
                    snapshotID: scoped.id, index: 3, role: "AXTextArea",
                    label: "Body"),
                expecting: "com.apple.Notes") == nil,
               "a find-scoped tree authorizes no background text")
        guard let scopedAgain = host.uiSnapshot() else {
            expect(false, "the find scope is sticky")
            return
        }
        expect(scopedAgain.isFindScoped && finds.count == 2,
               "the find scope stays for later partial observations")
        expect(host.setElement(
                index: 1, snapshotID: scopedAgain.id, label: "Wi-Fi",
                role: "AXCheckBox", state: .off,
                expecting: "com.apple.Notes") == .verified,
               "a complete find-scoped tree authorizes set_ui")

        complete = true
        guard let full = host.uiSnapshot() else {
            expect(false, "a complete walk is observed")
            return
        }
        expect(!full.isFindScoped && full.complete && finds.count == 2,
               "a complete full-window walk is returned as-is")

        complete = false
        setResult = .unverified
        guard let partialAgain = host.uiSnapshot() else {
            expect(false, "the busy window is observed again")
            return
        }
        expect(partialAgain.isFindScoped,
               "the query survives a complete observation of the same window")
        expect(host.setElement(
                index: 1, snapshotID: partialAgain.id, label: "Wi-Fi",
                role: "AXCheckBox", state: .on,
                expecting: "com.apple.Notes") == .unverified
               && host.actionFailureReason?.contains("could not be verified")
                == true,
               "an unverified background set ends the action")

        host.beginActionInputSession(command: "next")
        expect(!host.findUI(text: "Downloads", expecting: "com.apple.Notes")
               || host.actionFailureReason == nil,
               "a new session drops the route and its find query")
        host.endActionInputSession()
    }
}

private extension Result where Failure == ActionPlanError {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
