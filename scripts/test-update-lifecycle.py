#!/usr/bin/env python3
"""Exercise private updater wiring without starting AppKit or speech models."""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROBE_TIMEOUT_S = 5


def _closure_after(source, marker):
    start = source.index("{", source.index(marker) + len(marker))
    depth = 0
    for end in range(start, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start : end + 1]
    raise ValueError("Unclosed updater callback")


class UpdateLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="velora-update-test-")
        cls.addClassCleanup(cls.scratch.cleanup)
        scratch = Path(cls.scratch.name)
        delegate = (ROOT / "Sources/Velora/App/AppDelegate.swift").read_text()
        installer = (ROOT / "Sources/Velora/App/UpdateInstaller.swift").read_text()
        gate = _closure_after(
            delegate, "UpdateInstaller.shared.relaunchBlockReason ="
        )
        restart = _closure_after(delegate, "private func restartBlockReason()")
        policy = _closure_after(delegate, "enum UpdateRelaunchSafety")
        tool_run = _closure_after(installer, "private static func run(")
        quit_install = _closure_after(installer, "func installOnExit()")
        quit_hook = _closure_after(installer, "func installOnQuitIfReady()")
        prepare = _closure_after(installer, "private func performInstallAndRelaunch()")
        prepare = prepare[: prepare.index("        workQueue.async")] + "}"
        exit_version = (
            _closure_after(installer, "private var exitInstallVersion:")
            if "private var exitInstallVersion:" in installer else "{ nil }"
        )
        start = installer.index(
            "                    self.installAndRelaunchWhenReady = false\n"
            "                    guard self.spawnHelper("
        )
        end = installer.index(
            "\n                }\n                RunLoop.main.add", start
        )
        quit_body = installer[start:end]
        # Keep the production callback intact; shorten only its deadline so
        # a blocked quit is a bounded, model-free process test.
        quit_body, deadlines = re.subn(
            r"deadline: \.now\(\) \+ [^\n]+",
            "deadline: .now() + 0.05",
            quit_body,
        )
        assert deadlines == 1
        source = scratch / "probe.swift"
        source.write_text(
            """import Foundation
import Darwin
final class UpdateInstaller {
    static let shared = UpdateInstaller()
    var relaunchBlockReason: (() -> String?)?
}
final class GateOwner {
    var reason: String?
    func restartBlockReason() -> String? { reason }
    func connect() {
        UpdateInstaller.shared.relaunchBlockReason = """
            + gate
            + """
    }
}
final class Application {
    func terminate(_ sender: Any?) { Thread.sleep(forTimeInterval: 60) }
}
let NSApp = Application()
func veloraLog(_ message: String) { print(message) }
enum UpdateRelaunchSafety """
            + policy
            + """
final class Activity {
    var hasUserOperationInFlight = false
    var isTranscribing = false
    var foregroundCaptureActive = false
    var terminationWorkInFlight = false
}
struct Queue { var pendingURLs: [URL] = [] }
final class RestartOwner {
    let dictation = Activity()
    let transcriber = Activity()
    let meetingCoordinator = Activity()
    var openFileTranscriptionQueue = Queue()
    var openFileRetryPending = false
    var terminationPending = false
    func restartBlockReason() -> String? """
            + restart
            + """
}
enum ToolOwner {
    private static let toolTerminationGrace: TimeInterval = 0.05
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval)
        -> (status: Int32, output: String) """
            + tool_run
            + """
}
final class QuitOwner {
    var installAndRelaunchWhenReady = true
    func spawnHelper(staged: URL, version: String, relaunch: Bool) -> Bool { true }
    func requestQuit() {
        let staged = URL(fileURLWithPath: "/unused-staged-app")
        let version = "1.2.3"
"""
            + quit_body
            + """
    }
}
final class ExitOwner {
    enum State { case ready(version: String), installing, idle, failed(String) }
    var state = State.ready(version: "1.2.3")
    var helperSpawned = false
    var installingVersion: String?
    var installAndRelaunchWhenReady = true
    var generation = 0
    var spawned = false
    var relaunched = false
    static func installBlocker() -> String? { nil }
    static func stagedURL(for version: String) -> URL {
        URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(version)
    }
    private var exitInstallVersion: String? """
            + exit_version
            + """
    func spawnHelper(staged: URL, version: String, relaunch: Bool) -> Bool {
        spawned = true
        relaunched = relaunch
        return true
    }
    func installOnExit() """
            + quit_install
            + """
    func prepare() """
            + prepare
            + """
    func installOnQuitIfReady() """
            + quit_hook
            + """
}
final class AppConfig {
    static let shared = AppConfig()
    let autoInstallUpdates = false
    let skippedUpdateVersion: String? = nil
    let deferredUpdateVersion: String? = nil
    let deferredUpdateUntil = Date.distantPast
}
enum UpdatePromptPolicy {
    static func allowsAutomaticInstall(version: String, skippedVersion: String?) -> Bool { false }
}
switch CommandLine.arguments[1] {
case "idle", "busy", "gone":
    var owner: GateOwner? = GateOwner()
    owner?.connect()
    switch CommandLine.arguments[1] {
    case "idle":
        guard UpdateInstaller.shared.relaunchBlockReason?() == nil else { exit(1) }
    case "busy":
        owner?.reason = "Recording a meeting"
        guard UpdateInstaller.shared.relaunchBlockReason?() == owner?.reason else { exit(1) }
    default:
        owner = nil
        guard UpdateInstaller.shared.relaunchBlockReason?() != nil else { exit(1) }
    }
case "stalled-quit":
    QuitOwner().requestQuit()
    exit(1)
case "queued", "retry", "quitting":
    let owner = RestartOwner()
    if CommandLine.arguments[1] == "queued" {
        owner.openFileTranscriptionQueue.pendingURLs = [URL(fileURLWithPath: "/unused.wav")]
    } else if CommandLine.arguments[1] == "retry" {
        owner.openFileRetryPending = true
    } else {
        owner.terminationPending = true
    }
    guard owner.restartBlockReason() != nil else { exit(1) }
case "early-eof":
    let result = ToolOwner.run("/bin/sh", ["-c", "exec 1>&- 2>&-; exec /bin/sleep 0.7"], timeout: 0.05)
    guard result.status != 0 else { exit(1) }
case "descendant":
    let marker = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("tool-descendant")
    let args = ["-c", "(trap '' TERM; /bin/sleep 0.7; : > \\\"$1\\\") & /bin/sleep 0.03; exit 0", "probe", marker.path]
    let normal = ToolOwner.run("/bin/sh", args, timeout: 2)
    guard normal.status == 0 && FileManager.default.fileExists(atPath: marker.path) else { exit(1) }
    try FileManager.default.removeItem(at: marker)
    let result = ToolOwner.run("/bin/sh", args, timeout: 0.05)
    Thread.sleep(forTimeInterval: 0.8)
    guard result.status != 0 && !FileManager.default.fileExists(atPath: marker.path) else { exit(1) }
case "quit-verifying":
    let owner = ExitOwner()
    try FileManager.default.createDirectory(at: ExitOwner.stagedURL(for: "1.2.3"), withIntermediateDirectories: true)
    owner.prepare()
    owner.installOnQuitIfReady()
    guard owner.spawned && !owner.relaunched else { exit(1) }
default: exit(2)
}
"""
        )
        cls.probe = scratch / "probe"
        subprocess.run(
            ["xcrun", "swiftc", str(source), "-o", str(cls.probe)], check=True
        )

    def _run_probe(self, scenario):
        result = subprocess.run(
            [str(self.probe), scenario, self.scratch.name], capture_output=True, text=True,
            timeout=PROBE_TIMEOUT_S,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_idle_update_can_restart(self):
        self._run_probe("idle")

    def test_busy_update_waits(self):
        self._run_probe("busy")

    def test_missing_app_blocks(self):
        self._run_probe("gone")

    def test_stalled_quit_is_bounded(self):
        self._run_probe("stalled-quit")

    def test_queued_files_block(self):
        self._run_probe("queued")

    def test_pending_retry_blocks(self):
        self._run_probe("retry")

    def test_quit_prevents_relaunch(self):
        self._run_probe("quitting")

    def test_tool_eof_is_not_exit(self):
        self._run_probe("early-eof")

    def test_quit_keeps_install(self):
        self._run_probe("quit-verifying")

    def test_tool_reaps_descendants(self):
        self._run_probe("descendant")

    def test_helper_kills_stuck_tool(self):
        source = (ROOT / "Sources/Velora/App/UpdateInstaller.swift").read_text()
        body = _closure_after(source, "    run_to()")
        result = subprocess.run(
            ["/bin/sh", "-c", "TOOL_TIMEOUT=0.05; TERMINATION_GRACE=0.05\nrun_to() " + body
             + "\nrun_to /bin/sh -c \"trap '' TERM; exec /bin/sleep 0.7\""],
            capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
        )
        self.assertEqual(result.returncode, 137, result.stderr)

    def test_helper_reaps_descendants(self):
        source = (ROOT / "Sources/Velora/App/UpdateInstaller.swift").read_text()
        body = _closure_after(source, "    run_to()")
        marker = Path(self.scratch.name) / "helper-descendant"
        result = subprocess.run(
            ["/bin/sh", "-c", "TOOL_TIMEOUT=0.05; TERMINATION_GRACE=0.05\nrun_to() "
             + body + '\nrun_to /bin/sh -c \'trap "" TERM; (/bin/sleep 0.7; : > "$1") & wait\' probe "$1"',
             "probe", str(marker)],
            capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
        )
        self.assertEqual(result.returncode, 137, result.stderr)
        self.assertFalse(marker.exists(), "A descendant survived tool timeout")

    def test_helper_reaps_orphans(self):
        source = (ROOT / "Sources/Velora/App/UpdateInstaller.swift").read_text()
        body = _closure_after(source, "    run_to()")
        marker = Path(self.scratch.name) / "helper-orphan"
        result = subprocess.run(
            ["/bin/sh", "-c", "TOOL_TIMEOUT=0.05; TERMINATION_GRACE=0.05\nrun_to() "
             + body + '\nrun_to /bin/sh -c \'(trap "" TERM; /bin/sleep 0.7; : > "$1") & wait\' probe "$1"',
             "probe", str(marker)],
            capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
        )
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertFalse(marker.exists(), "A child survived after its parent terminated")


if __name__ == "__main__":
    unittest.main()
