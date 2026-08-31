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

// MARK: - View model

/// Backs the Stats tab. Aggregates are full-table SQL scans, so they load off
/// the main thread like the History header stats.
final class IntelligenceViewModel: ObservableObject {
    @Published var insights = HistoryStore.Insights()
    @Published private(set) var loaded = false

    private let history: HistoryStore

    init(history: HistoryStore) {
        self.history = history
    }

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fresh = self.history.insights()
            DispatchQueue.main.async {
                self.insights = fresh
                self.loaded = true
            }
        }
    }
}

// MARK: - Tab

/// The Stats dashboard: hero metric tiles, streak + 12-week heatmap, hoverable
/// daily activity chart, app/mode breakdowns, and latency/accuracy cards.
/// Charts stay hand-rolled (zero-dependency convention).
struct IntelligenceSettingsView: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var vm: IntelligenceViewModel
    @State private var window: StatsWindow = .week

    enum StatsWindow: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "Today"
            case .week: return "7 days"
            case .month: return "30 days"
            case .all: return "All time"
            }
        }
    }

    init(model: SettingsModel, history: HistoryStore) {
        self.model = model
        _vm = StateObject(wrappedValue: IntelligenceViewModel(history: history))
    }

    /// Snapshot renderer: inject a preloaded view model so the offscreen
    /// render doesn't race `.onAppear`'s async reload.
    init(model: SettingsModel, viewModel: IntelligenceViewModel) {
        self.model = model
        _vm = StateObject(wrappedValue: viewModel)
    }

    private var stats: HistoryStore.WindowStats {
        switch window {
        case .today: return vm.insights.today
        case .week: return vm.insights.week
        case .month: return vm.insights.month
        case .all: return vm.insights.allTime
        }
    }

    private var sharePeriod: IntelligenceShareCard.Period {
        switch window {
        case .today: return .today
        case .week: return .week
        case .month: return .month
        case .all: return .allTime
        }
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

    // MARK: Dashboard layout

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                Picker("Window", selection: $window) {
                    ForEach(StatsWindow.allCases) { w in
                        Text(w.title).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                heroTiles
                streakCard
                activityCard
                breakdownRow
                insightRow
                shareCard
            }
            .padding(VeloraSpacing.xl)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Hero tiles

    private var heroTiles: some View {
        HStack(spacing: VeloraSpacing.m) {
            StatTile(
                symbol: "textformat", color: VeloraBrand.violet.color,
                value: IntelligenceShareCard.compact(stats.words), label: "words")
            StatTile(
                symbol: "mic.fill", color: .blue,
                value: IntelligenceShareCard.compact(stats.count), label: "dictations")
            StatTile(
                symbol: "waveform", color: .teal,
                value: Self.spoken(ms: stats.spokenMs), label: "speaking time")
            StatTile(
                symbol: "clock.badge.checkmark", color: .green,
                value: IntelligenceShareCard.duration(
                    minutes: stats.minutesSaved(typingWPM: model.typingWPM)),
                label: "saved vs typing")
        }
    }

    // MARK: Streak + heatmap

    private var streakCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: VeloraSpacing.xl) {
                VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                    HStack(spacing: VeloraSpacing.s) {
                        IconTile(symbol: "flame.fill", color: .orange, side: 26)
                        Text("Streak")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(Self.days(vm.insights.currentStreak))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("Longest: \(Self.days(vm.insights.longestStreak))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: VeloraSpacing.l)
                ActivityHeatmap(daily: vm.insights.heatmapDaily)
            }
        }
    }

    // MARK: Daily activity

    private var activityCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "chart.bar.fill", color: .blue,
                title: "Daily activity",
                subtitle: "Words dictated each day — last 30 days")
            DailyActivityChart(daily: vm.insights.daily)
        }
    }

    // MARK: Breakdowns

    @ViewBuilder
    private var breakdownRow: some View {
        let monthWords = vm.insights.month.words
        if !vm.insights.apps.isEmpty || !vm.insights.modes.isEmpty {
            HStack(alignment: .top, spacing: VeloraSpacing.m) {
                if !vm.insights.apps.isEmpty {
                    SettingsCard {
                        CardHeader(
                            symbol: "square.grid.2x2.fill", color: .indigo,
                            title: "Where you dictate",
                            subtitle: "Top apps — last 30 days")
                        BreakdownList(slices: vm.insights.apps, totalWords: monthWords)
                    }
                }
                if !vm.insights.modes.isEmpty {
                    SettingsCard {
                        CardHeader(
                            symbol: "slider.horizontal.3", color: .teal,
                            title: "Modes",
                            subtitle: "Top modes — last 30 days")
                        BreakdownList(slices: vm.insights.modes, totalWords: monthWords)
                    }
                }
            }
        }
    }

    // MARK: Performance + accuracy

    private var insightRow: some View {
        HStack(alignment: .top, spacing: VeloraSpacing.m) {
            SettingsCard {
                CardHeader(
                    symbol: "speedometer", color: .purple,
                    title: "Performance",
                    subtitle: window.title)
                CardMetricRow(
                    label: "Speech-to-text (avg)",
                    value: Self.latency(stats.averageSttMs, samples: stats.sttSamples))
                CardMetricRow(
                    label: "Model cleanup (avg)",
                    value: Self.latency(stats.averageCleanupMs, samples: stats.cleanupSamples))
                CardMetricRow(
                    label: "Cleanup wall (avg)",
                    value: Self.latency(
                        stats.averageCleanupWallMs, samples: stats.cleanupWallSamples))
                CardMetricRow(
                    label: "Stop to final (avg)",
                    value: Self.latency(
                        stats.averageFinalizationMs, samples: stats.finalizationSamples))
                CardDivider()
                CardMetricRow(label: "Cleanup applied", value: Self.rate(stats.cleanupAppliedRate))
                CardMetricRow(
                    label: "Cleanup changed the raw",
                    value: Self.rate(stats.cleanupChangedRate))
            }
            SettingsCard {
                CardHeader(
                    symbol: "checkmark.seal.fill", color: .green,
                    title: "Accuracy signals",
                    subtitle: window.title)
                CardMetricRow(label: "Kept without edits", value: Self.rate(stats.zeroEditRate))
                CardMetricRow(
                    label: "Observation coverage",
                    value: Self.rate(stats.observationCoverage))
                CardMetricRow(label: "Learned terms (all time)", value: "\(learnedTermCount)")
                Spacer(minLength: 0)
                Text("“Kept without edits” counts only dictations Velora could verify after inserting — coverage shows how many that is.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var learnedTermCount: Int {
        model.dictionaryRows.filter { $0.source == .learned }.count
    }

    // MARK: Share

    private var shareCard: some View {
        SettingsCard {
            CardHeader(
                symbol: "square.and.arrow.up.fill", color: VeloraBrand.violet.color,
                title: "Share your stats",
                subtitle: "Aggregate numbers only — never transcripts, app names, or contacts."
            ) {
                if let image = renderedCardImage() {
                    ShareLink(
                        item: image,
                        preview: SharePreview(IntelligenceShareCard.title, image: image)
                    ) {
                        Label("Share \(window.title)…", systemImage: "square.and.arrow.up")
                    }
                }
            }
            CardDivider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Your typing speed")
                        .font(.system(size: 12))
                    Text("“Saved vs typing” compares speaking time against typing the same words at this speed.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Stepper(value: $model.typingWPM, in: 10...150, step: 5) {
                    Text("\(model.typingWPM) wpm")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
    }

    /// Renders the aggregate-only card locally for the selected window.
    private func renderedCardImage() -> Image? {
        let card = IntelligenceShareCard(
            period: sharePeriod,
            words: stats.words,
            dictations: stats.count,
            minutesSaved: stats.minutesSaved(typingWPM: model.typingWPM),
            currentStreakDays: vm.insights.currentStreak)
        guard let nsImage = IntelligenceShareCardRenderer.image(for: card) else { return nil }
        return Image(nsImage: nsImage)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: VeloraSpacing.m) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44))
                .foregroundStyle(VeloraBrand.iconGradient)
            Text("No stats yet")
                .font(.title3.weight(.semibold))
            Text("Dictate a few times and your usage, streaks, latency, and accuracy trends appear here. Everything stays on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Formatting

    private static func days(_ n: Int) -> String {
        "\(n) day\(n == 1 ? "" : "s")"
    }

    private static func spoken(ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        return IntelligenceShareCard.duration(minutes: seconds / 60)
    }

    private static func latency(_ ms: Int?, samples: Int) -> String {
        guard let ms, samples > 0 else { return "No data yet" }
        return ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    private static func rate(_ value: Double?) -> String {
        guard let value else { return "No data yet" }
        return "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - Shared day math

/// yyyy-MM-dd keys and friendly labels shared by the chart and the heatmap.
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

    static func label(forKey key: String) -> String {
        guard let date = keyFormatter.date(from: key) else { return key }
        return labelFormatter.string(from: date)
    }
}

// MARK: - Activity heatmap

/// GitHub-style contribution grid over the last 12 weeks: one column per
/// week, Monday-first rows, word count mapped to violet intensity.
/// Hand-rolled (zero-dependency convention).
private struct ActivityHeatmap: View {
    let daily: [HistoryStore.DaySample]

    private static let cellSide: CGFloat = 11
    private static let cellGap: CGFloat = 3

    private struct Cell: Identifiable {
        let id: Int
        /// nil words = leading/trailing pad outside the tracked span.
        let key: String?
        let words: Int?
    }

    /// Columns of 7 weekday rows (Monday first), oldest week leading.
    private var columns: [[Cell]] {
        let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.words) })
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var cells: [Cell] = []
        var id = 0
        // Leading pad aligns the first tracked day onto its weekday row.
        let firstDate = calendar.date(
            byAdding: .day, value: -(HistoryStore.heatmapDays - 1), to: today) ?? today
        for _ in 0..<Self.mondayRow(of: firstDate, calendar: calendar) {
            cells.append(Cell(id: id, key: nil, words: nil))
            id += 1
        }
        for offset in (0..<HistoryStore.heatmapDays).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let key = DayKeys.keyFormatter.string(from: date)
            cells.append(Cell(id: id, key: key, words: byDay[key] ?? 0))
            id += 1
        }
        while cells.count % 7 != 0 {
            cells.append(Cell(id: id, key: nil, words: nil))
            id += 1
        }
        return stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }
    }

    /// Weekday row with Monday = 0 (Calendar weekday has Sunday = 1).
    private static func mondayRow(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    var body: some View {
        let peak = max(daily.map(\.words).max() ?? 0, 1)
        VStack(alignment: .trailing, spacing: VeloraSpacing.xs) {
            HStack(alignment: .top, spacing: Self.cellGap) {
                weekdayGutter
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: Self.cellGap) {
                        ForEach(column) { cell in
                            cellView(cell, peak: peak)
                        }
                    }
                }
            }
            Text("Last 12 weeks")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var weekdayGutter: some View {
        VStack(spacing: Self.cellGap) {
            ForEach(
                Array(["M", "", "W", "", "F", "", ""].enumerated()), id: \.offset
            ) { _, label in
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10, height: Self.cellSide)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: Cell, peak: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch (cell.key, cell.words) {
        case (nil, _), (_, nil):
            shape.fill(Color.clear)
                .frame(width: Self.cellSide, height: Self.cellSide)
        case (let key?, let words?):
            shape.fill(fill(words: words, peak: peak))
                .frame(width: Self.cellSide, height: Self.cellSide)
                .help(words > 0
                      ? "\(DayKeys.label(forKey: key)) — \(words) words"
                      : "\(DayKeys.label(forKey: key)) — no dictation")
        }
    }

    private func fill(words: Int, peak: Int) -> Color {
        guard words > 0 else { return Color.primary.opacity(0.07) }
        let t = Double(words) / Double(peak)
        let opacity: Double
        switch t {
        case ..<0.25: opacity = 0.35
        case ..<0.5: opacity = 0.55
        case ..<0.75: opacity = 0.8
        default: opacity = 1.0
        }
        return VeloraBrand.violet.color.opacity(opacity)
    }
}

// MARK: - Daily activity chart

/// Hand-rolled 30-day bar chart (no Charts dependency, matching the app's
/// zero-dependency convention). Gradient bars, a dashed average line, and a
/// hover readout; missing days render as empty slots.
private struct DailyActivityChart: View {
    let daily: [HistoryStore.DaySample]

    @State private var hoveredDay: String?

    private static let barAreaHeight: CGFloat = 72

    /// The last 30 calendar days, oldest first, zero-filled where idle.
    private var series: [(day: String, words: Int)] {
        let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.words) })
        let calendar = Calendar.current
        return (0..<30).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = DayKeys.keyFormatter.string(from: date)
            return (day: key, words: byDay[key] ?? 0)
        }
    }

    var body: some View {
        let points = series
        let peak = max(points.map(\.words).max() ?? 0, 1)
        let activeDays = points.filter { $0.words > 0 }
        let average = activeDays.isEmpty
            ? 0 : activeDays.map(\.words).reduce(0, +) / activeDays.count

        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            hoverReadout(points: points, average: average)
            ZStack(alignment: .bottomLeading) {
                averageLine(average: average, peak: peak)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(points, id: \.day) { point in
                        bar(point: point, peak: peak)
                    }
                }
                .frame(height: Self.barAreaHeight, alignment: .bottom)
            }
            HStack {
                Text("30 days ago").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Today").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, VeloraSpacing.xs)
    }

    /// One line above the chart: the hovered day's exact count, or the
    /// active-day average when nothing is hovered.
    @ViewBuilder
    private func hoverReadout(points: [(day: String, words: Int)], average: Int) -> some View {
        if let hovered = hoveredDay,
           let point = points.first(where: { $0.day == hovered }) {
            Text("\(DayKeys.label(forKey: point.day)) — \(point.words) words")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        } else {
            Text(average > 0 ? "≈ \(average) words per active day" : "No activity yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func averageLine(average: Int, peak: Int) -> some View {
        if average > 0 {
            Line()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(.tertiary)
                .frame(height: 1)
                .offset(y: -Self.barAreaHeight * CGFloat(average) / CGFloat(peak))
        }
    }

    private func bar(point: (day: String, words: Int), peak: Int) -> some View {
        let hovered = hoveredDay == point.day
        return UnevenRoundedRectangle(
            topLeadingRadius: 2, bottomLeadingRadius: 0.5,
            bottomTrailingRadius: 0.5, topTrailingRadius: 2)
            .fill(barFill(words: point.words, hovered: hovered))
            .frame(height: max(3, Self.barAreaHeight * CGFloat(point.words) / CGFloat(peak)))
            .frame(maxWidth: .infinity)
            .onHover { inside in
                if inside {
                    hoveredDay = point.day
                } else if hoveredDay == point.day {
                    hoveredDay = nil
                }
            }
    }

    private func barFill(words: Int, hovered: Bool) -> AnyShapeStyle {
        guard words > 0 else {
            return AnyShapeStyle(Color.primary.opacity(0.07))
        }
        if hovered {
            return AnyShapeStyle(VeloraBrand.indigo.color)
        }
        return AnyShapeStyle(LinearGradient(
            colors: [VeloraBrand.violet.color, VeloraBrand.indigo.color],
            startPoint: .top, endPoint: .bottom))
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

// MARK: - Breakdown list

/// Ranked horizontal bars with a per-rank hue, share-of-total percentages,
/// and a soft track behind each fill.
private struct BreakdownList: View {
    let slices: [HistoryStore.BreakdownSlice]
    /// Denominator for the share label (words across the same 30-day window).
    let totalWords: Int

    private static let rankColors: [Color] = [
        VeloraBrand.violet.color, .blue, .teal, .green, .orange, .pink,
    ]

    var body: some View {
        let peak = max(slices.map(\.words).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: VeloraSpacing.s + 2) {
            ForEach(Array(slices.enumerated()), id: \.element.name) { rank, slice in
                row(slice: slice, color: Self.rankColors[rank % Self.rankColors.count],
                    peak: peak)
            }
        }
    }

    private func row(
        slice: HistoryStore.BreakdownSlice, color: Color, peak: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(slice.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: VeloraSpacing.s)
                Text(shareLabel(words: slice.words))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(4, geo.size.width * CGFloat(slice.words) / CGFloat(peak)))
                }
            }
            .frame(height: 6)
        }
        .help("\(slice.words) words across \(slice.count) dictations")
    }

    private func shareLabel(words: Int) -> String {
        let compact = IntelligenceShareCard.compact(words)
        guard totalWords > 0 else { return "\(compact) words" }
        let percent = Int((Double(words) / Double(totalWords) * 100).rounded())
        return "\(compact) words · \(percent)%"
    }
}
