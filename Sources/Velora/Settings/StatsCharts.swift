import AppKit
import Charts
import SwiftUI

// The Stats pane's cards and Swift Charts views. The data maths lives in
// IntelligenceSettingsView.swift (selftested); these views only draw it.

// MARK: - Snapshot rasterising

/// Set by the offscreen snapshot renderer. `NSView.cacheDisplay`, its
/// capture path, drops Swift Charts axes and gridlines, so with this set
/// every chart renders through `ImageRenderer` at its laid-out size and
/// the pane shows the bitmap instead.
enum StatsSnapshot {
    static var rasterizesCharts = false
}

/// A chart at a fixed height that rasterises itself under
/// `StatsSnapshot.rasterizesCharts` and draws live otherwise.
struct StatsChartBox<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    private static var scale: CGFloat { 2 }

    var body: some View {
        if StatsSnapshot.rasterizesCharts {
            GeometryReader { geometry in
                if let image = rasterized(width: geometry.size.width) {
                    Image(decorative: image, scale: Self.scale)
                }
            }
            .frame(height: height)
        } else {
            content.frame(height: height)
        }
    }

    /// The chart as a bitmap at `width` × `height`; nil before layout.
    @MainActor
    private func rasterized(width: CGFloat) -> CGImage? {
        guard width > 0 else {
            return nil
        }
        let renderer = ImageRenderer(content: content
            .frame(width: width, height: height)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = Self.scale
        return renderer.cgImage
    }
}

/// App icons as 32 px bitmaps, cached by bundle id. A live NSWorkspace
/// icon drawn inside `ImageRenderer` greys the whole frame; a plain bitmap
/// draws the same live and offscreen.
enum StatsAppIcons {
    private static let pixels = 32
    private static var cache: [String: CGImage?] = [:]

    static func image(for bundleID: String?) -> CGImage? {
        guard let bundleID, !bundleID.isEmpty else {
            return nil
        }
        if let cached = cache[bundleID] {
            return cached
        }
        let image = rasterize(bundleID)
        cache[bundleID] = image
        return image
    }

    private static func rasterize(_ bundleID: String) -> CGImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}

// MARK: - Cards and tiles

