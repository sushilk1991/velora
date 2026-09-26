"""In-session segmenting (smartness-v2 §2/§4): SilenceTracker energy VAD,
WhisperBackend segment closing/stitching (with a monkeypatched mlx_whisper —
tests never load MLX), glossary prompt building, and the prompt-echo guard."""

import contextlib
import sys
import types

import numpy as np
import pytest

import velora_engine.stt as stt_mod
from velora_engine.stt import (
    HARD_SEGMENT_S,
    LONG_DICTATION_S,
    MIN_FINAL_AUDIO_S,
    MIN_SEGMENT_S,
    PREVIEW_FIRST_S,
    PREVIEW_MIN_SPAN_S,
    PREVIEW_PAUSE_S,
    PREVIEW_WINDOW_S,
    SAMPLE_RATE,
    SEGMENT_SILENCE_S,
    FakeBackend,
    SilenceTracker,
    WhisperBackend,
    build_glossary_prompt,
    speech_window_fraction,
    strip_prompt_echo,
    transcribe_clip,
)

CHUNK = SAMPLE_RATE // 10  # 100ms feed chunks, like the app sends


def loud(amplitude: float = 0.1) -> np.ndarray:
    return np.full(CHUNK, amplitude, dtype=np.float32)


def speechy() -> np.ndarray:
    """Deterministic voiced chunk with speech-like amplitude modulation."""
    t = np.arange(CHUNK, dtype=np.float32) / SAMPLE_RATE
    envelope = 0.15 + 0.85 * np.square(np.sin(2 * np.pi * 4 * t))
    return (0.1 * envelope * np.sin(2 * np.pi * 220 * t)).astype(np.float32)


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


def test_speech_window_fraction_matches_batch_feed_windows():
    mixed = np.concatenate(
        [speechy() for _ in range(8)] + [quiet() for _ in range(2)]
    )
    assert speech_window_fraction(mixed, chunk_samples=CHUNK) == pytest.approx(0.8)
    assert speech_window_fraction(np.zeros(CHUNK * 10), chunk_samples=CHUNK) == 0


# ---- WhisperBackend segmenting (fake mlx_whisper) ------------------------------


class FakeWhisper:
    """Captures transcribe() calls; returns queued texts/results (last repeats)."""

    def __init__(self, texts):
        self.texts = list(texts)
        self.calls = []  # (n_samples, kwargs)
        self.fail_next = 0
        self.on_call = None

    def transcribe(self, audio, **kwargs):
        if self.fail_next > 0:
            self.fail_next -= 1
            raise RuntimeError("decode boom")
        self.calls.append((len(audio), kwargs))
        if self.on_call is not None:
            self.on_call(len(self.calls), kwargs)
        text = self.texts.pop(0) if len(self.texts) > 1 else self.texts[0]
        if isinstance(text, BaseException):
            raise text
        if isinstance(text, dict):
            return text
        return {"text": text, "segments": [{"text": text}]}


@pytest.fixture
def whisper(monkeypatch):
    def make(texts, previews=False):
        fake = FakeWhisper(texts)
        mod = types.ModuleType("mlx_whisper")
        mod.transcribe = fake.transcribe
        monkeypatch.setitem(sys.modules, "mlx_whisper", mod)
        # No real model behind the fake library: keep the configured
        # language and skip the encoder memo (test_whisper_encoder_reuse).
        monkeypatch.setattr(
            stt_mod, "_encoding_once",
            lambda _path, _audio, language: contextlib.nullcontext(language))
        backend = WhisperBackend("mlx-community/whisper-large-v3-turbo", "auto")
        backend._loaded = True  # noqa: SLF001 — skip load(); decode is faked
        backend._model_path = "/fake/model"  # noqa: SLF001
        backend.preview_enabled = previews
        backend.start_session()
        return backend, fake

    return make


def test_whisper_load_populates_transcribe_model_holder(monkeypatch):
    import mlx.core as mx
    from velora_engine import models

    evaluated = []

    class FakeModel:
        @staticmethod
        def parameters():
            return "model-parameters"

    class FakeHolder:
        calls = []
        model = FakeModel()

        @classmethod
        def get_model(cls, model_path, dtype):
            cls.calls.append((model_path, dtype))
            return cls.model

    transcribe_module = types.ModuleType("mlx_whisper.transcribe")
    transcribe_module.ModelHolder = FakeHolder
    monkeypatch.setitem(sys.modules, "mlx_whisper.transcribe", transcribe_module)
    monkeypatch.setattr(models, "ensure_downloaded", lambda _model_id: "/cached/whisper")
    monkeypatch.setattr(mx, "eval", lambda value: evaluated.append(value))

    backend = WhisperBackend("mlx-community/whisper-large-v3-turbo", "auto")
    backend.load()

    assert FakeHolder.calls == [("/cached/whisper", mx.float16)]
    assert evaluated == ["model-parameters"]
    assert backend._loaded is True


