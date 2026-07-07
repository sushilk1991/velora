import AppKit
import AVFoundation
import SwiftUI

/// Backs the History tab: a paged, searchable view over `HistoryStore` plus the
/// live `reprocess` round-trip. Owns audio playback and reprocess-in-flight
/// state. Main-thread only (all mutation happens from SwiftUI / notifications).
final class HistoryViewModel: ObservableObject {
    /// Rows loaded so far (newest first), grown by `loadMore`.
    @Published var records: [DictationRecord] = []
    @Published var searchText: String = ""
    /// Row ids currently awaiting a `reprocessed` reply (spinner on the row).
    @Published var inFlight: Set<Int64> = []
    /// Row ids whose last reprocess failed or timed out (brief inline notice).
    @Published var failed: Set<Int64> = []
    /// Basename of the clip currently playing, if any.
    @Published var playing: String?
    @Published private(set) var hasMore = false
    @Published private(set) var isEmpty = false

    private let history: HistoryStore
    private weak var supervisor: EngineSupervisor?
    private var reprocessObserver: NSObjectProtocol?
    private var player: AVAudioPlayer?
    /// Per-row reprocess generation: a later request invalidates an earlier
    /// request's timeout so it can't clear the fresh in-flight state.
    private var reprocessGen: [Int64: Int] = [:]
    /// Monotonic playback token so a stale end-timer can't stop a later replay.
    private var playGeneration = 0

    private static let pageSize = 50
    /// How long to wait for a `reprocessed` reply before showing "failed"
    /// (engine failures arrive as plain `error` events with no row id).
    private static let reprocessTimeout: TimeInterval = 90

