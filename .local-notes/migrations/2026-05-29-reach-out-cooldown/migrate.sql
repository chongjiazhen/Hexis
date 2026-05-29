-- Migration: add reach_out_sender_log to heartbeat_state view
-- Run on live databases after the view change in db/90_views.sql

BEGIN;

-- Ensure reach_out_sender_log key exists in state JSONB
DO $$
DECLARE
    existing_log JSONB;
BEGIN
    SELECT value->'reach_out_sender_log' INTO existing_log
    FROM state WHERE key = 'heartbeat_state';
    IF existing_log IS NULL THEN
        UPDATE state SET value = jsonb_set(value, '{reach_out_sender_log}', '{}'::jsonb)
        WHERE key = 'heartbeat_state';
    END IF;
END $$;

-- Drop with cascade to handle dependent views
DROP VIEW IF EXISTS heartbeat_state CASCADE;

-- Recreate the view with new column
CREATE VIEW heartbeat_state AS
SELECT
    1 as id,
    COALESCE((s.value->>'current_energy')::float, 10) as current_energy,
    (s.value->>'last_heartbeat_at')::timestamptz as last_heartbeat_at,
    (s.value->>'next_heartbeat_at')::timestamptz as next_heartbeat_at,
    COALESCE((s.value->>'heartbeat_count')::int, 0) as heartbeat_count,
    (s.value->>'last_user_contact')::timestamptz as last_user_contact,
    COALESCE(s.value->'affective_state', '{}'::jsonb) as affective_state,
    COALESCE((s.value->>'is_paused')::boolean, false) as is_paused,
    COALESCE((s.value->>'init_stage')::init_stage, 'not_started'::init_stage) as init_stage,
    COALESCE(s.value->'init_data', '{}'::jsonb) as init_data,
    (s.value->>'init_started_at')::timestamptz as init_started_at,
    (s.value->>'init_completed_at')::timestamptz as init_completed_at,
    NULLIF(s.value->>'active_heartbeat_id', '')::uuid as active_heartbeat_id,
    (s.value->>'active_heartbeat_number')::int as active_heartbeat_number,
    COALESCE(s.value->'active_actions', '[]'::jsonb) as active_actions,
    NULLIF(s.value->>'active_reasoning', '') as active_reasoning,
    COALESCE(s.value->'reach_out_sender_log', '{}'::jsonb) as reach_out_sender_log,
    s.updated_at
FROM state s
WHERE s.key = 'heartbeat_state';

-- Recreate dependent views
CREATE VIEW heartbeat_health AS
SELECT
    hs.is_paused,
    hs.current_energy,
    hs.last_heartbeat_at,
    hs.next_heartbeat_at,
    hs.heartbeat_count,
    hs.init_stage,
    CASE
        WHEN hs.is_paused THEN 'paused'
        WHEN hs.init_stage NOT IN ('complete', 'heartbeat') THEN 'initializing'
        WHEN hs.next_heartbeat_at IS NULL THEN 'running'
        WHEN hs.next_heartbeat_at < NOW() THEN 'due'
        ELSE 'waiting'
    END as status,
    EXTRACT(EPOCH FROM (hs.next_heartbeat_at - NOW()))/60 as minutes_until_next
FROM heartbeat_state hs;

CREATE VIEW current_emotional_state AS
SELECT
    hs.affective_state,
    COALESCE((hs.affective_state->>'valence')::float, 0) as valence,
    COALESCE((hs.affective_state->>'arousal')::float, 0) as arousal,
    COALESCE(hs.affective_state->>'mood', 'neutral') as mood
FROM heartbeat_state hs;

CREATE VIEW cognitive_health AS
SELECT
    hs.current_energy,
    hs.heartbeat_count,
    hs.affective_state,
    hs.is_paused,
    hs.init_stage
FROM heartbeat_state hs;

COMMIT;
