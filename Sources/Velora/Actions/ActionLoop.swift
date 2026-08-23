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

/// Aggregates typed executor evidence across model turns. A successful host
/// call proves only that the call was accepted. The events remain available
/// for a future caller-supplied, goal-bound postcondition; they are not turned
/// into user-facing completion text here.
private struct ActionCompletionEvidence {
    private(set) var events: [ActionEvidenceEvent] = []
    private(set) var hadEffect = false

    mutating func record(_ result: ActionRunResult) {
        for event in result.evidence {
            events.append(event)
            switch event {
            case .appOpenRequested, .unverifiedEffect:
                hadEffect = true
            case .frontmostConfirmed:
                break
            }
        }
    }
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
        // SystemActionHost persists across planner turns and user actions.
        // Draft ownership must cross turns in this run, but never leak into
        // the next action invocation.
        host.beginActionInputSession()
        var carried = ActionPlan.BatchState()
        carried.appNames.formUnion(context.runningApps)
        if !context.frontmostApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            carried.appNames.insert(context.frontmostApp)
        }
        carried.currentApp = context.frontmostApp
        // open_url data fence: titles and the selection stay out on purpose —
        // they are the payloads being fenced.
        carried.urlTokenPool = ActionPlan.urlTokenPool(
            [transcript, context.pageURL] + context.screenNames)
        var fullTrace: [String] = []
        /// What the PLANNER is shown between turns. Identical to `fullTrace`
        /// except where a line carries the plan's typed text, which belongs
        /// in the next prompt but never in the log or the task ledger.
        var observationTrace: [String] = []
        var completionEvidence = ActionCompletionEvidence()
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
                        executed: observationTrace,
                        failedStep: "steps rejected before running: \(reason) "
                            + "— propose different steps",
                        state: &carried))
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
                    lockedGoal = String(ActionPlan.sanitize(goal).prefix(200))
                }

                if stepsJSON.isEmpty {
                    planner.end()
                    // A FIRST turn that reports done without doing anything is
                    // the planner shrugging. On later turns `done` may stop the
                    // loop, but only the accumulated executor evidence decides
                    // whether that stop is verified completion.
                    guard done, turnsUsed > 1 else {
                        return .failed(reason: "the planner returned nothing to do",
                                       trace: fullTrace)
                    }
                    return completionResult(
                        goal: lockedGoal, trace: fullTrace,
                        evidence: completionEvidence)
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
                        executed: observationTrace,
                        failedStep: "steps rejected before running: \(message)",
                        state: &carried))
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
                observationTrace.append(contentsOf: result.observationTrace)
                completionEvidence.record(result)
                // Runtime truth, not batch intent: only steps that actually
                // completed update the carried safety state.
                carried = ActionPlan.state(after: plan,
                                           executedCount: result.executedSteps,
                                           seed: carried)

                switch result.outcome {
                case .completed:
                    if done {
                        planner.end()
                        return completionResult(
                            goal: lockedGoal, trace: fullTrace,
                            evidence: completionEvidence)
                    }
                    guard turnsUsed < Self.maxTurns, host.now() < deadline else {
                        planner.end()
                        return .failed(
                            reason: "ran out of attempts before finishing",
                            trace: fullTrace)
                    }
                    asks += 1
                    reply = planner.observe(gatherObservation(
                        executed: observationTrace, failedStep: nil,
                        state: &carried))

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
                        executed: observationTrace,
                        failedStep: result.observationTrace.last ?? reason,
                        state: &carried))
                }
            }
        }
    }

    private func completionResult(
        goal: String,
        trace: [String],
        evidence: ActionCompletionEvidence
    ) -> ActionResult {
        guard evidence.hadEffect else {
            return .failed(
                reason: "the planner returned nothing effective to do",
                trace: trace)
        }
        return .performedUnverified(goal: goal, trace: trace)
    }

    /// What the model gets to look at between turns. Every string is read off
    /// the user's screen; the engine defangs each one before it reaches the
    /// prompt.
    private func gatherObservation(executed: [String],
                                   failedStep: String?,
                                   state: inout ActionPlan.BatchState) -> [String: Any] {
        let front = host.frontmostApp()
        if let name = front?.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.appNames.insert(name)
        }
        state.currentApp = front?.name ?? ""
        let visibleNames = host.visibleNames()
        let pageURL = host.frontmostPageURL() ?? ""
        if state.urlTokenPool != nil {
            // Names the user can see may enter the next search URL (screen
            // spelling); titles/selections never do. A host driving a window
            // the user cannot see contributes nothing here — those labels
            // are payloads, not spelling.
            let admissible = host.screenNamesAreUserVisible ? visibleNames : []
            state.urlTokenPool?.formUnion(
                ActionPlan.urlTokenPool(admissible + [pageURL]))
        }
        var observation: [String: Any] = [
            "frontmost_app": front?.name ?? "",
            "frontmost_bundle": front?.bundleID ?? "",
            "window_title": host.frontmostWindowTitle() ?? "",
            "focused_label": host.focusedElementLabel() ?? "",
            "focused_role": host.focusedElementRole() ?? "",
            "selection": host.focusedSelectionLabel() ?? "",
            "screen_names": visibleNames,
            "page_url": pageURL,
            "executed": executed,
        ]
        if let failedStep {
            observation["failed_step"] = failedStep
        }
        return observation
    }
}
