import CryptoKit
import Foundation

// Downloads are measured, never removed here: only the engine can exclude all acquisition jobs.
enum ModelStorage {
    struct CachedModel: Identifiable, Equatable {
        let id: String
        let directory: URL
        let bytes: Int64
        var engineManaged: Bool = false
    }

    // Direct cache removal cannot exclude concurrent startup, History or meeting acquisition.
    static let removalAvailable = true

    static var hubURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    static func repoID(fromDirName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        return String(name.dropFirst("models--".count))
            .components(separatedBy: "--").joined(separator: "/")
    }

    static func ownedKey(_ model: String) -> String {
        SHA256.hash(data: Data(model.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func scan() async -> [CachedModel] {
        let hub = hubURL
        let home = AppConfig.veloraDirectory
        return await Task.detached(priority: .utility) { scan(at: hub, modelHome: home) }.value
    }

    // File device/inode identity counts hardlinks once; symlinked snapshots do not recount blobs.
    static func scan(at hub: URL, modelHome: URL? = nil) -> [CachedModel] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: hub, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        var models: [CachedModel] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard let id = repoID(fromDirName: entry.lastPathComponent), isDirectory(entry) else { continue }
            models.append(CachedModel(id: id, directory: entry,
                                      bytes: directorySize(entry, seen: &seen)))
        }
        let owned = hub.appendingPathComponent(".velora-downloads")
        let bases = (try? fm.contentsOfDirectory(at: owned, includingPropertiesForKeys: nil)) ?? []
        for base in bases.sorted(by: { $0.path < $1.path }) {
            guard isDirectory(base) else { continue }
            let id = ownedModel(base) ?? "Engine-managed \(base.lastPathComponent)"
            models.append(CachedModel(id: id, directory: base,
                                      bytes: directorySize(base, seen: &seen), engineManaged: true))
        }
        if let modelHome {
            let roots = ["quant-cache", "bark-cache", "bark-coreml-cache", "bundled-models"]
            for name in roots {
                let root = modelHome.appendingPathComponent(name)
                guard isDirectory(root) else { continue }
                let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                for child in children where isDirectory(child) {
                    let markers = ["velora-quant.json", "velora-bark.json",
                                   "velora-bark-coreml.json", "velora-bundled-import.json"]
                    for marker in markers {
                        let file = child.appendingPathComponent(marker)
                        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
                              let data = try? Data(contentsOf: file),
                              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        else { continue }
                        let identity = document["identity"] as? [String: Any] ?? document
                        guard let baseID = identity["model_id"] as? String ?? identity["repo"] as? String else { continue }
                        let variant = identity["variant"] as? String ?? identity["key"] as? String ?? ""
                        let id = variant.hasSuffix("-ane") ? baseID + ":coreml-ane" : baseID
                        models.append(CachedModel(
                            id: id, directory: child, bytes: directorySize(child, seen: &seen),
                            engineManaged: true))
                        break
                    }
                }
            }
        }
        // One row per identity, including the source and all derived caches.
        // The directory points at owned storage when removal is supported.
        var grouped: [String: CachedModel] = [:]
        for item in models {
            if let previous = grouped[item.id] {
                grouped[item.id] = CachedModel(
                    id: item.id, directory: item.engineManaged ? item.directory : previous.directory,
                    bytes: previous.bytes + item.bytes,
                    engineManaged: previous.engineManaged || item.engineManaged)
            } else {
                grouped[item.id] = item
            }
        }
        return grouped.values.sorted { $0.bytes > $1.bytes }
    }

    static func canRemove(_ model: CachedModel, protected: Set<String>) -> Bool {
        removalAvailable && model.engineManaged && !protected.contains(model.id)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func ownedModel(_ base: URL) -> String? {
        let manifests = base.appendingPathComponent("manifests")
        guard isDirectory(manifests) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: manifests, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false,
                  let data = try? Data(contentsOf: file),
                  let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let model = value["model"] as? String,
                  ownedKey(model) == base.lastPathComponent else { continue }
            return model
        }
        return nil
    }

    private static func directorySize(_ url: URL, seen: inout Set<String>) -> Int64 {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let inode = attrs[.systemFileNumber] as? NSNumber,
                  let device = attrs[.systemNumber] as? NSNumber,
                  seen.insert("\(device):\(inode)").inserted else { continue }
            total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}
