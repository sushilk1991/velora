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

DEFAULT_STT_MODEL = "mlx-community/whisper-large-v3-turbo"
# Qwen3.5-4B (8-bit MLX): newer generation than Qwen3-4B, higher precision than
# the old 4-bit build. Verified to load via stock mlx-lm and clean well
# (~0.3-0.5s/paragraph); ~4.3 GB / more RAM is the accepted tradeoff.
DEFAULT_CLEANUP_MODEL = "mlx-community/Qwen3.5-4B-MLX-8bit"

DEFAULT_CONFIG: dict[str, Any] = {
    "stt_model": DEFAULT_STT_MODEL,
    "cleanup_model": DEFAULT_CLEANUP_MODEL,
    "cleanup_enabled": True,
    "default_mode": "Default",
    "vocabulary": [],
    "replacements": {},
    "language": "auto",
    "auto_punctuation": True,
    # Romanize non-English (Devanagari/CJK/…) output into the Latin alphabet —
    # e.g. Hindi speech → natural Hinglish in English letters, not Devanagari.
    # Off by default; opt-in. Uses the multilingual cleanup LLM.
    "romanize_output": False,
    # Long prose dictated into a terminal (Claude Code, codex chats) gets LLM
    # cleanup instead of verbatim passthrough; short commands stay verbatim.
    "smart_terminal": True,
    # Clean whisper segments with the LLM DURING recording (smartness-v2 §2) so
    # long dictations stop blowing the cleanup budget; off → segments are
    # HUD-preview-only and finalize runs the whole-text cleanup as before.
    "streaming_cleanup": True,
    # Idle vocabulary miner: the cleanup LLM extracts proper nouns/jargon from
    # recent dictation history while nothing else is happening, growing
    # ~/.velora/auto_learned.json (all local; smartness-v2 §4).
    "vocab_mining": True,
    "max_recording_s": 300,
    # Audio archive: keep a clip of each dictation so it can be re-transcribed
    # later with a better model (history → reprocess). On by default (a core
    # feature); user-toggleable. Retained 6 months, total capped at 4 GB, and
    # stored 0600 under ~/.velora/audio — as private as the transcripts.
    "save_audio": True,
    "audio_retention_days": 180,
    "audio_max_mb": 4096,
}

DEFAULT_MAX_RECORDING_S = 300.0

VALID_FORMATTING = ("off", "light", "full")


def velora_home() -> Path:
    return Path(os.environ.get("VELORA_HOME", str(Path.home() / ".velora")))


_DICT_WORDS: frozenset[str] | None = None


