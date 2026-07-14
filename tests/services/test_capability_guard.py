"""The heartbeat worker's capability guard is the shared core.serving probe
(ADR-020 §2). The probe's own logic is tested in tests/core/test_serving.py;
this pins the worker's binding to it, so an accidental re-fork of the logic
inside worker_service.py fails here.
"""
from core import serving
from services import worker_service as ws


def test_worker_uses_shared_capability_probe():
    assert ws._on_cpu_floor is serving.on_cpu_floor
    assert ws._fetch_router_health is serving.fetch_router_health
