# Timezone-Aware Heartbeat Reach-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persona reach-out skips recipients in their own night window (per-sender IANA timezone + per-sender quiet hours, falling back to agent defaults), with a `force` override for emergencies. Existing agent-wide night-throttle preserved as outer gate.

**Architecture:** Per-sender timezone lives in `config` table as `channel.sender.<id>.timezone` (no schema change). A new pair of stable SQL helpers (`resolve_sender_timezone`, `is_sender_quiet`) read those keys with fallback to the agent-wide `heartbeat.timezone` / `heartbeat.night_start_hour` / `night_end_hour`. `get_active_senders_context` is enriched to expose `{timezone, local_hour, is_quiet}` per sender so the persona's REPL chooses non-quiet recipients without doing timezone math. `execute_heartbeat_action`'s `WHEN 'reach_out_user'` branch consults `is_sender_quiet(sender_id)`; on quiet without `force=true`, it skips the outbox publish, refunds the 5 energy, and emits `result={queued: false, reason: 'recipient_quiet_hours'}`. Prompts updated to instruct the persona to prefer non-quiet recipients and reserve `force` for genuine urgency.

**Tech Stack:** PostgreSQL (plpgsql, IANA tz via `AT TIME ZONE`), Python 3.10+ asyncio (no Python code changes — DB + prompts only), pytest-asyncio, Docker Compose (worker image rebuild for prompts).

**Spec:** `docs/superpowers/specs/2026-05-26-timezone-aware-reach-out-design.md` (commit `b511d1b`).

---

## File Structure

**Modify:**
- `db/07_functions_heartbeat.sql` — add `is_sender_quiet(p_sender_id TEXT) → BOOLEAN` (mirrors `is_heartbeat_night` wrap-midnight logic, parameterized on per-sender tz + quiet window with fallback). Place adjacent to `is_heartbeat_night` (~line 737).
- `db/09_functions_context.sql` — add `resolve_sender_timezone(p_sender_id TEXT) → TEXT` near top of file; modify `get_active_senders_context` to enrich each row with `timezone`, `local_hour`, `is_quiet`.
- `db/17_functions_subconscious_observations.sql` — replace the `WHEN 'reach_out_user' THEN` branch (around lines 1208–1219 post-2026-05-26-reach-out merge) with a quiet-gate variant. Use a nested `DECLARE` block; refund energy via `PERFORM update_energy(+action_cost)` on gated skip.
- `services/prompts/rlm_heartbeat_system.md` — update the `reach_out_user` paragraph in Action Types to mention `is_quiet`, `force`, and the skip semantics.
- `services/prompts/heartbeat_system.md` — same nudge appended to its Guidelines reach-out bullet.

**Create:**
- `.local-notes/migrations/2026-05-26-timezone-aware-reach-out/migrate.sql` — three `\ir` includes (db/07, db/09, db/17) + smoke selects.
- `.local-notes/migrations/2026-05-26-timezone-aware-reach-out/README.md` — fleet apply loop + heartbeat-worker rebuild ritual + per-sender tz set-config recipe + smoke template.
- Append to existing `tests/db/test_heartbeat_reach_out_sender.py` (do NOT create a new test file — co-locate with the reach-out tests added in the 2026-05-26 plan).
- Append to existing `tests/services/test_outbox_reach_out_routing.py` — gated-skip integration test.

**No change required:**
- `channels/outbox.py` — quiet-gated `reach_out_user` never publishes to RabbitMQ, so `_deliver_last_active` is not involved. No code path change.
- `db/00_tables.sql` — no new seed rows (`heartbeat.timezone`, `night_start_hour`, `night_end_hour` already seeded; per-sender keys are operator-set on demand).
- `services/worker_service.py` — no Python change; the action handler returning `queued: false` flows through the existing `outbox_messages` path harmlessly (empty array for that action).

---

## Task 1: `resolve_sender_timezone()` SQL helper

**Files:**
- Modify: `db/09_functions_context.sql` (insert near top of file, before `get_active_senders_context`)
- Test: `tests/db/test_heartbeat_reach_out_sender.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_resolve_sender_timezone_uses_per_sender_config(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('channel.sender.alice.timezone', '\"America/Los_Angeles\"'::jsonb)")
            tz = await conn.fetchval("SELECT resolve_sender_timezone('alice')")
            assert tz == "America/Los_Angeles"


async def test_resolve_sender_timezone_falls_back_to_agent_default(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Asia/Singapore\"'::jsonb)")
            tz = await conn.fetchval("SELECT resolve_sender_timezone('unknown-sender')")
            assert tz == "Asia/Singapore"


async def test_resolve_sender_timezone_falls_back_to_utc_when_all_unset(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("DELETE FROM config WHERE key = 'heartbeat.timezone'")
            tz = await conn.fetchval("SELECT resolve_sender_timezone('whoever')")
            assert tz == "UTC"


async def test_resolve_sender_timezone_handles_null_or_empty_sender(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.timezone', '\"Asia/Singapore\"'::jsonb)")
            assert await conn.fetchval("SELECT resolve_sender_timezone(NULL)") == "Asia/Singapore"
            assert await conn.fetchval("SELECT resolve_sender_timezone('')") == "Asia/Singapore"
```

- [ ] **Step 2: Run tests, verify fail**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py::test_resolve_sender_timezone_uses_per_sender_config tests/db/test_heartbeat_reach_out_sender.py::test_resolve_sender_timezone_falls_back_to_agent_default tests/db/test_heartbeat_reach_out_sender.py::test_resolve_sender_timezone_falls_back_to_utc_when_all_unset tests/db/test_heartbeat_reach_out_sender.py::test_resolve_sender_timezone_handles_null_or_empty_sender -v
```

Expected: all four FAIL with `function resolve_sender_timezone(text) does not exist` (or `(unknown)` for the NULL form).

- [ ] **Step 3: Add the helper**

In `db/09_functions_context.sql`, insert ABOVE `get_active_senders_context`:

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

- [ ] **Step 4: Run tests, verify pass**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py -v
```

