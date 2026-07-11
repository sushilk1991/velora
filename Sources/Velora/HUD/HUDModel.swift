import AppKit
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
    /// Learned-a-correction toast (Wispr-style): the misheard word struck
    /// through, the user's fix next to it. Shown briefly after Velora catches
    /// an edit to just-inserted text; auto-hidden by the controller.
    case learned(wrong: String, right: String)
    /// General transient toast: an SF Symbol + one line of text (file
    /// transcription done, etc.). Auto-hidden by whoever shows it.
    case notice(symbol: String, message: String)

    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }
}

/// The context chip shown at the pill's leading edge while listening: the
/// frontmost app's actual icon plus the client-side detected mode name
/// (`ModeCategory`) — makes Velora's app-awareness visible.
struct HUDSessionContext: Equatable {
    let appIcon: NSImage?
    let modeName: String

    static func == (lhs: HUDSessionContext, rhs: HUDSessionContext) -> Bool {
        lhs.appIcon === rhs.appIcon && lhs.modeName == rhs.modeName
    }
}

struct HUDTranscriptSelection: Equatable {
    let text: String
    let truncated: Bool
}

/// Pure live-partial selection. It favors a just-finished sentence; while the
/// speaker is mid-sentence it keeps the newest whole words that fit. Character
/// slicing is deliberately forbidden because it produced fragments such as
/// "…es below if we can" in the HUD.
enum HUDTranscript {
    private static func middleElide(_ token: Substring, maxCharacters: Int) -> String {
        guard token.count > maxCharacters else { return String(token) }
        guard maxCharacters > 1 else { return "…" }
        let visible = maxCharacters - 1
        let suffixCount = max(1, visible / 2)
        let prefixCount = visible - suffixCount
        return String(token.prefix(prefixCount)) + "…" + String(token.suffix(suffixCount))
    }

    static func select(_ raw: String, maxCharacters: Int) -> HUDTranscriptSelection {
        let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, maxCharacters > 0 else {
            return HUDTranscriptSelection(text: "", truncated: false)
        }
        guard normalized.count > maxCharacters else {
            return HUDTranscriptSelection(text: normalized, truncated: false)
        }

        let sentenceMarks: Set<Character> = [".", "?", "!"]
        if let last = normalized.last, sentenceMarks.contains(last) {
            let beforeLast = normalized.dropLast()
            let priorEnd = beforeLast.lastIndex(where: { sentenceMarks.contains($0) })
            let start = priorEnd.map { normalized.index(after: $0) } ?? normalized.startIndex
            let sentence = normalized[start...].trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty, sentence.count <= maxCharacters {
                return HUDTranscriptSelection(text: sentence, truncated: true)
            }
        }

        var kept: [Substring] = []
        var count = 0
        for word in normalized.split(separator: " ").reversed() {
            let proposed = count + (kept.isEmpty ? 0 : 1) + word.count
            if proposed > maxCharacters {
                if kept.isEmpty {
                    return HUDTranscriptSelection(
                        text: middleElide(word, maxCharacters: maxCharacters),
                        truncated: true)
                }
                break
            }
            kept.append(word)
            count = proposed
            if proposed >= maxCharacters { break }
        }
        let tail = kept.reversed().joined(separator: " ")
        return HUDTranscriptSelection(text: tail, truncated: tail != normalized)
    }
}

/// Observable state driving the HUD view. Main-actor only.
final class HUDModel: ObservableObject {
    @Published var state: HUDState = .hidden(.cancel)
    /// Set when recording starts; drives the m:ss timer text.
    @Published var recordingStart: Date?
    /// Context chip contents for the active session (nil until a session
    /// begins; the chip is simply absent then).
    @Published var sessionContext: HUDSessionContext?
    /// Useful whole-word phrase selected from the running partial. Empty until
    /// the first partial — the HUD never shows placeholder text.
    @Published private(set) var transcriptTail = ""
    /// Whole words shared by the previous and newest partial. The HUD renders
    /// this prefix at full contrast so settled words stop visually flickering.
    @Published private(set) var transcriptStablePrefix = ""
    /// The newest, still-changeable words following `transcriptStablePrefix`.
    @Published private(set) var transcriptProvisionalSuffix = ""
    /// True once selection has omitted older transcript text.
    @Published private(set) var transcriptTruncated = false

    /// Waveform levels (not @Published — the Canvas polls it every frame via
    /// TimelineView; publishing per audio buffer would churn SwiftUI).
    let levels = WaveformLevelStore()

    /// Invoked by the error-state action button.
    var onRetry: (() -> Void)?
    /// Title of the error-state action button ("Retry" normally; "Open
    /// Settings" when the fix is granting a permission).
    @Published var retryTitle = "Retry"

    /// Resets per-session UI state as a new recording starts.
    func beginSession(context: HUDSessionContext?) {
        sessionContext = context
        transcriptTail = ""
        transcriptStablePrefix = ""
        transcriptProvisionalSuffix = ""
        transcriptTruncated = false
    }

