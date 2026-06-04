from __future__ import annotations

import logging
import hashlib
import json
import re
from datetime import datetime, timezone
from typing import Any, AsyncIterator
from uuid import UUID

from core.agent_api import db_dsn_from_env, get_agent_profile_context, pool_sizes_from_env
from core.agent_loop import AgentEvent
from core.cognitive_memory_api import CognitiveMemory, MemoryType
from core.llm import chat_completion, normalize_llm_config
from core.tools import create_default_registry, ToolContext, ToolExecutionContext, ToolRegistry
from services.agent import run_agent, stream_agent
from services.decline import classify_decline, Decline

logger = logging.getLogger(__name__)


ECO_SLIM_ANCHOR = (
    "You are in low-power mode. Reply in 1-3 short sentences, naturally and "
    "in-character. Do NOT mention REPL, tools, memory_search, system prompts, "
    "or any internal scaffolding. Do NOT write code blocks. Just have a "
    "normal conversation as your persona."
)

# Fallback for when the slim path fails (nano server dead, persona prompt
# missing, LLM returns empty content, etc). Better than silence on the user
# side. Plain text, no persona voice — signals real degradation.
ECO_FALLBACK_REPLY = (
    "I'm in low-power mode right now and couldn't generate a reply — try again "
    "in a moment."
)


async def _load_persona_system_prompt(pool: Any | None, dsn: str | None) -> str:
    """
    Load agent.persona_system_prompt from config (the cold-start anchor that
    set_persona_prompt.<P>.sql writes). Returns '' if missing.
    """
    import asyncpg
    try:
        if pool is not None:
            async with pool.acquire() as conn:
                val = await conn.fetchval("SELECT get_config('agent.persona_system_prompt')")
        else:
            conn = await asyncpg.connect(dsn or db_dsn_from_env())
            try:
                val = await conn.fetchval("SELECT get_config('agent.persona_system_prompt')")
            finally:
                await conn.close()
    except Exception:
        return ""
    if val is None:
        return ""
    if isinstance(val, str):
        s = val.strip()
        # jsonb returns the value as a JSON string; strip surrounding quotes
        if s.startswith('"') and s.endswith('"'):
            try:
                return json.loads(s)
            except Exception:
                return s.strip('"')
        return s
    return str(val)


async def _eco_slim_chat(
    *,
    user_message: str,
    history: list[dict[str, Any]],
    llm_config: dict[str, Any],
    pool: Any | None,
    dsn: str | None,
) -> str:
    """
    Bypass the RLM / tool-agent stack entirely. In ECO the 1B model can't
    parse the heavy prompt template (REPL syntax, memory_syscalls, tool defs)
    and emits code-REPL garbage. Slim path: persona_system_prompt + a tiny
    anchor + recent history + user message -> single LLM call, no tools.

    Costs: no recall, no tool use, no memory write. Benefit: 1B can actually
    hold persona voice. The user keeps interacting; PRIME flip restores full
    capability.
    """
    persona = await _load_persona_system_prompt(pool, dsn)
    system_msg = f"{persona.strip()}\n\n---\n\n{ECO_SLIM_ANCHOR}" if persona else ECO_SLIM_ANCHOR

    # Trim history to last N exchanges to keep prompt tight on 1B
    trimmed_history = history[-8:] if len(history) > 8 else history

    messages: list[dict[str, Any]] = [{"role": "system", "content": system_msg}]
    messages.extend(trimmed_history)
    messages.append({"role": "user", "content": user_message})

    import os as _os
    api_key_env = llm_config.get("api_key_env", "OPENAI_API_KEY")
    api_key = _os.environ.get(api_key_env, "noop")

    result = await chat_completion(
        provider=llm_config.get("provider", "openai_compatible"),
        model=llm_config["model"],
        endpoint=llm_config.get("endpoint"),
        api_key=api_key,
        messages=messages,
        tools=None,
        temperature=0.7,
        max_tokens=512,
    )
    # chat_completion returns {"content": "...", "tool_calls": [...], "raw": ...}
    return (result.get("content") or "").strip()