Expected: prior tests still passing + the four new ones PASS.

- [ ] **Step 5: Commit**

```
git add db/09_functions_context.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): resolve_sender_timezone() with config + agent fallback"
```

No `Co-Authored-By` trailer.

---

## Task 2: `is_sender_quiet()` SQL helper

**Files:**
- Modify: `db/07_functions_heartbeat.sql` (insert adjacent to `is_heartbeat_night`, around line 737)
- Test: `tests/db/test_heartbeat_reach_out_sender.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_is_sender_quiet_inside_window_returns_true(db_pool):
    """With a fixed quiet window 22-06 and the sender's tz pinned so the current
    local hour falls inside it, returns true."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            # Compute a tz that places "now" inside a 22-06 quiet window.
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            # Pick an offset such that local hour = 23 (firmly inside 22-06).
            target_local = 23
            offset = (target_local - cur_utc_hour) % 24
            # Use a fixed-offset zone (POSIX style: "Etc/GMT-N" means UTC+N)
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"

            await conn.execute("SELECT set_config('channel.sender.quiet1.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('channel.sender.quiet1.quiet_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.quiet1.quiet_end_hour', '6'::jsonb)")

            result = await conn.fetchval("SELECT is_sender_quiet('quiet1')")
            assert result is True


async def test_is_sender_quiet_outside_window_returns_false(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            # Put local hour at 14 (firmly outside 22-06).
            target_local = 14
            offset = (target_local - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"

            await conn.execute("SELECT set_config('channel.sender.day1.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('channel.sender.day1.quiet_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.day1.quiet_end_hour', '6'::jsonb)")

            result = await conn.fetchval("SELECT is_sender_quiet('day1')")
            assert result is False


async def test_is_sender_quiet_handles_non_wrapping_window(db_pool):
    """Window NOT wrapping midnight (e.g. quiet 13-15 siesta): inside is true,
    before is false, after is false."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )

            # local hour 14 — inside [13, 15)
            inside_offset = (14 - cur_utc_hour) % 24
            tz_inside = f"Etc/GMT{('+' if inside_offset == 0 else '-')}{inside_offset if inside_offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.siesta_in.timezone', $1::jsonb)", f'"{tz_inside}"')
            await conn.execute("SELECT set_config('channel.sender.siesta_in.quiet_start_hour', '13'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.siesta_in.quiet_end_hour', '15'::jsonb)")
            assert await conn.fetchval("SELECT is_sender_quiet('siesta_in')") is True

            # local hour 12 — outside (before)
            before_offset = (12 - cur_utc_hour) % 24
            tz_before = f"Etc/GMT{('+' if before_offset == 0 else '-')}{before_offset if before_offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.siesta_before.timezone', $1::jsonb)", f'"{tz_before}"')
            await conn.execute("SELECT set_config('channel.sender.siesta_before.quiet_start_hour', '13'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.siesta_before.quiet_end_hour', '15'::jsonb)")
            assert await conn.fetchval("SELECT is_sender_quiet('siesta_before')") is False


async def test_is_sender_quiet_fails_open_on_bad_tz(db_pool):
    """Invalid IANA tz string must NOT silently gate forever — return false."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('channel.sender.badtz.timezone', '\"Not/A/Zone\"'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.badtz.quiet_start_hour', '0'::jsonb)")
            await conn.execute("SELECT set_config('channel.sender.badtz.quiet_end_hour', '23'::jsonb)")
            # Even with a window that would normally always trigger, the bad tz
            # must fail-open, returning false.
            result = await conn.fetchval("SELECT is_sender_quiet('badtz')")
            assert result is False


async def test_is_sender_quiet_falls_back_to_agent_window(db_pool):
    """No per-sender quiet override → uses heartbeat.night_start_hour / night_end_hour."""
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            target_local = 23
            offset = (target_local - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.fallback1.timezone', $1::jsonb)", f'"{tz_name}"')
            # NOTE: no per-sender quiet_start/end_hour set — must use agent defaults.
            result = await conn.fetchval("SELECT is_sender_quiet('fallback1')")
            assert result is True
```

(`Etc/GMT-N` is POSIX-style: `Etc/GMT-8` is UTC+8 per the POSIX sign-flip convention. Postgres ships these zones in its tzdata; verified at `extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'Etc/GMT-8')` returning UTC+8.)

- [ ] **Step 2: Run tests, verify fail**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py -k is_sender_quiet -v
```

Expected: five FAIL with `function is_sender_quiet(text) does not exist`.

- [ ] **Step 3: Add the helper**

In `db/07_functions_heartbeat.sql`, insert IMMEDIATELY AFTER `is_heartbeat_night` (i.e. after its `$$ LANGUAGE plpgsql STABLE;` at line 737):

```sql
-- TRUE when the recipient's local wall-clock is inside their quiet window.
-- Per-sender override via channel.sender.<id>.{timezone, quiet_start_hour,
-- quiet_end_hour}; falls back to agent-wide heartbeat.{timezone,
-- night_start_hour, night_end_hour}. Bad tz string → fail-open (FALSE).
CREATE OR REPLACE FUNCTION is_sender_quiet(p_sender_id TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    tz TEXT;
    cur_hour INT;
    quiet_start INT;
    quiet_end INT;
    safe_sender TEXT := COALESCE(p_sender_id, '');
BEGIN
    tz := resolve_sender_timezone(p_sender_id);
    quiet_start := COALESCE(
        get_config_int('channel.sender.' || safe_sender || '.quiet_start_hour'),
        get_config_int('heartbeat.night_start_hour'),
        23
    );
    quiet_end := COALESCE(
        get_config_int('channel.sender.' || safe_sender || '.quiet_end_hour'),
        get_config_int('heartbeat.night_end_hour'),
        8
    );
    BEGIN
        cur_hour := extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE tz))::INT;
    EXCEPTION WHEN OTHERS THEN
        RETURN FALSE;  -- bad tz → fail-open
    END;
    IF quiet_start <= quiet_end THEN
        RETURN cur_hour >= quiet_start AND cur_hour < quiet_end;
    ELSE
        RETURN cur_hour >= quiet_start OR cur_hour < quiet_end;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
