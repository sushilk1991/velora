"""Built-in mode refresh migration.

`_ensure_builtin_modes` never overwrites an installed mode file, so improved
built-in prompts/app lists would otherwise reach only fresh installs. The
refresh migration closes that gap with a hard rule: an installed file is
rewritten ONLY when it is byte-for-byte semantically equal to a revision this
repo previously shipped — any user edit, however small, blocks the refresh
forever for that file.
"""

import importlib.resources
import json

from velora_engine import config as config_mod
from velora_engine.config import Config


def _packaged(name: str) -> dict:
    res = importlib.resources.files("velora_engine") / "modes_builtin" / name
    return json.loads(res.read_text())


# The exact note.json v1 shipped from the first release through c4044b0.
OLD_NOTE = {
    "name": "Note",
    "prompt": (
        "The user is dictating a note. Markdown is allowed. Use a bulleted "
        "list ONLY when the speech clearly enumerates items (e.g. 'first... "
        "second...', 'one... two...'); otherwise keep prose. Paragraph breaks "
        "on topic shifts."
    ),
    "formatting": "full",
    "apps": [
        "com.apple.Notes",
        "md.obsidian",
        "notion.id",
        "net.shinyfrog.bear",
        "com.lukilabs.lukiapp",
    ],
    "vocabulary": [],
    "replacements": {},
}


def test_pristine_previous_revision_is_refreshed(home):
    cfg = Config()
    note = cfg.modes_dir / "note.json"
    note.write_text(json.dumps(OLD_NOTE, indent=2))
    cfg.data["builtin_modes_rev"] = 0
    cfg._refresh_builtin_modes()
    assert json.loads(note.read_text()) == _packaged("note.json")


def test_user_customized_file_is_never_touched(home):
    cfg = Config()
    edited = dict(OLD_NOTE, prompt=OLD_NOTE["prompt"] + " Always use emoji.")
    note = cfg.modes_dir / "note.json"
    note.write_text(json.dumps(edited, indent=2))
    cfg.data["builtin_modes_rev"] = 0
    cfg._refresh_builtin_modes()
    assert json.loads(note.read_text()) == edited


def test_marker_prevents_a_second_pass(home):
    cfg = Config()
    assert int(cfg.data.get("builtin_modes_rev") or 0) >= config_mod._BUILTIN_MODES_REV
    note = cfg.modes_dir / "note.json"
    note.write_text(json.dumps(OLD_NOTE, indent=2))
    cfg._refresh_builtin_modes()  # marker already satisfied → no rewrite
    assert json.loads(note.read_text()) == OLD_NOTE


def test_fresh_install_lands_on_current_revision(home):
    """First run installs the current files and stamps the marker, so the
    refresh never rewrites anything on a brand-new home."""
    cfg = Config()
    for res in (importlib.resources.files("velora_engine") / "modes_builtin").iterdir():
        if res.name.endswith(".json"):
            installed = json.loads((cfg.modes_dir / res.name).read_text())
            assert installed == json.loads(res.read_text())
    assert int(cfg.data.get("builtin_modes_rev") or 0) >= config_mod._BUILTIN_MODES_REV


def test_corrupt_mode_file_is_skipped_not_crashed(home):
    cfg = Config()
    note = cfg.modes_dir / "note.json"
    note.write_text("{not json")
    cfg.data["builtin_modes_rev"] = 0
    cfg._refresh_builtin_modes()  # must not raise
    assert note.read_text() == "{not json"


def test_every_superseded_revision_parses_and_differs_from_current():
    """The history table itself must stay valid: every entry parses, and no
    entry equals the current packaged file (that would make the table lie)."""
    for name, revisions in config_mod._BUILTIN_MODE_SUPERSEDED.items():
        current = _packaged(name)
        for old in revisions:
            assert old != current, f"{name}: superseded entry equals current"
            assert old.get("name"), f"{name}: superseded entry missing name"


def test_deliberate_unbind_is_not_recaptured_by_the_fallback(home):
    """Removing an app from a built-in mode file means 'give me Default
    there' — the category fallback must not silently re-capture it."""
    from velora_engine.formatting import resolve_mode

    cfg = Config()
    term = json.loads((cfg.modes_dir / "terminal.json").read_text())
    term["apps"].remove("com.googlecode.iterm2")
    (cfg.modes_dir / "terminal.json").write_text(json.dumps(term))
    cfg.reload()
    assert "com.googlecode.iterm2" in cfg.unbound_builtin_apps
    assert resolve_mode(cfg, "com.googlecode.iterm2", None).name == "Default"
    # Apps still claimed resolve normally, and a pristine install unbinds none.
    assert resolve_mode(cfg, "com.apple.Terminal", None).name == "Terminal"
    fresh_home = home / "fresh"
    import os
    os.environ["VELORA_HOME"] = str(fresh_home)
    try:
        assert Config().unbound_builtin_apps == frozenset()
    finally:
        os.environ["VELORA_HOME"] = str(home)
