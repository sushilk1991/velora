import UIKit

@MainActor
protocol ClipboardWriting {
    func write(_ text: String)
}

struct SystemClipboard: ClipboardWriting {
    func write(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// The completion invariant for every successful dictation: the normalized
/// text on the clipboard must be the same text recorded in local history.
@MainActor
enum TranscriptDelivery {
    @discardableResult
    static func deliver(
        _ rawText: String,
        to clipboard: ClipboardWriting,
        store: TranscriptStore
    ) -> String? {
        let normalized = TranscriptFormatter.normalize(rawText)
        guard !normalized.isEmpty else { return nil }
        clipboard.write(normalized)
        _ = store.add(normalized)
        return normalized
    }
}
