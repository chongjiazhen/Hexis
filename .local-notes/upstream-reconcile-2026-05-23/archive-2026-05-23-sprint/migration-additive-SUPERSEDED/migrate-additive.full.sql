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


-- ===== BEGIN INLINE: db/32_tables_runtime.sql =====
-- Hexis DB-owned runtime tables.
SET search_path = public, ag_catalog, "$user";

CREATE TABLE IF NOT EXISTS prompt_modules (
    key TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    description TEXT,
    source_path TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS llm_task_kinds (
    task_kind TEXT PRIMARY KEY,
    provider_config_key TEXT NOT NULL,
    prompt_module_keys JSONB NOT NULL DEFAULT '[]'::jsonb,
    response_schema JSONB NOT NULL DEFAULT '{}'::jsonb,
    defaults JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS external_driver_calls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    driver TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'dropped')),
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    error TEXT,
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 3,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    claimed_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_external_driver_calls_pending
    ON external_driver_calls (driver, next_attempt_at, created_at)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_external_driver_calls_in_progress
    ON external_driver_calls (claimed_at)
    WHERE status = 'in_progress';

CREATE TABLE IF NOT EXISTS tool_definitions (
    name TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    schema JSONB NOT NULL DEFAULT '{}'::jsonb,
    default_energy_cost INT NOT NULL DEFAULT 1,
    allowed_contexts TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    requires_approval BOOLEAN NOT NULL DEFAULT FALSE,
    supports_parallel BOOLEAN NOT NULL DEFAULT FALSE,
    execution_kind TEXT NOT NULL DEFAULT 'python_driver'
        CHECK (execution_kind IN ('db_function', 'python_driver', 'external_driver')),
    driver TEXT,
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS agent_turns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mode TEXT NOT NULL,
    session_id UUID,
    heartbeat_id UUID,
    status TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running', 'waiting_external', 'completed', 'failed', 'cancelled')),
    phase TEXT NOT NULL DEFAULT 'execute',
    user_message TEXT,
    messages JSONB NOT NULL DEFAULT '[]'::jsonb,
    runtime_state JSONB NOT NULL DEFAULT '{}'::jsonb,
    stopped_reason TEXT,
    result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_agent_turns_status_created
    ON agent_turns (status, created_at DESC);

CREATE TABLE IF NOT EXISTS agent_turn_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    turn_id UUID NOT NULL REFERENCES agent_turns(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agent_turn_events_turn_created
    ON agent_turn_events (turn_id, created_at);

CREATE TABLE IF NOT EXISTS workflow_step_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workflow_id UUID NOT NULL REFERENCES workflow_executions(id) ON DELETE CASCADE,
    step_name TEXT NOT NULL,
    tool_name TEXT NOT NULL,
    arguments JSONB NOT NULL DEFAULT '{}'::jsonb,
    depends_on TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'ready', 'in_progress', 'completed', 'failed', 'skipped')),
    output JSONB,
    error TEXT,
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    UNIQUE (workflow_id, step_name)
);

CREATE INDEX IF NOT EXISTS idx_workflow_step_runs_status
    ON workflow_step_runs (workflow_id, status, created_at);
-- ===== END INLINE: db/32_tables_runtime.sql =====


-- ===== BEGIN INLINE: db/04_functions_core.sql =====
-- Hexis schema: core memory functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION update_memory_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION update_memory_importance()
RETURNS TRIGGER AS $$
BEGIN
    NEW.importance = NEW.importance * (1.0 + (LN(NEW.access_count + 1) * 0.1));
    NEW.last_accessed = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION mark_neighborhoods_stale()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE memory_neighborhoods 
    SET is_stale = TRUE 
    WHERE memory_id = NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION assign_to_episode()
RETURNS TRIGGER AS $$
DECLARE
    current_episode_id UUID;
    last_memory_time TIMESTAMPTZ;
    new_seq INT;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('episode_manager'));
    SELECT e.id INTO current_episode_id
    FROM episodes e
    WHERE e.ended_at IS NULL
    ORDER BY e.started_at DESC
    LIMIT 1;
    IF current_episode_id IS NOT NULL THEN
        SELECT MAX(m.created_at), COALESCE(MAX(fem.sequence_order), 0)
        INTO last_memory_time, new_seq
        FROM find_episode_memories_graph(current_episode_id) fem
        JOIN memories m ON fem.memory_id = m.id;

        new_seq := COALESCE(new_seq, 0) + 1;
    END IF;
    IF current_episode_id IS NULL OR
       (last_memory_time IS NOT NULL AND NEW.created_at - last_memory_time > INTERVAL '30 minutes')
    THEN
        IF current_episode_id IS NOT NULL THEN
            UPDATE episodes
            SET ended_at = last_memory_time
            WHERE id = current_episode_id;
        END IF;
        INSERT INTO episodes (started_at, metadata)
        VALUES (NEW.created_at, jsonb_build_object('episode_type', 'autonomous'))
        RETURNING id INTO current_episode_id;

        new_seq := 1;
    END IF;
    PERFORM link_memory_to_episode_graph(NEW.id, current_episode_id, new_seq);
    INSERT INTO memory_neighborhoods (memory_id, is_stale)
    VALUES (NEW.id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- Signature changes (new output column + new param) require a DROP first;
-- CREATE OR REPLACE cannot alter a function's return type.
DROP FUNCTION IF EXISTS fast_recall(TEXT, INT);
CREATE OR REPLACE FUNCTION fast_recall(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_current_sender TEXT DEFAULT NULL
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    sender_id TEXT
) AS $$
	DECLARE
	    query_embedding vector;
	    zero_vec vector;
	    affective_state JSONB;
	    current_valence FLOAT;
	    current_arousal FLOAT;
	    current_primary TEXT;
        min_trust FLOAT;
	BEGIN
	    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query_text, 'search_query')]))[1];
	    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
        affective_state := get_current_affective_state();
	    BEGIN
	        current_valence := NULLIF(affective_state->>'valence', '')::float;
	    EXCEPTION
	        WHEN OTHERS THEN
	            current_valence := NULL;
	    END;
	    BEGIN
	        current_arousal := NULLIF(affective_state->>'arousal', '')::float;
	    EXCEPTION
	        WHEN OTHERS THEN
	            current_arousal := NULL;
	    END;
	    BEGIN
	        current_primary := NULLIF(affective_state->>'primary_emotion', '');
	    EXCEPTION
	        WHEN OTHERS THEN
	            current_primary := NULL;
	    END;
	    current_valence := COALESCE(current_valence, 0.0);
	    current_arousal := COALESCE(current_arousal, 0.5);
	    current_primary := COALESCE(current_primary, 'neutral');
        min_trust := COALESCE(get_config_float('memory.recall_min_trust_level'), 0.0);
	    
	    RETURN QUERY
	    WITH 
	    seeds AS (
	        SELECT 
	            m.id, 
	            m.content, 
	            m.type,
            m.importance,
            m.decay_rate,
            m.created_at,
            m.last_accessed,
            1 - (m.embedding <=> query_embedding) as sim
        FROM memories m
	        WHERE m.status = 'active'
              AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
	          AND m.embedding IS NOT NULL
	          AND m.embedding <> zero_vec
	        ORDER BY m.embedding <=> query_embedding
	        LIMIT GREATEST(p_limit, 5)
	    ),
    associations AS (
        SELECT 
            (key)::UUID as mem_id,
            MAX((value::float) * s.sim) as assoc_score
        FROM seeds s
        JOIN memory_neighborhoods mn ON s.id = mn.memory_id,
        jsonb_each_text(mn.neighbors)
        WHERE NOT mn.is_stale
        GROUP BY key
    ),
    temporal AS (
        SELECT DISTINCT
            fem.memory_id as mem_id,
            0.15 as temp_score
        FROM episodes e
        CROSS JOIN LATERAL find_episode_memories_graph(e.id) fem
        WHERE e.ended_at IS NULL
          OR e.ended_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'
        LIMIT 20
    ),
    candidates AS (
        SELECT id as mem_id, sim as vector_score, NULL::float as assoc_score, NULL::float as temp_score
        FROM seeds
        UNION
        SELECT mem_id, NULL, assoc_score, NULL FROM associations
        UNION
        SELECT mem_id, NULL, NULL, temp_score FROM temporal
    ),
    scored AS (
        SELECT 
            c.mem_id,
            MAX(c.vector_score) as vector_score,
            MAX(c.assoc_score) as assoc_score,
            MAX(c.temp_score) as temp_score
        FROM candidates c
        GROUP BY c.mem_id
    )
	    SELECT
	        m.id,
	        m.content,
	        m.type,
	        GREATEST(
	            COALESCE(sc.vector_score, 0) * 0.5 +
	            COALESCE(sc.assoc_score, 0) * 0.2 +
	            COALESCE(sc.temp_score, 0) * 0.15 +
	            calculate_relevance(m.importance, m.decay_rate, m.created_at, m.last_accessed) * 0.05 +
                COALESCE(m.trust_level, 0.5) * 0.1 +
	            (CASE
	                WHEN m.metadata ? 'emotional_context' THEN
	                    (
	                        COALESCE(
	                            CASE
	                                WHEN (m.metadata->'emotional_context'->>'valence') IS NULL THEN NULL
	                                ELSE 1.0 - (ABS((m.metadata->'emotional_context'->>'valence')::float - current_valence) / 2.0)
	                            END,
	                            0.5
	                        ) * 0.6
	                        +
	                        COALESCE(
	                            CASE
	                                WHEN (m.metadata->'emotional_context'->>'arousal') IS NULL THEN NULL
	                                ELSE 1.0 - ABS((m.metadata->'emotional_context'->>'arousal')::float - current_arousal)
	                            END,
	                            0.5
	                        ) * 0.3
	                        +
	                        (CASE
	                            WHEN (m.metadata->'emotional_context'->>'primary_emotion') IS NULL THEN 0.5
	                            WHEN (m.metadata->'emotional_context'->>'primary_emotion') = current_primary THEN 1.0
	                            ELSE 0.7
	                        END) * 0.1
	                    )
	                ELSE
	                    CASE
	                        WHEN (m.metadata->>'emotional_valence') IS NULL THEN 0.5
	                        ELSE 1.0 - (ABS((m.metadata->>'emotional_valence')::float - current_valence) / 2.0)
	                    END
	            END) * 0.05
	            -- Own-sender boost: the current DM partner's own memories outrank a
	            -- stranger's at equal similarity. NULL p_current_sender = no boost.
	            + (CASE
	                WHEN p_current_sender IS NOT NULL AND m.sender_id = p_current_sender THEN 0.1
	                ELSE 0.0
	            END),
	            0.001
	        ) as final_score,
	        CASE
	            WHEN sc.vector_score IS NOT NULL THEN 'vector'
	            WHEN sc.assoc_score IS NOT NULL THEN 'association'
	            WHEN sc.temp_score IS NOT NULL THEN 'temporal'
	            ELSE 'fallback'
	        END as source,
	        m.sender_id
	    FROM scored sc
	    JOIN memories m ON sc.mem_id = m.id
	    WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.trust_level >= min_trust
	    ORDER BY final_score DESC
	    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

SET check_function_bodies = on;
-- ===== END INLINE: db/04_functions_core.sql =====


-- ===== BEGIN INLINE: db/05_functions_provenance_trust.sql =====
-- Hexis schema: provenance and trust functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION normalize_source_reference(p_source JSONB)
RETURNS JSONB AS $$
DECLARE
    kind TEXT;
    ref TEXT;
    label TEXT;
    author TEXT;
    observed_at TIMESTAMPTZ;
    trust FLOAT;
    content_hash TEXT;
BEGIN
    IF p_source IS NULL OR jsonb_typeof(p_source) <> 'object' THEN
        RETURN '{}'::jsonb;
    END IF;

    kind := NULLIF(p_source->>'kind', '');
    ref := COALESCE(NULLIF(p_source->>'ref', ''), NULLIF(p_source->>'uri', ''));
    label := NULLIF(p_source->>'label', '');
    author := NULLIF(p_source->>'author', '');
    content_hash := NULLIF(p_source->>'content_hash', '');

    BEGIN
        observed_at := (p_source->>'observed_at')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        observed_at := CURRENT_TIMESTAMP;
    END;
    IF observed_at IS NULL THEN
        observed_at := CURRENT_TIMESTAMP;
    END IF;

    trust := COALESCE(NULLIF(p_source->>'trust', '')::float, 0.5);
    trust := LEAST(1.0, GREATEST(0.0, trust));

    RETURN jsonb_strip_nulls(
        jsonb_build_object(
            'kind', kind,
            'ref', ref,
            'label', label,
            'author', author,
            'observed_at', observed_at,
            'trust', trust,
            'content_hash', content_hash
        )
    );
    END;
$$ LANGUAGE plpgsql STABLE;
-- Return-type change (new sender_id column) requires a DROP first.
DROP FUNCTION IF EXISTS recall_memories_filtered(TEXT, INT, memory_type[], FLOAT);
CREATE OR REPLACE FUNCTION recall_memories_filtered(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_min_importance FLOAT DEFAULT 0.0,
    p_current_sender TEXT DEFAULT NULL
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT,
    sender_id TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH hits AS (
        SELECT * FROM fast_recall(p_query_text, p_limit * 2, p_current_sender)
    )
    SELECT
        h.memory_id,
        h.content,
        h.memory_type,
        h.score,
        h.source,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float AS emotional_valence,
        h.sender_id
    FROM hits h
    JOIN memories m ON m.id = h.memory_id
    WHERE (p_memory_types IS NULL OR h.memory_type = ANY(p_memory_types))
      AND m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
      AND m.importance >= COALESCE(p_min_importance, 0.0)
    ORDER BY h.score DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

-- Structured recall with rich filters: source path/kind, date range, concept, metadata
CREATE OR REPLACE FUNCTION recall_memories_structured(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_min_importance FLOAT DEFAULT 0.0,
    p_source_path TEXT DEFAULT NULL,
    p_source_kind TEXT DEFAULT NULL,
    p_created_after TIMESTAMPTZ DEFAULT NULL,
    p_created_before TIMESTAMPTZ DEFAULT NULL,
    p_concept TEXT DEFAULT NULL,
    p_metadata_filter JSONB DEFAULT NULL
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT
) AS $$
DECLARE
    use_vector BOOLEAN;
BEGIN
    -- If no query text, we can't use fast_recall; fall back to direct filter
    use_vector := (p_query_text IS NOT NULL AND trim(p_query_text) <> '');

    IF use_vector THEN
        RETURN QUERY
        WITH hits AS (
            SELECT * FROM fast_recall(p_query_text, p_limit * 3)
        )
        SELECT
            h.memory_id,
            h.content,
            h.memory_type,
            h.score,
            h.source,
            m.importance,
            m.trust_level,
            m.source_attribution,
            m.created_at,
            (m.metadata->>'emotional_valence')::float AS emotional_valence
        FROM hits h
        JOIN memories m ON m.id = h.memory_id
        WHERE (p_memory_types IS NULL OR h.memory_type = ANY(p_memory_types))
          AND m.importance >= COALESCE(p_min_importance, 0.0)
          AND (p_source_path IS NULL OR m.source_attribution->>'path' ILIKE '%' || p_source_path || '%')
          AND (p_source_kind IS NULL OR m.source_attribution->>'kind' = p_source_kind)
          AND (p_created_after IS NULL OR m.created_at >= p_created_after)
          AND (p_created_before IS NULL OR m.created_at <= p_created_before)
          AND (p_metadata_filter IS NULL OR m.metadata @> p_metadata_filter)
        ORDER BY h.score DESC
        LIMIT p_limit;
    ELSE
        -- Filter-only mode (no semantic search)
        RETURN QUERY
        SELECT
            m.id AS memory_id,
            m.content,
            m.type AS memory_type,
            m.importance::float AS score,
            'filter'::text AS source,
            m.importance,
            m.trust_level,
            m.source_attribution,
            m.created_at,
            (m.metadata->>'emotional_valence')::float AS emotional_valence
        FROM memories m
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND (p_memory_types IS NULL OR m.type = ANY(p_memory_types))
          AND m.importance >= COALESCE(p_min_importance, 0.0)
          AND (p_source_path IS NULL OR m.source_attribution->>'path' ILIKE '%' || p_source_path || '%')
          AND (p_source_kind IS NULL OR m.source_attribution->>'kind' = p_source_kind)
          AND (p_created_after IS NULL OR m.created_at >= p_created_after)
          AND (p_created_before IS NULL OR m.created_at <= p_created_before)
          AND (p_metadata_filter IS NULL OR m.metadata @> p_metadata_filter)
        ORDER BY m.importance DESC, m.created_at DESC
        LIMIT p_limit;
    END IF;

    -- Concept filter: if p_concept is provided, additionally filter via graph
    -- (Handled in Python layer via knowledge graph lookup when concept != NULL)
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION recall_memories_stub(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_min_importance FLOAT DEFAULT 0.0,
    p_preview_chars INT DEFAULT 256
) RETURNS TABLE (
    memory_id UUID,
    preview TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT,
    content_length INT
) AS $$
BEGIN
    RETURN QUERY
    WITH hits AS (
        SELECT * FROM fast_recall(p_query_text, p_limit * 2)
    )
    SELECT
        h.memory_id,
        LEFT(h.content, p_preview_chars) AS preview,
        h.memory_type,
        h.score,
        h.source,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float AS emotional_valence,
        length(h.content) AS content_length
    FROM hits h
    JOIN memories m ON m.id = h.memory_id
    WHERE (p_memory_types IS NULL OR h.memory_type = ANY(p_memory_types))
      AND m.importance >= COALESCE(p_min_importance, 0.0)
    ORDER BY h.score DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION touch_memories(p_ids UUID[])
RETURNS INT AS $$
DECLARE
    updated_count INT;
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN 0;
    END IF;
    UPDATE memories
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = ANY(p_ids);
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN COALESCE(updated_count, 0);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_memory_by_id(p_memory_id UUID)
RETURNS TABLE (
    id UUID,
    type memory_type,
    content TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.type,
        m.content,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float
    FROM memories m
    WHERE m.id = p_memory_id
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP);
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_memories_summary(p_ids UUID[])
RETURNS TABLE (
    id UUID,
    type memory_type,
    content TEXT,
    importance FLOAT
) AS $$
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT
        m.id,
        m.type,
        m.content,
        m.importance
    FROM memories m
    WHERE m.id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_memories_by_ids(
    p_ids UUID[],
    p_max_chars INT DEFAULT 2000
) RETURNS TABLE (
    id UUID,
    type memory_type,
    content TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT
) AS $$
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT
        m.id,
        m.type,
        LEFT(m.content, p_max_chars) AS content,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float
    FROM memories m
    WHERE m.id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION list_recent_memories(
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_by_access BOOLEAN DEFAULT FALSE
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    importance FLOAT,
    created_at TIMESTAMPTZ,
    last_accessed TIMESTAMPTZ,
    trust_level FLOAT,
    source_attribution JSONB,
    emotional_valence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.content,
        m.type,
        m.importance,
        m.created_at,
        m.last_accessed,
        m.trust_level,
        m.source_attribution,
        (m.metadata->>'emotional_valence')::float
    FROM memories m
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
      AND (p_memory_types IS NULL OR m.type = ANY(p_memory_types))
    ORDER BY
        CASE WHEN p_by_access THEN m.last_accessed ELSE m.created_at END DESC NULLS LAST
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_episode_details(p_episode_id UUID)
RETURNS TABLE (
    id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    episode_type TEXT,
    summary TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.started_at,
        e.ended_at,
        e.metadata->>'episode_type' as episode_type,
        e.summary
    FROM episodes e
    WHERE e.id = p_episode_id;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_episode_memories(p_episode_id UUID)
RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    emotional_valence FLOAT,
    sequence_order INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.content,
        m.type,
        m.importance,
        m.trust_level,
        m.source_attribution,
        m.created_at,
        (m.metadata->>'emotional_valence')::float,
        fem.sequence_order
    FROM find_episode_memories_graph(p_episode_id) fem
    JOIN memories m ON fem.memory_id = m.id
    ORDER BY fem.sequence_order ASC;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION list_recent_episodes(p_limit INT DEFAULT 5)
RETURNS TABLE (
    id UUID,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    episode_type TEXT,
    summary TEXT,
    memory_count INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.id,
        e.started_at,
        e.ended_at,
        e.metadata->>'episode_type' as episode_type,
        e.summary,
        (SELECT COUNT(*)::int FROM find_episode_memories_graph(e.id)) as memory_count
    FROM episodes e
    ORDER BY e.started_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION search_clusters_by_query(
    p_query TEXT,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    id UUID,
    name TEXT,
    cluster_type cluster_type,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH query_embedding AS (
        SELECT (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1] as emb
    )
    SELECT
        c.id,
        c.name,
        c.cluster_type,
        1 - (c.centroid_embedding <=> (SELECT emb FROM query_embedding)) as similarity
    FROM clusters c
    WHERE c.centroid_embedding IS NOT NULL
    ORDER BY c.centroid_embedding <=> (SELECT emb FROM query_embedding)
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_cluster_sample_memories(
    p_cluster_id UUID,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    membership_strength FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.id,
        m.content,
        m.type,
        gcm.membership_strength
    FROM get_cluster_members_graph(p_cluster_id) gcm
    JOIN memories m ON gcm.memory_id = m.id
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
    ORDER BY gcm.membership_strength DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION explore_clusters_with_samples(
    p_query TEXT,
    p_cluster_limit INT DEFAULT 3,
    p_sample_limit INT DEFAULT 3
) RETURNS TABLE (
    cluster_id UUID,
    cluster_name TEXT,
    cluster_type cluster_type,
    cluster_similarity FLOAT,
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    membership_strength FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sc.id,
        sc.name,
        sc.cluster_type,
        sc.similarity,
        sm.memory_id,
        sm.content,
        sm.memory_type,
        sm.membership_strength
    FROM search_clusters_by_query(p_query, p_cluster_limit) sc
    LEFT JOIN LATERAL get_cluster_sample_memories(sc.id, p_sample_limit) sm ON true;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION find_related_concepts_for_memories(
    p_memory_ids UUID[],
    p_exclude TEXT DEFAULT '',
    p_limit INT DEFAULT 10
) RETURNS TABLE (
    name TEXT,
    shared_memories INT
) AS $$
DECLARE
    ids_sql TEXT;
    sql TEXT;
BEGIN
    IF p_memory_ids IS NULL OR array_length(p_memory_ids, 1) IS NULL THEN
        RETURN;
    END IF;

    SELECT array_to_string(ARRAY(
        SELECT quote_literal(mid::text)
        FROM unnest(p_memory_ids) as mid
    ), ',') INTO ids_sql;

    IF ids_sql IS NULL OR btrim(ids_sql) = '' THEN
        RETURN;
    END IF;

    sql := format($sql$
        SELECT
            replace(name_raw::text, '"', '') as name,
            (shared_raw::text)::int as shared_memories
        FROM ag_catalog.cypher('memory_graph', $q$
            MATCH (m:MemoryNode)-[:INSTANCE_OF]->(c:ConceptNode)
            WHERE m.memory_id IN [%s] AND c.name <> %L
            RETURN c.name, COUNT(m) as shared
            ORDER BY COUNT(m) DESC
            LIMIT %s
        $q$) as (name_raw ag_catalog.agtype, shared_raw ag_catalog.agtype)
    $sql$, ids_sql, COALESCE(p_exclude, ''), p_limit);

    RETURN QUERY EXECUTE sql;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION search_procedural_memories(
    p_task TEXT,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    steps JSONB,
    prerequisites JSONB,
    success_rate FLOAT,
    average_duration FLOAT,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH query_embedding AS (
        SELECT (get_embedding(ARRAY[ensure_embedding_prefix(p_task, 'search_query')]))[1] as emb
    )
    SELECT
        m.id,
        m.content,
        m.metadata->'steps' as steps,
        m.metadata->'prerequisites' as prerequisites,
        CASE
            WHEN COALESCE((m.metadata->>'total_attempts')::int, 0) > 0 THEN
                (m.metadata->>'success_count')::float / NULLIF((m.metadata->>'total_attempts')::float, 0)
            ELSE NULL
        END as success_rate,
        (m.metadata->>'average_duration_seconds')::float as average_duration,
        1 - (m.embedding <=> (SELECT emb FROM query_embedding)) as similarity
    FROM memories m
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
      AND m.type = 'procedural'
    ORDER BY m.embedding <=> (SELECT emb FROM query_embedding)
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION search_strategic_memories(
    p_situation TEXT,
    p_limit INT DEFAULT 3
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    pattern_description TEXT,
    confidence_score FLOAT,
    context_applicability JSONB,
    success_metrics JSONB,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    WITH query_embedding AS (
        SELECT (get_embedding(ARRAY[ensure_embedding_prefix(p_situation, 'search_query')]))[1] as emb
    )
    SELECT
        m.id,
        m.content,
        COALESCE(m.metadata->>'pattern_description', m.content) as pattern_description,
        (m.metadata->>'confidence_score')::float as confidence_score,
        m.metadata->'context_applicability' as context_applicability,
        m.metadata->'success_metrics' as success_metrics,
        1 - (m.embedding <=> (SELECT emb FROM query_embedding)) as similarity
    FROM memories m
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
      AND m.type = 'strategic'
    ORDER BY m.embedding <=> (SELECT emb FROM query_embedding)
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION normalize_source_references(p_sources JSONB)
RETURNS JSONB AS $$
DECLARE
    elem JSONB;
    out_arr JSONB := '[]'::jsonb;
BEGIN
    IF p_sources IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;

    IF jsonb_typeof(p_sources) = 'array' THEN
        FOR elem IN SELECT * FROM jsonb_array_elements(p_sources)
        LOOP
            out_arr := out_arr || jsonb_build_array(normalize_source_reference(elem));
        END LOOP;
    ELSIF jsonb_typeof(p_sources) = 'object' THEN
        out_arr := jsonb_build_array(normalize_source_reference(p_sources));
    ELSE
        RETURN '[]'::jsonb;
    END IF;

    RETURN COALESCE(
        (SELECT jsonb_agg(e) FROM jsonb_array_elements(out_arr) e WHERE e <> '{}'::jsonb),
        '[]'::jsonb
    );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION dedupe_source_references(p_sources JSONB)
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(d.elem)
        FROM (
            SELECT DISTINCT ON (d.key) d.elem
            FROM (
                SELECT
                    COALESCE(NULLIF(e->>'ref', ''), NULLIF(e->>'label', ''), md5(e::text)) AS key,
                    e AS elem,
                    COALESCE(e->>'observed_at', '') AS observed_at
                FROM jsonb_array_elements(normalize_source_references(p_sources)) e
            ) d
            ORDER BY d.key, d.observed_at DESC
        ) d
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION source_reinforcement_score(p_source_references JSONB)
RETURNS FLOAT AS $$
DECLARE
    unique_sources INT;
    avg_trust FLOAT;
BEGIN
    WITH elems AS (
        SELECT
            COALESCE(NULLIF(e->>'ref', ''), NULLIF(e->>'label', ''), md5(e::text)) AS key,
            COALESCE((e->>'trust')::float, 0.5) AS trust
        FROM jsonb_array_elements(dedupe_source_references(p_source_references)) e
    )
    SELECT COUNT(DISTINCT key), AVG(trust) INTO unique_sources, avg_trust
    FROM elems;

    IF unique_sources IS NULL OR unique_sources = 0 THEN
        RETURN 0.0;
    END IF;

    avg_trust := COALESCE(avg_trust, 0.5);
    RETURN 1.0 - exp(-0.8 * unique_sources * avg_trust);
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION compute_worldview_alignment(p_memory_id UUID)
RETURNS FLOAT AS $$
DECLARE
    supports_score FLOAT := 0;
    contradicts_score FLOAT := 0;
    alignment FLOAT;
    sql TEXT;
BEGIN
    BEGIN
        sql := format($sql$
            SELECT COALESCE(SUM((strength::text)::float), 0)
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (m:MemoryNode {memory_id: %L})-[r:SUPPORTS]->(w:MemoryNode)
                WHERE w.type = 'worldview'
                RETURN r.strength
            $q$) as (strength ag_catalog.agtype)
        $sql$, p_memory_id);
        EXECUTE sql INTO supports_score;
    EXCEPTION WHEN OTHERS THEN supports_score := 0; END;
    BEGIN
        sql := format($sql$
            SELECT COALESCE(SUM((strength::text)::float), 0)
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (m:MemoryNode {memory_id: %L})-[r:CONTRADICTS]->(w:MemoryNode)
                WHERE w.type = 'worldview'
                RETURN r.strength
            $q$) as (strength ag_catalog.agtype)
        $sql$, p_memory_id);
        EXECUTE sql INTO contradicts_score;
    EXCEPTION WHEN OTHERS THEN contradicts_score := 0; END;
    supports_score := COALESCE(supports_score, 0);
    contradicts_score := COALESCE(contradicts_score, 0);

    IF (supports_score + contradicts_score) = 0 THEN
        RETURN 0.0;
    END IF;

    alignment := (supports_score - contradicts_score) / (supports_score + contradicts_score);
    RETURN LEAST(1.0, GREATEST(-1.0, alignment));
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION compute_semantic_trust(
    p_confidence FLOAT,
    p_source_references JSONB,
    p_worldview_alignment FLOAT DEFAULT 0.0
)
RETURNS FLOAT AS $$
DECLARE
    base_confidence FLOAT;
    reinforcement FLOAT;
    cap FLOAT;
    effective FLOAT;
    alignment FLOAT;
BEGIN
    base_confidence := LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.5)));
    reinforcement := source_reinforcement_score(p_source_references);
    cap := 0.15 + 0.85 * reinforcement;
    effective := LEAST(base_confidence, cap);

    alignment := LEAST(1.0, GREATEST(-1.0, COALESCE(p_worldview_alignment, 0.0)));
    IF alignment < 0 THEN
        effective := effective * (1.0 + alignment);
    ELSE
        effective := LEAST(1.0, effective + 0.10 * alignment);
    END IF;

    RETURN LEAST(1.0, GREATEST(0.0, effective));
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION sync_memory_trust(p_memory_id UUID)
RETURNS VOID AS $$
DECLARE
    mtype memory_type;
    conf FLOAT;
    sources JSONB;
    alignment FLOAT;
    computed FLOAT;
    mem_metadata JSONB;
BEGIN
    SELECT type, metadata INTO mtype, mem_metadata FROM memories WHERE id = p_memory_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF mtype <> 'semantic' THEN
        RETURN;
    END IF;
    conf := COALESCE((mem_metadata->>'confidence')::float, 0.5);
    sources := mem_metadata->'source_references';

    sources := dedupe_source_references(sources);
    alignment := compute_worldview_alignment(p_memory_id);
    computed := compute_semantic_trust(conf, sources, alignment);

    UPDATE memories
    SET trust_level = computed,
        trust_updated_at = CURRENT_TIMESTAMP,
        source_attribution = CASE
            WHEN (source_attribution = '{}'::jsonb OR source_attribution IS NULL)
                 AND jsonb_typeof(sources) = 'array'
                 AND jsonb_array_length(sources) > 0
            THEN normalize_source_reference(sources->0)
            ELSE source_attribution
        END
    WHERE id = p_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION add_semantic_source_reference(
    p_memory_id UUID,
    p_source JSONB
)
RETURNS VOID AS $$
DECLARE
    normalized JSONB;
BEGIN
    normalized := normalize_source_reference(p_source);
    IF normalized = '{}'::jsonb THEN
        RETURN;
    END IF;
    UPDATE memories
    SET metadata = jsonb_set(
            jsonb_set(
                metadata,
                '{source_references}',
                dedupe_source_references(
                    COALESCE(metadata->'source_references', '[]'::jsonb) || jsonb_build_array(normalized)
                )
            ),
            '{last_validated}',
            to_jsonb(CURRENT_TIMESTAMP)
        )
    WHERE id = p_memory_id AND type = 'semantic';

    PERFORM sync_memory_trust(p_memory_id);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_memory_truth_profile(p_memory_id UUID)
RETURNS JSONB AS $$
DECLARE
    mtype memory_type;
    base_conf FLOAT;
    sources JSONB;
    reinforcement FLOAT;
    alignment FLOAT;
    trust FLOAT;
    source_count INT;
    mem_metadata JSONB;
BEGIN
    SELECT type, trust_level, metadata INTO mtype, trust, mem_metadata
    FROM memories
    WHERE id = p_memory_id;

    IF NOT FOUND THEN
        RETURN '{}'::jsonb;
    END IF;

    IF mtype = 'semantic' THEN
        base_conf := COALESCE((mem_metadata->>'confidence')::float, 0.5);
        sources := mem_metadata->'source_references';

        sources := dedupe_source_references(sources);
        reinforcement := source_reinforcement_score(sources);
        alignment := compute_worldview_alignment(p_memory_id);
        source_count := COALESCE(jsonb_array_length(sources), 0);

        RETURN jsonb_build_object(
            'type', 'semantic',
            'base_confidence', COALESCE(base_conf, 0.5),
            'trust_level', trust,
            'source_count', source_count,
            'source_reinforcement', reinforcement,
            'worldview_alignment', alignment,
            'sources', sources
        );
    END IF;

    RETURN jsonb_build_object(
        'type', mtype::text,
        'trust_level', trust
    );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION update_worldview_confidence_from_influences(
    p_worldview_memory_id UUID,
    p_window INTERVAL DEFAULT INTERVAL '30 days',
    p_learning_rate FLOAT DEFAULT 0.05
)
RETURNS VOID AS $$
DECLARE
    delta FLOAT := 0;
    base_conf FLOAT;
    mem_meta JSONB;
BEGIN
    IF p_worldview_memory_id IS NULL THEN
        RETURN;
    END IF;
    SELECT metadata INTO mem_meta FROM memories WHERE id = p_worldview_memory_id AND type = 'worldview';
    IF NOT FOUND THEN RETURN; END IF;

    base_conf := COALESCE((mem_meta->>'confidence')::float, 0.5);
    BEGIN
        EXECUTE format($sql$
            SELECT COALESCE(AVG((strength::text)::float * 0.5), 0)
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (m:MemoryNode)-[r:SUPPORTS]->(w:MemoryNode {memory_id: %L})
                RETURN r.strength
            $q$) as (strength ag_catalog.agtype)
        $sql$, p_worldview_memory_id) INTO delta;
    EXCEPTION WHEN OTHERS THEN delta := 0; END;
    UPDATE memories
    SET metadata = jsonb_set(
            metadata,
            '{confidence}',
            to_jsonb(LEAST(1.0, GREATEST(0.0, base_conf + COALESCE(p_learning_rate, 0.05) * COALESCE(delta, 0))))
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_worldview_memory_id;
END;
$$ LANGUAGE plpgsql;
-- Adding p_sender_id creates a signature overload; DROP the old arity first so a
-- 6-arg call cannot resolve to a stale version that ignores sender_id.
DROP FUNCTION IF EXISTS create_memory(memory_type, TEXT, FLOAT, JSONB, FLOAT, JSONB);
CREATE OR REPLACE FUNCTION create_memory(
    p_type memory_type,
    p_content TEXT,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_sender_id TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    embedding_vec vector;
    normalized_source JSONB;
    effective_trust FLOAT;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object(
            'kind',
            CASE
                WHEN p_type = 'semantic' THEN 'unattributed'
                ELSE 'internal'
            END,
            'observed_at', CURRENT_TIMESTAMP
        );
    END IF;

    effective_trust := p_trust_level;
    IF effective_trust IS NULL THEN
        effective_trust := CASE
            WHEN p_type = 'episodic' THEN 0.95
            WHEN p_type = 'semantic' THEN 0.20
            WHEN p_type = 'procedural' THEN 0.70
            WHEN p_type = 'strategic' THEN 0.70
            ELSE 0.50
        END;
    END IF;
    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));
    embedding_vec := (get_embedding(ARRAY[p_content]))[1];

    INSERT INTO memories (type, content, embedding, importance, source_attribution, trust_level, trust_updated_at, metadata, sender_id)
    VALUES (p_type, p_content, embedding_vec, p_importance, normalized_source, effective_trust, CURRENT_TIMESTAMP, COALESCE(p_metadata, '{}'::jsonb), p_sender_id)
    RETURNING id INTO new_memory_id;
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MERGE (n:MemoryNode {memory_id: %L})
            SET n.type = %L, n.created_at = %L
            RETURN n
        $q$) as (result ag_catalog.agtype)',
        new_memory_id,
        p_type,
        CURRENT_TIMESTAMP
    );

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
DROP FUNCTION IF EXISTS create_episodic_memory(TEXT, JSONB, JSONB, JSONB, FLOAT, TIMESTAMPTZ, FLOAT, JSONB, FLOAT);
CREATE OR REPLACE FUNCTION create_episodic_memory(
    p_content TEXT,
    p_action_taken JSONB DEFAULT NULL,
    p_context JSONB DEFAULT NULL,
    p_result JSONB DEFAULT NULL,
    p_emotional_valence FLOAT DEFAULT 0.0,
    p_event_time TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_sender_id TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    END IF;
    effective_trust := COALESCE(p_trust_level, 0.95);
    meta := jsonb_build_object(
        'action_taken', p_action_taken,
        'context', p_context,
        'result', p_result,
        'emotional_valence', LEAST(1.0, GREATEST(-1.0, COALESCE(p_emotional_valence, 0.0))),
        'event_time', COALESCE(p_event_time, CURRENT_TIMESTAMP),
        'verification_status', NULL
    );

    new_memory_id := create_memory('episodic', p_content, p_importance, normalized_source, effective_trust, meta, p_sender_id);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
DROP FUNCTION IF EXISTS create_semantic_memory(TEXT, FLOAT, TEXT[], TEXT[], JSONB, FLOAT, JSONB, FLOAT);
CREATE OR REPLACE FUNCTION create_semantic_memory(
    p_content TEXT,
    p_confidence FLOAT,
    p_category TEXT[] DEFAULT NULL,
    p_related_concepts TEXT[] DEFAULT NULL,
    p_source_references JSONB DEFAULT NULL,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_sender_id TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_sources JSONB;
    primary_source JSONB;
    base_confidence FLOAT;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_sources := dedupe_source_references(p_source_references);
    base_confidence := LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.5)));

    primary_source := normalize_source_reference(p_source_attribution);
    IF primary_source = '{}'::jsonb AND jsonb_typeof(normalized_sources) = 'array' AND jsonb_array_length(normalized_sources) > 0 THEN
        primary_source := normalize_source_reference(normalized_sources->0);
    END IF;
    IF primary_source = '{}'::jsonb THEN
        primary_source := jsonb_build_object('kind', 'unattributed', 'observed_at', CURRENT_TIMESTAMP);
    END IF;

    effective_trust := COALESCE(p_trust_level, compute_semantic_trust(base_confidence, normalized_sources, 0.0));
    meta := jsonb_build_object(
        'confidence', base_confidence,
        'last_validated', CURRENT_TIMESTAMP,
        'source_references', normalized_sources,
        'contradictions', NULL,
        'category', to_jsonb(p_category),
        'related_concepts', to_jsonb(p_related_concepts)
    );

    new_memory_id := create_memory('semantic', p_content, p_importance, primary_source, effective_trust, meta, p_sender_id);

    PERFORM sync_memory_trust(new_memory_id);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION create_procedural_memory(
    p_content TEXT,
    p_steps JSONB,
    p_prerequisites JSONB DEFAULT NULL,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    END IF;
    effective_trust := COALESCE(p_trust_level, 0.70);
    meta := jsonb_build_object(
        'steps', p_steps,
        'prerequisites', p_prerequisites,
        'success_count', 0,
        'total_attempts', 0,
        'average_duration_seconds', NULL,
        'failure_points', NULL
    );

    new_memory_id := create_memory('procedural', p_content, p_importance, normalized_source, effective_trust, meta);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION create_strategic_memory(
    p_content TEXT,
    p_pattern_description TEXT,
    p_confidence_score FLOAT,
    p_supporting_evidence JSONB DEFAULT NULL,
    p_context_applicability JSONB DEFAULT NULL,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    END IF;
    effective_trust := COALESCE(p_trust_level, 0.70);
    meta := jsonb_build_object(
        'pattern_description', p_pattern_description,
        'confidence_score', LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence_score, 0.5))),
        'supporting_evidence', p_supporting_evidence,
        'success_metrics', NULL,
        'adaptation_history', NULL,
        'context_applicability', p_context_applicability
    );

    new_memory_id := create_memory('strategic', p_content, p_importance, normalized_source, effective_trust, meta);

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION create_worldview_memory(
    p_content TEXT,
    p_category TEXT DEFAULT 'belief',
    p_confidence FLOAT DEFAULT 0.8,
    p_stability FLOAT DEFAULT 0.7,
    p_importance FLOAT DEFAULT 0.8,
    p_origin TEXT DEFAULT 'discovered',
    p_trigger_patterns JSONB DEFAULT NULL,
    p_response_type TEXT DEFAULT NULL,
    p_response_template TEXT DEFAULT NULL,
    p_emotional_valence FLOAT DEFAULT 0.0,
    p_extra_metadata JSONB DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
    meta JSONB;
BEGIN
    -- Dedup: return existing active worldview memory with same content
    SELECT id INTO new_memory_id
    FROM memories
    WHERE type = 'worldview' AND content = p_content AND status = 'active'
    LIMIT 1;
    IF new_memory_id IS NOT NULL THEN
        RETURN new_memory_id;
    END IF;

    normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
    effective_trust := LEAST(1.0, GREATEST(0.0, COALESCE(p_stability, 0.7)));
    meta := jsonb_build_object(
        'category', p_category,
        'confidence', LEAST(1.0, GREATEST(0.0, COALESCE(p_confidence, 0.8))),
        'stability', LEAST(1.0, GREATEST(0.0, COALESCE(p_stability, 0.7))),
        'origin', COALESCE(p_origin, 'discovered'),
        'emotional_valence', LEAST(1.0, GREATEST(-1.0, COALESCE(p_emotional_valence, 0.0))),
        'evidence_threshold', 0.9,
        'trigger_patterns', p_trigger_patterns,
        'response_type', p_response_type,
        'response_template', p_response_template
    );
    IF p_extra_metadata IS NOT NULL THEN
        meta := meta || p_extra_metadata;
    END IF;

    new_memory_id := create_memory('worldview', p_content, p_importance, normalized_source, effective_trust, meta);
    BEGIN
        EXECUTE format(
            'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
                MATCH (s:SelfNode)
                MATCH (m:MemoryNode {memory_id: %L})
                CREATE (s)-[:HAS_BELIEF {category: %L, stability: %s}]->(m)
                RETURN m
            $q$) as (result ag_catalog.agtype)',
            new_memory_id,
            p_category,
            p_stability
        );
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION create_worldview_belief(
    p_content TEXT,
    p_category TEXT DEFAULT 'belief',
    p_confidence FLOAT DEFAULT 0.8,
    p_stability FLOAT DEFAULT 0.7,
    p_importance FLOAT DEFAULT 0.8,
    p_origin TEXT DEFAULT 'discovered',
    p_evidence_threshold FLOAT DEFAULT 0.7,
    p_emotional_valence FLOAT DEFAULT 0.0,
    p_trigger_patterns TEXT[] DEFAULT NULL,
    p_response_type TEXT DEFAULT NULL,
    p_source_references JSONB DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_sources JSONB;
    trigger_json JSONB;
    meta_patch JSONB := '{}'::jsonb;
BEGIN
    trigger_json := CASE
        WHEN p_trigger_patterns IS NULL THEN NULL
        ELSE to_jsonb(p_trigger_patterns)
    END;

    new_memory_id := create_worldview_memory(
        p_content,
        p_category,
        p_confidence,
        p_stability,
        p_importance,
        p_origin,
        trigger_json,
        p_response_type,
        NULL,
        p_emotional_valence
    );

    IF p_evidence_threshold IS NOT NULL THEN
        meta_patch := meta_patch || jsonb_build_object(
            'evidence_threshold',
            LEAST(1.0, GREATEST(0.0, p_evidence_threshold))
        );
    END IF;

    IF p_source_references IS NOT NULL THEN
        normalized_sources := dedupe_source_references(p_source_references);
        meta_patch := meta_patch || jsonb_build_object('source_references', normalized_sources);
    END IF;

    IF meta_patch <> '{}'::jsonb THEN
        UPDATE memories
        SET metadata = metadata || meta_patch,
            source_attribution = CASE
                WHEN normalized_sources IS NOT NULL
                     AND jsonb_typeof(normalized_sources) = 'array'
                     AND jsonb_array_length(normalized_sources) > 0
                THEN normalize_source_reference(normalized_sources->0)
                ELSE source_attribution
            END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = new_memory_id;
    END IF;

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION update_identity_belief(
    p_worldview_id UUID,
    p_new_content TEXT,
    p_evidence_memory_id UUID,
    p_force BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN AS $$
DECLARE
    current_stability FLOAT;
    stable_threshold FLOAT := 0.8;
BEGIN
    SELECT COALESCE((metadata->>'stability')::float, 0.7)
    INTO current_stability
    FROM memories
    WHERE id = p_worldview_id
      AND type = 'worldview'
      AND metadata->>'category' = 'self';

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    IF current_stability > stable_threshold AND NOT COALESCE(p_force, FALSE) THEN
        PERFORM create_strategic_memory(
            'Identity belief challenged but stable',
            'Identity stability check',
            0.7,
            jsonb_build_object(
                'worldview_id', p_worldview_id,
                'evidence_memory_id', p_evidence_memory_id
            )
        );
        RETURN FALSE;
    END IF;

    UPDATE memories
    SET content = p_new_content,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_worldview_id AND type = 'worldview';

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION batch_create_memories(p_items JSONB)
RETURNS UUID[] AS $$
DECLARE
    ids UUID[] := ARRAY[]::UUID[];
    item JSONB;
    mtype memory_type;
    content TEXT;
    importance FLOAT;
    new_id UUID;
    idx INT := 0;
BEGIN
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RETURN ids;
    END IF;

    FOR item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        idx := idx + 1;
        mtype := NULLIF(item->>'type', '')::memory_type;
        content := NULLIF(item->>'content', '');
        IF content IS NULL OR mtype IS NULL THEN
            RAISE EXCEPTION 'batch_create_memories: item % missing required fields', idx;
        END IF;
        importance := COALESCE(NULLIF(item->>'importance', '')::float, 0.5);

        IF mtype = 'episodic' THEN
            new_id := create_episodic_memory(
                content,
                item->'action_taken',
                item->'context',
                item->'result',
                COALESCE(NULLIF(item->>'emotional_valence', '')::float, 0.0),
                COALESCE(NULLIF(item->>'event_time', '')::timestamptz, CURRENT_TIMESTAMP),
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSIF mtype = 'semantic' THEN
            new_id := create_semantic_memory(
                content,
                COALESCE(NULLIF(item->>'confidence', '')::float, 0.8),
                CASE WHEN item ? 'category' THEN ARRAY(SELECT jsonb_array_elements_text(item->'category')) ELSE NULL END,
                CASE WHEN item ? 'related_concepts' THEN ARRAY(SELECT jsonb_array_elements_text(item->'related_concepts')) ELSE NULL END,
                item->'source_references',
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSIF mtype = 'procedural' THEN
            new_id := create_procedural_memory(
                content,
                COALESCE(item->'steps', jsonb_build_object('steps', '[]'::jsonb)),
                item->'prerequisites',
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSIF mtype = 'strategic' THEN
            new_id := create_strategic_memory(
                content,
                COALESCE(NULLIF(item->>'pattern_description', ''), content),
                COALESCE(NULLIF(item->>'confidence_score', '')::float, 0.8),
                item->'supporting_evidence',
                item->'context_applicability',
                importance,
                item->'source_attribution',
                NULLIF(item->>'trust_level', '')::float
            );
        ELSE
            RAISE EXCEPTION 'batch_create_memories: item % invalid type %', idx, mtype::text;
        END IF;

        IF new_id IS NULL THEN
            RAISE EXCEPTION 'batch_create_memories: item % failed to create memory', idx;
        END IF;
        ids := array_append(ids, new_id);
    END LOOP;

    RETURN ids;
END;
$$ LANGUAGE plpgsql;
-- PR-B: add p_sender_id at the end. Signature still backwards-compatible for
-- callers that pass positional args 1..7; new param has default NULL.
CREATE OR REPLACE FUNCTION create_memory_with_embedding(
    p_type memory_type,
    p_content TEXT,
    p_embedding vector,
    p_importance FLOAT DEFAULT 0.5,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb,
    p_sender_id TEXT DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    new_memory_id UUID;
    normalized_source JSONB;
    effective_trust FLOAT;
BEGIN
    IF p_embedding IS NULL THEN
        RAISE EXCEPTION 'embedding must not be NULL';
    END IF;

    normalized_source := normalize_source_reference(p_source_attribution);
    IF normalized_source = '{}'::jsonb THEN
        normalized_source := jsonb_build_object(
            'kind',
            CASE
                WHEN p_type = 'semantic' THEN 'unattributed'
                ELSE 'internal'
            END,
            'observed_at', CURRENT_TIMESTAMP
        );
    END IF;

    effective_trust := p_trust_level;
    IF effective_trust IS NULL THEN
        effective_trust := CASE
            WHEN p_type = 'episodic' THEN 0.95
            WHEN p_type = 'semantic' THEN 0.20
            WHEN p_type = 'procedural' THEN 0.70
            WHEN p_type = 'strategic' THEN 0.70
            ELSE 0.50
        END;
    END IF;
    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

    INSERT INTO memories (type, content, embedding, importance, source_attribution, trust_level, trust_updated_at, metadata, sender_id)
    VALUES (p_type, p_content, p_embedding, p_importance, normalized_source, effective_trust, CURRENT_TIMESTAMP, COALESCE(p_metadata, '{}'::jsonb), p_sender_id)
    RETURNING id INTO new_memory_id;

    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            CREATE (n:MemoryNode {memory_id: %L, type: %L, created_at: %L})
            RETURN n
        $q$) as (result ag_catalog.agtype)',
        new_memory_id,
        p_type,
        CURRENT_TIMESTAMP
    );

    RETURN new_memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION batch_create_memories_with_embeddings(
    p_type memory_type,
    p_contents TEXT[],
    p_embeddings JSONB,
    p_importance FLOAT DEFAULT 0.5
)
RETURNS UUID[] AS $$
DECLARE
    ids UUID[] := ARRAY[]::UUID[];
    n INT;
    i INT;
    expected_dim INT;
    emb_vec vector;
    emb_json JSONB;
    emb_arr FLOAT4[];
    new_id UUID;
    default_meta JSONB;
BEGIN
    n := COALESCE(array_length(p_contents, 1), 0);
    IF n = 0 THEN
        RETURN ids;
    END IF;

    IF p_embeddings IS NULL OR jsonb_typeof(p_embeddings) <> 'array' THEN
        RAISE EXCEPTION 'embeddings must be a JSON array';
    END IF;
    IF jsonb_array_length(p_embeddings) <> n THEN
        RAISE EXCEPTION 'contents and embeddings length mismatch';
    END IF;

    expected_dim := embedding_dimension();

    FOR i IN 1..n LOOP
        IF p_contents[i] IS NULL OR p_contents[i] = '' THEN
            CONTINUE;
        END IF;

        emb_json := p_embeddings->(i - 1);
        IF emb_json IS NULL OR jsonb_typeof(emb_json) <> 'array' THEN
            RAISE EXCEPTION 'embedding % must be a JSON array', i;
        END IF;

        SELECT ARRAY_AGG(value::float4) INTO emb_arr
        FROM jsonb_array_elements_text(emb_json) value;

        IF COALESCE(array_length(emb_arr, 1), 0) <> expected_dim THEN
            RAISE EXCEPTION 'embedding dimension mismatch: expected %, got %', expected_dim, COALESCE(array_length(emb_arr, 1), 0);
        END IF;

        emb_vec := (emb_arr::float4[])::vector;
        IF p_type = 'episodic' THEN
            default_meta := jsonb_build_object(
                'action_taken', NULL,
                'context', jsonb_build_object('type', 'raw_batch'),
                'result', NULL,
                'emotional_valence', 0.0,
                'verification_status', NULL,
                'event_time', CURRENT_TIMESTAMP
            );
        ELSIF p_type = 'semantic' THEN
            default_meta := jsonb_build_object(
                'confidence', 0.8,
                'last_validated', CURRENT_TIMESTAMP,
                'source_references', '[]'::jsonb,
                'contradictions', NULL,
                'category', NULL,
                'related_concepts', NULL
            );
        ELSIF p_type = 'procedural' THEN
            default_meta := jsonb_build_object(
                'steps', '[]'::jsonb,
                'prerequisites', NULL,
                'success_count', 0,
                'total_attempts', 0,
                'average_duration_seconds', NULL,
                'failure_points', NULL
            );
        ELSIF p_type = 'strategic' THEN
            default_meta := jsonb_build_object(
                'pattern_description', p_contents[i],
                'supporting_evidence', NULL,
                'confidence_score', 0.8,
                'success_metrics', NULL,
                'adaptation_history', NULL,
                'context_applicability', NULL
            );
        ELSE
            default_meta := '{}'::jsonb;
        END IF;

        new_id := create_memory_with_embedding(p_type, p_contents[i], emb_vec, p_importance, NULL, NULL, default_meta);

        IF p_type = 'semantic' THEN
            PERFORM sync_memory_trust(new_id);
        END IF;

        ids := array_append(ids, new_id);
    END LOOP;

    RETURN ids;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION search_similar_memories(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_memory_types memory_type[] DEFAULT NULL,
    p_min_importance FLOAT DEFAULT 0.0
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    type memory_type,
    similarity FLOAT,
    importance FLOAT
) AS $$
DECLARE
    query_embedding vector;
    zero_vec vector;
BEGIN
    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query_text, 'search_query')]))[1];
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    
    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT m.id, m.content, m.type, m.embedding, m.importance
        FROM memories m
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.embedding IS NOT NULL
          AND m.embedding <> zero_vec
          AND (p_memory_types IS NULL OR m.type = ANY(p_memory_types))
          AND m.importance >= p_min_importance
    )
    SELECT
        c.id,
        c.content,
        c.type,
        1 - (c.embedding <=> query_embedding) as similarity,
        c.importance
    FROM candidates c
    ORDER BY c.embedding <=> query_embedding
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION assign_memory_to_clusters(
    p_memory_id UUID,
    p_max_clusters INT DEFAULT 3
) RETURNS VOID AS $$
DECLARE
    memory_embedding vector;
    cluster_record RECORD;
    similarity_threshold FLOAT := 0.7;
    assigned_count INT := 0;
    zero_vec vector := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
