"""Validated, isolated configuration for a saved-text or unsaved-mode preview."""

from __future__ import annotations

from copy import copy, deepcopy
import importlib.resources
import json
from typing import Any

from .config import Config, Mode

MAX_TEXT_CHARS = 60_000
MAX_PROMPT_CHARS = 12_000
MAX_LIST_ITEMS = 500


def preview_input(msg: dict[str, Any], config: Config) -> tuple[str, Config, str | None]:
    request = msg.get("request_id")
    if not isinstance(request, str) or not request or len(request) > 128:
        raise ValueError("A request identifier is required.")
    raw = msg.get("text")
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError("Enter some text to format.")
    if len(raw) > MAX_TEXT_CHARS:
        raise ValueError(f"Text is limited to {MAX_TEXT_CHARS:,} characters.")
    for key in ("bundle_id", "app_name"):
        value = msg.get(key)
        if value is not None and (not isinstance(value, str) or len(value) > 512):
            raise ValueError(f"Invalid {key}.")
    snapshot = configuration_snapshot(config, personal_context=msg.get("personal_context") is not False)
    name = msg.get("mode")
    inline = msg.get("inline_mode")
    if inline is not None:
        if name is not None:
            raise ValueError("Choose a saved mode or an unsaved mode, not both.")
        mode = validated_mode(inline)
        # Config.mode_by_name indexes by lowercase name.
        snapshot.modes[mode.name.strip().lower()] = mode
        name = mode.name
    elif name is not None:
        if not isinstance(name, str) or not name or snapshot.mode_by_name(name) is None:
            raise ValueError("That mode is not available. Choose another mode.")
    return raw, snapshot, name


def configuration_snapshot(config: Config, *, personal_context: bool = True) -> Config:
    # An asynchronous preview must not change live mode selection or follow a
    # later reload halfway through generation. No Config constructor/reload is
    # used here: a preview neither installs modes nor writes configuration.
    snapshot = copy(config)
    snapshot.data = deepcopy(config.data)
    snapshot.modes = deepcopy(config.modes)
    snapshot._learned_vocab = list(config._learned_vocab)
    snapshot._learned_replacements = dict(config._learned_replacements)
    snapshot._auto_vocab = list(config._auto_vocab)
    if not personal_context:
        # Broker callers supplied text, not access to private snippets, learned
        # spellings, or saved mode instructions. UI previews retain those.
        snapshot.data.update(vocabulary=[], replacements={}, default_mode="Default", allow_snippets=False)
        snapshot._learned_vocab = []
        snapshot._learned_replacements = {}
        snapshot._learned_soft = {}
        snapshot._auto_vocab = []
        directory = importlib.resources.files("velora_engine").joinpath("modes_builtin")
        stock = [Mode.from_dict(json.loads(path.read_text()))
                 for path in directory.iterdir() if path.name.endswith(".json")]
        snapshot.modes = {mode.name.lower(): mode for mode in stock}
        snapshot._mode_files = {}
        snapshot.unbound_builtin_apps = frozenset()
    return snapshot


def validated_mode(value: Any) -> Mode:
    return Mode.from_dict(value)
