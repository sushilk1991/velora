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

    /// Additive migrations for stores created by older builds. Each ALTER is
    /// attempted unconditionally; the "duplicate column" error on an
    /// already-migrated store is expected and ignored.
    private func migrateSchema() {
        // audio_path: basename of the archived clip (nil for pre-archive rows).
        sqlite3_exec(db, "ALTER TABLE dictations ADD COLUMN audio_path TEXT", nil, nil, nil)
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
                    (ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms, audio_path)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
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

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("Velora: history insert failed: %@", lastError)
            }
        }
    }

    /// Rewrites a row after a `reprocess` produced a better transcript. Runs
    /// synchronously so the caller can refresh the list right after.
    func updateAfterReprocess(id: Int64, raw: String, final: String, mode: String?) {
        queue.sync { [self] in
            guard db != nil else { return }
            let sql = "UPDATE dictations SET raw = ?, final = ?, mode = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, raw)
            bindText(stmt, 2, final)
            bindText(stmt, 3, mode)
            sqlite3_bind_int64(stmt, 4, id)
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
        let url = AppConfig.audioDirectory.appendingPathComponent(name)
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
        "id, ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms, audio_path"

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
                audioPath: columnText(stmt, 9))
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
