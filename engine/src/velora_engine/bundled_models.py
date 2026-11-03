"""Pinned Underdog Bark 3.0 artifacts and the local bundled-model importer.

Every Bark artifact Velora can load is pinned here: Hub repository, revision,
and the size and SHA-256 of each file. ``bark.py`` identifies a source
directory against these pins. ``scripts/prepare-bundled-model.py`` downloads
exactly these files. :func:`import_bundled_model` copies a shipped bundle into
the user's model store.

    app bundle (read-only)                  ~/.velora/bundled-models
    <bundle>/model.bark ──verify──▶ clone ──▶ .bark-3.0@85db2ad18ab4.tmp-x/
    <bundle>/mlx/config.json                     │ verify the copy's hash
                                                 ▼ rename, no replace
                                           bark-3.0@85db2ad18ab4/

The importer is local-only. It contains no network code. It verifies the
copy, not the source, so a source file swapped between check and copy
cannot be published. It clones on APFS (copy-on-write, no extra disk) and
falls back to a streamed copy. It publishes with one no-replace rename under
an advisory lock. It never overwrites or deletes a file it did not create.
A directory in the way that lacks Velora's import marker is left alone and
reported as a conflict.

License: the weights and the vendored loaders are CC BY 4.0. The attribution
(each repo's NOTICE) and the license text travel with every bundle and import.
The Clean repository ships no LICENSE file, so its license text comes from the
main repository's identical CC BY 4.0 legal code
(``Resources/ModelNotices/CC-BY-4.0.LICENSE``).

This module uses only the standard library and stays Python 3.9 compatible,
because the packaging script imports it outside the engine venv.
"""

from __future__ import annotations

import ctypes
import errno
import fcntl
import hashlib
import json
import os
import shutil
import stat
import tempfile
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, Optional, Tuple, Union
from urllib.parse import quote

BUNDLE_MANIFEST = "velora-bundle.json"  # written by prepare-bundled-model.py
IMPORT_MANIFEST = "velora-bundled-import.json"  # marker in each import
FORMAT_VERSION = 1
_CHUNK = 8 << 20

CancelToken = Union[Callable[[], bool], threading.Event, None]


class BundledModelError(RuntimeError):
    """Base class for bundle verification and import failures."""


class BundleIntegrityError(BundledModelError):
    """A file is missing, not a regular file, or its size or hash differs."""


class BundledModelConflict(BundledModelError):
    """The destination exists and Velora did not create it."""


class BundleImportCancelled(BundledModelError):
    """The caller cancelled the import; nothing was published."""


@dataclass(frozen=True)
class PinnedFile:
    path: str  # repository-relative path, also the path inside a bundle
    size: int
    sha256: str


@dataclass(frozen=True)
class BundledModel:
    key: str
    repo: str
    revision: str
    runtime: str  # "mlx" | "coreml"
    # Leading silence prepended before decoding: the setting upstream
    # evaluated (0.25 s for Bark 3.0, none for Clean; see each repo's loader).
    pad_s: float
    files: Tuple[PinnedFile, ...]
    notice: str  # path of the attribution NOTICE among `files`
    license: str = "CC-BY-4.0"
    license_url: str = "https://creativecommons.org/licenses/by/4.0/"

    def file(self, path: str) -> PinnedFile:
        for pinned in self.files:
            if pinned.path == path:
                return pinned
        raise KeyError(f"{self.key} pins no file {path!r}")

    @property
    def total_size(self) -> int:
        return sum(f.size for f in self.files)

    def download_url(self, pinned: PinnedFile) -> str:
        return (f"https://huggingface.co/{self.repo}/resolve/{self.revision}/"
                f"{quote(pinned.path)}")

    def identity(self) -> Dict[str, Any]:
        """The JSON identity a bundle or an import must carry verbatim."""
        return {
            "key": self.key,
            "repo": self.repo,
            "revision": self.revision,
            "runtime": self.runtime,
            "license": self.license,
            "files": [{"path": f.path, "size": f.size, "sha256": f.sha256}
                      for f in self.files],
        }