BEGIN
    SELECT embedding INTO memory_embedding
    FROM memories WHERE id = p_memory_id;
    IF memory_embedding IS NULL OR memory_embedding = zero_vec THEN
        RETURN;
    END IF;

    FOR cluster_record IN
        SELECT id, 1 - (centroid_embedding <=> memory_embedding) as similarity
        FROM clusters
        WHERE centroid_embedding IS NOT NULL
          AND centroid_embedding <> zero_vec
        ORDER BY centroid_embedding <=> memory_embedding
        LIMIT 50
    LOOP
        IF cluster_record.similarity >= similarity_threshold AND assigned_count < p_max_clusters THEN
            PERFORM link_memory_to_cluster_graph(p_memory_id, cluster_record.id, cluster_record.similarity);
            assigned_count := assigned_count + 1;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION recalculate_cluster_centroid(p_cluster_id UUID)
RETURNS VOID AS $$
DECLARE
    new_centroid vector;
BEGIN
    SELECT AVG(m.embedding)::vector
    INTO new_centroid
    FROM memories m
    JOIN get_cluster_members_graph(p_cluster_id) gcm ON m.id = gcm.memory_id
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
      AND gcm.membership_strength > 0.3;

    UPDATE clusters
    SET centroid_embedding = new_centroid,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_cluster_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION create_memory_relationship(
    p_from_id UUID,
    p_to_id UUID,
    p_relationship_type graph_edge_type,
    p_properties JSONB DEFAULT '{}'
) RETURNS VOID AS $$
BEGIN
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MATCH (a:MemoryNode {memory_id: %L}), (b:MemoryNode {memory_id: %L})
            CREATE (a)-[r:%s %s]->(b)
            RETURN r
        $q$) as (result ag_catalog.agtype)',
        p_from_id,
        p_to_id,
        p_relationship_type,
        CASE WHEN p_properties = '{}'::jsonb 
             THEN '' 
             ELSE format('{%s}', 
                  (SELECT string_agg(format('%I: %s', key, value), ', ')
                   FROM jsonb_each(p_properties)))
        END
    );
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION auto_check_worldview_alignment()
RETURNS TRIGGER AS $$
DECLARE
    min_support FLOAT;
    min_contradict FLOAT;
    sim FLOAT;
    w RECORD;
    zero_vec vector;
BEGIN
    IF NEW.type <> 'semantic' THEN
        RETURN NEW;
    END IF;
    IF NEW.embedding IS NULL THEN
        RETURN NEW;
    END IF;

    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    IF NEW.embedding = zero_vec THEN
        RETURN NEW;
    END IF;

    min_support := COALESCE(get_config_float('memory.worldview_support_threshold'), 0.8);
    min_contradict := COALESCE(get_config_float('memory.worldview_contradict_threshold'), -0.5);

    BEGIN
        FOR w IN
            SELECT id, embedding
            FROM memories
            WHERE type = 'worldview'
              AND status = 'active'
              AND embedding IS NOT NULL
              AND embedding <> zero_vec
            ORDER BY embedding <=> NEW.embedding
            LIMIT 10
        LOOP
            sim := 1 - (w.embedding <=> NEW.embedding);
            IF sim >= min_support THEN
                PERFORM create_memory_relationship(
                    NEW.id,
                    w.id,
                    'SUPPORTS',
                    jsonb_build_object('strength', sim, 'source', 'auto_alignment')
                );
            ELSIF sim <= min_contradict THEN
                PERFORM create_memory_relationship(
                    NEW.id,
                    w.id,
                    'CONTRADICTS',
                    jsonb_build_object('strength', ABS(sim), 'source', 'auto_alignment')
                );
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION link_memory_to_concept(
    p_memory_id UUID,
    p_concept_name TEXT,
    p_strength FLOAT DEFAULT 1.0
) RETURNS BOOLEAN AS $$
BEGIN
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MERGE (c:ConceptNode {name: %L})
            RETURN c
        $q$) as (result ag_catalog.agtype)',
        p_concept_name
    );
    EXECUTE format(
        'SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
            MATCH (m:MemoryNode {memory_id: %L})
            MATCH (c:ConceptNode {name: %L})
            CREATE (m)-[:INSTANCE_OF {strength: %s}]->(c)
            RETURN m
        $q$) as (result ag_catalog.agtype)',
        p_memory_id,
        p_concept_name,
        p_strength
    );
    RETURN TRUE;
EXCEPTION
    WHEN OTHERS THEN
        RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION create_concept(
    p_name TEXT,
    p_description TEXT DEFAULT NULL,
    p_depth INT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
DECLARE
    desc_literal TEXT;
    depth_literal TEXT;
BEGIN
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RETURN FALSE;
    END IF;

    desc_literal := CASE WHEN p_description IS NULL THEN 'NULL' ELSE quote_literal(p_description) END;
    depth_literal := CASE WHEN p_depth IS NULL THEN 'NULL' ELSE p_depth::text END;

    EXECUTE format('SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
        MERGE (c:ConceptNode {name: %L})
        SET c.description = COALESCE(%s, c.description),
            c.depth = COALESCE(%s, c.depth)
        RETURN c
    $q$) as (result ag_catalog.agtype)', p_name, desc_literal, depth_literal);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION link_concept_parent(
    p_child_name TEXT,
    p_parent_name TEXT
)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_child_name IS NULL OR btrim(p_child_name) = ''
       OR p_parent_name IS NULL OR btrim(p_parent_name) = '' THEN
        RETURN FALSE;
    END IF;

    PERFORM create_concept(p_child_name);
    PERFORM create_concept(p_parent_name);

    EXECUTE format('SELECT * FROM ag_catalog.cypher(''memory_graph'', $q$
        MATCH (child:ConceptNode {name: %L})
        MATCH (parent:ConceptNode {name: %L})
        MERGE (parent)-[:PARENT_OF]->(child)
        RETURN parent
    $q$) as (result ag_catalog.agtype)', p_child_name, p_parent_name);

    RETURN TRUE;
EXCEPTION WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION touch_working_memory(p_ids UUID[])
RETURNS VOID AS $$
BEGIN
    IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
        RETURN;
    END IF;

    UPDATE working_memory
    SET access_count = access_count + 1,
        last_accessed = CURRENT_TIMESTAMP
    WHERE id = ANY(p_ids);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION promote_working_memory_to_episodic(
    p_working_memory_id UUID,
    p_importance FLOAT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    wm RECORD;
    new_id UUID;
    affect JSONB;
    v_valence FLOAT;
    meta JSONB;
BEGIN
    SELECT * INTO wm FROM working_memory WHERE id = p_working_memory_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    affect := get_current_affective_state();
    BEGIN
        v_valence := NULLIF(affect->>'valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            v_valence := 0.0;
    END;
    v_valence := LEAST(1.0, GREATEST(-1.0, COALESCE(v_valence, 0.0)));
    meta := jsonb_build_object(
        'action_taken', NULL,
        'context', jsonb_build_object(
            'from_working_memory_id', wm.id,
            'promoted_at', CURRENT_TIMESTAMP,
            'working_memory_created_at', wm.created_at,
            'working_memory_expiry', wm.expiry,
            'source_attribution', wm.source_attribution
        ),
        'result', NULL,
        'emotional_valence', v_valence,
        'verification_status', NULL,
        'event_time', wm.created_at
    );

    new_id := create_memory_with_embedding(
        'episodic'::memory_type,
        wm.content,
        wm.embedding,
        COALESCE(p_importance, wm.importance, 0.4),
        wm.source_attribution,
        wm.trust_level,
        meta
    );

    RETURN new_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION cleanup_working_memory(
    p_min_importance_to_promote FLOAT DEFAULT 0.75,
    p_min_accesses_to_promote INT DEFAULT 3
)
RETURNS JSONB AS $$
DECLARE
    promoted UUID[] := ARRAY[]::uuid[];
    rec RECORD;
    deleted_count INT := 0;
BEGIN
    FOR rec IN
        SELECT id, importance, access_count, promote_to_long_term
        FROM working_memory
        WHERE expiry < CURRENT_TIMESTAMP
    LOOP
        IF COALESCE(rec.promote_to_long_term, false)
           OR COALESCE(rec.importance, 0) >= COALESCE(p_min_importance_to_promote, 0.75)
           OR COALESCE(rec.access_count, 0) >= COALESCE(p_min_accesses_to_promote, 3)
        THEN
            promoted := array_append(promoted, promote_working_memory_to_episodic(rec.id, rec.importance));
        END IF;
    END LOOP;

    WITH deleted AS (
        DELETE FROM working_memory
        WHERE expiry < CURRENT_TIMESTAMP
        RETURNING 1
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;

    RETURN jsonb_build_object(
        'deleted_count', COALESCE(deleted_count, 0),
        'promoted_count', COALESCE(array_length(promoted, 1), 0),
        'promoted_ids', COALESCE(to_jsonb(promoted), '[]'::jsonb)
    );
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION add_to_working_memory(
    p_content TEXT,
    p_expiry INTERVAL DEFAULT INTERVAL '1 hour',
    p_importance FLOAT DEFAULT 0.3,
    p_source_attribution JSONB DEFAULT NULL,
    p_trust_level FLOAT DEFAULT NULL,
    p_promote_to_long_term BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
	DECLARE
	    new_id UUID;
	    embedding_vec vector;
	    normalized_source JSONB;
	    effective_trust FLOAT;
	BEGIN
	    embedding_vec := (get_embedding(ARRAY[p_content]))[1];

	    normalized_source := normalize_source_reference(p_source_attribution);
	    IF normalized_source = '{}'::jsonb THEN
	        normalized_source := jsonb_build_object('kind', 'internal', 'observed_at', CURRENT_TIMESTAMP);
	    END IF;
	    effective_trust := p_trust_level;
	    IF effective_trust IS NULL THEN
	        effective_trust := 0.8;
	    END IF;
	    effective_trust := LEAST(1.0, GREATEST(0.0, effective_trust));

	    INSERT INTO working_memory (content, embedding, importance, source_attribution, trust_level, promote_to_long_term, expiry)
	    VALUES (
	        p_content,
	        embedding_vec,
	        LEAST(1.0, GREATEST(0.0, COALESCE(p_importance, 0.3))),
	        normalized_source,
	        effective_trust,
	        COALESCE(p_promote_to_long_term, false),
	        CURRENT_TIMESTAMP + p_expiry
	    )
	    RETURNING id INTO new_id;
	    
	    RETURN new_id;
	END;
	$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION search_working_memory(
    p_query_text TEXT,
    p_limit INT DEFAULT 5
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    similarity FLOAT,
    created_at TIMESTAMPTZ
) AS $$
	DECLARE
	    query_embedding vector;
	    zero_vec vector;
	BEGIN
	    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query_text, 'search_query')]))[1];
	    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
	    PERFORM cleanup_working_memory();
	    
	    RETURN QUERY
	    WITH ranked AS (
	        SELECT
	            wm.id,
	            wm.content AS content_text,
	            1 - (wm.embedding <=> query_embedding) as similarity,
	            wm.created_at,
	            (wm.embedding <=> query_embedding) as dist
	        FROM working_memory wm
	        WHERE wm.embedding IS NOT NULL
	          AND wm.embedding <> zero_vec
	        ORDER BY wm.embedding <=> query_embedding
	        LIMIT p_limit
	    ),
	    touched AS (
	        UPDATE working_memory wm
	        SET access_count = access_count + 1,
	            last_accessed = CURRENT_TIMESTAMP
	        WHERE wm.id IN (SELECT id FROM ranked)
	        RETURNING wm.id
	    )
	    SELECT ranked.id AS memory_id, ranked.content_text AS content, ranked.similarity, ranked.created_at
	    FROM ranked
	    ORDER BY ranked.dist;
	END;
	$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION cleanup_embedding_cache(
    p_older_than INTERVAL DEFAULT INTERVAL '7 days'
) RETURNS INT AS $$
DECLARE
    deleted_count INT;
BEGIN
    WITH deleted AS (
        DELETE FROM embedding_cache
        WHERE created_at < CURRENT_TIMESTAMP - p_older_than
        RETURNING 1
    )
    SELECT COUNT(*) INTO deleted_count FROM deleted;
    
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Hybrid recall: combines vector similarity (fast_recall) with Postgres full-text search (tsvector)
-- Returns merged, deduplicated results ranked by a combined score.
CREATE OR REPLACE FUNCTION recall_hybrid(
    p_query_text TEXT,
    p_limit INT DEFAULT 10,
    p_vector_weight FLOAT DEFAULT 0.6,
    p_fts_weight FLOAT DEFAULT 0.4
) RETURNS TABLE (
    memory_id UUID,
    content TEXT,
    memory_type memory_type,
    score FLOAT,
    source TEXT,
    importance FLOAT,
    trust_level FLOAT,
    source_attribution JSONB
) AS $$
DECLARE
    fts_query tsquery;
BEGIN
    -- Build tsquery from natural language
    BEGIN
        fts_query := websearch_to_tsquery('english', p_query_text);
    EXCEPTION WHEN OTHERS THEN
        fts_query := plainto_tsquery('english', p_query_text);
    END;

    RETURN QUERY
    WITH
    -- Vector search results via fast_recall
    vector_hits AS (
        SELECT fr.memory_id, fr.content, fr.memory_type, fr.score AS vector_score, fr.source
        FROM fast_recall(p_query_text, p_limit * 2) fr
    ),
    -- Full-text search results
    fts_hits AS (
        SELECT
            m.id AS memory_id,
            m.content,
            m.type AS memory_type,
            ts_rank_cd(to_tsvector('english', m.content), fts_query)::float AS fts_score,
            'fts'::text AS source
        FROM memories m
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND to_tsvector('english', m.content) @@ fts_query
        ORDER BY fts_score DESC
        LIMIT p_limit * 2
    ),
    -- Merge and deduplicate
    merged AS (
        SELECT
            COALESCE(v.memory_id, f.memory_id) AS mem_id,
            COALESCE(v.content, f.content) AS mem_content,
            COALESCE(v.memory_type, f.memory_type) AS mem_type,
            -- Normalize and combine scores
            (COALESCE(v.vector_score, 0.0) * p_vector_weight +
             COALESCE(f.fts_score, 0.0) * p_fts_weight) AS combined_score,
            CASE
                WHEN v.memory_id IS NOT NULL AND f.memory_id IS NOT NULL THEN 'hybrid'
                WHEN v.memory_id IS NOT NULL THEN v.source
                ELSE 'fts'
            END AS hit_source
        FROM vector_hits v
        FULL OUTER JOIN fts_hits f ON v.memory_id = f.memory_id
    )
    SELECT
        mg.mem_id,
        mg.mem_content,
        mg.mem_type,
        mg.combined_score,
        mg.hit_source,
        m.importance,
        m.trust_level,
        m.source_attribution
    FROM merged mg
    JOIN memories m ON m.id = mg.mem_id
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
    ORDER BY mg.combined_score DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;

SET check_function_bodies = on;
-- ===== END INLINE: db/05_functions_provenance_trust.sql =====


-- ===== BEGIN INLINE: db/09_functions_context.sql =====
-- Hexis schema: context gathering functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION get_environment_snapshot()
RETURNS JSONB AS $$
DECLARE
    last_user TIMESTAMPTZ;
BEGIN
    SELECT last_user_contact INTO last_user FROM heartbeat_state WHERE id = 1;

    RETURN jsonb_build_object(
        'timestamp', CURRENT_TIMESTAMP,
        'time_since_user_hours', CASE
            WHEN last_user IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - last_user)) / 3600
        END,
        'pending_events', 0,
        'day_of_week', EXTRACT(DOW FROM CURRENT_TIMESTAMP),
        'hour_of_day', EXTRACT(HOUR FROM CURRENT_TIMESTAMP)
    );
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_goals_snapshot()
RETURNS JSONB AS $$
DECLARE
    active_goals JSONB;
    queued_goals JSONB;
    issues JSONB;
    stale_days FLOAT;
