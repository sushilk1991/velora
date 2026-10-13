import Foundation

/// Engine events the Settings/History UI observes out-of-band from the
/// dictation flow (which keeps its own delegate routing untouched).
extension Notification.Name {
    /// A `status` reply arrived. `userInfo["payload"]` is the raw `[String: Any]`
    /// (carries `models`, `save_audio`, `audio_retention_days`, `language`, …).
    static let veloraEngineStatus = Notification.Name("VeloraEngineStatus")
    /// A `reprocessed` reply arrived. `object` is the `EngineEvent.reprocessed`.
    static let veloraEngineReprocessed = Notification.Name("VeloraEngineReprocessed")
    /// First-run setup progress changed. `userInfo["status"]` is the display
    /// string ("Downloading the speech model (1.6 GB): 42%") and
    /// `userInfo["fraction"]` is a typed 0…1 value when measurable. Both are
    /// absent when no phase is active. Drives onboarding and the menubar line.
    static let veloraEngineLoading = Notification.Name("VeloraEngineLoading")
    /// All startup model work finished. `userInfo["complete"]` is a Bool.
    /// Retained for setup status; speech readiness alone gates dictation.
    static let veloraEngineSetupChanged = Notification.Name("VeloraEngineSetupChanged")
    /// The supervisor's `state` changed. `object` is the supervisor; read
    /// its `state`. Posted on main, after the delegate hears it. A drop
    /// from ready (a crash) posts nothing else, so a status line that
    /// shows "Ready" needs this to leave it.
    static let veloraEngineStateChanged = Notification.Name("VeloraEngineStateChanged")
}

/// Observes supervisor health for UI (menubar state) and dictation gating.
protocol EngineSupervisorDelegate: AnyObject {
    func engineSupervisor(_ supervisor: EngineSupervisor, didChangeState state: EngineSupervisor.State)
    func engineSupervisor(_ supervisor: EngineSupervisor, didReceive event: EngineEvent)
}

/// Spawns and babysits the Python inference engine
/// (`uv run --project <engine dir> velora-engine`, engine dir resolved by
/// `ResourceLocator.locateEngine()`), owns the socket client, and restarts
/// the engine with exponential backoff when it crashes.
///
/// If the engine project or `uv` cannot be found, the app stays alive in a
/// degraded state and keeps probing the socket — an externally launched
/// engine (e.g. started by a developer in a terminal) is picked up
/// automatically.
final class EngineSupervisor: NSObject, EngineClientDelegate {
    private static let engineLogBytes = 5_000_000

    /// Fixed byte chunks keep both disk retention and pipe memory bounded.
    /// child -> nonblocking pipe -> serial writer -> engine.log / engine.log.1
    private final class OutputLog {
        final class Capture {
            let pipe = Pipe()
            var finished = false
        }

        private static let readBytes = 32_768
        private enum UTF8 {
            static let scalarBytes = 4
            static let continuationMask: UInt8 = 0xC0
            static let continuation: UInt8 = 0x80
        }
        private let lock = NSLock()
        private let url: URL
        private let previous: URL
        private let limit: Int
        private var handle: FileHandle?
        private var size = 0

        init(url: URL, limit: Int) {
            self.url = url
            self.previous = url.appendingPathExtension("1")
            self.limit = max(UTF8.scalarBytes, limit)
            // Upgrade existing append-only logs without retaining oversized files.
            trim(url)
            trim(previous)
            open()
        }

        deinit { try? handle?.close() }

        // The reader writes directly: a verbose child cannot grow a queued log backlog.
        func attach(to process: Process) -> Capture {
            let capture = Capture()
            let reader = capture.pipe.fileHandleForReading
            let descriptor = reader.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            reader.readabilityHandler = { [weak self, weak capture] _ in
                guard let self, let capture else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.drain(capture)
            }
            process.standardOutput = capture.pipe
            process.standardError = capture.pipe
            return capture
        }

        // Exit/quit drains the already-written tail before the reader closes.
        func finish(_ capture: Capture) {
            lock.lock()
            defer { lock.unlock() }
            guard !capture.finished else { return }
            capture.pipe.fileHandleForReading.readabilityHandler = nil
            drain(capture)
            capture.finished = true
            try? capture.pipe.fileHandleForReading.close()
            try? capture.pipe.fileHandleForWriting.close()
        }

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            write(data)
        }

