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
        // One grouped form for both halves — the pre-0.9 layout stacked a
        // fixed-height Form above a hand-built panel, which clipped the last
        // settings row mid-text and gave the pane two competing designs.
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
                Toggle(isOn: $model.meetingDiarization) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Identify different speakers")
                        Text("Splits the other side of a call into Speaker 1, Speaker 2, … in the transcript. Runs on this Mac; downloads two small voice models (~46 MB) on the first meeting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                SettingsFooter("Detection only suggests. Every recording still needs a Start Recording confirmation. macOS asks for computer-audio access after that confirmation on the first meeting. Transcripts and notes stay until you delete them; this setting removes only audio.")
            }

            Section("Meeting memory") {
                // State + primary action live in a ROW, not the section
                // header — rows are guaranteed clickable, and header text
                // stays plain like every other section title.
                HStack {
                    stateLabel
                    Spacer()
                    if !captureActive { meetingAction }
                }

                if !records.isEmpty || isSearching {
                    // In-card search row: borderless field like the grouped
                    // idiom, with the same ⨉-clear affordance as
                    // SettingsSearchBox (a bordered box inside a card row
                    // would read as a double border).
                    HStack(spacing: VeloraSpacing.s) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField(
                            "Search summaries, decisions, actions, and transcript",
                            text: $query)
                            .textFieldStyle(.plain)
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .onChange(of: query) { _, _ in refreshSearch() }
                }

                if isSearching {
                    citedMatches
                } else if !records.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(records) { record in meetingChip(record) }
                        }
                    }
                }

                if let selected {
                    meetingDetail(selected)
                } else {
                    ContentUnavailableView(
                        "No meetings yet", systemImage: "person.2.wave.2",
                        description: Text("Start one manually or let Velora suggest it when a call begins."))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A live capture must never scroll its controls out of reach —
            // the form scrolls, so Stop/Discard get a pinned bottom bar for
            // the duration (the row above hides its action to avoid twins).
            if captureActive {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        stateLabel
                        Spacer()
                        meetingAction
                    }
                    .padding(.horizontal, VeloraSpacing.m)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in reload() }
    }

    /// True while a capture is being prepared or recorded — the states whose
    /// controls must stay reachable regardless of scroll position.
    private var captureActive: Bool {
        switch coordinator.state {
        case .idle: return false
        case .preparing, .recording: return true
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var citedMatches: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
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
        }
    }

    /// Section-header state line — inherits the grouped-form header style so
    /// it reads like every other section title in the app.
    @ViewBuilder private var stateLabel: some View {
        switch coordinator.state {
        case .idle:
            switch processor.state {
            case .idle:
                Text("Ready to record")
                    .foregroundStyle(.secondary)
            case .processing(_, let label, let fraction):
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                    ProgressView(value: fraction).frame(width: 220)
                }
            case .failed(_, let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        case .preparing(let title):
            Label(title, systemImage: "hourglass")
        case .recording(_, let title, let startedAt, let systemAudio):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Label(
                    "Recording \(title) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60)) · \(systemAudio ? "Mic + system" : "Mic only")",
                    systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var meetingAction: some View {
        switch coordinator.state {
        case .idle:
            Button("Start Meeting…") { coordinator.startManual() }
                .controlSize(.small)
        case .preparing:
            ProgressView().controlSize(.small)
        case .recording:
            Button("Stop & Create Notes") { coordinator.stopRecording() }
                .buttonStyle(.borderedProminent).tint(.red)
                .controlSize(.small)
            Button("Discard") { coordinator.cancelRecording() }
                .controlSize(.small)
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

            // No inner ScrollView: a same-axis nested scroller inside the
            // grouped form captures wheel events and strands the outer
            // scroll. The form itself scrolls the full transcript.
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
