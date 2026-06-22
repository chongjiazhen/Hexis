"""Schema management for Hexis instances.

Provides functions to create databases, apply schema files, and manage
database lifecycle programmatically.
"""
from __future__ import annotations

import importlib.resources
import logging
import tempfile
from pathlib import Path

import asyncpg

logger = logging.getLogger(__name__)


def get_schema_dir() -> Path:
    """Get path to db/ schema directory."""
    return Path(__file__).parent.parent / "db"


def get_schema_files() -> list[Path]:
    """Get sorted list of schema SQL files.

    First checks the filesystem (source checkout). Falls back to
    importlib.resources (pip install) when no SQL files are found on disk.
    """
    schema_dir = get_schema_dir()
    if schema_dir.exists():
        files = sorted(schema_dir.glob("*.sql"))
        if files:
            return files

    # Fallback: load from installed package data
    try:
        import db as _db_pkg  # noqa: F811
        ref = importlib.resources.files(_db_pkg)
        sql_files: list[Path] = []
        for item in ref.iterdir():
            if item.name.endswith(".sql"):
                # importlib.resources may return Traversable; extract to a temp path
                with importlib.resources.as_file(item) as p:
                    # Copy to a stable temp location so callers can read later
                    tmp = Path(tempfile.gettempdir()) / "hexis_schema" / item.name
                    tmp.parent.mkdir(parents=True, exist_ok=True)
                    if not tmp.exists() or tmp.read_bytes() != p.read_bytes():
                        tmp.write_bytes(p.read_bytes())
                    sql_files.append(tmp)
        if sql_files:
            return sorted(sql_files)
    except (ImportError, Exception) as exc:
        logger.debug("importlib.resources fallback failed: %s", exc)

    raise FileNotFoundError(f"No schema files found in {schema_dir} or via importlib.resources")


async def create_database(db_name: str, admin_dsn: str) -> None:
    """
    Create a new empty database.

    Args:
        db_name: Name of database to create
        admin_dsn: DSN with permissions to create databases (should connect to 'postgres' database)
    """
    conn = await asyncpg.connect(admin_dsn)
    try:
        # Check if database already exists
        exists = await conn.fetchval(
            "SELECT 1 FROM pg_database WHERE datname = $1", db_name
        )
        if exists:
            raise ValueError(f"Database '{db_name}' already exists")

        # Can't use parameters for database names in DDL
        # Use safe identifier quoting
        await conn.execute(f'CREATE DATABASE "{db_name}"')
        logger.info(f"Created database: {db_name}")
    finally:
        await conn.close()


async def drop_database(db_name: str, admin_dsn: str) -> None:
    """
    Drop a database.

    Args:
        db_name: Name of database to drop
        admin_dsn: DSN with permissions to drop databases (should connect to 'postgres' database)
    """
    conn = await asyncpg.connect(admin_dsn)
    try:
        # Terminate existing connections
        await conn.execute(
            """
            SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname = $1 AND pid <> pg_backend_pid()
            """,
            db_name,
        )
        # Drop the database
        await conn.execute(f'DROP DATABASE IF EXISTS "{db_name}"')
        logger.info(f"Dropped database: {db_name}")
    finally:
        await conn.close()


async def apply_schema(dsn: str) -> None:
    """
    Apply all schema files to a database.

    Args:
        dsn: Connection string for target database
    """
    schema_files = get_schema_files()
    if not schema_files:
        raise FileNotFoundError("No schema files found in db/")

    conn = await asyncpg.connect(dsn)
    try:
        for sql_file in schema_files:
            logger.info(f"Applying {sql_file.name}...")
            content = sql_file.read_text()
            try:
                await conn.execute(content)
            except Exception as e:
                logger.error(f"Error applying {sql_file.name}: {e}")
                raise
        logger.info(f"Applied {len(schema_files)} schema files")
        # A from-scratch bootstrap already contains the latest schema, so every
        # incremental migration is baseline-stamped (recorded as applied without
        # executing it). This stops apply_migrations from double-running an ALTER
        # whose effect the bootstrap files above already include.
        await stamp_migrations(conn)
    finally:
        await conn.close()


# ---------------------------------------------------------------------------
# Incremental migrations
#
# db/*.sql is a from-scratch bootstrap (rebuilds a full DB, fresh instances
# only). It cannot evolve an existing populated DB: most CREATE TABLE statements
# are bare, so re-running them throws "relation already exists".
#
# db/migrations/*.sql carries ordered deltas for DBs that already hold data.
# A schema_migrations table tracks which have run, so each applies exactly once.
#
# DUAL-WRITE RULE: every schema change goes in BOTH places —
#   1. db/*.sql       so future fresh instances get it from the bootstrap.
#   2. db/migrations/ so existing populated DBs get it as a delta.
# Baseline-stamping (see apply_schema) keeps the two consistent: a fresh DB
# stamps the new migration as already-applied instead of re-running it.
# Migrations should still be defensive (ADD COLUMN IF NOT EXISTS, etc.).
# ---------------------------------------------------------------------------

MIGRATIONS_TABLE = "schema_migrations"


def get_migrations_dir() -> Path:
    """Path to db/migrations/, the incremental-migration directory."""
    return get_schema_dir() / "migrations"


