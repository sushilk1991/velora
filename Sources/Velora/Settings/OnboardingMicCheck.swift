import AVFoundation
import Combine
import SwiftUI

/// One line explaining which microphone dictation will use, and why.
///
/// The onboarding microphone step is the first place a user can be told their
/// input is wrong, and "it did not work" is not an explanation. The line names
/// the resolved device and the ladder step that chose it, so the answer to
/// "why is it using the built-in mic?" is on screen instead of in a log.
enum OnboardingMicDiagnostic {
    enum Kind: Equatable {
        case ready
        /// No grant yet, or a denied one. The step's card carries the action.
        case noAccess
        case noDevices
    }

    struct Line: Equatable {
        let text: String
        let kind: Kind
        /// What to do about it. Nil when the answer is simply fine.
        let hint: String?
    }

    struct Input: Equatable {
        var accessGranted: Bool = true
        /// Denied is different from not-yet-asked: only one of them needs
        /// System Settings.
        var accessDenied: Bool = false
        var devices: [AudioInputDevices.Device] = []
        var chosenUID: String? = nil
        var systemDefaultUID: String? = nil
        var lastUsedUID: String? = nil
        var recentUIDs: [String] = []
        var excludedUIDs: [String] = []
        var language: InterfaceLanguage? = nil
    }

    /// The parenthetical for each ladder step, in the user's words.
    static func reason(for step: MicSelectionStep, language: InterfaceLanguage? = nil) -> String {
        switch step {
        case .chosen: return L10n.text("selected", language: language)
        case .systemDefault: return L10n.text("system default", language: language)
        case .lastUsed: return L10n.text("last used", language: language)
        case .recentChoice: return L10n.text("recently used", language: language)
        case .firstConnected: return L10n.text("the only microphone", language: language)
        case .exclusionOverridden: return L10n.text("every microphone is excluded", language: language)
        }
    }

    static func line(_ input: Input) -> Line {
        let language = input.language
        guard input.accessGranted else {
            return Line(
                text: L10n.text("Microphone access required", language: language),
                kind: .noAccess,
                hint: input.accessDenied
                    ? L10n.text(
                        "Open System Settings, Privacy and Security, Microphone, and switch Velora on.",
                        language: language)
                    : L10n.text("Click Allow Access above to grant it.", language: language))
        }
        guard !input.devices.isEmpty else {
            return Line(
                text: L10n.text("No microphone detected", language: language),
                kind: .noDevices,
                hint: L10n.text(
                    "Connect a microphone and it will appear here.", language: language))
        }

        let resolution = MicrophoneSelection.resolve(MicrophoneSelection.Ladder(
            chosenUID: input.chosenUID,
            systemDefaultUID: input.systemDefaultUID,
            lastUsedUID: input.lastUsedUID,
            recentUIDs: input.recentUIDs,
            excludedUIDs: input.excludedUIDs,
            connectedUIDs: input.devices.map(\.uid)))
        guard let resolution,
              let name = input.devices.first(where: { $0.uid == resolution.uid })?.name else {
            return Line(
                text: L10n.text("No microphone detected", language: language),
                kind: .noDevices,
                hint: L10n.text(
                    "Connect a microphone and it will appear here.", language: language))
        }

        return Line(
            text: L10n.formatted(
                "Using %@ (%@)",
                arguments: [name, reason(for: resolution.step, language: language)],
                language: language),
            kind: .ready,
            hint: hint(for: input, step: resolution.step, language: language))
    }

    /// Only the cases where the resolved device is not the one the user asked
    /// for: those are the moments a silent fallback looks like a bug.
    private static func hint(
        for input: Input, step: MicSelectionStep, language: InterfaceLanguage?
    ) -> String? {
        let excluded = Set(input.excludedUIDs)
        if let chosen = input.chosenUID {
            if excluded.contains(chosen) {
                return L10n.text(
                    "Your selected microphone is excluded. Allow it again from the microphone menu in the pill.",
                    language: language)
            }
            if !input.devices.contains(where: { $0.uid == chosen }) {
                return L10n.text(
                    "Your selected microphone is not connected, so Velora is using this one instead.",
                    language: language)
            }
        }
        if step == .exclusionOverridden {
            return L10n.text(
                "Every connected microphone is excluded. Allow one to choose it again.",
                language: language)
        }
        return nil
    }
}

