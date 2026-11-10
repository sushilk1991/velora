import Combine
import Foundation
import SwiftUI

struct MeetingLivePassage: Codable, Equatable, Identifiable {
    let key: String
    let speaker: String
    let startMs: Int
    let endMs: Int
    let text: String
    var id: String { key }
}

/// Provisional recording-only results. This never writes meeting segments,
/// notes, search, or transcript revisions. Final processing replaces the
/// entire preview after its scoped engine job has drained.
final class MeetingLivePreview: ObservableObject {
    private struct Checkpoint: Codable {
        var passages: [MeetingLivePassage] = []
        var chapters: [MeetingChapter] = []
        var completedWindows: [String] = []
        var chapteredKeys: [String] = []
    }
    private enum Job {
        case transcription(MeetingLiveWindow)
        case chapters([MeetingLivePassage])
    }
    private struct Active {
        let id: String
        let wireMeetingID: String
        let job: Job
        var passages: [Int: MeetingLivePassage] = [:]
    }
    @Published var enabled: Bool {
        didSet { defaults?.set(enabled, forKey: "experimentalLiveMeetingPreview") }
    }
    @Published private(set) var passages: [MeetingLivePassage] = []
    @Published private(set) var chapters: [MeetingChapter] = []
    @Published private(set) var status = "Live preview is experimental. Final notes may change."
    @Published private(set) var meetingID: String?
    private let store: MeetingStore
    private let engineReady: () -> Bool
    private let send: ([String: Any]) -> Void
    private let defaults: UserDefaults?
    private let now: () -> TimeInterval
    private var directory: URL?
    private var checkpoint = Checkpoint()
    private var active: Active?
    private var uncertain: [Active] = []
    private var fenceJob: Job?
    private var needsFence = false
    private var timer: Timer?
    private var notBefore: TimeInterval = 0
    private var stopping = false
    private var drainCallbacks: [() -> Void] = []
    private var windowsSinceChapters = 0
    private var chapterFailures = 0

    init(store: MeetingStore, engineReady: @escaping () -> Bool,
         send: @escaping ([String: Any]) -> Void, defaults: UserDefaults? = .standard,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.engineReady = engineReady; self.send = send
        self.defaults = defaults; self.now = now
        enabled = defaults?.bool(forKey: "experimentalLiveMeetingPreview") ?? false
    }

