"""Allocator experiments must preserve production identity and fail closed."""

import asyncio
import io
import json
import os
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts import benchmark_cleanup_resources as resources  # noqa: E402


def evidence(*, failures=(), output="Hello.", unique_outputs=1):
    return [
        {
            "event": "case", "case": "fixture", "output": output,
            "applied": True, "unique_outputs": unique_outputs,
            "failures": list(failures),
        },
        {
            "event": "summary", "model": "incumbent",
            "resolved_revision": "immutable", "weight_sha256": {"weights": "hash"},
        },
    ]


def test_comparison_allows_known_failure_but_requires_exact_stable_output():
    baseline = evidence(failures=("known_fixture_failure",))
    verdict = resources.compare_records(baseline, evidence(failures=("known_fixture_failure",)))

    assert verdict["accepted"]
    assert verdict["baseline_failed_cases"] == ["fixture"]
    assert verdict["candidate_failed_cases"] == ["fixture"]
    assert not resources.compare_records(baseline, evidence(output="Changed."))["accepted"]
    assert not resources.compare_records(evidence(unique_outputs=2), evidence())["accepted"]


def test_new_failure_in_an_already_failing_case_is_rejected():
    verdict = resources.compare_records(
        evidence(failures=("known",)), evidence(failures=("known", "new")),
    )

    assert not verdict["accepted"]
    assert verdict["new_quality_failures"] == {"fixture": ["new"]}


def test_comparison_requires_case_coverage_and_model_identity():
    assert not resources.compare_records(evidence(), evidence()[1:])["accepted"]
    candidate = evidence()
    candidate[1]["weight_sha256"] = {"weights": "different"}
    assert "model_evidence_mismatch" in resources.compare_records(evidence(), candidate)["failures"]
    candidate[1].pop("weight_sha256")
    assert "missing_model_evidence" in resources.compare_records(evidence(), candidate)["failures"]
    assert not resources.compare_records([], [])["accepted"]


def test_duplicate_case_evidence_is_rejected():
    with pytest.raises(ValueError, match="duplicate case"):
        resources.compare_records(evidence() + evidence(), evidence())


def test_jsonl_recorder_preserves_fragmented_writes():
    destination = io.StringIO()
    recorder = resources.JsonlRecorder(destination)
    recorder.write('{"event":')
    recorder.write('"case"}\n\n')
    recorder.flush()

    assert recorder.records == [{"event": "case"}]
    assert destination.getvalue() == '{"event":"case"}\n\n'


def test_jsonl_reader_requires_objects(tmp_path):
    path = tmp_path / "baseline.jsonl"
    path.write_text('{"event":"case"}\n[]\n')
    with pytest.raises(ValueError, match="expected a JSON object"):
        resources.read_jsonl(path)


def test_stress_prefill_has_exact_public_word_counts():
    for count in resources.STRESS_WORDS:
        assert len(resources.stress_text(count).split()) == count


def test_worker_arguments_keep_model_and_fd_for_production_parser(monkeypatch):
    calls = []
    monkeypatch.setattr(
        resources, "worker_main",
        lambda cap, argv, **options: calls.append((cap, argv, options)),
    )
    monkeypatch.setattr(resources, "benchmark_lock", lambda: pytest.fail("worker must not take parent lock"))
    monkeypatch.setattr(sys, "argv", [
        "benchmark", "--worker", "--cache-limit-mb", "256", "--fd", "17",
        "--model", resources.quality.MODEL_ID, "--local-model-path", "/weights",
    ])

    assert resources.main() == 0
    assert calls == [(256, [
        "--fd", "17", "--model", resources.quality.MODEL_ID,
        "--local-model-path", "/weights",
    ], {"uncapped": False})]


