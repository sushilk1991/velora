import Combine
import Foundation
import SwiftUI

struct TranscriptRetentionPolicy: Codable, Equatable {
    var dictationDays = 0
    var meetingDays = 0
    var isValid: Bool { (0...36_500).contains(dictationDays) && (0...36_500).contains(meetingDays) }
    static let preferenceKey = "velora.transcriptRetention.v1"

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: preferenceKey),
              let policy = try? JSONDecoder().decode(Self.self, from: data), policy.isValid else { return Self() }
        return policy
    }
    func save(to defaults: UserDefaults) throws {
        guard isValid else { throw RetentionFailure.changed }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }
}

enum RetentionFailure: LocalizedError {
    case unavailable, busy, changed, writeFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Storage controls are not ready yet."
        case .busy: return "Finish the current dictation, recording, or processing job before applying cleanup."
        case .changed: return "Some records or recordings changed. Preview cleanup again before applying it."
        case .writeFailed: return "Cleanup did not finish. Some records may already be removed. Check storage permissions and preview again to review what is left."
        }
    }
}

struct RetentionAudioStamp: Equatable {
    let bytes: Int64
    let modified: Date
    let inode: UInt64

    static func read(_ url: URL) -> Self? {
        guard let info = try? FileManager.default.attributesOfItem(atPath: url.path),
              info[.type] as? FileAttributeType == .typeRegular,
              let bytes = info[.size] as? NSNumber, let date = info[.modificationDate] as? Date,
              let inode = info[.systemFileNumber] as? NSNumber else { return nil }
        return Self(bytes: bytes.int64Value, modified: date, inode: inode.uint64Value)
    }
}

struct RetentionPreview: Identifiable {
    struct Audio {
        let url: URL
        let stamp: RetentionAudioStamp?
        var unchanged: Bool {
            if let stamp { return RetentionAudioStamp.read(url) == stamp }
            do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return false }
            catch CocoaError.fileNoSuchFile { return true }
            catch CocoaError.fileReadNoSuchFile { return true }
            catch { return false }
        }
    }
    let id = UUID()
    let createdAt: Date
    let policy: TranscriptRetentionPolicy
    let dictationAudioDays: Int
    let meetingAudioDays: Int
    let history: [HistoryRetentionCandidate]
    let meetings: [MeetingRecord]
    let meetingAudio: [MeetingRecord]
    let expiredClips: [Audio]
    let dictationAudio: [Audio]
    let pendingClips: Set<PendingStorageCleanup.Clip>
    let pendingMeetings: Set<String>
    let audio: [Audio]
    var audioBytes: Int64 { audio.reduce(0) { $0 + ($1.stamp?.bytes ?? 0) } }
    var audioCount: Int { audio.filter { $0.stamp != nil }.count }
    var hasRemovals: Bool { !history.isEmpty || !meetings.isEmpty || audioCount > 0 || !pendingMeetings.isEmpty }
}

struct PendingStorageCleanup: Codable {
    struct Clip: Codable, Hashable { let name: String; let deletedRecordID: Int64? }
    var version = 1
    var clips: Set<Clip> = []
    var meetings: Set<String> = []
    static func validClipName(_ name: String) -> Bool {
        name == URL(fileURLWithPath: name).lastPathComponent
            && ["flac", "wav"].contains(URL(fileURLWithPath: name).pathExtension)
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }
    }
}

/// Uses the app's store owners. Opening a second MeetingStore here would run
/// startup recovery against a recording that is still active.
final class StorageRetention {
    static let shared = StorageRetention()
    private let defaults: UserDefaults
    private let archive: URL
    private let removeFile: (URL) throws -> Void
    private var pendingURL: URL { archive.deletingLastPathComponent().appendingPathComponent("cleanup-pending.json") }
    private var history: HistoryStore?
    private var meetings: MeetingStore?
    private var canApply: () -> Bool = { false }
    private var didApplyAudioPolicy: () -> Void = {}
    private var timer: Timer?
    private var protectedClips: [String: String] = [:]
    private var activityObserver: NSObjectProtocol?
    private var engineObserver: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    private var jobsSnapshotCurrent = true
    var policy: TranscriptRetentionPolicy { .load(from: defaults) }
    var isConfigured: Bool { history != nil && meetings != nil }
    var hasProtectedJobs: Bool { !protectedClips.isEmpty }

