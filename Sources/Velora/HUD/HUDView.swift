import SwiftUI

/// One waveform-first capsule that truthfully reflects listening,
/// transcribing, success, and recovery states. Ordinary dictation stays
/// waveform-only; opaque Stream targets use the capsule for a non-mutating
/// live preview before one authoritative final insertion.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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
            if context?.livePreview == true {
                return (
                    CGSize(
                        width: HUDGeometry.maxListeningWidth,
                        height: HUDGeometry.height),
                    true)
            }
            let width = min(
                max(
                    HUDGeometry.controlRowWidth(chipWidth: Self.chipWidth(for: context)),
                    HUDGeometry.minListeningWidth),
                HUDGeometry.maxListeningWidth)
            return (CGSize(width: width, height: HUDGeometry.height), true)
        case .meetingSuggestion, .meetingEnd:
            return (
                CGSize(width: HUDGeometry.meetingPromptWidth, height: HUDGeometry.height),
                true)
        case .meeting:
            return (CGSize(width: HUDGeometry.meetingWidth, height: HUDGeometry.height), true)
        case .inserted:
            return (CGSize(width: HUDGeometry.insertedDiameter, height: HUDGeometry.height), true)
        case .error, .meetingFailure:
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
        .accessibilityElement(children: isMeetingSurface ? .contain : .ignore)
        .accessibilityLabel(meetingAccessibilityLabel)
        .accessibilityHint(meetingAccessibilityHint)
    }

    @ViewBuilder private var background: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
        // A HUD is a control surface, not ambient content. Keep one stable,
        // dark contrast contract regardless of the app underneath it.
        Capsule().fill(Color.black.opacity(reduceTransparency ? 0.96 : 0.72))
        Capsule().fill(VeloraBrand.indigo.color.opacity(0.16))
        Capsule().fill(Color.white.opacity(hovering ? 0.07 : 0))
    }

    private var border: some View {
        Capsule().strokeBorder(
            Color.white.opacity(hovering ? 0.34 : 0.20),
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
            meetingSuggestionContent
                .opacity(isMeetingSuggestion ? 1 : 0)
            meetingContent
                .opacity(isMeetingRecording ? 1 : 0)
            meetingEndContent
                .opacity(isMeetingEnd ? 1 : 0)
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
                    : AnyShapeStyle(hudSecondaryText))
    }

    // MARK: - Listening and transcribing

    @ViewBuilder private var recordingContent: some View {
        if model.sessionContext?.livePreview == true {
            livePreviewContent
        } else {
            recordingControls
        }
    }

    private var livePreviewContent: some View {
        HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VeloraBrand.iconGradient)
                .frame(width: 18)
            Text(model.liveTranscript.isEmpty ? "Listening…" : model.liveTranscript)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    model.liveTranscript.isEmpty
                        ? hudSecondaryText : hudPrimaryText)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            timerText
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .frame(
            width: HUDGeometry.maxListeningWidth,
            height: HUDGeometry.height)
    }

    private var recordingControls: some View {
        ZStack(alignment: .topLeading) {
            contextChip
                .frame(
                    width: contextChipWidth,
                    height: HUDGeometry.waveformSize.height,
                    alignment: .leading)
                .position(
                    x: HUDGeometry.contentInsetH + contextChipWidth / 2,
                    y: HUDGeometry.waveformSize.height / 2)
            HStack(spacing: VeloraSpacing.s) {
                recordingDot
                WaveformView(
                    levels: model.levels,
                    settle: model.state == .transcribing,
                    flashGreen: flashGreen,
                    active: isRecordingActive)
            }
            .frame(
                width: HUDGeometry.recordingClusterWidth,
                height: HUDGeometry.waveformSize.height)
            .position(
                x: recordingClusterCenterX,
                y: HUDGeometry.waveformSize.height / 2)
            timerText
                .frame(
                    width: currentTimerWidth,
                    height: HUDGeometry.waveformSize.height,
                    alignment: .trailing)
                .position(
                    x: desiredListeningWidth
                        - HUDGeometry.contentInsetH
                        - currentTimerWidth / 2,
                    y: HUDGeometry.waveformSize.height / 2)
                .opacity(isListening ? 1 : 0)
        }
        .frame(
            width: desiredListeningWidth,
            height: HUDGeometry.waveformSize.height)
        .padding(.vertical, HUDGeometry.contentInsetV)
    }

    // MARK: - Meeting recording

    private var meetingSuggestionValue: (title: String, source: String) {
        if case .meetingSuggestion(let title, let source) = model.state {
            return (title, source)
        }
        return ("Meeting", "Call")
    }

    private var meetingSuggestionContent: some View {
        let value = meetingSuggestionValue
        return HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemYellow))
                .frame(
                    width: HUDGeometry.meetingPromptIconSide,
                    height: HUDGeometry.meetingPromptIconSide)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value.source) · \(value.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hudPrimaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("Local mic + Mac audio · Tell everyone")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hudSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: 210, alignment: .leading)
            meetingPrimaryButton("Start Notes") {
                model.onMeetingSuggestionAccept?()
            }
                .help("Records your microphone and computer audio locally. Make sure everyone knows.")
                .accessibilityLabel("Start meeting notes")
            Button { model.onMeetingSuggestionDismiss?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hudSecondaryText)
            .help("Not now")
            .accessibilityLabel("Dismiss meeting suggestion")
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: HUDGeometry.meetingPromptWidth)
    }

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
                    .foregroundStyle(hudPrimaryText)
                    .lineLimit(1)
                if meetingValue?.systemAudio == false {
                    Text("Mic only")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            .frame(width: HUDGeometry.meetingTitleWidth, alignment: .leading)
            Spacer(minLength: 0)
            timerText
                .frame(width: HUDGeometry.meetingTimerWidth, alignment: .trailing)
            Button { model.onMeetingStop?() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(
                        width: HUDGeometry.meetingStopButtonSide,
                        height: HUDGeometry.meetingStopButtonSide)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(hudPrimaryText)
            .help("Stop meeting recording")
            .accessibilityLabel("Stop meeting recording")
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: HUDGeometry.meetingWidth)
    }

    private var meetingEndTitle: String {
        if case .meetingEnd(let title) = model.state { return title }
        return "Meeting"
    }

    private var meetingEndContent: some View {
        HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .frame(
                    width: HUDGeometry.meetingPromptIconSide,
                    height: HUDGeometry.meetingPromptIconSide)
            VStack(alignment: .leading, spacing: 1) {
                Text("Meeting ended?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hudPrimaryText)
                Text(meetingEndTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hudSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 150, alignment: .leading)
            Button("Keep") { model.onMeetingEndKeep?() }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hudSecondaryText)
                .accessibilityLabel("Keep recording meeting")
            meetingPrimaryButton("Finish Notes") {
                model.onMeetingEndConfirm?()
            }
                .accessibilityLabel("Stop meeting and create notes")
            Button { model.onMeetingEndDiscard?() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hudSecondaryText)
            .help("Discard meeting recording…")
            .accessibilityLabel("Discard meeting recording")
        }
        .padding(.horizontal, HUDGeometry.contentInsetH)
        .padding(.vertical, HUDGeometry.contentInsetV)
        .frame(width: HUDGeometry.meetingPromptWidth)
    }

    private func meetingPrimaryButton(
        _ title: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(
                    Color.white.opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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

    private var contextChipWidth: CGFloat {
        min(
            Self.chipWidth(for: model.sessionContext),
            HUDGeometry.maximumChipWidth)
    }

    private var recordingInnerWidth: CGFloat {
        desiredListeningWidth - HUDGeometry.contentInsetH * 2
    }

    private var currentTimerWidth: CGFloat {
        HUDGeometry.textWidth(
            Self.elapsedString(seconds: model.displayedElapsedSeconds),
            font: HUDGeometry.timerFont)
    }

    private var recordingClusterCenterX: CGFloat {
        HUDGeometry.contentInsetH + HUDGeometry.recordingClusterCenterX(
            innerWidth: recordingInnerWidth,
            chipWidth: contextChipWidth,
            timerWidth: currentTimerWidth)
    }

    @ViewBuilder private var contextChip: some View {
        if let context = model.sessionContext {
            HStack(spacing: VeloraSpacing.xs) {
                if let icon = context.appIcon {
                    Image(nsImage: icon)
                        .frame(
                            width: HUDGeometry.chipIconSide,
                            height: HUDGeometry.chipIconSide)
                        .clipShape(RoundedRectangle(
                            cornerRadius: HUDGeometry.chipIconCornerRadius,
                            style: .continuous))
                }
                Text(context.modeName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hudSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var timerText: some View {
        Text(Self.elapsedString(seconds: model.displayedElapsedSeconds))
            .font(Font(HUDGeometry.timerFont))
            .foregroundStyle(hudSecondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    static func elapsedString(seconds: Int) -> String {
        let value = max(0, seconds)
        if value >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                value / 3_600, (value % 3_600) / 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    // MARK: - Success

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(hudPrimaryText)
            .symbolEffect(.bounce, value: showCheck)
            .opacity(showCheck ? 1 : 0)
            .scaleEffect(showCheck ? 1 : 0.5)
    }

    // MARK: - Error

    private var errorMessage: String {
        switch model.state {
        case .error(let message), .meetingFailure(_, let message): return message
        default: return ""
        }
    }

    private var meetingFailureID: String? {
        if case .meetingFailure(let meetingID, _) = model.state { return meetingID }
        return nil
    }

    private var errorContent: some View {
        HStack(spacing: VeloraSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(errorMessage)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(hudPrimaryText)
            Spacer(minLength: 0)
            if let meetingID = meetingFailureID {
                Button("Open") { model.onMeetingFailureOpen?(meetingID) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Button("Retry") { model.onMeetingFailureRetry?(meetingID) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else {
                Button(model.retryTitle) { model.onRetry?() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
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
                .foregroundStyle(hudSecondaryText)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hudSecondaryText)
            Text(pair.right)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hudPrimaryText)
                .lineLimit(1)
            Text("· Learned")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hudSecondaryText)
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
                .foregroundStyle(hudPrimaryText)
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

    private var isMeetingRecording: Bool {
        if case .meeting = model.state { return true }
        return false
    }

    private var isMeetingSuggestion: Bool {
        if case .meetingSuggestion = model.state { return true }
        return false
    }

    private var isMeetingEnd: Bool {
        if case .meetingEnd = model.state { return true }
        return false
    }

    private var isMeetingSurface: Bool {
        isMeetingRecording || isMeetingSuggestion || isMeetingEnd
            || meetingFailureID != nil
    }

    private var meetingAccessibilityHint: String {
        switch model.state {
        case .meetingSuggestion:
            return "Start notes or dismiss the detected meeting"
        case .meeting:
            return "Use the stop button to finish the meeting recording"
        case .meetingEnd:
            return "Finish notes or keep recording"
        case .meetingFailure:
            return "Open the saved transcript or retry meeting processing"
        default:
            return isStandby ? "Click to start dictation" : "Click to stop dictation"
        }
    }

    private var meetingAccessibilityLabel: String {
        switch model.state {
        case .meetingSuggestion(let title, let source):
            return "Meeting detected, \(source), \(title)"
        case .meeting(let title, let systemAudio):
            return "Recording \(title), \(systemAudio ? "microphone and computer audio" : "microphone only")"
        case .meetingEnd(let title):
            return "Meeting ended, \(title)"
        case .meetingFailure(_, let message):
            return message
        default:
            return "Velora dictation"
        }
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
        switch model.state {
        case .error, .meetingFailure: return true
        default: return false
        }
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

    private var hudPrimaryText: Color {
        Color.white.opacity(colorSchemeContrast == .increased ? 1 : 0.96)
    }

    private var hudSecondaryText: Color {
        Color.white.opacity(colorSchemeContrast == .increased ? 0.92 : 0.76)
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
            // Normal entry (from .listening): the waveform settles and
            // shimmers; dot, timer, and ring fade — no geometry change.
            // A mis-driven entry (the capsule was hidden or reshaped under a
            // live session, e.g. by a stale toast dismissal) must restore the
            // session capsule rather than stay invisible.
            if old != .listening && old != .transcribing {
                resetInstant(width: desiredListeningWidth, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            }

        case .meetingSuggestion, .meetingEnd:
            let target = HUDGeometry.meetingPromptWidth
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
            // Same self-healing rule as .transcribing: entered from a
            // non-session state, the capsule must become visible again
            // before it shrinks into the checkmark circle.
            if old != .listening && old != .transcribing {
                resetInstant(width: desiredListeningWidth, height: HUDGeometry.height)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    opacity = 1
                    scale = 1
                    yOffset = 0
                }
            }
            flashGreen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard case .inserted = model.state else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    width = HUDGeometry.insertedDiameter
                    height = HUDGeometry.height
                    showCheck = true
                }
            }

        case .error, .meetingFailure:
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
            if case .notice = old {
                // Same surface, new text (meeting progress ticks every few
                // seconds). A full exit/enter reset here blanked the capsule
                // on every update; resize in place instead.
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    width = noticeWidth
                }
            } else if old == .standby {
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
