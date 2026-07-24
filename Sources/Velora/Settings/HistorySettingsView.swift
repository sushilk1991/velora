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
    /// How long to wait for a reprocess reply before showing "failed". Stable
    /// failures arrive immediately; this is the final defense for disconnects.
    private static let reprocessTimeout: TimeInterval = 90

    init(history: HistoryStore, supervisor: EngineSupervisor?) {
        self.history = history
        self.supervisor = supervisor
        reprocessObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineReprocessed, object: nil, queue: .main
        ) { [weak self] note in
            if case let .reprocessed(
                id, _, raw, text, mode, _, sttMs, cleanupMs, cleanupApplied,
                cleanupWallMs
            )? =
                note.object as? EngineEvent {
                self?.applyReprocessed(
                    id: id, raw: raw, text: text, mode: mode,
                    sttMs: sttMs, cleanupMs: cleanupMs,
                    cleanupApplied: cleanupApplied, cleanupWallMs: cleanupWallMs)
            } else if case let .reprocessFailed(id, _, _)? = note.object as? EngineEvent {
                self?.applyReprocessFailed(id: id)
            }
        }
        reload()
    }

    deinit {
        if let reprocessObserver { NotificationCenter.default.removeObserver(reprocessObserver) }
    }

    // MARK: - Loading

    /// Reloads the first page for the current search term. (Usage stats moved
    /// to the Stats tab — History is purely the transcript list now.)
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
        guard !record.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(record.final, forType: .string)
    }

    /// Puts the text back on the clipboard and pastes it into the app it came
    /// from (best effort — needs Accessibility, degrades to a plain copy).
    func pasteAgain(_ record: DictationRecord) {
        TextInserter.insertAgain(record)
    }

    /// Saves a user-edited transcript. The quality verdict about the original
    /// insertion described the old text, so the store clears it.
    func saveEdit(_ record: DictationRecord, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.final else { return }
        history.updateFinal(id: record.id, final: trimmed)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            let old = records[index]
            records[index] = DictationRecord(
                id: old.id, timestamp: old.timestamp, bundleID: old.bundleID,
                appName: old.appName, raw: old.raw, final: trimmed,
                mode: old.mode, durationMs: old.durationMs,
                cleanupMs: old.cleanupMs, cleanupWallMs: old.cleanupWallMs,
                finalizationMs: old.finalizationMs,
                audioPath: old.audioPath,
                sessionID: old.sessionID, sttMs: old.sttMs,
                cleanupApplied: old.cleanupApplied)
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

        // A stable failure normally clears this immediately; retain a timeout
        // for a process crash or dropped control connection.
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

    private func applyReprocessed(
        id: Int64?, raw: String, text: String, mode: String?,
        sttMs: Int, cleanupMs: Int, cleanupApplied: Bool, cleanupWallMs: Int?
    ) {
        guard let id else { return }
        history.updateAfterReprocess(
            id: id, raw: raw, final: text, mode: mode,
            sttMs: sttMs, cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
            cleanupWallMs: cleanupWallMs)
        if let index = records.firstIndex(where: { $0.id == id }) {
            let old = records[index]
            records[index] = DictationRecord(
                id: old.id, timestamp: old.timestamp, bundleID: old.bundleID,
                appName: old.appName, raw: raw, final: text,
                mode: mode ?? old.mode, durationMs: old.durationMs,
                cleanupMs: cleanupMs, cleanupWallMs: cleanupWallMs,
                finalizationMs: nil,
                audioPath: old.audioPath,
                sessionID: old.sessionID, sttMs: sttMs,
                cleanupApplied: cleanupApplied)
        }
        // A later request supersedes this reply's pending timeout.
        reprocessGen[id] = (reprocessGen[id] ?? 0) + 1
        inFlight.remove(id)
        failed.remove(id)
    }

    private func applyReprocessFailed(id: Int64?) {
        guard let id else { return }
        reprocessGen[id] = (reprocessGen[id] ?? 0) + 1
        inFlight.remove(id)
        failed.insert(id)
    }

    // MARK: - Audio playback

    /// Whether the archived clip for this record exists on disk.
    func canPlay(_ record: DictationRecord) -> Bool {
        guard let name = record.audioPath,
              let url = AppConfig.archivedAudioURL(name: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func togglePlayback(_ record: DictationRecord) {
        guard let name = record.audioPath,
              let url = AppConfig.archivedAudioURL(name: name) else { return }
        if playing == name { stopPlayback(); return }
        stopPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.requestStatus()
            vm.reload()  // fresh rows every time the tab appears
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: VeloraSpacing.s) {
            SettingsSearchBox(prompt: "Search transcripts", query: $vm.searchText)

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
                LazyVStack(alignment: .leading, spacing: VeloraSpacing.l, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.records, id: \.id) { record in
                                HistoryCard(
                                    record: record,
                                    isPlaying: vm.playing == record.audioPath,
                                    isReprocessing: vm.inFlight.contains(record.id),
                                    reprocessFailed: vm.failed.contains(record.id),
                                    sttModels: model.sttEngineModels,
                                    onCopy: { vm.copy(record) },
                                    onPaste: { vm.pasteAgain(record) },
                                    onEdit: { text in vm.saveEdit(record, newText: text) },
                                    onReprocess: { stt, mode in vm.reprocess(record, sttModel: stt, mode: mode) },
                                    onPlay: vm.canPlay(record) ? { vm.togglePlayback(record) } : nil,
                                    onDelete: { vm.delete(record) })
                                .onAppear {
                                    if record.id == vm.records.last?.id { vm.loadMore() }
                                }
                            }
                        } header: {
                            sectionHeader(section.title, count: section.records.count)
                        }
                    }
                    if vm.hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VeloraSpacing.s)
                    }
                }
                .padding(.horizontal, VeloraSpacing.m)
                .padding(.vertical, VeloraSpacing.m)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: VeloraSpacing.xs) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color(.separatorColor).opacity(0.4)))
            Spacer()
        }
        .padding(.vertical, VeloraSpacing.xs)
        .padding(.horizontal, VeloraSpacing.xs)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    /// Groups the loaded records (already newest-first) into date buckets,
    /// preserving order.
    private var sections: [DateSection] {
        var result: [DateSection] = []
        var index: [String: Int] = [:]
        for record in vm.records {
            let title = Self.bucket(for: record.timestamp)
            if let i = index[title] {
                result[i].records.append(record)
            } else {
                index[title] = result.count
                result.append(DateSection(title: title, records: [record]))
            }
        }
        return result
    }

    private struct DateSection {
        let title: String
        var records: [DictationRecord]
    }

    private static func bucket(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return "Previous 7 Days"
        }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 30 {
            return "Previous 30 Days"
        }
        return Self.monthFormatter.string(from: date)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

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

