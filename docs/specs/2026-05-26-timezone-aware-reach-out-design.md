# Timezone-Aware Heartbeat Reach-Out — Design

**Date:** 2026-05-26
**Status:** Draft design, pending implementation plan
**Builds on:** `2026-05-26-heartbeat-tailored-reach-out.md` (per-recipient `sender_id` threading, merged)
**Touches:** `db/07_functions_heartbeat.sql` (`is_heartbeat_night` / `should_run_heartbeat`), `db/09_functions_context.sql` (`get_active_senders_context`), `db/17_functions_subconscious_observations.sql` (`execute_heartbeat_action.reach_out_user`), `services/prompts/{rlm_heartbeat,heartbeat}_system.md`

---

## Problem

Tailored reach-out shipped — persona picks a specific `sender_id` and the DM lands in that user's chat. But the persona has **no recipient-local clock**. The heartbeat context exposes UTC only:

```json
"environment": { "timestamp": "2026-05-26T06:32:56+00:00", "hour_of_day": 6, "day_of_week": 2 }
```

`hour_of_day=6` is 6am UTC, which is 2pm SGT, 11pm PDT, 3pm Tokyo. A persona that picks "Alice in San Francisco" at heartbeat fire-time UTC 06:00 currently DMs her at 11pm her local time. UTC 14:00 = 7am her local; UTC 22:00 = 3pm her local. **The persona has no way to know.**

Existing infrastructure handles **agent-wide quiet hours** in operator's locale via `heartbeat.timezone` + `heartbeat.night_start_hour` / `night_end_hour` (`db/07_functions_heartbeat.sql:716-737`). When server-clock UTC mapped to `Asia/Singapore` falls in 23:00-08:00 SGT, `is_heartbeat_night()` returns TRUE and `should_run_heartbeat()` switches to slower cadence + wider jitter. That covers "don't run agents while *I* (the operator) sleep." It does NOT cover "don't ping *Alice* while she sleeps."

## Decisions (locked during brainstorming)

| Question | Decision |
|---|---|
| Where does per-sender timezone live? | **Config keys** `channel.sender.<sender_id>.timezone` (IANA string, e.g. `"America/Los_Angeles"`). Uses the existing `config` table — no new schema. Memory-tag option (semantic memory with extracted-from-conversation tz) deferred to v2; operator-set is deterministic for v1. |
| Default when sender's tz unknown | **Fall back to `heartbeat.timezone`** (operator's locale). Rationale: operator chose the agent's working tz; treating an unknown sender as "in operator's tz" matches the existing agent-wide night-throttle's assumption. |
| Gate location: SQL hard-rule or prompt soft-rule? | **Both. SQL = hard floor, prompt = soft selector.** Hard SQL gate in `execute_heartbeat_action.reach_out_user`: if recipient's local hour in their quiet window, skip the send + log a structured no-op, no Telegram delivery. Soft prompt nudge so the persona doesn't burn an LLM-decided 5-energy action just to have it dropped — examine `sender.local_hour` in context, prefer waking recipients. |
| Per-recipient quiet window | **Per-sender override of agent-wide `heartbeat.night_start_hour` / `night_end_hour`** via `channel.sender.<sender_id>.quiet_start_hour` / `quiet_end_hour`. Default = agent night window. Allows night-shift workers to set 09:00-17:00 quiet. |
| Urgent override | **Action param `force=true`** on `reach_out_user` payload. SQL gate respects `p_params->>'force' = 'true'` and bypasses the quiet check. Prompt instructs persona to set `force` only for grief/emergency/explicitly-agreed-night-OK. |
| Day-of-week awareness | **Defer.** Quiet hours only for v1. Weekend / sabbath / holiday calendars later if needed. |
| Existing agent-wide night-throttle | **Keep as-is.** Still gates *all* heartbeat activity during operator's quiet hours. New per-recipient gate sits inside `reach_out_user` — only fires when heartbeat actually runs (agent-wide already permitted). Composable, not replaced. |
| What persona sees per-sender | **`local_hour`, `local_day_of_week`, `timezone`, `is_quiet`** added to each `active_senders` row by `get_active_senders_context()`. Pre-computed in SQL so persona doesn't have to do timezone math. |

