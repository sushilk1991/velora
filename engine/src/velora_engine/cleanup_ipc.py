"""Finite newline-delimited protocol shared by the cleanup parent and child."""

from __future__ import annotations

import json
from typing import Any


# asyncio's default StreamReader ceiling is 64 KiB. A bounded 500-node
# Accessibility snapshot can legitimately exceed that. Four MiB leaves
# headroom for the worst-case normalized tree after UTF-8/JSON encoding; the
# common system prompt in prefix-cache candidates is transmitted only once.
CLEANUP_IPC_STREAM_LIMIT_BYTES = 4 * 1024 * 1024


def encode_cleanup_ipc_message(message: dict[str, Any]) -> bytes:
    """Encode one finite line, rejecting oversize messages before socket I/O."""
    encoded = (
        json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if len(encoded) > CLEANUP_IPC_STREAM_LIMIT_BYTES:
        raise ValueError(
            "cleanup IPC message exceeds "
            f"{CLEANUP_IPC_STREAM_LIMIT_BYTES} byte limit"
        )
    return encoded


def pack_prefix_candidates(
    system_prompt: str,
    candidates: list[tuple[str, str]] | None,
) -> tuple[list[tuple[str, str]] | None, list[str] | None]:
    """Avoid repeating a large common system prompt in one wire message."""
    if candidates and all(prompt == system_prompt for prompt, _ in candidates):
        return None, [prefix for _, prefix in candidates]
    return candidates, None


def unpack_prefix_candidates(
    system_prompt: str,
    candidates: object,
    shared_prompt_prefixes: object,
) -> list[tuple[str, str]]:
    """Restore the model API's `(system prompt, prefix)` candidate shape."""
    if isinstance(shared_prompt_prefixes, list):
        return [
            (system_prompt, prefix)
            for prefix in shared_prompt_prefixes
            if isinstance(prefix, str)
        ]
    return [
        (str(item[0]), str(item[1]))
        for item in (candidates or [])
        if isinstance(item, (list, tuple)) and len(item) == 2
    ]
