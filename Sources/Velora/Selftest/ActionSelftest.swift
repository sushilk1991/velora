import AppKit
import ApplicationServices
import Foundation

/// Scripted stand-in for the machine, so the executor's safety logic can be
/// exercised without touching real apps.
final class FakeActionHost: ActionHost {
    /// Frontmost app after each `openApp`, keyed by the requested name.
    var appsByName: [String: (name: String, bundleID: String)] = [:]
    var frontmost: (name: String, bundleID: String)?
    var windowTitle: String?
    var elementLabel: String?
    /// The highlighted row of a quick switcher, as the app labels it.
    var selectionLabel: String?
    var canPostInput = true
    var screenIsLocked = false
    var typingSucceeds = true
    var keyPressSucceeds = true
    var openURLSucceeds = true
    /// Set to make `frontmostApp()` change after N reads (focus stolen).
    var frontmostAfterReads: (reads: Int, value: (name: String, bundleID: String)?)?

    /// Fires after each host call, so a test can change the world mid-plan.
    var onStep: ((String) -> Void)?

    private(set) var log: [String] = []
    private(set) var typed: [String] = []
    private(set) var keys: [(CGKeyCode, CGEventFlags)] = []
    private(set) var openedURLs: [URL] = []
    private var frontmostReads = 0
    private var clock: TimeInterval = 0

    func openApp(named name: String) -> String? {
        log.append("openApp(\(name))")
        guard let resolved = appsByName[name] else { return nil }
        frontmost = resolved
        return resolved.name
    }

    func openURL(_ url: URL) -> Bool {
        log.append("openURL(\(url.absoluteString))")
        openedURLs.append(url)
        return openURLSucceeds
    }

    func frontmostApp() -> (name: String, bundleID: String)? {
        frontmostReads += 1
        if let scheduled = frontmostAfterReads, frontmostReads > scheduled.reads {
            return scheduled.value
        }
        return frontmost
    }

    func frontmostWindowTitle() -> String? { windowTitle }
    func focusedElementLabel() -> String? { elementLabel }
    func focusedSelectionLabel() -> String? { selectionLabel }

    func typeText(_ text: String, expecting bundleID: String?) -> Bool {
        log.append("type(\(text))")
        typed.append(text)
        onStep?("type(\(text))")
        return typingSucceeds
    }

    func pasteText(_ text: String, expecting bundleID: String?) -> Bool {
        typeText(text, expecting: bundleID)
    }

    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags,
                  expecting bundleID: String?) -> Bool {
        log.append("key(\(keyCode))")
        keys.append((keyCode, flags))
        return keyPressSucceeds
    }

    func sleep(ms: Int) { clock += Double(ms) / 1000 }
    func now() -> TimeInterval { clock }
}

extension Selftest {

    // MARK: - Suite entry point

    static func testActionMode() {
        // Guard the shared fixtures FIRST. Each rail below does
        // `guard let plan = decodePlan(...) else { expect(false); return }`, so
        // one stale fixture used to turn ~25 executor assertions dark while the
        // report showed a handful of failures — the worst shape a safety suite
        // can take. If the fixtures stop decoding, say so once, loudly.
        expect(decodePlan(slackPlanJSON)?.steps.count == 11,
               "FIXTURE: the Slack plan decodes to 11 steps — the executor rails "
                   + "below are skipped if it does not")
        expect(decodePlan(slackDraftPlanJSON)?.steps.count == 9,
               "FIXTURE: the draft plan decodes to 9 steps")
        testActionPlanDecoding()
        testActionPlanRejectsUnsafePlans()
        testActionKeyVocabulary()
        testAppMatching()
        testActionExecutorHappyPath()
        testActionExecutorSafetyRails()
        testSecondaryHotkeyRouting()
        testActionShortcutSettingsMigration()
        testActionCLIParsing()
    }

    // MARK: - Hotkey routing