def feed_seconds(backend, seconds, chunk=None):
    partials = []
    for _ in range(int(seconds * 10)):
        p = backend.feed_chunk(loud() if chunk is None else chunk)
        if p is not None:
            partials.append(p)
    return partials


def decode_pending_preview(backend):
    request = backend.take_preview_request()
    assert request is not None
    return backend.decode_preview(request), request


def test_audio_span_copies_only_requested_chunk_overlap(whisper, monkeypatch):
    backend, _fake = whisper(["unused"])
    backend._chunks = [
        np.arange(0, 3, dtype=np.float32),
        np.arange(3, 7, dtype=np.float32),
        np.arange(7, 12, dtype=np.float32),
    ]
    backend._samples = 12
    concatenated_lengths = []
    real_concatenate = np.concatenate

    def recording_concatenate(parts, *args, **kwargs):
        concatenated_lengths.append([len(part) for part in parts])
        return real_concatenate(parts, *args, **kwargs)

    monkeypatch.setattr(np, "concatenate", recording_concatenate)
    span = backend._audio_span(4, 10)

    np.testing.assert_array_equal(span, np.arange(4, 10, dtype=np.float32))
    assert concatenated_lengths == [[3, 3]]


def _full_speech_reference(backend):
    parts = []
    frame_samples = stt_mod._SPEECH_FRAME_SAMPLES
    for chunk in backend._chunks:
        frames = len(chunk) // frame_samples
        if not frames:
            continue
        audio = np.asarray(chunk[:frames * frame_samples], dtype=np.float32)
        frames = audio.reshape(frames, frame_samples)
        parts.append(np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1)))

    if not parts:
        return backend._silence.speech_level
    return max(backend._silence.speech_level, float(np.percentile(np.concatenate(parts), 90)))


def test_speech_reference_parity():
    backend = WhisperBackend("unused")
    rng = np.random.default_rng(42)
    for size in [0, 1, 319, 320, 321, 1600, 48000, 640, 0]:
        backend.feed_chunk(rng.normal(0, 0.1, size).astype(np.float32))
        assert backend._speech_reference() == _full_speech_reference(backend)

    backend.reset()
    backend.feed_chunk(quiet())
    assert backend._speech_reference() == _full_speech_reference(backend)


