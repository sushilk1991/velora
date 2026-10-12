"""Velora-owned cache; Hub blobs and other downloaders are never mutated."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import uuid
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath

_HASH_CHUNK = 1024 * 1024
_REVISION_RE = re.compile(r"[0-9a-f]{40}")


@dataclass(frozen=True)
class _File:
    name: str
    size: int
    digest: str
    algorithm: str


@dataclass(frozen=True)
class _Manifest:
    model: str
    revision: str
    files: tuple[_File, ...]


class _ManifestError(ValueError):
    def __init__(self, paths: tuple[Path, ...], revision: str | None = None):
        super().__init__("owned manifest invalid; reconnect and retry to rebuild metadata")
        self.paths = paths
        self.revision = revision


def _cache_root() -> Path:
    from huggingface_hub.constants import HF_HUB_CACHE

    return Path(HF_HUB_CACHE) / ".velora-downloads"


def _check_manifest(spec: _Manifest) -> None:
    # Immutable commit ids and relative file names bound every filesystem operation.
    if not _REVISION_RE.fullmatch(spec.revision) or not spec.files:
        raise ValueError("invalid manifest revision or empty files")
    from .models import (TRANSCRIBE_CPP_Q8_MODEL, TRANSCRIBE_CPP_Q8_REVISION,
                         TRANSCRIBE_CPP_Q8_SHA256, _SINGLE_FILE_MODELS)

    # The experimental artifact keeps its audited digest even in owned manifests.
    if spec.model == TRANSCRIBE_CPP_Q8_MODEL:
        expected = _SINGLE_FILE_MODELS[spec.model]
        if (spec.revision != TRANSCRIBE_CPP_Q8_REVISION or len(spec.files) != 1
                or spec.files[0].name != expected or spec.files[0].algorithm != "sha256"
                or spec.files[0].digest != TRANSCRIBE_CPP_Q8_SHA256):
            raise ValueError("pinned Q8 manifest mismatch")
    names = set()
    for file in spec.files:
        path = PurePosixPath(file.name)
        if (path.is_absolute() or ".." in path.parts or not path.parts
                or "\\" in file.name or file.name in names):
            raise ValueError("invalid manifest file path")
        names.add(file.name)
        length = 64 if file.algorithm == "sha256" else 40
        if (file.algorithm not in ("sha256", "git-sha1") or file.size < 0
                or not re.fullmatch(f"[0-9a-f]{{{length}}}", file.digest)):
            raise ValueError("invalid manifest file identity")


def _file_valid(path: Path, file: _File) -> bool:
    # Git stores the object header in its SHA-1; LFS hashes only file contents.
    try:
        if path.stat().st_size != file.size:
            return False
        digest = hashlib.sha256() if file.algorithm == "sha256" else hashlib.sha1()
        if file.algorithm == "git-sha1":
            digest.update(f"blob {file.size}\0".encode())
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(_HASH_CHUNK), b""):
                digest.update(chunk)
        return digest.hexdigest() == file.digest
    except OSError:
        return False


class _Cache:
    def __init__(self, root: Path, model: str):
        self._root = Path(root).resolve()
        self._model = model
        self._base = self._root / hashlib.sha256(model.encode()).hexdigest()

    def _guard(self, path: Path) -> Path:
        # Refuse symlink traversal even within owned state; never follow deletion escapes.
        path.relative_to(self._root)
        for entry in (path, *path.parents):
            if entry == self._root:
                break
            if entry.is_symlink():
                raise ValueError("symlink in owned cache")
        return path

    @contextmanager
    def _lock(self):
        # Engine -> worker -> flock -> manifest/partial/promotion; OS releases on death.
        self._guard(self._base).mkdir(parents=True, exist_ok=True)
        path = self._guard(self._base / "owner.lock")
        with path.open("a+b") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def _atomic_json(self, path: Path, value: dict) -> None:
        self._guard(path).parent.mkdir(parents=True, exist_ok=True)
        temp = self._guard(path.with_name(path.name + ".tmp"))
        with temp.open("w") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)

    def _save_manifest(self, spec: _Manifest) -> None:
        _check_manifest(spec)
        if spec.model != self._model:
            raise ValueError("manifest model mismatch")
        path = self._guard(self._base / "manifests" / (spec.revision + ".json"))
        value = asdict(spec)
        # Round trip normalizes the tuple before comparing immutable identities.
        value = json.loads(json.dumps(value))
        if path.exists():
            try:
                existing = self._read_manifest(path, spec.revision)
            except _ManifestError as error:
                # A malformed orphan at this exact resolved revision is repairable;
                # a valid immutable document with different identity is not.
                self._quarantine(error)
                existing = None
            if existing is not None and existing != spec:
                raise ValueError("immutable manifest changed")
        if not path.exists():
            self._atomic_json(path, value)
        self._atomic_json(self._base / "current.json", {"revision": spec.revision})
        self._guard(self._base / "repair.json").unlink(missing_ok=True)

    def _read_manifest(self, path: Path, revision: str) -> _Manifest:
        self._guard(path)
        try:
            value = json.loads(path.read_text())
            spec = _Manifest(value["model"], value["revision"], tuple(
                _File(**item) for item in value["files"]))
            _check_manifest(spec)
            if spec.model != self._model or spec.revision != revision:
                raise ValueError("manifest identity mismatch")
            return spec
        except (ValueError, KeyError, TypeError, AttributeError):
            raise _ManifestError((path,), revision) from None

    def _manifest(self) -> _Manifest | None:
        current = self._guard(self._base / "current.json")
        if not current.exists():
            repair = self._guard(self._base / "repair.json")
            if not repair.exists():
                return None
            # Persist the repair reason across worker/engine restarts. Missing
            # normal state is not corruption; quarantined state still needs repair.
            try:
                revision = json.loads(repair.read_text())["revision"]
                if revision is not None and not _REVISION_RE.fullmatch(revision):
                    revision = None
            except (ValueError, KeyError, TypeError):
                revision = None
            raise _ManifestError((), revision)
        try:
            revision = json.loads(current.read_text())["revision"]
            if not isinstance(revision, str) or not _REVISION_RE.fullmatch(revision):
                raise ValueError("invalid current revision")
        except (ValueError, KeyError, TypeError):
            raise _ManifestError((current,)) from None
        path = self._guard(self._base / "manifests" / (revision + ".json"))
        try:
            return self._read_manifest(path, revision)
        except FileNotFoundError:
            raise _ManifestError((current,), revision) from None
        except _ManifestError as error:
            raise _ManifestError((*error.paths, current), revision) from None

    def _quarantine(self, error: _ManifestError) -> None:
        # Caller holds the process lock. Preserve invalid named metadata documents,
        # never model bytes or unknown files; a repair marker survives interruption.
        self._atomic_json(self._base / "repair.json", {"revision": error.revision})
        destination = self._guard(self._base / "quarantine")
        destination.mkdir(parents=True, exist_ok=True)
        for path in error.paths:
            allowed = path == self._base / "current.json"
            manifest_name = re.fullmatch(r"[0-9a-f]{40}\.json", path.name)
            if not allowed and not (path.parent == self._base / "manifests" and manifest_name):
                raise ValueError("refusing to quarantine unowned metadata")
            self._guard(path)
            if not path.exists():
                continue
            target = self._guard(destination / (uuid.uuid4().hex + ".json"))
            path.replace(target)

    def _has_corruption(self, spec: _Manifest) -> bool:
        # Missing files/short partials are ordinary interruption. Only invalid
        # completed files or invalid fully received/oversized partials prove damage.
        for file in spec.files:
            complete = self._complete(spec, file)
            if complete.exists() and not _file_valid(complete, file):
                return True
            partial = self._partial(spec, file)
            if not partial.exists():
                continue
            size = partial.stat().st_size
            if size > file.size or (size == file.size and not _file_valid(partial, file)):
                return True
        return False

    def _complete(self, spec: _Manifest, file: _File) -> Path:
        _check_manifest(spec)
        _check_manifest(_Manifest(spec.model, spec.revision, (file,)))
        return self._guard(self._base / "snapshots" / spec.revision / file.name)

    def _partial(self, spec: _Manifest, file: _File) -> Path:
        _check_manifest(spec)
        _check_manifest(_Manifest(spec.model, spec.revision, (file,)))
        return self._guard(self._base / "partials" / spec.revision / (file.name + ".part"))

    def _identity_path(self, spec: _Manifest, file: _File) -> Path:
        return self._guard(self._partial(spec, file).with_suffix(".identity.json"))

    def _identity(self, spec: _Manifest, file: _File, etag: str) -> dict:
        return {"revision": spec.revision, "file": asdict(file), "etag": etag}

    def _save_identity(self, spec: _Manifest, file: _File, etag: str) -> None:
        self._atomic_json(self._identity_path(spec, file), self._identity(spec, file, etag))

    def _same_identity(self, spec: _Manifest, file: _File, etag: str) -> bool:
        try:
            value = json.loads(self._identity_path(spec, file).read_text())
            return value == self._identity(spec, file, etag)
        except (OSError, ValueError):
            return False

    def _cached(self) -> tuple[str, _Manifest] | None:
        spec = self._manifest()
        if spec is None:
            return None
        for file in spec.files:
            if not _file_valid(self._complete(spec, file), file):
                return None
        path = self._base / "snapshots" / spec.revision
        from .models import _SINGLE_FILE_MODELS

        filename = _SINGLE_FILE_MODELS.get(spec.model)
        return str(path / filename if filename else path), spec

    def _bytes(self, spec: _Manifest) -> int:
        # Count one storage object per file: completed file OR owned partial, never both.
        total = 0
        seen = set()
        for file in spec.files:
            path = self._complete(spec, file)
            if not path.exists():
                path = self._partial(spec, file)
            try:
                stat = path.stat()
                identity = (stat.st_dev, stat.st_ino)
                if identity in seen:
                    continue
                seen.add(identity)
                total += min(stat.st_size, file.size)
            except FileNotFoundError:
                continue
        return total

    def _discard(self, spec: _Manifest, file: _File) -> None:
        self._partial(spec, file).unlink(missing_ok=True)
        self._identity_path(spec, file).unlink(missing_ok=True)

    def _restart(self) -> None:
        # Caller holds the model lock after the old worker has exited. Only this
        # manifest's named incomplete files are removed; complete files are retained.
        self._guard(self._base / "partials")
        spec = self._manifest()
        if spec is None:
            return
        for file in spec.files:
            self._discard(spec, file)
