-- Live migration: add per-cycle heartbeat jitter. Applied via CREATE OR REPLACE
-- to running instance DBs (NO volume reset; memories preserved).
-- Source of truth: db/00_tables.sql + db/07_functions_heartbeat.sql.

INSERT INTO config (key, value, description) VALUES
    ('heartbeat.heartbeat_jitter_minutes', '12'::jsonb, 'Random +0..N minute spread added per cycle to de-cluster concurrent multi-instance heartbeats on shared inference')
ON CONFLICT (key) DO NOTHING;

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
        RETURN FALSE;
    END IF;
    IF state_record.last_heartbeat_at IS NULL THEN
        RETURN TRUE;
    END IF;
    interval_minutes := get_config_float('heartbeat.heartbeat_interval_minutes');
    jitter_minutes := COALESCE(get_config_float('heartbeat.heartbeat_jitter_minutes'), 0);

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
