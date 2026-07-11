import Darwin
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
    struct PortableSnapshot: Codable, Equatable {
        var terms: [String]
        var banned: [String]
    }

    private let url: URL
    /// Bound on the ban list so repeated deletes can't grow the file without
    /// limit; the oldest bans fall off first (the miner has long since
    /// checkpointed past the history rows that produced them).
    private static let maxBanned = 500

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/auto_learned.json")
    }

    /// Test/repository hook: point the store at an isolated projection file.
    init(url: URL) {
        self.url = url
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

    /// Only promoted terms and explicit bans are portable. Candidates and the
    /// history checkpoint are device-local mining state.
    func portableSnapshot() -> PortableSnapshot {
        guard let root = read() else { return PortableSnapshot(terms: [], banned: []) }
        return PortableSnapshot(
            terms: Self.validatedTerms((root["terms"] as? [String]) ?? []),
            banned: Self.validatedTerms((root["banned"] as? [String]) ?? []))
    }

    /// Merge confirmed state from another device. Bans win, while a term the
    /// miner promoted concurrently is unioned rather than overwritten.
    @discardableResult
    func applyPortableSnapshot(
        _ snapshot: PortableSnapshot,
        preservingDeviceState: Bool = true
    ) -> Bool {
        mutate { root in
            let validatedBans = Self.validatedTerms(snapshot.banned)
            let banned = preservingDeviceState
                ? self.appendingBanned(validatedBans, in: root)
                : self.appendingBanned(validatedBans, in: ["banned": [String]()])
            let bannedKeys = Set(banned.map(Self.normalized))
            let existing = preservingDeviceState ? ((root["terms"] as? [String]) ?? []) : []
            root["terms"] = Self.deduplicatedTerms(
                existing + Self.validatedTerms(snapshot.terms))
                .filter { !bannedKeys.contains(Self.normalized($0)) }
            root["banned"] = banned
            if !preservingDeviceState {
                root["candidates"] = [String: Any]()
            } else if var candidates = root["candidates"] as? [String: Any] {
                candidates = candidates.filter { !bannedKeys.contains(Self.normalized($0.key)) }
                root["candidates"] = candidates
            }
        }
    }

    /// Deletes one term: removed from the active list AND from the miner's
    /// pending candidates, then appended to `banned` so it can't come back.
    func remove(_ term: String) {
        guard let validated = try? DictionaryValue(term).text else { return }
        mutate(createIfMissing: false) { root in
            let key = Self.normalized(validated)
            var active = (root["terms"] as? [String]) ?? []
            active.removeAll { Self.normalized($0) == key }
            root["terms"] = active
            if var candidates = root["candidates"] as? [String: Any] {
                candidates = candidates.filter { Self.normalized($0.key) != key }
                root["candidates"] = candidates
            }
            root["banned"] = self.appendingBanned([validated], in: root)
        }
    }

    /// "Forget all": every active term moves to `banned` (so the miner can't
    /// re-learn the lot on its next pass) and the working sets are emptied.
    func clear() {
        mutate(createIfMissing: false) { root in
            let active = (root["terms"] as? [String]) ?? []
            root["banned"] = self.appendingBanned(active, in: root)
            root["terms"] = [String]()
            root["candidates"] = [String: Any]()
        }
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
        var keys = Set(banned.map(Self.normalized))
        for term in newTerms where keys.insert(Self.normalized(term)).inserted {
            banned.append(term)
        }
        if banned.count > Self.maxBanned {
            banned.removeFirst(banned.count - Self.maxBanned)
        }
        return banned
    }

    @discardableResult
    private func write(_ root: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("Velora: failed to persist auto_learned.json: \(error)")
            return false
        }
    }

    /// Cross-process lock shared with the Python miner. The critical section
    /// includes the fresh read, mutation, and atomic replace, so neither writer
    /// can publish a stale whole-file view over the other.
    @discardableResult
    private func mutate(
        createIfMissing: Bool = true,
        _ body: (inout [String: Any]) -> Void
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("Velora: failed to create auto-vocabulary directory: \(error)")
            return false
        }
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            NSLog("Velora: failed to open auto-vocabulary lock")
            return false
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            NSLog("Velora: failed to lock auto-vocabulary state")
            return false
        }
        defer { flock(descriptor, LOCK_UN) }
        guard createIfMissing || FileManager.default.fileExists(atPath: url.path) else {
            return true
        }
        var root = read() ?? ["version": 1]
        body(&root)
        return write(root)
    }

    private static func validatedTerms(_ terms: [String]) -> [String] {
        deduplicatedTerms(terms.compactMap { try? DictionaryValue($0).text })
    }

    private static func deduplicatedTerms(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms.filter { seen.insert(normalized($0)).inserted }
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
