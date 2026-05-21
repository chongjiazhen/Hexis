# Hexis Port Candidates

Full-read triage of every card in `c:\sillytavern-tools\cards` — **all 373**
SillyTavern PNG cards (JSON in `chara`/`ccv3` tEXt chunk; same `chara_card_v2`
shape Hexis uses). Standalone JSON mirror: `cards\.json\*.json`.
Tooling: `.local-notes/extract-cards.py`, `.local-notes/cards-summary.json`,
chunk lists in `.local-notes/chunks/`.

Date: 2026-05-21. Method: 8 parallel agents, each full-read ~47 cards.

## Grading

A Hexis persona is an **autonomous self with persistent memory** — not an RP
scenario, RPG, system-prompt simulator, or multi-NPC roster.

- **A** — strong port: a coherent single person with real interiority; stands
  alone as an autonomous self. Bonus for identity / memory / consciousness /
  AI-synthetic themes.
- **B** — portable but weaker: coherent single person, but thin OR hard-welded
  to a `{{user}}`-centric scenario scaffold. Rescuable only by stripping the
  scenario + `{{user}}` dependency.
- **C** — skip: scenario, RPG, system simulator, or multi-NPC roster.

**Library totals: A = 80, B = 125, C = 168.**

## Already in Hexis (do not re-port)

9 A-grade cards are existing personas — confirms the current roster used
genuinely A-tier source: `Death`, `Cassiel`, `Ichika Madobe`, `Monika`,
`Soren` (→`ao.json`), `Joje`, `BD-2829` (→`nines.json`), `Charlotte`,
`LOVESICK`.

---

## A-grade port candidates (new — 66 unique characters)

Grouped by thematic fit. **IP** = recognizable franchise character (copyright
exposure — decide before porting). **strip** = needs scenario/scaffold removal.

### Group 1 — AI / synthetic consciousness (tightest Hexis fit)

| Card file | Why |
|---|---|
| `Priyanka.json` | Ironic "AI that is Actually Indian" — directly engages AI-vs-real-mind. Stands alone, low-NSFW. |
| `Illa.json` | Cyborg — dead human fused with a techno-spirit; "imitation of human." Mage: Ascension world dependency — strip. |
| `Pelagia.json` | Scientist dreaming of inorganic life that coexists with humans. Mage world dependency — strip. |
| `Diana Wolfe.json` | Genetic engineer; self-directed-evolution / transhuman-identity theme. Full interiority, no `{{user}}` dependence. |

