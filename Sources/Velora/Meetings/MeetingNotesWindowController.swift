import AppKit
import Combine
import SwiftUI

/// Loads the useful note shell first and the potentially large transcript only
/// when requested. All SQLite work stays off AppKit's main thread.
final class MeetingNotesWindowModel: ObservableObject {
    @Published private(set) var record: MeetingRecord?
    /// A Recreate is staged for this meeting; a ready row's error is then
    /// the Recreate's, not the notes'.
    @Published private(set) var recreating = false
    /// The meeting has transcript lines; the Transcript card is left out
    /// when it would only offer "Show" over nothing.
    @Published private(set) var hasTranscript = false
    @Published private(set) var loading = false
    @Published private(set) var actionError: String?
    /// The Transcript card: whether it is open, and its lines.
    let transcript: MeetingTranscriptLoader
    let playback: MeetingAudioPlayback

    let store: MeetingStore
    private var meetingID: String?
    private var metadataToken = UUID()
    private var exportToken = UUID()
    private var presented = false
    /// `show` asked for the lines to be read again. The reload that lands
    /// reads them and clears this: a notification's reload can replace the
    /// one `show` started, and must not lose that read.
    private var pendingForcedRead = false

    init(store: MeetingStore) {
        self.store = store
        transcript = MeetingTranscriptLoader(store: store)
        playback = MeetingAudioPlayback(store: store)
    }

    /// Opens a meeting. Another meeting's Transcript card starts closed. The
    /// meeting already showing (Retry Notes or Recreate presenting its new
    /// notes) keeps its card and reads its lines again: a Recreate whose
    /// notes match the old ones changes only the lines, which the metadata
    /// `reload` compares leaves out.
    func show(meetingID: String) {
        presented = true
        actionError = nil
        if self.meetingID != meetingID {
            playback.configure(nil)
            self.meetingID = meetingID
            record = nil
            pendingForcedRead = false
            transcript.show(meetingID: meetingID, readable: false)
        } else {
            pendingForcedRead = true
        }
        exportToken = UUID()
        reload()
    }

    func reload() {
        guard let meetingID else { return }
        let token = UUID()
        metadataToken = token
        loading = record == nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fresh = self.store.recordMetadata(id: meetingID)
            let recreating = self.store.isReprocessing(meetingID: meetingID)
            let hasTranscript = self.store.hasCommittedSegments(meetingID: meetingID)
            let readable = MeetingTranscriptCard.loads(
                status: fresh?.status, reprocessing: recreating,
                notesPending: self.store.hasPendingNotes(meetingID: meetingID))
            DispatchQueue.main.async {
                guard self.metadataToken == token, self.meetingID == meetingID else { return }
                let update = MeetingTranscriptLoader.update(
                    meetingChanged: false, recordChanged: self.record != fresh,
                    readableChanged: self.transcript.readable != readable)
                self.record = fresh
                self.playback.configure(fresh)
                self.recreating = recreating
                self.hasTranscript = hasTranscript
                self.loading = false
                // One read either way: a changed record reads, and so does
                // an unchanged one that `show` asked to read.
                let forced = self.pendingForcedRead
                self.pendingForcedRead = false
                if update == .refresh || forced {
                    self.transcript.refresh(readable: readable)
                }
            }
        }
    }

    /// The window closed: its meeting reopens with the Transcript card
    /// closed, as it did in 0.25.0.
    func windowClosed() {
        presented = false
        playback.stop()
        exportToken = UUID()
        transcript.reset()
    }

    func setAction(_ action: String, completed: Bool, completion: @escaping (Bool) -> Void) {
        guard let meetingID else { completion(false); return }
        store.setActionCompletedAsync(meetingID: meetingID, action: action, completed: completed) { [weak self] saved in
            completion(saved)
            guard let self, self.isShowing(meetingID) else { return }
            self.actionError = saved ? nil : "This action changed or could not be saved. Open the meeting again and retry."
        }
    }

    func isShowing(_ id: String) -> Bool { presented && meetingID == id && record?.id == id }

    func loadExport(format: MeetingExportFormat = .markdown, completion: @escaping (String) -> Void) {
        guard let meetingID else { return }
        let token = UUID()
        exportToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text = self.store.record(id: meetingID)?.export(format: format) ?? ""
            DispatchQueue.main.async {
                guard self.exportToken == token, self.meetingID == meetingID else { return }
                completion(text)
            }
        }
    }
}