@pytest.mark.parametrize("cap,uncapped,expected_bytes", [
    (256, False, 256 * 1024 * 1024),
    (0, False, 0),
    (None, False, 512 * 1024 * 1024),
    (None, True, None),
])
def test_cache_override_survives_production_load_policy(
    monkeypatch, cap, uncapped, expected_bytes,
):
    from velora_engine import cleanup, cleanup_worker

    calls = []
    fake_mlx = ModuleType("mlx")
    fake_core = ModuleType("mlx.core")
    fake_core.set_cache_limit = lambda size: calls.append(("cache", size))
    fake_mlx.core = fake_core
    monkeypatch.setitem(sys.modules, "mlx", fake_mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", fake_core)
    monkeypatch.setattr(cleanup, "ALLOCATOR_CACHE_LIMITS", {"incumbent": 512 * 1024 * 1024})

    class FakeEngine:
        model_id = "incumbent"

        def load(self, source):
            # Mirror production: this would overwrite a cap set before load.
            cache_bytes = cleanup.ALLOCATOR_CACHE_LIMITS.get(self.model_id)
            if cache_bytes is not None:
                fake_core.set_cache_limit(cache_bytes)
            calls.append(("load", source))

    monkeypatch.setattr(cleanup, "CleanupEngine", FakeEngine)
    monkeypatch.setattr(cleanup_worker, "main", lambda: FakeEngine().load("weights"))
    monkeypatch.setattr(sys, "argv", ["benchmark", "--worker"])

    resources.worker_main(cap, ["--fd", "17", "--model", "incumbent"], uncapped=uncapped)

    assert calls == ([] if expected_bytes is None else [("cache", expected_bytes)]) + [
        ("load", "weights"),
    ]
    assert sys.argv == ["benchmark", "--fd", "17", "--model", "incumbent"]


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", [
    None, "load", "stress_timeout", "stress_error", "stress_other",
    "stress_unhealthy", "metrics", "cancelled",
])
async def test_run_closes_on_setup_failure_and_restores_shared_state(
    monkeypatch, tmp_path, capsys, failure,
):
    instances = []

    class FakeProcess:
        def __init__(self, model_id, **kwargs):
            self.model_id = model_id
            self.options = kwargs
            self.closed = False
            self.calls = []
            instances.append(self)

        async def load_async(self, *args, **kwargs):
            if failure == "load":
                raise RuntimeError("load failed")
            if failure == "cancelled":
                raise asyncio.CancelledError()

        async def cleanup(self, *args, **kwargs):
            self.calls.append((args, kwargs))
            if failure and failure.startswith("stress_"):
                self.unhealthy = failure == "stress_unhealthy"
                return SimpleNamespace(reason={
                    "stress_timeout": "timeout", "stress_error": "error:fake",
                    "stress_other": None, "stress_unhealthy": "length",
                }[failure])
            return SimpleNamespace(reason="length")

        async def aclose(self):
            self.closed = True

    async def runner(model_id, config, selected, repeats):
        engine = resources.quality.CleanupProcess("/resolved-weights")
        await engine.load_async("warm")
        if failure == "metrics":
            raise RuntimeError("metrics failed before fixture try/finally")
        await engine.cleanup("ordinary fixture", "prompt")
        assert repeats == 3
        assert selected == {"fixture"}
        records = evidence(failures=("known",))
        summary = {
            **records[-1], "failed_cases": ["fixture"],
            "p50_wall_ms": 100, "p95_wall_ms": 120,
            "footprint_after_inference": {"current_bytes": 300},
            "mlx_inference": {"cache_bytes": 200},
        }
        for record in [records[0], summary]:
            print(json.dumps(record))
        await engine.aclose()
        return summary

    original_factory = resources.quality.CleanupProcess
    original_resolver = resources.quality.resolve_benchmark_model
    monkeypatch.setattr(resources, "CleanupProcess", FakeProcess)
    monkeypatch.setattr(resources.quality, "_run_model", runner)
    monkeypatch.setenv("VELORA_HOME", "/original-home")
    monkeypatch.setattr(resources, "Config", lambda: SimpleNamespace())
    parameters = dict(
        model=str(tmp_path), logical_model=resources.quality.MODEL_ID, cache_limit_mb=256,
        stress=True, repeats=3, selected={"fixture"},
        baseline=evidence(failures=("known",)),
    )
    if failure:
        expected = asyncio.CancelledError if failure == "cancelled" else RuntimeError
        with pytest.raises(expected):
            await resources.run(**parameters)
    else:
        assert await resources.run(**parameters) == 0
        output = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
        assert output[-1]["accepted"]
        assert output[-2]["all_quality_checks_passed"] is False  # Known failure stays visible.
        assert output[-2]["allocator_policy"] == "override"
        assert output[-2]["footprint_bytes"] == 300
        assert instances[0].calls[-1][1]["copy_draft"] is True
        stress_calls = instances[0].calls[:2]
        assert [len(args[0].split()) for args, _ in stress_calls] == [1000, 3000]
        assert all(kwargs["copy_draft"] is False for _, kwargs in stress_calls)
        assert all(kwargs["max_tokens"] == 1 for _, kwargs in stress_calls)
    assert instances[0].closed
    assert instances[0].model_id == resources.quality.MODEL_ID
    assert instances[0].options["local_model_path"] == "/resolved-weights"
    assert instances[0].options["worker_command"][-2:] == ["--cache-limit-mb", "256"]
    assert os.environ["VELORA_HOME"] == "/original-home"
    assert resources.quality.CleanupProcess is original_factory
    assert resources.quality.resolve_benchmark_model is original_resolver


