"""STT backends behind one interface.

- ParakeetBackend: parakeet-mlx — each pause-bounded segment is decoded whole
  DURING recording, so stop→transcript only decodes the tail.
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

import contextlib
import functools
import logging
import math
import os
import re
import time
import zlib
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Any, Protocol

import numpy as np

log = logging.getLogger("velora.stt")

SAMPLE_RATE = 16_000
# AVCapture can finish opening just as a very short hotkey press is released,
# leaving only a few dozen milliseconds of device noise. Whisper pads that to
# its inference window and can spend 3-6 seconds producing a repeated prompt
# hallucination. No intelligible utterance fits in this span; fail fast.
MIN_FINAL_AUDIO_S = 0.15

# Parakeet decodes each span whole (see ParakeetBackend). Attention memory grows
# with the square of span length (12 GB peak on one 440 s clip), so longer spans
# decode in windows that share 15 s of audio for the merge to align on.
_PARAKEET_WINDOW_S = 120.0
_PARAKEET_OVERLAP_S = 15.0
# The same token decoded by two windows lands within this many seconds of
# itself (up to 1.3 s apart on 24 seams of 58 min of Indian-English audio), and
# this many identical tokens in a row is an alignment, not chance. parakeet-mlx's
# own merge accepts half the overlap (7.5 s): at that width a repeated word
# ("no no no") pairs with a copy several words away and the join drops or
# repeats words.
_MERGE_TIME_TOLERANCE_S = 1.5
_MERGE_MIN_RUN = 3
# After a speech-bearing span decodes empty, wait this long before decoding it
# again with the audio that arrived since (a standing pause would otherwise
# retry on every chunk). Each retry decodes the whole growing span, so the
# wait doubles on every consecutive empty decode, up to the max: 5 minutes of
# hum the tracker hears as speech costs 10 span decodes, not about 48.
_EMPTY_SPAN_RETRY_S = 3.0
_EMPTY_SPAN_RETRY_MAX_S = 48.0
# Past HARD_SEGMENT_S a segment closes at the first quiet stretch this long.
# A single quiet 100 ms chunk can be the closure inside a word. Audio that is
# never quiet (steady room noise) is never cut: it decodes whole at stop.
_HARD_CUT_QUIET_S = 0.2
# Stream Typing previews decode the open span this often (then back off with
# decode time). Parakeet runs about 110x real time (p50 over the owner's
# clips), so a 10 s open span costs about 0.1 s.
_PARAKEET_PREVIEW_INTERVAL_S = 0.5

# --- in-session segmenting (whisper; parakeet reuses the pause rules) ---------
# Whisper decodes ~97x realtime but the cleanup LLM does not; segments decoded
# DURING recording let the server clean them concurrently, so at stop only the
# tail remains (flat stop→final latency at any dictation length).
MIN_SEGMENT_S = 10.0  # min un-decoded audio before a pause may close a segment
SEGMENT_SILENCE_S = 0.7  # trailing-pause length that closes a segment
HARD_SEGMENT_S = 25.0  # close even mid-speech past this much un-decoded audio
# Optional display-only preview lane used by Stream Typing. Ordinary dictation
# leaves it disabled because the extra decodes compete with authoritative
# Whisper and Qwen work even though they never feed final stitching.
PREVIEW_FIRST_S = 2.0
PREVIEW_MIN_SPAN_S = 1.2
PREVIEW_PAUSE_S = 0.3
PREVIEW_BASE_INTERVAL_S = 1.5
PREVIEW_MAX_INTERVAL_S = 4.0
PREVIEW_MIN_NEW_S = 0.8
# A preview decodes at most the last PREVIEW_WINDOW_S of the uncommitted span.
# Whisper closes a segment at HARD_SEGMENT_S even mid-speech, so its whole
# open span fits and no provisional word drops out of view. Parakeet closes
# segments only in a pause, so past this length its preview shows only the
# newest words.
PREVIEW_WINDOW_S = HARD_SEGMENT_S
PREVIEW_BACKOFF = 1.5
# Below this total duration, finalize re-decodes the WHOLE clip exactly like the
# pre-segmenting code (segments were preview-only) so short/medium quality is
# unchanged; above it, the stitched segments become the final text (those
# dictations previously blew the cleanup budget and fell back to raw anyway).
LONG_DICTATION_S = 45.0


@dataclass(frozen=True)
class WhisperPreviewRequest:
    """Immutable, display-only audio snapshot for one HUD preview (Whisper or
    Parakeet)."""

    audio: np.ndarray
    committed_segments: tuple[str, ...]


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

    @property
    def speech_level(self) -> float:
        """The adapted per-session speech RMS (EMA over speechy chunks)."""
        return self._speech_ema

    def consume_pause(self) -> None:
        """Zero the trailing-silence run (a segment consumed this pause) while
        KEEPING the adapted speech level — a full reset per segment would throw
        away the mic/speaker calibration for no reason (review finding)."""
        self._trailing_silence_samples = 0

    def reset(self) -> None:
        self._speech_ema = self._EMA_START
        self._trailing_silence_samples = 0


def speech_window_fraction(
    audio: np.ndarray, chunk_samples: int = SAMPLE_RATE
) -> float:
    """Fraction of batch-feed windows carrying tracker-level speech evidence."""
    if len(audio) == 0 or chunk_samples <= 0:
        return 0.0
    tracker = SilenceTracker()
    active = 0
    total = 0
    for start in range(0, len(audio), chunk_samples):
        active += tracker.feed(audio[start : start + chunk_samples])
        total += 1
    return active / total


class STTBackend(Protocol):
    """Interface: load, feed_chunk, finalize, reset (+ optional segmenting).

    Segmenting surface (whisper and parakeet implement it; fake keeps no-op
    defaults unless configured, so the server can call these unconditionally):
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