/// The level bar's arithmetic, kept apart from the audio engine so it can be
/// pinned without a microphone.
enum OnboardingMicLevel {
    /// Below this the bar is empty, above `ceilingDb` it is full. −60 dBFS is a
    /// quiet room; −6 dBFS is close to clipping.
    static let floorDb: Double = -60
    static let ceilingDb: Double = -6

    /// Root-mean-square amplitude to a 0...1 bar position, on a decibel curve:
    /// a linear RMS bar sits near zero for normal speech and teaches nothing.
    static func target(rms: Float) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        let normalized = (decibels - floorDb) / (ceilingDb - floorDb)
        return min(1, max(0, normalized))
    }

    /// Rise quickly, fall slowly: a bar that drops to zero between syllables
    /// reads as broken rather than quiet.
    static func smoothed(
        previous: Double, target: Double, attack: Double = 0.5, release: Double = 0.15
    ) -> Double {
        let coefficient = target > previous ? attack : release
        return previous + (target - previous) * coefficient
    }
}

/// A live input level for the onboarding test.
///
/// Nothing is opened until `start()`, and `stop()` is idempotent so the view's
/// `onDisappear` and the object's own `deinit` can both call it. A denied grant
/// is reported once, not retried: the step's permission card owns that fix.
final class OnboardingMicLevelMonitor: ObservableObject {
    @Published private(set) var level: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var failure: String?

    private let stateLock = NSLock()
    private var engine: AVAudioEngine?
    private var watchdog: DispatchWorkItem?
    private var heardSound = false

    /// Main thread only.
    func start() {
        stateLock.lock()
        let alreadyRunning = engine != nil
        stateLock.unlock()
        guard !alreadyRunning else { return }

        failure = nil
        level = 0
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            failure = L10n.text("Microphone access required")
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failure = L10n.text("No microphone detected")
            return
        }

        heardSound = false
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let target = OnboardingMicLevel.target(rms: Self.rootMeanSquare(buffer))
            DispatchQueue.main.async {
                guard self.engine != nil else { return }
                if target > 0.05 { self.heardSound = true }
                self.level = OnboardingMicLevel.smoothed(
                    previous: self.level, target: target)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failure = L10n.text("The microphone could not be started.")
            return
        }

        stateLock.lock()
        self.engine = engine
        stateLock.unlock()
        isRunning = true
        scheduleSilenceWatchdog()
    }

    /// Main thread only.
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        stateLock.lock()
        let running = engine
        engine = nil
        stateLock.unlock()
        tearDown(running)
        isRunning = false
        level = 0
    }

    deinit {
        watchdog?.cancel()
        // No published writes from deinit: only the audio graph is released, so
        // a window closed mid-test cannot leave a tap running.
        stateLock.lock()
        let running = engine
        engine = nil
        stateLock.unlock()
        tearDown(running)
    }

    private func tearDown(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// A muted or dead input starts cleanly and then never reports a level; say
    /// so instead of showing a still bar.
    private func scheduleSilenceWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isRunning, !self.heardSound else { return }
            self.failure = L10n.text(
                "No sound arrived from this microphone. Check that it is not muted.")
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[index]
            sum += sample * sample
        }
        return (sum / Float(frames)).squareRoot()
    }
}

