import Foundation

enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case markdown, plainText, srt, vtt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain text"
        case .srt: return "SRT timed transcript"
        case .vtt: return "VTT timed transcript"
        }
    }
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }

    var usesCueTiming: Bool { self == .srt || self == .vtt }
    static let timingNotice = "Timed transcripts use the original audio-block timings, which can span about a minute. They are not sentence-aligned subtitles."
}

extension MeetingRecord {
    func export(format: MeetingExportFormat) -> String {
        switch format {
        case .markdown: return exportText
        case .plainText:
            var sections = [title, (isImported ? "Imported " : "")
                + startedAt.formatted(date: .long, time: .shortened)]
            if !notes.summary.isEmpty { sections += ["Summary", notes.summary] }
            if !notes.decisions.isEmpty { sections += ["Decisions", notes.decisions.joined(separator: "\n")] }
            if !notes.actionItems.isEmpty {
                sections += ["Action items", notes.actionItems.map {
                    "\(notes.completedActionItems.contains($0) ? "[x]" : "[ ]") \($0)"
                }.joined(separator: "\n")]
            }
            if !personalNotes.isEmpty { sections += ["Personal notes", personalNotes] }
            if !formattedTranscript.isEmpty { sections += ["Transcript", formattedTranscript] }
            return sections.joined(separator: "\n\n")
        case .srt, .vtt:
            let segments = segments.filter {
                $0.startMs >= 0 && $0.endMs > $0.startMs
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.sorted {
                ($0.startMs, $0.speaker.rawValue, $0.chunkIndex)
                    < ($1.startMs, $1.speaker.rawValue, $1.chunkIndex)
            }
            let cues = segments.enumerated().map { index, segment in
                // Empty lines end a cue, so normalize dictated whitespace.
                var text = "\(segment.speaker.displayName): " + segment.text
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                text = text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "\(index + 1)\n\(Self.cueTime(segment.startMs, format: format)) --> \(Self.cueTime(segment.endMs, format: format))\n\(text)"
            }
            let body = cues.joined(separator: "\n\n")
            return (format == .vtt ? "WEBVTT\n\n" : "") + body + (body.isEmpty ? "" : "\n")
        }
    }

    static func cueTime(_ milliseconds: Int, format: MeetingExportFormat) -> String {
        let value = max(0, milliseconds)
        let separator = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", value / 3_600_000,
                      (value / 60_000) % 60, (value / 1_000) % 60,
                      separator, value % 1_000)
    }

    var followUpText: String {
        var sections = [title]
        if !notes.summary.isEmpty { sections += [notes.summary] }
        let remaining = notes.actionItems.filter { !notes.completedActionItems.contains($0) }
        if !remaining.isEmpty { sections += ["Follow-up\n" + remaining.map { "• \($0)" }.joined(separator: "\n")] }
        return sections.joined(separator: "\n\n")
    }
}