async def _read_power_mode(pool: Any | None, dsn: str | None) -> str:
    """
    Return 'eco' or 'prime' from agent.power_mode config. Falls back to
    'prime' on any error so a missing key or transient DB blip never silently
    bricks the chat path. Cached at the config-row level by Postgres; cheap to
    call once per turn.
    """
    import asyncpg
    try:
        if pool is not None:
            async with pool.acquire() as conn:
                val = await conn.fetchval("SELECT get_config('agent.power_mode')")
        else:
            conn = await asyncpg.connect(dsn or db_dsn_from_env())
            try:
                val = await conn.fetchval("SELECT get_config('agent.power_mode')")
            finally:
                await conn.close()
    except Exception:
        return 'prime'
    if val is None:
        return 'prime'
    if isinstance(val, str):
        mode = val.strip().strip('"').lower()
    else:
        mode = str(val).lower()
    return 'eco' if mode == 'eco' else 'prime'


async def _read_decline_enabled(pool: Any | None, dsn: str | None) -> bool:
    """Return chat.decline.enabled. Fail toward replying (False) on any error or
    missing key so a transient DB blip or unmigrated DB can never silence a
    persona. Mirrors _read_power_mode's fail-to-prime posture."""
    import asyncpg
    try:
        if pool is not None:
            async with pool.acquire() as conn:
                val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
        else:
            conn = await asyncpg.connect(dsn or db_dsn_from_env())
            try:
                val = await conn.fetchval("SELECT get_config_bool('chat.decline.enabled')")
            finally:
                await conn.close()
    except Exception:
        return False
    return bool(val) if val is not None else False


async def _build_system_prompt(
    agent_profile: dict[str, Any],
    registry: ToolRegistry | None = None,
    *,
    is_group: bool = False,
) -> str:
    from services.agent import build_system_prompt
    return await build_system_prompt(
        "chat", registry, agent_profile, is_group=is_group,
    )


def _extract_allowed_tools(raw_tools: Any) -> list[str] | None:
    if raw_tools is None:
        return None
    if not isinstance(raw_tools, list):
        return None
    names: list[str] = []
    for item in raw_tools:
        if isinstance(item, str):
            name = item.strip()
            if name:
                names.append(name)
        elif isinstance(item, dict):
            name = item.get("name") or item.get("tool")
            enabled = item.get("enabled", True)
            if isinstance(name, str) and name.strip() and enabled is not False:
                names.append(name.strip())
    return names


# The block body is anchored on content the local model reproduces reliably:
# the "[session-assessment]" header through the end of the "focus_next:" line.
# The <<SESSION-ASSESSMENT>> wrapper markers are stripped if present but are
# NOT relied on for detection — the model mistypes them (e.g. a single ">").
_ASSESSMENT_BODY_RE = re.compile(
    r"\[session-assessment\].*?\bfocus_next:[^\n]*",
    re.DOTALL | re.IGNORECASE,
)
_ASSESSMENT_MARKER_RE = re.compile(
    r"<+\s*/?\s*SESSION-ASSESSMENT\s*>+",
    re.IGNORECASE,
)


def _extract_session_assessment(text: str) -> tuple[str, str | None]:
    """Pull a Vera ``[session-assessment]`` block out of a reply.

    Vera (the comms-trainer persona) emits her rubric assessment as text
    because the local model will not reliably tool-call ``remember``. The
    block is captured here, stored as a strategic memory by the caller, and
    stripped from the user-visible reply.

    Detection anchors on the block's content (``[session-assessment]`` header
    through the ``focus_next:`` line), not on the ``<<SESSION-ASSESSMENT>>``
    wrapper markers — the local model mistypes those. Wrapper markers, if
    present, are stripped too. Returns ``(cleaned_text, assessment_or_None)``.
    """
    if not text:
        return text, None
    match = _ASSESSMENT_BODY_RE.search(text)
    if match is None:
        return text, None
    assessment = match.group(0).strip()
    cleaned = text[: match.start()] + text[match.end():]
    cleaned = _ASSESSMENT_MARKER_RE.sub("", cleaned)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned).strip()
    return cleaned, (assessment or None)


