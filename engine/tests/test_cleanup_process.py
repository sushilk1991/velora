from __future__ import annotations

import asyncio
import os
import sys
import threading
from pathlib import Path

import pytest
import velora_engine.cleanup_process as cleanup_process_mod
from velora_engine import actions
from velora_engine.cleanup_ipc import (
    CLEANUP_IPC_STREAM_LIMIT_BYTES,
    encode_cleanup_ipc_message,
    pack_prefix_candidates,
    unpack_prefix_candidates,
)
from velora_engine.cleanup_process import CleanupProcess


def fixture_command() -> list[str]:
    return [
        sys.executable,
        str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
    ]


async def wait_until_loaded(cleanup: CleanupProcess) -> None:
    for _ in range(200):
        if cleanup.loaded:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("replacement cleanup worker did not become ready")


async def wait_until_unhealthy(cleanup: CleanupProcess) -> None:
    for _ in range(300):
        if cleanup.unhealthy:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("cleanup process did not escalate failed recovery")


async def test_cleanup_process_round_trip_and_prefix() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        result = await cleanup.cleanup("hello", "system")
        assert result.text == "HELLO"
        assert result.applied is True
        assert result.ms == 7
        assert 0 <= result.wall_ms < 1_000
        assert result.cache_hit is True

        limited = await cleanup.cleanup(
            "__limits__", "system", max_input_tokens=16_384)
        assert limited.text == "16384"

        prefix = await cleanup.prepare_prefix([("system", "alpha"), ("system", "zulu")])
        assert prefix.applied is True
        assert prefix.tokens == 12
        memory = await cleanup.memory_metrics(reset_peak=True)
        assert memory.active_bytes == 500_000_000
        assert memory.peak_bytes == 750_000_000
        assert memory.cache_bytes == 25_000_000
        await cleanup.release_action_memory()
    finally:
        await cleanup.aclose()


async def test_hibernated_cleanup_worker_reloads_lazily_on_next_request() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid

        assert await cleanup.hibernate() is True
        assert cleanup.loaded is False
        assert cleanup.pid is None

        result = await cleanup.cleanup("hello again", "system")

        assert result.text == "HELLO AGAIN"
        assert result.applied is True
        assert cleanup.loaded is True
        assert cleanup.pid is not None and cleanup.pid != original_pid
    finally:
        await cleanup.aclose()


async def test_hibernated_reload_retries_one_transient_load_failure(tmp_path) -> None:
    marker = tmp_path / "fail-next-hibernated-load"
    command = fixture_command() + ["--fail-next-replacement", str(marker)]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        await cleanup.load_async("warm prompt")
        assert await cleanup.hibernate() is True

        assert await cleanup.ensure_loaded() is True

        assert marker.read_text() == "failed"
        assert cleanup.loaded is True
        assert cleanup.unhealthy is False
    finally:
        await cleanup.aclose()


async def test_inflight_hibernated_reload_honors_threading_cancel() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        assert await cleanup.hibernate() is True
        entered = asyncio.Event()
        blocked = asyncio.Event()
        original_request = cleanup._request

        async def gated_request(operation: str, **payload):
            if operation == "load":
                entered.set()
                await blocked.wait()
            return await original_request(operation, **payload)

        cleanup._request = gated_request  # type: ignore[method-assign]
        cancelled = threading.Event()
        reload_task = asyncio.create_task(
            cleanup.ensure_loaded(cancel_event=cancelled))
        await asyncio.wait_for(entered.wait(), timeout=1)

        cancelled.set()

        assert await asyncio.wait_for(reload_task, timeout=0.5) is False
        assert cleanup.loaded is False
        assert cleanup.hibernated is True
        assert cleanup.pid is None
    finally:
        blocked.set()
        await cleanup.aclose()


async def test_precancelled_cleanup_does_not_reload_a_hibernated_worker() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        assert await cleanup.hibernate() is True
        cancelled = threading.Event()
        cancelled.set()

        result = await cleanup.cleanup(
            "do not reload", "system", cancel_event=cancelled)

        assert result.applied is False
        assert result.reason == "cancelled"
        assert cleanup.hibernated is True
        assert cleanup.loaded is False
        assert cleanup.pid is None
    finally:
        await cleanup.aclose()