    init(history: HistoryStore, supervisor: EngineSupervisor?) {
        self.history = history
        self.supervisor = supervisor
        reprocessObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineReprocessed, object: nil, queue: .main
        ) { [weak self] note in
            if case let .reprocessed(id, _, raw, text, mode, _, _, _, _)? =
                note.object as? EngineEvent {
                self?.applyReprocessed(id: id, raw: raw, text: text, mode: mode)
            }
        }
        reload()
    }

    deinit {
        if let reprocessObserver { NotificationCenter.default.removeObserver(reprocessObserver) }
    }

    // MARK: - Loading

    /// Reloads the first page for the current search term.
    func reload() {
        let term = searchText
        records = history.page(limit: Self.pageSize, offset: 0, search: term)
        hasMore = records.count == Self.pageSize
        isEmpty = records.isEmpty
    }

    /// Appends the next page when the list scrolls to the bottom.
    func loadMore() {
        guard hasMore else { return }
        let next = history.page(limit: Self.pageSize, offset: records.count, search: searchText)
        records.append(contentsOf: next)
        hasMore = next.count == Self.pageSize
    }

    // MARK: - Row actions

    func copy(_ record: DictationRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(record.final, forType: .string)
    }

    /// Puts the text back on the clipboard and pastes it into the app it came
    /// from (best effort — needs Accessibility, degrades to a plain copy).
    func pasteAgain(_ record: DictationRecord) {
        let inserter = TextInserter()
        inserter.copyToClipboard(record.final)
        if let bundleID = record.bundleID,
           let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                inserter.insert(record.final, targetBundleID: bundleID)
            }
        }
    }

    func delete(_ record: DictationRecord) {
        history.delete(id: record.id)
        records.removeAll { $0.id == record.id }
        isEmpty = records.isEmpty
    }

    func clearAll() {
        stopPlayback()
        history.deleteAll()
        records = []
        hasMore = false
        isEmpty = true
    }

    // MARK: - Reprocess

    /// Reprocesses a row. `sttModel`/`mode` are the user's explicit menu picks;
    /// nil means "reuse the original". The record's full context is always sent
    /// so the engine reproduces the same formatting (a speech-model-only
    /// reprocess must not silently fall back to the Default mode).
    func reprocess(_ record: DictationRecord, sttModel: String?, mode: String?) {
        guard let audio = record.audioPath else { return }
        let id = record.id
        let gen = (reprocessGen[id] ?? 0) + 1
        reprocessGen[id] = gen
        failed.remove(id)
        inFlight.insert(id)
        supervisor?.send(reprocessCommand(record: record, audio: audio, sttModel: sttModel, mode: mode))

        // Engine failures come back as plain `error` events with no row id, so
        // fall back to a timeout to release the spinner and flag the row.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reprocessTimeout) { [weak self] in
            guard let self, self.reprocessGen[id] == gen, self.inFlight.contains(id) else { return }
            self.inFlight.remove(id)
            self.failed.insert(id)
        }
    }

    private func reprocessCommand(
        record: DictationRecord, audio: String, sttModel: String?, mode: String?
    ) -> [String: Any] {
        var command: [String: Any] = ["cmd": "reprocess", "audio": audio, "id": record.id]
        if let sttModel { command["stt_model"] = sttModel }
        // Preserve the original mode unless the user explicitly picked another,
        // plus the app context that drives auto mode selection.
        if let effectiveMode = mode ?? record.mode { command["mode"] = effectiveMode }
        if let bundleID = record.bundleID { command["bundle_id"] = bundleID }
        if let appName = record.appName { command["app_name"] = appName }
        return command
    }

    private func applyReprocessed(id: Int64?, raw: String, text: String, mode: String?) {
        guard let id else { return }
        history.updateAfterReprocess(id: id, raw: raw, final: text, mode: mode)
        if let index = records.firstIndex(where: { $0.id == id }) {
            let old = records[index]
            records[index] = DictationRecord(
                id: old.id, timestamp: old.timestamp, bundleID: old.bundleID,
                appName: old.appName, raw: raw, final: text,
                mode: mode ?? old.mode, durationMs: old.durationMs,
                cleanupMs: old.cleanupMs, audioPath: old.audioPath)
        }
        // A later request supersedes this reply's pending timeout.
        reprocessGen[id] = (reprocessGen[id] ?? 0) + 1
        inFlight.remove(id)
        failed.remove(id)
    }

    // MARK: - Audio playback

    /// Whether the archived clip for this record exists on disk.
    func canPlay(_ record: DictationRecord) -> Bool {
        guard let name = record.audioPath else { return false }
        return FileManager.default.fileExists(atPath: audioURL(name).path)
    }

    func togglePlayback(_ record: DictationRecord) {
        guard let name = record.audioPath else { return }
        if playing == name { stopPlayback(); return }
        stopPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: audioURL(name)) else { return }
        self.player = player
        playing = name
        player.play()
        // Poll for natural end (AVAudioPlayerDelegate needs @objc conformance;
        // a lightweight timer keeps this file self-contained). Capture the
        // playback generation so a stale timer can't stop a later replay — even
        // of the same clip basename.
        playGeneration += 1
        let generation = playGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) { [weak self] in
            guard let self, self.playGeneration == generation else { return }
            self.stopPlayback()
        }
    }

    private func stopPlayback() {
        // Bump the generation so any in-flight end-timer is invalidated.
        playGeneration += 1
        player?.stop()
        player = nil
        playing = nil
    }

    private func audioURL(_ name: String) -> URL {
        AppConfig.audioDirectory.appendingPathComponent(name)
    }
}

// MARK: - View

