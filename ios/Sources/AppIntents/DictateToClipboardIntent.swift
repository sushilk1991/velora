import AppIntents

struct DictateToClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate to Clipboard"
    static let description = IntentDescription(
        "Open Velora ready to transcribe your voice and copy the finished text."
    )

    // Required for iOS 17–25. Apple deprecated this in the iOS 26 SDK in
    // favor of `supportedModes`, but keeps it as the backward-compatible path.
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            CaptureLaunchRouter.shared.requestCapture()
        }
        return .result(dialog: "Opening Velora, ready to dictate.")
    }
}

struct VeloraAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateToClipboardIntent(),
            phrases: [
                "Dictate to clipboard with \(.applicationName)",
                "Start dictating with \(.applicationName)",
            ],
            shortTitle: "Dictate to Clipboard",
            systemImageName: "waveform.badge.mic"
        )
    }
}
