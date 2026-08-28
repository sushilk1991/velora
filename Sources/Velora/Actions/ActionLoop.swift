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
    private(set) var hadGoalVerification = false
    private(set) var hadAppOpen = false
    private(set) var hadOtherEffect = false
    private(set) var target: ActionCompletionTarget?
    private var effectTarget: ActionCompletionTarget?
    private(set) var localProof: ActionLocalProof?

    var provesGoal: Bool { hadGoalVerification }
    var onlyOpenedApp: Bool {
        hadAppOpen && !hadOtherEffect && !hadGoalVerification
    }

    mutating func record(_ result: ActionRunResult) {
        for event in result.evidence {
            events.append(event)
            switch event {
            case .appOpenRequested:
                invalidateProof()
                target = nil
                hadEffect = true
                hadAppOpen = true
            case .unverifiedEffect(let kind):
                invalidateProof()
                hadEffect = true
                hadOtherEffect = true
                if kind != .openURL, kind != .presentUI,
                   let target, target.pid != nil, target.windowID != nil {
                    effectTarget = target
                }
            case .goalVerified:
                hadEffect = true
                hadGoalVerification = true
                localProof = nil
            case .localGoalVerified(let proof):
                hadEffect = true
                hadGoalVerification = true
                localProof = proof
            case .stateVerified(let receipt, let expectedValue):
                guard hadEffect,
                      receiptMatchesEffect(receipt)
                else { continue }
                hadGoalVerification = true
                localProof = .state(
                    expectedValue: expectedValue,
                    appName: receipt.appName)
                target = ActionCompletionTarget(
                    appName: receipt.appName, bundleID: receipt.bundleID,
                    pid: receipt.pid, windowID: receipt.windowID,
                    processIdentity: receipt.processIdentity)
            case .targetResolved(let value):
                invalidateProof()
                target = value
            case .uiTargetVerified:
                break
            case .frontmostConfirmed(_, let actual, let bundleID):
                guard !actual.isEmpty, !bundleID.isEmpty else { continue }
                if let target, target.pid != nil, target.windowID != nil,
                   target.bundleID.caseInsensitiveCompare(bundleID)
                    == .orderedSame {
                    continue
                }
                invalidateProof()
                target = ActionCompletionTarget(
                    appName: actual,
                    bundleID: bundleID)
            }
        }
    }

    private mutating func invalidateProof() {
        hadGoalVerification = false
        localProof = nil
        effectTarget = nil
    }

    private func receiptMatchesEffect(_ receipt: ActionStateReceipt) -> Bool {
        guard receipt.pid > 0, receipt.windowID > 0,
              !receipt.appName.isEmpty, !receipt.bundleID.isEmpty,
              let effectTarget,
              effectTarget.bundleID.caseInsensitiveCompare(receipt.bundleID)
                == .orderedSame,
              effectTarget.pid == receipt.pid,
              effectTarget.windowID == receipt.windowID,
              effectTarget.processIdentity == receipt.processIdentity
        else { return false }
        return true
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
    private let progress: (ActionProgress) -> Void

    private let lock = NSLock()
    private var cancelledStorage = false
    private var currentExecutor: ActionExecutor?

    init(host: ActionHost, planner: ActionTurnPlanner,
         execute: Bool, allowSend: Bool,
         progress: @escaping (ActionProgress) -> Void = { _ in }) {
        self.host = host
        self.planner = planner
        self.execute = execute
        self.allowSend = allowSend
        self.progress = progress
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
        host.beginActionInputSession(command: transcript)
        let result = runSession(transcript: transcript, context: context)
        host.endActionInputSession()
        guard let reason = host.actionFailureReason else { return result }
        return .failed(reason: reason, trace: Self.resultTrace(result))
    }

    private static func resultTrace(_ result: ActionResult) -> [String] {
        switch result {
        case .completed(_, let trace, _),
             .ready(_, let trace, _),
             .performedUnverified(_, let trace, _),
             .failed(_, let trace):
            return trace
        case .planned, .needsSendApproval, .cancelled:
            return []
        }
    }

    private func runSession(
        transcript: String,
        context: ActionContextSnapshot
    ) -> ActionResult {
        progress(.readingScreen)
        var context = context
        context.uiSnapshot = host.uiSnapshot()
        var carried = ActionPlan.BatchState()
        carried.spokenCommand = transcript
        carried.requireUITargetVerification = true
        carried.structuredUIAvailable = context.uiSnapshot != nil
        carried.structuredUIComplete = context.uiSnapshot?.complete == true
        carried.structuredUISnapshot = context.uiSnapshot
        carried.appNames.formUnion(context.runningApps)
        carried.appNames.formUnion(context.knownApps)
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
        /// The last runtime failure a step actually hit, in the user's terms.
        var lastStepFailure: String?
        var lastRecoverablePlan: String?
        var repeatedRecoverablePlans = 0
        var lastSuccessfulProgress: String?
        var repeatedSuccessfulPlans = 0
        var turnsUsed = 0
        var planInvalidRetries = 0
        // Every planner call, accepted or rejected. Rejected turns consume no
        // engine turn, so this is the bound that stops a model stuck on an
        // invalid shape from being asked forever.
        var asks = 1
        let deadline = host.now() + Self.wallClockSeconds

        progress(.planning(turn: 1))
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
                   planInvalidRetries < 1,
                   asks < Self.maxTurns + 2, host.now() < deadline, !isCancelled {
                    planInvalidRetries += 1
                    asks += 1
                    progress(.retrying(reason))
                    progress(.readingScreen)
                    let observation = gatherObservation(
                        executed: observationTrace,
                        failedStep: "steps rejected before running: \(reason) "
                            + "— propose different steps",
                        state: &carried)
                    progress(.planning(turn: turnsUsed + 1))
                    reply = planner.observe(observation)
                    continue
                }
                planner.end()
                if code == "cancelled" { return .cancelled }
                // A session-lifecycle refusal describes the PROTOCOL, not the
                // action: "action: session already finished" told the user
                // nothing about the app having no text field on screen. Only
                // that class is substituted, and only by a failure from the
                // batch that just ran — a turn limit or an unavailable model
                // is the authoritative reason and must reach the user as
                // itself.
                if code == "no_session", let lastStepFailure {
                    return .failed(reason: lastStepFailure, trace: fullTrace)
                }
                return .failed(reason: reason, trace: fullTrace)

            case .turn(let sends, _, let stepsJSON, let done):
                turnsUsed += 1
                if lockedSends == nil {
                    // Decided here, never again: a later turn upgrading a
                    // draft into a send would sidestep the consent the caller
                    // actually gave.
                    lockedSends = sends
                    // The model may summarize the task but cannot redefine
                    // what the user asked. Mirror the engine's immutable
                    // spoken-command goal at the app boundary.
                    lockedGoal = String(ActionPlan.sanitize(transcript).prefix(200))
                }

                if stepsJSON.isEmpty {
                    if carried.pendingIndex != nil {
                        let message = ActionPlanError.stateProofRequired(step: 0).message
                        guard execute, turnsUsed < Self.maxTurns,
                              asks < Self.maxTurns + 2, host.now() < deadline
                        else {
                            planner.end()
                            return .failed(
                                reason: "fresh state proof was required before completion",
                                trace: fullTrace)
                        }
                        asks += 1
                        progress(.retrying(message))
                        progress(.readingScreen)
                        let observation = gatherObservation(
                            executed: observationTrace,
                            failedStep: "steps rejected before running: \(message)",
                            state: &carried)
                        progress(.planning(turn: turnsUsed + 1))
                        reply = planner.observe(observation)
                        continue
                    }
                    // A FIRST turn that reports done without doing anything is
                    // the planner shrugging. On later turns `done` may stop the
                    // loop, but only the accumulated executor evidence decides
                    // whether that stop is verified completion.
                    guard done, turnsUsed > 1 else {
                        planner.end()
                        return .failed(reason: "the planner returned nothing to do",
                                       trace: fullTrace)
                    }
                    if let target = routedTarget(
                        transcript: transcript,
                        state: carried,
                        sends: lockedSends
                    ) {
                        return .ready(
                            goal: lockedGoal,
                            trace: fullTrace,
                            target: target)
                    }
                    if needsOpenFollowUp(
                        command: transcript, state: carried,
                        evidence: completionEvidence
                    ), turnsUsed < Self.maxTurns,
                       asks < Self.maxTurns + 2, host.now() < deadline {
                        asks += 1
                        progress(.readingScreen)
                        let observation = gatherObservation(
                            executed: observationTrace, failedStep: nil,
                            state: &carried)
                        progress(.planning(turn: turnsUsed + 1))
                        reply = planner.observe(observation)
                        continue
                    }
                    planner.end()
                    return completionResult(
                        command: transcript, goal: lockedGoal, trace: fullTrace,
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
                    progress(.retrying(message))
                    progress(.readingScreen)
                    let observation = gatherObservation(
                        executed: observationTrace,
                        failedStep: "steps rejected before running: \(message)",
                        state: &carried)
                    progress(.planning(turn: turnsUsed + 1))
                    reply = planner.observe(observation)
                    continue
                }

                guard execute else {
                    planner.end()
                    return .planned(plan)
                }

                let executor = ActionExecutor(host: host, progress: progress)
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
                    lastRecoverablePlan = nil
                    repeatedRecoverablePlans = 0
                    // A batch that ran clean supersedes whatever went wrong
                    // before it; keeping the old reason would report a solved
                    // problem as the cause of a later one.
                    lastStepFailure = nil
                    // Background app-only requests get one fresh routed
                    // observation. The app comes forward only if the user
                    // later clicks the completion card.
                    let needsBackgroundProof = host.isDrivingInBackground
                        && ActionPlan.isAppOnlyPresentation(
                            transcript, appName: carried.currentApp,
                            bundleID: carried.structuredUISnapshot?.bundleID,
                            candidates: carried.appNames)
                    let shouldReplanOpen = done && needsOpenFollowUp(
                        command: transcript, state: carried,
                        evidence: completionEvidence)
                    // `wait_frontmost` already proved the routed app is
                    // ready. Recheck its exact PID/window now; requiring an
                    // empty planner turn made a valid result depend on luck.
                    if done, let target = routedTarget(
                        transcript: transcript,
                        state: carried,
                        sends: lockedSends
                    ) {
                        planner.end()
                        return .ready(
                            goal: lockedGoal,
                            trace: fullTrace,
                            target: target)
                    }
                    if done, completionEvidence.provesGoal
                        || (!needsBackgroundProof
                            && !shouldReplanOpen) {
                        planner.end()
                        return completionResult(
                            command: transcript, goal: lockedGoal,
                            trace: fullTrace,
                            evidence: completionEvidence)
                    }
                    guard turnsUsed < Self.maxTurns, host.now() < deadline else {
                        planner.end()
                        return .failed(
                            reason: "ran out of attempts before finishing",
                            trace: fullTrace)
                    }
                    asks += 1
                    progress(.readingScreen)
                    let observation = gatherObservation(
                        executed: observationTrace, failedStep: nil,
                        state: &carried)
                    let progressFingerprint = Self.planFingerprint(stepsJSON)
                        + "\n" + Self.observationFingerprint(observation)
                    if progressFingerprint == lastSuccessfulProgress {
                        repeatedSuccessfulPlans += 1
                    } else {
                        lastSuccessfulProgress = progressFingerprint
                        repeatedSuccessfulPlans = 1
                    }
                    if repeatedSuccessfulPlans >= 2 {
                        planner.end()
                        return .failed(
                            reason: "the agent repeated the same action without "
                                + "changing the target state",
                            trace: fullTrace)
                    }
                    progress(.planning(turn: turnsUsed + 1))
                    reply = planner.observe(observation)

                case .cancelled:
                    planner.end()
                    return .cancelled

                case .failed(_, let reason, let recoverable):
                    lastStepFailure = reason
                    guard recoverable, turnsUsed < Self.maxTurns,
                          host.now() < deadline, !isCancelled else {
                        planner.end()
                        return .failed(reason: reason, trace: fullTrace)
                    }
                    let fingerprint = Self.planFingerprint(stepsJSON)
                    if fingerprint == lastRecoverablePlan {
                        repeatedRecoverablePlans += 1
                    } else {
                        lastRecoverablePlan = fingerprint
                        repeatedRecoverablePlans = 1
                    }
                    if repeatedRecoverablePlans >= 2 {
                        planner.end()
                        return .failed(
                            reason: "the agent repeated the same failed action; "
                                + "the screen did not provide enough evidence to continue",
                            trace: fullTrace)
                    }
                    // The trace's last line says what the screen actually
                    // showed — that detail is what makes the next turn
                    // smarter than a retry.
                    asks += 1
                    progress(.retrying(reason))
                    progress(.readingScreen)
                    let observation = gatherObservation(
                        executed: observationTrace,
                        failedStep: result.observationTrace.last ?? reason,
                        state: &carried)
                    progress(.planning(turn: turnsUsed + 1))
                    reply = planner.observe(observation)
                }
            }
        }
    }

    /// Semantic fingerprint for loop detection. Snapshot IDs and verifier
    /// attestations are capabilities refreshed on every observation; ignoring
    /// them lets us recognize the same failed choice against a fresh tree.
    private static func planFingerprint(_ rawSteps: [Any]) -> String {
        let normalized: [[String: Any]] = rawSteps.compactMap { raw in
            guard var step = raw as? [String: Any] else { return nil }
            step.removeValue(forKey: "snapshot")
            step.removeValue(forKey: "attestation")
            return step
        }
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(
                withJSONObject: normalized, options: [.sortedKeys])
        else { return String(describing: rawSteps) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func observationFingerprint(
        _ observation: [String: Any]
    ) -> String {
        var stable = observation
        stable.removeValue(forKey: "executed")
        stable.removeValue(forKey: "failed_step")
        if var snapshot = stable["ui_snapshot"] as? [String: Any] {
            snapshot.removeValue(forKey: "id")
            stable["ui_snapshot"] = snapshot
        }
        guard JSONSerialization.isValidJSONObject(stable),
              let data = try? JSONSerialization.data(
                withJSONObject: stable, options: [.sortedKeys])
        else { return String(describing: stable) }
        return String(decoding: data, as: UTF8.self)
    }

    private func completionResult(
        command: String,
        goal: String,
        trace: [String],
        evidence: ActionCompletionEvidence
    ) -> ActionResult {
        guard evidence.hadEffect else {
            return .failed(
                reason: "the planner returned nothing effective to do",
                trace: trace)
        }
        let localProofCoversGoal = evidence.localProof.map {
            $0.covers(command)
        } ?? true
        if evidence.hadGoalVerification, localProofCoversGoal {
            return .completed(
                goal: goal,
                trace: trace,
                target: exactTarget(evidence.target))
        }
        return .performedUnverified(
            goal: goal,
            trace: trace,
            target: exactTarget(evidence.target))
    }

    private static func namesOtherApp(
        _ command: String, target: String, candidates: Set<String>
    ) -> Bool {
        let words = AppMatcher.words(command)
        let targetID = AppMatcher.normalize(target)

        return candidates.contains { candidate in
            guard AppMatcher.normalize(candidate) != targetID else {
                return false
            }
            let appWords = AppMatcher.words(candidate)
            guard !appWords.isEmpty, appWords.count <= words.count else {
                return false
            }

            return (0...(words.count - appWords.count)).contains { index in
                Array(words[index..<(index + appWords.count)]) == appWords
            }
        }
    }

    private func needsOpenFollowUp(
        command: String, state: ActionPlan.BatchState,
        evidence: ActionCompletionEvidence
    ) -> Bool {
        host.isDrivingInBackground
            && evidence.onlyOpenedApp
            && !Self.namesOtherApp(
                command, target: state.currentApp,
                candidates: state.appNames)
    }

    private func exactTarget(
        _ target: ActionCompletionTarget?
    ) -> ActionCompletionTarget? {
        guard let target, let window = host.actionWindow(),
              window.bundleID.caseInsensitiveCompare(target.bundleID)
                == .orderedSame
        else { return target }
        return ActionCompletionTarget(
            appName: window.name, bundleID: window.bundleID,
            pid: window.pid, windowID: window.windowID,
            processIdentity: window.processIdentity)
    }

    private func routedTarget(
        transcript: String,
        state: ActionPlan.BatchState,
        sends: Bool?
    ) -> ActionCompletionTarget? {
        guard sends == false,
              host.isDrivingInBackground,
              state.requireUITargetVerification,
              let process = host.actionProcess(),
              process.pid > 0,
              !process.name.isEmpty,
              !process.bundleID.isEmpty,
              ActionPlan.isAppOnlyPresentation(
                transcript,
                appName: process.name,
                bundleID: process.bundleID,
                candidates: state.appNames)
        else { return nil }
        guard let live = host.frontmostApp(),
              live.bundleID.caseInsensitiveCompare(process.bundleID)
                == .orderedSame,
              let confirmed = host.actionProcess(), confirmed == process
        else { return nil }
        guard let target = host.actionWindow() else {
            return ActionCompletionTarget(
                appName: process.name, bundleID: process.bundleID,
                pid: process.pid, windowID: nil,
                processIdentity: process.processIdentity)
        }
        // App-only readiness needs no element tree. Requiring one made the
        // safe completion card depend on Cua's mutation-shaped AX output.
        guard target.pid == process.pid,
              target.bundleID.caseInsensitiveCompare(process.bundleID)
                == .orderedSame,
              target.processIdentity == process.processIdentity,
              let finalLive = host.frontmostApp(),
              finalLive.bundleID.caseInsensitiveCompare(process.bundleID)
                == .orderedSame,
              let finalProcess = host.actionProcess(), finalProcess == process
        else { return nil }
        return ActionCompletionTarget(
            appName: process.name, bundleID: process.bundleID,
            pid: process.pid, windowID: target.windowID,
            processIdentity: process.processIdentity)
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
        let snapshot: ActionUISnapshot?
        let visibleNames: [String]
        let windowTitle: String
        let focusedLabel: String
        let focusedRole: String
        let selection: String
        let capabilities = host.mediaCapabilities()
        if host.isDrivingInBackground,
           let routed = capabilitySnapshot(
            host.uiSnapshot(), capabilities: capabilities, front: front) {
            // One immutable Cua tree supplies a planner observation. Safety
            // boundaries still take their own fresh snapshots before acting.
            snapshot = routed
            visibleNames = snapshotNames(routed)
            windowTitle = routed.windowTitle
            let focused = routed.elements.first(where: \.focused)
            focusedLabel = focused?.label ?? ""
            focusedRole = focused?.role ?? ""
            selection = ""
        } else {
            visibleNames = host.visibleNames()
            windowTitle = host.frontmostWindowTitle() ?? ""
            focusedLabel = host.focusedElementLabel() ?? ""
            focusedRole = host.focusedElementRole() ?? ""
            selection = host.focusedSelectionLabel() ?? ""
            snapshot = capabilitySnapshot(
                host.uiSnapshot(), capabilities: capabilities, front: front)
        }
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
            "window_title": windowTitle,
            "focused_label": focusedLabel,
            "focused_role": focusedRole,
            "selection": selection,
            "screen_names": visibleNames,
            "page_url": pageURL,
            "executed": executed,
        ]
        if let snapshot {
            state.structuredUIAvailable = true
            state.structuredUIComplete = snapshot.complete
            state.structuredUISnapshot = snapshot
            observation["ui_snapshot"] = snapshot.payload
        } else {
            state.structuredUIAvailable = false
            state.structuredUIComplete = false
            state.structuredUISnapshot = nil
        }
        if let failedStep {
            observation["failed_step"] = failedStep
        }
        return observation
    }

    private func capabilitySnapshot(
        _ snapshot: ActionUISnapshot?,
        capabilities: [ActionNativeCapability],
        front: (name: String, bundleID: String)?
    ) -> ActionUISnapshot? {
        guard !capabilities.isEmpty else { return snapshot }
        if let snapshot {
            return snapshot.addingCapabilities(capabilities)
        }
        guard let target = host.actionProcess(), target.pid > 0 else {
            return nil
        }
        if !host.isDrivingInBackground {
            guard let front,
                  front.bundleID.caseInsensitiveCompare(target.bundleID)
                    == .orderedSame else { return nil }
        }
        return ActionUISnapshot(
            id: "app-native-\(capabilities[0].id)", source: .appNative,
            appName: target.name, bundleID: target.bundleID,
            windowTitle: "", windowID: host.actionWindow()?.windowID,
            complete: false, elements: [], capabilities: capabilities)
    }

    private func snapshotNames(_ snapshot: ActionUISnapshot) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for element in snapshot.elements {
            guard let candidate = ScreenContext.nameCandidate(element.label ?? "")
            else { continue }
            if seen.insert(candidate.lowercased()).inserted {
                names.append(candidate)
            }
            if names.count >= 40 { break }
        }
        return names
    }
}
