from __future__ import annotations

import asyncio
import contextlib
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
import velora_engine.cleanup_process as cleanup_process_mod
from fixtures.fake_cleanup_worker import PID_DIR_ENV, kill_leaked, kill_workers
from velora_engine import actions
from velora_engine.cleanup import CleanupResult
from velora_engine.cleanup_ipc import (
    CLEANUP_IPC_STREAM_LIMIT_BYTES,
    encode_cleanup_ipc_message,
    pack_prefix_candidates,
    unpack_prefix_candidates,
)
from velora_engine.cleanup_process import CleanupProcess
from velora_engine.decisions import (
    STATUS_CANCELLED,
    STATUS_OK,
    STATUS_TIMEOUT,
    STATUS_UNAVAILABLE,
    DecisionResult,
    Question,
)


def fixture_command() -> list[str]:
    return [
        sys.executable,
        str(Path(__file__).parent / "fixtures" / "fake_cleanup_worker.py"),
    ]


async def wait_until_loaded(cleanup: CleanupProcess, timeout_s: float = 2.0) -> None:
    for _ in range(int(timeout_s * 100)):
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


async def wait_until(condition, failure: str, timeout_s: float = 10.0) -> None:
    """Poll `condition`; raise AssertionError(failure) after `timeout_s`, so a
    wait that a later change breaks fails instead of hanging the suite."""
    for _ in range(int(timeout_s * 100)):
        if condition():
            return
        await asyncio.sleep(0.01)
    raise AssertionError(failure)


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
        assert (await cleanup.cleanup("__copy_draft__", "system")).text == "False"
        drafted = await cleanup.cleanup("__copy_draft__", "system", copy_draft=True)
        assert drafted.text == "True"

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