    /// Action Mode added a third hotkey, which turned the monitor's one
    /// hard-coded "edit" slot into a role table. These cover the routing that
    /// refactor introduced — a chord must reach exactly one feature.
    private static func testSecondaryHotkeyRouting() {
        let monitor = HotkeyMonitor()
        let probe = HotkeySelftestDelegate()
        monitor.delegate = probe
        monitor.hotkey = .rightOption
        monitor.secondaryHotkeys = [.edit: .optionShiftE, .action: .optionShiftA]

        // ⌥⇧A reaches Action Mode, and only Action Mode.
        expect(monitor.handleKeyDown(keyCode: 0, flags: Hotkey.optionShiftA.modifiers,
                                     isRepeat: false, invalidateContinuation: false),
               "the action combo is suppressed by a filtering tap")
        expect(waitUntil { probe.actionHotkeyDownCount == 1 },
               "the action hotkey callback is delivered")
        expect(probe.editHotkeyDownCount == 0, "the action combo never fires Voice Edit")
        expect(monitor.handleKeyUp(keyCode: 0), "the action key-up is suppressed")
        expect(waitUntil { probe.actionHotkeyUpCount == 1 }, "the action key-up is delivered")

        // ⌥⇧E still reaches Voice Edit after the refactor.
        expect(monitor.handleKeyDown(keyCode: 14, flags: Hotkey.optionShiftE.modifiers,
                                     isRepeat: false, invalidateContinuation: false),
               "the edit combo is still suppressed")
        expect(waitUntil { probe.editHotkeyDownCount == 1 },
               "the edit hotkey still works alongside Action Mode")
        expect(probe.actionHotkeyDownCount == 1, "the edit combo never fires Action Mode")
        _ = monitor.handleKeyUp(keyCode: 14)
        expect(waitUntil { probe.editHotkeyUpCount == 1 }, "the edit key-up is delivered")

        // Two roles on one chord resolve deterministically to the first role,
        // rather than firing both features from a single keypress.
        let collided = HotkeyMonitor()
        let collidedProbe = HotkeySelftestDelegate()
        collided.delegate = collidedProbe
        collided.hotkey = .rightOption
        collided.secondaryHotkeys = [.edit: .optionShiftE, .action: .optionShiftE]
        _ = collided.handleKeyDown(keyCode: 14, flags: Hotkey.optionShiftE.modifiers,
                                   isRepeat: false, invalidateContinuation: false)
        expect(waitUntil { collidedProbe.editHotkeyDownCount == 1 },
               "a collided chord fires the first role")
        expect(collidedProbe.actionHotkeyDownCount == 0,
               "a collided chord never fires both features at once")
        _ = collided.handleKeyUp(keyCode: 14)

        // The dictation hotkey outranks a secondary bound to the same chord.
        let shadowed = HotkeyMonitor()
        let shadowedProbe = HotkeySelftestDelegate()
        shadowed.delegate = shadowedProbe
        shadowed.hotkey = .optionShiftA
        shadowed.secondaryHotkeys = [.action: .optionShiftA]
        _ = shadowed.handleKeyDown(keyCode: 0, flags: Hotkey.optionShiftA.modifiers,
                                   isRepeat: false, invalidateContinuation: false)
        expect(waitUntil { shadowedProbe.hotkeyDownCount == 1 },
               "dictation wins when a secondary shares its chord")
        expect(shadowedProbe.actionHotkeyDownCount == 0,
               "the shadowed secondary role stays silent")
        _ = shadowed.handleKeyUp(keyCode: 0)

        // Rebinding one role must not strand a hold in progress on another.
        let rebound = HotkeyMonitor()
        let reboundProbe = HotkeySelftestDelegate()
        rebound.delegate = reboundProbe
        rebound.hotkey = .rightOption
        rebound.secondaryHotkeys = [.edit: .optionShiftE, .action: .optionShiftA]
        _ = rebound.handleKeyDown(keyCode: 14, flags: Hotkey.optionShiftE.modifiers,
                                  isRepeat: false, invalidateContinuation: false)
        expect(waitUntil { reboundProbe.editHotkeyDownCount == 1 }, "the edit hold started")
        rebound.secondaryHotkeys = [.edit: .optionShiftE, .action: .f19]
        expect(rebound.handleKeyUp(keyCode: 14),
               "rebinding Action Mode does not strand an Edit hold mid-press")
        expect(waitUntil { reboundProbe.editHotkeyUpCount == 1 },
               "the stranded-hold guard delivers the edit key-up")
    }

    // MARK: - Settings migration

