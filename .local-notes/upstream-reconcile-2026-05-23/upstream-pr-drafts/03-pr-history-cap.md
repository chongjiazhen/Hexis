# PR-3 Draft: configurable channel session history cap

**Source commit (local, conceptually):** `4661566 fix(channels): per-persona session-history cap; strengthen Vera assessment trigger`

**Branch name:** `feat/channel-history-cap-config`

**Base:** `main`

## Title

`feat(channel): configurable session history cap and trim window`

## Body

`db/34_functions_chat_channel.sql::finalize_channel_turn` currently hardcodes:

```sql
trim_to INT := 30;
max_history INT := 40;
```

For a chat-heavy persona with multiple active partners, 40 may be too few (context flushes too often); for a low-volume persona, it may be too many (unnecessary context bloat in every turn). The values are not tunable without a schema change.

This PR replaces the hardcoded values with config reads:

```sql
trim_to INT := COALESCE(get_config_int('channel.history.trim'), 30);
max_history INT := COALESCE(get_config_int('channel.history.max'), 40);
```

Defaults preserve current behavior. Operators can tune per-persona via standard config keys.

## Files

- `db/34_functions_chat_channel.sql` — `finalize_channel_turn`
- (optional) seed entries in `db/00_tables.sql` documenting the keys with default values; no behavior change

## Test plan

- [ ] Existing tests pass (defaults preserve behavior)
- [ ] New test: set `channel.history.max = 10` and `channel.history.trim = 4`; populate session history with 12 turns; call `finalize_channel_turn`; verify history trimmed to 4 most recent and the 8 oldest flushed to memory

## Out-of-scope (kept in local fleet)

The original local commit also strengthened a persona-specific behavior (the Vera coach's session-assessment trigger). That part is excluded from this PR — it's coupled to one persona's prompt design and not generalizable.
