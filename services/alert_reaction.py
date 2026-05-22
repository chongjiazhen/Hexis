"""Alert reaction — bounded persona reactions to incoming alerts.

An alert webhook (source=alert) delivers raw alert text to Telegram verbatim,
records it as a memory, and may run a short in-character persona reaction.
This module holds the reaction logic so the webhook handler stays thin.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Any

import asyncpg

logger = logging.getLogger(__name__)


def build_alert_outbox_message(text: str, alert_chat_id: Any) -> dict[str, Any]:
    """Build an outbox message that delivers `text` to the Telegram alert chat.

    Uses delivery_mode=direct so the outbox consumer routes it straight to the
    telegram adapter without session lookup.
    """
    return {
        "kind": "alert",
        "payload": {
            "content": text,
            "delivery_mode": "direct",
            "target_channel": "telegram",
            "target_id": str(alert_chat_id),
        },
    }
