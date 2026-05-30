-- Hexis stale-reference audit across non-content surfaces
-- Run via: docker exec -i hexis_brain psql -U hexis_user -d <db> -f /tmp/audit-scan.sql
\pset pager off
\set QUIET on
LOAD 'age';
SET search_path = ag_catalog, public;
\set QUIET off

\echo '--- COUNTS ---'
SELECT 'worldview' AS surface, count(*) FROM memories WHERE type='worldview'
UNION ALL SELECT 'goals', count(*) FROM memories WHERE type='goal'
UNION ALL SELECT 'clusters', count(*) FROM clusters
UNION ALL SELECT 'drives', count(*) FROM drives
UNION ALL SELECT 'emotional_triggers', count(*) FROM emotional_triggers
UNION ALL SELECT 'config_total', count(*) FROM config
UNION ALL SELECT 'age_nodes', count(*) FROM cypher('memory_graph', $$ MATCH (n) RETURN n $$) AS (n agtype);

\echo ''
\echo '--- WORLDVIEW hits ---'
SELECT id, LEFT(content, 200) AS snippet FROM memories
WHERE type='worldview' AND (
  content ILIKE '%openclaw%' OR content ILIKE '%mcp_bridge%' OR content ILIKE '%body_bridge%'
  OR content ILIKE '%TARS%' OR content ILIKE '%Rocky%' OR content ILIKE '%Baymax%' OR content ILIKE '%Warden%'
  OR content ILIKE '%hexis%'
  OR content ILIKE '%group chat%'
  OR content ILIKE '%context variable%' OR content ILIKE '%REPL>%' OR content ILIKE '%memory_search%' OR content ILIKE '%print(context)%'
);

\echo ''
\echo '--- GOAL hits ---'
SELECT id, LEFT(content, 200) AS snippet FROM memories
WHERE type='goal' AND (
  content ILIKE '%openclaw%' OR content ILIKE '%mcp_bridge%' OR content ILIKE '%body_bridge%'
  OR content ILIKE '%TARS%' OR content ILIKE '%Rocky%' OR content ILIKE '%Baymax%' OR content ILIKE '%Warden%'
  OR content ILIKE '%hexis%'
  OR content ILIKE '%group chat%'
  OR content ILIKE '%context variable%' OR content ILIKE '%REPL>%' OR content ILIKE '%memory_search%' OR content ILIKE '%print(context)%'
);

\echo ''
\echo '--- CLUSTERS hits ---'
SELECT id, cluster_type, LEFT(name, 200) AS snippet FROM clusters
WHERE name ILIKE '%openclaw%' OR name ILIKE '%mcp_bridge%' OR name ILIKE '%body_bridge%'
  OR name ILIKE '%TARS%' OR name ILIKE '%Rocky%' OR name ILIKE '%Baymax%' OR name ILIKE '%Warden%'
  OR name ILIKE '%hexis%'
  OR name ILIKE '%group chat%'
  OR name ILIKE '%context variable%' OR name ILIKE '%REPL>%' OR name ILIKE '%memory_search%' OR name ILIKE '%print(context)%';

\echo ''
\echo '--- DRIVES hits ---'
SELECT id, name, LEFT(description, 200) AS snippet FROM drives
WHERE name ILIKE '%openclaw%' OR name ILIKE '%mcp_bridge%' OR name ILIKE '%body_bridge%'
  OR name ILIKE '%TARS%' OR name ILIKE '%Rocky%' OR name ILIKE '%Baymax%' OR name ILIKE '%Warden%'
  OR name ILIKE '%hexis%' OR name ILIKE '%group chat%'
  OR description ILIKE '%openclaw%' OR description ILIKE '%mcp_bridge%' OR description ILIKE '%body_bridge%'
  OR description ILIKE '%TARS%' OR description ILIKE '%Rocky%' OR description ILIKE '%Baymax%' OR description ILIKE '%Warden%'
  OR description ILIKE '%hexis%' OR description ILIKE '%group chat%'
  OR description ILIKE '%context variable%' OR description ILIKE '%REPL>%' OR description ILIKE '%memory_search%' OR description ILIKE '%print(context)%';

\echo ''
\echo '--- EMOTIONAL_TRIGGERS hits ---'
SELECT id, LEFT(trigger_pattern, 100) AS pattern, typical_emotion, origin FROM emotional_triggers
WHERE trigger_pattern ILIKE '%openclaw%' OR trigger_pattern ILIKE '%mcp_bridge%' OR trigger_pattern ILIKE '%body_bridge%'
  OR trigger_pattern ILIKE '%TARS%' OR trigger_pattern ILIKE '%Rocky%' OR trigger_pattern ILIKE '%Baymax%' OR trigger_pattern ILIKE '%Warden%'
  OR trigger_pattern ILIKE '%hexis%' OR trigger_pattern ILIKE '%group chat%'
  OR trigger_pattern ILIKE '%context variable%' OR trigger_pattern ILIKE '%REPL>%' OR trigger_pattern ILIKE '%memory_search%' OR trigger_pattern ILIKE '%print(context)%';

\echo ''
\echo '--- PERSONA_SYSTEM_PROMPT hits ---'
SELECT key, LEFT(value::text, 300) AS snippet FROM config WHERE key='agent.persona_system_prompt' AND (
  value::text ILIKE '%openclaw%' OR value::text ILIKE '%mcp_bridge%' OR value::text ILIKE '%body_bridge%'
  OR value::text ILIKE '%TARS%' OR value::text ILIKE '%Rocky%' OR value::text ILIKE '%Baymax%' OR value::text ILIKE '%Warden%'
  OR value::text ILIKE '%hexis%' OR value::text ILIKE '%group chat%'
  OR value::text ILIKE '%context variable%' OR value::text ILIKE '%REPL>%' OR value::text ILIKE '%memory_search%' OR value::text ILIKE '%print(context)%'
);

\echo ''
\echo '--- CONFIG (other rows) hits ---'
SELECT key, LEFT(value::text, 200) AS snippet FROM config WHERE key <> 'agent.persona_system_prompt' AND (
  value::text ILIKE '%openclaw%' OR value::text ILIKE '%mcp_bridge%' OR value::text ILIKE '%body_bridge%'
  OR value::text ILIKE '%TARS%' OR value::text ILIKE '%Rocky%' OR value::text ILIKE '%Baymax%' OR value::text ILIKE '%Warden%'
  OR value::text ILIKE '%group chat%'
  OR value::text ILIKE '%context variable%' OR value::text ILIKE '%REPL>%' OR value::text ILIKE '%memory_search%' OR value::text ILIKE '%print(context)%'
);

\echo ''
\echo '--- AGE nodes (properties stale hits) ---'
SELECT label, LEFT(properties::text, 250) AS snippet
FROM cypher('memory_graph', $$ MATCH (n) RETURN label(n) AS label, properties(n) AS properties $$) AS (label agtype, properties agtype)
WHERE properties::text ILIKE '%openclaw%' OR properties::text ILIKE '%mcp_bridge%' OR properties::text ILIKE '%body_bridge%'
  OR properties::text ILIKE '%TARS%' OR properties::text ILIKE '%Rocky%' OR properties::text ILIKE '%Baymax%' OR properties::text ILIKE '%Warden%'
  OR properties::text ILIKE '%hexis%' OR properties::text ILIKE '%group chat%'
  OR properties::text ILIKE '%context variable%' OR properties::text ILIKE '%REPL>%' OR properties::text ILIKE '%memory_search%' OR properties::text ILIKE '%print(context)%'
LIMIT 20;
