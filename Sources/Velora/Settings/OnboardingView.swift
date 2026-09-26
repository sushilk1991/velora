import Combine
import Foundation
import SwiftUI

/// User-visible readiness for onboarding's first dictation. The engine can
/// accept raw dictation before its writing model finishes, but onboarding
/// waits for the explicit first-run setup completion signal so the guided
/// attempt never competes with an active model download.
struct OnboardingSetupState: Equatable {
    let isComplete: Bool
    let status: String?
    let fraction: Double?

    var canTryIt: Bool { isComplete && status == nil }
    var progressFraction: Double? { fraction.map { min(0.99, max(0, $0)) } }
    var primaryActionTitle: String {
        canTryIt ? "Finish" : "Continue in the Background"
    }
}

/// Onboarding state: current step, live permission status (polled — the
/// self-updating grant flip is the premium moment, design brief §4.2), and
/// try-it completion.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, privacy, microphone, inputMonitoring, accessibility, hotkey, tryIt
    }

    @Published var step: Step = .welcome
    @Published var microphoneGranted = Permissions.microphoneGranted
    @Published var microphoneDenied = Permissions.microphoneDenied
    @Published var inputMonitoringGranted = Permissions.inputMonitoringGranted
    @Published var accessibilityGranted = Permissions.accessibilityGranted
    @Published var dictationSucceeded = false
    /// First-run setup status ("Downloading the speech model (1.6 GB): 42%").
    /// The try-it step shows a progress card instead of a dead text field
    /// while models download.
    @Published var setupStatus: String? = EngineSupervisor.lastLoadingStatus
    @Published var setupFraction: Double? = EngineSupervisor.lastLoadingFraction
    @Published var setupComplete = EngineSupervisor.lastSetupComplete
    @Published var tryItText = ""
    @Published var hotkey = AppConfig.shared.hotkey {
        didSet {
            guard hotkey != oldValue else { return }
            AppConfig.shared.hotkey = hotkey
            NotificationCenter.default.post(name: .veloraHotkeyChanged, object: nil)
        }
    }

    /// Set by the window controller; dismisses the window.
    var onFinish: (() -> Void)?

    private var pollTimer: AnyCancellable?
    private var insertedObserver: NSObjectProtocol?
    private var loadingObserver: NSObjectProtocol?
    private var setupObserver: NSObjectProtocol?

    var setupState: OnboardingSetupState {
        OnboardingSetupState(
            isComplete: setupComplete,
            status: setupStatus,
            fraction: setupFraction)
    }

    /// The settle gate's clock. `Date()` in the app; the selftest steps its
    /// own, so the gate doesn't depend on how loaded the machine is.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        // 1 s live-poll: cards flip to granted with no "I did it" button.
        pollTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshPermissions() }

        insertedObserver = NotificationCenter.default.addObserver(
            forName: .veloraDictationInserted, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dictationSucceeded = true
        }

        loadingObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineLoading, object: nil, queue: .main
        ) { [weak self] note in
            self?.setupStatus = note.userInfo?["status"] as? String
            self?.setupFraction = note.userInfo?["fraction"] as? Double
        }

        setupObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineSetupChanged, object: nil, queue: .main
        ) { [weak self] note in
            self?.setupComplete = note.userInfo?["complete"] as? Bool ?? false
        }
    }

    deinit {
        if let insertedObserver {
            NotificationCenter.default.removeObserver(insertedObserver)
        }
        if let loadingObserver {
            NotificationCenter.default.removeObserver(loadingObserver)
        }
        if let setupObserver {
            NotificationCenter.default.removeObserver(setupObserver)
        }
    }

    func refreshPermissions() {
        microphoneGranted = Permissions.microphoneGranted
        microphoneDenied = Permissions.microphoneDenied

        let inputMonitoringNow = Permissions.inputMonitoringGranted
        if inputMonitoringNow, !inputMonitoringGranted {
            // The hotkey tap is starved until this grant lands; reinstall it
            // the instant the user flips the switch, no relaunch needed.
            veloraLog("Velora: input monitoring granted during onboarding — reinstalling hotkey")
            NotificationCenter.default.post(name: .veloraAccessibilityGranted, object: nil)
        }
        inputMonitoringGranted = inputMonitoringNow

        let accessibilityNow = Permissions.accessibilityGranted
        if accessibilityNow, !accessibilityGranted {
            // Event taps created before the grant stay dead; tell the app to
            // reinstall the hotkey monitor immediately.
            veloraLog("Velora: accessibility granted during onboarding")
            NotificationCenter.default.post(name: .veloraAccessibilityGranted, object: nil)
        }
        accessibilityGranted = accessibilityNow
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish?()
            return
        }
        stepShownAt = now()
        withAnimation(VeloraMotion.springSlow) {
            step = next
        }
    }

    /// A press this soon after a step appears is dropped: a double Return
    /// (or double click) must not skip the step the first press revealed.
    /// About the length of the step's push transition.
    static let stepSettleInterval: TimeInterval = 0.5
    /// When the current step appeared; `advance` stamps it.
    private var stepShownAt = Date.distantPast

    /// Whether a step's primary button may move on. Permission steps wait
    /// for their grant; Skip is the way past a missing one.
    func canContinue(from step: Step) -> Bool {
        switch step {
        case .microphone:
            return microphoneGranted
        case .inputMonitoring:
            return inputMonitoringGranted
        case .accessibility:
            return accessibilityGranted
        default:
            return true
        }
    }

    /// The primary button's action (Get Started, Continue). One press moves
    /// one step:
    ///
    ///     Return ↓ ─ advance ─ repeat, repeat… (held: dropped)
    ///     Return ↓ ─ advance ─ Return ↓ < 0.5 s (double: dropped)
    func pressContinue(isRepeat: Bool) {
        guard isSettled(isRepeat: isRepeat) else { return }
        guard canContinue(from: step) else { return }
        advance()
    }

    /// Skip moves one step past any missing grant, and finishes on try-it
    /// (the last step, where `advance` calls `onFinish`). It waits out the
    /// same gate as Continue: Skip stays put while steps change under it,
    /// so a double click would skip two.
    func pressSkip(isRepeat: Bool) {
        guard isSettled(isRepeat: isRepeat) else { return }
        advance()
    }

    /// False for a key repeat, or for a press within `stepSettleInterval`
    /// of the step appearing.
    private func isSettled(isRepeat: Bool) -> Bool {
        !isRepeat && now().timeIntervalSince(stepShownAt) >= Self.stepSettleInterval
    }

    func requestMicrophone() {
        Permissions.requestMicrophone { [weak self] granted in
            self?.microphoneGranted = granted
            self?.microphoneDenied = !granted
        }
    }

    func requestInputMonitoring() {
        // Prompt (registers Velora in the list) then open the pane so the user
        // can flip the switch even if the prompt was previously dismissed.
        Permissions.requestInputMonitoring()
        Permissions.openInputMonitoringSettings()
    }

    func requestAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }
}

