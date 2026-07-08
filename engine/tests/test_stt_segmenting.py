"""In-session segmenting (smartness-v2 §2/§4): SilenceTracker energy VAD,
WhisperBackend segment closing/stitching (with a monkeypatched mlx_whisper —
tests never load MLX), glossary prompt building, and the prompt-echo guard."""

import sys
import types

import numpy as np
import pytest

from velora_engine.stt import (
    HARD_SEGMENT_S,
    LONG_DICTATION_S,
    MIN_SEGMENT_S,
    SAMPLE_RATE,
    SEGMENT_SILENCE_S,
    FakeBackend,
    SilenceTracker,
    WhisperBackend,
    build_glossary_prompt,
    strip_prompt_echo,
    transcribe_clip,
)

CHUNK = SAMPLE_RATE // 10  # 100ms feed chunks, like the app sends


def loud(amplitude: float = 0.1) -> np.ndarray:
    return np.full(CHUNK, amplitude, dtype=np.float32)


def quiet() -> np.ndarray:
    return np.zeros(CHUNK, dtype=np.float32)


# ---- SilenceTracker ----------------------------------------------------------


def test_silence_tracker_counts_trailing_silence():
    t = SilenceTracker()
    for _ in range(5):
        t.feed(loud())
    assert t.trailing_silence_s == 0.0
    for i in range(7):
        t.feed(quiet())
    assert t.trailing_silence_s == pytest.approx(0.7)
    # speech resets the run
    t.feed(loud())
    assert t.trailing_silence_s == 0.0


def test_silence_tracker_ema_adapts_threshold():
    # Fresh tracker: 0.05 RMS is way above the initial threshold → speech.
    t = SilenceTracker()
    t.feed(loud(0.05))
    assert t.trailing_silence_s == 0.0
    # After sustained loud speech the EMA rises and 0.05 now reads as silence.
    t2 = SilenceTracker()
    for _ in range(50):
        t2.feed(loud(0.5))
    t2.feed(loud(0.05))
    assert t2.trailing_silence_s > 0.0


def test_silence_tracker_reset():
    t = SilenceTracker()
    for _ in range(50):
        t.feed(loud(0.5))
    t.feed(quiet())
    assert t.trailing_silence_s > 0
    t.reset()
    assert t.trailing_silence_s == 0.0
    # EMA is back at its start value: 0.05 counts as speech again.
    t.feed(loud(0.05))
    assert t.trailing_silence_s == 0.0


# ---- WhisperBackend segmenting (fake mlx_whisper) ------------------------------


class FakeWhisper:
    """Captures transcribe() calls; returns queued texts (last one repeats)."""

    def __init__(self, texts):
        self.texts = list(texts)
        self.calls = []  # (n_samples, kwargs)
        self.fail_next = 0

    def transcribe(self, audio, **kwargs):
        if self.fail_next > 0:
            self.fail_next -= 1
            raise RuntimeError("decode boom")
        self.calls.append((len(audio), kwargs))
        text = self.texts.pop(0) if len(self.texts) > 1 else self.texts[0]
        return {"text": text, "segments": [{"text": text}]}


@pytest.fixture
def whisper(monkeypatch):
    def make(texts):
        fake = FakeWhisper(texts)
        mod = types.ModuleType("mlx_whisper")
        mod.transcribe = fake.transcribe
        monkeypatch.setitem(sys.modules, "mlx_whisper", mod)
        backend = WhisperBackend("mlx-community/whisper-large-v3-turbo", "auto")
        backend._loaded = True  # noqa: SLF001 — skip load(); decode is faked
        backend._model_path = "/fake/model"  # noqa: SLF001
        backend.start_session()
        return backend, fake

    return make


def feed_seconds(backend, seconds, chunk=None):
    partials = []
    for _ in range(int(seconds * 10)):
        p = backend.feed_chunk(loud() if chunk is None else chunk)
        if p is not None:
            partials.append(p)
    return partials


