import SwiftUI

/// The HUD capsule (design brief §1.2) — one capsule that morphs between
/// listening / transcribing / inserted / error. All motion goes through the
/// five specified transitions plus the waveform; nothing else animates.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    @Environment(\.colorScheme) private var colorScheme

    // Animatable visual state, driven by `transition(from:to:)`.
    @State private var width: CGFloat = 180
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.8
    @State private var yOffset: CGFloat = 12
    @State private var flashGreen = false
    @State private var showCheck = false
    @State private var dotDimmed = false

    private let height: CGFloat = 44

    var body: some View {
        ZStack {
            capsule
        }
        .frame(width: HUDPanel.panelSize.width, height: HUDPanel.panelSize.height)
        .onChange(of: model.state) { old, new in
            transition(from: old, to: new)
        }
    }

    // MARK: - Capsule

    private var capsule: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            // Tint overlay keeps waveform contrast on busy wallpapers.
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.30) : Color.white.opacity(0.25))
            content
                .frame(width: width, height: height)
                .clipShape(Capsule())
            Capsule().strokeBorder(
                colorScheme == .dark
                    ? Color.white.opacity(0.15) : Color.black.opacity(0.08),
                lineWidth: 1)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 6)
        .scaleEffect(scale)
        .offset(y: yOffset)
        .opacity(opacity)
    }

    private var content: some View {
        ZStack {
            recordingContent
                .opacity(recordingContentOpacity)
            checkmark
            errorContent
                .opacity(isError ? 1 : 0)
        }
    }

    // MARK: - Listening / transcribing content

    private var recordingContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 8, height: 8)
                .opacity(dotDimmed ? 0.55 : 1.0)
                .opacity(isListening ? 1 : 0)

            WaveformView(
                levels: model.levels,
                settle: model.state == .transcribing,
                flashGreen: flashGreen)

            timerText
                .opacity(isListening ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .animation(.easeOut(duration: 0.2), value: isListening)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                dotDimmed = true
            }
        }
    }

    private var timerText: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            Text(elapsedString(at: timeline.date))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 32, alignment: .trailing)
    }

    private func elapsedString(at date: Date) -> String {
        guard let start = model.recordingStart else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Inserted content

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .symbolEffect(.bounce, value: showCheck)
            .opacity(showCheck ? 1 : 0)
            .scaleEffect(showCheck ? 1 : 0.5)
    }

    // MARK: - Error content

    private var errorMessage: String {
        if case .error(let message) = model.state { return message }
        return ""
    }

    private var errorContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(errorMessage)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            Spacer(minLength: 0)
            Button("Retry") { model.onRetry?() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .frame(width: 260)
    }

    // MARK: - State helpers

    private var isListening: Bool { model.state == .listening }
    private var isError: Bool {
        if case .error = model.state { return true }
        return false
    }

    private var recordingContentOpacity: Double {
        switch model.state {
        case .listening, .transcribing: return 1
        case .inserted: return showCheck ? 0 : 1  // visible through the green flash
        default: return 0
        }
    }

    // MARK: - Transitions (design brief §1.2 animation table)

    private func transition(from old: HUDState, to new: HUDState) {
        switch new {
        case .listening:
            resetInstant(width: 180)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .transcribing:
            // Bars settle + shimmer are handled by WaveformView; dot/timer
            // fade via `isListening` animation.
            break

        case .inserted:
            // 150 ms green flash, then the width morph to a 44 pt circle.
            flashGreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard case .inserted = model.state else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    width = 44
                    showCheck = true
                }
            }

        case .error:
            if old.isHidden {
                resetInstant(width: 260)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    width = 260
                    showCheck = false
                }
            }

        case .hidden(let style):
            switch style {
            case .success:
                withAnimation(.easeOut(duration: 0.25)) {
                    opacity = 0
                    scale = 0.85
                }
            case .cancel:
                withAnimation(.easeOut(duration: 0.18)) {
                    opacity = 0
                    scale = 0.9
                    yOffset = 8
                }
            }
        }
    }

    /// Snaps visual state to a fresh entrance pose without animating.
    private func resetInstant(width targetWidth: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            width = targetWidth
            opacity = 0
            scale = 0.8
            yOffset = 12
            showCheck = false
            flashGreen = false
        }
    }
}
