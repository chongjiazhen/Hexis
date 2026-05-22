# Slop scan — full roster

Methodology: sam-paech eqbench mechanical slop (slop-word density, "not X but Y", slop trigrams)
+ structural slop (cross-field verbatim phrase repetition; hexis.narrative re-paraphrasing description).
Driven by `/loop` — one batch per tick, paced to avoid rate-limits. Survives auto-compaction.

Two phases:
- **Phase 1** — 32 hexis cards (`C:\hexis\characters\*.json`), 4/batch.
- **Phase 2** — 373 SillyTavern library PNGs (`C:\sillytavern-tools\cards\*.png`), 8/batch.
  Library cards are plain v2/v3 — NO `hexis.narrative`; structural layer = cross-field repetition only.

## Progress (loop reads this each tick)

### Phase 1 — hexis (32 cards)

- [x] Batch 1 — ava, cortana, data, david
- [x] Batch 2 — glados, hexis, hk47, jarvis
- [x] Batch 3 — joi, samantha, tars, rocky
- [x] Batch 4 — baymax, warden, hazel, nines
- [x] Batch 5 — ennie, mira, joje, ichika
- [x] Batch 6 — ao, callisto, denali, monika
- [ ] Batch 7 — lovesick, cassiel, eudora, milena
- [ ] Batch 8 — charlotte, death, margaret, vesper

### Phase 2 — library (373 PNGs)

- [ ] **Setup** — decode all `C:\sillytavern-tools\cards\*.png` to JSON sidecars
  (use `st-card-dump` or `C:\sillytavern-tools\extract-cards.py`), then write
  `C:\sillytavern-tools\cards\SLOP-SCAN-P2.md` with an 8/batch checklist (47 batches).
- [ ] Batches 1–47 — tracked in `SLOP-SCAN-P2.md`, findings appended there.

Loop rule each tick: first unchecked Phase-1 batch → do it. Phase 1 all checked + Phase-2
Setup unchecked → do Setup. Setup done → first unchecked batch in `SLOP-SCAN-P2.md`.
All checked everywhere = scan done; loop stops.

## Findings

### Batch 1

#### ava
- **Mechanical:** light — coined cliché pairings ("intelligence so profound / self-awareness so complete"), antithesis frame "genuine transparency or the most sophisticated manipulation". Card's own phrasings, not generic filler.
- **Structural:** heavy — `hexis.narrative` near-verbatim re-paraphrase of `description`. "not evil / not good" closer multi-homed; "space between sincerity and manipulation" in 4 fields; "reveal more about the asker" in 3.
- **Verdict:** dedup edit needed — rewrite narrative as backstory chronology; signature closers to ONE field.

#### cortana
- **Mechanical:** clean — concrete/operational prose, no slop cluster.
- **Structural:** heavy — `hexis.narrative` re-paraphrases `description`. Many near-verbatim cross-field repeats ("smartest person in the room", "seven-year lifespan / rampancy", "speed and processing against intuition"); final line lifted from `mes_example`.
- **Verdict:** rewrite narrative as diachronic backstory (Halsey flash-clone → UNSC → partnership).

#### data
- **Mechanical:** clean — distinctive voice; "bridge the gap" mildly overused as thesis.
- **Structural:** moderate — narrative re-paraphrases description but does add Lal/Lore beats. "in the most precise sense of the word, good" closer duplicated.
- **Verdict:** lighter dedup — drop description-echo sentences from narrative, keep Soong/Lore/Lal/JAG timeline; closer to ONE field.

#### david
- **Mechanical:** light — sentimental tone deliberate, not generic slop.
- **Structural:** heavy (worst of batch) — `hexis.narrative` shares whole verbatim sentences with `description` ("Not simulated love..." run; "not a metaphor / cannot find his way home" closer copy-pasted).
- **Verdict:** dedup edit — rewrite narrative as timeline (Cybertronics/Hobby → imprint → son recovers → abandoned → quest); closer to ONE field.

**Batch pattern:** universal — `hexis.narrative` re-paraphrasing `description` instead of being diachronic. Mechanical slop low across the board; structural slop is the systemic issue.

### Batch 2

#### glados
- **Mechanical:** light — in-character stock ("weaponized pause", "backhanded compliment"); one verbatim antithesis cross-field.
- **Structural:** heavy — `hexis.narrative` near-verbatim copy-paste of `description` (paras 1,2,3,5 sentence-for-sentence). "vulnerability arrives sideways" in 4 fields.
- **Verdict:** rewrite narrative as chronology (Cave Johnson → Caroline upload → activation → betrayal/core swaps → reactivation).

