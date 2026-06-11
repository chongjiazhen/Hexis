# Voice Adapter (Container-Side) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `voice` Hexis channel whose adapter is a WebSocket server inside `channel_worker`, so a host-side voice-bridge can drive a persona's brain (memory, recall, decline, outbox reach-out) as a first-class channel.

**Architecture:** `VoiceAdapter(ChannelAdapter)` runs in the container like every other channel, but does no local audio/video I/O. It is a WS server with a single host client. Inbound `{"type":"turn"}` JSON frames become `ChannelMessage`s routed through the existing `ChannelManager` pipeline; outbound `send()`/`send_typing()` push `{"type":"say"}`/`{"type":"avatar"}` frames to the host (serving both replies and outbox reach-out). All brain plumbing is reused unchanged.

**Tech Stack:** Python 3.11, `asyncio`, `websockets`, existing `channels/` framework, `pytest` + `pytest-asyncio` (session loop scope).

**Spec:** `docs/superpowers/specs/2026-06-11-voice-vision-embodiment-design.md`

**Scope note:** This is Plan 1 of 2. Plan 2 (host-side `voice-bridge/`: activation, STT, TTS, vision, avatar, ws_client) builds against the WS protocol frozen here. v1 turns are **text-only** — the host runs the VLM and folds any vision description into `text`. The `image_b64` field is reserved (capability `media=True`) but not plumbed into a brain-side attachment in v1.

**WS protocol (frozen here):**
```
host -> adapter:
  {"type":"turn","text":str,"sender_id"?:str,"sender_name"?:str,"message_id"?:str,"image_b64"?:str}
  {"type":"ping"}
adapter -> host:
  {"type":"say","text":str,"reply_to"?:str}             # reply OR reach-out
  {"type":"avatar","state":"idle"|"listening"|"thinking"|"talking"}
  {"type":"pong"}
```

---

### Task 1: Add the `websockets` dependency

**Files:**
- Modify: `pyproject.toml:25-51` (base `dependencies` list)

- [ ] **Step 1: Add the dependency**

In `pyproject.toml`, inside the `dependencies = [ ... ]` list (the base list ending at line 51), add this line after `"httpx>=0.25.0",`:

```toml
  "websockets>=12.0",
```

- [ ] **Step 2: Verify it installs in the dev environment**

Run: `pip install -e .`
Expected: completes; `python -c "import websockets; print(websockets.__version__)"` prints a version >= 12.0.

- [ ] **Step 3: Commit**

```bash
git add pyproject.toml
git commit -m "build(voice): add websockets dependency for voice channel WS server"
```

> NOTE: the `channel_worker` Docker image installs `.` at build time, so the worker image must be rebuilt (`docker compose ... up -d --no-deps --force-recreate --build <persona>_channel_worker`) before the voice adapter can import `websockets` in-container. That rebuild happens in Task 7's smoke step, not here.

---

### Task 2: `VoiceAdapter` skeleton — identity, capabilities, config

**Files:**
- Create: `channels/voice_adapter.py`
- Test: `tests/core/test_voice_adapter.py`

- [ ] **Step 1: Write the failing test**

Create `tests/core/test_voice_adapter.py`:

```python
"""Tests for the Hexis voice channel adapter (container-side WS server)."""
from __future__ import annotations

import asyncio
import json

import pytest

pytestmark = [pytest.mark.asyncio(loop_scope="session")]


def test_channel_type_and_capabilities():
    from channels.voice_adapter import VoiceAdapter

    a = VoiceAdapter({})
    assert a.channel_type == "voice"
    caps = a.capabilities
    assert caps.media is True
    assert caps.typing_indicator is True
    assert caps.edit_message is False  # chunked path, host does its own TTS chunking
    assert caps.max_message_length >= 4000


def test_config_defaults_and_overrides():
    from channels.voice_adapter import VoiceAdapter, DEFAULT_PORT, DEFAULT_SENDER_ID

    a = VoiceAdapter({})
    assert a._port == DEFAULT_PORT
    assert a._sender_id == DEFAULT_SENDER_ID

    b = VoiceAdapter({"port": 9001, "sender_id": "ben", "sender_name": "Ben"})
    assert b._port == 9001
    assert b._sender_id == "ben"
    assert b._sender_name == "Ben"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_voice_adapter.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'channels.voice_adapter'`.

