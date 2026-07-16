import Foundation
import SQLite3

/// One completed dictation.
struct DictationRecord {
    var id: Int64 = 0
    let timestamp: Date
    let bundleID: String?
    let appName: String?
    let raw: String
    let final: String
    let mode: String?
    let durationMs: Int
    let cleanupMs: Int?
    /// Basename of the archived audio clip under `~/.velora/audio/`, if the
    /// engine saved one (`save_audio`). Nil when archiving was off.
    var audioPath: String? = nil
    /// Engine session UUID — the key later asynchronous quality-observation
    /// updates match on (never the rowid, which insert() doesn't report back).
    var sessionID: String? = nil
    /// STT decode latency from the engine's `transcript` event. Nil on rows
    /// from builds that predate latency capture.
    var sttMs: Int? = nil
    /// Whether LLM cleanup produced `final` (`final.cleanup_applied`). Nil =
    /// unknown (legacy row) — distinct from false (cleanup skipped/failed).
    var cleanupApplied: Bool? = nil
}

/// What the edit-learning loop honestly observed about a dictation after
/// insertion. Rows it could not watch (no AX element, unreadable field,
/// oversized text, ambiguous diff) stay NULL and never enter the zero-edit
/// rate — they only lower observation coverage.
enum QualityObservation: Int {
    /// The inserted text was still intact when observation ended.
    case unchanged = 1
    /// The user demonstrably edited the inserted text.
    case edited = 2
}

