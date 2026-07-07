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
                    (ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
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

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("Velora: history insert failed: %@", lastError)
            }
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

    /// Most recent dictations, newest first. Synchronous — called on menu
    /// open with tiny result sets.
    func recent(limit: Int = 3) -> [DictationRecord] {
        queue.sync { [self] in
            guard db != nil else { return [] }
            let sql = """
                SELECT id, ts, bundle_id, app_name, raw, final, mode, duration_ms, cleanup_ms
                FROM dictations ORDER BY ts DESC LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

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
                        ? nil : Int(sqlite3_column_int64(stmt, 8)))
                record.id = sqlite3_column_int64(stmt, 0)
                records.append(record)
            }
            return records
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
}
