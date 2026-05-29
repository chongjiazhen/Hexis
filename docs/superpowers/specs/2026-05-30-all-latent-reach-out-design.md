# All-Latent Reach-Out — Design

**Date:** 2026-05-30
**Status:** Design (approved for plan)
**Supersedes:** the deterministic per-sender cooldown gate shipped in `3c2ffea`
(`feat(heartbeat): per-sender reach-out cooldown + state-merge trigger fix`).
**Related prior art:** `docs/superpowers/specs/2026-05-26-timezone-aware-reach-out-design.md`
(the quiet-hours / timezone gate, `88f6aa2`), whose hard veto this design also dissolves.

## Thesis

Hexis is a personhood experiment: the LLM-backed character *is* the agent, not a
puppet the database disciplines. Reach-out cadence — whether and when a character
DMs a quiet user — should therefore be the **character's own judgment**, not a
mechanical veto applied after the model has already decided.

Today the architecture is *LLM proposes, DB disposes*: the heartbeat emits a
`reach_out_user` action and two deterministic gates (`can_reach_out_sender`,
`is_sender_quiet`) can silently veto it, refund the energy, and drop the message.
This design removes both vetoes. In their place the character is given enough
**awareness** — of its own local time, the user's apparent rhythm, and its own
ignored-streak — to read the room and exercise restraint itself.

The database stops being the impulse-control cop and becomes what it claims to be:
the brain that *informs* the decision, not the cop that overrides it.

## Goals

- A character with an outstanding, un-answered reach-out can still decide *for
  itself* to wait — or to send again — based on context, not a timer.
- Eliminate the "chatterbox" pile-up (the original complaint) via informed latent
  restraint, not a hard cap.
- Give the character genuine temporal awareness: its own local time, and the
  user's likely active hours inferred from observed message times.
- Keep the failure mode observable and reversible (dormant emergency brake +
  decision logging).

## Non-Goals

- No automatic, scheduled, per-sender relationship-decay job. (Investigated:
  relationship strength is a *global* AGE edge, LLM-set, with no decay machinery.
  An emergent, prompt-driven version is in scope; the infra version is not.)
- No learned/persisted per-sender timezone model or active-hours histogram. The
  character infers rhythm by latent reasoning over raw message timestamps.
- No cloud-host self-timezone resolution (local-inference-only mandate; deferred).
- `main` is untouched — upstream maintainers' line. This ships on a private
  local-patch branch.

## Architecture — what changes

### 1. Strip both vetoes — `db/17_functions_subconscious_observations.sql`

In the `reach_out_user` action handler (`execute_heartbeat_action`, ~`:1208`):

- Remove the `can_reach_out_sender` veto branch (~`:1234`).
- Remove the `is_sender_quiet` veto branch (~`:1216`).
- Remove the two `PERFORM update_energy(action_cost)` energy-refund-on-veto lines
  that accompanied them.

Result: when the LLM emits `reach_out_user` and energy is sufficient, the message
is queued. Quiet-hours and prior-silence become *inputs the model saw*, not gates.

### 2. Telemetry survives; role flips — `db/07_functions_heartbeat.sql`

- Keep `record_reach_out_sender`, called on every queued reach-out.
- Delete `can_reach_out_sender` (no longer a gate).
- Retire the `heartbeat.user_contact_cooldown_hours` config as gate semantics.
- Enrich each `reach_out_sender_log` entry from a bare timestamp to a small object:

  ```json
  { "last_at": "<timestamptz>", "unanswered_count": <int> }
  ```

  `unanswered_count` tracks reach-outs the user has not yet answered. The reset is
  computed **inside `record_reach_out_sender`**, deterministically, with no separate
  inbound-message hook: on each reach-out, if `last_user_contact > stored last_at`
  (the user replied since our previous reach-out) the count restarts at 1, else it
  is the stored count + 1. `last_at` is then set to now. This keeps the log a pure
  function of `(prior log entry, last_user_contact, now)`.

  This is now the *signal the LLM reads*, not veto fuel.

### 3. Self temporal awareness — `db/09_functions_context.sql` `get_environment_snapshot`

- Reuse the **existing** `heartbeat.timezone` config (already the agent-default TZ
  consulted by `resolve_sender_timezone`; falls back to UTC). No new key — single
  source of truth. Host is UTC+8 (`Asia/Singapore`).
- Inject alongside the existing UTC `timestamp`:
  - `agent_local_time` = `CURRENT_TIMESTAMP AT TIME ZONE COALESCE(heartbeat.timezone, 'UTC')`
  - `agent_local_hour` = its hour
- The character now knows "it's 2am where I am."

**Known limitation (documented, not solved):** this derives from the container
clock, which drifts on host sleep / GPU power-mode switch (the CLAUDE.local.md
"Docker VM clock drift" PRIMARY gotcha). The character's sense of time is only as
honest as the VM clock. Cloud-host self-timezone is out of scope (local-only
mandate).

