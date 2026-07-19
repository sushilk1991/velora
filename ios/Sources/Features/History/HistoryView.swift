import SwiftUI
import UIKit

struct HistoryView: View {
    @Bindable var store: TranscriptStore
    let onStartDictating: () -> Void

    @State private var copiedEntryID: UUID?
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Your words will live here", systemImage: "text.quote")
                    } description: {
                        Text("Every finished dictation is saved on this iPhone, ready to copy again.")
                    } actions: {
                        Button("Start your first dictation", action: onStartDictating)
                            .buttonStyle(.borderedProminent)
                            .tint(VeloraTheme.violet)
                    }
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            TranscriptRow(
                                entry: entry,
                                copied: copiedEntryID == entry.id,
                                onCopy: { copy(entry) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Delete", role: .destructive) {
                                    store.delete(entry)
                                }
                            }
                            .contextMenu {
                                Button("Copy transcript") { copy(entry) }
                                Button("Delete", role: .destructive) { store.delete(entry) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !store.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            showingClearConfirmation = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all local transcript history?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete all transcripts", role: .destructive) { store.clear() }
                Button("Keep transcripts", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Text already pasted into other apps is not affected.")
            }
            .sensoryFeedback(.success, trigger: copiedEntryID)
        }
    }

    private func copy(_ entry: TranscriptEntry) {
        UIPasteboard.general.string = entry.text
        copiedEntryID = entry.id
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text(entry.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copied ? Color.green : VeloraTheme.violet)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transcript from \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityValue(entry.text)
        .accessibilityHint("Copies this transcript")
    }
}

#Preview("History") {
    let defaults = UserDefaults(suiteName: "preview.history") ?? .standard
    let store = TranscriptStore(defaults: defaults)
    HistoryView(store: store) {}
}
