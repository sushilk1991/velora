import AVFoundation
import Foundation
import SQLite3

enum MeetingStatus: String {
    case recording
    case processing
    case ready
    case failed
}

/// A transcript channel: the mic ("me"), the remote mix ("them"), or a legacy
/// diarized remote label ("s1", "s2", …). New audio-only meetings stay
/// Me/Them because clustering cannot verify identity. RawRepresentable keeps
/// old database rows readable; unknown labels fail the initializer and callers
/// default to .them.
enum MeetingSpeaker: RawRepresentable, Equatable, Hashable {
    case me
    case them
    case remote(Int)

    init?(rawValue: String) {
        switch rawValue {
        case "me": self = .me
        case "them": self = .them
        default:
            guard rawValue.hasPrefix("s"), rawValue.count <= 3,
                  let n = Int(rawValue.dropFirst()), n >= 1
            else { return nil }
            self = .remote(n)
        }
    }

    var rawValue: String {
        switch self {
        case .me: return "me"
        case .them: return "them"
        case .remote(let n): return "s\(n)"
        }
    }

    var displayName: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        case .remote(let n): return "Speaker \(n)"
        }
    }

    /// True for any remote channel — plain "them" or a diarized voice.
    /// The system track's resume cursor spans all of them (see nextChunk).
    var isRemote: Bool { self != .me }
}

struct MeetingSegment: Identifiable, Equatable {
    var id: Int64 = 0
    let meetingID: String
    let speaker: MeetingSpeaker
    let chunkIndex: Int
    let startMs: Int
    let endMs: Int
    let text: String
}

struct MeetingNotes: Equatable {
    var summary: String = ""
    var decisions: [String] = []
    var actionItems: [String] = []
    /// True when the engine had to skip some transcript sections, so these
    /// notes cover only the rest of the meeting.
    var partial = false

    var isEmpty: Bool {
        summary.isEmpty && decisions.isEmpty && actionItems.isEmpty
    }
}

/// The stage a processing job failed or was cancelled in; it picks the row
/// the failure leaves (see `MeetingStore.markCancelled`).
enum MeetingJobStage {
    case transcription
    case notes
    case recreate
}

/// Why one captured track added no lines to the transcript. Stored per
/// track so a meeting names the missing side instead of failing whole.
enum MeetingTrackIssue: Equatable {
    /// The device delivered digital silence (a lid-closed built-in mic, a
    /// muted interface): the file is valid but holds no sound.
    case silent
    /// The file is valid but shorter than the engine's minimum (server.py
    /// `MEETING_MIN_TRACK_S`, 0.2 s): capture stopped right after it began.
    case tooShort
    /// The engine could not transcribe the track; the message says why.
    case failed(String)

    /// A silent or too-short track holds no speech: it adds no lines, and
    /// Recreate requires none from it.
    var holdsNoSpeech: Bool {
        self == .silent || self == .tooShort
    }
}

struct MeetingRecord: Identifiable, Equatable {
    let id: String
    var title: String
    let startedAt: Date
    var endedAt: Date
    var sourceApp: String?
    var calendarEventID: String?
    var status: MeetingStatus
    var notes: MeetingNotes = MeetingNotes()
    var micPath: String?
    var systemPath: String?
    var error: String?
    var micIssue: MeetingTrackIssue?
    var systemIssue: MeetingTrackIssue?
    var segments: [MeetingSegment] = []

