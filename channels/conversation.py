"""
Hexis Channel System - Conversation Handler

Routes inbound channel messages through the memory-enriched conversation
pipeline and manages per-sender session state in the database.
"""

from __future__ import annotations

import json
import logging
import hashlib
from datetime import datetime, timezone
from typing import Any, TYPE_CHECKING

from .base import ChannelMessage, chunk_text

if TYPE_CHECKING:
    import asyncpg

logger = logging.getLogger(__name__)

# Fleet-default conversation-history bounds. A persona on a small-context
# model (e.g. Vera on the 24K-window local model) can override these per-DB
# via the channel.history.max / channel.history.trim config keys — verbose
# personas otherwise overflow the model's context window.
MAX_SESSION_HISTORY = 40

# Trim to this many when we exceed the max
TRIM_TO_HISTORY = 30


async def _resolve_history_limits(conn: "asyncpg.Connection") -> tuple[int, int]:
    """Return (max, trim) session-history bounds for this persona.

    Defaults are MAX_SESSION_HISTORY / TRIM_TO_HISTORY; the channel.history.max
    and channel.history.trim config keys override them. trim is clamped below
    max so trimming always makes progress.
    """
    max_n, trim_n = MAX_SESSION_HISTORY, TRIM_TO_HISTORY

    def _as_int(raw: Any, default: int) -> int:
        try:
            return int(json.loads(raw) if isinstance(raw, str) else raw)
        except (TypeError, ValueError):
            return default

    try:
        rows = await conn.fetch(
            "SELECT key, value FROM config "
            "WHERE key IN ('channel.history.max', 'channel.history.trim')"
        )
        cfg = {r["key"]: r["value"] for r in rows}
        if "channel.history.max" in cfg:
            max_n = _as_int(cfg["channel.history.max"], max_n)
        if "channel.history.trim" in cfg:
            trim_n = _as_int(cfg["channel.history.trim"], trim_n)
    except Exception:
        logger.debug("history-limit config lookup failed; using defaults")

    trim_n = max(1, min(trim_n, max_n - 1))
    return max_n, trim_n

# Default energy cost per channel message (0 = free)
DEFAULT_CHANNEL_ENERGY_COST = 0.0

# Default rate limit (messages per sender per hour, None = unlimited)
DEFAULT_RATE_LIMIT: int | None = None


