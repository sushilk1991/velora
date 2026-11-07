import CryptoKit
import Darwin
import Foundation

/// The effective backend is separate from the attempted one: a trial can
/// finish through the standard model or retain the original transcript.
enum HistoryTrialBackend: String, Codable {
    case nativeLFM3G = "native_lfm3_g"
    case standard
    case raw
}

/// Text-free diagnostics written by the engine for the personal trial.
/// Session IDs alone are insufficient after History Edit or Reprocess.
struct HistoryTrialRun: Codable, Equatable {
    static let nativeModelIdentity = "ec3710cf3bc12c0fbdfcf24587e5f87a2bf197f4c3129d390052af67e3d1a666"

    let schema: Int
    let sessionID: String
    let rawSHA256: String
    let finalSHA256: String
    let backend: HistoryTrialBackend
    let attemptedBackend: String
    let modelIdentity: String
    let applied: Bool
    let reason: String?
    let cleanupMs: Int
    let cleanupWallMs: Int
    let recordedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case schema, backend, applied, reason
        case sessionID = "session_id"
        case rawSHA256 = "raw_sha256"
        case finalSHA256 = "final_sha256"
        case attemptedBackend = "attempted_backend"
        case modelIdentity = "model_identity"
        case cleanupMs = "cleanup_ms"
        case cleanupWallMs = "cleanup_wall_ms"
        case recordedAt = "recorded_at"
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ record: DictationRecord) -> Bool {
        guard isValid, record.sessionID == sessionID else { return false }
        return matches(record, rawHash: Self.sha256(record.raw), finalHash: Self.sha256(record.final))
    }

    fileprivate func matches(_ record: DictationRecord, rawHash: String, finalHash: String) -> Bool {
        rawSHA256 == rawHash && finalSHA256 == finalHash
            && (record.cleanupMs == nil || record.cleanupMs == cleanupMs)
            && (record.cleanupWallMs == nil || record.cleanupWallMs == cleanupWallMs)
            && (record.cleanupApplied == nil || record.cleanupApplied == applied)
    }

    var backendLabel: String {
        switch backend {
        case .nativeLFM3G: return "Native cleanup"
        case .standard: return "Standard cleanup"
        case .raw: return "Original transcript"
        }
    }

    /// Native's pinned model is named by checkpoint, rather than its artifact
    /// filename or opaque hash. Public Hub identities identify standard models.
    var modelLabel: String? {
        if backend == .nativeLFM3G
            || (backend == .raw && attemptedBackend == HistoryTrialBackend.nativeLFM3G.rawValue) {
            return "LFM3 Native, checkpoint G"
        }
        guard !modelIdentity.isEmpty, modelIdentity.utf8.count <= 300,
              !modelIdentity.hasPrefix("/"), !modelIdentity.contains("\\"),
              !modelIdentity.contains(".."), !modelIdentity.lowercased().hasSuffix(".gguf"),
              modelIdentity.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-._/".unicodeScalars.contains($0)
              }),
              !Self.isSHA256(modelIdentity)
        else { return nil }
        return modelIdentity
    }

    var resultNote: String {
        switch backend {
        case .nativeLFM3G:
            return "This experimental model can miss corrections or omit words. Compare with As heard."
        case .standard:
            return attemptedBackend == HistoryTrialBackend.nativeLFM3G.rawValue
                ? "The standard model handled this trial result."
                : "The standard model handled this result."
        case .raw:
            return "Cleanup was not applied to this result."
        }
    }

    fileprivate var isValid: Bool {
        schema == 1 && !sessionID.isEmpty && sessionID.utf8.count <= 256
            && Self.isSHA256(rawSHA256) && Self.isSHA256(finalSHA256)
            && ["native_lfm3_g", "standard", "bypass"].contains(attemptedBackend)
            && modelIdentity.utf8.count <= 1_024 && (reason?.utf8.count ?? 0) <= 4_096
            && cleanupMs >= 0 && cleanupWallMs >= 0 && recordedAt.isFinite
            && (backend == .raw ? !applied : applied)
            && (backend != .nativeLFM3G && !(backend == .raw && attemptedBackend == "native_lfm3_g")
                || modelIdentity == Self.nativeModelIdentity)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// This is the only trial file containing text. It is written only after an
/// explicit confirmation or correction, and has no training/network consumer.
struct HistoryTrialFeedback: Codable, Equatable {
    let schema: Int
    let sessionID: String
    let recordID: Int64
    let modelIdentity: String
    let backend: HistoryTrialBackend
    let raw: String
    let final: String
    let corrected: String
    let accepted: Bool
    let recordedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case schema, backend, raw, final, corrected, accepted
        case sessionID = "session_id"
        case recordID = "record_id"
        case modelIdentity = "model_identity"
        case recordedAt = "recorded_at"
    }
}