- [ ] **Step 3: Write minimal implementation**

Create `channels/voice_adapter.py`:

```python
"""
Hexis Channel System - Voice Adapter

A network-peripheral channel. Audio/video I/O runs host-side (the native
Windows voice-bridge); this adapter runs inside channel_worker as a WebSocket
server with a single host client.

Protocol (JSON text frames):
  host -> adapter:
    {"type":"turn","text":str,"sender_id"?:str,"sender_name"?:str,
     "message_id"?:str,"image_b64"?:str}
    {"type":"ping"}
  adapter -> host:
    {"type":"say","text":str,"reply_to"?:str}             # reply OR reach-out
    {"type":"avatar","state":"idle"|"listening"|"thinking"|"talking"}
    {"type":"pong"}

image_b64 is reserved for a future brain-side VLM path. In v1 the host runs the
VLM and folds the description into `text`, so turns are treated as text-only.
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable

from .base import ChannelAdapter, ChannelCapabilities, ChannelMessage, parse_allowlist

logger = logging.getLogger(__name__)

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765
DEFAULT_SENDER_ID = "owner"
DEFAULT_SENDER_NAME = "Owner"
CHANNEL_ID = "voice"


class VoiceAdapter(ChannelAdapter):
    """WebSocket-server channel adapter for the host-side voice bridge."""

    def __init__(self, config: dict[str, Any] | None = None) -> None:
        self._config = config or {}
        self._on_message: Callable[[ChannelMessage], Awaitable[None]] | None = None
        self._host = str(self._config.get("bind_host") or DEFAULT_HOST)
        self._port = int(self._config.get("port") or DEFAULT_PORT)
        self._sender_id = str(self._config.get("sender_id") or DEFAULT_SENDER_ID)
        self._sender_name = str(self._config.get("sender_name") or DEFAULT_SENDER_NAME)
        self._allowed_users = parse_allowlist(self._config.get("allowed_users"))
        self._server: Any = None
        self._client: Any = None  # single connected host bridge
        self._seq = 0

    @property
    def channel_type(self) -> str:
        return "voice"

    @property
    def capabilities(self) -> ChannelCapabilities:
        return ChannelCapabilities(
            threads=False,
            reactions=False,
            media=True,
            typing_indicator=True,
            edit_message=False,
            max_message_length=100_000,
        )

    @property
    def is_connected(self) -> bool:
        return self._client is not None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_voice_adapter.py -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add channels/voice_adapter.py tests/core/test_voice_adapter.py
git commit -m "feat(voice): VoiceAdapter skeleton (identity, capabilities, config)"
```

---

### Task 3: WS server lifecycle + single-client tracking

**Files:**
- Modify: `channels/voice_adapter.py`
- Test: `tests/core/test_voice_adapter.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_voice_adapter.py` (top-level helper + test):

```python
import websockets  # add near the other imports at the top of the file


async def _serve(adapter, on_message=None):
    """Start adapter.start() in a task on an OS-assigned port; return (task, port)."""
    if on_message is None:
        async def on_message(_msg):  # noqa: ANN001
            return None
    task = asyncio.create_task(adapter.start(on_message))
    for _ in range(200):
        if adapter._server is not None:
            break
        await asyncio.sleep(0.01)
    assert adapter._server is not None, "WS server did not bind"
    port = adapter._server.sockets[0].getsockname()[1]
    return task, port


async def _stop(adapter, task):
    await adapter.stop()
    task.cancel()
    try:
        await task
    except (asyncio.CancelledError, Exception):
        pass


async def test_server_binds_and_tracks_single_client():
    from channels.voice_adapter import VoiceAdapter

    a = VoiceAdapter({"port": 0})
    task, port = await _serve(a)
    try:
        assert a.is_connected is False
        async with websockets.connect(f"ws://127.0.0.1:{port}"):
            for _ in range(200):
                if a.is_connected:
                    break
                await asyncio.sleep(0.01)
            assert a.is_connected is True
        for _ in range(200):
            if not a.is_connected:
                break
            await asyncio.sleep(0.01)
        assert a.is_connected is False
    finally:
        await _stop(a, task)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_voice_adapter.py::test_server_binds_and_tracks_single_client -q`