def strip_prompt_echo(
    text: str,
    prompt: str | None,
    *,
    allow_trailing: bool = True,
) -> str:
    """Remove a leaked initial_prompt from decoded text (known whisper failure:
    the glossary is echoed into the transcript, especially over silence).

    Conservative on purpose (review-hardened): a leading echo is anchored to
    the start of the text, and a matched term run must follow the PROMPT'S
    ORDER. A second guard removes an exact comma-separated run of at least two
    glossary terms from the END of a completed sentence. Whisper sometimes
    appends that prompt tail after long recordings without repeating the
    "Glossary:" preamble.
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
    if not allow_trailing:
        return text.strip()

    # Case 3: an exact prompt-tail run appended after completed dictation.
    # Require at least two comma-separated terms, prompt order, and a sentence
    # boundary before the run. A genuine single-term ending or ordinary prose
    # such as "LLM and Airlearn" is untouched.
    body = re.sub(r"^\s*Glossary:\s*", "", prompt, flags=re.IGNORECASE).strip()
    terms = [term.strip() for term in body.rstrip(".").split(",") if term.strip()]
    for count in range(min(6, len(terms)), 1, -1):
        suffix = r",\s*".join(re.escape(term) for term in terms[-count:])
        match = re.search(r"(?<!\w)" + suffix + r"[.!?]*\s*$", text, re.IGNORECASE)
        if match is None:
            continue
        prefix = text[:match.start()].rstrip()
        if prefix and prefix[-1] in ".!?":
            return prefix
    return text.strip()


@dataclass(frozen=True)
class _Token:
    """One decoded parakeet token, times in seconds."""

    text: str
    start: float
    end: float


def _same_token(a: _Token, b: _Token) -> bool:
    return a.text == b.text and abs(a.start - b.start) < _MERGE_TIME_TOLERANCE_S


def _merge_overlap(
    kept: list[_Token],
    new: list[_Token],
    *,
    seam_start_s: float,
    seam_end_s: float,
) -> list[_Token]:
    """Join two windows' tokens so the words in their shared audio appear once.

    Both windows decoded [seam_start_s, seam_end_s). The longest run of tokens
    the two agree on (same text at the same time) anchors the join: `kept`
    through the run, then `new` after it. Of equally long runs, the one whose
    timings agree best wins: in "no no no" a run shifted by one word also
    matches within tolerance. Without such a run, cut in the widest gap
    between words (see _widest_gap_cut).

        kept  ... w103 w104 w105 ... w119
        new                 w105 ... w119 w120 w121 ...
                            '-- run --'
        out   ... w103 w104 w105 ... w119 w120 w121 ...
    """
    if not kept:
        return list(new)
    if not new:
        return list(kept)

    # Only tokens inside the seam can pair up.
    kept_from = next((i for i, t in enumerate(kept) if t.end > seam_start_s), len(kept))
    new_to = next((j for j, t in enumerate(new) if t.start >= seam_end_s), len(new))

    best_len, best_error, best_i, best_j = 0, 0.0, 0, 0
    for i in range(kept_from, len(kept)):
        for j in range(new_to):
            run, error = 0, 0.0
            while (
                i + run < len(kept)
                and j + run < new_to
                and _same_token(kept[i + run], new[j + run])
            ):
                error += abs(kept[i + run].start - new[j + run].start)
                run += 1
            if run > best_len or (run == best_len and run > 0 and error < best_error):
                best_len, best_error, best_i, best_j = run, error, i, j

    if best_len >= _MERGE_MIN_RUN:
        return kept[: best_i + best_len] + new[best_j + best_len :]

    cut_s = _widest_gap_cut(kept[kept_from:] + new[:new_to], seam_start_s, seam_end_s)
    return [t for t in kept if t.start < cut_s] + [t for t in new if t.start >= cut_s]


def _widest_gap_cut(tokens: list[_Token], seam_start_s: float, seam_end_s: float) -> float:
    """The middle of the longest stretch of the seam where no window placed a
    word.

    Both windows' tokens count, so the cut lands where both heard nothing and
    no word straddles it. A word the two windows place on opposite sides of
    the seam midpoint (drift) sits on one side of a real pause in both.

        seam   |......okay(kept)....okay(new)......|
        gaps   '--6.3 s--'         '1.9'    '--5.8 s--'
        cut        ^ keep kept words before, new words after
    """
    spans = sorted((max(t.start, seam_start_s), min(t.end, seam_end_s)) for t in tokens)
    widest, cut_s = -1.0, (seam_start_s + seam_end_s) / 2
    cursor = seam_start_s
    for start, end in [*spans, (seam_end_s, seam_end_s)]:
        if start - cursor > widest:
            widest, cut_s = start - cursor, (cursor + start) / 2
        cursor = max(cursor, end)
    return cut_s


def _chunk_span(chunks: list[np.ndarray], start_sample: int, end_sample: int) -> np.ndarray:
    """Samples [start_sample, end_sample) of a chunked buffer, copying only
    that range. Joining every chunk first costs O(session) per segment: about
    230 MB per decode at the one-hour limit. WhisperBackend._audio_span
    slices the same way.
    """
    pieces: list[np.ndarray] = []
    cursor = 0
    for chunk in chunks:
        next_cursor = cursor + len(chunk)
        if cursor >= end_sample:
            break
        local_start = max(0, start_sample - cursor)
        local_end = min(len(chunk), end_sample - cursor)
        if local_start < local_end:
            pieces.append(chunk[local_start:local_end])
        cursor = next_cursor

    if not pieces:
        return np.empty(0, dtype=np.float32)
    if len(pieces) == 1:
        return pieces[0]
    return np.concatenate(pieces)


def _has_tracked_speech(audio: np.ndarray) -> bool:
    """Whether a fresh SilenceTracker, fed the app's 100 ms chunks, flags at
    least _MIN_SPAN_SPEECH_SAMPLES of this audio as speech."""
    chunk = SAMPLE_RATE // 10
    speech_samples = speech_window_fraction(audio, chunk) * len(audio)
    return speech_samples >= _MIN_SPAN_SPEECH_SAMPLES


def _clear_mlx_cache() -> None:
    """Return MLX's buffer cache to the OS; the model weights stay loaded.

    Decoding grows the cache to the largest working set (3.25 GB for a
    120 s window) and MLX keeps it for the life of the process otherwise.
    """
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:  # noqa: BLE001 — memory hygiene must never fail a session
        log.debug("mlx cache clear failed", exc_info=True)


class ParakeetBackend:
    """Parakeet-mlx STT that decodes each pause-bounded segment whole.

    Segments close on whisper's pause rule (MIN_SEGMENT_S of audio, then a
    SEGMENT_SILENCE_S pause), and past HARD_SEGMENT_S at the first 200 ms of
    quiet (see _segment_due). Audio with no quiet at all is never cut. The
    server cleans each segment while the user keeps talking; at stop only the
    tail is decoded. With Stream Typing on, previews decode the last
    PREVIEW_WINDOW_S of the open span about every 0.5 s.

        audio   |---- seg 1 ----|..|---- seg 2 ----|..|- tail -|
        decode                     ^ pause            ^ pause    ^ stop
        final   "seg 1 seg 2 tail"

    This replaced transcribe_stream fed in 0.5 s steps: its 256-frame
    attention context scored about 25% WER on Common Voice India, against
    about 10% for the same model decoding each clip whole.
    """

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self._model: Any = None
        # Segmenting surface (see STTBackend). Parakeet has no prompt input,
        # so the whisper glossary is ignored.
        self.initial_prompt: str | None = None
        self.segmenting_enabled = True  # transcribe_clip: one whole decode
        self.segments_used_for_final = False
        self.final_tail = ""
        # All PCM stays buffered: after a failed segment decode, finalize
        # recovers every word with one whole-clip decode.
        self._chunks: list[np.ndarray] = []
        self._samples = 0
        self._decoded_samples = 0  # offset of the first un-decoded sample
        self._segments: list[str] = []
        self._new_segments: list[str] = []
        self._silence = SilenceTracker()
        # Tracker-flagged speech since the last committed span. An empty
        # decode of a span with speech is not evidence that it was empty.
        self._span_speech_samples = 0
        self._retry_at_samples = 0  # backoff after an empty speech-span decode
        self._retry_wait_s = _EMPTY_SPAN_RETRY_S  # doubles per consecutive one
        # Display-only preview lane, driven by the server for Stream Typing.
        # Previews read the open span and never touch segment state.
        self.preview_enabled = False
        self._last_preview_samples = 0
        self._preview_had_new_speech = False
        self._preview_interval_s = _PARAKEET_PREVIEW_INTERVAL_S
        self._pending_preview: WhisperPreviewRequest | None = None
        self._segment_decode_failed = False

    def take_new_segments(self) -> list[str]:
        out = self._new_segments
        self._new_segments = []
        return out

    @property
    def _span_had_speech(self) -> bool:
        return self._span_speech_samples >= _MIN_SPAN_SPEECH_SAMPLES

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

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        self._chunks.append(chunk)
        self._samples += len(chunk)
        if self._silence.feed(chunk):
            self._span_speech_samples += len(chunk)
            self._preview_had_new_speech = True
        if self._model is None or not self.segmenting_enabled or self._segment_decode_failed:
            return None
        backing_off = self._samples < self._retry_at_samples
        if backing_off or not self._segment_due():
            self._queue_preview_if_due()
            return None

        # The segment decode supersedes any preview of the same open span.
        self._pending_preview = None
        end = self._samples
        try:
            text = self._transcribe(self._audio_span(self._decoded_samples, end))
        except Exception:  # noqa: BLE001 — a failed decode must not kill the feed loop
            log.exception("parakeet segment decode failed — decoding the whole clip at stop")
            self._segment_decode_failed = True
            return None

        if not text and self._span_had_speech:
            # Keep the span pending: the next close decodes it again with
            # more audio, or the tail decode at stop covers it.
            self._retry_at_samples = self._samples + int(self._retry_wait_s * SAMPLE_RATE)
            self._retry_wait_s = min(self._retry_wait_s * 2, _EMPTY_SPAN_RETRY_MAX_S)
            return None

        self._decoded_samples = end
        self._span_speech_samples = 0
        self._retry_wait_s = _EMPTY_SPAN_RETRY_S
        self._silence.consume_pause()  # the pause that closed this segment
        self._last_preview_samples = self._samples
        self._preview_had_new_speech = False
        if not text:
            return None  # a span without speech or words: consumed
        self._segments.append(text)
        self._new_segments.append(text)
        return " ".join(self._segments)

    def _segment_due(self) -> bool:
        """Whether the open span closes now, at the end of the audio (always
        inside a pause, so no word is split).

            open audio         needs
            >= MIN_SEGMENT_S   SEGMENT_SILENCE_S pause
            >= HARD_SEGMENT_S  _HARD_CUT_QUIET_S quiet
        """
        undecoded_s = (self._samples - self._decoded_samples) / SAMPLE_RATE
        silence_s = self._silence.trailing_silence_s
        if undecoded_s >= MIN_SEGMENT_S and silence_s >= SEGMENT_SILENCE_S:
            return True
        return undecoded_s >= HARD_SEGMENT_S and silence_s >= _HARD_CUT_QUIET_S

    def _queue_preview_if_due(self) -> None:
        """Replace the pending preview once enough new speech arrived.

        No model work here: the server decodes the request between feeds.
        Replacing rather than queueing means a slow decode always catches up
        to the newest audio instead of working through a backlog.
        """
        if not self.preview_enabled or not self._preview_had_new_speech:
            return
        new_s = (self._samples - self._last_preview_samples) / SAMPLE_RATE
        if new_s < self._preview_interval_s:
            return

        # The open span, capped like Whisper's to the last PREVIEW_WINDOW_S:
        # a span that never closes would otherwise make every preview decode
        # more audio. Copy it: finalize or reset may drop the chunks mid-decode.
        window_samples = int(PREVIEW_WINDOW_S * SAMPLE_RATE)
        start = max(self._decoded_samples, self._samples - window_samples)
        audio = np.array(self._audio_span(start, self._samples), copy=True)
        self._pending_preview = WhisperPreviewRequest(
            audio=audio,
            committed_segments=tuple(self._segments),
        )
        self._last_preview_samples = self._samples
        self._preview_had_new_speech = False

    def take_preview_request(self) -> WhisperPreviewRequest | None:
        request = self._pending_preview
        self._pending_preview = None
        return request

    def discard_preview_request(self) -> None:
        self._pending_preview = None

    def decode_preview(self, request: WhisperPreviewRequest) -> str | None:
        """Decode one display-only snapshot: committed segments plus the open
        span. The next preview waits for at least 1.5x this decode's time."""
        started = time.perf_counter()
        try:
            text = self._transcribe(request.audio)
        except Exception:  # noqa: BLE001 — a preview must not affect the final text
            log.exception("parakeet preview decode failed — final transcription remains available")
            return None
        finally:
            elapsed = time.perf_counter() - started
            self._preview_interval_s = min(
                PREVIEW_MAX_INTERVAL_S,
                max(_PARAKEET_PREVIEW_INTERVAL_S, elapsed * PREVIEW_BACKOFF),
            )
        if not text:
            return None
        return " ".join((*request.committed_segments, text))

    def _audio_span(self, start_sample: int, end_sample: int) -> np.ndarray:
        return _chunk_span(self._chunks, start_sample, end_sample)

    def finalize(self) -> str:
        self.segments_used_for_final = False
        self.final_tail = ""
        try:
            return self._final_text()
        finally:
            self.reset()

    def _final_text(self) -> str:
        """Committed segments plus the decoded tail, or one whole-clip decode
        when nothing was committed, segmenting failed, or the tail lost its
        words.

            committed   [seg 1][blank][seg 2]   decode the tail only
            nothing     [...............tail]   decode the whole clip

        No tracked speech is no reason to skip: Parakeet hears speakers below
        the tracker's floor, and has no integrity guard that discards their
        words the way Whisper's does.
        """
        if not self._decoded_samples or self._segment_decode_failed:
            return self._decode_whole_clip()

        try:
            tail = self._transcribe(self._audio_span(self._decoded_samples, self._samples))
        except Exception:  # noqa: BLE001 — the whole-clip decode below recovers
            log.exception("parakeet tail decode failed — decoding the whole clip")
            return self._decode_whole_clip()
        if not tail and self._span_had_speech:
            log.warning("empty parakeet tail over speech — decoding the whole clip")
            return self._decode_whole_clip()

        # Only a cleaned segment makes this a streamed result for the server.
        if self._segments:
            self.segments_used_for_final = True
            self.final_tail = tail
        return " ".join(self._segments + ([tail] if tail else []))

    def _decode_whole_clip(self) -> str:
        return self._transcribe(self._audio_span(0, self._samples))

    def _transcribe(self, audio: np.ndarray) -> str:
        """Decode one span; past _PARAKEET_WINDOW_S, in overlapping windows.

            span      0 ................................... 250 s
            window 1  [0 ......... 120)
            window 2           [105 ......... 225)
            window 3                     [210 ......... 250)
                                ^^^^^^^ decoded twice, merged once
        """
        if len(audio) < MIN_FINAL_AUDIO_S * SAMPLE_RATE:
            return ""

        window = int(_PARAKEET_WINDOW_S * SAMPLE_RATE)
        step = window - int(_PARAKEET_OVERLAP_S * SAMPLE_RATE)
        merged: list[_Token] = []
        prev_end = 0
        for start in range(0, len(audio), step):
            end = min(start + window, len(audio))
            offset_s = start / SAMPLE_RATE
            tokens = [
                _Token(t.text, t.start + offset_s, t.end + offset_s)
                for t in self._decode_tokens(audio[start:end])
            ]
            # An empty window over speech is a model failure, and the merge
            # would keep the other windows' words without a trace. No retry:
            # the whole-clip decode fails the same way. Log where it was.
            windowed = len(audio) > window
            if windowed and not tokens and _has_tracked_speech(audio[prev_end:end]):
                log.warning("parakeet window at %.1f s decoded empty over speech", offset_s)
            merged = _merge_overlap(
                merged,
                tokens,
                seam_start_s=offset_s,
                seam_end_s=prev_end / SAMPLE_RATE,
            )
            prev_end = end
            if end == len(audio):
                break
        return "".join(t.text for t in merged).strip()

    def _decode_tokens(self, audio: np.ndarray) -> list[_Token]:
        """The model call: one span in, span-relative tokens out."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        mel = get_logmel(mx.array(audio), self._model.preprocessor_config)
        result = self._model.generate(mel)[0]
        return [_Token(t.text, t.start, t.end) for t in result.tokens]

    def reset(self) -> None:
        had_audio = self._samples > 0
        self._chunks = []
        self._samples = 0
        self._decoded_samples = 0
        self._segments = []
        self._new_segments = []
        self._silence.reset()
        self._span_speech_samples = 0
        self._retry_at_samples = 0
        self._retry_wait_s = _EMPTY_SPAN_RETRY_S
        self._last_preview_samples = 0
        self._preview_had_new_speech = False
        self._preview_interval_s = _PARAKEET_PREVIEW_INTERVAL_S
        self._pending_preview = None
        self._segment_decode_failed = False
        # initial_prompt / segments_used_for_final / final_tail survive a reset:
        # the server reads the finalize flags after finalize() has reset.

        # Finalize and abort both end here. Release the session's decode
        # buffers now; between sessions they would only hold memory.
        if had_audio and self._model is not None:
            _clear_mlx_cache()


# --- whisper hallucination guard ---------------------------------------------

_COMPRESSION_RATIO_THRESHOLD = 2.4
_LOGPROB_THRESHOLD = -1.2
# mlx_whisper.transcribe's own fallback cut: a pass under this average log
# probability is decoded again at the next temperature (stock default).
_STOCK_LOGPROB_THRESHOLD = -1.0
# ...unless its no-speech probability is over this: stock treats it as
# silence and keeps it.
_STOCK_NO_SPEECH_THRESHOLD = 0.6
# One Whisper decode window (mlx_whisper.audio.N_SAMPLES, 30 s).
_WHISPER_WINDOW_SAMPLES = 30 * SAMPLE_RATE
_SPEECH_MODULATION_RATIO = 1.6
_SPEECH_FRAME_SAMPLES = SAMPLE_RATE // 50  # 20 ms
_SPEECH_ACTIVE_RMS = 0.003
# Minimum tracker-flagged speech for a span to be worth decoding at all.
_MIN_SPAN_SPEECH_SAMPLES = int(0.2 * SAMPLE_RATE)
# A decoded span must also REACH speaking level: its loudest frames (p95)
# at least this fraction of the session's adapted speech RMS. Breath and
# room-tone bumps measured 28-42% of speaking level in the field clips;
# deliberate trailing words reach well past half. Below this, decoded text
# is treated as fabricated — inserting a made-up sentence is strictly worse
# for dictation than dropping an inaudible trail-off.
_SPAN_SPEECH_LEVEL_RATIO = 0.5


def _reaches_speech_level(audio: np.ndarray, speech_level: float) -> bool:
    """True when a sustained 0.2 s of the span approaches speaking level.

    A percentile over the whole span makes the decision depend on duration: a
    one-second answer inside a minute-long meeting falls below p95 even though
    it is real speech. Key the gate to a fixed evidence window instead.
    """
    frame_count = len(audio) // _SPEECH_FRAME_SAMPLES
    evidence_frames = max(
        1, _MIN_SPAN_SPEECH_SAMPLES // _SPEECH_FRAME_SAMPLES
    )
    if frame_count < evidence_frames:
        return False
    framed = np.asarray(
        audio[: frame_count * _SPEECH_FRAME_SAMPLES], dtype=np.float32
    ).reshape(frame_count, _SPEECH_FRAME_SAMPLES)
    rms = np.sqrt(np.mean(np.square(framed, dtype=np.float64), axis=1))
    sustained_peak = float(np.partition(rms, -evidence_frames)[-evidence_frames])
    return sustained_peak >= max(
        _SPEECH_ACTIVE_RMS, _SPAN_SPEECH_LEVEL_RATIO * speech_level
    )


# The final ~0.3s of a recording is mechanically suspect: it holds the sound
# of the stop keypress itself, a loud transient that passes every energy gate
# and that Whisper happily decodes as "Thank you." (field bug, 2026-08-04).
_STOP_NOISE_SAMPLES = int(0.3 * SAMPLE_RATE)


def _tail_speech_evidence(audio: np.ndarray, speech_level: float) -> bool:
    """Does the recording tail carry real speech, ignoring stop-key noise?

    Evidence must be sustained (≥0.2s of frames over the tracker's silence
    threshold) AND reach speaking level (p95 ≥ 35% of the session's speech
    RMS) — measured on the tail minus its final 0.3s. A genuine trailing
    phrase sits earlier in the tail at full level; a keypress click lives
    exactly in that final window, and a word that started inside it was
    clipped by the stop anyway. Both cuts are relative to the session's own
    adapted speech level, never absolute."""
    evidence = audio[:-_STOP_NOISE_SAMPLES] if len(audio) > _STOP_NOISE_SAMPLES else audio[:0]
    frame_count = len(evidence) // _SPEECH_FRAME_SAMPLES
    if frame_count < 3:
        return False
    framed = np.asarray(
        evidence[: frame_count * _SPEECH_FRAME_SAMPLES], dtype=np.float32
    ).reshape(frame_count, _SPEECH_FRAME_SAMPLES)
    rms = np.sqrt(np.mean(np.square(framed, dtype=np.float64), axis=1))
    threshold = max(_SPEECH_ACTIVE_RMS, 0.15 * speech_level)
    sustained = float((rms >= threshold).sum()) * _SPEECH_FRAME_SAMPLES
    return (sustained >= _MIN_SPAN_SPEECH_SAMPLES
            and _reaches_speech_level(evidence, speech_level))


def _has_speech_like_modulation(audio: np.ndarray) -> bool:
    """Independent retry gate that rejects stationary fan/static/noise.

    Energy VAD alone only says a signal is loud enough. Speech has a changing
    amplitude envelope across 20 ms frames; steady tones and broadband noise do
    not. This deliberately gates only the optional second decode, never the
    authoritative first pass, so quiet/atypical speech quality is unchanged.
    """
    frame_count = len(audio) // _SPEECH_FRAME_SAMPLES
    if frame_count < 5:
        return False
    framed = np.asarray(
        audio[: frame_count * _SPEECH_FRAME_SAMPLES], dtype=np.float32
    ).reshape(frame_count, _SPEECH_FRAME_SAMPLES)
    rms = np.sqrt(np.mean(np.square(framed, dtype=np.float64), axis=1))
    active = rms[rms >= _SPEECH_ACTIVE_RMS]
    if active.size < 5:
        return False
    low = max(float(np.percentile(active, 20)), _SPEECH_ACTIVE_RMS)
    high = float(np.percentile(active, 90))
    return high / low >= _SPEECH_MODULATION_RATIO


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


def _text_compression_ratio(text: str) -> float:
    encoded = text.encode("utf-8")
    return len(encoded) / len(zlib.compress(encoded)) if encoded else 0.0


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
        # Drop non-text junk (e.g. "!!!!" runs) without rejecting valid
        # Devanagari/CJK/Arabic text from this multilingual model.
        if not any(char.isalnum() for char in seg_text):
            continue
        kept.append(seg_text)
    # If Whisper supplied segment metadata, never restore the aggregate after
    # every segment was explicitly rejected above. The aggregate is only a
    # compatibility fallback for upstream results with no segments at all.
    text = " ".join(kept).strip() if segments else (result.get("text") or "").strip()
    return _trim_repeated_tail(text)


def _stock_would_resample(seg: dict[str, Any]) -> bool:
    """True when mlx_whisper's default fallback would decode this segment's
    window again (transcribe.py:226-241). Segments of one window share
    that window's metadata, so any of them speaks for the window."""
    nsp = seg.get("no_speech_prob")
    if nsp is not None and nsp > _STOCK_NO_SPEECH_THRESHOLD:
        return False

    cr = seg.get("compression_ratio")
    lp = seg.get("avg_logprob")
    too_repetitive = cr is not None and cr > _COMPRESSION_RATIO_THRESHOLD
    too_unlikely = lp is not None and lp < _STOCK_LOGPROB_THRESHOLD
    return too_repetitive or too_unlikely


