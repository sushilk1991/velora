"""Keyboard routing never changes manual selection or acquires a missing model."""

import asyncio
from test_server import connect, engine  # noqa: F401
from velora_engine import models


async def test_keyboard_route_is_bound_to_session_not_manual_model(engine, monkeypatch):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    original = eng.stt
    await client.send_json({"cmd": "start", "session": "keyboard-language", "context": {
        "keyboard_route": {"input_source": "test.source", "language": "hi", "model": original.model_id}}})
    route = await client.recv_event("session_route")
    assert route["language"] == "hi"
    assert eng.stt is original and eng.config.language != "hi"
    assert eng._session_stt(eng.session).language == "hi"
    eng.config.data["language"] = "fr"
    assert eng._session_config(eng.session).language == "hi"
    await client.send_json({"cmd": "cancel", "session": "keyboard-language"})
    await client.recv_event("cancelled")
    if eng._cancel_active_task is not None:
        await asyncio.shield(eng._cancel_active_task)
    assert original.language != "hi"


async def test_missing_keyboard_model_falls_back_without_acquisition(engine, monkeypatch):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    monkeypatch.setattr("velora_engine.models.cached_model_path", lambda _: None)
    await client.send_json({"cmd": "start", "session": "missing-route", "context": {
        "keyboard_route": {"input_source": "test.source", "language": "hi",
                           "model": "mlx-community/whisper-large-v3-mlx"}}})
    route = await client.recv_event("session_route")
    assert route["model"] == eng.stt.model_id
    assert route["fallback"] == "The keyboard's speech model is not installed. Using your selected model."
    assert eng.config.stt_model == eng.stt.model_id
    assert eng._keyboard_backend is None


async def test_save_memory_waits_for_continuous_idle(engine):
    eng, _ = engine
    calls = []

    class Cleanup:
        loaded = True
        async def hibernate(self):
            calls.append("hibernate")
            self.loaded = False
            return True

    old = eng.cleanup
    try:
        eng.cleanup = Cleanup()
        eng.config.data.update(memory_policy="save_memory", cleanup_idle_minutes=1)
        eng._clock = lambda: 10
        await eng._idle_memory_step()
        eng._clock = lambda: 69
        await eng._idle_memory_step()
        assert not calls
        eng._editing = True
        eng._clock = lambda: 100
        await eng._idle_memory_step()
        eng._editing = False
        await eng._idle_memory_step()
        eng._clock = lambda: 161
        await eng._idle_memory_step()
        assert calls == ["hibernate"]
        await eng._idle_memory_step()
        assert calls == ["hibernate"]
    finally:
        eng.cleanup = old


async def test_default_and_keep_ready_do_not_timed_unload(engine):
    eng, _ = engine
    assert eng.config.memory_policy == "automatic"
    eng.config.data.update(memory_policy="keep_ready", cleanup_idle_minutes=1)
    eng._idle_since = 0
    eng._clock = lambda: 10_000
    await eng._idle_memory_step()
    assert eng._idle_since is None


async def test_alternate_keyboard_backend_is_used_for_audio_and_released_from_session(engine, monkeypatch, tmp_path):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng.config.data["follow_keyboard_language"] = True
    manual = eng.stt
    selected = eng.config.stt_model
    target = "mlx-community/whisper-large-v3-mlx"
    monkeypatch.setattr(models, "cached_model_path", lambda _: str(tmp_path))
    await client.send_json({"cmd": "start", "session": "alternate", "context": {
        "keyboard_route": {"input_source": "test.source", "language": "es", "model": target}}})
    event = await client.recv_event("session_route")
    assert event["model"] == target and "fallback" not in event
    bound = eng._session_stt(eng.session)
    assert bound is eng._keyboard_backend and bound is not manual
    assert eng.stt is manual and eng.config.stt_model == selected
    await client.send_json({"cmd": "stop", "session": "alternate"})
    await client.recv_event("final")
    assert eng.stt is manual and eng.config.stt_model == selected
    assert manual.sessions == 0 and bound.sessions == 1


def test_installed_only_resolution_cannot_start_download(monkeypatch):
    monkeypatch.setattr(models, "_owned_cached", lambda _: None)
    monkeypatch.setattr(models, "_legacy_cached", lambda _: None)
    with models.installed_only():
        try:
            models.ensure_downloaded("missing/local-model")
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("a keyboard route may not acquire missing model files")


def test_invalid_memory_settings_retain_safe_defaults(config):
    config.data.update(memory_policy="unknown", cleanup_idle_minutes=float("nan"))
    assert config.memory_policy == "automatic" and config.cleanup_idle_minutes == 5
