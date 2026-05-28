-- 2026-05-26-timezone-aware-reach-out: per-recipient quiet-hours gate
-- Applies resolve_sender_timezone, is_sender_quiet, active_senders enrichment,
-- and reach_out_user quiet-gate + energy refund.
--
-- Safe to re-run: all CREATE OR REPLACE.
-- Requires: heartbeat functions (07), context functions (09),
--   subconscious/observations functions (17) already in the image.

\ir db/07_functions_heartbeat.sql
\ir db/09_functions_context.sql
\ir db/17_functions_subconscious_observations.sql

-- Smoke: helpers exist
SELECT pg_get_function_identity_arguments('resolve_sender_timezone'::regproc);
SELECT pg_get_function_identity_arguments('is_sender_quiet'::regproc);

-- Smoke: active_senders enriched
SELECT jsonb_pretty(get_active_senders_context(2, 7));

-- Smoke: quiet-gate probe (replace 'someone' with a real sender_id after setting tz)
-- BEGIN;
-- SELECT set_config('channel.sender.someone.timezone', '"Etc/GMT-8"'::jsonb);
-- SELECT execute_heartbeat_action(
--     gen_random_uuid(),
--     'reach_out_user',
--     jsonb_build_object('sender_id','someone','message','probe','intent','probe')
-- );
-- ROLLBACK;