async def test_cleanup_queue_timeout_can_be_set_per_request() -> None:
    """A request can outwait the default queue timeout for a busy worker."""
    cleanup = CleanupProcess(
        "fake",
        worker_command=[*fixture_command(), "--prefix-delay", "0.3"],
        queue_timeout_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        pid = cleanup.pid
        prefix = asyncio.create_task(
            cleanup.prepare_prefix([("system", "alpha"), ("system", "zulu")]))
        while not cleanup._operation_lock.locked():  # noqa: SLF001
            await asyncio.sleep(0.005)

        result = await cleanup.cleanup("hello", "system", queue_timeout_s=2.0)

        assert (result.text, result.applied) == ("HELLO", True)
        assert (await prefix).applied is True
        assert cleanup.loaded and cleanup.pid == pid
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


# A healthy real worker exits ~30 ms after SIGKILL, even mid-prefill. On
# 2026-09-25 two wedged workers were still alive 1 s after SIGTERM + SIGKILL.
SLOW_EXIT_S = 0.8


def process_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


# SIGKILL lands this late in the tests below, so a worker still alive when a
# caller returns shows the caller did not wait for its exit.
LATE_KILL_S = 3.0
# SIGTERM wait + SIGKILL wait (0.5 s each) plus slack for a loaded machine.
CALLER_WAIT_MAX_S = 2.0


def deliver_sigkill_late(monkeypatch, delay_s: float) -> None:
    """Make every SIGKILL land `delay_s` late, as for a worker inside a
    kernel call. A timer thread delivers it, so it still fires after the
    test's event loop has closed and no wedged fixture outlives the run."""
    killed: set[int] = set()

    def late_kill(process: asyncio.subprocess.Process) -> None:
        if process.pid in killed:
            return
        killed.add(process.pid)

        def kill() -> None:
            # returncode stays None until the pid is reaped, so it is still ours.
            if process.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(process.pid, signal.SIGKILL)

        threading.Timer(delay_s, kill).start()

    monkeypatch.setattr(asyncio.subprocess.Process, "kill", late_kill)


async def wait_until_wedged(loads: Path, timeout_s: float = 10.0) -> None:
    """Wait until a `--wedge-second-load` worker is inside its wedged load."""
    for _ in range(int(timeout_s * 100)):
        if loads.exists() and loads.read_text() == "2":
            return
        await asyncio.sleep(0.01)
    raise AssertionError("the second load never wedged")


def record_spawns(monkeypatch) -> tuple[list[int], list[int]]:
    """Record every worker spawn.

    Returns (spawned, alive_at_spawn): the pids in spawn order, and each
    earlier pid that was still alive when a later worker spawned.
    """
    spawned: list[int] = []
    alive_at_spawn: list[int] = []
    create = asyncio.create_subprocess_exec

    async def recording_create(*args, **kwargs):
        alive_at_spawn.extend(pid for pid in spawned if not process_gone(pid))
        process = await create(*args, **kwargs)
        spawned.append(process.pid)
        return process

    monkeypatch.setattr(asyncio, "create_subprocess_exec", recording_create)
    return spawned, alive_at_spawn


async def test_worker_slow_to_exit_after_sigkill_is_replaced(monkeypatch) -> None:
    """A wedged worker that takes SLOW_EXIT_S to die is still reaped and
    replaced, so the next dictation gets cleanup.

    Before: the 0.5 s wait after SIGKILL gave up, marked cleanup unhealthy,
    and every later dictation returned raw text until the app restarted.
    Delivering SIGKILL late gives the parent the same exit latency.
    """
    loop = asyncio.get_running_loop()

    def late_kill(process: asyncio.subprocess.Process) -> None:
        def kill() -> None:
            with contextlib.suppress(ProcessLookupError):
                os.kill(process.pid, signal.SIGKILL)

        loop.call_later(SLOW_EXIT_S, kill)

    monkeypatch.setattr(asyncio.subprocess.Process, "kill", late_kill)
    monkeypatch.setattr(cleanup_process_mod, "PREFIX_TIMEOUT_S", 0.05)
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        wedged_pid = cleanup.pid
        assert wedged_pid is not None

        # The fixture hangs in prefill and ignores SIGTERM.
        prepared = await cleanup.prepare_prefix(
            [("__hang__", "alpha"), ("__hang__", "zulu")]
        )
        assert prepared.reason == "timeout_hard"

        await wait_until_loaded(cleanup)
        assert cleanup.unhealthy is False
        assert cleanup.pid != wedged_pid
        assert process_gone(wedged_pid)
        result = await cleanup.cleanup("next dictation", "system")
        assert result.text == "NEXT DICTATION"
        assert result.applied is True
    finally:
        await cleanup.aclose()


async def test_crash_looping_worker_is_respawned_with_backoff() -> None:
    """Workers that die right after loading are respawned once at once, then
    only after a backoff, so a crash loop cannot reload the model back to back.
    """
    command = fixture_command() + ["--exit-after-load"]
    cleanup = CleanupProcess("fake", worker_command=command)
    spawned: list[int] = []
    spawn = cleanup._spawn

    async def counting_spawn() -> None:
        await spawn()
        spawned.append(cleanup.pid or 0)

    cleanup._spawn = counting_spawn  # type: ignore[method-assign]
    try:
        await cleanup.load_async("warm prompt")
        await asyncio.sleep(1.5)

        # The first worker plus one immediate respawn; the next waits.
        assert len(spawned) == 2
        assert cleanup.unhealthy is False
    finally:
        await cleanup.aclose()


async def test_replacement_waits_for_a_worker_outliving_the_reap_wait(
    monkeypatch,
) -> None:
    """No replacement loads while the retired worker still holds its weights.

    Before: recovery spawned the replacement 0.6 s in, while the old worker
    lived until 1.3 s: two copies of the model at once.
    """
    loop = asyncio.get_running_loop()

    def late_kill(process: asyncio.subprocess.Process) -> None:
        def kill() -> None:
            with contextlib.suppress(ProcessLookupError):
                os.kill(process.pid, signal.SIGKILL)

        loop.call_later(SLOW_EXIT_S, kill)

    monkeypatch.setattr(asyncio.subprocess.Process, "kill", late_kill)
    monkeypatch.setattr(cleanup_process_mod, "KILL_REAP_TIMEOUT_S", 0.1)
    spawned, alive_at_spawn = record_spawns(monkeypatch)
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        wedged_pid = cleanup.pid
        assert wedged_pid is not None
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        assert result.reason == "timeout_hard"

        await wait_until_loaded(cleanup)
        assert len(spawned) == 2
        assert alive_at_spawn == []
        assert process_gone(wedged_pid)
        assert cleanup.unhealthy is False
        assert (await cleanup.cleanup("next dictation", "system")).text == "NEXT DICTATION"
    finally:
        await cleanup.aclose()


async def test_cancelled_wedged_chunk_returns_before_the_worker_exits(
    monkeypatch,
) -> None:
    """Cancelling a wedged chunk returns before the worker exits, however
    late SIGKILL lands; the replacement still waits for that exit.

    Before: the cancel waited for the exit, up to 5.5 s, on the streaming path.
    """
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    spawned, alive_at_spawn = record_spawns(monkeypatch)
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        cancel_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        wedged_pid = cleanup.pid
        assert wedged_pid is not None
        chunk = asyncio.create_task(
            cleanup.cleanup("__hang__", "system", timeout_ms=60_000))
        await asyncio.sleep(0.2)

        chunk.cancel()
        # A hang detector, not a latency bound: the live worker below shows
        # the cancel did not wait for its exit.
        done, _ = await asyncio.wait({chunk}, timeout=CLOSE_HANG_S)
        assert chunk in done, f"the cancel still waits after {CLOSE_HANG_S:.0f} s"
        assert not process_gone(wedged_pid)

        await wait_until_loaded(cleanup, timeout_s=LATE_KILL_S + 5)
        assert process_gone(wedged_pid)
        assert len(spawned) == 2
        assert alive_at_spawn == []
        assert (await cleanup.cleanup("after", "system")).text == "AFTER"
    finally:
        await cleanup.aclose()


async def test_defer_during_a_wedged_reload_returns_before_the_worker_exits(
    monkeypatch, tmp_path,
) -> None:
    """A dictation start that interrupts a wedged replacement load does not
    wait for SIGKILL to land.

    Before: `defer_recovery` waited for the exit, up to 5.5 s, before the
    dictation could start.
    """
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    spawned, alive_at_spawn = record_spawns(monkeypatch)
    command = fixture_command() + ["--wedge-second-load", str(tmp_path / "loads")]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        await cleanup.load_async("warm prompt")
        # The crash is the first quick loss, so the reload starts at once.
        await cleanup.cleanup("__crash__", "system")
        await wait_until_wedged(tmp_path / "loads")
        assert len(spawned) == 2

        deferring = asyncio.create_task(cleanup.defer_recovery())
        # A hang detector, not a latency bound: the live worker below shows
        # the defer did not wait for its exit.
        done, _ = await asyncio.wait({deferring}, timeout=CLOSE_HANG_S)
        assert deferring in done, f"the defer still waits after {CLOSE_HANG_S:.0f} s"
        deferring.result()
        assert not process_gone(spawned[1])

        # Dictations that interrupt the wait for that exit load nothing, so
        # they do not count toward the deferral escalation.
        for _ in range(cleanup_process_mod.MAX_RECOVERY_DEFERRALS):
            cleanup.resume_recovery()
            await asyncio.sleep(0.05)
            await cleanup.defer_recovery()
        assert cleanup.unhealthy is False

        cleanup.resume_recovery()
        await wait_until_loaded(cleanup, timeout_s=LATE_KILL_S + 5)
        assert process_gone(spawned[1])
        assert len(spawned) == 3
        assert alive_at_spawn == []
    finally:
        await cleanup.aclose()


class ContendedLock(asyncio.Lock):
    """An asyncio.Lock that tells a test once a caller waits for it."""

    def __init__(self) -> None:
        super().__init__()
        self.contended = asyncio.Event()

    async def acquire(self) -> bool:
        if self.locked():
            self.contended.set()
        return await super().acquire()


async def load_then_wedge(cleanup: CleanupProcess, marker_dir: Path) -> asyncio.Task:
    """Load `cleanup`, then wedge its worker in a cleanup that never returns.

    Only SIGKILL ends that worker: it ignores SIGTERM and never reads the
    socket's EOF. Returns the hung cleanup call, which ends once the worker
    is reaped.
    """
    await cleanup.load_async("warm prompt")
    pid = cleanup.pid
    hung = asyncio.create_task(
        cleanup.cleanup("__hang__", "system", timeout_ms=60_000))
    await wait_until(lambda: (marker_dir / str(pid)).exists(), "the worker never wedged")
    return hung


# A hang detector for the cancelled-aclose() tests, not a latency bound: the
# reap alone waits EXIT_WAIT_S + KILL_REAP_TIMEOUT_S, and a loaded machine
# stretches both.
CLOSE_HANG_S = 10.0


class ReapLog:
    """How a test's `_reap` calls went: how many run now, and how many a
    cancel cut short."""

    def __init__(self) -> None:
        self.running = 0
        self.cut_short = 0


def record_reaps(monkeypatch) -> ReapLog:
    """Count every `_reap` of the test in a ReapLog."""
    reaps = ReapLog()
    reap = CleanupProcess._reap

    async def recording_reap(self, process):
        reaps.running += 1
        try:
            await reap(self, process)
        except asyncio.CancelledError:
            reaps.cut_short += 1
            raise
        finally:
            reaps.running -= 1

    monkeypatch.setattr(CleanupProcess, "_reap", recording_reap)
    return reaps


def retired_pids() -> set[int]:
    return {process.pid for process in cleanup_process_mod._retired_workers}


def exited_or_retired(pid: int) -> bool:
    """Whether a finished reap is done with worker `pid`: it exited, or it
    outlived SIGKILL and the retired registry holds the next spawn for it."""
    return process_gone(pid) or pid in retired_pids()


async def check_cancelled_close(
    closing: asyncio.Task, pids: list[int], reaps: ReapLog,
) -> set[int]:
    """Check that a cancelled aclose() finished every reap before the cancel
    reached its caller, and that every worker then exits.

    It checks what a reap guarantees, not how fast it runs. A worker that
    outlives SIGKILL by KILL_REAP_TIMEOUT_S is retired, not waited for, and
    a loaded machine can make a healthy worker look like one. Returns the
    pids that were retired, not exited, when the cancel reached the caller.
    """
    at_cancel: dict[str, object] = {}

    def snapshot(_task: asyncio.Task) -> None:
        at_cancel["reaps running"] = reaps.running
        at_cancel["settled"] = all(exited_or_retired(pid) for pid in pids)
        at_cancel["retired"] = retired_pids() & set(pids)

    closing.add_done_callback(snapshot)
    done, _ = await asyncio.wait({closing}, timeout=CLOSE_HANG_S)
    assert closing in done, f"aclose() still running {CLOSE_HANG_S:.0f} s after its cancel"
    assert closing.cancelled()
    assert at_cancel["reaps running"] == 0
    assert at_cancel["settled"]
    assert reaps.cut_short == 0
    await wait_until(
        lambda: all(process_gone(pid) for pid in pids),
        "a reaped worker never exited",
        timeout_s=CLOSE_HANG_S,
    )
    return at_cancel["retired"]


async def test_cancelled_aclose_reaps_the_worker_then_propagates(
    monkeypatch, tmp_path,
) -> None:
    """A cancel that lands while aclose() waits for a recovery reaches the
    caller once the recovery has reaped its worker.

    Before: aclose() awaited the recovery under suppress(CancelledError),
    which swallowed the caller's cancel too. Then it awaited the recovery
    directly, which carried the cancel into the recovery's reap: SIGKILL at
    once, and a return before the worker exited.
    """
    spawned, _ = record_spawns(monkeypatch)
    reaps = record_reaps(monkeypatch)
    command = fixture_command() + ["--wedge-second-load", str(tmp_path / "loads")]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        await cleanup.load_async("warm prompt")
        await cleanup.cleanup("__crash__", "system")
        await wait_until_wedged(tmp_path / "loads")

        # aclose() cancels the recovery, whose load then reaps the wedged
        # worker; SIGTERM is ignored, so that reap takes EXIT_WAIT_S.
        closing = asyncio.create_task(cleanup.aclose())
        await wait_until(lambda: cleanup.pid is None, "the recovery never began its reap")
        closing.cancel()
        await check_cancelled_close(closing, spawned, reaps)
    finally:
        kill_workers(pid for pid in spawned if not process_gone(pid))


async def test_cancelled_aclose_finishes_its_own_reap(monkeypatch, tmp_path) -> None:
    """A cancel that lands while aclose() reaps a worker that ignores SIGTERM
    reaches the caller once that reap has finished.

    Before: the cancel landed in the reap itself, which SIGKILLed the worker
    and raised without waiting for its exit.
    """
    spawned, _ = record_spawns(monkeypatch)
    reaps = record_reaps(monkeypatch)
    command = fixture_command() + ["--hang-marker-dir", str(tmp_path)]
    cleanup = CleanupProcess("fake", worker_command=command)
    hung = None
    try:
        hung = await load_then_wedge(cleanup, tmp_path)

        closing = asyncio.create_task(cleanup.aclose())
        # _stop_worker clears the pid, then SIGTERMs in the same step.
        await wait_until(lambda: cleanup.pid is None, "aclose() never began its reap")
        closing.cancel()
        await check_cancelled_close(closing, spawned, reaps)
    finally:
        kill_workers(pid for pid in spawned if not process_gone(pid))
        if hung is not None:
            await asyncio.wait({hung}, timeout=CLOSE_HANG_S)


async def test_cancelled_aclose_retires_a_worker_that_outlives_sigkill(
    monkeypatch, tmp_path,
) -> None:
    """A cancelled aclose() of a worker that outlives SIGKILL reaches its
    caller once the reap has retired that worker, never before.

    aclose() does not wait for that exit, by design: the retired registry
    holds every later spawn until the worker is gone.
    """
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    spawned, _ = record_spawns(monkeypatch)
    reaps = record_reaps(monkeypatch)
    command = fixture_command() + ["--hang-marker-dir", str(tmp_path)]
    cleanup = CleanupProcess("fake", worker_command=command)
    hung = None
    try:
        hung = await load_then_wedge(cleanup, tmp_path)
        pid = cleanup.pid

        closing = asyncio.create_task(cleanup.aclose())
        await wait_until(lambda: cleanup.pid is None, "aclose() never began its reap")
        closing.cancel()
        assert await check_cancelled_close(closing, spawned, reaps) == {pid}
    finally:
        kill_workers(pid for pid in spawned if not process_gone(pid))
        if hung is not None:
            await asyncio.wait({hung}, timeout=CLOSE_HANG_S)


async def test_aclose_cancelled_waiting_for_the_load_lock_still_reaps(
    monkeypatch, tmp_path,
) -> None:
    """A cancel that lands while aclose() waits for a load or hibernate to
    release the load lock still reaps the worker, and then reaches the
    caller.

    Before: the cancel ended the lock wait, so aclose() never stopped the
    worker at all.
    """
    spawned, _ = record_spawns(monkeypatch)
    reaps = record_reaps(monkeypatch)
    command = fixture_command() + ["--hang-marker-dir", str(tmp_path)]
    cleanup = CleanupProcess("fake", worker_command=command)
    lock = cleanup._load_lock = ContendedLock()
    hung = None
    try:
        hung = await load_then_wedge(cleanup, tmp_path)
        await lock.acquire()  # a load or hibernate in flight

        closing = asyncio.create_task(cleanup.aclose())
        await asyncio.wait_for(lock.contended.wait(), CLOSE_HANG_S)
        closing.cancel()
        lock.release()
        await check_cancelled_close(closing, spawned, reaps)
    finally:
        kill_workers(pid for pid in spawned if not process_gone(pid))
        if hung is not None:
            await asyncio.wait({hung}, timeout=CLOSE_HANG_S)


async def test_cancelled_aclose_logs_a_failure_the_cancel_hides(
    monkeypatch, caplog,
) -> None:
    """A teardown that fails while aclose()'s caller is cancelled is logged:
    the caller gets its cancel, not the failure, so the log is its only
    trace."""
    stopping = asyncio.Event()

    async def stop_failing(self) -> None:
        stopping.set()
        await asyncio.sleep(0.2)  # reaping the worker
        raise RuntimeError("reap failed")

    monkeypatch.setattr(CleanupProcess, "_stop_worker", stop_failing)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    closing = asyncio.create_task(cleanup.aclose())
    await asyncio.wait_for(stopping.wait(), CLOSE_HANG_S)
    closing.cancel()

    with pytest.raises(asyncio.CancelledError):
        await closing
    assert any(
        record.levelname == "WARNING"
        and record.exc_info is not None
        and str(record.exc_info[1]) == "reap failed"
        for record in caplog.records
    )


async def test_aclose_after_its_caller_was_cancelled_finishes(
    monkeypatch, tmp_path,
) -> None:
    """aclose() in a `finally` that a cancel entered, as serve()'s is,
    returns normally, so the rest of that `finally` runs.

    A regression guard; no release shipped this bug. A draft of the aclose()
    cancel fix raised whenever its task had a cancel pending, which counted
    the cancel that entered the `finally`. Its own cancel of the recovery
    then passed for the caller's, and serve() skipped closing its other
    engines.
    """
    spawned, _ = record_spawns(monkeypatch)
    command = fixture_command() + ["--wedge-second-load", str(tmp_path / "loads")]
    cleanup = CleanupProcess("fake", worker_command=command)
    serving_started = asyncio.Event()
    finished: list[str] = []

    async def serve_like() -> None:
        try:
            serving_started.set()
            await asyncio.Event().wait()
        finally:
            await cleanup.aclose()
            finished.append("rest of finally")

    try:
        await cleanup.load_async("warm prompt")
        await cleanup.cleanup("__crash__", "system")
        await wait_until_wedged(tmp_path / "loads")

        serving = asyncio.create_task(serve_like())
        await serving_started.wait()
        serving.cancel()
        await asyncio.wait({serving}, timeout=CLOSE_HANG_S)

        assert finished == ["rest of finally"]
        assert serving.cancelled()
        assert all(exited_or_retired(pid) for pid in spawned)
        await wait_until(
            lambda: all(process_gone(pid) for pid in spawned),
            "a reaped worker never exited",
            timeout_s=CLOSE_HANG_S,
        )
    finally:
        kill_workers(pid for pid in spawned if not process_gone(pid))


async def test_a_cancelled_stop_still_fails_the_calls_waiting_on_it(
    monkeypatch, tmp_path,
) -> None:
    """A worker stop that a cancel cuts short still fails the calls waiting
    on that worker, so they return at once, not at their own deadline.

    Before: the cancel skipped the loop that fails them, and the reader that
    would have failed them was already cancelled.
    """
    spawned, _ = record_spawns(monkeypatch)
    reaping = asyncio.Event()
    reap = CleanupProcess._reap

    async def signalled_reap(self, process):
        reaping.set()
        await reap(self, process)

    monkeypatch.setattr(CleanupProcess, "_reap", signalled_reap)
    command = fixture_command() + ["--hang-marker-dir", str(tmp_path)]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        hung = await load_then_wedge(cleanup, tmp_path)

        stopping = asyncio.create_task(cleanup._stop_worker())
        # The worker ignores SIGTERM, so the reap waits EXIT_WAIT_S for it:
        # the cancel lands inside that wait.
        await asyncio.wait_for(reaping.wait(), CLOSE_HANG_S)
        stopping.cancel()
        # The call's own deadline is 60 s away.
        done, _ = await asyncio.wait({hung, stopping}, timeout=CLOSE_HANG_S)

        assert stopping in done and stopping.cancelled()
        assert hung in done
        assert hung.result().reason.startswith("error:")
    finally:
        await cleanup.aclose()
        kill_workers(pid for pid in spawned if not process_gone(pid))


def fail_close_before_reap(cleanup: CleanupProcess) -> None:
    """Make `cleanup`'s close fail before it reaps the worker: the recovery
    that close waits on has failed."""

    async def failed_recovery() -> None:
        raise RuntimeError("recovery failed")

    cleanup._recovery_task = asyncio.create_task(failed_recovery())


async def test_a_close_that_fails_still_reaps_the_worker(monkeypatch) -> None:
    """aclose() leaves the worker exited or retired even when a recovery it
    waits on has failed, and then raises that failure.

    Before: the failure skipped the reap, so the worker outlived its proxy.
    """
    spawned, _ = record_spawns(monkeypatch)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        pid = cleanup.pid
        fail_close_before_reap(cleanup)

        with pytest.raises(RuntimeError, match="recovery failed"):
            await cleanup.aclose()
        assert exited_or_retired(pid)
    finally:
        kill_workers(pid for pid in spawned if not process_gone(pid))


async def test_worker_alive_past_the_exit_bound_escalates_instead_of_loading(
    monkeypatch, caplog,
) -> None:
    """A retired worker still alive at RETIRED_EXIT_TIMEOUT_S is stuck in the
    kernel: cleanup escalates to an engine restart rather than load a second
    copy of the model beside it."""
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    monkeypatch.setattr(cleanup_process_mod, "RETIRED_EXIT_TIMEOUT_S", 0.3)
    spawned, alive_at_spawn = record_spawns(monkeypatch)
    escalated = asyncio.Event()
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
        on_unhealthy=escalated.set,
    )
    try:
        await cleanup.load_async("warm prompt")
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        assert result.reason == "timeout_hard"

        await asyncio.wait_for(escalated.wait(), CALLER_WAIT_MAX_S + 1)
        assert cleanup.unhealthy is True
        assert len(spawned) == 1
        assert alive_at_spawn == []
        # One bound, not one per recovery attempt.
        assert caplog.text.count("waiting for retired cleanup worker") == 1
    finally:
        await cleanup.aclose()


