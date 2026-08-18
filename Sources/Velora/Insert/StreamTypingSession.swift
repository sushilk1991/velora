import AppKit
import Foundation

/// Pure revision policy for a live draft. The UI adapter proves ownership;
/// this type ensures provisional updates only ever insert once or replace the
/// exact revision that was committed before them.
struct StreamDraftPlan {
    enum Abandonment: Equatable {
        case unavailable
        case ownershipLost
    }

    enum Operation: Equatable {
        case insert(String)
        case replace(previous: String, with: String)
        case noChange
        case abandon
    }

    private(set) var rendered: String?
    private(set) var isAbandoned = false
    private(set) var abandonment: Abandonment?

    mutating func next(_ text: String, ownershipValid: Bool) -> Operation {
        guard !isAbandoned else { return .abandon }
        guard ownershipValid else {
            isAbandoned = true
            abandonment = .ownershipLost
            return .abandon
        }
        guard let rendered else { return .insert(text) }
        guard rendered != text else { return .noChange }
        return .replace(previous: rendered, with: text)
    }

    mutating func commit(_ text: String) {
        guard !isAbandoned else { return }
        rendered = text
    }

    mutating func abandon() {
        isAbandoned = true
        if abandonment == nil {
            abandonment = rendered == nil ? .unavailable : .ownershipLost
        }
    }

    mutating func abandonAfterFailedDelivery(
        postedUTF16Units: Int, ownershipStillValid: Bool
    ) {
        isAbandoned = true
        abandonment = rendered != nil || postedUTF16Units > 0 || !ownershipStillValid
            ? .ownershipLost : .unavailable
    }
}

enum StreamFinalOutputStagingPolicy {
    static func stage(
        _ text: String, alreadyStaged: Bool, write: (String) -> Void
    ) {
        guard !alreadyStaged else { return }
        write(text)
    }
}

enum StreamInteractionGate {
    static func actionRequestIsBusy(
        phaseIsIdle: Bool,
        cancellationInFlight: Bool,
        actionIsRunning: Bool
    ) -> Bool {
        !phaseIsIdle || cancellationInFlight || actionIsRunning
    }
}

enum StreamTypingFinalPolicy {
    static func shouldRecordHistory(alreadyRecorded: Bool) -> Bool {
        !alreadyRecorded
    }

    static func voiceCommand(
        enabled: Bool, text: String, raw: String
    ) -> VoiceCommand? {
        guard enabled else { return nil }
        return VoiceCommand.parse(text: text, raw: raw)
    }

    enum RestorationDecision: Equatable {
        case restored
        case retry
        case failed
    }

    static func restorationDecision(
        originalIsCurrent: Bool, attemptsRemaining: Int
    ) -> RestorationDecision {
        if originalIsCurrent { return .restored }
        return attemptsRemaining > 0 ? .retry : .failed
    }

    static func commandMayExecute(
        after cancellation: StreamTypingSession.CancellationResult
    ) -> Bool {
        cancellation != .failed
    }

    static func shouldDeferFinal(
        session: String, cancellationSession: String?
    ) -> Bool {
        cancellationSession == session
    }
}

/// Owns one opt-in Stream Typing draft from the initial caret through the
/// authoritative polished final. Provisional text is typed with Unicode events
/// (never put on the clipboard); every revision is preceded by exact AX
/// element/range/text validation and a physical-input generation check.
final class StreamTypingSession {
    enum FinishResult: Equatable {
        case applied
        case unavailable
        case ownershipLost
    }

    enum CancellationResult: Equatable {
        case restored
        case noDraft
        case failed
    }

    private struct Request {
        let text: String
        let mode: String?
        let isFinal: Bool
        let completion: ((FinishResult) -> Void)?
    }

    private let target: ScreenStreamTarget?
    private let inputGeneration: UInt64
    private let inserter: TextInserter
    private var plan = StreamDraftPlan()
    private var pending: Request?
    private var busy = false
    private var cancelRequested = false
    private var cancelCompletion: ((CancellationResult) -> Void)?

    init(
        target: ScreenStreamTarget?,
        inputGeneration: UInt64 = UserInputActivity.snapshot(),
        inserter: TextInserter = TextInserter()
    ) {
        self.target = target
        self.inputGeneration = inputGeneration
        self.inserter = inserter
    }

    var hasRenderedDraft: Bool { plan.rendered != nil }

    func update(_ text: String, mode: String?) {
        guard target != nil, !cancelRequested, !plan.isAbandoned else { return }
        enqueue(Request(text: text, mode: mode, isFinal: false, completion: nil))
    }

    func finish(
        _ text: String, mode: String?, completion: @escaping (FinishResult) -> Void
    ) {
        guard target != nil else {
            completion(.unavailable)
            return
        }
        guard !cancelRequested else {
            completion(.ownershipLost)
            return
        }
        enqueue(Request(text: text, mode: mode, isFinal: true, completion: completion))
    }

    /// Best-effort cancellation removes only a still-owned draft and restores
    /// any selection it replaced. If ownership was lost, doing nothing is the
    /// only safe behavior.
    func cancel(completion: ((CancellationResult) -> Void)? = nil) {
        if let completion {
            let existing = cancelCompletion
            cancelCompletion = { result in
                existing?(result)
                completion(result)
            }
        }
        cancelRequested = true
        pending = nil
        guard !busy else { return }
        revertDraftIfOwned()
    }

    private func enqueue(_ request: Request) {
        if pending?.isFinal == true, !request.isFinal { return }
        pending = request
        drain()
    }

