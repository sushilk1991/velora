import AppKit
import SwiftUI

/// Onboarding window: 640×520, hidden title bar, non-resizable, centered.
/// While it's open the app temporarily becomes a regular app (Dock icon) so
/// the window behaves normally; the accessory policy is restored on close.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model = OnboardingModel()
    /// See SettingsWindowController.holdsActivation — isVisible is false for
    /// a miniaturized window, so it can't gate the acquire.
    private var holdsActivation = false

    /// Called when onboarding finishes or the window closes.
    var onComplete: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Same paper/ink canvas and seamless titlebar as the main window, so
        // the first window a new user sees matches the app they land in.
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = VeloraPanel.canvasColor
        window.center()

        super.init(window: window)

        model.onFinish = { [weak self] in self?.close() }
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window, optionally jumping straight to a permission step
    /// (used by the menubar "Check Permissions…" re-run path).
    func show(startingAt step: OnboardingModel.Step? = nil) {
        if let step {
            model.step = step
        }
        model.refreshPermissions()
        // Same show sequence as the main, Settings and About windows: an
        // accessory app can swallow a plain makeKeyAndOrderFront.
        MainWindowController.presentShell(self, holding: &holdsActivation)
    }

    func windowWillClose(_ notification: Notification) {
        AppConfig.shared.onboardingComplete = true
        if holdsActivation {
            holdsActivation = false
            AppActivation.releaseRegular()
        }
        onComplete?()
    }
}
