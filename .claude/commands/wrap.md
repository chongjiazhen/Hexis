---
description: hexis session-close handover — reconcile state vs git AND live fleet, verify live-apply close-gate, leave a clean next-step pointer
argument-hint: "(no args — full outbound sweep)"
---

Session-close bookend for hexis. Shape per `~/atelier/guidelines/session-bookends.md`
(read it for the five contracts; do not restate them). This file supplies only the
repo bindings + danger-invariants.

BIND:
- Directive layer: `CLAUDE.local.md` (git/serving/heartbeat/clock-drift danger rules),
  `CLAUDE.md` (architecture principles, schema authority),
  `.local-notes/guidelines/{heartbeat,model-serving,schema-migration,debugging}.md`
- Live-state home: `.local-notes/_inbox.md`  [FLAG: `.local-notes/` is gitignored — its
  own `local-notes` repo, NOT tracked by hexis]; plus per-repo auto-memory
  `~/.claude/projects/C--hexis/memory/` [FLAG: external, untracked]
- Reconcile target: `git -C C:\hexis log --oneline main..home-rig-local -15` + `git status -s`
  — AND the live fleet (git-shipped ≠ live), see Close-gate
- Close-gate: a commit on `home-rig-local` is NOT done. Real gate is repo-local:
  - SQL/schema/view → live-applied to running `hexis_<P>` DBs via CREATE OR REPLACE,
    INSTEAD OF trigger re-created in same migration, verified by a real `UPDATE`
    (CREATE OR REPLACE VIEW silently drops the trigger)
  - `services/prompts/*.md` edit → baked into worker images; needs
    `--no-deps --force-recreate --build` of affected workers + in-container
    `grep -c <new_term>` verify (NOT read per turn)
  - heartbeat / behavior → proven by rising `heartbeat_count` in `heartbeat_state`
    per `hexis_<P>` DB; container `Up Xh` ≠ healthy (gateway wedges after brain bounce)
  - serving change → fleet green via `.\hexis-status.ps1`; recover with `.\start-all.ps1`

DANGER-INVARIANTS (the command's reason to exist — a generic bookend breaks these):
- NEVER merge / ff / push `home-rig-local` → `main`. `main` = unowned upstream mirror.
  "Merge this work" on hexis = commit on `home-rig-local`, full stop. Unmerged
  `home-rig-local` is the steady state, NOT a loose end. Upstream contribution =
  clean cherry-pick onto a fresh branch off `main`, never a branch merge.
- NEVER `docker compose down -v` — wipes every `hexis_<P>` persona DB (2026-05-29 wipe).
  Data destruction, not a reset.
- NEVER kill `llama-server.exe` to force-reload — no supervisor; embed `:8081` is
  always-on, killing it breaks ALL hydration → generic replies. Recover via
  `.\start-all.ps1` (idempotent, won't double-bind `:8080`).
- BEFORE trusting ANY `--since` / heartbeat-timing evidence, run
  `docker exec hexis_brain date -u` and confirm it == real UTC. VM clock leaps hours
  (host sleep/resume, ECO/PRIME switch) → silent-empty log windows look like dead workers.
- `compose up --build` WITHOUT `--no-deps` recreates `hexis_brain` → fleet gateway wedge.
  Resume / rebuild MUST pass `--no-deps`.
- Throwaway-DB tests pass while live breaks (the trigger-drop trap). Green tests are
  never the close-gate.

Run the shape's five contracts against the bindings above. Output ≤6 lines:
what was culled / reconciled (vs git AND live fleet) → close-gate status (live-applied?
workers rebuilt? heartbeat climbing?) → next-step pointer written to `_inbox.md`? →
uncommitted-work disposition → "clear to /new" or the one blocker.