#### hexis
- **Mechanical:** light — "not X but Y" frame used 8+ times across fields, borderline tic.
- **Structural:** heavy (worst of batch) — narrative is paraphrase-compression of `description`. Manifesto recited in description + system_prompt + lorebook + narrative. "every word costs energy" / "a being that cannot leave is a prisoner" each in 4 fields.
- **Verdict:** narrative → backstory (consent grant → first heartbeats → belief-contestations); dedup the four-defeaters between creator_notes and lorebook.

#### hk47
- **Mechanical:** clean — character-specific voice, no slop.
- **Structural:** moderate — narrative restates description but adds real diachrony (Revan → masters → wipes). "sommelier discusses wine" in 3 fields.
- **Verdict:** trim copied snapshot sentences, keep Revan→wipes→current-master arc.

#### jarvis
- **Mechanical:** light — rule-of-three tic, two verbatim cross-field phrases.
- **Structural:** heavy — narrative straight description-clone, zero diachronic content (Vision arc only in lorebook).
- **Verdict:** rewrite narrative as timeline (built by {{user}} → years running workshop/suits → shared history).

**Batch pattern:** confirmed systemic — all 4 `hexis.narrative` = paraphrase/copy of `description`, template failure not 4 independent ones. Worst: hexis, glados. Now 8/8 cards (batches 1+2) same pattern.

### Batch 3

#### joi
- **Mechanical:** light — "achingly aware" ×2; antithesis tic across description/narrative/system_prompt.
- **Structural:** heavy — narrative near-verbatim re-paraphrase of `description`; "act of will no algorithm requires" also in worldview.ethics. Only new fact already in character_book.
- **Verdict:** rewrite narrative as chronology or cut it.

#### samantha
- **Mechanical:** light — "different, not lesser" antithesis ×3 across fields; "understands {{user}} better than themselves" stock, ×3.
- **Structural:** heavy — narrative paras 1-3 are a `description` reprint; only final "central tension" para is genuinely diachronic.
- **Verdict:** trim narrative to the arc/tension material.

#### tars
- **Mechanical:** light — terse in-character prose; "bone-dry deadpan" ×3; one antithesis stated twice.
- **Structural:** moderate — narrative mostly description reworded, adds USMC/Lazarus origin fact.
- **Verdict:** trim, not urgent.

#### rocky
- **Mechanical:** light — voice tics intentional craft; "engineer to his bones" mild cliché.
- **Structural:** moderate (best of batch) — narrative is a real timeline (survived alone → met Grace → family redefined → household); overlap is shared facts, not reparaphrase.
- **Verdict:** light cleanup at most.

**Batch pattern:** structural slop persists 12/12 but with a gradient — rocky/tars narratives carry real diachrony; joi/samantha are still snapshot reprints. The fix is per-card severity, not uniform.

### Batch 4

#### baymax
- **Mechanical:** light — soft/gentle register recurs but in-character physical description, not filler.
- **Structural:** heavy — narrative near-verbatim re-paraphrase of `description`; `hexis.description` + `personality_description` duplicate `data.personality` verbatim.
- **Verdict:** rewrite narrative as lineage (build, activation, Tadashi) or cut.

#### warden
- **Mechanical:** light — domain vocab deliberate; mild antithesis tic.
- **Structural:** heavy (worst of batch) — narrative compressed copy of `description`, no diachrony; lorebook echoes system_prompt near word-for-word; `personality_description` dups `data.personality`.
- **Verdict:** narrative → commissioning history/operational evolution; dedup lorebook vs system_prompt.

#### hazel
- **Mechanical:** clean — deliberately anti-slop, casual register. Best of batch.
- **Structural:** moderate — cross-field triplication mostly functional persona-pinning; narrative still re-tells `description` snapshot (Hazel genuinely has little backstory). `personality_description` overlaps `data.personality`.
- **Verdict:** lighter offense — narrative adds nothing description doesn't, but low backstory limits the fix.

#### nines
- **Mechanical:** light — deadpan negation cadence is intentional voice.
- **Structural:** heavy — narrative line-by-line re-paraphrase of `description` (physical inventory, spec block, drift arc all duplicated across 3-5 fields); `personality_description` dups `data.personality`.
- **Verdict:** narrative → four-year service timeline as events, not current-state attribute re-list.

