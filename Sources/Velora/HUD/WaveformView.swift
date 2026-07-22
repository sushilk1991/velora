import SwiftUI

/// Original 24-bar waveform: 12 spectrum bands mirrored center-out in one
/// Canvas. The timeline pauses whenever no visible waveform animation exists.
struct WaveformView: View {
    let levels: WaveformLevelStore
    /// True in the transcribing state: bars settle to 4 pt + shimmer sweep.
    let settle: Bool
    /// Success flash: bars tint green for 150 ms before the circle morph.
    let flashGreen: Bool
    /// Hidden HUDs stay mounted for smooth morphs; pause invisible redraws.
    let active: Bool

    static let strip = HUDGeometry.waveformSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let heights = levels.displayHeights(settle: settle, time: time)

                var shimmerCenter: CGFloat = -1000
                if settle {
                    let phase = (time / 1.2).truncatingRemainder(dividingBy: 1.0)
                    let eased = phase < 0.5
                        ? 2 * phase * phase
                        : 1 - pow(-2 * phase + 2, 2) / 2
                    shimmerCenter = -30 + CGFloat(eased) * (size.width + 60)
                }

                let baseOpacity = 0.92

                for index in 0..<WaveformLevelStore.barCount {
                    let centerDistance = index < WaveformLevelStore.halfCount
                        ? WaveformLevelStore.halfCount - 1 - index
                        : index - WaveformLevelStore.halfCount
                    let x = CGFloat(index) * 5
                    let barHeight = min(max(heights[centerDistance], 2), size.height)
                    let rect = CGRect(
                        x: x,
                        y: (size.height - barHeight) / 2,
                        width: 3,
                        height: barHeight)

                    var opacity = baseOpacity
                    if settle {
                        let distance = (x + 1.5 - shimmerCenter) / 30
                        let boost = exp(-distance * distance * 2)
                        opacity = min(1, baseOpacity * 0.55 + boost * 0.6)
                    }

                    let color: Color = flashGreen
                        ? Color(nsColor: .systemGreen)
                        : VeloraBrand.barColor(
                            fraction: Double(index) / Double(WaveformLevelStore.barCount - 1),
                            darkMode: true)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(width: Self.strip.width, height: Self.strip.height)
    }
}
