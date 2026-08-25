import ApplicationServices
import Foundation

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
    /// Generic active-context evidence. A matching label without either flag
    /// can be a sidebar row, search result, or other available destination;
    /// it does not prove that destination is currently open.
    let selected: Bool
    let focused: Bool

    init(
        index: Int,
        parentIndex: Int?,
        depth: Int,
        role: String,
        label: String?,
        frame: CGRect?,
        actions: [String],
        selected: Bool = false,
        focused: Bool = false
    ) {
        self.index = index
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.label = label
        self.frame = frame
        self.actions = actions
        self.selected = selected
        self.focused = focused
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
        // Omit false flags from the prompt payload. Their absence means the
        // element is not active and avoids two low-value tokens per node.
        if selected { out["selected"] = true }
        if focused { out["focused"] = true }
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

    static func mayVerify(index: Int, in elements: [ActionUIElement]) -> Bool {
        guard elements.contains(where: { $0.index == index }) else { return false }
        return !isRepeatedCollectionMember(index: index, in: elements)
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
    let appName: String
    let bundleID: String
    let windowTitle: String
    let complete: Bool
    let elements: [ActionUIElement]

    var payload: [String: Any] {
        [
            "id": id,
            "app_name": appName,
            "bundle_id": bundleID,
            "window_title": windowTitle,
            "complete": complete,
            "elements": elements.map(\.payload),
        ]
    }
}

/// A snapshot plus the local capabilities it describes. AX references never
/// cross the process boundary and are invalidated after any UI-changing step.
struct ScreenActionUISnapshot {
    let observation: ActionUISnapshot
    let applicationElement: AXUIElement
    let elementsByIndex: [Int: AXUIElement]
}
