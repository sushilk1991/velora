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
    private var moveObserver: NSObjectProtocol?
    /// True while we reposition the panel ourselves, so the didMove observer
    /// doesn't mistake a preset placement for a user drag.
    private var isProgrammaticMove = false

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
        // Draggable, but click-through everywhere except the capsule itself: the
        // hosting view below hit-tests only the capsule region, so the large
        // transparent margins never steal clicks from the app underneath.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = HUDHostingView(rootView: HUDView(model: model))

        // Persist the new spot whenever the user drags the HUD.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.persistCustomOrigin() }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    }

    /// Stores the panel's current origin as a fraction of the screen's visible
    /// frame and flips the position preference to `.custom`.
    private func persistCustomOrigin() {
        guard !isProgrammaticMove else { return }
        // Only a real user drag should change the saved position. System-initiated
        // moves (display reconfiguration, AppKit clamping the panel when the
        // visible frame shrinks) also post didMove — those must NOT silently flip
        // the user's bottom/top preset to Custom.
        switch NSApp.currentEvent?.type {
        case .leftMouseDragged, .leftMouseUp:
            break
        default:
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let dx = max(1, visible.width - Self.panelSize.width)
        let dy = max(1, visible.height - Self.panelSize.height)
        let fx = (panel.frame.minX - visible.minX) / dx
        let fy = (panel.frame.minY - visible.minY) / dy
        AppConfig.shared.hudCustomOrigin = CGPoint(x: min(max(fx, 0), 1), y: min(max(fy, 0), 1))
        AppConfig.shared.hudPosition = .custom
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
        let centerX = visible.midX - Self.panelSize.width / 2

        // The capsule is vertically centered in the panel.
        let capsuleInset = (Self.panelSize.height - HUDGeometry.height) / 2
        let origin: NSPoint
        switch AppConfig.shared.hudPosition {
        case .bottomCenter:
            origin = NSPoint(x: centerX, y: visible.minY + VeloraSpacing.xl - capsuleInset)
        case .topCenter:
            origin = NSPoint(x: centerX, y: visible.maxY - VeloraSpacing.xl - HUDGeometry.height - capsuleInset)
        case .custom:
            if let frac = AppConfig.shared.hudCustomOrigin {
                let dx = max(1, visible.width - Self.panelSize.width)
                let dy = max(1, visible.height - Self.panelSize.height)
                origin = NSPoint(x: visible.minX + frac.x * dx, y: visible.minY + frac.y * dy)
            } else {  // custom with no stored origin yet → default bottom center
                origin = NSPoint(x: centerX, y: visible.minY + VeloraSpacing.xl - capsuleInset)
            }
        }
        // Guard the didMove observer against treating our own placement as a
        // user drag. Reset on the next runloop tick so it stays set even if
        // AppKit posts NSWindowDidMoveNotification asynchronously.
        isProgrammaticMove = true
        panel.setFrameOrigin(origin)
        DispatchQueue.main.async { [weak self] in self?.isProgrammaticMove = false }
    }
}

/// Hosting view that is transparent to the mouse everywhere except the capsule.
/// This keeps the HUD draggable (grab the capsule) while the large empty panel
/// margins pass clicks straight through to whatever is underneath.
private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capsule footprint, centered in the panel (see HUDPanel.panelSize).
        // The capsule width varies by state (280–420); use the widest so the
        // whole pill stays grabbable, with a little vertical slack for its
        // shadow/entrance offset.
        let size = HUDPanel.panelSize
        let w = HUDGeometry.maxListeningWidth
        let h = HUDGeometry.height + 24
        let capsule = NSRect(
            x: (size.width - w) / 2,
            y: (size.height - h) / 2,
            width: w,
            height: h)
        return capsule.contains(point) ? super.hitTest(point) : nil
    }
}
