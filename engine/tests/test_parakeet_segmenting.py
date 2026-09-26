"""ParakeetBackend session decoding (fake decoder — tests never load MLX).

Parakeet decodes each pause-bounded segment as one whole span while the user
speaks, then only the tail at stop, so the server can clean segments during
recording. Spans past the decode window are split into overlapping windows
whose shared words must appear once in the merged text. Stream Typing
previews decode the open span without changing what the final text is.
"""

import sys
import types

import numpy as np
import pytest

import velora_engine.stt as stt_mod
from velora_engine.stt import (
    HARD_SEGMENT_S,
    MIN_SEGMENT_S,
    SAMPLE_RATE,
    SEGMENT_SILENCE_S,
    ParakeetBackend,
    transcribe_clip,
)

pytestmark = pytest.mark.usefixtures("fake_stt")

CHUNK = SAMPLE_RATE // 10  # 100ms feed chunks, like the app sends
WORD_S = 0.5  # fake token duration


def loud() -> np.ndarray:
    return np.full(CHUNK, 0.1, dtype=np.float32)


def quiet() -> np.ndarray:
    return np.zeros(CHUNK, dtype=np.float32)


def tokens(text: str) -> list:
    """Window-relative tokens, one per word, one second apart."""
    return [
        stt_mod._Token(" " + word, float(i), float(i) + WORD_S)  # noqa: SLF001
        for i, word in enumerate(text.split())
    ]


class FakeDecoder:
    """Stands in for the model call: records span lengths, answers in order
    (the last answer repeats)."""

    def __init__(self, texts):
        self.texts = list(texts)
        self.calls: list[int] = []
        self.fail_next = 0

    def __call__(self, audio):
        if self.fail_next > 0:
            self.fail_next -= 1
            raise RuntimeError("decode boom")
        self.calls.append(len(audio))
        text = self.texts.pop(0) if len(self.texts) > 1 else self.texts[0]
        return tokens(text)


@pytest.fixture
def parakeet(monkeypatch):
    def make(decoder):
        backend = ParakeetBackend("mlx-community/parakeet-tdt-0.6b-v2")
        backend._model = object()  # noqa: SLF001 — skip load(); decode is faked
        monkeypatch.setattr(backend, "_decode_tokens", decoder)
        backend.start_session()
        return backend

    return make


def feed(backend, seconds, chunk) -> list[str]:
    """Feed `seconds` of one chunk kind; returns the segments it produced."""
    segments = []
    for _ in range(round(seconds * 10)):
        backend.feed_chunk(chunk())
        segments += backend.take_new_segments()
    return segments


# ---- pause-bounded segments ----------------------------------------------------


def test_one_segment_per_pause_then_tail_at_stop(parakeet):
    decoder = FakeDecoder(["first part", "second part", "the tail"])
    backend = parakeet(decoder)

    segments = feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    segments += feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    segments += feed(backend, 3, loud)

    assert segments == ["first part", "second part"]
    assert len(decoder.calls) == 2

    # The server's integrity check: segments + tail rebuild the final exactly.
    assert backend.finalize() == "first part second part the tail"
    assert backend.segments_used_for_final is True
    assert backend.final_tail == "the tail"
    assert len(decoder.calls) == 3


def test_segment_decodes_the_whole_span_not_feed_chunks(parakeet):
    decoder = FakeDecoder(["one span"])
    backend = parakeet(decoder)

    feed(backend, MIN_SEGMENT_S + 2, loud)
    assert decoder.calls == []  # nothing decoded per 100 ms (or 0.5 s) chunk

    feed(backend, SEGMENT_SILENCE_S, quiet)
    span_s = MIN_SEGMENT_S + 2 + SEGMENT_SILENCE_S
    assert decoder.calls == [round(span_s * SAMPLE_RATE)]


