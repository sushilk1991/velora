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


# ---- auto_punctuation config key ----


def test_auto_punctuation_default_on(config):
    assert config.auto_punctuation is True
    gate = run_gate("send the report", config)
    assert gate.text == "Send the report."


def test_auto_punctuation_off_short_utterance_left_as_dictated(config):
    config.data["auto_punctuation"] = False
    gate = run_gate("send the report", config)
    assert gate.use_llm is False
    assert gate.text == "send the report"  # no capitalization, no period


def test_auto_punctuation_off_chat_short_utterance(config):
    config.data["auto_punctuation"] = False
    gate = run_gate("sounds good to me", config, bundle_id="com.tinyspeck.slackmacgap")
    assert gate.text == "sounds good to me"


def test_auto_punctuation_off_adds_llm_prompt_line(config):
    config.data["auto_punctuation"] = False
    gate = run_gate(LONG, config)
    assert gate.use_llm is True
    assert "Do not add terminal punctuation the speaker did not dictate." in gate.system_prompt


def test_auto_punctuation_on_no_extra_prompt_line(config):
    gate = run_gate(LONG, config)
    assert "Do not add terminal punctuation" not in gate.system_prompt


# ---- code mode trailing period ----


def test_code_mode_strips_trailing_period(config):
    gate = run_gate("git status.", config, bundle_id="com.apple.Terminal")
    assert gate.text == "git status"


def test_code_mode_keeps_ellipsis(config):
    gate = run_gate("wait...", config, bundle_id="com.apple.Terminal")
    assert gate.text == "wait..."


# ---- non-Latin script routing (skip English-tuned cleanup LLM) ----


def test_hindi_skips_llm(config):
    hindi = "नमस्ते आज मौसम बहुत अच्छा है क्या आप मेरे साथ बाजार चलेंगे"
    gate = run_gate(hindi, config)
    assert gate.use_llm is False
    assert gate.reason == "non_latin_script"
    assert gate.system_prompt is None
    assert "नमस्ते" in gate.text  # preserved verbatim, not rewritten


def test_accented_latin_still_uses_llm(config):
    # café/naïve are Latin — must not be misrouted as non-Latin.
    text = "we visited the café and the naïve tourist ordered a très large coffee please"
    gate = run_gate(text, config)
    assert gate.use_llm is True


def test_is_mostly_non_latin_helper():
    assert formatting.is_mostly_non_latin("नमस्ते दुनिया") is True
    assert formatting.is_mostly_non_latin("hello world") is False
    assert formatting.is_mostly_non_latin("café résumé") is False
    assert formatting.is_mostly_non_latin("") is False


def test_cjk_sentence_routes_non_latin_not_short(config):
    # Unspaced CJK splits to one "word" but must take the non-Latin path
    # (no Latin period appended), not short_utterance.
    gate = run_gate("这是一个中文测试今天天气很好", config)
    assert gate.use_llm is False
    assert gate.reason == "non_latin_script"
    assert not gate.text.endswith(".")


def test_romanize_routes_non_latin_to_llm(config):
    config.data["romanize_output"] = True
    gate = run_gate("नमस्ते आज मौसम बहुत अच्छा है क्या आप ठीक हैं", config)
    assert gate.use_llm is True
    assert gate.romanize is True
    assert gate.reason == "romanize"
    assert gate.system_prompt == formatting.ROMANIZE_SYSTEM_PROMPT


def test_romanize_off_keeps_native_script(config):
    config.data["romanize_output"] = False
    gate = run_gate("नमस्ते आज मौसम बहुत अच्छा है क्या आप ठीक हैं", config)
    assert gate.use_llm is False
    assert gate.reason == "non_latin_script"


def test_romanize_ignores_latin_text(config):
    # English text is unaffected by the romanize toggle (already Latin).
    config.data["romanize_output"] = True
    gate = run_gate("please schedule the meeting for tomorrow at three pm", config)
    assert gate.romanize is False


# ---- screen-context entities feed the cleanup prompt ----


def test_entities_injected_into_llm_prompt(config):
    # A Slack (chat, LLM) dictation with screen entities embeds the exact names.
    entities = [{"type": "person", "value": "Priya Sharma"}, {"type": "file", "value": "auth.ts"}]
    gate = run_gate(
        LONG, config, bundle_id="com.tinyspeck.slackmacgap", app_name="Slack", entities=entities
    )
    assert gate.use_llm and gate.system_prompt is not None
    assert "Priya Sharma" in gate.system_prompt
    assert "auth.ts" in gate.system_prompt
    assert "Screen context" in gate.system_prompt