def _is_dictionary_word(word: str) -> bool:
    """True when `word` is a real English word per the system word list
    (/usr/share/dict/words, present on every macOS). Used to demote legacy
    hard replacements whose wrong side is a real word — those must never be
    deterministic rewrites. Missing word list (CI/Linux) → False: the Swift
    app's spellchecker-based migration is the primary line anyway."""
    global _DICT_WORDS
    if _DICT_WORDS is None:
        try:
            _DICT_WORDS = frozenset(
                Path("/usr/share/dict/words").read_text().lower().split()
            )
        except OSError:
            _DICT_WORDS = frozenset()
    return word.lower() in _DICT_WORDS


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
        self._learned_vocab: list[str] = []
        self._learned_replacements: dict[str, str] = {}
        self._auto_vocab: list[str] = []
        self._config_corrupt = False
        self.reload()

    # ---- paths ----
    @property
    def config_path(self) -> Path:
        return self.home / "config.json"

    @property
    def modes_dir(self) -> Path:
        return self.home / "modes"

    @property
    def audio_dir(self) -> Path:
        return self.home / "audio"

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
    def romanize_output(self) -> bool:
        """Write non-Latin output in the Latin alphabet (Hindi → Hinglish)."""
        return bool(self.data.get("romanize_output", False))

    @property
    def smart_terminal(self) -> bool:
        """LLM-clean long prose dictated into a terminal (AI-chat aware)."""
        return bool(self.data.get("smart_terminal", True))

    @property
    def streaming_cleanup(self) -> bool:
        """Clean whisper segments concurrently during recording."""
        return bool(self.data.get("streaming_cleanup", True))

    @property
    def vocab_mining(self) -> bool:
        """Mine proper nouns/jargon from history while the engine is idle."""
        return bool(self.data.get("vocab_mining", True))

    @property
    def max_recording_s(self) -> float:
        """Max recording duration before the engine auto-finalizes a session."""
        try:
            value = float(self.data.get("max_recording_s", DEFAULT_MAX_RECORDING_S))
        except (TypeError, ValueError):
            return DEFAULT_MAX_RECORDING_S
        return value if value > 0 else DEFAULT_MAX_RECORDING_S

    @property
    def save_audio(self) -> bool:
        return bool(self.data.get("save_audio", True))

    @property
    def audio_retention_days(self) -> float:
        try:
            value = float(self.data.get("audio_retention_days", 180))
        except (TypeError, ValueError):
            return 180.0
        return value if value > 0 else 180.0

    @property
    def audio_max_bytes(self) -> int:
        try:
            mb = float(self.data.get("audio_max_mb", 4096))
        except (TypeError, ValueError):
            mb = 4096.0
        return int(mb * 1024 * 1024) if mb > 0 else 0

    @property
    def user_vocabulary(self) -> list[str]:
        """Vocabulary the user configured explicitly (config.json)."""
        return [str(v) for v in self.data.get("vocabulary", []) or []]

    @property
    def learned_vocabulary(self) -> list[str]:
        """Vocabulary the app learned from the user's edits (learned.json)."""
        return list(self._learned_vocab)

    @property
    def auto_vocabulary(self) -> list[str]:
        """Terms the idle miner extracted (auto_learned.json, minus banned)."""
        return list(self._auto_vocab)

    @property
    def global_vocabulary(self) -> list[str]:
        # User-configured vocab + terms the app learned from corrections +
        # idle-mined terms. Dedup keeps the first (user wins over learned wins
        # over auto-mined).
        base = self.user_vocabulary
        seen: set[str] = set()
        out: list[str] = []
        for v in base + self._learned_vocab + self._auto_vocab:
            if v and v not in seen:
                seen.add(v)
                out.append(v)
        return out

    @property
    def global_replacements(self) -> dict[str, str]:
        # Learned corrections first, then user config on top (user always wins).
        merged = dict(self._learned_replacements)
        merged.update({str(k): str(v) for k, v in (self.data.get("replacements") or {}).items()})
        return merged

    @property
    def soft_corrections(self) -> dict[str, str]:
        """Context-gated learned corrections (real-word wrongs): surfaced to
        the cleanup LLM as hints, never applied deterministically."""
        return dict(self._learned_soft)

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
        self._load_learned()
        self._load_auto_vocab()
        self._ensure_builtin_modes()
        self._migrate_stale_builtins()
        self._load_modes()

    def _load_learned(self) -> None:
        """Load ~/.velora/learned.json — vocab/replacements the app taught the
        engine from the user's post-dictation edits. Kept separate from
        config.json so the app's config writes never clobber it and it survives
        a corrupt user config.

        `soft_replacements` are corrections whose WRONG side is a real word
        ("lung" misheard for "Airlearn") — never applied deterministically;
        they ride into the cleanup prompt as context-gated hints instead."""
        self._learned_vocab: list[str] = []
        self._learned_replacements: dict[str, str] = {}
        self._learned_soft: dict[str, str] = {}
        path = self.home / "learned.json"
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text())
            self._learned_vocab = [str(v) for v in data.get("vocabulary", []) or []]
            self._learned_replacements = {
                str(k): str(v) for k, v in (data.get("replacements") or {}).items()
            }
            self._learned_soft = {
                str(k): str(v) for k, v in (data.get("soft_replacements") or {}).items()
            }
            # Defense in depth (review finding): the Swift app demotes
            # real-word wrongs to soft on ITS load, but a standalone engine or
            # a restored pre-0.3.4 learned.json could still carry
            # {"lung": "Airlearn"} as a hard rule — which would deterministically
            # corrupt every genuine "lung". Demote such keys here too.
            risky = [k for k in self._learned_replacements if _is_dictionary_word(k)]
            for key in risky:
                self._learned_soft.setdefault(key, self._learned_replacements.pop(key))
            if risky:
                log.info("demoted %d real-word learned replacement(s) to context-gated", len(risky))
        except Exception as exc:  # noqa: BLE001 — never let a bad file kill reload
            log.warning("learned.json unreadable (%s); ignoring", exc)

    def _load_auto_vocab(self) -> None:
        """Load ~/.velora/auto_learned.json — terms the ENGINE's idle miner
        extracted from dictation history (vocab_miner.py owns the writes; the
        app deletes terms by moving them to `banned`). Banned terms are dropped
        here too so a mid-cycle app deletion takes effect on the next reload."""
        self._auto_vocab = []
        path = self.home / "auto_learned.json"
        if not path.exists():
            return
        try:
            data = json.loads(path.read_text())
            banned = {str(b).lower() for b in data.get("banned", []) or []}
            self._auto_vocab = [
                str(t) for t in data.get("terms", []) or [] if str(t).lower() not in banned
            ]
        except Exception as exc:  # noqa: BLE001 — never let a bad file kill reload
            log.warning("auto_learned.json unreadable (%s); ignoring", exc)

    def save(self) -> None:
        # Atomic: write a sibling temp then rename, so a crash mid-write can't
        # truncate config.json and we don't race the app's atomic writer.
        tmp = self.config_path.with_name(self.config_path.name + ".tmp")
        tmp.write_text(json.dumps(self.data, indent=2) + "\n")
        tmp.replace(self.config_path)

    def _load_or_create_config(self) -> None:
        self._config_corrupt = False
        if self.config_path.exists():
            try:
                on_disk = json.loads(self.config_path.read_text())
                if not isinstance(on_disk, dict):
                    raise ValueError("config.json is not an object")
                self.data = {**DEFAULT_CONFIG, **on_disk}
                # The app writes config.json (its own keys: stt_model, language,
                # …) BEFORE the engine's first start, so "first run" almost always
                # hits this branch with no cleanup_model yet. Apply the RAM-based
                # recommendation here too, once, when the app hasn't chosen one.
                if "cleanup_model" not in on_disk:
                    self.data["cleanup_model"] = self._auto_cleanup_model()
                    self.save()
                return
            except Exception as exc:  # noqa: BLE001 — corrupt config must not kill the engine
                log.warning("config.json unreadable (%s); using defaults in memory", exc)
                self.data = dict(DEFAULT_CONFIG)
                # Leave the on-disk file untouched so the user can recover it —
                # flag so the mode migration below doesn't save over it.
                self._config_corrupt = True
                return
        self.data = dict(DEFAULT_CONFIG)
        self.data["cleanup_model"] = self._auto_cleanup_model()
        self.save()
        log.info("wrote default config to %s (cleanup=%s)", self.config_path, self.data["cleanup_model"])

    def _auto_cleanup_model(self) -> str:
        """RAM-fitted cleanup model, falling back to the static default if
        hardware detection ever fails — never block startup on it."""
        try:
            from .models import recommended_cleanup_model

            return recommended_cleanup_model()
        except Exception as exc:  # noqa: BLE001
            log.warning("cleanup-model auto-select failed (%s); using default", exc)
            return DEFAULT_CLEANUP_MODEL

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

    # The exact `apps` list the old default Code mode shipped with. Migration
    # only fires when the on-disk file matches this set (plus empty prompt/vocab/
    # replacements) — so any user customization, even just an edited app list,
    # blocks the rewrite.
    _OLD_CODE_APPS = frozenset({
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
        "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "dev.zed.Zed",
    })

    def _migrate_stale_builtins(self) -> None:
        """One-time upgrade fixup: earlier versions shipped Code mode as
        `formatting:"off"` with an empty prompt and the terminal bundle ids
        folded in. That file is never overwritten by `_ensure_builtin_modes`, so
        upgraders keep a Code mode with no AI instruction that also steals
        terminals from the new Terminal mode. Rewrite it to the current built-in —
        but ONLY when it's still the exact old default (name, off, blank prompt,
        empty vocab/replacements, and the old app set), so ANY user edit is
        preserved. Runs once (guarded by a config marker) so a user who
        deliberately restores the old shape isn't reverted on every start."""
        # Never write over a config we couldn't parse (marker save would clobber
        # the user's hand-recoverable file); also skip if already migrated.
        if self._config_corrupt or self.data.get("builtin_split_migrated"):
            return
        code_path = self.modes_dir / "code.json"
        if code_path.exists():
            try:
                data = json.loads(code_path.read_text())
            except Exception:  # noqa: BLE001 — a bad file is handled by _load_modes
                data = None
            if isinstance(data, dict) and self._is_old_default_code(data):
                pkg = importlib.resources.files("velora_engine") / "modes_builtin" / "code.json"
                code_path.write_text(pkg.read_text())
                log.info("migrated stale built-in code.json to the Code/Terminal split")
        self.data["builtin_split_migrated"] = True
        self.save()

    @classmethod
    def _is_old_default_code(cls, data: dict[str, Any]) -> bool:
        return (
            str(data.get("name", "")).lower() == "code"
            and data.get("formatting") == "off"
            and not str(data.get("prompt", "")).strip()
            and not (data.get("vocabulary") or [])
            and not (data.get("replacements") or {})
            and set(data.get("apps") or []) == cls._OLD_CODE_APPS
        )

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
