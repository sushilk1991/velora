"""The native-model probe must preserve coverage and avoid answer leakage."""

from dataclasses import replace
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.benchmark_cleanup_quality import Case  # noqa: E402
from scripts.benchmark_phonon_refiner import (  # noqa: E402
    NativeEngine, model_file, native_environment, output_result, render_prompt,
    unsupported_reasons, resident_memory, shader_evidence, timing_summary,
    verify_metadata, verify_weights, writing_mode,
)


def test_context_selects_mode_but_expected_structure_does_not():
    case = Case("fixture", "same dictation", bundle_id="com.apple.Terminal")
    assert writing_mode(case) == "prompt"
    assert writing_mode(replace(case, numbered_items=3)) == "prompt"
    assert writing_mode(replace(case, explicit_mode="Note")) == "minimal"
    assert writing_mode(replace(case, bundle_id="com.apple.mail")) == "formal"


def test_custom_and_non_english_features_remain_explicit_failures():
    case = Case("unsupported", "नमस्ते Velora", mode_prompt="do something", romanize=True)
    assert unsupported_reasons(case) == [
        "unsupported_custom_mode_prompt", "unsupported_romanization",
        "unsupported_language_english_only",
    ]
    assert unsupported_reasons(Case("chinese", "第一是书")) == [
        "unsupported_language_english_only",
    ]


def test_prompt_has_thinking_disabled_and_no_fixture_answer():
    class Tokenizer:
        def apply_chat_template(self, messages, **kwargs):
            assert kwargs["enable_thinking"] is False
            assert kwargs["tokenize"] is False
            return json.dumps(messages)

    lines = {"minimal": "Writing mode: minimal (notes and documents)."}
    case = Case("fixture", "please help with the report")
    before = render_prompt(Tokenizer(), case, lines)
    after = render_prompt(
        Tokenizer(), replace(case, required=("secret answer",), numbered_items=3), lines,
    )
    assert before == after
    assert "secret answer" not in before[0]
    assert before[0].startswith(before[1])


def test_output_collapse_falls_back_and_is_a_quality_failure():
    case = Case("collapse", "one two three four five six seven eight nine ten")
    output, failures = output_result(case, {"text": "One.", "tokens": 2}, 48)
    assert output == case.raw
    assert "word_ratio_guard_fired" in failures
    assert "cleanup_not_applied" in failures


def test_token_cap_and_thought_leaks_are_not_accepted():
    case = Case("leak", "hello")
    _, failures = output_result(case, {"text": "<think>hello.</think>", "tokens": 48}, 48)
    assert "output_token_limit" in failures
    assert "leaked_control_token" in failures


def test_snapshot_paths_and_checksums_are_checked(tmp_path):
    with pytest.raises(ValueError, match="relative"):
        model_file(tmp_path, "../outside.gguf")
    invalid = tmp_path / "phonon-refiner-1.7b-Q4_K_S-e4.gguf"
    invalid.write_bytes(b"not the real weights")
    with pytest.raises(ValueError, match="checksum"):
        verify_weights([invalid])


def test_pinned_mode_metadata_rejects_changes(tmp_path):
    (tmp_path / "phonon_refiner.json").write_text('{"writing_modes":{"minimal":"changed"}}')
    with pytest.raises(ValueError, match="metadata checksum mismatch: phonon_refiner.json"):
        verify_metadata(tmp_path)


@pytest.mark.parametrize("name", ["tokenizer.json", "tokenizer_config.json", "config.json"])
def test_tokenizer_and_config_mutation_is_rejected(tmp_path, monkeypatch, name):
    trusted_hash = hashlib.sha256(b"trusted pinned metadata").hexdigest()
    monkeypatch.setattr(
        "scripts.benchmark_phonon_refiner.METADATA_SHA256", {name: trusted_hash},
    )
    (tmp_path / name).write_bytes(b"modified metadata")
    with pytest.raises(ValueError, match=f"metadata checksum mismatch: {name}"):
        verify_metadata(tmp_path)


