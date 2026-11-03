#!/usr/bin/env python3
"""Isolated signed-app E2E with real bundled models and synthetic audio.

This is a local macOS Seatbelt sandbox, NOT a clean macOS VM. It does not
exercise the physical microphone, global hotkeys or external-app AX grants.
Requires a local (harness-enabled) ./scripts/make-app.sh debug|release none.
Weights must be seeded locally. Network remains available for bootstrap;
HF Hub SDK offline mode is requested, not an OS-level network fence.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/Velora.app"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    if not (app / "Contents/Resources/Models/bark-3.0/velora-bundle.json").is_file():
        parser.error("build a local signed app with its included English model first")
    root = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="velora-sandbox-e2e-"))
    home = Path.home().resolve()
    if root == home or home in root.parents:
        parser.error("output must be outside the real home so its write fence stays effective")
    if args.output:
        root.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(root, 0o700)
    copy = root / "Velora.app"
    shutil.copytree(app, copy, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(copy)], check=True)

    denied = [home / ".velora", home / "Library/Application Support/Velora",
              home / ".cache/huggingface", home / ".netrc", home / ".huggingface"]
    profile = root / "sandbox.sb"
    lines = ["(version 1)", "(allow default)",
             '(deny file-write* (subpath %s))' % json.dumps(str(home)),
             '(deny file-write* (subpath %s))' % json.dumps(str(copy))]
    lines += ['(deny file-read* (subpath %s))' % json.dumps(str(path)) for path in denied]
    profile.write_text("\n".join(lines) + "\n")
    env = {"HOME": str(home), "USER": os.environ.get("USER", ""),
           # Keep scratch-home socket paths below Darwin AF_UNIX limits.
           "TMPDIR": "/tmp/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "UV_NO_CONFIG": "1"}
    prefix = ["/usr/bin/sandbox-exec", "-f", str(profile)]
    # Opening for append does not write or truncate; this proves the fence
    # without risking the contents even if sandbox-exec were ineffective.
    probe = """import os,errno,sys
try:
 f=os.open(sys.argv[1],os.O_WRONLY|os.O_APPEND)
except OSError as e:
 assert e.errno in (errno.EPERM,errno.EACCES),e
else:
 os.close(f);raise SystemExit('write fence ineffective')
"""
    # A writable, disposable control prevents filesystem permissions from
    # masquerading as a sandbox denial. Never open a live preference for write.
    with tempfile.NamedTemporaryFile(dir=home, prefix=".velora-sandbox-write-probe-") as control:
        fd = os.open(control.name, os.O_WRONLY | os.O_APPEND)
        os.close(fd)
        subprocess.run(prefix + ["/usr/bin/python3", "-c", probe, control.name],
                       check=True, env=env)
    source = root / "speech.aiff"
    wave = root / "speech.wav"
    subprocess.run(["/usr/bin/say", "-o", str(source),
                    "The quick brown fox jumps over the lazy dog."], check=True)
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@22050", "-c", "1",
                    str(source), str(wave)], check=True)
    report = root / "report.json"
    command = prefix + [str(copy / "Contents/MacOS/Velora"), "--sandbox-e2e", str(wave), str(report)]
    print("Evidence:", root, flush=True)
    started = time.monotonic()
    with (root / "app.log").open("wb") as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            status = process.wait(timeout=1200)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Foundation gives the uv child a separate process group. Kill it
            # before the app, but only with a lease AND live kernel parentage.
            # ps is usable here (outside Seatbelt); argv is never authority.
            try:
                lease = json.loads((root / "owned-process.json").read_text())
                group = lease.get("engine_group")
                if lease.get("owner_pid") == process.pid and isinstance(group, int) and group > 1:
                    parent = subprocess.check_output(
                        ["/bin/ps", "-p", str(group), "-o", "ppid="], text=True).strip()
                    if (parent == str(process.pid) and process.poll() is None
                            and os.getpgid(group) == group and group != os.getpgrp()):
                        os.killpg(group, signal.SIGKILL)
            except (OSError, ValueError, subprocess.CalledProcessError):
                pass
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise SystemExit("sandbox E2E interrupted/timed out; evidence retained at " + str(root))
    summary = json.loads(report.read_text()) if report.exists() else {"passed": False, "error": "no report"}
    summary["sandbox"] = {"kind": "macOS Seatbelt, not a VM", "write_fence_verified": True,
                          "live_product_state_read_denied": [str(path) for path in denied],
                          "hf_hub_offline_requested": True, "network_fenced": False,
                          "fresh_venv_requested": True,
                          "wall_s": round(time.monotonic() - started, 3)}
    report.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    os.chmod(report, 0o600)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(copy)], check=True)
    print(json.dumps(summary, indent=2))
    return 0 if status == 0 and summary.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