async def test_aclose_cannot_race_a_hibernated_reload() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    await cleanup.load_async("warm prompt")
    assert await cleanup.hibernate() is True
    entered = asyncio.Event()
    release = asyncio.Event()
    original_spawn = cleanup._spawn

    async def gated_spawn() -> None:
        entered.set()
        await release.wait()
        await original_spawn()

    cleanup._spawn = gated_spawn  # type: ignore[method-assign]
    reload_task = asyncio.create_task(cleanup.ensure_loaded())
    await asyncio.wait_for(entered.wait(), timeout=1)
    close_task = asyncio.create_task(cleanup.aclose())
    await asyncio.sleep(0)
    release.set()

    assert await reload_task is False
    await close_task
    assert cleanup.loaded is False
    assert cleanup.pid is None


async def test_cancelled_hibernate_finishes_reap_before_reload() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    release = asyncio.Event()
    try:
        await cleanup.load_async("warm prompt")
        entered = asyncio.Event()
        original_stop = cleanup._stop_worker
        first = True

        async def gated_stop() -> None:
            nonlocal first
            if first:
                first = False
                entered.set()
                await release.wait()
            await original_stop()

        cleanup._stop_worker = gated_stop  # type: ignore[method-assign]
        hibernate_task = asyncio.create_task(cleanup.hibernate())
        await asyncio.wait_for(entered.wait(), timeout=1)
        hibernate_task.cancel()
        reload_task = asyncio.create_task(cleanup.ensure_loaded())
        await asyncio.sleep(0.02)

        assert reload_task.done() is False
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await hibernate_task
        assert await asyncio.wait_for(reload_task, timeout=1) is True
        assert cleanup.loaded is True
    finally:
        release.set()
        await cleanup.aclose()


async def test_cleanup_ipc_accepts_ax_sized_lines_over_asyncio_default() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        raw = "screen evidence " + ("x" * 80_000)

        result = await cleanup.cleanup(raw, "controller rules")

        assert result.text == raw.upper()
        assert result.applied is True
        assert cleanup.loaded is True
        assert cleanup.pid == original_pid
        assert (await cleanup.cleanup("still connected", "system")).text == (
            "STILL CONNECTED"
        )
    finally:
        await cleanup.aclose()


def test_cleanup_ipc_worst_case_ax_prompt_is_bounded_without_prefix_duplication() -> None:
    snapshot = actions.normalize_ui_snapshot({
        "id": "worst-case",
        "complete": True,
        "elements": [
            {
                "index": index,
                "role": "😀" * 40,
                "label": "😀" * 180,
                "actions": ["😀" * 40] * 12,
            }
            for index in range(500)
        ],
    })
    prompt = actions.build_ui_action_review_prompt(snapshot)
    candidates = [(prompt, "a"), (prompt, "b")]
    wire_candidates, shared_prefixes = pack_prefix_candidates(prompt, candidates)
    encoded = encode_cleanup_ipc_message({
        "id": "probe",
        "op": "cleanup",
        "raw": "review one proposed UI press",
        "system_prompt": prompt,
        "prefix_candidates": wire_candidates,
        "shared_prompt_prefixes": shared_prefixes,
    })

    assert wire_candidates is None
    assert unpack_prefix_candidates(
        prompt, wire_candidates, shared_prefixes) == candidates
    assert len(encoded) < CLEANUP_IPC_STREAM_LIMIT_BYTES


def test_cleanup_ipc_refuses_oversize_message_before_socket_write() -> None:
    with pytest.raises(ValueError, match="exceeds"):
        encode_cleanup_ipc_message({
            "raw": "x" * CLEANUP_IPC_STREAM_LIMIT_BYTES,
        })


async def test_production_worker_model_free_probe() -> None:
    cleanup = CleanupProcess("probe")
    await cleanup.probe_async()
    assert cleanup.pid is None
    assert cleanup.loaded is False


async def test_unloaded_process_returns_raw_without_spawning() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    result = await cleanup.cleanup("hello", "system")
    prefix = await cleanup.prepare_prefix([("system", "hello")])

    assert result.text == "hello"
    assert result.reason == "llm_not_loaded"
    assert prefix.reason == "llm_not_loaded"
    assert cleanup.pid is None


