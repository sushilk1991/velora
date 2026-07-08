"""STT backends behind one interface.

- ParakeetBackend: parakeet-mlx `transcribe_stream` — audio is processed DURING
  recording so stop→transcript only flushes the tail.
- WhisperBackend: mlx-whisper — accumulates PCM, batch-transcribes on stop,
  with hallucination guard (compression/repetition checks, repeated-tail trim).
  Long recordings are additionally decoded in pause-aligned SEGMENTS during
  recording (smartness-v2 §2): live partials for the HUD, and past
  LONG_DICTATION_S the final text is stitched from those segments so the
  stop→final latency stays flat instead of growing with the dictation.
- FakeBackend: for tests (VELORA_FAKE_STT=1), no model downloads.

All heavy imports are lazy (inside load()) so tests never touch MLX.
"""

from __future__ import annotations

import logging
import math
import os
import re
import time
from typing import Any, Protocol

import numpy as np

log = logging.getLogger("velora.stt")

SAMPLE_RATE = 16_000

# Feed parakeet in ~0.5s increments: each add_audio() call runs the encoder,
# so per-100ms-frame calls would waste compute for no latency win.
_PARAKEET_FEED_SAMPLES = SAMPLE_RATE // 2

# --- in-session segmenting (whisper only) -------------------------------------
# Whisper decodes ~97x realtime but the cleanup LLM does not; segments decoded
# DURING recording let the server clean them concurrently, so at stop only the
# tail remains (flat stop→final latency at any dictation length).
MIN_SEGMENT_S = 10.0  # min un-decoded audio before a pause may close a segment
SEGMENT_SILENCE_S = 0.7  # trailing-pause length that closes a segment
HARD_SEGMENT_S = 25.0  # close even mid-speech past this much un-decoded audio
# Below this total duration, finalize re-decodes the WHOLE clip exactly like the
# pre-segmenting code (segments were preview-only) so short/medium quality is
# unchanged; above it, the stitched segments become the final text (those
# dictations previously blew the cleanup budget and fell back to raw anyway).
LONG_DICTATION_S = 45.0


class SilenceTracker:
    """Trailing-silence duration from per-chunk RMS at 16 kHz (energy VAD).

    The silence threshold adapts to the speaker/mic level: an EMA of RMS over
    non-silent chunks, floored so a dead-quiet room can't push the threshold
    to zero. No new deps — this only needs numpy.
    """

    _EMA_ALPHA = 0.1
    _EMA_START = 0.02
    _MIN_THRESHOLD = 0.003

    def __init__(self) -> None:
        self._speech_ema = self._EMA_START
        self._trailing_silence_samples = 0

    def feed(self, chunk: np.ndarray) -> bool:
        """Track one chunk; returns True when the chunk carried speech."""
        if chunk.size == 0:
            return False
        rms = float(np.sqrt(np.mean(np.square(chunk, dtype=np.float64))))
        threshold = max(self._MIN_THRESHOLD, 0.15 * self._speech_ema)
        if rms < threshold:
            self._trailing_silence_samples += len(chunk)
            return False
        self._trailing_silence_samples = 0
        self._speech_ema += self._EMA_ALPHA * (rms - self._speech_ema)
        return True

    @property
    def trailing_silence_s(self) -> float:
        return self._trailing_silence_samples / SAMPLE_RATE

    def consume_pause(self) -> None:
        """Zero the trailing-silence run (a segment consumed this pause) while
        KEEPING the adapted speech level — a full reset per segment would throw
        away the mic/speaker calibration for no reason (review finding)."""
        self._trailing_silence_samples = 0

    def reset(self) -> None:
        self._speech_ema = self._EMA_START
        self._trailing_silence_samples = 0