struct HistorySettingsView: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var vm: HistoryViewModel
    @State private var showClearConfirm = false

    init(model: SettingsModel, history: HistoryStore, supervisor: EngineSupervisor?) {
        self.model = model
        _vm = StateObject(wrappedValue: HistoryViewModel(history: history, supervisor: supervisor))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(width: 580, height: SettingsTab.history.preferredHeight)
        .onAppear { model.requestStatus() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: VeloraSpacing.s) {
            HStack(spacing: VeloraSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $vm.searchText)
                    .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, VeloraSpacing.s)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(.separatorColor)))

            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(vm.records.isEmpty)
            .confirmationDialog(
                "Delete all dictation history?", isPresented: $showClearConfirm
            ) {
                Button("Delete All History", role: .destructive) { vm.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes every saved transcript. Audio clips age out separately.")
            }
        }
        .padding(VeloraSpacing.m)
        .onChange(of: vm.searchText) { vm.reload() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if vm.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.records, id: \.id) { record in
                        HistoryRow(
                            record: record,
                            isPlaying: vm.playing == record.audioPath,
                            isReprocessing: vm.inFlight.contains(record.id),
                            reprocessFailed: vm.failed.contains(record.id),
                            sttModels: model.sttEngineModels,
                            onCopy: { vm.copy(record) },
                            onPaste: { vm.pasteAgain(record) },
                            onReprocess: { stt, mode in vm.reprocess(record, sttModel: stt, mode: mode) },
                            onPlay: vm.canPlay(record) ? { vm.togglePlayback(record) } : nil,
                            onDelete: { vm.delete(record) })
                        .onAppear {
                            if record.id == vm.records.last?.id { vm.loadMore() }
                        }
                        Divider().padding(.leading, VeloraSpacing.m)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: VeloraSpacing.m) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(VeloraBrand.iconGradient)
            Text(vm.searchText.isEmpty ? "No dictations yet" : "No matches")
                .font(.title3.weight(.semibold))
            Text(vm.searchText.isEmpty
                 ? "Your transcripts appear here. Everything stays on this Mac."
                 : "Try a different search term.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(VeloraSpacing.xl)
    }
}

// MARK: - Row

private struct HistoryRow: View {
    let record: DictationRecord
    let isPlaying: Bool
    let isReprocessing: Bool
    let reprocessFailed: Bool
    let sttModels: [EngineModel]
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onReprocess: (_ sttModel: String?, _ mode: String?) -> Void
    let onPlay: (() -> Void)?
    let onDelete: () -> Void

    @State private var expanded = false
    @State private var hovering = false

    /// Built-in modes offered in the reprocess menu (mirrors the Modes editor).
    private static let builtInModes = ["Default", "Message", "Email", "Note", "Code", "Raw"]

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            header
            Text(record.final)
                .font(.body)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
            if reprocessFailed {
                Label("Reprocess failed — try again", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            actions
                .opacity(hovering || isReprocessing || isPlaying || reprocessFailed ? 1 : 0.55)
        }
        .padding(VeloraSpacing.m)
        .background(hovering ? Color(.selectedContentBackgroundColor).opacity(0.08) : .clear)
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: VeloraSpacing.s) {
            if let icon = Self.appIcon(record.bundleID) {
                Image(nsImage: icon)
                    .resizable().frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(record.appName ?? "Unknown app")
                .font(.callout.weight(.medium))
            if let mode = record.mode, !mode.isEmpty {
                Text(mode.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(VeloraBrand.violet.color.opacity(0.15)))
                    .foregroundStyle(VeloraBrand.violet.color)
            }
            Spacer()
            Text(Self.relative(record.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: VeloraSpacing.m) {
            iconButton("doc.on.doc", "Copy", action: onCopy)
            iconButton("arrow.uturn.left", "Paste again", action: onPaste)

            Menu {
                Section("Speech model") {
                    if sttModels.isEmpty {
                        Button("Reprocess with current model") { onReprocess(nil, nil) }
                    } else {
                        ForEach(sttModels) { m in
                            Button(m.displayName) { onReprocess(m.id, nil) }
                        }
                    }
                }
                Section("Mode") {
                    ForEach(Self.builtInModes, id: \.self) { mode in
                        Button(mode) { onReprocess(nil, mode) }
                    }
                }
            } label: {
                if isReprocessing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(record.audioPath == nil || isReprocessing)
            .help(record.audioPath == nil ? "No audio archived for this dictation" : "Re-run with a different model or mode")

            if let onPlay {
                iconButton(isPlaying ? "stop.fill" : "play.fill",
                           isPlaying ? "Stop" : "Play audio", action: onPlay)
            }
            Spacer()
            iconButton("trash", "Delete", role: .destructive, action: onDelete)
        }
        .font(.callout)
    }

    private func iconButton(
        _ symbol: String, _ help: String,
        role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Helpers

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Cached app icons keyed by bundle id (icon lookups touch disk).
    private static var iconCache: [String: NSImage] = [:]

    private static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = icon
        return icon
    }
}
