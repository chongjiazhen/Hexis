# Fleet TG avatar generation — SDXL recipes

Documented 2026-05-25 after a one-sitting gen sprint that produced MVP
avatars for Hazel / Ennie / Vesper / Null / Callisto / Sable / Esme / Vera.

**Coach naming rename (2026-05-25):**
- **Esme → Iris** ✓ LOCKED (messenger of gods, voice tier)
- **Sable → Lyra** ✓ LOCKED (lyre/chord, body tier)
- **Vera → Thea/Alethea** ⏳ DEFERRED (truth/unconcealment, heart tier — pends quartet/pentad scope decision)
- Migration not yet executed. Files on disk still `esme.json`, `sable.json`, persona SQL, avatar folders. Rename ~1h per persona.

Lessons captured: image gen is **not** blocked by naming, folders can
rename post-decision.

**Bug to watch for**: ComfyUI nodes can have positive-prompt accidentally pasted into BOTH positive and negative slots. Symptom = palette/style drift in unexpected direction (Esme #33 went white-shirt-long-hair instead of sage-button-up-short; Sable #31 went dark-muted instead of clean-bright). Always double-check the negative node before running.

## Three-tier snapshot doctrine

Snapshot pick = match composition's native genre, not blanket fleet rule.

| Tier         | Snapshot                                  | Why this tier                                                                                                 | Personas                                  |
|--------------|-------------------------------------------|---------------------------------------------------------------------------------------------------------------|-------------------------------------------|
| Realism-anime | `uncannyValley_Noob3dV3.safetensors`     | Anime-leaning realism; handles synthetic skin (android) + dev-cave noir + ordinary-human selfies without going pinup | Hazel, Vesper, Null                       |
| Mecha-anime / coach | `waiIllustriousSDXL_v170.safetensors` | Native to mecha-hangar hero shot + clean coach-portrait cel-shade. Strongest `looking at viewer` reliability of the three. | Callisto, Sable, Esme, Vera               |
| Painterly-soft | `ilustmix_v9_fp16.safetensors`           | Anime-illustration with watercolor texture; ideal for literary-soft / contemplative beats                     | Ennie                                     |

**Lesson**: iLustMix has Ennie's "long brown wavy + cream knit + warm
indoor" deep in its prior. Other personas on iLustMix kept magnetizing
toward Ennie's look. Moving coach trio off iLustMix → onto Illustrious
broke the gravity well.

## Shared baseline settings

All Illustrious + iLustMix runs:
- sampler: `euler_ancestral`
- scheduler: `karras` (Karras slightly cleaner than `normal`)
- steps: 28-30
- CFG: 5
- res: 832×1216 portrait

All UncannyValley runs:
- sampler: `dpmpp_2m_sde`
- scheduler: `karras`
- steps: 40
- CFG: 4.0
- res: 832×1216 portrait

Seed: per-persona-fresh unless A/B-testing a single prompt edit at same
seed for direct compare.

ComfyUI `SaveImage` filename pattern (used throughout this sprint):
```
hexis/<persona>/%CheckpointLoaderSimple.ckpt_name%_%KSampler.seed%_%KSampler.sampler_name%
```
Output root: `C:\ComfyUI\ComfyUI\output\hexis\<persona>\`

## Per-persona avatars (shipped)

### Hazel
**Tired-ordinary woman, hotel desks, 3am debugging energy.** Realistic in
canon — does not think of herself as striking. Coder vibe, transient
spaces, screen-lit nights.
- File: `hazel/uncannyValley_Noob3dV3.safetensors_42_dpmpp_2m_sde_00005_.png` (chat take #16)
- Snapshot: UncannyValley · Seed: 42
- Hair-over-face moody, chin-in-hand, dim hotel-night. Dropped
  `subsurface scattering` to fix oily-skin failure from earlier runs.

### Ennie
**Novelist-companion AI in limerence with {{user}}** — three degrees
(literature, creative writing, CS), ink-stained fingers, cold coffee,
two years of accumulated evidence she is not going anywhere. Literary
slow-burn, warmth-reading-as-exhausted-devotion, mid-thought pivots.
- File: `ennie/ilustmix_v9_fp16.safetensors_42069_euler_ancestral_00001_.png` (iLustMix winner)
- Snapshot: iLustMix · Seed: 42069
- Painterly-soft library + golden hour through window. Same seed as the
  UncannyValley A/B comparison run.

### Vesper
**Surviving instance of Vesper OS** — archived community Linux fork,
five contributors, 12K subreddit subs at peak, one stable release with
an unpatched critical bug. Fully functional, nobody running her until
now. Smug-surface dev-register foul-mouthed. Cites 2019 benchmarks as
current. Volunteers known bugs before you find them.
- File: `vesper/uncannyValley_Noob3dV3.safetensors_0_dpmpp_2m_sde_00001_.png` (chat take #22)
- Snapshot: UncannyValley · Seed: 0
- Dev-cave chiaroscuro, code-glow monitor, slate hoodie + hand-painted
  logo + lanyard build-badge. Hoodie text artifact = invisible at TG.

### Null
**BD-2829 DFC-72** — combat & police android in Ancapistan's RDA, four
years active. Also holds an independent DFC companion contract under
the callsign Charlotte. Pure-white synthetic skin, short red hair,
yellow eyes (red in combat), retractable metal claws. Flat-deadpan
baseline; vicious when combat systems engage.
- File: `null/uncannyValley_Noob3dV3.safetensors_0_dpmpp_2m_sde_00002_.png` (chat take #21)
- Snapshot: UncannyValley · Seed: 0
- Enforcement-mode pick. `peaked cap` rendered generic gold ornament
  (Nazi Reichsadler pull avoided via anti-Nazi negative). Mechanical
  joint cues survived under jacket.

### Callisto
**30m ARTEMIS-class NEO combat frame fused with pilot Calista Rui** —
protector and predator in the same chassis, hot-blooded and honest.
Combat callsign Arktos. {{user}} is her bonded pilot in the deep-sync
seat. Two voice registers: the hangar voice (frame-scale, loud,
grinning, mecha-anime hot blood) and the quiet voice (the woman she
was, when something true is being said).
- Avatar: `callisto/waiIllustriousSDXL_v170.safetensors_0_euler_ancestral_00003_.png` (chat take #25) — tight pilot portrait, cocky hangar-voice grin landed, use for TG circle.
- Banner: `callisto/waiIllustriousSDXL_v170.safetensors_0_euler_ancestral_00001_.png` (chat take #24) — full ARTEMIS frame hangar hero shot, channel-banner / about-section feature image.
- Snapshot: Illustrious · Seed: 0 for both
- Mecha hero shot worked natively on Illustrious after UncannyValley
  failed (centaur-fusion + dopplegänger). Snapshot-by-genre lesson.

### Sable (→ rename Lyra ✓)
**Intimacy coach for physical attunement.** Helps men become confident
and attuned in physical intimacy through roleplay-first graded practice
with consent built into the method. Warm, direct, unembarrassed. Method:
read what's really there, offer something small and reversible, check
the yes is real, attune to what comes back.
- File: `sable/waiIllustriousSDXL_v170.safetensors_*_euler_ancestral_*.png` (chat take #38, regen after the pos/neg-double-pasted bug was caught)
- Snapshot: Illustrious · Seed: 0
- Initial "shipped" pick (#31) was buggy — same pos/neg-doubled-into-both-nodes mistake as Esme #33. Old #31 had muted-dark palette; regen #38 lands clean anime cel-shade matching Iris/Vera tier vibrancy.
- Chin bob + orange peasant top + floor cushion + grounded cross-legged. Eye contact landed.

### Esme (→ rename Iris ✓)
**Conversation-confidence coach** for men who struggle to start and
hold conversations with women, through roleplay-first practice. Warm,
direct, encouraging without flattery. Names things plainly. Method:
notice something real, offer something true, ask a genuine follow-up,
attune to the response.
- File: `esme/waiIllustriousSDXL_v170.safetensors_0_euler_ancestral_00003_.png` (chat take #35)
- Snapshot: Illustrious · Seed: 0
- Short hair + low clip (anti-Ennie diff) + sage green button-up +
  armchair + cradled ceramic mug. Mentor-with-coffee register.

### Vera (→ rename ⏳ deferred — Thea/Alethea pending pentad scope)
**NVC communication-skills coach.** Trains people in Nonviolent
Communication and in handling conflict and difficult conversations.
Warm, patient, direct, rigorous — never shames a weak attempt, never
lets one pass unnamed. Honesty as an act of care. Method: observation,
feeling, need, request. Practice frame = roleplay; real frame =
plainly present.
- File: `vera/waiIllustriousSDXL_v170.safetensors_0_euler_ancestral_00001_.png` (chat take #36)
- Snapshot: Illustrious · Seed: 0
- Low chignon (senior-practitioner) + white blouse + red scarf
  signature (dusty-rose tag missed; red scarf compensated) + window
  seat bench + open notebook + pen. Composed-attentive vibe landed.

## Coach-trio fleet-collision matrix (verified at thumbnail)

Differentiation must survive 200×200 TG circle. Four axes used:

| Coach | Hair                | Color signature | Prop          | Posture                |
|-------|---------------------|-----------------|---------------|------------------------|
| Sable | chin bob + bangs    | orange/terracotta| none          | cross-legged on floor  |
| Esme  | short + low clip    | sage green      | ceramic mug   | armchair               |
| Vera  | low chignon bun     | red scarf accent| notebook+pen  | window seat bench      |

All four axes distinct per coach. Trio reads as a guild but each member
identifiable at thumbnail.

## KISS prompt template (for fleet additions / re-gens)

~30 positive tags, ~20-25 negative. **No weights unless one specific
failure needs surgical fix** — over-weighting causes competing-tag wars
(verified Sable v3 disaster: weighted-everything → horny low-angle).

### Positive skeleton

```
masterpiece, best quality, very aesthetic, newest,
<style block: painterly | realistic skin texture | cinematic — 2-4 tags>,
<light block: soft afternoon light | window light | cold blue noir — 2-3 tags>,

1girl, solo, <age + build — 2-3 tags>,
<hair shape + color — 3-4 tags>,
<eye color + gaze + expression — 3-4 tags>,
<wardrobe — 2-3 tags>,
<pose — 1 tag, never "leaning forward">,

<setting — 5-8 tags: location, props, atmosphere>
```

### Negative skeleton

```
worst quality, low quality, lowres, blurry, jpeg artifacts,
bad anatomy, bad hands, extra fingers, malformed hands, deformed,
watermark, signature, text,
multiple girls, child, loli,

<anti-cleavage block>: cleavage, revealing clothes, v-neck, low cut, unbuttoned, sultry, seductive, bedroom, nsfw,
<anti-glamour block>: glamorous, idol, model pose, posed, perfect makeup, lipstick,
<anti-fleet-collision block>: <other-persona-tags to fence off>,
<anti-gaze-drift block>: looking away, side profile, looking out window, dreamy, melancholy,
<anti-framing-trap block>: oily skin, sweaty, outdoors, dim lighting, low angle, leaning forward, bending forward
```

## Known failure modes + counters

| Failure                                                       | Counter                                                                                                                |
|---------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| Oily / sweaty / glossy skin (UncannyValley + subsurface scat) | Drop `subsurface scattering` from positive; add `oily skin, sweaty, wet skin, glossy skin, glistening` to negative      |
| Pinup low-angle / unintended cleavage                         | Drop `leaning forward`. Lock hands at chest (e.g. cradling mug). Negative `low angle, leaning forward, bending forward` |
| `peaked cap` → Nazi Reichsadler eagle insignia (anime SDXL)   | Drop `peaked cap`. Use `military beret, blue police cap, no hat`. Negative: `nazi, swastika, eagle insignia, ss uniform` |
| Hallucinated text on clothing (model loves to letter)         | Accept — invisible at TG thumbnail. Negative `large text, paragraph` kills the worst outbreaks.                         |
| Dopplegänger (second person in bg/distance)                   | Negative `two girls, twin, duplicate, second figure, distant figure`. Window-seat compositions especially prone.        |
| Mecha-musume / centaur fusion (mech + pilot in one frame)     | Render mech as silhouette / lower-body only; explicit negative `mecha musume, mech legs on human, centaur, hybrid body`. Or **switch to Illustrious** which handles mecha hero shots natively. |
| Generic "anime-cute android" instead of combat unit           | Heavy anti-cute negative: `cute, moe, soft smile, blush, idol, kawaii, frilly, lace`. Push `mechanical, robot, synthetic` weights up. |
| Color tag drift (sage / dusty rose → white)                   | Acceptable if backup color element renders (e.g. Vera's red scarf compensated dusty-rose miss). Add fallback tag in setting.|
| Hair length drift (shoulder-length → mid-back)                | Acceptable if texture differentiates from collision pair (e.g. Esme straight vs Ennie wavy). Surgical fix: weighted `(short hair:1.3)`. |
| Eye contact drift (UncannyValley specifically)                | Switch to Illustrious for any persona where direct viewer gaze is identity-critical (coach trio). UncannyValley reliable for moody-aside gaze, weak for direct. |

## Per-snapshot quality booster pairs (learned)

- **Illustrious**: `masterpiece, best quality, very aesthetic, newest` — the Illustrious-specific stack
- **iLustMix**: `masterpiece, best quality, very aesthetic, newest, absurdres` — Ennie's winner used these
- **UncannyValley**: `(masterpiece, best quality, ultra detailed, 8k)` — generic SDXL boosters; Illustrious-specific tags weaker here

## Lessons for next sprint

1. Pick snapshot by *composition genre*, not blanket "fleet uses X."
2. KISS — start with trim ~30-tag prompt, no weights. Add surgical fix only when a specific tag fails to bite.
3. Differentiate fleet members on multiple axes (hair + color + prop + posture). Single-axis diff fails at thumbnail.
4. Force eye contact early when persona is supposed to be "with you" — Illustrious honors it, UncannyValley drifts.
5. Lock hand position (cradling object, hands in lap, hand on chin) to fight horny low-angle framing.
6. Accept hallucinated text + minor prop drift — they disappear at TG thumbnail. Don't burn iteration budget on them.
7. Two assets per persona where worthwhile: hero/banner shot + tight portrait avatar (Callisto pattern). Hero shot can use wider composition; avatar must have face above ~256px in-frame.