// MARK: - Card

private struct HistoryCard: View {
    let record: DictationRecord
    let isPlaying: Bool
    let isReprocessing: Bool
    let reprocessFailed: Bool
    let sttModels: [EngineModel]
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onEdit: (String) -> Void
    let onReprocess: (_ sttModel: String?, _ mode: String?) -> Void
    let onPlay: (() -> Void)?
    let onDelete: () -> Void

    @State private var expanded = false
    @State private var showRaw = false
    @State private var hovering = false
    @State private var copied = false
    @State private var editing = false
    @State private var editDraft = ""

    /// Built-in modes offered in the reprocess menu (mirrors the Modes editor).
    private static let builtInModes = ["Default", "Message", "Email", "Note", "Code", "Raw"]

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            header
            transcript
            if reprocessFailed {
                Label("Reprocess failed — try again", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider().opacity(hovering ? 0.5 : 0.25)
            actions
        }
        .padding(VeloraSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    hovering ? VeloraBrand.violet.color.opacity(0.45) : Color(.separatorColor).opacity(0.7),
                    lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.18 : 0.06),
                radius: hovering ? 8 : 3, x: 0, y: hovering ? 3 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .sheet(isPresented: $editing) { editSheet }
    }

    // MARK: Edit sheet

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            Text("Edit Transcript")
                .font(.headline)
            TextEditor(text: $editDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(VeloraSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(.separatorColor)))
                .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onEdit(editDraft)
                    editing = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VeloraSpacing.xl)
        .frame(width: 460, height: 280)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: VeloraSpacing.s) {
            appIconTile
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: VeloraSpacing.xs) {
                    Text(record.appName ?? "Unknown app")
                        .font(.callout.weight(.semibold))
                    if let mode = record.mode, !mode.isEmpty {
                        Text(mode.capitalized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(VeloraBrand.violet.color.opacity(0.16)))
                            .foregroundStyle(VeloraBrand.violet.color)
                    }
                }
                Text(Self.metaLine(record))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(Self.relative(record.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var appIconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(.separatorColor).opacity(0.25))
                .frame(width: 30, height: 30)
            if let icon = Self.appIcon(record.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VeloraBrand.violet.color)
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hasTranscript ? record.final : "No transcript — reprocess the saved audio")
                .font(.body)
                .foregroundStyle(hasTranscript ? .primary : .secondary)
                .italic(!hasTranscript)
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if Self.isLong(record.final) {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(VeloraBrand.violet.color)
            }
            if hasDistinctRaw {
                Button(showRaw ? "Hide original" : "As heard") {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help("What the speech model transcribed, before cleanup")
                if showRaw {
                    Text(record.raw)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(VeloraSpacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(.separatorColor).opacity(0.18)))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard Self.isLong(record.final) else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: VeloraSpacing.s) {
            if hasTranscript {
                actionButton(
                    copied ? "checkmark" : "doc.on.doc",
                    copied ? "Copied" : "Copy",
                    tint: copied ? Color(nsColor: .systemGreen) : nil
                ) {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }

                actionButton("arrow.uturn.left", "Paste again", action: onPaste)

                actionButton("pencil", "Edit transcript") {
                    editDraft = record.final
                    editing = true
                }
            }

            reprocessMenu

            if let onPlay {
                actionButton(isPlaying ? "stop.fill" : "play.fill",
                             isPlaying ? "Stop" : "Play audio",
                             tint: isPlaying ? VeloraBrand.violet.color : nil,
                             action: onPlay)
            }

            Spacer()

            actionButton("trash", "Delete", tint: .secondary, hoverTint: .red, action: onDelete)
        }
    }

    private var reprocessMenu: some View {
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
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(record.audioPath == nil ? Color.secondary.opacity(0.5) : .secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22)
        .disabled(record.audioPath == nil || isReprocessing)
        .help(record.audioPath == nil
              ? "No audio archived for this dictation"
              : "Re-run with a different model or mode")
    }

    @State private var hoveredButton: String?

    private func actionButton(
        _ symbol: String, _ help: String,
        tint: Color? = nil, hoverTint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredButton == help
        let color = isHovered ? (hoverTint ?? tint ?? .primary) : (tint ?? .secondary)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color(.separatorColor).opacity(0.35) : .clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hoveredButton = $0 ? help : (hoveredButton == help ? nil : hoveredButton) }
    }

    // MARK: Helpers

    private var hasTranscript: Bool {
        !record.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Raw is worth showing only when cleanup actually changed something.
    private var hasDistinctRaw: Bool {
        let raw = record.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != record.final.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLong(_ text: String) -> Bool {
        text.count > 140 || text.contains("\n")
    }

    private static func metaLine(_ record: DictationRecord) -> String {
        if record.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Needs reprocessing"
        }
        var parts: [String] = []
        let words = record.final.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        parts.append("\(words) word\(words == 1 ? "" : "s")")
        if record.durationMs > 0 {
            parts.append(String(format: "%.1fs", Double(record.durationMs) / 1000))
        }
        return parts.joined(separator: " · ")
    }

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
