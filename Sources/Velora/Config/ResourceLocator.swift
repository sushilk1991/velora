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

    /// Where the engine project was found and how it should be run.
    struct EngineLocation {
        let directory: URL
        /// True when the engine was synced from the app bundle into
        /// Application Support (self-contained distribution). The supervisor
        /// then points uv's caches at Application Support too, so nothing is
        /// ever written into the signed bundle.
        let isBundled: Bool
    }

    /// `~/Library/Application Support/Velora` — home for the synced engine
    /// project, its venv, and uv's caches in bundled (distribution) runs.
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velora", isDirectory: true)
    }

    /// The uv binary shipped inside the bundle (`Contents/Resources/bin/uv`),
    /// if present and executable. Distribution builds carry it so the app
    /// works on machines without uv installed.
    static var bundledUV: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let uv = resources.appendingPathComponent("bin/uv")
        return FileManager.default.isExecutableFile(atPath: uv.path) ? uv : nil
    }

    /// The engine project shipped inside the bundle
    /// (`Contents/Resources/engine`), if present.
    private static var bundledEngineDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let engine = resources.appendingPathComponent("engine", isDirectory: true)
        return FileManager.default.fileExists(
            atPath: engine.appendingPathComponent("pyproject.toml").path) ? engine : nil
    }

    /// Locates the engine project. Resolution order:
    ///  1. `VELORA_ENGINE_DIR` env (dev override, always wins),
    ///  2. engine bundled in the .app — synced into Application Support and
    ///     run from there (self-contained distribution builds),
    ///  3. `VeloraEngineDir` Info.plist key (dev builds tied to a checkout),
    ///  4. repo-ancestor scan (bare `swift build` binaries).
    /// Returns nil when unavailable — the app then runs in degraded mode
    /// (no local transcription).
    static func locateEngine() -> EngineLocation? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["VELORA_ENGINE_DIR"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return fm.fileExists(atPath: url.path)
                ? EngineLocation(directory: url, isBundled: false) : nil
        }
        if let bundled = bundledEngineDirectory,
           let synced = syncBundledEngine(from: bundled) {
            return EngineLocation(directory: synced, isBundled: true)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "VeloraEngineDir") as? String,
           !baked.isEmpty {
            let url = URL(fileURLWithPath: baked, isDirectory: true)
            if fm.fileExists(atPath: url.appendingPathComponent("pyproject.toml").path) {
                return EngineLocation(directory: url, isBundled: false)
            }
        }
        guard let root = repoRoot else { return nil }
        let engine = root.appendingPathComponent("engine", isDirectory: true)
        return fm.fileExists(atPath: engine.appendingPathComponent("pyproject.toml").path)
            ? EngineLocation(directory: engine, isBundled: false) : nil
    }

    /// Syncs the bundled engine project into Application Support so uv can
    /// create the venv next to it (the signed bundle is never written to).
    /// Copies when the target is missing or its `.velora-build` stamp differs
    /// from the bundle's; the target's `.venv` is preserved across syncs so
    /// upgrades don't re-download Python dependencies from scratch.
    private static func syncBundledEngine(from bundled: URL) -> URL? {
        let fm = FileManager.default
        let target = applicationSupportDirectory.appendingPathComponent("engine", isDirectory: true)
        let stampName = ".velora-build"
        let readStamp: (URL) -> String? = { dir in
            (try? String(contentsOf: dir.appendingPathComponent(stampName), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bundledStamp = readStamp(bundled)
        let targetUsable = fm.fileExists(
            atPath: target.appendingPathComponent("pyproject.toml").path)
        if targetUsable, let stamp = bundledStamp, !stamp.isEmpty, readStamp(target) == stamp {
            return target
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            // Replace everything except .venv (preserved), then copy the
            // bundle's payload in.
            for entry in try fm.contentsOfDirectory(atPath: target.path) where entry != ".venv" {
                try fm.removeItem(at: target.appendingPathComponent(entry))
            }
            for entry in try fm.contentsOfDirectory(atPath: bundled.path) where entry != ".venv" {
                try fm.copyItem(
                    at: bundled.appendingPathComponent(entry),
                    to: target.appendingPathComponent(entry))
            }
            NSLog("Velora: synced bundled engine (build %@) → %@",
                  bundledStamp ?? "unstamped", target.path)
            return target
        } catch {
            NSLog("Velora: failed to sync bundled engine: \(error)")
            return nil
        }
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