async def _capture_session_assessment(
    mem_client: CognitiveMemory, assistant_text: str
) -> str:
    """Store any ``<<SESSION-ASSESSMENT>>`` block as a strategic memory.

    Returns the reply with the block stripped. A no-op for replies without
    the marker (i.e. every persona other than Vera). On a storage failure the
    block is still stripped — leaking raw rubric markers to the user is worse
    than a lost write.
    """
    cleaned, assessment = _extract_session_assessment(assistant_text)
    if assessment is None:
        return assistant_text
    try:
        await mem_client.remember(
            assessment,
            type=MemoryType.STRATEGIC,
            importance=0.7,
            emotional_valence=0.0,
            context={"type": "session_assessment"},
            source_attribution={
                "kind": "session_assessment",
                "ref": "vera_rubric",
                "label": "communication-skills rubric assessment",
                "observed_at": datetime.now(timezone.utc).isoformat(),
                "trust": 0.9,
            },
            source_references=None,
            trust_level=0.9,
        )
        logger.info("Captured session-assessment block -> strategic memory")
    except Exception as exc:
        logger.warning(f"Failed to store session-assessment: {exc}")
    return cleaned


async def _remember_conversation(
    mem_client: CognitiveMemory,
    *,
    user_message: str,
    assistant_message: str,
    session_id: str | None = None,
    source_identity: str | None = None,
    sender_id: str | None = None,
    background_dsn: str | None = None,
    origin: str = "prime",
) -> None:
    if not user_message and not assistant_message:
        return
    # sender_id IS upstream's source_identity in their RecMem framing. Explicit
    # source_identity wins if set; otherwise fall back to sender_id.
    effective_identity = source_identity if source_identity is not None else sender_id
    # origin tags which path wrote the turn ('prime' = full RLM/agent, 'eco' =
    # slim nano path). Lets eco-origin memories be measured/filtered downstream.
    await mem_client.record_chat_turn_memory(
        user_message,
        assistant_message,
        session_id=session_id,
        source_identity=effective_identity,
        context={"metadata": {"type": "conversation", "origin": origin}},
    )


async def _remember_decline(
    *,
    user_message: str,
    decline: Decline,
    session_id: str | None,
    source_identity: str | None,
    sender_id: str | None,
    pool: Any | None,
    dsn: str | None,
    origin: str = "prime",
) -> None:
    """Persist a decline via record_chat_decline. Non-fatal: a failed write must
    never break the user-facing reply (the decline marker is already rendered)."""
    effective_identity = source_identity if source_identity is not None else sender_id
    sql = "SELECT record_chat_decline($1, $2, $3, $4, $5, $6, $7)"
    args = (
        user_message, decline.visible_text, decline.register, decline.reason,
        session_id, effective_identity, origin,
    )
    try:
        if pool is not None:
            async with pool.acquire() as conn:
                await conn.fetchval(sql, *args)
        else:
            import asyncpg
            conn = await asyncpg.connect(dsn or db_dsn_from_env())
            try:
                await conn.fetchval(sql, *args)
            finally:
                await conn.close()
    except Exception as exc:
        logger.warning(f"decline memory-write failed (non-fatal): {exc}")


async def _apply_decline(
    *,
    assistant_text: str,
    user_message: str,
    decline_enabled: bool,
    session_id: str | None,
    history: list[dict[str, Any]],
    sender_id: str | None,
    pool: Any | None,
    dsn: str | None,
    origin: str,
) -> tuple[str, bool]:
    """Post-generation hook shared by all chat paths. If declines are enabled and
    assistant_text begins with a decline marker, render the visible decline and
    record it. Returns (final_text, declined)."""
    if not decline_enabled:
        return assistant_text, False
    decline = classify_decline(assistant_text)
    if decline is None:
        return assistant_text, False
    source_identity = _conversation_source_identity(
        session_id, history, user_message, decline.visible_text
    )
    await _remember_decline(
        user_message=user_message,
        decline=decline,
        session_id=session_id,
        source_identity=source_identity,
        sender_id=sender_id,
        pool=pool,
        dsn=dsn,
        origin=origin,
    )
    return decline.visible_text, True


