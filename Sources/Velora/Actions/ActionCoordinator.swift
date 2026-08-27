import AppKit
import ApplicationServices
import Foundation

enum ActionProgress: Equatable {
    case readingScreen
    case planning(turn: Int)
    case verifyingTarget
    case executing(step: Int, total: Int, description: String)
    case retrying(String)

    var hudMessage: String {
        switch self {
        case .readingScreen:
            return "Reading screen · Esc to stop"
        case .planning(let turn):
            return "Planning" + (turn > 1 ? " turn \(turn)" : "")
                + " · Esc to stop"
        case .verifyingTarget:
            return "Confirming recipient · Esc to stop"
        case .executing(let step, let total, let description):
            let short = String(description.prefix(42))
            return "\(step)/\(total) \(short) · Esc to stop"
        case .retrying:
            return "Screen changed; trying a new path · Esc to stop"
        }
    }
}

/// What the planner is told about the machine. Gathered entirely from APIs that
/// need no permission beyond the Accessibility grant Velora already holds —
/// running apps and the frontmost app are free, window titles come from AX.
/// Nothing here uses Screen Recording.
struct ActionContextSnapshot {
    var frontmostApp: String = ""
    var frontmostBundle: String = ""
    var frontmostWindow: String = ""
    var runningApps: [String] = []
    /// Installed names used only by the local focus-authority validator.
    /// They are sent to the engine but never included in the model prompt.
    var knownApps: [String] = []
    var selection: String = ""
    /// Name-like labels visible in the front window — the correct spellings of
    /// the people and channels the user is about to name out loud.
    var screenNames: [String] = []
    /// URL of the frontmost browser page, "" outside a browser. Web tasks
    /// need it: the window title alone cannot tell Gmail's inbox from its
    /// compose view.
    var pageURL: String = ""
    var uiSnapshot: ActionUISnapshot?

    var payload: [String: Any] {
        var out: [String: Any] = [
            "frontmost_app": frontmostApp,
            "frontmost_bundle": frontmostBundle,
            "frontmost_window": frontmostWindow,
            "running_apps": runningApps,
            "known_apps": knownApps,
            "selection": selection,
            "screen_names": screenNames,
            "page_url": pageURL,
        ]
        if let uiSnapshot { out["ui_snapshot"] = uiSnapshot.payload }
        return out
    }

    /// Snapshot of the machine as the command was spoken. `frontmost` is passed
    /// in because by the time this runs Velora's own HUD may be key.
    static func capture(
        frontmost: NSRunningApplication?,
        windowTitle: String? = nil,
        selection: String = "",
        screenNames: [String] = [],
        pageURL: String = ""
    ) -> ActionContextSnapshot {
        var snapshot = ActionContextSnapshot()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        snapshot.runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty }
        snapshot.knownApps = InstalledApps.shared.entries().map(\.name)
        if let frontmost {
            snapshot.frontmostApp = frontmost.localizedName ?? ""
            snapshot.frontmostBundle = frontmost.bundleIdentifier ?? ""
        }
        snapshot.frontmostWindow = windowTitle ?? ""
        // Bounded: a whole selected document would swamp a 4B model's context
        // and push the actual command out of view.
        snapshot.selection = String(selection.prefix(400))
        snapshot.screenNames = screenNames
        snapshot.pageURL = String(pageURL.prefix(300))
        return snapshot
    }
}

/// Outcome of one spoken command, for the HUD and the log.
struct ActionCompletionTarget: Equatable {
    let appName: String
    let bundleID: String
    let pid: Int?
    let windowID: Int?
    let processIdentity: CuaProcessIdentity?

    init(
        appName: String, bundleID: String,
        pid: Int? = nil, windowID: Int? = nil,
        processIdentity: CuaProcessIdentity? = nil
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.processIdentity = pid.flatMap { value in
            processIdentity?.pid == pid_t(value) ? processIdentity : nil
        }
    }
}

