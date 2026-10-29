"""Transcript-free timing and work counts; no MLX device work."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
from dataclasses import asdict
import sys
import threading
from types import ModuleType, SimpleNamespace

import pytest

import velora_engine.cleanup as cleanup_mod
from velora_engine.cleanup import CleanupEngine, CleanupResult


@pytest.fixture(autouse=True)
def _enable_trace(monkeypatch):
    # Only this diagnostic test module opts into request-local recording.
    monkeypatch.setattr(cleanup_mod, "_TRACE_CLEANUP", True)


def test_trace_disabled(monkeypatch, caplog):
    # Ordinary dictation should allocate no diagnostic maps or emit span logs.
    monkeypatch.setattr(cleanup_mod, "_TRACE_CLEANUP", False)

    @cleanup_mod._trace_cleanup
    def run():
        with cleanup_mod._latency_span("test_ns"):
            cleanup_mod._count_work("passes", 1)
        return CleanupResult("fixed", True, 7)

    with caplog.at_level("INFO", logger="velora.cleanup"):
        result = run()
    assert result._latency_ns == {}
    assert result._work_counts == {}
    assert "spans_ns" not in caplog.text


def test_latency_scope_isolation():
    # Concurrent requests retain distinct counters and no request text. A
    # completed scope restores its caller even when that caller is nested.
    barrier = threading.Barrier(2)

    @cleanup_mod._trace_cleanup
    def run(count):
        barrier.wait()
        with cleanup_mod._latency_span("test_ns"):
            cleanup_mod._count_work("copy_draft_model_passes", count)
        return CleanupResult("private transcript", True, 7)

    with ThreadPoolExecutor(max_workers=2) as pool:
        first, second = list(pool.map(run, [1, 2]))
    assert first._work_counts == {"copy_draft_model_passes": 1}
    assert second._work_counts == {"copy_draft_model_passes": 2}
    assert first._latency_ns is not second._latency_ns
    assert all(value >= 0 for result in [first, second] for value in result._latency_ns.values())
    assert cleanup_mod._latency_spans.get() is None
    assert cleanup_mod._work_counts.get() is None


def test_latency_error_reset():
    # Exceptions must not attach the previous request's spans to the next one.
    @cleanup_mod._trace_cleanup
    def fail():
        raise ValueError("failed")

    with pytest.raises(ValueError):
        fail()
    assert cleanup_mod._latency_spans.get() is None
    assert cleanup_mod._work_counts.get() is None


def test_latency_ipc_defaults():
    # Old workers omit private diagnostics; new workers use normal asdict IPC.
    legacy = CleanupResult(**{"text": "raw", "applied": False, "ms": 7})
    current = CleanupResult("fixed", True, 7)
    current._latency_ns["exact_prefill_ns"] = 10
    current._work_counts["copy_draft_model_passes"] = 1
    restored = CleanupResult(**asdict(current))
    assert legacy._latency_ns == {}
    assert legacy._work_counts == {}
    assert restored == current
    assert restored._latency_ns is not current._latency_ns


def test_draft_work_counts(monkeypatch):
    # One pass scores two draft positions plus a pending token. Accepted draft
    # tokens and emitted output are separate from actual model input work.
    class Tensor:
        def __getitem__(self, _index):
            return self

        def tolist(self):
            return [2, 3, 9]

    mx = ModuleType("mlx.core")
    mx.array = lambda _values: Tensor()
    mx.argmax = lambda _values, axis: Tensor()
    mx.stream = lambda _stream: nullcontext()
    mlx = ModuleType("mlx")
    mlx.core = mx
    generate = ModuleType("mlx_lm.generate")
    generate.generation_stream = object()
    generate.wired_limit = lambda *_args: nullcontext()
    mlx_lm = ModuleType("mlx_lm")
    mlx_lm.generate = generate
    for name, module in [("mlx", mlx), ("mlx.core", mx), ("mlx_lm", mlx_lm), ("mlx_lm.generate", generate)]:
        monkeypatch.setitem(sys.modules, name, module)
    monkeypatch.setattr(cleanup_mod, "_copy_draft", lambda *_args: ([2, 3], 0))
    engine = CleanupEngine("fake")
    engine._tokenizer = SimpleNamespace(eos_token_ids=[])
    engine._model = lambda *_args, **_kwargs: Tensor()
    monkeypatch.setattr(engine, "_prefill_into_cache_locked", lambda cache, *_args: cache)

    @cleanup_mod._trace_cleanup
    def run():
        output = list(engine._copy_draft_steps([], [1, 2, 3, 4], 3, None))
        assert [step.token for step in output] == [2, 3, 9]
        return CleanupResult("fixed", True, 7)

    try:
        result = run()
        assert result._work_counts == {
            "copy_draft_model_passes": 1,
            "copy_draft_model_input_tokens": 3,
            "draft_proposed_tokens": 2,
            "draft_verified_tokens": 2,
            "draft_accepted_tokens": 2,
        }
        assert result._latency_ns["first_forward_sync_ns"] >= 0
    finally:
        engine.close()


def test_run_numeric_spans(monkeypatch, caplog):
    # A fake generation result exercises the real request scope and guard;
    # existing millisecond metrics remain the values returned by generation.
    engine = CleanupEngine("fake")
    engine._tokenizer = SimpleNamespace(encode=lambda text: list(text))

    def generate(*_args, **_kwargs):
        with cleanup_mod._latency_span("cache_select_restore_ns"):
            pass
        return cleanup_mod._GenerationResult(
            "private words", "ok", 11, 12, 3, 4, 5, True, 6, 7, 8)

    monkeypatch.setattr(engine, "_generate_locked", generate)
    try:
        with caplog.at_level("INFO", logger="velora.cleanup"):
            result = engine._run("private words", "rules", 1_000)
        assert result.applied
        assert (result.ttft_ms, result.decode_ms) == (11, 12)
        assert set(result._latency_ns) == {
            "worker_total_ns", "raw_tokenization_ns", "cache_select_restore_ns", "postprocess_ns"}
        assert all(value >= 0 for value in result._latency_ns.values())
        assert result._latency_ns["worker_total_ns"] >= result._latency_ns["postprocess_ns"]
        assert "private words" not in caplog.text
    finally:
        engine.close()


def test_greedy_hash_before_guard(monkeypatch):
    # A fallback can hide changed model output. Compare the pre-guard bytes.
    import hashlib

    engine = CleanupEngine("fake")
    engine._tokenizer = SimpleNamespace(encode=lambda text: list(text))
    generated = "different generated words " * 20
    monkeypatch.setattr(engine, "_generate_locked", lambda *_args, **_kwargs:
        cleanup_mod._GenerationResult(generated, "ok", 1, 2, 3, 4, 5, True, 0, 0, 0))
    try:
        result = engine._run("short input", "rules", 1_000)
        assert not result.applied
        assert result.text == "short input"
        assert result._greedy_sha256 == hashlib.sha256(generated.encode()).hexdigest()
    finally:
        engine.close()


def test_stock_stream_spans(monkeypatch):
    # Upstream's existing callbacks mark synchronized prefill and first output;
    # instrumentation must add no evaluation or extra generation calls.
    mx = ModuleType("mlx.core")
    mx.get_active_memory = lambda: 0
    mx.get_peak_memory = lambda: 0
    mx.get_cache_memory = lambda: 0
    mlx = ModuleType("mlx")
    mlx.core = mx
    mlx_lm = ModuleType("mlx_lm")
    sample_utils = ModuleType("mlx_lm.sample_utils")
    sample_utils.make_sampler = lambda **_kwargs: object()
    calls = []

    def generate(*_args, **kwargs):
        calls.append("generate")
        progress = kwargs["prompt_progress_callback"]
        progress(0, 3)
        progress(2, 3)
        progress(3, 3)
        yield SimpleNamespace(text="fixed", token=1, generation_tokens=1)

    mlx_lm.stream_generate = generate
    for name, module in [("mlx", mlx), ("mlx.core", mx), ("mlx_lm", mlx_lm),
                         ("mlx_lm.sample_utils", sample_utils)]:
        monkeypatch.setitem(sys.modules, name, module)
    engine = CleanupEngine("fake")
    engine._model = object()
    engine._tokenizer = SimpleNamespace(encode=lambda text: list(text))
    monkeypatch.setattr(engine, "_prompt_tokens", lambda *_args: [1, 2, 3])
    monkeypatch.setattr(engine, "_cache_for_tokens", lambda *_args, **_kwargs: ([], 0, False))
    try:
        result = engine._run("fixed", "rules", 1_000)
        assert result.applied
        assert calls == ["generate"]
        assert result._latency_ns["stream_prefill_ns"] >= 0
        assert result._latency_ns["stream_first_forward_sync_ns"] >= 0
        assert result._work_counts["stream_prefill_input_tokens"] == 2
    finally:
        engine.close()