private struct HistoryTrialMetadataHeader: Decodable {
    let schema: Int
    let sessionID: String
    let invalidated: Bool?
    let recordedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case schema, invalidated
        case sessionID = "session_id"
        case recordedAt = "recorded_at"
    }
}

private struct HistoryTrialInvalidation: Encodable {
    let schema = 1
    let sessionID: String
    let invalidated = true
    let recordedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case schema, invalidated
        case sessionID = "session_id"
        case recordedAt = "recorded_at"
    }
}

enum HistoryTrialFeedbackError: LocalizedError, Equatable {
    case recordChanged
    case emptyCorrection
    case unchangedCorrection
    case invalidConfirmation
    case textTooLarge
    case metadataUnavailable
    case feedbackUnavailable
    case feedbackBusy
    case incompleteFeedback

    var errorDescription: String? {
        switch self {
        case .recordChanged:
            return "This transcript no longer matches the trial result. Reopen the dictation to check it."
        case .emptyCorrection:
            return "Enter the result you intended before saving."
        case .unchangedCorrection:
            return "Change the result before saving, or cancel and choose Looks Right."
        case .invalidConfirmation:
            return "The confirmation must use the result shown in History."
        case .textTooLarge:
            return "This transcript is too large to save as trial feedback."
        case .metadataUnavailable:
            return "Couldn’t read local trial details. Try reopening this dictation."
        case .feedbackUnavailable:
            return "Couldn’t save feedback. Check that Velora can write to its local folder, then try again."
        case .feedbackBusy:
            return "Another feedback save is still running. Try again in a moment."
        case .incompleteFeedback:
            return "The local feedback file has an unfinished entry. Feedback could not be saved."
        }
    }
}

/// Small injectable store for selected History details, never a per-row scan.
/// Initialisation and makeFeedback do no I/O; cancelling a sheet does not
/// create a directory or feedback file. Call I/O methods off the main thread.
final class HistoryTrialFeedbackStore {
    static let metadataByteLimit = 8 * 1_024 * 1_024
    static let feedbackTextByteLimit = 1 * 1_024 * 1_024
    private static let metadataLineByteLimit = 16 * 1_024
    static let shared = HistoryTrialFeedbackStore()

    let metadataURL: URL
    let feedbackURL: URL
    private let maxMetadataBytes: Int
    private let lock = NSLock()

    init(metadataURL: URL? = nil, feedbackURL: URL? = nil,
         maxMetadataBytes: Int = HistoryTrialFeedbackStore.metadataByteLimit) {
        let home: URL
        if let path = ProcessInfo.processInfo.environment["VELORA_HOME"], !path.isEmpty {
            home = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            home = AppConfig.veloraDirectory
        }
        self.metadataURL = metadataURL ?? home.appendingPathComponent("native-trial-runs.jsonl")
        self.feedbackURL = feedbackURL ?? home.appendingPathComponent("native-trial-feedback.jsonl")
        self.maxMetadataBytes = min(max(0, maxMetadataBytes), Self.metadataByteLimit)
    }

