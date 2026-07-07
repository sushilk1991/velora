"""LLM cleanup via mlx-lm.

- Load once; the static system-prompt prefix is prompt-cached (common-prefix
  KV cache reuse, warmed at load time).
- Generation: temperature 0, max_tokens = max(96, int(input_tokens * 1.8)).
- Divergence guard: output/input length ratio outside [0.55, 1.6] or empty
  output → return raw (cleanup_applied False, reason logged).
- Hard timeout 1500ms: generation runs in a worker thread that checks its
  deadline per token; the async caller also enforces an outer bound. On
  breach, raw is returned.
"""

from __future__ import annotations

import asyncio
import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any

log = logging.getLogger("velora.cleanup")

TIMEOUT_MS = 1500
RATIO_MIN = 0.55
RATIO_MAX = 1.6
MIN_MAX_TOKENS = 96
OUTPUT_TOKEN_FACTOR = 1.8


def check_divergence(raw: str, output: str) -> str | None:
    """Anti-over-editing guard. Returns a rejection reason, or None if OK."""
    out = output.strip()
    if not out:
        return "empty_output"
    raw_len = max(1, len(raw.strip()))
    ratio = len(out) / raw_len
    if ratio < RATIO_MIN:
        return f"ratio_low({ratio:.2f})"
    if ratio > RATIO_MAX:
        return f"ratio_high({ratio:.2f})"
    return None


@dataclass
class CleanupResult:
    text: str
    applied: bool
    ms: int
    reason: str | None = None  # set when not applied


class CleanupEngine:
    """mlx-lm wrapper. All model access is serialized on one worker lock."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model: Any = None
        self._tokenizer: Any = None
        self._cache: list[Any] | None = None
        self._cache_tokens: list[int] = []
        self._lock = threading.Lock()
        # MLX streams are thread-affine: load and generation must all happen
        # on this one dedicated thread.
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cleanup")
        self.loaded = False

    async def load_async(self, warm_system_prompt: str | None = None) -> None:
        await asyncio.get_running_loop().run_in_executor(self._executor, self.load, warm_system_prompt)

    # ---- loading -------------------------------------------------------

    def load(self, warm_system_prompt: str | None = None) -> None:
        from mlx_lm import load

        from .models import ensure_downloaded

        t0 = time.perf_counter()
        # Local path, not repo id: a cached model must load without network.
        self._model, self._tokenizer = load(ensure_downloaded(self.model_id))
        log.info("cleanup LLM loaded %s in %.2fs", self.model_id, time.perf_counter() - t0)
        if warm_system_prompt:
            t0 = time.perf_counter()
            self._warm(warm_system_prompt)
            log.info("cleanup prompt cache warmed in %.2fs", time.perf_counter() - t0)
        self.loaded = True

    def _prompt_tokens(self, system_prompt: str, user_text: str) -> list[int]:
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text},
        ]
        try:
            return list(
                self._tokenizer.apply_chat_template(
                    messages, add_generation_prompt=True, enable_thinking=False
                )
            )
        except TypeError:  # tokenizer without enable_thinking support
            return list(self._tokenizer.apply_chat_template(messages, add_generation_prompt=True))

    def _warm(self, system_prompt: str) -> None:
        """Prefill the KV cache with the static system prefix.

        Uses a dummy request; subsequent real prompts share the static system
        prompt prefix, so their common prefix is served from cache.
        """
        with self._lock:
            self._generate_locked(system_prompt, "warm up", max_tokens=1, deadline=time.perf_counter() + 30)

    # ---- generation with common-prefix KV cache -------------------------

    def _generate_locked(self, system_prompt: str, user_text: str, max_tokens: int, deadline: float) -> tuple[str, bool]:
        """Returns (text, timed_out). Caller must hold self._lock."""
        from mlx_lm import stream_generate
        from mlx_lm.models import cache as kv
        from mlx_lm.sample_utils import make_sampler

        tokens = self._prompt_tokens(system_prompt, user_text)

        if self._cache is None:
            self._cache = kv.make_prompt_cache(self._model)
            self._cache_tokens = []

        # Reuse the longest common prefix already in the KV cache.
        common = 0
        limit = min(len(self._cache_tokens), len(tokens) - 1)  # always leave ≥1 token to process
        while common < limit and self._cache_tokens[common] == tokens[common]:
            common += 1
        to_trim = len(self._cache_tokens) - common
        if to_trim > 0:
            if kv.can_trim_prompt_cache(self._cache):
                kv.trim_prompt_cache(self._cache, to_trim)
                self._cache_tokens = self._cache_tokens[:common]
            else:  # pragma: no cover — KVCache is trimmable; safety net
                self._cache = kv.make_prompt_cache(self._model)
                self._cache_tokens = []
                common = 0

        suffix = tokens[common:]
        out_text: list[str] = []
        gen_tokens: list[int] = []
        timed_out = False
        sampler = make_sampler(temp=0.0)
        for resp in stream_generate(
            self._model,
            self._tokenizer,
            prompt=suffix,
            max_tokens=max_tokens,
            sampler=sampler,
            prompt_cache=self._cache,
        ):
            out_text.append(resp.text)
            gen_tokens.append(resp.token)
            if time.perf_counter() > deadline:
                timed_out = True
                break
        # KV cache now holds prompt + generated tokens (last sampled token is
        # not yet in the cache, but tracking a superset only costs a trim).
        self._cache_tokens = tokens + gen_tokens
        return "".join(out_text), timed_out

    def _run(self, raw: str, system_prompt: str, timeout_ms: int) -> CleanupResult:
        t0 = time.perf_counter()
        deadline = t0 + timeout_ms / 1000.0
        with self._lock:
            input_tokens = len(self._tokenizer.encode(raw))
            max_tokens = max(MIN_MAX_TOKENS, int(input_tokens * OUTPUT_TOKEN_FACTOR))
            text, timed_out = self._generate_locked(system_prompt, raw, max_tokens, deadline)
        ms = int((time.perf_counter() - t0) * 1000)
        if timed_out:
            log.warning("cleanup timeout after %dms — returning raw", ms)
            return CleanupResult(raw, False, ms, "timeout")
        reason = check_divergence(raw, text)
        if reason is not None:
            log.warning("cleanup divergence guard tripped (%s) — returning raw", reason)
            return CleanupResult(raw, False, ms, reason)
        return CleanupResult(text.strip(), True, ms)

    async def cleanup(self, raw: str, system_prompt: str, timeout_ms: int = TIMEOUT_MS) -> CleanupResult:
        """Clean `raw` under `system_prompt`. Never raises; returns raw on any failure."""
        if not self.loaded:
            return CleanupResult(raw, False, 0, "llm_not_loaded")
        try:
            # In-thread deadline enforces the budget between tokens; the outer
            # wait_for catches a truly wedged generation (thread keeps running,
            # the lock serializes any next request behind it).
            loop = asyncio.get_running_loop()
            return await asyncio.wait_for(
                loop.run_in_executor(self._executor, self._run, raw, system_prompt, timeout_ms),
                timeout=timeout_ms / 1000.0 + 3.0,
            )
        except asyncio.TimeoutError:
            log.error("cleanup hard-wedged past %dms — returning raw", timeout_ms)
            return CleanupResult(raw, False, timeout_ms, "timeout_hard")
        except Exception as exc:  # noqa: BLE001 — cleanup must never break dictation
            log.exception("cleanup failed")
            return CleanupResult(raw, False, 0, f"error:{exc}")
