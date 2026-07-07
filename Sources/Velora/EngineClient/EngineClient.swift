import Foundation

/// Delegate for engine socket lifecycle and events. All callbacks are
/// delivered on the main queue.
protocol EngineClientDelegate: AnyObject {
    func engineClient(_ client: EngineClient, didReceive event: EngineEvent)
    func engineClientDidDisconnect(_ client: EngineClient)
}

/// Unix-domain-socket client for velora-engine.
///
/// Wire format (docs/ARCHITECTURE.md, mirrored by
/// engine/src/velora_engine/protocol.py): every frame is
/// `u32 length (LE) | u8 type | payload`, where `length` counts everything
/// after the length prefix — the 1-byte type plus the payload
/// (`length == 1 + payload.count`).
/// Types: `0x01` JSON control, `0x02` raw PCM audio (16 kHz mono Float32 LE).
final class EngineClient {
    enum FrameType: UInt8 {
        case json = 0x01
        case audio = 0x02
    }

    weak var delegate: EngineClientDelegate?

    private var fd: Int32 = -1
    private let stateLock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.velora.engine.write")
    private let readQueue = DispatchQueue(label: "com.velora.engine.read")
    private var generation = 0

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return fd >= 0
    }

    /// Attempts a blocking connect to the unix socket. Returns true on
    /// success and starts the background read loop. Safe to call repeatedly.
    @discardableResult
    func connect(path: String) -> Bool {
        disconnect(notify: false)

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let ok: Bool = path.withCString { cPath in
            guard strlen(cPath) <= maxLen else { return false }
            withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                let raw = UnsafeMutableRawPointer(tuplePtr).assumingMemoryBound(to: CChar.self)
                strncpy(raw, cPath, maxLen)
            }
            return true
        }
        guard ok else { close(sock); return false }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(sock); return false }

        // Avoid SIGPIPE killing the app when the engine dies mid-write.
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        stateLock.lock()
        fd = sock
        generation += 1
        let gen = generation
        stateLock.unlock()

        readQueue.async { [weak self] in self?.readLoop(socket: sock, generation: gen) }
        return true
    }

    /// Closes the connection. `notify` controls whether the delegate hears
    /// about it (external disconnects notify; internal reconnects don't).
    func disconnect(notify: Bool = true) {
        stateLock.lock()
        let sock = fd
        fd = -1
        generation += 1  // invalidate any running read loop
        stateLock.unlock()
        guard sock >= 0 else { return }
        // shutdown before close: unblocks a read() parked in the read loop so
        // the stale loop exits promptly instead of lingering on a recycled fd.
        shutdown(sock, SHUT_RDWR)
        close(sock)
        if notify {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.engineClientDidDisconnect(self)
            }
        }
    }

    // MARK: - Sending

    /// Sends a JSON control frame (e.g. `{"cmd":"start",...}`).
    func send(json object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            NSLog("Velora: refusing to send invalid JSON control frame")
            return
        }
        send(type: .json, payload: data)
    }

    /// Sends a raw PCM audio chunk (16 kHz mono Float32 LE).
    func send(audio data: Data) {
        send(type: .audio, payload: data)
    }

    private func send(type: FrameType, payload: Data) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let sock = self.fd
            self.stateLock.unlock()
            guard sock >= 0 else { return }

            var frame = Data(capacity: 5 + payload.count)
            var length = UInt32(1 + payload.count).littleEndian  // type byte + payload
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            frame.append(type.rawValue)
            frame.append(payload)

            let failed: Bool = frame.withUnsafeBytes { buf -> Bool in
                var offset = 0
                while offset < buf.count {
                    let n = write(sock, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                    if n <= 0 {
                        if errno == EINTR { continue }
                        return true
                    }
                    offset += n
                }
                return false
            }
            if failed { self.disconnect() }
        }
    }

    // MARK: - Receiving

    private func readLoop(socket sock: Int32, generation gen: Int) {
        func isCurrent() -> Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return generation == gen && fd == sock
        }

        func readExact(_ count: Int) -> Data? {
            var data = Data(count: count)
            var offset = 0
            let ok: Bool = data.withUnsafeMutableBytes { buf -> Bool in
                while offset < count {
                    let n = read(sock, buf.baseAddress!.advanced(by: offset), count - offset)
                    if n == 0 { return false }        // EOF
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += n
                }
                return true
            }
            return ok ? data : nil
        }

        while isCurrent() {
            guard let header = readExact(4) else { break }
            let rawLength = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let length = Int(UInt32(littleEndian: rawLength))  // type byte + payload
            guard length >= 1, length <= 32 * 1024 * 1024 else { break }  // engine's cap
            guard let body = readExact(length) else { break }
            // Re-check after the blocking reads: a frame read by a stale loop
            // (disconnected mid-read, fd possibly recycled by a reconnect)
            // must never reach the parser as if it came from the new
            // connection.
            guard isCurrent() else { break }
            let type = body[body.startIndex]
            let payload = body.dropFirst()

            if type == FrameType.json.rawValue {
                guard
                    let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                else {
                    NSLog("Velora: undecodable JSON frame from engine (%d bytes)", payload.count)
                    continue
                }
                let event = EngineEvent.parse(object)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.engineClient(self, didReceive: event)
                }
            }
            // AUDIO frames from the engine are not part of the protocol; skip.
        }

        if isCurrent() { disconnect() }
    }
}
