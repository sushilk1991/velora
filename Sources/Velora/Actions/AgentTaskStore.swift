import Foundation
import SQLite3

enum AgentTaskStatus: String, Equatable {
    case running
    case planned
    case needsApproval = "needs_approval"
    case completed
    case ready
    case unverified
    case failed
    case cancelled
    case interrupted
}

struct AgentTaskRecord: Equatable {
    let id: String
    let createdAt: Date
    let updatedAt: Date
    let status: AgentTaskStatus
    let command: String
    let goal: String
    let execute: Bool
    let allowSend: Bool
    let frontmostBundle: String
    let lastError: String
}

struct AgentTaskEventRecord: Equatable {
    let id: Int64
    let taskID: String
    let timestamp: Date
    let kind: String
    let turn: Int?
    let durationMs: Int?
    let payload: String
}

enum AgentTaskStoreError: Error, Equatable {
    case unavailable
}

/// Private, bounded execution ledger for Agent Mode.
///
/// This is deliberately not an in-memory conversation transcript. The live
/// agent keeps only the current goal/observation in RAM; durable truth is
/// appended here as compact receipts and reloaded only when a future resume or
/// history surface asks for it. No screenshots or AX trees are stored.
final class AgentTaskStore {
    static let defaultRetentionDays = 14
    static let defaultMaximumTasks = 200
    static let maximumEventsPerTask = 64
    static let maximumPayloadCharacters = 4_096

    private let databaseURL: URL
    private let retentionDays: Int
    private let maximumTasks: Int
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.velora.agent-ledger")
    private let queueKey = DispatchSpecificKey<UInt8>()