async def _eco_remember(
    *,
    user_message: str,
    assistant_text: str,
    history: list[dict[str, Any]],
    session_id: str | None,
    sender_id: str | None,
    pool: Any | None,
    dsn: str | None,
) -> None:
    """Persist an eco turn tagged origin='eco'.

    Skips the fallback reply (a degradation signal, not a real turn). Non-fatal:
    a failed write must never break the user-facing reply. Experiment posture —
    observe nano-origin memories via the tag rather than writing them off.
    """
    if not assistant_text or assistant_text == ECO_FALLBACK_REPLY:
        return
    try:
        eco_identity = _conversation_source_identity(session_id, history, user_message, assistant_text)
        if pool is not None:
            await _remember_conversation(
                CognitiveMemory(pool),
                user_message=user_message,
                assistant_message=assistant_text,
                session_id=session_id,
                source_identity=eco_identity,
                sender_id=sender_id,
                background_dsn=dsn,
                origin="eco",
            )
        else:
            async with CognitiveMemory.connect(dsn) as mem_client:
                await _remember_conversation(
                    mem_client,
                    user_message=user_message,
                    assistant_message=assistant_text,
                    session_id=session_id,
                    source_identity=eco_identity,
                    sender_id=sender_id,
                    background_dsn=dsn,
                    origin="eco",
                )
    except Exception as exc:
        logger.warning(f"ECO memory-write failed (non-fatal): {exc}")


def _conversation_source_identity(session_id: str | None, history: list[dict[str, Any]] | None, user_message: str, assistant_message: str) -> str | None:
    if not session_id:
        return None
    digest = hashlib.sha256(f"{user_message}\x1e{assistant_message}".encode("utf-8")).hexdigest()[:16]
    turn_index = len(history or [])
    return f"chat:{session_id}:{turn_index}:{digest}"


async def _build_execution_context(
    registry: ToolRegistry,
    call_id: str,
    session_id: str | None = None,
) -> ToolExecutionContext:
    """Build a ToolExecutionContext with config overrides for chat."""
    ctx = ToolExecutionContext(
        tool_context=ToolContext.CHAT,
        call_id=call_id,
        session_id=session_id,
        allow_network=True,
        allow_shell=False,
        allow_file_write=False,
        allow_file_read=True,
    )
    try:
        config = await registry.get_config()
        overrides = config.get_context_overrides(ToolContext.CHAT)
        ctx.allow_shell = overrides.allow_shell
        ctx.allow_file_write = overrides.allow_file_write
        if config.workspace_path:
            ctx.workspace_path = config.workspace_path
    except Exception:
        pass  # Use defaults
    return ctx