def test_short_pause_before_min_segment_does_not_close(parakeet):
    decoder = FakeDecoder(["unused"])
    backend = parakeet(decoder)

    segments = feed(backend, MIN_SEGMENT_S / 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    segments += feed(backend, 2, loud)

    assert segments == []
    assert decoder.calls == []


def test_past_hard_limit_a_200ms_quiet_stretch_closes(parakeet):
    decoder = FakeDecoder(["long run"])
    backend = parakeet(decoder)

    segments = feed(backend, HARD_SEGMENT_S + 1, loud)
    assert segments == []  # never cut mid-speech

    # One quiet 100 ms chunk can be the closure inside a word.
    segments += feed(backend, 0.1, quiet)
    assert segments == []

    segments += feed(backend, 0.1, quiet)
    assert segments == ["long run"]


def test_steady_noise_is_never_cut_and_decodes_whole_at_stop(parakeet):
    # Room noise the tracker always hears as speech: no chunk is ever quiet.
    # A cut there could split a word. Parakeet cuts only in a pause (Whisper
    # cuts at HARD_SEGMENT_S even mid-speech), so this session is not
    # segmented and the whole clip decodes once at stop.
    decoder = FakeDecoder(["the whole noisy clip"])
    backend = parakeet(decoder)

    segments = feed(backend, 70, loud)

    assert segments == []
    assert decoder.calls == []
    assert backend.finalize() == "the whole noisy clip"
    assert decoder.calls == [70 * SAMPLE_RATE]


def test_short_clip_is_one_whole_decode(parakeet):
    decoder = FakeDecoder(["hello there"])
    backend = parakeet(decoder)
    feed(backend, 5, loud)

    assert backend.finalize() == "hello there"
    assert backend.segments_used_for_final is False
    assert backend.final_tail == ""
    assert decoder.calls == [5 * SAMPLE_RATE]


def test_blank_segment_is_consumed_without_emitting(parakeet):
    decoder = FakeDecoder(["first part", "", "the tail"])
    backend = parakeet(decoder)

    segments = feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S, quiet)
    segments += feed(backend, MIN_SEGMENT_S, quiet)  # closes with no words
    segments += feed(backend, 2, loud)

    assert segments == ["first part"]
    assert backend.finalize() == "first part the tail"
    assert backend.final_tail == "the tail"
    # The blank span is not decoded again at stop.
    assert decoder.calls[-1] == 2 * SAMPLE_RATE


def test_empty_decode_of_a_speech_span_keeps_its_audio_for_the_final(parakeet):
    decoder = FakeDecoder(["first part", "", "second part the tail"])
    backend = parakeet(decoder)

    segments = feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    # A loud span the model returned nothing for: its words are not known to
    # be absent, so it stays pending instead of being consumed.
    segments += feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    segments += feed(backend, 2, loud)

    assert segments == ["first part"]
    assert backend.finalize() == "first part second part the tail"
    # The first segment closed as its pause reached SEGMENT_SILENCE_S; the
    # tail decode covers everything after it, the empty span included.
    first_span_s = MIN_SEGMENT_S + 2 + SEGMENT_SILENCE_S
    total_s = 2 * (MIN_SEGMENT_S + 2 + SEGMENT_SILENCE_S + 0.3) + 2
    assert decoder.calls[-1] == round((total_s - first_span_s) * SAMPLE_RATE)


def test_empty_speech_span_retries_back_off_to_a_bounded_count(parakeet):
    # Speech the model always returns nothing for (hum the tracker hears as
    # speech), with a 1 s pause every 6 s. Each retry decodes the whole
    # growing span, so the wait doubles: 3, 6, 12, 24, then 48 s.
    #
    #   decode at  11.7  17.7  23.7  35.7  59.7  107.7  155.7  203.7  251.7  299.7
    #   next wait     3     6    12    24    48     48     48     48     48
    #
    # A fixed 3 s wait would decode at nearly every pause: about 48 times.
    backend = parakeet(FakeDecoder([""]))
    span_decodes = []
    transcribe = backend._transcribe  # noqa: SLF001
    backend._transcribe = lambda audio: span_decodes.append(len(audio)) or transcribe(audio)  # noqa: SLF001

    for _ in range(50):  # 50 x 6 s = 5 minutes
        feed(backend, 5, loud)
        feed(backend, 1, quiet)

    assert len(span_decodes) == 10