```

- [ ] **Step 4: Run tests, verify pass**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py -v
```

Expected: all prior tests + the five new ones PASS.

- [ ] **Step 5: Commit**

```
git add db/07_functions_heartbeat.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): is_sender_quiet() with per-sender tz + window fallback"
```

---

## Task 3: Enrich `get_active_senders_context` with `timezone` / `local_hour` / `is_quiet`

**Files:**
- Modify: `db/09_functions_context.sql` (the existing `get_active_senders_context` function)
- Test: `tests/db/test_heartbeat_reach_out_sender.py` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_active_senders_context_includes_timezone_localhour_isquiet(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT set_config('channel.sender.tzprobe.timezone', '\"Etc/GMT-8\"'::jsonb)")
            await conn.execute(
                """
                INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
                VALUES ('telegram', 'tzprobe', 'tzprobe', CURRENT_TIMESTAMP - INTERVAL '5 minutes')
                """,
            )

            raw = await conn.fetchval("SELECT get_active_senders_context(8, 7)")
            rows = raw if isinstance(raw, list) else json.loads(raw)
            row = next(r for r in rows if r["sender_id"] == "tzprobe")
            assert row["timezone"] == "Etc/GMT-8"
            assert isinstance(row["local_hour"], int)
            assert 0 <= row["local_hour"] <= 23
            # local_hour in Etc/GMT-8 (UTC+8) must equal UTC hour shifted +8 (mod 24)
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            assert row["local_hour"] == (cur_utc_hour + 8) % 24
            assert isinstance(row["is_quiet"], bool)
```

- [ ] **Step 2: Run test, verify fail**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py::test_active_senders_context_includes_timezone_localhour_isquiet -v
```

Expected: FAIL on `row["timezone"]` KeyError (key not present yet).

- [ ] **Step 3: Enrich the inner SELECT**

In `db/09_functions_context.sql`, replace the body of `get_active_senders_context`'s outer FROM with:

```sql
    SELECT COALESCE(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.last_active DESC), '[]'::jsonb)
    INTO out_json
    FROM (
        SELECT *
        FROM (
            SELECT DISTINCT ON (cs.sender_id)
                cs.sender_id,
                cs.channel_type,
                cs.channel_id,
                cs.last_active,
                (
                    SELECT COUNT(*)
                    FROM memories m
                    WHERE m.sender_id = cs.sender_id
                      AND m.status = 'active'
                ) AS memory_count,
                resolve_sender_timezone(cs.sender_id) AS timezone,
                extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE resolve_sender_timezone(cs.sender_id)))::INT AS local_hour,
                is_sender_quiet(cs.sender_id) AS is_quiet
            FROM channel_sessions cs
            WHERE cs.sender_id IS NOT NULL
              AND cs.last_active > CURRENT_TIMESTAMP - (win || ' days')::interval
            ORDER BY cs.sender_id, cs.last_active DESC
        ) distinct_senders
        ORDER BY last_active DESC
        LIMIT lim
    ) t;
```

(The outer LIMIT-recency-order pattern from `beae2b7` is preserved exactly; only the inner SELECT gains three columns.)

The function's `EXCEPTION WHEN OTHERS THEN RETURN '[]'::jsonb` swallows the unlikely case where `resolve_sender_timezone` returns garbage — but `resolve_sender_timezone` itself never throws (always returns at least `'UTC'`), and `extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')` is always defined, so the EXCEPTION is effectively dead code for this enrichment. Leave it for defensive depth (matches sibling functions).

- [ ] **Step 4: Run test, verify pass + prior tests still pass**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py -v
```