def get_migration_files(migrations_dir: Path | None = None) -> list[Path]:
    """Migration SQL files sorted in apply order (lexical by filename).

    Filenames MUST sort in the order they should apply — use a zero-padded
    numeric or date prefix, e.g. ``0001_add_foo.sql`` or
    ``20260622_add_foo.sql``. Returns [] when the directory is absent.
    """
    migrations_dir = migrations_dir or get_migrations_dir()
    if not migrations_dir.exists():
        return []
    return sorted(migrations_dir.glob("*.sql"), key=lambda p: p.name)


async def _ensure_migrations_table(conn: asyncpg.Connection) -> None:
    await conn.execute(
        f"""
        CREATE TABLE IF NOT EXISTS {MIGRATIONS_TABLE} (
            version    TEXT PRIMARY KEY,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )


async def _applied_versions(conn: asyncpg.Connection) -> set[str]:
    rows = await conn.fetch(f"SELECT version FROM {MIGRATIONS_TABLE}")
    return {r["version"] for r in rows}


async def stamp_migrations(
    conn: asyncpg.Connection, migrations_dir: Path | None = None
) -> None:
    """Baseline: record every current migration as applied WITHOUT running it.

    Flyway ``baseline`` semantics. Called after a from-scratch apply_schema so
    the bootstrap-fresh DB does not later re-run migrations whose effect it
    already contains.
    """
    await _ensure_migrations_table(conn)
    files = get_migration_files(migrations_dir)
    if not files:
        return
    await conn.executemany(
        f"INSERT INTO {MIGRATIONS_TABLE} (version) VALUES ($1) "
        f"ON CONFLICT (version) DO NOTHING",
        [(f.name,) for f in files],
    )


async def apply_migrations_conn(
    conn: asyncpg.Connection, migrations_dir: Path | None = None
) -> list[str]:
    """Apply pending migrations on an open connection, in filename order.

    Each migration runs in its own transaction with its bookkeeping insert, so a
    failure rolls back atomically and leaves schema_migrations untouched — a
    re-run retries it. Returns the versions newly applied this call.
    """
    await _ensure_migrations_table(conn)
    applied = await _applied_versions(conn)
    newly: list[str] = []
    for path in get_migration_files(migrations_dir):
        if path.name in applied:
            continue
        sql = path.read_text(encoding="utf-8")
        async with conn.transaction():
            await conn.execute(sql)
            await conn.execute(
                f"INSERT INTO {MIGRATIONS_TABLE} (version) VALUES ($1)",
                path.name,
            )
        logger.info("Applied migration %s", path.name)
        newly.append(path.name)
    return newly


async def apply_migrations(dsn: str, migrations_dir: Path | None = None) -> list[str]:
    """Connect to ``dsn`` and apply pending migrations. Returns applied versions."""
    conn = await asyncpg.connect(dsn)
    try:
        return await apply_migrations_conn(conn, migrations_dir)
    finally:
        await conn.close()


async def pending_migrations(dsn: str, migrations_dir: Path | None = None) -> list[str]:
    """Versions present on disk but not yet recorded applied for ``dsn``."""
    conn = await asyncpg.connect(dsn)
    try:
        await _ensure_migrations_table(conn)
        applied = await _applied_versions(conn)
        return [p.name for p in get_migration_files(migrations_dir) if p.name not in applied]
    finally:
        await conn.close()


async def database_exists(db_name: str, admin_dsn: str) -> bool:
    """Check if a database exists."""
    conn = await asyncpg.connect(admin_dsn)
    try:
        result = await conn.fetchval(
            "SELECT 1 FROM pg_database WHERE datname = $1", db_name
        )
        return result is not None
    finally:
        await conn.close()


async def get_admin_dsn(base_dsn: str | None = None) -> str:
    """
    Get admin DSN for database operations.

    Replaces the database name in the DSN with 'postgres' for admin operations.

    Args:
        base_dsn: Base DSN to modify. If None, uses default from env.

    Returns:
        DSN pointing to 'postgres' database for admin operations.
    """
    if not base_dsn:
        from core.agent_api import db_dsn_from_env
        base_dsn = db_dsn_from_env()

    # Replace database name with 'postgres'
    # DSN format: postgresql://user:pass@host:port/database
    # Need to handle case where there's no database part
    # The :// is part of the scheme, so we need to find / after host:port

    # Find the position after ://
    scheme_end = base_dsn.find("://")
    if scheme_end != -1:
        # Look for / after the scheme
        after_scheme = base_dsn[scheme_end + 3:]
        slash_pos = after_scheme.find("/")
        if slash_pos != -1:
            # There is a database part, replace it
            base_part = base_dsn[:scheme_end + 3 + slash_pos]
            admin_dsn = base_part + "/postgres"
        else:
            # No database part, just append
            admin_dsn = base_dsn + "/postgres"
    else:
        # No :// found, just append /postgres
        admin_dsn = base_dsn + "/postgres"

    return admin_dsn


async def verify_database_connection(dsn: str) -> bool:
    """Verify that we can connect to a database."""
    try:
        conn = await asyncpg.connect(dsn)
        await conn.close()
        return True
    except Exception:
        return False