def test_a_decoded_span_resets_the_retry_backoff(parakeet):
    # Two empty decodes grow the wait to 12 s; words from the span reset it,
    # so the next empty speech span is retried 3 s later again.
    decoder = FakeDecoder(["", "", "words at last", ""])
    backend = parakeet(decoder)

    segments = []
    for _ in range(4):  # decodes at 11.7 (empty), 17.7 (empty), 23.7 (words)
        segments += feed(backend, 5, loud)
        segments += feed(backend, 1, quiet)
    assert segments == ["words at last"]

    for _ in range(3):  # empty at 35.7, retried 3 s later at the 41.7 pause
        feed(backend, 5, loud)
        feed(backend, 1, quiet)
    assert len(decoder.calls) == 5


def test_empty_tail_with_speech_falls_back_to_whole_clip(parakeet):
    decoder = FakeDecoder(["first part", "", "whole clip text"])
    backend = parakeet(decoder)

    feed(backend, MIN_SEGMENT_S + 2, loud)
    feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    feed(backend, 3, loud)

    assert backend.finalize() == "whole clip text"
    assert backend.segments_used_for_final is False
    clip_s = MIN_SEGMENT_S + 2 + SEGMENT_SILENCE_S + 0.3 + 3
    assert decoder.calls[-1] == round(clip_s * SAMPLE_RATE)


def test_finalize_and_abort_release_the_mlx_cache(parakeet, monkeypatch):
    # A stand-in mlx.core: the test counts cache clears without loading MLX.
    cleared = []
    fake_core = types.ModuleType("mlx.core")
    fake_core.clear_cache = lambda: cleared.append(True)
    fake_mlx = types.ModuleType("mlx")
    fake_mlx.core = fake_core
    monkeypatch.setitem(sys.modules, "mlx", fake_mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", fake_core)
    backend = parakeet(FakeDecoder(["some words"]))

    feed(backend, 3, loud)
    backend.finalize()
    assert len(cleared) == 1

    backend.start_session()
    feed(backend, 3, loud)
    backend.reset()  # the server's abort path
    assert len(cleared) == 2


def test_all_silence_session_is_not_decoded_again_at_stop(parakeet):
    decoder = FakeDecoder([""])
    backend = parakeet(decoder)

    feed(backend, MIN_SEGMENT_S, quiet)  # closes one blank span
    feed(backend, SEGMENT_SILENCE_S, quiet)

    # The blank span is never decoded again; only the undecoded tail is.
    assert backend.finalize() == ""
    assert decoder.calls == [
        round(MIN_SEGMENT_S * SAMPLE_RATE),
        round(SEGMENT_SILENCE_S * SAMPLE_RATE),
    ]


def test_speech_after_blank_spans_decodes_only_the_tail(parakeet):
    decoder = FakeDecoder(["", "late words"])
    backend = parakeet(decoder)

    feed(backend, MIN_SEGMENT_S, quiet)  # closes one blank span
    feed(backend, 2, loud)

    assert backend.finalize() == "late words"
    assert backend.segments_used_for_final is False  # no segment was cleaned
    assert decoder.calls[-1] == 2 * SAMPLE_RATE


def test_words_the_tracker_missed_are_kept(parakeet):
    # Speech too quiet for the tracker still decoded to words in a segment.
    decoder = FakeDecoder(["whispered words", ""])
    backend = parakeet(decoder)

    segments = feed(backend, MIN_SEGMENT_S, quiet)
    feed(backend, 1, quiet)

    assert segments == ["whispered words"]
    assert backend.finalize() == "whispered words"


def test_clip_under_the_minimum_is_not_decoded(parakeet):
    decoder = FakeDecoder(["unused"])
    backend = parakeet(decoder)

    backend.feed_chunk(np.full(round(0.1 * SAMPLE_RATE), 0.1, dtype=np.float32))

    assert backend.finalize() == ""
    assert decoder.calls == []


def test_segment_decode_materializes_only_its_own_span(parakeet, monkeypatch):
    backend = parakeet(FakeDecoder(["first part", "second part"]))
    feed(backend, MIN_SEGMENT_S + 2, loud)
    feed(backend, SEGMENT_SILENCE_S, quiet)  # first segment closes

    # Count every sample copied into a joined buffer while the second
    # segment closes: only its own span, never the whole session.
    real_concatenate = np.concatenate
    copied = []

    def spy(arrays, *args, **kwargs):
        arrays = list(arrays)
        copied.append(sum(len(a) for a in arrays))
        return real_concatenate(arrays, *args, **kwargs)

    monkeypatch.setattr(stt_mod.np, "concatenate", spy)
    segments = feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S, quiet)

    assert segments == ["second part"]
    assert sum(copied) <= round((MIN_SEGMENT_S + 2 + SEGMENT_SILENCE_S) * SAMPLE_RATE)


