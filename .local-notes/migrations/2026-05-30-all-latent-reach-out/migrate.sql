-- 2026-05-30 all-latent reach-out: live-DB migration.
-- Functions come from canonical schema (idempotent CREATE OR REPLACE):
--   psql -f db/07_functions_heartbeat.sql
--   psql -f db/09_functions_context.sql
--   psql -f db/17_functions_subconscious_observations.sql
-- This script handles config + in-place data shape only.
BEGIN;

-- Retire the old cooldown gate config; seed the dormant brake.
DELETE FROM config WHERE key = 'heartbeat.user_contact_cooldown_hours';
INSERT INTO config (key, value, description)
VALUES ('heartbeat.reach_out_max_unanswered', '0'::jsonb,
        'Dormant circuit breaker: if >0, suppress reach-out to a sender whose unanswered streak >= this. 0 = off.')
ON CONFLICT (key) DO NOTHING;

-- Migrate existing reach_out_sender_log entries from bare-timestamp to {last_at, unanswered_count}.
UPDATE state
SET value = jsonb_set(
    value, ARRAY['reach_out_sender_log'],
    COALESCE((
        SELECT jsonb_object_agg(
            k,
            CASE
                WHEN jsonb_typeof(v) = 'string'
                THEN jsonb_build_object('last_at', v, 'unanswered_count', 1)
                ELSE v   -- already object shape
            END
        )
        FROM jsonb_each(value->'reach_out_sender_log')
    ), '{}'::jsonb)
)
WHERE key = 'heartbeat_state'
  AND value ? 'reach_out_sender_log';

COMMIT;
