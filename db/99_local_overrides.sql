-- Home-rig local overrides. Only on home-rig-local branch — do not merge to main.
-- Points llm.* cognition at the llm-serve router :8090 with the virtual model
-- hexis-active (ADR 019 item 2). The router rewrites hexis-active to the live
-- backend and survives PRIME/ECO flips; never pin raw :8080 / a hardcoded quant.
-- Host is host.docker.internal, NOT localhost: workers run on the hexis_private
-- bridge net, so localhost is the container's own loopback (router refuses) —
-- host.docker.internal is the host gateway where the router binds.
-- Runs last so it overrides anything seeded earlier by init_llm_config.

SELECT set_config(
    'llm.chat',
    '{"provider":"openai_compatible","model":"hexis-active","endpoint":"http://host.docker.internal:8090/v1","api_key_env":"OPENAI_API_KEY"}'::jsonb
);
SELECT set_config(
    'llm.heartbeat',
    '{"provider":"openai_compatible","model":"hexis-active","endpoint":"http://host.docker.internal:8090/v1","api_key_env":"OPENAI_API_KEY"}'::jsonb
);
SELECT set_config(
    'llm.subconscious',
    '{"provider":"openai_compatible","model":"hexis-active","endpoint":"http://host.docker.internal:8090/v1","api_key_env":"OPENAI_API_KEY"}'::jsonb
);