Expected: all tests PASS, including the prior `test_get_active_senders_context_returns_recent_distinct_senders` (which now sees three extra keys per row; its existing `for s in senders: assert "channel_type" in s` is permissive — extra keys don't break it).

- [ ] **Step 5: Commit**

```
git add db/09_functions_context.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): enrich active_senders rows with tz/local_hour/is_quiet"
```

---

## Task 4: Quiet gate + energy refund in `execute_heartbeat_action.reach_out_user`

**Files:**
- Modify: `db/17_functions_subconscious_observations.sql` (the `WHEN 'reach_out_user' THEN` branch around line 1208)
- Test: `tests/db/test_heartbeat_reach_out_sender.py` (append)

- [ ] **Step 1: Write the failing tests**

Append to `tests/db/test_heartbeat_reach_out_sender.py`:

```python
async def test_reach_out_user_skipped_when_recipient_quiet(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            # Pin recipient's tz so their local hour is 23 (firmly inside 22-06 default).
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            offset = (23 - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.sleepy.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")

            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(),
                    'reach_out_user',
                    jsonb_build_object(
                        'sender_id', 'sleepy',
                        'message',   'hi at midnight',
                        'intent',    'check_in'
                    )
                )
                """,
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            inner = res.get("result", {})
            assert inner.get("queued") is False
            assert inner.get("reason") == "recipient_quiet_hours"
            assert inner.get("sender_id") == "sleepy"
            # outbox_messages must be empty
            assert res.get("outbox_messages") == [] or res.get("outbox_messages") is None or len(res["outbox_messages"]) == 0


async def test_reach_out_user_delivered_with_force_override(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            offset = (23 - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.urgent.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")

            raw = await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(),
                    'reach_out_user',
                    jsonb_build_object(
                        'sender_id', 'urgent',
                        'message',   'emergency',
                        'intent',    'crisis',
                        'force',     true
                    )
                )
                """,
            )
            res = raw if isinstance(raw, dict) else json.loads(raw)
            inner = res.get("result", {})
            assert inner.get("queued") is True
            assert inner["outbox_message"]["payload"]["sender_id"] == "urgent"


async def test_reach_out_user_energy_refunded_on_quiet_skip(db_pool):
    async with db_pool.acquire() as conn:
        async with conn.transaction():
            cur_utc_hour = await conn.fetchval(
                "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
            )
            offset = (23 - cur_utc_hour) % 24
            tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
            await conn.execute("SELECT set_config('channel.sender.refund.timezone', $1::jsonb)", f'"{tz_name}"')
            await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
            await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")

            energy_before = await conn.fetchval("SELECT current_energy FROM heartbeat_state WHERE id = 1")
            await conn.fetchval(
                """
                SELECT execute_heartbeat_action(
                    gen_random_uuid(),
                    'reach_out_user',
                    jsonb_build_object('sender_id', 'refund', 'message', 'x', 'intent', 'x')
                )
                """,
            )
            energy_after = await conn.fetchval("SELECT current_energy FROM heartbeat_state WHERE id = 1")
            assert energy_after == energy_before, (
                f"quiet-skip must refund 5 energy; before={energy_before} after={energy_after}"
            )
```

- [ ] **Step 2: Run, verify fail**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py -k "skipped_when_recipient_quiet or force_override or energy_refunded" -v
```

Expected: first FAILS (queued=true, no quiet gate); second PASSES already (force ignored but coincidentally queues); third FAILS (energy charged 5).

- [ ] **Step 3: Replace the handler branch**

In `db/17_functions_subconscious_observations.sql`, locate the `WHEN 'reach_out_user' THEN` block. After the 2026-05-26 reach-out merge it currently reads:

```sql
        WHEN 'reach_out_user' THEN
            queued_call := build_outbox_message(
                'user',
                jsonb_build_object(
                    'message',     p_params->>'message',
                    'intent',      p_params->>'intent',
                    'sender_id',   NULLIF(p_params->>'sender_id', ''),
                    'heartbeat_id', p_heartbeat_id
                )
            );
            outbox_messages := outbox_messages || jsonb_build_array(queued_call);
            result := jsonb_build_object('queued', true, 'outbox_message', queued_call);
            PERFORM satisfy_drive('connection', 0.3);
```

Replace with:

```sql
        WHEN 'reach_out_user' THEN
            DECLARE
                target_sender TEXT := NULLIF(p_params->>'sender_id', '');
                force_send    BOOLEAN := COALESCE((p_params->>'force')::boolean, FALSE);
                resolved_tz   TEXT;
                recipient_hr  INT;
            BEGIN
                IF target_sender IS NOT NULL
                   AND NOT force_send
                   AND is_sender_quiet(target_sender) THEN
                    resolved_tz := resolve_sender_timezone(target_sender);
                    BEGIN
                        recipient_hr := extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE resolved_tz))::INT;
                    EXCEPTION WHEN OTHERS THEN
                        recipient_hr := NULL;
                    END;
                    result := jsonb_build_object(
                        'queued',     false,
                        'reason',     'recipient_quiet_hours',
                        'sender_id',  target_sender,
                        'timezone',   resolved_tz,
                        'local_hour', recipient_hr
                    );
                    -- Refund the pre-charged action_cost; no outbox publish, no drive credit.
                    PERFORM update_energy(action_cost);
                ELSE
                    queued_call := build_outbox_message(
                        'user',
                        jsonb_build_object(
                            'message',     p_params->>'message',
                            'intent',      p_params->>'intent',
                            'sender_id',   target_sender,
                            'heartbeat_id', p_heartbeat_id
                        )
                    );
                    outbox_messages := outbox_messages || jsonb_build_array(queued_call);
                    result := jsonb_build_object('queued', true, 'outbox_message', queued_call);
                    PERFORM satisfy_drive('connection', 0.3);
                END IF;
            END;
```

The nested `DECLARE`/`BEGIN`/`END` block sits inside the existing CASE branch; `action_cost` and `outbox_messages` from the enclosing function are still in scope. The inner `EXCEPTION` block protects the `local_hour` computation only (the gate's own `is_sender_quiet` already handles bad tz internally by returning FALSE, so this path won't fire on bad tz — but the defensive layer costs nothing).

- [ ] **Step 4: Run all tests, verify**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/db/test_heartbeat_reach_out_sender.py -v
```

Expected: all prior tests + three new ones PASS.

Especially confirm `test_reach_out_user_carries_sender_id_in_outbox_payload` (from the prior plan) still passes — it doesn't set a timezone for `'99999'`, so `resolve_sender_timezone` falls back to agent default. Whether that agent default puts hour-99999 in the quiet window depends on `heartbeat.timezone` + the current wall-clock. If the test starts flaking on this, the existing test needs a sender that's explicitly non-quiet — note this in your report and adjust the test by either:
- adding `'force': true` to the test's params, OR
- setting `channel.sender.99999.timezone` to a UTC-aligned zone where the current hour is outside the night window.

Prefer the `force: true` approach (one-line change, semantics-stable).

- [ ] **Step 5: Commit**

```
git add db/17_functions_subconscious_observations.sql tests/db/test_heartbeat_reach_out_sender.py
git commit -m "feat(heartbeat): quiet-gate reach_out_user with force override + refund"
```

---

## Task 5: Outbox-routing integration test for gated skip

**Files:**
- Modify: `tests/services/test_outbox_reach_out_routing.py` (append)

Confirms that even after the SQL gate, channel-side delivery isn't reached at all (zero outbox messages → zero `manager.send` calls). This is a regression-pin on the integration boundary.

