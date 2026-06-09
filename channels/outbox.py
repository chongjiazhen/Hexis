"""
Hexis Channel System - Outbox Consumer

Subscribes to the RabbitMQ outbox queue and routes heartbeat-initiated
messages to the appropriate channel adapters. This enables proactive
messaging — the agent can reach out to users without waiting for inbound.

Delivery modes:
    - direct: use explicit target_channel + target_id from payload
    - last_active: find the sender's most recent channel session
    - broadcast: send to all active sessions
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any, TYPE_CHECKING

import requests

if TYPE_CHECKING:
    import asyncpg
    from .manager import ChannelManager

logger = logging.getLogger(__name__)

RABBITMQ_MANAGEMENT_URL = os.getenv("RABBITMQ_MANAGEMENT_URL", "http://rabbitmq:15672").rstrip("/")
RABBITMQ_USER = os.getenv("RABBITMQ_USER", "hexis")
RABBITMQ_PASSWORD = os.getenv("RABBITMQ_PASSWORD", "hexis_password")
RABBITMQ_VHOST = os.getenv("RABBITMQ_VHOST", "/")

# Per-persona queue isolation: mirrors core/rabbitmq_bridge.py. Each persona
# channel worker consumes its own queue (hexis.outbox.<persona>) so no other
# persona's bot can win and deliver under the wrong Telegram token.
_POSTGRES_DB = os.getenv("POSTGRES_DB", "")
_PERSONA = (
    _POSTGRES_DB.removeprefix("hexis_")
    if _POSTGRES_DB.startswith("hexis_") and _POSTGRES_DB != "hexis_memory"
    else "memory"
)
_PERSONA_SUFFIX = "." + _PERSONA if _PERSONA != "memory" else ""
RABBITMQ_OUTBOX_QUEUE = os.getenv("RABBITMQ_OUTBOX_QUEUE", f"hexis.outbox{_PERSONA_SUFFIX}")
POLL_INTERVAL = float(os.getenv("OUTBOX_POLL_INTERVAL", "2.0"))


class ChannelOutboxConsumer:
    """
    Polls the RabbitMQ outbox queue and routes messages to channel adapters.

    Usage:
        consumer = ChannelOutboxConsumer(manager, pool)
        await consumer.start()  # blocks until stop()
    """

    def __init__(self, manager: ChannelManager, pool: asyncpg.Pool) -> None:
        self._manager = manager
        self._pool = pool
        self._running = False

    async def start(self) -> None:
        """Poll the outbox queue until stopped."""
        self._running = True
        logger.info("Outbox consumer started")
        while self._running:
            try:
                count = await self._poll()
                if count > 0:
                    logger.info("Processed %d outbox message(s)", count)
            except asyncio.CancelledError:
                break
            except Exception:
                logger.exception("Outbox poll error")
            await asyncio.sleep(POLL_INTERVAL)

    async def stop(self) -> None:
        self._running = False

    async def _poll(self, max_messages: int = 10) -> int:
        """Fetch and process messages from the outbox queue."""
        vhost = _vhost_path()
        try:
            resp = await _rmq_request(
                "POST",
                f"/api/queues/{vhost}/{requests.utils.quote(RABBITMQ_OUTBOX_QUEUE, safe='')}/get",
                payload={
                    "count": max_messages,
                    "ackmode": "ack_requeue_false",
                    "encoding": "auto",
                    "truncate": 50000,
                },
            )
            if resp.status_code != 200:
                return 0
            msgs = resp.json()
            if not isinstance(msgs, list):
                return 0
        except Exception:
            return 0

        processed = 0
        for msg in msgs:
            raw_payload = msg.get("payload")
            try:
                body = json.loads(raw_payload) if isinstance(raw_payload, str) else raw_payload
            except Exception:
                continue

            if not isinstance(body, dict):
                continue

            try:
                await self._process_message(body)
                processed += 1
            except Exception:
                logger.exception("Failed to process outbox message: %s", str(body)[:200])

        return processed

    async def _process_message(self, body: dict[str, Any]) -> None:
        """Route an outbox message to the appropriate channel."""
        # Defense-in-depth: even with per-persona queues, reject any message
        # whose embedded `agent` stamp does not match this container's persona.
        # Catches env-misconfig regressions where a worker falls back to a
        # shared queue. `agent` absent = legacy publisher, allow through.
        msg_agent = str(body.get("agent") or "")
        if msg_agent and msg_agent != _PERSONA:
            logger.warning(
                "Outbox origin mismatch: msg agent=%r container persona=%r body=%s — dropping",
                msg_agent, _PERSONA, str(body)[:200],
            )
            return

        kind = body.get("kind", "")
        payload = body.get("payload", {})
        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except Exception:
                payload = {"content": payload}

        content = str(payload.get("content") or payload.get("message") or payload.get("text") or "")
        if not content:
            return

        delivery_mode = str(payload.get("delivery_mode") or "last_active")
        outbox_msg_id = str(body.get("id") or "")
        # What fired this proactive send — payload.intent is the semantic signal
        # (kind is generically 'user' for all outbox user messages). Used to tag
        # the persisted reach-out (metadata.trigger).
        trigger = str(payload.get("intent") or kind or "reach_out")

        # I.2: Check for domain-based delivery routing from cron delivery info
        delivery_info = payload.get("delivery") or body.get("delivery")
        if isinstance(delivery_info, dict) and delivery_info.get("mode") == "channel":
            # Override delivery to route to specific channel+topic
            payload["target_channel"] = delivery_info.get("channel", "")
            payload["target_id"] = delivery_info.get("target_id", payload.get("target_id", ""))
            payload["thread_id"] = delivery_info.get("topic", "")
            delivery_mode = "direct"
        elif isinstance(delivery_info, dict) and delivery_info.get("mode") == "webhook":
            await self._deliver_webhook(content, payload, delivery_info, outbox_msg_id)
            return
        elif isinstance(delivery_info, dict) and delivery_info.get("mode") == "silent":
            # Silent: log only, no notification
            logger.info("Silent delivery (suppressed): %s", content[:100])
            return

        if delivery_mode == "direct":
            await self._deliver_direct(content, payload, outbox_msg_id)
        elif delivery_mode == "broadcast":
            await self._deliver_broadcast(content, payload, outbox_msg_id)
        else:
            # I.2: Check domain-based routing config
            domain = str(payload.get("domain") or payload.get("intent") or "")
            if domain:
                routed = await self._deliver_by_domain(content, payload, domain, outbox_msg_id)
                if routed:
                    return
            # Default: last_active
            await self._deliver_last_active(content, payload, outbox_msg_id, trigger)

    async def _deliver_by_domain(
        self, content: str, payload: dict, domain: str, outbox_msg_id: str
    ) -> bool:
        """I.2: Route message based on content domain config.

        Config key: channel.routing.{domain} = JSON {"channel": "...", "target_id": "...", "topic": "..."}
        Returns True if routing was found and delivery attempted, False otherwise.
        """
        try:
            async with self._pool.acquire() as conn:
                raw = await conn.fetchval(
                    "SELECT get_config_text($1)",
                    f"channel.routing.{domain}",
                )
            if not raw:
                return False
            route = json.loads(raw) if isinstance(raw, str) else raw
            if not isinstance(route, dict):
                return False
            channel_type = str(route.get("channel") or "")
            target_id = str(route.get("target_id") or "")
            if not channel_type or not target_id:
                return False
            thread_id = str(route.get("topic") or "") or None
            msg_id = await self._manager.send(
                channel_type, target_id, content, thread_id=thread_id
            )
            await self._log_delivery(
                outbox_msg_id, channel_type, target_id, thread_id, content, f"domain:{domain}", True
            )
            return True
        except Exception as e:
            logger.warning("Domain routing for %s failed: %s", domain, e)
            return False

    async def _deliver_direct(self, content: str, payload: dict, outbox_msg_id: str) -> None:
        """Send to an explicit channel + target, optionally with thread/topic."""
        channel_type = str(payload.get("target_channel") or "")
        target_id = str(payload.get("target_id") or "")
        if not channel_type or not target_id:
            logger.warning("Direct delivery missing target_channel/target_id")
            return

        thread_id = str(payload.get("thread_id") or "") or None

        try:
            msg_id = await self._manager.send(
                channel_type, target_id, content, thread_id=thread_id
            )
            await self._log_delivery(outbox_msg_id, channel_type, target_id, thread_id, content, "direct", True)
        except Exception as e:
            await self._log_delivery(outbox_msg_id, channel_type, target_id, thread_id, content, "direct", False, str(e))

    async def _deliver_last_active(self, content: str, payload: dict, outbox_msg_id: str, trigger: str = "reach_out") -> None:
        """Send to the sender's most recently active channel session."""
        sender_id = str(payload.get("sender_id") or payload.get("target_user") or "")

        async with self._pool.acquire() as conn:
            if sender_id:
                row = await conn.fetchrow(
                    """
                    SELECT id, channel_type, channel_id, sender_id
                    FROM channel_sessions
                    WHERE sender_id = $1
                    ORDER BY last_active DESC NULLS LAST
                    LIMIT 1
                    """,
                    sender_id,
                )
            else:
                # No specific sender. Deliver to the globally most-recent session
                # ONLY when there's no ambiguity (a single active partner). With
                # multiple active senders a target-less reach-out would silently
                # land on whoever messaged last — the wrong person for a
                # multi-partner persona. Skip + log so the omission is visible
                # rather than misdelivered. reach_out_user supplies sender_id;
                # this guard only catches the case where it was dropped.
                distinct_senders = await conn.fetchval(
                    """
                    SELECT COUNT(DISTINCT sender_id)
                    FROM channel_sessions
                    WHERE sender_id IS NOT NULL
                      AND last_active > CURRENT_TIMESTAMP - INTERVAL '7 days'
                    """
                )
                if distinct_senders and int(distinct_senders) > 1:
                    logger.warning(
                        "Target-less reach-out with %d active senders — skipping "
                        "to avoid misdelivery to the globally-latest DM. Persona "
                        "must supply sender_id (reach_out_user).",
                        int(distinct_senders),
                    )
                    return
                row = await conn.fetchrow(
                    """
                    SELECT id, channel_type, channel_id, sender_id
                    FROM channel_sessions
                    ORDER BY last_active DESC NULLS LAST
                    LIMIT 1
                    """,
                )

        if not row:
            logger.warning("No active session found for last_active delivery")
            return

        channel_type = row["channel_type"]
        channel_id = row["channel_id"]
        resolved_sender = row["sender_id"]

        try:
            await self._manager.send(channel_type, channel_id, content)
            await self._log_delivery(outbox_msg_id, channel_type, channel_id, resolved_sender, content, "last_active", True)
            # Persist the reach-out only on a SUCCESSFUL send (success-gated):
            # transcript + history continuity + tagged cognitive memory.
            await self._persist_reach_out(row["id"], content, trigger)
        except Exception as e:
            await self._log_delivery(outbox_msg_id, channel_type, channel_id, resolved_sender, content, "last_active", False, str(e))

    async def _persist_reach_out(self, session_id: Any, content: str, trigger: str) -> None:
        """Persist a proactive reach-out via the record_reach_out DB function.

        The inbound-reply path persists through prepare/finalize_channel_turn +
        record_chat_turn_memory; the outbox path skipped all of it, leaving the
        agent with no transcript and no memory of its own outreach. Non-fatal: a
        failed persist must never affect delivery (the send already succeeded).
        """
        try:
            async with self._pool.acquire() as conn:
                await conn.execute(
                    "SELECT record_reach_out($1::uuid, $2::text, $3::text, $4::text)",
                    str(session_id), content, trigger, "prime",
                )
        except Exception:
            logger.exception("Failed to persist reach-out (non-fatal)")

    async def _deliver_broadcast(self, content: str, payload: dict, outbox_msg_id: str) -> None:
        """Send to all active channel sessions."""
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT DISTINCT channel_type, channel_id, sender_id
                FROM channel_sessions
                WHERE last_active > CURRENT_TIMESTAMP - INTERVAL '7 days'
                ORDER BY channel_type, channel_id
                """,
            )

        for row in rows:
            channel_type = row["channel_type"]
            channel_id = row["channel_id"]
            sender_id = row["sender_id"]
            try:
                await self._manager.send(channel_type, channel_id, content)
                await self._log_delivery(outbox_msg_id, channel_type, channel_id, sender_id, content, "broadcast", True)
            except Exception as e:
                await self._log_delivery(outbox_msg_id, channel_type, channel_id, sender_id, content, "broadcast", False, str(e))

    async def _deliver_webhook(
        self,
        content: str,
        payload: dict[str, Any],
        delivery_info: dict[str, Any],
        outbox_msg_id: str,
    ) -> None:
        """Send outbox payload to a configured webhook URL."""
        url = str(delivery_info.get("url") or "").strip()
        if not url:
            logger.warning("Webhook delivery missing URL")
            return

        body = {
            "content": content,
            "payload": payload,
            "delivery": delivery_info,
            "outbox_message_id": outbox_msg_id or None,
        }
        headers = {"Content-Type": "application/json"}

        try:
            def _do() -> requests.Response:
                return requests.post(url, json=body, headers=headers, timeout=8)

            resp = await asyncio.to_thread(_do)
            if 200 <= resp.status_code < 300:
                await self._log_delivery(outbox_msg_id, "webhook", url, None, content, "webhook", True)
            else:
                err = f"HTTP {resp.status_code}: {resp.text[:300]}"
                await self._log_delivery(outbox_msg_id, "webhook", url, None, content, "webhook", False, err)
        except Exception as e:
            await self._log_delivery(outbox_msg_id, "webhook", url, None, content, "webhook", False, str(e))

    async def _log_delivery(
        self,
        outbox_message_id: str,
        channel_type: str,
        channel_id: str,
        sender_id: str | None,
        content: str,
        delivery_mode: str,
        success: bool,
        error: str | None = None,
    ) -> None:
        """Log a delivery attempt to the channel_deliveries table."""
        try:
            async with self._pool.acquire() as conn:
                await conn.execute(
                    """
                    INSERT INTO channel_deliveries
                        (outbox_message_id, channel_type, channel_id, sender_id, content, delivery_mode, success, error)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                    """,
                    outbox_message_id or None,
                    channel_type,
                    channel_id,
                    sender_id,
                    content[:2000],  # Truncate for storage
                    delivery_mode,
                    success,
                    error,
                )
        except Exception:
            logger.debug("Failed to log delivery", exc_info=True)


def _vhost_path() -> str:
    if RABBITMQ_VHOST == "/":
        return "%2F"
    return requests.utils.quote(RABBITMQ_VHOST, safe="")


async def _rmq_request(method: str, path: str, payload: dict | None = None) -> requests.Response:
    url = f"{RABBITMQ_MANAGEMENT_URL}{path}"
    auth = (RABBITMQ_USER, RABBITMQ_PASSWORD)

    def _do() -> requests.Response:
        return requests.request(method, url, auth=auth, json=payload, timeout=5)

    return await asyncio.to_thread(_do)