### 4. Sender awareness, observational — `db/09_functions_context.sql` `get_active_senders_context`

Keep `local_hour` and `is_quiet` — but as **information**, never a gate. Add, per
active sender:

- `hours_since_my_last_reach_out` (from `reach_out_sender_log.last_at`)
- `unanswered_reach_out_count` (from the log)
- `replied_since` (bool: did the user message after my last reach-out?)
- `recent_user_message_times` — raw timestamps of the user's last N messages
  (the observational substrate for inferring their rhythm)

`replied_since` is computed live (`last_user_contact > last_at`), and the
`unanswered_reach_out_count` shown is reconciled with it — 0 when `replied_since`
is true — so the LLM never sees a stale streak between a user reply and the next
reach-out (the persisted count only reconciles on the next write, §2).

Configured sender timezone (`channel.sender.<id>.timezone`) is surfaced when set;
otherwise the character infers active hours from the raw times. No histogram, no
learning pipeline — latent reasoning does the inference each turn.

### 5. Prompt — `services/prompts/*.md`

Instruct the reach-out/heartbeat decision to weigh: own local time, the user's
apparent rhythm/timezone, the `unanswered_reach_out_count` streak, and the
relationship. Restraint should scale with the ignored-streak. Explicitly license
the character to use the **existing** `update_trust` action to let closeness erode
when persistently ignored — emergent, prompt-driven relationship-decay with zero
new infrastructure.

**Deployment caveat:** prompt files are baked into worker images by
`ops/Dockerfile.worker`, not read per turn (`[[feedback_prompt_files_baked_rebuild_required]]`).
Any prompt edit needs `docker compose ... up -d --no-deps --force-recreate --build`
of the affected workers, verified with an in-container
`grep -c <new_term> /app/services/prompts/...`.

### 6. Emergency brake (dormant) — config

- New config key `heartbeat.reach_out_max_unanswered` (int, **default 0 = off**).
- When `> 0`, a reach-out to a sender whose `unanswered_count >= N` is suppressed
  as a last-resort safety backstop (logged, not silent).
- This is **not** a cadence dial and **not** the cool-off mechanism — it is a
  runaway-loop circuit breaker, dormant unless an experiment goes pathological.

### 7. Observability

Log every reach-out *decision* with the context it saw — the
`unanswered_reach_out_count`, `replied_since`, `agent_local_hour`, recipient
`local_hour` — so the all-latent behavior can be audited and the failure mode
(over-texting loop, cf `[[project_worldsim_rp_loop_diagnosis]]`) is visible rather
than inferred.

## What is explicitly kept

- The `heartbeat_state_update_trigger` non-NULL-merge fix from `3c2ffea` — an
  unrelated, genuine bugfix (partial updates no longer clobber unrelated state
  keys). Stays, and its test stays.
- The `reach_out_sender_log` JSONB column and `record_reach_out_sender` (repurposed
  as telemetry).
- Timezone resolution helpers (`resolve_sender_timezone`, `is_sender_quiet`) — used
  now only to *compute information* for the LLM, not to veto.

## Testing — `tests/db/test_heartbeat_reach_out_sender.py`

The 6 existing tests assert the deterministic veto fires; they are **rewritten** to
assert the new contract:

1. A prior un-answered reach-out does **not** block a subsequent `reach_out_user`.
2. A reach-out during quiet hours is **not** blocked (it queues; quiet status is
   only surfaced as context).
3. `unanswered_count` increments on each reach-out.
4. `unanswered_count` resets to 0 after the user contacts the agent.
5. `get_active_senders_context` exposes the new signal fields
   (`hours_since_my_last_reach_out`, `unanswered_reach_out_count`, `replied_since`).
6. `get_environment_snapshot` exposes `agent_local_time` / `agent_local_hour`.
7. The dormant brake: with `reach_out_max_unanswered = 0`, no suppression; with
   `N > 0` and `unanswered_count >= N`, the reach-out is suppressed and logged.

The `heartbeat_state_update_trigger` merge-fix test is retained unchanged.

## Risk

No hard cool-off floor means a looping or misjudging model **can** over-text. This
is the accepted cost of the personhood experiment. Mitigation is observation
(§7) + the dormant brake (§6), not prevention. Container clock drift (§3) can also
distort the character's time-sense; treated as a known limitation.

## Git / rollout

- Build on a **new branch off `home-rig-local`** (private local-patch line),
  cherry-keeping the `3c2ffea` trigger fix; this design supersedes that commit's
  gate. Not on `main` (upstream).
- DB function changes (`db/07`, `db/09`, `db/17`) propagate live via
  `CREATE OR REPLACE` (no `down -v`). Prompt + worker changes need a worker rebuild
  (§5). Config keys seed via the schema + a live `UPDATE config`.
