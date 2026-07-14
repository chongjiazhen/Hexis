-- ADR-020 phase 6: retire the agent.power_mode config flag.
--
-- The flag bundled a serving decision with a cognition gate. Both readers are gone:
-- the heartbeat worker gates on live serving capability (core/serving.py on_cpu_floor,
-- ADR-020 §2) and services/chat.py's slim path now reads the same signal. The row is
-- inert; drop it so a stale value can never be resurrected by a new reader.
--
-- Per-database: schema_migrations is per-DB, so this only touches the DB of the
-- current DSN. Fleet-wide cleanup = enumerate ~/.hexis/instances.json and apply per DB.
SET search_path = public, ag_catalog, "$user";

DELETE FROM config WHERE key = 'agent.power_mode';
