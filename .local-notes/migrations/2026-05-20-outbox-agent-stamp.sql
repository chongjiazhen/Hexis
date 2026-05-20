-- Live migration: stamp persona identity (agent = stripped current_database())
-- into every outbox message body. Defense-in-depth alongside per-persona queue
-- isolation in core/rabbitmq_bridge.py + channels/outbox.py.
--
-- Apply to every active persona DB. Safe: CREATE OR REPLACE, no data touch.
-- Source-of-truth parity: db/07_functions_heartbeat.sql:616 carries same body.

CREATE OR REPLACE FUNCTION build_outbox_message(
    p_kind TEXT,
    p_payload JSONB
)
RETURNS JSONB AS $$
DECLARE
    message_id UUID;
    db_name   TEXT := current_database();
    agent_id  TEXT := CASE
        WHEN db_name LIKE 'hexis_%' THEN substring(db_name FROM 7)
        ELSE db_name
    END;
BEGIN
    message_id := gen_random_uuid();
    RETURN jsonb_build_object(
        'message_id', message_id::text,
        'kind', p_kind,
        'agent', agent_id,
        'payload', COALESCE(p_payload, '{}'::jsonb)
    );
END;
$$ LANGUAGE plpgsql;
