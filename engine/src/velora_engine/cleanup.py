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
- The adaptive soft deadline starts at the first output token, so prompt
  tokenization/prefill cannot consume the generation budget. A separate outer
  watchdog still bounds wedged prefill or generation. On breach, raw is
  returned.
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
HARD_TIMEOUT_GRACE_S = 3.0  # independent TTFT/prefill wedge allowance
# A cancelled preview/streaming generation can remain inside native prefill
# until MLX yields. Final cleanup must not spend its own generation budget
# merely waiting to enter the single thread. Bound that wait separately, then
# replace the sidecar because its only model worker is unavailable.
QUEUE_TIMEOUT_S = 1.0
MS_PER_WORD = 45  # generation grows ~linearly with length past the base
BASE_WORDS = 25  # words covered by the base budget before scaling kicks in
RATIO_MAX = 1.6
# Shrink floors (output/input length). Applying a self-correction deletes the
# retracted words AND the correction phrase, so when the raw text carries a
# retraction marker the output may legitimately be a small fraction of the
# input ("…scratch all of that just tell him i'll call back" → 5 words).
RATIO_FLOOR_DEFAULT = 0.35
RATIO_FLOOR_RETRACTION = 0.12
# Novel-token budget: cleanup output should be built from the input's words or
# conservative grammatical forms of those words. Real hallucination (answering,
# greeting, summarizing) introduces MANY unrelated tokens. Require both a count
# and a fraction so a small legitimate fix never trips.
NOVEL_FRACTION_MAX = 0.20
NOVEL_MIN_TOKENS = 3
MIN_MAX_TOKENS = 96
OUTPUT_TOKEN_FACTOR = 1.8

# Spoken retraction / self-repair markers. Deliberately NOT used to rewrite
# text (the owner's steer: semantics live in the LLM prompt, not regex) — the
# only thing a marker does is relax the guard's shrink floor so the model's
# correct, much-shorter output isn't vetoed. Only UNAMBIGUOUS forms belong
# here: bare "actually" / "I mean" are everyday fillers, and listing them
# would switch the over-deletion backstop off for a huge share of normal
# dictation (review finding) — they only count when paired with "no".
_RETRACTION_RE = re.compile(
    r"\b(?:no+[,.]? no+|no,? wait|wait,? no|actually,? no|no,? actually|"
    r"scratch (?:that|all)|strike (?:that|all)|delete (?:that|this)|"
    r"correction|forget (?:that|it)|let me rephrase|start over)\b",
    re.IGNORECASE,
)

# Spoken number → digit equivalences for the containment check: the model
# legitimately writes "3:30" for "three thirty" and "5th" for "fifth"; those
# digit tokens must not count as hallucinated. Tens+units compositions
# ("twenty five" → "25") are added pairwise from adjacent raw tokens.
_NUMBER_WORDS: dict[str, tuple[str, ...]] = {
    "zero": ("0",), "one": ("1",), "two": ("2",), "three": ("3",), "four": ("4",),
    "five": ("5",), "six": ("6",), "seven": ("7",), "eight": ("8",), "nine": ("9",),
    "ten": ("10",), "eleven": ("11",), "twelve": ("12",), "thirteen": ("13",),
    "fourteen": ("14",), "fifteen": ("15",), "sixteen": ("16",), "seventeen": ("17",),
    "eighteen": ("18",), "nineteen": ("19",), "twenty": ("20",), "thirty": ("30",),
    "forty": ("40",), "fifty": ("50",), "sixty": ("60",), "seventy": ("70",),
    "eighty": ("80",), "ninety": ("90",), "hundred": ("100",), "thousand": ("1000",),
    "first": ("1st", "1"), "second": ("2nd", "2"), "third": ("3rd", "3"),
    "fourth": ("4th", "4"), "fifth": ("5th", "5"), "sixth": ("6th", "6"),
    "seventh": ("7th", "7"), "eighth": ("8th", "8"), "ninth": ("9th", "9"),
    "tenth": ("10th", "10"), "eleventh": ("11th", "11"), "twelfth": ("12th", "12"),
}
_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
         "seventy": 70, "eighty": 80, "ninety": 90}
