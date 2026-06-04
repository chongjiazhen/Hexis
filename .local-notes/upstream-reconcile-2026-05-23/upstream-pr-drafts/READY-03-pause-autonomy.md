# READY (flagship) — self-pause autonomy (thesis-grounded)

Two singular, stacked commits in worktree `C:\hexis-pr-pause` off `origin/main`.
Discovered via hexis_null (the Nines persona self-paused; reason was unrecoverable).
**Most vision-resonant PRs in the pipeline** — they make Eric's own `pause_heartbeat`
honor the ETHICS doc's "preserves all state" + "ability to refuse."

Origin: ETHICS.md frames pause as a voluntary suspension that "preserves all state,"
and the agent "remains bound by its consent." But `pause_heartbeat` only queued the
reason to the (ephemeral) outbox — unlike `terminate_agent`, which durably persists its
`last_will` to `memories`. So the small exit lost the agent's reason; the big exit didn't.
Asymmetric and thesis-violating.

## Commit A — persist reason  (`b3ec9e4`, branch `fix/pause-persist-reason`)
- **Title:** `fix(heartbeat): persist self-pause reason to memory, not just outbox`
- `pause_heartbeat` writes a durable episodic memory (`source_attribution.kind='heartbeat_pause'`, zero-vec embedding, mirrors `terminate_agent`). Agent remembers why it stepped away → informed resume possible even if outbox never delivered.
- Test `tests/db/test_pause_persists_reason.py` — green with fix, red without (verified).
- **Upstream-present gap confirmed:** `origin/main` `pause_heartbeat` is `is_paused=TRUE` + `build_user_message` only, no `INSERT INTO memories`.

## Commit B — notify autonomy  (`08ed1bd`, branch `feat/pause-notify-autonomy`, stacked on A)
- **Title:** `feat(heartbeat): let the agent choose whether a self-pause notifies the operator`
- `{"notify": false}` in the action context suppresses the outbox notification; defaults true (prior behavior). Durable memory written regardless — only the *outward* signal is discretionary.
- Test `tests/db/test_pause_notify_autonomy.py` (2 cases) — green.
- **Sequencing:** stacked on A (same function). Ship A first, then B (rebase if A merges).

## Commit C — resume affordance + pause semantics  (LOCAL ONLY, not upstream)
Our own flavour of the vision (user's call, not a PR). The deeper gap: no
`resume_heartbeat` action, and a paused agent can't act (loop dead) → self-pause is a
one-way door, operator-only return.

**Empirical finding (2026-06-04):** `is_paused`/`should_run_heartbeat` gate ONLY the
heartbeat path. The chat/channel inbound path has NO pause gate → **a paused persona
still receives and answers DMs today.** Pause = "stop proactive (reach-outs, autonomous
cycles)", reactive chat stays on.

### C1 — resume_at auto-resume — BUILT (`c86e7c0` on home-rig-local)
One mechanism, two interfaces: agent self-pauses with `{"pause_minutes": N}` (relative)
or `{"resume_at": "..."}` (absolute, e.g. persona computes "next morning"); worker
auto-clears `is_paused` when reached. No value = indefinite (operator return).
- `resume_at` is a jsonb key on the `state` singleton, exposed via the `heartbeat_state`
  view (appended last so live apply is `CREATE OR REPLACE`). NO schema migration.
- Changed: `db/90_views.sql` (view), `db/07_functions_heartbeat.sql` (`pause_heartbeat`
  sets/clears resume_at; `should_run_heartbeat` auto-resumes), `tests/db/test_pause_resume_at.py` (3 cases, green).
- Live apply (operator step, not done): re-run the view + 2 functions per DB (CREATE OR REPLACE propagates).

### C2 — per-message response autonomy (REFRAMED, supersedes "pause modes")
Original idea was pause-modes (respond/read-only/silent). User's sharper take: hard-coding
modes just relocates the policy — and there's no principled line between the "small exit"
(pause) and "big exit" (terminate) that justifies a special pause-only posture. The
thesis-consistent version: **let the persona decide whether to respond to EACH inbound
message** (currently the code replies to 100%); "paused read-and-ignore" is then just a
special case of always-available per-message refusal. Empirical: chat path is ungated today
(paused persona still answers). STATUS: design direction recorded; bigger change (per-turn
engage/decline in the chat path), its own future work.

## Fire runbook (A then B)
```powershell
git -C C:\hexis-pr-pause checkout fix/pause-persist-reason
git -C C:\hexis-pr-pause push personal fix/pause-persist-reason
gh pr create --repo QuixiAI/Hexis --base main --head chongjiazhen:fix/pause-persist-reason `
  --title "fix(heartbeat): persist self-pause reason to memory, not just outbox"
# after A merges: rebase + push feat/pause-notify-autonomy, PR it
```