def test_segment_closes_on_pause(whisper):
    backend, fake = whisper(["seg one"])
    partials = feed_seconds(backend, MIN_SEGMENT_S)  # 10s speech: not yet
    assert partials == [] and fake.calls == []
    partials = feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())  # 0.7s pause
    assert partials == ["seg one"]
    assert backend.take_new_segments() == ["seg one"]
    assert backend.take_new_segments() == []  # consumed
    n_samples, kwargs = fake.calls[0]
    assert n_samples == int((MIN_SEGMENT_S + SEGMENT_SILENCE_S) * SAMPLE_RATE)
    assert kwargs["condition_on_previous_text"] is False
    assert kwargs["initial_prompt"] is None
    assert kwargs["path_or_hf_repo"] == "/fake/model"


def test_segment_closes_at_hard_cap_without_pause(whisper):
    backend, fake = whisper(["seg one"])
    partials = feed_seconds(backend, HARD_SEGMENT_S)  # continuous speech
    assert partials == ["seg one"]
    assert fake.calls[0][0] == int(HARD_SEGMENT_S * SAMPLE_RATE)


def test_short_dictation_finalize_redecodes_whole_clip(whisper):
    backend, fake = whisper(["seg one", "whole clip text"])
    feed_seconds(backend, MIN_SEGMENT_S)
    feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())  # one segment closed
    feed_seconds(backend, 5)  # total ≈ 15.7s < LONG_DICTATION_S
    text = backend.finalize()
    # Segments were preview-only: the final text is a whole-clip decode.
    assert text == "whole clip text"
    assert backend.segments_used_for_final is False
    assert fake.calls[-1][0] == int(15.7 * SAMPLE_RATE)  # the WHOLE clip


def test_long_dictation_finalize_stitches_segments(whisper):
    backend, fake = whisper(["seg one", "seg two", "the tail"])
    feed_seconds(backend, MIN_SEGMENT_S)
    feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())  # seg one at 10.7s
    feed_seconds(backend, HARD_SEGMENT_S)  # seg two via hard cap at 35.7s
    feed_seconds(backend, 11)  # total 46.7s > LONG_DICTATION_S; 11s un-decoded
    assert backend.take_new_segments() == ["seg one", "seg two"]
    text = backend.finalize()
    assert text == "seg one seg two the tail"
    assert backend.segments_used_for_final is True
    assert backend.final_tail == "the tail"
    assert fake.calls[-1][0] == int(11 * SAMPLE_RATE)  # only the tail decoded
    # state fully reset for the next session
    backend.start_session()
    assert backend.segments_used_for_final is False and backend.final_tail == ""


def test_initial_prompt_passed_to_every_decode(whisper):
    backend, fake = whisper(["seg one", "tail"])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, HARD_SEGMENT_S)
    feed_seconds(backend, 21)  # total 46s → stitched finalize (tail decode)
    backend.finalize()
    assert len(fake.calls) >= 2
    assert all(kw["initial_prompt"] == "Glossary: Velora." for _, kw in fake.calls)


def test_echo_guard_applied_on_segment_decode(whisper):
    backend, fake = whisper(["Glossary: Velora, Wispr Flow. hello there"])
    backend.initial_prompt = "Glossary: Velora, Wispr Flow."
    partials = feed_seconds(backend, HARD_SEGMENT_S)
    assert partials == ["hello there"]


def test_segment_decode_failure_degrades_to_batch(whisper):
    backend, fake = whisper(["whole clip rescue"])
    fake.fail_next = 1
    partials = feed_seconds(backend, HARD_SEGMENT_S)  # decode raises → swallowed
    assert partials == []
    feed_seconds(backend, 5)  # keeps accumulating, no more decode attempts
    assert fake.calls == []
    text = backend.finalize()
    assert text == "whole clip rescue"
    assert backend.segments_used_for_final is False
    assert fake.calls[-1][0] == int((HARD_SEGMENT_S + 5) * SAMPLE_RATE)


def test_transcribe_clip_disables_segmenting(whisper):
    backend, fake = whisper(["whole clip text"])
    pcm = np.concatenate([loud() for _ in range(int(HARD_SEGMENT_S * 10) + 50)])
    text = transcribe_clip(backend, pcm)
    # One whole-clip decode; no in-session segment decodes happened.
    assert text == "whole clip text"
    assert len(fake.calls) == 1
    assert fake.calls[0][0] == len(pcm)
    assert backend.segmenting_enabled is True  # restored


