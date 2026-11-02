// Test harness: compiled out of the DMG build (VELORA_DISTRIBUTION; see
// main.swift). Production code must not reference anything in Selftest/.
#if !VELORA_DISTRIBUTION
import AppKit
import ApplicationServices
import Foundation

/// Read-only Accessibility survey of the apps running right now:
/// `open -n build/Velora.app --args --action-probe <out.json>`.
///
/// Action Mode's limits are properties of the target apps (tree size, which
/// attributes are settable, whether a background app's menu bar is readable),
/// so design decisions need numbers from real apps, not from fixtures. The
/// probe only reads attributes and asks whether they are settable. It never
/// performs an AX action, writes a value, activates an app, or moves focus.
/// Launch it through LaunchServices so the signed bundle's own Accessibility
/// grant applies rather than the terminal's.
enum ActionAXProbe {
    static func run(arguments: [String]) -> Int32 {
        guard let output = arguments.first else {
            print("usage: Velora --action-probe <out.json>")
            return EX_USAGE
        }
        guard AXIsProcessTrusted() else {
            write(["error": "accessibility_not_granted"], to: output)
            return 1
        }
        let me = ProcessInfo.processInfo.processIdentifier
        var apps: [[String: Any]] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier > 0
            && app.processIdentifier != me {
            apps.append(survey(app))
        }
        var result: [String: Any] = [
            "apps": apps,
            "generated": ISO8601DateFormatter().string(from: Date()),
        ]
        // VELORA_PROBE_DUMP=<bundle id>: every node of that app's focused
        // window with its role, the AX error when the role read fails, and
        // the attribute names it does expose. Read-only.
        if let bundle = ProcessInfo.processInfo.environment["VELORA_PROBE_DUMP"],
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundle
           }) {
            result["dump"] = dump(app)
        }
        // VELORA_PROBE_SNAPSHOT=<bundle id>: the production snapshot exactly
        // as the engine receives it (indices, labels, toggle/set, complete).
        if let bundle = ProcessInfo.processInfo.environment["VELORA_PROBE_SNAPSHOT"],
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundle
           }),
           let production = ScreenContext.actionUISnapshot(of: app) {
            result["snapshot"] = production.observation.payload
        }
        write(result, to: output)
        return 0
    }

    private static func dump(_ app: NSRunningApplication) -> [[String: Any]] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &ref)
                == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return [["error": "no focused window"]] }
        var queue: [(AXUIElement, Int, Int?)] = [(ref as! AXUIElement, 0, nil)]
        var out: [[String: Any]] = []
        var head = 0
        while head < queue.count, out.count < 700 {
            let (node, depth, parent) = queue[head]
            head += 1
            AXUIElementSetMessagingTimeout(node, 1.0)
            var roleRef: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(
                node, kAXRoleAttribute as CFString, &roleRef)
            var row: [String: Any] = [
                "i": out.count, "depth": depth, "parent": parent ?? -1,
                "role": (roleRef as? String) ?? "?",
            ]
            if roleError != .success { row["role_error"] = roleError.rawValue }
            for (key, attr) in [("subrole", kAXSubroleAttribute),
                                ("title", kAXTitleAttribute),
                                ("desc", kAXDescriptionAttribute),
                                ("id", kAXIdentifierAttribute)] {
                if let value = string(node, attr), !value.isEmpty {
                    row[key] = String(value.prefix(60))
                }
            }
            var names: CFArray?
            if AXUIElementCopyAttributeNames(node, &names) == .success,
               let list = names as? [String] {
                if roleError != .success || (roleRef as? String) == nil {
                    row["attrs"] = list
                }
                row["n_attrs"] = list.count
            }
            var actions: CFArray?
            if AXUIElementCopyActionNames(node, &actions) == .success,
               let list = actions as? [String], !list.isEmpty {
                row["actions"] = list
            }
            if let value = number(node, kAXValueAttribute) {
                row["value_number"] = value
            }
            if (roleRef as? String) == kAXStaticTextRole as String,
               let value = string(node, kAXValueAttribute) {
                row["value"] = String(value.prefix(60))
            }
            let children = elements(node, kAXChildrenAttribute)
            row["children"] = children.count
            out.append(row)
            if depth < 14 {
                queue.append(contentsOf: children.map {
                    ($0, depth + 1, out.count - 1)
                })
            }
        }
        return out
    }


    /// What the production snapshot offers set_ui, and a find walk's cost.
    /// The query comes from VELORA_PROBE_FIND (default "settings").
    private static func semantic(
        _ snapshot: ScreenActionUISnapshot
    ) -> [String: Any] {
        let elements = snapshot.observation.elements
        let rows = elements.filter { $0.role == "AXRow" }
        var out: [String: Any] = [
            "rows": rows.count,
            "rows_labelled": rows.filter { $0.label != nil }.count,
            "rows_settable": rows.filter { !$0.settable.isEmpty }.count,
            "toggles": elements.filter { $0.toggle != nil }.count,
            "expandable": elements.filter { $0.expanded != nil }.count,
            "settable": elements.filter { !$0.settable.isEmpty }.count,
            "samples": elements.filter { !$0.settable.isEmpty }.prefix(8).map {
                "\($0.role) \($0.label ?? "") set="
                    + $0.settable.map(\.rawValue).joined(separator: ",")
            },
        ]
        let query = ProcessInfo.processInfo.environment["VELORA_PROBE_FIND"]
            ?? "settings"
        let started = Date()
        let found = ScreenContext.findActionUISnapshot(
            scopedTo: snapshot, query: query)
        out["find"] = [
            "query": query,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
            "elements": found?.observation.elements.count ?? -1,
            "matches": found?.observation.scope?.matches ?? -1,
            "complete": found?.observation.complete ?? false,
        ] as [String: Any]
        return out
    }

    private static func survey(_ app: NSRunningApplication) -> [String: Any] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        var out: [String: Any] = [
            "name": app.localizedName ?? "",
            "bundle": app.bundleIdentifier ?? "",
            "active": app.isActive,
            "windows": elements(appElement, kAXWindowsAttribute).count,
        ]

        let started = Date()
        let production = ScreenContext.actionUISnapshot(of: app)
        out["production"] = [
            "ms": Int(Date().timeIntervalSince(started) * 1000),
            "elements": production?.observation.elements.count ?? -1,
            "complete": production?.observation.complete ?? false,
        ] as [String: Any]
        if let production {
            out["semantic"] = semantic(production)
        }
        let menuStarted = Date()
        let bar = app.bundleIdentifier.flatMap {
            ScreenContext.actionMenuBar(
                pid: Int(pid), bundleID: $0)
        }
        out["production_menu_bar"] = [
            "ms": Int(Date().timeIntervalSince(menuStarted) * 1000),
            "complete": bar?.complete ?? false,
            "top": bar?.top ?? [],
            "items": bar?.items.count ?? -1,
            "samples": (bar?.items.prefix(8) ?? []).map {
                $0.joined(separator: " > ")
            },
        ] as [String: Any]

        if let window = element(appElement, kAXFocusedWindowAttribute)
            ?? element(appElement, kAXMainWindowAttribute)
            ?? elements(appElement, kAXWindowsAttribute).first {
            out["tree"] = walk(window)
            out["row_samples"] = rowSamples(window)
        }
        out["menu_bar"] = menuBar(appElement)
        return out
    }

    /// Measures the whole window (up to 6000 nodes / 4 s) and records where
    /// the production limits (500 nodes, depth 128) would cut, and which
    /// parents are wide (the 60-children count is kept as a statistic).
    private static func walk(_ window: AXUIElement) -> [String: Any] {
        let stopAt = Date().addingTimeInterval(4)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        var nodes = 0
        var maxDepth = 0
        var maxChildren = 0
        var wideParents = 0
        var budgetDepth: Int?
        var roles: [String: Int] = [:]
        var rows = 0, rowSelectedSettable = 0, rowDisclosing = 0,
            rowDisclosingSettable = 0, rowPress = 0
        var tableSelectedRowsSettable = 0, tables = 0
        var toggles = 0, toggleNumeric = 0, switches = 0
        var popups = 0, disclosureTriangles = 0, sliders = 0,
            sliderSettable = 0, tabs = 0
        var passthrough = 0, inertLeaves = 0, valueOnlyText = 0
        let started = Date()
        while head < queue.count, nodes < 6000, Date() < stopAt {
            let (node, depth) = queue[head]
            head += 1
            nodes += 1
            if nodes == 501, budgetDepth == nil { budgetDepth = depth }
            AXUIElementSetMessagingTimeout(node, 0.2)
            maxDepth = max(maxDepth, depth)
            let role = string(node, kAXRoleAttribute) ?? "?"
            roles[role, default: 0] += 1
            let actions = actionNames(node)
            switch role {
            case "AXRow":
                rows += 1
                if settable(node, kAXSelectedAttribute) { rowSelectedSettable += 1 }
                if bool(node, kAXDisclosingAttribute) != nil { rowDisclosing += 1 }
                if settable(node, kAXDisclosingAttribute) { rowDisclosingSettable += 1 }
                if actions.contains(kAXPressAction as String) { rowPress += 1 }
            case "AXTable", "AXOutline", "AXList":
                tables += 1
                if settable(node, kAXSelectedRowsAttribute)
                    || settable(node, kAXSelectedChildrenAttribute) {
                    tableSelectedRowsSettable += 1
                }
            case "AXCheckBox":
                toggles += 1
                if number(node, kAXValueAttribute) != nil { toggleNumeric += 1 }
                if string(node, kAXSubroleAttribute) == "AXSwitch" { switches += 1 }
            case "AXPopUpButton", "AXMenuButton": popups += 1
            case "AXDisclosureTriangle": disclosureTriangles += 1
            case "AXSlider":
                sliders += 1
                if settable(node, kAXValueAttribute) { sliderSettable += 1 }
            case "AXRadioButton", "AXTab": tabs += 1
            default: break
            }
            let children = elements(node, kAXChildrenAttribute)
            let authored = [kAXTitleAttribute, kAXDescriptionAttribute]
                .compactMap { string(node, $0) }
                .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !authored, actions.isEmpty {
                if children.count == 1 { passthrough += 1 }
                if children.isEmpty { inertLeaves += 1 }
                if children.isEmpty, role == "AXStaticText",
                   let text = string(node, kAXValueAttribute), !text.isEmpty {
                    valueOnlyText += 1
                }
            }
            maxChildren = max(maxChildren, children.count)
            if children.count > 60 { wideParents += 1 }
            for child in children { queue.append((child, depth + 1)) }
        }
        let topRoles = roles.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)=\($0.value)" }
        return [
            "nodes_walked": nodes,
            "exhausted": head >= queue.count,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
            "max_depth": maxDepth,
            "max_children": maxChildren,
            "parents_over_60_children": wideParents,
            "depth_at_node_500": budgetDepth ?? -1,
            "top_roles": topRoles,
            "rows": rows, "row_selected_settable": rowSelectedSettable,
            "row_disclosing": rowDisclosing,
            "row_disclosing_settable": rowDisclosingSettable,
            "row_press": rowPress,
            "lists": tables, "list_selection_settable": tableSelectedRowsSettable,
            "checkboxes": toggles, "checkbox_numeric": toggleNumeric,
            "switches": switches, "popups": popups,
            "disclosure_triangles": disclosureTriangles,
            "sliders": sliders, "slider_settable": sliderSettable,
            "tabs_radios": tabs,
            "unlabeled_single_child": passthrough,
            "unlabeled_inert_leaves": inertLeaves,
            "static_text_value_only": valueOnlyText,
        ]
    }

    /// The first rows' own and descendant labels: which attribute carries the
    /// visible name a person would say ("Downloads", "Bluetooth").
    private static func rowSamples(_ window: AXUIElement) -> [[String: Any]] {
        var queue: [AXUIElement] = [window]
        var head = 0
        var samples: [[String: Any]] = []
        while head < queue.count, head < 3000, samples.count < 4 {
            let node = queue[head]
            head += 1
            if string(node, kAXRoleAttribute) == "AXRow" {
                samples.append(describe(node, depth: 0))
                continue
            }
            queue.append(contentsOf: elements(node, kAXChildrenAttribute))
        }
        return samples
    }

    private static func describe(_ node: AXUIElement, depth: Int) -> [String: Any] {
        var out: [String: Any] = ["role": string(node, kAXRoleAttribute) ?? "?"]
        for (key, attr) in [("subrole", kAXSubroleAttribute),
                            ("title", kAXTitleAttribute),
                            ("desc", kAXDescriptionAttribute)] {
            if let text = string(node, attr), !text.isEmpty {
                out[key] = String(text.prefix(40))
            }
        }
        if let text = string(node, kAXValueAttribute), !text.isEmpty {
            out["value_len"] = text.count
            out["value_is_short"] = text.count <= 40
        }
        if depth < 3 {
            let children = elements(node, kAXChildrenAttribute).prefix(4)
            if !children.isEmpty {
                out["children"] = children.map { describe($0, depth: depth + 1) }
            }
        }
        return out
    }

    private static func menuBar(_ appElement: AXUIElement) -> [String: Any] {
        guard let bar = element(appElement, kAXMenuBarAttribute) else {
            return ["present": false]
        }
        let started = Date()
        var titles: [String] = []
        var items = 0, leaves = 0, enabledLeaves = 0, withShortcut = 0
        var maxDepth = 0
        var samples: [String] = []
        func visit(_ menu: AXUIElement, path: [String], depth: Int) {
            maxDepth = max(maxDepth, depth)
            for item in elements(menu, kAXChildrenAttribute) {
                AXUIElementSetMessagingTimeout(item, 0.2)
                let title = string(item, kAXTitleAttribute) ?? ""
                if title.isEmpty { continue }
                items += 1
                let submenus = elements(item, kAXChildrenAttribute).filter {
                    string($0, kAXRoleAttribute) == "AXMenu"
                }
                if let submenu = submenus.first, depth < 5 {
                    visit(submenu, path: path + [title], depth: depth + 1)
                } else {
                    leaves += 1
                    if bool(item, kAXEnabledAttribute) != false { enabledLeaves += 1 }
                    if string(item, kAXMenuItemCmdCharAttribute) != nil {
                        withShortcut += 1
                    }
                    if samples.count < 12 {
                        samples.append((path + [title]).joined(separator: " > "))
                    }
                }
                if Date().timeIntervalSince(started) > 3 { return }
            }
        }
        for (offset, top) in elements(bar, kAXChildrenAttribute).enumerated() {
            AXUIElementSetMessagingTimeout(top, 0.2)
            let title = string(top, kAXTitleAttribute) ?? ""
            titles.append(title)
            if let menu = elements(top, kAXChildrenAttribute).first {
                visit(menu, path: [offset == 0 ? "<apple>" : title], depth: 1)
            }
        }
        return [
            "present": true,
            "top": titles,
            "items": items, "leaves": leaves, "enabled_leaves": enabledLeaves,
            "with_shortcut": withShortcut, "max_depth": maxDepth,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
            "samples": samples,
        ]
    }

    // MARK: - read-only AX helpers

    private static func value(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attr as CFString, &out) == .success else { return nil }
        return out
    }

    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let raw = value(el, attr),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let raw = value(el, attr) as? [AnyObject] else { return [] }
        return raw.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let raw = value(el, attr) else { return nil }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((raw as! CFBoolean))
        }
        return (raw as? NSNumber)?.boolValue
    }

    private static func number(_ el: AXUIElement, _ attr: String) -> Double? {
        (value(el, attr) as? NSNumber)?.doubleValue
    }

    private static func settable(_ el: AXUIElement, _ attr: String) -> Bool {
        var flag = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            el, attr as CFString, &flag) == .success && flag.boolValue
    }

    private static func actionNames(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    private static func write(_ object: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
#endif
