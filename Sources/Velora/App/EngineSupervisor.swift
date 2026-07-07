import Foundation

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
    weak var delegate: EngineSupervisorDelegate?

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            NSLog("Velora: engine state → \(state)")
            let s = state
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engineSupervisor(self, didChangeState: s)
            }
        }
    }

    var isReady: Bool { state == .ready }

    private var process: Process?
    private var connectTimer: Timer?
    private var restartAttempts = 0
    private var isQuitting = false

    // MARK: - Lifecycle

    /// Starts the engine (spawn + connect loop). Idempotent.
    func start() {
        guard !isQuitting else { return }
        AppConfig.shared.ensureVeloraDirectory()
        AppConfig.shared.writeEngineConfigIfMissing()
        spawnEngineProcess()
        beginConnectLoop()
    }

    /// Terminates the engine and stops all supervision. Call on app quit.
    func stop() {
        isQuitting = true
        connectTimer?.invalidate()
        connectTimer = nil
        client.disconnect(notify: false)
        terminateProcess()
        state = .stopped
    }

    /// Sends a command if connected (fire-and-forget; events come back via
    /// the delegate).
    func send(_ command: [String: Any]) {
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
            state = .degraded("uv not found — install from https://astral.sh/uv")
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

        // Engine logs go to a file so crashes are diagnosable. Append (never
        // truncate) so the evidence from a crash survives the restart spawn.
        let logURL = AppConfig.veloraDirectory.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            let stamp = ISO8601DateFormatter().string(from: Date())
            handle.write(Data("\n===== engine spawn \(stamp) =====\n".utf8))
            if firstBootstrap {
                handle.write(Data(
                    "First-run bootstrap: uv is creating the engine venv and downloading Python dependencies (can take several minutes; progress below).\n".utf8))
            }
            proc.standardOutput = handle
            proc.standardError = handle
        }
        if firstBootstrap {
            NSLog("Velora: first-run engine bootstrap — venv creation may take several minutes")
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.handleProcessExit(status: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            process = proc
            state = .launching
            NSLog("Velora: engine spawned (pid %d)", proc.processIdentifier)
        } catch {
            state = .degraded("Failed to launch engine: \(error.localizedDescription)")
        }
    }

    private func handleProcessExit(status: Int32) {
        process = nil
        guard !isQuitting else { return }
        client.disconnect(notify: false)
        restartAttempts += 1
        let delay = min(30.0, pow(2.0, Double(min(restartAttempts, 5))))
        state = .degraded("Engine exited (status \(status)) — restarting in \(Int(delay))s")
        NSLog("Velora: engine exited status=%d, restart in %.0fs", status, delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isQuitting else { return }
            self.spawnEngineProcess()
        }
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

    // MARK: - Socket connect loop

    private func beginConnectLoop() {
        connectTimer?.invalidate()
        client.delegate = self
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.attemptConnect()
        }
        RunLoop.main.add(timer, forMode: .common)
        connectTimer = timer
        attemptConnect()
    }

    private func attemptConnect() {
        guard !isQuitting, !client.isConnected else { return }
        if client.connect(path: AppConfig.socketPath) {
            state = .connecting
            // Nudge the engine; `pong` doubles as a ready signal for engines
            // that came up before we connected.
            client.send(json: ["cmd": "ping"])
        }
    }

    // MARK: - EngineClientDelegate

    func engineClient(_ client: EngineClient, didReceive event: EngineEvent) {
        switch event {
        case .ready, .pong:
            if state != .ready {
                restartAttempts = 0
                state = .ready
            }
        default:
            break
        }
        delegate?.engineSupervisor(self, didReceive: event)
    }

    func engineClientDidDisconnect(_ client: EngineClient) {
        guard !isQuitting else { return }
        if case .degraded = state {
            // keep degraded message (process exit handler owns the narrative)
        } else {
            state = .launching
        }
        // connect loop keeps running and will re-establish the session
    }
}