def test_segment_decode_failure_falls_back_to_whole_clip(parakeet):
    decoder = FakeDecoder(["whole clip text"])
    decoder.fail_next = 1
    backend = parakeet(decoder)

    segments = feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    segments += feed(backend, MIN_SEGMENT_S + 2, loud)
    segments += feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)

    assert segments == []  # segmenting stopped after the failure
    assert backend.finalize() == "whole clip text"
    assert backend.segments_used_for_final is False
    assert len(decoder.calls) == 1


def test_tail_decode_failure_falls_back_to_whole_clip(parakeet):
    decoder = FakeDecoder(["first part", "whole clip text"])
    backend = parakeet(decoder)

    feed(backend, MIN_SEGMENT_S + 2, loud)
    feed(backend, SEGMENT_SILENCE_S + 0.3, quiet)
    feed(backend, 3, loud)
    decoder.fail_next = 1  # the tail decode at stop

    assert backend.finalize() == "whole clip text"
    assert backend.segments_used_for_final is False
    clip_s = MIN_SEGMENT_S + 2 + SEGMENT_SILENCE_S + 0.3 + 3
    assert decoder.calls[-1] == round(clip_s * SAMPLE_RATE)


def test_short_all_silence_clip_decodes_once_to_nothing(parakeet):
    decoder = FakeDecoder([""])
    backend = parakeet(decoder)

    feed(backend, 3, quiet)

    assert backend.finalize() == ""
    assert decoder.calls == [3 * SAMPLE_RATE]


def test_speech_too_quiet_for_the_tracker_is_still_decoded(parakeet):
    # The tracker's floor is 0.003 RMS; Parakeet still hears a speaker below
    # it (2 of 486 CV India clips). Unlike Whisper, no integrity guard throws
    # that text away, so the clip must be decoded.
    decoder = FakeDecoder(["what are the facts"])
    backend = parakeet(decoder)

    feed(backend, 3, lambda: np.full(CHUNK, 0.002, dtype=np.float32))

    assert backend.finalize() == "what are the facts"


def test_decoded_spans_are_disjoint_and_cover_the_clip(parakeet):
    # Every chunk carries its own sample values, so the decoded spans can be
    # laid end to end and compared with what was fed. The plan closes one
    # segment at a pause, one past the hard limit, then the tail.
    spans = []

    def decode(audio):
        spans.append(np.array(audio, copy=True))
        return tokens("words")

    backend = parakeet(decode)
    fed = []
    plan = [(MIN_SEGMENT_S + 2, 0.1), (1, 0.0), (HARD_SEGMENT_S + 1, 0.1), (0.2, 0.0), (2, 0.1)]
    for seconds, level in plan:
        for _ in range(round(seconds * 10)):
            chunk = np.full(CHUNK, level + 1e-5 * len(fed), dtype=np.float32)
            fed.append(chunk)
            backend.feed_chunk(chunk)
    backend.finalize()

    assert len(spans) == 3
    np.testing.assert_array_equal(np.concatenate(spans), np.concatenate(fed))


