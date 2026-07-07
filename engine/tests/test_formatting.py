"""Formatting gate decisions: mode resolution, short-utterance, code category,
replacements, spoken commands, chat trailing period."""

from velora_engine import formatting
from velora_engine.formatting import (
    apply_replacements,
    apply_spoken_commands,
    resolve_mode,
    run_gate,
    strip_chat_trailing_period,
)

LONG = "so I think we should probably move the quarterly planning meeting to next Tuesday because the client visit got rescheduled"


# ---- mode resolution: explicit > per-app bundle-id match > default ----


def test_builtin_modes_installed(config):
    assert {"raw", "default", "message", "email", "note", "code"} <= set(config.modes)


def test_resolve_explicit_beats_bundle(config):
    mode = resolve_mode(config, bundle_id="com.tinyspeck.slackmacgap", explicit_mode="Email")
    assert mode.name == "Email"


def test_resolve_bundle_match(config):
    assert resolve_mode(config, "com.tinyspeck.slackmacgap", None).name == "Message"
    assert resolve_mode(config, "com.apple.mail", None).name == "Email"
    assert resolve_mode(config, "md.obsidian", None).name == "Note"


def test_resolve_default_fallback(config):
    assert resolve_mode(config, "com.unknown.app", None).name == "Default"
    assert resolve_mode(config, None, None).name == "Default"
    # browsers → default
    assert resolve_mode(config, "com.apple.Safari", None).name == "Default"


def test_resolve_unknown_explicit_falls_through(config):
    assert resolve_mode(config, "com.apple.mail", "Nonexistent").name == "Email"


# ---- code category → formatting off ----


def test_code_category_formatting_off(config):
    for bid in ("com.microsoft.VSCode", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.zed.Zed"):
        gate = run_gate("git rebase dash dash interactive head tilde three " + LONG, config, bundle_id=bid)
        assert gate.mode.name == "Code"
        assert gate.use_llm is False
        assert gate.reason == "formatting_off"
    assert formatting.category_for_bundle("com.googlecode.iterm2") == "code"
    assert formatting.category_for_bundle("com.google.Chrome") == "browser"


def test_code_mode_applies_spoken_newlines_without_llm(config):
    gate = run_gate("first line new line second line", config, bundle_id="com.apple.Terminal")
    assert gate.use_llm is False
    assert gate.text == "first line\nsecond line"


# ---- short utterance → punctuation-only ----


def test_short_utterance_never_uses_llm(config):
    gate = run_gate("send the report", config)
    assert gate.use_llm is False
    assert gate.reason == "short_utterance"
    assert gate.text == "Send the report."


def test_short_utterance_chat_no_trailing_period(config):
    gate = run_gate("sounds good to me", config, bundle_id="com.tinyspeck.slackmacgap")
    assert gate.use_llm is False
    assert gate.text == "Sounds good to me"


def test_long_utterance_uses_llm(config):
    gate = run_gate(LONG, config)
    assert gate.use_llm is True
    assert gate.reason == "llm"
    assert gate.system_prompt is not None
    assert gate.system_prompt.startswith(formatting.STATIC_SYSTEM_PROMPT)


# ---- system prompt assembly ----


def test_prompt_contains_app_context_and_vocab(config):
    config.data["vocabulary"] = ["Velora", "MLX"]
    gate = run_gate(LONG, config, bundle_id="com.tinyspeck.slackmacgap", app_name="Slack")
    assert "dictating into Slack" in gate.system_prompt
    assert "a casual chat message" in gate.system_prompt
    assert "Velora" in gate.system_prompt and "MLX" in gate.system_prompt


# ---- replacements: word-boundary, case-aware ----


def test_replacements_word_boundary():
    out = apply_replacements("open vs code and scode now", {"vs code": "VS Code"})
    assert out == "open VS Code and scode now"


def test_replacements_case_aware():
    # lowercase target capitalized at sentence start stays capitalized
    out = apply_replacements("Kubernetes cluster", {"kubernetes": "kubernetes"})
    assert out == "Kubernetes cluster"
    # canonical casing in the value always wins
    out = apply_replacements("i use Github daily", {"github": "GitHub"})
    assert out == "i use GitHub daily"


def test_replacements_applied_in_gate_paths(config):
    (config.home / "modes" / "default.json").write_text(
        '{"name":"Default","formatting":"full","replacements":{"vs code":"VS Code"}}'
    )
    config.reload()
    gate = run_gate("open vs code now", config)
    assert gate.text == "Open VS Code now."


# ---- spoken commands ----


def test_spoken_commands():
    assert apply_spoken_commands("one new line two new paragraph three") == "one\ntwo\n\nthree"
    assert apply_spoken_commands("hello. New line. Next") == "hello\nNext"


# ---- chat trailing period ----


def test_strip_chat_trailing_period():
    assert strip_chat_trailing_period("On my way.") == "On my way"
    # multi-sentence untouched
    assert strip_chat_trailing_period("Done. Shipping now.") == "Done. Shipping now."


def test_postprocess_chat(config):
    gate = run_gate(LONG, config, bundle_id="com.tinyspeck.slackmacgap", app_name="Slack")
    assert formatting.postprocess("Got it, will do.", gate) == "Got it, will do"


# ---- filler scrub (deterministic, pre-LLM) ----


def test_scrub_fillers_any_casing():
    from velora_engine.formatting import scrub_fillers

    assert scrub_fillers("UM, so I think we should ship") == "so I think we should ship"
    assert scrub_fillers("Hi UM. Following up") == "Hi. Following up"
    assert scrub_fillers("Can you, UM, send the assets?") == "Can you, send the assets?"
    assert scrub_fillers("uh yeah umm sounds good") == "yeah sounds good"
    # never inside words
    assert scrub_fillers("the umbrella and the uhlan") == "the umbrella and the uhlan"


def test_short_utterance_scrubs_fillers(config):
    gate = run_gate("um send the report", config)
    assert gate.text == "Send the report."


def test_llm_path_prescrubbed(config):
    gate = run_gate("UM, so I think we should probably move the quarterly planning meeting", config)
    assert gate.use_llm is True
    assert gate.text.startswith("so I think")


# ---- code mode trailing period ----


def test_code_mode_strips_trailing_period(config):
    gate = run_gate("git status.", config, bundle_id="com.apple.Terminal")
    assert gate.text == "git status"


def test_code_mode_keeps_ellipsis(config):
    gate = run_gate("wait...", config, bundle_id="com.apple.Terminal")
    assert gate.text == "wait..."
