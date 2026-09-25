"""Wire protocol framing (docs/ARCHITECTURE.md).

Frame = u32 length (LE) | u8 type | payload

`length` counts everything after the length prefix, i.e. the 1-byte type
plus the payload (length == 1 + len(payload)).

Types:
  0x01 JSON  — control, newline-free JSON object (UTF-8).
  0x02 AUDIO — raw PCM chunk: 16kHz mono Float32 LE.
"""

from __future__ import annotations

import asyncio
import json
import struct
from typing import Any

FRAME_JSON = 0x01
FRAME_AUDIO = 0x02

MAX_FRAME_LEN = 32 * 1024 * 1024  # 32 MiB safety cap

_HEADER = struct.Struct("<I")


class ProtocolError(Exception):
    """Unrecoverable framing error (stream desync)."""


def encode_frame(frame_type: int, payload: bytes) -> bytes:
    """Encode a frame: u32 LE length (type byte + payload) | u8 type | payload."""
    return _HEADER.pack(1 + len(payload)) + bytes([frame_type]) + payload


def encode_json(obj: dict[str, Any]) -> bytes:
    """Encode a control frame from a dict (newline-free JSON)."""
    payload = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return encode_frame(FRAME_JSON, payload)


async def read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    """Read one frame from an asyncio stream.

    Raises asyncio.IncompleteReadError on EOF, ProtocolError on bad length.
    """
    header = await reader.readexactly(4)
    (length,) = _HEADER.unpack(header)
    if length < 1 or length > MAX_FRAME_LEN:
        raise ProtocolError(f"invalid frame length {length}")
    body = await reader.readexactly(length)
    return body[0], body[1:]