    private static func testActionShortcutSettingsMigration() {
        // Settings written before Action Mode have no `action` keys. Decoding
        // must fill defaults rather than fail and reset every other preference.
        let legacy = """
        {"dictation":{"keyCode":61,"modifiers":524288,"isModifierOnly":true},
         "editSelection":{"keyCode":14,"modifiers":655360,"isModifierOnly":false},
         "voiceEdit":true,"behavior":"hold"}
        """
        guard let data = legacy.data(using: .utf8),
              let shortcuts = try? JSONDecoder().decode(
                SettingsDocument.Shortcuts.self, from: data) else {
            expect(false, "a pre-Action settings file still decodes")
            return
        }
        expect(shortcuts.dictation == .rightOption, "the existing hotkey survives the upgrade")
        expect(shortcuts.voiceEdit, "the existing Voice Edit preference survives")
        expect(shortcuts.action == SettingsDocument.Shortcuts.defaultActionHotkey,
               "a missing action hotkey defaults to ⌥⇧A")
        expect(shortcuts.actionsEnabled, "Action Mode is on by default after an upgrade")

        // And a full round trip keeps a customized binding.
        var custom = SettingsDocument.Shortcuts.defaults
        custom.action = .f19
        custom.actionsEnabled = false
        guard let encoded = try? JSONEncoder().encode(custom),
              let decoded = try? JSONDecoder().decode(
                SettingsDocument.Shortcuts.self, from: encoded) else {
            expect(false, "shortcuts round-trip through JSON")
            return
        }
        expect(decoded == custom, "a customized action hotkey round-trips")
    }

    // MARK: - CLI / control surface

    private static func testActionCLIParsing() {
        func parse(_ argv: [String]) -> CLICommand? {
            try? CLIInvocation.parse(argv).command
        }
        expect(parse(["action", "open", "WhatsApp"])
               == .action(text: "open WhatsApp", execute: false, allowSend: false),
               "a bare action command plans without executing")
        expect(parse(["action", "open", "WhatsApp", "--execute"])
               == .action(text: "open WhatsApp", execute: true, allowSend: false),
               "--execute opts in to carrying the plan out, but not to sending")
        expect(parse(["action", "message Priya hi", "--allow-send"])
               == .action(text: "message Priya hi", execute: true, allowSend: true),
               "--allow-send is the separate, explicit consent to message someone")
        expect(parse(["action"]) == nil, "action without a command is rejected")
        expect(parse(["action", "--bogus", "x"]) == nil, "unknown options are rejected")

        // The router must refuse an over-long command and an absent capability.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-action-cli-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(url: directory.appendingPathComponent("history.sqlite3"))
        let router = LocalControlRouter(
            history: history, accessEnabled: { true }, engineReady: { true },
            typingWPM: { 40 })
        var response: ControlResponse?
        _ = router.handle(ControlRequest(
            id: "1", command: "action", arguments: ["text": "open Slack"])) {
                response = $0
            }
        expect(response?.failure?.code == "capability_unavailable",
               "action is refused when the app exposes no action capability")

        var executed: Bool?
        let live = LocalControlRouter(
            history: history, accessEnabled: { true }, engineReady: { true },
            typingWPM: { 40 },
            action: { arguments, completion in
                executed = arguments["execute"] as? Bool
                completion(.success(["ok": true]))
                return {}
            })
        _ = live.handle(ControlRequest(
            id: "2", command: "action", arguments: ["text": "open Slack"])) { _ in }
        expect(executed == false, "the router defaults to planning, never executing")
        var sendOK: Bool?
        let sendRouter = LocalControlRouter(
            history: history, accessEnabled: { true }, engineReady: { true },
            typingWPM: { 40 },
            action: { arguments, completion in
                sendOK = arguments["allow_send"] as? Bool
                completion(.success(["ok": true]))
                return {}
            })
        _ = sendRouter.handle(ControlRequest(
            id: "s1", command: "action",
            arguments: ["text": "message Priya", "execute": true])) { _ in }
        expect(sendOK == false,
               "executing does not by itself permit a plan that messages someone")
        _ = live.handle(ControlRequest(
            id: "3", command: "action",
            arguments: ["text": "open Slack", "execute": true])) { _ in }
        expect(executed == true, "an explicit execute flag reaches the app")

        var tooLong: ControlResponse?
        _ = live.handle(ControlRequest(
            id: "4", command: "action",
            arguments: ["text": String(repeating: "x",
                                       count: LocalControlRouter
                                           .maxActionCommandCharacters + 1)])) {
                tooLong = $0
            }
        expect(tooLong?.failure?.code == "invalid_arguments",
               "an over-long action command is rejected before it reaches the app")

        var denied: ControlResponse?
        let locked = LocalControlRouter(
            history: history, accessEnabled: { false }, engineReady: { true },
            typingWPM: { 40 },
            action: { _, completion in completion(.success(["ok": true])); return {} })
        _ = locked.handle(ControlRequest(
            id: "5", command: "action", arguments: ["text": "open Slack"])) { denied = $0 }
        expect(denied?.failure?.code == "access_disabled",
               "actions are refused while local agent access is off")
    }