def test_native_environment_removes_all_inherited_pe_tuning(tmp_path, monkeypatch):
    monkeypatch.setenv("PE_DIR", "/unexpected/shaders")
    monkeypatch.setenv("PE_DEFINE", "CHANGE_MATH=1")
    monkeypatch.setenv("PE_MM", "different-tuning")
    monkeypatch.setenv("VELORA_BENCH_TEST", "preserved")
    environment = native_environment(tmp_path / "pe")
    assert {key: value for key, value in environment.items() if key.startswith("PE_")} == {
        "PE_DIR": str(tmp_path),
    }
    assert environment["VELORA_BENCH_TEST"] == "preserved"


def test_shader_fingerprints_track_the_sources_supplied_to_engine(tmp_path):
    (tmp_path / "mk.metal").write_text("target shader")
    (tmp_path / "df.metal").write_text("draft shader")
    first = shader_evidence(tmp_path / "pe")
    assert set(first) == {"mk.metal", "df.metal"}
    (tmp_path / "mk.metal").write_text("modified target shader")
    second = shader_evidence(tmp_path / "pe")
    assert first["mk.metal"] != second["mk.metal"]
    assert first["df.metal"] == second["df.metal"]


def test_rss_is_converted_from_kib_to_bytes(monkeypatch):
    def fake_ps(command, **kwargs):
        assert command == ["ps", "-o", "rss=", "-p", "123"]
        assert kwargs["timeout"] == 5
        return SimpleNamespace(stdout="  2048\n")

    monkeypatch.setattr("scripts.benchmark_phonon_refiner.subprocess.run", fake_ps)
    assert resident_memory(123) == {"current_bytes": 2097152}


def test_percentiles_weight_each_supported_case_equally():
    records = [
        {"case": "fast", "supported": True, "wall_ms": 1},
        {"case": "fast", "supported": True, "wall_ms": 3},
        {"case": "fast", "supported": True, "wall_ms": 1000},
        {"case": "slow", "supported": True, "wall_ms": 100, "failures": ["quality"]},
        {"case": "unsupported", "supported": False, "failures": ["language"]},
    ]
    summary = timing_summary(records)
    assert summary["sampled_cases"] == 2
    assert summary["sampled_case_names"] == ["fast", "slow"]
    assert summary["case_median_wall_ms"] == {"fast": 3, "slow": 100}
    assert summary["p50_wall_ms"] == 51.5
    assert summary["p95_wall_ms"] == pytest.approx(95.15)


def test_no_supported_timing_is_reported_as_missing_not_zero():
    summary = timing_summary([{"case": "unsupported", "supported": False}])
    assert summary["sampled_cases"] == 0
    assert summary["p50_wall_ms"] is None


def test_native_protocol_ready_request_and_reaping(tmp_path):
    worker = tmp_path / "fake.py"
    worker.write_text(
        "import json,sys\n"
        "print(json.dumps({'ready':True,'init_s':0}),flush=True)\n"
        "for line in sys.stdin:\n"
        " request=json.loads(line)\n"
        " print(json.dumps({'ok':True,'text':request.get('prompt','')}),flush=True)\n"
    )
    engine = NativeEngine([sys.executable, str(worker)], timeout=2)
    try:
        assert engine.call({"prompt": "fixture"}, timeout=2)["text"] == "fixture"
    finally:
        engine.close()
    assert engine.process.poll() is not None


def test_native_protocol_timeout_reaps_worker(tmp_path):
    worker = tmp_path / "hang.py"
    worker.write_text("import time\ntime.sleep(30)\n")
    with pytest.raises(TimeoutError, match="timed out"):
        NativeEngine([sys.executable, str(worker)], timeout=0.05)


def test_native_protocol_failure_keeps_bounded_stderr(tmp_path):
    worker = tmp_path / "crash.py"
    worker.write_text(
        "import sys\n"
        "sys.stderr.write('prefix' + 'x' * 10000 + ' shader failure context')\n"
        "sys.stderr.flush()\n"
        "sys.exit(6)\n"
    )
    with pytest.raises(RuntimeError, match="exited: 6") as caught:
        NativeEngine([sys.executable, str(worker)], timeout=2)
    error = str(caught.value)
    assert "shader failure context" in error
    assert "prefix" not in error
    assert len(error) < 4200
