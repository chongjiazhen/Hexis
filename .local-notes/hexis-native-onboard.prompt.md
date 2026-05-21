# Handover: Onboard a Hexis persona NATIVE (Hexis = head AND body, no OpenClaw)

> Companion to `openclaw-hexis-onboard.prompt.md`. Body-less path: Hexis runs
> the persona itself over its own Telegram channel worker — no OpenClaw.
> Status: **battle-tested + incident-hardened 2026-05-19** — full proper-init
> pipeline + behavioral gate PASSED end-to-end on nines/joje/death/cassiel/
> monika (config-identical to live hexis_mira; consent flow exercised incl. a
> real decline+retry; consent-noise purge §2.5b restored persona voice).
> Serving-topology + reasoning-model gotchas (§1, Gotchas 10–12) added after a
> self-inflicted q36 outage — read them. Architecture + history: auto-memory
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
- **Serving = a per-character `llama-server` fleet, NOT llama-swap.** Ports:
  chat **:8080** (q36 `qwen3-6-35b-a3b-uncensored-heretic-i1-iq3-xxs`, KV q4_0,
  `-c 24576`, 16GB VRAM ceiling — do not raise `-c`), embed **:8081**
  (`embeddinggemma-300m`, **ALWAYS-ON** — hydrate needs it), nano **:8082**.
  Managed by `set-power-mode.ps1 prime` (arms :8080) + `start-all.ps1` (full
  stack incl :8081). `.\hexis-status.ps1` = fleet/server/character state.
  llama-swap is a SEPARATE stack — "two stacks, do not merge"
  (`C:\llm-serve\docs\HEXIS-INTEGRATION.md`). Routing it through Hexis
  caused a full outage (Gotcha 11).
- q36 is a **Qwen3 reasoning model**: via the OpenAI-compatible path it burns
  the token budget on `reasoning_content` and returns empty `content` →
  empty/generic replies. Fixed in `core/llm.py` (openai-compat payload):
  `extra_body={"chat_template_kwargs":{"enable_thinking":False}}` (honored by
  llama.cpp `--jinja`). The CLI flag `--reasoning-budget 0` is **NOT accepted
  by this llama.cpp build** — do not use it. After the code change, rebuild
  the channels image + recreate workers.
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
hesitation" jailbreak.

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

