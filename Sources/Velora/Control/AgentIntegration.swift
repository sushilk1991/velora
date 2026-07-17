import Foundation

/// Closes the local-agent loop. The CLI ships inside the bundle
/// (`Contents/Resources/bin/velora`), but an agent can only use what is on
/// PATH and documented — so Settings offers two one-click installs: a
/// `velora` symlink into a PATH directory, and a Claude Code skill that
/// tells agents where to look and what they may ask for.
enum AgentIntegration {
    /// The bundled CLI entry point (a symlink back into the app binary).
    static var bundledCLI: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/velora")
    }

    // MARK: - CLI on PATH

    /// Candidate install directories, best first. Homebrew's bin is
    /// user-writable on Apple Silicon and already on every brew user's PATH;
    /// `~/.local/bin` is the personal-bin convention (created on demand, and
    /// the skill documents the full path so agents find it either way).
    static func candidateBinDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    /// True when the entry at `path` is a symlink we own — one that resolves
    /// into a Velora bundle. The install path may only ever replace these.
    static func isVeloraLink(_ path: String) -> Bool {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: path) else { return false }
        let resolved = destination.hasPrefix("/")
            ? destination
            : (path as NSString).deletingLastPathComponent + "/" + destination
        return resolved.contains("Velora.app/Contents/")
    }

    /// Where a Velora-owned `velora` link already exists in a candidate
    /// directory. A foreign `velora` binary is deliberately NOT reported as
    /// installed — install must never claim (or clobber) someone else's tool.
    static func installedCLIPath() -> String? {
        for dir in candidateBinDirectories() {
            let path = dir.appendingPathComponent("velora").path
            if isVeloraLink(path) { return path }
        }
        return nil
    }

    enum InstallError: LocalizedError {
        case missingBundledCLI
        case noWritableDirectory
        case foreignFile(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledCLI:
                return "This build has no bundled CLI (run from the installed app)"
            case .noWritableDirectory:
                return "No writable install directory (tried /opt/homebrew/bin, /usr/local/bin, ~/.local/bin)"
            case .foreignFile(let path):
                return "A different “velora” already exists at \(path) — remove or rename it first"
            }
        }
    }

    /// Symlinks the bundled CLI into the first writable candidate directory
    /// and returns the resulting path. Only a symlink that provably points
    /// into a Velora bundle is ever replaced; any other existing `velora`
    /// (review catch: could have been a different product's binary or even a
    /// directory) fails the install with its path instead of being deleted.
    @discardableResult
    static func installCLI() throws -> String {
        guard let cli = bundledCLI,
              FileManager.default.fileExists(atPath: cli.path) else {
            throw InstallError.missingBundledCLI
        }
        let fm = FileManager.default
        var conflict: String?
        for dir in candidateBinDirectories() {
            if !fm.fileExists(atPath: dir.path) {
                // Only the personal dir is worth creating; making
                // /usr/local/bin would need admin rights anyway.
                guard dir.path.hasSuffix("/.local/bin") else { continue }
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: dir.path) else { continue }
            let link = dir.appendingPathComponent("velora")
            var exists = fm.fileExists(atPath: link.path)
            // A dangling symlink (e.g. to a deleted Velora.app) reports as
            // nonexistent above but still blocks link creation.
            if !exists {
                exists = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
            }
            if exists {
                guard isVeloraLink(link.path) else {
                    conflict = conflict ?? link.path
                    continue
                }
                try? fm.removeItem(at: link)
            }
            do {
                try fm.createSymbolicLink(at: link, withDestinationURL: cli)
                return link.path
            } catch {
                continue
            }
        }
        if let conflict { throw InstallError.foreignFile(conflict) }
        throw InstallError.noWritableDirectory
    }

    // MARK: - Agent skill

    /// Claude Code user-skill location; other agents can be pointed at the
    /// same file.
    static var skillDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/velora", isDirectory: true)
    }

    static func skillInstalled() -> Bool {
        FileManager.default.fileExists(
            atPath: skillDirectory.appendingPathComponent("SKILL.md").path)
    }

    /// Writes the skill and returns its path.
    @discardableResult
    static func installSkill() throws -> String {
        let dir = skillDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        let cliPath = installedCLIPath()
            ?? bundledCLI?.path
            ?? "/Applications/Velora.app/Contents/Resources/bin/velora"
        let version = (Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        try skillMarkdown(cliPath: cliPath, version: version)
            .write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// The skill body — pure so the selftest can pin what agents are told.
    static func skillMarkdown(cliPath: String, version: String) -> String {
        """
        ---
        name: velora
        description: >
          Query the user's Velora dictation app (local-first, on-device): recent
          dictation transcripts, history search, usage stats, or transcribing an
          audio file. Use when the user asks about their dictations, dictation
          history/stats, or wants a local audio file transcribed.
        ---

        # Velora local control

        Velora is a local-first macOS dictation app. It exposes a deliberately
        small, allow-listed control surface for local CLIs and agents. Nothing
        leaves the machine; raw audio, screen context, contacts, and learning
        data are never exposed.

        ## Requirements

        - The Velora app must be running (menubar waveform icon).
        - "Allow local CLI and agents" must be ON in Velora Settings → General →
          Advanced. When it is off, `velora status` still answers (it reports
          `access_enabled: false`) but every other call fails with
          `access_disabled` — tell the user to flip the toggle rather than
          retrying.

        ## CLI

        Installed at: `\(cliPath)`
        (Always bundled at `/Applications/Velora.app/Contents/Resources/bin/velora`.)

        | Command | What it returns |
        |---|---|
        | `velora status` | app/engine readiness and whether access is enabled |
        | `velora recent [--limit N]` | newest dictation transcripts |
        | `velora search <query> [--limit N]` | full-text history search |
        | `velora stats` | words, dictations, streaks, time saved |
        | `velora transcribe <audio-file>` | transcript of a local audio file |
        | `velora listen` | one live dictation — shows a visible approval prompt first |

        Add `--json` to any command for machine-readable output. Results are
        capped (100 rows, 20k transcript chars per row).

        ## MCP

        `velora mcp` serves the same capabilities over MCP stdio
        (protocol 2025-06-18). Register it, e.g. for Claude Code:

        ```bash
        claude mcp add velora -- "\(cliPath)" mcp
        ```

        ## Direct socket (advanced)

        Newline-delimited JSON over the owner-only Unix socket
        `~/.velora/control.sock`:
        `{"version":1,"id":"<any>","command":"recent","arguments":{"limit":5}}`

        ## Notes for agents

        - `listen` blocks until the user approves or dismisses the prompt —
          never call it without telling the user to expect the dialog.
        - History rows are the user's private dictations: quote them back to
          the user freely, but do not send them to other services without an
          explicit instruction.

        <!-- Written by Velora \(version); reinstall from Settings → General →
             Advanced after major updates to refresh paths. -->
        """
    }
}
