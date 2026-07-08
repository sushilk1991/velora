import Foundation

/// Persists corrections Velora learns from the user's post-dictation edits into
/// `~/.velora/learned.json` — a small `{replacements, vocabulary}` file the
/// engine merges into its global vocab/replacements (see engine `_load_learned`).
///
/// Kept separate from the app-owned `config.json` so neither clobbers the other.
/// All access is main-actor (called from `DictationController`).
final class LearningStore {
    struct Learned: Codable {
        var replacements: [String: String] = [:]
        var vocabulary: [String] = []
        /// How many times each correction was seen — we only trust a correction
        /// once it recurs, to avoid learning one-off typos.
        var counts: [String: Int] = [:]
    }

    private(set) var learned = Learned()
    private let url: URL
    /// A correction is committed once seen this many times.
    private static let confirmThreshold = 2

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/learned.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Learned.self, from: data) else { return }
        learned = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(learned) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Records observed corrections (wrong → right). Returns true if anything
    /// crossed the confirmation threshold (caller should reload the engine).
    /// A correction is committed on its 2nd sighting so a one-off edit doesn't
    /// pollute the dictionary.
    @discardableResult
    func observe(_ corrections: [(wrong: String, right: String)]) -> Bool {
        var committed = false
        for correction in corrections {
            let key = correction.wrong.lowercased()
            // Already learned (and unchanged) — nothing to do.
            if learned.replacements[key] == correction.right { continue }
            learned.counts[key, default: 0] += 1
            if learned.counts[key] ?? 0 >= Self.confirmThreshold {
                learned.replacements[key] = correction.right
                if !learned.vocabulary.contains(correction.right) {
                    learned.vocabulary.append(correction.right)
                }
                committed = true
            }
        }
        save()
        return committed
    }

    func clear() {
        learned = Learned()
        save()
    }
}