def test_transcribe_clip_decodes_once(parakeet):
    decoder = FakeDecoder(["archived clip"])
    backend = parakeet(decoder)
    pcm = np.concatenate(
        [loud() for _ in range(120)] + [quiet() for _ in range(10)] + [loud() for _ in range(30)]
    )

    assert transcribe_clip(backend, pcm) == "archived clip"
    assert decoder.calls == [len(pcm)]
    assert backend.segmenting_enabled is True  # restored afterwards


# ---- long spans: overlapping windows -------------------------------------------


def timeline_decoder(calls):
    """Decoder over a fake timeline: one word per second, named by its second.

    The audio sample values carry absolute time (see `timeline_audio`), so the
    decoder knows which window it got and answers with that window's words,
    in window-relative times, exactly as the model would.
    """

    def decode(audio):
        start_s = float(audio[0])
        calls.append((round(start_s), round(len(audio) / SAMPLE_RATE)))
        first = int(np.ceil(start_s))
        last = start_s + len(audio) / SAMPLE_RATE - WORD_S
        return [
            stt_mod._Token(f" w{t}", t - start_s, t - start_s + WORD_S)  # noqa: SLF001
            for t in range(first, int(np.floor(last)) + 1)
        ]

    return decode


def timeline_audio(seconds: int) -> np.ndarray:
    return (np.arange(seconds * SAMPLE_RATE) / SAMPLE_RATE).astype(np.float32)


def test_long_span_decodes_in_overlapping_windows_without_duplicates(parakeet):
    calls = []
    backend = parakeet(timeline_decoder(calls))
    seconds = 250

    text = transcribe_clip(backend, timeline_audio(seconds))

    window_s = stt_mod._PARAKEET_WINDOW_S  # noqa: SLF001
    step_s = window_s - stt_mod._PARAKEET_OVERLAP_S  # noqa: SLF001
    assert calls == [
        (0, window_s),
        (step_s, window_s),
        (2 * step_s, seconds - 2 * step_s),
    ]
    assert text.split() == [f"w{t}" for t in range(seconds)]


def window_answers(answers):
    """Decoder that answers each window in turn: the words given for it, in
    window-relative times, or nothing."""
    calls = []

    def decode(audio):
        calls.append(len(audio))
        words = answers[len(calls) - 1]
        return tokens(words) if words else []

    return decode


def test_empty_window_over_speech_logs_its_offset(parakeet, caplog):
    # A 250 s span decodes as windows at 0, 105 and 210 s. The middle one
    # returns nothing although its new audio is speech: a model failure,
    # logged with where it happened.
    backend = parakeet(window_answers(["early words", "", "late words"]))
    pcm = np.full(250 * SAMPLE_RATE, 0.1, dtype=np.float32)

    with caplog.at_level("WARNING", logger="velora.stt"):
        transcribe_clip(backend, pcm)

    step_s = stt_mod._PARAKEET_WINDOW_S - stt_mod._PARAKEET_OVERLAP_S  # noqa: SLF001
    assert f"parakeet window at {step_s:.1f} s decoded empty over speech" in caplog.text


def test_silent_window_decodes_empty_without_a_warning(parakeet, caplog):
    # The middle window's new audio (120-225 s) is silence: empty is right.
    backend = parakeet(window_answers(["early words", "", "late words"]))
    pcm = np.concatenate([
        np.full(120 * SAMPLE_RATE, 0.1, dtype=np.float32),
        np.zeros(105 * SAMPLE_RATE, dtype=np.float32),
        np.full(25 * SAMPLE_RATE, 0.1, dtype=np.float32),
    ])

    with caplog.at_level("WARNING", logger="velora.stt"):
        transcribe_clip(backend, pcm)

    assert "decoded empty" not in caplog.text


