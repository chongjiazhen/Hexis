# Wrap bindings - hexis

Data for the session-close (`/wrap`). Harness-neutral: any wrap implementation
(Claude skill, Codex, qwen) reads this file and runs its own procedure
parameterized by the slots below. **Bindings only - no procedure here.**

Migrated from `.claude/commands/wrap.md` 2026-08-28; the command was never the
trigger, only the data.

## Directive layer

- `CLAUDE.local.md` - git / serving / heartbeat / clock-drift danger rules
- `CLAUDE.md` - architecture principles, schema authority
- `.local-notes/guidelines/{heartbeat,model-serving,schema-migration,debugging}.md`

## Live-state home

- `.local-notes/_inbox.md` - tracked by hexis on `home-rig-local`; commit inbox
  updates with the session's work (verified 2026-07-10)
- `~/.claude/projects/C--hexis/memory/` - **FLAG: external, untracked.** Will not
  show in `git status`; reconcile it separately.

## Reconcile target

`git -C C:\hexis log --oneline main..home-rig-local -15` + `git status -s` - AND
the live fleet. Git-shipped is not live; see Close-gate.

## Close-gate

A commit on `home-rig-local` is NOT done. The real gate is repo-local:

- **SQL / schema / view** - live-applied to the running `hexis_<P>` DBs via
  `CREATE OR REPLACE`, INSTEAD OF trigger re-created in the same migration,
  verified by a real `UPDATE` (`CREATE OR REPLACE VIEW` silently drops the
  trigger).
- **`services/prompts/*.md` edit** - baked into worker images; needs
  `--no-deps --force-recreate --build` of the affected workers plus an
  in-container `grep -c <new_term>` verify (NOT read per turn).
- **heartbeat / behavior** - proven by a rising `heartbeat_count` in
  `heartbeat_state` per `hexis_<P>` DB; a container at `Up Xh` is not healthy
  (the gateway wedges after a brain bounce).
- **serving change** - fleet green via `.\hexis-status.ps1`; recover with
  `.\start-all.ps1`.

Close-gate status is what the summary reports: live-applied? workers rebuilt?
heartbeat climbing?

## Danger-invariants

The reason this file exists - a generic close breaks these.

- **NEVER merge / ff / push `home-rig-local` into `main`.** `main` is an unowned
  upstream mirror. "Merge this work" on hexis means commit on `home-rig-local`,
  full stop. An unmerged `home-rig-local` is the steady state, NOT a loose end.
  Upstream contribution is a clean cherry-pick onto a fresh branch off `main`,
  never a branch merge.
- **NEVER `docker compose down -v`** - wipes every `hexis_<P>` persona DB
  (2026-05-29 wipe). Data destruction, not a reset.
- **NEVER kill `llama-server.exe` to force a reload** - there is no supervisor;
  the embed `:8081` is always-on and killing it breaks ALL hydration, giving
  generic replies. Recover via `.\start-all.ps1` (idempotent, will not
  double-bind `:8080`).
- **Before trusting ANY `--since` or heartbeat-timing evidence**, run
  `docker exec hexis_brain date -u` and confirm it equals real UTC. The VM clock
  leaps hours (host sleep/resume, ECO/PRIME switch), so silent-empty log windows
  look like dead workers.
- **`compose up --build` WITHOUT `--no-deps` recreates `hexis_brain`** and wedges
  the fleet gateway. Resume / rebuild MUST pass `--no-deps`.
- **Throwaway-DB tests pass while live breaks** (the trigger-drop trap). Green
  tests are never the close-gate.
