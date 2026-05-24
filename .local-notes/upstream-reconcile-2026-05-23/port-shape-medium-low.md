# Port Shapes: medium + low risk patches

## 4661566 — per-persona session-history cap

**Local:** Adds `channel.history.max` / `channel.history.trim` config keys; reads in `channels/conversation.py` to cap `channel_sessions.history` JSONB length per turn. Also strengthens Vera assessment trigger (drop that part — Vera-specific).

**Upstream impact:** `5ff99d4` moved history assembly into `db/34_functions_chat_channel.sql::prepare_channel_turn()`. History trim now happens DB-side via `finalize_channel_turn()` writing back into `channel_sessions.history`.

**Port:** Pure config wiring, no logic conflict. Add to `finalize_channel_turn` (db/34:363):

```sql
v_history_max := COALESCE(get_config_int('channel.history.max'), 16);
v_history_trim := COALESCE(get_config_int('channel.history.trim'), 8);
-- after appending new turn, if jsonb_array_length(new_history) > v_history_max:
--   take last v_history_trim entries
--   pass trimmed-off prefix to flush_channel_history_to_memory(p_session_id, prefix)
```

Drop the Vera assessment-trigger change from this PR (it lives in PR for 55d0dc9 / persona land).

**Upstream sell:** "configurable cap, prevents context-window overflow on long sessions, complements existing `flush_channel_history_to_memory`."

## 55d0dc9 — capture + strip session-assessment block on streaming path

**Local:** Detects `<<<SESSION_ASSESSMENT>>>...<<<END>>>` blocks in assistant output (Vera's structured reflection); strips before delivery; captures content as a separate memory.

**Upstream impact:** `_remember_conversation()` collapsed to delegate (`ac4c0c4`); chat.py reduced (`5ff99d4`). Logic must move to `db/35_functions_recmem_ops.sql` or `recmem_ingest_turn` preprocessor.

**Risk for upstream:** session-assessment is **Vera-specific** (persona-coupled). NOT upstreamable as-is. Either:

- (a) Generalize: add config `chat.assessment_block_pattern` (default NULL = disabled). Function `extract_and_strip_assessment(text, pattern)` returns `{stripped, assessment}`. Caller stores assessment separately. Generic upstream-shape.
- (b) Keep entirely local — Vera fleet feature, don't pursue upstream PR.

**Recommendation:** (b). Persona-coupled features don't survive review. Re-port locally inside whatever calls `recmem_ingest_turn` from the chat path; leave upstream alone.

## 3bf21cd — chat hydrated context into system prompt

**Local:** Hydrated memory context moved from user-turn into system prompt assembly. `services/agent.py::attach_chat_context()` writes hydrate output into system role, not appended to user message.

**Upstream impact:** `services/agent.py` survives merge (not in `5ff99d4`'s diff). `51fc76a` reduces `core/agent_loop.py` but doesn't remove `attach_chat_context()` callsite.

**Risk:** LOW. Likely textual-clean cherry-pick post-merge. Verify: `agent_loop.py` still imports + calls `attach_chat_context` after `51fc76a`. If yes, cherry-pick clean. If no, port the system-prompt assembly into wherever upstream moved it.

**Upstream sell:** "hydrated context belongs in system prompt, not user turn; survives model fine-tuning quirks where user-turn context gets weighted as the user's question."

## ec9e1ec — agent.tools seed correction

**Local:** `db/00_tables.sql` seed for `agent.tools` config row updated to current registry tool names (drift fix).

**Upstream impact:** `27eb5e2` moved tool handlers into `db/38_functions_db_native_tools.sql`. Tool registry source-of-truth may have shifted — verify `agent.tools` config key is still the consumed source after `27eb5e2`.

**Risk:** LOW if key still consumed. Cherry-pick clean if so. If `27eb5e2` introduced a new tool-config mechanism, port spirit (correct names) into new shape.

**Upstream sell:** trivial seed-drift fix, ~8-line patch.

## Suggested PR order (after M3 validates bd106a8 port)

1. **ec9e1ec** (low risk, tiny, demonstrates engagement)
2. **3bf21cd** (low risk, architectural fix, builds credibility)
3. **4661566 generalized** (medium, config-only addition, no behavior change for default users)
4. **bd106a8 PR-A** (sender-scoped recall — main pitch, only after first 3 land)
5. **bd106a8 PR-B** (derived memory propagation — depends on PR-A)
6. **bd106a8 PR-C** (compaction flush fix — independent, can ship anytime)

55d0dc9 stays local. Persona/alerts/compose/character work all stays local permanently.
