# BUG: heartbeat fleet stalls — Docker VM clock drift + GatewayConsumer no-self-heal

**Filed:** 2026-05-19
**Severity:** high (silent fleet-wide heartbeat outage; no alert; misdiagnosis-prone)
**Status:** mitigated by manual worker restart; root causes open

## Summary

Two distinct defects, observed together while verifying newchars heartbeat
activation (cassiel/death/joje/monika/nines + ennie/mira). Both make the
autonomous loop silently stop while every container still reports `Up`.

## Defect 1 (PRIMARY) — Docker VM clock instability

The Docker Desktop / WSL2 VM wall clock leapt forward **~8.7h mid-session**
(`2026-05-18 17:40:54Z` → `2026-05-19 02:27:11Z`) within ~40 min of real
wall time. All in-VM containers share this clock (brain + every worker:
`docker exec <c> date -u` all agreed with each other, disagreed with real
time across the jump).

### Impact
- `heartbeat_state.next_heartbeat_at` scheduling is wall-clock based →
  while the VM clock lags, every persona's "next" sits in the (skewed)
  future → heartbeats appear **stuck at `cnt=0`**; when the clock jumps
  forward the whole backlog **burst-fires** at once (thundering herd onto
  the single local GPU — the exact failure jitter was meant to prevent).
- `docker logs --since <dur>` math is computed against the skewed VM clock
  → silently returns an **empty / truncated** window. An empty worker log
  is indistinguishable from a dead worker. (death's heartbeat worker looked
  dead — `--since 25m` returned nothing — but full `docker logs` showed it
  had completed `Event 526`; it was fine.)
- Any host-vs-DB time comparison (user-contact cooldown, goal staleness,
  `next_heartbeat_at`) is wrong for the duration of the skew.

### Likely cause
Host sleep/resume or GPU power-mode switching (ECO/PRIME — see
`.local-notes/power-modes.md`); Docker Desktop's Hyper-V/WSL2 VM does not
reliably resync its clock after host power events on this rig.

### Diagnosis rule (mandatory before trusting any heartbeat-timing evidence)
```
docker exec hexis_brain date -u    # MUST agree with real UTC
```
If it disagrees, every `next_heartbeat_at`, `cnt`, and `docker logs --since`
reading is suspect until the clock resyncs. Do not conclude "stalled" or
"worker dead" from timing/`--since` alone while skewed.

### Mitigation / fix options (unimplemented)
- Disable host sleep while the fleet runs; or
- Force VM clock resync after resume (`wsl --shutdown` + restart Docker, or
  Docker Desktop clock-resync), or run an in-VM NTP/`hwclock` sync sidecar.
- Defensive: make the heartbeat scheduler tolerate non-monotonic wall-clock
  jumps (clamp absurd elapsed deltas; prefer a monotonic source for
  interval gating) so a clock leap doesn't burst-fire the whole fleet.

## Defect 2 (SECONDARY) — GatewayConsumer does not self-heal a brain bounce

After `hexis_brain` (Postgres) restarted, every worker's `core.gateway`
consumer loop wedged and never reconnected:

```
core.gateway - ERROR - Consumer loop error: connection was closed in the middle of operation
core.gateway - ERROR - Consumer loop error: [Errno 111] Connect call failed ('172.19.0.2', 5432)
core.gateway - ERROR - Consumer loop error: cannot switch to state 12; another operation (2) is in progress
core.gateway - ERROR - Consumer loop error: [Errno -2] Name or service not known
```

`cannot switch to state 12` = asyncpg connection left corrupted (concurrent
use after error). The loop logged the error repeatedly but never
re-established the DB/AMQP connection — heartbeats dead fleet-wide until a
**manual** `docker restart` of all `*_{heartbeat,maintenance,channel}_worker`.

Violates the stateless-worker principle (CLAUDE.md: workers should be
killable/restartable and recover without losing state — they don't recover
*on their own* from a dependency bounce).

### Fix direction
`core/gateway.py` consumer loop: on connection error, tear down and rebuild
the asyncpg connection/pool (don't reuse a connection that hit
`state 12`); bounded backoff reconnect; health-probe so a wedged consumer
is observable (it currently looks `Up` forever).

## Repro (observed, not yet minimized)
1. Fleet running (workers + `hexis_brain`).
2. Bounce `hexis_brain` (rebuild / restart).
3. Workers stay `Up`; `heartbeat_state` stops advancing; logs show the
   Defect-2 errors with no recovery.
4. Independently: host sleep/resume → VM clock jump → Defect-1 symptoms.

## Workaround (current)
```powershell
docker restart $(docker ps -q --filter "name=_heartbeat_worker" --filter "name=_maintenance_worker" --filter "name=_channel_worker")
```
Then verify recovery via `heartbeat_state` (cnt climbing, energy 10→20)
AND `docker exec hexis_brain date -u` == real UTC.

## Cross-refs
- Memory: `project-heartbeat-jitter-newchars-activated`, `power-modes-parked`
- Jitter (the herd mitigation a clock-jump defeats): commit `1684d8c`
