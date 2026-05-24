# PR-6 Draft: compaction sender preservation

**Source observation:** upstream `db/34_functions_chat_channel.sql::flush_channel_history_to_memory` synthesizes `source_identity := 'compaction:' || p_session_id::text || ':' || stored::text || ':' || digest`, which loses the real partner identity.

**Branch name:** `fix/recmem-compaction-sender`

**Base:** `main`

## Title

`fix(recmem): preserve real sender identity through compaction flush`

## Body

`flush_channel_history_to_memory` (db/34) is called when the channel session history exceeds `max_history`. It pulls pre-trim user/assistant pairs and routes them through `record_chat_turn_memory`, which in turn calls `recmem_ingest_turn(... p_source_identity)`.

The current `source_identity` value is purely synthetic: `'compaction:<session_uuid>:<idx>:<digest>'`. This guarantees idempotency (good) but throws away the partner identity (bad) — every compaction-flushed raw unit gets the same synthetic prefix instead of the actual sender, breaking any downstream code that relies on `subconscious_units.source_identity` to identify the partner.

This PR derives the real sender from the `channel_sessions` row and includes it as the identity prefix; the synthetic suffix stays as the idempotency disambiguator:

```sql
SELECT sender_id INTO real_sender FROM channel_sessions WHERE id = p_session_id;
source_identity := COALESCE(real_sender, 'session') || ':compaction:' || ...
```

Compaction-flushed raw units now carry the partner identity, restoring symmetry with hot-path-ingested raw units.

## Files

- `db/34_functions_chat_channel.sql` — `flush_channel_history_to_memory`

## Test plan

- [ ] Existing tests pass
- [ ] New test: insert channel_session with sender_id='alice'; populate history JSONB beyond max_history; trigger `finalize_channel_turn` (which calls `flush_channel_history_to_memory`); verify resulting `subconscious_units.source_identity LIKE 'alice:compaction:%'`
