-- Debrand live state for hexis_charlotte (phase 9 of 10; last).
-- Single token rule on single memory row:
--   "The Hexis episodic memory system" -> "The episodic memory system"
-- (same pattern used in ao phase)
-- No persona_system_prompt or init_profile hits (audit clean).
-- SQL prompt file not re-applied — avoids unrelated content overwrite.
-- Rollback: charlotte.pre-memories.txt.

BEGIN;

UPDATE memories SET content = replace(content, 'The Hexis episodic memory system', 'The episodic memory system')
WHERE id = '4652d654-3bbd-44ae-a106-400c612fbee8';  -- worldview imp 0.8

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