def test_speech_rms_analyzed_once(monkeypatch):
    backend = WhisperBackend("unused")
    backend.feed_chunk(loud())
    backend._speech_reference()
    squared_samples = []
    real_square = np.square

    def square(audio, **kwargs):
        squared_samples.append(audio.size)
        return real_square(audio, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(np, "square", square)
        backend._speech_reference()
    assert squared_samples == []

    backend.feed_chunk(loud(0.2))
    with monkeypatch.context() as patch:
        patch.setattr(np, "square", square)
        reference = backend._speech_reference()
    assert squared_samples == [CHUNK]
    assert reference == _full_speech_reference(backend)


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


def test_production_whisper_does_not_queue_hud_previews_by_default():
    backend = WhisperBackend("mlx-community/whisper-large-v3-turbo", "auto")
    backend._loaded = True  # noqa: SLF001 — no decode occurs in this test
    backend.start_session()

    assert backend.preview_enabled is False
    assert feed_seconds(backend, PREVIEW_FIRST_S + 1) == []
    assert backend.take_preview_request() is None


def test_tiny_capture_tail_skips_whisper_decode(whisper):
    backend, fake = whisper(["invented transcript"])
    tiny = np.full(
        int(MIN_FINAL_AUDIO_S * SAMPLE_RATE) - 1,
        0.1,
        dtype=np.float32,
    )
    backend.feed_chunk(tiny)

    assert backend.finalize() == ""
    assert fake.calls == []


def test_preview_is_requested_early_without_decoding_in_feed(whisper):
    backend, fake = whisper(["early preview"], previews=True)
    assert feed_seconds(backend, PREVIEW_FIRST_S) == []
    assert fake.calls == []

    partial, request = decode_pending_preview(backend)

    assert partial == "early preview"
    assert len(request.audio) == int(PREVIEW_FIRST_S * SAMPLE_RATE)
    assert backend._decoded_samples == 0
    assert backend._segments == []
    assert backend.take_new_segments() == []


def test_early_pause_preview_does_not_commit_segment_state(whisper):
    backend, fake = whisper(["pause preview"], previews=True)
    assert feed_seconds(backend, PREVIEW_MIN_SPAN_S) == []
    assert feed_seconds(backend, PREVIEW_PAUSE_S, chunk=quiet()) == []

    partial, request = decode_pending_preview(backend)

    assert partial == "pause preview"
    assert backend._decoded_samples == 0
    assert backend._segments == []
    assert backend.take_new_segments() == []
    assert len(request.audio) == int((PREVIEW_MIN_SPAN_S + PREVIEW_PAUSE_S) * SAMPLE_RATE)


def test_pending_preview_keeps_the_full_uncommitted_span_until_hard_commit(whisper):
    backend, fake = whisper(["latest"], previews=True)
    feed_seconds(backend, PREVIEW_FIRST_S)
    first = backend.take_preview_request()
    assert first is not None

    # Stay just below the hard commit. A shorter rolling window would make
    # words already shown in the Stream draft disappear until commit.
    span_s = HARD_SEGMENT_S - 0.1
    feed_seconds(backend, span_s - PREVIEW_FIRST_S)
    latest = backend.take_preview_request()

    assert latest is not None
    assert PREVIEW_WINDOW_S == HARD_SEGMENT_S
    assert len(latest.audio) >= int(
        (span_s - stt_mod.PREVIEW_BASE_INTERVAL_S) * SAMPLE_RATE
    )
    assert len(latest.audio) <= int(span_s * SAMPLE_RATE)
    assert fake.calls == []


def test_preview_decode_duration_adapts_and_reset_restores_cadence(whisper, monkeypatch):
    backend, _fake = whisper(["adaptive"], previews=True)
    feed_seconds(backend, PREVIEW_FIRST_S)
    request = backend.take_preview_request()
    assert request is not None
    times = iter([10.0, 12.0])
    monkeypatch.setattr(stt_mod.time, "perf_counter", lambda: next(times))

    assert backend.decode_preview(request) == "adaptive"
    assert backend._preview_interval_s == 3.0

    backend.reset()
    assert backend._preview_interval_s == stt_mod.PREVIEW_BASE_INTERVAL_S


def test_committed_decode_still_covers_full_span_after_preview(whisper):
    backend, fake = whisper(
        ["early preview", "committed segment"], previews=True
    )
    feed_seconds(backend, PREVIEW_FIRST_S)
    partial, _request = decode_pending_preview(backend)
    assert partial == "early preview"
    feed_seconds(backend, MIN_SEGMENT_S - PREVIEW_FIRST_S)
    partials = feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())

    assert partials[-1] == "committed segment"
    assert backend.take_new_segments() == ["committed segment"]
    assert backend._decoded_samples == int((MIN_SEGMENT_S + SEGMENT_SILENCE_S) * SAMPLE_RATE)
    assert fake.calls[-1][0] == backend._decoded_samples


def test_preview_does_not_change_short_whole_clip_final(whisper):
    backend, fake = whisper(["early preview", "whole clip final"], previews=True)
    feed_seconds(backend, PREVIEW_FIRST_S)
    partial, _request = decode_pending_preview(backend)
    assert partial == "early preview"
    feed_seconds(backend, 1)

    assert backend.finalize() == "whole clip final"
    assert backend.segments_used_for_final is False
    assert fake.calls[-1][0] == int((PREVIEW_FIRST_S + 1) * SAMPLE_RATE)


def test_preview_does_not_change_long_committed_stitch(whisper):
    backend, _fake = whisper(["unused"], previews=True)

    def by_span(audio, **_kwargs):
        seconds = len(audio) / SAMPLE_RATE
        if seconds == pytest.approx(HARD_SEGMENT_S):
            return "committed segment"
        if seconds == pytest.approx(21):
            return "final tail"
        return "preview only"

    backend._decode = by_span
    feed_seconds(backend, HARD_SEGMENT_S)
    feed_seconds(backend, 21)

    assert backend.take_new_segments() == ["committed segment"]
    assert backend.finalize() == "committed segment final tail"
    assert backend.segments_used_for_final is True


def test_preview_is_not_repeated_during_same_silent_pause(whisper):
    backend, fake = whisper(["early preview"], previews=True)
    feed_seconds(backend, PREVIEW_MIN_SPAN_S)
    feed_seconds(backend, PREVIEW_PAUSE_S, chunk=quiet())
    partial, _request = decode_pending_preview(backend)
    assert partial == "early preview"
    calls_after_preview = len(fake.calls)
    feed_seconds(backend, 3, chunk=quiet())
    assert len(fake.calls) == calls_after_preview
    assert backend.take_preview_request() is None


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


