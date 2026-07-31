import AppKit
import Combine
import SwiftUI

/// Loads the useful note shell first and the potentially large transcript only
/// when requested. All SQLite work stays off AppKit's main thread.
final class MeetingNotesWindowModel: ObservableObject {
    @Published private(set) var record: MeetingRecord?
    @Published private(set) var loading = false
    @Published private(set) var transcript: [MeetingSegment]?
    @Published private(set) var transcriptLoading = false
    @Published private(set) var presentationToken = UUID()

    private let store: MeetingStore
    private var meetingID: String?
    private var metadataToken = UUID()
    private var transcriptToken = UUID()
    private var exportToken = UUID()

    init(store: MeetingStore) {
        self.store = store
    }

    func show(meetingID: String) {
        presentationToken = UUID()
        if self.meetingID != meetingID {
            self.meetingID = meetingID
            record = nil
        }
        transcriptToken = UUID()
        exportToken = UUID()
        transcript = nil
        transcriptLoading = false
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
            DispatchQueue.main.async {
                guard self.metadataToken == token, self.meetingID == meetingID else { return }
                self.record = fresh
                self.loading = false
            }
        }
    }

    func loadTranscript() {
        guard let meetingID, transcript == nil, !transcriptLoading else { return }
        let token = UUID()
        transcriptToken = token
        transcriptLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let segments = self.store.record(id: meetingID)?.segments ?? []
            DispatchQueue.main.async {
                guard self.transcriptToken == token, self.meetingID == meetingID else { return }
                self.transcript = segments
                self.transcriptLoading = false
            }
        }
    }

    func loadExport(completion: @escaping (String) -> Void) {
        guard let meetingID else { return }
        let token = UUID()
        exportToken = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text = self.store.record(id: meetingID)?.exportText ?? ""
            DispatchQueue.main.async {
                guard self.exportToken == token, self.meetingID == meetingID else { return }
                completion(text)
            }
        }
    }
}

/// Dedicated post-meeting note surface. Settings remain the control plane;
/// this window is deliberately just the finished artifact.
struct MeetingNotesWindowView: View {
    @ObservedObject var model: MeetingNotesWindowModel
    @State private var transcriptExpanded = false

    var body: some View {
        Group {
            if let record = model.record {
                ScrollView {
                    VStack(alignment: .leading, spacing: VeloraSpacing.xl) {
                        header(record)
                        status(record)
                        if !record.notes.summary.isEmpty {
                            section("Summary", text: record.notes.summary)
                        }
                        if !record.notes.decisions.isEmpty {
                            section(
                                "Decisions",
                                text: record.notes.decisions.map { "• \($0)" }
                                    .joined(separator: "\n"))
                        }
                        if !record.notes.actionItems.isEmpty {
                            section(
                                "Action items",
                                text: record.notes.actionItems.map { "☐ \($0)" }
                                    .joined(separator: "\n"))
                        }
                        transcript
                    }
                    .padding(VeloraSpacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.presentationToken) { _, _ in
            transcriptExpanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .veloraMeetingsChanged)) { _ in
            model.reload()
        }
    }

    private func header(_ record: MeetingRecord) -> some View {
        HStack(alignment: .top, spacing: VeloraSpacing.l) {
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                Text(record.title)
                    .font(.system(size: 26, weight: .semibold))
                    .textSelection(.enabled)
                Text(record.startedAt.formatted(date: .long, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: VeloraSpacing.l)
            Button {
                model.loadExport { text in
                    guard !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            } label: {
                Label("Copy all", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func status(_ record: MeetingRecord) -> some View {
        switch record.status {
        case .ready:
            if let error = record.error {
                Label(
                    "Recreate did not finish; the previous notes were kept. \(error)",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        case .recording:
            Label("Recording is still in progress", systemImage: "record.circle")
                .foregroundStyle(.red)
        case .processing:
            Label("Transcript and notes are still processing", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .failed:
            Label(record.error ?? "Meeting processing failed",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func section(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcript: some View {
        DisclosureGroup(isExpanded: $transcriptExpanded) {
            Group {
                if model.transcriptLoading {
                    ProgressView("Loading transcript…")
                        .padding(.vertical, VeloraSpacing.m)
                } else if let segments = model.transcript {
                    if segments.isEmpty {
                        Text("No transcript is available.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: VeloraSpacing.m) {
                            ForEach(segments) { segment in
                                transcriptRow(segment)
                            }
                        }
                    }
                }
            }
            .padding(.top, VeloraSpacing.s)
        } label: {
            Text("Transcript")
                .font(.headline)
        }
        .onChange(of: transcriptExpanded) { _, expanded in
            if expanded { model.loadTranscript() }
        }
    }

    private func transcriptRow(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: VeloraSpacing.m) {
            Text(Self.clock(segment.startMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
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

    private static func clock(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

final class MeetingNotesWindowController: NSWindowController, NSWindowDelegate {
    private let model: MeetingNotesWindowModel
    private var holdsActivation = false

    init(store: MeetingStore) {
        model = MeetingNotesWindowModel(store: store)
        let root = MeetingNotesWindowView(model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Meeting Notes"
        window.setContentSize(NSSize(width: 760, height: 680))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(meetingID: String) {
        model.show(meetingID: meetingID)
        if !holdsActivation {
            holdsActivation = true
            AppActivation.acquireRegular()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }
}
