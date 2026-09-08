import AppKit
import SwiftUI

// MARK: - Share card (aggregate-only by construction)

/// The share card's entire content. Every variable field is a number or a
/// fixed period enum; the renderer has no path to transcript, app, or contact
/// text (the selftest seeds sentinels and asserts they can't leak).
struct IntelligenceShareCard: Equatable {
    enum Period: String, Equatable {
        case today = "Today"
        case week = "Last 7 days"
        case month = "Last 30 days"
        case allTime = "All time"
    }

    let period: Period
    let words: Int
    let dictations: Int
    let minutesSaved: Int
    let currentStreakDays: Int

    struct Metric: Equatable {
        let value: String
        let label: String
    }

    static let title = "My Velora dictation stats"
    static let footer = "Velora — local-first dictation"

    /// The only variable strings the renderer may draw.
    var metrics: [Metric] {
        var lines = [
            Metric(value: Self.compact(words), label: "words dictated"),
            Metric(value: Self.compact(dictations), label: "dictations"),
            Metric(value: Self.duration(minutes: minutesSaved), label: "saved vs typing"),
        ]
        if currentStreakDays > 1 {
            lines.append(Metric(value: "\(currentStreakDays)-day", label: "current streak"))
        }
        return lines
    }

    /// Every string that can appear on a rendered card (privacy selftest).
    var renderedStrings: [String] {
        [Self.title, period.rawValue, Self.footer] + metrics.flatMap { [$0.value, $0.label] }
    }

    static func compact(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// The card the local renderer draws — consumes ONLY `card.renderedStrings`
/// content (fixed literals + numeric aggregates).
private struct ShareCardView: View {
    let card: IntelligenceShareCard

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.l) {
            HStack(spacing: VeloraSpacing.s) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                Text(IntelligenceShareCard.title)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            Text(card.period.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: VeloraSpacing.l) {
                ForEach(card.metrics, id: \.label) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.value)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text(metric.label)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            Text(IntelligenceShareCard.footer)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(VeloraSpacing.xl)
        .frame(width: 460, alignment: .leading)
        .background(VeloraBrand.iconGradient)
    }
}

/// One renderer shared by the ShareLink and the deterministic selftest, so the
/// test exercises the actual card view rather than only its strings.
enum IntelligenceShareCardRenderer {
    @MainActor
    static func image(for card: IntelligenceShareCard, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: ShareCardView(card: card))
        renderer.scale = scale
        return renderer.nsImage
    }
}

// MARK: - Range

/// The Stats pane's time windows. The day maths mirrors the store's SQL
/// windows (`daysBack` 0 / 6 / 29 / nil) so the headline number and the
/// per-range scan describe the same rows.
enum StatsRange: String, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays, allTime

    var id: String { rawValue }

    /// Segmented-control label.
    var title: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .allTime: return "All time"
        }
    }

    /// Tail of the headline: "14,860 words <suffix>".
    var headlineSuffix: String {
        switch self {
        case .today: return "today"
        case .sevenDays: return "this week"
        case .thirtyDays: return "in the last 30 days"
        case .allTime: return "all time"
        }
    }

    /// Calendar days the window spans; nil = unbounded.
    var dayCount: Int? {
        switch self {
        case .today: return 1
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .allTime: return nil
        }
    }

    var sharePeriod: IntelligenceShareCard.Period {
        switch self {
        case .today: return .today
        case .sevenDays: return .week
        case .thirtyDays: return .month
        case .allTime: return .allTime
        }
    }

    /// Inclusive start of the window (local midnight `dayCount - 1` days
    /// before `now`); nil for all time.
    ///
    ///     now = Tue 14:30, sevenDays → Wed (6 days earlier) 00:00
    func start(now: Date, calendar: Calendar = .current) -> Date? {
        guard let dayCount else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: today)
    }

    func stats(in insights: HistoryStore.Insights) -> HistoryStore.WindowStats {
        switch self {
        case .today: return insights.today
        case .sevenDays: return insights.week
        case .thirtyDays: return insights.month
        case .allTime: return insights.allTime
        }
    }
}