    /// SQLITE_TRANSIENT: SQLite owns a copy after each bind returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(
        url: URL = AppConfig.agentDatabaseURL,
        retentionDays: Int = defaultRetentionDays,
        maximumTasks: Int = defaultMaximumTasks
    ) {
        databaseURL = url
        self.retentionDays = max(1, retentionDays)
        self.maximumTasks = max(1, maximumTasks)
        queue.setSpecific(key: queueKey, value: 1)

        if url == AppConfig.agentDatabaseURL {
            AppConfig.shared.ensureVeloraDirectory()
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) == SQLITE_OK {
            db = handle
            sqlite3_busy_timeout(handle, 2_000)
            sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA auto_vacuum=INCREMENTAL;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA wal_autocheckpoint=64;", nil, nil, nil)
            // This ledger is append-light and bounded; a large SQLite page
            // cache or file mapping would buy nothing while Velora is resident.
            sqlite3_exec(handle, "PRAGMA cache_size=-256;", nil, nil, nil)
            sqlite3_exec(handle, "PRAGMA mmap_size=0;", nil, nil, nil)
            createSchema()
            recoverInterruptedTasks()
            pruneOnQueue()
            protectDatabaseFiles()
        } else {
            if handle != nil { sqlite3_close(handle) }
            NSLog("Velora: failed to open agent ledger at %@", url.path)
        }
    }

    deinit {
        let close = { [self] in
            if db != nil { sqlite3_close(db) }
            db = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { close() }
        else { queue.sync(execute: close) }
    }

    @discardableResult
    func begin(
        command: String,
        context: ActionContextSnapshot,
        execute: Bool,
        allowSend: Bool
    ) -> Result<String, AgentTaskStoreError> {
        let id = UUID().uuidString
        let now = Date().timeIntervalSince1970
        return queue.sync { [self] in
            guard db != nil,
                  sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
            else { return .failure(.unavailable) }
            var transactionOpen = true
            defer {
                if transactionOpen {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                }
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT INTO agent_tasks
                    (id, created_at, updated_at, status, command, goal,
                     execute_requested, allow_send, frontmost_bundle, last_error)
                VALUES (?, ?, ?, 'running', ?, '', ?, ?, ?, '');
                """, -1, &stmt, nil) == SQLITE_OK else {
                logFailure("begin prepare")
                return .failure(.unavailable)
            }
            bindText(stmt, 1, id)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_double(stmt, 3, now)
            bindText(stmt, 4, Self.bounded(command, 1_200))
            sqlite3_bind_int(stmt, 5, execute ? 1 : 0)
            sqlite3_bind_int(stmt, 6, allowSend ? 1 : 0)
            bindText(stmt, 7, Self.bounded(context.frontmostBundle, 256))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                logFailure("begin")
                return .failure(.unavailable)
            }
            sqlite3_finalize(stmt)
            guard insertEventOnQueue(
                taskID: id,
                kind: "started",
                payload: [
                    "frontmost_app": Self.bounded(context.frontmostApp, 80),
                    "frontmost_window": Self.bounded(context.frontmostWindow, 160),
                ]) else { return .failure(.unavailable) }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                logFailure("begin commit")
                return .failure(.unavailable)
            }
            transactionOpen = false
            pruneOnQueue()
            protectDatabaseFiles()
            return .success(id)
        }
    }

    func recordTurn(
        taskID: String,
        turn: Int,
        sends: Bool,
        goal: String,
        stepCount: Int,
        durationMs: Int
    ) {
        queue.async { [self] in
            guard db != nil else { return }
            let boundedGoal = Self.bounded(goal, 200)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(
                db,
                "UPDATE agent_tasks SET updated_at = ?, goal = ? WHERE id = ?;",
                -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
                bindText(stmt, 2, boundedGoal)
                bindText(stmt, 3, taskID)
                if sqlite3_step(stmt) != SQLITE_DONE { logFailure("turn update") }
            }
            sqlite3_finalize(stmt)
            insertEventOnQueue(
                taskID: taskID,
                kind: "planner_turn",
                turn: turn,
                durationMs: max(0, durationMs),
                payload: [
                    "sends": sends,
                    "step_count": max(0, stepCount),
                    "goal": boundedGoal,
                ])
        }
    }

    func recordCancelRequested(taskID: String) {
        queue.async { [self] in
            insertEventOnQueue(taskID: taskID, kind: "cancel_requested")
        }
    }

    func finish(
        taskID: String,
        result: ActionResult,
        durationMs: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        let outcome: (status: AgentTaskStatus, goal: String, error: String, trace: [String])
        switch result {
        case .planned(let plan):
            outcome = (.planned, plan.goal, "", plan.describedSteps)
        case .needsSendApproval(let plan):
            outcome = (.needsApproval, plan.goal, "", plan.describedSteps)
        case .completed(let goal, let trace, _):
            outcome = (.completed, goal, "", trace)
        case .ready(let goal, let trace, _):
            outcome = (.ready, goal, "", trace)
        case .performedUnverified(let goal, let trace, _):
            outcome = (.unverified, goal, "", trace)
        case .failed(let reason, let trace):
            outcome = (.failed, "", reason, trace)
        case .cancelled:
            outcome = (.cancelled, "", "", [])
        }

        queue.async { [self] in
            let committed = finishOnQueue(
                taskID: taskID,
                outcome: outcome,
                durationMs: durationMs)
            if let completion {
                DispatchQueue.main.async { completion(committed) }
            }
        }
    }

    private func finishOnQueue(
        taskID: String,
        outcome: (status: AgentTaskStatus, goal: String, error: String, trace: [String]),
        durationMs: Int
    ) -> Bool {
        guard db != nil,
              sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
        else { return false }
        var transactionOpen = true
        defer {
            if transactionOpen {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            UPDATE agent_tasks
            SET updated_at = ?, status = ?,
                goal = CASE WHEN ? = '' THEN goal ELSE ? END,
                last_error = ?
            WHERE id = ?;
            """, -1, &stmt, nil) == SQLITE_OK else {
            logFailure("finish prepare")
            return false
        }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        bindText(stmt, 2, outcome.status.rawValue)
        let goal = Self.bounded(outcome.goal, 200)
        bindText(stmt, 3, goal)
        bindText(stmt, 4, goal)
        bindText(stmt, 5, Self.bounded(outcome.error, 500))
        bindText(stmt, 6, taskID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_finalize(stmt)
            logFailure("finish")
            return false
        }
        sqlite3_finalize(stmt)
        guard sqlite3_changes(db) == 1 else {
            logFailure("finish missing task")
            return false
        }

        guard insertEventOnQueue(
            taskID: taskID,
            kind: "finished",
            durationMs: max(0, durationMs),
            payload: [
                "status": outcome.status.rawValue,
                "error": Self.bounded(outcome.error, 500),
            ]) else { return false }
        for line in outcome.trace.suffix(ActionPlan.Limits.maxSteps) {
            guard insertEventOnQueue(
                taskID: taskID,
                kind: "receipt",
                payload: ["line": Self.bounded(line, 500)]) else { return false }
        }
        trimEventsOnQueue(taskID: taskID)
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            logFailure("finish commit")
            return false
        }
        transactionOpen = false
        pruneOnQueue()
        protectDatabaseFiles()
        return true
    }

    /// Test/debug read. Production execution does not retain this array.
    func recent(limit: Int = 20) -> [AgentTaskRecord] {
        queue.sync { [self] in
            guard db != nil else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT id, created_at, updated_at, status, command, goal,
                       execute_requested, allow_send, frontmost_bundle, last_error
                FROM agent_tasks ORDER BY created_at DESC LIMIT ?;
                """, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
            var rows: [AgentTaskRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = columnText(stmt, 0),
                      let statusText = columnText(stmt, 3),
                      let status = AgentTaskStatus(rawValue: statusText) else { continue }
                rows.append(AgentTaskRecord(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    status: status,
                    command: columnText(stmt, 4) ?? "",
                    goal: columnText(stmt, 5) ?? "",
                    execute: sqlite3_column_int(stmt, 6) != 0,
                    allowSend: sqlite3_column_int(stmt, 7) != 0,
                    frontmostBundle: columnText(stmt, 8) ?? "",
                    lastError: columnText(stmt, 9) ?? ""))
            }
            return rows
        }
    }

    /// Test/debug read. Payloads are already bounded before insertion.
    func events(taskID: String) -> [AgentTaskEventRecord] {
        queue.sync { [self] in
            guard db != nil else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                SELECT id, task_id, ts, kind, turn, duration_ms, payload
                FROM agent_events WHERE task_id = ? ORDER BY id;
                """, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, taskID)
            var rows: [AgentTaskEventRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(AgentTaskEventRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    taskID: columnText(stmt, 1) ?? "",
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    kind: columnText(stmt, 3) ?? "",
                    turn: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(stmt, 4)),
                    durationMs: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(stmt, 5)),
                    payload: columnText(stmt, 6) ?? "{}"))
            }
            return rows
        }
    }

    /// Waits for prior asynchronous writes; used only by deterministic tests.
    func flush() { queue.sync {} }

    private func createSchema() {
        let sql = """
            CREATE TABLE IF NOT EXISTS agent_tasks (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                status TEXT NOT NULL,
                command TEXT NOT NULL,
                goal TEXT NOT NULL DEFAULT '',
                execute_requested INTEGER NOT NULL,
                allow_send INTEGER NOT NULL,
                frontmost_bundle TEXT NOT NULL DEFAULT '',
                last_error TEXT NOT NULL DEFAULT ''
            );
            CREATE INDEX IF NOT EXISTS idx_agent_tasks_created
                ON agent_tasks(created_at DESC);
            CREATE TABLE IF NOT EXISTS agent_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                turn INTEGER,
                duration_ms INTEGER,
                payload TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS idx_agent_events_task
                ON agent_events(task_id, id);
            """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            logFailure("schema")
        }
    }

    private func recoverInterruptedTasks() {
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            UPDATE agent_tasks
            SET status = 'interrupted', updated_at = ?,
                last_error = 'Velora stopped before the task completed'
            WHERE status = 'running';
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        if sqlite3_step(stmt) != SQLITE_DONE { logFailure("recovery") }
    }

    @discardableResult
    private func insertEventOnQueue(
        taskID: String,
        kind: String,
        turn: Int? = nil,
        durationMs: Int? = nil,
        payload: [String: Any] = [:]
    ) -> Bool {
        guard db != nil else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO agent_events (task_id, ts, kind, turn, duration_ms, payload)
            VALUES (?, ?, ?, ?, ?, ?);
            """, -1, &stmt, nil) == SQLITE_OK else {
            logFailure("event prepare")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, taskID)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        bindText(stmt, 3, Self.bounded(kind, 64))
        if let turn { sqlite3_bind_int64(stmt, 4, Int64(turn)) }
        else { sqlite3_bind_null(stmt, 4) }
        if let durationMs { sqlite3_bind_int64(stmt, 5, Int64(durationMs)) }
        else { sqlite3_bind_null(stmt, 5) }
        bindText(stmt, 6, Self.payloadJSON(payload))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            logFailure("event")
            return false
        }
        trimEventsOnQueue(taskID: taskID)
        return true
    }

    private func trimEventsOnQueue(taskID: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            DELETE FROM agent_events
            WHERE task_id = ? AND id NOT IN (
                SELECT id FROM agent_events WHERE task_id = ?
                ORDER BY id DESC LIMIT ?
            );
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, taskID)
        bindText(stmt, 2, taskID)
        sqlite3_bind_int(stmt, 3, Int32(Self.maximumEventsPerTask))
        sqlite3_step(stmt)
    }

    private func pruneOnQueue() {
        guard db != nil else { return }
        let cutoff = Date().timeIntervalSince1970 - Double(retentionDays) * 86_400
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "DELETE FROM agent_tasks WHERE created_at < ?;", -1, &stmt, nil
        ) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        stmt = nil
        if sqlite3_prepare_v2(db, """
            DELETE FROM agent_tasks WHERE id IN (
                SELECT id FROM agent_tasks ORDER BY created_at DESC
                LIMIT -1 OFFSET ?
            );
            """, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(maximumTasks))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        // Deleted pages stay reusable inside this small, capped database. Do
        // not vacuum here: pruning may run inside a task-finalization
        // transaction, and reclaiming file space is not worth extending that
        // write lock.
    }

    private func protectDatabaseFiles() {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func logFailure(_ operation: String) {
        NSLog("Velora: agent ledger %@ failed: %@", operation, lastError)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private static func bounded(_ value: String, _ limit: Int) -> String {
        let collapsed = value.replacingOccurrences(of: "\0", with: "")
        return String(collapsed.prefix(max(0, limit)))
    }

    private static func payloadJSON(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        guard text.count <= maximumPayloadCharacters else {
            // Never persist a chopped JSON document. Inputs are bounded before
            // serialization, so this is a fail-closed guard against a future
            // caller accidentally treating the ledger as blob storage.
            return #"{"truncated":true}"#
        }
        return text
    }
}
