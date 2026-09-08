import AppKit
import Combine
import SwiftUI

/// The panes of the one "Velora" window, in sidebar order. Settings is not a
/// pane: it is its own ⌘, window (`SettingsTab`).
enum MainPane: String, CaseIterable, Identifiable {
    case home, history, stats, meetings, dictionary, modes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .stats: return "Stats"
        case .meetings: return "Meetings"
        case .dictionary: return "Dictionary"
        case .modes: return "Modes"
        }
    }

    /// Monochrome, non-filled sidebar symbols (Finder/Notes idiom).
    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .stats: return "chart.bar"
        case .meetings: return "person.2.wave.2"
        case .dictionary: return "character.book.closed"
        case .modes: return "slider.horizontal.3"
        }
    }
}

/// Sidebar selection shared between the window controller (deep links from
/// the menubar/HUD) and the SwiftUI shell. `pane` stays optional for API
/// stability; `current` resolves nil to Home.
final class MainWindowSelection: ObservableObject {
    @Published var pane: MainPane? = .home

    var current: MainPane { pane ?? .home }
}

/// App actions the main window triggers but does not own. Injected by the
/// AppDelegate so the window never reaches for a global.
struct MainWindowActions {
    /// The same toggle the menubar "Start Dictation" uses.
    var toggleDictation: () -> Void
    /// The same action as the menubar "Start Meeting Notes…".
    var startMeeting: () -> Void
    /// Opens the ⌘, Settings window.
    var openSettings: () -> Void
    /// Opens the focused notes window for one meeting.
    var openMeetingNotes: (String) -> Void
}

/// Sidebar geometry shared by the main and Settings windows.
enum WindowShellMetrics {
    /// Sidebar width including its 8 pt inset on each side.
    static let sidebarWidth: CGFloat = 200
    /// Room left at the top of the glass sidebar for the traffic lights,
    /// which sit inside it under `.fullSizeContentView`.
    static let trafficLightClearance: CGFloat = 52
    /// Gap between the sidebar's outer edge and the detail column.
    static let sidebarGap: CGFloat = 16
    static let detailTop: CGFloat = 18
    static let detailTrailing: CGFloat = 24
    static let detailBottom: CGFloat = 22
    static let detailLeading: CGFloat = 20
    /// Grouped forms centre themselves at any width; capping them keeps the
    /// Meetings form hugging the pane title instead of floating mid-window.
    static let formMaxWidth: CGFloat = 740
}