// MARK: - Pure stats maths (selftested)

/// Headline and sub-line wording.
enum StatsHeadline {
    /// "14,860 words in the last 30 days" (no full stop — `SerifHeadline`
    /// draws it).
    static func words(_ words: Int, range: StatsRange) -> String {
        "\(HistoryJournal.plural(words, "word")) \(range.headlineSuffix)"
    }

    /// "2 h 41 m of speaking, about 1 h 49 m faster than typing." The saving
    /// clause drops out when nothing was saved; no speech at all reads as
    /// a quiet placeholder.
    static func speaking(spokenMs: Int, minutesSaved: Int) -> String {
        guard spokenMs > 0 else { return "Nothing dictated in this range yet." }
        let spoken = StatsFormat.clock(ms: spokenMs) + " of speaking"
        guard minutesSaved > 0 else { return spoken + "." }
        return spoken + ", about " + StatsFormat.clock(minutes: minutesSaved) + " faster than typing."
    }
}

/// Number and duration formats shared by the tiles, headline and cards.
enum StatsFormat {
    /// "2 h 41 m", "41 m", "45 s".
    static func clock(ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) s" }
        return clock(minutes: seconds / 60)
    }

    /// "2 h 41 m", "41 m", "2 h".
    static func clock(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) m"
    }

    /// "—" when the engine hasn't reported a model, else its display name
    /// (or the repo basename for ids the engine doesn't describe).
    static func modelName(id: String, in models: [EngineModel]) -> String {
        guard !id.isEmpty else { return "—" }
        if let known = models.first(where: { $0.id == id }) { return known.displayName }
        return id.split(separator: "/").last.map(String.init) ?? id
    }
}

/// One app's share of the range's words.
struct StatsAppShare: Equatable {
    let name: String
    let words: Int
    /// Rounded share of ALL words in the range (not of the shown apps), so
    /// the shown percentages never exceed 100 together.
    let percent: Int
}

enum StatsTopApps {
    static let shown = 4

    /// Top `shown` apps by words with their share of the whole range.
    static func shares(_ slices: [HistoryStore.BreakdownSlice]) -> [StatsAppShare] {
        let total = slices.reduce(0) { $0 + $1.words }
        guard total > 0 else { return [] }
        return slices
            .sorted { $0.words > $1.words }
            .prefix(shown)
            .map { slice in
                StatsAppShare(
                    name: slice.name, words: slice.words,
                    percent: Int((Double(slice.words) / Double(total) * 100).rounded()))
            }
    }
}

/// What the per-range record scan yields: things the SQL aggregates don't
/// carry (hour buckets, latency percentiles, apps for windows other than the
/// store's fixed 30 days).
struct StatsRangeDetail: Equatable {
    static let hoursPerDay = 24
    /// Nearest-rank percentile for "slowest 5 %".
    static let slowestPercentile = 0.95

    var hourlyWords: [Int] = Array(repeating: 0, count: hoursPerDay)
    var apps: [HistoryStore.BreakdownSlice] = []
    /// Stop-to-final wall time (`finalizationMs`) percentiles.
    var readyMedianMs: Int?
    var readySlowestMs: Int?
    var scanned = 0

