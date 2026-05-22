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

from core.llm import chat_completion
from core.llm_config import resolve_llm_config
from services.chat import _load_persona_system_prompt

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


_SILENCE_TOKENS = {"", "[pass]", "pass", "[silent]", "(no comment)", "no comment"}

_REACTION_ANCHOR = (
    "An automated alert just arrived in your Telegram chat. The raw alert was "
    "already delivered to the user verbatim — do NOT repeat it. You may add ONE "
    "short in-character remark (a reaction, a piece of context, or a question) "
    "if you genuinely have something worth saying. If you have nothing to add, "
    "reply with exactly [pass] and nothing else. Keep any remark under 280 "
    "characters."
)


async def generate_alert_reaction(
    pool: asyncpg.Pool | None,
    *,
    alert_text: str,
    title: str | None = None,
) -> str | None:
    """Run one bounded LLM turn reacting to an alert.

    Returns the reaction text, or None if the persona chose silence or the
    LLM call failed (silence is a valid, first-class outcome).
    """
    persona = await _load_persona_system_prompt(pool, None)
    system_msg = (
        persona.strip() + "\n\n---\n\n" + _REACTION_ANCHOR
        if persona
        else _REACTION_ANCHOR
    )

    label = f"[{title}] " if title else ""
    user_msg = f"{label}{alert_text}"

    llm_config = await resolve_llm_config(pool, "llm.chat", fallback_key="llm")
    api_key_env = llm_config.get("api_key_env", "OPENAI_API_KEY")
    api_key = os.environ.get(api_key_env, "noop")

    try:
        result = await chat_completion(
            provider=llm_config.get("provider", "openai_compatible"),
            model=llm_config["model"],
            endpoint=llm_config.get("endpoint"),
            api_key=api_key,
            messages=[
                {"role": "system", "content": system_msg},
                {"role": "user", "content": user_msg},
            ],
            tools=None,
            temperature=0.7,
            max_tokens=256,
        )
    except Exception as exc:
        logger.warning("Alert reaction LLM call failed: %s", exc)
        return None

    reply = (result.get("content") or "").strip()
    if reply.lower() in _SILENCE_TOKENS:
        return None
    return reply


async def _get_alert_chat_id(pool: asyncpg.Pool) -> str | None:
    """Read channel.telegram.alert_chat_id config. Returns None if unset."""
    async with pool.acquire() as conn:
        val = await conn.fetchval(
            "SELECT get_config_text($1)", "channel.telegram.alert_chat_id"
        )
    chat_id = str(val).strip() if val else ""
    # get_config_text() flattens a JSON null config value to the text "null";
    # treat that (and an empty string) as unconfigured.
    if not chat_id or chat_id.lower() == "null":
        return None
    return chat_id


async def react_to_pending_alerts(
    pool: asyncpg.Pool,
    bridge: Any | None,
    *,
    limit: int = 10,
) -> int:
    """Heartbeat batch: react to unreacted alert memories from the last 24h.

    Called once per heartbeat. Picks up alert memories left unreacted by the
    webhook handler (normal-priority alerts), runs one reaction turn each, and
    publishes any non-silent reaction. A memory is marked reacted only when its
    reaction was delivered (or the persona passed on it) — a reaction that
    fails to publish is left unreacted so the next heartbeat retries it, rather
    than silently dropping a cognitive act.

    Returns the number of memories marked reacted.
    """
    alert_chat_id = await _get_alert_chat_id(pool)
    if not alert_chat_id:
        return 0

    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT id, content, metadata->'context' AS context
            FROM memories
            WHERE metadata->'context'->>'kind' = 'alert'
              AND metadata->'context'->>'reacted' = 'false'
              AND created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours'
            ORDER BY created_at
            LIMIT $1
            """,
            limit,
        )
    if not rows:
        return 0

    reacted_ids: list = []
    for row in rows:
        ctx = row["context"]
        if isinstance(ctx, str):
            try:
                ctx = json.loads(ctx)
            except Exception:
                ctx = {}
        ctx = ctx or {}
        alert_text = ctx.get("alert_text") or row["content"]
        title = ctx.get("title")
        comment = await generate_alert_reaction(
            pool, alert_text=alert_text, title=title
        )
        # Default True covers the silence case (no comment to publish — the
        # alert was genuinely processed). A comment that fails to publish is
        # NOT marked reacted, so the next heartbeat retries it.
        published_ok = True
        if comment and bridge:
            try:
                sent = await bridge.publish_outbox_payloads(
                    [build_alert_outbox_message(comment, alert_chat_id)]
                )
                published_ok = bool(sent)
            except Exception as exc:
                logger.warning("Failed to publish batched reaction: %s", exc)
                published_ok = False
        if published_ok:
            reacted_ids.append(row["id"])
        else:
            logger.warning(
                "Alert memory %s reaction publish failed; leaving unreacted "
                "for the next heartbeat to retry", row["id"],
            )

    if not reacted_ids:
        return 0
    async with pool.acquire() as conn:
        await conn.execute(
            "UPDATE memories "
            "SET metadata = jsonb_set(metadata, '{context,reacted}', 'true') "
            "WHERE id = ANY($1::uuid[])",
            reacted_ids,
        )
    return len(reacted_ids)