    // MARK: - Plan decoding

    private static func testActionPlanDecoding() {
        guard let plan = decodePlan(slackPlanJSON) else {
            expect(false, "the Slack plan decodes")
            return
        }
        expect(plan.steps.count == 11, "all eleven steps decode")
        expect(plan.sends, "the Slack plan is marked as sending")
        expect(plan.goal == "message Himesh", "the goal survives decoding")
        expect(plan.steps.first == .openApp("Slack"), "first step is open_app Slack")
        expect(plan.steps[1] == .waitFrontmost(app: "Slack",
                                               timeoutMs: ActionPlan.Limits.defaultWaitMs),
               "wait_frontmost gets the default timeout")
        expect(plan.steps[2] == .key(name: "k", mods: ["cmd"], repeatCount: 1),
               "⌘K decodes with its modifier")

        let unsupported = decodePlan("""
        {"unsupported":"Photoshop isn't installed"}
        """)
        expect(unsupported?.unsupported == "Photoshop isn't installed",
               "an unsupported plan carries its reason")
        expect(unsupported?.isExecutable == false, "an unsupported plan never executes")

        // Fail safe: a plan that forgets to mark itself is treated as sending,
        // so the confirmation surface still appears.
        let unmarked = decodePlan("""
        {"steps":[{"do":"open_app","app":"Slack"}]}
        """)
        expect(unmarked?.sends == true, "an unmarked plan is assumed to send")

        // Modifier spellings a small model actually produces.
        let aliases = decodePlan("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"K","mods":["Command","Shift"]}]}
        """)
        expect(aliases?.steps.last == .key(name: "k", mods: ["cmd", "shift"], repeatCount: 1),
               "'Command' normalizes to cmd and the key lowercases")

        let clamped = decodePlan("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack","timeout_ms":999999},
          {"do":"type_text","text":"hi"}]}
        """)
        expect(clamped?.steps.first == .waitFrontmost(app: "Slack",
                                                      timeoutMs: ActionPlan.Limits.maxWaitMs),
               "an absurd wait timeout is clamped, not honoured")
    }

