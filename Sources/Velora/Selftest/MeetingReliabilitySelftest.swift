// Meeting reliability (Wave 3: V-23 watchdog, V-24 end hold, V-25 resume
// sidecar). Coordinated hook: Selftest.run() calls MeetingReliabilitySelftest.run().
#if !VELORA_DISTRIBUTION
import AVFoundation
import Foundation

enum MeetingReliabilitySelftest {
    static func run() {
        run(expect: { Selftest.expect($0, $1) })
    }

    static func run(expect: (Bool, String) -> Void) {
        testWatchdogStallRestartBackoff(expect: expect)
        testWatchdogRecovery(expect: expect)
        testWatchdogExhaustion(expect: expect)
        testEndHold(expect: expect)
        testEndHoldCallSwitch(expect: expect)
        testUserStopBypassesHold(expect: expect)
        testEndReasonPersistence(expect: expect)
        testSidecarAtomicRoundTrip(expect: expect)
        testSidecarPendingDiscovery(expect: expect)
        testSidecarReconcileIdempotent(expect: expect)
        testMergeAudioSegments(expect: expect)
    }

    // MARK: - V-23 SystemAudioWatchdog

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static func testWatchdogStallRestartBackoff(
        expect: (Bool, String) -> Void
    ) {
        var watchdog = SystemAudioWatchdog()
        expect(watchdog.state == .healthy, "watchdog starts healthy")
        expect(watchdog.poll(at: t0) == .none,
               "no frames ever seen: nothing to stall yet")
        _ = watchdog.recordFrame(at: t0)
        expect(watchdog.poll(at: t0.addingTimeInterval(4.9)) == .none
               && watchdog.state == .healthy,
               "frames 4.9 s ago are inside the 5 s stall threshold")
        expect(watchdog.poll(at: t0.addingTimeInterval(5), recording: false) == .none
               && watchdog.state == .healthy,
               "not recording: a stall never triggers a restart")
        expect(watchdog.poll(at: t0.addingTimeInterval(5)) == .restart(attempt: 1)
               && watchdog.state == .restarting(attempt: 1),
               "5 s without frames while recording restarts the tap (attempt 1)")
        expect(watchdog.nextRetryAt == t0.addingTimeInterval(6),
               "attempt 1 is judged after its 1 s backoff")
        expect(SystemAudioWatchdog.backoff(forAttempt: 1) == 1
               && SystemAudioWatchdog.backoff(forAttempt: 2) == 2
               && SystemAudioWatchdog.backoff(forAttempt: 3) == 4,
               "backoff doubles per attempt: 1 s, 2 s, 4 s")
        expect(watchdog.poll(at: t0.addingTimeInterval(5.5)) == .none,
               "still inside attempt 1 backoff: no second restart yet")
        expect(watchdog.poll(at: t0.addingTimeInterval(6)) == .restart(attempt: 2)
               && watchdog.nextRetryAt == t0.addingTimeInterval(8),
               "attempt 1 produced no frames: attempt 2 after 2 s backoff")
        expect(watchdog.poll(at: t0.addingTimeInterval(8)) == .restart(attempt: 3)
               && watchdog.nextRetryAt == t0.addingTimeInterval(12),
               "attempt 2 produced no frames: attempt 3 after 4 s backoff")
        expect(watchdog.statusMessage == "Computer audio reconnecting…",
               "restarting surfaces a reconnecting status")
    }

    private static func testWatchdogRecovery(expect: (Bool, String) -> Void) {
        var watchdog = SystemAudioWatchdog()
        _ = watchdog.recordFrame(at: t0)
        _ = watchdog.poll(at: t0.addingTimeInterval(5))
        _ = watchdog.poll(at: t0.addingTimeInterval(6))
        expect(watchdog.state == .restarting(attempt: 2),
               "setup: second restart in flight")
        expect(watchdog.recordFrame(at: t0.addingTimeInterval(7))
               == .reconnected(attemptsUsed: 2),
               "frames resuming mid-restart prove recovery with attempts used")
        expect(watchdog.statusMessage == "Computer audio reconnected",
               "recovery surfaces the reconnected status")
        expect(watchdog.recordFrame(at: t0.addingTimeInterval(7.5)) == .healthy,
               "the next frame settles reconnected back to healthy")
        // A fresh stall after recovery restarts counting from attempt 1.
        expect(watchdog.poll(at: t0.addingTimeInterval(13)) == .restart(attempt: 1),
               "recovery reset the attempt budget for the next stall")
    }