    var durationMs: Int { max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000)) }

    /// The warning on a ready meeting that carries an error. A ready row
    /// keeps an error only when a later operation failed; name that one,
    /// and what the row still holds:
    ///
    ///     Recreate failed (its staged job remains) → previous notes kept
    ///     notes failed after partial notes         → notes incomplete
    ///     notes failed with none saved             → no notes
    ///
    /// `recreating` is `MeetingStore.isReprocessing(meetingID:)`.
    func readyErrorMessage(recreating: Bool) -> String? {
        guard status == .ready, let error else { return nil }
        if !recreating && notes.partial {
            return "Notes are incomplete. Retry Notes did not finish them. \(error)"
        }
        if !recreating && notes.isEmpty {
            return "Notes were not generated. \(error)"
        }
        return "Recreate did not finish; the previous notes were kept. \(error)"
    }

    var formattedTranscript: String {
        segments.sorted {
            ($0.startMs, $0.speaker.rawValue, $0.chunkIndex)
                < ($1.startMs, $1.speaker.rawValue, $1.chunkIndex)
        }.map { segment in
            "[\(Self.clock(segment.startMs))] \(segment.speaker.displayName): \(segment.text)"
        }.joined(separator: "\n")
    }

    var exportText: String {
        var sections = ["# \(title)", "", startedAt.formatted(date: .long, time: .shortened)]
        if !notes.summary.isEmpty { sections += ["", "## Summary", "", notes.summary] }
        if !notes.decisions.isEmpty {
            sections += ["", "## Decisions", ""] + notes.decisions.map { "- \($0)" }
        }
        if !notes.actionItems.isEmpty {
            sections += ["", "## Action items", ""] + notes.actionItems.map { "- [ ] \($0)" }
        }
        let transcript = formattedTranscript
        if !transcript.isEmpty { sections += ["", "## Transcript", "", transcript] }
        return sections.joined(separator: "\n")
    }

    private static func clock(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct MeetingSearchHit: Identifiable, Equatable {
    let id: String
    let meetingID: String
    let title: String
    let startedAt: Date
    let snippet: String
}

/// The track files the engine's meeting loader decodes (engine media.py,
/// `load_meeting_media`): mono or stereo uncompressed PCM in CAF
/// (`_MEETING_PCM_SAMPLE_BYTES`), or a legacy `them.m4a`, which it hands to
/// its generic decoder. Retry, Recreate and the processor all ask
/// `MeetingStore.hasUsableAudio`, which applies this, so none of them can
/// offer a track the engine would reject.
enum MeetingTrackFormat {
    private static let containerExtension = "caf"
    private static let legacyExtension = "m4a"
    private static let channelCounts: ClosedRange<UInt32> = 1...2
    private static let integerBitDepths: Set<UInt32> = [16, 24, 32]
    private static let floatBitDepths: Set<UInt32> = [32, 64]

    static func isSupported(_ file: AVAudioFile) -> Bool {
        let description = file.fileFormat.streamDescription.pointee
        guard channelCounts.contains(description.mChannelsPerFrame) else { return false }
        let fileExtension = file.url.pathExtension.lowercased()
        if fileExtension == legacyExtension {
            return true
        }
        guard fileExtension == containerExtension,
              description.mFormatID == kAudioFormatLinearPCM else { return false }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let depths = isFloat ? floatBitDepths : integerBitDepths
        return depths.contains(description.mBitsPerChannel)
    }
}

/// Separate owner-only meeting store. Dictation history and meeting memory
/// have intentionally independent databases and audio-retention lifecycles.
final class MeetingStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.velora.meetings.store")
    private let databaseURL: URL
    private let filesRoot: URL
    private var ftsAvailable = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(
        url: URL = AppConfig.meetingsDatabaseURL,
        filesRoot: URL = AppConfig.meetingsDirectory
    ) {
        self.databaseURL = url
        self.filesRoot = filesRoot
        Self.ensurePrivateDirectory(filesRoot)
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) == SQLITE_OK {
            db = handle
            sqlite3_busy_timeout(handle, 2_000)
            sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
            createSchema()
            recoverInterruptedRecordings()
            removeOrphanedCaptureDirectories()
            protectDatabaseFiles()
        } else {
            if handle != nil { sqlite3_close(handle) }
            NSLog("Velora: failed to open meetings database at %@", url.path)
        }
    }

    deinit { if db != nil { sqlite3_close(db) } }

    static func ensurePrivateDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func createSchema() {
        let sql = """
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL NOT NULL,
                source_app TEXT,
                calendar_event_id TEXT,
                status TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                decisions TEXT NOT NULL DEFAULT '',
                action_items TEXT NOT NULL DEFAULT '',
                mic_path TEXT,
                system_path TEXT,
                error TEXT,
                notes_pending INTEGER NOT NULL DEFAULT 0,
                mic_issue TEXT,
                system_issue TEXT,
                notes_partial INTEGER NOT NULL DEFAULT 0,
                notes_auto_retried INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS meeting_segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                speaker TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                UNIQUE(meeting_id, speaker, chunk_index)
            );
            CREATE INDEX IF NOT EXISTS idx_meeting_segments_order
                ON meeting_segments(meeting_id, start_ms, speaker, chunk_index);
            CREATE TABLE IF NOT EXISTS meeting_reprocess_jobs (
                meeting_id TEXT PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS meeting_reprocess_segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                speaker TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                UNIQUE(meeting_id, speaker, chunk_index)
            );
            CREATE INDEX IF NOT EXISTS idx_meeting_reprocess_segments_order
                ON meeting_reprocess_segments(meeting_id, start_ms, speaker, chunk_index);
            CREATE INDEX IF NOT EXISTS idx_meetings_started ON meetings(started_at DESC);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            NSLog("Velora: meeting schema failed: %@", lastError)
            return
        }
        // Existing installs predate the durable notes-only retry marker.
        // Duplicate-column is expected after the first migrated launch.
        sqlite3_exec(
            db,
            "ALTER TABLE meetings ADD COLUMN notes_pending INTEGER NOT NULL DEFAULT 0;",
            nil, nil, nil)
        // Per-track outcomes, partial notes and the spent automatic notes
        // retry arrived later still; the same duplicate-column rule applies.
        for column in [
            "mic_issue TEXT", "system_issue TEXT",
            "notes_partial INTEGER NOT NULL DEFAULT 0",
        ] {
            sqlite3_exec(db, "ALTER TABLE meetings ADD COLUMN \(column);", nil, nil, nil)
        }
        // The automatic notes retry upgrade runs once, as one transaction:
        //
        //   add notes_auto_retried   fails as a duplicate column once done
        //   pending rows -> retried  a cancelled notes job was stored like
        //                            a failed one; neither is restarted
        //   legacy notes failures    -> ready + notes pending, so each takes
        //                            the one claimed, quiet automatic retry
        //
        // A failure at any step rolls all of it back and the next launch
        // redoes it. The legacy rewrite must not run again later: a
        // Recreate whose notes failed leaves the same error text.
        _ = transactionOnQueue {
            sqlite3_exec(
                db,
                "ALTER TABLE meetings ADD COLUMN notes_auto_retried INTEGER NOT NULL DEFAULT 0;",
                nil, nil, nil) == SQLITE_OK
                && sqlite3_exec(
                    db,
                    "UPDATE meetings SET notes_auto_retried = 1 WHERE notes_pending = 1;",
                    nil, nil, nil) == SQLITE_OK
                // Only the legacy error text of the notes worker: a
                // transcription failure may also have committed segments
                // and must resume the remaining audio instead.
                && sqlite3_exec(db, """
                    UPDATE meetings SET status = 'ready', notes_pending = 1
                    WHERE notes_pending = 0
                      AND summary = '' AND decisions = '' AND action_items = ''
                      AND error LIKE 'local notes generation failed%'
                      AND EXISTS (
                          SELECT 1 FROM meeting_segments
                          WHERE meeting_id = meetings.id LIMIT 1
                      );
                    """, nil, nil, nil) == SQLITE_OK
        }
        ftsAvailable = sqlite3_exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS meeting_search USING fts5(
                meeting_id UNINDEXED, title, transcript, summary, decisions, action_items,
                tokenize='unicode61'
            );
            """, nil, nil, nil) == SQLITE_OK
        if !ftsAvailable { NSLog("Velora: meeting FTS unavailable; using bounded LIKE search") }
    }

    private func protectDatabaseFiles() {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    private func removeOrphanedCaptureDirectories() {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM meetings;", -1, &stmt, nil) == SQLITE_OK
        else { return }
        var retained = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = columnText(stmt, 0) { retained.insert(id) }
        }
        sqlite3_finalize(stmt)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: filesRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory && !retained.contains(child.lastPathComponent) {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// A recording row is written before capture starts. If the process was
    /// killed or the Mac crashed, preserve any audio that reached disk and
    /// expose it as recoverable instead of treating its directory as orphaned.
    /// Empty preparations are removed so they never become phantom meetings.
    private func recoverInterruptedRecordings() {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT id, mic_path, system_path FROM meetings WHERE status = ?;
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, MeetingStatus.recording.rawValue)
        var recoverable: [(String, String?, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = columnText(stmt, 0) {
                recoverable.append((id, columnText(stmt, 1), columnText(stmt, 2)))
            }
        }
        sqlite3_finalize(stmt)

        for (id, mic, system) in recoverable {
            func recoveredTrack(_ relative: String?) -> String? {
                guard let relative,
                      let url = audioURL(relativePath: relative) else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 4_096 else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                if let audio = try? AVAudioFile(forReading: url), audio.length > 0 {
                    return relative
                }
                // Retrying an unreadable container only creates a predictable
                // engine failure. Keep recovery and the Retry affordance on
                // the same contract: Core Audio must observe real frames.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let recoveredMic = recoveredTrack(mic)
            let recoveredSystem = recoveredTrack(system)
            if recoveredMic == nil && recoveredSystem == nil {
                var remove: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE id = ?;", -1, &remove, nil)
                    == SQLITE_OK {
                    bindText(remove, 1, id); sqlite3_step(remove)
                }
                sqlite3_finalize(remove)
                if let directory = meetingDirectoryURL(id: id) {
                    try? FileManager.default.removeItem(at: directory)
                }
                continue
            }
            var update: OpaquePointer?
            if sqlite3_prepare_v2(db, """
                UPDATE meetings SET status = ?, ended_at = ?, error = ?,
                    mic_path = ?, system_path = ? WHERE id = ?;
                """, -1, &update, nil) == SQLITE_OK {
                bindText(update, 1, MeetingStatus.failed.rawValue)
                sqlite3_bind_double(update, 2, Date().timeIntervalSince1970)
                bindText(update, 3, "Recording was interrupted; recovered local audio can be retried")
                bindText(update, 4, recoveredMic)
                bindText(update, 5, recoveredSystem)
                bindText(update, 6, id)
                sqlite3_step(update)
            }
            sqlite3_finalize(update)
        }
    }

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    // MARK: - Writes

    func insertRecording(_ record: MeetingRecord) {
        upsert(record, status: .recording)
    }

    func insertProcessing(_ record: MeetingRecord) {
        upsert(record, status: .processing)
    }

    private func upsert(_ record: MeetingRecord, status: MeetingStatus) {
        queue.sync { [self] in
            guard db != nil else { return }
            let sql = """
                INSERT OR REPLACE INTO meetings
                    (id, title, started_at, ended_at, source_app, calendar_event_id,
                     status, summary, decisions, action_items, mic_path, system_path, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, '', '', '', ?, ?, NULL);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, record.id)
            bindText(stmt, 2, record.title)
            sqlite3_bind_double(stmt, 3, record.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, record.endedAt.timeIntervalSince1970)
            bindText(stmt, 5, record.sourceApp)
            bindText(stmt, 6, record.calendarEventID)
            bindText(stmt, 7, status.rawValue)
            bindText(stmt, 8, record.micPath)
            bindText(stmt, 9, record.systemPath)
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("Velora: meeting insert failed: %@", lastError)
            }
            protectDatabaseFiles()
        }
    }

    func appendSegment(_ segment: MeetingSegment) {
        queue.sync { [self] in
            appendSegmentOnQueue(segment, table: "meeting_segments")
        }
    }

    /// Recreate writes into a shadow transcript. The committed transcript
    /// remains readable until fresh notes are also ready and both swap in one
    /// SQLite transaction.
    func beginReprocess(meetingID: String) -> Bool {
        queue.sync { [self] in
            transactionOnQueue {
                executeOnQueue(
                    "DELETE FROM meeting_reprocess_segments WHERE meeting_id = ?;",
                    meetingID: meetingID)
                    && executeOnQueue(
                        "INSERT OR IGNORE INTO meeting_reprocess_jobs (meeting_id) VALUES (?);",
                        meetingID: meetingID)
                    && executeOnQueue(
                        "UPDATE meetings SET status = 'processing', error = NULL, notes_pending = 0 WHERE id = ?;",
                        meetingID: meetingID)
            }
        }
    }

    func isReprocessing(meetingID: String) -> Bool {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT 1 FROM meeting_reprocess_jobs WHERE meeting_id = ? LIMIT 1;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func appendReprocessSegment(_ segment: MeetingSegment) {
        queue.sync { [self] in
            appendSegmentOnQueue(segment, table: "meeting_reprocess_segments")
        }
    }

    func nextReprocessChunk(meetingID: String, speaker: MeetingSpeaker) -> Int {
        queue.sync { [self] in
            nextChunkOnQueue(
                meetingID: meetingID, speaker: speaker,
                table: "meeting_reprocess_segments")
        }
    }

    func deleteReprocessSegments(meetingID: String, remoteTrack: Bool) {
        queue.sync { [self] in
            deleteSegmentsOnQueue(
                meetingID: meetingID, remoteTrack: remoteTrack,
                table: "meeting_reprocess_segments")
        }
    }

    func reprocessRecord(id: String) -> MeetingRecord? {
        queue.sync { [self] in
            guard var record = recordsOnQueue(
                whereClause: "WHERE id = ?", bindings: [id], limit: 1,
                includeSegments: false).first else { return nil }
            record.segments = segmentsOnQueue(
                meetingID: id, table: "meeting_reprocess_segments")
            return record
        }
    }

    func hasReprocessSegments(meetingID: String, speaker: MeetingSpeaker) -> Bool {
        queue.sync { [self] in
            hasSegmentsOnQueue(
                meetingID: meetingID, speaker: speaker,
                table: "meeting_reprocess_segments")
        }
    }

    /// Resume cursor for a TRACK, not a label: the system track's segments
    /// may carry diarized labels (s1, s2, …) interleaved with "them", and
    /// chunk indexes are global per track — so the remote cursor is the max
    /// over every non-mic row. (A diarization toggle flipped between a crash
    /// and the resume can shift the plan; the cursor still only moves
    /// forward, so the worst case is a re-transcribed or skipped chunk, not
    /// a wedged meeting.)
    func nextChunk(meetingID: String, speaker: MeetingSpeaker) -> Int {
        queue.sync { [self] in
            nextChunkOnQueue(
                meetingID: meetingID, speaker: speaker, table: "meeting_segments")
        }
    }

    /// Drops one track's committed segments — the engine restarted the track
    /// from chunk zero (its resume plan was lost), so existing rows would
    /// duplicate or mislabel lines once the fresh segments arrive.
    func deleteSegments(meetingID: String, remoteTrack: Bool) {
        queue.sync { [self] in
            deleteSegmentsOnQueue(
                meetingID: meetingID, remoteTrack: remoteTrack,
                table: "meeting_segments")
        }
    }

    /// False when SQLite refused the write (disk full, a lock held past the
    /// busy timeout); the row then keeps its previous state.
    @discardableResult
    func complete(meetingID: String, notes: MeetingNotes) -> Bool {
        queue.sync { [self] in
            guard db != nil else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                UPDATE meetings SET status = ?, summary = ?, decisions = ?,
                    action_items = ?, error = NULL, notes_pending = 0,
                    notes_partial = ? WHERE id = ?;
                """, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, MeetingStatus.ready.rawValue)
            bindText(stmt, 2, notes.summary)
            bindText(stmt, 3, notes.decisions.joined(separator: "\n"))
            bindText(stmt, 4, notes.actionItems.joined(separator: "\n"))
            sqlite3_bind_int(stmt, 5, notes.partial ? 1 : 0)
            bindText(stmt, 6, meetingID)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                NSLog("Velora: meeting notes save failed: %@", lastError)
                return false
            }
            refreshSearchOnQueue(meetingID: meetingID)
            return true
        }
    }

    /// Commits the shadow transcript, its notes and its track outcomes
    /// together. Any failure rolls back to the previously completed
    /// transcript, notes and outcomes.
    func completeReprocess(
        meetingID: String,
        notes: MeetingNotes,
        requiredSpeakers: [MeetingSpeaker],
        issues: [MeetingSpeaker: MeetingTrackIssue]
    ) -> Bool {
        queue.sync { [self] in
            let committed = transactionOnQueue {
                for speaker in requiredSpeakers {
                    guard hasSegmentsOnQueue(
                        meetingID: meetingID, speaker: speaker,
                        table: "meeting_reprocess_segments")
                    else { return false }
                }
                guard executeOnQueue(
                    "DELETE FROM meeting_segments WHERE meeting_id = ?;",
                    meetingID: meetingID)
                else { return false }
                var copy: OpaquePointer?
                guard sqlite3_prepare_v2(db, """
                    INSERT INTO meeting_segments
                        (meeting_id, speaker, chunk_index, start_ms, end_ms, text)
                    SELECT meeting_id, speaker, chunk_index, start_ms, end_ms, text
                    FROM meeting_reprocess_segments WHERE meeting_id = ?;
                    """, -1, &copy, nil) == SQLITE_OK else { return false }
                bindText(copy, 1, meetingID)
                let copied = sqlite3_step(copy) == SQLITE_DONE
                sqlite3_finalize(copy)
                guard copied else { return false }

                var update: OpaquePointer?
                guard sqlite3_prepare_v2(db, """
                    UPDATE meetings SET status = ?, summary = ?, decisions = ?,
                        action_items = ?, error = NULL, notes_pending = 0,
                        notes_partial = ?, mic_issue = ?, system_issue = ?
                    WHERE id = ?;
                    """, -1, &update, nil) == SQLITE_OK else { return false }
                bindText(update, 1, MeetingStatus.ready.rawValue)
                bindText(update, 2, notes.summary)
                bindText(update, 3, notes.decisions.joined(separator: "\n"))
                bindText(update, 4, notes.actionItems.joined(separator: "\n"))
                sqlite3_bind_int(update, 5, notes.partial ? 1 : 0)
                bindText(update, 6, Self.issueText(issues[.me]))
                bindText(update, 7, Self.issueText(issues[.them]))
                bindText(update, 8, meetingID)
                let updated = sqlite3_step(update) == SQLITE_DONE
                sqlite3_finalize(update)
                guard updated else { return false }
                return executeOnQueue(
                    "DELETE FROM meeting_reprocess_segments WHERE meeting_id = ?;",
                    meetingID: meetingID)
                    && executeOnQueue(
                        "DELETE FROM meeting_reprocess_jobs WHERE meeting_id = ?;",
                        meetingID: meetingID)
            }
            if committed { refreshSearchOnQueue(meetingID: meetingID) }
            return committed
        }
    }

    /// A failed Recreate must not hide the last committed meeting from search.
    /// Keep its staging cursor for Retry, and restore `ready` only when real
    /// committed content exists; a first-time failure remains `failed`.
    @discardableResult
    func markReprocessFailed(meetingID: String, error: String) -> Bool {
        queue.sync { [self] in
            failOnQueue(meetingID: meetingID, stage: .recreate, error: error)
        }
    }

    @discardableResult
    func markFailed(meetingID: String, error: String) -> Bool {
        queue.sync { [self] in
            failOnQueue(meetingID: meetingID, stage: .transcription, error: error)
        }
    }

    /// Notes are downstream of a durable transcript. A notes-model failure
    /// must not hide that transcript from meeting memory or make recovery
    /// depend on retained audio that notes generation never reads.
    @discardableResult
    func markNotesFailed(meetingID: String, error: String) -> Bool {
        queue.sync { [self] in
            guard failOnQueue(meetingID: meetingID, stage: .notes, error: error) else {
                return false
            }
            refreshSearchOnQueue(meetingID: meetingID)
            return true
        }
    }

    /// Cancel ends the job and spends the automatic notes retry in one
    /// transaction. Written apart, a half-saved cancel came back as an
    /// automatic retry or a resumed processing row. False when SQLite
    /// refused it; the caller must then hold the cancel itself.
    func markCancelled(meetingID: String, stage: MeetingJobStage, error: String) -> Bool {
        queue.sync { [self] in
            let committed = transactionOnQueue {
                failOnQueue(meetingID: meetingID, stage: stage, error: error)
                    && executeOnQueue(
                        "UPDATE meetings SET notes_auto_retried = 1 WHERE id = ?;",
                        meetingID: meetingID)
            }
            if committed && stage == .notes {
                refreshSearchOnQueue(meetingID: meetingID)
            }
            return committed
        }
    }

    /// The row a failed job leaves, by stage:
    ///
    ///     transcription -> failed, notes not pending
    ///     notes         -> ready with notes pending (Retry Notes),
    ///                      or failed when no transcript exists
    ///     recreate      -> ready while committed content exists (the
    ///                      staging cursor stays for Retry), else failed
    private func failOnQueue(
        meetingID: String, stage: MeetingJobStage, error: String
    ) -> Bool {
        let sql: String
        switch stage {
        case .transcription:
            sql = "UPDATE meetings SET status = 'failed', error = ?, notes_pending = 0 WHERE id = ?;"
        case .notes:
            sql = """
                UPDATE meetings SET
                    status = CASE WHEN EXISTS (
                        SELECT 1 FROM meeting_segments
                        WHERE meeting_id = meetings.id LIMIT 1
                    ) THEN 'ready' ELSE 'failed' END,
                    error = ?, notes_pending = 1
                WHERE id = ?;
                """
        case .recreate:
            sql = """
                UPDATE meetings SET
                    status = CASE
                        WHEN summary != '' OR decisions != '' OR action_items != ''
                             OR EXISTS (
                                 SELECT 1 FROM meeting_segments
                                 WHERE meeting_id = meetings.id LIMIT 1)
                        THEN 'ready' ELSE 'failed' END,
                    error = ?, notes_pending = 0
                WHERE id = ?;
                """
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, String(error.prefix(1_000)))
        bindText(stmt, 2, meetingID)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func markProcessing(meetingID: String, notesPending: Bool = false) {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "UPDATE meetings SET status = ?, error = NULL, notes_pending = ? WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, MeetingStatus.processing.rawValue)
            sqlite3_bind_int(stmt, 2, notesPending ? 1 : 0)
            bindText(stmt, 3, meetingID)
            sqlite3_step(stmt)
        }
    }

    /// Records how one track's transcription ended; nil clears an earlier
    /// issue after a successful Retry.
    func setTrackIssue(
        meetingID: String, speaker: MeetingSpeaker, issue: MeetingTrackIssue?
    ) {
        let column = speaker.isRemote ? "system_issue" : "mic_issue"
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "UPDATE meetings SET \(column) = ? WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.issueText(issue))
            bindText(stmt, 2, meetingID)
            sqlite3_step(stmt)
        }
    }

    /// Claims the one automatic notes retry a stalled meeting gets (see
    /// `stalledNotes`): one conditional UPDATE spends the marker and marks
    /// the row processing. False when SQLite refused the write or the row
    /// no longer qualifies; the retry must not be queued then, or nothing
    /// would stop it on every relaunch. (A cancel spends the marker too;
    /// see `markCancelled`.)
    func claimNotesAutoRetry(meetingID: String) -> Bool {
        queue.sync { [self] in
            executeOnQueue("""
                UPDATE meetings SET
                    status = 'processing', error = NULL,
                    notes_pending = 1, notes_auto_retried = 1
                WHERE id = ? AND status = 'ready' AND notes_pending = 1
                  AND notes_auto_retried = 0;
                """, meetingID: meetingID)
                && sqlite3_changes(db) == 1
        }
    }

    func delete(meetingID: String) {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE id = ?;", -1, &stmt, nil)
                    == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            sqlite3_step(stmt)
            if ftsAvailable {
                var fts: OpaquePointer?
                if sqlite3_prepare_v2(
                    db, "DELETE FROM meeting_search WHERE meeting_id = ?;", -1, &fts, nil)
                    == SQLITE_OK {
                    bindText(fts, 1, meetingID); sqlite3_step(fts)
                }
                sqlite3_finalize(fts)
            }
            if let directory = meetingDirectoryURL(id: meetingID) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func deleteAll() {
        queue.sync { [self] in
            sqlite3_exec(db, "DELETE FROM meetings;", nil, nil, nil)
            if ftsAvailable { sqlite3_exec(db, "DELETE FROM meeting_search;", nil, nil, nil) }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: filesRoot, includingPropertiesForKeys: nil)) ?? []
            for child in children
            where !child.lastPathComponent.hasPrefix(databaseURL.lastPathComponent) {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// Removes only retained audio after the configured window. Searchable
    /// notes/transcripts remain until the user deletes the meeting itself.
    func pruneAudio(olderThanDays days: Int) {
        guard days > 0 else { return }
        queue.async { [self] in
            let cutoff = Date().timeIntervalSince1970 - Double(days) * 86_400
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT id, mic_path, system_path FROM meetings
                WHERE status IN ('ready', 'failed') AND ended_at < ?
                  AND (mic_path IS NOT NULL OR system_path IS NOT NULL);
                """, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, cutoff)
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = columnText(stmt, 0) else { continue }
                ids.append(id)
                for column in [1, 2] {
                    if let relative = columnText(stmt, Int32(column)),
                       let url = audioURL(relativePath: relative) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            sqlite3_finalize(stmt)
            for id in ids {
                var update: OpaquePointer?
                if sqlite3_prepare_v2(
                    db, "UPDATE meetings SET mic_path = NULL, system_path = NULL WHERE id = ?;",
                    -1, &update, nil) == SQLITE_OK {
                    bindText(update, 1, id); sqlite3_step(update)
                }
                sqlite3_finalize(update)
            }
            if !ids.isEmpty {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .veloraMeetingsChanged, object: nil)
                }
            }
        }
    }

    // MARK: - Reads

    func recent(limit: Int = 100) -> [MeetingRecord] {
        queue.sync { [self] in
            recordsOnQueue(
                whereClause: "", bindings: [], limit: min(500, max(1, limit)))
        }
    }

    /// Lightweight rows for the meeting picker. A long transcript is loaded
    /// only for the selected meeting, never N times just to render N chips.
    func recentMetadata(limit: Int = 100) -> [MeetingRecord] {
        queue.sync { [self] in
            recordsOnQueue(
                whereClause: "", bindings: [], limit: min(500, max(1, limit)),
                includeSegments: false)
        }
    }

    func record(id: String) -> MeetingRecord? {
        queue.sync { [self] in
            recordsOnQueue(whereClause: "WHERE id = ?", bindings: [id], limit: 1).first
        }
    }

    /// Notes/status without transcript rows. Window shells use this first so
    /// a long selectable transcript never blocks tab or window presentation.
    func recordMetadata(id: String) -> MeetingRecord? {
        queue.sync { [self] in
            recordsOnQueue(
                whereClause: "WHERE id = ?", bindings: [id], limit: 1,
                includeSegments: false).first
        }
    }

    func hasCommittedSegments(meetingID: String) -> Bool {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM meeting_segments WHERE meeting_id = ? LIMIT 1;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func hasPendingNotes(meetingID: String) -> Bool {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT notes_pending FROM meetings WHERE id = ? LIMIT 1;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            return sqlite3_step(stmt) == SQLITE_ROW
                && sqlite3_column_int(stmt, 0) == 1
        }
    }

    /// True once the meeting's one automatic notes retry is spent. A
    /// processing notes job with it spent was, in practice, that automatic
    /// retry, so a crash-resume keeps it quiet. (A user Retry Notes after a
    /// cancel also matches; it then resumes quietly too.)
    func notesAutoRetried(meetingID: String) -> Bool {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT notes_auto_retried FROM meetings WHERE id = ? LIMIT 1;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            return sqlite3_step(stmt) == SQLITE_ROW
                && sqlite3_column_int(stmt, 0) == 1
        }
    }

    /// Retry Notes regenerates notes from the saved transcript: notes that
    /// never finished, or that cover only part of it.
    func canRetryNotes(meetingID: String) -> Bool {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT 1 FROM meetings
                WHERE id = ? AND (notes_pending = 1 OR notes_partial = 1)
                  AND EXISTS (
                      SELECT 1 FROM meeting_segments
                      WHERE meeting_id = meetings.id LIMIT 1)
                LIMIT 1;
                """, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    func recoverable() -> [MeetingRecord] {
        queue.sync { [self] in
            recordsOnQueue(
                whereClause: "WHERE status IN ('processing', 'failed')",
                bindings: [], limit: 100, includeSegments: false)
        }
    }

    /// Work interrupted while it was actively processing resumes on launch or
    /// engine reconnect. Permanently failed/cancelled rows stay user-driven so
    /// a poison file cannot create an automatic retry loop.
    func resumable() -> [MeetingRecord] {
        queue.sync { [self] in
            recordsOnQueue(
                whereClause: "WHERE status = 'processing'",
                bindings: [], limit: 100, includeSegments: false)
        }
    }

    /// Ready transcripts whose notes failed, were never regenerated, and
    /// have not had their one automatic retry. They sit outside
    /// `resumable()` because a failure is user-driven by default.
    func stalledNotes() -> [MeetingRecord] {
        queue.sync { [self] in
            recordsOnQueue(
                whereClause: """
                    WHERE status = 'ready' AND notes_pending = 1
                      AND notes_auto_retried = 0
                      AND summary = '' AND decisions = '' AND action_items = ''
                      AND EXISTS (
                          SELECT 1 FROM meeting_segments
                          WHERE meeting_id = meetings.id LIMIT 1)
                    """,
                bindings: [], limit: 100, includeSegments: false)
        }
    }

    func search(_ query: String, limit: Int = 50) -> [MeetingSearchHit] {
        self.queue.sync { [self] in
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return recordsOnQueue(
                    whereClause: "WHERE status = 'ready'", bindings: [],
                    limit: min(100, max(1, limit))).map {
                    MeetingSearchHit(
                        id: $0.id, meetingID: $0.id, title: $0.title,
                        startedAt: $0.startedAt,
                        snippet: $0.notes.summary.isEmpty ? $0.formattedTranscript : $0.notes.summary)
                }
            }
            if ftsAvailable, let expression = Self.ftsExpression(trimmed) {
                var stmt: OpaquePointer?
                let sql = """
                    SELECT m.id, m.title, m.started_at,
                           snippet(meeting_search, -1, '‹', '›', ' … ', 18)
                    FROM meeting_search JOIN meetings m ON m.id = meeting_search.meeting_id
                    WHERE meeting_search MATCH ? AND m.status = 'ready'
                    ORDER BY rank LIMIT ?;
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, expression)
                sqlite3_bind_int(stmt, 2, Int32(min(100, max(1, limit))))
                var hits: [MeetingSearchHit] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let id = columnText(stmt, 0), let title = columnText(stmt, 1) else { continue }
                    hits.append(MeetingSearchHit(
                        id: id, meetingID: id, title: title,
                        startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                        snippet: columnText(stmt, 3) ?? ""))
                }
                return hits
            }
            return likeSearchOnQueue(trimmed, limit: limit)
        }
    }

    func audioURL(relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let components = relativePath.split(
            separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2,
              UUID(uuidString: components[0]) != nil,
              components[1] == "me.caf" || components[1] == "them.caf"
                  || components[1] == "them.m4a"
        else { return nil }
        let root = filesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    /// A prepared CAF header exists even when capture wrote zero frames, and
    /// random/corrupt bytes can also exceed a size threshold. Retry is offered
    /// only when Core Audio can open the container, observe real frames, and
    /// the engine's loader accepts the format (`MeetingTrackFormat`).
    func hasUsableAudio(relativePath: String?) -> Bool {
        guard let url = audioURL(relativePath: relativePath),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 4_096,
              let audio = try? AVAudioFile(forReading: url)
        else { return false }
        return audio.length > 0 && MeetingTrackFormat.isSupported(audio)
    }

    /// Retry needs one track the engine can decode; the other side may be
    /// missing or unreadable and is then reported as a track issue.
    func hasAnyUsableAudio(for record: MeetingRecord) -> Bool {
        [record.micPath, record.systemPath].contains { hasUsableAudio(relativePath: $0) }
    }

    /// Recreate must retain every side that was originally captured. A single
    /// readable track is sufficient for a first pass, but not for replacing an
    /// existing two-sided transcript. A track that recorded only silence is
    /// still readable, so it does not block Recreate.
    func hasAllCapturedAudio(for record: MeetingRecord) -> Bool {
        let captured = [record.micPath, record.systemPath].compactMap { $0 }
        guard !captured.isEmpty else { return false }
        return captured.allSatisfy { hasUsableAudio(relativePath: $0) }
    }

    private func meetingDirectoryURL(id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let root = filesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    private func recordsOnQueue(
        whereClause: String, bindings: [String], limit: Int,
        includeSegments: Bool = true
    ) -> [MeetingRecord] {
        let sql = """
            SELECT id, title, started_at, ended_at, source_app, calendar_event_id,
                   status, summary, decisions, action_items, mic_path, system_path, error,
                   mic_issue, system_issue, notes_partial
            FROM meetings \(whereClause) ORDER BY started_at DESC LIMIT ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        for binding in bindings { bindText(stmt, index, binding); index += 1 }
        sqlite3_bind_int(stmt, index, Int32(limit))
        var output: [MeetingRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0), let title = columnText(stmt, 1) else { continue }
            let status = MeetingStatus(rawValue: columnText(stmt, 6) ?? "") ?? .failed
            output.append(MeetingRecord(
                id: id,
                title: title,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                endedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                sourceApp: columnText(stmt, 4),
                calendarEventID: columnText(stmt, 5),
                status: status,
                notes: MeetingNotes(
                    summary: columnText(stmt, 7) ?? "",
                    decisions: Self.lines(columnText(stmt, 8)),
                    actionItems: Self.lines(columnText(stmt, 9)),
                    partial: sqlite3_column_int(stmt, 15) == 1),
                micPath: columnText(stmt, 10),
                systemPath: columnText(stmt, 11),
                error: columnText(stmt, 12),
                micIssue: Self.issue(from: columnText(stmt, 13)),
                systemIssue: Self.issue(from: columnText(stmt, 14)),
                segments: includeSegments ? segmentsOnQueue(meetingID: id) : []))
        }
        return output
    }

    private func appendSegmentOnQueue(_ segment: MeetingSegment, table: String) {
        guard db != nil,
              table == "meeting_segments" || table == "meeting_reprocess_segments",
              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let sql = """
            INSERT OR REPLACE INTO \(table)
                (meeting_id, speaker, chunk_index, start_ms, end_ms, text)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, segment.meetingID)
        bindText(stmt, 2, segment.speaker.rawValue)
        sqlite3_bind_int64(stmt, 3, Int64(segment.chunkIndex))
        sqlite3_bind_int64(stmt, 4, Int64(segment.startMs))
        sqlite3_bind_int64(stmt, 5, Int64(segment.endMs))
        bindText(stmt, 6, segment.text)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("Velora: meeting segment insert failed: %@", lastError)
        }
    }

    private func nextChunkOnQueue(
        meetingID: String, speaker: MeetingSpeaker, table: String
    ) -> Int {
        guard table == "meeting_segments" || table == "meeting_reprocess_segments"
        else { return 0 }
        var stmt: OpaquePointer?
        let condition = speaker.isRemote ? "speaker != 'me'" : "speaker = 'me'"
        guard sqlite3_prepare_v2(db, """
            SELECT COALESCE(MAX(chunk_index) + 1, 0) FROM \(table)
            WHERE meeting_id = ? AND \(condition);
            """, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, meetingID)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func deleteSegmentsOnQueue(
        meetingID: String, remoteTrack: Bool, table: String
    ) {
        guard table == "meeting_segments" || table == "meeting_reprocess_segments"
        else { return }
        var stmt: OpaquePointer?
        let condition = remoteTrack ? "speaker != 'me'" : "speaker = 'me'"
        guard sqlite3_prepare_v2(db, """
            DELETE FROM \(table) WHERE meeting_id = ? AND \(condition);
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, meetingID)
        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("Velora: meeting segment reset failed: %@", lastError)
        }
    }

    private func hasSegmentsOnQueue(
        meetingID: String, speaker: MeetingSpeaker, table: String
    ) -> Bool {
        guard table == "meeting_segments" || table == "meeting_reprocess_segments"
        else { return false }
        let condition = speaker.isRemote ? "speaker != 'me'" : "speaker = 'me'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT 1 FROM \(table)
            WHERE meeting_id = ? AND \(condition) LIMIT 1;
            """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, meetingID)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func executeOnQueue(_ sql: String, meetingID: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, meetingID)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func transactionOnQueue(_ body: () -> Bool) -> Bool {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        guard body(),
              sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return false
        }
        return true
    }

    private func segmentsOnQueue(
        meetingID: String, table: String = "meeting_segments"
    ) -> [MeetingSegment] {
        guard table == "meeting_segments" || table == "meeting_reprocess_segments"
        else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT id, speaker, chunk_index, start_ms, end_ms, text
            FROM \(table) WHERE meeting_id = ?
            ORDER BY start_ms, speaker, chunk_index;
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, meetingID)
        var segments: [MeetingSegment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let speakerName = columnText(stmt, 1),
                  let speaker = MeetingSpeaker(rawValue: speakerName),
                  let text = columnText(stmt, 5) else { continue }
            segments.append(MeetingSegment(
                id: sqlite3_column_int64(stmt, 0), meetingID: meetingID,
                speaker: speaker, chunkIndex: Int(sqlite3_column_int64(stmt, 2)),
                startMs: Int(sqlite3_column_int64(stmt, 3)),
                endMs: Int(sqlite3_column_int64(stmt, 4)), text: text))
        }
        return segments
    }

    private func refreshSearchOnQueue(meetingID: String) {
        guard ftsAvailable, let record = recordsOnQueue(
            whereClause: "WHERE id = ?", bindings: [meetingID], limit: 1).first else { return }
        var delete: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "DELETE FROM meeting_search WHERE meeting_id = ?;", -1, &delete, nil) == SQLITE_OK {
            bindText(delete, 1, meetingID); sqlite3_step(delete)
        }
        sqlite3_finalize(delete)
        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO meeting_search
                (meeting_id, title, transcript, summary, decisions, action_items)
            VALUES (?, ?, ?, ?, ?, ?);
            """, -1, &insert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }
        bindText(insert, 1, meetingID)
        bindText(insert, 2, record.title)
        bindText(insert, 3, record.formattedTranscript)
        bindText(insert, 4, record.notes.summary)
        bindText(insert, 5, record.notes.decisions.joined(separator: "\n"))
        bindText(insert, 6, record.notes.actionItems.joined(separator: "\n"))
        sqlite3_step(insert)
    }

    private func likeSearchOnQueue(_ query: String, limit: Int) -> [MeetingSearchHit] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var stmt: OpaquePointer?
        let sql = """
            SELECT DISTINCT m.id, m.title, m.started_at,
                CASE WHEN m.summary != '' THEN m.summary ELSE s.text END
            FROM meetings m LEFT JOIN meeting_segments s ON s.meeting_id = m.id
            WHERE m.status = 'ready' AND (
                m.title LIKE ? ESCAPE '\\' OR m.summary LIKE ? ESCAPE '\\'
                OR m.decisions LIKE ? ESCAPE '\\' OR m.action_items LIKE ? ESCAPE '\\'
                OR s.text LIKE ? ESCAPE '\\')
            ORDER BY m.started_at DESC LIMIT ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(escaped)%"
        for index in 1...5 { bindText(stmt, Int32(index), pattern) }
        sqlite3_bind_int(stmt, 6, Int32(min(100, max(1, limit))))
        var hits: [MeetingSearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0), let title = columnText(stmt, 1) else { continue }
            hits.append(MeetingSearchHit(
                id: id, meetingID: id, title: title,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                snippet: columnText(stmt, 3) ?? ""))
        }
        return hits
    }

    private static func ftsExpression(_ query: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-'"))
        let tokens = query.components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }.prefix(12)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }

    // Track issues persist as "silent", "too_short" or "failed:<engine message>".
    private static let silentIssueText = "silent"
    private static let tooShortIssueText = "too_short"
    private static let failedIssuePrefix = "failed:"

    private static func issueText(_ issue: MeetingTrackIssue?) -> String? {
        switch issue {
        case nil:
            return nil
        case .silent:
            return silentIssueText
        case .tooShort:
            return tooShortIssueText
        case .failed(let message):
            return failedIssuePrefix + String(message.prefix(1_000))
        }
    }

    private static func issue(from text: String?) -> MeetingTrackIssue? {
        guard let text else { return nil }
        if text == silentIssueText { return .silent }
        if text == tooShortIssueText { return .tooShort }
        guard text.hasPrefix(failedIssuePrefix) else { return nil }
        return .failed(String(text.dropFirst(failedIssuePrefix.count)))
    }

    private static func lines(_ value: String?) -> [String] {
        (value ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, Self.transient) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: pointer)
    }
}
