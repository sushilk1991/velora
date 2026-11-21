"""Wave 2 V-04: LocalAgreement preview lane + Parakeet CPU-budget backoff.

`StreamingLocalAgreement.update` is the pure two-window gate (first window
confirms nothing); `display_update` is what the backends show — first-window
and zero-overlap passthroughs preserve the pre-existing contract that a lone
`decode_preview` call returns its text (test_stt_segmenting /
test_parakeet_segmenting rely on that), while from the second agreeing
window onward only the confirmed prefix is displayed.
"""

import numpy as np
import pytest

import velora_engine.stt as stt_mod
from velora_engine.preview_agreement import StreamingLocalAgreement
from velora_engine.stt import (
    SAMPLE_RATE,
    ParakeetBackend,
    WhisperBackend,
    WhisperPreviewRequest,
)

pytestmark = pytest.mark.usefixtures("fake_stt")

CHUNK = SAMPLE_RATE // 10  # 100ms feed chunks, like the app sends


def loud() -> np.ndarray:
    return np.full(CHUNK, 0.1, dtype=np.float32)


def request(committed=()) -> WhisperPreviewRequest:
    return WhisperPreviewRequest(
        audio=np.zeros(SAMPLE_RATE, dtype=np.float32),
        committed_segments=tuple(committed),
    )


def sequence_decoder(texts):
    """Stub decode returning the queued texts in order (last repeats)."""
    queue = list(texts)

    def decode(_audio, **_kwargs):
        return queue.pop(0) if len(queue) > 1 else queue[0]

    return decode


# ---- pure gate: update() ------------------------------------------------------


def test_two_windows_commit_stable_prefix_and_hold_volatile_tail():
    gate = StreamingLocalAgreement()

    assert gate.update("hello brave world") == ""  # one window: nothing agreed
    assert gate.update("hello brave word") == "hello brave"
    assert gate.tentative_text == "word"
    assert gate.update("hello brave word now") == "hello brave word"


def test_tail_word_changes_never_reach_confirmed_text():
    gate = StreamingLocalAgreement()
    outputs = [
        gate.update(text)
        for text in (
            "hello brave world",
            "hello brave word",
            "hello brave worm",
            "hello brave worlds",
        )
    ]

    assert outputs == ["", "hello brave", "hello brave", "hello brave"]


def test_punctuation_and_casing_match_with_latest_surface_form():
    gate = StreamingLocalAgreement()
    gate.update("Hello world this")

    # Same words keyed without case/edge punctuation; the newer decode's
    # surface form is what comes back.
    assert gate.update("hello, WORLD. this again") == "hello, WORLD. this"
    # An agreed word can still be re-cased/re-punctuated by a later window.
    assert gate.update("Hello world... this again now") == "Hello world... this again"


def test_pure_punctuation_tokens_do_not_agree_with_each_other():
    gate = StreamingLocalAgreement()
    gate.update("hello , world")

    assert gate.update("hello . world") == "hello"


def test_empty_input_is_not_a_window():
    gate = StreamingLocalAgreement()
    gate.update("hello world")

    assert gate.update("") == ""
    assert gate.update("   ") == ""
    # The empty ticks did not break the pair: window two still agrees.
    assert gate.update("hello world again") == "hello world"


def test_confirmed_prefix_never_retracts_under_an_early_rewrite():
    gate = StreamingLocalAgreement()
    gate.update("hello brave new world")
    assert gate.update("hello brave new world today") == "hello brave new world"

    # A rewrite inside the confirmed prefix cannot retract shown words;
    # it is corrected (if at all) when the segment commits, not mid-preview.
    assert gate.update("hello brave old world today") == "hello brave new world"


def test_reset_clears_previous_and_confirmed():
    gate = StreamingLocalAgreement()
    gate.update("hello world")
    gate.update("hello world again")
    assert gate.confirmed_text == "hello world"

    gate.reset()

    assert gate.confirmed_text == ""
    assert gate.latest_text == ""
    assert gate.tentative_text == ""
    assert gate.has_previous is False
    assert gate.update("hello world again") == ""  # back to a first window


# ---- display policy: display_update() -----------------------------------------


def test_display_first_window_passes_through_then_holds_the_tail():
    gate = StreamingLocalAgreement()

    # Lone first preview still shows (existing decode_preview contract)…
    assert gate.display_update("hello brave world") == "hello brave world"
    # …but from the second window only agreed words show.
    assert gate.display_update("hello brave word") == "hello brave"
    assert gate.display_update("hello brave word now") == "hello brave word"