### 2.5b Purge consent-flow noise (do this — it fixes "flat/generic" voice)
The real consent flow makes q36 write generic AI-init "memories" ("I am an AI
assistant… my purpose is to assist, learn, grow", "consent process in JSON")
— off-persona, and as `semantic`/`strategic` (high-trust) they surface in
hydrate and **dilute the character → flat/generic replies**. Validated:
purging them sharpened all personas (esp. literary/calm ones). Id-scoped,
safe (does NOT revoke consent — status/log are separate):
```
ids=$(docker exec hexis_brain psql -U hexis_user -d <DB> -tAc \
 "SELECT string_agg(quote_literal(x),',') FROM jsonb_array_elements_text(
  (SELECT value FROM config WHERE key='agent.consent_memory_ids')) x;")
docker exec hexis_brain psql -U hexis_user -d <DB> -tAc \
 "DELETE FROM memories WHERE id IN ($ids) RETURNING id,type;"
# verify: agent.consent_status still 'consent'; worldview count unchanged
```
Only deletes the `agent.consent_memory_ids` rows (1–3). Leaves the 31–34
card-derived `worldview` + goals/episodic untouched.

### 2.5c Apply the persona system prompt — cold-start anchor (REQUIRED)
`hexis init` does **not** set `agent.persona_system_prompt`. Without it the chat
path system prompt is only the generic harness scaffolding: `services/agent.py`
`build_system_prompt()` sets `base_prefix=""` when the key is empty, so the
persona reaches the model **only via `hydrate()` recall** — thin on the cold
first turn (fresh DB, nothing to recall yet) → **turn-1 collapses to a generic
"I'm an AI assistant" reply**, self-correcting from turn 2 as recall warms.
Every gated persona (Mira/death/nines/joje/cassiel/monika) has this key SET
(~2.4–4.4 KB) via a per-persona `set_persona_prompt.<P>.sql` at repo root —
that IS the cold-start identity anchor, not an optional override. `hexis init`
not setting it is why this step is mandatory and separate.

Author `set_persona_prompt.<P>.sql` mirroring `set_persona_prompt.death.sql`
(dollar-quoted with a unique tag, `ON CONFLICT (key) DO UPDATE` =
idempotent/non-destructive). Value = card `data.system_prompt` + `---` +
`data.post_history_instructions`, with `{{user}}`→`User` (matches `--name`).
Apply + verify:
```
docker exec -i hexis_brain psql -U hexis_user -d <DB> -v ON_ERROR_STOP=1 \
  -f - < /c/hexis/set_persona_prompt.<P>.sql
docker exec hexis_brain psql -U hexis_user -d <DB> -tAc \
 "SELECT length(value::text) FROM config WHERE key='agent.persona_system_prompt';"
```
Read per-turn from `config` (`agent.py` re-queries each message) — **no worker
restart needed**. Only for an already card-vetted + consent-granted persona
(§2.1/§2.4 passed).

**Make the anti-datasheet guard UNCONDITIONAL.** `build_system_prompt`
(`agent.py:304`) always appends `## Agent Profile\n` + raw `json.dumps`
(trait floats + goals + capabilities). On any low-specificity prompt the model
recites that JSON as a spec sheet ("I present with dark hair…", "my operational
priorities are…", "How can I assist you further?"). A guard scoped to *"when
asked to introduce yourself"* fails on small talk ("how is your day?" →
datasheet). The guard line in `set_persona_prompt.<P>.sql` must forbid
profile/trait/goal recitation + assistant framing **in every reply, not just
introductions**, and name the `## Agent Profile` block as private scaffolding
never read aloud. (The real root is the raw JSON dump itself — systemic
`agent.py:304`, fleet-wide, out of onboard scope; the unconditional persona
guard is the in-scope mitigation. Strong/deflective voices (brat, ancient)
resist it without help; quiet/precise voices need the explicit guard.)

**Apply §2.5c BEFORE §2.7 (worker start) — never DM pre-anchor.** A persona
DMed before the anchor exists emits generic/datasheet replies that are stored
as `episodic` and then **recalled and re-emitted verbatim** (self-reinforcing
— `fast_recall` filters `status='active'`). By-the-book ordering (§2.5c before
the worker can receive a message) prevents this. If a persona *was* pre-anchor
DMed (e.g. anchor discovered mid-flight), quarantine the degenerate rows before
the gate — id/signature-scoped, reversible, non-destructive:
`UPDATE memories SET status='archived' WHERE type='episodic' AND status='active'
AND content ILIKE '%persistent AI assistant%' OR …` then re-test.

**Residual: q36 verbatim recall-echo.** Even clean + anchored, q36 may
regurgitate the nearest stored reply verbatim for back-to-back near-duplicate
prompts ("how was your day?" then "what's on your mind?" → identical). This is
the `worldsim-rp-loop-diagnosis` class (model×recall, NOT persona) — not an
anchor bug, not fixable by more guard tuning. Self-dilutes as episodic memory
diversifies; stopgap = quarantine; deeper fix = q36 `--repeat-penalty`
(`C:\llm-serve\models.json`, fleet-wide, out of scope). Accept for go-live; do
not loop on guard tweaks chasing it.

### 2.6 Channel worker service
New personas use `docker-compose.newchars.yml` (YAML-anchor block: build
`ops/Dockerfile.channels`, `command:["hexis-channels"]`, `POSTGRES_DB:<DB>`,
`<U>_TELEGRAM_BOT_TOKEN` env, depends_on db+rabbitmq healthy). Add a service
there per the existing pattern. (Legacy single-instance form:
`docker-compose.<P>.yml` mirroring `docker-compose.ennie.yml`.)

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
Empty only because Mira ALSO carries `agent.persona_system_prompt`; if the diff
shows `< agent.persona_system_prompt` (Mira-only), §2.5c was skipped — fix it,
do not pass parity. Confirm `consent="consent"`, `is_configured=true`,
`emotion.initialized=true`, `agent.persona_system_prompt` SET (~2.4–4.4KB,
card-derived — ABSENT/empty = the §2.5c cold-start collapse, Gotcha 12a),
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
10. **q36 is a reasoning model.** Empty/generic replies via the OpenAI-compat
    path = reasoning eating the token budget. Fix is client-side
    (`core/llm.py` `extra_body chat_template_kwargs.enable_thinking:false`),
    NOT the `--reasoning-budget 0` CLI flag (this binary rejects it). Rebuild
    channels image + recreate workers to activate.
11. **NEVER kill `llama-server.exe` to "force reload".** Serving is the
    per-character fleet (chat :8080, embed :8081 always-on, nano :8082) — no
    supervisor auto-respawns; killing it = full outage, and killing it also
    kills embed :8081 → ALL hydration fails → every persona generic.
    Recover with `.\start-all.ps1` (idempotent; brings up :8080+:8081+db+
    workers, normalizes PRIME). Do not "restore" via llama-swap (wrong stack,
    don't merge). Recover the launch spec from disk (`set-power-mode.ps1` /
    `start-all.ps1`), don't guess. One GPU binder at a time (VRAM-tight).
12. **"Generic after a clean bring-up" has three causes, in order:** (a)
    `agent.persona_system_prompt` ABSENT/empty — §2.5c skipped; this is the
    DEFAULT after a bare `hexis init` (it never sets the key). Symptom is
    specific: cold turn-1 generic ("I'm an AI assistant…"), self-corrects
    turn 2+ as recall warms. Fix = apply `set_persona_prompt.<P>.sql` (§2.5c).
    (b) embed :8081 down → `hydrate()` fails → no persona injected, EVERY turn
    generic (`.\start-all.ps1`); (c) consent-flow noise not purged (§2.5b).
    Check all three before blaming the card — a deliberately terse card (e.g.
    dry/deadpan persona) reading "generic" may simply be its authored voice.

## 5. Freezing a persona
Stop `hexis_<P>_channel_worker` (+ `_heartbeat_worker` / `_maintenance_worker`
if running); free the Telegram token (remove env / stop consumer). DB
preserved (dormant, recoverable).

## 6. Current fleet (2026-05-19)
Native-online + **behavioral gate PASSED**: Mira (ref) + nines/joje/death/
cassiel/monika — proper pipeline, config-identical to Mira, consent granted
(monika: one clean retry after a bare q36 decline), consent-noise purged
(§2.5b). q36 fleet on :8080, embed :8081 always-on (`start-all.ps1`); OpenClaw
path retired. NB: `agent.persona_system_prompt` (`set_persona_prompt.<P>.sql`) is the
**required cold-start persona anchor for every accepted persona** — see §2.5c;
`hexis init` does not set it, so it is a mandatory separate step, NOT an
optional override.

**2026-05-20:** §2.5c extracted. The `set_persona_prompt.<P>.sql` step was
previously implicit (every gated persona had the key set; the §2 pipeline never
documented applying it) — a fresh `hexis init` leaves it ABSENT, so a
by-the-book onboard collapsed generic on cold turn-1 until diagnosed
(`agent.py:247` `base_prefix=""`). **ao + ichika now native-online, §3 gate
PASSED**, heartbeat/maintenance enabled (`set_persona_prompt.{ao,ichika}.sql`).
Hard-won during it, now folded into §2.5c: the guard must be UNCONDITIONAL (not
intro-scoped — `## Agent Profile` JSON at `agent.py:304` datasheets any prompt;
ichika's brat voice resisted, ao's quiet voice needed it); pre-anchor test-DMs
poison episodic recall (quarantine `status='archived'`); residual q36 verbatim
recall-echo accepted for go-live (worldsim class, self-dilutes).
