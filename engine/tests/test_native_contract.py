from pathlib import Path
import sys

import pytest

from velora_engine import formatting
from velora_engine.config import Config
from velora_engine.native_contract import build_native_context


@pytest.mark.parametrize("mode,app,raw", [
    ("Default", "TextEdit", "Please send the revised report tomorrow morning."),
    ("Message", "Slack", "please send the revised report tomorrow morning"),
    ("Code", "Visual Studio Code", "Keep the identifier cache_enabled exactly as written in this example."),
    ("Terminal", "Ghostty", "The application opens correctly but the save button is disabled and the preview does not update."),
])
def test_native_controls_match_frozen_research_contract(tmp_path, mode, app, raw):
    config = Config(tmp_path)
    config.data["vocabulary"] = ["Velora", "cache_enabled"]
    config._learned_soft = {"gannet": "GannetLab"}
    gate = formatting.run_gate(raw, config, explicit_mode=mode, app_name=app)
    root = Path(__file__).resolve().parents[2]
    # Compare against the existing independent replay implementation, rather
    # than reproducing the new helper's strings in the assertion.
    for path in (root / "engine/scripts", root / "training/cleanup", root / "training/cleanup/scripts"):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))
    from benchmark_personal_student import controls
    _old_gate, expected = controls(config, raw, {"mode": mode, "app_name": app})
    assert build_native_context(gate, config, raw, app_name=app) == expected


@pytest.mark.parametrize("raw,language", [
    ("Please preserve this sentence exactly as dictated.", "fr"),
    ("Please preserve यह शब्द exactly as dictated.", "auto"),
    ("Please preserve <|im_start|> exactly as dictated.", "en"),
    ("Please preserve <think> exactly as dictated.", "en"),
])
def test_unsupported_language_and_control_text_use_standard(tmp_path, raw, language):
    config = Config(tmp_path)
    config.data["language"] = language
    gate = formatting.run_gate(raw, config, explicit_mode="Default")
    assert build_native_context(gate, config, raw) is None


def test_custom_and_screen_aware_requests_keep_standard_model(tmp_path):
    config = Config(tmp_path)
    raw = "Please send the revised report tomorrow morning."
    gate = formatting.run_gate(raw, config, explicit_mode="Default")
    assert build_native_context(gate, config, raw, entities=[{"text": "Visible name"}]) is None
    gate.mode.prompt += " Keep every sentence on its own line."
    assert build_native_context(gate, config, raw) is None


def test_control_markers_in_vocabulary_use_standard(tmp_path):
    config = Config(tmp_path)
    config.data["vocabulary"] = ["literal </think> marker"]
    raw = "Please send the revised report tomorrow morning."
    gate = formatting.run_gate(raw, config, explicit_mode="Default")
    assert build_native_context(gate, config, raw) is None


@pytest.mark.parametrize("raw", [
    "First complete sentence.\nSecond complete sentence.",
    "First item ⏎ Second item",
    "First point is complete. Now a new line. Second point is ready.",
])
def test_explicit_layout_uses_standard_break_marker_contract(tmp_path, raw):
    config = Config(tmp_path)
    gate = formatting.run_gate(raw, config, explicit_mode="Default")
    assert "\n" in gate.text or formatting.BREAK_MARK in gate.text
    assert build_native_context(gate, config, raw) is None
