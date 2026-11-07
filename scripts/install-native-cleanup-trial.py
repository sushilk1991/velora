#!/usr/bin/env python3
"""Install the pinned personal trial kit without changing Velora's selection."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "model.gguf": "ec3710cf3bc12c0fbdfcf24587e5f87a2bf197f4c3129d390052af67e3d1a666",
    "velora-cleanup-native": "6b5ab148f586b881d27577f5a61a5dafa551d1a24edb140213c29321ec044a3c",
    "supervise.py": "fd06b212cff24db00b855265dfae20b403623a15a379ef1e72eec39e106e0b02",
}
PACKAGE_NAME = "lfm3-native-v1"


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        value = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()


def verify(path: Path, expected: str) -> None:
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"Expected a regular file: {path}")
    if digest(path) != expected:
        raise ValueError(f"SHA256 mismatch: {path}")


def install(model: Path, binary: Path, supervisor: Path, *, home: Path,
            model_license: Path | None = None) -> Path:
    """Publish one immutable, verified directory, or leave the old one intact."""
    sources = {"model.gguf": model, "velora-cleanup-native": binary,
               "supervise.py": supervisor}
    parent = home / "experimental"
    if parent.is_symlink():
        raise ValueError("Experimental package directory must not be a symlink")
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = parent / PACKAGE_NAME
    with (parent / ".install-native-cleanup.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name, source in sources.items():
            verify(source, PINS[name])
        manifest = {
            "schema": 1, "checkpoint": "G", "model_sha256": PINS["model.gguf"],
            "binary_sha256": PINS["velora-cleanup-native"],
            "supervisor_sha256": PINS["supervise.py"],
            "model_bytes": model.stat().st_size,
            "base_revision": "4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099",
            "adapter_sha256": "a5b141b7e5b261f04f5888d7943bd2a0c2c6d1e3de7e32a0df10040a390c2dd4",
            "llama_commit": "4b77dee0524c64b8471869232e2958bd9589607d",
            "quality_qualified": False,
        }
        if destination.exists() or destination.is_symlink():
            try:
                if destination.is_symlink():
                    raise ValueError("symlink destination")
                if json.loads((destination / "manifest.json").read_text()) != manifest:
                    raise ValueError("manifest mismatch")
                for name, expected in PINS.items():
                    verify(destination / name, expected)
            except (OSError, ValueError) as exc:
                raise ValueError("Refusing to replace an existing invalid trial package") from exc
            return destination
        stage = Path(tempfile.mkdtemp(prefix=".native-trial-", dir=parent))
        try:
            for name, source in sources.items():
                # copyfile uses the platform's fast copy where available.
                shutil.copyfile(source, stage / name)
                verify(stage / name, PINS[name])
                (stage / name).chmod(0o555 if name == "velora-cleanup-native" else 0o444)
            license_path = model_license or model.parent / "hf/LICENSE"
            if license_path.is_file():
                shutil.copyfile(license_path, stage / "LICENSE.model")
            elif model_license is not None:
                raise ValueError("Requested model license file is missing")
            shutil.copyfile(ROOT / "native/cleanup/LICENSE.llama.cpp", stage / "LICENSE.llama.cpp")
            (stage / "NOTICE").write_text(
                "Velora personal experimental English cleanup, checkpoint G.\n"
                "Model: LiquidAI LFM3 1.7B, LFM Open License v1.0; "
                "local adapter and Q4_K_M conversion.\n"
                "Runtime: independently authored Velora loop over MIT llama.cpp/ggml.\n"
                "The JSON dependency is nlohmann/json (MIT); minja is MIT.\n"
                "Model and runtime licenses are distinct. This kit is not quality-qualified.\n"
            )
            (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            for path in stage.iterdir():
                if path.name != "velora-cleanup-native":
                    path.chmod(0o444)
            os.rename(stage, destination)
            return destination
        finally:
            if stage.exists():
                shutil.rmtree(stage)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--model-license", type=Path, required=True)
    parser.add_argument("--supervisor", type=Path, default=ROOT / "native/cleanup/supervise.py")
    parser.add_argument("--home", type=Path,
                        default=Path(os.environ.get("VELORA_HOME", str(Path.home() / ".velora"))))
    args = parser.parse_args()
    os.umask(0o077)
    destination = install(args.model.expanduser(), args.binary.expanduser(),
                          args.supervisor.expanduser(), home=args.home.expanduser(),
                          model_license=args.model_license.expanduser())
    print(json.dumps({"installed": str(destination), "checkpoint": "G", "enabled": False}))


if __name__ == "__main__":
    main()
