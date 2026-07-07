import Combine
import Foundation
import SwiftUI

/// Onboarding state: current step, live permission status (polled — the
/// self-updating grant flip is the premium moment, design brief §4.2), and
/// try-it completion.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, hotkey, tryIt
    }

    @Published var step: Step = .welcome
    @Published var microphoneGranted = Permissions.microphoneGranted
    @Published var microphoneDenied = Permissions.microphoneDenied
    @Published var accessibilityGranted = Permissions.accessibilityGranted
    @Published var dictationSucceeded = false
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

    init() {
        // 1 s live-poll: cards flip to granted with no "I did it" button.
        pollTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshPermissions() }

        insertedObserver = NotificationCenter.default.addObserver(
            forName: .veloraDictationInserted, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dictationSucceeded = true
        }
    }

    deinit {
        if let insertedObserver {
            NotificationCenter.default.removeObserver(insertedObserver)
        }
    }

    func refreshPermissions() {
        microphoneGranted = Permissions.microphoneGranted
        microphoneDenied = Permissions.microphoneDenied
        let accessibilityNow = Permissions.accessibilityGranted
        if accessibilityNow, !accessibilityGranted {
            // Event taps created before the grant stay dead; tell the app to
            // reinstall the hotkey monitor immediately.
            NSLog("Velora: accessibility granted during onboarding")
            NotificationCenter.default.post(name: .veloraAccessibilityGranted, object: nil)
        }
        accessibilityGranted = accessibilityNow
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish?()
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            step = next
        }
    }

    func requestMicrophone() {
        Permissions.requestMicrophone { [weak self] granted in
            self?.microphoneGranted = granted
            self?.microphoneDenied = !granted
        }
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
}

/// Five-step onboarding flow (design brief §4.2): welcome → microphone →
/// accessibility → hotkey → try it. 640×520, dot page indicator, push
/// transitions, Skip paths on every step after welcome.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.step {
                case .welcome: welcomeStep.transition(.push(from: .trailing))
                case .microphone: microphoneStep.transition(.push(from: .trailing))
                case .accessibility: accessibilityStep.transition(.push(from: .trailing))
                case .hotkey: hotkeyStep.transition(.push(from: .trailing))
                case .tryIt: tryItStep.transition(.push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 640, height: 520)
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
            Text(title)
                .font(.title.weight(.semibold))
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
        stepLayout(title: "Welcome to Velora") {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 96))
                .foregroundStyle(VeloraBrand.iconGradient)
            Text("Hold a key, speak, release — polished text appears wherever you're typing. Entirely on this Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 440)
        } button: {
            Button("Get Started") { model.advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var microphoneStep: some View {
        permissionStep(
            title: "Velora needs to hear you",
            card: PermissionCard(
                symbol: "mic.fill",
                title: "Microphone",
                explanation: "Velora transcribes your speech on-device. Audio is processed locally and never leaves this Mac.",
                granted: model.microphoneGranted,
                buttonTitle: model.microphoneDenied ? "Open Settings" : "Allow Access",
                action: {
                    if model.microphoneDenied {
                        Permissions.openMicrophoneSettings()
                    } else {
                        model.requestMicrophone()
                    }
                }),
            continueEnabled: model.microphoneGranted)
    }

    private var accessibilityStep: some View {
        permissionStep(
            title: "Let Velora type for you",
            card: PermissionCard(
                symbol: "accessibility",
                title: "Accessibility",
                explanation: "Velora types for you and listens for your hotkey — that requires the Accessibility permission.",
                granted: model.accessibilityGranted,
                buttonTitle: "Open Settings",
                action: { model.requestAccessibility() }),
            continueEnabled: model.accessibilityGranted)
    }

    private func permissionStep(
        title: String, card: PermissionCard, continueEnabled: Bool
    ) -> some View {
        stepLayout(title: title) {
            card
        } button: {
            Button("Continue") { model.advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!continueEnabled)
        }
    }

    private var hotkeyStep: some View {
        stepLayout(title: "Your dictation key") {
            Text("Hold it and talk — release to insert. A quick tap locks recording on; tap again to finish.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 440)

            // The recorder is keycap-styled; click it to capture any combo
            // or a bare modifier, or use a quick pick below.
            HotkeyRecorderView(hotkey: $model.hotkey)
                .fixedSize(horizontal: true, vertical: false)
        } button: {
            Button("Continue") { model.advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var tryItStep: some View {
        stepLayout(title: "Try it") {
            Text("Click into the text field, hold \(model.hotkey.displayName), and speak.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TryItEditor()
                .frame(width: 480, height: 160)

            // Fixed-height slot so the success label never shifts the layout.
            Group {
                if model.dictationSucceeded {
                    Label("That's it — you're ready.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .font(.callout.weight(.medium))
                        .transition(.opacity)
                }
            }
            .frame(height: VeloraSpacing.xl)
        } button: {
            Button("Finish") { model.onFinish?() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.dictationSucceeded)
        }
    }

    // MARK: - Footer (dots + skip)

    private var footer: some View {
        ZStack {
            // 6 pt dot page indicator
            HStack(spacing: VeloraSpacing.s) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            HStack {
                Spacer()
                if model.step != .welcome {
                    Button("Skip") {
                        if model.step == .tryIt {
                            model.onFinish?()
                        } else {
                            model.advance()
                        }
                    }
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
                    .fill(Color.accentColor.opacity(granted ? 0.0 : 0.15))
                    .frame(width: 44, height: 44)
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .symbolEffect(.bounce, value: granted)
                        .transition(.opacity)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: granted)

            VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(granted ? "Granted" : buttonTitle, action: action)
                .disabled(granted)
        }
        .padding(VeloraSpacing.l)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1))
    }
}

// MARK: - Keycap (design brief §4.2 step 4)

/// Static keycap chip (menus, labels). The interactive recorder in
/// `HotkeyRecorderView` shares this design language.
struct KeycapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - Try-it editor

private struct TryItEditor: View {
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(VeloraSpacing.s)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 1))
    }
}
