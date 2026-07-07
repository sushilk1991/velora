"""Divergence guard (anti-over-editing) — pure function, no model needed."""

from velora_engine.cleanup import check_divergence
from velora_engine.stt import _trim_repeated_tail, guard_whisper_result

RAW = (
    "so um I wanted to say that the meeting on Thursday should probably be moved "
    "to Monday because the client is flying in on Tuesday"
)


def test_accepts_reasonable_cleanup():
    out = "The meeting on Thursday should be moved to Monday because the client is flying in on Tuesday."
    assert check_divergence(RAW, out) is None


def test_rejects_empty_output():
    assert check_divergence(RAW, "") == "empty_output"
    assert check_divergence(RAW, "   \n") == "empty_output"


def test_rejects_too_short():
    reason = check_divergence(RAW, "Move meeting.")
    assert reason is not None and reason.startswith("ratio_low")


def test_rejects_too_long():
    reason = check_divergence(RAW, RAW * 3)
    assert reason is not None and reason.startswith("ratio_high")


def test_boundary_identity_passes():
    assert check_divergence(RAW, RAW) is None


# ---- whisper hallucination guard ----


def test_trim_repeated_tail():
    text = "that we here highly resolve that we here highly resolve"
    assert _trim_repeated_tail(text) == "that we here highly resolve"
    assert _trim_repeated_tail("no repetition at the end here") == "no repetition at the end here"


def test_guard_drops_high_compression_segments():
    result = {
        "text": "ignored",
        "segments": [
            {"text": "Four score and seven years ago.", "compression_ratio": 1.1, "avg_logprob": -0.2},
            {"text": "End of address End of address End of address", "compression_ratio": 3.0, "avg_logprob": -0.9},
            {"text": "!!!!", "compression_ratio": 1.0, "avg_logprob": -0.5},
        ],
    }
    assert guard_whisper_result(result) == "Four score and seven years ago."
