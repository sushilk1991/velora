import AppKit
import AVFoundation
import Combine
import SwiftUI

extension Notification.Name {
    static let veloraHistoryRevealRequested = Notification.Name("VeloraHistoryRevealRequested")
}

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
    /// Every mode the Modes pane lists, Default first: the Reprocess menu.
    @Published private(set) var modeNames: [String] = []

    private let history: HistoryStore
    private weak var supervisor: EngineSupervisor?
    private let textFormatter: TextFormattingClient
    private var reprocessSnapshots: [Int64: DictationRecord] = [:]
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
    /// An entry another pane asked to open (Home's Recent rows). The pane
    /// rebuilds this model on every visit, so the request is static and
    /// one-shot.
    private static var pendingReveal: Int64?
    private static var pendingReformat: (Int64, String)?

    static func requestReformat(_ id: Int64, mode: String) {
        pendingReformat = (id, mode)
        requestReveal(id)
    }

    static func consumeReformat(_ id: Int64) -> String? {
        guard pendingReformat?.0 == id else { return nil }
        defer { pendingReformat = nil }
        return pendingReformat?.1
    }

    private static let pageSize = 50
    /// Most rows the app-name / month-count scan reads (newest first) so a
    /// huge history can't stream entirely into memory.
    private static let summaryScanCap = 5_000
    /// How long to wait for a reprocess reply before showing "failed". Stable
    /// failures arrive immediately; this is the final defense for disconnects.
    private static let reprocessTimeout: TimeInterval = 90
    /// Keystroke debounce before the search re-queries the store.
    private static let searchDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(150)

    init(
        history: HistoryStore, supervisor: EngineSupervisor?,
        modesDirectory: URL = AppConfig.modesDirectory
    ) {
        self.history = history
        self.supervisor = supervisor
        textFormatter = TextFormattingClient(supervisor: supervisor)
        modeNames = Self.modeNames(in: modesDirectory)
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

    /// The Modes pane's list (built-ins plus saved files), Default first,
    /// then alphabetical.
    private static func modeNames(in directory: URL) -> [String] {
        let names = Set(Mode.loadAll(from: directory).map(\.name))
        let rest = names.subtracting([Mode.defaultName]).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return [Mode.defaultName] + rest
    }

    /// Asks the next History pane to open `id` expanded.
    static func requestReveal(_ id: Int64) {
        pendingReveal = id
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .veloraHistoryRevealRequested, object: nil)
        }
    }

    /// Opens the requested entry once, after the pane's first reload (which
    /// collapses everything). A request for a row no longer loaded lapses.
    func revealPending() {
        guard let id = Self.pendingReveal else {
            return
        }
        Self.pendingReveal = nil
        if records.contains(where: { $0.id == id }) {
            expandedID = id
        }
    }

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
    func saveEdit(_ record: DictationRecord, newText: String, completion: @escaping (Bool) -> Void) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(false); return }
        guard trimmed != record.final else {
            completion(history.record(id: record.id)?.transcriptRevision == record.transcriptRevision)
            return
        }
        let store = history
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let saved = store.updateFinal(expected: record, final: trimmed)
            let refreshed = saved ? store.record(id: record.id) : nil
            DispatchQueue.main.async {
                if let refreshed, let self,
                   let index = self.records.firstIndex(where: { $0.id == record.id }) {
                    self.records[index] = refreshed
                }
                completion(saved)
            }
        }
    }

    @discardableResult
    func formatText(_ record: DictationRecord, mode: String,
                    completion: @escaping (Result<TextFormattingResult, TextFormattingFailure>) -> Void) -> String? {
        textFormatter.format(record.raw.isEmpty ? record.final : record.raw,
            modeName: mode, bundleID: record.targetBundleID, appName: record.targetAppName,
            completion: completion)
    }

    func cancelFormat(_ id: String) { textFormatter.cancel(id) }

    func undoEdit(_ record: DictationRecord) {
        guard history.undoFinal(expected: record), let refreshed = history.record(id: record.id),
              let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = refreshed
    }

    func delete(_ record: DictationRecord) {
        reprocessSnapshots.removeValue(forKey: record.id)
        inFlight.remove(record.id)
        reprocessGen[record.id] = (reprocessGen[record.id] ?? 0) + 1
        history.delete(id: record.id)
        records.removeAll { $0.id == record.id }
        isEmpty = records.isEmpty
        if expandedID == record.id { expandedID = nil }
        refreshSummary()
    }

    func clearAll() {
        stopPlayback()
        reprocessSnapshots.removeAll()
        inFlight.removeAll()
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
        reprocessSnapshots[id] = record
        supervisor?.send(reprocessCommand(record: record, audio: audio, sttModel: sttModel, mode: mode))

        // A stable failure normally clears this immediately; retain a timeout
        // for a process crash or dropped control connection.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reprocessTimeout) { [weak self] in
            guard let self, self.reprocessGen[id] == gen, self.inFlight.contains(id) else { return }
            self.inFlight.remove(id)
            self.reprocessSnapshots.removeValue(forKey: id)
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
        if let bundleID = record.targetBundleID { command["bundle_id"] = bundleID }
        if let appName = record.targetAppName { command["app_name"] = appName }
        return command
    }

    private func applyReprocessed(
        id: Int64?, raw: String, text: String, mode: String?,
        sttMs: Int, cleanupMs: Int, cleanupApplied: Bool, cleanupWallMs: Int?
    ) {
        guard let id, inFlight.contains(id), let snapshot = reprocessSnapshots.removeValue(forKey: id)
        else { return }
        let saved = history.updateAfterReprocess(
            id: id, raw: raw, final: text, mode: mode,
            sttMs: sttMs, cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
            cleanupWallMs: cleanupWallMs, expected: snapshot)
        if let refreshed = history.record(id: id),
           let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = refreshed
        }
        // A later request supersedes this reply's pending timeout.
        reprocessGen[id] = (reprocessGen[id] ?? 0) + 1
        inFlight.remove(id)
        if saved { failed.remove(id) } else { failed.insert(id) }
    }

    private func applyReprocessFailed(id: Int64?) {
        guard let id, inFlight.contains(id) else { return }
        reprocessSnapshots.removeValue(forKey: id)
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
    static let todayLabel = "Today"

    static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return todayLabel }
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

    /// "Default · 33 words · 15.8 s". A row with no text says so instead,
    /// since its numbers would describe nothing. Latency stays in Stats.
    static func entryMeta(_ record: DictationRecord) -> String {
        guard hasTranscript(record) else { return "Needs reprocessing" }
        var parts: [String] = [modeName(record.mode), plural(wordCount(record.final), "word")]
        if record.durationMs > 0 {
            parts.append(String(format: "%.1f s", Double(record.durationMs) / 1000))
        }
        return parts.joined(separator: " · ")
    }

    static func gapNote(_ record: DictationRecord) -> String? {
        guard record.failedWindowCount > 0 else { return nil }
        let seconds = Int(ceil(record.failedWindowS))
        let note = "Part of this dictation couldn't be transcribed (\(seconds) seconds)."
        return record.audioPath == nil ? note : note + " Retry from saved audio."
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

    /// The journal's time gutter in the reader's hour cycle: "13:21" or
    /// "1:21 PM".
    static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }

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
/// "All Apps" chooser. The shell places this beside its `PaneHeader`.
struct HistoryHeaderControls: View {
    @ObservedObject var viewModel: HistoryViewModel

