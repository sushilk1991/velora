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
    /// Home's Start/Stop Dictation: the menubar's toggle, except that a take
    /// it starts only copies (`DictationController.toggleFromHome`).
    var toggleDictation: () -> Void
    /// The same action as the menubar "Start Meeting Notes…".
    var startMeeting: () -> Void
    /// Opens the ⌘, Settings window.
    var openSettings: () -> Void
    /// Opens the focused notes window for one meeting.
    var openMeetingNotes: (String) -> Void
    /// The dictation phase behind `toggleDictation`, for Home's button.
    var dictation = DictationActivity()
}

/// The dictation phase as the main window sees it. The AppDelegate mirrors
/// the controller's phase in here, as it does for the menubar icon, so
/// Home's Start Dictation reads Stop while listening.
final class DictationActivity: ObservableObject {
    @Published var phase: DictationController.Phase = .idle
}

/// A shell window that opens with nothing focused. On every order-in AppKit
/// makes a responder-less window's first text field first responder and
/// selects all its text, so one keystroke replaced a mode's whole Name.
/// Clearing the responder right after a hidden window orders in undoes
/// that; Tab still reaches the fields, and re-showing a visible window keeps
/// whatever the user is editing.
private final class ShellWindow: NSWindow {
    override func orderFrontRegardless() {
        clearingFocus { super.orderFrontRegardless() }
    }

    override func orderFront(_ sender: Any?) {
        clearingFocus { super.orderFront(sender) }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        clearingFocus { super.makeKeyAndOrderFront(sender) }
    }

    private func clearingFocus(_ orderIn: () -> Void) {
        // A window coming back from the Dock keeps the field being edited.
        let wasVisible = isVisible || isMiniaturized
        orderIn()
        if !wasVisible {
            makeFirstResponder(nil)
        }
    }
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
    private static let frameAutosaveName = "VeloraMain"
    private static let shellToolbarID = NSToolbar.Identifier("VeloraShell")

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

