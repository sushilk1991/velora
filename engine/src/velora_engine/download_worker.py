"""One cancellable process performs metadata, HTTP streaming and verification."""
from __future__ import annotations

import errno
import json
import os
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path
from http import HTTPStatus

from .download_cache import _Cache, _File, _Manifest, _file_valid

_METADATA_S = 60
_READ_S = 60
_STREAM_CHUNK = 64 * 1024
_RANGE_REQUEST_LIMIT = 2
_AUTH_STATUS = {HTTPStatus.UNAUTHORIZED, HTTPStatus.FORBIDDEN}
_RETRY_STATUS = {
    HTTPStatus.REQUEST_TIMEOUT, HTTPStatus.TOO_MANY_REQUESTS,
    HTTPStatus.INTERNAL_SERVER_ERROR, HTTPStatus.BAD_GATEWAY,
    HTTPStatus.SERVICE_UNAVAILABLE, HTTPStatus.GATEWAY_TIMEOUT,
}
_DISK_ERRNOS = {errno.ENOSPC, errno.EDQUOT, errno.EACCES, errno.EROFS, errno.EIO}


def _classify(error: Exception) -> dict:
    # Messages are deliberately fixed: exception text can contain tokens/signed URLs.
    category, code, message, retryable = "network", "network_error", "Connection interrupted. Retry the download.", True
    status = getattr(getattr(error, "response", None), "status_code", None)
    if isinstance(error, urllib.error.HTTPError):
        status = error.code
    if status in _AUTH_STATUS:
        category, code, message, retryable = "auth", "access_denied", "Model access denied. Check Hugging Face access.", False
    elif status is not None and status not in _RETRY_STATUS:
        category, code, message, retryable = "network", "http_error", "Model request rejected. Retry or check model availability.", False
    elif isinstance(error, BlockingIOError):
        category, code, message, retryable = "cache", "download_locked", "Another process owns this model download. Retry after it exits.", False
    elif isinstance(error, OSError) and error.errno in _DISK_ERRNOS:
        category, code, message, retryable = "disk", "disk_error", "Cannot write model files. Check free space and cache permissions.", False
    elif isinstance(error, ValueError):
        category, code, message, retryable = "verification", "cache_integrity", "Model files are missing or corrupt. Reconnect and retry to repair.", False
    return {"category": category, "code": code, "message": message, "retryable": retryable}


def _progress(cache, spec, emit, *, state="downloading", resume="none"):
    emit({"event": "progress", "state": state, "revision": spec.revision,
          "bytes_received": cache._bytes(spec), "bytes_total": sum(f.size for f in spec.files),
          "resume": resume})


def _etag_value(etag: str) -> str:
    if not etag or etag.startswith("W/") or any(char in etag for char in '\r\n"'):
        return ""
    return '"' + etag + '"'


def _range_valid(response, offset: int, file: _File, etag: str) -> bool:
    # Accept only exact inclusive offsets/total and a matching strong identity.
    expected = f"bytes {offset}-{file.size - 1}/{file.size}"
    return (response.status == HTTPStatus.PARTIAL_CONTENT
            and response.headers.get("Content-Range") == expected
            and response.headers.get("ETag") == _etag_value(etag)
            and response.headers.get("Content-Encoding", "identity") == "identity"
            and response.headers.get("Content-Length") == str(file.size - offset))


def _promote(cache, spec, file, emit, resume):
    part = cache._partial(spec, file)
    if not part.exists() or part.stat().st_size != file.size:
        raise ConnectionError("incomplete body")
    _progress(cache, spec, emit, state="verifying", resume=resume)
    if not _file_valid(part, file):
        cache._discard(spec, file)
        raise ValueError("file verification failed")
    complete = cache._complete(spec, file)
    complete.parent.mkdir(parents=True, exist_ok=True)
    part.replace(complete)
    cache._identity_path(spec, file).unlink(missing_ok=True)
    _progress(cache, spec, emit, state="verifying", resume=resume)


