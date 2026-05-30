# Handover: wire chat tools into Telegram /slash commands per char

## Goal

Each character's Telegram bot should expose `/slash` commands that invoke the
agent tools now available in the chat path (e.g. `/search <q>`, `/fetch <url>`,
`/summarize <url>`, `/remember <text>`, `/schedule ...`). Today tools only fire
if the model decides to call them mid-conversation; add explicit slash commands
as a direct, discoverable entrypoint.

## Context (already done — do NOT redo)

- Chat tool bridge is LIVE. RLM chat path (`services/hexis_rlm.py::run_chat_turn`)
  now builds a CHAT `ReplToolBridge`; chat has web_search/web_fetch/
  web_summarize/ingest/schedule/goals + memory. Commits `541d78d`, `9d8f6f1`.
- `web_search` uses self-hosted SearXNG (`SEARXNG_URL=http://searxng:8080`,
  Tavily fallback). SearXNG container attached to `hexis_private`/`hexis_public`.
- Running chat instances (own DB each, shared `hexis_brain`): default brain +
  ennie, mira, cassiel, death, joje, monika, nines. Telegram-only.
- See memory `project-heartbeat-jitter-newchars-activated` for full state.

## Task

1. Read `channels/telegram_adapter.py` (+ `channels/conversation.py`) — find how
   inbound Telegram updates are handled and whether bot commands / a command
   registry already exist.
2. Add a slash-command layer: map `/command args` → the corresponding tool via
   the same registry/execution path chat uses (`core/tools/registry.py`
   `create_default_registry`, `ToolContext.CHAT`). Do NOT bypass tool policy.
3. Register the command list with Telegram (BotFather `setMyCommands` /
   `set_my_commands` via the bot API) so they autocomplete per char.
4. Keep it per-char generic: same command set for every character bot, driven by
   which tools are enabled for that instance.
5. Suggested initial commands: `/search`, `/fetch`, `/summarize`, `/remember`,
   `/recall`, `/schedule`, `/help` (lists commands). Free-text messages keep
   current RLM chat behavior unchanged.

## Constraints

- Local-inference-only mandate (memory `feedback-local-only-constraint`): no
  cloud APIs. SearXNG/local only.
- Shared code path → change affects all char instances; verify no regression to
  normal free-text chat.
- Schema/infra changes apply live via `CREATE OR REPLACE` / targeted `docker`,
  never `down -v` (memory `project-heartbeat-jitter-newchars-activated`).
- Auto-mode classifier blocks agent-run destructive/multi-instance infra; hand
  those commands to the user (memory `feedback-classifier-blocks-agent-infra-selfperm`).

## Verify

- Unit/import: `venv/Scripts/python.exe -m py_compile <changed>` + import.
- E2E: send `/search test` to one char's Telegram bot, then
  `docker logs --tail 30 hexis_ennie_channel_worker | Select-String "tool_use|web_search"`
  — expect a successful tool call.

## Commit

Conventional prefix, no `Co-Authored-By` (project rule). Commit per discrete step.