        let window = Self.makeShellWindow(
            rootView: root, title: "Velora", size: Self.contentSize, minimumSize: Self.minimumSize)
        // Reopens at the size and place the user left it: AppKit restores
        // the saved frame here and saves each move or resize. Not in
        // makeShellWindow, so selftest and harness windows never save one.
        window.setFrameAutosaveName(Self.frameAutosaveName)

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
        // A separator would paint a second "titlebar" band and make the
        // traffic lights look offset from the glass rail.
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar moves the traffic lights from (9, 9) to
        // (19, 19): 11 pt inside the glass rail instead of 1 pt from its
        // rounded corner, and level with the pane title (WindowShellMetrics).
        window.toolbar = NSToolbar(identifier: shellToolbarID)
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.backgroundColor = VeloraPanel.canvasColor
        window.title = title
    }

    /// A shell window around SwiftUI content, centred at `size` and never
    /// smaller than `minimumSize`.
    static func makeShellWindow<Root: View>(
        rootView: Root, title: String, size: NSSize, minimumSize: NSSize
    ) -> NSWindow {
        // The window owns its size. By default the hosting controller grows
        // the window to the content's ideal width and pins the minimum to the
        // content's, and Home's grid reports the window's own width as both,
        // so every Home layout widened the window (1180 → 1432 pt) and it
        // could never shrink back. With sizing off the controller rewrites
        // contentMinSize from its view's constraints, so the minimum lives
        // there; the view spans the whole window (full-size content).
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []
        let window = ShellWindow(contentViewController: hosting)
        NSLayoutConstraint.activate([
            hosting.view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.width),
            hosting.view.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height),
        ])
        applyShellChrome(to: window, title: title)
        window.setContentSize(size)
        window.contentMinSize = minimumSize
        window.center()
        return window
    }

    /// Shared show sequence for the main, Settings, and About windows.
    /// Accessory apps can swallow `makeKeyAndOrderFront` until the window is
    /// on screen — grey traffic lights on a front window were the symptom
    /// (see VisibleAlert). Order regardless, then activate, then key.
    static func presentShell(
        _ controller: NSWindowController,
        holding holds: inout Bool
    ) {
        if !holds {
            holds = true
            AppActivation.acquireRegular()
        }
        guard let window = controller.window else {
            return
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        controller.showWindow(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the window, activating the app so it becomes key. Optionally
    /// selects a pane (e.g. the HUD's "Open Velora" → Home). While the window
    /// is open the app runs as a regular app so the menu bar carries the
    /// Velora menus (user report: no app menu when focused).
    func show(selecting pane: MainPane? = nil) {
        if let pane {
            selection.pane = pane
        }
        Self.presentShell(self, holding: &holdsActivation)
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
        WindowShell {
            MainSidebar(
                selection: selection, supervisor: supervisor,
                openSettings: actions.openSettings)
        } detail: {
            detail(for: selection.current)
        }
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
            // Draws its own PaneHeader (search, Start Meeting Notes…) and
            // swaps list and detail in place.
            MeetingsSettingsView(
                model: model, coordinator: meetingCoordinator,
                processor: meetingProcessor, store: meetings)
        case .dictionary:
            // Draws its own PaneHeader: the search and Add state live inside it.
            DictionarySettingsView(model: model)
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
            SidebarTopSpace()
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

/// "● Ready · 0.23.0" — a 6 pt dot and an 11 pt caption. Green once the
/// supervisor's ready handshake landed; amber "Starting…", "Loading
/// models…", "Updating the speech engine…" or what went wrong otherwise.
/// `EngineStatusModel` keeps it current. A failure wraps rather than
/// losing its fix to truncation, with the dot on its first line:
///
///     ● Ready · 0.25.0
///     ● uv not found. Install it
///       from https://astral.sh/uv
struct EngineStatusLine: View {
    @StateObject private var status: EngineStatusModel

    init(supervisor: EngineSupervisor?) {
        _status = StateObject(wrappedValue: EngineStatusModel(supervisor: supervisor))
    }

    /// How long "Starting…" shows before the line calls the start stuck.
    /// The supervisor keeps no launch deadline, and the slow startup work
    /// (first-run setup, an update's dependency sync, model downloads, the
    /// speech-model load) reports a loading status, so a minute with no
    /// report is a stall.
    static let startupWait: TimeInterval = 60
    private static let dotDiameter: CGFloat = 6
    private static let captionSize: CGFloat = 11
    /// The dot's centre above the caption's first baseline: the middle of
    /// the font's line box, where centring put it beside one line.
    private static let dotLift: CGFloat = {
        let font = NSFont.systemFont(ofSize: captionSize)
        return (font.ascender + font.descender) / 2
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VeloraSpacing.s) {
            Circle()
                .fill(status.state == .ready ? VeloraStatus.success : VeloraStatus.warning)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Self.dotLift }
            Text(status.caption)
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { status.refresh() }
        .accessibilityElement(children: .combine)
    }

    /// The state in plain words, the version once ready. "Loading models…"
    /// while startup reports progress, so a long download does not read as
    /// a stuck start; an update's dependency sync reads as itself. A failure
    /// the supervisor reports reads in its own words, which name the fix
    /// ("uv not found. Install it from …"); a start with no report for
    /// `startupWait` says so and what to do.
    static func caption(
        state: EngineSupervisor.State, loading: String?, waited: TimeInterval, version: String
    ) -> String {
        if state == .ready {
            return "Ready · \(version)"
        }

        if case .degraded(let reason) = state {
            return reason
        }

        if let loading {
            return loading == EngineSupervisor.updatingStatus ? loading : "Loading models…"
        }

        return waited < startupWait ? "Starting…" : "Engine hasn't started. Quit and reopen Velora."
    }
}

/// What the sidebar's engine line says, kept current by the supervisor's
/// notifications rather than a poll: a state change, a loading change, a
/// status reply. The one timer fires when a quiet start reaches
/// `startupWait`, to say it is stuck.
///
///     launching ──(quiet 60 s)──▶ timer ──▶ "Engine hasn't started…"
///     any report ──▶ refresh, timer rescheduled from `quietSince`
final class EngineStatusModel: ObservableObject {
    @Published private(set) var state = EngineSupervisor.State.stopped
    @Published private(set) var caption = ""

    private let supervisor: EngineSupervisor?
    private let version: String
    private var observers: [NSObjectProtocol] = []
    private var stallTimer: Timer?

    init(supervisor: EngineSupervisor?, version: String = VeloraAppInfo.shortVersion) {
        self.supervisor = supervisor
        self.version = version
        let names: [Notification.Name] = [
            .veloraEngineStateChanged, .veloraEngineLoading,
            .veloraEngineStatus, .veloraEngineSetupChanged,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        stallTimer?.invalidate()
    }

    /// Re-reads the supervisor. `now` is a test seam for the stall clock.
    func refresh(now: Date = Date()) {
        state = supervisor?.state ?? .stopped
        let loading = supervisor?.loadingStatus
        let quietSince = supervisor?.quietSince
        let waited = quietSince.map { now.timeIntervalSince($0) } ?? 0
        caption = EngineStatusLine.caption(
            state: state, loading: loading, waited: waited, version: version)

        // Only a quiet start can turn into a stall; anything else waits for
        // the supervisor's next report. Without a supervisor (the snapshot
        // harnesses) there is no clock to run.
        stallTimer?.invalidate()
        stallTimer = nil
        var starting = state != .ready && loading == nil
        if case .degraded = state {
            starting = false
        }
        guard starting, let quietSince, waited < EngineStatusLine.startupWait else {
            return
        }

        let timer = Timer(
            fire: quietSince.addingTimeInterval(EngineStatusLine.startupWait),
            interval: 0, repeats: false
        ) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        stallTimer = timer
    }
}
