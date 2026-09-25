import AppKit
import EventKit
import SwiftUI

/// The Meetings pane: a full-width list of meetings that opens one
/// meeting's notes in place, like a System Settings detail page.
///
///     ┌ Meetings ──────────────── [Search…] [Start Meeting Notes…] ┐
///     │ ● Recording Standup · 12:04 · Mic only   [Finish] [Discard] │  ← only while active
///     │ Standup            Sep 24, 3:00 PM · 42 min            ›   │
///     │ Design review      Sep 23, 11:00 AM · 1 hr   Mic Silent ›   │
///     └─────────────────────────────────────────────────────────────┘
///                         click a row ▼
///     │ ‹ All Meetings              [Retry Notes] [More ▾]          │
///     │ Standup — summary, decisions, action items, transcript      │
struct MeetingsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject var processor: MeetingProcessor
    let store: MeetingStore

    @State private var records: [MeetingRecord] = []
    @State private var query = ""
    @State private var hits: [MeetingSearchHit] = []
    /// The meeting whose detail page is open; nil shows the list.
    @State private var selectedID: String?
    @State private var selectedRecord: MeetingRecord?
    @State private var selectedHasRecoverableAudio = false
    @State private var selectedCanRetryNotes = false
    @State private var selectedCanRecreate = false
    @State private var selectedIsReprocessing = false
    @State private var transcriptExpanded = false
    @State private var transcript: [MeetingSegment]?
    @State private var transcriptLoading = false
    @State private var metadataLoadToken = UUID()
    @State private var transcriptLoadToken = UUID()
    @State private var searchLoadToken = UUID()

    /// The header search box, as wide as Dictionary's and History's.
    private static let searchWidth: CGFloat = 240

    private var selected: MeetingRecord? { selectedRecord }

    var body: some View {
        // The preference rows live in Settings › Advanced › Meetings
        // (`MeetingPreferenceRows`); this pane is the meeting memory only.
        VStack(spacing: 0) {
            PaneHeader(title: MainPane.meetings.title) {
                if !records.isEmpty || isSearching {
                    SettingsSearchBox(
                        prompt: "Search meetings", query: $query,
                        accessibilityLabel: "Search summaries, decisions, actions, and transcripts")
                        .frame(width: Self.searchWidth)
                        .onChange(of: query) { _, _ in
                            // Typing leaves an open meeting for the results.
                            if selectedID != nil { closeDetail() }
                            refreshSearch()
                        }
                }
                if coordinator.state == .idle {
                    Button("Start Meeting Notes…") { coordinator.startManual() }
                        .buttonStyle(.primaryCapsule)
                }
            }
            .padding(.bottom, VeloraSpacing.m)

            // Capture and processing state sit above the list so Finish and
            // Discard stay reachable however far the list or notes scroll.
            if showsStatusRow {
                HStack {
                    stateLabel
                    Spacer()
                    meetingAction
                }
                .padding(.horizontal, VeloraSpacing.m)
                .padding(.vertical, VeloraSpacing.s)
                Divider()
            }

            Group {
                if let selected {
                    detailPage(selected)
                } else if isSearching {
                    searchResults
                } else if records.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet", systemImage: "person.2.wave.2",
                        description: Text("Start one manually or let Velora suggest it when a call begins."))
                } else {
                    List {
                        ForEach(records) { record in meetingRow(record) }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in reload() }
    }

    /// A capture, a suggestion, or background processing is under way.
    private var showsStatusRow: Bool {
        guard coordinator.state == .idle else { return true }
        return processor.state != .idle
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var searchResults: some View {
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                ForEach(hits) { hit in
                    Button { select(hit.meetingID) } label: {
                        HStack(spacing: VeloraSpacing.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title).lineLimit(1)
                                Text(hit.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(hit.snippet)
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: VeloraSpacing.m)
                            disclosureChevron
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                    .buttonStyle(.plain)
                    .help("Open cited local meeting")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// Capture state, or processing progress while no capture is active.
    @ViewBuilder private var stateLabel: some View {
        switch coordinator.state {
        case .idle:
            switch processor.state {
            case .idle:
                EmptyView()
            case .processing(_, let label, let fraction):
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                    ProgressView(value: fraction).frame(width: 220)
                }
            case .failed(_, let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(VeloraStatus.warning)
            }
        case .preparing(let title):
            Label(title, systemImage: "hourglass")
        case .suggesting(let title, let sourceApp):
            Label(
                "\(sourceApp ?? "Call") detected · \(title)",
                systemImage: "video.fill")
                .foregroundStyle(VeloraStatus.warning)
        case .recording(_, let title, let startedAt, let systemAudio, let endDetected):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                let sources = systemAudio ? "Mic + system" : "Mic only"
                let micState = coordinator.microphoneSilent ? " · Mic is silent" : ""
                Label(
                    endDetected
                        ? "Did \(title) end?"
                        : "Recording \(title) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60)) · \(sources)\(micState)",
                    systemImage: endDetected ? "questionmark.circle.fill" : "record.circle.fill")
                    .foregroundStyle(endDetected ? VeloraStatus.warning : Color(nsColor: .systemRed))
            }
        }
    }

    @ViewBuilder private var meetingAction: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .suggesting:
            Button("Start Meeting Notes") { coordinator.acceptSuggestion() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Not Now") { coordinator.declineSuggestion() }
                .controlSize(.small)
        case .preparing:
            ProgressView().controlSize(.small)
        case .recording(_, _, _, _, let endDetected):
            if endDetected {
                Button("Keep Recording") { coordinator.keepMeetingRecording() }
                    .controlSize(.small)
                Button("Finish Notes") { coordinator.confirmMeetingEnded() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Discard…") { coordinator.cancelRecording() }
                    .controlSize(.small)
            } else {
                Button("Finish Notes") { coordinator.stopRecording() }
                    .buttonStyle(.borderedProminent).tint(VeloraStatus.danger)
                    .controlSize(.small)
                Button("Discard") { coordinator.cancelRecording() }
                    .controlSize(.small)
            }
        }
    }

    private func meetingRow(_ record: MeetingRecord) -> some View {
        Button { select(record.id) } label: {
            HStack(spacing: VeloraSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title).lineLimit(1)
                    Text(Self.rowSubtitle(record))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: VeloraSpacing.m)
                if let badge = Self.rowBadge(record) {
                    Label(badge.text, systemImage: badge.symbol)
                        .font(.caption)
                        .foregroundStyle(badge.warns ? AnyShapeStyle(VeloraStatus.warning) : AnyShapeStyle(.secondary))
                }
                disclosureChevron
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            // Full-width separators; they otherwise start at the badge text.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        }
        .buttonStyle(.plain)
    }

    /// "Sep 24, 2026 at 3:00 PM · 42 min · Zoom"
    private static func rowSubtitle(_ record: MeetingRecord) -> String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        let minutes = Int(record.endedAt.timeIntervalSince(record.startedAt) / 60)
        if record.status != .recording && minutes > 0 {
            parts.append("\(minutes) min")
        }
        if let source = record.sourceApp, !source.isEmpty {
            parts.append(source)
        }
        return parts.joined(separator: " · ")
    }

    /// One status word per row, most urgent first. Ready meetings with
    /// complete notes from both tracks show none.
    private static func rowBadge(
        _ record: MeetingRecord
    ) -> (text: String, symbol: String, warns: Bool)? {
        switch record.status {
        case .recording:
            return ("Recording", "record.circle", false)
        case .processing:
            return ("Processing", "hourglass", false)
        case .failed:
            return ("Failed", "exclamationmark.triangle.fill", true)
        case .ready:
            break
        }
        if case .failed = record.micIssue { return ("Mic Not Transcribed", "mic.slash", true) }
        if case .failed = record.systemIssue { return ("Audio Not Transcribed", "speaker.slash", true) }
        if record.micIssue == .silent { return ("Mic Silent", "mic.slash", true) }
        if record.micIssue == .tooShort { return ("Mic Too Short", "mic.slash", true) }
        if record.notes.partial { return ("Partial Notes", "exclamationmark.circle", true) }
        return nil
    }

    private func detailPage(_ record: MeetingRecord) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { closeDetail() } label: {
                    Label("All Meetings", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to all meetings (⌘[)")
                Spacer()
                detailActions(record)
            }
            .padding(.horizontal, VeloraSpacing.m)
            .padding(.vertical, VeloraSpacing.s)
            Divider()
            // One scroller for notes and transcript: a nested same-axis
            // scroller captures wheel events and strands the outer one.
            ScrollView {
                meetingDetail(record)
                    .padding(VeloraSpacing.m)
            }
        }
    }

    @ViewBuilder private func detailActions(_ record: MeetingRecord) -> some View {
        let processing = processor.isPending(meetingID: record.id)
        if selectedIsReprocessing {
            if selectedCanRecreate && !processing {
                Button("Retry Recreate") { processor.enqueue(meetingID: record.id) }
            }
        } else if selectedCanRetryNotes && !processing {
            Button("Retry Notes") { processor.enqueue(meetingID: record.id) }
        } else if record.status != .ready && record.status != .recording
            && selectedHasRecoverableAudio && !processing {
            // A processing row no job is working on (its failure could not
            // be saved) needs a way out too.
            Button("Retry") { processor.enqueue(meetingID: record.id) }
        }
        if processing {
            Button("Cancel Processing") {
                processor.cancel(meetingID: record.id)
            }
        }
        Menu("More") {
            Button("Copy Notes and Transcript") { copy(recordID: record.id) }
            Button("Export Markdown…") { export(record) }
            if record.status == .ready && selectedCanRecreate
                && !selectedIsReprocessing && !processing {
                Divider()
                Button("Recreate Transcript and Notes…") { reprocess(record) }
            }
            if let url = store.audioURL(relativePath: record.micPath),
               FileManager.default.fileExists(atPath: url.path) {
                Button("Play My Audio") { NSWorkspace.shared.open(url) }
            }
            if let url = store.audioURL(relativePath: record.systemPath),
               FileManager.default.fileExists(atPath: url.path) {
                Button("Play System Audio") { NSWorkspace.shared.open(url) }
            }
            if record.status != .recording {
                Divider()
                Button("Delete Meeting…", role: .destructive) { delete(record) }
            }
        }
        .fixedSize()
    }

    private func meetingDetail(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.title3.weight(.semibold))
                Text(record.startedAt.formatted(date: .long, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if record.status == .processing {
                Label("Local transcription and notes are still processing.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            } else if record.status == .failed {
                Label(record.error ?? "Processing failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(VeloraStatus.warning)
                if !selectedHasRecoverableAudio {
                    Text("No usable audio was captured, so this meeting cannot be transcribed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let message = record.readyErrorMessage(
                recreating: selectedIsReprocessing) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(VeloraStatus.warning)
            }
            ForEach(Self.issueMessages(record), id: \.self) { message in
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(VeloraStatus.warning)
            }

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why a ready meeting's transcript or notes are one-sided or partial.
    /// A skipped track no longer fails the meeting, so it must say so here.
    private static func issueMessages(_ record: MeetingRecord) -> [String] {
        var messages: [String] = []
        switch record.micIssue {
        case .silent:
            messages.append("Your microphone recorded only silence, so the transcript has no lines from you. Check the input device before the next call.")
        case .tooShort:
            messages.append("Your microphone recorded less than 0.2 seconds of audio, so the transcript has no lines from you.")
        case .failed(let error):
            messages.append("Your microphone track could not be transcribed: \(error)")
        case nil:
            break
        }
        switch record.systemIssue {
        case .silent:
            messages.append("Computer audio recorded only silence, so the transcript has no lines from the other side.")
        case .tooShort:
            messages.append("Computer audio recorded less than 0.2 seconds of audio, so the transcript has no lines from the other side.")
        case .failed(let error):
            messages.append("Computer audio could not be transcribed: \(error)")
        case nil:
            break
        }
        if record.notes.partial {
            messages.append("Part of the transcript could not be summarized, so these notes may be incomplete.")
        }
        return messages
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
            // Reload keeps an open detail page; it never opens one itself.
            let resolvedID = requestedID.flatMap { id in
                fresh.contains(where: { $0.id == id }) ? id : nil
            }
            let selected = resolvedID.flatMap { store.recordMetadata(id: $0) }
            let recoverable = selected.map {
                store.hasAnyUsableAudio(for: $0)
            } ?? false
            let canRecreate = selected.map {
                store.hasAllCapturedAudio(for: $0)
            } ?? false
            let canRetryNotes = selected.map {
                store.canRetryNotes(meetingID: $0.id)
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
                selectedCanRetryNotes = canRetryNotes
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
        selectedCanRetryNotes = false
        selectedCanRecreate = false
        selectedIsReprocessing = false
        resetTranscript()
        let token = UUID()
        metadataLoadToken = token
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let selected = store.recordMetadata(id: id)
            let recoverable = selected.map {
                store.hasAnyUsableAudio(for: $0)
            } ?? false
            let canRecreate = selected.map {
                store.hasAllCapturedAudio(for: $0)
            } ?? false
            let canRetryNotes = selected.map {
                store.canRetryNotes(meetingID: $0.id)
            } ?? false
            let reprocessing = store.isReprocessing(meetingID: id)
            DispatchQueue.main.async {
                guard metadataLoadToken == token, selectedID == id else { return }
                selectedRecord = selected
                selectedHasRecoverableAudio = recoverable
                selectedCanRetryNotes = canRetryNotes
                selectedCanRecreate = canRecreate
                selectedIsReprocessing = reprocessing
            }
        }
    }

    private func closeDetail() {
        metadataLoadToken = UUID()
        selectedID = nil
        selectedRecord = nil
        resetTranscript()
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

// MARK: - Preferences (Settings › Advanced › Meetings)

/// The meeting preference rows, hosted inside the Advanced form's MEETINGS
/// section. Calendar access is requested on the spot when the toggle turns
/// on; retention changes prune audio immediately.
struct MeetingPreferenceRows: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var coordinator: MeetingCoordinator

    static let footer = "Velora detects calls from local call apps, the microphone, and meeting pages in your browser, never saving meeting addresses, and records only after you choose Start Meeting Notes. The retention setting removes only audio; transcripts and notes stay until you delete them."

    var body: some View {
        Toggle("Suggest recording when a call is detected", isOn: $model.meetingSuggestions)
        Toggle("Name meetings from Calendar", isOn: $model.meetingCalendar)
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
    }
}

/// The notes-prompt editor sheet ("Edit…" next to Notes prompt). An empty
/// prompt means the built-in guidance, shown as the placeholder.
///
///     ┌ Notes prompt ─────────────────────┐
///     │ ┌───────────────────────────────┐ │
///     │ │ Create faithful meeting notes…│ │
///     │ └───────────────────────────────┘ │
///     │ caption           [Use Default] [Done] │
///     └───────────────────────────────────┘
struct MeetingNotesPromptEditor: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    private static let size = CGSize(width: 520, height: 320)

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            Text("Notes prompt")
                .font(.headline)
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
                    .scrollContentBackground(.hidden)
            }
            .background(RoundedRectangle(cornerRadius: VeloraRadius.tile).fill(VeloraPanel.card))
            .overlay(RoundedRectangle(cornerRadius: VeloraRadius.tile).strokeBorder(Color(.separatorColor)))
            HStack(alignment: .top) {
                Text("Shapes the tone, focus, and structure of notes. Notes always come back as a summary, decisions, and action items, generated on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.meetingNotesPrompt.isEmpty {
                    Button("Customize") {
                        model.meetingNotesPrompt = MeetingNotesPrompt.builtinGuidance
                    }
                } else {
                    Button("Use Default") { model.meetingNotesPrompt = "" }
                }
                Button("Done") {
                    model.flushMeetingNotesPrompt()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VeloraSpacing.xl)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
