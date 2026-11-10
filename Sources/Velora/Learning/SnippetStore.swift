import Combine
import Foundation
import SwiftUI

struct VoiceSnippet: Codable, Identifiable, Equatable {
    let id: UUID
    var trigger: String
    var text: String

    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}

enum SnippetError: LocalizedError {
    case invalid, duplicate, full, unreadable
    var errorDescription: String? {
        switch self {
        case .invalid: return "Use a trigger of 1–60 characters and text of 1–4,000 characters. Triggers cannot be voice commands."
        case .duplicate: return "A snippet already uses this trigger."
        case .full: return "You can save up to 200 snippets."
        case .unreadable: return "The saved snippets could not be read. The file has been left unchanged."
        }
    }
}

final class SnippetStore: ObservableObject {
    private struct Document: Codable { let version: Int; let snippets: [VoiceSnippet] }
    @Published private(set) var snippets: [VoiceSnippet] = []
    @Published private(set) var error: String?
    private let url: URL
    private var canWrite = true

    init(url: URL = AppConfig.veloraDirectory.appendingPathComponent("snippets.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 4_000_000 else { throw SnippetError.unreadable }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, document.snippets.count <= 200,
                  Set(document.snippets.map(\.id)).count == document.snippets.count,
                  Set(document.snippets.map { VoiceSnippet.key($0.trigger) }).count == document.snippets.count,
                  document.snippets.allSatisfy(Self.valid) else { throw SnippetError.unreadable }
            snippets = document.snippets
        } catch { canWrite = false; self.error = SnippetError.unreadable.localizedDescription }
    }

    static func valid(_ snippet: VoiceSnippet) -> Bool {
        let key = VoiceSnippet.key(snippet.trigger)
        return !key.isEmpty && snippet.trigger.unicodeScalars.count <= 60
            && !snippet.trigger.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snippet.text.unicodeScalars.count <= 4_000
            && !snippet.text.unicodeScalars.contains(where: { $0.value == 0 })
            && VoiceCommand.parse(text: key, raw: key) == nil
    }

    func save(trigger: String, text: String, replacing id: UUID? = nil) throws {
        guard canWrite else { throw SnippetError.unreadable }
        let item = VoiceSnippet(id: id ?? UUID(), trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        guard Self.valid(item) else { throw SnippetError.invalid }
        guard !snippets.contains(where: { $0.id != item.id && VoiceSnippet.key($0.trigger) == VoiceSnippet.key(item.trigger) })
        else { throw SnippetError.duplicate }
        var candidate = snippets.filter { $0.id != item.id }
        guard candidate.count < 200 else { throw SnippetError.full }
        candidate.append(item)
        try persist(candidate)
    }

    func delete(_ id: UUID) throws {
        guard canWrite else { throw SnippetError.unreadable }
        try persist(snippets.filter { $0.id != id })
    }

    private func persist(_ candidate: [VoiceSnippet]) throws {
        let data = try JSONEncoder().encode(Document(version: 1, snippets: candidate))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        snippets = candidate
        error = nil
    }
}

struct SnippetSettingsCard: View {
    @StateObject private var store = SnippetStore()
    @State private var showingEditor = false
    @State private var editingID: UUID?
    @State private var trigger = ""
    @State private var text = ""
    @State private var message: String?
    var body: some View {
        DisclosureGroup("Voice snippets") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Say a trigger as a complete dictation to insert saved text, such as a signature or booking link. Snippets are literal text and stay on this Mac. As Heard and technical modes skip expansion.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(store.snippets) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.trigger).fontWeight(.medium)
                            Text(item.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editingID = item.id; trigger = item.trigger; text = item.text; message = nil; showingEditor = true }
                        Button("Delete", role: .destructive) {
                            do { try store.delete(item.id) } catch { message = error.localizedDescription }
                        }
                    }
                }
                Button("Add snippet…") { editingID = nil; trigger = ""; text = ""; message = nil; showingEditor = true }
                if let error = store.error ?? message { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding(.top, 8)
        }
        .sheet(isPresented: $showingEditor) {
            VStack(alignment: .leading, spacing: 12) {
                Text(editingID == nil ? "New voice snippet" : "Edit voice snippet").font(.headline)
                TextField("Spoken trigger", text: $trigger).textFieldStyle(.roundedBorder)
                TextEditor(text: $text).frame(minHeight: 170).border(.secondary.opacity(0.25))
                if let message { Text(message).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button("Cancel") { showingEditor = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        do { try store.save(trigger: trigger, text: text, replacing: editingID); showingEditor = false }
                        catch { message = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 520)
        }
    }
}
