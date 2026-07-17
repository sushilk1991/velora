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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = SettingsTab.general.title
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()

        super.init(window: window)
        window.delegate = self

        // System Settings titles the window after the selected pane. The log
        // line makes "clicked a tab, nothing happened" reports diagnosable.
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
        NavigationSplitView {
            sidebar
                .toolbar(removing: .sidebarToggle)  // fixed sidebar, like System Settings
        } detail: {
            detail(for: selection.current)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    /// Hand-rolled sidebar (System Settings idiom: unlabeled groups separated
    /// by whitespace, small icon tiles, accent-filled selected row). The rows
    /// are plain Buttons with an explicit selection background — `List`
    /// selection rendered no highlight here, and a settings sidebar must never
    /// hide which pane is open (user-reported failure, twice).
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                ForEach(Array(SettingsTab.sidebarGroups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(group) { tab in
                            SettingsSidebarRow(tab: tab, selection: selection)
                        }
                    }
                }
            }
            .padding(.horizontal, VeloraSpacing.s)
            .padding(.vertical, VeloraSpacing.m)
        }
        .navigationSplitViewColumnWidth(215)
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

/// One sidebar row: 20 pt colored icon tile + pane name, 28 pt tall, selected
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
            HStack(spacing: 7) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tab.tileColor.gradient))
                Text(tab.title)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