    private static func testWatchdogExhaustion(expect: (Bool, String) -> Void) {
        var watchdog = SystemAudioWatchdog()
        _ = watchdog.recordFrame(at: t0)
        _ = watchdog.poll(at: t0.addingTimeInterval(5))
        _ = watchdog.poll(at: t0.addingTimeInterval(6))
        _ = watchdog.poll(at: t0.addingTimeInterval(8))
        expect(watchdog.poll(at: t0.addingTimeInterval(12)) == .lost
               && watchdog.state == .lost && watchdog.isLost,
               "third failed attempt exhausts restarts: computer audio lost")
        expect(watchdog.statusMessage == "Computer audio lost",
               "lost surfaces the final status")
        expect(watchdog.poll(at: t0.addingTimeInterval(60)) == .none
               && watchdog.handleStall(at: t0.addingTimeInterval(61)) == .none
               && watchdog.state == .lost,
               "lost is terminal: no infinite restart loop")
        expect(watchdog.recordFrame(at: t0.addingTimeInterval(62)) == .lost,
               "even late frames do not resurrect a lost tap")
        watchdog.reset(at: t0.addingTimeInterval(63))
        expect(watchdog.state == .healthy && watchdog.restartAttempt == 0,
               "reset re-arms the watchdog for a new capture")

        // handleStall: the lower layer already proved the stall.
        var forced = SystemAudioWatchdog()
        _ = forced.recordFrame(at: t0)
        expect(forced.handleStall(at: t0.addingTimeInterval(1)) == .restart(attempt: 1),
               "a proven stall skips the timestamp wait")
        expect(forced.handleStall(at: t0.addingTimeInterval(1.5)) == .none,
               "repeated stall reports inside backoff do not burn attempts")
        forced.noteRestartFailed(at: t0.addingTimeInterval(2))
        expect(forced.nextRetryAt == t0.addingTimeInterval(3),
               "a restart that failed to start re-arms its own backoff")
        var terminal = SystemAudioWatchdog()
        terminal.markLost()
        expect(terminal.state == .lost, "markLost is an immediate terminal failure")
    }

    // MARK: - V-24 MeetingEndWatch hold / call switch / end reason

    private static func testEndHold(expect: (Bool, String) -> Void) {
        var watch = MeetingEndWatch(
            holdThreshold: MeetingEndWatch.defaultHoldThreshold, confirmed: true,
            boundCallID: "native:Zoom")
        expect(MeetingEndWatch.defaultHoldThreshold == 3,
               "held end confirmation defaults to 3 absent polls")
        expect(watch.observe(presence: .absent) == .holding(absentPolls: 1, needed: 3)
               && watch.isHoldingEnd,
               "first absent poll holds the end instead of firing it")
        expect(watch.observe(presence: .absent) == .holding(absentPolls: 2, needed: 3),
               "second absent poll still holds")
        expect(watch.observe(presence: .absent) == .ended && !watch.isHoldingEnd,
               "third consecutive absent poll confirms the end")

        // Returning presence cancels the hold cleanly.
        var returning = MeetingEndWatch(
            holdThreshold: 3, confirmed: true, boundCallID: "native:Zoom")
        _ = returning.observe(presence: .absent)
        _ = returning.observe(presence: .absent)
        expect(returning.observe(presence: .present(callID: "native:Zoom"))
               == .holdCancelled && !returning.isHoldingEnd
               && returning.absentPollCount == 0,
               "the bound call returning cancels the hold")
        expect(returning.observe(presence: .absent)
               == .holding(absentPolls: 1, needed: 3),
               "after cancellation the absence streak restarts from zero")

        // An unconfirmed watch (manual recording) never holds or ends.
        var manual = MeetingEndWatch(holdThreshold: 3)
        expect(manual.observe(presence: .absent) == .none
               && manual.observe(presence: .absent) == .none
               && manual.observe(presence: .absent) == .none,
               "no confirmed call: absence can never end the meeting")

        // Legacy observe(present:) contract is unchanged alongside the hold API.
        var legacy = MeetingEndWatch(threshold: 2)
        _ = legacy.observe(present: true)
        expect(legacy.observe(present: false) == .none
               && legacy.observe(present: false) == .ended,
               "legacy threshold-2 observe(present:) still fires on poll 2")
    }