/// The onboarding microphone step's extra card: which device, why, and a level
/// meter that only runs while the user is testing.
struct OnboardingMicCheckCard: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    /// The live permission reading from the step.
    let granted: Bool

    @StateObject private var monitor = OnboardingMicLevelMonitor()
    @State private var chosenUID: String?
    @State private var devices: [AudioInputDevices.Device] = []
    @State private var diagnostic = OnboardingMicDiagnostic.Line(
        text: "", kind: .noDevices, hint: nil)
    @State private var testing = false
    @State private var showingTroubleshooting = false

    private static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            diagnosticLine

            HStack(spacing: VeloraSpacing.s) {
                Text(L10n.text("Microphone"))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: VeloraSpacing.s)
                Menu {
                    ForEach(HomeMicrophoneRows.choices(selected: chosenUID, devices: devices),
                            id: \.uid) { row in
                        Button {
                            chosenUID = row.uid
                        } label: {
                            if row.uid == chosenUID {
                                Label(row.title, systemImage: "checkmark")
                            } else {
                                Text(row.title)
                            }
                        }
                    }
                } label: {
                    // Always names the device, including System Default: an
                    // empty menu label reads as a missing control.
                    Text(HomeMicrophone.value(selected: chosenUID, devices: devices))
                        .frame(minWidth: 180, alignment: .trailing)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(L10n.text("Microphone"))
            }

            // Label and switch in an HStack: a Spacer inside a Toggle's label
            // makes the control claim the remaining height on macOS.
            HStack(spacing: VeloraSpacing.s) {
                Text(L10n.text("Test Microphone"))
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                Toggle("", isOn: $testing)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(L10n.text("Test Microphone"))
            }
            .disabled(!granted)
            .help(granted
                  ? L10n.text("Listen to this microphone for a few seconds.")
                  : L10n.text("Allow the microphone first."))

            levelBar

            if let failure = monitor.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup(isExpanded: $showingTroubleshooting) {
                VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
                    Text(L10n.text("The bar should move while you speak at a normal level."))
                    Text(L10n.text("If it stays still, raise the input level in System Settings, Sound, Input."))
                    Text(L10n.text("Bluetooth headsets take a moment to switch to their microphone after they connect."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, VeloraSpacing.xs)
            } label: {
                Text(L10n.text("Sounds wrong?"))
                    .font(.system(size: 13))
            }
        }
        .padding(VeloraSpacing.l)
        .frame(width: Self.width)
        .background(
            VeloraPanel.groupFill,
            in: RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous))
        .onAppear {
            chosenUID = AppConfig.shared.inputDeviceUID
            refresh()
        }
        .onDisappear {
            testing = false
            monitor.stop()
        }
        .onChange(of: chosenUID) { _, newValue in
            guard newValue != AppConfig.shared.inputDeviceUID else { return }
            AppConfig.shared.inputDeviceUID = newValue
            refresh()
        }
        .onChange(of: testing) { _, isOn in
            if isOn, granted {
                monitor.start()
            } else {
                monitor.stop()
            }
        }
        .onChange(of: granted) { _, isGranted in
            if !isGranted {
                testing = false
                monitor.stop()
            }
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .veloraAudioInputDevicesChanged)) { _ in
            devices = AudioInputDevices.displayList()
            refresh()
        }
    }

    @ViewBuilder
    private var diagnosticLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let hint = diagnostic.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch diagnostic.kind {
        case .ready: return "mic.fill"
        case .noAccess: return "lock.fill"
        case .noDevices: return "mic.slash"
        }
    }

    private var tint: Color {
        diagnostic.kind == .ready ? VeloraBrand.sky.color : VeloraStatus.warning
    }

    private var levelBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // The card fill is too close to the canvas for a track to read;
                // secondary at low opacity survives both appearances.
                Capsule().fill(Color.secondary.opacity(0.18))
                if monitor.level > 0.01 {
                    Capsule()
                        .fill(VeloraBrand.sky.color)
                        .frame(width: proxy.size.width * monitor.level)
                }
            }
        }
        .frame(height: 6)
        .opacity(testing ? 1 : 0.45)
        .animation(VeloraMotion.quick, value: monitor.level)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Microphone level"))
        .accessibilityValue("\(Int((monitor.level * 100).rounded()))%")
    }

    private func refresh() {
        devices = AudioInputDevices.displayList()
        diagnostic = OnboardingMicDiagnostic.line(OnboardingMicDiagnostic.Input(
            accessGranted: granted,
            accessDenied: Permissions.microphoneDenied,
            devices: devices,
            chosenUID: AppConfig.shared.inputDeviceUID,
            systemDefaultUID: AudioInputDevices.systemDefaultUID(),
            lastUsedUID: AppConfig.shared.inputDeviceLastUID,
            recentUIDs: AppConfig.shared.recentInputDeviceUIDs,
            excludedUIDs: AppConfig.shared.excludedInputDeviceUIDs))
    }
}