_UNITS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
          "seven": 7, "eight": 8, "nine": 9}

# Only present-agreement auxiliary changes are containment-equivalent. Past,
# participle, and progressive forms are intentionally absent: admitting them
# let a cleanup silently change the tense of an otherwise valid sentence.
_PRESENT_AUXILIARY_FORMS = {
    "be": frozenset({"am", "is", "are"}),
    "am": frozenset({"be", "is", "are"}),
    "is": frozenset({"be", "am", "are"}),
    "are": frozenset({"be", "am", "is"}),
    "have": frozenset({"has"}),
    "has": frozenset({"have"}),
    "do": frozenset({"does"}),
    "does": frozenset({"do"}),
}


_CONTROL_TOKEN_RE = re.compile(r"<\|(?=[A-Za-z])")


def neutralize_control_tokens(text: str) -> str:
    """Defang chat-template control markers embedded in user content.

    HF tokenizers recognize special tokens like ``<|im_start|>`` even inside
    message content, so a selection (or dictation) containing a literal
    ``<|im_start|>system…`` sequence would tokenize into a real, attacker
    controlled conversation turn. Inserting a zero-width space after the bar
    breaks the exact-string match the tokenizer needs, while staying visually
    identical if it ever round-trips back to the user. Applies to every path
    into the model; whisper output never contains these, so dictation is a
    no-op — the exposure is arbitrary on-screen text via Safe Voice Edit."""
    return _CONTROL_TOKEN_RE.sub("<​|", text)


def restore_control_tokens(text: str) -> str:
    """Reverse :func:`neutralize_control_tokens` on model OUTPUT.

    A model that preserves its input verbatim (e.g. Safe Voice Edit reformats
    source containing a literal ``<|im_start|>``) would otherwise return the
    text with the injected zero-width space still in it, silently corrupting
    the source. Stripping the exact marker the neutralizer inserts restores a
    clean round-trip; it can only remove a ZWSP that sits between ``<`` and
    ``|word``, which no legitimate output places there."""
    return text.replace("<​|", "<|")


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


# Line-leading "1." / "2)" markers (the model's output carries breaks as the
# ⏎ marker, so "after a break" counts as line-leading too). When the speech
# asks for a numbered list these are formatting, not novel content — counting
# them vetoed every numbered list the user explicitly requested. Inline
# numbers elsewhere still count, and so do line-leading numbers that don't
# form a 1-anchored sequence (review finding: "42. … 99. …" must not smuggle
# invented values past the guard dressed as markers).
_LIST_MARKER_RE = re.compile(r"(?:(?m:^)|(?<=⏎))\s*(\d{1,2})[.)]\s+")


def _strip_list_markers(text: str) -> str:
    prev = 0

    def repl(m: "re.Match[str]") -> str:
        nonlocal prev
        value = int(m.group(1))
        if value == 1 or value == prev + 1:  # new list or the next item
            prev = value
            return " "
        return m.group(0)

    return _LIST_MARKER_RE.sub(repl, text)


def _grammatical_variants(token: str) -> set[str]:
    """Conservative output forms that preserve one raw token's identity.

    This is deliberately one-way from the raw transcript to the cleanup: it
    admits ordinary plural/agreement suffixes plus the present auxiliary forms
    above. It does not admit tense/aspect changes, stem arbitrary output words,
    or loosen the unrelated-novel-token budget.
    """
    variants = set(_PRESENT_AUXILIARY_FORMS.get(token, ()))
    if token in _PRESENT_AUXILIARY_FORMS:
        return variants
    if len(token) < 3 or not token.isalpha():
        return variants

    if token.endswith("y") and token[-2] not in "aeiou":
        variants.add(token[:-1] + "ies")
    elif token.endswith(("s", "x", "z", "ch", "sh", "o")):
        variants.add(token + "es")
    else:
        variants.add(token + "s")
    return variants


