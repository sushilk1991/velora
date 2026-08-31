import AppKit
import Foundation

enum StreamTargetRouting {
    enum Route: Equatable {
        case accessibility
        case sublime
        case keystroke
        case preview
        case unavailable
    }

    static func route(
        bundleID: String?,
        nativeTargetAvailable: Bool,
        keystrokeTargetAvailable: Bool = false,
        previewTargetAvailable: Bool = false
    ) -> Route {
        if nativeTargetAvailable { return .accessibility }
        if bundleID == SublimeTextSelectionBridge.bundleID { return .sublime }
        if keystrokeTargetAvailable { return .keystroke }
        if previewTargetAvailable { return .preview }
        return .unavailable
    }
}

/// Minimal physical-key revision between two provisional transcripts. Swift
/// `Character` is used deliberately: one Backspace should remove one extended
/// grapheme (including an emoji sequence), not one UTF-8/UTF-16 code unit.
struct KeystrokeStreamRevision: Equatable {
    let deleteCount: Int
    let insertion: String

    static func delta(from old: String, to new: String) -> Self {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var common = 0
        while common < oldCharacters.count,
              common < newCharacters.count,
              oldCharacters[common] == newCharacters[common] {
            common += 1
        }
        return Self(
            deleteCount: oldCharacters.count - common,
            insertion: String(newCharacters.dropFirst(common)))
    }
}

enum KeystrokeStreamDraftPolicy {
    static let maxProvisionalCharacters = 500

    static func acceptsProvisional(_ text: String) -> Bool {
        text.count <= maxProvisionalCharacters
    }
}

enum StreamInputOwnership {
    static func isCurrent(_ capturedGeneration: UInt64) -> Bool {
        capturedGeneration == UserInputActivity.snapshot()
    }
}

enum StreamPreviewOwnershipPolicy {
    static func isCurrent(
        capturedGeneration: UInt64,
        currentGeneration: UInt64,
        capturedBundleID: String,
        frontmostBundleID: String?,
        focusedElementMatches: Bool
    ) -> Bool {
        capturedGeneration == currentGeneration
            && frontmostBundleID == capturedBundleID
            && focusedElementMatches
    }
}

enum SublimeStreamCancelRetryPolicy {
    static func shouldRetry(
        _ result: SublimeStreamCancelResult, attemptsRemaining: Int
    ) -> Bool {
        result == .unknown && attemptsRemaining > 0
    }
}

enum SublimeStreamCompletionPolicy {
    enum Source: Equatable {
        case current
        case pending
        case none
    }

    static func source(
        currentIsFinal: Bool, pendingIsFinal: Bool
    ) -> Source {
        if currentIsFinal { return .current }
        if pendingIsFinal { return .pending }
        return .none
    }