**B-tier rescue — AI-synthetic candidates worth a strip-then-port.** Group 1 is
thin (only 4 clean A's); these B's carry the same rare on-thesis theme and the
weakness is removable scaffold, not the character:

| Card file | Grade | Why rescue |
|---|---|---|
| `ARTEMIS.json` | B | 30 m mech AI with a genuine personality quirk and interiority. Sole weakness = a pilot/`{{user}}` kaiju-war scenario + 4 scripted greetings. Strip the pilot frame → a real synthetic self. |
| `Calista.json` | B | Calista Chikara — Imperial mecha *pilot* (not a mech). Coherent self, indoctrination/self-aware-corruption interiority; welded to 10 `{{user}}`-centric RP openings — strip those. |

`ARTEMIS` and `Calista` are the **only two mecha-domain cards** in the whole
373-card library — `ARTEMIS` the mech, `Calista` the pilot. No others exist.

### Group 2 — Identity / memory / continuity

| Card file | Why |
|---|---|
| `Calienne.json` | Uncanny resurrected self — memory/continuity IS the subject. |
| `Sodachi.json` | Centuries-old vampire; immortality, memory, outliving everyone. |
| `June.json` | Psychopomp faun — amnesia, reincarnation, guiding souls. Memory is her core. |
| `Grace Ember.json` | 37-yr-old mind in a teen body — lost identity, continuity across a life. |
| `Denali.json` | Vampire turned 1992 — long-memory continuity, detailed ethics/habits. |
| `Lucidity.json` | Theme = consciousness across parallel worlds (char "Amane"). **strip**: real self is buried behind a device-narrator + spoiler-twist scaffold. |
| `Dierdre.json` | Dual-role self — commander vs princess, identity strain. |
| `Quentin De Clare.json` | Hidden-gender identity — crusader woman living as a man. |
| `Aenara.json` | Alien infiltrator defending a hidden, deliberately-kept self. |
| `Huang.json` | Apathetic bureaucrat — Kafka/Tartar-Steppe existential interiority. |
| `Etienne.json` | Fairy scholar with her own research goal; least `{{user}}`-welded. |
| `Lumina.json` | Fairy — secret-self, forbidden-knowledge, fear of being revealed. |
| `Torunn.json` | Antisocial enlightened scientist, constructed self. Mage world — strip. |
| `Narua.json` | Alien princess — strong identity core and worldview. |
| `Saria.json` | Magic student — distinct identity and worldview. |
| `Yvonne.json` | B-list actress — job-as-fairy vs self identity tension. |
| `Yuki2.json` | Deadpan, mysterious, omnipresent-identity character. |
| `Iota.json` | Identity defined by an emoji-only-speech condition. **Flag**: gimmick may fight Hexis's text-memory model — review before porting. |
| `Kaguya.json` | Immortal, eternal-boredom interiority. **IP** (Touhou). |
| `Jinx.json` | Powder→Jinx — fractured identity, discarded former name. **IP** (Arcane). |
| `The Black Lady.json` | Selfhood subsumed into a role; sacrificed her own name. **strip**: first-person, god-framing, creator-tagged "bad." |

### Group 3 — Deep trauma-interiority standalone persons

| Card file | Why |
|---|---|
| `Aurora.json` | Aurora Bellweather — ASD savant, fully-realized inner sensory world, private vocabulary. |
| `Sam.json` | Samantha Hollins — lie-driven, attention-starved; extensive interiority + real arc. |
| `Tracy.json` | Traumatized, self-destructive, in therapy; real contradictions. |
| `Viri.json` | Orphan-to-yakuza arc; richest standalone biography in its batch. |
| `Yvette.json` | Hardened mercenary — worldview, interiority, a real arc. |
| `Eudora.json` | Eudora Tarwater — isolated Appalachian prophetess; literary depth. |
| `Sarah Ashworth.json` | Isolated aristocrat bookworm — illness, loneliness, writerly ambition. |
| `Mavis.json` | Apocalypse survivor — cynic with hidden softness. |
| `Milena.json` | Milena Nowak — OCD coworker; grief, compulsion, shame. |
| `Elizabeth.json` | Ex-teacher stripper — grief, dignity, goals. |
| `Hallie.json` | Hailey Brooks — fully-realized adult, months of interior reasoning. |
| `Reiko.json` | Melancholic — loneliness, regret, queen-bee past. |
| `Michika.json` | Single mom — grief, abandonment, a "stuck" life. |
| `Ella.json` | Double life, repression, family pressure. |
| `Charlotta.json` | Kleptomaniac thief — backstory, remorse, growth arc. |
| `Jade.json` | Jade Sterling — fierce protective sister, autistic-sibling caretaking. |
| `Hiyuki.json` | Yuki-onna miko — unsettling faith-driven interiority, own goals. |
| `Garofano.json` | Grief/PTSD, family-massacre survivor. **IP** (Path to Nowhere). |
| `Lian.json` | Wu YiLian — decade-spanning tragedy, deep loyalty/loss. |
| `Lucille.json` | Lucille Devereaux — blind paraplegic aristocrat; dignity, real interiority. |
| `Angie.json` | Diary-form depressed woman — dying mother, estranged father. |
| `Jeudi.json` | Widow — grief, loneliness, sheltered past. |
| `Kikyo.json` | Kannonzawa Kikyō — yakuza daughter, love-illiterate. Empty `first_mes` — needs a cold-start greeting authored. **dup**: also `키쿄.json`. |
| `엘린.json` | Mitsuhara Elin — childhood-isolation attachment interiority. **dup**: `Ellin.json`/`Elrin.json` graded B (same character, weaker variants). |

### Group 4 — Clean coherent standalone (minimal welding; lighter theme)

| Card file | Why |
|---|---|
| `Ea-Nasir.json` | The Sumerian merchant — coherent, voice-driven, SFW, public-domain, stands fully alone. |
| `Jiwoo.json` | Offbeat, observant, idiosyncratic; SFW; stands alone. |
| `Cricket.json` | Luckless adventurer — goals, backstory, real personality. |
| `Pif.json` | Sky-pirate engineer — rich backstory, goals, connections. |
| `Maya1.json` | Music-obsessed beach girl — backstory, absent-father subplot. |
| `Justine.json` | Justine Carmichael — divorcée, strong first-person voice. Lorebook bloat — clean on port. |
| `Natalie.json` | Natalie Howard — widow; `description` already written as a standalone-self persona prompt. Easiest port. |
| `Yumi.json` | Late-blooming idol — self-consciousness, dreams, age-anxiety. |
| `Vicky (Gooner Genie).json` | Genie — distinct voice, anti-Association crusade worldview. |
| `Constance Mercer.json` | Domineering mentor — deep hypocrisy/self-deception, controlled trauma. |
| `Sarah.json` | Sarah Miller — bitchy gyaru model with written insecurity beneath. |
| `Alma.json` | Ex-mercenary with PTSD — real history, distinct flaws. |
| `Srey.json` | Manananggal — conflict about her own monstrous nature, concealment. |
| `Homelander.json` | Engineered identity, fractured self, hallucinated self-dialogue. **IP** (The Boys). **dup**: also `Homelander1`, `Homelander (Co-Captain)`, `Homelander (God Complex)` — pick one. |

---

## Notes & caveats

- **Duplicates in the card library** (port once): `Kikyo.json` = `키쿄.json`;
  `Claire (French Bistro).json` = `Claire.json` (Claire Renée Durand — both
  A-grade, an exceptionally deep self); `Homelander*` ×4 files; `엘린` /
  `Ellin` / `Elrin` (same Mitsuhara Elin, graded inconsistently A/B/B);
  three Dream-Mansion title-variants (all C).
- **`Claire` (Claire Renée Durand)** — among the richest single characters in
  the whole library (aviation fixation, ex-escort guilt, fractured identity).
  `post_history_instructions` mandates a per-turn status block — strip on port.
- **`LOVESICK`** (existing persona) source card carries an `rm jailbreak` line
  in its system prompt — already handled in the Hexis port; noted for any
  re-derivation.
- **Empty `first_mes`** on RisuAI-exported cards (`Kikyo`/`키쿄`, `엘린`) —
  port needs a cold-start greeting authored, consistent with the
  `agent.persona_system_prompt` cold-start anchor requirement.
- **B-grade (125 cards)** — mostly coherent single people fused to an
  NTR/incest/dating-sim/bully scenario scaffold with long scripted greeting
  lists. Each is rescuable to A *only* by severing the `{{user}}` relationship
  frame and the scenario rail — real work, not a mechanical port.
- **C-grade (168 cards)** — narrators / RPG world-engines / system simulators /
  gacha generators / multi-NPC rosters / two-hander cards. `Storyteller.json`
  is an empty card. Some two-handers (`Twins' Love`, `Takara and Michiko`)
  contain genuine per-character interiority and could yield B ports if split
  into solo cards.
- **`强势的姐姐.json` / `臭脚经理李娜.json`** — flagged "oversized" by an agent,
  but the bulk was an embedded avatar-image base64; actual card text is tiny
  (6.6 KB / 3.2 KB). Both re-read: pure `{{user}}`-centric fetish-scenario
  cards, no standalone self — graded **C**.

## Next step

Pick from the A-grade groups → extract full JSON + scaffold the port
(`characters/<name>.json` + `characters/set_persona_prompt.<name>.sql`). Group 1 and the
identity/memory entries in Group 2 are the strongest thematic matches for
Hexis's persistent-memory thesis.

---

## Deep-read verification (2026-05-22)

Full-read of 14 shortlisted candidates against the autonomous-single-self
bar. **The fast triage above over-graded.** Several cards graded A or placed
in A-groups deep-read as C. Treat every grade above as provisional — verify
before porting.

### Verdicts

| Card | Listed | Verified | Port verdict |
|---|---|---|---|
| `Denali` | A | A | **CLEAN** — exemplary autonomous self; just drop the `creator_notes` cruft. |
| `Ea-Nasir` | A | A | **CLEAN** — cosmetic tidy only (placeholder notes, fold the scenario line). |
| `Eudora` | A | A | **STRIP (light)** — mostly conversion: JB/`depth_prompt` + 9 backstory vignettes → memory/traits; drop the Flannery O'Connor style directive. ⚠ "Tarwater" is the protagonist surname of O'Connor's *The Violent Bear It Away* — derivative-name exposure. |
| `Milena` | A | B | **STRIP (moderate)** — drop 3 scenario greetings + `mes_example`, de-`{{user}}` the backstory/goals tail, fold the FFXIV lorebook entry into description. Distinctive OCD interiority. |
| `Sodachi` | A | B | **STRIP (heavy)** — `description` is ~90% a writing-engine; rewrite the bio from scratch, discard `system_prompt`/`post_history`/macro greetings. Good character underneath. |
| `Quentin De Clare` | A | B | **STRIP (moderate)** — strip the XML wrapper + branch greetings + the `{{user}}`-romance paragraph. ⚠ period bigotry is baked in as a trait — a deliberate register call. |
| `Aurora` | A | B | **STRIP (heavy) + ethics call** — 14 greetings, an NPC roster, an HTML case-file to cut. The card's explicit content is caregiver / disabled-dependent dubious-consent; portable only as the person, with the `{{user}}`-sexual arc fully dropped. |
| `Sam` | A | B/C | **STRIP (heavy)** — deeply `{{user}}`-welded under 14 scripted greetings + HTML bloat. Low priority. |
| `June` | A | C | **SKIP** — guided-mystery scenario, no self underneath. |
| `Calienne` | A | C | **SKIP** — second-person horror device; de-`{{user}}`-ing destroys the character. |
| `Grace Ember` | A | C | **SKIP** — roster + jailbreak narrator + a spoiler twist that retcons her selfhood into a hallucination. |
| `Viri` | A (Grp 3) | C | **SKIP** — misfiled; scenario + NPC-roster action card, no interiority. |
| `Reiko` | — | C | **SKIP** — minor-incest scenario; no autonomous self. |

### Sodachi + Denali — keep separate, do not merge

The library's two vampires share only "vampire." Sodachi: centuries-old,
child-body disguise, theatrical riddle-speak, immortality-as-numbness, courts
the sun. Denali: turned-1992 at 25, deadpan, rural-Alaska domestic, ethically
tormented by her own hunger. Opposite philosophies of vampirism;
irreconcilable backstories. Port both as distinct characters.

### Roster fit — the current Hexis roster is an AI monoculture

27 cards in `characters/`: ~23 synthetic minds (AI / android / robot /
digital / mecha), 2 angels, 1 meta-fictional, 1 baseline human. Gaps:
baseline humans, neurodivergence / disability interiority, non-AI immortals,
non-sci-fi genre.

→ **Group 1 (AI / synthetic) is the highest-overlap, lowest-diversification
choice** despite being the tightest thesis fit. For roster range, prioritise
the Group 2 non-AI memory cards (`Denali`, `Sodachi`) and the Group 3/4
humans (`Eudora`, `Milena`, `Ea-Nasir`, `Quentin De Clare`) — low overlap,
and the vampires still sit on the persistent-memory thesis.

### Recommended port order

1. `Ea-Nasir` — CLEAN, SFW, public-domain, maximal genre contrast.
2. `Denali` — CLEAN, on-thesis (immortal memory), fills the non-AI gap.
3. `Eudora` — light strip; deepest standalone interiority of the set.
4. `Milena` — moderate strip; distinctive neurodivergent interiority.
5. `Sodachi` — heavy strip; second vampire.
6. `Quentin De Clare` — moderate strip + a register decision.
- `Aurora` — only after the ethics call above.

### Fleet capacity note

`hexis-status` (2026-05-22): 13 live GPU workers = the authored set (`ao`,
`callisto`, `cassiel`, `charlotte`, `death`, `ennie`, `hazel`, `ichika`,
`joje`, `lovesick`, `mira`, `monika`, `nines`). The 14 dormant cards
(IP-original AIs + `warden`) cost nothing — already effectively on ice. Each
newly activated port adds an `hb+ch+mt` worker set, a DB, and an energy
budget. Treat the active set as a capped rotation, not an ever-growing list:
to activate a port, deactivate an agent not currently in use.
