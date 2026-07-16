import Darwin
import Foundation

/// Owner-only app broker for CLI/MCP requests. The protocol is local AF_UNIX,
/// one bounded JSON line per connection, and one final response line.
final class LocalControlServer {
    private let path: String
    private let router: LocalControlRouter
    private let acceptQueue = DispatchQueue(label: "com.velora.control.accept")
    private let clientQueue = DispatchQueue(
        label: "com.velora.control.clients", attributes: .concurrent)
    private let stateLock = NSLock()
    private let clientSlots = DispatchSemaphore(value: 8)
    private var listener: Int32 = -1
    /// Worker-owned descriptors currently accepted by this server. stop()
    /// shuts them down to unblock partial reads and long-running requests;
    /// each worker remains the sole owner responsible for close().
    private var clients: Set<Int32> = []

    init(path: String = AppConfig.controlSocketPath, router: LocalControlRouter) {
        self.path = path
        self.router = router
    }

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard listener < 0 else { return true }

        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: parent.path)
        } catch {
            veloraLog("Velora: control socket directory failed: \(error.localizedDescription)")
            return false
        }

        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                UnixSocket.setTimeouts(probe, seconds: 1)
                let connected = UnixSocket.withAddress(path: path) { address, length in
                    Darwin.connect(probe, address, length) == 0
                } == true
                close(probe)
                if connected {
                    veloraLog("Velora: control socket already owned by a running instance")
                    return false
                }
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        UnixSocket.disableSigpipe(fd)
        guard UnixSocket.withAddress(path: path, { address, length in
            Darwin.bind(fd, address, length) == 0
        }) == true else {
            close(fd)
            return false
        }
        guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return false
        }
        listener = fd
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd) }
        veloraLog("Velora: local control socket ready")
        return true
    }

    func stop() {
        stateLock.lock()
        let fd = listener
        listener = -1
        // Keep descriptor membership stable until every shutdown call has
        // completed. A worker removes itself under this same lock before close,
        // so an fd cannot be closed/reused between a snapshot and shutdown.
        for client in clients { shutdown(client, SHUT_RDWR) }
        stateLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    deinit { stop() }

    private func isCurrent(_ fd: Int32) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener == fd
    }

    private func register(_ client: Int32, listener fd: Int32) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard listener == fd else { return false }
        clients.insert(client)
        return true
    }

    private func unregister(_ client: Int32) {
        stateLock.lock()
        clients.remove(client)
        stateLock.unlock()
    }

    private func acceptLoop(fd: Int32) {
        while isCurrent(fd) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            clientSlots.wait()
            guard register(client, listener: fd) else {
                close(client)
                clientSlots.signal()
                continue
            }
            clientQueue.async { [weak self] in
                defer {
                    self?.unregister(client)
                    close(client)
                    self?.clientSlots.signal()
                }
                self?.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        UnixSocket.disableSigpipe(fd)
        UnixSocket.setTimeouts(fd, seconds: 15)

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            send(.error(id: "", ControlFailure(
                code: "unauthorized", message: "Control socket peer is not the app owner")), to: fd)
            return
        }
        guard let data = UnixSocket.readLine(fd, cap: ControlRequest.maxBytes) else { return }
        guard data.count <= ControlRequest.maxBytes else {
            send(.error(id: "", ControlFailure(
                code: "request_too_large", message: "Request exceeds 1 MiB")), to: fd)
            return
        }
        do {
            let request = try ControlRequest.parse(data)
            // Long-running local capabilities keep this bounded client worker
            // (not the accept loop or main thread) parked until the app-owned
            // workflow completes. Five-minute recording plus formatting gets
            // a small grace window; the client slots still cap concurrency.
            UnixSocket.setTimeouts(fd, seconds: 360)
            let completed = DispatchSemaphore(value: 0)
            var routed: ControlResponse?
            let cancellation = router.handle(request) { response in
                routed = response
                completed.signal()
            }
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(360) * 1_000_000_000
            while true {
                if completed.wait(timeout: .now() + .milliseconds(250)) == .success {
                    if let routed { send(routed, to: fd) }
                    break
                }
                if UnixSocket.peerDisconnected(fd) {
                    cancellation?()
                    return
                }
                if !isRunning {
                    cancellation?()
                    return
                }
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    cancellation?()
                    send(.error(id: request.id, ControlFailure(
                        code: "request_timeout", message: "Velora request timed out")), to: fd)
                    break
                }
            }
        } catch {
            send(.error(id: "", ControlFailure(
                code: "invalid_request", message: error.localizedDescription)), to: fd)
        }
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listener >= 0
    }

    private func send(_ response: ControlResponse, to fd: Int32) {
        guard let data = response.encodedLine() else { return }
        UnixSocket.writeAll(data, to: fd)
    }
}

enum ControlClientError: LocalizedError {
    case socketPathTooLong
    case appUnavailable
    case sendFailed
    case invalidResponse
    case responseTooLarge
    case remote(ControlFailure)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: return "Velora control socket path is too long"
        case .appUnavailable: return "Velora is not running"
        case .sendFailed: return "Could not send request to Velora"
        case .invalidResponse: return "Velora returned an invalid response"
        case .responseTooLarge: return "Velora response exceeded the size limit"
        case .remote(let failure): return failure.message
        }
    }
}

/// Blocking one-shot client used only by the headless CLI/MCP process.
enum LocalControlClient {
    static let maxResponseBytes = 4 * 1_048_576

    static func send(
        command: String,
        arguments: [String: Any] = [:],
        path: String = AppConfig.controlSocketPath,
        timeoutSeconds: Int = 30
    ) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.appUnavailable }
        defer { close(fd) }
        UnixSocket.disableSigpipe(fd)
        UnixSocket.setTimeouts(fd, seconds: timeoutSeconds)
        guard let connected = UnixSocket.withAddress(path: path, { address, length in
            Darwin.connect(fd, address, length) == 0
        }) else { throw ControlClientError.socketPathTooLong }
        guard connected else { throw ControlClientError.appUnavailable }

        let request = ControlRequest(
            id: UUID().uuidString, command: command, arguments: arguments)
        guard JSONSerialization.isValidJSONObject(request.payload),
              var data = try? JSONSerialization.data(
                withJSONObject: request.payload, options: [.sortedKeys])
        else { throw ControlClientError.sendFailed }
        data.append(0x0A)
        UnixSocket.writeAll(data, to: fd)

        guard let responseData = UnixSocket.readLine(fd, cap: maxResponseBytes) else {
            throw ControlClientError.invalidResponse
        }
        guard responseData.count <= maxResponseBytes else {
            throw ControlClientError.responseTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: responseData),
              let response = object as? [String: Any],
              (response["version"] as? NSNumber)?.intValue == ControlRequest.version,
              let ok = response["ok"] as? Bool
        else { throw ControlClientError.invalidResponse }
        if ok, let result = response["result"] as? [String: Any] { return result }
        if let error = response["error"] as? [String: Any] {
            throw ControlClientError.remote(ControlFailure(
                code: error["code"] as? String ?? "request_failed",
                message: error["message"] as? String ?? "Velora request failed"))
        }
        throw ControlClientError.invalidResponse
    }
}
