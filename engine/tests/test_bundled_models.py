"""Pinned Bark artifacts, the local bundled-model importer, and the packaging
script. Offline: fake models with tiny files stand in for the pinned weights."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import re
import socket
import stat
import sys
import threading
from pathlib import Path

import pytest

from velora_engine import bundled_models as bm

REPO = Path(__file__).resolve().parents[2]
NOTICES = REPO / "Resources" / "ModelNotices"
VENDOR = REPO / "engine" / "src" / "velora_engine" / "vendor_bark"


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


FAKE_FILES = {
    "model.bark": b"packed weights " * 4096,
    "mlx/config.json": b'{"fake": true}\n',
    "NOTICE": b"Fake model NOTICE: attribution text\n",
}


def _fake_model(key: str = "fake-model", files: dict[str, bytes] = FAKE_FILES) -> bm.BundledModel:
    return bm.BundledModel(
        key=key, repo="Example/Fake-Model", revision="a" * 40, runtime="mlx", pad_s=0.25,
        files=tuple(bm.PinnedFile(p, len(d), _sha(d)) for p, d in files.items()),
        notice="NOTICE")


@pytest.fixture
def fake(monkeypatch):
    model = _fake_model()
    monkeypatch.setattr(bm, "BUNDLED_MODELS", {model.key: model})
    return model


def _write_bundle(root: Path, files: dict[str, bytes] = FAKE_FILES, manifest_for=None) -> Path:
    for path, data in files.items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_bytes(data)
    if manifest_for is not None:
        (root / bm.BUNDLE_MANIFEST).write_text(json.dumps(bm.bundle_manifest(manifest_for)))
    return root


def _leftovers(root: Path) -> list[str]:
    return sorted(p.name for p in root.iterdir() if ".tmp-" in p.name) if root.exists() else []


# --- pins -----------------------------------------------------------------------


def test_bark_pins_match_the_required_public_artifacts():
    bark = bm.BARK_3.file("model.bark")
    assert (bm.BARK_3.repo, bm.BARK_3.revision) == (
        "ConwayResearch/Underdog-Bark-3.0", "85db2ad18ab41e534a222ee253c29191d77ed919")
    assert (bark.size, bark.sha256) == (
        163398645, "c18de9418d73cbeb80b8c1287b392d480a56e191ef4a81d1baaa1b02e66d92ed")
    assert (bm.BARK_3_CLEAN.repo, bm.BARK_3_CLEAN.revision) == (
        "ConwayResearch/Underdog-Bark-3.0-Clean", "6d34ed8639b2b9a33e764acf06748519bbb950cf")
    assert bm.BARK_3_ANE.revision == bm.BARK_3.revision
    assert (bm.BARK_3.pad_s, bm.BARK_3_CLEAN.pad_s, bm.BARK_3_ANE.pad_s) == (0.25, 0.0, 0.25)


@pytest.mark.parametrize("model", list(bm.BUNDLED_MODELS.values()), ids=lambda m: m.key)
def test_every_pin_is_complete_and_carries_its_attribution(model):
    assert re.fullmatch(r"[0-9a-f]{40}", model.revision)
    assert model.license == "CC-BY-4.0"
    paths = [f.path for f in model.files]
    assert len(paths) == len(set(paths))
    assert model.notice in paths
    for pinned in model.files:
        assert re.fullmatch(r"[0-9a-f]{64}", pinned.sha256) and pinned.size > 0
        assert not pinned.path.startswith("/") and ".." not in pinned.path.split("/")
        assert model.download_url(pinned).startswith(
            f"https://huggingface.co/{model.repo}/resolve/{model.revision}/")
    if model.runtime == "coreml":
        assert all(p.startswith("coreml/") for p in paths)


def test_shipped_notices_are_the_pinned_upstream_bytes():
    expected = {
        NOTICES / "Underdog-Bark-3.0.NOTICE": bm.BARK_3.file("NOTICE"),
        NOTICES / "Underdog-Bark-3.0-Clean.NOTICE": bm.BARK_3_CLEAN.file("NOTICE"),
        NOTICES / "CC-BY-4.0.LICENSE": bm.BARK_3.file("coreml/LICENSE"),
        VENDOR / "NOTICE": bm.BARK_3.file("NOTICE"),
        VENDOR / "LICENSE": bm.BARK_3.file("coreml/LICENSE"),
    }
    for path, pinned in expected.items():
        bm.verify_file(path, pinned)
    assert "Attribution 4.0 International" in (NOTICES / "CC-BY-4.0.LICENSE").read_text()


# --- importer -------------------------------------------------------------------


def test_import_publishes_a_verified_read_only_copy(fake, tmp_path):
    bundle = _write_bundle(tmp_path / "bundle", manifest_for=fake)
    root = tmp_path / "store"

    published = bm.import_bundled_model(bundle, fake.key, dest_root=root)

    assert published == root / bm.import_dir_name(fake)
    for path, data in FAKE_FILES.items():
        assert (published / path).read_bytes() == data
        assert stat.S_IMODE((published / path).stat().st_mode) & 0o222 == 0
    marker = json.loads((published / bm.IMPORT_MANIFEST).read_text())
    assert marker["revision"] == fake.revision and set(marker["imported"]["methods"]) == set(FAKE_FILES)
    assert _leftovers(root) == []
    assert bm.read_attribution(published, fake) == FAKE_FILES["NOTICE"].decode()


def test_import_clones_and_verifies_the_clone(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    calls = []
    real = bm._clonefile

    def spy(src, dst):
        calls.append(src.name)
        return real(src, dst)

    monkeypatch.setattr(bm, "_clonefile", spy)
    published = bm.import_bundled_model(bundle, fake.key, dest_root=tmp_path / "store")
    assert sorted(calls) == sorted(Path(p).name for p in FAKE_FILES)
    methods = json.loads((published / bm.IMPORT_MANIFEST).read_text())["imported"]["methods"]
    assert set(methods.values()) <= {"clone", "copy"}


def test_import_falls_back_to_a_streamed_copy(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    monkeypatch.setattr(bm, "_clonefile", lambda src, dst: False)
    published = bm.import_bundled_model(bundle, fake.key, dest_root=tmp_path / "store")
    methods = json.loads((published / bm.IMPORT_MANIFEST).read_text())["imported"]["methods"]
    assert set(methods.values()) == {"copy"}
    assert (published / "model.bark").read_bytes() == FAKE_FILES["model.bark"]


def test_a_clone_that_differs_from_the_pin_is_never_published(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"

    def corrupt_clone(src, dst):  # e.g. the source was swapped after its check
        data = bytearray(src.read_bytes())
        data[0] ^= 0xFF
        dst.write_bytes(bytes(data))
        return True

    monkeypatch.setattr(bm, "_clonefile", corrupt_clone)
    with pytest.raises(bm.BundleIntegrityError):
        bm.import_bundled_model(bundle, fake.key, dest_root=root)
    assert not (root / bm.import_dir_name(fake)).exists() and _leftovers(root) == []


def test_reimport_returns_the_existing_import_without_copying(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"
    first = bm.import_bundled_model(bundle, fake.key, dest_root=root)

    def no_copy(*_args):
        raise AssertionError("a verified import must not be copied again")

    monkeypatch.setattr(bm, "_clone_or_copy", no_copy)
    assert bm.import_bundled_model(bundle, fake.key, dest_root=root) == first


@pytest.mark.parametrize("damage", ["size", "hash", "missing", "symlink", "manifest"])
def test_a_bundle_that_does_not_match_its_pins_is_refused(fake, tmp_path, damage):
    bundle = _write_bundle(tmp_path / "bundle")
    target = bundle / "model.bark"
    if damage == "size":
        target.write_bytes(FAKE_FILES["model.bark"] + b"x")
    elif damage == "hash":
        target.write_bytes(FAKE_FILES["model.bark"][:-1] + b"X")
    elif damage == "missing":
        target.unlink()
    elif damage == "symlink":
        real = tmp_path / "elsewhere.bark"
        real.write_bytes(FAKE_FILES["model.bark"])
        target.unlink()
        target.symlink_to(real)
    else:
        other = _fake_model(files={**FAKE_FILES, "NOTICE": b"other\n"})
        (bundle / bm.BUNDLE_MANIFEST).write_text(json.dumps(bm.bundle_manifest(other)))
    root = tmp_path / "store"
    with pytest.raises(bm.BundleIntegrityError):
        bm.import_bundled_model(bundle, fake.key, dest_root=root)
    assert not (root / bm.import_dir_name(fake)).exists() and _leftovers(root) == []


def test_a_directory_velora_did_not_create_is_never_touched(fake, tmp_path):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"
    theirs = root / bm.import_dir_name(fake)
    theirs.mkdir(parents=True)
    (theirs / "model.bark").write_bytes(b"the user's own file")

    with pytest.raises(bm.BundledModelConflict):
        bm.import_bundled_model(bundle, fake.key, dest_root=root)
    assert (theirs / "model.bark").read_bytes() == b"the user's own file"
    assert sorted(p.name for p in theirs.iterdir()) == ["model.bark"]


def test_a_damaged_import_is_set_aside_not_deleted(fake, tmp_path):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"
    first = bm.import_bundled_model(bundle, fake.key, dest_root=root)
    edited = first / "NOTICE"
    os.chmod(edited, 0o644)
    edited.write_bytes(b"user edit\n")

    again = bm.import_bundled_model(bundle, fake.key, dest_root=root)

    assert again == first and (again / "NOTICE").read_bytes() == FAKE_FILES["NOTICE"]
    aside = [p for p in root.iterdir() if ".stale-" in p.name]
    assert len(aside) == 1 and (aside[0] / "NOTICE").read_bytes() == b"user edit\n"


def test_cancel_mid_copy_publishes_nothing(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"
    monkeypatch.setattr(bm, "_clonefile", lambda src, dst: False)
    monkeypatch.setattr(bm, "_CHUNK", 1024)
    cancel = threading.Event()
    real_copy = bm._copy_hashing

    def copy_then_cancel(src, dst, token):
        cancel.set()
        return real_copy(src, dst, token)

    monkeypatch.setattr(bm, "_copy_hashing", copy_then_cancel)
    with pytest.raises(bm.BundleImportCancelled):
        bm.import_bundled_model(bundle, fake.key, dest_root=root, cancel=cancel)
    assert not (root / bm.import_dir_name(fake)).exists() and _leftovers(root) == []


def test_a_killed_imports_temporary_directory_is_cleaned_up(fake, tmp_path):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"
    stale = root / f".{bm.import_dir_name(fake)}.tmp-dead"
    stale.mkdir(parents=True)
    (stale / "model.bark").write_bytes(b"half")
    bm.import_bundled_model(bundle, fake.key, dest_root=root)
    assert not stale.exists()


def test_concurrent_imports_publish_once(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"
    copies = []
    real = bm._clone_or_copy

    def counting(src, dst, pinned, cancel):
        copies.append(pinned.path)
        return real(src, dst, pinned, cancel)

    monkeypatch.setattr(bm, "_clone_or_copy", counting)
    results: list[Path] = []
    threads = [threading.Thread(target=lambda: results.append(
        bm.import_bundled_model(bundle, fake.key, dest_root=root))) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(set(results)) == 1 and len(results) == 4
    assert sorted(copies) == sorted(FAKE_FILES)


def test_import_is_local_only(fake, tmp_path, monkeypatch):
    def no_network(*_args, **_kwargs):
        raise AssertionError("the importer must not open sockets")

    monkeypatch.setattr(socket, "socket", no_network)
    bundle = _write_bundle(tmp_path / "bundle")
    assert bm.import_bundled_model(bundle, fake.key, dest_root=tmp_path / "store").is_dir()
    with pytest.raises(ValueError):
        bm.import_bundled_model("https://huggingface.co/x", fake.key, dest_root=tmp_path / "s")


def test_a_destination_that_appears_mid_import_wins(fake, tmp_path, monkeypatch):
    bundle = _write_bundle(tmp_path / "bundle")
    root = tmp_path / "store"

    def raced(src, dst):
        raise FileExistsError(dst)

    monkeypatch.setattr(bm, "rename_no_replace", raced)
    with pytest.raises(bm.BundledModelConflict):
        bm.import_bundled_model(bundle, fake.key, dest_root=root)
    assert _leftovers(root) == []


def test_rename_no_replace_refuses_an_existing_empty_directory(tmp_path):
    src, dst = tmp_path / "src", tmp_path / "dst"
    src.mkdir()
    (src / "f").write_text("x")
    dst.mkdir()  # os.rename would silently replace this
    with pytest.raises(FileExistsError):
        bm.rename_no_replace(src, dst)
    assert (src / "f").exists() and dst.is_dir() and not any(dst.iterdir())
    dst.rmdir()
    bm.rename_no_replace(src, dst)
    assert (dst / "f").read_text() == "x" and not src.exists()


def test_unknown_key_is_refused(tmp_path):
    with pytest.raises(KeyError):
        bm.import_bundled_model(tmp_path, "no-such-model", dest_root=tmp_path / "s")


# --- packaging script ---------------------------------------------------------------


@pytest.fixture
def script():
    spec = importlib.util.spec_from_file_location(
        "prepare_bundled_model", REPO / "scripts" / "prepare-bundled-model.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.bm is bm  # monkeypatched pins reach the script
    return module


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def _opener(model: bm.BundledModel, files: dict[str, bytes], seen: list[str]):
    by_url = {model.download_url(f): files[f.path] for f in model.files}

    def open_url(url):
        seen.append(url)
        return _Response(by_url[url])

    return open_url


def test_prepare_downloads_only_pinned_files_and_reports_attribution(fake, script, tmp_path):
    seen: list[str] = []
    report = script.prepare(fake.key, tmp_path / "out", _opener(fake, FAKE_FILES, seen))

    assert sorted(seen) == sorted(fake.download_url(f) for f in fake.files)
    assert all(u.startswith(f"https://huggingface.co/{fake.repo}/resolve/{fake.revision}/") for u in seen)
    bundle = Path(report["path"])
    bm.verify_tree(bundle, fake)
    bm.check_bundle_manifest(bundle, fake)
    assert report["attribution"] == FAKE_FILES["NOTICE"].decode()
    assert report["license"] == "CC-BY-4.0" and report["reused"] is False
    assert Path(report["manifest"]) == bundle / bm.BUNDLE_MANIFEST
    # The prepared bundle is exactly what the importer accepts.
    assert bm.import_bundled_model(bundle, fake.key, dest_root=tmp_path / "store").is_dir()


def test_prepare_reuses_a_verified_bundle_without_network(fake, script, tmp_path):
    script.prepare(fake.key, tmp_path / "out", _opener(fake, FAKE_FILES, []))

    def offline(url):
        raise AssertionError(f"unexpected download {url}")

    assert script.prepare(fake.key, tmp_path / "out", offline)["reused"] is True
    assert script.verify(fake.key, tmp_path / "out")["reused"] is True


@pytest.mark.parametrize("served", ["wrong-bytes", "too-long"])
def test_prepare_publishes_nothing_when_the_hub_serves_other_bytes(fake, script, tmp_path, served):
    bad = dict(FAKE_FILES)
    bad["model.bark"] = (FAKE_FILES["model.bark"][:-1] + b"X" if served == "wrong-bytes"
                         else FAKE_FILES["model.bark"] + b"extra")
    out = tmp_path / "out"
    with pytest.raises(bm.BundleIntegrityError):
        script.prepare(fake.key, out, _opener(fake, bad, []))
    assert not (out / fake.key).exists() and _leftovers(out) == []


def test_prepare_never_replaces_a_foreign_directory(fake, script, tmp_path):
    theirs = tmp_path / "out" / fake.key
    theirs.mkdir(parents=True)
    (theirs / "notes.txt").write_text("mine")
    with pytest.raises(script.PrepareError):
        script.prepare(fake.key, tmp_path / "out", _opener(fake, FAKE_FILES, []))
    assert (theirs / "notes.txt").read_text() == "mine"


def test_prepare_refuses_outputs_git_would_track(script, tmp_path):
    assert script._inside_repo_unignored(REPO / "engine" / "src" / "weights")
    assert not script._inside_repo_unignored(REPO / "build" / "bundled-models")
    assert not script._inside_repo_unignored(tmp_path / "out")
    with pytest.raises(SystemExit):
        script.main(["--output", str(REPO / "engine" / "weights-here")])


def test_prepare_cli_prints_a_json_report(fake, script, tmp_path, capsys):
    code = script.main(["--output", str(tmp_path / "out"), "--model", fake.key, "--json"],
                       opener=_opener(fake, FAKE_FILES, []))
    assert code == 0
    report = json.loads(capsys.readouterr().out)["bundles"][0]
    assert report["key"] == fake.key and report["attribution"].startswith("Fake model NOTICE")


def test_prepare_only_speaks_https(script):
    with pytest.raises(script.PrepareError):
        script._open_url("http://huggingface.co/x")


def test_bundled_models_has_no_engine_imports_at_module_level():
    # The packaging script imports it with any python3; keep it stdlib-only.
    source = (REPO / "engine" / "src" / "velora_engine" / "bundled_models.py").read_text()
    top_level = [line for line in source.splitlines()
                 if line.startswith(("import ", "from ")) and "__future__" not in line]
    allowed = set(sys.stdlib_module_names)
    for line in top_level:
        module = line.split()[1].split(".")[0]
        assert module in allowed, line