def _transfer_file(cache, spec, file, url, etag, emit):
    part = cache._partial(spec, file)
    complete = cache._complete(spec, file)
    # Corrupt owned completions must not mask partial-byte progress during repair.
    if complete.exists() and not _file_valid(complete, file):
        complete.unlink()
    part.parent.mkdir(parents=True, exist_ok=True)
    offset = part.stat().st_size if part.exists() else 0
    resume = "none"
    if offset and (offset > file.size or not _etag_value(etag)
                   or not cache._same_identity(spec, file, etag)):
        cache._discard(spec, file)
        offset, resume = 0, "file_restarted"
    if offset:
        resume = "partial"
    cache._save_identity(spec, file, etag)
    # Retained bytes are real, but partial resume is not established until the
    # Range response has passed identity/offset checks (or a full partial hashes).
    _progress(cache, spec, emit, resume=resume if not offset else "none")
    # A fully received partial still needs hashing, but no HTTP request or 416.
    if offset == file.size and part.exists():
        _promote(cache, spec, file, emit, resume)
        return

    # At most one safe fallback GET, not a hidden retry budget. A rejected Range
    # discards only this owned partial, then downloads the file from byte zero.
    for _ in range(_RANGE_REQUEST_LIMIT):
        headers = {"Accept-Encoding": "identity"}
        if offset:
            headers.update({"Range": f"bytes={offset}-", "If-Range": _etag_value(etag)})
        request = urllib.request.Request(url, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=_READ_S)
        except urllib.error.HTTPError as error:
            if error.code != HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE or not offset:
                raise
            error.close()
            cache._discard(spec, file)
            offset, resume = 0, "file_restarted"
            cache._save_identity(spec, file, etag)
            _progress(cache, spec, emit, resume=resume)
            continue
        with response:
            if offset and not _range_valid(response, offset, file, etag):
                cache._discard(spec, file)
                offset, resume = 0, "file_restarted"
                cache._save_identity(spec, file, etag)
                _progress(cache, spec, emit, resume=resume)
                continue
            if not offset and (response.status != HTTPStatus.OK
                               or response.headers.get("Content-Encoding", "identity") != "identity"):
                raise ValueError("invalid full response")
            _progress(cache, spec, emit, resume=resume)
            # read1 exposes short body fragments immediately; a blocked read is
            # bounded by the parent's byte-stall watchdog, not worker heartbeats.
            with part.open("ab" if offset else "wb", buffering=0) as handle:
                while True:
                    chunk = response.read1(_STREAM_CHUNK)
                    if not chunk:
                        break
                    if handle.tell() + len(chunk) > file.size:
                        raise ValueError("body exceeds manifest size")
                    view = memoryview(chunk)
                    while view:
                        written = handle.write(view)
                        if not written:
                            raise OSError(errno.EIO, "partial file write failed")
                        view = view[written:]
                    _progress(cache, spec, emit, resume=resume)
                # Persist data before atomic promotion; relaunch still rehashes it.
                handle.flush()
                os.fsync(handle.fileno())
            break
    _promote(cache, spec, file, emit, resume)


def _resolve_manifest(model: str, revision: str | None) -> _Manifest:
    from huggingface_hub import HfApi
    from .models import (_SINGLE_FILE_MODELS, _SINGLE_FILE_REVISIONS,
                         TRANSCRIBE_CPP_Q8_MODEL, TRANSCRIBE_CPP_Q8_SHA256)

    # Public Hub API provides immutable commit and both Git and LFS digests.
    revision = _SINGLE_FILE_REVISIONS.get(model, revision)
    info = HfApi().model_info(model, revision=revision, files_metadata=True, timeout=_METADATA_S)
    files = []
    selected = _SINGLE_FILE_MODELS.get(model)
    for sibling in info.siblings:
        if selected and sibling.rfilename != selected:
            continue
        if sibling.size is None:
            raise ValueError("missing file size")
        digest = sibling.lfs.sha256 if sibling.lfs else sibling.blob_id
        algorithm = "sha256" if sibling.lfs else "git-sha1"
        if model == TRANSCRIBE_CPP_Q8_MODEL and digest != TRANSCRIBE_CPP_Q8_SHA256:
            raise ValueError("pinned Q8 digest mismatch")
        files.append(_File(sibling.rfilename, sibling.size, digest, algorithm))
    return _Manifest(model, info.sha, tuple(files))


