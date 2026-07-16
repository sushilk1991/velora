import AppKit
import Combine
import SwiftUI

/// Sidebar selection shared between the window controller (deep links from
/// the menubar/HUD) and the SwiftUI shell. Optional because that is the type
/// `List(selection:)` binds against — a mismatched tag type silently breaks
/// row selection on macOS.
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
        } detail: {
            detail(for: selection.current)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private var sidebar: some View {
        List(selection: $selection.tab) {
            ForEach(Array(SettingsTab.sidebarSections.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Section(title) {
                        ForEach(group.tabs) { row($0) }
                    }
                } else {
                    Section {
                        ForEach(group.tabs) { row($0) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 250)
    }

    /// One sidebar row: a small colored icon tile + the section name
    /// (the System Settings idiom).
    private func row(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tab.tileColor.gradient)
                        .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Belt and suspenders: List selection drives the pane, and a direct
        // tap on the row does too — a tag/selection type quirk must never
        // leave the sidebar dead again (user-reported failure).
        .simultaneousGesture(TapGesture().onEnded { selection.tab = tab })
        // Explicit optional cast: the List selection is SettingsTab?, and the
        // tag type must match it exactly for row selection to bind.
        .tag(tab as SettingsTab?)
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
            AboutSettingsView()
        }
    }
}
