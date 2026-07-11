import SwiftUI

/// One waveform-first capsule that truthfully reflects listening,
/// transcribing, success, and recovery states. It never displays provisional
/// transcript text; the target app receives only the authoritative final.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    @Environment(\.colorScheme) private var colorScheme

    @State private var width: CGFloat = HUDGeometry.minListeningWidth
    @State private var height: CGFloat = HUDGeometry.height
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.8
    @State private var yOffset: CGFloat = 12
    @State private var flashGreen = false
    @State private var showCheck = false

    var body: some View {
        capsule
            .frame(width: HUDPanel.panelSize.width, height: HUDPanel.panelSize.height)
            .onChange(of: model.state) { old, new in
                transition(from: old, to: new)
            }
    }

    // MARK: - Capsule

    private var capsule: some View {
        ZStack {
            background
            content
                .frame(width: width, height: height)
                .clipShape(Capsule())
            border
            listeningRing
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 6)
        .scaleEffect(scale)
        .offset(y: yOffset)
        .opacity(opacity)
    }

    @ViewBuilder private var background: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.18)
                    : Color.white.opacity(0.12))
        } else {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.30)
                    : Color.white.opacity(0.25))
        }
    }

    private var border: some View {
        Capsule().strokeBorder(
            colorScheme == .dark
                ? Color.white.opacity(0.15)
                : Color.black.opacity(0.08),
            lineWidth: 1)
    }

    /// A restrained four-second rotation while listening. The timeline pauses
    /// as soon as listening ends.
    private var listeningRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(time.truncatingRemainder(dividingBy: 4) / 4 * 360)
            Capsule().strokeBorder(
                AngularGradient(
                    gradient: Gradient(colors: [
                        VeloraBrand.indigo.color,
                        VeloraBrand.violet.color,
                        VeloraBrand.indigo.color,
                    ]),
                    center: .center,
                    angle: angle),
                lineWidth: 1.5)
        }
        .opacity(isListening ? 0.25 : 0)
        .animation(.easeOut(duration: 0.25), value: isListening)
    }

    private var content: some View {
        ZStack {
            recordingContent
                .opacity(recordingContentOpacity)
            checkmark
            errorContent
                .opacity(isError ? 1 : 0)
            learnedContent
                .opacity(isLearned ? 1 : 0)
            noticeContent
                .opacity(isNotice ? 1 : 0)
        }
    }

    // MARK: - Listening and transcribing

    private var recordingContent: some View {
        HStack(spacing: HUDGeometry.elementGap) {
            contextChip
            Spacer(minLength: VeloraSpacing.xs)

            HStack(spacing: VeloraSpacing.s) {
                recordingDot
                WaveformView(
                    levels: model.levels,
                    settle: model.state == .transcribing,
                    flashGreen: flashGreen,
                    active: isRecordingActive)
            }

            Spacer(minLength: VeloraSpacing.xs)
            timerText
                .opacity(isListening ? 1 : 0)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .animation(.easeOut(duration: 0.2), value: isListening)
    }

    private var recordingDot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2) / 2
            let dotOpacity = 0.55 + 0.45 * (0.5 + 0.5 * cos(phase * 2 * .pi))
            Circle()
                .fill(Color(nsColor: .systemRed))
                .opacity(isListening ? dotOpacity : 0)
        }
        .frame(width: HUDGeometry.dotDiameter, height: HUDGeometry.dotDiameter)
    }

    @ViewBuilder private var contextChip: some View {
        if let context = model.sessionContext {
            HStack(spacing: VeloraSpacing.xs) {
                if let icon = context.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(
                            width: HUDGeometry.chipIconSide,
                            height: HUDGeometry.chipIconSide)
                        .clipShape(RoundedRectangle(
                            cornerRadius: HUDGeometry.chipIconCornerRadius,
                            style: .continuous))
                }
                Text(context.modeName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var timerText: some View {
        if isListening {
            TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                timerLabel(at: timeline.date)
            }
            .frame(width: HUDGeometry.timerWidth, alignment: .trailing)
        } else {
            timerLabel(at: Date())
                .frame(width: HUDGeometry.timerWidth, alignment: .trailing)
        }
    }

    private func timerLabel(at date: Date) -> some View {
        Text(elapsedString(at: date))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func elapsedString(at date: Date) -> String {
        guard let start = model.recordingStart else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Success

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .symbolEffect(.bounce, value: showCheck)
            .opacity(showCheck ? 1 : 0)
            .scaleEffect(showCheck ? 1 : 0.5)
    }

    // MARK: - Error

    private var errorMessage: String {
        if case .error(let message) = model.state { return message }
        return ""
    }

    private var errorContent: some View {
        HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(errorMessage)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            Spacer(minLength: 0)
            Button(model.retryTitle) { model.onRetry?() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: HUDGeometry.errorWidth)
    }

    // MARK: - Learned correction

    private var learnedPair: (wrong: String, right: String) {
        if case .learned(let wrong, let right) = model.state { return (wrong, right) }
        return ("", "")
    }

    private var learnedContent: some View {
        let pair = learnedPair
        return HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VeloraBrand.violet.color)
                .symbolEffect(.bounce, value: isLearned)
            Text(pair.wrong)
                .font(.system(size: 12, weight: .medium))
                .strikethrough(true, color: Color(nsColor: .systemRed).opacity(0.85))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(pair.right)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .lineLimit(1)
            Text("· Learned")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: learnedWidth)
    }

    private var learnedWidth: CGFloat {
        let pair = learnedPair
        var value = HUDGeometry.contentInsetH * 2 + 14 + 12 + VeloraSpacing.s * 4
        value += HUDGeometry.textWidth(pair.wrong, font: HUDGeometry.bodyFont)
        value += HUDGeometry.textWidth(pair.right, font: HUDGeometry.bodyFont)
        value += HUDGeometry.textWidth("· Learned", font: HUDGeometry.bodyFont)
        return min(max(value, 190), 380)
    }

    // MARK: - Notice

    private var noticeParts: (symbol: String, message: String) {
        if case .notice(let symbol, let message) = model.state { return (symbol, message) }
        return ("", "")
    }

    private var noticeContent: some View {
        let parts = noticeParts
        return HStack(spacing: VeloraSpacing.s) {
            Image(systemName: parts.symbol.isEmpty ? "checkmark.circle.fill" : parts.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VeloraBrand.violet.color)
                .symbolEffect(.bounce, value: isNotice)
            Text(parts.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .lineLimit(1)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: noticeWidth)
    }

    private var noticeWidth: CGFloat {
        var value = HUDGeometry.contentInsetH * 2 + 14 + VeloraSpacing.s
        value += HUDGeometry.textWidth(noticeParts.message, font: HUDGeometry.bodyFont)
        return min(max(value, 160), HUDGeometry.maxListeningWidth)
    }

    // MARK: - State

    private var isListening: Bool { model.state == .listening }

    private var isRecordingActive: Bool {
        switch model.state {
        case .listening, .transcribing:
            return true
        case .inserted:
            return !showCheck
        default:
            return false
        }
    }

    private var isError: Bool {
        if case .error = model.state { return true }
        return false
    }

    private var isLearned: Bool {
        if case .learned = model.state { return true }
        return false
    }

    private var isNotice: Bool {
        if case .notice = model.state { return true }
        return false
    }

    private var recordingContentOpacity: Double {
        switch model.state {
        case .listening, .transcribing:
            return 1
        case .inserted:
            return showCheck ? 0 : 1
        default:
            return 0
        }
    }

    private var chipWidth: CGFloat {
        guard let context = model.sessionContext else { return 0 }
        var value = HUDGeometry.textWidth(context.modeName, font: HUDGeometry.chipFont)
        if context.appIcon != nil {
            value += HUDGeometry.chipIconSide + VeloraSpacing.xs
        }
        return value
    }

    private var desiredListeningWidth: CGFloat {
        min(
            max(
                HUDGeometry.controlRowWidth(chipWidth: chipWidth),
                HUDGeometry.minListeningWidth),
            HUDGeometry.maxListeningWidth)
    }

    // MARK: - Transitions

    private func transition(from old: HUDState, to new: HUDState) {
        switch new {
        case .listening:
            resetInstant(width: desiredListeningWidth, height: HUDGeometry.height)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .transcribing:
            // The waveform settles and shimmers; dot, timer, and ring fade.
            break

        case .inserted:
            flashGreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard case .inserted = model.state else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    width = HUDGeometry.insertedDiameter
                    height = HUDGeometry.height
                    showCheck = true
                }
            }

        case .error:
            if old.isHidden {
                resetInstant(width: HUDGeometry.errorWidth, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    width = HUDGeometry.errorWidth
                    height = HUDGeometry.height
                    showCheck = false
                }
            }

        case .learned:
            resetInstant(width: learnedWidth, height: HUDGeometry.height)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .notice:
            resetInstant(width: noticeWidth, height: HUDGeometry.height)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                opacity = 1
                scale = 1
                yOffset = 0
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

    private func resetInstant(width targetWidth: CGFloat, height targetHeight: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            width = targetWidth
            height = targetHeight
            opacity = 0
            scale = 0.8
            yOffset = 12
            showCheck = false
            flashGreen = false
        }
    }
}