def check_divergence(raw: str, output: str, allowed_terms: list[str] | None = None) -> str | None:
    """Anti-over-editing guard v2. Returns a rejection reason, or None if OK.

    Containment first: every output token should come from the input or be a
    conservative grammatical form of one input token. Merges of up to three
    adjacent input tokens are allowed ("6 p m" → "6pm", "auth check" →
    "authCheck"), and small outputs get slack (≥3 novel tokens required). The
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
    out_tokens = _guard_tokens(_strip_list_markers(out))
    if raw_tokens and out_tokens:
        allowed = set(raw_tokens)
        raw_token_set = set(raw_tokens)
        grammatical_variants: set[str] = set()
        # Vocabulary/learned terms are legitimate spellings the model is TOLD
        # to produce ("whisper flow" → "Wispr Flow", a learned soft correction
        # to "Airlearn") — but only as SUBSTITUTIONS for words that left the
        # text. An unconditional allowlist would wave through an output
        # sprinkled with unrelated vocab terms (review finding), so vocab
        # tokens are budgeted against the count of raw words that disappeared.
        # (If the model over-applies a soft hint to a genuine word, this bounds
        # the damage to a 1:1 swap — the residual risk of context-gating being
        # the LLM's call; the keep-by-default prompt is the first defense.)
        vocab_tokens: set[str] = set()
        for term in allowed_terms or []:
            vocab_tokens.update(_guard_tokens(term))
        vocab_tokens -= allowed
        if vocab_tokens:
            out_set = set(out_tokens)
            removed = sum(1 for t in set(raw_tokens) if t not in out_set)
            vocab_novel = [t for t in set(out_tokens) if t in vocab_tokens]
            if len(vocab_novel) > removed + 1:
                return f"vocab_injection({len(vocab_novel)}>{removed})"
            allowed |= vocab_tokens
        for n in (2, 3):
            for i in range(len(raw_tokens) - n + 1):
                allowed.add("".join(raw_tokens[i : i + n]))
        for i, tok in enumerate(raw_tokens):
            variants = _grammatical_variants(tok)
            grammatical_variants.update(variants)
            allowed.update(variants)
            for digits in _NUMBER_WORDS.get(tok, ()):
                allowed.add(digits)
            # "twenty five" → "25" (and "25th" via the ordinal unit form)
            if tok in _TENS and i + 1 < len(raw_tokens):
                nxt = raw_tokens[i + 1]
                if nxt in _UNITS:
                    allowed.add(str(_TENS[tok] + _UNITS[nxt]))
                for digits in _NUMBER_WORDS.get(nxt, ()):
                    if digits.endswith(("st", "nd", "rd", "th")):
                        allowed.add(str(_TENS[tok] + int(digits[:-2])) + digits[-2:])
        novel = [t for t in out_tokens if t not in allowed]
        # An all-inflection result is the exact grammar-repair case this guard
        # permits. Once unrelated output appears, however, count the inflected
        # substitutions too: otherwise a couple of allowed plurals can hide a
        # sentence-wide tense rewrite under the two-token novelty slack.
        changed = novel
        if novel:
            inflected = [
                t for t in out_tokens
                if t not in raw_token_set and t in grammatical_variants
            ]
            changed = novel + inflected
        if (
            len(changed) >= NOVEL_MIN_TOKENS
            and len(changed) / len(out_tokens) > NOVEL_FRACTION_MAX
        ):
            return f"novel_content({len(changed)}/{len(out_tokens)})"
    # KNOWN RESIDUAL (accepted): an answer assembled purely from input words
    # ("should we ship friday or monday" → "we should ship friday") passes
    # containment — no length/token guard can tell that from transcription.
    # The defense is prompt rule 1 (TRANSCRIBE, don't answer) at temperature 0;
    # this guard exists to catch the loud failure modes, not to be an oracle.
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
    ttft_ms: int = 0
    decode_ms: int = 0
    prefix_tokens: int = 0
    output_tokens: int = 0
    cache_hit: bool = False


@dataclass(frozen=True)
class _GenerationResult:
    text: str
    status: str
    ttft_ms: int
    decode_ms: int
    prefix_tokens: int
    output_tokens: int
    cache_hit: bool


@dataclass(frozen=True)
class PrefixPreparation:
    applied: bool
    tokens: int
    ms: int
    reason: str | None = None


def _copy_cache_containers(value: Any) -> Any:
    """Copy cache state containers while sharing immutable MLX arrays.

    Cache objects mutate their surrounding lists/metadata during generation.
    MLX arrays themselves are value objects and are intentionally shared; a
    restored KV cache allocates before extending the exact-length snapshot.
    """
    if isinstance(value, list):
        return [_copy_cache_containers(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_copy_cache_containers(item) for item in value)
    if isinstance(value, dict):
        return {key: _copy_cache_containers(item) for key, item in value.items()}
    return value


def _snapshot_prompt_cache(cache: list[Any]) -> list[tuple[type[Any], Any, Any]]:
    return [
        (
            type(item),
            _copy_cache_containers(item.state),
            _copy_cache_containers(item.meta_state),
        )
        for item in cache
    ]


def _restore_prompt_cache(
    snapshot: list[tuple[type[Any], Any, Any]],
) -> list[Any]:
    return [
        cache_type.from_state(
            _copy_cache_containers(state),
            _copy_cache_containers(meta_state),
        )
        for cache_type, state, meta_state in snapshot
    ]


def _longest_common_tokens(sequences: list[list[int]]) -> list[int]:
    if not sequences:
        return []
    common = list(sequences[0])
    for sequence in sequences[1:]:
        limit = min(len(common), len(sequence))
        index = 0
        while index < limit and common[index] == sequence[index]:
            index += 1
        common = common[:index]
        if not common:
            break
    # A future generation must always have at least one uncached token to feed
    # to MLX. Different candidate suffixes normally guarantee this; retain the
    # defensive bound for malformed/equal candidate sets.
    shortest = min(len(sequence) for sequence in sequences)
    if len(common) >= shortest and common:
        common = common[:-1]
    return common


class _PrefixCancelled(Exception):
    pass


class CleanupEngine:
    """mlx-lm wrapper. All model access is serialized on one worker lock."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model: Any = None
        self._tokenizer: Any = None
        # Immutable session prefix snapshot. Each generation receives a fresh
        # cache object restored from it, so a preview/chunk generation cannot
        # consume or pollute the final-cleanup speedup.
        self._prepared_tokens: list[int] = []
        self._prepared_cache: list[tuple[type[Any], Any, Any]] | None = None
        self._lock = threading.Lock()
        # MLX streams are thread-affine: load and generation must all happen
        # on this one dedicated thread.
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cleanup")
        self.loaded = False
        # A Python worker thread cannot be killed safely. If the independent
        # watchdog fires, retire this engine rather than queue every later
        # dictation behind a possibly permanent MLX wedge. The server sends the
        # raw fallback, then restarts the sidecar to obtain a fresh worker.
        self.unhealthy = False

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
        self.unhealthy = False

    def _prompt_tokens(self, system_prompt: str, user_text: str) -> list[int]:
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": neutralize_control_tokens(user_text)},
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

        Runtime prompts append mode/strength/context inside the SAME system
        message. Warming a completed static-only system message caches its
        closing chat-template token, which cannot prefix that extended prompt
        and causes a full TTFT cache miss. Two deliberately different SYSTEM
        suffixes identify only the exact shared static content (plus whatever
        delimiter tokenization is common). Unlike a dummy generation, this
        leaves no sampled token in the reusable snapshot.
        """
        self._prepare_prefix([
            (system_prompt + "\n\nalpha", "transcript"),
            (system_prompt + "\n\nzulu", "transcript"),
        ])

    def _make_prompt_cache(self) -> list[Any]:
        from mlx_lm.models import cache as kv

        return kv.make_prompt_cache(self._model)

    def _prefill_tokens_locked(
        self,
        tokens: list[int],
        cancel_event: threading.Event | None = None,
    ) -> list[Any]:
        """Process exactly `tokens` into a new cache, generating no token."""
        import mlx.core as mx
        from mlx_lm.generate import generate_step

        cache = self._make_prompt_cache()

        def progress(_processed: int, _total: int) -> None:
            if cancel_event is not None and cancel_event.is_set():
                raise _PrefixCancelled

        # max_tokens=0 runs the prompt model call but stops before feeding a
        # sampled token back into the model. Small steps make cancellation
        # observable between prefill batches without changing logits.
        for _ in generate_step(
            mx.array(tokens),
            self._model,
            max_tokens=0,
            prompt_cache=cache,
            prefill_step_size=256,
            prompt_progress_callback=progress,
        ):
            pass
        mx.eval([item.state for item in cache])
        return cache

    def _prepare_prefix(
        self,
        candidates: list[tuple[str, str]],
        cancel_event: threading.Event | None = None,
    ) -> PrefixPreparation:
        t0 = time.perf_counter()
        try:
            with self._lock:
                if cancel_event is not None and cancel_event.is_set():
                    raise _PrefixCancelled
                sequences = [self._prompt_tokens(system, user) for system, user in candidates]
                prefix = _longest_common_tokens(sequences)
                if not prefix:
                    self._prepared_tokens = []
                    self._prepared_cache = None
                    return PrefixPreparation(False, 0, int((time.perf_counter() - t0) * 1000), "no_prefix")
                cache = self._prefill_tokens_locked(prefix, cancel_event)
                self._prepared_tokens = prefix
                self._prepared_cache = _snapshot_prompt_cache(cache)
            ms = int((time.perf_counter() - t0) * 1000)
            log.info("cleanup prefix prepared tokens=%d prefill_ms=%d", len(prefix), ms)
            return PrefixPreparation(True, len(prefix), ms)
        except _PrefixCancelled:
            # The in-progress cache is local until the successful assignment
            # above. Preserve the last completed snapshot: exact-token matching
            # makes it safe, and the authoritative cleanup can still reuse its
            # static prefix instead of paying full TTFT after preemption.
            ms = int((time.perf_counter() - t0) * 1000)
            log.info("cleanup prefix preparation cancelled after %dms", ms)
            return PrefixPreparation(False, 0, ms, "cancelled")
        except Exception as exc:  # noqa: BLE001 — preparation is an optimization
            self._prepared_tokens = []
            self._prepared_cache = None
            ms = int((time.perf_counter() - t0) * 1000)
            log.exception("cleanup prefix preparation failed")
            return PrefixPreparation(False, 0, ms, f"error:{exc}")

    async def prepare_prefix(
        self,
        candidates: list[tuple[str, str]],
        cancel_event: threading.Event | None = None,
    ) -> PrefixPreparation:
        """Prepare a reusable exact prompt prefix on the model's owner thread."""
        if self.unhealthy:
            return PrefixPreparation(False, 0, 0, "llm_unhealthy")
        if not self.loaded:
            return PrefixPreparation(False, 0, 0, "llm_not_loaded")
        return await asyncio.get_running_loop().run_in_executor(
            self._executor, self._prepare_prefix, candidates, cancel_event
        )

    def _cache_for_tokens(self, tokens: list[int]) -> tuple[list[Any], int, bool]:
        prepared = self._prepared_tokens
        if (
            self._prepared_cache is not None
            and len(tokens) > len(prepared)
            and tokens[: len(prepared)] == prepared
        ):
            return _restore_prompt_cache(self._prepared_cache), len(prepared), True
        return self._make_prompt_cache(), 0, False

    # ---- generation with common-prefix KV cache -------------------------

    def _generate_locked(
        self,
        system_prompt: str,
        user_text: str,
        max_tokens: int,
        output_timeout_s: float,
        cancel_event: threading.Event | None = None,
    ) -> _GenerationResult:
        """Generate with a quality budget that begins at first output token."""
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler

        started = time.perf_counter()
        if cancel_event is not None and cancel_event.is_set():
            return _GenerationResult("", "cancelled", 0, 0, 0, 0, False)
        tokens = self._prompt_tokens(system_prompt, user_text)
        cache, common, cache_hit = self._cache_for_tokens(tokens)

        suffix = tokens[common:]
        out_text: list[str] = []
        gen_tokens: list[int] = []
        first_token_at: float | None = None
        status = "ok"
        sampler = make_sampler(temp=0.0)
        for resp in stream_generate(
            self._model,
            self._tokenizer,
            prompt=suffix,
            max_tokens=max_tokens,
            sampler=sampler,
            prompt_cache=cache,
        ):
            now = time.perf_counter()
            if cancel_event is not None and cancel_event.is_set():
                status = "cancelled"
                break
            if first_token_at is None:
                first_token_at = now
            out_text.append(resp.text)
            generation_tokens = getattr(resp, "generation_tokens", None)
            if generation_tokens is None:
                gen_tokens.append(resp.token)
            elif generation_tokens > len(gen_tokens):
                gen_tokens.extend([resp.token] * (generation_tokens - len(gen_tokens)))
            # Prompt prefill/TTFT is deliberately outside the soft quality
            # budget. Once output begins, however, slow or runaway decoding is
            # still bounded between tokens.
            if now - first_token_at > output_timeout_s:
                status = "timeout"
                break
        # Hitting the token ceiling means the output was CUT OFF mid-thought.
        # For dictation the divergence guard catches the too-short result, but
        # a transformation path (check_ratio off) has no such net — flag it so
        # a truncated edit is never pasted as a success.
        if status == "ok" and len(gen_tokens) >= max_tokens:
            status = "length"
        # The working cache is intentionally neither reused nor retained:
        # Qwen's hybrid cache contains non-trimmable recurrent state. Keeping
        # it here would duplicate the prepared prefix's MLX state until the
        # next request. The immutable snapshot is the only cross-request cache.
        log.debug(
            "cleanup cache prepared_hit=%s prefix_tokens=%d input_tokens=%d output_tokens=%d",
            cache_hit,
            common,
            len(tokens),
            len(gen_tokens),
        )
        finished = time.perf_counter()
        ttft_ms = int(((first_token_at or finished) - started) * 1000)
        decode_ms = int((finished - first_token_at) * 1000) if first_token_at else 0
        return _GenerationResult(
            "".join(out_text),
            status,
            ttft_ms,
            decode_ms,
            common,
            len(gen_tokens),
            cache_hit,
        )

    def _run(
        self,
        raw: str,
        system_prompt: str,
        timeout_ms: int,
        check_ratio: bool = True,
        cancel_event: threading.Event | None = None,
        allowed_terms: list[str] | None = None,
    ) -> CleanupResult:
        t0 = time.perf_counter()
        with self._lock:
            input_tokens = len(self._tokenizer.encode(raw))
            # Romanization (check_ratio off) expands length, so give the
            # generator more headroom than the usual 1.8x cleanup budget.
            factor = OUTPUT_TOKEN_FACTOR if check_ratio else 3.0
            max_tokens = max(MIN_MAX_TOKENS, int(input_tokens * factor))
            generated = self._generate_locked(
                system_prompt,
                raw,
                max_tokens,
                timeout_ms / 1000.0,
                cancel_event,
            )
        ms = int((time.perf_counter() - t0) * 1000)
        log.info(
            "cleanup inference total_ms=%d ttft_ms=%d decode_ms=%d prefix_tokens=%d "
            "output_tokens=%d prepared_hit=%s status=%s",
            ms,
            generated.ttft_ms,
            generated.decode_ms,
            generated.prefix_tokens,
            generated.output_tokens,
            generated.cache_hit,
            generated.status,
        )
        metrics = {
            "ttft_ms": generated.ttft_ms,
            "decode_ms": generated.decode_ms,
            "prefix_tokens": generated.prefix_tokens,
            "output_tokens": generated.output_tokens,
            "cache_hit": generated.cache_hit,
        }
        if generated.status == "cancelled":
            log.info("cleanup cooperatively cancelled after %dms", ms)
            return CleanupResult(raw, False, ms, "cancelled", **metrics)
        if generated.status == "timeout":
            log.warning("cleanup timeout after %dms — returning raw", ms)
            return CleanupResult(raw, False, ms, "timeout", **metrics)
        if generated.status == "length":
            # Truncated at the token ceiling. Dictation cleanup would normally
            # let the divergence guard decide, but a cut-off result is never
            # trustworthy — return raw so nothing partial is delivered.
            log.warning("cleanup hit token ceiling after %dms — returning raw", ms)
            return CleanupResult(raw, False, ms, "length", **metrics)
        # Undo the control-token neutralization applied to the prompt so a
        # preserved marker round-trips cleanly (before the guard compares).
        text = restore_control_tokens(generated.text)
        # The divergence guard is a length-ratio over-editing check; a script
        # transliteration legitimately changes length, so skip it when romanizing.
        if check_ratio:
            reason = check_divergence(raw, text, allowed_terms)
            if reason is not None:
                log.warning("cleanup divergence guard tripped (%s) — returning raw", reason)
                return CleanupResult(raw, False, ms, reason, **metrics)
        elif not text.strip():
            return CleanupResult(raw, False, ms, "empty_output", **metrics)
        return CleanupResult(text.strip(), True, ms, **metrics)

    async def cleanup(
        self,
        raw: str,
        system_prompt: str,
        timeout_ms: int | None = None,
        check_ratio: bool = True,
        cancel_event: threading.Event | None = None,
        allowed_terms: list[str] | None = None,
    ) -> CleanupResult:
        """Clean `raw` under `system_prompt`. Never raises; returns raw on any failure.

        `timeout_ms` defaults to a length-adaptive budget (see
        `adaptive_timeout_ms`); pass an explicit value to override.
        `cancel_event` lets a BACKGROUND caller (vocab mining) be preempted
        mid-generation the moment a dictation needs the model."""
        if timeout_ms is None:
            timeout_ms = adaptive_timeout_ms(raw)
        if self.unhealthy:
            return CleanupResult(raw, False, 0, "llm_unhealthy")
        if not self.loaded:
            return CleanupResult(raw, False, 0, "llm_not_loaded")
        worker_cancel = cancel_event if cancel_event is not None else threading.Event()
        loop = asyncio.get_running_loop()
        started = asyncio.Event()

        def run_started() -> CleanupResult:
            # asyncio.Event is not thread-safe. Schedule the signal onto the
            # owning loop before entering `_run`, so the hard watchdog measures
            # native execution time rather than time queued behind old work.
            loop.call_soon_threadsafe(started.set)
            return self._run(
                raw, system_prompt, timeout_ms, check_ratio,
                worker_cancel, allowed_terms,
            )

        worker = loop.run_in_executor(self._executor, run_started)
        try:
            try:
                await asyncio.wait_for(started.wait(), timeout=QUEUE_TIMEOUT_S)
            except asyncio.TimeoutError:
                worker_cancel.set()
                worker.cancel()
                self.unhealthy = True
                log.error(
                    "cleanup worker unavailable after %dms in queue — returning raw",
                    int(QUEUE_TIMEOUT_S * 1000),
                )
                return CleanupResult(
                    raw, False, int(QUEUE_TIMEOUT_S * 1000), "timeout_queue"
                )

            # In-thread deadline enforces the budget between tokens. This
            # independent outer watchdog starts only once this job is actually
            # running. If native generation then wedges, retire the process.
            return await asyncio.wait_for(
                worker,
                timeout=timeout_ms / 1000.0 + HARD_TIMEOUT_GRACE_S,
            )
        except asyncio.TimeoutError:
            worker_cancel.set()
            self.unhealthy = True
            log.error("cleanup hard-wedged past %dms — returning raw", timeout_ms)
            return CleanupResult(raw, False, timeout_ms, "timeout_hard")
        except asyncio.CancelledError:
            worker_cancel.set()
            worker.cancel()
            raise
        except Exception as exc:  # noqa: BLE001 — cleanup must never break dictation
            log.exception("cleanup failed")
            return CleanupResult(raw, False, 0, f"error:{exc}")
