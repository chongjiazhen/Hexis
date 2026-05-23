"""
Local conftest for tests/channels — overrides the repo-root autouse fixtures
(temp_test_db, db_pool, etc.) that require Postgres.

These tests exercise pure-Python helpers in channels/* (no DB, no Docker).
"""

from __future__ import annotations

import pytest


@pytest.fixture(scope="module", autouse=True)
def temp_test_db():  # type: ignore[override]
    yield


@pytest.fixture(scope="module")
def db_pool():  # type: ignore[override]
    yield None


@pytest.fixture(scope="module", autouse=True)
def sync_test_embedding_dimension_from_db():  # type: ignore[override]
    yield


@pytest.fixture(scope="module", autouse=True)
def configure_agent_for_tests():  # type: ignore[override]
    yield


@pytest.fixture(scope="module", autouse=True)
def apply_repo_migrations():  # type: ignore[override]
    yield


@pytest.fixture(autouse=True)
def setup_db():  # type: ignore[override]
    yield