def test_span_within_one_window_is_one_decode(parakeet):
    calls = []
    backend = parakeet(timeline_decoder(calls))
    seconds = int(stt_mod._PARAKEET_WINDOW_S)  # noqa: SLF001

    text = transcribe_clip(backend, timeline_audio(seconds))

    assert calls == [(0, seconds)]
    assert len(text.split()) == seconds


def test_merge_keeps_shared_words_once():
    merge = stt_mod._merge_overlap  # noqa: SLF001
    kept = [stt_mod._Token(f" w{t}", t, t + WORD_S) for t in range(0, 20)]  # noqa: SLF001
    new = [stt_mod._Token(f" w{t}", t + 0.04, t + WORD_S) for t in range(12, 30)]  # noqa: SLF001

    merged = merge(kept, new, seam_start_s=12.0, seam_end_s=20.0)

    assert [t.text.strip() for t in merged] == [f"w{t}" for t in range(30)]


def token(text: str, start: float) -> "stt_mod._Token":
    return stt_mod._Token(" " + text, start, start + WORD_S)  # noqa: SLF001


def words_of(merged) -> list[str]:
    return [t.text.strip() for t in merged]


def test_merge_aligns_repeated_words_on_the_closest_timing():
    # "no no no ...": the new window lost the word straddling its start, so
    # two equally long runs agree within tolerance. Only one of them pairs
    # each word with itself (zero timing error); the other is off by a word.
    kept = [token("no", t) for t in range(100, 106)]
    new = [token("no", t) for t in range(101, 107)]

    merged = stt_mod._merge_overlap(kept, new, seam_start_s=100.0, seam_end_s=106.0)  # noqa: SLF001

    assert [t.start for t in merged] == [float(t) for t in range(100, 107)]


def test_merge_anchor_survives_drift_and_a_disagreeing_word():
    # The new window hears every word 0.8 s later and reads w16 as x16. The
    # seam midpoint (16.3 s) falls between the two timings of that word, so a
    # midpoint cut would keep both readings.
    kept = [token(f"w{t}", t) for t in range(0, 21)]
    new = [token("x16" if t == 16 else f"w{t}", t + 0.8) for t in range(12, 30)]

    merged = stt_mod._merge_overlap(kept, new, seam_start_s=12.0, seam_end_s=20.6)  # noqa: SLF001

    expected = [f"w{t}" for t in range(16)] + ["x16"] + [f"w{t}" for t in range(17, 30)]
    assert words_of(merged) == expected


def test_merge_realistic_seam_keeps_each_word_once():
    # Real seams: both windows decode the same audio, so the tokens agree and
    # timings drift by at most 0.2 s. Dense speech (a word every 0.3 s) with
    # repeated common words must still come out exactly once.
    words = "the cat and the dog sat on the mat and the rat ran".split() * 6
    kept = [token(w, i * 0.3) for i, w in enumerate(words) if i * 0.3 < 20.0]
    drifts = [0.2, -0.1, 0.0, 0.15, -0.2, 0.05]
    new = [
        token(w, i * 0.3 + drifts[i % len(drifts)])
        for i, w in enumerate(words)
        if i * 0.3 >= 12.0
    ]

    merged = stt_mod._merge_overlap(kept, new, seam_start_s=12.0, seam_end_s=20.0)  # noqa: SLF001

    assert words_of(merged) == words


@pytest.mark.parametrize("kept_drift, new_drift", [(-1.2, 1.2), (1.2, -1.2)])
def test_merge_keeps_one_copy_of_a_lone_word_under_opposite_drift(kept_drift, new_drift):
    # One word ("okay", truly at 112.5 s) is all the seam holds, so no run
    # anchors the join. Each window places it 1.2 s off in opposite
    # directions, on either side of the seam midpoint.
    seam_start, seam_end, word_at = 105.0, 120.0, 112.5
    kept = [token(f"a{t}", t) for t in range(90, 105)] + [token("okay", word_at + kept_drift)]
    new = [token("okay", word_at + new_drift)] + [token(f"b{t}", t) for t in range(120, 130)]

    merged = stt_mod._merge_overlap(kept, new, seam_start_s=seam_start, seam_end_s=seam_end)  # noqa: SLF001

    expected = [f"a{t}" for t in range(90, 105)] + ["okay"] + [f"b{t}" for t in range(120, 130)]
    assert words_of(merged) == expected


