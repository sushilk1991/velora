"""Text previews use the dictation formatter, without audio or live delivery."""

import asyncio

import numpy as np

from test_server import connect, engine  # noqa: F401
from velora_engine import text_formatting


async def test_format_text_raw_round_trip_without_audio(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({
        "cmd": "format_text", "request_id": "raw-preview", "text": "um hello there",
        "mode": "Raw",
    })
    result = await client.recv_event("text_formatted")
    assert result["request_id"] == "raw-preview"
    assert result["raw"] == "um hello there"
    assert result["text"] == "um hello there"
    assert result["mode"] == "Raw"
    assert result["cleanup_applied"] is False
    assert eng.session is None
    assert not eng._reprocessing


async def test_inline_preview_does_not_replace_live_modes(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    modes = dict(eng.config.modes)
    await client.send_json({
        "cmd": "format_text", "request_id": "inline", "text": "hello work",
        "inline_mode": {"name": "Unsaved preview", "formatting": "off",
                        "replacements": {"work": "Velora"}},
    })
    result = await client.recv_event("text_formatted")
    assert result["mode"] == "Unsaved preview"
    assert result["text"] == "hello Velora"
    assert eng.config.modes == modes
    assert eng.config.mode_by_name("Unsaved preview") is None


async def test_text_preview_validation_has_request_identity(engine):
    _, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    for payload in (
        {"text": ""},
        {"text": "hello", "mode": "missing-mode"},
        {"text": "hello", "inline_mode": {"name": "x", "formatting": "unknown"}},
        {"text": "hello", "inline_mode": {"name": "x", "replacements": []}},
    ):
        await client.send_json({"cmd": "format_text", "request_id": "invalid", **payload})
        error = await client.recv_event("text_format_failed")
        assert error["request_id"] == "invalid"
        assert error["code"] == "invalid_arguments"


async def test_text_preview_refuses_foreground_jobs(engine):
    eng, sock = engine
    client = await connect(sock)
    await client.recv_event("ready")
    eng._editing = True
    try:
        await client.send_json({"cmd": "format_text", "request_id": "busy", "text": "hello"})
        result = await client.recv_event("text_format_failed")
        assert result["code"] == "busy"
        assert result["request_id"] == "busy"
    finally:
        eng._editing = False


async def test_text_preview_cancel_is_correlated_and_keeps_reader_live(engine):
    eng, sock = engine
    started = asyncio.Event()

    async def formatting(raw, **kwargs):
        started.set()
        while not kwargs["cancel_event"].is_set():
            await asyncio.sleep(0.01)
        return raw, "Default", 0, False, "cancelled"

    eng._apply_formatting = formatting
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "format_text", "request_id": "cancel-me", "text": "hello"})
    await asyncio.wait_for(started.wait(), 1)
    await client.send_json({"cmd": "format_text_cancel", "request_id": "older-request"})
    await client.send_json({"cmd": "ping"})
    await client.recv_event("pong")
    assert not eng._edit_cancel.is_set()
    await client.send_json({"cmd": "format_text_cancel", "request_id": "cancel-me"})
    result = await client.recv_event("text_format_failed")
    assert result["request_id"] == "cancel-me"
    assert result["code"] == "cancelled"
    assert eng._editing is False


def test_preview_snapshot_and_size_guards(home):
    from velora_engine.config import Config

    config = Config(home)
    config.data["language"] = "en"
    _, snapshot, _ = text_formatting.preview_input(
        {"request_id": "snapshot", "text": "hello", "mode": "Raw"}, config)
    config.data["language"] = "hi"
    assert snapshot.language == "en"
    assert snapshot.data is not config.data
    try:
        text_formatting.preview_input({"request_id": "large", "text": "x" * 60_001}, config)
    except ValueError as error:
        assert "60,000" in str(error)
    else:
        raise AssertionError("oversized source was accepted")


async def test_display_only_preview_does_not_request_stream_insertion(engine):
    eng, sock = engine
    eng.stt.preview_enabled = False
    client = await connect(sock)
    await client.recv_event("ready")
    await client.send_json({"cmd": "start", "session": "display-only",
                            "context": {"preview_only": True}})
    for _ in range(100):
        if eng.session is not None:
            break
        await asyncio.sleep(0.01)
    assert eng.session is not None
    assert eng.session._partials_enabled is True
    assert eng.stt.preview_enabled is True
    assert eng.session.context.get("stream_typing") is not True
    await client.send_audio(np.zeros(1_600, dtype=np.float32))
    await client.send_json({"cmd": "cancel", "session": "display-only"})
    await client.recv_event("cancelled")
    assert eng.stt.preview_enabled is False
