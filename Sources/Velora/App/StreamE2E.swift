import AppKit
import ApplicationServices

/// Headless end-to-end probe for Stream Typing against a **real** app window.
///
/// Stream Typing cannot be exercised by the pure-logic selftest: everything
/// that decides whether a draft survives — the Accessibility selected range,
/// whether the caret lands where AX says it does, whether the app reports the
/// text back through `AXStringForRange` — is a property of the target app, not
/// of Velora's code. This driver feeds a scripted partial sequence through the
/// same `StreamTypingSession` the app uses and reports, after every revision,
/// exactly what the target reported back.
///
/// `.build/release/Velora --stream-e2e [AppName|front] [--keep]`
///
/// Needs Accessibility, so run the copy that holds the grant (the installed
/// bundle, or a dev-signed build). Nothing here is reachable from the GUI or
/// the `velora` CLI.
enum StreamE2E {
    private static let probeMarker = "VELORA-STREAM-E2E"

    /// A realistic progression: Whisper revises its own hypothesis, cleanup
    /// swaps a stable prefix for a polished one, and the tail keeps moving.
    /// The last entry is the authoritative final.
    private static let partials = [
        "Just testing whether",
        "Just testing whether it streams",
        "Just testing whether it streams my content or not",
        "Just testing whether it streams my content or not. So yeah,",
        "Just testing whether it streams my content or not. So yeah, I am confused.",
    ]