class STTBackend(Protocol):
    """Interface: load, feed_chunk, finalize, reset (+ optional segmenting).

    Segmenting surface (only WhisperBackend implements it for real; parakeet
    and fake keep no-op defaults so the server can call these unconditionally):
    - `initial_prompt`: glossary text biasing recognition (whisper only).
    - `take_new_segments()`: raw segment texts finalized since the last call —
      the server kicks off per-segment cleanup from these.
    - After `finalize()`, `segments_used_for_final` says whether the returned
      text was stitched from the in-session segments (long dictation) or is a
      fresh whole-clip decode; `final_tail` is the tail text decoded at stop
      when stitched (the only part the server still has to clean).
    """

    model_id: str
    initial_prompt: str | None
    segments_used_for_final: bool
    final_tail: str

    def load(self) -> None: ...

    def start_session(self) -> None: ...

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        """Feed Float32 PCM; may return an updated partial transcript."""
        ...

    def take_new_segments(self) -> list[str]:
        """Raw segment texts finalized since the last call (may be empty)."""
        ...

    def finalize(self) -> str:
        """End the session and return the full transcript."""
        ...

    def reset(self) -> None:
        """Discard any in-flight session state."""
        ...


# --- STT contextual biasing (whisper initial_prompt) ---------------------------


def build_glossary_prompt(
    user_vocab: list[str],
    learned_vocab: list[str],
    auto_vocab: list[str],
    entity_names: list[str],
    cap: int = 24,
) -> str | None:
    """Render vocab sources into a whisper `initial_prompt` glossary, or None.

    Whisper attends most to the END of the prompt, so terms are ordered least
    important first / most important LAST: auto-mined, learned, user-configured,
    then on-screen entity names (what the user is looking at right now). Dedup
    is case-insensitive keeping the LAST (most important) occurrence, and the
    cap keeps the tail — well under whisper's 224-token prompt budget.
    """
    ordered: list[str] = []
    for source in (auto_vocab, learned_vocab, user_vocab, entity_names):
        for term in source or []:
            term = str(term).strip()
            if term:
                ordered.append(term)
    seen: set[str] = set()
    kept_rev: list[str] = []
    for term in reversed(ordered):  # keep the most-important (last) occurrence
        key = term.lower()
        if key in seen:
            continue
        seen.add(key)
        kept_rev.append(term)
    terms = list(reversed(kept_rev))[-cap:]
    if not terms:
        return None
    return "Glossary: " + ", ".join(terms) + "."


_ECHO_WORD_RE = re.compile(r"\S+")


