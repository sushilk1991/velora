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
        if !holdsActivation {
            holdsActivation = true
            AppActivation.acquireRegular()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection)
                .frame(width: WindowShellMetrics.sidebarWidth)
            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                PaneTitle(title: selection.current.title)
                    .padding(.leading, VeloraSpacing.xl)  // lines up with the form's rows
                detail(for: selection.current)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, WindowShellMetrics.detailTop)
            .padding(.bottom, VeloraSpacing.s)
            .padding(.leading, WindowShellMetrics.sidebarGap - VeloraSpacing.s)
        }
        .background(WindowGlow())
        .background(VeloraPanel.canvas)
        .ignoresSafeArea()
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
            Color.clear.frame(height: WindowShellMetrics.trafficLightClearance - VeloraSpacing.s)
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab, selection: selection)
            }
        }
    }
}

/// One rail row: 22 pt coloured icon tile + tab name on a 32 pt row, the
/// selected row on the sidebar selection fill. Internal so `--snapshot`
/// renders the real row, selection state included.
struct SettingsSidebarRow: View {
    let tab: SettingsTab
    @ObservedObject var selection: SettingsWindowSelection

    private static var height: CGFloat { 32 }
    private static var tileSide: CGFloat { 22 }

    var body: some View {
        let selected = selection.current == tab
        Button {
            selection.tab = tab
        } label: {
            HStack(spacing: VeloraSpacing.s) {
                IconTile(symbol: tab.symbol, color: tab.tileColor, side: Self.tileSide)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VeloraSpacing.s)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous)
                    .fill(selected ? VeloraPanel.sidebarSelection : .clear))
            .contentShape(RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
