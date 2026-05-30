# .local-notes — map

Local runbooks, scratch, research. Not team-shared. Reorganized 2026-05-30.

## Root (entrypoints — referenced from source/CLAUDE.md, do not move)

| File | Role |
|---|---|
| `_inbox.md` | Live "open items / what's on our plate" tracker |
| `hexis-native-onboard.prompt.md` | Persona onboard full recipe (cited by CLAUDE.md, `core/llm.py`, plans) |
| `hexis-native-onboard-nsfw.prompt.md` | NSFW persona onboard recipe |
| `recall-ctx-cap-spec.md` | Recall context-cap spec (cited by `apps/hexis_mcp_server.py`) |
| `power-modes.md` | ECO/PRIME power modes (cited by `hexis-launcher.ps1`) |
| `probe-tier-matrix.md` | Tier-probe matrix output (written by `tools/probe-eco`) |
| `strategy-local-llm-positioning.md` | Local-LLM positioning (cited by `tools/probe-eco`) |

## Subdirs

| Dir | Holds |
|---|---|
| `guidelines/` | Durable how-to: debugging, heartbeat, model-serving, schema-migration, persona-onboard(+nsfw). Cited by CLAUDE.md. |
| `migrations/` | Dated live-DB migration runbooks + loose migration `.sql` (jitter, night-mode) |
| `onboard/` | Persona onboarding material: `onboard-dve-*.sh`, `ennie-hexis-native-migration-spec.md` |
| `prompts/` | Reusable prompt templates: activebig-launcher, telegram-slash-tools |
| `research/` | Research + strategy: persona-memory-systems (base + 2026-05-30 snapshot), pivot-stack-eval, wsl2-docker-migration |
| `ideas/` | Parked ideas/plans: multi-char-group-chat, multi-char-modes, model-tier-probe plan, custom-characters, card-prompt-techniques, fleet-tg-avatars |
| `ops/` | Operational: `audit-scan.sql`, BUG-heartbeat-clock-drift, scratch-atelier-setup-sync |
| `archive/` | Abandoned paths: openclaw-hexis-onboard (OpenClaw retired) |
| `upstream-reconcile-2026-05-23/` | Upstream reconcile working set (PR drafts, migrate scripts) |

## Gitignored (not in version control)

`cards-summary.json`, `chunks/`, `card-full/`, `__pycache__/`.