/// Local dictation history — SQLite via the raw sqlite3 C API (no
/// dependencies). Database lives at `~/.velora/history.sqlite3`.
///
/// P0 surface: insert on every completed dictation + last-3 for the menubar.
/// The full history browser is P1; storage is day-one (docs/SPEC.md).
final class HistoryStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.velora.history")

    /// SQLITE_TRANSIENT: make sqlite copy bound strings immediately.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = AppConfig.historyDatabaseURL) {
        AppConfig.shared.ensureVeloraDirectory()
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) == SQLITE_OK {
            db = handle
            // The engine's idle vocab miner reads this DB concurrently; without
            // a busy timeout an INSERT that collides with its SELECT fails
            // SQLITE_BUSY instantly and the dictation silently vanishes from
            // history (review finding).
            sqlite3_busy_timeout(handle, 2000)
            createTableIfNeeded()
            // Transcript store is owner-only (default umask would be 0644).
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            NSLog("Velora: failed to open history database at %@", url.path)
            if handle != nil { sqlite3_close(handle) }
            db = nil
        }
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func createTableIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS dictations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                bundle_id TEXT,
                app_name TEXT,
                raw TEXT NOT NULL,
                final TEXT NOT NULL,
                mode TEXT,
                duration_ms INTEGER NOT NULL,
                cleanup_ms INTEGER
            );
            """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Velora: failed to create dictations table: %@", lastError)
        }
        migrateSchema()
    }

    /// Additive migrations for stores created by older builds. Inspecting the
    /// schema first avoids emitting a scary sqlite "duplicate column" error
    /// into Console on every normal launch of an already-migrated app.
    private func migrateSchema() {
        let existing = tableColumns("dictations")
        let additions = [
            ("audio_path", "TEXT"),
            ("session_id", "TEXT"),
            ("stt_ms", "INTEGER"),
            ("cleanup_applied", "INTEGER"),
            ("quality_state", "INTEGER"),
        ]
        for (name, declaration) in additions where !existing.contains(name) {
            if sqlite3_exec(
                db, "ALTER TABLE dictations ADD COLUMN \(name) \(declaration)",
                nil, nil, nil) != SQLITE_OK {
                NSLog("Velora: history migration failed for %@: %@", name, lastError)
            }
        }
        // Quality observations arrive seconds-to-minutes after the insert and
        // update by session UUID; keep that lookup off a full table scan.
        sqlite3_exec(
            db, "CREATE INDEX IF NOT EXISTS idx_dictations_session ON dictations(session_id)",
            nil, nil, nil)
    }

    private func tableColumns(_ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil)
                == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 1) { names.insert(name) }
        }
        return names
    }

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    // MARK: - Writes

    /// Persists a completed dictation. Fire-and-forget (background queue).
    func insert(_ record: DictationRecord) {
        queue.async { [self] in
            guard db != nil else { return }
            let sql = """
                INSERT INTO dictations
                    (ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms,
                     audio_path, session_id, stt_ms, cleanup_applied)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("Velora: history insert prepare failed: %@", lastError)
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, record.timestamp.timeIntervalSince1970)
            bindText(stmt, 2, record.bundleID)
            bindText(stmt, 3, record.appName)
            bindText(stmt, 4, record.raw)
            bindText(stmt, 5, record.final)
            bindText(stmt, 6, record.mode)
            sqlite3_bind_int64(stmt, 7, Int64(record.durationMs))
            if let cleanupMs = record.cleanupMs {
                sqlite3_bind_int64(stmt, 8, Int64(cleanupMs))
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            bindText(stmt, 9, record.audioPath)
            bindText(stmt, 10, record.sessionID)
            if let sttMs = record.sttMs {
                sqlite3_bind_int64(stmt, 11, Int64(sttMs))
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            if let applied = record.cleanupApplied {
                sqlite3_bind_int(stmt, 12, applied ? 1 : 0)
            } else {
                sqlite3_bind_null(stmt, 12)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("Velora: history insert failed: %@", lastError)
            }
        }
    }

    /// Records what the edit-learning loop observed for a session's row.
    /// Runs on the same serial queue as `insert`, so the row (enqueued at
    /// final-event time, seconds earlier) is always persisted first — keyed by
    /// the session UUID because the async insert never reports its rowid.
    /// First observation wins; later triggers for the same session are no-ops.
    func markQualityObservation(session: String, state: QualityObservation) {
        guard !session.isEmpty else { return }
        queue.async { [self] in
            guard db != nil else { return }
            let sql = """
                UPDATE dictations SET quality_state = ?
                WHERE session_id = ? AND quality_state IS NULL;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(state.rawValue))
            bindText(stmt, 2, session)
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("Velora: quality observation update failed: %@", lastError)
            }
        }
    }

    /// Rewrites a row after a `reprocess` produced a better transcript. Runs
    /// synchronously so the caller can refresh the list right after.
    func updateAfterReprocess(
        id: Int64, raw: String, final: String, mode: String?,
        sttMs: Int, cleanupMs: Int, cleanupApplied: Bool
    ) {
        queue.sync { [self] in
            guard db != nil else { return }
            // A reprocess replaces the measured output, so its latency and
            // cleanup fields replace the old run too. Any prior edit-quality
            // verdict described the old text and must not survive the rewrite.
            let sql = """
                UPDATE dictations
                SET raw = ?, final = ?, mode = ?, stt_ms = ?, cleanup_ms = ?,
                    cleanup_applied = ?, quality_state = NULL
                WHERE id = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, raw)
            bindText(stmt, 2, final)
            bindText(stmt, 3, mode)
            sqlite3_bind_int64(stmt, 4, Int64(sttMs))
            sqlite3_bind_int64(stmt, 5, Int64(cleanupMs))
            sqlite3_bind_int(stmt, 6, cleanupApplied ? 1 : 0)
            sqlite3_bind_int64(stmt, 7, id)
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("Velora: history update failed: %@", lastError)
            }
        }
    }

    /// Deletes a single row and its archived audio clip (if any).
    func delete(id: Int64) {
        queue.sync { [self] in
            guard db != nil else { return }
            // Remove the clip first — best effort; a missing file is fine.
            if let name = audioPathOnQueue(forID: id) { Self.removeClip(name) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictations WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
        }
    }

    /// Wipes the entire history, including every archived audio clip.
    func deleteAll() {
        queue.sync { [self] in
            guard db != nil else { return }
            for name in allAudioPathsOnQueue() { Self.removeClip(name) }
            sqlite3_exec(db, "DELETE FROM dictations;", nil, nil, nil)
        }
    }

    /// Looks up the clip basename for a row. MUST be called on `queue`.
    private func audioPathOnQueue(forID id: Int64) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT audio_path FROM dictations WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }

    /// Every non-null clip basename in the store. MUST be called on `queue`.
    private func allAudioPathsOnQueue() -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT audio_path FROM dictations WHERE audio_path IS NOT NULL;",
            -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 0) { names.append(name) }
        }
        return names
    }

    /// Deletes an archived clip by basename (ignores a missing file).
    private static func removeClip(_ name: String) {
        guard let url = AppConfig.archivedAudioURL(name: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes rows older than `days` (matches the audio retention window so
    /// the transcript store and the clips age out together). Called once at
    /// startup; fire-and-forget.
    func pruneOlderThan(days: Double) {
        queue.async { [self] in
            guard db != nil, days > 0 else { return }
            let cutoff = Date().timeIntervalSince1970 - days * 86_400
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictations WHERE ts < ?;", -1, &stmt, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    // MARK: - Reads

    /// Column list shared by every read so decode offsets stay in lockstep.
    private static let selectColumns =
        "id, ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms, audio_path, " +
        "session_id, stt_ms, cleanup_applied"

    /// Most recent dictations, newest first. Synchronous — called on menu
    /// open with tiny result sets.
    func recent(limit: Int = 3) -> [DictationRecord] {
        queue.sync { [self] in
            guard db != nil else { return [] }
            let sql = """
                SELECT \(Self.selectColumns)
                FROM dictations ORDER BY ts DESC LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            return decodeRows(stmt)
        }
    }

    /// A page of history, newest first, with an optional case-insensitive
    /// substring filter over the final text, raw transcript, and app name.
    func page(limit: Int, offset: Int, search: String?) -> [DictationRecord] {
        queue.sync { [self] in
            guard db != nil else { return [] }
            let term = Self.likeTerm(search)
            var sql = "SELECT \(Self.selectColumns) FROM dictations"
            if term != nil {
                sql += " WHERE " + Self.likeClause
            }
            sql += " ORDER BY ts DESC LIMIT ? OFFSET ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var next: Int32 = 1
            if let term { bindText(stmt, next, term); next += 1 }
            sqlite3_bind_int(stmt, next, Int32(limit)); next += 1
            sqlite3_bind_int(stmt, next, Int32(offset))
            return decodeRows(stmt)
        }
    }

    /// Aggregate usage numbers for the History header (words ≈ space-separated
    /// tokens of the final text; computed in SQL so a big history never loads
    /// into memory).
    struct Stats: Equatable {
        var totalWords = 0
        var totalCount = 0
        var totalSpokenMs = 0
        var todayWords = 0
        var todayCount = 0
        /// Consecutive calendar days (ending today or yesterday) with at
        /// least one dictation.
        var streakDays = 0

        /// Minutes saved vs typing the same words at the user's typing speed
        /// (Settings → Intelligence; default 40 wpm).
        func minutesSaved(typingWPM: Int) -> Int {
            HistoryStore.minutesSaved(
                words: totalWords, spokenMs: totalSpokenMs, typingWPM: typingWPM)
        }
    }

    /// Shared time-saved definition: minutes to type `words` at `typingWPM`
    /// minus the minutes actually spent speaking, floored at zero.
    static func minutesSaved(words: Int, spokenMs: Int, typingWPM: Int) -> Int {
        guard typingWPM > 0 else { return 0 }
        let typingMs = Int64(max(0, words)) * 60_000 / Int64(typingWPM)
        let savedMs = max(0, typingMs - Int64(max(0, spokenMs)))
        return Int(savedMs / 60_000)
    }

    /// `final` with newlines/tabs folded to spaces so the word estimate
    /// counts multiline notes correctly (review finding).
    private static let flatFinal =
        "REPLACE(REPLACE(final, char(10), ' '), char(9), ' ')"
    private static let wordsExpr =
        "COALESCE(SUM(LENGTH(TRIM(\(flatFinal))) - LENGTH(REPLACE(TRIM(\(flatFinal)), ' ', '')) + 1), 0)"
    private static let nonEmpty = "TRIM(\(flatFinal)) != ''"

    func stats() -> Stats {
        queue.sync { [self] in
            guard db != nil else { return Stats() }
            var s = Stats()
            var stmt: OpaquePointer?
            let all = "SELECT COUNT(*), \(Self.wordsExpr), COALESCE(SUM(duration_ms), 0) " +
                "FROM dictations WHERE \(Self.nonEmpty);"
            if sqlite3_prepare_v2(db, all, -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW {
                s.totalCount = Int(sqlite3_column_int64(stmt, 0))
                s.totalWords = Int(sqlite3_column_int64(stmt, 1))
                s.totalSpokenMs = Int(sqlite3_column_int64(stmt, 2))
            }
            sqlite3_finalize(stmt); stmt = nil

            let today = "SELECT COUNT(*), \(Self.wordsExpr) FROM dictations " +
                "WHERE \(Self.nonEmpty) AND date(ts, 'unixepoch', 'localtime') = date('now', 'localtime');"
            if sqlite3_prepare_v2(db, today, -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW {
                s.todayCount = Int(sqlite3_column_int64(stmt, 0))
                s.todayWords = Int(sqlite3_column_int64(stmt, 1))
            }
            sqlite3_finalize(stmt); stmt = nil

            let days = "SELECT DISTINCT date(ts, 'unixepoch', 'localtime') FROM dictations " +
                "WHERE \(Self.nonEmpty) ORDER BY 1 DESC LIMIT 400;"
            var dayStrings: [String] = []
            if sqlite3_prepare_v2(db, days, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { dayStrings.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            s.streakDays = Self.streak(days: dayStrings)
            return s
        }
    }

    /// Counts consecutive days from `days` (yyyy-MM-dd, newest first). The
    /// streak is alive if it includes today OR yesterday (today's first
    /// dictation may simply not have happened yet).
    static func streak(days: [String]) -> Int {
        guard !days.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let calendar = Calendar.current
        guard let newest = formatter.date(from: days[0]) else { return 0 }
        let daysAgo = calendar.dateComponents(
            [.day], from: newest, to: calendar.startOfDay(for: Date())).day ?? 0
        guard daysAgo <= 1 else { return 0 }
        var streak = 1
        var previous = newest
        for dayString in days.dropFirst() {
            guard let day = formatter.date(from: dayString),
                  calendar.dateComponents([.day], from: day, to: previous).day == 1
            else { break }
            streak += 1
            previous = day
        }
        return streak
    }

    /// Longest run of consecutive days anywhere in `days` (yyyy-MM-dd, newest
    /// first) — unlike `streak`, it doesn't have to reach today.
    static func longestStreak(days: [String]) -> Int {
        guard !days.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let calendar = Calendar.current
        var longest = 0
        var run = 0
        var previous: Date?
        for dayString in days {
            guard let day = formatter.date(from: dayString) else {
                run = 0
                previous = nil
                continue
            }
            if let previous, calendar.dateComponents([.day], from: day, to: previous).day == 1 {
                run += 1
            } else {
                run = 1
            }
            previous = day
            longest = max(longest, run)
        }
        return longest
    }

    // MARK: - Intelligence aggregates

    /// One time window of Intelligence metrics. Everything is computed in SQL;
    /// the derived rates return nil (not 0) when the underlying rows carry no
    /// data, so the UI can say "no data" instead of overclaiming.
    struct WindowStats: Equatable {
        var count = 0
        var words = 0
        var spokenMs = 0
        var sttSamples = 0
        var sttTotalMs = 0
        var cleanupSamples = 0
        var cleanupTotalMs = 0
        /// Rows whose cleanup_applied state is known (post-migration rows).
        var cleanupKnown = 0
        var cleanupApplied = 0
        /// Cleanup-applied rows where the final text actually differs from the
        /// raw transcript (the raw→final delta).
        var cleanupChanged = 0
        var qualityUnchanged = 0
        var qualityEdited = 0

        var averageSttMs: Int? {
            sttSamples > 0 ? sttTotalMs / sttSamples : nil
        }
        var averageCleanupMs: Int? {
            cleanupSamples > 0 ? cleanupTotalMs / cleanupSamples : nil
        }
        /// Share of state-known dictations where cleanup produced the final.
        var cleanupAppliedRate: Double? {
            cleanupKnown > 0 ? Double(cleanupApplied) / Double(cleanupKnown) : nil
        }
        /// Among cleanup-applied dictations, how often cleanup changed the raw.
        var cleanupChangedRate: Double? {
            cleanupApplied > 0 ? Double(cleanupChanged) / Double(cleanupApplied) : nil
        }
        var qualityObserved: Int { qualityUnchanged + qualityEdited }
        /// unchanged / honestly-observed. Nil when nothing was observable —
        /// unobserved rows never count as zero-edit successes.
        var zeroEditRate: Double? {
            qualityObserved > 0 ? Double(qualityUnchanged) / Double(qualityObserved) : nil
        }
        /// observed / all dictations in the window — shown next to the rate so
        /// a sparse observation set can't masquerade as a universal claim.
        var observationCoverage: Double? {
            count > 0 ? Double(qualityObserved) / Double(count) : nil
        }
        func minutesSaved(typingWPM: Int) -> Int {
            HistoryStore.minutesSaved(words: words, spokenMs: spokenMs, typingWPM: typingWPM)
        }
    }

    /// One calendar day of activity (`yyyy-MM-dd`, local time).
    struct DaySample: Equatable {
        let day: String
        let count: Int
        let words: Int
    }

    /// One app/mode slice of the last-30-days breakdown.
    struct BreakdownSlice: Equatable {
        let name: String
        let count: Int
        let words: Int
    }

    /// The Intelligence tab's whole data set. Every query returns aggregates
    /// or day/slice-bounded rows — a 100k-row history never streams into
    /// Swift memory.
    struct Insights: Equatable {
        var today = WindowStats()
        var week = WindowStats()
        var month = WindowStats()
        var allTime = WindowStats()
        var currentStreak = 0
        var longestStreak = 0
        /// Days with activity in the last 30 (ascending; gaps omitted).
        var daily: [DaySample] = []
        /// Top apps / modes by words over the last 30 days.
        var apps: [BreakdownSlice] = []
        var modes: [BreakdownSlice] = []
    }

    private static let localDay = "date(ts, 'unixepoch', 'localtime')"

    func insights() -> Insights {
        queue.sync { [self] in
            guard db != nil else { return Insights() }
            var result = Insights()
            result.today = windowStatsOnQueue(daysBack: 0)
            result.week = windowStatsOnQueue(daysBack: 6)
            result.month = windowStatsOnQueue(daysBack: 29)
            result.allTime = windowStatsOnQueue(daysBack: nil)
            result.daily = dailySeriesOnQueue()
            result.apps = breakdownOnQueue(
                expr: "COALESCE(app_name, 'Unknown app')")
            result.modes = breakdownOnQueue(
                expr: "COALESCE(NULLIF(mode, ''), 'Default')")
            let days = activeDaysOnQueue()
            result.currentStreak = Self.streak(days: days)
            result.longestStreak = Self.longestStreak(days: days)
            return result
        }
    }

    /// Aggregates one calendar-day window. `daysBack` 0 = today only,
    /// nil = all time. MUST be called on `queue`.
    private func windowStatsOnQueue(daysBack: Int?) -> WindowStats {
        var sql = """
            SELECT COUNT(*), \(Self.wordsExpr), COALESCE(SUM(duration_ms), 0),
                COUNT(stt_ms), COALESCE(SUM(stt_ms), 0),
                COUNT(cleanup_ms), COALESCE(SUM(cleanup_ms), 0),
                COUNT(cleanup_applied),
                COALESCE(SUM(CASE WHEN cleanup_applied = 1 THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN cleanup_applied = 1 AND raw != final THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN quality_state = \(QualityObservation.unchanged.rawValue) THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN quality_state = \(QualityObservation.edited.rawValue) THEN 1 ELSE 0 END), 0)
            FROM dictations WHERE \(Self.nonEmpty)
            """
        if let daysBack {
            sql += " AND \(Self.localDay) >= date('now', 'localtime', '-\(daysBack) days')"
        }
        var stats = WindowStats()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Velora: insights window query failed: %@", lastError)
            return stats
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return stats }
        stats.count = Int(sqlite3_column_int64(stmt, 0))
        stats.words = Int(sqlite3_column_int64(stmt, 1))
        stats.spokenMs = Int(sqlite3_column_int64(stmt, 2))
        stats.sttSamples = Int(sqlite3_column_int64(stmt, 3))
        stats.sttTotalMs = Int(sqlite3_column_int64(stmt, 4))
        stats.cleanupSamples = Int(sqlite3_column_int64(stmt, 5))
        stats.cleanupTotalMs = Int(sqlite3_column_int64(stmt, 6))
        stats.cleanupKnown = Int(sqlite3_column_int64(stmt, 7))
        stats.cleanupApplied = Int(sqlite3_column_int64(stmt, 8))
        stats.cleanupChanged = Int(sqlite3_column_int64(stmt, 9))
        stats.qualityUnchanged = Int(sqlite3_column_int64(stmt, 10))
        stats.qualityEdited = Int(sqlite3_column_int64(stmt, 11))
        return stats
    }

    /// Per-day activity for the last 30 calendar days. MUST be called on `queue`.
    private func dailySeriesOnQueue() -> [DaySample] {
        let sql = """
            SELECT \(Self.localDay), COUNT(*), \(Self.wordsExpr)
            FROM dictations
            WHERE \(Self.nonEmpty)
              AND \(Self.localDay) >= date('now', 'localtime', '-29 days')
            GROUP BY 1 ORDER BY 1 ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var samples: [DaySample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            samples.append(DaySample(
                day: columnText(stmt, 0) ?? "",
                count: Int(sqlite3_column_int64(stmt, 1)),
                words: Int(sqlite3_column_int64(stmt, 2))))
        }
        return samples
    }

    /// Top slices by words over the last 30 days. MUST be called on `queue`.
    private func breakdownOnQueue(expr: String) -> [BreakdownSlice] {
        let sql = """
            SELECT \(expr), COUNT(*), \(Self.wordsExpr)
            FROM dictations
            WHERE \(Self.nonEmpty)
              AND \(Self.localDay) >= date('now', 'localtime', '-29 days')
            GROUP BY 1 ORDER BY 3 DESC LIMIT 6;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var slices: [BreakdownSlice] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            slices.append(BreakdownSlice(
                name: columnText(stmt, 0) ?? "Unknown",
                count: Int(sqlite3_column_int64(stmt, 1)),
                words: Int(sqlite3_column_int64(stmt, 2))))
        }
        return slices
    }

    /// Every distinct active day, newest first (bounded by days, not rows).
    /// MUST be called on `queue`.
    private func activeDaysOnQueue() -> [String] {
        let sql = "SELECT DISTINCT \(Self.localDay) FROM dictations WHERE \(Self.nonEmpty) ORDER BY 1 DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var days: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let day = columnText(stmt, 0) { days.append(day) }
        }
        return days
    }

    /// Total row count, honoring the same optional search filter as `page`.
    func count(search: String?) -> Int {
        queue.sync { [self] in
            guard db != nil else { return 0 }
            let term = Self.likeTerm(search)
            var sql = "SELECT COUNT(*) FROM dictations"
            if term != nil {
                sql += " WHERE " + Self.likeClause
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if let term { bindText(stmt, 1, term) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Search predicate shared by `page`/`count`. Uses `ESCAPE '\'` so the
    /// wildcards `likeTerm` escapes are treated literally.
    private static let likeClause =
        "final LIKE ?1 ESCAPE '\\' OR raw LIKE ?1 ESCAPE '\\' OR app_name LIKE ?1 ESCAPE '\\'"

    /// Wraps a non-empty trimmed search string in `%…%` for a LIKE match,
    /// escaping the LIKE metacharacters (`\`, `%`, `_`) the user typed so they
    /// match literally rather than acting as wildcards.
    private static func likeTerm(_ search: String?) -> String? {
        guard let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%" + escaped + "%"
    }

    /// Decodes every remaining row of a stepped statement using `selectColumns`.
    private func decodeRows(_ stmt: OpaquePointer?) -> [DictationRecord] {
        var records: [DictationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var record = DictationRecord(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                bundleID: columnText(stmt, 2),
                appName: columnText(stmt, 3),
                raw: columnText(stmt, 4) ?? "",
                final: columnText(stmt, 5) ?? "",
                mode: columnText(stmt, 6),
                durationMs: Int(sqlite3_column_int64(stmt, 7)),
                cleanupMs: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(stmt, 8)),
                audioPath: columnText(stmt, 9),
                sessionID: columnText(stmt, 10),
                sttMs: sqlite3_column_type(stmt, 11) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(stmt, 11)),
                cleanupApplied: sqlite3_column_type(stmt, 12) == SQLITE_NULL
                    ? nil : sqlite3_column_int(stmt, 12) != 0)
            record.id = sqlite3_column_int64(stmt, 0)
            records.append(record)
        }
        return records
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}
