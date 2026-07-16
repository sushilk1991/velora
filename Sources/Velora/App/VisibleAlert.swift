import AppKit

/// Non-blocking, visibility-hardened NSAlert presenter for an LSUIElement app.
/// `runModal()` can strand the main thread before a menu-bar app's first window
/// is registered with WindowServer. Ordering the alert normally keeps the run
/// loop live and makes consent inspectable by both the user and Accessibility.
enum VisibleAlert {
    private static var active: AlertSession?
    private struct PendingAlert {
        let token: UUID
        let alert: NSAlert
        let completion: (NSApplication.ModalResponse) -> Void
    }
    private static var pending: [PendingAlert] = []

    @discardableResult
    static func present(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) -> UUID {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = UUID()
        guard active == nil else {
            pending.append(PendingAlert(token: token, alert: alert, completion: completion))
            return token
        }
        let session = AlertSession(token: token, alert: alert, completion: completion) {
            active = nil
            if !pending.isEmpty {
                let next = pending.removeFirst()
                show(next)
            }
        }
        active = session
        session.show()
        return token
    }

    static func dismiss(_ token: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        if active?.token == token {
            active?.cancel()
            return
        }
        guard let index = pending.firstIndex(where: { $0.token == token }) else { return }
        let item = pending.remove(at: index)
        item.completion(.cancel)
    }

    private static func show(_ item: PendingAlert) {
        let session = AlertSession(
            token: item.token, alert: item.alert, completion: item.completion
        ) {
            active = nil
            if !pending.isEmpty { show(pending.removeFirst()) }
        }
        active = session
        session.show()
    }
}

private final class AlertSession: NSObject, NSWindowDelegate {
    let token: UUID
    private let alert: NSAlert
    private let completion: (NSApplication.ModalResponse) -> Void
    private let onFinish: () -> Void
    private var priorPolicy: NSApplication.ActivationPolicy = .accessory
    private var finished = false

    init(
        token: UUID,
        alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.token = token
        self.alert = alert
        self.completion = completion
        self.onFinish = onFinish
    }

    func show() {
        priorPolicy = NSApp.activationPolicy()
        let changedPolicy = priorPolicy == .regular || NSApp.setActivationPolicy(.regular)
        alert.layout()
        let window = alert.window
        window.delegate = self
        window.level = .modalPanel
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }
        // `makeKeyAndOrderFront` alone can be ignored for an LSUIElement app
        // that has never owned a visible window. Ordering regardless first
        // registers it with WindowServer; activation then gives it keyboard
        // focus without starting a nested modal run loop.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        veloraLog(
            "Velora: presenting explicit consent alert "
            + "policy=\(NSApp.activationPolicy().rawValue) changed=\(changedPolicy) "
            + "visible=\(window.isVisible)")
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        let raw = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag
        finish(NSApplication.ModalResponse(rawValue: raw))
    }

    func cancel() {
        finish(.cancel)
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        let raw = alert.buttons.count > 1
            ? NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
            : NSApplication.ModalResponse.cancel.rawValue
        finish(NSApplication.ModalResponse(rawValue: raw))
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard !finished else { return }
        finished = true
        alert.window.orderOut(nil)
        alert.window.delegate = nil
        if priorPolicy != .regular { NSApp.setActivationPolicy(priorPolicy) }
        veloraLog("Velora: consent alert response=\(response.rawValue)")
        completion(response)
        onFinish()
    }
}
