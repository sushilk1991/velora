import SwiftUI

/// One waveform-first capsule that truthfully reflects listening,
/// transcribing, success, and recovery states. It never displays provisional
/// transcript text; the target app receives only the authoritative final.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    @Environment(\.colorScheme) private var colorScheme

    @State private var width: CGFloat
    @State private var height: CGFloat
    @State private var opacity: Double
    @State private var scale: CGFloat
    @State private var yOffset: CGFloat
    @State private var flashGreen = false
    @State private var showCheck = false
    @State private var hovering = false

    /// Seeds the animation state from the model's current state, so a view
    /// created mid-state (relaunch into standby, `--snapshot` rendering)
    /// starts visually correct instead of assuming "hidden".
    init(model: HUDModel) {
        self.model = model
        let metrics = Self.capsuleMetrics(for: model.state, context: model.sessionContext)
        _width = State(initialValue: metrics.size.width)
        _height = State(initialValue: metrics.size.height)
        _opacity = State(initialValue: metrics.visible ? 1 : 0)
        _scale = State(initialValue: metrics.visible ? 1 : 0.8)
        _yOffset = State(initialValue: metrics.visible ? 0 : 12)
    }

    /// The capsule's visual footprint per state. Shared with HUDPanel's hit
    /// testing so the interactive region always matches what's on screen —
    /// an oversized hit rect would swallow the frontmost app's clicks.
    static func capsuleMetrics(
        for state: HUDState, context: HUDSessionContext?
    ) -> (size: CGSize, visible: Bool) {
        switch state {
        case .hidden:
            return (CGSize(width: HUDGeometry.minListeningWidth, height: HUDGeometry.height), false)
        case .standby:
            return (HUDGeometry.standbySize, true)
        case .listening, .transcribing:
            let width = min(
                max(
                    HUDGeometry.controlRowWidth(chipWidth: Self.chipWidth(for: context)),
                    HUDGeometry.minListeningWidth),
                HUDGeometry.maxListeningWidth)
            return (CGSize(width: width, height: HUDGeometry.height), true)
        case .meeting:
            return (CGSize(width: HUDGeometry.meetingWidth, height: HUDGeometry.height), true)
        case .inserted:
            return (CGSize(width: HUDGeometry.insertedDiameter, height: HUDGeometry.height), true)
        case .error:
            return (CGSize(width: HUDGeometry.errorWidth, height: HUDGeometry.height), true)
        case .learned(let wrong, let right):
            var value = HUDGeometry.contentInsetH * 2 + 14 + 12 + VeloraSpacing.s * 4
            value += HUDGeometry.textWidth(wrong, font: HUDGeometry.bodyFont)
            value += HUDGeometry.textWidth(right, font: HUDGeometry.bodyFont)
            value += HUDGeometry.textWidth("· Learned", font: HUDGeometry.bodyFont)
            return (CGSize(width: min(max(value, 190), 380), height: HUDGeometry.height), true)
        case .notice(_, let message):
            var value = HUDGeometry.contentInsetH * 2 + 14 + VeloraSpacing.s
            value += HUDGeometry.textWidth(message, font: HUDGeometry.bodyFont)
            return (
                CGSize(
                    width: min(max(value, 160), HUDGeometry.maxListeningWidth),
                    height: HUDGeometry.height),
                true)
        }
    }

    private static func chipWidth(for context: HUDSessionContext?) -> CGFloat {
        guard let context else { return 0 }
        var value = HUDGeometry.textWidth(context.modeName, font: HUDGeometry.chipFont)
        if context.appIcon != nil {
            value += HUDGeometry.chipIconSide + VeloraSpacing.xs
        }
        return value
    }

    var body: some View {
        capsule
            .padding(.horizontal, HUDGeometry.panelEdgePadding)
            .frame(
                width: HUDPanel.panelSize.width,
                height: HUDPanel.panelSize.height,
                alignment: panelAlignment)
            .onChange(of: model.state) { old, new in
                transition(from: old, to: new)
            }
    }

    /// Corner presets anchor the capsule to the panel edge so width changes
    /// grow inward from the screen edge instead of expanding symmetrically.
    private var panelAlignment: Alignment {
        switch model.edge {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: isMeeting ? .contain : .ignore)
        .accessibilityLabel(isMeeting ? "Velora meeting recording" : "Velora dictation")
        .accessibilityHint(isMeeting
            ? "Use the stop button to finish the meeting recording"
            : (isStandby ? "Click to start dictation" : "Click to stop dictation"))
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
        // Hover highlight: a whisper of extra light (never a size change).
        Capsule().fill(
            colorScheme == .dark
                ? Color.white.opacity(hovering ? 0.08 : 0)
                : Color.black.opacity(hovering ? 0.05 : 0))
    }

    private var border: some View {
        Capsule().strokeBorder(
            colorScheme == .dark
                ? Color.white.opacity(hovering ? 0.30 : 0.15)
                : Color.black.opacity(hovering ? 0.18 : 0.08),
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
            standbyContent
                .opacity(isStandby ? 1 : 0)
            recordingContent
                .opacity(recordingContentOpacity)
            meetingContent
                .opacity(isMeeting ? 1 : 0)
            checkmark
            errorContent
                .opacity(isError ? 1 : 0)
            learnedContent
                .opacity(isLearned ? 1 : 0)
            noticeContent
                .opacity(isNotice ? 1 : 0)
        }
    }

    // MARK: - Standby pill

    /// The persistent idle pill: the brand waveform glyph, warming up on hover
    /// to say "click me".
    private var standbyContent: some View {
        Image(systemName: "waveform")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                hovering && isStandby
                    ? AnyShapeStyle(VeloraBrand.iconGradient)
                    : AnyShapeStyle(.secondary))
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

    // MARK: - Meeting recording

    private var meetingValue: (title: String, systemAudio: Bool)? {
        if case .meeting(let title, let systemAudio) = model.state {
            return (title, systemAudio)
        }
        return nil
    }

    private var meetingContent: some View {
        HStack(spacing: VeloraSpacing.s) {
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: HUDGeometry.dotDiameter, height: HUDGeometry.dotDiameter)
            VStack(alignment: .leading, spacing: 1) {
                Text(meetingValue?.title ?? "Meeting")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if meetingValue?.systemAudio == false {
                    Text("Mic only")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            .frame(width: 112, alignment: .leading)
            Spacer(minLength: 0)
            timerText
            Button { model.onMeetingStop?() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Stop meeting recording")
            .accessibilityLabel("Stop meeting recording")
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: HUDGeometry.meetingWidth)
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
        if isListening || isMeeting {
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
        Self.capsuleMetrics(for: model.state, context: nil).size.width
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
        Self.capsuleMetrics(for: model.state, context: nil).size.width
    }

    // MARK: - State

    private var isListening: Bool { model.state == .listening }

    private var isStandby: Bool { model.state == .standby }

    private var isMeeting: Bool {
        if case .meeting = model.state { return true }
        return false
    }

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

    private var desiredListeningWidth: CGFloat {
        Self.capsuleMetrics(for: .listening, context: model.sessionContext).size.width
    }

    // MARK: - Transitions

    private func transition(from old: HUDState, to new: HUDState) {
        switch new {
        case .standby:
            if old.isHidden {
                resetInstant(
                    width: HUDGeometry.standbySize.width,
                    height: HUDGeometry.standbySize.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            } else {
                // Session just ended — the capsule shrinks back into the pill.
                flashGreen = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    width = HUDGeometry.standbySize.width
                    height = HUDGeometry.standbySize.height
                    showCheck = false
                }
            }

        case .listening:
            if old == .standby {
                // The pill blooms into the listening capsule in place.
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    width = desiredListeningWidth
                    height = HUDGeometry.height
                }
            } else {
                resetInstant(width: desiredListeningWidth, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            }

        case .transcribing:
            // The waveform settles and shimmers; dot, timer, and ring fade.
            break

        case .meeting:
            let target = HUDGeometry.meetingWidth
            if old.isHidden {
                resetInstant(width: target, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    width = target
                    height = HUDGeometry.height
                    showCheck = false
                }
            }

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
            if old == .standby {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    width = learnedWidth
                    height = HUDGeometry.height
                }
            } else {
                resetInstant(width: learnedWidth, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            }

        case .notice:
            if old == .standby {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    width = noticeWidth
                    height = HUDGeometry.height
                }
            } else {
                resetInstant(width: noticeWidth, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
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
