-- Pure-RecMem reconcile migration — DRAFT (staged, NOT yet applied)
-- Mirrors upstream QuixiAI/Hexis 244ba5c "Adopt pure RecMem, remove A/B + eager memory paths"
-- for the DB-authority half. Drops the rollout / eval / dual-write scaffolding functions
-- and their config toggles. RecMem becomes the only memory-formation path.
--
-- ============================================================================
-- !! ORDERING GATE — DO NOT APPLY STANDALONE !!
-- ============================================================================
-- services/chat.py still defines + calls these functions:
--     _record_recmem_rollout_event   -> record_recmem_rollout_event(...)
--     _log_dual_write_comparison     -> record_recmem_dual_write_comparison(...)
-- (chat.py:32-149, inherited from upstream, NOT yet removed on our branch).
--
-- Applying this migration BEFORE the chat.py hand-merge lands = live chat path
-- calls a dropped function -> runtime error on every turn.
--
-- Correct sequence:
--   1. Hand-merge upstream 244ba5c chat.py deletions (remove the helpers above).
--   2. Rebuild + roll out workers (--no-deps --force-recreate, per prompt-baked rule).
--   3. THEN apply this migration to each live hexis_<P> DB.
-- Propagate via DROP FUNCTION (live CREATE OR REPLACE split rule) — NOT down -v.
-- ============================================================================
--
-- BEHAVIORAL NOTE: removing the toggles below makes RecMem unconditional. Check
-- each live DB's current values first — DBs where memory.recmem_enabled='false'
-- will flip behavior (RecMem turns ON) once code stops reading the toggle.

BEGIN;

-- 1. Rollout / dual-write event recorders (db/31) ----------------------------
DROP FUNCTION IF EXISTS record_recmem_rollout_event(
    TEXT, UUID, TEXT, UUID, TEXT, BOOLEAN, BOOLEAN, UUID, FLOAT, TEXT, JSONB);
DROP FUNCTION IF EXISTS record_recmem_dual_write_comparison(
    TEXT, UUID, UUID[], UUID[], FLOAT, JSONB);

-- 2. Eval / rollout metric readers (db/31) -----------------------------------
DROP FUNCTION IF EXISTS get_recmem_rollout_metrics(TIMESTAMPTZ);
DROP FUNCTION IF EXISTS get_recmem_eval_run_summary(UUID);
DROP FUNCTION IF EXISTS get_recmem_eval_quality_gate(UUID, FLOAT, FLOAT);
DROP FUNCTION IF EXISTS get_recmem_phase5_readiness(UUID);

-- 3. Rollout phase orchestration + eval runner (db/35) -----------------------
DROP FUNCTION IF EXISTS apply_recmem_rollout_phase(INT, UUID, BOOLEAN);
DROP FUNCTION IF EXISTS get_recmem_rollout_status(UUID);
DROP FUNCTION IF EXISTS infer_recmem_rollout_phase();
DROP FUNCTION IF EXISTS recmem_rollout_phase_config(INT);
DROP FUNCTION IF EXISTS run_recmem_eval_set(TEXT, TEXT, INT);

-- 4. Retire rollout / A-B config toggles (db/00 seed rows) --------------------
DELETE FROM config WHERE key IN (
    'memory.recmem_rollout_phase',
    'memory.recmem_enabled',
    'chat.recmem_salience_direct_promote',
    'memory.recmem_hydrate_enabled',
    'memory.recmem_dual_write_compare',
    'memory.recmem_rollout_metrics_enabled',
    'memory.recmem_worker_enabled'
);

COMMIT;

-- Verify post-apply (expect 0 rows each):
--   SELECT proname FROM pg_proc WHERE proname IN (
--     'record_recmem_rollout_event','record_recmem_dual_write_comparison',
--     'get_recmem_rollout_metrics','get_recmem_eval_run_summary',
--     'get_recmem_eval_quality_gate','get_recmem_phase5_readiness',
--     'apply_recmem_rollout_phase','get_recmem_rollout_status',
--     'infer_recmem_rollout_phase','recmem_rollout_phase_config','run_recmem_eval_set');
--   SELECT key FROM config WHERE key LIKE 'memory.recmem_rollout%' OR key LIKE '%recmem_enabled%';
