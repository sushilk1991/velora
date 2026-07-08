"""LLM cleanup via mlx-lm.

- Load once; the static system-prompt prefix is prompt-cached (common-prefix
  KV cache reuse, warmed at load time).
- Generation: temperature 0, max_tokens = max(96, int(input_tokens * 1.8)).
- Divergence guard v2 (containment-based): cleanup may DELETE words (spoken
  self-corrections legitimately shrink the text a lot) but may never INVENT
  them — >15% novel output tokens → reject. Length is only a backstop: a
  hard 1.6x growth cap, plus a shrink floor that relaxes when the raw text
  contains a retraction marker ("no no", "scratch that", …). The old flat
  0.55 ratio floor vetoed exactly the self-corrections the model got right.
- Hard timeout 1500ms: generation runs in a worker thread that checks its
  deadline per token; the async caller also enforces an outer bound. On
  breach, raw is returned.
"""

from __future__ import annotations

import asyncio
import logging
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any

log = logging.getLogger("velora.cleanup")

TIMEOUT_MS = 1500  # base budget, for a short/normal sentence
TIMEOUT_CEILING_MS = 6000  # hard ceiling however long the dictation
MS_PER_WORD = 45  # generation grows ~linearly with length past the base
BASE_WORDS = 25  # words covered by the base budget before scaling kicks in
RATIO_MAX = 1.6
# Shrink floors (output/input length). Applying a self-correction deletes the
# retracted words AND the correction phrase, so when the raw text carries a
# retraction marker the output may legitimately be a small fraction of the
# input ("…scratch all of that just tell him i'll call back" → 5 words).
RATIO_FLOOR_DEFAULT = 0.35
RATIO_FLOOR_RETRACTION = 0.12
# Novel-token budget: cleanup output should be built from the input's words.
NOVEL_FRACTION_MAX = 0.15
MIN_MAX_TOKENS = 96
OUTPUT_TOKEN_FACTOR = 1.8

# Spoken retraction / self-repair markers. Deliberately NOT used to rewrite
# text (the owner's steer: semantics live in the LLM prompt, not regex) — the
# only thing a marker does is relax the guard's shrink floor so the model's
# correct, much-shorter output isn't vetoed.
_RETRACTION_RE = re.compile(
    r"\b(?:no+[,.]? no+|no,? wait|wait,? no|actually|scratch (?:that|all)|"
    r"delete (?:that|this)|i meant?|correction|forget (?:that|it)|"
    r"let me rephrase|start over)\b",
    re.IGNORECASE,
)


def adaptive_timeout_ms(raw: str, base: int = TIMEOUT_MS) -> int:
    """Scale the cleanup budget with input length.

    A fixed 1500ms silently dropped long paragraphs to raw (uncleaned) text —
    measured cleanup is ~0.5s for a sentence but ~0.75s already at 37 words and
    climbs from there. Give longer dictation proportionally more headroom, up to
    a ceiling so a truly wedged generation still bails."""
    words = len(raw.split())
    extra = max(0, words - BASE_WORDS) * MS_PER_WORD
    return min(base + extra, TIMEOUT_CEILING_MS)