def test_long_segmented_finalize_does_not_join_the_whole_recording(whisper, monkeypatch):
    backend, fake = whisper(["tail"])
    body_samples = int(LONG_DICTATION_S * SAMPLE_RATE)
    # The tail must carry real speech (built before np.concatenate is
    # patched) or the speechless-tail guard rightly skips its decode.
    tail_audio = np.concatenate([speechy() for _ in range(10)])
    backend._chunks = [np.zeros(body_samples, dtype=np.float32), tail_audio]
    backend._samples = body_samples + len(tail_audio)
    backend._decoded_samples = body_samples
    backend._segments = ["committed"]

    real_concatenate = np.concatenate

    def reject_whole_join(parts, *args, **kwargs):
        # numpy uses concatenate internally (np.percentile in the tail
        # evidence gate) — only the join of the WHOLE recording is the bug.
        sizes = [len(part) for part in parts]
        if sum(sizes) >= backend._samples:
            raise AssertionError(
                "segmented finalize must materialize only its tail")
        return real_concatenate(parts, *args, **kwargs)

    monkeypatch.setattr(np, "concatenate", reject_whole_join)
    assert backend.finalize() == "committed tail"
    assert fake.calls[-1][0] == SAMPLE_RATE


def test_empty_speech_tail_forces_whole_clip_redecode(whisper):
    backend, fake = whisper(["committed prefix", "", "whole clip rescue"])
    feed_seconds(backend, HARD_SEGMENT_S)
    assert backend.take_new_segments() == ["committed prefix"]
    feed_seconds(backend, LONG_DICTATION_S + 1 - HARD_SEGMENT_S)

    assert backend.finalize() == "whole clip rescue"
    assert backend.segments_used_for_final is False
    assert [samples for samples, _ in fake.calls[-2:]] == [
        int((LONG_DICTATION_S + 1 - HARD_SEGMENT_S) * SAMPLE_RATE),
        int((LONG_DICTATION_S + 1) * SAMPLE_RATE),
    ]


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


def test_strip_prompt_echo_keeps_glossary_word_deep_in_text():
    # Review finding: "glossary" beyond the first words is dictation, never an
    # echo — even when followed by a real glossary term.
    text = "please add that to the glossary Velora is capitalized"
    assert strip_prompt_echo(text, PROMPT) == text


def test_strip_prompt_echo_requires_prompt_order():
    # Review finding: a genuine dictation reusing glossary words in a DIFFERENT
    # order must survive — only an in-prompt-order run reads as an echo.
    text = "authCheck broke Velora again this morning"
    assert strip_prompt_echo(text, PROMPT) == text


def test_strip_prompt_echo_removes_exact_prompt_tail_after_sentence():
    prompt = "Glossary: Velora, Wispr Flow, LLM, Airlearn."
    text = "Ship the current patch. LLM, Airlearn."
    assert strip_prompt_echo(text, prompt) == "Ship the current patch."


def test_strip_prompt_echo_keeps_single_or_prose_prompt_terms_at_end():
    prompt = "Glossary: Velora, Wispr Flow, LLM, Airlearn."
    assert strip_prompt_echo("We use Airlearn.", prompt) == "We use Airlearn."
    text = "We compare LLM and Airlearn."
    assert strip_prompt_echo(text, prompt) == text


def test_strip_prompt_echo_keeps_reversed_prompt_tail():
    prompt = "Glossary: Velora, Wispr Flow, LLM, Airlearn."
    text = "Ship the current patch. Airlearn, LLM."
    assert strip_prompt_echo(text, prompt) == text


def test_strip_prompt_echo_does_not_apply_trailing_guard_to_a_segment():
    prompt = "Glossary: Velora, Wispr Flow, Alice, Bob."
    text = "Confirmed the attendees. Alice, Bob."
    assert strip_prompt_echo(text, prompt, allow_trailing=False) == text


# ---- empty-decode speech protection (review finding) ----------------------------


def test_empty_speech_decode_keeps_audio_pending(whisper):
    # A span that HAD speech but decoded to "" must stay un-consumed: marking
    # it decoded would drop those words from the stitched final.
    backend, fake = whisper(["", "recovered text"])
    feed_seconds(backend, MIN_SEGMENT_S)
    feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())
    assert len(fake.calls) == 1  # decode happened, returned ""
    assert backend._decoded_samples == 0  # noqa: SLF001 — audio NOT consumed
    assert backend.take_new_segments() == []
    # after the ~3s backoff, the retry decodes the WHOLE span again (larger)
    feed_seconds(backend, 3.5)
    feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())
    assert len(fake.calls) == 2
    assert fake.calls[1][0] > fake.calls[0][0]  # span grew — nothing lost
    assert backend.take_new_segments() == ["recovered text"]


# Prompted decodes that must trigger the prompt-free retry: the model looping
# on the glossary, and a verbatim echo of the prompt.
PROMPT_HALLUCINATION = {
    "text": "Glossary. " * 20,
    "segments": [
        {
            "text": "Glossary. " * 20,
            "compression_ratio": 10.89,
            "avg_logprob": -0.1,
            "no_speech_prob": 0.0,
        }
    ],
}
PROMPT_ECHO = {
    "text": "Glossary: project.md.",
    "segments": [
        {
            "text": "Glossary: project.md.",
            "compression_ratio": 0.5,
            "avg_logprob": -0.1,
            "no_speech_prob": 0.0,
        }
    ],
}