async def test_new_proxy_waits_for_a_worker_another_proxy_retired(
    monkeypatch,
) -> None:
    """A worker one proxy retired holds every other proxy's spawn as well.

    Before: each proxy kept its own registry, so the retry, set_model or a
    restarted load built a fresh proxy and loaded beside the retired worker.
    """
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    spawned, alive_at_spawn = record_spawns(monkeypatch)
    first = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        cancel_grace_s=0.05,
    )
    second: CleanupProcess | None = None
    try:
        await first.load_async("warm prompt")
        wedged_pid = first.pid
        assert wedged_pid is not None
        chunk = asyncio.create_task(
            first.cleanup("__hang__", "system", timeout_ms=60_000))
        await asyncio.sleep(0.2)
        chunk.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await chunk
        await first.aclose()
        assert not process_gone(wedged_pid)  # retired, still exiting

        # Built after the retirement, as set_model and the retry build theirs.
        second = CleanupProcess("fake", worker_command=fixture_command())
        await second.load_async("warm prompt")
        assert process_gone(wedged_pid)
        assert len(spawned) == 2
        assert alive_at_spawn == []
    finally:
        await first.aclose()
        if second is not None:
            await second.aclose()


async def test_retired_exit_bound_runs_from_retirement_across_deferrals(
    monkeypatch, tmp_path,
) -> None:
    """Dictations that keep interrupting the wait for a retired worker do not
    restart its bound: cleanup escalates RETIRED_EXIT_TIMEOUT_S after the
    worker was retired.

    Before: each resumed recovery waited a fresh bound, so a user who
    dictated at least once per bound kept cleanup raw with no escalation.
    """
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    monkeypatch.setattr(cleanup_process_mod, "RETIRED_EXIT_TIMEOUT_S", 0.8)
    spawned, _ = record_spawns(monkeypatch)
    command = fixture_command() + ["--wedge-second-load", str(tmp_path / "loads")]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        await cleanup.load_async("warm prompt")
        await cleanup.cleanup("__crash__", "system")  # its reload wedges
        await wait_until_wedged(tmp_path / "loads")
        await cleanup.defer_recovery()  # retires the wedged worker
        retired_at = time.monotonic()

        # A dictation every 0.3 s, each shorter than the bound.
        while time.monotonic() - retired_at < 1.6 and not cleanup.unhealthy:
            cleanup.resume_recovery()
            await asyncio.sleep(0.25)
            await cleanup.defer_recovery()

        assert cleanup.unhealthy is True
        assert not process_gone(spawned[1])  # escalated before it exited
        assert len(spawned) == 2
    finally:
        await cleanup.aclose()