    static func completesCancellation(
        cancelRequested: Bool, duringOwnershipRestore: Bool
    ) -> Bool {
        cancelRequested && duringOwnershipRestore
    }
}

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
    static func selectionEditIsBusy(
        phaseIsIdle: Bool,
        cancellationInFlight: Bool,
        actionIsRunning: Bool
    ) -> Bool {
        !phaseIsIdle || cancellationInFlight || actionIsRunning
    }

    static func actionRequestIsBusy(
        phaseIsIdle: Bool,
        cancellationInFlight: Bool,
        actionIsRunning: Bool
    ) -> Bool {
        selectionEditIsBusy(
            phaseIsIdle: phaseIsIdle,
            cancellationInFlight: cancellationInFlight,
            actionIsRunning: actionIsRunning)
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
        let wasAbandoned = plan.isAbandoned
        let operation = plan.next(delivery, ownershipValid: ownershipValid)
        switch operation {
        case .abandon:
            if !wasAbandoned {
                NSLog("Velora: stream draft abandoned in %@ before typing — "
                      + "ownership check failed (userInput=%@, hadDraft=%@)",
                      target.bundleID,
                      inputIsUnchanged ? "unchanged" : "changed",
                      plan.rendered == nil ? "no" : "yes")
            }
            request.completion?(finishResult(for: plan.abandonment))
            drain()
        case .noChange:
            request.completion?(.applied)
            drain()
        case .insert:
            typeRevision(
                delivery,
                replacing: target.originalText,
                selectionIsOurs: false,
                target: target,
                request: request)
        case .replace(let previous, _):
            // Confirming the selection can take a beat on a Chromium-backed
            // target, so this is asynchronous — which means a cancel or a newer
            // partial can now arrive mid-flight. Hold the queue with `busy`
            // exactly as a running revision would.
            busy = true
            ScreenContext.selectStreamDraft(previous, target: target) {
                [weak self] selected in
                guard let self else { return }
                self.busy = false
                guard !self.cancelRequested else {
                    // Esc landed while we waited. The revert path owns the
                    // draft from here.
                    self.drain()
                    return
                }
                guard selected else {
                    NSLog("Velora: stream draft lost — could not reselect the "
                          + "%ld-char draft in %@ (%@)",
                          previous.count, target.bundleID,
                          ScreenContext.streamDraftOwnershipDiagnosis(
                            previous, target: target))
                    self.plan.abandon()
                    request.completion?(.ownershipLost)
                    // The selection may still land after the verify gave up.
                    // Put the caret back so an abandoned draft is never left
                    // highlighted for the user's next keystroke to erase.
                    ScreenContext.collapseStreamDraftSelection(
                        previous, target: target,
                        ownedAtGeneration: self.inputGeneration
                    ) { [weak self] in
                        self?.drain()
                    }
                    return
                }
                self.typeRevision(
                    delivery,
                    replacing: previous,
                    selectionIsOurs: true,
                    target: target,
                    request: request)
            }
        }
    }

    private func typeRevision(
        _ delivery: String,
        replacing selectedText: String,
        selectionIsOurs: Bool,
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
                // Settle rather than read once: the same asynchronous
                // Chromium/Electron accessibility that delays a selection also
                // delays the typed text and caret becoming readable. A
                // delivery that never happened skips the wait entirely.
                let mayHaveApplied = outcome.completed && self.inputIsUnchanged
                let confirm: (@escaping (Bool) -> Void) -> Void = { done in
                    guard mayHaveApplied else {
                        done(false)
                        return
                    }
                    ScreenContext.settle(until: {
                        ScreenContext.streamOwnsDraft(delivery, target: target)
                    }, completion: done)
                }
                confirm { applied in
                // `busy` stays set across the confirmation above, so a partial
                // arriving mid-wait queues instead of interleaving.
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
                    NSLog("Velora: stream draft abandoned in %@ — typed=%@ "
                          + "posted=%ld/%ld userInputUnchanged=%@ ownsDraft=%@",
                          target.bundleID,
                          outcome.completed ? "yes" : "no",
                          outcome.postedUTF16Units, delivery.utf16.count,
                          self.inputIsUnchanged ? "yes" : "no",
                          ScreenContext.streamOwnsDraft(delivery, target: target)
                              ? "yes" : "no")
                    self.plan.abandonAfterFailedDelivery(
                        postedUTF16Units: outcome.postedUTF16Units,
                        ownershipStillValid: ownershipStillValid)
                    let failure = self.finishResult(for: self.plan.abandonment)
                    if !self.cancelRequested {
                        request.completion?(failure)
                    }
                    if selectionIsOurs, outcome.postedUTF16Units == 0 {
                        // Nothing was typed over the selection Velora made, so
                        // restoring the caret restores exactly what the user
                        // had before this revision started. Refuses on its own
                        // if the input generation moved — this path is reached
                        // precisely when it may have.
                        ScreenContext.collapseStreamDraftSelection(
                            selectedText, target: target,
                            ownedAtGeneration: self.inputGeneration
                        ) { [weak self] in
                            self?.drain()
                        }
                        return
                    }
                }
                self.drain()
                }
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
        guard let target, inputIsUnchanged else {
            finishCancellation(.failed)
            return
        }
        // Held across the asynchronous reselect so a partial arriving mid-Esc
        // cannot start a revision on top of the restoration.
        busy = true
        ScreenContext.selectStreamDraft(rendered, target: target) {
            [weak self] selected in
            guard let self else { return }
            guard selected else {
                self.finishCancellation(.failed)
                return
            }
            self.restoreOverSelectedDraft(rendered, target: target)
        }
    }

    private func restoreOverSelectedDraft(
        _ rendered: String, target: ScreenStreamTarget
    ) {
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
                        guard inserted, self.inputIsUnchanged else {
                            self.finishCancellation(.failed)
                            return
                        }
                        ScreenContext.selectStreamDraft(
                            target.originalText, target: target
                        ) { [weak self] restored in
                            guard let self else { return }
                            guard restored else {
                                self.finishCancellation(.failed)
                                return
                            }
                            self.verifyRestoration(
                                target: target, attemptsRemaining: 4)
                        }
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

/// Live-draft adapter for ordinary editable controls that accept physical key
/// events but do not expose a mutable AX selection range. It keeps the smallest
/// grapheme suffix revision, then verifies only the bounded draft and caret.
/// It stops permanently if the app, focused element, draft, Secure Input state,
/// or observed physical-input generation changes.
final class KeystrokeStreamTypingSession: LiveStreamDraftSession {
    typealias RevisionDelivery = (
        KeystrokeStreamRevision,
        @escaping () -> Bool,
        @escaping (Int) -> Bool,
        @escaping (TextInserter.KeystrokeRevisionOutcome) -> Void
    ) -> Void

    private struct Request {
        let text: String
        let mode: String?
        let isFinal: Bool
        let completion: ((StreamTypingSession.FinishResult) -> Void)?
    }

    private let target: ScreenKeystrokeStreamTarget
    private let inputGeneration: UInt64
    private let ownershipCheck: (String) -> Bool
    private let safetyCheck: () -> Bool
    private let revisionDelivery: RevisionDelivery
    private var plan = StreamDraftPlan()
    private var pending: Request?
    private var busy = false
    private var cancelRequested = false
    private var cancelCompletion:
        ((StreamTypingSession.CancellationResult) -> Void)?

    init(
        target: ScreenKeystrokeStreamTarget,
        inputGeneration: UInt64 = UserInputActivity.snapshot(),
        inserter: TextInserter = TextInserter(),
        ownershipCheck: ((String) -> Bool)? = nil,
        safetyCheck: (() -> Bool)? = nil,
        revisionDelivery: RevisionDelivery? = nil
    ) {
        self.target = target
        self.inputGeneration = inputGeneration
        self.ownershipCheck = ownershipCheck ?? { draft in
            ScreenContext.keystrokeStreamOwnsDraft(
                draft, target: target)
        }
        self.safetyCheck = safetyCheck ?? { !SecureInput.isActive }
        self.revisionDelivery = revisionDelivery ?? {
            revision, deliveryCheck, deletionProgressCheck, completion in
            inserter.applyKeystrokeRevisionDetailed(
                revision,
                targetBundleID: target.bundleID,
                targetElement: target.element,
                deliveryCheck: deliveryCheck,
                deletionProgressCheck: deletionProgressCheck,
                completion: completion)
        }
    }

    var hasRenderedDraft: Bool { plan.rendered != nil }

    func update(_ text: String, mode: String?) {
        guard !cancelRequested, !plan.isAbandoned,
              KeystrokeStreamDraftPolicy.acceptsProvisional(text)
        else { return }
        enqueue(Request(
            text: text, mode: mode, isFinal: false, completion: nil))
    }

    func finish(
        _ text: String,
        mode: String?,
        completion: @escaping (StreamTypingSession.FinishResult) -> Void
    ) {
        guard !cancelRequested else {
            completion(.ownershipLost)
            return
        }
        guard !plan.isAbandoned else {
            completion(finishResult)
            return
        }
        guard KeystrokeStreamDraftPolicy.acceptsProvisional(text) else {
            // Do not create a multi-second Backspace liability. Remove the
            // still-verified bounded draft, then let the controller deliver
            // the long final once through its normal paste path.
            cancel { result in
                completion(result == .failed ? .ownershipLost : .unavailable)
            }
            return
        }
        enqueue(Request(
            text: text, mode: mode, isFinal: true, completion: completion))
    }

    func cancel(
        completion: ((StreamTypingSession.CancellationResult) -> Void)? = nil
    ) {
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

        let delivery = TextInsertionBoundary.adjusted(
            request.text,
            boundary: target.boundary,
            mode: request.mode)
        let ownershipValid = targetIsCurrent(plan.rendered ?? "")
        let operation = plan.next(delivery, ownershipValid: ownershipValid)
        switch operation {
        case .abandon:
            request.completion?(finishResult)
            drain()
        case .noChange:
            request.completion?(.applied)
            drain()
        case .insert:
            apply(delivery, replacing: "", request: request)
        case .replace(let previous, _):
            apply(delivery, replacing: previous, request: request)
        }
    }

    private func apply(
        _ delivery: String,
        replacing previous: String,
        request: Request
    ) {
        let revision = KeystrokeStreamRevision.delta(
            from: previous, to: delivery)
        let previousCharacters = Array(previous)
        busy = true
        revisionDelivery(
            revision,
            { [weak self] in self?.inputIsUnchanged == true },
            { [weak self] deletedCount in
                guard let self,
                      deletedCount <= previousCharacters.count
                else { return false }
                return self.targetIsCurrent(String(
                    previousCharacters.dropLast(deletedCount)))
            }
        ) { [weak self] outcome in
            guard let self else { return }
            // Same asynchronous-accessibility hazard as the AX route: a
            // Chromium-backed field updates the caret this check reads from
            // another process, after this callback. Settle on the ownership
            // read only — the input-generation and Secure Input guards are
            // decided facts, and re-checked after the wait so a keystroke
            // during it still fails closed.
            let confirm: (@escaping (Bool) -> Void) -> Void = { done in
                guard outcome.completed else {
                    done(self.targetIsCurrent(previous))
                    return
                }
                guard self.inputIsUnchanged, self.safetyCheck() else {
                    done(false)
                    return
                }
                ScreenContext.settle(until: { self.ownershipCheck(delivery) }) {
                    owns in
                    // Re-check after the wait: the run loop kept turning, so a
                    // keystroke during it is visible here and must still lose.
                    done(owns && self.inputIsUnchanged && self.safetyCheck())
                }
            }
            confirm { ownershipStillValid in
            self.busy = false
            if outcome.completed, ownershipStillValid {
                self.plan.commit(delivery)
                if !self.cancelRequested {
                    request.completion?(.applied)
                }
            } else if !request.isFinal,
                      !outcome.postedAnyEvent,
                      ownershipStillValid {
                // A transient delivery refusal before a partial posted
                // anything leaves the previously verified draft untouched.
                // Keep the session live so the next partial/final can retry.
            } else {
                self.plan.abandonAfterFailedDelivery(
                    postedUTF16Units: outcome.postedAnyEvent ? 1 : 0,
                    ownershipStillValid: ownershipStillValid)
                if !self.cancelRequested {
                    request.completion?(self.finishResult)
                }
            }
            self.drain()
            }
        }
    }

    private func revertDraftIfOwned() {
        guard !plan.isAbandoned else {
            finishCancellation(.failed)
            return
        }
        guard let rendered = plan.rendered else {
            finishCancellation(targetIsCurrent("") ? .noDraft : .failed)
            return
        }
        guard targetIsCurrent(rendered) else {
            finishCancellation(.failed)
            return
        }

        busy = true
        let renderedCharacters = Array(rendered)
        revisionDelivery(
            KeystrokeStreamRevision.delta(from: rendered, to: ""),
            { [weak self] in self?.inputIsUnchanged == true },
            { [weak self] deletedCount in
                guard let self,
                      deletedCount <= renderedCharacters.count
                else { return false }
                return self.targetIsCurrent(String(
                    renderedCharacters.dropLast(deletedCount)))
            }
        ) { [weak self] outcome in
            guard let self else { return }
            self.finishCancellation(
                outcome.completed && self.targetIsCurrent("")
                    ? .restored : .failed)
        }
    }

    private func targetIsCurrent(_ expectedDraft: String) -> Bool {
        inputIsUnchanged
            && safetyCheck()
            && ownershipCheck(expectedDraft)
    }

    private var inputIsUnchanged: Bool {
        inputGeneration == UserInputActivity.snapshot()
    }

    private var finishResult: StreamTypingSession.FinishResult {
        plan.abandonment == .ownershipLost ? .ownershipLost : .unavailable
    }

    private func finishCancellation(
        _ result: StreamTypingSession.CancellationResult
    ) {
        busy = false
        plan.abandon()
        let completion = cancelCompletion
        cancelCompletion = nil
        completion?(result)
    }
}

protocol LiveStreamDraftSession: AnyObject {
    var hasRenderedDraft: Bool { get }
    var finalInsertionTarget: ScreenStreamPreviewTarget? { get }
    func update(_ text: String, mode: String?)
    func finish(
        _ text: String,
        mode: String?,
        completion: @escaping (StreamTypingSession.FinishResult) -> Void)
    func cancel(
        completion: ((StreamTypingSession.CancellationResult) -> Void)?)
}

extension LiveStreamDraftSession {
    var finalInsertionTarget: ScreenStreamPreviewTarget? { nil }
}

extension StreamTypingSession: LiveStreamDraftSession {}

/// Safe fallback for terminal and canvas-backed inputs whose live text is not
/// readable through Accessibility. Provisional revisions stay inside Velora's
/// HUD; the authoritative final is inserted once by the normal delivery path.
/// This deliberately never sends blind Backspaces into an opaque field.
final class StreamPreviewTypingSession: LiveStreamDraftSession {
    let finalInsertionTarget: ScreenStreamPreviewTarget?
    private let ownershipCheck: () -> Bool
    private let render: (String) -> Void
    private var rendered = ""

    init(
        target: ScreenStreamPreviewTarget,
        inputGeneration: UInt64 = UserInputActivity.snapshot(),
        ownershipCheck: (() -> Bool)? = nil,
        render: @escaping (String) -> Void
    ) {
        self.finalInsertionTarget = target
        self.ownershipCheck = ownershipCheck ?? {
            ScreenContext.streamPreviewTargetIsCurrent(
                target,
                inputGeneration: inputGeneration)
        }
        self.render = render
    }

    var hasRenderedDraft: Bool { !rendered.isEmpty }

    func update(_ text: String, mode: String?) {
        guard text != rendered else { return }
        rendered = text
        render(text)
    }

    func finish(
        _ text: String,
        mode: String?,
        completion: @escaping (StreamTypingSession.FinishResult) -> Void
    ) {
        rendered = ""
        render("")
        guard ownershipCheck() else {
            completion(.ownershipLost)
            return
        }
        // No target draft exists to replace. Ask the controller to use the
        // normal final-only insertion path after clearing the preview.
        completion(.unavailable)
    }

    func cancel(
        completion: ((StreamTypingSession.CancellationResult) -> Void)?
    ) {
        rendered = ""
        render("")
        completion?(.noDraft)
    }
}

/// Live-draft adapter for Sublime's opaque editor surface. All document reads
/// and mutations stay inside the authenticated plugin; socket work runs on a
/// serial background queue and only publishes state changes back on main.
final class SublimeStreamTypingSession: LiveStreamDraftSession {
    private enum RestoreReason {
        case cancellation
        case ownershipLoss(((StreamTypingSession.FinishResult) -> Void)?)
    }

    private struct Request {
        let text: String
        let mode: String?
        let isFinal: Bool
        let completion: ((StreamTypingSession.FinishResult) -> Void)?
    }

    private let boundary: TextSelectionBoundary
    private let token: SublimeStreamTypingToken
    private let inputGeneration: UInt64
    private let queue = DispatchQueue(
        label: "com.velora.sublime-stream", qos: .userInitiated)
    private var plan = StreamDraftPlan()
    private var pending: Request?
    private var busy = false
    private var cancelRequested = false
    private var cancelCompletion:
        ((StreamTypingSession.CancellationResult) -> Void)?

    init(
        capture: SublimeStreamTypingCapture,
        inputGeneration: UInt64
    ) {
        boundary = capture.boundary
        token = capture.token
        self.inputGeneration = inputGeneration
    }

    var hasRenderedDraft: Bool { plan.rendered != nil }

    func update(_ text: String, mode: String?) {
        guard !cancelRequested, !plan.isAbandoned else { return }
        enqueue(Request(
            text: text, mode: mode, isFinal: false, completion: nil))
    }

    func finish(
        _ text: String,
        mode: String?,
        completion: @escaping (StreamTypingSession.FinishResult) -> Void
    ) {
        guard !cancelRequested, !plan.isAbandoned else {
            completion(.ownershipLost)
            return
        }
        enqueue(Request(
            text: text, mode: mode, isFinal: true, completion: completion))
    }

    func cancel(
        completion: ((StreamTypingSession.CancellationResult) -> Void)? = nil
    ) {
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
        restore(reason: .cancellation)
    }

    private func enqueue(_ request: Request) {
        if pending?.isFinal == true, !request.isFinal { return }
        pending = request
        drain()
    }

    private func drain() {
        guard !busy else { return }
        if cancelRequested {
            restore(reason: .cancellation)
            return
        }
        guard let request = pending else { return }
        pending = nil
        let delivery = TextInsertionBoundary.adjusted(
            request.text, boundary: boundary, mode: request.mode)
        let operation = plan.next(
            delivery,
            ownershipValid: StreamInputOwnership.isCurrent(inputGeneration))
        switch operation {
        case .abandon:
            pending = nil
            restore(reason: .ownershipLoss(request.completion))
        case .noChange where !request.isFinal:
            drain()
        case .insert, .replace, .noChange:
            deliver(delivery, request: request)
        }
    }

    private func deliver(_ text: String, request: Request) {
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            // Keep the plugin session restorable until the main-thread owner
            // accepts the final. This closes the Esc-vs-final response race.
            let result = self.token.update(text, final: false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard result == .applied else {
                    self.plan.abandon()
                    let finishCompletion = self.finishCompletion(
                        current: request)
                    self.pending = nil
                    if self.cancelRequested {
                        self.restore(reason: .cancellation)
                    } else {
                        self.restore(
                            reason: .ownershipLoss(finishCompletion))
                    }
                    return
                }
                self.plan.commit(text)
                if self.cancelRequested {
                    self.restore(reason: .cancellation)
                    return
                }
                guard StreamInputOwnership.isCurrent(self.inputGeneration) else {
                    self.plan.abandon()
                    let finishCompletion = self.finishCompletion(
                        current: request)
                    self.pending = nil
                    self.restore(
                        reason: .ownershipLoss(finishCompletion))
                    return
                }
                if request.isFinal {
                    self.token.finish()
                    request.completion?(.applied)
                }
                self.drain()
            }
        }
    }

    private func restore(
        attemptsRemaining: Int = 4,
        reason: RestoreReason
    ) {
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.token.cancel()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if SublimeStreamCancelRetryPolicy.shouldRetry(
                    result, attemptsRemaining: attemptsRemaining
                ) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.restore(
                            attemptsRemaining: attemptsRemaining - 1,
                            reason: reason)
                    }
                    return
                }
                switch reason {
                case .ownershipLoss(let completion):
                    self.busy = false
                    self.plan.abandon()
                    completion?(.ownershipLost)
                    if SublimeStreamCompletionPolicy.completesCancellation(
                        cancelRequested: self.cancelRequested,
                        duringOwnershipRestore: true
                    ) {
                        self.finishCancellation(
                            Self.cancellationResult(for: result))
                    }
                    return
                case .cancellation:
                    break
                }
                switch result {
                case .restored:
                    self.finishCancellation(.restored)
                case .noDraft:
                    self.finishCancellation(.noDraft)
                case .failed:
                    self.finishCancellation(.failed)
                case .unknown:
                    self.finishCancellation(.failed)
                }
            }
        }
    }

    private func finishCancellation(
        _ result: StreamTypingSession.CancellationResult
    ) {
        busy = false
        plan.abandon()
        let completion = cancelCompletion
        cancelCompletion = nil
        completion?(result)
    }

    private func finishCompletion(
        current: Request
    ) -> ((StreamTypingSession.FinishResult) -> Void)? {
        switch SublimeStreamCompletionPolicy.source(
            currentIsFinal: current.isFinal,
            pendingIsFinal: pending?.isFinal == true
        ) {
        case .current:
            return current.completion
        case .pending:
            return pending?.completion
        case .none:
            return nil
        }
    }

    private static func cancellationResult(
        for result: SublimeStreamCancelResult
    ) -> StreamTypingSession.CancellationResult {
        switch result {
        case .restored:
            return .restored
        case .noDraft:
            return .noDraft
        case .failed, .unknown:
            return .failed
        }
    }
}