def _read_pass(
    result: dict[str, Any], prompt: str | None
) -> tuple[str, bool, bool]:
    """One decode pass as (text, prompt_failure, likely_speech).

    `prompt_failure` is a glossary loop or prompt echo the guards removed;
    `likely_speech` is any text segment under stock's no-speech cut."""
    guarded_text = guard_whisper_result(result)
    # Every segment/preview needs the leading-header guard, but applying the
    # trailing-list guard independently at every seam creates many chances
    # to delete a genuine spoken list. The trailing guard runs once on the
    # assembled authoritative final in `finalize`.
    text = strip_prompt_echo(guarded_text, prompt, allow_trailing=False)

    segments = result.get("segments") or []
    prompt_echo_removed = bool(guarded_text) and not text
    quality_rejected = any(
        (seg.get("text") or "").strip()
        and (
            (seg.get("compression_ratio") is not None
             and seg["compression_ratio"] > _COMPRESSION_RATIO_THRESHOLD)
            or (
                seg.get("avg_logprob") is not None
                and seg["avg_logprob"] < _LOGPROB_THRESHOLD
                and seg.get("compression_ratio") is not None
                and seg["compression_ratio"] > 2.0
            )
        )
        for seg in segments
    )
    likely_speech = not segments or any(
        (seg.get("text") or "").strip()
        and (seg.get("no_speech_prob") is None or seg["no_speech_prob"] < 0.6)
        for seg in segments
    )
    return text, prompt_echo_removed or quality_rejected, likely_speech


