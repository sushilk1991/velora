import Foundation
import Security

struct CuaProcessIdentity: Hashable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    /// PID plus kernel start time prevents force-killing a recycled PID.
    static func capture(pid: pid_t) -> CuaProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return CuaProcessIdentity(
            pid: pid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec)
    }

    var isCurrent: Bool { Self.capture(pid: pid) == self }
}

struct CuaPeerTrustCache {
    private var identities = Set<CuaProcessIdentity>()

    func contains(_ identity: CuaProcessIdentity) -> Bool {
        identities.contains(identity)
    }

    mutating func insert(_ identity: CuaProcessIdentity) {
        identities.insert(identity)
    }

    mutating func removeAll() {
        identities.removeAll()
    }
}

/// Client for the Cua Driver daemon (github.com/trycua — `com.trycua.driver`),
/// an MIT-licensed computer-use daemon the user installs separately. It can
/// observe and address a chosen process and window. Velora talks to it over
/// its unix socket in newline-delimited JSON:
/// `{"method":"call","name":<tool>,"args":{…}}` per request
/// (protocol verified live against driver 0.21.0, 2026-08-23).
///
/// Everything here is transport. What Action Mode may DO with the transport
/// is decided by the same `ActionPlan` validator and `ActionRuntimePolicy`
/// that govern the foreground path — the driver is an actuator, never an
/// authority.
enum CuaDriver {
    private static let exactPartialCode =
        "bring_to_front_exact_window_unverified"
    private static let toolErrorMarker = "_velora_tool_error"
    private static let safeEnvironmentNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL",
        "TMPDIR", "TMP", "TEMP", "LANG",
    ]

    static var appBinaryPath: String {
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
    }

    static func socketPathFits(_ path: String) -> Bool {
        var address = sockaddr_un()
        return withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.utf8.count < MemoryLayout.size(ofValue: pointer.pointee)
        }
    }

    /// Builds the child's entire environment. Ambient driver authority and
    /// loader hooks never cross the embedding boundary.
    static func safeEnvironment(
        from inherited: [String: String], bundleID: String?, hostPID: pid_t
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for (name, value) in inherited {
            guard safeEnvironmentNames.contains(name)
                    || name.hasPrefix("LC_") else { continue }
            environment[name] = value
        }
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = bundleID
            ?? "com.sushil.velora"
        environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "false"
        environment["CUA_DRIVER_RS_UPDATE_CHECK"] = "false"
        environment["CUA_DRIVER_EMBEDDED_HOST_PID"] = String(hostPID)
        return environment
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: appBinaryPath)
    }

    /// The driver's Developer ID identity. `/Applications` is writable by
    /// admin users without authentication, and a spawned child inherits
    /// Velora's TCC responsibility — so an unverified binary at this path
    /// would run under Velora's Accessibility grant with no prompt (review
    /// finding). Nothing is spawned unless the bundle really is Cua's.
    static let requirement = "identifier \"com.trycua.driver\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"YCK386LBJ7\""

    static var signatureIsTrusted: Bool {
        let url = URL(fileURLWithPath: "/Applications/CuaDriver.app") as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        guard let requirementRef = codeRequirement() else { return false }
        return SecStaticCodeCheckValidity(
            staticCode, [], requirementRef) == errSecSuccess
    }

    static func codeRequirement() -> SecRequirement? {
        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(
                requirement as CFString, [], &requirementRef) == errSecSuccess
        else { return nil }
        return requirementRef
    }

    private static let peerLock = NSLock()
    private static var trustedPeers = CuaPeerTrustCache()

    /// Verifies that the process on the other end of the socket really is
    /// Cua's driver, by asking the kernel for the peer's pid and checking
    /// THAT process against the Developer ID requirement.
    ///
    /// The socket carries no credential of its own, so without this any
    /// process running as this user could squat the path, receive every
    /// `type_text` payload, and hand back the snapshots Velora's delivery
    /// evidence is built from (review finding). Same-user is not a trust
    /// boundary; a verified code signature is.
    static func peerIsTrusted(fd: Int32, expectedPID: pid_t? = nil) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              pid > 0, let identity = CuaProcessIdentity.capture(pid: pid)
        else { return false }
        if let expectedPID, pid != expectedPID { return false }
        peerLock.lock()
        let known = trustedPeers.contains(identity)
        peerLock.unlock()
        // Cached per kernel process generation: a signature check costs
        // milliseconds, while a recycled pid always misses this cache.
        if known { return true }
        guard let requirementRef = codeRequirement() else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(
                nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], requirementRef) == errSecSuccess,
              CuaProcessIdentity.capture(pid: pid) == identity
        else { return false }
        peerLock.lock()
        trustedPeers.insert(identity)
        peerLock.unlock()
        return true
    }

    /// Forgets cached peer trust — called when a daemon Velora started exits,
    /// so a recycled pid is never trusted on the strength of its predecessor.
    static func forgetTrustedPeers() {
        peerLock.lock()
        trustedPeers.removeAll()
        peerLock.unlock()
    }

    /// Parses one response line. The daemon wraps MCP-shaped results:
    /// `{"ok":true,"result":{"content":…,"structuredContent":{…}}}` on
    /// success, `{"ok":false,"error":"…"}` on failure. Tool-level refusals
    /// arrive inside a successful envelope with `isError:true`; they remain
    /// failures even when they carry structured diagnostic fields.
    static func parseResponse(_ line: Data) -> Result<[String: Any], CuaDriverError> {
        guard let object = (try? JSONSerialization.jsonObject(with: line))
                as? [String: Any] else {
            return .failure(.malformedResponse)
        }
        guard (object["ok"] as? Bool) == true else {
            let message = (object["error"] as? String) ?? "unknown daemon error"
            return .failure(.daemonError(message))
        }
        guard let result = object["result"] as? [String: Any] else {
            return .failure(.malformedResponse)
        }
        // A TOOL error rides inside a successful envelope. Treating it as an
        // empty success is how a wrong argument key hid for a whole round:
        // every snapshot came back "fine, no elements", which reads exactly
        // like a window with nothing in it.
        if (result["isError"] as? Bool) == true {
            // Refusals arrive this way too, carrying a structured reason —
            // "off_space_or_ax_unresolved" says far more about what to do
            // next than the prose does, so prefer it when present.
            let structured = result["structuredContent"] as? [String: Any]
            let code = (structured?["code"] as? String)
                ?? (structured?["reason"] as? String)
            let text = ((result["content"] as? [[String: Any]])?
                .first?["text"] as? String)
            // Cua deliberately marks a non-verified exact-window activation
            // as a tool error while returning the independent observations.
            // Preserve only that closed shape for the presentation policy;
            // every other tool error remains a transport failure.
            if code == exactPartialCode, var structured {
                structured[toolErrorMarker] = true
                return .success(structured)
            }
            return .failure(.daemonError(code ?? text ?? "tool error"))
        }
        if var structured = result["structuredContent"] as? [String: Any] {
            guard CuaVisualEvidence.preserve(
                content: result["content"], in: &structured
            ) else { return .failure(.malformedResponse) }
            return .success(structured)
        }
        // No structured payload and no error marker: the tool answered with
        // something this client cannot ground an action on.
        guard result["content"] == nil else {
            return .failure(.malformedResponse)
        }
        return .success(result)
    }

    /// The wire shape is `{"method":"call","name":<tool>,"args":{…}}`.
    ///
    /// The key is `args`, and getting it wrong fails SILENTLY in the worst
    /// way: the daemon still answers `ok:true`, but with an `isError`
    /// content saying the required fields are missing. Verified live against
    /// driver 0.21.0 — `arguments`, `input`, and `params` are all ignored.
    static func encodeRequest(tool: String, arguments: [String: Any]) -> Data? {
        let payload: [String: Any] = [
            "method": "call", "name": tool, "args": arguments,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }
        data.append(0x0A)
        return data
    }
}