BARK_REPO = "ConwayResearch/Underdog-Bark-3.0"
BARK_REVISION = "85db2ad18ab41e534a222ee253c29191d77ed919"
BARK_CLEAN_REPO = "ConwayResearch/Underdog-Bark-3.0-Clean"
BARK_CLEAN_REVISION = "6d34ed8639b2b9a33e764acf06748519bbb950cf"

# Sizes and hashes were read from the pinned revisions on 2026-11-03. LFS
# files: the Hub's lfs.sha256. Small files: SHA-256 of the bytes served at
# the revision, cross-checked against the Hub's git blob ids.
_CONFIG = PinnedFile(
    "mlx/config.json", 237042,
    "86efced0e9b34101990175e6e94f0d34a3ba251bb4f1a86a1e77b9ce77e26eee")
_BARK_NOTICE = PinnedFile(
    "NOTICE", 603,
    "7760825e72004ccf97f7a8b63a75e2890105a7cae8ca875b70d4df78cff9abcd")
_BARK_LICENSE = PinnedFile(
    "coreml/LICENSE", 18657,
    "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411")

BARK_3 = BundledModel(
    key="bark-3.0",
    repo=BARK_REPO,
    revision=BARK_REVISION,
    runtime="mlx",
    pad_s=0.25,
    files=(
        PinnedFile("model.bark", 163398645,
                   "c18de9418d73cbeb80b8c1287b392d480a56e191ef4a81d1baaa1b02e66d92ed"),
        _CONFIG,
        _BARK_NOTICE,
        _BARK_LICENSE,
    ),
    notice="NOTICE",
)

BARK_3_CLEAN = BundledModel(
    key="bark-3.0-clean",
    repo=BARK_CLEAN_REPO,
    revision=BARK_CLEAN_REVISION,
    runtime="mlx",
    pad_s=0.0,
    files=(
        PinnedFile("model.bark", 179458613,
                   "b67ca90d94b79a36af4616f1cb3f241884925de7aa9f3e673a8d5c6c4cfd3436"),
        _CONFIG,
        PinnedFile("NOTICE", 615,
                   "4e627d41fa10efedd84a7dbb915711b0b73c904af1fee8bacdd4a2387bcc5a10"),
    ),
    notice="NOTICE",
)

ANE_DIR = "coreml/ane"
BARK_3_ANE = BundledModel(
    key="bark-3.0-ane",
    repo=BARK_REPO,
    revision=BARK_REVISION,
    runtime="coreml",
    pad_s=0.25,
    files=(
        PinnedFile(f"{ANE_DIR}/BarkEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                   1784701,
                   "7c3f1c1612ba21bcc4d8efff1b32154b39cb3e1e2f10020117793acc5c96fcdf"),
        PinnedFile(f"{ANE_DIR}/BarkEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                   189133632,
                   "98979e5dd731486ddfb2c312f80a3038205c058aac9fe0f403ba26e1a158d385"),
        PinnedFile(f"{ANE_DIR}/BarkEncoder.mlpackage/Manifest.json", 617,
                   "d37c121561b99da49b9bf1e28c00152c14c56a943815fa83008ee0691b8f1149"),
        PinnedFile(f"{ANE_DIR}/decoder.npz", 11168286,
                   "1ce79071f54c3dcec9aa9bb1d488486766f1fdbb3fd988b776da3f4da8024665"),
        PinnedFile(f"{ANE_DIR}/vocab.json", 115878,
                   "eee86951e9f74921342fdc60ba26711eb70f7188e8784d98d2aecfc525b72270"),
        PinnedFile("coreml/NOTICE", 603, _BARK_NOTICE.sha256),
        _BARK_LICENSE,
    ),
    notice="coreml/NOTICE",
)

