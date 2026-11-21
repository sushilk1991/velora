"""Provisional live speaker labels over 1.5 s windows; the batch path stays."""
from __future__ import annotations

import inspect

import numpy as np
import pytest

from velora_engine import diarization
from velora_engine.diarization import StreamingDiarizer, Turn

SR = 16_000
WINDOW = int(round(SR * 1.5))

A = np.array([1.0, 0.0, 0.0], dtype=np.float32)
B = np.array([0.0, 1.0, 0.0], dtype=np.float32)
C = np.array([0.0, 0.0, 1.0], dtype=np.float32)
# The audio level identifies the voice, so a stream can be built from a list.
LEVELS = {0.1: A, 0.2: B, 0.3: C}


def level_embedder(pcm: np.ndarray) -> np.ndarray | None:
    return LEVELS.get(round(float(np.abs(pcm).mean()), 3))


def window(level: float, samples: int = WINDOW) -> np.ndarray:
    return np.full(samples, level, dtype=np.float32)


def stream(levels: list[float]) -> np.ndarray:
    return np.concatenate([window(level) for level in levels])


class QueueEmbedder:
    """Hands out prepared embeddings, one per window, in order."""

    def __init__(self, embeddings: list[np.ndarray]) -> None:
        self.pending = list(embeddings)

    def __call__(self, pcm: np.ndarray) -> np.ndarray | None:
        return self.pending.pop(0)


def spans(turns: list[Turn]) -> list[tuple[float, float, str]]:
    return [(turn.start, turn.end, turn.speaker) for turn in turns]


def test_two_speakers_keep_consistent_labels_across_the_stream():
    diarizer = StreamingDiarizer(level_embedder)

    turns = diarizer.feed(stream([0.1, 0.1, 0.2, 0.2, 0.1]))

    # Consecutive windows of one voice close as one turn, in stream time.
    assert spans(turns) == [(0.0, 3.0, "s1"), (3.0, 6.0, "s2")]
    assert spans(diarizer.flush()) == [(6.0, 7.5, "s1")]
    assert diarizer.speaker_count == 2


def test_three_speakers_are_numbered_by_first_appearance():
    diarizer = StreamingDiarizer(level_embedder)

    turns = diarizer.feed(stream([0.3, 0.1, 0.2, 0.3]))

    assert spans(turns + diarizer.flush()) == [
        (0.0, 1.5, "s1"),   # the first voice heard takes s1, whatever its level
        (1.5, 3.0, "s2"),
        (3.0, 4.5, "s3"),
        (4.5, 6.0, "s1"),
    ]
    assert diarizer.speaker_count == 3


def test_arbitrary_feed_sizes_produce_the_same_stream():
    samples = stream([0.1, 0.2, 0.3, 0.1, 0.2])

    one_shot = StreamingDiarizer(level_embedder)
    expected = one_shot.feed(samples) + one_shot.flush()

    split = StreamingDiarizer(level_embedder)
    got: list[Turn] = []
    for start in range(0, len(samples), 5_000):
        got.extend(split.feed(samples[start:start + 5_000]))
    got.extend(split.flush())

    assert got == expected
    assert [turn.speaker for turn in expected] == ["s1", "s2", "s3", "s1", "s2"]