enum CuaDriverError: Error, Equatable {
    case notRunning
    case timeout
    case malformedResponse
    case daemonError(String)
}

enum CuaWindowActivation {
    static let tool = "bring_to_front"
    private static let verifiedCode =
        "bring_to_front_exact_window_verified"

    static func matches(_ reply: [String: Any], pid: Int, windowID: Int) -> Bool {
        guard reply["status"] as? String == "activated",
              reply["code"] as? String == verifiedCode,
              exactFlag(reply["activated"]) == true,
              exactFlag(reply["request_accepted"]) == true,
              exactFlag(reply["process_activated"]) == true,
              exactInt(reply["pid"]) == pid,
              exactInt(reply["window_id"]) == windowID,
              let effect = reply["exact_window_effect"] as? [String: Any],
              exactFlag(effect["verified"]) == true,
              exactFlag(effect["focused"]) == true,
              exactFlag(effect["frontmost_ordinary"]) == true,
              exactFlag(effect["target_visible_ordinary"]) == true,
              let observed = reply["observed"] as? [String: Any],
              exactInt(observed["frontmost_pid"]) == pid,
              exactInt(observed["focused_window_id"]) == windowID,
              exactInt(observed["frontmost_ordinary_window_id"]) == windowID,
              derivedPID(observed, targetPID: pid) == pid
        else { return false }
        return true
    }