        private func drain(_ capture: Capture) {
            guard !capture.finished else { return }
            let reader = capture.pipe.fileHandleForReading
            var bytes = [UInt8](repeating: 0, count: Self.readBytes)
            while true {
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    write(Data(bytes.prefix(count)))
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                if count == 0 { reader.readabilityHandler = nil }
                return
            }
        }

        private func open() {
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            size = Int((try? handle?.seekToEnd()) ?? 0)
        }

        private func write(_ data: Data) {
            // Split large writes at the byte cap; a single long line stays bounded.
            var offset = 0
            while offset < data.count {
                if size >= limit {
                    rotate()
                }
                guard let handle, size < limit else { return }
                let count = min(limit - size, data.count - offset)
                do {
                    try handle.write(contentsOf: data.subdata(in: offset..<(offset + count)))
                } catch {
                    return
                }
                size += count
                offset += count
            }
        }

        private func rotate() {
            // A scalar split at the byte cap moves whole to the new file.
            // For example, trailing C3 moves before its next A9 byte (é).
            let carry = scalarCarry()
            if !carry.isEmpty {
                try? handle?.truncate(atOffset: UInt64(size - carry.count))
            }
            try? handle?.close()
            handle = nil
            let manager = FileManager.default
            try? manager.removeItem(at: previous)
            do {
                try manager.moveItem(at: url, to: previous)
            } catch {
                // Still cap the current file if preserving its predecessor fails.
                try? Data().write(to: url)
            }
            open()
            guard !carry.isEmpty, let handle, size + carry.count <= limit else { return }
            do {
                try handle.write(contentsOf: carry)
                size += carry.count
            } catch {
                return
            }
        }