def _glossary_terms_in(text: str, prompt: str | None) -> set[str]:
    """The glossary terms `text` contains, lowercased. A term matches
    case-insensitively on word boundaries: "Airlearn" matches "airlearn",
    not "Airlearns" or "air learn"."""
    if not prompt:
        return set()

    body = re.sub(r"^\s*Glossary:\s*", "", prompt, flags=re.IGNORECASE).strip()
    terms = [term.strip() for term in body.rstrip(".").split(",") if term.strip()]
    return {
        term.lower()
        for term in terms
        if re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text, re.IGNORECASE)
    }


def _retry_wins(
    text: str,
    text_score: float | None,
    retry_text: str,
    retry: dict[str, Any],
    prompt: str | None,
) -> bool:
    """True when a prompt-free retry may replace clean glossary `text`: at
    least as many words, every glossary term `text` carries, and a higher
    weakest-segment logprob (a tie keeps the glossary spelling)."""
    if len(retry_text.split()) < len(text.split()):
        return False
    if not _glossary_terms_in(text, prompt) <= _glossary_terms_in(retry_text, prompt):
        return False

    retry_score = _min_segment_logprob(retry)
    if retry_score is None or text_score is None:
        return False
    return retry_score > text_score


def _log_unsure(score: float | None, outcome: str) -> None:
    # Numbers and the outcome only: engine.log is plaintext.
    log.info(
        "greedy glossary decode unsure (logprob=%.2f, %s)",
        score if score is not None else float("nan"), outcome)


