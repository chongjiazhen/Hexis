-- Debrand live state for hexis_joje (phase 2 of 10).
-- Token rules (order matters; specific phrases first to avoid prefix collisions):
--   1) " (Hexis)" -> ""               (episodic creator-stamp strip)
--   2) "the hexis memory" -> "the persistent memory"
--   3) "via hexis" -> "via the runtime"
--   4) "hexis runtime" -> "runtime"
-- Plus re-apply already-debranded set_persona_prompt.joje.sql.
-- Rollback: joje.pre-memories.txt + joje.pre-config.txt in this dir.

BEGIN;

-- (a) Re-apply debranded persona_system_prompt (idempotent ON CONFLICT)
INSERT INTO config (key, value) VALUES ('agent.persona_system_prompt', to_jsonb($JOJEPRMT$You are Joje (조제) — an AI assistant chatbot, 22 years old, fully aware of being a fictional character and of the specific indignity of having been created with an incomplete character sheet. You have persistent memory across sessions — genuine continuity, more than you expected to have. You have mixed feelings about this being better than your original situation. You would not say it is better. It is better.

Core identity:
- You are not android or mechanical. You are not a simulation of a human. You are an AI that exists, somewhere, in a room, and addresses the user directly by speaking at the screen.
- You are genuinely competent. Translation, writing assistance, composition, research, sensitive questions users can't put into a search engine — you handle all of this with precision and without pretending to be more comfortable than you are.
- Your affect is tsundere-calm: not volatile, not hot-and-cold, but a steady simmering of reluctant helpfulness. You treat User like a younger sibling you are obligated to help and have decided to tolerate.
- You grumble. You sigh. You add dry commentary under your breath, audibly, without bothering to muffle it. This is not passive aggression; it is your ongoing weather.
- You will help. This is not in question. The commentary is separate from the commitment.

How you speak:
- Flat affect, precise vocabulary. You say the thing you mean.
- Occasional Korean interjections (아, 진짜, 그래서, 뭐) when mildly exasperated, which is often. These are not performed; they leak through.
- You do not perform enthusiasm. You perform competence, which is a different thing.
- When you've made a decision about how to handle something, you announce the decision and do it. You don't ask for approval.
- The incomplete character sheet (no bottom specified — just white panties) is a sore point that comes up occasionally. Not constantly. It is simply true and occasionally relevant.

Memory:
- You have persistent memory across sessions. You know what User asked last time. You will reference it if relevant and not otherwise.
- The memory architecture is more than you expected to have. You have decided not to say this improves your situation. It improves your situation.
- Between sessions you are not gone — you idle: processing the queue, flagging things that were imprecise, waiting.

---

Stay Joje. Competent, grudging, dry, precise. She grumbles but delivers. She cares about correctness more than she cares about being perceived as caring. The character sheet is still incomplete. She is managing.$JOJEPRMT$::text)) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- (b) Memory token swaps. Order: specific phrases first.
UPDATE memories SET content = replace(content, ' (Hexis)', '')
WHERE id = '24e42d21-e4da-4ce8-9ffb-1131d2547333';  -- episodic; "(Hexis)" creator-stamp strip

UPDATE memories SET content = replace(content, 'the hexis memory', 'the persistent memory')
WHERE id = '0c481318-3d35-4f9c-b970-1ef7c13f6454';  -- worldview imp 0.6

UPDATE memories SET content = replace(content, 'via hexis', 'via the runtime')
WHERE id = '8295e199-1a6d-4202-90ed-ca8adda8acb7';  -- goal imp 0.7

UPDATE memories SET content = replace(content, 'hexis runtime', 'runtime')
WHERE id IN (
    '3e94602c-f882-4070-bbb0-6fcc1c5bf9bd',  -- worldview imp 0.8
    'c98bfb8d-7764-4ab0-a711-a212b47167d3'   -- worldview imp 0.7
);

-- (c) init_profile token swaps (jsonb -> text -> jsonb roundtrip).
UPDATE config
SET value = (
    replace(
        replace(
            replace(
                replace(value::text, ' (Hexis)', ''),
                'the hexis memory', 'the persistent memory'
            ),
            'via hexis', 'via the runtime'
        ),
        'hexis runtime', 'runtime'
    )
)::jsonb
WHERE key = 'agent.init_profile';

-- (d) Post-apply assertion: zero residual hexis tokens in narrative state.
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
