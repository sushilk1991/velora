import AppKit
import Combine
import SwiftUI

/// Rail selection shared between the window controller (deep links) and the
/// SwiftUI shell. `tab` stays optional for API stability; `current` resolves
/// nil to General.
final class SettingsWindowSelection: ObservableObject {
    @Published var tab: SettingsTab? = .general

    var current: SettingsTab { tab ?? .general }
}

/// The ⌘, Settings window: the same glass-sidebar chrome as the main window
/// at 780×560, a System Settings-style rail of coloured tiles (General,
/// Dictation, Shortcuts, Models, Advanced) and one grouped form per tab.
///
///     ┌────────────────────────────────────┐
///     │ ●●●                                │
///     │ ┌────────┐  General                │
///     │ │ ▣ Gen. │  ┌ APPEARANCE ────────┐ │
///     │ │ ▣ Dict.│  │ rows               │ │
///     │ │ ▣ …    │  └────────────────────┘ │
///     │ └────────┘                         │
///     └────────────────────────────────────┘
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 780, height: 560)

    private let model: SettingsModel
    private let selection = SettingsWindowSelection()
    private var tabObserver: AnyCancellable?
    /// See MainWindowController.holdsActivation.
    private var holdsActivation = false

    init(
        model: SettingsModel,
        meetingCoordinator: MeetingCoordinator,
        openSetupAssistant: @escaping () -> Void
    ) {
        self.model = model
        let root = SettingsRootView(
            model: model,
            selection: selection,
            meetingCoordinator: meetingCoordinator,
            openSetupAssistant: openSetupAssistant)

        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        MainWindowController.applyShellChrome(to: window, title: "Settings")
        window.setContentSize(Self.contentSize)
        window.contentMinSize = Self.contentSize
        window.center()

        super.init(window: window)
        window.delegate = self

        tabObserver = selection.$tab.sink { tab in
            veloraLog("Velora: settings pane → \((tab ?? .general).title)")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(selecting tab: SettingsTab? = nil) {
        if let tab {
            selection.tab = tab
        }
        MainWindowController.presentShell(self, holding: &holdsActivation)
    }

    /// Persists debounced free-text edits immediately (app termination).
    func flushPendingEdits() {
        model.flushMeetingNotesPrompt()
    }

    func windowWillClose(_ notification: Notification) {
        model.flushMeetingNotesPrompt()
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }
}

// MARK: - SwiftUI shell

/// Internal (not private) so `--snapshot` can render the same shell offscreen.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var selection: SettingsWindowSelection
    let meetingCoordinator: MeetingCoordinator
    let openSetupAssistant: () -> Void

    var body: some View {
        WindowShell {
            SettingsSidebar(selection: selection)
        } detail: {
            VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                PaneHeader(title: selection.current.title)
                detail(for: selection.current)
            }
        }
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView(model: model)
        case .dictation:
            DictationSettingsView(model: model)
        case .shortcuts:
            ShortcutsSettingsView(model: model)
        case .models:
            ModelSettingsView(model: model)
        case .advanced:
            AdvancedSettingsView(
                model: model, coordinator: meetingCoordinator,
                openSetupAssistant: openSetupAssistant)
        }
    }
}

/// The Settings rail: coloured-tile rows in the glass sidebar.
struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsWindowSelection

    var body: some View {
        FloatingSidebar {
            SidebarTopSpace()
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab, selection: selection)
            }
        }
    }
}

/// One rail row: coloured `IconTile` in the shared `SidebarRowFrame`.
/// Internal so `--snapshot` renders the real row, selection included.
struct SettingsSidebarRow: View {
    let tab: SettingsTab
    @ObservedObject var selection: SettingsWindowSelection

    var body: some View {
        let selected = selection.current == tab
        Button {
            selection.tab = tab
        } label: {
            SidebarRowFrame(selected: selected) {
                HStack(spacing: VeloraSpacing.s) {
                    IconTile(
                        symbol: tab.symbol, color: tab.tileColor,
                        side: WindowShellMetrics.symbolWell)
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