BUNDLED_MODELS: Dict[str, BundledModel] = {
    m.key: m for m in (BARK_3, BARK_3_CLEAN, BARK_3_ANE)
}


def lookup(key: str) -> BundledModel:
    try:
        return BUNDLED_MODELS[key]
    except KeyError:
        raise KeyError(f"unknown bundled model {key!r}; "
                       f"known: {', '.join(sorted(BUNDLED_MODELS))}") from None


# --- hashing and verification -------------------------------------------------


def is_cancelled(cancel: CancelToken) -> bool:
    if cancel is None:
        return False
    if isinstance(cancel, threading.Event):
        return cancel.is_set()
    return bool(cancel())


def sha256_file(path: Union[str, Path], cancel: CancelToken = None) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            if is_cancelled(cancel):
                raise BundleImportCancelled(f"cancelled while hashing {path}")
            block = handle.read(_CHUNK)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def _regular_file_size(path: Path, follow_symlinks: bool) -> int:
    try:
        info = path.stat() if follow_symlinks else path.lstat()
    except FileNotFoundError:
        raise BundleIntegrityError(f"missing {path}") from None
    if not stat.S_ISREG(info.st_mode):
        raise BundleIntegrityError(f"{path} is not a regular file")
    return info.st_size


def verify_file(path: Union[str, Path], pinned: PinnedFile, *,
                follow_symlinks: bool = False,
                cancel: CancelToken = None) -> None:
    """Raise BundleIntegrityError unless `path` is exactly `pinned`.

    Size is checked first, so a wrong file costs no hashing.
    """
    path = Path(path)
    size = _regular_file_size(path, follow_symlinks)
    if size != pinned.size:
        raise BundleIntegrityError(
            f"{path}: {size} bytes, pinned {pinned.size}")
    actual = sha256_file(path, cancel)
    if actual != pinned.sha256:
        raise BundleIntegrityError(
            f"{path}: sha256 {actual}, pinned {pinned.sha256}")


def verify_tree(root: Union[str, Path], model: BundledModel, *,
                follow_symlinks: bool = False,
                cancel: CancelToken = None) -> None:
    """Verify every pinned file of `model` under `root`."""
    root = Path(root)
    for pinned in model.files:
        verify_file(root / pinned.path, pinned,
                    follow_symlinks=follow_symlinks, cancel=cancel)


def read_attribution(root: Union[str, Path], model: BundledModel) -> str:
    """The NOTICE text that must accompany `model` wherever it is shipped."""
    return (Path(root) / model.notice).read_text(encoding="utf-8")


# --- APFS clone, no-replace rename, locking -----------------------------------

_CLONE_NOFOLLOW = 0x0001
_CLONE_NOOWNERCOPY = 0x0002
_RENAME_EXCL = 0x0004
_libc: Any = None


def _libc_function(name: str) -> Optional[Callable[..., int]]:
    global _libc
    try:
        if _libc is None:
            _libc = ctypes.CDLL(None, use_errno=True)
        function = getattr(_libc, name)
    except (OSError, AttributeError):
        return None
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    return function


def _clonefile(src: Path, dst: Path) -> bool:
    """APFS copy-on-write clone; False when unsupported here (copy instead)."""
    clonefile = _libc_function("clonefile")
    if clonefile is None:
        return False
    flags = _CLONE_NOFOLLOW | _CLONE_NOOWNERCOPY
    if clonefile(os.fsencode(src), os.fsencode(dst), flags) == 0:
        return True
    # EXDEV (another volume), ENOTSUP (not APFS), and anything else: the
    # streamed copy either works or raises the real error.
    if os.path.lexists(dst):
        os.unlink(dst)
    return False