enum ActionResult {
    /// Planned only — nothing was executed (a dry run).
    case planned(ActionPlan)
    /// The plan would deliver something to another person and the caller had
    /// not agreed to that. Nothing ran.
    case needsSendApproval(ActionPlan)
    /// The requested postcondition was proven, or an app-only request reached
    /// a fresh exact background route.
    case completed(
        goal: String,
        trace: [String],
        target: ActionCompletionTarget? = nil
    )
    /// A background app-only request reached a fresh exact route. The app is
    /// ready, but opening it remains an explicit user click.
    case ready(
        goal: String,
        trace: [String],
        target: ActionCompletionTarget
    )
    /// Steps ran, but the executor did not observe enough structured evidence
    /// to prove the requested postcondition.
    case performedUnverified(
        goal: String,
        trace: [String],
        target: ActionCompletionTarget? = nil
    )
    case failed(reason: String, trace: [String])
    case cancelled
}

struct ActionVoiceCompletionNotice: Equatable {
    let verified: Bool
    let ready: Bool
    let symbol: String
    let message: String
    let target: ActionCompletionTarget?
}

extension ActionResult {
    /// Successful transport payload for CLI callers. Execution and verified
    /// completion are independent facts and stay independent on the wire.
    func controlSuccessPayload(execute: Bool) -> [String: Any]? {
        switch self {
        case .completed(let goal, let trace, _):
            return [
                "ok": true,
                "executed": execute,
                "completed": true,
                "verified": true,
                "goal": goal,
                "trace": trace,
            ]
        case .ready(let goal, let trace, _):
            return [
                "ok": true,
                "executed": execute,
                "completed": false,
                "verified": true,
                "ready": true,
                "goal": goal,
                "trace": trace,
            ]
        case .performedUnverified(let goal, let trace, _):
            return [
                "ok": true,
                "executed": true,
                "completed": false,
                "verified": false,
                "goal": goal,
                "trace": trace,
            ]
        default:
            return nil
        }
    }

    var voiceCompletionNotice: ActionVoiceCompletionNotice? {
        switch self {
        case .completed(let goal, _, let target):
            return ActionVoiceCompletionNotice(
                verified: true,
                ready: false,
                symbol: "checkmark.circle.fill",
                message: goal.isEmpty
                    ? "Task completed"
                    : "Done · \(String(goal.prefix(80)))",
                target: target)
        case .ready(_, _, let target):
            return ActionVoiceCompletionNotice(
                verified: true,
                ready: true,
                symbol: "arrow.up.forward.app.fill",
                message: "\(target.appName) is ready",
                target: target)
        case .performedUnverified(_, _, let target):
            return ActionVoiceCompletionNotice(
                verified: false,
                ready: false,
                symbol: "circle.dashed",
                message: "Action ran; completion wasn't verified",
                target: target)
        default:
            return nil
        }
    }
}

extension ActionPlan {
    /// One line per step, for dry-run output and logs. Reads as a sentence so a
    /// user (or an agent) can sanity-check a plan before running it.
    var describedSteps: [String] {
        steps.map { step in
            switch step {
            case .openApp(let app): return "open \(app)"
            case .openURL(let url): return "open \(url.absoluteString)"
            case .waitFrontmost(let app, let ms): return "wait for \(app) (≤\(ms)ms)"
            case .verifyContext(let terms):
                // Every term must appear; a preview that said "or" would
                // understate the check a reader is inspecting.
                return "verify screen shows \(terms.joined(separator: " and "))"
            case .verifyUI(_, let index, let role, let label, let target):
                return "verify [\(index)] \(role) \"\(label)\" proves \(target)"
            case .verifyGoal(_, let index, let role, let label, let target):
                return "verify goal [\(index)] \(role) \"\(label)\" proves \(target)"
            case .presentUI(_, let bundleID, let windowID, _):
                return "present \(bundleID) window \(windowID)"
            case .typeText(let text): return "type \"\(text)\""
            case .typeTextAt(let text, let operation, _):
                return operation == .search
                    ? "search for \"\(text)\"" : "type \"\(text)\""
            case .searchText(let text): return "search for \"\(text)\""
            case .pasteText(let text): return "paste \"\(text)\""
            case .key(let name, let mods, let count):
                let chord = (mods + [name]).joined(separator: "+")
                return count > 1 ? "press \(chord) x\(count)" : "press \(chord)"
            case .pause(let ms): return "pause \(ms)ms"
            case .pressElement(let label): return "press \"\(label)\" on screen"
            case .pressUI(_, let index, let role, let label):
                return "press [\(index)] \(role) \"\(label)\" on screen"
            case .mediaControl(let control):
                return "set media playback to \(control.state.rawValue)"
            case .verifyState(let check):
                return "verify \(check.assertion.rawValue)"
            }
        }
    }

