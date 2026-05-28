# Heartbeat System (Autonomous Loop)

The heartbeat is the agent's conscious cognitive loop:

1. **Initialize** — Regenerate energy (+10/hour, max 20)
2. **Observe** — Check environment, pending events, user presence
3. **Orient** — Review goals, gather context (memories, clusters, identity, worldview)
4. **Decide** — LLM call with action budget and context
5. **Act** — Execute chosen actions within energy budget
6. **Record** — Store heartbeat as episodic memory
7. **Wait** — Sleep until next heartbeat

**Action costs**: Free (observe, remember) → Cheap (recall: 1, reflect: 2) → Expensive (reach out: 5-7)

## Heartbeat liveness (verify autonomous loop ACTUALLY runs)

Ground truth = `heartbeat_state` table per `hexis_<P>` DB (NOT config keys):
`cnt`/`heartbeat_count`, `last_heartbeat_at`, `next_heartbeat_at`,
`current_energy` (10=never ran, regens →20), `is_paused`, `init_stage`.

"Promoted" = container Up AND per-DB gate (`agent.is_configured=true` +
`agent.consent_status="consent"`) AND `heartbeat_count` climbing. First two
are necessary-not-sufficient; only a rising cnt proves the loop runs.

Container `Up Xh` ≠ healthy: `core.gateway` consumer loop wedges after a
`hexis_brain` bounce (`Connect call failed …5432`, asyncpg `cannot switch
to state 12`) and does NOT self-heal. Fix = restart workers:
`docker restart $(docker ps -q --filter name=_heartbeat_worker --filter name=_maintenance_worker --filter name=_channel_worker)`

## Heartbeat not running?

Check `agent.is_configured` via `hexis status` or run `hexis init`.
Note: `heartbeat_state.next_heartbeat_at - CURRENT_TIMESTAMP` going negative is
**stale display, NOT overdue**. The gate is `should_run_heartbeat()` which adds
per-cycle jitter on top of `last_heartbeat_at + heartbeat_interval_minutes`.
Compute expected fire window as `last + interval` to `last + interval + heartbeat_jitter_minutes`.
Run `SELECT should_run_heartbeat();` to see the real verdict.

## Heartbeat workers silent after a DB bounce?

Consumer-wedge bug (`bf38d45`): per-char heartbeat workers don't reconnect after
the DB container's IP changes — they sit on `Consumer loop error: [Errno -2] Name
or service not known` forever while the process stays `Up`. Fix:
`docker restart hexis_<name>_heartbeat_worker`. Default `hexis_heartbeat_worker`
usually self-recovers; the per-persona ones often don't.