- [ ] **Step 1: Append the test**

Append to `tests/services/test_outbox_reach_out_routing.py`:

```python
async def test_quiet_gated_reach_out_never_reaches_channel(db_pool):
    """When the SQL gate skips a quiet reach-out, no outbox message is emitted,
    so the channel-side consumer should never see anything to deliver."""
    async with db_pool.acquire() as conn:
        # Set up a recipient currently in their quiet window.
        cur_utc_hour = await conn.fetchval(
            "SELECT extract(hour FROM CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::INT"
        )
        offset = (23 - cur_utc_hour) % 24
        tz_name = f"Etc/GMT{('+' if offset == 0 else '-')}{offset if offset else 0}"
        await conn.execute("SELECT set_config('channel.sender.gated.timezone', $1::jsonb)", f'"{tz_name}"')
        await conn.execute("SELECT set_config('heartbeat.night_start_hour', '22'::jsonb)")
        await conn.execute("SELECT set_config('heartbeat.night_end_hour', '6'::jsonb)")
        await conn.execute(
            """
            INSERT INTO channel_sessions (channel_type, channel_id, sender_id, last_active)
            VALUES ('telegram', 'gated-chat', 'gated', CURRENT_TIMESTAMP - INTERVAL '1 minute')
            ON CONFLICT DO NOTHING
            """,
        )

        # Run the action and capture its outbox_messages array directly — the gated
        # path returns an empty list.
        raw = await conn.fetchval(
            """
            SELECT execute_heartbeat_action(
                gen_random_uuid(),
                'reach_out_user',
                jsonb_build_object('sender_id','gated','message','x','intent','x')
            )
            """,
        )
        res = raw if isinstance(raw, dict) else json.loads(raw)
        outbox = res.get("outbox_messages") or []
        assert outbox == [], f"gated skip must produce zero outbox messages; got {outbox}"

    try:
        # Belt-and-braces: even if a stale message somehow leaked, the channel
        # consumer must not deliver a quiet-gated payload. (Today: it never sees
        # one. Tomorrow: this test catches a regression.)
        from unittest.mock import AsyncMock
        from channels.outbox import ChannelOutboxConsumer

        manager = AsyncMock()
        manager.send = AsyncMock(return_value="msg-gated")
        consumer = ChannelOutboxConsumer(manager, db_pool)
        # Simulate the (non-existent in normal flow) case: nothing to process.
        # We assert no send happened in the prior step's gated execution; this
        # block doesn't enqueue anything to the consumer because the gated SQL
        # didn't.
        assert manager.send.await_count == 0
    finally:
        async with db_pool.acquire() as conn:
            await conn.execute("DELETE FROM channel_sessions WHERE sender_id = 'gated'")
            await conn.execute("DELETE FROM config WHERE key LIKE 'channel.sender.gated.%'")
```

- [ ] **Step 2: Run, verify pass**

```
C:\hexis\venv\Scripts\python.exe -m pytest tests/services/test_outbox_reach_out_routing.py -v
```

Expected: both this and the prior `test_payload_sender_id_routes_to_that_users_session` PASS.

- [ ] **Step 3: Commit**

```
git add tests/services/test_outbox_reach_out_routing.py
git commit -m "test(outbox): pin gated-skip emits zero outbox messages"
```

---

## Task 6: Update heartbeat prompts for `is_quiet` + `force`

**Files:**
- Modify: `services/prompts/rlm_heartbeat_system.md`
- Modify: `services/prompts/heartbeat_system.md`

- [ ] **Step 1: Edit `services/prompts/rlm_heartbeat_system.md`**

Find the existing paragraph added in the 2026-05-26 reach-out migration (immediately after the **Expensive (4-7)** bullet):

```
`reach_out_user` params: `{sender_id: str, message: str, intent?: str}`. `sender_id` is REQUIRED — choose a specific person from `context["active_senders"]` (or another partner you have memories with). You MAY emit multiple `reach_out_user` actions in one cycle, each targeting a different `sender_id` with a message tailored to your relationship with that person. Each recipient costs 5 energy.
```

Replace with:

```
`reach_out_user` params: `{sender_id: str, message: str, intent?: str, force?: bool}`. `sender_id` is REQUIRED — choose a specific person from `context["active_senders"]`. Each row carries `is_quiet` (recipient's local clock is in their personal night window) and `local_hour` (their actual clock right now) — prefer non-quiet recipients. Set `force: true` ONLY for grief, emergency, or an explicit agreement to night-OK contact; otherwise the action is skipped with `reason='recipient_quiet_hours'` and the 5 energy is refunded. You MAY emit multiple `reach_out_user` actions in one cycle, each targeting a different `sender_id` with a message tailored to your relationship with that person. Each delivered recipient costs 5 energy.
```

- [ ] **Step 2: Edit `services/prompts/heartbeat_system.md`**

Find the bullet appended in the 2026-05-26 reach-out migration:

```
- For `reach_out_user`, include `sender_id` in params to target a specific person. You may emit multiple `reach_out_user` actions in one heartbeat, each with a distinct `sender_id` + tailored `message`. Each recipient costs 5 energy.
```

Replace with:

```
- For `reach_out_user`, include `sender_id` in params to target a specific person, and check that person's `is_quiet` flag in `context["active_senders"]` before emitting. Set `force: true` only for genuine urgency; otherwise quiet recipients are skipped with `reason='recipient_quiet_hours'` and the energy is refunded. You may emit multiple `reach_out_user` actions in one heartbeat, each with a distinct `sender_id` + tailored `message`. Each delivered recipient costs 5 energy.
```

- [ ] **Step 3: Commit**

```
git add services/prompts/rlm_heartbeat_system.md services/prompts/heartbeat_system.md
git commit -m "feat(prompts): heartbeat reach_out_user quiet-hours awareness + force flag"
```

