import AppKit
import ApplicationServices
import Foundation

/// What the planner is told about the machine. Gathered entirely from APIs that
/// need no permission beyond the Accessibility grant Velora already holds —
/// running apps and the frontmost app are free, window titles come from AX.
/// Nothing here uses Screen Recording.
struct ActionContextSnapshot {
    var frontmostApp: String = ""
    var frontmostBundle: String = ""
    var frontmostWindow: String = ""
    var runningApps: [String] = []
    var selection: String = ""
    /// Name-like labels visible in the front window — the correct spellings of
    /// the people and channels the user is about to name out loud.
    var screenNames: [String] = []

    var payload: [String: Any] {
        [
            "frontmost_app": frontmostApp,
            "frontmost_bundle": frontmostBundle,
            "frontmost_window": frontmostWindow,
            "running_apps": runningApps,
            "selection": selection,
            "screen_names": screenNames,
        ]
    }

    /// Snapshot of the machine as the command was spoken. `frontmost` is passed
    /// in because by the time this runs Velora's own HUD may be key.
    static func capture(
        frontmost: NSRunningApplication?,
        windowTitle: String? = nil,
        selection: String = "",
        screenNames: [String] = []
    ) -> ActionContextSnapshot {
        var snapshot = ActionContextSnapshot()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        snapshot.runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty }
        if let frontmost {
            snapshot.frontmostApp = frontmost.localizedName ?? ""
            snapshot.frontmostBundle = frontmost.bundleIdentifier ?? ""
        }
        snapshot.frontmostWindow = windowTitle ?? ""
        // Bounded: a whole selected document would swamp a 4B model's context
        // and push the actual command out of view.
        snapshot.selection = String(selection.prefix(400))
        snapshot.screenNames = screenNames
        return snapshot
    }
}

/// Outcome of one spoken command, for the HUD and the log.
enum ActionResult {
    /// Planned only — nothing was executed (a dry run).
    case planned(ActionPlan)
    /// The plan would deliver something to another person and the caller had
    /// not agreed to that. Nothing ran.
    case needsSendApproval(ActionPlan)
    /// Reserved for a caller-supplied, goal-bound postcondition. The current
    /// Action loop has no such contract and never constructs this case.
    case completed(goal: String, trace: [String])
    /// Steps ran, but the executor did not observe enough structured evidence
    /// to prove the requested postcondition.
    case performedUnverified(goal: String, trace: [String])
    case failed(reason: String, trace: [String])
    case cancelled
}

struct ActionVoiceCompletionNotice: Equatable {
    let symbol: String
    let message: String
}

extension ActionResult {
    /// Successful transport payload for CLI callers. Execution and verified
    /// completion are independent facts and stay independent on the wire.
    func controlSuccessPayload(execute: Bool) -> [String: Any]? {
        switch self {
        case .completed(let goal, let trace):
            return [
                "ok": true,
                "executed": execute,
                "completed": true,
                "verified": true,
                "goal": goal,
                "trace": trace,
            ]
        case .performedUnverified(let goal, let trace):
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
        case .completed(let goal, _):
            return ActionVoiceCompletionNotice(
                symbol: "checkmark.circle",
                message: goal.isEmpty ? "Done" : String(goal.prefix(60)))
        case .performedUnverified:
            return ActionVoiceCompletionNotice(
                symbol: "circle.dashed",
                message: "Action ran; completion wasn't verified")
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
            case .typeText(let text): return "type \"\(text)\""
            case .pasteText(let text): return "paste \"\(text)\""
            case .key(let name, let mods, let count):
                let chord = (mods + [name]).joined(separator: "+")
                return count > 1 ? "press \(chord) x\(count)" : "press \(chord)"
            case .pause(let ms): return "pause \(ms)ms"
            case .pressElement(let label): return "press \"\(label)\" on screen"
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
    /// The engine's worst case per ask is 35 s (cold first attempt) + 20 s
    /// (repair); this backstop sits above that so it only ever fires for a
    /// reply that will truly never arrive (engine crash, restart
    /// mid-request). Without it the loop's thread would wait forever and
    /// every later action would be refused as "already running".
    static let turnTimeout: TimeInterval = 65

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
        completion: @escaping (ActionResult) -> Void
    ) {
        guard !isRunning else {
            completion(.failed(reason: "another action is already running", trace: []))
            return
        }
        let planner = EngineTurnPlanner(client: client)
        let runner = ActionLoopRunner(host: host, planner: planner,
                                      execute: execute, allowSend: allowSend)
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
        case .completed(let goal, let trace):
            for line in trace { veloraLog("Velora: action · \(line)") }
            veloraLog("Velora: action completed — \(goal)")
        case .performedUnverified(let goal, let trace):
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