async def test_hard_timeout_loop_is_respawned_with_backoff(monkeypatch) -> None:
    """Workers lost to hard timeouts right after loading extend the crash-loop
    streak as crashes do, so the second loss waits out a backoff.

    Before: only the response reader counted losses, and a replacement
    retires its worker without it, so hard timeouts reloaded back to back.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 2.0)
    spawned, _ = record_spawns(monkeypatch)
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        hard_timeout_grace_s=0.05,
    )
    try:
        await cleanup.load_async("warm prompt")
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        assert result.reason == "timeout_hard"
        await wait_until_loaded(cleanup)  # loss 1 respawns at once
        result = await cleanup.cleanup("__hang__", "system", timeout_ms=50)
        assert result.reason == "timeout_hard"

        await asyncio.sleep(1.2)  # past the reap, inside the 2 s backoff
        assert len(spawned) == 2
        assert cleanup.recovery_deadline is not None
        await wait_until_loaded(cleanup, timeout_s=5)
        assert len(spawned) == 3
    finally:
        await cleanup.aclose()


async def test_loss_after_a_healthy_run_respawns_at_once(monkeypatch) -> None:
    """Crashes spaced past RESPAWN_STREAK_RESET_S are not a crash loop."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_STREAK_RESET_S", 0.2)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        for _ in range(3):
            await asyncio.sleep(0.25)
            crashed = await cleanup.cleanup("__crash__", "system")
            assert crashed.applied is False
            await wait_until_loaded(cleanup)
        assert (await cleanup.cleanup("after", "system")).text == "AFTER"
    finally:
        await cleanup.aclose()


