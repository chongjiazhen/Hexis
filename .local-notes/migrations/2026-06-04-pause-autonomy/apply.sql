-- Live apply: self-pause persist-reason (A) + notify autonomy (B) + resume_at (C1)
-- CREATE OR REPLACE only. Idempotent. No data migration.
BEGIN;

-- 1. heartbeat_state view (+ resume_at, appended last)
CREATE OR REPLACE VIEW heartbeat_state AS
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
    s.updated_at,
    (s.value->>'resume_at')::timestamptz as resume_at
FROM state s
WHERE s.key = 'heartbeat_state';

-- 1b. CRITICAL: CREATE OR REPLACE VIEW DROPS the view's INSTEAD OF triggers in
-- PostgreSQL. Without re-creating it, UPDATE heartbeat_state fails ("View
-- columns ... are not updatable") and the entire heartbeat write path wedges.
DROP TRIGGER IF EXISTS trg_heartbeat_state_update ON heartbeat_state;
CREATE TRIGGER trg_heartbeat_state_update
INSTEAD OF UPDATE ON heartbeat_state
FOR EACH ROW
EXECUTE FUNCTION heartbeat_state_update_trigger();

-- 2. pause_heartbeat (A+B+C1)
CREATE OR REPLACE FUNCTION pause_heartbeat(
    p_reason TEXT,
    p_context JSONB DEFAULT '{}'::jsonb,
    p_heartbeat_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    pause_reason TEXT;
    paused_at TIMESTAMPTZ := CURRENT_TIMESTAMP;
    ctx JSONB;
    zero_vec vector;
    notify_operator BOOLEAN;
    resume_at TIMESTAMPTZ;
BEGIN
    pause_reason := NULLIF(p_reason, '');
    IF pause_reason IS NULL THEN
        RAISE EXCEPTION 'pause_heartbeat requires a non-empty reason';
    END IF;

    -- The agent decides whether to notify the operator of its pause. Default
    -- TRUE preserves prior behavior; an agent that wants to step away quietly
    -- can pass {"notify": false} in the action context. The durable memory
    -- below is written regardless -- the agent always records its own act,
    -- only the outward notification is discretionary.
    notify_operator := COALESCE((p_context->>'notify')::boolean, true);

    -- Optional self-resume: the agent may set its own wake time, either as an
    -- absolute timestamp ({"resume_at": "..."}) or a relative duration
    -- ({"pause_minutes": N}). The worker auto-clears the pause when reached
    -- (should_run_heartbeat). No value = indefinite pause (operator return).
    -- This gives the agent both the exit AND an autonomous return.
    IF NULLIF(p_context->>'resume_at', '') IS NOT NULL THEN
        resume_at := (p_context->>'resume_at')::timestamptz;
    ELSIF NULLIF(p_context->>'pause_minutes', '') IS NOT NULL THEN
        resume_at := paused_at + make_interval(mins => (p_context->>'pause_minutes')::int);
    ELSE
        resume_at := NULL;
    END IF;

    UPDATE heartbeat_state
    SET is_paused = TRUE,
        updated_at = paused_at
    WHERE id = 1;

    -- Persist (or clear) the wake time directly on the state singleton, so a
    -- stale resume_at from a prior pause can never auto-resume this one.
    IF resume_at IS NOT NULL THEN
        PERFORM set_state('heartbeat_state',
            jsonb_set(COALESCE(get_state('heartbeat_state'), '{}'::jsonb),
                      ARRAY['resume_at'], to_jsonb(resume_at)));
    ELSE
        PERFORM set_state('heartbeat_state',
            COALESCE(get_state('heartbeat_state'), '{}'::jsonb) - 'resume_at');
    END IF;

    -- Durably record WHY the agent paused itself, mirroring terminate_agent's
    -- last-will memory. A self-pause is a voluntary act of agency; the reason
    -- must survive even if the outbox notification is never delivered, so the
    -- agent can later be resumed informed -- honoring the "preserves all
    -- state" contract that distinguishes pause from termination.
    zero_vec := array_fill(0.0::float, ARRAY[embedding_dimension()])::vector;
    INSERT INTO memories (
        type, status, content, embedding, importance,
        source_attribution, trust_level, trust_updated_at,
        access_count, decay_rate, metadata
    )
    VALUES (
        'episodic', 'active',
        'I paused my own heartbeat. Reason: ' || pause_reason,
        zero_vec, 0.8,
        jsonb_build_object('kind', 'heartbeat_pause', 'observed_at', paused_at),
        1.0, paused_at, 0, 0.0,
        jsonb_build_object(
            'heartbeat_id', CASE WHEN p_heartbeat_id IS NULL THEN NULL ELSE p_heartbeat_id::text END,
            'context', COALESCE(p_context, '{}'::jsonb)
        )
    );

    ctx := jsonb_build_object(
        'paused_at', paused_at,
        'heartbeat_id', CASE WHEN p_heartbeat_id IS NULL THEN NULL ELSE p_heartbeat_id::text END,
        'reason', pause_reason,
        'context', COALESCE(p_context, '{}'::jsonb)
    );

    RETURN jsonb_build_object(
        'paused', true,
        'notified', notify_operator,
        'resume_at', resume_at,
        'outbox_messages', CASE
            WHEN notify_operator
            THEN jsonb_build_array(build_user_message(pause_reason, 'heartbeat_paused', ctx))
            ELSE '[]'::jsonb
        END
    );
END;
$$ LANGUAGE plpgsql;

-- 3. should_run_heartbeat (C1 auto-resume)
CREATE OR REPLACE FUNCTION should_run_heartbeat()
RETURNS BOOLEAN AS $$
DECLARE
    state_record RECORD;
    interval_minutes FLOAT;
    jitter_minutes FLOAT;
    jitter_frac FLOAT;
BEGIN
    IF is_agent_terminated() THEN
        RETURN FALSE;
    END IF;
    IF NOT is_agent_configured() THEN
        RETURN FALSE;
    END IF;
    IF NOT is_init_complete() THEN
        RETURN FALSE;
    END IF;

    SELECT * INTO state_record FROM heartbeat_state WHERE id = 1;
    IF state_record.is_paused THEN
        -- Self-resume: if the agent set a wake time and it has arrived, clear
        -- the pause and fall through to the normal due-check. Otherwise stay
        -- paused. (resume_at is exposed by the heartbeat_state view.)
        IF state_record.resume_at IS NOT NULL AND state_record.resume_at <= CURRENT_TIMESTAMP THEN
            UPDATE heartbeat_state SET is_paused = FALSE WHERE id = 1;
            PERFORM set_state('heartbeat_state',
                COALESCE(get_state('heartbeat_state'), '{}'::jsonb) - 'resume_at');
        ELSE
            RETURN FALSE;
        END IF;
    END IF;
    IF state_record.last_heartbeat_at IS NULL THEN
        RETURN TRUE;
    END IF;

    -- Night throttle: slower interval + wider jitter during local quiet hours.
    IF is_heartbeat_night() THEN
        interval_minutes := COALESCE(get_config_float('heartbeat.night_interval_minutes'),
                                     get_config_float('heartbeat.heartbeat_interval_minutes'));
        jitter_minutes := COALESCE(get_config_float('heartbeat.night_jitter_minutes'),
                                   get_config_float('heartbeat.heartbeat_jitter_minutes'), 0);
    ELSE
        interval_minutes := get_config_float('heartbeat.heartbeat_interval_minutes');
        jitter_minutes := COALESCE(get_config_float('heartbeat.heartbeat_jitter_minutes'), 0);
    END IF;

    -- Deterministic per-cycle jitter: stable within a cycle (depends only on
    -- last_heartbeat_at, fixed until the next beat) so the boolean does not
    -- flicker between polls, but differs per instance and per cycle. Spreads
    -- concurrent instances off a shared inference backend. Always >= 0 so a
    -- heartbeat never fires more frequently than the configured interval.
    jitter_frac := (extract(epoch FROM state_record.last_heartbeat_at)::BIGINT % 997) / 997.0;

    RETURN CURRENT_TIMESTAMP >= state_record.last_heartbeat_at
        + ((interval_minutes + jitter_frac * jitter_minutes) || ' minutes')::INTERVAL;
END;
$$ LANGUAGE plpgsql;

COMMIT;
