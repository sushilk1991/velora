import ApplicationServices
import Foundation

enum ActionUICapability {
    static let axFocus = "AXFocus"
    static let axPress = kAXPressAction as String
    static let cuaClick = "CuaClick"
}

enum ActionUISnapshotSource: String {
    case native
    case cua
    case appNative = "app_native"
}

enum ActionNativeCapabilityVerb: String {
    case mediaControl = "media_control"
}

/// An opaque, single-use automation authority. The planner sees only what the
/// capability does; provider identity and target binding remain in Swift.
struct ActionNativeCapability: Equatable {
    let id: String
    let verb: ActionNativeCapabilityVerb
    let state: ActionMediaState

    var payload: [String: Any] {
        [
            "id": id,
            "source": ActionUISnapshotSource.appNative.rawValue,
            "do": verb.rawValue,
            "state": state.rawValue,
        ]
    }
}

/// Framework-neutral UI evidence passed across the Swift/engine boundary.
/// The model reasons over these records; only the Swift host retains the
/// corresponding AXUIElement references and therefore the authority to act.
struct ActionUIElement: Equatable {
    let index: Int
    let parentIndex: Int?
    let depth: Int
    let role: String
    let label: String?
    let frame: CGRect?
    let actions: [String]
    let enabled: Bool
    /// Generic active-context evidence. A matching label without either flag
    /// can be a sidebar row, search result, or other available destination;
    /// it does not prove that destination is currently open.
    let selected: Bool
    let focused: Bool
    let inWebContent: Bool

    init(
        index: Int,
        parentIndex: Int?,
        depth: Int,
        role: String,
        label: String?,
        frame: CGRect?,
        actions: [String],
        enabled: Bool = true,
        selected: Bool = false,
        focused: Bool = false,
        inWebContent: Bool = false
    ) {
        self.index = index
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.label = label
        self.frame = frame
        self.actions = actions
        self.enabled = enabled
        self.selected = selected
        self.focused = focused
        self.inWebContent = inWebContent
    }

    var payload: [String: Any] {
        var out: [String: Any] = [
            "index": index,
            "depth": depth,
            "role": role,
        ]
        if let parentIndex { out["parent_index"] = parentIndex }
        if let label, !label.isEmpty { out["label"] = label }
        if let frame,
           frame.origin.x.isFinite, frame.origin.y.isFinite,
           frame.size.width.isFinite, frame.size.height.isFinite {
            out["frame"] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "w": frame.size.width,
                "h": frame.size.height,
            ]
        }
        if !actions.isEmpty { out["actions"] = actions }
        if !enabled { out["enabled"] = false }
        // Omit false flags from the prompt payload. Their absence means the
        // element is not active and avoids two low-value tokens per node.
        if selected { out["selected"] = true }
        if focused { out["focused"] = true }
        if inWebContent { out["in_web_content"] = true }
        return out
    }
}

/// Generic evidence policy shared by completion and recipient verification.
///
/// A destination row may be selected/focused while the requested content is
/// still closed (sidebar, quick switcher, command palette). Repeated peer
/// collections remain valid navigation capabilities, but never proof. Unique
/// target-bound content such as a conversation header or composer remains
/// admissible without any app name, bundle id, or per-app role table.
enum ActionUIEvidencePolicy {
    // collection_evidence_policy: minimumPeers=4 ancestorLevels=4 frameTolerance=3
    static let minimumPeers = 4
    static let ancestorLevels = 4
    static let frameTolerance: CGFloat = 3
    private static let editableRoles: Set<String> = [
        "AXComboBox", "AXSearchField", "AXTextArea", "AXTextField",
    ]

    static func mayVerify(index: Int, in elements: [ActionUIElement]) -> Bool {
        guard elements.contains(where: { $0.index == index }) else { return false }
        return !isRepeatedCollectionMember(index: index, in: elements)
    }

    /// Goal evidence must describe active state or inert content, never the
    /// unchanged actuator that caused navigation or one of its child labels.
    static func mayVerifyGoal(
        index: Int, source: ActionUISnapshotSource,
        in elements: [ActionUIElement]
    ) -> Bool {
        guard mayVerify(index: index, in: elements),
              let element = elements.first(where: { $0.index == index })
        else { return false }
        guard source != .appNative else { return false }
        if element.selected { return true }
        if element.focused && editableRoles.contains(element.role) { return true }
        return hasInertPath(index: index, in: elements)
    }

