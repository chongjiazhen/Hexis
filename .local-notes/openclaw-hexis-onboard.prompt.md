# Handover: Onboard a Hexis persona on OpenClaw (Hexis = head, OpenClaw = body)

> Self-contained, battle-tested recipe (validated 2026-05-18 on Sam, Warden,
> ENI→Ennie). A fresh Claude window can run this with no prior context.
> Architecture decision + full history: auto-memory `openclaw-hexis-architecture`.

## 0. Model

OpenClaw = runtime body (agent loop, channels, tools). Hexis = mind
(identity / memory / worldview) exposed over MCP. One OpenClaw gateway hosts
N isolated agents, one per persona. Each persona = its own Hexis DB +
its own stdio-MCP→SSE proxy + its own OpenClaw agent + its own Telegram bot.

## 1. Environment (assumed running)

- Hexis stack up (`docker compose ... up -d`): `hexis_brain` Postgres,
  per-persona DBs (`hexis_<persona>`), heartbeat/maintenance workers.
- GPU model armed via `set-power-mode.ps1 prime` (single 16GB slot,
  `ActiveBig` in `power-profiles.psd1`). **Must be a tool-capable model with
  `--reasoning-budget 0`** (already baked into `set-power-mode.ps1`). q36
  (Qwen3.6-35B-A3B) validated. llama-server on host `:8080`.
- OpenClaw clone at `C:\openclaw`, prebuilt image
  `OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest` in `C:\openclaw\.env`
  (local build OOMs on the 1.86GB Docker VM — do NOT build locally).
- All `docker compose` for OpenClaw run from `C:\openclaw`.

## 2. Per-persona onboard steps

Replace `<P>` = persona id (e.g. `warden`), `<DB>` = `hexis_<P>`,
`<PORT>` = unique host port (sam 8765, warden 8766, eni 8767, next 8768…),
`<TOK>` = the persona's telegram bot token.

### 2.1 MCP proxy
Add a service to `C:\hexis\docker-compose.mcp.yml` (copy an existing block):
`hexis_mcp_<P>` → `POSTGRES_DB: <DB>`, ports `127.0.0.1:<PORT>:8765`.
```
cd C:\hexis
docker compose -f docker-compose.yml -f docker-compose.mcp.yml up -d --build hexis_mcp_<P>
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:<PORT>/sse   # expect 200
```

### 2.2 OpenClaw agent + MCP server (run from C:\openclaw)
```
# agent (MSYS_NO_PATHCONV=1 is REQUIRED for container paths under Git Bash)
MSYS_NO_PATHCONV=1 docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js agents add <P> --non-interactive --workspace /home/node/.openclaw/workspace-<P>
# MCP server (SSE; host.docker.internal OK for the MCP path)
docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js mcp set hexis-<P> '{"url":"http://host.docker.internal:<PORT>/sse"}'
```
First persona only — onboard the LLM provider once (note the **IP**, not
`host.docker.internal`, for the provider baseUrl — see Gotchas):
```
docker compose run --rm --no-deps --entrypoint node openclaw-gateway dist/index.js \
  onboard --non-interactive --accept-risk --mode local --no-install-daemon \
  --skip-health --skip-channels --skip-search --skip-skills --skip-ui \
  --gateway-bind lan --gateway-port 18789 --gateway-auth token \
  --auth-choice custom-api-key --custom-provider-id hexis \
  --custom-base-url http://192.168.65.254:8080/v1 \
  --custom-model-id <q36-alias> --custom-api-key noop \
  --custom-compatibility openai --custom-text-input
```
Then in `C:\openclaw\data\openclaw.json` provider `hexis`: set
`request.allowPrivateNetwork: true`, `timeoutSeconds: 900`,
model `contextWindow` ≤ (n_ctx − maxTokens).

### 2.3 Persona files (workspace-<P>, host: C:\openclaw\data\workspace-<P>)
Source of truth = the Hexis character card `characters/<P>.json` +
`hexis_<P>` `agent.init_profile`. Write a **tight** `SOUL.md` (voice/stance,
~1–1.5KB) + `IDENTITY.md`; **stub `AGENTS.md`** (~0.5KB) + minimal `TOOLS.md`.
Keep total workspace bootstrap small (~3KB) — large prompts hit the ctx
threshold and compaction derails the tool loop. Persona must be a POSITIVE
complete self (no "never say X" gag clauses — they backfire). Tell it: its
memory/identity is in `hexis-<P>` MCP; on identity questions call
`get_identity`+`recall` first; `remember` what lands.