/// A chart in a grouped card, titled like every other card: the title and
/// an optional caption sit above it as the `GroupCard` header (Home's
/// "Last 7 days" chart does the same). Cards in a `fixedSize` row stretch
/// to the tallest one.
///
///     Words per day              Best day 30 Sep · 1,240 words
///     ┌───────────────────────────────────────────────────────┐
///     │ chart                                                 │
///     └───────────────────────────────────────────────────────┘
struct StatsChartCard<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    private static var inset: CGFloat { 14 }

    var body: some View {
        GroupCard(header: title, headerCaption: caption) {
            content
                .padding(.horizontal, Self.inset)
                .padding(.vertical, VeloraSpacing.m)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// What a tile draws under its caption. Both fill the same 30 pt, so a
/// row of tiles keeps one height and weight.
enum StatTileTrend {
    /// Sparkline of bucket values; fewer than 2 leaves the space blank.
    case series([Double])
    /// One dot per day, oldest first, filled when the day has a dictation.
    case days([Bool])
}

/// A hero metric: label, value, a context line and a trend, on the
/// GroupCard fill. The app's one metric tile (DESIGN.md §7).
///
///     ┌───────────────────────┐
///     │ Words                 │  12 pt secondary
///     │ 32,739                │  26 pt bold, tabular
///     │ ↑ 9% vs previous 30…  │  caption
///     │ ╱╲__╱╲_╱‾╲            │  30 pt sparkline, or ● ● ○ ● day dots
///     └───────────────────────┘
struct StatTile<Caption: View>: View {
    let label: String
    let value: String
    var emphasis: StatEmphasis = .plain
    var trend: StatTileTrend = .series([])
    @ViewBuilder var caption: Caption

    private var valueStyle: AnyShapeStyle {
        switch emphasis {
        case .plain: return AnyShapeStyle(.primary)
        case .accent: return AnyShapeStyle(VeloraBrand.accent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            caption
            // Zero ideal width: a tile's ideal width is its text, which is
            // what the Stats row measures to pick four across or 2 × 2.
            trendView
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                .padding(.top, VeloraSpacing.xs)
        }
        .padding(VeloraSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Same borderless fill as the GroupCards below the tiles.
        .background(
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                .fill(VeloraPanel.groupFill))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trendView: some View {
        switch trend {
        case .series(let values):
            StatsSparkline(series: values)
        case .days(let days):
            StatsDayStrip(days: days)
        }
    }
}

/// A quiet line in place of a chart with nothing to draw.
struct StatsEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Charts

/// Shared chart tokens: the accent, the empty-cell well, the gridline.
private enum StatsChartStyle {
    static let well = Color.primary.opacity(0.05)
    static let grid = VeloraPanel.hairline
    static let axisFont = Font.system(size: 10)
    /// Height of a tile's sparkline or day strip.
    static let trendHeight: CGFloat = 30
}

/// A tile's sparkline: an accent line over a fading area, no axes.
private struct StatsSparkline: View {
    let series: [Double]

    private static let height = StatsChartStyle.trendHeight
    private static let lineWidth: CGFloat = 1.5
    private static let areaOpacity = 0.25

    var body: some View {
        if series.count < 2 {
            Color.clear.frame(height: Self.height)
        } else {
            StatsChartBox(height: Self.height) {
                Chart(Array(series.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Bucket", index), y: .value("Value", value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(
                            colors: [VeloraBrand.accent.opacity(Self.areaOpacity), VeloraBrand.accent.opacity(0)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Bucket", index), y: .value("Value", value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: Self.lineWidth))
                        .foregroundStyle(VeloraBrand.accent)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...max(series.max() ?? 0, 1))
            }
        }
    }
}

/// A tile's day strip: accent dots for active days, a faint well for idle
/// ones, spread across the tile. More than `perRow` days wrap into a second
/// row so 30 days keep dots as large as a week's. Plain shapes, so it draws
/// the same live and in `--snapshot`.
///
///     ●   ●   ●   ●   ○   ○   ●              7 days, one row
///     ● ● ● ○ ● ● ● ○ ○ ● ● ● ● ○ ●          30 days, two rows of 15,
///     ● ● ● ○ ● ● ● ○ ● ● ● ● ○ ● ●          oldest top left, today last
private struct StatsDayStrip: View {
    let days: [Bool]

    private static let height = StatsChartStyle.trendHeight
    private static let perRow = 15
    private static let maxDot: CGFloat = 8
    private static let rowGap: CGFloat = 5
    /// Share of each day's slot the dot fills; the rest is the gap.
    private static let dotShare: CGFloat = 0.7
    private static let idleOpacity = 0.14

    var body: some View {
        let rows = stride(from: 0, to: days.count, by: Self.perRow).map {
            Array(days[$0..<min($0 + Self.perRow, days.count)])
        }
        let columns = min(days.count, Self.perRow)
        GeometryReader { geometry in
            let slot = geometry.size.width / CGFloat(max(columns, 1))
            let side = min(Self.maxDot, slot * Self.dotShare)
            VStack(spacing: Self.rowGap) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, active in
                            Circle()
                                .fill(active ? VeloraBrand.accent : Color.primary.opacity(Self.idleOpacity))
                                .frame(width: side, height: side)
                                .frame(width: slot)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

/// Words per bucket with a dashed average rule; trailing y axis.
///
///     ▂▃▅▂▇▃▁▅▆▂▃▅▂▇▃▁▅▆▂▃▅▂▇▃▁▅▆▂▃█   190 pt
///     - - - - - - - - - - - Average 1,040
///     Aug 10    Aug 17    Aug 25    Sep 1
struct StatsWordsChart: View {
    let bars: [StatsBar]
    let range: StatsRange

    private static let height: CGFloat = 190
    private static let radius: CGFloat = 3
    private static let yTicks = 4
    private static let hoursPerTick = 6
    private static let daysPerTick = 7
    private static let monthTicks = 6
    private static let dash: [CGFloat] = [3, 3]
    /// Room above the plot for the top y label, which centres on the top
    /// grid line and would otherwise clip ("1,000" losing its top half).
    private static let topInset: CGFloat = 8

    var body: some View {
        let average = StatsSeries.average(bars)
        StatsChartBox(height: Self.height) {
            Chart {
                ForEach(bars) { bar in
                    BarMark(x: .value("Date", bar.date, unit: unit), y: .value("Words", bar.words))
                        .foregroundStyle(VeloraBrand.accent)
                        .cornerRadius(Self.radius)
                }
                if average > 0 {
                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: Self.dash))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Average \(HistoryJournal.grouped(Int(average.rounded())))")
                                .font(StatsChartStyle.axisFont)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: xTicks) { _ in
                    AxisGridLine().foregroundStyle(StatsChartStyle.grid)
                    AxisValueLabel(format: xFormat)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: Self.yTicks)) { _ in
                    AxisGridLine().foregroundStyle(StatsChartStyle.grid)
                    AxisValueLabel()
                }
            }
            .padding(.top, Self.topInset)
        }
    }

    private var unit: Calendar.Component {
        switch range {
        case .today: return .hour
        case .sevenDays, .thirtyDays: return .day
        case .allTime: return .month
        }
    }

    private var xTicks: AxisMarkValues {
        switch range {
        case .today: return .stride(by: .hour, count: Self.hoursPerTick)
        case .sevenDays: return .stride(by: .day)
        case .thirtyDays: return .stride(by: .day, count: Self.daysPerTick)
        case .allTime: return .stride(by: .month, count: max(1, bars.count / Self.monthTicks))
        }
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .today: return .dateTime.hour()
        case .sevenDays: return .dateTime.weekday(.abbreviated)
        case .thirtyDays: return .dateTime.month(.abbreviated).day()
        case .allTime: return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }
}

/// Words per weekday × hour: rows in the locale's weekday order, darker
/// accent for busier hours (square-root scaled so one heavy hour doesn't
/// wash the rest out).
///
///          12 AM   6 AM   12 PM   6 PM
///     Mon  · · · · ▂ ▅ ▇ ▅ ▃ ▂ · ·
///     Tue  · · · · ▃ ▇ █ ▅ ▂ · · ·
struct StatsHourHeatmap: View {
    let cells: [HistoryStore.WeekdayHourSample]

    private struct Slot: Identifiable {
        let row: Int
        let hour: Int
        let words: Int
        var id: Int { row * StatsRangeDetail.hoursPerDay + hour }
    }

    private static let height: CGFloat = 170
    private static let hourTicks = [0, 6, 12, 18, 24]
    /// Gap between cells, in axis units.
    private static let inset = 0.06
    private static let floorOpacity = 0.18
    private static let radius: CGFloat = 2

    var body: some View {
        let calendar = Calendar.current
        let order = StatsWeekdays.order(calendar: calendar)
        let slots = Self.slots(cells, order: order)
        let peak = Double(max(slots.map(\.words).max() ?? 0, 1))
        StatsChartBox(height: Self.height) {
            Chart(slots) { slot in
                RectangleMark(
                    xStart: .value("Hour", Double(slot.hour) + Self.inset),
                    xEnd: .value("Hour", Double(slot.hour + 1) - Self.inset),
                    yStart: .value("Day", Double(slot.row) + Self.inset),
                    yEnd: .value("Day", Double(slot.row + 1) - Self.inset))
                    .foregroundStyle(fill(slot.words, peak: peak))
                    .cornerRadius(Self.radius)
            }
            .chartXScale(domain: 0.0...Double(StatsRangeDetail.hoursPerDay))
            .chartYScale(domain: [Double(StatsWeekdays.count), 0.0])
            .chartXAxis {
                AxisMarks(values: Self.hourTicks.map(Double.init)) { value in
                    AxisValueLabel(centered: false) {
                        Text(hourLabel(Int(value.as(Double.self) ?? 0), calendar: calendar))
                            .font(StatsChartStyle.axisFont)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: (0..<StatsWeekdays.count).map { Double($0) + 0.5 }) { value in
                    AxisValueLabel {
                        let row = Int(value.as(Double.self) ?? 0)
                        Text(StatsWeekdays.symbol(order[min(max(row, 0), order.count - 1)], calendar: calendar))
                            .font(StatsChartStyle.axisFont)
                    }
                }
            }
        }
    }

    /// Every weekday × hour, empty cells included, rows in display order.
    private static func slots(_ cells: [HistoryStore.WeekdayHourSample], order: [Int]) -> [Slot] {
        var words: [Int: Int] = [:]
        for cell in cells {
            words[cell.weekday * StatsRangeDetail.hoursPerDay + cell.hour, default: 0] += cell.words
        }
        return order.enumerated().flatMap { row, weekday in
            (0..<StatsRangeDetail.hoursPerDay).map { hour in
                Slot(row: row, hour: hour, words: words[weekday * StatsRangeDetail.hoursPerDay + hour] ?? 0)
            }
        }
    }

    private func fill(_ words: Int, peak: Double) -> Color {
        guard words > 0 else {
            return StatsChartStyle.well
        }
        return VeloraBrand.accent.opacity(Self.floorOpacity + (1 - Self.floorOpacity) * (Double(words) / peak).squareRoot())
    }

    /// "6 AM" or "06" per the locale's hour cycle. The hour is set on a
    /// fixed day (1 Jan 2001) that no time zone shifts clocks on, so a DST
    /// day can't turn 1 into "2 AM".
    private func hourLabel(_ hour: Int, calendar: Calendar) -> String {
        let reference = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let date = calendar.date(
            bySettingHour: hour % StatsRangeDetail.hoursPerDay, minute: 0, second: 0, of: reference) ?? reference
        return date.formatted(.dateTime.hour())
    }
}

/// Where: one fixed-height row per app with its icon and name, a bar
/// scaled to the top app, and the share on the same line. Plain rows, not a
/// Chart, so every row is the same height and the percentage never wraps
/// under the bar.
///
///     [■] Orca      ██████████████  61%
///     [■] Ghostty   ███             15%
///     [■] cmux      █                7%
struct StatsTopAppsChart: View {
    let shares: [StatsAppShare]
    /// App name → bundle id, for the icons.
    let bundles: [String: String]

    private static let rowHeight: CGFloat = 26
    private static let barHeight: CGFloat = 10
    private static let iconSide: CGFloat = 16
    private static let nameWidth: CGFloat = 72
    /// Fits "100%" at 11 pt.
    private static let percentWidth: CGFloat = 32
    private static let radius: CGFloat = 3

    var body: some View {
        let top = shares.map(\.words).max() ?? 0
        VStack(spacing: 0) {
            ForEach(shares, id: \.name) { share in
                row(share, fraction: top > 0 ? CGFloat(share.words) / CGFloat(top) : 0)
                    .frame(height: Self.rowHeight)
            }
        }
    }

    private func row(_ share: StatsAppShare, fraction: CGFloat) -> some View {
        HStack(spacing: VeloraSpacing.s) {
            appLabel(share.name)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(VeloraBrand.accent)
                    .frame(width: max(geometry.size.width * fraction, Self.radius * 2))
            }
            .frame(height: Self.barHeight)
            Text("\(share.percent)%")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Self.percentWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(share.name), \(share.percent)%")
    }

    private func appLabel(_ name: String) -> some View {
        HStack(spacing: VeloraSpacing.xs + 2) {
            if let icon = StatsAppIcons.image(for: bundles[name]) {
                Image(decorative: icon, scale: 2)
                    .resizable()
                    .frame(width: Self.iconSide, height: Self.iconSide)
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(StatsChartStyle.well)
                    .frame(width: Self.iconSide, height: Self.iconSide)
            }
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.nameWidth, alignment: .leading)
        }
    }
}

/// Ready in: 1 s bins, the 10 s+ overflow bin lighter, a solid median rule
/// and a dashed 95th-percentile rule.
///
///     █▇▃▂ · · · · · ▁      | median   ¦ 95%
///     0 s  2 s  4 s … 10 s+
struct StatsLatencyChart: View {
    let bins: [StatsLatency.Bin]
    let medianMs: Int
    let slowMs: Int

    private static let height: CGFloat = 130
    private static let gap = 0.06
    private static let overflowOpacity = 0.45
    private static let ticks = [0, 2, 4, 6, 8, 10]
    private static let dash: [CGFloat] = [3, 3]
    private static let radius: CGFloat = 2

    var body: some View {
        let cap = Double(StatsLatency.overflowSeconds)
        StatsChartBox(height: Self.height) {
            Chart {
                ForEach(bins) { bin in
                    RectangleMark(
                        xStart: .value("From", Double(bin.start) + Self.gap),
                        xEnd: .value("To", Double(bin.start + StatsLatency.binSeconds) - Self.gap),
                        yStart: .value("Zero", 0),
                        yEnd: .value("Dictations", bin.count))
                        .foregroundStyle(VeloraBrand.accent.opacity(bin.isOverflow ? Self.overflowOpacity : 1))
                        .cornerRadius(Self.radius)
                }
                RuleMark(x: .value("Median", min(Double(medianMs) / 1000, cap)))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                RuleMark(x: .value("95th percentile", min(Double(slowMs) / 1000, cap)))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: Self.dash))
            }
            .chartXScale(domain: 0.0...(cap + Double(StatsLatency.binSeconds)))
            .chartXAxis {
                AxisMarks(values: Self.ticks.map(Double.init)) { value in
                    AxisValueLabel {
                        let seconds = Int(value.as(Double.self) ?? 0)
                        Text(seconds >= StatsLatency.overflowSeconds ? "\(seconds) s+" : "\(seconds) s")
                            .font(StatsChartStyle.axisFont)
                    }
                }
            }
            .chartYAxis(.hidden)
        }
    }
}

/// One stacked bar of mode shares in accent shades, then a legend row per
/// mode.
///
///     ████████████▓▓▓▓▒▒░
///     ● Default        60%
///     ● Terminal       20%
struct StatsModesChart: View {
    let shares: [StatsAppShare]

    /// Accent opacity per slot, strongest first; `Other` takes the last.
    private static let shades = [1.0, 0.6, 0.32, 0.18]
    private static let barHeight: CGFloat = 14
    private static let dot: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            StatsChartBox(height: Self.barHeight) {
                Chart(shares, id: \.name) { share in
                    BarMark(x: .value("Words", share.words), y: .value("All", "all"))
                        .foregroundStyle(by: .value("Mode", share.name))
                }
                .chartForegroundStyleScale(
                    domain: shares.map(\.name),
                    range: shares.indices.map { VeloraBrand.accent.opacity(shade($0)) })
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .clipShape(Capsule())
            }
            ForEach(Array(shares.enumerated()), id: \.element.name) { index, share in
                HStack(spacing: VeloraSpacing.s) {
                    Circle()
                        .fill(VeloraBrand.accent.opacity(shade(index)))
                        .frame(width: Self.dot, height: Self.dot)
                    Text(share.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: VeloraSpacing.s)
                    Text("\(share.percent)%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func shade(_ index: Int) -> Double {
        Self.shades[min(index, Self.shades.count - 1)]
    }
}

/// The last 12 weeks as weekday rows and week columns, darker for busier
/// days.
struct StatsActivityCalendar: View {
    let cells: [StatsCalendarCell]

    private static let height: CGFloat = 96
    private static let gap = 0.08
    private static let floorOpacity = 0.2
    private static let radius: CGFloat = 2

    var body: some View {
        let peak = Double(max(cells.map(\.words).max() ?? 0, 1))
        let columns = (cells.map(\.column).max() ?? 0) + 1
        StatsChartBox(height: Self.height) {
            Chart(cells) { cell in
                RectangleMark(
                    xStart: .value("Week", Double(cell.column) + Self.gap),
                    xEnd: .value("Week", Double(cell.column + 1) - Self.gap),
                    yStart: .value("Day", Double(cell.row) + Self.gap),
                    yEnd: .value("Day", Double(cell.row + 1) - Self.gap))
                    .foregroundStyle(fill(cell.words, peak: peak))
                    .cornerRadius(Self.radius)
            }
            .chartXScale(domain: 0.0...Double(columns))
            .chartYScale(domain: [Double(StatsWeekdays.count), 0.0])
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }

    private func fill(_ words: Int, peak: Double) -> Color {
        guard words > 0 else {
            return StatsChartStyle.well
        }
        return VeloraBrand.accent.opacity(Self.floorOpacity + (1 - Self.floorOpacity) * Double(words) / peak)
    }
}
