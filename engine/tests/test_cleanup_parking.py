import asyncio
import os
from pathlib import Path
import sys

from velora_engine.cleanup_process import CleanupProcess


def proxy(*args):
    return CleanupProcess("fake", worker_command=[sys.executable,
        str(Path(__file__).parent / "fixtures/fake_cleanup_worker.py"), *args])


async def test_empty_proxy_can_be_parked_and_explicitly_loaded():
    cleanup = proxy()
    try:
        assert await cleanup.park_for_backend_switch()
        assert cleanup.hibernated and cleanup.pid is None and not cleanup.recovering
        assert cleanup.recovery_deadline is None
        assert await cleanup.ensure_loaded()
        assert (await cleanup.cleanup("send the draft", "prompt")).applied
    finally:
        await cleanup.aclose()


async def test_parking_reaps_real_child_before_success():
    cleanup = proxy()
    try:
        await cleanup.load_async()
        pid = cleanup.pid
        assert await cleanup.park_for_backend_switch()
        assert cleanup.pid is None and not cleanup.loaded and cleanup.hibernated
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("park returned with an old model process alive")
        cleanup.resume_recovery()
        await asyncio.sleep(.05)
        assert cleanup.pid is None, "parked standard model must not auto-respawn"
    finally:
        await cleanup.aclose()


async def test_parking_refuses_foreground_load_or_operation():
    cleanup = proxy("--load-delay", "0.15")
    try:
        loading = asyncio.create_task(cleanup.load_async())
        while cleanup.pid is None:
            await asyncio.sleep(.005)
        assert not await cleanup.park_for_backend_switch()
        await loading
        await cleanup._operation_lock.acquire()
        try:
            assert not await cleanup.park_for_backend_switch()
            assert cleanup.loaded
        finally:
            cleanup._operation_lock.release()
    finally:
        await cleanup.aclose()
        await asyncio.gather(loading, return_exceptions=True)
