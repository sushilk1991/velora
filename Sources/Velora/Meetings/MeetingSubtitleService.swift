import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A sheet owns its preview; the engine owns the lifetime of the audio lease.
/// Closing/cancelling the sheet never releases an executor-backed storage job.
final class MeetingSubtitleService: ObservableObject {
    @Published var format: MeetingExportFormat = .srt
    @Published private(set) var working = false
    @Published private(set) var fraction: Double = 0
    @Published private(set) var result: MeetingSubtitleResult?
    @Published private(set) var message: String?
    @Published private(set) var cancelling = false
    @Published private(set) var exporting = false
    private let record: MeetingRecord
    private let store: MeetingStore
    private let isReady: () -> Bool
    private let send: ([String: Any]) -> Void
    private var requestID: String?
    private var observer: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var generation = 0

    init(record: MeetingRecord, store: MeetingStore,
         isReady: @escaping () -> Bool, send: @escaping ([String: Any]) -> Void) {
        self.record = record; self.store = store; self.isReady = isReady; self.send = send
        observer = NotificationCenter.default.addObserver(forName: .veloraEngineMeetingSubtitles, object: nil, queue: .main) { [weak self] note in
            if let event = note.object as? EngineEvent { self?.receive(event) }
        }
        snapshotObserver = NotificationCenter.default.addObserver(forName: .veloraEngineReprocessSnapshot, object: nil, queue: .main) { [weak self] note in
            guard let self, self.working, let id = self.requestID,
                  note.userInfo?["valid"] as? Bool == true,
                  let jobs = note.object as? [ReprocessJobLease],
                  !jobs.contains(where: { $0.requestID.lowercased() == id.lowercased() }) else { return }
            self.working = false; self.cancelling = false
            self.message = L10n.text("Subtitle generation stopped when the engine reconnected. Generate again.")
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let snapshotObserver { NotificationCenter.default.removeObserver(snapshotObserver) }
    }

    private var paths: [String] { [record.micPath, record.systemPath].compactMap { $0 } }

    private func currentSources() -> [URL]? {
        guard let latest = store.record(id: record.id), latest.status != .recording,
              latest.transcriptRevision == record.transcriptRevision,
              latest.micPath == record.micPath, latest.systemPath == record.systemPath,
              latest.isImported == record.isImported,
              !store.isReprocessing(meetingID: record.id), !paths.isEmpty,
              paths.allSatisfy({ store.hasUsableAudio(relativePath: $0) }) else { return nil }
        let urls = paths.compactMap { path -> URL? in
            guard let guarded = store.retentionAudioURL(relativePath: path),
                  let readable = store.audioURL(relativePath: path),
                  guarded.standardizedFileURL == readable.standardizedFileURL else { return nil }
            return guarded
        }
        return urls.count == paths.count ? urls : nil
    }

    func generate() {
        guard !working, !exporting else { return }
        guard isReady() else { message = L10n.text("The speech engine is not ready. Try again shortly."); return }
        guard let sources = currentSources() else { sourceChanged(); return }
        generation += 1
        let id = UUID().uuidString
        requestID = id; result = nil; message = nil; fraction = 0; cancelling = false; working = true
        StorageRetention.shared.protectClip("meeting:" + record.id, owner: id)
        let tracks = sources.map { source -> [String: Any] in
            let speaker = source.lastPathComponent == "me.caf" ? "me" : (record.isImported ? "recording" : "them")
            return ["path": source.path, "speaker": speaker]
        }
        send(["cmd": "meeting_subtitles", "id": id, "meeting_id": record.id,
              "revision": record.transcriptRevision, "tracks": tracks])
    }

    func cancel() {
        guard let requestID, working else { return }
        cancelling = true
        send(["cmd": "meeting_subtitles_cancel", "id": requestID])
    }

    func disappear() {
        generation += 1
        cancel()
    }

    func receive(_ event: EngineEvent) {
        guard let requestID else { return }
        switch event {
        case .meetingSubtitlesProgress(let id, let meetingID, let value) where id == requestID && meetingID == record.id:
            fraction = value
        case .meetingSubtitlesReady(let id, let preview) where id == requestID:
            working = false
            guard !cancelling else { cancelling = false; return }
            guard preview.meetingID == record.id, preview.revision == record.transcriptRevision,
                  let sources = currentSources(), Set(sources.map(\.path)) == Set(preview.fingerprints.keys)
            else { sourceChanged(); return }
            result = preview
            if preview.cues.isEmpty { message = L10n.text("No reliable speech was found in the retained audio.") }
        case .meetingSubtitlesFailed(let id, _, let error, let code) where id == requestID:
            working = false; cancelling = false
            message = code == "cancelled" ? L10n.text("Subtitle generation cancelled.") : error
        default: break
        }
    }

    private func sourceChanged() {
        result = nil
        message = L10n.text("The meeting or its audio changed. Reopen this meeting to generate subtitles.")
    }

    /// Recheck source SHA256 after the save panel, off the main thread. The
    /// app owns the destination grant; the engine never receives that path.
    func export(format: MeetingExportFormat) {
        guard !working, !exporting, let preview = result, !preview.cues.isEmpty,
              let sources = currentSources() else { sourceChanged(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + "-subtitles." + format.fileExtension
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let destination = panel.url,
                  let latestSources = self.currentSources(), latestSources == sources else { return }
            self.exporting = true
            let expected = self.generation
            DispatchQueue.global(qos: .utility).async {
                let valid = sources.allSatisfy { source in
                    guard let fingerprint = preview.fingerprints[source.path], let digest = fingerprint.split(separator: ":").first,
                          let observed = Self.digest(source) else { return false }
                    return observed == digest
                }
                DispatchQueue.main.async {
                    self.exporting = false
                    guard expected == self.generation else { return }
                    guard valid, self.currentSources() == sources else { self.sourceChanged(); return }
                    do {
                        let data = preview.export(format: format, speakerName: { speaker in
                            switch speaker {
                            case .me: return L10n.text("Me")
                            case .them: return L10n.text("Them")
                            default: return L10n.text("Recording")
                            }
                        })
                        try data.write(to: destination, atomically: true, encoding: .utf8)
                        self.message = L10n.text("Subtitles exported.")
                    } catch { self.message = error.localizedDescription }
                }
            }
        }
    }

    private static func digest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let before = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        var digest = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
        } catch { return nil }
        let after = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard let before, let after, before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate,
              String(describing: before.fileResourceIdentifier) == String(describing: after.fileResourceIdentifier)
        else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
