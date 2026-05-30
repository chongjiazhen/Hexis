# Handoff: eco memory-write, tagged `origin=eco`

**Date:** 2026-05-30
**For:** the agent editing `services/chat.py`
**Status:** spec ready, NOT implemented (handed off to avoid edit collision)

## Decision

ECO currently writes **no** memory (slim path returns early before `_remember_conversation`).
Change: under eco, **write the turn** but tag it `metadata.origin='eco'` so eco-origin
memories are auditable / filterable — experiment with them instead of writing them off.

Rationale: memory-write is cheap (pure PL/pgSQL `record_chat_turn_memory`, embedding via
always-on CPU embed `:8081`, no GPU, no generative LLM). The original skip was really about
*poisoning* (1B nano output → recalled in PRIME → re-emitted, the worldsim RP-loop trap).
Tagging defers that safety to a one-query filter instead of pre-deleting the signal.
Observability-over-deletion (CLAUDE.md "Fix vs Design Overreach" §3).

## Callsites

Both eco blocks return early before the normal `_remember_conversation` call:

- `chat_turn` eco block ends at `services/chat.py:349`
- `stream_chat_turn` eco block ends at `services/chat.py:505`

Normal write happens via `_remember_conversation` (`services/chat.py:250`), which calls
`mem_client.record_chat_turn_memory(...)` with `context={"metadata": {"type": "conversation"}}`.

## Changes

### 1. `_remember_conversation` — add `origin` param

```python
async def _remember_conversation(
    mem_client: CognitiveMemory,
    *,
    user_message: str,
    assistant_message: str,
    session_id: str | None = None,
    source_identity: str | None = None,
    sender_id: str | None = None,
    background_dsn: str | None = None,
    origin: str = "prime",          # NEW
) -> None:
    if not user_message and not assistant_message:
        return
    effective_identity = source_identity if source_identity is not None else sender_id
    await mem_client.record_chat_turn_memory(
        user_message,
        assistant_message,
        session_id=session_id,
        source_identity=effective_identity,
        context={"metadata": {"type": "conversation", "origin": origin}},   # CHANGED
    )
```

Existing PRIME/RLM callsites need no change (default `origin="prime"`).

### 2. `chat_turn` eco block (ends `:349`) — write before return

Before `return {"assistant": assistant_text, "history": new_history}`, and only when the
reply is real (not the degradation fallback):

```python
if assistant_text and assistant_text != ECO_FALLBACK_REPLY:
    try:
        if pool is not None:
            mem_client = CognitiveMemory(pool)
            await _remember_conversation(
                mem_client,
                user_message=user_message,
                assistant_message=assistant_text,
                session_id=session_id,
                source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
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
                    source_identity=_conversation_source_identity(session_id, history, user_message, assistant_text),
                    sender_id=sender_id,
                    background_dsn=dsn,
                    origin="eco",
                )
    except Exception as exc:
        logger.warning(f"ECO memory-write failed (non-fatal): {exc}")
```

Mirror the pool-vs-`connect` branch the normal paths already use. Keep the write
non-fatal — a failed eco memory-write must not break the user-facing reply.

### 3. `stream_chat_turn` eco block (ends `:505`) — write before `yield`

Same write, inserted after `text` is finalized and before `yield text` / `return`. Guard
identically (`text and text != ECO_FALLBACK_REPLY`). Build a `mem_client` the same way.

## Design choices (locked)

- **Write both turns, identical to PRIME.** No trust down-weight, no importance cap — the
  point is to observe the *real* effect of nano-origin memories. The only delta vs PRIME is
  the tag.
- **Tag in `metadata.origin='eco'` only.** NOT in the content body or recalled text — a
  visible `[eco]` in the body risks the model echoing it (leak). Metadata is enough for
  filtering.
- **Skip the fallback reply.** `ECO_FALLBACK_REPLY` is a degradation signal, not a turn; the
  `if not user and not assistant` guard won't catch it (user_message is present), so guard
  explicitly.

## Test

`tests/core/test_chat.py` (eco slim path already has coverage there):

1. eco turn with a real slim reply → a `memories`/recmem row exists with
   `metadata->>'origin' = 'eco'`.
2. eco turn that falls back to `ECO_FALLBACK_REPLY` → no memory written.
3. (regression) PRIME turn still writes with `origin='prime'` (or absent-but-not-eco).

## Observability (the payoff)

```sql
-- how many eco-origin memories exist
SELECT count(*) FROM memories WHERE metadata->>'origin' = 'eco';
-- whether eco memories get recalled (join against recall logs / inspect by hand)
```

Lets the poisoning question be *measured* instead of assumed. If eco memories degrade recall,
the tag makes exclusion/down-weight a one-line `fast_recall` filter — no data already lost.

## Follow-up (not this change)

Once landed, update `.local-notes/research/home-rig-local-vs-upstream-personhood-review.md`
§Tensions — family I's "no memory-write under eco" continuity gap is now closed (tagged-write),
leaving only the honestly-labeled fallback as the residual puppet moment.
