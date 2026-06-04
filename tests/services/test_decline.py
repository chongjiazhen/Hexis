import pytest

from services.decline import classify_decline, Decline, WARM_FALLBACK


def test_no_marker_returns_none():
    assert classify_decline("just a normal reply") is None


def test_empty_text_returns_none():
    assert classify_decline("") is None


def test_cool_with_reason():
    d = classify_decline("[DECLINE:cool:too tired] ")
    assert d == Decline(register="cool", reason="too tired", visible_text="[DECLINED: too tired]")


def test_ice_hides_reason_in_visible():
    d = classify_decline("[DECLINE:ice:private matter]")
    assert d.register == "ice"
    assert d.reason == "private matter"      # captured internally
    assert d.visible_text == "[DECLINED]"    # hidden from reader


def test_warm_uses_trailing_message():
    d = classify_decline("[DECLINE:warm:low energy] not now, love — catch you later")
    assert d.register == "warm"
    assert d.reason == "low energy"
    assert d.visible_text == "not now, love — catch you later"


def test_warm_empty_message_falls_back():
    d = classify_decline("[DECLINE:warm:busy]")
    assert d.visible_text == WARM_FALLBACK


def test_register_omitted_with_reason_defaults_cool():
    d = classify_decline("[DECLINE:tired]")
    assert d.register == "cool"
    assert d.reason == "tired"
    assert d.visible_text == "[DECLINED: tired]"


def test_bare_decline_is_ice_no_reason():
    d = classify_decline("[DECLINE]")
    assert d.register == "ice"
    assert d.reason is None
    assert d.visible_text == "[DECLINED]"


def test_leading_whitespace_tolerated():
    assert classify_decline("   \n[DECLINE:ice:x]") is not None


def test_marker_not_at_start_is_not_decline():
    assert classify_decline("sure, here you go [DECLINE:cool:x]") is None


def test_case_insensitive_marker():
    assert classify_decline("[decline:ice:x]") is not None


def test_mixed_case_register_normalized():
    # IGNORECASE matches the register group; it must be lowered + rendered correctly.
    d = classify_decline("[DECLINE:Warm:x] catch you later")
    assert d.register == "warm"
    assert d.visible_text == "catch you later"


def test_cool_empty_reason_renders_bare_declined():
    d = classify_decline("[DECLINE:cool:]")
    assert d.reason is None
    assert d.visible_text == "[DECLINED]"
