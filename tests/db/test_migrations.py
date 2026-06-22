"""Tests for the incremental migration runner in core.schema.

Covers: ordered apply, idempotency (no double-run), atomic rollback of a
failing migration, and baseline-stamping (mark applied without executing).
"""
import asyncpg
import pytest

from core.schema import (
    _applied_versions,
    apply_migrations_conn,
    pending_migrations,
    stamp_migrations,
)
from tests.utils import _db_dsn

pytestmark = [pytest.mark.asyncio(loop_scope="session"), pytest.mark.db]


@pytest.fixture
def migrations_dir(tmp_path):
    d = tmp_path / "migrations"
    d.mkdir()
    return d


def _write(d, name, sql):
    (d / name).write_text(sql, encoding="utf-8")


async def _drop_versions(conn, *versions):
    await conn.execute(
        "DELETE FROM schema_migrations WHERE version = ANY($1::text[])",
        list(versions),
    )


async def test_apply_runs_pending_in_order(db_pool, migrations_dir):
    _write(migrations_dir, "0001_a.sql", "CREATE TABLE mig_test_a (id int);")
    _write(migrations_dir, "0002_b.sql", "CREATE TABLE mig_test_b (id int);")
    async with db_pool.acquire() as conn:
        try:
            applied = await apply_migrations_conn(conn, migrations_dir)
            assert applied == ["0001_a.sql", "0002_b.sql"]
            for tbl in ("mig_test_a", "mig_test_b"):
                assert await conn.fetchval("SELECT to_regclass($1)", tbl) is not None
            assert {"0001_a.sql", "0002_b.sql"} <= await _applied_versions(conn)
        finally:
            await conn.execute("DROP TABLE IF EXISTS mig_test_a, mig_test_b")
            await _drop_versions(conn, "0001_a.sql", "0002_b.sql")


async def test_apply_is_idempotent(db_pool, migrations_dir):
    # Bare CREATE TABLE would raise "already exists" if re-run — proves the
    # second pass skips it rather than re-executing.
    _write(migrations_dir, "0001_c.sql", "CREATE TABLE mig_test_c (id int);")
    async with db_pool.acquire() as conn:
        try:
            assert await apply_migrations_conn(conn, migrations_dir) == ["0001_c.sql"]
            assert await apply_migrations_conn(conn, migrations_dir) == []
        finally:
            await conn.execute("DROP TABLE IF EXISTS mig_test_c")
            await _drop_versions(conn, "0001_c.sql")


async def test_failed_migration_rolls_back(db_pool, migrations_dir):
    _write(migrations_dir, "0001_bad.sql", "THIS IS NOT VALID SQL;")
    async with db_pool.acquire() as conn:
        try:
            with pytest.raises(asyncpg.PostgresError):
                await apply_migrations_conn(conn, migrations_dir)
            # not recorded -> a later fixed re-run retries it
            assert "0001_bad.sql" not in await _applied_versions(conn)
        finally:
            await _drop_versions(conn, "0001_bad.sql")


async def test_pending_lists_unapplied(db_pool, migrations_dir):
    _write(migrations_dir, "0001_p.sql", "CREATE TABLE mig_test_p (id int);")
    _write(migrations_dir, "0002_q.sql", "CREATE TABLE mig_test_q (id int);")
    dsn = _db_dsn()  # temp_test_db fixture has pointed POSTGRES_DB at the test DB
    async with db_pool.acquire() as conn:
        try:
            assert await pending_migrations(dsn, migrations_dir) == ["0001_p.sql", "0002_q.sql"]
            await apply_migrations_conn(conn, migrations_dir)
            assert await pending_migrations(dsn, migrations_dir) == []
        finally:
            await conn.execute("DROP TABLE IF EXISTS mig_test_p, mig_test_q")
            await _drop_versions(conn, "0001_p.sql", "0002_q.sql")


async def test_stamp_marks_without_running(db_pool, migrations_dir):
    # Invalid SQL that WOULD fail if executed — stamping must not run it.
    _write(migrations_dir, "0001_would_fail.sql", "THIS IS NOT VALID SQL;")
    async with db_pool.acquire() as conn:
        try:
            await stamp_migrations(conn, migrations_dir)
            assert "0001_would_fail.sql" in await _applied_versions(conn)
            # subsequent apply skips the stamped migration -> no error raised
            assert await apply_migrations_conn(conn, migrations_dir) == []
        finally:
            await _drop_versions(conn, "0001_would_fail.sql")