def _echo_norm(word: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", word.lower())


def strip_prompt_echo(text: str, prompt: str | None) -> str:
    """Remove a leaked initial_prompt from decoded text (known whisper failure:
    the glossary is echoed into the transcript, especially over silence).

    Conservative on purpose (review-hardened): an echo LEADS a decode, so both
    cases are anchored to the very start of the text (the preamble word must be
    one of the first three words), and a matched term run must follow the
    PROMPT'S ORDER — real dictation that happens to reuse glossary words in a
    different order is left alone. Mid-transcript echoes without the preamble
    are out of scope (guard_whisper_result's heuristics are the net there).
    """
    if not text or not prompt:
        return text
    ptokens = [t for t in (_echo_norm(w) for w in prompt.split()) if t]
    if not ptokens:
        return text

    def run_end(words: list[re.Match[str]], idx: int) -> tuple[int | None, int]:
        """From word `idx`, consume words that match prompt tokens IN PROMPT
        ORDER (subsequence); returns (end char offset, matched-word count)."""
        end: int | None = None
        matched = 0
        ppos = 0
        while idx < len(words):
            norm = _echo_norm(words[idx].group(0))
            if not norm:  # bare punctuation token — part of the echoed list
                idx += 1
                continue
            try:
                ppos = ptokens.index(norm, ppos) + 1
            except ValueError:
                break
            matched += 1
            end = words[idx].end()
            idx += 1
        return end, matched

    # Bounded loop: whisper occasionally echoes the prompt more than once.
    for _ in range(3):
        words = list(_ECHO_WORD_RE.finditer(text))
        if not words:
            break
        stripped = False
        # Case 1: the literal preamble word within the first three words →
        # strip it and the in-order term run. To protect genuinely dictated
        # uses ("add a glossary section" is not start-anchored; "glossary
        # Kubernetes" mid-text is never touched), the word must carry the
        # echoed colon ("Glossary:") or be followed by ≥2 in-order terms.
        for i, w in enumerate(words[:3]):
            if _echo_norm(w.group(0)) != "glossary":
                continue
            end, matched = run_end(words, i + 1)
            if matched < 2 and not w.group(0).rstrip(".").endswith(":"):
                continue  # bare prose use of the word — not an echo
            end = end if end is not None else w.end()
            text = (text[: w.start()] + " " + text[end:]).strip()
            stripped = True
            break
        if stripped:
            text = re.sub(r"\s{2,}", " ", text)
            continue
        # Case 2: fuzzy prefix of the glossary at the very start (allow the
        # preamble word itself to have been dropped by the decoder). Requires
        # ≥3 prompt tokens matched in order from the first word.
        first = _echo_norm(words[0].group(0))
        if first and first in (ptokens[0], ptokens[1] if len(ptokens) > 1 else ptokens[0]):
            end, matched = run_end(words, 0)
            if end is not None and matched >= min(3, len(ptokens)):
                text = text[end:].strip()
                text = re.sub(r"\s{2,}", " ", text)
                continue
        break
    return text.strip()


class ParakeetBackend:
    """Streaming STT via parakeet-mlx (default)."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model: Any = None
        self._stream: Any = None
        self._pending: list[np.ndarray] = []
        self._pending_samples = 0
        # Segmenting surface (see STTBackend): parakeet already streams, so it
        # never produces cleanup segments and ignores the whisper glossary.
        self.initial_prompt: str | None = None
        self.segments_used_for_final = False
        self.final_tail = ""

    def take_new_segments(self) -> list[str]:
        return []

    def load(self) -> None:
        from parakeet_mlx import from_pretrained

        from .models import ensure_downloaded

        t0 = time.perf_counter()
        # Resolve to the local snapshot so a cached model loads with zero
        # network requests (local-first).
        self._model = from_pretrained(ensure_downloaded(self.model_id))
        log.info("parakeet loaded %s in %.2fs", self.model_id, time.perf_counter() - t0)

    def start_session(self) -> None:
        self.reset()
        # depth=2: first two encoder layers carry exact cache across chunks —
        # good accuracy/latency tradeoff for dictation.
        self._stream = self._model.transcribe_stream(context_size=(256, 256), depth=2)
        self._stream.__enter__()

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        if self._stream is None:
            return None
        self._pending.append(chunk)
        self._pending_samples += len(chunk)
        if self._pending_samples < _PARAKEET_FEED_SAMPLES:
            return None
        self._flush_pending()
        return self._stream.result.text

    def _flush_pending(self) -> None:
        import mlx.core as mx

        if not self._pending:
            return
        audio = np.concatenate(self._pending)
        self._pending = []
        self._pending_samples = 0
        self._stream.add_audio(mx.array(audio))

    def finalize(self) -> str:
        if self._stream is None:
            return ""
        # Flush the tail plus a little silence so the draft region decodes.
        self._pending.append(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
        self._flush_pending()
        text = self._stream.result.text.strip()
        self.reset()
        return text

    def reset(self) -> None:
        if self._stream is not None:
            try:
                self._stream.__exit__(None, None, None)
            except Exception:  # noqa: BLE001
                log.exception("parakeet stream teardown failed")
        self._stream = None
        self._pending = []
        self._pending_samples = 0


# --- whisper hallucination guard ---------------------------------------------

_COMPRESSION_RATIO_THRESHOLD = 2.4
_LOGPROB_THRESHOLD = -1.2


def _trim_repeated_tail(text: str) -> str:
    """Trim Whisper's classic end-of-audio repetition loops.

    Repeatedly drops the final phrase (5..2 words) while it is an immediate
    repeat of the preceding words.
    """
    words = text.split()
    changed = True
    while changed and len(words) >= 4:
        changed = False
        for n in range(5, 1, -1):
            if len(words) >= 2 * n:
                tail = [w.strip(".,!?;:").lower() for w in words[-n:]]
                prev = [w.strip(".,!?;:").lower() for w in words[-2 * n : -n]]
                if tail == prev:
                    words = words[:-n]
                    changed = True
                    break
    return " ".join(words)


def guard_whisper_result(result: dict[str, Any]) -> str:
    """Drop hallucinated segments, then trim repeated tails."""
    segments = result.get("segments") or []
    kept: list[str] = []
    for seg in segments:
        seg_text = (seg.get("text") or "").strip()
        if not seg_text:
            continue
        cr = seg.get("compression_ratio")
        lp = seg.get("avg_logprob")
        # Log lengths only — never transcript text (privacy: engine.log is plaintext).
        if cr is not None and cr > _COMPRESSION_RATIO_THRESHOLD:
            log.info("whisper guard: dropped segment (compression_ratio=%.2f, %d chars)", cr, len(seg_text))
            continue
        if lp is not None and lp < _LOGPROB_THRESHOLD and cr is not None and cr > 2.0:
            log.info("whisper guard: dropped segment (logprob=%.2f cr=%.2f, %d chars)", lp, cr, len(seg_text))
            continue
        # drop non-text junk (e.g. "!!!!" runs)
        if not re.search(r"[A-Za-z0-9]", seg_text):
            continue
        kept.append(seg_text)
    text = " ".join(kept).strip() or (result.get("text") or "").strip()
    return _trim_repeated_tail(text)


def whisper_language(language: str | None) -> str | None:
    """Map config `language` to mlx-whisper's arg: "auto"/empty → None (autodetect)."""
    if not language:
        return None
    language = language.strip()
    if not language or language.lower() == "auto":
        return None
    return language


class WhisperBackend:
    """Batch STT via mlx-whisper, with hallucination guard and in-session
    segmenting: pause-aligned spans are decoded DURING recording so the server
    can clean them concurrently (and the HUD finally gets whisper partials)."""

    def __init__(self, model_id: str, language: str = "auto") -> None:
        self.model_id = model_id
        self.language = language
        self._model_path = model_id  # resolved to a local path in load()
        self._chunks: list[np.ndarray] = []
        self._loaded = False
        # Glossary biasing (set by the server per session; smartness-v2 §4).
        self.initial_prompt: str | None = None
        # In-session segmenting exists for LIVE latency; transcribe_clip
        # (reprocess) turns it off so an archived clip stays one batch decode.
        self.segmenting_enabled = True
        # Segmenting state. ALL pcm is kept in _chunks even after a segment is
        # decoded — the whole-clip re-decode at finalize must stay possible.
        self._samples = 0
        self._decoded_samples = 0  # offset of the first un-decoded sample
        self._segments: list[str] = []
        self._new_segments: list[str] = []
        self._silence = SilenceTracker()
        self._span_had_speech = False  # speech seen since the last decode point
        self._retry_at_samples = 0  # backoff cursor after an empty speech-span decode
        # Sticky per-session kill switch: one failed segment decode degrades
        # the whole session to today's batch path (never raise into the feed).
        self._segment_decode_failed = False
        # Read by the server right after finalize() (see STTBackend Protocol).
        self.segments_used_for_final = False
        self.final_tail = ""

    def load(self) -> None:
        import mlx.core as mx
        from mlx_whisper.load_models import load_model

        from .models import ensure_downloaded

        self._model_path = ensure_downloaded(self.model_id)
        t0 = time.perf_counter()
        model = load_model(self._model_path, dtype=mx.float16)
        mx.eval(model.parameters())
        del model  # mlx_whisper's ModelHolder reloads by repo id at transcribe time
        self._loaded = True
        log.info("whisper weights warmed %s in %.2fs", self.model_id, time.perf_counter() - t0)

    def start_session(self) -> None:
        self.reset()
        self.segments_used_for_final = False
        self.final_tail = ""

    def _decode(self, audio: np.ndarray) -> str:
        """One guarded mlx-whisper decode (segment, tail, or whole clip)."""
        import mlx_whisper

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self._model_path,
            condition_on_previous_text=False,
            language=whisper_language(self.language),
            fp16=True,
            initial_prompt=self.initial_prompt,
        )
        text = guard_whisper_result(result)
        # Known initial_prompt failure mode: the glossary leaks into the
        # transcript (especially over silence) — strip it on every decode.
        return strip_prompt_echo(text, self.initial_prompt)

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        self._chunks.append(chunk)
        self._samples += len(chunk)
        if self._silence.feed(chunk):
            self._span_had_speech = True
        if not self._loaded or not self.segmenting_enabled or self._segment_decode_failed:
            return None
        if self._samples < self._retry_at_samples:
            return None  # backing off after an empty decode of a speech span
        undecoded_s = (self._samples - self._decoded_samples) / SAMPLE_RATE
        pause_close = undecoded_s >= MIN_SEGMENT_S and self._silence.trailing_silence_s >= SEGMENT_SILENCE_S
        if not pause_close and undecoded_s < HARD_SEGMENT_S:
            return None
        try:
            span = np.concatenate(self._chunks)[self._decoded_samples : self._samples]
            text = self._decode(span)
        except Exception:  # noqa: BLE001 — a failed decode must not kill the feed loop
            # Degrade to the batch path for the rest of the session; the audio
            # is still all in _chunks, so finalize recovers everything.
            log.exception("segment decode failed — falling back to batch decode at stop")
            self._segment_decode_failed = True
            return None
        if not text and self._span_had_speech:
            # Empty decode for a span that HAD speech (guard misfire): marking
            # it decoded would drop those words from the stitched final
            # (review finding). Leave the audio pending — the next attempt or
            # the tail decode at stop re-covers it with more context — and
            # back off ~3s so a standing pause doesn't retry every frame.
            self._retry_at_samples = self._samples + int(3 * SAMPLE_RATE)
            return None
        self._decoded_samples = self._samples
        self._silence.consume_pause()  # the pause that closed this segment is consumed
        self._span_had_speech = False
        if not text:
            return None  # true silence-only span — consumed, nothing to say
        self._segments.append(text)
        self._new_segments.append(text)
        return " ".join(self._segments)

    def take_new_segments(self) -> list[str]:
        out = self._new_segments
        self._new_segments = []
        return out

    def finalize(self) -> str:
        self.segments_used_for_final = False
        self.final_tail = ""
        if not self._chunks:
            self.reset()
            return ""
        audio = np.concatenate(self._chunks)
        duration_s = len(audio) / SAMPLE_RATE
        # Long dictation with usable segments: decode only the un-decoded tail
        # and stitch — stop→final stays flat however long the user spoke. Short
        # and medium clips re-decode WHOLE, exactly like the pre-segmenting
        # code, so their quality is unchanged (segments were preview-only).
        if duration_s > LONG_DICTATION_S and self._segments and not self._segment_decode_failed:
            try:
                tail = self._decode(audio[self._decoded_samples :]) if self._decoded_samples < len(audio) else ""
            except Exception:  # noqa: BLE001 — fall through to the whole-clip decode
                log.exception("tail decode failed — re-decoding the whole clip")
            else:
                parts = self._segments + ([tail] if tail else [])
                text = " ".join(parts).strip()
                self.reset()
                self.segments_used_for_final = True
                self.final_tail = tail
                return text
        if duration_s > 60:
            log.warning("whisper batch transcribe of %.0fs of audio — expect high stop→final latency", duration_s)
        try:
            text = self._decode(audio)
        finally:
            self.reset()
        return text

    def reset(self) -> None:
        self._chunks = []
        self._samples = 0
        self._decoded_samples = 0
        self._segments = []
        self._new_segments = []
        self._silence.reset()
        self._segment_decode_failed = False
        self._span_had_speech = False
        self._retry_at_samples = 0
        # NOTE: initial_prompt / segments_used_for_final / final_tail survive a
        # reset on purpose — the server sets the prompt per session and reads
        # the finalize flags right after finalize() has reset the audio state.


