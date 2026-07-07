import AppKit
import SwiftUI

/// Owns the HUD's NSPanel and drives state transitions on the model.
///
/// Panel configuration follows the design brief §1.2 / spike findings:
/// borderless non-activating panel at `.statusBar` level that joins all
/// Spaces, never takes focus, and ignores mouse events except in the error
/// state (which shows a Retry button).
final class HUDPanel {
    /// Host size: the largest capsule (420×56 listening pill) plus room for
    /// the 20 pt shadow and the ±12 pt entrance offset so nothing clips.
    static let panelSize = NSSize(width: 480, height: 120)

    let model = HUDModel()

    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the capsule draws its own animated shadow
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    /// Moves the HUD to a new state, showing/hiding the panel as needed.
    /// Never repositions while visible.
    func transition(to newState: HUDState) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        if !newState.isHidden {
            if model.state.isHidden || !panel.isVisible {
                position()
            }
            if case .error = newState {
                panel.ignoresMouseEvents = false
            } else {
                panel.ignoresMouseEvents = true
            }
            panel.orderFrontRegardless()  // shows without activating Velora
        }

        model.state = newState

        if newState.isHidden {
            // Keep the panel on screen long enough for the exit animation.
            let item = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    /// Centers horizontally on the screen with keyboard focus; capsule bottom
    /// edge 20 pt above the Dock (or 20 pt below the menubar for top position).
    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - Self.panelSize.width / 2

        // The capsule is vertically centered in the panel.
        let capsuleInset = (Self.panelSize.height - HUDGeometry.height) / 2
        let y: CGFloat
        switch AppConfig.shared.hudPosition {
        case .bottomCenter:
            y = visible.minY + VeloraSpacing.xl - capsuleInset
        case .topCenter:
            y = visible.maxY - VeloraSpacing.xl - HUDGeometry.height - capsuleInset
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
