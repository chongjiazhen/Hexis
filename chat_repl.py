"""Plain stdin/stdout REPL using Hexis stream_agent. Bypass TUI."""
import asyncio
import os
import sys
import uuid
from dotenv import load_dotenv

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

import asyncpg
from core.agent_loop import AgentEvent
from core.cognitive_memory_api import CognitiveMemory
from core.tools.registry import create_default_registry
from services.agent import stream_agent
from services.chat import _remember_conversation


async def main() -> None:
    dsn = os.getenv("DATABASE_URL") or (
        f"postgres://{os.getenv('POSTGRES_USER', 'hexis_user')}:"
        f"{os.getenv('POSTGRES_PASSWORD', 'hexis_password')}"
        f"@{os.getenv('POSTGRES_HOST', 'localhost')}:"
        f"{os.getenv('POSTGRES_PORT', '43815')}/"
        f"{os.getenv('POSTGRES_DB', 'hexis_memory')}"
    )
    pool = await asyncpg.create_pool(dsn)
    registry = create_default_registry(pool)
    history: list[dict[str, str]] = []

    async def persist(user_input: str, full_text: str) -> None:
        if not user_input and not full_text:
            return
        try:
            mem_client = CognitiveMemory(pool)
            await _remember_conversation(
                mem_client,
                user_message=user_input,
                assistant_message=full_text,
            )
        except Exception as e:
            sys.stderr.write(f"[persist-error] {e}\n")
            sys.stderr.flush()

    print("Hexis REPL (Ctrl+C to exit). Type a message and press Enter.\n")
    try:
        while True:
            user_input = input("you: ").strip()
            if not user_input:
                continue
            session_id = str(uuid.uuid4())
            full_text = ""
            sys.stdout.write("Samantha: ")
            sys.stdout.flush()
            try:
                async for event in stream_agent(
                    pool, registry,
                    user_message=user_input,
                    mode="chat",
                    history=history,
                    session_id=session_id,
                    dsn=dsn,
                ):
                    if event.event == AgentEvent.TEXT_DELTA:
                        chunk = event.data.get("text", "")
                        if chunk:
                            sys.stdout.write(chunk)
                            sys.stdout.flush()
                            full_text += chunk
                    elif event.event == AgentEvent.ERROR:
                        sys.stdout.write(f"\n[ERROR] {event.data.get('error', '')}\n")
                        sys.stdout.flush()
            finally:
                await persist(user_input, full_text)
            sys.stdout.write("\n\n")
            sys.stdout.flush()
            history.append({"role": "user", "content": user_input})
            history.append({"role": "assistant", "content": full_text})
    except KeyboardInterrupt:
        print("\nbye")
    finally:
        await pool.close()


if __name__ == "__main__":
    asyncio.run(main())
