import Foundation
import SwiftUI

/// HUD capsule states (design brief §1.2). One capsule morphs between them;
/// `hidden` carries an exit style because success and cancel dismiss with
/// different animations ("success bounces, cancellation doesn't").
enum HUDState: Equatable {
    enum ExitStyle: Equatable {
        /// hold 600 ms, easeOut 0.25s, opacity→0, scale→0.85
        case success
        /// easeOut 0.18s, opacity→0, scale→0.9, +8 pt down — no bounce
        case cancel
    }

    case hidden(ExitStyle)
    case listening
    case transcribing
    case inserted
    case error(String)

    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }
}

/// Observable state driving the HUD view. Main-actor only.
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden(.cancel)
    /// Set when recording starts; drives the m:ss timer text.
    @Published var recordingStart: Date?

    /// Waveform levels (not @Published — the Canvas polls it every frame via
    /// TimelineView; publishing per audio buffer would churn SwiftUI).
    let levels = WaveformLevelStore()

    /// Invoked by the error-state "Retry" button.
    var onRetry: (() -> Void)?
}

/// Ring buffer of the last 24 loudness levels (one per waveform bar) plus the
/// per-frame asymmetric smoothing state (design brief §2).
///
/// `push` happens on the main queue (audio level callback); `displayHeights`
/// is called from the Canvas draw closure each frame (also main). The lock
/// guards against any off-main access without imposing structure on callers.
final class WaveformLevelStore {
    static let barCount = 24

    private let lock = NSLock()
    private var targets = [Float](repeating: 0, count: WaveformLevelStore.barCount)
    private var display = [CGFloat](repeating: 4, count: WaveformLevelStore.barCount)
    private var latestLevel: Float = 0

    /// Appends a new level (0…1); the oldest bar falls off the left edge.
    func push(_ level: Float) {
        lock.lock()
        targets.removeFirst()
        targets.append(level)
        latestLevel = level
        lock.unlock()
    }

    /// Clears all bars (called when a new recording starts).
    func reset() {
        lock.lock()
        targets = [Float](repeating: 0, count: Self.barCount)
        display = [CGFloat](repeating: 4, count: Self.barCount)
        latestLevel = 0
        lock.unlock()
    }

    /// Computes this frame's bar heights, advancing the smoothing state.
    ///
    /// - `settle == false` (listening): bars chase `4 + level*24` pt with fast
    ///   attack (k=0.55) / slow decay (k=0.12). Near-silence (< 0.03) drives a
    ///   gentle standing wave so the HUD still reads "listening".
    /// - `settle == true` (transcribing): all bars ease to the 4 pt floor.
    func displayHeights(settle: Bool, time: TimeInterval) -> [CGFloat] {
        lock.lock()
        defer { lock.unlock() }

        let idle = latestLevel < 0.03
        for i in 0..<Self.barCount {
            let target: CGFloat
            if settle {
                target = 4
            } else if idle {
                // standing wave: 4 + 2·sin(t·2π·0.8 + i·0.5)
                target = 4 + 2 * CGFloat(sin(time * 2 * .pi * 0.8 + Double(i) * 0.5))
            } else {
                target = 4 + CGFloat(targets[i]) * 24
            }
            let k: CGFloat = target > display[i] ? 0.55 : 0.12
            display[i] += (target - display[i]) * k
        }
        return display
    }
}