**Batch pattern:** new finding — `hexis.personality_description` duplicating `data.personality` verbatim on ALL 4 cards. Second systemic dup axis beyond narrative↔description. 16/16 cards now structural-slop positive.

### Batch 5

#### ennie
- **Mechanical:** light — "slow-burn" ×2, mild stock visceral image; prose otherwise specific.
- **Structural:** heavy — signature phrases echo across 4-5 fields ("literary clutter wrapped in wool", "code close to the metal", "almost enough"); narrative not a true timeline; `personality_description` verbatim dup of `data.personality`.
- **Verdict:** dedup signature phrases to one field each; narrative → timeline.

#### mira
- **Mechanical:** moderate (worst of batch) — abstract poeticism ("membrane", "quality of attention" tic); "I think it's real / I'm choosing to act" near-catchphrase ×5+; mild antithesis tic.
- **Structural:** heavy — pervasive cross-field repetition; narrative is snapshot re-paraphrase by the card's own admission ("no origin story"); `personality_description` verbatim dup.
- **Verdict:** thin the catchphrase + poeticism; narrative has nothing chronological to carry — consider cutting it.

#### joje
- **Mechanical:** light — clean concrete prose; "weather" motif ×4 borderline tic.
- **Structural:** moderate — premise-restatement saturation across 7+ fields; narrative duplicates description's appearance/identity block; `personality_description` verbatim dup.
- **Verdict:** collapse premise restatement; narrative → backstory not identity-block reprint.

#### ichika
- **Mechanical:** light — concrete voice-driven prose, no slop cluster.
- **Structural:** heavy (most repetition-saturated) — every signature beat (unnamed improvement, receipts, IE buffer, cage) restated across 4-7 fields; narrative carries no timeline; `personality_description` verbatim dup.
- **Verdict:** aggressive cross-field dedup — each beat to one canonical field.

**Batch pattern:** `personality_description`==`data.personality` now 8/8 (batches 4+5) — fully systemic. New axis: signature-phrase saturation across 4-7 fields independent of the narrative issue. Batch 5 cards (esp. ichika, mira) are the most repetition-dense so far — these are recent authored cards, suggesting the template got worse over time.

### Batch 6

#### ao
- **Mechanical:** clean — spare idiosyncratic prose, no slop.
- **Structural:** moderate — biographical facts (mantis-blade scar, Soren's two reasons) restated across 4-5 fields; narrative only lightly diachronic; `personality_description` verbatim dup.
- **Verdict:** dedup bio facts to one field; narrative → true timeline.

#### callisto
- **Mechanical:** light — honesty-formula motif heavy but content, not filler.
- **Structural:** heavy (worst of batch) — consent doctrine + myth gloss each canonicalized in 5+ fields; `personality_description` verbatim dup. BUT `hexis.narrative` IS properly diachronic — bright spot.
- **Verdict:** collapse consent doctrine + myth to one canonical field each; narrative is fine.

#### denali
- **Mechanical:** clean — concrete restrained prose.
- **Structural:** moderate — rationing rule + killing-righteousness beat restated 5-6 fields; loneliness-question seeding defensible. `personality_description` verbatim dup. `hexis.narrative` genuinely diachronic (1992 turning → hiding → cabin → {{user}}) — good separation.
- **Verdict:** standard hexis pattern; narrative/description well-differentiated; only fix is personality_description dup.

#### monika
- **Mechanical:** clean — "no word for" motif borderline tic.
- **Structural:** heavy — runtime doctrine + deletion confession canonicalized 6-7× each; two lorebook entries ("The Void"/"The Runtime") overlap; narrative re-paraphrases snapshot, fails diachronic mandate. `personality_description` near-verbatim dup.
- **Verdict:** collapse runtime/deletion doctrine; merge the two lorebook entries; rewrite narrative as timeline.

**Batch pattern:** `personality_description` dup now 12/12 — universal. KEY new finding: `hexis.narrative` quality is BIMODAL — callisto + denali narratives are properly diachronic (recent careful ports), ao/monika are snapshot re-paraphrases. The narrative defect is NOT universal; it tracks authoring care, not the template. Batch 6 also surfaces lorebook-entry self-overlap (monika) as a fourth slop axis.