        // Inspect at most one scalar; pipe/read boundaries need no line buffer.
        private func scalarCarry() -> Data {
            guard size > 0, let reader = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? reader.close() }
            let count = min(size, UTF8.scalarBytes)
            try? reader.seek(toOffset: UInt64(size - count))
            guard let tail = try? reader.read(upToCount: count), !tail.isEmpty else { return Data() }
            var lead = tail.count - 1
            while lead > 0 && Self.isContinuation(tail[lead]) {
                lead -= 1
            }
            let expected = (~tail[lead]).leadingZeroBitCount
            guard expected > 1, expected <= UTF8.scalarBytes,
                  tail.count - lead < expected else { return Data() }
            return tail.subdata(in: lead..<tail.count)
        }

        private static func isContinuation(_ byte: UInt8) -> Bool {
            (byte & UTF8.continuationMask) == UTF8.continuation
        }

        private func trim(_ file: URL) {
            guard let reader = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? reader.close() }
            guard let bytes = try? reader.seekToEnd(), bytes > UInt64(limit) else { return }
            try? reader.seek(toOffset: bytes - UInt64(limit))
            guard let tail = try? reader.read(upToCount: limit) else { return }
            // The retained tail may begin inside a scalar; keep only its full suffix.
            try? Data(tail.drop(while: Self.isContinuation)).write(to: file, options: .atomic)
        }
    }

    /// The Python sidecar uses BSD `EX_TEMPFAIL` after it has already returned
    /// raw text from an unkillable cleanup-model wedge. This is a controlled
    /// replacement request, not a crash that benefits from backoff.
    static let cleanupRestartExitStatus: Int32 = 75

    enum State: Equatable {
        case stopped
        /// Process spawned (or probing an external engine); socket not up yet.
        case launching
        /// Socket connected; waiting for the `ready` handshake.
        case connecting
        /// Ready handshake received — dictation available.
        case ready
        /// Engine unavailable (missing uv/engine dir, or repeated crashes).
        case degraded(String)
    }

    let client = EngineClient()
    let downloads = DownloadState()
    // Late onboarding uses the same supervisor-owned instance, not a second reducer.
    private(set) static var latestDownloads: DownloadState?

    weak var delegate: EngineSupervisorDelegate?

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            NSLog("Velora: engine state → \(state)")
            if state != .ready { setupComplete = false }
            if state == .launching || state == .stopped {
                downloads.disconnect()
            }
            if case .degraded = state { downloads.disconnect() }
            if state == .ready { engineUpdatePending = false }
            quietSince = Date()
            let s = state
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engineSupervisor(self, didChangeState: s)
                NotificationCenter.default.post(name: .veloraEngineStateChanged, object: self)
            }
        }
    }

    /// When the supervisor last reported anything: a state change or a
    /// loading-status change. A start that stays quiet for long enough is
    /// stuck (`EngineStatusLine.startupWait`); every report restarts the
    /// clock, so a respawn after a crash gets a full wait of its own.
    private(set) var quietSince = Date()

    var isReady: Bool { readyOverride?() ?? (state == .ready) }

    /// Legacy setup completion is distinct from loaded-speech readiness.
    private(set) var setupComplete = false {
        didSet {
            guard setupComplete != oldValue else { return }
            Self.lastSetupComplete = setupComplete
            let complete = setupComplete
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .veloraEngineSetupChanged,
                    object: nil,
                    userInfo: ["complete": complete])
            }
        }
    }

    /// Human-readable first-run setup status ("Downloading the speech model
    /// (1.6 GB): 42%"), nil when nothing is loading. Also set app-side for
    /// the pre-socket venv bootstrap, then owned by engine `loading` events.
    private(set) var loadingStatus: String? {
        didSet {
            guard loadingStatus != oldValue else { return }
            quietSince = Date()
            let status = loadingStatus
            Self.lastLoadingStatus = status
            Self.lastLoadingFraction = loadingFraction
            let fraction = loadingFraction
            DispatchQueue.main.async {
                var info: [String: Any] = [:]
                if let status { info["status"] = status }
                if let fraction { info["fraction"] = fraction }
                NotificationCenter.default.post(
                    name: .veloraEngineLoading, object: nil, userInfo: info)
            }
        }
    }

    /// Typed progress for onboarding's determinate progress bar.
    private(set) var loadingFraction: Double?

    /// Latest setup status for late-constructed observers (the onboarding
    /// window seeds from this — notifications only fire on change).
    private(set) static var lastLoadingStatus: String?
    private(set) static var lastLoadingFraction: Double?
    private(set) static var lastSetupComplete = false

    /// Shown while `uv run` re-syncs an updated engine's dependencies.
    static let updatingStatus = "Updating the speech engine…"

    /// Set when this launch copied a new bundled engine over the old one,
    /// until the engine is ready. A respawn after a crash mid-sync shows
    /// the update status again, although the copy is then current.
    private var engineUpdatePending = false

    private var process: Process?
    private var connectTimer: Timer?
    private static let connectInterval: TimeInterval = 0.5
    private var outputLog: OutputLog?
    private var outputCapture: OutputLog.Capture?
    private var restartAttempts = 0
    private(set) var processGeneration = 0
    private(set) var stallRestartCount = 0
    private var isQuitting = false
    private let commandSink: (([String: Any]) -> Void)?
    private let readyOverride: (() -> Bool)?
    private let restartSink: (() -> Void)?
    private let connectAttempt: (() -> Bool)?
    private let connectionIsOpen: (() -> Bool)?

    private init(
        commandSink: (([String: Any]) -> Void)? = nil,
        readyOverride: (() -> Bool)? = nil,
        restartSink: (() -> Void)? = nil,
        connectAttempt: (() -> Bool)? = nil,
        connectionIsOpen: (() -> Bool)? = nil,
        logURL: URL? = nil,
        logMaxBytes: Int = engineLogBytes
    ) {
        self.commandSink = commandSink
        self.readyOverride = readyOverride
        self.restartSink = restartSink
        self.connectAttempt = connectAttempt
        self.connectionIsOpen = connectionIsOpen
        if let logURL {
            outputLog = OutputLog(url: logURL, limit: logMaxBytes)
        }
        super.init()
        downloads.bind { [weak self] command in self?.send(command) }
        Self.latestDownloads = downloads
    }

    override convenience init() {
        self.init(commandSink: nil, readyOverride: nil, restartSink: nil)
    }

    /// Isolated selftest driver; production callers use the empty initializer.
    static func forSelftest(
        commandSink: @escaping ([String: Any]) -> Void,
        readyOverride: @escaping () -> Bool,
        restartSink: @escaping () -> Void,
        connectAttempt: (() -> Bool)? = nil,
        connectionIsOpen: (() -> Bool)? = nil,
        logURL: URL? = nil,
        logMaxBytes: Int = engineLogBytes
    ) -> EngineSupervisor {
        EngineSupervisor(
            commandSink: commandSink, readyOverride: readyOverride,
            restartSink: restartSink, connectAttempt: connectAttempt,
            connectionIsOpen: connectionIsOpen,
            logURL: logURL, logMaxBytes: logMaxBytes)
    }

    /// Replace an unresponsive process while keeping normal crash recovery.
    /// The termination handler owns respawn and its connection handshake.
    func restartForStall() {
        if let restartSink {
            stallRestartCount += 1
            restartSink()
            return
        }
        guard !isQuitting, let proc = process, proc.isRunning else { return }
        stallRestartCount += 1
        client.disconnect(notify: false)
        state = .launching
        stopConnectLoop()
        proc.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak proc] in
            guard let self, let proc, self.process === proc, proc.isRunning else { return }
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    // MARK: - Lifecycle

    /// Starts the engine (spawn + connect loop). Idempotent.
    func start() {
        guard !isQuitting else { return }
        AppConfig.shared.ensureVeloraDirectory()
        AppConfig.shared.writeEngineConfigIfMissing()
        client.delegate = self
        // A fake socket driver exercises supervision without launching Python.
        if connectAttempt == nil {
            spawnEngineProcess()
        }
        beginConnectLoop()
    }

    /// Terminates the engine and stops all supervision. Call on app quit.
    func stop() {
        isQuitting = true
        stopConnectLoop()
        client.disconnect(notify: false)
        terminateProcess()
        if let outputCapture {
            outputLog?.finish(outputCapture)
        }
        outputCapture = nil
        state = .stopped
    }

    /// Sends a command if connected (fire-and-forget; events come back via
    /// the delegate).
    func send(_ command: [String: Any]) {
        if let commandSink {
            commandSink(command)
            return
        }
        client.send(json: command)
    }

    // MARK: - Process management

    private func spawnEngineProcess() {
        guard process == nil || process?.isRunning == false else { return }

        guard let engine = ResourceLocator.locateEngine() else {
            state = .degraded("Engine project not found (set VELORA_ENGINE_DIR)")
            return
        }
        // Prefer the uv shipped in the bundle (self-contained distribution);
        // fall back to a system install for dev/checkout runs.
        guard let uv = ResourceLocator.bundledUV?.path ?? findUV() else {
            state = .degraded("uv not found. Install it from https://astral.sh/uv")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uv)
        // --parent-pid lets the engine self-exit if this app dies without a
        // clean shutdown (crash, force-quit) — no zombie MLX process.
        proc.arguments = [
            "run", "--project", engine.directory.path, "velora-engine",
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        proc.currentDirectoryURL = engine.directory

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.local/bin"]
        env["PATH"] = (extraPaths + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        if engine.isBundled {
            // Keep every uv side effect (interpreter installs, wheel cache)
            // under Application Support — never inside the signed bundle.
            let support = ResourceLocator.applicationSupportDirectory
            env["UV_CACHE_DIR"] = support.appendingPathComponent("uv-cache").path
            env["UV_PYTHON_INSTALL_DIR"] = support.appendingPathComponent("python").path
        }
        proc.environment = env

        // First run on a fresh machine: `uv run` creates the venv and
        // downloads Python deps, which can take minutes. There is no launch
        // deadline — the connect loop polls until the socket appears and uv's
        // progress goes to engine.log — so we just flag it for diagnosability.
        let firstBootstrap = !FileManager.default.fileExists(
            atPath: engine.directory.appendingPathComponent(".venv").path)
        // An update copies the new engine over the old one but keeps its
        // `.venv`, so `uv run` first re-syncs whatever dependencies changed,
        // which can take minutes on a slow network.
        if engine.refreshed {
            engineUpdatePending = true
        }

        // Preserve recent output across crashes without unbounded disk growth.
        let logURL = AppConfig.veloraDirectory.appendingPathComponent("engine.log")
        let log = outputLog ?? OutputLog(url: logURL, limit: Self.engineLogBytes)
        outputLog = log
        let stamp = ISO8601DateFormatter().string(from: Date())
        log.append(Data("\n===== engine spawn \(stamp) =====\n".utf8))
        if firstBootstrap {
            log.append(Data(
                "First-run bootstrap: uv is creating the engine venv and downloading Python dependencies (can take several minutes; progress below).\n".utf8))
        }
        let capture = log.attach(to: proc)
        outputCapture = capture
        announceStartup(firstBootstrap: firstBootstrap)

        proc.terminationHandler = { [weak self] p in
            log.finish(capture)
            DispatchQueue.main.async {
                self?.handleProcessExit(status: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            process = proc
            processGeneration += 1
            state = .launching
            NSLog("Velora: engine spawned (pid %d)", proc.processIdentifier)
        } catch {
            log.finish(capture)
            outputCapture = nil
            state = .degraded("Failed to launch engine: \(error.localizedDescription)")
        }
    }

    /// Pre-socket phase: the engine can't report progress yet, so the app
    /// owns the message until the first `loading`/`ready` event. First-run
    /// setup wins over an update, which a fresh venv makes moot.
    private func announceStartup(firstBootstrap: Bool) {
        if firstBootstrap {
            NSLog("Velora: first-run engine bootstrap — venv creation may take several minutes")
            updateLoading(
                phase: "Setting up the speech engine (one-time, a few minutes)…",
                fraction: nil)
            return
        }

        if engineUpdatePending {
            NSLog("Velora: engine updated — uv may re-sync its dependencies first")
            updateLoading(phase: Self.updatingStatus, fraction: nil)
        }
    }

    /// Test seam for spawn status and process-generation fencing.
    func simulateSpawn(
        firstBootstrap: Bool, engineRefreshed: Bool,
        output: Data? = nil, process: Process? = nil
    ) {
        // Selftest output uses the same writer and pipe as a real engine spawn.
        if let output { outputLog?.append(output) }
        if let process, let outputLog {
            self.process = process
            let capture = outputLog.attach(to: process)
            outputCapture = capture
            process.terminationHandler = { _ in outputLog.finish(capture) }
        }
        if engineRefreshed {
            engineUpdatePending = true
        }
        announceStartup(firstBootstrap: firstBootstrap)
        processGeneration += 1
        state = .launching
    }

    /// Test seam for the state notification sent by a process exit.
    func simulateState(_ newState: State) {
        state = newState
        if newState == .connecting { downloads.connect() }
    }

    private func handleProcessExit(status: Int32) {
        process = nil
        guard !isQuitting else { return }
        // A crash mid-download must not leave a stale "Downloading…" line
        // in the menubar next to the degraded message; the respawned engine
        // re-reports its own progress.
        updateLoading(phase: nil, fraction: nil)
        client.disconnect(notify: false)
        stopConnectLoop()
        restartAttempts = Self.nextRestartAttempt(status: status, current: restartAttempts)
        let delay = Self.restartDelay(status: status, attempt: restartAttempts)
        if delay == 0 {
            state = .launching
            NSLog("Velora: cleanup worker requested immediate engine restart")
        } else {
            state = .degraded("Engine stopped (status \(status)). Restarting in \(Int(delay))s")
            NSLog("Velora: engine exited status=%d, restart in %.0fs", status, delay)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isQuitting else { return }
            self.spawnEngineProcess()
            self.beginConnectLoop()
        }
    }

    static func restartDelay(status: Int32, attempt: Int) -> TimeInterval {
        if status == cleanupRestartExitStatus { return 0 }
        return min(30.0, pow(2.0, Double(min(max(attempt, 1), 5))))
    }

    static func nextRestartAttempt(status: Int32, current: Int) -> Int {
        status == cleanupRestartExitStatus ? current : current + 1
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else { process = nil; return }
        proc.terminationHandler = nil
        proc.terminate()  // SIGTERM
        // Called from applicationWillTerminate: the app exits as soon as we
        // return, so an async SIGKILL fallback would never fire. Block briefly
        // for a graceful exit, then escalate synchronously.
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)  // 50 ms poll
        }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        proc.waitUntilExit()
        process = nil
    }

    private func findUV() -> String? {
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(NSHomeDirectory())/.local/bin/uv",
            "\(NSHomeDirectory())/.cargo/bin/uv",
            "/usr/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Updates the display string and typed progress as one logical snapshot.
    /// The cache-size fraction is only an estimate, so 100% remains reserved
    /// for the explicit setup-complete event.
    private func updateLoading(phase: String?, fraction: Double?) {
        let normalized = fraction.map { min(0.99, max(0, $0)) }
        loadingFraction = normalized
        // Keep the late-observer snapshot exact even when the rounded display
        // string stays on the same whole percentage.
        Self.lastLoadingFraction = normalized
        guard let phase else {
            loadingStatus = nil
            return
        }
        if let normalized {
            loadingStatus = "\(phase): \(min(99, Int((normalized * 100).rounded())))%"
        } else {
            loadingStatus = phase
        }
    }

    // MARK: - Socket connect loop

    private func beginConnectLoop() {
        guard !isQuitting else { return }
        stopConnectLoop()
        guard !(connectionIsOpen?() ?? client.isConnected) else { return }
        let timer = Timer(timeInterval: Self.connectInterval, repeats: true) { [weak self] _ in
            self?.attemptConnect()
        }
        RunLoop.main.add(timer, forMode: .common)
        connectTimer = timer
        attemptConnect()
    }

    // Connected sockets report EOF themselves; polling adds no health signal.
    private func stopConnectLoop() {
        connectTimer?.invalidate()
        connectTimer = nil
    }

    private func attemptConnect() {
        guard !isQuitting, !(connectionIsOpen?() ?? client.isConnected) else { return }
        if connectAttempt?() ?? client.connect(path: AppConfig.socketPath) {
            stopConnectLoop()
            state = .connecting
            downloads.connect()
            client.send(json: ["cmd": "ping"])
        }
    }

    // MARK: - EngineClientDelegate

    func engineClient(_ client: EngineClient, didReceive event: EngineEvent) {
        switch event {
        case .ready(let setupIsComplete, let activeSTTModel):
            downloads.readiness(speech: true, writing: nil)
            if state != .ready {
                restartAttempts = 0
                state = .ready
            }
            if let activeSTTModel, !activeSTTModel.isEmpty,
               activeSTTModel != AppConfig.shared.sttModel {
                // The engine can fall back from an experimental backend after
                // a load failure. Persist the backend it actually proved so
                // settings.json does not request the broken model next launch.
                AppConfig.shared.sttModel = activeSTTModel
                veloraLog("Velora: reconciled speech model to engine-ready backend \(activeSTTModel)")
            }
            // Ready ends the pre-dictation setup phases; the post-ready
            // writing-model download re-sets the status via .loading events.
            if loadingStatus != nil {
                updateLoading(phase: nil, fraction: nil)
            }
            if setupIsComplete { setupComplete = true }
        case .pong:
            break
        case .downloadStatus(let snapshot):
            if downloads.apply(snapshot) {
                state = downloads.speechReady ? .ready : .connecting
            }
        case .modelSet(let model, let kind, let requestID):
            downloads.accept(model: model, kind: kind, requestID: requestID)
            var acceptance: [String: Any] = ["accepted_model": model, "accepted_kind": kind.rawValue]
            if let requestID { acceptance["accepted_request_id"] = requestID }
            NotificationCenter.default.post(
                name: .veloraEngineStatus, object: nil, userInfo: ["payload": acceptance])
        case .selectionRejected(let model, let kind, let requestID, let message):
            downloads.reject(model: model, kind: kind, requestID: requestID, message: message)
        case .unknown(let payload):
            if payload["event"] as? String == "download_status" { downloads.invalidate() }
        case .loading(let phase, let fraction):
            updateLoading(phase: phase, fraction: fraction)
        case .setupComplete:
            if state == .ready { setupComplete = true }
        case .status(let payload):
            downloads.readiness(speech: payload["stt_ready"] as? Bool,
                                writing: payload["cleanup_loaded"] as? Bool)
            if downloads.speechReady { state = .ready }
            if payload["stt_ready"] as? Bool == false, state == .ready { state = .connecting }
            NotificationCenter.default.post(
                name: .veloraEngineStatus, object: nil, userInfo: ["payload": payload])
        case .reprocessed, .reprocessFailed:
            NotificationCenter.default.post(name: .veloraEngineReprocessed, object: event)
        default:
            break
        }
        delegate?.engineSupervisor(self, didReceive: event)
    }

    func engineClientDidDisconnect(_ client: EngineClient) {
        guard !isQuitting else { return }
        // An external engine can disappear without a Process termination
        // callback. Replace any frozen download percentage with the truthful
        // reconnect phase; a reconnect replays its current model progress.
        updateLoading(phase: "Reconnecting to the speech engine…", fraction: nil)
        if case .degraded = state {
            // keep degraded message (process exit handler owns the narrative)
        } else {
            state = .launching
        }
        // EOF re-arms polling for external engines as well as owned processes.
        beginConnectLoop()
    }
}
