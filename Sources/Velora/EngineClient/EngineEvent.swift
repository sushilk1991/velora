import Foundation

/// Events emitted by velora-engine over the control channel.
/// See docs/ARCHITECTURE.md "Wire protocol".
enum EngineEvent {
    /// Engine finished STT startup and is ready for `start`. `setupComplete`
    /// snapshots whether the later writing-model setup has also finished.
    case ready(setupComplete: Bool)

    /// First-run setup progress ("Downloading the speech model (1.6 GB)",
    /// fraction 0…1 when measurable). `phase == nil` clears the status.
    case loading(phase: String?, fraction: Double?)

    /// Speech and writing model setup finished. Onboarding uses this stricter
    /// signal instead of the earlier `ready` event, which intentionally makes
    /// raw dictation available while the writing model is still downloading.
    case setupComplete

    /// The idle miner promoted confirmed vocabulary. Carries a count only;
    /// Swift reads the allow-listed terms from the local projection file.
    case vocabularyPromoted(count: Int)

    /// Display-only streaming transcript used by the fixed live HUD.
    case partial(session: String, text: String)

    /// Raw transcript available (before LLM cleanup).
    case transcript(session: String, raw: String, ms: Int)

    /// Final text to insert. `cleanupApplied == false` means `text` carries the
    /// raw transcript (cleanup skipped, failed, or over budget). `audio` is the
    /// basename of the archived clip under `~/.velora/audio/`, when archiving
    /// is on.
    case final(
        session: String, text: String, raw: String, mode: String?,
        cleanupMs: Int?, cleanupApplied: Bool, audio: String?)

    /// Result of a History `reprocess` command: a re-run of an archived clip
    /// through a (possibly different) STT model / mode. Routed to the History
    /// UI, not the live dictation flow.
    case reprocessed(
        id: Int64?, audio: String, raw: String, text: String, mode: String?,
        sttModel: String?, sttMs: Int, cleanupMs: Int, cleanupApplied: Bool)
    case reprocessFailed(id: Int64?, error: String, code: String)

    /// Safe Voice Edit result: the transformed selection (or the original
    /// text when `applied` is false — a guard tripped or the model declined).
    case edited(id: String?, text: String, applied: Bool, ms: Int, reason: String?)
    case editFailed(id: String?, error: String, code: String)

    /// File-transcription command reached the engine (sent before decoding —
    /// distinguishes "working" from "command dropped while disconnected").
    case transcribeAccepted(id: String?)

    /// File-transcription job accepted: decoded duration and chunk count.
    case transcribeStarted(id: String?, durationS: Double, chunks: Int)

    /// File-transcription progress, 0…1.
    case transcribeProgress(id: String?, fraction: Double)

    /// File-transcription result.
    case transcribed(
        id: String?, path: String, text: String, mode: String?,
        durationS: Double, sttMs: Int)

    /// File-transcription failed (includes user-initiated cancel).
    case transcribeFailed(id: String?, error: String)

    case meetingTranscribeAccepted(id: String?, meetingID: String, speaker: MeetingSpeaker)
    case meetingTranscribeStarted(
        id: String?, meetingID: String, speaker: MeetingSpeaker,
        durationS: Double, chunks: Int, startChunk: Int)
    case meetingSegment(id: String?, segment: MeetingSegment)
    case meetingTranscribeProgress(
        id: String?, meetingID: String, speaker: MeetingSpeaker, fraction: Double)
    case meetingTranscribed(
        id: String?, meetingID: String, speaker: MeetingSpeaker,
        durationS: Double, chunks: Int)
    case meetingTranscribeFailed(
        id: String?, meetingID: String, speaker: MeetingSpeaker?,
        error: String, code: String?)
    case meetingNotesAccepted(id: String?, meetingID: String)
    case meetingNotesProgress(id: String?, meetingID: String, fraction: Double)
    case meetingNotesReady(id: String?, meetingID: String, notes: MeetingNotes)
    case meetingNotesFailed(id: String?, meetingID: String, error: String, code: String?)

    /// Engine-reported error, optionally scoped to a session.
    case error(session: String?, message: String)

    /// Response to `ping`.
    case pong

    /// Response to `status`.
    case status([String: Any])

    /// Anything this client version doesn't know; ignored but logged.
    case unknown([String: Any])

