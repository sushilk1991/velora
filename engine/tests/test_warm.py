"""Unit tests for V-02 non-blocking key-down prewarm (`cmd == 'warm'`)."""

from __future__ import annotations

import asyncio

import pytest

from velora_engine.config import Config
from velora_engine.server import Engine


class _FakeWarmCleanup:
    def __init__(self, *, loaded: bool = True, hibernated: bool = False) -> None:
        self.loaded = loaded
        self._hibernated = hibernated
        self.unhealthy = False
        self.ensure_calls = 0
        self.prepare_calls: list[list[tuple[str, str]]] = []
        self.done = asyncio.Event()

    async def ensure_loaded(self, cancel_event=None) -> bool:
        self.ensure_calls += 1
        self.loaded = True
        self._hibernated = False
        return True

    async def prepare_prefix(self, candidates, cancel_event=None):
        self.prepare_calls.append(list(candidates))
        self.done.set()


@pytest.mark.asyncio
async def test_warm_wakes_hibernated_cleanup_and_prepares_prefix(home):
    eng = Engine(Config(home))
    fake = _FakeWarmCleanup(loaded=False, hibernated=True)
    eng.cleanup = fake
    sent: list[dict] = []

    async def capture(msg):
        sent.append(msg)

    eng._send = capture

    await eng._cmd_warm({"cmd": "warm", "context": {"bundle_id": "com.tinyspeck.slackmacgap", "app_name": "Slack"}})
    assert sent[-1] == {"event": "warmed", "started": True, "reason": "ok"}
    await asyncio.wait_for(fake.done.wait(), timeout=2.0)
    assert fake.ensure_calls == 1
    assert len(fake.prepare_calls) == 1
    assert len(fake.prepare_calls[0]) == 2


@pytest.mark.asyncio
async def test_warm_rate_limits_to_once_per_second_and_skips_when_busy(home):
    eng = Engine(Config(home))
    fake = _FakeWarmCleanup(loaded=True, hibernated=False)
    eng.cleanup = fake
    sent: list[dict] = []

    async def capture(msg):
        sent.append(msg)

    eng._send = capture

    await eng._cmd_warm({"cmd": "warm", "context": {}})
    assert sent[-1]["started"] is True
    await asyncio.wait_for(fake.done.wait(), timeout=2.0)
    if eng._prewarm_task is not None:
        await eng._prewarm_task

    # Immediate second warm within 1 s is rate-limited.
    await eng._cmd_warm({"cmd": "warm", "context": {}})
    assert sent[-1] == {"event": "warmed", "started": False, "reason": "rate_limited"}

    # Reset rate-limit clock and verify busy session skips warm.
    eng._last_prewarm_at = 0.0
    eng._starting = True
    await eng._cmd_warm({"cmd": "warm", "context": {}})
    assert sent[-1] == {"event": "warmed", "started": False, "reason": "busy"}
