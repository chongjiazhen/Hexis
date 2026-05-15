-- Home-rig local overrides. Only on home-rig-local branch — do not merge to main.
-- Pins llm.* endpoints to host llama-server instances started by start.ps1.
-- Runs last so it overrides anything seeded earlier by init_llm_config.

SELECT set_config(
    'llm.chat',
    '{"provider":"openai_compatible","model":"hexis-vesper-12b","endpoint":"http://localhost:8080/v1","api_key_env":"OPENAI_API_KEY"}'::jsonb
);
SELECT set_config(
    'llm.heartbeat',
    '{"provider":"openai_compatible","model":"hexis-vesper-12b","endpoint":"http://localhost:8080/v1","api_key_env":"OPENAI_API_KEY"}'::jsonb
);
SELECT set_config(
    'llm.subconscious',
    '{"provider":"openai_compatible","model":"hexis-vesper-12b","endpoint":"http://localhost:8080/v1","api_key_env":"OPENAI_API_KEY"}'::jsonb
);
