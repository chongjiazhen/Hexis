# Custom Characters

Yes — Hexis supports custom character cards.

## Locations

Search order (first-seen filename wins):

1. `HEXIS_CHARACTERS_DIR` env var (highest priority, Docker/CI overrides)
2. `~/.hexis/characters/` (user custom cards)
3. `characters/` in the package directory (shipped presets, read-only)

User cards in `~/.hexis/characters/` override presets with matching filenames.

## Three ways to add a card

### 1. CLI

```bash
hexis characters create --name "MyBot" --voice "cheerful and direct" --values "honesty,growth"
hexis characters import /path/to/card.json
hexis characters export myagent
hexis characters list
hexis characters show jarvis
```

### 2. Web UI

- **Character** stage → **Import Card** to load a `.json` file
- **Custom** stage → **Save as Character Card** to export current config

### 3. Manual

1. Create `.json` in `~/.hexis/characters/` following the format below
2. Optionally add a matching 300x300 `.jpg` portrait
3. Run `hexis init` — card appears in selection list

## Card format (chara_card_v2)

```json
{
  "spec": "chara_card_v2",
  "spec_version": "2.0",
  "data": {
    "name": "Character Name",
    "description": "...",
    "personality": "trait1, trait2, ...",
    "scenario": "...",
    "first_mes": "...",
    "mes_example": "...",
    "system_prompt": "...",
    "extensions": {
      "hexis": {
        "name": "Character Name",
        "description": "...",
        "voice": "warm and curious",
        "values": ["honesty", "growth", "kindness"],
        "personality_description": "...",
        "big_five": {
          "openness": 0.85,
          "conscientiousness": 0.70,
          "extraversion": 0.60,
          "agreeableness": 0.75,
          "neuroticism": 0.30
        },
        "worldview": [
          { "belief": "...", "confidence": 0.9 }
        ],
        "goals": [
          { "description": "...", "priority": "active" }
        ],
        "boundaries": [
          "I will not..."
        ]
      }
    }
  }
}
```

## The `extensions.hexis` block

When `hexis init` applies a card, it reads `extensions.hexis` and:

1. Sets agent **name**, **description**, **voice**
2. Stores **Big Five** traits as worldview memories (`metadata.subcategory='personality'`)
3. Creates **worldview** beliefs with confidence scores
4. Creates **goals** with priority levels (`active`, `queued`, `backburner`)
5. Sets **boundaries** the agent can enforce
6. Stores **values** as core identity markers

If `extensions.hexis` is pre-populated, init skips the LLM personality-extraction step — card application is instant.

If absent (e.g. SillyTavern card), init wizard runs LLM call to extract personality traits from `description` + `system_prompt`.

## Portraits

`.jpg` with same base name as JSON (e.g. `mybot.jpg` next to `mybot.json`). 300x300 recommended. Shown in web UI during character selection.
