import AppKit
import SwiftUI

extension Notification.Name {
    /// HUD placement / always-visible preference changed (Settings picker or
    /// the HUD's own context menu). AppDelegate re-applies panel preferences;
    /// SettingsModel re-reads the config so an open Settings window stays live.
    static let veloraHUDPrefsChanged = Notification.Name("VeloraHUDPrefsChanged")
}

/// Owns the HUD's NSPanel and drives state transitions on the model.
///
/// Panel configuration follows the design brief §1.2 / spike findings:
/// borderless non-activating panel at `.statusBar` level that joins all
/// Spaces and never takes focus. The capsule itself is interactive: click
/// toggles dictation, right-click opens quick actions, drag repositions;
/// the transparent panel margins stay click-through.
final class HUDPanel: NSObject {
    /// Widest capsule plus room for the shadow and entrance offset.
    static let panelSize = NSSize(width: 480, height: 160)

    /// Everything the HUD's click/menu surface needs from the app. Wired by
    /// AppDelegate once the modules exist.
    struct MenuHooks {
        var isRecording: () -> Bool
        var recents: () -> [DictationRecord]
        var toggleDictation: () -> Void
        var insertAgain: (DictationRecord) -> Void
        var openHistory: () -> Void
        var openSettings: () -> Void
    }

    let model = HUDModel()

    /// Left-click on the capsule (start/stop dictation). Wired by AppDelegate.
    var onTap: (() -> Void)?
    var menuHooks: MenuHooks?

    private let panel: NSPanel
    private var hideWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    /// Set when a placement/visibility preference changes while a session is
    /// on screen — moving the capsule mid-recording would yank it out from
    /// under the user's eyes. Applied when the HUD settles back to idle.
    private var needsPrefsReapply = false

    override init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the capsule draws its own animated shadow
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        // Click vs. drag is disambiguated manually in HUDHostingView (a tap
        // toggles dictation; a real drag calls performDrag), so AppKit's
        // whole-background dragging stays off.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = HUDHostingView(rootView: HUDView(model: model))
        hosting.capsuleHitRect = { [weak self] in self?.currentHitRect() ?? .zero }
        // The error state hosts a real SwiftUI Retry button — let SwiftUI own
        // the mouse there instead of the tap/drag interceptor.
        hosting.wantsNativeMouse = { [weak self] in
            if case .error = self?.model.state { return true }
            return false
        }
        hosting.onTap = { [weak self] in self?.onTap?() }
        hosting.onDragEnded = { [weak self] in self?.finalizeUserDrag() }
        hosting.menuProvider = { [weak self] in self?.buildContextMenu() }
        panel.contentView = hosting

        model.edge = HUDEdge.edge(
            for: AppConfig.shared.hudPosition, custom: AppConfig.shared.hudCustomEdge)

