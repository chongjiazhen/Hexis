"""Tests for Vera's session-assessment capture (services.chat).

Vera (the comms-trainer persona) cannot reliably tool-call `remember` on the
local model, so she emits the rubric assessment as text.
`_extract_session_assessment` pulls that block out of the reply for storage as
a strategic memory and strips it from the user-visible text.

Detection anchors on the block CONTENT (`[session-assessment]` header through
the `focus_next:` line) — not on the `<<SESSION-ASSESSMENT>>` wrapper markers,
which the local model mistypes (gate run 4 emitted a single-`>` opener).
"""
from services.chat import _extract_session_assessment


_BODY = (
    "[session-assessment] 2026-05-22\n"
    "observation_vs_evaluation: 4 — clean observation\n"
    "feeling_literacy: 3 — mixed a thought in\n"
    "need_identification: 4 — clear need\n"
    "request_clarity: 4 — actionable\n"
    "empathy_before_solving: 4 — reflected first\n"
    "de_escalation: 5 — stayed present\n"
    "focus_next: feeling_literacy"
)


def test_extracts_with_well_formed_markers():
    reply = (
        "Good work on that scenario.\n\n"
        "<<SESSION-ASSESSMENT>>\n" + _BODY + "\n<</SESSION-ASSESSMENT>>\n\n"
        "Let's try another."
    )
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is not None
    assert "[session-assessment] 2026-05-22" in assessment
    assert "focus_next: feeling_literacy" in assessment
    assert "<<SESSION-ASSESSMENT" not in cleaned
    assert "[session-assessment]" not in cleaned
    assert "Good work on that scenario." in cleaned
    assert "Let's try another." in cleaned


def test_extracts_with_malformed_opening_marker():
    # gate run 4: model emitted "<<SESSION-ASSESSMENT>" (single >).
    reply = (
        "Here is the record:\n\n"
        "<<SESSION-ASSESSMENT>\n" + _BODY + "\n<</SESSION-ASSESSMENT>>\n\n"
        "Goodbye for now."
    )
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is not None
    assert "observation_vs_evaluation: 4" in assessment
    # both the malformed opener and the closer are gone from user-visible text
    assert "SESSION-ASSESSMENT" not in cleaned
    assert "[session-assessment]" not in cleaned
    assert "Here is the record:" in cleaned
    assert "Goodbye for now." in cleaned


def test_extracts_with_no_markers_at_all():
    # content anchor alone is enough — markers are a bonus, not required.
    reply = "Wrapping up.\n\n" + _BODY + "\n\nSee you next time."
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is not None
    assert "focus_next: feeling_literacy" in assessment
    assert "[session-assessment]" not in cleaned
    assert "Wrapping up." in cleaned
    assert "See you next time." in cleaned


def test_no_block_returns_text_unchanged():
    reply = "Just a normal coaching reply, no assessment."
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is None
    assert cleaned == reply


def test_empty_text():
    cleaned, assessment = _extract_session_assessment("")
    assert assessment is None
    assert cleaned == ""