    /// Folds records (any order) into the detail. Empty transcripts are
    /// skipped to match the store's `nonEmpty` aggregates.
    static func build(records: [DictationRecord], calendar: Calendar = .current) -> StatsRangeDetail {
        var detail = StatsRangeDetail()
        var appWords: [String: (count: Int, words: Int)] = [:]
        var ready: [Int] = []
        for record in records where HistoryJournal.hasTranscript(record) {
            let words = HistoryJournal.wordCount(record.final)
            let hour = calendar.component(.hour, from: record.timestamp)
            detail.hourlyWords[min(max(hour, 0), hoursPerDay - 1)] += words
            let app = record.appName.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown app"
            let entry = appWords[app] ?? (0, 0)
            appWords[app] = (entry.count + 1, entry.words + words)
            if let ms = record.finalizationMs, ms > 0 { ready.append(ms) }
            detail.scanned += 1
        }
        detail.apps = appWords
            .map { HistoryStore.BreakdownSlice(name: $0.key, count: $0.value.count, words: $0.value.words) }
            .sorted { $0.words > $1.words }
        let sorted = ready.sorted()
        detail.readyMedianMs = percentile(sorted, 0.5)
        detail.readySlowestMs = percentile(sorted, slowestPercentile)
        return detail
    }

    /// Nearest-rank percentile of an ascending list; nil when empty.
    static func percentile(_ sorted: [Int], _ p: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// One bar of the words chart.
struct StatsBar: Equatable {
    let label: String
    let words: Int
}

/// Builds the chart series per range: hours today, days for 7 / 30 days,
/// and the last 12 weeks for all time (a bar per day of a year-long history
/// would be a hairline, and the store's daily series stops at 84 days).
enum StatsSeries {
    static let weeksAllTime = HistoryStore.heatmapDays / 7

    static func bars(
        range: StatsRange, insights: HistoryStore.Insights, hourlyWords: [Int],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [StatsBar] {
        switch range {
        case .today:
            return hourlyWords.enumerated().map { hour, words in
                StatsBar(label: hourLabel(hour, calendar: calendar), words: words)
            }
        case .sevenDays, .thirtyDays:
            return dayBars(count: range.dayCount ?? 0, daily: insights.daily, now: now, calendar: calendar)
        case .allTime:
            return weekBars(daily: insights.heatmapDaily, now: now, calendar: calendar)
        }
    }

    /// The bar drawn in full accent: the current hour today, else the last.
    static func latestIndex(range: StatsRange, count: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard count > 0 else { return 0 }
        if range == .today { return min(calendar.component(.hour, from: now), count - 1) }
        return count - 1
    }

    /// "Best day Sep 30 · 1,240 words" (hour / week per range); nil when
    /// every bar is empty.
    static func bestCaption(bars: [StatsBar], range: StatsRange) -> String? {
        guard let best = bars.max(by: { $0.words < $1.words }), best.words > 0 else { return nil }
        let unit: String
        switch range {
        case .today: unit = "hour"
        case .sevenDays, .thirtyDays: unit = "day"
        case .allTime: unit = "week"
        }
        return "Best \(unit) \(best.label) · \(HistoryJournal.plural(best.words, "word"))"
    }

    /// The last `count` calendar days ending today, zero-filled.
    private static func dayBars(
        count: Int, daily: [HistoryStore.DaySample], now: Date, calendar: Calendar
    ) -> [StatsBar] {
        let byDay = Dictionary(daily.map { ($0.day, $0.words) }, uniquingKeysWith: +)
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = DayKeys.keyFormatter.string(from: date)
            return StatsBar(label: DayKeys.labelFormatter.string(from: date), words: byDay[key] ?? 0)
        }
    }

    /// Twelve 7-day buckets ending today, labelled by each bucket's first day.
    ///
    ///     today-83 … today-77 │ … │ today-6 … today
    ///        bucket 0         │   │   bucket 11
    private static func weekBars(
        daily: [HistoryStore.DaySample], now: Date, calendar: Calendar
    ) -> [StatsBar] {
        let today = calendar.startOfDay(for: now)
        var words = Array(repeating: 0, count: weeksAllTime)
        for sample in daily {
            guard let date = DayKeys.keyFormatter.date(from: sample.day),
                  let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day,
                  daysAgo >= 0
            else { continue }
            let bucket = weeksAllTime - 1 - daysAgo / 7
            guard words.indices.contains(bucket) else { continue }
            words[bucket] += sample.words
        }
        return words.enumerated().map { bucket, total in
            let daysBack = (weeksAllTime - 1 - bucket) * 7 + 6
            let start = calendar.date(byAdding: .day, value: -daysBack, to: today) ?? today
            return StatsBar(label: DayKeys.labelFormatter.string(from: start), words: total)
        }
    }

    private static func hourLabel(_ hour: Int, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .hour, value: hour, to: today) ?? today
        return DayKeys.hourFormatter.string(from: date)
    }
}

// MARK: - View model

/// Backs the Stats pane. Aggregates are full-table SQL scans, so they load
/// off the main thread; the per-range detail is a bounded newest-first page
/// scan (hour buckets, latency percentiles, apps) for the same window.
final class IntelligenceViewModel: ObservableObject {
    @Published var insights = HistoryStore.Insights()
    @Published var range: StatsRange = .thirtyDays {
        didSet {
            guard range != oldValue else { return }
            reloadDetail()
        }
    }
    @Published private(set) var detail = StatsRangeDetail()
    @Published private(set) var loaded = false
    @Published private(set) var typingWPM = AppConfig.shared.typingWPM