# ---- FakeBackend segment mode --------------------------------------------------


def test_fake_backend_segment_mode(monkeypatch):
    monkeypatch.setenv("VELORA_FAKE_STT_SEGMENTS", "seg one text|seg two text")
    monkeypatch.setenv("VELORA_FAKE_STT_TEXT", "tail text")
    b = FakeBackend()
    b.start_session()
    partials = []
    for _ in range(4):
        p = b.feed_chunk(np.zeros(FakeBackend.SEGMENT_SAMPLES // 2, dtype=np.float32))
        if p:
            partials.append(p)
    assert partials == ["seg one text", "seg one text seg two text"]
    assert b.take_new_segments() == ["seg one text", "seg two text"]
    assert b.finalize() == "seg one text seg two text tail text"
    assert b.segments_used_for_final is True
    assert b.final_tail == "tail text"


def test_fake_backend_default_mode_unchanged(monkeypatch):
    monkeypatch.delenv("VELORA_FAKE_STT_SEGMENTS", raising=False)
    monkeypatch.delenv("VELORA_FAKE_STT_TEXT", raising=False)
    b = FakeBackend()
    b.start_session()
    assert b.feed_chunk(np.zeros(100, dtype=np.float32)) == "partial after 100 samples"
    assert b.finalize() == FakeBackend.DEFAULT_TEXT
    assert b.segments_used_for_final is False


# ---- glossary prompt -----------------------------------------------------------


def test_build_glossary_prompt_orders_least_to_most_important():
    out = build_glossary_prompt(["User"], ["Learned"], ["Auto"], ["Entity"])
    assert out == "Glossary: Auto, Learned, User, Entity."


def test_build_glossary_prompt_empty_and_dedup():
    assert build_glossary_prompt([], [], [], []) is None
    assert build_glossary_prompt(["", "  "], [], [], []) is None
    # case-insensitive dedup keeps the most-important (later) spelling/slot
    out = build_glossary_prompt(["Velora"], [], ["velora"], [])
    assert out == "Glossary: Velora."


def test_build_glossary_prompt_cap_keeps_tail():
    user = [f"term{i}" for i in range(30)]
    out = build_glossary_prompt(user, [], [], ["Entity"], cap=5)
    # the cap keeps the LAST (most important) terms — entities above all
    assert out == "Glossary: term26, term27, term28, term29, Entity."


# ---- prompt-echo guard ---------------------------------------------------------

PROMPT = "Glossary: Velora, Wispr Flow, authCheck."


def test_strip_prompt_echo_noop_cases():
    assert strip_prompt_echo("hello world", None) == "hello world"
    assert strip_prompt_echo("hello world", PROMPT) == "hello world"
    assert strip_prompt_echo("", PROMPT) == ""


def test_strip_prompt_echo_leading_preamble():
    text = "Glossary: Velora, Wispr Flow, authCheck. let's ship it today"
    assert strip_prompt_echo(text, PROMPT) == "let's ship it today"


def test_strip_prompt_echo_preamble_mid_text():
    text = "okay so Glossary: Velora, Wispr Flow. and then we shipped"
    assert strip_prompt_echo(text, PROMPT) == "okay so and then we shipped"


def test_strip_prompt_echo_fuzzy_prefix_without_preamble():
    text = "Velora, Wispr Flow, authCheck. real dictation follows"
    assert strip_prompt_echo(text, PROMPT) == "real dictation follows"


def test_strip_prompt_echo_full_echo_becomes_empty():
    assert strip_prompt_echo("Glossary: Velora, Wispr Flow, authCheck.", PROMPT) == ""


def test_strip_prompt_echo_keeps_real_use_of_terms():
    # A dictation genuinely starting with one or two glossary terms survives.
    assert strip_prompt_echo("Velora crashed again today", PROMPT) == "Velora crashed again today"
    assert strip_prompt_echo("Wispr Flow is the competitor", PROMPT) == "Wispr Flow is the competitor"


def test_strip_prompt_echo_keeps_dictated_word_glossary():
    # The word "glossary" in ordinary prose (no colon, no term run) survives.
    text = "add a glossary section to the doc"
    assert strip_prompt_echo(text, PROMPT) == text
