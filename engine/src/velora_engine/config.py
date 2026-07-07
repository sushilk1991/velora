"""Config + mode files shared with the Swift app via ~/.velora/.

- ~/.velora/config.json  — active models, cleanup on/off, default mode.
- ~/.velora/modes/*.json — mode files (built-ins written on first run, user-editable).

`VELORA_HOME` env var overrides ~/.velora (used by tests).
"""

from __future__ import annotations

import importlib.resources
import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

log = logging.getLogger("velora.config")

DEFAULT_STT_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
DEFAULT_CLEANUP_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

DEFAULT_CONFIG: dict[str, Any] = {
    "stt_model": DEFAULT_STT_MODEL,
    "cleanup_model": DEFAULT_CLEANUP_MODEL,
    "cleanup_enabled": True,
    "default_mode": "Default",
    "vocabulary": [],
    "replacements": {},
    "language": "auto",
    "auto_punctuation": True,
    "max_recording_s": 300,
}

DEFAULT_MAX_RECORDING_S = 300.0

VALID_FORMATTING = ("off", "light", "full")


def velora_home() -> Path:
    return Path(os.environ.get("VELORA_HOME", str(Path.home() / ".velora")))


@dataclass
class Mode:
    name: str
    prompt: str = ""
    formatting: str = "full"  # off | light | full
    apps: list[str] = field(default_factory=list)
    vocabulary: list[str] = field(default_factory=list)
    replacements: dict[str, str] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Mode":
        fmt = d.get("formatting", "full")
        if fmt not in VALID_FORMATTING:
            fmt = "full"
        return cls(
            name=str(d.get("name", "Unnamed")),
            prompt=str(d.get("prompt", "") or ""),
            formatting=fmt,
            apps=[str(a) for a in d.get("apps", []) or []],
            vocabulary=[str(v) for v in d.get("vocabulary", []) or []],
            replacements={str(k): str(v) for k, v in (d.get("replacements") or {}).items()},
        )


class Config:
    """Engine configuration; call reload() when the app sends reload_config."""

    def __init__(self, home: Path | None = None) -> None:
        self.home = home or velora_home()
        self.data: dict[str, Any] = dict(DEFAULT_CONFIG)
        self.modes: dict[str, Mode] = {}
        self.reload()

    # ---- paths ----
    @property
    def config_path(self) -> Path:
        return self.home / "config.json"

    @property
    def modes_dir(self) -> Path:
        return self.home / "modes"

    @property
    def socket_path(self) -> Path:
        return self.home / "engine.sock"

    # ---- properties ----
    @property
    def stt_model(self) -> str:
        return str(self.data.get("stt_model") or DEFAULT_STT_MODEL)

    @property
    def cleanup_model(self) -> str:
        return str(self.data.get("cleanup_model") or DEFAULT_CLEANUP_MODEL)

    @property
    def cleanup_enabled(self) -> bool:
        return bool(self.data.get("cleanup_enabled", True))

    @property
    def default_mode_name(self) -> str:
        return str(self.data.get("default_mode") or "Default")

    @property
    def language(self) -> str:
        """Dictation language ("auto" = autodetect; only whisper honors it)."""
        return str(self.data.get("language") or "auto").strip() or "auto"

    @property
    def auto_punctuation(self) -> bool:
        return bool(self.data.get("auto_punctuation", True))

    @property
    def max_recording_s(self) -> float:
        """Max recording duration before the engine auto-finalizes a session."""
        try:
            value = float(self.data.get("max_recording_s", DEFAULT_MAX_RECORDING_S))
        except (TypeError, ValueError):
            return DEFAULT_MAX_RECORDING_S
        return value if value > 0 else DEFAULT_MAX_RECORDING_S

    @property
    def global_vocabulary(self) -> list[str]:
        return [str(v) for v in self.data.get("vocabulary", []) or []]

    @property
    def global_replacements(self) -> dict[str, str]:
        return {str(k): str(v) for k, v in (self.data.get("replacements") or {}).items()}

    # ---- lifecycle ----
    def reload(self) -> None:
        # 0700: ~/.velora holds transcripts (history.sqlite3), config, and the
        # engine socket — keep it private to the user.
        self.home.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            os.chmod(self.home, 0o700)
        except OSError as exc:  # pragma: no cover — permissions best-effort
            log.warning("could not chmod %s to 0700: %s", self.home, exc)
        self._load_or_create_config()
        self._ensure_builtin_modes()
        self._load_modes()

    def save(self) -> None:
        self.config_path.write_text(json.dumps(self.data, indent=2) + "\n")

    def _load_or_create_config(self) -> None:
        if self.config_path.exists():
            try:
                on_disk = json.loads(self.config_path.read_text())
                if not isinstance(on_disk, dict):
                    raise ValueError("config.json is not an object")
                self.data = {**DEFAULT_CONFIG, **on_disk}
                return
            except Exception as exc:  # noqa: BLE001 — corrupt config must not kill the engine
                log.warning("config.json unreadable (%s); using defaults", exc)
                self.data = dict(DEFAULT_CONFIG)
                return
        self.data = dict(DEFAULT_CONFIG)
        self.save()
        log.info("wrote default config to %s", self.config_path)

    def _ensure_builtin_modes(self) -> None:
        """Write built-in mode files on first run (never overwrite user edits)."""
        self.modes_dir.mkdir(parents=True, exist_ok=True)
        pkg = importlib.resources.files("velora_engine") / "modes_builtin"
        for res in pkg.iterdir():
            if not res.name.endswith(".json"):
                continue
            dest = self.modes_dir / res.name
            if not dest.exists():
                dest.write_text(res.read_text())
                log.info("installed built-in mode %s", dest.name)

    def _load_modes(self) -> None:
        self.modes = {}
        for path in sorted(self.modes_dir.glob("*.json")):
            try:
                mode = Mode.from_dict(json.loads(path.read_text()))
                self.modes[mode.name.lower()] = mode
            except Exception as exc:  # noqa: BLE001
                log.warning("skipping bad mode file %s: %s", path.name, exc)
        log.info("loaded %d modes: %s", len(self.modes), ", ".join(m.name for m in self.modes.values()))

    # ---- lookup ----
    def mode_by_name(self, name: str | None) -> Mode | None:
        if not name:
            return None
        return self.modes.get(name.strip().lower())

    def default_mode(self) -> Mode:
        return self.mode_by_name(self.default_mode_name) or Mode(name="Default")

    def mode_for_bundle(self, bundle_id: str | None) -> Mode | None:
        if not bundle_id:
            return None
        for mode in self.modes.values():
            if bundle_id in mode.apps:
                return mode
        return None
