#!/usr/bin/env python3
"""Download a pinned Bark model bundle for packaging, verified file by file.

    scripts/prepare-bundled-model.py --output build/bundled-models
    scripts/prepare-bundled-model.py --output DIR --model bark-3.0 --model bark-3.0-ane --json
    scripts/prepare-bundled-model.py --output DIR --verify-only

Each model lands in <output>/<key>/ with its files at their repository paths,
plus velora-bundle.json (the manifest the importer checks). Only the files
pinned in engine/src/velora_engine/bundled_models.py are fetched, anonymously
over HTTPS, from the pinned revision. Every byte is size- and SHA-256-checked
while it streams. A bundle directory appears only after all its files verify.
The script prints each bundle's attribution (its NOTICE) and manifest path.
Ship both.

Model weights never go into Git: an output inside this repository must be
git-ignored (build/ is), or the script refuses to run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "engine" / "src"))

from velora_engine import bundled_models as bm  # noqa: E402

USER_AGENT = "velora-prepare-bundled-model/1"
TIMEOUT_S = 60
ATTEMPTS = 3
_CHUNK = 1 << 20


class PrepareError(RuntimeError):
    pass


def _open_url(url: str):
    """The only network call. Anonymous: no token or cookie is ever sent."""
    if not url.startswith("https://"):
        raise PrepareError(f"refusing non-HTTPS URL {url}")
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(request, timeout=TIMEOUT_S)


def _download(model: bm.BundledModel, pinned: bm.PinnedFile, dst: Path,
              opener: Callable[[str], Any]) -> None:
    """Stream one pinned file to `dst`; raise unless it matches the pin."""
    last: Optional[Exception] = None
    for attempt in range(ATTEMPTS):
        if dst.exists():
            dst.unlink()
        try:
            digest = hashlib.sha256()
            size = 0
            with opener(model.download_url(pinned)) as response, open(dst, "xb") as out:
                while True:
                    block = response.read(_CHUNK)
                    if not block:
                        break
                    size += len(block)
                    if size > pinned.size:
                        raise bm.BundleIntegrityError(
                            f"{pinned.path}: more than the pinned {pinned.size} bytes")
                    digest.update(block)
                    out.write(block)
            if size != pinned.size or digest.hexdigest() != pinned.sha256:
                raise bm.BundleIntegrityError(
                    f"{pinned.path}: got {size} bytes sha256 {digest.hexdigest()}, "
                    f"pinned {pinned.size} {pinned.sha256}")
            return
        except bm.BundleIntegrityError:
            raise  # a wrong byte stream is not transient: stop
        except OSError as exc:  # network errors, truncated reads
            last = exc
            time.sleep(min(2 ** attempt, 5))
    raise PrepareError(f"download of {pinned.path} failed: {last}")


def _inside_repo_unignored(path: Path) -> bool:
    try:
        path.resolve().relative_to(REPO_ROOT)
    except ValueError:
        return False
    probe = path.resolve()
    result = subprocess.run(["git", "-C", str(REPO_ROOT), "check-ignore", "-q", str(probe)],
                            check=False, capture_output=True)
    return result.returncode != 0


def _is_ours(directory: Path) -> bool:
    try:
        manifest = json.loads((directory / bm.BUNDLE_MANIFEST).read_text())
    except (OSError, ValueError):
        return False
    return isinstance(manifest, dict) and manifest.get("format") == "velora-bundle"


def _bundle_ok(directory: Path, model: bm.BundledModel) -> bool:
    if not (directory / bm.BUNDLE_MANIFEST).is_file():
        return False
    try:
        bm.check_bundle_manifest(directory, model)
        bm.verify_tree(directory, model)
    except bm.BundledModelError:
        return False
    return True


def _report(directory: Path, model: bm.BundledModel, reused: bool) -> Dict[str, Any]:
    return {
        "key": model.key,
        "repo": model.repo,
        "revision": model.revision,
        "path": str(directory),
        "manifest": str(directory / bm.BUNDLE_MANIFEST),
        "total_bytes": model.total_size,
        "files": [{"path": f.path, "size": f.size, "sha256": f.sha256} for f in model.files],
        "license": model.license,
        "license_url": model.license_url,
        "attribution": bm.read_attribution(directory, model),
        "reused": reused,
    }


def prepare(key: str, output: Path, opener: Callable[[str], Any] = _open_url) -> Dict[str, Any]:
    """Make <output>/<key> a verified bundle and return its report."""
    model = bm.lookup(key)
    output.mkdir(parents=True, exist_ok=True)
    final = output / model.key
    if _bundle_ok(final, model):
        return _report(final, model, reused=True)
    if os.path.lexists(final) and not _is_ours(final):
        raise PrepareError(f"{final} exists and is not a Velora bundle; left untouched")

    temp = Path(tempfile.mkdtemp(prefix=f".{model.key}.tmp-", dir=output))
    try:
        for pinned in model.files:
            dst = temp / pinned.path
            dst.parent.mkdir(parents=True, exist_ok=True)
            _download(model, pinned, dst, opener)
        (temp / bm.BUNDLE_MANIFEST).write_text(
            json.dumps(bm.bundle_manifest(model), indent=2) + "\n")
        bm.verify_tree(temp, model)  # re-read from disk before publishing
        os.chmod(temp, 0o755)
        if os.path.lexists(final):  # ours, but incomplete or stale
            shutil.rmtree(final)
        bm.rename_no_replace(temp, final)
    finally:
        if temp.exists():
            shutil.rmtree(temp, ignore_errors=True)
    return _report(final, model, reused=False)


def verify(key: str, output: Path) -> Dict[str, Any]:
    model = bm.lookup(key)
    final = output / model.key
    bm.check_bundle_manifest(final, model)
    if not (final / bm.BUNDLE_MANIFEST).is_file():
        raise bm.BundleIntegrityError(f"{final} has no {bm.BUNDLE_MANIFEST}")
    bm.verify_tree(final, model)
    return _report(final, model, reused=True)


def main(argv: Optional[List[str]] = None, opener: Callable[[str], Any] = _open_url) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", required=True, type=Path,
                        help="directory to hold <key>/ bundles (outside Git, or git-ignored)")
    parser.add_argument("--model", action="append", choices=sorted(bm.BUNDLED_MODELS),
                        help="bundle to prepare; repeatable (default: bark-3.0)")
    parser.add_argument("--verify-only", action="store_true",
                        help="verify existing bundles; no network")
    parser.add_argument("--json", action="store_true", help="print a JSON report")
    args = parser.parse_args(argv)
    keys = args.model or [bm.BARK_3.key]
    output = args.output.expanduser()
    if _inside_repo_unignored(output):
        parser.error(f"{output} is inside the repository and not git-ignored; "
                     "model weights must not be committed (use build/...)")
    try:
        reports = [verify(k, output) if args.verify_only else prepare(k, output, opener)
                   for k in keys]
    except (bm.BundledModelError, PrepareError, KeyError) as exc:
        print(f"prepare-bundled-model: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps({"bundles": reports}, indent=2))
    else:
        for report in reports:
            state = "verified (existing)" if report["reused"] else "downloaded and verified"
            print(f"{report['key']}: {state} at {report['path']} "
                  f"({report['total_bytes']} bytes, {report['repo']}@{report['revision']})")
            print(f"  manifest: {report['manifest']}")
            print(f"  license: {report['license']} {report['license_url']}")
            print("  attribution:")
            for line in report["attribution"].rstrip().splitlines():
                print(f"    {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