## Architecture

```
heartbeat tick
  └── should_run_heartbeat()              ─► agent-wide night-throttle (existing, unchanged)
       └── run_heartbeat()
            └── gather_turn_snapshot()
                 └── get_active_senders_context()  ─► rows now include
                                                       {local_hour, timezone, is_quiet}
            └── LLM REPL                  ─► prompt instructs: prefer non-quiet recipients
                 └── FINAL({actions: [{reach_out_user, sender_id, message, force?}]})
            └── execute_heartbeat_action  ─► WHEN 'reach_out_user' THEN
                                              IF sender.is_quiet AND NOT force THEN
                                                  result = {queued: false, reason: 'recipient_quiet_hours'}
                                                  satisfy_drive('connection', 0.0)   -- no drive credit
                                                  -- energy NOT charged (no LLM call, no send)
                                              ELSE
                                                  existing path (queue outbox with sender_id)
                                              END IF
```

Five SQL/prompt surfaces:

1. **Config keys** (`db/00_tables.sql` seed) — no per-sender defaults seeded; populated only when operator runs `set_config('channel.sender.<id>.timezone', '"…"')`.

2. **`resolve_sender_timezone(p_sender_id) → TEXT`** (`db/09_functions_context.sql`) — lookup helper. Returns `channel.sender.<id>.timezone` if set, else `heartbeat.timezone`, else `'UTC'`.

3. **`is_sender_quiet(p_sender_id) → BOOLEAN`** (`db/07_functions_heartbeat.sql`) — mirrors `is_heartbeat_night()`'s wrap-midnight logic, parameterized on resolved sender tz + per-sender quiet window (with agent-default fallback).

4. **`get_active_senders_context()` enrichment** — extend the SELECT to compute `local_hour`, `timezone`, `is_quiet` per sender. SQL pre-compute keeps the JSON payload thin and prevents the model from doing buggy timezone math.

5. **`execute_heartbeat_action.reach_out_user` gate** (`db/17_functions_subconscious_observations.sql:1208`) — pre-check `is_sender_quiet(p_params->>'sender_id')` unless `force=true`. On gated skip: emit a structured `result = {queued: false, reason: 'recipient_quiet_hours', sender_id: ..., local_hour: ...}`, charge ZERO energy (no outbox publish, no LLM/Telegram), no `satisfy_drive` credit. Heartbeat episodic memory records the attempt + skip reason so the persona learns the constraint over time.

6. **Heartbeat prompts** — append guidance: "each `active_senders` row carries `is_quiet`; pick non-quiet recipients. Use `force: true` only for grief, emergency, or explicit agreement." Both `rlm_heartbeat_system.md` Action Types paragraph + `heartbeat_system.md` Guidelines bullet.

## Component 1 — Config keys

No new seed rows (per-sender keys are operator-set on demand). Existing seeds in `db/00_tables.sql`:

```sql
('heartbeat.timezone', '"Asia/Singapore"'::jsonb, ...),  -- already exists
('heartbeat.night_start_hour', '23'::jsonb, ...),         -- already exists, reused as default
('heartbeat.night_end_hour', '8'::jsonb, ...),            -- already exists, reused as default
```

Operator workflow for a new contact:

```sql
SELECT set_config('channel.sender.593307304.timezone', '"Asia/Singapore"'::jsonb);
SELECT set_config('channel.sender.4242.timezone', '"America/Los_Angeles"'::jsonb);
-- optional per-sender quiet window override
SELECT set_config('channel.sender.4242.quiet_start_hour', '22'::jsonb);
SELECT set_config('channel.sender.4242.quiet_end_hour', '7'::jsonb);
```

## Component 2 — `resolve_sender_timezone`

