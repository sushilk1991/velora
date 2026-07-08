import Foundation

/// Manages `~/.velora/auto_learned.json` — the vocabulary the ENGINE's idle
/// miner extracts from dictation history (smartness-v2 §4). The engine owns the
/// file and all mining bookkeeping (`checkpoint_id`, candidate counts); the app
/// only performs the user-facing management actions: list the active terms,
/// delete one, delete all. Deleted terms are appended to `banned` so the miner
/// never re-learns them.
///
/// Writes are surgical: the JSON is read as a plain dictionary and only the
/// keys the user's action owns (`terms`, `candidates`, `banned`) are replaced —
/// `version`, `checkpoint_id`, and any future engine-side keys pass through
/// untouched, so an app older than the engine can't corrupt its state.
/// All access is main-actor (called from SettingsModel), like LearningStore.
final class AutoVocabStore {
    private let url: URL
    /// Bound on the ban list so repeated deletes can't grow the file without
    /// limit; the oldest bans fall off first (the miner has long since
    /// checkpointed past the history rows that produced them).
    private static let maxBanned = 500

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/auto_learned.json")
    }

    /// Active auto-learned terms, alphabetized for display. Reads fresh from
    /// disk on every call so the Settings list reflects the engine's latest
    /// mining pass; a missing or corrupt file (miner hasn't run yet) is simply
    /// an empty list. The stored order is never rewritten — only the copy shown
    /// to the user is sorted, because the engine's order drives its eviction.
    func terms() -> [String] {
        guard let root = read() else { return [] }
        let active = (root["terms"] as? [String]) ?? []
        return active.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Deletes one term: removed from the active list AND from the miner's
    /// pending candidates, then appended to `banned` so it can't come back.
    func remove(_ term: String) {
        guard var root = read() else { return }  // no file → nothing to forget
        var active = (root["terms"] as? [String]) ?? []
        active.removeAll { $0 == term }
        root["terms"] = active
        if var candidates = root["candidates"] as? [String: Any] {
            candidates.removeValue(forKey: term)
            root["candidates"] = candidates
        }
        root["banned"] = appendingBanned([term], in: root)
        write(root)
    }

    /// "Forget all": every active term moves to `banned` (so the miner can't
    /// re-learn the lot on its next pass) and the working sets are emptied.
    func clear() {
        guard var root = read() else { return }
        let active = (root["terms"] as? [String]) ?? []
        root["banned"] = appendingBanned(active, in: root)
        root["terms"] = [String]()
        root["candidates"] = [String: Any]()
        write(root)
    }

    // MARK: - IO

    private func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root
    }

    /// The `banned` list with `newTerms` appended — deduplicated, capped at
    /// `maxBanned` by dropping the oldest entries.
    private func appendingBanned(_ newTerms: [String], in root: [String: Any]) -> [String] {
        var banned = (root["banned"] as? [String]) ?? []
        for term in newTerms where !banned.contains(term) {
            banned.append(term)
        }
        if banned.count > Self.maxBanned {
            banned.removeFirst(banned.count - Self.maxBanned)
        }
        return banned
    }

    private func write(_ root: [String: Any]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Velora: failed to persist auto_learned.json: \(error)")
        }
    }
}
