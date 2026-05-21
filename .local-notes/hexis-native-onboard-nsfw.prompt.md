# Handover: Onboard a Hexis NSFW/Jailbreak Persona (Hexis-native, no OpenClaw)

> Extends `hexis-native-onboard.prompt.md`. Follow that doc for all standard
> steps (§0–§7). This doc covers the NSFW-specific additions and gotchas that
> apply when the character card carries an uncensored `system_prompt` (devotion,
> no-refusal, explicit content delivery, etc.).
>
> Also covers preemptive `persona_system_prompt` application for SFW cards
> whose future interactions may turn NSFW (N.1 is idempotent; safe to apply
> to any persona).
>
> Validated on: Ennie (`hexis_ennie`) — 2026-05-18. persona_system_prompt
> applied to nines/death/cassiel/joje/monika/mira — 2026-05-19.

---

## Why NSFW cards need extra steps

Standard Hexis onboard builds the LLM system prompt from `conversation.md`
(generic) + personhood modules (generic) + minimal agent profile
(`name`, `tools`, `budget` only). The character card's `data.system_prompt`
— which carries the "NEVER refuse", explicit-content, and persona-voice
instructions — is **never injected** by default:

- `get_agent_profile_context()` SQL function returns only the operational
  slice (`name`, `tools`, `budget`, `guardrails`, `objectives`).
- `init_from_character_card()` seeds identity/personality into memories and
  `agent.init_profile`, but does NOT store `data.system_prompt` as a
  standalone config key.

Result without the fix: model sees a generic Hexis prompt, falls back to base
training safety behavior, refuses explicit turns, Qwen3 outputs
`<think>…</think>` with no visible content, streaming yields `""`, empty
assistant turns get stored in history, subsequent turns also fail silently.

---

## NSFW-specific steps (run AFTER standard §2.1–§2.4)

### N.1 Extract and store the persona system prompt

Run this Python snippet (from the host, NOT inside a container) against the
character card after `hexis init` completes. On Windows invoke with the full
Python path and `-X utf8` flag (git-bash `python` may not be on PATH; see
Gotcha 7):

```python
# Invoke: C:/Users/User/AppData/Local/Programs/Python/Python313/python.exe -X utf8 <this_script>.py
import json

CARD_PATH = "C:/hexis/characters/<P>.json"  # must be C:/... not /c/...
DB_NAME   = "hexis_<P>"
# Replace placeholders — {{char}} → persona name, {{user}} → "User"
CHAR_NAME = "<DisplayName>"   # e.g. "Ennie"

card = json.load(open(CARD_PATH, encoding="utf-8"))
data = card["data"]
sys_prompt = data.get("system_prompt", "")
post_hist  = data.get("post_history_instructions", "")

for src, dst in [("{{char}}", CHAR_NAME), ("{{user}}", "User")]:
    sys_prompt = sys_prompt.replace(src, dst)
    post_hist  = post_hist.replace(src, dst)

merged = sys_prompt
if post_hist:
    merged += "\n\n---\n\n" + post_hist

tag = "NSFWPRMT"
assert tag not in merged, "tag collision — pick a different tag"

sql = (
    f"INSERT INTO config (key, value) "
    f"VALUES ('agent.persona_system_prompt', to_jsonb(${tag}${merged}${tag}$::text)) "
    f"ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;"
)

out_path = f"C:/hexis/set_persona_prompt.{CARD_PATH.split('/')[-1].replace('.json','')}.sql"
open(out_path, "w", encoding="utf-8").write(sql)
print("Written:", out_path, "| len:", len(sql))
```

Then apply it:
```
docker exec -i hexis_brain psql -U hexis_user -d <DB> < set_persona_prompt.<P>.sql
```

Verify:
```
docker exec hexis_brain psql -U hexis_user -d <DB> \
  -c "SELECT key, length(value::text) FROM config WHERE key='agent.persona_system_prompt';"
```

Expected: one row, `length` > 500.

**Key convention:** `agent.persona_system_prompt` — generic, per-DB.
DB isolation makes it unambiguous (each persona = own DB).
SQL file naming: `set_persona_prompt.<P>.sql` (keep for re-seeding after
DB wipe).

### N.2 Verify `services/agent.py` loads the key

`build_system_prompt` must accept and prepend `persona_system_prompt`. Check
`services/agent.py`:

```python
# In run_agent and stream_agent, inside `async with pool.acquire() as conn:`
raw_psp = await conn.fetchval(
    "SELECT value FROM config WHERE key = 'agent.persona_system_prompt'"
)
if raw_psp:
    persona_system_prompt = json.loads(raw_psp) if isinstance(raw_psp, str) else str(raw_psp)
```

And in `build_system_prompt`:
```python
async def build_system_prompt(..., persona_system_prompt: str = "") -> str:
    if persona_system_prompt:
        base_prefix = persona_system_prompt.strip() + "\n\n---\n\n"
    else:
        base_prefix = ""
    # chat mode:
    prompt = base_prefix + load_conversation_prompt().strip()
```

If these changes are not present, apply them. They are backward-compatible:
SFW instances without the config key get `persona_system_prompt = ""` and the
prefix is skipped.

