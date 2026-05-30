-- Live migration: night-mode heartbeat throttle + wider day jitter.
-- Applied via CREATE OR REPLACE to running instance DBs (NO volume reset;
-- memories preserved). Idempotent. Re-runnable.
-- Source of truth: db/00_tables.sql + db/07_functions_heartbeat.sql.
--
-- Behavior: during local night window (heartbeat.timezone, default
-- Asia/Singapore), heartbeats use night_interval_minutes/night_jitter_minutes
-- instead of the daytime values. Window wraps midnight when
-- night_start_hour > night_end_hour (default 23..8). Daytime jitter widened
-- 12 -> 20 min. Maintenance gate NOT touched here.

-- New config keys (defaults). DO NOTHING preserves any per-DB overrides.
INSERT INTO config (key, value, description) VALUES
    ('heartbeat.timezone', '"Asia/Singapore"'::jsonb, 'IANA tz for night-window hour comparison; server clock is UTC'),
    ('heartbeat.night_start_hour', '23'::jsonb, 'Local hour [0-23] night throttle begins (inclusive)'),
    ('heartbeat.night_end_hour', '8'::jsonb, 'Local hour [0-23] night throttle ends (exclusive); window wraps midnight when start > end'),
    ('heartbeat.night_interval_minutes', '240'::jsonb, 'Minutes between heartbeats during night window (slower than daytime)'),
    ('heartbeat.night_jitter_minutes', '60'::jsonb, 'Random +0..N minute spread during night window')
ON CONFLICT (key) DO NOTHING;

-- Widen daytime jitter 12 -> 20. Explicit UPDATE: ON CONFLICT DO NOTHING above
-- would not touch an existing row. Only bump if still at the old default, so a
-- deliberate per-DB override is not clobbered.
UPDATE config SET value = '20'::jsonb
WHERE key = 'heartbeat.heartbeat_jitter_minutes' AND value = '12'::jsonb;

CREATE OR REPLACE FUNCTION is_heartbeat_night()
RETURNS BOOLEAN AS $$
DECLARE
    tz TEXT;
    cur_hour INT;
    night_start INT;
    night_end INT;
BEGIN
    tz := COALESCE(get_config_text('heartbeat.timezone'), 'Asia/Singapore');
    night_start := COALESCE(get_config_int('heartbeat.night_start_hour'), 23);
    night_end := COALESCE(get_config_int('heartbeat.night_end_hour'), 8);
    cur_hour := extract(hour FROM (CURRENT_TIMESTAMP AT TIME ZONE tz))::INT;
    IF night_start <= night_end THEN
        RETURN cur_hour >= night_start AND cur_hour < night_end;
    ELSE
        RETURN cur_hour >= night_start OR cur_hour < night_end;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

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
