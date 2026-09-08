import AppKit
import AVFoundation
import Combine
import SwiftUI

enum HistoryClearPolicy {
    static let confirmationMessage =
        "This permanently deletes every saved transcript and its archived audio. This can't be undone."
}

/// Backs the History tab: a paged, searchable view over `HistoryStore` plus the
/// live `reprocess` round-trip. Owns audio playback and reprocess-in-flight
/// state. Main-thread only (all mutation happens from SwiftUI / notifications).
final class HistoryViewModel: ObservableObject {
    /// Rows loaded so far (newest first), grown by `loadMore`.
    @Published var records: [DictationRecord] = []
    @Published var searchText: String = ""
    /// App name the journal is narrowed to; nil shows every app.
    @Published var appFilter: String?
    /// The one entry open in place (the journal expands a single row at a time).
    @Published var expandedID: Int64?
    /// Row ids currently awaiting a `reprocessed` reply (spinner on the row).
    @Published var inFlight: Set<Int64> = []
    /// Row ids whose last reprocess failed or timed out (brief inline notice).
    @Published var failed: Set<Int64> = []
    /// Basename of the clip currently playing, if any.
    @Published var playing: String?
    @Published private(set) var hasMore = false
    @Published private(set) var isEmpty = false
    /// Distinct app names seen in the store, most frequent first (feeds the
    /// "All apps" popup). Bounded by `summaryScanCap` rows.
    @Published private(set) var appNames: [String] = []
    /// Dictations since the start of the current calendar month (footer).
    @Published private(set) var monthCount = 0

    private let history: HistoryStore
    private weak var supervisor: EngineSupervisor?
    private var reprocessObserver: NSObjectProtocol?
    private var searchObserver: AnyCancellable?
    private var player: AVAudioPlayer?
    /// Per-row reprocess generation: a later request invalidates an earlier
    /// request's timeout so it can't clear the fresh in-flight state.
    private var reprocessGen: [Int64: Int] = [:]
    /// Monotonic playback token so a stale end-timer can't stop a later replay.
    private var playGeneration = 0
    /// Summary scans race the user's edits; only the newest scan may land.
    private var summaryGeneration = 0

    private static let pageSize = 50
    /// Most rows the app-name / month-count scan reads (newest first) so a
    /// huge history can't stream entirely into memory.
    private static let summaryScanCap = 5_000
    /// How long to wait for a reprocess reply before showing "failed". Stable
    /// failures arrive immediately; this is the final defense for disconnects.
    private static let reprocessTimeout: TimeInterval = 90
    /// Keystroke debounce before the search re-queries the store.
    private static let searchDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(150)

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
        // The search box lives in the pane header (a separate view from the
        // journal), so the model itself reacts to typing rather than either
        // view owning an `onChange`.
        searchObserver = $searchText
            .dropFirst()
            .removeDuplicates()
            .debounce(for: Self.searchDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
        reload()
        refreshSummary()
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
        expandedID = nil
        fillFilteredPage()
    }

    /// Appends the next page when the list scrolls to the bottom. With an
    /// app filter on, a page that adds no visible row would leave the last
    /// visible row (and its `onAppear` trigger) unchanged, so keep paging
    /// until something new shows or the store runs dry (bounded).
    func loadMore() {
        guard hasMore else { return }
        let visibleBefore = visibleRecords.count
        var rounds = 0
        repeat {
            appendPage()
            rounds += 1
        } while appFilter != nil && hasMore && visibleRecords.count == visibleBefore
            && rounds < Self.summaryScanCap / Self.pageSize
    }

    private func appendPage() {
        let next = history.page(limit: Self.pageSize, offset: records.count, search: searchText)
        records.append(contentsOf: next)
        hasMore = next.count == Self.pageSize
    }

    /// The loaded rows narrowed to `appFilter`. The store has no app column
    /// filter, so the narrowing is client-side over the loaded pages.
    var visibleRecords: [DictationRecord] {
        guard let appFilter else { return records }
        return records.filter { $0.appName == appFilter }
    }