    init(defaults: UserDefaults = .standard, archive: URL = AppConfig.audioDirectory,
         removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.defaults = defaults
        self.archive = archive
        self.removeFile = removeFile
        activityObserver = NotificationCenter.default.addObserver(forName: .veloraEngineReprocessActivity, object: nil, queue: .main) { [weak self] note in
            guard let self, case .reprocessActivity(let id, let audio, let active)? = note.object as? EngineEvent else { return }
            if active, let audio { self.protectClip(audio, owner: id) }
            else { self.releaseClip(owner: id) }
        }
        snapshotObserver = NotificationCenter.default.addObserver(forName: .veloraEngineReprocessSnapshot, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            guard note.userInfo?["valid"] as? Bool == true, let jobs = note.object as? [ReprocessJobLease] else {
                self.jobsSnapshotCurrent = false; return
            }
            self.protectedClips = Dictionary(jobs.map { ($0.requestID.lowercased(), $0.audio) }, uniquingKeysWith: { _, latest in latest })
            self.jobsSnapshotCurrent = true
        }
    }
    deinit {
        timer?.invalidate()
        if let activityObserver { NotificationCenter.default.removeObserver(activityObserver) }
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        if let snapshotObserver { NotificationCenter.default.removeObserver(snapshotObserver) }
    }