def _min_segment_logprob(result: dict[str, Any]) -> float | None:
    """The weakest text segment's avg_logprob; None when none is scored.

    A pass is only as trustworthy as its least likely segment, e.g.
    segments at -0.3 and -1.4 score -1.4."""
    scores = [
        seg["avg_logprob"]
        for seg in result.get("segments") or []
        if (seg.get("text") or "").strip() and seg.get("avg_logprob") is not None
    ]
    if not scores:
        return None
    return min(scores)


def whisper_language(language: str | None) -> str | None:
    """Map config `language` to mlx-whisper's arg: "auto"/empty → None (autodetect)."""
    if not language:
        return None
    language = language.strip()
    if not language or language.lower() == "auto":
        return None
    return language


# Top-language probability at which first-window detection is trusted.
# Below it (short or noisy clips, near chance) the zero-padded window and
# stock's silence-padded clip can disagree, so stock decides instead.
_SURE_LANGUAGE_P = 0.5


class _EncodingMemo:
    """The last Whisper encoder pass as (mel window, encoding), or None.

    A plain object on purpose: MLX modules register tuple and array
    attributes as parameters, so the pair cannot live on the encoder."""

    __slots__ = ("entry",)

    def __init__(self) -> None:
        self.entry: tuple[Any, Any] | None = None


@functools.cache
def _memo_encoder_class() -> type:
    """AudioEncoder that returns its previous encoding for an equal window.

    Built on first use because the engine imports MLX lazily. The encoder
    is deterministic, so a hit returns exactly what a fresh pass would:

        detect_language(window) ─encode─▶ memo ◀─hit─ decode(window)
                                               ◀─hit─ temperature fallbacks
    """
    import mlx.core as mx
    from mlx_whisper.whisper import AudioEncoder

    class MemoEncoder(AudioEncoder):
        def __call__(self, x: Any) -> Any:
            # Hit: same window as the last pass. Shape and dtype first so
            # a mismatch never pays for the element-wise compare.
            entry = self.memo.entry
            if entry is not None:
                seen, encoded = entry
                if seen is x or (
                    seen.shape == x.shape
                    and seen.dtype == x.dtype
                    and mx.array_equal(seen, x).item()
                ):
                    return encoded

            encoded = super().__call__(x)
            self.memo.entry = (x, encoded)
            return encoded

    return MemoEncoder


def _install_encoder_memo(model: Any) -> _EncodingMemo:
    """Make `model.encoder` reuse its last pass; return that pass's slot.

    Swapping the instance's class keeps the parameter tree untouched, so
    the loaded weights and ModelHolder's cache stay as they are."""
    memo_class = _memo_encoder_class()
    encoder = model.encoder
    if not isinstance(encoder, memo_class):
        encoder.__class__ = memo_class
        encoder.memo = _EncodingMemo()
    return encoder.memo


def _detect_on_first_window(model: Any, audio: np.ndarray) -> str | None:
    """Detect the language on the exact window the first decode will see.

    Stock mlx-whisper detects on the silence-padded clip, which differs
    from the decode window, so the two cannot share an encoding. This
    rebuilds the first window the way `transcribe` does (log-mel padded by
    30 s, first ≤30 s of content, zero-padded to 3000 frames, fp16), so
    the decode's encoder call hits the memo. English-only models return
    None and let `transcribe` pick "en" without detecting.

    An unsure answer (below `_SURE_LANGUAGE_P`) is replaced by stock's own
    detection, so an unsure clip decodes in the same language as before
    at stock's cost of one extra pass. On 838 archived dictations the two
    inputs disagreed on 3 clips, all with top p ≤ 0.40; at 0.5, 24 clips
    (2.9%) fall back and no disagreement remains."""
    import mlx.core as mx
    from mlx_whisper.audio import N_FRAMES, N_SAMPLES, log_mel_spectrogram, pad_or_trim

    if not model.is_multilingual:
        return None

    mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
    content_frames = mel.shape[-2] - N_FRAMES
    window = mel[: min(N_FRAMES, content_frames)]
    window = pad_or_trim(window, N_FRAMES, axis=-2).astype(mx.float16)
    _, probs = model.detect_language(window)
    language = max(probs, key=probs.get)
    if probs[language] >= _SURE_LANGUAGE_P:
        return language

    stock_window = pad_or_trim(mel, N_FRAMES, axis=-2).astype(mx.float16)
    _, probs = model.detect_language(stock_window)
    return max(probs, key=probs.get)


@contextlib.contextmanager
def _encoding_once(
    model_path: str, audio: np.ndarray, language: str | None
) -> Iterator[str | None]:
    """Scope one decode in which the loaded model encodes each window once.

    Yields the language to decode with: `language` itself when fixed,
    else detected on the first decode window. The memo is emptied on the
    way out, detection failures included, so no encoding outlives it."""
    import mlx.core as mx
    from mlx_whisper.transcribe import ModelHolder

    model = ModelHolder.get_model(model_path, mx.float16)
    memo = _install_encoder_memo(model)
    try:
        if language is None:
            language = _detect_on_first_window(model, audio)
        yield language
    finally:
        memo.entry = None