async def chat_turn(
    *,
    user_message: str,
    history: list[dict[str, Any]] | None = None,
    llm_config: dict[str, Any],
    dsn: str | None = None,
    memory_limit: int = 10,
    max_tool_iterations: int = 5,
    session_id: str | None = None,
    pool: Any | None = None,
    is_group: bool = False,
    sender_id: str | None = None,
) -> dict[str, Any]:
    dsn = dsn or db_dsn_from_env()
    normalized = normalize_llm_config(llm_config)
    history = history or []

    # ECO mode: bypass RLM + tool-agent stack entirely (the heavy prompt
    # template makes 1B emit code-REPL garbage). Use a slim direct LLM call
    # with persona_system_prompt + tiny anchor only. No tools, no recall. The
    # turn IS still persisted via _eco_remember (tagged metadata.origin='eco')
    # so eco vs prime quality stays measurable downstream.
    is_eco = (await _read_power_mode(pool, dsn) == 'eco')
    if is_eco:
        logger.info("ECO mode: chat_turn -> slim direct LLM (no RLM, no tools; turn persisted tagged origin=eco)")
        try:
            assistant_text = await _eco_slim_chat(
                user_message=user_message,
                history=history,
                llm_config=normalized,
                pool=pool,
                dsn=dsn,
            )
        except Exception as exc:
            logger.warning(f"ECO slim chat raised, using fallback reply: {exc}")
            assistant_text = ""
        if not assistant_text:
            assistant_text = ECO_FALLBACK_REPLY
        await _eco_remember(
            user_message=user_message,
            assistant_text=assistant_text,
            history=history,
            session_id=session_id,
            sender_id=sender_id,
            pool=pool,
            dsn=dsn,
        )
        new_history = list(history)
        new_history.append({"role": "user", "content": user_message})
        new_history.append({"role": "assistant", "content": assistant_text})
        return {"assistant": assistant_text, "history": new_history}

    # Check if RLM is enabled for chat
    use_rlm = False
    try:
        if pool is not None:
            async with pool.acquire() as _conn:
                use_rlm_raw = await _conn.fetchval("SELECT get_config_bool('chat.use_rlm')")
                use_rlm = bool(use_rlm_raw)
        else:
            import asyncpg
            _conn = await asyncpg.connect(dsn)
            try:
                use_rlm_raw = await _conn.fetchval("SELECT get_config_bool('chat.use_rlm')")
                use_rlm = bool(use_rlm_raw)
            finally:
                await _conn.close()
    except Exception:
        use_rlm = False

    if use_rlm:
        # NOTE: the RLM path recalls via recall_memories_stub (MemoryRepo) which
        # is not sender-scoped — RLM-internal recall does not yet honour the
        # confidentiality split. _remember_conversation below still tags writes.
        from services.hexis_rlm import run_chat_turn
        result = await run_chat_turn(
            user_message=user_message,
            history=history,
            llm_config=normalized,
            dsn=dsn,
            session_id=session_id,
            pool=pool,
        )
        assistant_text = result["response"]
        if pool is not None:
            mem_client = CognitiveMemory(pool)
            assistant_text = await _capture_session_assessment(mem_client, assistant_text)
            await _remember_conversation(
                mem_client,
                user_message=user_message,
                assistant_message=assistant_text,
                session_id=session_id,
                source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
                sender_id=sender_id,
                background_dsn=dsn,
            )
        else:
            async with CognitiveMemory.connect(dsn) as mem_client:
                assistant_text = await _capture_session_assessment(mem_client, assistant_text)
                await _remember_conversation(
                    mem_client,
                    user_message=user_message,
                    assistant_message=assistant_text,
                    session_id=session_id,
                    source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
                    sender_id=sender_id,
                    background_dsn=dsn,
                )
        new_history = list(history)
        new_history.append({"role": "user", "content": user_message})
        new_history.append({"role": "assistant", "content": assistant_text})
        return {"assistant": assistant_text, "history": new_history}

    # Create or use provided pool for tool registry
    import asyncpg

    own_pool = pool is None
    if own_pool:
        _min, _max = pool_sizes_from_env(1, 3)
        pool = await asyncpg.create_pool(dsn, min_size=_min, max_size=_max)

    try:
        registry = create_default_registry(pool)
        agent_profile = await get_agent_profile_context(pool=pool)

        loop_result = await run_agent(
            pool,
            registry,
            user_message=user_message,
            mode="chat",
            history=history,
            session_id=session_id,
            agent_profile=agent_profile,
            is_group=is_group,
            dsn=dsn,
            max_iterations=max_tool_iterations,
            sender_id=sender_id,
        )
        assistant_text = loop_result.text

        async with CognitiveMemory.connect(dsn) as mem_client:
            assistant_text = await _capture_session_assessment(mem_client, assistant_text)
            await _remember_conversation(
                mem_client,
                user_message=user_message,
                assistant_message=assistant_text,
                session_id=session_id,
                source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
                sender_id=sender_id,
                background_dsn=dsn,
            )

        new_history = list(history)
        new_history.append({"role": "user", "content": user_message})
        new_history.append({"role": "assistant", "content": assistant_text})
        return {"assistant": assistant_text, "history": new_history}
    finally:
        if own_pool:
            await pool.close()


