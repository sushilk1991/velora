import Foundation

/// Fresh source-language recognition; independent of committed MeetingSegments.
struct MeetingSubtitleCue: Equatable, Identifiable {
    let startMs: Int
    let endMs: Int
    let text: String
    let speaker: MeetingSpeaker
    var id: String { "\(speaker.rawValue):\(startMs):\(endMs)" }
}

struct MeetingSubtitleResult: Equatable {
    let meetingID: String
    let revision: Int64
    let model: String
    let cues: [MeetingSubtitleCue]
    /// Engine-verified SHA256 plus source descriptor identity; no disk cache.
    let fingerprints: [String: String]

    static func parse(_ object: [String: Any]) -> Self? {
        guard let meetingID = object["meeting_id"] as? String, UUID(uuidString: meetingID) != nil,
              let revision = object["revision"] as? Int64, revision >= 0,
              let model = object["model"] as? String, !model.isEmpty,
              let values = object["cues"] as? [[String: Any]], values.count <= 200_000,
              let sources = object["fingerprints"] as? [[String: String]], (1...2).contains(sources.count)
        else { return nil }
        var fingerprints: [String: String] = [:]
        for source in sources {
            guard let path = source["path"], let value = source["value"],
                  let digest = value.split(separator: ":").first, digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit }), fingerprints[path] == nil
            else { return nil }
            fingerprints[path] = value
        }
        var cues: [MeetingSubtitleCue] = []
        var ends: [MeetingSpeaker: Int] = [:]
        var previousStart = 0
        for value in values {
            guard let start = value["start_ms"] as? Int, let end = value["end_ms"] as? Int,
                  start >= previousStart, start >= (ends[MeetingSpeaker(rawValue: value["speaker"] as? String ?? "") ?? .recording] ?? 0),
                  start >= 0, end > start, end - start <= 7_000, end <= 86_400_000,
                  let text = value["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 1_000,
                  let speakerRaw = value["speaker"] as? String, ["me", "them", "recording"].contains(speakerRaw),
                  let speaker = MeetingSpeaker(rawValue: speakerRaw)
            else { return nil }
            let lines = text.components(separatedBy: "\n")
            guard (1...2).contains(lines.count), lines.allSatisfy({ !$0.isEmpty && $0.count <= 42 }),
                  lines[0].count <= 30,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" })
            else { return nil }
            cues.append(MeetingSubtitleCue(startMs: start, endMs: end, text: text, speaker: speaker))
            previousStart = start
            ends[speaker] = end
        }
        return Self(meetingID: meetingID, revision: revision, model: model, cues: cues, fingerprints: fingerprints)
    }

    func export(format: MeetingExportFormat, speakerName: (MeetingSpeaker) -> String = { $0.displayName }) -> String {
        guard format == .srt || format == .vtt else { return "" }
        let blocks = cues.enumerated().map { index, cue in
            let text = "\(speakerName(cue.speaker)): \(cue.text)"
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "\(index + 1)\n\(MeetingRecord.cueTime(cue.startMs, format: format)) --> \(MeetingRecord.cueTime(cue.endMs, format: format))\n\(text)"
        }
        return (format == .vtt ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }
}
