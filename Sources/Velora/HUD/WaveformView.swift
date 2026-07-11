import SwiftUI

/// Seven compact spectrum bars. The single Canvas avoids per-bar SwiftUI
/// updates, and its timeline is paused whenever the recording HUD is hidden.
struct WaveformView: View {
    let levels: WaveformLevelStore
    /// During finalization the bars settle to their quiet floor.
    let settle: Bool
    /// Hidden views stay mounted for state morphs; this stops invisible redraws.
    let active: Bool

    @Environment(\.colorScheme) private var colorScheme

    static let strip = HUDGeometry.waveformSize
    private static let barCount = 7
    private static let barWidth: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let heights = levels.displayHeights(settle: settle, time: time)
                guard !heights.isEmpty else { return }

                let gaps = CGFloat(Self.barCount - 1)
                let gap = max(0, (size.width - Self.barWidth * CGFloat(Self.barCount)) / gaps)
                let center = Self.barCount / 2
                let darkMode = colorScheme == .dark

                for index in 0..<Self.barCount {
                    // The existing store is center→edge (low→high frequency).
                    // Sample it symmetrically so this compact mark still reads
                    // as a waveform instead of a tiny one-sided equalizer.
                    let distance = abs(index - center)
                    let sourceIndex = min(
                        heights.count - 1,
                        distance * max(1, heights.count - 1) / center)
                    let barHeight = min(max(heights[sourceIndex], 3), size.height)
                    let x = CGFloat(index) * (Self.barWidth + gap)
                    let rect = CGRect(
                        x: x,
                        y: (size.height - barHeight) / 2,
                        width: Self.barWidth,
                        height: barHeight)

                    let color = settle
                        ? Color.primary.opacity(darkMode ? 0.30 : 0.24)
                        : VeloraBrand.barColor(
                            fraction: Double(index) / Double(Self.barCount - 1),
                            darkMode: darkMode).opacity(darkMode ? 0.92 : 0.78)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                        with: .color(color))
                }
            }
        }
        .frame(width: Self.strip.width, height: Self.strip.height)
    }
}