def test_a_partial_window_is_buffered_not_labelled():
    diarizer = StreamingDiarizer(level_embedder)

    assert diarizer.feed(window(0.1, WINDOW // 2)) == []
    assert diarizer.speaker_count == 0
    assert diarizer.feed(window(0.1, WINDOW // 2)) == []  # turn still open
    assert spans(diarizer.flush()) == [(0.0, 1.5, "s1")]


def test_silent_windows_never_spawn_a_speaker():
    diarizer = StreamingDiarizer(level_embedder)

    assert diarizer.feed(np.zeros(WINDOW * 4, dtype=np.float32)) == []
    assert diarizer.speaker_count == 0

    turns = diarizer.feed(stream([0.1, 0.0, 0.0, 0.1]))

    # Silence ends the turn and is then skipped; only real speech is labelled.
    # The four leading silent windows still advance stream time.
    assert spans(turns) == [(6.0, 7.5, "s1")]
    assert spans(diarizer.flush()) == [(10.5, 12.0, "s1")]
    assert diarizer.speaker_count == 1


def test_centroid_refinement_converges_on_one_noisy_voice():
    rng = np.random.default_rng(7)
    base = np.zeros(8, dtype=np.float32)
    base[0] = 1.0
    # Noise this size leaves every window above the 0.55 match threshold but
    # well off the true voice, so only the running mean can converge.
    embeddings = [
        base + rng.normal(0.0, 0.25, size=base.shape).astype(np.float32)
        for _ in range(20)
    ]
    diarizer = StreamingDiarizer(QueueEmbedder(embeddings), max_speakers=3)

    turns = diarizer.feed(stream([0.1] * 20))

    assert diarizer.speaker_count == 1
    assert {turn.speaker for turn in turns} | {turn.speaker for turn in diarizer.flush()} == {"s1"}
    centroid = diarizer.centroids[0]
    first = embeddings[0] / np.linalg.norm(embeddings[0])
    unit_base = base / np.linalg.norm(base)
    # The running mean is a better estimate than the noisiest single window.
    assert float(np.dot(centroid, unit_base)) > float(np.dot(first, unit_base))
    assert float(np.dot(centroid, unit_base)) > 0.95


def test_reset_clears_speakers_timestamps_and_open_turn():
    diarizer = StreamingDiarizer(level_embedder)
    diarizer.feed(stream([0.1, 0.2]))
    assert diarizer.speaker_count == 2

    diarizer.reset()

    assert diarizer.speaker_count == 0 and diarizer.centroids == ()
    assert spans(diarizer.feed(stream([0.2])) + diarizer.flush()) == [(0.0, 1.5, "s1")]


def test_speaker_cap_maps_an_unmatched_voice_to_the_closest_speaker():
    diarizer = StreamingDiarizer(level_embedder, max_speakers=2)

    turns = diarizer.feed(stream([0.1, 0.2, 0.3]))
    labels = [turn.speaker for turn in turns + diarizer.flush()]

    assert diarizer.speaker_count == 2
    assert labels == ["s1", "s2", "s1"]
    # A forced match must not drag the centroid it borrowed.
    assert float(np.dot(diarizer.centroids[0], A)) > 0.99


def test_missing_models_leave_live_labelling_off_and_download_nothing(home):
    diarizer = StreamingDiarizer()

    assert diarizer.feed(stream([0.1, 0.2])) == []
    assert diarizer.flush() == []
    assert diarizer.speaker_count == 0
    assert not (home / "models" / "diarization").exists()


def test_an_embedder_that_returns_nothing_creates_no_speaker():
    diarizer = StreamingDiarizer(lambda pcm: None)

    assert diarizer.feed(stream([0.1, 0.1])) == []
    assert diarizer.speaker_count == 0


def test_a_failing_embedder_degrades_instead_of_ending_the_stream():
    calls = {"n": 0}

    def flaky(pcm: np.ndarray) -> np.ndarray | None:
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("onnx runtime died")
        return level_embedder(pcm)

    diarizer = StreamingDiarizer(flaky)

    assert diarizer.feed(stream([0.1, 0.2])) == []
    assert spans(diarizer.flush()) == [(1.5, 3.0, "s1")]
    assert diarizer.speaker_count == 1


def test_invalid_geometry_is_rejected():
    with pytest.raises(ValueError):
        StreamingDiarizer(level_embedder, window_s=0)
    with pytest.raises(ValueError):
        StreamingDiarizer(level_embedder, sample_rate=0)
    with pytest.raises(ValueError):
        StreamingDiarizer(level_embedder, max_speakers=0)


def test_the_offline_batch_path_remains_the_authority():
    # Guard against anyone rewiring the stored-transcript path through the
    # provisional live labels.
    assert list(inspect.signature(diarization.diarize).parameters) == ["pcm"]
    assert list(inspect.signature(diarization.plain_speaker_plan).parameters) == [
        "turns", "total_samples", "sample_rate", "label"]