    private static func derivedPID(
        _ observed: [String: Any], targetPID: Int
    ) -> Int? {
        guard let workspaceRaw = observed["workspace_frontmost_pid"],
              let privateRaw = observed["front_process_matches_target"]
        else { return nil }
        let workspace = nullablePID(workspaceRaw)
        let privateMatch = nullableFlag(privateRaw)
        guard workspace.valid, privateMatch.valid else { return nil }
        if let matches = privateMatch.value {
            return matches ? targetPID : nil
        }
        return workspace.value
    }

    private static func nullablePID(
        _ raw: Any
    ) -> (valid: Bool, value: Int?) {
        if raw is NSNull { return (true, nil) }
        guard let value = exactInt(raw) else { return (false, nil) }
        return (true, value)
    }

    private static func nullableFlag(
        _ raw: Any
    ) -> (valid: Bool, value: Bool?) {
        if raw is NSNull { return (true, nil) }
        guard let value = exactFlag(raw) else { return (false, nil) }
        return (true, value)
    }

    private static func exactInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.intValue
    }

    private static func exactFlag(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// The seam the selftests script: the host's decisions (what to press, when
/// to refuse, how to verify typing) run against a scripted transport with no
/// daemon anywhere near the test.
protocol CuaTransport: AnyObject {
    func call(_ tool: String, arguments: [String: Any],
              timeout: TimeInterval) -> Result<[String: Any], CuaDriverError>
}

struct CuaSocketIdentity {
    let path: String
    let ownedPID: pid_t?
}

/// One connection per call, like the driver's own CLI. Connect latency to a
/// local unix socket is microseconds; a persistent connection would only add
/// reconnect states to get wrong.
final class CuaSocketTransport: CuaTransport {
    /// Snapshots of an Electron window can run to a few hundred KB; 8 MB is
    /// far above any observed response yet still refuses a runaway stream.
    static let maxResponseBytes = 8 << 20

    private let socketProvider: () -> CuaSocketIdentity?

    /// The path is injectable so the selftest can point the real transport
    /// at a socket it controls and prove the peer check REFUSES an impostor
    /// — the direction of a security control that must never be assumed.
    convenience init() {
        self.init(socketIdentityProvider: {
            CuaDriverDaemon.transportSocketIdentity
        })
    }

    convenience init(socketPath: String) {
        self.init(socketIdentityProvider: {
            CuaSocketIdentity(path: socketPath, ownedPID: nil)
        })
    }

    init(socketPathProvider: @escaping () -> String?) {
        self.socketProvider = {
            socketPathProvider().map {
                CuaSocketIdentity(path: $0, ownedPID: nil)
            }
        }
    }

    init(socketIdentityProvider: @escaping () -> CuaSocketIdentity?) {
        self.socketProvider = socketIdentityProvider
    }

    var resolvedSocketPath: String? { socketProvider()?.path }
    var resolvedSocketIdentity: CuaSocketIdentity? { socketProvider() }

    func call(_ tool: String, arguments: [String: Any],
              timeout: TimeInterval) -> Result<[String: Any], CuaDriverError> {
        guard let request = CuaDriver.encodeRequest(tool: tool, arguments: arguments)
        else { return .failure(.malformedResponse) }
        /// One deadline for the whole call — connect, write, and every read.
        let deadline = Date().addingTimeInterval(timeout)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.notRunning) }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard let socketIdentity = resolvedSocketIdentity else {
            return .failure(.notRunning)
        }
        let path = socketIdentity.path
        guard CuaDriver.socketPathFits(path) else {
            return .failure(.notRunning)
        }
        let ok = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { cString in
                let capacity = MemoryLayout.size(ofValue: pointer.pointee)
                guard strlen(cString) < capacity else { return false }
                _ = memcpy(pointer, cString, strlen(cString) + 1)
                return true
            }
        }
        guard ok else { return .failure(.notRunning) }

        var timeval = Self.timeval(seconds: timeout)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval,
                       socklen_t(MemoryLayout<Foundation.timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval,
                       socklen_t(MemoryLayout<Foundation.timeval>.size))
        // A daemon dying mid-write must surface as an error, not SIGPIPE the
        // whole app.
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failure(.notRunning) }
        // Nothing is written until the far end proves it is Cua's driver.
        guard CuaDriver.peerIsTrusted(
            fd: fd, expectedPID: socketIdentity.ownedPID
        ) else {
            CuaSocketTransport.reportUntrustedPeerOnce()
            return .failure(.notRunning)
        }

        var remaining = request
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, buffer.count)
            }
            guard written > 0 else { return .failure(.notRunning) }
            remaining.removeFirst(written)
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while response.last != 0x0A {
            // The socket option bounds ONE read; without a whole-call
            // deadline a daemon dripping one byte per second would block the
            // action loop indefinitely (review finding). Re-arm the timeout
            // with the time this call has left before every read.
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return .failure(.timeout) }
            var readTimeout = Self.timeval(seconds: left)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout,
                           socklen_t(MemoryLayout<Foundation.timeval>.size))
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { break }
            guard count > 0 else {
                return .failure(errno == EAGAIN || errno == EWOULDBLOCK
                                ? .timeout : .notRunning)
            }
            response.append(contentsOf: chunk[0..<count])
            guard response.count <= Self.maxResponseBytes else {
                return .failure(.malformedResponse)
            }
        }
        guard !response.isEmpty else { return .failure(.notRunning) }
        return CuaDriver.parseResponse(response)
    }

    private static let noticeLock = NSLock()
    private static var reportedUntrustedPeer = false

    /// Once per launch: a squatted socket is a security event worth seeing in
    /// the log, but it must not become a per-call spam loop.
    static func reportUntrustedPeerOnce() {
        noticeLock.lock()
        let first = !reportedUntrustedPeer
        reportedUntrustedPeer = true
        noticeLock.unlock()
        guard first else { return }
        veloraLog("Velora: something other than Cua's driver is answering the "
                  + "driver socket — background actions are disabled")
    }

    private static func timeval(seconds: TimeInterval) -> Foundation.timeval {
        let whole = Int(seconds)
        let microseconds = Int32((seconds - Double(whole)) * 1_000_000)
        return Foundation.timeval(tv_sec: whole, tv_usec: microseconds)
    }
}