    func configure(history: HistoryStore, meetings: MeetingStore, canApply: @escaping () -> Bool,
                   didApplyAudioPolicy: @escaping () -> Void, startAutomatic: Bool = true,
                   supervisor: EngineSupervisor? = nil) {
        self.history = history
        self.meetings = meetings
        self.canApply = canApply
        self.didApplyAudioPolicy = didApplyAudioPolicy
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        if let supervisor {
            jobsSnapshotCurrent = false
            engineObserver = NotificationCenter.default.addObserver(forName: .veloraEngineStateChanged, object: supervisor, queue: .main) { [weak self, weak supervisor] _ in
                // A reconnect can retain work in the same engine. Only its
                // authoritative ready snapshot may replace the lease set.
                if supervisor?.state != .ready { self?.jobsSnapshotCurrent = false }
            }
        }
        timer?.invalidate()
        guard startAutomatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in self?.applySavedPolicy() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.applySavedPolicy() }
    }

    func protectClip(_ name: String, owner: String) { protectedClips[owner.lowercased()] = name }
    func releaseClip(owner: String) { protectedClips.removeValue(forKey: owner.lowercased()) }

    private func loadPending() throws -> PendingStorageCleanup {
        guard FileManager.default.fileExists(atPath: pendingURL.path) else { return PendingStorageCleanup() }
        let info = try FileManager.default.attributesOfItem(atPath: pendingURL.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              (info[.size] as? NSNumber)?.intValue ?? Int.max <= 8 * 1_024 * 1_024 else { throw RetentionFailure.writeFailed }
        let pending = try JSONDecoder().decode(PendingStorageCleanup.self, from: Data(contentsOf: pendingURL))
        guard pending.version == 1, pending.clips.count <= 100_000, pending.meetings.count <= 100_000,
              pending.clips.allSatisfy({ PendingStorageCleanup.validClipName($0.name) }),
              pending.meetings.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw RetentionFailure.writeFailed }
        return pending
    }

    private func savePending(_ pending: PendingStorageCleanup) throws {
        let data = try JSONEncoder().encode(pending)
        try data.write(to: pendingURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
    }

    private func applySavedPolicy() {
        let policy = self.policy
        guard policy.dictationDays > 0 || policy.meetingDays > 0, canApply(), protectedClips.isEmpty else { return }
        let config = AppConfig.shared
        preview(policy: policy, dictationAudioDays: Int(config.portableEngineSettings.audioRetentionDays),
                meetingAudioDays: config.meetingAudioRetentionDays) { [weak self] result in
            if case .success(let preview) = result { _ = self?.apply(preview, persist: false, automatic: true) }
        }
    }

    func preview(policy: TranscriptRetentionPolicy, dictationAudioDays: Int, meetingAudioDays: Int,
                 now: Date = Date(), completion: @escaping (Result<RetentionPreview, Error>) -> Void) {
        guard let history, let meetings, policy.isValid,
              (1...36_500).contains(dictationAudioDays), (1...365).contains(meetingAudioDays) else {
            completion(.failure(RetentionFailure.unavailable)); return
        }
        let archive = self.archive
        let protected = Set(protectedClips.values)
        DispatchQueue.global(qos: .utility).async {
            let pending: PendingStorageCleanup
            do { pending = try self.loadPending() }
            catch { DispatchQueue.main.async { completion(.failure(error)) }; return }
            let pendingClips = pending.clips.filter { entry in
                !protected.contains(entry.name)
                    && (entry.deletedRecordID == nil
                        ? (RetentionAudioStamp.read(archive.appendingPathComponent(entry.name))?.modified ?? .distantPast) < now.addingTimeInterval(-Double(dictationAudioDays) * 86_400)
                        : (history.record(id: entry.deletedRecordID!) == nil && !history.referencesAudio(named: entry.name)))
            }
            let pendingMeetings = pending.meetings.filter { meetings.retentionOrphanAudioURLs(meetingID: $0) != nil }
            func cutoff(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
            let historyRows = policy.dictationDays == 0 ? [] : history.retentionCandidates(before: cutoff(policy.dictationDays))
            let days = policy.meetingDays > 0 ? min(policy.meetingDays, meetingAudioDays) : meetingAudioDays
            let meetingRows = meetings.retentionMetadata(before: cutoff(days))
            let expiredMeetings = policy.meetingDays == 0 ? [] : meetingRows.filter { $0.endedAt < cutoff(policy.meetingDays) }
            let removedIDs = Set(expiredMeetings.map(\.id))
            let expiredMeetingAudio = meetingRows.filter { !removedIDs.contains($0.id) && $0.endedAt < cutoff(meetingAudioDays)
                && ($0.micPath != nil || $0.systemPath != nil) }
            let children = (try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? []
            var expiredClips = children.compactMap { url -> RetentionPreview.Audio? in
                guard ["flac", "wav"].contains(url.pathExtension), !protected.contains(url.lastPathComponent),
                      let stamp = RetentionAudioStamp.read(url), stamp.modified < cutoff(dictationAudioDays) else { return nil }
                return RetentionPreview.Audio(url: url, stamp: stamp)
            }
            let agedNames = Set(expiredClips.map { $0.url.lastPathComponent })
            expiredClips += pendingClips.filter { !agedNames.contains($0.name) }.map {
                let url = archive.appendingPathComponent($0.name)
                return RetentionPreview.Audio(url: url, stamp: RetentionAudioStamp.read(url))
            }
            var urls = expiredClips.map(\.url)
            urls += historyRows.compactMap { row in
                guard let name = row.audioPath, name == URL(fileURLWithPath: name).lastPathComponent,
                      ["flac", "wav"].contains(URL(fileURLWithPath: name).pathExtension) else { return nil }
                return archive.appendingPathComponent(name)
            }
            let dictationAudio = Set(urls).map { RetentionPreview.Audio(url: $0, stamp: RetentionAudioStamp.read($0)) }
            urls += (expiredMeetings + expiredMeetingAudio).flatMap { row in
                [row.micPath, row.systemPath].compactMap { meetings.retentionAudioURL(relativePath: $0) }
            }
            urls += pendingMeetings.flatMap { meetings.retentionOrphanAudioURLs(meetingID: $0) ?? [] }
            let audio = Set(urls).map { RetentionPreview.Audio(url: $0, stamp: RetentionAudioStamp.read($0)) }
            let preview = RetentionPreview(createdAt: now, policy: policy, dictationAudioDays: dictationAudioDays,
                meetingAudioDays: meetingAudioDays, history: historyRows, meetings: expiredMeetings,
                meetingAudio: expiredMeetingAudio, expiredClips: expiredClips, dictationAudio: dictationAudio,
                pendingClips: Set(pendingClips), pendingMeetings: Set(pendingMeetings), audio: audio)
            DispatchQueue.main.async { completion(.success(preview)) }
        }
    }

    /// The main-thread pass cannot interleave with starting a new app-owned
    /// job. Each store also rechecks snapshots inside its serialized mutation.
    func apply(_ preview: RetentionPreview, persist: Bool = true, automatic: Bool = false) -> Result<String, Error> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let history, let meetings else { return .failure(RetentionFailure.unavailable) }
        guard jobsSnapshotCurrent else { return .failure(RetentionFailure.unavailable) }
        guard canApply(), protectedClips.isEmpty else { return .failure(RetentionFailure.busy) }
        if automatic {
            let config = AppConfig.shared
            guard policy == preview.policy,
                  Int(config.portableEngineSettings.audioRetentionDays) == preview.dictationAudioDays,
                  config.meetingAudioRetentionDays == preview.meetingAudioDays else { return .failure(RetentionFailure.changed) }
        }
        guard Date().timeIntervalSince(preview.createdAt) < 600, preview.audio.allSatisfy(\.unchanged),
              history.retentionMatches(preview.history),
              preview.pendingClips.allSatisfy({ $0.deletedRecordID == nil
                  || (history.record(id: $0.deletedRecordID!) == nil && !history.referencesAudio(named: $0.name)) }),
              preview.pendingMeetings.allSatisfy({ meetings.retentionOrphanAudioURLs(meetingID: $0) != nil }),
              (preview.meetings + preview.meetingAudio).allSatisfy({ meetings.recordMetadata(id: $0.id) == $0
                  && !meetings.isReprocessing(meetingID: $0.id) }) else { return .failure(RetentionFailure.changed) }
        var previousSettings: SettingsDocument.PortableSettings?
        var pending: PendingStorageCleanup?
        do {
            var targets = try loadPending()
            targets.clips.formUnion(preview.history.compactMap { row in
                guard let name = row.audioPath, PendingStorageCleanup.validClipName(name) else { return nil }
                return PendingStorageCleanup.Clip(name: name, deletedRecordID: row.id)
            })
            targets.clips.formUnion(preview.expiredClips.map { PendingStorageCleanup.Clip(name: $0.url.lastPathComponent, deletedRecordID: nil) })
            targets.meetings.formUnion(preview.meetings.map(\.id))
            try savePending(targets)
            pending = targets
            if persist {
                var document = try SettingsDocumentCodec.decode(AppConfig.shared.exportSettingsData())
                previousSettings = document.settings
                document.settings.engine.audioRetentionDays = Double(preview.dictationAudioDays)
                document.settings.meetings.audioRetentionDays = preview.meetingAudioDays
                try AppConfig.shared.applyPortableSettings(document.settings)
            }
            guard history.deleteForRetention(preview.history) != nil else { throw RetentionFailure.changed }
            for row in preview.meetings {
                guard meetings.deleteForRetention(expected: row) else {
                    throw meetings.recordMetadata(id: row.id) == nil ? RetentionFailure.writeFailed : RetentionFailure.changed
                }
                pending?.meetings.remove(row.id)
            }
            for row in preview.meetingAudio { guard meetings.expireAudio(expected: row) else { throw RetentionFailure.writeFailed } }
            for clip in preview.expiredClips where FileManager.default.fileExists(atPath: clip.url.path) {
                guard clip.unchanged else { throw RetentionFailure.changed }
                try removeFile(clip.url)
            }
            // Store callbacks historically treated unlink as best effort. A
            // retention confirmation must account for every previewed recording.
            for item in preview.dictationAudio where FileManager.default.fileExists(atPath: item.url.path) {
                guard item.stamp != nil, item.unchanged else { throw RetentionFailure.changed }
                try removeFile(item.url)
            }
            for id in preview.pendingMeetings {
                guard meetings.removeRetentionOrphan(meetingID: id) else { throw RetentionFailure.writeFailed }
                pending?.meetings.remove(id)
            }
            if var remaining = pending {
                remaining.clips = remaining.clips.filter { entry in
                    FileManager.default.fileExists(atPath: archive.appendingPathComponent(entry.name).path)
                        && (entry.deletedRecordID == nil || history.record(id: entry.deletedRecordID!) == nil)
                }
                remaining.meetings = remaining.meetings.filter { meetings.recordMetadata(id: $0) == nil }
                try savePending(remaining)
                pending = remaining
            }
            if persist { try preview.policy.save(to: defaults); didApplyAudioPolicy() }
            NotificationCenter.default.post(name: .veloraHistoryChanged, object: nil)
            return .success("Removed \(preview.history.count) dictations and \(preview.meetings.count) meetings. Audio cleanup is complete.")
        } catch {
            if let pending { try? savePending(pending) }
            if let previousSettings { try? AppConfig.shared.applyPortableSettings(previousSettings) }
            return .failure(error)
        }
    }
}

struct RetentionSettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var policy = TranscriptRetentionPolicy()
    @State private var dictationAudioDays = 180
    @State private var meetingAudioDays = 30
    @State private var preview: RetentionPreview?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        DisclosureGroup("Storage and retention") {
            daysPicker("Keep dictation text", value: $policy.dictationDays, forever: true, choices: [7, 30, 90, 180, 365])
            daysPicker("Keep dictation audio", value: $dictationAudioDays, forever: false, choices: [7, 30, 90, 180, 365])
            daysPicker("Keep meetings and notes", value: $policy.meetingDays, forever: true, choices: [30, 90, 180, 365])
            daysPicker("Keep meeting audio", value: $meetingAudioDays, forever: false, choices: [7, 30, 90, 365])
            Text("Text stays forever unless you choose a limit. Removing a meeting also removes its notes, passages, and recording. Audio can expire while text stays.")
                .font(.caption).foregroundStyle(.secondary)
            Button(busy ? "Preparing preview…" : "Preview cleanup…") {
                busy = true
                StorageRetention.shared.preview(policy: policy, dictationAudioDays: dictationAudioDays,
                    meetingAudioDays: meetingAudioDays) { result in
                    busy = false
                    switch result {
                    case .success(let value): preview = value
                    case .failure(let error): message = error.localizedDescription
                    }
                }
            }.disabled(busy)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .onAppear {
            policy = StorageRetention.shared.policy
            dictationAudioDays = Int(model.audioRetentionDays)
            meetingAudioDays = model.meetingAudioRetentionDays
        }
        .sheet(item: $preview) { value in
            VStack(alignment: .leading, spacing: 16) {
                Text("Review storage cleanup").font(.title2)
                Text("\(value.history.count) dictations and \(value.meetings.count) meetings will be removed.")
                Text("\(value.audioCount) recordings · \(ByteCountFormatter.string(fromByteCount: value.audioBytes, countStyle: .file))")
                Text("Meeting notes and source links follow deleted meetings. Existing recordings being processed are kept. Future cleanup follows the limits you save.")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { preview = nil }.keyboardShortcut(.cancelAction)
                    Button(value.hasRemovals ? "Apply and remove" : "Save policy", role: value.hasRemovals ? .destructive : nil) {
                        switch StorageRetention.shared.apply(value) {
                        case .success(let text):
                            model.audioRetentionDays = Double(value.dictationAudioDays)
                            model.meetingAudioRetentionDays = value.meetingAudioDays
                            message = text
                        case .failure(let error): message = error.localizedDescription
                        }
                        preview = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 470)
        }
    }

    private func daysPicker(_ title: String, value: Binding<Int>, forever: Bool, choices: [Int]) -> some View {
        Picker(title, selection: value) {
            if forever { Text("Forever").tag(0) }
            ForEach(choices, id: \.self) { days in Text("\(days) days").tag(days) }
            if value.wrappedValue > 0 && !choices.contains(value.wrappedValue) { Text("\(value.wrappedValue) days").tag(value.wrappedValue) }
        }
    }
}
