"""Replacement evidence fails closed on missing samples or host contamination."""
from copy import deepcopy
import asyncio
import json
from pathlib import Path
import struct
import sys
from types import SimpleNamespace

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import benchmark_model_replacement as study  # noqa: E402
import compare_model_replacement as comparison  # noqa: E402


def sample(**kw):
    return {"load1": 4, "pressure": 1, "swapouts": 100, "swap_used_mb": 1000, **kw}


def test_raw_tails_include_one_slow_or_failed_request():
    # A percentile of per-fixture medians would hide this timeout.
    values = [1.0] * 19 + [4000.0]
    assert study.percentiles(values)["p95"] > 1
    assert study.percentiles(values)["p99"] > 3000


@pytest.mark.parametrize("values", [[], [float("nan")], [float("inf")], [-1]])
def test_missing_invalid_latency_fails_closed(values):
    with pytest.raises(ValueError):
        study.percentiles(values)


def test_transient_host_pressure_cannot_be_hidden_by_final_recovery():
    samples = [sample(), sample(load1=21, pressure=2, swapouts=101,
                                swap_used_mb=1100), sample()]
    assert set(study.contamination(samples)) == {
        "host_load1_ge_20", "host_memory_pressure", "host_swapouts", "host_swap_used_growth",
    }
    assert study.contamination([sample(), sample()]) == []
    assert study.contamination([]) == ["missing_host_telemetry"]


def test_logical_parameters_unpack_quantized_weights_without_counting_scales(tmp_path):
    (tmp_path / "config.json").write_text(json.dumps({"quantization": {"group_size": 64}}))
    header = {
        "model.language_model.layers.0.weight": {"shape": [2, 16], "dtype": "U32"},
        "model.language_model.layers.0.scales": {"shape": [2, 1], "dtype": "BF16"},
        "model.language_model.layers.0.biases": {"shape": [2, 1], "dtype": "BF16"},
        "model.visual.weight": {"shape": [2, 3], "dtype": "BF16"},
        "model.language_model.norm.weight": {"shape": [2], "dtype": "F32"},
    }
    data = json.dumps(header).encode()
    (tmp_path / "model.safetensors").write_bytes(struct.pack("<Q", len(data)) + data)
    evidence = study.model_evidence(tmp_path)
    assert evidence["logical_parameters_text"] == 130
    assert evidence["logical_parameters_all_tensors"] == 136
    assert evidence["artifact_bytes"] == sum(p.stat().st_size for p in tmp_path.iterdir()
                                             if p.is_file())
    assert len(evidence["files"]["model.safetensors"]["sha256"]) == 64


def complete_round():
    def run(scale):
        cases = [{"case": str(i), "failures": [], "unique_outputs": 1,
                  "output": "public fixture"} for i in range(10)]
        return {
            "model": {"artifact_bytes": 1000 * scale, "logical_parameters_text": 100 * scale},
            "result": {"requests": 10, "summary": {
                "footprint_after_load": {"peak_bytes": 1000 * scale},
                "footprint_after_inference": {"peak_bytes": 1000 * scale}},
                "peak_rss_bytes": 1000 * scale, "runtime": {"mlx": "pinned"}},
            "requests": [{"case": c["case"], "duration_ms": 100 * scale} for c in cases],
            "cases": cases, "host": [sample(time_ns=1)],
        }
    a, b = run(1), run(0.5)
    runs = [a, b, deepcopy(b), deepcopy(a)]
    for i, r in enumerate(runs):
        r["result"].update(model_id="mlx-community/Qwen3.5-4B-MLX-8bit" if i in (0,3) else "candidate",
                           prompt_style="production", copy_draft_allowlist_override=False,
                           cache_limit_mb_override=None)
        r["result"].update(expected_cases=[str(n) for n in range(10)], repeats=1,
                           worker_pids=[123], started_ns=i*10+1, ended_ns=i*10+2)
    return runs


def test_passing_screen_still_requires_full_qualification():
    result = comparison.compare(complete_round())
    assert result["screen_passed"]
    assert not result["promotion_qualified"]
    assert result["improvements_pct"]["p95"] == 50


@pytest.mark.parametrize("field", ["artifact_bytes", "logical_parameters_text"])
def test_quantization_alone_cannot_pass_fewer_parameters(field):
    runs = complete_round()
    for run in runs[1:3]:
        run["model"][field] = runs[0]["model"][field]
    assert field in comparison.compare(runs)["failures"]


def test_missing_peak_cannot_be_treated_as_memory_savings():
    runs = complete_round()
    runs[1]["result"]["summary"]["footprint_after_load"] = {"error": "tool failed"}
    assert "missing_peak_memory" in comparison.compare(runs)["failures"]


def test_new_failure_in_existing_failed_case_cannot_hide_in_total_score():
    runs = complete_round()
    for i in (0, 3):
        runs[i]["cases"][0]["failures"] = ["old"]
    for i in (1, 2):
        runs[i]["cases"][0]["failures"] = ["old", "new"]
    result = comparison.compare(runs)
    assert result["quality_regressions"] == {"0": ["new"]}
    assert not result["screen_passed"]


def test_round_swap_drift_is_rejected_even_if_each_worker_has_no_swap_delta():
    runs = complete_round()
    for i, run in enumerate(runs):
        run["host"] = [sample(time_ns=i, swapouts=100 + i)]
    assert "host_swapouts" in comparison.compare(runs)["failures"]


