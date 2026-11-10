import AppKit
import Combine
import Foundation
import SwiftUI

/// Support events deliberately have no free-text, transcript, or path field.
enum ActivityKind: String, Codable {
    case engineRestart, engineUnavailable, modelFallback, deliveryBlocked, formattingFailed, meetingIssue

    var title: String {
        switch self {
        case .engineRestart: return "Speech engine restarted"
        case .engineUnavailable: return "Speech engine unavailable"
        case .modelFallback: return "Keyboard route used the saved model"
        case .deliveryBlocked: return "Text copied instead of inserted"
        case .formattingFailed: return "Writing preview did not finish"
        case .meetingIssue: return "Meeting processing needs attention"
        }
    }
    var detail: String {
        switch self {
        case .engineRestart: return "Velora reconnects automatically. An interrupted take can be reviewed in History."
        case .engineUnavailable: return "Check model setup and engine status in Settings."
        case .modelFallback: return "The requested language or installed model was unavailable. Check keyboard mappings in Dictation settings."
        case .deliveryBlocked: return "Your result is available on the clipboard and in History. Check focus and Accessibility permission."
        case .formattingFailed: return "The original text is unchanged. Try again when the engine is ready."
        case .meetingIssue: return "Open Meetings to review the issue and retry the retained recording."
        }
    }
}

struct ActivityItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let kind: ActivityKind
}

final class ActivityStore: ObservableObject {
    static let shared = ActivityStore(url: AppConfig.veloraDirectory.appendingPathComponent("activity.json"),
        enabled: !CommandLine.arguments.contains("--selftest"))
    @Published private(set) var items: [ActivityItem] = []
    private let url: URL
    private let enabled: Bool
    private let writes = DispatchQueue(label: "com.velora.activity", qos: .utility)

    init(url: URL, enabled: Bool = true) {
        self.url = url
        self.enabled = enabled
        if enabled, let data = try? Data(contentsOf: url), data.count <= 100_000,
           let saved = try? JSONDecoder().decode([ActivityItem].self, from: data) {
            items = Array(saved.prefix(200))
        }
    }

    func record(_ kind: ActivityKind, date: Date = Date()) {
        guard enabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.record(kind, date: date) }
            return
        }
        if let latest = items.first, latest.kind == kind, abs(latest.date.timeIntervalSince(date)) < 5 { return }
        items.insert(ActivityItem(id: UUID(), date: date, kind: kind), at: 0)
        items = Array(items.prefix(200))
        persist()
    }

    func clear() { items = []; persist() }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(items)
    }

    private func persist() {
        let snapshot = items
        let url = url
        writes.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { NSLog("Velora: support event persistence failed") }
        }
    }
}

struct ActivityView: View {
    @ObservedObject var store: ActivityStore = .shared
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent support events").font(.headline)
            Text("This list contains event types and times. It does not include your words, recordings, app names, or screen context.")
                .font(.caption).foregroundStyle(.secondary)
            if store.items.isEmpty { Text("No support events recorded.").foregroundStyle(.secondary) }
            ForEach(store.items.prefix(12)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.kind.title).fontWeight(.medium)
                        Spacer()
                        Text(item.date, style: .relative).foregroundStyle(.secondary)
                    }
                    Text(item.kind.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Export support events…", action: export)
                Button("Clear", role: .destructive) { store.clear() }.disabled(store.items.isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Velora support events.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try store.exportData().write(to: url, options: .atomic); message = "Support events exported." }
            catch { message = "The support events could not be saved." }
        }
    }
}