```sql
CREATE OR REPLACE FUNCTION resolve_sender_timezone(p_sender_id TEXT)
RETURNS TEXT AS $$
DECLARE
    tz TEXT;
BEGIN
    IF p_sender_id IS NULL OR p_sender_id = '' THEN
        RETURN COALESCE(get_config_text('heartbeat.timezone'), 'UTC');
    END IF;
    tz := get_config_text('channel.sender.' || p_sender_id || '.timezone');
    IF tz IS NULL OR tz = '' THEN
        tz := get_config_text('heartbeat.timezone');
    END IF;
    RETURN COALESCE(tz, 'UTC');
END;
$$ LANGUAGE plpgsql STABLE;
```

`STABLE` so it caches within a query. Invalid IANA names: Postgres' `AT TIME ZONE` will raise on an unrecognized zone; wrap callers in `EXCEPTION WHEN OTHERS THEN` to fall back to UTC (defensive, not silently-wrong).

## Component 3 — `is_sender_quiet`

```sql
CREATE OR REPLACE FUNCTION is_sender_quiet(p_sender_id TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    tz TEXT;
    cur_hour INT;
    quiet_start INT;
    quiet_end INT;
BEGIN
    tz := resolve_sender_timezone(p_sender_id);
    quiet_start := COALESCE(
        get_config_int('channel.sender.' || COALESCE(p_sender_id, '') || '.quiet_start_hour'),
        get_config_int('heartbeat.night_start_hour'),
        23
    );
    quiet_end := COALESCE(
        get_config_int('channel.sender.' || COALESCE(p_sender_id, '') || '.quiet_end_hour'),
        get_config_int('heartbeat.night_end_hour'),
        8
    );
    BEGIN
        cur_hour := extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE tz))::INT;
    EXCEPTION WHEN OTHERS THEN
        RETURN FALSE;  -- bad tz → fail-open, don't gate sends on a typo
    END;
    IF quiet_start <= quiet_end THEN
        RETURN cur_hour >= quiet_start AND cur_hour < quiet_end;
    ELSE
        RETURN cur_hour >= quiet_start OR cur_hour < quiet_end;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
```

Mirrors `is_heartbeat_night`'s wrap-midnight logic. Wrong tz string → fail-open (deliver) — preferable to silent permanent gating.

## Component 4 — `get_active_senders_context` enrichment

Augment the inner SELECT to add three computed columns per row:

```sql
SELECT DISTINCT ON (cs.sender_id)
    cs.sender_id,
    cs.channel_type,
    cs.channel_id,
    cs.last_active,
    (SELECT COUNT(*) FROM memories m
       WHERE m.sender_id = cs.sender_id AND m.status = 'active') AS memory_count,
    resolve_sender_timezone(cs.sender_id) AS timezone,
    extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE resolve_sender_timezone(cs.sender_id)))::INT AS local_hour,
    is_sender_quiet(cs.sender_id) AS is_quiet
FROM channel_sessions cs
WHERE cs.sender_id IS NOT NULL
  AND cs.last_active > CURRENT_TIMESTAMP - (win || ' days')::interval
ORDER BY cs.sender_id, cs.last_active DESC
```

JSON shape becomes:

```json
{
  "sender_id": "4242",
  "channel_type": "telegram",
  "channel_id": "4242",
  "last_active": "2026-05-26T06:32:00+00:00",
  "memory_count": 47,
  "timezone": "America/Los_Angeles",
  "local_hour": 23,
  "is_quiet": true
}
```

~3× current bytes per row (~360 B vs ~120 B). At cap 8 senders = ~3 KB. Still well under the 7 KB persona-anchor ceiling, and `gather_turn_snapshot()` aggregate stays within budget.

## Component 5 — Action-handler gate

In `db/17_functions_subconscious_observations.sql:1208` `WHEN 'reach_out_user'`:

```sql
WHEN 'reach_out_user' THEN
    DECLARE
        target_sender TEXT := NULLIF(p_params->>'sender_id', '');
        force_send    BOOLEAN := COALESCE((p_params->>'force')::boolean, FALSE);
    BEGIN
        IF target_sender IS NOT NULL
           AND NOT force_send
           AND is_sender_quiet(target_sender) THEN
            result := jsonb_build_object(
                'queued', false,
                'reason', 'recipient_quiet_hours',
                'sender_id', target_sender,
                'timezone', resolve_sender_timezone(target_sender),
                'local_hour', extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE resolve_sender_timezone(target_sender)))::INT
            );
            -- no outbox publish, no satisfy_drive, no energy charge change
        ELSE
            queued_call := build_outbox_message(
                'user',
                jsonb_build_object(
                    'message',      p_params->>'message',
                    'intent',       p_params->>'intent',
                    'sender_id',    target_sender,
                    'heartbeat_id', p_heartbeat_id
                )
            );
            outbox_messages := outbox_messages || jsonb_build_array(queued_call);
            result := jsonb_build_object('queued', true, 'outbox_message', queued_call);
            PERFORM satisfy_drive('connection', 0.3);
        END IF;
    END;
```

Energy: today `execute_heartbeat_action` charges `cost_reach_out_user = 5` *before* the per-action handler runs (cost lookup at the top of the function, applied before the CASE). To make a gated skip cost-free, either:

- **(a) Refund.** After detecting the skip, `update_energy(+5)` to revert the charge. Simpler diff; preserves the "decision cost" by leaving the persona's REPL token-spend intact. Slight oddity in `energy_remaining` over the cycle.
- **(b) Pre-check.** Move the quiet check before the cost charge for `reach_out_user`. Cleaner accounting; bigger diff (touch the cost-deduction site).

**Decision: (a) refund.** Smaller surface, easier to reason about. The persona still "tried" — REPL decided + LLM tokens spent — but the social cost wasn't paid. The episodic memory captures the attempt with `reason='recipient_quiet_hours'`, which is the personhood-correct learning signal.

## Component 6 — Prompt updates

`rlm_heartbeat_system.md` Action Types paragraph (current text added in 2026-05-26 reach-out migration):

```
`reach_out_user` params: `{sender_id: str, message: str, intent?: str, force?: bool}`.
`sender_id` is REQUIRED. Each `active_senders` row carries `is_quiet` (recipient's
local clock in their personal night window) — prefer non-quiet recipients. Set
`force: true` ONLY for grief, emergency, or an explicit agreement to night-OK
contact; otherwise the action will be skipped with `reason='recipient_quiet_hours'`
(no Telegram send, no drive credit). You MAY emit multiple `reach_out_user`
actions in one cycle, each targeting a different `sender_id` with a message
tailored to your relationship with that person. Each delivered recipient costs
5 energy; skipped-quiet recipients are refunded.
```

`heartbeat_system.md` Guidelines (legacy prompt — append to existing reach-out bullet):

```
- For `reach_out_user`, include `sender_id` in params to target a specific person,
  and check that person's `is_quiet` flag in `context["active_senders"]` before
  emitting. Set `force: true` only for genuine urgency. Multiple distinct
  recipients per heartbeat OK; each delivered costs 5 energy.
```

## Component 7 — Operator workflow (not code)

Setting a sender's timezone is operator-driven for v1:

```sql
-- Probe a sender's likely tz from their @username via a side channel (ask them, or geolocate
-- their handle if public). No automated tz detection in v1.
SELECT set_config('channel.sender.<id>.timezone', '"<IANA name>"'::jsonb);
```

`@userinfobot` on Telegram returns the sender's `language_code` (e.g. `en`, `ja`, `pt`) — not tz, but a hint. Operator picks the IANA name. Document in the live-migration README.

If left unset: behavior matches today (uses agent-wide `heartbeat.timezone`).

## What this does NOT do