def test_runtime_and_workload_mismatch_cannot_pass():
    runs = complete_round()
    runs[1]["result"]["runtime"]["mlx"] = "different"
    runs[1]["requests"].pop()
    failures = comparison.compare(runs)["failures"]
    assert "runtime_mismatch" in failures
    assert "request_count_mismatch" in failures
    assert "workload_mismatch" in failures


@pytest.mark.parametrize("reason", ["error:worker exited", "timeout_hard", "timeout_queue", "llm_recovering"])
def test_worker_failure_cannot_pass_even_if_quality_matches_baseline(reason):
    runs = complete_round()
    runs[1]["requests"][0]["reason"] = reason
    assert "inference_failure" in comparison.compare(runs)["failures"]


def test_worker_model_argument_is_forwarded_without_abbreviation(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(study, "worker", lambda *args: calls.append(args))
    monkeypatch.setattr(sys, "argv", ["benchmark", "--worker", "--telemetry",
                                     str(tmp_path / "worker.jsonl"), "--model", "model-id",
                                     "--local-model-path", "/weights", "--fd", "17"])
    assert study.main() == 0
    assert calls[0][-1] == ["--model", "model-id", "--local-model-path", "/weights", "--fd", "17"]


def test_isolated_worker_keeps_production_id_and_copy_draft_and_reaps_load_failure(
    monkeypatch, tmp_path,
):
    engines = []

    class Process:
        def __init__(self, identity, **kwargs):
            self.identity, self.options, self.closed = identity, kwargs, False
            engines.append(self)

        async def load_async(self, prompt):
            raise RuntimeError("controlled load failure")

        async def aclose(self):
            self.closed = True

    async def fail_load(model_id, config, selected, repeats):
        engine = study.quality.CleanupProcess("/weights")
        await engine.load_async("production system")

    monkeypatch.setattr(study, "CleanupProcess", Process)
    monkeypatch.setattr(study.quality, "_run_model", fail_load)
    monkeypatch.setattr(study, "host_snapshot", lambda: sample(time_ns=1))
    monkeypatch.setattr(study, "model_evidence", lambda path: {})
    monkeypatch.setattr(study, "runtime_versions", lambda: {"mlx": "test"})
    monkeypatch.setenv("VELORA_HOME", str(tmp_path / "original-home"))
    args = SimpleNamespace(output=tmp_path / "run", model_path=tmp_path,
                           model_id="logical-production-id", prompt_style="production",
                           repeats=2, cache_limit_mb=None, copy_draft=False)
    assert asyncio.run(study.run(args)) == 1
    assert engines[0].identity == "logical-production-id"
    assert engines[0].options["local_model_path"] == "/weights"
    assert engines[0].closed
    assert study.os.environ["VELORA_HOME"] == str(tmp_path / "original-home")
    result = json.loads((args.output / "result.json").read_text())
    assert result["copy_draft_requested"]
    assert "incomplete_run" in result["contamination"]


def test_second_candidate_predicate_regression_is_rejected():
    runs = complete_round()
    for r in runs:
        r["cases"][0]["failures"] = ["old"]
    runs[2]["cases"][0]["failures"].append("new")
    assert comparison.compare(runs)["quality_regressions"] == {"0": ["new"]}


def test_copied_round_or_changed_policy_is_rejected():
    runs = complete_round()
    runs[3] = deepcopy(runs[0])
    runs[2]["result"]["prompt_style"] = "changed"
    failures = comparison.compare(runs)["failures"]
    assert "invalid_round_chronology" in failures
    assert "policy_drift" in failures


def test_specialist_control_line_does_not_restore_ungated_raw_input():
    case = study.quality.CASES[0]
    _, text = study.quality.s1_mini_prompt(case, "first line\nsecond line")
    assert text.split("\n", 1)[1] == "first line\nsecond line"
    assert case.raw not in text


def test_muesli_uses_documented_manual_prompt_without_a_chat_template():
    class Tokenizer:
        def encode(self, text, *, add_special_tokens):
            assert add_special_tokens is False
            assert text == ("<|im_start|>user\nsystem\n\ntranscript<|im_end|>\n"
                            "<|im_start|>assistant\n<think>\n\n</think>\n\n")
            return [1, 2]
    assert study.muesli_tokens(Tokenizer(), "system", "transcript") == [1, 2]
    assert "dictated it.\n\nYou may:" in study.MUESLI_PROMPT


def test_muesli_worker_adds_required_turn_stop_without_changing_snapshot(monkeypatch, tmp_path):
    import velora_engine
    observed = []

    class Tokenizer:
        eos_token_ids = {248044}  # Snapshot config: end of text, not turn.

        def add_eos_token(self, token):
            assert token == '<|im_end|>'
            self.eos_token_ids = self.eos_token_ids | {248046}

    class Engine:
        def load(self):
            self._tokenizer = Tokenizer()

        def _memory_metrics(self, reset_peak):
            raise AssertionError('No GPU measurement in this regression')

    def main():
        engine = Engine()
        engine.load()
        observed.append(engine._tokenizer.eos_token_ids)

    monkeypatch.setattr(velora_engine, 'cleanup', SimpleNamespace(CleanupEngine=Engine), raising=False)
    monkeypatch.setattr(velora_engine, 'cleanup_worker', SimpleNamespace(main=main), raising=False)
    monkeypatch.setattr(sys, 'argv', ['benchmark'])
    study.worker(tmp_path / 'worker.jsonl', 'muesli', None, False, [])
    assert observed == [{248044, 248046}]
