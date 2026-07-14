"""Capability guard (ADR-020 §2): is the live :8090 backend the CPU floor (1B)?

Port-based so it survives the phase-4 router label rename (prime/eco -> gpu/cpu);
the nano floor is :8082 by ADR-017/018 contract regardless of label. Fails OPEN
(False = proceed) on any error — a router blip must never silently degrade a path.
"""
import pytest

from core import serving


@pytest.mark.asyncio
async def test_cpu_floor_when_upstream_is_nano_port(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"status": "ok", "upstream": "http://127.0.0.1:8082", "model": "qwen3-0.6b"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is True


@pytest.mark.asyncio
async def test_not_cpu_floor_when_upstream_is_gpu_port(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"status": "ok", "upstream": "http://127.0.0.1:8080", "model": "qwen36-35b"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is False


@pytest.mark.asyncio
async def test_fails_open_when_router_unreachable(monkeypatch):
    # unreachable / no_upstream (503) -> None -> proceed (False), never silence.
    async def fake_health(url, timeout=2.0):
        return None
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is False


@pytest.mark.asyncio
async def test_trailing_slash_tolerated(monkeypatch):
    async def fake_health(url, timeout=2.0):
        return {"upstream": "http://127.0.0.1:8082/"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is True


@pytest.mark.asyncio
async def test_floor_port_env_override(monkeypatch):
    monkeypatch.setenv("HEXIS_CPU_FLOOR_PORT", "9999")

    async def fake_health(url, timeout=2.0):
        return {"upstream": "http://127.0.0.1:9999"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)
    assert await serving.on_cpu_floor() is True


@pytest.mark.asyncio
async def test_default_health_url_is_reachable_from_a_container(monkeypatch):
    """The default must target the HOST gateway, not loopback.

    Every caller of on_cpu_floor runs inside a container (chat.py -> api,
    worker_service.py -> the *_worker services). In a container 127.0.0.1 is the
    CONTAINER, so a loopback default is refused -> fails open -> on_cpu_floor()
    returns False unconditionally and the guard is silently dead. Measured
    2026-07-14 in hexis_callisto_heartbeat_worker: env unset, 127.0.0.1:8090
    refused, host.docker.internal:8090 -> 200. hexis already reaches the router
    this way for llm.chat / llm.heartbeat; the health probe must match.
    """
    monkeypatch.delenv(serving.ROUTER_HEALTH_URL_ENV, raising=False)
    seen: dict[str, str] = {}

    async def fake_health(url, timeout=2.0):
        seen["url"] = url
        return {"upstream": "http://127.0.0.1:8082"}
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)

    assert await serving.on_cpu_floor() is True
    assert seen["url"] == "http://host.docker.internal:8090/health"


@pytest.mark.asyncio
async def test_health_url_env_override_wins(monkeypatch):
    """A host-native run (no container) overrides back to loopback."""
    monkeypatch.setenv(serving.ROUTER_HEALTH_URL_ENV, "http://127.0.0.1:8090/health")
    seen: dict[str, str] = {}

    async def fake_health(url, timeout=2.0):
        seen["url"] = url
        return None
    monkeypatch.setattr(serving, "fetch_router_health", fake_health)

    await serving.on_cpu_floor()
    assert seen["url"] == "http://127.0.0.1:8090/health"
