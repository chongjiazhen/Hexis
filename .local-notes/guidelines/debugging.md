# Debugging Tips

## Generic/empty persona replies — two causes

- embed :8081 down → `hydrate()` fails → no persona injected → generic. Fix: `.\start-all.ps1`.
- q36 = Qwen3 reasoning model: eats token budget on reasoning_content. Fixed
  `core/llm.py` (openai-compat path): `extra_body={"chat_template_kwargs":
  {"enable_thinking":False}}`. `--reasoning-budget 0` NOT accepted by this
  llama.cpp build. Rebuild channels image + recreate workers to activate.
- All characters reply just `...`? Chat LLM server (`:8080`, `ActiveBig`) is down.
  Confirm with read-only `.\hexis-status.ps1`. Recover: `.\set-power-mode.ps1 prime`
  — but first ensure the active ActiveBig key exists in `C:\llm-serve\models.json`
  and its gguf is cached, else the re-arm hard-fails.

## Memory not found?

Embeddings = host llama-server :8081 (per `.env`). Check `curl localhost:8081/health`.

## Reply has a ```thought block / recites valence·signals·trait floats?

Reasoning-trace leak — gemma-4 `abliterix` emits visible CoT (`enable_thinking:false`
is unreliable on it, no server-side fix). `strip_reasoning()` in `core/llm.py` strips
it at the LLM boundary (commit `0b3beb2`), logs an INFO per strip. Don't remove it.

## Persona stuck re-emitting a bad reply (markdown headers, stray `---`, verbatim loops)?

Two feedback loops to break:
1. `channel_sessions.history` (fleet default 40 turns, trim to 30 —
   `MAX_SESSION_HISTORY`/`TRIM_TO_HISTORY` in `channels/conversation.py`;
   override per-persona via `channel.history.max`/`channel.history.trim`
   config keys) feeds last-N turns back every turn.
2. `fast_recall` surfaces similar past episodic by embedding — a stored bad
   reply from DAYS ago can resurface on related prompts.

Fix sequence: hunt active episodic by content phrase (`SELECT id, created_at,
left(content,80) FROM memories WHERE status='active' AND type='episodic' AND
content ILIKE '%<identifying phrase>%' ORDER BY created_at DESC`), archive
matches (`UPDATE memories SET status='archived' WHERE id IN (...)`), clear history
(`UPDATE channel_sessions SET history='[]'::jsonb WHERE channel_id=...`),
re-apply anchor (`docker exec -i hexis_brain psql -U hexis_user -d hexis_<P>
-f - < characters/set_persona_prompt.<P>.sql`). Effective next message, no restart.

## Test failures?

Ensure Docker services are up before running pytest; after a fresh `down -v`,
wait for Postgres to accept connections. Use `POSTGRES_HOST=127.0.0.1` with
pytest if localhost SSL negotiation flakes.

## Schema changes not taking effect?

SQL files are baked into the Docker image at build time (not bind-mounted).
See `schema-migration.md` for the full bounce-and-reapply procedure.

## Windows / git-bash gotchas

- Native python: `C:/...` paths (git-bash `/c/...` fails) + `python -X utf8`.
- `MSYS_NO_PATHCONV=1` for docker `-v` mounts in git-bash (else "Character not found").
- Same `MSYS_NO_PATHCONV=1` for `docker exec hexis_X /app/...` — git-bash
  rewrites `/app/...` to `C:/Program Files/Git/app/...` and the exec fails.
- Don't pass huge values via psql `-v` argv (docker arg limit) — embed via stdin.
- `& script.ps1` in-session; don't use `powershell -ExecutionPolicy Bypass` (blocked).

## Fast Python iteration (no image rebuild)

`docker cp local/file.py hexis_X_worker:/app/path/file.py && docker restart hexis_X_worker`
— Python reloads from disk on restart (worker images set `PYTHONDONTWRITEBYTECODE=1`
so no .pyc cache to bust). Use to test a 1-file change on one container before
full fleet rebuild + roll-out to all 11.