async def test_aclose_reaps_worker() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    await cleanup.load_async("warm prompt")
    pid = cleanup.pid
    assert pid is not None

    await cleanup.aclose()

    assert cleanup.pid is None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("cleanup child survived aclose")


async def test_spontaneous_worker_exit_recovers() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        result = await cleanup.cleanup("__crash__", "system", timeout_ms=500)

        assert result.applied is False
        assert result.reason.startswith("error:")
        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
        assert (await cleanup.cleanup("after crash", "system")).text == "AFTER CRASH"
    finally:
        await cleanup.aclose()


async def test_malformed_worker_response_fails_fast_and_recovers() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        started = asyncio.get_running_loop().time()

        result = await cleanup.cleanup(
            "__malformed__", "system", timeout_ms=5_000)

        elapsed = asyncio.get_running_loop().time() - started
        assert result.applied is False
        assert "invalid cleanup worker response" in str(result.reason)
        assert elapsed < 1.5
        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
        assert (await cleanup.cleanup("after malformed", "system")).text == (
            "AFTER MALFORMED"
        )
    finally:
        await cleanup.aclose()


async def test_child_watchdog_result_retires_worker_and_recovers() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid

        result = await cleanup.cleanup("__child_timeout__", "system")

        assert result.text == "__child_timeout__"
        assert result.applied is False
        assert result.reason == "timeout_hard"
        assert cleanup.loaded is False
        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
        assert (await cleanup.cleanup("after child watchdog", "system")).text == (
            "AFTER CHILD WATCHDOG"
        )
    finally:
        await cleanup.aclose()


async def test_child_watchdog_has_time_to_serialize_boundary_result() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        started = asyncio.get_running_loop().time()
        result = await cleanup.cleanup(
            "__child_timeout_boundary__", "system", timeout_ms=50)
        elapsed = asyncio.get_running_loop().time() - started

        # The fake child responds after the former 100ms parent boundary. Its
        # distinct ms value proves the response arrived over IPC instead of
        # the parent manufacturing its own timeout fallback.
        assert result.reason == "timeout_hard"
        assert result.ms == 12
        assert 0.11 <= elapsed < 0.30
    finally:
        await cleanup.aclose()


async def test_hard_deadline_kills_only_worker_and_recovers() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
        queue_timeout_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)

        assert result.text == "__hang__"
        assert result.applied is False
        assert result.reason == "timeout_hard"
        assert result.ms == 50
        assert 80 <= result.wall_ms < 1_000
        assert cleanup.unhealthy is False

        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
        try:
            os.kill(original_pid, 0)
        except ProcessLookupError:
            old_pid_is_gone = True
        else:
            old_pid_is_gone = False
        assert old_pid_is_gone
        recovered = await cleanup.cleanup("after", "system")
        assert recovered.text == "AFTER"
    finally:
        await cleanup.aclose()


async def test_hard_deadline_returns_fallback_before_sigkill_reap() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
        queue_timeout_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        started = asyncio.get_running_loop().time()
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        elapsed = asyncio.get_running_loop().time() - started

        # The fixture ignores SIGTERM, so synchronous replacement pays the
        # 0.5-second terminate grace before SIGKILL. The chosen raw fallback
        # must return without that reap delay.
        assert elapsed < 0.35
        assert result.text == "__hang__"
        assert result.reason == "timeout_hard"
        immediate = await cleanup.cleanup("must not reach old worker", "system")
        assert immediate.text == "must not reach old worker"
        assert immediate.reason in {"llm_recovering", "llm_not_loaded"}

        await wait_until_loaded(cleanup)
        assert (await cleanup.cleanup("after", "system")).text == "AFTER"
    finally:
        await cleanup.aclose()


async def test_close_during_detached_reap_leaves_no_orphan() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    await cleanup.load_async("warm prompt")
    pid = cleanup.pid
    assert pid is not None

    result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
    assert result.reason == "timeout_hard"
    await cleanup.aclose()

    assert cleanup.pid is None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("detached cleanup child survived aclose")


