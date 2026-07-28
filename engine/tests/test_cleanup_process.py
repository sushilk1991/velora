from __future__ import annotations

import asyncio
import os
import sys
import threading
from pathlib import Path

import pytest
import velora_engine.cleanup_process as cleanup_process_mod
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

        prefix = await cleanup.prepare_prefix([("system", "alpha"), ("system", "zulu")])
        assert prefix.applied is True
        assert prefix.tokens == 12
        memory = await cleanup.memory_metrics(reset_peak=True)
        assert memory.active_bytes == 500_000_000
        assert memory.peak_bytes == 750_000_000
        assert memory.cache_bytes == 25_000_000
    finally:
        await cleanup.aclose()


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