def backoff_left_s(cleanup: CleanupProcess) -> float:
    """Seconds until the crash-loop backoff lets a respawn start."""
    return max(0.0, cleanup._respawn_not_before - time.monotonic())


async def test_a_worker_that_served_resets_the_crash_streak(monkeypatch) -> None:
    """A loss after the worker served a cleanup respawns at once, however many
    such losses came before. Losses with no success between still back off.

    Before: every quick loss grew the streak, so eight timeouts spread over a
    busy afternoon reached the 300 s cap, and every later loss left
    dictation raw for five minutes.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 30.0)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        for _ in range(3):
            assert (await cleanup.cleanup("hello", "system")).applied
            await cleanup.cleanup("__crash__", "system")
            assert backoff_left_s(cleanup) == 0.0
            await wait_until_loaded(cleanup, timeout_s=10.0)

        # The last loss above had no success after it, so this one backs off.
        await cleanup.cleanup("__crash__", "system")
        assert backoff_left_s(cleanup) > 20.0
    finally:
        await cleanup.aclose()


class SpawnWatch:
    """Record, at each worker spawn, which watched pids are still alive."""

    def __init__(self, monkeypatch, watched: list[int]) -> None:
        self.alive_at_spawn: list[list[int]] = []
        create = asyncio.create_subprocess_exec

        async def recording_create(*args, **kwargs):
            self.alive_at_spawn.append(
                [pid for pid in watched if not process_gone(pid)])
            return await create(*args, **kwargs)

        monkeypatch.setattr(asyncio, "create_subprocess_exec", recording_create)


async def retire_worker(cleanup: CleanupProcess) -> int:
    """Wedge `cleanup`'s worker and cancel into it, so its reap retires it."""
    pid = cleanup.pid
    assert pid is not None
    chunk = asyncio.create_task(
        cleanup.cleanup("__hang__", "system", timeout_ms=60_000))
    await asyncio.sleep(0.2)
    chunk.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await chunk
    assert pid in [process.pid for process in cleanup_process_mod._retired_workers]
    return pid