    func begin(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, self.meetingID == nil,
              let directory = store.acquireLivePreview(meetingID: meetingID) else { return }
        self.meetingID = meetingID; self.directory = directory
        stopping = false; chapterFailures = 0; windowsSinceChapters = 0; notBefore = 0
        let url = directory.appendingPathComponent("preview.json")
        if let data = MeetingLiveWindowWriter.readData(at: url, maxBytes: 256_000),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: data) {
            checkpoint = saved
            boundCheckpoint()
        } else { checkpoint = Checkpoint() }
        publish()
        status = "Waiting for the first sealed audio window…"
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.pump() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        pump()
    }

    /// Capture has already closed its writers. Cancel by exact job ID, wait
    /// for the terminal event (or confirmed engine exit), then remove files.
    /// A transport disconnect alone never authorizes deleting in-use audio.
    func stopAndDrain(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard meetingID != nil else { completion(); return }
        stopping = true
        drainCallbacks.append(completion)
        for job in uncertain { send(["cmd": cancellation(for: job.job), "id": job.id]) }
        if let active { send(["cmd": cancellation(for: active.job), "id": active.id]) }
        else if !needsFence { finishDrain() }
        else { pump() }
    }

    func handle(_ event: EngineEvent) {
        if let terminalID = Self.terminalID(event), uncertain.contains(where: { $0.id == terminalID }) {
            uncertain.removeAll { $0.id == terminalID }
            if stopping && active == nil && !needsFence { finishDrain() }
            else { pump() }
            return
        }
        guard var job = active else { return }
        switch event {
        case .meetingTranscribeAccepted(let id, let wireMeetingID, _),
             .meetingNotesAccepted(let id, let wireMeetingID):
            guard id == job.id, wireMeetingID == job.wireMeetingID else { return }
            // Acceptance is a mutex fence: no earlier background job still
            // owns the engine, including a terminal reply lost at socket EOF.
            uncertain.removeAll(); needsFence = false; fenceJob = nil
            if stopping { send(["cmd": cancellation(for: job.job), "id": job.id]) }
        case .meetingSegment(let id, let segment):
            guard id == job.id, segment.meetingID == job.wireMeetingID,
                  case .transcription(let window) = job.job, !stopping,
                  segment.chunkIndex >= 0, segment.chunkIndex < 1_000,
                  segment.startMs >= 0, segment.endMs > segment.startMs,
                  segment.endMs <= window.endMs - window.startMs + 100,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Engine timestamps describe audio blocks, never individual words.
            let keyIndex = window.startFrame * 1_000 + Int64(segment.chunkIndex)
            job.passages[segment.chunkIndex] = MeetingLivePassage(
                key: "\(window.speakerValue):\(keyIndex)", speaker: window.speakerValue,
                startMs: window.startMs + segment.startMs,
                endMs: min(window.endMs, window.startMs + segment.endMs),
                text: String(segment.text.prefix(4_000)))
            active = job
        case .meetingTranscribed(let id, let wireMeetingID, _, _, _, let silent):
            guard id == job.id, wireMeetingID == job.wireMeetingID,
                  case .transcription(let window) = job.job else { return }
            uncertain.removeAll(); needsFence = false; fenceJob = nil
            if stopping { active = nil; finishDrain(); return }
            let previous = checkpoint
            var updated = checkpoint
            if !silent {
                updated.passages.removeAll { passage in job.passages.values.contains { $0.key == passage.key } }
                updated.passages.append(contentsOf: job.passages.sorted { $0.key < $1.key }.map(\.value))
            }
            updated.completedWindows.append(window.id)
            checkpoint = updated; boundCheckpoint()
            // Replay is idempotent even if the process dies before retire.
            guard save() else { checkpoint = previous; pauseForStorage(); return }
            if let directory { MeetingLiveWindowWriter.retire(window, in: directory) }
            active = nil; windowsSinceChapters += 1; publish(); pump()
        case .meetingTranscribeFailed(let id, let wireMeetingID, _, _, let code):
            guard id == job.id, wireMeetingID == job.wireMeetingID else { return }
            settleFailure(job, code: code)
        case .meetingNotesReady(let id, let wireMeetingID, let notes):
            guard id == job.id, wireMeetingID == job.wireMeetingID,
                  case .chapters(let input) = job.job else { return }
            uncertain.removeAll(); needsFence = false; fenceJob = nil
            if stopping { active = nil; finishDrain(); return }
            let previous = checkpoint
            let keys = Dictionary(uniqueKeysWithValues: input.map { ($0.key, $0) })
            let valid = notes.chapters.filter {
                keys[$0.startKey]?.text == $0.startText && keys[$0.endKey]?.text == $0.endText
                    && (keys[$0.startKey]?.startMs ?? Int.max) <= (keys[$0.endKey]?.startMs ?? -1)
            }
            checkpoint.chapters.append(contentsOf: valid)
            checkpoint.chapteredKeys.append(contentsOf: input.map(\.key))
            boundCheckpoint()
            guard save() else { checkpoint = previous; pauseForStorage(); return }
            active = nil; chapterFailures = 0; windowsSinceChapters = 0; publish(); pump()
        case .meetingNotesFailed(let id, let wireMeetingID, _, let code):
            guard id == job.id, wireMeetingID == job.wireMeetingID else { return }
            settleFailure(job, code: code)
        default: break
        }
    }

    func handleEngineState(_ state: EngineSupervisor.State) {
        switch state {
        case .stopped, .degraded, .launching:
            // These UI states can also mean EOF or a failed local launch
            // while an external engine still decodes. None proves retirement.
            // Preserve files until terminal reply or an accepted mutex fence.
            if let active {
                if !uncertain.contains(where: { $0.id == active.id }) { uncertain.append(active) }
                uncertain = Array(uncertain.suffix(4))
                needsFence = true; fenceJob = active.job; self.active = nil
            }
            status = "Preview is reconnecting. Recording continues."
        case .ready:
            for job in uncertain { send(["cmd": cancellation(for: job.job), "id": job.id]) }
            if stopping, let active { send(["cmd": cancellation(for: active.job), "id": active.id]) }
            pump()
        case .connecting:
            status = "Preview is reconnecting. Recording continues."
        }
    }

    func pump() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active == nil, let meetingID, let directory else { return }
        if stopping && !needsFence { finishDrain(); return }
        if !stopping && store.recordMetadata(id: meetingID)?.status != .recording {
            stopAndDrain(completion: {}); return
        }
        guard engineReady() else {
            status = "Preview is waiting for the speech engine. Recording continues."; return
        }
        guard now() >= notBefore else { return }
        if needsFence, let fenceJob {
            // A fresh scoped request either fences a lost terminal reply or
            // receives busy and backs off. Only one engine job is accepted;
            // retain at most four cancellation identities across repeated EOFs.
            for old in uncertain { send(["cmd": cancellation(for: old.job), "id": old.id]) }
            switch fenceJob {
            case .transcription(let window): beginTranscription(window)
            case .chapters(let passages): beginChapters(passages)
            }
            return
        }
        var pending = MeetingLiveWindowWriter.pending(in: directory).filter { $0.meetingID == meetingID }
        // Saved result + unretired descriptor is the crash replay boundary.
        for window in pending where checkpoint.completedWindows.contains(window.id) {
            MeetingLiveWindowWriter.retire(window, in: directory)
        }
        pending.removeAll { checkpoint.completedWindows.contains($0.id) }
        let newPassages = checkpoint.passages.filter { !checkpoint.chapteredKeys.contains($0.key) }
        if chapterFailures < 3, windowsSinceChapters >= 2, !newPassages.isEmpty {
            var input: [MeetingLivePassage] = []; var chars = 0
            for passage in newPassages.prefix(12) {
                guard chars + passage.text.count <= 16_000 else { break }
                input.append(passage); chars += passage.text.count
            }
            if !input.isEmpty { beginChapters(input); return }
        }
        guard let window = pending.first else {
            status = passages.isEmpty ? "Waiting for the first sealed audio window…"
                : "Provisional preview. Final notes may change."
            return
        }
        beginTranscription(window)
    }

    private func beginTranscription(_ window: MeetingLiveWindow) {
        guard let directory else { return }
        let job = Active(id: "live-transcript-" + UUID().uuidString,
            wireMeetingID: UUID().uuidString, job: .transcription(window))
        active = job; status = "Updating the provisional transcript…"
        send(["cmd": "meeting_transcribe", "id": job.id, "meeting_id": job.wireMeetingID,
              "speaker": window.speakerValue, "path": window.audioURL(in: directory).path, "start_chunk": 0])
    }

    private func beginChapters(_ input: [MeetingLivePassage]) {
        let job = Active(id: "live-chapters-" + UUID().uuidString,
            wireMeetingID: UUID().uuidString, job: .chapters(input))
        active = job; status = "Updating provisional topics…"
        send(["cmd": "meeting_notes", "id": job.id, "meeting_id": job.wireMeetingID,
              "transcript": input.map(\.text).joined(separator: "\n"),
              "passages": input.map { ["key": $0.key, "text": $0.text,
                "start_ms": $0.startMs, "end_ms": $0.endMs] as [String: Any] }])
    }

    private func settleFailure(_ job: Active, code: String?) {
        active = nil
        if stopping {
            if !needsFence { finishDrain() }
            else { notBefore = now() + 4 }
            return
        }
        if needsFence {
            notBefore = now() + 4
            status = "Preview is reconnecting. Recording continues."
            return
        }
        if case .transcription(let window) = job.job,
           ["too_short", "unsupported_audio"].contains(code ?? "") {
            let previous = checkpoint
            checkpoint.completedWindows.append(window.id); boundCheckpoint()
            if save(), let directory { MeetingLiveWindowWriter.retire(window, in: directory) }
            else { checkpoint = previous }
        }
        if case .chapters = job.job, code != "busy" { chapterFailures += 1 }
        notBefore = now() + (code == "busy" ? 4 : 30)
        status = "Preview is waiting for available models. Recording continues."
    }

    private func pauseForStorage() {
        active = nil; notBefore = now() + 30
        status = "Preview could not be saved. Recording continues."
    }

    private func cancellation(for job: Job) -> String {
        switch job {
        case .transcription: return "meeting_transcribe_cancel"
        case .chapters: return "meeting_notes_cancel"
        }
    }

    private func boundCheckpoint() {
        var seen: Set<String> = []
        checkpoint.passages = checkpoint.passages.prefix(240).filter {
            $0.key.count <= 80 && ["me", "them"].contains($0.speaker)
                && $0.startMs >= 0 && $0.endMs > $0.startMs && $0.text.utf8.count <= 16_000
                && seen.insert($0.key).inserted
        }
        checkpoint.passages.sort { ($0.startMs, $0.key) < ($1.startMs, $1.key) }
        checkpoint.passages = Array(checkpoint.passages.suffix(120))
        while checkpoint.passages.reduce(0, { $0 + $1.text.utf8.count }) > 96_000 {
            checkpoint.passages.removeFirst()
        }
        let keys = Set(checkpoint.passages.map(\.key))
        checkpoint.chapters = Array(checkpoint.chapters.filter {
            keys.contains($0.startKey) && keys.contains($0.endKey)
                && !$0.title.isEmpty && $0.title.count <= 160
        }.suffix(40))
        checkpoint.completedWindows = Array(checkpoint.completedWindows.suffix(64))
        checkpoint.chapteredKeys = Array(Set(checkpoint.chapteredKeys).intersection(keys)).sorted()
        // Chapters repeat their exact boundary text; bound their encoded
        // checkpoint too, rather than only counting displayed rows.
        while !checkpoint.chapters.isEmpty,
              (try? JSONEncoder().encode(checkpoint).count) ?? Int.max > 240_000 {
            checkpoint.chapters.removeFirst()
        }
    }

    private func save() -> Bool {
        guard let directory else { return false }
        do {
            try MeetingLiveWindowWriter.write(checkpoint, to: directory.appendingPathComponent("preview.json"))
            return true
        } catch { return false }
    }

    private func publish() { passages = checkpoint.passages; chapters = checkpoint.chapters }

    private static func terminalID(_ event: EngineEvent) -> String? {
        switch event {
        case .meetingTranscribed(let id, _, _, _, _, _), .meetingTranscribeFailed(let id, _, _, _, _),
             .meetingNotesReady(let id, _, _), .meetingNotesFailed(let id, _, _, _): return id
        default: return nil
        }
    }

    private func finishDrain() {
        guard active == nil, !needsFence else { return }
        timer?.invalidate(); timer = nil
        if let meetingID { store.releaseLivePreview(meetingID: meetingID) }
        meetingID = nil; directory = nil; checkpoint = Checkpoint()
        passages = []; chapters = []; stopping = false
        let callbacks = drainCallbacks; drainCallbacks.removeAll(); callbacks.forEach { $0() }
    }
}

struct MeetingLivePreviewView: View {
    @ObservedObject var model: MeetingLivePreview
    @State private var expanded = true

    var body: some View {
        GroupCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(model.status)).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Shows recent audio blocks, not word-level timing. Me is your microphone; Them is Mac audio."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.text("Preview may skip audio while models are busy. Final transcription uses the complete recording."))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.chapters.enumerated()), id: \.offset) { _, chapter in
                                Text(chapter.title).font(.callout.weight(.semibold))
                            }
                            ForEach(model.passages) { passage in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(L10n.text(passage.speaker == "me" ? "Me" : "Them"))
                                        .font(.caption.weight(.semibold)).frame(width: 42, alignment: .leading)
                                    Text(passage.text).font(.callout).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 200)
                }.padding(.top, 8)
            } label: {
                Text(L10n.text("Live preview · Experimental")).font(.callout.weight(.semibold))
            }
        }
    }
}
