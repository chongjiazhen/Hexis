# Schema Migration

## SQL files are baked into the Docker image

SQL schema files (`db/*.sql`) are **baked into the Docker image at build time**
(not bind-mounted). Editing SQL files on disk does NOT automatically take effect
in the running container.

## Full bounce (nuclear — wipes data)

```bash
docker compose down -v && docker compose build db && docker compose up -d
```

1. `docker compose down -v` — stops containers and **removes the data volume**
2. `docker compose build db` — rebuilds the `db` service image with updated SQL
3. `docker compose up -d` — starts containers with the new image

**Important**: The compose service is named `db`, but the container is named
`hexis_brain`. Use the service name (`db`) with compose commands, but the container
name with `docker exec`.

## Live migration (no data loss, no `down -v`)

Safe to re-apply `db/04_functions_core.sql` + `db/05_functions_provenance_trust.sql`
(CREATE OR REPLACE / DROP + CREATE = idempotent).

**DO NOT** re-apply `db/01_indices.sql` blindly — many `CREATE INDEX` lines lack
`IF NOT EXISTS` and `ON_ERROR_STOP=1` aborts on the first existing index.

New columns require explicit `ALTER TABLE memories ADD COLUMN IF NOT EXISTS <name> <type>;` —
`db/00_tables.sql` only does `CREATE TABLE`, so re-applying it after a column add is
a no-op on the live DB.

Re-apply live:
```bash
docker exec -i hexis_brain psql -U hexis_user -d <persona> -v ON_ERROR_STOP=1 -f - < db/<file>.sql
```

## Whole-feature additive migration (alternative to `down -v`)

For a coherent upstream merge / feature drop that is purely additive (new tables +
new columns + new functions + new indexes, no DROP TABLE, no column-type changes),
hand-craft ONE migration SQL with `ALTER TABLE … ADD COLUMN IF NOT EXISTS`,
`CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `CREATE INDEX IF NOT EXISTS`,
`DROP FUNCTION IF EXISTS`, then loop over
`SELECT datname FROM pg_database WHERE datname LIKE 'hexis_%'`
with `--single-transaction --set ON_ERROR_STOP=on`. Brain stays up (no consumer-wedge),
all memories preserved, workers recreate rolling via `--no-deps --force-recreate --build`.
Validated 2026-05-23 on 26 persona DBs — see `.local-notes/upstream-reconcile-2026-05-23/`.

## Changing a SQL function signature

`CREATE OR REPLACE FUNCTION` **cannot** alter the argument list or RETURNS TABLE shape —
Postgres treats new params as overloads, leaving stale arity callable and ambiguous.
Always `DROP FUNCTION IF EXISTS name(argtypes); CREATE FUNCTION ...` for signature
changes. Return-type change is forced; new param with default is strongly recommended
to avoid overload ambiguity.

## Verifying schema changes

```bash
# Check if a specific function exists
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "\df function_name"

# Check config keys
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT key, value FROM config WHERE key LIKE 'rlm.%'"

# Check table columns
docker exec hexis_brain psql -U hexis_user -d hexis_memory -c "SELECT column_name FROM information_schema.columns WHERE table_name = 'memories' ORDER BY ordinal_position"
```

## Postgres connections

`max_connections=300` (compose-overridden from PG default 100) — needed for ~33-worker
fleet pools. Override via `POSTGRES_MAX_CONNECTIONS` env. Bumping requires recreating
the DB container — and per the wedge trap, all per-persona workers will need a manual
`docker restart` since they don't auto-reconnect on DB IP change.