def test_no_entities_no_screen_context_section(config):
    gate = run_gate(LONG, config, bundle_id="com.tinyspeck.slackmacgap", app_name="Slack")
    assert gate.system_prompt is not None
    assert "Screen context" not in gate.system_prompt


def test_entities_dedup_and_blank_skipped(config):
    entities = [{"type": "person", "value": "Alex"}, {"type": "person", "value": "Alex"}, {"type": "file", "value": ""}]
    gate = run_gate(LONG, config, bundle_id="com.apple.mail", app_name="Mail", entities=entities)
    assert gate.system_prompt.count("Alex") == 1


# ---- voice @-tagging ----


def test_tag_trigger_resolves_open_file():
    from velora_engine.formatting import apply_tags
    files = [{"type": "file", "value": "authCheck.ts"}]
    assert apply_tags("fix the bug in tag authCheck", files, "code") == "fix the bug in @authCheck.ts"


def test_tag_spoken_dot_extension():
    from velora_engine.formatting import apply_tags
    assert apply_tags("open main dot py now", [], "code") == "open main.py now"


def test_tag_at_needs_strong_target():
    from velora_engine.formatting import apply_tags
    files = [{"type": "file", "value": "main.py"}]
    # ordinary "at" prose is untouched
    assert apply_tags("meet me at main street", files, "code") == "meet me at main street"
    # identifier-like / dotted target tags
    assert apply_tags("edit at main.py please", files, "code") == "edit @main.py please"


def test_tag_mention_person_in_chat():
    from velora_engine.formatting import apply_tags
    people = [{"type": "person", "value": "Priya Sharma"}]
    assert "@Priya Sharma" in apply_tags("mention Priya about this", people, "chat")


def test_tag_only_in_taggable_categories():
    from velora_engine.formatting import apply_tags
    files = [{"type": "file", "value": "main.py"}]
    assert apply_tags("tag main.py here", files, "email") == "tag main.py here"


# ---- browser site → mode refinement ----


def test_browser_site_refines_mode(config):
    chrome = "com.google.Chrome"
    assert run_gate("...", config, chrome, "Chrome", None, [{"type": "site", "value": "gmail"}]).mode.name == "Email"
    assert run_gate("...", config, chrome, "Chrome", None, [{"type": "site", "value": "github"}]).category == "browser"  # github → prose, no refine
    # unknown / no site → browser stays default
    assert run_gate("...", config, chrome, "Chrome", None, []).category == "browser"


def test_browser_site_yields_to_explicit_mode(config):
    chrome = "com.google.Chrome"
    g = run_gate("...", config, chrome, "Chrome", "Note", [{"type": "site", "value": "gmail"}])
    assert g.mode.name == "Note"


# ---- @-tagging false-positive guards (regression: adversarial review) ----


def test_tag_no_false_positive_on_prose():
    from velora_engine.formatting import apply_tags
    files = [{"type": "file", "value": "test_utils.py"}]
    people = [{"type": "person", "value": "Keith"}]
    for t, ents, cat in [
        ("don't mention it to anyone", people, "chat"),
        ("i tagged him in the photo", people, "chat"),
        ("let's meet at 3pm today", files, "chat"),
        ("we wrapped at 5 in the evening", files, "chat"),
        ("back in the dot com days", files, "chat"),
        ("polka dot top looks nice", files, "chat"),
        ("look at test results please", files, "code"),   # test_utils.py open
        ("call me at 5.30 sharp", files, "chat"),
    ]:
        assert apply_tags(t, ents, cat) == t, f"false-positive tag on: {t!r} -> {apply_tags(t, ents, cat)!r}"


def test_tag_spoken_dot_only_known_extension():
    from velora_engine.formatting import apply_tags
    assert apply_tags("open main dot py", [], "code") == "open main.py"       # known ext
    assert apply_tags("in the dot com days", [], "chat") == "in the dot com days"  # not an ext


def test_browser_site_respects_user_binding(config):
    # User binds Chrome to the Note mode; a Gmail site must not override it.
    config.modes["note"].apps.append("com.google.Chrome")
    g = run_gate("...", config, "com.google.Chrome", "Chrome", None, [{"type": "site", "value": "gmail"}])
    assert g.mode.name == "Note"