def _copy_hashing(src: Path, dst: Path, cancel: CancelToken) -> str:
    digest = hashlib.sha256()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with open(src, "rb") as reader, os.fdopen(os.open(dst, flags, 0o600), "wb") as writer:
        while True:
            if is_cancelled(cancel):
                raise BundleImportCancelled(f"cancelled while copying {src}")
            block = reader.read(_CHUNK)
            if not block:
                break
            digest.update(block)
            writer.write(block)
        writer.flush()
        os.fsync(writer.fileno())
    return digest.hexdigest()


def _clone_or_copy(src: Path, dst: Path, pinned: PinnedFile,
                   cancel: CancelToken) -> str:
    """Materialize `src` at `dst` and prove `dst` matches the pin.

    The hash is always of bytes that reach `dst` (the clone itself, or the
    stream that was written), so a source replaced after its check cannot
    slip through.
    """
    if _clonefile(src, dst):
        method = "clone"
        size = _regular_file_size(dst, follow_symlinks=False)
        actual = sha256_file(dst, cancel) if size == pinned.size else None
    else:
        method = "copy"
        actual = _copy_hashing(src, dst, cancel)
        size = _regular_file_size(dst, follow_symlinks=False)
    if size != pinned.size or actual != pinned.sha256:
        raise BundleIntegrityError(
            f"{src}: copied {size} bytes sha256 {actual}, "
            f"pinned {pinned.size} {pinned.sha256}")
    return method


def rename_no_replace(src: Path, dst: Path) -> None:
    """Atomically rename; raise FileExistsError rather than replace `dst`.

    os.rename would silently replace an empty directory at `dst`.
    renamex_np(RENAME_EXCL) makes the existence check and the rename one
    step. Elsewhere, an existence check under the caller's lock stands in.
    """
    renamex = _libc_function("renamex_np")
    if renamex is not None:
        if renamex(os.fsencode(src), os.fsencode(dst), _RENAME_EXCL) == 0:
            return
        err = ctypes.get_errno()
        if err == errno.EEXIST:
            raise FileExistsError(err, os.strerror(err), str(dst))
        if err not in (errno.ENOTSUP, errno.EINVAL, getattr(errno, "EOPNOTSUPP", -1)):
            raise OSError(err, os.strerror(err), str(dst))
    if os.path.lexists(dst):
        raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), str(dst))
    os.rename(src, dst)


@contextmanager
def exclusive_lock(path: Path) -> Iterator[None]:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(path, "a") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


# --- bundle manifests ---------------------------------------------------------


def bundle_manifest(model: BundledModel) -> Dict[str, Any]:
    """The manifest a prepared bundle carries next to its files."""
    return {
        "format": "velora-bundle",
        "version": FORMAT_VERSION,
        **model.identity(),
        "notice": model.notice,
        "license_url": model.license_url,
    }


def check_bundle_manifest(bundle_dir: Path, model: BundledModel) -> None:
    """A bundle manifest is optional; when present it must name these pins."""
    path = bundle_dir / BUNDLE_MANIFEST
    if not os.path.lexists(path):
        return
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise BundleIntegrityError(f"unreadable {path}: {exc}") from None
    if manifest != bundle_manifest(model):
        raise BundleIntegrityError(
            f"{path} does not describe {model.key}@{model.revision}")


# --- importer -----------------------------------------------------------------


def bundled_import_root(home: Optional[Path] = None) -> Path:
    if home is None:
        from .config import velora_home  # lazy: keeps the script stdlib-only

        home = velora_home()
    return Path(home) / "bundled-models"


def import_dir_name(model: BundledModel) -> str:
    return f"{model.key}@{model.revision[:12]}"


def _import_manifest(model: BundledModel) -> Dict[str, Any]:
    return {"format": "velora-bundled-import", "version": FORMAT_VERSION,
            **model.identity()}


def _read_marker(directory: Path) -> Optional[Dict[str, Any]]:
    path = directory / IMPORT_MANIFEST
    try:
        if not stat.S_ISREG(path.lstat().st_mode):
            return None
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(manifest, dict) or manifest.get("format") != "velora-bundled-import":
        return None
    return manifest