async def test_spawn_waits_for_a_worker_retired_during_its_wait(
    monkeypatch,
) -> None:
    """A worker retired while a load already waits on another one holds
    that load too, until it has exited.

    Before: the wait watched only the workers retired when it began, so the
    load spawned beside the later one as soon as the first exited.
    """
    deliver_sigkill_late(monkeypatch, 4.0)
    first = CleanupProcess(
        "fake", worker_command=fixture_command(), cancel_grace_s=0.05)
    third = CleanupProcess(
        "fake", worker_command=fixture_command(), cancel_grace_s=0.05)
    second: CleanupProcess | None = None
    loading: asyncio.Task[None] | None = None
    try:
        await first.load_async("warm prompt")
        await third.load_async("warm prompt")
        watch = SpawnWatch(monkeypatch, [first.pid, third.pid])
        await retire_worker(first)
        await first.aclose()

        second = CleanupProcess("fake", worker_command=fixture_command())
        loading = asyncio.create_task(second.load_async("warm prompt"))
        await wait_until(
            lambda: second._respawn_waiting,
            "the second load never waited for the retired worker",
        )
        await retire_worker(third)  # while `second` waits on `first`'s worker
        await third.aclose()
        await asyncio.wait_for(loading, timeout=20.0)

        assert watch.alive_at_spawn == [[]]
    finally:
        if loading is not None and not loading.done():
            loading.cancel()
        await first.aclose()
        await third.aclose()
        if second is not None:
            await second.aclose()


async def test_recovery_waits_for_the_worker_it_stops_itself(monkeypatch) -> None:
    """A recovery that starts while its own worker still runs (a failed call
    schedules one without stopping the worker) reaps that worker first and
    waits for it like any retired worker.

    Before: the wait ran before the spawn stopped the worker, so a worker
    that outlived SIGKILL was retired after the check, and the replacement
    spawned beside it.
    """
    deliver_sigkill_late(monkeypatch, LATE_KILL_S)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        watch = SpawnWatch(monkeypatch, [cleanup.pid])
        chunk = asyncio.create_task(
            cleanup.cleanup("__hang__", "system", timeout_ms=60_000))
        await asyncio.sleep(0.2)

        cleanup._schedule_recovery("call_failed")
        await wait_until(
            lambda: not cleanup.loaded, "the recovery never began")
        await wait_until_loaded(cleanup, timeout_s=15.0)

        assert watch.alive_at_spawn == [[]]
        assert (await chunk).applied is False
    finally:
        await cleanup.aclose()


async def test_replacement_load_reports_its_deadline() -> None:
    """A replacement loading right after a first loss (no backoff, no
    retired worker) still reports when it should have loaded.

    Before: recovery_deadline was None once the backoff had passed, so
    meeting notes that met the load took the model for lost and restarted
    the engine.
    """
    cleanup = CleanupProcess(
        "fake", worker_command=[*fixture_command(), "--load-delay", "1.0"])
    try:
        await cleanup.load_async("warm prompt")
        await cleanup.cleanup("__crash__", "system")
        for _ in range(200):
            if cleanup.recovering:
                break
            await asyncio.sleep(0.01)
        assert cleanup.recovering and not cleanup.loaded

        deadline = cleanup.recovery_deadline
        assert deadline is not None
        assert 0 < deadline - time.monotonic() <= cleanup_process_mod.LOAD_TIMEOUT_S
        await wait_until_loaded(cleanup, timeout_s=10.0)
        assert cleanup.recovery_deadline is None
    finally:
        await cleanup.aclose()


async def test_deferred_recovery_still_counts_a_quick_crash(monkeypatch) -> None:
    """A crash right after ready extends the streak even when a long dictation
    defers recovery past RESPAWN_STREAK_RESET_S.

    Before: the streak was judged when recovery ran, so the deferral turned a
    quick crash into a healthy run and the respawn skipped its backoff.
    """
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_STREAK_RESET_S", 1.0)
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 2.5)
    spawned, _ = record_spawns(monkeypatch)
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        await cleanup.cleanup("__crash__", "system")  # loss 1 respawns at once
        await wait_until_loaded(cleanup)

        await cleanup.defer_recovery()  # a dictation starts
        await cleanup.cleanup("__crash__", "system")  # loss 2, just after ready
        await asyncio.sleep(1.3)  # the dictation outlasts the reset window
        cleanup.resume_recovery()
        await asyncio.sleep(0.3)
        assert len(spawned) == 2  # still inside loss 2's 2.5 s backoff

        await wait_until_loaded(cleanup, timeout_s=5)
        assert len(spawned) == 3
    finally:
        await cleanup.aclose()


def test_respawn_backoff_saturates_past_a_1024_streak() -> None:
    """5 s x 2**1024 overflows a float; a long crash loop stays at the cap."""
    cap = cleanup_process_mod.RESPAWN_BACKOFF_MAX_S
    assert cleanup_process_mod._respawn_delay_s(1_500) == cap
    assert cleanup_process_mod.respawn_backoff_s(1_500) == cap
    assert cleanup_process_mod.respawn_backoff_s(0) == cleanup_process_mod.RESPAWN_BACKOFF_S


