-- rollback.sql — revert llm.* back to CPU nano (:8082) for one persona.
-- Only used if the GPU :8080 model proves unfit for that persona's volume.

BEGIN;

UPDATE config
SET value = jsonb_set(
              jsonb_set(value, '{endpoint}', '"http://host.docker.internal:8082/v1"'::jsonb),
              '{model}',    '"nano-imp-1b"'::jsonb
            ),
    updated_at = NOW()
WHERE key IN ('llm.chat','llm.heartbeat','llm.subconscious')
  AND value->>'endpoint' = 'http://host.docker.internal:8080/v1';

SELECT key, value FROM config
WHERE key IN ('llm.chat','llm.heartbeat','llm.subconscious')
ORDER BY key;

COMMIT;