/// Dedicated post-meeting note surface. Settings remain the control plane;
/// this window is deliberately just the finished artifact. It wears the
/// shell's paint (canvas, glow, transparent titlebar) with the header below
/// the traffic lights, as About does.
///
///     ●●●
///     Product review                          [Copy All]   22 pt PaneTitle
///     15 November 2023 at 3:43 AM
///     Summary / Decisions / Action items / Transcript     GroupCards
struct MeetingNotesWindowView: View {
    @ObservedObject var model: MeetingNotesWindowModel
    var processor: MeetingProcessor? = nil
    @State private var subtitleRecord: MeetingRecord?
    /// A long meeting title wraps to at most this many lines.
    private static let titleLines = 2

    var body: some View {
        Group {
            if let record = model.record {
                VStack(alignment: .leading, spacing: 0) {
                    header(record)
                        .padding(.bottom, VeloraSpacing.m)
                    ScrollView {
                        VStack(alignment: .leading, spacing: MeetingNotesCards.sectionSpacing) {
                            status(record)
                            MeetingPlaybackControls(playback: model.playback)
                            MeetingIntelligenceCards(record: record, store: model.store, playback: model.playback,
                                onToggleAction: model.setAction,
                                showTranscript: { model.transcript.setExpanded(true) })
                            if let error = model.actionError {
                                Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText)
                            }
                            if MeetingTranscriptCard.shows(
                                status: record.status, hasTranscript: model.hasTranscript) {
                                MeetingPlayableTranscriptCard(loader: model.transcript, playback: model.playback)
                            }
                        }
                        .padding(.bottom, VeloraSpacing.xl)
                    }
                }
                .padding(.horizontal, VeloraSpacing.xl)
            } else if model.loading {
                ProgressView("Opening meeting notes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Meeting not found",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("The meeting may have been deleted."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, WindowShellMetrics.trafficLightClearance)
        .background(WindowGlow())
        .background(VeloraPanel.canvas)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in
            model.reload()
        }
        .sheet(item: $subtitleRecord) { record in
            MeetingSubtitleSheet(record: record, store: model.store,
                isReady: { processor?.canProcessLibraryAudio ?? false },
                send: { processor?.sendLibraryRequest($0) })
        }
    }

    private func header(_ record: MeetingRecord) -> some View {
        HStack(alignment: .center, spacing: VeloraSpacing.m) {
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                // PaneTitle's type, but a long title wraps to a second line
                // and can be selected to copy.
                Text(record.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .lineLimit(Self.titleLines)
                    .textSelection(.enabled)
                Text(record.startedAt.formatted(date: .long, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: VeloraSpacing.m)
            Button {
                model.loadExport { text in
                    guard !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .buttonStyle(.capsule)
            MeetingRecapDraftButton(text: record.followUpText).buttonStyle(.capsule)
            Menu {
                Button("Copy Follow-up") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.followUpText, forType: .string)
                }
                Divider()
                ForEach(MeetingExportFormat.allCases) { format in
                    Button("Export \(format.title)…") { export(record, format: format) }
                }
                Button(L10n.text("Generate subtitles…")) { subtitleRecord = record }
                    .disabled(record.status == .recording || processor == nil || (record.micPath == nil && record.systemPath == nil))
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Meeting export and follow-up")
        }
    }

    private func export(_ record: MeetingRecord, format: MeetingExportFormat) {
        model.loadExport(format: format) { text in
            guard !text.isEmpty, model.isShowing(record.id) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(record.title.replacingOccurrences(of: "/", with: "-")) notes.\(format.fileExtension)"
            if format.usesCueTiming { panel.message = MeetingExportFormat.timingNotice }
            panel.begin { response in
                guard response == .OK, model.isShowing(record.id), let url = panel.url else { return }
                do { try text.write(to: url, atomically: true, encoding: .utf8) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }

    @ViewBuilder
    private func status(_ record: MeetingRecord) -> some View {
        switch record.status {
        case .ready:
            if let message = record.readyErrorMessage(recreating: model.recreating) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(VeloraStatus.warningText)
            }
        case .recording:
            // Red on the glyph only: red text misses 4.5:1 in light mode.
            Label {
                Text("Recording is still in progress")
            } icon: {
                Image(systemName: "record.circle").foregroundStyle(VeloraStatus.danger)
            }
            .foregroundStyle(.secondary)
        case .processing:
            Label("Transcript and notes are still processing", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .failed:
            Label(record.error ?? "Meeting processing failed",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(VeloraStatus.warningText)
        }
    }
}

/// A meeting's notes as grouped cards, shared by the Meetings pane and the
/// notes window. Action checkboxes persist through the supplied store callback;
/// read-only callers keep the same plain-bullet presentation.
///
///     Summary
///     ┌──────────────────────────────────────┐
///     │ The review aligned on a focused plan │
///     └──────────────────────────────────────┘
///     Action items
///     ┌──────────────────────────────────────┐
///     │ • Me: prepare the implementation plan│
///     └──────────────────────────────────────┘
struct MeetingNotesCards: View {
    let notes: MeetingNotes
    var onToggleAction: ((String, Bool, @escaping (Bool) -> Void) -> Void)? = nil
    var sourceFor: ((String) -> MeetingSourceReference?)? = nil
    var onShowSource: ((MeetingSourceReference) -> Void)? = nil
    @State private var pending: [String: (id: UUID, value: Bool, saved: Bool)] = [:]

    /// Space between cards, as on Home and Modes.
    static let sectionSpacing: CGFloat = 18
    /// A `GroupRow`'s leading and trailing inset, for card text drawn
    /// without one.
    static let rowInset: CGFloat = 14

    var body: some View {
        if !notes.summary.isEmpty {
            GroupCard(header: "Summary") {
                VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                    Text(notes.summary).textSelection(.enabled)
                    sourceLink(notes.summary)
                }.modifier(MeetingCardText())
            }
        }
        if !notes.decisions.isEmpty {
            GroupCard(header: "Decisions") { bullets(notes.decisions) }
        }
        if !notes.actionItems.isEmpty {
            GroupCard(header: "Action items") {
                if let onToggleAction {
                    VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                        ForEach(Array(notes.actionItems.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                            Toggle(item, isOn: Binding(
                                get: { pending[item]?.value ?? notes.completedActionItems.contains(item) },
                                set: { value in
                                    let token = UUID()
                                    pending[item] = (token, value, false)
                                    onToggleAction(item, value) { saved in
                                        guard pending[item]?.id == token else { return }
                                        if !saved || notes.completedActionItems.contains(item) == value { pending.removeValue(forKey: item) }
                                        else { pending[item] = (token, value, true) }
                                    }
                                }))
                                .toggleStyle(.checkbox)
                                .fixedSize(horizontal: false, vertical: true)
                            sourceLink(item)
                            }
                        }
                    }
                    .modifier(MeetingCardText())
                } else {
                    bullets(notes.actionItems)
                }
            }
            .onChange(of: notes) { latest in
                pending = pending.filter { action, state in
                    latest.actionItems.contains(action)
                        && !(state.saved && latest.completedActionItems.contains(action) == state.value)
                }
            }
        }
    }

    @ViewBuilder private func sourceLink(_ text: String) -> some View {
        if let source = sourceFor?(text), let onShowSource {
            Button("Related passage") { onShowSource(source) }
                .font(.caption).help("Review the related exact transcript passage")
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.s) {
                    Text("•")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                        Text(item).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        sourceLink(item)
                    }
                }
            }
        }
        .modifier(MeetingCardText())
    }
}

/// The transcript as a grouped card whose header link shows or hides it.
/// Its open state and lines come from `MeetingTranscriptLoader`.
struct MeetingTranscriptCard: View {
    @ObservedObject var loader: MeetingTranscriptLoader
    var onSeek: ((MeetingSegment) -> Void)? = nil
    var activeSegmentID: Int64? = nil

    // Test seam: internal so Selftest can reach it.
    /// Whether a meeting gets the card: always while processing, whose
    /// lines land after the one read of `hasTranscript`, else only when
    /// there are lines to show.
    static func shows(status: MeetingStatus, hasTranscript: Bool) -> Bool {
        status == .processing || hasTranscript
    }

    /// Whether a meeting's transcript may be read. Its first transcription
    /// commits lines without a notification, so a read then would stick;
    /// Retry Notes and a Recreate run over a finished transcript.
    static func loads(status: MeetingStatus?, reprocessing: Bool, notesPending: Bool) -> Bool {
        status != .processing || reprocessing || notesPending
    }

    // Test seam: internal so Selftest can reach it.
    /// VoiceOver's name and state for the header link, which shows only
    /// "Show" or "Hide" on screen.
    static func linkAccessibility(expanded: Bool) -> (label: String, value: String) {
        expanded ? ("Hide Transcript", "Expanded") : ("Show Transcript", "Collapsed")
    }

    var body: some View {
        GroupCard(
            header: "Transcript",
            headerLink: (loader.expanded ? "Hide" : "Show", { loader.setExpanded(!loader.expanded) }),
            headerLinkAccessibility: Self.linkAccessibility(expanded: loader.expanded)
        ) {
            if loader.expanded {
                content
                    .modifier(MeetingCardText())
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !loader.readable {
            Text("The transcript appears when processing finishes.")
                .foregroundStyle(.secondary)
        } else if let segments = loader.segments {
            // A re-read keeps these on screen until the new lines land.
            if segments.isEmpty {
                Text("No transcript is available.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: VeloraSpacing.m) {
                    ForEach(segments) { segment in
                        row(segment)
                    }
                }
            }
        } else {
            ProgressView("Loading transcript…")
                .controlSize(.small)
        }
    }

    private func row(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: VeloraSpacing.m) {
            if let onSeek {
                Button { onSeek(segment) } label: {
                    Text(Self.clock(segment.startMs))
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, alignment: .leading)
                .accessibilityLabel("Play \(segment.speaker.displayName) at \(Self.clock(segment.startMs))")
            } else {
                Text(Self.clock(segment.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                Text(segment.speaker.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(segment.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
        .background(activeSegmentID == segment.id ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private static func clock(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// One meeting's Transcript card, shared by the Meetings pane and the
/// notes window: whether it is open, and the lines it shows. Lines are
/// read off the main thread only while the card is open and the transcript
/// can be read (`MeetingTranscriptCard.loads`). Lines commit without a
/// notification, so a changed record reads an open card's lines again,
/// keeping the old ones on screen so the reader keeps their place.
///
///     show(meeting) ──▶ closed, no lines
///     open ──▶ readable? ──yes──▶ Loading… ──▶ lines
///                  └──no──▶ "appears when processing finishes"
///     refresh(readable) ──▶ open and readable: old lines stay ──▶ new lines
///                      └──▶ closed or unreadable: lines dropped
///     hide ──▶ read stopped, lines kept ──▶ show ──▶ lines ──▶ read again
final class MeetingTranscriptLoader: ObservableObject {
    /// What a fresh look at the open meeting does to its card.
    enum Update: Equatable {
        /// Another meeting: its card starts closed (`show`).
        case show
        /// The same meeting's record or readability changed (`refresh`).
        case refresh
        case none
    }

    // Test seam: internal so Selftest can reach it.
    static func update(meetingChanged: Bool, recordChanged: Bool, readableChanged: Bool) -> Update {
        if meetingChanged {
            return .show
        }
        return recordChanged || readableChanged ? .refresh : .none
    }

    @Published private(set) var expanded = false
    /// The transcript can be read now (`MeetingTranscriptCard.loads`).
    @Published private(set) var readable = false
    @Published private(set) var segments: [MeetingSegment]?
    @Published private(set) var loading = false
    // Test seam: internal so Selftest can reach it.
    /// Reads started, so a test can tell one read from two.
    private(set) var readCount = 0

    private let store: MeetingStore
    private var meetingID: String?
    private var token = UUID()

    init(store: MeetingStore) {
        self.store = store
    }

    /// Another meeting, or none: its card starts closed.
    func show(meetingID: String?, readable: Bool) {
        self.meetingID = meetingID
        self.readable = readable
        reset()
    }

    /// Closes the card and forgets its lines: another meeting, or the notes
    /// window closing.
    func reset() {
        expanded = false
        drop()
    }

    /// The meeting's record changed, so its cached lines may be stale. An
    /// open card stays open and reads them again, showing the old lines
    /// until the new ones land. A closed or unreadable card has none.
    func refresh(readable: Bool) {
        self.readable = readable
        guard expanded, readable else {
            drop()
            return
        }
        read()
    }

    /// Hide stops a read in flight and keeps the lines, so Show puts them
    /// back at once, as 0.25.0 did, and reads them again behind them, as
    /// `refresh` does.
    func setExpanded(_ expanded: Bool) {
        self.expanded = expanded
        guard expanded else {
            cancelRead()
            return
        }
        guard readable, !loading else {
            return
        }
        read()
    }

    /// Ignores a read still running: its result never lands.
    private func cancelRead() {
        token = UUID()
        loading = false
    }

    /// Forgets the lines and any read still running.
    private func drop() {
        cancelRead()
        segments = nil
    }

    private func read() {
        guard let meetingID else {
            return
        }
        let token = UUID()
        self.token = token
        loading = true
        readCount += 1
        let store = store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let segments = store.record(id: meetingID)?.segments ?? []
            DispatchQueue.main.async {
                guard let self, self.token == token, self.meetingID == meetingID else {
                    return
                }
                self.segments = segments
                self.loading = false
            }
        }
    }
}

/// 13 pt row text filling a `GroupCard`, inset like a `GroupRow`.
private struct MeetingCardText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MeetingNotesCards.rowInset)
            .padding(.vertical, VeloraSpacing.m)
    }
}

final class MeetingNotesWindowController: NSWindowController, NSWindowDelegate {
    /// Opening size, and the smallest the notes still read at.
    private static let contentSize = NSSize(width: 760, height: 680)
    private static let minimumSize = NSSize(width: 620, height: 480)
    private static let frameAutosaveName = "VeloraMeetingNotes"

    // Test seam: internal so Selftest can reach it.
    let model: MeetingNotesWindowModel
    private var holdsActivation = false

    init(store: MeetingStore, processor: MeetingProcessor? = nil) {
        model = MeetingNotesWindowModel(store: store)
        let root = MeetingNotesWindowView(model: model, processor: processor)
        // The shared shell factory: it paints the shell's titlebar and keeps
        // the hosting controller from growing the window to its content.
        let window = MainWindowController.makeShellWindow(
            rootView: root, title: "Meeting Notes",
            size: Self.contentSize, minimumSize: Self.minimumSize)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(meetingID: String) {
        // Reopens at the size and place the user left it: AppKit restores
        // the saved frame here and saves each move or resize. Set on the
        // first show, not in init or makeShellWindow, so selftest and
        // harness windows, which never come through here, never save one:
        // the bare binary's defaults are the installed app's.
        if let window, window.frameAutosaveName != Self.frameAutosaveName {
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        model.show(meetingID: meetingID)
        MainWindowController.presentShell(self, holding: &holdsActivation)
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }
}