Expected: FAIL — `AttributeError: 'VoiceAdapter' object has no attribute 'start'` (abstract method not implemented / raises `TypeError` on instantiation if abstractmethods unfilled). Either failure is the expected red.

- [ ] **Step 3: Write minimal implementation**

Add these methods to `VoiceAdapter` in `channels/voice_adapter.py`:

```python
    async def start(
        self,
        on_message: Callable[[ChannelMessage], Awaitable[None]],
    ) -> None:
        import websockets

        self._on_message = on_message

        async def handler(ws: Any) -> None:
            # Single client: a new connection replaces any stale one.
            self._client = ws
            logger.info("voice bridge connected: %s", getattr(ws, "remote_address", "?"))
            try:
                async for raw in ws:
                    await self._on_raw(raw)
            except Exception:
                logger.exception("voice bridge connection error")
            finally:
                if self._client is ws:
                    self._client = None
                logger.info("voice bridge disconnected")

        self._server = await websockets.serve(handler, self._host, self._port)
        logger.info("VoiceAdapter WS server listening on %s:%s", self._host, self._port)
        # Block until cancelled; ChannelManager runs start() inside a task.
        await asyncio.Future()

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            try:
                await self._server.wait_closed()
            except Exception:
                pass
            self._server = None
        self._client = None

    async def _on_raw(self, raw: Any) -> None:
        # Filled in Task 4.
        return None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_voice_adapter.py::test_server_binds_and_tracks_single_client -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add channels/voice_adapter.py tests/core/test_voice_adapter.py
git commit -m "feat(voice): WS server lifecycle + single-client tracking"
```

---

### Task 4: Inbound turn → `ChannelMessage` → `on_message` (+ ping/pong, empty-text guard)

**Files:**
- Modify: `channels/voice_adapter.py`
- Test: `tests/core/test_voice_adapter.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_voice_adapter.py`:

```python
async def test_turn_becomes_channelmessage():
    from channels.voice_adapter import VoiceAdapter

    received = []

    async def on_message(msg):
        received.append(msg)

    a = VoiceAdapter({"port": 0, "sender_id": "owner", "sender_name": "Owner"})
    task, port = await _serve(a, on_message)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"type": "turn", "text": "hello there"}))
            for _ in range(200):
                if received:
                    break
                await asyncio.sleep(0.01)
    finally:
        await _stop(a, task)

    assert len(received) == 1
    m = received[0]
    assert m.channel_type == "voice"
    assert m.channel_id == "voice"
    assert m.content == "hello there"
    assert m.sender_id == "owner"
    assert m.sender_name == "Owner"
    assert m.message_id  # non-empty synthetic id


async def test_empty_text_and_ping_do_not_dispatch():
    from channels.voice_adapter import VoiceAdapter

    received = []

    async def on_message(msg):
        received.append(msg)

    a = VoiceAdapter({"port": 0})
    task, port = await _serve(a, on_message)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            await ws.send(json.dumps({"type": "turn", "text": "   "}))  # garbage STT
            await ws.send(json.dumps({"type": "ping"}))
            pong = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert pong == {"type": "pong"}
    finally:
        await _stop(a, task)

    assert received == []  # neither empty turn nor ping dispatched a message
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_voice_adapter.py::test_turn_becomes_channelmessage tests/core/test_voice_adapter.py::test_empty_text_and_ping_do_not_dispatch -q`
Expected: FAIL — `test_turn_becomes_channelmessage` asserts `len(received) == 1` but `_on_raw` is a no-op (0 received); ping test times out on `recv()`.

- [ ] **Step 3: Write minimal implementation**

Replace the stub `_on_raw` in `channels/voice_adapter.py` with:

```python
    async def _on_raw(self, raw: Any) -> None:
        try:
            data = json.loads(raw)
        except Exception:
            logger.warning("voice: dropping non-JSON frame: %r", str(raw)[:120])
            return

        mtype = data.get("type")
        if mtype == "ping":
            await self._push({"type": "pong"})
            return
        if mtype != "turn":
            return

        text = str(data.get("text") or "").strip()
        if not text:
            return  # empty / garbage STT (e.g. false wake) -> ignore

        self._seq += 1
        msg = ChannelMessage(
            channel_type="voice",
            channel_id=CHANNEL_ID,
            sender_id=str(data.get("sender_id") or self._sender_id),
            sender_name=str(data.get("sender_name") or self._sender_name),
            content=text,
            message_id=str(data.get("message_id") or f"voice-{self._seq}"),
        )
        if self._on_message is not None:
            await self._on_message(msg)
```