struct CuaDaemonLaunch {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let socketPath: String
}

struct CuaEndpointIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

enum CuaEndpoint {
    /// Captures the unlink authority only after readiness: exact 0600 socket,
    /// exact device, exact inode.
    static func identity(at path: String) -> CuaEndpointIdentity? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_mode & 0o777 == 0o600 else { return nil }
        return CuaEndpointIdentity(
            device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    static func removeOwned(at path: String, identity: CuaEndpointIdentity) {
        guard self.identity(at: path) == identity else { return }
        _ = unlink(path)
    }
}

protocol CuaChildProcess: AnyObject {
    var processIdentifier: pid_t { get }
    var isRunning: Bool { get }
    var hasLivenessChannel: Bool { get }
    func run() throws
    func closeLiveness()
    func terminate()
    func forceTerminate() -> Bool
}

private final class FoundationCuaChild: CuaChildProcess {
    private let process = Process()
    private let livenessPipe = Pipe()
    private var livenessWriter: FileHandle?
    private var startIdentity: CuaProcessIdentity?

    init(launch: CuaDaemonLaunch) {
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.environment = launch.environment
        process.standardInput = livenessPipe.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        livenessWriter = livenessPipe.fileHandleForWriting
    }

    var processIdentifier: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var hasLivenessChannel: Bool { livenessWriter != nil }

