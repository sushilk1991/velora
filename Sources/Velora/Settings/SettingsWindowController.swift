import AppKit
import SwiftUI

/// The Settings window: an `NSTabViewController` in toolbar style (the native
/// System Settings idiom) hosting one SwiftUI grouped form per tab.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel
    private let tabController: NSTabViewController

    init(
        supervisor: EngineSupervisor?,
        history: HistoryStore,
        dictionary: DictionaryRepository,
        dictionarySync: ICloudDictionarySync
    ) {
        model = SettingsModel(
            supervisor: supervisor,
            dictionary: dictionary,
            dictionarySync: dictionarySync)

        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar
        self.tabController = tabController

        for tab in SettingsTab.allCases {
            let hosting: NSViewController
            switch tab {
            case .general:
                hosting = NSHostingController(rootView: GeneralSettingsView(model: model))
            case .dictation:
                hosting = NSHostingController(rootView: DictationSettingsView(model: model))
            case .model:
                hosting = NSHostingController(rootView: ModelSettingsView(model: model))
            case .modes:
                hosting = NSHostingController(rootView: ModesSettingsView(supervisor: supervisor))
            case .history:
                hosting = NSHostingController(rootView: HistorySettingsView(
                    model: model, history: history, supervisor: supervisor))
            case .shortcuts:
                hosting = NSHostingController(rootView: ShortcutsSettingsView(model: model))
            case .about:
                hosting = NSHostingController(rootView: AboutSettingsView())
            }
            hosting.preferredContentSize = NSSize(width: 580, height: tab.preferredHeight)
            // A toolbar-style NSTabViewController propagates the *selected*
            // child VC's title to the window; without one AppKit shows
            // "Untitled". Give every tab the app name so the window title is
            // always "Velora" regardless of the active tab.
            hosting.title = "Velora"

            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabController.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Velora Settings"
        window.titlebarAppearsTransparent = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window, activating the app so it becomes key. Optionally
    /// selects a specific tab (e.g. the menubar "History…" item).
    func show(selecting tab: SettingsTab? = nil) {
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabController.selectedTabViewItemIndex = index
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
