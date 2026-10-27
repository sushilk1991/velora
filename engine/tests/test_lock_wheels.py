"""The shipped engine installs from wheels on every Python uv may choose.

The app bundles pyproject.toml and uv.lock but not .python-version, so
`uv run` builds the engine venv on the first interpreter it finds: Homebrew's
python3 or a managed download. A version the lock has no wheel for fails the
install, the engine exits 2 on every restart, and Settings › Models waits on
"Connecting to the model engine…" forever:

    uv run ─▶ CPython 3.15 ─▶ mlx 0.31.2: no cp315 wheel ─▶ exit 2 ─▶ restart
"""
import tomllib
from pathlib import Path

from packaging.markers import Marker
from packaging.specifiers import SpecifierSet
from packaging.tags import compatible_tags, cpython_tags, mac_platforms
from packaging.utils import parse_wheel_filename

_ENGINE = Path(__file__).resolve().parents[1]
# Package.swift's deployment target: a wheel tagged for a newer macOS does
# not install on the oldest supported Mac.
_MACOS_MIN = (14, 0)
_ARCH = "arm64"
# Every CPython minor up to here is checked against requires-python, so an
# unbounded range fails as soon as it admits a version the lock can't serve.
_PYTHON_MINORS = range(12, 21)
# `uv run` syncs the dev group too (uv's default-groups).
_DEFAULT_GROUPS = ("dev",)


def _environment(minor: int) -> dict[str, str]:
    return {
        "python_version": f"3.{minor}", "python_full_version": f"3.{minor}.0",
        "sys_platform": "darwin", "platform_system": "Darwin",
        "platform_machine": _ARCH, "os_name": "posix",
        "implementation_name": "cpython", "platform_python_implementation": "CPython",
        "extra": "",
    }


def _packages_for(lock: dict, environment: dict[str, str]) -> list[dict]:
    """Walks the lock from the project, following only edges whose markers
    hold on this Mac and Python, the way uv picks what to install."""
    by_name: dict[str, list[dict]] = {}
    for package in lock["package"]:
        by_name.setdefault(package["name"], []).append(package)
    root = next(p for p in lock["package"] if "editable" in p.get("source", {}))
    edges = list(root.get("dependencies", []))
    for group in _DEFAULT_GROUPS:
        edges += root.get("dev-dependencies", {}).get(group, [])

    seen: set[tuple[str, str, frozenset[str]]] = set()
    found: list[dict] = []
    while edges:
        edge = edges.pop()
        if "marker" in edge and not Marker(edge["marker"]).evaluate(environment):
            continue

        candidates = [p for p in by_name[edge["name"]]
                      if "version" not in edge or p["version"] == edge["version"]]
        assert len(candidates) == 1, f"ambiguous lock edge {edge}"
        package = candidates[0]
        extras = frozenset(edge.get("extra", ()))
        key = (package["name"], package["version"], extras)
        if key in seen:
            continue

        seen.add(key)
        found.append(package)
        edges += package.get("dependencies", [])
        for extra in extras:
            edges += package.get("optional-dependencies", {}).get(extra, [])
    return found


def test_lock_has_wheels_for_every_allowed_python():
    project = tomllib.loads((_ENGINE / "pyproject.toml").read_text())
    lock = tomllib.loads((_ENGINE / "uv.lock").read_text())
    allowed = SpecifierSet(project["project"]["requires-python"])
    platforms = list(mac_platforms(_MACOS_MIN, _ARCH))

    missing = []
    for minor in _PYTHON_MINORS:
        if f"3.{minor}.0" not in allowed:
            continue

        version = (3, minor)
        supported = set(cpython_tags(version, platforms=platforms))
        supported |= set(compatible_tags(version, f"cp3{minor}", platforms))
        for package in _packages_for(lock, _environment(minor)):
            if "registry" not in package.get("source", {}):
                continue

            wheels = (parse_wheel_filename(w["url"].rsplit("/", 1)[-1])[3]
                      for w in package.get("wheels", []))
            if not any(tags & supported for tags in wheels):
                missing.append(f"cp3{minor}: {package['name']}=={package['version']}")

    assert not missing, (
        f"requires-python {allowed} admits Pythons the lock has no macOS {_ARCH} "
        f"wheel for; uv would fail the engine install: {missing}")
