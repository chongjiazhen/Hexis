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

# Used when the persona picks ``gentle`` but supplies no trailing line of its own.
# Decline output must never be empty (silence is indistinguishable from a crash).
GENTLE_FALLBACK = "(stepping away for now)"

# Leading marker only (anchored to start, after optional whitespace). DOTALL so a
# gentle trailing message may span newlines. Register and reason are both optional.
_DECLINE_RE = re.compile(
    r"^\s*\[DECLINE"
    r"(?::(?P<register>gentle|plain|blunt))?"
    r"(?::(?P<reason>[^\]]*))?"
    r"\]\s*(?P<message>.*)\Z",
    re.IGNORECASE | re.DOTALL,
)


@dataclass(frozen=True)
class Decline:
    register: str          # 'gentle' | 'plain' | 'blunt'
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
        register = "plain"         # reason given, register omitted -> plain
    else:
        register = "blunt"         # bare [DECLINE] -> blunt, no reason

    message = (m.group("message") or "").strip()
    return Decline(register=register, reason=reason, visible_text=_render(register, reason, message))


def _render(register: str, reason: str | None, message: str) -> str:
    if register == "gentle":
        return message or GENTLE_FALLBACK
    if register == "plain" and reason:
        return f"[DECLINED: {reason}]"
    # blunt, or plain with no reason
    return "[DECLINED]"