class FakeBackend:
    """Deterministic backend for tests — no models, no downloads.

    Selected when VELORA_FAKE_STT=1. Transcript comes from VELORA_FAKE_STT_TEXT
    (default below); finalize also reports the number of samples received so
    integration tests can assert audio actually flowed.

    Segmenting mode: VELORA_FAKE_STT_SEGMENTS="seg one|seg two" makes the
    backend emit one raw segment per SEGMENT_SAMPLES of audio (mimicking the
    whisper in-session segment pipeline), with finalize returning the stitched
    join plus VELORA_FAKE_STT_TEXT as the tail when set. Default behavior
    (env var unset) is exactly the historical one.
    """

    DEFAULT_TEXT = "hello world this is a fake transcript"
    SEGMENT_SAMPLES = 3200  # one fake segment per 0.2s of audio

    def __init__(self, model_id: str = "fake", language: str = "auto") -> None:
        self.model_id = model_id
        self.language = language
        self.samples = 0
        self.sessions = 0
        self.initial_prompt: str | None = None
        self.segments_used_for_final = False
        self.final_tail = ""
        self._pending_segments: list[str] = []
        self._emitted_segments: list[str] = []
        self._new_segments: list[str] = []
        self._samples_since_segment = 0

    def load(self) -> None:
        pass

    def start_session(self) -> None:
        self.samples = 0
        self.sessions += 1
        spec = os.environ.get("VELORA_FAKE_STT_SEGMENTS", "")
        self._pending_segments = [s.strip() for s in spec.split("|") if s.strip()]
        self._emitted_segments = []
        self._new_segments = []
        self._samples_since_segment = 0
        self.segments_used_for_final = False
        self.final_tail = ""

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        self.samples += len(chunk)
        if not (self._pending_segments or self._emitted_segments):
            return f"partial after {self.samples} samples"
        # Segment mode: like whisper, partials only appear when a segment closes.
        self._samples_since_segment += len(chunk)
        if self._samples_since_segment < self.SEGMENT_SAMPLES or not self._pending_segments:
            return None
        self._samples_since_segment = 0
        seg = self._pending_segments.pop(0)
        self._emitted_segments.append(seg)
        self._new_segments.append(seg)
        return " ".join(self._emitted_segments)

    def take_new_segments(self) -> list[str]:
        out = self._new_segments
        self._new_segments = []
        return out

    def finalize(self) -> str:
        if self._emitted_segments:
            tail = os.environ.get("VELORA_FAKE_STT_TEXT", "")
            parts = self._emitted_segments + ([tail] if tail else [])
            text = " ".join(parts)
            self.reset()
            self.segments_used_for_final = True
            self.final_tail = tail
            return text
        text = os.environ.get("VELORA_FAKE_STT_TEXT", self.DEFAULT_TEXT)
        self.reset()
        return text

    def reset(self) -> None:
        self.samples = 0
        self._pending_segments = []
        self._emitted_segments = []
        self._new_segments = []
        self._samples_since_segment = 0


