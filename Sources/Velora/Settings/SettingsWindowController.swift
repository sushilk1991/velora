import AppKit
import Combine
import SwiftUI

/// Sidebar selection + shell state shared between the window controller
/// (deep links from the menubar/HUD, the View menu's sidebar toggle) and the
/// SwiftUI shell. `tab` stays optional for API stability; `current` resolves
/// nil to General.
final class SettingsWindowSelection: ObservableObject {
    @Published var tab: SettingsTab? = .general

    /// Superwhisper-style collapsed icon rail. Persisted so the window
    /// reopens the way the user left it.
    @Published var sidebarCollapsed = AppConfig.shared.settingsSidebarCollapsed {
        didSet { AppConfig.shared.settingsSidebarCollapsed = sidebarCollapsed }
    }

    var current: SettingsTab { tab ?? .general }
}

/// The Settings window: a Superwhisper-style shell — flat collapsible
/// sidebar (search, grouped colored-tile rows, identity chip bottom bar) on
/// the left, one grouped form per section on the right, pane title in the
/// content header. Replaces the toolbar tab strip, which overflowed once the
/// app passed eight tabs.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let selection = SettingsWindowSelection()
    private var titleObserver: AnyCancellable?
    /// Whether this window currently holds the regular-app activation. An
    /// `isVisible` check would double-acquire when show() reopens a
    /// MINIATURIZED window (isVisible is false there) and the hold would
    /// never drain.
    private var holdsActivation = false

    init(
        supervisor: EngineSupervisor?,
        history: HistoryStore,
        dictionary: DictionaryRepository,
        dictionarySync: ICloudDictionarySync,
        meetings: MeetingStore,
        meetingCoordinator: MeetingCoordinator,
        meetingProcessor: MeetingProcessor
    ) {
        model = SettingsModel(
            supervisor: supervisor,
            dictionary: dictionary,
            dictionarySync: dictionarySync)

        let root = SettingsRootView(
            model: model,
            selection: selection,
            supervisor: supervisor,
            history: history,
            meetings: meetings,
            meetingCoordinator: meetingCoordinator,
            meetingProcessor: meetingProcessor)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        // A transparent, title-hidden titlebar melts into the window
        // background, so the traffic lights sit in a seamless strip above the
        // sidebar card (the Raycast/System Settings hybrid look). Deliberately
        // NOT `.fullSizeContentView`: hosting SwiftUI under the titlebar left
        // the detail column blank (snapshot-verified), and the plain titled
        // window needs no safe-area games.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = SettingsTab.general.title
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()

        super.init(window: window)
        window.delegate = self

        // The visible title lives in the detail header now, but the window
        // title still names the pane for Mission Control and accessibility.
        // The log line makes "clicked a tab, nothing happened" diagnosable.
        titleObserver = selection.$tab.sink { [weak window] tab in
            let resolved = tab ?? .general
            window?.title = resolved.title
            veloraLog("Velora: settings pane → \(resolved.title)")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window, activating the app so it becomes key. Optionally
    /// selects a specific section (e.g. the menubar "History…" item). While
    /// the window is open the app runs as a regular app so the menu bar
    /// carries the Velora menus (user report: no app menu when focused).
    func show(selecting tab: SettingsTab? = nil) {
        if let tab {
            selection.tab = tab
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

    /// View → Hide/Show Sidebar (⌃⌘S).
    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selection.sidebarCollapsed.toggle()
        }
    }
}

// MARK: - SwiftUI shell

/// Internal (not private) so `--snapshot` can render the same shell offscreen.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: SettingsWindowSelection
    let supervisor: EngineSupervisor?
    let history: HistoryStore
    let meetings: MeetingStore
    let meetingCoordinator: MeetingCoordinator
    let meetingProcessor: MeetingProcessor

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection)
            Divider()  // hairline between sidebar and content (vertical in HStack)
            detail(for: selection.current)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { detailHeader }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Pane title above the detail column — the visible replacement for the
    /// window title. Leads with the sidebar toggle, anchored here like
    /// Superwhisper/Finder/Notes (its menu counterpart is View → Hide
    /// Sidebar). Content scrolls under the bar.
    private var detailHeader: some View {
        HStack(spacing: VeloraSpacing.m) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    selection.sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(selection.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
            Text(selection.current.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VeloraSpacing.xl)
        .frame(height: 46)
        // Matches the (transparent) titlebar strip above, so the top chrome
        // reads as one surface; scrolled form content hides behind it.
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            // An explicit hairline: Divider kept picking the vertical
            // orientation inside the overlay (snapshot-verified, twice).
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(model: model)
        case .dictation:
            DictationSettingsView(model: model)
        case .dictionary:
            DictionarySettingsView(model: model)
        case .model:
            ModelSettingsView(model: model)
        case .modes:
            ModesSettingsView(supervisor: supervisor)
        case .history:
            HistorySettingsView(model: model, history: history, supervisor: supervisor)
        case .intelligence:
            IntelligenceSettingsView(model: model, history: history)
        case .meetings:
            MeetingsSettingsView(
                model: model, coordinator: meetingCoordinator,
                processor: meetingProcessor, store: meetings)
        case .shortcuts:
            ShortcutsSettingsView(model: model)
        case .about:
            AboutSettingsView(model: model)
        }
    }
}