def test_merge_without_shared_run_cuts_in_the_widest_gap():
    # The windows disagree on every word; both hear a pause from 12.5 s to
    # 15 s. The cut lands in that pause, not mid-speech at the midpoint.
    seam_times = [12, 15, 16, 17, 18, 19]
    kept = [token(f"a{t}", t) for t in range(12)] + [token(f"a{t}", t) for t in seam_times]
    new = [token(f"b{t}", t) for t in seam_times] + [token(f"b{t}", t) for t in range(20, 30)]

    merged = stt_mod._merge_overlap(kept, new, seam_start_s=12.0, seam_end_s=20.0)  # noqa: SLF001

    expected = [f"a{t}" for t in range(13)] + [f"b{t}" for t in range(15, 30)]
    assert words_of(merged) == expected


# ---- Stream Typing previews ----------------------------------------------------


def span_decoder(calls):
    """Answers with the span length, so each text names the audio it came
    from and a preview decode cannot shift the answers segments get."""

    def decode(audio):
        calls.append(len(audio))
        return tokens(f"s{len(audio)}")

    return decode


def run_with_previews(backend, plan) -> list[str]:
    """Feed `plan` like the server does: after each chunk, decode the pending
    preview request if there is one. Returns the partials shown."""
    partials = []
    for seconds, chunk in plan:
        for _ in range(round(seconds * 10)):
            backend.feed_chunk(chunk())
            request = backend.take_preview_request()
            if request is not None:
                partials.append(backend.decode_preview(request))
    return partials


def test_previews_arrive_before_the_first_segment_closes(parakeet):
    calls = []
    backend = parakeet(span_decoder(calls))
    backend.preview_enabled = True

    partials = run_with_previews(backend, [(3, loud)])

    assert backend.take_new_segments() == []  # no segment closed yet
    # One partial per _PARAKEET_PREVIEW_INTERVAL_S of new audio, each over
    # the whole open span.
    interval_s = stt_mod._PARAKEET_PREVIEW_INTERVAL_S  # noqa: SLF001
    assert len(partials) == round(3 / interval_s)
    assert partials[-1] == f"s{3 * SAMPLE_RATE}"


def test_preview_audio_is_capped_to_the_preview_window(parakeet):
    # Speech with no pause never closes a segment. Like Whisper's, each
    # preview decodes at most the last PREVIEW_WINDOW_S, not the whole span.
    calls = []
    backend = parakeet(span_decoder(calls))
    backend.preview_enabled = True

    run_with_previews(backend, [(40, loud)])

    window = round(stt_mod.PREVIEW_WINDOW_S * SAMPLE_RATE)
    assert max(calls) == window
    assert calls[-1] == window


def test_previews_leave_segments_and_final_text_unchanged(parakeet):
    plan = [
        (MIN_SEGMENT_S + 2, loud),
        (SEGMENT_SILENCE_S + 0.3, quiet),
        (MIN_SEGMENT_S + 2, loud),
        (SEGMENT_SILENCE_S + 0.3, quiet),
        (3, loud),
    ]
    results = {}
    for previews in (False, True):
        backend = parakeet(span_decoder([]))
        backend.preview_enabled = previews
        partials = run_with_previews(backend, plan)
        segments = backend.take_new_segments()
        results[previews] = (segments, backend.finalize(), backend.final_tail, partials)

    off_segments, off_final, off_tail, off_partials = results[False]
    on_segments, on_final, on_tail, on_partials = results[True]
    assert off_partials == []
    assert (on_segments, on_final, on_tail) == (off_segments, off_final, off_tail)
    # After the first segment, previews show it followed by the open span.
    assert any(p.startswith(off_segments[0] + " ") for p in on_partials)
