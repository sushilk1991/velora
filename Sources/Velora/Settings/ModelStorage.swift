import Foundation

/// Inspects and prunes the on-disk HuggingFace model cache
/// (`~/.cache/huggingface/hub`). Lets Settings show where the disk went
/// (the "why is it 15 GB?" question) and reclaim space from models Velora
/// downloaded but no longer uses. Every model here is re-downloadable, so
/// deletion is recoverable — but we still confirm before removing.
enum ModelStorage {
    /// One cached model snapshot on disk.
    struct CachedModel: Identifiable, Equatable {
        let id: String  // repo id, e.g. "mlx-community/whisper-large-v3-turbo"
        let directory: URL
        let bytes: Int64

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    static var hubURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// `models--mlx-community--whisper-large-v3-turbo` → `mlx-community/whisper-large-v3-turbo`.
    /// The org and repo can themselves contain single dashes, so only the
    /// `--` separators are turned back into `/`.
    static func repoID(fromDirName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let body = String(name.dropFirst("models--".count))
        return body.components(separatedBy: "--").joined(separator: "/")
    }

    /// Enumerates cached models with their on-disk size, largest first.
    /// Runs off the main thread (directory walks can be slow).
    static func scan() async -> [CachedModel] {
        let hub = hubURL
        return await Task.detached(priority: .utility) { () -> [CachedModel] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: hub, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return [] }
            var models: [CachedModel] = []
            for entry in entries {
                let name = entry.lastPathComponent
                guard let id = repoID(fromDirName: name) else { continue }
                let bytes = directorySize(entry, fm: fm)
                models.append(CachedModel(id: id, directory: entry, bytes: bytes))
            }
            return models.sorted { $0.bytes > $1.bytes }
        }.value
    }

    /// Deletes one cached model snapshot (off the caller's thread — a multi-GB
    /// snapshot has hundreds of blob files). Returns true on success.
    @discardableResult
    static func delete(_ model: CachedModel) async -> Bool {
        let dir = model.directory.standardizedFileURL
        // Defense in depth: the target must be a direct `models--…` child of the
        // hub, so a crafted path can never walk up and remove the whole cache.
        guard dir.deletingLastPathComponent().standardizedFileURL == hubURL.standardizedFileURL,
              dir.lastPathComponent.hasPrefix("models--")
        else { return false }
        return await Task.detached(priority: .utility) { () -> Bool in
            do {
                try FileManager.default.removeItem(at: dir)
                return true
            } catch {
                NSLog("Velora: failed to delete model cache \(model.id): \(error)")
                return false
            }
        }.value
    }

    private static func directorySize(_ url: URL, fm: FileManager) -> Int64 {
        guard let files = fm.enumerator(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        while let file = files.nextObject() as? String {
            let attrs = try? fm.attributesOfItem(atPath: url.path + "/" + file)
            total += (attrs?[.size] as? Int64) ?? 0
        }
        return total
    }
}
