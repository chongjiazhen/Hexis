-- 2026-05-26 heartbeat tailored reach-out
-- Re-applies the three SQL files touched by this feature.
--
-- db/09_functions_context.sql            — adds get_active_senders_context().
-- db/13_functions_emotional_state.sql    — wires 'active_senders' into gather_turn_context().
-- db/17_functions_subconscious_observations.sql
--                                        — threads sender_id into reach_out_user outbox payload.
--
-- All changes are CREATE OR REPLACE FUNCTION — safe to re-run.
-- No ALTER TABLE, no new index, no new column. Brain DB stays up.

\set ON_ERROR_STOP on
\ir ../../../db/09_functions_context.sql
\ir ../../../db/13_functions_emotional_state.sql
\ir ../../../db/17_functions_subconscious_observations.sql

-- Smoke: both new surfaces reachable.
SELECT
    (SELECT count(*) FROM pg_proc WHERE proname = 'get_active_senders_context') AS get_active_senders_context_present,
    (gather_turn_context() ? 'active_senders') AS active_senders_in_gather_turn_context;
