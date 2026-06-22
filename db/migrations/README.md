# db/migrations/

Ordered, incremental schema deltas for **existing populated** Hexis databases.

`db/*.sql` (one level up) is a *from-scratch bootstrap* — it rebuilds a full DB
for a fresh instance, but cannot evolve a DB that already holds data (most
`CREATE TABLE` statements are bare, so re-running them throws
`relation already exists`). This directory fills that gap: each file is one
change, applied exactly once, tracked in the `schema_migrations` table.

## Writing a migration

1. Create a file named so it **sorts in apply order** — zero-padded numeric or
   date prefix: `0001_add_foo.sql`, `20260622_add_contacts_index.sql`.
2. Put the delta in it. Make it **defensive** so a stray re-run is harmless:
   ```sql
   ALTER TABLE memories ADD COLUMN IF NOT EXISTS foo text;
   CREATE INDEX IF NOT EXISTS idx_memories_foo ON memories (foo);
   ```
3. **Dual-write rule** — also fold the same change into the relevant `db/*.sql`
   bootstrap file, so future fresh instances get it from the bootstrap. A fresh
   instance baseline-stamps this migration as already-applied (it never
   re-runs), so the two paths stay consistent.

## Applying

```bash
python scripts/migrate.py --all          # every registered instance
python scripts/migrate.py --instance ada # one instance
python scripts/migrate.py --dsn postgresql://…   # explicit DSN
python scripts/migrate.py --dry-run --all        # list pending, apply nothing
```

Fresh instances are migrated automatically — `core.schema.apply_schema` runs the
bootstrap then baseline-stamps every migration here. The runner lives in
`core/schema.py` (`apply_migrations`); tests in `tests/db/test_migrations.py`.