async def test_recovery_retries_one_failed_replacement_load(tmp_path) -> None:
    marker = tmp_path / "fail-next-replacement"
    command = fixture_command() + ["--fail-next-replacement", str(marker)]
    cleanup = CleanupProcess(
        "fake",
        worker_command=command,
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)

        assert result.reason == "timeout_hard"
        await wait_until_loaded(cleanup)
        assert marker.read_text() == "failed"
        assert cleanup.pid != original_pid
        assert cleanup.unhealthy is False
        assert (await cleanup.cleanup("after retry", "system")).text == "AFTER RETRY"
    finally:
        await cleanup.aclose()


async def test_recovery_exhaustion_escalates_to_engine_restart(tmp_path) -> None:
    marker = tmp_path / "fail-all-replacements"
    command = fixture_command() + ["--fail-all-replacements", str(marker)]
    cleanup = CleanupProcess(
        "fake",
        worker_command=command,
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)

        assert result.reason == "timeout_hard"
        await wait_until_unhealthy(cleanup)
        assert cleanup.loaded is False
        assert cleanup.unhealthy is True
    finally:
        await cleanup.aclose()


async def test_queue_timeout_replaces_blocked_worker_and_recovers() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
        queue_timeout_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        blocked = asyncio.create_task(
            cleanup.cleanup("__cancel__", "system", timeout_ms=5_000)
        )
        await asyncio.sleep(0.05)
        queued = await cleanup.cleanup("queued", "system", timeout_ms=500)
        first = await blocked

        assert queued.reason == "timeout_queue"
        assert first.reason.startswith("error:")
        await wait_until_loaded(cleanup)
        assert (await cleanup.cleanup("after queue", "system")).text == "AFTER QUEUE"
    finally:
        await cleanup.aclose()


async def test_queue_timeout_returns_before_reaping_wedged_owner() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=5.0,
        queue_timeout_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        blocked = asyncio.create_task(
            cleanup.cleanup("__hang__", "system", timeout_ms=5_000)
        )
        await asyncio.sleep(0.05)
        started = asyncio.get_running_loop().time()
        queued = await cleanup.cleanup("queued", "system", timeout_ms=500)
        elapsed = asyncio.get_running_loop().time() - started

        assert elapsed < 0.35
        assert queued.text == "queued"
        assert queued.reason == "timeout_queue"
        assert cleanup.loaded is False
        first = await blocked
        assert first.reason.startswith("error:")
        await wait_until_loaded(cleanup)
    finally:
        await cleanup.aclose()


async def test_pre_admitted_call_rechecks_generation_after_lock() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        queue_timeout_s=1.0,
    )
    try:
        await cleanup.load_async("warm prompt")
        await cleanup._operation_lock.acquire()
        queued = asyncio.create_task(cleanup.cleanup("queued", "system"))
        await asyncio.sleep(0.02)
        cleanup._schedule_replacement("test_generation_fence")
        cleanup._operation_lock.release()

        result = await queued
        assert result.text == "queued"
        assert result.reason in {"llm_recovering", "llm_not_loaded"}
        await wait_until_loaded(cleanup)
        assert (await cleanup.cleanup("after", "system")).text == "AFTER"
    finally:
        if cleanup._operation_lock.locked():
            cleanup._operation_lock.release()
        await cleanup.aclose()


async def test_replacement_warmup_waits_for_dictation_idle() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        await cleanup.defer_recovery()
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        assert result.reason == "timeout_hard"

        # Allow the detached SIGTERM/SIGKILL reap to finish. Recovery remains
        # deferred, so no replacement child/model load overlaps dictation.
        await asyncio.sleep(0.7)
        assert cleanup.loaded is False
        assert cleanup.pid is None
        assert cleanup._deferred_recovery_reason == "timeout_hard"

        cleanup.resume_recovery()
        await wait_until_loaded(cleanup)
        assert (await cleanup.cleanup("after idle", "system")).text == "AFTER IDLE"
    finally:
        await cleanup.aclose()


