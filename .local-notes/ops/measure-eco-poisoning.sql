-- Measure eco-memory recall poisoning (W3 / eco-write experiment).
--
-- Eco turns are written tagged metadata.origin='eco' (services/chat.py
-- _eco_remember). This measures: (1) how many exist, (2) whether they surface
-- in fast_recall and at what rank. Decision rule: if eco memories appear high
-- in recall AND degrade replies, lower their write-trust (see
-- spec-recall-quality-guard.md) — else leave them (no thumb on the scale).
--
-- RUN (per persona DB — brain holds hexis_<P>):
--   docker exec -i hexis_brain psql -U hexis_user -d hexis_<persona> -f - < .local-notes/ops/measure-eco-poisoning.sql
-- Fleet sweep: loop the personas you care about.
--
-- origin values: 'eco' (slim nano path), 'prime' (full RLM/agent path),
--   NULL = legacy memory written before the origin tag existed.
--
-- CAVEAT: sections A+B need only the DB. Sections C+D call fast_recall ->
--   get_embedding -> embed server :8081. If :8081 is down they error. Confirm
--   embed up (start-all.ps1 / hexis-status.ps1) before running C+D.

\echo '== A. volume by origin =='
SELECT
    COALESCE(metadata->>'origin', '(legacy/null)') AS origin,
    count(*)                                       AS memories,
    round(100.0 * count(*) / NULLIF(sum(count(*)) OVER (), 0), 1) AS pct
FROM memories
WHERE status = 'active'
GROUP BY 1
ORDER BY memories DESC;

\echo ''
\echo '== B. eco memory shape (age, importance, trust, promotion-eligibility) =='
SELECT
    count(*)                                              AS eco_memories,
    round(avg(importance)::numeric, 3)                    AS avg_importance,
    count(*) FILTER (WHERE importance >= 0.8)             AS auto_promoted_episodic,
    round(avg(trust_level)::numeric, 3)                   AS avg_trust,
    min(created_at)                                       AS oldest,
    max(created_at)                                       AS newest
FROM memories
WHERE status = 'active'
  AND metadata->>'origin' = 'eco';

\echo ''
\echo '== C. single-query recall probe (edit :probe) — top-10 with origin tag =='
-- Override the probe text: psql -v probe='your query here' ... or edit below.
\if :{?probe}
\else
  \set probe 'what did we talk about recently'
\endif
\echo 'probe query:' :'probe'
WITH r AS (
    SELECT * FROM fast_recall(:'probe', 10, NULL)
)
SELECT
    row_number() OVER (ORDER BY r.score DESC)        AS rank,
    round(r.score::numeric, 4)                       AS score,
    r.source,
    COALESCE(m.metadata->>'origin', '(legacy)')      AS origin,
    left(r.content, 70)                              AS snippet
FROM r
JOIN memories m ON m.id = r.memory_id
ORDER BY r.score DESC;

\echo ''
\echo '== D. multi-query eco exposure (edit the VALUES probe set) =='
-- For each probe query: how much of the recalled top-10 is eco-origin, and
-- where does eco rank. High eco_pct + high best_eco_score = poisoning signal.
WITH probes(q) AS (
    VALUES
        ('what did we talk about recently'),
        ('how have you been feeling'),
        ('what do you remember about me'),
        ('what are you working on')
),
recalled AS (
    SELECT p.q, r.score, (m.metadata->>'origin') AS origin
    FROM probes p
    CROSS JOIN LATERAL fast_recall(p.q, 10, NULL) r
    JOIN memories m ON m.id = r.memory_id
)
SELECT
    q                                                              AS probe,
    count(*)                                                       AS topk,
    count(*) FILTER (WHERE origin = 'eco')                         AS eco_hits,
    round(100.0 * count(*) FILTER (WHERE origin = 'eco')
          / NULLIF(count(*), 0), 1)                                AS eco_pct,
    round(max(score) FILTER (WHERE origin = 'eco')::numeric, 4)    AS best_eco_score,
    round(max(score)::numeric, 4)                                  AS best_overall_score
FROM recalled
GROUP BY q
ORDER BY eco_pct DESC NULLS LAST;