    private static func testActionPlanRejectsUnsafePlans() {
        // The engine validates first; this mirror is what stops a plan that
        // reached the app by any other route.
        expect(decodePlanError("""
        {"steps":[{"do":"run_shell","cmd":"rm -rf /"}]}
        """) == .unknownVerb("run_shell"), "there is no shell verb")

        expect(decodePlanError("""
        {"steps":[{"do":"open_url","url":"file:///etc/passwd"}]}
        """) != nil, "file:// links are rejected")

        expect(decodePlanError("""
        {"steps":[{"do":"open_url","url":"javascript:alert(1)"}]}
        """) != nil, "javascript: links are rejected")

        expect(decodePlanError("""
        {"steps":[{"do":"open_app","app":"Slack"},{"do":"type_text","text":"hello"}]}
        """) == .inputBeforeFocus(step: 1),
        "typing without a focus checkpoint is rejected — this is the rail that "
            + "stops a message landing in the wrong window")

        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"line one\\nline two"}]}
        """) == .newlineInText(step: 1),
        "a newline inside typed text is rejected — in a chat composer it is a send")

        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},{"do":"key","key":"banana"}]}
        """) == .unknownKey("banana"), "unknown key names are rejected")

        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"down","repeat":500}]}
        """) == .repeatOutOfRange(500), "a runaway key repeat is rejected")

        expect(decodePlanError("{\"steps\":[]}") == .noSteps, "an empty plan is rejected")

        // The wrong-recipient class, caught by adversarial review: the Slack
        // recipe used to press Return (selecting from the quick switcher)
        // BEFORE verifying. If ⌘K was swallowed — a cold-launched app that
        // isn't input-ready yet — the recipient's name goes into the
        // conversation already on screen and that Return sends it to the wrong
        // person. Verifying afterwards is verifying too late.
        expect(decodePlanError("""
        {"steps":[{"do":"open_app","app":"Slack"},
          {"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"k","mods":["cmd"]},
          {"do":"type_text","text":"Himesh"},
          {"do":"key","key":"return"}]}
        """) == .unverifiedSend(step: 4),
        "a Return that commits typed text needs a verify_context before it")

        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hi"},
          {"do":"key","key":"k","mods":["cmd"]}]}
        """) == nil, "a MODIFIED key after typing is a shortcut, not a send")

        // A one- or two-character term matches nearly any window title.
        for weak in ["a", "Jo", "-"] {
            expect(decodePlanError("""
            {"steps":[{"do":"wait_frontmost","app":"Slack"},
              {"do":"verify_context","expect":["\(weak)"]},
              {"do":"type_text","text":"hi"}]}
            """) == .weakVerifyTerm(weak),
            "'\(weak)' is too weak to be a verification")
        }

        // "Slack" is in every Slack window title: it proves the app is open,
        // not that the right conversation is.
        expect(decodePlanError("""
        {"steps":[{"do":"open_app","app":"Slack"},
          {"do":"wait_frontmost","app":"Slack"},
          {"do":"verify_context","expect":["Slack"]},
          {"do":"type_text","text":"hi"}]}
        """) == .weakVerifyTerm("Slack"),
        "the app's own name cannot serve as the verification")

        // `shortcuts://run-shortcut` runs a user Shortcut, which can contain a
        // Run Shell Script action — a shell step by another name.
        for scheme in ["shortcuts", "raycast", "obsidian", "things", "vscode", "cursor"] {
            expect(decodePlanError("""
            {"steps":[{"do":"open_url","url":"\(scheme)://run?x=1"}]}
            """) != nil, "\(scheme): links are not in the allowlist")
        }

        // JSON `true` bridges to 1 through NSNumber; a repeat count must be a
        // real number, matching the engine's explicit bool rejection.
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"down","repeat":true}]}
        """) != nil, "a boolean repeat count is rejected, as in the engine")

        let manySteps = (0..<(ActionPlan.Limits.maxSteps + 1))
            .map { _ in "{\"do\":\"pause\",\"ms\":10}" }.joined(separator: ",")
        expect(decodePlanError("{\"steps\":[\(manySteps)]}") != nil,
               "the step cap is enforced")

        let longText = String(repeating: "x", count: ActionPlan.Limits.maxTextChars + 1)
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},{"do":"type_text","text":"\(longText)"}]}
        """) != nil, "the per-step text cap is enforced")

        // A bidi override makes a preview read differently from what is typed.
        let sneaky = decodePlan("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"pay \\u202eyalp"}]}
        """)
        if case .typeText(let text)? = sneaky?.steps.last {
            expect(!text.unicodeScalars.contains { $0.value == 0x202E },
                   "bidi overrides are stripped from typed text")
        } else {
            expect(false, "the sanitized text step still decodes")
        }
    }

    private static func testActionKeyVocabulary() {
        expect(ActionKey.keyCode(for: "return") == 36, "return maps to keycode 36")
        expect(ActionKey.keyCode(for: "escape") == 53, "escape maps to keycode 53")
        expect(ActionKey.keyCode(for: "banana") == nil, "unknown names map to nil")
        expect(ActionKey.keyCode(for: "k") != nil, "letter keys resolve")
        expect(ActionKey.keyCode(for: "K") != nil, "key names are case-insensitive")
        expect(ActionKey.keyCode(for: "comma") != nil, "punctuation names resolve")
        expect(ActionKey.keyCode(for: "f12") == 111, "function keys resolve")
        expect(ActionModifier.flags(for: ["cmd", "shift"])
               == [.maskCommand, .maskShift], "modifier flags combine")
        expect(ActionModifier.flags(for: ["nonsense"]).isEmpty,
               "unknown modifiers contribute no flags")
        // Every name the engine may emit must map, or a plan dies mid-flight.
        for name in ActionKey.allNames {
            expect(ActionKey.keyCode(for: name) != nil, "'\(name)' maps to a keycode")
        }
    }

    private static func testAppMatching() {
        let running = ["Finder", "Google Chrome", "\u{200E}WhatsApp", "Messages",
                       "Sublime Text", "Slack"]
        func match(_ query: String) -> String? {
            AppMatcher.bestMatch(for: query, in: running).map { running[$0] }
        }
        expect(match("Slack") == "Slack", "exact names match")
        expect(match("chrome") == "Google Chrome", "'chrome' finds Google Chrome")
        // Verified on this machine: WhatsApp's localizedName carries a leading
        // U+200E, so a plain == against "WhatsApp" is false.
        expect(match("WhatsApp") == "\u{200E}WhatsApp",
               "an invisible mark in the app's name does not break matching")
        expect(match("Messages") == "Messages", "Messages is not captured by a longer name")
        expect(match("Photoshop") == nil, "absent apps do not match")
        expect(match("go") == nil, "a two-letter query does not select by substring")

        expect(AppMatcher.contextMatches(["Himesh"], in: ["Himesh Singh (DM) - Slack"]),
               "a window title satisfies a verify term")
        expect(AppMatcher.contextMatches(["himesh"], in: [nil, "Message Himesh"]),
               "a focused-element label satisfies a verify term")
        expect(!AppMatcher.contextMatches(["Himesh"], in: ["Priya - Slack"]),
               "the wrong conversation fails verification")
        expect(!AppMatcher.contextMatches(["Himesh"], in: [nil, nil]),
               "unreadable context fails closed, never open")

        // Substring matching would confirm the wrong human: ask to message
        // Priya, let the switcher land on Priyanka, and a `contains` test says
        // yes. Matching is whole-word for exactly this reason.
        expect(!AppMatcher.contextMatches(["Priya"], in: ["Priyanka Menon (DM) - Slack"]),
               "a name that is a PREFIX of another person's name does not verify")
        expect(AppMatcher.contextMatches(["Priya"], in: ["Priya Menon (DM) - Slack"]),
               "the actual person still verifies")
        expect(AppMatcher.contextMatches(["Himesh Singh"], in: ["Himesh Singh (DM)"]),
               "a multi-word term matches a consecutive run of words")
        expect(!AppMatcher.contextMatches(["Himesh Singh"], in: ["Singh Himesh"]),
               "a multi-word term does not match its words out of order")

        // Every term must match. With any-of semantics one generic term could
        // carry a whole plan past the check.
        expect(!AppMatcher.contextMatches(["Himesh", "Slack"], in: ["Priya - Slack"]),
               "one satisfied term out of two is not a verification")
        expect(AppMatcher.contextMatches(["Himesh", "DM"], in: ["Himesh Singh (DM) - Slack"]),
               "all terms present verifies")
    }

    // MARK: - Executor

    private static func testActionExecutorHappyPath() {
        let host = FakeActionHost()
        host.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        host.windowTitle = "Himesh Singh (DM) - Acme - Slack"
        host.elementLabel = "Message Himesh Singh"
        guard let plan = decodePlan(slackPlanJSON) else {
            expect(false, "plan decodes for the executor test")
            return
        }
        let result = ActionExecutor(host: host).run(plan)
        expect(result.outcome == .completed, "the Slack plan runs to completion")
        expect(host.typed == ["Himesh", "running five late"],
               "the name and the message are typed in order")
        expect(host.keys.count == 3, "⌘K plus two Returns are pressed")
        expect(host.keys.first?.1 == .maskCommand, "the first keystroke carries ⌘")

        // A draft plan is the same shape minus the final Return.
        let draftJSON = slackDraftPlanJSON
        let draftHost = FakeActionHost()
        draftHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        draftHost.windowTitle = "Himesh Singh (DM) - Slack"
        if let draft = decodePlan(draftJSON) {
            let draftResult = ActionExecutor(host: draftHost).run(draft)
            expect(draftResult.outcome == .completed, "the draft plan completes")
            expect(draftHost.keys.count == 2,
                   "a draft leaves the message in the composer (no final Return)")
        } else {
            expect(false, "the draft plan decodes")
        }

        // A URL plan needs no focus at all.
        let searchHost = FakeActionHost()
        if let search = decodePlan("""
        {"goal":"search","sends":false,"steps":[
          {"do":"open_url","url":"https://www.youtube.com/results?search_query=football"}]}
        """) {
            expect(ActionExecutor(host: searchHost).run(search).outcome == .completed,
                   "a search plan is one URL step")
            expect(searchHost.openedURLs.first?.query == "search_query=football",
                   "the search query reaches the URL")
        } else {
            expect(false, "the search plan decodes")
        }
    }

    private static func testActionExecutorSafetyRails() {
        guard let plan = decodePlan(slackPlanJSON) else {
            expect(false, "plan decodes for the safety tests")
            return
        }

        // 1. The app never comes to the front → stop before any typing.
        let stuck = FakeActionHost()
        stuck.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        stuck.frontmost = ("Sublime Text", "com.sublimetext.4")
        stuck.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        stuck.frontmostAfterReads = (reads: 0, value: ("Sublime Text", "com.sublimetext.4"))
        let stuckResult = ActionExecutor(host: stuck).run(plan)
        expect(stuckResult.outcome == .failed(step: 1, reason: "Slack didn't come to the front"),
               "a plan stops when its app never comes forward")
        expect(stuck.typed.isEmpty, "nothing is typed when focus was never established")

        // 2. The wrong conversation is open → stop before the message is typed.
        let wrongChat = FakeActionHost()
        wrongChat.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        wrongChat.windowTitle = "Priya Sharma (DM) - Slack"
        wrongChat.elementLabel = "Message Priya Sharma"
        let wrongResult = ActionExecutor(host: wrongChat).run(plan)
        if case .failed(let step, _) = wrongResult.outcome {
            // Step 5 is the verify that now guards the switcher's Return —
            // it fires before anything is committed.
            expect(step == 5, "verify_context is what fails, at its own step")
        } else {
            expect(false, "the wrong conversation must fail the plan, got \(wrongResult.outcome)")
        }
        expect(wrongChat.typed == ["Himesh"],
               "only the switcher query was typed — the message never reached the wrong person")

        // 3. The user switches apps mid-plan → the remaining input is refused.
        let stolen = FakeActionHost()
        stolen.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        stolen.windowTitle = "Himesh Singh (DM) - Slack"
        stolen.frontmostAfterReads = (reads: 4, value: ("Mail", "com.apple.mail"))
        let stolenResult = ActionExecutor(host: stolen).run(plan)
        expect(!stolenResult.outcome.isSuccess,
               "losing focus mid-plan fails the plan instead of typing into the new app")
        expect(!stolen.typed.contains("running five late"),
               "the message body never lands in the app that stole focus")

        // 4. Secure input (a password field) is up → no keystrokes at all.
        let secure = FakeActionHost()
        secure.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        secure.windowTitle = "Himesh Singh (DM) - Slack"
        secure.canPostInput = false
        let secureResult = ActionExecutor(host: secure).run(plan)
        expect(!secureResult.outcome.isSuccess, "a plan fails while secure input is active")
        expect(secure.typed.isEmpty && secure.keys.isEmpty,
               "no keystroke is synthesized while secure input is active")

        // 4b. A locked Mac fails the plan up front, and says so. Found in the
        // field: with the screen locked the run failed at wait_frontmost with
        // "TextEdit didn't come to the front", sending the user after a bug
        // that was really just a locked screen.
        let locked = FakeActionHost()
        locked.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        locked.windowTitle = "Himesh Singh (DM) - Slack"
        locked.screenIsLocked = true
        let lockedResult = ActionExecutor(host: locked).run(plan)
        expect(lockedResult.outcome == .failed(step: 0, reason: "the screen is locked"),
               "a locked screen fails the plan with an honest reason")
        expect(locked.log.isEmpty, "a locked screen stops the plan before it opens anything")

        // 5. Cancel is honoured between steps.
        let cancelHost = FakeActionHost()
        cancelHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        cancelHost.windowTitle = "Himesh Singh (DM) - Slack"
        let cancelExecutor = ActionExecutor(host: cancelHost)
        cancelExecutor.cancel()
        let cancelled = cancelExecutor.run(plan)
        expect(cancelled.outcome == .cancelled(step: 0), "a cancelled plan runs no steps")
        expect(cancelHost.log.isEmpty, "cancelling before the first step touches nothing")

        // 5b. Cancelling mid-flight (what Esc does) stops before the message.
        let midHost = FakeActionHost()
        midHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        midHost.windowTitle = "Himesh Singh (DM) - Slack"
        let midExecutor = ActionExecutor(host: midHost)
        midHost.onStep = { step in
            // Cancel the moment the switcher query has been typed.
            if step == "type(Himesh)" { midExecutor.cancel() }
        }
        let midResult = midExecutor.run(plan)
        if case .cancelled = midResult.outcome {
            expect(true, "a mid-flight cancel stops the plan")
        } else {
            expect(false, "Esc must stop a running plan, got \(midResult.outcome)")
        }
        expect(!midHost.typed.contains("running five late"),
               "cancelling before the body means nothing is sent")

        // 6. The app in the plan does not exist on this Mac.
        let missing = FakeActionHost()
        let missingResult = ActionExecutor(host: missing).run(plan)
        if case .failed(let step, _) = missingResult.outcome {
            expect(step == 0, "an unknown app fails at the open step")
        } else {
            expect(false, "an unknown app must fail the plan")
        }

        // 6b. Re-activating an app mid-plan invalidates the checkpoint. Without
        // this, `open_app` left the expected bundle id nil, and a nil id turns
        // OFF the per-chunk target check inside TextInserter — so the whole
        // message would type with no mid-typing abort.
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"open_app","app":"Slack"},
          {"do":"type_text","text":"leak"}]}
        """) == .inputBeforeFocus(step: 2),
        "re-opening an app requires a fresh focus checkpoint before typing")

        // 7. A URL hand-off does not count as focus for later typing.
        let handoff = decodePlan("""
        {"sends":false,"steps":[
          {"do":"wait_frontmost","app":"Slack"},
          {"do":"open_url","url":"https://example.com"},
          {"do":"type_text","text":"leak"}]}
        """)
        let handoffHost = FakeActionHost()
        handoffHost.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        if let handoff {
            let result = ActionExecutor(host: handoffHost).run(handoff)
            expect(!result.outcome.isSuccess,
                   "opening a URL drops focus, so the following type_text is refused")
            expect(handoffHost.typed.isEmpty, "nothing is typed after a URL hand-off")
        } else {
            expect(false, "the hand-off plan decodes")
        }
    }

    // MARK: - Helpers

    static func decodePlan(_ json: String) -> ActionPlan? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? ActionPlan.decode(object)
    }

    static func decodePlanError(_ json: String) -> ActionPlanError? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        do {
            _ = try ActionPlan.decode(object)
            return nil
        } catch let error as ActionPlanError {
            return error
        } catch {
            return nil
        }
    }

    /// The plan used across the executor tests: the Slack DM shape.
    static let slackPlanJSON = """
    {"goal":"message Himesh","sends":true,"steps":[
      {"do":"open_app","app":"Slack"},
      {"do":"wait_frontmost","app":"Slack"},
      {"do":"key","key":"k","mods":["cmd"]},
      {"do":"type_text","text":"Himesh"},
      {"do":"pause","ms":600},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"key","key":"return"},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"type_text","text":"running five late"},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"key","key":"return"}
    ]}
    """

    /// The same plan in draft form: everything up to the message, no send.
    static let slackDraftPlanJSON = """
    {"goal":"draft a message to Himesh","sends":false,"steps":[
      {"do":"open_app","app":"Slack"},
      {"do":"wait_frontmost","app":"Slack"},
      {"do":"key","key":"k","mods":["cmd"]},
      {"do":"type_text","text":"Himesh"},
      {"do":"pause","ms":600},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"key","key":"return"},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"type_text","text":"running five late"}
    ]}
    """
}
