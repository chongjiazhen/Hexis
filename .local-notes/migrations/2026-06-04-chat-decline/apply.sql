-- ============================================================================
-- OPERATOR RUNBOOK: per-message response autonomy (C2) live apply
-- ============================================================================
--
-- What this does:
--   1. Upserts config key chat.decline.enabled = true (default ON; idempotent;
--      does NOT overwrite if operator already set it false).
--   2. CREATE OR REPLACE FUNCTION record_chat_decline (verbatim from db/34).
--   3. CREATE OR REPLACE VIEW chat_decline_log (verbatim from db/34).
--   No schema migration. All objects are CREATE OR REPLACE / upsert-safe.
--   chat_decline_log is a NEW view (no INSTEAD OF trigger ->
--   the view-replace-drops-trigger gotcha does NOT apply here).
--
-- Pre-requisites:
--   - hexis_brain container up (docker ps shows hexis_brain running).
--   - channel_worker images rebuilt AFTER this SQL (prompts + chat.py are baked;
--     see worker rebuild step below).
--
-- Apply per persona (replace <persona> with e.g. eni, mira, nines, ...):
--   docker exec -i hexis_brain psql -U hexis_user -d hexis_<persona> \
--     -v ON_ERROR_STOP=1 -f - \
--     < .local-notes/migrations/2026-06-04-chat-decline/apply.sql
--
-- Rebuild channel_worker per persona (prompts + chat.py baked into image):
--   docker compose -f docker-compose.newchars.yml up -d \
--     --no-deps --force-recreate --build <persona>_channel_worker
--
-- Verify (check view returns — zero rows is fine on a fresh DB):
--   docker exec hexis_brain psql -U hexis_user -d hexis_<persona> -c \
--     "SELECT created_at, register, reason, visible_text, origin FROM chat_decline_log LIMIT 5;"
--
-- Notes:
--   - Decline prompt block is positioned late in the system prompt. Local models
--     vary in how well they honor late-positioned instructions; may need per-persona
--     prompt tuning (move block earlier or strengthen framing) after observing
--     first few live declines in chat_decline_log.
--   - Run against all 9 persona DBs: eni mira nines death cassiel joje monika
--     vesper lyra (adjust for your fleet roster).
-- ============================================================================

-- Live apply: per-message response autonomy (C2).
-- record_chat_decline fn + chat_decline_log view + chat.decline.enabled config.
-- CREATE OR REPLACE only. No schema migration. chat_decline_log is a NEW view
-- (no INSTEAD OF trigger -> the view-replace-drops-trigger gotcha does not apply).
BEGIN;

-- 1. config (idempotent upsert; default ON)
INSERT INTO config (key, value, description)
VALUES ('chat.decline.enabled', 'true'::jsonb, 'Allow the persona to decline to respond to a chat message (per-message response autonomy)')
ON CONFLICT (key) DO NOTHING;

-- 2. record_chat_decline function (verbatim from db/34_functions_chat_channel.sql)
-- Per-message response autonomy (C2): durably record a decline-to-respond.
-- Always inserts one episodic memory (zero-vector embedding, mirroring
-- pause_heartbeat) so every decline is observable via chat_decline_log,
-- independent of importance-based promotion.
CREATE OR REPLACE FUNCTION record_chat_decline(
    p_user_text TEXT,
    p_visible_text TEXT,
    p_register TEXT,
    p_reason TEXT DEFAULT NULL,
    p_session_id TEXT DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_origin TEXT DEFAULT 'prime'
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    zero_vec vector;
    mem_id UUID;
    observed TIMESTAMPTZ := CURRENT_TIMESTAMP;
    norm_reason TEXT := NULLIF(p_reason, '');
BEGIN
    IF NULLIF(p_register, '') IS NULL THEN
        RAISE EXCEPTION 'record_chat_decline requires a non-empty register';
    END IF;
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    INSERT INTO memories (
        type, status, content, embedding, importance,
        source_attribution, trust_level, trust_updated_at,
        access_count, decay_rate, metadata
    )
    VALUES (
        'episodic', 'active',
        'I chose not to engage with a message. Register: ' || p_register
            || COALESCE('. Reason: ' || norm_reason, '.'),
        zero_vec, 0.8,
        jsonb_build_object(
            'kind', 'chat_decline',
            'ref', COALESCE(p_source_identity, 'chat_decline'),
            'label', 'declined to respond',
            'observed_at', observed,
            'trust', 0.95
        ),
        0.95, observed, 0, 0.0,
        jsonb_build_object(
            'type', 'chat_decline',
            'register', p_register,
            'reason', norm_reason,
            'origin', p_origin,
            'session_id', p_session_id,
            'user_text', p_user_text,
            'visible_text', p_visible_text
        )
    )
    RETURNING id INTO mem_id;
    RETURN mem_id;
END;
$$;

-- 3. chat_decline_log view (verbatim from db/34_functions_chat_channel.sql)
-- Operator-facing decline log: one row per honored decline.
CREATE OR REPLACE VIEW chat_decline_log AS
SELECT
    id AS memory_id,
    created_at,
    metadata->>'register'     AS register,
    metadata->>'reason'       AS reason,
    metadata->>'origin'       AS origin,
    metadata->>'session_id'   AS session_id,
    metadata->>'user_text'    AS user_text,
    metadata->>'visible_text' AS visible_text
FROM memories
WHERE source_attribution->>'kind' = 'chat_decline'
ORDER BY created_at DESC;

COMMIT;
