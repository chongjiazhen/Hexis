"""Per-message response autonomy (C2): the persona may decline to engage.

A persona signals a decline with a leading marker in its reply text:

    [DECLINE:<register>:<reason>]<optional trailing message>

This module parses that marker and renders the user-visible decline. It is pure
and path-agnostic: the same parser runs on the ``assistant_text`` produced by any
chat engine (ECO slim, RLM, run_agent). No I/O, no config — the caller decides
whether to honor the result (see ``chat.decline.enabled``).

Spec: docs/superpowers/specs/2026-06-04-per-message-response-autonomy-design.md
"""
from __future__ import annotations

import re
from dataclasses import dataclass

# Used when the persona picks ``warm`` but supplies no trailing line of its own.
# Decline output must never be empty (silence is indistinguishable from a crash).
WARM_FALLBACK = "(stepping away for now)"

# Leading marker only (anchored to start, after optional whitespace). DOTALL so a
# warm trailing message may span newlines. Register and reason are both optional.
_DECLINE_RE = re.compile(
    r"^\s*\[DECLINE"
    r"(?::(?P<register>warm|cool|ice))?"
    r"(?::(?P<reason>[^\]]*))?"
    r"\]\s*(?P<message>.*)\Z",
    re.IGNORECASE | re.DOTALL,
)


@dataclass(frozen=True)
class Decline:
    register: str          # 'warm' | 'cool' | 'ice'
    reason: str | None     # None when not stated
    visible_text: str      # what the reader actually sees


def classify_decline(text: str) -> Decline | None:
    """Return a ``Decline`` if ``text`` begins with a decline marker, else ``None``.

    ``None`` means "treat as a normal reply" — the fail-open default.
    """
    if not text:
        return None
    m = _DECLINE_RE.match(text)
    if not m:
        return None

    raw_reason = m.group("reason")
    reason = raw_reason.strip() if raw_reason and raw_reason.strip() else None

    register = m.group("register")
    if register:
        register = register.lower()
    elif reason:
        register = "cool"          # reason given, register omitted -> cool
    else:
        register = "ice"           # bare [DECLINE] -> ice, no reason

    message = (m.group("message") or "").strip()
    return Decline(register=register, reason=reason, visible_text=_render(register, reason, message))


def _render(register: str, reason: str | None, message: str) -> str:
    if register == "warm":
        return message or WARM_FALLBACK
    if register == "cool" and reason:
        return f"[DECLINED: {reason}]"
    # ice, or cool with no reason
    return "[DECLINED]"