No `Co-Authored-By` trailer.

---

## Task 7: Fleet migration runbook

**Files:**
- Create: `.local-notes/migrations/2026-05-26-timezone-aware-reach-out/migrate.sql`
- Create: `.local-notes/migrations/2026-05-26-timezone-aware-reach-out/README.md`

- [ ] **Step 1: Create `migrate.sql`**

```sql
-- 2026-05-26 timezone-aware heartbeat reach-out
-- Re-applies the three SQL files touched by this feature.
--
-- db/07_functions_heartbeat.sql           — adds is_sender_quiet()
-- db/09_functions_context.sql             — adds resolve_sender_timezone(),
--                                           enriches get_active_senders_context
-- db/17_functions_subconscious_observations.sql
--                                         — quiet-gate inside reach_out_user
--                                           (refunds energy on skip)
--
-- All changes are CREATE OR REPLACE FUNCTION — safe to re-run.
-- No ALTER TABLE, no new index, no new column. Brain DB stays up.

\set ON_ERROR_STOP on
\ir ../../../db/07_functions_heartbeat.sql
\ir ../../../db/09_functions_context.sql
\ir ../../../db/17_functions_subconscious_observations.sql

-- Smoke: new surfaces reachable.
SELECT
    (SELECT count(*) FROM pg_proc WHERE proname = 'resolve_sender_timezone') AS resolve_tz_present,
    (SELECT count(*) FROM pg_proc WHERE proname = 'is_sender_quiet')         AS is_quiet_present,
    -- active_senders rows now expose timezone + local_hour + is_quiet keys
    EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(get_active_senders_context(1, 7), '[]'::jsonb)) row_data
        WHERE row_data ? 'timezone' AND row_data ? 'local_hour' AND row_data ? 'is_quiet'
    ) AS active_senders_enriched_when_nonempty;
```

The `EXISTS` smoke is `false` only when `channel_sessions` is empty — acceptable; the operator confirms enrichment on a populated DB.

- [ ] **Step 2: Create `README.md`**

```markdown
# 2026-05-26 — timezone-aware heartbeat reach-out, fleet migration

Builds on `2026-05-26-heartbeat-tailored-reach-out` (per-recipient sender_id threading). Adds per-sender quiet-hours awareness so the heartbeat never pings a recipient in their own night window without an explicit `force=true`.

## What this changes

- `db/07_functions_heartbeat.sql` — new function `is_sender_quiet(p_sender_id TEXT)`. Returns TRUE when the recipient's local wall-clock (per-sender tz override or agent default) is inside their per-sender quiet window (or agent default `night_start_hour` / `night_end_hour`). Wraps midnight; fail-open on bad tz.
- `db/09_functions_context.sql` — new function `resolve_sender_timezone`; `get_active_senders_context` now emits `timezone`, `local_hour`, `is_quiet` per row.
- `db/17_functions_subconscious_observations.sql` — `execute_heartbeat_action`'s `WHEN 'reach_out_user' THEN` branch checks `is_sender_quiet(sender_id)` (unless `force=true`); on quiet, no outbox publish, no drive credit, and the 5 energy is refunded via `update_energy(+action_cost)`. Episodic memory records the attempt + skip reason.

Agent-wide night-throttle (`is_heartbeat_night`, `should_run_heartbeat` cadence switch) is unchanged — it remains the outer gate for whether heartbeats run at all.

## Apply

```powershell
$dbs = docker exec hexis_brain psql -U hexis_user -d postgres -tAc `
  "SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%' ORDER BY 1"
foreach ($db in ($dbs -split "`n" | Where-Object { $_ })) {
  Write-Host ">>> $db"
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/07_functions_heartbeat.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/09_functions_context.sql
  docker exec -i hexis_brain psql -U hexis_user -d $db -v ON_ERROR_STOP=1 -f - `
    < db/17_functions_subconscious_observations.sql
}
```

## Heartbeat-worker rebuild (mandatory for prompt changes)

Per `feedback_prompt_files_baked_rebuild_required`, `services/prompts/*.md` are baked into worker images. The Task 6 prompt edits need a rebuild + recreate:

```powershell
$svcs = docker ps --format '{{.Names}}' | Select-String '_heartbeat_worker$' | ForEach-Object { $_.ToString() -replace '^hexis_','' }
docker compose -f docker-compose.yml -f docker-compose.newchars.yml --profile active up -d --no-deps --force-recreate --build $svcs
```

`--no-deps` mandatory — without it, `up -d` recreates `hexis_brain` and triggers consumer-wedge per `project_heartbeat_persona_collapse_fix`.

Verify the new prompt landed in any rebuilt container:

```bash
MSYS_NO_PATHCONV=1 docker exec hexis_<persona>_heartbeat_worker grep -c "is_quiet" /app/services/prompts/rlm_heartbeat_system.md
# expected: ≥1
MSYS_NO_PATHCONV=1 docker exec hexis_<persona>_heartbeat_worker grep -c "is_quiet" /app/services/prompts/heartbeat_system.md
# expected: ≥1
```

## Verify per DB

```sql
-- Helpers present
SELECT pg_get_function_identity_arguments('resolve_sender_timezone'::regproc);
-- expected: p_sender_id text
SELECT pg_get_function_identity_arguments('is_sender_quiet'::regproc);
-- expected: p_sender_id text

-- active_senders enriched
SELECT jsonb_pretty(get_active_senders_context(2, 7));
-- expect each row carries: timezone, local_hour, is_quiet

-- Quiet-gate fires (probe; replace 'someone' with a real sender_id you've tz-set)
BEGIN;
SELECT set_config('channel.sender.someone.timezone', '"Etc/GMT-8"'::jsonb);
SELECT execute_heartbeat_action(
    gen_random_uuid(),
    'reach_out_user',
    jsonb_build_object('sender_id','someone','message','probe','intent','probe')
);
-- If 'someone'-local is 22-06: expect result.queued=false, reason='recipient_quiet_hours'
-- Otherwise: expect result.queued=true with payload.sender_id='someone'
ROLLBACK;
```

