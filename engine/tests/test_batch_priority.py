"""Only truly idle batch jobs use Darwin background scheduling.

Intent under test: idle mining stays invisible, while user-requested meeting
transcription/notes remain responsive. A dictation start still preempts either
kind of work at the server state-machine layer.
"""

import asyncio
import os
import sys
from unittest.mock import Mock

import pytest

from velora_engine import batch_priority
# From-import binds the real function before conftest's autouse fixture
# patches the module attribute — the syscall tests below exercise the real
# implementation on purpose.
from velora_engine.batch_priority import set_background as real_set_background
from velora_engine.config import Config
from velora_engine.server import Engine


@pytest.mark.skipif(sys.platform != "darwin", reason="Darwin scheduling API")
def test_set_background_round_trip_on_self():
    pid = os.getpid()
    try:
        assert real_set_background(pid, True)
    finally:
        # Always restore — a demoted pytest process throttles later tests.
        assert real_set_background(pid, False)


def test_set_background_swallows_dead_pid():
    # A cleanup child can die between refreshes; restoring its pid must not
    # raise, only report failure.
    assert real_set_background(2**22 - 1, False) in (True, False)


@pytest.fixture
def recording_engine(home, monkeypatch):
    calls: list[tuple[int, bool]] = []
    monkeypatch.setattr(
        batch_priority, "set_background",
        lambda pid, background: calls.append((pid, background)) or True)
    return Engine(Config(), parent_pid=None, hard_exit=Mock()), calls


def test_refresh_demotes_only_while_batch_work_is_unattended(recording_engine):
    eng, calls = recording_engine
    eng._begin_batch_job(lower_priority=True)
    assert (os.getpid(), True) in calls

    # A dictation start lifts the demotion immediately.
    calls.clear()
    eng._starting = True
    eng._refresh_batch_priority()
    assert (os.getpid(), False) in calls

    # Dictation released the machine: the next refresh re-demotes.
    calls.clear()
    eng._starting = False
    eng._refresh_batch_priority()
    assert (os.getpid(), True) in calls

    calls.clear()
    eng._end_batch_job(lower_priority=True)
    assert (os.getpid(), False) in calls
    assert eng._batch_jobs == 0


def test_user_visible_batch_work_never_enters_darwin_background(recording_engine):
    eng, calls = recording_engine

    eng._begin_batch_job(lower_priority=False)
    eng._end_batch_job(lower_priority=False)

    assert calls == []
    assert eng._batch_jobs == 0


@pytest.mark.asyncio
async def test_meeting_preemption_waits_for_idle_miner_priority_restore(recording_engine):
    eng, calls = recording_engine
    started = asyncio.Event()

    async def mining_step():
        eng._begin_batch_job(lower_priority=True)
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            eng._end_batch_job(lower_priority=True)

    eng._miner_task = asyncio.create_task(mining_step())
    await started.wait()
    assert eng._batch_jobs == 1

    await eng._cancel_idle_mining()

    assert eng._miner_task is None
    assert eng._mine_cancel.is_set()
    assert eng._batch_jobs == 0
    assert calls[-1] == (os.getpid(), False)


def test_refresh_tracks_respawned_cleanup_child(recording_engine):
    eng, calls = recording_engine
    eng.cleanup = Mock(pid=4242)
    eng._begin_batch_job(lower_priority=True)
    assert (4242, True) in calls

    # Child respawned mid-job under a new pid: the old pid is restored and
    # the new one demoted.
    calls.clear()
    eng.cleanup = Mock(pid=4343)
    eng._refresh_batch_priority()
    assert (4242, False) in calls
    assert (4343, True) in calls


def test_refresh_restores_child_spawned_while_demoted(recording_engine):
    # A cleanup child spawned while the parent was demoted inherits Darwin
    # background without ever entering the tracked set (review P1). Leaving
    # background must restore it anyway.
    eng, calls = recording_engine
    eng._begin_batch_job(lower_priority=True)  # only the engine demotes

    calls.clear()
    eng.cleanup = Mock(pid=5151)  # spawned mid-batch, inherited background
    eng._end_batch_job(lower_priority=True)
    assert (5151, False) in calls
    assert (os.getpid(), False) in calls
