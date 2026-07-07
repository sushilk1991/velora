import Foundation

/// Finds bundled resources and the engine project directory in both launch
/// configurations:
///  - inside `Velora.app` (resources in `Contents/Resources`, repo optional),
///  - as a bare SwiftPM binary at `<repo>/.build/<config>/Velora` (dev runs).
enum ResourceLocator {
    /// Directory containing this executable, resolved through symlinks.
    private static var executableDirectory: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// Walks up from a starting directory looking for a path that satisfies
    /// `predicate`; returns the matching directory.
    private static func ancestor(
        of start: URL, maxDepth: Int = 8, where predicate: (URL) -> Bool
    ) -> URL? {
        var dir = start
        for _ in 0..<maxDepth {
            if predicate(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// The repository root, if this binary lives inside a checkout
    /// (identified by `engine/pyproject.toml` or `Package.swift` + `Sources/Velora`).
    static var repoRoot: URL? {
        let fm = FileManager.default
        let isRepoRoot: (URL) -> Bool = { dir in
            fm.fileExists(atPath: dir.appendingPathComponent("engine/pyproject.toml").path)
                || (fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
                    && fm.fileExists(atPath: dir.appendingPathComponent("Sources/Velora").path))
        }
        if let exeDir = executableDirectory,
           let root = ancestor(of: exeDir, where: isRepoRoot) {
            return root
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        return ancestor(of: cwd, where: isRepoRoot)
    }

    /// The engine project directory (`<repo>/engine`), honoring the
    /// `VELORA_ENGINE_DIR` override. Returns nil when unavailable — the app
    /// then runs in degraded mode (no local transcription).
    static var engineDirectory: URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["VELORA_ENGINE_DIR"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        guard let root = repoRoot else { return nil }
        let engine = root.appendingPathComponent("engine", isDirectory: true)
        return fm.fileExists(atPath: engine.appendingPathComponent("pyproject.toml").path)
            ? engine : nil
    }

    /// URL for a bundled resource (e.g. "start", "caf"). Checks the .app
    /// bundle first, then `<repo>/Resources` for bare-binary dev runs.
    static func resource(named name: String, extension ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let root = repoRoot {
            let candidate = root.appendingPathComponent("Resources/\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
