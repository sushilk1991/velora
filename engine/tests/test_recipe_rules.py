"""Declarative recipe rules and transactional reload behavior."""

import json

import pytest

from test_server import AUDIO, connect, engine  # noqa: F401 — isolated fake-STT socket fixture
from velora_engine.config import Config, Mode
from velora_engine.formatting import run_gate
from velora_engine.text_formatting import configuration_snapshot, validated_mode


def write_mode(config, filename, **fields):
    path = config.modes_dir / filename
    path.write_text(json.dumps(fields))
    return path


def test_reload_retains_last_good_mode_until_deleted(home):
    config = Config(home)
    path = write_mode(config, "custom.json", name="Custom", prompt="Keep names", sites=["gmail"])
    config.reload()
    path.write_text('{"name":')
    config.reload()
    assert config.mode_by_name("Custom").prompt == "Keep names"
    assert path.read_text() == '{"name":'
    path.write_text(json.dumps({"name": "Renamed", "prompt": "New valid instructions"}))
    config.reload()
    assert config.mode_by_name("Custom") is None
    assert config.mode_by_name("Renamed").prompt == "New valid instructions"
    path.unlink()
    config.reload()
    assert config.mode_by_name("Renamed") is None


def test_initial_bad_mode_is_not_loaded_and_duplicate_names_are_stable(home):
    config = Config(home)
    path = write_mode(config, "a.json", name="Same", prompt="First")
    write_mode(config, "b.json", name="Same", prompt="Second")
    write_mode(config, "invalid.json", name="Invalid", vocabulary=[True])
    config.reload()
    assert config.mode_by_name("Same").prompt == "First"
    assert config.mode_by_name("Invalid") is None
    path.write_text("[]")
    config.reload()
    assert config.mode_by_name("Same").prompt == "First"


@pytest.mark.parametrize("broken", ['{"cleanup_enabled":', '[]', '{"cleanup_enabled": "yes"}'])
def test_reload_retains_last_good_top_level_config(home, broken):
    config = Config(home)
    config.data.update(cleanup_enabled=False, default_mode="Raw")
    config.save()
    config.config_path.write_text(broken)
    config.reload()
    assert config.cleanup_enabled is False
    assert config.default_mode_name == "Raw"
    assert config.config_path.read_text() == broken


def test_site_rule_priority_and_automatic_fallback(home):
    config = Config(home)
    config.modes["recipe"] = Mode.from_dict({"name": "Recipe", "sites": ["gmail"]})
    context = dict(bundle_id="com.google.Chrome", entities=[{"type": "site", "value": "gmail"}])
    assert run_gate("hello", config, **context).mode.name == "Recipe"
    config.modes["bound"] = Mode.from_dict({"name": "Bound", "apps": ["com.google.Chrome"]})
    assert run_gate("hello", config, **context).mode.name == "Bound"
    assert run_gate("hello", config, explicit_mode="Note", **context).mode.name == "Note"
    del config.modes["bound"]
    assert run_gate("hello", config, explicit_mode="missing", **context).mode.name == "Recipe"
    config.modes["recipe"].sites = []
    assert run_gate("hello", config, **context).mode.name == "Email"


def test_ordered_steps_have_noncommutative_effect_and_never_use_model(home):
    config = Config(home)
    mode = Mode.from_dict({"name": "Rules", "steps": ["replacements", "spoken_commands"],
                           "replacements": {"break": "new line"}})
    config.modes["rules"] = mode
    first = run_gate("one break two", config, explicit_mode="Rules")
    assert first.text == "one\ntwo"
    assert first.use_llm is False
    mode.steps.reverse()
    second = run_gate("one break two", config, explicit_mode="Rules")
    assert second.text == "one new line two"
    assert second.use_llm is False
    mode.steps = []
    config.data["romanize_output"] = True
    literal = run_gate("उह नमस्ते दुनिया", config, explicit_mode="Rules")
    assert literal.text == "उह नमस्ते दुनिया"
    assert literal.use_llm is False


def test_fast_and_technical_modes_keep_their_contract(home):
    config = Config(home)
    config.modes["rules"] = Mode.from_dict({"name": "Rules", "steps": ["fillers", "punctuation"]})
    config.data["cleanup_enabled"] = False
    gate = run_gate("um hello full stop", config, explicit_mode="Rules")
    assert gate.text == "um hello full stop"
    assert gate.use_llm is False
    config.data["cleanup_enabled"] = True
    for name in ("Raw", "Terminal"):
        gate = run_gate("um echo hello", config, explicit_mode=name)
        assert gate.text == "um echo hello"
        assert gate.use_llm is False


@pytest.mark.parametrize("fields", [
    {"name": " "}, {"name": "x" * 241}, {"name": "x", "prompt": None},
    {"name": "x", "apps": [False]}, {"name": "x", "sites": ["made-up"]},
    {"name": "x", "sites": ["gmail", "gmail"]}, {"name": "x", "steps": ["execute"]},
    {"name": "x", "steps": ["fillers", "fillers"]}, {"name": "x", "steps": "fillers"},
    {"name": "x", "steps": None}, {"name": "x", "steps": [], "formatting": "off"},
    {"name": "Raw", "steps": []}, {"name": "Code", "steps": ["fillers"]},
    {"name": "x", "vocabulary": ["v" * 201]}, {"name": "x", "replacements": {" ": "a"}},
    {"name": "x", "command": "rm"}, {"name": "x", "prompt": "\ud800"},
])
def test_preview_and_disk_share_strict_validation(fields):
    with pytest.raises(ValueError):
        Mode.from_dict(fields)
    with pytest.raises(ValueError):
        validated_mode(fields)


