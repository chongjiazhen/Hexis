# Telegram Alert Bot + Hexis Persona — Design

**Date:** 2026-05-22
**Status:** Approved design, pending implementation plan

## Problem

The user runs a standalone Telegram bot that consolidates alerts from various
personal scripts (price alerts, monitors, etc.). They want a hexis persona to
inhabit that same bot: deliver the alerts, optionally react to them in
character, be aware of them as memories, and participate in daily routine
(scheduled digests/recaps the user can ask for).

## Decisions (locked during brainstorming)

| Question | Decision |
|----------|----------|
| One bot or two? | **One bot.** The persona's hexis Telegram bot token becomes the alert bot's token. |
| Alert through LLM, or raw? | **Hybrid.** Alert text delivered verbatim; persona may append an in-character reaction below it. |
| Who decides if persona reacts? | **The persona.** It can choose silence on any alert. |
| Daily-routine scope | **Awareness** (definite) + **scheduled rituals on demand** (no upfront build — uses the existing `manage_schedule` tool). Routine-data ingestion (calendar/tasks) is out of scope. |
| Reaction timing | **Tiered.** Alerts carry a `priority`; `high` → immediate reaction, `normal` → batched via heartbeat. |

## Existing plumbing this design builds on

- `POST /api/webhook/{source}` (`apps/hexis_api.py:157`) — accepts an external
  payload, calls `Gateway.submit(EventSource.WEBHOOK, "webhook:{source}", payload)`,
  returns `202 {event_id}`. Already exists.
- `Gateway` / `GatewayConsumer` (`core/gateway.py`) — queue-and-consume. The
  worker registers `EventSource.WEBHOOK` → `create_webhook_handler`
  (`services/worker_service.py:673`).
- `create_webhook_handler` (`services/worker_service.py:578`) — currently
  records the webhook payload as a 0.4-importance episodic memory and nothing
  else. **No Telegram delivery, no persona reaction.** This is the gap.
- `TelegramAdapter` (`channels/telegram_adapter.py`) — inbound + outbound, one
  bot token per persona DB (`channel.telegram.bot_token`).
- The outbox (`channels/outbox.py`, per-persona queue `hexis.outbox.<persona>`)
  — durable proactive-send path. A queued message survives a worker crash.
- `manage_schedule` tool (`core/tools/cron.py`, `ManageScheduleHandler`) —
  the persona can create scheduled tasks via tool-use, including
  `delivery_mode=channel` → a specific Telegram chat/topic. Available in
  `CHAT`, `HEARTBEAT`, and `MCP` contexts.
- Heartbeat — autonomous jittered timer; already does proactive reach-out
  through the outbox.

## Architecture

```
personal alert scripts
        │  POST /api/webhook/alert  { text, priority, title?, tags? }
        ▼
hexis_api  ──►  Gateway.submit(WEBHOOK, "webhook:alert", payload)
        │
        ▼  (queued, pg_notify)
GatewayConsumer (worker)  ──►  handle_webhook(event)
        │
        ├─ 1. send `text` verbatim → outbox → Telegram alert chat   [no LLM]
        ├─ 2. record episodic memory (importance by priority, reacted=false)
        └─ 3. route reaction:
               priority=high   → immediate bounded LLM reaction turn
               priority=normal → leave for heartbeat to pick up
        ▼
heartbeat handler  ──►  scan reacted=false alert memories
                        → optional grouped comment → mark reacted=true
```

### Component 1 — Webhook contract

`POST /api/webhook/alert`

```json
{
  "text": "BTC crossed 70k",
  "priority": "high",
  "title": "price-alert",
  "tags": ["btc"]
}
```

- `text` — **required.** The verbatim alert body. Delivered untouched.
- `priority` — `"high"` | `"normal"`. Default `"normal"`.
- `title` — optional. Used for the memory label and reaction context.
- `tags` — optional string array. Stored on the memory context.

A payload with no non-empty `text` is rejected: the gateway event is marked
`failed` and nothing is sent to Telegram.

No change to `hexis_api.py` itself — the generic `POST /api/webhook/{source}`
already accepts this. `source=alert` is the routing key the handler keys on.

### Component 2 — Webhook handler (raw delivery + memory)

Modify `create_webhook_handler` in `services/worker_service.py`. When
`source_name == "alert"`, run these steps **in order**, each independently
error-isolated:

