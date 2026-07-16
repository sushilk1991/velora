import Combine
import Foundation

extension Notification.Name {
    static let veloraMeetingsChanged = Notification.Name("VeloraMeetingsChanged")
}

/// Resumable post-capture pipeline. Each engine chunk is committed before the
/// next one is requested; relaunch resumes from `MAX(chunk_index) + 1`.
final class MeetingProcessor: ObservableObject {
    enum State: Equatable {
        case idle
        case processing(meetingID: String, label: String, fraction: Double)
        case failed(meetingID: String, message: String)
    }

    private struct Track {
        let speaker: MeetingSpeaker
        let path: String
    }

    private struct Work {
        let meetingID: String
        let tracks: [Track]
        var trackIndex: Int
        var jobID: String
        var stage: Stage
    }

    private enum Stage { case transcribing, notes }

    private let supervisor: EngineSupervisor
    private let store: MeetingStore
    private var queued: [String] = []
    private var work: Work?
    /// A corrupt/resource-exhausting track must not create an endless
    /// engine-ready → retry → crash loop. Explicit user Retry resets the cap.
    private var engineRestartAttempts: [String: Int] = [:]

    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    init(supervisor: EngineSupervisor, store: MeetingStore) {
        self.supervisor = supervisor
        self.store = store
    }

    func enqueue(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard work?.meetingID != meetingID, !queued.contains(meetingID) else { return }
        engineRestartAttempts[meetingID] = 0
        // Protect queued audio from retention pruning even if the engine is
        // currently unavailable and cannot begin it immediately.
        store.markProcessing(meetingID: meetingID)
        queued.append(meetingID)
        notifyChanged()
        beginNextIfPossible()
    }

    func resumeRecoverable() {
        dispatchPrecondition(condition: .onQueue(.main))
        for record in store.resumable().reversed() where hasRecoverableAudio(record) {
            if work?.meetingID != record.id, !queued.contains(record.id) { queued.append(record.id) }
        }
        beginNextIfPossible()
    }

    func cancelCurrent() {
        guard let work else { return }
        supervisor.send([
            "cmd": work.stage == .notes
                ? "meeting_notes_cancel" : "meeting_transcribe_cancel",
            "id": work.jobID,
        ])
        store.markFailed(meetingID: work.meetingID, error: "Processing cancelled")
        engineRestartAttempts.removeValue(forKey: work.meetingID)
        state = .failed(meetingID: work.meetingID, message: "Processing cancelled")
        self.work = nil
        notifyChanged()
        beginNextIfPossible()
    }

    /// Removes a meeting from both pending and active background work before
    /// its row/audio are deleted. Without this, a user can delete a processing
    /// meeting while the engine keeps emitting segments for a record that no
    /// longer exists, leaving the processor in a misleading failed state.
    func cancelAndForget(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        queued.removeAll { $0 == meetingID }
        engineRestartAttempts.removeValue(forKey: meetingID)
        guard let active = work, active.meetingID == meetingID else { return }
        supervisor.send([
            "cmd": active.stage == .notes
                ? "meeting_notes_cancel" : "meeting_transcribe_cancel",
            "id": active.jobID,
        ])
        work = nil
        state = .idle
        beginNextIfPossible()
    }

    func handle(_ event: EngineEvent) {
        guard var work else { return }
        switch event {
        case .meetingTranscribeStarted(let id, let meetingID, let speaker, _, _, _):
            guard matches(id: id, meetingID: meetingID, work: work),
                  work.stage == .transcribing,
                  work.tracks.indices.contains(work.trackIndex),
                  work.tracks[work.trackIndex].speaker == speaker else { return }
            state = .processing(
                meetingID: meetingID,
                label: "Transcribing \(speaker.displayName)…",
                fraction: trackBase(work))
        case .meetingSegment(let id, let segment):
            guard matches(id: id, meetingID: segment.meetingID, work: work) else { return }
            store.appendSegment(segment)
        case .meetingTranscribeProgress(let id, let meetingID, _, let fraction):
            guard matches(id: id, meetingID: meetingID, work: work) else { return }
            let count = max(1, work.tracks.count)
            let overall = (Double(work.trackIndex) + min(1, max(0, fraction)))
                / Double(count) * 0.75
            state = .processing(
                meetingID: meetingID, label: "Transcribing meeting…", fraction: overall)
        case .meetingTranscribed(let id, let meetingID, _, _, _):
            guard matches(id: id, meetingID: meetingID, work: work) else { return }
            work.trackIndex += 1
            self.work = work
            if work.trackIndex < work.tracks.count { beginCurrentTrack() }
            else { beginNotes() }
        case .meetingTranscribeFailed(let id, let meetingID, _, let error, let code):
            guard matches(id: id, meetingID: meetingID, work: work) else { return }
            failActive(error, code: code)
        case .meetingNotesProgress(let id, let meetingID, let fraction):
            guard matches(id: id, meetingID: meetingID, work: work), work.stage == .notes else { return }
            state = .processing(
                meetingID: meetingID, label: "Creating notes…",
                fraction: 0.75 + min(1, max(0, fraction)) * 0.25)
        case .meetingNotesReady(let id, let meetingID, let notes):
            guard matches(id: id, meetingID: meetingID, work: work), work.stage == .notes else { return }
            store.complete(meetingID: meetingID, notes: notes)
            engineRestartAttempts.removeValue(forKey: meetingID)
            self.work = nil
            state = .idle
            notifyChanged()
            beginNextIfPossible()
        case .meetingNotesFailed(let id, let meetingID, let error, let code):
            guard matches(id: id, meetingID: meetingID, work: work) else { return }
            failActive(error, code: code)
        default:
            break
        }
    }

