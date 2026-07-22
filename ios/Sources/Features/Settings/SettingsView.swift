import SwiftUI

struct SettingsView: View {
    @AppStorage(VeloraPreferences.speechLocaleIdentifierKey)
    private var speechLocaleIdentifier = VeloraPreferences.systemLocaleIdentifier
    @AppStorage(VeloraPreferences.dictationStyleKey)
    private var dictationStyleRawValue = DictationStyle.automatic.rawValue

    @State private var showingActionButtonGuide = false

    private let languages: [(name: String, identifier: String)] = [
        ("System language", VeloraPreferences.systemLocaleIdentifier),
        ("English (India)", "en-IN"),
        ("English (US)", "en-US"),
        ("Hindi", "hi-IN"),
        ("Spanish", "es-ES"),
        ("French", "fr-FR"),
        ("German", "de-DE"),
        ("Japanese", "ja-JP"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showingActionButtonGuide = true
                    } label: {
                        Label("Set up the Action Button", systemImage: "button.programmable")
                    }
                } header: {
                    Text("Fastest way to dictate")
                } footer: {
                    Text("The Dictate to Clipboard App Shortcut opens Velora ready to listen. Finish once and your text is copied automatically.")
                }

                Section {
                    Picker("Recognition language", selection: $speechLocaleIdentifier) {
                        ForEach(languages, id: \.identifier) { language in
                            Text(language.name).tag(language.identifier)
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Velora only uses recognition languages available on-device. Downloaded language support is managed by iOS.")
                }

                Section {
                    Picker("Format for", selection: $dictationStyleRawValue) {
                        ForEach(DictationStyle.allCases) { style in
                            Label(style.title, systemImage: style.systemImage)
                                .tag(style.rawValue)
                        }
                    }

                    Label(
                        TranscriptRefiner.capability.title,
                        systemImage: TranscriptRefiner.capability.isAvailable
                            ? "apple.intelligence"
                            : "textformat"
                    )
                } header: {
                    Text("Smart cleanup")
                } footer: {
                    Text("\(TranscriptRefiner.capability.detail) iOS does not let Velora inspect the app where you will paste, so your selected format stays active until you change it.")
                }

                Section {
                    Label("Recognition stays on this iPhone", systemImage: "lock.shield.fill")
                    Label("The latest 50 transcripts stay in local History", systemImage: "internaldrive.fill")
                    Label("Nothing is uploaded by Velora", systemImage: "icloud.slash.fill")
                } header: {
                    Text("Privacy by construction")
                }

                Section {
                    optionalLink("Email Support", systemImage: "envelope.fill", destination: VeloraMobileLinks.supportEmail)
                    optionalLink("Velora Website", systemImage: "safari.fill", destination: VeloraMobileLinks.website)
                    optionalLink("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right", destination: VeloraMobileLinks.repository)
                    optionalLink("Star Velora on GitHub", systemImage: "star.fill", destination: VeloraMobileLinks.star)
                } header: {
                    Text("Velora")
                } footer: {
                    Text("Open-source voice tools for Mac and iPhone. Support: \(VeloraMobileLinks.supportEmailAddress)")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Minimum iOS", value: "17.0")
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingActionButtonGuide) {
                ActionButtonGuideView()
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version, let build {
            return "\(version) (\(build))"
        }
        return version ?? "Development build"
    }

    @ViewBuilder
    private func optionalLink(
        _ title: String,
        systemImage: String,
        destination: URL?
    ) -> some View {
        if let destination {
            Link(destination: destination) {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

struct ActionButtonGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "button.programmable")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(VeloraTheme.violet)
                            .accessibilityHidden(true)
                        Text("One press. Then speak.")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Assign Velora’s App Shortcut once and your Action Button becomes a private voice-to-clipboard key.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        GuideStep(number: 1, title: "Open iPhone Settings", detail: "Tap Action Button.")
                        GuideStep(number: 2, title: "Choose Shortcut", detail: "Tap Choose a Shortcut.")
                        GuideStep(number: 3, title: "Pick Dictate to Clipboard", detail: "Find it under the Velora App Shortcuts.")
                    }

                    if let guide = VeloraMobileLinks.actionButtonGuide {
                        Link("Read Apple’s Action Button guide", destination: guide)
                            .font(.headline)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Action Button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(VeloraTheme.violet, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.body).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Settings") {
    SettingsView()
}