    static func run(arguments: [String]) -> Int32 {
        let options = arguments.filter { $0.hasPrefix("--") }
        let positional = arguments.filter { !$0.hasPrefix("--") }
        let requested = positional.first ?? "TextEdit"
        let keepDocument = options.contains("--keep")
        // Read-only: capture and describe the target without typing a thing.
        let dryRun = options.contains("--dry-run")
        // Type the partials, then cancel instead of committing, so the field is
        // left exactly as it was found. Safe against a real app the user owns.
        let revert = options.contains("--revert")

        // `front` types into whatever the user has open. Make the caller say
        // out loud whether the probe may leave its text behind — the scratch
        // document cleanup only exists for the launch-an-app path.
        if requested.lowercased() == "front", !dryRun, !revert, !keepDocument {
            print("FAIL: `front` types five partials into the focused field of")
            print("      a real app. Pass --revert to restore it afterwards,")
            print("      --keep to accept the text, or --dry-run to look only.")
            return 2
        }

        guard AXIsProcessTrusted() else {
            print("FAIL: this binary does not hold Accessibility access.")
            print("      Run the copy that has the grant, or approve it in")
            print("      System Settings → Privacy & Security → Accessibility.")
            return 2
        }

        guard let app = focusTarget(requested) else {
            print("FAIL: could not bring '\(requested)' to the front.")
            return 2
        }
        print("target app: \(app.localizedName ?? "?") "
            + "(\(app.bundleIdentifier ?? "no bundle id"))")

        // Report every route the real hotkey path would consider, so a failure
        // to capture is distinguishable from a failure to type.
        let nativeTarget = ScreenContext.streamTarget(of: app)
        let keystrokeTarget = nativeTarget == nil
            ? ScreenContext.keystrokeStreamTarget(of: app) : nil
        let previewTarget = nativeTarget == nil && keystrokeTarget == nil
            ? ScreenContext.streamPreviewTarget(of: app) : nil
        let route = StreamTargetRouting.route(
            bundleID: app.bundleIdentifier,
            nativeTargetAvailable: nativeTarget != nil,
            keystrokeTargetAvailable: keystrokeTarget != nil,
            previewTargetAvailable: previewTarget != nil)
        print("route: \(route)")

        guard let target = nativeTarget else {
            // Never exit 0 having tested nothing. This probe exists to exercise
            // the .accessibility route; "I did not run the code under test" is
            // a failure to report, not a pass.
            print("FAIL: no accessibility stream target here (route: \(route)) —")
            print("      this probe only covers the .accessibility route, so")
            print("      nothing was typed and nothing was proven.")
            return 2
        }
        print("captured: location=\(target.location) "
            + "originalText=\(quoted(target.originalText)) "
            + "boundary=\(target.boundary.map { "before=\(quoted($0.before)) after=\(quoted($0.after))" } ?? "nil")")
        print("element:  role=\(axAttribute(target.element, kAXRoleAttribute)) "
            + "subrole=\(axAttribute(target.element, kAXSubroleAttribute)) "
            + "valueSettable=\(isSettable(target.element, kAXValueAttribute)) "
            + "rangeSettable=\(isSettable(target.element, kAXSelectedTextRangeAttribute))")
        print("reads:    value=\(quoted(fieldValue(target.element) ?? "<unreadable>")) "
            + "\(describeSelection(target.element)) "
            + "stringForRange(0,4)=\(stringForRange(target.element, location: 0, length: 4).map(quoted) ?? "<unreadable>")")

        if dryRun {
            print("")
            print("dry run — nothing was typed.")
            if !keepDocument { cleanUpProbeDocument(app: app) }
            return 0
        }

        let session = StreamTypingSession(target: target)
        var failures: [String] = []

        for (index, partial) in partials.enumerated() {
            let isFinal = index == partials.count - 1 && !revert
            let label = index == partials.count - 1 ? "final" : "partial \(index + 1)"
            var finishResult: StreamTypingSession.FinishResult?

            if isFinal {
                session.finish(partial, mode: nil) { finishResult = $0 }
                waitOnMainQueue(until: { finishResult != nil }, seconds: 8)
            } else {
                session.update(partial, mode: nil)
                // The session settles a revision 60 ms after typing; give it a
                // beat plus the target app's own event-loop turn.
                waitOnMainQueue(until: { session.hasRenderedDraft }, seconds: 3)
                waitOnMainQueue(until: { false }, seconds: 0.35)
            }

            let owns = ScreenContext.streamOwnsDraft(
                deliveredText(partial, target: target), target: target)
            let onScreen = fieldValue(target.element) ?? "<unreadable>"
            print("\(label): rendered=\(session.hasRenderedDraft) "
                + "ownsDraft=\(owns) "
                + (finishResult.map { "finish=\($0) " } ?? "")
                + "\(describeSelection(target.element)) "
                + "own=[\(ScreenContext.streamDraftOwnershipDiagnosis(deliveredText(partial, target: target), target: target))] "
                + "field=\(quoted(onScreen))")

            // Assert on the FIELD, not on `hasRenderedDraft`: that flag stays
            // true after the session abandons (`plan.rendered` is never
            // cleared), so it would have gone green for exactly the Chromium
            // regression this probe exists to catch. What matters is that each
            // revision actually reached the document.
            let delivered = deliveredText(partial, target: target)
            if !onScreen.contains(delivered) {
                failures.append("\(label): the revision never reached the field")
            }
            if !isFinal, !session.hasRenderedDraft {
                failures.append("\(label): the session stopped owning a draft")
            }
            if let finishResult, finishResult != .applied {
                failures.append("final: finish returned .\(finishResult) — "
                    + "the polished text was never inserted")
            }
        }

        if revert {
            var cancellation: StreamTypingSession.CancellationResult?
            session.cancel { cancellation = $0 }
            waitOnMainQueue(until: { cancellation != nil }, seconds: 8)
            print("revert: \(cancellation.map { "\($0)" } ?? "timed out")")
            print("field after revert: \(quoted(fieldValue(target.element) ?? ""))")
            if cancellation != .restored, cancellation != .noDraft {
                failures.append("revert: the probe could not restore the field "
                    + "(left \(quoted(fieldValue(target.element) ?? ""))) ")
            }
            if !keepDocument { cleanUpProbeDocument(app: app) }
            guard failures.isEmpty else {
                print("")
                for failure in failures { print("FAIL: \(failure)") }
                return 1
            }
            print("PASS: revert probe completed without leaving text behind.")
            return 0
        }

        let expected = partials[partials.count - 1]
        let actual = fieldValue(target.element) ?? ""
        let landed = actual.contains(expected)
        if !landed {
            failures.append("final text is not in the field")
        }

        print("")
        print("expected in field: \(quoted(expected))")
        print("actual field:      \(quoted(actual))")

        if !keepDocument { cleanUpProbeDocument(app: app) }

        guard failures.isEmpty else {
            print("")
            for failure in failures { print("FAIL: \(failure)") }
            return 1
        }
        print("PASS: the full final text landed in \(app.localizedName ?? "the app").")
        return 0
    }