    /// Keeps loading pages until the app-filtered view shows at least one
    /// page's worth of rows (or the store runs dry), so picking a rarely used
    /// app doesn't leave the journal blank with more rows still unloaded.
    ///
    ///     loaded:  [S S S M S S ... ]  filter = M
    ///     visible: [      M         ]  → loadMore until ≥ pageSize or !hasMore
    func fillFilteredPage() {
        guard appFilter != nil else { return }
        var rounds = 0
        while hasMore, visibleRecords.count < Self.pageSize, rounds < Self.summaryScanCap / Self.pageSize {
            appendPage()
            rounds += 1
        }
    }

    /// Recomputes the popup's app names and the footer's month count from a
    /// bounded newest-first scan, off the main thread.
    func refreshSummary() {
        summaryGeneration += 1
        let generation = summaryGeneration
        let store = history
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = Self.scanSummary(store: store, monthStart: monthStart)
            DispatchQueue.main.async {
                guard let self, self.summaryGeneration == generation else { return }
                self.appNames = summary.appNames
                self.monthCount = summary.monthCount
                if let appFilter = self.appFilter, !summary.appNames.contains(appFilter) {
                    self.appFilter = nil
                }
            }
        }
    }

    private struct Summary {
        var appNames: [String] = []
        var monthCount = 0
    }

    private static func scanSummary(store: HistoryStore, monthStart: Date) -> Summary {
        var frequency: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var monthCount = 0
        var offset = 0
        while offset < summaryScanCap {
            let page = store.page(limit: pageSize, offset: offset, search: nil)
            for record in page {
                if record.timestamp >= monthStart { monthCount += 1 }
                guard let app = record.appName, !app.isEmpty else { continue }
                frequency[app, default: 0] += 1
                if firstSeen[app] == nil { firstSeen[app] = offset }
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        // Most used first; ties fall back to most recently seen.
        let names = frequency.keys.sorted {
            let (a, b) = (frequency[$0] ?? 0, frequency[$1] ?? 0)
            if a != b { return a > b }
            return (firstSeen[$0] ?? 0) < (firstSeen[$1] ?? 0)
        }
        return Summary(appNames: names, monthCount: monthCount)
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
        if expandedID == record.id { expandedID = nil }
        refreshSummary()
    }

    func clearAll() {
        stopPlayback()
        history.deleteAll()
        records = []
        hasMore = false
        isEmpty = true
        expandedID = nil
        refreshSummary()
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

// MARK: - Journal maths (pure, selftested)

/// Pure helpers behind the journal: day headings, per-day and per-entry meta
/// lines, and the footer's retention phrase. No SwiftUI, so the selftest can
/// pin the wording against fixed dates.
enum HistoryJournal {
    /// Rows the mono typeface applies to: terminal and code modes.
    private static let codeModeMarkers = ["code", "terminal", "shell"]

    /// "Today", "Yesterday", or the weekday date ("Monday 1 September").
    static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return weekdayFormatter.string(from: date)
    }

    /// Stable key so records land in one bucket per local calendar day.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// "26 dictations · 2,217 words · 14 min".
    static func dayMeta(count: Int, words: Int, durationMs: Int) -> String {
        var parts = [plural(count, "dictation"), plural(words, "word")]
        if durationMs > 0 { parts.append(spoken(ms: durationMs)) }
        return parts.joined(separator: " · ")
    }

    /// "Default · 33 words · 15.8 s · ready in 0.9 s". A row with no text
    /// says so instead, since its numbers would describe nothing.
    static func entryMeta(_ record: DictationRecord) -> String {
        guard hasTranscript(record) else { return "Needs reprocessing" }
        var parts: [String] = [modeName(record.mode), plural(wordCount(record.final), "word")]
        if record.durationMs > 0 {
            parts.append(String(format: "%.1f s", Double(record.durationMs) / 1000))
        }
        if let ready = record.finalizationMs, ready > 0 {
            parts.append("ready in " + latency(ms: ready))
        }
        return parts.joined(separator: " · ")
    }

    /// Mode label shown in meta lines: the stored name, "Default" when unset.
    static func modeName(_ mode: String?) -> String {
        guard let mode, !mode.isEmpty else { return "Default" }
        return mode.prefix(1).uppercased() + mode.dropFirst()
    }

    static func isCodeMode(_ mode: String?) -> Bool {
        guard let mode = mode?.lowercased() else { return false }
        return codeModeMarkers.contains { mode.contains($0) }
    }

    static func hasTranscript(_ record: DictationRecord) -> Bool {
        !record.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Raw is worth showing only when cleanup actually changed something.
    static func hasDistinctRaw(_ record: DictationRecord) -> Bool {
        let raw = record.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != record.final.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whitespace-separated token count, the same estimate the store's SQL uses.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// "<N> this month · audio kept for 6 months". The retention clause is
    /// dropped when clips aren't kept at all.
    static func footer(monthCount: Int, retentionDays: Double) -> String {
        var parts = ["\(grouped(monthCount)) this month"]
        if let kept = retentionPhrase(days: retentionDays) {
            parts.append("audio kept for " + kept)
        }
        return parts.joined(separator: " · ")
    }

    /// Whole years / months when the window divides evenly, else days.
    static func retentionPhrase(days: Double) -> String? {
        let whole = Int(days.rounded())
        guard whole > 0 else { return nil }
        if whole % 365 == 0 { return plural(whole / 365, "year") }
        if whole % 30 == 0 { return plural(whole / 30, "month") }
        return plural(whole, "day")
    }

    /// "1 h 5 min", "14 min", "48 s".
    static func spoken(ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "640 ms" under a second, "0.9 s" above.
    static func latency(ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    static func plural(_ n: Int, _ noun: String) -> String {
        "\(grouped(n)) \(noun)\(n == 1 ? "" : "s")"
    }

    static func grouped(_ n: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    /// Fixed 24-hour "13:21": a 12-hour "12:30 PM" overruns the 56 pt gutter.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// App icons keyed by bundle id (icon lookups touch disk, so they're cached).
private enum AppIconLookup {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

/// An app's icon at `side`, falling back to the waveform glyph on a tinted
/// tile when the app isn't installed any more.
private struct AppIconView: View {
    let bundleID: String?
    let side: CGFloat

    var body: some View {
        if let icon = AppIconLookup.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: side * 0.55, weight: .semibold))
                .foregroundStyle(VeloraBrand.accent)
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Header controls

/// The History pane's title-row controls: a 240 pt search box and the
/// "All apps" popup. The shell places this beside its `PaneHeader`.
struct HistoryHeaderControls: View {
    @ObservedObject var viewModel: HistoryViewModel

    private static let searchWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: VeloraSpacing.s) {
            SettingsSearchBox(prompt: "Search what you said", query: $viewModel.searchText)
                .frame(width: Self.searchWidth)
            Picker("App", selection: $viewModel.appFilter) {
                Text("All apps").tag(String?.none)
                if !viewModel.appNames.isEmpty {
                    Divider()
                    ForEach(viewModel.appNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Filter by app")
            .onChange(of: viewModel.appFilter) { viewModel.fillFilteredPage() }
        }
    }
}

// MARK: - Pane

/// The journal: one running page of dictations grouped by day, newest
/// first, 720 pt wide and centred. The shell draws the title and
/// `HistoryHeaderControls` above it.
///
///     Today.        26 dictations · 2,217 words · 14 min
///     13:21  ▣ Slack   Default · 33 words · 15.8 s
///            Final text of the dictation …
///     13:04  ▣ Notes   Note · 120 words · 48.0 s
///            …
///     Yesterday.    …
struct HistorySettingsView: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var vm: HistoryViewModel
    @State private var showClearConfirm = false

    private static let columnWidth: CGFloat = 720
    private static let daySpacing: CGFloat = 28
    private static let entrySpacing: CGFloat = 18

    init(model: SettingsModel, history: HistoryStore, supervisor: EngineSupervisor?) {
        self.model = model
        _vm = StateObject(wrappedValue: HistoryViewModel(history: history, supervisor: supervisor))
    }

    /// Shell entry point: the window owns one view model shared with
    /// `HistoryHeaderControls`.
    init(model: SettingsModel, viewModel: HistoryViewModel) {
        self.model = model
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                model.requestStatus()
                vm.reload()  // fresh rows every time the tab appears
                vm.refreshSummary()
            }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isEmpty || (vm.appFilter != nil && vm.visibleRecords.isEmpty && !vm.hasMore) {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Self.daySpacing) {
                    ForEach(days, id: \.key) { day in
                        daySection(day)
                    }
                    if vm.hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    }
                    footer
                }
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, VeloraSpacing.xl)
            }
        }
    }

    // MARK: Day sections

    private struct JournalDay {
        let key: Date
        let label: String
        var records: [DictationRecord]

        var meta: String {
            HistoryJournal.dayMeta(
                count: records.count,
                words: records.reduce(0) { $0 + HistoryJournal.wordCount($1.final) },
                durationMs: records.reduce(0) { $0 + $1.durationMs })
        }
    }

    /// Groups the visible rows (already newest-first) by local day,
    /// preserving order.
    private var days: [JournalDay] {
        var result: [JournalDay] = []
        var index: [Date: Int] = [:]
        for record in vm.visibleRecords {
            let key = HistoryJournal.dayKey(for: record.timestamp)
            if let i = index[key] {
                result[i].records.append(record)
                continue
            }
            index[key] = result.count
            result.append(JournalDay(
                key: key, label: HistoryJournal.dayLabel(for: record.timestamp),
                records: [record]))
        }
        return result
    }

    private func daySection(_ day: JournalDay) -> some View {
        VStack(alignment: .leading, spacing: Self.entrySpacing) {
            HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.m) {
                SerifHeadline(day.label)
                Text(day.meta)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ForEach(day.records, id: \.id) { record in
                JournalEntry(
                    record: record,
                    expanded: vm.expandedID == record.id,
                    isPlaying: record.audioPath != nil && vm.playing == record.audioPath,
                    isReprocessing: vm.inFlight.contains(record.id),
                    reprocessFailed: vm.failed.contains(record.id),
                    hasAudio: vm.canPlay(record),
                    sttModels: model.sttEngineModels,
                    onToggle: { toggle(record) },
                    onCopy: { vm.copy(record) },
                    onPaste: { vm.pasteAgain(record) },
                    onEdit: { text in vm.saveEdit(record, newText: text) },
                    onReprocess: { stt, mode in vm.reprocess(record, sttModel: stt, mode: mode) },
                    onPlay: { vm.togglePlayback(record) },
                    onDelete: { vm.delete(record) })
                .onAppear {
                    if record.id == vm.visibleRecords.last?.id { vm.loadMore() }
                }
            }
        }
    }

    private func toggle(_ record: DictationRecord) {
        withAnimation(VeloraMotion.standard) {
            vm.expandedID = vm.expandedID == record.id ? nil : record.id
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: VeloraSpacing.xs) {
            Text(HistoryJournal.footer(
                monthCount: vm.monthCount, retentionDays: model.audioRetentionDays))
            Text("·")
            Button("Delete All…") { showClearConfirm = true }
                .buttonStyle(.plain)
                .foregroundStyle(VeloraBrand.link)
                .confirmationDialog(
                    "Delete all dictation history?", isPresented: $showClearConfirm
                ) {
                    Button("Delete All History", role: .destructive) { vm.clearAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(HistoryClearPolicy.confirmationMessage)
                }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, VeloraSpacing.m)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            Spacer()
            SerifHeadline(vm.searchText.isEmpty && vm.appFilter == nil ? "Nothing yet" : "No matches")
            Text(vm.searchText.isEmpty && vm.appFilter == nil
                 ? "Your dictations show up here. Everything stays on this Mac."
                 : "Try a different search or app.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Journal entry

/// One dictation in the journal. Collapsed: a 56 pt time gutter beside the
/// app line and the final text. Expanded (one at a time): a raised card with
/// the full text, the raw transcript, and the action capsules.
///
///     13:21 │ ▣ Slack  Default · 33 words · 15.8 s
///           │ Final text …
///
///     ┌────────────────────────────────────────────┐ raised, radius 12
///     │ 13:21  ▣ Slack  Default · 33 words · 15.8 s │
///     │ Full final text …                          │
///     │ ┌ As heard · before cleanup ─────────────┐ │
///     │ │ raw transcript                          │ │
///     │ └────────────────────────────────────────┘ │
///     │ (Copy)(Insert Again)(Edit)(Reprocess ▸)(Play)   (🗑) │
///     └────────────────────────────────────────────┘
private struct JournalEntry: View {
    let record: DictationRecord
    let expanded: Bool
    let isPlaying: Bool
    let isReprocessing: Bool
    let reprocessFailed: Bool
    let hasAudio: Bool
    let sttModels: [EngineModel]
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onEdit: (String) -> Void
    let onReprocess: (_ sttModel: String?, _ mode: String?) -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void

    @State private var copied = false
    @State private var editing = false
    @State private var editDraft = ""

    private static let timeColumn: CGFloat = 56
    private static let iconSide: CGFloat = 18
    private static let textSize: CGFloat = 14
    private static let expandedTextSize: CGFloat = 14.5
    private static let codeTextSize: CGFloat = 12.5
    /// Extra leading that lifts the system font's ~1.2 line height to the
    /// journal's 1.45 (14 pt → about 3.5 pt between lines).
    private static let extraLeadingRatio: CGFloat = 0.25
    private static let rawRadius: CGFloat = 9
    private static let rawFill = 0.06
    private static let copiedFlash: TimeInterval = 1.2

    /// Built-in modes offered in the reprocess menu (mirrors the Modes editor).
    private static let builtInModes = ["Default", "Message", "Email", "Note", "Code", "Raw"]

    private var isCode: Bool { HistoryJournal.isCodeMode(record.mode) }
    private var hasTranscript: Bool { HistoryJournal.hasTranscript(record) }

    var body: some View {
        Group {
            if expanded {
                expandedCard
            } else {
                collapsedRow
            }
        }
        .sheet(isPresented: $editing) { editSheet }
    }

    // MARK: Collapsed

    private var collapsedRow: some View {
        HStack(alignment: .top, spacing: 0) {
            timeLabel
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                appLine
                transcript(size: Self.textSize, lineLimit: nil)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Expands the dictation")
    }

    // MARK: Expanded

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            HStack(alignment: .center, spacing: 0) {
                timeLabel
                appLine
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            transcript(size: Self.expandedTextSize, lineLimit: nil)
                .padding(.leading, Self.timeColumn)

            if HistoryJournal.hasDistinctRaw(record) {
                rawBox
                    .padding(.leading, Self.timeColumn)
            }

            if reprocessFailed {
                Label("Reprocess failed — try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warning)
                    .padding(.leading, Self.timeColumn)
            }

            toolbar
                .padding(.leading, Self.timeColumn)
        }
        .padding(VeloraSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                .fill(VeloraPanel.raised))
        .overlay(
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                .strokeBorder(VeloraPanel.hairline, lineWidth: 1))
    }

    private var rawBox: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text("As heard · before cleanup")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(record.raw)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VeloraSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: Self.rawRadius, style: .continuous)
                .fill(Color.primary.opacity(Self.rawFill)))
    }

    // MARK: Shared pieces

    private var timeLabel: some View {
        Text(HistoryJournal.timeFormatter.string(from: record.timestamp))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: Self.timeColumn, alignment: .leading)
    }

    private var appLine: some View {
        HStack(spacing: VeloraSpacing.xs + 2) {
            AppIconView(bundleID: record.bundleID, side: Self.iconSide)
            Text(record.appName ?? "Unknown app")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(HistoryJournal.entryMeta(record))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func transcript(size: CGFloat, lineLimit: Int?) -> some View {
        let pointSize = isCode ? Self.codeTextSize : size
        return Text(hasTranscript ? record.final : "No transcript — reprocess the saved audio")
            .font(.system(size: pointSize, design: isCode ? .monospaced : .default))
            .lineSpacing(pointSize * Self.extraLeadingRatio)
            .foregroundStyle(hasTranscript ? .primary : .secondary)
            .italic(!hasTranscript)
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: VeloraSpacing.s) {
            if hasTranscript {
                Button(copied ? "Copied" : "Copy") {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFlash) { copied = false }
                }
                .buttonStyle(.capsule)
                Button("Insert Again", action: onPaste)
                    .buttonStyle(.capsule)
                    .help("Copy; if the original app is open, switch there and try to paste")
                Button("Edit") {
                    editDraft = record.final
                    editing = true
                }
                .buttonStyle(.capsule)
            }
            reprocessMenu
            if hasAudio {
                Button(isPlaying ? "Stop" : "Play", action: onPlay)
                    .buttonStyle(.capsule)
            }
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.capsule)
            .help("Delete this transcript permanently")
            .accessibilityLabel("Delete")
        }
    }

    /// The reprocess menu dressed as a capsule so it sits with the buttons.
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
            HStack(spacing: VeloraSpacing.xs) {
                if isReprocessing {
                    ProgressView().controlSize(.mini)
                }
                Text("Reprocess ▸")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, VeloraSpacing.m)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous)
                .fill(Color.primary.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous)
                .strokeBorder(VeloraPanel.hairline, lineWidth: 1))
        .disabled(!hasAudio || isReprocessing)
        .opacity(hasAudio ? 1 : 0.5)
        .help(hasAudio
              ? "Re-transcribe the saved audio with another model or mode"
              : "Reprocessing unavailable — no saved audio for this dictation")
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
                    RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                        .fill(VeloraPanel.card))
                .overlay(
                    RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
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
}

// MARK: - Home pane: recent list

/// Compact newest-first rows for the Home pane. Reads `history.recent`
/// (synchronous, tiny) each time it appears.
///
///     ▣  Slack                              3 min ago
///        Default · 33 words · 15.8 s
///        Final text clamped to two lines …
struct HistoryRecentList: View {
    let history: HistoryStore
    let limit: Int

    @State private var records: [DictationRecord] = []

    private static let iconSide: CGFloat = 28

    var body: some View {
        Group {
            if records.isEmpty {
                Text("Your dictations show up here.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                    ForEach(records, id: \.id) { record in
                        row(record)
                    }
                }
            }
        }
        .onAppear { records = history.recent(limit: limit) }
    }

    private func row(_ record: DictationRecord) -> some View {
        let isCode = HistoryJournal.isCodeMode(record.mode)
        return HStack(alignment: .top, spacing: VeloraSpacing.s + 2) {
            AppIconView(bundleID: record.bundleID, side: Self.iconSide)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.appName ?? "Unknown app")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: VeloraSpacing.s)
                    Text(HistoryJournal.relativeFormatter.localizedString(
                        for: record.timestamp, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(HistoryJournal.entryMeta(record))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(record.final)
                    .font(.system(size: isCode ? 12 : 13, design: isCode ? .monospaced : .default))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
