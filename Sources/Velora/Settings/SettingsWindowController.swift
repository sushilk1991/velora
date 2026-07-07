import AppKit
import SwiftUI

/// The Settings window: an `NSTabViewController` in toolbar style (the native
/// System Settings idiom) hosting one SwiftUI grouped form per tab.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: SettingsModel

    init(supervisor: EngineSupervisor?) {
        model = SettingsModel(supervisor: supervisor)

        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar

        for tab in SettingsTab.allCases {
            let hosting: NSViewController
            switch tab {
            case .general:
                hosting = NSHostingController(rootView: GeneralSettingsView(model: model))
            case .dictation:
                hosting = NSHostingController(rootView: DictationSettingsView(model: model))
            case .model:
                hosting = NSHostingController(rootView: ModelSettingsView(model: model))
            case .shortcuts:
                hosting = NSHostingController(rootView: ShortcutsSettingsView(model: model))
            case .about:
                hosting = NSHostingController(rootView: AboutSettingsView())
            }
            hosting.preferredContentSize = NSSize(width: 580, height: tab.preferredHeight)

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

    /// Shows the window, activating the app so it becomes key.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
