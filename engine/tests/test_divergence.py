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


# ---- guard v2: self-corrections may shrink, hallucinations may not ----


def test_retraction_shrink_accepted():
    # Applying a spoken self-correction legitimately deletes most of the text;
    # the marker-relaxed floor must let the (correct) short output through.
    raw = "let's meet at 3 p.m no no let's meet at 6 p.m"
    assert check_divergence(raw, "Let's meet at 6 p.m.") is None


def test_scratch_that_deep_shrink_accepted():
    raw = (
        "so i was thinking about the quarterly numbers and the hiring plan "
        "scratch all of that just tell him i'll call back"
    )
    assert check_divergence(raw, "Just tell him I'll call back.") is None


def test_deep_shrink_without_marker_rejected():
    # No retraction anywhere → a tiny output is over-deletion, not a repair.
    reason = check_divergence(RAW, "Meeting moved.")
    assert reason is not None and reason.startswith("ratio_low")


def test_novel_content_rejected():
    # The model answering/summarizing instead of transcribing introduces words
    # that never occurred in the input — reject even at a plausible length.
    out = "Here is a quick summary of your dictated message for review purposes today"
    reason = check_divergence(RAW, out)
    assert reason is not None and reason.startswith("novel_content")


def test_bare_actually_does_not_relax_floor():
    # "actually" / "I mean" are everyday fillers; treating them as retraction
    # markers switched the over-deletion backstop off for ordinary dictation
    # (review finding). A deep shrink with only a bare "actually" → rejected.
    raw = (
        "the roadmap actually looks solid for the third quarter and we should "
        "also think about hiring two more engineers before the launch window"
    )
    reason = check_divergence(raw, "The roadmap looks solid.")
    assert reason is not None and reason.startswith("ratio_low")


def test_strike_that_relaxes_floor():
    raw = (
        "so i drafted a long summary of the quarterly numbers and the hiring "
        "plan strike that just tell him i will call back"
    )
    assert check_divergence(raw, "Just tell him I will call back.") is None


def test_number_normalization_not_novel():
    # "three thirty" → "3:30", "june fifth" → "June 5th": digit forms of
    # spoken numbers are normalization, not hallucination (review finding).
    raw = "meet at three thirty on june fifth with the twenty five designs"
    out = "Meet at 3:30 on June 5th with the 25 designs."
    assert check_divergence(raw, out) is None


def test_small_grammar_fix_not_novel():
    # A legitimate agreement fix introduces one novel token — must pass.
    raw = "it don't work when the user click the button twice"
    out = "It doesn't work when the user clicks the button twice."
    assert check_divergence(raw, out) is None


def test_token_merges_not_novel():
    # "6 p m" → "6pm" style merges are normal cleanup, not hallucination.
    raw = "meet at 6 p m tomorrow and ping the auth check module afterwards"
    assert check_divergence(raw, "Meet at 6pm tomorrow and ping the authCheck module afterwards.") is None


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


def test_guard_does_not_restore_aggregate_when_every_segment_is_rejected():
    result = {
        "text": "hallucinated loop",
        "segments": [
            {"text": "hallucinated loop", "compression_ratio": 3.2, "avg_logprob": -0.2},
        ],
    }
    assert guard_whisper_result(result) == ""


def test_guard_keeps_unicode_letter_segments():
    result = {
        "text": "नमस्ते दुनिया",
        "segments": [
            {"text": "नमस्ते दुनिया", "compression_ratio": 1.1, "avg_logprob": -0.2},
        ],
    }
    assert guard_whisper_result(result) == "नमस्ते दुनिया"


def test_allowed_terms_not_novel():
    # A learned/vocab spelling the model is TOLD to produce must not count as
    # hallucinated content ("whisper flow" → "Wispr Flow"; soft correction →
    # "Airlearn").
    raw = "open valora and beat whisper flow then catch the lung or not with it"
    out = "Open Velora and beat Wispr Flow, then catch the Airlearn or not with it."
    assert check_divergence(raw, out) is not None  # without terms: 3 novel tokens
    assert check_divergence(raw, out, ["Velora", "Wispr Flow", "Airlearn"]) is None


def test_vocab_injection_rejected():
    # Review finding: vocab terms may only SUBSTITUTE for removed words —
    # an output sprinkled with unrelated known terms must still be rejected.
    raw = "send it to the team after lunch please"
    out = "Send it to the Velora Airlearn Wispr Flow team after lunch."
    reason = check_divergence(raw, out, ["Velora", "Airlearn", "Wispr Flow"])
    assert reason is not None and reason.startswith("vocab_injection")
