# Upstream PR Pipeline — STATUS (index)

Reorganized 2026-06-04: files renamed by **status**, not stale sequence numbers.
Strategy playbook: `00-engagement-strategy.md`. Suitability screen + scrub table:
`../pr-suitability-2026-06-04.md`. Branch/divergence state: `../README.md`.

| Order | Status | PR / idea | File | Where |
|---|---|---|---|---|
| canary | **SHIPPED** | strip_reasoning (PR #19, no signal yet, gate ~06-13) | `SHIPPED-01-strip-reasoning.md` | open on QuixiAI/Hexis |
| 1 | **READY** (validated) | Telegram reply/quote context | `READY-01-reply-quote.md` | needs branch staging |
| 2 | **READY** (built) | RecMem compaction sender | `READY-02-recmem-compaction.md` | `C:\hexis-pr-recmem` branch `fix/recmem-compaction-sender` |
| 1b | **READY** (built, tested) | self-pause persist reason (A) + notify autonomy (B) | `READY-03-pause-autonomy.md` | `C:\hexis-pr-pause` branches `fix/pause-persist-reason` (`b3ec9e4`) + `feat/pause-notify-autonomy` (`08ed1bd`) — thesis-grounded, strongest fit |
| 3 | DRAFT | Tier-A bug fixes (8, security first) | `DRAFT-tierA-bugfixes.md` | need test each |
| 4 | DRAFT (rework) | chat context → system prompt | `DRAFT-chat-context.md` | re-port to upstream agent.py |
| 5 | gated | strip leading divider (PR-2) | in `DRAFT-tierA-bugfixes.md` | after PR #19 lands |
| — | TIER B | configurable channel history cap | `TIERB-history-cap.md` | needs re-port |
| — | TIER C | sender-scoped recall | `TIERC-01-sender-scoped-recall.md` | after 3+ landed PRs |
| — | TIER C | sender propagation to derived | `TIERC-02-sender-propagation.md` | companion to TIERC-01 |
| — | DROPPED | agent.tools seed | `DROPPED-agent-tools-seed.md` | fleet-specific, keep local |

## Not drafted (idea, not portable as-is)
- **Agent local-time awareness** (`3b3d060`): needs a fresh decoupled `db/09` patch
  (`resolve_sender_timezone` absent upstream). Low priority. See `../pr-suitability-2026-06-04.md`.

## Gate plan (~2026-06-13)
If PR #19 still has zero maintainer signal: fire **READY-01 reply/quote** (lowest risk,
completes his gap) as the high-value seriousness signal, then **READY-02 recmem**. If still
silent after that → stop upstreaming, keep local, re-eval after Eric's next drop.