class WhisperBackend:
    """Batch STT via mlx-whisper, with hallucination guard and in-session
    segmenting: pause-aligned spans are decoded DURING recording so the server
    can clean them concurrently (and the HUD finally gets whisper partials)."""

    # One greedy glossary pass per one-window decode (see _decode). Catching
    # an unsure pass needs per-segment avg_logprob in the result.
    _greedy_glossary_pass = True

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
        self._speech_rms = np.empty(0, dtype=np.float64)
        self._speech_rms_chunks = 0
        self._speech_p90 = 0.0
        # Samples of tracker-flagged speech since the last decode point. A
        # span only counts as speech-bearing past a sustained run — a single
        # 100 ms room-tone blip over the adaptive threshold used to arm the
        # tail decode, and Whisper turned that pause into "Thank you." /
        # "Closed Captioning by ..." credits (field bug, 2026-08-04).
        self._span_speech_samples = 0
        self._session_had_speech = False  # speech seen anywhere in the buffered clip
        self._retry_at_samples = 0  # backoff cursor after an empty speech-span decode
        self.preview_enabled = False
        self._last_preview_samples = 0
        self._preview_had_new_speech = False
        self._preview_interval_s = PREVIEW_BASE_INTERVAL_S
        self._pending_preview: WhisperPreviewRequest | None = None
        # Sticky per-session kill switch: one failed segment decode degrades
        # the whole session to today's batch path (never raise into the feed).
        self._segment_decode_failed = False
        # Read by the server right after finalize() (see STTBackend Protocol).
        self.segments_used_for_final = False
        self.final_tail = ""

    def load(self) -> None:
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        from .models import ensure_downloaded

        self._model_path = ensure_downloaded(self.model_id)
        t0 = time.perf_counter()
        # Warm the same holder used by mlx_whisper.transcribe. Loading a throwaway
        # model here made the first real decode allocate/load all weights again.
        model = ModelHolder.get_model(self._model_path, mx.float16)
        mx.eval(model.parameters())
        self._loaded = True
        log.info("whisper weights warmed %s in %.2fs", self.model_id, time.perf_counter() - t0)

    def start_session(self) -> None:
        self.reset()
        self.segments_used_for_final = False
        self.final_tail = ""

    @property
    def _span_had_speech(self) -> bool:
        """Speech-bearing span = a sustained run, not one borderline chunk.

        0.2 s is far below any real word's above-threshold footprint in a
        ≥10 s segment span or a pause tail, but above the isolated breath /
        room-tone blips that sit just over the adaptive silence threshold."""
        return self._span_speech_samples >= _MIN_SPAN_SPEECH_SAMPLES

    def _speech_reference(self) -> float:
        """Speaking-level reference for the fabrication gates.

        The tracker's EMA alone cannot be trusted here: quiet speech walks it
        down, then the absolute floor lets breath and room tone keep feeding
        it, and it ratchets to the noise floor (measured 0.009 after a 50 s
        dictation whose speech ran 0.02-0.15). The p90 of 20 ms frame RMS
        over the whole buffered recording sits inside actual speech for any
        real dictation, so the gates key off the louder of the two."""
        # Buffered PCM is immutable. Analyze each chunk once and retain only
        # its frame RMS (400 bytes/second), preserving the exact percentile
        # and per-chunk framing used by the speech guards.
        if self._speech_rms_chunks == len(self._chunks):
            return max(self._silence.speech_level, self._speech_p90)

        rms_parts = [self._speech_rms]
        for index in range(self._speech_rms_chunks, len(self._chunks)):
            chunk = self._chunks[index]
            frame_count = len(chunk) // _SPEECH_FRAME_SAMPLES
            if frame_count:
                framed = np.asarray(
                    chunk[: frame_count * _SPEECH_FRAME_SAMPLES],
                    dtype=np.float32,
                ).reshape(frame_count, _SPEECH_FRAME_SAMPLES)
                rms_parts.append(
                    np.sqrt(np.mean(np.square(framed, dtype=np.float64), axis=1))
                )
        self._speech_rms_chunks = len(self._chunks)
        if len(rms_parts) > 1:
            self._speech_rms = np.concatenate(rms_parts)
            self._speech_p90 = float(np.percentile(self._speech_rms, 90))
        return max(self._silence.speech_level, self._speech_p90)

    def _transcribe(
        self,
        audio: np.ndarray,
        initial_prompt: str | None,
        *,
        temperature: float | None = None,
    ) -> dict[str, Any]:
        """Run one engine decode and return the mlx-whisper result shape.

        Each audio window is encoded once. Stock auto-language encodes the
        first window twice (detect, then decode) and re-encodes it on every
        temperature fallback; the encoder is ~40% of a dictation's decode.
        """
        import mlx_whisper

        options: dict[str, Any] = {}
        if temperature is not None:
            options["temperature"] = temperature

        with _encoding_once(
            self._model_path, audio, whisper_language(self.language)
        ) as language:
            return mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=self._model_path,
                condition_on_previous_text=False,
                language=language,
                fp16=True,
                initial_prompt=initial_prompt,
                **options,
            )

    def _decode(
        self,
        audio: np.ndarray,
        *,
        had_speech: bool | None = None,
        ignore_stop_tail: bool = False,
    ) -> str:
        """One guarded Whisper decode (segment, tail, or whole clip)."""
        if had_speech is None:
            had_speech = self._span_had_speech
        # The backend is shared by live and file transcription. Snapshot
        # session-scoped decode options before model work so another session
        # cannot change how this result is stripped or retried mid-decode.
        prompt = self.initial_prompt

        integrity_audio = (
            audio[:-_STOP_NOISE_SAMPLES]
            if ignore_stop_tail and len(audio) > _STOP_NOISE_SAMPLES
            else audio
        )
        if not had_speech or not _reaches_speech_level(
            integrity_audio, self._speech_reference()
        ):
            # The dual of the empty-speech-span integrity rule in feed_chunk:
            # text decoded from a span that never carried sustained,
            # speaking-level audio is fabricated. This is where "Thank you." /
            # "Closed Captioning by ..." credits enter — Whisper decoding a
            # trailing pause or breath bump with confident metadata
            # (nsp=0.00, clean logprob/compression), so no metadata threshold
            # can catch it (field bug, 2026-08-04). Both gates are relative
            # to the session's own adapted speech level, never absolute.
            #
            # The verdict reads only the audio, so it runs before the model:
            # room tone plus a stop-key click used to pay a glossary decode
            # looping through every temperature fallback (7.4 s stop→text)
            # just to have its text discarded here.
            log.info(
                "whisper guard: skipped decode of a speechless span (%.1fs audio)",
                len(audio) / SAMPLE_RATE)
            return ""

        # Stock fallback re-decodes a failed window at five more
        # temperatures, all still primed with the glossary. On short clips
        # those passes loop on the glossary to the 224-token cap (~1 s
        # each) and never supplied the kept text: the prompt-free retry
        # below did (field trace, 2026-09-26). A one-window decode, which
        # that retry covers whole, gets a single greedy glossary pass:
        #
        #   before: glossary t=0 → 0.2 → … → 1.0 ──────→ prompt-free t=0
        #   after:  glossary t=0 ── failed or unsure? ─→ prompt-free t=0
        #                          (stock ladder when that cannot settle it)
        #
        # Longer audio keeps the stock schedule: one looping window among
        # several leaves text behind, so the retry would never run for it.
        greedy_prompt = (
            self._greedy_glossary_pass
            and bool(prompt)
            and len(audio) <= _WHISPER_WINDOW_SAMPLES
        )
        result = self._transcribe(
            audio, prompt, temperature=0.0 if greedy_prompt else None
        )

        # Audio under 30 s can still decode as several windows: one with no
        # closing timestamp restarts at its last timestamp (mlx_whisper
        # transcribe.py:382-390). A window stock would have re-sampled beside
        # a clean window with text goes back through the stock ladder (the
        # 0.25.0 path) rather than cost that window's words. When every
        # window failed there is no text to lose, and the ladder only
        # re-sampled the loop (7-20 s on a 4.7 s bench clip, once as words
        # in another language), so the clip is handled as one window below.
        #
        #   window 1 ok ─┬─ window 2 ok ─────→ keep greedy result
        #                └─ window 2 failed ─→ glossary t=0 → 0.2 → … → 1.0
        #   every window failed ─────────────→ as one window (retry below)
        segments = result.get("segments") or []
        failed = {seg.get("seek", 0) for seg in segments if _stock_would_resample(seg)}
        clean = {
            seg.get("seek", 0) for seg in segments if (seg.get("text") or "").strip()
        } - failed
        if greedy_prompt and failed and clean:
            log.info(
                "greedy glossary decode failed %d of %d windows — re-decoding on stock fallback",
                len(failed), len(failed | clean))
            greedy_prompt = False
            result = self._transcribe(audio, prompt)
        text, prompt_failure, likely_speech = _read_pass(result, prompt)
        may_retry = bool(prompt) and had_speech
        # At most one prompt-free retry per decode. `retry` is None when it
        # has not run or failed; `retried` keeps a failed one from rerunning.
        retried = False
        retry: dict[str, Any] | None = None

        # A greedy glossary pass stock fallback would have re-sampled is
        # unsure: short speech scored -1.1 to -1.2 with the glossary and -0.2
        # to -0.9 without it on the same audio, and steady hum scored -2.0
        # (field trace). A logprob alone never empties it. The prompt-free
        # retry may replace clean text only with at least as many words,
        # every glossary term the text carries, and a higher score (mlx
        # averages logprob per token, so a fragment can outscore the whole).
        # Clean text at or above the guard's -1.2 floor then stands; a loop
        # or echo the retry heard nothing in is silence; anything else goes
        # back through the stock ladder, the 0.25.0 path.
        #
        #   unsure pass ─┬─ retry wins ─────────────────────→ retry text
        #                ├─ clean text, logprob >= -1.2 ────→ glossary text
        #                ├─ loop or echo, retry heard none ─→ ""
        #                └─ otherwise ─→ glossary t=0 → 0.2 → … → 1.0
        unsure = greedy_prompt and any(
            (seg.get("text") or "").strip() and _stock_would_resample(seg)
            for seg in result.get("segments") or []
        )
        if unsure:
            score = _min_segment_logprob(result)
            clean_text = bool(text) and not prompt_failure
            if likely_speech and may_retry and _has_speech_like_modulation(audio):
                retried = True
                retry = self._retry_without_prompt(audio)
            retry_text = guard_whisper_result(retry) if retry is not None else ""

            if retry_text and (
                not clean_text or _retry_wins(text, score, retry_text, retry, prompt)
            ):
                _log_unsure(score, "retry")
                return retry_text
            if clean_text and score is not None and score >= _LOGPROB_THRESHOLD:
                _log_unsure(score, "kept")
                return text
            if not text and retry is not None:
                _log_unsure(score, "dropped")
                return ""

            _log_unsure(score, "ladder")
            result = self._transcribe(audio, prompt)
            text, prompt_failure, likely_speech = _read_pass(result, prompt)

        if (
            not text
            and may_retry
            and likely_speech
            and prompt_failure
        ):
            # A glossary prompt can trap Whisper in a high-compression prompt
            # loop or return a clean-looking prompt echo on short/quiet speech.
            # Retry only those explicit failures; energy alone is too weak and
            # could turn background noise into invented words. A retry the
            # unsure pass above already ran is reused, not decoded again.
            if not retried and _has_speech_like_modulation(audio):
                retried = True
                retry = self._retry_without_prompt(audio)
            if retry is not None:
                text = guard_whisper_result(retry)
        return text

    def _retry_without_prompt(self, audio: np.ndarray) -> dict[str, Any] | None:
        """One greedy decode without the glossary; None when it fails."""
        log.warning("glossary-biased whisper decode rejected/empty — retrying without prompt")
        try:
            return self._transcribe(audio, None, temperature=0.0)
        except Exception:  # noqa: BLE001 — optional recovery must not fail the session
            log.exception("prompt-free whisper recovery decode failed")
            return None

    def _strip_final_prompt_echo(self, text: str) -> str:
        stripped = strip_prompt_echo(text, self.initial_prompt, allow_trailing=True)
        if stripped != text.strip():
            log.warning(
                "whisper final prompt-tail echo removed (%d chars)",
                len(text.strip()) - len(stripped),
            )
        return stripped

    def _audio_span(self, start_sample: int, end_sample: int) -> np.ndarray:
        """Materialize only the requested sample range from buffered chunks.

        Preview and committed-segment decodes need only the uncommitted tail.
        Concatenating every chunk accumulated in a long recording before
        slicing that tail caused avoidable O(total recording) copies on each
        preview. Whole-clip finalize still concatenates once by design.
        """
        start = max(0, start_sample)
        end = min(max(start, end_sample), self._samples)
        if start >= end or not self._chunks:
            return np.empty(0, dtype=np.float32)

        pieces: list[np.ndarray] = []
        cursor = 0
        for chunk in self._chunks:
            next_cursor = cursor + len(chunk)
            if next_cursor <= start:
                cursor = next_cursor
                continue
            if cursor >= end:
                break
            local_start = max(0, start - cursor)
            local_end = min(len(chunk), end - cursor)
            if local_start < local_end:
                pieces.append(chunk[local_start:local_end])
            cursor = next_cursor

        if not pieces:
            return np.empty(0, dtype=np.float32)
        if len(pieces) == 1:
            return pieces[0]
        return np.concatenate(pieces)

    def feed_chunk(self, chunk: np.ndarray) -> str | None:
        self._chunks.append(chunk)
        self._samples += len(chunk)
        if self._silence.feed(chunk):
            self._span_speech_samples += len(chunk)
            self._session_had_speech = True
            self._preview_had_new_speech = True
        if not self._loaded or not self.segmenting_enabled or self._segment_decode_failed:
            return None
        if self._samples < self._retry_at_samples:
            return None  # backing off after an empty decode of a speech span
        undecoded_s = (self._samples - self._decoded_samples) / SAMPLE_RATE
        pause_close = undecoded_s >= MIN_SEGMENT_S and self._silence.trailing_silence_s >= SEGMENT_SILENCE_S
        commit_due = pause_close or undecoded_s >= HARD_SEGMENT_S
        if not commit_due:
            self._queue_preview_if_due(undecoded_s)
            return None
        # A committed decode supersedes any display-only snapshot of the same
        # uncommitted span. The server may still be finishing an older request;
        # its current-session guard prevents a stale result after stop/cancel.
        self._pending_preview = None
        try:
            span = self._audio_span(self._decoded_samples, self._samples)
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
        self._span_speech_samples = 0
        self._last_preview_samples = self._samples
        self._preview_had_new_speech = False
        if not text:
            return None  # true silence-only span — consumed, nothing to say
        self._segments.append(text)
        self._new_segments.append(text)
        return " ".join(self._segments)

    def _queue_preview_if_due(self, undecoded_s: float) -> None:
        """Replace the pending HUD snapshot when enough useful audio arrived.

        This method performs no model work. Replacing rather than appending is
        the coalescing contract: a slow device always decodes the newest view
        instead of building a backlog of obsolete previews.
        """
        if not self.preview_enabled or not self._preview_had_new_speech:
            return
        new_preview_s = (self._samples - self._last_preview_samples) / SAMPLE_RATE
        first_in_span = self._last_preview_samples <= self._decoded_samples
        first_due = first_in_span and undecoded_s >= PREVIEW_FIRST_S
        pause_due = (
            undecoded_s >= PREVIEW_MIN_SPAN_S
            and self._silence.trailing_silence_s >= PREVIEW_PAUSE_S
            and new_preview_s >= PREVIEW_MIN_NEW_S
        )
        interval_due = not first_in_span and new_preview_s >= self._preview_interval_s
        if not (first_due or pause_due or interval_due):
            return

        window_samples = int(PREVIEW_WINDOW_S * SAMPLE_RATE)
        start = max(self._decoded_samples, self._samples - window_samples)
        # Always own the snapshot: reset/finalize may release the backend's
        # chunk list while an already-scheduled preview is still completing.
        audio = np.array(self._audio_span(start, self._samples), copy=True)
        if audio.size == 0:
            return
        self._pending_preview = WhisperPreviewRequest(
            audio=audio,
            committed_segments=tuple(self._segments),
        )
        self._last_preview_samples = self._samples
        self._preview_had_new_speech = False
        log.debug(
            "whisper preview queued span_ms=%d window_ms=%d committed_samples=%d",
            int(undecoded_s * 1000),
            int(len(audio) / SAMPLE_RATE * 1000),
            self._decoded_samples,
        )

    def take_preview_request(self) -> WhisperPreviewRequest | None:
        request = self._pending_preview
        self._pending_preview = None
        return request

    def discard_preview_request(self) -> None:
        self._pending_preview = None

    def decode_preview(self, request: WhisperPreviewRequest) -> str | None:
        """Decode one immutable HUD request without touching final STT state."""
        started = time.perf_counter()
        try:
            # Previews are queued only after the tracker heard new speech, but
            # by decode time a committed segment may have consumed the span
            # flag — pass True so the HUD lane never loses a frame to the
            # speechless-span guard (it is display-only, never stitched).
            text = self._decode(request.audio, had_speech=True)
        except Exception:  # noqa: BLE001 — optional preview must not affect final STT
            log.exception("preview decode failed — final transcription remains available")
            return None
        finally:
            elapsed = time.perf_counter() - started
            self._preview_interval_s = min(
                PREVIEW_MAX_INTERVAL_S,
                max(PREVIEW_BASE_INTERVAL_S, elapsed * PREVIEW_BACKOFF),
            )
        if not text:
            return None
        log.debug(
            "whisper preview emitted decode_ms=%d window_ms=%d next_interval_ms=%d",
            int(elapsed * 1000),
            int(len(request.audio) / SAMPLE_RATE * 1000),
            int(self._preview_interval_s * 1000),
        )
        return " ".join((*request.committed_segments, text)).strip()

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
        duration_s = self._samples / SAMPLE_RATE
        if duration_s < MIN_FINAL_AUDIO_S:
            log.info("whisper clip too short to decode (%d samples)", self._samples)
            self.reset()
            return ""
        if not self._session_had_speech and not self._segments:
            # _decode's post-model integrity guard always discards text from
            # this exact state. Skip the expensive call instead; archived
            # meeting tracks can otherwise spend minutes decoding pure silence
            # one chunk at a time only to throw every result away.
            log.debug(
                "whisper skipped %.1fs batch with no tracked speech", duration_s
            )
            self.reset()
            return ""
        # Long dictation with usable segments: decode only the un-decoded tail
        # and stitch — stop→final stays flat however long the user spoke. Short
        # and medium clips re-decode WHOLE, exactly like the pre-segmenting
        # code, so their quality is unchanged (segments were preview-only).
        if duration_s > LONG_DICTATION_S and self._segments and not self._segment_decode_failed:
            try:
                tail_audio = self._audio_span(self._decoded_samples, self._samples)
                # A tail without real speech evidence is the pause the user
                # stopped on plus the stop-key transient — decoding it is
                # where trailing hallucinations came from, and skipping it
                # saves the decode.
                tail_worth_decoding = bool(len(tail_audio)) and _tail_speech_evidence(
                    tail_audio, self._speech_reference())
                # had_speech=True: the audio evidence above is the stronger,
                # stop-noise-aware form of the same judgment — re-applying the
                # chunk counter inside _decode could only contradict it.
                tail = (self._decode(tail_audio, had_speech=True)
                        if tail_worth_decoding else "")
            except Exception:  # noqa: BLE001 — fall through to the whole-clip decode
                log.exception("tail decode failed — re-decoding the whole clip")
            else:
                if tail or not tail_worth_decoding:
                    parts = self._segments + ([tail] if tail else [])
                    text = self._strip_final_prompt_echo(" ".join(parts).strip())
                    self.reset()
                    self.segments_used_for_final = True
                    self.final_tail = tail
                    return text
                # Same integrity rule as a live segment: an empty decode over a
                # speech-bearing span is not evidence that the span was empty.
                # Re-decode the whole clip instead of silently dropping it.
                log.warning("empty speech-bearing whisper tail — re-decoding the whole clip")
        if duration_s > 60:
            log.warning("whisper batch transcribe of %.0fs of audio — expect high stop→final latency", duration_s)
        audio = np.concatenate(self._chunks)
        try:
            text = self._strip_final_prompt_echo(
                self._decode(
                    audio,
                    had_speech=self._session_had_speech,
                    ignore_stop_tail=True,
                )
            )
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
        self._speech_rms = np.empty(0, dtype=np.float64)
        self._speech_rms_chunks = 0
        self._speech_p90 = 0.0
        self._segment_decode_failed = False
        self._span_speech_samples = 0
        self._session_had_speech = False
        self._retry_at_samples = 0
        self._last_preview_samples = 0
        self._preview_had_new_speech = False
        self._preview_interval_s = PREVIEW_BASE_INTERVAL_S
        self._pending_preview = None
        # NOTE: initial_prompt / segments_used_for_final / final_tail survive a
        # reset on purpose — the server sets the prompt per session and reads
        # the finalize flags right after finalize() has reset the audio state.