BEGIN
    stale_days := get_config_float('heartbeat.goal_stale_days');
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id,
        'title', metadata->>'title',
        'description', metadata->>'description',
        'due_at', (metadata->>'due_at')::timestamptz,
        'last_touched', (metadata->>'last_touched')::timestamptz,
        'progress_count', jsonb_array_length(COALESCE(metadata->'progress', '[]'::jsonb)),
        'blocked_by', metadata->'blocked_by'
    )), '[]'::jsonb)
    INTO active_goals
    FROM memories
    WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id,
        'title', metadata->>'title',
        'source', metadata->>'source',
        'due_at', (metadata->>'due_at')::timestamptz
    )), '[]'::jsonb)
    INTO queued_goals
    FROM (
        SELECT * FROM memories
        WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'queued'
        ORDER BY (metadata->>'due_at')::timestamptz NULLS LAST, (metadata->>'last_touched')::timestamptz DESC
        LIMIT 5
    ) q;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'goal_id', id,
        'title', metadata->>'title',
        'issue', CASE
            WHEN metadata->'blocked_by' IS NOT NULL AND metadata->'blocked_by' <> 'null'::jsonb THEN 'blocked'
            WHEN (metadata->>'due_at')::timestamptz IS NOT NULL AND (metadata->>'due_at')::timestamptz < CURRENT_TIMESTAMP THEN 'overdue'
            WHEN (metadata->>'last_touched')::timestamptz < CURRENT_TIMESTAMP - (stale_days || ' days')::INTERVAL THEN 'stale'
            ELSE 'unknown'
        END,
        'due_at', (metadata->>'due_at')::timestamptz,
        'days_since_touched', EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - (metadata->>'last_touched')::timestamptz)) / 86400
    )), '[]'::jsonb)
    INTO issues
    FROM memories
    WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active'
    AND (
        (metadata->'blocked_by' IS NOT NULL AND metadata->'blocked_by' <> 'null'::jsonb)
        OR ((metadata->>'due_at')::timestamptz IS NOT NULL AND (metadata->>'due_at')::timestamptz < CURRENT_TIMESTAMP)
        OR (metadata->>'last_touched')::timestamptz < CURRENT_TIMESTAMP - (stale_days || ' days')::INTERVAL
    );

    RETURN jsonb_build_object(
        'active', active_goals,
        'queued', queued_goals,
        'issues', issues,
        'counts', jsonb_build_object(
            'active', (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'active'),
            'queued', (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'queued'),
            'backburner', (SELECT COUNT(*) FROM memories WHERE type = 'goal' AND status = 'active' AND metadata->>'priority' = 'backburner')
        )
    );
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_goals_by_priority(
    p_priority goal_priority DEFAULT NULL
) RETURNS TABLE (
    id UUID,
    title TEXT,
    description TEXT,
    priority TEXT,
    source TEXT,
    due_at TIMESTAMPTZ,
    last_touched TIMESTAMPTZ,
    progress JSONB,
    blocked_by JSONB,
    emotional_valence FLOAT,
    created_at TIMESTAMPTZ
) AS $$
BEGIN
    IF p_priority IS NULL THEN
        RETURN QUERY
        SELECT
            m.id,
            m.metadata->>'title' as title,
            m.metadata->>'description' as description,
            m.metadata->>'priority' as priority,
            m.metadata->>'source' as source,
            (m.metadata->>'due_at')::timestamptz as due_at,
            (m.metadata->>'last_touched')::timestamptz as last_touched,
            m.metadata->'progress' as progress,
            m.metadata->'blocked_by' as blocked_by,
            (m.metadata->>'emotional_valence')::float as emotional_valence,
            m.created_at
        FROM memories m
        WHERE m.type = 'goal'
          AND m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.metadata->>'priority' IN ('active', 'queued')
        ORDER BY m.metadata->>'priority', (m.metadata->>'last_touched')::timestamptz DESC;
    ELSE
        RETURN QUERY
        SELECT
            m.id,
            m.metadata->>'title' as title,
            m.metadata->>'description' as description,
            m.metadata->>'priority' as priority,
            m.metadata->>'source' as source,
            (m.metadata->>'due_at')::timestamptz as due_at,
            (m.metadata->>'last_touched')::timestamptz as last_touched,
            m.metadata->'progress' as progress,
            m.metadata->'blocked_by' as blocked_by,
            (m.metadata->>'emotional_valence')::float as emotional_valence,
            m.created_at
        FROM memories m
        WHERE m.type = 'goal'
          AND m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.metadata->>'priority' = p_priority::text
        ORDER BY (m.metadata->>'last_touched')::timestamptz DESC;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_recent_context(p_limit INT DEFAULT 5)
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(sub.obj)
        FROM (
            SELECT jsonb_build_object(
                'id', m.id,
                'content', m.content,
                'created_at', m.created_at,
                'emotional_valence', (m.metadata->>'emotional_valence')::float,
                'trust_level', m.trust_level,
                'source_attribution', m.source_attribution
            ) as obj
            FROM memories m
            WHERE m.type = 'episodic'
              AND m.status = 'active'
              AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
            ORDER BY m.created_at DESC
            LIMIT p_limit
        ) sub
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_recent_context_stub(
    p_limit INT DEFAULT 5,
    p_preview_chars INT DEFAULT 256
) RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(sub.obj)
        FROM (
            SELECT jsonb_build_object(
                'id', m.id,
                'preview', LEFT(m.content, p_preview_chars),
                'created_at', m.created_at,
                'emotional_valence', (m.metadata->>'emotional_valence')::float,
                'trust_level', m.trust_level,
                'source_attribution', m.source_attribution,
                'content_length', length(m.content)
            ) as obj
            FROM memories m
            WHERE m.type = 'episodic'
              AND m.status = 'active'
              AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
            ORDER BY m.created_at DESC
            LIMIT p_limit
        ) sub
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_identity_context()
RETURNS JSONB AS $$
DECLARE
    result JSONB := '[]'::jsonb;
BEGIN
    BEGIN
        SELECT COALESCE(jsonb_agg(sub.obj), '[]'::jsonb)
        INTO result
        FROM (
            SELECT jsonb_build_object(
                'type', replace(kind::text, '"', ''),
                'concept', replace(concept::text, '"', ''),
                'strength', (strength::text)::float
            ) as obj
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (s:SelfNode)-[r:ASSOCIATED]->(c)
                RETURN r.kind as kind, c.name as concept, r.strength as strength
                ORDER BY r.strength DESC
                LIMIT 15
            $q$) as (kind ag_catalog.agtype, concept ag_catalog.agtype, strength ag_catalog.agtype)
        ) sub;
    EXCEPTION WHEN OTHERS THEN result := '[]'::jsonb; END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_worldview_context()
RETURNS JSONB AS $$
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(sub.obj)
        FROM (
            SELECT jsonb_build_object(
                'category', metadata->>'category',
                'belief', content,
                'confidence', (metadata->>'confidence')::float,
                'stability', (metadata->>'stability')::float
            ) as obj
            FROM memories
            WHERE type = 'worldview'
              AND status = 'active'
              AND (metadata->>'confidence')::float > 0.5
            ORDER BY (metadata->>'confidence')::float DESC, importance DESC
            LIMIT 5
        ) sub
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_worldview_snapshot(
    p_limit INT DEFAULT 5,
    p_min_confidence FLOAT DEFAULT 0.5
) RETURNS TABLE (
    content TEXT,
    category TEXT,
    confidence FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.content,
        m.metadata->>'category' as category,
        (m.metadata->>'confidence')::float as confidence
        FROM memories m
        WHERE m.type = 'worldview'
          AND m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND COALESCE((m.metadata->>'confidence')::float, 0.0) > COALESCE(p_min_confidence, 0.5)
    ORDER BY (m.metadata->>'confidence')::float DESC, m.importance DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_emotional_patterns_context(p_limit INT DEFAULT 5)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(50, COALESCE(p_limit, 5)));
BEGIN
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'memory_id', m.id,
            'pattern', m.metadata->'supporting_evidence'->>'pattern',
            'frequency', COALESCE((m.metadata->'supporting_evidence'->>'frequency')::int, 0),
            'unprocessed', COALESCE((m.metadata->'supporting_evidence'->>'unprocessed')::boolean, false),
            'summary', m.content
        ))
        FROM (
            SELECT id, content, metadata
            FROM memories
            WHERE type = 'strategic'
              AND metadata->'supporting_evidence'->>'kind' = 'emotional_pattern'
            ORDER BY created_at DESC
            LIMIT lim
        ) m
    ), '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_subconscious_context(
    p_recent_limit INT DEFAULT 20,
    p_self_limit INT DEFAULT 25,
    p_relationship_limit INT DEFAULT 15,
    p_contradiction_limit INT DEFAULT 5,
    p_emotional_pattern_limit INT DEFAULT 5,
    p_trigger_limit INT DEFAULT 5,
    p_trigger_min_similarity FLOAT DEFAULT 0.75
)
RETURNS JSONB AS $$
DECLARE
    recent JSONB;
    seed TEXT;
    emotional_triggers JSONB := '[]'::jsonb;
BEGIN
    recent := COALESCE(get_recent_context(p_recent_limit), '[]'::jsonb);

    SELECT string_agg(content, ' ')
    INTO seed
    FROM (
        SELECT NULLIF(value->>'content', '') as content
        FROM jsonb_array_elements(recent) value
        WHERE value ? 'content'
        LIMIT 5
    ) sub
    WHERE content IS NOT NULL;

    IF COALESCE(p_trigger_limit, 0) > 0 AND seed IS NOT NULL AND seed <> '' THEN
        emotional_triggers := match_emotional_triggers(seed, p_trigger_limit, p_trigger_min_similarity);
    END IF;

    RETURN jsonb_build_object(
        'recent_memories', recent,
        'narrative', get_narrative_context(),
        'self_model', get_self_model_context(p_self_limit),
        'relationships', get_relationships_context(p_relationship_limit),
        'worldview', get_worldview_context(),
        'contradictions', get_contradictions_context(p_contradiction_limit),
        'emotional_patterns', get_emotional_patterns_context(p_emotional_pattern_limit),
        'active_transformations', get_active_transformations_context(5),
        'transformations_ready', check_transformation_readiness(),
        'emotional_state', get_current_affective_state(),
        'emotional_triggers', COALESCE(emotional_triggers, '[]'::jsonb),
        'goals', get_goals_snapshot()
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'recent_memories', recent,
            'emotional_state', get_current_affective_state(),
            'emotional_triggers', '[]'::jsonb
        );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_subconscious_chat_context(
    p_query TEXT,
    p_limit INT DEFAULT 12
)
RETURNS JSONB AS $$
DECLARE
    recall JSONB;
BEGIN
    IF p_query IS NULL OR btrim(p_query) = '' THEN
        recall := '[]'::jsonb;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'memory_id', memory_id,
            'content', content,
            'type', memory_type,
            'score', score,
            'source', source
        )), '[]'::jsonb)
        INTO recall
        FROM fast_recall(p_query, p_limit);
    END IF;

    RETURN jsonb_build_object(
        'prompt', COALESCE(p_query, ''),
        'relevant_memories', recall,
        'emotional_state', get_current_affective_state(),
        'relationships', get_relationships_context(8),
        'goals', get_goals_snapshot()
    );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_chat_context(
    p_query TEXT,
    p_limit INT DEFAULT 8
)
RETURNS JSONB AS $$
DECLARE
    recall JSONB;
BEGIN
    IF p_query IS NULL OR btrim(p_query) = '' THEN
        recall := '[]'::jsonb;
    ELSE
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'memory_id', memory_id,
            'content', content,
            'type', memory_type,
            'score', score,
            'source', source
        )), '[]'::jsonb)
        INTO recall
        FROM fast_recall(p_query, p_limit);
    END IF;

    RETURN jsonb_build_object(
        'agent', get_agent_profile_context(),
        'profile', get_init_profile(),
        'goals', get_goals_snapshot(),
        'identity', get_identity_context(),
        'worldview', get_worldview_context(),
        'relationships', get_relationships_context(10),
        'emotional_state', get_current_affective_state(),
        'relevant_memories', recall
    );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION record_subconscious_exchange(
    p_prompt TEXT,
    p_response JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    valence FLOAT;
    content TEXT;
    memory_id UUID;
BEGIN
    BEGIN
        valence := NULLIF(COALESCE(p_response#>>'{emotional_state,valence}', ''), '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            valence := 0.0;
    END;
    content := format(
        'Prompt: %s%sSubconscious: %s',
        LEFT(COALESCE(p_prompt, ''), 1000),
        E'\n\n',
        LEFT(COALESCE(p_response::text, '{}'), 2000)
    );

    memory_id := create_episodic_memory(
        p_content := content,
        p_action_taken := jsonb_build_object('action', 'subconscious_chat'),
        p_context := jsonb_build_object('prompt', p_prompt),
        p_result := jsonb_build_object('subconscious_response', COALESCE(p_response, '{}'::jsonb)),
        p_emotional_valence := COALESCE(valence, 0.0),
        p_importance := 0.4,
        p_source_attribution := jsonb_build_object('kind', 'subconscious_chat', 'observed_at', CURRENT_TIMESTAMP)
    );

    RETURN memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION record_chat_turn(
    p_user_prompt TEXT,
    p_assistant_response TEXT,
    p_context JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    content TEXT;
    memory_id UUID;
BEGIN
    content := format('User: %s%sAssistant: %s',
        COALESCE(p_user_prompt, ''),
        E'\n\n',
        COALESCE(p_assistant_response, '')
    );

    memory_id := create_episodic_memory(
        p_content := content,
        p_action_taken := jsonb_build_object('action', 'chat_turn'),
        p_context := p_context,
        p_result := NULL,
        p_emotional_valence := 0.0,
        p_importance := 0.6,
        p_source_attribution := jsonb_build_object('kind', 'conversation', 'observed_at', CURRENT_TIMESTAMP)
    );

    RETURN memory_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_contradictions_context(p_limit INT DEFAULT 5)
RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(50, COALESCE(p_limit, 5)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH pairs AS (
            SELECT
                replace(a_id::text, '"', '')::uuid as a_uuid,
                replace(b_id::text, '"', '')::uuid as b_uuid
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (a:MemoryNode)-[:CONTRADICTS]-(b:MemoryNode)
                RETURN a.memory_id, b.memory_id
                LIMIT %s
            $q$) as (a_id ag_catalog.agtype, b_id ag_catalog.agtype)
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'memory_a', p.a_uuid,
            'memory_b', p.b_uuid,
            'content_a', ma.content,
            'content_b', mb.content
        )), '[]'::jsonb)
        FROM pairs p
        JOIN memories ma ON ma.id = p.a_uuid
        JOIN memories mb ON mb.id = p.b_uuid
    $sql$, lim);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_contradictions_stub(
    p_limit INT DEFAULT 5,
    p_preview_chars INT DEFAULT 256
) RETURNS JSONB AS $$
DECLARE
    lim INT := GREATEST(0, LEAST(50, COALESCE(p_limit, 5)));
    sql TEXT;
    out_json JSONB;
BEGIN
    sql := format($sql$
        WITH pairs AS (
            SELECT
                replace(a_id::text, '"', '')::uuid as a_uuid,
                replace(b_id::text, '"', '')::uuid as b_uuid
            FROM ag_catalog.cypher('memory_graph', $q$
                MATCH (a:MemoryNode)-[:CONTRADICTS]-(b:MemoryNode)
                RETURN a.memory_id, b.memory_id
                LIMIT %s
            $q$) as (a_id ag_catalog.agtype, b_id ag_catalog.agtype)
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'memory_a', p.a_uuid,
            'memory_b', p.b_uuid,
            'preview_a', LEFT(ma.content, %s),
            'preview_b', LEFT(mb.content, %s)
        )), '[]'::jsonb)
        FROM pairs p
        JOIN memories ma ON ma.id = p.a_uuid
        JOIN memories mb ON mb.id = p.b_uuid
    $sql$, lim, p_preview_chars, p_preview_chars);

    EXECUTE sql INTO out_json;
    RETURN COALESCE(out_json, '[]'::jsonb);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '[]'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;

SET check_function_bodies = on;
-- ===== END INLINE: db/09_functions_context.sql =====


-- ===== BEGIN INLINE: db/13_functions_emotional_state.sql =====
-- Hexis schema: emotional state functions.
SET search_path = public, ag_catalog, "$user";
SET check_function_bodies = off;

DO $$
DECLARE
    dim INT;
BEGIN
    dim := embedding_dimension();
    EXECUTE format(
        'ALTER TABLE emotional_triggers ALTER COLUMN trigger_embedding TYPE vector(%s) USING trigger_embedding::vector(%s)',
        dim,
        dim
    );
    EXECUTE format(
        'ALTER TABLE memory_activation ALTER COLUMN query_embedding TYPE vector(%s) USING query_embedding::vector(%s)',
        dim,
        dim
    );
END;
$$;
CREATE OR REPLACE FUNCTION normalize_affective_state(p_state JSONB)
RETURNS JSONB AS $$
DECLARE
    baseline JSONB;
    valence FLOAT;
    arousal FLOAT;
    dominance FLOAT;
    intensity FLOAT;
    trigger_summary TEXT;
    secondary_emotion TEXT;
    mood_valence FLOAT;
    mood_arousal FLOAT;
    primary_emotion TEXT;
    source TEXT;
    updated_at TIMESTAMPTZ;
    mood_updated_at TIMESTAMPTZ;
