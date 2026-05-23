-- migrate.sql — flip llm.chat / llm.heartbeat / llm.subconscious from CPU nano (:8082)
-- to GPU q36 (:8080) for one persona DB. Idempotent: only touches rows that still
-- point at the nano endpoint, so re-running is a no-op.
--
-- Run per-DB:
--   docker exec -i hexis_brain psql -U hexis_user -d hexis_<persona> -f /dev/stdin < migrate.sql
-- Or interactively:
--   docker exec -it hexis_brain psql -U hexis_user -d hexis_<persona>
--   \i /tmp/migrate.sql
--
-- After applying: restart channel + heartbeat workers for that persona so they
-- pick up new config:
--   docker restart hexis_<persona>_channel_worker hexis_<persona>_heartbeat_worker hexis_<persona>_maintenance_worker

BEGIN;

\echo '--- before ---'
SELECT key, value FROM config
WHERE key IN ('llm.chat','llm.heartbeat','llm.subconscious')
ORDER BY key;

UPDATE config
SET value = jsonb_set(
              jsonb_set(value, '{endpoint}', '"http://host.docker.internal:8080/v1"'::jsonb),
              '{model}',    '"qwen36-35b-a3b-iq3"'::jsonb
            ),
    updated_at = NOW()
WHERE key IN ('llm.chat','llm.heartbeat','llm.subconscious')
  AND value->>'endpoint' = 'http://host.docker.internal:8082/v1';

\echo '--- after ---'
SELECT key, value FROM config
WHERE key IN ('llm.chat','llm.heartbeat','llm.subconscious')
ORDER BY key;

COMMIT;
