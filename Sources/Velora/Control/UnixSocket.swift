import Darwin
import Foundation

/// Minimal shared plumbing for the control plane's AF_UNIX sockets (server
/// and CLI/MCP client sides). Local-only by construction — there is no TCP
/// variant of any of these helpers.
enum UnixSocket {
    /// Runs `body` with a `sockaddr_un` for `path`. Returns nil when the path
    /// does not fit `sun_path` (104 bytes on Darwin).
    static func withAddress(
        path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Bool
    ) -> Bool? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard bytes.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    /// Reads until a newline, EOF, error, or one chunk past `cap` bytes. The
    /// newline is not included. Returns nil when nothing arrived.
    static func readLine(_ fd: Int32, cap: Int) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= cap {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer.isEmpty ? nil : buffer
    }

    /// Writes the whole buffer, tolerating short writes; gives up on error
    /// (the peer sees a truncated line and fails its own parse).
    static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(fd, base, remaining)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return }
                base += n
                remaining -= n
            }
        }
    }

    /// A stuck peer must never wedge the serving queue: bound both directions.
    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
    }

    /// A peer that disconnects mid-write must not SIGPIPE the whole app.
    static func disableSigpipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Non-consuming peer liveness probe for a request whose response is still
    /// pending. Readability alone can mean data; EOF/HUP means the caller is
    /// gone and the app-owned microphone/file operation should be cancelled.
    static func peerDisconnected(_ fd: Int32) -> Bool {
        var descriptor = pollfd(
            fd: fd,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0)
        let result = poll(&descriptor, 1, 0)
        guard result > 0 else { return false }
        // The protocol keeps the connection open until the response arrives;
        // a hangup or socket error therefore means there is no response
        // consumer and the exact in-flight capability can be cancelled.
        return descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0
    }
}