def _coerce_json(value: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except Exception:
            return value
    return value


async def _prepare_channel_turn_db(
    conn: asyncpg.Connection,
    msg: ChannelMessage,
) -> dict[str, Any]:
    raw = await conn.fetchval(
        "SELECT prepare_channel_turn($1::jsonb)",
        json.dumps({
            "channel_type": msg.channel_type,
            "channel_id": msg.channel_id,
            "sender_id": msg.sender_id,
            "sender_name": msg.sender_name,
            "content": msg.content,
            "message_id": msg.message_id,
        }),
    )
    result = _coerce_json(raw)
    return result if isinstance(result, dict) else {}


async def _finalize_channel_turn_db(
    conn: asyncpg.Connection,
    *,
    session_id: str,
    user_text: str,
    assistant_text: str,
    history: list[dict[str, Any]],
    metadata: dict[str, Any] | None = None,
    platform_message_id: str | None = None,
) -> dict[str, Any]:
    raw = await conn.fetchval(
        "SELECT finalize_channel_turn($1::uuid, $2::text, $3::text, $4::jsonb)",
        session_id,
        user_text,
        assistant_text,
        json.dumps({
            "history": history,
            "metadata": metadata or {},
            "platform_message_id": platform_message_id,
        }),
    )
    result = _coerce_json(raw)
    return result if isinstance(result, dict) else {}


async def _check_channel_energy(
    conn: asyncpg.Connection,
    msg: ChannelMessage,
) -> tuple[bool, float, str | None]:
    """
    Check if the agent has enough energy for a channel message and if the
    sender is within rate limits.

    Returns (allowed, cost, rejection_reason).
    """
    # Load per-channel energy cost
    cost_raw = await conn.fetchval(
        "SELECT value FROM config WHERE key = $1",
        f"channel.{msg.channel_type}.energy_cost",
    )
    if cost_raw is not None:
        try:
            cost = float(json.loads(cost_raw) if isinstance(cost_raw, str) else cost_raw)
        except (ValueError, TypeError):
            cost = DEFAULT_CHANNEL_ENERGY_COST
    else:
        cost = DEFAULT_CHANNEL_ENERGY_COST

    # Load energy multiplier
    mult_raw = await conn.fetchval(
        "SELECT value FROM config WHERE key = $1",
        f"channel.{msg.channel_type}.energy_multiplier",
    )
    if mult_raw is not None:
        try:
            mult = float(json.loads(mult_raw) if isinstance(mult_raw, str) else mult_raw)
        except (ValueError, TypeError):
            mult = 1.0
    else:
        mult = 1.0

    effective_cost = cost * mult

    # Check rate limit
    rate_limit_raw = await conn.fetchval(
        "SELECT value FROM config WHERE key = $1",
        f"channel.{msg.channel_type}.rate_limit.max_per_sender_per_hour",
    )
    rate_limit = DEFAULT_RATE_LIMIT
    if rate_limit_raw is not None:
        try:
            rate_limit = int(json.loads(rate_limit_raw) if isinstance(rate_limit_raw, str) else rate_limit_raw)
        except (ValueError, TypeError):
            pass

    if rate_limit is not None:
        # Count recent messages from this sender
        count = await conn.fetchval(
            """
            SELECT COUNT(*) FROM channel_messages cm
            JOIN channel_sessions cs ON cm.session_id = cs.id
            WHERE cs.sender_id = $1 AND cs.channel_type = $2
              AND cm.direction = 'inbound'
              AND cm.created_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'
            """,
            msg.sender_id,
            msg.channel_type,
        )
        if count and count >= rate_limit:
            return False, effective_cost, "Rate limit exceeded. Please try again later."

    # Check energy (skip if cost is 0)
    if effective_cost > 0:
        updated = await conn.fetchval(
            """
            UPDATE heartbeat_state
            SET current_energy = current_energy - $1
            WHERE current_energy >= $1
            RETURNING current_energy
            """,
            effective_cost,
        )
        if updated is None:
            return False, effective_cost, "I need to rest and recharge before I can respond. Please try again later."

    return True, effective_cost, None


async def _get_or_create_session(
    conn: asyncpg.Connection,
    msg: ChannelMessage,
) -> tuple[str, list[dict[str, Any]]]:
    """
    Load or create a channel session for this sender.

    Returns (session_id, history).
    """
    row = await conn.fetchrow(
        """
        SELECT id, history FROM channel_sessions
        WHERE channel_type = $1 AND channel_id = $2 AND sender_id = $3
        """,
        msg.channel_type,
        msg.channel_id,
        msg.sender_id,
    )

    if row:
        session_id = str(row["id"])
        raw_history = row["history"]
        if isinstance(raw_history, str):
            history = json.loads(raw_history)
        elif isinstance(raw_history, list):
            history = raw_history
        else:
            history = []
        return session_id, history

    # Create new session
    session_id = await conn.fetchval(
        """
        INSERT INTO channel_sessions (channel_type, channel_id, sender_id, sender_name, history)
        VALUES ($1, $2, $3, $4, '[]'::jsonb)
        RETURNING id::text
        """,
        msg.channel_type,
        msg.channel_id,
        msg.sender_id,
        msg.sender_name,
    )
    return str(session_id), []


async def _flush_trimmed_to_memory(
    dsn: str,
    trimmed_messages: list[dict[str, Any]],
    session_id: str,
    sender_id: str | None = None,
) -> int:
    """
    Pre-compaction memory flush: extract important information from messages
    about to be trimmed and store as memories.

    Groups user/assistant pairs and creates episodic memories for each.
    Only stores pairs that seem worth remembering (long, contain learning signals).
    Runs silently -- no output to the user.

    Returns the number of memories stored.
    """
    if not trimmed_messages:
        return 0

    # Pair up user/assistant turns
    pairs: list[tuple[str, str]] = []
    i = 0
    while i < len(trimmed_messages):
        msg = trimmed_messages[i]
        user_text = ""
        assistant_text = ""

        if msg.get("role") == "user":
            user_text = msg.get("content", "")
            if i + 1 < len(trimmed_messages) and trimmed_messages[i + 1].get("role") == "assistant":
                assistant_text = trimmed_messages[i + 1].get("content", "")
                i += 2
            else:
                i += 1
        elif msg.get("role") == "assistant":
            assistant_text = msg.get("content", "")
            i += 1
        else:
            i += 1
            continue

        if user_text or assistant_text:
            pairs.append((user_text, assistant_text))

    if not pairs:
        return 0

    stored = 0
    try:
        from core.cognitive_memory_api import CognitiveMemory

        async with CognitiveMemory.connect(dsn) as mem:
            for idx, (user_text, assistant_text) in enumerate(pairs):
                combined = (user_text + " " + assistant_text).lower()
                importance = 0.3

                learning_signals = [
                    "remember", "don't forget", "important", "note that",
                    "my name is", "i prefer", "i like", "i don't like",
                    "always", "never", "make sure", "keep in mind",
                ]
                if any(signal in combined for signal in learning_signals):
                    importance = max(importance, 0.7)
                if len(user_text) > 200 or len(assistant_text) > 500:
                    importance = max(importance, 0.5)

                if importance < 0.4 and len(user_text) + len(assistant_text) < 100:
                    continue

                source_attr = {
                    "kind": "compaction_flush",
                    "ref": session_id,
                    "label": "pre-compaction memory flush",
                    "observed_at": datetime.now(timezone.utc).isoformat(),
                    "trust": 0.85,
                }

                # PR-C: preserve real sender through compaction flush. Synthetic
                # suffix is the idempotency disambiguator, not the identity.
                digest = hashlib.sha256(f"{user_text}\x1e{assistant_text}".encode("utf-8")).hexdigest()[:16]
                identity_prefix = sender_id or "session"
                await mem.remember_turn_raw(
                    user_text,
                    assistant_text,
                    session_id=session_id,
                    source_identity=f"{identity_prefix}:compaction:{session_id}:{idx}:{digest}",
                    importance=importance,
                    source_attribution=source_attr,
                    metadata={"type": "conversation", "source": "compaction_flush"},
                )
                stored += 1

        if stored:
            logger.info("Pre-compaction flush: stored %d memories from %d pairs (session=%s)", stored, len(pairs), session_id)
    except Exception:
        logger.exception("Pre-compaction memory flush failed (session=%s)", session_id)

    return stored


async def _update_session(
    conn: asyncpg.Connection,
    session_id: str,
    history: list[dict[str, Any]],
    *,
    dsn: str | None = None,
    sender_id: str | None = None,
) -> None:
    """Update session history and last_active timestamp.

    When history exceeds the max bound, runs a pre-compaction memory flush to
    preserve important information from the messages being trimmed, then trims
    to the trim bound. Bounds come from _resolve_history_limits (per-persona
    config, fleet defaults otherwise).
    """
    max_n, trim_n = await _resolve_history_limits(conn)
    if len(history) > max_n:
        # Messages that will be discarded
        trimmed = history[:-trim_n]
        history = history[-trim_n:]

        # Flush trimmed messages to long-term memory (non-blocking best-effort)
        if dsn and trimmed:
            try:
                await _flush_trimmed_to_memory(dsn, trimmed, session_id, sender_id=sender_id)
            except Exception:
                logger.exception("Pre-compaction flush error (session=%s)", session_id)

    await conn.execute(
        """
        UPDATE channel_sessions
        SET history = $2::jsonb, last_active = CURRENT_TIMESTAMP
        WHERE id = $1::uuid
        """,
        session_id,
        json.dumps(history),
    )


def _prepend_reply_quote(user_content: str, msg: ChannelMessage) -> str:
    """Prepend a quote block when the user replied to / quoted a specific earlier
    message — the same context a participant sees rendered above the reply.

    Mirrors how the platform presents it to a human: the quoted snippet, attributed
    to its author (you, the agent itself, or another sender), above the new message.
    Content comes from the adapter (captured off the platform update), so this works
    even for quotes of messages we never logged. A partial-quote slice is preferred
    over the full referenced message (handled upstream in the adapter).
    """
    quoted = getattr(msg, "reply_to_text", None)
    if not quoted:
        return user_content
    if getattr(msg, "reply_to_is_self", False):
        who = "your earlier message"
    elif getattr(msg, "reply_to_sender", None):
        who = msg.reply_to_sender
    else:
        who = "an earlier message"
    note = f'[replying to {who}: "{quoted}"]'
    return f"{note}\n\n{user_content}" if user_content else note


async def _log_message(
    conn: asyncpg.Connection,
    session_id: str,
    direction: str,
    content: str,
    platform_message_id: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    """Log a message to channel_messages for audit."""
    await conn.execute(
        """
        INSERT INTO channel_messages (session_id, direction, content, platform_message_id, metadata)
        VALUES ($1::uuid, $2, $3, $4, $5::jsonb)
        """,
        session_id,
        direction,
        content,
        platform_message_id,
        json.dumps(metadata or {}),
    )


async def process_channel_message(
    msg: ChannelMessage,
    pool: asyncpg.Pool,
    *,
    max_message_length: int = 4000,
) -> list[str]:
    """
    Process an inbound channel message through the conversation pipeline.

    1. Load/create session (conversation history per sender)
    2. Delegate to services.chat.chat_turn() for enrichment + LLM + tools + memory
    3. Update session with new history
    4. Log messages for audit
    5. Chunk response for channel limits

    Args:
        msg: Normalized channel message.
        pool: Database connection pool.
        max_message_length: Channel's max message length for chunking.

    Returns:
        List of response text chunks to send back.
    """
    from core.agent_api import db_dsn_from_env
    from core.llm_config import load_llm_config

    try:
        async with pool.acquire() as conn:
            prepared = await _prepare_channel_turn_db(conn, msg)
            if not prepared.get("allowed"):
                return [prepared.get("rejection") or "I can't respond right now."]

            session_id = str(prepared["session_id"])
            history = prepared.get("history") if isinstance(prepared.get("history"), list) else []

            # Load LLM config from DB
            llm_config = await load_llm_config(conn, "llm.chat", fallback_key="llm.heartbeat")

        # Record channel event for audit trail (record-and-dispatch)
        try:
            from core.gateway import EventSource, Gateway

            gateway = Gateway(pool)
            await gateway.record(
                EventSource.CHANNEL,
                f"channel:{msg.channel_type}:{msg.channel_id}:{msg.sender_id}",
                {"message": msg.content[:500], "sender": msg.sender_name},
            )
        except Exception:
            logger.debug("Gateway record failed (non-fatal)", exc_info=True)

        # Build DSN for chat_turn (it manages its own connections)
        dsn = db_dsn_from_env()

        # Inject attachment context so the LLM knows about media
        user_content = msg.content
        if msg.attachments:
            from .media import Attachment
            descs = []
            for att in msg.attachments:
                if isinstance(att, Attachment):
                    descs.append(att.describe())
                elif isinstance(att, dict):
                    descs.append(str(att.get("filename") or att.get("url", "attachment")))
            if descs:
                attachment_note = "[User attached: " + "; ".join(descs) + "]"
                user_content = f"{attachment_note}\n\n{user_content}" if user_content else attachment_note

        # Inject reply/quote context the same way a participant sees it.
        user_content = _prepend_reply_quote(user_content, msg)

        # Run the conversation turn
        from services.chat import chat_turn

        result = await chat_turn(
            user_message=user_content,
            history=history,
            llm_config=llm_config,
            dsn=dsn,
            session_id=f"channel:{msg.channel_type}:{msg.channel_id}:{msg.sender_id}",
            pool=pool,
            sender_id=msg.sender_id,
        )

        assistant_text = result.get("assistant", "")
        new_history = result.get("history", [])

        async with pool.acquire() as conn:
            await _finalize_channel_turn_db(
                conn,
                session_id=session_id,
                user_text=user_content,
                assistant_text=assistant_text,
                history=new_history,
                metadata={"channel_type": msg.channel_type},
            )

        # Chunk for channel limits
        if not assistant_text:
            return ["I processed your message but have no response to give."]

        return chunk_text(assistant_text, max_message_length)

    except Exception:
        logger.exception("Error processing channel message from %s/%s", msg.channel_type, msg.sender_id)
        return ["Sorry, I encountered an error processing your message. Please try again."]


async def stream_channel_message(
    msg: ChannelMessage,
    pool: asyncpg.Pool,
    adapter: Any,
) -> str | None:
    """
    Process an inbound channel message with streaming edit-in-place delivery.

    Uses StreamCoalescer to progressively edit a message as tokens arrive.
    Falls back to process_channel_message() if streaming fails.

    Args:
        msg: Normalized channel message.
        pool: Database connection pool.
        adapter: The channel adapter (must support edit_message).

    Returns:
        The platform message ID of the final response, or None.
    """
    from channels.streaming import StreamCoalescer
    from core.agent_api import db_dsn_from_env
    from core.llm_config import load_llm_config
    from services.chat import stream_chat_turn

    try:
        async with pool.acquire() as conn:
            prepared = await _prepare_channel_turn_db(conn, msg)
            if not prepared.get("allowed"):
                await adapter.send(msg.channel_id, prepared.get("rejection") or "I can't respond right now.", reply_to=msg.message_id)
                return None

            session_id = str(prepared["session_id"])
            history = prepared.get("history") if isinstance(prepared.get("history"), list) else []
            llm_config = await load_llm_config(conn, "llm.chat", fallback_key="llm.heartbeat")

        # Record channel event for audit trail (record-and-dispatch)
        try:
            from core.gateway import EventSource, Gateway

            gateway = Gateway(pool)
            await gateway.record(
                EventSource.CHANNEL,
                f"channel:{msg.channel_type}:{msg.channel_id}:{msg.sender_id}",
                {"message": msg.content[:500], "sender": msg.sender_name, "streamed": True},
            )
        except Exception:
            logger.debug("Gateway record failed (non-fatal)", exc_info=True)

        dsn = db_dsn_from_env()

        # Inject attachment context
        user_content = msg.content
        if msg.attachments:
            from .media import Attachment
            descs = []
            for att in msg.attachments:
                if isinstance(att, Attachment):
                    descs.append(att.describe())
                elif isinstance(att, dict):
                    descs.append(str(att.get("filename") or att.get("url", "attachment")))
            if descs:
                attachment_note = "[User attached: " + "; ".join(descs) + "]"
                user_content = f"{attachment_note}\n\n{user_content}" if user_content else attachment_note

        # Inject reply/quote context the same way a participant sees it.
        user_content = _prepend_reply_quote(user_content, msg)

        coalescer = StreamCoalescer(
            adapter,
            msg.channel_id,
            reply_to=msg.message_id,
            thread_id=msg.thread_id,
        )

        collected: list[str] = []
        async for token in stream_chat_turn(
            user_message=user_content,
            history=history,
            llm_config=llm_config,
            dsn=dsn,
            session_id=f"channel:{msg.channel_type}:{msg.channel_id}:{msg.sender_id}",
            pool=pool,
            sender_id=msg.sender_id,
        ):
            collected.append(token)
            await coalescer.push(token)

        message_id = await coalescer.flush()
        assistant_text = "".join(collected)

        if not assistant_text:
            # Model returned nothing — don't poison history with an empty assistant turn.
            # Send a fallback so the user knows the message was received.
            logger.warning(
                "Empty streaming response for %s/%s — sending fallback, not storing in history",
                msg.channel_type, msg.sender_id,
            )
            try:
                await adapter.send(
                    msg.channel_id,
                    "...",
                    reply_to=msg.message_id,
                    thread_id=msg.thread_id,
                )
            except Exception:
                logger.debug("Failed to send empty-response fallback", exc_info=True)
            return None

        # Update session and log
        new_history = list(history)
        new_history.append({"role": "user", "content": user_content})
        new_history.append({"role": "assistant", "content": assistant_text})

        async with pool.acquire() as conn:
            await _finalize_channel_turn_db(
                conn,
                session_id=session_id,
                user_text=user_content,
                assistant_text=assistant_text,
                history=new_history,
                platform_message_id=message_id,
                metadata={"channel_type": msg.channel_type, "streamed": True},
            )

        return message_id

    except Exception:
        logger.exception("Streaming failed for %s/%s, falling back to chunked", msg.channel_type, msg.sender_id)
        # Fall back to non-streaming
        chunks = await process_channel_message(
            msg, pool, max_message_length=adapter.capabilities.max_message_length,
        )
        reply_to = msg.message_id
        for i, chunk in enumerate(chunks):
            try:
                await adapter.send(
                    msg.channel_id,
                    chunk,
                    reply_to=reply_to if i == 0 else None,
                    thread_id=msg.thread_id,
                )
            except Exception:
                break
        return None
