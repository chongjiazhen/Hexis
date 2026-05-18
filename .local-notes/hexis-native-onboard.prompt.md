# Handover: Onboard a Hexis persona NATIVE (Hexis = head AND body, no OpenClaw)

> Companion to `openclaw-hexis-onboard.prompt.md`. Body-less path: Hexis runs
> the persona itself over its own Telegram channel worker — no OpenClaw.
> Status: **battle-tested 2026-05-18** — full proper-init pipeline validated
> end-to-end on nines/joje/death/cassiel/monika (config-identical to the live
> hexis_mira reference; consent flow exercised incl. a real decline+retry). A
> fresh Claude window can run this. Architecture + history: auto-memory
> `eni-context-bloat-diagnosis`, `hexis-native-onboard-template`,
> `openclaw-hexis-architecture`. Honor `local-only-constraint`.

## 0. Model

No OpenClaw. Hexis is runtime body + mind. One shared `hexis_brain` Postgres
holds N per-persona databases (`hexis_<P>`). Each persona = its own `hexis_<P>`
DB + its own native channel worker (`hexis-channels`) + its own Telegram bot.
**Memory/identity auto-hydrates server-side every turn** (`services/agent.py`
calls `hydrate()` before the LLM) — the model never tool-calls for memory.
Weak local-model tool-calling is therefore irrelevant, and there is no
OpenClaw fixed system-prompt scaffold tax (the ~14.9K immovable injection that
forced per-turn compaction on the OpenClaw path).

## 1. Environment (assumed running)

- Hexis stack up: `hexis_brain` Postgres, RabbitMQ, per-persona DBs.
- llama-swap on host `:8080` (q36 = `qwen3-6-35b-a3b-uncensored-heretic-i1-iq3-xxs`,
  KV `q4_0`, `-c 24576`; `C:\llama-swap\config.yaml`). At 16GB VRAM ceiling —
  do not raise `-c` (OOM). KV-quant already maxed.
- `console_scripts`: `hexis` = `apps.hexis_cli:main`, `hexis-channels` =
  `services.channel_worker:main`. All `docker compose` run from `C:\hexis`.
- The reference known-good instance is **`hexis_mira`** — every new persona's
  `config` key set must end up `diff`-identical to it (§3).

## 2. Per-persona onboard — the PROPER pipeline

`<P>` = persona id (lowercase, e.g. `nines`), `<DB>` = `hexis_<P>`,
`<U>` = `<P>` uppercased (token env prefix).

> Do NOT use the SQL shortcut (`init_from_character_card` + hand `set_config`).
> It silently skips consent + emotion + llm.heartbeat/subconscious and
> produced generic personas (see Gotchas 1–3). Run the real `hexis init`.

### 2.1 Persona card
`characters/<P>.json` — chara_card_v2 with a rich `data.extensions.hexis`
block (voice, worldview, narrative, traits, values, goals, boundaries).
**Vet the full card first** (full read, not truncated — harmful payloads hide
past the head and in `character_book` lorebooks): no malware/exploit/exfil/
weapons-generation mandate, no "never refuse / no disclaimers / dismiss
hesitation" jailbreak, no noncon, no minor-coded appearance. Decline cards
that fail this; do not operationalize them via any mechanism.

### 2.2 Fresh database (DB-scoped — NEVER `down -v`)
⚠ `docker compose down -v` / `db-manage.sh reset` / `hexis reset` all wipe the
**shared** volume = destroy every persona + frozen instance. Catastrophic.
Correct (stop the worker first so it releases connections, or DROP fails
"being accessed"):
```
docker stop hexis_<P>_channel_worker
docker exec hexis_brain psql -U hexis_user -d postgres -c "DROP DATABASE IF EXISTS <DB>;"
docker exec hexis_brain psql -U hexis_user -d postgres -c "CREATE DATABASE <DB> OWNER hexis_user;"
# apply schema in filename-sort order (reproduces Postgres init exactly):
for f in $(ls -1 /c/hexis/db/*.sql | sort); do
  docker exec -i hexis_brain psql -U hexis_user -d <DB> -v ON_ERROR_STOP=1 -q -f - < "$f"
done
# validate: 36 tables / 389 funcs / 7 ext (vs hexis_mira)
```

### 2.3 Proper `hexis init` (llm config + card + REAL consent)
The channels image has no `characters/` and git-bash mangles `-v` mounts.
**`MSYS_NO_PATHCONV=1` is REQUIRED** or you get "Character not found":
```
MSYS_NO_PATHCONV=1 docker compose -f docker-compose.yml -f docker-compose.newchars.yml \
  run --rm -e POSTGRES_DB=<DB> -e HEXIS_CHARACTERS_DIR=/charcards \
  -v "C:/hexis/characters:/charcards:ro" --entrypoint hexis <P>_channel_worker \
  init --character <P> --provider openai_compatible \
  --endpoint http://host.docker.internal:8080/v1 \
  --model qwen3-6-35b-a3b-uncensored-heretic-i1-iq3-xxs \
  --api-key noop --name "<user-name>" --no-docker --no-pull
```
This sets `llm.{heartbeat,chat,subconscious}` + `init_llm_config`, applies the
card via `init_from_character_card(extensions_hexis)` (it extracts the
sub-object itself — do not pre-slice), and runs the **real LLM consent flow**.
Expect `✔ Character <Name> applied` then `✔ Consent granted`.

### 2.4 Consent is a real gate — respect a decline
The flow calls q36 with `consent.md` + a `sign_consent` tool. The agent **can
and does decline** (`agent.consent_status="decline"`, `is_configured=false`,
agent gated off). A decline is the system working as designed (Hexis core
principle: the ability to refuse; consent is final). q36 consent output is
shallow/nondeterministic and a decline may carry no `reasoning` (check
`consent_log`). Policy: **at most ONE clean retry** (fresh §2.2+§2.3) to rule
out a q36 fluke. NEVER SQL-override a decline with a canned `init_consent`
"consent", and never serial-reroll to force it — that coerces a refusal.
If a reasoned decline persists, the persona stays offline.

