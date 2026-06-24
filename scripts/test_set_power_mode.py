"""Unit tests for the power-mode applier's transient-retry path.

Lives in scripts/ (not tests/) on purpose: tests/conftest.py has an autouse
fixture that provisions a real Postgres per module. These tests mock asyncpg
entirely — no live DB — so they stay out of that subtree.

Run: C:\\hexis\\venv\\Scripts\\python.exe -m pytest scripts/test_set_power_mode.py -q
"""
import asyncio
import os
import sys
from unittest import mock

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import set_power_mode as spm  # noqa: E402


def _fake_conn():
    conn = mock.AsyncMock()
    conn.execute = mock.AsyncMock()
    conn.fetchrow = mock.AsyncMock(return_value=None)
    conn.close = mock.AsyncMock()
    return conn


_ECO_ENTRIES = {"llm.chat": {"model": "qwen3-0.6b"}, "agent.power_mode": "eco"}


async def test_apply_instance_retries_transient_then_succeeds():
    # GPU cold-load starves PG -> first two connects time out, third lands.
    conn = _fake_conn()
    connect = mock.AsyncMock(
        side_effect=[asyncio.TimeoutError(), asyncio.TimeoutError(), conn]
    )
    with mock.patch.object(spm.asyncpg, "connect", connect), \
         mock.patch.object(spm.asyncio, "sleep", mock.AsyncMock()) as slept:
        await spm.apply_instance("dsn", "hexis_x", _ECO_ENTRIES)
    assert connect.await_count == 3          # retried past the two timeouts
    assert slept.await_count == 2            # backoff between attempts
    conn.close.assert_awaited_once()         # the connected handle was closed


async def test_apply_instance_raises_after_exhausting_retries():
    # Persistent failure must still surface (loud) once retries are spent, so
    # the caller reports the DB flip failed rather than silently skipping it.
    connect = mock.AsyncMock(side_effect=asyncio.TimeoutError())
    with mock.patch.object(spm.asyncpg, "connect", connect), \
         mock.patch.object(spm.asyncio, "sleep", mock.AsyncMock()):
        with pytest.raises(asyncio.TimeoutError):
            await spm.apply_instance("dsn", "hexis_x", _ECO_ENTRIES)
    assert connect.await_count == spm._APPLY_ATTEMPTS


async def test_apply_instance_no_retry_on_success():
    conn = _fake_conn()
    connect = mock.AsyncMock(return_value=conn)
    sleep = mock.AsyncMock()
    with mock.patch.object(spm.asyncpg, "connect", connect), \
         mock.patch.object(spm.asyncio, "sleep", sleep):
        await spm.apply_instance("dsn", "hexis_x", _ECO_ENTRIES)
    assert connect.await_count == 1
    sleep.assert_not_awaited()               # happy path pays no backoff


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
