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

    private struct QueueItem {
        let meetingID: String
        let reprocessing: Bool
    }

    private struct Work {
        let meetingID: String
        let tracks: [Track]
        let reprocessing: Bool
        var trackIndex: Int
        var jobID: String
        var stage: Stage
    }

    private enum Stage { case transcribing, notes }

    private let store: MeetingStore
    private let engineIsReady: () -> Bool
    private let sendToEngine: ([String: Any]) -> Void
    private var queued: [QueueItem] = []
    private var work: Work?
    /// A corrupt/resource-exhausting track must not create an endless
    /// engine-ready → retry → crash loop. Explicit user Retry resets the cap.
    private var engineRestartAttempts: [String: Int] = [:]

    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    var onNotesReady: ((String) -> Void)?

    init(supervisor: EngineSupervisor, store: MeetingStore) {
        self.store = store
        engineIsReady = { supervisor.isReady }
        sendToEngine = { supervisor.send($0) }
    }

    /// Deterministic app-side pipeline seam. Production always uses the
    /// EngineSupervisor initializer above; self-test supplies the real wire
    /// messages back as typed events to cover both tracks through notes-ready.
    init(
        store: MeetingStore,
        engineIsReady: @escaping () -> Bool,
        sendToEngine: @escaping ([String: Any]) -> Void
    ) {
        self.store = store
        self.engineIsReady = engineIsReady
        self.sendToEngine = sendToEngine
    }

    func enqueue(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard work?.meetingID != meetingID, !isQueued(meetingID) else { return }
        let reprocessing = store.isReprocessing(meetingID: meetingID)
        guard let record = store.recordMetadata(id: meetingID),
              reprocessing
                ? store.hasAllCapturedAudio(for: record)
                : hasRecoverableAudio(record) else {
            failUnqueued(meetingID: meetingID, message: "No usable audio was captured for this meeting")
            return
        }
        enqueueValidated(meetingID: meetingID, reprocessing: reprocessing)
    }

    private func enqueueValidated(meetingID: String, reprocessing: Bool) {
        engineRestartAttempts[meetingID] = 0
        // Protect queued audio from retention pruning even if the engine is
        // currently unavailable and cannot begin it immediately.
        store.markProcessing(meetingID: meetingID)
        queued.append(QueueItem(meetingID: meetingID, reprocessing: reprocessing))
        notifyChanged()
        beginNextIfPossible()
    }

    /// Explicitly rebuilds a completed/failed transcript with the current
    /// planner. Notes remain visible until fresh output replaces them.
    func reprocess(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard work?.meetingID != meetingID, !isQueued(meetingID) else { return }
        guard let record = store.recordMetadata(id: meetingID),
              store.hasAllCapturedAudio(for: record) else {
            failReprocessUnqueued(
                meetingID: meetingID,
                message: "Every captured audio track must still be readable to safely Recreate this meeting")
            return
        }
        guard store.beginReprocess(meetingID: meetingID) else {
            failReprocessUnqueued(
                meetingID: meetingID,
                message: "Could not prepare a safe transcript replacement")
            return
        }
        enqueueValidated(meetingID: meetingID, reprocessing: true)
    }

    func resumeRecoverable() {
        dispatchPrecondition(condition: .onQueue(.main))
        var changed = false
        for record in store.resumable().reversed() {
            let reprocessing = store.isReprocessing(meetingID: record.id)
            let audioReady = reprocessing
                ? store.hasAllCapturedAudio(for: record)
                : hasRecoverableAudio(record)
            guard audioReady else {
                persistFailure(
                    meetingID: record.id, reprocessing: reprocessing,
                    message: "Meeting audio is missing or unreadable")
                state = .failed(
                    meetingID: record.id,
                    message: "Meeting audio is missing or unreadable")
                changed = true
                continue
            }
            if work?.meetingID != record.id, !isQueued(record.id) {
                queued.append(QueueItem(
                    meetingID: record.id, reprocessing: reprocessing))
            }
        }
        if changed { notifyChanged() }
        beginNextIfPossible()
    }

    func cancelCurrent() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let work {
            cancel(meetingID: work.meetingID)
        } else if case .processing(let waitingID, _, _) = state {
            cancel(meetingID: waitingID)
        }
    }

    /// Cancels one active or queued meeting. A selected meeting can be pending
    /// behind other work, so cancellation must target its id instead of the
    /// processor's single presentation state.
    func cancel(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let active = work.flatMap { $0.meetingID == meetingID ? $0 : nil }
        let queuedMatch = isQueued(meetingID)
        let presented = stateMeetingID == meetingID
        guard active != nil || queuedMatch || presented else { return }
        if let active {
            sendToEngine([
                "cmd": active.stage == .notes
                    ? "meeting_notes_cancel" : "meeting_transcribe_cancel",
                "id": active.jobID,
            ])
            work = nil
        }
        queued.removeAll { $0.meetingID == meetingID }
        let reprocessing = active?.reprocessing
            ?? store.isReprocessing(meetingID: meetingID)
        persistFailure(
            meetingID: meetingID, reprocessing: reprocessing,
            message: "Processing cancelled")
        engineRestartAttempts.removeValue(forKey: meetingID)
        if active != nil || presented {
            state = .failed(meetingID: meetingID, message: "Processing cancelled")
        }
        notifyChanged()
        beginNextIfPossible()
    }

    func isPending(meetingID: String) -> Bool {
        if work?.meetingID == meetingID || isQueued(meetingID) { return true }
        if case .processing(let presentedID, _, _) = state {
            return presentedID == meetingID
        }
        return false
    }

    /// Removes a meeting from both pending and active background work before
    /// its row/audio are deleted. Without this, a user can delete a processing
    /// meeting while the engine keeps emitting segments for a record that no
    /// longer exists, leaving the processor in a misleading failed state.
    func cancelAndForget(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let queuedCount = queued.count
        queued.removeAll { $0.meetingID == meetingID }
        engineRestartAttempts.removeValue(forKey: meetingID)
        guard let active = work, active.meetingID == meetingID else {
            let ownedState = stateMeetingID == meetingID
            if ownedState { state = .idle }
            if queued.count != queuedCount || ownedState {
                notifyChanged()
                beginNextIfPossible()
            }
            return
        }
        sendToEngine([
            "cmd": active.stage == .notes
                ? "meeting_notes_cancel" : "meeting_transcribe_cancel",
            "id": active.jobID,
        ])
        work = nil
        state = .idle
        notifyChanged()
        beginNextIfPossible()
    }

    func handle(_ event: EngineEvent) {
        guard var work else { return }
        switch event {
        case .meetingTranscribeStarted(
            let id, let meetingID, let speaker, _, _, _, let restarted):
            guard matches(id: id, meetingID: meetingID, work: work),
                  work.stage == .transcribing,
                  work.tracks.indices.contains(work.trackIndex),
                  work.tracks[work.trackIndex].speaker == speaker else { return }
            if restarted {
                // The engine lost the chunk plan our committed rows came from
                // (crash before the plan cache, or an upgraded install) and is
                // re-running the whole track — stale rows would otherwise
                // duplicate or mislabel transcript lines.
                if work.reprocessing {
                    store.deleteReprocessSegments(
                        meetingID: meetingID, remoteTrack: speaker.isRemote)
                } else {
                    store.deleteSegments(meetingID: meetingID, remoteTrack: speaker.isRemote)
                }
            }
            state = .processing(
                meetingID: meetingID,
                label: "Transcribing \(speaker.displayName)…",
                fraction: trackBase(work))
        case .meetingSegment(let id, let segment):
            guard matches(id: id, meetingID: segment.meetingID, work: work) else { return }
            if work.reprocessing {
                store.appendReprocessSegment(segment)
            } else {
                store.appendSegment(segment)
            }
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
            if work.reprocessing {
                guard store.completeReprocess(
                    meetingID: meetingID, notes: notes,
                    requiredSpeakers: work.tracks.map(\.speaker))
                else {
                    failActive("Could not safely replace the transcript and notes")
                    return
                }
            } else {
                store.complete(meetingID: meetingID, notes: notes)
            }
            engineRestartAttempts.removeValue(forKey: meetingID)
            self.work = nil
            state = .idle
            notifyChanged()
            onNotesReady?(meetingID)
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
                let reprocessing = work?.reprocessing ?? false
                let attempts = (engineRestartAttempts[meetingID] ?? 0) + 1
                engineRestartAttempts[meetingID] = attempts
                if attempts >= 3 {
                    persistFailure(
                        meetingID: meetingID, reprocessing: reprocessing,
                        message: "Speech engine repeatedly restarted on this meeting; retry manually")
                    state = .failed(
                        meetingID: meetingID,
                        message: "Meeting processing stopped after repeated engine restarts")
                } else {
                    store.markProcessing(meetingID: meetingID)
                    if !isQueued(meetingID) {
                        queued.insert(
                            QueueItem(
                                meetingID: meetingID,
                                reprocessing: reprocessing),
                            at: 0)
                    }
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
        guard work == nil, !queued.isEmpty else { return }
        guard engineIsReady() else {
            let next = queued[0]
            state = .processing(
                meetingID: next.meetingID,
                label: "Waiting for speech engine…", fraction: 0)
            return
        }
        let item = queued.removeFirst()
        let meetingID = item.meetingID
        guard let record = store.recordMetadata(id: meetingID) else {
            beginNextIfPossible(); return
        }
        let tracks = availableTracks(record)
        let capturedSpeakers = Set(capturedSpeakers(record))
        let availableSpeakers = Set(tracks.map(\.speaker))
        guard !tracks.isEmpty,
              !item.reprocessing
                || (!capturedSpeakers.isEmpty && availableSpeakers == capturedSpeakers)
        else {
            persistFailure(
                meetingID: meetingID, reprocessing: item.reprocessing,
                message: "One or more captured meeting tracks are missing or unreadable")
            state = .failed(
                meetingID: meetingID,
                message: "One or more captured meeting tracks are missing or unreadable")
            notifyChanged()
            beginNextIfPossible()
            return
        }
        store.markProcessing(meetingID: meetingID)
        work = Work(
            meetingID: meetingID, tracks: tracks, reprocessing: item.reprocessing, trackIndex: 0,
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
        let startChunk = work.reprocessing
            ? store.nextReprocessChunk(
                meetingID: work.meetingID, speaker: track.speaker)
            : store.nextChunk(
                meetingID: work.meetingID, speaker: track.speaker)
        sendToEngine([
            "cmd": "meeting_transcribe",
            "id": work.jobID,
            "meeting_id": work.meetingID,
            "speaker": track.speaker.rawValue,
            "path": track.path,
            "start_chunk": startChunk,
        ])
    }

    private func beginNotes() {
        guard var work else { return }
        if work.reprocessing,
           let emptyTrack = work.tracks.first(where: {
               !store.hasReprocessSegments(
                   meetingID: work.meetingID, speaker: $0.speaker)
           }) {
            failActive(
                "No speech was found in the \(emptyTrack.speaker.displayName) audio; "
                    + "the previous transcript was kept")
            return
        }
        guard
              let record = work.reprocessing
                ? store.reprocessRecord(id: work.meetingID)
                : store.record(id: work.meetingID) else {
            failActive("Meeting disappeared during processing"); return
        }
        let transcript = record.formattedTranscript
        guard !transcript.isEmpty else { failActive("No speech was found in the recording"); return }
        work.jobID = UUID().uuidString
        work.stage = .notes
        self.work = work
        state = .processing(
            meetingID: work.meetingID, label: "Creating notes…", fraction: 0.75)
        sendToEngine([
            "cmd": "meeting_notes", "id": work.jobID,
            "meeting_id": work.meetingID, "transcript": transcript,
        ])
    }

    private func failActive(_ message: String, code: String? = nil) {
        guard let meetingID = work?.meetingID else { return }
        if code == "busy" {
            let reprocessing = work?.reprocessing ?? false
            work = nil
            if !isQueued(meetingID) {
                queued.insert(
                    QueueItem(meetingID: meetingID, reprocessing: reprocessing),
                    at: 0)
            }
            state = .processing(
                meetingID: meetingID, label: "Waiting for foreground work…", fraction: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.beginNextIfPossible()
            }
            return
        }
        let reprocessing = work?.reprocessing ?? false
        persistFailure(
            meetingID: meetingID, reprocessing: reprocessing, message: message)
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
           store.hasUsableAudio(relativePath: relative) {
            tracks.append(Track(speaker: .me, path: url.path))
        }
        if let relative = record.systemPath,
           let url = store.audioURL(relativePath: relative),
           store.hasUsableAudio(relativePath: relative) {
            tracks.append(Track(speaker: .them, path: url.path))
        }
        return tracks
    }

    private func hasRecoverableAudio(_ record: MeetingRecord) -> Bool {
        !availableTracks(record).isEmpty
    }

    private func capturedSpeakers(_ record: MeetingRecord) -> [MeetingSpeaker] {
        var speakers: [MeetingSpeaker] = []
        if record.micPath != nil { speakers.append(.me) }
        if record.systemPath != nil { speakers.append(.them) }
        return speakers
    }

    private func isQueued(_ meetingID: String) -> Bool {
        queued.contains { $0.meetingID == meetingID }
    }

    private var stateMeetingID: String? {
        switch state {
        case .processing(let meetingID, _, _), .failed(let meetingID, _):
            return meetingID
        case .idle:
            return nil
        }
    }

    private func failUnqueued(meetingID: String, message: String) {
        persistFailure(
            meetingID: meetingID,
            reprocessing: store.isReprocessing(meetingID: meetingID),
            message: message)
        state = .failed(meetingID: meetingID, message: message)
        notifyChanged()
    }

    private func failReprocessUnqueued(meetingID: String, message: String) {
        store.markReprocessFailed(meetingID: meetingID, error: message)
        state = .failed(meetingID: meetingID, message: message)
        notifyChanged()
    }

    private func persistFailure(
        meetingID: String, reprocessing: Bool, message: String
    ) {
        if reprocessing {
            store.markReprocessFailed(meetingID: meetingID, error: message)
        } else {
            store.markFailed(meetingID: meetingID, error: message)
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .veloraMeetingsChanged, object: nil)
    }
}
