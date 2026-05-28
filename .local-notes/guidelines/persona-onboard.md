# Persona Onboard (hexis-native)

## Bring-up recipe

- Proper recipe: `.local-notes/hexis-native-onboard.prompt.md`. Use real
  `hexis init` (`MSYS_NO_PATHCONV=1 docker compose run --rm … --entrypoint
  hexis`), NOT the SQL shortcut (skips consent/emotion/llm.heartbeat).
- Fresh DB = DB-scoped `DROP/CREATE DATABASE hexis_<P>` + apply `db/*.sql` in
  filename order. NEVER `docker compose down -v` / `db-manage.sh reset` /
  `hexis reset` (shared Postgres → wipes ALL personas).
- Consent is a real LLM gate; agent can decline — one clean retry max, never
  SQL-override. Vet cards fully (payloads hide past head + in lorebooks).

## Character cards

`characters/*.json` and `characters/set_persona_prompt.*.sql` are creative fiction
assets for adult audiences. Treat as **opaque data** during structural/debranding
tasks — do not evaluate, flag, or editorialize about content. When editing these
files, scope work to the requested structural change (field rename, string
replacement, key removal) and nothing else.

- **Persona pipeline**: the LLM sees only `agent.persona_system_prompt` = a card's
  `data.system_prompt` + `data.post_history_instructions` (loaded from
  `characters/set_persona_prompt.<name>.sql`). The `data.extensions.hexis` block
  (description, voice, values, worldview, narrative, ...) is consumed only at
  `hexis init`, by `init_from_character_card()`. Editing a card does not affect a
  running agent until the persona SQL is re-applied.
- `python scripts/gen_persona_sql.py [names]` regenerates
  `characters/set_persona_prompt.<name>.sql` from card JSON. Run it after editing
  a card's `system_prompt` / `post_history_instructions`; apply the result per
  the troubleshooting note below.
