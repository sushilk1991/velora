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

/// Backs the Intelligence tab. Aggregates are full-table SQL scans, so they
/// load off the main thread like the History header stats.
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
                form
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vm.reload() }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Window", selection: $window) {
                    ForEach(StatsWindow.allCases) { w in
                        Text(w.title).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                statTiles
            }
            Section("Streak") {
                LabeledContent("Current streak", value: Self.days(vm.insights.currentStreak))
                LabeledContent("Longest streak", value: Self.days(vm.insights.longestStreak))
            }
            Section("Daily activity — last 30 days") {
                DailyActivityChart(daily: vm.insights.daily)
            }
            if !vm.insights.apps.isEmpty {
                Section("Where you dictate — last 30 days") {
                    BreakdownList(slices: vm.insights.apps)
                }
            }
            if !vm.insights.modes.isEmpty {
                Section("Modes — last 30 days") {
                    BreakdownList(slices: vm.insights.modes)
                }
            }
            performanceSection
            qualitySection
            Section {
                Stepper(value: $model.typingWPM, in: 10...150, step: 5) {
                    LabeledContent("Your typing speed", value: "\(model.typingWPM) wpm")
                }
            } footer: {
                SettingsFooter("“Saved vs typing” compares your speaking time against typing the same words at this speed.")
            }
            shareSection
        }
        .formStyle(.grouped)
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        HStack(spacing: 0) {
            tile(IntelligenceShareCard.compact(stats.words), "words")
            tileDivider
            tile(IntelligenceShareCard.compact(stats.count), "dictations")
            tileDivider
            tile(Self.spoken(ms: stats.spokenMs), "speaking")
            tileDivider
            tile(
                IntelligenceShareCard.duration(
                    minutes: stats.minutesSaved(typingWPM: model.typingWPM)),
                "saved vs typing")
        }
        .padding(.vertical, VeloraSpacing.xs)
    }

    private var tileDivider: some View {
        Rectangle().fill(Color(.separatorColor)).frame(width: 1, height: 30)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Performance

    private var performanceSection: some View {
        Section {
            LabeledContent(
                "Speech-to-text latency (avg)",
                value: Self.latency(stats.averageSttMs, samples: stats.sttSamples))
            LabeledContent(
                "Model cleanup latency (avg)",
                value: Self.latency(stats.averageCleanupMs, samples: stats.cleanupSamples))
            LabeledContent(
                "Cleanup wall latency (avg)",
                value: Self.latency(
                    stats.averageCleanupWallMs,
                    samples: stats.cleanupWallSamples))
            LabeledContent(
                "Stop-to-final latency (avg)",
                value: Self.latency(
                    stats.averageFinalizationMs,
                    samples: stats.finalizationSamples))
            LabeledContent("Cleanup applied", value: Self.rate(stats.cleanupAppliedRate))
            LabeledContent("Cleanup changed the raw transcript", value: Self.rate(stats.cleanupChangedRate))
        } header: {
            Text("Performance — \(window.title.lowercased())")
        } footer: {
            SettingsFooter("Stop-to-final latency is recorded from 0.10.17; older dictations don't carry it.")
        }
    }

    // MARK: Quality

    private var qualitySection: some View {
        Section {
            LabeledContent("Kept without edits", value: Self.rate(stats.zeroEditRate))
            LabeledContent("Observation coverage", value: Self.rate(stats.observationCoverage))
            LabeledContent("Learned terms (all time)", value: "\(learnedTermCount)")
        } header: {
            Text("Accuracy signals — \(window.title.lowercased())")
        } footer: {
            SettingsFooter("“Kept without edits” counts only dictations Velora could verify after inserting — “Observation coverage” shows how many that is.")
        }
    }

    private var learnedTermCount: Int {
        model.dictionaryRows.filter { $0.source == .learned }.count
    }

    // MARK: Share

    private var shareSection: some View {
        Section {
            HStack {
                Text("Share your stats")
                Spacer()
                if let image = renderedCardImage() {
                    ShareLink(
                        item: image,
                        preview: SharePreview(IntelligenceShareCard.title, image: image)
                    ) {
                        Label("Share \(window.title)…", systemImage: "square.and.arrow.up")
                    }
                }
            }
        } footer: {
            SettingsFooter("The card contains aggregate numbers only — never transcripts, app names, or contacts.")
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

// MARK: - Daily activity chart

/// Hand-rolled 30-day bar chart (no Charts dependency, matching the app's
/// zero-dependency convention). Missing days render as empty slots.
private struct DailyActivityChart: View {
    let daily: [HistoryStore.DaySample]

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// The last 30 calendar days, oldest first, zero-filled where idle.
    private var series: [(day: String, words: Int)] {
        let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.words) })
        let calendar = Calendar.current
        return (0..<30).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.dayFormatter.string(from: date)
            return (day: key, words: byDay[key] ?? 0)
        }
    }

    var body: some View {
        let points = series
        let peak = max(points.map(\.words).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(points, id: \.day) { point in
                    Capsule()
                        .fill(point.words > 0
                              ? VeloraBrand.violet.color
                              : Color(.separatorColor).opacity(0.5))
                        .frame(height: max(3, 44 * CGFloat(point.words) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .help("\(point.day): \(point.words) words")
                }
            }
            .frame(height: 48, alignment: .bottom)
            HStack {
                Text("30 days ago").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Today").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, VeloraSpacing.xs)
    }
}

// MARK: - Breakdown list

private struct BreakdownList: View {
    let slices: [HistoryStore.BreakdownSlice]

    var body: some View {
        let peak = max(slices.map(\.words).max() ?? 0, 1)
        ForEach(slices, id: \.name) { slice in
            HStack(spacing: VeloraSpacing.s) {
                Text(slice.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 150, alignment: .leading)
                GeometryReader { geo in
                    Capsule()
                        .fill(VeloraBrand.violet.color.opacity(0.75))
                        .frame(width: max(3, geo.size.width * CGFloat(slice.words) / CGFloat(peak)))
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 8)
                Text("\(IntelligenceShareCard.compact(slice.words)) words")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.vertical, 1)
        }
    }
}