    private let history: HistoryStore
    /// A range switch mid-scan must not let the older scan land.
    private var generation = 0

    private static let pageSize = 500
    /// Most rows a detail scan reads (newest first). Beyond this, apps and
    /// percentiles describe the most recent rows only.
    static let scanCap = 20_000

    init(history: HistoryStore) {
        self.history = history
    }

    var stats: HistoryStore.WindowStats { range.stats(in: insights) }

    var shareCard: IntelligenceShareCard {
        IntelligenceShareCard(
            period: range.sharePeriod,
            words: stats.words,
            dictations: stats.count,
            minutesSaved: stats.minutesSaved(typingWPM: typingWPM),
            currentStreakDays: insights.currentStreak)
    }

    /// Set by the offscreen snapshot renderer, whose nested runloop never
    /// drains main-queue blocks: the first load then runs inline so the
    /// captured frame shows real numbers. The live app always loads in the
    /// background — `insights()` plus a scan of up to `scanCap` rows is too
    /// much for the main thread.
    static var loadsFirstReloadInline = false

    /// Reload both the aggregates and the current range's detail.
    func reload() {
        if !loaded, Self.loadsFirstReloadInline {
            reloadNow()
            return
        }

        generation += 1
        let generation = generation
        let store = history
        let range = range
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fresh = store.insights()
            let detail = StatsRangeDetail.build(records: Self.scan(store: store, range: range))
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.insights = fresh
                self.detail = detail
                self.typingWPM = AppConfig.shared.typingWPM
                self.loaded = true
            }
        }
    }

    /// Synchronous reload for the offscreen snapshot renderer, whose runloop
    /// budget can't wait on the background load.
    func reloadNow() {
        generation += 1
        insights = history.insights()
        detail = StatsRangeDetail.build(records: Self.scan(store: history, range: range))
        typingWPM = AppConfig.shared.typingWPM
        loaded = true
    }

    private func reloadDetail() {
        generation += 1
        let generation = generation
        let store = history
        let range = range
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = StatsRangeDetail.build(records: Self.scan(store: store, range: range))
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.detail = detail
            }
        }
    }

    /// Newest-first rows inside `range`, stopping at the window start or
    /// `scanCap`, whichever comes first.
    private static func scan(store: HistoryStore, range: StatsRange) -> [DictationRecord] {
        let start = range.start(now: Date())
        var rows: [DictationRecord] = []
        var offset = 0
        while offset < scanCap {
            let page = store.page(limit: pageSize, offset: offset, search: nil)
            for record in page {
                if let start, record.timestamp < start { return rows }
                rows.append(record)
            }
            offset += page.count
            if page.count < pageSize { break }
        }
        return rows
    }
}

// MARK: - Header controls

/// The Stats pane's title-row controls: the range picker and the Share
/// capsule. The shell places this beside its `PaneHeader`.
struct StatsHeaderControls: View {
    @ObservedObject var viewModel: IntelligenceViewModel