    var payload: [String: Any] {
        ["goal": goal, "sends": sends, "steps": describedSteps]
    }
}

/// Blocking bridge from the loop's background queue to the engine socket.
/// Lives for exactly one action: send a command, wait for that action's turn
/// event, hand it back as a value.
final class EngineTurnPlanner: ActionTurnPlanner {
    /// One turn may chain controller, UI reviewer, completion/target verifier,
    /// and one repair. The previous 65 s backstop predated those calls and
    /// cancelled a healthy engine mid-review, producing "session already
    /// finished". The action's 180 s wall remains the outer bound.
    static let turnTimeout: TimeInterval = 150

    let id = UUID().uuidString
    private let client: EngineClient
    private let lock = NSLock()
    private var slot: PlannedTurn?
    /// True only between a request going out and its reply being consumed. An
    /// event that lands outside that window (a stale answer after a timeout)
    /// is dropped instead of being smuggled in as the reply to the NEXT
    /// request — without this the loop would desync one turn for the rest of
    /// the action, executing steps chosen for a previous screen state.
    private var awaiting = false
    private let semaphore = DispatchSemaphore(value: 0)

    init(client: EngineClient) {
        self.client = client
    }

    /// Called on the main queue with every engine event; keeps this action's.
    func handle(_ event: EngineEvent) {
        switch event {
        case .actionTurn(let id, _, let sends, let goal, let steps, let done, _):
            guard id == self.id else { return }
            deliver(.turn(sends: sends, goal: goal, steps: steps, done: done))
        case .actionFailed(let id, let error, let code):
            guard id == self.id else { return }
            deliver(.failure(reason: error, code: code))
        default:
            break
        }
    }

    /// Unblocks a waiting turn with "cancelled" — what Esc resolves to when
    /// it lands between batches, while the model is thinking.
    func cancelPending() {
        deliver(.failure(reason: "the action was cancelled", code: "cancelled"))
        send(["cmd": "action_cancel", "id": id])
    }

    private func deliver(_ turn: PlannedTurn) {
        lock.lock()
        // Only an answer someone is waiting for counts; first answer wins.
        guard awaiting, slot == nil else {
            lock.unlock()
            return
        }
        slot = turn
        lock.unlock()
        semaphore.signal()
    }

    private func send(_ json: [String: Any]) {
        // AX is an IPC boundary. One app returning NaN/∞ geometry must not
        // make JSONSerialization silently drop the whole observation and
        // leave the caller waiting for a request the engine never received.
        guard JSONSerialization.isValidJSONObject(json) else {
            deliver(.failure(
                reason: "the screen observation could not be encoded",
                code: "invalid_observation"))
            return
        }
        DispatchQueue.main.async { [client] in
            client.send(json: json)
        }
    }

    private func beginRequest() {
        lock.lock()
        awaiting = true
        slot = nil
        lock.unlock()
        // Drain any leftover signal from an answer that arrived after its
        // request had already timed out.
        while semaphore.wait(timeout: .now()) == .success {}
    }

    private func awaitReply() -> PlannedTurn {
        defer {
            lock.lock()
            awaiting = false
            lock.unlock()
        }
        guard semaphore.wait(timeout: .now() + Self.turnTimeout) != .timedOut else {
            send(["cmd": "action_cancel", "id": id])
            return .failure(reason: "planning timed out", code: "timeout")
        }
        lock.lock()
        let value = slot
        slot = nil
        lock.unlock()
        return value ?? .failure(reason: "the engine returned nothing", code: "failed")
    }

    func start(transcript: String, context: ActionContextSnapshot) -> PlannedTurn {
        beginRequest()
        send(["cmd": "action_start", "id": id,
              "transcript": transcript, "context": context.payload])
        return awaitReply()
    }

    func observe(_ observation: [String: Any]) -> PlannedTurn {
        beginRequest()
        send(["cmd": "action_observe", "id": id, "observation": observation])
        return awaitReply()
    }

    func end() {
        send(["cmd": "action_end", "id": id])
    }
}

