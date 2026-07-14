"""Live serving-capability probe (ADR-020 §2).

The :8090 inference router (llm-serve, ADR-019) fails over between the GPU
backend (:8080) and the CPU floor (nano, :8082). Some hexis paths must know
which one is actually live: the 1B floor cannot follow the Hexis tool template,
so autonomous cycles on it emit garbage that corrupts episodic memory, and the
chat path must use its slim direct-LLM variant instead of the heavy template.

This reads serving *capability*; it is not a resurrection of the retired power-mode
DB flag (ADR-020). No DB, no operator gesture — just what is live right now.
"""
from __future__ import annotations

import os
from typing import Any

ROUTER_HEALTH_URL_ENV = "HEXIS_ROUTER_HEALTH_URL"
DEFAULT_ROUTER_HEALTH_URL = "http://127.0.0.1:8090/health"
CPU_FLOOR_PORT_ENV = "HEXIS_CPU_FLOOR_PORT"
DEFAULT_CPU_FLOOR_PORT = "8082"


async def fetch_router_health(url: str, timeout: float = 2.0) -> dict[str, Any] | None:
    """GET the :8090 router /health; parsed JSON dict, or None on any error /
    non-200 (503 no_upstream included). Thin HTTP seam so on_cpu_floor's
    interpretation logic stays unit-testable."""
    import httpx
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(url, timeout=timeout)
        if r.status_code != 200:
            return None
        return r.json()
    except Exception:
        return None


async def on_cpu_floor() -> bool:
    """True when the live :8090 backend is the CPU floor (nano :8082).

    Detects the floor by upstream PORT (ADR-017/018: the nano floor is :8082),
    NOT the router's internal prime/eco label — so it survives the ADR-020
    phase-4 label rename to gpu/cpu untouched. Fails OPEN (returns False =
    "not on the floor", proceed) on any error, so a router blip never silently
    silences a heartbeat or downgrades a chat turn."""
    url = os.environ.get(ROUTER_HEALTH_URL_ENV, DEFAULT_ROUTER_HEALTH_URL)
    floor_port = os.environ.get(CPU_FLOOR_PORT_ENV, DEFAULT_CPU_FLOOR_PORT)
    health = await fetch_router_health(url)
    if not health:
        return False
    upstream = str(health.get("upstream", "")).rstrip("/")
    return upstream.endswith(f":{floor_port}")
