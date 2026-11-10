import json

from velora_engine.formatting import run_gate


def test_whole_dictation_expands_literal_snippet(config):
    (config.home / "snippets.json").write_text(json.dumps({"version": 1, "snippets": [
        {"id": "signature", "trigger": "insert my signature", "text": "Regards,\nSushil"}]}))
    gate = run_gate("Insert my signature.", config)
    assert gate.text == "Regards,\nSushil"
    assert not gate.use_llm and gate.mode.name == "Snippet"
    assert run_gate("please insert my signature tomorrow", config).mode.name != "Snippet"
    assert run_gate("insert my signature", config, explicit_mode="Raw").text == "insert my signature"
    assert run_gate("insert my signature", config, bundle_id="com.apple.Terminal").mode.name != "Snippet"


def test_corrupt_or_duplicate_snippets_preserve_dictation(config):
    path = config.home / "snippets.json"
    path.write_text("not json")
    assert run_gate("hello", config).mode.name != "Snippet"
    path.write_text(json.dumps({"version": 1, "snippets": [
        {"trigger": "hello", "text": "one"}, {"trigger": "Hello", "text": "two"}]}))
    assert run_gate("hello", config).mode.name != "Snippet"



def test_supplied_text_preview_cannot_read_saved_private_content(config):
    from velora_engine.text_formatting import preview_input
    (config.home / "snippets.json").write_text(json.dumps({"version": 1, "snippets": [
        {"trigger": "insert my address", "text": "Private address"}]}))
    config.data["replacements"] = {"my address": "Private address"}
    config.data["vocabulary"] = ["PrivateCustomerName"]
    raw, snapshot, mode = preview_input({"request_id": "agent", "text": "insert my address",
                                          "personal_context": False}, config)
    assert snapshot.global_vocabulary == []
    assert snapshot.global_replacements == {}
    assert run_gate(raw, snapshot, explicit_mode=mode).mode.name != "Snippet"