    /// Reads at most the last 8 MiB. Incomplete tail entries, an initial cut
    /// line, malformed entries and oversized lines are ignored. The latest
    /// session event by timestamp must match. An engine append can arrive after
    /// an edit's invalidation, so file order alone cannot establish provenance.
    func loadMatch(for record: DictationRecord) throws -> HistoryTrialRun? {
        guard let session = record.sessionID, !session.isEmpty,
              record.raw.utf8.count <= Self.feedbackTextByteLimit,
              record.final.utf8.count <= Self.feedbackTextByteLimit,
              maxMetadataBytes > 0
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let fd = Darwin.open(metadataURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw HistoryTrialFeedbackError.metadataUnavailable
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.isRegular(info), info.st_size >= 0 else {
            throw HistoryTrialFeedbackError.metadataUnavailable
        }
        let count = Int(min(info.st_size, off_t(maxMetadataBytes)))
        guard count > 0 else { return nil }
        let start = info.st_size - off_t(count)
        let data = try Self.read(fd: fd, from: start, count: count)
        var end = data.endIndex
        if data.last != 0x0a {
            guard let lastComplete = data.lastIndex(of: 0x0a) else { return nil }
            end = lastComplete + 1
        }
        let rawHash = HistoryTrialRun.sha256(record.raw)
        let finalHash = HistoryTrialRun.sha256(record.final)
        let decoder = JSONDecoder()
        var newestStamp = -Double.infinity
        var newestMatch: HistoryTrialRun?
        // Walk backwards without allocating an array for every line. Even a
        // file of millions of empty lines keeps the same bounded read buffer.
        while end > data.startIndex {
            let lineEnd = end - 1 // Every complete entry ends in a newline.
            let previousNewline = data[..<lineEnd].lastIndex(of: 0x0a)
            let lineStart = previousNewline.map { $0 + 1 } ?? data.startIndex
            end = lineStart
            if start > 0 && previousNewline == nil { break }
            guard lineEnd > lineStart, lineEnd - lineStart <= Self.metadataLineByteLimit else { continue }
            let entry = data.subdata(in: lineStart..<lineEnd)
            guard let header = try? decoder.decode(HistoryTrialMetadataHeader.self, from: entry),
                  header.sessionID == session else { continue }
            guard header.recordedAt.isFinite else { return nil }
            guard header.recordedAt > newestStamp else { continue }
            newestStamp = header.recordedAt
            newestMatch = nil
            if header.schema == 1, header.invalidated != true,
               let run = try? decoder.decode(HistoryTrialRun.self, from: entry), run.isValid,
               run.matches(record, rawHash: rawHash, finalHash: finalHash) {
                newestMatch = run
            }
        }
        return newestMatch
    }

    /// History calls this after a successful reprocess, even if its raw/final
    /// text happens to be identical. The engine uses the same sibling lock
    /// when appending diagnostics. A later complete run can restore provenance.
    func invalidate(sessionID: String, recordedAt: Date = Date()) throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256 else {
            throw HistoryTrialFeedbackError.recordChanged
        }
        let marker = HistoryTrialInvalidation(
            sessionID: sessionID, recordedAt: recordedAt.timeIntervalSince1970)
        var data = try JSONEncoder().encode(marker)
        data.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        try append(data, to: metadataURL, sidecarLock: true)
    }