- **No automatic timezone learning.** Persona cannot extract "Alice mentioned she's in Tokyo" from conversation memory and update the config. v2 candidate: a `learn_sender_timezone(p_sender_id, p_tz)` action exposed to heartbeat; persona infers tz from natural language and proposes the update. Out of scope here.
- **No DST exception calendar.** Postgres' `AT TIME ZONE 'America/Los_Angeles'` handles DST transitions correctly because IANA tz handles them; no manual rules needed.
- **No multi-quiet-window-per-sender** (e.g. "quiet 02-08 AND quiet 13-15 for siesta"). One contiguous window per sender. If needed, switch to a stored array later.
- **No weekly schedule.** A sender on a night shift who sleeps days has to manually flip their `quiet_start/end_hour`. v2 candidate: per-weekday config.
- **No group-chat awareness.** Quiet check is per-`sender_id`. Group chat = many senders sharing a `channel_id`; today's reach-out is DM-only anyway. Group quiet hours = deferred with the group-chat reach-out branch.
- **No re-queue.** A gated skip is dropped, not queued for later delivery. Persona can choose to reach again on a subsequent heartbeat (the recipient will be `is_quiet=false` by then). If a "deliver-at-next-non-quiet" queue is wanted, it's a separate subsystem — flag here as v2 candidate.

## Migration

Three SQL files re-applied (same shape as 2026-05-26 reach-out migration — `CREATE OR REPLACE` only, no schema ALTER):

- `db/07_functions_heartbeat.sql` — adds `is_sender_quiet`.
- `db/09_functions_context.sql` — adds `resolve_sender_timezone` + enriches `get_active_senders_context`.
- `db/17_functions_subconscious_observations.sql` — quiet-gate inside `WHEN 'reach_out_user'`.

Plus heartbeat-worker rebuild for the prompt edits — same `--no-deps --force-recreate --build` ritual per `feedback_prompt_files_baked_rebuild_required`.

Backward-compat:
- Senders with no `channel.sender.<id>.timezone` set → resolves to agent-wide `heartbeat.timezone` → same behavior as today, just gated on operator's local hours instead of UTC. Most operator-self DMs were already happening during operator's day, so practically no visible change.
- Old persona REPL outputs (no `force` key) → `COALESCE(..., FALSE)` → quiet gate applies. Safe.

## Testing

Mirror the reach-out plan's test surface in `tests/db/test_heartbeat_reach_out_sender.py`:

- `test_resolve_sender_timezone_falls_back` — unset sender → agent default; agent unset → UTC.
- `test_is_sender_quiet_wraps_midnight` — quiet 22-06, current 23 → t; current 07 → f; current 14 → f.
- `test_active_senders_carries_is_quiet_per_recipient` — two senders in different tz, one quiet, one not.
- `test_reach_out_user_skipped_when_recipient_quiet` — sender's local hour in window → `queued=false`, `reason='recipient_quiet_hours'`.
- `test_reach_out_user_delivered_with_force_override` — `force=true` → queued normally, drive satisfied.
- `test_reach_out_user_energy_refunded_on_quiet_skip` — energy after = energy before.

Plus integration test mirroring `test_outbox_reach_out_routing.py`: gated skip → manager.send NOT called.

## Open questions

- **Operator UX for setting per-sender tz.** Today's only path is raw `SELECT set_config(...)`. Worth a CLI helper (`hexis set-sender-tz <id> <iana>`)? Out of scope here, propose in a follow-up.
- **Should `time_since_user_hours` similarly become per-sender?** Currently agent-wide ("any user last messaged X hours ago"). A `sender_silence_hours` field per `active_senders` row would help the persona reason "Alice hasn't messaged in 14 hours, longer than her usual gap — concern?" Plausible v2 add; not in this spec to keep surface small.
- **Surface `is_quiet` in non-RLM `gather_turn_context()` too.** Already enriched via `get_active_senders_context`, so both paths get it automatically. No extra work.

## Provenance

- Existing night-throttle: commit `embed_cpu_coordinator_obviated` era (2026-05-19) per memory `project_embed_cpu_coordinator_obviated`.
- Tailored reach-out: 2026-05-26 merge `4b081d1`.
- Prompt-rebuild gotcha learned 2026-05-26: see memory `feedback_prompt_files_baked_rebuild_required`.