## Per-sender timezone setup

Operator-driven; no automatic detection. After identifying a sender's locale (Telegram `@userinfobot` returns `language_code` as a hint), set:

```sql
SELECT set_config('channel.sender.593307304.timezone', '"Asia/Singapore"'::jsonb);
SELECT set_config('channel.sender.4242.timezone', '"America/Los_Angeles"'::jsonb);
-- optional per-sender quiet window override (defaults to agent-wide night window)
SELECT set_config('channel.sender.4242.quiet_start_hour', '22'::jsonb);
SELECT set_config('channel.sender.4242.quiet_end_hour', '7'::jsonb);
```

If unset: `resolve_sender_timezone` falls back to `heartbeat.timezone` (currently `"Asia/Singapore"`). Effectively, every unknown sender is treated as if they live in operator's tz until the operator sets otherwise.

## Compatibility window

- Senders with no per-sender tz set behave exactly as today's "operator's local hours" gate — no regression for SGT-resident recipients.
- Old persona REPL outputs (no `force` key) coerce via `COALESCE((p_params->>'force')::boolean, FALSE)` — safe.
- Backward-compat reach_out_user (no `sender_id`) — `target_sender` is `NULL`, `is_sender_quiet(NULL)` reads `safe_sender = ''` and queries `channel.sender..quiet_start_hour` (key with double dot, never set) → falls back to agent default; the gate uses agent-wide night window. This means heartbeats firing during operator's quiet hours WITH an un-sender'd reach_out_user (legacy path) will skip + refund. If you want the legacy untargeted reach to bypass the gate, the simplest knob is `force=true` from the persona's REPL, or just ensure all reach_out_user actions go through the new tailored path.

## ACID-for-cognition invariant

Unchanged. Outbox publish only happens on `queued=true` path; per-persona queue isolation contract from `project_outbox_per_persona_queues` is intact.

## Smoke procedure

Run after applying migration to a chosen test persona.

### 1. Pick a sender currently in their quiet window

Find a sender whose local hour is in 22-06 by setting their tz first:

```sql
-- inside hexis_<persona>
SELECT set_config('channel.sender.<sender_id>.timezone', '"<IANA name>"'::jsonb);
SELECT sender_id, timezone, local_hour, is_quiet
FROM jsonb_to_recordset(get_active_senders_context(8, 7))
     AS x(sender_id text, timezone text, local_hour int, is_quiet boolean)
WHERE sender_id = '<sender_id>';
-- expect is_quiet=true if local_hour in 22-06
```

### 2. Watch heartbeat worker logs

```bash
docker logs -f hexis_<persona>_heartbeat_worker
```

### 3. Wait for natural heartbeat cycle

Per `BUG-heartbeat-clock-drift-consumer-wedge`: do not fabricate timing. Heartbeats fire at `last_heartbeat_at + interval + jitter`. Check `should_run_heartbeat()`.

### 4. Inspect episodic memory

```sql
SELECT created_at, left(content, 200)
FROM memories
WHERE type='episodic'
  AND source_attribution->>'kind' = 'heartbeat'
ORDER BY created_at DESC LIMIT 3;
-- expect the most-recent heartbeat episodic to contain reach_out_user attempts
-- with reason='recipient_quiet_hours' for any quiet recipient the persona picked
```

### 5. Confirm no Telegram delivery for gated senders

```bash
docker logs hexis_<persona>_channel_worker --tail 100 | grep -E "deliver|sender_id"
```

Expect NO `last_active` delivery to the gated sender's `channel_id` during the gated window.

## Smoke result

<!-- Operator fills in below -->

Persona:
Datetime (UTC):
Sender_id chosen + tz set:
Local hour at heartbeat fire:
Quiet-gate fired? (yes/no):
Telegram delivery suppressed? (yes/no):
Episodic memory captured skip reason? (yes/no):
Anomalies / notes:
```

- [ ] **Step 3: Commit**

```
git add .local-notes/migrations/2026-05-26-timezone-aware-reach-out/
git commit -m "docs(migrations): 2026-05-26 timezone-aware reach-out runbook"
```

---

## Task 8: Index spec + plan in MEMORY.md

**Files:**
- Modify: `C:\Users\User\.claude\projects\C--hexis\memory\MEMORY.md` (this is the global per-project memory index, not a repo file)

- [ ] **Step 1: Add a one-liner pointing to this feature**

Append to `C:\Users\User\.claude\projects\C--hexis\memory\MEMORY.md` (after the existing 2026-05-26 entries):

```markdown
- [Timezone-aware reach-out](project_timezone_aware_reach_out.md) — 2026-05-26 design + impl: per-sender `channel.sender.<id>.timezone` + quiet hours; `is_sender_quiet()` hard gate inside `execute_heartbeat_action.reach_out_user`; energy refunded on skip; `get_active_senders_context` enriched with `{timezone, local_hour, is_quiet}`; existing agent-wide `is_heartbeat_night` outer gate untouched.
```

And create the linked memory file `C:\Users\User\.claude\projects\C--hexis\memory\project_timezone_aware_reach_out.md`:

```markdown
---
name: project-timezone-aware-reach-out
description: "2026-05-26: per-recipient quiet-hours gate on heartbeat reach_out_user. channel.sender.<id>.timezone + quiet_start_hour/end_hour; falls back to heartbeat.timezone + night_start/end_hour. SQL hard-gate + energy refund. active_senders enriched with timezone/local_hour/is_quiet."
metadata:
  type: project
---