/// The main window: a floating glass sidebar (Home, History, Stats, Meetings,
/// Dictionary, Modes, then Settings and the engine status) beside one pane.
///
///     ┌──────────────────────────────────────────────┐
///     │ ●●●                                          │  traffic lights in the glass
///     │ ┌────────┐  Home              [mic] [Start]  │
///     │ │ ▒rows▒ │                                   │
///     │ │        │  pane content                     │
///     │ │ ⚙ ⌘,   │                                   │
///     │ │ ● ready│                                   │
///     │ └────────┘                                   │
///     └──────────────────────────────────────────────┘
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 1180, height: 760)
    private static let minimumSize = NSSize(width: 960, height: 620)

    private let selection = MainWindowSelection()
    private var paneObserver: AnyCancellable?
    /// Whether this window currently holds the regular-app activation. An
    /// `isVisible` check would double-acquire when show() reopens a
    /// MINIATURIZED window (isVisible is false there) and the hold would
    /// never drain.
    private var holdsActivation = false

    init(
        model: SettingsModel,
        supervisor: EngineSupervisor?,
        history: HistoryStore,
        meetings: MeetingStore,
        meetingCoordinator: MeetingCoordinator,
        meetingProcessor: MeetingProcessor,
        actions: MainWindowActions
    ) {
        let root = MainRootView(
            model: model,
            selection: selection,
            supervisor: supervisor,
            history: history,
            meetings: meetings,
            meetingCoordinator: meetingCoordinator,
            meetingProcessor: meetingProcessor,
            actions: actions)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        Self.applyShellChrome(to: window, title: "Velora")
        window.setContentSize(Self.contentSize)
        window.contentMinSize = Self.minimumSize
        window.center()

        super.init(window: window)
        window.delegate = self

        // The log line makes "clicked a row, nothing happened" diagnosable.
        paneObserver = selection.$pane.sink { pane in
            veloraLog("Velora: main pane → \((pane ?? .home).title)")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The chrome both shell windows share: full-size content so the glass
    /// sidebar starts at the very top with the traffic lights inside it, a
    /// transparent titlebar on the canvas colour, and no visible title text
    /// (the window keeps its name for Mission Control and accessibility).
    static func applyShellChrome(to window: NSWindow, title: String) {
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = VeloraPanel.canvasColor
        window.title = title
    }

    /// Shows the window, activating the app so it becomes key. Optionally
    /// selects a pane (e.g. the HUD's "Open Velora" → Home). While the window
    /// is open the app runs as a regular app so the menu bar carries the
    /// Velora menus (user report: no app menu when focused).
    func show(selecting pane: MainPane? = nil) {
        if let pane {
            selection.pane = pane
        }
        if !holdsActivation {
            holdsActivation = true
            AppActivation.acquireRegular()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }
}

// MARK: - SwiftUI shell

/// Internal (not private) so `--snapshot` can render the same shell offscreen.
struct MainRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: MainWindowSelection
    let supervisor: EngineSupervisor?
    let history: HistoryStore
    let meetings: MeetingStore
    let meetingCoordinator: MeetingCoordinator
    let meetingProcessor: MeetingProcessor
    let actions: MainWindowActions

    var body: some View {
        HStack(spacing: 0) {
            MainSidebar(selection: selection, supervisor: supervisor, openSettings: actions.openSettings)
                .frame(width: WindowShellMetrics.sidebarWidth)
            detail(for: selection.current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, WindowShellMetrics.detailTop)
                .padding(.trailing, WindowShellMetrics.detailTrailing)
                .padding(.bottom, WindowShellMetrics.detailBottom)
                .padding(.leading, WindowShellMetrics.detailLeading + WindowShellMetrics.sidebarGap
                    - VeloraSpacing.s)  // the sidebar already insets itself 8 pt
        }
        .background(WindowGlow())
        .background(VeloraPanel.canvas)
        // Full-size content: the shell owns the titlebar strip too.
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func detail(for pane: MainPane) -> some View {
        switch pane {
        case .home:
            HomeView(
                model: model, selection: selection, history: history,
                meetings: meetings, actions: actions)
        case .history:
            HistoryPane(model: model, history: history, supervisor: supervisor)
        case .stats:
            StatsPane(model: model, history: history)
        case .meetings:
            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                PaneHeader(title: pane.title)
                MeetingsSettingsView(
                    model: model, coordinator: meetingCoordinator,
                    processor: meetingProcessor, store: meetings)
                    .frame(maxWidth: WindowShellMetrics.formMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .dictionary:
            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                PaneHeader(title: pane.title)
                DictionarySettingsView(model: model)
            }
        case .modes:
            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                PaneHeader(title: pane.title)
                ModesSettingsView(supervisor: supervisor)
            }
        }
    }
}

/// History: the pane title with the search box and app filter beside it,
/// over the journal. One view model, owned here, feeds both.
struct HistoryPane: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var viewModel: HistoryViewModel

    init(model: SettingsModel, history: HistoryStore, supervisor: EngineSupervisor?) {
        self.model = model
        _viewModel = StateObject(wrappedValue: HistoryViewModel(history: history, supervisor: supervisor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            PaneHeader(title: MainPane.history.title) {
                HistoryHeaderControls(viewModel: viewModel)
            }
            HistorySettingsView(model: model, viewModel: viewModel)
        }
    }
}

/// Stats: the pane title with the range picker and Share beside it, over
/// the dashboard. Same one-view-model arrangement as `HistoryPane`.
struct StatsPane: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var viewModel: IntelligenceViewModel

    init(model: SettingsModel, history: HistoryStore) {
        self.model = model
        _viewModel = StateObject(wrappedValue: IntelligenceViewModel(history: history))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            PaneHeader(title: MainPane.stats.title) {
                StatsHeaderControls(viewModel: viewModel)
            }
            IntelligenceSettingsView(model: model, viewModel: viewModel)
        }
    }
}

/// The main window's glass sidebar: pane rows, a Settings row with the ⌘,
/// hint, and the engine status line at the bottom.
struct MainSidebar: View {
    @ObservedObject var selection: MainWindowSelection
    let supervisor: EngineSupervisor?
    let openSettings: () -> Void

    var body: some View {
        FloatingSidebar {
            Color.clear.frame(height: WindowShellMetrics.trafficLightClearance - VeloraSpacing.s)
            ForEach(MainPane.allCases) { pane in
                Button {
                    selection.pane = pane
                } label: {
                    SidebarRow(symbol: pane.symbol, title: pane.title, selected: selection.current == pane)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: VeloraSpacing.m)
            Button(action: openSettings) {
                SidebarRow(symbol: "gearshape", title: "Settings", selected: false) {
                    Text("⌘,")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            EngineStatusLine(supervisor: supervisor)
                .padding(.horizontal, VeloraSpacing.s)
                .padding(.vertical, VeloraSpacing.s)
        }
    }
}

/// "● Engine ready · 0.23.0" — a 6 pt dot and an 11 pt caption. Green once
/// the supervisor's ready handshake landed; the amber "Engine starting…"
/// otherwise. Refreshes on the engine's status notifications.
struct EngineStatusLine: View {
    let supervisor: EngineSupervisor?
    @State private var ready = false

    private static let dotDiameter: CGFloat = 6

    var body: some View {
        HStack(spacing: VeloraSpacing.s) {
            Circle()
                .fill(ready ? VeloraStatus.success : VeloraStatus.warning)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            Text(ready ? "Engine ready · \(VeloraAppInfo.shortVersion)" : "Engine starting…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .veloraEngineStatus)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraEngineSetupChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .veloraEngineLoading)) { _ in refresh() }
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        ready = supervisor?.isReady ?? false
    }
}