def _import_hub(cache, spec, emit):
    from huggingface_hub import hf_hub_download, snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError
    from .models import _SINGLE_FILE_MODELS

    # Import verified completed legacy files, without deleting/replacing Hub state.
    try:
        filename = _SINGLE_FILE_MODELS.get(spec.model)
        if filename:
            source = Path(hf_hub_download(spec.model, filename, revision=spec.revision, local_files_only=True)).parent
        else:
            source = Path(snapshot_download(spec.model, revision=spec.revision, local_files_only=True))
    except LocalEntryNotFoundError:
        return
    for file in spec.files:
        complete = cache._complete(spec, file)
        if _file_valid(complete, file) or not _file_valid(source / file.name, file):
            continue
        complete.parent.mkdir(parents=True, exist_ok=True)
        temp = cache._guard(complete.with_name(complete.name + ".import"))
        shutil.copyfile(source / file.name, temp)
        if not _file_valid(temp, file):
            temp.unlink()
            raise ValueError("import verification failed")
        temp.replace(complete)
        _progress(cache, spec, emit, state="verifying", resume="completed_files")


def _local_bytes(path: Path) -> int:
    seen = set()
    total = 0
    paths = [path] if path.is_file() else path.rglob("*")
    for entry in paths:
        if not entry.is_file():
            continue
        stat = entry.stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity in seen:
            continue
        seen.add(identity)
        total += stat.st_size
    return total


def _run(model: str, root: Path, restart: bool, emit):
    from huggingface_hub import get_hf_file_metadata, hf_hub_url
    from .models import _legacy_cached, _SINGLE_FILE_REVISIONS

    # Explicit user paths retain their existing loading semantics, not Hub trust.
    local = Path(model).expanduser()
    if local.exists():
        emit({"event": "progress", "state": "verifying", "revision": None,
              "bytes_received": _local_bytes(local), "bytes_total": None, "resume": "none"})
        return str(local.resolve()), None
    cache = _Cache(root, model)
    with cache._lock():
        if restart:
            cache._restart()
        saved = cache._manifest()
        if saved:
            _progress(cache, saved, emit, state="verifying")
            cached = cache._cached()
            if cached:
                _progress(cache, saved, emit, state="verifying", resume="completed_files")
                return cached[0], saved.revision
        # Existing installed models remain offline-usable after backend-required
        # artifact checks. Their legacy check is not whole-repository verification.
        emit({"event": "phase", "state": "verifying"})
        damaged = saved is not None
        try:
            legacy = _legacy_cached(model)
        except ValueError:
            damaged, legacy = True, None
        if legacy:
            path = Path(legacy)
            revision = _SINGLE_FILE_REVISIONS.get(model, path.name)
            emit({"event": "progress", "state": "verifying", "revision": revision,
                  "bytes_received": _local_bytes(path), "bytes_total": None, "resume": "completed_files"})
            return legacy, revision
        emit({"event": "phase", "state": "metadata"})
        try:
            spec = _resolve_manifest(model, saved.revision if saved else None)
        except Exception as error:
            # Corrupt installed artifacts plus unavailable metadata must not appear
            # as a usable offline model or an unexplained connection failure.
            if damaged and _classify(error)["category"] == "network":
                raise ValueError("cached model integrity failed; reconnect to repair") from None
            raise
        cache._save_manifest(spec)
        _progress(cache, spec, emit, state="verifying")
        _import_hub(cache, spec, emit)
        for file in spec.files:
            _progress(cache, spec, emit, state="verifying")
            if _file_valid(cache._complete(spec, file), file):
                _progress(cache, spec, emit, resume="completed_files")
                continue
            emit({"event": "phase", "state": "metadata"})
            url = hf_hub_url(model, file.name, revision=spec.revision)
            metadata = get_hf_file_metadata(url, timeout=_METADATA_S)
            if metadata.commit_hash != spec.revision or metadata.size != file.size:
                raise ValueError("metadata identity changed")
            # Resolve on every attempt; expiring locations never enter persisted state.
            _transfer_file(cache, spec, file, metadata.location, metadata.etag or "", emit)
        _progress(cache, spec, emit, state="verifying")
        cached = cache._cached()
        if not cached:
            raise ValueError("snapshot verification failed")
        return cached[0], spec.revision


def _main():
    def emit(value):
        print(json.dumps(value), flush=True)

    # stdout is the private JSON protocol; stderr is never persisted or sent to UI.
    try:
        model, root, restart = sys.argv[1:]
        path, revision = _run(model, Path(root), restart == "restart", emit)
        emit({"event": "result", "path": path, "revision": revision})
    except Exception as error:
        emit({"event": "error", "error": _classify(error)})
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
