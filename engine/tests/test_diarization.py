"""plan_chunks + config behavior for meeting diarization (no models needed)."""
from velora_engine.config import Config
from velora_engine.diarization import Turn, plan_chunks

SR = 16_000


def spans_s(chunks: list[tuple[int, int, str]]) -> list[tuple[float, float, str]]:
    return [(round(a / SR, 2), round(b / SR, 2), s) for a, b, s in chunks]


def test_empty_turns_yield_no_chunks() -> None:
    assert plan_chunks([], total_samples=SR * 60) == []


def test_same_speaker_turns_merge_across_small_gaps() -> None:
    turns = [Turn(0.0, 5.0, "s1"), Turn(5.5, 10.0, "s1"), Turn(12.0, 15.0, "s2")]
    chunks = plan_chunks(turns, total_samples=SR * 20)
    assert [c[2] for c in chunks] == ["s1", "s2"]
    # merged s1 spans both turns (plus padding)
    assert chunks[0][0] == 0
    assert chunks[0][1] >= int(10.0 * SR)


def test_alternating_speakers_never_merge() -> None:
    turns = [Turn(0.0, 5.0, "s1"), Turn(5.2, 10.0, "s2"), Turn(10.4, 15.0, "s1")]
    chunks = plan_chunks(turns, total_samples=SR * 20)
    assert [c[2] for c in chunks] == ["s1", "s2", "s1"]


def test_padding_never_overlaps_neighbouring_turn() -> None:
    turns = [Turn(1.0, 5.0, "s1"), Turn(5.1, 9.0, "s2")]
    chunks = plan_chunks(turns, total_samples=SR * 10)
    assert len(chunks) == 2
    # s1's padded end must not cross into s2's start, and vice versa
    assert chunks[0][1] <= int(5.1 * SR)
    assert chunks[1][0] >= int(5.0 * SR)


def test_long_merged_span_splits_evenly_under_cap() -> None:
    turns = [Turn(0.0, 150.0, "s1")]
    chunks = plan_chunks(turns, total_samples=SR * 151)
    assert len(chunks) == 3  # 150 s → 3 pieces ≤ 60 s
    assert all(s == "s1" for _, _, s in chunks)
    lengths = [(b - a) / SR for a, b, _ in chunks]
    assert all(45 <= length <= 60 for length in lengths)
    # contiguous: no dropped audio between pieces
    assert chunks[0][1] == chunks[1][0]
    assert chunks[1][1] == chunks[2][0]


def test_micro_turns_are_dropped() -> None:
    turns = [Turn(0.0, 0.05, "s1"), Turn(1.0, 6.0, "s2")]
    chunks = plan_chunks(turns, total_samples=SR * 10)
    assert [c[2] for c in chunks] == ["s2"]


def test_plan_is_deterministic() -> None:
    turns = [Turn(0.0, 9.3, "s1"), Turn(9.7, 21.3, "s2"), Turn(21.7, 31.2, "s3")]
    a = plan_chunks(turns, total_samples=SR * 32)
    b = plan_chunks(turns, total_samples=SR * 32)
    assert a == b


def test_chunk_bounds_stay_inside_track() -> None:
    turns = [Turn(0.0, 4.0, "s1"), Turn(4.5, 9.9, "s2")]
    total = int(SR * 9.95)
    chunks = plan_chunks(turns, total_samples=total)
    assert all(0 <= a < b <= total for a, b, _ in chunks)


def test_meeting_diarization_config_default_and_override(tmp_path) -> None:
    cfg = Config(home=tmp_path)
    assert cfg.meeting_diarization is True
    (tmp_path / "config.json").write_text('{"meeting_diarization": false}')
    cfg = Config(home=tmp_path)
    assert cfg.meeting_diarization is False