    /// Pure validation/encoding seam for selftests. Whitespace is only used
    /// to reject empty corrections; the actual Unicode text stays unchanged.
    static func makeFeedback(record: DictationRecord, run: HistoryTrialRun,
                             corrected: String, accepted: Bool,
                             recordedAt: Date = Date()) throws -> HistoryTrialFeedback {
        guard record.raw.utf8.count <= feedbackTextByteLimit,
              record.final.utf8.count <= feedbackTextByteLimit,
              corrected.utf8.count <= feedbackTextByteLimit
        else { throw HistoryTrialFeedbackError.textTooLarge }
        guard run.matches(record) else { throw HistoryTrialFeedbackError.recordChanged }
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoryTrialFeedbackError.emptyCorrection
        }
        if accepted {
            guard corrected == record.final else { throw HistoryTrialFeedbackError.invalidConfirmation }
        } else {
            guard corrected != record.final else { throw HistoryTrialFeedbackError.unchangedCorrection }
        }
        return HistoryTrialFeedback(
            schema: 1, sessionID: run.sessionID, recordID: record.id,
            modelIdentity: run.modelIdentity, backend: run.backend, raw: record.raw,
            final: record.final, corrected: corrected, accepted: accepted,
            recordedAt: recordedAt.timeIntervalSince1970)
    }

    @discardableResult
    func save(record: DictationRecord, run: HistoryTrialRun, corrected: String,
              accepted: Bool, recordedAt: Date = Date()) throws -> HistoryTrialFeedback {
        let feedback = try Self.makeFeedback(
            record: record, run: run, corrected: corrected,
            accepted: accepted, recordedAt: recordedAt)
        guard try loadMatch(for: record) == run else {
            throw HistoryTrialFeedbackError.recordChanged
        }
        var data = try JSONEncoder().encode(feedback)
        data.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        try append(data, to: feedbackURL)
        return feedback
    }

    private func append(_ data: Data, to url: URL, sidecarLock: Bool = false) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw HistoryTrialFeedbackError.feedbackUnavailable
        }
        // A sibling lock is stable across the engine's metadata-file rotation.
        // Feedback is append-only and can use its own descriptor as the lock.
        var sidecarFD: Int32 = -1
        if sidecarLock {
            sidecarFD = Darwin.open(
                url.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                S_IRUSR | S_IWUSR)
            guard sidecarFD >= 0 else { throw HistoryTrialFeedbackError.feedbackUnavailable }
        }
        defer { if sidecarFD >= 0 { Darwin.close(sidecarFD) } }
        if sidecarFD >= 0 {
            try Self.validateWritableFile(sidecarFD)
            try Self.lockFeedback(sidecarFD)
        }
        defer { if sidecarFD >= 0 { _ = flock(sidecarFD, LOCK_UN) } }
        var fd = Darwin.open(
            url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw HistoryTrialFeedbackError.feedbackUnavailable }
        defer { Darwin.close(fd) }
        try Self.validateWritableFile(fd)
        if sidecarFD < 0 { try Self.lockFeedback(fd) }
        defer { if sidecarFD < 0 { _ = flock(fd, LOCK_UN) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else {
            throw HistoryTrialFeedbackError.feedbackUnavailable
        }
        var previousSize = info.st_size
        if previousSize > 0 {
            var lastByte: UInt8 = 0
            guard pread(fd, &lastByte, 1, previousSize - 1) == 1, lastByte == 0x0a else {
                throw HistoryTrialFeedbackError.incompleteFeedback
            }
        }
        if sidecarLock && previousSize + off_t(data.count) > off_t(Self.metadataByteLimit) {
            let previous = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
            guard Darwin.rename(url.path, previous.path) == 0 else {
                throw HistoryTrialFeedbackError.feedbackUnavailable
            }
            Darwin.close(fd)
            fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                             S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw HistoryTrialFeedbackError.feedbackUnavailable }
            try Self.validateWritableFile(fd)
            previousSize = 0
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw HistoryTrialFeedbackError.feedbackUnavailable }
                    written += count
                }
            }
            guard fsync(fd) == 0 else { throw HistoryTrialFeedbackError.feedbackUnavailable }
        } catch {
            // The exclusive file lock spans the whole append and rollback,
            // including partial writes, so an error preserves earlier entries.
            _ = ftruncate(fd, previousSize)
            _ = fsync(fd)
            throw HistoryTrialFeedbackError.feedbackUnavailable
        }
    }

    private static func validateWritableFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, isRegular(info), info.st_nlink == 1,
              info.st_uid == geteuid(), fchmod(fd, S_IRUSR | S_IWUSR) == 0
        else { throw HistoryTrialFeedbackError.feedbackUnavailable }
    }

    private static func lockFeedback(_ fd: Int32) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { throw HistoryTrialFeedbackError.feedbackUnavailable }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw HistoryTrialFeedbackError.feedbackBusy
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func isRegular(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func read(fd: Int32, from offset: off_t, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var loaded = 0
            while loaded < count {
                let amount = pread(fd, base.advanced(by: loaded), count - loaded, offset + off_t(loaded))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw HistoryTrialFeedbackError.metadataUnavailable }
                loaded += amount
            }
        }
        return data
    }
}