    // MARK: - Target setup

    private static func focusTarget(_ requested: String) -> NSRunningApplication? {
        if requested.lowercased() == "front" {
            print("using the frontmost app in 3s — focus a text field now")
            waitOnMainQueue(until: { false }, seconds: 3)
            return NSWorkspace.shared.frontmostApplication
        }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID(forAppNamed: requested))
            ?? applicationURL(named: requested)
        else { return nil }

        // A scratch document guarantees an empty, focused text area — probing
        // whatever the user happens to have open would type into their work.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(probeMarker).txt")
        try? "".write(to: scratch, atomically: true, encoding: .utf8)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let done = DispatchSemaphore(value: 0)
        var opened: NSRunningApplication?
        NSWorkspace.shared.open([scratch], withApplicationAt: url,
                                configuration: configuration) { app, _ in
            opened = app
            done.signal()
        }
        _ = done.wait(timeout: .now() + 20)

        // Frontmost lags the launch callback; the AX tree lags frontmost.
        waitOnMainQueue(
            until: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == opened?.bundleIdentifier
            },
            seconds: 10)
        waitOnMainQueue(until: { false }, seconds: 1.2)
        return opened.flatMap {
            NSRunningApplication(processIdentifier: $0.processIdentifier)
        }
    }

    private static func applicationURL(named name: String) -> URL? {
        let candidates = ["/System/Applications", "/Applications"]
        for directory in candidates {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func bundleID(forAppNamed name: String) -> String {
        switch name.lowercased() {
        case "textedit": return "com.apple.TextEdit"
        case "notes": return "com.apple.Notes"
        default: return name
        }
    }

    /// Leaves the user's Mac as it was found: the scratch document is closed
    /// without saving and removed.
    private static func cleanUpProbeDocument(app: NSRunningApplication) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(probeMarker).txt")
        guard FileManager.default.fileExists(atPath: scratch.path) else { return }
        let script = """
            tell application id "\(app.bundleIdentifier ?? "")"
                try
                    close (every document whose name contains "\(probeMarker)") \
            saving no
                end try
            end tell
            """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Reads

    private static func fieldValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// What the session actually types: the boundary adjustment (a leading
    /// space next to an existing word) is part of the draft it must own.
    private static func deliveredText(
        _ text: String, target: ScreenStreamTarget
    ) -> String {
        TextInsertionBoundary.adjusted(text, boundary: target.boundary, mode: nil)
    }

    private static func axAttribute(
        _ element: AXUIElement, _ attribute: String
    ) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value) == .success
        else { return "<none>" }
        return (value as? String) ?? "<non-string>"
    }

    private static func isSettable(
        _ element: AXUIElement, _ attribute: String
    ) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    /// The selected range exactly as the target app reports it — the value
    /// `streamOwnsDraft` compares against, and the usual thing an Electron or
    /// web-backed field gets wrong.
    private static func describeSelection(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString,
                &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID()
        else { return "selRange=<unreadable>" }
        var range = CFRange()
        guard AXValueGetValue(
            raw as! AXValue, .cfRange, &range) else { return "selRange=<bad>" }
        return "selRange=(\(range.location),\(range.length))"
    }

    private static func stringForRange(
        _ element: AXUIElement, location: Int, length: Int
    ) -> String? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\n", with: "\\n"))\""
    }

    /// Drives the main run loop so the session's `DispatchQueue.main` hops and
    /// the target app's AX replies both make progress.
    private static func waitOnMainQueue(
        until condition: () -> Bool, seconds: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