def test_unicode_limits_and_private_snapshot(home):
    fields = {"name": "🙂" * 240, "prompt": "🙂" * 12_000,
              "vocabulary": ["e\u0301" * 100], "steps": [], "sites": ["gmail"]}
    assert validated_mode(fields).name == fields["name"]
    config = Config(home)
    config.modes["private"] = Mode.from_dict({"name": "Private", "sites": ["gmail"],
                                              "steps": ["replacements"], "replacements": {"x": "SECRET"}})
    snapshot = configuration_snapshot(config, personal_context=False)
    assert snapshot.mode_by_name("Private") is None
    assert all(not mode.sites and mode.steps is None for mode in snapshot.modes.values())


def test_existing_long_mode_name_loads_and_previews_with_shared_schema_limit(home):
    from pathlib import Path
    from velora_engine.text_formatting import preview_input
    config = Config(home)
    name = "x" * 230
    write_mode(config, name + ".json", name=name, prompt="Preserve the existing mode", steps=[])
    config.reload()
    mode = config.mode_by_name(name)
    assert mode is not None and mode.name == name
    raw, snapshot, selected = preview_input({"request_id": "long-name", "text": "hello", "mode": name}, config)
    assert selected == name and run_gate(raw, snapshot, explicit_mode=selected).text == "hello"
    schema = json.loads((Path(__file__).parents[1] / "schemas" / "mode.schema.json").read_text())
    assert schema["$defs"]["mode"]["properties"]["name"]["maxLength"] == 240


def test_explicit_rules_do_not_expand_snippets(home, monkeypatch):
    from velora_engine import formatting
    config = Config(home)
    config.modes["literal prose"] = Mode.from_dict({"name": "Literal prose", "steps": []})
    monkeypatch.setattr(formatting, "snippet_expansion", lambda *_: "unexpected expansion")
    assert run_gate("insert template", config, explicit_mode="Literal prose").text == "insert template"


def test_migration_snapshots_validate_and_site_assignment_prevents_legacy_rewrite():
    from velora_engine import config as config_module
    for revisions in config_module._BUILTIN_MODE_SUPERSEDED.values():
        for fields in revisions:
            Mode.from_dict(fields)
    old = {"name": "Code", "formatting": "off", "apps": list(Config._OLD_CODE_APPS), "sites": ["gmail"]}
    assert Config._is_old_default_code(old) is False


def test_corrupt_migration_marker_cannot_crash_reload(home):
    config = Config(home)
    config.config_path.write_text('{"builtin_modes_rev":"oops"}')
    config.reload()
    assert config._config_corrupt is True
    assert config.config_path.read_text() == '{"builtin_modes_rev":"oops"}'


async def test_server_formatting_executes_disabled_model_rules_without_loading(home):
    from types import SimpleNamespace
    from velora_engine.server import Engine
    config = Config(home)
    config.modes["rules"] = Mode.from_dict({"name": "Rules", "steps": ["replacements", "spoken_commands"],
                                            "replacements": {"break": "new line"}})

    async def forbidden(*args, **kwargs):
        raise AssertionError("A model-free rule sequence attempted to use the writing model")

    # Exercise the same formatting method used by dictation and Try it,
    # without constructing audio/model workers or opening a real user home.
    engine = Engine.__new__(Engine)
    engine.config = config
    engine.cleanup = SimpleNamespace(loaded=False, cleanup=forbidden)
    engine._ensure_cleanup_loaded = forbidden
    text, name, ms, applied, reason = await engine._apply_formatting(
        "first break second", bundle_id=None, app_name=None, explicit_mode="Rules")
    assert (text, name, ms, applied, reason) == ("first\nsecond", "Rules", 0, False, "recipe_steps")


@pytest.mark.parametrize("site", [[], {}, None, 42, False])
def test_malformed_site_entity_does_not_interrupt_gate(home, site):
    config = Config(home)
    gate = run_gate("hello world", config, bundle_id="com.google.Chrome",
                    entities=[{"type": "site", "value": site}])
    assert gate.mode.name == "Default"
    assert gate.text == "Hello world."
    assert config.mode_for_site(site) is None


def test_invalid_site_entities_are_ignored_before_valid_site_rule(home):
    config = Config(home)
    config.modes["recipe"] = Mode.from_dict({"name": "Recipe", "sites": ["gmail"], "steps": []})
    gate = run_gate("hello world", config, bundle_id="com.google.Chrome", entities=[
        {"type": "site", "value": {}}, {"type": "site", "value": " GMAIL "}])
    assert gate.mode.name == "Recipe"
    assert gate.text == "hello world"


@pytest.mark.parametrize("site", [[], {}])
async def test_stop_with_malformed_site_still_delivers_terminal_final_event(engine, site):
    eng, sock = engine
    client = await connect(sock)
    try:
        await client.recv_event("ready")
        await client.send_json({"cmd": "start", "session": "malformed-site", "context": {
            "bundle_id": "com.google.Chrome", "app_name": "Chrome"}})
        await client.send_audio(AUDIO)
        await client.send_json({"cmd": "stop", "session": "malformed-site", "entities": [
            {"type": "site", "value": site}]})
        transcript = await client.recv_event("transcript")
        assert transcript["raw"] == "hello world this is a fake transcript"
        final = await client.recv_event("final", timeout=1.0)
        assert final["session"] == "malformed-site"
        assert final["mode"] == "Default"
        assert final["text"] == transcript["raw"] + "."
        assert eng.session is None
        await client.send_json({"cmd": "ping"})
        assert (await client.recv_event("pong"))["event"] == "pong"
    finally:
        client.close()
        await client.writer.wait_closed()