    private static func hasInertPath(
        index: Int, in elements: [ActionUIElement]
    ) -> Bool {
        let byIndex = Dictionary(uniqueKeysWithValues: elements.map { ($0.index, $0) })
        guard var element = byIndex[index] else { return false }
        var visited: Set<Int> = []

        while true {
            guard !visited.contains(element.index), element.actions.isEmpty else {
                return false
            }
            visited.insert(element.index)
            guard let parent = element.parentIndex else { return true }
            guard let ancestor = byIndex[parent] else { return false }
            element = ancestor
        }
    }

    static func isRepeatedCollectionMember(
        index: Int,
        in elements: [ActionUIElement]
    ) -> Bool {
        let byIndex = Dictionary(uniqueKeysWithValues: elements.map { ($0.index, $0) })
        var children: [Int: [ActionUIElement]] = [:]
        for element in elements {
            if let parent = element.parentIndex {
                children[parent, default: []].append(element)
            }
        }
        guard var candidate = byIndex[index] else { return true }

        for _ in 0..<ancestorLevels {
            guard let parent = candidate.parentIndex,
                  let siblings = children[parent] else { break }
            let labelledPeers = siblings.filter { peer in
                guard let label = peer.label,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return false }
                return peerMatches(candidate, peer)
            }
            if labelledPeers.count >= minimumPeers { return true }
            guard let ancestor = byIndex[parent] else { break }
            candidate = ancestor
        }
        return false
    }

    private static func peerMatches(
        _ candidate: ActionUIElement,
        _ peer: ActionUIElement
    ) -> Bool {
        guard let first = candidate.frame, let second = peer.frame,
              first.width > 1, first.height > 1,
              second.width > 1, second.height > 1 else {
            // Frame-less Electron rows still expose repeated roles. Refusing
            // proof is the safe direction when geometry is unavailable.
            return candidate.role == peer.role
        }
        let verticalList = abs(first.minX - second.minX) <= frameTolerance
            && abs(first.width - second.width) <= frameTolerance
        let horizontalStrip = abs(first.minY - second.minY) <= frameTolerance
            && abs(first.height - second.height) <= frameTolerance
        return verticalList || horizontalStrip
    }
}

struct ActionUISnapshot: Equatable {
    let id: String
    let source: ActionUISnapshotSource
    let appName: String
    let bundleID: String
    let windowTitle: String
    let windowID: Int?
    let complete: Bool
    let elements: [ActionUIElement]
    let capabilities: [ActionNativeCapability]

    init(id: String, source: ActionUISnapshotSource = .native,
         appName: String, bundleID: String,
         windowTitle: String, windowID: Int? = nil, complete: Bool,
         elements: [ActionUIElement],
         capabilities: [ActionNativeCapability] = []) {
        self.id = id
        self.source = source
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.complete = complete
        self.elements = elements
        self.capabilities = capabilities
    }

    var payload: [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "source": source.rawValue,
            "app_name": appName,
            "bundle_id": bundleID,
            "window_title": windowTitle,
            "complete": complete,
            "elements": elements.map(\.payload),
        ]
        if !capabilities.isEmpty {
            out["capabilities"] = capabilities.map(\.payload)
        }
        if let windowID { out["window_id"] = windowID }
        return out
    }

    func addingCapabilities(
        _ values: [ActionNativeCapability]
    ) -> ActionUISnapshot {
        ActionUISnapshot(
            id: id, source: source, appName: appName, bundleID: bundleID,
            windowTitle: windowTitle, windowID: windowID, complete: complete,
            elements: elements, capabilities: values)
    }
}

/// A snapshot plus the local capabilities it describes. AX references never
/// cross the process boundary and are invalidated after any UI-changing step.
struct ScreenActionUISnapshot {
    let observation: ActionUISnapshot
    let applicationElement: AXUIElement
    let focusedWindow: AXUIElement
    let elementsByIndex: [Int: AXUIElement]
}