        // A persistent pill never re-shows, so it must re-anchor itself when
        // displays change (undock, resolution switch) — the transient HUD used
        // to self-heal on every show.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            if self.model.state == .standby {
                self.position()
            } else if !self.model.state.isHidden {
                self.needsPrefsReapply = true
            }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// Called by the hosting view when a user drag of the capsule finishes
    /// (`performDrag` returned). Re-anchors the capsule to the screen edge it
    /// was dropped near — so later width changes grow toward open space, never
    /// off-screen — and persists the spot (plus its anchor) as Custom.
    private func finalizeUserDrag() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let size = HUDView.capsuleMetrics(for: model.state, context: model.sessionContext).size
        let capsule = NSRect(
            x: panel.frame.minX + Self.capsuleMinX(edge: model.edge, capsuleWidth: size.width),
            y: panel.frame.midY - size.height / 2,
            width: size.width, height: size.height)

        let visible = screen.visibleFrame
        let anchor = Self.customAnchor(capsule: capsule, visible: visible)
        panel.setFrameOrigin(anchor.panelOrigin)
        model.edge = anchor.edge

        AppConfig.shared.hudCustomOrigin = Self.customFraction(
            panelOrigin: anchor.panelOrigin, edge: anchor.edge, visible: visible)
        AppConfig.shared.hudCustomEdge = anchor.edge
        AppConfig.shared.hudPosition = .custom
        NotificationCenter.default.post(name: .veloraHUDPrefsChanged, object: nil)
    }

    /// The persisted form of a custom spot: the standby pill's CENTER as a
    /// fraction (0…1) of the visible frame. The pill center is used — not the
    /// panel origin, which legitimately overhangs the screen by a fixed point
    /// amount — because a fixed overhang stored as a fraction would scale on a
    /// different-sized display and push the capsule off-screen (review
    /// finding). A center fraction restores on-screen on any display.
    static func customFraction(
        panelOrigin: NSPoint, edge: HUDEdge, visible: NSRect
    ) -> CGPoint {
        let pill = HUDGeometry.standbySize
        let midX = panelOrigin.x + capsuleMinX(edge: edge, capsuleWidth: pill.width)
            + pill.width / 2
        let midY = panelOrigin.y + panelSize.height / 2
        return CGPoint(
            x: min(max((midX - visible.minX) / max(1, visible.width), 0), 1),
            y: min(max((midY - visible.minY) / max(1, visible.height), 0), 1))
    }

    /// Rebuilds the pill rect a stored fraction describes on `visible`. Feed
    /// it back through `customAnchor` to place the panel — that re-derives the
    /// growth anchor and re-clamps for THIS screen, so a spot saved on one
    /// display can never restore off-screen on another.
    static func customPillRect(fraction: CGPoint, visible: NSRect) -> NSRect {
        let pill = HUDGeometry.standbySize
        return NSRect(
            x: visible.minX + fraction.x * visible.width - pill.width / 2,
            y: visible.minY + fraction.y * visible.height - pill.height / 2,
            width: pill.width, height: pill.height)
    }

    /// Where a dragged pill settles: the growth anchor and panel origin for a
    /// capsule dropped at `capsule` (screen coordinates). Pure geometry so the
    /// selftest can pin it.
    ///
    /// The anchor is chosen so the widest session capsule
    /// (`maxListeningWidth`) can grow from the drop point without leaving the
    /// visible frame — near the right edge it grows leftward, and vice versa.
    /// The drop is clamped so the pill itself (and the full-height capsule)
    /// stays on screen; the capsule does not move otherwise.
    static func customAnchor(
        capsule: NSRect, visible: NSRect
    ) -> (edge: HUDEdge, panelOrigin: NSPoint) {
        let inset = VeloraSpacing.xl
        let halfMax = HUDGeometry.maxListeningWidth / 2
        let roomLeft = capsule.midX - visible.minX
        let roomRight = visible.maxX - capsule.midX

        let edge: HUDEdge
        if roomRight < halfMax + inset, roomLeft < halfMax + inset {
            edge = roomLeft < roomRight ? .leading : .trailing  // tiny screen
        } else if roomRight < halfMax + inset {
            edge = .trailing
        } else if roomLeft < halfMax + inset {
            edge = .leading
        } else {
            edge = .center
        }

        // Panel x per anchor. Edge anchors keep the capsule's screen-side edge
        // `panelEdgePadding` from the screen edge at the closest drop, which
        // puts the panel exactly flush with the visible frame.
        let panelX: CGFloat
        switch edge {
        case .trailing:
            let maxX = min(
                max(capsule.maxX, visible.minX + inset + capsule.width),
                visible.maxX - HUDGeometry.panelEdgePadding)
            panelX = maxX + HUDGeometry.panelEdgePadding - panelSize.width
        case .leading:
            let minX = min(
                max(capsule.minX, visible.minX + HUDGeometry.panelEdgePadding),
                visible.maxX - inset - capsule.width)
            panelX = minX - HUDGeometry.panelEdgePadding
        case .center:
            let midX = min(
                max(capsule.midX, visible.minX + inset + halfMax),
                visible.maxX - inset - halfMax)
            panelX = midX - panelSize.width / 2
        }

        // Vertically the capsule is centered in the panel; clamp so the
        // full-height (session) capsule stays inside the visible frame.
        let halfHeight = HUDGeometry.height / 2
        let midY = min(
            max(capsule.midY, visible.minY + inset + halfHeight),
            visible.maxY - inset - halfHeight)
        return (edge, NSPoint(x: panelX, y: midY - panelSize.height / 2))
    }

    /// Leading x of the capsule inside the panel for an edge anchor.
    static func capsuleMinX(edge: HUDEdge, capsuleWidth: CGFloat) -> CGFloat {
        switch edge {
        case .leading:
            return HUDGeometry.panelEdgePadding
        case .center:
            return (panelSize.width - capsuleWidth) / 2
        case .trailing:
            return panelSize.width - HUDGeometry.panelEdgePadding - capsuleWidth
        }
    }

    /// Re-reads the position + always-visible preferences and applies them:
    /// shows/hides the standby pill and repositions it while idle. While a
    /// session is on screen the change is deferred — moving or re-anchoring
    /// the capsule mid-recording would jump it to a spot that matches no
    /// preset (the panel itself can't be safely moved while visible).
    func applyPreferences() {
        guard model.state.isAvailable || !panel.isVisible else {
            needsPrefsReapply = true
            return
        }
        needsPrefsReapply = false
        model.edge = HUDEdge.edge(
            for: AppConfig.shared.hudPosition, custom: AppConfig.shared.hudCustomEdge)
        if AppConfig.shared.hudAlwaysVisible {
            if model.state.isHidden {
                transition(to: .standby)
            } else if model.state == .standby {
                position()
            }
        } else if model.state == .standby {
            transition(to: .hidden(.cancel))
        }
    }

    /// Moves the HUD to a new state, showing/hiding the panel as needed.
    /// Never repositions while a session is visible. When the standby pill is
    /// enabled, "hidden" resolves to the pill instead of ordering out.
    func transition(to newState: HUDState) {
        let target: HUDState = (newState.isHidden && AppConfig.shared.hudAlwaysVisible)
            ? .standby
            : newState

        hideWorkItem?.cancel()
        hideWorkItem = nil

        if !target.isHidden {
            if model.state.isHidden || !panel.isVisible {
                position()
            }
            panel.orderFrontRegardless()  // shows without activating Velora
        }

        model.state = target

        if target.isHidden {
            // Keep the panel on screen long enough for the exit animation.
            let item = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }

        // A placement change made mid-session applies once the HUD settles.
        if needsPrefsReapply, target.isAvailable {
            applyPreferences()
        }
    }

    /// Places the panel per the position preference; capsule edges keep a
    /// 20 pt inset from the visible frame (above the Dock / below the menubar,
    /// clear of screen corners).
    private func position() {
        // A dragged spot belongs to the screen the pill was dropped on, so
        // custom positions restore against the panel's own screen — restoring
        // against NSScreen.main teleported the pill to whichever display held
        // key focus (review finding). Presets keep following the main screen.
        let isCustom = AppConfig.shared.hudPosition == .custom
        guard let screen = (isCustom ? panel.screen : nil)
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let inset = VeloraSpacing.xl
        let centerX = visible.midX - Self.panelSize.width / 2
        // The capsule is centered vertically in the panel; corner presets
        // account for the horizontal padding between capsule and panel edge.
        let capsuleInset = (Self.panelSize.height - HUDGeometry.height) / 2
        let leftX = visible.minX + inset - HUDGeometry.panelEdgePadding
        let rightX = visible.maxX - inset + HUDGeometry.panelEdgePadding - Self.panelSize.width
        let bottomY = visible.minY + inset - capsuleInset
        let topY = visible.maxY - inset - HUDGeometry.height - capsuleInset

        let origin: NSPoint
        switch AppConfig.shared.hudPosition {
        case .bottomCenter:
            origin = NSPoint(x: centerX, y: bottomY)
        case .bottomLeft:
            origin = NSPoint(x: leftX, y: bottomY)
        case .bottomRight:
            origin = NSPoint(x: rightX, y: bottomY)
        case .topCenter:
            origin = NSPoint(x: centerX, y: topY)
        case .topLeft:
            origin = NSPoint(x: leftX, y: topY)
        case .topRight:
            origin = NSPoint(x: rightX, y: topY)
        case .custom:
            if let frac = AppConfig.shared.hudCustomOrigin {
                let anchor = Self.customAnchor(
                    capsule: Self.customPillRect(fraction: frac, visible: visible),
                    visible: visible)
                // The re-derived anchor is authoritative for this screen (the
                // drop screen may have been a different size or shape).
                model.edge = anchor.edge
                AppConfig.shared.hudCustomEdge = anchor.edge
                origin = anchor.panelOrigin
            } else {  // custom with no stored origin yet → bottom center
                origin = NSPoint(x: centerX, y: bottomY)
            }
        }
        panel.setFrameOrigin(origin)
        veloraLog(String(
            format: "Velora: HUD position=%@ origin=(%.0f, %.0f) frame=%@",
            AppConfig.shared.hudPosition.rawValue, origin.x, origin.y,
            NSStringFromRect(panel.frame)))
    }

    // MARK: - Hit testing

    private func currentHitRect() -> NSRect {
        Self.hitRect(for: model.state, edge: model.edge, context: model.sessionContext)
    }

    /// The capsule's interactive footprint inside the panel for a state —
    /// sized from the state's ACTUAL capsule geometry plus a small grace
    /// margin. An oversized rect is an invisible click-to-record strip over
    /// the frontmost app (the `.inserted` circle is 56 pt, not 420).
    static func hitRect(
        for state: HUDState, edge: HUDEdge, context: HUDSessionContext?
    ) -> NSRect {
        if state.isHidden { return .zero }
        let capsule = HUDView.capsuleMetrics(for: state, context: context).size
        let width = capsule.width + VeloraSpacing.s
        let height = capsule.height + VeloraSpacing.m
        let x = capsuleMinX(edge: edge, capsuleWidth: capsule.width) - VeloraSpacing.xs
        let y = (panelSize.height - height) / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let recording = menuHooks?.isRecording() ?? false
        let toggleTitle = recording ? "Stop Dictation" : "Start Dictation"
        let toggle = NSMenuItem(
            title: toggleTitle, action: #selector(menuToggleDictation), keyEquivalent: "")
        toggle.target = self
        toggle.attributedTitle = NSAttributedString(
            string: toggleTitle,
            attributes: [.font: NSFont.systemFont(
                ofSize: NSFont.systemFontSize(for: .regular), weight: .semibold)])
        menu.addItem(toggle)

        let recents = (menuHooks?.recents() ?? []).filter {
            !$0.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !recents.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for record in recents.prefix(5) {
                let item = NSMenuItem(
                    title: Self.truncate(record.final, to: 46), action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                item.toolTip = record.final

                let submenu = NSMenu()
                let copy = NSMenuItem(
                    title: "Copy", action: #selector(copyRecent(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = RecordBox(record)
                submenu.addItem(copy)
                let insert = NSMenuItem(
                    title: "Insert Again", action: #selector(insertRecent(_:)), keyEquivalent: "")
                insert.target = self
                insert.representedObject = RecordBox(record)
                submenu.addItem(insert)
                item.submenu = submenu
                menu.addItem(item)
            }
            let edit = NSMenuItem(
                title: "Edit in History…", action: #selector(openHistoryAction),
                keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
        }

        menu.addItem(.separator())

        let position = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        let current = AppConfig.shared.hudPosition
        for preset in HUDPosition.presets {
            let item = NSMenuItem(
                title: preset.displayName, action: #selector(selectPosition(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = current == preset ? .on : .off
            positionMenu.addItem(item)
        }
        if current == .custom {
            positionMenu.addItem(.separator())
            let custom = NSMenuItem(
                title: HUDPosition.custom.displayName, action: nil, keyEquivalent: "")
            custom.isEnabled = false
            custom.state = .on
            positionMenu.addItem(custom)
        }
        position.submenu = positionMenu
        menu.addItem(position)

        let keep = NSMenuItem(
            title: "Keep on Screen When Idle", action: #selector(toggleAlwaysVisible),
            keyEquivalent: "")
        keep.target = self
        keep.state = AppConfig.shared.hudAlwaysVisible ? .on : .off
        menu.addItem(keep)

        menu.addItem(.separator())

        let history = NSMenuItem(
            title: "History…", action: #selector(openHistoryAction), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        return menu
    }

    /// NSMenuItem.representedObject needs a class; DictationRecord is a struct.
    private final class RecordBox: NSObject {
        let record: DictationRecord
        init(_ record: DictationRecord) { self.record = record }
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    @objc private func menuToggleDictation() {
        menuHooks?.toggleDictation()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecordBox else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(box.record.final, forType: .string)
    }

    @objc private func insertRecent(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? RecordBox else { return }
        menuHooks?.insertAgain(box.record)
    }

    @objc private func openHistoryAction() {
        menuHooks?.openHistory()
    }

    @objc private func openSettingsAction() {
        menuHooks?.openSettings()
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = HUDPosition(rawValue: raw) else { return }
        AppConfig.shared.hudPosition = preset
        NotificationCenter.default.post(name: .veloraHUDPrefsChanged, object: nil)
    }

    @objc private func toggleAlwaysVisible() {
        AppConfig.shared.hudAlwaysVisible.toggle()
        NotificationCenter.default.post(name: .veloraHUDPrefsChanged, object: nil)
    }
}

/// Hosting view that is transparent to the mouse everywhere except the capsule
/// and disambiguates click (toggle dictation), drag (move the pill), and
/// right-click (quick-actions menu). The empty panel margins pass clicks
/// straight through to whatever is underneath.
private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    /// Current interactive capsule footprint (state-dependent).
    var capsuleHitRect: (() -> NSRect)?
    /// True when SwiftUI should own mouse events (error state's Retry button).
    var wantsNativeMouse: (() -> Bool)?
    var onTap: (() -> Void)?
    /// Fires once when a capsule drag finishes (`performDrag` returned).
    var onDragEnded: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var pressStart: NSPoint?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }

    /// The pill must react to the first click even though the panel never
    /// becomes key (it's a non-activating overlay).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let capsule = capsuleHitRect?() ?? .zero
        return capsule.contains(point) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        if wantsNativeMouse?() == true {
            super.mouseDown(with: event)
            return
        }
        pressStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        if wantsNativeMouse?() == true {
            super.mouseDragged(with: event)
            return
        }
        guard let start = pressStart, !didDrag else { return }
        let location = event.locationInWindow
        // A 3 pt slop keeps shaky clicks from turning into drags.
        if hypot(location.x - start.x, location.y - start.y) > 3 {
            didDrag = true
            // performDrag runs the whole drag session synchronously; when it
            // returns, the capsule is at its new home.
            window?.performDrag(with: event)
            onDragEnded?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if wantsNativeMouse?() == true {
            super.mouseUp(with: event)
            return
        }
        if pressStart != nil, !didDrag, event.clickCount == 1 {
            onTap?()
        }
        pressStart = nil
        didDrag = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
