-- Debrand live state for hexis_baymax (phase 5 of 10).
-- IDENTITY CORRECTION (not just token swap): DB memories named persona "Hexis";
-- canonical card name = "Baymax". Init drift; fix to card-canonical identity.
-- Rule: "Hexis" -> "Baymax" (case-sensitive; all 3 hits use capital H).
-- No persona_system_prompt or init_profile (audit clean). No SQL prompt file.
-- Frozen instance — no worker restart needed.
-- Rollback: baymax.pre-memories.txt.

BEGIN;

UPDATE memories SET content = replace(content, 'Hexis', 'Baymax')
WHERE id IN (
    '9c814b26-4fe0-4a1c-8c08-56bf8ad2e4a3',  -- worldview imp 1.068 "My name is Hexis."
    'c2ac3db5-cc74-4b72-a345-4856a5cfa20d',  -- episodic  imp 1.068 "...bring me into being as Hexis."
    '9c435b9b-da6f-4a15-a12d-2114a0f518db'   -- worldview imp 0.749 "I am Hexis, a developing mind."
);

DO $$
DECLARE
    mem_hits INT;
BEGIN
    SELECT COUNT(*) INTO mem_hits FROM memories WHERE content ILIKE '%hexis%';
    IF mem_hits > 0 THEN
        RAISE EXCEPTION 'Debrand assertion failed: memories=%', mem_hits;
    END IF;
END $$;

COMMIT;
