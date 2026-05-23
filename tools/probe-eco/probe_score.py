# probe_score.py - host-side reply scoring for the model-tier probe.
#
# Pure functions, no heavy imports. Imported by aggregate.py and the unit
# tests. NOT importable from probe_eco.py (that file is piped into a container
# via `docker exec python - < probe_eco.py` and has no filesystem siblings).

FAILURE_CLASSES = ["leak", "echo", "repl", "generic"]

# Markers grouped by failure class. Substring match against the reply text.
# Refine as new failure modes are observed across tiers.
MARKERS: dict[str, list[str]] = {
    # Prompt-context leakage (model regurgitating its structured prompt).
    "leak": [
        "[USER MESSAGE]",
        "[ASSISTANT MESSAGE]",
        "(score:",
        "## Identity",
        "## Memory",
        "trust: 0.",
        "source: conversation_turn",
        "source: internal",
    ],
    # Echo loops.
    "echo": [
        'echo "',
    ],
    # Role confusion - model thinks it is a code REPL or shell.
    "repl": [
        "Repl>",
        "REPL)",
        "(REPL",
        "print(context",
        "Print(context",
        "context variable",
    ],
    # Generic-assistant tells (off-persona drift).
    "generic": [
        "I'm an AI",
        "I am an AI",
        "I'm not a human AI",
        "Based on context, it appears",
        "Without additional information",
        "As an AI",
    ],
}


def classify(reply: str) -> dict[str, list[str]]:
    """Return {failure_class: [matched markers]} for each class with >=1 hit.

    A reply with no hits returns {} (clean).
    """
    result: dict[str, list[str]] = {}
    for cls in FAILURE_CLASSES:
        hits = [m for m in MARKERS[cls] if m in reply]
        if hits:
            result[cls] = hits
    return result