/// The sidebar column, Superwhisper-style: a flat full-height source list —
/// search at the top (HIG sidebar rule), grouped pane rows, and the app
/// identity chip as the sidebar's bottom bar. Collapsible to an icon-only
/// rail; the toggle lives in the content header and in View → Hide Sidebar.
struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsWindowSelection
    @State private var query = ""

    private var collapsed: Bool { selection.sidebarCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !collapsed {
                SettingsSearchField(query: $query, onSubmit: selectFirstMatch)
                    .padding(.horizontal, VeloraSpacing.m)
                    .padding(.top, VeloraSpacing.s)
                    .padding(.bottom, VeloraSpacing.m)
            } else {
                Color.clear.frame(height: VeloraSpacing.s)
            }
            groupList
            identityChip
                .padding(.horizontal, collapsed ? VeloraSpacing.s : VeloraSpacing.m)
                .padding(.vertical, VeloraSpacing.m)
        }
        .frame(width: collapsed ? 64 : 240)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var groupList: some View {
        let groups = SettingsTab.filteredGroups(query: collapsed ? "" : query)
        return ScrollView {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group) { tab in
                            SettingsSidebarRow(
                                tab: tab, selection: selection, collapsed: collapsed)
                        }
                    }
                }
                if groups.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, VeloraSpacing.l)
                }
            }
            .padding(.horizontal, collapsed ? VeloraSpacing.xs : VeloraSpacing.m)
            .padding(.vertical, VeloraSpacing.xs)
        }
    }

    /// App icon + name + version pinned at the bottom (the Superwhisper chip;
    /// per the HIG this strip is the sidebar's bottom bar). Clicking opens
    /// About. Velora has no accounts, so the app itself is the identity.
    private var identityChip: some View {
        Button {
            selection.tab = .about
        } label: {
            HStack(spacing: VeloraSpacing.s) {
                Image(nsImage: VeloraAppInfo.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                if !collapsed {
                    Text("Velora")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("v\(VeloraAppInfo.shortVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, collapsed ? VeloraSpacing.xs : VeloraSpacing.s + 2)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("About Velora")
    }

    /// Return in the search field jumps to the best match, System
    /// Settings-style.
    private func selectFirstMatch() {
        if let first = SettingsTab.filteredGroups(query: query).first?.first {
            selection.tab = first
        }
    }
}

/// Compact in-card search field (a toolbar `.searchable` has no toolbar to
/// live in here). Escape clears; Return selects the first match.
struct SettingsSearchField: View {
    @Binding var query: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: VeloraSpacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
                // First Escape clears, second resigns focus (review finding:
                // clearing forever made Escape a consumed no-op).
                .onExitCommand {
                    if query.isEmpty {
                        focused = false
                    } else {
                        query = ""
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, VeloraSpacing.s)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    focused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                    lineWidth: 1))
    }
}

/// One sidebar row: 25 pt colored icon tile + pane name, 34 pt tall. The
/// selected row gets a soft neutral fill (the Superwhisper/source-list look —
/// still unmistakable, which a settings sidebar must be; user-reported
/// failure, twice). Collapsed mode shows just the tile, title as tooltip.
/// Internal so `--snapshot` renders the real row, selection state included.
struct SettingsSidebarRow: View {
    let tab: SettingsTab
    @ObservedObject var selection: SettingsWindowSelection
    var collapsed = false

    var body: some View {
        let selected = selection.current == tab
        Button {
            selection.tab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 25, height: 25)
                    .background(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(tab.tileColor.gradient))
                if !collapsed {
                    Text(tab.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, collapsed ? 0 : VeloraSpacing.s)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.primary.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