def fake_stt_enabled() -> bool:
    return os.environ.get("VELORA_FAKE_STT", "") == "1"


def create_backend(model_id: str, language: str = "auto") -> STTBackend:
    """Backend selection from config (and VELORA_FAKE_STT for tests).

    `language` is honored by whisper only ("auto" → autodetect); parakeet is
    English-only, so it ignores the setting.
    """
    if fake_stt_enabled():
        return FakeBackend(model_id, language)
    if "whisper" in model_id.lower():
        return WhisperBackend(model_id, language)
    return ParakeetBackend(model_id)


def transcribe_clip(backend: STTBackend, pcm: np.ndarray, chunk_samples: int = SAMPLE_RATE) -> str:
    """Batch-transcribe a whole PCM clip through any backend (used by reprocess).

    Drives the same start/feed/finalize path a live session uses, so streaming
    (parakeet) and batch (whisper) backends both work. Runs on the caller's
    thread — MLX is thread-affine, so call this on the STT executor.
    In-session segmenting is disabled for the duration: it exists for LIVE
    latency; a reprocessed clip should stay one whole-clip decode.
    """
    segmenting = getattr(backend, "segmenting_enabled", None)
    if segmenting is not None:
        backend.segmenting_enabled = False  # type: ignore[attr-defined]
    try:
        backend.start_session()
        for i in range(0, len(pcm), chunk_samples):
            backend.feed_chunk(pcm[i : i + chunk_samples])
        return backend.finalize()
    finally:
        if segmenting is not None:
            backend.segmenting_enabled = segmenting  # type: ignore[attr-defined]


def pcm_from_payload(payload: bytes) -> np.ndarray:
    """Decode an AUDIO frame payload: 16kHz mono Float32 LE."""
    if len(payload) % 4 != 0:
        raise ValueError(f"audio payload length {len(payload)} not a multiple of 4")
    arr = np.frombuffer(payload, dtype="<f4").astype(np.float32, copy=False)
    if arr.size and not math.isfinite(float(np.max(np.abs(arr)))):
        arr = np.nan_to_num(arr)
    return arr
