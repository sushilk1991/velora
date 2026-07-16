import AppKit
import EventKit
import SwiftUI

struct MeetingsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject var processor: MeetingProcessor
    let store: MeetingStore

    @State private var records: [MeetingRecord] = []
    @State private var query = ""
    @State private var hits: [MeetingSearchHit] = []
    @State private var selectedID: String?
    @State private var selectedRecord: MeetingRecord?

    private var selected: MeetingRecord? { selectedRecord }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Suggest recording when a call is detected", isOn: $model.meetingSuggestions)
                    Toggle("Use Calendar for meeting suggestions", isOn: $model.meetingCalendar)
                        .onChange(of: model.meetingCalendar) { _, enabled in
                            if enabled && coordinator.calendarAuthorization != .fullAccess {
                                coordinator.requestCalendarAccess { granted in
                                    if !granted { model.meetingCalendar = false }
                                }
                            }
                        }
                    Picker("Keep meeting audio", selection: $model.meetingAudioRetentionDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .onChange(of: model.meetingAudioRetentionDays) { _, _ in
                        coordinator.pruneAudio()
                    }
                } footer: {
                    Text("Detection only suggests. Every recording still needs a Start Recording confirmation. macOS asks for computer-audio access after that confirmation on the first meeting. Transcripts and notes stay until you delete them; this setting removes only audio.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 210)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    stateLabel
                    Spacer()
                    meetingAction
                }

                TextField("Search summaries, decisions, actions, and transcript", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, _ in refreshSearch() }

                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Cited matches")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(hits) { hit in
                                Button { select(hit.meetingID) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(hit.title).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text(hit.startedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(hit.snippet).font(.caption2).lineLimit(2)
                                    }
                                    .frame(width: 180, alignment: .leading)
                                    .padding(8)
                                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .help("Open cited local meeting")
                            }
                        }
                    }
                    .frame(height: 76)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(records) { record in meetingChip(record) }
                        }
                    }
                    .frame(height: 54)
                }

                Divider()
                if let selected { meetingDetail(selected) }
                else {
                    ContentUnavailableView(
                        "No meetings yet", systemImage: "person.2.wave.2",
                        description: Text("Start one manually or let Velora suggest it when a call begins."))
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: SettingsTab.meetings.preferredHeight)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in reload() }
    }

    @ViewBuilder private var stateLabel: some View {
        switch coordinator.state {
        case .idle:
            switch processor.state {
            case .idle: Label("Meeting memory", systemImage: "person.2.wave.2").font(.headline)
            case .processing(_, let label, let fraction):
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.headline)
                    ProgressView(value: fraction).frame(width: 220)
                }
            case .failed(_, let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case .preparing(let title):
            Label(title, systemImage: "hourglass").font(.headline)
        case .recording(_, let title, let startedAt, let systemAudio):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Label(
                    "Recording \(title) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60)) · \(systemAudio ? "Mic + system" : "Mic only")",
                    systemImage: "record.circle.fill")
                    .font(.headline).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var meetingAction: some View {
        switch coordinator.state {
        case .idle:
            Button("Start Meeting…") { coordinator.startManual() }
        case .preparing:
            ProgressView().controlSize(.small)
        case .recording:
            Button("Stop & Create Notes") { coordinator.stopRecording() }
                .buttonStyle(.borderedProminent).tint(.red)
            Button("Discard") { coordinator.cancelRecording() }
        }
    }

    private func meetingChip(_ record: MeetingRecord) -> some View {
        Button { select(record.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            .padding(7)
            .background(
                selected?.id == record.id ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func meetingDetail(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.title3.weight(.semibold))
                    Text(record.startedAt.formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if record.status == .failed {
                    Button("Retry") { processor.enqueue(meetingID: record.id) }
                }
                Menu("More") {
                    Button("Copy notes and transcript") { copy(record.exportText) }
                    Button("Export Markdown…") { export(record) }
                    if let url = store.audioURL(relativePath: record.micPath),
                       FileManager.default.fileExists(atPath: url.path) {
                        Button("Play my audio") { NSWorkspace.shared.open(url) }
                    }
                    if let url = store.audioURL(relativePath: record.systemPath),
                       FileManager.default.fileExists(atPath: url.path) {
                        Button("Play system audio") { NSWorkspace.shared.open(url) }
                    }
                    if record.status != .recording {
                        Divider()
                        Button("Delete meeting", role: .destructive) { delete(record) }
                    }
                }
            }

            if record.status == .processing {
                Label("Local transcription and notes are still processing", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            } else if record.status == .failed {
                Label(record.error ?? "Processing failed", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !record.notes.summary.isEmpty {
                        detailSection("Summary", text: record.notes.summary)
                    }
                    if !record.notes.decisions.isEmpty {
                        detailSection("Decisions", text: record.notes.decisions.map { "• \($0)" }.joined(separator: "\n"))
                    }
                    if !record.notes.actionItems.isEmpty {
                        detailSection("Action items", text: record.notes.actionItems.map { "☐ \($0)" }.joined(separator: "\n"))
                    }
                    if !record.formattedTranscript.isEmpty {
                        detailSection("Transcript", text: record.formattedTranscript)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)
        }
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    private func reload() {
        records = store.recentMetadata(limit: 100)
        if selectedID == nil || !records.contains(where: { $0.id == selectedID }) {
            selectedID = records.first?.id
        }
        selectedRecord = selectedID.flatMap { store.record(id: $0) }
        refreshSearch()
    }

    private func select(_ id: String) {
        selectedID = id
        selectedRecord = store.record(id: id)
    }

    private func refreshSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []
            return
        }
        hits = store.search(query, limit: 30)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(record.title.replacingOccurrences(of: "/", with: "-")) notes.md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? record.exportText.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func delete(_ record: MeetingRecord) {
        // Active capture owns the row and files; Discard is the only safe way
        // to remove it because that stops both writers before deletion.
        guard record.status != .recording else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(record.title)?"
        alert.informativeText = "This permanently deletes its transcript, notes, search index, and retained audio."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        processor.cancelAndForget(meetingID: record.id)
        store.delete(meetingID: record.id)
        reload()
    }
}
