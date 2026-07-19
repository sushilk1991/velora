import SwiftUI

@main
struct VeloraMobileApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

private enum AppTab: Hashable {
    case dictate
    case history
    case settings
}

struct AppRootView: View {
    @State private var selectedTab: AppTab = .dictate
    @State private var store: TranscriptStore
    @State private var speech: SpeechCaptureService
    @State private var shortcutRouter = CaptureLaunchRouter.shared

    init() {
        let store = TranscriptStore()
        _store = State(initialValue: store)
        _speech = State(initialValue: SpeechCaptureService(store: store))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureView(service: speech)
                .tabItem { Label("Dictate", systemImage: "waveform") }
                .tag(AppTab.dictate)

            HistoryView(store: store) {
                selectedTab = .dictate
            }
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            .tag(AppTab.history)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(VeloraTheme.violet)
        .task {
            await handlePendingShortcut()
        }
        .onChange(of: shortcutRouter.requestID) {
            Task { await handlePendingShortcut() }
        }
    }

    @MainActor
    private func handlePendingShortcut() async {
        guard shortcutRouter.consumePendingCapture() else { return }
        selectedTab = .dictate
        try? await Task.sleep(for: .milliseconds(250))
        await speech.start()
    }
}
