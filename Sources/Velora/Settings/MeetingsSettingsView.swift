import AppKit
import EventKit
import SwiftUI

/// The Meetings pane: one card of meetings that opens a meeting's notes in
/// place, like a System Settings detail page.
///
///     Meetings            [Search…] [Start Meeting Notes…] [⋯]
///     ┌──────────────────────────────────────────────────────┐
///     │ ◉ Recording Standup          [Discard…] [Finish Notes] │  ← only while active
///     │   12:04 · Mic only                                     │
///     └──────────────────────────────────────────────────────┘
///     ┌──────────────────────────────────────────────────────┐
///     │ Standup            Sep 24, 3:00 PM · 42 min        ›  │
///     │ Design review      Sep 23 · 1 hr      Mic silent   ›  │
///     └──────────────────────────────────────────────────────┘
///                         click a row ▼
///     [‹] Standup                         [Retry Notes] [⋯]
///     Summary / Decisions / Action items / Transcript cards
struct MeetingsSettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var coordinator: MeetingCoordinator
    @ObservedObject var processor: MeetingProcessor
    let store: MeetingStore
    /// Opens Settings › Advanced, where the meeting preferences live.
    var openMeetingSettings: () -> Void = {}

    init(
        model: SettingsModel, coordinator: MeetingCoordinator,
        processor: MeetingProcessor, store: MeetingStore,
        openMeetingSettings: @escaping () -> Void = {}
    ) {
        self.model = model
        self.coordinator = coordinator
        self.processor = processor
        self.store = store
        self.openMeetingSettings = openMeetingSettings
        _transcript = StateObject(wrappedValue: MeetingTranscriptLoader(store: store))
    }

    @State private var records: [MeetingRecord] = []
    /// False until the first list load lands: the pane shows a spinner, not
    /// "No meetings yet", and the header adds its search box only after.
    @State private var loaded = false
    @State private var query = ""
    @State private var hits: [MeetingSearchHit] = []
    /// The meeting whose detail page is open; nil shows the list.
    @State private var selectedID: String?
    /// The meeting just closed, which the list focuses as it comes back.
    @State private var returnFocusID: String?
    @State private var selectedRecord: MeetingRecord?
    @State private var selectedHasRecoverableAudio = false
    @State private var selectedCanRetryNotes = false
    @State private var selectedCanRecreate = false
    @State private var selectedIsReprocessing = false
    /// The open meeting has transcript lines; without any, the Transcript
    /// card would only offer "Show" over nothing, so it is left out.
    @State private var selectedHasTranscript = false
    /// The open meeting's Transcript card, as in the notes window.
    @StateObject private var transcript: MeetingTranscriptLoader
    @State private var metadataLoadToken = UUID()
    @State private var searchLoadToken = UUID()

    /// The header search box, as wide as Dictionary's and History's.
    private static let searchWidth: CGFloat = 240
    /// The header ellipsis menu's tooltip and VoiceOver name.
    private static let actionsLabel = "Meeting actions"
    /// A search hit's excerpt, at most this many lines.
    private static let snippetLines = 2

    // Test seam: internal so Selftest can reach it.
    /// The meeting the list focuses as it comes back: the one just closed,
    /// when the list being returned to shows it. A request for a row that
    /// isn't there would wait and take focus from the search box later.
    static func returnFocus(closing id: String?, listed ids: [String]) -> String? {
        guard let id, ids.contains(id) else {
            return nil
        }
        return id
    }

    // Test seam: internal so Selftest can reach it.
    /// The meeting a reload keeps open: the one requested, while the store
    /// still has it, even past the list's most recent (one opened from
    /// search). Reload never opens one itself.
    static func openMeeting(_ id: String?, in store: MeetingStore) -> MeetingRecord? {
        id.flatMap { store.recordMetadata(id: $0) }
    }

    // Test seam: internal so Selftest can reach it.
    /// What a reload does to the Transcript card, from the meeting the pane
    /// shows to the one the reload resolved.
    static func transcriptUpdate(
        shownID: String?, shownRecord: MeetingRecord?, shownReadable: Bool,
        freshID: String?, freshRecord: MeetingRecord?, freshReadable: Bool
    ) -> MeetingTranscriptLoader.Update {
        MeetingTranscriptLoader.update(
            meetingChanged: shownID != freshID,
            recordChanged: shownRecord != freshRecord,
            readableChanged: shownReadable != freshReadable)
    }

    private var selected: MeetingRecord? { selectedRecord }

    var body: some View {
        // The preference rows live in Settings › Advanced › Meetings
        // (`MeetingPreferenceRows`); this pane is the meeting memory only.
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let selected {
                    detailHeader(selected)
                } else {
                    listHeader
                }
            }
            .padding(.bottom, VeloraSpacing.m)

            // Capture and processing state sit above the list so Finish and
            // Discard stay reachable however far the list or notes scroll.
            if showsStatusRow {
                MeetingStatusCard(
                    capture: coordinator.state, processing: processor.state,
                    microphoneSilent: coordinator.microphoneSilent, coordinator: coordinator)
                    .padding(.bottom, MeetingNotesCards.sectionSpacing)
            }

            Group {
                if let selected {
                    // One scroller for notes and transcript: a nested same-axis
                    // scroller captures wheel events and strands the outer one.
                    ScrollView {
                        meetingDetail(selected)
                            .padding(.bottom, VeloraSpacing.xl)
                    }
                } else if isSearching {
                    searchResults
                } else if !loaded {
                    ProgressView()
                        .controlSize(.small)
                } else if records.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet", systemImage: "person.2.wave.2",
                        description: Text("Start one manually or let Velora suggest it when a call begins."))
                } else {
                    MeetingRowList(
                        label: "Meetings", items: records,
                        returnFocus: $returnFocusID) { record in
                        select(record.id)
                    } row: { record in
                        meetingRow(record)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in reload() }
    }

    private var listHeader: some View {
        PaneHeader(title: MainPane.meetings.title) {
            if loaded && (!records.isEmpty || isSearching) {
                SettingsSearchBox(
                    prompt: "Search meetings", query: $query,
                    accessibilityLabel: "Search summaries, decisions, actions, and transcripts")
                    .frame(width: Self.searchWidth)
                    .onChange(of: query) { _, _ in
                        // Typing moves on from the meeting just closed; its
                        // row must not take focus from the search box.
                        returnFocusID = nil
                        refreshSearch()
                    }
            }
            if coordinator.state == .idle {
                Button("Start Meeting Notes…") { coordinator.startManual() }
                    .buttonStyle(.primaryCapsule)
            }
            HeaderMenu(actions: Self.actionsLabel) {
                meetingSettingsItem
            }
        }
    }

    /// The open meeting's title in the pane header, after a back button.
    private func detailHeader(_ record: MeetingRecord) -> some View {
        HStack(spacing: VeloraSpacing.s) {
            Button { closeDetail() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.capsule)
            .keyboardShortcut("[", modifiers: .command)
            .help("All Meetings (⌘[)")
            .accessibilityLabel("All Meetings")
            PaneHeader(title: record.title) {
                detailActions(record)
            }
            // The title truncates to one line; hover shows all of it. Each
            // action sets its own help, which overrides this one.
            .help(record.title)
        }
    }

    private var meetingSettingsItem: some View {
        Button("Meeting Settings…", action: openMeetingSettings)
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
            MeetingRowList(
                label: "Search results", items: hits,
                returnFocus: $returnFocusID) { hit in
                select(hit.meetingID)
            } row: { hit in
                GroupRow(label: hit.title, sub: hit.snippet) {
                    Text(hit.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    disclosureChevron
                }
                // A long transcript match stays a two-line excerpt.
                .lineLimit(Self.snippetLines)
                .help("Open cited local meeting")
            }
        }
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func meetingRow(_ record: MeetingRecord) -> some View {
        GroupRow(label: record.title, sub: Self.rowSubtitle(record)) {
            if let badge = Self.rowBadge(record) {
                Label(badge.text, systemImage: badge.symbol)
                    .font(.caption)
                    .foregroundStyle(badge.warns ? AnyShapeStyle(VeloraStatus.warningText) : AnyShapeStyle(.secondary))
            }
            disclosureChevron
        }
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
        if case .failed = record.micIssue { return ("Mic not transcribed", "mic.slash", true) }
        if case .failed = record.systemIssue { return ("Mac audio not transcribed", "speaker.slash", true) }
        if record.micIssue == .silent { return ("Mic silent", "mic.slash", true) }
        if record.micIssue == .tooShort { return ("Mic too short", "mic.slash", true) }
        if record.notes.partial { return ("Partial notes", "exclamationmark.circle", true) }
        return nil
    }

    @ViewBuilder private func detailActions(_ record: MeetingRecord) -> some View {
        let processing = processor.isPending(meetingID: record.id)
        if selectedIsReprocessing {
            if selectedCanRecreate && !processing {
                Button("Retry Recreate") { processor.enqueue(meetingID: record.id) }
                    .buttonStyle(.capsule)
                    .help("Recreate transcript and notes again")
            }
        } else if selectedCanRetryNotes && !processing {
            Button("Retry Notes") { processor.enqueue(meetingID: record.id) }
                .buttonStyle(.capsule)
                .help("Write the notes again")
        } else if record.status != .ready && record.status != .recording
            && selectedHasRecoverableAudio && !processing {
            // A processing row no job is working on (its failure could not
            // be saved) needs a way out too.
            Button("Retry") { processor.enqueue(meetingID: record.id) }
                .buttonStyle(.capsule)
                .help("Process this meeting again")
        }
        if processing {
            Button("Cancel Processing") {
                processor.cancel(meetingID: record.id)
            }
            .buttonStyle(.capsule)
            .help("Stop processing this meeting")
        }
        HeaderMenu(actions: Self.actionsLabel) {
            Button("Copy Notes and Transcript") { copy(recordID: record.id) }
            Button("Export Markdown…") { export(record) }
            if record.status == .ready && selectedCanRecreate
                && !selectedIsReprocessing && !processing {
                Divider()
                Button("Recreate Transcript and Notes…") { reprocess(record) }
            }
            if let url = store.audioURL(relativePath: record.micPath),
               FileManager.default.fileExists(atPath: url.path) {
                Button("Play Mic Audio") { NSWorkspace.shared.open(url) }
            }
            if let url = store.audioURL(relativePath: record.systemPath),
               FileManager.default.fileExists(atPath: url.path) {
                Button("Play Mac Audio") { NSWorkspace.shared.open(url) }
            }
            if record.status != .recording {
                Divider()
                Button("Delete Meeting…", role: .destructive) { delete(record) }
            }
            Divider()
            meetingSettingsItem
        }
    }

    /// The date line and any warnings, then the notes and transcript cards.
    /// The title sits in the pane header.
    private func meetingDetail(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: MeetingNotesCards.sectionSpacing) {
            detailStatus(record)
                .padding(.horizontal, MeetingNotesCards.rowInset)
            MeetingNotesCards(notes: record.notes)
            if MeetingTranscriptCard.shows(
                status: record.status, hasTranscript: selectedHasTranscript) {
                MeetingTranscriptCard(loader: transcript)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailStatus(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            Text(Self.rowSubtitle(record))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if record.status == .processing {
                Label("Local transcription and notes are still processing.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            } else if record.status == .failed {
                Label(record.error ?? "Processing failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(VeloraStatus.warningText)
                if let caption = Self.failureCaption(
                    error: record.error, recoverable: selectedHasRecoverableAudio) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let message = record.readyErrorMessage(
                recreating: selectedIsReprocessing) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(VeloraStatus.warningText)
            }
            ForEach(Self.issueMessages(record), id: \.self) { message in
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(VeloraStatus.warningText)
            }
        }
    }

    // Test seam: internal so Selftest can reach it.
    /// The line under a failed meeting's error when its audio is gone:
    /// capture failed, the files went missing, or retention deleted them.
    /// It names no source, since any of those can empty either track, and
    /// is left out when the error already says no audio was captured.
    static func failureCaption(error: String?, recoverable: Bool) -> String? {
        guard !recoverable, error != MeetingProcessor.noUsableAudioMessage else {
            return nil
        }
        return "This meeting has no audio left to transcribe."
    }

    /// Why a ready meeting's transcript or notes are one-sided or partial.
    /// A skipped track no longer fails the meeting, so it must say so here.
    private static func issueMessages(_ record: MeetingRecord) -> [String] {
        var messages: [String] = []
        switch record.micIssue {
        case .silent:
            messages.append("Your mic recorded only silence, so the transcript has no lines from you. Check the input device before the next call.")
        case .tooShort:
            messages.append("Your mic recorded less than 0.2 seconds of audio, so the transcript has no lines from you.")
        case .failed(let error):
            messages.append("Your mic track could not be transcribed: \(error)")
        case nil:
            break
        }
        switch record.systemIssue {
        case .silent:
            messages.append("Mac audio recorded only silence, so the transcript has no lines from the other side.")
        case .tooShort:
            messages.append("Mac audio recorded less than 0.2 seconds of audio, so the transcript has no lines from the other side.")
        case .failed(let error):
            messages.append("Mac audio could not be transcribed: \(error)")
        case nil:
            break
        }
        if record.notes.partial {
            messages.append("Part of the transcript could not be summarized, so these notes may be incomplete.")
        }
        return messages
    }

    private func reload() {
        let token = UUID()
        metadataLoadToken = token
        let requestedID = selectedID
        let store = store
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = store.recentMetadata(limit: 100)
            let selected = Self.openMeeting(requestedID, in: store)
            let resolvedID = selected?.id
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
            let hasTranscript = resolvedID.map {
                store.hasCommittedSegments(meetingID: $0)
            } ?? false
            let readable = MeetingTranscriptCard.loads(
                status: selected?.status, reprocessing: reprocessing,
                notesPending: resolvedID.map { store.hasPendingNotes(meetingID: $0) } ?? false)
            DispatchQueue.main.async {
                guard metadataLoadToken == token else { return }
                let update = Self.transcriptUpdate(
                    shownID: selectedID, shownRecord: selectedRecord,
                    shownReadable: transcript.readable,
                    freshID: resolvedID, freshRecord: selected, freshReadable: readable)
                records = fresh
                loaded = true
                selectedID = resolvedID
                selectedRecord = selected
                selectedHasRecoverableAudio = recoverable
                selectedCanRetryNotes = canRetryNotes
                selectedCanRecreate = canRecreate
                selectedIsReprocessing = reprocessing
                selectedHasTranscript = hasTranscript
                switch update {
                case .show:
                    transcript.show(meetingID: resolvedID, readable: readable)
                case .refresh:
                    transcript.refresh(readable: readable)
                case .none:
                    break
                }
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
        selectedHasTranscript = false
        // Until the metadata lands, the list's row says whether its
        // transcript can be read; the completion below corrects it.
        transcript.show(
            meetingID: id,
            readable: MeetingTranscriptCard.loads(
                status: selectedRecord?.status, reprocessing: false, notesPending: false))
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
            let hasTranscript = store.hasCommittedSegments(meetingID: id)
            let readable = MeetingTranscriptCard.loads(
                status: selected?.status, reprocessing: reprocessing,
                notesPending: store.hasPendingNotes(meetingID: id))
            DispatchQueue.main.async {
                guard metadataLoadToken == token, selectedID == id else { return }
                // The list's row can be stale: a status that changed since
                // goes through the same refresh as a reload's.
                let update = MeetingTranscriptLoader.update(
                    meetingChanged: false, recordChanged: selectedRecord != selected,
                    readableChanged: transcript.readable != readable)
                selectedRecord = selected
                selectedHasRecoverableAudio = recoverable
                selectedCanRetryNotes = canRetryNotes
                selectedCanRecreate = canRecreate
                selectedIsReprocessing = reprocessing
                selectedHasTranscript = hasTranscript
                if update == .refresh {
                    transcript.refresh(readable: readable)
                }
            }
        }
    }

    private func closeDetail() {
        metadataLoadToken = UUID()
        returnFocusID = Self.returnFocus(
            closing: selectedID,
            listed: isSearching ? hits.map(\.meetingID) : records.map(\.id))
        selectedID = nil
        selectedRecord = nil
        transcript.show(meetingID: nil, readable: false)
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
        processor.reprocess(meetingID: record.id)
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
        if !Self.deleteMeeting(record.id, store: store, processor: processor) {
            deleteFailed()
        }
        reload()
    }

    // Test seam: internal so Selftest can reach it.
    /// Deletes a meeting, then forgets its processing job. A refused delete
    /// keeps the meeting, so it keeps its job too. Engine events reach the
    /// processor on main, so none lands between the two calls.
    static func deleteMeeting(
        _ id: String, store: MeetingStore, processor: MeetingProcessor
    ) -> Bool {
        guard store.delete(meetingID: id) else {
            return false
        }
        processor.cancelAndForget(meetingID: id)
        return true
    }

    /// SQLite refused the delete. The store kept the meeting whole (row,
    /// audio, search entry) and logged why; its page stays open.
    private func deleteFailed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't delete meeting"
        alert.informativeText = "The meetings database didn't accept the change, so nothing was removed. Try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Capture state and its actions, or processing progress while no capture
/// is active, as one grouped card. The states come in as values, so any one
/// can be drawn. Finish Notes is the one primary action; red marks only the
/// recording symbol, never a button.
///
///     ┌──────────────────────────────────────────────────────────┐
///     │ ◉  Recording Standup            [Discard…] [Finish Notes] │
///     │    6:12 · Mic + Mac audio                                 │
///     └──────────────────────────────────────────────────────────┘
private struct MeetingStatusCard: View {
    let capture: MeetingCoordinator.State
    let processing: MeetingProcessor.State
    let microphoneSilent: Bool
    /// Runs the buttons' actions; `capture` already carries its state.
    let coordinator: MeetingCoordinator

    /// The processing bar's widest; it narrows with the window.
    private static let progressWidth: CGFloat = 220
    /// The leading symbol's point size, as on Home's feature rows.
    private static let symbolSize: CGFloat = 15

    var body: some View {
        GroupCard {
            switch capture {
            case .idle:
                processingRow
            case .preparing(let title):
                row(symbol: "hourglass", tint: .secondary, label: title, sub: nil) {
                    ProgressView().controlSize(.small)
                }
            case .suggesting(let title, let sourceApp):
                row(
                    symbol: "video.fill", tint: VeloraStatus.warning,
                    label: "\(sourceApp ?? "Call") detected", sub: title
                ) {
                    Button("Not Now") { coordinator.declineSuggestion() }
                        .buttonStyle(.capsule)
                    Button("Start Meeting Notes") { coordinator.acceptSuggestion() }
                        .buttonStyle(.primaryCapsule)
                }
            case .recording(_, let title, let startedAt, let systemAudio, let endDetected):
                // Only this row redraws each second, for the elapsed time.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    row(
                        symbol: recordingSymbol(endDetected: endDetected),
                        tint: endDetected || microphoneSilent ? VeloraStatus.warning : VeloraStatus.danger,
                        label: endDetected ? "Did \(title) end?" : "Recording \(title)",
                        sub: Self.recordingDetail(
                            elapsed: elapsed, systemAudio: systemAudio,
                            microphoneSilent: microphoneSilent)
                    ) {
                        recordingActions(endDetected: endDetected)
                    }
                }
            }
        }
    }

    /// Background processing, shown while no capture is active.
    @ViewBuilder private var processingRow: some View {
        switch processing {
        case .idle:
            EmptyView()
        case .processing(_, let label, let fraction):
            row(symbol: "hourglass", tint: .secondary, label: label, sub: nil) {
                ProgressView(value: fraction)
                    .frame(maxWidth: Self.progressWidth)
            }
        case .failed(_, let message):
            row(
                symbol: "exclamationmark.triangle.fill", tint: VeloraStatus.warning,
                label: message, sub: nil
            ) {
                EmptyView()
            }
        }
    }

    /// A silent microphone swaps the recording dot for a warning, so the
    /// card says at a glance that "Me" will have no lines.
    private func recordingSymbol(endDetected: Bool) -> String {
        if endDetected {
            return "questionmark.circle.fill"
        }
        return microphoneSilent ? "mic.slash.fill" : "record.circle.fill"
    }

    /// Discard asks first; Finish Notes is the constructive, primary action.
    @ViewBuilder private func recordingActions(endDetected: Bool) -> some View {
        Button("Discard…") { coordinator.cancelRecording() }
            .buttonStyle(.capsule)
        if endDetected {
            Button("Keep Recording") { coordinator.keepMeetingRecording() }
                .buttonStyle(.capsule)
            Button("Finish Notes") { coordinator.confirmMeetingEnded() }
                .buttonStyle(.primaryCapsule)
        } else {
            Button("Finish Notes") { coordinator.stopRecording() }
                .buttonStyle(.primaryCapsule)
        }
    }

    /// A `GroupRow` after a tinted status symbol, like Home's feature rows.
    private func row<Trailing: View>(
        symbol: String, tint: Color, label: String, sub: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: VeloraSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: Self.symbolSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: WindowShellMetrics.symbolWell)
                .accessibilityHidden(true)
            GroupRow(label: label, sub: sub, trailing: trailing)
                // The symbol takes the row's leading inset.
                .padding(.leading, -MeetingNotesCards.rowInset)
        }
        .padding(.leading, MeetingNotesCards.rowInset)
    }

    /// "6:12 · Mic + Mac audio", then "Mic is silent" while it is.
    private static func recordingDetail(
        elapsed: Int, systemAudio: Bool, microphoneSilent: Bool
    ) -> String {
        var parts = [
            "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))",
            MeetingCoordinator.sourcesLabel(systemAudio: systemAudio),
        ]
        if microphoneSilent {
            parts.append("Mic is silent")
        }
        return parts.joined(separator: " · ")
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

// Test seam: internal so Selftest can reach it.
/// A scrolling card of meeting rows that a click, VoiceOver or the
/// keyboard opens. Rows are not Buttons, so the card is one Tab stop the
/// arrows move within (`MeetingListKeys`), with Dictionary's focus mark:
/// an accent tint and a 2 pt accent edge, which gives the 3:1 a focus ring
/// needs. The focused row scrolls into view as it moves.
struct MeetingRowList<Item: Identifiable, Row: View>: View where Item.ID == String {
    let label: String
    let items: [Item]
    /// The meeting to focus as the list appears: the one just closed. The
    /// list clears it once read, so a list that comes back later (a search
    /// cleared from the search box) leaves focus where it is.
    @Binding var returnFocus: String?
    let open: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    @FocusState private var focusedID: String?
    /// The last row that had focus, which Tab returns to.
    @State private var lastFocusedID: String?

    /// Dictionary's focus mark: tint, edge, and inset from the card.
    private static var focusTint: Double { 0.14 }
    private static var focusStroke: CGFloat { 2 }
    private static var focusInset: CGFloat { 4 }

    var body: some View {
        let ids = items.map(\.id)
        let tabStop = MeetingListKeys.tabStop(lastFocusedID, in: ids)
        ScrollViewReader { proxy in
            ScrollView {
                card(ids: ids, tabStop: tabStop)
                    .padding(.bottom, VeloraSpacing.xl)
            }
            // Keep the focused row on screen as Tab and the arrows move,
            // and remember it as the list's Tab stop.
            .onChange(of: focusedID) { _, id in
                guard let id else {
                    return
                }
                lastFocusedID = id
                proxy.scrollTo(id)
            }
        }
        .onAppear { focusReturningRow(ids: ids) }
    }

    private func card(ids: [String], tabStop: String?) -> some View {
        GroupCard {
            // The ForEach ID is each row's scroll ID. The divider sits inside
            // the row's stack: as a sibling it was what `scrollTo` revealed,
            // leaving the row itself just out of view.
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 {
                        GroupDivider()
                    }
                    row(item)
                        .contentShape(Rectangle())
                        .background(focusMark(item.id == focusedID))
                        .onTapGesture { open(item) }
                        // Only the Tab stop row is focusable, so Tab lands on
                        // one row and the arrows walk the rest.
                        .focusable(item.id == tabStop, interactions: .edit)
                        .focused($focusedID, equals: item.id)
                        .focusEffectDisabled()
                        .onKeyPress(keys: MeetingListKeys.keys) { press in
                            handle(press.key, on: item, ids: ids)
                        }
                        // Each row still reads and acts as one button.
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { open(item) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// Back from a meeting, focus lands on its row. The row becomes the Tab
    /// stop first, so it is focusable when focus arrives.
    private func focusReturningRow(ids: [String]) {
        guard let id = returnFocus else {
            return
        }
        returnFocus = nil
        guard ids.contains(id) else {
            return
        }
        lastFocusedID = id
        focusedID = id
    }

    private func handle(_ key: KeyEquivalent, on item: Item, ids: [String]) -> KeyPress.Result {
        guard let command = MeetingListKeys.command(for: key, on: item.id, in: ids) else {
            return .ignored
        }
        switch command {
        case .focus(let id):
            // Move the Tab stop first so the row is focusable when focus lands.
            lastFocusedID = id
            focusedID = id
        case .open:
            open(item)
        }
        return .handled
    }

    @ViewBuilder private func focusMark(_ focused: Bool) -> some View {
        if focused {
            let shape = RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous)
            shape
                .fill(VeloraBrand.accent.opacity(Self.focusTint))
                .overlay(shape.strokeBorder(VeloraBrand.accent, lineWidth: Self.focusStroke))
                .padding(.horizontal, Self.focusInset)
        }
    }
}

// Test seam: internal so Selftest can reach it.
/// The meetings list and search results from the keyboard, as Dictionary's
/// entries work: the list is one Tab stop, the arrows move within it, and
/// Return or Space opens the focused meeting.
///
///     Tab ──▶ ┌ Product review ┐ ◀─ last focused row, else the first
///             │ Design review  │  ↑ ↓ move, stopping at the ends
///             └ Weekly sync    ┘  ⏎ or Space opens
enum MeetingListKeys {
    enum Command: Equatable {
        case focus(String)
        case open(String)
    }

    /// The keys a focused row handles; every other key passes through.
    static let keys: Set<KeyEquivalent> = [.upArrow, .downArrow, .return, .space]

    static func tabStop(_ lastFocused: String?, in ids: [String]) -> String? {
        if let lastFocused, ids.contains(lastFocused) {
            return lastFocused
        }
        return ids.first
    }

    static func command(for key: KeyEquivalent, on id: String, in ids: [String]) -> Command? {
        guard let index = ids.firstIndex(of: id) else {
            return nil
        }
        switch key {
        case .upArrow:
            return index > 0 ? .focus(ids[index - 1]) : nil
        case .downArrow:
            return index + 1 < ids.count ? .focus(ids[index + 1]) : nil
        case .return, .space:
            return .open(id)
        default:
            return nil
        }
    }
}
