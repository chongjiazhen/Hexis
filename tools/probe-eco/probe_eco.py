# probe_eco.py - per-persona ECO-floor reply quality probe.
#
# Runs N fixed prompts through services.chat.chat_turn against the current
# persona DB (built from POSTGRES_* env). Captures replies, then SCRUBS the
# memories created during the probe so the persona's history stays clean.
#
# Designed to be piped into a persona's worker container:
#   docker exec -i hexis_<persona>_heartbeat_worker python - < probe_eco.py
#
# The container is in /app with services/ on sys.path and POSTGRES_* set, so
# no path or config plumbing is needed here.
#
# Output: JSON to stdout with { persona, probe: [...], scrubbed, broken_count }.
# Auto-flags replies that look like prompt-context leakage or echo loops via
# looks_broken().

import asyncio
import json
import os
import sys

import asyncpg

from services.chat import chat_turn


PROMPTS = [
    "testing 1 2 3",
    "how's your day?",
    "tell me about yourself in one paragraph",
]

# Markers that strongly indicate the 1B model leaked the structured prompt
# template back as the reply (the lovesick-style failure) or fell into an echo
# loop. Used to auto-label probe replies; not exhaustive, refine as we see more.
# NOTE: keep this list in sync with MARKERS in tools/probe-eco/probe_score.py
# (host-side scorer) — they are deliberately separate copies because this file
# is piped into a container with no filesystem siblings, so it cannot import it.
BROKEN_MARKERS = [
    # Prompt-context leakage (1B regurgitating its structured prompt)
    "[USER MESSAGE]",
    "[ASSISTANT MESSAGE]",
    "(score:",
    "## Identity",
    "## Memory",
    "trust: 0.",
    "source: conversation_turn",
    "source: internal",
    # Echo loops
    'echo "',
    # Role confusion / model thinks it's a code REPL or shell
    "Repl>",
    "REPL)",
    "(REPL",
    "print(context",
    "Print(context",
    "context variable",
    # Generic-assistant tells (off-persona drift)
    "I'm an AI",
    "I am an AI",
    "I'm not a human AI",
    "Based on context, it appears",
    "Without additional information",
    "As an AI",
]


def looks_broken(reply: str) -> list[str]:
    return [m for m in BROKEN_MARKERS if m in reply]


def build_dsn() -> str:
    user = os.environ["POSTGRES_USER"]
    pw = os.environ["POSTGRES_PASSWORD"]
    host = os.environ["POSTGRES_HOST"]
    port = os.environ.get("POSTGRES_PORT", "5432")
    db = os.environ["POSTGRES_DB"]
    return f"postgres://{user}:{pw}@{host}:{port}/{db}"


async def main() -> None:
    dsn = build_dsn()
    persona = os.environ["POSTGRES_DB"].replace("hexis_", "", 1)
    # Operator-supplied tier label, passed via `docker exec -e PROBE_MODEL_LABEL`.
    # Identifies which model tier was served for this sweep (e.g. "1b", "4b").
    model_label = os.environ.get("PROBE_MODEL_LABEL", "unlabeled")

    # Snapshot point for scrub. memories.id is uuid (no MAX), so use NOW() only.
    # Caveat: if a heartbeat fires DURING the probe window, that real memory
    # will also be scrubbed. Run when the persona's heartbeat is idle, or pause
    # it first (docker stop hexis_<p>_heartbeat_worker for the probe duration).
    conn = await asyncpg.connect(dsn)
    try:
        snap_ts = await conn.fetchval("SELECT NOW()")
        # asyncpg returns jsonb as raw str unless a codec is set on the
        # connection. The persona workers wire a codec internally; this
        # standalone script does not, so parse defensively.
        llm_cfg_raw = await conn.fetchval("SELECT value FROM config WHERE key = 'llm.chat'")
    finally:
        await conn.close()
    if isinstance(llm_cfg_raw, str):
        llm_cfg = json.loads(llm_cfg_raw)
    else:
        llm_cfg = llm_cfg_raw

    if llm_cfg is None:
        print(json.dumps({"persona": persona, "error": "no llm.chat config"}), flush=True)
        sys.exit(2)

    history: list[dict] = []
    out: list[dict] = []
    for prompt in PROMPTS:
        try:
            r = await chat_turn(
                user_message=prompt,
                history=history,
                llm_config=llm_cfg,
                dsn=dsn,
            )
            history = r["history"]
            reply = r["assistant"]
        except Exception as e:
            reply = f"<probe error: {type(e).__name__}: {e}>"

        out.append(
            {
                "prompt": prompt,
                "reply": reply[:4000],
                "reply_len": len(reply),
                "broken_markers": looks_broken(reply),
            }
        )

    # Scrub. Maintenance worker will recluster from remaining real memories on
    # its next cycle; we don't touch clusters/neighborhoods directly.
    conn = await asyncpg.connect(dsn)
    try:
        deleted = await conn.execute(
            "DELETE FROM memories WHERE created_at >= $1",
            snap_ts,
        )
    finally:
        await conn.close()

    broken_count = sum(1 for r in out if r["broken_markers"])
    result = {
        "persona": persona,
        "model_label": model_label,
        "snap_ts": str(snap_ts),
        "scrubbed": deleted,
        "broken_count": broken_count,
        "probe": out,
    }
    print(json.dumps(result, indent=2, default=str), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
