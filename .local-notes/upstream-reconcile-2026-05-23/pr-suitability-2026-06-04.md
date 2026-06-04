# PR Suitability Screen — 2026-06-04

Conceptual screen of upstream-PR candidates (NOT a build/test pass). Each judged on:
generalizable · completes-an-upstream-gap / real-bug · vision-fit · dependency-clean (portable as cherry-pick?) · rejection risk.

Gates recap (`00-engagement-strategy.md`): Eric Hartford solo-maintains, Discussions OFF, ignores architecture proposals, merges small obviously-correct PRs. → ship small correct code; completing his own half-built features is the lowest-risk move.

## Built / validated this session

| Commit | Idea | State | Verdict |
|---|---|---|---|
| `a50c7e7` | surface Telegram reply/quote context to model | **VALIDATED** — clean cherry-pick on `origin/main`, 42/42 channel tests green | **TOP flagship.** Completes upstream's own captured-but-unused `reply_to_id` (telegram_adapter.py:218, ChannelMessage.reply_to_id base.py:48). Self-evident value, vision-fit (presence/grounding), additive +94, no fleet coupling. Lowest rejection risk. |
| `7ead8fe` (port of compaction bug) | preserve real sender through compaction flush | **BUILT** — branch `fix/recmem-compaction-sender` @ `C:\hexis-pr-recmem`, test green/red proven | **Flagship #2.** Bug in Eric's newest RecMem code; deep signal. Caveat: value conditional on an upstream consumer of partner-identity → frame on hot-path symmetry. |

## Tier A — suitable bug fixes (generic, low risk, smaller signal)

All generalizable, no fleet coupling, ship one-at-a-time after a flagship lands.

| Commit | Idea | Suitability | Note |
|---|---|---|---|
| `036e840` | silence httpx INFO so TG tokens don't leak | **HIGH** | security; +4 lines; reads as drive-by but universally correct |
| `b987e32` | keep queued Telegram updates across worker restart | **HIGH** | robustness bug; anyone running TG wants it |
| `7897c72` | gateway pass `timedelta` not `str` | **HIGH** | plain type bug, isolated `core/gateway.py` |
| `54253d9` | coerce free-text goal priority to enum | **HIGH** | bug fix, 1 db function |
| `a95c654` | use `#>>` for JSONB string extraction in card init | **HIGH** | bug fix, generic |
| `dc4766c` | treat TG "Message is not modified" as edit no-op | **MED-HIGH** | bug fix; verify against current adapter |
| `48d8d99` | `--endpoint` arg for noninteractive `hexis init` | **MED** | useful CLI feature, generic |
| `a13e7c8` | warn when card extensions misplaced | **MED** | UX nicety |

> None of these ship a test (home-rig quick fixes). For PR quality, add a minimal test per fix before pushing. db-touching ones (`54253d9`, `a95c654`) get implicit SQL-compile validation from any db test's full schema build.

## Sequenced / conditional

| Commit | Idea | Verdict |
|---|---|---|
| `4ff607e` | strip leading markdown divider from output | **PR-2, gated.** Depends on `0b3beb2` (`strip_reasoning`, = open PR #19). Sibling — calls strip_reasoning. Ship only after #19 lands. |
| `3bf21cd` | move chat hydrated context into system prompt | **MED risk — verify first.** Touches `services/agent.py`, which upstream actively churns (RecMem migration). Has a bundled test (good). Re-base + re-check collision against current `origin/main` before PR. |

## Needs rework — NOT a port

| Commit | Idea | Verdict |
|---|---|---|
| `3b3d060` | agent local-time awareness in env snapshot | **Upstreamable idea, un-portable commit.** Depends on `resolve_sender_timezone()` which DOES NOT exist upstream (it's our reach-out cluster). Upstream `db/09` has no local-time concept. To PR: write a fresh ~10-line `db/09` patch giving the agent its own configured local time, decoupled from sender-timezone / quiet-hours. New work, weak signal (small, fills no maintainer gap). Low priority. |

## Tier C — gated on goodwill (big, opinionated)

| Bundle | Verdict |
|---|---|
| All-latent reach-out cluster (~25 commits: `bada1cd`,`a90bfc1`,`e62f23a`,`5838689`,…) | Our design line. Worldview-level autonomy change. Eric ignores architecture proposals → do NOT PR cold. Issue-first at best; realistically keep local. |
| Sender-scoped recall (`ec9e1ec`+`bd106a8`+PR-A/B) | Big. Ship only after 3+ landed PRs. See `upstream-pr-drafts/TIERC-01-sender-scoped-recall.md` + `TIERC-02-sender-propagation.md`. |

## Body-read corrections (2026-06-04, after reading every candidate's full message)

Initial screen above ranked some candidates from subjects only. Reading bodies changed:

- **`a95c654` JSONB `#>>` → upgrade MED to HIGH.** Real correctness bug: `btrim(entry::text,'"')` doesn't JSON-unescape, so worldview/values/boundaries with escaped quotes came through mangled. 8 sites. Clearly-correct, well-justified — strong Tier-A.
- **`dc4766c` telegram not-modified → upgrade MED-HIGH to HIGH.** Specific rendering bug: final streaming edit raised "Message is not modified", generic `except` retried without parse_mode → MarkdownV2 replaced by raw text. Clean, generic.
- **`3bf21cd` chat-context → promote to STRONG (but port-rework, not cherry-pick).** Bug CONFIRMED present upstream: `origin/main:services/agent.py:91` injects subconscious output "into the user message context"; `attach_chat_context` absent upstream. Leak-prone local models narrate injected context as if the user said it. Generalizable, vision-fit (clean persona behavior). BUT upstream `agent.py` shape differs (post-RecMem) → needs re-port to current assembly, plus verify framing. Treat as high-value Tier-B.

### SCRUB-BEFORE-PR (dimension missed in first screen)

Several fixes are generic but their COMMIT MESSAGES name personas/fleet — rewrite the message/PR body before pushing (the code is clean; the prose isn't):

| Commit | Scrub |
|---|---|
| `4ff607e` | "Eudora's onboarding" → generic "a persona onboarding surfaced it" |
| `48d8d99` | "hexis_mira" per-persona DB example → generic |
| `b987e32` | "power-mode flips" fleet example → keep "deploys/restarts" only |
| `3bf21cd` | "Vera onboarding" → generic |

`0b3beb2` (PR #19, already pushed) and `4ff607e` are abliterated-Gemma-motivated but model-agnostic in the fix — frame the PR on the general case, not the specific model.

## Recommended PR order for the ~2026-06-13 gate

1. **`a50c7e7` reply/quote** (validated, lowest risk, completes his gap) — lead with this.
2. **`7ead8fe` recmem compaction** (built, deep signal) — follow-up.
3. Then Tier A bug fixes one-at-a-time, security (`036e840`) first.
4. `4ff607e` only after PR #19 lands.
5. Tier C never cold.