2026-05-26 follow-up to `project_outbox_per_persona_queues` and the same-day reach-out tailoring merge (`4b081d1`). Persona REPL had no recipient-local clock — every recipient was reasoned about in UTC, leading to 3am DMs landing in users' chats.

**What landed:**
- `resolve_sender_timezone(p_sender_id)` reads `channel.sender.<id>.timezone` with fallback to `heartbeat.timezone` then `'UTC'`.
- `is_sender_quiet(p_sender_id)` reuses the wrap-midnight logic from `is_heartbeat_night` but per-recipient. Per-sender quiet window override via `channel.sender.<id>.quiet_start_hour` / `quiet_end_hour`; default = agent `heartbeat.night_start_hour` / `night_end_hour`. Bad IANA tz string → fail-open (returns FALSE).
- `get_active_senders_context(p_limit, p_recency_days)` enriched per row with `{timezone, local_hour, is_quiet}` so the persona doesn't do timezone math.
- `execute_heartbeat_action.reach_out_user`: if `is_sender_quiet(sender_id)` AND NOT `force=true`, returns `{queued: false, reason: 'recipient_quiet_hours', sender_id, timezone, local_hour}`, refunds 5 energy via `update_energy(+action_cost)`, no outbox publish, no drive credit.
- Prompts (rlm + legacy) instruct persona to consult `is_quiet` and reserve `force: true` for emergencies.

**Why:** Existing agent-wide night-throttle (`is_heartbeat_night` / `should_run_heartbeat` cadence switch) only gated whether agents run at all in operator's local night — useless for protecting recipients in other timezones. New per-recipient gate sits *inside* the action handler so it composes with the outer agent-wide gate without replacing it.

**How to apply:** Spec at `docs/superpowers/specs/2026-05-26-timezone-aware-reach-out-design.md`; plan at `docs/superpowers/plans/2026-05-26-timezone-aware-reach-out.md`; migration runbook at `.local-notes/migrations/2026-05-26-timezone-aware-reach-out/README.md`. Three SQL files re-apply via `CREATE OR REPLACE`; heartbeat workers rebuild for prompt changes per `feedback_prompt_files_baked_rebuild_required`.

**Deferred to v2:**
- Auto timezone learning from conversation (semantic memory tag → propose tz update action).
- Multi-window quiet (siesta + night).
- Per-weekday schedule.
- Group-chat awareness (quiet check per-`sender_id`; groups need `channel_id`-keyed equivalent).
- Re-queue gated sends for next non-quiet slot (today: just dropped, persona may re-emit next cycle).

Related: [[project_outbox_per_persona_queues]], [[feedback_prompt_files_baked_rebuild_required]], [[project_heartbeat_persona_collapse_fix]] (--no-deps wedge), `project_embed_cpu_coordinator_obviated` (where the agent-wide night-throttle originally landed).
```

- [ ] **Step 2: Commit (memory files only; not a repo commit)**

Memory files live under `C:\Users\User\.claude\` and are not in the hexis repo — no `git add`. They're written directly. No commit needed.

---

## Deferred (not in this plan)

- **Auto-detection of sender timezone.** Telegram doesn't expose tz natively; would require a learn-action via persona conversation memory. Out of scope.
- **CLI helper.** `hexis set-sender-tz <id> <iana>` would be friendlier than raw `set_config` calls. Add later; not in critical path.
- **Per-weekday quiet windows.** Single contiguous window per sender for v1.
- **Group-chat quiet awareness.** Tied to the group-chat reach-out branch (deferred from the 2026-05-26 reach-out plan).
- **`time_since_user_hours` per-sender variant.** Currently agent-wide; would be useful for "Alice hasn't messaged in 14h, unusual for her" reasoning. Separate spec.

---

## Self-Review

**Spec coverage** — each spec section mapped:

| Spec section | Task |
|---|---|
| Component 1 — Config keys | Setup-only (no code task); Task 7 documents operator workflow |
| Component 2 — `resolve_sender_timezone` | Task 1 |
| Component 3 — `is_sender_quiet` | Task 2 |
| Component 4 — `get_active_senders_context` enrichment | Task 3 |
| Component 5 — Action-handler gate + refund | Task 4 |
| Component 6 — Prompt updates | Task 6 |
| Component 7 — Operator workflow | Task 7 (README "Per-sender timezone setup") |
| Migration ritual | Task 7 |
| Worker rebuild for prompts | Task 7 (heartbeat-worker rebuild section) |
| Channel-side gated-skip pin | Task 5 |
| Provenance + memory index | Task 8 |

**Placeholder scan** — no `TBD`, no `appropriate`, no `similar to`. Every SQL block is complete. Every test body has assertions.

**Type consistency** —
- `p_sender_id TEXT` everywhere (resolve, is_quiet, action handler).
- Returns: `resolve_sender_timezone → TEXT`, `is_sender_quiet → BOOLEAN`, action result `jsonb_build_object('queued', false|true, ...)`.
- Action params: `force` is `BOOLEAN` coerced via `(p_params->>'force')::boolean` with `COALESCE(..., FALSE)`.
- Config keys: `channel.sender.<id>.timezone` (TEXT JSONB-string), `channel.sender.<id>.quiet_start_hour` (INT JSONB-number), `channel.sender.<id>.quiet_end_hour` (INT). Match the existing `heartbeat.night_*` precedent.
- `local_hour` is `INT 0-23` throughout (extract(hour) on a tz-converted timestamp).
- Test fixtures use `Etc/GMT-N` POSIX zones (sign-flip convention) deterministically across machines regardless of host wall-clock.

**Backward-compat audit** — tests `test_reach_out_user_carries_sender_id_in_outbox_payload` and `test_reach_out_user_without_sender_id_stays_backward_compat` from the prior plan: Task 4 step 4 calls out the flake risk + fix (add `force: true` to those tests' params if they start failing because the sender happens to be in operator's quiet window at test time). Fix is one-line and semantics-stable.