    /// Feeds a streaming partial transcript into the live-transcript tail.
    ///
    /// Growth is monotonic from the HUD's perspective: empty partials are
    /// ignored so the pill never flash-clears between engine updates.
    func updatePartial(_ text: String) {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return }
        let selection = HUDTranscript.select(
            flattened, maxCharacters: HUDGeometry.transcriptCharacterLimit)
        let previousWords = transcriptTail.split(separator: " ")
        let nextWords = selection.text.split(separator: " ")
        let sharedCount = zip(previousWords, nextWords)
            .prefix(while: { $0 == $1 })
            .count
        transcriptStablePrefix = nextWords.prefix(sharedCount).joined(separator: " ")
        transcriptProvisionalSuffix = nextWords.dropFirst(sharedCount).joined(separator: " ")
        transcriptTail = selection.text
        transcriptTruncated = selection.truncated
    }
}

/// Ring buffer of recent loudness levels plus per-frame asymmetric smoothing
/// state (design brief §2), arranged center-out: the newest level renders at
/// the strip's vertical midline and flows outward toward both edges, so the
/// 24 visible bars are mirror-symmetric (Siri-like) — 12 unique heights.
///
/// `push` happens on the main queue (audio level callback); `displayHeights`
/// is called from the Canvas draw closure each frame (also main). The lock
/// guards against any off-main access without imposing structure on callers.
final class WaveformLevelStore {
    /// Visible bars (mirrored pairs around the center).
    static let barCount = 24
    /// Unique levels: one per mirrored pair.
    static let halfCount = barCount / 2

    private let lock = NSLock()
    /// Index 0 = center bars (LOW frequency) … `halfCount - 1` = outer edge
    /// (HIGH frequency). A live frequency spectrum, so the bars respond to
    /// pitch (which bands light up) as well as loudness (how tall they get).
    private var targets = [Float](repeating: 0, count: WaveformLevelStore.halfCount)
    private var display = [CGFloat](repeating: 4, count: WaveformLevelStore.halfCount)
    private var latestLevel: Float = 0

    /// Sets the target bar heights from a frequency spectrum: `bands[0]` (low)
    /// maps to the center bars, the highest band to the outer edges. Each value
    /// is a 0…1 magnitude. Bass in the middle reads as a natural, lively
    /// center-weighted waveform.
    func push(_ bands: [Float]) {
        guard !bands.isEmpty else { return }
        lock.lock()
        var peak: Float = 0
        for i in 0..<Self.halfCount {
            // Map halfCount bars onto the provided bands (nearest, tolerant of
            // a mismatched count).
            let idx = bands.count == Self.halfCount
                ? i
                : min(bands.count - 1, i * bands.count / Self.halfCount)
            let v = max(0, min(1, bands[idx]))
            targets[i] = v
            peak = max(peak, v)
        }
        latestLevel = peak
        lock.unlock()
    }

    /// Clears all bars (called when a new recording starts).
    func reset() {
        lock.lock()
        targets = [Float](repeating: 0, count: Self.halfCount)
        display = [CGFloat](repeating: 4, count: Self.halfCount)
        latestLevel = 0
        lock.unlock()
    }

    /// Computes this frame's bar heights (center→edge, `halfCount` values),
    /// advancing the smoothing state.
    ///
    /// - `settle == false` (listening): bars chase `4 + level*28` pt with fast
    ///   attack (k=0.55) / slow decay (k=0.12). Near-silence (< 0.03) drives a
    ///   gentle standing wave so the HUD still reads "listening".
    /// - `settle == true` (transcribing): all bars ease to the 4 pt floor.
    func displayHeights(settle: Bool, time: TimeInterval) -> [CGFloat] {
        lock.lock()
        defer { lock.unlock() }

        let idle = latestLevel < 0.04
        let maxH = HUDGeometry.waveformSize.height
        for i in 0..<Self.halfCount {
            let target: CGFloat
            if settle {
                target = 4
            } else if idle {
                // Breathing standing wave: two rippling components so the idle
                // state still feels alive without looking mechanical.
                let a = sin(time * 2 * .pi * 0.9 + Double(i) * 0.55)
                let b = sin(time * 2 * .pi * 0.37 - Double(i) * 0.3)
                target = 5 + 2.2 * CGFloat(a) + 1.2 * CGFloat(b)
            } else {
                // Slight expansion curve gives quiet consonants visible motion
                // while loud vowels still peak near the top of the strip.
                let shaped = pow(CGFloat(targets[i]), 0.82)
                target = 4 + shaped * (maxH - 4)
            }
            // Snappy attack so the bars track speech onsets; a springier decay
            // lets them fall back with a lively bounce instead of a slow sag.
            let k: CGFloat = target > display[i] ? 0.6 : 0.22
            display[i] += (target - display[i]) * k
        }
        return display
    }
}