def whisper_result(*windows):
    """mlx-whisper result for (seek, text, avg_logprob, compression_ratio
    [, no_speech_prob]) windows; mlx tags each segment with the seek of the
    window it came from."""
    segments = [
        {
            "seek": seek,
            "text": text,
            "avg_logprob": logprob,
            "compression_ratio": ratio,
            "no_speech_prob": rest[0] if rest else 0.0,
        }
        for seek, text, logprob, ratio, *rest in windows
    ]
    return {"text": " ".join(s["text"] for s in segments), "segments": segments}


GLOSSARY_LOOP = "Glossary. " * 20


def test_glossary_loop_on_short_clip_runs_one_pass_per_decode(whisper):
    # Field trace: on 1-6 s clips the glossary decode looped to the token
    # cap at most stock temperatures (~1 s a pass, 5-8 s stop→text), and
    # the prompt-free retry produced the kept text every time. A float
    # temperature is one mlx pass per window, so this is two passes.
    backend, fake = whisper([PROMPT_HALLUCINATION, "two words"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "two words"
    assert [kwargs["temperature"] for _, kwargs in fake.calls] == [0.0, 0.0]


def test_unsure_glossary_text_kept_when_retry_is_gated_off(whisper):
    # The modulation gate must never decide the authoritative pass: a quiet
    # one-word answer with a flat envelope keeps its glossary spelling.
    backend, fake = whisper([whisper_result((0, "Airlearn", -1.15, 0.6))])
    backend.initial_prompt = "Glossary: Airlearn."
    feed_seconds(backend, 2.5, chunk=loud(0.02))

    assert backend.finalize() == "Airlearn"
    assert len(fake.calls) == 1


def test_unsure_hum_takes_stock_ladder_when_retry_is_gated_off(whisper):
    # Owner-sample hum clip: the greedy glossary pass scored -2.0 on steady
    # noise and nothing can confirm it. A logprob alone never empties a
    # transcript; the stock ladder (0.25.0) decides, and on this clip it
    # returned nothing.
    backend, fake = whisper([whisper_result((0, "you", -2.04, 0.3)), ""])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=loud(0.02))

    assert backend.finalize() == ""
    assert len(fake.calls) == 2
    assert fake.calls[1][1]["initial_prompt"] == "Glossary: project.md."
    assert "temperature" not in fake.calls[1][1]


@pytest.mark.parametrize(
    ("chunk", "queued"),
    [
        # Flat envelope: the prompt-free retry is gated off.
        (loud(0.02), ["okay"]),
        # The prompt-free retry runs and hears nothing.
        (speechy(), ["", "okay"]),
    ],
    ids=["retry-gated-off", "retry-empty"],
)
def test_unsure_text_below_floor_takes_stock_ladder(whisper, chunk, queued):
    # Review probe: "okay" at -1.21 with a clean compression ratio. The
    # guard itself keeps it (it needs cr > 2.0 too), and 0.25.0 laddered
    # and kept text, so an unconfirmed pass re-decodes on the ladder.
    backend, fake = whisper([whisper_result((0, "okay", -1.21, 0.6))] + queued)
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 2.5, chunk=chunk)

    assert backend.finalize() == "okay"
    assert fake.calls[-1][1]["initial_prompt"] == "Glossary: Velora."
    assert "temperature" not in fake.calls[-1][1]


def test_unsure_text_at_floor_is_kept(whisper):
    backend, fake = whisper([whisper_result((0, "okay", -1.2, 0.6))])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 2.5, chunk=loud(0.02))

    assert backend.finalize() == "okay"
    assert len(fake.calls) == 1


def test_loop_with_retry_gated_off_takes_stock_ladder(whisper):
    # Only a prompt-free pass that heard nothing may confirm a loop as
    # silence; without one the stock ladder gets its 0.25.0 chance.
    backend, fake = whisper([whisper_result((0, GLOSSARY_LOOP, -0.1, 12.0)), "okay"])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 2.5, chunk=loud(0.02))

    assert backend.finalize() == "okay"
    assert len(fake.calls) == 2
    assert "temperature" not in fake.calls[1][1]


def test_unsure_glossary_text_kept_when_retry_scores_lower(whisper):
    # Taking the prompt-free pass unconditionally costs glossary spelling.
    backend, _fake = whisper([
        whisper_result((0, "Airlearn", -1.15, 0.6)),
        whisper_result((0, "air learn", -1.4, 0.6)),
    ])
    backend.initial_prompt = "Glossary: Airlearn."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "Airlearn"


def test_unsure_glossary_text_replaced_when_retry_scores_higher(whisper):
    # Short speech scored -1.1 to -1.2 with the glossary and -0.2 to -0.9
    # without it on the same audio (field trace).
    backend, fake = whisper([
        whisper_result((0, "to words", -1.15, 0.6)),
        whisper_result((0, "two words", -0.3, 0.6)),
    ])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "two words"
    assert fake.calls[-1][1]["initial_prompt"] is None


