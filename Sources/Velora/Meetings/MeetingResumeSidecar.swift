import Foundation

/// Crash-resume checkpoint for one in-progress meeting capture, stored as
/// `<meeting-dir>/resume.json` next to the CAF tracks.
///
/// CAF keeps already-flushed PCM readable after a hard crash, but nothing
/// recorded *how much* audio was durable, which take segments exist, or what
/// the meeting was called. The sidecar is rewritten (atomically, `0600`)
/// about every ten seconds during capture and removed on a normal stop, so
/// its mere presence on launch marks a crash-interrupted recording whose
/// duration can be repaired from frame counts instead of wall-clock guesses.
struct MeetingResumeSidecar: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let fileName = "resume.json"

    var schemaVersion: Int = currentSchemaVersion
    var meetingID: String
    var title: String
    var startedAt: Date
    var updatedAt: Date
    /// Track file names inside the meeting directory ("me.caf" / "them.caf").
    var micTrack: String?
    var systemTrack: String?
    var micDurationS: Double = 0
    var systemDurationS: Double = 0
    var micFrames: Int64 = 0
    var systemFrames: Int64 = 0
    /// Number of capture takes merged into these totals (1 + restarts/resumes).
    var segmentCount: Int = 1
    var endReason: MeetingEndReason?

    /// Best durable duration: the longer track wins; a sidecar checkpointed
    /// before any frames were counted falls back to elapsed wall time.
    var repairedTotalDurationS: Double {
        let tracks = max(0, max(micDurationS, systemDurationS))
        if tracks > 0 { return tracks }
        return max(0, updatedAt.timeIntervalSince(startedAt))
    }

    /// The end instant implied by repaired duration, for fixing a recovered
    /// row whose `ended_at` was never written.
    var repairedEndedAt: Date {
        startedAt.addingTimeInterval(repairedTotalDurationS)
    }

    /// Clamps corrupt values (negative durations/frames, an `updatedAt`
    /// before `startedAt`, a zero segment count) without inventing audio.
    func repaired() -> MeetingResumeSidecar {
        var copy = self
        copy.schemaVersion = max(1, schemaVersion)
        copy.micDurationS = max(0, micDurationS)
        copy.systemDurationS = max(0, systemDurationS)
        copy.micFrames = max(0, micFrames)
        copy.systemFrames = max(0, systemFrames)
        copy.segmentCount = max(1, segmentCount)
        if copy.updatedAt < copy.startedAt { copy.updatedAt = copy.startedAt }
        return copy
    }

    /// Merges a later take (a resumed/restarted capture's totals) into this
    /// sidecar as one more segment. Durations and frames add; identity,
    /// title and the original start stay with the first take.
    func appendingTakeSegment(_ take: MeetingResumeSidecar) -> MeetingResumeSidecar {
        var merged = repaired()
        let take = take.repaired()
        merged.micDurationS += take.micDurationS
        merged.systemDurationS += take.systemDurationS
        merged.micFrames += take.micFrames
        merged.systemFrames += take.systemFrames
        merged.segmentCount += max(1, take.segmentCount)
        merged.updatedAt = max(merged.updatedAt, take.updatedAt)
        if merged.micTrack == nil { merged.micTrack = take.micTrack }
        if merged.systemTrack == nil { merged.systemTrack = take.systemTrack }
        if let reason = take.endReason { merged.endReason = reason }
        return merged
    }

    /// Idempotent launch reconciliation. Recovering twice must not merge the
    /// same crashed take twice: a `recovered` snapshot whose frame totals are
    /// already covered by `existing` (same meeting, same start, no more
    /// frames on either track) is a duplicate and changes nothing. A take
    /// with genuinely more frames is appended exactly once — after that its
    /// totals are covered, so a second reconcile is a no-op.
    static func reconcileResume(
        existing: MeetingResumeSidecar?,
        recovered: MeetingResumeSidecar
    ) -> MeetingResumeSidecar {
        guard let existing else { return recovered.repaired() }
        let kept = existing.repaired()
        let take = recovered.repaired()
        guard take.meetingID == kept.meetingID,
              take.startedAt == kept.startedAt else {
            // A different capture entirely: never merge across meetings.
            return kept
        }
        if take.micFrames <= kept.micFrames
            && take.systemFrames <= kept.systemFrames {
            return kept
        }
        return kept.appendingTakeSegment(take)
    }
}

/// Atomic `0600` file store for `MeetingResumeSidecar`.
enum MeetingResumeSidecarStore {
    static func url(in meetingDirectory: URL) -> URL {
        meetingDirectory.appendingPathComponent(MeetingResumeSidecar.fileName)
    }

    /// Writes via a same-directory temp file + rename, so a crash mid-write
    /// leaves either the old checkpoint or the new one, never a torn file.
    /// The temp file is `0600` before the rename, so the visible file is
    /// owner-only from its first instant.
    static func write(
        _ sidecar: MeetingResumeSidecar, to meetingDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: meetingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(sidecar.repaired())
        let target = url(in: meetingDirectory)
        let temp = meetingDirectory.appendingPathComponent(
            ".\(MeetingResumeSidecar.fileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temp, options: [.withoutOverwriting])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: target)
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    static func read(
        from meetingDirectory: URL, fileManager: FileManager = .default
    ) -> MeetingResumeSidecar? {
        guard let data = try? Data(contentsOf: url(in: meetingDirectory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MeetingResumeSidecar.self, from: data))?.repaired()
    }

    /// Normal finish / discard: the recording is accounted for, so the
    /// crash marker goes away. Missing is fine.
    static func remove(from meetingDirectory: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url(in: meetingDirectory))
    }

    /// Every decodable sidecar in an immediate subdirectory of the meetings
    /// root — the crash-interrupted recordings a launch should reconcile.
    /// Corrupt or partial files are skipped, never fatal.
    static func pendingSidecars(
        in meetingsDirectory: URL, fileManager: FileManager = .default
    ) -> [MeetingResumeSidecar] {
        let children = (try? fileManager.contentsOfDirectory(
            at: meetingsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { read(from: $0, fileManager: fileManager) }
            .sorted { $0.startedAt < $1.startedAt }
    }
}
