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


def test_rejects_full_translation_that_drops_devanagari():
    raw = (
        "मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, "
        "और चौथी एक दर्जन अंडे।"
    )
    out = "I need to buy three things today: books, three apples, and one dozen eggs."
    assert check_divergence(raw, out) == "script_loss(DEVANAGARI)"


def test_rejects_translation_of_short_cjk_phrase():
    assert check_divergence("买书", "Buy books") == "script_loss(CJK)"


def test_accepts_native_script_list_formatting():
    raw = "मुझे तीन चीज़ें खरीदनी हैं, पहली किताबें, दूसरी सेब, तीसरी अंडे"
    out = "1. किताबें ⏎ 2. सेब ⏎ 3. अंडे"
    assert check_divergence(raw, out) is None


def test_accepts_mixed_latin_and_native_script_when_both_are_preserved():
    raw = "OpenAI पर बात करनी है अभी"
    out = "OpenAI पर अभी बात करनी है।"
    assert check_divergence(raw, out) is None


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


def test_sentence_wide_grammar_inflections_not_novel():
    # Live release smoke: three ordinary agreement/number repairs crossed the
    # global novelty threshold and caused the complete cleanup to be discarded.
    raw = "this sentence need a full stop and it also have two grammar issue"
    out = "This sentence needs a full stop, and it also has two grammar issues."
    assert check_divergence(raw, out) is None


def test_sentence_wide_past_tense_rewrite_rejected():
    raw = "we plan and review and test today"
    out = "We planned and reviewed and tested today."
    reason = check_divergence(raw, out)
    assert reason is not None and reason.startswith("novel_content")


def test_plural_inflections_cannot_hide_unrelated_tense_rewrites():
    raw = "we plan the test and review the change today"
    out = "We planned the tests and reviewed the changes today."
    reason = check_divergence(raw, out)
    assert reason is not None and reason.startswith("novel_content")


def test_past_auxiliary_rewrite_rejected():
    raw = "we have a plan and do the review and are ready"
    out = "We had a plan and did the review and were ready."
    reason = check_divergence(raw, out)
    assert reason is not None and reason.startswith("novel_content")


def test_mechanical_nonword_tense_forms_rejected():
    raw = "we have and do and be careful"
    out = "We haved and doed and bed careful."
    reason = check_divergence(raw, out)
    assert reason is not None and reason.startswith("novel_content")


def test_mechanical_nonword_present_forms_rejected():
    raw = "the box and dish and buzz while we have and are ready"
    out = "The boxs and dishs and buzzs while we haves and ares ready."
    reason = check_divergence(raw, out)
    assert reason is not None and reason.startswith("novel_content")


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


def test_list_markers_not_novel():
    # Line-leading numbering the speech explicitly asked for is formatting,
    # not novel content — with breaks as ⏎ markers (the LLM transport form)
    # and as real newlines (post-decode form).
    raw = "put this in a numbered list apples bananas milk and eggs"
    assert check_divergence(raw, "1. Apples ⏎ 2. Bananas ⏎ 3. Milk ⏎ 4. Eggs") is None
    assert check_divergence(raw, "1. Apples\n2. Bananas\n3. Milk\n4. Eggs") is None


def test_inline_numbers_still_novel():
    # Numbers that are NOT list markers keep counting as novel content.
    raw = "the plan needs a review before we ship it to the customer team"
    out = "The plan needs 12 45 78 99 reviews before we ship it."
    assert check_divergence(raw, out) is not None


def test_non_sequential_markers_still_novel():
    # Only a 1-anchored sequence reads as list formatting; arbitrary numbers
    # dressed as markers must not slip past the guard (review finding).
    raw = "the plan needs a review before we ship it to the customer team"
    out = "42. alpha beta ⏎ 99. gamma delta ⏎ 73. epsilon zeta eta theta"
    assert check_divergence(raw, out) is not None
