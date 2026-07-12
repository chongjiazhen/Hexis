"""Capability guard (ADR-020 §2): skip autonomous cycles when the live :8090
backend is the CPU floor (1B), which can't follow the tool template and would
write garbage to episodic memory. Port-based so it survives the phase-4 router
label rename (prime/eco -> gpu/cpu); the nano floor is :8082 by ADR-017/018
contract regardless of label. Fails OPEN (proceed) on any error — never silently
silences the fleet.
"""
import pytest

from services import worker_service as ws


@pytest.mark.asyncio
async def test_cpu_floor_when_upstream_is_nano_port(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"status": "ok", "upstream": "http://127.0.0.1:8082", "model": "qwen3-0.6b"}
    monkeypatch.setattr(ws, "_fetch_router_health", fake_health)
    assert await ws._on_cpu_floor() is True


@pytest.mark.asyncio
async def test_not_cpu_floor_when_upstream_is_gpu_port(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"status": "ok", "upstream": "http://127.0.0.1:8080", "model": "qwen36-35b"}
    monkeypatch.setattr(ws, "_fetch_router_health", fake_health)
    assert await ws._on_cpu_floor() is False


@pytest.mark.asyncio
async def test_fails_open_when_router_unreachable(monkeypatch):
    # unreachable / no_upstream (503) -> None -> proceed (False), never silence.
    async def fake_health(url, timeout=2.0):
        return None
    monkeypatch.setattr(ws, "_fetch_router_health", fake_health)
    assert await ws._on_cpu_floor() is False


@pytest.mark.asyncio
async def test_trailing_slash_tolerated(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"upstream": "http://127.0.0.1:8082/"}
    monkeypatch.setattr(ws, "_fetch_router_health", fake_health)
    assert await ws._on_cpu_floor() is True


@pytest.mark.asyncio
async def test_floor_port_env_override(monkeypatch):
    monkeypatch.setenv("HEXIS_CPU_FLOOR_PORT", "9999")
    async def fake_health(url, timeout=2.0):
        return {"upstream": "http://127.0.0.1:9999"}
    monkeypatch.setattr(ws, "_fetch_router_health", fake_health)
    assert await ws._on_cpu_floor() is True