    func run() throws {
        try process.run()
        livenessPipe.fileHandleForReading.closeFile()
        startIdentity = CuaProcessIdentity.capture(pid: process.processIdentifier)
    }

    func closeLiveness() {
        livenessWriter?.closeFile()
        livenessWriter = nil
    }

    func terminate() { process.terminate() }

    func forceTerminate() -> Bool {
        guard process.isRunning, let startIdentity, startIdentity.isCurrent
        else { return false }
        return kill(startIdentity.pid, SIGKILL) == 0
    }
}

struct CuaDaemonRuntime {
    let driverInstalled: () -> Bool
    let signatureIsTrusted: () -> Bool
    let bundleIdentifier: () -> String?
    let environment: () -> [String: String]
    let makeSocketPath: () -> String
    let socketExists: (String) -> Bool
    let endpointIdentity: (String) -> CuaEndpointIdentity?
    let makeProcess: (CuaDaemonLaunch) -> CuaChildProcess
    let removeSocket: (String, CuaEndpointIdentity) -> Void
    let wait: (TimeInterval) -> Void

    static let production = CuaDaemonRuntime(
        driverInstalled: { CuaDriver.isInstalled },
        signatureIsTrusted: { CuaDriver.signatureIsTrusted },
        bundleIdentifier: { Bundle.main.bundleIdentifier },
        environment: { ProcessInfo.processInfo.environment },
        makeSocketPath: {
            "/tmp/velora-cua-\(getpid())-\(UUID().uuidString).sock"
        },
        socketExists: { FileManager.default.fileExists(atPath: $0) },
        endpointIdentity: { CuaEndpoint.identity(at: $0) },
        makeProcess: { FoundationCuaChild(launch: $0) },
        removeSocket: { path, identity in
            CuaEndpoint.removeOwned(at: path, identity: identity)
        },
        wait: { Thread.sleep(forTimeInterval: $0) })
}

/// Owns one private embedded driver child for the duration of an Action.
/// A separately run daemon is neither contacted nor controlled.
final class CuaDaemonController {
    private static let healthAttempts = 10
    private static let healthInterval: TimeInterval = 0.25
    private static let stopAttempts = 10
    private static let stopInterval: TimeInterval = 0.05
    private static let socketAttempts = 4
    private static let fallbackBundleID = "com.sushil.velora"

    private let runtime: CuaDaemonRuntime
    private let state = NSCondition()
    private var child: CuaChildProcess?
    private var socketPath: String?
    private var endpointIdentity: CuaEndpointIdentity?
    private var connectionEnabled = false
    private var stopping = false
    private var startingGeneration: Int?
    private var nextGeneration = 0
    private var startCancelled = false
    private var lastStartGeneration = 0
    private var lastStartSucceeded = false

    init(runtime: CuaDaemonRuntime) {
        self.runtime = runtime
    }

    var activeSocketPath: String? {
        activeSocketIdentity?.path
    }

    var activeSocketIdentity: CuaSocketIdentity? {
        socketIdentity(requireEndpoint: true)
    }

    var transportSocketIdentity: CuaSocketIdentity? {
        socketIdentity(requireEndpoint: false)
    }

    private func socketIdentity(requireEndpoint: Bool) -> CuaSocketIdentity? {
        state.lock()
        guard let child else {
            state.unlock()
            return nil
        }
        if !child.isRunning {
            connectionEnabled = false
            state.unlock()
            CuaDriver.forgetTrustedPeers()
            return nil
        }
        guard connectionEnabled, !stopping, let socketPath,
              !requireEndpoint || endpointIdentity != nil else {
            state.unlock()
            return nil
        }
        let pid = child.processIdentifier
        state.unlock()
        guard pid > 0 else { return nil }
        return CuaSocketIdentity(path: socketPath, ownedPID: pid)
    }

