"""Offline source propagation through the production cleanup worker."""

from __future__ import annotations

import asyncio
import json
import threading
from pathlib import Path

from velora_engine.cleanup_worker import Worker


async def test_worker_local_source(monkeypatch, tmp_path: Path):
    """Keep the logical identity separate from the offline source at the child."""
    from velora_engine import cleanup_worker

    calls = []

    class Engine:
        def __init__(self, model_id, *, local_model_path=None):
            calls.append((model_id, local_model_path))

        async def load_async(self, prompt):
            calls.append(prompt)

    class Writer:
        def write(self, data):
            self.message = json.loads(data)

        async def drain(self):
            pass

    monkeypatch.setattr(cleanup_worker, "CleanupEngine", Engine)
    writer = Writer()
    worker = Worker("logical/model", asyncio.StreamReader(), writer,
                    local_model_path=tmp_path)
    await worker._run("load-1", "load", {"warm_system_prompt": "warm"}, threading.Event())
    assert calls == [("logical/model", tmp_path), "warm"]
    assert writer.message == {"id": "load-1", "ok": True}