def _published_ok(directory: Path, model: BundledModel, cancel: CancelToken) -> bool:
    try:
        if not stat.S_ISDIR(directory.lstat().st_mode):
            return False
    except FileNotFoundError:
        return False
    marker = _read_marker(directory)
    if marker is None:
        return False
    recorded = dict(marker)
    recorded.pop("imported", None)
    if recorded != _import_manifest(model):
        return False
    try:
        verify_tree(directory, model, cancel=cancel)
    except BundleIntegrityError:
        return False
    return True


def import_bundled_model(bundle_dir: Union[str, Path], key: str, *,
                         dest_root: Optional[Path] = None,
                         cancel: CancelToken = None) -> Path:
    """Copy the shipped bundle `key` into the user's model store.

    Returns the published directory. It holds the pinned files at their
    repository paths, so it is a valid ``source_dir`` for ``bark.load_bark``
    (MLX variants) or ``bark.load_bark_coreml`` (the ANE variant).

    Idempotent: a complete, verified import is returned as is. Raises
    BundleIntegrityError when the bundle does not match its pins,
    BundledModelConflict when a directory Velora did not create is in the way,
    and BundleImportCancelled when `cancel` fires. Every failure leaves
    nothing published and removes its temporary directory.
    """
    if "://" in str(bundle_dir):
        raise ValueError("bundled models import from local paths only")
    model = lookup(key)
    bundle_dir = Path(bundle_dir)
    if not bundle_dir.is_dir():
        raise BundleIntegrityError(f"bundle {bundle_dir} is not a directory")
    root = Path(dest_root) if dest_root is not None else bundled_import_root()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    final = root / import_dir_name(model)
    if _published_ok(final, model, cancel):
        return final

    check_bundle_manifest(bundle_dir, model)
    with exclusive_lock(root / ".import.lock"):
        if _published_ok(final, model, cancel):
            return final
        if os.path.lexists(final):
            if _read_marker(final) is None:
                raise BundledModelConflict(
                    f"{final} exists and was not created by Velora; left untouched")
            # Ours, but incomplete or modified since: set it aside, never
            # delete it (it may hold a user's edits).
            aside = final.with_name(f"{final.name}.stale-{time.time_ns()}")
            os.rename(final, aside)
        for stale in root.glob(f".{final.name}.tmp-*"):
            shutil.rmtree(stale, ignore_errors=True)  # a killed import's leftovers

        temp = Path(tempfile.mkdtemp(prefix=f".{final.name}.tmp-", dir=root))
        try:
            methods: Dict[str, str] = {}
            for pinned in model.files:
                if is_cancelled(cancel):
                    raise BundleImportCancelled(f"import of {key} cancelled")
                src = bundle_dir / pinned.path
                size = _regular_file_size(src, follow_symlinks=False)
                if size != pinned.size:
                    raise BundleIntegrityError(
                        f"{src}: {size} bytes, pinned {pinned.size}")
                dst = temp / pinned.path
                dst.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                methods[pinned.path] = _clone_or_copy(src, dst, pinned, cancel)
                os.chmod(dst, 0o444)
            manifest = _import_manifest(model)
            manifest["imported"] = {"at": int(time.time()), "methods": methods}
            marker = temp / IMPORT_MANIFEST
            with open(marker, "w", encoding="utf-8") as handle:
                json.dump(manifest, handle, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp, 0o755)
            if is_cancelled(cancel):
                raise BundleImportCancelled(f"import of {key} cancelled")
            try:
                rename_no_replace(temp, final)
            except FileExistsError:
                raise BundledModelConflict(
                    f"{final} appeared during import; left untouched") from None
            _fsync_dir(root)
            return final
        finally:
            if temp.exists():
                shutil.rmtree(temp, ignore_errors=True)