    func ensureRunning(transport: CuaTransport) -> Bool {
        state.lock()
        while stopping { state.wait() }
        if let generation = startingGeneration {
            while startingGeneration == generation { state.wait() }
            let succeeded = lastStartGeneration == generation
                && lastStartSucceeded
                && child?.isRunning == true
                && endpointIdentity != nil
                && connectionEnabled
                && !stopping
            state.unlock()
            return succeeded
        }
        if let child, child.isRunning {
            let mayConnect = connectionEnabled && endpointIdentity != nil
            state.unlock()
            return mayConnect
        }
        var stalePath: String?
        var staleIdentity: CuaEndpointIdentity?
        if child != nil {
            stalePath = socketPath
            staleIdentity = endpointIdentity
            child = nil
            socketPath = nil
            endpointIdentity = nil
            connectionEnabled = false
            stopping = false
        }
        nextGeneration += 1
        let generation = nextGeneration
        startingGeneration = generation
        startCancelled = false
        state.unlock()
        if let stalePath, let staleIdentity {
            runtime.removeSocket(stalePath, staleIdentity)
        }
        CuaDriver.forgetTrustedPeers()
        return startOwned(generation, transport: transport)
    }

    private func startOwned(
        _ generation: Int, transport: CuaTransport
    ) -> Bool {
        guard runtime.driverInstalled() else {
            finishStart(generation)
            return false
        }
        guard runtime.signatureIsTrusted() else {
            finishStart(generation)
            veloraLog("Velora: refusing to start cua-driver — the bundle at "
                      + "/Applications/CuaDriver.app is not signed by Cua AI")
            return false
        }
        guard !isStartCancelled(generation) else {
            finishStart(generation)
            return false
        }
        var path: String?
        for _ in 0..<Self.socketAttempts {
            let candidate = runtime.makeSocketPath()
            guard candidate.hasPrefix("/tmp/"),
                  CuaDriver.socketPathFits(candidate) else { continue }
            guard !runtime.socketExists(candidate) else { continue }
            path = candidate
            break
        }
        guard let path else {
            finishStart(generation)
            veloraLog("Velora: refusing an invalid private cua-driver socket path")
            return false
        }
        guard !isStartCancelled(generation) else {
            finishStart(generation)
            return false
        }

        let bundleID = runtime.bundleIdentifier() ?? Self.fallbackBundleID
        let environment = CuaDriver.safeEnvironment(
            from: runtime.environment(), bundleID: bundleID,
            hostPID: getpid())
        let launch = CuaDaemonLaunch(
            executableURL: URL(fileURLWithPath: CuaDriver.appBinaryPath),
            arguments: [
                "serve", "--embedded", "--parent-liveness-stdio",
                "--no-permissions-gate",
                "--socket", path, "--host-bundle-id", bundleID,
                "--permission-mode", "standard", "--no-overlay",
            ],
            environment: environment,
            socketPath: path)
        let process = runtime.makeProcess(launch)
        do {
            try process.run()
        } catch {
            if process.isRunning {
                state.lock()
                child = process
                socketPath = path
                endpointIdentity = nil
                connectionEnabled = false
                state.unlock()
                failStart(generation, process: process, path: path)
            } else {
                process.closeLiveness()
                finishStart(generation)
            }
            veloraLog("Velora: could not start cua-driver — \(error.localizedDescription)")
            return false
        }
        state.lock()
        let stillStarting = startingGeneration == generation
        child = process
        socketPath = path
        endpointIdentity = nil
        connectionEnabled = stillStarting && !startCancelled
        state.unlock()
        guard stillStarting, process.hasLivenessChannel,
              !isStartCancelled(generation) else {
            failStart(generation, process: process, path: path)
            return false
        }
        veloraLog("Velora: started a private cua-driver child for this action")

        for _ in 0..<Self.healthAttempts {
            guard process.isRunning, !isStartCancelled(generation) else {
                failStart(generation, process: process, path: path)
                return false
            }
            if Self.isHealthy(transport: transport),
               let identity = runtime.endpointIdentity(path) {
                state.lock()
                let sameChild = startingGeneration == generation
                    && child === process && process.isRunning
                    && connectionEnabled && !stopping
                    && !startCancelled
                if sameChild {
                    endpointIdentity = identity
                    startingGeneration = nil
                    lastStartGeneration = generation
                    lastStartSucceeded = true
                    state.broadcast()
                }
                state.unlock()
                if sameChild { return true }
                failStart(
                    generation, process: process, path: path,
                    identity: identity)
                return false
            }
            runtime.wait(Self.healthInterval)
        }
        failStart(generation, process: process, path: path)
        return false
    }

