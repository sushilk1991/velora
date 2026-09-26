"""Probes of CleanupProcess reaps and worker exits, shared by the cleanup
tests; never imported by production."""

from __future__ import annotations

import asyncio
import os

import velora_engine.cleanup_process as cleanup_process_mod
from velora_engine.cleanup_process import CleanupProcess


def process_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    return False


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


def hold_reaps(monkeypatch) -> asyncio.Event:
    """Hold every `_reap` until the returned event is set, as a worker slow
    to exit does, so a test can land a cancel while one runs."""
    release = asyncio.Event()
    reap = CleanupProcess._reap

    async def held_reap(self, process):
        await release.wait()
        await reap(self, process)

    monkeypatch.setattr(CleanupProcess, "_reap", held_reap)
    return release


def snapshot_at_end(task: asyncio.Task, pid: int, reaps: ReapLog) -> dict[str, object]:
    """Record, as `task` ends, how many reaps still run and whether worker
    `pid` has exited or been retired."""
    at_end: dict[str, object] = {}

    def snapshot(_task: asyncio.Task) -> None:
        at_end["reaps running"] = reaps.running
        at_end["settled"] = exited_or_retired(pid)

    task.add_done_callback(snapshot)
    return at_end


def retired_pids() -> set[int]:
    return {process.pid for process in cleanup_process_mod._retired_workers}


def exited_or_retired(pid: int) -> bool:
    """Whether a finished reap is done with worker `pid`: it exited, or it
    outlived SIGKILL and the retired registry holds the next spawn for it."""
    return process_gone(pid) or pid in retired_pids()
