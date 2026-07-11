import SwiftUI

/// A quiet, transcript-first dictation card. The recording shell is fixed so
/// Whisper revisions never move the user's focal point; only deliberate state
/// changes (recording, copied, error, toast, hidden) alter its geometry.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    @Environment(\.colorScheme) private var colorScheme

    @State private var width: CGFloat = HUDGeometry.recordingWidth
    @State private var height: CGFloat = HUDGeometry.recordingHeight
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.94
    @State private var yOffset: CGFloat = 8
    @State private var showSuccess = false

    var body: some View {
        card
            .frame(width: HUDPanel.panelSize.width, height: HUDPanel.panelSize.height)
            .onChange(of: model.state) { old, new in
                transition(from: old, to: new)
            }
    }

    // MARK: - Card shell

    private var card: some View {
        ZStack {
            background
            content
                .frame(width: width, height: height)
                .clipShape(cardShape)
            border
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.30 : 0.18),
            radius: 16,
            x: 0,
            y: 7)
        .scaleEffect(scale)
        .offset(y: yOffset)
        .opacity(opacity)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: min(HUDGeometry.cornerRadius, height / 2),
            style: .circular)
    }

    /// Liquid Glass on macOS 26; a restrained native material on macOS 14–15.
    @ViewBuilder private var background: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: cardShape)
            cardShape.fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.16)
                    : Color.white.opacity(0.10))
        } else {
            cardShape.fill(.ultraThinMaterial)
            cardShape.fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.28)
                    : Color.white.opacity(0.24))
        }
    }

    private var border: some View {
        cardShape.strokeBorder(
            colorScheme == .dark
                ? Color.white.opacity(0.14)
                : Color.black.opacity(0.09),
            lineWidth: 1)
    }

    private var content: some View {
        ZStack {
            recordingContent
                .opacity(recordingContentOpacity)
            successContent
                .opacity(showSuccess ? 1 : 0)
            errorContent
                .opacity(isError ? 1 : 0)
            learnedContent
                .opacity(isLearned ? 1 : 0)
            noticeContent
                .opacity(isNotice ? 1 : 0)
        }
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: HUDGeometry.elementGap) {
            WaveformView(
                levels: model.levels,
                settle: model.state == .transcribing,
                active: isRecordingActive)

            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                transcriptLabel
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .leading)
                recordingFooter
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
            }
        }
        .padding(.horizontal, VeloraSpacing.m)
        .frame(width: HUDGeometry.recordingWidth, height: HUDGeometry.recordingHeight)
    }

    @ViewBuilder private var transcriptLabel: some View {
        if model.transcriptTail.isEmpty {
            Text("Listening…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(primaryTextColor.opacity(0.62))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            transcriptText
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One Text tree keeps wrapping stable while settled and provisional words
    /// use different emphasis. There is intentionally no transcript animation.
    private var transcriptText: Text {
        let stable = model.transcriptStablePrefix
        let provisional = model.transcriptProvisionalSuffix
        let separator = stable.isEmpty || provisional.isEmpty ? "" : " "
        return Text(stable)
            .foregroundColor(primaryTextColor.opacity(0.95))
            + Text(separator + provisional)
            .foregroundColor(primaryTextColor.opacity(0.68))
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var recordingFooter: some View {
        HStack(spacing: VeloraSpacing.xs) {
            contextLabel
            Spacer(minLength: VeloraSpacing.s)
            trailingStatus
        }
    }

    private var contextLabel: some View {
        HStack(spacing: VeloraSpacing.xs) {
            if let icon = model.sessionContext?.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(
                        width: HUDGeometry.chipIconSide,
                        height: HUDGeometry.chipIconSide)
                    .clipShape(RoundedRectangle(
                        cornerRadius: HUDGeometry.chipIconCornerRadius,
                        style: .continuous))
            } else {
                Image(systemName: "text.cursor")
                    .font(.system(size: 9.5, weight: .medium))
                    .frame(
                        width: HUDGeometry.chipIconSide,
                        height: HUDGeometry.chipIconSide)
            }

            Text(model.sessionContext?.modeName ?? "Text")
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var trailingStatus: some View {
        if model.state == .transcribing {
            Text("Polishing")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(VeloraBrand.violet.color.opacity(0.88))
        } else if isListening {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                timerLabel(at: timeline.date)
            }
        } else {
            timerLabel(at: Date())
        }
    }

    private func timerLabel(at date: Date) -> some View {
        Text(elapsedString(at: date))
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: HUDGeometry.timerWidth, alignment: .trailing)
    }

    private func elapsedString(at date: Date) -> String {
        guard let start = model.recordingStart else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Success

    private var successContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("Copied")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(primaryTextColor.opacity(0.94))
        }
        .frame(width: HUDGeometry.successWidth, height: HUDGeometry.successHeight)
    }

    // MARK: - Error

    private var errorMessage: String {
        if case .error(let message) = model.state { return message }
        return ""
    }

    private var errorContent: some View {
        HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(errorMessage)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(primaryTextColor.opacity(0.94))
            Spacer(minLength: 0)
            Button(model.retryTitle) { model.onRetry?() }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .frame(width: HUDGeometry.errorWidth, height: HUDGeometry.successHeight)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VeloraBrand.violet.color)
            Text(pair.wrong)
                .font(.system(size: 11.5, weight: .medium))
                .strikethrough(true, color: Color(nsColor: .systemRed).opacity(0.80))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(pair.right)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(primaryTextColor.opacity(0.94))
                .lineLimit(1)
            Text("· Learned")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .frame(width: learnedWidth, height: HUDGeometry.successHeight)
    }

    private var learnedWidth: CGFloat {
        let pair = learnedPair
        var value = HUDGeometry.contentInsetH * 2 + 14 + 12 + VeloraSpacing.s * 4
        value += HUDGeometry.textWidth(pair.wrong, font: HUDGeometry.transcriptFont)
        value += HUDGeometry.textWidth(pair.right, font: HUDGeometry.transcriptFont)
        value += HUDGeometry.textWidth("· Learned", font: HUDGeometry.chipFont)
        return min(max(value, 190), HUDGeometry.recordingWidth)
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
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(VeloraBrand.violet.color)
            Text(parts.message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(primaryTextColor.opacity(0.94))
                .lineLimit(1)
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .frame(width: noticeWidth, height: HUDGeometry.successHeight)
    }

    private var noticeWidth: CGFloat {
        var value = HUDGeometry.contentInsetH * 2 + 14 + VeloraSpacing.s
        value += HUDGeometry.textWidth(noticeParts.message, font: HUDGeometry.transcriptFont)
        return min(max(value, 160), HUDGeometry.recordingWidth)
    }

    // MARK: - State

    private var isListening: Bool { model.state == .listening }

    private var isRecordingActive: Bool {
        switch model.state {
        case .listening, .transcribing: return true
        default: return false
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
        isRecordingActive && !showSuccess ? 1 : 0
    }

    // MARK: - Deliberate state transitions

    private func transition(from old: HUDState, to new: HUDState) {
        switch new {
        case .listening:
            resetInstant(
                width: HUDGeometry.recordingWidth,
                height: HUDGeometry.recordingHeight)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .transcribing:
            // The fixed card stays put. Only the footer label and bars settle.
            break

        case .inserted:
            withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                width = HUDGeometry.successWidth
                height = HUDGeometry.successHeight
                showSuccess = true
            }

        case .error:
            if old.isHidden {
                resetInstant(width: HUDGeometry.errorWidth, height: HUDGeometry.successHeight)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            } else {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                    width = HUDGeometry.errorWidth
                    height = HUDGeometry.successHeight
                    showSuccess = false
                }
            }

        case .learned:
            resetInstant(width: learnedWidth, height: HUDGeometry.successHeight)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .notice:
            resetInstant(width: noticeWidth, height: HUDGeometry.successHeight)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .hidden(let style):
            switch style {
            case .success:
                withAnimation(.easeOut(duration: 0.25)) {
                    opacity = 0
                    scale = 0.90
                }
            case .cancel:
                withAnimation(.easeOut(duration: 0.18)) {
                    opacity = 0
                    scale = 0.92
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
            scale = 0.94
            yOffset = 8
            showSuccess = false
        }
    }
}