    private static func testEndHoldCallSwitch(expect: (Bool, String) -> Void) {
        var watch = MeetingEndWatch(
            holdThreshold: 3, confirmed: true, boundCallID: "native:Zoom")
        _ = watch.observe(presence: .absent)
        _ = watch.observe(presence: .absent)
        expect(watch.observe(presence: .differentCall(callID: "native:Teams"))
               == .callSwitched && !watch.isHoldingEnd
               && watch.boundCallID == "native:Teams",
               "a different call while holding cancels the hold and rebinds")
        // The new call dropping needs a full fresh streak.
        expect(watch.observe(presence: .absent) == .holding(absentPolls: 1, needed: 3)
               && watch.observe(presence: .absent) == .holding(absentPolls: 2, needed: 3)
               && watch.observe(presence: .absent) == .ended,
               "the rebound call ends only after its own 3 absent polls")

        // Presence carrying a different identity is also a switch.
        var viaPresent = MeetingEndWatch(
            holdThreshold: 3, confirmed: true, boundCallID: "native:Zoom")
        _ = viaPresent.observe(presence: .absent)
        expect(viaPresent.observe(presence: .present(callID: "browser:com.google.Chrome"))
               == .callSwitched,
               "present-with-different-id is reported as a call switch")
        expect(MeetingWatchScope.native("Zoom").callKey == "native:Zoom"
               && MeetingWatchScope.browser("com.google.Chrome").callKey
                    == "browser:com.google.Chrome"
               && MeetingWatchScope.unknown.callKey == nil,
               "call keys distinguish transports; unknown has no identity")
    }

    private static func testUserStopBypassesHold(expect: (Bool, String) -> Void) {
        var watch = MeetingEndWatch(
            holdThreshold: 3, confirmed: true, boundCallID: "native:Zoom")
        _ = watch.observe(presence: .absent)
        expect(watch.isHoldingEnd, "setup: an end hold is pending")
        expect(watch.confirmUserStop() == .user
               && !watch.isHoldingEnd && !watch.confirmed,
               "user stop wins immediately without waiting out the hold")
        expect(watch.observe(presence: .absent) == .none,
               "a watch settled by user stop cannot fire afterwards")
    }

    private static func testEndReasonPersistence(expect: (Bool, String) -> Void) {
        for reason in [MeetingEndReason.user, .mic, .calendar, .durationCap,
                       .appTermination, .error] {
            expect(MeetingEndReason(rawValue: reason.rawValue) == reason,
                   "end reason \(reason.rawValue) round-trips its raw value")
        }
        withTempDirectory { dir in
            let dbURL = dir.appendingPathComponent("meetings.sqlite3")
            let files = dir.appendingPathComponent("files", isDirectory: true)
            let id = UUID().uuidString
            func makeRecord(endReason: MeetingEndReason?) -> MeetingRecord {
                MeetingRecord(
                    id: id, title: "Reliability",
                    startedAt: t0, endedAt: t0.addingTimeInterval(600),
                    status: .processing, micPath: "\(id)/me.caf",
                    endReason: endReason)
            }
            do {
                let store = MeetingStore(url: dbURL, filesRoot: files)
                store.insertProcessing(makeRecord(endReason: .mic))
                expect(store.record(id: id)?.endReason == .mic,
                       "insertProcessing persists the end reason")
                expect(store.setEndReason(meetingID: id, reason: .durationCap)
                       && store.record(id: id)?.endReason == .durationCap,
                       "setEndReason updates the stored reason in place")
            }
            // Reopening the same database reruns the idempotent
            // ADD COLUMN migration and keeps the value.
            let reopened = MeetingStore(url: dbURL, filesRoot: files)
            expect(reopened.record(id: id)?.endReason == .durationCap,
                   "end reason survives a store reopen (migration is idempotent)")
            expect(reopened.record(id: id)?.title == "Reliability",
                   "reopened store still reads the migrated row")
        }
    }