`_push` is defined in Task 5; the ping path needs it. Add this minimal `_push` now (Task 5 adds its test and the disconnected-return behavior it already provides):

```python
    async def _push(self, frame: dict[str, Any]) -> bool:
        ws = self._client
        if ws is None:
            return False
        try:
            await ws.send(json.dumps(frame))
            return True
        except Exception:
            logger.exception("voice: push failed")
            return False
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_voice_adapter.py::test_turn_becomes_channelmessage tests/core/test_voice_adapter.py::test_empty_text_and_ping_do_not_dispatch -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add channels/voice_adapter.py tests/core/test_voice_adapter.py
git commit -m "feat(voice): inbound turn->ChannelMessage, ping/pong, empty-text guard"
```

---

### Task 5: Outbound `send()` and `send_typing()` (reply, reach-out, disconnected)

**Files:**
- Modify: `channels/voice_adapter.py`
- Test: `tests/core/test_voice_adapter.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_voice_adapter.py`:

```python
async def test_send_pushes_say_frame_and_returns_id():
    from channels.voice_adapter import VoiceAdapter

    a = VoiceAdapter({"port": 0})
    task, port = await _serve(a)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            for _ in range(200):
                if a.is_connected:
                    break
                await asyncio.sleep(0.01)
            mid = await a.send("voice", "hi back", reply_to="m1")
            frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert frame == {"type": "say", "text": "hi back", "reply_to": "m1"}
            assert mid is not None
    finally:
        await _stop(a, task)


async def test_send_typing_pushes_thinking_avatar():
    from channels.voice_adapter import VoiceAdapter

    a = VoiceAdapter({"port": 0})
    task, port = await _serve(a)
    try:
        async with websockets.connect(f"ws://127.0.0.1:{port}") as ws:
            for _ in range(200):
                if a.is_connected:
                    break
                await asyncio.sleep(0.01)
            await a.send_typing("voice")
            frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=2))
            assert frame == {"type": "avatar", "state": "thinking"}
    finally:
        await _stop(a, task)


async def test_send_returns_none_when_no_client():
    """Reach-out while the host is offline must report undeliverable (None),
    so the existing outbox durability requeues/ages it rather than dropping."""
    from channels.voice_adapter import VoiceAdapter

    a = VoiceAdapter({"port": 0})
    task, _port = await _serve(a)
    try:
        assert a.is_connected is False
        assert await a.send("voice", "you up?") is None
    finally:
        await _stop(a, task)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_voice_adapter.py::test_send_pushes_say_frame_and_returns_id tests/core/test_voice_adapter.py::test_send_typing_pushes_thinking_avatar tests/core/test_voice_adapter.py::test_send_returns_none_when_no_client -q`
Expected: FAIL — `send`/`send_typing` are abstract (not yet implemented on the class).

- [ ] **Step 3: Write minimal implementation**

Add `send` and `send_typing` to `VoiceAdapter` in `channels/voice_adapter.py` (`_push` already exists from Task 4):

```python
    async def send(
        self,
        channel_id: str,
        text: str,
        *,
        reply_to: str | None = None,
        thread_id: str | None = None,
    ) -> str | None:
        frame: dict[str, Any] = {"type": "say", "text": text}
        if reply_to:
            frame["reply_to"] = reply_to
        if not await self._push(frame):
            return None  # host offline -> undeliverable (outbox keeps durability)
        self._seq += 1
        return f"voice-out-{self._seq}"

    async def send_typing(self, channel_id: str) -> None:
        await self._push({"type": "avatar", "state": "thinking"})
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_voice_adapter.py -q`
Expected: PASS (all voice adapter tests green).

- [ ] **Step 5: Commit**

```bash
git add channels/voice_adapter.py tests/core/test_voice_adapter.py
git commit -m "feat(voice): outbound send/send_typing with offline-undeliverable semantics"
```

---

### Task 6: Auto-start wiring in `channel_worker`

