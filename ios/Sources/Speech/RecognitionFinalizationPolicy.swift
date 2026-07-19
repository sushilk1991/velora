import Foundation

enum RecognitionFinalizationDecision: Equatable {
    case wait
    case deliverFallback
    case fail
}

/// Gives Speech time to emit an authoritative final result while bounding how
/// long the UI can remain in its finishing state when the framework stalls.
enum RecognitionFinalizationPolicy {
    static let minimumGracePeriod: TimeInterval = 2.5
    static let stablePartialPeriod: TimeInterval = 0.75
    static let maximumWait: TimeInterval = 8

    static func decision(
        transcript: String,
        elapsed: TimeInterval,
        secondsSinceLastUpdate: TimeInterval
    ) -> RecognitionFinalizationDecision {
        let hasWords = !TranscriptFormatter.normalize(transcript).isEmpty

        if elapsed >= maximumWait {
            return hasWords ? .deliverFallback : .fail
        }

        guard hasWords,
              elapsed >= minimumGracePeriod,
              secondsSinceLastUpdate >= stablePartialPeriod
        else {
            return .wait
        }

        return .deliverFallback
    }
}
