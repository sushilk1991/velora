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
    case completed(goal: String, trace: [String])
    case failed(reason: String, trace: [String])
    case cancelled
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
            }
        }
    }

    var payload: [String: Any] {
        ["goal": goal, "sends": sends, "steps": describedSteps]
    }
}

/// Owns one action from transcript to outcome: ask the engine for a plan,
/// re-validate it locally, execute it, report.
///
/// The engine already validated the plan; this decodes it through
/// `ActionPlan.decode` anyway. Two independent implementations of one contract
/// is the point — the engine guards what the model may propose, the app guards
/// what the machine will do, and only the app holds the Accessibility grant.
final class ActionCoordinator {
    private let client: EngineClient
    private let host: ActionHost
    private var executor: ActionExecutor?
    private var pendingID: String?
    private var completion: ((ActionResult) -> Void)?
    private var cancelled = false
    private var executeRequested = false
    /// Whether this caller accepted that the plan may deliver something to
    /// another person. The voice hotkey is itself that consent; the CLI has to
    /// say so per request.
    private var sendAllowed = true
    private var planTimer: Timer?

    /// The engine's own plan budget is 20 s; this is the app-side backstop for
    /// a reply that never arrives at all (engine crash, restart mid-request).
    /// Without it `pendingID` stays set and every later action is refused as
    /// "already running".
    private static let planTimeout: TimeInterval = 30

    init(client: EngineClient, host: ActionHost) {
        self.client = client
        self.host = host
    }

    var isRunning: Bool { pendingID != nil || executor != nil }
    /// True only while steps are being carried out — planning does not touch
    /// the machine, so it must not swallow Esc from the rest of the app.
    var isExecuting: Bool { executor != nil }

    /// Send a spoken command off for planning. `completion` fires once. With
    /// `execute: false` the plan comes back untouched and nothing happens to the
    /// machine — the safe way to inspect what a command would do.
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
        cancelled = false
        executeRequested = execute
        sendAllowed = allowSend
        let id = UUID().uuidString
        pendingID = id
        self.completion = completion
        client.send(json: [
            "cmd": "action_plan",
            "id": id,
            "transcript": transcript,
            "context": context.payload,
        ])
        planTimer?.invalidate()
        planTimer = Timer.scheduledTimer(
            withTimeInterval: Self.planTimeout, repeats: false
        ) { [weak self] _ in
            guard let self, self.pendingID == id else { return }
            self.client.send(json: ["cmd": "action_cancel", "id": id])
            self.pendingID = nil
            self.finish(.failed(reason: "planning timed out", trace: []))
        }
    }

    func cancel() {
        cancelled = true
        executor?.cancel()
        if let pendingID {
            client.send(json: ["cmd": "action_cancel", "id": pendingID])
        }
    }

    /// Feed engine events here. Ignores anything that isn't this action's reply.
    func handle(_ event: EngineEvent) {
        switch event {
        case .actionPlan(let id, let planJSON, let ms):
            guard let id, id == pendingID else { return }
            pendingID = nil
            run(planJSON: planJSON, planMs: ms)
        case .actionFailed(let id, let error, let code):
            guard let id, id == pendingID else { return }
            pendingID = nil
            finish(code == "cancelled" ? .cancelled : .failed(reason: error, trace: []))
        default:
            break
        }
    }

    private func run(planJSON: [String: Any], planMs: Int) {
        let plan: ActionPlan
        do {
            plan = try ActionPlan.decode(planJSON)
        } catch let error as ActionPlanError {
            NSLog("Velora: action plan rejected locally — %@", error.message)
            finish(.failed(reason: "that plan didn't look safe to run", trace: []))
            return
        } catch {
            finish(.failed(reason: "that plan didn't look safe to run", trace: []))
            return
        }
        if let unsupported = plan.unsupported {
            finish(.failed(reason: unsupported, trace: []))
            return
        }
        guard plan.isExecutable else {
            finish(.failed(reason: "there was nothing to do", trace: []))
            return
        }
        if cancelled {
            finish(.cancelled)
            return
        }
        if plan.sends, !sendAllowed {
            // The plan would message someone and this caller never said that
            // was acceptable. Report it as a refusal with the plan attached, so
            // the caller can look at it and ask again deliberately.
            NSLog("Velora: action refused — plan sends and the caller did not allow it")
            finish(.needsSendApproval(plan))
            return
        }
        guard executeRequested else {
            NSLog("Velora: action dry run — %d steps, sends=%@",
                  plan.steps.count, plan.sends ? "yes" : "no")
            finish(.planned(plan))
            return
        }
        veloraLog("Velora: action plan ready in \(planMs)ms — \(plan.steps.count) steps, "
                  + "sends=\(plan.sends ? "yes" : "no"), goal=\(plan.goal)")

        let executor = ActionExecutor(host: host)
        self.executor = executor
        // Steps block on real UI (activation polling, per-chunk typing), so the
        // run never touches the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = executor.run(plan)
            DispatchQueue.main.async {
                guard let self else { return }
                self.executor = nil
                for line in result.trace { veloraLog("Velora: action · \(line)") }
                switch result.outcome {
                case .completed:
                    self.finish(.completed(goal: plan.goal, trace: result.trace))
                case .cancelled:
                    self.finish(.cancelled)
                case .failed(let step, let reason):
                    veloraLog("Velora: action failed at step \(step) — \(reason)")
                    self.finish(.failed(reason: reason, trace: result.trace))
                }
            }
        }
    }

    private func finish(_ result: ActionResult) {
        planTimer?.invalidate()
        planTimer = nil
        // Cleared before the callback: `completion` is nilled first so a
        // callback that starts another action cannot be mistaken for a second
        // completion of this one.
        let callback = completion
        completion = nil
        pendingID = nil
        callback?(result)
    }
}