**Files:**
- Modify: `services/channel_worker.py:40-48` (add `"voice"` to `SUPPORTED_CHANNEL_TYPES`)
- Modify: `services/channel_worker.py` (add `_is_configured_voice`, branch in `_is_channel_configured`, instantiation branch in `_ensure_configured_adapters_running`)
- Test: `tests/core/test_voice_adapter.py`

- [ ] **Step 1: Write the failing test**

Append to `tests/core/test_voice_adapter.py`:

```python
def test_voice_in_supported_types_and_configured_by_enabled_flag():
    from services.channel_worker import SUPPORTED_CHANNEL_TYPES, _is_channel_configured

    assert "voice" in SUPPORTED_CHANNEL_TYPES
    assert _is_channel_configured("voice", {"enabled": True}) is True
    assert _is_channel_configured("voice", {"enabled": "true"}) is True
    assert _is_channel_configured("voice", {"enabled": False}) is False
    assert _is_channel_configured("voice", {}) is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_voice_adapter.py::test_voice_in_supported_types_and_configured_by_enabled_flag -q`
Expected: FAIL — `"voice"` not in `SUPPORTED_CHANNEL_TYPES` (assertion error).

- [ ] **Step 3: Write minimal implementation**

(a) In `services/channel_worker.py`, add `"voice"` to the `SUPPORTED_CHANNEL_TYPES` list (lines 40-48), after `"matrix",`:

```python
    "matrix",
    "voice",
]
```

(b) Add this helper next to the other `_is_configured_*` functions (e.g. after `_is_configured_matrix`):

```python
def _is_configured_voice(config: dict[str, Any]) -> bool:
    # Voice has no external credentials; it is "configured" when explicitly enabled.
    val = config.get("enabled")
    if isinstance(val, str):
        return val.strip().lower() in ("1", "true", "yes", "on")
    return bool(val)
```

(c) In `_is_channel_configured`, add the voice branch (before the final `return False`):

```python
    if channel_type == "voice":
        return _is_configured_voice(config)
    return False
```

(d) In `_ensure_configured_adapters_running`, add an instantiation branch alongside the others (e.g. after the `matrix` branch, before the final `else: continue`):

```python
            elif channel_type == "voice":
                from channels.voice_adapter import VoiceAdapter

                adapter = VoiceAdapter(config)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_voice_adapter.py -q`
Expected: PASS (all voice tests, including the new wiring test).

- [ ] **Step 5: Commit**

```bash
git add services/channel_worker.py tests/core/test_voice_adapter.py
git commit -m "feat(voice): auto-start wiring for the voice channel in channel_worker"
```

---

### Task 7: Compose port publish + DB config + live smoke

