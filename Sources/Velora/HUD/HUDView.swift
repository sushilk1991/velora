import SwiftUI

/// The HUD capsule (design brief §1.2, HUD 2.0) — one capsule that morphs
/// between listening / transcribing / inserted / error. All motion goes
/// through the five specified transitions plus the waveform and the gentle
/// live-transcript growth; nothing else animates.
///
/// Listening layout: a useful live phrase occupies its own top row; the
/// app/mode chip, recording dot, waveform, and timer stay in a stable control
/// row below it.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    @Environment(\.colorScheme) private var colorScheme

    // Animatable visual state, driven by `transition(from:to:)`.
    @State private var width: CGFloat = HUDGeometry.minListeningWidth
    @State private var height: CGFloat = HUDGeometry.height
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.8
    @State private var yOffset: CGFloat = 12
    @State private var flashGreen = false
    @State private var showCheck = false
    /// Widest pill so far this session — width only ever grows while
    /// listening so live-transcript updates never jitter the capsule smaller.
    @State private var sessionMaxWidth: CGFloat = HUDGeometry.minListeningWidth

    var body: some View {
        ZStack {
            capsule
        }
        .frame(width: HUDPanel.panelSize.width, height: HUDPanel.panelSize.height)
        .onChange(of: model.state) { old, new in
            transition(from: old, to: new)
        }
        .onChange(of: model.transcriptTail) { _, _ in
            updateListeningGeometry()
        }
        .onChange(of: model.sessionContext) { _, _ in
            updateListeningGeometry()
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

    /// Liquid Glass on macOS 26; material + tint fallback on 14–15.
    /// The tint overlay keeps waveform contrast on busy wallpapers.
    @ViewBuilder private var background: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.18) : Color.white.opacity(0.12))
        } else {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(
                colorScheme == .dark
                    ? Color.black.opacity(0.30) : Color.white.opacity(0.25))
        }
    }

    private var border: some View {
        Capsule().strokeBorder(
            colorScheme == .dark
                ? Color.white.opacity(0.15) : Color.black.opacity(0.08),
            lineWidth: 1)
    }

    /// While listening: a 1.5 pt indigo→violet gradient ring hugging the
    /// capsule border, 25 % opacity, one slow rotation every 4 s. Subtle —
    /// the gradient's angle rotates, the shape itself never moves.
    private var listeningRing: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(t.truncatingRemainder(dividingBy: 4) / 4 * 360)
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

    // MARK: - Listening / transcribing content

    private var recordingContent: some View {
        VStack(spacing: VeloraSpacing.xs) {
            if !model.transcriptTail.isEmpty {
                transcript
            }

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
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, model.transcriptTail.isEmpty ? HUDGeometry.contentInsetV : 10)
        .animation(.easeOut(duration: 0.2), value: isListening)
    }

    private var recordingDot: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isListening)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.0) / 2.0
            let opacity = 0.55 + 0.45 * (0.5 + 0.5 * cos(phase * 2 * .pi))
            Circle()
                .fill(Color(nsColor: .systemRed))
                .opacity(isListening ? opacity : 0)
        }
        .frame(width: HUDGeometry.dotDiameter, height: HUDGeometry.dotDiameter)
    }

    /// Frontmost-app icon (16 pt, 4 pt rounded) + detected mode name.
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
                            cornerRadius: HUDGeometry.chipIconCornerRadius))
                }
                Text(context.modeName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    // MARK: - Live transcript

    /// A dedicated two-line phrase row. Selection already happens on whole
    /// words/sentences in HUDModel, so no head truncation or fade is needed.
    private var transcript: some View {
        transcriptLabel
            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 34, alignment: .leading)
    }

    @ViewBuilder private var transcriptLabel: some View {
        if model.state == .transcribing {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (t / 1.2).truncatingRemainder(dividingBy: 1.0)
                let eased = phase < 0.5
                    ? 2 * phase * phase
                    : 1 - pow(-2 * phase + 2, 2) / 2
                transcriptText(shimmerCenter: eased)
            }
        } else {
            transcriptText(shimmerCenter: nil)
        }
    }

    private func transcriptText(shimmerCenter: Double?) -> some View {
        Text(model.transcriptTail)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(2)
            .lineSpacing(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .foregroundStyle(transcriptShading(shimmerCenter: shimmerCenter))
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.15), value: model.transcriptTail)
    }

    /// Solid primary while listening; a sweeping brightness band while
    /// transcribing ("keep the final partial visible with the shimmer over it").
    private func transcriptShading(shimmerCenter: Double?) -> AnyShapeStyle {
        let base: Color = colorScheme == .dark ? .white : .black
        guard let center = shimmerCenter else {
            return AnyShapeStyle(base.opacity(0.95))
        }
        let dim = base.opacity(0.55)
        return AnyShapeStyle(
            LinearGradient(
                stops: [
                    .init(color: dim, location: 0),
                    .init(color: dim, location: max(0, center - 0.2)),
                    .init(color: base, location: center),
                    .init(color: dim, location: min(1, center + 0.2)),
                    .init(color: dim, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing))
    }

    // MARK: - Timer

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

    // MARK: - Learned content (correction toast)

    private var learnedPair: (wrong: String, right: String) {
        if case .learned(let wrong, let right) = model.state { return (wrong, right) }
        return ("", "")
    }

    /// "✕wrong → right · Learned": the mishearing struck through in red, the
    /// user's fix in brand violet — the learning loop made visible.
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

    /// Measured toast width: icon + both words + arrow + caption + gaps,
    /// clamped so a pathological word can't stretch the pill across the screen.
    private var learnedWidth: CGFloat {
        let pair = learnedPair
        var w = HUDGeometry.contentInsetH * 2 + 14 + 12 + VeloraSpacing.s * 4
        w += HUDGeometry.textWidth(pair.wrong, font: HUDGeometry.transcriptFont)
        w += HUDGeometry.textWidth(pair.right, font: HUDGeometry.transcriptFont)
        w += HUDGeometry.textWidth("· Learned", font: HUDGeometry.transcriptFont)
        return min(max(w, 190), 380)
    }

    // MARK: - Notice content (general toast)

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
        var w = HUDGeometry.contentInsetH * 2 + 14 + VeloraSpacing.s
        w += HUDGeometry.textWidth(noticeParts.message, font: HUDGeometry.transcriptFont)
        return min(max(w, 160), 420)
    }

    // MARK: - State helpers

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
        case .listening, .transcribing: return 1
        case .inserted: return showCheck ? 0 : 1  // visible through the green flash
        default: return 0
        }
    }

    // MARK: - Listening geometry

    /// Width of the context chip (icon + 4 pt gap + measured mode text).
    private var chipWidth: CGFloat {
        guard let context = model.sessionContext else { return 0 }
        var w = HUDGeometry.textWidth(context.modeName, font: HUDGeometry.chipFont)
        if context.appIcon != nil {
            w += HUDGeometry.chipIconSide + VeloraSpacing.xs
        }
        return w
    }

    /// Width required by the stable controls row.
    private var fixedRowWidth: CGFloat {
        HUDGeometry.controlRowWidth(chipWidth: chipWidth)
    }

    /// The transcript owns a separate row, so its width no longer competes
    /// with the waveform. Short phrases can stay compact; useful prose gets at
    /// least 360 pt and may grow to 420 pt.
    private func desiredListeningWidth() -> CGFloat {
        guard !model.transcriptTail.isEmpty else {
            return min(
                max(fixedRowWidth, HUDGeometry.minListeningWidth),
                HUDGeometry.maxListeningWidth)
        }
        let textWidth = HUDGeometry.textWidth(
            model.transcriptTail, font: HUDGeometry.transcriptFont)
        let transcriptWidth = textWidth + HUDGeometry.contentInsetH * 2
        return min(
            max(fixedRowWidth, transcriptWidth, HUDGeometry.minTranscriptWidth),
            HUDGeometry.maxListeningWidth)
    }

    private var desiredListeningHeight: CGFloat {
        model.transcriptTail.isEmpty
            ? HUDGeometry.height
            : HUDGeometry.expandedListeningHeight
    }

    /// Grows the pill gently as partials stream in; it never shrinks within a
    /// session, avoiding jitter while phrases are replaced.
    private func updateListeningGeometry() {
        switch model.state {
        case .listening, .transcribing:
            break
        default:
            return
        }
        let target = max(desiredListeningWidth(), sessionMaxWidth)
        sessionMaxWidth = target
        let targetHeight = max(height, desiredListeningHeight)
        guard target != width || targetHeight != height else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            width = target
            height = targetHeight
        }
    }

    // MARK: - Transitions (design brief §1.2 animation table)

    private func transition(from old: HUDState, to new: HUDState) {
        switch new {
        case .listening:
            sessionMaxWidth = desiredListeningWidth()
            resetInstant(width: sessionMaxWidth, height: desiredListeningHeight)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                opacity = 1
                scale = 1
                yOffset = 0
            }

        case .transcribing:
            // Bars settle + shimmer are handled by WaveformView; dot/timer
            // fade via `isListening` animation. Width stays frozen.
            break

        case .inserted:
            // 150 ms green flash, then the width morph to a circle.
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
            // The toast appears from hidden well after the insert pill left;
            // same gentle entrance as an error, sized to its content.
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

    /// Snaps visual state to a fresh entrance pose without animating.
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