### 2.4 Isolation + bloat trim (per-agent `agents.list[].tools.deny`)
Each agent denies (a) every OTHER persona's `hexis-<other>__*` namespace, and
(b) its own bloat tools (keep ~8: get_identity, get_worldview, recall,
recall_recent, remember, sense_memory_availability, hydrate, get_goals; deny
the rest: `hexis-<P>__*ingest*`, `__web_*`, `__*_file`, `__glob`, `__grep`,
`__list_directory`, `__*contact*`, `__manage_*`, `__*_batch*`,
`__generate_image`, `__list_council_personas`, `__query_usage`,
`__aggregate_signals`, `__hold`, `__link_concept`, `__get_health`,
`__get_drives`, `__get_procedures`, `__get_strategies`, `__recall_by_id`,
`__search_working`, `__request_background_search`, `__explore_concept`).
(Isolation deny ALONE is insufficient — the bloat trim is what lets the loop
finish.) Also set global `tools.profile: "messaging"`.

### 2.5 Channel + binding
Token file: write `<TOK>` to `C:\openclaw\data\.<P>-tg-token` (the live
credential — do not delete). Pairing is per-account.
```
MSYS_NO_PATHCONV=1 docker compose run --rm --no-deps --entrypoint node openclaw-gateway \
  dist/index.js channels add --channel telegram --account <P> --token-file /home/node/.openclaw/.<P>-tg-token
```
`openclaw.json` `bindings`: `{agentId:"<P>", match:{channel:"telegram", accountId:"<P>"}}`.

### 2.6 Restart + first-contact pairing
```
docker compose restart openclaw-gateway   # wait ~120s for channel-connect grace
```
User messages the bot → first contact needs pairing:
`docker compose run --rm --entrypoint node openclaw-cli dist/index.js pairing list telegram`
→ `… pairing approve telegram <CODE>`. Resend (pre-approval msgs drop).

## 3. Validate (ground truth, not inference)
- `docker logs hexis_mcp_<P> | grep -c CallToolRequest` rises (NOT just
  ListToolsRequest) → real tool calls.
- New row in `hexis_<P>.memories` from `remember`.
- Other personas' proxies/DBs unchanged → isolation holds.
- Reply in-persona, correct name, no cross-persona/lineage leak.

## 4. Gotchas (each cost hours — do not relitigate)
1. **Provider baseUrl MUST be the host-gateway IP** (`192.168.65.254`), NOT
   `host.docker.internal`. OpenClaw's idle-watchdog only treats IP/loopback as
   "local"; a DNS alias → clamped to 120s, ignoring `timeoutSeconds`.
2. **Reasoning models eat the tool call.** `--reasoning-budget 0` on
   llama-server (baked into `set-power-mode.ps1`) — else `<think>` consumes the
   budget, zero CallToolRequest ever.
3. **Workspace must be small.** Big bootstrap → ctx-threshold auto-compaction
   mid-turn → SOUL stripped, loop truncated, generic non-persona reply.
4. **MCP tool ids are namespaced** `hexis-<P>__<tool>` — `tools.deny` must use
   that prefix; bare ids silently no-op.
5. **Reset the agent session after ANY persona change**: move
   `C:\openclaw\data\agents\<P>\sessions\*` aside + restart. Else the agent
   parrots its own stale transcript verbatim and never recalls. The Hexis DB
   is the durable store; the session is ephemeral.
6. **Git Bash mangles container paths** → prefix `MSYS_NO_PATHCONV=1`.
7. Character card `characters/<P>.json` is **inert at runtime** (only
   `hexis init` on a fresh DB consumes it). Runtime persona = SOUL/IDENTITY +
   the Hexis brain. Don't expect card edits to change a live agent.
8. Inheriting an existing DB carries its old identity memories — re-seed the
   identity rows (UPDATE + regenerate embedding via
   `(get_embedding(ARRAY[content]))[1]`) if the persona changed; fix identity
   at the BRAIN, not just SOUL.
9. Avoid 3-letter acronym-shaped names (model uppercases them); pick a
   clearly-name-shaped id.

## 5. Freezing a persona (full)
Stop `hexis_<P>_heartbeat_worker` + `hexis_<P>_maintenance_worker`; remove its
agent/account/binding from `openclaw.json`; restart gateway. DB preserved
(dormant, recoverable). Bot token freed.

## 6. Current fleet state (2026-05-18)
Active: **Ennie** only (`eni` agent / @enigmatic_writer_bot / hexis_eni;
ex ENI-Warden; user-facing name "Ennie"). Frozen: Sam (hexis_memory,
@samantha_summers_bot), Warden (hexis_warden). 1 gateway, 1 active agent.
