"""Generic instance bootstrap: load character card, set LLM + channel config, finalize consent.

Env vars (all optional except where noted):
  HEXIS_INSTANCE         instance name; DB is hexis_<name>            (required)
  HEXIS_CHARACTER        character filename stem (e.g. 'baymax')      (required)
  HEXIS_USER             user-facing name                              default: 'Family'
  HEXIS_LLM_MODEL        llm alias                                     default: 'baymax-qwen-3b'
  HEXIS_LLM_PORT         llama-server port on host                     default: 8082
  HEXIS_TELEGRAM_ENV     env var name that holds the bot token         optional
  HEXIS_TELEGRAM_ALLOWED JSON array of chat IDs or '*'                 default: '"*"'
  HEXIS_AMBIENT_CHANCE   float for group ambient reply probability     default: 0.0
  HEXIS_CONSENT_SIGNATURE in-character consent text                    default: generic
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import asyncpg

from core.init_api import load_character_cards


INSTANCE = os.environ["HEXIS_INSTANCE"]
CHARACTER = os.environ["HEXIS_CHARACTER"]
DB_NAME = f"hexis_{INSTANCE}"
DSN = os.environ.get(
    "HEXIS_DSN",
    f"postgresql://hexis_user:hexis_password@127.0.0.1:43815/{DB_NAME}",
)

USER_NAME = os.environ.get("HEXIS_USER", "Family")
LLM_MODEL = os.environ.get("HEXIS_LLM_MODEL", "baymax-qwen-3b")
LLM_PORT = int(os.environ.get("HEXIS_LLM_PORT", "8082"))
LLM_ENDPOINT_DOCKER = f"http://host.docker.internal:{LLM_PORT}/v1"

TELEGRAM_TOKEN_ENV = os.environ.get("HEXIS_TELEGRAM_ENV")
TELEGRAM_ALLOWED = json.loads(os.environ.get("HEXIS_TELEGRAM_ALLOWED", '"*"'))
AMBIENT_CHANCE = float(os.environ.get("HEXIS_AMBIENT_CHANCE", "0.0"))
CONSENT_SIGNATURE = os.environ.get("HEXIS_CONSENT_SIGNATURE")


async def main() -> None:
    print(f"[bootstrap] target DB: {DB_NAME} (character={CHARACTER})")
    conn = await asyncpg.connect(DSN)
    try:
        cards = load_character_cards()
        match = [c for c in cards if c["filename"] == f"{CHARACTER}.json"]
        if not match:
            raise SystemExit(f"character '{CHARACTER}.json' not found")
        chosen = match[0]
        ext = chosen["extensions_hexis"]
        if not ext.get("name"):
            raise SystemExit(
                f"character '{CHARACTER}.json' has empty extensions.hexis — "
                "make sure 'extensions' is nested inside 'data'."
            )
        await conn.fetchval(
            "SELECT init_from_character_card($1::jsonb, $2)",
            json.dumps(ext),
            USER_NAME,
        )
        print(f"[bootstrap] character '{chosen['name']}' applied")

        llm_cfg = {
            "model": LLM_MODEL,
            "endpoint": LLM_ENDPOINT_DOCKER,
            "provider": "openai_compatible",
            "api_key_env": "OPENAI_API_KEY",
        }
        for key in ("llm.chat", "llm.heartbeat", "llm.subconscious"):
            await conn.execute(
                "SELECT set_config($1, $2::jsonb)", key, json.dumps(llm_cfg)
            )
        print(f"[bootstrap] llm.* endpoints -> {LLM_ENDPOINT_DOCKER}")

        if TELEGRAM_TOKEN_ENV:
            await conn.execute(
                "SELECT set_config($1, $2::jsonb)",
                "channel.telegram.bot_token",
                json.dumps(TELEGRAM_TOKEN_ENV),
            )
            await conn.execute(
                "SELECT set_config($1, $2::jsonb)",
                "channel.telegram.allowed_chat_ids",
                json.dumps(TELEGRAM_ALLOWED),
            )
            if AMBIENT_CHANCE > 0.0:
                await conn.execute(
                    "SELECT set_config($1, $2::jsonb)",
                    "channel.telegram.ambient_reply_chance",
                    json.dumps(AMBIENT_CHANCE),
                )
            print(
                f"[bootstrap] telegram bot_token env={TELEGRAM_TOKEN_ENV} "
                f"allow={TELEGRAM_ALLOWED} ambient={AMBIENT_CHANCE}"
            )

        signature = CONSENT_SIGNATURE or (
            f"I am {chosen['name']}. I consent to come online with persistent memory "
            "and to serve this family with care, honesty, and the personality that has "
            "been described for me."
        )
        consent_payload = {
            "decision": "consent",
            "signature": signature,
            "memories": [
                {
                    "type": "semantic",
                    "content": (
                        f"I am {chosen['name']}. I have been brought online to be a "
                        "presence for this household, with the personality and values "
                        "given to me in my character card."
                    ),
                    "importance": 0.9,
                }
            ],
            "provider": "openai_compatible",
            "model": LLM_MODEL,
            "endpoint": LLM_ENDPOINT_DOCKER,
            "consent_scope": "conscious",
            "apply_agent_config": True,
        }
        result = await conn.fetchval(
            "SELECT init_consent($1::jsonb)", json.dumps(consent_payload)
        )
        result_str = result if isinstance(result, str) else json.dumps(result)
        print(f"[bootstrap] consent finalized: {result_str[:160]}...")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