    func handleEngineStateChange(_ engineState: EngineSupervisor.State) {
        switch engineState {
        case .ready:
            if work == nil { resumeRecoverable() }
        case .stopped, .launching, .degraded:
            if let meetingID = work?.meetingID {
                let attempts = (engineRestartAttempts[meetingID] ?? 0) + 1
                engineRestartAttempts[meetingID] = attempts
                if attempts >= 3 {
                    store.markFailed(
                        meetingID: meetingID,
                        error: "Speech engine repeatedly restarted on this meeting; retry manually")
                    state = .failed(
                        meetingID: meetingID,
                        message: "Meeting processing stopped after repeated engine restarts")
                } else {
                    store.markProcessing(meetingID: meetingID)
                    state = .processing(
                        meetingID: meetingID,
                        label: "Waiting for speech engine to restart…", fraction: 0)
                }
                work = nil
                notifyChanged()
            }
        case .connecting:
            break
        }
    }

    private func beginNextIfPossible() {
        guard work == nil, supervisor.isReady, !queued.isEmpty else { return }
        let meetingID = queued.removeFirst()
        guard let record = store.record(id: meetingID) else {
            beginNextIfPossible(); return
        }
        let tracks = availableTracks(record)
        guard !tracks.isEmpty else {
            store.markFailed(meetingID: meetingID, error: "Meeting audio is missing")
            state = .failed(meetingID: meetingID, message: "Meeting audio is missing")
            notifyChanged()
            beginNextIfPossible()
            return
        }
        store.markProcessing(meetingID: meetingID)
        work = Work(
            meetingID: meetingID, tracks: tracks, trackIndex: 0,
            jobID: UUID().uuidString, stage: .transcribing)
        beginCurrentTrack()
    }

    private func beginCurrentTrack() {
        guard var work, work.tracks.indices.contains(work.trackIndex) else { return }
        let track = work.tracks[work.trackIndex]
        work.jobID = UUID().uuidString
        work.stage = .transcribing
        self.work = work
        state = .processing(
            meetingID: work.meetingID,
            label: "Preparing \(track.speaker.displayName)…",
            fraction: trackBase(work))
        supervisor.send([
            "cmd": "meeting_transcribe",
            "id": work.jobID,
            "meeting_id": work.meetingID,
            "speaker": track.speaker.rawValue,
            "path": track.path,
            "start_chunk": store.nextChunk(
                meetingID: work.meetingID, speaker: track.speaker),
        ])
    }

    private func beginNotes() {
        guard var work, let record = store.record(id: work.meetingID) else {
            failActive("Meeting disappeared during processing"); return
        }
        let transcript = record.formattedTranscript
        guard !transcript.isEmpty else { failActive("No speech was found in the recording"); return }
        work.jobID = UUID().uuidString
        work.stage = .notes
        self.work = work
        state = .processing(
            meetingID: work.meetingID, label: "Creating notes…", fraction: 0.75)
        supervisor.send([
            "cmd": "meeting_notes", "id": work.jobID,
            "meeting_id": work.meetingID, "transcript": transcript,
        ])
    }

    private func failActive(_ message: String, code: String? = nil) {
        guard let meetingID = work?.meetingID else { return }
        if code == "busy" {
            work = nil
            if !queued.contains(meetingID) { queued.insert(meetingID, at: 0) }
            state = .processing(
                meetingID: meetingID, label: "Waiting for foreground work…", fraction: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.beginNextIfPossible()
            }
            return
        }
        store.markFailed(meetingID: meetingID, error: message)
        engineRestartAttempts.removeValue(forKey: meetingID)
        work = nil
        state = .failed(meetingID: meetingID, message: message)
        notifyChanged()
        beginNextIfPossible()
    }

    private func matches(id: String?, meetingID: String, work: Work) -> Bool {
        id == work.jobID && meetingID == work.meetingID
    }

    private func trackBase(_ work: Work) -> Double {
        Double(work.trackIndex) / Double(max(1, work.tracks.count)) * 0.75
    }

    private func availableTracks(_ record: MeetingRecord) -> [Track] {
        var tracks: [Track] = []
        if let relative = record.micPath,
           let url = store.audioURL(relativePath: relative),
           FileManager.default.fileExists(atPath: url.path) {
            tracks.append(Track(speaker: .me, path: url.path))
        }
        if let relative = record.systemPath,
           let url = store.audioURL(relativePath: relative),
           FileManager.default.fileExists(atPath: url.path) {
            tracks.append(Track(speaker: .them, path: url.path))
        }
        return tracks
    }

    private func hasRecoverableAudio(_ record: MeetingRecord) -> Bool {
        !availableTracks(record).isEmpty
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .veloraMeetingsChanged, object: nil)
    }
}
