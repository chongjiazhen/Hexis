"""Tests for Vera's session-assessment capture (services.chat).

Vera (the comms-trainer persona) cannot reliably tool-call `remember` on the
local model, so she emits the rubric assessment as text wrapped in
<<SESSION-ASSESSMENT>> markers. `_extract_session_assessment` pulls that block
out of the reply for storage as a strategic memory and strips it from the
user-visible text.
"""
from services.chat import _extract_session_assessment


def test_extracts_and_strips_assessment_block():
    reply = (
        "Good work on that scenario.\n\n"
        "<<SESSION-ASSESSMENT>>\n"
        "[session-assessment] 2026-05-22\n"
        "observation_vs_evaluation: 4 — clean observation\n"
        "focus_next: need_identification\n"
        "<</SESSION-ASSESSMENT>>\n\n"
        "Let's try another."
    )
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is not None
    assert "[session-assessment] 2026-05-22" in assessment
    assert "observation_vs_evaluation: 4" in assessment
    # markers and block content gone from the user-visible text
    assert "<<SESSION-ASSESSMENT>>" not in cleaned
    assert "<</SESSION-ASSESSMENT>>" not in cleaned
    assert "[session-assessment]" not in cleaned
    # surrounding coaching text preserved
    assert "Good work on that scenario." in cleaned
    assert "Let's try another." in cleaned


def test_no_block_returns_text_unchanged():
    reply = "Just a normal coaching reply, no assessment."
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is None
    assert cleaned == reply


def test_unclosed_marker_left_intact():
    # malformed: opening marker, no close — do not partially strip
    reply = "Some text <<SESSION-ASSESSMENT>> partial, never closed"
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is None
    assert cleaned == reply


def test_empty_text():
    cleaned, assessment = _extract_session_assessment("")
    assert assessment is None
    assert cleaned == ""
