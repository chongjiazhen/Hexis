-- ============================================================================
-- HEXIS UPSTREAM RECONCILE MIGRATION -- additive deltas (shell)
-- ============================================================================
-- Source: trial-merge-port-2026-05-23 (commits feba84b + 2ad5a94 + 5d00116)
-- Anchor: pre-upstream-merge-2026-05-23
-- Generated: 2026-05-23
--
-- This file is a SHELL containing hand-crafted parts.
-- The full applicable SQL is built by `migrate-additive-build.sh` which
-- concats the @@INLINE-tagged files from the trial worktree.
--
-- Apply built output to each persona DB live (no brain bounce):
--   ./migrate-additive-build.sh > migrate-additive.full.sql
--   for p in $personas; do
--     docker exec -i hexis_brain psql -U hexis_user -d hexis_$p \
--       --single-transaction --set ON_ERROR_STOP=on < migrate-additive.full.sql
--   done
--
-- All parts are idempotent: CREATE OR REPLACE + CREATE * IF NOT EXISTS.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- PART 1: ALTER memories -- RecMem validity hooks
-- ----------------------------------------------------------------------------
ALTER TABLE memories ADD COLUMN IF NOT EXISTS valid_from TIMESTAMPTZ;
ALTER TABLE memories ADD COLUMN IF NOT EXISTS valid_until TIMESTAMPTZ;
ALTER TABLE memories ADD COLUMN IF NOT EXISTS superseded_by UUID
    REFERENCES memories(id) ON DELETE SET NULL;

-- ----------------------------------------------------------------------------
-- PART 1b: Drop OLD overload signatures so re-CREATE produces a single
-- canonical version per name. Without these, CREATE OR REPLACE adds a NEW
-- overload (same name, different arg count) and leaves the OLD one orphaned
-- with stale function body. Callers using the old arg count then hit stale
-- code.
-- ----------------------------------------------------------------------------

-- PR-B added p_sender_id at end of create_memory_with_embedding (7 -> 8 args).
DROP FUNCTION IF EXISTS create_memory_with_embedding(
    memory_type, text, vector, float, jsonb, float, jsonb
);

-- PR-A added p_current_sender at end of recmem_recall_context (5 -> 6 args).
-- (Already DROPped inside db/31 itself; harmless to repeat here for clarity.)
DROP FUNCTION IF EXISTS recmem_recall_context(text, int, int, int, uuid);

-- ----------------------------------------------------------------------------
-- PART 2: NEW TABLES -- RecMem core + rollout + eval (from db/00 diff)
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS subconscious_units (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    session_id UUID,
    source_identity TEXT,
    turn_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    content TEXT NOT NULL,
    user_text TEXT,
    assistant_text TEXT,
    embedding vector(768),
    embedded_at TIMESTAMPTZ,
    embedding_status TEXT NOT NULL DEFAULT 'pending'
        CHECK (embedding_status IN ('pending','in_progress','embedded','failed')),
    embedding_claimed_at TIMESTAMPTZ,
    embedding_attempts INT NOT NULL DEFAULT 0,
    route_status TEXT NOT NULL DEFAULT 'unrouted'
        CHECK (route_status IN (
            'unrouted','routing','raw_only',
            'merge_queued','merged',
            'create_queued','episode_created','route_failed'
        )),
    last_routed_at TIMESTAMPTZ,
    route_attempts INT NOT NULL DEFAULT 0,
    route_result JSONB NOT NULL DEFAULT '{}'::jsonb,
    importance FLOAT DEFAULT 0.3 CHECK (importance BETWEEN 0 AND 1),
    source_attribution JSONB NOT NULL DEFAULT '{}'::jsonb,
    trust_level FLOAT NOT NULL DEFAULT 0.95 CHECK (trust_level BETWEEN 0 AND 1),
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active','redacted','archived')),
    recurrence_cluster_id UUID,
    consolidated_at TIMESTAMPTZ,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    idempotency_key TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS recmem_consolidation_tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','in_progress','completed','failed','dropped')),
    task_type TEXT NOT NULL,
    trigger_unit_id UUID REFERENCES subconscious_units(id) ON DELETE SET NULL,
    target_memory_id UUID REFERENCES memories(id) ON DELETE SET NULL,
    source_unit_ids UUID[] NOT NULL DEFAULT '{}',
    recurrence_count INT NOT NULL DEFAULT 0,
    max_similarity FLOAT,
    attempts INT NOT NULL DEFAULT 0,
    error TEXT,
    task_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    dropped_reason TEXT,
    CONSTRAINT recmem_task_type_known
        CHECK (task_type IN ('episode_merge','episode_create','semantic_refine'))
);

