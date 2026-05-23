#!/usr/bin/env python3
"""Generate set_persona_prompt.<name>.sql from character card JSON.

The hexis runtime sends the LLM only `agent.persona_system_prompt`, loaded
from a characters/set_persona_prompt.<name>.sql file. That value is the
card's `data.system_prompt` + `data.post_history_instructions`, with the
{{user}} and {{char}} placeholders resolved. The .sql files are not produced
by any build step, so they drift out of date whenever a card's system_prompt
or post_history_instructions is edited.

This regenerates them from characters/<name>.json.

    python scripts/gen_persona_sql.py                 # refresh every card
                                                      #   that already has a
                                                      #   set_persona_prompt.*.sql
    python scripts/gen_persona_sql.py monika death     # regenerate only these
                                                      #   (creates the .sql if new)

Output files are written to characters/. The runtime is NOT touched -- apply
a file to a running instance by executing it against that instance's database
(e.g. psql / docker exec); it takes effect next turn.

Note: only `system_prompt` and `post_history_instructions` reach the model
this way. The rest of the hexis extension block (description, narrative,
values, worldview, ...) is consumed by `init_from_character_card()` at init
time only and is not carried by this generator.

stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHARACTERS_DIR = REPO_ROOT / "characters"
CONFIG_KEY = "agent.persona_system_prompt"
USER_NAME = "User"


def _dollar_tag(stem: str, text: str) -> str:
    """Pick a Postgres dollar-quote tag guaranteed not to occur in the text."""
    base = re.sub(r"[^A-Za-z0-9]", "", stem).upper() or "PERSONA"
    candidate = f"${base}PRMT$"
    if candidate not in text:
        return candidate
    n = 1
    while f"${base}PRMT{n}$" in text:
        n += 1
    return f"${base}PRMT{n}$"


def build_persona_text(card: dict) -> str | None:
    """Return the persona prompt text for a card, or None if it has no system_prompt."""
    data = card.get("data", {})
    system_prompt = (data.get("system_prompt") or "").strip()
    if not system_prompt:
        return None
    post_history = (data.get("post_history_instructions") or "").strip()
    text = system_prompt + ("\n\n" + post_history if post_history else "")
    return text.replace("{{char}}", data.get("name", "")).replace("{{user}}", USER_NAME)


def generate(stem: str) -> Path | None:
    """Regenerate set_persona_prompt.<stem>.sql. Returns the path written, or None."""
    src = CHARACTERS_DIR / f"{stem}.json"
    if not src.is_file():
        print(f"  skip {stem}: no {src.name}", file=sys.stderr)
        return None
    try:
        card = json.loads(src.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"  skip {stem}: cannot parse ({exc})", file=sys.stderr)
        return None
    text = build_persona_text(card)
    if text is None:
        print(f"  skip {stem}: card has no system_prompt", file=sys.stderr)
        return None
    tag = _dollar_tag(stem, text)
    sql = (
        f"INSERT INTO config (key, value) VALUES ('{CONFIG_KEY}', "
        f"to_jsonb({tag}{text}{tag}::text)) "
        f"ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;\n"
    )
    dest = CHARACTERS_DIR / f"set_persona_prompt.{stem}.sql"
    dest.write_text(sql, encoding="utf-8", newline="\n")
    print(f"  wrote {dest.name} ({len(text)} chars)")
    return dest


def _existing_stems() -> list[str]:
    """Stems that already have a characters/set_persona_prompt.*.sql file."""
    prefix, suffix = "set_persona_prompt.", ".sql"
    return sorted(
        p.name[len(prefix):-len(suffix)]
        for p in CHARACTERS_DIR.glob("set_persona_prompt.*.sql")
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Regenerate persona SQL from character cards."
    )
    parser.add_argument(
        "names",
        nargs="*",
        help="card stems to regenerate (default: every card that already "
        "has a set_persona_prompt.*.sql file)",
    )
    args = parser.parse_args(argv)

    stems = args.names or _existing_stems()
    if not stems:
        print("nothing to do: no card stems given and no existing persona SQL")
        return 0

    written = sum(generate(stem) is not None for stem in stems)
    print(f"done: {written}/{len(stems)} file(s) written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