    // MARK: - V-25 MeetingResumeSidecar

    private static func sampleSidecar(
        meetingID: String = "11111111-1111-1111-1111-111111111111",
        micFrames: Int64 = 480_000, systemFrames: Int64 = 480_000,
        micDurationS: Double = 10, systemDurationS: Double = 10
    ) -> MeetingResumeSidecar {
        MeetingResumeSidecar(
            meetingID: meetingID, title: "Crash Test",
            startedAt: t0, updatedAt: t0.addingTimeInterval(10),
            micTrack: "me.caf", systemTrack: "them.caf",
            micDurationS: micDurationS, systemDurationS: systemDurationS,
            micFrames: micFrames, systemFrames: systemFrames,
            segmentCount: 1, endReason: nil)
    }

    private static func testSidecarAtomicRoundTrip(expect: (Bool, String) -> Void) {
        withTempDirectory { dir in
            let meetingDir = dir.appendingPathComponent("m1", isDirectory: true)
            let sidecar = sampleSidecar()
            do {
                try MeetingResumeSidecarStore.write(sidecar, to: meetingDir)
            } catch {
                expect(false, "sidecar write threw: \(error.localizedDescription)")
                return
            }
            let url = MeetingResumeSidecarStore.url(in: meetingDir)
            expect(url.lastPathComponent == "resume.json"
                   && FileManager.default.fileExists(atPath: url.path),
                   "sidecar lands at <meeting-dir>/resume.json")
            let permissions = (try? FileManager.default.attributesOfItem(
                atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            expect(permissions.map { $0 & 0o777 } == 0o600,
                   "sidecar is owner-only (0600)")
            let children = (try? FileManager.default.contentsOfDirectory(
                atPath: meetingDir.path)) ?? []
            expect(children == ["resume.json"],
                   "atomic write leaves no temp residue behind")
            let read = MeetingResumeSidecarStore.read(from: meetingDir)
            expect(read == sidecar,
                   "sidecar round-trips every field through JSON")
            expect(read?.schemaVersion == MeetingResumeSidecar.currentSchemaVersion
                   && read?.repairedTotalDurationS == 10
                   && read?.repairedEndedAt == t0.addingTimeInterval(10),
                   "repaired duration/ended-at derive from the longer track")

            // Overwriting replaces atomically; removal is clean and idempotent.
            var updated = sidecar
            updated.micFrames = 960_000
            updated.micDurationS = 20
            updated.updatedAt = t0.addingTimeInterval(20)
            try? MeetingResumeSidecarStore.write(updated, to: meetingDir)
            expect(MeetingResumeSidecarStore.read(from: meetingDir)?.micFrames == 960_000,
                   "a later checkpoint replaces the earlier one")
            MeetingResumeSidecarStore.remove(from: meetingDir)
            MeetingResumeSidecarStore.remove(from: meetingDir)
            expect(MeetingResumeSidecarStore.read(from: meetingDir) == nil
                   && !FileManager.default.fileExists(atPath: url.path),
                   "normal finish removes the crash marker (twice is fine)")
        }
    }

    private static func testSidecarPendingDiscovery(expect: (Bool, String) -> Void) {
        withTempDirectory { dir in
            let first = dir.appendingPathComponent("a-meeting", isDirectory: true)
            let second = dir.appendingPathComponent("b-meeting", isDirectory: true)
            let corrupt = dir.appendingPathComponent("c-meeting", isDirectory: true)
            try? MeetingResumeSidecarStore.write(
                sampleSidecar(meetingID: "a"), to: first)
            var later = sampleSidecar(meetingID: "b")
            later.startedAt = t0.addingTimeInterval(3600)
            later.updatedAt = t0.addingTimeInterval(3610)
            try? MeetingResumeSidecarStore.write(later, to: second)
            try? FileManager.default.createDirectory(
                at: corrupt, withIntermediateDirectories: true)
            try? Data("not json".utf8).write(
                to: MeetingResumeSidecarStore.url(in: corrupt))
            try? Data("plain file".utf8).write(
                to: dir.appendingPathComponent("meetings.sqlite3"))
            let pending = MeetingResumeSidecarStore.pendingSidecars(in: dir)
            expect(pending.map(\.meetingID) == ["a", "b"],
                   "pending discovery finds interrupted meetings in start order, "
                   + "skipping corrupt sidecars and plain files")
            expect(MeetingResumeSidecarStore.pendingSidecars(
                in: dir.appendingPathComponent("missing", isDirectory: true)).isEmpty,
                   "a missing meetings directory has nothing pending")
        }
    }

    private static func testSidecarReconcileIdempotent(
        expect: (Bool, String) -> Void
    ) {
        let firstHalf = sampleSidecar(
            micFrames: 1_440_000, systemFrames: 1_440_000,
            micDurationS: 30, systemDurationS: 30)
        // The resumed take is a fresh capture of the same meeting whose own
        // totals describe only the second half, checkpointed later.
        var secondHalf = firstHalf
        secondHalf.updatedAt = t0.addingTimeInterval(120)
        secondHalf.micFrames = 1_440_000
        secondHalf.systemFrames = 1_200_000
        secondHalf.micDurationS = 30
        secondHalf.systemDurationS = 25

        let merged = firstHalf.appendingTakeSegment(secondHalf)
        expect(merged.micDurationS == 60 && merged.systemDurationS == 55
               && merged.micFrames == 2_880_000 && merged.segmentCount == 2
               && merged.repairedTotalDurationS == 60
               && merged.repairedEndedAt == t0.addingTimeInterval(60),
               "resuming appends a take: durations and frames add across halves")

        let reconciled = MeetingResumeSidecar.reconcileResume(
            existing: nil, recovered: firstHalf)
        expect(reconciled == firstHalf,
               "first recovery adopts the crashed checkpoint as-is")
        let again = MeetingResumeSidecar.reconcileResume(
            existing: reconciled, recovered: firstHalf)
        expect(again == reconciled && again.segmentCount == 1,
               "recovering the same crash twice changes nothing (no double-merge)")
        let grew = MeetingResumeSidecar.reconcileResume(
            existing: merged, recovered: secondHalf)
        expect(grew == merged,
               "a take already merged (frames covered) is not merged again")
        var otherMeeting = secondHalf
        otherMeeting.meetingID = "22222222-2222-2222-2222-222222222222"
        expect(MeetingResumeSidecar.reconcileResume(
                existing: firstHalf, recovered: otherMeeting) == firstHalf,
               "reconciliation never merges across different meetings")

        var corrupt = firstHalf
        corrupt.micDurationS = -5
        corrupt.systemFrames = -1
        corrupt.segmentCount = 0
        corrupt.updatedAt = t0.addingTimeInterval(-60)
        let repaired = corrupt.repaired()
        expect(repaired.micDurationS == 0 && repaired.systemFrames == 0
               && repaired.segmentCount == 1 && repaired.updatedAt == repaired.startedAt
               && repaired.repairedTotalDurationS == 30,
               "repair clamps corrupt values without inventing audio")
    }

    private static func testMergeAudioSegments(expect: (Bool, String) -> Void) {
        withTempDirectory { dir in
            let first = dir.appendingPathComponent("them.caf")
            let second = dir.appendingPathComponent("them.seg1.caf")
            writeCAF(first, frames: 4_800)
            writeCAF(second, frames: 2_400)
            let merged = MeetingAudioCapture.mergeAudioSegments(
                [first, second], into: first)
            let length = (try? AVAudioFile(forReading: first))?.length
            expect(merged && length == 7_200,
                   "watchdog take segments merge into one continuous track")
        }
    }

    // MARK: - Fixtures

    private static func writeCAF(_ url: URL, frames: Int) {
        guard let format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let file = try? AVAudioFile(
                forWriting: url, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.floatChannelData {
            for index in 0..<frames { data[0][index] = 0.25 }
        }
        try? file.write(from: buffer)
    }

    private static func withTempDirectory(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("velora-reliability-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        body(dir)
        try? FileManager.default.removeItem(at: dir)
    }
}
#endif
