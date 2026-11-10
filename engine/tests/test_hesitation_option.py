from velora_engine.formatting import run_gate


def test_fast_dictation_hesitation_removal_is_opt_in(config):
    config.data["cleanup_enabled"] = False
    assert run_gate("um send the report", config).text == "um send the report"
    config.data["remove_hesitations"] = True
    gate = run_gate("um, uh, send the report", config)
    assert gate.text == "send the report"
    assert not gate.use_llm


def test_hesitation_option_preserves_literal_and_code_words(config):
    config.data.update(cleanup_enabled=False, remove_hesitations=True)
    for text in ["uh-huh like the umbrella", 'say "um" aloud', "use `uh` here"]:
        assert run_gate(text, config).text == text
    assert run_gate("um echo hello", config, explicit_mode="Raw").text == "um echo hello"
    assert run_gate("um echo hello", config, bundle_id="com.apple.Terminal").text == "um echo hello"
