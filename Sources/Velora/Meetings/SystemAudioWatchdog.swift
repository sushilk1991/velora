import Foundation

/// Pure, deterministic health watchdog for the computer-audio (system) tap.
///
/// A process tap can die silently — the aggregate device stays open but no
/// buffers arrive — and the meeting then records mic-only without anyone
/// noticing. This state machine decides when the tap has stalled, when to
/// restart it (bounded: `maxRestartAttempts`, with exponential backoff
/// 1 s / 2 s / 4 s), and when to give up for good (`.lost`) instead of
/// looping forever. It owns no timers and no audio objects: callers feed it
/// frame timestamps and poll it, so every transition is reproducible in a
/// test with synthetic dates.
///
///     recordFrame ─► .healthy
///     .healthy ──(no frames for stallThreshold)──► .restarting(1)
///     .restarting(n) ──(backoff expires, still silent)──► .restarting(n+1)
///     .restarting(max) ──(backoff expires, still silent)──► .lost  (terminal)
///     .restarting(n) ──(frames resume)──► .reconnected(attemptsUsed: n)
///     .reconnected ──(next non-stalled poll/frame)──► .healthy
struct SystemAudioWatchdog: Equatable {
    enum State: Equatable {
        case healthy
        case restarting(attempt: Int)
        case reconnected(attemptsUsed: Int)
        case lost
    }

    enum Action: Equatable {
        case none
        /// Tear the tap down and start it again; `attempt` is 1-based.
        case restart(attempt: Int)
        /// Restarts are exhausted; surface the loss and stop trying.
        case lost
    }

    let stallThreshold: TimeInterval
    let maxRestartAttempts: Int

    private(set) var state: State = .healthy
    private(set) var lastFrameAt: Date?
    private(set) var restartAttempt = 0
    /// When the current restart attempt is judged failed if no frames have
    /// arrived by then (restart time + backoff for that attempt).
    private(set) var nextRetryAt: Date?

    init(stallThreshold: TimeInterval = 5.0, maxRestartAttempts: Int = 3) {
        self.stallThreshold = max(0, stallThreshold)
        self.maxRestartAttempts = max(1, maxRestartAttempts)
    }

    /// Exponential backoff between restart attempts: 1 s, 2 s, 4 s, …
    static func backoff(forAttempt attempt: Int) -> TimeInterval {
        pow(2.0, Double(max(1, attempt) - 1))
    }

    var isLost: Bool { state == .lost }

    /// User-facing status for the current state, or nil while healthy.
    var statusMessage: String? {
        switch state {
        case .healthy: return nil
        case .restarting: return "Computer audio reconnecting…"
        case .reconnected: return "Computer audio reconnected"
        case .lost: return "Computer audio lost"
        }
    }

    mutating func reset(at now: Date? = nil) {
        state = .healthy
        lastFrameAt = now
        restartAttempt = 0
        nextRetryAt = nil
    }

    /// Frames arrived from the tap. Resuming during a restart is the proof
    /// the restart worked; after `.lost` the watchdog stays terminal so a
    /// flapping tap cannot restart the loop.
    @discardableResult
    mutating func recordFrame(at now: Date) -> State {
        lastFrameAt = now
        if case .restarting(let attempt) = state {
            state = .reconnected(attemptsUsed: attempt)
            restartAttempt = 0
            nextRetryAt = nil
        } else if case .reconnected = state {
            state = .healthy
        }
        return state
    }

    /// Periodic check while recording. Returns `.restart` at most once per
    /// attempt (when the stall is first seen, then each time an attempt's
    /// backoff expires with no frames), and `.lost` exactly once.
    @discardableResult
    mutating func poll(at now: Date, recording: Bool = true) -> Action {
        guard recording, state != .lost else { return .none }
        switch state {
        case .healthy, .reconnected:
            guard let lastFrameAt else { return .none }
            guard now.timeIntervalSince(lastFrameAt) >= stallThreshold else {
                if case .reconnected = state { state = .healthy }
                return .none
            }
            return beginRestart(at: now)
        case .restarting:
            guard let nextRetryAt, now >= nextRetryAt else { return .none }
            guard restartAttempt < maxRestartAttempts else {
                state = .lost
                self.nextRetryAt = nil
                return .lost
            }
            return beginRestart(at: now)
        case .lost:
            return .none
        }
    }

    /// The lower capture layer already proved a stall (its own heartbeat
    /// saw no buffers), so skip the timestamp check and advance directly.
    /// Repeated stall reports while an attempt is still inside its backoff
    /// window are ignored, keeping the attempt count honest.
    @discardableResult
    mutating func handleStall(at now: Date) -> Action {
        switch state {
        case .lost:
            return .none
        case .restarting:
            if let nextRetryAt, now < nextRetryAt { return .none }
            guard restartAttempt < maxRestartAttempts else {
                state = .lost
                nextRetryAt = nil
                return .lost
            }
            return beginRestart(at: now)
        case .healthy, .reconnected:
            return beginRestart(at: now)
        }
    }

    /// A restart could not even start (tap creation threw). Keep the same
    /// attempt number and re-arm its backoff from `now`; the next poll at
    /// or after `nextRetryAt` moves to the following attempt or `.lost`.
    mutating func noteRestartFailed(at now: Date) {
        guard case .restarting(let attempt) = state else { return }
        nextRetryAt = now.addingTimeInterval(Self.backoff(forAttempt: attempt))
    }

    /// A terminal, non-stall failure (disk writer, format): restarting the
    /// tap cannot fix it, so go straight to `.lost`.
    mutating func markLost() {
        state = .lost
        nextRetryAt = nil
    }

    private mutating func beginRestart(at now: Date) -> Action {
        restartAttempt += 1
        guard restartAttempt <= maxRestartAttempts else {
            state = .lost
            nextRetryAt = nil
            return .lost
        }
        state = .restarting(attempt: restartAttempt)
        nextRetryAt = now.addingTimeInterval(Self.backoff(forAttempt: restartAttempt))
        return .restart(attempt: restartAttempt)
    }
}
