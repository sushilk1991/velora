import AppKit
import Combine
import SwiftUI

/// Sidebar selection shared between the window controller (deep links from
/// the menubar/HUD) and the SwiftUI shell. `tab` stays optional for API
/// stability; `current` resolves nil to General.
final class SettingsWindowSelection: ObservableObject {
    @Published var tab: SettingsTab? = .general

    var current: SettingsTab { tab ?? .general }
}

/// The Settings window: a System Settings-style `NavigationSplitView` — a
/// grouped sidebar with colored icon tiles on the left, one grouped form per
/// section on the right. Replaces the toolbar tab strip, which overflowed
/// Shortcuts and About into a "»" chevron once the app passed eight tabs.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let selection = SettingsWindowSelection()
    private var titleObserver: AnyCancellable?

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
    /// selects a specific section (e.g. the menubar "History…" item).
    func show(selecting tab: SettingsTab? = nil) {
        if let tab {
            selection.tab = tab
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
        HStack(alignment: .top, spacing: 0) {
            SettingsSidebar(selection: selection)
            detail(for: selection.current)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { detailHeader }
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Pane title above the detail column — the visible replacement for the
    /// window title, System Settings-style. Content scrolls under the bar.
    private var detailHeader: some View {
        HStack {
            Text(selection.current.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VeloraSpacing.xl + VeloraSpacing.xs)
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

/// The sidebar column: an enclosed rounded card (the Raycast idiom on top of
/// the HIG's opaque-sidebar-for-settings rule) holding a search field, the
/// app identity row, and the grouped pane list. The traffic lights float on
/// the window background just above the card.
struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsWindowSelection
    @State private var query = ""

    var body: some View {
        card
            .frame(width: 236)
            .padding(.top, VeloraSpacing.xs)  // small gap below the titlebar strip
            .padding(.leading, VeloraSpacing.s + 2)
            .padding(.bottom, VeloraSpacing.s + 2)
            .padding(.trailing, VeloraSpacing.xs)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField(query: $query, onSubmit: selectFirstMatch)
                .padding(.bottom, VeloraSpacing.m)
            identityRow
                .padding(.bottom, VeloraSpacing.s)
            groupList
        }
        .padding(VeloraSpacing.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    /// App icon + name + version, the sidebar's identity block (Raycast puts
    /// the account here; Velora has no accounts, so the app itself is the
    /// identity). Clicking it opens About.
    private var identityRow: some View {
        Button {
            selection.tab = .about
        } label: {
            HStack(spacing: VeloraSpacing.s + 1) {
                Image(nsImage: VeloraAppInfo.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Velora")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Version \(VeloraAppInfo.shortVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VeloraSpacing.xs)
            .frame(height: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("About Velora")
    }

    private var groupList: some View {
        let groups = SettingsTab.filteredGroups(query: query)
        return ScrollView {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group) { tab in
                            SettingsSidebarRow(tab: tab, selection: selection)
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
            .padding(.vertical, VeloraSpacing.xs)
        }
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

/// One sidebar row: 25 pt colored icon tile + pane name, 34 pt tall, selected
/// row filled with the accent color and white text (the System Settings look).
/// Internal so `--snapshot` renders the real row, selection state included.
struct SettingsSidebarRow: View {
    let tab: SettingsTab
    @ObservedObject var selection: SettingsWindowSelection

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
                Text(tab.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VeloraSpacing.s)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