async def test_respawn_backoff_reports_recovering_until_its_deadline(
    monkeypatch,
) -> None:
    """Callers can tell a crash-loop backoff from a lost model: the proxy
    reports recovering and when the replacement may load."""
    monkeypatch.setattr(cleanup_process_mod, "RESPAWN_BACKOFF_S", 1.0)
    command = fixture_command() + ["--exit-after-load"]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        await cleanup.load_async("warm prompt")
        for _ in range(300):
            if cleanup.recovery_deadline is not None:
                break
            await asyncio.sleep(0.01)
        await asyncio.sleep(0.2)  # the lost worker is reaped; recovery waits
        deadline = cleanup.recovery_deadline
        assert deadline is not None
        # The backoff, then the replacement's load.
        load_s = cleanup_process_mod.LOAD_TIMEOUT_S
        assert load_s < deadline - time.monotonic() <= 1.0 + load_s
        assert cleanup.recovering is True
        assert cleanup.loaded is False
        result = await cleanup.cleanup("during backoff", "system")
        assert result.reason == "llm_recovering"
    finally:
        await cleanup.aclose()


async def test_dictation_during_respawn_backoff_does_not_escalate() -> None:
    """Deferring a recovery that is only waiting out its backoff is not a
    stuck warm-up, however many dictations arrive meanwhile."""
    command = fixture_command() + ["--exit-after-load"]
    cleanup = CleanupProcess("fake", worker_command=command)
    try:
        await cleanup.load_async("warm prompt")
        for _ in range(200):
            if time.monotonic() < cleanup._respawn_not_before:
                break
            await asyncio.sleep(0.01)
        assert cleanup._respawn_streak == 2

        for _ in range(cleanup_process_mod.MAX_RECOVERY_DEFERRALS + 1):
            await cleanup.defer_recovery()
            cleanup.resume_recovery()
            await asyncio.sleep(0.01)
        assert cleanup.unhealthy is False
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


DECISION = Question("kind", "What does the command ask for?", (
    ("open_app", "open an app"), ("other", "something else"),
))


async def test_decide_round_trips_typed_answers() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        result = await cleanup.decide(
            "command: open slack", [DECISION], max_input_tokens=4_096)

        assert result.status == STATUS_OK
        assert result.answers["kind"].choice == "open_app"
        assert result.answers["kind"].label_mass == 0.9
        assert result.ms == 1
        assert result.state_tokens == 4_096
    finally:
        await cleanup.aclose()


async def test_decide_cancellation_preserves_warm_worker() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid
        cancel = threading.Event()
        task = asyncio.create_task(
            cleanup.decide("__cancel__", [DECISION], cancel_event=cancel))
        await asyncio.sleep(0.05)
        cancel.set()

        result = await task

        assert result.status == STATUS_CANCELLED
        assert cleanup.pid == original_pid
        assert cleanup.loaded is True
    finally:
        await cleanup.aclose()


async def test_decide_hard_timeout_replaces_worker() -> None:
    cleanup = CleanupProcess(
        "fake", worker_command=fixture_command(), hard_timeout_grace_s=0.05)
    try:
        await cleanup.load_async("warm prompt")
        original_pid = cleanup.pid

        result = await cleanup.decide("__hang__", [DECISION], timeout_ms=50)

        assert result.status == STATUS_TIMEOUT
        assert result.reason == "timeout_hard"
        await wait_until_loaded(cleanup)
        assert cleanup.pid != original_pid
        assert (await cleanup.cleanup("after decide", "system")).text == "AFTER DECIDE"
    finally:
        await cleanup.aclose()


async def test_decide_without_a_loaded_worker_is_unavailable() -> None:
    cleanup = CleanupProcess("fake", worker_command=fixture_command())
    try:
        result = await cleanup.decide("command: open slack", [DECISION])

        assert result.status == STATUS_UNAVAILABLE
        assert result.reason == "llm_not_loaded"
    finally:
        await cleanup.aclose()


async def test_worker_keeps_a_cancel_read_with_its_request() -> None:
    """A cancel line buffered right behind its request is read before the
    request's task first runs. It must still reach that request."""
    from velora_engine.cleanup_worker import Worker

    seen: list[bool] = []

    class RecordingEngine:
        async def decide(self, state, questions, *, cancel_event, **_kwargs):
            seen.append(cancel_event.is_set())
            return DecisionResult(STATUS_CANCELLED)

    class Sink:
        def write(self, _data: bytes) -> None:
            pass

        async def drain(self) -> None:
            pass

    reader = asyncio.StreamReader()
    reader.feed_data(encode_cleanup_ipc_message({
        "id": "r1", "op": "decide", "state": "s",
        "questions": [DECISION.to_dict()]}))
    reader.feed_data(encode_cleanup_ipc_message({"op": "cancel", "target": "r1"}))
    worker = Worker("unused", reader, Sink())
    worker.engine.close()
    worker.engine = RecordingEngine()
    serving = asyncio.create_task(worker.serve())
    try:
        for _ in range(100):
            if seen:
                break
            await asyncio.sleep(0.01)

        assert seen == [True]
    finally:
        serving.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await serving


async def test_worker_passes_copy_draft_to_the_engine() -> None:
    from velora_engine.cleanup_worker import Worker

    seen: list[bool] = []

    class RecordingEngine:
        async def cleanup(self, raw, _prompt, *, copy_draft=False, **_kwargs):
            seen.append(copy_draft)
            return CleanupResult(raw, True, 1)

    class Sink:
        def write(self, _data: bytes) -> None:
            pass

        async def drain(self) -> None:
            pass

    reader = asyncio.StreamReader()
    for request_id, flag in (("r1", True), ("r2", None)):
        message = {"id": request_id, "op": "cleanup", "raw": "hi",
                   "system_prompt": "s", "timeout_ms": 1_000}
        if flag is not None:
            message["copy_draft"] = flag
        reader.feed_data(encode_cleanup_ipc_message(message))
    worker = Worker("unused", reader, Sink())
    worker.engine.close()
    worker.engine = RecordingEngine()
    serving = asyncio.create_task(worker.serve())
    try:
        for _ in range(100):
            if len(seen) == 2:
                break
            await asyncio.sleep(0.01)

        assert seen == [True, False]
    finally:
        serving.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await serving


