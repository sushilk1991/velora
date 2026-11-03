"""Remove only Velora-owned inactive model copies, under their writer locks.

Never remove shared Hub repos, imported user paths, or signed app resources.
The server/coordinator fences acquisitions and active inference first.
"""
from __future__ import annotations

import fcntl
import json
import shutil
from contextlib import ExitStack
from pathlib import Path

from .config import velora_home
from .download_cache import _Cache


def _remove_tree(path: Path) -> int:
    if path.is_symlink():
        raise ValueError("refusing a symlinked model directory")
    if not path.exists():
        return 0
    size = sum(file.lstat().st_size for file in path.rglob("*")
               if file.is_file() and not file.is_symlink())
    shutil.rmtree(path)
    return size


def remove_owned(model: str, cache_root: Path, home: Path | None = None) -> int:
    """Caller excludes active models and acquisition jobs for this ID.

    Writer locks remain on disk. A competing process holding any required
    lock causes refusal before mutation. Manifest paths never become targets:
    only direct children of fixed Velora cache roots can be removed.
    """
    from .models import lookup, bark_spec
    if lookup(model) is None or Path(model).is_absolute():
        raise ValueError("only registered Velora model copies can be removed")
    spec = bark_spec(model)
    cache = _Cache(cache_root, model)
    home = home or velora_home()
    roots = [
        (home / "quant-cache", ".build.lock", "velora-quant.json"),
    ]
    if spec is not None:
        roots += [
            (home / "bark-cache", ".build.lock", "velora-bark.json"),
            (home / "bark-coreml-cache", ".compile.lock", "velora-bark-coreml.json"),
            (home / "bundled-models", ".import.lock", "velora-bundled-import.json"),
        ]
    with ExitStack() as stack:
        stack.enter_context(cache._lock())
        targets = []
        for root, lock_name, marker_name in roots:
            if root.is_symlink():
                raise ValueError("refusing a symlinked cache root")
            root.mkdir(mode=0o700, parents=True, exist_ok=True)
            lock_path = root / lock_name
            if lock_path.is_symlink():
                raise ValueError("refusing a symlinked cache lock")
            lock = stack.enter_context(lock_path.open("a"))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for path in root.iterdir():
                if path.is_symlink() or not path.is_dir():
                    continue
                marker = path / marker_name
                if marker.is_symlink():
                    continue
                try:
                    manifest = json.loads(marker.read_text())
                except (OSError, ValueError):
                    continue
                if not isinstance(manifest, dict):
                    continue
                identity = manifest.get("identity", manifest)
                if not isinstance(identity, dict):
                    continue
                matches = (marker_name == "velora-quant.json"
                           and identity.get("format") == "velora-quant"
                           and identity.get("model_id") == model)
                if spec is not None and marker_name != "velora-quant.json":
                    matches = (identity.get("repo") == spec.repo
                               and identity.get("variant", identity.get("key")) == spec.key)
                if matches:
                    targets.append(path)
        # Validate all fixed owned paths before the first mutation.
        for name in ("snapshots", "partials", "manifests", "current.json", "repair.json"):
            cache._guard(cache._base / name)
        freed = 0
        for name in ("snapshots", "partials", "manifests"):
            freed += _remove_tree(cache._base / name)
        for name in ("current.json", "repair.json"):
            (cache._base / name).unlink(missing_ok=True)
        for target in targets:
            freed += _remove_tree(target)
        return freed
