import Foundation

/// Observes supervisor health for UI (menubar state) and dictation gating.
protocol EngineSupervisorDelegate: AnyObject {
    func engineSupervisor(_ supervisor: EngineSupervisor, didChangeState state: EngineSupervisor.State)
    func engineSupervisor(_ supervisor: EngineSupervisor, didReceive event: EngineEvent)
}

/// Spawns and babysits the Python inference engine
/// (`uv run --project <repo>/engine velora-engine`), owns the socket client,
/// and restarts the engine with exponential backoff when it crashes.
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

        guard let engineDir = ResourceLocator.engineDirectory else {
            state = .degraded("Engine project not found (set VELORA_ENGINE_DIR)")
            return
        }
        guard let uv = findUV() else {
            state = .degraded("uv not found — install from https://astral.sh/uv")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uv)
        proc.arguments = ["run", "--project", engineDir.path, "velora-engine"]
        proc.currentDirectoryURL = engineDir

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.local/bin"]
        env["PATH"] = (extraPaths + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        proc.environment = env

        // Engine logs go to a file so crashes are diagnosable.
        let logURL = AppConfig.veloraDirectory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            proc.standardOutput = handle
            proc.standardError = handle
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
        guard let proc = process, proc.isRunning else { return }
        proc.terminationHandler = nil
        proc.terminate()  // SIGTERM
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
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
