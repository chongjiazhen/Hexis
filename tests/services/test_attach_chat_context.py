"""Tests for attach_chat_context (services.agent).

Hydrated per-turn context (subconscious signals, recalled memories, identity,
beliefs) must be folded into the SYSTEM prompt for chat mode — not the user
turn. When it sat in the user message, leak-prone local models echoed it back
and misattributed it to the user ("you provided me with my Subconscious
Signals...").
"""
from services.agent import SubconsciousOutput, attach_chat_context


def test_memory_context_appended_to_system_prompt():
    sp = "You are Vera, a coach."
    mem = "## Relevant Memories\n- User skipped the need last session."
    result = attach_chat_context(sp, SubconsciousOutput(), mem)

    assert result.startswith(sp)
    assert mem in result
    assert result != sp


def test_no_context_returns_system_prompt_unchanged():
    sp = "You are Vera, a coach."
    # empty SubconsciousOutput -> no signals; no memory context
    result = attach_chat_context(sp, SubconsciousOutput(), None)

    assert result == sp


def test_subconscious_signals_and_memory_both_appended():
    sp = "You are Vera."
    sub = SubconsciousOutput(
        instincts=[{"impulse": "reassure", "intensity": 0.6, "reason": "user tense"}]
    )
    mem = "## Identity\n- A communication coach."
    result = attach_chat_context(sp, sub, mem)

    assert result.startswith(sp)
    assert "## Subconscious Signals" in result
    assert "reassure" in result
    assert "## Identity" in result


def test_empty_subconscious_output_with_no_memory_is_noop():
    sp = "system prompt"
    assert attach_chat_context(sp, SubconsciousOutput(), "") == sp