async def test_repeated_dictation_deferrals_escalate_stuck_recovery() -> None:
    escalated = asyncio.Event()
    cleanup = CleanupProcess("fake", on_unhealthy=escalated.set)
    blocker = asyncio.Event()

    async def blocked_load() -> None:
        cleanup.recovering = True
        try:
            await blocker.wait()
        finally:
            cleanup.recovering = False

    cleanup._start_and_load = blocked_load  # type: ignore[method-assign]
    try:
        cleanup._schedule_recovery("initial")
        for attempt in range(3):
            for _ in range(100):
                if cleanup.recovering:
                    break
                await asyncio.sleep(0.001)
            assert cleanup.recovering is True
            await cleanup.defer_recovery()
            if attempt < 2:
                assert cleanup.unhealthy is False
                cleanup.resume_recovery()

        await asyncio.wait_for(escalated.wait(), 1)
        assert cleanup.unhealthy is True
        assert cleanup.loaded is False
    finally:
        blocker.set()
        await cleanup.aclose()


async def test_threading_cancel_reaches_worker_without_replacing_it() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.5,
    )
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        cancel = threading.Event()
        task = asyncio.create_task(
            cleanup.cleanup("__cancel__", "system", timeout_ms=500, cancel_event=cancel)
        )
        await asyncio.sleep(0.05)
        cancel.set()
        result = await task
        assert result.reason == "cancelled"
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        await cleanup.aclose()


async def test_repeated_task_cancel_cannot_interrupt_worker_handoff(
    monkeypatch,
) -> None:
    class Writer:
        def is_closing(self):
            return False

        def write(self, _data):
            pass

        async def drain(self):
            pass

    cleanup = CleanupProcess("fake", cancel_grace_s=0.02)
    cleanup.loaded = True
    cleanup._writer = Writer()
    entered_cancel = asyncio.Event()
    release_cancel = asyncio.Event()
    replaced: list[str] = []

    async def slow_cancel(_request_id):
        entered_cancel.set()
        await release_cancel.wait()

    async def replace(reason):
        replaced.append(reason)

    monkeypatch.setattr(cleanup, "_send_cancel", slow_cancel)
    monkeypatch.setattr(cleanup, "_replace_worker", replace)

    owner = asyncio.create_task(
        cleanup.cleanup("first", "system", timeout_ms=10_000)
    )
    while not cleanup._pending:
        await asyncio.sleep(0)
    owner.cancel()
    await entered_cancel.wait()
    owner.cancel()
    await asyncio.sleep(0.01)

    assert owner.done() is False
    assert cleanup._operation_lock.locked() is True

    release_cancel.set()
    with pytest.raises(asyncio.CancelledError):
        await owner

    assert cleanup._operation_lock.locked() is False
    assert replaced == ["cancel_unresponsive"]


async def test_prefix_cancellation_preserves_warm_worker() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        cancel = threading.Event()
        task = asyncio.create_task(
            cleanup.prepare_prefix(
                [("__cancel__", "alpha"), ("__cancel__", "zulu")],
                cancel_event=cancel,
            )
        )
        await asyncio.sleep(0.05)
        cancel.set()
        result = await task
        assert result.reason == "cancelled"
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        await cleanup.aclose()


async def test_prefix_hard_timeout_replaces_worker(monkeypatch) -> None:
    monkeypatch.setattr(cleanup_process_mod, "PREFIX_TIMEOUT_S", 0.05)
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        result = await cleanup.prepare_prefix(
            [("__hang__", "alpha"), ("__hang__", "zulu")]
        )

        assert result.reason == "timeout_hard"
        assert 80 <= result.ms < 1_000
        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
    finally:
        await cleanup.aclose()


async def test_cancelled_wedged_prefix_replaces_worker() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        cancel_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        task = asyncio.create_task(
            cleanup.prepare_prefix(
                [("__hang__", "alpha"), ("__hang__", "zulu")]
            )
        )
        await asyncio.sleep(0.05)
        task.cancel()

        with pytest.raises(asyncio.CancelledError):
            await task
        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
        assert (await cleanup.cleanup("after prefix", "system")).text == "AFTER PREFIX"
    finally:
        await cleanup.aclose()


async def test_parent_shutdown_during_stall_reaps_worker() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    await cleanup.load_async("warm prompt")
    pid = cleanup.pid
    assert pid is not None
    task = asyncio.create_task(
        cleanup.cleanup("__hang__", "system", timeout_ms=5_000)
    )
    await asyncio.sleep(0.05)

    await cleanup.aclose()
    result = await task

    assert result.reason.startswith("error:")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("stalled cleanup child survived parent shutdown")
