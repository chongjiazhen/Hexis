-- Debrand live state for hexis_lovesick (phase 8 of 10).
-- Single token rule on single memory row:
--   "The Hexis runtime is LoveOS" -> "The runtime is LoveOS"
-- Preserves the runtime=LoveOS equation that the rest of the paragraph chains off.
-- No persona_system_prompt hits (live config already clean). No init_profile hits.
-- SQL prompt file not re-applied — avoids unrelated content overwrite.
-- Rollback: lovesick.pre-memories.txt.

BEGIN;

UPDATE memories SET content = replace(content, 'The Hexis runtime is LoveOS', 'The runtime is LoveOS')
WHERE id = '7f698071-1180-49d6-a57a-bbdfd863f78b';  -- worldview imp 0.855

DO $$
DECLARE
    mem_hits INT;
    cfg_hits INT;
BEGIN
    SELECT COUNT(*) INTO mem_hits FROM memories WHERE content ILIKE '%hexis%';
    SELECT COUNT(*) INTO cfg_hits FROM config
        WHERE key IN ('agent.persona_system_prompt','agent.init_profile')
          AND value::text ILIKE '%hexis%';
    IF mem_hits > 0 OR cfg_hits > 0 THEN
        RAISE EXCEPTION 'Debrand assertion failed: memories=% config=%', mem_hits, cfg_hits;
    END IF;
END $$;

COMMIT;