def _guard_tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def check_divergence(raw: str, output: str) -> str | None:
    """Anti-over-editing guard v2. Returns a rejection reason, or None if OK.

    Containment first: every output token should come from the input (cleanup
    deletes and re-punctuates; it never writes new words). Merges of up to
    three adjacent input tokens are allowed ("6 p m" → "6pm", "auth check" →
    "authCheck"), and small outputs get slack (≥2 novel tokens required). The
    length ratio is only a backstop — growth capped hard, shrinkage floored
    loosely, and floored barely at all when the raw text contains a spoken
    retraction ("no no", "scratch that"): deleting the retracted words is the
    correct behavior, and the old flat floor was throwing those results away.
    """
    out = output.strip()
    if not out:
        return "empty_output"
    raw_len = max(1, len(raw.strip()))
    ratio = len(out) / raw_len
    if ratio > RATIO_MAX:
        return f"ratio_high({ratio:.2f})"
    raw_tokens = _guard_tokens(raw)
    out_tokens = _guard_tokens(out)
    if raw_tokens and out_tokens:
        allowed = set(raw_tokens)
        for n in (2, 3):
            for i in range(len(raw_tokens) - n + 1):
                allowed.add("".join(raw_tokens[i : i + n]))
        novel = [t for t in out_tokens if t not in allowed]
        if len(novel) >= 2 and len(novel) / len(out_tokens) > NOVEL_FRACTION_MAX:
            return f"novel_content({len(novel)}/{len(out_tokens)})"
    floor = RATIO_FLOOR_RETRACTION if _RETRACTION_RE.search(raw) else RATIO_FLOOR_DEFAULT
    if ratio < floor:
        return f"ratio_low({ratio:.2f})"
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

    def close(self) -> None:
        """Retire this engine before dropping the reference to it. Marks it
        unloaded (so no new cleanup starts) and shuts the worker thread once any
        in-flight generation finishes. Deliberately does NOT null the model
        fields — a generation may still be reading them under the lock, and MLX
        objects are freed by GC when the last reference goes anyway."""
        self.loaded = False
        # wait=False: don't block the event loop; the thread exits after its
        # current task. The model is released when this object is GC'd.
        self._executor.shutdown(wait=False)

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

    def _run(self, raw: str, system_prompt: str, timeout_ms: int, check_ratio: bool = True) -> CleanupResult:
        t0 = time.perf_counter()
        deadline = t0 + timeout_ms / 1000.0
        with self._lock:
            input_tokens = len(self._tokenizer.encode(raw))
            # Romanization (check_ratio off) expands length, so give the
            # generator more headroom than the usual 1.8x cleanup budget.
            factor = OUTPUT_TOKEN_FACTOR if check_ratio else 3.0
            max_tokens = max(MIN_MAX_TOKENS, int(input_tokens * factor))
            text, timed_out = self._generate_locked(system_prompt, raw, max_tokens, deadline)
        ms = int((time.perf_counter() - t0) * 1000)
        if timed_out:
            log.warning("cleanup timeout after %dms — returning raw", ms)
            return CleanupResult(raw, False, ms, "timeout")
        # The divergence guard is a length-ratio over-editing check; a script
        # transliteration legitimately changes length, so skip it when romanizing.
        if check_ratio:
            reason = check_divergence(raw, text)
            if reason is not None:
                log.warning("cleanup divergence guard tripped (%s) — returning raw", reason)
                return CleanupResult(raw, False, ms, reason)
        elif not text.strip():
            return CleanupResult(raw, False, ms, "empty_output")
        return CleanupResult(text.strip(), True, ms)

    async def cleanup(
        self, raw: str, system_prompt: str, timeout_ms: int | None = None, check_ratio: bool = True
    ) -> CleanupResult:
        """Clean `raw` under `system_prompt`. Never raises; returns raw on any failure.

        `timeout_ms` defaults to a length-adaptive budget (see
        `adaptive_timeout_ms`); pass an explicit value to override."""
        if timeout_ms is None:
            timeout_ms = adaptive_timeout_ms(raw)
        if not self.loaded:
            return CleanupResult(raw, False, 0, "llm_not_loaded")
        try:
            # In-thread deadline enforces the budget between tokens; the outer
            # wait_for catches a truly wedged generation (thread keeps running,
            # the lock serializes any next request behind it).
            loop = asyncio.get_running_loop()
            return await asyncio.wait_for(
                loop.run_in_executor(self._executor, self._run, raw, system_prompt, timeout_ms, check_ratio),
                timeout=timeout_ms / 1000.0 + 3.0,
            )
        except asyncio.TimeoutError:
            log.error("cleanup hard-wedged past %dms — returning raw", timeout_ms)
            return CleanupResult(raw, False, timeout_ms, "timeout_hard")
        except Exception as exc:  # noqa: BLE001 — cleanup must never break dictation
            log.exception("cleanup failed")
            return CleanupResult(raw, False, 0, f"error:{exc}")