CREATE TABLE IF NOT EXISTS memory_source_units (
    memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    subconscious_unit_id UUID NOT NULL REFERENCES subconscious_units(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'source'
        CHECK (role IN ('source','direct_promotion','merge_addition')),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (memory_id, subconscious_unit_id)
);

CREATE TABLE IF NOT EXISTS recmem_rollout_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    event_type TEXT NOT NULL,
    session_id UUID,
    source_identity TEXT,
    raw_unit_id UUID REFERENCES subconscious_units(id) ON DELETE SET NULL,
    raw_status TEXT,
    direct_promoted BOOLEAN DEFAULT FALSE,
    eager_written BOOLEAN DEFAULT FALSE,
    eager_memory_id UUID REFERENCES memories(id) ON DELETE SET NULL,
    duration_ms FLOAT,
    error TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS recmem_retrieval_comparisons (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    query_hash TEXT NOT NULL,
    query_text TEXT,
    session_id UUID,
    eager_memory_ids UUID[] NOT NULL DEFAULT '{}',
    recmem_item_ids UUID[] NOT NULL DEFAULT '{}',
    eager_count INT NOT NULL DEFAULT 0,
    recmem_count INT NOT NULL DEFAULT 0,
    overlap_count INT NOT NULL DEFAULT 0,
    duration_ms FLOAT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS recmem_eval_sets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS recmem_eval_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    eval_set_id UUID NOT NULL REFERENCES recmem_eval_sets(id) ON DELETE CASCADE,
    category TEXT NOT NULL DEFAULT 'general',
    query_text TEXT NOT NULL,
    reference_answer TEXT,
    session_fixture JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS recmem_eval_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    eval_set_id UUID REFERENCES recmem_eval_sets(id) ON DELETE SET NULL,
    label TEXT,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','completed','failed','abandoned')),
    baseline_config JSONB NOT NULL DEFAULT '{}'::jsonb,
    recmem_config JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    started_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS recmem_eval_results (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id UUID NOT NULL REFERENCES recmem_eval_runs(id) ON DELETE CASCADE,
    item_id UUID REFERENCES recmem_eval_items(id) ON DELETE SET NULL,
    category TEXT NOT NULL DEFAULT 'general',
    baseline_answer TEXT,
    recmem_answer TEXT,
    baseline_memory_ids UUID[] NOT NULL DEFAULT '{}',
    recmem_memory_ids UUID[] NOT NULL DEFAULT '{}',
    judge_score FLOAT CHECK (judge_score IS NULL OR judge_score BETWEEN 0 AND 1),
    verdict TEXT,
    notes TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ----------------------------------------------------------------------------
-- PART 3: NEW INDEXES -- from db/01_indices.sql (already IF NOT EXISTS)
-- ----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_memories_validity
    ON memories (valid_until) WHERE valid_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subconscious_units_embedding
    ON subconscious_units USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL AND status = 'active';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_embed_pending
    ON subconscious_units (created_at) WHERE embedding_status = 'pending';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_embed_claimed
    ON subconscious_units (embedding_claimed_at) WHERE embedding_status = 'in_progress';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_route_pending
    ON subconscious_units (last_routed_at NULLS FIRST, created_at)
    WHERE embedding_status = 'embedded' AND route_status = 'unrouted';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_route_claimed
    ON subconscious_units (last_routed_at) WHERE route_status = 'routing';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_raw_only
    ON subconscious_units (last_routed_at)
    WHERE route_status = 'raw_only' AND consolidated_at IS NULL AND status = 'active';
CREATE INDEX IF NOT EXISTS idx_subconscious_units_status_created
    ON subconscious_units (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_subconscious_units_session_created
    ON subconscious_units (session_id, created_at DESC)
    WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_subconscious_units_metadata
    ON subconscious_units USING GIN (metadata);
CREATE INDEX IF NOT EXISTS idx_recmem_tasks_pending
    ON recmem_consolidation_tasks (next_attempt_at, created_at)
    WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_recmem_tasks_in_progress
    ON recmem_consolidation_tasks (started_at) WHERE status = 'in_progress';
CREATE INDEX IF NOT EXISTS idx_recmem_tasks_open_create_sources
    ON recmem_consolidation_tasks USING GIN (source_unit_ids)
    WHERE status IN ('pending','in_progress') AND task_type = 'episode_create';
CREATE INDEX IF NOT EXISTS idx_recmem_tasks_status_type
    ON recmem_consolidation_tasks (status, task_type, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_memory_source_units_source
    ON memory_source_units (subconscious_unit_id);
CREATE INDEX IF NOT EXISTS idx_recmem_rollout_events_created_type
    ON recmem_rollout_events (created_at DESC, event_type);
CREATE INDEX IF NOT EXISTS idx_recmem_rollout_events_session
    ON recmem_rollout_events (session_id, created_at DESC)
    WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_recmem_retrieval_comparisons_created
    ON recmem_retrieval_comparisons (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_recmem_retrieval_comparisons_session
    ON recmem_retrieval_comparisons (session_id, created_at DESC)
    WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_recmem_eval_items_set_category
    ON recmem_eval_items (eval_set_id, category);
CREATE INDEX IF NOT EXISTS idx_recmem_eval_runs_set_started
    ON recmem_eval_runs (eval_set_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_recmem_eval_results_run_category
    ON recmem_eval_results (run_id, category);

-- ----------------------------------------------------------------------------
-- PARTS 4-7: inlined from trial worktree by migrate-additive-build.sh
-- Build script replaces each @@INLINE marker with the file's content.
-- Function-only files are safe (all CREATE OR REPLACE FUNCTION).
-- New file db/32_tables_runtime.sql uses CREATE TABLE IF NOT EXISTS throughout.
-- ----------------------------------------------------------------------------

-- @@INLINE: db/32_tables_runtime.sql
-- @@INLINE: db/04_functions_core.sql
-- @@INLINE: db/05_functions_provenance_trust.sql
-- @@INLINE: db/09_functions_context.sql
-- @@INLINE: db/13_functions_emotional_state.sql
-- @@INLINE: db/31_functions_recmem.sql
-- @@INLINE: db/32_functions_db_brain.sql
-- @@INLINE: db/33_functions_runtime.sql
-- @@INLINE: db/34_functions_chat_channel.sql
-- @@INLINE: db/35_functions_recmem_ops.sql
-- @@INLINE: db/36_functions_tool_runtime.sql
-- @@INLINE: db/37_functions_agent_runtime.sql
-- @@INLINE: db/38_functions_db_native_tools.sql

-- ----------------------------------------------------------------------------
-- PART 7B: NEW VIEWS (from db/90_views.sql additions)
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS recmem_state;
CREATE VIEW recmem_state AS
SELECT
    1 as id,
    (s.value->>'last_sweep_at')::timestamptz as last_sweep_at,
    COALESCE(s.value->'last_sweep_result', '{}'::jsonb) as last_sweep_result,
    s.updated_at
FROM state s
WHERE s.key = 'recmem_state';

CREATE OR REPLACE VIEW recmem_rollout_health AS
SELECT
    (SELECT COUNT(*) FROM subconscious_units WHERE status = 'active') AS active_raw_units,
    (SELECT COUNT(*) FROM subconscious_units WHERE embedding_status = 'pending') AS pending_embeddings,
    (SELECT COUNT(*) FROM subconscious_units WHERE embedding_status = 'failed') AS failed_embeddings,
    (SELECT COUNT(*) FROM subconscious_units WHERE route_status = 'unrouted' AND embedding_status = 'embedded') AS pending_routes,
    (SELECT COUNT(*) FROM subconscious_units WHERE route_status = 'route_failed') AS failed_routes,
    (SELECT COUNT(*) FROM recmem_consolidation_tasks WHERE status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP) AS pending_tasks,
    (SELECT COUNT(*) FROM recmem_consolidation_tasks WHERE status = 'failed') AS failed_tasks,
    (SELECT COUNT(*) FROM recmem_consolidation_tasks WHERE status = 'dropped') AS dropped_tasks,
    (SELECT AVG(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - created_at))) FROM subconscious_units WHERE embedding_status = 'pending') AS avg_pending_embedding_age_s,
    (SELECT AVG(EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - embedded_at))) FROM subconscious_units WHERE embedding_status = 'embedded' AND route_status = 'unrouted') AS avg_pending_route_age_s,
    (SELECT COUNT(*) FROM recmem_retrieval_comparisons WHERE created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours') AS dual_write_comparisons_24h,
    (SELECT COUNT(*) FROM recmem_rollout_events WHERE created_at > CURRENT_TIMESTAMP - INTERVAL '24 hours') AS rollout_events_24h,
    (SELECT get_recmem_rollout_metrics(CURRENT_TIMESTAMP - INTERVAL '24 hours')) AS metrics_24h;

CREATE OR REPLACE VIEW worker_tasks AS
SELECT
    'heartbeat'::text AS task_type,
    CASE WHEN should_run_heartbeat() THEN 1 ELSE 0 END AS pending_count,
    'Run heartbeat tick (autonomous cognition)'::text AS description
UNION ALL
SELECT
    'subconscious_maintenance'::text AS task_type,
    CASE WHEN should_run_maintenance() THEN 1 ELSE 0 END AS pending_count,
    'Run subconscious maintenance tick (consolidate + prune)'::text AS description
UNION ALL
SELECT
    'recmem_embedding'::text AS task_type,
    COUNT(*)::int AS pending_count,
    'Embed pending RecMem raw units'::text AS description
FROM subconscious_units
WHERE embedding_status = 'pending'
UNION ALL
SELECT
    'recmem_routing'::text AS task_type,
    COUNT(*)::int AS pending_count,
    'Route embedded RecMem raw units'::text AS description
FROM subconscious_units
WHERE embedding_status = 'embedded' AND route_status = 'unrouted'
UNION ALL
SELECT
    'recmem_consolidation'::text AS task_type,
    COUNT(*)::int AS pending_count,
    'Process pending RecMem consolidation tasks'::text AS description
FROM recmem_consolidation_tasks
WHERE status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP
UNION ALL
SELECT
    'recmem_sweep'::text AS task_type,
    CASE WHEN should_run_recmem_sweep() THEN 1 ELSE 0 END AS pending_count,
    'Re-route old RecMem raw-only units'::text AS description;

-- ----------------------------------------------------------------------------
-- PART 8: CONFIG SEEDS (new RecMem + llm.recmem keys). ON CONFLICT DO NOTHING.
-- ----------------------------------------------------------------------------
INSERT INTO config (key, value, description) VALUES
    ('memory.recmem_rollout_phase', '0'::jsonb, 'Last operator-applied RecMem rollout phase'),
    ('memory.recmem_enabled', 'false'::jsonb, 'Use RecMem raw-turn ingestion for chat memory'),
    ('chat.eager_memory_enabled', 'true'::jsonb, 'Write ordinary chat turns directly to long-term memory'),
    ('chat.recmem_salience_direct_promote', 'true'::jsonb, 'Promote high-salience turns directly alongside raw ingest'),
    ('chat.inline_subconscious_enabled', 'true'::jsonb, 'Run inline subconscious appraisal during chat'),
    ('memory.recmem_hydrate_enabled', 'false'::jsonb, 'Use RecMem tiered retrieval for chat hydration'),
    ('memory.recmem_dual_write_compare', 'false'::jsonb, 'Log RecMem-vs-eager retrieval candidates during dual-write'),
    ('memory.recmem_rollout_metrics_enabled', 'false'::jsonb, 'Record RecMem rollout latency/write events'),
    ('memory.recmem_theta_sim', '0.7'::jsonb, 'Similarity threshold for recurrence'),
    ('memory.recmem_theta_sim_merge', '0.78'::jsonb, 'Similarity threshold for merge-first routing'),
    ('memory.recmem_theta_count', '5'::jsonb, 'Recurrence count threshold'),
    ('memory.recmem_top_k', '20'::jsonb, 'Top-k subconscious neighbors checked for recurrence'),
    ('memory.recmem_sub_limit', '10'::jsonb, 'Subconscious retrieval budget'),
    ('memory.recmem_epi_limit', '5'::jsonb, 'Episodic retrieval budget'),
    ('memory.recmem_sem_limit', '10'::jsonb, 'Semantic retrieval budget'),
    ('memory.recmem_embed_batch_size', '32'::jsonb, 'Units embedded per nearline batch'),
    ('memory.recmem_embed_interval_ms', '2000'::jsonb, 'Nearline embed pass interval'),
    ('memory.recmem_embed_claim_timeout_s', '120'::jsonb, 'Stale embedding claim timeout'),
    ('memory.recmem_embed_max_attempts', '3'::jsonb, 'Max embedding attempts before marking failed'),
    ('memory.recmem_route_batch_size', '32'::jsonb, 'Units routed per nearline batch'),
    ('memory.recmem_route_claim_timeout_s', '60'::jsonb, 'Stale routing claim timeout'),
    ('memory.recmem_route_max_attempts', '3'::jsonb, 'Max routing attempts before marking failed'),
    ('memory.recmem_worker_enabled', 'false'::jsonb, 'Process RecMem consolidation tasks'),
    ('memory.recmem_task_batch_size', '3'::jsonb, 'Consolidation tasks per worker tick'),
    ('memory.recmem_task_claim_timeout_s', '600'::jsonb, 'Stale consolidation task timeout'),
    ('memory.recmem_task_max_attempts', '3'::jsonb, 'Max attempts before a task is marked failed'),
    ('memory.recmem_task_backoff_base_s', '30'::jsonb, 'Base seconds for exponential backoff on retry'),
    ('memory.recmem_queue_max', '5000'::jsonb, 'Pending consolidation queue cap'),
    ('memory.recmem_queue_alert', '1000'::jsonb, 'Alert threshold for pending queue depth'),
    ('memory.recmem_sweep_age_days', '14'::jsonb, 'Periodic sweep age for unconsolidated units'),
    ('memory.recmem_sweep_batch_size', '100'::jsonb, 'Max units re-routed per sweep run'),
    ('memory.recmem_sweep_interval_seconds', '86400'::jsonb, 'Seconds between RecMem raw-only recurrence sweeps'),
    ('memory.recmem_sweep_min_rerouting_age_days', '7'::jsonb, 'Skip units routed within this window'),
    ('llm.recmem', 'null'::jsonb, 'Optional LLM override for RecMem consolidation prompts')
ON CONFLICT (key) DO NOTHING;

-- ----------------------------------------------------------------------------
-- PART 9: COMMIT
-- ----------------------------------------------------------------------------
COMMIT;
