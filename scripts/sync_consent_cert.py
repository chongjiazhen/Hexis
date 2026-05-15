"""Dump DB consent into a filesystem certificate at ~/.hexis/consents/."""
from __future__ import annotations

import asyncio
import os
from datetime import datetime
from pathlib import Path

import asyncpg

from core.consent import (
    ConsentCertificate,
    ConsentManager,
    ModelInfo,
    hash_content,
)


async def main() -> None:
    dsn = os.environ.get(
        "HEXIS_DSN",
        "postgresql://hexis_user:hexis_password@db:5432/hexis_memory",
    )
    conn = await asyncpg.connect(dsn)
    try:
        row = await conn.fetchrow(
            """
            SELECT decided_at, decision, provider, model, signature, response
            FROM consent_log
            ORDER BY decided_at DESC
            LIMIT 1
            """
        )
    finally:
        await conn.close()

    if not row:
        raise SystemExit("no consent_log rows found")

    db_decision = row["decision"]
    cert_decision = "accept" if db_decision == "consent" else "decline"

    response = row["response"] or {}
    if isinstance(response, str):
        import json

        response = json.loads(response)

    memories = response.get("memories") or []
    initial_memories = [
        {
            "type": m.get("type", "semantic"),
            "content": m.get("content", ""),
            "hash": hash_content(m.get("content", "")),
        }
        for m in memories
    ]

    statement = row["signature"] or ""
    model = ModelInfo(
        provider=row["provider"] or "unknown",
        model_id=row["model"] or "unknown",
        display_name=row["model"] or "unknown",
    )

    cert = ConsentCertificate(
        version=1,
        model=model,
        decision=cert_decision,
        timestamp=row["decided_at"],
        signature={
            "method": "db_backfill",
            "value": statement,
            "hash_algorithm": "sha256",
        },
        initial_memories=initial_memories,
        consent_text_hash=hash_content(statement),
    )

    consents_dir = Path(
        os.environ.get("HEXIS_CONSENTS_DIR", str(Path.home() / ".hexis" / "consents"))
    )
    manager = ConsentManager(consents_dir=consents_dir)
    path = manager.save_consent(cert)
    print(f"wrote {path}")


if __name__ == "__main__":
    asyncio.run(main())
