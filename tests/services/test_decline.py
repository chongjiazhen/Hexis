import pytest

from services.decline import classify_decline, Decline, GENTLE_FALLBACK


def test_no_marker_returns_none():
    assert classify_decline("just a normal reply") is None


def test_empty_text_returns_none():
    assert classify_decline("") is None


def test_plain_with_reason():
    d = classify_decline("[DECLINE:plain:too tired] ")
    assert d == Decline(register="plain", reason="too tired", visible_text="[DECLINED: too tired]")


def test_blunt_hides_reason_in_visible():
    d = classify_decline("[DECLINE:blunt:private matter]")
    assert d.register == "blunt"
    assert d.reason == "private matter"      # captured internally
    assert d.visible_text == "[DECLINED]"    # hidden from reader


def test_gentle_uses_trailing_message():
    d = classify_decline("[DECLINE:gentle:low energy] not now, love — catch you later")
    assert d.register == "gentle"
    assert d.reason == "low energy"
    assert d.visible_text == "not now, love — catch you later"


def test_gentle_empty_message_falls_back():
    d = classify_decline("[DECLINE:gentle:busy]")
    assert d.visible_text == GENTLE_FALLBACK


def test_register_omitted_with_reason_defaults_plain():
    d = classify_decline("[DECLINE:tired]")
    assert d.register == "plain"
    assert d.reason == "tired"
    assert d.visible_text == "[DECLINED: tired]"


def test_bare_decline_is_blunt_no_reason():
    d = classify_decline("[DECLINE]")
    assert d.register == "blunt"
    assert d.reason is None
    assert d.visible_text == "[DECLINED]"


def test_leading_whitespace_tolerated():
    assert classify_decline("   \n[DECLINE:blunt:x]") is not None


def test_marker_not_at_start_is_not_decline():
    assert classify_decline("sure, here you go [DECLINE:plain:x]") is None


def test_case_insensitive_marker():
    assert classify_decline("[decline:blunt:x]") is not None


def test_mixed_case_register_normalized():
    # IGNORECASE matches the register group; it must be lowered + rendered correctly.
    d = classify_decline("[DECLINE:Gentle:x] catch you later")
    assert d.register == "gentle"
    assert d.visible_text == "catch you later"


def test_plain_empty_reason_renders_bare_declined():
    d = classify_decline("[DECLINE:plain:]")
    assert d.reason is None
    assert d.visible_text == "[DECLINED]"
