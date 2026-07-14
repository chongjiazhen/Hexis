"""Tests for session-assessment capture on the chat paths (services.chat).

Coach personas (Vera, Esme, Sable) emit a ``<<SESSION-ASSESSMENT>>`` rubric
block at the end of a practice scene. It must be captured as a strategic
memory and stripped from the user-visible reply.

`chat_turn()` already does this via `_capture_session_assessment()`. These
tests cover the extractor itself and the regression for `stream_chat_turn()`
(the Telegram path), which previously yielded the block raw and stored the
conversation with the block embedded.
"""
import pytest

from core.agent_loop import AgentEvent, AgentEventData
from core.cognitive_memory_api import MemoryType
from services.chat import _extract_session_assessment, stream_chat_turn


# A real Esme reply tail with a well-formed assessment block.
_ESME_REPLY = (
    "Great work this scene.\n\n"
    "<<SESSION-ASSESSMENT>>\n"
    "[session-assessment] 2026-05-22\n"
    "other_focus: 4 - good\n"
    "calibrated_disclosure: 5 - perfect\n"
    "follow_up_questions: 4 - relevant\n"
    "reading_signals: 3 - moved quickly\n"
    "presence_under_nerves: 3 - some strain\n"
    "authenticity: 4 - natural\n"
    "focus_next: calibrated_disclosure\n"
    "<</SESSION-ASSESSMENT>>"
)


def test_extract_well_formed_block():
    cleaned, assessment = _extract_session_assessment(_ESME_REPLY)

    assert assessment is not None
    assert "focus_next:" in assessment
    assert "SESSION-ASSESSMENT" not in cleaned
    assert "[session-assessment]" not in cleaned
    assert "Great work this scene." in cleaned


def test_extract_no_block_returns_unchanged():
    reply = "Just a normal coaching reply, no assessment block."
    cleaned, assessment = _extract_session_assessment(reply)

    assert assessment is None
    assert cleaned == reply


# --- Regression: stream_chat_turn must strip the block -----------------------


class _FakePool:
    """Minimal stand-in; stream_chat_turn only passes it through to mocks."""
    async def close(self):
        pass


class _FakeMemClient:
    """Records remember() calls. Async context manager via CognitiveMemory."""
    def __init__(self):
        self.remember_calls = []

    async def remember(self, content, **kwargs):
        self.remember_calls.append({"content": content, **kwargs})


class _FakeCognitiveMemory:
    """Stand-in for CognitiveMemory; .connect() yields a shared _FakeMemClient."""
    last_client: _FakeMemClient | None = None

    @classmethod
    def connect(cls, dsn):
        client = _FakeMemClient()
        cls.last_client = client

        class _Ctx:
            async def __aenter__(self_):
                return client

            async def __aexit__(self_, *exc):
                return False

        return _Ctx()


@pytest.mark.asyncio
async def test_stream_chat_turn_strips_session_assessment(monkeypatch):
    """stream_chat_turn must NOT leak the rubric block and must store it
    as a strategic memory; the episodic conversation write must be clean."""

    async def _fake_on_cpu_floor():
        return False

    async def _fake_stream_agent(pool, registry, **kwargs):
        # Yield the Esme reply split across several TEXT_DELTA events.
        chunk = len(_ESME_REPLY) // 4 or 1
        for i in range(0, len(_ESME_REPLY), chunk):
            yield AgentEventData(
                event=AgentEvent.TEXT_DELTA,
                data={"text": _ESME_REPLY[i:i + chunk]},
            )

    def _fake_create_default_registry(pool):
        return object()

    async def _fake_get_agent_profile_context(*, pool):
        return {}

    async def _fake_create_pool(dsn, **kwargs):
        return _FakePool()

    monkeypatch.setattr("services.chat.on_cpu_floor", _fake_on_cpu_floor)
    monkeypatch.setattr("services.chat.stream_agent", _fake_stream_agent)
    monkeypatch.setattr(
        "services.chat.create_default_registry", _fake_create_default_registry
    )
    monkeypatch.setattr(
        "services.chat.get_agent_profile_context", _fake_get_agent_profile_context
    )
    monkeypatch.setattr("services.chat.CognitiveMemory", _FakeCognitiveMemory)

    import asyncpg
    monkeypatch.setattr(asyncpg, "create_pool", _fake_create_pool)

    collected: list[str] = []
    async for chunk in stream_chat_turn(
        user_message="Let's practice.",
        history=[],
        llm_config={},
        dsn="postgresql://fake/db",
    ):
        collected.append(chunk)

    visible = "".join(collected)

    # The rubric block must not leak to the user.
    assert "SESSION-ASSESSMENT" not in visible
    assert "[session-assessment]" not in visible
    assert "Great work this scene." in visible

    # A strategic memory must have been written for the assessment, and the
    # episodic conversation write must NOT contain the block.
    client = _FakeCognitiveMemory.last_client
    assert client is not None
    strategic = [
        c for c in client.remember_calls if c.get("type") == MemoryType.STRATEGIC
    ]
    episodic = [
        c for c in client.remember_calls if c.get("type") == MemoryType.EPISODIC
    ]
    assert len(strategic) == 1, "expected one strategic session-assessment memory"
    assert "focus_next:" in strategic[0]["content"]
    assert len(episodic) == 1, "expected one episodic conversation memory"
    assert "SESSION-ASSESSMENT" not in episodic[0]["content"]
    assert "[session-assessment]" not in episodic[0]["content"]