    /// Decodes an event from a JSON control frame payload.
    static func parse(_ object: [String: Any]) -> EngineEvent {
        let name = (object["event"] as? String) ?? (object["reply"] as? String) ?? ""
        switch name {
        case "ready":
            return .ready(setupComplete: object["setup_complete"] as? Bool ?? false)
        case "loading":
            return .loading(
                phase: (object["phase"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                fraction: (object["fraction"] as? NSNumber)?.doubleValue)
        case "setup_complete":
            return .setupComplete
        case "vocabulary_promoted":
            return .vocabularyPromoted(
                count: (object["count"] as? NSNumber)?.intValue ?? 0)
        case "partial":
            return .partial(
                session: object["session"] as? String ?? "",
                text: object["text"] as? String ?? "")
        case "transcript":
            return .transcript(
                session: object["session"] as? String ?? "",
                raw: object["raw"] as? String ?? "",
                ms: object["ms"] as? Int ?? 0)
        case "final":
            return .final(
                session: object["session"] as? String ?? "",
                text: object["text"] as? String ?? "",
                raw: object["raw"] as? String ?? (object["text"] as? String ?? ""),
                mode: object["mode"] as? String,
                cleanupMs: object["cleanup_ms"] as? Int,
                cleanupApplied: object["cleanup_applied"] as? Bool ?? false,
                audio: object["audio"] as? String)
        case "reprocessed":
            return .reprocessed(
                id: (object["id"] as? Int).map(Int64.init),
                audio: object["audio"] as? String ?? "",
                raw: object["raw"] as? String ?? "",
                text: object["text"] as? String ?? "",
                mode: object["mode"] as? String,
                sttModel: object["stt_model"] as? String,
                sttMs: object["stt_ms"] as? Int ?? 0,
                cleanupMs: object["cleanup_ms"] as? Int ?? 0,
                cleanupApplied: object["cleanup_applied"] as? Bool ?? false)
        case "reprocess_failed":
            return .reprocessFailed(
                id: (object["id"] as? NSNumber)?.int64Value,
                error: object["error"] as? String ?? "reprocess failed",
                code: object["code"] as? String ?? "failed")
        case "edited":
            return .edited(
                id: object["id"] as? String,
                text: object["text"] as? String ?? "",
                applied: object["applied"] as? Bool ?? false,
                ms: object["ms"] as? Int ?? 0,
                reason: object["reason"] as? String)
        case "edit_failed":
            return .editFailed(
                id: object["id"] as? String,
                error: object["error"] as? String ?? "edit failed",
                code: object["code"] as? String ?? "failed")
        case "transcribe_accepted":
            return .transcribeAccepted(id: object["id"] as? String)
        case "transcribe_started":
            return .transcribeStarted(
                id: object["id"] as? String,
                durationS: (object["duration_s"] as? NSNumber)?.doubleValue ?? 0,
                chunks: object["chunks"] as? Int ?? 1)
        case "transcribe_progress":
            return .transcribeProgress(
                id: object["id"] as? String,
                fraction: (object["fraction"] as? NSNumber)?.doubleValue ?? 0)
        case "transcribed":
            return .transcribed(
                id: object["id"] as? String,
                path: object["path"] as? String ?? "",
                text: object["text"] as? String ?? "",
                mode: object["mode"] as? String,
                durationS: (object["duration_s"] as? NSNumber)?.doubleValue ?? 0,
                sttMs: object["stt_ms"] as? Int ?? 0)
        case "transcribe_failed":
            return .transcribeFailed(
                id: object["id"] as? String,
                error: object["error"] as? String ?? "transcription failed")
        case "meeting_transcribe_accepted":
            return .meetingTranscribeAccepted(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                speaker: MeetingSpeaker(rawValue: object["speaker"] as? String ?? "") ?? .them)
        case "meeting_transcribe_started":
            return .meetingTranscribeStarted(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                speaker: MeetingSpeaker(rawValue: object["speaker"] as? String ?? "") ?? .them,
                durationS: (object["duration_s"] as? NSNumber)?.doubleValue ?? 0,
                chunks: (object["chunks"] as? NSNumber)?.intValue ?? 0,
                startChunk: (object["start_chunk"] as? NSNumber)?.intValue ?? 0)
        case "meeting_segment":
            let meetingID = object["meeting_id"] as? String ?? ""
            return .meetingSegment(
                id: object["id"] as? String,
                segment: MeetingSegment(
                    meetingID: meetingID,
                    speaker: MeetingSpeaker(rawValue: object["speaker"] as? String ?? "") ?? .them,
                    chunkIndex: (object["chunk_index"] as? NSNumber)?.intValue ?? 0,
                    startMs: (object["start_ms"] as? NSNumber)?.intValue ?? 0,
                    endMs: (object["end_ms"] as? NSNumber)?.intValue ?? 0,
                    text: object["text"] as? String ?? ""))
        case "meeting_transcribe_progress":
            return .meetingTranscribeProgress(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                speaker: MeetingSpeaker(rawValue: object["speaker"] as? String ?? "") ?? .them,
                fraction: (object["fraction"] as? NSNumber)?.doubleValue ?? 0)
        case "meeting_transcribed":
            return .meetingTranscribed(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                speaker: MeetingSpeaker(rawValue: object["speaker"] as? String ?? "") ?? .them,
                durationS: (object["duration_s"] as? NSNumber)?.doubleValue ?? 0,
                chunks: (object["chunks"] as? NSNumber)?.intValue ?? 0)
        case "meeting_transcribe_failed":
            return .meetingTranscribeFailed(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                speaker: (object["speaker"] as? String).flatMap(MeetingSpeaker.init(rawValue:)),
                error: object["error"] as? String ?? "meeting transcription failed",
                code: object["code"] as? String)
        case "meeting_notes_accepted":
            return .meetingNotesAccepted(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "")
        case "meeting_notes_progress":
            return .meetingNotesProgress(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                fraction: (object["fraction"] as? NSNumber)?.doubleValue ?? 0)
        case "meeting_notes_ready":
            return .meetingNotesReady(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                notes: MeetingNotes(
                    summary: object["summary"] as? String ?? "",
                    decisions: object["decisions"] as? [String] ?? [],
                    actionItems: object["action_items"] as? [String] ?? []))
        case "meeting_notes_failed":
            return .meetingNotesFailed(
                id: object["id"] as? String,
                meetingID: object["meeting_id"] as? String ?? "",
                error: object["error"] as? String ?? "meeting note generation failed",
                code: object["code"] as? String)
        case "error":
            return .error(
                session: object["session"] as? String,
                message: object["message"] as? String
                    ?? object["error"] as? String ?? "Engine error")
        case "pong":
            return .pong
        case "status":
            return .status(object)
        default:
            return .unknown(object)
        }
    }
}