def test_retry_with_fewer_words_never_replaces_glossary_text(whisper):
    # mlx averages logprob over generated tokens, so a fragment of the
    # clip can outscore the whole of it (review probe).
    backend, _fake = whisper([
        whisper_result((0, "we ship the fix", -1.15, 0.6)),
        whisper_result((0, "the fix", -0.3, 0.6)),
    ])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "we ship the fix"


@pytest.mark.parametrize(
    ("retry", "final"),
    [
        # Split spelling loses the term: glossary text stays.
        ("air learn is live", "Airlearn is live"),
        # Part of a longer word is not the term.
        ("Airlearns is live", "Airlearn is live"),
        # Case differs, word boundaries hold: the term is there.
        ("airlearn is live", "airlearn is live"),
    ],
    ids=["split", "inside-a-word", "case"],
)
def test_retry_keeps_every_glossary_term(whisper, retry, final):
    backend, _fake = whisper([
        whisper_result((0, "Airlearn is live", -1.15, 0.6)),
        whisper_result((0, retry, -0.3, 0.6)),
    ])
    backend.initial_prompt = "Glossary: Velora, Airlearn."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == final


def test_retry_scoring_a_tie_keeps_glossary_text(whisper):
    backend, _fake = whisper([
        whisper_result((0, "Velora ships the fix", -1.15, 0.6)),
        whisper_result((0, "Velora ships the fixes", -1.15, 0.6)),
    ])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "Velora ships the fix"


def test_unsure_glossary_text_kept_when_retry_hears_nothing(whisper):
    backend, _fake = whisper([whisper_result((0, "Airlearn", -1.15, 0.6)), ""])
    backend.initial_prompt = "Glossary: Airlearn."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "Airlearn"


@pytest.mark.parametrize(
    "windows",
    [
        # Window 2 restarts without the glossary and is unsure.
        ((0, "Velora ships", -0.3, 1.2), (2400, "the fix", -1.15, 0.8)),
        # Window 2 loops: the guard drops it and window 1's text blocks the
        # prompt-free retry.
        ((0, "Velora ships", -0.3, 1.2), (2400, GLOSSARY_LOOP, -0.1, 12.0)),
        # Window 1 loops, window 2 is clean.
        ((0, GLOSSARY_LOOP, -0.1, 12.0), (2400, "the fix", -0.3, 1.2)),
    ],
    ids=["later-unsure", "later-loop", "first-loop"],
)
def test_failed_window_in_multi_window_result_takes_stock_ladder(whisper, windows):
    # A window without a closing timestamp restarts, so audio under 30 s can
    # decode as two windows (mlx_whisper transcribe.py:382-390). A failure
    # in either must not cost words the stock ladder (0.25.0) kept.
    backend, fake = whisper([whisper_result(*windows), "Velora ships the fix"])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 20.0, chunk=speechy())

    assert backend.finalize() == "Velora ships the fix"
    assert len(fake.calls) == 2
    assert fake.calls[1][1]["initial_prompt"] == "Glossary: Velora."
    assert "temperature" not in fake.calls[1][1]


def test_all_windows_failed_takes_prompt_free_retry(whisper):
    # With no clean window there is no text to lose: the ladder only
    # re-samples the loop (7-20 s on a 4.7 s bench clip, once as words in
    # another language), so the prompt-free retry covers the clip instead.
    backend, fake = whisper([
        whisper_result((0, GLOSSARY_LOOP, -0.1, 12.0), (2400, GLOSSARY_LOOP, -0.1, 12.0)),
        "",
    ])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 5.0, chunk=speechy())

    assert backend.finalize() == ""
    assert len(fake.calls) == 2
    assert fake.calls[1][1]["initial_prompt"] is None
    assert fake.calls[1][1]["temperature"] == 0.0


def test_ladder_result_is_final(whisper):
    # The stock ladder is the 0.25.0 path: its last sample is kept as
    # 0.25.0 kept it, never judged again as a greedy pass.
    backend, fake = whisper([
        whisper_result((0, "Velora ships", -0.3, 1.2), (2400, "the fix", -1.15, 0.8)),
        whisper_result((0, "Velora ships the fix", -1.1, 1.0)),
    ])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 20.0, chunk=speechy())

    assert backend.finalize() == "Velora ships the fix"
    assert len(fake.calls) == 2


def test_silent_window_is_not_a_failed_window(whisper):
    # Stock treats a window over 0.6 no-speech probability as silence and
    # never re-samples it (transcribe.py:238-241); the guard drops its text.
    backend, fake = whisper([
        whisper_result(
            (0, "Velora ships", -0.3, 1.2), (2400, "Thank you.", -0.2, 3.0, 0.7)
        ),
    ])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 20.0, chunk=speechy())

    assert backend.finalize() == "Velora ships"
    assert len(fake.calls) == 1


