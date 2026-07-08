import Foundation

/// Lightweight append-only file logger mirroring `NSLog` into
/// `~/.velora/velora-app.log`, so the Swift app's behavior is observable
/// after the fact (the unified-logging store drops our `info`-level lines,
/// which made the "hotkey dead" bug painful to diagnose). Cheap, serial,
/// best-effort — never throws into callers.
///
/// Use `veloraLog("…")` everywhere we'd previously `NSLog`; it does both so
/// existing Console workflows keep working while the file gives us a durable
/// trail. The file is truncated when it grows past ~1 MB so it can't bloat.
enum VeloraLog {
    private static let queue = DispatchQueue(label: "com.velora.log")
    private static let maxBytes = 1_000_000

    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("velora-app.log")
    }()

    static func write(_ message: String) {
        queue.async {
            let stamp = Self.timestamp()
            let line = "\(stamp) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                try? Data().write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String { formatter.string(from: Date()) }
}

/// Logs to both the unified log (Console) and the Velora file log.
func veloraLog(_ message: String) {
    NSLog("%@", message)
    VeloraLog.write(message)
}
