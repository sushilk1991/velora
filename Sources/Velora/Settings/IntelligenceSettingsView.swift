import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    static let footer = "Velora, local-first dictation"

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

    enum RenderError: Error {
        case failed
    }

    /// The card as PNG bytes, for the share sheet.
    @MainActor
    static func pngData(for card: IntelligenceShareCard) throws -> Data {
        guard let image = image(for: card),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw RenderError.failed
        }
        return png
    }
}

/// The Share capsule's item. The card renders only when the share sheet
/// asks for it; building an image on every body pass made each range
/// switch pay for a render nobody shared.
struct StatsShareImage: Transferable {
    let card: IntelligenceShareCard

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await MainActor.run { try IntelligenceShareCardRenderer.pngData(for: item.card) }
        }
    }
}

// MARK: - Range

/// The Stats pane's time windows. The day maths mirrors the store's SQL
/// windows (`daysBack` 0 / 6 / 29 / nil) so the headline number and the
/// per-range scan describe the same rows.
enum StatsRange: String, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays, allTime

    var id: String { rawValue }

    /// Segmented-control label, Title Case like a tab (DESIGN.md §5).
    var title: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        case .allTime: return "All Time"
        }
    }

    /// Tail of the headline: "14,860 words <suffix>".
    var headlineSuffix: String {
        switch self {
        case .today: return "today"
        case .sevenDays: return "in the last 7 days"
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

    /// The store's `daysBack` for this window (0 / 6 / 29); nil = all time.
    var daysBack: Int? {
        dayCount.map { $0 - 1 }
    }

    /// What a tile's delta is measured against; nil when there is no
    /// earlier window of the same length (all time).
    var comparisonLabel: String? {
        switch self {
        case .today: return "yesterday"
        case .sevenDays: return "previous 7 days"
        case .thirtyDays: return "previous 30 days"
        case .allTime: return nil
        }
    }

    /// The equal-length window just before this one; nil for all time.
    func previousStats(in insights: HistoryStore.Insights) -> HistoryStore.WindowStats? {
        switch self {
        case .today: return insights.yesterday
        case .sevenDays: return insights.previousWeek
        case .thirtyDays: return insights.previousMonth
        case .allTime: return nil
        }
    }

    /// "last 30 days", "all time": the tail of a chart caption.
    var windowPhrase: String {
        switch self {
        case .today: return "today"
        case .sevenDays: return "last 7 days"
        case .thirtyDays: return "last 30 days"
        case .allTime: return "all time"
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

    /// Least speech a pace is quoted from: under a minute, one quick
    /// sentence would set the number.
    static let minimumSpokenMs = 60_000
    /// Below this speaking : typing ratio the "× your typing speed" clause
    /// says nothing, so the sentence stops at the pace.
    static let multipleThreshold = 1.1

    /// "You speak at 125 wpm, 3.1× your typing speed" (no full stop,
    /// `SerifHeadline` draws it). Adds the one fact the tiles don't show;
    /// nil under a minute of speech.
    static func pace(words: Int, spokenMs: Int, typingWPM: Int) -> String? {
        guard spokenMs >= minimumSpokenMs, words > 0 else {
            return nil
        }

        let wpm = Double(words) / (Double(spokenMs) / 60_000)
        let sentence = "You speak at \(Int(wpm.rounded())) wpm"
        guard typingWPM > 0 else {
            return sentence
        }

        let ratio = wpm / Double(typingWPM)
        guard ratio >= multipleThreshold else {
            return sentence
        }
        return sentence + ", " + multiple(ratio) + " your typing speed"
    }

    /// "3.1×", or "3×" when the tenths round to a whole number.
    private static func multiple(_ ratio: Double) -> String {
        let tenths = Int((ratio * 10).rounded())
        let digits = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        return digits + "×"
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

    /// "↑ 9% vs previous 30 days", "↓ 19% vs yesterday", "Same as
    /// yesterday". Nil for all time or when the earlier window is empty
    /// (a rise from nothing has no percentage).
    static func delta(_ current: Int, _ previous: Int, range: StatsRange) -> String? {
        guard let label = range.comparisonLabel, previous > 0 else {
            return nil
        }

        let percent = Int((Double(current - previous) / Double(previous) * 100).rounded())
        if percent == 0 {
            return "Same as \(label)"
        }
        let arrow = percent > 0 ? "↑" : "↓"
        return "\(arrow) \(abs(percent))% vs \(label)"
    }
}

/// One app's share of the range's words.
struct StatsAppShare: Equatable {
    let name: String
    let words: Int
    /// Share of ALL words in the range (not of the shown apps), so the
    /// shown percentages never exceed 100 together.
    let percent: Int
}

/// Whole percentages that total exactly 100 (largest remainder): floor
/// every share, then hand the leftover points to the biggest remainders,
/// earlier entries first on a tie. Integer maths, so no float drift.
///
///     335 / 335 / 330  →  33.5 / 33.5 / 33.0  →  34 / 33 / 33
///     (plain rounding: 34 / 34 / 33 = 101)
enum StatsPercent {
    static func allocate(_ parts: [Int]) -> [Int] {
        let total = parts.reduce(0, +)
        guard total > 0 else {
            return parts.map { _ in 0 }
        }

        var result = parts.map { $0 * 100 / total }
        let remainders = parts.map { $0 * 100 % total }
        let leftover = 100 - result.reduce(0, +)
        let order = parts.indices.sorted { (remainders[$0], $1) > (remainders[$1], $0) }
        for index in order.prefix(leftover) {
            result[index] += 1
        }
        return result
    }
}

enum StatsTopApps {
    static let shown = 4

    /// Top `shown` apps by words with their share of the whole range.
    /// Shares are allocated across every app, then cut, so the shown ones
    /// never add up past 100.
    static func shares(_ slices: [HistoryStore.BreakdownSlice]) -> [StatsAppShare] {
        let total = slices.reduce(0) { $0 + $1.words }
        guard total > 0 else { return [] }
        let ranked = slices.sorted { $0.words > $1.words }
        let percents = StatsPercent.allocate(ranked.map(\.words))
        return zip(ranked, percents).prefix(shown).map { slice, percent in
            StatsAppShare(name: slice.name, words: slice.words, percent: percent)
        }
    }
}

/// The selected range's hour buckets, apps, modes and latency, from the
/// store's uncapped SQL summary (`HistoryStore.rangeSummary`), so every card
/// describes the same rows as the headline.
struct StatsRangeDetail: Equatable {
    static let hoursPerDay = 24
    /// Nearest-rank percentile for "slowest 5 %".
    static let slowestPercentile = 0.95

    var hourlyWords: [Int] = Array(repeating: 0, count: hoursPerDay)
    /// Dictations and speaking time per hour: today's tile sparklines.
    var hourlyCounts: [Int] = Array(repeating: 0, count: hoursPerDay)
    var hourlySpokenMs: [Int] = Array(repeating: 0, count: hoursPerDay)
    var apps: [HistoryStore.BreakdownSlice] = []
    /// The newest bundle id seen for each app name: the Where chart's icons.
    var appBundles: [String: String] = [:]
    /// Words per mode (display name): the Modes bar.
    var modes: [HistoryStore.BreakdownSlice] = []
    /// Every stop-to-final wall time (`finalizationMs`), ascending: the
    /// Ready in histogram.
    var readyMs: [Int] = []
    /// Stop-to-final wall time (`finalizationMs`) percentiles.
    var readyMedianMs: Int?
    var readySlowestMs: Int?
    /// Words per weekday × hour, from the store's grid query.
    var weekdayHour: [HistoryStore.WeekdayHourSample] = []

    /// Lays the store's summary into the cards' shapes: 24 hour buckets,
    /// modes folded to display names ("" and "default" both read
    /// "Default"), and the latency percentiles.
    static func make(
        summary: HistoryStore.RangeSummary, weekdayHour: [HistoryStore.WeekdayHourSample] = []
    ) -> StatsRangeDetail {
        var detail = StatsRangeDetail()
        for sample in summary.hours where (0..<hoursPerDay).contains(sample.hour) {
            detail.hourlyWords[sample.hour] += sample.words
            detail.hourlyCounts[sample.hour] += sample.count
            detail.hourlySpokenMs[sample.hour] += sample.spokenMs
        }

        detail.apps = summary.apps
        detail.appBundles = summary.appBundles
        var modeWords: [String: (count: Int, words: Int)] = [:]
        for slice in summary.modes {
            let name = HistoryJournal.modeName(slice.name)
            let entry = modeWords[name] ?? (0, 0)
            modeWords[name] = (entry.count + slice.count, entry.words + slice.words)
        }
        detail.modes = slices(modeWords)

        detail.readyMs = summary.readyMs
        detail.readyMedianMs = percentile(detail.readyMs, 0.5)
        detail.readySlowestMs = percentile(detail.readyMs, slowestPercentile)
        detail.weekdayHour = weekdayHour
        return detail
    }

    /// Tallies as slices, most words first (ties by name, so the order is
    /// stable across reloads).
    private static func slices(_ tally: [String: (count: Int, words: Int)]) -> [HistoryStore.BreakdownSlice] {
        tally
            .map { HistoryStore.BreakdownSlice(name: $0.key, count: $0.value.count, words: $0.value.words) }
            .sorted { ($0.words, $1.name) > ($1.words, $0.name) }
    }

    /// Nearest-rank percentile of an ascending list; nil when empty.
    static func percentile(_ sorted: [Int], _ p: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// One bar of the words chart: an hour, a day or a month.
struct StatsBar: Equatable, Identifiable {
    /// Start of the bucket; the chart's x value.
    let date: Date
    let label: String
    let words: Int
    var count = 0
    var spokenMs = 0

    var id: Date { date }
}

/// Builds the chart series per range: hours today, days for 7 / 30 days,
/// and months for all time (a bar per day of a year-long history would be
/// a hairline).
enum StatsSeries {
    /// Most months the all-time chart draws; older months drop off the left.
    static let maxMonths = 24

    static func bars(
        range: StatsRange, insights: HistoryStore.Insights, detail: StatsRangeDetail,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [StatsBar] {
        switch range {
        case .today:
            return hourBars(detail: detail, now: now, calendar: calendar)
        case .sevenDays, .thirtyDays:
            return days(count: range.dayCount ?? 0, daily: insights.daily, now: now, calendar: calendar)
        case .allTime:
            return monthBars(monthly: insights.monthly, now: now, calendar: calendar)
        }
    }

    /// The bucket a range's bars stand for: "Words per <unit>".
    static func unit(for range: StatsRange) -> String {
        switch range {
        case .today: return "hour"
        case .sevenDays, .thirtyDays: return "day"
        case .allTime: return "month"
        }
    }

    /// The words card title. All time draws at most `maxMonths` bars, so a
    /// longer history says where the chart starts.
    ///
    ///     "Words per day"   "Words per month, last 24 months"
    static func title(
        range: StatsRange, insights: HistoryStore.Insights,
        now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let base = "Words per \(unit(for: range))"
        guard range == .allTime, monthsSinceFirst(monthly: insights.monthly, now: now, calendar: calendar) > maxMonths else {
            return base
        }
        return "\(base), last \(maxMonths) months"
    }

    /// Mean words per bar, empty bars included (the chart's average rule).
    static func average(_ bars: [StatsBar]) -> Double {
        guard !bars.isEmpty else {
            return 0
        }
        return Double(bars.reduce(0) { $0 + $1.words }) / Double(bars.count)
    }

    /// "Best day Sep 30 · 1,240 words" (hour / month per range); nil when
    /// every bar is empty.
    static func bestCaption(bars: [StatsBar], range: StatsRange) -> String? {
        guard let best = bars.max(by: { $0.words < $1.words }), best.words > 0 else {
            return nil
        }
        return "Best \(unit(for: range)) \(best.label) · \(HistoryJournal.plural(best.words, "word"))"
    }

    /// The last `count` calendar days ending today, zero-filled. Home's
    /// week card draws the same seven.
    static func days(
        count: Int, daily: [HistoryStore.DaySample], now: Date, calendar: Calendar
    ) -> [StatsBar] {
        let byDay = Dictionary(daily.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let today = calendar.startOfDay(for: now)
        let style = DayKeys.style(.dateTime.month(.abbreviated).day(), calendar)
        return (0..<count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let sample = byDay[DayKeys.dayKey(date, calendar: calendar)]
            return StatsBar(
                date: date, label: date.formatted(style), words: sample?.words ?? 0,
                count: sample?.count ?? 0, spokenMs: sample?.spokenMs ?? 0)
        }
    }

    /// Calendar months from the first active month through this one,
    /// inclusive; 1 for an empty history (this month alone).
    private static func monthsSinceFirst(
        monthly: [HistoryStore.MonthSample], now: Date, calendar: Calendar
    ) -> Int {
        let gregorian = DayKeys.gregorian(calendar)
        guard let thisMonth = gregorian.dateInterval(of: .month, for: now)?.start,
              let first = monthly.first.flatMap({ DayKeys.date(monthKey: $0.month, calendar: calendar) })
        else {
            return 1
        }
        let span = gregorian.dateComponents([.month], from: first, to: thisMonth).month ?? 0
        return max(span, 0) + 1
    }

    /// Today's wall-clock hours, from the range summary. Each bar starts at
    /// its own local hour, matching SQLite's `%H` buckets; midnight + n
    /// hours drifts by one on DST days. An hour the clocks skip (spring
    /// forward) has no bar.
    ///
    ///     Europe/London, 29 Mar:  00  02  03 … 23   (23 bars, no 01)
    private static func hourBars(detail: StatsRangeDetail, now: Date, calendar: Calendar) -> [StatsBar] {
        let today = calendar.startOfDay(for: now)
        let style = DayKeys.style(.dateTime.hour(), calendar)
        var starts = Set<Date>()
        return (0..<StatsRangeDetail.hoursPerDay).compactMap { hour in
            // A skipped hour resolves to the next one; drop it rather than
            // draw two bars on one start.
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today),
                  calendar.component(.hour, from: date) == hour,
                  starts.insert(date).inserted
            else {
                return nil
            }
            return StatsBar(
                date: date, label: date.formatted(style), words: detail.hourlyWords[hour],
                count: detail.hourlyCounts[hour], spokenMs: detail.hourlySpokenMs[hour])
        }
    }

    /// One bar per month from the first active month (at most `maxMonths`
    /// back) through this month, zero-filled. Month maths runs in the
    /// Gregorian calendar because the store's `yyyy-MM` keys are Gregorian.
    ///
    ///     monthly: 2026-06, 2026-09      now: Sep 2026
    ///     bars:    Jun  Jul  Aug  Sep    (Jul and Aug empty)
    private static func monthBars(
        monthly: [HistoryStore.MonthSample], now: Date, calendar: Calendar
    ) -> [StatsBar] {
        let gregorian = DayKeys.gregorian(calendar)
        guard let thisMonth = gregorian.dateInterval(of: .month, for: now)?.start else {
            return []
        }

        let byMonth = Dictionary(monthly.map { ($0.month, $0) }, uniquingKeysWith: { first, _ in first })
        let count = min(monthsSinceFirst(monthly: monthly, now: now, calendar: calendar), maxMonths)
        let style = DayKeys.style(.dateTime.month(.abbreviated).year(), calendar)
        return (0..<count).reversed().map { back in
            let date = gregorian.date(byAdding: .month, value: -back, to: thisMonth) ?? thisMonth
            let sample = byMonth[DayKeys.monthKey(date, calendar: calendar)]
            return StatsBar(
                date: date, label: date.formatted(style), words: sample?.words ?? 0,
                count: sample?.count ?? 0, spokenMs: sample?.spokenMs ?? 0)
        }
    }
}

/// The Ready in histogram: stop-to-final times in 1 s bins, everything
/// from 10 s up in one overflow bin.
///
///     0 s  1 s  2 s … 9 s  10 s+
///     ▇▇   ▅▅   ▂▂    ·    ▁▁
enum StatsLatency {
    static let binSeconds = 1
    static let overflowSeconds = 10
    static let binCount = overflowSeconds / binSeconds + 1
    /// Fewer samples than this draw a note instead of a histogram.
    static let minimumSamples = 5

    struct Bin: Equatable, Identifiable {
        /// Lower edge in seconds.
        let start: Int
        let count: Int

        var isOverflow: Bool { start >= StatsLatency.overflowSeconds }
        var id: Int { start }
    }

    static func bins(_ ms: [Int]) -> [Bin] {
        var counts = Array(repeating: 0, count: binCount)
        for value in ms {
            let index = min(max(value, 0) / (binSeconds * 1000), binCount - 1)
            counts[index] += 1
        }
        return counts.enumerated().map { Bin(start: $0.offset * binSeconds, count: $0.element) }
    }
}

/// The Modes bar: the top modes by words, the rest folded into "Other".
enum StatsModes {
    static let shown = 3
    static let otherName = "Other"

    /// Shares of ALL words in the range, top `shown` first, then Other.
    static func shares(_ slices: [HistoryStore.BreakdownSlice]) -> [StatsAppShare] {
        let total = slices.reduce(0) { $0 + $1.words }
        guard total > 0 else {
            return []
        }

        let ranked = slices.sorted { $0.words > $1.words }
        var groups = ranked.prefix(shown).map { (name: $0.name, words: $0.words) }
        let rest = ranked.dropFirst(shown).reduce(0) { $0 + $1.words }
        if rest > 0 {
            groups.append((name: otherName, words: rest))
        }
        // The bar shows exactly these groups, so they total 100.
        let percents = StatsPercent.allocate(groups.map(\.words))
        return zip(groups, percents).map { group, percent in
            StatsAppShare(name: group.name, words: group.words, percent: percent)
        }
    }
}

/// One day of the "Last 12 weeks" calendar.
struct StatsCalendarCell: Equatable, Identifiable {
    let date: Date
    /// Week column, 0 = the oldest week.
    let column: Int
    /// Weekday row, 0 = the locale's first weekday.
    let row: Int
    let words: Int

    var id: Date { date }
}

/// Lays the last `HistoryStore.heatmapDays` days out in weekday rows and
/// week columns, today in the last cell.
///
///          col 0   col 1  …  col 12
///     Mon          ■          ■
///     Tue          ■          ■  ← today
///     Wed   ■      ■
enum StatsCalendar {
    static func cells(
        daily: [HistoryStore.DaySample], now: Date = Date(), calendar: Calendar = .current
    ) -> [StatsCalendarCell] {
        let words = Dictionary(daily.map { ($0.day, $0.words) }, uniquingKeysWith: +)
        let today = calendar.startOfDay(for: now)
        let dayCount = HistoryStore.heatmapDays
        guard let first = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else {
            return []
        }

        let firstRow = StatsWeekdays.row(of: first, calendar: calendar)
        return (0..<dayCount).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: first) else {
                return nil
            }
            let slot = index + firstRow
            return StatsCalendarCell(
                date: date, column: slot / StatsWeekdays.count, row: slot % StatsWeekdays.count,
                words: words[DayKeys.dayKey(date, calendar: calendar)] ?? 0)
        }
    }
}

/// Weekday rows in the locale's order (Monday first in most of Europe,
/// Sunday first in the US).
enum StatsWeekdays {
    static let count = 7

    /// Weekday numbers (1 = Sunday) in display order.
    static func order(calendar: Calendar) -> [Int] {
        (0..<count).map { (calendar.firstWeekday - 1 + $0) % count + 1 }
    }

    /// 0-based display row of `date`'s weekday.
    static func row(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) - calendar.firstWeekday + count) % count
    }

    /// "Mon".
    static func symbol(_ weekday: Int, calendar: Calendar) -> String {
        calendar.shortWeekdaySymbols[(weekday - 1) % count]
    }
}

/// The Active days tile: days with a dictation against the days in range.
enum StatsActivity {
    struct Days: Equatable {
        let active: Int
        let total: Int
    }

    /// All time runs from the first active day through today, inclusive.
    static func activeDays(
        range: StatsRange, insights: HistoryStore.Insights,
        now: Date = Date(), calendar: Calendar = .current
    ) -> Days {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .today:
            return Days(active: insights.today.count > 0 ? 1 : 0, total: 1)
        case .sevenDays, .thirtyDays:
            let total = range.dayCount ?? 0
            let start = calendar.date(byAdding: .day, value: -(total - 1), to: today) ?? today
            // yyyy-MM-dd keys sort in date order.
            let startKey = DayKeys.dayKey(start, calendar: calendar)
            return Days(active: insights.daily.filter { $0.day >= startKey }.count, total: total)
        case .allTime:
            guard let firstDay = insights.firstDay,
                  let first = DayKeys.date(dayKey: firstDay, calendar: calendar)
            else {
                return Days(active: 0, total: 0)
            }
            let span = calendar.dateComponents([.day], from: first, to: today).day ?? 0
            return Days(active: insights.activeDayCount, total: max(span, 0) + 1)
        }
    }

    /// Days the tile's dot strip draws. Today (the Streak tile) shows its
    /// week; all time shows the last 30 days, since `insights.daily` only
    /// reaches back `HistoryStore.heatmapDays` and 84 dots don't fit a tile.
    static let weekStrip = 7
    static let monthStrip = 30

    /// One flag per day, oldest first, today last: true when that day has
    /// a dictation.
    ///
    ///     7 days:  ● ● ● ● ○ ○ ○    (Sep 2 … Sep 8)
    static func strip(
        range: StatsRange, insights: HistoryStore.Insights,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [Bool] {
        let count: Int
        switch range {
        case .today, .sevenDays: count = weekStrip
        case .thirtyDays, .allTime: count = monthStrip
        }

        let active = Set(insights.daily.filter { $0.count > 0 }.map(\.day))
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else {
                return false
            }
            return active.contains(DayKeys.dayKey(date, calendar: calendar))
        }
    }
}

// MARK: - View model

/// Backs the Stats pane. Aggregates are full-table SQL scans, so they load
/// off the main thread; the per-range detail is a bounded newest-first page
/// scan (hour buckets, latency, apps, modes) for the same window plus the
/// store's weekday × hour grid.
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
    /// background — `insights()` plus the range summary is too much for the
    /// main thread.
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
            let detail = Self.loadDetail(store: store, range: range)
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
        detail = Self.loadDetail(store: history, range: range)
        typingWPM = AppConfig.shared.typingWPM
        loaded = true
    }

    private func reloadDetail() {
        generation += 1
        let generation = generation
        let store = history
        let range = range
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = Self.loadDetail(store: store, range: range)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.detail = detail
            }
        }
    }

    /// Reads the typing speed again after the Time saved popover changed it.
    func refreshTypingWPM() {
        typingWPM = AppConfig.shared.typingWPM
    }

    /// The range's SQL summary plus the weekday × hour grid for the heatmap.
    private static func loadDetail(store: HistoryStore, range: StatsRange) -> StatsRangeDetail {
        StatsRangeDetail.make(
            summary: store.rangeSummary(daysBack: range.daysBack),
            weekdayHour: store.weekdayHourWords(daysBack: range.daysBack))
    }
}