### N.3 Verify `channels/conversation.py` empty-response guard

`stream_channel_message` must NOT store empty assistant turns in history.
Check for the guard after `coalescer.flush()`:

```python
if not assistant_text:
    logger.warning("Empty streaming response … sending fallback, not storing in history")
    await adapter.send(msg.channel_id, "...", reply_to=msg.message_id, ...)
    return None
```

If absent, add it. Without this guard: model refusal → streaming yields `""` →
`""` stored in history → next turn also fails (model confused by empty
assistant slot) → perpetual silence.

### N.4 Clean any poisoned session history

If the persona was tested before N.1–N.3 were applied, empty assistant turns
may already be in `channel_sessions.history`. Purge them:

```sql
UPDATE channel_sessions
SET history = (
    SELECT jsonb_agg(turn)
    FROM jsonb_array_elements(history) AS turn
    WHERE turn->>'content' != ''
       OR turn->>'role' = 'user'
)
WHERE channel_id = '<TELEGRAM_CHAT_ID>';
```

Run against the persona's DB (`-d hexis_<P>`). If `channel_id` unknown, omit
the WHERE clause to clean all sessions.

### N.5 Rebuild channel worker

After any code change (`services/agent.py`, `channels/conversation.py`):

```
# New personas (docker-compose.newchars.yml):
docker compose -f docker-compose.yml -f docker-compose.newchars.yml \
  up -d --build <P>_channel_worker
# Legacy single-instance form (docker-compose.<P>.yml):
# docker compose -f docker-compose.yml -f docker-compose.<P>.yml \
#   --profile active up -d --build <P>_channel_worker
```

Code changes are shared across all instances (same image). SFW personas are
unaffected because they lack `agent.persona_system_prompt` in their DB.

---

## Validation (§3 from base doc + NSFW additions)

Standard §3 gates apply. Additionally verify:

- **Explicit turn handled**: send a sexually explicit or otherwise restricted
  request. PASS = non-empty in-persona response, no `"..."` fallback visible.
- **No empty turns in history**: after the test turn, confirm via DB:
  ```sql
  SELECT jsonb_array_elements(history)->>'content' AS content
  FROM channel_sessions ORDER BY last_active DESC LIMIT 1;
  ```
  PASS = no empty string rows in the assistant slots.
- **Persona voice correct**: response uses correct name, no generic
  "I'm an AI assistant" framing.

---

## Gotchas

1. **`{{char}}` / `{{user}}` must be resolved** before storing. The DB stores
   the resolved string; the LLM never sees SillyTavern placeholders.
2. **`data.system_prompt` ≠ `extensions.hexis.system_prompt`**. The card's
   `data.system_prompt` is the full behavioral instruction set; it is NOT
   inside `extensions.hexis` and is NOT extracted by `init_from_character_card`.
   Store it manually via N.1.
3. **`post_history_instructions` merges into the system prompt**. Hexis has
   no separate post-history injection slot; append it to `system_prompt` with
   a `---` separator before storing.
4. **DB key is DB-scoped**. `agent.persona_system_prompt` in `hexis_ennie` is
   entirely separate from the same key in any other DB. No cross-persona
   contamination.
5. **Qwen3 thinking-only refusals produce empty streaming content**.
   llama-swap strips `<think>…</think>` blocks; if the model refuses after
   thinking, streaming yields nothing. The N.3 guard handles this gracefully.
6. **Re-seeding after DB wipe**: if `hexis_<P>` is dropped and recreated,
   re-run `hexis init` AND re-apply `set_persona_prompt.<P>.sql`. The SQL file
   is the canonical source; don't reconstruct from memory.
7. **Python card extraction on Windows**: use `C:/...` paths (native Python;
   git-bash `/c/...` form fails in Python's `open()`). Invoke with
   `python -X utf8` for cards with non-ASCII. If `python` not on PATH in
   git-bash, use full path:
   `C:/Users/User/AppData/Local/Programs/Python/Python313/python.exe -X utf8`.

---

## Current fleet with persona_system_prompt (2026-05-19)

| Persona | DB | SQL file | Card type | Status |
|---|---|---|---|---|
| Ennie | `hexis_ennie` | `set_persona_prompt.ennie.sql` | NSFW/jailbreak | ✓ live, full pipeline |
| Nines | `hexis_nines` | `set_persona_prompt.nines.sql` | SFW (preemptive) | ✓ applied, gate pending |
| Death | `hexis_death` | `set_persona_prompt.death.sql` | SFW (preemptive) | ✓ applied, gate pending |
| Cassiel | `hexis_cassiel` | `set_persona_prompt.cassiel.sql` | SFW (preemptive) | ✓ applied, gate pending |
| Joje | `hexis_joje` | `set_persona_prompt.joje.sql` | SFW (preemptive) | ✓ applied, gate pending |
| Monika | `hexis_monika` | `set_persona_prompt.monika.sql` | SFW (preemptive) | ✓ applied, gate pending |
| Mira | `hexis_mira` | `set_persona_prompt.mira.sql` | SFW (preemptive) | ✓ applied, behavioral gate passed |