    private func drain() {
        guard !busy else { return }
        if cancelRequested {
            revertDraftIfOwned()
            return
        }
        guard let request = pending else { return }
        pending = nil
        guard let target else {
            request.completion?(.unavailable)
            return
        }

        let delivery = TextInsertionBoundary.adjusted(
            request.text, boundary: target.boundary, mode: request.mode)
        let ownershipValid = inputIsUnchanged && (
            plan.rendered.map { ScreenContext.streamOwnsDraft($0, target: target) }
                ?? ScreenContext.streamOriginalIsCurrent(target))
        let operation = plan.next(delivery, ownershipValid: ownershipValid)
        switch operation {
        case .abandon:
            request.completion?(finishResult(for: plan.abandonment))
            drain()
        case .noChange:
            request.completion?(.applied)
            drain()
        case .insert:
            typeRevision(
                delivery,
                replacing: target.originalText,
                target: target,
                request: request)
        case .replace(let previous, _):
            guard ScreenContext.selectStreamDraft(previous, target: target) else {
                plan.abandon()
                request.completion?(.ownershipLost)
                drain()
                return
            }
            typeRevision(
                delivery,
                replacing: previous,
                target: target,
                request: request)
        }
    }

    private func typeRevision(
        _ delivery: String,
        replacing selectedText: String,
        target: ScreenStreamTarget,
        request: Request
    ) {
        busy = true
        inserter.insertViaTypingDetailed(
            delivery,
            targetBundleID: target.bundleID,
            targetElement: target.element,
            initialDeliveryCheck: { [weak self] in
                guard let self, self.inputIsUnchanged else { return false }
                return ScreenContext.streamSelectionIsCurrent(
                    selectedText, target: target)
            },
            continuationDeliveryCheck: { [weak self] in
                self?.inputIsUnchanged == true
            }
        ) { [weak self] outcome in
            guard let self else { return }
            // Give the target's event loop one beat to apply the last Unicode
            // event, then prove the exact draft and caret before claiming it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let applied = outcome.completed
                    && self.inputIsUnchanged
                    && ScreenContext.streamOwnsDraft(delivery, target: target)
                self.busy = false
                if applied {
                    self.plan.commit(delivery)
                    if !self.cancelRequested {
                        request.completion?(.applied)
                    }
                } else {
                    let ownershipStillValid = self.inputIsUnchanged
                        && ScreenContext.streamSelectionIsCurrent(
                            selectedText, target: target)
                    self.plan.abandonAfterFailedDelivery(
                        postedUTF16Units: outcome.postedUTF16Units,
                        ownershipStillValid: ownershipStillValid)
                    let failure = self.finishResult(for: self.plan.abandonment)
                    if !self.cancelRequested {
                        request.completion?(failure)
                    }
                }
                self.drain()
            }
        }
    }

    private var inputIsUnchanged: Bool {
        inputGeneration == UserInputActivity.snapshot()
    }

    private func revertDraftIfOwned() {
        guard let rendered = plan.rendered else {
            let originalStillOwned: Bool
            if let target {
                originalStillOwned = inputIsUnchanged
                    && ScreenContext.streamOriginalIsCurrent(target)
            } else {
                // Unsupported targets never received provisional text.
                originalStillOwned = true
            }
            finishCancellation(
                plan.abandonment == .ownershipLost || !originalStillOwned
                    ? .failed : .noDraft)
            return
        }
        guard let target, inputIsUnchanged,
              ScreenContext.selectStreamDraft(rendered, target: target) else {
            finishCancellation(.failed)
            return
        }
        busy = true
        if target.originalText.isEmpty {
            guard inserter.pressKey(51) else {
                finishCancellation(.failed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.verifyRestoration(target: target, attemptsRemaining: 4)
            }
        } else {
            inserter.insertViaTyping(
                target.originalText,
                targetBundleID: target.bundleID,
                targetElement: target.element,
                initialDeliveryCheck: {
                    ScreenContext.streamSelectionIsCurrent(
                        rendered, target: target)
                },
                continuationDeliveryCheck: { [weak self] in
                    self?.inputIsUnchanged == true
                },
                completion: { [weak self] inserted in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        // Restore the exact selection, not merely its text and
                        // a caret after it. If ownership changed, fail closed.
                        guard inserted, self.inputIsUnchanged,
                              ScreenContext.selectStreamDraft(
                                target.originalText, target: target) else {
                            self.finishCancellation(.failed)
                            return
                        }
                        self.verifyRestoration(
                            target: target, attemptsRemaining: 4)
                    }
                })
        }
    }

    private func verifyRestoration(
        target: ScreenStreamTarget, attemptsRemaining: Int
    ) {
        guard inputIsUnchanged else {
            finishCancellation(.failed)
            return
        }
        switch StreamTypingFinalPolicy.restorationDecision(
            originalIsCurrent: ScreenContext.streamOriginalIsCurrent(target),
            attemptsRemaining: attemptsRemaining
        ) {
        case .restored:
            finishCancellation(.restored)
        case .failed:
            finishCancellation(.failed)
        case .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.verifyRestoration(
                    target: target, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func finishCancellation(_ result: CancellationResult) {
        busy = false
        plan.abandon()
        let completion = cancelCompletion
        cancelCompletion = nil
        completion?(result)
    }

    static func finishResultForFailedDelivery(
        hadRenderedDraft: Bool,
        postedUTF16Units: Int,
        ownershipStillValid: Bool = true
    ) -> FinishResult {
        hadRenderedDraft || postedUTF16Units > 0 || !ownershipStillValid
            ? .ownershipLost : .unavailable
    }

    private func finishResult(
        for abandonment: StreamDraftPlan.Abandonment?
    ) -> FinishResult {
        abandonment == .ownershipLost ? .ownershipLost : .unavailable
    }
}