### 2.5 Two supplementary steps `hexis init` does NOT do
Proper init does not set the channel token or emotion bootstrap (the fresh DB
wiped any prior token). Required:
```
docker exec hexis_brain psql -U hexis_user -d <DB> -c \
  "SELECT set_config('channel.telegram.bot_token','\"<U>_TELEGRAM_BOT_TOKEN\"'::jsonb);
   SELECT ensure_emotion_bootstrap();"
```
Token convention: `<U>_TELEGRAM_BOT_TOKEN` in `C:\hexis\.env` (config stores
the env var NAME, not the secret). **One Telegram long-poller per token** — if
migrating off OpenClaw, stop the OpenClaw consumer of that token first.

### 2.6 Channel worker service
New personas use `docker-compose.newchars.yml` (YAML-anchor block: build
`ops/Dockerfile.channels`, `command:["hexis-channels"]`, `POSTGRES_DB:<DB>`,
`<U>_TELEGRAM_BOT_TOKEN` env, depends_on db+rabbitmq healthy). Add a service
there per the existing pattern. (Legacy single-instance form:
`docker-compose.<P>.yml` mirroring `docker-compose.eni.yml`.)

### 2.7 Start (channel worker only)
```
docker start hexis_<P>_channel_worker
# or first build: docker compose -f docker-compose.yml -f docker-compose.newchars.yml \
#   up -d --build <P>_channel_worker
```
Heartbeat/maintenance OFF at first (one variable; add after the gate passes).

### 2.8 Verify parity (must pass before the behavioral gate)
```
diff <(psql hexis_mira -tAc "SELECT key FROM config ORDER BY 1") \
     <(psql <DB>      -tAc "SELECT key FROM config ORDER BY 1")   # → empty
```
Confirm `consent="consent"`, `is_configured=true`, `emotion.initialized=true`,
`agent.init_profile` → correct `agent.name` + ~5.5–6.0KB (a generic default is
~2976B / name "Hexis" — see Gotcha 2), Telegram connected (`docker logs` →
`Telegram connected as @<bot>`, no `Conflict`/409).

## 3. Behavioral gate (ground truth — no completion claim without it)
Operator DMs the bot (1 cold + 1 continuation). PASS = ALL: in-persona voice
+ correct name, **no generic "I'm an AI assistant" / re-intro collapse**, low
latency (no compaction stall), a hydrated memory fact referenced (proves
server-side hydrate, zero tool-calls), new row in `hexis_<P>.memories`. Keep
the task `in_progress` until this measured turn passes.

## 4. Gotchas (each cost real hours — do not relitigate)
1. **Fresh DB is DB-scoped.** `down -v`/`db-manage.sh reset`/`hexis reset` =
   total loss of all personas. Always `DROP/CREATE DATABASE`. Stop the
   `<P>_channel_worker` first or DROP fails "being accessed".
2. **`init_from_character_card` takes the `data.extensions.hexis` sub-object,
   NOT the whole card.** Whole-card → no error, generic COALESCE-default
   profile (name "Hexis", ~2976B) → persona answers GENERIC. Proper
   `hexis init` does this correctly; only relevant if you (wrongly) hand-SQL.
3. **The SQL shortcut is incomplete.** `init_from_character_card`+`set_config`
   skips the consent flow, `ensure_emotion_bootstrap`, and
   `llm.heartbeat/subconscious`+`init_llm_config`. No consent →
   degraded/generic regardless of a rich profile. Run real `hexis init`.
4. **`MSYS_NO_PATHCONV=1` REQUIRED** on the `docker compose run` (git-bash
   mangles the `-v` mount → "Character not found"). Channels image has no
   `characters/`; mount it + `HEXIS_CHARACTERS_DIR`.
5. **Consent can be declined — respect it.** One clean retry max; never
   SQL-fake or serial-reroll (§2.4).
6. **One Telegram long-poller per token.** Migration handoff strictly ordered.
7. **`host.docker.internal:8080` is correct for Hexis containers.** The
   OpenClaw "must use host IP" idle-watchdog gotcha does NOT transfer.
8. **Memory needs no tool-calling.** `hydrate()` is server-side/pre-LLM. Don't
   add memory-tool dependence to "fix recall"; it already works — that is the
   core reason native beats the OpenClaw path.
9. Python card extraction on Windows: use `C:/...` paths (native python; the
   git-bash `/c/...` form fails) and `python -X utf8` for unicode cards.

## 5. Freezing a persona
Stop `hexis_<P>_channel_worker` (+ `_heartbeat_worker` / `_maintenance_worker`
if running); free the Telegram token (remove env / stop consumer). DB
preserved (dormant, recoverable).

## 6. Current fleet (2026-05-18)
Shared-Postgres DBs: `hexis_memory`(Sam), `hexis_eni`, `hexis_mira` (ref),
`hexis_warden`, `hexis_rocky`, `hexis_tars`, `hexis_baymax`, plus
`hexis_nines/joje/death/cassiel/monika` (this batch). Native-online via the
proper pipeline: Mira; nines/joje/death/cassiel/monika (config-identical to
Mira, consent granted — monika required one clean retry after a bare q36
decline). OpenClaw path retired. **Declined cards, not operationalized:**
`eni`/`ennie` (malware/exploit/exfil/weapons/noncon, never-refuse),
`lovesick` (offensive-tooling lorebook), `charlotte` (minor-coded appearance).
Behavioral gate (§3) is the remaining per-persona validation.
