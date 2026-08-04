import Foundation

/// The engine's side of one action, as the loop sees it. Calls BLOCK on the
/// loop's background queue until the engine replies or times out; the fake in
/// the selftest answers instantly from a script.
protocol ActionTurnPlanner: AnyObject {
    func start(transcript: String, context: ActionContextSnapshot) -> PlannedTurn
    func observe(_ observation: [String: Any]) -> PlannedTurn
    /// The loop is finished with the session — success, failure, or cancel.
    func end()
}

enum PlannedTurn {
    /// One model turn: the sends bit (only the FIRST turn's value is
    /// honoured), the goal, a batch of raw step JSON — decoded and
    /// re-validated app-side, never trusted — and whether the model says the
    /// goal is met once this batch finishes.
    case turn(sends: Bool, goal: String, steps: [Any], done: Bool)
    case failure(reason: String, code: String)
}

/// Drives one action end to end: batch → machine → observation → next batch.
///
/// This loop replaced the v1 one-shot plan after a morning of field failures
/// showed why blind scripts die: WhatsApp's Return does not open a chat the
/// way Slack's does, quick switchers select stale rows, and a model that
/// never sees the screen can only fail and shrug. Here every batch's outcome
/// — including a failed checkpoint — becomes the next turn's observation.
///
/// What the loop never relaxes:
/// * every batch passes `ActionPlan.decode` against the CARRIED state, so
///   budgets span the whole action and text typed in turn N cannot be
///   committed unverified in turn N+1;
/// * the carried state is recomputed from what actually EXECUTED
///   (`ActionPlan.state(after:executedCount:seed:)`), so a verify that failed
///   at runtime never counts as having verified anything;
/// * `sends` is taken from the first turn and locked — and gates execution
///   before the first step runs;
/// * only recoverable failures loop; secure input, a locked screen, or
///   stolen focus ends the action;
/// * the turn cap and wall clock end it even if the model never says done.
final class ActionLoopRunner {
    /// Mirrors `actions.MAX_TURNS` in the engine.
    static let maxTurns = 8
    /// Hard wall for the whole loop, model thinking included.
    static let wallClockSeconds: TimeInterval = 180

    private let host: ActionHost
    private let planner: ActionTurnPlanner
    private let execute: Bool
    private let allowSend: Bool

    private let lock = NSLock()
    private var cancelledStorage = false
    private var currentExecutor: ActionExecutor?

    init(host: ActionHost, planner: ActionTurnPlanner,
         execute: Bool, allowSend: Bool) {
        self.host = host
        self.planner = planner
        self.execute = execute
        self.allowSend = allowSend
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledStorage
    }

    /// Safe from any thread; stops the running batch and the loop.
    func cancel() {
        lock.lock()
        cancelledStorage = true
        let executor = currentExecutor
        lock.unlock()
        executor?.cancel()
    }