1. **Raw delivery.** Enqueue `payload["text"]` verbatim to the outbox, targeted
   at `channel.telegram.alert_chat_id`. The outbox is durable — a worker crash
   between submit and send does not lose the alert. No LLM, no reformatting:
   numbers, tickers, and URLs are byte-identical to what the script sent.
2. **Memory.** Record the episodic memory (the handler already does this).
   Change: importance keyed to priority — `high` → 0.7, `normal` → 0.4. The
   memory context carries `kind=alert`, `priority`, `title`, `tags`, and
   `reacted=false`.
3. **Reaction routing** — see Component 3.

Step 1 runs first and unconditionally. Failure in step 2 or 3 never blocks or
reverses raw delivery.

Non-`alert` webhook sources keep the current behavior (memory only).

### Component 3 — Tiered reaction

The reaction is a **bounded LLM turn**: input = the alert text + a small recall
context + the persona system prompt; output = either a short in-character
comment or explicit silence. A comment is sent through the outbox to the alert
chat. Silence sends nothing — a valid, first-class outcome (matches hexis's
agency model: the persona can refuse).

- **`priority=high` → immediate.** The webhook handler runs the reaction turn
  inline, right after raw delivery. One LLM call per high alert, including
  alerts the persona ends up ignoring.
- **`priority=normal` → batched.** The handler does nothing further. The
  heartbeat handler, on its next run, scans for episodic memories with
  `kind=alert` and `reacted=false`, optionally comments (may group several
  into one message), and marks them `reacted=true`. Reaction lag = up to one
  heartbeat interval (jittered, ~10-40 min).

The immediate path also marks its memory `reacted=true` so the heartbeat does
not double-react.

**Reply threading.** A reaction is sent as a Telegram reply to the raw alert
message *if* the outbox surfaces the sent `message_id` back to the handler. If
it does not, the reaction lands as a standalone follow-up message in the same
chat. The standalone fallback is acceptable; threading is a nice-to-have.

### Component 4 — Scheduled rituals (no code)

Daily digests / recaps are **not built upfront.** The persona already has the
`manage_schedule` tool. The user asks in chat ("send me a 7am overnight
digest"); the persona creates a scheduled task with `delivery_mode=channel`,
`delivery_channel=telegram`, `delivery_target_id=<alert chat>`. The task fires
`queue_user_message` to the persona, which composes the ritual in character.

This design only needs to **document** that this path exists; no new code.

## Configuration

| Key | Purpose |
|-----|---------|
| `channel.telegram.bot_token` | Existing. The one bot's token. |
| `channel.telegram.alert_chat_id` | **New.** Chat ID that raw alerts and reactions are delivered to. |

The reaction LLM turn reuses `llm.chat`. No new model config.

## ECO mode

`agent.power_mode='eco'` (single flag workers gate on):

- **Raw alert delivery still works** — it is LLM-free, so ECO does not affect it.
- **All reactions are skipped** — both `high` and `normal`. The handler does not
  run the immediate reaction turn; the heartbeat timer already skips in ECO so
  batched reactions naturally pause.

PRIME restores reactions.

## Error handling

| Failure | Behavior |
|---------|----------|
| Raw outbox send fails | Outbox durability retries; nothing silently lost. |
| Memory record fails | Logged; raw alert already delivered; reaction still attempted. |
| LLM down during reaction | Reaction skipped; alert already delivered. No canned fallback — silence is valid. |
| Malformed payload (no `text`) | Gateway event marked `failed`; nothing sent to Telegram. |
| `alert_chat_id` unconfigured | Handler logs an error and marks the event failed; surfaced, not silent. |

## Testing

- `POST /api/webhook/alert` → asserts a raw message is queued to the outbox
  **and** an episodic memory is created with importance matching priority.
- `priority=high` → reaction turn is triggered; `priority=normal` → it is not.
- Batched path: a `reacted=false` alert memory → heartbeat reacts and flips it
  to `reacted=true`.
- ECO mode → raw alert delivered, no reaction (high and normal).
- Malformed payload (missing/empty `text`) → event failed, no Telegram send.

## Out of scope

- Routine-data ingestion (calendar, tasks, journal) — explicitly deferred.
- Reformatting / persona-voicing the alert body itself — alerts stay verbatim.
- Migrating the user's alert scripts — they must be re-pointed from the
  Telegram API to `POST /api/webhook/alert`, but that is the user's change,
  outside this repo.
