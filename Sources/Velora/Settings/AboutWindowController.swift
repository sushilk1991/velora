import AppKit
import SwiftUI

/// "About Velora" (app menu): a small fixed-size window hosting
/// `AboutSettingsView`, now that the Settings window has no About tab.
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 420, height: 520)

    /// See MainWindowController.holdsActivation.
    private var holdsActivation = false

    init(model: SettingsModel) {
        // Same paint as the shells (canvas + glow + transparent titlebar)
        // so About is not a third design; strip resize after chrome apply
        // because this panel stays small and fixed.
        let root = AboutSettingsView(model: model)
            .padding(.top, WindowShellMetrics.trafficLightClearance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WindowGlow())
            .background(VeloraPanel.canvas)
            .ignoresSafeArea()
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        MainWindowController.applyShellChrome(to: window, title: "About Velora")
        window.styleMask.remove(.resizable)
        window.styleMask.remove(.miniaturizable)
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
        MainWindowController.presentShell(self, holding: &holdsActivation)
    }

    func windowWillClose(_ notification: Notification) {
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
    }
}
