import Foundation

/// The already-audited action kernel as seen by the new agent lifecycle.
/// Keeping this protocol narrow makes the ownership boundary explicit: the
/// agent may schedule a task, observe events, or cancel; it never receives an
/// `ActionHost` and therefore cannot bypass Swift validation or execution.
protocol AgentActionCoordinating: AnyObject {
    var isRunning: Bool { get }
    var isExecuting: Bool { get }
    var activeActionID: String? { get }
    func perform(
        transcript: String,
        context: ActionContextSnapshot,
        execute: Bool,
        allowSend: Bool,
        completion: @escaping (ActionResult) -> Void
    )
    func cancel()
    func handle(_ event: EngineEvent)
}

extension ActionCoordinator: AgentActionCoordinating {}

/// Separate logical lifecycle for Agent Mode.
///
/// This owns task identity, durable receipts, cancellation and future planner
/// selection. `ActionCoordinator` remains the sole bridge into the privileged
/// ActionLoop/ActionExecutor kernel. Version one intentionally reuses the
/// already-loaded cleanup model so enabling Agent Mode adds no resident model.
final class AgentSessionManager {
    private let core: AgentActionCoordinating
    private let store: AgentTaskStore
    private var activeTaskID: String?
    private var startedAt: TimeInterval?

    convenience init(
        client: EngineClient,
        host: ActionHost,
        store: AgentTaskStore = AgentTaskStore()
    ) {
        self.init(core: ActionCoordinator(client: client, host: host), store: store)
    }

    init(core: AgentActionCoordinating, store: AgentTaskStore) {
        self.core = core
        self.store = store
    }

    /// Includes the short receipt-commit tail after the executor has stopped.
    /// A successor cannot start until the prior task is durably finalized.
    var isRunning: Bool { core.isRunning || activeTaskID != nil }
    var isExecuting: Bool { core.isExecuting }

    func perform(
        transcript: String,
        context: ActionContextSnapshot,
        execute: Bool = true,
        allowSend: Bool = true,
        completion: @escaping (ActionResult) -> Void
    ) {
        guard !core.isRunning, activeTaskID == nil else {
            completion(.failed(reason: "another action is already running", trace: []))
            return
        }

        let started = store.begin(
            command: transcript,
            context: context,
            execute: execute,
            allowSend: allowSend)
        guard case .success(let taskID) = started else {
            completion(.failed(
                reason: "the private local agent ledger is unavailable",
                trace: []))
            return
        }
        activeTaskID = taskID
        startedAt = ProcessInfo.processInfo.systemUptime

        core.perform(
            transcript: transcript,
            context: context,
            execute: execute,
            allowSend: allowSend
        ) { [weak self] result in
            guard let self else {
                completion(result)
                return
            }
            let elapsed = max(
                0,
                Int(((ProcessInfo.processInfo.systemUptime - (self.startedAt ?? 0))
                     * 1_000).rounded()))
            guard let active = self.activeTaskID else {
                completion(result)
                return
            }
            self.store.finish(
                taskID: active,
                result: result,
                durationMs: elapsed
            ) { [weak self] committed in
                let delivered = committed
                    ? result
                    : Self.receiptFailure(after: result)
                guard let self else {
                    completion(delivered)
                    return
                }
                guard self.activeTaskID == active else { return }
                self.activeTaskID = nil
                self.startedAt = nil
                completion(delivered)
            }
        }
    }

    func cancel() {
        if let activeTaskID { store.recordCancelRequested(taskID: activeTaskID) }
        core.cancel()
    }

    func handle(_ event: EngineEvent) {
        if let activeTaskID, let activeActionID = core.activeActionID,
           case .actionTurn(let eventID, let turn, let sends, let goal,
                            let steps, _, let durationMs) = event,
           eventID == activeActionID {
            store.recordTurn(
                taskID: activeTaskID,
                turn: turn,
                sends: sends,
                goal: goal,
                stepCount: steps.count,
                durationMs: durationMs)
        }
        core.handle(event)
    }

    private static func receiptFailure(after result: ActionResult) -> ActionResult {
        let trace: [String]
        switch result {
        case .planned(let plan), .needsSendApproval(let plan):
            trace = plan.describedSteps
        case .completed(_, let lines), .performedUnverified(_, let lines),
             .failed(_, let lines):
            trace = lines
        case .cancelled:
            trace = []
        }
        return .failed(
            reason: "the action ended, but Velora could not save its local receipt",
            trace: trace)
    }
}