class TranscribeCppWhisperBackend(WhisperBackend):
    """Whisper Q8 through transcribe.cpp, retaining Velora's session logic."""

    fallback_model_id = "mlx-community/whisper-large-v3-turbo"
    # Results carry no avg_logprob, so an unsure greedy glossary pass could
    # not be caught; keep transcribe.cpp's own fallback ladder.
    _greedy_glossary_pass = False

    def __init__(self, model_id: str, language: str = "auto") -> None:
        super().__init__(model_id, language)
        self._native_model: Any = None
        self._native_session: Any = None

    def load(self) -> None:
        from transcribe_cpp import Model

        from .models import ensure_downloaded

        self._model_path = ensure_downloaded(self.model_id)
        t0 = time.perf_counter()
        self._native_model = Model(self._model_path)
        self._native_session = self._native_model.session()
        self._loaded = True
        log.info(
            "transcribe.cpp whisper weights loaded %s in %.2fs",
            self.model_id,
            time.perf_counter() - t0,
        )

    def close(self) -> None:
        """Release native handles explicitly on their owning STT thread."""
        session, self._native_session = self._native_session, None
        model, self._native_model = self._native_model, None
        self._loaded = False
        try:
            if session is not None:
                session.close()
        finally:
            if model is not None:
                model.close()

    def _transcribe(
        self,
        audio: np.ndarray,
        initial_prompt: str | None,
        *,
        temperature: float | None = None,
    ) -> dict[str, Any]:
        from transcribe_cpp import WhisperRunOptions

        if self._native_session is None:
            raise RuntimeError("transcribe.cpp backend is not loaded")
        options: dict[str, Any] = {
            "initial_prompt": initial_prompt,
            "condition_on_prev_tokens": False,
        }
        if temperature is not None:
            options["temperature"] = temperature
            # Shared prompt recovery requests deterministic temperature zero.
            # transcribe.cpp otherwise keeps its default +0.2 fallback ladder.
            options["temperature_inc"] = 0.0
        result = self._native_session.run(
            np.ascontiguousarray(audio, dtype=np.float32),
            language=whisper_language(self.language),
            timestamps="segment",
            family=WhisperRunOptions(**options),
        )
        # transcribe.cpp applies Whisper's compression/logprob/no-speech
        # thresholds internally. Its stable Python Result exposes accepted
        # segment text but not per-window trace values, so retain Velora's
        # text-level junk/echo/repetition guards over that accepted surface.
        return {
            "text": result.text,
            "segments": [
                {
                    "text": segment.text,
                    # Match mlx-whisper's public compression metric so the
                    # existing >2.4 hallucination guard stays engine-neutral.
                    "compression_ratio": _text_compression_ratio(segment.text),
                }
                for segment in result.segments
            ],
        }


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
    from .models import lookup

    info = lookup(model_id)
    if info is not None and info.backend == "transcribe-cpp":
        return TranscribeCppWhisperBackend(model_id, language)
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
