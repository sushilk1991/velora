import SwiftUI

struct LiveWaveform: View {
    let level: Double
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isActive || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<11, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? VeloraTheme.warmAccent : VeloraTheme.violet.opacity(0.45))
                        .frame(width: 5, height: height(for: index, time: time))
                }
            }
            .frame(height: 52)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .accessibilityHidden(true)
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        guard isActive else {
            return CGFloat(12 + (index % 4) * 5)
        }
        let wave = (sin(time * 5.2 + Double(index) * 0.88) + 1) / 2
        let centerBias = 1 - abs(Double(index - 5)) / 8
        return CGFloat(12 + (42 * max(level, 0.15) * (0.45 + wave * 0.55) * centerBias))
    }
}