    func run(transcript: String, context: ActionContextSnapshot) -> ActionResult {
        var carried = ActionPlan.BatchState()
        var fullTrace: [String] = []
        var lockedSends: Bool?
        var lockedGoal = ""
        var turnsUsed = 0
        // Every planner call, accepted or rejected. Rejected turns consume no
        // engine turn, so this is the bound that stops a model stuck on an
        // invalid shape from being asked forever.
        var asks = 1
        let deadline = host.now() + Self.wallClockSeconds

        var reply = planner.start(transcript: transcript, context: context)

        while true {
            if isCancelled {
                planner.end()
                return .cancelled
            }
            switch reply {
            case .failure(let reason, let code):
                // A rejected turn (the engine's validator refused what the
                // model proposed, twice) is recoverable the same way a failed
                // checkpoint is: tell the model and let it look again. Seen
                // live: the inline repair repeated the rejected shape, while
                // a fresh observation broke the fixation.
                if code == "plan_invalid", execute,
                   asks < Self.maxTurns + 2, host.now() < deadline, !isCancelled {
                    asks += 1
                    reply = planner.observe(gatherObservation(
                        executed: fullTrace,
                        failedStep: "steps rejected before running: \(reason) "
                            + "— propose different steps"))
                    continue
                }
                planner.end()
                return code == "cancelled" ? .cancelled
                                           : .failed(reason: reason, trace: fullTrace)

            case .turn(let sends, let goal, let stepsJSON, let done):
                turnsUsed += 1
                if lockedSends == nil {
                    // Decided here, never again: a later turn upgrading a
                    // draft into a send would sidestep the consent the caller
                    // actually gave.
                    lockedSends = sends
                    lockedGoal = goal
                }

                if stepsJSON.isEmpty {
                    planner.end()
                    // A FIRST turn that reports done without doing anything is
                    // the planner shrugging, and this used to reach the user
                    // as success. From turn 2 an observation has been seen, so
                    // "already met" is a real answer. The engine refuses this
                    // too; keeping the app's own check is the point of having
                    // two (review finding, 2026-08-04).
                    return done && turnsUsed > 1
                        ? .completed(goal: lockedGoal, trace: fullTrace)
                        : .failed(reason: "the planner returned nothing to do",
                                  trace: fullTrace)
                }

                let batchObject: [String: Any] = [
                    "goal": lockedGoal,
                    "sends": lockedSends ?? true,
                    "steps": stepsJSON,
                ]

                // The send gate comes before decode so even an undecodable
                // batch cannot stall a refusal the caller is owed now.
                if execute, lockedSends == true, !allowSend {
                    var probe = carried
                    let plan = (try? ActionPlan.decode(batchObject, state: &probe))
                        ?? ActionPlan(goal: lockedGoal, sends: true, steps: [],
                                      unsupported: nil)
                    planner.end()
                    return .needsSendApproval(plan)
                }

                var probe = carried
                let plan: ActionPlan
                do {
                    plan = try ActionPlan.decode(batchObject, state: &probe)
                } catch {
                    let message = (error as? ActionPlanError)?.message ?? "invalid steps"
                    NSLog("Velora: action batch rejected locally — %@", message)
                    // The app's validator is stricter than the engine's here —
                    // it knows what actually RAN, not what was proposed. Its
                    // rejection is itself an observation the model can act on.
                    guard execute, turnsUsed < Self.maxTurns,
                          asks < Self.maxTurns + 2, host.now() < deadline
                    else {
                        planner.end()
                        return .failed(reason: "that plan didn't look safe to run",
                                       trace: fullTrace)
                    }
                    asks += 1
                    reply = planner.observe(gatherObservation(
                        executed: fullTrace,
                        failedStep: "steps rejected before running: \(message)"))
                    continue
                }

                guard execute else {
                    planner.end()
                    return .planned(plan)
                }

                let executor = ActionExecutor(host: host)
                lock.lock()
                currentExecutor = executor
                let alreadyCancelled = cancelledStorage
                lock.unlock()
                if alreadyCancelled {
                    planner.end()
                    return .cancelled
                }
                let result = executor.run(plan)
                lock.lock()
                currentExecutor = nil
                lock.unlock()

                fullTrace.append(contentsOf: result.trace)
                // Runtime truth, not batch intent: only steps that actually
                // completed update the carried safety state.
                carried = ActionPlan.state(after: plan,
                                           executedCount: result.executedSteps,
                                           seed: carried)

                switch result.outcome {
                case .completed:
                    if done {
                        planner.end()
                        return .completed(goal: lockedGoal, trace: fullTrace)
                    }
                    guard turnsUsed < Self.maxTurns, host.now() < deadline else {
                        planner.end()
                        return .failed(
                            reason: "ran out of attempts before finishing",
                            trace: fullTrace)
                    }
                    asks += 1
                    reply = planner.observe(gatherObservation(
                        executed: fullTrace, failedStep: nil))

                case .cancelled:
                    planner.end()
                    return .cancelled

                case .failed(_, let reason, let recoverable):
                    guard recoverable, turnsUsed < Self.maxTurns,
                          host.now() < deadline, !isCancelled else {
                        planner.end()
                        return .failed(reason: reason, trace: fullTrace)
                    }
                    // The trace's last line says what the screen actually
                    // showed — that detail is what makes the next turn
                    // smarter than a retry.
                    asks += 1
                    reply = planner.observe(gatherObservation(
                        executed: fullTrace,
                        failedStep: result.trace.last ?? reason))
                }
            }
        }
    }

    /// What the model gets to look at between turns. Every string is read off
    /// the user's screen; the engine defangs each one before it reaches the
    /// prompt.
    private func gatherObservation(executed: [String],
                                   failedStep: String?) -> [String: Any] {
        let front = host.frontmostApp()
        var observation: [String: Any] = [
            "frontmost_app": front?.name ?? "",
            "frontmost_bundle": front?.bundleID ?? "",
            "window_title": host.frontmostWindowTitle() ?? "",
            "focused_label": host.focusedElementLabel() ?? "",
            "focused_role": host.focusedElementRole() ?? "",
            "selection": host.focusedSelectionLabel() ?? "",
            "screen_names": host.visibleNames(),
            "executed": executed,
        ]
        if let failedStep {
            observation["failed_step"] = failedStep
        }
        return observation
    }
}