/// Owns one action from transcript to outcome: run the observe→decide→act
/// loop against the engine, report the result on the main queue.
///
/// The engine validates every batch before proposing it; the loop decodes it
/// through `ActionPlan.decode` anyway. Two independent implementations of one
/// contract is the point — the engine guards what the model may propose, the
/// app guards what the machine will do, and only the app holds the
/// Accessibility grant.
final class ActionCoordinator {
    private let client: EngineClient
    private let host: ActionHost
    private var runner: ActionLoopRunner?
    private var planner: EngineTurnPlanner?
    private var completion: ((ActionResult) -> Void)?
    private var executing = false
    private var executeRequested = false

    init(client: EngineClient, host: ActionHost) {
        self.client = client
        self.host = host
    }

    var isRunning: Bool { runner != nil }
    /// Planner transport identity, exposed only so the outer Agent lifecycle
    /// can avoid recording a late event from a superseded engine session.
    var activeActionID: String? { planner?.id }
    /// True once the loop has begun driving the machine. Until the first turn
    /// arrives nothing has been touched, so Esc still belongs to whatever
    /// else is on screen.
    var isExecuting: Bool { executing }

    /// Send a spoken command into the loop. `completion` fires once, on the
    /// main queue. With `execute: false` the first batch comes back untouched
    /// and nothing happens to the machine — the safe way to inspect what a
    /// command would do.
    func perform(
        transcript: String,
        context: ActionContextSnapshot,
        execute: Bool = true,
        allowSend: Bool = true,
        progress: ((ActionProgress) -> Void)? = nil,
        completion: @escaping (ActionResult) -> Void
    ) {
        guard !isRunning else {
            completion(.failed(reason: "another action is already running", trace: []))
            return
        }
        let planner = EngineTurnPlanner(client: client)
        let report: (ActionProgress) -> Void = { value in
            guard let progress else { return }
            DispatchQueue.main.async { progress(value) }
        }
        let runner = ActionLoopRunner(
            host: host, planner: planner, execute: execute,
            allowSend: allowSend, progress: report)
        self.planner = planner
        self.runner = runner
        self.completion = completion
        executeRequested = execute
        executing = false
        // The loop blocks on real UI (activation polling, per-chunk typing)
        // and on the model between batches; it never touches the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runner.run(transcript: transcript, context: context)
            DispatchQueue.main.async {
                self?.finish(result)
            }
        }
    }

    func cancel() {
        runner?.cancel()
        // Whichever state the loop is in — mid-batch or waiting on the model —
        // one of these two reaches it.
        planner?.cancelPending()
    }

    /// Feed engine events here. Ignores anything that isn't this action's.
    func handle(_ event: EngineEvent) {
        guard let planner else { return }
        if case .actionTurn(let id, let turn, let sends, let goal, _, _, let ms) = event,
           id == planner.id {
            if executeRequested { executing = true }
            if turn == 1 {
                veloraLog("Velora: action turn 1 ready in \(ms)ms — "
                          + "sends=\(sends ? "yes" : "no"), goal=\(goal)")
            } else {
                veloraLog("Velora: action turn \(turn) ready in \(ms)ms")
            }
        }
        planner.handle(event)
    }

    private func finish(_ result: ActionResult) {
        switch result {
        case .completed(let goal, let trace, _):
            for line in trace { veloraLog("Velora: action · \(line)") }
            veloraLog("Velora: action completed — \(goal)")
        case .ready(let goal, let trace, _):
            for line in trace { veloraLog("Velora: action · \(line)") }
            veloraLog("Velora: action target ready — \(goal)")
        case .performedUnverified(let goal, let trace, _):
            for line in trace { veloraLog("Velora: action · \(line)") }
            veloraLog("Velora: action ran without completion evidence — \(goal)")
        case .failed(let reason, let trace):
            for line in trace { veloraLog("Velora: action · \(line)") }
            veloraLog("Velora: action failed — \(reason)")
        case .cancelled:
            veloraLog("Velora: action cancelled")
        case .planned, .needsSendApproval:
            break
        }
        runner = nil
        planner = nil
        executing = false
        // Cleared before the callback: `completion` is nilled first so a
        // callback that starts another action cannot be mistaken for a second
        // completion of this one.
        let callback = completion
        completion = nil
        callback?(result)
    }
}