    func stopOwned() {
        state.lock()
        while true {
            while stopping { state.wait() }
            guard startingGeneration != nil else { break }
            startCancelled = true
            connectionEnabled = false
            state.broadcast()
            while startingGeneration != nil { state.wait() }
        }
        guard let process = child else {
            state.unlock()
            CuaDriver.forgetTrustedPeers()
            return
        }
        let path = socketPath
        let identity = endpointIdentity
        stopping = true
        connectionEnabled = false
        state.unlock()
        CuaDriver.forgetTrustedPeers()

        guard stopChild(process) else {
            state.lock()
            stopping = false
            state.broadcast()
            state.unlock()
            veloraLog("Velora: cua-driver child did not exit; private socket retained")
            return
        }
        state.lock()
        if child === process {
            child = nil
            socketPath = nil
            endpointIdentity = nil
        }
        stopping = false
        state.broadcast()
        state.unlock()
        if let path, let identity { runtime.removeSocket(path, identity) }
        veloraLog("Velora: stopped the private cua-driver child")
    }

    private func failStart(
        _ generation: Int, process: CuaChildProcess,
        path: String, identity: CuaEndpointIdentity? = nil
    ) {
        state.lock()
        if child === process {
            connectionEnabled = false
            endpointIdentity = identity
        }
        state.unlock()
        let stopped = stopChild(process)

        state.lock()
        if child === process, stopped {
            child = nil
            socketPath = nil
            endpointIdentity = nil
        }
        if startingGeneration == generation {
            startingGeneration = nil
            lastStartGeneration = generation
            lastStartSucceeded = false
            startCancelled = false
        }
        state.broadcast()
        state.unlock()
        CuaDriver.forgetTrustedPeers()
        if stopped, let identity {
            runtime.removeSocket(path, identity)
        }
    }

    private func finishStart(_ generation: Int) {
        state.lock()
        if startingGeneration == generation {
            startingGeneration = nil
            lastStartGeneration = generation
            lastStartSucceeded = false
            startCancelled = false
        }
        state.broadcast()
        state.unlock()
        CuaDriver.forgetTrustedPeers()
    }

    private func isStartCancelled(_ generation: Int) -> Bool {
        state.lock()
        defer { state.unlock() }
        return startingGeneration != generation || startCancelled
    }

    private func stopChild(_ process: CuaChildProcess) -> Bool {
        process.closeLiveness()
        waitForExit(process)
        if process.isRunning { process.terminate() }
        waitForExit(process)
        if process.isRunning {
            _ = process.forceTerminate()
            waitForExit(process)
        }
        return !process.isRunning
    }

    private func waitForExit(_ process: CuaChildProcess) {
        for _ in 0..<Self.stopAttempts {
            if !process.isRunning { return }
            runtime.wait(Self.stopInterval)
        }
    }

    static func isHealthy(transport: CuaTransport,
                          timeout: TimeInterval = 1.0) -> Bool {
        guard case .success(let permissions) = transport.call(
            "check_permissions", arguments: [:], timeout: timeout)
        else { return false }
        return (permissions["accessibility"] as? Bool) == true
    }
}

enum CuaDriverDaemon {
    private static let controller = CuaDaemonController(runtime: .production)

    static var activeSocketPath: String? { controller.activeSocketPath }
    static var activeSocketIdentity: CuaSocketIdentity? {
        controller.activeSocketIdentity
    }
    static var transportSocketIdentity: CuaSocketIdentity? {
        controller.transportSocketIdentity
    }

    static func stopIfVeloraStarted() {
        controller.stopOwned()
    }

    static func isHealthy(transport: CuaTransport,
                          timeout: TimeInterval = 1.0) -> Bool {
        CuaDaemonController.isHealthy(transport: transport, timeout: timeout)
    }

    static func ensureRunning(transport: CuaTransport) -> Bool {
        controller.ensureRunning(transport: transport)
    }
}
