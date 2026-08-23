import Foundation

/// Client for the Cua Driver daemon (github.com/trycua — `com.trycua.driver`),
/// an MIT-licensed computer-use daemon the user installs separately. It can
/// deliver clicks and text to a CHOSEN window without moving the cursor or
/// stealing focus, which is what lets an Action run while the user keeps
/// working. Velora talks to it over its unix socket in newline-delimited
/// JSON: `{"method":"call","name":<tool>,"arguments":{…}}` per request
/// (protocol verified live against driver 0.21.0, 2026-08-23).
///
/// Everything here is transport. What Action Mode may DO with the transport
/// is decided by the same `ActionPlan` validator and `ActionRuntimePolicy`
/// that govern the foreground path — the driver is an actuator, never an
/// authority.
enum CuaDriver {
    /// Fixed by the driver; `cua-driver serve` refuses a second bind, so
    /// discovering a live socket here means a healthy daemon.
    static var socketPath: String {
        NSHomeDirectory() + "/Library/Caches/cua-driver/cua-driver.sock"
    }

    static var appBinaryPath: String {
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: appBinaryPath)
    }

    /// Parses one response line. The daemon wraps MCP-shaped results:
    /// `{"ok":true,"result":{"content":…,"structuredContent":{…}}}` on
    /// success, `{"ok":false,"error":"…"}` on failure. Tool-level refusals
    /// (`{"refusal":…,"status":"refused"}`) arrive INSIDE a successful
    /// envelope and are surfaced as values, not errors — a refusal is an
    /// answer the caller must judge, not a transport fault.
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
        if let structured = result["structuredContent"] as? [String: Any] {
            return .success(structured)
        }
        return .success(result)
    }

    static func encodeRequest(tool: String, arguments: [String: Any]) -> Data? {
        let payload: [String: Any] = [
            "method": "call", "name": tool, "arguments": arguments,
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

/// The seam the selftests script: the host's decisions (what to press, when
/// to refuse, how to verify typing) run against a scripted transport with no
/// daemon anywhere near the test.
protocol CuaTransport: AnyObject {
    func call(_ tool: String, arguments: [String: Any],
              timeout: TimeInterval) -> Result<[String: Any], CuaDriverError>
}

/// One connection per call, like the driver's own CLI. Connect latency to a
/// local unix socket is microseconds; a persistent connection would only add
/// reconnect states to get wrong.
final class CuaSocketTransport: CuaTransport {
    /// Snapshots of an Electron window can run to a few hundred KB; 8 MB is
    /// far above any observed response yet still refuses a runaway stream.
    static let maxResponseBytes = 8 << 20

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
        let path = CuaDriver.socketPath
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

    private static func timeval(seconds: TimeInterval) -> Foundation.timeval {
        let whole = Int(seconds)
        let microseconds = Int32((seconds - Double(whole)) * 1_000_000)
        return Foundation.timeval(tv_sec: whole, tv_usec: microseconds)
    }
}

/// Daemon lifecycle. If the user already runs a daemon (for another agent),
/// Velora uses it as-is and never touches its lifetime. Otherwise Velora
/// spawns one as a child process — a child inherits Velora's TCC
/// responsibility, so the daemon reads AX trees under the Accessibility grant
/// Velora already holds and no new permission dialog appears.
///
/// A daemon Velora started, Velora stops on quit. The driver's socket carries
/// no per-connection credential, so while a daemon is up any process running
/// as this user can drive every app on the desktop. That surface is worth
/// having only while Velora is actually using it.
enum CuaDriverDaemon {
    private static let lock = NSLock()
    private static var spawned: Process?

    /// Called from `applicationWillTerminate`. A daemon Velora did not start
    /// is left alone — another client may be attached to it.
    static func stopIfVeloraStarted() {
        lock.lock()
        let process = spawned
        spawned = nil
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        veloraLog("Velora: stopped the cua-driver daemon it started")
    }

    /// True when a daemon answers AND holds a usable Accessibility grant.
    /// The permission check matters for a daemon someone else started: it may
    /// run under an identity with no AX access, and every window read would
    /// return empty trees that look like "nothing on screen" to the planner.
    static func isHealthy(transport: CuaTransport,
                          timeout: TimeInterval = 1.0) -> Bool {
        guard case .success(let permissions) = transport.call(
            "check_permissions", arguments: [:], timeout: timeout)
        else { return false }
        return (permissions["accessibility"] as? Bool) == true
    }

    /// Health-checks, spawning the daemon first if the driver is installed
    /// but idle. Bounded: one spawn attempt, ~2.5 s worst case, called off
    /// the main thread (the action loop's queue).
    static func ensureRunning(transport: CuaTransport) -> Bool {
        if isHealthy(transport: transport) { return true }
        guard CuaDriver.isInstalled else { return false }
        lock.lock()
        let alreadySpawned = spawned?.isRunning == true
        lock.unlock()
        if !alreadySpawned {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CuaDriver.appBinaryPath)
            process.arguments = ["serve"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                veloraLog("Velora: could not start cua-driver — \(error.localizedDescription)")
                return false
            }
            lock.lock()
            spawned = process
            lock.unlock()
            veloraLog("Velora: started cua-driver daemon for background actions")
        }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.25)
            if isHealthy(transport: transport) { return true }
        }
        return false
    }
}