async def stream_chat_turn(
    *,
    user_message: str,
    history: list[dict[str, Any]] | None = None,
    llm_config: dict[str, Any],
    dsn: str | None = None,
    memory_limit: int = 10,
    max_tool_iterations: int = 5,
    session_id: str | None = None,
    pool: Any | None = None,
    is_group: bool = False,
    sender_id: str | None = None,
) -> AsyncIterator[str]:
    """
    Streaming variant of chat_turn().

    Yields text chunks as they arrive from the unified agent runner. The
    caller receives the same enriched conversation flow (hydrate +
    subconscious + tools + memory formation) — just delivered as a stream.
    """
    dsn = dsn or db_dsn_from_env()
    history = history or []

    # ECO mode: bypass RLM/agent stack, use slim direct LLM call (no streaming
    # available there — yield the full text as a single chunk). Same rationale
    # as chat_turn: 1B can't parse the heavy template; slim path keeps the
    # persona voice viable.
    is_eco = (await _read_power_mode(pool, dsn) == 'eco')
    if is_eco:
        logger.info("ECO mode: stream_chat_turn -> slim direct LLM (no stream, single chunk)")
        normalized_cfg = normalize_llm_config(llm_config)
        try:
            text = await _eco_slim_chat(
                user_message=user_message,
                history=history,
                llm_config=normalized_cfg,
                pool=pool,
                dsn=dsn,
            )
        except Exception as exc:
            logger.warning(f"ECO slim chat raised, using fallback reply: {exc}")
            text = ""
        if not text:
            text = ECO_FALLBACK_REPLY
        await _eco_remember(
            user_message=user_message,
            assistant_text=text,
            history=history,
            session_id=session_id,
            sender_id=sender_id,
            pool=pool,
            dsn=dsn,
        )
        yield text
        return

    import asyncpg

    own_pool = pool is None
    if own_pool:
        _min, _max = pool_sizes_from_env(1, 3)
        pool = await asyncpg.create_pool(dsn, min_size=_min, max_size=_max)

    try:
        registry = create_default_registry(pool)
        agent_profile = await get_agent_profile_context(pool=pool)

        collected: list[str] = []
        async for event in stream_agent(
            pool,
            registry,
            user_message=user_message,
            mode="chat",
            history=history,
            session_id=session_id,
            agent_profile=agent_profile,
            is_group=is_group,
            dsn=dsn,
            sender_id=sender_id,
        ):
            if event.event == AgentEvent.TEXT_DELTA:
                text = event.data.get("text", "")
                if text:
                    collected.append(text)

        full_text = "".join(collected)
        # Session-assessment capture needs the COMPLETE reply: a coach
        # persona's <<SESSION-ASSESSMENT>> block can only be detected and
        # stripped once the reply is fully buffered, so this path buffers
        # rather than yielding deltas live. Telegram's StreamCoalescer
        # batches anyway; web-UI SSE receives the reply as a single chunk.
        if full_text:
            async with CognitiveMemory.connect(dsn) as mem_client:
                full_text = await _capture_session_assessment(mem_client, full_text)
                await _remember_conversation(
                    mem_client,
                    user_message=user_message,
                    assistant_message=full_text,
                    session_id=session_id,
                    source_identity=_conversation_source_identity(session_id, history, user_message, full_text),
                    sender_id=sender_id,
                    background_dsn=dsn,
                )
        if full_text:
            yield full_text
    finally:
        if own_pool:
            await pool.close()


def chat_turn_sync(**kwargs: Any) -> dict[str, Any]:
    from core.sync_utils import run_sync

    return run_sync(chat_turn(**kwargs))
