#if !VELORA_DISTRIBUTION
import AppKit
import AVFoundation
import Foundation

/// Real bundled-engine integration with file-backed audio and controlled
/// permission/media probes. No fake STT, no real microphone, no global
/// hotkey registration, no external-app insertion, no general pasteboard.
/// Run through scripts/test-sandbox-dictation.py, which adds OS write/read
/// fences as well as this harness's fresh-home gate.
enum DictationE2E {
    static func run(audio: String, report: String) -> Int32 {
        // NSTemporaryDirectory can be too long for Darwin AF_UNIX sockets.
        WindowSnapshot.enterScratchHome(label: "sandbox-e2e",
            temporaryDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (key, value) in [
            "HOME": home.path,
            "VELORA_HOME": home.appendingPathComponent(".velora").path,
            "HF_HOME": home.appendingPathComponent(".cache/huggingface").path,
            "HF_HUB_CACHE": home.appendingPathComponent(".cache/huggingface/hub").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "VELORA_FAKE_STT": "0", "UV_NO_CONFIG": "1",
        ] { setenv(key, value, 1) }
        for key in ["VELORA_ENGINE_DIR", "PYTHONPATH", "VIRTUAL_ENV", "UV_PYTHON"] {
            unsetenv(key)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let driver = Driver(home: home, audio: URL(fileURLWithPath: audio),
                            report: URL(fileURLWithPath: report))
        Task { @MainActor in await driver.run() }
        app.run()
        return 1
    }

    private final class Driver: EngineSupervisorDelegate {
        let home: URL
        let audio: URL
        let report: URL
        let supervisor = EngineSupervisor()
        var controller: DictationController?
        var history: HistoryStore?
        var source: FileMicrophone?
        var status: [String: Any] = [:]
        var statusReplies = 0
        var interruptedAcks: Set<String> = []
        var events: [String] = []
        var checks: [[String: Any]] = []
        let started = Date()
        let pasteboard = NSPasteboard(name: .init("velora.sandbox-e2e.\(UUID().uuidString)"))
        var window: NSWindow?

        init(home: URL, audio: URL, report: URL) {
            self.home = home; self.audio = audio; self.report = report
        }

        func check(_ passed: Bool, _ label: String) throws {
            checks.append(["check": label, "passed": passed])
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            fflush(stdout)
            if !passed { throw NSError(domain: "VeloraSandboxE2E", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: label]) }
        }

        @MainActor
        func wait(_ seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        @MainActor
        func run() async {
            do {
                try check(Bundle.main.bundleURL.pathExtension == "app", "runs inside the signed app bundle")
                let config = AppConfig.shared
                try check(config.sttModel == STTModel.all[0].id && !config.onboardingComplete,
                          "fresh settings, not the installed user's choices")
                try check(history == nil && !FileManager.default.fileExists(atPath:
                    AppConfig.historyDatabaseURL.path), "no existing History database")
                supervisor.delegate = self
                supervisor.onSpawnForSelftest = { [weak self] in self?.publishLease() }
                let onboarding = OnboardingModel()
                onboarding.languageScope = "english"
                onboarding.smartWriting = false
                var committedBeforeStart = false
                onboarding.onSpeechModelChosen = { model in
                    config.sttModel = model
                    committedBeforeStart = config.languageScope == "english" && !config.cleanupEnabled
                    self.supervisor.start()
                }
                onboarding.commitLanguageChoice()
                try check(committedBeforeStart, "language and optional writing committed before engine launch")
                let launched = await wait(900) {
                    if case .degraded = self.supervisor.state { return true }
                    return self.supervisor.isReady
                }
                try check(launched && supervisor.isReady, "fresh bundled engine reaches speech-ready")
                supervisor.send(["cmd": "status"])
                try check(await wait(10) { self.status["stt_model"] != nil }, "real engine reports serving model")
                try check(status["stt_model"] as? String == "ConwayResearch/Underdog-Bark-3.0",
                          "included Bark English is the serving backend")
                try check(status["cleanup_loaded"] as? Bool == false,
                          "declining smart writing does not load the writing model")
                let engine = ResourceLocator.applicationSupportDirectory.appendingPathComponent("engine")
                try check(engine.path.hasPrefix(home.path) && FileManager.default.fileExists(atPath:
                    engine.appendingPathComponent(".venv/pyvenv.cfg").path),
                    "bundled engine bootstrapped a new private venv")
                try check(FileManager.default.fileExists(atPath: configPath("bundled-models/bark-3.0@85db2ad18ab4/model.bark")),
                          "included weights verified and seeded into the fresh model store")

                let history = HistoryStore()
                self.history = history
                let source = try FileMicrophone(url: audio)
                self.source = source
                let media = MediaPlaybackCoordinator(
                    snapshot: { .init(processes: [], playing: []) }, postToggle: { false },
                    schedule: { _, _ in })
                let controller = DictationController(
                    supervisor: supervisor, contextTracker: AppContextTracker(),
                    hud: HUDPanel(pillEnabled: { false }), history: history,
                    sounds: SoundPlayer(cues: []), dictionary: DictionaryRepository(),
                    pasteboard: pasteboard, capture: AudioCapture(source: source),
                    mediaPlayback: media, micAuthorized: { true }, secureInputActive: { false })
                self.controller = controller
                controller.toggleFromHome()
                try await finishTake(controller, source: source)
                try check(await wait(30) { !history.recent(limit: 1).isEmpty && !history.hasPendingWrites },
                          "capture, framed PCM, real STT and finalization persist History")
                let first = history.recent(limit: 1)[0]
                try check(expected(first.final), "recognizer returns the known English speech")
                try check(pasteboard.string(forType: .string) == first.final,
                          "Home dictation delivers final text to the private clipboard")
                try check(first.cleanupApplied == false, "fast dictation did not run AI rewriting")
                try check(await wait(10) {
                    first.audioPath.flatMap(AppConfig.archivedAudioURL(name:)).map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } ?? false
                }, "dictation audio is durably archived")

                // Exercise the same own-window insertion path as onboarding.
                let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
                let window = NSWindow(contentRect: editor.frame,
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "Velora Sandbox Dictation Test"
                window.contentView = editor
                self.window = window
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(editor)
                try check(await wait(5) { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() },
                          "only the sandbox app owns the insertion target")
                controller.toggleFromMenu()
                try await finishTake(controller, source: source)
                try check(await wait(30) { self.expected(editor.string) },
                          "real final event inserts into the sandbox's native text field")
                try check(await wait(10) { history.recent(limit: 10).count == 2 && !history.hasPendingWrites },
                          "own-window insertion records exactly one additional History row")

                // Kill only this harness's child engine while it owns a take.
                let sentinel = "RECOVERY MUST NOT AUTO-INSERT"
                pasteboard.clearContents(); pasteboard.setString(sentinel, forType: .string)
                editor.string = sentinel
                window.makeFirstResponder(editor)
                controller.toggleFromMenu()
                try check(await wait(10) { source.finished && controller.isRecording }, "recovery take captured real PCM")
                try check(await wait(10) { self.activeSpoolExists() }, "recording spool exists before the forced crash")
                try check(supervisor.crashOwnedProcessForSelftest(),
                          "forced crash targets only the supervisor-owned engine process group")
                try check(await wait(120) {
                    history.recent(limit: 10).count == 3
                        && history.recent(limit: 10).allSatisfy { self.expected($0.final) }
                        && !history.hasPendingWrites
                }, "engine restarts and reprocesses interrupted audio into durable History")
                try check(editor.string == sentinel && pasteboard.string(forType: .string) == sentinel,
                          "crash recovery leaves the native field and private clipboard unchanged")
                try check(await wait(10) { self.interruptedAcks.count == 1 && !self.activeSpoolExists() },
                          "recovery acknowledgement removes the retained crash spool")
                try check(retainedSpools().isEmpty, "acknowledged recovery leaves no pending spool on disk")
                let expectedIDs = history.recent(limit: 10).map(\.id).sorted()
                let generation = supervisor.processGeneration
                supervisor.restartForStall()
                try check(await wait(60) {
                    self.supervisor.processGeneration > generation && self.supervisor.isReady
                }, "acknowledged recovery survives another engine restart")
                let replies = statusReplies
                supervisor.send(["cmd": "status"])
                try check(await wait(10) { self.statusReplies > replies },
                          "replacement engine serves requests after recovery acknowledgement")
                // With no retained files before or after restart, _client_ready
                // sees no pending sessions and does not schedule _emit_interrupted.
                // Status proves usability, NOT a barrier for asynchronous recovery.
                try check(retainedSpools().isEmpty, "replacement engine has no retained session to replay")
                try check(expectedIDs.count == 3
                    && HistoryStore().recent(limit: 10).map(\.id).sorted() == expectedIDs
                    && interruptedAcks.count == 1 && !activeSpoolExists()
                    && editor.string == sentinel && pasteboard.string(forType: .string) == sentinel,
                          "normal, inserted and recovered rows survive restart without duplicates or insertion")
                await finish(error: nil)
            } catch { await finish(error: error) }
        }

        func configPath(_ relative: String) -> String {
            AppConfig.veloraDirectory.appendingPathComponent(relative).path
        }
        func expected(_ text: String) -> Bool {
            let value = text.lowercased()
            return value.contains("quick brown fox") && value.contains("lazy dog")
        }
        @MainActor
        func finishTake(_ controller: DictationController, source: FileMicrophone) async throws {
            try check(await wait(15) { source.finished && controller.isRecording }, "audio source and capture conversion finish")
            controller.toggleFromMenu()
            try check(await wait(60) { controller.phase == .idle }, "stop drains capture and receives an authoritative final")
        }
        func retainedSpools() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: AppConfig.audioDirectory.appendingPathComponent(".active"),
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".pcm16.part") }
        }
        func activeSpoolExists() -> Bool {
            let dir = AppConfig.audioDirectory.appendingPathComponent(".active")
            return ((try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.fileSizeKey])) ?? []).contains {
                $0.lastPathComponent.hasSuffix(".pcm16.part")
                    && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            }
        }
        @MainActor
        func finish(error: Error?) async -> Never {
            controller?.cancel()
            supervisor.stop()
            _ = await wait(3) { !FileManager.default.fileExists(atPath: AppConfig.socketPath) }
            window?.close()
            let log = AppConfig.veloraDirectory.appendingPathComponent("engine.log")
            if FileManager.default.fileExists(atPath: log.path) {
                try? FileManager.default.copyItem(at: log,
                    to: report.deletingLastPathComponent().appendingPathComponent("engine.log"))
            }
            let result: [String: Any] = [
                "passed": error == nil, "error": error?.localizedDescription as Any? ?? NSNull(),
                "checks": checks, "elapsed_s": Date().timeIntervalSince(started),
                "serving_model": status["stt_model"] ?? NSNull(),
                "real_stt_exercised": checks.contains {
                    $0["check"] as? String == "recognizer returns the known English speech"
                        && $0["passed"] as? Bool == true
                }, "physical_microphone_tested": false,
                "global_hotkey_tested": false, "external_app_insertion_tested": false,
                "history_rows": history?.recent(limit: 10).count ?? 0,
                "fresh_home": home.path, "events": events,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: report, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
            }
            if let error { print("sandbox-e2e FAILED: \(error.localizedDescription)") }
            else { print("sandbox-e2e OK") }
            exit(error == nil ? 0 : 1)
        }
        func engineSupervisor(_ supervisor: EngineSupervisor, didChangeState state: EngineSupervisor.State) {
            events.append(String(describing: state))
            publishLease()
            controller?.handleEngineStateChange(state)
        }
        func publishLease() {
            let lease: [String: Any] = [
                "owner_pid": getpid(),
                "engine_group": supervisor.ownedProcessGroupForSelftest as Any? ?? NSNull(),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: lease) {
                try? data.write(to: report.deletingLastPathComponent()
                    .appendingPathComponent("owned-process.json"), options: .atomic)
            }
        }
        func engineSupervisor(_ supervisor: EngineSupervisor, didReceive event: EngineEvent) {
            if case .status(let payload) = event {
                statusReplies += 1
                status.merge(payload) { _, new in new }
            }
            if case .interruptedAck(let session) = event { interruptedAcks.insert(session) }
            controller?.handleEngineEvent(event)
        }
    }

    /// Hardware-free input at 10x real time; AudioCapture still performs its
    /// real format conversion, chunking, tail drain and startup checks.
    private final class FileMicrophone: MicrophoneStreamCapturing {
        let url: URL
        var finished = false
        private var generation = 0
        private var file: AVAudioFile?
        init(url: URL) throws { self.url = url; _ = try AVAudioFile(forReading: url) }
        func start(persistedUID: String?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
                   onFailure: @escaping (String) -> Void,
                   completion: @escaping (Result<Void, Error>) -> Void) {
            generation += 1
            finished = false
            let token = generation
            do {
                let file = try AVAudioFile(forReading: url)
                self.file = file
                completion(.success(()))
                func feed() {
                    guard self.generation == token else { return }
                    guard file.framePosition < file.length else { self.finished = true; return }
                    let frames = AVAudioFrameCount(min(file.length - file.framePosition,
                        AVAudioFramePosition(file.processingFormat.sampleRate / 10)))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return }
                    do {
                        try file.read(into: buffer)
                        if buffer.frameLength == 0 { self.finished = true; return }
                        onBuffer(buffer)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: feed)
                    } catch { onFailure(error.localizedDescription) }
                }
                DispatchQueue.main.async(execute: feed)
            } catch { completion(.failure(error)) }
        }
        func stop(completion: @escaping () -> Void) {
            generation += 1; file = nil
            completion()
        }
    }
}
#endif
