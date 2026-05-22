"""Tests for services.alert_reaction."""
from __future__ import annotations

import pytest

from services.alert_reaction import build_alert_outbox_message


def test_build_alert_outbox_message():
    msg = build_alert_outbox_message("BTC crossed 70k", "-100999")
    assert msg["kind"] == "alert"
    assert msg["payload"]["content"] == "BTC crossed 70k"
    assert msg["payload"]["delivery_mode"] == "direct"
    assert msg["payload"]["target_channel"] == "telegram"
    assert msg["payload"]["target_id"] == "-100999"


def test_build_alert_outbox_message_coerces_chat_id():
    msg = build_alert_outbox_message("x", -100999)
    assert msg["payload"]["target_id"] == "-100999"
