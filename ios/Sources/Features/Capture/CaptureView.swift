import SwiftUI
import UIKit

struct CaptureView: View {
    @Bindable var service: SpeechCaptureService

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingActionButtonGuide = false

    var body: some View {
        NavigationStack {
            ZStack {
                VeloraTheme.canvas(for: colorScheme).ignoresSafeArea()
                ambientShape

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        hero
                        transcriptSurface
                        captureControl

                        Button {
                            showingActionButtonGuide = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "button.programmable")
                                    .font(.title3)
                                    .foregroundStyle(VeloraTheme.violet)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Make it your Action Button")
                                        .font(.headline)
                                    Text("One press opens Velora ready to listen")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 56)
                        .accessibilityHint("Shows three steps for assigning the Dictate to Clipboard shortcut")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 104)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Velora")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingActionButtonGuide) {
                ActionButtonGuideView()
            }
            .sensoryFeedback(.success, trigger: service.copiedPulse)
        }
    }

    private var ambientShape: some View {
        Circle()
            .fill(VeloraTheme.violet.opacity(colorScheme == .dark ? 0.18 : 0.10))
            .frame(width: 360, height: 360)
            .blur(radius: 2)
            .offset(x: 180, y: -290)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ON-DEVICE DICTATION", systemImage: "lock.shield.fill")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(VeloraTheme.violet)

            Text(heroTitle)
                .font(.system(.title, design: .rounded, weight: .bold))
                .tracking(-0.8)
                .accessibilityAddTraits(.isHeader)

            Text(heroSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(surfaceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if service.phase == .copied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(service.transcript.isEmpty ? placeholder : service.transcript)
                .font(.title3.weight(service.transcript.isEmpty ? .regular : .medium))
                .foregroundStyle(service.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                .textSelection(.enabled)
                .contentTransition(.numericText())

            if service.phase == .failed, let message = service.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open iPhone Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(18)
        .background(VeloraTheme.raised(for: colorScheme), in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(VeloraTheme.violet.opacity(colorScheme == .dark ? 0.22 : 0.10))
        }
    }

    private var captureControl: some View {
        VStack(spacing: 8) {
            LiveWaveform(level: service.audioLevel, isActive: service.phase == .listening)

            Button(action: primaryAction) {
                ZStack {
                    Circle()
                        .fill(controlColor)
                        .frame(width: 94, height: 94)
                        .shadow(color: controlColor.opacity(0.28), radius: 22, y: 10)

                    controlIcon
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
            }
            .buttonStyle(CaptureButtonStyle())
            .disabled(service.phase == .requestingPermission || service.phase == .finishing)
            .accessibilityLabel(primaryLabel)
            .accessibilityHint(primaryHint)

            Text(primaryLabel)
                .font(.headline)

            if service.phase == .listening {
                Button("Cancel", role: .cancel) { service.cancel() }
                    .font(.subheadline.weight(.semibold))
            } else if service.phase == .copied {
                HStack(spacing: 20) {
                    Button("Copy again") { service.copyAgain() }
                    Button("Start another") {
                        service.reset()
                        Task { await service.start() }
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var heroTitle: String {
        switch service.phase {
        case .listening: "I’m listening."
        case .finishing: "Making it ready."
        case .copied: "It’s on your clipboard."
        case .failed: "That didn’t work yet."
        case .idle, .requestingPermission: "Say it. Paste it anywhere."
        }
    }

    private var heroSubtitle: String {
        switch service.phase {
        case .listening: "Speak naturally, then tap Finish. Your words stay on this iPhone."
        case .finishing: "Velora is finishing the last words and punctuation."
        case .copied: "Switch to any app and paste. A local copy is waiting in History."
        case .failed: "Nothing was copied. Follow the fix below and try once more."
        case .idle, .requestingPermission: "Private voice-to-text that ends exactly where you need it: the clipboard."
        }
    }

    private var surfaceLabel: String {
        service.phase == .copied ? "READY TO PASTE" : "LIVE TRANSCRIPT"
    }

    private var placeholder: String {
        switch service.phase {
        case .requestingPermission: "Getting the microphone ready…"
        case .finishing: "Finishing your last words…"
        case .failed: "No text was copied."
        default: "Your words will appear here as you speak."
        }
    }

    private var primaryLabel: String {
        switch service.phase {
        case .idle: "Start dictating"
        case .requestingPermission: "Getting ready…"
        case .listening: "Finish and copy"
        case .finishing: "Finishing…"
        case .copied: "Copied"
        case .failed: "Try again"
        }
    }

    private var primaryHint: String {
        switch service.phase {
        case .listening: "Stops listening and copies the transcript"
        default: "Starts on-device speech recognition"
        }
    }

    private var controlColor: Color {
        switch service.phase {
        case .listening: VeloraTheme.warmAccent
        case .copied: .green
        case .failed: .red
        default: VeloraTheme.violet
        }
    }

    @ViewBuilder
    private var controlIcon: some View {
        switch service.phase {
        case .requestingPermission, .finishing:
            ProgressView().tint(.white)
        case .listening:
            Image(systemName: "stop.fill")
        case .copied:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "arrow.clockwise")
        case .idle:
            Image(systemName: "mic.fill")
        }
    }

    private func primaryAction() {
        switch service.phase {
        case .listening:
            service.stopAndCopy()
        case .idle, .failed:
            service.reset()
            Task { await service.start() }
        case .copied:
            service.copyAgain()
        case .requestingPermission, .finishing:
            break
        }
    }
}

private struct CaptureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    let defaults = UserDefaults(suiteName: "preview.capture") ?? .standard
    let store = TranscriptStore(defaults: defaults)
    CaptureView(service: SpeechCaptureService(store: store))
}