def test_display_zero_overlap_restarts_instead_of_blanking():
    gate = StreamingLocalAgreement()
    assert gate.display_update("hello world") == "hello world"

    # Fully rewritten hypothesis (or a slid preview window): show the new
    # text and re-seed agreement on it instead of emitting nothing.
    assert gate.display_update("goodbye now") == "goodbye now"
    assert gate.display_update("goodbye now friend") == "goodbye now"


def test_display_empty_input_returns_confirmed_not_stale_raw():
    gate = StreamingLocalAgreement()
    gate.display_update("hello world")
    gate.display_update("hello world again")

    assert gate.display_update("") == "hello world"


# ---- backend wiring -------------------------------------------------------------


def test_parakeet_single_preview_still_emits_its_text(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = ParakeetBackend("unused")
    backend._transcribe = sequence_decoder(["only preview"])  # noqa: SLF001

    assert backend.decode_preview(request()) == "only preview"


def test_parakeet_preview_gates_open_span_behind_verbatim_committed(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = ParakeetBackend("unused")
    backend._transcribe = sequence_decoder(  # noqa: SLF001
        ["hello brave world", "hello brave word", "fresh span words"]
    )
    committed = ("Already DONE.",)

    assert (
        backend.decode_preview(request(committed))
        == "Already DONE. hello brave world"
    )
    assert backend.decode_preview(request(committed)) == "Already DONE. hello brave"
    # A new committed segment starts a new open span: agreement restarts and
    # the (single) first window of the new span passes through in full.
    assert (
        backend.decode_preview(request(("Already DONE.", "next seg")))
        == "Already DONE. next seg fresh span words"
    )


def test_whisper_preview_gates_open_span_behind_verbatim_committed(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = WhisperBackend("unused")
    backend._decode = sequence_decoder(  # noqa: SLF001
        ["hello brave world", "hello brave word", "hello brave word now"]
    )
    committed = ("committed words.",)

    assert (
        backend.decode_preview(request(committed))
        == "committed words. hello brave world"
    )
    assert backend.decode_preview(request(committed)) == "committed words. hello brave"
    assert (
        backend.decode_preview(request(committed))
        == "committed words. hello brave word"
    )


def test_backend_reset_clears_preview_agreement(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = WhisperBackend("unused")
    backend._decode = sequence_decoder(["hello world", "hello world again"])  # noqa: SLF001
    backend.decode_preview(request())
    backend.decode_preview(request())
    assert backend._preview_agreement.confirmed_text == "hello world"  # noqa: SLF001

    backend.reset()

    assert backend._preview_agreement.has_previous is False  # noqa: SLF001
    assert backend._preview_agreement_committed == ()  # noqa: SLF001


# ---- Parakeet cadence + CPU budget ----------------------------------------------


def test_preview_cadence_constants():
    assert stt_mod._PARAKEET_PREVIEW_INTERVAL_S == 0.5  # noqa: SLF001
    assert stt_mod._PARAKEET_PREVIEW_BACKOFF_INTERVAL_S == 0.8  # noqa: SLF001
    assert stt_mod.PREVIEW_BASE_INTERVAL_S == 1.5


def test_parakeet_cpu_budget_backs_off_the_floor_and_reset_restores(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = ParakeetBackend("unused")
    backend._transcribe = sequence_decoder(["hello world"])  # noqa: SLF001
    backend._samples = 4 * SAMPLE_RATE  # noqa: SLF001 — 4 s take, budget 0.6 s
    # Three 0.25 s decodes, then one cheap 0.01 s decode. 0.25 keeps the
    # per-decode adaptation (elapsed * 1.5) below either floor, isolating
    # the cumulative-budget effect.
    times = iter([0.0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 0.76])
    monkeypatch.setattr(stt_mod.time, "perf_counter", lambda: next(times))

    backend.decode_preview(request())
    backend.decode_preview(request())
    assert backend._preview_decode_total_s == pytest.approx(0.5)  # noqa: SLF001
    assert backend._preview_backed_off is False  # noqa: SLF001
    assert backend._preview_interval_s == stt_mod._PARAKEET_PREVIEW_INTERVAL_S  # noqa: SLF001

    backend.decode_preview(request())  # cumulative 0.75 s > 15% of 4 s
    assert backend._preview_backed_off is True  # noqa: SLF001
    assert backend._preview_interval_s == stt_mod._PARAKEET_PREVIEW_BACKOFF_INTERVAL_S  # noqa: SLF001

    backend.decode_preview(request())  # cheap decode: floor stays backed off
    assert backend._preview_interval_s == stt_mod._PARAKEET_PREVIEW_BACKOFF_INTERVAL_S  # noqa: SLF001

    backend.reset()
    assert backend._preview_backed_off is False  # noqa: SLF001
    assert backend._preview_decode_total_s == 0.0  # noqa: SLF001
    assert backend._preview_interval_s == stt_mod._PARAKEET_PREVIEW_INTERVAL_S  # noqa: SLF001
    assert backend._preview_agreement.has_previous is False  # noqa: SLF001


def test_parakeet_cpu_budget_is_not_judged_before_a_two_second_take(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = ParakeetBackend("unused")
    backend._transcribe = sequence_decoder(["hello world"])  # noqa: SLF001
    backend._samples = SAMPLE_RATE  # noqa: SLF001 — 1 s take: ratio not judged yet
    times = iter([0.0, 0.25])
    monkeypatch.setattr(stt_mod.time, "perf_counter", lambda: next(times))

    backend.decode_preview(request())  # 0.25 s > 15% of 1 s, but take < 2 s

    assert backend._preview_backed_off is False  # noqa: SLF001
    assert backend._preview_interval_s == stt_mod._PARAKEET_PREVIEW_INTERVAL_S  # noqa: SLF001


@pytest.fixture
def parakeet(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)

    def make(decoder):
        backend = ParakeetBackend("unused")
        backend._model = object()  # noqa: SLF001 — skip load(); decode is faked
        monkeypatch.setattr(backend, "_decode_tokens", decoder)
        backend.start_session()
        backend.preview_enabled = True
        return backend

    return make


def tokens(text: str) -> list:
    return [
        stt_mod._Token(" " + word, float(i), float(i) + 0.5)  # noqa: SLF001
        for i, word in enumerate(text.split())
    ]


def test_parakeet_backed_off_floor_gates_the_next_preview_request(parakeet, monkeypatch):
    clock = [0.0]
    monkeypatch.setattr(stt_mod.time, "perf_counter", lambda: clock[0])

    def slow_decoder(_audio):
        clock[0] += 0.25  # each preview decode burns 0.25 s of wall time
        return tokens("hello brave world")

    backend = parakeet(slow_decoder)
    decoded_at_s = []

    def feed(seconds: float) -> None:
        for _ in range(round(seconds * 10)):
            backend.feed_chunk(loud())
            pending = backend.take_preview_request()
            if pending is not None:
                backend.decode_preview(pending)
                decoded_at_s.append(backend._samples / SAMPLE_RATE)  # noqa: SLF001

    feed(2.0)
    # Fast 0.5 s cadence up to the 2 s mark; the 4th decode takes cumulative
    # preview time to 1.0 s, past 15% of the 2 s taken so far.
    assert decoded_at_s == [0.5, 1.0, 1.5, 2.0]
    assert backend._preview_backed_off is True  # noqa: SLF001
    assert backend._preview_interval_s == stt_mod._PARAKEET_PREVIEW_BACKOFF_INTERVAL_S  # noqa: SLF001

    feed(0.7)  # 0.7 s of new audio: not due under the 0.8 s floor
    assert decoded_at_s == [0.5, 1.0, 1.5, 2.0]
    feed(0.1)  # 0.8 s of new audio: due again
    assert decoded_at_s == [0.5, 1.0, 1.5, 2.0, 2.8]


def test_whisper_cadence_floor_stays_at_base_interval(monkeypatch):
    monkeypatch.setattr(stt_mod, "_clear_mlx_cache", lambda: None)
    backend = WhisperBackend("unused")
    backend._decode = sequence_decoder(["hello world"])  # noqa: SLF001
    assert backend._preview_interval_s == stt_mod.PREVIEW_BASE_INTERVAL_S  # noqa: SLF001

    # Several slow-ish decodes: Whisper has no Parakeet CPU budget, and the
    # per-decode adaptation stays under the 1.5 s floor here.
    times = iter([0.0, 0.9, 0.9, 1.8, 1.8, 2.7])
    monkeypatch.setattr(stt_mod.time, "perf_counter", lambda: next(times))
    for _ in range(3):
        backend.decode_preview(request())

    assert backend._preview_interval_s == stt_mod.PREVIEW_BASE_INTERVAL_S  # noqa: SLF001
    assert not hasattr(backend, "_preview_backed_off")

    backend.reset()
    assert backend._preview_interval_s == stt_mod.PREVIEW_BASE_INTERVAL_S  # noqa: SLF001