    private static let searchWidth: CGFloat = 240
    private static let allApps = "All Apps"

    var body: some View {
        HStack(spacing: VeloraSpacing.s) {
            SettingsSearchBox(prompt: "Search what you said", query: $viewModel.searchText)
                .frame(width: Self.searchWidth)
            // The shared header chooser, like Home's microphone menu; it
            // brings its own capsule, tooltip and VoiceOver label.
            HeaderMenu(
                "Filter by app", value: viewModel.appFilter ?? Self.allApps,
                selection: $viewModel.appFilter
            ) {
                Text(Self.allApps).tag(String?.none)
                if !viewModel.appNames.isEmpty {
                    Divider()
                    ForEach(viewModel.appNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
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
    private let onEditStyle: () -> Void
    @StateObject private var vm: HistoryViewModel
    @State private var showClearConfirm = false

    /// Widest the journal text runs; the column starts at the pane title's
    /// leading edge (centring it left a dead gutter beside the title).
    private static let columnWidth: CGFloat = 760
    private static let daySpacing: CGFloat = 28
    /// Rows carry 8 pt of their own vertical padding (the hover fill), so
    /// the gap between them stays tight.
    private static let entrySpacing: CGFloat = 8

    init(model: SettingsModel, history: HistoryStore, supervisor: EngineSupervisor?,
         onEditStyle: @escaping () -> Void = {}) {
        self.onEditStyle = onEditStyle
        self.model = model
        _vm = StateObject(wrappedValue: HistoryViewModel(history: history, supervisor: supervisor))
    }

    /// Shell entry point: the window owns one view model shared with
    /// `HistoryHeaderControls`.
    init(model: SettingsModel, viewModel: HistoryViewModel, onEditStyle: @escaping () -> Void = {}) {
        self.onEditStyle = onEditStyle
        self.model = model
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .veloraHistoryRevealRequested)) { _ in
                vm.revealPending()
            }
            .onAppear {
                model.requestStatus()
                vm.reload()  // fresh rows every time the tab appears
                vm.revealPending()  // after the reload, which collapses rows
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
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                dayHeading(day.label)
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
                    onEdit: { snapshot, text, completion in vm.saveEdit(snapshot, newText: text, completion: completion) },
                    onUndo: { vm.undoEdit(record) },
                    onFormat: { snapshot, mode, completion in vm.formatText(snapshot, mode: mode, completion: completion) },
                    onCancelFormat: vm.cancelFormat,
                    onEditStyle: onEditStyle,
                    dictionary: model.dictionary,
                    onReprocess: { stt, mode in vm.reprocess(record, sttModel: stt, mode: mode) },
                    onPlay: { vm.togglePlayback(record) },
                    onDelete: { vm.delete(record) },
                    modeNames: vm.modeNames)
                .onAppear {
                    if record.id == vm.visibleRecords.last?.id { vm.loadMore() }
                }
            }
        }
    }

    /// Only "Today" is the pane's serif sentence; older days are plain
    /// section headings, so a long journal isn't a column of headlines.
    @ViewBuilder
    private func dayHeading(_ label: String) -> some View {
        if label == HistoryJournal.todayLabel {
            SerifHeadline(label)
        } else {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One dictation in the journal. Collapsed: a 64 pt time gutter beside the
/// app line and the final text (three lines at most), with a hover fill so
/// the click-to-expand is discoverable. Expanded (one at a time): a raised card with the full text,
/// an "As heard" disclosure for the raw transcript, and the action capsules.
///
///     13:21 │ ▣ Slack  Default · 33 words · 15.8 s
///           │ Final text …
///
///     ┌────────────────────────────────────────────┐ raised, radius 12
///     │ 13:21  ▣ Slack  Default · 33 words · 15.8 s │
///     │ Full final text …                          │
///     │ ▸ As heard                                 │  toggles the raw text
///     │ (Copy)(Insert Again)(Edit)(Reprocess)(Play)   (🗑) │
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
    let onEdit: (DictationRecord, String, @escaping (Bool) -> Void) -> Void
    let onUndo: () -> Void
    let onFormat: (DictationRecord, String, @escaping (Result<TextFormattingResult, TextFormattingFailure>) -> Void) -> String?
    let onCancelFormat: (String) -> Void
    let onEditStyle: () -> Void
    let dictionary: DictionaryRepository
    let onReprocess: (_ sttModel: String?, _ mode: String?) -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void
    /// Every mode the Modes pane lists (Reprocess › Mode).
    let modeNames: [String]

    @State private var copied = false
    @State private var editing = false
    @State private var editSnapshot: DictationRecord?
    @State private var reformatting = false
    @State private var reformatModeOverride: String?
    @State private var reformatSnapshot: DictationRecord?
    @State private var rememberedSpellings: [DictionaryEntry] = []
    @State private var spellingMessage: String?
    @State private var editDraft = ""
    @State private var editError: String?
    @State private var editSaving = false
    @State private var hovering = false
    @State private var showsRaw = false
    @State private var confirmingDelete = false
    @State private var trialRun: HistoryTrialRun?
    @State private var trialLoadError: String?
    @State private var trialLoadGeneration = 0

    /// Wide enough for a 12-hour "12:30 PM".
    private static let timeColumn: CGFloat = 64
    private static let iconSide: CGFloat = 18
    private static let textSize: CGFloat = 14
    private static let expandedTextSize: CGFloat = 14.5
    private static let codeTextSize: CGFloat = 12.5
    /// Extra leading that lifts the system font's ~1.2 line height to the
    /// journal's 1.45 (14 pt → about 3.5 pt between lines).
    private static let extraLeadingRatio: CGFloat = 0.25
    /// Hover fill behind a collapsed row, bled `rowBleed` past the text so
    /// the text itself stays on the column's edge.
    private static let hoverFill = 0.05
    private static let rowBleed: CGFloat = 10
    private static let rowRadius: CGFloat = 10
    /// Raw transcript: 12.5 pt secondary text behind a 2 pt hairline rule.
    private static let rawTextSize: CGFloat = 12.5
    private static let rawRuleWidth: CGFloat = 2
    private static let copiedFlash: TimeInterval = 1.2

    /// Collapsed rows show this many lines; the expanded card shows all.
    private static let collapsedLines = 3

    private var isCode: Bool { HistoryJournal.isCodeMode(record.mode) }
    private var hasTranscript: Bool { HistoryJournal.hasTranscript(record) }

    private struct TrialLookupKey: Equatable {
        let expanded: Bool
        let reprocessing: Bool
        let raw: String
        let final: String
        let sessionID: String?
        let cleanupMs: Int?
        let cleanupWallMs: Int?
        let cleanupApplied: Bool?
    }

    private var trialLookupKey: TrialLookupKey {
        TrialLookupKey(expanded: expanded, reprocessing: isReprocessing,
            raw: record.raw, final: record.final, sessionID: record.sessionID,
            cleanupMs: record.cleanupMs, cleanupWallMs: record.cleanupWallMs,
            cleanupApplied: record.cleanupApplied)
    }

    var body: some View {
        Group {
            if expanded {
                expandedCard
            } else {
                collapsedRow
            }
        }
        .sheet(isPresented: $editing) { editSheet }
        .sheet(isPresented: $reformatting) {
            HistoryReformatSheet(record: reformatSnapshot ?? record, modeNames: modeNames, initialMode: reformatModeOverride,
                format: onFormat, cancel: onCancelFormat,
                save: { snapshot, text, completion in onEdit(snapshot, text, completion) })
        }
        .onAppear(perform: loadTrial)
        .onDisappear { trialLoadGeneration += 1 }
        .onChange(of: trialLookupKey) { _ in loadTrial() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraHistoryRevealRequested)) { _ in
            if expanded, let mode = HistoryViewModel.consumeReformat(record.id) {
                reformatModeOverride = mode
                reformatSnapshot = record
                reformatting = true
            }
        }
        .onChange(of: expanded) { isExpanded in
            if isExpanded, let mode = HistoryViewModel.consumeReformat(record.id) {
                reformatModeOverride = mode
                reformatSnapshot = record
                reformatting = true
            }
        }
        .onAppear {
            if expanded, let mode = HistoryViewModel.consumeReformat(record.id) {
                reformatModeOverride = mode
                reformatSnapshot = record
                reformatting = true
            }
        }
    }

    private func loadTrial() {
        trialLoadGeneration += 1
        let generation = trialLoadGeneration
        trialRun = nil
        trialLoadError = nil
        guard expanded, hasTranscript, !isReprocessing else { return }
        let snapshot = record
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try HistoryTrialFeedbackStore.shared.loadMatch(for: snapshot) }
            DispatchQueue.main.async {
                guard trialLoadGeneration == generation else { return }
                switch result {
                case .success(let match): trialRun = match
                case .failure(let error): trialLoadError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Collapsed

    private var collapsedRow: some View {
        HStack(alignment: .top, spacing: 0) {
            timeLabel
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                appLine
                transcript(size: Self.textSize, lineLimit: Self.collapsedLines)
                if let gap = HistoryJournal.gapNote(record) {
                    Text(gap)
                        .font(.caption)
                        .foregroundStyle(VeloraStatus.warningText)
                }
            }
        }
        .padding(.vertical, VeloraSpacing.s)
        .padding(.horizontal, Self.rowBleed)
        .padding(.horizontal, -Self.rowBleed)
        .background(
            RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous)
                .fill(Color.primary.opacity(hovering ? Self.hoverFill : 0))
                .padding(.horizontal, -Self.rowBleed))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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

            if let gap = HistoryJournal.gapNote(record) {
                Label(gap, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warningText)
                    .padding(.leading, Self.timeColumn)
            }

            if HistoryJournal.hasDistinctRaw(record) {
                rawDisclosure
                    .padding(.leading, Self.timeColumn)
            }

            if let trialRun, hasTranscript && !isReprocessing {
                HistoryTrialFeedbackDetail(record: record, run: trialRun)
                    .padding(.leading, Self.timeColumn)
            } else if let trialLoadError {
                Text(trialLoadError)
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.timeColumn)
            }

            if reprocessFailed {
                Label("Reprocess failed. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warningText)
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

    /// "▸ As heard" toggles the pre-cleanup transcript under the final text.
    /// Closed by default: the cleaned text is the record, the raw is a check.
    private var rawDisclosure: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs + 2) {
            Button {
                withAnimation(VeloraMotion.standard) { showsRaw.toggle() }
            } label: {
                HStack(spacing: VeloraSpacing.xs + 1) {
                    Image(systemName: showsRaw ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text("As heard")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the transcript before cleanup")

            if showsRaw {
                Text(record.raw)
                    .font(.system(size: Self.rawTextSize))
                    .lineSpacing(Self.rawTextSize * Self.extraLeadingRatio)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, VeloraSpacing.m)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Self.rawRuleWidth / 2)
                            .fill(VeloraPanel.hairline)
                            .frame(width: Self.rawRuleWidth)
                    }
                    .padding(.leading, VeloraSpacing.xs)
            }
        }
    }

    // MARK: Shared pieces

    private var timeLabel: some View {
        Text(HistoryJournal.time(record.timestamp))
            .font(.system(size: 12))
            .monospacedDigit()
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
        return Text(hasTranscript ? record.final : "No transcript. Reprocess the saved audio.")
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
                Button("Fix this") {
                    editSnapshot = record
                    editDraft = record.final
                    editError = nil
                    spellingMessage = nil
                    rememberedSpellings = []
                    editing = true
                }
                .buttonStyle(.capsule)
                Menu {
                    Button("Reformat saved text…") {
                        reformatModeOverride = nil
                        reformatSnapshot = record
                        reformatting = true
                    }
                    Button("Copy As Heard") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(record.raw.isEmpty ? record.final : record.raw, forType: .string)
                    }
                    if record.previousFinal != nil {
                        Button("Undo last correction", action: onUndo)
                    }
                    Divider()
                    Button("Adjust app style in Modes…", action: onEditStyle)
                } label: { Text("More") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            reprocessMenu
            if hasAudio {
                Button(isPlaying ? "Stop" : "Play", action: onPlay)
                    .buttonStyle(.capsule)
            }
            Spacer(minLength: 0)
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.capsule)
            .help("Delete this transcript permanently")
            .accessibilityLabel("Delete")
            // One click used to delete the transcript and its audio for good.
            .confirmationDialog("Delete this dictation?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive, action: onDelete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The transcript and its saved audio are deleted from this Mac. This can't be undone.")
            }
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
                ForEach(modeNames, id: \.self) { mode in
                    Button(mode) { onReprocess(nil, mode) }
                }
            }
        } label: {
            HStack(spacing: VeloraSpacing.xs) {
                if isReprocessing {
                    ProgressView().controlSize(.mini)
                }
                Text("Reprocess")
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
              : "Reprocessing unavailable: no saved audio for this dictation")
    }

    private var spellingSuggestions: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            ForEach(Array(CorrectionDiff.corrections(
                baseline: (editSnapshot ?? record).final, edited: editDraft).prefix(3).enumerated()), id: \.offset) { _, pair in
                Button("Remember spelling: \(pair.wrong) → \(pair.right)") {
                    do {
                        let row = try dictionary.add(writeAs: pair.right, heardAs: pair.wrong)
                        if let receipt = dictionary.document.entry(id: row.id) { rememberedSpellings.append(receipt) }
                        spellingMessage = "Remembered. You can undo this here or remove it in Dictionary."
                    } catch { spellingMessage = error.localizedDescription }
                }
                .buttonStyle(.link)
            }
            if let spellingMessage {
                HStack {
                    Text(spellingMessage).font(.caption).foregroundStyle(.secondary)
                    if let last = rememberedSpellings.last {
                        Button("Undo") {
                            do {
                                let removed = try dictionary.undoAddition(last)
                                rememberedSpellings.removeLast()
                                self.spellingMessage = removed ? "Spelling removed." : "This spelling changed since it was remembered. The newer entry was kept."
                            } catch { self.spellingMessage = error.localizedDescription }
                        }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    // MARK: Edit sheet

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            Text("Fix this result")
                .font(.headline)
            Text("Save changes to this result. Remembering a spelling is a separate choice.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("As heard") {
                Text((editSnapshot ?? record).raw).font(.caption).textSelection(.enabled)
                    .frame(maxHeight: 80, alignment: .topLeading)
            }
            if let editError {
                Text(editError).font(.caption).foregroundStyle(.red)
            }
            TextEditor(text: $editDraft)
                .disabled(editSaving)
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
            spellingSuggestions
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(editSaving)
                Button(editSaving ? "Saving…" : "Save") {
                    guard !editSaving else { return }
                    editSaving = true
                    onEdit(editSnapshot ?? record, editDraft) { saved in
                        editSaving = false
                        if saved {
                            editError = nil
                            editing = false
                        } else {
                            editError = "This result may have changed or been deleted. Your draft is still here; copy it or reopen the latest result."
                        }
                    }
                }
                .disabled(editSaving)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(VeloraSpacing.xl)
        .frame(width: 560, height: 560)
        .interactiveDismissDisabled(editSaving)
    }
}

// MARK: - Personal trial feedback

/// Only an expanded entry instantiates this view. Metadata lookup and feedback
/// writes run off the main thread, while the normal History actions keep their
/// existing meaning. Feedback never updates the transcript or dictionary.
private struct HistoryTrialFeedbackDetail: View {
    let record: DictationRecord
    let run: HistoryTrialRun
    private let store = HistoryTrialFeedbackStore.shared

    @State private var feedbackError: String?
    @State private var feedbackMessage: String?
    @State private var saving = false
    @State private var correcting = false
    @State private var correctionDraft = ""
    @State private var correctionError: String?
    @State private var showsRaw = false

    private static let sheetWidth: CGFloat = 520
    private static let editorHeight: CGFloat = 160
    private static let rawHeight: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                Text("Personal trial: \(run.backendLabel)")
                    .font(.system(size: 13, weight: .semibold))
                if let model = run.modelLabel {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(run.resultNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: VeloraSpacing.s) {
                Button("Looks Right") {
                    save(corrected: record.final, accepted: true, run: run)
                }
                .buttonStyle(.capsule)
                .help("Confirm this result for the local personal trial")
                Button("Correct Result…") {
                    correctionDraft = record.final
                    correctionError = nil
                    showsRaw = false
                    correcting = true
                }
                .buttonStyle(.capsule)
                if saving { ProgressView().controlSize(.mini) }
            }
            .disabled(saving)
            Text("Feedback is saved on this Mac. It is not sent or used for training automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let feedbackError {
                Text(feedbackError)
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let feedbackMessage {
                Text(feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $correcting) { correctionSheet }
    }

    private func save(corrected: String, accepted: Bool, run: HistoryTrialRun) {
        guard !saving else { return }
        saving = true
        feedbackError = nil
        feedbackMessage = nil
        correctionError = nil
        let snapshot = record
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try store.save(record: snapshot, run: run, corrected: corrected, accepted: accepted)
            }
            DispatchQueue.main.async {
                saving = false
                switch result {
                case .success:
                    correcting = false
                    feedbackMessage = accepted ? "Result confirmed on this Mac." : "Correction saved on this Mac."
                case .failure(let error):
                    if correcting {
                        correctionError = error.localizedDescription
                    } else {
                        feedbackError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var correctionSheet: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            Text("Correct Result")
                .font(.headline)
            Text("Write the result you intended for this personal trial.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if HistoryJournal.hasDistinctRaw(record) {
                DisclosureGroup("As heard", isExpanded: $showsRaw) {
                    ScrollView {
                        Text(record.raw)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: Self.rawHeight)
                    .padding(.top, VeloraSpacing.xs)
                }
                .font(.caption)
            }
            TextEditor(text: $correctionDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(VeloraSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                        .fill(VeloraPanel.card))
                .overlay(
                    RoundedRectangle(cornerRadius: VeloraRadius.tile, style: .continuous)
                        .strokeBorder(Color(.separatorColor)))
                .frame(minHeight: Self.editorHeight)
                .accessibilityLabel("Correct result")
                .disabled(saving)
                .onChange(of: correctionDraft) { _ in correctionError = nil }
            if let correctionError {
                Text(correctionError)
                    .font(.caption)
                    .foregroundStyle(VeloraStatus.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: VeloraSpacing.s) {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { correcting = false }
                    .buttonStyle(.capsule)
                    .keyboardShortcut(.cancelAction)
                Button("Save Correction") {
                    save(corrected: correctionDraft, accepted: false, run: run)
                }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(saving)
        }
        .padding(VeloraSpacing.xl)
        .frame(width: Self.sheetWidth)
        .interactiveDismissDisabled(saving)
    }
}

// MARK: - Home pane: recent list

/// Compact newest-first rows for the Home pane. Reads `history.recent`
/// (synchronous, tiny) each time it appears. A click opens the row in
/// History.
///
///     ▣  Slack                              3 min ago
///        Default · 33 words · 15.8 s
///        Final text clamped to two lines …
struct HistoryRecentList: View {
    let history: HistoryStore
    let limit: Int
    let onOpen: (DictationRecord) -> Void

    @State private var records: [DictationRecord] = []
    @State private var hoveredID: Int64?

    private static let iconSide: CGFloat = 28
    /// The hover fill bleeds this far past the row so text stays aligned.
    private static let rowBleed: CGFloat = 6
    private static let rowRadius: CGFloat = 8
    private static let hoverFill = 0.05

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
                            .padding(Self.rowBleed)
                            .background(
                                RoundedRectangle(cornerRadius: Self.rowRadius, style: .continuous)
                                    .fill(Color.primary.opacity(hoveredID == record.id ? Self.hoverFill : 0)))
                            .contentShape(Rectangle())
                            .padding(-Self.rowBleed)
                            .onHover { inside in
                                if inside {
                                    hoveredID = record.id
                                } else if hoveredID == record.id {
                                    hoveredID = nil
                                }
                            }
                            .onTapGesture { onOpen(record) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Opens the dictation in History")
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