@pytest.mark.parametrize("argument", ["--cache-limit-mb", "--repeats"])
def test_cli_rejects_invalid_limits(monkeypatch, argument):
    monkeypatch.setattr(sys, "argv", ["benchmark", argument, "-1"])
    with pytest.raises(SystemExit) as exc:
        resources.main()
    assert exc.value.code == 2


def test_parent_invocation_holds_shared_benchmark_lock(monkeypatch, tmp_path):
    calls = []

    async def run(**kwargs):
        calls.append("run")
        return 0

    monkeypatch.setattr(resources, "run", run)
    monkeypatch.setattr(resources, "LOCK_PATH", tmp_path / "benchmark.lock")
    monkeypatch.setattr(resources.fcntl, "flock", lambda _lock, operation: calls.append(operation))
    monkeypatch.setattr(sys, "argv", ["benchmark"])

    assert resources.main() == 0
    assert calls == [resources.fcntl.LOCK_EX, "run", resources.fcntl.LOCK_UN]


@pytest.mark.asyncio
async def test_arbitrary_local_snapshot_requires_explicit_behavior_identity(tmp_path):
    with pytest.raises(ValueError, match="local snapshots require --logical-model"):
        await resources.run(
            model=str(tmp_path), logical_model=None, cache_limit_mb=None,
            stress=False, repeats=3, selected=None,
        )


@pytest.mark.asyncio
@pytest.mark.parametrize("uncapped", [False, True])
async def test_exact_pinned_snapshot_retains_incumbent_identity(
    monkeypatch, tmp_path, capsys, uncapped,
):
    calls = []

    async def runner(identity, *_args):
        calls.append((identity, resources.quality.resolve_benchmark_model(identity)))
        return {
            "failed_cases": [], "footprint_after_inference": {},
            "mlx_inference": {},
        }

    monkeypatch.setattr(resources, "incumbent_snapshot_path", lambda: tmp_path.resolve())
    monkeypatch.setattr(resources, "Config", lambda: SimpleNamespace())
    monkeypatch.setattr(resources.quality, "_run_model", runner)

    assert await resources.run(
        model=str(tmp_path), logical_model=None, cache_limit_mb=None,
        stress=False, repeats=3, selected=None, uncapped=uncapped,
    ) == 0
    assert calls == [(resources.quality.MODEL_ID, str(tmp_path.resolve()))]
    report = json.loads(capsys.readouterr().out)
    assert report["allocator_policy"] == ("mlx_default" if uncapped else "production")
    assert report["cache_limit_mb"] is None


@pytest.mark.parametrize("worker", [False, True])
def test_explicit_cap_and_uncapped_flags_are_mutually_exclusive(monkeypatch, worker):
    monkeypatch.setattr(sys, "argv", [
        "benchmark", *(["--worker"] if worker else []),
        "--uncapped", "--cache-limit-mb", "256",
    ])
    with pytest.raises(SystemExit) as exc:
        resources.main()
    assert exc.value.code == 2


def test_uncapped_worker_flag_is_not_forwarded_to_production_parser(monkeypatch):
    calls = []
    monkeypatch.setattr(
        resources, "worker_main",
        lambda cap, argv, **options: calls.append((cap, argv, options)),
    )
    monkeypatch.setattr(sys, "argv", ["benchmark", "--worker", "--uncapped", "--fd", "17"])

    assert resources.main() == 0
    assert calls == [(None, ["--fd", "17"], {"uncapped": True})]
