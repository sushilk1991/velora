import Combine
import Foundation

extension Notification.Name {
    static let veloraMeetingsChanged = Notification.Name("VeloraMeetingsChanged")
}

/// Mirrors the engine's built-in meeting-notes guidance (server.py,
/// `_run_meeting_notes`) so Settings can show what "default" means and seed
/// customization from it. The JSON schema clause is enforced engine-side and
/// is never part of the editable text.
enum MeetingNotesPrompt {
    static let builtinGuidance =
        "Create faithful meeting notes from this transcript chunk. "
        + "Do not invent owners, deadlines, decisions, or facts. "
        + "Me and Them are audio channels, not verified identities. "
        + "If a legacy transcript contains Speaker-number labels, treat those "
        + "the same way. Never guess who a speaker is."
}

enum MeetingFailurePresentation {
    static func hudMessage(_ detail: String) -> String {
        let value = detail.lowercased()
        if value.contains("note") && value.contains("timeout") {
            return "Meeting notes timed out"
        }
        if value.contains("note") || value.contains("model") {
            return "Meeting notes failed"
        }
        if value.contains("no speech") {
            return "No speech found in meeting"
        }
        if value.contains("audio") || value.contains("file") {
            return "Meeting audio could not be processed"
        }
        return "Meeting processing failed"
    }
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
        let notesOnly: Bool
        /// The one automatic notes retry (`requeueStalledNotes`).
        var automatic = false
        /// A retried job starts no earlier than this `now()` reading
        /// (`requeueActive`).
        var notBefore: TimeInterval?
    }

    private struct Work {
        let meetingID: String
        let tracks: [Track]
        let reprocessing: Bool
        var trackIndex: Int
        var jobID: String
        var stage: Stage
        /// How each finished track ended; a track absent here transcribed
        /// normally. Every run revisits every track, so this is complete by
        /// notes time even after a crash-resume.
        var issues: [MeetingSpeaker: MeetingTrackIssue] = [:]
        /// Nobody asked for this job, so it never takes the HUD: neither its
        /// progress nor its failure is presented (see `present`).
        var automatic = false
        /// The generated notes were refused once and written again after
        /// `notesSaveRetryDelay` (see `notesNotSaved`).
        var notesWriteRetried = false
    }

    private enum Stage { case transcribing, notes }

    private let store: MeetingStore
    private let engineIsReady: () -> Bool
    private let sendToEngine: ([String: Any]) -> Void
    private let notesPrompt: () -> String
    /// Seconds of system uptime, the clock retry delays are measured on.
    /// It is monotonic, like the timer that waits them out: setting the
    /// wall clock back must not stretch a wait. The self-test moves it.
    private let now: () -> TimeInterval
    private var queued: [QueueItem] = []
    private var work: Work?
    /// A corrupt/resource-exhausting track must not create an endless
    /// engine-ready → retry → crash loop. Explicit user Retry resets the cap.
    private var engineRestartAttempts: [String: Int] = [:]
    /// Meetings whose generated notes SQLite refused to save once this run;
    /// a second refusal is a notes failure (see `notesNotSaved`).
    private var notesSaveRetried: Set<String> = []
    /// Retries spent per meeting on `audioLoadFailedCode`; explicit user
    /// work and a finished job reset it.
    private var audioLoadRetries: [String: Int] = [:]
    /// Meetings whose cancel or failure SQLite refused to save. Their rows
    /// still look resumable (processing), so this run must not restart
    /// them on its own; explicit user work clears the entry.
    private var unsavedOutcomes: Set<String> = []
    /// Seconds before notes SQLite refused are written once more.
    private static let notesSaveRetryDelay: TimeInterval = 1
    /// The engine's code for a track file it can never transcribe (engine
    /// server.py, `MEETING_UNSUPPORTED_AUDIO`). Only this skips one track;
    /// every other failure is transient and fails the job for Retry.
    private static let unsupportedAudioCode = "unsupported_audio"
    /// The engine's code for a valid track too short to hold speech
    /// (server.py `MEETING_TRACK_TOO_SHORT`). It ends like a silent track.
    private static let trackTooShortCode = "too_short"
    /// The engine's code for a track file it could not read this time: the
    /// converter timed out or could not run, the disk was full, or the file
    /// changed (server.py `MEETING_AUDIO_LOAD_FAILED`). Retried like "busy",
    /// then the job fails; the track is never skipped.
    private static let audioLoadFailedCode = "audio_load_failed"
    private static let audioLoadRetryLimit = 3
    private static let audioLoadRetryDelay: TimeInterval = 30
    /// Seconds a "busy" engine gets before the job starts again.
    private static let busyRetryDelay: TimeInterval = 2
    /// Automatic notes retries one engine-ready may queue. An upgrade can
    /// find many stalled meetings at once; the rest wait for a later ready.
    private static let automaticNotesRetriesPerReady = 3
    /// Recorded for a captured track whose file cannot be opened, so it
    /// never reaches the engine.
    private static let unreadableTrackMessage = "The audio file could not be read"

    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    var onNotesReady: ((String) -> Void)?

    init(supervisor: EngineSupervisor, store: MeetingStore) {
        self.store = store
        engineIsReady = { supervisor.isReady }
        sendToEngine = { supervisor.send($0) }
        notesPrompt = { AppConfig.shared.meetingNotesPrompt }
        now = { ProcessInfo.processInfo.systemUptime }
    }

    /// Deterministic app-side pipeline seam. Production always uses the
    /// EngineSupervisor initializer above; self-test supplies the real wire
    /// messages back as typed events to cover both tracks through notes-ready.
    init(
        store: MeetingStore,
        engineIsReady: @escaping () -> Bool,
        sendToEngine: @escaping ([String: Any]) -> Void,
        notesPrompt: @escaping () -> String = { "" },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store
        self.engineIsReady = engineIsReady
        self.sendToEngine = sendToEngine
        self.notesPrompt = notesPrompt
        self.now = now
    }

    func enqueue(meetingID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard work?.meetingID != meetingID, !isQueued(meetingID) else { return }
        let reprocessing = store.isReprocessing(meetingID: meetingID)
        guard let record = store.recordMetadata(id: meetingID) else {
            failUnqueued(meetingID: meetingID, message: "Meeting could not be found")
            return
        }
        let notesOnly = !reprocessing && store.canRetryNotes(meetingID: meetingID)
        guard notesOnly || (reprocessing
                ? store.hasAllCapturedAudio(for: record)
                : hasRecoverableAudio(record)) else {
            failUnqueued(meetingID: meetingID, message: "No usable audio was captured for this meeting")
            return
        }
        enqueueValidated(
            meetingID: meetingID, reprocessing: reprocessing,
            notesOnly: notesOnly)
    }

    private func enqueueValidated(
        meetingID: String, reprocessing: Bool, notesOnly: Bool = false
    ) {
        engineRestartAttempts[meetingID] = 0
        audioLoadRetries.removeValue(forKey: meetingID)
        unsavedOutcomes.remove(meetingID)
        // Protect queued audio from retention pruning even if the engine is
        // currently unavailable and cannot begin it immediately.
        store.markProcessing(
            meetingID: meetingID, notesPending: notesOnly)
        queued.append(QueueItem(
            meetingID: meetingID, reprocessing: reprocessing,
            notesOnly: notesOnly))
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
            // An interrupted in-memory job has already preserved its exact
            // stage in `queued` (including notes-only retries after audio
            // retention). Do not reinterpret that row as a fresh audio job
            // when the engine reports ready again.
            guard work?.meetingID != record.id, !isQueued(record.id),
                  !unsavedOutcomes.contains(record.id) else {
                continue
            }
            let reprocessing = store.isReprocessing(meetingID: record.id)
            let notesOnly = !reprocessing
                && store.hasPendingNotes(meetingID: record.id)
                && store.hasCommittedSegments(meetingID: record.id)
            if notesOnly {
                // A crash mid automatic retry must not bring the HUD and the
                // notes window back for a job nobody asked for.
                queued.append(QueueItem(
                    meetingID: record.id, reprocessing: false,
                    notesOnly: true,
                    automatic: store.notesAutoRetried(meetingID: record.id)))
                continue
            }
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
            queued.append(QueueItem(
                meetingID: record.id, reprocessing: reprocessing,
                notesOnly: false))
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
        let queuedItem = queued.first { $0.meetingID == meetingID }
        let queuedMatch = queuedItem != nil
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
        let notesOnly = active?.stage == .notes || queuedItem?.notesOnly == true
        let stage: MeetingJobStage = reprocessing
            ? .recreate : notesOnly ? .notes : .transcription
        // The user stopped this job; never restart it on their behalf. The
        // failure and the spent automatic retry are saved together.
        veloraLog("Velora: meeting \(meetingID) processing cancelled")
        if !store.markCancelled(
            meetingID: meetingID, stage: stage, error: "Processing cancelled") {
            veloraLog(
                "Velora: meeting \(meetingID) cancel could not be saved; "
                + "it will not restart in this run")
            unsavedOutcomes.insert(meetingID)
        }
        engineRestartAttempts.removeValue(forKey: meetingID)
        notesSaveRetried.remove(meetingID)
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
        notesSaveRetried.remove(meetingID)
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
        case .meetingTranscribed(let id, let meetingID, _, _, _, let silent):
            guard matches(id: id, meetingID: meetingID, work: work) else { return }
            if silent {
                dropTrackLines(work)
            }
            finishTrack(work, issue: silent ? .silent : nil)
        case .meetingTranscribeFailed(let id, let meetingID, let speaker, let error, let code):
            guard matches(id: id, meetingID: meetingID, work: work) else { return }
            // A valid track too short to hold speech ends like a silent
            // one, in a first pass and in Recreate.
            if code == Self.trackTooShortCode, work.stage == .transcribing {
                finishTrack(work, issue: .tooShort)
                return
            }
            // A first pass keeps going past a track the engine can never
            // transcribe: the other side may still hold the conversation.
            // Recreate replaces a committed transcript, so it still needs
            // every track, and any other failure (busy, shutdown, cancel, a
            // transient engine error) retries or stops the job as a whole.
            guard !work.reprocessing, work.stage == .transcribing,
                  code == Self.unsupportedAudioCode else {
                failActive(error, code: code)
                return
            }
            veloraLog(
                "Velora: meeting \(meetingID) skipped the "
                + "\(speaker?.displayName ?? "unknown") track: \(error)")
            finishTrack(work, issue: .failed(error))
        case .meetingNotesProgress(let id, let meetingID, let fraction):
            guard matches(id: id, meetingID: meetingID, work: work), work.stage == .notes else { return }
            present(
                .processing(
                    meetingID: meetingID, label: "Creating notes…",
                    fraction: 0.75 + min(1, max(0, fraction)) * 0.25),
                automatic: work.automatic)
        case .meetingNotesReady(let id, let meetingID, let notes):
            guard matches(id: id, meetingID: meetingID, work: work), work.stage == .notes else { return }
            if work.reprocessing {
                // A silent or too-short track has no lines to require;
                // every other captured side must be in the replacement.
                guard store.completeReprocess(
                    meetingID: meetingID, notes: notes,
                    requiredSpeakers: work.tracks.map(\.speaker).filter {
                        work.issues[$0]?.holdsNoSpeech != true
                    },
                    issues: work.issues)
                else {
                    failActive("Could not safely replace the transcript and notes")
                    return
                }
            } else {
                guard store.complete(meetingID: meetingID, notes: notes) else {
                    notesNotSaved(work, notes: notes)
                    return
                }
            }
            notesSaved(work)
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
            if work == nil {
                requeueStalledNotes()
                resumeRecoverable()
            }
        case .stopped, .launching, .degraded:
            if let meetingID = work?.meetingID {
                let interruptedWork = work
                let reprocessing = interruptedWork?.reprocessing ?? false
                let notesOnly = interruptedWork?.stage == .notes && !reprocessing
                let attempts = (engineRestartAttempts[meetingID] ?? 0) + 1
                engineRestartAttempts[meetingID] = attempts
                let automatic = interruptedWork?.automatic ?? false
                if attempts >= 3 {
                    persistFailure(
                        meetingID: meetingID, reprocessing: reprocessing,
                        notesOnly: notesOnly,
                        message: "Speech engine repeatedly restarted on this meeting; retry manually")
                    present(
                        .failed(
                            meetingID: meetingID,
                            message: "Meeting processing stopped after repeated engine restarts"),
                        automatic: automatic)
                } else {
                    store.markProcessing(
                        meetingID: meetingID, notesPending: notesOnly)
                    if !isQueued(meetingID) {
                        queued.insert(
                            QueueItem(
                                meetingID: meetingID,
                                reprocessing: reprocessing,
                                notesOnly: notesOnly,
                                automatic: automatic),
                            at: 0)
                    }
                    present(
                        .processing(
                            meetingID: meetingID,
                            label: "Waiting for speech engine to restart…", fraction: 0),
                        automatic: automatic)
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
            present(
                .processing(
                    meetingID: next.meetingID,
                    label: "Waiting for speech engine…", fraction: 0),
                automatic: next.automatic)
            return
        }
        // A job waiting out its retry delay holds the head of the queue.
        // An enqueue, cancel or engine-ready in the meantime only checks
        // again later; starting it early spent every retry in seconds.
        let wait = queued[0].notBefore.map { $0 - now() } ?? 0
        guard wait <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.beginNextIfPossible()
            }
            return
        }
        let item = queued.removeFirst()
        let meetingID = item.meetingID
        guard let record = store.recordMetadata(id: meetingID) else {
            beginNextIfPossible(); return
        }
        if item.notesOnly {
            // Partial notes are regenerated too (Retry Notes); complete
            // notes mean the job already finished.
            guard !item.reprocessing, record.notes.isEmpty || record.notes.partial,
                  store.hasCommittedSegments(meetingID: meetingID) else {
                present(.idle, automatic: item.automatic)
                beginNextIfPossible()
                return
            }
            store.markProcessing(meetingID: meetingID, notesPending: true)
            work = Work(
                meetingID: meetingID, tracks: [], reprocessing: false,
                trackIndex: 0, jobID: UUID().uuidString, stage: .notes,
                automatic: item.automatic)
            beginNotes()
            return
        }
        let (tracks, unreadable) = availableTracks(record)
        // A first pass reports a captured track it cannot open the way the
        // engine reports one it rejects. Recreate needs every track (below)
        // and keeps the committed outcomes until its replacement commits.
        var issues: [MeetingSpeaker: MeetingTrackIssue] = [:]
        if !item.reprocessing {
            for speaker in unreadable {
                issues[speaker] = .failed(Self.unreadableTrackMessage)
                store.setTrackIssue(
                    meetingID: meetingID, speaker: speaker, issue: issues[speaker])
            }
        }
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
            jobID: UUID().uuidString, stage: .transcribing, issues: issues)
        beginCurrentTrack()
    }

    /// A transcript whose notes failed stays `ready` with notes pending, and
    /// nothing retried it (3D1AD0F6 waited a month). It gets one automatic
    /// attempt, ever: the marker is spent in SQLite before the attempt, so
    /// neither a failure nor a relaunch can loop on a transcript that breaks
    /// the notes model. The attempt runs without the HUD.
    private func requeueStalledNotes() {
        var claimed = 0
        for record in store.stalledNotes()
        where !isQueued(record.id) && !unsavedOutcomes.contains(record.id) {
            guard claimed < Self.automaticNotesRetriesPerReady else { break }
            // Queue only a durable claim: an unsaved one would repeat the
            // retry on every relaunch.
            guard store.claimNotesAutoRetry(meetingID: record.id) else {
                veloraLog(
                    "Velora: meeting \(record.id) automatic notes retry could not be claimed")
                continue
            }
            claimed += 1
            queued.append(QueueItem(
                meetingID: record.id, reprocessing: false, notesOnly: true,
                automatic: true))
        }
    }

    /// Nobody asked for an automatic job, so it never takes the HUD: its
    /// progress and failure show only on the meeting's row.
    private func present(_ newState: State, automatic: Bool) {
        guard !automatic else { return }
        state = newState
    }

    /// Ends a job whose notes are saved on the row.
    private func notesSaved(_ work: Work) {
        let meetingID = work.meetingID
        engineRestartAttempts.removeValue(forKey: meetingID)
        audioLoadRetries.removeValue(forKey: meetingID)
        notesSaveRetried.remove(meetingID)
        self.work = nil
        present(.idle, automatic: work.automatic)
        notifyChanged()
        // An automatic retry runs unasked (launch, engine ready): its
        // notes land on the row without opening a window.
        if !work.automatic {
            onNotesReady?(meetingID)
        }
        beginNextIfPossible()
    }

    /// SQLite refused to save generated notes (disk full, a lock held past
    /// the busy timeout). The same notes are written again shortly; then
    /// they are generated once more; a refusal after that is a notes
    /// failure the row keeps, with Retry Notes.
    ///
    ///     refused ─► wait 1 s, write the same notes ─► saved
    ///                  └ refused ─► generate again (once) ─► refused
    ///                                 ─► wait 1 s, write ─► refused ─► failed
    private func notesNotSaved(_ work: Work, notes: MeetingNotes) {
        let meetingID = work.meetingID
        if !work.notesWriteRetried {
            var retrying = work
            retrying.notesWriteRetried = true
            self.work = retrying
            veloraLog("Velora: meeting \(meetingID) notes could not be saved; writing them again")
            let jobID = work.jobID
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.notesSaveRetryDelay
            ) { [weak self] in
                // Cancel, delete or an engine restart replaced the job.
                guard let self, let current = self.work, current.jobID == jobID else {
                    return
                }
                if self.store.complete(meetingID: meetingID, notes: notes) {
                    self.notesSaved(current)
                } else {
                    self.notesNotSaved(current, notes: notes)
                }
            }
            return
        }
        guard !notesSaveRetried.contains(meetingID) else {
            notesSaveRetried.remove(meetingID)
            failActive("Meeting notes could not be saved")
            return
        }
        notesSaveRetried.insert(meetingID)
        veloraLog("Velora: meeting \(meetingID) notes could not be saved; generating them again")
        self.work = nil
        queued.insert(
            QueueItem(
                meetingID: meetingID, reprocessing: false, notesOnly: true,
                automatic: work.automatic),
            at: 0)
        beginNextIfPossible()
    }

    /// A silent track has no speech, so lines an older build committed for
    /// it are Whisper hallucinations ("Thank you.") that would reach the
    /// notes. Drop them before the next track or the notes start.
    private func dropTrackLines(_ work: Work) {
        guard work.tracks.indices.contains(work.trackIndex) else { return }
        let remote = work.tracks[work.trackIndex].speaker.isRemote
        if work.reprocessing {
            store.deleteReprocessSegments(meetingID: work.meetingID, remoteTrack: remote)
        } else {
            store.deleteSegments(meetingID: work.meetingID, remoteTrack: remote)
        }
    }

    /// Records how the current track ended, then starts the next track or,
    /// after the last one, the notes. A first pass persists each outcome at
    /// once; Recreate keeps them until its replacement commits.
    private func finishTrack(_ finished: Work, issue: MeetingTrackIssue?) {
        var work = finished
        guard work.tracks.indices.contains(work.trackIndex) else { return }
        let speaker = work.tracks[work.trackIndex].speaker
        work.issues[speaker] = issue
        if !work.reprocessing {
            store.setTrackIssue(
                meetingID: work.meetingID, speaker: speaker, issue: issue)
        }
        work.trackIndex += 1
        self.work = work
        if work.trackIndex < work.tracks.count {
            beginCurrentTrack()
        } else {
            beginNotes()
        }
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
               work.issues[$0.speaker]?.holdsNoSpeech != true
                   && !store.hasReprocessSegments(
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
        guard !transcript.isEmpty else {
            // Every track was silent or failed. Name the first failure when
            // there is one, including a track never sent to the engine: "no
            // speech" would hide a rejected or unreadable file.
            let firstFailure = [MeetingSpeaker.me, .them].lazy.compactMap { speaker -> String? in
                guard case .failed(let message) = work.issues[speaker] else {
                    return nil
                }
                return message
            }.first
            failActive(firstFailure ?? "No speech was found in the recording")
            return
        }
        work.jobID = UUID().uuidString
        work.stage = .notes
        self.work = work
        if !work.reprocessing {
            // This write is the crash boundary: after the transcript exists,
            // relaunch must regenerate notes directly even if the process dies
            // before the engine replies.
            store.markProcessing(meetingID: work.meetingID, notesPending: true)
        }
        present(
            .processing(
                meetingID: work.meetingID, label: "Creating notes…", fraction: 0.75),
            automatic: work.automatic)
        var message: [String: Any] = [
            "cmd": "meeting_notes", "id": work.jobID,
            "meeting_id": work.meetingID, "transcript": transcript,
        ]
        let custom = notesPrompt().trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { message["prompt"] = custom }
        sendToEngine(message)
    }

    private func failActive(_ message: String, code: String? = nil) {
        guard let active = work else { return }
        let meetingID = active.meetingID
        if code == "busy" {
            requeueActive(
                active, label: "Waiting for foreground work…",
                after: Self.busyRetryDelay)
            return
        }
        // A file the engine could not read this time gets a few more
        // tries; past the cap the job fails below, so the row keeps Retry
        // and the track is never skipped.
        if code == Self.audioLoadFailedCode {
            let retries = audioLoadRetries[meetingID, default: 0]
            if retries < Self.audioLoadRetryLimit {
                audioLoadRetries[meetingID] = retries + 1
                veloraLog(
                    "Velora: meeting \(meetingID) audio could not be read "
                    + "(\(message)); retry \(retries + 1) of \(Self.audioLoadRetryLimit)")
                requeueActive(
                    active, label: "Waiting to read the meeting audio again…",
                    after: Self.audioLoadRetryDelay)
                return
            }
        }
        audioLoadRetries.removeValue(forKey: meetingID)
        let reprocessing = active.reprocessing
        persistFailure(
            meetingID: meetingID, reprocessing: reprocessing,
            notesOnly: active.stage == .notes && !reprocessing,
            message: message)
        engineRestartAttempts.removeValue(forKey: meetingID)
        work = nil
        present(.failed(meetingID: meetingID, message: message), automatic: active.automatic)
        notifyChanged()
        beginNextIfPossible()
    }

    /// Puts the active job back at the head of the queue at its current
    /// stage, to start again no earlier than `delay` from now
    /// (`beginNextIfPossible` holds it). The row stays processing, so
    /// Cancel still reaches it while it waits.
    private func requeueActive(
        _ active: Work, label: String, after delay: TimeInterval
    ) {
        let meetingID = active.meetingID
        let reprocessing = active.reprocessing
        let notesOnly = active.stage == .notes && !reprocessing
        work = nil
        if !isQueued(meetingID) {
            queued.insert(
                QueueItem(
                    meetingID: meetingID, reprocessing: reprocessing,
                    notesOnly: notesOnly, automatic: active.automatic,
                    notBefore: now() + delay),
                at: 0)
        }
        present(
            .processing(meetingID: meetingID, label: label, fraction: 0),
            automatic: active.automatic)
        beginNextIfPossible()
    }

    private func matches(id: String?, meetingID: String, work: Work) -> Bool {
        id == work.jobID && meetingID == work.meetingID
    }

    private func trackBase(_ work: Work) -> Double {
        Double(work.trackIndex) / Double(max(1, work.tracks.count)) * 0.75
    }

    /// The captured tracks the engine can decode, and the captured ones it
    /// cannot (missing, unreadable, or an unsupported format).
    private func availableTracks(
        _ record: MeetingRecord
    ) -> (usable: [Track], unreadable: [MeetingSpeaker]) {
        var usable: [Track] = []
        var unreadable: [MeetingSpeaker] = []
        for (speaker, relative) in [
            (MeetingSpeaker.me, record.micPath), (.them, record.systemPath),
        ] {
            guard let relative else { continue }
            guard let url = store.audioURL(relativePath: relative),
                  store.hasUsableAudio(relativePath: relative) else {
                unreadable.append(speaker)
                continue
            }
            usable.append(Track(speaker: speaker, path: url.path))
        }
        return (usable, unreadable)
    }

    private func hasRecoverableAudio(_ record: MeetingRecord) -> Bool {
        store.hasAnyUsableAudio(for: record)
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

    /// Saves a job's failure on its row. When SQLite refuses (every write
    /// failing), the row stays processing, so the meeting is held in
    /// `unsavedOutcomes`: this run does not restart it on its own, and
    /// Retry in the pane stays the way out.
    private func persistFailure(
        meetingID: String, reprocessing: Bool, notesOnly: Bool = false,
        message: String
    ) {
        veloraLog(
            "Velora: meeting \(meetingID) processing failed "
            + "(\(reprocessing ? "recreate" : notesOnly ? "notes" : "transcription")): \(message)")
        let saved: Bool
        if reprocessing {
            saved = store.markReprocessFailed(meetingID: meetingID, error: message)
        } else if notesOnly {
            saved = store.markNotesFailed(meetingID: meetingID, error: message)
        } else {
            saved = store.markFailed(meetingID: meetingID, error: message)
        }
        guard !saved else { return }
        veloraLog(
            "Velora: meeting \(meetingID) failure could not be saved; "
            + "it will not restart in this run")
        unsavedOutcomes.insert(meetingID)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .veloraMeetingsChanged, object: nil)
    }
}
