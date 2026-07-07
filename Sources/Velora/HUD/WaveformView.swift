import SwiftUI

/// 24-bar live waveform (design brief §2, HUD 2.0 visual language).
///
/// Bars are mirrored center-out around the vertical midline (Siri-like):
/// the newest level renders at the two center bars and flows outward. One
/// `Canvas` inside `TimelineView(.animation)` — redrawn every frame, zero
/// per-bar SwiftUI views. Bars: 3 pt wide, 2 pt gap (5 pt pitch), corner
/// radius 1.5 pt, heights 4…32 pt inside a fixed 120×32 pt strip, tinted
/// with a subtle brand indigo→violet gradient (`VeloraBrand.barColor`).
struct WaveformView: View {
    let levels: WaveformLevelStore
    /// True in the transcribing state: bars settle to 4 pt + shimmer sweep.
    let settle: Bool
    /// Success flash: bars tint green for 150 ms before the circle morph.
    let flashGreen: Bool

    @Environment(\.colorScheme) private var colorScheme

    static let strip = HUDGeometry.waveformSize

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let heights = levels.displayHeights(settle: settle, time: t)

                // Shimmer: a 60 pt-wide highlight sweeping the strip every
                // 1.2 s (easeInOut), rendered as a per-bar brightness boost.
                var shimmerCenter: CGFloat = -1000
                if settle {
                    let phase = (t / 1.2).truncatingRemainder(dividingBy: 1.0)
                    let eased = phase < 0.5
                        ? 2 * phase * phase
                        : 1 - pow(-2 * phase + 2, 2) / 2
                    shimmerCenter = -30 + CGFloat(eased) * (size.width + 60)
                }

                let dark = colorScheme == .dark
                let baseOpacity = dark ? 0.9 : 0.75
                let barCount = WaveformLevelStore.barCount

                for i in 0..<barCount {
                    // Mirror around the midline: bars 11 and 12 are the two
                    // center (newest) bars; the edges carry the oldest levels.
                    let centerDistance = i < WaveformLevelStore.halfCount
                        ? (WaveformLevelStore.halfCount - 1 - i)
                        : (i - WaveformLevelStore.halfCount)
                    let x = CGFloat(i) * 5
                    let h = min(max(heights[centerDistance], 2), size.height)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: 3, height: h)

                    var opacity = baseOpacity
                    if settle {
                        let barCenter = x + 1.5
                        let d = (barCenter - shimmerCenter) / 30  // 60 pt window
                        let boost = exp(-d * d * 2)
                        opacity = min(1.0, baseOpacity * 0.55 + boost * 0.6)
                    }

                    let color: Color = flashGreen
                        ? Color(nsColor: .systemGreen)
                        : VeloraBrand.barColor(
                            fraction: Double(i) / Double(barCount - 1), darkMode: dark)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(color.opacity(opacity)))
                }
            }
        }
        .frame(width: Self.strip.width, height: Self.strip.height)
    }
}