async def test_queued_decision_rechecks_generation_after_lock() -> None:
    cleanup = CleanupProcess(
        "fake",
        worker_command=fixture_command(),
        queue_timeout_s=1.0,
    )
    try:
        await cleanup.load_async("warm prompt")
        await cleanup._operation_lock.acquire()
        queued = asyncio.create_task(cleanup.decide("state", [DECISION]))
        await asyncio.sleep(0.02)
        cleanup._schedule_replacement("test_generation_fence")
        cleanup._operation_lock.release()

        result = await queued

        assert result.status == STATUS_UNAVAILABLE
        assert result.reason in {"llm_recovering", "llm_not_loaded"}
        await wait_until_loaded(cleanup)
    finally:
        if cleanup._operation_lock.locked():
            cleanup._operation_lock.release()
        await cleanup.aclose()


async def test_repeated_task_cancel_cannot_interrupt_decision_handoff(
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
        cleanup.decide("state", [DECISION], timeout_ms=10_000))
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
    assert replaced == ["decision_cancel_unresponsive"]


def spawn_fixture_worker(*flags: str) -> tuple[subprocess.Popen, socket.socket]:
    """Start the fake worker without a proxy; returns it and our socket end."""
    ours, theirs = socket.socketpair()
    worker = subprocess.Popen(
        [*fixture_command(), "--fd", str(theirs.fileno()), "--model", "fake",
         *flags],
        pass_fds=(theirs.fileno(),),
    )
    theirs.close()
    return worker, ours


# Two loads: the second wedges a `--wedge-second-load` worker.
TWO_LOADS = b'{"id":"1","op":"load"}\n{"id":"2","op":"load"}\n'


def process_state(pid: int) -> str:
    """The ps state letters, e.g. "S" sleeping or "R" running."""
    return subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)],
        capture_output=True, text=True, check=False,
    ).stdout.strip()


async def test_wedged_fixture_worker_sleeps_instead_of_spinning(tmp_path) -> None:
    """A wedged fake worker blocks, so one a test leaks costs no CPU.

    Before: wedges spun on `while True: pass`; four leaked workers each held
    a core and pushed the load average past 240.
    """
    loads = tmp_path / "loads"
    worker, ours = spawn_fixture_worker("--wedge-second-load", str(loads))
    try:
        ours.sendall(TWO_LOADS)
        await wait_until_wedged(loads)

        states = []
        for _ in range(5):
            states.append(process_state(worker.pid))
            await asyncio.sleep(0.1)
        assert sum(state.startswith("R") for state in states) <= 1, states
    finally:
        worker.kill()
        worker.wait()
        ours.close()


# Runs the fake worker from argv, wedges it, prints its pid, then waits for
# stdin to close; killing this parent orphans the wedged worker.
ORPHANING_PARENT = """
import socket, subprocess, sys
ours, theirs = socket.socketpair()
worker = subprocess.Popen(
    [*sys.argv[1:], "--fd", str(theirs.fileno()), "--model", "fake"],
    pass_fds=(theirs.fileno(),),
)
ours.sendall(b'{"id":"1","op":"load"}\\n{"id":"2","op":"load"}\\n')
print(worker.pid, flush=True)
sys.stdin.read()
"""


async def test_orphaned_fixture_worker_exits_on_its_own(tmp_path) -> None:
    """A wedged fake worker whose parent died exits without being killed.

    Before: a pytest run that died with a worker wedged left it running,
    ignoring SIGTERM, until someone SIGKILLed it by hand.
    """
    loads = tmp_path / "loads"
    parent = subprocess.Popen(
        [sys.executable, "-c", ORPHANING_PARENT, *fixture_command(),
         "--wedge-second-load", str(loads)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    assert parent.stdout is not None
    worker_pid = int(parent.stdout.readline())
    try:
        await wait_until_wedged(loads)
        parent.kill()
        parent.wait()

        for _ in range(500):
            if process_gone(worker_pid):
                break
            await asyncio.sleep(0.01)
        assert process_gone(worker_pid)
    finally:
        parent.kill()
        parent.wait()
        with contextlib.suppress(ProcessLookupError):
            os.kill(worker_pid, signal.SIGKILL)


async def test_fixture_worker_exits_at_its_lifetime_cap(tmp_path) -> None:
    """A wedged fake worker that its live parent leaked exits at its cap.

    Before: it ran for as long as the pytest process that leaked it.
    """
    lifetime_s = 4.0
    loads = tmp_path / "loads"
    started = time.monotonic()
    worker, ours = spawn_fixture_worker(
        "--wedge-second-load", str(loads), "--max-lifetime", str(lifetime_s))
    try:
        ours.sendall(TWO_LOADS)
        await wait_until_wedged(loads, timeout_s=lifetime_s)

        # Wedged means SIGTERM is ignored and the socket is never read, so
        # only the cap can end it here.
        worker.wait(timeout=lifetime_s + 5.0)
        assert time.monotonic() - started >= lifetime_s
    finally:
        worker.kill()
        worker.wait()
        ours.close()


async def test_session_cleanup_kills_only_leaked_fixture_workers(
    tmp_path, monkeypatch,
) -> None:
    """The session cleanup SIGKILLs a worker a test leaked, and spares a
    process that has since taken a registered pid."""
    pid_dir = tmp_path / "pids"
    pid_dir.mkdir()
    loads = tmp_path / "loads"
    monkeypatch.setenv(PID_DIR_ENV, str(pid_dir))
    worker, ours = spawn_fixture_worker("--wedge-second-load", str(loads))
    bystander = subprocess.Popen(["sleep", "30"])
    (pid_dir / str(bystander.pid)).touch()
    try:
        ours.sendall(TWO_LOADS)
        await wait_until_wedged(loads)
        assert (pid_dir / str(worker.pid)).exists()

        assert kill_leaked(pid_dir) == [worker.pid]
        assert worker.wait(timeout=5.0) == -signal.SIGKILL
        assert bystander.poll() is None
    finally:
        for process in (worker, bystander):
            process.kill()
            process.wait()
        ours.close()