def test_clean_multi_window_greedy_result_is_kept(whisper):
    backend, fake = whisper([
        whisper_result((0, "Velora ships", -0.3, 1.2), (2400, "the fix", -0.4, 1.1)),
    ])
    backend.initial_prompt = "Glossary: Velora."
    feed_seconds(backend, 20.0, chunk=speechy())

    assert backend.finalize() == "Velora ships the fix"
    assert len(fake.calls) == 1


def test_multi_window_glossary_decode_keeps_stock_fallback(whisper):
    # Past one 30 s window a looping window leaves the others' text, so
    # the prompt-free retry never runs; stock fallback stays its recovery.
    backend, fake = whisper(["long dictation"])
    backend.segmenting_enabled = False
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 31.0, chunk=speechy())

    assert backend.finalize() == "long dictation"
    assert "temperature" not in fake.calls[0][1]


def test_prompt_hallucination_retries_speech_without_glossary(whisper):
    backend, fake = whisper([PROMPT_HALLUCINATION, "recovered speech"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "recovered speech"
    assert len(fake.calls) == 2
    assert fake.calls[0][1]["initial_prompt"] == "Glossary: project.md."
    assert fake.calls[1][1]["initial_prompt"] is None
    assert fake.calls[1][1]["temperature"] == 0.0


def test_prompt_echo_stripped_to_empty_retries_speech_without_glossary(whisper):
    backend, fake = whisper([PROMPT_ECHO, "recovered speech"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "recovered speech"
    assert len(fake.calls) == 2
    assert fake.calls[-1][1]["initial_prompt"] is None
    assert fake.calls[-1][1]["temperature"] == 0.0


def test_prompt_hallucination_does_not_retry_silence(whisper):
    backend, fake = whisper([PROMPT_HALLUCINATION, "invented words"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=quiet())

    assert backend.finalize() == ""
    assert fake.calls == []


def test_non_prompt_empty_decode_on_noise_does_not_invent_words(whisper):
    no_speech = {
        "text": "",
        "segments": [
            {
                "text": "",
                "compression_ratio": 0.1,
                "avg_logprob": -2.0,
                "no_speech_prob": 0.99,
            }
        ],
    }
    backend, fake = whisper([no_speech, "invented words"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=loud(0.005))

    assert backend.finalize() == ""
    assert len(fake.calls) == 1


def test_prompt_hallucination_on_stationary_noise_does_not_retry(whisper):
    # The greedy loop goes back through the stock ladder (loops again here),
    # never to a prompt-free pass that could invent words from noise.
    backend, fake = whisper([PROMPT_HALLUCINATION, PROMPT_HALLUCINATION, "invented words"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=loud(0.02))

    assert backend.finalize() == ""
    assert all(kwargs["initial_prompt"] for _, kwargs in fake.calls)


def test_prompt_free_retry_failure_degrades_to_empty_final(whisper):
    # A failed retry is no evidence of silence: the stock ladder runs (and
    # loops again here), and the failed retry is not attempted twice.
    backend, fake = whisper([
        PROMPT_HALLUCINATION, RuntimeError("retry decode boom"), PROMPT_HALLUCINATION,
    ])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == ""
    assert len(fake.calls) == 3


def test_prompt_retry_uses_session_snapshot_when_prompt_changes_mid_decode(whisper):
    backend, fake = whisper([PROMPT_ECHO, "recovered speech"])
    backend.initial_prompt = "Glossary: project.md."

    def replace_shared_prompt(call_number, _kwargs):
        if call_number == 1:
            backend.initial_prompt = "Glossary: another-session.md."

    fake.on_call = replace_shared_prompt
    feed_seconds(backend, 2.5, chunk=speechy())

    assert backend.finalize() == "recovered speech"
    assert len(fake.calls) == 2
    assert fake.calls[0][1]["initial_prompt"] == "Glossary: project.md."
    assert fake.calls[1][1]["initial_prompt"] is None


def test_prompt_hallucination_retries_whole_clip_after_segment_commit(whisper):
    backend, fake = whisper(["early segment", PROMPT_HALLUCINATION, "recovered whole clip"])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, MIN_SEGMENT_S, chunk=speechy())
    feed_seconds(backend, SEGMENT_SILENCE_S, chunk=quiet())

    assert backend._span_had_speech is False  # noqa: SLF001 — segment was committed
    assert backend.finalize() == "recovered whole clip"
    assert len(fake.calls) == 3
    assert fake.calls[-1][1]["initial_prompt"] is None
    assert fake.calls[-1][1]["temperature"] == 0.0


def test_true_silence_span_is_consumed(whisper):
    # An all-silence span is consumed without a model decode (no retry loop).
    backend, fake = whisper([""])
    feed_seconds(backend, MIN_SEGMENT_S + 1, chunk=quiet())
    assert fake.calls == []
    assert backend._decoded_samples > 0  # noqa: SLF001 — silence consumed


# ---- speechless-span hallucination guard (field bug, 2026-08-04) -------------
# Two ~50s dictations came back with "Closed Captioning by ..." credits and a
# trailing "Thank you." fabricated from the stop pause / stop-key click. The
# segments carried confident metadata (no_speech_prob=0.00, clean logprob and
# compression), so only audio evidence can catch the class.


def test_speechless_batch_clip_skips_model_decode(whisper):
    backend, fake = whisper(["Closed Captioning by Example"])
    feed_seconds(backend, 5.0, chunk=quiet())

    assert backend.finalize() == ""
    assert fake.calls == []


def test_sparse_speech_in_long_batch_is_not_dropped(whisper):
    backend, fake = whisper(["sparse but real speech"])
    backend.segmenting_enabled = False
    feed_seconds(backend, 59.0, chunk=quiet())
    feed_seconds(backend, 1.0, chunk=speechy())

    assert backend.finalize() == "sparse but real speech"
    assert len(fake.calls) == 1


def test_batch_stop_click_does_not_become_transcript(whisper):
    backend, fake = whisper(["Thank you."])
    pcm = np.zeros(60 * SAMPLE_RATE, dtype=np.float32)
    pcm[-int(0.25 * SAMPLE_RATE):] = 0.1

    assert transcribe_clip(backend, pcm) == ""
    assert fake.calls == []


def test_room_tone_and_stop_click_skip_model_decode(whisper):
    # Field clip: 9.6 s of room tone, then the stop-key click. The click
    # counts as tracked speech, so the glossary decode ran and looped
    # through every temperature fallback (7.4 s stop→text) only for the
    # speechless-span guard to discard the text. The guard's verdict
    # depends on the audio alone, so it must run before the model does.
    backend, fake = whisper([PROMPT_HALLUCINATION])
    backend.initial_prompt = "Glossary: project.md."
    feed_seconds(backend, 9.6, chunk=loud(0.001))
    feed_seconds(backend, 0.2, chunk=loud(0.05))

    assert backend.finalize() == ""
    assert fake.calls == []


def test_speechless_tail_is_never_decoded(whisper):
    backend, fake = whisper(["segment one", "segment two", "Thank you."])
    feed_seconds(backend, HARD_SEGMENT_S)
    feed_seconds(backend, HARD_SEGMENT_S)
    # Trailing pause at room-tone level, then the stop-key click itself.
    feed_seconds(backend, 0.6, chunk=np.full(CHUNK, 0.006, dtype=np.float32))
    backend.feed_chunk(loud())
    text = backend.finalize()
    assert text == "segment one segment two"
    assert backend.final_tail == ""
    assert len(fake.calls) == 2  # the tail decode never ran


def test_speech_bearing_tail_still_decodes(whisper):
    backend, fake = whisper(["segment one", "segment two", "and that is it"])
    feed_seconds(backend, HARD_SEGMENT_S)
    feed_seconds(backend, HARD_SEGMENT_S)
    feed_seconds(backend, 0.5, chunk=speechy())
    feed_seconds(backend, 0.5, chunk=quiet())
    text = backend.finalize()
    assert text == "segment one segment two and that is it"
    assert backend.final_tail == "and that is it"
    assert len(fake.calls) == 3


def test_tail_speech_evidence_gates():
    level = 0.1
    room_tone = np.full(SAMPLE_RATE, 0.006, dtype=np.float32)
    assert not stt_mod._tail_speech_evidence(room_tone, level)
    # A click confined to the final 0.3s (the stop keypress) is not evidence.
    click = room_tone.copy()
    click[-int(0.25 * SAMPLE_RATE):] = 0.08
    assert not stt_mod._tail_speech_evidence(click, level)
    # A real trailing phrase before the stop is evidence.
    phrase = room_tone.copy()
    phrase[: int(0.4 * SAMPLE_RATE)] = 0.06
    assert stt_mod._tail_speech_evidence(phrase, level)


def test_single_blip_span_does_not_count_as_speech(whisper):
    # One 100ms room-tone blip over the adaptive threshold used to arm the
    # tail decode; a span needs a sustained 0.2s run to count.
    backend, _fake = whisper(["unused"])
    feed_seconds(backend, 1, chunk=quiet())
    backend.feed_chunk(loud())
    assert backend._span_had_speech is False  # noqa: SLF001 — single blip
    backend.feed_chunk(loud())
    backend.feed_chunk(loud())
    assert backend._span_had_speech is True  # noqa: SLF001 — sustained run