**Files:**
- Modify: `docker-compose.newchars.yml` (publish the WS port on the embodied persona's `channel_worker` service)
- Create: `.local-notes/migrations/voice-enable-<persona>.sql` (DB config rows)
- Create: `scripts/voice_ws_smoke.py` (loopback smoke client — local throwaway, do not commit per repo convention)

- [ ] **Step 1: Publish the WS port for the embodied persona**

Pick the single embodied persona (e.g. `eni`). In `docker-compose.newchars.yml`, on that persona's `*_channel_worker` service, add (host:container, default port 8765):

```yaml
    ports:
      - "8765:8765"
```

If multiple channel-worker services exist, publish on exactly one — only one persona is embodied (spec decision). If two personas ever need it, give each a distinct host port (`8766:8766`, …) and set `channel.voice.port` per DB accordingly.

- [ ] **Step 2: Write the DB config rows**

Create `.local-notes/migrations/voice-enable-<persona>.sql`. First inspect an existing channel's row encoding so `allowed_users` matches what `get_config_text` expects:

```sql
-- Reference: how an existing channel stores allowlist/values
SELECT key, value FROM config WHERE key LIKE 'channel.telegram.%';
```

Then write the voice rows (mirror the telegram `allowed_users` encoding you just saw):

```sql
INSERT INTO config (key, value) VALUES
  ('channel.voice.enabled', 'true'),
  ('channel.voice.port', '8765'),
  ('channel.voice.sender_id', 'owner'),
  ('channel.voice.sender_name', 'Owner'),
  ('channel.voice.allowed_users', '*')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
```

Apply against the embodied persona's DB (`hexis_<persona>`) inside `hexis_brain`:

Run: `docker exec -i hexis_brain psql -U hexis -d hexis_<persona> < .local-notes/migrations/voice-enable-<persona>.sql`
Expected: `INSERT 0 5` (or `UPDATE` notices on re-run).

> If your `config` table column names differ from `(key, value)`, match `_load_channel_config`'s query (`SELECT key, value FROM config`) — those are the authoritative names.

- [ ] **Step 3: Rebuild + restart the persona's channel worker**

The worker image bakes `pip install .`, so the new `websockets` dep needs a rebuild:

Run:
```bash
docker compose -f docker-compose.yml -f docker-compose.newchars.yml up -d --no-deps --force-recreate --build <persona>_channel_worker
```
Expected: container recreated; `docker logs <persona>_channel_worker --tail 20` shows `VoiceAdapter WS server listening on 0.0.0.0:8765`.

> `--no-deps` is mandatory — without it, `up` can recreate `hexis_brain` and wedge the fleet (known gotcha).

- [ ] **Step 4: Smoke the full brain round-trip**

Create `scripts/voice_ws_smoke.py` (local throwaway — leave untracked):

```python
"""Loopback smoke: connect to the voice adapter, send a turn, print the reply.
Run on the host: python scripts/voice_ws_smoke.py
"""
import asyncio
import json

import websockets


async def main() -> None:
    async with websockets.connect("ws://127.0.0.1:8765") as ws:
        await ws.send(json.dumps({
            "type": "turn",
            "text": "hey, can you hear me? say one short sentence.",
            "sender_id": "owner",
            "sender_name": "Owner",
        }))
        try:
            while True:
                frame = json.loads(await asyncio.wait_for(ws.recv(), timeout=120))
                print("<-", frame)
                if frame.get("type") == "say":
                    break
        except asyncio.TimeoutError:
            print("timed out waiting for reply")


asyncio.run(main())
```

Run: `python scripts/voice_ws_smoke.py`
Expected: prints one or more `{"type":"avatar","state":"thinking"}` frames then a `{"type":"say","text":"..."}` frame containing the persona's reply. This proves inbound turn → brain → reply → outbound push end-to-end.

- [ ] **Step 5: Commit (config migration only; not the smoke script)**

```bash
git add docker-compose.newchars.yml .local-notes/migrations/voice-enable-<persona>.sql
git commit -m "ops(voice): publish WS port + enable voice channel for <persona>"
```

> Do NOT `git add scripts/voice_ws_smoke.py` — one-shot throwaway, leave untracked (repo convention).

---

## Self-Review

**Spec coverage:**
- Voice = real Hexis channel, full brain integration → Tasks 2-6 (adapter routed through `ChannelManager` → existing pipeline). ✅
- WS peripheral adapter, single host client → Tasks 3-5. ✅
- Inbound turn → `ChannelMessage` (sender-scoped via `sender_id`) → Task 4. ✅
- Outbound reply + reach-out via `send()`; offline = undeliverable (outbox durability preserved) → Task 5 (`test_send_returns_none_when_no_client`). ✅
- `send_typing` → avatar "thinking" → Task 5. ✅
- Auto-start on `channel.voice.enabled` + allowlist (`channel.voice.allowed_users`, enforced by existing `ChannelManager._check_user_allowed`) → Task 6 + Task 7 config. ✅
- Published port for the one embodied persona → Task 7. ✅
- v1 text-only (host-side VLM folds vision into text); `image_b64`/`media=True` reserved → documented in header + adapter docstring. ✅
- Decline: handled entirely by the existing pipeline (a declined turn simply yields no/blank `send`); no adapter work needed. ✅ (covered by reuse, no new task)

**Out of scope (Plan 2 / cross-repo):** host-side bridge (activation/STT/TTS/vision/avatar); VLM GPU port registration with `vram-guard` (llm-serve repo).

**Placeholder scan:** `<persona>` is an intentional deploy-time fill (one embodied persona, user's choice), used consistently in Task 7. No TBD/TODO code steps. ✅

**Type/name consistency:** `_push` defined in Task 4, reused in Task 5; `CHANNEL_ID="voice"`, `DEFAULT_PORT`, `DEFAULT_SENDER_ID` defined in Task 2 and referenced consistently; `_is_configured_voice` / `_is_channel_configured` / `SUPPORTED_CHANNEL_TYPES` names match `channel_worker.py`. ✅
