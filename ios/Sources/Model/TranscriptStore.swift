import Foundation
import Observation

@MainActor
@Observable
final class TranscriptStore {
    private static let storageKey = "velora.mobile.transcriptHistory"
    private static let maximumEntries = 50

    private let defaults: UserDefaults
    private(set) var entries: [TranscriptEntry] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    @discardableResult
    func add(_ text: String) -> TranscriptEntry? {
        let normalized = TranscriptFormatter.normalize(text)
        guard !normalized.isEmpty else { return nil }

        let entry = TranscriptEntry(text: normalized)
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        persist()
        return entry
    }

    func delete(_ entry: TranscriptEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TranscriptEntry].self, from: data)
        else { return }
        entries = Array(decoded.prefix(Self.maximumEntries))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