// MARK: - Header controls

/// The Stats pane's title-row controls: the range picker and the Share
/// capsule. The shell places this beside its `PaneHeader`.
struct StatsHeaderControls: View {
    @ObservedObject var viewModel: IntelligenceViewModel

    /// The Stats symbol (DESIGN.md §7) stands in for the card in the share
    /// sheet's preview, so nothing renders until something is shared.
    private static let previewSymbol = "chart.bar.fill"

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
            ShareLink(
                item: StatsShareImage(card: viewModel.shareCard),
                preview: SharePreview(IntelligenceShareCard.title, image: Image(systemName: Self.previewSymbol))
            ) {
                Text("Share…")
            }
            .buttonStyle(.capsule)
            .help("Aggregate numbers only. Never transcripts, app names, or contacts.")
        }
    }
}

// MARK: - Pane

/// The Stats pane: a serif pace sentence, four tiles with deltas and
/// sparklines, the words chart, then two rows of Swift Charts cards. The
/// shell draws the title and `StatsHeaderControls` above it.
///
///     You speak at 125 wpm, 3.1× your typing speed.
///     [Words ↑9%] [Time saved] [Dictations ↑4%] [Active days 21 of 30]
///     ┌ Words per day ──────────── Best day Sep 30 · 1,240 words ┐
///     └──────────────────────────────────────────────────────────┘
///     ┌ When you dictate ─────────────┐ ┌ Where ───────┐
///     ┌ Ready in ──────┐ ┌ Modes ──┐ ┌ Last 12 weeks ┐
struct IntelligenceSettingsView: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var vm: IntelligenceViewModel
    @State private var editingTypingSpeed = false

    private static let sectionSpacing: CGFloat = 18
    /// Widths of the narrow cards beside a flexible one.
    private static let whereWidth: CGFloat = 250
    private static let modesWidth: CGFloat = 220
    private static let calendarWidth: CGFloat = 240
    /// The typing-speed popover's stepper bounds (words per minute).
    private static let typingRange = 10...200
    private static let typingStep = 5
    private static let popoverWidth: CGFloat = 260

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
        .onChange(of: model.typingWPM) { vm.refreshTypingWPM() }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        let bars = StatsSeries.bars(range: vm.range, insights: vm.insights, detail: vm.detail)
        return ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                SerifHeadline(headline)
                tiles(bars: bars)
                wordsCard(bars: bars)
                // Cards in a row stretch to the tallest one.
                HStack(alignment: .top, spacing: VeloraSpacing.m) {
                    if vm.range != .today {
                        whenCard
                        whereCard.frame(width: Self.whereWidth)
                    } else {
                        whereCard
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: VeloraSpacing.m) {
                    readyCard
                    modesCard.frame(width: Self.modesWidth)
                    calendarCard.frame(width: Self.calendarWidth)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, VeloraSpacing.xl)
        }
    }

    /// The pace sentence when there's enough speech to quote one, else
    /// "14,860 words in the last 30 days".
    private var headline: String {
        let stats = vm.stats
        return StatsHeadline.pace(words: stats.words, spokenMs: stats.spokenMs, typingWPM: vm.typingWPM)
            ?? StatsHeadline.words(stats.words, range: vm.range)
    }

    // MARK: Tiles

    /// Words · Time saved (the accent number) · Dictations · Active days,
    /// each with a delta or context line and a sparkline of the chart's
    /// buckets (Active days: a dot per day). Today swaps Active days for
    /// the streak.
    ///
    /// Four across while every caption fits on one line; narrower (the
    /// 960 pt minimum window leaves each tile about 138 pt) a 2 × 2 grid,
    /// so "at 40 wpm typing · Change…" is never clipped.
    ///
    ///     ┌ Words ┐┌ Saved ┐┌ Dict. ┐┌ Days ┐      ┌ Words ─┐┌ Saved ─┐
    ///     └───────┘└───────┘└───────┘└──────┘  or  ┌ Dict. ─┐┌ Days ──┐
    private func tiles(bars: [StatsBar]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VeloraSpacing.m) {
                wordsTile(bars: bars)
                savedTile(bars: bars)
                dictationsTile(bars: bars)
                activityTile
            }
            .fixedSize(horizontal: false, vertical: true)
            Grid(horizontalSpacing: VeloraSpacing.m, verticalSpacing: VeloraSpacing.m) {
                GridRow {
                    wordsTile(bars: bars)
                    savedTile(bars: bars)
                }
                GridRow {
                    dictationsTile(bars: bars)
                    activityTile
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wordsTile(bars: [StatsBar]) -> some View {
        let previous = vm.range.previousStats(in: vm.insights)
        return StatTile(
            label: "Words", value: HistoryJournal.grouped(vm.stats.words),
            trend: .series(bars.map { Double($0.words) })
        ) {
            tileCaption(StatsFormat.delta(vm.stats.words, previous?.words ?? 0, range: vm.range) ?? noDelta)
        }
    }

    private func savedTile(bars: [StatsBar]) -> some View {
        let saved = bars.map {
            Double(HistoryStore.minutesSaved(words: $0.words, spokenMs: $0.spokenMs, typingWPM: vm.typingWPM))
        }
        return StatTile(
            label: "Time saved", value: StatsFormat.clock(minutes: vm.stats.minutesSaved(typingWPM: vm.typingWPM)),
            emphasis: .accent, trend: .series(saved)
        ) {
            typingSpeedCaption
        }
    }

    private func dictationsTile(bars: [StatsBar]) -> some View {
        let previous = vm.range.previousStats(in: vm.insights)
        return StatTile(
            label: "Dictations", value: HistoryJournal.grouped(vm.stats.count),
            trend: .series(bars.map { Double($0.count) })
        ) {
            tileCaption(StatsFormat.delta(vm.stats.count, previous?.count ?? 0, range: vm.range) ?? noDelta)
        }
    }

    /// Today has no "of N days", so its fourth tile is the streak.
    @ViewBuilder
    private var activityTile: some View {
        let longest = "\(HistoryJournal.plural(vm.insights.longestStreak, "day"))"
        let strip = StatTileTrend.days(StatsActivity.strip(range: vm.range, insights: vm.insights))
        if vm.range == .today {
            StatTile(label: "Streak", value: HistoryJournal.plural(vm.insights.currentStreak, "day"), trend: strip) {
                tileCaption("Longest \(longest)")
            }
        } else {
            let days = StatsActivity.activeDays(range: vm.range, insights: vm.insights)
            StatTile(
                label: "Active days",
                value: "\(HistoryJournal.grouped(days.active)) of \(HistoryJournal.grouped(days.total))",
                trend: strip
            ) {
                tileCaption("Longest streak \(longest)")
            }
        }
    }

    /// The caption when there's no delta: where all time starts, or that
    /// the earlier window was empty.
    private var noDelta: String {
        guard vm.range == .allTime else {
            return "Nothing to compare yet"
        }
        guard let firstDay = vm.insights.firstDay,
              let first = DayKeys.date(dayKey: firstDay, calendar: .current)
        else {
            return "All time"
        }
        return "Since " + first.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private func tileCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    /// "at 40 wpm typing · Change…": the popover edits the speed Time saved
    /// is measured against (Settings has no other control for it).
    private var typingSpeedCaption: some View {
        HStack(spacing: 3) {
            tileCaption("at \(vm.typingWPM) wpm typing ·")
            // The only typing-speed control: the text truncates first.
            Button("Change…") { editingTypingSpeed = true }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(VeloraBrand.link)
                .fixedSize()
                .layoutPriority(1)
                .popover(isPresented: $editingTypingSpeed, arrowEdge: .bottom) {
                    typingSpeedEditor
                }
        }
    }

    private var typingSpeedEditor: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            Stepper(value: $model.typingWPM, in: Self.typingRange, step: Self.typingStep) {
                Text("Typing speed: \(model.typingWPM) wpm")
                    .monospacedDigit()
            }
            Text("Time saved compares your speaking time with typing the same words at this speed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VeloraSpacing.l)
        .frame(width: Self.popoverWidth)
    }

    // MARK: Words chart

    private func wordsCard(bars: [StatsBar]) -> some View {
        StatsChartCard(
            title: StatsSeries.title(range: vm.range, insights: vm.insights),
            caption: StatsSeries.bestCaption(bars: bars, range: vm.range)
        ) {
            StatsWordsChart(bars: bars, range: vm.range)
        }
    }

    // MARK: When and where

    private var whenCard: some View {
        StatsChartCard(title: "When you dictate", caption: "Words by hour, \(vm.range.windowPhrase)") {
            if vm.detail.weekdayHour.isEmpty {
                StatsEmptyNote(text: Self.emptyRange)
            } else {
                StatsHourHeatmap(cells: vm.detail.weekdayHour)
            }
        }
    }

    private var whereCard: some View {
        let shares = StatsTopApps.shares(vm.detail.apps)
        return StatsChartCard(title: "Where", caption: shares.isEmpty ? nil : "Share of words") {
            if shares.isEmpty {
                StatsEmptyNote(text: Self.emptyRange)
            } else {
                StatsTopAppsChart(shares: shares, bundles: vm.detail.appBundles)
            }
        }
    }

    // MARK: Ready in, modes, calendar

    private var readyCard: some View {
        let ready = vm.detail.readyMs
        let enough = ready.count >= StatsLatency.minimumSamples
        return StatsChartCard(title: "Ready in", caption: enough ? readyCaption : nil) {
            if enough {
                StatsLatencyChart(
                    bins: StatsLatency.bins(ready),
                    medianMs: vm.detail.readyMedianMs ?? 0, slowMs: vm.detail.readySlowestMs ?? 0)
            } else {
                StatsEmptyNote(text: "Not enough dictations yet")
            }
        }
    }

    /// "Median 0.9 s · 95% under 2.1 s".
    private var readyCaption: String {
        let median = HistoryJournal.latency(ms: vm.detail.readyMedianMs ?? 0)
        let slow = HistoryJournal.latency(ms: vm.detail.readySlowestMs ?? 0)
        return "Median \(median) · 95% under \(slow)"
    }

    /// The mode split, then what cleanup and the edit watcher saw: only
    /// signals the stored rows back.
    private var modesCard: some View {
        let shares = StatsModes.shares(vm.detail.modes)
        return StatsChartCard(title: "Modes") {
            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                if shares.isEmpty {
                    StatsEmptyNote(text: Self.emptyRange)
                } else {
                    StatsModesChart(shares: shares)
                }
                ForEach(qualityNotes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Cleanup rewrote 120 of 400 dictations", "You edited 3 of 41
    /// afterwards". Each drops out when its rows carry no data.
    private var qualityNotes: [String] {
        let stats = vm.stats
        var notes: [String] = []
        if stats.cleanupKnown > 0 {
            notes.append("Cleanup rewrote \(HistoryJournal.grouped(stats.cleanupChanged)) of "
                         + HistoryJournal.plural(stats.cleanupKnown, "dictation"))
        }
        if stats.qualityObserved > 0 {
            notes.append("You edited \(HistoryJournal.grouped(stats.qualityEdited)) of "
                         + "\(HistoryJournal.grouped(stats.qualityObserved)) afterwards")
        }
        return notes
    }

    private var calendarCard: some View {
        let active = vm.insights.heatmapDaily.count
        return StatsChartCard(title: "Last 12 weeks", caption: HistoryJournal.plural(active, "active day")) {
            StatsActivityCalendar(cells: StatsCalendar.cells(daily: vm.insights.heatmapDaily))
        }
    }

    private static let emptyRange = "Nothing in this range yet"

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

// MARK: - Shared day math

/// `yyyy-MM-dd` / `yyyy-MM` keys matching SQLite's, and label styles, in a
/// given calendar's time zone (the selftest pins Europe/London).
private enum DayKeys {
    /// Gregorian in `calendar`'s zone: the store's keys are Gregorian
    /// ASCII whatever calendar the user reads dates in.
    static func gregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// "2026-09-08".
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        return [pad(parts.year, 4), pad(parts.month, 2), pad(parts.day, 2)].joined(separator: "-")
    }

    /// "2026-09".
    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let parts = gregorian(calendar).dateComponents([.year, .month], from: date)
        return [pad(parts.year, 4), pad(parts.month, 2)].joined(separator: "-")
    }

    /// Local midnight of a "2026-09-08" key.
    static func date(dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            return nil
        }
        return gregorian(calendar).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Local midnight on the 1st of a "2026-09" key.
    static func date(monthKey: String, calendar: Calendar) -> Date? {
        let parts = monthKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else {
            return nil
        }
        return gregorian(calendar).date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }

    /// `base` rendered in `calendar`'s zone.
    static func style(_ base: Date.FormatStyle, _ calendar: Calendar) -> Date.FormatStyle {
        var style = base
        style.timeZone = calendar.timeZone
        return style
    }

    /// Zero-padded ASCII digits (never locale digits).
    private static func pad(_ value: Int?, _ width: Int) -> String {
        let digits = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
