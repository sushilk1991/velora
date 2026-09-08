import AppKit
import SwiftUI

/// "About Velora" (app menu): a small fixed-size window hosting
/// `AboutSettingsView`, now that the Settings window has no About tab.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 420, height: 520)

    /// See MainWindowController.holdsActivation.
    private var holdsActivation = false

    init(model: SettingsModel) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "About Velora"
        window.backgroundColor = VeloraPanel.canvasColor
        window.contentViewController = NSHostingController(
            rootView: AboutSettingsView(model: model).background(VeloraPanel.canvas))
        window.setContentSize(Self.contentSize)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
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