    var body: some View {
        HStack(spacing: VeloraSpacing.s) {
            Picker("Range", selection: $viewModel.range) {
                ForEach(StatsRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let image = Self.renderedCard(viewModel.shareCard) {
                ShareLink(
                    item: image,
                    preview: SharePreview(IntelligenceShareCard.title, image: image)
                ) {
                    Text("Share…")
                }
                .buttonStyle(.capsule)
                .help("Aggregate numbers only — never transcripts, app names, or contacts.")
            }
        }
    }

    /// Renders the aggregate-only card locally for the selected range.
    private static func renderedCard(_ card: IntelligenceShareCard) -> Image? {
        guard let nsImage = IntelligenceShareCardRenderer.image(for: card) else { return nil }
        return Image(nsImage: nsImage)
    }
}

// MARK: - Pane

/// The Stats pane: a serif headline for the range, four tiles, the words
/// chart, and the Performance / Accuracy / Top apps cards. The shell draws
/// the title and `StatsHeaderControls` above it.
///
///     14,860 words in the last 30 days.
///     2 h 41 m of speaking, about 1 h 49 m faster than typing.
///     [Words] [Dictations] [Speaking time] [Saved vs typing]
///     ┌ Words per day ──────────── Best day Sep 30 · 1,240 words ┐
///     │ ▂▃▅▂▇▃▁▅▆▂▃▅▂▇▃▁▅▆▂▃▅▂▇▃▁▅▆▂▃█                            │
///     └──────────────────────────────────────────────────────────┘
///     ┌ Performance ┐ ┌ Accuracy signals ┐ ┌ Top apps ┐
struct IntelligenceSettingsView: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var vm: IntelligenceViewModel

    private static let sectionSpacing: CGFloat = 18

    init(model: SettingsModel, history: HistoryStore) {
        self.model = model
        _vm = StateObject(wrappedValue: IntelligenceViewModel(history: history))
    }

    /// Shell + snapshot entry point: the window owns one view model shared
    /// with `StatsHeaderControls`.
    init(model: SettingsModel, viewModel: IntelligenceViewModel) {
        self.model = model
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Group {
            if vm.loaded && vm.insights.allTime.count == 0 {
                emptyState
            } else {
                dashboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vm.reload() }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                headline
                StatsTileRow(stats: vm.stats, typingWPM: vm.typingWPM)
                wordsCard
                HStack(alignment: .top, spacing: VeloraSpacing.m) {
                    performanceCard
                    accuracyCard
                    topAppsCard
                }
            }
            .padding(.bottom, VeloraSpacing.xl)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            SerifHeadline(StatsHeadline.words(vm.stats.words, range: vm.range))
            Text(StatsHeadline.speaking(
                spokenMs: vm.stats.spokenMs,
                minutesSaved: vm.stats.minutesSaved(typingWPM: vm.typingWPM)))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Words chart

    private var wordsCard: some View {
        let bars = StatsSeries.bars(range: vm.range, insights: vm.insights, hourlyWords: vm.detail.hourlyWords)
        return GroupCard {
            GroupRow(label: vm.range == .today ? "Words per hour" : vm.range == .allTime ? "Words per week" : "Words per day") {
                if let best = StatsSeries.bestCaption(bars: bars, range: vm.range) {
                    Text(best)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            GroupDivider()
            WordsBarChart(bars: bars, latest: StatsSeries.latestIndex(range: vm.range, count: bars.count))
                .padding(.horizontal, 14)
                .padding(.vertical, VeloraSpacing.m)
        }
    }

    // MARK: Performance

    private var performanceCard: some View {
        GroupCard(header: "Performance") {
            valueRow("Ready in, median", latency(vm.detail.readyMedianMs))
            GroupDivider()
            valueRow("Ready in, slowest 5%", latency(vm.detail.readySlowestMs))
            GroupDivider()
            valueRow("Speech model", StatsFormat.modelName(id: model.sttModel, in: model.sttEngineModels))
            GroupDivider()
            valueRow("Cleanup model", StatsFormat.modelName(id: model.cleanupModel, in: model.cleanupEngineModels))
        }
    }

    // MARK: Accuracy

    /// Only signals the stored rows can back: learned dictionary terms and
    /// the edit-learning loop's observed edits. Reprocess counts, voice
    /// command use and languages aren't recorded, so they aren't shown.
    private var accuracyCard: some View {
        GroupCard(header: "Accuracy signals") {
            valueRow("Learned words", HistoryJournal.grouped(learnedTermCount))
            GroupDivider()
            valueRow("Edited after insert", editedAfterInsert)
        }
    }

    private var learnedTermCount: Int {
        model.dictionaryRows.filter { $0.source == .learned }.count
    }

    /// "3 of 41 observed" — the denominator is only the dictations Velora
    /// could actually watch after inserting.
    private var editedAfterInsert: String {
        let observed = vm.stats.qualityObserved
        guard observed > 0 else { return "No data yet" }
        return "\(vm.stats.qualityEdited) of \(HistoryJournal.grouped(observed)) observed"
    }

    // MARK: Top apps

    private var topAppsCard: some View {
        let shares = StatsTopApps.shares(vm.detail.apps)
        return GroupCard(header: "Top apps") {
            if shares.isEmpty {
                GroupRow(label: "Nothing in this range yet")
            } else {
                ForEach(Array(shares.enumerated()), id: \.element.name) { index, share in
                    if index > 0 { GroupDivider() }
                    TopAppRow(share: share)
                }
            }
        }
    }

    // MARK: Row helpers

    private func valueRow(_ label: String, _ value: String) -> some View {
        GroupRow(label: label) {
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func latency(_ ms: Int?) -> String {
        guard let ms else { return "No data yet" }
        return HistoryJournal.latency(ms: ms)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            Spacer()
            SerifHeadline("No stats yet")
            Text("Dictate a few times and your usage, latency, and accuracy trends appear here. Everything stays on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Tiles

/// The four hero tiles for one window: Words · Dictations · Speaking time ·
/// Saved vs typing (the accent number).
struct StatsTileRow: View {
    let stats: HistoryStore.WindowStats
    let typingWPM: Int

    var body: some View {
        HStack(spacing: VeloraSpacing.m) {
            StatTile(value: HistoryJournal.grouped(stats.words), label: "Words")
            StatTile(value: HistoryJournal.grouped(stats.count), label: "Dictations")
            StatTile(value: StatsFormat.clock(ms: stats.spokenMs), label: "Speaking time")
            StatTile(
                value: StatsFormat.clock(minutes: stats.minutesSaved(typingWPM: typingWPM)),
                label: "Saved vs typing", emphasis: .accent)
        }
    }
}

/// Home pane entry point: the four tiles for `range` over the aggregates of
/// a view model the pane owns (one model per pane, reloaded in place, so a
/// re-activation never rebuilds it and re-scans the store).
struct StatsHeadlineTiles: View {
    @ObservedObject var viewModel: IntelligenceViewModel
    let range: StatsRange

    var body: some View {
        StatsTileRow(stats: range.stats(in: viewModel.insights), typingWPM: viewModel.typingWPM)
    }
}

// MARK: - Words chart

/// Bars for the range's buckets, drawn with plain shapes so the offscreen
/// snapshot renders them: radius 3, accent at 35 % with the latest bucket
/// in full accent, 168 pt tall, five evenly spaced x labels.
///
///     ▂▃▅▂▇▃▁▅▆▂▃▅▂▇▃▁▅▆▂▃▅▂▇▃▁▅▆▂▃█   168 pt
///     Aug 10    Aug 17    Aug 25    Sep 1    Sep 8
private struct WordsBarChart: View {
    let bars: [StatsBar]
    /// Index of the bar drawn in full accent.
    let latest: Int

    private static let height: CGFloat = 168
    private static let radius: CGFloat = 3
    private static let restingOpacity = 0.35
    private static let minBarHeight: CGFloat = 2
    private static let labelCount = 5
    private static let denseGap: CGFloat = 2
    private static let sparseGap: CGFloat = 6
    private static let denseThreshold = 12

    private var gap: CGFloat { bars.count > Self.denseThreshold ? Self.denseGap : Self.sparseGap }

    /// Indices whose labels are drawn: first, last, and three between.
    private var labelIndices: [Int] {
        guard bars.count > 1 else { return bars.isEmpty ? [] : [0] }
        let last = bars.count - 1
        var indices = (0..<Self.labelCount).map { $0 * last / (Self.labelCount - 1) }
        indices.removeAll { $0 < 0 || $0 > last }
        return Array(NSOrderedSet(array: indices)) as? [Int] ?? indices
    }

    var body: some View {
        let peak = max(bars.map(\.words).max() ?? 0, 1)
        VStack(spacing: VeloraSpacing.xs) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .fill(VeloraBrand.accent.opacity(
                            index == latest ? 1 : Self.restingOpacity))
                        .frame(height: max(
                            Self.minBarHeight, Self.height * CGFloat(bar.words) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .help(bar.words > 0
                              ? "\(bar.label) — \(HistoryJournal.plural(bar.words, "word"))"
                              : "\(bar.label) — no dictation")
                }
            }
            .frame(height: Self.height, alignment: .bottom)
            axisLabels
        }
    }

    /// Labels sit under their bar's centre; the first hugs the leading edge
    /// and the last the trailing edge so nothing spills outside the card.
    private var axisLabels: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(bars.count, 1))
            let barWidth = (geometry.size.width - gap * (count - 1)) / count
            ForEach(labelIndices, id: \.self) { index in
                let centre = CGFloat(index) * (barWidth + gap) + barWidth / 2
                Text(bars[index].label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .modifier(AxisLabelPlacement(
                        centre: centre, width: geometry.size.width,
                        edge: index == 0 ? .leading : index == bars.count - 1 ? .trailing : .centre))
            }
        }
        .frame(height: 14)
    }

    private struct AxisLabelPlacement: ViewModifier {
        enum Edge { case leading, centre, trailing }
        let centre: CGFloat
        let width: CGFloat
        let edge: Edge

        func body(content: Content) -> some View {
            switch edge {
            case .leading:
                content.frame(maxWidth: .infinity, alignment: .leading)
            case .trailing:
                content.frame(maxWidth: .infinity, alignment: .trailing)
            case .centre:
                content.position(x: centre, y: 7)
            }
        }
    }
}

// MARK: - Top app row

/// App name, its share, and a 5 pt accent bar under both.
///
///     Slack                                  42 %
///     ████████████████░░░░░░░░░░░░░░░░░░░░░░░░░
private struct TopAppRow: View {
    let share: StatsAppShare

    private static let barHeight: CGFloat = 5
    private static let inset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs + 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(share.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: VeloraSpacing.s)
                Text("\(share.percent)%")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(VeloraBrand.accent)
                        .frame(width: max(
                            Self.barHeight, geometry.size.width * CGFloat(share.percent) / 100))
                }
            }
            .frame(height: Self.barHeight)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, VeloraSpacing.s + 2)
        .help("\(HistoryJournal.plural(share.words, "word"))")
    }
}

// MARK: - Shared day math

/// yyyy-MM-dd keys and friendly labels shared by the chart series.
private enum DayKeys {
    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        // POSIX locale: keys must match SQLite's Gregorian ASCII day strings
        // even when the user's locale uses another calendar or digit set.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.timeZone = .current
        return f
    }()

    /// "9 AM" / "14" depending on the locale's hour cycle.
    static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j")
        f.timeZone = .current
        return f
    }()
}