/// Fixed vertical rhythm shared by every onboarding step: title pinned
/// 32 pt from the top, content centered in the remaining space, primary
/// button pinned 32 pt above the page dots, 24 pt side margins.
private enum OnboardingLayout {
    static let titleTop: CGFloat = 32
    static let buttonBottom: CGFloat = 32
    static let sideMargin: CGFloat = 24
    /// Side of the app icon on the welcome step.
    static let welcomeIconSide: CGFloat = 96
}

/// Seven-step onboarding flow (design brief §4.2): welcome → privacy →
/// microphone → input monitoring → accessibility → hotkey → try it. 640×520,
/// dot page indicator, push transitions, Skip on every step after welcome.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.step {
                case .welcome: welcomeStep.transition(.push(from: .trailing))
                case .privacy: privacyStep.transition(.push(from: .trailing))
                case .microphone: microphoneStep.transition(.push(from: .trailing))
                case .inputMonitoring: inputMonitoringStep.transition(.push(from: .trailing))
                case .accessibility: accessibilityStep.transition(.push(from: .trailing))
                case .hotkey: hotkeyStep.transition(.push(from: .trailing))
                case .tryIt: tryItStep.transition(.push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 640, height: 520)
        // Same canvas and corner glow as the main window (WindowShell).
        .background(WindowGlow().ignoresSafeArea())
        .background(VeloraPanel.canvas.ignoresSafeArea())
    }

    /// True when the press is an autorepeat of a held key: a held Return
    /// must not walk through the steps. `isARepeat` is only valid on key
    /// events, so a click reads false.
    private static var pressIsRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    // MARK: - Step scaffold

    /// Shared vertical structure: fixed title, centered content block,
    /// pinned primary button (see `OnboardingLayout`).
    private func stepLayout(
        title: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder button: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            // The shell's serif title voice; SerifHeadline adds the full stop.
            SerifHeadline(title)
                .multilineTextAlignment(.center)
                .padding(.top, OnboardingLayout.titleTop)

            VStack(spacing: VeloraSpacing.xl) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            button()
                .padding(.bottom, OnboardingLayout.buttonBottom)
        }
        .padding(.horizontal, OnboardingLayout.sideMargin)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        stepLayout(title: "You talk. Velora types") {
            // The real app icon, as in About and the update window.
            Image(nsImage: VeloraAppInfo.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: OnboardingLayout.welcomeIconSide, height: OnboardingLayout.welcomeIconSide)
            Text("Hold a key, talk, let go. The words appear wherever your cursor is: an email, Slack, a terminal.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 440)
            Text("A few short steps, about two minutes.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(width: 440)
        } button: {
            Button("Get Started") { model.pressContinue(isRepeat: Self.pressIsRepeat) }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// The privacy claims are required copy, so they get room of their own
    /// rather than a fine-print block crowding the welcome step. Network
    /// exceptions stay next to the claim: a promise with a hidden asterisk
    /// is worse than no promise.
    private var privacyStep: some View {
        stepLayout(title: "Your voice stays on this Mac") {
            Image(systemName: "airplane")
                .font(.system(size: 60))
                .foregroundStyle(VeloraBrand.iconGradient)
            Text("Velora has no dictation server. Your audio, the screenshots it takes and the text it reads on screen stay on this Mac and are never sent to us. Nothing it reads on screen is kept.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 440)
            Text("Dictation works with no internet. Velora goes online only for setup, model downloads, update checks, and syncing your Dictionary through iCloud.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(width: 440)
        } button: {
            Button("Continue") { model.pressContinue(isRepeat: Self.pressIsRepeat) }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            title: "Allow the microphone",
            card: PermissionCard(
                symbol: "mic.fill",
                title: "Microphone",
                explanation: "Velora turns your voice into text on this Mac. The audio goes nowhere else.",
                granted: model.microphoneGranted,
                buttonTitle: model.microphoneDenied ? "Open Settings" : "Allow Access",
                action: {
                    if model.microphoneDenied {
                        Permissions.openMicrophoneSettings()
                    } else {
                        model.requestMicrophone()
                    }
                }),
            continueEnabled: model.canContinue(from: .microphone))
    }

    private var inputMonitoringStep: some View {
        permissionStep(
            title: "Allow Input Monitoring",
            card: PermissionCard(
                symbol: "keyboard.fill",
                title: "Input Monitoring",
                explanation: "Lets Velora notice your dictation key in every app. Without it, the key does nothing.",
                granted: model.inputMonitoringGranted,
                buttonTitle: "Open Settings",
                action: { model.requestInputMonitoring() }),
            continueEnabled: model.canContinue(from: .inputMonitoring),
            staleHint: !model.inputMonitoringGranted)
            // Fire the native "Velora would like to monitor input" prompt as
            // soon as the step appears — this also registers Velora in the
            // Input Monitoring list so the toggle exists when the pane opens.
            .onAppear {
                if !model.inputMonitoringGranted { Permissions.requestInputMonitoring() }
            }
    }

    private var accessibilityStep: some View {
        permissionStep(
            title: "Allow Accessibility",
            card: PermissionCard(
                symbol: "accessibility",
                title: "Accessibility",
                explanation: "Lets Velora type the finished text into the app you're in. Without it, Velora hears you but can't type.",
                granted: model.accessibilityGranted,
                buttonTitle: "Open Settings",
                action: { model.requestAccessibility() }),
            continueEnabled: model.canContinue(from: .accessibility),
            staleHint: !model.accessibilityGranted)
    }

    private func permissionStep(
        title: String, card: PermissionCard, continueEnabled: Bool,
        staleHint: Bool = false
    ) -> some View {
        stepLayout(title: title) {
            card
            // TCC grants are tied to the app's code signature. After an app
            // update whose signature changed, an old "Velora" row can linger
            // in the list, toggled on, while the running build stays denied —
            // toggling it does nothing. Removing and re-adding fixes it. Shown
            // only while the permission reads as not granted.
            if staleHint {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("Velora already in the list but the switch won't stick? Select it, click “−”, then add Velora back. An older Velora build was signed differently, so macOS needs the entry re-added.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 480, alignment: .leading)
                .padding(.top, VeloraSpacing.xs)
            }
        } button: {
            Button("Continue") { model.pressContinue(isRepeat: Self.pressIsRepeat) }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.defaultAction)
                .disabled(!continueEnabled)
        }
    }

    private var hotkeyStep: some View {
        stepLayout(title: "Pick your dictation key") {
            Text("Hold it, talk, let go, and the text appears. Or tap once to start and tap again to stop.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 440)

            // The recorder is keycap-styled; click it to capture any combo
            // or a bare modifier, or use a quick pick below.
            HotkeyRecorderView(hotkey: $model.hotkey)
                .fixedSize(horizontal: true, vertical: false)
        } button: {
            Button("Continue") { model.pressContinue(isRepeat: Self.pressIsRepeat) }
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var tryItStep: some View {
        let setup = model.setupState
        return stepLayout(title: setup.canTryIt ? "Try it" : "Downloading models") {
            if setup.canTryIt {
                Text("Click the box, hold \(model.hotkey.displayLabel), and say anything.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TryItEditor(text: $model.tryItText)
                    .frame(width: 480, height: 160)

                // Fixed-height slot so the success label never shifts the layout.
                Group {
                    if model.dictationSucceeded {
                        // Green text measured 1.9:1 on light: only the glyph
                        // is green, the words stay primary.
                        Label {
                            Text("You're set up.")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(VeloraStatus.success)
                        }
                        .font(.callout.weight(.medium))
                        .transition(.opacity)
                    }
                }
                .frame(height: VeloraSpacing.xl)
            } else {
                ModelSetupCard(state: setup)
                    .transition(.opacity)
            }
        } button: {
            // No Return here: in the try-it box Return is a newline, and
            // Continue in the Background closes setup mid-download, so it
            // takes a deliberate click, past the settle gate: it sits where
            // the hotkey step's Continue was.
            Button(setup.primaryActionTitle) { model.pressContinue(isRepeat: Self.pressIsRepeat) }
                .buttonStyle(.primaryCapsule)
                .disabled(setup.canTryIt && !model.dictationSucceeded)
        }
        .animation(VeloraMotion.standard, value: setup.canTryIt)
    }

    // MARK: - Footer (dots + skip)

    private var footer: some View {
        ZStack {
            // 6 pt dot page indicator
            HStack(spacing: VeloraSpacing.s) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == model.step ? VeloraBrand.sky.color : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            HStack {
                Spacer()
                if model.step != .welcome {
                    Button("Skip") { model.pressSkip(isRepeat: Self.pressIsRepeat) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, OnboardingLayout.sideMargin)
        }
        .frame(height: 44)
        .padding(.bottom, VeloraSpacing.s)
    }
}

// MARK: - First-run model setup

private struct ModelSetupCard: View {
    let state: OnboardingSetupState

    var body: some View {
        VStack(spacing: VeloraSpacing.l) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(VeloraBrand.sky.color)

            VStack(spacing: VeloraSpacing.s) {
                Text(state.status ?? "Starting the downloads…")
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)

                Group {
                    if let fraction = state.progressFraction {
                        ProgressView(value: fraction, total: 1)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 360)
            }

            Text("Velora downloads the speech and writing models once. You can continue; the download keeps going.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 400)
        }
        .padding(VeloraSpacing.xl)
        .frame(width: 480)
        // The one card style (GroupCard): grouped-Form fill, no border.
        .background(
            VeloraPanel.groupFill,
            in: RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous))
    }
}

// MARK: - Permission card (design brief §4.2)

struct PermissionCard: View {
    let symbol: String
    let title: String
    let explanation: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: VeloraSpacing.m) {
            ZStack {
                Circle()
                    .fill(VeloraBrand.sky.color.opacity(granted ? 0.0 : 0.15))
                    .frame(width: 44, height: 44)
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(VeloraStatus.success)
                        .symbolEffect(.bounce, value: granted)
                        .transition(.opacity)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(VeloraBrand.sky.color)
                }
            }
            .animation(VeloraMotion.quick, value: granted)

            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            // Granted is a state, not an action: a label in place of a dead
            // button. The green check in the leading circle is the card's
            // one status glyph; green text measured 1.83:1 on the card fill,
            // so the word stays secondary.
            if granted {
                Text("Granted")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(buttonTitle, action: action)
            }
        }
        .padding(VeloraSpacing.l)
        .frame(width: 480)
        // The one card style (GroupCard): grouped-Form fill, no border.
        .background(
            VeloraPanel.groupFill,
            in: RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous))
    }
}

// MARK: - Try-it editor

private struct TryItEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(VeloraSpacing.s)
            .background(VeloraPanel.card, in: RoundedRectangle(cornerRadius: VeloraRadius.tile))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.tile)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1))
    }
}