BEGIN
    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);

    BEGIN
        valence := NULLIF(p_state->>'valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            valence := NULL;
    END;
    BEGIN
        arousal := NULLIF(p_state->>'arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            arousal := NULL;
    END;
    BEGIN
        dominance := NULLIF(p_state->>'dominance', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            dominance := NULL;
    END;
    BEGIN
        intensity := NULLIF(p_state->>'intensity', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            intensity := NULL;
    END;
    BEGIN
        mood_valence := NULLIF(p_state->>'mood_valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            mood_valence := NULL;
    END;
    BEGIN
        mood_arousal := NULLIF(p_state->>'mood_arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            mood_arousal := NULL;
    END;
    BEGIN
        updated_at := NULLIF(p_state->>'updated_at', '')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            updated_at := NULL;
    END;
    BEGIN
        mood_updated_at := NULLIF(p_state->>'mood_updated_at', '')::timestamptz;
    EXCEPTION
        WHEN OTHERS THEN
            mood_updated_at := NULL;
    END;

    valence := COALESCE(valence, NULLIF(baseline->>'valence', '')::float, 0.0);
    arousal := COALESCE(arousal, NULLIF(baseline->>'arousal', '')::float, 0.5);
    dominance := COALESCE(dominance, NULLIF(baseline->>'dominance', '')::float, 0.5);
    intensity := COALESCE(intensity, NULLIF(baseline->>'intensity', '')::float, 0.5);
    mood_valence := COALESCE(mood_valence, NULLIF(baseline->>'mood_valence', '')::float, valence);
    mood_arousal := COALESCE(mood_arousal, NULLIF(baseline->>'mood_arousal', '')::float, arousal);

    valence := LEAST(1.0, GREATEST(-1.0, valence));
    arousal := LEAST(1.0, GREATEST(0.0, arousal));
    dominance := LEAST(1.0, GREATEST(0.0, dominance));
    intensity := LEAST(1.0, GREATEST(0.0, intensity));
    mood_valence := LEAST(1.0, GREATEST(-1.0, mood_valence));
    mood_arousal := LEAST(1.0, GREATEST(0.0, mood_arousal));

    primary_emotion := COALESCE(NULLIF(p_state->>'primary_emotion', ''), 'neutral');
    secondary_emotion := NULLIF(p_state->>'secondary_emotion', '');
    trigger_summary := NULLIF(p_state->>'trigger_summary', '');
    source := COALESCE(NULLIF(p_state->>'source', ''), 'derived');
    updated_at := COALESCE(updated_at, CURRENT_TIMESTAMP);
    mood_updated_at := COALESCE(mood_updated_at, updated_at);

    RETURN jsonb_build_object(
        'valence', valence,
        'arousal', arousal,
        'dominance', dominance,
        'primary_emotion', primary_emotion,
        'secondary_emotion', secondary_emotion,
        'intensity', intensity,
        'trigger_summary', trigger_summary,
        'source', source,
        'updated_at', updated_at,
        'mood_valence', mood_valence,
        'mood_arousal', mood_arousal,
        'mood_updated_at', mood_updated_at
    );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION get_current_affective_state()
RETURNS JSONB AS $$
DECLARE
    st RECORD;
    state_json JSONB;
BEGIN
    SELECT * INTO st FROM heartbeat_state WHERE id = 1;

    state_json := COALESCE(st.affective_state, '{}'::jsonb);
    RETURN normalize_affective_state(state_json);
EXCEPTION
    WHEN OTHERS THEN
        RETURN '{}'::jsonb;
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION set_current_affective_state(p_state JSONB)
RETURNS VOID AS $$
DECLARE
    current_state JSONB;
    merged_state JSONB;
BEGIN
    SELECT affective_state INTO current_state FROM heartbeat_state WHERE id = 1;
    merged_state := COALESCE(current_state, '{}'::jsonb) || COALESCE(p_state, '{}'::jsonb);
    merged_state := jsonb_set(merged_state, '{updated_at}', to_jsonb(CURRENT_TIMESTAMP), true);
    merged_state := normalize_affective_state(merged_state);

    UPDATE heartbeat_state
    SET affective_state = merged_state,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_emotional_context_for_memory()
RETURNS JSONB AS $$
DECLARE
    st JSONB;
BEGIN
    st := get_current_affective_state();
    RETURN jsonb_build_object(
        'valence', (st->>'valence')::float,
        'arousal', (st->>'arousal')::float,
        'dominance', (st->>'dominance')::float,
        'primary_emotion', COALESCE(st->>'primary_emotion', 'neutral'),
        'intensity', (st->>'intensity')::float,
        'source', COALESCE(st->>'source', 'derived')
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'valence', 0.0,
            'arousal', 0.5,
            'dominance', 0.5,
            'primary_emotion', 'neutral',
            'intensity', 0.5,
            'source', 'default'
        );
END;
$$ LANGUAGE plpgsql STABLE;
CREATE OR REPLACE FUNCTION regulate_emotional_state(
    p_regulation_type TEXT,
    p_target_emotion TEXT DEFAULT NULL,
    p_intensity_change FLOAT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    current_state JSONB;
    new_valence FLOAT;
    new_arousal FLOAT;
    new_intensity FLOAT;
    new_primary TEXT;
    dominance FLOAT;
BEGIN
    current_state := get_current_affective_state();
    new_valence := COALESCE((current_state->>'valence')::float, 0.0);
    new_arousal := COALESCE((current_state->>'arousal')::float, 0.5);
    new_intensity := COALESCE((current_state->>'intensity')::float, 0.5);
    dominance := COALESCE((current_state->>'dominance')::float, 0.5);
    new_primary := COALESCE(NULLIF(p_target_emotion, ''), current_state->>'primary_emotion', 'neutral');

    CASE p_regulation_type
        WHEN 'suppress' THEN
            new_valence := new_valence * 0.3;
            new_arousal := new_arousal * 0.5 + 0.15;
            new_intensity := new_intensity * 0.3;
        WHEN 'reduce' THEN
            new_valence := new_valence * 0.7;
            new_arousal := new_arousal * 0.8;
            new_intensity := new_intensity * 0.6;
        WHEN 'amplify' THEN
            new_valence := new_valence * 1.3;
            new_arousal := LEAST(1.0, new_arousal * 1.2);
            new_intensity := LEAST(1.0, new_intensity * 1.5);
        WHEN 'reframe' THEN
            new_valence := COALESCE(
                CASE WHEN p_target_emotion IN ('interest', 'curiosity') THEN 0.2
                     WHEN p_target_emotion IN ('acceptance', 'peace') THEN 0.1
                     ELSE new_valence * 0.5
                END,
                new_valence * 0.5
            );
            new_arousal := new_arousal * 0.8;
            new_intensity := new_intensity * 0.7;
        ELSE
            RETURN jsonb_build_object('error', 'unknown_regulation_type');
    END CASE;

    PERFORM set_current_affective_state(jsonb_build_object(
        'valence', new_valence,
        'arousal', new_arousal,
        'dominance', dominance,
        'primary_emotion', new_primary,
        'intensity', new_intensity,
        'source', 'regulated',
        'trigger_summary', format('Regulated via %s', p_regulation_type)
    ));

    RETURN jsonb_build_object(
        'success', true,
        'regulation_type', p_regulation_type,
        'before', current_state,
        'after', get_current_affective_state()
    );
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION sense_memory_availability(
    p_query TEXT,
    p_query_embedding vector DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    query_emb vector;
    zero_vec vector;
    estimated_count INT;
    top_similarity FLOAT;
    activation_id UUID;
BEGIN
    query_emb := COALESCE(p_query_embedding, (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1]);
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;

    SELECT
        COUNT(*),
        MAX(1 - (embedding <=> query_emb))
    INTO estimated_count, top_similarity
    FROM memories
    WHERE status = 'active'
      AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
      AND embedding IS NOT NULL
      AND embedding <> zero_vec
      AND (1 - (embedding <=> query_emb)) > 0.5
    LIMIT 100;

    INSERT INTO memory_activation (
        query_embedding,
        query_text,
        estimated_matches,
        activation_strength
    ) VALUES (
        query_emb,
        p_query,
        estimated_count,
        COALESCE(top_similarity, 0)
    )
    RETURNING id INTO activation_id;

    RETURN jsonb_build_object(
        'feeling', CASE
            WHEN estimated_count = 0 THEN 'nothing'
            WHEN estimated_count <= 2 THEN 'vague'
            WHEN estimated_count <= 5 THEN 'something'
            WHEN estimated_count <= 10 THEN 'familiar'
            ELSE 'rich'
        END,
        'estimated_count', estimated_count,
        'strongest_match', top_similarity,
        'activation_id', activation_id,
        'description', CASE
            WHEN estimated_count = 0 THEN 'I don''t think I know anything about this'
            WHEN top_similarity > 0.8 THEN 'I know this well - let me recall'
            WHEN top_similarity > 0.6 THEN 'This feels familiar - I should be able to remember'
            WHEN estimated_count > 0 THEN 'I might know something about this - it''s not coming immediately'
            ELSE 'I don''t think I know anything about this'
        END
    );
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION request_background_search(
    p_query TEXT,
    p_query_embedding vector DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    query_emb vector;
    activation_id UUID;
BEGIN
    query_emb := COALESCE(p_query_embedding, (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1]);

    INSERT INTO memory_activation (
        query_embedding,
        query_text,
        retrieval_attempted,
        retrieval_succeeded,
        background_search_pending,
        background_search_started_at
    ) VALUES (
        query_emb,
        p_query,
        TRUE,
        FALSE,
        TRUE,
        CURRENT_TIMESTAMP
    )
    RETURNING id INTO activation_id;

    RETURN activation_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION process_background_searches(
    p_limit INT DEFAULT 10,
    p_min_age INTERVAL DEFAULT INTERVAL '30 seconds'
)
RETURNS INT AS $$
DECLARE
    pending RECORD;
    processed_count INT := 0;
BEGIN
    FOR pending IN
        SELECT * FROM memory_activation
        WHERE background_search_pending = TRUE
          AND background_search_started_at <= CURRENT_TIMESTAMP - p_min_age
        ORDER BY created_at ASC
        LIMIT GREATEST(1, COALESCE(p_limit, 10))
    LOOP
        UPDATE memories
        SET metadata = jsonb_set(
            COALESCE(metadata, '{}'::jsonb),
            '{activation_boost}',
            to_jsonb(COALESCE((metadata->>'activation_boost')::float, 0) + 0.2)
        )
        WHERE status = 'active'
          AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
          AND (1 - (embedding <=> pending.query_embedding)) > 0.6;

        UPDATE memory_activation
        SET background_search_pending = FALSE,
            retrieval_succeeded = TRUE
        WHERE id = pending.id;

        processed_count := processed_count + 1;
    END LOOP;

    RETURN processed_count;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION decay_activation_boosts(p_decay FLOAT DEFAULT 0.05)
RETURNS INT AS $$
DECLARE
    updated_count INT;
BEGIN
    UPDATE memories
    SET metadata = jsonb_set(
        COALESCE(metadata, '{}'::jsonb),
        '{activation_boost}',
        to_jsonb(GREATEST(0, COALESCE((metadata->>'activation_boost')::float, 0) - COALESCE(p_decay, 0.05)))
    )
    WHERE (metadata->>'activation_boost')::float > 0;
    GET DIAGNOSTICS updated_count = ROW_COUNT;
    RETURN COALESCE(updated_count, 0);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION cleanup_memory_activations()
RETURNS INT AS $$
DECLARE
    deleted_count INT;
BEGIN
    DELETE FROM memory_activation WHERE expires_at < CURRENT_TIMESTAMP;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN COALESCE(deleted_count, 0);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION get_spontaneous_memories(p_limit INT DEFAULT 3)
RETURNS SETOF memories AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM memories
    WHERE status = 'active'
      AND (valid_until IS NULL OR valid_until > CURRENT_TIMESTAMP)
      AND (metadata->>'activation_boost')::float > 0.3
    ORDER BY (metadata->>'activation_boost')::float DESC
    LIMIT GREATEST(1, COALESCE(p_limit, 3));
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION update_mood()
RETURNS VOID AS $$
DECLARE
    baseline JSONB;
    decay_rate FLOAT;
    current_state JSONB;
    recent RECORD;
    new_mood_valence FLOAT;
    new_mood_arousal FLOAT;
BEGIN
    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);
    decay_rate := COALESCE(NULLIF(baseline->>'decay_rate', '')::float, 0.1);

    current_state := get_current_affective_state();

    SELECT
        AVG(NULLIF(m.metadata->>'emotional_valence', '')::float) as avg_valence,
        COUNT(*) as sample_count
    INTO recent
    FROM memories m
    WHERE m.type = 'episodic'
      AND m.metadata#>>'{context,heartbeat_id}' IS NOT NULL
      AND COALESCE((m.metadata->>'event_time')::timestamptz, m.created_at)
            > CURRENT_TIMESTAMP - INTERVAL '2 hours'
      AND m.metadata->>'emotional_valence' IS NOT NULL;

    new_mood_valence := COALESCE((current_state->>'mood_valence')::float, 0.0);
    new_mood_arousal := COALESCE((current_state->>'mood_arousal')::float, 0.3);

    IF recent.sample_count > 0 THEN
        new_mood_valence := new_mood_valence * (1 - decay_rate) + COALESCE(recent.avg_valence, 0.0) * decay_rate;
    ELSE
        new_mood_valence := new_mood_valence * (1 - decay_rate);
    END IF;

    new_mood_arousal := new_mood_arousal * (1 - decay_rate * 0.5)
        + COALESCE(NULLIF(baseline->>'mood_arousal', '')::float, 0.3) * decay_rate * 0.5;

    PERFORM set_current_affective_state(jsonb_build_object(
        'mood_valence', new_mood_valence,
        'mood_arousal', new_mood_arousal,
        'mood_updated_at', CURRENT_TIMESTAMP
    ));
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION learn_emotional_trigger(
    p_trigger_text TEXT,
    p_trigger_embedding vector,
    p_emotional_response JSONB,
    p_source_memory_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    existing RECORD;
    baseline JSONB;
    trigger_id UUID;
BEGIN
    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);

    SELECT * INTO existing
    FROM emotional_triggers
    WHERE (1 - (trigger_embedding <=> p_trigger_embedding)) > 0.85
    ORDER BY (1 - (trigger_embedding <=> p_trigger_embedding)) DESC
    LIMIT 1;

    IF existing IS NOT NULL THEN
        UPDATE emotional_triggers
        SET
            valence_delta = (valence_delta * times_activated +
                ((p_emotional_response->>'valence')::float - COALESCE((baseline->>'valence')::float, 0.0)))
                / (times_activated + 1),
            arousal_delta = (arousal_delta * times_activated +
                ((p_emotional_response->>'arousal')::float - COALESCE((baseline->>'arousal')::float, 0.3)))
                / (times_activated + 1),
            dominance_delta = (dominance_delta * times_activated +
                ((p_emotional_response->>'dominance')::float - COALESCE((baseline->>'dominance')::float, 0.5)))
                / (times_activated + 1),
            times_activated = times_activated + 1,
            confidence = LEAST(0.95, confidence + 0.02),
            last_activated_at = CURRENT_TIMESTAMP,
            source_memory_ids = CASE
                WHEN p_source_memory_id IS NOT NULL THEN array_append(source_memory_ids, p_source_memory_id)
                ELSE source_memory_ids
            END
        WHERE id = existing.id;
        RETURN existing.id;
    END IF;

    INSERT INTO emotional_triggers (
        trigger_pattern,
        trigger_embedding,
        valence_delta,
        arousal_delta,
        dominance_delta,
        typical_emotion,
        origin,
        source_memory_ids,
        last_activated_at
    ) VALUES (
        p_trigger_text,
        p_trigger_embedding,
        (p_emotional_response->>'valence')::float - COALESCE((baseline->>'valence')::float, 0.0),
        (p_emotional_response->>'arousal')::float - COALESCE((baseline->>'arousal')::float, 0.3),
        (p_emotional_response->>'dominance')::float - COALESCE((baseline->>'dominance')::float, 0.5),
        p_emotional_response->>'primary_emotion',
        'learned',
        CASE WHEN p_source_memory_id IS NOT NULL THEN ARRAY[p_source_memory_id] ELSE '{}'::uuid[] END,
        CURRENT_TIMESTAMP
    )
    RETURNING id INTO trigger_id;

    RETURN trigger_id;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION match_emotional_triggers(
    p_text TEXT,
    p_limit INT DEFAULT 5,
    p_min_similarity FLOAT DEFAULT 0.75
) RETURNS JSONB AS $$
DECLARE
    query_emb vector;
BEGIN
    IF p_text IS NULL OR btrim(p_text) = '' THEN
        RETURN '[]'::jsonb;
    END IF;

    BEGIN
        query_emb := (get_embedding(ARRAY[ensure_embedding_prefix(p_text, 'search_query')]))[1];
    EXCEPTION
        WHEN OTHERS THEN
            RETURN '[]'::jsonb;
    END;

    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'trigger_pattern', trigger_pattern,
            'similarity', sim,
            'typical_emotion', typical_emotion,
            'valence_delta', valence_delta,
            'arousal_delta', arousal_delta,
            'dominance_delta', dominance_delta,
            'confidence', confidence,
            'times_activated', times_activated
        ))
        FROM (
            SELECT
                et.*,
                (1 - (et.trigger_embedding <=> query_emb))::float as sim
            FROM emotional_triggers et
            WHERE (1 - (et.trigger_embedding <=> query_emb)) >= COALESCE(p_min_similarity, 0.75)
            ORDER BY sim DESC
            LIMIT GREATEST(1, COALESCE(p_limit, 5))
        ) ranked
    ), '[]'::jsonb);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION initialize_innate_emotions()
RETURNS INT AS $$
DECLARE
    inserted_count INT := 0;
BEGIN
    BEGIN
        WITH seed(idx, trigger_pattern, valence_delta, arousal_delta, dominance_delta, typical_emotion) AS (
            VALUES
                (1, 'gratitude appreciation thankful', 0.4, 0.1, 0.1, 'joy'),
                (2, 'success achieved accomplished', 0.5, 0.3, 0.3, 'pride'),
                (3, 'curious interesting fascinating', 0.3, 0.3, 0.1, 'interest'),
                (4, 'understood seen connected', 0.4, 0.2, 0.2, 'warmth'),
                (5, 'beautiful elegant aesthetic', 0.3, 0.2, 0.1, 'appreciation'),
                (6, 'learned insight realized', 0.4, 0.4, 0.2, 'satisfaction'),
                (7, 'threat danger harm', -0.5, 0.6, -0.3, 'fear'),
                (8, 'rejection dismissed ignored', -0.4, 0.2, -0.2, 'sadness'),
                (9, 'unfair unjust wrong', -0.4, 0.5, 0.2, 'anger'),
                (10, 'confused lost uncertain', -0.2, 0.3, -0.2, 'anxiety'),
                (11, 'failed mistake error', -0.3, 0.3, -0.1, 'disappointment'),
                (12, 'violated boundary crossed', -0.5, 0.5, -0.2, 'alarm'),
                (13, 'unexpected surprise sudden', 0.0, 0.6, -0.1, 'surprise'),
                (14, 'conflict tension disagree', -0.2, 0.4, 0.0, 'discomfort')
        ),
        embeds AS (
            SELECT get_embedding(ARRAY(SELECT trigger_pattern FROM seed ORDER BY idx)) AS embeddings
        )
        INSERT INTO emotional_triggers (trigger_pattern, trigger_embedding, valence_delta, arousal_delta, dominance_delta, typical_emotion, origin)
        SELECT
            seed.trigger_pattern,
            (embeds.embeddings)[seed.idx],
            seed.valence_delta,
            seed.arousal_delta,
            seed.dominance_delta,
            seed.typical_emotion,
            'innate'
        FROM seed
        CROSS JOIN embeds
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS inserted_count = ROW_COUNT;
    EXCEPTION
        WHEN OTHERS THEN
            inserted_count := 0;
    END;

    RETURN inserted_count;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION ensure_emotion_bootstrap()
RETURNS VOID AS $$
DECLARE
    initialized JSONB;
    baseline JSONB;
BEGIN
    initialized := COALESCE(get_config('emotion.initialized'), 'false'::jsonb);
    IF initialized = 'true'::jsonb THEN
        RETURN;
    END IF;

    baseline := COALESCE(get_config('emotion.baseline'), '{}'::jsonb);
    PERFORM set_current_affective_state(jsonb_build_object(
        'valence', COALESCE((baseline->>'valence')::float, 0.0),
        'arousal', COALESCE((baseline->>'arousal')::float, 0.3),
        'dominance', COALESCE((baseline->>'dominance')::float, 0.5),
        'intensity', COALESCE((baseline->>'intensity')::float, 0.4),
        'mood_valence', COALESCE((baseline->>'mood_valence')::float, 0.0),
        'mood_arousal', COALESCE((baseline->>'mood_arousal')::float, 0.3),
        'source', 'baseline'
    ));

    PERFORM initialize_innate_emotions();
    PERFORM set_config('emotion.initialized', 'true'::jsonb);
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION apply_emotional_context_to_memory()
RETURNS TRIGGER AS $$
DECLARE
    meta JSONB;
    context JSONB;
    state JSONB;
    valence FLOAT;
    arousal FLOAT;
    dominance FLOAT;
    intensity FLOAT;
    primary_emotion TEXT;
    source TEXT;
BEGIN
    meta := COALESCE(NEW.metadata, '{}'::jsonb);
    context := COALESCE(meta->'emotional_context', '{}'::jsonb);
    state := get_current_affective_state();

    BEGIN
        valence := NULLIF(meta->>'emotional_valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            valence := NULL;
    END;
    BEGIN
        arousal := NULLIF(context->>'arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            arousal := NULL;
    END;
    BEGIN
        dominance := NULLIF(context->>'dominance', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            dominance := NULL;
    END;
    BEGIN
        intensity := NULLIF(context->>'intensity', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            intensity := NULL;
    END;

    valence := COALESCE(valence, NULLIF(context->>'valence', '')::float, (state->>'valence')::float, 0.0);
    arousal := COALESCE(arousal, NULLIF(state->>'arousal', '')::float, 0.5);
    dominance := COALESCE(dominance, NULLIF(state->>'dominance', '')::float, 0.5);
    intensity := COALESCE(intensity, NULLIF(state->>'intensity', '')::float, 0.5);
    primary_emotion := COALESCE(NULLIF(context->>'primary_emotion', ''), NULLIF(state->>'primary_emotion', ''), 'neutral');
    source := COALESCE(NULLIF(context->>'source', ''), NULLIF(state->>'source', ''), 'derived');

    valence := LEAST(1.0, GREATEST(-1.0, valence));
    arousal := LEAST(1.0, GREATEST(0.0, arousal));
    dominance := LEAST(1.0, GREATEST(0.0, dominance));
    intensity := LEAST(1.0, GREATEST(0.0, intensity));

    context := jsonb_build_object(
        'valence', valence,
        'arousal', arousal,
        'dominance', dominance,
        'primary_emotion', primary_emotion,
        'intensity', intensity,
        'source', source
    );

    NEW.metadata := meta || jsonb_build_object(
        'emotional_context', context,
        'emotional_valence', valence
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION gather_turn_context()
RETURNS JSONB AS $$
DECLARE
    state_record RECORD;
    action_costs JSONB;
    contradictions JSONB;
    allowed_actions JSONB;
BEGIN
    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    allowed_actions := get_config('heartbeat.allowed_actions');
    IF jsonb_typeof(allowed_actions) = 'array' THEN
        SELECT jsonb_object_agg(
            regexp_replace(key, '^heartbeat\.cost_', ''),
            value
        ) INTO action_costs
        FROM config
        WHERE key LIKE 'heartbeat.cost_%'
          AND regexp_replace(key, '^heartbeat\.cost_', '') IN (
              SELECT value FROM jsonb_array_elements_text(allowed_actions)
          );
    ELSE
        SELECT jsonb_object_agg(
            regexp_replace(key, '^heartbeat\.cost_', ''),
            value
        ) INTO action_costs
        FROM config
        WHERE key LIKE 'heartbeat.cost_%';
    END IF;
    action_costs := COALESCE(action_costs, '{}'::jsonb);

    contradictions := get_contradictions_context(5);

    RETURN jsonb_build_object(
        'agent', get_agent_profile_context(),
        'environment', get_environment_snapshot(),
        'goals', get_goals_snapshot(),
        'recent_memories', get_recent_context(5),
        'identity', get_identity_context(),
        'worldview', get_worldview_context(),
        'self_model', get_self_model_context(25),
        'narrative', get_narrative_context(),
        'relationships', get_relationships_context(10),
        'contradictions', contradictions,
        'contradictions_count', COALESCE(jsonb_array_length(contradictions), 0),
        'emotional_patterns', get_emotional_patterns_context(5),
        'active_transformations', get_active_transformations_context(5),
        'transformations_ready', check_transformation_readiness(),
        'energy', jsonb_build_object(
            'current', state_record.current_energy,
            'max', get_config_float('heartbeat.max_energy')
        ),
        'allowed_actions', allowed_actions,
        'action_costs', action_costs,
        'heartbeat_number', state_record.heartbeat_count,
        'urgent_drives', (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'name', name,
                        'level', current_level,
                        'urgency_ratio', current_level / NULLIF(urgency_threshold, 0)
                    )
                    ORDER BY current_level DESC
                ),
                '[]'::jsonb
            )
            FROM drives
            WHERE current_level >= urgency_threshold * 0.8
        ),
        'emotional_state', get_current_affective_state()
    );
END;
$$ LANGUAGE plpgsql;

-- Snapshot variant for RLM: uses stub-only recent memories and contradictions
CREATE OR REPLACE FUNCTION gather_turn_snapshot()
RETURNS JSONB AS $$
DECLARE
    state_record RECORD;
    action_costs JSONB;
    contradictions JSONB;
    allowed_actions JSONB;
BEGIN
    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    allowed_actions := get_config('heartbeat.allowed_actions');

    IF jsonb_typeof(allowed_actions) = 'array' THEN
        SELECT jsonb_object_agg(
            regexp_replace(key, '^heartbeat\.cost_', ''),
            value
        ) INTO action_costs
        FROM config
        WHERE key LIKE 'heartbeat.cost_%'
          AND regexp_replace(key, '^heartbeat\.cost_', '') IN (
              SELECT value FROM jsonb_array_elements_text(allowed_actions)
          );
    ELSE
        SELECT jsonb_object_agg(
            regexp_replace(key, '^heartbeat\.cost_', ''),
            value
        ) INTO action_costs
        FROM config
        WHERE key LIKE 'heartbeat.cost_%';
    END IF;
    action_costs := COALESCE(action_costs, '{}'::jsonb);

    contradictions := get_contradictions_stub(5);

    RETURN jsonb_build_object(
        'agent', get_agent_profile_context(),
        'environment', get_environment_snapshot(),
        'goals', get_goals_snapshot(),
        'recent_memory_stubs', get_recent_context_stub(5),
        'identity', get_identity_context(),
        'worldview', get_worldview_context(),
        'self_model', get_self_model_context(10),
        'narrative', get_narrative_context(),
        'relationships', get_relationships_context(6),
        'contradictions', contradictions,
        'contradictions_count', COALESCE(jsonb_array_length(contradictions), 0),
        'emotional_patterns', get_emotional_patterns_context(5),
        'active_transformations', get_active_transformations_context(5),
        'transformations_ready', check_transformation_readiness(),
        'energy', jsonb_build_object(
            'current', state_record.current_energy,
            'max', get_config_float('heartbeat.max_energy')
        ),
        'allowed_actions', allowed_actions,
        'action_costs', action_costs,
        'heartbeat_number', state_record.heartbeat_count,
        'urgent_drives', (
            SELECT COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'name', name,
                        'level', current_level,
                        'urgency_ratio', current_level / NULLIF(urgency_threshold, 0)
                    )
                    ORDER BY current_level DESC
                ),
                '[]'::jsonb
            )
            FROM drives
            WHERE current_level >= urgency_threshold * 0.8
        ),
        'emotional_state', get_current_affective_state(),
        'backlog', get_backlog_snapshot()
    );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION complete_heartbeat(
    p_heartbeat_id UUID,
    p_reasoning TEXT,
    p_actions_taken JSONB,
    p_goals_modified JSONB DEFAULT '[]',
    p_emotional_assessment JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    narrative_text TEXT;
    memory_id_created UUID;
    hb_number INT;
    state_record RECORD;
    prev_state JSONB;
    prev_valence FLOAT;
    prev_arousal FLOAT;
    prev_dominance FLOAT;
    new_valence FLOAT;
    new_arousal FLOAT;
    primary_emotion TEXT;
    intensity FLOAT;
    action_elem JSONB;
    goal_elem JSONB;
    goal_change TEXT;
    assess_valence FLOAT;
    assess_arousal FLOAT;
    assess_primary TEXT;
    mem_importance FLOAT;
BEGIN
    SELECT active_heartbeat_number INTO hb_number FROM heartbeat_state WHERE id = 1;
    IF hb_number IS NULL THEN
        SELECT heartbeat_count INTO hb_number FROM heartbeat_state WHERE id = 1;
    END IF;

    SELECT string_agg(
        format('- %s: %s',
            a->>'action',
            CASE
                WHEN COALESCE((a->'result'->>'success')::boolean, true) = false THEN 'failed'
                ELSE 'completed'
            END
        ), E'\n'
    ) INTO narrative_text
    FROM jsonb_array_elements(p_actions_taken) a;

    narrative_text := format('Heartbeat #%s: %s', hb_number, COALESCE(narrative_text, 'No actions taken'));

    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    prev_state := COALESCE(state_record.affective_state, '{}'::jsonb);

    BEGIN
        prev_valence := NULLIF(prev_state->>'valence', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            prev_valence := NULL;
    END;
    BEGIN
        prev_arousal := NULLIF(prev_state->>'arousal', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            prev_arousal := NULL;
    END;

    prev_valence := COALESCE(prev_valence, 0.0);
    prev_arousal := COALESCE(prev_arousal, 0.5);
    BEGIN
        prev_dominance := NULLIF(prev_state->>'dominance', '')::float;
    EXCEPTION
        WHEN OTHERS THEN
            prev_dominance := NULL;
    END;
    prev_dominance := COALESCE(prev_dominance, 0.5);
    new_valence := prev_valence * 0.8;
    new_arousal := 0.5 + (prev_arousal - 0.5) * 0.8;
    FOR action_elem IN SELECT * FROM jsonb_array_elements(COALESCE(p_actions_taken, '[]'::jsonb))
    LOOP
        IF (action_elem->'result'->>'error') = 'Boundary triggered' THEN
            new_valence := new_valence - 0.4;
            new_arousal := new_arousal + 0.3;
        ELSIF COALESCE((action_elem->'result'->>'success')::boolean, true) = false THEN
            new_valence := new_valence - 0.1;
            new_arousal := new_arousal + 0.1;
        END IF;

        IF (action_elem->>'action') IN ('reach_out_user', 'reach_out_public') THEN
            IF COALESCE((action_elem->'result'->>'success')::boolean, true) = true THEN
                new_valence := new_valence + 0.2;
                new_arousal := new_arousal + 0.1;
            END IF;
        END IF;

        IF (action_elem->>'action') = 'rest' THEN
            new_valence := new_valence + 0.1;
            new_arousal := new_arousal - 0.2;
        END IF;
    END LOOP;
    FOR goal_elem IN SELECT * FROM jsonb_array_elements(COALESCE(p_goals_modified, '[]'::jsonb))
    LOOP
        goal_change := COALESCE(goal_elem->>'new_priority', goal_elem->>'change', goal_elem->>'priority', '');

        IF goal_change = 'completed' THEN
            new_valence := new_valence + 0.3;
            new_arousal := new_arousal + 0.1;
        ELSIF goal_change = 'abandoned' THEN
            new_valence := new_valence - 0.2;
            new_arousal := new_arousal - 0.1;
        END IF;
    END LOOP;
    assess_valence := NULL;
    assess_arousal := NULL;
    assess_primary := NULL;
    IF p_emotional_assessment IS NOT NULL AND jsonb_typeof(p_emotional_assessment) = 'object' THEN
        BEGIN
            assess_valence := NULLIF(p_emotional_assessment->>'valence', '')::float;
        EXCEPTION
            WHEN OTHERS THEN
                assess_valence := NULL;
        END;
        BEGIN
            assess_arousal := NULLIF(p_emotional_assessment->>'arousal', '')::float;
        EXCEPTION
            WHEN OTHERS THEN
                assess_arousal := NULL;
        END;
        assess_primary := NULLIF(p_emotional_assessment->>'primary_emotion', '');
    END IF;

    IF assess_valence IS NOT NULL THEN
        new_valence := new_valence * 0.6 + LEAST(1.0, GREATEST(-1.0, assess_valence)) * 0.4;
    END IF;
    IF assess_arousal IS NOT NULL THEN
        new_arousal := new_arousal * 0.6 + LEAST(1.0, GREATEST(0.0, assess_arousal)) * 0.4;
    END IF;

    new_valence := LEAST(1.0, GREATEST(-1.0, new_valence));
    new_arousal := LEAST(1.0, GREATEST(0.0, new_arousal));

    primary_emotion := COALESCE(
        assess_primary,
        CASE
            WHEN new_valence > 0.2 AND new_arousal > 0.6 THEN 'excited'
            WHEN new_valence > 0.2 THEN 'content'
            WHEN new_valence < -0.2 AND new_arousal > 0.6 THEN 'anxious'
            WHEN new_valence < -0.2 THEN 'down'
            ELSE 'neutral'
        END
    );

    intensity := LEAST(1.0, GREATEST(0.0, (ABS(new_valence) * 0.6 + new_arousal * 0.4)));
    UPDATE heartbeat_state SET
        affective_state = normalize_affective_state(
            COALESCE(prev_state, '{}'::jsonb) || jsonb_build_object(
                'valence', new_valence,
                'arousal', new_arousal,
                'dominance', prev_dominance,
                'primary_emotion', primary_emotion,
                'intensity', intensity,
                'updated_at', CURRENT_TIMESTAMP,
                'source', CASE WHEN p_emotional_assessment IS NULL THEN 'derived' ELSE 'blended' END
            )
        )
    WHERE id = 1;

    mem_importance := LEAST(1.0, GREATEST(0.4, 0.5 + intensity * 0.25));

    memory_id_created := create_episodic_memory(
        p_content := narrative_text,
        p_context := jsonb_build_object(
            'heartbeat_id', p_heartbeat_id,
            'heartbeat_number', hb_number,
            'reasoning', p_reasoning,
            'actions_taken', p_actions_taken,
            'goal_changes', p_goals_modified,
            'affective_state', get_current_affective_state()
        ),
        p_emotional_valence := new_valence,
        p_importance := mem_importance
    );

    RAISE LOG 'Heartbeat % completed: %', hb_number, narrative_text;
    UPDATE heartbeat_state SET
        next_heartbeat_at = CURRENT_TIMESTAMP +
            (get_config_float('heartbeat.heartbeat_interval_minutes') || ' minutes')::INTERVAL,
        active_heartbeat_id = NULL,
        active_heartbeat_number = NULL,
        active_actions = '[]'::jsonb,
        active_reasoning = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = 1;

    RETURN memory_id_created;
END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION finalize_heartbeat(
    p_heartbeat_id UUID,
    p_reasoning TEXT,
    p_actions_taken JSONB,
    p_goal_changes JSONB DEFAULT '[]',
    p_emotional_assessment JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    actions JSONB := COALESCE(p_actions_taken, '[]'::jsonb);
    goals JSONB := COALESCE(p_goal_changes, '[]'::jsonb);
    memory_id_created UUID;
BEGIN
    IF jsonb_typeof(actions) <> 'array' THEN
        actions := '[]'::jsonb;
    END IF;
    IF jsonb_typeof(goals) <> 'array' THEN
        goals := '[]'::jsonb;
    END IF;

    PERFORM apply_goal_changes(goals);

    memory_id_created := complete_heartbeat(
        p_heartbeat_id,
        p_reasoning,
        actions,
        goals,
        p_emotional_assessment
    );
    RETURN memory_id_created;
END;
$$ LANGUAGE plpgsql;

SET check_function_bodies = on;
-- ===== END INLINE: db/13_functions_emotional_state.sql =====


-- ===== BEGIN INLINE: db/31_functions_recmem.sql =====
-- RecMem: recurrence-based memory consolidation.

CREATE OR REPLACE FUNCTION format_recmem_turn(
    p_user_text TEXT,
    p_assistant_text TEXT
) RETURNS TEXT AS $$
BEGIN
    RETURN format(
        'User: %s%sAssistant: %s',
        COALESCE(p_user_text, ''),
        E'\n\n',
        COALESCE(p_assistant_text, '')
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION normalize_recmem_text(
    p_text TEXT
) RETURNS TEXT AS $$
    SELECT regexp_replace(
        regexp_replace(
            regexp_replace(
                replace(replace(COALESCE($1, ''), E'\r\n', E'\n'), E'\r', E'\n'),
                '[ \t]+$', '', 'gm'
            ),
            '^\n+', ''
        ),
        '\n+$', ''
    );
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION compute_recmem_idempotency_key(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_session_id UUID DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL
) RETURNS TEXT AS $$
DECLARE
    normalized TEXT;
BEGIN
    IF NULLIF(trim(COALESCE(p_source_identity, '')), '') IS NOT NULL THEN
        RETURN 'src:' || trim(p_source_identity);
    END IF;

    normalized := normalize_recmem_text(p_user_text)
        || chr(30)
        || normalize_recmem_text(p_assistant_text)
        || chr(30)
        || COALESCE(p_session_id::text, '');

    RETURN 'hash:' || encode(digest(normalized, 'sha256'), 'hex');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION recmem_ingest_turn(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_session_id UUID DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_turn_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    p_importance FLOAT DEFAULT 0.3,
    p_source_attribution JSONB DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    unit_content TEXT;
    idem TEXT;
    new_id UUID;
    existing_id UUID;
BEGIN
    IF COALESCE(p_user_text, '') = '' AND COALESCE(p_assistant_text, '') = '' THEN
        RETURN jsonb_build_object('status', 'empty');
    END IF;

    unit_content := format_recmem_turn(p_user_text, p_assistant_text);
    idem := compute_recmem_idempotency_key(p_user_text, p_assistant_text, p_session_id, p_source_identity);

    INSERT INTO subconscious_units (
        session_id,
        source_identity,
        turn_at,
        content,
        user_text,
        assistant_text,
        importance,
        source_attribution,
        metadata,
        idempotency_key
    )
    VALUES (
        p_session_id,
        NULLIF(trim(COALESCE(p_source_identity, '')), ''),
        COALESCE(p_turn_at, CURRENT_TIMESTAMP),
        unit_content,
        COALESCE(p_user_text, ''),
        COALESCE(p_assistant_text, ''),
        LEAST(1.0, GREATEST(0.0, COALESCE(p_importance, 0.3))),
        COALESCE(p_source_attribution, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        idem
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO new_id;

    IF new_id IS NOT NULL THEN
        RETURN jsonb_build_object('unit_id', new_id, 'status', 'stored');
    END IF;

    SELECT id INTO existing_id
    FROM subconscious_units
    WHERE idempotency_key = idem;

    RETURN jsonb_build_object('unit_id', existing_id, 'status', 'duplicate');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claim_recmem_unembedded_batch(
    p_limit INT DEFAULT 32,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('memory.recmem_embed_claim_timeout_s'), 120);
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM subconscious_units
        WHERE status = 'active'
          AND (
              embedding_status = 'pending'
              OR (
                  embedding_status = 'in_progress'
                  AND embedding_claimed_at < CURRENT_TIMESTAMP - (timeout_s * INTERVAL '1 second')
              )
          )
        ORDER BY created_at
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 32), 1)
    ),
    claimed AS (
        UPDATE subconscious_units u
        SET embedding_status = 'in_progress',
            embedding_claimed_at = CURRENT_TIMESTAMP,
            embedding_attempts = embedding_attempts + 1,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate c
        WHERE u.id = c.id
        RETURNING u.id, u.content, u.embedding_attempts
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'unit_id', id,
        'content', content,
        'attempts', embedding_attempts
    )), '[]'::jsonb)
    INTO payload
    FROM claimed;

    RETURN payload;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_recmem_embeddings(
    p_payload JSONB
) RETURNS JSONB AS $$
DECLARE
    item JSONB;
    updated_count INT := 0;
    row_count INT := 0;
    emb_arr FLOAT4[];
BEGIN
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_payload, '[]'::jsonb))
    LOOP
        SELECT array_agg(value::float4 ORDER BY ord)
        INTO emb_arr
        FROM jsonb_array_elements_text(item->'embedding') WITH ORDINALITY AS e(value, ord);

        IF emb_arr IS NULL OR array_length(emb_arr, 1) IS NULL THEN
            CONTINUE;
        END IF;

        UPDATE subconscious_units
        SET embedding = emb_arr::vector,
            embedded_at = CURRENT_TIMESTAMP,
            embedding_status = 'embedded',
            embedding_claimed_at = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = (item->>'unit_id')::uuid
          AND embedding_status = 'in_progress';

        GET DIAGNOSTICS row_count = ROW_COUNT;
        updated_count := updated_count + row_count;
    END LOOP;

    RETURN jsonb_build_object('updated', updated_count);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_recmem_embedding(
    p_unit_id UUID,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    max_attempts INT := COALESCE(get_config_int('memory.recmem_embed_max_attempts'), 3);
    final_status TEXT;
BEGIN
    UPDATE subconscious_units
    SET embedding_status = CASE WHEN embedding_attempts >= max_attempts THEN 'failed' ELSE 'pending' END,
        embedding_claimed_at = NULL,
        metadata = COALESCE(metadata, '{}'::jsonb)
            || jsonb_build_object(
                'recmem',
                COALESCE(metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object(
                        'embedding_error',
                        jsonb_build_object('error', p_error, 'at', CURRENT_TIMESTAMP)
                    )
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_unit_id
    RETURNING embedding_status INTO final_status;

    RETURN jsonb_build_object('unit_id', p_unit_id, 'embedding_status', final_status);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claim_recmem_unrouted_batch(
    p_limit INT DEFAULT 32,
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('memory.recmem_route_claim_timeout_s'), 60);
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM subconscious_units
        WHERE status = 'active'
          AND embedding_status = 'embedded'
          AND (
              route_status = 'unrouted'
              OR (
                  route_status = 'routing'
                  AND last_routed_at < CURRENT_TIMESTAMP - (timeout_s * INTERVAL '1 second')
              )
          )
        ORDER BY last_routed_at NULLS FIRST, created_at
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 32), 1)
    ),
    claimed AS (
        UPDATE subconscious_units u
        SET route_status = 'routing',
            route_attempts = route_attempts + 1,
            last_routed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate c
        WHERE u.id = c.id
        RETURNING u.id, u.content, u.route_attempts
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'unit_id', id,
        'content', content,
        'attempts', route_attempts
    )), '[]'::jsonb)
    INTO payload
    FROM claimed;

    RETURN payload;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _recmem_pending_queue_depth()
RETURNS INT AS $$
    SELECT COUNT(*)::int
    FROM recmem_consolidation_tasks
    WHERE status IN ('pending','in_progress');
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION recmem_route_unit(
    p_unit_id UUID
) RETURNS JSONB AS $$
DECLARE
    unit_row subconscious_units%ROWTYPE;
    theta_sim FLOAT := COALESCE(get_config_float('memory.recmem_theta_sim'), 0.7);
    theta_merge FLOAT := COALESCE(get_config_float('memory.recmem_theta_sim_merge'), 0.78);
    theta_count INT := COALESCE(get_config_int('memory.recmem_theta_count'), 5);
    top_k INT := COALESCE(get_config_int('memory.recmem_top_k'), 20);
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
    nearest_memory_id UUID;
    nearest_similarity FLOAT;
    source_ids UUID[];
    recurrence_count INT;
    max_neighbor_similarity FLOAT;
    task_id UUID;
    overlaps_open_create BOOLEAN;
BEGIN
    SELECT * INTO unit_row
    FROM subconscious_units
    WHERE id = p_unit_id
      AND status = 'active'
      AND embedding_status = 'embedded';

    IF NOT FOUND THEN
        RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'skipped', 'reason', 'not_embedded_or_inactive');
    END IF;

    SELECT m.id, 1 - (m.embedding <=> unit_row.embedding)
    INTO nearest_memory_id, nearest_similarity
    FROM memories m
    WHERE m.status = 'active'
      AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
      AND m.type = 'episodic'
      AND m.embedding IS NOT NULL
    ORDER BY m.embedding <=> unit_row.embedding
    LIMIT 1;

    IF nearest_memory_id IS NOT NULL
       AND nearest_similarity >= theta_merge
       AND COALESCE(unit_row.route_result->>'merge_rejected_target_memory_id', '') <> nearest_memory_id::text THEN
        IF _recmem_pending_queue_depth() >= queue_max THEN
            UPDATE subconscious_units
            SET route_status = 'raw_only',
                route_result = route_result || jsonb_build_object(
                    'decision', 'raw_only',
                    'reason', 'queue_full',
                    'nearest_memory_id', nearest_memory_id,
                    'similarity', nearest_similarity
                ),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = p_unit_id;
            RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'raw_only', 'reason', 'queue_full');
        END IF;

        SELECT id INTO task_id
        FROM recmem_consolidation_tasks
        WHERE task_type = 'episode_merge'
          AND status = 'pending'
          AND target_memory_id = nearest_memory_id
        ORDER BY created_at
        LIMIT 1
        FOR UPDATE;

        IF task_id IS NOT NULL THEN
            UPDATE recmem_consolidation_tasks
            SET source_unit_ids = (
                    SELECT array_agg(DISTINCT source_id)
                    FROM unnest(array_append(source_unit_ids, p_unit_id)) AS source_id
                ),
                task_payload = task_payload || jsonb_build_object('coalesced_at', CURRENT_TIMESTAMP),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = task_id;
        ELSE
            INSERT INTO recmem_consolidation_tasks (
                task_type,
                trigger_unit_id,
                target_memory_id,
                source_unit_ids,
                max_similarity,
                task_payload
            )
            VALUES (
                'episode_merge',
                p_unit_id,
                nearest_memory_id,
                ARRAY[p_unit_id],
                nearest_similarity,
                jsonb_build_object(
                    'unit_content', unit_row.content,
                    'target_memory_id', nearest_memory_id,
                    'similarity', nearest_similarity
                )
            )
            RETURNING id INTO task_id;
        END IF;

        UPDATE subconscious_units
        SET route_status = 'merge_queued',
            route_result = route_result || jsonb_build_object(
                'decision', 'merge_queued',
                'task_id', task_id,
                'target_memory_id', nearest_memory_id,
                'similarity', nearest_similarity
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_unit_id;

        RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'merge_queued', 'task_id', task_id);
    END IF;

    WITH neighbors AS (
        SELECT s.id, 1 - (s.embedding <=> unit_row.embedding) AS similarity
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
        ORDER BY s.embedding <=> unit_row.embedding
        LIMIT GREATEST(top_k, theta_count)
    ),
    recurrent AS (
        SELECT id, similarity
        FROM neighbors
        WHERE similarity >= theta_sim
    )
    SELECT array_agg(id ORDER BY id), COUNT(*)::int, MAX(similarity)
    INTO source_ids, recurrence_count, max_neighbor_similarity
    FROM recurrent;

    source_ids := COALESCE(source_ids, ARRAY[p_unit_id]);
    IF NOT p_unit_id = ANY(source_ids) THEN
        source_ids := source_ids || p_unit_id;
        recurrence_count := COALESCE(recurrence_count, 0) + 1;
    END IF;

    IF COALESCE(recurrence_count, 0) < theta_count THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'decision', 'raw_only',
                'recurrence_count', COALESCE(recurrence_count, 0),
                'max_similarity', max_neighbor_similarity
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_unit_id;
        RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'raw_only', 'recurrence_count', COALESCE(recurrence_count, 0));
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM recmem_consolidation_tasks t
        WHERE t.task_type = 'episode_create'
          AND t.status IN ('pending','in_progress')
          AND t.source_unit_ids && source_ids
    ) INTO overlaps_open_create;

    IF overlaps_open_create THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'decision', 'raw_only',
                'reason', 'open_create_overlap',
                'recurrence_count', recurrence_count
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_unit_id;
        RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'raw_only', 'reason', 'open_create_overlap');
    END IF;

    IF _recmem_pending_queue_depth() >= queue_max THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'decision', 'raw_only',
                'reason', 'queue_full_create_paused',
                'recurrence_count', recurrence_count
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_unit_id;
        RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'raw_only', 'reason', 'queue_full_create_paused');
    END IF;

    INSERT INTO recmem_consolidation_tasks (
        task_type,
        trigger_unit_id,
        source_unit_ids,
        recurrence_count,
        max_similarity,
        task_payload
    )
    VALUES (
        'episode_create',
        p_unit_id,
        source_ids,
        recurrence_count,
        max_neighbor_similarity,
        jsonb_build_object('source_unit_ids', source_ids, 'recurrence_count', recurrence_count)
    )
    RETURNING id INTO task_id;

    UPDATE subconscious_units
    SET route_status = 'create_queued',
        route_result = route_result || jsonb_build_object(
            'decision', 'create_queued',
            'task_id', task_id,
            'recurrence_count', recurrence_count,
            'max_similarity', max_neighbor_similarity
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(source_ids)
      AND route_status IN ('routing','raw_only','unrouted');

    RETURN jsonb_build_object('unit_id', p_unit_id, 'status', 'create_queued', 'task_id', task_id, 'recurrence_count', recurrence_count);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_recmem_routing(
    p_unit_id UUID,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    max_attempts INT := COALESCE(get_config_int('memory.recmem_route_max_attempts'), 3);
    final_status TEXT;
BEGIN
    UPDATE subconscious_units
    SET route_status = CASE WHEN route_attempts >= max_attempts THEN 'route_failed' ELSE 'unrouted' END,
        route_result = jsonb_build_object('error', p_error, 'at', CURRENT_TIMESTAMP),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_unit_id
    RETURNING route_status INTO final_status;

    RETURN jsonb_build_object('unit_id', p_unit_id, 'route_status', final_status);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claim_recmem_consolidation_task(
    p_claim_timeout_s INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    timeout_s INT := COALESCE(p_claim_timeout_s, get_config_int('memory.recmem_task_claim_timeout_s'), 600);
    task JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM recmem_consolidation_tasks
        WHERE (status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP)
           OR (status = 'in_progress' AND started_at < CURRENT_TIMESTAMP - (timeout_s * INTERVAL '1 second'))
        ORDER BY next_attempt_at, created_at
        FOR UPDATE SKIP LOCKED
        LIMIT 1
    ),
    claimed AS (
        UPDATE recmem_consolidation_tasks t
        SET status = 'in_progress',
            started_at = CURRENT_TIMESTAMP,
            attempts = attempts + 1,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate c
        WHERE t.id = c.id
        RETURNING t.*
    )
    SELECT to_jsonb(claimed)
    INTO task
    FROM claimed;

    RETURN task;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fail_recmem_consolidation_task(
    p_task_id UUID,
    p_error TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    max_attempts INT := COALESCE(get_config_int('memory.recmem_task_max_attempts'), 3);
    backoff_base INT := COALESCE(get_config_int('memory.recmem_task_backoff_base_s'), 30);
    task recmem_consolidation_tasks%ROWTYPE;
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    IF task.attempts >= max_attempts THEN
        UPDATE recmem_consolidation_tasks
        SET status = 'failed',
            error = p_error,
            completed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'failed');
    END IF;

    UPDATE recmem_consolidation_tasks
    SET status = 'pending',
        started_at = NULL,
        next_attempt_at = CURRENT_TIMESTAMP + (backoff_base * power(2, GREATEST(attempts - 1, 0))) * INTERVAL '1 second',
        error = p_error,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'pending');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION link_memory_to_source_unit(
    p_memory_id UUID,
    p_unit_id UUID,
    p_role TEXT DEFAULT 'source'
) RETURNS BOOLEAN AS $$
BEGIN
    INSERT INTO memory_source_units (memory_id, subconscious_unit_id, role)
    VALUES (p_memory_id, p_unit_id, COALESCE(p_role, 'source'))
    ON CONFLICT (memory_id, subconscious_unit_id) DO UPDATE
    SET role = EXCLUDED.role;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_recmem_episode_merge(
    p_task_id UUID,
    p_merged_content TEXT DEFAULT NULL,
    p_should_merge BOOLEAN DEFAULT TRUE
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    old_content TEXT;
    new_embedding vector;
    unit_id UUID;
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
    v_primary_sender TEXT;  -- PR-B: identity to backfill onto target memory if NULL
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    IF NOT COALESCE(p_should_merge, TRUE) THEN
        UPDATE subconscious_units
        SET route_status = 'routing',
            route_result = route_result || jsonb_build_object(
                'merge_rejected', true,
                'merge_rejected_target_memory_id', task.target_memory_id,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(task.source_unit_ids);

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM recmem_route_unit(unit_id);
        END LOOP;

        UPDATE recmem_consolidation_tasks
        SET status = 'completed',
            completed_at = CURRENT_TIMESTAMP,
            result = jsonb_build_object('merged', false),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;

        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'merged', false);
    END IF;

    SELECT content INTO old_content
    FROM memories
    WHERE id = task.target_memory_id;

    IF task.target_memory_id IS NULL OR old_content IS NULL THEN
        PERFORM fail_recmem_consolidation_task(p_task_id, 'target memory missing');
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'failed', 'reason', 'target_missing');
    END IF;

    new_embedding := (get_embedding(ARRAY[COALESCE(NULLIF(p_merged_content, ''), old_content)]))[1];

    -- PR-B: compute primary sender across the NEW units being merged in. Only
    -- backfill on the target memory when its sender_id is NULL (conservative;
    -- never overwrites an established identity). Multi-sender merge results in
    -- the most-common sender from the incoming batch.
    SELECT mode() WITHIN GROUP (ORDER BY source_identity)
    INTO v_primary_sender
    FROM subconscious_units
    WHERE id = ANY(task.source_unit_ids) AND source_identity IS NOT NULL;

    UPDATE memories
    SET content = COALESCE(NULLIF(p_merged_content, ''), old_content),
        embedding = new_embedding,
        sender_id = COALESCE(sender_id, v_primary_sender),
        metadata = COALESCE(metadata, '{}'::jsonb)
            || jsonb_build_object(
                'recmem',
                COALESCE(metadata->'recmem', '{}'::jsonb)
                    || jsonb_build_object(
                        'merge_history',
                        COALESCE(metadata#>'{recmem,merge_history}', '[]'::jsonb)
                            || jsonb_build_array(jsonb_build_object('content', old_content, 'merged_at', CURRENT_TIMESTAMP))
                    )
            ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = task.target_memory_id;

    FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
        PERFORM link_memory_to_source_unit(task.target_memory_id, unit_id, 'merge_addition');
    END LOOP;

    UPDATE subconscious_units
    SET consolidated_at = CURRENT_TIMESTAMP,
        route_status = 'merged',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(task.source_unit_ids);

    IF _recmem_pending_queue_depth() >= queue_max THEN
        INSERT INTO recmem_consolidation_tasks (
            task_type,
            trigger_unit_id,
            target_memory_id,
            source_unit_ids,
            status,
            completed_at,
            dropped_reason,
            task_payload
        )
        VALUES (
            'semantic_refine',
            task.trigger_unit_id,
            task.target_memory_id,
            task.source_unit_ids,
            'dropped',
            CURRENT_TIMESTAMP,
            'queue_full_semantic_refine_dropped',
            jsonb_build_object('reason', 'episode_merge')
        );
    ELSE
        INSERT INTO recmem_consolidation_tasks (task_type, trigger_unit_id, target_memory_id, source_unit_ids, task_payload)
        VALUES ('semantic_refine', task.trigger_unit_id, task.target_memory_id, task.source_unit_ids, jsonb_build_object('reason', 'episode_merge'));
    END IF;

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('merged', true, 'target_memory_id', task.target_memory_id),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'merged', true, 'target_memory_id', task.target_memory_id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_recmem_episode_create(
    p_task_id UUID,
    p_episodes JSONB
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    item JSONB;
    episode_content TEXT;
    new_embedding vector;
    memory_id UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
    unit_id UUID;
    source_attr JSONB;
    queue_max INT := COALESCE(get_config_int('memory.recmem_queue_max'), 5000);
    v_primary_sender TEXT;  -- PR-B: identity stamped onto each created episode
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    source_attr := jsonb_build_object(
        'kind', 'recmem',
        'ref', task.id::text,
        'label', 'RecMem episodic consolidation',
        'observed_at', CURRENT_TIMESTAMP,
        'trust', 0.9
    );

    -- PR-B: derived episodes inherit the most-common sender_id across their
    -- raw source units. Mixed-sender consolidations fall back to NULL (treated
    -- as global by sender-scoped recall).
    SELECT mode() WITHIN GROUP (ORDER BY source_identity)
    INTO v_primary_sender
    FROM subconscious_units
    WHERE id = ANY(task.source_unit_ids) AND source_identity IS NOT NULL;

    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_episodes, '[]'::jsonb))
    LOOP
        episode_content := COALESCE(item->>'content', item->>'episode', item#>>'{}');
        IF NULLIF(trim(COALESCE(episode_content, '')), '') IS NULL THEN
            CONTINUE;
        END IF;

        new_embedding := (get_embedding(ARRAY[episode_content]))[1];
        memory_id := create_memory_with_embedding(
            'episodic',
            episode_content,
            new_embedding,
            COALESCE(NULLIF(item->>'importance', '')::float, 0.6),
            source_attr,
            0.9,
            jsonb_build_object('recmem', jsonb_build_object('task_id', task.id, 'source_unit_ids', task.source_unit_ids)),
            v_primary_sender
        );
        created_ids := created_ids || memory_id;

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM link_memory_to_source_unit(memory_id, unit_id, 'source');
        END LOOP;

        IF _recmem_pending_queue_depth() >= queue_max THEN
            INSERT INTO recmem_consolidation_tasks (
                task_type,
                trigger_unit_id,
                target_memory_id,
                source_unit_ids,
                status,
                completed_at,
                dropped_reason,
                task_payload
            )
            VALUES (
                'semantic_refine',
                task.trigger_unit_id,
                memory_id,
                task.source_unit_ids,
                'dropped',
                CURRENT_TIMESTAMP,
                'queue_full_semantic_refine_dropped',
                jsonb_build_object('reason', 'episode_create')
            );
        ELSE
            INSERT INTO recmem_consolidation_tasks (task_type, trigger_unit_id, target_memory_id, source_unit_ids, task_payload)
            VALUES ('semantic_refine', task.trigger_unit_id, memory_id, task.source_unit_ids, jsonb_build_object('reason', 'episode_create'));
        END IF;
    END LOOP;

    IF cardinality(created_ids) = 0 THEN
        UPDATE subconscious_units
        SET route_status = 'raw_only',
            route_result = route_result || jsonb_build_object(
                'episode_create_empty', true,
                'task_id', p_task_id,
                'at', CURRENT_TIMESTAMP
            ),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY(task.source_unit_ids);

        UPDATE recmem_consolidation_tasks
        SET status = 'completed',
            completed_at = CURRENT_TIMESTAMP,
            result = jsonb_build_object('memory_ids', created_ids, 'empty', true),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_task_id;

        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids, 'empty', true);
    END IF;

    UPDATE subconscious_units
    SET consolidated_at = CURRENT_TIMESTAMP,
        route_status = 'episode_created',
        updated_at = CURRENT_TIMESTAMP
    WHERE id = ANY(task.source_unit_ids);

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('memory_ids', created_ids),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION apply_recmem_semantic_facts(
    p_task_id UUID,
    p_facts JSONB
) RETURNS JSONB AS $$
DECLARE
    task recmem_consolidation_tasks%ROWTYPE;
    item JSONB;
    fact_content TEXT;
    fact_embedding vector;
    duplicate_id UUID;
    memory_id UUID;
    created_ids UUID[] := ARRAY[]::UUID[];
    unit_id UUID;
    v_primary_sender TEXT;  -- PR-B: identity stamped onto each created fact
BEGIN
    SELECT * INTO task
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('task_id', p_task_id, 'status', 'missing');
    END IF;

    -- PR-B: see apply_recmem_episode_create for rationale.
    SELECT mode() WITHIN GROUP (ORDER BY source_identity)
    INTO v_primary_sender
    FROM subconscious_units
    WHERE id = ANY(task.source_unit_ids) AND source_identity IS NOT NULL;

    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(p_facts, '[]'::jsonb))
    LOOP
        fact_content := COALESCE(item->>'content', item->>'fact', item#>>'{}');
        IF NULLIF(trim(COALESCE(fact_content, '')), '') IS NULL THEN
            CONTINUE;
        END IF;

        fact_embedding := (get_embedding(ARRAY[fact_content]))[1];

        SELECT m.id INTO duplicate_id
        FROM memories m
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'semantic'
          AND 1 - (m.embedding <=> fact_embedding) >= 0.92
        ORDER BY m.embedding <=> fact_embedding
        LIMIT 1;

        IF duplicate_id IS NOT NULL THEN
            CONTINUE;
        END IF;

        memory_id := create_memory_with_embedding(
            'semantic',
            fact_content,
            fact_embedding,
            COALESCE(NULLIF(item->>'importance', '')::float, 0.55),
            jsonb_build_object(
                'kind', 'recmem',
                'ref', task.id::text,
                'label', 'RecMem semantic refinement',
                'observed_at', CURRENT_TIMESTAMP,
                'trust', 0.85
            ),
            0.85,
            jsonb_build_object('recmem', jsonb_build_object('task_id', task.id, 'episode_id', task.target_memory_id, 'source_unit_ids', task.source_unit_ids)),
            v_primary_sender
        );
        created_ids := created_ids || memory_id;

        FOREACH unit_id IN ARRAY task.source_unit_ids LOOP
            PERFORM link_memory_to_source_unit(memory_id, unit_id, 'source');
        END LOOP;

        IF task.target_memory_id IS NOT NULL THEN
            PERFORM create_memory_relationship(memory_id, task.target_memory_id, 'DERIVED_FROM', '{}'::jsonb);
        END IF;
    END LOOP;

    UPDATE recmem_consolidation_tasks
    SET status = 'completed',
        completed_at = CURRENT_TIMESTAMP,
        result = jsonb_build_object('memory_ids', created_ids),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_task_id;

    RETURN jsonb_build_object('task_id', p_task_id, 'status', 'completed', 'memory_ids', created_ids);
END;
$$ LANGUAGE plpgsql;

-- Adding p_current_sender + source_identity/confidentiality columns is a signature
-- change; DROP first so the CREATE doesn't fail with "cannot change return type".
DROP FUNCTION IF EXISTS recmem_recall_context(TEXT, INT, INT, INT, UUID);

CREATE OR REPLACE FUNCTION recmem_recall_context(
    p_query TEXT,
    p_k_sub INT DEFAULT 10,
    p_k_epi INT DEFAULT 5,
    p_k_sem INT DEFAULT 10,
    p_session_id UUID DEFAULT NULL,
    p_current_sender TEXT DEFAULT NULL
) RETURNS TABLE (
    tier TEXT,
    item_id UUID,
    content TEXT,
    memory_type TEXT,
    score FLOAT,
    source_unit_ids UUID[],
    source_attribution JSONB,
    created_at TIMESTAMPTZ,
    trust_level FLOAT,
    source_identity TEXT,
    confidentiality TEXT
) AS $$
DECLARE
    query_embedding vector;
BEGIN
    query_embedding := (get_embedding(ARRAY[ensure_embedding_prefix(p_query, 'search_query')]))[1];

    RETURN QUERY
    WITH raw_hits AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            ((1 - (s.embedding <=> query_embedding))
              + CASE WHEN p_current_sender IS NOT NULL
                          AND s.source_identity = p_current_sender
                     THEN 0.1 ELSE 0 END)::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            s.source_identity AS source_identity
        FROM subconscious_units s
        WHERE s.status = 'active'
          AND s.embedding_status = 'embedded'
          AND s.embedding IS NOT NULL
        ORDER BY s.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sub, 10), 0)
    ),
    recent_unembedded AS (
        SELECT
            'subconscious'::text AS tier,
            s.id AS item_id,
            s.content,
            NULL::text AS memory_type,
            (0.2
              + CASE WHEN p_current_sender IS NOT NULL
                          AND s.source_identity = p_current_sender
                     THEN 0.1 ELSE 0 END)::float AS score,
            ARRAY[s.id]::uuid[] AS source_unit_ids,
            s.source_attribution,
            s.created_at,
            s.trust_level,
            s.source_identity AS source_identity
        FROM subconscious_units s
        WHERE p_session_id IS NOT NULL
          AND s.session_id = p_session_id
          AND s.status = 'active'
          AND s.embedding_status <> 'embedded'
        ORDER BY s.created_at DESC
        LIMIT 3
    ),
    epi_hits AS (
        SELECT
            'episodic'::text AS tier,
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            ((1 - (m.embedding <=> query_embedding))
              + CASE WHEN p_current_sender IS NOT NULL
                          AND COALESCE(m.sender_id,
                                       mode() WITHIN GROUP (ORDER BY su.source_identity))
                              = p_current_sender
                     THEN 0.1 ELSE 0 END)::float AS score,
            COALESCE(array_agg(msu.subconscious_unit_id) FILTER (WHERE msu.subconscious_unit_id IS NOT NULL), '{}'::uuid[]) AS source_unit_ids,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            -- Prefer the derived memory's own sender_id (set by PR-B at apply time);
            -- fall back to most common source_identity across linked raw units for
            -- memories created before PR-B started propagating.
            COALESCE(m.sender_id,
                     mode() WITHIN GROUP (ORDER BY su.source_identity)) AS source_identity
        FROM memories m
        LEFT JOIN memory_source_units msu ON msu.memory_id = m.id
        LEFT JOIN subconscious_units su
               ON su.id = msu.subconscious_unit_id
              AND su.source_identity IS NOT NULL
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'episodic'
        GROUP BY m.id
        ORDER BY m.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_epi, 5), 0)
    ),
    sem_hits AS (
        SELECT
            'semantic'::text AS tier,
            m.id AS item_id,
            m.content,
            m.type::text AS memory_type,
            ((1 - (m.embedding <=> query_embedding))
              + CASE WHEN p_current_sender IS NOT NULL
                          AND COALESCE(m.sender_id,
                                       mode() WITHIN GROUP (ORDER BY su.source_identity))
                              = p_current_sender
                     THEN 0.1 ELSE 0 END)::float AS score,
            COALESCE(array_agg(msu.subconscious_unit_id) FILTER (WHERE msu.subconscious_unit_id IS NOT NULL), '{}'::uuid[]) AS source_unit_ids,
            m.source_attribution,
            m.created_at,
            m.trust_level,
            COALESCE(m.sender_id,
                     mode() WITHIN GROUP (ORDER BY su.source_identity)) AS source_identity
        FROM memories m
        LEFT JOIN memory_source_units msu ON msu.memory_id = m.id
        LEFT JOIN subconscious_units su
               ON su.id = msu.subconscious_unit_id
              AND su.source_identity IS NOT NULL
        WHERE m.status = 'active'
          AND (m.valid_until IS NULL OR m.valid_until > CURRENT_TIMESTAMP)
          AND m.type = 'semantic'
        GROUP BY m.id
        ORDER BY m.embedding <=> query_embedding
        LIMIT GREATEST(COALESCE(p_k_sem, 10), 0)
    ),
    all_hits AS (
        SELECT * FROM raw_hits
        UNION ALL
        SELECT * FROM recent_unembedded
        UNION ALL
        SELECT * FROM epi_hits
        UNION ALL
        SELECT * FROM sem_hits
    )
    SELECT
        h.tier,
        h.item_id,
        h.content,
        h.memory_type,
        h.score,
        h.source_unit_ids,
        h.source_attribution,
        h.created_at,
        h.trust_level,
        h.source_identity,
        CASE
            WHEN p_current_sender IS NULL THEN NULL
            WHEN h.source_identity IS NULL THEN NULL
            WHEN h.source_identity = p_current_sender THEN 'own'
            ELSE 'cross_partner'
        END::text AS confidentiality
    FROM all_hits h
    ORDER BY h.tier, h.score DESC, h.created_at DESC;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recmem_periodic_sweep(
    p_limit INT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    sweep_limit INT := COALESCE(p_limit, get_config_int('memory.recmem_sweep_batch_size'), 100);
    min_age_days INT := COALESCE(get_config_int('memory.recmem_sweep_min_rerouting_age_days'), 7);
    unit_id UUID;
    processed INT := 0;
BEGIN
    FOR unit_id IN
        SELECT id
        FROM subconscious_units
        WHERE status = 'active'
          AND embedding_status = 'embedded'
          AND route_status = 'raw_only'
          AND consolidated_at IS NULL
          AND (last_routed_at IS NULL OR last_routed_at < CURRENT_TIMESTAMP - (min_age_days * INTERVAL '1 day'))
        ORDER BY created_at
        LIMIT sweep_limit
    LOOP
        UPDATE subconscious_units
        SET route_status = 'routing',
            last_routed_at = CURRENT_TIMESTAMP,
            route_attempts = route_attempts + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = unit_id;
        PERFORM recmem_route_unit(unit_id);
        processed := processed + 1;
    END LOOP;

    RETURN jsonb_build_object('processed', processed);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION should_run_recmem_sweep()
RETURNS BOOLEAN AS $$
DECLARE
    state_doc JSONB := COALESCE(get_state('recmem_state'), '{}'::jsonb);
    last_run TIMESTAMPTZ := NULLIF(state_doc->>'last_sweep_at', '')::timestamptz;
    interval_seconds FLOAT := COALESCE(get_config_float('memory.recmem_sweep_interval_seconds'), 86400);
BEGIN
    IF COALESCE(get_config_bool('memory.recmem_enabled'), FALSE) IS FALSE THEN
        RETURN FALSE;
    END IF;

    IF last_run IS NULL THEN
        RETURN TRUE;
    END IF;

    RETURN CURRENT_TIMESTAMP >= last_run + (interval_seconds || ' seconds')::interval;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION mark_recmem_sweep_run(
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB AS $$
DECLARE
    merged JSONB;
BEGIN
    merged := COALESCE(get_state('recmem_state'), '{}'::jsonb)
        || jsonb_build_object(
            'last_sweep_at', CURRENT_TIMESTAMP,
            'last_sweep_result', COALESCE(p_result, '{}'::jsonb)
        );

    PERFORM set_state('recmem_state', merged);
    RETURN merged;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION recmem_unhealthy_items()
RETURNS TABLE (
    kind TEXT,
    item_id UUID,
    item_status TEXT,
    attempts INT,
    last_seen TIMESTAMPTZ,
    error TEXT,
    extra JSONB
) AS $$
    SELECT
        'embedding'::text,
        id,
        embedding_status,
        embedding_attempts,
        COALESCE(embedding_claimed_at, updated_at, created_at),
        metadata#>>'{recmem,embedding_error,error}',
        metadata
    FROM subconscious_units
    WHERE embedding_status = 'failed'
    UNION ALL
    SELECT
        'routing'::text,
        id,
        route_status,
        route_attempts,
        COALESCE(last_routed_at, updated_at, created_at),
        route_result->>'error',
        route_result
    FROM subconscious_units
    WHERE route_status = 'route_failed'
    UNION ALL
    SELECT
        'task'::text,
        id,
        status,
        attempts,
        COALESCE(completed_at, started_at, updated_at, created_at),
        error,
        task_payload
    FROM recmem_consolidation_tasks
    WHERE status = 'failed'
    UNION ALL
    SELECT
        'task'::text,
        id,
        status,
        attempts,
        COALESCE(completed_at, started_at, updated_at, created_at),
        dropped_reason,
        task_payload
    FROM recmem_consolidation_tasks
    WHERE status = 'dropped';
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION recmem_redact_unit(
    p_unit_id UUID,
    p_reason TEXT DEFAULT NULL,
    p_cascade_invalidate BOOLEAN DEFAULT TRUE
) RETURNS JSONB AS $$
DECLARE
    invalidated_ids UUID[] := ARRAY[]::UUID[];
BEGIN
    UPDATE subconscious_units
    SET status = 'redacted',
        metadata = jsonb_set(
            COALESCE(metadata, '{}'::jsonb),
            '{redaction}',
            jsonb_build_object('reason', p_reason, 'at', CURRENT_TIMESTAMP),
            true
        ),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_unit_id;

    IF COALESCE(p_cascade_invalidate, TRUE) THEN
        WITH linked AS (
            SELECT DISTINCT memory_id
            FROM memory_source_units
            WHERE subconscious_unit_id = p_unit_id
        ),
        updated AS (
            UPDATE memories m
            SET valid_until = CURRENT_TIMESTAMP,
                metadata = COALESCE(m.metadata, '{}'::jsonb)
                    || jsonb_build_object(
                        'recmem',
                        COALESCE(m.metadata->'recmem', '{}'::jsonb)
                            || jsonb_build_object(
                                'invalidation',
                                jsonb_build_object(
                                    'reason', 'source_redacted',
                                    'source_unit_id', p_unit_id,
                                    'detail', p_reason,
                                    'at', CURRENT_TIMESTAMP
                                )
                            )
                    ),
                updated_at = CURRENT_TIMESTAMP
            FROM linked l
            WHERE m.id = l.memory_id
            RETURNING m.id
        )
        SELECT COALESCE(array_agg(id), '{}'::uuid[])
        INTO invalidated_ids
        FROM updated;
    END IF;

    RETURN jsonb_build_object('redacted_unit_id', p_unit_id, 'invalidated_memory_ids', invalidated_ids);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_recmem_rollout_event(
    p_event_type TEXT,
    p_session_id UUID DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_raw_unit_id UUID DEFAULT NULL,
    p_raw_status TEXT DEFAULT NULL,
    p_direct_promoted BOOLEAN DEFAULT FALSE,
    p_eager_written BOOLEAN DEFAULT FALSE,
    p_eager_memory_id UUID DEFAULT NULL,
    p_duration_ms FLOAT DEFAULT NULL,
    p_error TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    new_id UUID;
BEGIN
    INSERT INTO recmem_rollout_events (
        event_type,
        session_id,
        source_identity,
        raw_unit_id,
        raw_status,
        direct_promoted,
        eager_written,
        eager_memory_id,
        duration_ms,
        error,
        metadata
    )
    VALUES (
        COALESCE(NULLIF(trim(p_event_type), ''), 'unknown'),
        p_session_id,
        NULLIF(trim(COALESCE(p_source_identity, '')), ''),
        p_raw_unit_id,
        p_raw_status,
        COALESCE(p_direct_promoted, FALSE),
        COALESCE(p_eager_written, FALSE),
        p_eager_memory_id,
        p_duration_ms,
        p_error,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION record_recmem_dual_write_comparison(
    p_query_text TEXT,
    p_session_id UUID DEFAULT NULL,
    p_eager_memory_ids UUID[] DEFAULT '{}',
    p_recmem_item_ids UUID[] DEFAULT '{}',
    p_duration_ms FLOAT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS UUID AS $$
DECLARE
    new_id UUID;
    eager_ids UUID[] := COALESCE(p_eager_memory_ids, '{}'::uuid[]);
    recmem_ids UUID[] := COALESCE(p_recmem_item_ids, '{}'::uuid[]);
    overlap INT;
BEGIN
    SELECT COUNT(DISTINCT eager_id)::int
    INTO overlap
    FROM unnest(eager_ids) AS eager_id
    WHERE eager_id = ANY(recmem_ids);

    INSERT INTO recmem_retrieval_comparisons (
        query_hash,
        query_text,
        session_id,
        eager_memory_ids,
        recmem_item_ids,
        eager_count,
        recmem_count,
        overlap_count,
        duration_ms,
        metadata
    )
    VALUES (
        encode(digest(COALESCE(p_query_text, ''), 'sha256'), 'hex'),
        p_query_text,
        p_session_id,
        eager_ids,
        recmem_ids,
        cardinality(eager_ids),
        cardinality(recmem_ids),
        COALESCE(overlap, 0),
        p_duration_ms,
        COALESCE(p_metadata, '{}'::jsonb)
    )
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_recmem_rollout_metrics(
    p_since TIMESTAMPTZ DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    since_time TIMESTAMPTZ := COALESCE(p_since, CURRENT_TIMESTAMP - INTERVAL '7 days');
BEGIN
    RETURN jsonb_build_object(
        'period_start', since_time,
        'period_end', CURRENT_TIMESTAMP,
        'raw_units', (
            SELECT jsonb_build_object(
                'total', COUNT(*),
                'pending_embedding', COUNT(*) FILTER (WHERE embedding_status = 'pending'),
                'embedded', COUNT(*) FILTER (WHERE embedding_status = 'embedded'),
                'failed_embedding', COUNT(*) FILTER (WHERE embedding_status = 'failed'),
                'raw_only', COUNT(*) FILTER (WHERE route_status = 'raw_only'),
                'merge_queued', COUNT(*) FILTER (WHERE route_status = 'merge_queued'),
                'merged', COUNT(*) FILTER (WHERE route_status = 'merged'),
                'create_queued', COUNT(*) FILTER (WHERE route_status = 'create_queued'),
                'episode_created', COUNT(*) FILTER (WHERE route_status = 'episode_created'),
                'route_failed', COUNT(*) FILTER (WHERE route_status = 'route_failed')
            )
            FROM subconscious_units
            WHERE created_at >= since_time
        ),
        'tasks', (
            SELECT jsonb_build_object(
                'pending', COUNT(*) FILTER (WHERE status = 'pending'),
                'in_progress', COUNT(*) FILTER (WHERE status = 'in_progress'),
                'completed', COUNT(*) FILTER (WHERE status = 'completed'),
                'failed', COUNT(*) FILTER (WHERE status = 'failed'),
                'dropped', COUNT(*) FILTER (WHERE status = 'dropped')
            )
            FROM recmem_consolidation_tasks
            WHERE created_at >= since_time
        ),
        'rollout_events', (
            SELECT jsonb_build_object(
                'total', COUNT(*),
                'avg_duration_ms', AVG(duration_ms),
                'raw_stored', COUNT(*) FILTER (WHERE raw_status = 'stored'),
                'raw_duplicate', COUNT(*) FILTER (WHERE raw_status = 'duplicate'),
                'direct_promoted', COUNT(*) FILTER (WHERE direct_promoted),
                'eager_written', COUNT(*) FILTER (WHERE eager_written),
                'errors', COUNT(*) FILTER (WHERE error IS NOT NULL)
            )
            FROM recmem_rollout_events
            WHERE created_at >= since_time
        ),
        'dual_write', (
            SELECT jsonb_build_object(
                'comparisons', COUNT(*),
                'avg_duration_ms', AVG(duration_ms),
                'avg_eager_count', AVG(eager_count),
                'avg_recmem_count', AVG(recmem_count),
                'avg_overlap_count', AVG(overlap_count),
                'divergence_rate',
                    CASE WHEN COUNT(*) > 0
                         THEN COUNT(*) FILTER (WHERE eager_memory_ids <> recmem_item_ids)::float / COUNT(*)::float
                         ELSE 0 END
            )
            FROM recmem_retrieval_comparisons
            WHERE created_at >= since_time
        ),
        'unhealthy_count', (
            SELECT COUNT(*)
            FROM recmem_unhealthy_items()
        )
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_recmem_eval_run_summary(
    p_run_id UUID
) RETURNS JSONB AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'run_id', r.id,
            'status', r.status,
            'label', r.label,
            'eval_set_id', r.eval_set_id,
            'started_at', r.started_at,
            'completed_at', r.completed_at,
            'result_count', (
                SELECT COUNT(*)
                FROM recmem_eval_results
                WHERE run_id = r.id
            ),
            'avg_judge_score', (
                SELECT AVG(judge_score)
                FROM recmem_eval_results
                WHERE run_id = r.id
            ),
            'by_category', COALESCE((
                SELECT jsonb_object_agg(
                    s.category,
                    jsonb_build_object(
                        'count', s.count,
                        'avg_judge_score', s.avg_judge_score
                    )
                )
                FROM (
                    SELECT category, COUNT(*) AS count, AVG(judge_score) AS avg_judge_score
                    FROM recmem_eval_results
                    WHERE run_id = r.id
                    GROUP BY category
                ) s
            ), '{}'::jsonb)
        )
        FROM recmem_eval_runs r
        WHERE r.id = p_run_id
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_recmem_eval_quality_gate(
    p_run_id UUID,
    p_overall_max_regression FLOAT DEFAULT 0.015,
    p_category_max_regression FLOAT DEFAULT 0.05
) RETURNS JSONB AS $$
DECLARE
    overall_baseline FLOAT;
    overall_recmem FLOAT;
    overall_regression FLOAT;
    worst_category_regression FLOAT;
    total_items INT;
    judged_items INT;
    regression_items INT;
    gate_passed BOOLEAN;
    categories JSONB;
BEGIN
    SELECT
        COUNT(*)::int,
        COUNT(*) FILTER (WHERE metadata ? 'baseline_hit_rate' AND metadata ? 'recmem_hit_rate')::int,
        COUNT(*) FILTER (WHERE verdict = 'regression')::int,
        AVG(NULLIF(metadata->>'baseline_hit_rate', 'null')::float),
        AVG(NULLIF(metadata->>'recmem_hit_rate', 'null')::float)
    INTO total_items, judged_items, regression_items, overall_baseline, overall_recmem
    FROM recmem_eval_results
    WHERE run_id = p_run_id;

    overall_regression := GREATEST(COALESCE(overall_baseline, 0) - COALESCE(overall_recmem, 0), 0);

    WITH category_scores AS (
        SELECT
            category,
            COUNT(*) AS count,
            AVG(NULLIF(metadata->>'baseline_hit_rate', 'null')::float) AS baseline_hit_rate,
            AVG(NULLIF(metadata->>'recmem_hit_rate', 'null')::float) AS recmem_hit_rate
        FROM recmem_eval_results
        WHERE run_id = p_run_id
          AND metadata ? 'baseline_hit_rate'
          AND metadata ? 'recmem_hit_rate'
        GROUP BY category
    ),
    scored AS (
        SELECT
            category,
            count,
            baseline_hit_rate,
            recmem_hit_rate,
            GREATEST(COALESCE(baseline_hit_rate, 0) - COALESCE(recmem_hit_rate, 0), 0) AS regression
        FROM category_scores
    )
    SELECT
        COALESCE(MAX(regression), 0),
        COALESCE(
            jsonb_object_agg(
                category,
                jsonb_build_object(
                    'count', count,
                    'baseline_hit_rate', baseline_hit_rate,
                    'recmem_hit_rate', recmem_hit_rate,
                    'regression', regression,
                    'passed', regression <= COALESCE(p_category_max_regression, 0.05)
                )
            ),
            '{}'::jsonb
        )
    INTO worst_category_regression, categories
    FROM scored;

    gate_passed := COALESCE(judged_items, 0) > 0
        AND overall_regression <= COALESCE(p_overall_max_regression, 0.015)
        AND COALESCE(worst_category_regression, 0) <= COALESCE(p_category_max_regression, 0.05);

    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'passed', gate_passed,
        'total_items', COALESCE(total_items, 0),
        'judged_items', COALESCE(judged_items, 0),
        'regression_items', COALESCE(regression_items, 0),
        'overall_baseline_hit_rate', overall_baseline,
        'overall_recmem_hit_rate', overall_recmem,
        'overall_regression', overall_regression,
        'overall_max_regression', COALESCE(p_overall_max_regression, 0.015),
        'worst_category_regression', COALESCE(worst_category_regression, 0),
        'category_max_regression', COALESCE(p_category_max_regression, 0.05),
        'categories', COALESCE(categories, '{}'::jsonb)
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION get_recmem_phase5_readiness(
    p_run_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
    selected_run_id UUID;
    run_status TEXT;
    gate JSONB;
    unhealthy_count INT;
BEGIN
    IF p_run_id IS NULL THEN
        SELECT id INTO selected_run_id
        FROM recmem_eval_runs
        WHERE status = 'completed'
        ORDER BY completed_at DESC NULLS LAST, started_at DESC
        LIMIT 1;
    ELSE
        selected_run_id := p_run_id;
    END IF;

    IF selected_run_id IS NULL THEN
        RETURN jsonb_build_object(
            'ready', false,
            'reason', 'no_completed_eval_run'
        );
    END IF;

    SELECT status INTO run_status
    FROM recmem_eval_runs
    WHERE id = selected_run_id;

    IF run_status <> 'completed' THEN
        RETURN jsonb_build_object(
            'ready', false,
            'reason', 'eval_run_not_completed',
            'run_id', selected_run_id,
            'status', run_status
        );
    END IF;

    gate := get_recmem_eval_quality_gate(selected_run_id);
    SELECT COUNT(*)::int INTO unhealthy_count FROM recmem_unhealthy_items();

    RETURN jsonb_build_object(
        'ready',
            COALESCE((gate->>'passed')::boolean, false)
            AND COALESCE(unhealthy_count, 0) = 0,
        'run_id', selected_run_id,
        'quality_gate', gate,
        'unhealthy_count', COALESCE(unhealthy_count, 0),
        'hydrate_enabled', COALESCE(get_config_bool('memory.recmem_hydrate_enabled'), false),
        'recommendation',
            CASE
                WHEN COALESCE((gate->>'passed')::boolean, false) IS FALSE THEN 'keep_recmem_hydrate_disabled_quality_gate_failed'
                WHEN COALESCE(unhealthy_count, 0) > 0 THEN 'keep_recmem_hydrate_disabled_unhealthy_items'
                ELSE 'eligible_to_enable_memory.recmem_hydrate_enabled'
            END
    );
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION has_pending_recmem_consolidation()
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1
        FROM recmem_consolidation_tasks
        WHERE status = 'pending'
          AND next_attempt_at <= CURRENT_TIMESTAMP
    );
$$ LANGUAGE sql STABLE;
-- ===== END INLINE: db/31_functions_recmem.sql =====


-- ===== BEGIN INLINE: db/32_functions_db_brain.sql =====
-- Hexis DB-brain migration guardrails.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION assert_db_brain_ready(
    p_strict BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    required_extensions TEXT[] := ARRAY[
        'vector',
        'age',
        'btree_gist',
        'pg_trgm',
        'http',
        'pgcrypto'
    ];
    planned_extensions TEXT[] := ARRAY[
        'pg_cron',
        'pg_jsonschema'
    ];
    installed_extensions TEXT[];
    available_extensions TEXT[];
    missing_required TEXT[];
    planned_not_installed TEXT[];
    planned_not_available TEXT[];
    result JSONB;
BEGIN
    SELECT COALESCE(array_agg(extname ORDER BY extname), ARRAY[]::TEXT[])
    INTO installed_extensions
    FROM pg_extension
    WHERE extname = ANY(required_extensions || planned_extensions);

    SELECT COALESCE(array_agg(name ORDER BY name), ARRAY[]::TEXT[])
    INTO available_extensions
    FROM pg_available_extensions
    WHERE name = ANY(required_extensions || planned_extensions);

    SELECT COALESCE(array_agg(ext ORDER BY ext), ARRAY[]::TEXT[])
    INTO missing_required
    FROM unnest(required_extensions) AS ext
    WHERE NOT (ext = ANY(installed_extensions));

    SELECT COALESCE(array_agg(ext ORDER BY ext), ARRAY[]::TEXT[])
    INTO planned_not_installed
    FROM unnest(planned_extensions) AS ext
    WHERE NOT (ext = ANY(installed_extensions));

    SELECT COALESCE(array_agg(ext ORDER BY ext), ARRAY[]::TEXT[])
    INTO planned_not_available
    FROM unnest(planned_extensions) AS ext
    WHERE NOT (ext = ANY(available_extensions));

    result := jsonb_build_object(
        'ready', COALESCE(array_length(missing_required, 1), 0) = 0,
        'strict', p_strict,
        'required_extensions', to_jsonb(required_extensions),
        'planned_extensions', to_jsonb(planned_extensions),
        'installed_extensions', to_jsonb(installed_extensions),
        'available_extensions', to_jsonb(available_extensions),
        'missing_required_extensions', to_jsonb(missing_required),
        'planned_extensions_not_installed', to_jsonb(planned_not_installed),
        'planned_extensions_not_available', to_jsonb(planned_not_available),
        'note', 'Slice 0 readiness is advisory for planned extensions; later slices install and require them.'
    );

    IF p_strict AND COALESCE(array_length(missing_required, 1), 0) > 0 THEN
        RAISE EXCEPTION 'Hexis DB-brain required extensions missing: %', array_to_string(missing_required, ', ')
            USING DETAIL = result::TEXT;
    END IF;

    RETURN result;
END;
$$;
-- ===== END INLINE: db/32_functions_db_brain.sql =====


-- ===== BEGIN INLINE: db/33_functions_runtime.sql =====
-- Hexis DB-owned runtime functions.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION upsert_prompt_module(
    p_key TEXT,
    p_content TEXT,
    p_description TEXT DEFAULT NULL,
    p_source_path TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    IF NULLIF(btrim(p_key), '') IS NULL THEN
        RAISE EXCEPTION 'prompt module key is required';
    END IF;
    IF p_content IS NULL THEN
        RAISE EXCEPTION 'prompt module content is required';
    END IF;

    INSERT INTO prompt_modules (key, content, description, source_path, metadata, updated_at)
    VALUES (p_key, p_content, p_description, p_source_path, COALESCE(p_metadata, '{}'::jsonb), CURRENT_TIMESTAMP)
    ON CONFLICT (key) DO UPDATE SET
        content = EXCLUDED.content,
        description = EXCLUDED.description,
        source_path = EXCLUDED.source_path,
        metadata = EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object('key', p_key, 'status', 'upserted');
END;
$$;

CREATE OR REPLACE FUNCTION render_prompt(
    p_key TEXT,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    template TEXT;
    rendered TEXT;
    match TEXT[];
    placeholder TEXT;
    path TEXT[];
    replacement TEXT;
BEGIN
    SELECT content INTO template
    FROM prompt_modules
    WHERE key = p_key;

    IF template IS NULL THEN
        RAISE EXCEPTION 'prompt module not found: %', p_key;
    END IF;

    rendered := template;
    FOR match IN
        SELECT regexp_matches(template, '\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}', 'g')
    LOOP
        placeholder := match[1];
        path := string_to_array(placeholder, '.');
        SELECT jsonb_extract_path_text(COALESCE(p_context, '{}'::jsonb), VARIADIC path)
        INTO replacement;
        rendered := replace(
            rendered,
            '{{' || placeholder || '}}',
            COALESCE(replacement, '')
        );
        rendered := regexp_replace(
            rendered,
            '\{\{\s*' || regexp_replace(placeholder, '([.^$*+?()\\[\]{}|\\-])', '\\\1', 'g') || '\s*\}\}',
            COALESCE(replacement, ''),
            'g'
        );
    END LOOP;

    RETURN rendered;
END;
$$;

CREATE OR REPLACE FUNCTION register_llm_task_kind(
    p_task_kind TEXT,
    p_provider_config_key TEXT,
    p_prompt_module_keys JSONB DEFAULT '[]'::jsonb,
    p_response_schema JSONB DEFAULT '{}'::jsonb,
    p_defaults JSONB DEFAULT '{}'::jsonb,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    IF NULLIF(btrim(p_task_kind), '') IS NULL THEN
        RAISE EXCEPTION 'task kind is required';
    END IF;
    IF NULLIF(btrim(p_provider_config_key), '') IS NULL THEN
        RAISE EXCEPTION 'provider config key is required';
    END IF;
    IF jsonb_typeof(COALESCE(p_prompt_module_keys, '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION 'prompt module keys must be a JSON array';
    END IF;

    INSERT INTO llm_task_kinds (
        task_kind,
        provider_config_key,
        prompt_module_keys,
        response_schema,
        defaults,
        metadata,
        updated_at
    )
    VALUES (
        p_task_kind,
        p_provider_config_key,
        COALESCE(p_prompt_module_keys, '[]'::jsonb),
        COALESCE(p_response_schema, '{}'::jsonb),
        COALESCE(p_defaults, '{}'::jsonb),
        COALESCE(p_metadata, '{}'::jsonb),
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (task_kind) DO UPDATE SET
        provider_config_key = EXCLUDED.provider_config_key,
        prompt_module_keys = EXCLUDED.prompt_module_keys,
        response_schema = EXCLUDED.response_schema,
        defaults = EXCLUDED.defaults,
        metadata = EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object('task_kind', p_task_kind, 'status', 'registered');
END;
$$;

CREATE OR REPLACE FUNCTION build_llm_request(
    p_task_kind TEXT,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    task llm_task_kinds%ROWTYPE;
    key_value JSONB;
    rendered_prompts TEXT[] := ARRAY[]::TEXT[];
    system_prompt TEXT;
    user_prompt TEXT;
BEGIN
    SELECT * INTO task
    FROM llm_task_kinds
    WHERE task_kind = p_task_kind;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'LLM task kind not found: %', p_task_kind;
    END IF;

    FOR key_value IN SELECT * FROM jsonb_array_elements(task.prompt_module_keys)
    LOOP
        rendered_prompts := rendered_prompts || render_prompt(key_value #>> '{}', COALESCE(p_context, '{}'::jsonb));
    END LOOP;

    system_prompt := array_to_string(rendered_prompts, E'\n\n');
    user_prompt := COALESCE(
        p_context->>'user_prompt',
        p_context->>'prompt',
        CASE
            WHEN p_context ? 'payload' THEN (p_context->'payload')::TEXT
            ELSE COALESCE(p_context, '{}'::jsonb)::TEXT
        END
    );

    RETURN jsonb_build_object(
        'task_kind', task.task_kind,
        'provider_config_key', task.provider_config_key,
        'messages', jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', system_prompt),
            jsonb_build_object('role', 'user', 'content', user_prompt)
        ),
        'response_schema', task.response_schema,
        'defaults', task.defaults,
        'metadata', task.metadata
    );
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_external_driver_call(
    p_driver TEXT,
    p_payload JSONB,
    p_max_attempts INT DEFAULT 3
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    call_id UUID;
BEGIN
    IF NULLIF(btrim(p_driver), '') IS NULL THEN
        RAISE EXCEPTION 'external driver is required';
    END IF;

    INSERT INTO external_driver_calls (driver, payload, max_attempts)
    VALUES (p_driver, COALESCE(p_payload, '{}'::jsonb), GREATEST(COALESCE(p_max_attempts, 3), 1))
    RETURNING id INTO call_id;

    RETURN call_id;
END;
$$;

CREATE OR REPLACE FUNCTION claim_external_driver_call(
    p_driver TEXT,
    p_limit INT DEFAULT 1,
    p_claim_timeout_s INT DEFAULT 600
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    payload JSONB;
BEGIN
    WITH candidate AS (
        SELECT id
        FROM external_driver_calls
        WHERE driver = p_driver
          AND (
              (status = 'pending' AND next_attempt_at <= CURRENT_TIMESTAMP)
              OR (
                  status = 'in_progress'
                  AND claimed_at < CURRENT_TIMESTAMP - make_interval(secs => GREATEST(COALESCE(p_claim_timeout_s, 600), 1))
              )
          )
        ORDER BY next_attempt_at, created_at
        FOR UPDATE SKIP LOCKED
        LIMIT GREATEST(COALESCE(p_limit, 1), 1)
    ),
    updated AS (
        UPDATE external_driver_calls c
        SET status = 'in_progress',
            attempts = attempts + 1,
            claimed_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        FROM candidate
        WHERE c.id = candidate.id
        RETURNING c.*
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(updated) ORDER BY updated.created_at), '[]'::jsonb)
    INTO payload
    FROM updated;

    RETURN payload;
END;
$$;

CREATE OR REPLACE FUNCTION apply_external_driver_result(
    p_call_id UUID,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out external_driver_calls%ROWTYPE;
BEGIN
    UPDATE external_driver_calls
    SET status = CASE WHEN COALESCE((p_result->>'success')::BOOLEAN, TRUE) THEN 'completed' ELSE 'failed' END,
        result = COALESCE(p_result, '{}'::jsonb),
        error = p_result->>'error',
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_call_id
    RETURNING * INTO row_out;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'external driver call not found: %', p_call_id;
    END IF;

    RETURN to_jsonb(row_out);
END;
$$;

CREATE OR REPLACE FUNCTION execute_llm_http(
    p_request JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    -- Provider-specific DB-side HTTP execution lands in the agent/external-call slices.
    -- Slice 1 intentionally exposes the stable SQL interface without changing runtime behavior.
    RETURN jsonb_build_object(
        'success', false,
        'deferred', true,
        'reason', 'db_side_llm_http_not_enabled_for_provider',
        'request', COALESCE(p_request, '{}'::jsonb)
    );
END;
$$;

SELECT register_llm_task_kind(
    'recmem_episode_merge',
    'llm.recmem',
    '["recmem_episode_merge"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":1800,"temperature":0.1}'::jsonb,
    '{"fallback_key":"llm.subconscious"}'::jsonb
);

SELECT register_llm_task_kind(
    'recmem_episode_create',
    'llm.recmem',
    '["recmem_episode_create"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":2200,"temperature":0.1}'::jsonb,
    '{"fallback_key":"llm.subconscious"}'::jsonb
);

SELECT register_llm_task_kind(
    'recmem_semantic_refine',
    'llm.recmem',
    '["recmem_semantic_refine"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":1800,"temperature":0.1}'::jsonb,
    '{"fallback_key":"llm.subconscious"}'::jsonb
);

SELECT register_llm_task_kind(
    'subconscious_decider',
    'llm.subconscious',
    '["subconscious"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":1800}'::jsonb,
    '{"fallback_key":"llm.heartbeat"}'::jsonb
);

SELECT register_llm_task_kind(
    'heartbeat_decision',
    'llm.heartbeat',
    '["heartbeat_system"]'::jsonb,
    '{"type":"object"}'::jsonb,
    '{"max_tokens":2048}'::jsonb,
    '{}'::jsonb
);
-- ===== END INLINE: db/33_functions_runtime.sql =====


-- ===== BEGIN INLINE: db/34_functions_chat_channel.sql =====
-- DB-owned chat and channel turn lifecycle.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION _db_brain_try_uuid(p_value TEXT)
RETURNS UUID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_value IS NULL OR p_value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RETURN NULL;
    END IF;
    RETURN p_value::uuid;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION estimate_conversation_importance(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_baseline FLOAT DEFAULT 0.5
) RETURNS FLOAT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    combined TEXT := lower(COALESCE(p_user_text, '') || E'\n' || COALESCE(p_assistant_text, ''));
    importance FLOAT := COALESCE(p_baseline, 0.5);
    signal TEXT;
    signals TEXT[] := ARRAY[
        'remember',
        'don''t forget',
        'important',
        'note that',
        'my name is',
        'i prefer',
        'i like',
        'i don''t like',
        'always',
        'never',
        'make sure',
        'keep in mind'
    ];
BEGIN
    IF length(COALESCE(p_user_text, '')) > 200 OR length(COALESCE(p_assistant_text, '')) > 500 THEN
        importance := GREATEST(importance, 0.7);
    END IF;

    FOREACH signal IN ARRAY signals LOOP
        IF position(signal IN combined) > 0 THEN
            importance := GREATEST(importance, 0.8);
            EXIT;
        END IF;
    END LOOP;

    RETURN LEAST(1.0, GREATEST(0.15, importance));
END;
$$;

CREATE OR REPLACE FUNCTION record_chat_turn_memory(
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_session_id TEXT DEFAULT NULL,
    p_source_identity TEXT DEFAULT NULL,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    started_at TIMESTAMPTZ := clock_timestamp();
    content TEXT;
    importance FLOAT;
    source_attribution JSONB;
    metadata JSONB;
    session_uuid UUID;
    recmem_enabled BOOLEAN;
    eager_enabled BOOLEAN;
    salience_promote BOOLEAN;
    dual_compare BOOLEAN;
    rollout_metrics BOOLEAN;
    raw JSONB;
    raw_unit_id UUID;
    eager_memory_id UUID;
    promoted BOOLEAN := FALSE;
    eager_written BOOLEAN := FALSE;
    duration_ms FLOAT;
BEGIN
    IF COALESCE(p_user_text, '') = '' AND COALESCE(p_assistant_text, '') = '' THEN
        RETURN jsonb_build_object('skipped', true, 'reason', 'empty_turn');
    END IF;

    content := format_recmem_turn(COALESCE(p_user_text, ''), COALESCE(p_assistant_text, ''));
    importance := COALESCE(
        NULLIF(p_context->>'importance', '')::FLOAT,
        estimate_conversation_importance(p_user_text, p_assistant_text)
    );
    metadata := COALESCE(p_context->'metadata', '{"type":"conversation"}'::jsonb);
    source_attribution := COALESCE(
        p_context->'source_attribution',
        jsonb_build_object(
            'kind', COALESCE(p_context #>> '{source_attribution_kind}', 'conversation'),
            'ref', COALESCE(p_source_identity, 'conversation_turn'),
            'label', COALESCE(p_context #>> '{source_attribution_label}', 'conversation turn'),
            'observed_at', CURRENT_TIMESTAMP,
            'trust', COALESCE(NULLIF(p_context #>> '{trust}', '')::FLOAT, 0.95)
        )
    );
    session_uuid := _db_brain_try_uuid(p_session_id);

    recmem_enabled := COALESCE(get_config_bool('memory.recmem_enabled'), false);
    eager_enabled := COALESCE(get_config_bool('chat.eager_memory_enabled'), true);
    salience_promote := COALESCE(get_config_bool('chat.recmem_salience_direct_promote'), true);
    dual_compare := COALESCE(get_config_bool('memory.recmem_dual_write_compare'), false);
    rollout_metrics := COALESCE(get_config_bool('memory.recmem_rollout_metrics_enabled'), false);

    IF recmem_enabled THEN
        raw := recmem_ingest_turn(
            p_user_text,
            p_assistant_text,
            session_uuid,
            p_source_identity,
            CURRENT_TIMESTAMP,
            importance,
            source_attribution,
            metadata
        );
        raw_unit_id := _db_brain_try_uuid(raw->>'unit_id');
    END IF;

    IF recmem_enabled AND salience_promote AND importance >= 0.8 THEN
        eager_memory_id := create_episodic_memory(
            content,
            NULL,
            jsonb_build_object('type', 'conversation', 'recmem', jsonb_build_object('direct_promoted', true)),
            NULL,
            0.0,
            CURRENT_TIMESTAMP,
            importance,
            source_attribution,
            0.95
        );
        promoted := TRUE;
        IF raw_unit_id IS NOT NULL THEN
            PERFORM link_memory_to_source_unit(eager_memory_id, raw_unit_id, 'direct_promotion');
        END IF;
    END IF;

    IF eager_enabled AND NOT promoted THEN
        eager_memory_id := create_episodic_memory(
            content,
            NULL,
            jsonb_build_object('type', 'conversation'),
            NULL,
            0.0,
            CURRENT_TIMESTAMP,
            importance,
            source_attribution,
            0.95
        );
        eager_written := TRUE;
    END IF;

    duration_ms := EXTRACT(EPOCH FROM (clock_timestamp() - started_at)) * 1000.0;

    IF rollout_metrics THEN
        PERFORM record_recmem_rollout_event(
            'chat_turn_memory',
            session_uuid,
            p_source_identity,
            raw_unit_id,
            raw->>'status',
            promoted,
            eager_written,
            eager_memory_id,
            duration_ms,
            NULL,
            jsonb_build_object(
                'importance', importance,
                'recmem_enabled', recmem_enabled,
                'eager_enabled', eager_enabled,
                'db_owned', true
            )
        );
    END IF;

    IF recmem_enabled AND eager_enabled AND dual_compare THEN
        PERFORM enqueue_external_driver_call(
            'recmem_dual_write_comparison',
            jsonb_build_object(
                'query', p_user_text,
                'session_id', p_session_id,
                'source_identity', p_source_identity
            )
        );
    END IF;

    RETURN jsonb_build_object(
        'raw', COALESCE(raw, '{}'::jsonb),
        'raw_unit_id', raw_unit_id,
        'direct_promoted', promoted,
        'eager_written', eager_written,
        'eager_memory_id', eager_memory_id,
        'importance', importance,
        'duration_ms', duration_ms,
        'recmem_enabled', recmem_enabled,
        'eager_enabled', eager_enabled
    );
END;
$$;

CREATE OR REPLACE FUNCTION prepare_channel_turn(
    p_message JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_channel_type TEXT := p_message->>'channel_type';
    v_channel_id TEXT := p_message->>'channel_id';
    v_sender_id TEXT := p_message->>'sender_id';
    v_sender_name TEXT := p_message->>'sender_name';
    v_content TEXT := COALESCE(p_message->>'content', '');
    v_platform_message_id TEXT := p_message->>'message_id';
    cost FLOAT;
    multiplier FLOAT;
    effective_cost FLOAT;
    rate_limit INT;
    recent_count INT;
    session_row channel_sessions%ROWTYPE;
    remaining_energy FLOAT;
BEGIN
    cost := COALESCE(NULLIF(get_config_text('channel.' || v_channel_type || '.energy_cost'), '')::FLOAT, 0.0);
    multiplier := COALESCE(NULLIF(get_config_text('channel.' || v_channel_type || '.energy_multiplier'), '')::FLOAT, 1.0);
    effective_cost := cost * multiplier;
    rate_limit := NULLIF(get_config_text('channel.' || v_channel_type || '.rate_limit.max_per_sender_per_hour'), '')::INT;

    IF rate_limit IS NOT NULL THEN
        SELECT COUNT(*)::INT INTO recent_count
        FROM channel_messages cm
        JOIN channel_sessions cs ON cm.session_id = cs.id
        WHERE cs.sender_id = v_sender_id
          AND cs.channel_type = v_channel_type
          AND cm.direction = 'inbound'
          AND cm.created_at > CURRENT_TIMESTAMP - INTERVAL '1 hour';
        IF recent_count >= rate_limit THEN
            RETURN jsonb_build_object('allowed', false, 'cost', effective_cost, 'rejection', 'Rate limit exceeded. Please try again later.');
        END IF;
    END IF;

    IF effective_cost > 0 THEN
        UPDATE heartbeat_state
        SET current_energy = current_energy - effective_cost
        WHERE current_energy >= effective_cost
        RETURNING current_energy INTO remaining_energy;
        IF remaining_energy IS NULL THEN
            RETURN jsonb_build_object('allowed', false, 'cost', effective_cost, 'rejection', 'I need to rest and recharge before I can respond. Please try again later.');
        END IF;
    END IF;

    SELECT * INTO session_row
    FROM channel_sessions cs
    WHERE cs.channel_type = v_channel_type
      AND cs.channel_id = v_channel_id
      AND cs.sender_id = v_sender_id
    LIMIT 1;

    IF NOT FOUND THEN
        INSERT INTO channel_sessions (channel_type, channel_id, sender_id, sender_name, history)
        VALUES (v_channel_type, v_channel_id, v_sender_id, v_sender_name, '[]'::jsonb)
        RETURNING * INTO session_row;
    END IF;

    INSERT INTO channel_messages (session_id, direction, content, platform_message_id, metadata)
    VALUES (
        session_row.id,
        'inbound',
        v_content,
        v_platform_message_id,
        jsonb_build_object('channel_type', v_channel_type, 'sender_name', v_sender_name)
    );

    RETURN jsonb_build_object(
        'allowed', true,
        'cost', effective_cost,
        'session_id', session_row.id,
        'history', COALESCE(session_row.history, '[]'::jsonb)
    );
END;
$$;

CREATE OR REPLACE FUNCTION flush_channel_history_to_memory(
    p_session_id UUID,
    p_trimmed_history JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    idx INT := 0;
    item JSONB;
    next_item JSONB;
    user_text TEXT;
    assistant_text TEXT;
    stored INT := 0;
    digest TEXT;
    source_identity TEXT;
    result JSONB;
BEGIN
    WHILE idx < jsonb_array_length(COALESCE(p_trimmed_history, '[]'::jsonb)) LOOP
        item := p_trimmed_history->idx;
        next_item := p_trimmed_history->(idx + 1);
        user_text := '';
        assistant_text := '';

        IF item->>'role' = 'user' THEN
            user_text := COALESCE(item->>'content', '');
            IF next_item->>'role' = 'assistant' THEN
                assistant_text := COALESCE(next_item->>'content', '');
                idx := idx + 2;
            ELSE
                idx := idx + 1;
            END IF;
        ELSIF item->>'role' = 'assistant' THEN
            assistant_text := COALESCE(item->>'content', '');
            idx := idx + 1;
        ELSE
            idx := idx + 1;
            CONTINUE;
        END IF;

        IF user_text <> '' OR assistant_text <> '' THEN
            IF estimate_conversation_importance(user_text, assistant_text, 0.3) < 0.4
               AND length(user_text) + length(assistant_text) < 100 THEN
                CONTINUE;
            END IF;
            digest := substring(encode(digest(user_text || E'\x1e' || assistant_text, 'sha256'), 'hex') from 1 for 16);
            source_identity := 'compaction:' || p_session_id::text || ':' || stored::text || ':' || digest;
            result := record_chat_turn_memory(
                user_text,
                assistant_text,
                p_session_id::text,
                source_identity,
                jsonb_build_object(
                    'importance', estimate_conversation_importance(user_text, assistant_text, 0.3),
                    'metadata', jsonb_build_object('type', 'conversation', 'source', 'compaction_flush'),
                    'source_attribution', jsonb_build_object(
                        'kind', 'compaction_flush',
                        'ref', p_session_id,
                        'label', 'pre-compaction memory flush',
                        'observed_at', CURRENT_TIMESTAMP,
                        'trust', 0.85
                    ),
                    'trust', 0.85
                )
            );
            stored := stored + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('stored', stored);
END;
$$;

CREATE OR REPLACE FUNCTION finalize_channel_turn(
    p_session_id UUID,
    p_user_text TEXT,
    p_assistant_text TEXT,
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_history JSONB := COALESCE(p_result->'history', '[]'::jsonb);
    trimmed JSONB := '[]'::jsonb;
    trim_to INT := 30;
    max_history INT := 40;
    flush_result JSONB := '{}'::jsonb;
    platform_message_id TEXT := p_result->>'platform_message_id';
    metadata JSONB := COALESCE(p_result->'metadata', '{}'::jsonb);
BEGIN
    IF jsonb_array_length(v_history) > max_history THEN
        SELECT COALESCE(jsonb_agg(value ORDER BY ord), '[]'::jsonb)
        INTO trimmed
        FROM jsonb_array_elements(v_history) WITH ORDINALITY AS t(value, ord)
        WHERE ord <= jsonb_array_length(v_history) - trim_to;

        SELECT COALESCE(jsonb_agg(value ORDER BY ord), '[]'::jsonb)
        INTO v_history
        FROM jsonb_array_elements(v_history) WITH ORDINALITY AS t(value, ord)
        WHERE ord > jsonb_array_length(v_history) - trim_to;

        flush_result := flush_channel_history_to_memory(p_session_id, trimmed);
    END IF;

    UPDATE channel_sessions
    SET history = v_history,
        last_active = CURRENT_TIMESTAMP
    WHERE id = p_session_id;

    INSERT INTO channel_messages (session_id, direction, content, platform_message_id, metadata)
    VALUES (p_session_id, 'outbound', COALESCE(p_assistant_text, ''), platform_message_id, metadata);

    RETURN jsonb_build_object('session_id', p_session_id, 'history_count', jsonb_array_length(v_history), 'flush', flush_result);
END;
$$;
-- ===== END INLINE: db/34_functions_chat_channel.sql =====


-- ===== BEGIN INLINE: db/35_functions_recmem_ops.sql =====
-- DB-owned RecMem operations, rollout/eval, and subconscious post-processing.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION load_recmem_task_context(
    p_task_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    task_row recmem_consolidation_tasks%ROWTYPE;
    sources JSONB;
    target JSONB;
BEGIN
    SELECT * INTO task_row
    FROM recmem_consolidation_tasks
    WHERE id = p_task_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RecMem task not found: %', p_task_id;
    END IF;

    SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.turn_at, s.created_at), '[]'::jsonb)
    INTO sources
    FROM (
        SELECT id, content, user_text, assistant_text, turn_at, created_at
        FROM subconscious_units
        WHERE id = ANY(task_row.source_unit_ids)
    ) s;

    IF task_row.target_memory_id IS NOT NULL THEN
        SELECT to_jsonb(m)
        INTO target
        FROM (
            SELECT id, content, type::text, trust_level
            FROM memories
            WHERE id = task_row.target_memory_id
        ) m;
    END IF;

    RETURN jsonb_build_object(
        'task', to_jsonb(task_row),
        'sources', COALESCE(sources, '[]'::jsonb),
        'target_memory', target
    );
END;
$$;

CREATE OR REPLACE FUNCTION normalize_recmem_episode_output(
    p_output JSONB
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    raw JSONB;
    item JSONB;
    episodes JSONB := '[]'::jsonb;
BEGIN
    raw := CASE
        WHEN jsonb_typeof(p_output) = 'object' THEN COALESCE(p_output->'episodes', '[]'::jsonb)
        ELSE COALESCE(p_output, '[]'::jsonb)
    END;
    IF jsonb_typeof(raw) <> 'array' THEN
        RETURN '[]'::jsonb;
    END IF;
    FOR item IN SELECT * FROM jsonb_array_elements(raw) LOOP
        IF jsonb_typeof(item) = 'string' THEN
            episodes := episodes || jsonb_build_array(jsonb_build_object('content', item #>> '{}'));
        ELSIF jsonb_typeof(item) = 'object' AND COALESCE(item->>'content', item->>'episode') IS NOT NULL THEN
            episodes := episodes || jsonb_build_array(item);
        END IF;
    END LOOP;
    RETURN episodes;
END;
$$;

CREATE OR REPLACE FUNCTION normalize_recmem_fact_output(
    p_output JSONB
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    raw JSONB;
    item JSONB;
    facts JSONB := '[]'::jsonb;
BEGIN
    raw := CASE
        WHEN jsonb_typeof(p_output) = 'object' THEN COALESCE(p_output->'facts', '[]'::jsonb)
        ELSE COALESCE(p_output, '[]'::jsonb)
    END;
    IF jsonb_typeof(raw) <> 'array' THEN
        RETURN '[]'::jsonb;
    END IF;
    FOR item IN SELECT * FROM jsonb_array_elements(raw) LOOP
        IF jsonb_typeof(item) = 'string' THEN
            facts := facts || jsonb_build_array(jsonb_build_object('content', item #>> '{}'));
        ELSIF jsonb_typeof(item) = 'object' AND COALESCE(item->>'content', item->>'fact') IS NOT NULL THEN
            facts := facts || jsonb_build_array(item);
        END IF;
    END LOOP;
    RETURN facts;
END;
$$;

CREATE OR REPLACE FUNCTION run_recmem_eval_set(
    p_eval_set TEXT,
    p_label TEXT DEFAULT NULL,
    p_limit INT DEFAULT 10
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    eval_row recmem_eval_sets%ROWTYPE;
    run_id UUID;
    item recmem_eval_items%ROWTYPE;
    baseline_ids UUID[];
    recmem_ids UUID[];
    expected_ids UUID[];
    baseline_score FLOAT;
    recmem_score FLOAT;
    verdict TEXT;
    safe_limit INT := GREATEST(COALESCE(p_limit, 10), 1);
BEGIN
    BEGIN
        SELECT * INTO eval_row FROM recmem_eval_sets WHERE id = p_eval_set::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        SELECT * INTO eval_row FROM recmem_eval_sets WHERE name = p_eval_set;
    END;
    IF eval_row.id IS NULL THEN
        RAISE EXCEPTION 'RecMem eval set not found: %', p_eval_set;
    END IF;

    INSERT INTO recmem_eval_runs (eval_set_id, label, baseline_config, recmem_config, metadata)
    VALUES (
        eval_row.id,
        p_label,
        jsonb_build_object('retrieval', 'fast_recall', 'limit', safe_limit),
        jsonb_build_object('retrieval', 'recmem_recall_context', 'limit', safe_limit),
        '{}'::jsonb
    )
    RETURNING id INTO run_id;

    BEGIN
        FOR item IN
            SELECT * FROM recmem_eval_items WHERE eval_set_id = eval_row.id ORDER BY created_at, id
        LOOP
            SELECT COALESCE(array_agg(memory_id), ARRAY[]::uuid[])
            INTO baseline_ids
            FROM (
                SELECT memory_id FROM fast_recall(item.query_text, safe_limit)
            ) b;

            SELECT COALESCE(array_agg(item_id), ARRAY[]::uuid[])
            INTO recmem_ids
            FROM (
                SELECT item_id
                FROM recmem_recall_context(item.query_text, safe_limit, GREATEST(1, LEAST(safe_limit, 5)), safe_limit)
                WHERE tier IN ('episodic', 'semantic')
                LIMIT safe_limit
            ) r;

            SELECT COALESCE(array_agg(value::uuid), ARRAY[]::uuid[])
            INTO expected_ids
            FROM jsonb_array_elements_text(
                COALESCE(
                    NULLIF(item.metadata->'expected_memory_ids', 'null'::jsonb),
                    NULLIF(item.session_fixture->'expected_memory_ids', 'null'::jsonb),
                    '[]'::jsonb
                )
            ) ids(value)
            WHERE value ~* '^[0-9a-f-]{36}$';

            IF cardinality(expected_ids) = 0 THEN
                baseline_score := NULL;
                recmem_score := NULL;
                verdict := 'unjudged';
            ELSE
                SELECT COUNT(*)::float / cardinality(expected_ids)::float
                INTO baseline_score
                FROM unnest(expected_ids) expected(id)
                WHERE expected.id = ANY(baseline_ids);

                SELECT COUNT(*)::float / cardinality(expected_ids)::float
                INTO recmem_score
                FROM unnest(expected_ids) expected(id)
                WHERE expected.id = ANY(recmem_ids);

                IF recmem_score >= COALESCE(baseline_score, 0) THEN
                    verdict := 'pass';
                ELSIF baseline_score IS NULL THEN
                    verdict := CASE WHEN recmem_score > 0 THEN 'pass' ELSE 'miss' END;
                ELSE
                    verdict := 'regression';
                END IF;
            END IF;

            INSERT INTO recmem_eval_results (
                run_id, item_id, category, baseline_memory_ids, recmem_memory_ids, judge_score, verdict, metadata
            )
            VALUES (
                run_id,
                item.id,
                item.category,
                baseline_ids,
                recmem_ids,
                recmem_score,
                verdict,
                jsonb_build_object(
                    'expected_memory_ids', to_jsonb(expected_ids),
                    'baseline_hit_rate', baseline_score,
                    'recmem_hit_rate', recmem_score
                )
            );
        END LOOP;

        UPDATE recmem_eval_runs
        SET status = 'completed', completed_at = CURRENT_TIMESTAMP
        WHERE id = run_id;
    EXCEPTION WHEN OTHERS THEN
        UPDATE recmem_eval_runs
        SET status = 'failed',
            completed_at = CURRENT_TIMESTAMP,
            metadata = metadata || jsonb_build_object('error', SQLERRM)
        WHERE id = run_id;
        RAISE;
    END;

    RETURN get_recmem_eval_run_summary(run_id);
END;
$$;

CREATE OR REPLACE FUNCTION recmem_rollout_phase_config(
    p_phase INT
) RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_phase
        WHEN 0 THEN '{"memory.recmem_rollout_phase":0,"memory.recmem_enabled":false,"chat.eager_memory_enabled":true,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":false,"memory.recmem_dual_write_compare":false,"memory.recmem_rollout_metrics_enabled":false,"memory.recmem_worker_enabled":false}'::jsonb
        WHEN 1 THEN '{"memory.recmem_rollout_phase":1,"memory.recmem_enabled":false,"chat.eager_memory_enabled":true,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":false,"memory.recmem_dual_write_compare":false,"memory.recmem_rollout_metrics_enabled":true,"memory.recmem_worker_enabled":false}'::jsonb
        WHEN 2 THEN '{"memory.recmem_rollout_phase":2,"memory.recmem_enabled":true,"chat.eager_memory_enabled":true,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":false,"memory.recmem_dual_write_compare":true,"memory.recmem_rollout_metrics_enabled":true,"memory.recmem_worker_enabled":false}'::jsonb
        WHEN 3 THEN '{"memory.recmem_rollout_phase":3,"memory.recmem_enabled":true,"chat.eager_memory_enabled":false,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":false,"memory.recmem_dual_write_compare":false,"memory.recmem_rollout_metrics_enabled":true,"memory.recmem_worker_enabled":false}'::jsonb
        WHEN 4 THEN '{"memory.recmem_rollout_phase":4,"memory.recmem_enabled":true,"chat.eager_memory_enabled":false,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":false,"memory.recmem_dual_write_compare":false,"memory.recmem_rollout_metrics_enabled":true,"memory.recmem_worker_enabled":true}'::jsonb
        WHEN 5 THEN '{"memory.recmem_rollout_phase":5,"memory.recmem_enabled":true,"chat.eager_memory_enabled":false,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":true,"memory.recmem_dual_write_compare":false,"memory.recmem_rollout_metrics_enabled":true,"memory.recmem_worker_enabled":true}'::jsonb
        WHEN 6 THEN '{"memory.recmem_rollout_phase":6,"memory.recmem_enabled":true,"chat.eager_memory_enabled":false,"chat.inline_subconscious_enabled":true,"memory.recmem_hydrate_enabled":true,"memory.recmem_dual_write_compare":false,"memory.recmem_rollout_metrics_enabled":true,"memory.recmem_worker_enabled":true}'::jsonb
        ELSE NULL
    END;
$$;

CREATE OR REPLACE FUNCTION infer_recmem_rollout_phase()
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    phase INT;
    cfg JSONB;
    key TEXT;
    value JSONB;
    matches BOOLEAN;
BEGIN
    FOR phase IN REVERSE 6..0 LOOP
        cfg := recmem_rollout_phase_config(phase);
        matches := TRUE;
        FOR key, value IN SELECT * FROM jsonb_each(cfg) LOOP
            IF get_config(key) IS DISTINCT FROM value THEN
                matches := FALSE;
                EXIT;
            END IF;
        END LOOP;
        IF matches THEN
            RETURN phase;
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION get_recmem_rollout_status(
    p_eval_run_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    selected_run_id UUID := p_eval_run_id;
    configs JSONB := '{}'::jsonb;
    key TEXT;
BEGIN
    IF selected_run_id IS NULL THEN
        SELECT id INTO selected_run_id
        FROM recmem_eval_runs
        WHERE status = 'completed'
        ORDER BY completed_at DESC NULLS LAST, started_at DESC
        LIMIT 1;
    END IF;

    FOREACH key IN ARRAY ARRAY[
        'memory.recmem_rollout_phase',
        'memory.recmem_enabled',
        'chat.eager_memory_enabled',
        'chat.recmem_salience_direct_promote',
        'chat.inline_subconscious_enabled',
        'memory.recmem_hydrate_enabled',
        'memory.recmem_dual_write_compare',
        'memory.recmem_rollout_metrics_enabled',
        'memory.recmem_worker_enabled'
    ] LOOP
        configs := configs || jsonb_build_object(key, get_config(key));
    END LOOP;

    RETURN jsonb_build_object(
        'phase', infer_recmem_rollout_phase(),
        'configs', configs,
        'health', COALESCE((SELECT to_jsonb(h) FROM recmem_rollout_health h LIMIT 1), '{}'::jsonb),
        'metrics_7d', get_recmem_rollout_metrics(CURRENT_TIMESTAMP - INTERVAL '7 days'),
        'phase5_readiness', get_recmem_phase5_readiness(selected_run_id)
    );
END;
$$;

CREATE OR REPLACE FUNCTION apply_recmem_rollout_phase(
    p_phase INT,
    p_eval_run_id UUID DEFAULT NULL,
    p_force BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    cfg JSONB;
    readiness JSONB;
    key TEXT;
    value JSONB;
BEGIN
    cfg := recmem_rollout_phase_config(p_phase);
    IF cfg IS NULL THEN
        RAISE EXCEPTION 'Unknown RecMem rollout phase: %', p_phase;
    END IF;

    IF p_phase >= 5 AND NOT COALESCE(p_force, false) THEN
        readiness := get_recmem_phase5_readiness(p_eval_run_id);
        IF COALESCE((readiness->>'ready')::boolean, false) IS DISTINCT FROM TRUE THEN
            RAISE EXCEPTION 'Phase % requires a passing readiness gate: %', p_phase, COALESCE(readiness->>'reason', 'readiness_unavailable');
        END IF;
    END IF;

    FOR key, value IN SELECT * FROM jsonb_each(cfg) LOOP
        PERFORM set_config(key, value);
    END LOOP;

    RETURN get_recmem_rollout_status(p_eval_run_id)
        || jsonb_build_object('applied_phase', p_phase, 'forced', COALESCE(p_force, false));
END;
$$;

CREATE OR REPLACE FUNCTION normalize_subconscious_observations(
    p_doc JSONB
) RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
        'narrative_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'narrative_observations', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'narrative_observations', '[]'::jsonb) ELSE '[]'::jsonb END,
        'relationship_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'relationship_observations', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'relationship_observations', '[]'::jsonb) ELSE '[]'::jsonb END,
        'contradiction_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'contradiction_observations', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'contradiction_observations', '[]'::jsonb) ELSE '[]'::jsonb END,
        'emotional_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'emotional_observations', p_doc->'emotional_patterns', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'emotional_observations', p_doc->'emotional_patterns', '[]'::jsonb) ELSE '[]'::jsonb END,
        'consolidation_observations', CASE WHEN jsonb_typeof(COALESCE(p_doc->'consolidation_observations', p_doc->'consolidation_suggestions', '[]'::jsonb)) = 'array' THEN COALESCE(p_doc->'consolidation_observations', p_doc->'consolidation_suggestions', '[]'::jsonb) ELSE '[]'::jsonb END
    );
$$;

CREATE OR REPLACE FUNCTION compute_dopamine_rpe(
    p_context JSONB DEFAULT '{}'::jsonb,
    p_doc JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    da_state JSONB;
    affect JSONB;
    tonic FLOAT;
    current_valence FLOAT;
    current_arousal FLOAT;
    expected_valence FLOAT;
    rpe FLOAT;
    trigger_parts TEXT[] := ARRAY[]::TEXT[];
    obs JSONB;
    result JSONB;
    emotional_obs JSONB;
    relationship_obs JSONB;
BEGIN
    da_state := get_dopamine_state();
    affect := get_current_affective_state();
    BEGIN tonic := NULLIF(da_state->>'tonic', '')::float;
    EXCEPTION WHEN OTHERS THEN tonic := NULL; END;
    BEGIN current_valence := NULLIF(affect->>'valence', '')::float;
    EXCEPTION WHEN OTHERS THEN current_valence := NULL; END;
    BEGIN current_arousal := NULLIF(affect->>'arousal', '')::float;
    EXCEPTION WHEN OTHERS THEN current_arousal := NULL; END;
    tonic := COALESCE(tonic, 0.5);
    current_valence := COALESCE(current_valence, 0.0);
    current_arousal := COALESCE(current_arousal, 0.5);
    expected_valence := (tonic - 0.5) * 2.0;
    rpe := current_valence - expected_valence;
    rpe := rpe * (0.5 + current_arousal * 0.5);
    rpe := LEAST(1.0, GREATEST(-1.0, rpe));

    IF abs(rpe) < 0.15 THEN
        RETURN jsonb_build_object('fired', false, 'rpe', rpe, 'tonic', tonic);
    END IF;

    IF p_doc #>> '{emotional_state,primary_emotion}' IS NOT NULL THEN
        trigger_parts := trigger_parts || ('feeling ' || (p_doc #>> '{emotional_state,primary_emotion}'));
    END IF;
    emotional_obs := COALESCE(p_doc->'emotional_observations', p_doc->'emotional_patterns', '[]'::jsonb);
    IF jsonb_typeof(emotional_obs) <> 'array' THEN
        emotional_obs := '[]'::jsonb;
    END IF;
    FOR obs IN SELECT * FROM jsonb_array_elements(emotional_obs) LIMIT 2 LOOP
        IF COALESCE(obs->>'pattern', obs->>'summary', obs->>'theme') IS NOT NULL THEN
            trigger_parts := trigger_parts || left(COALESCE(obs->>'pattern', obs->>'summary', obs->>'theme'), 100);
        END IF;
    END LOOP;
    relationship_obs := COALESCE(p_doc->'relationship_observations', '[]'::jsonb);
    IF jsonb_typeof(relationship_obs) <> 'array' THEN
        relationship_obs := '[]'::jsonb;
    END IF;
    FOR obs IN SELECT * FROM jsonb_array_elements(relationship_obs) LIMIT 2 LOOP
        IF obs->>'entity' IS NOT NULL AND obs->>'change_type' IS NOT NULL THEN
            trigger_parts := trigger_parts || ((obs->>'change_type') || ' with ' || (obs->>'entity'));
        END IF;
    END LOOP;

    result := fire_dopamine_spike(
        rpe,
        COALESCE(array_to_string(trigger_parts, '; '), 'affective state shift')
    );
    RETURN jsonb_build_object('fired', true, 'rpe', rpe, 'result', result);
END;
$$;

CREATE OR REPLACE FUNCTION apply_subconscious_decider_result(
    p_doc JSONB,
    p_raw_response JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    observations JSONB;
    applied JSONB;
    dopamine JSONB;
BEGIN
    observations := normalize_subconscious_observations(COALESCE(p_doc, '{}'::jsonb));
    applied := apply_subconscious_observations(observations);
    dopamine := compute_dopamine_rpe('{}'::jsonb, COALESCE(p_doc, '{}'::jsonb));
    RETURN jsonb_build_object('applied', applied, 'dopamine', dopamine, 'raw_response', COALESCE(p_raw_response, '{}'::jsonb));
END;
$$;
-- ===== END INLINE: db/35_functions_recmem_ops.sql =====


-- ===== BEGIN INLINE: db/36_functions_tool_runtime.sql =====
-- DB-owned tool catalog, policy, workflow bookkeeping, and schedule parsing.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION upsert_tool_definition(
    p_name TEXT,
    p_category TEXT,
    p_schema JSONB DEFAULT '{}'::jsonb,
    p_description TEXT DEFAULT '',
    p_energy_cost INT DEFAULT 1,
    p_allowed_contexts TEXT[] DEFAULT ARRAY[]::TEXT[],
    p_requires_approval BOOLEAN DEFAULT FALSE,
    p_supports_parallel BOOLEAN DEFAULT TRUE,
    p_optional BOOLEAN DEFAULT FALSE,
    p_read_only BOOLEAN DEFAULT TRUE,
    p_execution_kind TEXT DEFAULT 'python_driver',
    p_driver TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    meta JSONB;
BEGIN
    IF NULLIF(btrim(p_name), '') IS NULL THEN
        RAISE EXCEPTION 'tool name is required';
    END IF;
    IF NULLIF(btrim(p_category), '') IS NULL THEN
        RAISE EXCEPTION 'tool category is required';
    END IF;

    meta := COALESCE(p_metadata, '{}'::jsonb)
        || jsonb_build_object(
            'description', COALESCE(p_description, ''),
            'optional', COALESCE(p_optional, false),
            'is_read_only', COALESCE(p_read_only, true)
        );

    INSERT INTO tool_definitions (
        name, category, schema, default_energy_cost, allowed_contexts,
        requires_approval, supports_parallel, execution_kind, driver, metadata, updated_at
    )
    VALUES (
        p_name,
        p_category,
        COALESCE(p_schema, '{}'::jsonb),
        GREATEST(COALESCE(p_energy_cost, 1), 0),
        COALESCE(p_allowed_contexts, ARRAY[]::TEXT[]),
        COALESCE(p_requires_approval, false),
        COALESCE(p_supports_parallel, true),
        COALESCE(NULLIF(p_execution_kind, ''), 'python_driver'),
        p_driver,
        meta,
        CURRENT_TIMESTAMP
    )
    ON CONFLICT (name) DO UPDATE SET
        category = EXCLUDED.category,
        schema = EXCLUDED.schema,
        default_energy_cost = EXCLUDED.default_energy_cost,
        allowed_contexts = EXCLUDED.allowed_contexts,
        requires_approval = EXCLUDED.requires_approval,
        supports_parallel = EXCLUDED.supports_parallel,
        execution_kind = EXCLUDED.execution_kind,
        driver = EXCLUDED.driver,
        metadata = EXCLUDED.metadata,
        updated_at = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object('name', p_name, 'status', 'upserted');
END;
$$;

CREATE OR REPLACE FUNCTION sync_tool_definitions(
    p_tools JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    tool JSONB;
    count_synced INT := 0;
BEGIN
    IF jsonb_typeof(COALESCE(p_tools, '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION 'p_tools must be an array';
    END IF;

    FOR tool IN SELECT * FROM jsonb_array_elements(COALESCE(p_tools, '[]'::jsonb))
    LOOP
        PERFORM upsert_tool_definition(
            tool->>'name',
            tool->>'category',
            COALESCE(tool->'schema', '{}'::jsonb),
            COALESCE(tool->>'description', ''),
            COALESCE(NULLIF(tool->>'energy_cost', '')::int, 1),
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(tool->'allowed_contexts', '[]'::jsonb))), ARRAY[]::TEXT[]),
            COALESCE((tool->>'requires_approval')::boolean, false),
            COALESCE((tool->>'supports_parallel')::boolean, true),
            COALESCE((tool->>'optional')::boolean, false),
            COALESCE((tool->>'is_read_only')::boolean, true),
            COALESCE(tool->>'execution_kind', 'python_driver'),
            tool->>'driver',
            COALESCE(tool->'metadata', '{}'::jsonb)
        );
        count_synced := count_synced + 1;
    END LOOP;

    RETURN jsonb_build_object('synced', count_synced);
END;
$$;

CREATE OR REPLACE FUNCTION tool_config_enabled(
    p_tool_name TEXT,
    p_category TEXT,
    p_context TEXT,
    p_optional BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    cfg JSONB := COALESCE(get_config('tools'), '{}'::jsonb);
    ctx_cfg JSONB := '{}'::jsonb;
    enabled JSONB;
    disabled JSONB;
    disabled_categories JSONB;
    ctx_enabled JSONB;
    ctx_disabled JSONB;
    allowed_optional JSONB;
    allowed_optional_groups JSONB;
BEGIN
    enabled := cfg->'enabled';
    disabled := COALESCE(cfg->'disabled', '[]'::jsonb);
    disabled_categories := COALESCE(cfg->'disabled_categories', '[]'::jsonb);
    ctx_cfg := COALESCE(cfg #> ARRAY['context_overrides', p_context], '{}'::jsonb);
    ctx_enabled := COALESCE(ctx_cfg->'enabled', '[]'::jsonb);
    ctx_disabled := COALESCE(ctx_cfg->'disabled', '[]'::jsonb);

    IF disabled ? p_tool_name OR disabled_categories ? p_category THEN
        RETURN FALSE;
    END IF;
    IF enabled IS NOT NULL AND jsonb_typeof(enabled) = 'array' AND NOT (enabled ? p_tool_name) THEN
        RETURN FALSE;
    END IF;
    IF ctx_disabled ? p_tool_name THEN
        RETURN FALSE;
    END IF;
    IF COALESCE((ctx_cfg->>'allow_all')::boolean, false) THEN
        RETURN TRUE;
    END IF;
    IF jsonb_typeof(ctx_enabled) = 'array' AND jsonb_array_length(ctx_enabled) > 0 AND NOT (ctx_enabled ? p_tool_name) THEN
        RETURN FALSE;
    END IF;

    IF COALESCE(p_optional, false) THEN
        allowed_optional := COALESCE(cfg->'allowed_optional', '[]'::jsonb);
        allowed_optional_groups := COALESCE(cfg->'allowed_optional_groups', '[]'::jsonb);
        IF NOT (allowed_optional ? p_tool_name OR allowed_optional_groups ? p_category OR allowed_optional_groups ? 'plugins') THEN
            RETURN FALSE;
        END IF;
    END IF;

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION get_tool_specs_for_context(
    p_context TEXT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    specs JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'type', 'function',
            'function', jsonb_build_object(
                'name', name,
                'description', COALESCE(metadata->>'description', ''),
                'parameters', schema
            )
        )
        ORDER BY name
    ), '[]'::jsonb)
    INTO specs
    FROM tool_definitions
    WHERE (COALESCE(array_length(allowed_contexts, 1), 0) = 0 OR lower(p_context) = ANY(allowed_contexts))
      AND tool_config_enabled(name, category, lower(p_context), COALESCE((metadata->>'optional')::boolean, false));

    RETURN specs;
END;
$$;

CREATE OR REPLACE FUNCTION evaluate_tool_call(
    p_tool_name TEXT,
    p_arguments JSONB DEFAULT '{}'::jsonb,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    tool tool_definitions%ROWTYPE;
    ctx TEXT := lower(COALESCE(p_context->>'tool_context', p_context->>'context', 'chat'));
    energy_available INT;
    cfg JSONB := COALESCE(get_config('tools'), '{}'::jsonb);
    ctx_cfg JSONB;
    cost INT;
    max_per_tool INT;
    boundary TEXT;
BEGIN
    SELECT * INTO tool FROM tool_definitions WHERE name = p_tool_name;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'Unknown tool: ' || p_tool_name, 'error_type', 'unknown_tool');
    END IF;

    IF NOT tool_config_enabled(tool.name, tool.category, ctx, COALESCE((tool.metadata->>'optional')::boolean, false)) THEN
        RETURN jsonb_build_object('allowed', false, 'reason', format('Tool %L is disabled', tool.name), 'error_type', 'disabled');
    END IF;
    IF COALESCE(array_length(tool.allowed_contexts, 1), 0) > 0 AND NOT (ctx = ANY(tool.allowed_contexts)) THEN
        RETURN jsonb_build_object('allowed', false, 'reason', format('Tool %L not allowed in %s context', tool.name, ctx), 'error_type', 'context_denied');
    END IF;

    cost := COALESCE(NULLIF(cfg #>> ARRAY['costs', tool.name], '')::int, tool.default_energy_cost);
    IF ctx = 'heartbeat' AND p_context ? 'energy_available' THEN
        BEGIN energy_available := NULLIF(p_context->>'energy_available', '')::int;
        EXCEPTION WHEN OTHERS THEN energy_available := NULL; END;
        ctx_cfg := COALESCE(cfg #> '{context_overrides,heartbeat}', '{}'::jsonb);
        BEGIN max_per_tool := NULLIF(ctx_cfg->>'max_energy_per_tool', '')::int;
        EXCEPTION WHEN OTHERS THEN max_per_tool := NULL; END;
        IF max_per_tool IS NOT NULL AND cost > max_per_tool THEN
            RETURN jsonb_build_object('allowed', false, 'reason', format('Tool %L cost (%s) exceeds max per tool (%s)', tool.name, cost, max_per_tool), 'error_type', 'insufficient_energy', 'energy_cost', cost);
        END IF;
        IF energy_available IS NOT NULL AND cost > energy_available THEN
            RETURN jsonb_build_object('allowed', false, 'reason', format('Insufficient energy: need %s, have %s', cost, energy_available), 'error_type', 'insufficient_energy', 'energy_cost', cost);
        END IF;
    END IF;

    boundary := tool_boundary_violation(tool.name, tool.category);
    IF boundary IS NOT NULL THEN
        RETURN jsonb_build_object('allowed', false, 'reason', 'Boundary restriction: ' || boundary, 'error_type', 'boundary_violation', 'energy_cost', cost);
    END IF;

    IF tool.requires_approval AND ctx <> 'chat' AND NOT is_tool_approved(tool.name) THEN
        RETURN jsonb_build_object('allowed', false, 'reason', format('Tool %L requires approval for autonomous use', tool.name), 'error_type', 'approval_required', 'energy_cost', cost);
    END IF;

    RETURN jsonb_build_object(
        'allowed', true,
        'energy_cost', cost,
        'supports_parallel', tool.supports_parallel,
        'execution_kind', tool.execution_kind,
        'driver', tool.driver
    );
END;
$$;

CREATE OR REPLACE FUNCTION plan_tool_batch(
    p_calls JSONB,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    call JSONB;
    idx INT := 0;
    planned JSONB := '[]'::jsonb;
    decision JSONB;
    remaining INT;
    ctx JSONB;
BEGIN
    BEGIN remaining := NULLIF(p_context->>'energy_available', '')::int;
    EXCEPTION WHEN OTHERS THEN remaining := NULL; END;

    FOR call IN SELECT * FROM jsonb_array_elements(COALESCE(p_calls, '[]'::jsonb))
    LOOP
        ctx := p_context;
        IF remaining IS NOT NULL THEN
            ctx := jsonb_set(ctx, '{energy_available}', to_jsonb(remaining), true);
        END IF;
        decision := evaluate_tool_call(call->>'name', COALESCE(call->'arguments', '{}'::jsonb), ctx);
        IF COALESCE((decision->>'allowed')::boolean, false) AND remaining IS NOT NULL THEN
            remaining := GREATEST(0, remaining - COALESCE((decision->>'energy_cost')::int, 0));
        END IF;
        planned := planned || jsonb_build_array(call || jsonb_build_object('index', idx, 'policy', decision));
        idx := idx + 1;
    END LOOP;
    RETURN jsonb_build_object('calls', planned, 'remaining_energy', remaining);
END;
$$;

CREATE OR REPLACE FUNCTION db_brain_is_cron_expression(
    p_value TEXT
) RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT array_length(regexp_split_to_array(btrim(COALESCE(p_value, '')), '\s+'), 1) IN (5, 6)
       AND NOT EXISTS (
           SELECT 1
           FROM unnest(regexp_split_to_array(btrim(COALESCE(p_value, '')), '\s+')) field
           WHERE field !~ '^[0-9*/,\-?LW#]+$'
       );
$$;

CREATE OR REPLACE FUNCTION parse_schedule_input(
    p_input JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    schedule_str TEXT := NULLIF(btrim(COALESCE(p_input->>'schedule', '')), '');
    schedule_kind TEXT := NULLIF(lower(btrim(COALESCE(p_input->>'schedule_kind', ''))), '');
    timezone_value TEXT := normalize_timezone(COALESCE(p_input->>'timezone', 'UTC'));
    parts TEXT[];
    schedule JSONB := '{}'::jsonb;
    offset_text TEXT;
    offset_value INT;
    offset_unit TEXT;
    run_at TIMESTAMPTZ;
BEGIN
    IF schedule_str IS NOT NULL THEN
        IF db_brain_is_cron_expression(schedule_str) THEN
            schedule_kind := 'cron';
            schedule := jsonb_build_object('cron', schedule_str, '_next_run', (CURRENT_TIMESTAMP + INTERVAL '1 minute')::text);
        ELSIF schedule_str LIKE '{%' THEN
            schedule := schedule_str::jsonb;
        ELSIF position(':' in schedule_str) > 0 THEN
            parts := string_to_array(schedule_str, ':');
            CASE lower(parts[1])
                WHEN 'once' THEN
                    offset_text := regexp_replace(COALESCE(parts[2], ''), '^\+', '');
                    IF offset_text !~ '^\d+[hmd]$' THEN
                        RAISE EXCEPTION 'Invalid offset format: %', offset_text;
                    END IF;
                    offset_value := left(offset_text, length(offset_text) - 1)::int;
                    offset_unit := right(offset_text, 1);
                    run_at := CURRENT_TIMESTAMP
                        + CASE offset_unit
                            WHEN 'h' THEN offset_value * INTERVAL '1 hour'
                            WHEN 'm' THEN offset_value * INTERVAL '1 minute'
                            WHEN 'd' THEN offset_value * INTERVAL '1 day'
                          END;
                    schedule_kind := 'once';
                    schedule := jsonb_build_object('run_at', run_at);
                WHEN 'daily' THEN
                    schedule_kind := 'daily';
                    schedule := jsonb_build_object('time', parts[2] || ':' || COALESCE(parts[3], '00'));
                WHEN 'weekly' THEN
                    schedule_kind := 'weekly';
                    schedule := jsonb_build_object('weekday', parts[2], 'time', parts[3] || ':' || COALESCE(parts[4], '00'));
                WHEN 'every' THEN
                    offset_text := COALESCE(parts[2], '');
                    IF offset_text !~ '^\d+[hms]$' THEN
                        RAISE EXCEPTION 'Invalid interval format: %', offset_text;
                    END IF;
                    schedule_kind := 'interval';
                    offset_value := left(offset_text, length(offset_text) - 1)::int;
                    offset_unit := right(offset_text, 1);
                    schedule := CASE offset_unit
                        WHEN 'h' THEN jsonb_build_object('every_hours', offset_value)
                        WHEN 'm' THEN jsonb_build_object('every_minutes', offset_value)
                        ELSE jsonb_build_object('every_seconds', offset_value)
                    END;
                ELSE
                    IF length(schedule_str) <= 5 THEN
                        schedule_kind := COALESCE(schedule_kind, 'daily');
                        schedule := jsonb_build_object('time', schedule_str);
                    ELSE
                        RAISE EXCEPTION 'Could not parse schedule: %', schedule_str;
                    END IF;
            END CASE;
        ELSIF length(schedule_str) <= 5 THEN
            schedule_kind := COALESCE(schedule_kind, 'daily');
            schedule := jsonb_build_object('time', schedule_str);
        ELSE
            RAISE EXCEPTION 'Could not parse schedule: %', schedule_str;
        END IF;
    END IF;

    IF schedule_kind IS NULL THEN
        RAISE EXCEPTION 'schedule_kind is required';
    END IF;

    IF schedule_kind = 'cron' THEN
        schedule := schedule || jsonb_build_object('_next_run', COALESCE(NULLIF(schedule->>'_next_run', ''), (CURRENT_TIMESTAMP + INTERVAL '1 minute')::text));
    END IF;

    IF schedule_kind = 'once' AND schedule ? '_offset' THEN
        offset_text := regexp_replace(schedule->>'_offset', '^\+', '');
        IF offset_text !~ '^\d+[hmd]$' THEN
            RAISE EXCEPTION 'Invalid offset format: %', offset_text;
        END IF;
        offset_value := left(offset_text, length(offset_text) - 1)::int;
        offset_unit := right(offset_text, 1);
        run_at := CURRENT_TIMESTAMP
            + CASE offset_unit
                WHEN 'h' THEN offset_value * INTERVAL '1 hour'
                WHEN 'm' THEN offset_value * INTERVAL '1 minute'
                WHEN 'd' THEN offset_value * INTERVAL '1 day'
              END;
        schedule := (schedule - '_offset') || jsonb_build_object('run_at', run_at);
    END IF;

    RETURN jsonb_build_object(
        'schedule_kind', schedule_kind,
        'schedule', schedule,
        'timezone', timezone_value,
        'next_run_at', compute_next_run_at(schedule_kind, schedule, timezone_value, CURRENT_TIMESTAMP)
    );
END;
$$;

CREATE OR REPLACE FUNCTION build_schedule_delivery(
    p_args JSONB
) RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE COALESCE(NULLIF(p_args->>'delivery_mode', ''), 'outbox')
        WHEN 'channel' THEN jsonb_strip_nulls(jsonb_build_object(
            'mode', 'channel',
            'channel', NULLIF(p_args->>'delivery_channel', ''),
            'target_id', NULLIF(p_args->>'delivery_target_id', ''),
            'topic', NULLIF(p_args->>'delivery_topic', '')
        ))
        WHEN 'webhook' THEN jsonb_strip_nulls(jsonb_build_object(
            'mode', 'webhook',
            'url', NULLIF(p_args->>'delivery_webhook_url', '')
        ))
        WHEN 'silent' THEN '{"mode":"silent"}'::jsonb
        ELSE '{"mode":"outbox"}'::jsonb
    END;
$$;

CREATE OR REPLACE FUNCTION manage_schedule_tool(
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    action TEXT := COALESCE(p_args->>'action', '');
    parsed JSONB;
    delivery JSONB;
    action_kind TEXT;
    action_payload JSONB := '{}'::jsonb;
    task_id UUID;
    row_data JSONB;
    tasks JSONB;
BEGIN
    IF action NOT IN ('create', 'list', 'update', 'cancel', 'stats') THEN
        RETURN jsonb_build_object('success', false, 'error', format('Invalid action %L', action), 'error_type', 'invalid_params');
    END IF;

    IF action = 'create' THEN
        IF NULLIF(btrim(COALESCE(p_args->>'name', '')), '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Name is required for create', 'error_type', 'invalid_params');
        END IF;
        action_kind := COALESCE(NULLIF(p_args->>'action_kind', ''), 'queue_user_message');
        IF action_kind = 'queue_user_message' THEN
            IF NULLIF(btrim(COALESCE(p_args->>'message', '')), '') IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'message is required for queue_user_message action_kind', 'error_type', 'invalid_params');
            END IF;
            action_payload := jsonb_build_object('message', p_args->>'message');
        ELSIF action_kind = 'create_goal' THEN
            action_payload := jsonb_build_object('title', COALESCE(NULLIF(p_args->>'goal_title', ''), p_args->>'name'), 'description', p_args->>'description');
        ELSE
            RETURN jsonb_build_object('success', false, 'error', format('Invalid action_kind %L', action_kind), 'error_type', 'invalid_params');
        END IF;
        delivery := build_schedule_delivery(p_args);
        IF delivery->>'mode' = 'channel' AND NULLIF(delivery->>'target_id', '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'delivery_target_id is required when delivery_mode is channel', 'error_type', 'invalid_params');
        END IF;
        IF delivery->>'mode' = 'webhook' AND NULLIF(delivery->>'url', '') IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'delivery_webhook_url is required when delivery_mode is webhook', 'error_type', 'invalid_params');
        END IF;
        parsed := parse_schedule_input(p_args);
        task_id := create_scheduled_task(
            p_args->>'name',
            parsed->>'schedule_kind',
            parsed->'schedule',
            action_kind,
            action_payload,
            parsed->>'timezone',
            p_args->>'description',
            'active',
            COALESCE(NULLIF(p_args->>'max_runs', '')::int, CASE WHEN parsed->>'schedule_kind' = 'once' THEN 1 ELSE NULL END),
            'agent',
            delivery
        );
        RETURN jsonb_build_object('success', true, 'output', jsonb_build_object(
            'task_id', task_id::text,
            'name', p_args->>'name',
            'schedule_kind', parsed->>'schedule_kind',
            'action_kind', action_kind,
            'delivery', delivery
        ), 'display_output', format('Created scheduled task: %s (%s)', p_args->>'name', parsed->>'schedule_kind'));
    ELSIF action = 'list' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(t)), '[]'::jsonb)
        INTO tasks
        FROM list_scheduled_tasks(NULLIF(p_args->>'status', '')) t;
        RETURN jsonb_build_object('success', true, 'output', jsonb_build_object('tasks', tasks, 'count', jsonb_array_length(tasks)), 'display_output', format('Found %s scheduled task(s)', jsonb_array_length(tasks)));
    ELSIF action = 'update' THEN
        task_id := NULLIF(p_args->>'task_id', '')::uuid;
        IF task_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'task_id is required for update', 'error_type', 'invalid_params');
        END IF;
        parsed := CASE WHEN p_args ? 'schedule' OR p_args ? 'schedule_kind' THEN parse_schedule_input(p_args) ELSE NULL END;
        delivery := CASE WHEN p_args ? 'delivery_mode' OR p_args ? 'delivery_channel' OR p_args ? 'delivery_target_id' OR p_args ? 'delivery_webhook_url' THEN build_schedule_delivery(p_args) ELSE NULL END;
        action_payload := CASE
            WHEN p_args ? 'message' THEN jsonb_build_object('message', p_args->>'message')
            WHEN p_args ? 'goal_title' THEN jsonb_build_object('title', p_args->>'goal_title')
            ELSE NULL
        END;
        row_data := update_scheduled_task(
            task_id,
            p_args->>'name',
            p_args->>'description',
            COALESCE(parsed->>'schedule_kind', p_args->>'schedule_kind'),
            parsed->'schedule',
            COALESCE(parsed->>'timezone', p_args->>'timezone'),
            p_args->>'action_kind',
            action_payload,
            p_args->>'status',
            NULLIF(p_args->>'max_runs', '')::int,
            delivery
        );
        RETURN jsonb_build_object('success', true, 'output', jsonb_build_object('task_id', task_id::text, 'updated', true, 'task', row_data), 'display_output', format('Updated scheduled task %s...', left(task_id::text, 8)));
    ELSIF action = 'cancel' THEN
        task_id := NULLIF(p_args->>'task_id', '')::uuid;
        IF task_id IS NULL AND NULLIF(p_args->>'name', '') IS NOT NULL THEN
            SELECT id INTO task_id FROM scheduled_tasks WHERE name = p_args->>'name' AND status = 'active' LIMIT 1;
        END IF;
        IF task_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'task_id or name is required for cancel', 'error_type', 'invalid_params');
        END IF;
        IF delete_scheduled_task(task_id, false, COALESCE(p_args->>'description', 'Cancelled by agent')) THEN
            RETURN jsonb_build_object('success', true, 'output', jsonb_build_object('task_id', task_id::text, 'cancelled', true), 'display_output', format('Cancelled scheduled task %s...', left(task_id::text, 8)));
        END IF;
        RETURN jsonb_build_object('success', false, 'error', format('Task %s not found', task_id), 'error_type', 'invalid_params');
    ELSE
        IF NULLIF(p_args->>'task_id', '') IS NOT NULL THEN
            SELECT to_jsonb(t) INTO row_data FROM scheduled_tasks t WHERE id = (p_args->>'task_id')::uuid;
            IF row_data IS NULL THEN
                RETURN jsonb_build_object('success', false, 'error', 'Task not found', 'error_type', 'invalid_params');
            END IF;
            RETURN jsonb_build_object('success', true, 'output', row_data);
        END IF;
        SELECT jsonb_build_object(
            'active_tasks', COUNT(*) FILTER (WHERE status = 'active'),
            'paused_tasks', COUNT(*) FILTER (WHERE status = 'paused'),
            'disabled_tasks', COUNT(*) FILTER (WHERE status = 'disabled'),
            'total_executions', COALESCE(SUM(run_count), 0),
            'tasks_with_errors', COUNT(*) FILTER (WHERE last_error IS NOT NULL AND status = 'active'),
            'last_execution', MAX(last_run_at),
            'next_execution', MIN(next_run_at) FILTER (WHERE status = 'active')
        ) INTO row_data
        FROM scheduled_tasks;
        RETURN jsonb_build_object('success', true, 'output', row_data);
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_type', 'execution_failed');
END;
$$;

CREATE OR REPLACE FUNCTION recompute_cron_next_runs(
    p_task_ids UUID[]
) RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    updated_count INT := 0;
    task_id UUID;
    schedule_value JSONB;
    next_run TIMESTAMPTZ;
BEGIN
    IF p_task_ids IS NULL OR cardinality(p_task_ids) = 0 THEN
        RETURN 0;
    END IF;
    FOREACH task_id IN ARRAY p_task_ids LOOP
        SELECT schedule INTO schedule_value FROM scheduled_tasks WHERE id = task_id AND schedule_kind = 'cron';
        IF NOT FOUND THEN
            CONTINUE;
        END IF;
        schedule_value := COALESCE(schedule_value, '{}'::jsonb)
            || jsonb_build_object('_next_run', (CURRENT_TIMESTAMP + INTERVAL '1 minute')::text);
        next_run := compute_next_run_at('cron', schedule_value, 'UTC', CURRENT_TIMESTAMP);
        UPDATE scheduled_tasks
        SET schedule = schedule_value,
            next_run_at = next_run,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = task_id;
        updated_count := updated_count + 1;
    END LOOP;
    RETURN updated_count;
END;
$$;

CREATE OR REPLACE FUNCTION create_workflow_execution(
    p_plan JSONB,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    wf_id UUID;
    step JSONB;
BEGIN
    IF NULLIF(p_plan->>'name', '') IS NULL THEN
        RAISE EXCEPTION 'Workflow name is required';
    END IF;
    IF jsonb_typeof(COALESCE(p_plan->'steps', '[]'::jsonb)) <> 'array' OR jsonb_array_length(COALESCE(p_plan->'steps', '[]'::jsonb)) = 0 THEN
        RAISE EXCEPTION 'Workflow must have at least one step';
    END IF;

    INSERT INTO workflow_executions (name, plan, status, session_id)
    VALUES (p_plan->>'name', p_plan, 'running', p_context->>'session_id')
    RETURNING id INTO wf_id;

    FOR step IN SELECT * FROM jsonb_array_elements(p_plan->'steps')
    LOOP
        INSERT INTO workflow_step_runs (
            workflow_id, step_name, tool_name, arguments, depends_on, status, max_attempts
        )
        VALUES (
            wf_id,
            step->>'name',
            step->>'tool',
            COALESCE(step->'arguments', '{}'::jsonb),
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(step->'depends_on', '[]'::jsonb))), ARRAY[]::TEXT[]),
            CASE WHEN jsonb_array_length(COALESCE(step->'depends_on', '[]'::jsonb)) = 0 THEN 'ready' ELSE 'pending' END,
            CASE WHEN COALESCE(step->>'on_error', 'stop') = 'retry' THEN GREATEST(COALESCE(NULLIF(step->>'max_retries', '')::int, 1), 1) ELSE 1 END
        )
        ON CONFLICT (workflow_id, step_name) DO NOTHING;
    END LOOP;

    RETURN jsonb_build_object('workflow_id', wf_id::text, 'status', 'running');
END;
$$;

CREATE OR REPLACE FUNCTION workflow_plan_layers(
    p_plan JSONB
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    steps JSONB := COALESCE(p_plan->'steps', '[]'::jsonb);
    step JSONB;
    step_names TEXT[] := ARRAY[]::TEXT[];
    remaining TEXT[] := ARRAY[]::TEXT[];
    satisfied TEXT[] := ARRAY[]::TEXT[];
    layers JSONB := '[]'::jsonb;
    layer JSONB;
    name_value TEXT;
    dep TEXT;
    deps TEXT[];
    progress BOOLEAN;
BEGIN
    IF jsonb_typeof(steps) <> 'array' OR jsonb_array_length(steps) = 0 THEN
        RAISE EXCEPTION 'Workflow must have at least one step';
    END IF;

    FOR step IN SELECT * FROM jsonb_array_elements(steps)
    LOOP
        name_value := step->>'name';
        IF NULLIF(name_value, '') IS NULL THEN
            RAISE EXCEPTION 'Workflow step name is required';
        END IF;
        IF name_value = ANY(step_names) THEN
            RAISE EXCEPTION 'Workflow step names must be unique';
        END IF;
        step_names := step_names || name_value;
        remaining := remaining || name_value;
    END LOOP;

    FOR step IN SELECT * FROM jsonb_array_elements(steps)
    LOOP
        FOR dep IN SELECT * FROM jsonb_array_elements_text(COALESCE(step->'depends_on', '[]'::jsonb))
        LOOP
            IF NOT dep = ANY(step_names) THEN
                RAISE EXCEPTION 'Step % depends on unknown step %', step->>'name', dep;
            END IF;
        END LOOP;
    END LOOP;

    WHILE cardinality(remaining) > 0 LOOP
        layer := '[]'::jsonb;
        progress := FALSE;
        FOREACH name_value IN ARRAY remaining LOOP
            SELECT COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(s->'depends_on', '[]'::jsonb))), ARRAY[]::TEXT[])
            INTO deps
            FROM jsonb_array_elements(steps) s
            WHERE s->>'name' = name_value;

            IF NOT EXISTS (SELECT 1 FROM unnest(deps) d WHERE NOT d = ANY(satisfied)) THEN
                SELECT layer || jsonb_build_array(s)
                INTO layer
                FROM jsonb_array_elements(steps) s
                WHERE s->>'name' = name_value;
                progress := TRUE;
            END IF;
        END LOOP;

        IF NOT progress THEN
            RAISE EXCEPTION 'Circular dependency detected among steps: %', remaining;
        END IF;

        layers := layers || jsonb_build_array(layer);
        SELECT COALESCE(ARRAY(
            SELECT r
            FROM unnest(remaining) r
            WHERE NOT EXISTS (
                SELECT 1
                FROM jsonb_array_elements(layer) l
                WHERE l->>'name' = r
            )
        ), ARRAY[]::TEXT[]) INTO remaining;
        SELECT COALESCE(ARRAY(
            SELECT DISTINCT value
            FROM unnest(satisfied || ARRAY(
                SELECT l->>'name'
                FROM jsonb_array_elements(layer) l
            )) v(value)
        ), ARRAY[]::TEXT[]) INTO satisfied;
    END LOOP;

    RETURN layers;
END;
$$;

CREATE OR REPLACE FUNCTION resolve_workflow_templates(
    p_value JSONB,
    p_step_outputs JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    key TEXT;
    value JSONB;
    out_obj JSONB := '{}'::jsonb;
    out_arr JSONB := '[]'::jsonb;
    text_value TEXT;
    match TEXT[];
    replacement JSONB;
    replacement_text TEXT;
BEGIN
    IF p_value IS NULL THEN
        RETURN 'null'::jsonb;
    END IF;

    IF jsonb_typeof(p_value) = 'object' THEN
        FOR key, value IN SELECT * FROM jsonb_each(p_value)
        LOOP
            out_obj := out_obj || jsonb_build_object(key, resolve_workflow_templates(value, p_step_outputs));
        END LOOP;
        RETURN out_obj;
    ELSIF jsonb_typeof(p_value) = 'array' THEN
        FOR value IN SELECT * FROM jsonb_array_elements(p_value)
        LOOP
            out_arr := out_arr || jsonb_build_array(resolve_workflow_templates(value, p_step_outputs));
        END LOOP;
        RETURN out_arr;
    ELSIF jsonb_typeof(p_value) <> 'string' THEN
        RETURN p_value;
    END IF;

    text_value := p_value #>> '{}';
    match := regexp_match(text_value, '^\{\{([A-Za-z0-9_]+)\.output(?:\.([A-Za-z0-9_]+))?\}\}$');
    IF match IS NOT NULL THEN
        replacement := p_step_outputs -> match[1];
        IF match[2] IS NOT NULL AND jsonb_typeof(replacement) = 'object' THEN
            replacement := replacement -> match[2];
        END IF;
        RETURN COALESCE(replacement, p_value);
    END IF;

    FOR match IN SELECT regexp_matches(text_value, '\{\{([A-Za-z0-9_]+)\.output(?:\.([A-Za-z0-9_]+))?\}\}', 'g')
    LOOP
        replacement := p_step_outputs -> match[1];
        IF match[2] IS NOT NULL AND jsonb_typeof(replacement) = 'object' THEN
            replacement := replacement -> match[2];
        END IF;
        replacement_text := COALESCE(replacement #>> '{}', '{{' || match[1] || '.output' || CASE WHEN match[2] IS NULL THEN '' ELSE '.' || match[2] END || '}}');
        text_value := replace(
            text_value,
            '{{' || match[1] || '.output' || CASE WHEN match[2] IS NULL THEN '' ELSE '.' || match[2] END || '}}',
            replacement_text
        );
    END LOOP;

    RETURN to_jsonb(text_value);
END;
$$;

CREATE OR REPLACE FUNCTION claim_workflow_steps(
    p_workflow_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    claimed JSONB;
BEGIN
    WITH ready AS (
        SELECT s.id
        FROM workflow_step_runs s
        WHERE s.workflow_id = p_workflow_id
          AND s.status IN ('ready', 'pending')
          AND NOT EXISTS (
              SELECT 1
              FROM unnest(s.depends_on) dep(step_name)
              JOIN workflow_step_runs d ON d.workflow_id = s.workflow_id AND d.step_name = dep.step_name
              WHERE d.status <> 'completed'
          )
        ORDER BY s.created_at
        FOR UPDATE SKIP LOCKED
    ),
    updated AS (
        UPDATE workflow_step_runs s
        SET status = 'in_progress',
            attempts = attempts + 1,
            started_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        FROM ready
        WHERE s.id = ready.id
        RETURNING s.*
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(updated)), '[]'::jsonb) INTO claimed
    FROM updated;

    RETURN claimed;
END;
$$;

CREATE OR REPLACE FUNCTION apply_workflow_step_result(
    p_step_id UUID,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out workflow_step_runs%ROWTYPE;
BEGIN
    UPDATE workflow_step_runs
    SET status = CASE WHEN COALESCE((p_result->>'success')::boolean, false) THEN 'completed' ELSE 'failed' END,
        output = COALESCE(p_result->'output', p_result),
        error = p_result->>'error',
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_step_id
    RETURNING * INTO row_out;

    RETURN to_jsonb(row_out);
END;
$$;

CREATE OR REPLACE FUNCTION finalize_workflow_execution(
    p_workflow_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    status_value TEXT;
    steps JSONB;
    total_energy INT;
    error_value TEXT;
BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.created_at), '[]'::jsonb),
           COALESCE(SUM(COALESCE((s.output->>'energy_spent')::int, 0)), 0),
           CASE WHEN COUNT(*) FILTER (WHERE s.status = 'failed') > 0 THEN 'failed' ELSE 'completed' END,
           MIN(s.error) FILTER (WHERE s.status = 'failed')
    INTO steps, total_energy, status_value, error_value
    FROM workflow_step_runs s
    WHERE s.workflow_id = p_workflow_id;

    UPDATE workflow_executions
    SET status = status_value,
        step_results = steps,
        total_energy_spent = total_energy,
        error = error_value,
        completed_at = CURRENT_TIMESTAMP
    WHERE id = p_workflow_id;

    RETURN jsonb_build_object('workflow_id', p_workflow_id::text, 'status', status_value, 'steps', steps, 'total_energy_spent', total_energy, 'error', error_value);
END;
$$;
-- ===== END INLINE: db/36_functions_tool_runtime.sql =====


-- ===== BEGIN INLINE: db/37_functions_agent_runtime.sql =====
-- DB-owned agent-loop state and external-call dispatch helpers.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION record_agent_turn_event(
    p_turn_id UUID,
    p_event_type TEXT,
    p_payload JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    event_id UUID;
BEGIN
    INSERT INTO agent_turn_events (turn_id, event_type, payload)
    VALUES (p_turn_id, p_event_type, COALESCE(p_payload, '{}'::jsonb))
    RETURNING id INTO event_id;
    RETURN jsonb_build_object('event_id', event_id::text);
END;
$$;

CREATE OR REPLACE FUNCTION start_agent_turn(
    p_mode TEXT,
    p_user_message TEXT,
    p_session_id UUID DEFAULT NULL,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    turn_id UUID;
    initial_messages JSONB;
    runtime JSONB;
BEGIN
    initial_messages := COALESCE(p_context->'messages', '[]'::jsonb);
    runtime := jsonb_build_object(
        'iterations', 0,
        'energy_spent', 0,
        'energy_budget', p_context->'energy_budget',
        'max_iterations', p_context->'max_iterations',
        'continuations_used', 0,
        'max_continuations', COALESCE(NULLIF(p_context->>'max_continuations', '')::int, 0),
        'last_text', '',
        'tool_calls_made', '[]'::jsonb,
        'phases_completed', '[]'::jsonb
    ) || COALESCE(p_context->'runtime_state', '{}'::jsonb);

    INSERT INTO agent_turns (
        mode, session_id, heartbeat_id, user_message, messages, runtime_state, phase, status
    )
    VALUES (
        COALESCE(NULLIF(p_mode, ''), 'chat'),
        p_session_id,
        _db_brain_try_uuid(p_context->>'heartbeat_id'),
        p_user_message,
        initial_messages,
        runtime,
        COALESCE(NULLIF(p_context->>'phase', ''), 'execute'),
        'running'
    )
    RETURNING id INTO turn_id;

    PERFORM record_agent_turn_event(turn_id, 'loop_start', p_context);
    RETURN jsonb_build_object('turn_id', turn_id::text, 'status', 'running', 'runtime_state', runtime);
END;
$$;

CREATE OR REPLACE FUNCTION next_agent_step(
    p_turn_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    turn agent_turns%ROWTYPE;
    iterations INT;
    max_iterations INT;
    energy_spent INT;
    energy_budget INT;
BEGIN
    SELECT * INTO turn FROM agent_turns WHERE id = p_turn_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'agent turn not found: %', p_turn_id;
    END IF;
    IF turn.status <> 'running' THEN
        RETURN jsonb_build_object('action', 'done', 'status', turn.status, 'reason', turn.stopped_reason);
    END IF;

    iterations := COALESCE(NULLIF(turn.runtime_state->>'iterations', '')::int, 0);
    BEGIN max_iterations := NULLIF(turn.runtime_state->>'max_iterations', '')::int;
    EXCEPTION WHEN OTHERS THEN max_iterations := NULL; END;
    energy_spent := COALESCE(NULLIF(turn.runtime_state->>'energy_spent', '')::int, 0);
    BEGIN energy_budget := NULLIF(turn.runtime_state->>'energy_budget', '')::int;
    EXCEPTION WHEN OTHERS THEN energy_budget := NULL; END;

    IF max_iterations IS NOT NULL AND iterations >= max_iterations THEN
        UPDATE agent_turns
        SET stopped_reason = 'max_iterations',
            runtime_state = jsonb_set(runtime_state, '{stop_decision}', '"max_iterations"', true),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_turn_id;
        RETURN jsonb_build_object('action', 'stop', 'reason', 'max_iterations', 'iterations', iterations, 'energy_spent', energy_spent);
    END IF;
    IF energy_budget IS NOT NULL AND energy_spent >= energy_budget THEN
        PERFORM record_agent_turn_event(p_turn_id, 'energy_exhausted', jsonb_build_object('budget', energy_budget, 'spent', energy_spent));
        UPDATE agent_turns
        SET stopped_reason = 'energy',
            runtime_state = jsonb_set(runtime_state, '{stop_decision}', '"energy"', true),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = p_turn_id;
        RETURN jsonb_build_object('action', 'stop', 'reason', 'energy', 'iterations', iterations, 'energy_spent', energy_spent);
    END IF;

    RETURN jsonb_build_object('action', 'llm', 'iteration', iterations + 1, 'energy_spent', energy_spent);
END;
$$;

CREATE OR REPLACE FUNCTION apply_agent_llm_result(
    p_turn_id UUID,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    turn agent_turns%ROWTYPE;
    content TEXT := COALESCE(p_result->>'content', '');
    tool_calls JSONB := COALESCE(p_result->'tool_calls', '[]'::jsonb);
    iterations INT;
    message JSONB;
    runtime JSONB;
BEGIN
    SELECT * INTO turn FROM agent_turns WHERE id = p_turn_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'agent turn not found: %', p_turn_id;
    END IF;
    iterations := COALESCE(NULLIF(turn.runtime_state->>'iterations', '')::int, 0) + 1;
    message := jsonb_build_object('role', 'assistant', 'content', content);
    IF jsonb_typeof(tool_calls) = 'array' AND jsonb_array_length(tool_calls) > 0 THEN
        message := message || jsonb_build_object('tool_calls', tool_calls);
    END IF;
    runtime := jsonb_set(turn.runtime_state, '{iterations}', to_jsonb(iterations), true);
    runtime := jsonb_set(runtime, '{last_text}', to_jsonb(content), true);
    runtime := jsonb_set(runtime, '{last_tool_calls}', tool_calls, true);

    UPDATE agent_turns
    SET messages = COALESCE(messages, '[]'::jsonb) || jsonb_build_array(message),
        runtime_state = runtime,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_turn_id;
    PERFORM record_agent_turn_event(p_turn_id, 'llm_result', p_result || jsonb_build_object('iteration', iterations));

    RETURN jsonb_build_object('turn_id', p_turn_id::text, 'iterations', iterations, 'tool_call_count', COALESCE(jsonb_array_length(tool_calls), 0));
END;
$$;

CREATE OR REPLACE FUNCTION apply_agent_tool_result(
    p_turn_id UUID,
    p_tool_call_id TEXT,
    p_result JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    turn agent_turns%ROWTYPE;
    spent INT := COALESCE(NULLIF(p_result->>'energy_spent', '')::int, 0);
    total_spent INT;
    call_record JSONB;
    runtime JSONB;
BEGIN
    SELECT * INTO turn FROM agent_turns WHERE id = p_turn_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'agent turn not found: %', p_turn_id;
    END IF;
    total_spent := COALESCE(NULLIF(turn.runtime_state->>'energy_spent', '')::int, 0) + spent;
    call_record := jsonb_build_object(
        'id', p_tool_call_id,
        'name', p_result->>'tool_name',
        'success', COALESCE((p_result->>'success')::boolean, false),
        'energy_spent', spent,
        'error', p_result->>'error'
    );
    runtime := jsonb_set(turn.runtime_state, '{energy_spent}', to_jsonb(total_spent), true);
    runtime := jsonb_set(runtime, '{tool_calls_made}', COALESCE(turn.runtime_state->'tool_calls_made', '[]'::jsonb) || jsonb_build_array(call_record), true);

    UPDATE agent_turns
    SET messages = COALESCE(messages, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
            'role', 'tool',
            'tool_call_id', p_tool_call_id,
            'content', COALESCE(p_result->>'model_output', p_result->>'display_output', p_result->>'error', '')
        )),
        runtime_state = runtime,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_turn_id;
    PERFORM record_agent_turn_event(p_turn_id, 'tool_result', p_result || jsonb_build_object('total_energy_spent', total_spent));

    RETURN jsonb_build_object('turn_id', p_turn_id::text, 'energy_spent', total_spent);
END;
$$;

CREATE OR REPLACE FUNCTION finish_agent_turn(
    p_turn_id UUID,
    p_result JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_out agent_turns%ROWTYPE;
BEGIN
    UPDATE agent_turns
    SET status = COALESCE(NULLIF(p_result->>'status', ''), 'completed'),
        stopped_reason = COALESCE(NULLIF(p_result->>'stopped_reason', ''), stopped_reason, 'completed'),
        result = COALESCE(p_result, '{}'::jsonb),
        completed_at = CURRENT_TIMESTAMP,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_turn_id
    RETURNING * INTO row_out;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'agent turn not found: %', p_turn_id;
    END IF;
    PERFORM record_agent_turn_event(p_turn_id, 'loop_end', p_result);
    RETURN to_jsonb(row_out);
END;
$$;

CREATE OR REPLACE FUNCTION resolve_external_call_kind(
    p_call JSONB
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    call_type TEXT := COALESCE(NULLIF(p_call->>'call_type', ''), NULLIF(p_call->>'type', ''));
    input JSONB := COALESCE(p_call->'input', p_call);
    think_kind TEXT;
BEGIN
    IF call_type = 'tool_use' OR input ? 'tool_name' OR input ? 'name' THEN
        RETURN jsonb_build_object('call_type', 'tool_use', 'kind', 'tool_use', 'input', input);
    END IF;
    IF call_type = 'embed' THEN
        RETURN jsonb_build_object('call_type', 'embed', 'kind', 'embed', 'input', input, 'supported', false);
    END IF;
    think_kind := COALESCE(NULLIF(input->>'kind', ''), 'heartbeat_decision');
    RETURN jsonb_build_object('call_type', 'think', 'kind', think_kind, 'input', input, 'supported', think_kind IN (
        'heartbeat_decision_rlm',
        'heartbeat_decision',
        'brainstorm_goals',
        'inquire',
        'reflect',
        'termination_confirm',
        'consent_request'
    ));
END;
$$;

CREATE OR REPLACE FUNCTION apply_think_result(
    p_call JSONB,
    p_result JSONB
) RETURNS JSONB
LANGUAGE sql
AS $$
    SELECT apply_external_call_result(p_call, p_result);
$$;

CREATE OR REPLACE FUNCTION apply_tool_use_result(
    p_call JSONB,
    p_result JSONB
) RETURNS JSONB
LANGUAGE sql
AS $$
    SELECT apply_external_call_result(p_call, p_result);
$$;
-- ===== END INLINE: db/37_functions_agent_runtime.sql =====


-- ===== BEGIN INLINE: db/38_functions_db_native_tools.sql =====
-- DB-native tool execution helpers for tools that do not need Python side effects.
SET search_path = public, ag_catalog, "$user";

CREATE OR REPLACE FUNCTION tool_success(
    p_output JSONB,
    p_display_output TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object('success', true, 'output', COALESCE(p_output, '{}'::jsonb), 'display_output', p_display_output);
$$;

CREATE OR REPLACE FUNCTION tool_error(
    p_error TEXT,
    p_error_type TEXT DEFAULT 'execution_failed'
) RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object('success', false, 'error', COALESCE(p_error, 'Tool failed'), 'error_type', COALESCE(p_error_type, 'execution_failed'));
$$;

CREATE OR REPLACE FUNCTION execute_goals_tool(
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    action TEXT := COALESCE(p_args->>'action', '');
    title TEXT;
    goal_id UUID;
    priority TEXT;
    source_value TEXT;
    snapshot JSONB;
    rows_json JSONB;
BEGIN
    IF action NOT IN ('create', 'update_priority', 'add_progress', 'list') THEN
        RETURN tool_error(format('Invalid action %L', action), 'invalid_params');
    END IF;
    IF action = 'create' THEN
        title := NULLIF(btrim(COALESCE(p_args->>'title', '')), '');
        IF title IS NULL THEN
            RETURN tool_error('Title is required for create', 'invalid_params');
        END IF;
        priority := COALESCE(NULLIF(p_args->>'priority', ''), 'queued');
        IF priority NOT IN ('active', 'queued', 'backburner', 'completed', 'abandoned') THEN
            priority := 'queued';
        END IF;
        source_value := COALESCE(NULLIF(p_args->>'source', ''), 'curiosity');
        IF source_value NOT IN ('curiosity', 'user_request', 'identity', 'derived', 'external') THEN
            source_value := 'curiosity';
        END IF;
        goal_id := create_goal(title, p_args->>'description', source_value::goal_source, priority::goal_priority);
        RETURN tool_success(
            jsonb_build_object('goal_id', goal_id::text, 'title', title, 'priority', priority),
            format('Created goal: %s (%s)', title, priority)
        );
    ELSIF action = 'update_priority' THEN
        goal_id := NULLIF(p_args->>'goal_id', '')::uuid;
        priority := COALESCE(p_args->>'priority', '');
        IF goal_id IS NULL THEN
            RETURN tool_error('goal_id is required for update_priority', 'invalid_params');
        END IF;
        IF priority NOT IN ('active', 'queued', 'backburner', 'completed', 'abandoned') THEN
            RETURN tool_error(format('Invalid priority %L', priority), 'invalid_params');
        END IF;
        PERFORM change_goal_priority(goal_id, priority::goal_priority, COALESCE(p_args->>'reason', ''));
        RETURN tool_success(jsonb_build_object('goal_id', goal_id::text, 'new_priority', priority, 'reason', COALESCE(p_args->>'reason', '')), format('Updated goal %s... to %s', left(goal_id::text, 8), priority));
    ELSIF action = 'add_progress' THEN
        goal_id := NULLIF(p_args->>'goal_id', '')::uuid;
        IF goal_id IS NULL THEN
            RETURN tool_error('goal_id is required for add_progress', 'invalid_params');
        END IF;
        IF NULLIF(btrim(COALESCE(p_args->>'note', '')), '') IS NULL THEN
            RETURN tool_error('note is required for add_progress', 'invalid_params');
        END IF;
        PERFORM add_goal_progress(goal_id, p_args->>'note');
        RETURN tool_success(jsonb_build_object('goal_id', goal_id::text, 'note', p_args->>'note'), format('Added progress to goal %s...', left(goal_id::text, 8)));
    ELSE
        priority := NULLIF(p_args->>'priority', '');
        IF priority IS NOT NULL AND priority IN ('active', 'queued', 'backburner', 'completed', 'abandoned') THEN
            SELECT COALESCE(jsonb_agg(to_jsonb(g)), '[]'::jsonb) INTO rows_json
            FROM get_goals_by_priority(priority::goal_priority) g;
            RETURN tool_success(jsonb_build_object('goals', rows_json, 'count', jsonb_array_length(rows_json)));
        END IF;
        snapshot := get_goals_snapshot();
        RETURN tool_success(COALESCE(snapshot, '{}'::jsonb));
    END IF;
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION record_backlog_user_change(
    p_action TEXT,
    p_title TEXT,
    p_item_id UUID
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO memories (type, content, embedding, importance, trust_level, metadata)
    VALUES (
        'episodic',
        format('User %s backlog item: %s', p_action, p_title),
        array_fill(0.1, ARRAY[embedding_dimension()])::vector,
        0.6,
        1.0,
        jsonb_build_object('backlog_item_id', p_item_id::text, 'action', p_action, 'source', 'user_backlog_change')
    );
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

CREATE OR REPLACE FUNCTION execute_backlog_tool(
    p_args JSONB,
    p_context JSONB DEFAULT '{}'::jsonb
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    action TEXT := COALESCE(p_args->>'action', '');
    item_id UUID;
    row_data backlog%ROWTYPE;
    rows_json JSONB;
    fields JSONB := '{}'::jsonb;
    is_user BOOLEAN := COALESCE(p_context->>'tool_context', 'chat') IN ('chat', 'mcp');
BEGIN
    IF action NOT IN ('create', 'update', 'delete', 'list', 'get', 'set_status', 'set_checkpoint') THEN
        RETURN tool_error(format('Invalid action %L', action), 'invalid_params');
    END IF;
    IF action = 'create' THEN
        IF NULLIF(btrim(COALESCE(p_args->>'title', '')), '') IS NULL THEN
            RETURN tool_error('Title is required for create', 'invalid_params');
        END IF;
        SELECT * INTO row_data
        FROM create_backlog_item(
            p_args->>'title',
            COALESCE(p_args->>'description', ''),
            CASE WHEN p_args->>'priority' IN ('urgent', 'high', 'normal', 'low') THEN p_args->>'priority' ELSE 'normal' END,
            CASE WHEN p_args->>'owner' IN ('agent', 'user', 'shared') THEN p_args->>'owner' ELSE 'agent' END,
            CASE WHEN is_user THEN 'user' ELSE 'agent' END,
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_args->'tags', '[]'::jsonb))), ARRAY[]::TEXT[]),
            NULLIF(p_args->>'parent_id', '')::uuid
        );
        IF is_user THEN
            PERFORM record_backlog_user_change('created', row_data.title, row_data.id);
        END IF;
        RETURN tool_success(jsonb_build_object('item_id', row_data.id::text, 'title', row_data.title, 'priority', row_data.priority, 'owner', row_data.owner, 'created_by', row_data.created_by), format('Created backlog item: %s (%s)', row_data.title, row_data.priority));
    ELSIF action = 'list' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(b)), '[]'::jsonb)
        INTO rows_json
        FROM list_backlog(
            CASE WHEN p_args->>'status_filter' IN ('todo', 'in_progress', 'done', 'blocked', 'cancelled') THEN p_args->>'status_filter' ELSE NULL END,
            CASE WHEN p_args->>'priority_filter' IN ('urgent', 'high', 'normal', 'low') THEN p_args->>'priority_filter' ELSE NULL END,
            CASE WHEN p_args->>'owner_filter' IN ('agent', 'user', 'shared') THEN p_args->>'owner_filter' ELSE NULL END
        ) b;
        RETURN tool_success(jsonb_build_object('items', rows_json, 'count', jsonb_array_length(rows_json)));
    END IF;

    item_id := NULLIF(p_args->>'item_id', '')::uuid;
    IF item_id IS NULL THEN
        RETURN tool_error(format('item_id is required for %s', action), 'invalid_params');
    END IF;

    IF action = 'get' THEN
        SELECT * INTO row_data FROM get_backlog_item(item_id);
        IF row_data.id IS NULL THEN
            RETURN tool_error(format('Backlog item %s not found', item_id), 'execution_failed');
        END IF;
        RETURN tool_success(to_jsonb(row_data));
    ELSIF action = 'delete' THEN
        SELECT * INTO row_data FROM get_backlog_item(item_id);
        IF NOT delete_backlog_item(item_id) THEN
            RETURN tool_error(format('Backlog item %s not found', item_id), 'execution_failed');
        END IF;
        IF is_user AND row_data.title IS NOT NULL THEN
            PERFORM record_backlog_user_change('deleted', row_data.title, item_id);
        END IF;
        RETURN tool_success(jsonb_build_object('item_id', item_id::text, 'deleted', true), format('Deleted backlog item %s...', left(item_id::text, 8)));
    ELSIF action = 'set_status' THEN
        IF p_args->>'status' NOT IN ('todo', 'in_progress', 'done', 'blocked', 'cancelled') THEN
            RETURN tool_error(format('Invalid status %L', p_args->>'status'), 'invalid_params');
        END IF;
        fields := jsonb_build_object('status', p_args->>'status');
    ELSIF action = 'set_checkpoint' THEN
        IF NOT p_args ? 'checkpoint' THEN
            RETURN tool_error('checkpoint data is required for set_checkpoint', 'invalid_params');
        END IF;
        fields := jsonb_build_object('checkpoint', p_args->'checkpoint');
    ELSE
        FOR fields IN SELECT jsonb_object_agg(key, value)
        FROM jsonb_each(p_args)
        WHERE key IN ('title', 'description', 'priority', 'owner', 'status', 'tags')
        LOOP
            fields := COALESCE(fields, '{}'::jsonb);
        END LOOP;
        IF fields = '{}'::jsonb THEN
            RETURN tool_error('No fields to update. Provide at least one of: title, description, priority, owner, status, tags.', 'invalid_params');
        END IF;
    END IF;

    SELECT * INTO row_data FROM update_backlog_item(item_id, fields);
    IF row_data.id IS NULL THEN
        RETURN tool_error(format('Backlog item %s not found', item_id), 'execution_failed');
    END IF;
    IF is_user THEN
        PERFORM record_backlog_user_change(CASE WHEN action = 'set_status' THEN format('changed status to %L on', p_args->>'status') ELSE 'updated' END, row_data.title, item_id);
    END IF;
    RETURN tool_success(
        CASE action
            WHEN 'set_status' THEN jsonb_build_object('item_id', row_data.id::text, 'title', row_data.title, 'new_status', row_data.status)
            WHEN 'set_checkpoint' THEN jsonb_build_object('item_id', row_data.id::text, 'title', row_data.title, 'checkpoint_saved', true)
            ELSE jsonb_build_object('item_id', row_data.id::text, 'title', row_data.title, 'status', row_data.status, 'priority', row_data.priority, 'owner', row_data.owner)
        END,
        CASE action
            WHEN 'set_status' THEN format('Set %s to %s', row_data.title, row_data.status)
            WHEN 'set_checkpoint' THEN format('Saved checkpoint for %s', row_data.title)
            ELSE format('Updated backlog item %s...', left(item_id::text, 8))
        END
    );
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION contact_row_json(c contacts)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
        'id', c.id,
        'name', c.name,
        'email', c.email,
        'company', c.company,
        'role', c.role,
        'phone', c.phone,
        'notes', c.notes,
        'tags', to_jsonb(c.tags),
        'source', c.source,
        'first_seen', c.first_seen,
        'last_touch', c.last_touch
    );
$$;

CREATE OR REPLACE FUNCTION execute_contact_tool(
    p_tool_name TEXT,
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    row_data contacts%ROWTYPE;
    rows_json JSONB;
    contact_id BIGINT;
    keep_id BIGINT;
    remove_id BIGINT;
    query TEXT;
    limit_value INT;
    updated BOOLEAN;
BEGIN
    limit_value := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 20), 1), 100);
    IF p_tool_name = 'search_contacts' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'query', '')), '');
        IF query IS NULL THEN
            SELECT COALESCE(jsonb_agg(contact_row_json(c)), '[]'::jsonb) INTO rows_json FROM recent_contacts(limit_value) c;
        ELSE
            SELECT COALESCE(jsonb_agg(contact_row_json(c)), '[]'::jsonb) INTO rows_json FROM search_contacts(query, limit_value) c;
        END IF;
        RETURN tool_success(jsonb_build_object('count', jsonb_array_length(rows_json), 'contacts', rows_json), format('Found %s contact(s)', jsonb_array_length(rows_json)));
    ELSIF p_tool_name = 'get_contact' THEN
        IF p_args ? 'id' THEN
            SELECT * INTO row_data FROM contacts WHERE id = (p_args->>'id')::bigint;
        ELSIF NULLIF(p_args->>'email', '') IS NOT NULL THEN
            SELECT * INTO row_data FROM get_contact_by_email(p_args->>'email');
        ELSE
            RETURN tool_error('Provide either id or email.', 'invalid_params');
        END IF;
        IF row_data.id IS NULL THEN
            RETURN tool_success('{"found": false}'::jsonb);
        END IF;
        RETURN tool_success(jsonb_build_object('found', true, 'contact', contact_row_json(row_data)));
    ELSIF p_tool_name = 'create_contact' THEN
        IF NULLIF(btrim(COALESCE(p_args->>'name', '')), '') IS NULL THEN
            RETURN tool_error('Name is required.', 'invalid_params');
        END IF;
        contact_id := create_contact(
            p_args->>'name',
            p_args->>'email',
            p_args->>'company',
            p_args->>'role',
            p_args->>'phone',
            p_args->>'notes',
            COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_args->'tags', '[]'::jsonb))), ARRAY[]::TEXT[]),
            COALESCE(NULLIF(p_args->>'source', ''), 'manual')
        );
        RETURN tool_success(jsonb_build_object('id', contact_id, 'name', p_args->>'name'), format('Created contact #%s: %s', contact_id, p_args->>'name'));
    ELSIF p_tool_name = 'update_contact' THEN
        contact_id := NULLIF(p_args->>'id', '')::bigint;
        IF contact_id IS NULL THEN
            RETURN tool_error('Contact ID is required.', 'invalid_params');
        END IF;
        updated := update_contact(
            contact_id,
            p_args->>'name',
            p_args->>'email',
            p_args->>'company',
            p_args->>'role',
            p_args->>'phone',
            p_args->>'notes',
            CASE WHEN p_args ? 'tags' THEN ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_args->'tags', '[]'::jsonb))) ELSE NULL END
        );
        IF NOT updated THEN
            RETURN tool_error(format('Contact #%s not found.', contact_id), 'execution_failed');
        END IF;
        PERFORM touch_contact(contact_id);
        RETURN tool_success(jsonb_build_object('id', contact_id, 'updated', true), format('Updated contact #%s', contact_id));
    ELSIF p_tool_name = 'merge_contacts' THEN
        keep_id := NULLIF(p_args->>'keep_id', '')::bigint;
        remove_id := NULLIF(p_args->>'remove_id', '')::bigint;
        IF keep_id IS NULL OR remove_id IS NULL THEN
            RETURN tool_error('Both keep_id and remove_id are required.', 'invalid_params');
        END IF;
        IF keep_id = remove_id THEN
            RETURN tool_error('Cannot merge a contact with itself.', 'invalid_params');
        END IF;
        IF NOT merge_contacts(keep_id, remove_id) THEN
            RETURN tool_error(format('Contact #%s not found.', remove_id), 'execution_failed');
        END IF;
        RETURN tool_success(jsonb_build_object('keep_id', keep_id, 'removed_id', remove_id, 'merged', true), format('Merged contact #%s into #%s', remove_id, keep_id));
    END IF;
    RETURN tool_error(format('Unsupported contact tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;

CREATE OR REPLACE FUNCTION execute_memory_tool(
    p_tool_name TEXT,
    p_args JSONB
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    content TEXT;
    memory_type_value TEXT;
    importance_value FLOAT;
    memory_id UUID;
    query TEXT;
    limit_value INT;
    rows_json JSONB;
    type_filter memory_type[];
BEGIN
    IF p_tool_name = 'remember' THEN
        content := NULLIF(btrim(COALESCE(p_args->>'content', '')), '');
        IF content IS NULL THEN
            RETURN tool_error('content is required', 'invalid_params');
        END IF;
        memory_type_value := COALESCE(NULLIF(p_args->>'type', ''), 'episodic');
        IF memory_type_value NOT IN ('episodic', 'semantic', 'procedural', 'strategic') THEN
            RETURN tool_error(format('Invalid memory type: %s', memory_type_value), 'invalid_params');
        END IF;
        importance_value := LEAST(1.0, GREATEST(0.0, COALESCE(NULLIF(p_args->>'importance', '')::float, 0.5)));
        memory_id := create_memory(memory_type_value::memory_type, content, importance_value);
        IF jsonb_typeof(COALESCE(p_args->'concepts', '[]'::jsonb)) = 'array' THEN
            PERFORM link_memory_to_concept(memory_id, value)
            FROM jsonb_array_elements_text(p_args->'concepts') c(value);
        END IF;
        RETURN tool_success(jsonb_build_object('memory_id', memory_id::text, 'content', left(content, 100)), format('Stored memory: %s...', left(content, 50)));
    ELSIF p_tool_name = 'sense_memory_availability' THEN
        query := NULLIF(btrim(COALESCE(p_args->>'query', '')), '');
        IF query IS NULL THEN
            RETURN tool_error('query is required', 'invalid_params');
        END IF;
        SELECT to_jsonb(s) INTO rows_json FROM sense_memory_availability(query) s;
        RETURN tool_success(COALESCE(rows_json, '{"has_memories": false, "activation_strength": 0.0}'::jsonb), format('Memory availability: %s', COALESCE(rows_json->>'activation_strength', '0.0')));
    ELSIF p_tool_name = 'recall' THEN
        query := NULLIF(p_args->>'query', '');
        limit_value := LEAST(GREATEST(COALESCE(NULLIF(p_args->>'limit', '')::int, 5), 1), 50);
        IF p_args ? 'memory_types' THEN
            SELECT ARRAY(SELECT value::memory_type FROM jsonb_array_elements_text(p_args->'memory_types') t(value)) INTO type_filter;
        END IF;
        IF query IS NULL AND NOT (p_args ? 'memory_types' OR p_args ? 'source_path' OR p_args ? 'source_kind' OR p_args ? 'created_after' OR p_args ? 'created_before' OR p_args ? 'concept') THEN
            RETURN tool_error('Provide at least a query or one filter (memory_types, source_path, source_kind, created_after, created_before, concept).', 'invalid_params');
        END IF;
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'memory_id', r.memory_id::text,
            'content', r.content,
            'type', r.memory_type::text,
            'score', r.score,
            'importance', r.importance,
            'source_attribution', r.source_attribution
        )), '[]'::jsonb)
        INTO rows_json
        FROM recall_memories_structured(
            query,
            limit_value,
            type_filter,
            COALESCE(NULLIF(p_args->>'min_importance', '')::float, 0.0),
            p_args->>'source_path',
            p_args->>'source_kind',
            NULLIF(p_args->>'created_after', '')::timestamptz,
            NULLIF(p_args->>'created_before', '')::timestamptz,
            p_args->>'concept',
            NULL
        ) r;
        PERFORM touch_memories(ARRAY(SELECT (value->>'memory_id')::uuid FROM jsonb_array_elements(rows_json) value));
        RETURN tool_success(jsonb_build_object('memories', rows_json, 'count', jsonb_array_length(rows_json), 'query', COALESCE(query, '(filters only)')), format('Found %s memories for %L', jsonb_array_length(rows_json), COALESCE(query, '(filters only)')));
    END IF;
    RETURN tool_error(format('Unsupported memory tool: %s', p_tool_name), 'invalid_params');
EXCEPTION WHEN OTHERS THEN
    RETURN tool_error(SQLERRM);
END;
$$;
-- ===== END INLINE: db/38_functions_db_native_tools.sql =====


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
