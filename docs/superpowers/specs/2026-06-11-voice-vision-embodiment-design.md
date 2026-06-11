# Voice + Vision Embodiment for a Hexis Persona — Design

**Date:** 2026-06-11
**Status:** Approved (design); pending implementation plan
**Branch:** `home-rig-local` (local-only; never upstream)

## Motivation

Port the conversational-embodiment feature of [be-more-agent](https://github.com/brenpoly/be-more-agent)
(wake-word → STT → LLM → TTS, plus webcam vision and an animated face) onto the
Windows rig instead of a Raspberry Pi 5. The user has a mic + speaker via an audio
interface and will add a cheap webcam.

be-more-agent supplies its own brain (Ollama + `gemma:2b`, Moondream vision). Hexis
already **is** the brain — Postgres-backed memory, per-character `llama-server` fleet,
heartbeat reach-out, decline, multi-channel adapters. So we crib only the **I/O
embodiment layer** (ears, mouth, eyes, face) and wire it to an existing Hexis persona
as a new first-class channel.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Scope | Voice I/O loop + webcam vision + Windows desktop floating avatar |
| Integration depth | **Full channel** — voice = a real Hexis channel; memory, sender-scoped recall, decline, and outbox voice-reach-out all apply |
| Persona scope | **One embodied persona at a time**, switchable by config |
| Vision trigger | **On-demand snapshot** in v1; pipeline futureproofed for per-turn / continuous via swappable policy |
| Activation | **Both pluggable** — push-to-talk hotkey + OpenWakeWord, selected by config |
| STT placement | **CPU** (protect persona chat-model VRAM) |
| VLM placement | **On-demand small GPU port** |

## Hard constraint that shapes everything

Hexis channel adapters run **inside the `channel_worker` Docker container**. Docker
Desktop on Windows has no clean passthrough for mic / speaker / webcam. Therefore the
audio/video I/O **must run host-side** (native Windows Python), and the in-container
adapter must be a **network peripheral endpoint**, not a local-I/O adapter.

## Architecture (Approach A — chosen)

```
┌─ Windows host (native python venv, GPU + audio devices) ────────┐
│  voice-bridge/                                                   │
│   activation/  ── PttActivator | WakeWordActivator  (pluggable)  │
│   stt.py       ── mic capture → faster-whisper (CPU)             │
│   vision/      ── webcam grab → VLM client (sampler + policy)    │
│   tts.py       ── Piper TTS → speaker                            │
│   avatar/      ── AvatarController: idle/listening/thinking/talk │
│   ws_client.py ── connects to adapter; sends {turn,text,image}, │
│                   receives {say}/{avatar} control events         │
│   bridge.py    ── main loop                                      │
└────────────────────────────┬────────────────────────────────────┘
                              │ WebSocket (published port, localhost)
┌─ Docker: channel_worker (the embodied persona) ─────────────────┐
│  channels/voice_adapter.py  (VoiceAdapter : ChannelAdapter)     │
│   - WS server, single host client                               │
│   - inbound {turn,text,image_b64?} →                            │
│       ChannelMessage(channel_type="voice", attachments=[img])   │
│       → on_message → BRAIN (unchanged)                           │
│   - outbound send()/send_media() → WS push (replies + reach-out)│
│   - typing → avatar "thinking" event                            │
│  + existing machinery: outbox drain, decline, memory, recall    │
└──────────────────────────────┬──────────────────────────────────┘
              brain: Postgres + per-character llama-server fleet
              + new on-demand VLM port (Moondream2) for vision
```

### Why A over alternatives

- **B (host → hexis HTTP API per turn):** request/response only. No server push, so
  autonomous voice reach-out needs outbox polling, and decline/session handling gets
  re-implemented outside the channel path. Fights "full channel."
- **C (host speaks RabbitMQ + brain DB directly):** max power but duplicates
  `channel_worker` plumbing on the host and bypasses the adapter abstraction. Most
  coupling.

A keeps **all** brain plumbing in the container (reuses channel/outbox/decline
machinery untouched), gives bidirectional push for free (reach-out "just works" via the
existing outbox → `channel_worker` → `adapter.send()` path), and confines host concerns
to pure peripheral I/O.

## Components & interfaces

### Container side (in hexis repo; builds into `channel_worker`)

- **`channels/voice_adapter.py`** — `VoiceAdapter(ChannelAdapter)`:
  - WS server (e.g. `websockets`), single host client per persona.
  - `channel_type = "voice"`.
  - `capabilities = ChannelCapabilities(media=True, typing_indicator=True, max_message_length=<large>)`.
  - `start(on_message)`: boot WS server; on inbound `{type:"turn", text, image_b64?, sender_id?}`
    build `ChannelMessage(channel_type="voice", channel_id=<persona>, attachments=[image])`
    and invoke `on_message`.
  - `send(channel_id, text, …)`: push `{type:"say", text, reply_to}` to the host client.
    Serves both the reply path **and** outbox reach-out.
  - `send_media(...)`: push image/control as needed.
  - `send_typing(...)`: push `{type:"avatar", state:"thinking"}`.
  - `is_connected`: True when a host WS client is attached.
- **`channels/manager.py`** — register adapter; auto-start when `channel.voice.enabled`;
  enforce `channel.voice.allowed_users` allowlist via `parse_allowlist`.
- **`docker-compose.newchars.yml`** — publish the WS port for the single embodied
  persona's `channel_worker` so the host can reach `localhost:<port>`.
- **Config keys:** `channel.voice.{enabled, port, activation, vision_policy, allowed_users}`.

### Host side — `voice-bridge/` (native Windows venv; EXCLUDED from Docker build; `home-rig-local` only)

- **`activation/`** — `Activator` interface (`async next_trigger()`); impls
  `PttActivator` (global hotkey) and `WakeWordActivator` (OpenWakeWord). Config selects.
- **`stt.py`** — faster-whisper (`base`/`small`) on CPU; `transcribe(wav) -> str`.
- **`vision/`** — `VisionSampler` + `TriggerPolicy` enum (`on_demand` | `per_turn` |
  `ambient`); `should_capture(ctx) -> bool`, `capture() -> frame`, `describe(frame) -> str`
  via an OpenAI-style VLM client. v1 wires `on_demand`; `per_turn`/`ambient` are stub
  policies behind the same interface.
- **`tts.py`** — Piper subprocess; sentence-chunked for low first-audio latency; one
  voice per persona.
- **`avatar/`** — `AvatarController` interface (`set_state(idle|listening|thinking|talking)`,
  optional `viseme(frame)`); ships a logging stub **+ a PyQt6 sprite-overlay impl**
  (Variation 1 — see Avatar research). No lip-sync in v1 (state-based PNG animation only;
  `viseme` is the futureproof hook that a later Live2D impl fills).
- **`ws_client.py`** — connect to the adapter; send turns; receive `{say}`/`{avatar}`
  events; drive TTS + avatar.
- **`bridge.py`** — main loop (below).
- **`config.json`** — WS host/port, audio device indices, model paths, persona name /
  wake word, activation mode, vision policy.

## Data flow — one turn

1. `Activator` fires (hotkey or wake word) → avatar `listening`.
2. Mic capture until silence / key release → wav.
3. STT (CPU) → text. Empty/garbage → abort, no WS send (false-trigger guard).
4. `VisionSampler.should_capture(ctx)`? → grab frame → VLM `describe` → attach
   `[sees: …]` text (and/or `image_b64`).
5. WS send `{type:"turn", text, image_b64?}` → avatar `thinking`.
6. Adapter → `on_message` → **brain** (memory, recall, decline) → reply.
7. Adapter `send()` → WS `{type:"say", text}` → avatar `talking` → Piper speaks → `idle`.
8. **Reach-out:** persona outbox → `channel_worker` → `adapter.send()` → WS push even
   with no active turn → host speaks + animates unprompted.

## Error handling

- **Host WS offline during reach-out:** `adapter.send()` returns `None`; existing outbox
  durability handles requeue/age. No change to outbox semantics ("ACID for cognition"
  preserved — do not silently drop).
- **STT / VLM / TTS failure (host-side):** fail soft — avatar → `idle`; turn aborts or
  proceeds text-only.
- **Vision never blocks a turn:** VLM port down → proceed text-only.
- **Empty/garbage STT (false wake):** abort before WS send.
- **Brain bounce / gateway-wedge:** host just reconnects WS; the existing worker
  wedge-fix (`docker restart …_channel_worker`) is unchanged.
- **Decline:** persona declines → empty/marker reply → host stays silent (configurable
  short acknowledgement).

## Testing

- **Container (pytest):** `VoiceAdapter` — inbound frame → `ChannelMessage` shape
  (`channel_type="voice"`, `attachments`), `send()` → WS payload, allowlist filtering,
  reach-out delivers when a client is connected and returns `None` when not.
- **Host:** unit tests for `Activator` (fake trigger), `VisionSampler` policy decisions
  (`on_demand`/`per_turn`/`ambient`), STT/TTS behind fakes; loopback WS echo server for
  integration.
- **Manual smoke:** PTT → speak → hear reply; vision hotkey; reach-out fires unprompted.

## v1 scope & YAGNI cuts (kept as futureproof hooks)

- Avatar: state-based only; visemes/lip-sync = interface hook, not built.
- Vision: `on_demand` wired; `per_turn` / `ambient` are policy stubs.
- One embodied persona; multi-persona switching deferred.
- No barge-in (interrupt persona mid-speech).
- Activation + vision both pluggable (per decisions above).

## Cross-repo follow-up (not built here)

The on-demand **VLM GPU port** (Moondream2 via `llama-server`) lives in `C:\llm-serve`
per the single-launcher / fleet rule. It must be **registered with `vram-guard`** so it
is accounted under ECO/PRIME power switching alongside the persona chat model on `:8080`.
Tracked as a llm-serve task, not part of this hexis implementation.

## Backends (all swappable)

| Concern | Choice | Placement | Rationale |
|---|---|---|---|
| STT | faster-whisper (`base`/`small`) | CPU | easier on Windows than whisper.cpp; protects chat-model VRAM |
| TTS | Piper | CPU | be-more-agent's choice; Windows binaries, fast, voice-per-persona |
| VLM | Moondream2 GGUF via `llama-server` | small on-demand GPU port | tiny (~2GB), only loaded/called on demand |
| Wake word | OpenWakeWord (ONNX) | host CPU | be-more-agent parity; offline |
| Avatar | PyQt6 sprite overlay (v1) → `live2d-py` (upgrade) behind `AvatarController` | host | pluggable; sprite ships first, Live2D drops into the `viseme()` hook later |

## Avatar research (2026-06-11)

Filter: the full AI-VTuber apps each ship their **own** LLM/STT/TTS brain, so adopting
one means two competing brains (and, for Soul-of-Waifu, GPL-3 viral licensing). They are
**reference, not dependencies**. What fits the pluggable `AvatarController` is a render
layer we drive. Three variations evaluated:

1. **Sprite/PNG overlay (chosen for v1).** PyQt6/PySide6 frameless transparent
   always-on-top window, `Qt.WindowTransparentForInput` click-through, PNG frames swapped
   per state. This is be-more-agent's `faces/` approach as a floating Windows widget.
   Zero model licensing, ~100-150 LOC, matches the v1 state-based cut. No real lip-sync.
2. **Live2D via `live2d-py` (documented upgrade).** Pure-Python library (not an app)
   wrapping the Live2D Native SDK; renders Cubism models in PyQt/pygame-OpenGL with
   programmatic param control -> real lip-sync by driving `ParamMouthOpenY` from TTS
   amplitude. Needs Cubism Core+Framework (proprietary, free at our scale) + a `.model3`
   asset. Drops into the `viseme()` hook when lip-sync is wanted. `Deskpet` (Qt+Live2D)
   is a transparent-pet-mode reference.
3. **Fork a full app's renderer - rejected.** Big surgery, GPL-3 entanglement, inherits
   their architecture. Study Open-LLM-VTuber's transparent pet mode + audio lip-sync for
   ideas; do not depend on it.

**Decision:** ship Variation 1 first; Variation 2 is a drop-in upgrade via the existing
`viseme()` hook - no rework.

Sources: [Open-LLM-VTuber](https://github.com/Open-LLM-VTuber/Open-LLM-VTuber),
[live2d-py](https://github.com/Arkueid/live2d-py),
[Deskpet](https://github.com/SpacervalLam/Deskpet),
[Soul-of-Waifu](https://github.com/jofizcd/Soul-of-Waifu),
[LLM-Live2D-Desktop-Assistant](https://github.com/ylxmf2005/LLM-Live2D-Desktop-Assitant).
