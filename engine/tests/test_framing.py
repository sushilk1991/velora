"""Framing codec roundtrip tests."""

import asyncio
import struct

import pytest

from velora_engine import protocol


def test_length_counts_type_byte():
    """Wire format: u32 length covers the type byte plus payload."""
    frame = protocol.encode_frame(protocol.FRAME_AUDIO, b"\x00" * 8)
    (length,) = struct.unpack("<I", frame[:4])
    assert length == 9
    assert frame[4] == protocol.FRAME_AUDIO
    assert len(frame) == 4 + 9


async def test_async_read_frame_roundtrip():
    reader = asyncio.StreamReader()
    reader.feed_data(protocol.encode_json({"event": "ready"}))
    reader.feed_data(protocol.encode_frame(protocol.FRAME_AUDIO, b"\x01\x02\x03\x04"))
    reader.feed_eof()
    t1, p1 = await protocol.read_frame(reader)
    assert (t1, p1) == (protocol.FRAME_JSON, b'{"event":"ready"}')
    t2, p2 = await protocol.read_frame(reader)
    assert (t2, p2) == (protocol.FRAME_AUDIO, b"\x01\x02\x03\x04")
    with pytest.raises(asyncio.IncompleteReadError):
        await protocol.read_frame(reader)


async def test_async_read_frame_bad_length():
    reader = asyncio.StreamReader()
    reader.feed_data(struct.pack("<I", 0) + b"junk")
    with pytest.raises(protocol.ProtocolError):
        await protocol.read_frame(reader)

    oversized = asyncio.StreamReader()
    oversized.feed_data(struct.pack("<I", protocol.MAX_FRAME_LEN + 1) + b"\x01")
    with pytest.raises(protocol.ProtocolError):
        await protocol.read_frame(oversized)
