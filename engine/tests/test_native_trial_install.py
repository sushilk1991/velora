from __future__ import annotations

import hashlib
import importlib.util
import json
import stat
from pathlib import Path

import pytest


@pytest.fixture
def installer(monkeypatch, tmp_path):
    path = Path(__file__).resolve().parents[2] / "scripts/install-native-cleanup-trial.py"
    spec = importlib.util.spec_from_file_location("native_trial_installer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    contents = {"model.gguf": b"fake GGUF", "velora-cleanup-native": b"fake worker",
                "supervise.py": b"fake supervisor"}
    monkeypatch.setattr(module, "PINS", {
        name: hashlib.sha256(data).hexdigest() for name, data in contents.items()
    })
    sources = tmp_path / "source"
    sources.mkdir()
    for name, data in contents.items():
        (sources / name).write_bytes(data)
    return module, sources, contents


def install(module, source, home):
    return module.install(source / "model.gguf", source / "velora-cleanup-native",
                          source / "supervise.py", home=home)


def test_install_is_verified_read_only_and_does_not_opt_in(installer, tmp_path):
    module, source, contents = installer
    home = tmp_path / "home"
    home.mkdir()
    config = home / "config.json"
    config.write_text('{"cleanup_model":"quality","experimental_native_cleanup":false}')
    before = config.read_bytes()
    destination = install(module, source, home)
    assert config.read_bytes() == before
    for name, data in contents.items():
        path = destination / name
        assert path.read_bytes() == data and not path.is_symlink()
        assert not (stat.S_IMODE(path.stat().st_mode) & 0o222)
    assert stat.S_IMODE((destination / "velora-cleanup-native").stat().st_mode) & 0o111
    manifest = json.loads((destination / "manifest.json").read_text())
    assert manifest["checkpoint"] == "G" and manifest["model_bytes"] == len(contents["model.gguf"])
    assert manifest["model_sha256"] == module.PINS["model.gguf"]


@pytest.mark.parametrize("name", ["model.gguf", "velora-cleanup-native", "supervise.py"])
def test_bad_source_never_publishes_package(installer, tmp_path, name):
    module, source, _ = installer
    (source / name).write_bytes(b"corrupt")
    with pytest.raises(ValueError, match="SHA256"):
        install(module, source, tmp_path / "home")
    parent = tmp_path / "home/experimental"
    assert not (parent / "lfm3-native-v1").exists()
    assert not list(parent.glob(".native-trial-*"))


def test_source_symlink_is_rejected(installer, tmp_path):
    module, source, _ = installer
    original = source / "model.gguf"
    original.rename(source / "other")
    original.symlink_to(source / "other")
    with pytest.raises(ValueError, match="regular"):
        install(module, source, tmp_path / "home")


def test_reinstall_keeps_valid_package_and_refuses_corrupt_destination(installer, tmp_path):
    module, source, _ = installer
    home = tmp_path / "home"
    destination = install(module, source, home)
    old_inode = (destination / "model.gguf").stat().st_ino
    assert install(module, source, home) == destination
    assert (destination / "model.gguf").stat().st_ino == old_inode
    (destination / "manifest.json").chmod(0o600)
    (destination / "manifest.json").write_text("{}")
    with pytest.raises(ValueError, match="existing"):
        install(module, source, home)
    assert (destination / "manifest.json").read_text() == "{}"


def test_copy_is_verified_before_atomic_publication(installer, monkeypatch, tmp_path):
    module, source, _ = installer
    real_copy = module.shutil.copyfile

    def bad_copy(src, dest):
        real_copy(src, dest)
        if Path(dest).name == "model.gguf":
            Path(dest).write_bytes(b"bad copy")

    monkeypatch.setattr(module.shutil, "copyfile", bad_copy)
    with pytest.raises(ValueError, match="SHA256"):
        install(module, source, tmp_path / "home")
    parent = tmp_path / "home/experimental"
    assert not (parent / "lfm3-native-v1").exists()
    assert not list(parent.glob(".native-trial-*"))
