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
    @State private var selectedHasRecoverableAudio = false
    @State private var selectedCanRecreate = false
    @State private var selectedIsReprocessing = false
    @State private var transcriptExpanded = false
    @State private var transcript: [MeetingSegment]?
    @State private var transcriptLoading = false
    @State private var metadataLoadToken = UUID()
    @State private var transcriptLoadToken = UUID()
    @State private var searchLoadToken = UUID()

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
                        Text("Improve remote speech detection")
                        Text("Skips long silences while keeping the transcript honestly labeled Me and Them. Runs on this Mac; downloads two small voice models (~46 MB) on the first meeting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker(selection: $model.meetingEndAction) {
                    Text("Ask to stop").tag(MeetingEndAction.ask)
                    Text("Stop and create notes").tag(MeetingEndAction.stop)
                    Text("Keep recording").tag(MeetingEndAction.off)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When the call ends")
                        Text("While recording, Velora keeps watching the detected call (Huddle, Zoom, Meet, Teams) and reacts when it disappears.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                SettingsFooter("Detection only suggests. Every recording still needs a Start Recording confirmation. macOS asks for computer-audio access after that confirmation on the first meeting. Transcripts and notes stay until you delete them; this setting removes only audio.")
            }

            Section("Notes style") {
                VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                    ZStack(alignment: .topLeading) {
                        if model.meetingNotesPrompt.isEmpty {
                            Text(MeetingNotesPrompt.builtinGuidance)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $model.meetingNotesPrompt)
                            .font(.callout)
                            .frame(minHeight: 72, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                    }
                    HStack(alignment: .top) {
                        Text("Shapes how notes read — tone, focus, structure. Notes always come back as a summary, decisions, and action items, generated on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.meetingNotesPrompt.isEmpty {
                            Button("Customize") {
                                model.meetingNotesPrompt = MeetingNotesPrompt.builtinGuidance
                            }
                            .controlSize(.small)
                        } else {
                            Button("Use Default") { model.meetingNotesPrompt = "" }
                                .controlSize(.small)
                        }
                    }
                }
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
        let processing = processor.isPending(meetingID: record.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).font(.title3.weight(.semibold))
                    Text(record.startedAt.formatted(date: .long, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selectedIsReprocessing {
                    if selectedCanRecreate && !processing {
                        Button("Retry Recreate") { processor.enqueue(meetingID: record.id) }
                    }
                } else if record.status == .failed && selectedHasRecoverableAudio
                    && !processing {
                    Button("Retry") { processor.enqueue(meetingID: record.id) }
                }
                if processing {
                    Button("Cancel processing") {
                        processor.cancel(meetingID: record.id)
                    }
                }
                Menu("More") {
                    Button("Copy notes and transcript") { copy(recordID: record.id) }
                    Button("Export Markdown…") { export(record) }
                    if record.status == .ready && selectedCanRecreate
                        && !selectedIsReprocessing && !processing {
                        Divider()
                        Button("Recreate transcript and notes…") { reprocess(record) }
                    }
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
                if !selectedHasRecoverableAudio {
                    Text("No usable audio was captured, so this meeting cannot be transcribed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = record.error {
                Label(
                    "Recreate did not finish; the previous notes were kept. \(error)",
                    systemImage: "exclamationmark.triangle")
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
                transcriptSection(record)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcriptSection(_ record: MeetingRecord) -> some View {
        DisclosureGroup(isExpanded: $transcriptExpanded) {
            Group {
                if transcriptLoading {
                    ProgressView("Loading transcript…")
                        .padding(.vertical, VeloraSpacing.s)
                } else if let transcript {
                    if transcript.isEmpty {
                        Text("No transcript is available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: VeloraSpacing.s) {
                            ForEach(transcript) { segment in
                                transcriptRow(segment)
                            }
                        }
                    }
                }
            }
            .padding(.top, VeloraSpacing.xs)
        } label: {
            Text("Transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .onChange(of: transcriptExpanded) { _, expanded in
            if expanded { loadTranscript(meetingID: record.id) }
        }
    }

    private func transcriptRow(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: VeloraSpacing.s) {
            Text(Self.clock(segment.startMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.speaker.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(segment.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }

    private func reload() {
        let token = UUID()
        metadataLoadToken = token
        let requestedID = selectedID
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = store.recentMetadata(limit: 100)
            let resolvedID = requestedID.flatMap { id in
                fresh.contains(where: { $0.id == id }) ? id : nil
            } ?? fresh.first?.id
            let selected = resolvedID.flatMap { store.recordMetadata(id: $0) }
            let recoverable = selected.map {
                store.hasUsableAudio(relativePath: $0.micPath)
                    || store.hasUsableAudio(relativePath: $0.systemPath)
            } ?? false
            let canRecreate = selected.map {
                store.hasAllCapturedAudio(for: $0)
            } ?? false
            let reprocessing = resolvedID.map {
                store.isReprocessing(meetingID: $0)
            } ?? false
            DispatchQueue.main.async {
                guard metadataLoadToken == token else { return }
                let selectionChanged = selectedID != resolvedID
                let recordChanged = selectedRecord != selected
                records = fresh
                selectedID = resolvedID
                selectedRecord = selected
                selectedHasRecoverableAudio = recoverable
                selectedCanRecreate = canRecreate
                selectedIsReprocessing = reprocessing
                if selectionChanged || recordChanged { resetTranscript() }
            }
        }
        refreshSearch()
    }

    private func select(_ id: String) {
        guard selectedID != id else { return }
        selectedID = id
        selectedRecord = records.first(where: { $0.id == id })
        selectedHasRecoverableAudio = false
        selectedCanRecreate = false
        selectedIsReprocessing = false
        resetTranscript()
        let token = UUID()
        metadataLoadToken = token
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let selected = store.recordMetadata(id: id)
            let recoverable = selected.map {
                store.hasUsableAudio(relativePath: $0.micPath)
                    || store.hasUsableAudio(relativePath: $0.systemPath)
            } ?? false
            let canRecreate = selected.map {
                store.hasAllCapturedAudio(for: $0)
            } ?? false
            let reprocessing = store.isReprocessing(meetingID: id)
            DispatchQueue.main.async {
                guard metadataLoadToken == token, selectedID == id else { return }
                selectedRecord = selected
                selectedHasRecoverableAudio = recoverable
                selectedCanRecreate = canRecreate
                selectedIsReprocessing = reprocessing
            }
        }
    }

    private func refreshSearch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchLoadToken = UUID()
            hits = []
            return
        }
        let token = UUID()
        searchLoadToken = token
        let requestedQuery = query
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = store.search(requestedQuery, limit: 30)
            DispatchQueue.main.async {
                guard searchLoadToken == token, query == requestedQuery else { return }
                hits = fresh
            }
        }
    }

    private func loadTranscript(meetingID: String) {
        guard transcript == nil, !transcriptLoading else { return }
        let token = UUID()
        transcriptLoadToken = token
        transcriptLoading = true
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let segments = store.record(id: meetingID)?.segments ?? []
            DispatchQueue.main.async {
                guard transcriptLoadToken == token, selectedID == meetingID else { return }
                transcript = segments
                transcriptLoading = false
            }
        }
    }

    private func resetTranscript() {
        transcriptLoadToken = UUID()
        transcriptExpanded = false
        transcript = nil
        transcriptLoading = false
    }

    private func copy(recordID: String) {
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let text = store.record(id: recordID)?.exportText ?? ""
            DispatchQueue.main.async {
                guard !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func export(_ record: MeetingRecord) {
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let text = store.record(id: record.id)?.exportText ?? ""
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.nameFieldStringValue =
                    "\(record.title.replacingOccurrences(of: "/", with: "-")) notes.md"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func reprocess(_ record: MeetingRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recreate this transcript and its notes?"
        alert.informativeText =
            "Velora will use the retained audio and the current transcription pipeline. "
            + "The existing notes stay visible until the replacement is ready."
        alert.addButton(withTitle: "Recreate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        resetTranscript()
        processor.reprocess(meetingID: record.id)
    }

    private static func clock(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
