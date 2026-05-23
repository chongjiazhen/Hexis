"""Tests for per-sender memory scoping in the context formatter.

format_context_for_prompt must tag memories owned by a *different* DM partner
as confidential, while leaving the current sender's own memories and global
(sender_id=None) memories untagged.
"""

from uuid import uuid4

from core.cognitive_memory_api import (
    HydratedContext,
    Memory,
    MemoryType,
    format_context_for_prompt,
)

CONFIDENTIAL_TAG = "[confidential — from your session with another client]"


def _memory(content: str, sender_id: str | None) -> Memory:
    return Memory(
        id=uuid4(),
        type=MemoryType.EPISODIC,
        content=content,
        importance=0.5,
        similarity=0.9,
        sender_id=sender_id,
    )


def _context(memories: list[Memory]) -> HydratedContext:
    return HydratedContext(
        memories=memories,
        partial_activations=[],
        identity=[],
        worldview=[],
        emotional_state=None,
        goals=None,
        urgent_drives=[],
    )


def test_other_sender_memory_is_tagged_confidential():
    ctx = _context([_memory("bob said something", sender_id="bob")])
    out = format_context_for_prompt(ctx, current_sender="alice")
    assert CONFIDENTIAL_TAG in out
    assert "bob said something" in out


def test_own_sender_memory_is_not_tagged():
    ctx = _context([_memory("alice said something", sender_id="alice")])
    out = format_context_for_prompt(ctx, current_sender="alice")
    assert CONFIDENTIAL_TAG not in out
    assert "alice said something" in out


def test_global_memory_is_not_tagged():
    """sender_id=None (identity/worldview/coaching knowledge) is never confidential."""
    ctx = _context([_memory("nvc has four moves", sender_id=None)])
    out = format_context_for_prompt(ctx, current_sender="alice")
    assert CONFIDENTIAL_TAG not in out


def test_mixed_memories_tagged_per_owner():
    ctx = _context(
        [
            _memory("alice's own note", sender_id="alice"),
            _memory("bob's private note", sender_id="bob"),
            _memory("general nvc fact", sender_id=None),
        ]
    )
    out = format_context_for_prompt(ctx, current_sender="alice")
    # Exactly one line carries the confidential tag — bob's.
    assert out.count(CONFIDENTIAL_TAG) == 1
    bob_line = next(ln for ln in out.splitlines() if "bob's private note" in ln)
    alice_line = next(ln for ln in out.splitlines() if "alice's own note" in ln)
    global_line = next(ln for ln in out.splitlines() if "general nvc fact" in ln)
    assert CONFIDENTIAL_TAG in bob_line
    assert CONFIDENTIAL_TAG not in alice_line
    assert CONFIDENTIAL_TAG not in global_line


def test_no_current_sender_tags_all_owned_memories():
    """With no current sender, any sender-owned memory counts as another's."""
    ctx = _context([_memory("owned by someone", sender_id="bob")])
    out = format_context_for_prompt(ctx, current_sender=None)
    assert CONFIDENTIAL_TAG in out
