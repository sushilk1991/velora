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


async def test_prefix_cancellation_preserves_warm_worker() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        cancel = threading.Event()
        task = asyncio.create_task(
            cleanup.prepare_prefix([("__cancel__", "alpha")], cancel_event=cancel)
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
        result = await cleanup.prepare_prefix([("__hang__", "alpha")])

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
            cleanup.prepare_prefix([("__hang__", "alpha")])
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
