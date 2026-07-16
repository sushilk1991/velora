import AVFoundation
import Foundation
import SQLite3

enum MeetingStatus: String {
    case recording
    case processing
    case ready
    case failed
}

enum MeetingSpeaker: String, CaseIterable {
    case me
    case them

    var displayName: String { self == .me ? "Me" : "Them" }
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
    var segments: [MeetingSegment] = []

    var durationMs: Int { max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000)) }

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
                error TEXT
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
            CREATE INDEX IF NOT EXISTS idx_meetings_started ON meetings(started_at DESC);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            NSLog("Velora: meeting schema failed: %@", lastError)
            return
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
            func recoveredTrack(_ relative: String?, allowFlushedBytes: Bool) -> String? {
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
                // The microphone CAF's data chunk can extend to EOF, and a
                // decoder may still reject partially flushed metadata after a
                // power loss. Preserve its bytes for an explicit retry. AAC
                // system audio, however, needs a finalized container; keeping
                // an unreadable .m4a would make a healthy recovered mic track
                // fail every retry after it had already transcribed.
                if allowFlushedBytes { return relative }
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            let recoveredMic = recoveredTrack(mic, allowFlushedBytes: true)
            let recoveredSystem = recoveredTrack(system, allowFlushedBytes: false)
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
            guard db != nil, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            let sql = """
                INSERT OR REPLACE INTO meeting_segments
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
    }

    func nextChunk(meetingID: String, speaker: MeetingSpeaker) -> Int {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT COALESCE(MAX(chunk_index) + 1, 0) FROM meeting_segments
                WHERE meeting_id = ? AND speaker = ?;
                """, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, meetingID)
            bindText(stmt, 2, speaker.rawValue)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    func complete(meetingID: String, notes: MeetingNotes) {
        queue.sync { [self] in
            guard db != nil else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                UPDATE meetings SET status = ?, summary = ?, decisions = ?,
                    action_items = ?, error = NULL WHERE id = ?;
                """, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, MeetingStatus.ready.rawValue)
            bindText(stmt, 2, notes.summary)
            bindText(stmt, 3, notes.decisions.joined(separator: "\n"))
            bindText(stmt, 4, notes.actionItems.joined(separator: "\n"))
            bindText(stmt, 5, meetingID)
            if sqlite3_step(stmt) == SQLITE_DONE { refreshSearchOnQueue(meetingID: meetingID) }
        }
    }

    func markFailed(meetingID: String, error: String) {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "UPDATE meetings SET status = ?, error = ? WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, MeetingStatus.failed.rawValue)
            bindText(stmt, 2, String(error.prefix(1_000)))
            bindText(stmt, 3, meetingID)
            sqlite3_step(stmt)
        }
    }

    func markProcessing(meetingID: String) {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "UPDATE meetings SET status = ?, error = NULL WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, MeetingStatus.processing.rawValue)
            bindText(stmt, 2, meetingID)
            sqlite3_step(stmt)
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
              components[1] == "me.caf" || components[1] == "them.m4a"
        else { return nil }
        let root = filesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
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
                   status, summary, decisions, action_items, mic_path, system_path, error
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
                    actionItems: Self.lines(columnText(stmt, 9))),
                micPath: columnText(stmt, 10),
                systemPath: columnText(stmt, 11),
                error: columnText(stmt, 12),
                segments: includeSegments ? segmentsOnQueue(meetingID: id) : []))
        }
        return output
    }

    private func segmentsOnQueue(meetingID: String) -> [MeetingSegment] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT id, speaker, chunk_index, start_ms, end_ms, text
            FROM meeting_segments WHERE meeting_id = ?
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
